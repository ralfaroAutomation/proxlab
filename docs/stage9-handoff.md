# Stage 9 Handoff — Endpoints + DMZ Overview

**Date:** 2026-05-02  
**Status:** Stage 9 in progress — Linux VMs created, Win11 template pending, DMZ pending

---

## VM Inventory (as of this session)

| VM ID | Name | Status | Role | VLAN | Lab IP | AZNET mgmt IP |
|---|---|---|---|---|---|---|
| 22200 | ubuntu-2404-tmpl | template | Ubuntu 24.04 cloud-init base | — | — | — |
| 22201 | ws2022-tmpl | template | Windows Server 2022 sysprep base | — | — | — |
| 22203 | DC-01 | running | Primary DC, DNS, DHCP | 100 | 10.10.1.10 | <admin-net>.101 |
| 22204 | DC-02 | running | Secondary DC | 100 | 10.10.1.11 | — |
| 22205 | PKI-01 | running | Certificate Authority | 100 | 10.10.1.20 (was SIEM?) | — |
| 22206 | SIEM-01 | running | Wazuh SIEM | 100 | 10.10.1.20 | <admin-net2>.84 |
| 22207 | FS-01 | running | File Server (DFS) | 200 | 10.10.2.10 | <admin-net>.102 |
| 22208 | APP-01 | running | IIS Web Server | 200 | 10.10.2.11 | <admin-net>.103 |
| 22209 | SQL-01 | running | SQL Server 2022 | 200 | 10.10.2.12 | <admin-net>.104 |
| 22210 | WSUS-01 | running | Windows Update Services | 200 | 10.10.2.13 | <admin-net>.105 |
| 22211 | RT-01 | running | MikroTik CHR router (lab) | — | — | — |
| 22212 | win11-build | running | Win11 template build VM | — | DHCP | 192.168.10.??? |
| 22216 | LX-01 | running | Ubuntu 24.04 endpoint (SSSD) | 300 | 10.10.3.20 | <admin-net>.109 |
| 22217 | LX-02 | stopped | Debian 13 endpoint (SSSD) | 300 | 10.10.3.21 | DHCP (net1) |
| 22218 | ATK-01 | stopped | Kali 2026.1 attacker | 300 | 10.10.3.30 | DHCP (net1) |

**Note:** VMIDs shifted by +2 from original plan because 22211=RT-01 and 22212=win11-build.  
**WS-01/02/03 (22213/22214/22215) not yet created** — waiting for Win11 template.

---

## Stage 9 Checklist

### Win11 Template (22212 → win11-tmpl)

- [ ] Complete Win11 OOBE on VM 22212 (if still at network screen: Shift+F10 → `OOBE\BYPASSNRO`)
- [ ] Install VirtIO drivers: Device Manager → unknown devices → browse `D:\amd64\w11`
- [ ] Install QEMU guest agent: `Start-Process D:\guest-agent\qemu-ga-x86_64.msi -ArgumentList "/quiet" -Wait`
- [ ] Run Windows Update fully (may take multiple reboots)
- [ ] Sysprep: `C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown`
- [ ] After shutdown, convert to template: `qm template 22212`
- [ ] Rename template: `qm set 22212 --name win11-tmpl`

### WS-01 / WS-02 / WS-03 (clone win11-tmpl → 22213/22214/22215)

Once win11-tmpl is ready:
```bash
for ID in 22213 22214 22215; do
  qm clone 22212 $ID --name WS-$(printf "%02d" $((ID-22212))) --full 1 --storage vms-1tb
done
```

Configure each:
| VM ID | Name | Lab IP | AZNET IP |
|---|---|---|---|
| 22213 | WS-01 | 10.10.3.10/24 | <admin-net>.106 |
| 22214 | WS-02 | 10.10.3.11/24 | <admin-net>.107 |
| 22215 | WS-03 | 10.10.3.12/24 | <admin-net>.108 |

- net0: vmbr1, tag=300 | net1: vmbr0 (temp mgmt)
- Complete Win11 OOBE, set static IPs, join `corp.lab`
- Snapshot: `qm snapshot 2221X stage9-baseline`

### LX-01 (22216) — Ubuntu 24.04 ✓ CREATED, running

- [ ] Wait for cloud-init to finish (1-2 min after boot)
- [ ] SSH: `ssh ubuntu@<admin-net>.109` (or via lab IP 10.10.3.20)
- [ ] Verify internet: `ping 8.8.8.8`
- [ ] Install SSSD + realmd + join domain:
  ```bash
  apt update && apt install -y sssd realmd adcli samba-common-bin oddjob-mkhomedir packagekit
  realm discover corp.lab
  realm join corp.lab -U Administrator
  # Verify: id CORP\\Administrator
  ```
- [ ] Install Wazuh agent (enroll to SIEM-01 at 10.10.1.20)
- [ ] Snapshot: `qm snapshot 22216 stage9-baseline`

### LX-02 (22217) — Debian 13 — CREATED, needs install

- [ ] Start VM: `qm start 22217` → open Proxmox console
- [ ] Install Debian 13 — set hostname `LX-02`, static IP 10.10.3.21/24 GW 10.10.3.1, DNS 10.10.1.10
- [ ] Install QEMU agent: `apt install qemu-guest-agent && systemctl enable --now qemu-guest-agent`
- [ ] Join domain with SSSD (same as LX-01)
- [ ] Snapshot: `qm snapshot 22217 stage9-baseline`

### ATK-01 (22218) — Kali 2026.1 — CREATED, needs install

- [ ] Start VM: `qm start 22218` → open Proxmox console
- [ ] Install Kali — hostname `ATK-01`, static IP 10.10.3.30/24 GW 10.10.3.1, DNS 10.10.1.10
- [ ] Install QEMU agent: `apt install qemu-guest-agent && systemctl enable --now qemu-guest-agent`
- [ ] Copy claude-lxc SSH pubkey for remote access
- [ ] **No domain join** — standalone attacker VM
- [ ] Snapshot: `qm snapshot 22218 stage9-baseline`

### VLAN 300 DHCP Scope (on DC-01)

```powershell
# Run on DC-01 as CORP\Administrator
Add-DhcpServerv4Scope -Name 'VLAN300-Endpoints' `
    -StartRange 10.10.3.100 -EndRange 10.10.3.199 `
    -SubnetMask 255.255.255.0 -State Active
Set-DhcpServerv4OptionValue -ScopeId 10.10.3.0 `
    -Router 10.10.3.1 -DnsServer 10.10.1.10,10.10.1.11 -DnsDomain corp.lab
```

---

## Stage 10 — DMZ / Vuln Targets (VLAN 400)

**VMIDs: 22219 (VULN-01), 22220 (VULN-02)** — original plan had 22217/22218 but those are now LX-02/ATK-01.

### VULN-01 — Metasploitable 2 (22219)

- [ ] Download Metasploitable2 VMDK (SourceForge/Rapid7 — free)
  - Can use Transmission at http://<admin-net>.17:9091 or direct wget on claude-agent
- [ ] Import and create VM:
  ```bash
  qm create 22219 --name VULN-01 --memory 1024 --cores 1 --cpu host --machine pc \
    --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr1,tag=400,firewall=0 \
    --ostype l26 --onboot 0
  # Copy VMDK to <proxmox-host>, then:
  qm importdisk 22219 /path/to/Metasploitable.vmdk vms-512gb --format qcow2
  qm set 22219 --scsi0 vms-512gb:vm-22219-disk-0 --boot order=scsi0
  ```
- [ ] Set static IP 10.10.4.10/24 inside VM

### VULN-02 — DVWA on Debian (22220)

- [ ] Create from Debian 13 netinst on VLAN 400, onboot=0, static IP 10.10.4.11
- [ ] Install DVWA:
  ```bash
  apt install apache2 php php-mysqli mariadb-server git
  cd /var/www/html && git clone https://github.com/digininja/DVWA.git
  ```

### Additional SecOps Targets (optional — from <file-server> ISO archive)

Available at `/media/drives/12tb/backup_dataset4/ordered/tech/software/_OS_installers/` on <file-server>:

| VM | Key attacks |
|---|---|
| Windows XP | MS08-067, EternalBlue, SMBv1 |
| Windows 7 | MS17-010, pass-the-hash, Mimikatz |
| Ubuntu 16.04 | Dirty COW, privesc |

---

## Stage 11 — claude-lxc Integration (pending Stage 9+10 complete)

- [ ] Create AD service accounts `svc-claude-ro` and `svc-claude-rw` in `OU=ServiceAccounts`
- [ ] Generate Kerberos keytabs on DC-01, copy to `/etc/krb5/` on claude-lxc
- [ ] Configure WinRM on all Windows VMs for pywinrm access
- [ ] Test MCP tools: scan, query AD, run playbooks

---

## Pending Cleanup

- [ ] Remove temp management NIC (net1) from DC-01 once Stage 11 is stable
- [ ] Remove temp management NIC (net1) from SIEM-01 once Wazuh agent rollout complete
- [ ] Install QEMU agent on SIEM-01: `apt install qemu-guest-agent && systemctl enable --now qemu-guest-agent`
- [ ] Update `proxlab-context.md` — phases 1-8 marked complete, phases 9-10 in progress
- [ ] Stage 8 VMs (FS-01/APP-01/SQL-01/WSUS-01) — complete OOBE + role install + domain join + snapshot

---

## Key Reference

- Proxmox host: `sshpass -e ssh root@<admin-net>.222`
- Transmission: http://<admin-net>.17:9091 (LXC 20008 on <file-server>, IP changed from .10.18)
- Credentials: `/home/projects/homelab/CREDENTIALS.md`
- Full deployment plan: `/home/projects/homelab/plans/proxlab-deployment.md`
- Architecture: `/home/projects/homelab/plans/proxlab-architecture.md`
