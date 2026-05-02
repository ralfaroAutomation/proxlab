# Stage 6 — SIEM & Attack Lab (SIEM-01, VULN-01, VULN-02)

## Goal

Deploy Wazuh as the SIEM, stand up two intentionally vulnerable targets in the isolated DMZ, and run the first attack scenario — proving that the detection pipeline actually works.

---

## SIEM-01 — Wazuh all-in-one

SIEM-01 runs the Wazuh manager, indexer, and dashboard on a single Ubuntu 24.04 VM. It needs more resources than most VMs in the lab — 8 GB RAM and 60 GB disk.

```bash
qm clone 22200 22206 --name SIEM-01 --full 1 --storage vms-1tb
qm set 22206 --memory 8192 --balloon 0 --cores 4 --cpu host
qm resize 22206 scsi0 60G
qm set 22206 --ipconfig0 ip=10.10.1.20/24,gw=10.10.1.1 \
  --nameserver 10.10.1.10 --searchdomain corp.lab
qm start 22206
```

Install Wazuh all-in-one from inside the VM:

```bash
curl -sO https://packages.wazuh.com/4.9/wazuh-install.sh
sudo bash wazuh-install.sh -a
```

The installer prints admin credentials at the end — save them immediately:

```bash
scp ubuntu@10.10.1.20:/tmp/wazuh-install-files.tar /opt/claude-agent/secrets/
```

Dashboard: `https://10.10.1.20` (admin / from install output)

---

## Wazuh agent rollout

Push the Wazuh agent to all Windows VMs via PowerShell remoting:

```powershell
$servers = @('DC-01','DC-02','FS-01','APP-01','SQL-01','WSUS-01','WS-01','WS-02','WS-03')
$cred = Get-Credential CORP\Administrator

Invoke-Command -ComputerName $servers -Credential $cred -ScriptBlock {
    $url = 'https://packages.wazuh.com/4.x/windows/wazuh-agent-4.9.0-1.msi'
    Invoke-WebRequest $url -OutFile C:\wazuh-agent.msi
    msiexec /i C:\wazuh-agent.msi /qn WAZUH_MANAGER='10.10.1.20'
    Start-Service WazuhSvc
}
```

For Linux VMs (LX-01, LX-02), use Ansible from claude-lxc:

```yaml
# playbooks/deploy-wazuh-agent.yml
- hosts: linux_vms
  tasks:
    - name: Install Wazuh agent
      apt:
        deb: "https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.9.0-1_amd64.deb"
      environment:
        WAZUH_MANAGER: "10.10.1.20"
    - name: Start Wazuh
      service: name=wazuh-agent state=started enabled=yes
```

---

## DMZ — VULN-01 and VULN-02 (VLAN 400)

VLAN 400 is fully isolated — no routes to any other VLAN, no internet. Only ATK-01 (10.10.3.30) has an explicit allow rule on RT-01.

### VULN-01 — Metasploitable 2

```bash
# Download Metasploitable2 VMDK and import
qm create 22219 --name VULN-01 --memory 1024 --cores 1 --cpu host \
  --machine pc --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr1,tag=400,firewall=0 \
  --ostype l26 --onboot 0

qm importdisk 22219 /path/to/Metasploitable.vmdk vms-512gb --format qcow2
qm set 22219 --scsi0 vms-512gb:vm-22219-disk-0 --boot order=scsi0
```

Static IP inside the VM: `10.10.4.10/24`, gateway `10.10.4.1`.

### VULN-02 — DVWA on Debian

```bash
qm create 22220 --name VULN-02 --memory 1024 --cores 1 --cpu host \
  --net0 virtio,bridge=vmbr1,tag=400,firewall=0 --onboot 0
# Install Debian manually, then:
apt install apache2 php php-mysqli mariadb-server git
cd /var/www/html && git clone https://github.com/digininja/DVWA.git
```

Static IP: `10.10.4.11/24`.

---

## Attack scenario — ATK-01 → VULN-01

The full loop: launch an exploit from Kali, watch Wazuh fire.

From ATK-01:

```bash
msfconsole -q -x "use exploit/unix/ftp/vsftpd_234_backdoor; \
  set RHOSTS 10.10.4.10; run; exit"
```

From claude-lxc, check Wazuh for the alert:

```bash
curl -sk -u admin:password https://10.10.1.20/api/alerts \
  | python3 -m json.tool | grep -A5 "vsftpd\|10.10.4.10"
```

You should see a Wazuh alert for the connection attempt within seconds.

---

## Verifying VLAN 400 isolation

From claude-lxc (should fail — not ATK-01):

```bash
ping -c2 10.10.4.10   # should time out
```

From ATK-01 (should succeed):

```bash
nmap -sV 10.10.4.0/24 --open
```

If claude-lxc can reach VLAN 400, the RT-01 firewall rules need tightening.

---

## Lessons learned

| Issue | Fix |
|---|---|
| Wazuh installer credentials lost if not saved | Save immediately: `scp ubuntu@10.10.1.20:/tmp/wazuh-install-files.tar /somewhere/safe/` |
| VULN-01/02 must never reach corp.lab | Verify isolation before turning on — one misconfigured route and Metasploitable is on your AD network |
| Wazuh agent on Windows needs internet or local repo | Stage ISOs/packages locally if lab is air-gapped |
