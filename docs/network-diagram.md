# ProxLab Network Diagram

## Physical topology

```
Internet
    │
    ▼
[MikroTik CHR 7.22.2]  <admin-net>.1  ← AZNET default gateway
    │  AZNET <admin-net>.0/23
    ├── Pi-hole          <admin-net>.21
    ├── claude-agent     <admin-net>.27   (LXC on <file-server> — build host)
    ├── <file-server>          <admin-net>.200  (Proxmox node — file server / Transmission)
    │     └─ ctTransmission LXC  <admin-net>.17  (Transmission torrent client)
    └── <proxmox-host>          <admin-net>.222  (Proxmox node — ProxLab host)
          └─ vmbr1 (VLAN-aware bridge) ─────────────────────────────────┐
                                                                         │

⚠️  <file-server> connects to MikroTik via wireless repeater.
    Only the host NIC MAC (<mac-addr>) is registered.
```

---

## ProxLab — <proxmox-host> internal network

```mermaid
graph TD
    Internet((Internet))
    MK["MikroTik CHR\n<admin-net>.1"]
    AZNET["AZNET <admin-net>.0/23\n(home/management network)"]

    Internet --> MK
    MK --> AZNET

    subgraph <proxmox-host>["<proxmox-host> — Proxmox VE 9.1.1 | <admin-net>.222"]
        CL["CT 22202 — claude-lxc\neth0: 10.10.0.50 (lab)\neth1: <admin-net>.100 (mgmt)"]

        subgraph V0["VLAN native — 10.0.0.0/24 — Proxmox mgmt"]
        end

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

    AZNET --> <proxmox-host>
    CL -->|"mgmt"| AZNET
    CL -->|"WinRM/SSH/Ansible"| V100
    CL -->|"WinRM/SSH/Ansible"| V200
    CL -->|"WinRM/SSH/Ansible"| V300
    CL -->|"nmap scan only"| V400
    ATK01 -->|"allowed"| V400
```

---

## VLAN routing (MikroTik RT-01, VM 22211)

| VLAN | Subnet | Gateway | Purpose |
|---|---|---|---|
| native | 10.0.0.0/24 | — | Proxmox host mgmt |
| 100 | 10.10.1.0/24 | 10.10.1.1 | Core Identity |
| 200 | 10.10.2.0/24 | 10.10.2.1 | Server Workloads |
| 300 | 10.10.3.0/24 | 10.10.3.1 | Endpoints |
| 400 | 10.10.4.0/24 | 10.10.4.1 | DMZ — no route to other VLANs |

**Firewall rules:**
- All VLANs can reach VLAN 100 (DNS/AD)
- VLAN 400 is fully isolated — inbound only from ATK-01 (10.10.3.30)
- No VLAN has direct internet access (lab is offline by design)

---

## AZNET management IPs (ProxLab reserved range: .100–.199)

| Host | AZNET IP |
|---|---|
| claude-lxc | <admin-net>.100 |
| DC-01 (temp) | <admin-net>.101 |
| FS-01 (temp) | <admin-net>.102 |
| APP-01 (temp) | <admin-net>.103 |
| SQL-01 (temp) | <admin-net>.104 |
| WSUS-01 (temp) | <admin-net>.105 |
| WS-01 (temp) | <admin-net>.106 |
| WS-02 (temp) | <admin-net>.107 |
| WS-03 (temp) | <admin-net>.108 |
| LX-01 (temp) | <admin-net>.109 |
| LX-02 (temp) | <admin-net>.110 |
| ATK-01 (temp) | <admin-net>.111 |

"temp" = remove these NICs after lab is fully built and claude-lxc is the sole management path.
