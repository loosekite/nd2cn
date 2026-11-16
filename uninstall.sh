#!/bin/sh
# nd2cn — uninstaller / rollback (plugin based)
#
# Usage: sh uninstall.sh [--no-reboot] [--force] [--list] [PLUGIN...]
#   (no PLUGIN)  full uninstall: every applied plugin is removed (reverse
#                filename order), leftover pristine backups are restored,
#                nd2cn boot/GUI hooks and state are cleaned up (logs kept)
#   PLUGIN...    remove only these plugins, e.g. "11-ssh-access" or
#                "ssh-access" (id or PLUGIN_NAME)
#   --force      remove a plugin even if another applied plugin requires it
#   --list       show applied plugins and exit
#   --no-reboot  do not reboot at the end (for SSH use)
#
# Plugin code is taken from /data/nd2cn/plugins/ (the copy that applied the
# change), falling back to plugins/ and plugins/optional/ on the USB stick.
# Nothing is written to the USB stick; the log is /data/nd2cn/nd2cn.log.
# Safe to run multiple times: every plugin_remove is a no-op when there is
# nothing to undo.

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
. "$REPO_DIR/lib/helpers.sh"
ND2CN_SRC_DIR="$REPO_DIR"

ND2CN_REBOOT=1
ND2CN_FORCE=0
_list_only=0
_args=""
for _arg in "$@"; do
    case "$_arg" in
        --no-reboot) ND2CN_REBOOT=0 ;;
        --force)     ND2CN_FORCE=1 ;;
        --list)      _list_only=1 ;;
        -h|--help)
            sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            echo "unknown option: $_arg" >&2
            exit 2 ;;
        *)  _args="$_args $_arg" ;;
    esac
done

if [ "$_list_only" = "1" ]; then
    echo "Applied plugins ($ND2CN_APPLIED):"
    nd2cn_applied_list | sed 's/^/  /'
    exit 0
fi

mkdir -p "$ND2CN_DIR"

nd2cn_log "=========================================="
nd2cn_log "nd2cn $ND2CN_VERSION uninstaller started"
nd2cn_log "=========================================="

# Print the path of the code for plugin file name $1, or fail.
_plugin_source() {
    for _ps in "$ND2CN_PLUGIN_STORE/$1" "$REPO_DIR/plugins/$1" "$REPO_DIR/plugins/optional/$1"; do
        [ -f "$_ps" ] && { echo "$_ps"; return 0; }
    done
    return 1
}

# ── Firmware check ──
if ! nd2cn_check_firmware; then
    nd2cn_dialog_ok "nd2cn" "Unsupported firmware.\nNo changes made."
    exit 1
fi

WORK="${TMPDIR:-/tmp}/nd2cn-un.$$"
rm -rf "$WORK"
if ! mkdir -p "$WORK/src"; then
    nd2cn_log "FATAL: cannot create work dir $WORK"
    exit 1
fi

# ── Candidates: applied list + stored copies (+ partial applies) ──
{
    nd2cn_applied_list
    for _s in "$ND2CN_PLUGIN_STORE"/*.sh; do
        [ -f "$_s" ] && basename "$_s"
    done
} | LC_ALL=C sort -u > "$WORK/known"

_legacy=0
if [ ! -s "$WORK/known" ]; then
    if [ -f "$ND2CN_FLAG" ] || [ -d "$ND2CN_PRISTINE_DIR" ] || [ -d "$ND2CN_BOOT_DIR" ]; then
        # nd2cn v1 install (no applied_plugins.txt): run every plugin's
        # remove. Removes are no-ops for things that were never applied.
        _legacy=1
        nd2cn_log "No applied_plugins.txt — legacy (v1) install, removing every known plugin"
        for _s in "$REPO_DIR/plugins"/*.sh "$REPO_DIR/plugins/optional"/*.sh; do
            [ -f "$_s" ] && basename "$_s"
        done | LC_ALL=C sort -u > "$WORK/known"
    fi
fi

# ── Resolve targets ──
_full=1
: > "$WORK/targets"
if [ -n "$_args" ]; then
    _full=0
    for _want in $_args; do
        _want=$(basename "$_want" .sh)
        _hit=""
        while IFS= read -r _k; do
            if [ "$(basename "$_k" .sh)" = "$_want" ]; then
                _hit="$_k"
                break
            fi
            _src=$(_plugin_source "$_k") || continue
            # CR-stripped copy, as in the removal loop (files edited on Windows)
            _norm="$WORK/src/$_k"
            nd2cn_plugin_normalize "$_src" "$_norm" || continue
            _meta=$(nd2cn_plugin_meta "$_norm" < /dev/null) || continue
            if [ "${_meta%%|*}" = "$_want" ]; then
                _hit="$_k"
                break
            fi
        done < "$WORK/known"
        if [ -z "$_hit" ]; then
            nd2cn_log "WARN: '$_want' is not an applied plugin (ignored)"
            continue
        fi
        echo "$_hit" >> "$WORK/targets"
    done
else
    cp "$WORK/known" "$WORK/targets"
fi
# Reverse filename order: dependents before the plugins they require
LC_ALL=C sort -u -r "$WORK/targets" > "$WORK/order"

if [ ! -s "$WORK/order" ]; then
    nd2cn_log "Nothing to uninstall"
    rm -rf "$WORK"
    nd2cn_dialog_ok "nd2cn" "Nothing to uninstall."
    exit 0
fi

# ── Dependency guard (partial uninstall only) ──
if [ "$_full" = "0" ]; then
    : > "$WORK/order.ok"
    # shellcheck disable=SC2094  # $WORK/order is only read in this loop; it is rewritten (order.ok) afterwards
    while IFS= read -r _t; do
        _tid=$(basename "$_t" .sh)
        _blocker=""
        for _a in $(nd2cn_applied_list); do
            nd2cn_has_line "$_a" "$WORK/order" && continue
            _asrc=$(_plugin_source "$_a") || continue
            for _req in $(nd2cn_plugin_requires "$_asrc"); do
                [ "$(basename "$_req" .sh)" = "$_tid" ] && _blocker="$_blocker $(basename "$_a" .sh)"
            done
        done
        if [ -n "$_blocker" ] && [ "$ND2CN_FORCE" != "1" ]; then
            nd2cn_log "REFUSED $_tid: still required by$_blocker (remove those too, or use --force)"
            continue
        fi
        [ -n "$_blocker" ] && nd2cn_log "WARN: removing $_tid although required by$_blocker (--force)"
        echo "$_t" >> "$WORK/order.ok"
    done < "$WORK/order"
    mv -f "$WORK/order.ok" "$WORK/order"
    if [ ! -s "$WORK/order" ]; then
        rm -rf "$WORK"
        nd2cn_dialog_ok "nd2cn" "Nothing removed (dependency check).\nLog: /data/nd2cn/nd2cn.log"
        exit 1
    fi
fi

_names=$(sed 's/\.sh$//' "$WORK/order" | tr '\n' ' ')
nd2cn_log "Removing: $_names"
if [ "$_full" = "1" ]; then
    nd2cn_dialog_ok "nd2cn" "Uninstalling nd2cn...\nRestoring all original files."
else
    nd2cn_dialog_ok "nd2cn" "Removing plugins:\n$(sed 's/\.sh$//' "$WORK/order" | sed 's/^/- /' | tr '\n' '|' | sed 's/|/\\n/g')"
fi

# ── Safety trap + prepare rootfs (once) ──
nd2cn_install_trap
if ! nd2cn_prepare_mutation; then
    nd2cn_log "FATAL: cannot prepare rootfs for modification"
    nd2cn_dialog_ok "nd2cn ERROR" "Cannot modify system files."
    rm -rf "$WORK"
    exit 1
fi

# ── Remove plugins (reverse order) ──
_removed=0
_failed=0
while IFS= read -r _t; do
    _tid=$(basename "$_t" .sh)
    nd2cn_log "------------------------------------------"
    if ! _src=$(_plugin_source "$_t"); then
        nd2cn_log "ERROR: no code for $_tid (not in $ND2CN_PLUGIN_STORE or on USB)"
        _failed=$((_failed + 1))
        continue
    fi
    _norm="$WORK/src/$_t"
    if ! nd2cn_plugin_normalize "$_src" "$_norm" || ! nd2cn_plugin_meta "$_norm" < /dev/null > /dev/null; then
        nd2cn_log "ERROR: $_src is not a valid plugin"
        _failed=$((_failed + 1))
        continue
    fi
    nd2cn_log "Removing plugin $_tid (from $_src)"
    if nd2cn_plugin_run "$_norm" plugin_remove < /dev/null; then
        nd2cn_applied_del "$_t"
        rm -f "$ND2CN_PLUGIN_STORE/$_t"
        nd2cn_log "REMOVED $_tid"
        _removed=$((_removed + 1))
    else
        nd2cn_log "FAILED to remove $_tid (kept in $ND2CN_APPLIED)"
        _failed=$((_failed + 1))
    fi
done < "$WORK/order"

# ── Full uninstall: safety net + cleanup ──
_swept=0
if [ "$_full" = "1" ]; then
    # Any pristine backup still left belongs to a plugin whose remove failed,
    # or to a v1 tag: restore it (v1 uninstall behavior).
    for _orig in "$ND2CN_PRISTINE_DIR"/*.orig; do
        [ -f "$_orig" ] || continue
        _bn=$(basename "$_orig" .orig)
        _target=$(cat "$ND2CN_PRISTINE_DIR/$_bn.path" 2>/dev/null)
        if [ -z "$_target" ]; then
            nd2cn_log "WARN: no .path sidecar for $_orig (left in place)"
            continue
        fi
        if [ -f "$_target" ] && cmp -s "$_orig" "$_target"; then
            rm -f "$_orig" "$ND2CN_PRISTINE_DIR/$_bn.path"
            continue
        fi
        _stg="$(dirname "$_target")/.$(basename "$_target").nd2cn.new"
        if cp -p "$_orig" "$_stg" 2>/dev/null && nd2cn_publish_file "$_stg"; then
            rm -f "$_orig" "$ND2CN_PRISTINE_DIR/$_bn.path"
            nd2cn_log "Safety net: restored $_target"
            _swept=$((_swept + 1))
        else
            rm -f "$_stg"
            nd2cn_log "ERROR: safety net restore failed: $_target"
            _failed=$((_failed + 1))
        fi
    done
    # The settings cache (/data/com/jci/cpp/settings/*.bin) is not wiped: the
    # settings service re-parses a restored XML by itself (checksum mismatch),
    # and a wipe would reset every user setting.

    if [ "$_failed" = "0" ]; then
        # Clean up nd2cn state (logs and remaining backups are preserved)
        rm -rf "$ND2CN_BOOT_DIR" "$ND2CN_GUI_DIR" "$ND2CN_PLUGIN_STORE"
        rm -f "$ND2CN_APPLIED" "$ND2CN_FLAG"
        # Left by the retired wifi-security plugin (nothing ever read it)
        rm -f "$ND2CN_DIR/hostapd_secure.conf" "$ND2CN_DIR/hostapd_secure.conf.tmp"
        for _d in "$ND2CN_BACKUP_DIR"/*/; do
            [ -d "$_d" ] && rmdir "$_d" 2>/dev/null
        done
        nd2cn_log "Cleaned up nd2cn data (logs preserved)"
    else
        nd2cn_log "WARN: $_failed failure(s) — state kept so uninstall can be re-run"
    fi
fi

nd2cn_log "Summary: $_removed removed, $_failed failed, $_swept restored by safety net"

# ── Finalize ──
# Trap stays armed until finalize has returned (a signal during finalize
# re-runs it from the trap; finalize is idempotent). 0 = done, 2 = ro remount
# deferred to the reboot (restored in-use library, expected), 1 = failed.
sync
_fin_rc=0
nd2cn_finalize || _fin_rc=$?
nd2cn_clear_trap
rm -rf "$WORK"

if [ "$ND2CN_REBOOT" = "1" ]; then
    _reboot_txt="Please remove USB drive.\nThe system will reboot."
else
    _reboot_txt="Reboot the system to finish."
fi

# Never claims "complete" after a failed finalize
if [ "$_fin_rc" != "1" ]; then
    _txt="Uninstall complete!\n\n$_removed plugins removed."
    [ "$_failed" != "0" ] && _txt="$_txt\n$_failed failed.\nLog: /data/nd2cn/nd2cn.log"
    [ "$_fin_rc" = "2" ] && _txt="$_txt\n\n$(nd2cn_finalize_problem_text)"
    _txt="$_txt\n\n$_reboot_txt"
    nd2cn_dialog_ok "nd2cn" "$_txt"
else
    nd2cn_log "ERROR: finalize failed — uninstall is NOT reported as complete"
    _txt="Uninstall NOT finalized.\n\n$_removed plugins removed, $_failed failed.\n$(nd2cn_finalize_problem_text)\nLog: /data/nd2cn/nd2cn.log"
    _txt="$_txt\n\n$_reboot_txt"
    nd2cn_dialog_ok "nd2cn ERROR" "$_txt"
fi

if [ "$ND2CN_REBOOT" = "1" ]; then
    sleep 3
    nd2cn_safe_reboot
fi
[ "$_failed" = "0" ] && [ "$_fin_rc" != "1" ]
