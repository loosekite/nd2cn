#!/bin/sh
# nd2cn plugin: Lower Bluetooth A2DP audio latency (was patch 21,
# REDUCE_BT_LATENCY flag)
# /jci/bds/BdsAudioBufferConfig.xml sets the BDS A2DP jitter buffer. bds reads
# only this rootfs path (hardcoded in /jci/bds/bds) and only at startup.
#
# One chunk = 8192 bytes = 46440 us at 44.1 kHz / 16-bit / stereo.
# Stock buffer: 44 chunks = 2.04 s. All thresholds are ABSOLUTE microsecond
# values, positioned in chunks:
#   buff_low_wm_us   1 chunk   buff_avg_us     ~12.9 chunks
#   buff_low_th_us  15 chunks  buff_midpoint_us 22 chunks (= N/2)
#   buff_high_th_us 39 chunks (= N-5)   buff_high_wm_us 43 chunks (= N-1)
# Changing num_of_chunk to 22 on its own would make the midpoint equal the
# whole buffer and put both high marks beyond its end. So this patch halves
# the buffer AND rescales every threshold to the same relative positions:
#   num_of_chunk      44       -> 22
#   buff_avg_us       600000   -> 300000
#   buff_midpoint_us  1021678  -> 510839   (11 chunks)
#   buff_low_th_us    696598   -> 325079   (7 chunks)
#   buff_high_th_us   1811156  -> 789478   (17 chunks = N-5)
#   buff_high_wm_us   1996916  -> 975238   (21 chunks = N-1)
#   buff_low_wm_us    46434       unchanged (1 chunk)
# The fill target (midpoint) drops from ~1.02 s to ~0.51 s.
# Several new values are below the "min" in the file's own comment block.
# Those ranges are already stale: stock buff_low_th_us is above its stated
# max. Still, this is NOT verified on hardware. bds runs with
# reset_board="yes", so watch for BT audio dropouts or reboots.
#
# Rootfs change (pristine backup kept, restored by uninstall.sh) plus a
# boot.d script that keeps an editable copy at /data/nd2cn/bt_audio_config.xml
# and SSH tuning notes at /data/nd2cn/bt_audio_config.README.
#
# Idempotency: every key is classified against the table:
#   old    all stock            -> rewrite to new (one atomic publish)
#   mixed  some stock, some new -> complete the rewrite (interrupted run)
#   new    all new              -> already applied
#   custom all present, other values (hand-tuned over SSH, see README)
#                               -> left untouched, warning only
#   bad    a key missing / not unique -> refuse
# Removal restores the pristine file (this also undoes hand tuning); without
# a backup it reverts table values only.
PLUGIN_NAME="bt-audio-latency"
PLUGIN_DESC="Halve the Bluetooth A2DP jitter buffer (~1.0 s -> ~0.5 s audio latency)"
PLUGIN_RISK="experimental"
# requires: 00-boot-hook

P21_TAG="21-bt-audio-latency"
P21_XML="$FIRMWARE_ROOT/jci/bds/BdsAudioBufferConfig.xml"
P21_BOOT_SCRIPT="$ND2CN_BOOT_DIR/21-bt-audio-latency.sh"
P21_DATA_XML="$ND2CN_DIR/bt_audio_config.xml"
P21_README="$ND2CN_DIR/bt_audio_config.README"

# key old new
P21_TABLE="num_of_chunk 44 22
buff_avg_us 600000 300000
buff_midpoint_us 1021678 510839
buff_low_th_us 696598 325079
buff_high_th_us 1811156 789478
buff_high_wm_us 1996916 975238"

# Print the attribute value of <buffer_param ... key="N" ...> (one per line).
# Fails if the key is absent or appears more than once.
_p21_get() {
    _p21_n=$(grep -c "^[[:space:]]*$2=\"" "$1")
    [ "$_p21_n" = "1" ] || return 1
    sed -n "s/^[[:space:]]*$2=\"\([0-9]*\)\".*/\1/p" "$1"
}

# Build a sed script that rewrites every key from column $1 to column $2
# (2 = old, 3 = new). Each key only changes if it currently holds the "from" value.
_p21_sed_expr() {
    echo "$P21_TABLE" | awk -v f="$1" -v t="$2" '
        { printf "s/^\\([[:space:]]*%s=\"\\)%s\"/\\1%s\"/;", $1, $f, $t }'
}

# Check every key in file $1. Prints "new" if all are at the new value,
# "old" if all are stock, "mixed" if both, "custom" if all keys exist but
# some hold other values, "bad" if a key is missing or not unique.
_p21_state() {
    _p21_old=0; _p21_new=0; _p21_other=0; _p21_bad=0
    while read -r _k _o _n; do
        [ -n "$_k" ] || continue
        _v=$(_p21_get "$1" "$_k")
        if [ -z "$_v" ]; then
            nd2cn_log "  $_k missing or not unique"
            _p21_bad=$((_p21_bad + 1))
        elif [ "$_v" = "$_n" ]; then
            _p21_new=$((_p21_new + 1))
        elif [ "$_v" = "$_o" ]; then
            _p21_old=$((_p21_old + 1))
        else
            nd2cn_log "  $_k = '$_v' (expected $_o or $_n)"
            _p21_other=$((_p21_other + 1))
        fi
    done << EOF
$P21_TABLE
EOF
    if [ "$_p21_bad" != "0" ]; then echo bad
    elif [ "$_p21_other" != "0" ]; then echo custom
    elif [ "$_p21_old" = "0" ]; then echo new
    elif [ "$_p21_new" = "0" ]; then echo old
    else echo mixed
    fi
}

# The README text below sits in TWO here-documents. The outer one (BOOTEOF)
# is unquoted, so $P21_XML, $P21_DATA_XML and $ND2CN_BACKUP_DIR are replaced
# by their paths now, while the boot script is generated. The inner one is
# quoted ('READMEEOF') on purpose: by then the paths are plain text, and the
# quoting keeps the boot script from expanding anything a second time.
# Checked: the generated script and the README it writes contain no "$".
_p21_install_boot_script() {
    _p21_fwd=$(_p21_sed_expr 2 3)
    nd2cn_install_file "$P21_BOOT_SCRIPT" 755 << BOOTEOF || return 1
#!/bin/sh
# nd2cn 21: keep an editable copy of the BT A2DP buffer config in /data.
# Never overwrites an existing copy (user edits survive reboots/reinstalls).
# bds reads only $P21_XML. See $P21_README.
_src="$P21_XML"
_dst="$P21_DATA_XML"
_log="$ND2CN_BOOT_LOG"
mkdir -p "$ND2CN_BOOT_LOG_DIR"
if [ ! -f "\$_dst" ] && [ -f "\$_src" ]; then
    cp "\$_src" "\$_dst.tmp" || exit 0
    # If the rootfs copy is still stock (patch not applied), pre-apply the
    # nd2cn low-latency values so the /data copy is ready to push.
    if grep -q '^[[:space:]]*num_of_chunk="44"' "\$_dst.tmp"; then
        sed -i '$_p21_fwd' "\$_dst.tmp"
    fi
    mv "\$_dst.tmp" "\$_dst" && sync
    echo "[nd2cn 21] wrote \$_dst" >> "\$_log"
fi
if [ ! -f "$P21_README" ]; then
    cat > "$P21_README" << 'READMEEOF'
nd2cn 21: Bluetooth A2DP buffer tuning
======================================
bds reads ONLY $P21_XML (at startup).
$P21_DATA_XML is your working copy; editing it alone does nothing.

Tune over SSH (see nd2cn patch 12):
  vi $P21_DATA_XML
  mount -o rw,remount /
  cp $P21_DATA_XML $P21_XML
  sync; mount -o ro,remount /
  reboot            # bds only reads the file at startup

Keep the thresholds consistent with num_of_chunk (N):
  1 chunk = chunk_size 8192 bytes = 46440 us at 44.1 kHz 16-bit stereo
  buff_low_wm_us   = 1 chunk        = 46434
  buff_midpoint_us = N/2 chunks     (fill target, roughly = latency)
  buff_low_th_us   = about 2/3 of the midpoint
  buff_high_th_us  = (N-5) chunks
  buff_high_wm_us  = (N-1) chunks
  buff_avg_us      = about 0.29 * N chunks (stock 600000 for N=44)
  Stock:   N=44  mid=1021678 low_th=696598 high_th=1811156 high_wm=1996916 avg=600000
  nd2cn:   N=22  mid=510839  low_th=325079 high_th=789478  high_wm=975238  avg=300000
  Example: N=16  mid=371519  low_th=232199 high_th=510839  high_wm=696598  avg=218000

Smaller buffers mean lower latency but more dropouts on weak BT links.
WARNING: bds is supervised with reset_board="yes". If a bad config makes
bds crash, the head unit reboots. Restore the stock file with:
  mount -o rw,remount /
  cp $ND2CN_BACKUP_DIR/_pristine/BdsAudioBufferConfig.xml.orig $P21_XML
  sync; mount -o ro,remount /; reboot
READMEEOF
fi
exit 0
BOOTEOF
    rm -f "$P21_BOOT_SCRIPT.tmp"   # v1 leftover
    return 0
}

plugin_check() {
    if [ ! -f "$P21_XML" ]; then
        nd2cn_log "FAIL: $P21_XML not found"
        return 1
    fi
    if [ "$(_p21_get "$P21_XML" chunk_size)" != "8192" ]; then
        nd2cn_log "FAIL: chunk_size is not 8192, the table values would be wrong"
        return 1
    fi
    _p21_st=$(_p21_state "$P21_XML")
    case "$_p21_st" in
        bad)
            nd2cn_log "FAIL: BdsAudioBufferConfig.xml keys missing"
            return 1 ;;
        custom)
            nd2cn_log "OK: BdsAudioBufferConfig.xml (hand-tuned values, will be left alone)" ;;
        *)
            nd2cn_log "OK: BdsAudioBufferConfig.xml num_of_chunk ($_p21_st)" ;;
    esac
    return 0
}

plugin_apply() {
    if [ ! -f "$P21_XML" ]; then
        nd2cn_log "ERROR: $P21_XML not found"
        return 1
    fi
    if [ "$(_p21_get "$P21_XML" chunk_size)" != "8192" ]; then
        nd2cn_log "ERROR: chunk_size is not 8192, values below would be wrong"
        return 1
    fi

    _p21_st=$(_p21_state "$P21_XML")
    case "$_p21_st" in
        new)
            nd2cn_log "rootfs values already applied" ;;
        old|mixed)
            _p21_staged=$(nd2cn_stage_file "$P21_XML") || return 1
            sed -i "$(_p21_sed_expr 2 3)" "$_p21_staged"
            if [ "$(_p21_state "$_p21_staged")" != "new" ] || \
               ! grep -q '</bdsAudioBufferConfig>' "$_p21_staged"; then
                nd2cn_log "ERROR: verify failed on staged $P21_XML"
                rm -f "$_p21_staged"
                return 1
            fi
            nd2cn_commit_staged "$P21_XML" "$_p21_staged" "$P21_TAG" || return 1
            nd2cn_log "BT A2DP buffer 44 -> 22 chunks (midpoint ~1.02 s -> ~0.51 s)" ;;
        custom)
            nd2cn_log "WARN: $P21_XML holds hand-tuned values — left untouched" ;;
        *)
            nd2cn_log "ERROR: $P21_XML has unexpected structure, not touching it"
            return 1 ;;
    esac

    _p21_install_boot_script || return 1
    # Create the /data copy + README now, before the first reboot.
    sh "$P21_BOOT_SCRIPT"
    nd2cn_log "working copy $P21_DATA_XML, notes $P21_README"
    nd2cn_log "NOTE: lower BT buffer is untested on hardware. Watch for dropouts"
    return 0
}

plugin_remove() {
    rm -f "$P21_BOOT_SCRIPT" "$P21_BOOT_SCRIPT.tmp" "$P21_BOOT_SCRIPT.nd2cn.tmp" \
          "$P21_DATA_XML" "$P21_DATA_XML.tmp" "$P21_README"

    # Pristine copy first: exact, and also undoes hand tuning
    nd2cn_restore_file "$P21_XML" "$P21_TAG"
    case $? in
        0) return 0 ;;
        2) ;;
        *) return 1 ;;
    esac

    [ -f "$P21_XML" ] || return 0
    _p21_st=$(_p21_state "$P21_XML")
    case "$_p21_st" in
        old)
            nd2cn_log "rootfs values not present (skip)"
            return 0 ;;
        new|mixed) ;;
        *)
            nd2cn_log "WARN: $P21_XML was hand-edited and no backup exists — left as is"
            return 1 ;;
    esac
    _p21_staged=$(nd2cn_stage_file "$P21_XML") || return 1
    sed -i "$(_p21_sed_expr 3 2)" "$_p21_staged"
    if [ "$(_p21_state "$_p21_staged")" != "old" ]; then
        nd2cn_log "ERROR: restore verify failed on $P21_XML"
        rm -f "$_p21_staged"
        return 1
    fi
    nd2cn_commit_staged "$P21_XML" "$_p21_staged" || return 1
    nd2cn_log "stock buffer values restored"
    return 0
}
