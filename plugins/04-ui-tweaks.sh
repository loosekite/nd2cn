#!/bin/sh
# nd2cn plugin: systemApp.js UI tweaks (was patches 04 + 07, merged because
# both edit /jci/gui/apps/system/js/systemApp.js)
#
# A. Source order — CarPlay / Android Auto first (was patch 04)
#    Chinese owners primarily use CarPlay for navigation (Gaode/Baidu maps).
#    Moves carplay,androidauto from last to first in the Applications list
#    (both the "Old" and "New" vehicle config lists).
# B. Faster disclaimer dismiss (was patch 07)
#    The stock disclaimer auto-dismisses after 3.5 s via
#    this._disclaimerTime.remaining = 3500; reduced to 200 ms.
#    The constant appears twice (~line 2484 and ~2525). Only the FIRST
#    occurrence (initial display) is changed; the second is the retry/reset
#    loop — patching it too would create a 5 Hz timer.
#
# Both edits go into ONE staged copy, published once. Idempotency: the
# substitutions are literal and only match unpatched text, so the staged copy
# equals the live file once applied. Removal applies the exact reverse
# substitutions (byte-identical to stock), then releases the pristine backup.
PLUGIN_NAME="ui-tweaks"
PLUGIN_DESC="CarPlay/Android Auto first in the source list; disclaimer dismisses in 0.2 s"
PLUGIN_RISK="low"

P04_TAG="04-ui-tweaks"
P04_LEGACY_TAGS="04-source-reorder 07-disclaimer"   # v1 backup tags for this file
P04_SYSTEM_JS="$FIRMWARE_ROOT/jci/gui/apps/system/js/systemApp.js"

# A. Stock order -> target order (carplay,androidauto first)
P04_OLD1='"xmdata","hdtrafficimage","idm","ecoenergy","driverid","warnguide","schedmaint","vehicleStatus","vdt_settings","vdt","carplay","androidauto"'
P04_NEW1='"carplay","androidauto","ecoenergy","vdt","vehicleStatus","idm","driverid","warnguide","schedmaint","vdt_settings","xmdata","hdtrafficimage"'
P04_OLD2='"xmdata","hdtrafficimage","idm","ecoenergy","driverid","vehicleStatus","vdt_settings","vdt","carplay","androidauto"'
P04_NEW2='"carplay","androidauto","ecoenergy","vdt","vehicleStatus","idm","driverid","vdt_settings","xmdata","hdtrafficimage"'

# B. Disclaimer timer
P04_DISC_OLD='this._disclaimerTime.remaining = 3500;'
P04_DISC_NEW='this._disclaimerTime.remaining = 200;'

_p04_has() {
    grep -qF -- "$1" "$P04_SYSTEM_JS"
}

plugin_check() {
    if [ ! -f "$P04_SYSTEM_JS" ]; then
        nd2cn_log "FAIL: $P04_SYSTEM_JS not found"
        return 1
    fi
    _p04_ok=0
    if _p04_has "$P04_NEW1" || _p04_has "$P04_NEW2"; then
        nd2cn_log "OK: A source order (already reordered)"; _p04_ok=1
    elif _p04_has "$P04_OLD1" || _p04_has "$P04_OLD2"; then
        nd2cn_log "OK: A source order anchor"; _p04_ok=1
    else
        nd2cn_log "WARN: A source order anchor NOT found (will be skipped)"
    fi
    if _p04_has "$P04_DISC_NEW"; then
        nd2cn_log "OK: B disclaimer timer (already patched)"; _p04_ok=1
    elif _p04_has "$P04_DISC_OLD"; then
        nd2cn_log "OK: B disclaimer timer anchor"; _p04_ok=1
    else
        nd2cn_log "WARN: B disclaimer timer anchor NOT found (will be skipped)"
    fi
    if [ "$_p04_ok" != "1" ]; then
        nd2cn_log "FAIL: no anchors found in systemApp.js — firmware may differ"
        return 1
    fi
    return 0
}

plugin_apply() {
    if [ ! -f "$P04_SYSTEM_JS" ]; then
        nd2cn_log "ERROR: $P04_SYSTEM_JS not found"
        return 1
    fi
    _p04_staged=$(nd2cn_stage_file "$P04_SYSTEM_JS") || return 1

    # ── A. source order ──
    _p04_a=$(( $(nd2cn_replace_fixed "$_p04_staged" "$P04_OLD1" "$P04_NEW1") + \
               $(nd2cn_replace_fixed "$_p04_staged" "$P04_OLD2" "$P04_NEW2") ))
    if [ "$_p04_a" != "0" ]; then
        nd2cn_log "A: source order patched ($_p04_a configs)"
    elif grep -qF -- "$P04_NEW1" "$_p04_staged" || grep -qF -- "$P04_NEW2" "$_p04_staged"; then
        nd2cn_log "A: sources already reordered"
    else
        nd2cn_log "WARN: A: no source order patterns matched — firmware may differ"
    fi

    # ── B. disclaimer (first occurrence only, and only once) ──
    if grep -qF -- "$P04_DISC_NEW" "$_p04_staged"; then
        nd2cn_log "B: disclaimer already patched"
    elif [ "$(nd2cn_replace_fixed "$_p04_staged" "$P04_DISC_OLD" "$P04_DISC_NEW" first)" = "1" ]; then
        nd2cn_log "B: disclaimer timer 3500 -> 200 ms (first site only)"
    else
        nd2cn_log "WARN: B: disclaimer constant not found — firmware may differ"
    fi

    # Verify: at most one patched timer, patched list(s) present only once
    if [ "$(grep -cF -- "$P04_DISC_NEW" "$_p04_staged")" -gt 1 ]; then
        rm -f "$_p04_staged"
        nd2cn_log "ERROR: verify failed (disclaimer patched more than once)"
        return 1
    fi

    nd2cn_commit_staged "$P04_SYSTEM_JS" "$_p04_staged" "$P04_TAG" || return 1
    [ "$ND2CN_CHANGED" = "1" ] || nd2cn_log "already applied"
    return 0
}

plugin_remove() {
    if [ ! -f "$P04_SYSTEM_JS" ]; then
        nd2cn_log "$P04_SYSTEM_JS not found (nothing to remove)"
        return 0
    fi
    # Exact reverse edits (also correct if the file was never patched)
    _p04_staged=$(nd2cn_stage_file "$P04_SYSTEM_JS") || return 1
    nd2cn_replace_fixed "$_p04_staged" "$P04_NEW1" "$P04_OLD1" > /dev/null
    nd2cn_replace_fixed "$_p04_staged" "$P04_NEW2" "$P04_OLD2" > /dev/null
    nd2cn_replace_fixed "$_p04_staged" "$P04_DISC_NEW" "$P04_DISC_OLD" > /dev/null
    nd2cn_commit_staged "$P04_SYSTEM_JS" "$_p04_staged" || return 1
    if [ "$ND2CN_CHANGED" = "1" ]; then
        nd2cn_log "systemApp.js tweaks reverted"
    else
        nd2cn_log "systemApp.js tweaks not present"
    fi
    # shellcheck disable=SC2086
    nd2cn_release_backup "$P04_SYSTEM_JS" "$P04_TAG" $P04_LEGACY_TAGS
    return 0
}
