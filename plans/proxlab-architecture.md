# ProxLab Architecture

## Overview

ProxLab runs entirely on a single Proxmox node. Two logical Claude agents serve distinct roles:

| Agent | Where | Role |
|---|---|---|
| **Builder** | Your workstation / management host | Runs Claude Code, orchestrates the build via SSH + `qm` commands |
| **claude-lxc** | CT 22202 inside ProxLab | Permanent lab operator — WinRM, Ansible, Kerberos, Nmap, Wazuh |

---

## Full Architecture

```mermaid
graph TD
    Internet((Internet))
    GW["Your Router / Gateway"]

    Internet --> GW

    subgraph <proxmox-host>["Proxmox Host — Lenovo S30 V1 | Xeon E5-2650L | 128 GB ECC | PVE 9.1.1\nvms-1tb (953 GB NVMe)  +  vms-512gb (476 GB NVMe)"]

        subgraph Templates["Templates (read-only)"]
            T1["22200 ubuntu-2404-tmpl\nUbuntu 24.04 cloud-init"]
            T2["22201 ws2022-tmpl\nWindows Server 2022 sysprep"]
            T3["22212 win11-tmpl\nWindows 11 sysprep"]
        end

        subgraph ClaudeLXC["CT 22202 — claude-lxc  |  10.10.0.50 (lab)  |  <mgmt-ip> (management)"]
            CL["Claude Lab Operator\nAnsible · WinRM · Kerberos\nNmap · impacket · ldap3\n/opt/claude-agent/\n/var/log/claude-agent/actions.log"]
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
            RT01["22211 RT-01\nMikroTik CHR\n10.10.x.1 gateways"]
            WS01["22213 WS-01\nWin11 | 3 GB\n10.10.3.10"]
            WS02["22214 WS-02\nWin11 | 3 GB\n10.10.3.11"]
            WS03["22215 WS-03\nWin11 | 3 GB\n10.10.3.12"]
            LX01["22216 LX-01\nUbuntu 24.04 | 2 GB\n10.10.3.20\nSSSD AD-joined"]
            LX02["22217 LX-02\nDebian 13 | 2 GB\n10.10.3.21\nSSSD AD-joined"]
            ATK01["22218 ATK-01\nKali Linux | 4 GB\n10.10.3.30\nAttacker"]
        end

        subgraph VLAN400["VLAN 400 — 10.10.4.0/24 — DMZ (ISOLATED)"]
            VULN01["22219 VULN-01\nMetasploitable | 1 GB\n10.10.4.10"]
            VULN02["22220 VULN-02\nDVWA | 1 GB\n10.10.4.11"]
        end

    end

    GW -->|"management access"| <proxmox-host>

    CL -->|"WinRM + Kerberos"| DC01
    CL -->|"WinRM + Kerberos"| FS01
    CL -->|"Wazuh REST API"| SIEM
    CL -->|"Ansible SSH"| LX01
    CL -->|"Ansible SSH"| LX02
    CL -->|"nmap scan only"| VLAN400

    DC01 <-->|"AD replication"| DC02
    DC01 -->|"cert issuance · LDAPS"| PKI
    SIEM -->|"Wazuh agents"| DC01
    SIEM -->|"Wazuh agents"| FS01
    SIEM -->|"Wazuh agents"| APP01
    SIEM -->|"Wazuh agents"| WS01

    ATK01 -->|"only allowed path"| VULN01
    ATK01 --> VULN02
```

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| Single Proxmox host | Everything on one machine — cheaper, simpler, 128 GB ECC handles all VMs comfortably |
| Two logical agents | Builder (external, ephemeral) creates VMs; claude-lxc (permanent lab resident) operates them |
| Clone from sysprep templates | WS2022 + Ubuntu cloud-init templates eliminate per-VM OS installs — clone takes ~3 min |
| RT-01 as inter-VLAN router | MikroTik CHR VM routes between VLANs inside the lab — no dependency on physical router |
| VLAN-aware bridge (vmbr1) | Single bridge handles all lab VLANs via 802.1Q tagging |
| Kerberos keytabs | claude-lxc never stores passwords — keytabs for svc-claude-ro (always on), svc-claude-rw (enabled per session only) |
| VLAN 400 fully isolated | Vuln targets have no route to corp.lab — only ATK-01 has an explicit allow rule through RT-01 |
| Wazuh on all VMs | Single pane of glass for detection; attack scenarios generate real alerts |
| Win11 modded ISO | Stock Win11 ISO rejects old Xeon CPUs — modded ISO bypasses the CPU/TPM check |

---

## VLAN Layout

| VLAN | Subnet | Gateway (RT-01) | Purpose |
|---|---|---|---|
| native | 10.0.0.0/24 | — | Proxmox host management |
| 100 | 10.10.1.0/24 | 10.10.1.1 | Core Identity — AD, DNS, PKI, SIEM |
| 200 | 10.10.2.0/24 | 10.10.2.1 | Server Workloads |
| 300 | 10.10.3.0/24 | 10.10.3.1 | Endpoints |
| 400 | 10.10.4.0/24 | 10.10.4.1 | DMZ — no route to other VLANs |

## Resource Budget

| Resource | Total | ProxLab VMs | Headroom |
|---|---|---|---|
| RAM | 128 GB | ~56 GB | ~52 GB |
| Storage (vms-1tb) | 953 GB | DC/server VMs | — |
| Storage (vms-512gb) | 476 GB | Endpoints, DMZ | — |
