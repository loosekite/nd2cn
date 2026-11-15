#!/bin/sh
# nd2cn plugin: SSH access (was patch 12; previously enabled by the presence
# of resources/ssh_keys/*.pub)
# sshd ALREADY RUNS on port 36000 (start_network.sh:30).
# What's missing is an authorized public key.
# Default AuthorizedKeysFile is /config-mfg/authorized_keys (squashfs, read-only).
# We redirect sshd config to read keys from /data/nd2cn/ssh/authorized_keys
# and generate fresh host keys (firmware ships the same keys on every unit).
# Firewall allows SSH on USB-ethernet (eth1 192.168.42.1) but blocks WiFi.
#
# Put your public key(s) in resources/ssh_keys/*.pub on the USB stick.
#
# Idempotency: a key line is only appended if it is not in authorized_keys
# yet; each host key is generated only if missing; sshd_config and the boot.d
# script are rewritten only if their content changes; sshd is restarted only
# when the config changed or sshd is not running with our config.
# Only the listening daemon is restarted, found through its PID file
# (/var/run/sshd.pid — the OpenSSH default; neither the stock nor our config
# sets PidFile). "killall sshd" is not used: every open SSH session is a
# process named sshd too, so it would also cut the session that is running
# this installer.
# Removal keeps authorized_keys and the host keys (inert without our
# sshd_config) so a reinstall does not change the host fingerprint.
PLUGIN_NAME="ssh-access"
PLUGIN_DESC="Key-only root SSH on port 36000 (USB-ethernet) with per-car host keys"
PLUGIN_RISK="medium"
# requires: 00-boot-hook

P11_SSH_DIR="$ND2CN_DIR/ssh"
P11_AUTH="$P11_SSH_DIR/authorized_keys"
P11_CONF="$P11_SSH_DIR/sshd_config"
P11_BOOT_SCRIPT="$ND2CN_BOOT_DIR/12-sshd.sh"    # v1 name, kept
P11_SSHD="$FIRMWARE_ROOT/usr/sbin/sshd"
P11_KEY_SRC="$ND2CN_SRC_DIR/resources/ssh_keys"
P11_PIDFILE="/var/run/sshd.pid"

_p11_usb_keys() {
    for _p11_k in "$P11_KEY_SRC"/*.pub; do
        [ -f "$_p11_k" ] && [ -s "$_p11_k" ] && return 0
    done
    return 1
}

# Print the PID of the listening sshd daemon (from its PID file). Fails if
# there is none, or if the PID in a stale file now belongs to something else.
# pidof cannot be used: per-session children are named sshd as well.
_p11_daemon_pid() {
    _p11_dp=$(cat "$P11_PIDFILE" 2>/dev/null)
    case "$_p11_dp" in
        ''|*[!0-9]*) return 1 ;;
    esac
    grep -q sshd "/proc/$_p11_dp/cmdline" 2>/dev/null || return 1
    echo "$_p11_dp"
}

# The listening daemon runs with our config
_p11_ours_running() {
    _p11_pid=$(_p11_daemon_pid) || return 1
    tr '\0' ' ' < "/proc/$_p11_pid/cmdline" 2>/dev/null | grep -qF "$P11_CONF"
}

# Restart the listener with config $1 (stock config if empty). Open sessions
# are left alone. Succeeds if a listening daemon is up afterwards.
_p11_restart_sshd() {
    nd2cn_is_live || { nd2cn_log "offline root: not restarting sshd"; return 0; }
    if _p11_pid=$(_p11_daemon_pid); then
        kill "$_p11_pid" 2>/dev/null
    fi
    sleep 1
    if [ -n "$1" ]; then
        "$P11_SSHD" -f "$1" 2>/dev/null
    else
        "$P11_SSHD" 2>/dev/null
    fi
    sleep 1
    _p11_daemon_pid > /dev/null
}

plugin_check() {
    if [ ! -x "$P11_SSHD" ]; then
        nd2cn_log "FAIL: $P11_SSHD not found"
        return 1
    fi
    if _p11_usb_keys; then
        nd2cn_log "OK: public key(s) found in resources/ssh_keys/"
    elif [ -s "$P11_AUTH" ]; then
        nd2cn_log "OK: no keys on USB, using existing $P11_AUTH"
    else
        nd2cn_log "FAIL: no public keys in resources/ssh_keys/*.pub and no existing $P11_AUTH"
        return 1
    fi
    command -v ssh-keygen > /dev/null 2>&1 || \
        nd2cn_log "WARN: ssh-keygen not available, stock host keys will be used"
    return 0
}

plugin_apply() {
    if ! mkdir -p "$P11_SSH_DIR"; then
        nd2cn_log "ERROR: cannot create $P11_SSH_DIR"
        return 1
    fi
    touch "$P11_AUTH" && chmod 600 "$P11_AUTH"

    # ── Authorized keys (append only new lines) ──
    _p11_added=0
    for _p11_key in "$P11_KEY_SRC"/*.pub; do
        [ -f "$_p11_key" ] || continue
        while IFS= read -r _p11_line || [ -n "$_p11_line" ]; do
            _p11_line=$(printf '%s' "$_p11_line" | tr -d '\r')
            case "$_p11_line" in ''|'#'*) continue ;; esac
            if ! nd2cn_has_line "$_p11_line" "$P11_AUTH"; then
                printf '%s\n' "$_p11_line" >> "$P11_AUTH"
                _p11_added=$((_p11_added + 1))
                nd2cn_log "Added SSH key from $(basename "$_p11_key")"
            fi
        done < "$_p11_key"
    done
    [ "$_p11_added" = "0" ] && nd2cn_log "authorized_keys already up to date"
    if [ ! -s "$P11_AUTH" ]; then
        nd2cn_log "WARN: $P11_AUTH is empty — add keys there to log in"
    fi

    # ── Host keys (generate each one only if missing) ──
    if command -v ssh-keygen > /dev/null 2>&1; then
        for _p11_t in rsa ecdsa; do
            _p11_hk="$P11_SSH_DIR/ssh_host_${_p11_t}_key"
            [ -s "$_p11_hk" ] && continue
            rm -f "$_p11_hk" "$_p11_hk.pub"
            if ssh-keygen -t "$_p11_t" -f "$_p11_hk" -N "" -q 2>/dev/null; then
                nd2cn_log "Generated $_p11_t host key"
            else
                rm -f "$_p11_hk" "$_p11_hk.pub"
                nd2cn_log "WARN: could not generate $_p11_t host key"
            fi
        done
    else
        nd2cn_log "WARN: ssh-keygen not available, using default host keys"
    fi

    # ── sshd config ──
    # Stock requires UsePrivilegeSeparation no and StrictModes no (no
    # /var/empty, no sshd user). HostKey lines only for keys that exist,
    # otherwise sshd falls back to its default host keys.
    {
        echo "Port 36000"
        echo "AddressFamily inet"
        echo "Protocol 2"
        for _p11_t in rsa ecdsa; do
            [ -s "$P11_SSH_DIR/ssh_host_${_p11_t}_key" ] && \
                echo "HostKey $P11_SSH_DIR/ssh_host_${_p11_t}_key"
        done
        echo "PermitRootLogin yes"
        echo "PubkeyAuthentication yes"
        echo "AuthorizedKeysFile $P11_AUTH"
        echo "PasswordAuthentication no"
        echo "PermitEmptyPasswords no"
        echo "UsePrivilegeSeparation no"
        echo "StrictModes no"
        echo "Subsystem sftp /usr/libexec/sftp-server"
    } | nd2cn_install_file "$P11_CONF" 644 || return 1
    _p11_conf_changed=$ND2CN_CHANGED

    # ── Boot script: restart sshd with our config ──
    nd2cn_install_file "$P11_BOOT_SCRIPT" 755 << BOOTEOF || return 1
#!/bin/sh
# nd2cn: restart sshd with custom config
_nd2cn_ssh="$P11_SSH_DIR"
if [ -f "\$_nd2cn_ssh/sshd_config" ]; then
    # Stop only the stock listener (PID file), not every process named sshd
    _pid=\$(cat $P11_PIDFILE 2>/dev/null)
    [ -n "\$_pid" ] && kill "\$_pid" 2>/dev/null
    sleep 1
    /usr/sbin/sshd -f "\$_nd2cn_ssh/sshd_config"
fi
BOOTEOF

    # ── Apply now ──
    if ! nd2cn_is_live; then
        :
    elif [ "$_p11_conf_changed" = "0" ] && _p11_ours_running; then
        nd2cn_log "already applied (sshd running with nd2cn config)"
    elif _p11_restart_sshd "$P11_CONF" && _p11_ours_running; then
        nd2cn_log "sshd running with nd2cn config (pid $(_p11_daemon_pid))"
    else
        nd2cn_log "ERROR: sshd failed to start with nd2cn config, restoring stock"
        _p11_restart_sshd ""
        return 1
    fi
    nd2cn_log "SSH access: port 36000, USB-ethernet eth1 (192.168.42.1)"
    return 0
}

plugin_remove() {
    rm -f "$P11_BOOT_SCRIPT" "$P11_BOOT_SCRIPT.nd2cn.tmp" "$P11_CONF" "$P11_CONF.nd2cn.tmp"
    if nd2cn_is_live && _p11_ours_running; then
        _p11_restart_sshd ""
        nd2cn_log "sshd restored to stock config"
    fi
    if [ -d "$P11_SSH_DIR" ]; then
        nd2cn_log "Kept $P11_SSH_DIR (authorized_keys, host keys) — inert without nd2cn sshd_config"
    fi
    return 0
}
