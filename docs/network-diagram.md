# ProxLab Network Diagram

All VMs run on a single Proxmox host connected to your management network via `vmbr0`. Lab traffic is isolated on `vmbr1` (VLAN-aware bridge) — no lab subnet has direct internet access.

---

## ProxLab internal topology

```mermaid
graph TD
    Internet((Internet))
    MK["MikroTik CHR — RT-01\nVM 22211 on vmbr1\nInter-VLAN router\nGateway for all lab VLANs"]
    AZNET["Management Network\nvmbr0 — your LAN\n(access to Proxmox UI + claude-lxc)"]

    Internet --> AZNET
    AZNET --> MK

    subgraph <proxmox-host>["Proxmox Host — vmbr1 (VLAN-aware bridge)"]
        CL["CT 22202 — claude-lxc\neth0: 10.10.0.50 (lab)\neth1: management NIC"]

        subgraph V100["VLAN 100 — 10.10.1.0/24 — Core Identity"]
            DC01["22203 DC-01\nWS2022 · AD DS · DNS · DHCP\n10.10.1.10"]
            DC02["22204 DC-02\nWS2022 · AD DS · DNS\n10.10.1.11"]
            PKI["22205 PKI-01\nWS2022 · Enterprise CA\n10.10.1.12"]
            SIEM["22206 SIEM-01\nUbuntu · Wazuh\n10.10.1.20"]
        end

        subgraph V200["VLAN 200 — 10.10.2.0/24 — Server Workloads"]
            FS01["22207 FS-01\nWS2022 · SMB/DFS\n10.10.2.10"]
            APP01["22208 APP-01\nWS2022 · IIS\n10.10.2.11"]
            SQL01["22209 SQL-01\nWS2022 · SQL Server 2022\n10.10.2.12"]
            WSUS01["22210 WSUS-01\nWS2022 · WSUS\n10.10.2.13"]
        end

        subgraph V300["VLAN 300 — 10.10.3.0/24 — Endpoints"]
            WS01["22213 WS-01\nWin11 · corp.lab\n10.10.3.10"]
            WS02["22214 WS-02\nWin11 · corp.lab\n10.10.3.11"]
            WS03["22215 WS-03\nWin11 · corp.lab\n10.10.3.12"]
            LX01["22216 LX-01\nUbuntu 24.04 · SSSD\n10.10.3.20"]
            LX02["22217 LX-02\nDebian 13 · SSSD\n10.10.3.21"]
            ATK01["22218 ATK-01\nKali 2026.1\n10.10.3.30"]
        end

        subgraph V400["VLAN 400 — 10.10.4.0/24 — DMZ (ISOLATED)"]
            VULN01["22219 VULN-01\nMetasploitable 2\n10.10.4.10"]
            VULN02["22220 VULN-02\nDVWA on Debian\n10.10.4.11"]
        end
    end

    MK --> V100
    MK --> V200
    MK --> V300
    MK -.->|"no default route\nisolated"| V400

    CL -->|"WinRM/SSH/Ansible"| V100
    CL -->|"WinRM/SSH/Ansible"| V200
    CL -->|"WinRM/SSH/Ansible"| V300
    CL -->|"nmap scan only"| V400
    ATK01 -->|"only allowed VM"| V400
```

---

## VLAN routing (RT-01, VM 22211)

| VLAN | Subnet | Gateway | Purpose |
|---|---|---|---|
| native | 10.0.0.0/24 | — | Proxmox host management |
| 100 | 10.10.1.0/24 | 10.10.1.1 | Core Identity |
| 200 | 10.10.2.0/24 | 10.10.2.1 | Server Workloads |
| 300 | 10.10.3.0/24 | 10.10.3.1 | Endpoints |
| 400 | 10.10.4.0/24 | 10.10.4.1 | DMZ — isolated |

**Firewall rules (on RT-01):**
- All VLANs can reach VLAN 100 (AD/DNS)
- VLAN 400 is fully isolated — inbound only from ATK-01 (10.10.3.30)
- No VLAN has direct internet access (lab is air-gapped by design)

---

## Management access (per VM)

Each Windows/Linux VM gets a second NIC on `vmbr0` (your management network) during the build phase. This is used for RDP/SSH access before the lab is fully operational. These NICs are removed once claude-lxc is the sole management path.

| Host | Lab IP | Management NIC |
|---|---|---|
| claude-lxc | 10.10.0.50 | `<mgmt-net>.100` |
| DC-01 | 10.10.1.10 | `<mgmt-net>.101` (temp) |
| FS-01 | 10.10.2.10 | `<mgmt-net>.102` (temp) |
| APP-01 | 10.10.2.11 | `<mgmt-net>.103` (temp) |
| SQL-01 | 10.10.2.12 | `<mgmt-net>.104` (temp) |
| WSUS-01 | 10.10.2.13 | `<mgmt-net>.105` (temp) |
| WS-01 | 10.10.3.10 | `<mgmt-net>.106` (temp) |
| WS-02 | 10.10.3.11 | `<mgmt-net>.107` (temp) |
| WS-03 | 10.10.3.12 | `<mgmt-net>.108` (temp) |
| LX-01 | 10.10.3.20 | `<mgmt-net>.109` (temp) |
| LX-02 | 10.10.3.21 | `<mgmt-net>.110` (temp) |
| ATK-01 | 10.10.3.30 | `<mgmt-net>.111` (temp) |
