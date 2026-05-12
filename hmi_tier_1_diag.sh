#!/bin/bash
 
################################################################################
# HMI DIAGNOSTICS SCRIPT
# Purpose: Remote SSH-based diagnostics for Rockwell MES HMIs (Optix/FactoryTalk)
# Usage: ./hmi_tier_1_diag.sh 
#
# This script pulls system health, network connectivity, and application logs
# without interrupting the HMI's user-facing terminal. Output is structured
# for quick scanning and escalation.
#
# Author: Jason Callahan Tier 1 MES Support
# Email: jasoncallahan@rivian.com
# Version: 1.0
# Date: 2025-05-08
#
# 
################################################################################
 
set -euo pipefail
 
# Color codes for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#!!! Script Config & Flags - !!!
#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
 
# defaults
HMI_IP="$1"                         # REQUIRED - IP address of the target HMI
HMI_USER="${2:-rivadmin}"           # Optional - default user for SSH access (update as needed)
MES_SERVER="${3:-173.255.255.255}"  # Optional - default MES server IP (update as needed)
MES_PORT="${4:-443}"                # Optional - default MES server port (update as needed)
LOG_RETENTION_DAYS=30                # Optional - how long to keep logs (in days)

# Flags to change parameters
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --targetip) HMI_IP="$2"; shift 2;;
        --muser) HMI_USER="$3"; shift 2;;
        --mserv) MES_SERVER="$4"; shift 2;;
        --mport) MES_PORT="$5"; shift 2;;
        *) echo -e "${RED}[ERROR] Unknown parameter: $1${NC}"; exit 1 ;;
    esac
    shift
done
 
# Validate required variables
required_vars=("HMI_IP" "HMI_USER" "MES_SERVER" "MES_PORT" "LOG_RETENTION_DAYS")
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo -e "${RED}[ERROR] Missing required config variable: $var${NC}"
        exit 1
    fi
done

# Setup output directory with timestamp
REPORT_ID=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/mnt/c/Users/jmcal/Documents/"
REPORT_FILE="${LOG_DIR}/HMI_DIAGNOSTICS_REPORT_${HMI_IP}_${REPORT_ID}.txt"
 
mkdir -p "$LOG_DIR"
 
# Function to log results (both to console and file, with color stripping for file)
log_result() {
    local status=$1
    local message=$2
    local details="${3:-}"
    
    case "$status" in
        ok)
            echo -e "${GREEN}[OK]${NC} $message"
            echo "[OK] $message" >> "$REPORT_FILE"
            ;;
        fail)
            echo -e "${RED}[FAIL]${NC} $message"
            echo "[FAIL] $message" >> "$REPORT_FILE"
            ;;
        warn)
            echo -e "${YELLOW}[WARN]${NC} $message"
            echo "[WARN] $message" >> "$REPORT_FILE"
            ;;
        info)
            echo -e "${BLUE}[INFO]${NC} $message"
            echo "[INFO] $message" >> "$REPORT_FILE"
            ;;
    esac
    
    if [[ -n "$details" ]]; then
        echo "    $details" | tee -a "$REPORT_FILE"
    fi
}
 
# Start report
{
    echo "===== HMI DIAGNOSTICS REPORT ====="
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Target HMI: $HMI_IP (User: $HMI_USER)"
    echo "Report ID: $REPORT_ID"
    echo "MES Server: $MES_SERVER:$MES_PORT"
    echo ""
} > "$REPORT_FILE"

# Also print header to console
{
    echo "===== HMI DIAGNOSTICS REPORT ====="
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Target HMI: $HMI_IP (User: $HMI_USER)"
    echo "Report ID: $REPORT_ID"
    echo "MES Server: $MES_SERVER:$MES_PORT"
}
 
# Function to print section headers
print_header() {
    echo ""
    echo -e "${BLUE}--- $1 ---${NC}"
    echo "--- $1 ---" >> "$REPORT_FILE"
}
 
################################################################################
# 1. LOCAL NETWORK CHECK (Is the HMI on the wire?)
################################################################################
print_header "CONNECTIVITY CHECK"
 
if ping -c 5 -v "$HMI_IP" > /tmp/ping_output.txt 2>&1; then
    ping_stats=$(grep -oP '(?<=min/avg/max/stddev = )[^/]+' /tmp/ping_output.txt | cut -d'/' -f2)
    packet_loss=$(grep -oP '\d+(?=% packet loss)' /tmp/ping_output.txt)
    log_result "ok" "HMI is reachable" "Avg latency: ${ping_stats}ms, Packet loss: ${packet_loss}%"
else
    log_result "fail" "HMI unreachable - cannot continue diagnostics"
    echo "Stopping script - no network connectivity to HMI."
    exit 1
fi
 
# Check for oversized/fragmented packets (for lag investigation)
# Note: This is a baseline check; packet fragmentation typically happens at network level
log_result "info" "Ping packet check complete" "See logs for detailed packet analysis if needed"
 
# Save ping output to file for reference
cp /tmp/ping_output.txt "$LOG_DIR/ping_detailed.txt"
 
################################################################################
# 2. SSH CONNECTIVITY & REMOTE SYSTEM HEALTH
################################################################################
print_header "REMOTE SYSTEM HEALTH"
 
# SSH key auth notes (commented for future reference)
# To use SSH key instead of password:
# 1. Generate key: ssh-keygen -t ed25519 -f ~/.ssh/hmi_key -N ""
# 2. Add public key to HMI: ssh-copy-id -i ~/.ssh/hmi_key.pub ${HMI_USER}@${HMI_IP}
# 3. Update config: SSH_KEY_PATH="~/.ssh/hmi_key"
# 4. Use flag: ssh -i ${SSH_KEY_PATH} ...
# Note: Requires IT coordination for multi-user SSH key management
 
# Alternative: Use expect for password automation (less secure, not recommended for production)
# Alternative: Use SSH with timeout to avoid hangs
 
# Run remote diagnostics via SSH
# Using 'here document' (EOF) to execute multiple commands remotely
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HMI_USER}@${HMI_IP}" << 'REMOTE_EOF' > /tmp/remote_diagnostics.txt 2>&1
    echo "=== UPTIME & LOAD ==="
    uptime
    echo ""
    echo "=== MEMORY USAGE ==="
    free -h
    echo ""
    echo "=== CPU USAGE (top - one iteration) ==="
    top -bn1 -n1 | head -20
    echo ""
    echo "=== DISK USAGE ==="
    df -h
    echo ""
    echo "=== KERNEL & SYSTEM INFO ==="
    uname -a
    echo ""
    echo "=== RUNNING PROCESSES (Optix/FactoryTalk) ==="
    ps aux | grep -iE 'optix|factorytalk|spinalx|mars' | grep -v grep
    echo ""
    echo "=== SYSTEMD SERVICES (if applicable) ==="
    systemctl status optix.service 2>/dev/null || echo "optix.service not found or not running"
    systemctl status factorytalk.service 2>/dev/null || echo "factorytalk.service not found or not running"
    systemctl status spinalx.service 2>/dev/null || echo "spinalx.service not found or not running"
    echo ""
    echo "=== DMESG (last 10 lines - kernel errors/warnings) ==="
    dmesg | tail -10
REMOTE_EOF
 
if [[ $? -eq 0 ]]; then
    log_result "ok" "SSH connection successful"
    
    # Parse and display key metrics
    uptime_line=$(grep "up" /tmp/remote_diagnostics.txt | head -1)
    log_result "info" "System uptime: $uptime_line"
    
    memory_line=$(grep "^Mem:" /tmp/remote_diagnostics.txt)
    log_result "info" "Memory: $memory_line"
    
    load_line=$(grep "load average" /tmp/remote_diagnostics.txt)
    log_result "info" "CPU load: $load_line"
    
    # Full output to file
    cat /tmp/remote_diagnostics.txt >> "$REPORT_FILE"
else
    log_result "fail" "SSH connection failed - cannot retrieve remote diagnostics"
    exit 1
fi
 
################################################################################
# 3. NETWORK CONNECTIVITY TO MES SERVER
################################################################################
print_header "MES SERVER CONNECTIVITY"
 
# SSH into HMI and test connectivity to MES server
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HMI_USER}@${HMI_IP}" << REMOTE_EOF > /tmp/mes_connectivity.txt 2>&1
    echo "=== Testing connectivity to MES Server: $MES_SERVER:$MES_PORT ==="
    
    # Using nc (netcat) - preferred for port testing
    # If nc is not available, netcat can be installed: apt-get install netcat-openbsd
    if command -v nc &> /dev/null; then
        echo "Testing with netcat (nc)..."
        nc -zv -w 3 $MES_SERVER $MES_PORT 2>&1
    else
        echo "nc not found. Attempting telnet (fallback)..."
        # Telnet timeout: install telnet if needed (apt-get install telnet)
        timeout 3 telnet $MES_SERVER $MES_PORT 2>&1 || echo "telnet failed or timed out"
    fi
    
    echo ""
    echo "=== Traceroute to MES Server ==="
    traceroute -m 10 -w 2 $MES_SERVER 2>&1 || echo "traceroute not available"
    
    echo ""
    echo "=== MTR latency check (if available) ==="
    # mtr provides continuous latency stats; -c = count, -r = report mode (non-interactive)
    mtr -c 10 -r $MES_SERVER 2>&1 || echo "mtr not installed"
    
    echo ""
    echo "=== Current network connections (ss) ==="
    ss -tunap 2>/dev/null | grep -E '(LISTEN|ESTABLISHED|CLOSE_WAIT)' || netstat -tunap 2>/dev/null || echo "Unable to retrieve connection state"
REMOTE_EOF
 
if [[ $? -eq 0 ]]; then
    log_result "ok" "MES connectivity check complete"
    cat /tmp/mes_connectivity.txt >> "$REPORT_FILE"
else
    log_result "warn" "MES connectivity check had issues - check logs"
    cat /tmp/mes_connectivity.txt >> "$REPORT_FILE"
fi
 
################################################################################
# 4. PORT STATUS CHECK (from local machine)
################################################################################
print_header "PORT STATUS (from local machine)"
 
# Check common MES ports from local perspective
# This helps identify if firewalls or routes are filtering traffic
declare -a PORTS=(443 80 5432 8080 27017 3306)
 
for port in "${PORTS[@]}"; do
    if nc -zv -w 2 "$HMI_IP" "$port" 2>/dev/null; then
        log_result "ok" "Port $port: Open"
    else
        log_result "warn" "Port $port: Closed/Filtered"
    fi
done
 
################################################################################
# 5. APPLICATION LOGS - LOCATION DISCOVERY & COLLECTION
################################################################################
print_header "APPLICATION LOGS"
 
# Attempt to find and retrieve application logs
# Common locations for Optix, FactoryTalk, SpinalX
# You'll need to verify actual log paths with your Tier 2 team
 
log_result "info" "Searching for application logs on HMI..."
 
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HMI_USER}@${HMI_IP}" << 'REMOTE_EOF' > /tmp/log_discovery.txt 2>&1
    echo "=== Searching for common log locations ==="
    
    # Check common directories
    for logdir in /var/log /opt/FactoryTalk/logs /home/admin/logs /opt/optix/logs /opt/spinalx/logs /var/log/optix_runtime; do
        if [[ -d "$logdir" ]]; then
            echo "Found: $logdir"
            ls -lah "$logdir" 2>/dev/null | head -10
            echo ""
        fi
    done
    
    # Check for specific log files
    echo "=== Checking for specific log files ==="
    for logfile in /var/log/optix_runtime.log /var/log/factorytalk.log /opt/FactoryTalk/logs/runtime.log /opt/optix/logs/app.log; do
        if [[ -f "$logfile" ]]; then
            echo "Found: $logfile ($(du -h "$logfile" | cut -f1))"
        fi
    done
REMOTE_EOF
 
cat /tmp/log_discovery.txt >> "$REPORT_FILE"
 
# Attempt to SCP logs (only small ones, to avoid slowdown)
log_result "info" "Attempting to retrieve application logs via SCP..."
 
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HMI_USER}@${HMI_IP}" << 'REMOTE_EOF' > /tmp/scp_targets.txt 2>&1
    # Find logs smaller than 50MB
    find /var/log /opt -name "*.log" -type f -size -50M 2>/dev/null | head -20
REMOTE_EOF
 
# SCP each discovered log
while IFS= read -r logfile; do
    if [[ -n "$logfile" && ! "$logfile" =~ "Find:" ]]; then
        if scp -o ConnectTimeout=5 "${HMI_USER}@${HMI_IP}:${logfile}" "$LOG_DIR/" 2>/dev/null; then
            log_result "ok" "Collected: $(basename "$logfile")"
        fi
    fi
done < /tmp/scp_targets.txt
 
# If large logs exist, note them but don't copy
log_result "info" "Large logs (>50MB) noted but not collected automatically"
log_result "info" "To retrieve manually: scp ${HMI_USER}@${HMI_IP}:/path/to/large.log ./"
 
################################################################################
# 6. SOFTWARE & FIRMWARE VERSION
################################################################################
print_header "SOFTWARE VERSIONS & UPDATE HISTORY"
 
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HMI_USER}@${HMI_IP}" << 'REMOTE_EOF' > /tmp/versions.txt 2>&1
    echo "=== Kernel Version ==="
    uname -r
    echo ""
    echo "=== OS Release Info ==="
    cat /etc/os-release 2>/dev/null || lsb_release -a 2>/dev/null || echo "Unable to determine OS"
    echo ""
    echo "=== Optix/FactoryTalk Version (if available) ==="
    optix --version 2>/dev/null || echo "optix CLI not found"
    factorytalk --version 2>/dev/null || echo "factorytalk CLI not found"
    spinalx --version 2>/dev/null || echo "spinalx CLI not found"
    echo ""
    echo "=== Package Manager Updates (apt history) ==="
    # Note: Requires root or sudo access
    cat /var/log/apt/history.log 2>/dev/null | tail -50 || echo "Unable to access apt history (requires sudo)"
    echo ""
    echo "=== Recent File Changes (logs, config) ==="
    find /opt /var/log -type f -newermt "7 days ago" 2>/dev/null | head -20 || echo "No recent changes found"
REMOTE_EOF
 
cat /tmp/versions.txt >> "$REPORT_FILE"
log_result "info" "Version info collected - see logs for details"
 
################################################################################
# 7. SYSTEMD JOURNAL (Recent errors/warnings)
################################################################################
print_header "RECENT SYSTEM ERRORS (systemd journal)"
 
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HMI_USER}@${HMI_IP}" << 'REMOTE_EOF' > /tmp/journal.txt 2>&1
    echo "=== Recent errors/warnings (last 50 lines) ==="
    journalctl -p err -n 50 2>/dev/null || echo "journalctl not available"
    echo ""
    echo "=== Last 20 lines of all logs ==="
    journalctl -n 20 2>/dev/null || echo "journalctl not available"
REMOTE_EOF
 
cat /tmp/journal.txt >> "$REPORT_FILE"
 
################################################################################
# 8. SUMMARY & RECOMMENDATIONS
################################################################################
print_header "SUMMARY & RECOMMENDATIONS"
 
{
    echo ""
    echo "Report Location: $LOG_DIR"
    echo "Collected Files:"
    ls -lh "$LOG_DIR" | awk 'NR>1 {print "  - " $9 " (" $5 ")"}'
    echo ""
    echo "NEXT STEPS FOR ESCALATION:"
    echo "1. Review this report for [✗] FAIL or [!] WARN indicators"
    echo "2. If lag/performance issues: Check MES connectivity and CPU load"
    echo "3. If application crashes: Review journal and application logs"
    echo "4. If network issues: Provide traceroute and MTR output to Network Team"
    echo "5. If app-specific errors: Forward application logs and versions to App Team"
    echo ""
} | tee -a "$REPORT_FILE"
 
{
    echo "===== END REPORT ====="
    echo "Report saved: $(date)"
} >> "$REPORT_FILE"
 
log_result "ok" "Diagnostics complete" "Report saved to $REPORT_FILE"
 
################################################################################
# 9. CLEANUP (optional - remove old logs)
################################################################################
# Remove logs older than retention days
if [[ "$LOG_RETENTION_DAYS" -gt 0 ]]; then
    find . -maxdepth 1 -name "hmi_logs_*" -type d -mtime +"$LOG_RETENTION_DAYS" -exec rm -rf {} \; 2>/dev/null
    log_result "info" "Cleaned up logs older than $LOG_RETENTION_DAYS days"
fi
 
echo ""
echo -e "${GREEN}Diagnostics script completed successfully.${NC}"
echo "Review report: $REPORT_FILE"