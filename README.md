# ProxLab — Enterprise Home Lab on a Single Proxmox Node

A fully functional enterprise-grade security operations lab running on one old workstation. Built to get hands-on with Active Directory, Windows Server, Linux administration, PKI, SIEM, and offensive security — with Claude AI as the co-pilot that operates the whole thing.

---

## What I built

| Layer | VMs | Purpose |
|---|---|---|
| Core Identity | DC-01, DC-02, PKI-01, SIEM-01 | AD forest `corp.lab`, DNS, DHCP, Enterprise CA, Wazuh SIEM |
| Server Workloads | FS-01, APP-01, SQL-01, WSUS-01 | File shares, IIS, SQL Server 2022, Windows Update |
| Endpoints | WS-01/02/03 (Win11), LX-01 (Ubuntu), LX-02 (Debian), ATK-01 (Kali) | Domain-joined workstations, Linux clients, attacker machine |
| DMZ | VULN-01 (Metasploitable), VULN-02 (DVWA) | Intentionally vulnerable targets — isolated VLAN |
| Router | RT-01 (MikroTik CHR VM) | Inter-VLAN routing and firewall rules inside the lab |

**Hardware:** Lenovo ThinkStation S30 V1 — Xeon E5-2650L, 128 GB ECC RAM, two NVMe drives (~1.5 TB total), Proxmox VE 9.1.1. A single machine from ~2012 that costs almost nothing second-hand.

**Domain:** `corp.lab` | All VMs on a single host — no external dependencies, fully air-gapped from the internet by design.

---

## Why build this

Most home labs are too small to feel real. This one isn't:

- **Real AD** — forest root DC, secondary DC with replication, Enterprise CA issuing certs, LDAPS
- **Real patch management** — WSUS controlling updates for all Windows VMs, tested via PSWindowsUpdate
- **Real attack surface** — Metasploitable and DVWA in an isolated DMZ, attacked from Kali, detected by Wazuh
- **Real automation** — Claude running as a lab operator inside the environment, not just answering questions

The goal is to build the kind of environment you'd encounter in a mid-size company, then use it to learn how to attack it, defend it, and automate its management.

---

## The build journey

The [`journey/`](journey/) directory tells the story of how this was built — in order, including every blocker hit and how it was fixed. Start there if you want to replicate it.

| Doc | What it covers |
|---|---|
| [`01-proxmox-and-templates.md`](journey/01-proxmox-and-templates.md) | Proxmox setup, storage pools, cloud-init and sysprep templates, Win11 on old hardware |
| [`02-network-and-vlans.md`](journey/02-network-and-vlans.md) | VLAN-aware bridge, RT-01 inter-VLAN router VM, firewall rules |
| [`03-core-identity.md`](journey/03-core-identity.md) | AD forest, DC-02 promotion, PKI Enterprise CA, LDAPS |
| [`04-server-workloads.md`](journey/04-server-workloads.md) | FS-01, APP-01, SQL-01, WSUS-01 — domain join, roles, DHCP scopes |
| [`05-endpoints.md`](journey/05-endpoints.md) | Win11 template → clone workflow, Linux realm join, Kali setup |
| [`06-siem-and-attack-lab.md`](journey/06-siem-and-attack-lab.md) | Wazuh deployment, DMZ setup, attack scenarios |
| [`07-ai-integration.md`](journey/07-ai-integration.md) | Claude as lab operator — Kerberos, WinRM, Ansible, MCP tools |

---

## What you'll learn

- **Active Directory** — forests, OUs, GPOs, replication, service accounts, Kerberoasting targets
- **Windows Server** — file services (DFS), IIS, SQL Server, WSUS patch pipelines
- **PKI** — Enterprise Root CA, auto-enrollment, LDAPS on domain controllers
- **Linux in a Windows domain** — SSSD, realmd, Kerberos, AD-joined Ubuntu/Debian
- **Network segmentation** — VLANs, inter-VLAN routing, ACLs, DMZ isolation
- **SIEM operations** — Wazuh agent deployment, alert tuning, attack detection
- **Offensive security** — Metasploit, network scanning, AD attack chains from Kali
- **Defensive security** — GPO hardening, detection engineering, incident response
- **AI-assisted operations** — Claude as a co-pilot for all of the above

---

## Architecture

See [`plans/proxlab-architecture.md`](plans/proxlab-architecture.md) for the full topology with Mermaid diagram.  
See [`docs/network-diagram.md`](docs/network-diagram.md) for the VLAN layout and per-VM IPs.  
See [`docs/troubleshooting.md`](docs/troubleshooting.md) for a log of real issues encountered and their fixes.  
See [`plans/proxlab-deployment.md`](plans/proxlab-deployment.md) for the full stage-by-stage build checklist with commands.
