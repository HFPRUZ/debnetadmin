#!/usr/bin/env bash
#
# DebNetAdmin - Debian network server administration toolkit
#
# Copyright (c) 2026 Fabricio Plasencia
# Licensed under the MIT License. See the LICENSE file for details.
#
# Manage Debian servers and their common network services (web, DNS, DHCP,
# file sharing, mail, VPN, NTP, proxy, databases) from a single script.
#
# Usage: debnetadmin.sh [GLOBAL OPTIONS] <command> [ARGS]
#        debnetadmin.sh help

set -Eeuo pipefail

readonly DNA_VERSION="1.2.0"
readonly PROG="${0##*/}"
readonly LOG_FILE="${DEBNETADMIN_LOG:-/var/log/debnetadmin.log}"
readonly BACKUP_DIR="${DEBNETADMIN_BACKUP_DIR:-/var/backups/debnetadmin}"
readonly BACKUP_KEEP="${DEBNETADMIN_BACKUP_KEEP:-7}"
readonly SSH_DROPIN="/etc/ssh/sshd_config.d/99-debnetadmin.conf"

DRY_RUN=0
ASSUME_YES=0

# ---------------------------------------------------------------------------
# Service catalogue
#   key -> Debian package(s), systemd unit(s), firewall ports
# ---------------------------------------------------------------------------
declare -A SERVICE_PKGS=(
  [nginx]="nginx"
  [apache]="apache2"
  [bind]="bind9 bind9-utils dnsutils"
  [dhcp]="isc-dhcp-server"
  [kea]="kea-dhcp4-server"
  [samba]="samba"
  [nfs]="nfs-kernel-server"
  [postfix]="postfix"
  [dovecot]="dovecot-core dovecot-imapd"
  [wireguard]="wireguard wireguard-tools"
  [openvpn]="openvpn"
  [chrony]="chrony"
  [mariadb]="mariadb-server"
  [squid]="squid"
  [openssh]="openssh-server"
)

declare -A SERVICE_UNITS=(
  [nginx]="nginx"
  [apache]="apache2"
  [bind]="bind9"
  [dhcp]="isc-dhcp-server"
  [kea]="kea-dhcp4-server"
  [samba]="smbd nmbd"
  [nfs]="nfs-server"
  [postfix]="postfix"
  [dovecot]="dovecot"
  [wireguard]="wg-quick@wg0"
  [openvpn]="openvpn"
  [chrony]="chrony"
  [mariadb]="mariadb"
  [squid]="squid"
  [openssh]="ssh"
)

declare -A SERVICE_PORTS=(
  [nginx]="80/tcp 443/tcp"
  [apache]="80/tcp 443/tcp"
  [bind]="53/tcp 53/udp"
  [dhcp]="67/udp"
  [kea]="67/udp"
  [samba]="137/udp 138/udp 139/tcp 445/tcp"
  [nfs]="111/tcp 111/udp 2049/tcp"
  [postfix]="25/tcp 465/tcp 587/tcp"
  [dovecot]="143/tcp 993/tcp"
  [wireguard]="51820/udp"
  [openvpn]="1194/udp"
  [chrony]="123/udp"
  [mariadb]="3306/tcp"
  [squid]="3128/tcp"
  [openssh]="22/tcp"
)

declare -A CONFIG_TESTS=(
  [nginx]="nginx -t"
  [apache]="apache2ctl configtest"
  [bind]="named-checkconf"
  [dhcp]="dhcpd -t -cf /etc/dhcp/dhcpd.conf"
  [kea]="kea-dhcp4 -t /etc/kea/kea-dhcp4.conf"
  [samba]="testparm -s"
  [postfix]="postfix check"
  [openssh]="sshd -t"
  [squid]="squid -k parse"
)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

_log() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >>"$LOG_FILE" 2>/dev/null || true
}
info()    { printf '%s[INFO]%s  %s\n' "$C_BLUE" "$C_RESET" "$*"; _log INFO "$*"; }
ok()      { printf '%s[ OK ]%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; _log OK "$*"; }
warn()    { printf '%s[WARN]%s  %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; _log WARN "$*"; }
err()     { printf '%s[ERR ]%s  %s\n' "$C_RED" "$C_RESET" "$*" >&2; _log ERROR "$*"; }
die()     { err "$*"; exit 1; }
section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }

trap 'rc=$?; err "Unexpected failure at line ${LINENO} (exit code ${rc})"' ERR

# ---------------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------------
# Run a command, or only print it when --dry-run is active.
run() {
  if (( DRY_RUN )); then
    printf '%s[DRY ]%s  %s\n' "$C_YELLOW" "$C_RESET" "$*"
  else
    "$@"
  fi
}

# Write stdin to a file (or discard it in dry-run mode).
write_file() {
  local path="$1"
  if (( DRY_RUN )); then
    printf '%s[DRY ]%s  write %s\n' "$C_YELLOW" "$C_RESET" "$path"
    cat >/dev/null
  else
    cat >"$path"
  fi
}

require_root() {
  if (( EUID != 0 )) && (( ! DRY_RUN )); then
    die "This command must be run as root (try: sudo $PROG ...)"
  fi
}

init_log() {
  if (( EUID == 0 )); then
    touch "$LOG_FILE" 2>/dev/null || true
    chmod 640 "$LOG_FILE" 2>/dev/null || true
  fi
}

# Read one field from /etc/os-release in a subshell so that its variables
# (VERSION, NAME, ID...) never leak into or collide with this script.
os_field() {
  ( # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null
    printf '%s' "${!1:-}" )
}

check_os() {
  local id id_like
  [[ -r /etc/os-release ]] || die "Cannot detect the operating system."
  id="$(os_field ID)"
  id_like="$(os_field ID_LIKE)"
  case "$id" in
    debian) ;;
    ubuntu) warn "Ubuntu detected: most features work, but Debian is the target." ;;
    *)
      if [[ "$id_like" != *debian* ]]; then
        die "Unsupported OS '${id:-unknown}'. DebNetAdmin targets Debian."
      fi
      warn "Debian derivative detected (${id:-unknown}); proceeding."
      ;;
  esac
}

confirm() {
  local prompt="${1:-Continue?}" answer
  (( ASSUME_YES )) && return 0
  read -r -p "$prompt [y/N] " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

pkg_install() {
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

backup_file() {
  local file="$1" dest
  [[ -e "$file" ]] || return 0
  dest="$BACKUP_DIR/files/$(date +%F_%H%M%S)"
  run mkdir -p "$dest"
  run cp -a --parents "$file" "$dest"
  info "Backed up $file to $dest"
}

valid_service() {
  [[ -n "${1:-}" && -n "${SERVICE_PKGS[$1]+x}" ]] || \
    die "Unknown service '${1:-}'. Run '$PROG services' to list valid names."
}

valid_username() {
  [[ "${1:-}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username '${1:-}'."
}

# ---------------------------------------------------------------------------
# Commands: information
# ---------------------------------------------------------------------------
cmd_sysinfo() {
  section "System"
  printf 'Hostname : %s\n' "$(hostname -f 2>/dev/null || hostname)"
  if [[ -r /etc/os-release ]]; then
    printf 'OS       : %s\n' "$(os_field PRETTY_NAME)"
  fi
  printf 'Kernel   : %s\n' "$(uname -r)"
  printf 'Uptime   : %s\n' "$(uptime -p 2>/dev/null || uptime)"
  printf 'CPU      : %s cores\n' "$(nproc)"
  printf 'Memory   : %s\n' "$(free -h | awk '/^Mem:/ {print $3 " used / " $2 " total"}')"
  section "Addresses"
  ip -br addr
}

cmd_health() {
  local failed upgradable usage
  section "Load and memory"
  uptime
  free -h

  section "Disk usage"
  df -hT -x tmpfs -x devtmpfs -x squashfs
  while read -r usage mount; do
    usage="${usage%\%}"
    if (( usage >= 85 )); then
      warn "Filesystem $mount is ${usage}% full"
    fi
  done < <(df -P -x tmpfs -x devtmpfs -x squashfs | awk 'NR>1 {print $5, $6}')

  section "Failed systemd units"
  failed="$(systemctl --failed --no-legend 2>/dev/null || true)"
  if [[ -n "$failed" ]]; then
    warn "Failed units detected:"
    printf '%s\n' "$failed"
  else
    ok "No failed units"
  fi

  section "Pending updates"
  upgradable="$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)"
  if (( upgradable > 0 )); then
    warn "$upgradable package(s) can be upgraded"
  else
    ok "System is up to date"
  fi
  if [[ -f /var/run/reboot-required ]]; then
    warn "A reboot is required"
  fi
}

cmd_services() {
  local key
  printf '%-10s %-34s %s\n' "NAME" "PACKAGES" "UNITS"
  for key in $(printf '%s\n' "${!SERVICE_PKGS[@]}" | sort); do
    printf '%-10s %-34s %s\n' "$key" "${SERVICE_PKGS[$key]}" "${SERVICE_UNITS[$key]}"
  done
}

cmd_listening() {
  section "Listening sockets"
  ss -tulpn
}

cmd_netdiag() {
  local gw host="${1:-debian.org}"
  section "Interfaces"
  ip -br addr
  section "Routes"
  ip route
  section "DNS resolvers"
  grep -E '^(nameserver|search)' /etc/resolv.conf 2>/dev/null || warn "No resolvers found"

  section "Connectivity"
  gw="$(ip route | awk '/^default/ {print $3; exit}')"
  if [[ -n "$gw" ]]; then
    if ping -c 2 -W 2 "$gw" >/dev/null 2>&1; then ok "Gateway $gw reachable"
    else warn "Gateway $gw NOT reachable"; fi
  else
    warn "No default gateway configured"
  fi
  if ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1; then ok "Internet (1.1.1.1) reachable"
  else warn "Internet (1.1.1.1) NOT reachable"; fi
  if getent hosts "$host" >/dev/null 2>&1; then ok "DNS resolution works for $host"
  else warn "DNS resolution FAILED for $host"; fi

  cmd_listening
}

# ---------------------------------------------------------------------------
# Commands: system maintenance
# ---------------------------------------------------------------------------
cmd_update() {
  require_root
  info "Updating package lists and upgrading the system"
  run env DEBIAN_FRONTEND=noninteractive apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
  run apt-get -y autoremove
  run apt-get -y autoclean
  if [[ -f /var/run/reboot-required ]]; then
    warn "A reboot is required to finish applying updates"
  fi
  ok "System updated"
}

cmd_autoupdates() {
  require_root
  info "Enabling unattended security upgrades"
  pkg_install unattended-upgrades apt-listchanges
  write_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  ok "Unattended upgrades enabled"
}

cmd_backup() {
  require_root
  local archive old
  archive="$BACKUP_DIR/etc-$(hostname)-$(date +%F_%H%M%S).tar.gz"
  info "Backing up /etc to $archive"
  run mkdir -p "$BACKUP_DIR"
  run chmod 700 "$BACKUP_DIR"
  if (( DRY_RUN )); then
    run tar -czf "$archive" /etc
  else
    ( umask 077; tar -czf "$archive" /etc 2>/dev/null ) || \
      warn "tar reported warnings (some files may be unreadable)"
    # Retention: keep only the newest BACKUP_KEEP archives
    while IFS= read -r old; do
      [[ -n "$old" ]] && rm -f -- "$old"
    done < <(ls -1t "$BACKUP_DIR"/etc-*.tar.gz 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))")
  fi
  ok "Backup complete (keeping the last $BACKUP_KEEP archives)"
}

# ---------------------------------------------------------------------------
# Commands: users and SSH
# ---------------------------------------------------------------------------
cmd_user_add() {
  require_root
  local user="${1:-}" with_sudo=0 pubkey="" home
  shift || true
  valid_username "$user"
  while (( $# )); do
    case "$1" in
      --sudo) with_sudo=1 ;;
      --key)  shift; pubkey="${1:-}"; [[ -n "$pubkey" ]] || die "--key needs a public key" ;;
      *) die "Unknown option for user-add: $1" ;;
    esac
    shift
  done

  if id "$user" >/dev/null 2>&1; then
    warn "User $user already exists"
  else
    if [[ -n "$pubkey" ]]; then
      run adduser --disabled-password --gecos "" "$user"
    else
      run adduser --gecos "" "$user"
    fi
  fi
  if (( with_sudo )); then
    pkg_install sudo
    run usermod -aG sudo "$user"
    ok "$user added to the sudo group"
  fi
  if [[ -n "$pubkey" ]]; then
    home="/home/$user"
    run install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
    if (( DRY_RUN )); then
      printf '%s[DRY ]%s  append public key to %s\n' "$C_YELLOW" "$C_RESET" "$home/.ssh/authorized_keys"
    else
      printf '%s\n' "$pubkey" >>"$home/.ssh/authorized_keys"
      chown "$user:$user" "$home/.ssh/authorized_keys"
      chmod 600 "$home/.ssh/authorized_keys"
    fi
    ok "SSH public key installed for $user"
  fi
}

cmd_ssh_harden() {
  require_root
  local port=""
  while (( $# )); do
    case "$1" in
      --port) shift; port="${1:-}"
              [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) \
                || die "Invalid SSH port '$port'" ;;
      *) die "Unknown option for ssh-harden: $1" ;;
    esac
    shift
  done

  warn "This disables root login and password authentication."
  warn "Make sure a non-root user with an SSH key can log in BEFORE continuing."
  confirm "Apply SSH hardening?" || { info "Aborted"; return 0; }

  pkg_install openssh-server
  backup_file "$SSH_DROPIN"
  run mkdir -p /etc/ssh/sshd_config.d
  {
    cat <<'EOF'
# Managed by DebNetAdmin
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
    [[ -n "$port" ]] && printf 'Port %s\n' "$port"
    true
  } | write_file "$SSH_DROPIN"

  if (( ! DRY_RUN )); then
    if sshd -t; then
      systemctl reload ssh
      ok "SSH hardened and reloaded. Keep this session open and test a new login."
    else
      rm -f "$SSH_DROPIN"
      die "sshd configuration test failed; changes were reverted."
    fi
  fi
  [[ -n "$port" ]] && warn "SSH port changed to $port: open it with '$PROG fw-allow $port/tcp'"
  return 0
}

# ---------------------------------------------------------------------------
# Commands: firewall and intrusion prevention
# ---------------------------------------------------------------------------
detect_ssh_port() {
  local p=""
  if have sshd; then
    p="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
  fi
  printf '%s' "${p:-22}"
}

cmd_fw_setup() {
  require_root
  local ssh_port
  ssh_port="$(detect_ssh_port)"
  info "Configuring UFW (default deny incoming, allow outgoing)"
  pkg_install ufw
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw allow "${ssh_port}/tcp" comment 'SSH'
  confirm "Enable the firewall now? SSH on port ${ssh_port}/tcp is allowed." || {
    info "Firewall configured but NOT enabled"; return 0; }
  run ufw --force enable
  ok "Firewall enabled"
}

cmd_fw_allow() {
  require_root
  local rule="${1:-}" from="${2:-}"
  [[ "$rule" =~ ^[0-9]+(:[0-9]+)?(/(tcp|udp))?$ ]] || \
    die "Usage: $PROG fw-allow <port>[/tcp|/udp] [source-cidr]"
  local port="${rule%%/*}" proto=""
  [[ "$rule" == */* ]] && proto="${rule##*/}"
  if [[ -n "$from" && -n "$proto" ]]; then
    run ufw allow from "$from" to any port "$port" proto "$proto"
  elif [[ -n "$from" ]]; then
    run ufw allow from "$from" to any port "$port"
  else
    run ufw allow "$rule"
  fi
  ok "Rule added: $rule ${from:+from $from}"
}

cmd_fw_preset() {
  require_root
  local svc="${1:-}" rule
  valid_service "$svc"
  for rule in ${SERVICE_PORTS[$svc]}; do
    run ufw allow "$rule" comment "$svc"
  done
  ok "Firewall ports opened for $svc: ${SERVICE_PORTS[$svc]}"
}

cmd_fw_status() {
  have ufw || die "UFW is not installed. Run: $PROG fw-setup"
  ufw status verbose
}

cmd_fail2ban() {
  require_root
  info "Installing and configuring Fail2ban"
  pkg_install fail2ban
  write_file /etc/fail2ban/jail.d/debnetadmin.local <<'EOF'
# Managed by DebNetAdmin
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
EOF
  run systemctl enable --now fail2ban
  run systemctl restart fail2ban
  ok "Fail2ban active (sshd jail enabled)"
}

# ---------------------------------------------------------------------------
# Commands: network services
# ---------------------------------------------------------------------------
cmd_install() {
  require_root
  local svc="${1:-}" unit
  valid_service "$svc"
  info "Installing $svc (${SERVICE_PKGS[$svc]})"
  # shellcheck disable=SC2086
  pkg_install ${SERVICE_PKGS[$svc]}
  if [[ "$svc" != "wireguard" ]]; then
    for unit in ${SERVICE_UNITS[$svc]}; do
      run systemctl enable --now "$unit" || warn "Could not start $unit (needs configuration?)"
    done
  else
    info "WireGuard needs /etc/wireguard/wg0.conf before 'wg-quick@wg0' can start."
  fi
  case "$svc" in
    dhcp) warn "isc-dhcp-server is end-of-life and absent from recent Debian releases; consider 'kea'." ;;
  esac
  ok "$svc installed. Open its ports with: $PROG fw-preset $svc"
}

cmd_svc() {
  local action="${1:-}" svc="${2:-}" unit
  valid_service "$svc"
  case "$action" in
    status)
      for unit in ${SERVICE_UNITS[$svc]}; do
        systemctl --no-pager status "$unit" || true
      done ;;
    start|stop|restart|reload|enable|disable)
      require_root
      for unit in ${SERVICE_UNITS[$svc]}; do
        run systemctl "$action" "$unit"
      done
      ok "$action: $svc" ;;
    *) die "Usage: $PROG svc <status|start|stop|restart|reload|enable|disable> <service>" ;;
  esac
}

cmd_logs() {
  local svc="${1:-}" lines="${2:-100}" unit args=()
  valid_service "$svc"
  [[ "$lines" =~ ^[0-9]+$ ]] || die "Line count must be a number"
  for unit in ${SERVICE_UNITS[$svc]}; do args+=(-u "$unit"); done
  journalctl "${args[@]}" -n "$lines" --no-pager
}

check_one_config() {
  local svc="$1" cmd
  local -a parts
  read -r -a parts <<<"${CONFIG_TESTS[$svc]}"
  cmd="${parts[0]}"
  if ! have "$cmd"; then
    return 2
  fi
  if "${parts[@]}" >/dev/null 2>&1; then
    ok "$svc: configuration is valid"
  else
    err "$svc: configuration test FAILED (run '${CONFIG_TESTS[$svc]}' for details)"
    return 1
  fi
}

cmd_check_config() {
  local target="${1:-all}" svc failures=0 rc
  if [[ "$target" == "all" ]]; then
    for svc in $(printf '%s\n' "${!CONFIG_TESTS[@]}" | sort); do
      rc=0; check_one_config "$svc" || rc=$?
      (( rc == 1 )) && failures=$((failures + 1))
    done
  else
    [[ -n "${CONFIG_TESTS[$target]+x}" ]] || die "No config test available for '$target'"
    check_one_config "$target" || failures=1
  fi
  (( failures == 0 )) || die "$failures configuration test(s) failed"
}

# ---------------------------------------------------------------------------
# HTML report generator
#   report [-o FILE] [--title T] [--author A] [--mail ADDR] [--quiet]
#   report-schedule / report-list
# The report is one self-contained HTML file (inline CSS, no JavaScript, no
# external requests). It scores the server from collected findings.
# ---------------------------------------------------------------------------
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "$0")"
readonly SCRIPT_PATH
readonly REPORT_KEEP="${DEBNETADMIN_REPORT_KEEP:-12}"
readonly CRON_REPORT="/etc/cron.d/debnetadmin-report"
readonly RE_EMAIL='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'

declare -A RISKY_PORTS=(
  [21]="FTP" [23]="Telnet" [69]="TFTP" [111]="rpcbind" [135]="MS-RPC"
  [139]="NetBIOS" [445]="SMB" [512]="rexec" [513]="rlogin" [514]="rsh"
  [2049]="NFS" [3306]="MySQL/MariaDB" [5432]="PostgreSQL" [5900]="VNC"
  [6379]="Redis" [9200]="Elasticsearch" [11211]="Memcached" [27017]="MongoDB"
)

FIND_SEV=(); FIND_MSG=(); FIND_FIX=()
REPORT_BODY=""
REPORT_LIMITED=0

report_default_dir() {
  if (( EUID == 0 )); then
    printf '%s' "${DEBNETADMIN_REPORT_DIR:-/var/lib/debnetadmin/reports}"
  else
    printf '%s' "${DEBNETADMIN_REPORT_DIR:-$PWD}"
  fi
}

# --- small HTML helpers ----------------------------------------------------
esc()  { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
hesc() { printf '%s' "$*" | esc; }
out()  { printf '%s\n' "$*" >>"$REPORT_BODY"; }
finding() { FIND_SEV+=("$1"); FIND_MSG+=("$2"); FIND_FIX+=("${3:-}"); }

badge() { printf '<span class="badge %s">%s</span>' "$1" "$(hesc "$2")"; }

bar() {
  local p="${1:-0}" cls="ok"
  if   (( p >= 90 )); then cls="crit"
  elif (( p >= 80 )); then cls="warn"
  fi
  printf '<span style="white-space:nowrap"><span class="bar"><i class="%s" style="width:%s%%"></i></span> %s%%</span>' "$cls" "$p" "$p"
}

hsize() {
  awk -v k="${1:-0}" 'BEGIN { split("KiB MiB GiB TiB", u, " "); i = 1;
    while (k >= 1024 && i < 4) { k /= 1024; i++ } printf "%.1f %s", k, u[i] }'
}

rep_open()  { out "<section id=\"$1\"><h2>$2</h2>"; }
rep_close() { out "</section>"; }
rep_h3()    { out "<h3>$(hesc "$1")</h3>"; }
rep_note()  { out "<p class=\"muted\">$*</p>"; }

kv_begin() { out '<table class="kv"><tbody>'; }
kv()       { out "<tr><th>$(hesc "$1")</th><td>$(hesc "${2:-}")</td></tr>"; }
kv_raw()   { out "<tr><th>$(hesc "$1")</th><td>$2</td></tr>"; }
kv_end()   { out '</tbody></table>'; }

# rep_table <headers...>   stdin: tab-separated rows; cells starting with @@ are raw HTML
rep_table() {
  local h
  out '<div class="tablewrap"><table><thead><tr>'
  for h in "$@"; do out "<th>$(hesc "$h")</th>"; done
  out '</tr></thead><tbody>'
  awk -F'\t' 'NF == 0 { next }
    { printf "<tr>"
      for (i = 1; i <= NF; i++) {
        if (substr($i, 1, 2) == "@@") { printf "<td>%s</td>", substr($i, 3); continue }
        gsub(/&/, "\\&amp;", $i); gsub(/</, "\\&lt;", $i); gsub(/>/, "\\&gt;", $i)
        printf "<td>%s</td>", $i }
      print "</tr>" }' >>"$REPORT_BODY"
  out '</tbody></table></div>'
}

# rep_cmd <label> <command> [args...]   -> output in a <pre> block
rep_cmd() {
  local label="$1" outp
  shift
  rep_h3 "$label"
  if ! have "$1"; then
    rep_note "Not available: <code>$(hesc "$1")</code> is not installed."
    return 0
  fi
  outp="$("$@" 2>&1 || true)"
  if [[ -z "$outp" ]]; then rep_note "No output."
  else out "<pre>$(printf '%s' "$outp" | esc)</pre>"; fi
}

# rep_sh <label> <shell snippet>   (snippets are static and trusted)
rep_sh() {
  local outp
  rep_h3 "$1"
  outp="$(bash -c "$2" 2>&1 || true)"
  if [[ -z "$outp" ]]; then rep_note "No output."
  else out "<pre>$(printf '%s' "$outp" | esc)</pre>"; fi
}

limited() { REPORT_LIMITED=1; rep_note "$(badge info "Limited") $*"; }

# --- sections --------------------------------------------------------------
rep_system() {
  local deb major virt ntp tz
  rep_open system "System"
  deb="$(cat /etc/debian_version 2>/dev/null || echo n/a)"
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [[ -n "$tz" ]] || tz="$(cat /etc/timezone 2>/dev/null || echo n/a)"
  ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  kv_begin
  kv "Hostname" "$(hostname -f 2>/dev/null || hostname)"
  kv "Operating system" "$(os_field PRETTY_NAME)"
  kv "Debian version" "$deb"
  kv "Kernel" "$(uname -r)"
  kv "Architecture" "$(uname -m)"
  kv "Uptime" "$(uptime -p 2>/dev/null || echo n/a)"
  kv "Booted" "$(uptime -s 2>/dev/null || echo n/a)"
  kv "Virtualization" "${virt:-unknown}"
  kv "Time zone" "$tz"
  kv "Clock synchronised (NTP)" "${ntp:-unknown}"
  kv "Current time" "$(date '+%F %T %Z')"
  kv_end
  major="${deb%%.*}"
  if [[ "$major" =~ ^[0-9]+$ ]]; then
    case "$major" in
      [1-9]|10|11) finding crit "Debian $major is past the end of Debian's regular and LTS security support (per Debian's published schedule)" "Plan an upgrade to the current stable release" ;;
      12) finding info "Debian 12 is in long-term support (LTS)" "Plan the upgrade to Debian 13 before LTS ends in 2028" ;;
      13) finding ok "Debian 13 is a supported release" ;;
    esac
  fi
  case "$ntp" in
    yes) finding ok "System clock is synchronised" ;;
    no)  finding warn "System clock is not synchronised" "debnetadmin time-sync" ;;
  esac
  if [[ -f /var/run/reboot-required ]]; then
    finding warn "A reboot is pending to apply updates" "Schedule a maintenance window and reboot"
    kv_begin; kv_raw "Reboot required" "$(badge warn yes)"; kv_end
  fi
  rep_close
}

rep_hardware() {
  local cores model l1 l5 l15 mt ma st sf mp sp mu su
  rep_open hardware "Hardware and resources"
  cores="$(nproc 2>/dev/null || echo 1)"
  model="$(awk -F: '/model name/ {gsub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  read -r l1 l5 l15 _ </proc/loadavg
  mt="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  ma="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
  st="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
  sf="$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)"
  mt="${mt:-0}"; ma="${ma:-0}"; st="${st:-0}"; sf="${sf:-0}"
  mp=0; (( mt > 0 )) && mp=$(( 100 - ma * 100 / mt ))
  mu=$(( mt - ma ))
  sp=0; (( st > 0 )) && sp=$(( 100 - sf * 100 / st ))
  su=$(( st - sf ))
  kv_begin
  kv "CPU model" "${model:-n/a}"
  kv "CPU cores" "$cores"
  kv "Load average (1/5/15 min)" "$l1 / $l5 / $l15"
  kv_raw "Memory" "$(hesc "$(hsize "$mu") used of $(hsize "$mt")") &nbsp; $(bar "$mp")"
  kv "Memory available" "$(hsize "$ma")"
  if (( st > 0 )); then
    kv_raw "Swap" "$(hesc "$(hsize "$su") used of $(hsize "$st")") &nbsp; $(bar "$sp")"
  else
    kv "Swap" "not configured"
  fi
  if have dmidecode && (( EUID == 0 )); then
    kv "Hardware" "$(dmidecode -s system-manufacturer 2>/dev/null | head -1) $(dmidecode -s system-product-name 2>/dev/null | head -1)"
  fi
  kv_end
  if (( mt > 0 )) && (( ma * 100 / mt < 10 )); then
    finding warn "Available memory is below 10% (${mp}% in use)" "debnetadmin procs mem; consider adding RAM or swap (debnetadmin swap-add 2G)"
  else
    finding ok "Memory usage is healthy (${mp}% in use)"
  fi
  if (( st > 0 )) && (( sp > 80 )); then
    finding warn "Swap usage is high (${sp}%)" "Check memory-hungry processes: debnetadmin procs mem"
  fi
  if awk -v l="$l1" -v c="$cores" 'BEGIN { exit !(l > c * 2) }'; then
    finding warn "Load average ($l1) is more than twice the CPU count ($cores)" "debnetadmin procs cpu"
  else
    finding ok "CPU load is normal ($l1 on $cores cores)"
  fi
  rep_close
}

rep_storage() {
  local fs type size used avail pct mnt p rows="" inode_bad=0 d smart state bad=0 name
  rep_open storage "Storage"
  rep_h3 "Filesystems"
  while read -r fs type size used avail pct mnt; do
    p="${pct%\%}"
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    rows+="$fs"$'\t'"$type"$'\t'"$size"$'\t'"$used"$'\t'"$avail"$'\t'"@@$(bar "$p")"$'\t'"$mnt"$'\n'
    if   (( p >= 90 )); then finding crit "Filesystem $mnt is ${p}% full" "debnetadmin disk-usage $mnt; debnetadmin pkg clean; debnetadmin journal-vacuum 200M"
    elif (( p >= 80 )); then finding warn "Filesystem $mnt is ${p}% full" "debnetadmin disk-usage $mnt"
    fi
  done < <(df -PTh -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | tail -n +2)
  rep_table "Filesystem" "Type" "Size" "Used" "Avail" "Use" "Mounted on" <<<"$rows"

  while read -r fs _ _ _ pct mnt; do
    p="${pct%\%}"
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    if (( p >= 90 )); then
      finding crit "Inode usage on $mnt is ${p}%" "Find directories with many small files: debnetadmin disk-usage $mnt"
      inode_bad=1
    fi
  done < <(df -Pi -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)
  (( inode_bad )) || finding ok "Inode usage is healthy on all filesystems"

  rep_cmd "Block devices" lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
  rep_sh "Persistent mounts (/etc/fstab)" "grep -vE '^[[:space:]]*(#|\$)' /etc/fstab"
  if grep -q '^md' /proc/mdstat 2>/dev/null; then
    rep_sh "Software RAID" "cat /proc/mdstat"
    if grep -qE '\[[U_]*_[U_]*\]' /proc/mdstat; then
      finding crit "A software RAID array is degraded" "cat /proc/mdstat; replace the failed disk"
    else
      finding ok "Software RAID arrays are healthy"
    fi
  fi
  if have lvs && (( EUID == 0 )); then rep_cmd "LVM logical volumes" lvs; fi

  rep_h3 "Disk health (SMART)"
  if have smartctl && (( EUID == 0 )); then
    rows=""
    while read -r name; do
      [[ -n "$name" ]] || continue
      state="$(smartctl -H "/dev/$name" 2>/dev/null | awk -F: '/overall-health|SMART Health Status/ {gsub(/^ +/, "", $2); print $2}')"
      state="${state:-unsupported}"
      case "$state" in
        PASSED|OK) smart="$(badge ok "$state")" ;;
        unsupported) smart="$(badge info "$state")" ;;
        *) smart="$(badge crit "$state")"; bad=1
           finding crit "SMART health check FAILED on /dev/$name" "Back up immediately and replace the disk" ;;
      esac
      rows+="/dev/$name"$'\t'"@@$smart"$'\n'
    done < <(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2 == "disk" {print $1}')
    rep_table "Disk" "SMART status" <<<"$rows"
    (( bad )) || finding ok "SMART reports no failing disks"
  else
    rep_note "SMART data needs root and the <code>smartmontools</code> package."
    [[ "$(systemd-detect-virt 2>/dev/null || true)" == none ]] && finding info "SMART monitoring is not available on this physical server" "debnetadmin install-smart"
    (( EUID == 0 )) || REPORT_LIMITED=1
  fi
  rep_close
}

rep_network() {
  local proto state rq sq loc peer proc port addr expo pname rows="" nr
  local -A seen=()
  rep_open network "Network"
  rep_cmd "Interfaces" ip -br addr
  rep_cmd "Routing table" ip route
  rep_sh "DNS configuration" "grep -E '^(nameserver|search|domain)' /etc/resolv.conf"
  rep_sh "Hosts file" "grep -vE '^[[:space:]]*(#|\$)' /etc/hosts"

  rep_h3 "Listening sockets"
  if have ss; then
    while read -r proto state rq sq loc peer proc; do
      [[ -n "$loc" ]] || continue
      port="${loc##*:}"; addr="${loc%:*}"; addr="${addr%%%*}"
      case "$addr" in
        0.0.0.0|\*|\[::\]|::) expo="all interfaces" ;;
        127.*|\[::1\]|::1)    expo="localhost only" ;;
        *)                    expo="$addr" ;;
      esac
      pname=""
      [[ "$proc" =~ \(\(\"([^\"]+)\" ]] && pname="${BASH_REMATCH[1]}"
      rows+="$proto"$'\t'"$loc"$'\t'"$(if [[ "$expo" == "all interfaces" ]]; then printf '@@%s' "$(badge warn "$expo")"; else printf '%s' "$expo"; fi)"$'\t'"$pname"$'\n'
      if [[ "$expo" == "all interfaces" && -n "${RISKY_PORTS[$port]+x}" && -z "${seen[$port]+x}" ]]; then
        seen[$port]=1
        finding warn "${RISKY_PORTS[$port]} (port $port) listens on all interfaces" "Restrict it with the firewall: debnetadmin fw-allow $port/tcp <trusted-cidr>"
      fi
    done < <(ss -H -tulpn 2>/dev/null)
    rep_table "Proto" "Local address" "Exposure" "Process" <<<"$rows"
    nr="$(ss -H -tn state established 2>/dev/null | wc -l)"
    rep_note "Established TCP connections: <strong>$nr</strong>"
    (( EUID == 0 )) || rep_note "Process names are limited without root."
  else
    rep_note "The <code>ss</code> command is not available."
  fi

  rep_h3 "Firewall"
  if systemctl is-active --quiet ufw 2>/dev/null; then
    finding ok "Firewall (UFW) is active"
    if (( EUID == 0 )); then rep_cmd "UFW rules" ufw status verbose; else limited "UFW rules need root."; fi
  elif have nft && (( EUID == 0 )) && [[ -n "$(nft list ruleset 2>/dev/null)" ]]; then
    finding ok "A nftables ruleset is loaded"
    rep_cmd "nftables ruleset" nft list ruleset
  elif have iptables && (( EUID == 0 )) && (( $(iptables -S 2>/dev/null | wc -l) > 3 )); then
    finding ok "iptables rules are loaded"
    rep_cmd "iptables rules" iptables -S
  elif (( EUID != 0 )); then
    limited "The firewall state could not be verified without root."
    finding info "Firewall state could not be verified (run the report as root)"
  else
    rep_note "$(badge crit "No firewall")"
    finding crit "No active firewall detected" "debnetadmin fw-setup"
  fi
  rep_close
}

rep_services() {
  local k pkg unit state en col rows="" line
  rep_open services "Services"
  rep_h3 "Managed service catalogue"
  for k in $(printf '%s\n' "${!SERVICE_PKGS[@]}" | sort); do
    pkg="${SERVICE_PKGS[$k]%% *}"
    unit="${SERVICE_UNITS[$k]%% *}"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      state="$(systemctl is-active "$unit" 2>/dev/null || true)"
      en="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
      case "$state" in
        active) col="ok" ;;
        failed) col="crit" ;;
        *)      col="warn" ;;
      esac
      rows+="$k"$'\t'"@@$(badge "$col" "${state:-unknown}")"$'\t'"${en:-n/a}"$'\t'"${SERVICE_PORTS[$k]}"$'\n'
    fi
  done
  if [[ -n "$rows" ]]; then
    rep_table "Service" "State" "Boot" "Standard ports" <<<"$rows"
  else
    rep_note "None of the catalogue services is installed."
  fi

  rep_h3 "Running services"
  if have systemctl; then
    rows=""
    while read -r line; do
      [[ -n "$line" ]] || continue
      unit="${line%% *}"
      rows+="$unit"$'\t'"${line#* * * * }"$'\n'
    done < <(systemctl list-units --type=service --state=running --no-legend --plain --no-pager 2>/dev/null)
    rep_table "Unit" "Description" <<<"$rows"
  fi

  rep_h3 "Failed units"
  rows=""
  while read -r unit _; do
    [[ -n "$unit" ]] || continue
    rows+="$unit"$'\n'
    finding warn "systemd unit $unit has failed" "debnetadmin logs ${unit%.service} 50   (or: journalctl -u $unit)"
  done < <(systemctl --failed --no-legend --plain --no-pager 2>/dev/null)
  if [[ -z "$rows" ]]; then
    rep_note "$(badge ok "None")"
    finding ok "No failed systemd units"
  else
    rep_table "Failed unit" <<<"$rows"
  fi
  rep_cmd "Timers" systemctl list-timers --all --no-pager
  rep_close
}

ssh_cfg_value() {
  local key="$1"
  if [[ -n "${SSHD_T:-}" ]]; then
    awk -v k="${key,,}" 'tolower($1) == k {print tolower($2); exit}' <<<"$SSHD_T"
  else
    cat /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config 2>/dev/null \
      | awk -v k="${key,,}" 'tolower($1) == k {print tolower($2); exit}'
  fi
}

rep_security() {
  local root_login pass_auth rows="" k v name uid shell u f2b ua status fails
  local deviations=0 cur want para
  SSHD_T=""
  rep_open security "Security"

  rep_h3 "SSH daemon"
  if have sshd && (( EUID == 0 )); then SSHD_T="$(sshd -T 2>/dev/null || true)"
  elif (( EUID != 0 )); then REPORT_LIMITED=1; fi
  if [[ -r /etc/ssh/sshd_config ]]; then
    for k in port permitrootlogin passwordauthentication pubkeyauthentication kbdinteractiveauthentication \
             permitemptypasswords x11forwarding maxauthtries logingracetime allowusers allowgroups; do
      v="$(ssh_cfg_value "$k")"
      case "$k" in
        permitrootlogin)        v="${v:-prohibit-password (default)}" ;;
        passwordauthentication) v="${v:-yes (default)}" ;;
        port)                   v="${v:-22 (default)}" ;;
      esac
      [[ -n "$v" ]] && rows+="$k"$'\t'"$v"$'\n'
    done
    rep_table "Setting" "Value" <<<"$rows"
    root_login="$(ssh_cfg_value permitrootlogin)"; root_login="${root_login:-prohibit-password}"
    pass_auth="$(ssh_cfg_value passwordauthentication)"; pass_auth="${pass_auth:-yes}"
    case "$root_login" in
      no) finding ok "SSH root login is disabled" ;;
      prohibit-password|without-password) finding warn "SSH root login is allowed with keys" "debnetadmin ssh-harden" ;;
      *)  finding crit "SSH root login is allowed" "debnetadmin ssh-harden" ;;
    esac
    if [[ "$pass_auth" == no ]]; then finding ok "SSH password authentication is disabled"
    else finding warn "SSH password authentication is enabled" "debnetadmin ssh-harden (after installing an SSH key)"; fi
  else
    rep_note "OpenSSH server is not installed."
  fi

  rep_h3 "Privileged and login accounts"
  rows=""
  while IFS=: read -r name _ uid _ _ _ shell; do
    if (( uid == 0 )) && [[ "$name" != root ]]; then
      finding crit "Account '$name' has UID 0 (root equivalent)" "Investigate and remove it: debnetadmin user-del $name"
    fi
  done </etc/passwd
  for f2b in sudo adm wheel; do
    u="$(getent group "$f2b" 2>/dev/null | cut -d: -f4)"
    [[ -n "$u" ]] && rows+="$f2b"$'\t'"${u//,/, }"$'\n'
  done
  rep_table "Group" "Members" <<<"$rows"
  if (( EUID == 0 )); then
    if [[ -r /etc/shadow ]]; then
      u="$(awk -F: '$2 == "" {printf "%s ", $1}' /etc/shadow)"
      if [[ -n "$u" ]]; then finding crit "Accounts with an empty password: $u" "Set a password or lock them: debnetadmin user-lock <name>"
      else finding ok "No accounts have an empty password"; fi
    fi
    if grep -rqsE '^[^#]*NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null; then
      finding info "sudo rules with NOPASSWD exist" "Review: grep -r NOPASSWD /etc/sudoers /etc/sudoers.d"
    fi
  else
    REPORT_LIMITED=1
  fi

  rep_h3 "Kernel hardening parameters"
  rows=""
  while IFS='=' read -r para want; do
    cur="$(sysctl -n "$para" 2>/dev/null || echo n/a)"
    if [[ "$cur" == "$want" ]]; then status="$(badge ok OK)"
    else status="$(badge warn Differs)"; deviations=$((deviations + 1)); fi
    rows+="$para"$'\t'"$cur"$'\t'"$want"$'\t'"@@$status"$'\n'
  done <<'EOF'
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.icmp_echo_ignore_broadcasts=1
kernel.randomize_va_space=2
EOF
  rep_table "Parameter" "Current" "Recommended" "Status" <<<"$rows"
  if (( deviations > 0 )); then
    finding warn "$deviations kernel network/memory parameters differ from the recommended profile" "debnetadmin sysctl-harden"
  else
    finding ok "Kernel hardening parameters match the recommended profile"
  fi

  rep_h3 "Intrusion prevention and automatic updates"
  kv_begin
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    kv_raw "Fail2ban" "$(badge ok active)"; finding ok "Fail2ban is active"
  else
    kv_raw "Fail2ban" "$(badge warn "not active")"; finding warn "Fail2ban is not active" "debnetadmin fail2ban"
  fi
  if dpkg -s unattended-upgrades >/dev/null 2>&1; then
    ua="$(apt-config dump 2>/dev/null | awk -F'"' '/APT::Periodic::Unattended-Upgrade/ {print $2}')"
    if [[ "$ua" == 1 ]]; then kv_raw "Unattended upgrades" "$(badge ok enabled)"; finding ok "Automatic security updates are enabled"
    else kv_raw "Unattended upgrades" "$(badge warn "installed, not enabled")"; finding warn "Unattended upgrades are installed but not enabled" "debnetadmin autoupdates"; fi
  else
    kv_raw "Unattended upgrades" "$(badge warn "not installed")"
    finding warn "Automatic security updates are not configured" "debnetadmin autoupdates"
  fi
  if systemctl is-active --quiet apparmor 2>/dev/null; then kv_raw "AppArmor" "$(badge ok active)"
  else kv_raw "AppArmor" "$(badge info "not active")"; fi
  kv_end
  if (( EUID == 0 )) && have fail2ban-client && systemctl is-active --quiet fail2ban 2>/dev/null; then
    rep_cmd "Fail2ban jails" fail2ban-client status
  fi

  rep_h3 "Authentication activity (last 24 hours)"
  fails="$( { journalctl --since '24 hours ago' --no-pager -t sshd -t sshd-session 2>/dev/null \
              || grep -h 'sshd' /var/log/auth.log 2>/dev/null; } | grep -cE 'Failed password|Invalid user' || true)"
  fails="${fails:-0}"
  rep_note "Failed SSH login attempts: <strong>$fails</strong>"
  if (( fails > 0 )); then
    rows="$( { journalctl --since '24 hours ago' --no-pager -t sshd -t sshd-session 2>/dev/null \
               || grep -h 'sshd' /var/log/auth.log 2>/dev/null; } \
             | grep -E 'Failed password|Invalid user' | grep -oE 'from [0-9a-fA-F:.]+' | awk '{print $2}' \
             | sort | uniq -c | sort -rn | head -10 | awk '{print $2 "\t" $1}')"
    [[ -n "$rows" ]] && rep_table "Source address" "Attempts" <<<"$rows"
  fi
  if (( fails > 200 )); then
    finding warn "$fails failed SSH logins in the last 24 hours" "Use keys only (debnetadmin ssh-harden) and enable Fail2ban (debnetadmin fail2ban)"
  else
    finding ok "Failed SSH login volume is low ($fails in 24 h)"
  fi
  rep_cmd "Recent logins" last -n 10 -F
  rep_close
}

rep_packages() {
  local total upg sec held rows="" line pkg ver
  rep_open packages "Packages and updates"
  total="$(dpkg-query -f '.\n' -W 2>/dev/null | wc -l)"
  upg="$(apt list --upgradable 2>/dev/null | tail -n +2 | grep -c . || true)"
  sec="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst.*[Ss]ecurity' || true)"
  held="$(apt-mark showhold 2>/dev/null | tr '\n' ' ')"
  kv_begin
  kv "Installed packages" "$total"
  kv "Upgradable packages" "${upg:-0}"
  kv "Pending security updates" "${sec:-0}"
  kv "Held packages" "${held:-none}"
  kv "Last APT transaction" "$(awk '/^Start-Date/ {d=$2" "$3} END {print d}' /var/log/apt/history.log 2>/dev/null)"
  kv_end
  if (( ${sec:-0} > 0 )); then
    finding warn "${sec} security update(s) are pending" "debnetadmin update"
  elif (( ${upg:-0} > 0 )); then
    finding info "${upg} package update(s) are available" "debnetadmin update"
  else
    finding ok "All packages are up to date"
  fi
  if (( ${upg:-0} > 0 )); then
    while IFS= read -r line; do
      pkg="${line%%/*}"; ver="$(awk '{print $2}' <<<"$line")"
      rows+="$pkg"$'\t'"$ver"$'\n'
    done < <(apt list --upgradable 2>/dev/null | tail -n +2 | head -40)
    rep_h3 "Upgradable packages (first 40)"
    rep_table "Package" "New version" <<<"$rows"
  fi
  rep_sh "APT sources" "grep -rhE '^(deb |deb-src |URIs:|Suites:|Components:)' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null"
  rep_close
}

rep_users() {
  local name uid home shell groups st last rows="" login
  rep_open users "Users and groups"
  while IFS=: read -r name _ uid _ _ home shell; do
    (( uid == 0 || uid >= 1000 )) || continue
    [[ "$name" == nobody ]] && continue
    groups="$(id -nG "$name" 2>/dev/null | tr ' ' ',')"
    case "$shell" in */nologin|*/false|"") login="no" ;; *) login="yes" ;; esac
    st="n/a"
    if (( EUID == 0 )); then
      st="$(passwd -S "$name" 2>/dev/null | awk '{print $2}')"
      case "$st" in
        P)  st="@@$(badge ok "password set")" ;;
        L)  st="@@$(badge info locked)" ;;
        NP) st="@@$(badge crit "no password")"
            [[ "$login" == yes ]] && finding crit "Account '$name' can log in without a password" "debnetadmin user-lock $name" ;;
      esac
    fi
    last="$(lastlog -u "$name" 2>/dev/null | sed -n '2s/^[^ ]* *//p')"
    [[ "$last" == *Never* ]] && last="never"
    rows+="$name"$'\t'"$uid"$'\t'"$login"$'\t'"$st"$'\t'"${last:-n/a}"$'\t'"$groups"$'\n'
  done </etc/passwd
  rep_table "User" "UID" "Login shell" "Password" "Last login" "Groups" <<<"$rows"
  (( EUID == 0 )) || limited "Password status needs root."
  rep_close
}

rep_scheduled() {
  local u rows=""
  rep_open scheduled "Scheduled tasks"
  rep_sh "System crontab" "grep -vE '^[[:space:]]*(#|\$)' /etc/crontab"
  rep_sh "Files in /etc/cron.d and periodic directories" "ls -1 /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly 2>/dev/null"
  if (( EUID == 0 )); then
    for u in $(cut -d: -f1 /etc/passwd); do
      crontab -l -u "$u" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' | sed "s/^/$u: /" || true
    done >/tmp/.dna_cron.$$ 2>/dev/null || true
    rows="$(cat /tmp/.dna_cron.$$ 2>/dev/null || true)"; rm -f /tmp/.dna_cron.$$
    if [[ -n "$rows" ]]; then out "<h3>User crontabs</h3><pre>$(printf '%s' "$rows" | esc)</pre>"
    else rep_note "No user crontabs."; fi
  fi
  rep_close
}

rep_logs() {
  local errs oom
  rep_open logs "Logs and events"
  errs="$(journalctl -p err --since '24 hours ago' --no-pager -q 2>/dev/null | wc -l)"
  oom="$(journalctl -k --since '7 days ago' --no-pager -q 2>/dev/null | grep -ciE 'out of memory|oom-kill' || true)"
  kv_begin
  kv "Error-level journal entries (24 h)" "${errs:-0}"
  kv "Out-of-memory kills (7 days)" "${oom:-0}"
  kv "Journal disk usage" "$(journalctl --disk-usage 2>/dev/null | sed 's/^.*take up //; s/ in the .*//; s/\.$//')"
  kv "/var/log size" "$(du -sh /var/log 2>/dev/null | cut -f1)"
  kv_end
  if (( ${errs:-0} > 100 )); then
    finding warn "${errs} error-level log entries in the last 24 hours" "debnetadmin logs-errors 24"
  else
    finding ok "Error log volume is normal (${errs:-0} in 24 h)"
  fi
  if (( ${oom:-0} > 0 )); then
    finding warn "The kernel killed processes for lack of memory (${oom} event(s) in 7 days)" "debnetadmin procs mem; add RAM or swap"
  fi
  rep_sh "Latest error-level entries (up to 40)" "journalctl -p err --since '24 hours ago' --no-pager -q -n 40"
  rep_close
}

rep_processes() {
  local z
  rep_open processes "Processes"
  z="$(ps -eo stat 2>/dev/null | grep -c '^Z' || true)"
  kv_begin; kv "Total processes" "$(ps -e --no-headers 2>/dev/null | wc -l)"; kv "Zombie processes" "${z:-0}"; kv_end
  (( ${z:-0} > 0 )) && finding warn "${z} zombie process(es) present" "Identify the parent: ps -eo pid,ppid,stat,comm | awk '\$3 ~ /^Z/'"
  rep_sh "Top 10 by CPU" "ps -eo pid,user,%cpu,%mem,etime,comm --sort=-%cpu | head -11"
  rep_sh "Top 10 by memory" "ps -eo pid,user,%cpu,%mem,etime,comm --sort=-%mem | head -11"
  rep_close
}

rep_backups_certs() {
  local f latest age end days rows="" now c col
  rep_open backups "Backups and certificates"
  rep_h3 "Backups ($BACKUP_DIR)"
  now="$(date +%s)"
  if (( EUID == 0 )) && [[ ! -d "$BACKUP_DIR" ]]; then
    rep_note "No backups found."
    finding warn "No backups were found in $BACKUP_DIR" "debnetadmin backup"
  elif [[ -r "$BACKUP_DIR" ]]; then
    latest="$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.sql.gz' \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)"
    if [[ -n "$latest" ]]; then
      age=$(( (now - $(stat -c %Y "$latest")) / 86400 ))
      while IFS= read -r f; do
        rows+="$(basename "$f")"$'\t'"$(du -h "$f" | cut -f1)"$'\t'"$(date -r "$f" '+%F %T')"$'\n'
      done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.sql.gz' \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -10 | cut -d' ' -f2-)
      rep_table "File" "Size" "Created" <<<"$rows"
      if (( age > 7 )); then finding warn "The newest backup is $age days old" "debnetadmin backup"
      else finding ok "A recent backup exists ($age day(s) old)"; fi
    else
      rep_note "No backups found."
      finding warn "No backups were found in $BACKUP_DIR" "debnetadmin backup"
    fi
  else
    limited "The backup directory is only readable by root."
  fi

  rep_h3 "TLS certificates (Let's Encrypt)"
  rows=""
  for f in /etc/letsencrypt/live/*/cert.pem; do
    [[ -r "$f" ]] || continue
    end="$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)"
    [[ -n "$end" ]] || continue
    days=$(( ( $(date -d "$end" +%s 2>/dev/null || echo "$now") - now ) / 86400 ))
    c="$(basename "$(dirname "$f")")"
    if   (( days < 14 )); then col="crit"; finding crit "Certificate for $c expires in $days day(s)" "debnetadmin cert-renew"
    elif (( days < 30 )); then col="warn"; finding warn "Certificate for $c expires in $days day(s)" "debnetadmin cert-renew"
    else col="ok"; fi
    rows+="$c"$'\t'"$end"$'\t'"@@$(badge "$col" "$days days")"$'\n'
  done
  if [[ -n "$rows" ]]; then
    rep_table "Certificate" "Expires" "Remaining" <<<"$rows"
  elif [[ -d /etc/letsencrypt/live ]] || (( EUID == 0 )); then
    rep_note "No Let's Encrypt certificates found."
  else
    limited "Certificate files are only readable by root."
  fi
  rep_close
}

# --- summary and page assembly ---------------------------------------------
report_css() {
  cat <<'CSS'
:root{--bg:#f3f5f9;--card:#fff;--text:#1b2430;--muted:#5b6878;--line:#e3e8ef;--accent:#1f4fbf;--accent2:#3b82f6;
--ok:#15803d;--warn:#b45309;--crit:#b91c1c;--info:#1d4ed8;--okbg:#dcfce7;--warnbg:#fef3c7;--critbg:#fee2e2;--infobg:#dbeafe;--code:#f1f4f9;--track:#e5e9f0}
@media (prefers-color-scheme:dark){:root{--bg:#0e141b;--card:#161e29;--text:#e6ebf2;--muted:#9aa7b8;--line:#263241;--accent:#6ea0ff;--accent2:#3b82f6;
--ok:#4ade80;--warn:#fbbf24;--crit:#f87171;--info:#7cb0ff;--okbg:#10301c;--warnbg:#3a2c0b;--critbg:#3d1414;--infobg:#112544;--code:#0f1620;--track:#2a3647}}
*{box-sizing:border-box}html{scroll-behavior:smooth}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
header.hero{background:linear-gradient(135deg,#0f2a6b,#1f4fbf 60%,#3b82f6);color:#fff;padding:34px 16px 28px}
.wrap{max-width:1100px;margin:0 auto;padding:0 16px}header.hero .wrap{padding:0}
.hero h1{margin:0 0 4px;font-size:28px;letter-spacing:-.01em}.hero p{margin:0;opacity:.85}
.hero .meta{display:flex;flex-wrap:wrap;gap:8px 22px;margin-top:16px;font-size:13px;opacity:.92}
nav.toc{position:sticky;top:0;z-index:5;background:var(--card);border-bottom:1px solid var(--line);overflow-x:auto;white-space:nowrap}
nav.toc .wrap{display:flex;gap:2px;padding:6px 16px}
nav.toc a{color:var(--muted);text-decoration:none;padding:6px 12px;border-radius:999px;font-size:13px}
nav.toc a:hover{background:var(--code);color:var(--text)}
main{padding:22px 0 40px}
section,.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:20px 22px;margin:0 0 18px}
h2{margin:0 0 14px;font-size:20px;padding-bottom:10px;border-bottom:1px solid var(--line)}
h3{margin:20px 0 8px;font-size:15px;color:var(--accent)}
.muted{color:var(--muted);font-size:13px}code{background:var(--code);padding:1px 6px;border-radius:5px;font-size:13px}
.summary{display:grid;grid-template-columns:200px 1fr;gap:24px;align-items:center}
.ring{--c:var(--ok);width:170px;height:170px;border-radius:50%;margin:auto;display:grid;place-items:center;
background:conic-gradient(var(--c) calc(var(--score)*1%),var(--track) 0)}
.ring.warn{--c:var(--warn)}.ring.crit{--c:var(--crit)}
.ring div{width:130px;height:130px;border-radius:50%;background:var(--card);display:grid;place-items:center;text-align:center}
.ring b{font-size:38px;line-height:1}.ring span{font-size:12px;color:var(--muted);display:block}
.counts{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-top:12px}
.count{border-radius:10px;padding:10px 12px;text-align:center}.count b{display:block;font-size:24px}.count span{font-size:12px}
.count.crit{background:var(--critbg);color:var(--crit)}.count.warn{background:var(--warnbg);color:var(--warn)}
.count.info{background:var(--infobg);color:var(--info)}.count.ok{background:var(--okbg);color:var(--ok)}
.tablewrap{overflow-x:auto;margin:6px 0}
table{border-collapse:collapse;width:100%;font-size:14px}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}
thead th{background:var(--code);font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}
tbody tr:nth-child(even){background:color-mix(in srgb,var(--code) 55%,transparent)}
table.kv th{width:260px;background:none;text-transform:none;letter-spacing:0;font-size:14px;color:var(--muted);font-weight:600}
pre{background:var(--code);border:1px solid var(--line);border-radius:10px;padding:12px 14px;overflow:auto;max-height:380px;font:12.5px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;margin:6px 0}
.badge{display:inline-block;padding:1px 9px;border-radius:999px;font-size:12px;font-weight:600;white-space:nowrap}
.badge.ok{background:var(--okbg);color:var(--ok)}.badge.warn{background:var(--warnbg);color:var(--warn)}
.badge.crit{background:var(--critbg);color:var(--crit)}.badge.info{background:var(--infobg);color:var(--info)}
.bar{display:inline-block;width:110px;height:9px;background:var(--track);border-radius:9px;overflow:hidden;vertical-align:middle}
.bar i{display:block;height:100%;border-radius:9px}.bar i.ok{background:var(--ok)}.bar i.warn{background:var(--warn)}.bar i.crit{background:var(--crit)}
.notice{border-left:4px solid var(--warn);background:var(--warnbg);padding:10px 14px;border-radius:8px;margin:12px 0;font-size:13px}
footer{color:var(--muted);font-size:12px;text-align:center;padding:10px 16px 40px}
@media (max-width:720px){.summary{grid-template-columns:1fr}.counts{grid-template-columns:repeat(2,1fr)}table.kv th{width:42%}.hero h1{font-size:22px}}
@media print{body{background:#fff;color:#000}nav.toc{display:none}header.hero{background:#1f4fbf!important;-webkit-print-color-adjust:exact;print-color-adjust:exact}
section,.card{break-inside:avoid-page;border-color:#ccc}pre{max-height:none;white-space:pre-wrap}*{-webkit-print-color-adjust:exact;print-color-adjust:exact}}
CSS
}

report_summary() {
  local i s crit=0 warn=0 info=0 ok=0 score cls grade status sev
  for s in "${FIND_SEV[@]}"; do
    case "$s" in crit) crit=$((crit + 1)) ;; warn) warn=$((warn + 1)) ;; info) info=$((info + 1)) ;; ok) ok=$((ok + 1)) ;; esac
  done
  score=$(( 100 - crit * 15 - warn * 5 ))
  (( score < 0 )) && score=0
  if   (( score >= 90 )); then grade="A"; cls="ok";   status="Healthy"
  elif (( score >= 80 )); then grade="B"; cls="ok";   status="Good, minor issues"
  elif (( score >= 70 )); then grade="C"; cls="warn"; status="Needs attention"
  elif (( score >= 60 )); then grade="D"; cls="warn"; status="Needs attention soon"
  else grade="F"; cls="crit"; status="Critical issues present"; fi
  (( crit > 0 && score >= 60 )) && { cls="crit"; status="Critical issues present"; }

  printf '<section id="summary"><h2>Executive summary</h2><div class="summary">'
  printf '<div class="ring %s" style="--score:%s"><div><p style="margin:0"><b>%s</b><span>score / grade %s</span></p></div></div>' "$cls" "$score" "$score" "$grade"
  printf '<div><p style="margin:0 0 4px;font-size:18px"><strong>%s</strong></p>' "$(hesc "$status")"
  printf '<p class="muted" style="margin:0">%s checks evaluated. Each critical finding costs 15 points and each warning 5 points.</p>' "${#FIND_SEV[@]}"
  printf '<div class="counts"><div class="count crit"><b>%s</b><span>Critical</span></div><div class="count warn"><b>%s</b><span>Warnings</span></div><div class="count info"><b>%s</b><span>Notices</span></div><div class="count ok"><b>%s</b><span>Passed</span></div></div></div></div>' "$crit" "$warn" "$info" "$ok"
  if (( REPORT_LIMITED )); then
    printf '<div class="notice"><strong>Limited scope.</strong> This report was generated without root privileges, so some checks (firewall rules, password status, SMART, certificates, backups, logs) are incomplete. Run it with <code>sudo</code> for the full picture.</div>'
  fi

  printf '<h3>Findings and recommended actions</h3><div class="tablewrap"><table><thead><tr><th>Severity</th><th>Finding</th><th>Recommended action</th></tr></thead><tbody>'
  for sev in crit warn info ok; do
    for i in "${!FIND_SEV[@]}"; do
      [[ "${FIND_SEV[$i]}" == "$sev" ]] || continue
      [[ "$sev" == ok ]] && continue
      printf '<tr><td>%s</td><td>%s</td><td>%s</td></tr>' \
        "$(badge "$sev" "$( [[ $sev == crit ]] && echo Critical || { [[ $sev == warn ]] && echo Warning || echo Notice; } )")" \
        "$(hesc "${FIND_MSG[$i]}")" \
        "$( [[ -n "${FIND_FIX[$i]}" ]] && printf '<code>%s</code>' "$(hesc "${FIND_FIX[$i]}")" || printf '&ndash;' )"
    done
  done
  if (( crit + warn + info == 0 )); then printf '<tr><td colspan="3">No issues found.</td></tr>'; fi
  printf '</tbody></table></div>'

  printf '<h3>Checks passed</h3><ul style="margin:6px 0;padding-left:20px">'
  for i in "${!FIND_SEV[@]}"; do
    [[ "${FIND_SEV[$i]}" == ok ]] && printf '<li>%s</li>' "$(hesc "${FIND_MSG[$i]}")"
  done
  printf '</ul></section>'
  REPORT_SCORE="$score"; REPORT_GRADE="$grade"; REPORT_STATUS="$status"
}

report_assemble() {
  local file="$1" title="$2" author="$3" host addrs
  host="$(hostname -f 2>/dev/null || hostname)"
  addrs="$(ip -4 -br addr 2>/dev/null | awk '$1 != "lo" && $3 != "" {split($3, a, "/"); printf "%s ", a[1]}')"
  {
    printf '<!DOCTYPE html>\n<html lang="en"><head><meta charset="utf-8">'
    printf '<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow">'
    printf '<meta name="generator" content="DebNetAdmin %s"><title>%s - %s</title><style>\n' "$DNA_VERSION" "$(hesc "$title")" "$(hesc "$host")"
    report_css
    printf '</style></head><body>\n'
    printf '<header class="hero"><div class="wrap"><h1>%s</h1><p>%s</p><div class="meta">' "$(hesc "$title")" "$(hesc "$host")"
    printf '<span>Generated: %s</span><span>Prepared by: %s</span><span>Address: %s</span><span>Privileges: %s</span></div></div></header>\n' \
      "$(date '+%F %T %Z')" "$(hesc "$author")" "$(hesc "${addrs:-n/a}")" "$( ((EUID == 0)) && echo root || echo "unprivileged ($(id -un))" )"
    printf '<nav class="toc"><div class="wrap">'
    local pair
    for pair in summary:Summary system:System hardware:Resources storage:Storage network:Network services:Services \
                security:Security packages:Updates users:Users scheduled:Scheduled logs:Logs processes:Processes backups:Backups; do
      printf '<a href="#%s">%s</a>' "${pair%%:*}" "${pair#*:}"
    done
    printf '</div></nav><main><div class="wrap">\n'
    report_summary
    cat "$REPORT_BODY"
    printf '</div></main><footer>Generated by DebNetAdmin %s. This document describes the configuration of %s at the time shown and may contain sensitive information: store and share it accordingly.</footer></body></html>\n' \
      "$DNA_VERSION" "$(hesc "$host")"
  } >"$file"
}

cmd_report() {
  local outfile="" title="Server Health and Security Report" author="" mail_to="" quiet=0 host dir old old_umask
  REPORT_SCORE=0 REPORT_GRADE="" REPORT_STATUS=""
  while (( $# )); do
    case "$1" in
      -o|--output) shift; outfile="${1:-}"; [[ -n "$outfile" ]] || die "--output needs a file name" ;;
      --title)     shift; title="${1:-}";   [[ -n "$title" ]] || die "--title needs a value" ;;
      --author)    shift; author="${1:-}" ;;
      --mail)      shift; mail_to="${1:-}"; [[ "$mail_to" =~ $RE_EMAIL ]] || die "Invalid e-mail address '$mail_to'" ;;
      --quiet)     quiet=1 ;;
      *) die "Unknown option for report: $1" ;;
    esac
    shift
  done
  author="${author:-$(id -un)@$(hostname)}"
  host="$(hostname -s 2>/dev/null || hostname)"
  if [[ -z "$outfile" ]]; then
    dir="$(report_default_dir)"
    outfile="$dir/debnetadmin-report-${host}-$(date +%Y%m%d-%H%M).html"
  fi
  (( EUID == 0 )) || REPORT_LIMITED=1
  if (( DRY_RUN )); then
    info "[dry-run] would write the report to $outfile"
    return 0
  fi
  mkdir -p "$(dirname "$outfile")"
  REPORT_BODY="$(mktemp)"
  trap 'rm -f "$REPORT_BODY"' EXIT
  FIND_SEV=(); FIND_MSG=(); FIND_FIX=()
  REPORT_LIMITED=0
  (( EUID == 0 )) || REPORT_LIMITED=1

  set +e
  trap - ERR
  trap 'rm -f "$REPORT_BODY"' EXIT
  (( quiet )) || info "Collecting data (this can take up to a minute)..."
  rep_system; rep_hardware; rep_storage; rep_network; rep_services; rep_security
  rep_packages; rep_users; rep_scheduled; rep_logs; rep_processes; rep_backups_certs
  old_umask="$(umask)"; umask 077
  report_assemble "$outfile" "$title" "$author"
  umask "$old_umask"
  set -e
  chmod 600 "$outfile" 2>/dev/null || true
  ok "Report written to $outfile (score ${REPORT_SCORE}/100, grade ${REPORT_GRADE}: ${REPORT_STATUS})"

  if [[ -n "$mail_to" ]]; then
    if have sendmail; then
      { printf 'To: %s\nSubject: [DebNetAdmin] %s - score %s/100 (%s)\nMIME-Version: 1.0\nContent-Type: text/html; charset=UTF-8\n\n' \
          "$mail_to" "$host" "$REPORT_SCORE" "$REPORT_GRADE"
        cat "$outfile"; } | sendmail -t && ok "Report e-mailed to $mail_to"
    else
      warn "No 'sendmail' found; install and configure postfix to e-mail reports (debnetadmin install postfix)."
    fi
  fi
  # Retention for the default report directory
  if [[ "$outfile" == "$(report_default_dir)"/debnetadmin-report-* ]]; then
    while IFS= read -r old; do
      [[ -n "$old" ]] && rm -f -- "$old"
    done < <(ls -1t "$(report_default_dir)"/debnetadmin-report-*.html 2>/dev/null | tail -n +"$((REPORT_KEEP + 1))")
  fi
  return 0
}

cmd_report_list() {
  local dir
  dir="$(report_default_dir)"
  [[ -d "$dir" ]] || { info "No reports yet in $dir"; return 0; }
  ls -lht "$dir"/debnetadmin-report-*.html 2>/dev/null || info "No reports yet in $dir"
}

cmd_report_schedule() {
  require_root
  local when="weekly" mail_to="" cron_expr line
  while (( $# )); do
    case "$1" in
      --daily|--weekly|--monthly) when="${1#--}" ;;
      --mail)   shift; mail_to="${1:-}"; [[ "$mail_to" =~ $RE_EMAIL ]] || die "Invalid e-mail address '$mail_to'" ;;
      --remove) run rm -f "$CRON_REPORT"; ok "Scheduled report removed"; return 0 ;;
      --show)   [[ -f "$CRON_REPORT" ]] && cat "$CRON_REPORT" || info "No scheduled report"; return 0 ;;
      *) die "Unknown option for report-schedule: $1" ;;
    esac
    shift
  done
  case "$when" in
    daily)   cron_expr="30 6 * * *" ;;
    weekly)  cron_expr="30 6 * * 1" ;;
    monthly) cron_expr="30 6 1 * *" ;;
  esac
  line="$cron_expr root $SCRIPT_PATH report --quiet${mail_to:+ --mail $mail_to} >/dev/null 2>&1"
  if [[ -n "${DEBNETADMIN_REPORT_DIR:-}" ]]; then
    [[ "$DEBNETADMIN_REPORT_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "DEBNETADMIN_REPORT_DIR may only contain letters, digits and . _ / -"
  fi
  {
    printf '# Managed by DebNetAdmin\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
    [[ -n "${DEBNETADMIN_REPORT_DIR:-}" ]] && printf 'DEBNETADMIN_REPORT_DIR=%s\n' "$DEBNETADMIN_REPORT_DIR"
    printf '%s\n' "$line"
  } | write_file "$CRON_REPORT"
  (( DRY_RUN )) || chmod 644 "$CRON_REPORT"
  ok "Report scheduled ($when) via $CRON_REPORT; reports are stored in $(report_default_dir) (keeping the last $REPORT_KEEP)"
}

# ---------------------------------------------------------------------------
# Sysadmin toolbox: system configuration
# ---------------------------------------------------------------------------
readonly RE_DOMAIN='^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'
readonly SYSCTL_DROPIN="/etc/sysctl.d/99-debnetadmin.conf"

cmd_hostname_set() {
  require_root
  local new="${1:-}"
  [[ "$new" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
    || die "Usage: hostname-set <name>  (lowercase letters, digits and '-', max 63 characters)"
  info "Changing the host name from '$(hostname)' to '$new'"
  backup_file /etc/hosts
  run hostnamectl set-hostname "$new"
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
    run sed -i -E "s/^(127\.0\.1\.1[[:space:]]+).*/\1${new}/" /etc/hosts
  elif (( DRY_RUN )); then
    info "[dry-run] would add '127.0.1.1 $new' to /etc/hosts"
  else
    printf '127.0.1.1\t%s\n' "$new" >>/etc/hosts
  fi
  ok "Host name set to $new (open sessions keep the old name until they reconnect)"
}

cmd_timezone_set() {
  require_root
  local tz="${1:-}"
  [[ "$tz" =~ ^[A-Za-z0-9_+/-]+$ && -f "/usr/share/zoneinfo/$tz" ]] \
    || die "Usage: timezone-set <Area/City>  (for example Europe/Madrid; list: timedatectl list-timezones)"
  run timedatectl set-timezone "$tz"
  ok "Time zone set to $tz"
}

cmd_time_sync() {
  section "Time synchronisation"
  timedatectl 2>/dev/null || date
  if have chronyc; then
    printf '\n'
    chronyc tracking 2>/dev/null || true
    chronyc sources 2>/dev/null || true
  fi
  if [[ "${1:-}" == "--enable" ]]; then
    require_root
    pkg_install chrony
    run systemctl enable --now chrony
    ok "Chrony is installed and running"
  elif ! have chronyc; then
    info "Tip: '$PROG time-sync --enable' installs Chrony (NTP client/server)."
  fi
}

cmd_swap_add() {
  require_root
  local size="${1:-}" file="/swapfile" mb free_mb
  [[ "$size" =~ ^[0-9]+[MG]$ ]] || die "Usage: swap-add <size>  (for example 2G or 512M)"
  [[ ! -e "$file" ]] || die "$file already exists. Remove it first: swapoff $file && rm $file"
  mb="${size%[MG]}"
  [[ "$size" == *G ]] && mb=$((mb * 1024))
  free_mb="$(df -Pm / | awk 'NR == 2 {print $4}')"
  (( free_mb > mb + 512 )) || die "Not enough free space on / (${free_mb} MB free, ${mb} MB requested)."
  info "Creating a ${size} swap file at $file"
  run fallocate -l "$size" "$file"
  run chmod 600 "$file"
  run mkswap "$file"
  run swapon "$file"
  if ! grep -qs "^$file " /etc/fstab; then
    backup_file /etc/fstab
    if (( DRY_RUN )); then info "[dry-run] would add $file to /etc/fstab"
    else printf '%s none swap sw 0 0\n' "$file" >>/etc/fstab; fi
  fi
  ok "Swap enabled ($size). Persistent across reboots via /etc/fstab."
}

cmd_sysctl_harden() {
  require_root
  warn "Applies network and kernel hardening. Strict reverse-path filtering (rp_filter=1)"
  warn "can break asymmetric routing on multi-homed servers and routers."
  confirm "Apply the hardening profile?" || { info "Aborted"; return 0; }
  backup_file "$SYSCTL_DROPIN"
  write_file "$SYSCTL_DROPIN" <<'EOF'
# Managed by DebNetAdmin
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 1
kernel.randomize_va_space = 2
kernel.kptr_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
  run sysctl --system
  ok "Hardening profile applied ($SYSCTL_DROPIN). To revert, delete that file and run 'sysctl --system'."
}

# ---------------------------------------------------------------------------
# Sysadmin toolbox: users and access
# ---------------------------------------------------------------------------
user_must_exist() {
  valid_username "${1:-}"
  id "$1" >/dev/null 2>&1 || die "User '$1' does not exist."
}

cmd_user_list() {
  local name uid shell sudo st last
  printf '%s%-18s %-6s %-5s %-12s %-26s %s%s\n' "$C_BOLD" USER UID SUDO STATE "LAST LOGIN" SHELL "$C_RESET"
  while IFS=: read -r name _ uid _ _ _ shell; do
    (( uid == 0 || uid >= 1000 )) || continue
    [[ "$name" == nobody ]] && continue
    sudo="no"
    [[ " $(id -nG "$name" 2>/dev/null) " == *" sudo "* ]] && sudo="yes"
    st="n/a"
    if (( EUID == 0 )); then
      case "$(passwd -S "$name" 2>/dev/null | awk '{print $2}')" in
        P) st="active" ;; L) st="locked" ;; NP) st="NO-PASSWORD" ;; *) st="unknown" ;;
      esac
    fi
    last="$(lastlog -u "$name" 2>/dev/null | sed -n '2s/^[^ ]* *//p' | cut -c1-26)"
    [[ "$last" == *Never* ]] && last="never"
    printf '%-18s %-6s %-5s %-12s %-26s %s\n' "$name" "$uid" "$sudo" "$st" "${last:-n/a}" "$shell"
  done </etc/passwd
}

cmd_user_lock() {
  require_root
  local user="${1:-}"
  user_must_exist "$user"
  [[ "$user" != root ]] || die "Refusing to lock root."
  local uid; uid="$(id -u "$user")"
  (( uid >= 1000 && uid < 60000 )) || die "Refusing to lock system account '$user' (UID $uid)."
  [[ "$user" != "${SUDO_USER:-}" ]] || die "Refusing to lock the account you are using (${SUDO_USER})."
  run usermod -L -e 1 "$user"
  ok "User $user locked (password disabled and account expired: SSH keys stop working too)"
}

cmd_user_unlock() {
  require_root
  local user="${1:-}"
  user_must_exist "$user"
  run usermod -e "" "$user"
  if ! run usermod -U "$user" 2>/dev/null; then
    info "Password left locked: the account has no password (SSH key login works)."
  fi
  ok "User $user unlocked"
}

cmd_user_expire() {
  require_root
  local user="${1:-}"
  user_must_exist "$user"
  run chage -d 0 "$user"
  ok "$user must choose a new password at the next login"
}

cmd_user_del() {
  require_root
  local user="${1:-}" purge=0 force=0 archive uid
  shift || true
  while (( $# )); do
    case "$1" in
      --purge-home) purge=1 ;;
      --force)      force=1 ;;
      *) die "Unknown option for user-del: $1" ;;
    esac
    shift
  done
  user_must_exist "$user"
  uid="$(id -u "$user")"
  (( uid >= 1000 )) || die "Refusing to delete system account '$user' (UID $uid)."
  [[ "$user" != "${SUDO_USER:-}" ]] || die "Refusing to delete the account you are using."
  if pgrep -u "$user" >/dev/null 2>&1; then
    (( force )) || die "$user has running processes. Use --force to terminate them."
    run pkill -KILL -u "$user"
  fi
  if (( ASSUME_YES == 0 )); then
    if (( purge )); then warn "This permanently deletes user '$user' and its home directory."
    else warn "This permanently deletes user '$user'."; fi
    local ans
    read -r -p "Type the user name to confirm: " ans
    [[ "$ans" == "$user" ]] || { info "Aborted"; return 0; }
  fi
  if (( purge )); then
    archive="$BACKUP_DIR/home-${user}-$(date +%F_%H%M%S).tar.gz"
    run mkdir -p "$BACKUP_DIR"
    run chmod 700 "$BACKUP_DIR"
    info "Archiving /home/$user to $archive before deletion"
    run tar -czf "$archive" -C /home "$user"
    run userdel -r "$user"
  else
    run userdel "$user"
  fi
  ok "User $user deleted"
}

# ---------------------------------------------------------------------------
# Sysadmin toolbox: storage
# ---------------------------------------------------------------------------
cmd_disk_usage() {
  local path="${1:-/}"
  [[ -d "$path" ]] || die "Directory not found: $path"
  section "Largest directories under $path"
  du -xh --max-depth=1 "$path" 2>/dev/null | sort -rh | head -16
}

cmd_big_files() {
  local path="${1:-/}" size="${2:-100M}"
  [[ -d "$path" ]] || die "Directory not found: $path"
  [[ "$size" =~ ^[0-9]+[kMG]$ ]] || die "Size must look like 100M or 1G"
  section "Files larger than $size under $path"
  find "$path" -xdev -type f -size "+$size" -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn | head -20 \
    | awk -F'\t' '{ s = $1; u = "B"; if (s > 1024) { s /= 1024; u = "KiB" } if (s > 1024) { s /= 1024; u = "MiB" } if (s > 1024) { s /= 1024; u = "GiB" } printf "%9.1f %-4s %s\n", s, u, $2 }'
}

cmd_install_smart() {
  require_root
  pkg_install smartmontools
  run systemctl enable --now smartmontools
  ok "smartmontools installed. Run '$PROG smart' to check disk health."
}

cmd_smart() {
  require_root
  have smartctl || die "smartmontools is not installed. Run: $PROG install-smart"
  local disk
  while read -r disk; do
    [[ -n "$disk" ]] || continue
    section "SMART: /dev/$disk"
    smartctl -H -A "/dev/$disk" 2>/dev/null | grep -E 'overall-health|Health Status|Reallocated|Pending|Uncorrectable|Temperature|Power_On_Hours|Wear' || \
      info "No SMART data (virtual disk or unsupported controller)"
  done < <(lsblk -dno NAME,TYPE | awk '$2 == "disk" {print $1}')
}

# ---------------------------------------------------------------------------
# Sysadmin toolbox: packages
# ---------------------------------------------------------------------------
valid_pkgs() {
  local p
  (( $# )) || die "Give at least one package name."
  for p in "$@"; do
    [[ "$p" =~ ^[a-z0-9][a-z0-9+.:-]*$ ]] || die "Invalid package name '$p'."
  done
}

cmd_pkg() {
  local action="${1:-}"
  shift || true
  case "$action" in
    search)     (( $# )) || die "Usage: pkg search <term>"; apt-cache search "$@" | head -40 ;;
    info)       valid_pkgs "$@"; apt-cache policy "$1" ;;
    install)    require_root; valid_pkgs "$@"; pkg_install "$@" ;;
    remove)     require_root; valid_pkgs "$@"; run apt-get remove -y "$@" ;;
    purge)      require_root; valid_pkgs "$@"; run apt-get purge -y "$@" ;;
    hold)       require_root; valid_pkgs "$@"; run apt-mark hold "$@" ;;
    unhold)     require_root; valid_pkgs "$@"; run apt-mark unhold "$@" ;;
    held)       apt-mark showhold ;;
    upgradable) apt list --upgradable 2>/dev/null | tail -n +2 ;;
    history)    tail -n 40 /var/log/apt/history.log 2>/dev/null || die "No APT history available." ;;
    clean)
      require_root
      run apt-get autoremove -y
      run apt-get autoclean
      if (( DRY_RUN )); then
        info "[dry-run] would purge packages with leftover configuration (state 'rc')"
      else
        dpkg -l | awk '/^rc/ {print $2}' | xargs -r apt-get purge -y
      fi
      run apt-get clean
      ok "Package cache and unused packages cleaned" ;;
    reboot-check)
      if [[ -f /var/run/reboot-required ]]; then
        warn "A reboot is required"; cat /var/run/reboot-required.pkgs 2>/dev/null || true
      else ok "No reboot required"; fi ;;
    *) die "Usage: pkg <search|info|install|remove|purge|hold|unhold|held|upgradable|history|clean|reboot-check> [names]" ;;
  esac
}

# ---------------------------------------------------------------------------
# Sysadmin toolbox: logs, processes and scheduled tasks
# ---------------------------------------------------------------------------
cmd_logs_errors() {
  local hours="${1:-24}"
  [[ "$hours" =~ $RE_NUMBER ]] || die "Hours must be a number"
  section "Error-level log entries (last ${hours} h)"
  journalctl -p err --since "${hours} hours ago" --no-pager -q | tail -n 200
}

cmd_auth_failures() {
  local hours="${1:-24}" lines count
  [[ "$hours" =~ $RE_NUMBER ]] || die "Hours must be a number"
  lines="$(journalctl --since "${hours} hours ago" --no-pager -q -t sshd -t sshd-session 2>/dev/null || true)"
  [[ -n "$lines" ]] || lines="$(grep -h sshd /var/log/auth.log 2>/dev/null || true)"
  count="$(grep -cE 'Failed password|Invalid user' <<<"$lines" || true)"
  section "Failed SSH logins (last ${hours} h): ${count:-0}"
  if (( ${count:-0} > 0 )); then
    printf '\n%sTop source addresses%s\n' "$C_BOLD" "$C_RESET"
    { grep -E 'Failed password|Invalid user' <<<"$lines" | grep -oE 'from [0-9a-fA-F:.]+' \
        | awk '{print $2}' | sort | uniq -c | sort -rn | head -10; } || true
    printf '\n%sMost targeted user names%s\n' "$C_BOLD" "$C_RESET"
    { grep -oE 'Invalid user [^ ]+' <<<"$lines" | awk '{print $3}' | sort | uniq -c | sort -rn | head -10; } || true
  fi
}

cmd_procs() {
  local by="${1:-cpu}"
  case "$by" in
    cpu) ps -eo pid,user,%cpu,%mem,etime,comm --sort=-%cpu | head -16 ;;
    mem) ps -eo pid,user,%cpu,%mem,rss,etime,comm --sort=-%mem | head -16 ;;
    *) die "Usage: procs [cpu|mem]" ;;
  esac
}

cmd_cron_list() {
  local u
  section "System crontab"
  grep -vE '^[[:space:]]*(#|$)' /etc/crontab 2>/dev/null || true
  section "/etc/cron.d and periodic jobs"
  ls -1 /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly 2>/dev/null || true
  if (( EUID == 0 )); then
    section "User crontabs"
    for u in $(cut -d: -f1 /etc/passwd); do
      { crontab -l -u "$u" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' | sed "s/^/${u}: /"; } || true
    done
  fi
  section "systemd timers"
  systemctl list-timers --all --no-pager 2>/dev/null || true
}

cmd_journal_vacuum() {
  require_root
  local size="${1:-}"
  [[ "$size" =~ ^[0-9]+[KMG]$ ]] || die "Usage: journal-vacuum <size>  (for example 200M)"
  run journalctl --vacuum-size="$size"
  ok "Journal trimmed to at most $size"
}

# ---------------------------------------------------------------------------
# Sysadmin toolbox: TLS certificates
# ---------------------------------------------------------------------------
cmd_cert_check() {
  local target="${1:-}" host port end days f c
  if [[ -n "$target" ]]; then
    host="${target%%:*}"
    port="443"
    [[ "$target" == *:* ]] && port="${target##*:}"
    [[ "$host" =~ $RE_HOST ]] || die "Invalid host '$host'"
    [[ "$port" =~ $RE_NUMBER ]] || die "Invalid port '$port'"
    section "Certificate presented by $host:$port"
    have openssl || die "openssl is not installed."
    openssl s_client -connect "$host:$port" -servername "$host" </dev/null 2>/dev/null \
      | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null \
      || die "Could not retrieve a certificate from $host:$port"
    end="$(openssl s_client -connect "$host:$port" -servername "$host" </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    if [[ -n "$end" ]]; then
      days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
      if   (( days < 14 )); then err "Expires in $days day(s)"
      elif (( days < 30 )); then warn "Expires in $days day(s)"
      else ok "Valid for another $days day(s)"; fi
    fi
    return 0
  fi
  section "Local Let's Encrypt certificates"
  local found=0
  for f in /etc/letsencrypt/live/*/cert.pem; do
    [[ -r "$f" ]] || continue
    found=1
    c="$(basename "$(dirname "$f")")"
    end="$(openssl x509 -enddate -noout -in "$f" | cut -d= -f2)"
    days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
    printf '%-40s expires %s (%s days)\n' "$c" "$end" "$days"
  done
  (( found )) || info "No readable certificates in /etc/letsencrypt/live (run as root?)"
}

cmd_certbot_issue() {
  require_root
  local domain="${1:-}" email="" mode="nginx" webroot="" staging=0
  local -a flag=() args=()
  [[ "$domain" =~ $RE_DOMAIN ]] || \
    die "Usage: certbot-issue <domain> --email <addr> [--nginx|--apache|--standalone|--webroot <path>] [--staging]"
  shift
  while (( $# )); do
    case "$1" in
      --email)  shift; email="${1:-}" ;;
      --nginx|--apache|--standalone) mode="${1#--}" ;;
      --webroot) mode="webroot"; shift; webroot="${1:-}" ;;
      --staging) staging=1 ;;
      *) die "Unknown option for certbot-issue: $1" ;;
    esac
    shift
  done
  [[ "$email" =~ $RE_EMAIL ]] || die "A valid --email is required (used for expiry notices)."
  [[ "$mode" != webroot || -d "$webroot" ]] || die "Webroot directory not found: '$webroot'"
  getent hosts "$domain" >/dev/null 2>&1 || warn "$domain does not resolve from this server yet; validation will fail until DNS points here."
  case "$mode" in
    nginx)      pkg_install certbot python3-certbot-nginx; flag=(--nginx) ;;
    apache)     pkg_install certbot python3-certbot-apache; flag=(--apache) ;;
    standalone) pkg_install certbot; flag=(--standalone); warn "Standalone mode needs port 80 free: stop the web server first." ;;
    webroot)    pkg_install certbot; flag=(--webroot -w "$webroot") ;;
  esac
  warn "Port 80/tcp must be reachable from the Internet (debnetadmin fw-allow 80/tcp)."
  args=(--non-interactive --agree-tos -m "$email" -d "$domain" "${flag[@]}")
  (( staging )) && args+=(--staging)
  run certbot "${args[@]}"
  ok "Certificate requested for $domain. Renewal is automatic (certbot systemd timer)."
}

cmd_cert_renew() {
  require_root
  have certbot || die "certbot is not installed."
  if [[ "${1:-}" == "--test" ]]; then run certbot renew --dry-run
  else run certbot renew; fi
}

# ---------------------------------------------------------------------------
# Sysadmin toolbox: backups
# ---------------------------------------------------------------------------
prune_backups() {
  local pattern="$1" old
  (( DRY_RUN )) && return 0
  while IFS= read -r old; do
    [[ -n "$old" ]] && rm -f -- "$old"
  done < <(ls -1t "$BACKUP_DIR"/$pattern 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))")
}

cmd_backup_list() {
  require_root
  [[ -d "$BACKUP_DIR" ]] || { info "No backups yet ($BACKUP_DIR does not exist)."; return 0; }
  section "Backups in $BACKUP_DIR"
  ls -lht "$BACKUP_DIR" | tail -n +2 | grep -v '^d' || true
  du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print "Total: " $1}'
}

cmd_backup_verify() {
  require_root
  local f="${1:-}" bad=0
  if [[ -z "$f" ]]; then
    f="$(ls -1t "$BACKUP_DIR"/*.tar.gz "$BACKUP_DIR"/*.sql.gz 2>/dev/null | head -1 || true)"
    [[ -n "$f" ]] || die "No backups found in $BACKUP_DIR"
  fi
  [[ -f "$f" ]] || die "File not found: $f"
  info "Verifying $f"
  if [[ "$f" == *.tar.gz ]]; then tar -tzf "$f" >/dev/null || bad=1
  else gzip -t "$f" || bad=1; fi
  (( bad == 0 )) && ok "Backup is readable and its compression is intact" || die "Backup is CORRUPT: $f"
}

cmd_backup_paths() {
  require_root
  (( $# )) || die "Usage: backup-paths <absolute-path>..."
  local p archive
  for p in "$@"; do
    [[ "$p" == /* && -e "$p" ]] || die "Path must be absolute and exist: $p"
  done
  archive="$BACKUP_DIR/custom-$(hostname -s)-$(date +%F_%H%M%S).tar.gz"
  run mkdir -p "$BACKUP_DIR"
  run chmod 700 "$BACKUP_DIR"
  info "Archiving: $* -> $archive"
  if (( DRY_RUN )); then run tar -czf "$archive" "$@"
  else ( umask 077; tar -czf "$archive" "$@" 2>/dev/null ) || warn "tar reported warnings (some files may be unreadable)"; fi
  prune_backups 'custom-*.tar.gz'
  ok "Backup complete"
}

# dump_to <dest.sql.gz> <command...>: write via a temporary file, never leave partial dumps
dump_to() {
  local dest="$1"
  shift
  if ( umask 077; set -o pipefail; "$@" | gzip >"$dest.part" ); then
    mv "$dest.part" "$dest"
    return 0
  fi
  rm -f "$dest.part"
  return 1
}

cmd_db_backup() {
  require_root
  local stamp dump tried=0 okc=0
  stamp="$(date +%F_%H%M%S)"
  run mkdir -p "$BACKUP_DIR"
  run chmod 700 "$BACKUP_DIR"
  if have mariadb-dump || have mysqldump; then
    dump="$(command -v mariadb-dump || command -v mysqldump)"
    tried=$((tried + 1))
    info "Dumping all MariaDB/MySQL databases"
    if (( DRY_RUN )); then
      info "[dry-run] $dump --all-databases | gzip > $BACKUP_DIR/db-mariadb-$stamp.sql.gz"
      okc=$((okc + 1))
    elif dump_to "$BACKUP_DIR/db-mariadb-$stamp.sql.gz" "$dump" --all-databases --single-transaction --routines --events; then
      prune_backups 'db-mariadb-*.sql.gz'
      okc=$((okc + 1))
    else
      warn "MariaDB/MySQL dump failed (is the server running and root socket authentication enabled?)"
    fi
  fi
  if have pg_dumpall && id postgres >/dev/null 2>&1; then
    tried=$((tried + 1))
    info "Dumping all PostgreSQL databases"
    if (( DRY_RUN )); then
      info "[dry-run] runuser -u postgres -- pg_dumpall | gzip > $BACKUP_DIR/db-postgres-$stamp.sql.gz"
      okc=$((okc + 1))
    elif dump_to "$BACKUP_DIR/db-postgres-$stamp.sql.gz" runuser -u postgres -- pg_dumpall; then
      prune_backups 'db-postgres-*.sql.gz'
      okc=$((okc + 1))
    else
      warn "PostgreSQL dump failed (is the server running?)"
    fi
  fi
  (( tried > 0 )) || die "No MariaDB/MySQL or PostgreSQL client tools found."
  (( okc > 0 )) || die "No database could be dumped."
  ok "Database backup complete in $BACKUP_DIR ($okc of $tried succeeded)"
}

# ---------------------------------------------------------------------------
# Interactive mode: validation patterns and prompt helpers
# ---------------------------------------------------------------------------
readonly RE_PORT='^[0-9]{1,5}(:[0-9]{1,5})?$'
readonly RE_CIDR='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'
readonly RE_HOST='^[A-Za-z0-9]([A-Za-z0-9.:-]*[A-Za-z0-9])?$'
readonly RE_USER='^[a-z_][a-z0-9_-]{0,31}$'
readonly RE_NUMBER='^[0-9]+$'
readonly RE_PUBKEY='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com) [A-Za-z0-9+/=]+( .*)?$'

need_tty() {
  [[ -t 0 && -t 1 ]] || die "Interactive mode needs a terminal. Use a subcommand instead (see '$PROG help')."
}

pause() { read -r -p $'\nPress Enter to continue... ' _ || true; }

clear_screen() { printf '\e[H\e[2J'; }

# ask <prompt> [default] [regex] [error message]  ->  REPLY
ask() {
  local prompt="$1" default="${2:-}" regex="${3:-}" errmsg="${4:-Invalid input.}" ans
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [$default]: " ans || die "Input closed."
      ans="${ans:-$default}"
    else
      read -r -p "$prompt: " ans || die "Input closed."
    fi
    if [[ -z "$regex" || "$ans" =~ $regex ]]; then
      REPLY="$ans"
      return 0
    fi
    warn "$errmsg"
  done
}

# ask_yn <prompt> [y|n]  ->  exit status 0 for yes, 1 for no
ask_yn() {
  local prompt="$1" default="${2:-n}" hint ans
  [[ "$default" == y ]] && hint="Y/n" || hint="y/N"
  while true; do
    read -r -p "$prompt [$hint]: " ans || return 1
    ans="${ans:-$default}"
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
    esac
    warn "Please answer y or n."
  done
}

# menu_choose <title> <option>...  ->  CHOICE (1-based); returns 1 on Back/Quit
# The label of option 0 can be changed with: BACK_LABEL=Quit menu_choose ...
menu_choose() {
  local title="$1" i ans
  shift
  local -a opts=("$@")
  while true; do
    printf '\n%s%s%s\n' "$C_BOLD" "$title" "$C_RESET"
    for i in "${!opts[@]}"; do
      printf '  %s%2d)%s %s\n' "$C_BLUE" "$((i + 1))" "$C_RESET" "${opts[$i]}"
    done
    printf '  %s 0)%s %s\n' "$C_BLUE" "$C_RESET" "${BACK_LABEL:-Back}"
    read -r -p $'\nChoose an option: ' ans || return 1
    if [[ "$ans" == 0 || "${ans,,}" == q ]]; then
      return 1
    fi
    if [[ "$ans" =~ $RE_NUMBER ]] && (( 10#$ans >= 1 && 10#$ans <= ${#opts[@]} )); then
      CHOICE=$((10#$ans))
      return 0
    fi
    warn "Invalid option: '$ans'"
  done
}

# Run an action in a subshell so that a failure or die() returns to the menu.
act() {
  local rc=0
  set +e
  ( set -e; "$@" )
  rc=$?
  set -e
  (( rc == 0 )) || warn "The action ended with errors (exit code $rc)."
  pause
}

status_line() {
  case "$1" in
    ok)  printf '  %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$2" ;;
    bad) printf '  %s✘%s %s\n' "$C_RED" "$C_RESET" "$2" ;;
    *)   printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$2" ;;
  esac
}

valid_cidr() {
  local addr="${1%%/*}" mask="" o
  local -a oct
  [[ "$1" == */* ]] && mask="${1##*/}"
  IFS=. read -r -a oct <<<"$addr"
  for o in "${oct[@]}"; do
    (( 10#$o <= 255 )) || return 1
  done
  [[ -z "$mask" ]] || (( 10#$mask <= 32 ))
}

ask_port() {
  local p
  while true; do
    ask "$1" "${2:-}" "$RE_PORT" "Enter a port (1-65535) or a range such as 8000:8100."
    p="$REPLY"
    if [[ "$p" != *:* ]] && (( 10#$p < 1 || 10#$p > 65535 )); then
      warn "Port out of range."
      continue
    fi
    REPLY="$p"
    return 0
  done
}

# ask_source -> SOURCE ("" means any address); returns 1 if the user goes back
ask_source() {
  SOURCE=""
  menu_choose "Who may connect?" \
    "Anyone (any source address)" \
    "Only a specific network or host (CIDR)" || return 1
  if (( CHOICE == 2 )); then
    while true; do
      ask "Network or host (e.g. 192.168.1.0/24 or 10.0.0.5)" "" "$RE_CIDR" \
        "Enter an IPv4 address or CIDR."
      if valid_cidr "$REPLY"; then
        SOURCE="$REPLY"
        break
      fi
      warn "Octets must be 0-255 and the prefix 0-32."
    done
  fi
}

service_state() {
  local svc="$1" pkg unit state
  pkg="${SERVICE_PKGS[$svc]%% *}"
  unit="${SERVICE_UNITS[$svc]%% *}"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    printf 'not installed'
    return 0
  fi
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  printf '%s' "${state:-unknown}"
}

state_colour() {
  case "$1" in
    active)          printf '%s' "$C_GREEN" ;;
    failed)          printf '%s' "$C_RED" ;;
    "not installed") printf '%s' "$C_YELLOW" ;;
  esac
}

# pick_service <title>  ->  SELECTED
pick_service() {
  local k
  local -a keys=() labels=()
  mapfile -t keys < <(printf '%s\n' "${!SERVICE_PKGS[@]}" | sort)
  for k in "${keys[@]}"; do
    labels+=("$(printf '%-10s %s' "$k" "$(service_state "$k")")")
  done
  menu_choose "$1" "${labels[@]}" || return 1
  SELECTED="${keys[$((CHOICE - 1))]}"
}

ensure_ufw() {
  have ufw && return 0
  warn "UFW (the firewall) is not installed."
  ask_yn "Install and enable it now?" y || return 1
  cmd_fw_setup
  have ufw || (( DRY_RUN ))
}

# ---------------------------------------------------------------------------
# Interactive mode: dashboard and wizards
# ---------------------------------------------------------------------------
banner() {
  printf '%s╔══════════════════════════════════════════════╗%s\n' "$C_BOLD" "$C_RESET"
  printf '%s║  DebNetAdmin v%-8s Debian server toolkit ║%s\n' "$C_BOLD" "$DNA_VERSION" "$C_RESET"
  printf '%s╚══════════════════════════════════════════════╝%s\n' "$C_BOLD" "$C_RESET"
  if (( DRY_RUN )); then
    printf '%s  DRY-RUN MODE: nothing will be changed%s\n' "$C_YELLOW" "$C_RESET"
  fi
}

dashboard() {
  local host addrs load disk failed fw sshd_state
  host="$(hostname -f 2>/dev/null || hostname)"
  addrs="$(ip -4 -br addr 2>/dev/null \
    | awk '$1 != "lo" && $3 != "" {split($3, a, "/"); printf "%s=%s ", $1, a[1]}' || true)"
  load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || true)"
  disk="$(df -P / 2>/dev/null | awk 'NR == 2 {print $5}' || true)"
  failed="$(systemctl --failed --no-legend 2>/dev/null | wc -l || true)"
  fw="$(systemctl is-active ufw 2>/dev/null || true)"
  sshd_state="$(systemctl is-active ssh 2>/dev/null || true)"
  printf '\n  Host     : %s\n' "$host"
  printf '  Address  : %s\n' "${addrs:-none}"
  printf '  Load     : %s    Disk /: %s\n' "${load:-n/a}" "${disk:-n/a}"
  printf '  Failed units: %s    Firewall: %s    SSH: %s\n' \
    "${failed:-0}" "${fw:-unknown}" "${sshd_state:-unknown}"
  (( EUID == 0 )) || printf '  %sNot running as root: read-only features only%s\n' "$C_YELLOW" "$C_RESET"
}

maybe_elevate() {
  (( EUID == 0 || DRY_RUN )) && return 0
  have sudo || return 0
  if ask_yn "You are not root. Restart this menu with sudo for full access?" y; then
    exec sudo -E "$BASH" "$0" menu
  fi
}

wiz_overview() {
  local k pkg unit state en col
  section "Service overview"
  printf '%-10s %-14s %-10s %s\n' "SERVICE" "STATE" "ENABLED" "PORTS"
  for k in $(printf '%s\n' "${!SERVICE_PKGS[@]}" | sort); do
    state="$(service_state "$k")"
    col="$(state_colour "$state")"
    unit="${SERVICE_UNITS[$k]%% *}"
    pkg="${SERVICE_PKGS[$k]%% *}"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      en="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
      en="${en:-n/a}"
    else
      en="-"
    fi
    printf '%-10s %s%-14s%s %-10s %s\n' "$k" "$col" "$state" "$C_RESET" "$en" "${SERVICE_PORTS[$k]}"
  done
}

wiz_open_ports() {
  local svc="$1" rule
  require_root
  ensure_ufw || { info "Skipped firewall changes"; return 0; }
  ask_source || { info "Cancelled"; return 0; }
  if [[ -z "$SOURCE" ]]; then
    cmd_fw_preset "$svc"
  else
    for rule in ${SERVICE_PORTS[$svc]}; do
      cmd_fw_allow "$rule" "$SOURCE"
    done
  fi
}

wiz_install() {
  local svc
  require_root
  pick_service "Which service do you want to install?" || return 0
  svc="$SELECTED"
  section "Install $svc"
  printf 'Packages : %s\n' "${SERVICE_PKGS[$svc]}"
  printf 'Units    : %s\n' "${SERVICE_UNITS[$svc]}"
  printf 'Ports    : %s\n' "${SERVICE_PORTS[$svc]}"
  ask_yn "Proceed with the installation?" y || { info "Cancelled"; return 0; }
  cmd_install "$svc"
  if ask_yn "Open the firewall ports for $svc now?" n; then
    wiz_open_ports "$svc"
  fi
  if [[ -n "${CONFIG_TESTS[$svc]+x}" ]] && ask_yn "Validate its configuration now?" y; then
    check_one_config "$svc" || true
  fi
}

wiz_manage() {
  local svc
  pick_service "Which service do you want to manage?" || return 0
  svc="$SELECTED"
  while true; do
    menu_choose "Manage '$svc' (state: $(service_state "$svc"))" \
      "Show status" "Start" "Stop" "Restart" "Reload configuration" \
      "Enable at boot" "Disable at boot" "View recent logs" \
      "Validate configuration" || return 0
    case "$CHOICE" in
      1) act cmd_svc status "$svc" ;;
      2) act cmd_svc start "$svc" ;;
      3) if ask_yn "Stop $svc? Active clients will be disconnected." n; then act cmd_svc stop "$svc"; fi ;;
      4) if ask_yn "Restart $svc?" y; then act cmd_svc restart "$svc"; fi ;;
      5) act cmd_svc reload "$svc" ;;
      6) act cmd_svc enable "$svc" ;;
      7) act cmd_svc disable "$svc" ;;
      8) ask "How many lines?" 50 "$RE_NUMBER" "Enter a number."
         act cmd_logs "$svc" "$REPLY" ;;
      9) if [[ -n "${CONFIG_TESTS[$svc]+x}" ]]; then
           act check_one_config "$svc"
         else
           info "No automatic configuration test is available for $svc."
           pause
         fi ;;
    esac
  done
}

menu_services() {
  while true; do
    menu_choose "Network services" \
      "Overview of all services" \
      "Install a service (guided)" \
      "Manage a service (start, stop, logs, ...)" \
      "Validate all configurations" || return 0
    case "$CHOICE" in
      1) act wiz_overview ;;
      2) act wiz_install ;;
      3) wiz_manage ;;
      4) act cmd_check_config all ;;
    esac
  done
}

net_ping() {
  ask "Host to ping" "1.1.1.1" "$RE_HOST" "Enter a valid host name or IP address."
  ping -c 4 -W 2 "$REPLY"
}

net_dns() {
  local host
  ask "Name to resolve" "debian.org" "$RE_HOST" "Enter a valid host name."
  host="$REPLY"
  if have dig; then
    dig +short "$host" A "$host" AAAA
  else
    getent ahosts "$host" || warn "Could not resolve $host"
  fi
}

net_port() {
  local host port
  ask "Host" "" "$RE_HOST" "Enter a valid host name or IP address."
  host="$REPLY"
  ask_port "TCP port" 443
  port="$REPLY"
  if [[ "$port" == *:* ]]; then
    die "Enter a single port, not a range."
  fi
  if timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>/dev/null; then
    ok "$host:$port is OPEN"
  else
    warn "$host:$port is closed, filtered or unreachable"
  fi
}

net_trace() {
  local tool=""
  if have traceroute; then tool="traceroute"
  elif have tracepath; then tool="tracepath"
  else
    die "Neither traceroute nor tracepath is installed (apt install traceroute)."
  fi
  ask "Host to trace" "debian.org" "$RE_HOST" "Enter a valid host name or IP address."
  "$tool" "$REPLY"
}

menu_network() {
  while true; do
    menu_choose "Network tools" \
      "Full network diagnostics" \
      "Listening sockets" \
      "Ping a host" \
      "DNS lookup" \
      "Check whether a TCP port is open" \
      "Trace the route to a host" || return 0
    case "$CHOICE" in
      1) act cmd_netdiag ;;
      2) act cmd_listening ;;
      3) act net_ping ;;
      4) act net_dns ;;
      5) act net_port ;;
      6) act net_trace ;;
    esac
  done
}

wiz_fw_allow() {
  local port proto src rule
  require_root
  ensure_ufw || { info "Cancelled"; return 0; }
  ask_port "Port or range to allow" ""
  port="$REPLY"
  menu_choose "Protocol" "TCP" "UDP" "Both TCP and UDP" || return 0
  case "$CHOICE" in
    1) proto="/tcp" ;;
    2) proto="/udp" ;;
    3) proto="" ;;
  esac
  if [[ "$port" == *:* && -z "$proto" ]]; then
    warn "Port ranges need an explicit protocol (TCP or UDP)."
    return 1
  fi
  ask_source || return 0
  src="$SOURCE"
  rule="${port}${proto}"
  section "Summary"
  printf 'Allow %s from %s\n' "$rule" "${src:-anywhere}"
  ask_yn "Apply this rule?" y || { info "Cancelled"; return 0; }
  cmd_fw_allow "$rule" "$src"
}

wiz_fw_delete() {
  local num
  require_root
  have ufw || die "UFW is not installed."
  ufw status numbered
  ask "Rule number to delete (0 to cancel)" "0" "$RE_NUMBER" "Enter a number."
  num="$REPLY"
  [[ "$num" == 0 ]] && { info "Cancelled"; return 0; }
  warn "Deleting rule #$num"
  ask_yn "Are you sure?" n || { info "Cancelled"; return 0; }
  run ufw --force delete "$num"
  ok "Rule #$num deleted"
}

menu_firewall() {
  while true; do
    menu_choose "Firewall (UFW)" \
      "Show firewall status and rules" \
      "Set up the firewall (guided)" \
      "Allow a port (guided)" \
      "Open the standard ports of a service" \
      "Delete a rule" || return 0
    case "$CHOICE" in
      1) act cmd_fw_status ;;
      2) act cmd_fw_setup ;;
      3) act wiz_fw_allow ;;
      4) if pick_service "Open ports for which service?"; then act wiz_open_ports "$SELECTED"; fi ;;
      5) act wiz_fw_delete ;;
    esac
  done
}

users_with_keys() {
  local f u n=0
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -s "$f" ]] || continue
    u="${f#/home/}"; u="${u%%/*}"
    [[ "$f" == /root/* ]] && u="root"
    [[ "$u" == root ]] && continue
    printf '%s\n' "$u"
    n=$((n + 1))
  done
  return 0
}

wiz_ssh_harden() {
  local -a keyed=()
  local port_args=() newport=""
  require_root
  section "SSH hardening"
  mapfile -t keyed < <(users_with_keys)
  if (( ${#keyed[@]} > 0 )); then
    ok "Non-root users with SSH keys: ${keyed[*]}"
  else
    err "No non-root user with an authorized SSH key was found."
    warn "Hardening now would lock you out. Create a user with a key first."
    if (( ! DRY_RUN )); then
      ask "Type I UNDERSTAND to continue anyway, or press Enter to cancel" "" \
        '^(I UNDERSTAND)?$' "Type exactly: I UNDERSTAND"
      [[ "$REPLY" == "I UNDERSTAND" ]] || { info "Cancelled"; return 0; }
    fi
  fi
  printf '\nThis will: disable root login, disable password login, limit auth attempts.\n'
  if ask_yn "Change the SSH port as well?" n; then
    ask_port "New SSH port" 2222
    newport="$REPLY"
    [[ "$newport" == *:* ]] && die "Enter a single port."
    port_args=(--port "$newport")
  fi
  ask_yn "Apply SSH hardening?" n || { info "Cancelled"; return 0; }
  ASSUME_YES=1 cmd_ssh_harden "${port_args[@]}"
  if [[ -n "$newport" ]] && have ufw && ask_yn "Allow port $newport/tcp in the firewall now?" y; then
    cmd_fw_allow "$newport/tcp"
  fi
  warn "Keep this session open and test a new login from another terminal."
}

wiz_user() {
  local user="" args=() key=""
  require_root
  ask "New username" "" "$RE_USER" "Use lowercase letters, digits, '-' or '_' (max 32, not starting with a digit)."
  user="$REPLY"
  if id "$user" >/dev/null 2>&1; then
    warn "User $user already exists; options below will be applied to it."
  fi
  if ask_yn "Grant administrator (sudo) rights?" n; then
    args+=(--sudo)
  fi
  if ask_yn "Install an SSH public key for this user?" y; then
    ask "Paste the public key (ssh-ed25519 AAAA...)" "" "$RE_PUBKEY" \
      "That does not look like a valid SSH public key."
    key="$REPLY"
    args+=(--key "$key")
  fi
  section "Summary"
  printf 'User : %s\nSudo : %s\nKey  : %s\n' "$user" \
    "$([[ " ${args[*]} " == *" --sudo "* ]] && echo yes || echo no)" \
    "$([[ -n "$key" ]] && echo yes || echo "no (a password will be requested)")"
  ask_yn "Create it?" y || { info "Cancelled"; return 0; }
  cmd_user_add "$user" "${args[@]}"
}

wiz_audit() {
  local v val
  section "Security quick audit"
  if have sshd && v="$(sshd -T 2>/dev/null)"; then
    val="$(awk '/^permitrootlogin / {print $2}' <<<"$v")"
    case "$val" in
      no) status_line ok "SSH root login is disabled" ;;
      prohibit-password|without-password) status_line warn "SSH root login allowed with keys only" ;;
      *) status_line bad "SSH root login is allowed" ;;
    esac
    val="$(awk '/^passwordauthentication / {print $2}' <<<"$v")"
    if [[ "$val" == no ]]; then status_line ok "SSH password authentication is disabled"
    else status_line bad "SSH password authentication is enabled"; fi
  else
    status_line warn "Cannot read the sshd configuration (run as root with openssh-server installed)"
  fi
  if systemctl is-active --quiet ufw 2>/dev/null; then status_line ok "Firewall (UFW) is active"
  else status_line bad "Firewall (UFW) is not active"; fi
  if systemctl is-active --quiet fail2ban 2>/dev/null; then status_line ok "Fail2ban is active"
  else status_line bad "Fail2ban is not active"; fi
  if dpkg -s unattended-upgrades >/dev/null 2>&1; then status_line ok "Unattended upgrades installed"
  else status_line bad "Unattended upgrades not installed"; fi
  if [[ -f /var/run/reboot-required ]]; then status_line warn "A reboot is pending"
  else status_line ok "No reboot pending"; fi
  if (( EUID == 0 )) && [[ -r /etc/shadow ]]; then
    val="$(awk -F: '$2 == "" {printf "%s ", $1}' /etc/shadow)"
    if [[ -n "$val" ]]; then status_line bad "Accounts with an empty password: $val"
    else status_line ok "No accounts with an empty password"; fi
  fi
}

wiz_reboot() {
  require_root
  [[ -f /var/run/reboot-required ]] && warn "A reboot is pending." || info "No reboot is pending."
  warn "Rebooting will disconnect every user and interrupt all services."
  ask_yn "Reboot the server now?" n || { info "Cancelled"; return 0; }
  ask "Type REBOOT to confirm" "" '^REBOOT$' "Type exactly: REBOOT"
  run systemctl reboot
}

show_log() {
  [[ -r "$LOG_FILE" ]] || die "Log file $LOG_FILE is not readable."
  tail -n 40 "$LOG_FILE"
}

pick_user() {
  local -a names=()
  mapfile -t names < <(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}' /etc/passwd)
  if (( ${#names[@]} == 0 )); then
    warn "No regular user accounts found."
    return 1
  fi
  menu_choose "$1" "${names[@]}" || return 1
  SELECTED="${names[$((CHOICE - 1))]}"
}

# ---------------------------------------------------------------------------
# Interactive mode: reports
# ---------------------------------------------------------------------------
wiz_report() {
  local title author
  local -a args=()
  section "Generate an HTML server report"
  ask "Report title" "Server Health and Security Report"
  title="$REPLY"
  ask "Prepared by" "$(id -un)@$(hostname)"
  author="$REPLY"
  args=(--title "$title" --author "$author")
  if ask_yn "Choose the output file yourself?" n; then
    ask "Output file (absolute path ending in .html)" \
      "$(report_default_dir)/debnetadmin-report-$(hostname -s)-$(date +%Y%m%d-%H%M).html" \
      '^/.+\.html?$' "Enter an absolute path ending in .html"
    args+=(-o "$REPLY")
  fi
  if ask_yn "E-mail the report when done?" n; then
    ask "Recipient address" "" "$RE_EMAIL" "Enter a valid e-mail address."
    args+=(--mail "$REPLY")
  fi
  (( EUID == 0 )) || warn "Not root: firewall, passwords, SMART, certificates and logs will be incomplete."
  cmd_report "${args[@]}"
}

wiz_report_schedule() {
  local -a args=()
  require_root
  menu_choose "How often should the report run?" \
    "Every day at 06:30" "Every Monday at 06:30" "First day of each month at 06:30" || return 0
  case "$CHOICE" in
    1) args+=(--daily) ;;
    2) args+=(--weekly) ;;
    3) args+=(--monthly) ;;
  esac
  if ask_yn "E-mail each report?" n; then
    ask "Recipient address" "" "$RE_EMAIL" "Enter a valid e-mail address."
    args+=(--mail "$REPLY")
  fi
  cmd_report_schedule "${args[@]}"
}

menu_reports() {
  while true; do
    menu_choose "Reports (self-contained HTML)" \
      "Generate a report now (guided)" \
      "Generate a report with default settings" \
      "List generated reports" \
      "Schedule recurring reports" \
      "Show the current schedule" \
      "Remove the schedule" || return 0
    case "$CHOICE" in
      1) act wiz_report ;;
      2) act cmd_report ;;
      3) act cmd_report_list ;;
      4) act wiz_report_schedule ;;
      5) act cmd_report_schedule --show ;;
      6) if ask_yn "Remove the scheduled report?" n; then act cmd_report_schedule --remove; fi ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Interactive mode: users, system, storage, packages, logs, certificates
# ---------------------------------------------------------------------------
wiz_user_delete() {
  local -a args=()
  require_root
  pick_user "Which user do you want to delete?" || return 0
  local user="$SELECTED"
  if ask_yn "Also delete the home directory (an archive is saved first)?" n; then
    args+=(--purge-home)
  fi
  if pgrep -u "$user" >/dev/null 2>&1; then
    warn "$user has running processes."
    ask_yn "Terminate them?" n || { info "Cancelled"; return 0; }
    args+=(--force)
  fi
  cmd_user_del "$user" "${args[@]}"
}

menu_users() {
  while true; do
    menu_choose "User accounts" \
      "List users" \
      "Create a user (guided)" \
      "Lock a user" \
      "Unlock a user" \
      "Force a password change at next login" \
      "Delete a user" || return 0
    case "$CHOICE" in
      1) act cmd_user_list ;;
      2) act wiz_user ;;
      3) if pick_user "Lock which user?"; then act cmd_user_lock "$SELECTED"; fi ;;
      4) if pick_user "Unlock which user?"; then act cmd_user_unlock "$SELECTED"; fi ;;
      5) if pick_user "Which user must change their password?"; then act cmd_user_expire "$SELECTED"; fi ;;
      6) act wiz_user_delete ;;
    esac
  done
}

menu_system() {
  local cur
  while true; do
    menu_choose "System configuration" \
      "System information" \
      "Health check" \
      "Set the host name" \
      "Set the time zone" \
      "Time synchronisation (status / enable Chrony)" \
      "Add a swap file" \
      "Apply the kernel hardening profile (sysctl)" \
      "Reboot the server" || return 0
    case "$CHOICE" in
      1) act cmd_sysinfo ;;
      2) act cmd_health ;;
      3) ask "New host name" "$(hostname -s)" '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' \
           "Use lowercase letters, digits and '-' (max 63)."
         act cmd_hostname_set "$REPLY" ;;
      4) cur="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
         ask "Time zone (Area/City)" "${cur:-Europe/Madrid}" '^[A-Za-z0-9_+/-]+$' "Use the form Area/City."
         act cmd_timezone_set "$REPLY" ;;
      5) act cmd_time_sync
         if ! have chronyc && ask_yn "Install and enable Chrony now?" y; then act cmd_time_sync --enable; fi ;;
      6) ask "Swap size (for example 2G or 512M)" "2G" '^[0-9]+[MG]$' "Use a number followed by M or G."
         act cmd_swap_add "$REPLY" ;;
      7) act cmd_sysctl_harden ;;
      8) act wiz_reboot ;;
    esac
  done
}

menu_storage() {
  local -a paths=()
  while true; do
    menu_choose "Storage and backups" \
      "Largest directories (disk usage)" \
      "Find large files" \
      "Disk health (SMART)" \
      "Back up /etc" \
      "Back up other directories" \
      "Back up databases (MariaDB/MySQL, PostgreSQL)" \
      "List backups" \
      "Verify the latest backup" || return 0
    case "$CHOICE" in
      1) ask "Directory" "/" '^/.*$' "Enter an absolute path."
         act cmd_disk_usage "$REPLY" ;;
      2) ask "Directory" "/" '^/.*$' "Enter an absolute path."
         local where="$REPLY"
         ask "Minimum size (for example 100M, 1G)" "100M" '^[0-9]+[kMG]$' "Use a number followed by k, M or G."
         act cmd_big_files "$where" "$REPLY" ;;
      3) if ! have smartctl && ask_yn "smartmontools is not installed. Install it now?" y; then act cmd_install_smart; fi
         act cmd_smart ;;
      4) act cmd_backup ;;
      5) ask "Absolute paths to back up, separated by spaces" "/home" '^(/[^ ]*)( +/[^ ]*)*$' \
           "Enter one or more absolute paths."
         read -r -a paths <<<"$REPLY"
         act cmd_backup_paths "${paths[@]}" ;;
      6) act cmd_db_backup ;;
      7) act cmd_backup_list ;;
      8) act cmd_backup_verify ;;
    esac
  done
}

menu_packages() {
  local -a names=()
  while true; do
    menu_choose "Packages and updates" \
      "Update the system" \
      "List upgradable packages" \
      "Search for a package" \
      "Install packages" \
      "Remove packages" \
      "Hold a package (prevent upgrades)" \
      "Release a held package" \
      "List held packages" \
      "Clean up (unused packages, cache, leftovers)" \
      "Enable unattended security upgrades" \
      "Is a reboot required?" \
      "Show recent APT history" || return 0
    case "$CHOICE" in
      1) if ask_yn "Upgrade all packages now?" y; then act cmd_update; fi ;;
      2) act cmd_pkg upgradable ;;
      3) ask "Search term" "" '^[A-Za-z0-9+._ -]+$' "Use letters, digits and spaces."
         read -r -a names <<<"$REPLY"
         act cmd_pkg search "${names[@]}" ;;
      4) ask "Package names (space separated)" "" '^[a-z0-9][a-z0-9+.: -]*$' "Use valid Debian package names."
         read -r -a names <<<"$REPLY"
         act cmd_pkg install "${names[@]}" ;;
      5) ask "Package names to remove" "" '^[a-z0-9][a-z0-9+.: -]*$' "Use valid Debian package names."
         read -r -a names <<<"$REPLY"
         if ask_yn "Remove ${names[*]}?" n; then act cmd_pkg remove "${names[@]}"; fi ;;
      6) ask "Package to hold" "" '^[a-z0-9][a-z0-9+.:-]*$' "Use a valid package name."
         act cmd_pkg hold "$REPLY" ;;
      7) ask "Package to release" "" '^[a-z0-9][a-z0-9+.:-]*$' "Use a valid package name."
         act cmd_pkg unhold "$REPLY" ;;
      8) act cmd_pkg held ;;
      9) if ask_yn "Remove unused packages, leftover configs and the package cache?" y; then act cmd_pkg clean; fi ;;
      10) act cmd_autoupdates ;;
      11) act cmd_pkg reboot-check ;;
      12) act cmd_pkg history ;;
    esac
  done
}

menu_logs() {
  while true; do
    menu_choose "Logs, processes and scheduled tasks" \
      "Recent errors in the system journal" \
      "Failed SSH logins and top offenders" \
      "Logs of a service" \
      "Top processes by CPU" \
      "Top processes by memory" \
      "Scheduled tasks (cron and timers)" \
      "Trim the journal to a maximum size" \
      "DebNetAdmin action log" || return 0
    case "$CHOICE" in
      1) ask "How many hours back?" 24 "$RE_NUMBER" "Enter a number."
         act cmd_logs_errors "$REPLY" ;;
      2) ask "How many hours back?" 24 "$RE_NUMBER" "Enter a number."
         act cmd_auth_failures "$REPLY" ;;
      3) if pick_service "Logs of which service?"; then
           local svc="$SELECTED"
           ask "How many lines?" 100 "$RE_NUMBER" "Enter a number."
           act cmd_logs "$svc" "$REPLY"
         fi ;;
      4) act cmd_procs cpu ;;
      5) act cmd_procs mem ;;
      6) act cmd_cron_list ;;
      7) ask "Maximum journal size (for example 200M)" "200M" '^[0-9]+[KMG]$' "Use a number followed by K, M or G."
         act cmd_journal_vacuum "$REPLY" ;;
      8) act show_log ;;
    esac
  done
}

wiz_cert_issue() {
  local domain email
  local -a args=()
  require_root
  ask "Domain name (must point to this server)" "" "$RE_DOMAIN" "Enter a valid domain such as example.org."
  domain="$REPLY"
  ask "Contact e-mail for expiry notices" "" "$RE_EMAIL" "Enter a valid e-mail address."
  email="$REPLY"
  menu_choose "How should the domain be validated?" \
    "Through Nginx (installs the certbot Nginx plugin)" \
    "Through Apache (installs the certbot Apache plugin)" \
    "Standalone (temporary web server on port 80)" \
    "Webroot (an existing document root)" || return 0
  case "$CHOICE" in
    1) args+=(--nginx) ;;
    2) args+=(--apache) ;;
    3) args+=(--standalone) ;;
    4) ask "Document root" "/var/www/html" '^/.+' "Enter an absolute path."
       args+=(--webroot "$REPLY") ;;
  esac
  if ask_yn "Use the Let's Encrypt staging server (test certificate, no rate limits)?" n; then
    args+=(--staging)
  fi
  cmd_certbot_issue "$domain" --email "$email" "${args[@]}"
}

menu_certs() {
  while true; do
    menu_choose "TLS certificates" \
      "Check local Let's Encrypt certificates" \
      "Check the certificate of a remote host" \
      "Issue a certificate (guided)" \
      "Renew certificates now" \
      "Test renewal (dry run)" || return 0
    case "$CHOICE" in
      1) act cmd_cert_check ;;
      2) ask "Host or host:port" "" '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$' "Enter host or host:port."
         act cmd_cert_check "$REPLY" ;;
      3) act wiz_cert_issue ;;
      4) act cmd_cert_renew ;;
      5) act cmd_cert_renew --test ;;
    esac
  done
}

menu_security() {
  while true; do
    menu_choose "Security and hardening" \
      "Quick security audit" \
      "Harden SSH (guided)" \
      "Install and configure Fail2ban" \
      "Show Fail2ban sshd jail status" \
      "Enable unattended security upgrades" \
      "Apply the kernel hardening profile (sysctl)" \
      "Failed SSH logins and top offenders" || return 0
    case "$CHOICE" in
      1) act wiz_audit ;;
      2) act wiz_ssh_harden ;;
      3) if ask_yn "Install Fail2ban with an sshd jail?" y; then act cmd_fail2ban; fi ;;
      4) act fail2ban-client status sshd ;;
      5) act cmd_autoupdates ;;
      6) act cmd_sysctl_harden ;;
      7) act cmd_auth_failures 24 ;;
    esac
  done
}

cmd_menu() {
  need_tty
  trap - ERR
  trap 'printf "\n"; info "Interrupted. Bye."; exit 130' INT
  maybe_elevate
  while true; do
    clear_screen
    banner
    dashboard
    if BACK_LABEL="Quit" menu_choose "Main menu" \
      "Reports (professional HTML report)" \
      "Network services (install, manage, validate)" \
      "Network tools (ping, DNS, ports, routes)" \
      "Firewall" \
      "Security and hardening" \
      "User accounts" \
      "System configuration" \
      "Storage and backups" \
      "Packages and updates" \
      "Logs, processes and scheduled tasks" \
      "TLS certificates" \
      "Toggle dry-run mode (now: $( ((DRY_RUN)) && echo ON || echo OFF ))"; then
      case "$CHOICE" in
        1)  menu_reports ;;
        2)  menu_services ;;
        3)  menu_network ;;
        4)  menu_firewall ;;
        5)  menu_security ;;
        6)  menu_users ;;
        7)  menu_system ;;
        8)  menu_storage ;;
        9)  menu_packages ;;
        10) menu_logs ;;
        11) menu_certs ;;
        12) DRY_RUN=$((1 - DRY_RUN)) ;;
      esac
    else
      ok "Goodbye"
      return 0
    fi
  done
}

# ---------------------------------------------------------------------------
# Help and entry point
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
DebNetAdmin ${DNA_VERSION} - Debian server administration toolkit

Usage: ${PROG} [options] <command> [arguments]
       ${PROG}                 (no command: interactive console)

Global options:
  -n, --dry-run     Show what would be done without changing anything
  -y, --yes         Assume "yes" for confirmation prompts
  -h, --help        Show this help
  -V, --version     Show the version

REPORTS
  report [-o FILE] [--title T] [--author A] [--mail ADDR] [--quiet]
                               Professional self-contained HTML report
  report-list                  List generated reports
  report-schedule [--daily|--weekly|--monthly] [--mail ADDR] | --show | --remove

INFORMATION
  sysinfo | health | netdiag [host] | listening | services | audit

SERVICES
  install <service>            Install, enable and start a service
  svc <action> <service>       status|start|stop|restart|reload|enable|disable
  logs <service> [lines]       Recent journal entries of a service
  check-config [service|all]   Validate service configuration files

FIREWALL AND SECURITY
  fw-setup | fw-status | fw-allow <port>[/proto] [cidr] | fw-preset <service>
  fail2ban                     Install Fail2ban with an sshd jail
  ssh-harden [--port <n>]      Disable root/password login, apply safe defaults
  sysctl-harden                Kernel/network hardening profile
  autoupdates                  Enable unattended security upgrades

USERS
  user-add <name> [--sudo] [--key "<public key>"]
  user-list | user-lock <name> | user-unlock <name> | user-expire <name>
  user-del <name> [--purge-home] [--force]

SYSTEM
  hostname-set <name> | timezone-set <Area/City>
  time-sync [--enable]         NTP status; install Chrony
  swap-add <size>              Create and enable a swap file (e.g. 2G)
  update                       Upgrade packages and clean up

STORAGE AND BACKUPS
  disk-usage [path] | big-files [path] [size] | smart | install-smart
  backup                       Archive /etc
  backup-paths <path>...       Archive arbitrary directories
  db-backup                    Dump MariaDB/MySQL and PostgreSQL databases
  backup-list | backup-verify [file]

PACKAGES
  pkg <search|info|install|remove|purge|hold|unhold|held|upgradable|history|clean|reboot-check> [names]

LOGS, PROCESSES, TASKS
  logs-errors [hours] | auth-failures [hours] | procs [cpu|mem]
  cron-list | journal-vacuum <size>

TLS CERTIFICATES
  cert-check [host[:port]]     Local Let's Encrypt certs or a remote host
  certbot-issue <domain> --email <addr> [--nginx|--apache|--standalone|--webroot <dir>] [--staging]
  cert-renew [--test]

Environment:
  DEBNETADMIN_LOG, DEBNETADMIN_BACKUP_DIR, DEBNETADMIN_BACKUP_KEEP,
  DEBNETADMIN_REPORT_DIR, DEBNETADMIN_REPORT_KEEP

Examples:
  sudo ${PROG} report --author "Jane Doe" --mail ops@example.org
  sudo ${PROG} install nginx && sudo ${PROG} fw-preset nginx
  sudo ${PROG} certbot-issue www.example.org --email admin@example.org
  sudo ${PROG} --dry-run ssh-harden --port 2222
EOF
}

main() {
  while (( $# )); do
    case "$1" in
      -n|--dry-run) DRY_RUN=1 ;;
      -y|--yes)     ASSUME_YES=1 ;;
      -h|--help)    usage; exit 0 ;;
      -V|--version) printf '%s %s\n' "$PROG" "$DNA_VERSION"; exit 0 ;;
      --)           shift; break ;;
      -*)           die "Unknown option: $1 (see '$PROG help')" ;;
      *)            break ;;
    esac
    shift
  done

  local cmd="${1:-menu}"
  (( $# )) && shift

  case "$cmd" in
    help) usage; return 0 ;;
    sysinfo|health|netdiag|listening|services|fw-status|report-list|user-list|disk-usage|big-files|procs|cron-list|pkg|cert-check|logs-errors|auth-failures) ;;
    *) check_os ;;
  esac
  init_log

  case "$cmd" in
    menu)            cmd_menu ;;
    report)          cmd_report "$@" ;;
    report-list)     cmd_report_list ;;
    report-schedule) cmd_report_schedule "$@" ;;
    sysinfo)         cmd_sysinfo ;;
    health)          cmd_health ;;
    netdiag)         cmd_netdiag "$@" ;;
    listening)       cmd_listening ;;
    services)        cmd_services ;;
    audit)           wiz_audit ;;
    update)          cmd_update ;;
    autoupdates)     cmd_autoupdates ;;
    backup)          cmd_backup ;;
    backup-paths)    cmd_backup_paths "$@" ;;
    backup-list)     cmd_backup_list ;;
    backup-verify)   cmd_backup_verify "$@" ;;
    db-backup)       cmd_db_backup ;;
    user-add)        cmd_user_add "$@" ;;
    user-list)       cmd_user_list ;;
    user-lock)       cmd_user_lock "$@" ;;
    user-unlock)     cmd_user_unlock "$@" ;;
    user-expire)     cmd_user_expire "$@" ;;
    user-del)        cmd_user_del "$@" ;;
    ssh-harden)      cmd_ssh_harden "$@" ;;
    sysctl-harden)   cmd_sysctl_harden ;;
    fw-setup)        cmd_fw_setup ;;
    fw-allow)        cmd_fw_allow "$@" ;;
    fw-preset)       cmd_fw_preset "$@" ;;
    fw-status)       cmd_fw_status ;;
    fail2ban)        cmd_fail2ban ;;
    install)         cmd_install "$@" ;;
    svc)             cmd_svc "$@" ;;
    logs)            cmd_logs "$@" ;;
    check-config)    cmd_check_config "$@" ;;
    hostname-set)    cmd_hostname_set "$@" ;;
    timezone-set)    cmd_timezone_set "$@" ;;
    time-sync)       cmd_time_sync "$@" ;;
    swap-add)        cmd_swap_add "$@" ;;
    disk-usage)      cmd_disk_usage "$@" ;;
    big-files)       cmd_big_files "$@" ;;
    smart)           cmd_smart ;;
    install-smart)   cmd_install_smart ;;
    pkg)             cmd_pkg "$@" ;;
    logs-errors)     cmd_logs_errors "$@" ;;
    auth-failures)   cmd_auth_failures "$@" ;;
    procs)           cmd_procs "$@" ;;
    cron-list)       cmd_cron_list ;;
    journal-vacuum)  cmd_journal_vacuum "$@" ;;
    cert-check)      cmd_cert_check "$@" ;;
    certbot-issue)   cmd_certbot_issue "$@" ;;
    cert-renew)      cmd_cert_renew "$@" ;;
    *)               die "Unknown command '$cmd' (see '$PROG help')" ;;
  esac
}

main "$@"
