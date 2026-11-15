#!/bin/sh
# nd2cn plugin: CPU / IO priority tuning (was patch 10; boot.d only, no rootfs
# changes)
# 15 s after the boot hook runs (in the background, so boot is not delayed):
#   - opera            -> nice -5          (UI responsiveness)
#   - gracenote_server -> nice 10, ionice idle (class 3) for background indexing
# renice/ionice are busybox applets on this firmware. Busybox renice without
# -n sets an ABSOLUTE nice value, so re-running is harmless.
#
# Idempotency: only installs/overwrites one boot.d script.
PLUGIN_NAME="cpu-renice"
PLUGIN_DESC="Raise Opera (UI) priority, lower Gracenote indexing priority at boot"
PLUGIN_RISK="low"
# requires: 00-boot-hook

P09_BOOT_SCRIPT="$ND2CN_BOOT_DIR/10-renice.sh"   # v1 name, kept

plugin_check() {
    nd2cn_log "OK: no prerequisites besides the boot hook"
    return 0
}

plugin_apply() {
    nd2cn_install_file "$P09_BOOT_SCRIPT" 755 << 'BOOTEOF' || return 1
#!/bin/sh
# nd2cn 10: renice Opera (UI) up and gracenote_server (indexing) down
PATH=/bin:/sbin:/usr/bin:/usr/sbin:$PATH
(
    sleep 15
    _log=/tmp/nd2cn/boot.log
    mkdir -p /tmp/nd2cn
    for _pid in $(pidof opera); do
        renice -5 -p "$_pid" > /dev/null 2>&1 && \
            echo "[nd2cn 10] opera $_pid nice=-5" >> "$_log"
    done
    for _pid in $(pidof gracenote_server); do
        renice 10 -p "$_pid" > /dev/null 2>&1 && \
            echo "[nd2cn 10] gracenote_server $_pid nice=10" >> "$_log"
        ionice -c 3 -p "$_pid" > /dev/null 2>&1 && \
            echo "[nd2cn 10] gracenote_server $_pid ionice=idle" >> "$_log"
    done
) < /dev/null > /dev/null 2>&1 &
exit 0
BOOTEOF
    [ "$ND2CN_CHANGED" = "1" ] || nd2cn_log "already applied"
    return 0
}

plugin_remove() {
    # v1 left "<script>.tmp" behind on a failed rename
    rm -f "$P09_BOOT_SCRIPT" "$P09_BOOT_SCRIPT.tmp" "$P09_BOOT_SCRIPT.nd2cn.tmp"
    # Priorities reset naturally on the next reboot.
    nd2cn_log "removed (takes effect after reboot)"
    return 0
}
