#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_HOST=""
REMOTE_PORT="5514"
PROTOCOL="udp"
PERSIST_DIR="/volume1/system-config/ugreen-remote-syslog"

ACTIVE_CONFIG="/etc/rsyslog.d/00-remote-syslog.conf"
MASTER_CONFIG="/rootfs/fw/etc/rsyslog.conf"
WORKDIR="/var/spool/rsyslog"
WRAPPER="/usr/local/sbin/ugreen-rsyslog-restore-wrapper.sh"
SERVICE_DST="/etc/systemd/system/ugreen-rsyslog-restore.service"

usage() {
    cat <<'EOF'
Usage:
  sudo ./install.sh --remote-host HOST [options]

Options:
  --remote-host HOST     Remote Syslog collector hostname or IP address (required)
  --remote-port PORT     Remote Syslog port (default: 5514)
  --protocol udp|tcp     Transport protocol (default: udp)
  --persist-dir PATH     Persistent recovery directory
                         (default: /volume1/system-config/ugreen-remote-syslog)
  -h, --help             Show this help
EOF
}

log() {
    echo "[ugreen-remote-syslog] $*"
}

fail() {
    echo "[ugreen-remote-syslog] ERROR: $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --remote-host)
            [ "$#" -ge 2 ] || fail "--remote-host requires a value"
            REMOTE_HOST="$2"
            shift 2
            ;;
        --remote-port)
            [ "$#" -ge 2 ] || fail "--remote-port requires a value"
            REMOTE_PORT="$2"
            shift 2
            ;;
        --protocol)
            [ "$#" -ge 2 ] || fail "--protocol requires a value"
            PROTOCOL="$2"
            shift 2
            ;;
        --persist-dir)
            [ "$#" -ge 2 ] || fail "--persist-dir requires a value"
            PERSIST_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[ "${EUID}" -eq 0 ] || fail "run this installer as root"
[ -n "$REMOTE_HOST" ] || fail "--remote-host is required"

# Keep generated configuration and wrapper content safe and predictable.
[[ "$REMOTE_HOST" =~ ^[A-Za-z0-9._:-]+$ ]] || fail "remote host contains unsupported characters"
[[ "$REMOTE_PORT" =~ ^[0-9]+$ ]] || fail "remote port must be numeric"
[ "$REMOTE_PORT" -ge 1 ] && [ "$REMOTE_PORT" -le 65535 ] || fail "remote port must be between 1 and 65535"
[[ "$PROTOCOL" == "udp" || "$PROTOCOL" == "tcp" ]] || fail "protocol must be udp or tcp"
[[ "$PERSIST_DIR" =~ ^/volume[0-9]+/[A-Za-z0-9._/-]+$ ]] || fail "persist directory must be under /volumeN and contain only safe path characters"

[ -f "$MASTER_CONFIG" ] || fail "UGOS rsyslog master configuration not found: $MASTER_CONFIG"
[ -f "$SCRIPT_DIR/rsyslog/00-remote-syslog.conf.template" ] || fail "rsyslog template not found"
[ -f "$SCRIPT_DIR/scripts/restore-rsyslog-config.sh" ] || fail "restore script not found"
[ -f "$SCRIPT_DIR/systemd/ugreen-rsyslog-restore.service" ] || fail "systemd unit not found"

VOLUME_NAME="$(printf '%s\n' "$PERSIST_DIR" | cut -d/ -f2)"
VOLUME_ROOT="/$VOLUME_NAME"

mountpoint -q "$VOLUME_ROOT" || fail "$VOLUME_ROOT is not currently mounted; refusing to place recovery data on the OS overlay"

mkdir -p "$WORKDIR"
chown root:root "$WORKDIR"
chmod 0755 "$WORKDIR"

mkdir -p "$PERSIST_DIR"
chmod 0755 "$PERSIST_DIR"

TMP_CONFIG="$(mktemp)"
OLD_CONFIG=""
cleanup() {
    rm -f "$TMP_CONFIG"
    [ -z "$OLD_CONFIG" ] || rm -f "$OLD_CONFIG"
}
trap cleanup EXIT

TEMPLATE_CONTENT="$(cat "$SCRIPT_DIR/rsyslog/00-remote-syslog.conf.template")"
TEMPLATE_CONTENT="${TEMPLATE_CONTENT//@@REMOTE_HOST@@/$REMOTE_HOST}"
TEMPLATE_CONTENT="${TEMPLATE_CONTENT//@@REMOTE_PORT@@/$REMOTE_PORT}"
TEMPLATE_CONTENT="${TEMPLATE_CONTENT//@@PROTOCOL@@/$PROTOCOL}"
printf '%s\n' "$TEMPLATE_CONTENT" >"$TMP_CONFIG"

if [ -f "$ACTIVE_CONFIG" ]; then
    OLD_CONFIG="$(mktemp)"
    cp -a "$ACTIVE_CONFIG" "$OLD_CONFIG"
fi

log "installing temporary active rsyslog rule for validation"
install -o root -g root -m 0644 "$TMP_CONFIG" "$ACTIVE_CONFIG"

if ! rsyslogd -N1 -f "$MASTER_CONFIG"; then
    log "validation failed; restoring previous configuration"
    if [ -n "$OLD_CONFIG" ] && [ -f "$OLD_CONFIG" ]; then
        cp -a "$OLD_CONFIG" "$ACTIVE_CONFIG"
    else
        rm -f "$ACTIVE_CONFIG"
    fi
    fail "rsyslog configuration validation failed"
fi

log "rsyslog configuration validation succeeded"

# The persistent directory is the canonical recovery source.
install -o root -g root -m 0644 "$TMP_CONFIG" "$PERSIST_DIR/00-remote-syslog.conf"
install -o root -g root -m 0750 "$SCRIPT_DIR/scripts/restore-rsyslog-config.sh" "$PERSIST_DIR/restore-rsyslog-config.sh"

# UGOS can expose data-volume mount units dynamically. The wrapper therefore
# waits for the actual mountpoint instead of depending on a static volumeX.mount
# unit that may not exist when systemd builds the boot transaction.
cat >"$WRAPPER" <<EOF
#!/bin/bash
set -u

PERSIST_DIR="$PERSIST_DIR"
VOLUME_ROOT="$VOLUME_ROOT"

for _ in \$(seq 1 60); do
    if mountpoint -q "\$VOLUME_ROOT" && [ -x "\$PERSIST_DIR/restore-rsyslog-config.sh" ]; then
        exec "\$PERSIST_DIR/restore-rsyslog-config.sh"
    fi
    sleep 5
done

echo "\$(date '+%Y-%m-%d %H:%M:%S') ERROR: persistent volume or restore script unavailable"
exit 1
EOF
chmod 0750 "$WRAPPER"

install -o root -g root -m 0644 "$SCRIPT_DIR/systemd/ugreen-rsyslog-restore.service" "$SERVICE_DST"

systemctl daemon-reload
systemd-analyze verify "$SERVICE_DST"
systemctl enable ugreen-rsyslog-restore.service >/dev/null

log "restarting rsyslog"
systemctl restart rsyslog
systemctl is-active --quiet rsyslog || fail "rsyslog failed to start after installation"

# Run the recovery service once. It should detect that the active and
# persistent copies are already identical and exit successfully.
systemctl start ugreen-rsyslog-restore.service

log "installation complete"
log "remote destination: ${REMOTE_HOST}:${REMOTE_PORT}/${PROTOCOL}"
log "persistent recovery directory: $PERSIST_DIR"
log "active configuration: $ACTIVE_CONFIG"
log "INFO messages are filtered; WARN and higher application levels are forwarded"
