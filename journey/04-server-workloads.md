# Stage 4 — Server Workloads (FS-01, APP-01, SQL-01, WSUS-01)

## Goal

Deploy four Windows Server 2022 VMs on VLAN 200, domain-join them, and install their roles. These are the enterprise workload tier — file shares, web apps, SQL Server, and patch management.

---

## The pattern (repeat for all four)

All four follow the same flow: clone template → set hardware → start → OOBE → static IP → rename → domain join → install role.

```bash
# Clone from WS2022 template
qm clone 22201 <vmid> --name <name> --full 1 --storage vms-1tb

# Set hardware
qm set <vmid> --memory <ram> --balloon 0 --cores <cores> --cpu host \
  --net0 virtio,bridge=vmbr1,tag=200,firewall=0 \
  --onboot 1 --agent enabled=1

qm start <vmid>
```

After OOBE (set Administrator password via console):

```powershell
Rename-Computer -NewName <name> -Force; Restart-Computer -Force

# Set static IP on VLAN 200
New-NetIPAddress -InterfaceAlias (Get-NetAdapter|?{$_.Status -eq 'Up'}).Name `
    -IPAddress <ip> -PrefixLength 24 -DefaultGateway 10.10.2.1
Set-DnsClientServerAddress -InterfaceAlias (Get-NetAdapter|?{$_.Status -eq 'Up'}).Name `
    -ServerAddresses 10.10.1.10,10.10.1.11

# Domain join
Add-Computer -DomainName corp.lab -Credential (Get-Credential CORP\Administrator) `
    -OUPath 'OU=Servers,DC=corp,DC=lab' -Restart -Force
```

---

## VM specs

| VM | ID | RAM | Cores | Disk | IP |
|---|---|---|---|---|---|
| FS-01 | 22207 | 3 GB | 2 | 40 GB | 10.10.2.10 |
| APP-01 | 22208 | 4 GB | 2 | 40 GB | 10.10.2.11 |
| SQL-01 | 22209 | 6 GB | 4 | 60 GB | 10.10.2.12 |
| WSUS-01 | 22210 | 4 GB | 2 | 40 GB | 10.10.2.13 |

---

## FS-01 — File Server

```powershell
Install-WindowsFeature FS-FileServer,FS-DFS-Namespace,FS-DFS-Replication -IncludeManagementTools
New-SmbShare -Name Public -Path (New-Item C:\Shares\Public -ItemType Directory -Force).FullName `
    -FullAccess 'CORP\Domain Admins' -ChangeAccess 'CORP\Domain Users'
```

---

## APP-01 — IIS App Server

```powershell
Install-WindowsFeature Web-Server,Web-Asp-Net45,Web-Mgmt-Tools -IncludeManagementTools
```

---

## SQL-01 — SQL Server 2022 Developer

Attach the SQL Server 2022 Developer ISO via Proxmox UI, then run unattended setup:

```cmd
D:\setup.exe /Q /ACTION=Install /FEATURES=SQLEngine /INSTANCENAME=MSSQLSERVER `
  /SQLSVCACCOUNT="NT AUTHORITY\SYSTEM" /SQLSYSADMINACCOUNTS="CORP\Domain Admins" `
  /AGTSVCACCOUNT="NT AUTHORITY\SYSTEM" /IACCEPTSQLSERVERLICENSETERMS
```

---

## WSUS-01 — Patch Management

```powershell
Install-WindowsFeature UpdateServices -IncludeManagementTools
New-Item C:\WSUS -ItemType Directory -Force
& 'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall CONTENT_DIR=C:\WSUS
```

Initial WSUS sync takes 30–60 minutes. Configure products and classifications in the WSUS console before the first sync to avoid downloading everything.

---

## Blocker: WS2022 Evaluation edition

Every clone from template 22201 inherits the Evaluation edition with a 180-day activation timer.

**Fix:**

```powershell
DISM /Online /Set-Edition:ServerStandard /ProductKey:VDYBN-27WPP-V4HQT-9VMD4-VMK7H /AcceptEula /Quiet
```

Reboot when prompted. Use a KMS/MAK key for a licensed environment; the key above is a generic public key that converts the edition — you still need a valid license.

---

## Updating all servers via QEMU guest agent

Once guest agents are running, you can push Windows Update to all VMs from the Proxmox host without WinRM or network access — handy for initial patch runs:

```bash
# scripts/update-windows-servers.sh — runs on the Proxmox host
# Uses qm guest exec to fire PSWindowsUpdate on each VM asynchronously
bash scripts/run.sh scripts/update-windows-servers.sh
```

See [`scripts/update-windows-servers.sh`](../scripts/update-windows-servers.sh) for the full script.

---

## Lessons learned

| Issue | Fix |
|---|---|
| All WS2022 clones are Evaluation (180-day timer) | Convert with DISM post-install |
| DHCP authorization fails after feature install | Set `ConfigurationState=2` in registry, restart `dhcpserver` |
| Domain join fails with duplicate SID | Sysprep `/generalize` on the clone before joining |
