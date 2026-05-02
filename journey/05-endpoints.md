# Stage 5 — Endpoints (WS-01–03, LX-01, LX-02, ATK-01)

## Goal

Deploy the endpoint tier: three Win11 domain workstations, two Linux VMs AD-joined via realmd, and a Kali attacker machine. This is the most interesting VLAN — it's where users (or attackers) live.

---

## Win11 workstations — template clone workflow

Win11 was built once as a template (`win11-tmpl`, VM 22212) and cloned three times. This is the fastest way to get three identical, up-to-date workstations:

```bash
# Convert sysprepped VM to template
qm template 22212
qm set 22212 --name win11-tmpl

# Clone ×3
qm clone 22212 22213 --name WS-01 --full
qm clone 22212 22214 --name WS-02 --full
qm clone 22212 22215 --name WS-03 --full
```

Configure networking on each clone:

```bash
qm set <vmid> --net0 virtio,bridge=vmbr1,tag=300 --net1 virtio,bridge=vmbr0
qm start <vmid>
```

After Windows boots into OOBE:
- Choose **"Set up for work or school"** → **"Domain join instead"** (bottom-left)
- Set a local Administrator password
- Complete setup, then set static IPs and domain-join:

```powershell
# Static IPs: WS-01=10.10.3.10, WS-02=10.10.3.11, WS-03=10.10.3.12
New-NetIPAddress -InterfaceAlias <lab-nic> -IPAddress 10.10.3.1x -PrefixLength 24 -DefaultGateway 10.10.3.1
Set-DnsClientServerAddress -InterfaceAlias <lab-nic> -ServerAddresses 10.10.1.10,10.10.1.11

Add-Computer -DomainName corp.lab -OUPath 'OU=Endpoints,DC=corp,DC=lab' -Restart -Force
```

---

## LX-01 — Ubuntu 24.04 (cloud-init + realmd)

LX-01 is cloned from the Ubuntu cloud-init template and AD-joined via `realmd`. This is the Linux equivalent of a domain workstation.

```bash
qm clone 22200 22216 --name LX-01 --full 1 --storage vms-512gb
qm set 22216 --memory 2048 --balloon 0 --cores 2 --cpu host \
  --net0 virtio,bridge=vmbr1,tag=300,firewall=0 \
  --net1 virtio,bridge=vmbr0
qm set 22216 \
  --cicustom "vendor=local:snippets/lx-vendor.yaml" \
  --ciuser ubuntu --cipassword "YourPassword" \
  --nameserver "10.10.1.10" --searchdomain corp.lab \
  --ipconfig0 ip=10.10.3.20/24,gw=10.10.3.1
qm cloudinit update 22216
qm start 22216
```

**Blocker: SSH password auth blocked by cloud images**

Ubuntu and Debian cloud images disable SSH password authentication by default. After cloning, SSH logins were rejected even with the correct password.

**Fix:** Use a `vendor` cloud-init snippet (not `user` — that replaces Proxmox's generated config) to enable it:

```bash
# /var/lib/vz/snippets/lx-vendor.yaml
cat > /var/lib/vz/snippets/lx-vendor.yaml << 'EOF'
#cloud-config
ssh_pwauth: true
package_update: true
packages:
  - qemu-guest-agent
  - sssd
  - realmd
  - adcli
  - samba-common-bin
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF
```

**Why `vendor=` and not `user=`?**

`cicustom user=` replaces Proxmox's generated user-data entirely, which means `cipassword` and SSH key injection stop working. `cicustom vendor=` merges with the generated config — you get Proxmox's defaults plus your additions.

**Forcing cloud-init to re-run after fixing the snippet:**

cloud-init only runs once per boot if the instance ID hasn't changed. To force a re-run after fixing `lx-vendor.yaml`, change the VM's UUID:

```bash
qm set 22216 --smbios1 "uuid=$(uuidgen)"
qm reboot 22216
```

**AD join:**

```bash
sudo realm join --user=Administrator corp.lab
```

After join, update DNS to point to the DCs:

```bash
echo "nameserver 10.10.1.10
nameserver 10.10.1.11" > /etc/resolv.conf
```

---

## LX-02 — Debian 13

Same process as LX-01. Debian 13 (`debian-13-cloud-amd64.qcow2`) uses the same cloud-init vendor snippet approach.

```bash
qm create 22217 --name LX-02 ...
qm importdisk 22217 debian-13-cloud-amd64.qcow2 vms-512gb
```

Static IP: `10.10.3.21/24`, gateway `10.10.3.1`.

---

## ATK-01 — Kali Linux

ATK-01 is the attacker machine. It lives on VLAN 300 but RT-01 has an explicit allow rule letting it reach VLAN 400 (the DMZ). No AD join — it's adversarial.

```bash
# Download Kali ISO, create VM
qm create 22218 --name ATK-01 --memory 4096 --cores 2 --cpu host \
  --net0 virtio,bridge=vmbr1,tag=300 \
  --net1 virtio,bridge=vmbr0 \
  --ostype l26 --agent enabled=1
```

Static IP: `10.10.3.30/24`, gateway `10.10.3.1`.

Copy your management SSH pubkey to ATK-01 so you can drive it from claude-lxc:

```bash
ssh-copy-id root@10.10.3.30
```

---

## Lessons learned

| Issue | Fix |
|---|---|
| `cicustom user=` breaks `cipassword` and SSH key injection | Always use `cicustom vendor=` — it merges with Proxmox-generated config |
| Cloud images block SSH password auth | Add `ssh_pwauth: true` to vendor snippet |
| cloud-init won't re-run after snippet fix | Change VM UUID with `qm set --smbios1 "uuid=$(uuidgen)"` and reboot |
| Win11 OOBE: Microsoft account forced | Choose "Set up for work or school" → "Domain join instead" |
| Linux DNS breaks after domain join | Update `/etc/resolv.conf` to DCs after realm join |
