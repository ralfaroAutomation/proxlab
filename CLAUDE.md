# ProxLab — CLAUDE.md

## What this repo is

Public documentation for **ProxLab** — an enterprise-grade home lab on a single Proxmox node. Built to practice Active Directory, Windows Server, PKI, SIEM (Wazuh), and offensive security, with Claude AI as the operations co-pilot.

Private counterpart: `github.com/ralfaroAutomation/homelab` (contains real IPs, SSH credentials, private context).

## Lab topology

| VLAN | Subnet | Purpose |
|---|---|---|
| native | `10.0.0.0/24` | Proxmox management |
| 100 | `10.10.1.0/24` | Core identity — AD, DNS, PKI, SIEM |
| 200 | `10.10.2.0/24` | Server workloads — FS, APP, SQL, WSUS |
| 300 | `10.10.3.0/24` | Endpoints — Windows/Linux clients, Kali |
| 400 | `10.10.4.0/24` | DMZ / vuln targets (isolated) |

## VM ID convention (alza222 host)

`222XX` — sequential from 22200. Examples: `22203` = DC-01, `22206` = SIEM-01.

## Key VMs

| VM | ID | Role |
|---|---|---|
| ubuntu-2404-tmpl | 22200 | Ubuntu 24.04 cloud-init base template |
| ws2022-tmpl | 22201 | Windows Server 2022 sysprep template |
| claude-lxc | 22202 | AI ops container (PROXLAB agent) |
| DC-01 | 22203 | Primary domain controller — corp.lab |
| DC-02 | 22204 | Secondary DC |
| PKI-01 | 22205 | Enterprise Root CA (LDAPS) |
| SIEM-01 | 22206 | Wazuh all-in-one |
| FS-01 | 22207 | File server |
| APP-01 | 22208 | IIS app server |
| SQL-01 | 22209 | SQL Server 2022 Dev |
| WSUS-01 | 22210 | Patch management |
| WS-01/02/03 | 22211–22213 | Windows 11 endpoints |
| LX-01 | 22216 | Ubuntu 24.04 endpoint (AD-joined) |
| LX-02 | 22217 | Debian 13 endpoint (AD-joined) |
| ATK-01 | 22218 | Kali Linux (VLAN 300) |

## Repo layout

```
plans/          # Deployment plans with commands and configs (reference docs)
docs/           # Architecture, workflow, troubleshooting
journey/        # Build log — stage-by-stage narrative with blockers and fixes
scripts/        # Utility scripts
```

## Task tracking

Open work items are tracked as GitHub Issues in the private `ralfaroAutomation/lab-tasks` repo. Plan files are reference/command docs — not the task list.

## Agents

Two Claude agents operate this lab:

| Agent | Host | Label | Role |
|---|---|---|---|
| BUILDER | claude-agent LXC (outside lab) | `BUILDER` | Proxmox API, SSH to lab hosts |
| PROXLAB | claude-lxc (VM 22202, inside lab) | `PROXLAB` | AD/WinRM/Ansible/LDAP ops |
