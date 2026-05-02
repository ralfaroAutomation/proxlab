# Stage 3 — Core Identity (DC-01, DC-02, PKI-01)

## Goal

Stand up an Active Directory forest (`corp.lab`), a secondary DC for redundancy, and an Enterprise Certificate Authority — then enable LDAPS on both DCs.

---

## DC-01 — Forest root

Clone from the WS2022 template, set a static IP, and promote:

```powershell
# Rename and set IP
Rename-Computer -NewName DC-01 -Force
$if = (Get-NetAdapter | Where-Object Status -eq 'Up').Name
New-NetIPAddress -InterfaceAlias $if -IPAddress 10.10.1.10 -PrefixLength 24 -DefaultGateway 10.10.1.1
Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses 127.0.0.1
Restart-Computer -Force

# Promote to forest root
Install-WindowsFeature AD-Domain-Services,DNS,DHCP -IncludeManagementTools
$dsrm = ConvertTo-SecureString 'YourDSRMPassword' -AsPlainText -Force
Install-ADDSForest `
    -DomainName 'corp.lab' -DomainNetbiosName 'CORP' `
    -ForestMode 'WinThreshold' -DomainMode 'WinThreshold' `
    -InstallDns:$true -SafeModeAdministratorPassword $dsrm `
    -NoRebootOnCompletion:$false -Force:$true
```

After reboot, verify:

```powershell
Get-ADDomain; Get-ADForest
dcdiag /q   # should return no errors
```

---

## DC-02 — Secondary DC

**Blocker: identical machine SID blocks domain join**

After cloning DC-02 from the same template as DC-01, the domain join failed:

```
Add-Computer : The domain join cannot be completed because the SID of the domain you
attempted to join was identical to the SID of this machine.
```

When DC-01 was promoted, its machine SID became the domain SID. DC-02, cloned from the same template with the same virtual hardware profile, ended up with the same SID. Windows refused to join a domain it was identical to.

**Fix:** Run sysprep `/generalize` on DC-02 before domain join to force a new unique SID:

```cmd
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /reboot
```

Set the Administrator password again after reboot, then domain-join and promote:

```powershell
Add-Computer -DomainName corp.lab -Credential (Get-Credential CORP\Administrator) -Restart -Force

# After reboot, as CORP\Administrator:
Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools
$dsrm = ConvertTo-SecureString 'YourDSRMPassword' -AsPlainText -Force
Install-ADDSDomainController -DomainName 'corp.lab' -InstallDns:$true `
    -Credential (Get-Credential CORP\Administrator) `
    -SafeModeAdministratorPassword $dsrm -Force:$true
```

Verify replication:

```powershell
repadmin /replsummary
dcdiag /test:replications /test:dns
```

---

## PKI-01 — Enterprise Root CA

**Blocker: CA installs as Standalone instead of Enterprise**

After installing ADCS, `certutil -getreg CA\CAType` returned `3` (Standalone Root) instead of `0` (Enterprise Root). All certificate template operations failed:

```
certutil -catemplates  →  element not found
certutil -SetCAtemplates +DomainController  →  ERROR_NOT_FOUND (1168)
```

DCs couldn't auto-enroll for Domain Controller certificates. LDAPS couldn't be enabled.

**Root cause:** `Install-AdcsCertificationAuthority -CAType EnterpriseRootCa` silently falls back to Standalone when the installing user isn't a Domain Admin at install time. The first attempts were made as local Administrator (before domain join), which has no AD privileges.

**Fix:** Log in as `CORP\Administrator`, uninstall completely, reboot, reinstall:

```powershell
# Step 1 — remove everything
Uninstall-AdcsCertificationAuthority -Force
Remove-WindowsFeature ADCS-Cert-Authority,ADCS-Web-Enrollment
Restart-Computer -Force

# Step 2 — reinstall as CORP\Administrator
Install-WindowsFeature ADCS-Cert-Authority,ADCS-Web-Enrollment -IncludeManagementTools
Install-AdcsCertificationAuthority `
    -CAType EnterpriseRootCa `
    -CACommonName 'CORP-LAB-Root-CA' `
    -KeyLength 2048 -HashAlgorithmName SHA256 `
    -ValidityPeriod Years -ValidityPeriodUnits 5 `
    -Force
```

Verify:

```powershell
certutil -getreg CA\CAType        # must return 0
certutil -getreg CA\DSConfigDN    # must return CN=Configuration,DC=corp,DC=lab
certutil -catemplates             # must list templates
```

**Blocker: ADCS registry corruption after failed install cycle**

Multiple failed install attempts left the registry in an inconsistent state. `certsvc` refused to start after reinstall.

**Fix:** Add `-OverwriteExistingKey -OverwriteExistingDatabase` to clear leftover state:

```powershell
Install-AdcsCertificationAuthority `
    -CAType EnterpriseRootCa -CACommonName 'CORP-LAB-Root-CA' `
    -KeyLength 2048 -HashAlgorithmName SHA256 `
    -ValidityPeriod Years -ValidityPeriodUnits 5 `
    -OverwriteExistingKey -OverwriteExistingDatabase -Force
```

---

## Enabling LDAPS

Once PKI-01 is an Enterprise CA, Domain Controller certificate auto-enrollment happens automatically via Group Policy. Give it a few minutes, then restart NTDS on both DCs to pick up the new cert:

```powershell
Restart-Service NTDS -Force   # run on DC-01 and DC-02
```

Verify from your management host:

```bash
openssl s_client -connect dc-01.corp.lab:636 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer
```

---

## Lessons learned

| Issue | Fix |
|---|---|
| DC-02 clone has same SID as DC-01/domain | Sysprep `/generalize` before domain join |
| Enterprise CA silently installs as Standalone | Always install ADCS as `CORP\Administrator`, not local admin |
| Multiple failed CA installs corrupt registry | Use `-OverwriteExistingKey -OverwriteExistingDatabase` on reinstall |
| DHCP authorization fails on fresh install | Set `ConfigurationState=2` in registry before `Add-DhcpServerInDC` (see `docs/troubleshooting.md`) |
