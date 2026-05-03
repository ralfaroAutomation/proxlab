# Stage 8 — Linux Endpoints (LX-01, LX-02)

## Goal

Domain-join two Linux VMs (Ubuntu 24.04 and Debian 13) to corp.lab using realmd/sssd, with dual-NIC network config (VLAN 300 lab + management AZNET).

---

## VM Config

| VM | ID | OS | Lab IP | Mgmt IP | ciuser |
|---|---|---|---|---|---|
| LX-01 | 22216 | Ubuntu 24.04 (cloud-init) | 10.10.3.20/24 | `<mgmt-ip>`/23 | ubuntu |
| LX-02 | 22217 | Debian 13 genericcloud | 10.10.3.21/24 | `<mgmt-ip>`/23 | debian |

Both cloned from cloud-init templates with a vendor snippet (`lx-vendor.yaml`) that pre-installs the domain-join stack and enables SSH password auth.

**Cloud-init vendor snippet** (`/var/lib/vz/snippets/lx-vendor.yaml` on the Proxmox host):

```yaml
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
```

> Use `cicustom vendor=local:snippets/lx-vendor.yaml` — not `user=`. `vendor` merges with Proxmox-generated user-data; `user` replaces it and bypasses `cipassword`.

---

## Network Setup

Each VM has two NICs:

| Interface | Bridge | VLAN | IP | Gateway | DNS |
|---|---|---|---|---|---|
| eth0 | vmbr1 | 300 | 10.10.3.20 or .21 | — | DC-01 10.10.1.10, DC-02 10.10.1.11 |
| eth1 | vmbr0 | native | `<mgmt-ip>` | `<mgmt-gw>` | Pi-hole `<mgmt-dns>` |

**Route required for domain join:** DC-01/DC-02 live on 10.10.1.x, which is a different VLAN 100 subnet. Traffic must go through RT-01 (10.10.3.1).

Netplan eth0 section (persisted in `/etc/netplan/50-cloud-init.yaml`):

```yaml
eth0:
  match:
    macaddress: "<mac>"
  addresses:
    - 10.10.3.20/24
  nameservers:
    addresses:
      - 10.10.1.10
      - 10.10.1.11
    search:
      - corp.lab
  routes:
    - to: 10.10.0.0/16
      via: 10.10.3.1
  set-name: eth0
```

After editing, apply with `sudo netplan apply`. Then verify: `resolvectl status | grep -A3 'Link 2'`.

---

## Domain Join Steps

```bash
# 1. SSH as the ciuser (ubuntu or debian — NOT root)
ssh ubuntu@<mgmt-ip>

# 2. Set eth0 DNS to DC-01 live (in case netplan hasn't applied yet)
sudo resolvectl dns eth0 10.10.1.10 10.10.1.11

# 3. Add route to DC subnet via RT-01
sudo ip route add 10.10.0.0/16 via 10.10.3.1 dev eth0

# 4. Verify DC reachability
ping -c 1 10.10.1.10

# 5. Join
echo '<domain-admin-pass>' | sudo realm join --user=Administrator corp.lab

# On Debian only — use --install=/ to bypass PackageKit check:
echo '<domain-admin-pass>' | sudo realm join --install=/ --user=Administrator corp.lab

# 6. Enable home dir auto-creation for AD logins
sudo bash -c 'echo "session required pam_mkhomedir.so skel=/etc/skel umask=0077" >> /etc/pam.d/common-session'

# 7. Verify
realm list
id administrator@corp.lab
```

---

## Blockers and Fixes

| Blocker | Fix |
|---|---|
| SSH as root fails — permission denied | ciuser is `ubuntu` (Ubuntu) or `debian` (Debian), not root. Check `qm config <vmid>` for `ciuser` |
| Pi-hole can't resolve corp.lab | Pi-hole is on AZNET, can't reach DC-01 (10.10.1.x). Set eth0 DNS directly to DC-01/DC-02 |
| DC-01 unreachable from VLAN 300 | No route to 10.10.1.0/24 by default. Add `10.10.0.0/16 via 10.10.3.1` (RT-01) on eth0 |
| `realm: command not found` on Debian | Binary is in `/usr/sbin/realm`, not in non-root PATH. Use `sudo /usr/sbin/realm` or install `realmd` |
| LX-02: realm refuses to join — "Necessary packages not installed" | PackageKit not available on Debian 13. Use `sudo realm join --install=/ ...` to bypass the check |
| LX-02 missing `sssd-tools`, `libnss-sss`, `libpam-sss` | `sudo apt install -y sssd-tools libnss-sss libpam-sss` before joining |
| LX-02: sssd inactive after join | sssd condition check fails on first run (no `.ldb` or `.log` files yet). `sudo systemctl start sssd` manually; auto-starts on subsequent boots |
| LX-02: `/etc/krb5.conf` warning during join | Warning only — realm creates the keytab anyway. sssd handles Kerberos config independently |

---

## Final State

Both VMs joined and resolving AD users:

```
corp.lab
  type: kerberos
  realm-name: CORP.LAB
  configured: kerberos-member
  server-software: active-directory
  client-software: sssd
  login-formats: %U@corp.lab
  login-policy: allow-realm-logins
```

```bash
$ id administrator@corp.lab
uid=797800500(administrator@corp.lab) gid=797800513(domain users@corp.lab)
groups=...,797800512(domain admins@corp.lab),...
```

---

## Lessons Learned

| Issue | Takeaway |
|---|---|
| Cloud-init `ciuser` is never `root` on standard cloud images | Always check `qm config <vmid>` for `ciuser` before SSHing |
| Management DNS (Pi-hole) can't forward to internal AD | Set eth0 DNS to DC-01/DC-02 and add a route before realm join; Pi-hole stays on mgmt NIC only |
| Debian 13 ships without PackageKit | `realm join --install=/` is the reliable path on Debian; avoids dependency on PackageKit for package checks |
| sssd won't auto-start on first boot if log/db dirs are empty | `systemctl start sssd` once manually after join; normal thereafter |
| `realm` binary in `/usr/sbin` — not always in $PATH | Use `sudo realm` (sudo preserves sbin path) or full path `/usr/sbin/realm` |
