<#
.SYNOPSIS  Commvault: disable backups during soft off, then retire the client.
.NOTES     Commvault REST API. CV_URL = https://commserve.corp.example.com/webconsole/api
           (or .../commandcenter/api on newer releases). CHECK THE ENDPOINTS AGAINST YOUR VERSION'S API DOCS.

           RETIRE, don't DELETE: retiring stops backups and keeps existing backup data until its retention
           runs out, then removes the client. Deleting a client can make its backup data unrecoverable.

           Hypervisor-level (VSA) backups: the VM is content of a VM group, not an agent client.
             - Rule-based VM group (tag, folder, datastore...): deleting the VM from vCenter is enough.
             - Static content: remove the VM from the VM group (Command Center > Protect > Virtualization).
           Those rows come out of Fetch as Kind=VM / Action=Review.

  .\08-commvault.ps1 -Mode Fetch -Wave 1
  .\08-commvault.ps1 -Mode DisableBackup -Wave 1 -Execute    # soft off
  .\08-commvault.ps1 -Mode Retire -Wave 1 [-Execute]

  curl equivalents:
    curl -X POST "$CV/Login" -H "Accept: application/json" -H "Content-Type: application/json" \
         -d '{"username":"svc_decom","password":"<base64 password>"}'          # -> token "QSDK ..."
    curl -H "Authtoken: QSDK ..." -H "Accept: application/json" "$CV/Client"
    curl -X POST   -H "Authtoken: QSDK ..." "$CV/Client/<clientId>/Backup/Action/Disable"
    curl -X DELETE -H "Authtoken: QSDK ..." "$CV/Client/<clientId>/Retire"
#>
[CmdletBinding()]
param(
    [string]$CvUrl = $env:CV_URL,
    [pscredential]$Credential,
    [string]$Manifest = "$PSScriptRoot/manifest.csv",
    [string]$Wave,
    [ValidateSet('Fetch', 'DisableBackup', 'Retire')][string]$Mode = 'Fetch',
    [switch]$Execute
)
. "$PSScriptRoot/_common.ps1"
if (-not $Credential) { $Credential = Get-Credential -Message 'Commvault user' }

$pw = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Credential.GetNetworkCredential().Password))
$login = Invoke-RestMethod -Method Post -Uri "$CvUrl/Login" -Headers @{ Accept = 'application/json' } `
            -ContentType 'application/json' -Body (@{ username = $Credential.UserName; password = $pw } | ConvertTo-Json)
$h = @{ Authtoken = $login.token; Accept = 'application/json' }

if ($Mode -eq 'Fetch') {
    $clients = (Invoke-RestMethod -Uri "$CvUrl/Client" -Headers $h).clientProperties
    $cvVms = try { (Invoke-RestMethod -Uri "$CvUrl/V4/VirtualMachines" -Headers $h).virtualMachines } catch { @() }

    $rows = foreach ($vm in Get-Manifest $Manifest $Wave) {
        $names = @($vm.Hostname, $vm.FQDN, $vm.VMName) | Where-Object { $_ }
        foreach ($c in $clients) {
            $e = $c.client.clientEntity
            if ($e.clientName -in $names -or $e.hostName -in $names -or $e.hostName -in $vm.IPList) {
                [pscustomobject]@{ Hostname = $vm.Hostname; Kind = 'Client'; Id = $e.clientId; Name = $e.clientName
                    Detail = "hostName=$($e.hostName)"; Action = 'Delete'; Reason = '' }
            }
        }
        foreach ($v in ($cvVms | Where-Object { $_.name -in $names })) {
            [pscustomobject]@{ Hostname = $vm.Hostname; Kind = 'VM'; Id = $v.UUID; Name = $v.name
                Detail = "VM group / hypervisor: $($v.vmGroup.name) / $($v.hypervisor.name)"
                Action = 'Review'; Reason = 'VSA-protected: check whether the VM group content is rule-based or static' }
        }
    }
    Export-Review $rows 'commvault'
    return
}

foreach ($r in Import-Review 'commvault' | Where-Object Kind -eq 'Client') {
    if ($Mode -eq 'DisableBackup') {
        Invoke-Step $r.Hostname 'Commvault-Disable' "Disable backups for client $($r.Name) ($($r.Id))" {
            Invoke-RestMethod -Method Post -Uri "$CvUrl/Client/$($r.Id)/Backup/Action/Disable" -Headers $h
        }
    } else {
        Invoke-Step $r.Hostname 'Commvault-Retire' "Retire client $($r.Name) ($($r.Id))" {
            Invoke-RestMethod -Method Delete -Uri "$CvUrl/Client/$($r.Id)/Retire" -Headers $h
        }
    }
}
