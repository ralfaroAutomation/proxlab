# VLAN Segmentation Plan — AZNET Home Network

**Status:** Pending — awaiting Aruba Instant On app configuration  
**Last updated:** 2026-04-28  
**Network:** AZNET (<admin-net>.0/23)  
**Router:** MikroTik CHR — <admin-net>.1 (RouterOS 7.22.2)  
**Switch:** Aruba Instant On 1930 8G 2SFP PoE 124W (JL681A) — <admin-net2>.22  
**APs:** 4× Aruba Instant On AP22 — .11.20, .11.47, .11.88, .11.32  

---

## Goal

Separate the flat <admin-net>.0/23 network into three isolated segments:

| VLAN | Subnet | Purpose |
|------|--------|---------|
| 1 (native/untagged) | <admin-net>.0/24 | Servers, Proxmox, static infrastructure |
| 20 | <admin-net2>.0/24 | Personal devices — phones, laptops, tablets |
| 30 | 192.168.30.0/24 | IoT — ESP/ESPEasy, Tuya, cameras, appliances |

### Traffic policy (directional isolation)

```
IoT (VLAN 30)     → personal/servers   BLOCKED   (compromised device can't attack you)
Personal (VLAN 20) → IoT (VLAN 30)    ALLOWED   (you can view cameras, control plugs)
Personal (VLAN 20) → Servers (VLAN 1) ALLOWED   (access Proxmox, Pi-hole, etc.)
Servers (VLAN 1)   → IoT (VLAN 30)   ALLOWED   (NVR software can pull camera streams)
All VLANs          → Internet         ALLOWED   (cloud cameras, Tuya, updates)
IoT                → IoT              BLOCKED   (lateral movement prevention)
```

### Why this model

Cloud cameras (Tapo C210, Reecam) and Tuya devices make outbound connections to their
cloud — those continue working regardless of VLAN. Local RTSP streams and camera web UIs
work because your phone (VLAN 20) initiates the connection to the camera (VLAN 30), and
the firewall allows that direction. Return traffic is permitted by connection tracking.
Only IoT-initiated connections toward personal/servers are blocked.

---

## Step 1 — Aruba Instant On App (YOU do this first)

**Do this before any MikroTik changes.** Enabling VLAN filtering on MikroTik before
the Aruba side is configured will cut off all WiFi clients.

### 1a. Create IoT network (VLAN 30)

1. Open Aruba Instant On app or portal: https://portal.arubainstanton.com
2. Go to **Networks** → **Add Network**
3. Name: `AZNET-IoT` (or any name you prefer)
4. Type: Employee or Guest (Employee recommended for IoT)
5. VLAN: **30** (custom VLAN, not default)
6. Set a separate password for IoT devices
7. Apply to all 4 APs

### 1b. Assign VLAN 20 to the existing personal SSID

1. Edit the existing **AZNET** network
2. Under VLAN settings → set VLAN ID to **20**
3. Save — clients will briefly reconnect and get new IPs from VLAN 20 pool

### 1c. Verify Aruba switch uplink

The Aruba 1930 switch will automatically configure its uplink (to MikroTik ether5)
as a trunk port once VLANs are defined in the app. Confirm in the switch settings
that VLANs 20 and 30 are tagged on the uplink port.

---

## Step 2 — MikroTik Router (run after Aruba app is done)

Connect via: `ssh admin@<admin-net>.1`

Run each block one at a time and verify before continuing.

### 2a. Create VLAN interfaces

```routeros
/interface vlan add name=vlan20-personal vlan-id=20 interface=bridge
/interface vlan add name=vlan30-iot      vlan-id=30 interface=bridge
```

### 2b. Assign IP addresses

```routeros
/ip address add address=<admin-net2>.1/24 interface=vlan20-personal
/ip address add address=192.168.30.1/24 interface=vlan30-iot
```

Note: remove the existing bridge IP for 192.168.11.x range once VLAN 20 is live.
The /23 bridge address (<admin-net>.1/23) covers .10.x only after split.

```routeros
# After verifying VLAN 20 is working:
/ip address remove [find address="<admin-net>.1/23"]
/ip address add address=<admin-net>.1/24 interface=bridge
```

### 2c. DHCP pools and servers

```routeros
/ip pool add name=pool-personal ranges=<admin-net2>.20-<admin-net2>.240
/ip pool add name=pool-iot      ranges=192.168.30.20-192.168.30.240

/ip dhcp-server add name=dhcp-personal interface=vlan20-personal \
    address-pool=pool-personal lease-time=2h disabled=no
/ip dhcp-server add name=dhcp-iot      interface=vlan30-iot \
    address-pool=pool-iot      lease-time=2h disabled=no

/ip dhcp-server network add address=<admin-net2>.0/24 \
    gateway=<admin-net2>.1 dns-server=<admin-net>.21
/ip dhcp-server network add address=192.168.30.0/24 \
    gateway=192.168.30.1 dns-server=<admin-net>.21
```

Pi-hole at <admin-net>.21 serves DNS for all VLANs. It must be reachable from
VLAN 20 and VLAN 30 — add a specific allow rule if needed (servers VLAN is
reachable from personal by default; for IoT, allow port 53 to .10.21 only).

### 2d. Bridge VLAN table

```routeros
/interface bridge vlan add bridge=bridge vlan-ids=20 tagged=bridge,ether5
/interface bridge vlan add bridge=bridge vlan-ids=30 tagged=bridge,ether5
```

### 2e. Enable VLAN filtering — BRIEF OUTAGE

```routeros
/interface bridge set bridge vlan-filtering=yes
```

All clients will briefly lose connectivity and reconnect on their respective VLAN.

### 2f. Firewall rules (add before existing forward rules)

```routeros
# 1. Allow established/related (return traffic for all initiated connections)
/ip firewall filter add chain=forward \
    connection-state=established,related action=accept place-before=0 \
    comment="Allow established/related"

# 2. Allow IoT to reach Pi-hole DNS only (not full server access)
/ip firewall filter add chain=forward \
    src-address=192.168.30.0/24 dst-address=<admin-net>.21 \
    protocol=udp dst-port=53 action=accept \
    comment="IoT DNS to Pi-hole"
/ip firewall filter add chain=forward \
    src-address=192.168.30.0/24 dst-address=<admin-net>.21 \
    protocol=tcp dst-port=53 action=accept \
    comment="IoT DNS to Pi-hole TCP"

# 3. IoT cannot reach personal devices
/ip firewall filter add chain=forward \
    src-address=192.168.30.0/24 dst-address=<admin-net2>.0/24 \
    action=drop comment="IoT cannot reach personal"

# 4. IoT cannot reach servers
/ip firewall filter add chain=forward \
    src-address=192.168.30.0/24 dst-address=<admin-net>.0/24 \
    action=drop comment="IoT cannot reach servers"

# 5. Block IoT lateral movement (device-to-device within IoT VLAN)
/ip firewall filter add chain=forward \
    in-interface=vlan30-iot out-interface=vlan30-iot \
    action=drop comment="IoT lateral movement block"
```

---

## Step 3 — Move IoT devices to AZNET-IoT

After VLAN 30 is live, devices currently on AZNET that belong in IoT need to move:

**Manually reconnect these to AZNET-IoT:**
- All ESP/ESPEasy devices (update WiFi config in ESPEasy web UI)
- Tuya devices — re-pair in Tuya/Smart Life app on new SSID
- TP-Link Tapo plugs and cameras — re-pair in Tapo app
- Samsung Washer — SmartThings re-pair
- Midea AC — re-pair in Midea Air app
- Broadlink RM Mini — re-pair in Broadlink app
- eufy RoboVacs — re-pair in eufy Home app
- Amazon Echo/Fire devices — change WiFi in Alexa/Amazon app

**Stay on personal SSID (AZNET, VLAN 20):**
- iPhones, iPads
- Android phones (Pixel 9 Pro, Pixel 9 Pro XL)
- Laptops (JosePC, alza Dell, RUGBOOKGO5G)
- Amazon Echo Show (kept personal for voice control responsiveness)

**Stay on VLAN 1 (wired/static, no change):**
- All Proxmox hosts and VMs (.10.x range)
- MikroTik CSS326 switch
- .10.70 IPCAM (wired, static IP)

---

## Rollback procedure

If anything breaks during Step 2, restore flat network:

```routeros
/interface bridge set bridge vlan-filtering=no
/ip dhcp-server disable dhcp-personal
/ip dhcp-server disable dhcp-iot
```

This immediately restores the flat bridge. All clients reconnect within seconds.
The existing `defconf` DHCP server on the bridge is still there and takes over.

---

## Open items / follow-up

- [ ] Step 1: Aruba Instant On app — create AZNET-IoT SSID (VLAN 30), assign VLAN 20 to AZNET
- [ ] Step 2: MikroTik VLAN configuration (run after Aruba is done)
- [ ] Step 3: Move IoT devices to new SSID
- [ ] Consider adding Prometheus node-exporter auth after VLAN split (ports 9100 exposed on VLAN 1)
- [ ] Pi-hole upgrade v5 → v6 on <admin-net>.21
- [ ] Camera review: confirm Reecam .11.45/.11.98/.11.99 ownership and change default creds
- [ ] Corporate device .11.43 (IT-CR-ZF-0761): confirm owner, consider isolating to guest VLAN
- [ ] Two old Amazon devices (.11.71, .11.86) on kernel 3.18 — no patches available, monitor
- [ ] Android 11 device (.11.57) — EOL OS, encourage upgrade
- [ ] Clean credentials: remove SSHUSER/SSHPASS from ~/.bashrc on claude-agent host
