#!/bin/sh
# nd2cn plugin: Boot hook infrastructure (was patch 00)
# Creates /data/nd2cn/boot.d/ for system-level hooks and
# /data/nd2cn/gui.d/ for Opera GUI hooks.
# - System hooks: a marked runner block appended to start_wifi.sh runs every
#   boot.d/*.sh at boot. Their output goes to /tmp/nd2cn/boot.log (tmpfs,
#   cleared on reboot) — never to flash.
# - GUI hooks: developer_mode_GuiConfig.js (loaded by /jci/gui/index.html:33
#   if it exists) with explicit loadScript calls, registered through
#   nd2cn_register_gui_script.
# Every plugin that installs a boot.d script declares "# requires: 00-boot-hook".
#
# Idempotency: the desired start_wifi.sh is computed as
#   (current file with any nd2cn block removed) + (current nd2cn block)
# and only published when it differs, so re-runs are no-ops and an outdated
# or hand-edited block is replaced. Inconsistent markers are never touched.
#
# The block ends with ":" so that start_wifi.sh still exits 0 when boot.d is
# empty or the last hook script fails (a for loop returns the status of the
# last command it ran, and the block is the last thing in start_wifi.sh).
PLUGIN_NAME="boot-hook"
PLUGIN_DESC="Boot-time hook runner (boot.d) and GUI hook loader; needed by other plugins"
PLUGIN_RISK="medium"

P00_TAG="00-boot-hook"
P00_WIFI="$ND2CN_BOOT_HOOK_SCRIPT"
P00_GUICONFIG="$ND2CN_GUICONFIG"

_p00_block() {
    cat << HOOKEOF
$ND2CN_BOOT_HOOK_BEGIN
mkdir -p $ND2CN_BOOT_LOG_DIR
for _nd2cn_f in $ND2CN_BOOT_DIR/*.sh; do
    [ -f "\$_nd2cn_f" ] && sh "\$_nd2cn_f" >> $ND2CN_BOOT_LOG 2>&1
done
:
$ND2CN_BOOT_HOOK_END
HOOKEOF
}

_p00_guiconfig() {
    cat << JSEOF
$ND2CN_GUICONFIG_HEADER
// Loaded by /jci/gui/index.html:33 — BEFORE Utility.js and before var utility.
// We defer execution until the framework is ready using a polling interval.
(function() {
    var _nd2cn_timer = setInterval(function() {
        if (typeof utility === "undefined" || !utility.loadScript) return;
        clearInterval(_nd2cn_timer);
        try {
            // GUI module scripts are registered here by their installers:
            // __ND2CN_GUI_SCRIPTS_START__
            // __ND2CN_GUI_SCRIPTS_END__
        } catch(e) {}
    }, 500);
})();
JSEOF
}

# Marker sanity: prints "none", "ok" or "bad".
# One awk pass counts the exact marker lines and compares their positions
# (BusyBox 1.19.2 grep has no -x, so "grep -cx" / "grep -nx" cannot be used).
_p00_marker_state() {
    if [ ! -f "$1" ]; then
        echo none
        return
    fi
    ND2CN_B="$ND2CN_BOOT_HOOK_BEGIN" ND2CN_E="$ND2CN_BOOT_HOOK_END" awk '
        BEGIN { b = ENVIRON["ND2CN_B"]; e = ENVIRON["ND2CN_E"]; nb = 0; ne = 0; lb = 0; le = 0 }
        $0 == b { nb++; lb = NR }
        $0 == e { ne++; le = NR }
        END {
            if (nb == 0 && ne == 0) print "none"
            else if (nb == 1 && ne == 1 && lb < le) print "ok"
            else print "bad"
        }' "$1"
}

# Number of lines _p00_strip removes from FILE: the block (BEGIN..END) plus
# the blank line before it; 0 without a block. Passed to nd2cn_commit_staged
# as the only shrinkage its truncation guard may accept.
_p00_strip_lines() {
    ND2CN_B="$ND2CN_BOOT_HOOK_BEGIN" ND2CN_E="$ND2CN_BOOT_HOOK_END" awk '
        BEGIN { b = ENVIRON["ND2CN_B"]; e = ENVIRON["ND2CN_E"]; lb = 0; le = 0 }
        $0 == b && !lb { lb = NR }
        $0 == e && lb && !le { le = NR }
        END { n = 0; if (lb && le) n = le - lb + 2; print n }' "$1"
}

# Write FILE without the nd2cn block (and the one blank line we put before it)
_p00_strip() {
    ND2CN_B="$ND2CN_BOOT_HOOK_BEGIN" ND2CN_E="$ND2CN_BOOT_HOOK_END" awk '
        BEGIN { b = ENVIRON["ND2CN_B"]; e = ENVIRON["ND2CN_E"]; skip = 0; held = 0 }
        skip { if ($0 == e) skip = 0; next }
        $0 == b { skip = 1; held = 0; next }
        {
            if (held) { print ""; held = 0 }
            if ($0 == "") { held = 1; next }
            print
        }
        END { if (held) print "" }' "$1"
}

plugin_check() {
    _p00_rc=0
    if [ ! -f "$P00_WIFI" ]; then
        nd2cn_log "WARN: $P00_WIFI not found — boot.d hooks will not auto-start"
    else
        case "$(_p00_marker_state "$P00_WIFI")" in
            bad)
                nd2cn_log "FAIL: inconsistent nd2cn markers in $P00_WIFI (fix by hand)"
                _p00_rc=1 ;;
            ok) nd2cn_log "OK: boot hook present in $P00_WIFI" ;;
            *)  nd2cn_log "OK: $P00_WIFI found (hook not yet installed)" ;;
        esac
    fi
    if [ -f "$P00_GUICONFIG" ] && ! grep -qF "$ND2CN_GUICONFIG_HEADER" "$P00_GUICONFIG"; then
        nd2cn_log "WARN: foreign $P00_GUICONFIG present — GUI hooks will not be installed"
    fi
    return $_p00_rc
}

plugin_apply() {
    if ! mkdir -p "$ND2CN_BOOT_DIR" "$ND2CN_GUI_DIR"; then
        nd2cn_log "ERROR: cannot create $ND2CN_BOOT_DIR / $ND2CN_GUI_DIR"
        return 1
    fi

    # ── GUI hook loader ──
    if [ -f "$P00_GUICONFIG" ] && ! grep -qF "$ND2CN_GUICONFIG_HEADER" "$P00_GUICONFIG"; then
        # Someone else's developer config: never overwrite it.
        nd2cn_log "WARN: $P00_GUICONFIG is not ours — GUI hook loader not installed"
    elif [ -f "$P00_GUICONFIG" ]; then
        nd2cn_log "GuiConfig loader already installed"
    else
        _p00_guiconfig | nd2cn_install_file "$P00_GUICONFIG" 644 || return 1
    fi

    # ── System boot hook ──
    if [ ! -f "$P00_WIFI" ]; then
        nd2cn_log "WARN: $P00_WIFI not found, system hooks will not auto-start"
        return 0
    fi
    if [ "$(_p00_marker_state "$P00_WIFI")" = "bad" ]; then
        nd2cn_log "ERROR: inconsistent nd2cn markers in $P00_WIFI — not touching it"
        return 1
    fi

    if tail -5 "$P00_WIFI" | grep -q "^exit"; then
        nd2cn_log "WARN: $P00_WIFI ends with exit — boot.d hooks may not run"
    fi

    _p00_staged=$(nd2cn_stage_file "$P00_WIFI") || return 1
    if ! { _p00_strip "$P00_WIFI"; echo ""; _p00_block; } > "$_p00_staged"; then
        rm -f "$_p00_staged"
        nd2cn_log "ERROR: cannot build staged $P00_WIFI"
        return 1
    fi
    if [ "$(_p00_marker_state "$_p00_staged")" != "ok" ]; then
        rm -f "$_p00_staged"
        nd2cn_log "ERROR: verify failed on staged $P00_WIFI"
        return 1
    fi
    # An older/hand-edited block may be longer than the current one.
    nd2cn_commit_staged "$P00_WIFI" "$_p00_staged" "$P00_TAG" \
        "$(_p00_strip_lines "$P00_WIFI")" || return 1
    if [ "$ND2CN_CHANGED" = "1" ]; then
        nd2cn_log "Boot hook installed in $P00_WIFI"
    else
        nd2cn_log "Boot hook already applied"
    fi
    return 0
}

plugin_remove() {
    _p00_rc=0
    if [ -f "$P00_WIFI" ]; then
        case "$(_p00_marker_state "$P00_WIFI")" in
            none)
                nd2cn_log "Boot hook not present in $P00_WIFI" ;;
            bad)
                nd2cn_log "ERROR: inconsistent nd2cn markers in $P00_WIFI — remove by hand"
                _p00_rc=1 ;;
            ok)
                _p00_staged=$(nd2cn_stage_file "$P00_WIFI") || return 1
                if _p00_strip "$P00_WIFI" > "$_p00_staged" && \
                   [ "$(_p00_marker_state "$_p00_staged")" = "none" ]; then
                    nd2cn_commit_staged "$P00_WIFI" "$_p00_staged" "" \
                        "$(_p00_strip_lines "$P00_WIFI")" || _p00_rc=1
                    [ "$_p00_rc" = "0" ] && nd2cn_log "Removed boot hook from $P00_WIFI"
                else
                    rm -f "$_p00_staged"
                    nd2cn_log "ERROR: could not strip boot hook from $P00_WIFI"
                    _p00_rc=1
                fi ;;
        esac
    fi
    [ "$_p00_rc" = "0" ] && nd2cn_release_backup "$P00_WIFI" "$P00_TAG"

    if [ -f "$P00_GUICONFIG" ] && grep -qF "$ND2CN_GUICONFIG_HEADER" "$P00_GUICONFIG"; then
        rm -f "$P00_GUICONFIG"
        nd2cn_log "Removed $P00_GUICONFIG"
    fi
    rmdir "$ND2CN_GUI_DIR" 2>/dev/null
    if [ -d "$ND2CN_BOOT_DIR" ] && [ -n "$(ls -A "$ND2CN_BOOT_DIR" 2>/dev/null)" ]; then
        nd2cn_log "WARN: $ND2CN_BOOT_DIR still has scripts from other plugins (no longer run at boot)"
    else
        rmdir "$ND2CN_BOOT_DIR" 2>/dev/null
    fi
    return $_p00_rc
}
