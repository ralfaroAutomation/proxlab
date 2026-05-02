#!/bin/bash
# Run on <proxmox-host>: bash scripts/update-windows-servers.sh
# Triggers Windows Update on all ProxLab WS2022 VMs via QEMU guest agent.
# VMs update and reboot in the background — no WinRM needed.

set -euo pipefail

declare -A VMS=(
    [22203]="DC-01"
    [22204]="DC-02"
    [22205]="PKI-01"
    [22207]="FS-01"
    [22208]="APP-01"
    [22209]="SQL-01"
    [22210]="WSUS-01"
)

PS_SCRIPT='
if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
    Install-Module PSWindowsUpdate -Force -Scope AllUsers -Confirm:$false | Out-Null
}
Import-Module PSWindowsUpdate -Force
$r = Install-WindowsUpdate -AcceptAll -AutoReboot -Confirm:$false
if ($r) { $r | Select-Object -ExpandProperty Title } else { "No updates." }
'

# PowerShell -EncodedCommand requires UTF-16LE base64
PS_ENCODED=$(printf '%s' "$PS_SCRIPT" | iconv -f UTF-8 -t UTF-16LE | base64 -w 0)

for VMID in $(echo "${!VMS[@]}" | tr ' ' '\n' | sort -n); do
    NAME="${VMS[$VMID]}"
    STATUS=$(qm status "$VMID" 2>/dev/null | awk '{print $2}')
    if [[ "$STATUS" != "running" ]]; then
        echo "[$NAME] skipped — VM is $STATUS"
        continue
    fi

    PID_JSON=$(qm guest exec "$VMID" -- \
        powershell.exe -NonInteractive -EncodedCommand "$PS_ENCODED" 2>&1)
    PID=$(echo "$PID_JSON" | grep -oP '"pid":\K[0-9]+' || echo "?")
    echo "[$NAME] queued  (vmid=$VMID pid=$PID)"
done

echo ""
echo "Updates running in background. VMs will auto-reboot if needed."
echo "Check output: qm guest exec-status <vmid> <pid>"
