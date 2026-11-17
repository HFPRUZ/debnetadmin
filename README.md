# DebNetAdmin

> A single Bash toolkit to install, secure, monitor, document and troubleshoot Debian servers and their network services.

![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)
![Shell: Bash](https://img.shields.io/badge/shell-bash-blue.svg)
![Platform: Debian](https://img.shields.io/badge/platform-Debian-A81D33.svg)

DebNetAdmin wraps the day-to-day work of a Debian sysadmin into one
dependency-free script: a **professional HTML server report**, service
installation and lifecycle management, firewall and SSH hardening, user and
package management, backups, TLS certificates, log analysis and more, from the
command line or through a guided interactive console.

## Features

- **Professional HTML report:** one self-contained file (no JavaScript, no external requests, light/dark mode, print-ready) with a health score, prioritised findings with the command that fixes each one, and 13 sections covering system, resources, storage, network, services, security, updates, users, scheduled tasks, logs, processes, backups and certificates. Can be scheduled and e-mailed.
- **Interactive console:** status dashboard, submenus, step-by-step wizards, validated inputs, typed confirmations for dangerous actions and a built-in dry-run toggle.
- **Service catalogue:** Nginx, Apache, BIND9, ISC DHCP / Kea, Samba, NFS, Postfix, Dovecot, WireGuard, OpenVPN, Chrony (NTP), MariaDB, Squid, OpenSSH: install, start/stop/restart/reload, logs and configuration validation.
- **Security:** UFW with per-service port presets, SSH hardening (validated and reverted on failure), Fail2ban, unattended upgrades, kernel hardening profile, quick audit, failed-login analysis.
- **Users:** list, create (with SSH key), lock, unlock, force password change, delete (with home archive).
- **System:** host name, time zone, NTP (Chrony), swap file, health check, updates, reboot.
- **Storage and backups:** disk usage, large files, SMART, `/etc` and custom directory backups, MariaDB/MySQL and PostgreSQL dumps, retention, listing and integrity verification.
- **Packages:** search, install, remove, hold, clean-up, APT history, reboot check.
- **Certificates:** Let's Encrypt issuing (Nginx, Apache, standalone, webroot), renewal tests, expiry checks of local and remote certificates.
- **Safe by design:** `--dry-run` mode, confirmation prompts, input validation, strict Bash mode (`set -Eeuo pipefail`), configuration backups before changes, audit log.

## Requirements

- Debian 11, 12 or newer (derivatives such as Ubuntu generally work but are not the target)
- Bash 4.0+ (associative arrays are used)
- Root privileges (or `sudo`) for anything that changes the system and for a complete report
- Internet access to the Debian mirrors when installing packages

Optional tools used when present: `smartmontools`, `dig`, `traceroute`, `certbot`, `sendmail` (to e-mail reports).

## Installation

```bash
git clone https://github.com/<your-user>/debnetadmin.git
cd debnetadmin
sudo install -m 0755 debnetadmin.sh /usr/local/bin/debnetadmin
```

Or run it in place:

```bash
chmod +x debnetadmin.sh
sudo ./debnetadmin.sh help
```

## Quick start

```bash
# Interactive console
sudo debnetadmin

# Generate the HTML report and open it in your browser
sudo debnetadmin report -o ~/web01-report.html --author "Jane Doe"

# Weekly report by e-mail
sudo debnetadmin report-schedule --weekly --mail ops@example.org

# Deploy a web server with HTTPS
sudo debnetadmin install nginx
sudo debnetadmin fw-preset nginx
sudo debnetadmin certbot-issue www.example.org --email admin@example.org --nginx

# Preview a risky change before applying it
sudo debnetadmin --dry-run ssh-harden --port 2222
```

## The HTML report

```bash
sudo debnetadmin report [-o FILE] [--title TEXT] [--author TEXT] [--mail ADDRESS] [--quiet]
```

The report starts with an **executive summary**: a score from 0 to 100 and a
grade (A-F), counts of critical issues, warnings and notices, and a table of
findings, each with the DebNetAdmin command that resolves it. Typical findings:

- filesystem or inode usage above 80/90%, degraded RAID, failing SMART disks
- no firewall, risky services (Telnet, NFS, databases, Redis...) listening on all interfaces
- SSH root login or password authentication enabled, UID-0 or passwordless accounts
- Fail2ban or automatic updates missing, pending security updates, reboot required
- failed systemd units, out-of-memory kills, unusually high error volume
- stale or missing backups, Let's Encrypt certificates close to expiry
- Debian releases past the end of security support (per Debian's published schedule)

Run it as root for the complete picture; without root the report says which
checks were skipped. It contains sensitive details about the server, so it is
created with mode `0600`. Full details: [docs/USAGE.md](docs/USAGE.md#reports).

## Interactive mode

Run the script without arguments from a terminal (it offers to restart with `sudo`
if you are not root):

```
╔══════════════════════════════════════════════╗
║  DebNetAdmin v1.2.0    Debian server toolkit ║
╚══════════════════════════════════════════════╝
  Host     : web01
  Address  : eth0=192.168.1.10
  Load     : 0.12 0.08 0.05    Disk /: 29%
  Failed units: 0    Firewall: active    SSH: active

Main menu
   1) Reports (professional HTML report)
   2) Network services (install, manage, validate)
   3) Network tools (ping, DNS, ports, routes)
   4) Firewall
   5) Security and hardening
   6) User accounts
   7) System configuration
   8) Storage and backups
   9) Packages and updates
  10) Logs, processes and scheduled tasks
  11) TLS certificates
  12) Toggle dry-run mode (now: OFF)
   0) Quit
```

Wizards ask one question at a time, validate each answer, show a summary and ask
for confirmation. Dangerous actions need typed confirmation (`I UNDERSTAND`,
`REBOOT`, the user name). A failed action returns you to the menu. Interactive
mode needs a real terminal; scripts and cron jobs use the commands below.

## Commands

Run `debnetadmin help` for the complete list. Global options: `-n/--dry-run`, `-y/--yes`, `-h/--help`, `-V/--version`.

| Area | Commands |
|---|---|
| **Reports** | `report`, `report-list`, `report-schedule` |
| **Information** | `sysinfo`, `health`, `netdiag`, `listening`, `services`, `audit` |
| **Services** | `install`, `svc`, `logs`, `check-config` |
| **Firewall and security** | `fw-setup`, `fw-status`, `fw-allow`, `fw-preset`, `fail2ban`, `ssh-harden`, `sysctl-harden`, `autoupdates` |
| **Users** | `user-add`, `user-list`, `user-lock`, `user-unlock`, `user-expire`, `user-del` |
| **System** | `hostname-set`, `timezone-set`, `time-sync`, `swap-add`, `update` |
| **Storage and backups** | `disk-usage`, `big-files`, `smart`, `install-smart`, `backup`, `backup-paths`, `db-backup`, `backup-list`, `backup-verify` |
| **Packages** | `pkg search\|info\|install\|remove\|purge\|hold\|unhold\|held\|upgradable\|history\|clean\|reboot-check` |
| **Logs and tasks** | `logs-errors`, `auth-failures`, `procs`, `cron-list`, `journal-vacuum` |
| **Certificates** | `cert-check`, `certbot-issue`, `cert-renew` |
| **Console** | `menu` (default without arguments) |

See [docs/USAGE.md](docs/USAGE.md) for every command with examples and recipes.

## Configuration

No configuration file is needed. Behaviour can be tuned with environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `DEBNETADMIN_LOG` | `/var/log/debnetadmin.log` | Audit log location |
| `DEBNETADMIN_BACKUP_DIR` | `/var/backups/debnetadmin` | Where backups are stored |
| `DEBNETADMIN_BACKUP_KEEP` | `7` | Backups to retain per backup type |
| `DEBNETADMIN_REPORT_DIR` | `/var/lib/debnetadmin/reports` (root) or current directory | Where reports are written |
| `DEBNETADMIN_REPORT_KEEP` | `12` | Reports to retain in the default directory |

## Safety notes

- `ssh-harden` disables password authentication. **Confirm that a non-root user with a working SSH key exists first**, and keep your current session open while testing a new login.
- `fw-setup` allows your detected SSH port before enabling UFW to avoid locking you out.
- `sysctl-harden` enables strict reverse-path filtering, which can break asymmetric routing on routers and multi-homed hosts.
- `user-lock` also expires the account so SSH keys stop working; root, system accounts and your current account are protected from lock and deletion.
- Backups on the same disk are not a disaster-recovery plan: copy them off the server.
- Use `--dry-run` to preview any change, and test on a disposable VM before production.
- You are responsible for the changes the script makes on your systems.

## Project layout

```
debnetadmin/
├── debnetadmin.sh   # the toolkit
├── README.md
├── LICENSE          # MIT
├── CHANGELOG.md
└── docs/
    ├── USAGE.md     # command reference and recipes
    └── CONTRIBUTING.md
```

## Contributing

Contributions are welcome. Please read [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) first.

## License

Released under the [MIT License](LICENSE).
