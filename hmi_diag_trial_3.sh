#!/bin/bash

#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#   HMI TIER 1 DIAGNOSTICS SCRIPT !!!!
#   Pull system health metrics for 
#   non-invasive tier 1 troubleshooting
#   
#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

set -euo pipefail

# colors for console feedback only
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
HMI_IP=""
HMI_USER="rivadmin"
MES_SERVER=""
MES_PORT=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --tgip) HMI_IP="$2"; shift 2 ;;
        --user) HMI_USER="$2"; shift 2 ;;
        --serv) MES_SERVER="$2"; shift 2 ;;
        --port) MES_PORT="$2"; shift 2 ;;
        *) echo -e "${RED}[ERROR] Unknown parameter: $1${NC}"; echo "Usage: $0 --tgip <IP> [--user USER] [--serv SERVER] [--port PORT]"; exit 1 ;;
    esac
done