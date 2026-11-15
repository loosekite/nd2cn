#!/bin/sh
# nd2cn plugin: Wireless CarPlay firewall opening (was patch 20, ENABLE_WCP flag)
#
# Background (firmware 74.00.324A):
#   - /usr/bin/carplayd contains a full AirPlay receiver; wpa_supplicant
#     supports WiFi P2P; BLM exposes EnableWirelessCarPlayConnection; the
#     settings GUI only shows WCP when _supportedWirelessCarPlay is true.
#   - /usr/bin/autostart picks /jci/sm/sm_WCP.conf only when
#     get_board_type.sh returns 2 (WCP-capable hardware). Otherwise sm.conf
#     runs "start_network.sh UCP", which runs "jci-fw.sh start" WITHOUT the
#     WCP chain.
#   - jci-fw.sh's help text advertises wcp-open / wcp-close, but those words
#     are NOT handled by its case statement. The real commands are
#     "wcpset" / "wcpdelete". wcpset only inserts a jump to the wcp_packets
#     chain, and that chain exists only after "jci-fw.sh start WCP".
#     Nothing else in the rootfs calls wcpset.
#
# What this plugin does (no rootfs change):
#   It installs a boot.d script. At boot, after start_network has started the
#   firewall, the script builds the wcp_packets chain if it is missing, with
#   rules identical to jci-fw.sh "start WCP". It then runs
#   "jci-fw.sh wcpset" and checks that the jump rule is present.
#
# Firewall idempotency (boot script, safe to run any number of times):
#   - chain missing            -> create + fill; marks /tmp/nd2cn_wcp_built
#   - chain has the 7 rules    -> left alone
#   - chain empty / ours with a wrong rule count (interrupted build)
#                              -> flushed and refilled
#   - chain with other rules not built by nd2cn -> left alone (warning)
#   - jump rule missing -> "jci-fw.sh wcpset"; duplicate jumps are removed
#   A failed build is rolled back completely.
#
# CAVEAT: this only opens the firewall for AirPlay (5000/7000/mDNS/ephemeral)
# from 192.168.100.0/24 on wlan0. Whether Wireless CarPlay actually works
# depends on carplayd/BLM reporting WCP support at runtime, which is likely
# gated by board type. This needs ON-CAR VERIFICATION. Check
# /tmp/nd2cn/boot.log after a reboot (tmpfs, cleared on the next reboot).
PLUGIN_NAME="wireless-carplay"
PLUGIN_DESC="Open the WiFi firewall ports Wireless CarPlay needs (EXPERIMENTAL, unverified)"
PLUGIN_RISK="experimental"
# requires: 00-boot-hook

P18_BOOT_SCRIPT="$ND2CN_BOOT_DIR/20-wireless-carplay.sh"   # v1 name, kept
P18_FW="$FIRMWARE_ROOT/jci/scripts/jci-fw.sh"
P18_IPT="$FIRMWARE_ROOT/usr/sbin/iptables"
P18_BUILT="/tmp/nd2cn_wcp_built"

plugin_check() {
    if [ ! -x "$P18_FW" ]; then
        nd2cn_log "FAIL: $P18_FW not found"
        return 1
    fi
    if ! grep -q '^wcpset()' "$P18_FW" || ! grep -q 'wcp_packets' "$P18_FW"; then
        nd2cn_log "FAIL: jci-fw.sh has no wcpset / wcp_packets support"
        return 1
    fi
    if [ ! -x "$P18_IPT" ]; then
        nd2cn_log "FAIL: $P18_IPT not found"
        return 1
    fi
    nd2cn_log "OK: jci-fw.sh wcpset + iptables"
    return 0
}

plugin_apply() {
    plugin_check || return 1

    nd2cn_install_file "$P18_BOOT_SCRIPT" 755 << 'BOOTEOF' || return 1
#!/bin/sh
# nd2cn 20: open Wireless CarPlay firewall ports (EXPERIMENTAL)
# Runs from the start_wifi.sh boot hook, after start_network has started
# the firewall. Safe to run more than once.
# NOTE: this only opens ports. Whether Wireless CarPlay works depends on
# carplayd/BLM reporting WCP support at runtime (needs on-car verification).
LOG=/tmp/nd2cn/boot.log
mkdir -p /tmp/nd2cn
FW=/jci/scripts/jci-fw.sh
IPT=/usr/sbin/iptables
KMOD=/lib/modules/3.0.35/kernel/net
CHAIN=wcp_packets
BUILT=/tmp/nd2cn_wcp_built
EXPECTED_RULES=7

log() { echo "[nd2cn 20] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

if [ -f /data/integration/developer_mode_on_flag ]; then
    log "developer mode: stock firewall is not started, nothing to open"
    exit 0
fi
if [ ! -x "$FW" ] || [ ! -x "$IPT" ]; then
    log "ERROR: $FW or $IPT missing"
    exit 0
fi

chain_exists() { "$IPT" -L "$CHAIN" -n > /dev/null 2>&1; }
# Rules in the chain (skip the two header lines of iptables -L)
rule_count() { "$IPT" -L "$CHAIN" -n 2>/dev/null | sed '1,2d' | grep -c .; }
jump_count() { "$IPT" -L INPUT -n 2>/dev/null | grep -c "^$CHAIN "; }

# The rate-limited ACCEPT must exist before the REJECT, or established
# WCP traffic would be rejected. Stops at the first failure.
add_rules() {
    "$IPT" -A "$CHAIN" -p tcp -i wlan0 -m state --state ESTABLISHED,RELATED -m hashlimit --hashlimit 1667/sec --hashlimit-mode dstip --hashlimit-burst 1000 --hashlimit-name 25Mbps -j ACCEPT || return 1
    "$IPT" -A "$CHAIN" -p tcp -i wlan0 -m state --state ESTABLISHED,RELATED -j REJECT --reject-with icmp-port-unreachable || return 1
    "$IPT" -A "$CHAIN" -p udp -i wlan0 --dport 5353 -j ACCEPT || return 1
    "$IPT" -A "$CHAIN" -p tcp -i wlan0 --dport 5000 -j ACCEPT || return 1
    "$IPT" -A "$CHAIN" -p tcp -i wlan0 --dport 7000 -j ACCEPT || return 1
    "$IPT" -A "$CHAIN" -p tcp -i wlan0 --dport 32768:61000 -j ACCEPT || return 1
    "$IPT" -A "$CHAIN" -p udp -i wlan0 --dport 32768:61000 -j ACCEPT || return 1
}

# Undo a failed build. The chain is only deleted if we created it.
rollback() {
    "$IPT" -F "$CHAIN" 2>/dev/null
    if [ -f "$BUILT" ]; then
        while [ "$(jump_count)" -gt 0 ] && "$FW" wcpdelete > /dev/null 2>&1; do :; done
        "$IPT" -X "$CHAIN" 2>/dev/null && rm -f "$BUILT"
    fi
    log "ERROR: $1, rolled back"
    exit 0
}

if chain_exists; then
    _n=$(rule_count)
    if [ "$_n" = "$EXPECTED_RULES" ]; then
        log "chain $CHAIN present with $_n rules"
    elif [ -f "$BUILT" ] || [ "$_n" = "0" ]; then
        log "chain $CHAIN incomplete ($_n rules), rebuilding"
        "$IPT" -F "$CHAIN" 2>/dev/null
        add_rules || rollback "rebuilding $CHAIN failed (hashlimit/REJECT module?)"
        log "rebuilt chain $CHAIN"
    else
        log "WARN: chain $CHAIN has $_n rules and was not built by nd2cn — left as is"
    fi
else
    log "chain $CHAIN missing (UCP board config), building it"
    # jci-fw.sh does not insmod these; ignore 'already loaded' errors
    insmod "$KMOD/netfilter/xt_hashlimit.ko" 2>/dev/null
    insmod "$KMOD/ipv4/netfilter/ipt_REJECT.ko" 2>/dev/null
    if ! "$IPT" -N "$CHAIN" 2>/dev/null; then
        log "ERROR: cannot create chain $CHAIN"
        exit 0
    fi
    : > "$BUILT"
    add_rules || rollback "building $CHAIN failed (hashlimit/REJECT module?)"
    log "built chain $CHAIN"
fi

_j=$(jump_count)
if [ "$_j" = "0" ]; then
    "$FW" wcpset >> "$LOG" 2>&1
    _j=$(jump_count)
    if [ "$_j" -ge 1 ]; then
        log "ran '$FW wcpset': WCP ports open on wlan0 for 192.168.100.0/24 (udp 5353, tcp 5000/7000, 32768-61000)"
        log "NOTE: Wireless CarPlay itself still depends on carplayd/BLM reporting WCP support at runtime (unverified)"
    else
        log "ERROR: '$FW wcpset' did not add the jump rule"
    fi
else
    log "WCP jump rule already present"
fi
# Remove duplicate jumps (e.g. wcpset run by hand)
_i=0
while [ "$(jump_count)" -gt 1 ] && [ "$_i" -lt 5 ]; do
    "$FW" wcpdelete > /dev/null 2>&1 || break
    _i=$((_i + 1))
done
[ "$_i" -gt 0 ] && log "removed $_i duplicate jump rule(s)"
exit 0
BOOTEOF
    rm -f "$P18_BOOT_SCRIPT.tmp"   # v1 leftover
    [ "$ND2CN_CHANGED" = "1" ] || nd2cn_log "already applied"
    nd2cn_log "boot.d runs '$P18_FW wcpset' (builds wcp_packets chain if missing)"
    nd2cn_log "NOTE: WCP needs carplayd/BLM runtime support. Verify on car via /tmp/nd2cn/boot.log after boot"
    return 0
}

plugin_remove() {
    rm -f "$P18_BOOT_SCRIPT" "$P18_BOOT_SCRIPT.tmp" "$P18_BOOT_SCRIPT.nd2cn.tmp"
    if ! nd2cn_is_live; then
        return 0
    fi
    # Live firewall: drop our jump rule(s); delete the chain only if nd2cn
    # built it this boot. Stock WCP setup is untouched; all of it disappears
    # at the next boot anyway.
    if [ -x "$P18_FW" ] && [ -x "$P18_IPT" ]; then
        _p18_i=0
        while "$P18_IPT" -L INPUT -n 2>/dev/null | grep -q '^wcp_packets ' && [ "$_p18_i" -lt 5 ]; do
            "$P18_FW" wcpdelete > /dev/null 2>&1 || break
            _p18_i=$((_p18_i + 1))
        done
        [ "$_p18_i" -gt 0 ] && nd2cn_log "Removed live WCP jump rule(s)"
        if [ -f "$P18_BUILT" ]; then
            "$P18_IPT" -F wcp_packets 2>/dev/null
            "$P18_IPT" -X wcp_packets 2>/dev/null && nd2cn_log "Removed nd2cn-built wcp_packets chain"
            rm -f "$P18_BUILT"
        fi
    fi
    return 0
}
