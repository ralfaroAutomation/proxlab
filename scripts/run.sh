#!/bin/bash
# Usage: bash scripts/run.sh <script>
# Runs a proxmox script on <proxmox-host> via SSH.
# Example: bash scripts/run.sh scripts/fix-dns-pihole.sh

set -euo pipefail

SCRIPT="${1:?Usage: bash scripts/run.sh <script>}"
sshpass -e ssh root@<mgmt-ip> bash < "$SCRIPT"
