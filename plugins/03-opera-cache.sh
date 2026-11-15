#!/bin/sh
# nd2cn plugin: Opera browser cache on tmpfs (was patch 03)
# Dramatically improves UI responsiveness by caching parsed pages.
# Cache goes to /tmp/nd2cn_cache (tmpfs) to avoid flash wear.
# /tmp is empty at every boot, so a boot.d script recreates the directory.
# TIMING: boot.d runs from the start_wifi.sh boot hook, which runs AFTER
# Opera has started and loaded the GUI — not before. The directory therefore
# does not exist yet for Opera's first page load of a session; the disk cache
# only works from the second page load on (once the hook has run). The RAM
# cache sizes ([Cache] Figure/Document) do not depend on the directory.
#
# Idempotency: nd2cn_ini_set is a pure "set key" operation, so the staged
# opera.ini is identical to the live one once applied (nothing published).
# The boot.d script is (re)installed on every run, so a run that was
# interrupted after publishing opera.ini is completed by the next one.
#
# Shared file: 21-track-dashboard also edits opera.ini ([User Prefs], a
# different section). Each plugin stages the CURRENT live file and sets only
# its own keys, so neither loses the other's edits. The pristine backup is
# write-once (the first plugin to touch the file takes it) and each plugin
# holds its own reference. Removal goes through nd2cn_ini_undo: whole-file
# restore if this is the last user, key-level revert otherwise.
PLUGIN_NAME="opera-cache"
PLUGIN_DESC="Enable Opera disk cache on tmpfs and larger RAM cache (faster UI)"
PLUGIN_RISK="low"
# requires: 00-boot-hook

P03_TAG="03-opera-cache"
P03_OPERA_INI="$FIRMWARE_ROOT/jci/opera/opera_home/opera.ini"
P03_CACHE_DIR="/tmp/nd2cn_cache"
P03_BOOT_SCRIPT="$ND2CN_BOOT_DIR/03-opera-cache.sh"

# section|key|value
P03_SETTINGS="Disk Cache|Enabled|1
Disk Cache|Size|8000
Disk Cache|Cache Directory4|$P03_CACHE_DIR
Disk Cache|Empty On Exit|1
Cache|Figure|16000
Cache|Document|4000"

plugin_check() {
    if [ ! -f "$P03_OPERA_INI" ]; then
        nd2cn_log "FAIL: $P03_OPERA_INI not found"
        return 1
    fi
    if ! grep -q '^\[Disk Cache\]' "$P03_OPERA_INI"; then
        nd2cn_log "FAIL: opera.ini has no [Disk Cache] section"
        return 1
    fi
    nd2cn_log "OK: opera.ini Disk Cache section"
    return 0
}

plugin_apply() {
    if [ ! -f "$P03_OPERA_INI" ]; then
        nd2cn_log "ERROR: $P03_OPERA_INI not found"
        return 1
    fi

    _p03_staged=$(nd2cn_stage_file "$P03_OPERA_INI") || return 1
    # The cache directory key in Opera Devices SDK is "Cache Directory4"
    _p03_ok=1
    while IFS='|' read -r _p03_s _p03_k _p03_v; do
        [ -n "$_p03_s" ] || continue
        nd2cn_ini_set "$_p03_staged" "$_p03_s" "$_p03_k" "$_p03_v" || _p03_ok=0
    done << EOF
$P03_SETTINGS
EOF
    if [ "$_p03_ok" != "1" ] || ! nd2cn_has_line "Cache Directory4=$P03_CACHE_DIR" "$_p03_staged"; then
        rm -f "$_p03_staged"
        nd2cn_log "ERROR: editing staged opera.ini failed"
        return 1
    fi
    nd2cn_commit_staged "$P03_OPERA_INI" "$_p03_staged" "$P03_TAG" || return 1
    if [ "$ND2CN_CHANGED" = "1" ]; then
        nd2cn_log "opera.ini cache settings applied"
    else
        nd2cn_log "opera.ini already applied"
    fi

    # Create the tmpfs directory now (for this session)
    nd2cn_is_live && mkdir -p "$P03_CACHE_DIR"

    # boot.d script recreates the dir on every boot. It runs after Opera has
    # started (see TIMING above), so the first page load is not disk-cached.
    nd2cn_install_file "$P03_BOOT_SCRIPT" 755 << BOOTEOF || return 1
#!/bin/sh
mkdir -p $P03_CACHE_DIR
BOOTEOF
    return 0
}

plugin_remove() {
    _p03_rc=0
    # opera.ini is shared with 21-track-dashboard ([User Prefs] Allow File
    # XMLHttpRequest): restore the pristine file only when no other plugin
    # still uses it, otherwise revert just the keys set here.
    nd2cn_ini_undo "$P03_OPERA_INI" "$P03_TAG" "$(echo "$P03_SETTINGS" | cut -d'|' -f1,2)" || _p03_rc=1
    rm -f "$P03_BOOT_SCRIPT" "$P03_BOOT_SCRIPT.nd2cn.tmp"
    nd2cn_is_live && rm -rf "$P03_CACHE_DIR"
    return $_p03_rc
}
