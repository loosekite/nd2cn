#!/bin/sh
# nd2cn plugin: Track Dash app (live vehicle data dashboard)
# Installs the files of app/ on the USB stick into /data/nd2cn/app/:
#   dashboard-loader.js   GUI hook: adds a "Track Dash" entry to the
#                         Applications list and shows dashboard.html in an
#                         overlay. It looks for dashboard.html next to itself.
#   dashboard.html        the dashboard page; reads /tmp/nd2cn/dashboard.json
#   nd2cn-dashd           native data daemon (static ARM binary, source in
#                         native/dashd.c): reads the vehicle data from D-Bus
#                         and writes that JSON file, 10 times a second
#                         (tmpfs only, on demand). Optional: without it, or
#                         if it cannot run on this unit, the script is used.
#   dashboard-daemon.sh   starts nd2cn-dashd; also the fallback that does the
#                         same job in shell (5 to 6 times a second)
# and wires them up without touching the rootfs:
#   - the loader is registered with the nd2cn GuiConfig hook loader of plugin
#     00-boot-hook (a utility.loadScript("file://...") line between its
#     __ND2CN_GUI_SCRIPTS_START__/END__ markers)
#   - a boot.d script starts the daemon at every boot
#   - opera.ini [User Prefs] "Allow File XMLHttpRequest=1": dashboard.html
#     (file:///data/nd2cn/app/) reads file:///tmp/nd2cn/dashboard.json with
#     XHR. Opera Presto 12 blocks file:// XHR unless this pref is set; its
#     built-in default is 0 and the stock opera.ini does not set it. This is
#     the only rootfs edit of this plugin.
# The app entry appears after the next reboot (the GUI loads its hooks once,
# Opera reads opera.ini at start).
#
# opera.ini is shared with 03-opera-cache ([Disk Cache]/[Cache]). Each plugin
# stages the current live file and sets only its own key(s), so neither
# loses the other's edits; the pristine backup is write-once (whichever
# plugin runs first takes it) and each plugin holds its own reference.
# Removal uses nd2cn_ini_undo: whole-file restore when this is the last
# plugin using the backup, otherwise only this key is reverted (deleted:
# the stock file does not have it).
#
# NOT verified on a car: the GUI hook and the scaling of the raw CAN values
# (calibration: see dashboard-daemon.sh and /data/nd2cn/dashboard.conf).
#
# Idempotency: each file is rewritten only if its content differs; the GUI
# registration and the boot.d script are added only if missing/changed. A
# running daemon is restarted only when its script or nd2cn-dashd changed.
# Removal unregisters the loader, stops the daemon and deletes the boot.d
# script and /data/nd2cn/app/. A dashboard.conf made by the user is kept.
PLUGIN_NAME="track-dashboard"
PLUGIN_DESC="Track Dash app: live speed/rpm/g-force dashboard in the Applications list (unverified on car)"
PLUGIN_RISK="experimental"
# requires: 00-boot-hook

P21_FILES="dashboard.html dashboard-loader.js dashboard-daemon.sh"
P21_NATIVE="nd2cn-dashd"                # optional, see above
P21_SRC_DIR="$ND2CN_SRC_DIR/app"
P21_APP_DIR="$ND2CN_DIR/app"
# Paths as seen on the car (never prefixed with FIRMWARE_ROOT): these are
# written into the GuiConfig loader and the boot.d script.
P21_DEV_DIR="/data/nd2cn/app"
P21_DEV_LOADER="$P21_DEV_DIR/dashboard-loader.js"
P21_DEV_DAEMON="$P21_DEV_DIR/dashboard-daemon.sh"
P21_BOOT_SCRIPT="$ND2CN_BOOT_DIR/21-track-dashboard.sh"
P21_TAG="21-track-dashboard"
P21_OPERA_INI="$FIRMWARE_ROOT/jci/opera/opera_home/opera.ini"
P21_XHR_SECTION="User Prefs"
P21_XHR_KEY="Allow File XMLHttpRequest"

# The GuiConfig file exists but is not the nd2cn loader (plugin 00 never
# overwrites someone else's developer config).
_p21_foreign_guiconfig() {
    [ -f "$ND2CN_GUICONFIG" ] && ! grep -qF "$ND2CN_GUICONFIG_HEADER" "$ND2CN_GUICONFIG"
}

plugin_check() {
    for _p21_f in $P21_FILES; do
        if [ ! -s "$P21_SRC_DIR/$_p21_f" ]; then
            nd2cn_log "FAIL: app/$_p21_f missing or empty on the USB drive"
            return 1
        fi
    done
    if ! sh -n "$P21_SRC_DIR/dashboard-daemon.sh" 2>/dev/null; then
        nd2cn_log "FAIL: app/dashboard-daemon.sh has a syntax error (edited with CRLF line ends?)"
        return 1
    fi
    if _p21_foreign_guiconfig; then
        nd2cn_log "FAIL: $ND2CN_GUICONFIG is not the nd2cn loader — the GUI hook cannot be registered"
        return 1
    fi
    if [ ! -f "$P21_OPERA_INI" ]; then
        nd2cn_log "FAIL: $P21_OPERA_INI not found (needed to allow file:// XHR)"
        return 1
    fi
    if [ -s "$P21_SRC_DIR/$P21_NATIVE" ]; then
        nd2cn_log "OK: app files present, with the native data daemon (GUI hook is registered by 00-boot-hook's loader)"
    else
        nd2cn_log "OK: app files present; no app/$P21_NATIVE on the USB drive, the shell data daemon will be used"
    fi
    return 0
}

# Install the native daemon and ask it whether it can run on this unit. It is
# never a reason to fail: dashboard-daemon.sh falls back to its shell loop.
_p21_install_native() {
    if [ ! -s "$P21_SRC_DIR/$P21_NATIVE" ]; then
        if [ -f "$P21_APP_DIR/$P21_NATIVE" ]; then
            rm -f "$P21_APP_DIR/$P21_NATIVE"
            _p21_daemon_changed=1
            nd2cn_log "native data daemon removed (not on the USB drive any more)"
        fi
        return 0
    fi
    if ! nd2cn_install_file "$P21_APP_DIR/$P21_NATIVE" 755 < "$P21_SRC_DIR/$P21_NATIVE" || \
       ! cmp -s "$P21_SRC_DIR/$P21_NATIVE" "$P21_APP_DIR/$P21_NATIVE"; then
        # a daemon that runs from the old copy is restarted: it goes to the shell daemon
        [ -f "$P21_APP_DIR/$P21_NATIVE" ] && _p21_daemon_changed=1
        rm -f "$P21_APP_DIR/$P21_NATIVE"
        nd2cn_log "WARN: could not install $P21_NATIVE; the shell data daemon will be used"
        return 0
    fi
    if [ "$ND2CN_CHANGED" = "1" ]; then
        _p21_changed=1
        _p21_daemon_changed=1
    fi
    nd2cn_is_live || return 0
    if _p21_st=$("$P21_APP_DIR/$P21_NATIVE" selftest 2>&1); then
        nd2cn_log "native data daemon self-test: $_p21_st"
    else
        nd2cn_log "WARN: native data daemon cannot run from $P21_APP_DIR (exit $?: $_p21_st); dashboard-daemon.sh will try a copy in /tmp and else use its shell loop"
    fi
    return 0
}

plugin_apply() {
    plugin_check || return 1
    _p21_changed=0
    _p21_daemon_changed=0

    # ── 1. App files ──
    for _p21_f in $P21_FILES; do
        case "$_p21_f" in
            *.sh) _p21_mode=755 ;;
            *)    _p21_mode=644 ;;
        esac
        nd2cn_install_file "$P21_APP_DIR/$_p21_f" "$_p21_mode" < "$P21_SRC_DIR/$_p21_f" || return 1
        if [ "$ND2CN_CHANGED" = "1" ]; then
            _p21_changed=1
            [ "$_p21_f" = "dashboard-daemon.sh" ] && _p21_daemon_changed=1
        fi
        if ! cmp -s "$P21_SRC_DIR/$_p21_f" "$P21_APP_DIR/$_p21_f"; then
            nd2cn_log "ERROR: $P21_APP_DIR/$_p21_f differs from the copy on the USB drive"
            return 1
        fi
    done

    _p21_install_native

    # ── 2. GUI hook (after the files exist, so the loader never points at a
    #       missing script) ──
    if ! grep -qF "\"file://$P21_DEV_LOADER\"" "$ND2CN_GUICONFIG" 2>/dev/null; then
        _p21_changed=1
    fi
    nd2cn_register_gui_script "$P21_DEV_LOADER" || return 1

    # ── 3. opera.ini: allow file:// XHR (dashboard.html -> dashboard.json) ──
    _p21_staged=$(nd2cn_stage_file "$P21_OPERA_INI") || return 1
    if ! nd2cn_ini_set "$_p21_staged" "$P21_XHR_SECTION" "$P21_XHR_KEY" 1 || \
       [ "$(nd2cn_ini_get "$_p21_staged" "$P21_XHR_SECTION" "$P21_XHR_KEY")" != "1" ]; then
        rm -f "$_p21_staged"
        nd2cn_log "ERROR: editing staged opera.ini failed"
        return 1
    fi
    nd2cn_commit_staged "$P21_OPERA_INI" "$_p21_staged" "$P21_TAG" || return 1
    if [ "$ND2CN_CHANGED" = "1" ]; then
        _p21_changed=1
        nd2cn_log "opera.ini: $P21_XHR_KEY=1 set in [$P21_XHR_SECTION] (Opera reads it at the next start)"
    fi

    # ── 4. boot.d: start the data daemon ──
    nd2cn_install_file "$P21_BOOT_SCRIPT" 755 << BOOTEOF || return 1
#!/bin/sh
# nd2cn 21: start the Track Dash data daemon (detaches; never starts twice;
# writes only to /tmp/nd2cn)
[ -f $P21_DEV_DAEMON ] && sh $P21_DEV_DAEMON start
exit 0
BOOTEOF
    [ "$ND2CN_CHANGED" = "1" ] && _p21_changed=1

    # A daemon that is already running still executes the old program.
    if [ "$_p21_daemon_changed" = "1" ] && nd2cn_is_live && \
       sh "$P21_APP_DIR/dashboard-daemon.sh" status > /dev/null 2>&1; then
        sh "$P21_APP_DIR/dashboard-daemon.sh" restart      # returns once the new daemon is up
        nd2cn_log "data daemon restarted: $(sh "$P21_APP_DIR/dashboard-daemon.sh" status 2>/dev/null | head -n 1)"
    fi

    if [ "$_p21_changed" = "1" ]; then
        nd2cn_log "Track Dash installed in $P21_APP_DIR (appears in Applications after reboot)"
    else
        nd2cn_log "already applied"
    fi
    return 0
}

plugin_remove() {
    # GUI hook first: if it cannot be unregistered the files stay, so the
    # loader never points at a missing script (re-run to finish).
    if ! nd2cn_unregister_gui_script "$P21_DEV_LOADER"; then
        nd2cn_log "ERROR: could not unregister the GUI hook — app files kept"
        return 1
    fi
    rm -f "$P21_BOOT_SCRIPT" "$P21_BOOT_SCRIPT.nd2cn.tmp"
    _p21_rc=0
    if ! nd2cn_ini_undo "$P21_OPERA_INI" "$P21_TAG" "$P21_XHR_SECTION|$P21_XHR_KEY"; then
        nd2cn_log "ERROR: could not revert $P21_XHR_KEY in opera.ini (re-run uninstall)"
        _p21_rc=1
    fi
    if nd2cn_is_live && [ -f "$P21_APP_DIR/dashboard-daemon.sh" ]; then
        sh "$P21_APP_DIR/dashboard-daemon.sh" stop
    fi
    rm -rf "$P21_APP_DIR"
    if [ -f "$ND2CN_DIR/dashboard.conf" ]; then
        nd2cn_log "Kept $ND2CN_DIR/dashboard.conf (your calibration; delete it by hand if unwanted)"
    fi
    [ "$_p21_rc" = "0" ] && nd2cn_log "removed (the Applications entry disappears after reboot)"
    return $_p21_rc
}
