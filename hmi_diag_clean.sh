#!/bin/bash

################################################################################
# HMI TIER 1 DIAGNOSTICS - CLEAN & EFFICIENT
# Pulls system health, network connectivity, and logs from remote HMI
# Writes everything to report file, opens it when complete
#
# Usage: ./hmi_diag_clean.sh --targetip <IP> [--muser USER] [--mserv SERVER] [--mport PORT]
# Example: ./hmi_diag_clean.sh --targetip 10.54.46.1 --muser admin --mserv 9.9.9.9 --mport 443
#
# Author: Tier 1 MES Support
# Version: 2.0 - Clean edition
################################################################################

set -euo pipefail

# Colors for console feedback only
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Parse arguments
HMI_IP=""
HMI_USER="admin"
MES_SERVER="172.18.0.3"
MES_PORT="443"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --targetip) HMI_IP="$2"; shift 2 ;;
        --muser) HMI_USER="$2"; shift 2 ;;
        --mserv) MES_SERVER="$2"; shift 2 ;;
        --mport) MES_PORT="$2"; shift 2 ;;
        *) echo -e "${RED}[ERROR] Unknown parameter: $1${NC}"; echo "Usage: $0 --targetip <IP> [--muser USER] [--mserv SERVER] [--mport PORT]"; exit 1 ;;
    esac
done

if [[ -z "$HMI_IP" ]]; then
    echo -e "${RED}[ERROR] --targetip required${NC}"
    exit 1
fi

# Setup
if [[ ! -d /mnt/c/HMI_LOGS ]]; then
    mkdir -p /mnt/c/HMI_LOGS
fi

REPORT_ID=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/mnt/c/HMI_LOGS"
REPORT_FILE="${LOG_DIR}/HMI_DIAG_${HMI_IP//\./_}_${REPORT_ID}.txt"

# Initialize report
{
    echo "===== HMI DIAGNOSTICS REPORT ====="
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Target HMI: $HMI_IP (User: $HMI_USER)"
    echo "MES Server: $MES_SERVER:$MES_PORT"
    echo "Report ID: $REPORT_ID"
    echo ""
} > "$REPORT_FILE"

# Console feedback function (minimal)
status() {
    echo -e "${GREEN}[OK]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

# Write to report
write_section() {
    echo "" >> "$REPORT_FILE"
    echo "===== $1 =====" >> "$REPORT_FILE"
}

write_line() {
    echo "$1" >> "$REPORT_FILE"
}

################################################################################
# CONNECTIVITY CHECK
################################################################################
write_section "CONNECTIVITY CHECK"

if timeout 10 ping -c 3 "$HMI_IP" >> "$REPORT_FILE" 2>&1; then
    status "HMI reachable"
else
    error "HMI unreachable - continuing anyway"
fi

################################################################################
# SSH SYSTEM DIAGNOSTICS
################################################################################
write_section "SYSTEM HEALTH"

if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HMI_USER}@${HMI_IP}" << 'REMOTE_CMDS' >> "$REPORT_FILE" 2>&1; then
echo "--- Uptime & Load ---"
uptime

echo ""
echo "--- Memory Usage ---"
free -h

echo ""
echo "--- Disk Usage ---"
df -h

echo ""
echo "--- CPU Info ---"
top -bn1 -n1 | head -15

echo ""
echo "--- Running Services (Optix/FactoryTalk) ---"
ps aux | grep -iE 'optix|factorytalk|spinalx|mars' | grep -v grep || echo "No matching processes found"

echo ""
echo "--- System Kernel ---"
uname -a

echo ""
echo "--- Recent Errors (dmesg) ---"
dmesg | tail -15

REMOTE_CMDS
    status "SSH diagnostics collected"
else
    error "SSH connection failed"
fi

################################################################################
# MES CONNECTIVITY
################################################################################
write_section "MES SERVER CONNECTIVITY"

ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HMI_USER}@${HMI_IP}" << REMOTE_MES >> "$REPORT_FILE" 2>&1 || true
echo "--- Testing connection to $MES_SERVER:$MES_PORT ---"
timeout 5 nc -zv $MES_SERVER $MES_PORT 2>&1 || echo "Netcat timed out or failed"

echo ""
echo "--- Traceroute to MES Server ---"
traceroute -m 10 -w 2 $MES_SERVER 2>&1 || echo "Traceroute not available"

echo ""
echo "--- Network Connections (ss) ---"
ss -tunap 2>/dev/null | grep -E 'LISTEN|ESTABLISHED|CLOSE_WAIT' | head -20 || echo "Unable to get connection state"

REMOTE_MES

################################################################################
# APPLICATION LOGS
################################################################################
write_section "LOGS - DISCOVERY & COLLECTION"

write_line "--- Searching for logs on HMI ---"
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HMI_USER}@${HMI_IP}" << 'REMOTE_LOGS' >> "$REPORT_FILE" 2>&1 || true
find /var/log /opt -name "*.log" -type f -size -100M 2>/dev/null | head -20
REMOTE_LOGS

write_line ""
write_line "--- Collecting logs via SCP ---"

# Get list of small logs
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HMI_USER}@${HMI_IP}" "find /var/log /opt -name '*.log' -type f -size -50M 2>/dev/null | head -10" | while read logfile; do
    if [[ -n "$logfile" ]]; then
        if scp -o ConnectTimeout=5 "${HMI_USER}@${HMI_IP}:${logfile}" "$LOG_DIR/" 2>/dev/null; then
            write_line "[OK] Collected: $(basename "$logfile")"
        fi
    fi
done

################################################################################
# SOFTWARE VERSIONS
################################################################################
write_section "SOFTWARE VERSIONS & UPDATES"

ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HMI_USER}@${HMI_IP}" << 'REMOTE_VER' >> "$REPORT_FILE" 2>&1 || true
echo "--- OS Release ---"
cat /etc/os-release 2>/dev/null || lsb_release -a 2>/dev/null || echo "Unable to determine OS"

echo ""
echo "--- Kernel Version ---"
uname -r

echo ""
echo "--- Application Versions ---"
optix --version 2>/dev/null || echo "optix not found"
factorytalk --version 2>/dev/null || echo "factorytalk not found"

echo ""
echo "--- Recent Updates (apt history) ---"
tail -30 /var/log/apt/history.log 2>/dev/null || echo "Unable to access apt history (requires sudo)"

REMOTE_VER

################################################################################
# SYSTEMD JOURNAL
################################################################################
write_section "RECENT SYSTEM ERRORS"

ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HMI_USER}@${HMI_IP}" "journalctl -p err -n 50 2>/dev/null || journalctl -n 50 2>/dev/null" >> "$REPORT_FILE" 2>&1 || true

################################################################################
# SUMMARY
################################################################################
write_section "SUMMARY"

{
    echo ""
    echo "Report Location: $REPORT_FILE"
    echo "Logs Collected:"
    ls -lh "$LOG_DIR" 2>/dev/null | awk 'NR>1 {print "  " $9 " (" $5 ")"}' || echo "  No additional logs"
    echo ""
    echo "Next Steps:"
    echo "1. Review errors/warnings in this report"
    echo "2. Check MES connectivity if network issues"
    echo "3. Forward app logs to App Team if needed"
    echo "4. Escalate to Tier 2 with this report"
    echo ""
    echo "Report completed: $(date '+%Y-%m-%d %H:%M:%S')"
} >> "$REPORT_FILE"

# Done - open the report
status "Diagnostics complete"
info "Opening report..."
sleep 1

# Try to open the file
if command -v xdg-open &> /dev/null; then
    xdg-open "$REPORT_FILE"
elif command -v open &> /dev/null; then
    open "$REPORT_FILE"
else
    cat "$REPORT_FILE"
fi