# UGREEN Remote Syslog

Forward internal **UGREEN NAS / UGOS Pro** application logs to a remote Syslog collector without modifying the read-only firmware image.

This project was developed and tested on UGOS Pro based on Debian 12 with `rsyslog` 8.2302.0. UGOS uses `rsyslog` internally and routes many application logs to `/var/ugreen/log/*.slog`. Most vendor rules end with `stop`, so a remote-forwarding rule must be loaded **before** the UGOS rules.

## What this project does

- adds `/etc/rsyslog.d/00-remote-syslog.conf`, which is evaluated before the vendor rules;
- forwards only UGOS/UGREEN application sources, not the complete Linux system log;
- drops application-level `INFO` messages by default;
- forwards `WARN`, `ERROR`, `CRIT`, `ALERT`, `EMERG`, `FATAL`, `PANIC` and common aliases;
- preserves the normal local UGOS `.slog` files;
- uses RFC 5424 output (`RSYSLOG_SyslogProtocol23Format`);
- supports UDP or TCP transport;
- keeps a persistent copy of the custom configuration on a NAS data volume;
- restores the custom rule after boot if the overlay copy disappears;
- includes an OpenObserve VRL parser that extracts process, PID, application log level and clean message fields.

## Why filtering uses the message body

UGOS applications do not always map their own severity to the Syslog severity correctly. For example, an application can emit a message like:

```text
ERROR 2026-01-01 12:34:56.123456 service/module.go:123 operation failed
```

while the Syslog PRI still reports `info`.

Because of that, filtering on `$syslogseverity` can silently discard real UGOS errors. This project instead evaluates the application-level prefix at the start of `$msg`.

## Architecture

```text
UGOS application
      |
      v
   rsyslog
      |
      +--> 00-remote-syslog.conf --> remote Syslog collector
      |
      +--> vendor /etc/rsyslog.d/*.conf --> /var/ugreen/log/*.slog --> stop
```

A typical OpenObserve deployment can use:

```text
UGREEN NAS
   |
   | Syslog UDP/TCP
   v
syslog-ng / Vector / Fluent Bit
   |
   | HTTP / JSON
   v
OpenObserve
```

## Requirements

- UGREEN NAS running UGOS Pro;
- SSH access with root privileges (`sudo -i`);
- working UGOS `rsyslog` service;
- a remote Syslog receiver;
- a persistent NAS data volume such as `/volume1` or `/volume2`.

Before installing, verify that UGOS uses the expected master configuration:

```bash
systemctl status rsyslog --no-pager
```

A tested system runs `rsyslogd` with:

```text
-f /rootfs/fw/etc/rsyslog.conf
```

## Installation

Clone the repository on the NAS and run:

```bash
sudo ./install.sh \
  --remote-host syslog.example.net \
  --remote-port 5514 \
  --protocol udp \
  --persist-dir /volume1/system-config/ugreen-remote-syslog
```

Arguments:

| Option | Required | Default | Description |
|---|---:|---|---|
| `--remote-host` | yes | - | Syslog collector hostname or IP address |
| `--remote-port` | no | `5514` | Destination Syslog port |
| `--protocol` | no | `udp` | `udp` or `tcp` |
| `--persist-dir` | no | `/volume1/system-config/ugreen-remote-syslog` | Persistent backup/recovery directory |

The installer:

1. validates the requested data volume;
2. renders the rsyslog rule;
3. creates `/var/spool/rsyslog` if needed;
4. validates the complete UGOS rsyslog configuration;
5. installs and activates the forwarding rule;
6. stores a persistent copy on the selected NAS volume;
7. installs the recovery script and boot wrapper;
8. creates and enables `ugreen-rsyslog-restore.service`;
9. restarts `rsyslog` only after successful validation.

## Filtering policy

The default rule forwards recognized UGOS application sources only when the application message starts with one of:

```text
WARN
WARNING
ERROR
ERR
CRIT
CRITICAL
ALERT
EMERG
EMERGENCY
FATAL
PANIC
```

`INFO` is intentionally not forwarded.

The source selector is based on UGOS program names observed in `/etc/rsyslog.d/*.conf`, including service names such as `*_serv`, `ug*`, `snapshot_tool_*`, `jobmgr_*_model`, `smbd_audit`, and related helpers.

Local vendor logging is unchanged because this rule does **not** call `stop`.

## Validation and test

Validate the full UGOS rsyslog configuration:

```bash
mkdir -p /var/spool/rsyslog
rsyslogd -N1 -f /rootfs/fw/etc/rsyslog.conf
echo "EXIT=$?"
```

Expected result:

```text
EXIT=0
```

Generate controlled test messages:

```bash
logger -p local0.info -t syncbackup_serv \
  "INFO 2026-01-01 12:00:00 test.go:100 UGREEN_INFO_TEST"

logger -p local0.info -t syncbackup_serv \
  "WARN 2026-01-01 12:00:01 test.go:101 UGREEN_WARN_TEST"

logger -p local0.info -t syncbackup_serv \
  "ERROR 2026-01-01 12:00:02 test.go:102 UGREEN_ERROR_TEST"
```

Expected remote result:

```text
UGREEN_INFO_TEST   -> not forwarded
UGREEN_WARN_TEST   -> forwarded
UGREEN_ERROR_TEST  -> forwarded
```

All three intentionally use Syslog priority `local0.info`. This verifies that filtering is based on the UGOS application level, not on the outer Syslog severity.

## Persistent recovery

UGOS uses a read-only firmware stack with a writable overlay. Custom files under `/etc` can therefore survive normal reboots, but a firmware update may replace or reset the overlay.

The installer keeps the canonical forwarding rule in the selected persistent data-volume directory and installs a small boot-time recovery service.

The wrapper waits for the data volume to become available before executing the restore script. This avoids depending on a static `volumeX.mount` unit because UGOS may create mount units dynamically.

Check recovery status with:

```bash
systemctl status ugreen-rsyslog-restore.service --no-pager
journalctl -u ugreen-rsyslog-restore.service -b --no-pager
```

The service is `Type=oneshot`, so `inactive (dead)` after a successful run is normal.

## OpenObserve parsing

The file [`openobserve/parse_ugreen_syslog.vrl`](openobserve/parse_ugreen_syslog.vrl) contains a VRL ingest function for OpenObserve.

It extracts:

- `syslog_host`
- `process`
- `pid`
- `log_message`
- `app_level`
- `app_message`

This is useful because the collector may expose only the whole RFC 5424 payload in the `message` field.

Example input:

```text
2026-01-01T12:34:56.123456+01:00 nas-host cloud_serv 1234 - - ERROR 2026-01-01 12:34:56.123000 cloud_serv/service/module.go:123 operation failed
```

Example extracted values:

```text
process    = cloud_serv
pid        = 1234
app_level  = ERROR
app_message = 2026-01-01 12:34:56.123000 cloud_serv/service/module.go:123 operation failed
```

Keep the original `message` field until the pipeline has been verified against your own collector format.

## Troubleshooting

### `rsyslogd -N1` returns exit code 1 with WorkDirectory error

If validation reports:

```text
$WorkDirectory: /var/spool/rsyslog can not be accessed
```

create it:

```bash
mkdir -p /var/spool/rsyslog
chown root:root /var/spool/rsyslog
chmod 0755 /var/spool/rsyslog
```

Then validate again.

### Vendor logs stop before the forwarding rule

UGOS rules frequently end with `stop`. The custom file is intentionally named:

```text
/etc/rsyslog.d/00-remote-syslog.conf
```

so that it is loaded before vendor files such as `syncbackup_serv.conf`, `storage_serv.conf`, and similar rules.

### Too many logs

The default configuration already removes `INFO`. If a specific service is still noisy, add an additional `$programname` exclusion or a more specific `$msg` rule before the forwarding action.

### No logs arrive remotely

Test basic network transport independently of rsyslog filtering:

```bash
logger -n syslog.example.net -P 5514 -d -t UGREEN_TEST \
  "UGREEN_REMOTE_SYSLOG_TEST"
```

For TCP, omit `-d` and use the options supported by your local `logger` implementation.

## Files

```text
.
├── README.md
├── install.sh
├── uninstall.sh
├── rsyslog/
│   └── 00-remote-syslog.conf.template
├── scripts/
│   └── restore-rsyslog-config.sh
├── systemd/
│   └── ugreen-rsyslog-restore.service
└── openobserve/
    └── parse_ugreen_syslog.vrl
```

## Upgrade notes

After an UGOS upgrade, verify:

```bash
systemctl is-active rsyslog
systemctl is-enabled ugreen-rsyslog-restore.service
ls -l /etc/rsyslog.d/00-remote-syslog.conf
rsyslogd -N1 -f /rootfs/fw/etc/rsyslog.conf
```

Major firmware upgrades may replace files stored in the writable OS overlay. The persistent copy on the NAS data volume is intended to make manual recovery straightforward even if the boot integration itself has to be reinstalled.

## Safety

The project deliberately avoids editing `/rootfs/fw`, vendor `.conf` files, or UGOS application files. All changes are additive and can be removed independently.
