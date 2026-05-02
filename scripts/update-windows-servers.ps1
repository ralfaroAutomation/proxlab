#Requires -RunAsAdministrator
<#
  Run from DC-01 or any domain-joined admin workstation.
  Requires PSWindowsUpdate module (auto-installed if missing).
  Usage:
    .\update-windows-servers.ps1              # check + install, no auto-reboot
    .\update-windows-servers.ps1 -Reboot      # auto-reboot each server if needed
#>

param(
    [switch]$Reboot
)

$Servers = @(
    'DC-01',    # 10.10.1.10
    'DC-02',    # 10.10.1.11
    'PKI-01',   # 10.10.1.12
    'FS-01',    # 10.10.2.10
    'APP-01',   # 10.10.2.11
    'SQL-01',   # 10.10.2.12
    'WSUS-01'   # 10.10.2.13
)

$Cred = Get-Credential -Message "Domain admin credentials (CORP\Administrator)"

foreach ($Server in $Servers) {
    Write-Host "`n=== $Server ===" -ForegroundColor Cyan

    try {
        Invoke-Command -ComputerName $Server -Credential $Cred -ScriptBlock {
            param($AutoReboot)

            # Install PSWindowsUpdate if not present
            if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
                Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
                Install-Module PSWindowsUpdate -Force -Scope AllUsers -Confirm:$false | Out-Null
            }
            Import-Module PSWindowsUpdate

            $Updates = Get-WindowsUpdate -AcceptAll -IgnoreReboot
            if (-not $Updates) {
                Write-Output "  Up to date."
                return
            }

            Write-Output "  Installing $($Updates.Count) update(s):"
            $Updates | ForEach-Object { Write-Output "    - $($_.Title)" }

            Install-WindowsUpdate -AcceptAll -IgnoreReboot -AutoReboot:$false | Out-Null

            $NeedsReboot = (Get-WURebootStatus -Silent)
            if ($NeedsReboot) {
                if ($AutoReboot) {
                    Write-Output "  Reboot required — rebooting now."
                    Restart-Computer -Force
                } else {
                    Write-Output "  Reboot required — skipped (run with -Reboot to auto-reboot)."
                }
            } else {
                Write-Output "  Done, no reboot needed."
            }

        } -ArgumentList $Reboot.IsPresent

    } catch {
        Write-Warning "  FAILED: $_"
    }
}

Write-Host "`nAll servers processed." -ForegroundColor Green
