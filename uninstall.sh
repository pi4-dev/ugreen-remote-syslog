#!/bin/bash
set -euo pipefail

PERSIST_DIR="/volume1/system-config/ugreen-remote-syslog"
PURGE=0

ACTIVE_CONFIG="/etc/rsyslog.d/00-remote-syslog.conf"
WRAPPER="/usr/local/sbin/ugreen-rsyslog-restore-wrapper.sh"
SERVICE="/etc/systemd/system/ugreen-rsyslog-restore.service"
MASTER_CONFIG="/rootfs/fw/etc/rsyslog.conf"

usage() {
    cat <<'EOF'
Usage:
  sudo bash uninstall.sh [options]

Options:
  --persist-dir PATH   Persistent recovery directory used during installation
  --purge              Also delete the persistent recovery directory
  -h, --help           Show this help

By default the persistent recovery copy is preserved.
EOF
}

log() {
    echo "[ugreen-remote-syslog] $*"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --persist-dir)
            PERSIST_DIR="$2"
            shift 2
            ;;
        --purge)
            PURGE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

[ "${EUID}" -eq 0 ] || { echo "Run this script as root." >&2; exit 1; }

systemctl disable --now ugreen-rsyslog-restore.service 2>/dev/null || true
rm -f "$SERVICE"
rm -f "$WRAPPER"
rm -f "$ACTIVE_CONFIG"

systemctl daemon-reload

mkdir -p /var/spool/rsyslog

if [ -f "$MASTER_CONFIG" ]; then
    rsyslogd -N1 -f "$MASTER_CONFIG"
fi

systemctl restart rsyslog

if [ "$PURGE" -eq 1 ]; then
    case "$PERSIST_DIR" in
        /volume[0-9]/*)
            log "removing persistent recovery directory: $PERSIST_DIR"
            rm -rf -- "$PERSIST_DIR"
            ;;
        *)
            echo "Refusing to purge an unexpected path: $PERSIST_DIR" >&2
            exit 1
            ;;
    esac
else
    log "persistent recovery data preserved at: $PERSIST_DIR"
fi

log "uninstallation complete"
