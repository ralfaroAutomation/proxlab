# Stage 1 — Proxmox Setup & VM Templates

## Goal

Get Proxmox running on the hardware, set up storage properly, and build the two reusable VM templates that every other stage depends on: a Windows Server 2022 sysprep base and an Ubuntu 24.04 cloud-init base.

---

## Hardware

Lenovo ThinkStation S30 V1. Xeon E5-2650L, 128 GB ECC, two NVMe drives. You can find these for ~€100–150 second-hand. The Xeon E5-26xx family is an excellent ProxLab host — ECC RAM, plenty of cores, and enough RAM to run 15+ VMs simultaneously.

**One immediate problem:** the Win11 ISO rejects this CPU. More on that below.

---

## Storage setup

Two separate LVM-thin pools — one per NVMe:

```bash
# 1 TB Intel NVMe → server/DC workloads (larger VMs)
pvesm add lvmthin vms-1tb --thinpool vms-1tb --vgname pve

# 512 GB T-Force NVMe → endpoints, DMZ, LXCs (smaller VMs, more I/O)
pvesm add lvmthin vms-512gb --thinpool vms-512gb --vgname pve
```

Splitting across two drives gives you independent I/O paths. DC-01 and the SIEM doing heavy writes won't compete with endpoint VMs.

**Lesson:** Wipe any existing partition tables before adding drives to Proxmox — leftover Windows or old LVM signatures cause `pvesm add` to fail silently.

```bash
wipefs -a /dev/nvme0n1
```

---

## Ubuntu 24.04 cloud-init template (22200)

Cloud-init templates let you spin up a configured Linux VM in ~2 minutes instead of going through an installer. Build this once, clone forever.

```bash
# Download the cloud image
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# Create the VM skeleton
qm create 22200 --name ubuntu-2404-tmpl --memory 2048 --cores 2 --cpu host \
  --machine q35 --bios ovmf \
  --efidisk0 vms-1tb:1,efitype=4m,pre-enrolled-keys=1 \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr1,firewall=0 \
  --agent enabled=1 --ostype l26

# Import the cloud image as the boot disk
qm importdisk 22200 noble-server-cloudimg-amd64.img vms-1tb
qm set 22200 --scsi0 vms-1tb:vm-22200-disk-1,discard=on,ssd=1 \
  --ide2 vms-1tb:cloudinit \
  --boot order=scsi0

# Convert to template
qm template 22200
```

Each clone gets its own cloud-init config (IP, hostname, SSH keys, packages) without touching the template.

---

## Windows Server 2022 sysprep template (22201)

The WS2022 template is the base for DC-01, DC-02, PKI-01, FS-01, APP-01, SQL-01, and WSUS-01. Build it once from the ISO, sysprep it, and clone.

```bash
qm create 22201 --name ws2022-tmpl --memory 4096 --cores 2 --cpu host \
  --machine q35 --bios ovmf \
  --efidisk0 vms-1tb:1,efitype=4m,pre-enrolled-keys=1 \
  --tpmstate0 vms-1tb:1,version=v2.0 \
  --scsihw virtio-scsi-single \
  --scsi0 vms-1tb:40,discard=on,ssd=1 \
  --ide2 local:iso/win2022.iso,media=cdrom \
  --ide0 local:iso/virtio-win.iso,media=cdrom \
  --net0 virtio,bridge=vmbr0,firewall=0 \
  --agent enabled=1 --ostype win11 --onboot 0 \
  --boot order='ide2;scsi0'
qm start 22201
```

During install, load VirtIO storage drivers from the second CD (`virtio-win.iso`, path `D:\amd64\2k22`) — otherwise the installer won't see the disk.

After install + QEMU Guest Agent, run sysprep:

```cmd
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

Then convert to template:

```bash
qm template 22201
```

---

## Windows 11 template (22212)

Win11 requires TPM 2.0 and Secure Boot — Proxmox handles both with `q35 + ovmf + tpmstate0`. But the stock Win11 ISO rejects old Xeon CPUs (E5-26xx series) during setup.

**Blocker: "This PC doesn't meet the minimum system requirements"**

The Xeon E5-2650L doesn't match Microsoft's official CPU list for Win11. The installer checks at the beginning of setup and refuses to continue.

**Fix:** Use a modded ISO that removes the CPU/TPM/RAM checks:

```bash
# Download Windows11-modded.iso (bypasses CPU/TPM/RAM checks)
# Build the VM with q35 + OVMF + TPM (still required by the OS, just not enforced at setup)
qm create 22212 --name win11-build --machine q35 --bios ovmf \
  --efidisk0 vms-512gb:1,efitype=4m,pre-enrolled-keys=1 \
  --tpmstate0 vms-512gb:1,version=v2.0 \
  --scsi0 vms-512gb:60,discard=on,ssd=1 \
  --ide2 local:iso/Windows11-modded.iso,media=cdrom \
  --ide0 local:iso/virtio-win.iso,media=cdrom \
  --net0 virtio,bridge=vmbr0 \
  --memory 3072 --cores 2 --cpu host --agent enabled=1
```

After installing, running Windows Update fully, and verifying the image is clean:

```cmd
C:\Windows\System32\Sysprep\sysprep.exe /oobe /generalize /shutdown
```

```bash
qm template 22212 && qm set 22212 --name win11-tmpl
```

Clone ×3 for WS-01/02/03:

```bash
qm clone 22212 22213 --name WS-01 --full
qm clone 22212 22214 --name WS-02 --full
qm clone 22212 22215 --name WS-03 --full
```

---

## Lessons learned

| Issue | Fix |
|---|---|
| Win11 installer rejects old Xeon | Use a modded ISO that skips CPU/TPM/RAM checks |
| VirtIO disk not visible during WS2022 setup | Load driver from `virtio-win.iso` → `D:\amd64\2k22` before partitioning |
| `pvesm add` fails on drive with old partition table | Run `wipefs -a /dev/nvmeXnX` first |
| WS2022 ISO is Evaluation edition | Convert post-install: `DISM /Online /Set-Edition:ServerStandard /ProductKey:...` |
