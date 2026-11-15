#!/bin/sh
# nd2cn plugin: Raise USB media library string limits (was patch 06)
# /etc/race_config_params_CMU.xml caps metadata and file/folder names at 128.
# Chinese titles are 3 bytes per character in UTF-8, so long CJK song titles
# and album names get truncated. Raise both limits to 256.
#   uiMaxMetadataLength: 128 -> 256
#   uiMaxNameLength:     128 -> 256
#
# Idempotency: every key is classified (128 = todo, 256 = done, anything else
# = refuse). Only "todo" keys are rewritten, in one atomic publish; a partly
# patched file (one key done) is completed. Removal reverts only keys that
# hold our value.
PLUGIN_NAME="media-limits"
PLUGIN_DESC="Raise USB media metadata/name length limits 128 -> 256 (long CJK titles)"
PLUGIN_RISK="low"

P06_TAG="06-media-limits"
P06_XML="$FIRMWARE_ROOT/etc/race_config_params_CMU.xml"
P06_KEYS="uiMaxMetadataLength uiMaxNameLength"
P06_OLD="128"
P06_NEW="256"

# Print the current <value> of a config key, or nothing if absent/ambiguous.
_p06_get() {
    _p06_n=$(grep -c "<name>$2</name>" "$1")
    [ "$_p06_n" = "1" ] || return 1
    grep "<name>$2</name>" "$1" | \
        sed -n "s|.*<name>$2</name>[[:space:]]*<value>\([^<]*\)</value>.*|\1|p"
}

# Rewrite a key's value from $3 to $4 in file $1 (single-line config entries).
_p06_set() {
    sed -i "s|\(<name>$2</name>[[:space:]]*<value>\)$3\(</value>\)|\1$4\2|" "$1"
}

plugin_check() {
    if [ ! -f "$P06_XML" ]; then
        nd2cn_log "FAIL: $P06_XML not found"
        return 1
    fi
    for _p06_key in $P06_KEYS; do
        _p06_val=$(_p06_get "$P06_XML" "$_p06_key")
        case "$_p06_val" in
            "$P06_OLD"|"$P06_NEW")
                nd2cn_log "OK: $_p06_key = $_p06_val" ;;
            "")
                nd2cn_log "FAIL: $_p06_key not found (or not unique)"
                return 1 ;;
            *)
                nd2cn_log "FAIL: $_p06_key has unexpected value '$_p06_val'"
                return 1 ;;
        esac
    done
    return 0
}

plugin_apply() {
    if [ ! -f "$P06_XML" ]; then
        nd2cn_log "ERROR: $P06_XML not found"
        return 1
    fi

    # Pre-flight: every key must exist exactly once with a known value.
    _p06_todo=""
    for _p06_key in $P06_KEYS; do
        _p06_val=$(_p06_get "$P06_XML" "$_p06_key")
        case "$_p06_val" in
            "$P06_NEW")
                nd2cn_log "$_p06_key already $P06_NEW (skip)" ;;
            "$P06_OLD")
                _p06_todo="$_p06_todo $_p06_key" ;;
            "")
                nd2cn_log "ERROR: $_p06_key not found (or not unique) in $P06_XML"
                return 1 ;;
            *)
                nd2cn_log "ERROR: $_p06_key has unexpected value '$_p06_val' (expected $P06_OLD)"
                return 1 ;;
        esac
    done

    if [ -z "$_p06_todo" ]; then
        nd2cn_log "already applied"
        return 0
    fi

    _p06_staged=$(nd2cn_stage_file "$P06_XML") || return 1

    for _p06_key in $_p06_todo; do
        _p06_set "$_p06_staged" "$_p06_key" "$P06_OLD" "$P06_NEW"
    done

    for _p06_key in $P06_KEYS; do
        if [ "$(_p06_get "$_p06_staged" "$_p06_key")" != "$P06_NEW" ]; then
            nd2cn_log "ERROR: verify failed for $_p06_key in staged $P06_XML"
            rm -f "$_p06_staged"
            return 1
        fi
    done

    nd2cn_commit_staged "$P06_XML" "$_p06_staged" "$P06_TAG" || return 1
    nd2cn_log "metadata/name limits $P06_OLD -> $P06_NEW"
    return 0
}

plugin_remove() {
    if [ ! -f "$P06_XML" ]; then
        return 0
    fi

    _p06_todo=""
    for _p06_key in $P06_KEYS; do
        if [ "$(_p06_get "$P06_XML" "$_p06_key")" = "$P06_NEW" ]; then
            _p06_todo="$_p06_todo $_p06_key"
        fi
    done
    if [ -z "$_p06_todo" ]; then
        nd2cn_log "not present (skip)"
        nd2cn_release_backup "$P06_XML" "$P06_TAG"
        return 0
    fi

    _p06_staged=$(nd2cn_stage_file "$P06_XML") || return 1
    for _p06_key in $_p06_todo; do
        _p06_set "$_p06_staged" "$_p06_key" "$P06_NEW" "$P06_OLD"
    done
    for _p06_key in $P06_KEYS; do
        if [ "$(_p06_get "$_p06_staged" "$_p06_key")" = "$P06_NEW" ]; then
            nd2cn_log "ERROR: restore verify failed for $_p06_key"
            rm -f "$_p06_staged"
            return 1
        fi
    done
    nd2cn_commit_staged "$P06_XML" "$_p06_staged" || return 1
    nd2cn_release_backup "$P06_XML" "$P06_TAG"
    nd2cn_log "limits restored to $P06_OLD"
    return 0
}
