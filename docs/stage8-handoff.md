# Stage 8 Handoff — Server Workloads (FS-01, APP-01, SQL-01, WSUS-01)

**Date:** 2026-05-01  
**Status:** VMs cloned and started, awaiting OOBE on each

---

## VM State at Handoff

All 4 VMs cloned from template 22201 (WS2022 sysprep), configured, and started:

| VM ID | Name | RAM | Cores | Disk | VLAN | Lab IP | AZNET mgmt IP |
|---|---|---|---|---|---|---|---|
| 22207 | FS-01 | 3 GB | 2 | 40 GB | 200 | 10.10.2.10/24 | <admin-net>.102 |
| 22208 | APP-01 | 4 GB | 2 | 40 GB | 200 | 10.10.2.11/24 | <admin-net>.103 |
| 22209 | SQL-01 | 6 GB | 4 | 60 GB | 200 | 10.10.2.12/24 | <admin-net>.104 |
| 22210 | WSUS-01 | 4 GB | 2 | 40 GB | 200 | 10.10.2.13/24 | <admin-net>.105 |

Each VM has:
- `net0`: vmbr1, tag=200 (VLAN 200 lab internal)
- `net1`: vmbr0 (AZNET management — for RDP access during setup)
- QEMU agent enabled in config
- `onboot 1`

DNS servers for lab NIC: 10.10.1.10 (DC-01), 10.10.1.11 (DC-02)  
Gateway for lab NIC: 10.10.2.1 (MikroTik VLAN 200 interface)  
Gateway for AZNET mgmt NIC: <admin-net>.1  
DNS for AZNET mgmt NIC: <admin-net>.21 (Pi-hole)

---

## Stage 8 — Full Procedure (repeat for each VM in order)

Do **one VM at a time**: FS-01 → APP-01 → SQL-01 → WSUS-01

---

### Phase A — OOBE (Proxmox console)

Open VM console in Proxmox web UI. Windows will boot into OOBE (first-run setup).

1. Select region: your region
2. Select keyboard layout
3. Set Administrator password (use your homelab standard password)
4. Wait for desktop to appear

---

### Phase B — Eval → ServerStandard conversion

In the Proxmox console, open CMD as Administrator:

```cmd
DISM /Online /Set-Edition:ServerStandard /ProductKey:VDYBN-27WPP-V4HQT-9VMD4-VMK7H /AcceptEula /Quiet
```

When prompted, type `y` and press Enter to reboot. Wait for reboot to complete and log back in.

---

### Phase C — Find AZNET IP (so you can switch to RDP)

After reboot, open PowerShell as Administrator in the console:

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Select InterfaceAlias, IPAddress
```

Look for the IP on `Ethernet 2` (the net1 management NIC). It will have gotten a DHCP address from AZNET. From your desktop/laptop, RDP to that IP as `Administrator`.

---

### Phase D — Static IPs and rename (via RDP)

Replace `10.10.2.XX` and `<admin-net>.1XX` with the values for this VM from the table above.

```powershell
# Lab NIC — Ethernet (net0, VLAN 200)
$labIP   = "10.10.2.10"       # change per VM
$mgmtIP  = "<admin-net>.102"   # change per VM
$vmName  = "FS-01"            # change per VM

New-NetIPAddress -InterfaceAlias "Ethernet" `
    -IPAddress $labIP -PrefixLength 24 -DefaultGateway 10.10.2.1
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" `
    -ServerAddresses 10.10.1.10,10.10.1.11

# AZNET management NIC — Ethernet 2 (net1)
# Remove DHCP address first, then set static
$mgmtIface = Get-NetAdapter | Where-Object { $_.Name -eq "Ethernet 2" }
$mgmtIface | Set-NetIPInterface -Dhcp Disabled
Remove-NetIPAddress -InterfaceAlias "Ethernet 2" -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceAlias "Ethernet 2" -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceAlias "Ethernet 2" `
    -IPAddress $mgmtIP -PrefixLength 23 -DefaultGateway <admin-net>.1
Set-DnsClientServerAddress -InterfaceAlias "Ethernet 2" `
    -ServerAddresses <admin-net>.21

# Rename and reboot
Rename-Computer -NewName $vmName -Restart -Force
```

After reboot, RDP back in on the static AZNET IP (<admin-net>.102 etc).

---

### Phase E — VirtIO drivers + QEMU agent

Open Device Manager and check for unknown devices. If vioserial is missing:

1. Open Device Manager → right-click unknown device → Update Driver
2. Browse to `D:\vioserial\2k22\amd64\` → Install

Install QEMU guest agent:
```powershell
Start-Process -FilePath "D:\guest-agent\qemu-ga-x86_64.msi" -ArgumentList "/quiet" -Wait
Start-Service QEMU-GA
Get-Service QEMU-GA
```

---

### Phase F — Domain join

```powershell
Add-Computer -DomainName corp.lab -Credential CORP\Administrator -Restart -Force
```

Enter CORP\Administrator password when prompted. VM reboots — log back in as `CORP\Administrator`.

---

### Phase G — Role install (as CORP\Administrator)

**FS-01:**
```powershell
Install-WindowsFeature FS-FileServer,FS-DFS-Namespace,FS-DFS-Replication -IncludeManagementTools
```

**APP-01:**
```powershell
Install-WindowsFeature Web-Server,Web-Asp-Net45,Web-Mgmt-Console,Web-Mgmt-Tools -IncludeManagementTools
```

**SQL-01:**
```powershell
# SQL Server 2022 must be installed from ISO — copy ISO from <file-server> or mount in Proxmox
# Basic role for now (SQL installer handles everything):
Install-WindowsFeature NET-Framework-45-Features -IncludeManagementTools
# Then run SQL Server 2022 installer from D:\ or mounted ISO
```

**WSUS-01:**
```powershell
Install-WindowsFeature UpdateServices -IncludeManagementTools
# Post-install config:
& 'C:\Program Files\Update Services\Tools\wsusutil.exe' postinstall CONTENT_DIR=C:\WSUS
Add-WsusServer -Name wsus-01.corp.lab -Port 8530 | Approve-WsusUpdate
```

---

### Phase H — Snapshot

After each VM is configured, take a snapshot from the Proxmox host:

```bash
# Run on <proxmox-host> for each VM
qm snapshot 22207 stage8-baseline --description "FS-01 domain joined, role installed"
qm snapshot 22208 stage8-baseline --description "APP-01 domain joined, role installed"
qm snapshot 22209 stage8-baseline --description "SQL-01 domain joined, role installed"
qm snapshot 22210 stage8-baseline --description "WSUS-01 domain joined, role installed"
```

---

## VLAN 200 DHCP Scope

Before Stage 9 (endpoints), add DHCP scope for VLAN 200 on DC-01:

```powershell
# Run on DC-01 as CORP\Administrator
Add-DhcpServerv4Scope -Name "VLAN200-Workloads" `
    -StartRange 10.10.2.100 -EndRange 10.10.2.200 `
    -SubnetMask 255.255.255.0 -State Active

Set-DhcpServerv4OptionValue -ScopeId 10.10.2.0 `
    -Router 10.10.2.1 `
    -DnsServer 10.10.1.10,10.10.1.11 `
    -DnsDomain corp.lab
```

---

## Pending After Stage 8

- [ ] Stage 9: Endpoints — WS-01/02/03 (Win11), LX-01 (Ubuntu SSSD), LX-02 (Debian SSSD), ATK-01 (Kali)
- [ ] Stage 10: DMZ — VULN-01 (Metasploitable), VULN-02 (DVWA)
- [ ] Stage 11: claude-lxc integration — create svc-claude-ro + svc-claude-rw in AD, generate keytabs, configure WinRM, test MCP tools
- [ ] Remove temp management NICs from DC-01 (net1) and SIEM-01 (net1) once fully set up
- [ ] Install QEMU agent on SIEM-01 (Ubuntu — `apt install qemu-guest-agent && systemctl enable --now qemu-guest-agent`)

---

## Key Reference

- Proxmox host: `sshpass -e ssh root@<admin-net>.222`
- SSHPASS set in `~/.bashrc` on claude-agent (<admin-net>.27)
- Full credentials: `/home/projects/homelab/CREDENTIALS.md` (gitignored)
- Deployment plan: `/home/projects/homelab/plans/proxlab-deployment.md`
- Architecture: `/home/projects/homelab/plans/proxlab-architecture.md`
- Troubleshooting log: `/home/projects/homelab/docs/troubleshooting.md`
