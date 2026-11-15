#!/bin/sh
# nd2cn plugin: Collation rule for Simplified Chinese (contact sorting) (was patch 05)
# /jci/utils/textcoll_mazda_cmu_cfg.xml only defines collators for lngid 0/1/2
# (US English, NA Spanish, CN French). With LanguageDisplay=20 (Simplified
# Chinese, set by patch 01) no collator matches, so phonebook/media lists fall
# back to raw Unicode code point order.
# This adds an lngid="20" entry pointing at the stock UCA latin1 table — the only
# collation table shipped in this firmware (there is no pinyin table .so).
# Latin-script names then sort/group alphabetically; Han characters still sort
# by the UCA implicit weights (effectively code point order).
# Pairs with 01-chinese-language (which sets LanguageDisplay=20), but has no
# file dependency on it.
#
# Idempotency: skipped when our marker block (or any lngid 20 rule) exists.
# The insert is one atomic publish, so there is no partial state. Removal
# deletes only our marked block and refuses to publish if the document would
# lose its closing </collations> (e.g. a hand-damaged END marker).
PLUGIN_NAME="pinyin-sort"
PLUGIN_DESC="Add a collation rule for Simplified Chinese (contact/media list sorting)"
PLUGIN_RISK="low"

P05_TAG="05-pinyin-sort"
P05_CFG="$FIRMWARE_ROOT/jci/utils/textcoll_mazda_cmu_cfg.xml"
# Device paths written into the XML (never prefixed)
P05_RESOURCE="/jci/utils/libjcitextcoll_uca.so"
P05_TABLE="/jci/utils/uca/uca_mazda_cmu_na_latin1.so"
P05_MARKER="nd2cn-pinyin-sort"

plugin_check() {
    if [ ! -f "$P05_CFG" ]; then
        nd2cn_log "FAIL: $P05_CFG not found"
        return 1
    fi
    if [ ! -f "$FIRMWARE_ROOT$P05_RESOURCE" ] || [ ! -f "$FIRMWARE_ROOT$P05_TABLE" ]; then
        nd2cn_log "FAIL: UCA collator files missing ($P05_RESOURCE / $P05_TABLE)"
        return 1
    fi
    if grep -q "$P05_MARKER" "$P05_CFG" || grep -q 'lngid="20"' "$P05_CFG"; then
        nd2cn_log "OK: lngid 20 collation already present"
        return 0
    fi
    _p05_count=$(grep -c '</collations>' "$P05_CFG")
    if [ "$_p05_count" != "1" ]; then
        nd2cn_log "FAIL: textcoll </collations> anchor count is $_p05_count (expected 1)"
        return 1
    fi
    nd2cn_log "OK: textcoll </collations> anchor"
    return 0
}

plugin_apply() {
    if [ ! -f "$P05_CFG" ]; then
        nd2cn_log "ERROR: $P05_CFG not found"
        return 1
    fi
    if [ ! -f "$FIRMWARE_ROOT$P05_RESOURCE" ] || [ ! -f "$FIRMWARE_ROOT$P05_TABLE" ]; then
        nd2cn_log "ERROR: UCA collator files missing ($P05_RESOURCE / $P05_TABLE)"
        return 1
    fi

    # Idempotency: our marker, or any existing lngid 20 rule
    if grep -q "$P05_MARKER" "$P05_CFG" || grep -q 'lngid="20"' "$P05_CFG"; then
        nd2cn_log "already applied (lngid 20 collation present)"
        return 0
    fi

    _p05_count=$(grep -c '</collations>' "$P05_CFG")
    if [ "$_p05_count" != "1" ]; then
        nd2cn_log "ERROR: </collations> anchor count is $_p05_count (expected 1)"
        return 1
    fi

    _p05_staged=$(nd2cn_stage_file "$P05_CFG") || return 1

    # Insert the block before </collations>. Write via cat (not mv) so the
    # staged file keeps the permissions copied from the original.
    if ! awk -v m="$P05_MARKER" -v res="$P05_RESOURCE" -v tbl="$P05_TABLE" '
        /<\/collations>/ && !done {
            print "    <!-- BEGIN " m " -->"
            print "    <!-- Simplified Chinese (no pinyin table in firmware; use UCA latin1) -->"
            print "    <collation id=\"uca_mazda_cmu_na_latin1\" resource=\"" res "\" "
            print "               table=\"" tbl "\""
            print "               lngid=\"20\" cs=\"0\" groups=\"1\"/>"
            print "    <!-- END " m " -->"
            done = 1
        }
        { print }
    ' "$_p05_staged" > "$_p05_staged.tmp"; then
        nd2cn_log "ERROR: awk insert failed on $P05_CFG"
        rm -f "$_p05_staged" "$_p05_staged.tmp"
        return 1
    fi
    cat "$_p05_staged.tmp" > "$_p05_staged"
    rm -f "$_p05_staged.tmp"

    # Verify: new rule present exactly once, document still closed
    if [ "$(grep -c 'lngid="20"' "$_p05_staged")" != "1" ] || \
       ! grep -q '</collations>' "$_p05_staged"; then
        nd2cn_log "ERROR: verify failed on staged $P05_CFG"
        rm -f "$_p05_staged"
        return 1
    fi

    nd2cn_commit_staged "$P05_CFG" "$_p05_staged" "$P05_TAG" || return 1
    nd2cn_log "lngid 20 collation added"
    return 0
}

plugin_remove() {
    if [ ! -f "$P05_CFG" ] || ! grep -q "$P05_MARKER" "$P05_CFG"; then
        nd2cn_log "not present (skip)"
        nd2cn_release_backup "$P05_CFG" "$P05_TAG"
        return 0
    fi

    _p05_staged=$(nd2cn_stage_file "$P05_CFG") || return 1
    # Lines the sed range below deletes: the only shrinkage the truncation
    # guard in nd2cn_commit_staged may accept.
    _p05_del=$(sed -n "/BEGIN $P05_MARKER/,/END $P05_MARKER/p" "$P05_CFG" | wc -l)
    sed -i "/BEGIN $P05_MARKER/,/END $P05_MARKER/d" "$_p05_staged"
    if grep -q "$P05_MARKER" "$_p05_staged" || ! grep -q '</collations>' "$_p05_staged"; then
        nd2cn_log "ERROR: remove verify failed on staged $P05_CFG"
        rm -f "$_p05_staged"
        return 1
    fi
    nd2cn_commit_staged "$P05_CFG" "$_p05_staged" "" "$((_p05_del))" || return 1
    nd2cn_release_backup "$P05_CFG" "$P05_TAG"
    nd2cn_log "lngid 20 collation removed"
    return 0
}
