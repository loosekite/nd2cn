#!/bin/sh
# nd2cn — core helper library
# All functions return 0 on success, non-zero on failure.
# POSIX sh compatible. No bashisms.
#
# FIRMWARE_ROOT: prefix for every system path. Empty on the car. A non-empty
# value points nd2cn at an extracted firmware tree (offline testing). In that
# mode nd2cn never remounts /, never touches the watchdog, never reboots and
# never signals live processes (see nd2cn_is_live).

ND2CN_VERSION="2.0.0"
FIRMWARE_ROOT="${FIRMWARE_ROOT:-}"

ND2CN_DIR="$FIRMWARE_ROOT/data/nd2cn"
ND2CN_BACKUP_DIR="$ND2CN_DIR/backups"
ND2CN_PRISTINE_DIR="$ND2CN_BACKUP_DIR/_pristine"
ND2CN_BOOT_DIR="$ND2CN_DIR/boot.d"
ND2CN_GUI_DIR="$ND2CN_DIR/gui.d"
ND2CN_LOG="$ND2CN_DIR/nd2cn.log"
ND2CN_FLAG="$ND2CN_DIR/installed"
ND2CN_APPLIED="$ND2CN_DIR/applied_plugins.txt"   # one plugin filename per line
ND2CN_PLUGIN_STORE="$ND2CN_DIR/plugins"          # copies used by uninstall
# Boot-time logging goes to tmpfs: nothing nd2cn runs at boot writes to flash
# continuously. /data only receives one-time config files at install time.
ND2CN_BOOT_LOG_DIR="$FIRMWARE_ROOT/tmp/nd2cn"
ND2CN_BOOT_LOG="$ND2CN_BOOT_LOG_DIR/boot.log"

# Boot hook (owned by plugin 00-boot-hook; constants shared so other code can
# test for it)
ND2CN_BOOT_HOOK_SCRIPT="$FIRMWARE_ROOT/jci/scripts/start_wifi.sh"
ND2CN_BOOT_HOOK_BEGIN="# BEGIN nd2cn-boot-hook"
ND2CN_BOOT_HOOK_END="# END nd2cn-boot-hook"
ND2CN_GUICONFIG="$FIRMWARE_ROOT/data/integration/developer_mode_GuiConfig.js"
ND2CN_GUICONFIG_HEADER="// nd2cn GUI hook loader"

# Set by install.sh / uninstall.sh to the USB repo directory. Plugins read
# their resources from "$ND2CN_SRC_DIR/resources".
ND2CN_SRC_DIR="${ND2CN_SRC_DIR:-}"

WATCHDOG_PATH="$FIRMWARE_ROOT/sys/class/gpio/Watchdog Disable/value"
DBUS_ADDR="unix:path=/tmp/dbus_service_socket"
JCI_DIALOG="$FIRMWARE_ROOT/jci/tools/jci-dialog"

# Last nd2cn_commit_staged / nd2cn_install_file call: 1 = file changed, 0 = not
ND2CN_CHANGED=0

_nd2cn_watchdog_was_disabled=0

# ──────────────────────────────────────────────────────────────
# Logging
# ──────────────────────────────────────────────────────────────
nd2cn_log() {
    if [ -n "${ND2CN_PLUGIN_ID:-}" ]; then
        _msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$ND2CN_PLUGIN_ID] $1"
    else
        _msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    fi
    echo "$_msg" >> "$ND2CN_LOG" 2>/dev/null
    echo "$_msg" >&2
}

# True on the car; false when operating on an offline FIRMWARE_ROOT.
nd2cn_is_live() {
    [ -z "$FIRMWARE_ROOT" ]
}

# nd2cn_has_line LINE [FILE] — true if FILE (stdin when omitted) contains a
# line that is exactly LINE (fixed string, whole line).
# Replaces "grep -x": the BusyBox 1.19.2 grep on the CMU has no -x option
# (its option string is "lnqvscFiHhe:f:Lorm:wA:B:C:EaI").
# The ("" x) concatenation forces a string comparison, so "10" != "10.0".
nd2cn_has_line() {
    if [ "$#" -ge 2 ]; then
        ND2CN_L="$1" awk 'BEGIN { l = ENVIRON["ND2CN_L"] }
            ("" $0) == ("" l) { f = 1; exit }
            END { exit !f }' "$2" 2>/dev/null
    else
        ND2CN_L="$1" awk 'BEGIN { l = ENVIRON["ND2CN_L"] }
            ("" $0) == ("" l) { f = 1; exit }
            END { exit !f }'
    fi
}

# ──────────────────────────────────────────────────────────────
# Firmware check
# ──────────────────────────────────────────────────────────────
nd2cn_firmware_version() {
    grep 'JCI_SW_VER=' "$FIRMWARE_ROOT/jci/version.ini" 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/'
}

nd2cn_check_firmware() {
    _verfile="$FIRMWARE_ROOT/jci/version.ini"
    if [ ! -f "$_verfile" ]; then
        nd2cn_log "ERROR: $_verfile not found"
        return 1
    fi
    _ver=$(nd2cn_firmware_version)
    _patch=$(grep 'JCI_SW_VER_PATCH=' "$_verfile" | head -1 | sed 's/.*"\(.*\)".*/\1/')
    nd2cn_log "Firmware: $_ver patch=$_patch"
    case "$_ver" in
        *74.00.324) return 0 ;;
    esac
    nd2cn_log "ERROR: unsupported firmware $_ver"
    return 1
}

# ──────────────────────────────────────────────────────────────
# Watchdog — best-effort, not fatal
# ──────────────────────────────────────────────────────────────
nd2cn_disable_watchdog() {
    if [ ! -f "$WATCHDOG_PATH" ]; then
        nd2cn_log "WARN: watchdog path not found, skipping"
        return 0
    fi
    echo 1 > "$WATCHDOG_PATH" 2>/dev/null
    _val=$(cat "$WATCHDOG_PATH" 2>/dev/null)
    if [ "$_val" = "1" ]; then
        _nd2cn_watchdog_was_disabled=1
        nd2cn_log "Watchdog disabled"
        return 0
    fi
    nd2cn_log "WARN: watchdog disable unconfirmed (read back: $_val)"
    return 0
}

nd2cn_enable_watchdog() {
    if [ "$_nd2cn_watchdog_was_disabled" != "1" ]; then
        return 0
    fi
    if [ ! -f "$WATCHDOG_PATH" ]; then
        return 0
    fi
    echo 0 > "$WATCHDOG_PATH" 2>/dev/null
    _val=$(cat "$WATCHDOG_PATH" 2>/dev/null)
    if [ "$_val" = "0" ]; then
        _nd2cn_watchdog_was_disabled=0
        nd2cn_log "Watchdog re-enabled"
        return 0
    fi
    nd2cn_log "WARN: watchdog re-enable unconfirmed"
    return 1
}

# ──────────────────────────────────────────────────────────────
# Rootfs mount control
# ──────────────────────────────────────────────────────────────
nd2cn_root_is_ro() {
    # Parse mount options (field 4) for the / mount; avoid matching "errors=remount-ro"
    awk '$2=="/" { split($4,opts,","); for(i in opts) if(opts[i]=="ro") { found=1 } } END { exit !found }' /proc/mounts 2>/dev/null
}

nd2cn_remount_rw() {
    if ! nd2cn_is_live; then
        nd2cn_log "Offline root ($FIRMWARE_ROOT): not remounting /"
        return 0
    fi
    if ! nd2cn_root_is_ro; then
        nd2cn_log "Root already rw"
        return 0
    fi
    mount -o rw,remount / 2>/dev/null
    if nd2cn_root_is_ro; then
        nd2cn_log "ERROR: remount rw failed"
        return 1
    fi
    nd2cn_log "Root remounted rw"
    return 0
}

nd2cn_remount_ro() {
    sync
    if ! nd2cn_is_live; then
        return 0
    fi
    # Idempotent: finalize can run twice (normal path + signal trap)
    if nd2cn_root_is_ro; then
        nd2cn_log "Root already ro"
        return 0
    fi
    mount -o ro,remount / 2>/dev/null
    if nd2cn_root_is_ro; then
        nd2cn_log "Root remounted ro"
        return 0
    fi
    nd2cn_log "WARN: remount ro failed, retrying"
    sync
    sleep 1
    mount -o ro,remount / 2>/dev/null
    if nd2cn_root_is_ro; then
        nd2cn_log "Root remounted ro (retry)"
        return 0
    fi
    nd2cn_log "ERROR: root still rw after retry"
    return 1
}

# ──────────────────────────────────────────────────────────────
# Mutation bracket: prepare / finalize (called ONCE by install/uninstall,
# never by plugins)
# ──────────────────────────────────────────────────────────────
nd2cn_prepare_mutation() {
    nd2cn_disable_watchdog
    nd2cn_remount_rw
    return $?
}

# Print (one per line) the files on the root filesystem that were unlinked or
# replaced (mv over them) but are still mapped or open by a running process.
# While any exist, the kernel refuses "mount -o ro,remount /" with EBUSY
# (an inode with no links but still in use). Example: plugin 14 replaces
# /jci/lib/libjcilds-ublox.so, which the running jciLDS service (sm.conf:
# reset_board="yes", must never be killed) keeps mapped until the reboot.
# Sources: /proc/PID/maps ("... /path (deleted)") and /proc/PID/fd links
# ("... -> /path (deleted)"). Paths on other mounts (/tmp, /data, /dev ...)
# and kernel-internal names (SysV shm, memfd) are ignored.
nd2cn_rootfs_deleted_in_use() {
    _du_mnt=$(awk '{ print $2 }' /proc/mounts 2>/dev/null)
    {
        cat /proc/[0-9]*/maps 2>/dev/null
        ls -l /proc/[0-9]*/fd/ 2>/dev/null
    } | ND2CN_MNT="$_du_mnt" awk '
        BEGIN { n = split(ENVIRON["ND2CN_MNT"], m, "\n") }
        / \(deleted\)$/ {
            p = $0
            sub(/ \(deleted\)$/, "", p)
            i = index(p, " -> ")
            if (i) p = substr(p, i + 4); else sub(/^[^\/]*/, "", p)
            if (substr(p, 1, 1) != "/") next
            if (p ~ /^\/SYSV[0-9a-fA-F]+$/ || p ~ /^\/memfd:/ || p ~ /^\/dev\//) next
            best = "/"
            for (j = 1; j <= n; j++) {
                mp = m[j]
                if (mp == "/" || length(mp) <= length(best)) continue
                if (p == mp || substr(p, 1, length(mp) + 1) == mp "/") best = mp
            }
            if (best == "/" && !(p in seen)) { seen[p] = 1; print p }
        }'
}

# nd2cn_finalize — remount / ro and re-enable the watchdog.
# Returns 0 both done; 2 the watchdog is back on but / stays rw until the
# reboot because a replaced file is still in use (expected, see
# nd2cn_rootfs_deleted_in_use; the reboot finishes it); 1 anything else
# failed. Sets ND2CN_FIN_RO (ok|deferred|failed) and ND2CN_FIN_WD (ok|failed)
# for the caller's dialog. Idempotent (normal path + trap may both call it).
nd2cn_finalize() {
    set +e
    sync
    nd2cn_remount_ro
    _ro_ok=$?
    nd2cn_enable_watchdog
    _wd_ok=$?
    sync
    _fin_rc=0
    ND2CN_FIN_RO=ok
    ND2CN_FIN_WD=ok
    if [ "$_ro_ok" != "0" ]; then
        # Assumption: when a deleted-but-still-mapped file exists on /, it is
        # the cause of the EBUSY. That holds for the current scope (the only
        # in-use rootfs files nd2cn replaces are shared libraries, see plugin
        # 14), but it is not verified: another cause (e.g. a process holding
        # a writable fd on a regular, non-deleted file on /) at the same time
        # would also be reported as "deferred". The kernel does not say which
        # inode blocked the remount, so this is not checked; revisit if nd2cn
        # ever leaves other files open/writable on / across finalize.
        _fin_busy=$(nd2cn_rootfs_deleted_in_use)
        if [ -n "$_fin_busy" ]; then
            ND2CN_FIN_RO=deferred
            _fin_rc=2
            nd2cn_log "NOTE: root stays rw until the reboot — replaced file(s) still in use by a running service (kernel refuses the ro remount with EBUSY). Expected; the reboot loads the new file(s) and mounts / ro again:"
            echo "$_fin_busy" | while IFS= read -r _fin_p; do
                nd2cn_log "  in use, already replaced on disk: $_fin_p"
            done
        else
            ND2CN_FIN_RO=failed
            _fin_rc=1
            nd2cn_log "ERROR: finalize: root could not be remounted ro (no replaced in-use file explains it)"
        fi
    fi
    if [ "$_wd_ok" != "0" ]; then
        ND2CN_FIN_WD=failed
        _fin_rc=1
        nd2cn_log "ERROR: finalize: watchdog could not be re-enabled"
    fi
    case "$_fin_rc" in
        0) nd2cn_log "Finalize complete" ;;
        2) nd2cn_log "Finalize complete except the ro remount (deferred to the reboot)" ;;
        *) nd2cn_log "ERROR: finalize incomplete (root: $ND2CN_FIN_RO, watchdog: $ND2CN_FIN_WD)" ;;
    esac
    return $_fin_rc
}

# Dialog lines (jci-dialog "\n" escapes) describing a non-zero finalize
# result, from ND2CN_FIN_RO / ND2CN_FIN_WD.
nd2cn_finalize_problem_text() {
    _fpt=""
    case "${ND2CN_FIN_RO:-ok}" in
        deferred) _fpt="The system partition stays writable\nuntil the reboot (a replaced system\nlibrary is still in use). This is\nexpected: the reboot completes it." ;;
        failed)   _fpt="The system partition could not be\nset back to read-only." ;;
    esac
    if [ "${ND2CN_FIN_WD:-ok}" = "failed" ]; then
        [ -n "$_fpt" ] && _fpt="$_fpt\n"
        _fpt="${_fpt}The watchdog could not be re-enabled."
    fi
    printf '%s' "$_fpt"
}

# ──────────────────────────────────────────────────────────────
# Safety trap — ensure finalize runs on exit/signal
# ──────────────────────────────────────────────────────────────
nd2cn_install_trap() {
    trap '_nd2cn_trap_handler' EXIT INT TERM HUP
}

_nd2cn_trap_handler() {
    trap - EXIT INT TERM HUP
    set +e
    nd2cn_log "Trap fired — running finalize"
    nd2cn_finalize
    exit 1
}

nd2cn_clear_trap() {
    trap - EXIT INT TERM HUP
}

# ──────────────────────────────────────────────────────────────
# Backups
#
# One pristine copy per target file, keyed by basename:
#   backups/_pristine/<basename>.orig   the file before nd2cn first touched it
#   backups/_pristine/<basename>.path   the full path it belongs to
# Each plugin (backup tag) that depends on a pristine copy records a reference:
#   backups/<tag>/<basename>.ref
# The pristine copy is deleted only when the last reference is released.
# ──────────────────────────────────────────────────────────────

# Print the pristine backup of FILE if a complete one exists and belongs to it.
nd2cn_pristine_of() {
    _po_b=$(basename "$1")
    _po_o="$ND2CN_PRISTINE_DIR/$_po_b.orig"
    [ -f "$_po_o" ] || return 1
    [ "$(cat "$ND2CN_PRISTINE_DIR/$_po_b.path" 2>/dev/null)" = "$1" ] || return 1
    echo "$_po_o"
}

# nd2cn_backup_file FILE TAG — write-once, atomic (.orig only ever appears
# complete). Refuses a basename collision with a different path.
nd2cn_backup_file() {
    _src="$1"
    _tag="$2"
    _bname=$(basename "$_src")
    _pristine="$ND2CN_PRISTINE_DIR/$_bname.orig"
    _pristine_path="$ND2CN_PRISTINE_DIR/$_bname.path"

    if [ ! -f "$_src" ]; then
        nd2cn_log "ERROR: cannot back up missing file $_src"
        return 1
    fi
    if ! mkdir -p "$ND2CN_PRISTINE_DIR"; then
        nd2cn_log "ERROR: cannot create $ND2CN_PRISTINE_DIR"
        return 1
    fi

    if [ -f "$_pristine" ]; then
        _owner=$(cat "$_pristine_path" 2>/dev/null)
        if [ -z "$_owner" ]; then
            # Legacy (v1) crash between copy and sidecar write: adopt it.
            echo "$_src" > "$_pristine_path"
            nd2cn_log "WARN: pristine $_bname had no .path sidecar, adopted for $_src"
        elif [ "$_owner" != "$_src" ]; then
            nd2cn_log "ERROR: pristine backup name collision: $_bname belongs to $_owner, not $_src"
            return 1
        fi
        nd2cn_log "Pristine backup exists: $_pristine (skip)"
    else
        rm -f "$_pristine.tmp"
        if ! echo "$_src" > "$_pristine_path" || \
           ! cp -p "$_src" "$_pristine.tmp" 2>/dev/null || \
           ! cmp -s "$_src" "$_pristine.tmp" || \
           ! mv "$_pristine.tmp" "$_pristine"; then
            rm -f "$_pristine.tmp"
            nd2cn_log "ERROR: backup failed: $_src -> $_pristine"
            return 1
        fi
        sync
        nd2cn_log "Backed up (pristine): $_src -> $_pristine"
    fi

    _tag_dir="$ND2CN_BACKUP_DIR/$_tag"
    mkdir -p "$_tag_dir"
    echo "$_src" > "$_tag_dir/$_bname.ref"
    return 0
}

# nd2cn_release_backup FILE TAG [TAG...] — drop the references of the given
# tags; delete the pristine copy once nobody references it any more.
nd2cn_release_backup() {
    _rb_f="$1"
    shift
    _rb_b=$(basename "$_rb_f")
    for _rb_tag in "$@"; do
        rm -f "$ND2CN_BACKUP_DIR/$_rb_tag/$_rb_b.ref"
        rmdir "$ND2CN_BACKUP_DIR/$_rb_tag" 2>/dev/null
    done
    for _rb_ref in "$ND2CN_BACKUP_DIR"/*/"$_rb_b.ref"; do
        [ -f "$_rb_ref" ] || continue
        if [ "$(cat "$_rb_ref" 2>/dev/null)" = "$_rb_f" ]; then
            nd2cn_log "Pristine $_rb_b kept (still referenced by $(basename "$(dirname "$_rb_ref")"))"
            return 0
        fi
    done
    if nd2cn_pristine_of "$_rb_f" > /dev/null; then
        rm -f "$ND2CN_PRISTINE_DIR/$_rb_b.orig" "$ND2CN_PRISTINE_DIR/$_rb_b.path"
        nd2cn_log "Pristine $_rb_b released"
    fi
    return 0
}

# nd2cn_restore_file FILE TAG [TAG...] — atomically restore FILE from its
# pristine copy, then release it.
# Returns 0 restored (or already identical), 1 error, 2 no pristine backup.
# ND2CN_CHANGED=1 only if FILE was rewritten.
nd2cn_restore_file() {
    _rf_t="$1"
    ND2CN_CHANGED=0
    _rf_o=$(nd2cn_pristine_of "$_rf_t") || {
        nd2cn_log "No pristine backup for $_rf_t"
        return 2
    }
    if [ -f "$_rf_t" ] && cmp -s "$_rf_o" "$_rf_t"; then
        nd2cn_log "Already pristine: $_rf_t"
    else
        _rf_s="$(dirname "$_rf_t")/.$(basename "$_rf_t").nd2cn.new"
        if ! cp -p "$_rf_o" "$_rf_s" 2>/dev/null || ! cmp -s "$_rf_o" "$_rf_s"; then
            rm -f "$_rf_s"
            nd2cn_log "ERROR: restore staging failed: $_rf_t"
            return 1
        fi
        nd2cn_publish_file "$_rf_s" || { rm -f "$_rf_s"; return 1; }
        ND2CN_CHANGED=1
        nd2cn_log "Restored: $_rf_t"
    fi
    nd2cn_release_backup "$@"
    return 0
}

# ──────────────────────────────────────────────────────────────
# Atomic file replacement: stage -> publish
# ──────────────────────────────────────────────────────────────
nd2cn_stage_file() {
    _src="$1"
    _dir=$(dirname "$_src")
    _base=$(basename "$_src")
    _staged="$_dir/.$_base.nd2cn.new"
    if ! cp -p "$_src" "$_staged" 2>/dev/null; then
        nd2cn_log "ERROR: stage cp failed: $_src" >&2
        rm -f "$_staged"
        echo ""
        return 1
    fi
    # Verify copy is sane (matches source size)
    _src_size=$(wc -c < "$_src" 2>/dev/null)
    _stg_size=$(wc -c < "$_staged" 2>/dev/null)
    if [ "$_src_size" != "$_stg_size" ]; then
        nd2cn_log "ERROR: staged file size mismatch: $_src_size vs $_stg_size" >&2
        rm -f "$_staged"
        echo ""
        return 1
    fi
    echo "$_staged"
}

nd2cn_publish_file() {
    _staged="$1"
    _dir=$(dirname "$_staged")
    _base=$(basename "$_staged" | sed 's/^\.//;s/\.nd2cn\.new$//')
    _target="$_dir/$_base"
    if ! mv "$_staged" "$_target" 2>/dev/null; then
        nd2cn_log "ERROR: publish failed: $_staged -> $_target"
        return 1
    fi
    sync
    nd2cn_log "Published: $_target"
    return 0
}

# nd2cn_commit_staged TARGET STAGED [TAG] [MAX_REMOVED]
# Desired-state commit: if STAGED is byte-identical to TARGET it is discarded
# (ND2CN_CHANGED=0). Otherwise TARGET is backed up under TAG (if given) and
# STAGED is published (ND2CN_CHANGED=1). STAGED never survives an error.
#
# Truncation guard (disk full while the staged copy was being rewritten):
# STAGED may not have fewer lines than a non-empty TARGET. Edits that really
# delete lines pass MAX_REMOVED, the number of lines they are expected to
# remove (default 0); anything shorter than that is refused, nothing is
# published and no backup is taken.
nd2cn_commit_staged() {
    _cs_t="$1"
    _cs_s="$2"
    _cs_tag="$3"
    _cs_max="${4:-0}"
    ND2CN_CHANGED=0
    if cmp -s "$_cs_t" "$_cs_s"; then
        rm -f "$_cs_s"
        return 0
    fi
    _cs_ol=$(wc -l < "$_cs_t" 2>/dev/null)
    _cs_nl=$(wc -l < "$_cs_s" 2>/dev/null)
    _cs_ol=$((${_cs_ol:-0}))
    _cs_nl=$((${_cs_nl:-0}))
    if [ "$_cs_ol" -gt 0 ] && [ "$_cs_nl" -lt $((_cs_ol - _cs_max)) ]; then
        nd2cn_log "ERROR: staged copy of $_cs_t has $_cs_nl lines, the original has $_cs_ol (truncated write / disk full?) — not published"
        rm -f "$_cs_s"
        return 1
    fi
    if [ -n "$_cs_tag" ] && ! nd2cn_backup_file "$_cs_t" "$_cs_tag"; then
        rm -f "$_cs_s"
        return 1
    fi
    if ! nd2cn_publish_file "$_cs_s"; then
        rm -f "$_cs_s"
        return 1
    fi
    ND2CN_CHANGED=1
    return 0
}

# nd2cn_install_file DEST [MODE] < content
# Idempotent install of a generated file (boot.d scripts, configs): written to
# a temp file, then renamed over DEST only if the content differs.
# The temp name (DEST.nd2cn.tmp) never matches the boot.d "*.sh" glob.
nd2cn_install_file() {
    _if_d="$1"
    _if_m="${2:-644}"
    _if_t="$_if_d.nd2cn.tmp"
    ND2CN_CHANGED=0
    if ! mkdir -p "$(dirname "$_if_d")"; then
        nd2cn_log "ERROR: cannot create $(dirname "$_if_d")"
        return 1
    fi
    if ! cat > "$_if_t"; then
        rm -f "$_if_t"
        nd2cn_log "ERROR: cannot write $_if_t"
        return 1
    fi
    chmod "$_if_m" "$_if_t"
    if [ -f "$_if_d" ] && cmp -s "$_if_t" "$_if_d"; then
        rm -f "$_if_t"
        chmod "$_if_m" "$_if_d"
        nd2cn_log "Up to date: $_if_d"
        return 0
    fi
    if ! mv -f "$_if_t" "$_if_d"; then
        rm -f "$_if_t"
        nd2cn_log "ERROR: cannot install $_if_d"
        return 1
    fi
    sync
    ND2CN_CHANGED=1
    nd2cn_log "Installed: $_if_d"
    return 0
}

# nd2cn_replace_fixed FILE OLD NEW [first|all]
# Literal (non-regex) in-place replacement; keeps FILE's inode/permissions.
# Prints the number of replacements. FILE is left untouched when it is 0.
nd2cn_replace_fixed() {
    _rx_f="$1"
    _rx_cnt="$_rx_f.rxcnt"
    _rx_tmp="$_rx_f.rxtmp"
    if ! ND2CN_RX_OLD="$2" ND2CN_RX_NEW="$3" ND2CN_RX_MODE="${4:-all}" ND2CN_RX_CNT="$_rx_cnt" \
        LC_ALL=C awk '
        BEGIN { o = ENVIRON["ND2CN_RX_OLD"]; n = ENVIRON["ND2CN_RX_NEW"]
                first = (ENVIRON["ND2CN_RX_MODE"] == "first"); lo = length(o); c = 0 }
        {
            line = $0; out = ""
            while (lo > 0 && (!first || c == 0) && (i = index(line, o)) > 0) {
                out = out substr(line, 1, i - 1) n
                line = substr(line, i + lo)
                c++
            }
            print out line
        }
        END { print c > ENVIRON["ND2CN_RX_CNT"] }' "$_rx_f" > "$_rx_tmp"; then
        rm -f "$_rx_tmp" "$_rx_cnt"
        echo 0
        return 1
    fi
    _rx_n=$(cat "$_rx_cnt" 2>/dev/null)
    rm -f "$_rx_cnt"
    if [ "${_rx_n:-0}" != "0" ]; then
        cat "$_rx_tmp" > "$_rx_f"
    fi
    rm -f "$_rx_tmp"
    echo "${_rx_n:-0}"
}

# ──────────────────────────────────────────────────────────────
# Binary byte access (POSIX: od + octal printf + dd)
# ──────────────────────────────────────────────────────────────
# nd2cn_read_byte FILE OFFSET [COUNT] — lowercase hex, no spaces
nd2cn_read_byte() {
    od -An -tx1 -j "$2" -N "${3:-1}" "$1" 2>/dev/null | tr -d ' \n'
}

# nd2cn_write_byte FILE OFFSET HEXBYTE (e.g. 01). Never truncates.
nd2cn_write_byte() {
    _wb_oct=$(printf '%03o' "0x$3") || return 1
    # shellcheck disable=SC2059
    printf "\\$_wb_oct" | dd of="$1" bs=1 seek="$2" count=1 conv=notrunc 2>/dev/null
}

# ──────────────────────────────────────────────────────────────
# GUI hook registration (the loader is installed by plugin 00-boot-hook)
# ──────────────────────────────────────────────────────────────
# Register a GUI script with the GuiConfig loader (idempotent)
nd2cn_register_gui_script() {
    _gs="$1"
    if [ ! -f "$ND2CN_GUICONFIG" ] || ! grep -qF "$ND2CN_GUICONFIG_HEADER" "$ND2CN_GUICONFIG"; then
        nd2cn_log "ERROR: nd2cn GuiConfig not installed, cannot register $_gs"
        return 1
    fi
    if grep -qF "\"file://$_gs\"" "$ND2CN_GUICONFIG"; then
        nd2cn_log "GUI script already registered: $_gs"
        return 0
    fi
    ND2CN_GS_LINE="            utility.loadScript(\"file://$_gs\");" awk '
        /\/\/ __ND2CN_GUI_SCRIPTS_END__/ { print ENVIRON["ND2CN_GS_LINE"] }
        { print }' "$ND2CN_GUICONFIG" | nd2cn_install_file "$ND2CN_GUICONFIG" 644 || return 1
    nd2cn_log "Registered GUI script: $_gs"
}

nd2cn_unregister_gui_script() {
    _gs="$1"
    [ -f "$ND2CN_GUICONFIG" ] || return 0
    grep -qF "\"file://$_gs\"" "$ND2CN_GUICONFIG" || return 0
    grep -vF "utility.loadScript(\"file://$_gs\");" "$ND2CN_GUICONFIG" | \
        nd2cn_install_file "$ND2CN_GUICONFIG" 644 || return 1
    nd2cn_log "Unregistered GUI script: $_gs"
}

# ──────────────────────────────────────────────────────────────
# Dialog — bilingual (Chinese renders as tofu in jci-dialog)
# ──────────────────────────────────────────────────────────────
nd2cn_dialog_ok() {
    _title="$1"
    _text="$2"
    _timeout="${3:-10}"
    if [ -x "$JCI_DIALOG" ]; then
        killall jci-dialog 2>/dev/null || :
        "$JCI_DIALOG" --info --title="$_title" --text="$_text" --ok-label="OK" &
        sleep "$_timeout"
        killall jci-dialog 2>/dev/null || :
    fi
}

# ──────────────────────────────────────────────────────────────
# Safe reboot via D-Bus
# ──────────────────────────────────────────────────────────────
nd2cn_safe_reboot() {
    if ! nd2cn_is_live; then
        nd2cn_log "Offline root: not rebooting"
        return 0
    fi
    nd2cn_log "Requesting SafeReboot"
    _result=$(dbus-send --print-reply --address="$DBUS_ADDR" \
        --reply-timeout=5000 --type=method_call \
        --dest=com.jci.blm.system /com/jci/blm/system \
        com.jci.blmsystem.Interface.SafeReboot 2>/dev/null)
    if echo "$_result" | grep -q "int32 100"; then
        nd2cn_log "SafeReboot accepted"
        return 0
    fi
    nd2cn_log "WARN: SafeReboot response: $_result"
    return 1
}

# ──────────────────────────────────────────────────────────────
# Section-aware INI editor (for opera.ini)
# Sets KEY=VALUE in [SECTION]; replaces existing occurrences, adds the key at
# the end of the section if missing, appends the section if it is missing.
# Rewrites the file in place, so its permissions are kept.
# ──────────────────────────────────────────────────────────────
nd2cn_ini_set() {
    _file="$1"
    if ! ND2CN_INI_S="$2" ND2CN_INI_K="$3" ND2CN_INI_V="$4" awk '
        BEGIN { s = ENVIRON["ND2CN_INI_S"]; k = ENVIRON["ND2CN_INI_K"]; v = ENVIRON["ND2CN_INI_V"]
                kl = length(k) + 1; ins = 0; found = 0; seen = 0 }
        /^\[/ {
            if (ins && !found) { print k "=" v; found = 1 }
            ins = ($0 == "[" s "]") ? 1 : 0
            if (ins) seen = 1
        }
        ins && substr($0, 1, kl) == k "=" { print k "=" v; found = 1; next }
        { print }
        END {
            if (!found) {
                if (!seen) { print ""; print "[" s "]" }
                print k "=" v
            }
        }' "$_file" > "$_file.ini.tmp"; then
        rm -f "$_file.ini.tmp"
        return 1
    fi
    cat "$_file.ini.tmp" > "$_file"
    _ini_rc=$?
    rm -f "$_file.ini.tmp"
    return $_ini_rc
}

# nd2cn_ini_get FILE SECTION KEY — print the (last) value of KEY in
# [SECTION]; non-zero if the key is not there.
nd2cn_ini_get() {
    ND2CN_INI_S="$2" ND2CN_INI_K="$3" awk '
        BEGIN { s = ENVIRON["ND2CN_INI_S"]; k = ENVIRON["ND2CN_INI_K"]
                kl = length(k) + 1; ins = 0; found = 0 }
        /^\[/ { ins = ($0 == "[" s "]") ? 1 : 0 }
        ins && substr($0, 1, kl) == k "=" { v = substr($0, kl + 1); found = 1 }
        END { if (found) print v; exit !found }' "$1" 2>/dev/null
}

# nd2cn_ini_del FILE SECTION KEY — remove every KEY= line of [SECTION] in
# place (permissions kept). Prints the number of lines removed.
nd2cn_ini_del() {
    _id_f="$1"
    if ! ND2CN_INI_S="$2" ND2CN_INI_K="$3" ND2CN_INI_CNT="$_id_f.ini.cnt" awk '
        BEGIN { s = ENVIRON["ND2CN_INI_S"]; k = ENVIRON["ND2CN_INI_K"]
                kl = length(k) + 1; ins = 0; c = 0 }
        /^\[/ { ins = ($0 == "[" s "]") ? 1 : 0 }
        ins && substr($0, 1, kl) == k "=" { c++; next }
        { print }
        END { print c > ENVIRON["ND2CN_INI_CNT"] }' "$_id_f" > "$_id_f.ini.tmp"; then
        rm -f "$_id_f.ini.tmp" "$_id_f.ini.cnt"
        echo 0
        return 1
    fi
    _id_n=$(cat "$_id_f.ini.cnt" 2>/dev/null)
    rm -f "$_id_f.ini.cnt"
    _id_rc=0
    if [ "${_id_n:-0}" != "0" ]; then
        cat "$_id_f.ini.tmp" > "$_id_f" || _id_rc=1
    fi
    rm -f "$_id_f.ini.tmp"
    echo "${_id_n:-0}"
    return $_id_rc
}

# nd2cn_backup_shared FILE TAG — true if a backup tag other than TAG still
# references the pristine copy of FILE (another plugin edits the same file).
nd2cn_backup_shared() {
    _bs_b=$(basename "$1")
    for _bs_ref in "$ND2CN_BACKUP_DIR"/*/"$_bs_b.ref"; do
        [ -f "$_bs_ref" ] || continue
        [ "$(basename "$(dirname "$_bs_ref")")" = "$2" ] && continue
        [ "$(cat "$_bs_ref" 2>/dev/null)" = "$1" ] && return 0
    done
    return 1
}

# nd2cn_ini_undo FILE TAG SPECS — undo TAG's edits of an INI file that
# several plugins may edit (opera.ini: 03-opera-cache, 21-track-dashboard).
# SPECS: newline-separated "section|key" lines (the keys TAG sets).
#   - TAG is the only user of the pristine copy: the whole file is restored
#     from it (also undoes anything an older nd2cn version did).
#   - TAG is the only user and there is no pristine copy: TAG never changed
#     the file (nd2cn_commit_staged backs up before every change; an
#     unchanged file — e.g. the user already had the key — gets no backup),
#     so the file is left as it is. A key-level revert here would delete
#     the user's own pre-existing setting.
#   - Another tag still uses it: key-level revert — each key gets its
#     pristine value back, or is deleted when the pristine copy has no such
#     key. The other plugin's keys are untouched.
# TAG's backup reference is released either way. Returns 0 on success.
nd2cn_ini_undo() {
    _iu_f="$1"
    _iu_tag="$2"
    _iu_specs="$3"
    if ! nd2cn_backup_shared "$_iu_f" "$_iu_tag"; then
        nd2cn_restore_file "$_iu_f" "$_iu_tag"
        case $? in
            0) return 0 ;;
            2) # no pristine copy: nothing of TAG's to undo
               nd2cn_log "$(basename "$_iu_f"): no backup, leaving file unchanged"
               nd2cn_release_backup "$_iu_f" "$_iu_tag"
               return 0 ;;
            *) return 1 ;;
        esac
    else
        nd2cn_log "$(basename "$_iu_f") is also edited by another plugin: reverting only this plugin's keys"
    fi
    if [ ! -f "$_iu_f" ]; then
        nd2cn_release_backup "$_iu_f" "$_iu_tag"
        return 0
    fi
    _iu_o=$(nd2cn_pristine_of "$_iu_f") || _iu_o=""
    _iu_s=$(nd2cn_stage_file "$_iu_f") || return 1
    _iu_ok=1
    _iu_del=0
    while IFS='|' read -r _iu_sec _iu_key; do
        [ -n "$_iu_sec" ] || continue
        if [ -n "$_iu_o" ] && _iu_v=$(nd2cn_ini_get "$_iu_o" "$_iu_sec" "$_iu_key"); then
            nd2cn_ini_set "$_iu_s" "$_iu_sec" "$_iu_key" "$_iu_v" || _iu_ok=0
        else
            _iu_n=$(nd2cn_ini_del "$_iu_s" "$_iu_sec" "$_iu_key") || _iu_ok=0
            _iu_del=$((_iu_del + ${_iu_n:-0}))
        fi
    done << EOF
$_iu_specs
EOF
    if [ "$_iu_ok" != "1" ]; then
        rm -f "$_iu_s"
        nd2cn_log "ERROR: key-level revert of $_iu_f failed (file untouched)"
        return 1
    fi
    nd2cn_commit_staged "$_iu_f" "$_iu_s" "" "$_iu_del" || return 1
    [ "$ND2CN_CHANGED" = "1" ] && nd2cn_log "Reverted keys in $_iu_f"
    nd2cn_release_backup "$_iu_f" "$_iu_tag"
    return 0
}

# ══════════════════════════════════════════════════════════════
# Plugin framework (used by install.sh / uninstall.sh)
#
# Plugin contract: a .sh file that, when sourced, only defines
#   PLUGIN_NAME PLUGIN_DESC PLUGIN_RISK (low|medium|high|experimental)
#   plugin_check  — read-only prerequisite check
#   plugin_apply  — idempotent apply, 0 on success / already applied
#   plugin_remove — undo this plugin's changes only, 0 if nothing to undo
# Optional dependency line:  # requires: 00-boot-hook
# Every call runs in a subshell, so plugins cannot clobber each other's
# variables or functions, and an "exit" inside a plugin cannot kill the
# installer.
# ══════════════════════════════════════════════════════════════

# Plugin id = filename without .sh (e.g. 03-opera-cache)
nd2cn_plugin_id() {
    basename "$1" .sh
}

# Print "NAME|RISK|DESC" for a valid plugin; non-zero (with log) if invalid.
nd2cn_plugin_meta() {
    if ! sh -n "$1" 2>/dev/null; then
        nd2cn_log "ERROR: $(basename "$1"): syntax error"
        return 1
    fi
    (
        trap - EXIT INT TERM HUP
        unset -f plugin_check plugin_apply plugin_remove 2>/dev/null
        PLUGIN_NAME=""; PLUGIN_DESC=""; PLUGIN_RISK=""
        # shellcheck source=/dev/null  # plugin path is dynamic (resolved at runtime)
        . "$1" > /dev/null 2>&1 || exit 1
        if [ -z "$PLUGIN_NAME" ]; then
            nd2cn_log "ERROR: $(basename "$1"): PLUGIN_NAME not set"
            exit 1
        fi
        case "$PLUGIN_RISK" in
            low|medium|high|experimental) ;;
            *) nd2cn_log "ERROR: $(basename "$1"): invalid PLUGIN_RISK '$PLUGIN_RISK'"
               exit 1 ;;
        esac
        for _pm_fn in plugin_check plugin_apply plugin_remove; do
            if ! command -v "$_pm_fn" > /dev/null 2>&1; then
                nd2cn_log "ERROR: $(basename "$1"): $_pm_fn not defined"
                exit 1
            fi
        done
        printf '%s|%s|%s\n' "$PLUGIN_NAME" "$PLUGIN_RISK" "$PLUGIN_DESC"
    )
}

# Space-separated list of plugin ids this plugin requires.
nd2cn_plugin_requires() {
    sed -n 's/^#[[:space:]]*requires:[[:space:]]*//p' "$1" 2>/dev/null | \
        sed 's/(.*//' | tr ',' ' ' | tr -s ' \t' '  ' | \
        tr ' ' '\n' | grep -v '^none$' | grep -v '^$' | tr '\n' ' '
}

# nd2cn_plugin_run FILE FUNCTION — source FILE in a subshell, call FUNCTION.
nd2cn_plugin_run() {
    (
        trap - EXIT INT TERM HUP
        unset -f plugin_check plugin_apply plugin_remove 2>/dev/null
        PLUGIN_NAME=""; PLUGIN_DESC=""; PLUGIN_RISK=""
        ND2CN_PLUGIN_FILE="$1"
        ND2CN_PLUGIN_ID=$(nd2cn_plugin_id "$1")
        # shellcheck source=/dev/null  # plugin path is dynamic (resolved at runtime)
        . "$1" || exit 1
        if ! command -v "$2" > /dev/null 2>&1; then
            nd2cn_log "ERROR: $2 not defined"
            exit 1
        fi
        "$2"
    )
}

# ── applied_plugins.txt ──
nd2cn_applied_list() {
    [ -f "$ND2CN_APPLIED" ] || return 0
    grep -v '^[[:space:]]*$' "$ND2CN_APPLIED" | grep -v '^#'
}

nd2cn_applied_has() {
    nd2cn_applied_list | nd2cn_has_line "$1"
}

_nd2cn_applied_write() {
    mkdir -p "$ND2CN_DIR" || return 1
    LC_ALL=C sort -u > "$ND2CN_APPLIED.tmp" && mv -f "$ND2CN_APPLIED.tmp" "$ND2CN_APPLIED" && sync
}

nd2cn_applied_add() {
    nd2cn_applied_has "$1" && return 0
    { nd2cn_applied_list; echo "$1"; } | _nd2cn_applied_write
}

nd2cn_applied_del() {
    nd2cn_applied_has "$1" || return 0
    # (no "grep -vx" on BusyBox 1.19.2; forced string comparison as above)
    nd2cn_applied_list | ND2CN_L="$1" awk 'BEGIN { l = ENVIRON["ND2CN_L"] }
        ("" $0) != ("" l)' | _nd2cn_applied_write
}

# Copy a plugin (CR stripped) to DEST — tolerates files edited on Windows.
nd2cn_plugin_normalize() {
    mkdir -p "$(dirname "$2")" || return 1
    tr -d '\r' < "$1" > "$2.tmp" && mv -f "$2.tmp" "$2"
}
