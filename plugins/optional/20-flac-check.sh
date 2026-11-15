#!/bin/sh
# nd2cn plugin: FLAC playback support check (DIAGNOSTIC ONLY) (was patch 22,
# ENABLE_FLAC flag)
#
# There are two decode paths for USB media (RACE media player, GStreamer 0.10):
#   1. beep (mfw_gst_beep): /usr/share/beep_registry.arm12.cf maps a codec to
#      a Freescale *wrap* library in /usr/lib/imx-mm/audio-codec/wrap/.
#      Stock registry: aac, mp3, wma, ac3, vorbis. The core decoder
#      lib_flac_dec_arm11_elinux.so exists, but there is NO
#      lib_flacd_wrap_*.so. beep only talks to wrap libs, so adding a [flac]
#      section would point at a library that does not exist.
#   2. Native GStreamer: /etc/race_mp_config.xml sets
#        flacparser -> flacparse   (libgstaudioparsers.so: present)
#        flacdec    -> ffdec_flac  (needs gst-ffmpeg's libgstffmpeg.so: ABSENT)
#      libavcodec.so.54 does contain a FLAC decoder, but nothing in the
#      firmware loads it into GStreamer.
# librace_interface.so has a FLAC tag parser, so FLAC files can be indexed
# and listed but fail when the pipeline tries to create ffdec_flac.
#
# Result on 74.00.324A: FLAC is NOT AVAILABLE, and no config-only change can
# enable it. This patch changes nothing. It runs the checks on the car and
# writes the result to /data/nd2cn/flac_status.txt (never to the USB stick),
# so a future firmware or an added decoder plugin shows up.
#
# Idempotency: the only output is the status report, rewritten on each run.
PLUGIN_NAME="flac-check"
PLUGIN_DESC="Diagnose FLAC decoder support into /data/nd2cn/flac_status.txt (changes nothing)"
PLUGIN_RISK="low"

P22_TAG="22-flac-enable"
P22_REGISTRY="$FIRMWARE_ROOT/usr/share/beep_registry.arm12.cf"
P22_CODEC_DIR="$FIRMWARE_ROOT/usr/lib/imx-mm/audio-codec"
P22_GST_DIR="$FIRMWARE_ROOT/usr/lib/gstreamer-0.10"
P22_RACE_CFG="$FIRMWARE_ROOT/etc/race_mp_config.xml"
P22_STATUS="$ND2CN_DIR/flac_status.txt"

# Print the <value> for a <name> in race_mp_config.xml (single-line entries).
_p22_race_value() {
    sed -n "s|.*<name>$1</name><value>\([^<]*\)</value>.*|\1|p" "$P22_RACE_CFG" 2>/dev/null | head -1
}

# First existing file matching a glob, or nothing.
_p22_first() {
    for _p22_f in $1; do
        [ -e "$_p22_f" ] && { echo "$_p22_f"; return 0; }
    done
    return 1
}

plugin_check() {
    if [ ! -f "$P22_RACE_CFG" ] && [ ! -f "$P22_REGISTRY" ]; then
        nd2cn_log "FAIL: neither $P22_RACE_CFG nor $P22_REGISTRY found"
        return 1
    fi
    nd2cn_log "OK: media config present (diagnostic only)"
    return 0
}

plugin_apply() {
    nd2cn_log "diagnostic only, no system changes"

    # ── beep path ──
    if grep -q '^\[flac\]' "$P22_REGISTRY" 2>/dev/null; then
        _p22_reg="yes"
    else
        _p22_reg="no"
    fi
    _p22_core=$(_p22_first "$P22_CODEC_DIR/lib_flac_dec_arm1*_elinux.so")
    _p22_wrap=$(_p22_first "$P22_CODEC_DIR/wrap/lib_flac*wrap*_elinux.so")

    # ── native GStreamer path ──
    _p22_parser=$(_p22_race_value flacparser)
    _p22_dec=$(_p22_race_value flacdec)
    _p22_parser_lib=""
    if grep -q 'gst_flac_parse' "$P22_GST_DIR/libgstaudioparsers.so" 2>/dev/null; then
        _p22_parser_lib="$P22_GST_DIR/libgstaudioparsers.so"
    fi
    # ffdec_* elements come from gst-ffmpeg (libgstffmpeg.so; NOT
    # libgstffmpegcolorspace.so, which is present but only converts video
    # colorspace). "flacdec" comes from gst-plugins-good (libgstflac.so).
    _p22_ffmpeg=$(_p22_first "$P22_GST_DIR/libgstffmpeg.so $P22_GST_DIR/libgstffmpeg-gpl.so")
    _p22_gstflac=$(_p22_first "$P22_GST_DIR/libgstflac.so")
    case "$_p22_dec" in
        ffdec_*) _p22_dec_lib="$_p22_ffmpeg" ;;
        flacdec) _p22_dec_lib="$_p22_gstflac" ;;
        *)       _p22_dec_lib="" ;;
    esac
    _p22_avcodec=$(_p22_first "$FIRMWARE_ROOT/usr/lib/libavcodec.so.*")

    # ── verdict ──
    _p22_beep_ok=no
    [ "$_p22_reg" = "yes" ] && [ -n "$_p22_wrap" ] && _p22_beep_ok=yes
    _p22_native_ok=no
    [ -n "$_p22_parser_lib" ] && [ -n "$_p22_dec_lib" ] && _p22_native_ok=yes
    if [ "$_p22_beep_ok" = "yes" ] || [ "$_p22_native_ok" = "yes" ]; then
        _p22_verdict="AVAILABLE"
    else
        _p22_verdict="NOT AVAILABLE"
    fi

    mkdir -p "$ND2CN_DIR"
    cat > "$P22_STATUS.tmp" << EOF
nd2cn 22: FLAC support status
Checked: $(date '+%Y-%m-%d %H:%M:%S')
Firmware: $(nd2cn_firmware_version)

STATUS: FLAC playback $_p22_verdict

[beep / Freescale decoder path]  usable: $_p22_beep_ok
  [flac] in $P22_REGISTRY: $_p22_reg
  core decoder: ${_p22_core:-MISSING}
  wrap library (required by beep): ${_p22_wrap:-MISSING}

[native GStreamer path, $P22_RACE_CFG]  usable: $_p22_native_ok
  flacparser -> ${_p22_parser:-<unset>}  plugin: ${_p22_parser_lib:-MISSING}
  flacdec    -> ${_p22_dec:-<unset>}  plugin: ${_p22_dec_lib:-MISSING}
  libgstffmpeg (gst-ffmpeg, provides ffdec_*): ${_p22_ffmpeg:-MISSING}
  libgstflac (gst-plugins-good flacdec): ${_p22_gstflac:-MISSING}
  libavcodec (has FLAC, but no GStreamer binding): ${_p22_avcodec:-MISSING}

Notes:
- beep can only use wrap libraries. Adding [flac] to the registry without
  lib_flacd_wrap_*.so would break nothing but enable nothing.
- RACE can index FLAC tags, so .flac files may be listed but not play.
- Manual check over SSH: gst-inspect-0.10 $_p22_dec ; gst-inspect-0.10 flacparse
- nd2cn made NO changes for FLAC.
EOF
    mv -f "$P22_STATUS.tmp" "$P22_STATUS" || return 1
    sync


    nd2cn_log "FLAC: $_p22_verdict (beep: registry=$_p22_reg wrap=${_p22_wrap:-none}; native: $_p22_parser=${_p22_parser_lib:+ok} $_p22_dec=${_p22_dec_lib:-missing})"
    if [ "$_p22_verdict" = "NOT AVAILABLE" ]; then
        nd2cn_log "FLAC cannot be enabled on this firmware (no beep wrap, no $_p22_dec plugin). See $P22_STATUS"
    fi
    nd2cn_log "done (no system changes)"
    return 0
}

plugin_remove() {
    rm -f "$P22_STATUS" "$P22_STATUS.tmp"
    return 0
}
