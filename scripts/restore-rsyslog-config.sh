#!/bin/bash
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/00-remote-syslog.conf"
DST="/etc/rsyslog.d/00-remote-syslog.conf"
MASTER="/rootfs/fw/etc/rsyslog.conf"
WORKDIR="/var/spool/rsyslog"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

# rsyslogd -N1 returns a non-zero exit code on UGOS if the configured
# WorkDirectory does not exist. Create it before any validation attempt.
mkdir -p "$WORKDIR"
chown root:root "$WORKDIR"
chmod 0755 "$WORKDIR"

if [ ! -f "$SRC" ]; then
    log "ERROR: source configuration does not exist: $SRC"
    exit 1
fi

# Avoid restarting rsyslog when the active file is already identical.
if [ -f "$DST" ] && cmp -s "$SRC" "$DST"; then
    log "Configuration already correct - nothing to do."
    exit 0
fi

log "Restoring rsyslog configuration..."

OLD=""
if [ -f "$DST" ]; then
    OLD="$(mktemp)"
    cp -a "$DST" "$OLD"
fi

install -o root -g root -m 0644 "$SRC" "$DST"

VALIDATION_LOG="$(mktemp)"

if rsyslogd -N1 -f "$MASTER" >"$VALIDATION_LOG" 2>&1; then
    log "Configuration validation OK."

    if systemctl restart rsyslog && systemctl is-active --quiet rsyslog; then
        log "rsyslog restarted successfully."
        [ -n "$OLD" ] && rm -f "$OLD"
        rm -f "$VALIDATION_LOG"
        exit 0
    fi

    log "ERROR: rsyslog did not start correctly."
else
    log "ERROR: configuration validation failed."
    cat "$VALIDATION_LOG"
fi

rm -f "$VALIDATION_LOG"

# Restore the previous working state if validation or restart failed.
if [ -n "$OLD" ] && [ -f "$OLD" ]; then
    log "Rolling back previous configuration."
    cp -a "$OLD" "$DST"
    rm -f "$OLD"
else
    log "Removing restored configuration."
    rm -f "$DST"
fi

systemctl restart rsyslog || true
exit 1
