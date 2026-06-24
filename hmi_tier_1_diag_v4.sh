#!/usr/bin/env bash
################################################################################
# HMI TIER 1 DIAGNOSTICS - v3
# Purpose: Gather low-impact diagnostics from Ubuntu-based Rockwell MES HMIs.
# Author: Jason Callahan
# Email: jmcall3883@gmail.com
# Usage: ./hmi_tier1_diag_v3_1.sh <HMI_IP> [options]
# Usage: ./hmi_tier1_diag_v3_1.sh --targetip <HMI_IP> [options]
# Example: ./hmi_tier1_diag_v3_1.sh 172.55.44.1
# Example: ./hmi_tier1_diag_v3_1.sh --targetip 172.55.44.1 --muser admin --mserv 9.9.9.9 --mport 443
################################################################################

set -uo pipefail

# ---------- Defaults ----------
HMI_IP=""
HMI_USER="admin"
MES_SERVER="9.9.9.9"
MES_PORT="443"
PING_COUNT="5"
REPORT_BASE="/mnt/c/HMI_LOGS"
OPEN_REPORT=0
QUIET=0
# This assumes that all users will use default "admin" credentials.


# ---------- Console colors ----------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

# Help Guide/Manual/User Instructions
usage() {
  cat <<USAGE
Usage: $0 <HMI_IP> [options]
   or: $0 --targetip <HMI_IP> [options]

Only the HMI IP is required. Defaults are used for SSH user, MES server,
MES port, and report location unless overridden.

Required:
  <HMI_IP>               Target HMI IP address
  --targetip <IP>        Target HMI IP address, flag form

Options:
  --muser <USER>         SSH user. Default: admin
  --mserv <HOST/IP>      MES server host/IP. Default: 9.9.9.9
  --mport <PORT>         MES server TCP port. Default: 443
  --outdir <PATH>        Report output directory. Default: /mnt/c/HMI_LOGS
  --open                 Open report when complete
  --quiet                Minimal console output
  -h, --help             Show this help

Examples:
  $0 172.1.11.111
  $0 172.1.11.111 --mserv 172.1.11.3
  $0 --targetip 172.55.44.1 --muser admin --mserv 9.9.9.9 --mport 443
USAGE
}

need_value() {
  local opt="$1"
  local val="${2:-}"
  if [[ -z "$val" || "$val" == --* ]]; then
    echo "[ERROR] $opt requires a value"
    usage
    exit 2
  fi
}

# flags for changing defaults
while [[ $# -gt 0 ]]; do
  case "$1" in
    --targetip) need_value "$1" "${2:-}"; HMI_IP="$2"; shift 2 ;;
    --muser) need_value "$1" "${2:-}"; HMI_USER="$2"; shift 2 ;;
    --mserv) need_value "$1" "${2:-}"; MES_SERVER="$2"; shift 2 ;;
    --mport) need_value "$1" "${2:-}"; MES_PORT="$2"; shift 2 ;;
    --outdir) need_value "$1" "${2:-}"; REPORT_BASE="$2"; shift 2 ;;
    --open) OPEN_REPORT=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "[ERROR] Unknown option: $1"; usage; exit 2 ;;
    *)
      if [[ -z "$HMI_IP" ]]; then
        HMI_IP="$1"
        shift
      else
        echo "[ERROR] Unexpected extra argument: $1"
        usage
        exit 2
      fi
      ;;
  esac
done

if [[ -z "$HMI_IP" ]]; then
  echo "[ERROR] HMI IP required"
  usage
  exit 2
fi

if [[ ! "$MES_PORT" =~ ^[0-9]+$ ]] || (( MES_PORT < 1 || MES_PORT > 65535 )); then
  echo "[ERROR] --mport must be a TCP port from 1-65535"
  exit 2
fi


# Txt File Outout Setup
REPORT_ID="$(date +%Y%m%d_%H%M%S)"
mkdir -p "$REPORT_BASE"
REPORT_FILE="${REPORT_BASE}/HMI_DIAG_${HMI_IP//./_}_${REPORT_ID}.txt"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

say() {
  [[ "$QUIET" -eq 1 ]] && return 0
  local level="$1"; shift
  case "$level" in
    OK)   echo -e "${GREEN}[OK]${NC} $*" ;;
    WARN) echo -e "${YELLOW}[WARN]${NC} $*" ;;
    FAIL) echo -e "${RED}[FAIL]${NC} $*" ;;
    INFO) echo -e "${BLUE}[INFO]${NC} $*" ;;
    *)    echo "$*" ;;
  esac
}

write_section() {
  {
    echo ""
    echo "================================================================================"
    echo "$1"
    echo "================================================================================"
  } >> "$REPORT_FILE"
}

write_kv() {
  printf '%-24s %s\n' "$1:" "$2" >> "$REPORT_FILE"
}

run_logged() {
  local label="$1"; shift
  write_section "$label"
  echo "Command: $*" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
  if timeout 20 "$@" >> "$REPORT_FILE" 2>&1; then
    say OK "$label complete"
    echo "" >> "$REPORT_FILE"
    echo "[RESULT] OK" >> "$REPORT_FILE"
    return 0
  else
    local rc=$?
    say WARN "$label failed or timed out; continuing"
    echo "" >> "$REPORT_FILE"
    echo "[RESULT] WARN/FAIL rc=$rc" >> "$REPORT_FILE"
    return 0
  fi
}

# ---------- Header ----------
{
  echo "===== HMI TIER 1 DIAGNOSTICS REPORT ====="
  write_kv "Generated" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  write_kv "Local Host" "$(hostname 2>/dev/null || echo unknown)"
  write_kv "Target HMI" "$HMI_IP"
  write_kv "SSH User" "$HMI_USER"
  write_kv "MES Server" "$MES_SERVER:$MES_PORT"
  write_kv "Report ID" "$REPORT_ID"
  write_kv "Report File" "$REPORT_FILE"
} > "$REPORT_FILE"

say INFO "Writing report to $REPORT_FILE"

# ---------- Local connectivity ----------
write_section "QUICK SUMMARY"
echo "Fill this section from the status markers below before escalating." >> "$REPORT_FILE"
echo "- HMI ping: see LOCAL CONNECTIVITY - HMI" >> "$REPORT_FILE"
echo "- MES ping from WSL: see LOCAL CONNECTIVITY - MES SERVER" >> "$REPORT_FILE"
echo "- SSH diagnostics: see REMOTE HMI DIAGNOSTICS" >> "$REPORT_FILE"
echo "- MES path from HMI: see REMOTE HMI TO MES CONNECTIVITY" >> "$REPORT_FILE"
echo "- Recent errors: see RECENT ERROR SIGNALS" >> "$REPORT_FILE"

# User system pings target HMI & MES server to validate connectivity
run_logged "LOCAL CONNECTIVITY - HMI PING" ping -c "$PING_COUNT" "$HMI_IP"
run_logged "LOCAL CONNECTIVITY - MES SERVER PING FROM WSL" ping -c "$PING_COUNT" "$MES_SERVER"

# Runs NetCat to check port availability
if command -v nc >/dev/null 2>&1; then
  run_logged "LOCAL TCP CHECK - HMI SSH PORT 22" nc -zv -w 3 "$HMI_IP" 22
  run_logged "LOCAL TCP CHECK - MES SERVER PORT" nc -zv -w 3 "$MES_SERVER" "$MES_PORT"
else
  write_section "LOCAL TCP CHECKS"
  echo "nc not installed locally; skipped TCP port checks." >> "$REPORT_FILE"
  say WARN "nc not installed locally; skipped TCP checks"
fi

# User system runs Trace Route to MES Server
if command -v traceroute >/dev/null 2>&1; then
  run_logged "LOCAL TRACEROUTE - MES SERVER" traceroute -m 12 -w 2 "$MES_SERVER"
else
  write_section "LOCAL TRACEROUTE - MES SERVER"
  echo "traceroute not installed locally; skipped." >> "$REPORT_FILE"
fi

# User system runs MTR
if command -v mtr >/dev/null 2>&1; then
  run_logged "LOCAL MTR REPORT - MES SERVER" mtr -r -c 10 "$MES_SERVER"
else
  write_section "LOCAL MTR REPORT - MES SERVER"
  echo "mtr not installed locally; skipped." >> "$REPORT_FILE"
fi

# ---------- Remote diagnostics ----------
write_section "REMOTE HMI DIAGNOSTICS"
echo "Starting SSH collection. You may be prompted for the HMI password once." >> "$REPORT_FILE"
say INFO "Starting SSH collection. Enter HMI password if prompted."

SSH_OPTS=(
  -o ConnectTimeout=10
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=2
  -o StrictHostKeyChecking=accept-new
)

# Attempts to ssh into target HMI
if ssh "${SSH_OPTS[@]}" "${HMI_USER}@${HMI_IP}" 'bash -s' -- "$MES_SERVER" "$MES_PORT" <<'REMOTE_CMDS' >> "$REPORT_FILE" 2>&1; then
MES_SERVER="$1"
MES_PORT="$2"

section() {
  echo ""
  echo "--------------------------------------------------------------------------------"
  echo "$1"
  echo "--------------------------------------------------------------------------------"
}

safe_run() {
  local label="$1"; shift
  section "$label"
  timeout 15 nice -n 10 "$@" 2>&1 || echo "[WARN] Command failed, unavailable, or timed out: $*"
}

safe_shell() {
  local label="$1"; shift
  section "$label"
  timeout 20 nice -n 10 bash -c "$*" 2>&1 || echo "[WARN] Command failed, unavailable, or timed out: $*"
}

section "REMOTE COLLECTION CONTEXT"
echo "Remote host: $(hostname 2>/dev/null || echo unknown)"
echo "Remote time: $(date 2>/dev/null || echo unknown)"
echo "User: $(id 2>/dev/null || echo unknown)"

# runs HMI diagnostics including: Uptime, Free, disk health, Top, pa, ps aux, uname, OS version, and dmesg
# to collect basic system health diagnostics and validate kernel version.

safe_run "UPTIME AND LOAD" uptime
safe_run "MEMORY USAGE" free -h
safe_run "DISK USAGE" df -hT
safe_run "SYSTEM STATS" iostat -s -t
safe_shell "TOP SNAPSHOT - FIRST 15 LINES" 'COLUMNS=160 top -b -n 1 | head -15'
safe_shell "TOP CPU PROCESSES" 'ps -eo pid,ppid,user,stat,pcpu,pmem,etime,comm,args --sort=-pcpu | head -25'
safe_shell "TOP MEMORY PROCESSES" 'ps -eo pid,ppid,user,stat,pcpu,pmem,etime,comm,args --sort=-pmem | head -25'
safe_shell "APPLICATION PROCESS CHECK" 'ps aux | grep -iE "optix|factorytalk|rockwell|spinalx|mars|mes" | grep -v grep || echo "No matching app processes found"'
safe_shell "FULL PROCESS LIST - PS AUX" 'ps aux'
safe_run "KERNEL AND OS" uname -a
safe_shell "OS RELEASE" 'cat /etc/os-release 2>/dev/null || lsb_release -a 2>/dev/null || echo "OS release unavailable"'
safe_shell "DMESG TAIL" 'dmesg 2>/dev/null | tail -25 || echo "dmesg unavailable or permission denied"'

# Performs network diagnostics from the HMI including: ping to MES Server, NetCat port validation
# mtr, netstat, etc...
section "REMOTE HMI TO MES CONNECTIVITY"
echo "Target MES: ${MES_SERVER}:${MES_PORT}"
safe_shell "PING MES FROM HMI" "ping -c 5 '$MES_SERVER'"
safe_shell "TCP PORT CHECK TO MES" "if command -v nc >/dev/null 2>&1; then nc -zv -w 5 '$MES_SERVER' '$MES_PORT'; else timeout 5 bash -c '</dev/tcp/$MES_SERVER/$MES_PORT' && echo 'TCP connect succeeded via /dev/tcp' || echo 'TCP connect failed via /dev/tcp'; fi"
safe_shell "TRACEROUTE MES FROM HMI" "traceroute -m 12 -w 2 '$MES_SERVER' 2>&1 || tracepath '$MES_SERVER' 2>&1 || echo 'traceroute/tracepath unavailable'"
safe_shell "MTR MES FROM HMI" "mtr -r -c 10 '$MES_SERVER' 2>&1 || echo 'mtr unavailable'"
safe_shell "NETWORK INTERFACES" 'ip -br addr 2>/dev/null || ifconfig 2>/dev/null || echo "Interface command unavailable"'
safe_shell "ROUTES" 'ip route 2>/dev/null || route -n 2>/dev/null || echo "Route command unavailable"'
safe_shell "CONNECTION STATES" 'ss -tunap 2>/dev/null | head -80 || netstat -tunap 2>/dev/null | head -80 || echo "ss/netstat unavailable"'

section "SERVICES"
safe_shell "SYSTEMD FAILED SERVICES" 'systemctl --failed --no-pager 2>/dev/null || echo "systemctl unavailable"'
safe_shell "ROCKWELL/OPTIX RELATED SERVICES" 'systemctl list-units --type=service --all --no-pager 2>/dev/null | grep -iE "optix|factorytalk|rockwell|spinalx|mars|mes" || echo "No matching services found"'

#checks Optix and FactoryTalk for version
section "SOFTWARE AND VERSION SIGNALS"
safe_shell "APPLICATION VERSION COMMANDS" 'for cmd in optix factorytalk spinalx; do command -v "$cmd" >/dev/null 2>&1 && "$cmd" --version 2>&1 || echo "$cmd command not found"; done'
safe_shell "APT HISTORY TAIL" 'tail -80 /var/log/apt/history.log 2>/dev/null || echo "apt history unavailable"'
safe_shell "RECENT PACKAGE INSTALLS" 'grep -hE " install | upgrade | remove " /var/log/dpkg.log* 2>/dev/null | tail -80 || echo "dpkg history unavailable"'

section "LOG DISCOVERY"
safe_shell "COMMON LOG DIRECTORIES" 'for d in /var/log /opt /home/admin /home/admin; do [[ -d "$d" ]] && echo "--- $d ---" && find "$d" -maxdepth 3 -type f \( -name "*.log" -o -name "*.txt" \) -printf "%TY-%Tm-%Td %TH:%TM %9s %p\n" 2>/dev/null | sort -r | head -40; done'

# Pulls error logs
section "RECENT ERROR SIGNALS"
safe_shell "JOURNAL ERRORS" 'journalctl -p err -n 80 --no-pager 2>/dev/null || echo "journalctl error query unavailable"'
safe_shell "JOURNAL WARNINGS" 'journalctl -p warning -n 80 --no-pager 2>/dev/null || echo "journalctl warning query unavailable"'
safe_shell "SYSLOG/AUTH ERROR GREP" 'grep -RihE "error|fail|fatal|panic|segfault|timeout|refused|denied|unreachable|disconnect" /var/log/syslog /var/log/messages /var/log/auth.log 2>/dev/null | tail -120 || echo "No readable syslog/auth error matches"'

section "RECENT APPLICATION LOG TAILS"
safe_shell "TAIL CANDIDATE APP LOGS" '
find /var/log /opt /home/admin /home/admin -maxdepth 5 -type f \( -name "*.log" -o -name "*.txt" \) -size -20M 2>/dev/null \
  | grep -iE "optix|factorytalk|rockwell|spinalx|mars|mes|runtime|app" \
  | head -8 \
  | while read -r f; do
      echo "===== $f ====="
      tail -60 "$f" 2>/dev/null
      echo ""
    done
'
REMOTE_CMDS
  say OK "SSH diagnostics collected"
  echo "" >> "$REPORT_FILE"
  echo "[RESULT] REMOTE SSH COLLECTION OK" >> "$REPORT_FILE"
else
  rc=$?
  say FAIL "SSH diagnostics failed; report still contains local checks"
  echo "" >> "$REPORT_FILE"
  echo "[RESULT] REMOTE SSH COLLECTION FAILED rc=$rc" >> "$REPORT_FILE"
fi

# ---------- Final summary ----------
write_section "ESCALATION NOTES"
cat >> "$REPORT_FILE" <<NOTES
Attach this report when escalating.

Useful routing:
- HMI unreachable from WSL: likely local/network/VLAN/firewall/path issue.
- HMI reachable but SSH fails: credential, SSH service, host firewall, or endpoint policy issue.
- HMI can ping MES but TCP port fails: application port/firewall/service-listener issue.
- HMI cannot ping/traceroute MES: network path or routing issue.
- High load, low memory, full disk, failed services, or journal errors: endpoint/app team review.

Operator-impact note:
This script avoids package installs, service restarts, writes to the HMI, and large file copies.
It runs read-only commands with timeouts and nice priority where practical.
NOTES

say OK "Diagnostics complete"
say INFO "Report saved: $REPORT_FILE"

# Opens the .txt file for for review
if [[ "$OPEN_REPORT" -eq 1 ]]; then
  if command -v explorer.exe >/dev/null 2>&1; then
    explorer.exe "$(wslpath -w "$REPORT_FILE")" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$REPORT_FILE" >/dev/null 2>&1 || true
  else
    say WARN "No opener found; report path printed above"
  fi
fi

exit 0
