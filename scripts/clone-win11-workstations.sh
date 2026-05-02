#!/bin/bash
# Run on <proxmox-host>: bash scripts/clone-win11-workstations.sh
# Converts win11-build (22212) to template, clones WS-01/02/03

set -euo pipefail

SRC=22212
TEMPLATE_NAME="win11-tmpl"

declare -A CLONES=(
    [22213]="WS-01"
    [22214]="WS-02"
    [22215]="WS-03"
)

echo "Converting $SRC to template..."
qm template $SRC
qm set $SRC --name $TEMPLATE_NAME
echo "Template ready: $TEMPLATE_NAME ($SRC)"

for VMID in $(echo "${!CLONES[@]}" | tr ' ' '\n' | sort -n); do
    NAME="${CLONES[$VMID]}"
    echo "Cloning $NAME ($VMID)..."
    qm clone $SRC $VMID --name $NAME --full
    echo "  $NAME done"
done

echo ""
echo "All clones complete. Configure each with:"
echo "  net0 -> vmbr1 tag=300 (VLAN)"
echo "  net1 -> vmbr0 (AZNET mgmt)"
echo "  Static IPs: WS-01=10.10.3.10, WS-02=10.10.3.11, WS-03=10.10.3.12"
echo "  Mgmt IPs:   WS-01=<mgmt-ip>, WS-02=107, WS-03=108"
