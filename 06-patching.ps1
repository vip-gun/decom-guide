<#
.SYNOPSIS  Patching platforms: SCCM (Windows rows) and Red Hat Satellite (Linux rows).
.NOTES     SCCM: run on a machine with the ConfigurationManager console installed.
           SCCM: if AD System Discovery runs while the AD computer object still exists, the device comes back.
                 Remove the AD object first (01-ad.ps1), or run both on the same day.
           Satellite: REST API v2 over HTTPS with basic auth.

  .\06-patching.ps1 -Mode Fetch -Wave 1 -SiteCode P01 -SiteServer sccm01 -SatelliteUrl https://satellite.corp.example.com
  .\06-patching.ps1 -Mode Delete -Wave 1 -SiteCode P01 -SiteServer sccm01 -SatelliteUrl https://... [-Execute]

  Single-host equivalents:
    SCCM      Get-CMDevice -Name APPSRV01 -Fast | Select Name,ResourceID,IsClient,LastActiveTime
              Remove-CMDevice -ResourceId 16777220 -Force
    Satellite hammer host list --search "name ~ rhel-web-07"
              hammer host info --name rhel-web-07.corp.example.com
              hammer host delete --name rhel-web-07.corp.example.com
#>
[CmdletBinding()]
param(
    [string]$SiteCode,
    [string]$SiteServer,
    [string]$SatelliteUrl = $env:SATELLITE_URL,
    [pscredential]$SatCredential,
    [string]$Manifest = "$PSScriptRoot/manifest.csv",
    [string]$Wave,
    [ValidateSet('Fetch', 'Delete')][string]$Mode = 'Fetch',
    [switch]$Execute
)
. "$PSScriptRoot/_common.ps1"

function Connect-CM {
    Import-Module (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1') -ErrorAction Stop
    if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null
    }
    Push-Location "$($SiteCode):"
}
$vms = @(Get-Manifest $Manifest $Wave)
$win = @($vms | Where-Object OS -eq 'Windows')
$lin = @($vms | Where-Object OS -eq 'Linux')
if ($lin -and -not $SatCredential) { $SatCredential = Get-Credential -Message 'Satellite API user' }
$sat = @{ Credential = $SatCredential; Authentication = 'Basic' }

if ($Mode -eq 'Fetch') {
    $rows = [System.Collections.Generic.List[object]]::new()

    if ($win) {
        Connect-CM
        foreach ($vm in $win) {
            $devs = @(Get-CMDevice -Name $vm.Hostname -Fast)
            foreach ($d in $devs) {
                $rows.Add([pscustomobject]@{ Hostname = $vm.Hostname; Platform = 'SCCM'; Id = $d.ResourceID; Name = $d.Name
                    Detail = "IsClient=$($d.IsClient) LastActive=$($d.LastActiveTime)"
                    Action = 'Delete'; Reason = if ($devs.Count -gt 1) { 'Duplicate records - delete all' } else { '' } })
            }
            if (-not $devs) { $rows.Add([pscustomobject]@{ Hostname = $vm.Hostname; Platform = 'SCCM'; Id = ''; Name = ''
                Detail = ''; Action = 'None'; Reason = 'Not in SCCM' }) }
        }
        Pop-Location
    }

    foreach ($vm in $lin) {
        $q = [uri]::EscapeDataString("name ~ $($vm.Hostname)")
        $hosts = @((Invoke-RestMethod -Uri "$SatelliteUrl/api/v2/hosts?search=$q&per_page=100" @sat).results)
        foreach ($s in $hosts) {
            $exact = $s.name -in @($vm.FQDN, $vm.Hostname)
            $rows.Add([pscustomobject]@{ Hostname = $vm.Hostname; Platform = 'Satellite'; Id = $s.id; Name = $s.name
                Detail = "org=$($s.organization_name) ip=$($s.ip) lastCheckin=$($s.subscription_facet_attributes.last_checkin)"
                Action = if ($exact) { 'Delete' } else { 'Review' }
                Reason = if ($exact) { '' } else { 'Partial name match' } })
        }
        if (-not $hosts) { $rows.Add([pscustomobject]@{ Hostname = $vm.Hostname; Platform = 'Satellite'; Id = ''; Name = ''
            Detail = ''; Action = 'None'; Reason = 'Not in Satellite' }) }
    }
    Export-Review $rows 'patching'
    return
}

$approved = @(Import-Review 'patching')
$cmRows = @($approved | Where-Object Platform -eq 'SCCM')
if ($cmRows) {
    Connect-CM
    foreach ($r in $cmRows) {
        Invoke-Step -Execute:$Execute $r.Hostname 'SCCM' "Remove-CMDevice $($r.Name) ResourceId=$($r.Id)" {
            Remove-CMDevice -ResourceId $r.Id -Force -Confirm:$false
        }
    }
    Pop-Location
}
foreach ($r in $approved | Where-Object Platform -eq 'Satellite') {
    # Deleting the host also removes its content host / subscription registration
    Invoke-Step -Execute:$Execute $r.Hostname 'Satellite' "Delete host $($r.Name) id=$($r.Id)" {
        Invoke-RestMethod -Method Delete -Uri "$SatelliteUrl/api/v2/hosts/$($r.Id)" @sat
    }
}
