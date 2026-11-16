#!/bin/sh
# nd2cn plugin: One-time GPS backup data (almanac/ephemeris) reset (was patch 18)
# A car imported from another region carries stale u-blox backup data, which
# makes the receiver hunt for satellites that aren't overhead and slows the
# first fix. LDS exposes com.jci.lds.control.ClearBackupData (no arguments;
# introspection in /jci/lib/libjcilds-dbus.so) on /com/jci/lds/control.
#
# A boot.d script calls it once, 10 s after boot, then writes a flag file so it
# never repeats. Delete the flag file to run it again on the next boot:
#   rm /data/nd2cn/gps-reset.done
# No rootfs changes.
#
# Idempotency: the boot.d script is rewritten only if it changed, and the
# "done" flag survives re-installs, so re-running the installer never
# repeats the reset. Removal deletes the script and the flag.
PLUGIN_NAME="gps-reset"
PLUGIN_DESC="Clear stale u-blox almanac/ephemeris once at next boot (imported cars)"
PLUGIN_RISK="low"
# requires: 00-boot-hook

P18_BOOT_SCRIPT="$ND2CN_BOOT_DIR/18-gps-reset.sh"
P18_FLAG="$ND2CN_DIR/gps-reset.done"

plugin_check() {
    if ! nd2cn_is_live; then
        nd2cn_log "OK: offline root (dbus-send not checked)"
        return 0
    fi
    if ! command -v dbus-send > /dev/null 2>&1; then
        nd2cn_log "FAIL: dbus-send not available"
        return 1
    fi
    nd2cn_log "OK: dbus-send available"
    return 0
}

plugin_apply() {
    # Flag/attempt paths and D-Bus address are expanded now; runtime vars are escaped.
    # Known and accepted: the boot script writes its flag and its attempt
    # counter in place, not through a temp file and rename. Only the flag's
    # existence is ever tested, so a write cut short by power loss still
    # counts as "done"; a lost one repeats ClearBackupData on the next boot,
    # which costs one slow GPS fix and nothing else.
    nd2cn_install_file "$P18_BOOT_SCRIPT" 755 << BOOTEOF || return 1
#!/bin/sh
# nd2cn 18: clear u-blox backup data once (faster first fix after import)
PATH=/bin:/sbin:/usr/bin:/usr/sbin:\$PATH
_flag="$P18_FLAG"
_tries="$P18_FLAG.tries"
_log="$ND2CN_BOOT_LOG"
mkdir -p "$ND2CN_BOOT_LOG_DIR"
[ -f "\$_flag" ] && exit 0
(
    sleep 10
    _out=\$(dbus-send --print-reply --address="$DBUS_ADDR" \\
        --reply-timeout=5000 --type=method_call \\
        --dest=com.jci.lds.control /com/jci/lds/control \\
        com.jci.lds.control.ClearBackupData 2>&1)
    _rc=\$?
    # ClearBackupData is async on the server side; a NoReply timeout still
    # means the call was delivered, so treat it as done.
    if [ "\$_rc" = "0" ] || echo "\$_out" | grep -q "NoReply"; then
        date '+%Y-%m-%d %H:%M:%S' > "\$_flag"
        rm -f "\$_tries"
        echo "[nd2cn 18] ClearBackupData sent, flag written" >> "\$_log"
    else
        # LDS not up yet (e.g. ServiceUnknown): retry next boot, give up after 3
        _n=\$(cat "\$_tries" 2>/dev/null)
        _n=\$((\${_n:-0} + 1))
        echo "\$_n" > "\$_tries"
        echo "[nd2cn 18] ClearBackupData failed (attempt \$_n): \$_out" >> "\$_log"
        if [ "\$_n" -ge 3 ]; then
            echo "gave-up" > "\$_flag"
            echo "[nd2cn 18] giving up after \$_n attempts" >> "\$_log"
        fi
    fi
) < /dev/null > /dev/null 2>&1 &
exit 0
BOOTEOF
    rm -f "$P18_BOOT_SCRIPT.tmp"   # v1 leftover

    if [ -f "$P18_FLAG" ]; then
        nd2cn_log "GPS reset already done ($P18_FLAG exists); delete it to rerun"
    else
        nd2cn_log "GPS backup data will be cleared once on next boot"
    fi
    return 0
}

plugin_remove() {
    rm -f "$P18_BOOT_SCRIPT" "$P18_BOOT_SCRIPT.tmp" "$P18_BOOT_SCRIPT.nd2cn.tmp" \
          "$P18_FLAG" "$P18_FLAG.tries"
    nd2cn_log "removed"
    return 0
}
