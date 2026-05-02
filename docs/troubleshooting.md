# ProxLab — Troubleshooting & Known Issues

A log of real problems encountered during the ProxLab build, with root cause analysis and solutions. Useful for anyone building a similar Windows AD lab on Proxmox.

---

## Issue 1 — Windows VM clones share the same SID, blocking domain join

**Stage:** Stage 5 — DC-02 domain join  
**Symptom:**
```
Add-Computer : failed to join domain 'corp.lab' from its current workgroup 'WORKGROUP'
with following error message: The domain join cannot be completed because the SID of
the domain you attempted to join was identical to the SID of this machine. This is a
symptom of an improperly cloned operating system install. You should run sysprep on
this machine in order to generate a new machine SID.
FullyQualifiedErrorId : FailToJoinDomainFromWorkgroup
```

**Root cause:**

When a Windows VM is cloned from a sysprepped Proxmox template, each clone should run through sysprep's *specialize* pass on first boot, generating a unique machine SID. However, if the first clone (DC-01) was promoted to a domain controller, its SID becomes the **domain SID**. If a second clone (DC-02) ends up with the same SID — because the specialize pass did not generate a sufficiently unique SID on that hardware profile — it will be rejected when trying to join the domain it is identical to.

This is a known edge case in Proxmox LVM-thin cloning: the virtual hardware presented to both VMs is identical (same virtual BIOS, same MAC prefix before Proxmox randomises it, etc.), which can cause Windows to derive the same SID from the hardware fingerprint during specialize.

**Fix:**

Run sysprep `/generalize` on the affected clone before attempting the domain join. This discards the current SID and forces a full re-specialization on next boot:

```powershell
# Run on the affected VM (e.g. DC-02) as Administrator
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /reboot
```

The VM will reboot, run through OOBE (you will need to set the Administrator password again), and come back with a new unique SID. The domain join will then succeed normally.

**Prevention:**

For any Windows VM cloned from a Proxmox template that will join an existing domain, verify the SID is unique before joining:

```powershell
# Check the machine SID
(Get-WmiObject Win32_ComputerSystem).Name
whoami /user   # shows domain SID after join — compare beforehand with:
psgetsid.exe . # from Sysinternals, shows local machine SID
```

If building multiple clones in sequence, run sysprep `/generalize /oobe /shutdown` on each clone immediately after first boot and before any configuration, then start the VM again for the actual setup. This guarantees a fresh SID on every clone.

---

## Issue 2 — Enterprise CA installs as Standalone CA (CAType 3) blocking all template operations

**Stage:** Stage 6 — PKI-01 Enterprise CA installation  
**Symptom:**

All certificate template operations fail silently or with `ERROR_NOT_FOUND`/`element not found`:
```
certutil -catemplates        → element not found
certutil -SetCAtemplates +DomainController → ERROR_NOT_FOUND (1168)
certutil -getreg CA\DSConfigDN → ERROR_FILE_NOT_FOUND
certutil -getreg CA\CAType   → 3   ← should be 0 for Enterprise Root
```
DCs cannot auto-enroll for Domain Controller certificates. LDAPS cannot be enabled.

**Root cause:**

`Install-AdcsCertificationAuthority -CAType EnterpriseRootCa` silently falls back to **Standalone Root CA** (CAType 3) when the installing user does not have Enterprise Admin / Domain Admin privileges at install time, or when the domain membership is not fully recognized. In this build, the first CA install attempts were made before logging in as `CORP\Administrator` (local Administrator was used instead), causing the CA to install without AD integration.

**Fix:**

Uninstall, remove the feature, reboot, then reinstall — all as `CORP\Administrator`:

```powershell
# Step 1 — remove CA and feature
Uninstall-AdcsCertificationAuthority -Force
Remove-WindowsFeature ADCS-Cert-Authority,ADCS-Web-Enrollment
Restart-Computer -Force

# Step 2 — reinstall as CORP\Administrator
Install-WindowsFeature ADCS-Cert-Authority,ADCS-Web-Enrollment -IncludeManagementTools
Install-AdcsCertificationAuthority `
    -CAType EnterpriseRootCa `
    -CACommonName 'CORP-LAB-Root-CA' `
    -KeyLength 2048 `
    -HashAlgorithmName SHA256 `
    -ValidityPeriod Years `
    -ValidityPeriodUnits 5 `
    -Force
```

Verify it installed correctly:
```powershell
certutil -getreg CA\CAType        # must return 0
certutil -getreg CA\DSConfigDN    # must return CN=Configuration,DC=corp,DC=lab
certutil -catemplates             # must list templates
```

**Prevention:**

Always log in as a **domain admin** (`CORP\Administrator` or equivalent) before installing Enterprise CA. Local Administrator has no AD privileges and silently causes the fallback to Standalone mode.

---

## Issue 3 — ADCS registry corruption after failed uninstall/reinstall cycle

**Stage:** Stage 6 — PKI-01 Enterprise CA reinstall  
**Symptom:**
```
The service failed to start.
Event log: ADCS cannot find required registry information, needs to be reinstalled.
```
`certsvc` stops and refuses to start after a failed CA installation followed by uninstall and reinstall attempts.

**Root cause:**

Multiple failed `Install-AdcsCertificationAuthority` attempts (due to wrong user context, range constraint errors, and Standalone vs Enterprise confusion) left the registry in an inconsistent state. The CA database files and some registry keys persisted while others were removed, causing certsvc to fail on startup.

**Fix:**

Full feature removal, reboot, and clean reinstall — all as `CORP\Administrator`:

```powershell
Uninstall-AdcsCertificationAuthority -Force
Remove-WindowsFeature ADCS-Cert-Authority,ADCS-Web-Enrollment
Restart-Computer -Force

# After reboot, as CORP\Administrator:
Install-WindowsFeature ADCS-Cert-Authority,ADCS-Web-Enrollment -IncludeManagementTools
Install-AdcsCertificationAuthority `
    -CAType EnterpriseRootCa `
    -CACommonName 'CORP-LAB-Root-CA' `
    -KeyLength 2048 -HashAlgorithmName SHA256 `
    -ValidityPeriod Years -ValidityPeriodUnits 5 `
    -OverwriteExistingKey -OverwriteExistingDatabase -Force
```

Use `-OverwriteExistingKey` and `-OverwriteExistingDatabase` to clear any leftover state from previous attempts.

---

## Issue 4 — WS2022 template clones are Evaluation edition — must convert before production use

**Stage:** Stage 4+ — any VM cloned from template 22201  
**Symptom:**

`winver` or `slmgr /dli` shows `Windows Server 2022 Datacenter Evaluation` with a 180-day activation timer. Some features (e.g. certificate auto-enrollment) may behave differently on eval builds.

**Root cause:**

The WS2022 template (22201) was built from an evaluation ISO. Every clone inherits the eval edition. The 180-day timer is per-VM and starts at first boot, so for a lab this is workable, but converting to a licensed edition is cleaner and avoids expiry issues.

**Fix:**

Run on each affected VM (requires reboot):

```powershell
# Convert eval to Standard (no GUI) — use a KMS or MAK key, or a generic lab key
DISM /Online /Set-Edition:ServerStandard /ProductKey:VDYBN-27WPP-V4HQT-9VMD4-VMK7H /AcceptEula /Quiet
# Reboot when prompted
```

For a domain controller specifically, do this before or after promotion — both work. Converting triggers a reboot which also helps flush GPO and certificate auto-enrollment.

**Prevention:**

For a permanent lab setup, rebuild template 22201 from a non-eval ISO or a volume-licensed ISO. Alternatively, convert the template by starting it (which consumes the sysprep state), converting, re-running sysprep `/generalize /oobe /shutdown`, and re-templating.

---

## Issue 3 — DHCP authorization fails: "unable to create or lookup the DHCP user local group": "unable to create or lookup the DHCP user local group"

**Stage:** Stage 4 — DC-01 DHCP configuration  
**Symptom:**
```
Add-DhcpServerInDC : The DHCP service was unable to create or lookup the DHCP user
local group in this computer.
```

**Root cause:**

After installing the DHCP Server Windows feature, the service requires a post-install configuration step to initialize its local security groups (`DHCP Users`, `DHCP Administrators`). This step is normally triggered through the Server Manager post-deployment notification. When skipped and `Add-DhcpServerInDC` is called directly via PowerShell, the service hasn't completed initialization and the local groups don't exist yet.

**Fix:**

Manually mark the DHCP configuration state as complete and restart the service before authorizing:

```powershell
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' `
    -Name 'ConfigurationState' -Value 2
Restart-Service dhcpserver

# Now authorization works
Add-DhcpServerInDC -DnsName dc-01.corp.lab -IPAddress 10.10.1.10
```

---

## Issue 3 — pip install fails: "Cannot uninstall cryptography, RECORD file not found"

**Stage:** Stage 3 — claude-lxc tool stack installation  
**Symptom:**
```
ERROR: Cannot uninstall cryptography 41.0.7, RECORD file not found.
Hint: The package was installed by debian.
```

**Root cause:**

`impacket` depends on a newer version of `cryptography` than the one shipped with Ubuntu/Debian. When pip attempts to upgrade it, it fails because the system-managed package was installed without a pip RECORD file (it was installed via `apt`, not `pip`).

**Fix:**

Use `--ignore-installed` to allow pip to install its own copy of `cryptography` alongside the system one:

```bash
pip3 install --break-system-packages --ignore-installed cryptography impacket
```

**Note:** `--break-system-packages` is required on Ubuntu 24.04+ (PEP 668) when installing pip packages system-wide without a virtual environment. For a production system use a venv; for a lab ops container this is acceptable.

---

## Issue 4 — Ansible fails with "unsupported locale setting"

**Stage:** Stage 3 — claude-lxc tool stack installation  
**Symptom:**
```
ERROR: Ansible could not initialize the preferred locale: unsupported locale setting
```

**Root cause:**

The Ubuntu 24.04 LXC container template ships without a fully generated locale. Ansible reads the system locale at startup and fails if it is not valid.

**Fix:**

Set `LANG=C.UTF-8` before running any ansible command, and persist it:

```bash
# Immediate fix
LANG=C.UTF-8 ansible --version

# Persist in shell profile
echo 'LANG=C.UTF-8' >> /root/.bashrc
echo 'export LANG' >> /root/.bashrc
```

---

## Issue 5 — claude-lxc loses default gateway after manual IP reconfiguration

**Stage:** Stage 3 — claude-lxc network setup  
**Symptom:**

After running `ip addr flush dev eth1 && ip addr add <mgmt-ip>/23 dev eth1`, the container loses internet access. `ip route` shows no default gateway.

**Root cause:**

`ip addr flush` removes all addresses **and associated routes** from the interface, including the default gateway that systemd-networkd had configured. The manual `ip addr add` only restores the address, not the route.

**Fix:**

Restore the default gateway manually after the flush, or (better) just restart systemd-networkd to re-apply the full configuration from its unit files:

```bash
# Option 1 — manual route restore
ip route add default via <mgmt-ip> dev eth1

# Option 2 — let networkd re-apply everything cleanly
systemctl restart systemd-networkd
```

The Proxmox LXC network config (`/etc/pve/lxc/<id>.conf`) already contains the correct gateway — networkd picks it up from `/etc/systemd/network/eth1.network` which Proxmox generates automatically. Restarting networkd is always the cleaner fix.
