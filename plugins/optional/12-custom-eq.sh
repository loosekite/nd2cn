#!/bin/sh
# nd2cn plugin: Custom audio EQ profile (was patch 14)
# The DSP config is selected via a symlink: /data/dsp.xml -> /jci/dsp/<profile>.xml
# Contains a 25-band graphic EQ, noise compensation, gains, etc.
# We drop a custom profile in /data/ without touching rootfs.
# Put your profile in resources/eq/*.xml on the USB stick (first one wins).
#
# Idempotency: the profile is copied only if its content changed; the symlink
# is only re-pointed (atomically, via rename) if it does not already point at
# our profile. The previous state is recorded only when the link is NOT ours,
# so re-runs never record our own profile as the "original".
# Previous state records (in /data/nd2cn/eq/):
#   original_dsp_target.txt  /data/dsp.xml was a symlink to this target (v1 format)
#   original_dsp.xml         /data/dsp.xml was a regular file (copy of it)
#   original_dsp.none        /data/dsp.xml did not exist
PLUGIN_NAME="custom-eq"
PLUGIN_DESC="Use a custom DSP/EQ profile from resources/eq/*.xml (takes effect after reboot)"
PLUGIN_RISK="medium"

P12_DSP_LINK="$FIRMWARE_ROOT/data/dsp.xml"
P12_EQ_DIR="$ND2CN_DIR/eq"
P12_CUSTOM="$P12_EQ_DIR/custom_dsp.xml"
P12_REC_LINK="$P12_EQ_DIR/original_dsp_target.txt"
P12_REC_FILE="$P12_EQ_DIR/original_dsp.xml"
P12_REC_NONE="$P12_EQ_DIR/original_dsp.none"
P12_SRC_DIR="$ND2CN_SRC_DIR/resources/eq"

_p12_usb_profile() {
    for _p12_eq in "$P12_SRC_DIR"/*.xml; do
        [ -f "$_p12_eq" ] && [ -s "$_p12_eq" ] && { echo "$_p12_eq"; return 0; }
    done
    return 1
}

_p12_is_ours() {
    [ -L "$P12_DSP_LINK" ] && [ "$(readlink "$P12_DSP_LINK")" = "$P12_CUSTOM" ]
}

_p12_has_record() {
    [ -f "$P12_REC_LINK" ] || [ -f "$P12_REC_FILE" ] || [ -f "$P12_REC_NONE" ]
}

plugin_check() {
    if ! command -v readlink > /dev/null 2>&1; then
        nd2cn_log "FAIL: readlink not available"
        return 1
    fi
    if _p12_profile=$(_p12_usb_profile); then
        if ! grep -q '<' "$_p12_profile"; then
            nd2cn_log "FAIL: $(basename "$_p12_profile") does not look like XML"
            return 1
        fi
        nd2cn_log "OK: EQ profile $(basename "$_p12_profile")"
    elif [ -s "$P12_CUSTOM" ]; then
        nd2cn_log "OK: no profile on USB, keeping installed $P12_CUSTOM"
    else
        nd2cn_log "FAIL: no EQ profile in resources/eq/*.xml"
        return 1
    fi
    return 0
}

plugin_apply() {
    mkdir -p "$P12_EQ_DIR" || return 1

    # ── Profile ──
    if _p12_profile=$(_p12_usb_profile); then
        nd2cn_install_file "$P12_CUSTOM" 644 < "$_p12_profile" || return 1
        [ "$ND2CN_CHANGED" = "1" ] && nd2cn_log "Installed custom EQ: $(basename "$_p12_profile")"
    elif [ ! -s "$P12_CUSTOM" ]; then
        nd2cn_log "ERROR: no EQ profile in resources/eq/ and none installed"
        return 1
    fi

    # ── Symlink ──
    if _p12_is_ours; then
        nd2cn_log "already applied (DSP symlink -> $P12_CUSTOM)"
        return 0
    fi

    # Record the state we are replacing (the link is not ours, so this is
    # the real previous state — also after a manual change over SSH)
    if [ -L "$P12_DSP_LINK" ]; then
        _p12_cur=$(readlink "$P12_DSP_LINK")
        echo "$_p12_cur" > "$P12_REC_LINK.tmp" && mv -f "$P12_REC_LINK.tmp" "$P12_REC_LINK" || return 1
        rm -f "$P12_REC_FILE" "$P12_REC_NONE"
        nd2cn_log "Current DSP target: $_p12_cur"
    elif [ -f "$P12_DSP_LINK" ]; then
        if ! cp -p "$P12_DSP_LINK" "$P12_REC_FILE.tmp" || \
           ! cmp -s "$P12_DSP_LINK" "$P12_REC_FILE.tmp" || \
           ! mv -f "$P12_REC_FILE.tmp" "$P12_REC_FILE"; then
            rm -f "$P12_REC_FILE.tmp"
            nd2cn_log "ERROR: cannot back up regular file $P12_DSP_LINK"
            return 1
        fi
        rm -f "$P12_REC_LINK" "$P12_REC_NONE"
        nd2cn_log "WARN: $P12_DSP_LINK was a regular file; saved to $P12_REC_FILE"
    elif [ -e "$P12_DSP_LINK" ]; then
        nd2cn_log "ERROR: $P12_DSP_LINK is neither a file nor a symlink — not touching it"
        return 1
    else
        : > "$P12_REC_NONE"
        rm -f "$P12_REC_LINK" "$P12_REC_FILE"
        nd2cn_log "No $P12_DSP_LINK existed before"
    fi
    sync

    # Atomic re-point: build the new link aside, rename over the old one
    rm -f "$P12_DSP_LINK.nd2cn.tmp"
    if ! ln -s "$P12_CUSTOM" "$P12_DSP_LINK.nd2cn.tmp" || \
       ! mv -f "$P12_DSP_LINK.nd2cn.tmp" "$P12_DSP_LINK"; then
        rm -f "$P12_DSP_LINK.nd2cn.tmp"
        nd2cn_log "ERROR: could not point $P12_DSP_LINK at $P12_CUSTOM"
        return 1
    fi
    sync
    nd2cn_log "DSP symlink -> $P12_CUSTOM (takes effect after reboot)"
    return 0
}

plugin_remove() {
    if [ ! -e "$P12_DSP_LINK" ] && [ ! -L "$P12_DSP_LINK" ] && ! _p12_has_record; then
        nd2cn_log "not applied"
        rm -f "$P12_CUSTOM"
        return 0
    fi

    if _p12_is_ours; then
        rm -f "$P12_DSP_LINK.nd2cn.tmp"
        if [ -f "$P12_REC_LINK" ] && [ -n "$(cat "$P12_REC_LINK")" ]; then
            _p12_orig=$(cat "$P12_REC_LINK")
            ln -s "$_p12_orig" "$P12_DSP_LINK.nd2cn.tmp" && \
                mv -f "$P12_DSP_LINK.nd2cn.tmp" "$P12_DSP_LINK" || return 1
            nd2cn_log "DSP symlink restored -> $_p12_orig"
        elif [ -f "$P12_REC_FILE" ]; then
            cp -p "$P12_REC_FILE" "$P12_DSP_LINK.nd2cn.tmp" && \
                mv -f "$P12_DSP_LINK.nd2cn.tmp" "$P12_DSP_LINK" || return 1
            nd2cn_log "DSP config restored as regular file"
        elif [ -f "$P12_REC_NONE" ]; then
            rm -f "$P12_DSP_LINK"
            nd2cn_log "DSP symlink removed (none existed before)"
        else
            nd2cn_log "ERROR: no record of the original DSP config — keeping custom profile in place"
            return 1
        fi
        sync
    else
        nd2cn_log "WARN: $P12_DSP_LINK no longer points at the nd2cn profile (changed by hand) — left as is"
    fi
    rm -f "$P12_CUSTOM" "$P12_REC_LINK" "$P12_REC_FILE" "$P12_REC_NONE"
    rmdir "$P12_EQ_DIR" 2>/dev/null
    return 0
}
