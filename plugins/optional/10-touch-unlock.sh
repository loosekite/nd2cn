#!/bin/sh
# nd2cn plugin: Unlock touchscreen while driving (was patch 11, TOUCH_UNLOCK
# flag)
# Uses the stock NVRAM scripts — cleaner and more reversible than JS patching.
# The scripts write to /sys/class/nvram/nv-config which persists across reboots.
# Reversal: run the same scripts with "enable" argument.
#
# Idempotency: the stock scripts write a fixed value, so calling "disable"
# again yields the same NVRAM state. The NVRAM content cannot be read back
# reliably, so the call is re-asserted on every run (this also repairs a
# restriction that was re-enabled by hand over SSH). The flag file is only
# written after the stock script succeeded.
PLUGIN_NAME="touch-unlock"
PLUGIN_DESC="Allow touchscreen use while driving (stock NVRAM speed-restriction scripts)"
PLUGIN_RISK="high"

P10_SPEED_SCRIPT="$FIRMWARE_ROOT/jci/scripts/set_speed_restriction_config.sh"
P10_LVDS_SCRIPT="$FIRMWARE_ROOT/jci/scripts/set_lvds_speed_restriction_config.sh"
P10_FLAG="$ND2CN_DIR/touch-unlock.flag"

plugin_check() {
    if [ ! -x "$P10_SPEED_SCRIPT" ]; then
        nd2cn_log "FAIL: $P10_SPEED_SCRIPT not found or not executable"
        return 1
    fi
    nd2cn_log "OK: speed restriction script"
    [ -x "$P10_LVDS_SCRIPT" ] || nd2cn_log "WARN: $P10_LVDS_SCRIPT not found (LVDS step skipped)"
    return 0
}

_p10_run() {
    if ! nd2cn_is_live; then
        nd2cn_log "offline root: would run $1 $2"
        return 0
    fi
    "$1" "$2"
}

plugin_apply() {
    if [ ! -x "$P10_SPEED_SCRIPT" ]; then
        nd2cn_log "ERROR: $P10_SPEED_SCRIPT not found or not executable"
        return 1
    fi
    if [ -f "$P10_FLAG" ]; then
        nd2cn_log "already applied (re-asserting; the NVRAM write is idempotent)"
    fi

    _p10_run "$P10_SPEED_SCRIPT" disable
    _p10_r1=$?
    nd2cn_log "bus_bcm speed restriction disable: exit=$_p10_r1"
    if [ "$_p10_r1" != "0" ]; then
        nd2cn_log "ERROR: $P10_SPEED_SCRIPT disable failed"
        return 1
    fi

    if [ -x "$P10_LVDS_SCRIPT" ]; then
        _p10_run "$P10_LVDS_SCRIPT" disable
        nd2cn_log "lvds speed restriction disable: exit=$?"
    fi

    echo "applied" > "$P10_FLAG"
    return 0
}

plugin_remove() {
    # Same gate as v1 uninstall: avoid needless NVRAM writes when the unlock
    # was never applied (stock state is "enabled").
    if [ ! -f "$P10_FLAG" ]; then
        nd2cn_log "not applied (no $P10_FLAG)"
        return 0
    fi
    if [ -x "$P10_SPEED_SCRIPT" ]; then
        _p10_run "$P10_SPEED_SCRIPT" enable
        nd2cn_log "bus_bcm speed restriction re-enabled (exit=$?)"
    fi
    if [ -x "$P10_LVDS_SCRIPT" ]; then
        _p10_run "$P10_LVDS_SCRIPT" enable
        nd2cn_log "lvds speed restriction re-enabled (exit=$?)"
    fi
    rm -f "$P10_FLAG"
    return 0
}
