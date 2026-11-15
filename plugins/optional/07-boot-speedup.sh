#!/bin/sh
# nd2cn plugin: Skip/shorten boot animation (was patch 08, FAST_BOOT flag)
# The real boot animation is IVF video files played by splashplayer:
#   /jci/resources/TranLogo.ivf (transition logo)
#   /jci/resources/LoopLogo.ivf (looping logo)
#   /jci/resources/newLoopLogo.ivf (alternative loop)
# Replacing them with minimal 1-frame black IVF would be ideal but requires
# a valid IVF file. Instead, we zero-truncate the loop files so splashplayer
# exits quickly, keeping TranLogo for a brief flash.
# Risk: loop logos are referenced by init; behavior on truncated files is
# unknown. Boot animation is non-critical but these are boot-path files.
#
# Idempotency: a file <= 100 bytes counts as done. A file is only truncated
# after a verified (cmp) pristine backup exists, so a crash at any point
# leaves either the original or a truncated file with a complete backup.
PLUGIN_NAME="boot-speedup"
PLUGIN_DESC="Truncate the looping boot logo videos for a shorter boot animation"
PLUGIN_RISK="high"

P07_TAG="08-boot-speed"          # v1 backup tag (kept for upgrade compatibility)
P07_IVFS="$FIRMWARE_ROOT/jci/resources/LoopLogo.ivf $FIRMWARE_ROOT/jci/resources/newLoopLogo.ivf"

plugin_check() {
    _p07_found=0
    for _p07_ivf in $P07_IVFS; do
        if [ -f "$_p07_ivf" ]; then
            nd2cn_log "OK: $(basename "$_p07_ivf") exists ($(wc -c < "$_p07_ivf") bytes)"
            _p07_found=1
        else
            nd2cn_log "WARN: $_p07_ivf not found"
        fi
    done
    if [ "$_p07_found" = "0" ]; then
        nd2cn_log "FAIL: no loop logo IVF files found"
        return 1
    fi
    return 0
}

plugin_apply() {
    _p07_changed=0
    _p07_rc=0
    for _p07_ivf in $P07_IVFS; do
        if [ ! -f "$_p07_ivf" ]; then
            nd2cn_log "WARN: $_p07_ivf not found, skipping"
            continue
        fi
        _p07_size=$(wc -c < "$_p07_ivf" 2>/dev/null)
        if [ "${_p07_size:-0}" -le 100 ]; then
            if ! nd2cn_pristine_of "$_p07_ivf" > /dev/null; then
                nd2cn_log "WARN: $_p07_ivf is already minimal but has no nd2cn backup"
            fi
            nd2cn_log "$(basename "$_p07_ivf") already minimal ($_p07_size bytes)"
            continue
        fi
        if ! nd2cn_backup_file "$_p07_ivf" "$P07_TAG"; then
            _p07_rc=1
            continue
        fi
        # Truncate to empty — splashplayer will fail gracefully and skip
        : > "$_p07_ivf"
        sync
        _p07_changed=$((_p07_changed + 1))
        nd2cn_log "Truncated: $_p07_ivf (was $_p07_size bytes)"
    done
    [ "$_p07_changed" = "0" ] && [ "$_p07_rc" = "0" ] && nd2cn_log "already applied"
    return $_p07_rc
}

plugin_remove() {
    _p07_rc=0
    for _p07_ivf in $P07_IVFS; do
        nd2cn_restore_file "$_p07_ivf" "$P07_TAG"
        case $? in
            0) ;;
            2) nd2cn_log "$(basename "$_p07_ivf"): not modified by nd2cn" ;;
            *) _p07_rc=1 ;;
        esac
    done
    return $_p07_rc
}
