#!/bin/sh
# nd2cn plugin: Simplified Chinese UI + metric units (was patch 01)
# Edits maz_cmu-root.xml (language lists, keyboard) and blm_settings-system.xml
# (defaults). Does NOT use D-Bus — settings are applied via the XML files only.
#
# The settings cache (/data/com/jci/cpp/settings/*.bin) is NOT deleted: that
# would reset every user setting on the car, not just the ones changed here.
# The settings service stores a checksum of the XML configuration and
# re-parses it by itself at the next boot when the checksum no longer
# matches (libjcisettings.so: 'Re-parsing "%s" because the calculated
# checksum ... does not match the stored checksum').
# Not verified on a car: whether a re-parse replaces a value the user has
# already changed (e.g. the display language) with the new XML default. The
# language can always be selected by hand: Settings > Language.
#
# Idempotency: each XML is edited into a staged copy with substitutions that
# are no-ops on an already-patched file; the copy is published only if it
# differs.
PLUGIN_NAME="simplified-chinese"
PLUGIN_DESC="Enable Simplified Chinese in language menu, pinyin keyboard, km/Celsius defaults"
PLUGIN_RISK="low"

P01_TAG="01-chinese-lang"
P01_CMU_XML="$FIRMWARE_ROOT/jci/settings/configurations/maz_cmu-root.xml"
P01_BLM_XML="$FIRMWARE_ROOT/jci/settings/configurations/blm_settings-system.xml"

# Replace the 4th slot "-" with "Simplified Chinese"
# Real XML uses: data="String" value="..." (lowercase)
P01_OLD_LANG='US English;NA Spanish;CN French;-'
P01_NEW_LANG='US English;NA Spanish;CN French;Simplified Chinese'
P01_KBD_ADD=';Chinese (Simplified);ABC Chinese (Simplified)'

_p01_kbd_done() {
    grep 'KeyboardLanguageStrings' "$1" | grep -qF 'Chinese (Simplified)'
}

plugin_check() {
    if [ ! -f "$P01_CMU_XML" ]; then
        nd2cn_log "FAIL: $P01_CMU_XML not found"
        return 1
    fi
    if grep -qF "$P01_NEW_LANG" "$P01_CMU_XML"; then
        nd2cn_log "OK: language strings (already patched)"
    elif grep -qF "$P01_OLD_LANG" "$P01_CMU_XML"; then
        nd2cn_log "OK: language string anchor"
    else
        nd2cn_log "FAIL: language string anchor NOT found"
        return 1
    fi
    grep -q 'KeyboardLanguageStrings' "$P01_CMU_XML" || \
        nd2cn_log "WARN: KeyboardLanguageStrings not found (keyboard entries will be skipped)"
    if [ -f "$P01_BLM_XML" ] && ! grep -q 'key="LanguageDisplay"' "$P01_BLM_XML"; then
        nd2cn_log "WARN: LanguageDisplay not found in $P01_BLM_XML (defaults will be skipped)"
    fi
    return 0
}

plugin_apply() {
    _p01_changed=0

    # ── 1+2. Language strings + keyboard languages (maz_cmu-root.xml) ──
    if [ ! -f "$P01_CMU_XML" ]; then
        nd2cn_log "ERROR: $P01_CMU_XML not found"
        return 1
    fi
    if ! grep -qF "$P01_OLD_LANG" "$P01_CMU_XML" && ! grep -qF "$P01_NEW_LANG" "$P01_CMU_XML"; then
        nd2cn_log "ERROR: expected language string not found in $P01_CMU_XML"
        return 1
    fi
    _p01_staged=$(nd2cn_stage_file "$P01_CMU_XML") || return 1
    _p01_n=$(nd2cn_replace_fixed "$_p01_staged" "$P01_OLD_LANG" "$P01_NEW_LANG")
    [ "$_p01_n" != "0" ] && nd2cn_log "Language strings: $_p01_n replacements"
    _p01_count=$(grep -cF "$P01_NEW_LANG" "$_p01_staged")
    if [ "$_p01_count" -lt 4 ]; then
        nd2cn_log "WARN: expected 4 language string lines, found $_p01_count"
    fi
    # Keyboard: add Chinese (Simplified) + ABC Chinese (Simplified) before the
    # closing "/> of the KeyboardLanguageStrings line, only if not yet there.
    if grep -q 'KeyboardLanguageStrings' "$_p01_staged"; then
        if ! _p01_kbd_done "$_p01_staged"; then
            sed -i "/KeyboardLanguageStrings/s|\"/>|$P01_KBD_ADD\"/>|" "$_p01_staged"
            if _p01_kbd_done "$_p01_staged"; then
                nd2cn_log "Added Chinese keyboard entries"
            else
                nd2cn_log "WARN: keyboard string patch may not have applied"
            fi
        fi
    else
        nd2cn_log "WARN: KeyboardLanguageStrings not found, keyboard entries skipped"
    fi
    nd2cn_commit_staged "$P01_CMU_XML" "$_p01_staged" "$P01_TAG" || return 1
    if [ "$ND2CN_CHANGED" = "1" ]; then
        _p01_changed=1
    else
        nd2cn_log "maz_cmu-root.xml already applied"
    fi

    # ── 3. BLM defaults: language, units ──
    # LanguageDisplay=20 (Simplified Chinese), UnitsDistance=1 (km),
    # UnitsTemperature=1 (Celsius)
    if [ -f "$P01_BLM_XML" ]; then
        if grep -q 'key="LanguageDisplay"' "$P01_BLM_XML"; then
            _p01_staged=$(nd2cn_stage_file "$P01_BLM_XML") || return 1
            sed -i \
                -e 's|\(key="LanguageDisplay"[^>]*value="\)[0-9]*"|\120"|' \
                -e 's|\(key="UnitsDistance"[^>]*value="\)[0-9]*"|\11"|' \
                -e 's|\(key="UnitsTemperature"[^>]*value="\)[0-9]*"|\11"|' \
                "$_p01_staged"
            nd2cn_commit_staged "$P01_BLM_XML" "$_p01_staged" "$P01_TAG" || return 1
            if [ "$ND2CN_CHANGED" = "1" ]; then
                _p01_changed=1
                nd2cn_log "BLM defaults updated (language=20, km, Celsius)"
            else
                nd2cn_log "BLM defaults already applied"
            fi
        else
            nd2cn_log "WARN: LanguageDisplay not found in $P01_BLM_XML"
        fi
    fi

    # ── 4. Clear settings cache so the service re-reads the modified XML ──
    # The settings service caches XML in .bin files under /data/com/jci/cpp/settings/.
    # Without clearing, the new language/unit values never load.
    # The running service regenerates .bin immediately after deletion from its
    # in-memory state, so the actual clear must happen at NEXT BOOT before the
    # service starts. We inject a one-shot clear into stage_1.sh (runs before
    # the settings service in sm.conf). A flag file tracks whether we've already
    # done this so repeat installs don't reset user prefs every time.
    _p01_cache="$FIRMWARE_ROOT/data/com/jci/cpp/settings"
    _p01_flag="$ND2CN_DIR/lang-cache-cleared"
    _p01_stage1="$FIRMWARE_ROOT/jci/scripts/stage_1.sh"
    _p01_marker_begin="# BEGIN nd2cn-cache-clear"
    _p01_marker_end="# END nd2cn-cache-clear"

    _p01_need_clear=0
    if [ "$_p01_changed" = "1" ]; then
        # XML changed this run — must clear cache
        _p01_need_clear=1
    elif grep -q "Simplified Chinese" "$P01_CMU_XML" 2>/dev/null && [ ! -f "$_p01_flag" ]; then
        # XML was patched by a previous install that didn't clear cache
        nd2cn_log "XML already patched but cache never cleared — scheduling clear"
        _p01_need_clear=1
    fi

    if [ "$_p01_need_clear" = "1" ]; then
        # Inject a one-shot cache clear into stage_1.sh (runs before settings service)
        if [ -f "$_p01_stage1" ] && ! grep -q "$_p01_marker_begin" "$_p01_stage1"; then
            nd2cn_backup_file "$_p01_stage1" "$P01_TAG" || true
            _p01_s1_staged=$(nd2cn_stage_file "$_p01_stage1") || true
            if [ -n "$_p01_s1_staged" ]; then
                cat >> "$_p01_s1_staged" << CACHEEOF

$_p01_marker_begin
# One-shot settings cache clear — runs once before the settings service starts.
# Ensures the modified maz_cmu-root.xml language values take effect.
_nd2cn_cc="$_p01_cache"
_nd2cn_cf="$_p01_flag"
if [ ! -f "\$_nd2cn_cf" ] && [ -d "\$_nd2cn_cc" ]; then
    rm -f "\$_nd2cn_cc"/*.bin 2>/dev/null
    echo "cleared" > "\$_nd2cn_cf"
fi
$_p01_marker_end
CACHEEOF
                nd2cn_publish_file "$_p01_s1_staged" 2>/dev/null && \
                    nd2cn_log "injected cache clear into stage_1.sh (runs before settings service on next boot)"
            fi
        elif [ -f "$_p01_flag" ]; then
            nd2cn_log "cache already cleared on a previous boot (flag exists)"
        fi
    else
        nd2cn_log "already applied"
    fi
    return 0
}

plugin_remove() {
    _p01_rc=0

    # maz_cmu-root.xml: pristine copy, or reverse the exact edits
    nd2cn_restore_file "$P01_CMU_XML" "$P01_TAG"
    case $? in
        0) ;;
        2)
            if [ -f "$P01_CMU_XML" ]; then
                _p01_staged=$(nd2cn_stage_file "$P01_CMU_XML") || return 1
                nd2cn_replace_fixed "$_p01_staged" "$P01_NEW_LANG" "$P01_OLD_LANG" > /dev/null
                nd2cn_replace_fixed "$_p01_staged" "$P01_KBD_ADD\"/>" "\"/>" > /dev/null
                nd2cn_commit_staged "$P01_CMU_XML" "$_p01_staged" || _p01_rc=1
            fi ;;
        *) _p01_rc=1 ;;
    esac

    # blm_settings-system.xml: the stock defaults are only known from the backup
    nd2cn_restore_file "$P01_BLM_XML" "$P01_TAG"
    case $? in
        0) ;;
        2) nd2cn_log "WARN: no backup of $P01_BLM_XML; BLM defaults left as they are" ;;
        *) _p01_rc=1 ;;
    esac

    # The settings cache is not wiped here either (see the header comment).
    return $_p01_rc
}
