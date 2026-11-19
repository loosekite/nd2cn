#!/bin/sh
# nd2cn Track Dash — data daemon
#
# Collects live vehicle data over the CMU service D-Bus and publishes it as
# one small JSON file for app/dashboard.html:
#
#     /tmp/nd2cn/dashboard.json        (tmpfs, replaced atomically, ~20 Hz)
#
# Usage:  dashboard-daemon.sh [start|stop|restart|status|run]
#     start    detach and run in the background (default; safe to call from
#              boot.d, prints nothing, never starts twice)
#     run      run in the foreground (debugging over SSH)
#
# THIS SCRIPT IS THE FALLBACK. Next to it lives nd2cn-dashd, a native program
# (source: native/dashd.c) that does the same job without launching a
# process per question: it forwards every frame the car sends (10 a second)
# where this script reaches 5 to 6. "start" runs the native program if it
# passes its own self-test on this unit, and the shell loop below otherwise.
# DASH_NATIVE=off in dashboard.conf forces the shell loop. Both write the
# same JSON (the native one adds "wheels", "src":"native" and "t", the time
# stamp the page uses to move its bars and numbers evenly) and use the
# same pid file, so stop / restart / status work for either.
#
# POSIX sh, written for BusyBox 1.19.2 ash. Needs dbus-send, dbus-monitor,
# awk, mkfifo, usleep, stat, touch and (for coolant) /jci/smdb/smdb-read
# (all present on firmware 74.00.324A).
#
# STORAGE: this daemon writes ONLY below /tmp/nd2cn (tmpfs). It never writes
# to /data or the rootfs, keeps no log and records nothing. The optional
# config file /data/nd2cn/dashboard.conf is only ever read.
#
# ── Data sources (interfaces verified against the 74.00.324A binaries) ──
#   pushed, read with dbus-monitor:
#     com.jci.vbs.vdt  (uint16 each, JCIDBUS_add_ui16_param in libjcimod_vdt.so)
#         EngAout_N_Actl           engine speed
#         ApedPos_Pc_ActlArb       accelerator pedal
#         SteWhlComp_An_Est        steering wheel angle, UNSIGNED with the
#                                  centre at an offset; 32766 (0x7FFE) means
#                                  "nothing received yet", 32767 invalid
#         Lateral_Acceleration     lateral acceleration, UNSIGNED 13 bit,
#         VehLong_A_Actl           longitudinal acceleration: 0 g = raw 4000
#         Veh_V_ActlEng            vehicle speed (fallback for the BCM speed)
#     com.jci.vbs.vwm
#         OilPressureWarning(_2)   oil pressure telltale
#         BatteryChargingTelltale(2)  charging system telltale. Used instead
#                                  of com.jci.vbs.bcm BatteryVoltageFlag,
#                                  whose polarity is not documented anywhere.
#   polled with dbus-send:
#     com.jci.vbs.bcm  GetCarSpeed(u) -> u,
#                      GetBrkPedalDepressedStatus() -> y   (every 2nd tick, 10 Hz)
#                          on/off switch, no pressure: 1 released, 2 depressed
#                          (published raw; dashboard.html decodes it)
#                      GetGearPos() -> y                   manual gearbox:
#                          0 neutral, 1..8 forward, 14 reverse, 15 invalid
#                      GetTransmChangeLeverPosition() -> y automatic gearbox:
#                          1 P, 2 R, 3 N, 4..6 forward (D, M)
#                          (the two take turns, 5 Hz each; the value tables
#                          are the ones VBS_BCM_Get_PASCD_GearPosition in
#                          libjcimod_bcm.so uses for the parking sensors)
#     com.jci.lds.data GetPosition() -> accuracy(i) utc(t) lat(d) lon(d)
#                      alt(i) heading(d) velocity km/h(d) hdop(d) vdop(d)
#                                                   (every 4th tick, 5 Hz)
#   read with smdb-read (shared memory database, every 2 s):
#     vdm_vdt_current_data / EngClnt_Te_Actl        coolant temperature
#
# ── What this firmware does NOT provide ──
#   Coolant and outside temperature are NOT available over D-Bus on
#   74.00.324A. The introspection data of com.jci.vbs.vwm lists the signals
#   EngClnt_Te_Actl_2 and AirAmb_Te_Actl_2, but their emitters in
#   libjcimod_vwm.so (VBS_VWM_EngClnt_Te_Actl_2 at 0x102ac,
#   VBS_VWM_AirAmb_Te_Actl_2 at 0x5208) are dead code: no branch and no
#   function pointer anywhere in the binary refers to them, so the signals
#   are never sent. com.jci.vbs.vdt has no coolant signal either:
#   VBS_VDT_SendSignal_EngClnt_Te_Actl only stores the value in the SMDB
#   (VDM_UpdateCVD_EngClnt_Te_Actl), which is where this daemon reads it.
#   Outside temperature has no source at all; "ambient" is always null and
#   the dashboard hides that cell.
#
# ── How it runs ──
#   dbus-monitor ──> FIFO ──> awk   keeps the newest value of every signal
#   main loop (20 Hz):  writes "T" into the same FIFO, which makes awk dump
#       its state to a one-line file; on the ticks that are due it polls the
#       BCM, GPS or coolant; then merges everything into the JSON and renames
#       it into place. On a tick without a poll the snapshot it reads may be
#       the one requested a tick earlier (50 ms older), never a torn one.
#
# ── On-demand operation ──
#   Every poll is a process launch on a single 1 GHz core, so only the
#   pushed signals (free) run at 20 Hz. Polls per second while active:
#   30 for the BCM (3 calls at 10 Hz), 5 for GPS, 0.5 for coolant; it was
#   65 when everything was polled on every tick. That is fine while someone
#   is looking at the dashboard and a waste otherwise, so the daemon sleeps
#   until the page starts reading the file: after each probe write the
#   file's timestamps are set back to the year 2000; a read by the browser
#   bumps the access time, which the next tick notices. While idle (1 Hz)
#   nothing is polled and dbus-monitor listens only to the telltales, so
#   those are already known the moment the dashboard opens. If access times
#   do not work on /tmp (self-test at start), the daemon simply stays
#   active all the time.
#
# ── Calibration ──
#   The VDT values are raw CAN numbers. Their encoding (unsigned, and where
#   zero sits) is taken from the firmware; the scale per bit could not be
#   verified off-car. Every channel is  value = raw * SCALE + OFFSET  (with
#   optional two's-complement decoding), overridable in dashboard.conf. The
#   JSON carries the raw numbers under "raw", and the dashboard's
#   calibration panel (commander tilt left / right) shows raw and converted
#   values side by side.

DBUS_ADDR="unix:path=/tmp/dbus_service_socket"
RUN_DIR="${DASH_RUN_DIR:-/tmp/nd2cn}"       # tmpfs; the override exists for bench tests
OUT="$RUN_DIR/dashboard.json"
TMP="$RUN_DIR/.dashboard.json.tmp"
FRAG="$RUN_DIR/.dashboard.signals"
FIFO="$RUN_DIR/.dashboard.fifo"
PIDFILE="$RUN_DIR/dashboard-daemon.pid"
CONF="${DASH_CONF:-/data/nd2cn/dashboard.conf}"

# ── Defaults (override in $CONF, plain sh assignments) ──
DASH_HZ=20              # JSON updates per second while the dashboard is open
DASH_BCM_EVERY=2        # poll the BCM every Nth tick (20 Hz / 2 = 10 Hz)
DASH_GPS_EVERY=4        # poll GPS every Nth tick (20 Hz / 4 = 5 Hz)
DASH_COOL_EVERY=40      # read coolant from the SMDB every Nth tick (2 s)
DASH_GEARBOX=auto       # auto | at | mt. auto: decided from what the car reports
                        #   (see detect_gearbox); set it if the gear shows wrong
DASH_IDLE=auto          # auto: sleep while nobody reads the file; off: always active
DASH_LINGER=30          # seconds without a reader before going idle
DASH_DBUS_TIMEOUT=250   # ms, per method call
DASH_NATIVE=auto        # auto: use nd2cn-dashd if it can run here; off: always this script
# DASH_WS_PORT=7361     # nd2cn-dashd only: the WebSocket port it pushes the samples on
                        #   (127.0.0.1); 0 = off, the page then reads the file
# DASH_STATS=on         # nd2cn-dashd only: keep the highest brake pressure and what each
                        #   run saw of the uncalibrated values in /data/nd2cn/dashd-stats.txt
                        #   (flash; a new peak within 10 s, otherwise every 10 min); off = don't
# Read by the page itself (dashboard.html, see CFG.shift* there), not here:
# SHIFT_BEEP=long       # shift beep: long | short | off
# SHIFT_RPM_12=7400     # r/min to shift at in 1st and 2nd
# SHIFT_RPM=7100        # ... from 3rd up
# SHIFT_LEAD_MS=450     # how early the beep comes
# SHIFT_COLD_C=60       # coolant below this (0 = never): beep at
# SHIFT_COLD_RPM=4500   #   this engine speed instead
# BRAKE_FULL=0          # raw brake pressure for a full brake bar; 0 = the highest seen

RPM_SCALE=2             # EngAout_N_Actl: 2 r/min per bit. Verified on the car (ND2 RF,
RPM_OFFSET=0            #   74.00.324A, 2026-11-16): matches the tachometer, idle and revving
THR_SCALE=0.1           # ApedPos_Pc_ActlArb: 0.1 % per bit
THR_OFFSET=0
# Steering and both accelerations are UNSIGNED on this firmware. libjcivdm.so
# stores the same numbers as "PID" values and range-checks them first:
# steering is accepted from 0 to 0x7FFE, the accelerations from 0 to 0x1FFF,
# and 4000 is what it substitutes for an acceleration it has no reading for.
# jci/smdb/vdm_vdt_current_data.xml starts them at 32766 / 4000 / 4000. So
# two's complement is wrong for all three: standing still reads raw 4000.
STEER_SCALE=0.1         # SteWhlComp_An_Est: 0.1 degree per bit ...
STEER_OFFSET=-1600      #   ... centre at raw 16000. The firmware only proves "unsigned,
STEER_SIGNED=0          #   0..32765"; 16000 is the value Mazda uses on the CAN bus of
                        #   this generation (opendbc mazda_2017). Check on the car: wheels
                        #   straight must read about 0. Negative scale flips left / right.
# Both accelerations: 0.01 m/s2 per bit, 0 = raw 4000. That is the definition
# of the same-named signals (VehLong_A_Actl, VehLat_A_Actl) in Ford's public
# CAN database (opendbc, ford_lincoln_base_pt.dbc: factor 0.01, offset -40
# m/s2), whose naming this Mazda generation shares; the engine speed scale
# from the same file (2 r/min per bit) was confirmed on the car. In g:
# 0.01 / 9.80665 = 0.001019716 per bit, and 4000 bits = 4.078864 g.
# (Until 2026-11-17 this was 0.001 g per bit: readings were 2 % low.)
LATG_SCALE=0.001019716  # Lateral_Acceleration (flip the sign of LATG_SCALE, and make
LATG_OFFSET=-4.078864   #   LATG_OFFSET +4.078864, if the dot moves the wrong way)
LATG_SIGNED=0
LONG_SCALE=0.001019716  # VehLong_A_Actl; positive = accelerating
LONG_OFFSET=-4.078864
LONG_SIGNED=0
COOL_SCALE=1            # SMDB EngClnt_Te_Actl (one byte): 1 degree C per bit ...
COOL_OFFSET=-40         #   ... with the usual CAN offset of -40 (use 0 if it reads 40 too low)
VSS_SCALE=0.01          # Veh_V_ActlEng: 0.01 km/h per bit
SPEED_UNIT=0            # argument of GetCarSpeed (0 = km/h)
SPEED_DIV=100           # GetCarSpeed result is divided by this (100: reports 0.01 km/h on MX-5 ND2)

# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

# Integer sanity for everything used in shell arithmetic
case "$DASH_HZ" in ''|*[!0-9]*|0) DASH_HZ=20 ;; esac
[ "$DASH_HZ" -gt 50 ] && DASH_HZ=50
case "$DASH_BCM_EVERY" in ''|*[!0-9]*|0) DASH_BCM_EVERY=2 ;; esac
case "$DASH_GPS_EVERY" in ''|*[!0-9]*|0) DASH_GPS_EVERY=4 ;; esac
case "$DASH_COOL_EVERY" in ''|*[!0-9]*|0) DASH_COOL_EVERY=40 ;; esac
case "$DASH_LINGER" in ''|*[!0-9]*) DASH_LINGER=30 ;; esac
case "$DASH_DBUS_TIMEOUT" in ''|*[!0-9]*|0) DASH_DBUS_TIMEOUT=250 ;; esac
case "$SPEED_DIV" in ''|*[!0-9]*|0) SPEED_DIV=1 ;; esac
case "$SPEED_UNIT" in ''|*[!0-9]*) SPEED_UNIT=0 ;; esac

PERIOD_CS=$((100 / DASH_HZ))          # tick length in 1/100 s
[ "$PERIOD_CS" -lt 2 ] && PERIOD_CS=2
STAMP_OLD=200001010000                # touch -t: "nobody has read this yet"

# The BCM is polled on even ticks. GPS and coolant go on odd ones where the
# intervals allow it, so that no single tick has to carry every launch.
GPS_PHASE=0
[ "$DASH_GPS_EVERY" -gt 1 ] && GPS_PHASE=1
COOL_PHASE=0
[ "$DASH_COOL_EVERY" -gt 3 ] && COOL_PHASE=3

# Gearbox: fixed by the config, or found out while running
case "$DASH_GEARBOX" in
    at|mt) GBOX=$DASH_GEARBOX; GBOX_FIXED=1 ;;
    *)     GBOX="";            GBOX_FIXED=0 ;;
esac

# ──────────────────────────────────────────────────────────────
# Process control
# ──────────────────────────────────────────────────────────────
daemon_pid() {
    [ -r "$PIDFILE" ] || return 1
    read -r _dp 2>/dev/null < "$PIDFILE" || return 1
    case "$_dp" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$_dp" 2>/dev/null || return 1
    # guard against a recycled pid: it must be this script or the native daemon
    grep -q -e "${0##*/}" -e "$NATIVE_NAME" "/proc/$_dp/cmdline" 2>/dev/null || return 1
    echo "$_dp"
}

# ──────────────────────────────────────────────────────────────
# The native daemon
# ──────────────────────────────────────────────────────────────
NATIVE_NAME=nd2cn-dashd
NATIVE_BIN=""

# native_try FILE — true if FILE is the native daemon and runs on this unit
native_try() {
    [ -f "$1" ] && [ -x "$1" ] || return 1
    # the braces: a binary that crashes must not put the shell's "Bus error" on the console
    { _nt=$("$1" selftest 2>/dev/null); } 2>/dev/null || return 1
    case "$_nt" in "nd2cn-dashd OK"*) NATIVE_BIN=$1; return 0 ;; esac
    return 1
}

# Find a copy that can be executed: the installed one, or (should /data not
# allow execution) a copy in the run directory, which is the only place this
# script writes to.
native_find() {
    [ "$DASH_NATIVE" = "off" ] && return 1
    _nf="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$NATIVE_NAME"
    [ -f "$_nf" ] || return 1
    native_try "$_nf" && return 0
    # by rename: a copy that is still running cannot be written over. The
    # temporary name is this caller's own, so that two starts at once do not
    # write into the same file.
    # It is tested under that name first: a copy that cannot run either (/tmp
    # not executable as well) is not left behind.
    _nt_tmp="$RUN_DIR/.$NATIVE_NAME.$$.tmp"
    if cp "$_nf" "$_nt_tmp" 2>/dev/null && chmod 755 "$_nt_tmp" 2>/dev/null && \
       native_try "$_nt_tmp" && mv -f "$_nt_tmp" "$RUN_DIR/$NATIVE_NAME" 2>/dev/null; then
        NATIVE_BIN="$RUN_DIR/$NATIVE_NAME"
        return 0
    fi
    rm -f "$_nt_tmp"
    return 1
}

# nap: wait a tenth of a second; without usleep, a whole one. NAP is how many
# tenths that was, so that the loops below count time, not rounds.
if command -v usleep > /dev/null 2>&1; then
    nap() { usleep 100000; }
    NAP=1
else
    nap() { sleep 1; }
    NAP=10
fi

# Who runs is decided by the native daemon itself, not here. It holds a
# kernel lock on .daemon.lock in the run directory for as long as it lives
# (the kernel drops it when the process ends, so nothing is ever left
# behind). A second one waits up to 4 s for that lock: it takes over if the
# first one is on its way out (a stop or restart running at the same time),
# and otherwise leaves quietly. So "start" may launch it as often as it is
# called, from as many places at once as it likes: exactly one keeps running.
# Checking for a running daemon here first, and launching only if there is
# none, cannot work: between the check and the launch another start or a
# stop can come in.
# The shell daemon below is only the fallback, for a unit where the native
# one does not pass its self-test; it keeps the simple pid file check.
cmd_start() {
    mkdir -p "$RUN_DIR" || return 1
    # a shell daemon that runs already (DASH_NATIVE=off until now): leave it be.
    # (Asked positively: a native daemon that has just ended is not one.)
    if _sp=$(daemon_pid) && grep -q "${0##*/}" "/proc/$_sp/cmdline" 2>/dev/null; then
        return 0
    fi
    if native_find; then
        # it reads the same dashboard.conf and the same DASH_* overrides
        if command -v setsid > /dev/null 2>&1; then
            setsid "$NATIVE_BIN" run < /dev/null > /dev/null 2>&1 &
        else
            "$NATIVE_BIN" run < /dev/null > /dev/null 2>&1 &
        fi
    else
        daemon_pid > /dev/null && return 0
        _self="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
        if command -v setsid > /dev/null 2>&1; then
            setsid sh "$_self" run < /dev/null > /dev/null 2>&1 &
        else
            sh "$_self" run < /dev/null > /dev/null 2>&1 &
        fi
    fi
    # "started" means: a daemon's pid file is there, so that a status or stop
    # right after this sees it. (6 s at most: a native daemon that takes over
    # from one being stopped may wait 4 s for it.)
    _n=0
    while ! daemon_pid > /dev/null && [ "$_n" -lt 60 ]; do
        nap
        _n=$((_n + NAP))
    done
    return 0
}

# True if PID leads its own process group (field 5 of /proc/PID/stat). That
# is the case when the daemon was started through setsid (cmd_start) or as a
# job of an interactive shell.
is_group_leader() {
    read -r _ _ _ _ _pg _ 2>/dev/null < "/proc/$1/stat" || return 1
    [ "$_pg" = "$1" ]
}

# Print the pids whose parent is PID (builtins only, no process is started)
# (In these reads "2>/dev/null" comes before "<": redirections are made from
# left to right, and the message about a process that has just gone would
# otherwise still reach the terminal.)
children_of() {
    for _st in /proc/[0-9]*/stat; do
        read -r _cp _ _ _cpp _ 2>/dev/null < "$_st" || continue
        [ "$_cpp" = "$1" ] && echo "$_cp"
    done
}

# The copy of the native daemon in the run directory (made when /data does
# not allow execution) goes with the daemon, unless one runs again by now: a
# start that overlapped this stop may have taken over.
drop_copy() {
    daemon_pid > /dev/null || rm -f "$RUN_DIR/$NATIVE_NAME"
}

cmd_stop() {
    _sp=$(daemon_pid) || { drop_copy; return 0; }
    _grp=""
    is_group_leader "$_sp" && _grp=$_sp
    kill "$_sp" 2>/dev/null             # TERM: cleanup() stops dbus-monitor and awk, removes the files
    _n=0
    while kill -0 "$_sp" 2>/dev/null && [ "$_n" -lt 30 ]; do
        nap
        _n=$((_n + NAP))
    done
    kill -0 "$_sp" 2>/dev/null || { drop_copy; return 0; }

    # It does not react. SIGKILL cannot be trapped, so nothing would stop
    # dbus-monitor and awk: they would live on, and so would the monitor's
    # match rules on the bus. Take the daemon's whole process group, and
    # whatever it started that is still its child.
    # ("kill -9 -PGID", signal first and no "--": that form is understood by
    # every kill there is; "--" is not, by an old BusyBox.)
    _kids=$(children_of "$_sp")
    if [ -n "$_grp" ]; then
        kill -9 "-$_grp" 2>/dev/null
    else
        kill -9 "$_sp" 2>/dev/null
    fi
    for _k in $_kids; do
        kill -9 "$_k" 2>/dev/null
    done
    # Its files, which it could not remove itself: only if the pid file still
    # names it. A native daemon started meanwhile may have taken over and be
    # writing them. (Left behind, a stale pid file is harmless: daemon_pid
    # checks the process.)
    _pf=""
    read -r _pf 2>/dev/null < "$PIDFILE"
    if [ "$_pf" = "$_sp" ]; then
        rm -f "$OUT" "$TMP" "$FRAG" "$FIFO" "$PIDFILE"
    fi
    drop_copy
    return 0
}

cmd_status() {
    if _sp=$(daemon_pid); then
        if grep -q "$NATIVE_NAME" "/proc/$_sp/cmdline" 2>/dev/null; then
            echo "running (pid $_sp, native)"
        else
            echo "running (pid $_sp, shell)"
        fi
        [ -r "$OUT" ] && cat "$OUT"
        return 0
    fi
    echo "stopped"
    return 1
}

# ──────────────────────────────────────────────────────────────
# Time: NOW_CS = uptime in 1/100 s (no fork: /proc/uptime + builtin read)
# ──────────────────────────────────────────────────────────────
now_cs() {
    read -r _up _ < /proc/uptime
    _fr="${_up#*.}00"
    _fr="${_fr%"${_fr#??}"}"            # first two digits
    NOW_CS=$(( ${_up%%.*} * 100 + 1$_fr - 100 ))
}

# num VAR VALUE — VAR=VALUE if VALUE is a JSON-safe number, else VAR=null
num() {
    case "$2" in
        ''|*[!0-9.eE+-]*) eval "$1=null" ;;
        [0-9]*|-[0-9]*)   eval "$1=\$2" ;;
        *)                eval "$1=null" ;;
    esac
}

# ──────────────────────────────────────────────────────────────
# Signal reader: dbus-monitor -> FIFO -> awk
#
# awk lives as long as the daemon and remembers the newest value of every
# signal. Lines it understands besides dbus-monitor output:
#     T   dump the current state to $FRAG
#     R   forget the fast channels (their values are stale after an idle
#         period; the slow ones stay valid because they were still monitored)
# ──────────────────────────────────────────────────────────────
MON_PID=""
MON_MODE=""                             # wide (everything) | narrow (slow signals only)
AWK_PID=""
MON_NEXT=0                              # earliest time for the next monitor restart

start_awk() {
    awk -v FRAG="$FRAG" \
        -v RPM_S="$RPM_SCALE" -v RPM_O="$RPM_OFFSET" \
        -v THR_S="$THR_SCALE" -v THR_O="$THR_OFFSET" \
        -v STE_S="$STEER_SCALE" -v STE_O="$STEER_OFFSET" -v STE_G="$STEER_SIGNED" \
        -v LAT_S="$LATG_SCALE" -v LAT_O="$LATG_OFFSET" -v LAT_G="$LATG_SIGNED" \
        -v LON_S="$LONG_SCALE" -v LON_O="$LONG_OFFSET" -v LON_G="$LONG_SIGNED" \
        -v VSS_S="$VSS_SCALE" '
    # lim: the largest raw value the firmware itself accepts for an unsigned
    # channel (0 = no limit). Anything above it is "invalid" on the bus.
    function conv(name, scale, offset, sgn, fmt, lim,    v) {
        if (!(name in raw)) return "x"
        v = raw[name]
        if (sgn + 0 == 1) { if (v > 32767) v -= 65536 }
        else if (lim > 0 && v > lim) return "x"
        return sprintf(fmt, v * scale + offset)
    }
    # 32766 (0x7FFE) is what the firmware holds before the first CAN frame,
    # 32767 the invalid marker. Shown as an angle they would read 1676.6.
    function steer(    v) {
        if (!("SteWhlComp_An_Est" in raw)) return "x"
        v = raw["SteWhlComp_An_Est"]
        if (v == 32766 || v == 32767) return "x"
        return conv("SteWhlComp_An_Est", STE_S, STE_O, STE_G, "%.1f", 32765)
    }
    function rawof(name) { return (name in raw) ? raw[name] : "x" }
    function flag(name)  { return (name in raw) ? (raw[name] != 0 ? 1 : 0) : "x" }
    function dump() {
        # 6 converted values, 2 telltales, 6 raw values, signal counter, end marker
        printf "%s %s %s %s %s %s %s %s %s %s %s %s %s %s %d END\n", \
            conv("EngAout_N_Actl", RPM_S, RPM_O, 0, "%.0f", 0), \
            conv("ApedPos_Pc_ActlArb", THR_S, THR_O, 0, "%.1f", 0), \
            steer(), \
            conv("Lateral_Acceleration", LAT_S, LAT_O, LAT_G, "%.3f", 8191), \
            conv("VehLong_A_Actl", LON_S, LON_O, LON_G, "%.3f", 8191), \
            conv("Veh_V_ActlEng", VSS_S, 0, 0, "%.1f", 0), \
            flag("OilPressureWarning"), flag("BatteryChargingTelltale"), \
            rawof("EngAout_N_Actl"), rawof("ApedPos_Pc_ActlArb"), \
            rawof("SteWhlComp_An_Est"), rawof("Lateral_Acceleration"), \
            rawof("VehLong_A_Actl"), rawof("Veh_V_ActlEng"), nsig > FRAG
        close(FRAG)
    }
    BEGIN { cur = ""; nsig = 0 }
    $0 == "T" { dump(); next }
    $0 == "R" {
        delete raw["EngAout_N_Actl"]; delete raw["ApedPos_Pc_ActlArb"]
        delete raw["SteWhlComp_An_Est"]; delete raw["Lateral_Acceleration"]
        delete raw["VehLong_A_Actl"]; delete raw["Veh_V_ActlEng"]
        nsig = 0
        next
    }
    $1 == "signal" {
        i = index($0, "member=")
        cur = (i > 0) ? substr($0, i + 7) : ""
        sub(/[ ;].*$/, "", cur)
        sub(/_2$/, "", cur)                          # OilPressureWarning_2 -> OilPressureWarning
        if (cur == "BatteryChargingTelltale2") cur = "BatteryChargingTelltale"
        next
    }
    cur != "" && NF == 2 {
        if ($1 == "boolean") { raw[cur] = ($2 == "true") ? 1 : 0; nsig++ }
        else if (($1 == "uint16" || $1 == "int16" || $1 == "byte" || $1 == "uint32" || $1 == "int32") && $2 ~ /^-?[0-9]+$/) {
            raw[cur] = $2 + 0; nsig++
        }
        cur = ""
        next
    }
    { cur = "" }
    ' < "$FIFO" > /dev/null 2>&1 &
    AWK_PID=$!
}

# start_monitor wide|narrow
# Only signals this firmware really sends are matched (EngClnt_Te_Actl_2 and
# AirAmb_Te_Actl_2 never are, see the header).
start_monitor() {
    MON_MODE=$1
    # 3>&-: the monitor must not inherit our write end of the FIFO
    if [ "$1" = "wide" ]; then
        dbus-monitor --address "$DBUS_ADDR" \
            "type='signal',interface='com.jci.vbs.vdt'" \
            "type='signal',interface='com.jci.vbs.vwm',member='OilPressureWarning'" \
            "type='signal',interface='com.jci.vbs.vwm',member='OilPressureWarning_2'" \
            "type='signal',interface='com.jci.vbs.vwm',member='BatteryChargingTelltale'" \
            "type='signal',interface='com.jci.vbs.vwm',member='BatteryChargingTelltale2'" \
            > "$FIFO" 2> /dev/null 3>&- < /dev/null &
    else
        dbus-monitor --address "$DBUS_ADDR" \
            "type='signal',interface='com.jci.vbs.vwm',member='OilPressureWarning'" \
            "type='signal',interface='com.jci.vbs.vwm',member='OilPressureWarning_2'" \
            "type='signal',interface='com.jci.vbs.vwm',member='BatteryChargingTelltale'" \
            "type='signal',interface='com.jci.vbs.vwm',member='BatteryChargingTelltale2'" \
            > "$FIFO" 2> /dev/null 3>&- < /dev/null &
    fi
    MON_PID=$!
}

stop_monitor() {
    if [ -n "$MON_PID" ]; then
        kill "$MON_PID" 2>/dev/null
        wait "$MON_PID" 2>/dev/null
    fi
    MON_PID=""
}

# start_reader wide|narrow
start_reader() {
    rm -f "$FIFO" "$FRAG"
    mkfifo "$FIFO" || return 1
    start_awk                           # reader first: blocks in open() until we open for writing
    exec 3> "$FIFO"                     # our write end: keeps awk alive across monitor restarts
    start_monitor "$1"
    return 0
}

stop_reader() {
    stop_monitor
    exec 3>&-                           # awk sees EOF and exits
    if [ -n "$AWK_PID" ]; then
        kill "$AWK_PID" 2>/dev/null
        wait "$AWK_PID" 2>/dev/null
    fi
    AWK_PID=""
    rm -f "$FIFO" "$FRAG"
}

# Restart whatever died (called about once per second while active and
# every few seconds while idle)
check_reader() {
    if [ -z "$AWK_PID" ] || ! kill -0 "$AWK_PID" 2>/dev/null; then
        _m=${MON_MODE:-wide}
        stop_reader
        start_reader "$_m"
        MON_NEXT=$((NOW_CS + 500))
        return
    fi
    if ! kill -0 "$MON_PID" 2>/dev/null && [ "$NOW_CS" -ge "$MON_NEXT" ]; then
        wait "$MON_PID" 2>/dev/null
        start_monitor "$MON_MODE"       # D-Bus not up yet, or it restarted
        MON_NEXT=$((NOW_CS + 500))
    fi
}

# ──────────────────────────────────────────────────────────────
# Polled sources
# ──────────────────────────────────────────────────────────────
# bcm METHOD [ARG] — the reply's last word is the value ("   uint32 72")
bcm() {
    # shellcheck disable=SC2086
    _out=$(dbus-send --print-reply --reply-timeout="$DASH_DBUS_TIMEOUT" --address="$DBUS_ADDR" \
        --type=method_call --dest=com.jci.vbs.bcm /com/jci/vbs/bcm \
        "com.jci.vbs.bcm.$1" $2 2>/dev/null 3>&-) || _out=""
    BCM_VAL="${_out##*[!0-9]}"
    case "$_out" in *"method return"*) ;; *) BCM_VAL="" ;; esac
}

poll_gps() {
    _out=$(dbus-send --print-reply --reply-timeout="$DASH_DBUS_TIMEOUT" --address="$DBUS_ADDR" \
        --type=method_call --dest=com.jci.lds.data /com/jci/lds/data \
        com.jci.lds.data.GetPosition 2>/dev/null 3>&-) || _out=""
    gps_fix=null; gps_lat=null; gps_lon=null; gps_hdg=null; gps_spd=null
    # shellcheck disable=SC2086
    set -- $_out
    while [ $# -gt 0 ]; do
        case "$1" in reply_serial=*) shift; break ;; esac
        shift
    done
    # int32 ACC uint64 UTC double LAT double LON int32 ALT double HDG double VEL ...
    [ $# -ge 14 ] || return
    num gps_fix "$2"
    # accuracy 0 = POSITION_UNKNOWN: the numbers are not a position
    [ "$gps_fix" = "0" ] || [ "$gps_fix" = "null" ] && return
    # dbus-send prints doubles with 6 significant digits, so lat/lon are only
    # good to ~0.001 degree here; heading and speed are unaffected.
    num gps_lat "$6"; num gps_lon "$8"; num gps_hdg "${12}"; num gps_spd "${14}"
}

# Coolant: not on D-Bus on this firmware (see the header). libjcimod_vdt.so
# writes the byte it gets from the CAN bus into the shared memory database,
# entry EngClnt_Te_Actl of vdm_vdt_current_data, and smdb-read prints it.
SMDB_READ=""
find_smdb_read() {
    if [ -n "$DASH_SMDB_READ" ]; then
        SMDB_READ=$DASH_SMDB_READ               # bench tests
    elif [ -x /jci/smdb/smdb-read ]; then
        SMDB_READ=/jci/smdb/smdb-read
    else
        SMDB_READ=$(command -v smdb-read 2>/dev/null)
    fi
}

is_int() {
    case "${1#-}" in ''|*[!0-9]*) return 1 ;; esac
    return 0
}

# smdb-read creates the database if it does not exist yet (the vendor library
# opens it with O_CREAT), and it would do so as root, while the services that
# own it run as another user. So it is only run once the object is there and
# has data: in /dev/shm or, as glibc's shm_open() does when that is no tmpfs,
# in another tmpfs. The owner makes the semaphore last, after filling the
# object, so in the first half minute after boot the semaphore must be there
# too (glibc keeps it next to the object as "sem.smdb_<name>"; that name is
# inferred, hence only then). Should the object be nowhere this script looks,
# the tool is allowed after two minutes of uptime, by which time the services
# have long created it.
smdb_there() {      # DIR
    [ -s "$1/smdb_vdm_vdt_current_data" ] || return 1
    [ "$_ss_s" -ge 30 ] || [ -e "$1/sem.smdb_vdm_vdt_current_data" ]
}
smdb_safe() {
    read -r _ss_up _ < /proc/uptime 2>/dev/null || _ss_up=999
    _ss_s=${_ss_up%%.*}
    case "$_ss_s" in ''|*[!0-9]*) _ss_s=999 ;; esac
    smdb_there /dev/shm && return 0
    while read -r _ _ss_mp _ss_ft _; do
        case "$_ss_ft" in
            tmpfs|shm) smdb_there "$_ss_mp" && return 0 ;;
        esac
    done < /proc/mounts 2>/dev/null
    [ "$_ss_s" -ge 120 ]
}

poll_cool() {
    v_cool=null; r_cool=null
    [ -n "$SMDB_READ" ] || return
    [ -n "$DASH_SMDB_READ" ] || smdb_safe || return
    _out=$(LD_LIBRARY_PATH="/jci/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$SMDB_READ" -n vdm_vdt_current_data -e EngClnt_Te_Actl 2>/dev/null 3>&-) || return
    # the value is the last word of the output
    # shellcheck disable=SC2086
    set -- $_out
    while [ $# -gt 1 ]; do shift; done
    case "$1" in ''|*[!0-9]*|????*) return ;; esac
    r_cool=$1
    # 0 is the database default (nothing received yet), 255 "invalid" on the bus
    [ "$1" -gt 0 ] && [ "$1" -lt 255 ] || return
    if is_int "$COOL_SCALE" && is_int "$COOL_OFFSET"; then
        v_cool=$(($1 * COOL_SCALE + COOL_OFFSET))
    else
        _out=$(awk -v r="$1" -v s="$COOL_SCALE" -v o="$COOL_OFFSET" \
            'BEGIN { printf "%.0f", r * s + o }' 2>/dev/null 3>&-)
        num v_cool "$_out"
    fi
}

# Which gearbox is this? GetGearPos is the manual gearbox's position (the
# firmware calls it GearPosMt; an automatic is expected to leave it at 0,
# which the binaries cannot confirm). GetTransmChangeLeverPosition is the
# automatic's selector, but it reads 1 ("P") on a manual car as well: that
# is the value libjcimod_bcm.so starts with, and it is only replaced when
# the CAN bus reports a selector position.
#   lever 2..6           -> automatic (a manual never gets there)
#   a gear, lever 0 or 1 -> manual
# Until one of the two has been seen the answer is open ("gearbox":null) and
# the page decides by the same rule for itself: lever 2..6 reads as an
# automatic, anything else as a manual (gearText() in dashboard.html).
# DASH_GEARBOX=at|mt in the config settles it.
detect_gearbox() {
    [ "$GBOX_FIXED" = "1" ] && return
    case "$lever" in
        [2-6]) GBOX="at" ;;
        0|1)   [ -z "$GBOX" ] && case "$gear" in [1-8]|14) GBOX="mt" ;; esac ;;
    esac
    return 0
}

# ──────────────────────────────────────────────────────────────
# Reader detection (on-demand mode)
# ──────────────────────────────────────────────────────────────
ATIME_OK=0
STAMP0=""
ARMED=0

atime_selftest() {
    _f="$RUN_DIR/.dashboard.atime.$$"
    echo x > "$_f" 2>/dev/null || return 1
    touch -t "$STAMP_OLD" "$_f" 2>/dev/null || { rm -f "$_f"; return 1; }
    STAMP0=$(stat -c %X "$_f" 2>/dev/null)
    cat "$_f" > /dev/null 2>&1
    _a=$(stat -c %X "$_f" 2>/dev/null)
    rm -f "$_f"
    [ -n "$STAMP0" ] && [ -n "$_a" ] && [ "$_a" != "$STAMP0" ]
}

# Mark the published file as unread
arm() {
    [ "$ATIME_OK" = "1" ] || return
    touch -t "$STAMP_OLD" "$OUT" 2>/dev/null && ARMED=1
}

# True if the file armed earlier has been read since
was_read() {
    [ "$ARMED" = "1" ] || return 1
    ARMED=0
    _a=$(stat -c %X "$OUT" 2>/dev/null) || return 1
    [ -n "$_a" ] && [ "$_a" != "$STAMP0" ]
}

# ──────────────────────────────────────────────────────────────
# Publishing
# ──────────────────────────────────────────────────────────────
SEQ=0
EPOCH=0
HZ_NOW=0
HZ_COUNT=0

v_rpm=null; v_thr=null; v_steer=null; v_latg=null; v_long=null; v_cool=null; v_vss=null
v_oil=null; v_batt=null
r_rpm=null; r_thr=null; r_steer=null; r_latg=null; r_long=null; r_cool=null; r_vss=null
n_sig=0
speed=null; gear=null; lever=null; brake=null; r_spd=null
VDT_SEEN=0
gps_fix=null; gps_lat=null; gps_lon=null; gps_hdg=null; gps_spd=null
BCM_N=0

read_signals() {
    t_end=""
    read -r t1 t2 t3 t4 t5 t6 t7 t8 t9 t10 t11 t12 t13 t14 t15 t_end < "$FRAG" 2>/dev/null
    [ "$t_end" = "END" ] || return      # missing or half-written: keep the last values
    num v_rpm "$t1"; num v_thr "$t2"; num v_steer "$t3"; num v_latg "$t4"
    num v_long "$t5"; num v_vss "$t6"
    num v_oil "$t7"; num v_batt "$t8"
    num r_rpm "$t9"; num r_thr "$t10"; num r_steer "$t11"; num r_latg "$t12"
    num r_long "$t13"; num r_vss "$t14"
    num n_sig "$t15"
}

# "gear" is the manual gearbox position, "lever" the automatic's selector,
# both as the BCM reports them; "gearbox" says which one counts ("at", "mt"
# or null while that is still open). "ambient" has no source on this
# firmware and is always null.
publish() {
    case "$GBOX" in
        at|mt) _gb="\"$GBOX\"" ;;
        *)     _gb=null ;;
    esac
    printf '{"speed":%s,"rpm":%s,"gear":%s,"lever":%s,"gearbox":%s,"throttle":%s,"brake":%s,"steering":%s,"lat_g":%s,"lon_g":%s,"coolant":%s,"ambient":null,"oil_warn":%s,"batt_warn":%s,"gps_lat":%s,"gps_lon":%s,"gps_heading":%s,"gps_speed":%s,"gps_fix":%s,"ts":%s,"seq":%s,"hz":%s,"sig":%s,"raw":{"rpm":%s,"thr":%s,"steer":%s,"latg":%s,"lon":%s,"cool":%s,"vss":%s,"spd":%s,"gear":%s,"lever":%s}}\n' \
        "$speed" "$v_rpm" "$gear" "$lever" "$_gb" "$v_thr" "$brake" "$v_steer" "$v_latg" "$v_long" "$v_cool" "$v_oil" "$v_batt" \
        "$gps_lat" "$gps_lon" "$gps_hdg" "$gps_spd" "$gps_fix" "$EPOCH" "$SEQ" "$HZ_NOW" "$n_sig" \
        "$r_rpm" "$r_thr" "$r_steer" "$r_latg" "$r_long" "$r_cool" "$r_vss" "$r_spd" "$gear" "$lever" \
        > "$TMP" 2>/dev/null && mv -f "$TMP" "$OUT" 2>/dev/null
}

publish_idle() {
    printf '{"idle":true,"ts":%s,"seq":%s}\n' "$EPOCH" "$SEQ" > "$TMP" 2>/dev/null && mv -f "$TMP" "$OUT" 2>/dev/null
}

tick() {
    SEQ=$((SEQ + 1))
    echo T 2>/dev/null >&3              # ask awk for a fresh signal snapshot

    if [ $((SEQ % DASH_BCM_EVERY)) -eq 0 ]; then
        bcm GetCarSpeed "uint32:$SPEED_UNIT"
        num r_spd "$BCM_VAL"
        bcm GetBrkPedalDepressedStatus
        num brake "$BCM_VAL"
        # manual gear and automatic selector take turns: one launch, not two
        BCM_N=$((BCM_N + 1))
        if [ $((BCM_N % 2)) -eq 0 ]; then
            bcm GetGearPos
            num gear "$BCM_VAL"
        else
            bcm GetTransmChangeLeverPosition
            num lever "$BCM_VAL"
        fi
        detect_gearbox
    fi
    if [ $((SEQ % DASH_GPS_EVERY)) -eq "$GPS_PHASE" ]; then
        poll_gps
    fi
    if [ $((SEQ % DASH_COOL_EVERY)) -eq "$COOL_PHASE" ]; then
        poll_cool
    fi

    read_signals                        # written by awk while we were polling (or a tick ago)
    was_read && LAST_SEEN=$NOW_CS       # the page read the file armed a second ago

    # Prefer VDT wheel speed (pushed signal, always current) over BCM
    # (polled, may return a stale cached value when stationary on some firmware)
    if [ "$v_vss" != "null" ]; then
        VDT_SEEN=1
        speed=$v_vss
    elif [ "$VDT_SEEN" = "0" ]; then
        # VDT hasn't pushed yet (cold start); BCM may hold a stale cached value
        speed=null
    elif [ "$r_spd" = "null" ]; then
        speed=null
    elif [ "$SPEED_DIV" = "1" ]; then
        speed=$r_spd
    else
        _t=$((r_spd * 10 / SPEED_DIV))
        speed="$((_t / 10)).$((_t % 10))"
    fi
    publish
}

# ──────────────────────────────────────────────────────────────
# Main loop
# ──────────────────────────────────────────────────────────────
MODE=idle
HAVE_USLEEP=0
IDLE_N=0

go_active() {
    MODE=active
    echo R 2>/dev/null >&3              # fast channels are stale after an idle period
    stop_monitor
    start_monitor wide
    now_cs
    LAST_SEEN=$NOW_CS
    SEC_MARK=$NOW_CS
    MON_NEXT=$((NOW_CS + 500))
    HZ_COUNT=0
    HZ_NOW=0
    poll_cool                           # the first view opens on it: do not wait 2 s
}

go_idle() {
    MODE=idle
    IDLE_N=0
    stop_monitor
    start_monitor narrow
    v_rpm=null; v_thr=null; v_steer=null; v_latg=null; v_long=null; v_vss=null; v_cool=null
    r_rpm=null; r_thr=null; r_steer=null; r_latg=null; r_long=null; r_vss=null; r_cool=null
    speed=null; gear=null; lever=null; brake=null; r_spd=null
    gps_fix=null; gps_lat=null; gps_lon=null; gps_hdg=null; gps_spd=null
}

cleanup() {
    trap - EXIT INT TERM HUP
    stop_reader
    rm -f "$OUT" "$TMP" "$PIDFILE"
    exit 0
}

cmd_run() {
    mkdir -p "$RUN_DIR" || exit 1
    if _other=$(daemon_pid) && [ "$_other" != "$$" ]; then
        exit 0
    fi
    echo $$ > "$PIDFILE"
    trap cleanup EXIT INT TERM HUP
    trap '' PIPE                        # a dead awk must not kill us through the FIFO
    exec 3>&-
    command -v usleep > /dev/null 2>&1 && HAVE_USLEEP=1
    find_smdb_read

    if [ "$DASH_IDLE" = "auto" ] && atime_selftest; then
        ATIME_OK=1
    fi
    EPOCH=$(date +%s)
    now_cs
    LAST_SEEN=$NOW_CS
    SEC_MARK=$NOW_CS
    if [ "$ATIME_OK" = "1" ]; then
        start_reader narrow
    else
        start_reader wide
        MODE=active
        poll_cool
    fi
    MON_NEXT=$((NOW_CS + 500))

    while :; do
        if [ "$MODE" = "idle" ]; then
            # ── idle: one heartbeat per second, nothing is polled ──
            if was_read; then
                go_active
                continue
            fi
            SEQ=$((SEQ + 1))
            EPOCH=$(date +%s)
            publish_idle
            arm
            IDLE_N=$((IDLE_N + 1))
            if [ $((IDLE_N % 5)) -eq 0 ]; then
                now_cs
                check_reader
            fi
            sleep 1
            continue
        fi

        # ── active ──
        now_cs
        _t0=$NOW_CS
        tick
        HZ_COUNT=$((HZ_COUNT + 1))
        now_cs
        if [ $((NOW_CS - SEC_MARK)) -ge 100 ] || [ "$NOW_CS" -lt "$SEC_MARK" ]; then
            # once per second: wall clock, measured rate, health, reader probe
            SEC_MARK=$NOW_CS
            HZ_NOW=$HZ_COUNT
            HZ_COUNT=0
            EPOCH=$(date +%s)
            check_reader
            arm
            if [ "$ATIME_OK" = "1" ] && [ $((NOW_CS - LAST_SEEN)) -gt $((DASH_LINGER * 100)) ]; then
                go_idle
                continue
            fi
            now_cs
        fi
        _rem=$((PERIOD_CS - (NOW_CS - _t0)))
        if [ "$_rem" -gt 0 ] && [ "$HAVE_USLEEP" = "1" ]; then
            usleep $((_rem * 10000))
        fi
    done
}

case "${1:-start}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_stop; cmd_start ;;
    status)  cmd_status ;;
    run)     cmd_run ;;
    *)       echo "usage: $0 [start|stop|restart|status|run]" >&2; exit 2 ;;
esac
