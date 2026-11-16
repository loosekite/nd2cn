#!/bin/sh
# nd2cn — extended probe: a READ-ONLY survey of what this particular car
# offers. Sourced by install.sh (after lib/helpers.sh); it runs only when
# asked for:
#     an (empty) file named PROBE in the root of the USB stick, or
#     sh install.sh --probe
#
# It answers questions that cannot be settled from the firmware image alone:
#   - which CMU board this is (old / new "WCP" board) and so which GNSS
#     receiver is in use; whether plugin 14 (BeiDou) has any effect here
#   - whether the CMU feeds its own GPS position to CarPlay
#   - which vehicle signals this car really sends, how often, and with what
#     values (brake pressure, yaw rate, intake temperature, fuel level, ...)
#   - how long one dbus-send / smdb-read launch takes (dashboard data rate)
#
# What it does, and nothing else:
#   - reads files (/proc, /data_persist, /tmp/devmgr_config_edit.xml)
#   - calls "Get..." and Introspect methods over D-Bus (they only return state)
#   - reads entries of the shared memory database with smdb-read
#   - listens to D-Bus signals for PROBE_SECS seconds with dbus-monitor
#   - shows one dialog during that time, asking for brake / clutch /
#     steering / throttle so that those channels show up
# It changes no setting and writes only below /tmp (RAM). The summary goes
# into the install log; the raw capture is copied next to it on the USB
# stick by install.sh (nd2cn-signals.txt).
#
# POSIX sh for BusyBox 1.19.2 ash. Every step is best-effort: a missing tool
# or a service that does not answer is logged and skipped, never fatal.

ND2CN_PROBE_DIR="${TMPDIR:-/tmp}/nd2cn-probe"
ND2CN_PROBE_RAW="$ND2CN_PROBE_DIR/signals.txt"
ND2CN_PROBE_SECS=12
ND2CN_PROBE_RAW_MAX_KB=3072             # at most this much of the capture goes to the USB stick

_PR_SMDB="$FIRMWARE_ROOT/jci/smdb/smdb-read"
_PR_SMDB_DB="vdm_vdt_current_data"
# entries of the shared memory database worth a look (names from
# /jci/smdb/vdm_vdt_current_data.xml). Every read is a process launch, so the
# ones the driver is asked to move are read every round and the rest only
# every fourth round: a brake press must not fall between two samples.
_PR_SMDB_FAST="BrakePressure BrkLevel SteeringWheel YawRate AccelPedalPosition EngineSpeed DR_ClutchSW DR_NeutralSW"
_PR_SMDB_SLOW="VehicleSpeed LongitudinalAccelerometer LateralAcceleration BrakePressure_Qf EngClnt_Te_Actl DR_IntakeAirTemp EngineLoad FuelGaugePosition FuelPulse Odocount TransmissionGearPosition TransmChangeLeverPosition DR_Slope Battery_StateOfCharge AC_Pressure LatitudeByGPS LongitudeByGPS"
_PR_SMDB_KEYS="$_PR_SMDB_FAST $_PR_SMDB_SLOW"

# ── logging: one line, or a block with a single timestamp (no fork per line) ──
_pr() { nd2cn_log "PROBE $1"; }
_pr_block() {
    _pb_ts=$(date '+%Y-%m-%d %H:%M:%S')
    sed "s/^/[$_pb_ts] PROBE $1/" >> "$ND2CN_LOG" 2>/dev/null
}

# uptime in 1/100 s, builtins only (same method as dashboard-daemon.sh)
_pr_now() {
    read -r _pn_up _ < /proc/uptime 2>/dev/null || { PR_CS=0; return; }
    _pn_fr="${_pn_up#*.}00"
    _pn_fr="${_pn_fr%"${_pn_fr#??}"}"
    PR_CS=$(( ${_pn_up%%.*} * 100 + 1$_pn_fr - 100 ))
}

# _pr_dbus DEST PATH METHOD [ARG] — reply on one line (empty if no answer)
_pr_dbus() {
    # shellcheck disable=SC2086
    dbus-send --print-reply --reply-timeout=2000 --address="$DBUS_ADDR" \
        --type=method_call --dest="$1" "$2" "$3" $4 2>&1 | tr -s ' \n\t' '   '
}

# _pr_smdb KEY — the value (last word of the tool's output), empty on failure
_pr_smdb() {
    _ps_out=$(LD_LIBRARY_PATH="$FIRMWARE_ROOT/jci/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$_PR_SMDB" -n "$_PR_SMDB_DB" -e "$1" 2>/dev/null) || { echo ""; return; }
    # shellcheck disable=SC2086
    set -- $_ps_out
    while [ $# -gt 1 ]; do shift; done
    echo "$1"
}

# ── 1. board, CPU, tools ──
_pr_hardware() {
    _pr "--- hardware ---"
    if [ -f "$FIRMWARE_ROOT/jci/scripts/get_board_type.sh" ]; then
        sh "$FIRMWARE_ROOT/jci/scripts/get_board_type.sh" > /dev/null 2>&1
        _ph_rc=$?
        case "$_ph_rc" in
            2) _pr "board type: 2 = NEW board (WCP capable, u-blox GNSS, sm_WCP.conf)" ;;
            1) _pr "board type: 1 = OLD board (no WCP, GNSS is not the u-blox, sm.conf)" ;;
            *) _pr "board type: get_board_type.sh exit $_ph_rc (unexpected)" ;;
        esac
    else
        _pr "board type: get_board_type.sh not found"
    fi
    if [ -e "$FIRMWARE_ROOT/data_persist/ublox.txt" ]; then
        _pr "ublox.txt: present (autostart saw the new board)"
    else
        _pr "ublox.txt: absent"
    fi
    _pr "antenna type file: $(cat "$FIRMWARE_ROOT/data_persist/lds_AntennaType.txt" 2>/dev/null || echo 'not readable')"
    _pr "cpu cores: $(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
    grep -i -E '^(Hardware|model name|Processor|BogoMIPS|Revision)' /proc/cpuinfo 2>/dev/null | _pr_block "cpuinfo: "
    grep -E '^(MemTotal|MemFree|Cached)' /proc/meminfo 2>/dev/null | _pr_block "meminfo: "
    _pr "loadavg: $(cat /proc/loadavg 2>/dev/null)"
    # which service manager configuration is running, and with which GNSS argument
    # shellcheck disable=SC2009  # BusyBox 1.19.2 on the CMU: no pgrep to rely on
    ps 2>/dev/null | grep -E '/jci/sm/sm |svcjcilds|GPS=' | grep -v grep | _pr_block "ps: "
    _pr "busybox applets: $( (busybox --list 2>/dev/null || busybox 2>&1 | sed '1,/defined functions/d') | tr -s ' ,\n\t' '    ')"
    _pr "tools: $(for _t in dbus-send dbus-monitor usleep nc httpd awk stat mkfifo setsid timeout openssl sha1sum base64 gzip; do command -v "$_t" > /dev/null 2>&1 && printf '%s ' "$_t"; done)"
}

# ── 2. GNSS receiver and what it tracks ──
_pr_gnss() {
    _pr "--- gnss ---"
    _pr "GetGPSFirmwareVersion: $(_pr_dbus com.jci.lds.data /com/jci/lds/data com.jci.lds.data.GetGPSFirmwareVersion)"
    _pr "GetSatelliteInfo: $(_pr_dbus com.jci.lds.data /com/jci/lds/data com.jci.lds.data.GetSatelliteInfo)"
    _pr "GetPosition: $(_pr_dbus com.jci.lds.data /com/jci/lds/data com.jci.lds.data.GetPosition)"
    _pr "GetSelectedGPS: $(_pr_dbus com.jci.lds.control /com/jci/lds/control com.jci.lds.control.GetSelectedGPS_sync)"
    # u-blox only: receiver version, mode, and the satellite list. Each entry
    # of svinfo starts with the GNSS id (0 GPS, 1 SBAS, 3 BeiDou, 5 QZSS,
    # 6 GLONASS), so this shows whether BeiDou is really tracked.
    _pr "GetUbloxDiag: $(_pr_dbus com.jci.lds.data /com/jci/lds/data com.jci.lds.data.GetUbloxDiag | cut -c1-1800)"
}

# ── 3. does the CMU hand its GPS position to CarPlay? ──
_pr_carplay() {
    _pr "--- carplay location feed ---"
    _pc_f="$FIRMWARE_ROOT/tmp/devmgr_config_edit.xml"
    if [ -r "$_pc_f" ]; then
        grep -E 'CARPLAY_LOCATION|boGPRMCDataStatusNotification' "$_pc_f" | \
            sed 's/<[^>]*>/ /g' | tr -s ' \t' '  ' | _pr_block "devmgr:"
    else
        _pr "devmgr: $_pc_f not readable"
    fi
}

# ── 4. cost of one process launch (decides the dashboard's polling design) ──
_pr_timing() {
    _pr "--- timing ---"
    _pr_now; _pt_a=$PR_CS
    for _pt_i in 1 2 3 4 5; do
        dbus-send --print-reply --reply-timeout=2000 --address="$DBUS_ADDR" --type=method_call \
            --dest=com.jci.vbs.bcm /com/jci/vbs/bcm com.jci.vbs.bcm.GetGearPos > /dev/null 2>&1
    done
    _pr_now; _pt_b=$PR_CS
    _pr "dbus-send: 5 calls in $(( (_pt_b - _pt_a) * 10 )) ms"
    if [ -x "$_PR_SMDB" ]; then
        for _pt_i in 1 2 3 4 5; do _pr_smdb EngClnt_Te_Actl > /dev/null; done
        _pr_now
        _pr "smdb-read: 5 reads in $(( (PR_CS - _pt_b) * 10 )) ms"
    else
        _pr "smdb-read: $_PR_SMDB not found"
    fi
}

# ── 5. interfaces as the services describe themselves (raw file only) ──
_pr_introspect() {
    for _pi in "com.jci.vbs.bcm /com/jci/vbs/bcm" "com.jci.vbs.vdt /com/jci/vbs/vdt" \
               "com.jci.vbs.vwm /com/jci/vbs/vwm" "com.jci.lds.data /com/jci/lds/data"; do
        # shellcheck disable=SC2086
        set -- $_pi
        echo "### INTROSPECT $1 $2"
        dbus-send --print-reply --reply-timeout=2000 --address="$DBUS_ADDR" --type=method_call \
            --dest="$1" "$2" org.freedesktop.DBus.Introspectable.Introspect 2>&1
    done >> "$ND2CN_PROBE_RAW" 2>/dev/null
}

# ── 6. live capture: D-Bus signals + shared memory values while the driver
#       works the controls ──
# shellcheck disable=SC2154  # the per-key variables are set through eval
_pr_capture() {
    _pr "--- live capture (${ND2CN_PROBE_SECS} s) ---"
    echo "### SIGNALS ${ND2CN_PROBE_SECS} s" >> "$ND2CN_PROBE_RAW"
    dbus-monitor --address "$DBUS_ADDR" "type='signal'" >> "$ND2CN_PROBE_RAW" 2> /dev/null < /dev/null &
    _pc_mon=$!

    if [ -x "$JCI_DIALOG" ]; then
        killall jci-dialog 2>/dev/null || :
        "$JCI_DIALOG" --info --title="nd2cn DATA PROBE (${ND2CN_PROBE_SECS} s)" \
            --text="Car parked, NEUTRAL, handbrake ON.\n\nNow, for ${ND2CN_PROBE_SECS} seconds:\n- press and HOLD the BRAKE 2 s (soft, then hard)\n- press the CLUTCH\n- turn the STEERING WHEEL left and right\n- tap the THROTTLE" \
            --ok-label="OK" > /dev/null 2>&1 &
    fi

    # shared memory values: sample them round after round until the time is up
    _pr_now; _pc_end=$((PR_CS + ND2CN_PROBE_SECS * 100)); _pc_rounds=0
    if [ -x "$_PR_SMDB" ] && [ "$PR_CS" -gt 0 ]; then
        while :; do
            if [ $((_pc_rounds % 4)) -eq 0 ]; then _pc_set=$_PR_SMDB_KEYS; else _pc_set=$_PR_SMDB_FAST; fi
            for _pc_k in $_pc_set; do
                _pc_v=$(_pr_smdb "$_pc_k")
                case "$_pc_v" in ''|*[!0-9-]*) continue ;; esac
                eval "_pc_seen=\${_pc_n_$_pc_k:-0}"
                if [ "$_pc_seen" = "0" ]; then
                    eval "_pc_first_$_pc_k=\$_pc_v; _pc_min_$_pc_k=\$_pc_v; _pc_max_$_pc_k=\$_pc_v"
                else
                    eval "[ \"\$_pc_v\" -lt \"\$_pc_min_$_pc_k\" ] && _pc_min_$_pc_k=\$_pc_v"
                    eval "[ \"\$_pc_v\" -gt \"\$_pc_max_$_pc_k\" ] && _pc_max_$_pc_k=\$_pc_v"
                fi
                eval "_pc_n_$_pc_k=\$((_pc_seen + 1))"
            done
            _pc_rounds=$((_pc_rounds + 1))
            _pr_now
            [ "$PR_CS" -ge "$_pc_end" ] && break
            [ "$_pc_rounds" -ge 20000 ] && break       # belt and braces: never loop forever
        done
    else
        sleep "$ND2CN_PROBE_SECS"
    fi

    kill "$_pc_mon" 2>/dev/null
    wait "$_pc_mon" 2>/dev/null
    killall jci-dialog 2>/dev/null || :

    # shared memory: first value, range, and whether it moved
    _pr "smdb: $_pc_rounds rounds over ${ND2CN_PROBE_SECS} s"
    for _pc_k in $_PR_SMDB_KEYS; do
        eval "_pc_seen=\${_pc_n_$_pc_k:-0}"
        if [ "$_pc_seen" = "0" ]; then
            _pr "smdb $_pc_k: no value"
            continue
        fi
        eval "_pc_a=\$_pc_first_$_pc_k; _pc_lo=\$_pc_min_$_pc_k; _pc_hi=\$_pc_max_$_pc_k"
        if [ "$_pc_lo" = "$_pc_hi" ]; then
            _pr "smdb $_pc_k: constant $_pc_a"
        else
            _pr "smdb $_pc_k: MOVED first=$_pc_a min=$_pc_lo max=$_pc_hi"
        fi
    done

    # signals: count, rate, and the range of the first argument, per member
    _pr "signals: $(grep -c '^signal' "$ND2CN_PROBE_RAW" 2>/dev/null) messages, $(wc -c < "$ND2CN_PROBE_RAW" 2>/dev/null) bytes raw"
    awk -v SECS="$ND2CN_PROBE_SECS" '
        /^### SIGNALS/ { on = 1; next }
        !on { next }
        $1 == "signal" {
            i = index($0, "interface="); ifc = (i > 0) ? substr($0, i + 10) : "?"; sub(/[ ;].*$/, "", ifc)
            m = index($0, "member=");    mem = (m > 0) ? substr($0, m + 7)  : "?"; sub(/[ ;].*$/, "", mem)
            key = ifc "." mem; n[key]++; cur = key; arg = 0
            next
        }
        $1 == "method" || $1 == "error" { cur = ""; next }
        cur != "" {
            if (arg == 0) {
                typ[cur] = $1
                if (NF == 2 && $2 ~ /^-?[0-9]+(\.[0-9]+)?$/) {
                    v = $2 + 0
                    if (!(cur in lo) || v < lo[cur]) lo[cur] = v
                    if (!(cur in hi) || v > hi[cur]) hi[cur] = v
                    last[cur] = v
                } else if (NF == 2) {
                    last[cur] = $2
                }
            }
            arg++
        }
        END {
            for (k in n) {
                s = sprintf("%s n=%d rate=%.1f/s", k, n[k], n[k] / SECS)
                if (k in typ)  s = s " arg1=" typ[k]
                if (k in lo)   s = s sprintf(" min=%s max=%s", lo[k], hi[k])
                if (k in last) s = s " last=" last[k]
                print s
            }
        }' "$ND2CN_PROBE_RAW" 2>/dev/null | LC_ALL=C sort | _pr_block "sig "
}

# nd2cn_probe_wanted USB_ROOT — true if the extended probe was asked for
nd2cn_probe_wanted() {
    [ "${ND2CN_PROBE:-0}" = "1" ] && return 0
    [ -f "$1/PROBE" ] || [ -f "$1/probe" ] || [ -f "$1/PROBE.txt" ]
}

nd2cn_probe_extended() {
    # Needs the running car. ND2CN_PROBE_TEST=1 lets a bench test run it
    # against stand-in tools.
    if ! nd2cn_is_live && [ "${ND2CN_PROBE_TEST:-0}" != "1" ]; then
        nd2cn_log "PROBE skipped: offline root"
        return 0
    fi
    rm -rf "$ND2CN_PROBE_DIR"
    mkdir -p "$ND2CN_PROBE_DIR" || { nd2cn_log "PROBE skipped: cannot create $ND2CN_PROBE_DIR"; return 0; }
    : > "$ND2CN_PROBE_RAW"
    nd2cn_log "=== EXTENDED PROBE (read-only) ==="
    _pr_hardware
    _pr_gnss
    _pr_carplay
    _pr_timing
    _pr_introspect
    _pr_capture
    nd2cn_log "=== END EXTENDED PROBE ==="
    return 0
}

# nd2cn_probe_copy_raw DIR — put the raw capture next to the install log
nd2cn_probe_copy_raw() {
    [ -s "$ND2CN_PROBE_RAW" ] || return 0
    dd if="$ND2CN_PROBE_RAW" of="$1/nd2cn-signals.txt" bs=1024 count="$ND2CN_PROBE_RAW_MAX_KB" 2>/dev/null
}
