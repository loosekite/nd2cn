#!/bin/sh
# nd2cn — MX-5 ND2 Chinese Owner's Patch Installer (plugin based)
# Entry point called by the USB trigger mechanism.
#
# Usage: sh install.sh [--check] [--no-reboot]
#   --check      dry run: runs only plugin_check of every plugin, changes nothing
#   --no-reboot  do not reboot at the end (for SSH use)
#
# Every plugins/*.sh on the USB stick is run, in filename order (00, 01, ...).
# To leave a feature out, delete its file. Opt-in plugins live in
# plugins/optional/ and are NOT run until moved up into plugins/.
#
# Per plugin: syntax/metadata validation -> "# requires:" dependencies ->
# plugin_check (skip on failure) -> plugin_apply (log and continue on failure).
# Successfully applied plugins are recorded in /data/nd2cn/applied_plugins.txt
# and a copy of each attempted plugin is kept in /data/nd2cn/plugins/ so that
# uninstall.sh works even with a different USB stick.
# A copy of the install log is written to the USB stick for debugging.

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
. "$REPO_DIR/lib/helpers.sh"
ND2CN_SRC_DIR="$REPO_DIR"
PLUGIN_DIR="$REPO_DIR/plugins"

ND2CN_CHECK_MODE=0
ND2CN_REBOOT=1
for _arg in "$@"; do
    case "$_arg" in
        --check)     ND2CN_CHECK_MODE=1 ;;
        --no-reboot) ND2CN_REBOOT=0 ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "unknown option: $_arg" >&2
            exit 2 ;;
    esac
done

mkdir -p "$ND2CN_DIR"

nd2cn_log "=========================================="
nd2cn_log "nd2cn $ND2CN_VERSION installer started"
[ "$ND2CN_CHECK_MODE" = "1" ] && nd2cn_log "CHECK MODE — no modifications will be made"
nd2cn_log "=========================================="

# ── System probe: collect diagnostic info before anything else ──
nd2cn_log "--- SYSTEM PROBE ---"
nd2cn_log "USB source: $REPO_DIR"
nd2cn_log "Date: $(date 2>/dev/null)"
nd2cn_log "Kernel: $(uname -a 2>/dev/null)"
nd2cn_log "BusyBox: $(busybox 2>&1 | head -1)"
if [ -f /jci/version.ini ]; then
    nd2cn_log "FW version: $(grep JCI_SW_VER= /jci/version.ini | head -1)"
    nd2cn_log "FW patch: $(grep JCI_SW_VER_PATCH= /jci/version.ini | head -1)"
    nd2cn_log "FW flavor: $(grep JCI_SW_FLAVOR= /jci/version.ini | head -1)"
    nd2cn_log "HU model: $(grep HUModel /jci/settings/configurations/maz_cmu-root.xml 2>/dev/null | head -1)"
fi
nd2cn_log "Rootfs mount: $(grep ' / ' /proc/mounts 2>/dev/null)"
nd2cn_log "Data mount: $(grep '/data ' /proc/mounts 2>/dev/null || grep '/mnt/data ' /proc/mounts 2>/dev/null)"
nd2cn_log "Free space /data: $(df /data 2>/dev/null | tail -1)"
nd2cn_log "Free space /tmp: $(df /tmp 2>/dev/null | tail -1)"
nd2cn_log "Watchdog: $(cat '/sys/class/gpio/Watchdog Disable/value' 2>/dev/null || echo 'not found')"
nd2cn_log "Opera running: $(pidof opera 2>/dev/null || echo 'no')"
nd2cn_log "sshd running: $(pidof sshd 2>/dev/null || echo 'no')"
nd2cn_log "Settings cache: $(find /data/com/jci/cpp/settings -name '*.bin' 2>/dev/null | wc -l) .bin files"
nd2cn_log "Existing nd2cn: $(cat /data/nd2cn/installed 2>/dev/null || echo 'none')"
nd2cn_log "GuiConfig exists: $([ -f /data/integration/developer_mode_GuiConfig.js ] && echo 'yes' || echo 'no')"
nd2cn_log "Language XML current: $(grep LanguageDisplayStrings /jci/settings/configurations/maz_cmu-root.xml 2>/dev/null | head -1)"
nd2cn_log "USB contents: $(ls "$REPO_DIR"/plugins/*.sh 2>/dev/null | wc -l) plugins, $(ls "$REPO_DIR"/plugins/optional/*.sh 2>/dev/null | wc -l) optional"
nd2cn_log "--- END SYSTEM PROBE ---"

# Helper: copy log to USB before exiting (best-effort)
_nd2cn_copy_log_to_usb() {
    [ -f "$ND2CN_LOG" ] || return 0
    # Try writing directly first
    if cp "$ND2CN_LOG" "$REPO_DIR/nd2cn-install.log" 2>/dev/null; then
        return 0
    fi
    # USB might be mounted read-only by the media manager — try remounting rw
    _usb_dev=$(mount | grep "$REPO_DIR" | awk '{print $1}' | head -1)
    if [ -n "$_usb_dev" ]; then
        mount -o rw,remount "$_usb_dev" "$REPO_DIR" 2>/dev/null || \
        mount -o rw,remount "$REPO_DIR" 2>/dev/null
        cp "$ND2CN_LOG" "$REPO_DIR/nd2cn-install.log" 2>/dev/null
    fi
}

# ── Firmware check ──
if ! nd2cn_check_firmware; then
    nd2cn_dialog_ok "nd2cn" "Unsupported firmware.\nOnly 74.00.324/324A is supported.\n\nNo changes were made."
    _nd2cn_copy_log_to_usb
    exit 1
fi

# ── Discover + validate plugins ──
WORK="${TMPDIR:-/tmp}/nd2cn.$$"
rm -rf "$WORK"
if ! mkdir -p "$WORK/src"; then
    nd2cn_log "FATAL: cannot create work dir $WORK"
    _nd2cn_copy_log_to_usb
    exit 1
fi
QUEUE="$WORK/queue"       # file|name|risk|desc, in execution order
DONE="$WORK/done"         # ids satisfied this run (check passed / applied)
RESULTS="$WORK/results"   # id: result
: > "$QUEUE"
: > "$DONE"
: > "$RESULTS"

_invalid=0
for _f in "$PLUGIN_DIR"/*.sh; do
    [ -f "$_f" ] && echo "$_f"
done | LC_ALL=C sort > "$WORK/found"

while IFS= read -r _f; do
    _file=$(basename "$_f")
    _norm="$WORK/src/$_file"
    if ! nd2cn_plugin_normalize "$_f" "$_norm"; then
        nd2cn_log "ERROR: cannot read $_file"
        echo "$(basename "$_file" .sh): INVALID (unreadable)" >> "$RESULTS"
        _invalid=$((_invalid + 1))
        continue
    fi
    if ! _meta=$(nd2cn_plugin_meta "$_norm" < /dev/null); then
        nd2cn_log "ERROR: $_file is not a valid nd2cn plugin (skipped)"
        echo "$(basename "$_file" .sh): INVALID" >> "$RESULTS"
        _invalid=$((_invalid + 1))
        continue
    fi
    echo "$_file|$_meta" >> "$QUEUE"
done < "$WORK/found"

_total=$(grep -c . "$QUEUE")
nd2cn_log "Found $_total plugin(s) in $PLUGIN_DIR ($_invalid invalid)"
if [ "$_total" = "0" ]; then
    nd2cn_dialog_ok "nd2cn" "No plugins found in plugins/ on the USB drive.\n\nNo changes were made."
    rm -rf "$WORK"
    _nd2cn_copy_log_to_usb
    exit 0
fi

# ── Plugin list dialog ──
_list=""
while IFS='|' read -r _file _name _risk _desc; do
    nd2cn_log "  $(basename "$_file" .sh)  [$_risk]  $_desc"
    case "$_risk" in
        high)         _mark=" (!)" ;;
        experimental) _mark=" (EXPERIMENTAL)" ;;
        *)            _mark="" ;;
    esac
    _list="$_list\n- $(basename "$_file" .sh)$_mark"
done < "$QUEUE"

if [ "$ND2CN_CHECK_MODE" = "1" ]; then
    nd2cn_dialog_ok "nd2cn $ND2CN_VERSION" "Checking $_total plugins:$_list"
else
    nd2cn_dialog_ok "nd2cn $ND2CN_VERSION" "MX-5 ND2 Customization Installer\n\nInstalling $_total plugins:$_list"

    # ── Safety trap + prepare rootfs (once) ──
    nd2cn_install_trap
    if ! nd2cn_prepare_mutation; then
        nd2cn_log "FATAL: cannot prepare rootfs for modification"
        nd2cn_dialog_ok "nd2cn ERROR" "Cannot modify system files.\nNo changes were made."
        rm -rf "$WORK"
        _nd2cn_copy_log_to_usb
        exit 1
    fi
    mkdir -p "$ND2CN_BACKUP_DIR" "$ND2CN_PLUGIN_STORE"
fi

# ── Run plugins in filename order ──
_ok=0
_skipped=0
_failed=0
while IFS='|' read -r _file _name _risk _desc; do
    _id=$(basename "$_file" .sh)
    _norm="$WORK/src/$_file"
    nd2cn_log "------------------------------------------"
    nd2cn_log "Plugin $_id ($_name, risk: $_risk)"

    # Dependencies: satisfied by a plugin that succeeded in this run, or one
    # that was applied by an earlier install.
    _missing=""
    for _req in $(nd2cn_plugin_requires "$_norm"); do
        _req=$(basename "$_req" .sh)
        if nd2cn_has_line "$_req" "$DONE" || nd2cn_applied_has "$_req.sh"; then
            continue
        fi
        _missing="$_missing $_req"
    done
    if [ -n "$_missing" ]; then
        nd2cn_log "SKIP $_id: requires$_missing (not applied and not succeeded in this run)"
        echo "$_id: skipped (requires$_missing)" >> "$RESULTS"
        _skipped=$((_skipped + 1))
        continue
    fi

    # plugin_check — read-only
    if ! nd2cn_plugin_run "$_norm" plugin_check < /dev/null; then
        nd2cn_log "SKIP $_id: plugin_check failed"
        echo "$_id: skipped (check failed)" >> "$RESULTS"
        _skipped=$((_skipped + 1))
        continue
    fi

    if [ "$ND2CN_CHECK_MODE" = "1" ]; then
        nd2cn_log "CHECK OK $_id"
        echo "$_id" >> "$DONE"
        echo "$_id: check ok" >> "$RESULTS"
        _ok=$((_ok + 1))
        continue
    fi

    if nd2cn_plugin_run "$_norm" plugin_apply < /dev/null; then
        # Keep the code that touched the system, for uninstall.sh. Stored only
        # after a successful apply: if apply fails, the previously stored copy
        # (matching the state an earlier successful apply left) is kept.
        cp "$_norm" "$ND2CN_PLUGIN_STORE/$_file.tmp" 2>/dev/null && \
            mv -f "$ND2CN_PLUGIN_STORE/$_file.tmp" "$ND2CN_PLUGIN_STORE/$_file" || \
            nd2cn_log "WARN: could not store a copy of $_file for uninstall"
        if nd2cn_applied_add "$_file"; then
            nd2cn_log "OK $_id"
        else
            nd2cn_log "WARN: $_id applied but $ND2CN_APPLIED could not be updated"
        fi
        echo "$_id" >> "$DONE"
        echo "$_id: ok" >> "$RESULTS"
        _ok=$((_ok + 1))
    else
        nd2cn_log "FAILED $_id: plugin_apply returned an error (continuing)"
        echo "$_id: FAILED" >> "$RESULTS"
        _failed=$((_failed + 1))
    fi
done < "$QUEUE"

nd2cn_log "=========================================="
nd2cn_log "Summary: $_ok ok, $_skipped skipped, $_failed failed, $_invalid invalid"
while IFS= read -r _line; do
    nd2cn_log "  $_line"
done < "$RESULTS"

# ── Applied earlier, but not on this USB stick ──
for _a in $(nd2cn_applied_list); do
    if ! cut -d'|' -f1 "$QUEUE" | nd2cn_has_line "$_a"; then
        nd2cn_log "NOTE: $_a is still applied from an earlier install (not on this USB)."
        nd2cn_log "      To remove it: sh uninstall.sh $(basename "$_a" .sh)"
    fi
done

# ── Check mode ends here ──
if [ "$ND2CN_CHECK_MODE" = "1" ]; then
    rm -rf "$WORK"
    nd2cn_dialog_ok "nd2cn check" "Check complete.\n\n$_ok OK, $_skipped would be skipped, $_invalid invalid.\n\nLog: /data/nd2cn/nd2cn.log"
    _nd2cn_copy_log_to_usb
    exit 0
fi

# ── Save install metadata ──
# Known and accepted: written in place, not through a temp file and rename.
# The file is informational (uninstall.sh only tests that it exists), so a
# write cut short by power loss costs at most some of the lines below.
cat > "$ND2CN_FLAG" << EOF
version=$ND2CN_VERSION
date=$(date '+%Y-%m-%d %H:%M:%S')
firmware=$(nd2cn_firmware_version)
plugins_ok=$_ok
plugins_skipped=$_skipped
plugins_failed=$_failed
EOF

# ── Finalize: remount ro + re-enable watchdog (once) ──
# The trap stays armed until finalize has returned: a signal during finalize
# (e.g. in the remount retry sleep) makes the trap run it again (idempotent).
# 0 = done, 2 = ro remount deferred to the reboot (replaced in-use library,
# expected), 1 = failed.
_fin_rc=0
nd2cn_finalize || _fin_rc=$?
nd2cn_clear_trap
rm -rf "$WORK"

if [ "$ND2CN_REBOOT" = "1" ]; then
    _reboot_txt="Please remove USB drive.\nThe system will reboot."
else
    _reboot_txt="Reboot the system to finish."
fi

# ── Copy log to USB BEFORE showing the dialog ──
# (user will remove USB when they see "Please remove USB drive")
_nd2cn_copy_log_to_usb
sync

# ── Plugin status dialog: per-plugin results on screen ──
_plist=""
while IFS= read -r _rline; do
    case "$_rline" in
        *": ok")
            _pname="${_rline%%: ok}"
            _plist="$_plist\n[OK]  $_pname" ;;
        *": FAILED")
            _pname="${_rline%%: FAILED}"
            _plist="$_plist\n[XX]  $_pname" ;;
        *": INVALID"*)
            _pname="${_rline%%: INVALID*}"
            _plist="$_plist\n[--]  $_pname (invalid)" ;;
        *": skipped"*)
            _pname="${_rline%%: skipped*}"
            _plist="$_plist\n[--]  $_pname (skip)" ;;
        *": check ok")
            _pname="${_rline%%: check ok}"
            _plist="$_plist\n[OK]  $_pname" ;;
    esac
done < "$RESULTS"
nd2cn_dialog_ok "nd2cn $ND2CN_VERSION" "$_ok OK, $_skipped skip, $_failed fail$_plist" 15

# ── Completion dialog (never claims "complete" after a failed finalize) ──
if [ "$_fin_rc" != "1" ]; then
    _done_txt="Installation complete!\n\n$_ok OK, $_skipped skipped, $_failed failed."
    [ "$_failed" != "0" ] && _done_txt="$_done_txt\nLog: nd2cn-install.log on USB"
    [ "$_fin_rc" = "2" ] && _done_txt="$_done_txt\n\n$(nd2cn_finalize_problem_text)"
    _done_txt="$_done_txt\n\n$_reboot_txt"
    if nd2cn_applied_has "01-chinese-language.sh"; then
        _done_txt="$_done_txt\n\nAfter reboot:\nSettings > Language > Simplified Chinese"
    fi
    nd2cn_dialog_ok "nd2cn" "$_done_txt"
else
    nd2cn_log "ERROR: finalize failed — install is NOT reported as complete"
    nd2cn_dialog_ok "nd2cn ERROR" "Installation NOT finalized.\n\n$_ok OK, $_skipped skipped, $_failed failed.\n$(nd2cn_finalize_problem_text)\nLog: nd2cn-install.log on USB\n\n$_reboot_txt"
fi

# ── (log already copied above; this is a no-op safety net) ──
if [ -f "$ND2CN_LOG" ]; then
    cp "$ND2CN_LOG" "$REPO_DIR/nd2cn-install.log" 2>/dev/null && \
        nd2cn_log "install log copied to USB: nd2cn-install.log"
fi

if [ "$ND2CN_REBOOT" = "1" ]; then
    sleep 5
    nd2cn_safe_reboot
fi
[ "$_failed" = "0" ] && [ "$_fin_rc" != "1" ]
