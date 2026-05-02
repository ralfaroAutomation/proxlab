# Stage 2 — Network & VLANs

## Goal

Isolate lab traffic from your management network, segment the lab into four VLANs, and get inter-VLAN routing working — all without needing a physical managed switch or a separate router.

---

## The design

One physical NIC on the Proxmox host, two bridges:

| Bridge | Purpose |
|---|---|
| `vmbr0` | Management — Proxmox UI, SSH to host, RDP/SSH to VMs during build |
| `vmbr1` | Lab traffic — all VLANs, VLAN-aware, no IP on the host |

VMs on `vmbr1` get a VLAN tag. The bridge passes tagged frames between VMs — it doesn't route between them. Routing is handled by RT-01, a MikroTik CHR VM running on the same host.

This means the entire lab — including its router — runs on one machine. No physical switch needed for VLAN support.

---

## Setting up vmbr1

In Proxmox UI → Node → Network → Create Linux Bridge:

```
Name: vmbr1
Bridge ports: (leave empty — no physical uplink)
VLAN aware: yes
Comment: ProxLab lab bridge
```

Or via `/etc/network/interfaces`:

```
auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
```

`bridge-ports none` is the key — this bridge is internal only, isolated from your physical network by design.

---

## RT-01 — MikroTik CHR as inter-VLAN router (VM 22211)

Instead of configuring static routes on each VM or relying on the physical router, RT-01 is a MikroTik Cloud Hosted Router VM sitting on `vmbr1` with one NIC per VLAN.

```bash
qm create 22211 --name RT-01 --memory 512 --cores 1 --cpu host \
  --net0 virtio,bridge=vmbr1,tag=100 \
  --net1 virtio,bridge=vmbr1,tag=200 \
  --net2 virtio,bridge=vmbr1,tag=300 \
  --net3 virtio,bridge=vmbr1,tag=400 \
  --net4 virtio,bridge=vmbr1 \
  --ostype l26 --agent enabled=1 --onboot 1 \
  --boot order=scsi0
```

Download MikroTik CHR (free tier — unlimited throughput for lab use) and import as disk:

```bash
wget https://download.mikrotik.com/routeros/7.x.x/chr-7.x.x.img.zip
unzip chr-7.x.x.img.zip
qm importdisk 22211 chr-7.x.x.img vms-512gb
qm set 22211 --scsi0 vms-512gb:vm-22211-disk-0 --boot order=scsi0
```

Inside MikroTik, assign IPs to each interface and add routes:

```routeros
/ip address
add address=10.10.1.1/24 interface=ether1   # VLAN 100 gateway
add address=10.10.2.1/24 interface=ether2   # VLAN 200 gateway
add address=10.10.3.1/24 interface=ether3   # VLAN 300 gateway
add address=10.10.4.1/24 interface=ether4   # VLAN 400 gateway (isolated)

# Allow all VLANs to reach VLAN 100 (AD/DNS)
/ip firewall filter
add chain=forward src-address=10.10.0.0/16 dst-address=10.10.1.0/24 action=accept

# VLAN 400 fully isolated — only ATK-01 can reach it
add chain=forward src-address=10.10.3.30   dst-address=10.10.4.0/24 action=accept
add chain=forward dst-address=10.10.4.0/24 action=drop
```

---

## VLAN layout

| VLAN | Subnet | Gateway | Purpose |
|---|---|---|---|
| 100 | 10.10.1.0/24 | 10.10.1.1 | Core Identity — AD, DNS, PKI, SIEM |
| 200 | 10.10.2.0/24 | 10.10.2.1 | Server Workloads |
| 300 | 10.10.3.0/24 | 10.10.3.1 | Endpoints |
| 400 | 10.10.4.0/24 | 10.10.4.1 | DMZ — isolated, vuln targets only |

---

## Why RT-01 shifts all Stage 9 VM IDs

The original plan had WS-01 starting at VM ID 22211. When RT-01 was added as the inter-VLAN router it took 22211, pushing all endpoint VMs up by one:

| VM | Planned ID | Actual ID |
|---|---|---|
| RT-01 | (not planned) | 22211 |
| WS-01 | 22211 | 22213 |
| WS-02 | 22212 | 22214 |
| WS-03 | 22213 | 22215 |
| LX-01 | 22214 | 22216 |
| LX-02 | 22215 | 22217 |
| ATK-01 | 22216 | 22218 |

Worth knowing when you cross-reference docs and scripts — everything endpoint-related is +2 from the original plan.

---

## Lessons learned

| Issue | Fix |
|---|---|
| Lab VMs can accidentally reach management network | `vmbr1` has no physical port — it's fully internal by design |
| VMID conflicts when adding unplanned VMs | Reserve a block and document any changes immediately |
| MikroTik CHR free tier limitations | Free tier is bandwidth-limited to 1 Mbps — upgrade to a paid license or use the trial for lab use; actual inter-VLAN LAN traffic is unaffected in practice |
