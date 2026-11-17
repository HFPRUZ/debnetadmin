# DebNetAdmin Usage Guide

This guide covers every command with practical examples. All commands that
change the system require root (`sudo`). Add `--dry-run` (`-n`) to any command
to preview what would be executed, and `--yes` (`-y`) to skip confirmation
prompts in automation.

## Table of contents

1. [Interactive mode](#interactive-mode)
2. [Information commands](#information-commands)
3. [System maintenance](#system-maintenance)
4. [Users and SSH](#users-and-ssh)
5. [Firewall and intrusion prevention](#firewall-and-intrusion-prevention)
6. [Network services](#network-services)
7. [Reports](#reports)
8. [System configuration](#system-configuration)
9. [User accounts](#user-accounts)
10. [Storage and backups](#storage-and-backups)
11. [Packages](#packages)
12. [Logs, processes and scheduled tasks](#logs-processes-and-scheduled-tasks)
13. [TLS certificates](#tls-certificates)
14. [Recipes](#recipes)
15. [Logging](#logging)
16. [Troubleshooting](#troubleshooting)

## Interactive mode

```bash
sudo debnetadmin          # same as: sudo debnetadmin menu
```

Navigation: type the number of an option and press Enter. `0` (or `q`) goes
back one level or quits from the main menu. `Ctrl+C` exits immediately.

### Menu map

| Menu | Entries |
|---|---|
| **Reports** | Generate a report (guided or with defaults); list reports; schedule, show or remove recurring reports |
| **Network services** | Overview of all services; install a service (wizard); manage a service (status, start, stop, restart, reload, enable/disable at boot, logs, validate config); validate all configurations |
| **Network tools** | Full diagnostics; listening sockets; ping; DNS lookup (uses `dig` when installed); TCP port check; traceroute/tracepath |
| **Firewall** | Status and rules; guided setup; allow a port (port, protocol, source); open standard ports of a service; delete a rule by number |
| **Security and hardening** | Quick audit; SSH hardening wizard; Fail2ban install and status; unattended upgrades; kernel hardening profile; failed SSH logins |
| **User accounts** | List; create (wizard); lock; unlock; force password change; delete (with optional home archive) |
| **System configuration** | System information; health check; host name; time zone; time synchronisation; swap file; kernel hardening; reboot |
| **Storage and backups** | Disk usage; large files; SMART health; `/etc` backup; backup of other directories; database dumps; list and verify backups |
| **Packages and updates** | Update; list upgradable; search; install; remove; hold/release; clean up; unattended upgrades; reboot check; APT history |
| **Logs, processes and scheduled tasks** | Journal errors; failed SSH logins; service logs; top processes; cron and timers; trim the journal; DebNetAdmin log |
| **TLS certificates** | Check local or remote certificates; issue (wizard); renew; test renewal |
| **Toggle dry-run** | Switches the whole session between real and rehearsal mode |

### Wizards

**Install a service.** Pick a service from a list that shows its current state,
review packages/units/ports, confirm, install, then optionally open the firewall
ports (for anyone or only for a network you specify) and validate the
configuration.

**Allow a port.** Asks for the port or range, the protocol (TCP, UDP or both)
and the allowed source (anyone or a CIDR), shows a summary and applies it.
If UFW is missing it offers to install it first.

**Create a user.** Validates the username, asks about sudo rights and an SSH
public key (format-checked), shows a summary and creates the account.

**Harden SSH.** Lists the non-root users that already have an authorized key.
If there are none it warns about the lockout risk and requires you to type
`I UNDERSTAND` to continue. It can also change the SSH port and open it in the
firewall.

### Notes

- Prompts show the default value in brackets, for example `[Y/n]` or `[2222]`; press Enter to accept it.
- A failed action never closes the menu: you see the error and return to it.
- Interactive mode requires a terminal; scripts and cron jobs must use the CLI commands (every menu action has an equivalent command, see `debnetadmin help`).
- Started without root, the menu offers to restart itself with `sudo`. In dry-run mode it skips that question.

## Information commands

These do not require root.

```bash
debnetadmin sysinfo          # hostname, OS, kernel, uptime, CPU, memory, addresses
debnetadmin health           # disk, memory, failed units, pending updates
debnetadmin netdiag          # interfaces, routes, DNS, connectivity, sockets
debnetadmin netdiag example.org   # test DNS resolution of a specific host
debnetadmin listening        # same as `ss -tulpn`
debnetadmin services         # supported services with packages and units
```

`health` warns when any filesystem is 85% full or more, lists failed systemd
units, counts upgradable packages and reports if a reboot is required.

## System maintenance

```bash
sudo debnetadmin update        # apt update + upgrade + autoremove + autoclean
sudo debnetadmin autoupdates   # enable unattended security upgrades
sudo debnetadmin backup        # /etc archive in /var/backups/debnetadmin
```

Backups are stored with mode `0700` and `umask 077`. Only the newest
`DEBNETADMIN_BACKUP_KEEP` archives (default 7) are kept.

## Users and SSH

### Create a user

```bash
# Interactive: asks for a password
sudo debnetadmin user-add alice --sudo

# Key-only account (no password set)
sudo debnetadmin user-add bob --sudo --key "ssh-ed25519 AAAA... bob@laptop"
```

Usernames must match `^[a-z_][a-z0-9_-]{0,31}$`.

### Harden SSH

```bash
sudo debnetadmin --dry-run ssh-harden           # preview
sudo debnetadmin ssh-harden                     # apply
sudo debnetadmin ssh-harden --port 2222         # apply and change the port
```

The following settings are written to
`/etc/ssh/sshd_config.d/99-debnetadmin.conf`:

| Setting | Value |
|---|---|
| `PermitRootLogin` | `no` |
| `PasswordAuthentication` | `no` |
| `KbdInteractiveAuthentication` | `no` |
| `PubkeyAuthentication` | `yes` |
| `PermitEmptyPasswords` | `no` |
| `X11Forwarding` | `no` |
| `MaxAuthTries` | `3` |
| `LoginGraceTime` | `30` |
| `ClientAliveInterval` / `ClientAliveCountMax` | `300` / `2` |

The configuration is validated with `sshd -t`. If validation fails, the drop-in
file is removed and nothing is reloaded. To undo hardening later, delete the
drop-in file and run `sudo systemctl reload ssh`.

> **Important:** Debian's default `sshd_config` includes `sshd_config.d/*.conf`
> at the top, so the first value found wins. If you changed these options in the
> main file, make sure they do not conflict.

If you change the port, open it in the firewall before disconnecting:

```bash
sudo debnetadmin fw-allow 2222/tcp
```

## Firewall and intrusion prevention

```bash
sudo debnetadmin fw-setup                       # install UFW, deny incoming, allow SSH, enable
sudo debnetadmin fw-allow 8080/tcp              # allow a port
sudo debnetadmin fw-allow 3306/tcp 10.0.0.0/24  # allow a port only from a subnet
sudo debnetadmin fw-preset nginx                # open 80/tcp and 443/tcp
sudo debnetadmin fw-status
sudo debnetadmin fail2ban                       # install Fail2ban with sshd jail
```

### Service port presets

| Service | Ports |
|---|---|
| nginx, apache | 80/tcp, 443/tcp |
| bind | 53/tcp, 53/udp |
| dhcp, kea | 67/udp |
| samba | 137/udp, 138/udp, 139/tcp, 445/tcp |
| nfs | 111/tcp, 111/udp, 2049/tcp |
| postfix | 25/tcp, 465/tcp, 587/tcp |
| dovecot | 143/tcp, 993/tcp |
| wireguard | 51820/udp |
| openvpn | 1194/udp |
| chrony | 123/udp |
| mariadb | 3306/tcp |
| squid | 3128/tcp |
| openssh | 22/tcp |

Database ports such as 3306 should normally be restricted to trusted subnets
with `fw-allow <port> <cidr>` instead of using the preset.

Fail2ban settings written to `/etc/fail2ban/jail.d/debnetadmin.local`:
`bantime = 1h`, `findtime = 10m`, `maxretry = 5`, `sshd` jail enabled.

## Network services

```bash
sudo debnetadmin install nginx           # install, enable and start
sudo debnetadmin svc status nginx
sudo debnetadmin svc restart bind
sudo debnetadmin check-config nginx      # validate before reloading
sudo debnetadmin check-config all        # validate every installed service
debnetadmin logs postfix 200             # last 200 journal lines
```

### Supported services

| Key | Packages | systemd unit(s) | Config test |
|---|---|---|---|
| `nginx` | nginx | nginx | `nginx -t` |
| `apache` | apache2 | apache2 | `apache2ctl configtest` |
| `bind` | bind9, bind9-utils, dnsutils | bind9 | `named-checkconf` |
| `dhcp` | isc-dhcp-server | isc-dhcp-server | `dhcpd -t` |
| `kea` | kea-dhcp4-server | kea-dhcp4-server | `kea-dhcp4 -t` |
| `samba` | samba | smbd, nmbd | `testparm -s` |
| `nfs` | nfs-kernel-server | nfs-server | n/a |
| `postfix` | postfix | postfix | `postfix check` |
| `dovecot` | dovecot-core, dovecot-imapd | dovecot | n/a |
| `wireguard` | wireguard, wireguard-tools | wg-quick@wg0 | n/a |
| `openvpn` | openvpn | openvpn | n/a |
| `chrony` | chrony | chrony | n/a |
| `mariadb` | mariadb-server | mariadb | n/a |
| `squid` | squid | squid | `squid -k parse` |
| `openssh` | openssh-server | ssh | `sshd -t` |

Notes:

- Some services need configuration before they start (BIND zones, DHCP scopes,
  WireGuard `wg0.conf`, Dovecot mail locations). A failed start after
  installation is reported as a warning, not a fatal error.
- `isc-dhcp-server` is end-of-life upstream and may be absent from current
  Debian releases. Prefer `kea`.
- `check-config` skips services whose binaries are not installed.

## Reports

```bash
sudo debnetadmin report                                   # default location
sudo debnetadmin report -o /srv/reports/web01.html --title "Monthly review" --author "Jane Doe"
sudo debnetadmin report --mail ops@example.org            # also send it (needs sendmail)
sudo debnetadmin report-list
sudo debnetadmin report-schedule --weekly --mail ops@example.org
sudo debnetadmin report-schedule --show
sudo debnetadmin report-schedule --remove
```

The report is a **single self-contained HTML file** (inline CSS, no JavaScript,
no external requests). It adapts to light and dark mode, works on phones and
prints cleanly to PDF from any browser (`Ctrl+P`).

Default location: `/var/lib/debnetadmin/reports/` when run as root, the current
directory otherwise (override with `DEBNETADMIN_REPORT_DIR`). Files are created
with mode `0600`, and the newest `DEBNETADMIN_REPORT_KEEP` (default 12) reports
in the default directory are kept.

### What it contains

| Section | Content |
|---|---|
| **Executive summary** | Score (0-100) and grade, counts per severity, findings with recommended commands, list of passed checks |
| **System** | Host, OS, Debian version, kernel, uptime, virtualization, time zone, clock synchronisation, reboot-required flag, Debian release support status |
| **Resources** | CPU model and cores, load, memory and swap with usage bars |
| **Storage** | Filesystems with usage bars, inode usage, block devices, `/etc/fstab`, software RAID, LVM, SMART health |
| **Network** | Interfaces, routes, DNS, hosts, listening sockets with exposure and risky-port detection, active firewall and rules |
| **Services** | State of catalogue services, running services, failed units, timers |
| **Security** | Effective SSH configuration, UID-0 and passwordless accounts, privileged groups, kernel hardening parameters, Fail2ban, unattended upgrades, AppArmor, failed logins and top offenders, recent logins |
| **Updates** | Package counts, pending security updates, upgradable list, held packages, APT sources |
| **Users** | Regular accounts with login shell, password state, last login, groups |
| **Scheduled tasks** | Crontabs, cron directories, timers |
| **Logs and events** | Error volume, out-of-memory kills, journal size, latest errors |
| **Processes** | Top by CPU and memory, zombie processes |
| **Backups and certificates** | Newest backups and their age, Let's Encrypt expiry |

### Scoring

The score starts at 100. Each **critical** finding subtracts 15 points and each
**warning** 5 points. Grades: A (90+), B (80+), C (70+), D (60+), F (below 60);
any critical finding always shows the "Critical issues present" status.
Notices (for example available updates) do not affect the score.

### Running without root

The report also works for a normal user, but checks that need privileges
(firewall rules, password status, SMART, certificates, backups, parts of the
journal) are skipped and the report says so in a "Limited scope" notice.
**Run it with `sudo` for a complete picture.**

### Privacy

A report lists users, open ports, installed services and configuration. Treat it
as confidential: keep the default `0600` permissions, and avoid sending it over
unencrypted channels.

## System configuration

```bash
sudo debnetadmin hostname-set web01            # hostnamectl + /etc/hosts (backed up)
sudo debnetadmin timezone-set Europe/Madrid
sudo debnetadmin time-sync                     # NTP status
sudo debnetadmin time-sync --enable            # install and start Chrony
sudo debnetadmin swap-add 2G                   # /swapfile, persisted in /etc/fstab
sudo debnetadmin sysctl-harden                 # /etc/sysctl.d/99-debnetadmin.conf
```

`sysctl-harden` enables SYN cookies, reverse-path filtering, disables ICMP
redirects and source routing, logs martian packets, and sets conservative kernel
and filesystem protections. Strict reverse-path filtering can break asymmetric
routing on routers and multi-homed hosts; revert by deleting the drop-in file
and running `sysctl --system`.

## User accounts

```bash
debnetadmin user-list                          # users, sudo, lock state, last login
sudo debnetadmin user-lock alice               # disables password AND expires the account
sudo debnetadmin user-unlock alice
sudo debnetadmin user-expire alice             # force a new password at next login
sudo debnetadmin user-del alice --purge-home   # archives /home/alice first
sudo debnetadmin user-del alice --force        # also terminate running processes
```

Safety rules: system accounts (UID below 1000 or above 59999), `root` and the
account running `sudo` cannot be locked or deleted. Deleting asks you to type the
user name unless `--yes` is given. `user-lock` also expires the account, so SSH
key logins stop working too (locking only the password would not stop them).

## Storage and backups

```bash
debnetadmin disk-usage /var                    # largest directories
debnetadmin big-files /var 500M                # files larger than 500 MiB
sudo debnetadmin install-smart && sudo debnetadmin smart
sudo debnetadmin backup                        # /etc
sudo debnetadmin backup-paths /var/www /home   # arbitrary directories
sudo debnetadmin db-backup                     # MariaDB/MySQL and PostgreSQL dumps
sudo debnetadmin backup-list
sudo debnetadmin backup-verify                 # newest backup, or a given file
```

Backups are stored in `DEBNETADMIN_BACKUP_DIR` (default `/var/backups/debnetadmin`,
mode `0700`). Each backup type keeps the newest `DEBNETADMIN_BACKUP_KEEP` files.
Database dumps use the local root socket (no password is stored) and are written
through a temporary file, so a failed dump never leaves a truncated archive.
Copy backups off the server: a backup on the same disk is not a disaster-recovery plan.

## Packages

```bash
debnetadmin pkg search nginx
debnetadmin pkg upgradable
sudo debnetadmin pkg install htop curl
sudo debnetadmin pkg remove htop
sudo debnetadmin pkg hold linux-image-amd64    # keep a package at its current version
sudo debnetadmin pkg unhold linux-image-amd64
debnetadmin pkg held
sudo debnetadmin pkg clean                     # autoremove, autoclean, residual configs, cache
debnetadmin pkg reboot-check
debnetadmin pkg history
```

Package names are validated before anything is passed to APT.

## Logs, processes and scheduled tasks

```bash
sudo debnetadmin logs-errors 24                # error-level journal entries, last 24 h
sudo debnetadmin auth-failures 24              # failed SSH logins, top IPs and user names
debnetadmin procs cpu                          # or: procs mem
sudo debnetadmin cron-list                     # crontabs, cron dirs and systemd timers
sudo debnetadmin journal-vacuum 200M           # cap the journal size
sudo debnetadmin audit                         # quick security audit
```

## TLS certificates

```bash
sudo debnetadmin cert-check                    # local Let's Encrypt certificates
debnetadmin cert-check www.example.org         # certificate presented by a remote host
debnetadmin cert-check mail.example.org:993
sudo debnetadmin certbot-issue www.example.org --email admin@example.org --nginx
sudo debnetadmin certbot-issue example.org --email admin@example.org --webroot /var/www/html
sudo debnetadmin certbot-issue test.example.org --email admin@example.org --standalone --staging
sudo debnetadmin cert-renew --test             # dry-run renewal
sudo debnetadmin cert-renew
```

The domain must resolve to the server and port 80 must be reachable
(`debnetadmin fw-allow 80/tcp`). Use `--staging` while testing to avoid
Let's Encrypt rate limits. Renewal is automatic through the certbot systemd timer;
the report warns when a certificate expires in under 30 days (critical under 14).

## Recipes

### Baseline for a new server

```bash
sudo debnetadmin update
sudo debnetadmin hostname-set web01
sudo debnetadmin timezone-set Europe/Madrid
sudo debnetadmin time-sync --enable
sudo debnetadmin autoupdates
sudo debnetadmin user-add admin --sudo --key "ssh-ed25519 AAAA... admin@laptop"
# Test the key login from another terminal, then:
sudo debnetadmin ssh-harden
sudo debnetadmin fw-setup
sudo debnetadmin fail2ban
sudo debnetadmin sysctl-harden
sudo debnetadmin backup
sudo debnetadmin report-schedule --weekly --mail ops@example.org
sudo debnetadmin report        # first report: aim for a green score
```

### Web server

```bash
sudo debnetadmin install nginx
sudo debnetadmin fw-preset nginx
sudo debnetadmin check-config nginx
```

### Internal DNS server restricted to your LAN

```bash
sudo debnetadmin install bind
sudo debnetadmin fw-allow 53/tcp 192.168.1.0/24
sudo debnetadmin fw-allow 53/udp 192.168.1.0/24
sudo debnetadmin check-config bind
```

### File server (Samba)

```bash
sudo debnetadmin install samba
sudo debnetadmin fw-preset samba
sudo debnetadmin check-config samba
```

### Scheduled health report

```bash
sudo debnetadmin report-schedule --weekly --mail ops@example.org
```

This writes `/etc/cron.d/debnetadmin-report`. To run it from your own cron or
systemd timer instead, call `debnetadmin report --quiet` as root.

### HTTPS website

```bash
sudo debnetadmin install nginx
sudo debnetadmin fw-preset nginx
sudo debnetadmin certbot-issue www.example.org --email admin@example.org --nginx
sudo debnetadmin cert-renew --test
```

### Nightly backups of data and databases

```cron
15 2 * * * root /usr/local/bin/debnetadmin --yes backup-paths /var/www /home
30 2 * * * root /usr/local/bin/debnetadmin --yes db-backup
```

### Weekly `/etc` backup

```cron
0 3 * * 0 /usr/local/bin/debnetadmin --yes backup
```

## Logging

Every action is appended to `/var/log/debnetadmin.log` (override with
`DEBNETADMIN_LOG`) with timestamp and level (`INFO`, `OK`, `WARN`, `ERROR`).
The log file is created with mode `0640` when run as root.

## Troubleshooting

| Problem | Fix |
|---|---|
| `Unsupported OS` | The script targets Debian. Derivatives are accepted with a warning. |
| `This command must be run as root` | Run with `sudo`. |
| A service fails to start after install | It needs configuration. Run `debnetadmin logs <service>` and `debnetadmin check-config <service>`. |
| Locked out after SSH hardening | Use the provider console, delete `/etc/ssh/sshd_config.d/99-debnetadmin.conf` and run `systemctl reload ssh`. |
| `Unknown service` | Run `debnetadmin services` for valid names. |
| Associative array errors | Your Bash is older than 4.0. Check with `bash --version`. |
