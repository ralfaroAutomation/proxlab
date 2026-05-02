# Stage 7 — AI Integration (claude-lxc)

## Goal

Wire Claude into the lab as a permanent operator — able to query AD, run PowerShell on Windows VMs via WinRM, run Ansible against Linux VMs, read Wazuh alerts, and scan the network. All without storing passwords.

---

## Two agents, two roles

| Agent | Lives where | Role |
|---|---|---|
| **Builder** (Claude Code) | Your workstation / management host | Orchestrates the build via SSH + `qm` commands on the Proxmox host |
| **claude-lxc** (CT 22202) | Inside ProxLab permanently | Operates the lab — WinRM, Ansible, Kerberos, Nmap, Wazuh API |

The builder is ephemeral — it only exists during build sessions. claude-lxc is always on and is the sole management path into the lab once the build is complete.

---

## claude-lxc setup

```bash
# Create the LXC
pct create 22202 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname claude-lxc --memory 4096 --cores 2 \
  --rootfs vms-512gb:20 --privileged 1 --features nesting=1 \
  --net0 name=eth0,bridge=vmbr1,ip=10.10.0.50/24,gw=10.10.0.1 \
  --net1 name=eth1,bridge=vmbr0,ip=<mgmt-ip>/24,gw=<mgmt-gw> \
  --onboot 1 --start 1
```

Install the tool stack:

```bash
apt install -y nmap ansible python3-pip sshpass krb5-user ldap-utils git jq dnsutils
pip3 install --break-system-packages ldap3 pywinrm impacket paramiko requests httpx python-nmap
ansible-galaxy collection install community.windows community.general
```

**Blocker: `impacket` pip install fails — "Cannot uninstall cryptography, RECORD file not found"**

`impacket` requires a newer `cryptography` than the system-managed apt version. pip can't upgrade what apt installed because it has no RECORD file.

**Fix:**

```bash
pip3 install --break-system-packages --ignore-installed cryptography impacket
```

**Blocker: Ansible fails with "unsupported locale setting"**

The Ubuntu LXC template ships without a fully generated locale. Ansible reads it at startup and aborts.

**Fix:**

```bash
echo 'LANG=C.UTF-8' >> /root/.bashrc
echo 'export LANG' >> /root/.bashrc
```

---

## Kerberos auth — no passwords stored

claude-lxc uses Kerberos keytabs instead of passwords. Two service accounts:

| Account | Privileges | Default state |
|---|---|---|
| `svc-claude-ro` | Read-only — LDAP, WMI, Wazuh read, WSUS read | Always enabled |
| `svc-claude-rw` | Write — WinRM exec, AD account management, service restart | **Disabled by default** |

Create accounts on DC-01:

```powershell
$pwRO = ConvertTo-SecureString 'ChangeMe-RO!' -AsPlainText -Force
New-ADUser -Name svc-claude-ro -SamAccountName svc-claude-ro `
    -UserPrincipalName svc-claude-ro@corp.lab `
    -Path 'OU=ServiceAccounts,DC=corp,DC=lab' `
    -AccountPassword $pwRO -Enabled $true -PasswordNeverExpires $true

$pwRW = ConvertTo-SecureString 'ChangeMe-RW!' -AsPlainText -Force
New-ADUser -Name svc-claude-rw -SamAccountName svc-claude-rw `
    -UserPrincipalName svc-claude-rw@corp.lab `
    -Path 'OU=ServiceAccounts,DC=corp,DC=lab' `
    -AccountPassword $pwRW -Enabled $false -PasswordNeverExpires $true
```

Generate keytabs on DC-01:

```powershell
ktpass -princ svc-claude-ro@CORP.LAB -mapuser CORP\svc-claude-ro `
    -pass 'ChangeMe-RO!' -ptype KRB5_NT_PRINCIPAL -crypto AES256-SHA1 `
    -out C:\svc-claude-ro.keytab
```

Pull to claude-lxc:

```bash
mkdir -p /etc/krb5
smbclient //dc-01.corp.lab/c$ -U CORP/Administrator \
    -c 'get svc-claude-ro.keytab /etc/krb5/svc-claude-ro.keytab'
chmod 600 /etc/krb5/svc-claude-*.keytab
```

Configure `/etc/krb5.conf`:

```ini
[libdefaults]
    default_realm = CORP.LAB
    dns_lookup_realm = false
    dns_lookup_kdc = true
[realms]
    CORP.LAB = {
        kdc = dc-01.corp.lab
        kdc = dc-02.corp.lab
        admin_server = dc-01.corp.lab
    }
[domain_realm]
    .corp.lab = CORP.LAB
    corp.lab  = CORP.LAB
```

Test:

```bash
kinit -kt /etc/krb5/svc-claude-ro.keytab svc-claude-ro@CORP.LAB && klist
ldapsearch -H ldaps://dc-01.corp.lab -Y GSSAPI -b "DC=corp,DC=lab" "(objectClass=user)" sAMAccountName
```

---

## Driving the lab via guest agent

During the build phase, before Kerberos is wired up, the Proxmox QEMU guest agent is the most powerful tool available. It lets you run PowerShell directly inside any VM without needing WinRM, network access, or credentials — just a running guest agent and SSH access to the Proxmox host.

```bash
# Run PowerShell inside a VM (synchronous, returns output)
qm guest exec <vmid> --sync --timeout 30 -- \
    powershell.exe -NonInteractive -Command "Get-Service | Where-Object Status -eq Running"

# For long scripts, encode as UTF-16LE base64 to avoid shell quoting issues
PS_ENCODED=$(printf '%s' "$PS_SCRIPT" | iconv -f UTF-8 -t UTF-16LE | base64 -w 0)
qm guest exec <vmid> -- powershell.exe -NonInteractive -EncodedCommand "$PS_ENCODED"
```

This is how Windows Update, DNS changes, and domain joins were scripted across all VMs without WinRM being set up yet. See the [`scripts/`](../scripts/) directory for examples.

---

## What Claude can do once wired in

With `svc-claude-ro` active and `svc-claude-rw` available for approved sessions:

| Operation | How |
|---|---|
| Query AD users, groups, OUs | LDAP via `ldap3` + Kerberos GSSAPI |
| Run PowerShell on any Windows VM | WinRM via `pywinrm` + Kerberos |
| Run playbooks against Linux VMs | Ansible SSH |
| Read SIEM alerts | Wazuh REST API |
| Scan a subnet | Nmap via `python-nmap` |
| Isolate a compromised host | MikroTik API or WinRM firewall rule |

The `svc-claude-rw` account is **disabled by default** and enabled only for specific approved actions, then disabled again immediately. Every action is logged to `/var/log/claude-agent/actions.log`.

---

## Lessons learned

| Issue | Fix |
|---|---|
| `impacket` pip install fails (system cryptography conflict) | Use `--ignore-installed cryptography` |
| Ansible fails on fresh Ubuntu LXC | Set `LANG=C.UTF-8` in `.bashrc` |
| claude-lxc loses default gateway after `ip addr flush` | Use `systemctl restart systemd-networkd` instead of manual route restore |
| Storing passwords in scripts is a risk | Use Kerberos keytabs — `svc-claude-rw` disabled by default |
| Guest agent output parsing — not always base64 | `qm guest exec --sync` returns plain JSON; no base64 decoding needed |
