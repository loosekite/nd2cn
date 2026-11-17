#!/bin/sh
# nd2cn plugin: faster GPS position updates for CarPlay (EXPERIMENTAL)
#
# Stock, the position reaches the iPhone once per second and 1-3 s late:
#
#   u-blox M8 (sensor fusion at 10 Hz, UBX-CFG-HNR)
#     -> UBX-HNR-PVT, but only every 10th solution is output      = 1 Hz
#     -> jciLDS (com.jci.lds.data GetPosition)
#     -> CarPlay loop A: asks jciLDS every 1000 ms
#        (THLdsGetLocationInformation; builds $GPGGA/$GPRMC itself)
#     -> CarPlay loop B: sends to the iPhone every 1000 ms, only when the
#        sentence changed (THSendLocationInformation)
#
# This plugin changes three numbers (all found by disassembling 74.00.324A;
# nothing here has run on a car before):
#
#   1. /jci/lib/libjcilds-ublox.so, file offset 0x8d94
#      cfg_rates row 0 is the message-rate row the driver selects for the
#      whole run (driver_ReadGpsInfoThread -> LDS_UBX_cfg_set(1)). Its first
#      byte is the divider of UBX-HNR-PVT: 0x0a = every 10th solution.
#      0x01 = every solution = 10 Hz, 0x02 = 5 Hz, 0x05 = 2 Hz.
#      The GNSS fix itself (UBX-CFG-RATE, 1 Hz, GPS + BeiDou) is not touched;
#      the positions in between are the chip's own dead-reckoning output.
#   2. /jci/carplay/blmjcicarplay.so, file offset 0xa1514 (Lds::Init)
#      "mov r1, #1000" = period of loop A in ms.
#   3. /jci/carplay/blmjcicarplay.so, file offset 0xc5958
#      (RaceDeviceManager::StartLocationInformation)
#      "mov r1, #1000" = period of loop B in ms.
#
# RULE: loop A must not run faster than the GPS delivers. CarPlay stamps a
# sentence with "time since this UTC second was first seen", so polling an
# unchanged position sends the OLD position with a NEW time. The plugin
# therefore never sets loop A below the GPS period, patches the GPS library
# first and the CarPlay library only after that succeeded, and reverts in the
# opposite order.
#
# Settings: optional file resources/gps-fast.conf on the USB stick, lines
# KEY=NUMBER (CRLF line ends are fine):
#   HNR_DIV=1     1 = 10 Hz (default), 2 = 5 Hz, 5 = 2 Hz, 10 = stock 1 Hz
#   POLL_MS=100   loop A; default and minimum = HNR_DIV x 100
#   SEND_MS=50    loop B; 20..1000
# With HNR_DIV=10 only loop B is changed (safe on its own).
#
# Applies only to the new CMU board (get_board_type.sh exit 2: u-blox GNSS,
# sm_WCP.conf). On the old board the u-blox driver is not used and the car
# does not feed positions to CarPlay, so the plugin refuses.
#
# Shares libjcilds-ublox.so with plugin 14 (BeiDou). This plugin only ever
# writes its own byte there and reverts that byte on removal; it never
# restores the whole file. If plugin 14 alone is removed later (it restores
# the whole file), run the installer again to re-apply this plugin.
#
# Side effect: jciLDS writes one "UBX-INFO" log line per 60 positions, i.e.
# every 6 s at 10 Hz instead of once a minute.
#
# IN-USE LIBRARIES: both files are mapped by running services, so / stays rw
# until the reboot the installer does anyway (see plugin 14).
PLUGIN_NAME="gps-fast"
PLUGIN_DESC="GPS position to CarPlay up to 10x per second, less lag (new board only, EXPERIMENTAL)"
PLUGIN_RISK="experimental"

PGF_TAG="22-gps-fast"
PGF_UBX="$FIRMWARE_ROOT/jci/lib/libjcilds-ublox.so"
PGF_CP="$FIRMWARE_ROOT/jci/carplay/blmjcicarplay.so"
PGF_CONF="$ND2CN_SRC_DIR/resources/gps-fast.conf"
PGF_BOARD_SCRIPT="$FIRMWARE_ROOT/jci/scripts/get_board_type.sh"

# libjcilds-ublox.so (decimal file offsets)
PGF_UBX_MSGS_OFFSET=36220      # 0x8d7c: cfg_msgs, 12 x (class, id)
PGF_UBX_MSGS="280028012802010401350a091010f000f002f003f004f007"
PGF_UBX_DIV_OFFSET=36244       # 0x8d94: cfg_rates row 0, byte 0 = HNR-PVT
PGF_UBX_ROW_REST_OFFSET=36245  # 0x8d95: row 0, bytes 1..11
PGF_UBX_ROW_REST="0a0a010101010000000000"
PGF_UBX_HNR_OFFSET=41460       # 0xa1f4: UBX-CFG-HNR, highNavRate = 10 Hz
PGF_UBX_HNR="b562065c04000a000000"

# blmjcicarplay.so (decimal file offsets): the instruction before each
# "mov r1, #ms" and the two after it ("mov lr, pc" / "bx r2") are checked.
PGF_CP_POLL_OFFSET=660756      # 0xa1514
PGF_CP_SEND_OFFSET=809304      # 0xc5958
PGF_CP_BEFORE="0300a0e1"
PGF_CP_AFTER="0fe0a0e112ff2fe1"

# ── settings ──
_pgf_conf_get() {
    [ -f "$PGF_CONF" ] || return 0
    awk -F= -v k="$1" '
        { gsub(/[ \t\r]/, "") }
        $1 == k && $2 ~ /^[0-9]+$/ { v = $2 }
        END { if (v != "") print v }' "$PGF_CONF" 2>/dev/null
}

# Sets PGF_DIV, PGF_POLL, PGF_SEND (decimal) from the conf file / defaults.
_pgf_settings() {
    PGF_DIV=$(_pgf_conf_get HNR_DIV)
    case "$PGF_DIV" in
        1|2|5|10) ;;
        "") PGF_DIV=1 ;;
        *)  nd2cn_log "WARN: HNR_DIV=$PGF_DIV is not one of 1, 2, 5, 10 — using 1"
            PGF_DIV=1 ;;
    esac
    _pgf_min=$((PGF_DIV * 100))
    PGF_POLL=$(_pgf_conf_get POLL_MS)
    [ -n "$PGF_POLL" ] || PGF_POLL=$_pgf_min
    if [ "$PGF_POLL" -lt "$_pgf_min" ]; then
        nd2cn_log "WARN: POLL_MS=$PGF_POLL is faster than the GPS ($_pgf_min ms) — using $_pgf_min"
        PGF_POLL=$_pgf_min
    fi
    [ "$PGF_POLL" -le 1000 ] || PGF_POLL=1000
    PGF_SEND=$(_pgf_conf_get SEND_MS)
    [ -n "$PGF_SEND" ] || PGF_SEND=50
    if [ "$PGF_SEND" -lt 20 ] || [ "$PGF_SEND" -gt 1000 ]; then
        nd2cn_log "WARN: SEND_MS=$PGF_SEND is outside 20..1000 — using 50"
        PGF_SEND=50
    fi
    # Round to a value "mov r1, #imm" can encode (see _pgf_enc)
    [ "$PGF_POLL" -le 255 ] || PGF_POLL=$((PGF_POLL / 4 * 4))
    [ "$PGF_SEND" -le 255 ] || PGF_SEND=$((PGF_SEND / 4 * 4))
}

# ── ARM "mov r1, #ms" (e3a01XXX, stored little-endian) ──
# imm 1..255: rotate 0 -> bytes  ms   10 a0 e3
# imm = 4*n : rotate 15 -> bytes n    1f a0 e3   (1000 = fa 1f a0 e3, stock)
_pgf_enc() {
    if [ "$1" -ge 1 ] && [ "$1" -le 255 ]; then
        printf '%02x10a0e3' "$1"
    elif [ $(($1 % 4)) -eq 0 ] && [ $(($1 / 4)) -le 255 ]; then
        printf '%02x1fa0e3' $(($1 / 4))
    else
        return 1
    fi
}

_pgf_dec() {
    case "$1" in
        ??10a0e3) printf '%d\n' "0x${1%10a0e3}" ;;
        ??1fa0e3) echo $(($(printf '%d' "0x${1%1fa0e3}") * 4)) ;;
        *) return 1 ;;
    esac
}

# _pgf_write_hex FILE OFFSET HEX — write the bytes of HEX (even length)
_pgf_write_hex() {
    _pgf_wf="$1"
    _pgf_wo="$2"
    _pgf_wh="$3"
    while [ -n "$_pgf_wh" ]; do
        _pgf_wr=${_pgf_wh#??}
        nd2cn_write_byte "$_pgf_wf" "$_pgf_wo" "${_pgf_wh%"$_pgf_wr"}" || return 1
        _pgf_wh=$_pgf_wr
        _pgf_wo=$((_pgf_wo + 1))
    done
}

# ── layout checks ──
# Prints the current HNR-PVT divider (decimal) of FILE.
_pgf_inspect_ubx() {
    _pgf_v=$(nd2cn_read_byte "$1" $PGF_UBX_MSGS_OFFSET 24)
    if [ "$_pgf_v" != "$PGF_UBX_MSGS" ]; then
        nd2cn_log "UBX message table not found at 0x8d7c (got '$_pgf_v')"
        return 1
    fi
    _pgf_v=$(nd2cn_read_byte "$1" $PGF_UBX_ROW_REST_OFFSET 11)
    if [ "$_pgf_v" != "$PGF_UBX_ROW_REST" ]; then
        nd2cn_log "UBX rate row 0 differs from the expected one (got '$_pgf_v')"
        return 1
    fi
    _pgf_v=$(nd2cn_read_byte "$1" $PGF_UBX_HNR_OFFSET 10)
    if [ "$_pgf_v" != "$PGF_UBX_HNR" ]; then
        nd2cn_log "UBX-CFG-HNR is not the expected 10 Hz message (got '$_pgf_v')"
        return 1
    fi
    _pgf_v=$(nd2cn_read_byte "$1" $PGF_UBX_DIV_OFFSET)
    case "$_pgf_v" in
        01|02|05|0a) printf '%d\n' "0x$_pgf_v" ;;
        *) nd2cn_log "unexpected HNR-PVT divider 0x$_pgf_v"
           return 1 ;;
    esac
}

# Prints "POLL_MS SEND_MS" of FILE.
_pgf_inspect_cp() {
    _pgf_out=""
    for _pgf_o in $PGF_CP_POLL_OFFSET $PGF_CP_SEND_OFFSET; do
        if [ "$(nd2cn_read_byte "$1" $((_pgf_o - 4)) 4)" != "$PGF_CP_BEFORE" ] || \
           [ "$(nd2cn_read_byte "$1" $((_pgf_o + 4)) 8)" != "$PGF_CP_AFTER" ]; then
            nd2cn_log "CarPlay library: code around 0x$(printf '%x' "$_pgf_o") is not the expected one"
            return 1
        fi
        _pgf_v=$(nd2cn_read_byte "$1" "$_pgf_o" 4)
        _pgf_ms=$(_pgf_dec "$_pgf_v") || {
            nd2cn_log "CarPlay library: no 'mov r1, #ms' at 0x$(printf '%x' "$_pgf_o") (got '$_pgf_v')"
            return 1
        }
        _pgf_out="$_pgf_out $_pgf_ms"
    done
    echo "${_pgf_out# }"
}

# True when this is the new board. Offline (FIRMWARE_ROOT set) there are no
# GPIOs to ask, so the check is skipped.
_pgf_board_ok() {
    if ! nd2cn_is_live; then
        nd2cn_log "offline tree: board type not checked"
        return 0
    fi
    if [ ! -f "$PGF_BOARD_SCRIPT" ]; then
        nd2cn_log "FAIL: $PGF_BOARD_SCRIPT not found, cannot tell the board type"
        return 1
    fi
    sh "$PGF_BOARD_SCRIPT" > /dev/null 2>&1
    _pgf_rc=$?
    if [ "$_pgf_rc" != "2" ]; then
        nd2cn_log "FAIL: old CMU board (get_board_type.sh exit $_pgf_rc): no u-blox GNSS path, nothing to speed up"
        return 1
    fi
    # Which receiver jciLDS selected: 1 DR unit, 2 legacy, 3 u-blox. Only a
    # clear "not u-blox" answer stops the plugin; no answer does not.
    _pgf_sel=$(dbus-send --print-reply --reply-timeout=2000 --address="$DBUS_ADDR" \
        --type=method_call --dest=com.jci.lds.control /com/jci/lds/control \
        com.jci.lds.control.GetSelectedGPS_sync 2>/dev/null | awk '$1 == "int32" { print $2; exit }')
    case "$_pgf_sel" in
        3)   nd2cn_log "OK: new board, jciLDS uses the u-blox receiver" ;;
        1|2) nd2cn_log "FAIL: jciLDS reports GPS device $_pgf_sel (not the u-blox)"
             return 1 ;;
        *)   nd2cn_log "OK: new board (jciLDS did not report the selected GPS: '$_pgf_sel')" ;;
    esac
    return 0
}

_pgf_inuse_note() {
    nd2cn_is_live || return 0
    nd2cn_log "NOTE: the running services keep the old libraries mapped until the reboot; / cannot be set read-only before then (expected, not an error)"
}

# _pgf_set_ubx DIV [TAG] — bring the divider byte to DIV (decimal)
_pgf_set_ubx() {
    _pgf_cur=$(_pgf_inspect_ubx "$PGF_UBX") || {
        nd2cn_log "ERROR: layout check failed, not touching $PGF_UBX"
        return 1
    }
    if [ "$_pgf_cur" = "$1" ]; then
        nd2cn_log "GPS library: HNR-PVT divider already $1 ($((10 / $1)) Hz)"
        ND2CN_CHANGED=0
        return 0
    fi
    _pgf_st=$(nd2cn_stage_file "$PGF_UBX") || return 1
    nd2cn_write_byte "$_pgf_st" $PGF_UBX_DIV_OFFSET "$(printf '%02x' "$1")"
    _pgf_new=$(_pgf_inspect_ubx "$_pgf_st")
    _pgf_diff=$(cmp -l "$PGF_UBX" "$_pgf_st" 2>/dev/null | wc -l)
    if [ "$_pgf_new" != "$1" ] || [ "$_pgf_diff" -ne 1 ] || \
       [ "$(wc -c < "$PGF_UBX")" != "$(wc -c < "$_pgf_st")" ]; then
        rm -f "$_pgf_st"
        nd2cn_log "ERROR: GPS library patch verification failed (divider='$_pgf_new', bytes changed=$_pgf_diff)"
        return 1
    fi
    # The stock byte is 0x0a, a newline to "wc -l": allow one line fewer.
    nd2cn_commit_staged "$PGF_UBX" "$_pgf_st" "$2" 1 || return 1
    nd2cn_log "GPS library: HNR-PVT divider $_pgf_cur -> $1 ($((10 / $1)) positions per second after the reboot)"
    return 0
}

# _pgf_set_cp POLL_MS SEND_MS [TAG]
_pgf_set_cp() {
    _pgf_cur=$(_pgf_inspect_cp "$PGF_CP") || {
        nd2cn_log "ERROR: layout check failed, not touching $PGF_CP"
        return 1
    }
    if [ "$_pgf_cur" = "$1 $2" ]; then
        nd2cn_log "CarPlay library: already poll $1 ms, send $2 ms"
        ND2CN_CHANGED=0
        return 0
    fi
    if ! _pgf_hp=$(_pgf_enc "$1") || ! _pgf_hs=$(_pgf_enc "$2"); then
        nd2cn_log "ERROR: $1 / $2 ms cannot be encoded"
        return 1
    fi
    # The staged copy is written next to the target: needs room on /
    _pgf_need=$(($(wc -c < "$PGF_CP") / 1024 + 512))
    _pgf_free=$(df -k "$(dirname "$PGF_CP")" 2>/dev/null | awk 'NR > 1 { f = $(NF - 2) } END { print f }')
    case "$_pgf_free" in
        ""|*[!0-9]*) nd2cn_log "free space on the system partition unknown, trying anyway" ;;
        *) if [ "$_pgf_free" -lt "$_pgf_need" ]; then
               nd2cn_log "ERROR: only $_pgf_free KB free on the system partition, $_pgf_need KB needed for the CarPlay library"
               return 1
           fi ;;
    esac
    _pgf_st=$(nd2cn_stage_file "$PGF_CP") || return 1
    _pgf_write_hex "$_pgf_st" $PGF_CP_POLL_OFFSET "$_pgf_hp"
    _pgf_write_hex "$_pgf_st" $PGF_CP_SEND_OFFSET "$_pgf_hs"
    _pgf_new=$(_pgf_inspect_cp "$_pgf_st")
    _pgf_diff=$(cmp -l "$PGF_CP" "$_pgf_st" 2>/dev/null | wc -l)
    if [ "$_pgf_new" != "$1 $2" ] || [ "$_pgf_diff" -gt 4 ] || \
       [ "$(wc -c < "$PGF_CP")" != "$(wc -c < "$_pgf_st")" ]; then
        rm -f "$_pgf_st"
        nd2cn_log "ERROR: CarPlay library patch verification failed (now '$_pgf_new', bytes changed=$_pgf_diff)"
        return 1
    fi
    # A period byte can be 0x0a (a newline to "wc -l"): allow two lines fewer.
    nd2cn_commit_staged "$PGF_CP" "$_pgf_st" "$3" 2 || return 1
    nd2cn_log "CarPlay library: poll/send $_pgf_cur ms -> $1 $2 ms (after the reboot)"
    return 0
}

plugin_check() {
    for _pgf_f in "$PGF_UBX" "$PGF_CP"; do
        if [ ! -f "$_pgf_f" ]; then
            nd2cn_log "FAIL: $_pgf_f not found"
            return 1
        fi
    done
    _pgf_board_ok || return 1
    if ! _pgf_a=$(_pgf_inspect_ubx "$PGF_UBX"); then
        nd2cn_log "FAIL: libjcilds-ublox.so does not match the expected layout"
        return 1
    fi
    if ! _pgf_b=$(_pgf_inspect_cp "$PGF_CP"); then
        nd2cn_log "FAIL: blmjcicarplay.so does not match the expected layout"
        return 1
    fi
    _pgf_settings
    nd2cn_log "OK: layout verified. Now: GPS $((10 / _pgf_a)) Hz, CarPlay poll/send $_pgf_b ms. Target: GPS $((10 / PGF_DIV)) Hz, poll/send $PGF_POLL $PGF_SEND ms"
    return 0
}

plugin_apply() {
    _pgf_settings
    _pgf_any=0
    # Both layouts must be right before anything is changed
    if ! _pgf_inspect_ubx "$PGF_UBX" > /dev/null || ! _pgf_inspect_cp "$PGF_CP" > /dev/null; then
        nd2cn_log "ERROR: layout check failed, nothing changed"
        return 1
    fi
    # GPS first: loop A may only get faster once the GPS is (see RULE)
    _pgf_set_ubx "$PGF_DIV" "$PGF_TAG" || return 1
    [ "$ND2CN_CHANGED" = "1" ] && _pgf_any=1
    _pgf_set_cp "$PGF_POLL" "$PGF_SEND" "$PGF_TAG" || {
        nd2cn_log "WARN: the GPS library is patched, the CarPlay library is not: positions still reach the iPhone once per second (harmless)"
        return 1
    }
    [ "$ND2CN_CHANGED" = "1" ] && _pgf_any=1
    [ "$_pgf_any" = "1" ] && _pgf_inuse_note
    return 0
}

plugin_remove() {
    _pgf_rc=0
    _pgf_any=0
    # CarPlay first, then the GPS (see RULE)
    if [ -f "$PGF_CP" ]; then
        if _pgf_set_cp 1000 1000; then
            [ "$ND2CN_CHANGED" = "1" ] && _pgf_any=1
            nd2cn_release_backup "$PGF_CP" "$PGF_TAG"
        else
            _pgf_rc=1
        fi
    fi
    if [ -f "$PGF_UBX" ] && [ "$_pgf_rc" = "0" ]; then
        if _pgf_set_ubx 10; then
            [ "$ND2CN_CHANGED" = "1" ] && _pgf_any=1
            nd2cn_release_backup "$PGF_UBX" "$PGF_TAG"
        else
            _pgf_rc=1
        fi
    fi
    [ "$_pgf_any" = "1" ] && _pgf_inuse_note
    return $_pgf_rc
}
