#!/bin/sh
# nd2cn plugin: Use BeiDou instead of GLONASS (was patch 16)
# The u-blox M8 receiver cannot run GLONASS and BeiDou at the same time: the
# M8 datasheets (e.g. LEA-M8S, Table 2) state that "either GLONASS or BeiDou
# can be processed concurrently with GPS and Galileo". GPS+GLONASS+BeiDou is
# NOT a permitted combination, so BeiDou cannot simply be added to the stock
# configuration — it has to replace GLONASS.
#
# Stock:  GPS=ON SBAS=ON Galileo=OFF BeiDou=OFF IMES=OFF QZSS=ON GLONASS=ON
# Target: GPS=ON SBAS=ON Galileo=OFF BeiDou=ON  IMES=OFF QZSS=ON GLONASS=OFF
# i.e. GPS + BeiDou, with the SBAS and QZSS augmentation systems unchanged.
# TRADE-OFF: GLONASS is switched off. Galileo stays off, as in stock.
#
# The UBX-CFG-GNSS init message is at file offset 0xa288 in
# libjcilds-ublox.so: 6-byte header, 4-byte payload header (7 config blocks),
# then 8 bytes per block (gnssId, resTrkCh, maxTrkCh, reserved, 4 flag bytes;
# bit 0 of the first flag byte = enable). The two checksum bytes after the
# payload are 00 00 in the file, i.e. not a precomputed checksum.
#   block 2 Galileo  gnssId 02 at 0xa2a2, enable flag at 0xa2a6 = 41638
#   block 3 BeiDou   gnssId 03 at 0xa2aa, enable flag at 0xa2ae = 41646
#   block 6 GLONASS  gnssId 06 at 0xa2c2, enable flag at 0xa2c6 = 41670
# Earlier nd2cn versions left an invalid combination behind, which this
# plugin repairs: v1 enabled BeiDou AND Galileo next to GLONASS, v2.0 enabled
# BeiDou next to GLONASS.
#
# Safety: verifies UBX sync bytes, gnssId values, and flag values before writing.
# Idempotency: target state is Galileo=00 BeiDou=01 GLONASS=00. Already there
# → skip; otherwise only the flag bytes that differ are written (one atomic
# publish).
#
# IN-USE LIBRARY: /jci/lds/svcjcilds.so has NEEDED libjcilds-ublox.so, so the
# running jciLDS service keeps the old file mapped. The atomic mv unlinks the
# old inode while it is still mapped, and the kernel then refuses
# "mount -o ro,remount /" with EBUSY until that process is gone. jciLDS must
# NOT be killed or restarted (sm.conf: reset_board="yes" reboots the CMU).
# A boot-time swap does not help either: sm.conf starts jciLDS right after
# jciUSBMGR, long before start_wifi.sh (and so boot.d) runs, so the library
# is already mapped then. So the new file is published now, / stays rw until
# the reboot that install.sh/uninstall.sh does anyway, and nd2cn_finalize
# reports that as "deferred" (expected), not as a failure. The reboot loads
# the patched library and mounts / ro again. The same applies to
# plugin_remove.
PLUGIN_NAME="beidou-enable"
PLUGIN_DESC="Use BeiDou instead of GLONASS in u-blox GNSS (GPS+BeiDou+SBAS+QZSS; M8 cannot run both)"
PLUGIN_RISK="medium"

P14_TAG="16-beidou"                  # v1 backup tag (kept for upgrade compatibility)
P14_LIB="$FIRMWARE_ROOT/jci/lib/libjcilds-ublox.so"

# Offsets in the file (byte-level verified against firmware binary):
P14_UBX_SYNC_OFFSET=41608      # 0xa288: b5 62 06 3e (sync, CFG, GNSS)
P14_GAL_ID_OFFSET=41634        # 0xa2a2: block 2 gnssId (expect 02)
P14_GAL_FLAG_OFFSET=41638      # 0xa2a6: block 2 flags byte 0
P14_BEI_ID_OFFSET=41642        # 0xa2aa: block 3 gnssId (expect 03)
P14_BEI_FLAG_OFFSET=41646      # 0xa2ae: block 3 flags byte 0
P14_GLO_ID_OFFSET=41666        # 0xa2c2: block 6 gnssId (expect 06)
P14_GLO_FLAG_OFFSET=41670      # 0xa2c6: block 6 flags byte 0

P14_TARGET="00 01 00"          # Galileo BeiDou GLONASS
P14_STOCK="00 00 01"

# Verify the structure of FILE; prints "gal bei glo" flag bytes on success.
_p14_inspect() {
    _p14_sync=$(nd2cn_read_byte "$1" $P14_UBX_SYNC_OFFSET 4)
    if [ "$_p14_sync" != "b562063e" ]; then
        nd2cn_log "UBX-CFG-GNSS sync bytes not found at 0x$(printf '%x' $P14_UBX_SYNC_OFFSET) (got '$_p14_sync')"
        return 1
    fi
    _p14_gid=$(nd2cn_read_byte "$1" $P14_GAL_ID_OFFSET)
    _p14_bid=$(nd2cn_read_byte "$1" $P14_BEI_ID_OFFSET)
    _p14_rid=$(nd2cn_read_byte "$1" $P14_GLO_ID_OFFSET)
    if [ "$_p14_gid" != "02" ] || [ "$_p14_bid" != "03" ] || [ "$_p14_rid" != "06" ]; then
        nd2cn_log "unexpected gnssId bytes (block2=$_p14_gid expect 02, block3=$_p14_bid expect 03, block6=$_p14_rid expect 06)"
        return 1
    fi
    _p14_gal=$(nd2cn_read_byte "$1" $P14_GAL_FLAG_OFFSET)
    _p14_bei=$(nd2cn_read_byte "$1" $P14_BEI_FLAG_OFFSET)
    _p14_glo=$(nd2cn_read_byte "$1" $P14_GLO_FLAG_OFFSET)
    for _p14_v in "$_p14_gal" "$_p14_bei" "$_p14_glo"; do
        case "$_p14_v" in
            00|01) ;;
            *) nd2cn_log "unexpected flag values (gal=$_p14_gal bei=$_p14_bei glo=$_p14_glo)"
               return 1 ;;
        esac
    done
    echo "$_p14_gal $_p14_bei $_p14_glo"
}

# After the library file was replaced on a live system (see IN-USE LIBRARY).
_p14_inuse_note() {
    nd2cn_is_live || return 0
    nd2cn_log "NOTE: the running jciLDS keeps the old library mapped until the reboot; / cannot be set read-only before then (expected, not an error)"
}

plugin_check() {
    if [ ! -f "$P14_LIB" ]; then
        nd2cn_log "FAIL: $P14_LIB not found"
        return 1
    fi
    if ! _p14_st=$(_p14_inspect "$P14_LIB"); then
        nd2cn_log "FAIL: libjcilds-ublox.so does not match the expected layout"
        return 1
    fi
    nd2cn_log "OK: UBX-CFG-GNSS layout verified (gal/bei/glo flags: $_p14_st)"
    return 0
}

plugin_apply() {
    if [ ! -f "$P14_LIB" ]; then
        nd2cn_log "ERROR: $P14_LIB not found"
        return 1
    fi
    if ! _p14_st=$(_p14_inspect "$P14_LIB"); then
        nd2cn_log "ERROR: layout check failed, not touching $P14_LIB"
        return 1
    fi
    # shellcheck disable=SC2086
    set -- $_p14_st
    nd2cn_log "Current flags: Galileo=0x$1 BeiDou=0x$2 GLONASS=0x$3"
    if [ "$_p14_st" = "$P14_TARGET" ]; then
        nd2cn_log "already applied (BeiDou on, GLONASS off, Galileo off)"
        return 0
    fi

    _p14_staged=$(nd2cn_stage_file "$P14_LIB") || return 1
    if [ "$2" = "00" ]; then
        nd2cn_write_byte "$_p14_staged" $P14_BEI_FLAG_OFFSET 01
    fi
    if [ "$3" = "01" ]; then
        # u-blox M8: GLONASS and BeiDou cannot be processed concurrently
        nd2cn_log "Disabling GLONASS (u-blox M8 cannot run GLONASS and BeiDou together)"
        nd2cn_write_byte "$_p14_staged" $P14_GLO_FLAG_OFFSET 00
    fi
    if [ "$1" = "01" ]; then
        # nd2cn v1 enabled Galileo as well; back to the stock value
        nd2cn_log "WARN: Galileo is enabled (nd2cn v1?) — switching it back off (stock)"
        nd2cn_write_byte "$_p14_staged" $P14_GAL_FLAG_OFFSET 00
    fi

    # Verify: target flags, at most the three flag bytes changed, size unchanged
    _p14_new=$(_p14_inspect "$_p14_staged")
    _p14_diff=$(cmp -l "$P14_LIB" "$_p14_staged" 2>/dev/null | wc -l)
    if [ "$_p14_new" != "$P14_TARGET" ] || [ "$_p14_diff" -gt 3 ] || \
       [ "$(wc -c < "$P14_LIB")" != "$(wc -c < "$_p14_staged")" ]; then
        rm -f "$_p14_staged"
        nd2cn_log "ERROR: patch verification failed (flags='$_p14_new', bytes changed=$_p14_diff)"
        return 1
    fi

    nd2cn_commit_staged "$P14_LIB" "$_p14_staged" "$P14_TAG" || return 1
    nd2cn_log "BeiDou enabled, GLONASS disabled: config now GPS+BeiDou+SBAS+QZSS (takes effect after reboot)"
    _p14_inuse_note
    return 0
}

plugin_remove() {
    nd2cn_restore_file "$P14_LIB" "$P14_TAG"
    case $? in
        0) [ "$ND2CN_CHANGED" = "1" ] && _p14_inuse_note
           return 0 ;;
        2) ;;
        *) return 1 ;;
    esac
    # No pristine copy: write the stock BeiDou/GLONASS flags back (layout-checked)
    [ -f "$P14_LIB" ] || return 0
    _p14_st=$(_p14_inspect "$P14_LIB") || {
        nd2cn_log "ERROR: layout check failed, not touching $P14_LIB"
        return 1
    }
    # shellcheck disable=SC2086
    set -- $_p14_st
    if [ "$2" = "00" ] && [ "$3" = "01" ]; then
        nd2cn_log "not applied"
        return 0
    fi
    _p14_staged=$(nd2cn_stage_file "$P14_LIB") || return 1
    [ "$2" = "00" ] || nd2cn_write_byte "$_p14_staged" $P14_BEI_FLAG_OFFSET 00
    [ "$3" = "01" ] || nd2cn_write_byte "$_p14_staged" $P14_GLO_FLAG_OFFSET 01
    _p14_new=$(_p14_inspect "$_p14_staged")
    _p14_diff=$(cmp -l "$P14_LIB" "$_p14_staged" 2>/dev/null | wc -l)
    if [ "$_p14_new" != "$1 00 01" ] || [ "$_p14_diff" -gt 2 ] || \
       [ "$(wc -c < "$P14_LIB")" != "$(wc -c < "$_p14_staged")" ]; then
        rm -f "$_p14_staged"
        nd2cn_log "ERROR: revert verification failed (flags='$_p14_new', bytes changed=$_p14_diff)"
        return 1
    fi
    nd2cn_commit_staged "$P14_LIB" "$_p14_staged" || return 1
    nd2cn_log "BeiDou off, GLONASS on again (stock; Galileo untouched)"
    _p14_inuse_note
    return 0
}
