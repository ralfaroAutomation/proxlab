# ProxLab Deployment Plan — <proxmox-host>
**Host:** <proxmox-host>.<your-domain> — <admin-net>.222
**Hardware:** Lenovo ThinkStation S30 V1 — Xeon E5-2650L, 128 GB ECC, Proxmox VE 9.1.1
**Started:** 2026-04-30
**Reference:** `proxlab-context.md` for full topology, VM specs, AD domain, and operating rules

---

## Stage 0 — Infrastructure Prep

### Storage ✅ DONE
- [x] Wipe old `pve-OLD-33F55561` LVM (6 orphaned VMs destroyed)
- [x] Wipe Windows partition table on nvme0n1 (T-Force 512 GB)
- [x] Create LVM-thin pool `vms-1tb` on nvme1n1 (1 TB Intel) — 953 GB available
- [x] Create LVM-thin pool `vms-512gb` on nvme0n1 (512 GB T-Force) — 476 GB available
- [x] Register both pools in Proxmox (`pvesm add lvmthin`)

### ISOs
- [x] `virtio-win.iso` — 693 MB (VirtIO drivers for Windows VMs)
- [x] `Win10Pro_debloated.iso` — 4.0 GB (Windows 10 endpoints)
- [x] `Windows-11eng-us.iso` — 5.3 GB (Windows 11 endpoints)
- [x] `ubuntu-24.04.2-desktop-amd64.iso` — 6.0 GB (Linux VMs)
- [x] `win2022.iso` — 4.9 GB ✅

---

## Stage 1 — Network Setup ✅ DONE

- [x] Create `vmbr1` — VLAN-aware bridge, bridge-vids 2-4094, up and active
- [x] Verify `vmbr0` (management, <admin-net>.222/23) still up after vmbr1 added
- [ ] Confirm ProxLab lab subnets routed on vmbr1 (internal only, no AlzaNet access):

  | VLAN | Subnet | Purpose |
  |---|---|---|
  | native | `10.0.0.0/24` | Proxmox management |
  | 100 | `10.10.1.0/24` | Core identity (AD, DNS, PKI, SIEM) |
  | 200 | `10.10.2.0/24` | Server workloads (FS, APP, SQL, WSUS) |
  | 300 | `10.10.3.0/24` | Endpoints (Windows/Linux clients, Kali) |
  | 400 | `10.10.4.0/24` | DMZ / vuln targets (isolated) |

---

## Stage 2 — Templates

### VM ID convention — <proxmox-host>
All VMs/LXCs on <proxmox-host> use IDs starting with 222xx:
- 22200 = Ubuntu 24.04 cloud-init template ✅
- 22201 = Windows Server 2022 template (pending)
- 22202 = claude-lxc
- 22203 = DC-01, 22204 = DC-02, 22205 = PKI-01 ...and so on sequentially

- [x] Build Ubuntu 24.04 cloud-init template — **ID 22200** `ubuntu-2404-tmpl` on `vms-1tb`
  - q35, OVMF/UEFI, virtio-scsi, cloud-init drive, DNS → Pi-hole .10.21

- [ ] Prepare Windows Server 2022 sysprep base — **ID 22201**
  - Create VM from `win2022.iso` + `virtio-win.iso`
  - Install VirtIO storage + network drivers during setup
  - Install QEMU Guest Agent post-install
  - Run sysprep `/generalize /shutdown`
  - Convert to template

---

## Stage 3 — Phase 1: Foundation (claude-lxc)

*Deploy the AI operations LXC container first — used to manage and verify everything else.*

- [x] Create `claude-lxc` (LXC, Ubuntu 24.04, 4 GB RAM, CT 22202)
  - eth0: vmbr1, `10.10.0.50/24`, gw `10.0.0.1` (lab internal)
  - eth1: vmbr0, `<admin-net>.100/23`, gw `<admin-net>.1` (AZNET mgmt / internet)
  - Storage: vms-512gb, 20 GB rootfs, privileged, nesting=1, onboot=1
  - **IP range rule**: ProxLab VMs/LXCs on AZNET use `<admin-net>.100–199`
- [x] Install tool stack inside claude-lxc (apt + pip + ansible-galaxy):
  - nmap, ansible, python3-pip, sshpass, krb5-user, ldap-utils, git, jq, dnsutils
  - pip: ldap3 2.9.1, pywinrm 0.4.3, impacket 0.13.0, paramiko 4.0.0, requests 2.33.1, httpx 0.28.1, python-nmap 0.7.1
  - ansible collections: community.windows, community.general (pre-installed with ansible pkg)
  - Note: impacket required `--ignore-installed cryptography` due to Debian-managed system package
  - Added `/usr/local/bin` to PATH and `LANG=C.UTF-8` to /root/.bashrc (ansible locale fix)
- [x] Create `/var/log/claude-agent/actions.log` (append-only audit log, chmod 700)
- [x] Create `/opt/claude-agent/` directory structure (playbooks/, inventory/)
- [x] Verify claude-lxc can reach management network (ping <admin-net>.222 ✅)

---

## Stage 3.5 — Cleanup (wrong ISO-based VMs) ✅ DONE

- [x] Destroyed ISO-based 22203/22204 and purged disks — IDs freed

---

## Stage 4 — DC-01 (Primary DC)

*Clone from sysprep'd template 22201 — never install from ISO.*

### 4.1 Clone and configure

- [x] Clone template to VM 22203, set hardware, VLAN 100, started ✅
- [x] Complete OOBE via noVNC console — set Administrator password
- [x] Set static IP and rename (PowerShell on DC-01 console):
  ```powershell
  Rename-Computer -NewName DC-01 -Force
  $if = (Get-NetAdapter | Where-Object Status -eq 'Up').Name
  New-NetIPAddress -InterfaceAlias $if -IPAddress 10.10.1.10 -PrefixLength 24 -DefaultGateway 10.10.1.1
  Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses 127.0.0.1,10.10.1.11
  Set-TimeZone -Id 'UTC'
  Restart-Computer -Force
  ```
- [ ] Verify QEMU agent responds:
  ```bash
  qm agent 22203 ping && qm agent 22203 network-get-interfaces
  ```

### 4.2 Promote to forest root DC

- [ ] Install AD DS, DNS, DHCP and promote to new forest at FFL/DFL 2016:
  ```powershell
  Install-WindowsFeature AD-Domain-Services,DNS,DHCP -IncludeManagementTools
  Import-Module ADDSDeployment
  $dsrm = ConvertTo-SecureString 'ChangeMe-DSRM-2026!' -AsPlainText -Force
  Install-ADDSForest `
      -DomainName 'corp.lab' -DomainNetbiosName 'CORP' `
      -ForestMode 'WinThreshold' -DomainMode 'WinThreshold' `
      -InstallDns:$true -SafeModeAdministratorPassword $dsrm `
      -NoRebootOnCompletion:$false -Force:$true
  ```
- [ ] After reboot, log in as `CORP\Administrator` and verify:
  ```powershell
  Get-ADDomain; Get-ADForest
  Get-Service ADWS,KDC,Netlogon,DNS | Format-Table Name,Status
  dcdiag /q
  ```

### 4.3 DHCP, DNS forwarders, reverse zone

- [ ] Configure DHCP scope for VLAN 100:
  ```powershell
  Add-DhcpServerInDC -DnsName dc-01.corp.lab -IPAddress 10.10.1.10
  Add-DhcpServerv4Scope -Name 'VLAN100-Identity' -StartRange 10.10.1.100 -EndRange 10.10.1.199 -SubnetMask 255.255.255.0 -State Active
  Set-DhcpServerv4OptionValue -ScopeId 10.10.1.0 -Router 10.10.1.1 -DnsServer 10.10.1.10,10.10.1.11 -DnsDomain corp.lab
  ```
- [ ] Set DNS forwarder to Pi-hole for external resolution:
  ```powershell
  Set-DnsServerForwarder -IPAddress <admin-net>.21 -UseRootHint $false
  Add-DnsServerPrimaryZone -NetworkId '10.10.1.0/24' -ReplicationScope Forest
  ```

### 4.4 OU structure and groups

- [ ] Create OUs and AI security groups:
  ```powershell
  New-ADOrganizationalUnit -Name Servers         -Path 'DC=corp,DC=lab'
  New-ADOrganizationalUnit -Name Endpoints       -Path 'DC=corp,DC=lab'
  New-ADOrganizationalUnit -Name ServiceAccounts -Path 'DC=corp,DC=lab'
  New-ADOrganizationalUnit -Name Groups          -Path 'DC=corp,DC=lab'
  New-ADGroup -Name GRP-Claude-Scan -GroupScope Global -Path 'OU=Groups,DC=corp,DC=lab'
  New-ADGroup -Name GRP-Claude-Resp -GroupScope Global -Path 'OU=Groups,DC=corp,DC=lab'
  New-ADGroup -Name GRP-AI-Audit    -GroupScope Global -Path 'OU=Groups,DC=corp,DC=lab'
  ```
- [ ] Snapshot DC-01:
  ```bash
  qm snapshot 22203 post-promote --description "DC-01 promoted, OUs created"
  ```

---

## Stage 5 — DC-02 (Secondary DC)

- [x] Clone 22201 → 22204, configured: 3 GB RAM, VLAN 100, onboot=1 ✅ (not yet started)
- [ ] OOBE, then set IP pointing DNS at DC-01:
  ```powershell
  Rename-Computer -NewName DC-02 -Force
  $if = (Get-NetAdapter | Where-Object Status -eq 'Up').Name
  New-NetIPAddress -InterfaceAlias $if -IPAddress 10.10.1.11 -PrefixLength 24 -DefaultGateway 10.10.1.1
  Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses 10.10.1.10
  Restart-Computer -Force
  ```
- [ ] Join domain and promote as additional DC:
  ```powershell
  Add-Computer -DomainName corp.lab -Credential (Get-Credential CORP\Administrator) -Restart -Force
  # After reboot, as CORP\Administrator:
  Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools
  $dsrm = ConvertTo-SecureString 'ChangeMe-DSRM-2026!' -AsPlainText -Force
  Install-ADDSDomainController -DomainName 'corp.lab' -InstallDns:$true `
      -Credential (Get-Credential CORP\Administrator) `
      -SafeModeAdministratorPassword $dsrm -Force:$true
  ```
- [ ] Update DNS client on DC-02 to prefer itself, then DC-01:
  ```powershell
  Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses 10.10.1.11,10.10.1.10
  ```
- [ ] Verify replication:
  ```powershell
  repadmin /replsummary; repadmin /showrepl
  dcdiag /test:replications /test:dns
  ```
- [ ] Snapshot: `qm snapshot 22204 post-promote`

---

## Stage 6 — PKI-01 (Enterprise CA)

- [ ] Clone, configure, domain-join:
  ```bash
  qm clone 22201 22205 --name PKI-01 --full 1 --storage vms-1tb
  qm set 22205 --memory 3072 --balloon 0 --cores 2 --cpu host
  qm set 22205 --net0 virtio,bridge=vmbr1,tag=100,firewall=0
  qm set 22205 --onboot 1 --agent enabled=1
  qm start 22205
  ```
  ```powershell
  Rename-Computer -NewName PKI-01 -Force
  New-NetIPAddress -InterfaceAlias (Get-NetAdapter|?{$_.Status -eq 'Up'}).Name -IPAddress 10.10.1.12 -PrefixLength 24 -DefaultGateway 10.10.1.1
  Set-DnsClientServerAddress -InterfaceAlias (Get-NetAdapter|?{$_.Status -eq 'Up'}).Name -ServerAddresses 10.10.1.10,10.10.1.11
  Restart-Computer -Force
  Add-Computer -DomainName corp.lab -Credential (Get-Credential CORP\Administrator) -OUPath 'OU=Servers,DC=corp,DC=lab' -Restart -Force
  ```
- [ ] Install Enterprise Root CA:
  ```powershell
  Install-WindowsFeature ADCS-Cert-Authority,ADCS-Web-Enrollment -IncludeManagementTools
  Install-AdcsCertificationAuthority -CAType EnterpriseRootCa -CACommonName 'CORP-LAB-Root-CA' `
      -KeyLength 4096 -HashAlgorithmName SHA256 -ValidityPeriod Years -ValidityPeriodUnits 10 -Force
  Install-AdcsWebEnrollment -Force
  ```
- [ ] Issue DC certs to enable LDAPS (auto-enroll via DomainController template), then restart NTDS on both DCs
- [ ] Verify LDAPS from claude-lxc:
  ```bash
  openssl s_client -connect dc-01.corp.lab:636 -showcerts </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer
  ```

---

## Stage 7 — SIEM-01 (Wazuh + OpenSearch)

*Can run in parallel with Stage 6 — no AD dependency.*

- [ ] Clone Ubuntu template 22200, resize to 60 GB:
  ```bash
  qm clone 22200 22206 --name SIEM-01 --full 1 --storage vms-1tb
  qm set 22206 --memory 8192 --balloon 0 --cores 4 --cpu host
  qm set 22206 --net0 virtio,bridge=vmbr1,tag=100,firewall=0
  qm set 22206 --onboot 1 --agent enabled=1
  qm resize 22206 scsi0 60G
  qm set 22206 --ipconfig0 ip=10.10.1.20/24,gw=10.10.1.1
  qm set 22206 --nameserver 10.10.1.10 --searchdomain corp.lab
  qm set 22206 --ciuser ubuntu --sshkeys /root/.ssh/authorized_keys
  qm cloudinit update 22206
  qm start 22206
  ```
- [ ] From claude-lxc verify SSH, then install Wazuh all-in-one:
  ```bash
  ssh ubuntu@10.10.1.20 'sudo hostnamectl set-hostname siem-01.corp.lab'
  ssh ubuntu@10.10.1.20 'curl -sO https://packages.wazuh.com/4.9/wazuh-install.sh && sudo bash wazuh-install.sh -a'
  ```
- [ ] Save admin credentials: `scp ubuntu@10.10.1.20:/tmp/wazuh-install-files.tar /opt/claude-agent/secrets/`
- [ ] Verify dashboard: `curl -ks https://10.10.1.20 -o /dev/null -w '%{http_code}\n'` → 200
- [ ] Snapshot: `qm snapshot 22206 post-install`

---

## Stage 8 — Server Workloads (VLAN 200)

*Deploy after AD is replicated. All four follow: clone → set → start → OOBE → IP → domain-join → role.*

### 8.1 FS-01 (22207) — File Server

- [ ] ```bash
  qm clone 22201 22207 --name FS-01 --full 1 --storage vms-1tb
  qm set 22207 --memory 3072 --balloon 0 --cores 2 --cpu host --net0 virtio,bridge=vmbr1,tag=200,firewall=0 --onboot 1 --agent enabled=1
  qm start 22207
  ```
  ```powershell
  Rename-Computer -NewName FS-01 -Force; Restart-Computer -Force
  New-NetIPAddress -InterfaceAlias (Get-NetAdapter|?{$_.Status -eq 'Up'}).Name -IPAddress 10.10.2.10 -PrefixLength 24 -DefaultGateway 10.10.2.1
  Set-DnsClientServerAddress -InterfaceAlias (Get-NetAdapter|?{$_.Status -eq 'Up'}).Name -ServerAddresses 10.10.1.10,10.10.1.11
  Add-Computer -DomainName corp.lab -Credential (Get-Credential CORP\Administrator) -OUPath 'OU=Servers,DC=corp,DC=lab' -Restart -Force
  Install-WindowsFeature FS-FileServer,FS-DFS-Namespace,FS-DFS-Replication -IncludeManagementTools
  New-SmbShare -Name Public -Path (New-Item C:\Shares\Public -ItemType Directory -Force).FullName -FullAccess 'CORP\Domain Admins' -ChangeAccess 'CORP\Domain Users'
  ```

### 8.2 APP-01 (22208) — IIS App Server

- [ ] ```bash
  qm clone 22201 22208 --name APP-01 --full 1 --storage vms-1tb
  qm set 22208 --memory 4096 --balloon 0 --cores 2 --cpu host --net0 virtio,bridge=vmbr1,tag=200,firewall=0 --onboot 1 --agent enabled=1
  qm start 22208
  ```
  ```powershell
  Rename-Computer -NewName APP-01 -Force; Restart-Computer -Force
  # (set IP 10.10.2.11, DNS, restart, domain-join, then:)
  Install-WindowsFeature Web-Server,Web-Asp-Net45,Web-Mgmt-Tools -IncludeManagementTools
  ```

### 8.3 SQL-01 (22209) — SQL Server 2022 Dev

- [ ] ```bash
  qm clone 22201 22209 --name SQL-01 --full 1 --storage vms-1tb
  qm set 22209 --memory 6144 --balloon 0 --cores 4 --cpu host --net0 virtio,bridge=vmbr1,tag=200,firewall=0 --onboot 1 --agent enabled=1
  qm resize 22209 scsi0 60G
  qm start 22209
  ```
  Set IP 10.10.2.12, domain-join, attach SQL Server 2022 Developer ISO via Proxmox GUI, run unattended setup.

### 8.4 WSUS-01 (22210) — Patch Management

- [ ] ```bash
  qm clone 22201 22210 --name WSUS-01 --full 1 --storage vms-1tb
  qm set 22210 --memory 4096 --balloon 0 --cores 2 --cpu host --net0 virtio,bridge=vmbr1,tag=200,firewall=0 --onboot 1 --agent enabled=1
  qm start 22210
  ```
  ```powershell
  # Set IP 10.10.2.13, domain-join, then:
  Install-WindowsFeature UpdateServices -IncludeManagementTools
  New-Item C:\WSUS -ItemType Directory -Force
  & 'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall CONTENT_DIR=C:\WSUS
  ```

### 8.5 Add VLAN 200 DHCP scope and validate from claude-lxc

- [ ] ```powershell
  Add-DhcpServerv4Scope -Name 'VLAN200-Servers' -StartRange 10.10.2.100 -EndRange 10.10.2.199 -SubnetMask 255.255.255.0 -State Active
  Set-DhcpServerv4OptionValue -ScopeId 10.10.2.0 -Router 10.10.2.1 -DnsServer 10.10.1.10,10.10.1.11 -DnsDomain corp.lab
  ```
- [ ] From claude-lxc, LDAPS query and WinRM health check against FS-01

---

## Stage 9 — Endpoints (VLAN 300)

### 9.1 WS-01, WS-02, WS-03 (Win 11, from ISO — no template)

- [ ] ```bash
  for ID in 22211 22212 22213; do
    N=$((ID-22210))
    qm create $ID --name "WS-$(printf '%02d' $N)" --memory 3072 --balloon 0 --cores 2 --cpu host \
      --machine q35 --bios ovmf \
      --efidisk0 vms-512gb:1,format=raw,efitype=4m,pre-enrolled-keys=1 \
      --tpmstate0 vms-512gb:1,version=v2.0 \
      --scsihw virtio-scsi-single \
      --scsi0 vms-512gb:40,discard=on,ssd=1,iothread=1 \
      --ide2 local:iso/Windows-11eng-us.iso,media=cdrom \
      --ide0 local:iso/virtio-win.iso,media=cdrom \
      --net0 virtio,bridge=vmbr1,tag=300,firewall=0 \
      --ostype win11 --agent enabled=1 --onboot 1 \
      --boot order='ide2;scsi0'
  done
  ```
- [ ] Boot each, load VirtIO driver from D:\amd64\w11 during setup, set static IPs 10.10.3.10–12
- [ ] Domain-join each: `Add-Computer -DomainName corp.lab -OUPath 'OU=Endpoints,DC=corp,DC=lab'`

### 9.2 LX-01 (Ubuntu 24.04, clone 22200 → 22214)

- [ ] ```bash
  qm clone 22200 22214 --name LX-01 --full 1 --storage vms-512gb
  qm set 22214 --memory 1024 --balloon 0 --cores 1 --cpu host --net0 virtio,bridge=vmbr1,tag=300,firewall=0
  qm set 22214 --ipconfig0 ip=10.10.3.20/24,gw=10.10.3.1 --nameserver 10.10.1.10 --searchdomain corp.lab
  qm set 22214 --onboot 1 --agent enabled=1; qm cloudinit update 22214; qm start 22214
  ```
- [ ] AD-join via realmd: `sudo realm join --user=Administrator corp.lab`

### 9.3 LX-02 (Debian 12, from ISO — 22215)

- [ ] Download Debian 12 netinst to ISO storage if not present, create VM with VLAN 300, install manually, IP 10.10.3.21
- [ ] AD-join via realmd (same as LX-01)

### 9.4 ATK-01 (Kali Linux, from ISO — 22216)

- [ ] Download Kali ISO to ISO storage, create VM with VLAN 300, install with static IP 10.10.3.30 — no AD join
- [ ] Copy claude-lxc SSH pubkey to ATK-01 for remote ops

### 9.5 VLAN 300 DHCP scope on DC-01

- [ ] ```powershell
  Add-DhcpServerv4Scope -Name 'VLAN300-Endpoints' -StartRange 10.10.3.100 -EndRange 10.10.3.199 -SubnetMask 255.255.255.0 -State Active
  Set-DhcpServerv4OptionValue -ScopeId 10.10.3.0 -Router 10.10.3.1 -DnsServer 10.10.1.10,10.10.1.11 -DnsDomain corp.lab
  ```

---

## Stage 10 — DMZ / Vuln Targets (VLAN 400)

*Isolated — only ATK-01 should reach this VLAN. Enforce on MikroTik/vmbr1 separately.*

### 10.1 VULN-01 — Metasploitable 2 (22217)

- [ ] Download Metasploitable VMDK, import and configure on VLAN 400 with no onboot:
  ```bash
  qm create 22217 --name VULN-01 --memory 1024 --cores 1 --cpu host --machine pc \
    --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr1,tag=400,firewall=0 --ostype l26 --onboot 0
  qm importdisk 22217 /path/to/Metasploitable.vmdk vms-512gb --format qcow2
  qm set 22217 --scsi0 vms-512gb:vm-22217-disk-0 --boot order=scsi0
  ```
- [ ] Set static IP 10.10.4.10/24 inside the VM

### 10.2 VULN-02 — DVWA on Debian (22218)

- [ ] Create from Debian 12 netinst on VLAN 400, onboot=0, static IP 10.10.4.11
- [ ] Install DVWA: `apt install apache2 php php-mysqli mariadb-server git && cd /var/www/html && git clone https://github.com/digininja/DVWA.git`

### 10.3 Additional SecOps targets (from <file-server> — see references/fileserver-<file-server>.md)

Deploy selectively as needed. ISOs at `/media/drives/12tb/backup_dataset4/ordered/tech/software/_OS_installers/` on <file-server>.

| Target | Key CVEs |
|---|---|
| Windows XP | MS08-067, EternalBlue, SMBv1 |
| Windows 7 | MS17-010, pass-the-hash, Mimikatz |
| Windows 8.1 | UAC bypasses, Kerberoasting |
| Server 2012 R2 | DCSync, legacy AD attacks |
| Ubuntu 16.04 | Dirty COW, privesc CVEs |

### 10.4 Verify VLAN 400 isolation

- [ ] From claude-lxc → VULN-01: should FAIL
- [ ] From ATK-01 → VULN-01: should succeed (allow rule on MikroTik)
- [ ] `scan_host` MCP tool: `nmap -sV 10.10.4.0/24 --open`

---

## Stage 11 — claude-lxc Integration (Kerberos + MCP)

### 11.1 Service accounts on DC-01

- [ ] Create accounts in `OU=ServiceAccounts`, rw disabled by default:
  ```powershell
  $pwRO = ConvertTo-SecureString 'ChangeMe-RO-2026!' -AsPlainText -Force
  $pwRW = ConvertTo-SecureString 'ChangeMe-RW-2026!' -AsPlainText -Force
  New-ADUser -Name svc-claude-ro -SamAccountName svc-claude-ro -UserPrincipalName svc-claude-ro@corp.lab -Path 'OU=ServiceAccounts,DC=corp,DC=lab' -AccountPassword $pwRO -Enabled $true -PasswordNeverExpires $true
  New-ADUser -Name svc-claude-rw -SamAccountName svc-claude-rw -UserPrincipalName svc-claude-rw@corp.lab -Path 'OU=ServiceAccounts,DC=corp,DC=lab' -AccountPassword $pwRW -Enabled $false -PasswordNeverExpires $true
  Add-ADGroupMember -Identity GRP-Claude-Scan -Members svc-claude-ro
  Add-ADGroupMember -Identity GRP-Claude-Resp -Members svc-claude-rw
  ```

### 11.2 Generate keytabs and copy to claude-lxc

- [ ] On DC-01 generate keytabs:
  ```powershell
  ktpass -princ svc-claude-ro@CORP.LAB -mapuser CORP\svc-claude-ro -pass 'ChangeMe-RO-2026!' -ptype KRB5_NT_PRINCIPAL -crypto AES256-SHA1 -out C:\svc-claude-ro.keytab
  ktpass -princ svc-claude-rw@CORP.LAB -mapuser CORP\svc-claude-rw -pass 'ChangeMe-RW-2026!' -ptype KRB5_NT_PRINCIPAL -crypto AES256-SHA1 -out C:\svc-claude-rw.keytab
  ```
- [ ] Pull keytabs from claude-lxc via SMB:
  ```bash
  mkdir -p /etc/krb5
  smbclient //dc-01.corp.lab/c$ -U CORP/Administrator -c 'get svc-claude-ro.keytab /etc/krb5/svc-claude-ro.keytab'
  smbclient //dc-01.corp.lab/c$ -U CORP/Administrator -c 'get svc-claude-rw.keytab /etc/krb5/svc-claude-rw.keytab'
  chmod 600 /etc/krb5/svc-claude-*.keytab
  ```

### 11.3 Configure /etc/krb5.conf on claude-lxc

- [ ] Write `/etc/krb5.conf`:
  ```ini
  [libdefaults]
      default_realm = CORP.LAB
      dns_lookup_realm = false
      dns_lookup_kdc = true
  [realms]
      CORP.LAB = {
          kdc = dc-01.corp.lab
          kdc = dc-02.corp.lab
          admin_server = dc-01.corp.lab
      }
  [domain_realm]
      .corp.lab = CORP.LAB
      corp.lab  = CORP.LAB
  ```
- [ ] Point systemd-resolved at DC-01 for corp.lab DNS

### 11.4 Validate all MCP tools

- [ ] `kinit -kt /etc/krb5/svc-claude-ro.keytab svc-claude-ro@CORP.LAB && klist`
- [ ] LDAPS query: `ldapsearch -H ldaps://dc-01.corp.lab -Y GSSAPI -b "DC=corp,DC=lab" "(objectClass=user)" sAMAccountName`
- [ ] WinRM against FS-01 via Kerberos (pywinrm)
- [ ] Wazuh REST API call (`get_siem_alerts`)
- [ ] Nmap DMZ scan (`scan_host 10.10.4.0/24`)

### 11.5 Responder mode dry-run

- [ ] Enable `svc-claude-rw` on DC-01 for test session
- [ ] Restart Spooler on FS-01 via WinRM + log to `/var/log/claude-agent/actions.log`
- [ ] Disable `svc-claude-rw` immediately after
- [ ] Test `run_ansible_playbook` with a ping playbook against LX-01

### 11.6 Wazuh agent rollout

- [ ] Push Wazuh agent to all Windows VMs via PowerShell remoting
- [ ] Push to LX-01/LX-02 via Ansible
- [ ] Verify all agents Active in Wazuh dashboard

### 11.7 Snapshot all VMs

- [ ] ```bash
  for ID in 22203 22204 22205 22206 22207 22208 22209 22210 22211 22212 22213 22214 22215 22216; do
    qm snapshot $ID post-deploy --description "Initial deploy complete" || true
  done
  ```

---

## SecOps Scenario (Stage 12)

- [ ] ATK-01 → VULN-01: run Metasploit exploit
- [ ] Verify Wazuh detects the attack and fires alert
- [ ] claude-lxc (Analyst mode) explains kill chain, CVSS score, blast radius
- [ ] `isolate_host` MCP tool blocks VULN-01 traffic via firewall rule

---

## RAM budget (128 GB total)

| Allocation | GB |
|---|---|
| ProxLab VMs total (all stages) | ~56 GB |
| ZFS ARC + OS overhead | ~20 GB |
| Headroom / future expansion | ~52 GB |

## Storage budget (~1.6 TB total)

| Pool | Size | Primary use |
|---|---|---|
| `vms-1tb` | 953 GB | DC-01, DC-02, server workloads, SIEM |
| `vms-512gb` | 476 GB | Endpoints, DMZ VMs, claude-lxc |
| `local-lvm` (sda) | 130 GB | Spare / overflow |

---

## Current blockers
*(none)*
