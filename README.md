# ProxLab — Home Security Operations Lab

A fully functional enterprise-grade home lab running on a single Proxmox node. Built to practice real-world IT operations, Active Directory administration, and security operations — with Claude AI as a co-pilot.

---

## What's in the lab

| Layer | VMs | Purpose |
|---|---|---|
| Core Identity | DC-01, DC-02, PKI-01, SIEM-01 | Active Directory domain `corp.lab`, DNS, DHCP, Certificate Authority, Wazuh SIEM |
| Server Workloads | FS-01, APP-01, SQL-01, WSUS-01 | File sharing, IIS web apps, SQL Server, Windows Update |
| Endpoints | WS-01/02/03 (Win11), LX-01 (Ubuntu), LX-02 (Debian), ATK-01 (Kali) | Domain-joined workstations, Linux clients, attacker machine |
| DMZ | VULN-01 (Metasploitable), VULN-02 (DVWA) | Intentionally vulnerable targets — isolated VLAN |
| Infra | MikroTik CHR router, Wazuh | VLAN routing, firewall, centralized logging |

All VMs run on **<proxmox-host>** (Lenovo ThinkStation S30, Xeon E5-2650L, 128 GB ECC RAM, Proxmox VE 9.1.1). The lab is air-gapped from the internet by design — VLAN 400 (DMZ) is fully isolated, and no lab subnet has direct internet access.

---

## Use cases

### 1. Windows patch management agent with Claude AI

Build an automated maintenance agent that manages Windows machines in an Active Directory domain:

- **Discover** all Windows hosts via `svc-claude-ro` (read-only AD service account) using LDAP queries from claude-lxc
- **Assess** patch state via WSUS or direct WMI queries (`Get-WindowsUpdateLog`, `Get-HotFix`)
- **Deploy** patches using WinRM + PowerShell: `Install-WindowsUpdate` or WSUS approval workflows on WSUS-01
- **Verify** completion and reboot status with QEMU guest agent
- **Log** every action to `/var/log/claude-agent/actions.log` for audit

**Where to start:**
```bash
# From claude-lxc, check patch status on all domain members
python3 /opt/claude-agent/scripts/check_patches.py --domain corp.lab
```

Claude helps you write the playbooks, interpret WMI output, and design safe rollout logic (ring deployments, maintenance windows).

---

### 2. Attack scenario simulation with Claude AI

Use ATK-01 (Kali) + VULN-01/02 (Metasploitable, DVWA) to learn offensive security:

- **Recon:** `nmap -sV -sC 10.10.4.0/24` — map the DMZ
- **Exploit:** Metasploit against Metasploitable (MS08-067, vsftpd backdoor, Samba CVEs)
- **Web attacks:** DVWA for SQLi, XSS, CSRF, file upload, command injection
- **AD attacks:** From ATK-01 into corp.lab — Kerberoasting, pass-the-hash, BloodHound enumeration

Ask Claude to explain each vulnerability, walk you through the exploit, and describe what defenders see in the logs. The SIEM (Wazuh) captures it all in real time.

**Example learning session:**
```
You: "Show me how MS17-010 works and how to exploit it on VULN-01"
Claude: walks through the vulnerability, runs the exploit step-by-step, then shows what Wazuh alerts fired
```

---

### 3. Defensive operations with Claude AI

After running attacks, use Claude to build defenses:

- **Analyze Wazuh alerts** — ask Claude to interpret security events, correlate attack timeline
- **Harden machines** — GPO hardening (SMB signing, LAPS, AppLocker), CIS benchmarks
- **Write detection rules** — custom Wazuh rules for specific attack patterns
- **Incident response** — Claude guides you through containment (isolate VM via MikroTik ACL), eradication, recovery

The `svc-claude-rw` AD account (disabled by default) gives Claude write access to AD for response actions — enable it only during approved sessions.

---

### 4. Vulnerability measurement and reduction

Continuously measure and improve your security posture:

- **Scan all VMs** from claude-lxc using nmap + OpenVAS
- **Query Wazuh** for unresolved alerts and vulnerability detections
- **Track remediation** — ask Claude to create a prioritized fix list from scan results
- **Measure over time** — compare scans before/after patch cycles

```bash
# Full lab vulnerability scan (run from claude-lxc)
nmap -sV --script vuln 10.10.1.0/24 10.10.2.0/24 10.10.3.0/24 -oX /tmp/scan.xml
```

Claude can parse the XML, explain each finding, suggest fixes, and help you write remediation playbooks.

---

## Getting started

**Access the lab:**
```bash
# From any machine on AZNET
ssh root@<admin-net>.100          # claude-lxc (lab operator)
https://<admin-net>.222:8006      # Proxmox web UI
https://10.10.1.20               # Wazuh dashboard (admin / see CREDENTIALS.md)
```

**Start Claude on the build host:**
```bash
ssh root@<admin-net>.27
~/start-claude.sh               # launches tmux + Claude Code in /home/projects/homelab
```

**Domain:** `corp.lab` | Admin: `CORP\Administrator`

---

## Architecture

See [`docs/network-diagram.md`](docs/network-diagram.md) for full topology with Mermaid diagram.  
See [`plans/proxlab-deployment.md`](plans/proxlab-deployment.md) for the full build plan and stage-by-stage procedures.  
See [`docs/stage9-handoff.md`](docs/stage9-handoff.md) for current build status and next steps.

---

## What you'll learn

By building and operating ProxLab you get hands-on experience with:

- **Active Directory** — forests, domains, OUs, GPOs, DHCP, DNS, PKI, service accounts
- **Windows Server** — file services (DFS), IIS, SQL Server, WSUS patch management
- **Linux in a Windows domain** — SSSD, realmd, Kerberos, AD-joined Ubuntu/Debian
- **Network segmentation** — VLANs, inter-VLAN routing, firewall ACLs on MikroTik
- **SIEM operations** — Wazuh agent deployment, log collection, alert tuning
- **Offensive security** — Metasploit, network scanning, AD attack chains
- **Defensive security** — GPO hardening, detection engineering, incident response
- **Infrastructure as code** — Ansible playbooks, PowerShell DSC, cloud-init
- **AI-assisted operations** — using Claude as a co-pilot for all of the above
