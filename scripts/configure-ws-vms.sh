#!/bin/bash
# Configures network for WS-01/02/03 and boots them for OOBE + domain join.
# Run via: bash scripts/run.sh scripts/configure-ws-vms.sh

set -euo pipefail

declare -A VMS=(
    [22213]="WS-01"
    [22214]="WS-02"
    [22215]="WS-03"
)

declare -A MGMT_IPS=(
    [22213]="<mgmt-ip>"
    [22214]="<mgmt-ip>"
    [22215]="<mgmt-ip>"
)

for VMID in $(echo "${!VMS[@]}" | tr ' ' '\n' | sort -n); do
    NAME="${VMS[$VMID]}"
    MGMT="${MGMT_IPS[$VMID]}"
    echo "[$NAME] Configuring network..."
    qm set $VMID \
        --net0 virtio,bridge=vmbr1,tag=300 \
        --net1 virtio,bridge=vmbr0
    echo "[$NAME] Starting VM..."
    qm start $VMID
    echo "[$NAME] Started — complete OOBE, then set:"
    echo "         VLAN IP via DHCP (VLAN 300: 10.10.3.x) or static"
    echo "         Mgmt NIC: $MGMT/23, GW <mgmt-ip>, DNS <mgmt-ip>"
    echo ""
done

echo "All WS VMs started. Domain join after OOBE:"
echo "  Add-Computer -DomainName corp.lab -OUPath 'OU=Endpoints,DC=corp,DC=lab' -Restart"
