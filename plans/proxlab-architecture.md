# ProxLab Architecture Diagram

## Dual Claude Agent Design

Two Claude agents are involved in this project with distinct roles:

| Agent | Host | Role |
|---|---|---|
| **claude-agent** | `<admin-net>.27` (Proxmox LXC on AZNET) | **Builder** — runs Claude Code, orchestrates the entire ProxLab build via SSH to <proxmox-host> |
| **claude-lxc** | CT 22202 on <proxmox-host> — `10.10.0.50` (lab) / `<admin-net>.100` (AZNET) | **Lab Operator** — lives inside ProxLab permanently, manages all VMs via WinRM/Kerberos/Ansible/Nmap |

---

## Full Architecture

```mermaid
graph TD
    Internet((Internet))

    subgraph AZNET["AZNET — <admin-net>.0/23  |  MikroTik CHR 7.22.2"]

        Router["MikroTik CHR\n<admin-net>.1\nDefault GW"]
        PiHole["Pi-hole DNS\n<admin-net>.21"]
        AlzaFS["<file-server> File Server\n<admin-net>.229\n12 TB — OS ISOs"]

        subgraph ClaudeAgentBox["claude-agent LXC  |  <admin-net>.27"]
            CA["🤖 Claude Code\n(YOU ARE HERE)\nOrchestrates build\nvia SSH to <proxmox-host>"]
        end

        subgraph <proxmox-host>Box["<proxmox-host> — Proxmox VE 9.1.1  |  <admin-net>.222\nLenovo S30 V1  |  Xeon E5-2650L  |  128 GB ECC\nvms-1tb (953 GB)  +  vms-512gb (476 GB)"]

            subgraph Templates["Templates (read-only)"]
                T1["22200 ubuntu-2404-tmpl\nUbuntu 24.04 cloud-init"]
                T2["22201 ws2022-tmpl\nWindows Server 2022 sysprep"]
            end

            subgraph ClaudeLXC["CT 22202 — claude-lxc  |  eth0: 10.10.0.50  |  eth1: <admin-net>.100"]
                CL["🤖 Claude Lab Operator\nAnsible · WinRM · Kerberos\nNmap · impacket · ldap3\n/opt/claude-agent/\n/var/log/claude-agent/actions.log"]
            end

            subgraph VLAN100["VLAN 100 — 10.10.1.0/24 — Core Identity"]
                DC01["22203 DC-01\nWS2022 | 4 GB\n10.10.1.10\nAD DS · DNS · DHCP"]
                DC02["22204 DC-02\nWS2022 | 3 GB\n10.10.1.11\nAD DS · DNS"]
                PKI["22205 PKI-01\nWS2022 | 3 GB\n10.10.1.12\nEnterprise CA · LDAPS"]
                SIEM["22206 SIEM-01\nUbuntu 24.04 | 8 GB\n10.10.1.20\nWazuh · OpenSearch"]
            end

            subgraph VLAN200["VLAN 200 — 10.10.2.0/24 — Server Workloads"]
                FS01["22207 FS-01\nWS2022 | 3 GB\n10.10.2.10\nSMB · DFS"]
                APP01["22208 APP-01\nWS2022 | 4 GB\n10.10.2.11\nIIS · REST APIs"]
                SQL01["22209 SQL-01\nWS2022 | 6 GB\n10.10.2.12\nSQL Server 2022"]
                WSUS01["22210 WSUS-01\nWS2022 | 4 GB\n10.10.2.13\nPatch Mgmt"]
            end

            subgraph VLAN300["VLAN 300 — 10.10.3.0/24 — Endpoints"]
                WS01["22211 WS-01\nWin11 | 3 GB\n10.10.3.10"]
                WS02["22212 WS-02\nWin11 | 3 GB\n10.10.3.11"]
                WS03["22213 WS-03\nWin11 | 3 GB\n10.10.3.12"]
                LX01["22214 LX-01\nUbuntu 24.04 | 1 GB\n10.10.3.20\nSSSD AD-joined"]
                LX02["22215 LX-02\nDebian 12 | 1 GB\n10.10.3.21\nSSSD AD-joined"]
                ATK01["22216 ATK-01\nKali Linux | 4 GB\n10.10.3.30\nSecOps attacker"]
            end

            subgraph VLAN400["VLAN 400 — 10.10.4.0/24 — DMZ / Vuln Targets  (ISOLATED)"]
                VULN01["22217 VULN-01\nMetasploitable | 1 GB\n10.10.4.10"]
                VULN02["22218 VULN-02\nDVWA | 1 GB\n10.10.4.11"]
            end

        end
    end

    %% Internet
    Internet -->|NAT| Router

    %% AZNET connectivity
    Router --> PiHole
    Router --> ClaudeAgentBox
    Router --> AlzaFS
    Router --> <proxmox-host>Box

    %% Builder agent controls <proxmox-host>
    CA -->|"SSH 22\nqm / pct commands"| <proxmox-host>Box

    %% claude-lxc bridges AZNET ↔ lab
    CL -->|"eth1 — AZNET mgmt\n<admin-net>.100"| Router
    CL -->|"eth0 — lab internal\n10.10.0.50"| VLAN100
    CL -->|"eth0 — lab internal"| VLAN200
    CL -->|"eth0 — lab internal"| VLAN300

    %% claude-lxc operations
    CL -->|"WinRM + Kerberos\nsvc-claude-ro / rw"| DC01
    CL -->|"WinRM + Kerberos"| FS01
    CL -->|"Wazuh REST API"| SIEM
    CL -->|"Ansible SSH"| LX01
    CL -->|"Ansible SSH"| LX02
    CL -->|"nmap scan"| VLAN400

    %% AD topology
    DC01 <-->|"AD replication"| DC02
    DC01 -->|"cert issuance\nLDAPS"| PKI
    SIEM -->|"Wazuh agents\ncollect logs"| DC01
    SIEM -->|"Wazuh agents"| FS01
    SIEM -->|"Wazuh agents"| APP01
    SIEM -->|"Wazuh agents"| SQL01
    SIEM -->|"Wazuh agents"| WS01

    %% ATK-01 only VM that reaches VLAN 400
    ATK01 -->|"ONLY allowed path\nto vuln targets"| VULN01
    ATK01 --> VULN02

    %% ISO source
    AlzaFS -->|"SCP ISOs\nWin XP/7/2012R2\nUbuntu 16.04"| <proxmox-host>Box
```

---

## Agent Role Summary

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          AZNET (<admin-net>.0/23)                        │
│                                                                         │
│  ┌──────────────────────┐         ┌──────────────────────────────────┐  │
│  │   claude-agent        │  SSH   │   <proxmox-host> (Proxmox VE 9.1.1)    │  │
│  │   <admin-net>.27      │───────▶│   <admin-net>.222                 │  │
│  │                       │        │                                   │  │
│  │  🤖 Claude Code        │        │  ┌─────────────────────────────┐ │  │
│  │  YOU ARE HERE         │        │  │  claude-lxc  (CT 22202)     │ │  │
│  │                       │        │  │                              │ │  │
│  │  Role: BUILDER        │        │  │  eth1: <admin-net>.100 ──────┼─┼──┘
│  │  - Plans the lab      │        │  │  eth0: 10.10.0.50           │ │
│  │  - Runs qm/pct cmds  │        │  │                              │ │
│  │  - Manages ISOs       │        │  │  🤖 Claude Lab Operator      │ │
│  │  - Monitors progress  │        │  │  Role: OPERATOR              │ │
│  │                       │        │  │  - WinRM to all Windows VMs  │ │
│  │  Temporary role:      │        │  │  - Ansible to Linux VMs      │ │
│  │  not present in lab   │        │  │  - Kerberos auth to AD       │ │
│  └──────────────────────┘        │  │  - Nmap scans DMZ            │ │
│                                   │  │  - Reads SIEM alerts         │ │
│                                   │  │  - Logs all actions          │ │
│                                   │  │  Permanent resident of lab   │ │
│                                   │  └─────────────────────────────┘ │
│                                   │                                   │
│                                   │  [VLAN 100] DC-01 DC-02 PKI SIEM │
│                                   │  [VLAN 200] FS APP SQL WSUS      │
│                                   │  [VLAN 300] WS×3 LX×2 ATK-01    │
│                                   │  [VLAN 400] VULN-01 VULN-02      │
│                                   └──────────────────────────────────┘
└─────────────────────────────────────────────────────────────────────────┘
```

## Key Design Decisions

| Decision | Rationale |
|---|---|
| Two separate agents | claude-agent is the external builder (ephemeral sessions); claude-lxc is the permanent lab operator |
| claude-lxc dual NIC | eth0 on vmbr1 (lab internal) for WinRM/Ansible; eth1 on vmbr0 for internet access and AZNET management |
| Clone from templates | WS2022 sysprep template (22201) and Ubuntu cloud-init template (22200) eliminate per-VM OS installs |
| Kerberos keytabs | claude-lxc never stores passwords; uses keytabs for svc-claude-ro (always on) and svc-claude-rw (enabled per session only) |
| VLAN 400 isolation | Vuln targets have no route to corp.lab — only ATK-01 (VLAN 300) has an explicit allow rule |
| Wazuh on all VMs | SIEM-01 is the single pane of glass; `get_siem_alerts` MCP tool gives claude-lxc real-time visibility |
| ProxLab AZNET IPs | <admin-net>.100–199 reserved for lab VMs/LXCs needing management access outside the lab |
