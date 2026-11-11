<#
.SYNOPSIS  Build the list for the firewall / proxy / QRadar team: one row per IP, with every DNS name.
.NOTES     Run after 02-dns.ps1 -Mode Fetch, so CNAMEs and other names on the IPs are included.

  .\10-handoff.ps1 -Wave 1      # -> reports/handoff-wave-1.csv, attach to one ticket per wave
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Wave,
    [string]$Manifest = "$PSScriptRoot/manifest.csv"
)
. "$PSScriptRoot/_common.ps1"
$dnsFile = Join-Path $ReportDir 'dns-review.csv'
$dns = if (Test-Path $dnsFile) { Import-Csv $dnsFile } else { Write-Warning 'No dns-review.csv - DNS names will be missing'; @() }

$rows = foreach ($vm in Get-Manifest $Manifest $Wave) {
    $names = @($dns | Where-Object { $_.Hostname -eq $vm.Hostname -and $_.RecordType -in 'A', 'CNAME' } | ForEach-Object Fqdn) +
             @($vm.FQDN) | Where-Object { $_ } | Sort-Object -Unique
    foreach ($ip in $vm.IPList) {
        [pscustomobject]@{ Wave = $Wave; Hostname = $vm.Hostname; IP = $ip; DnsNames = $names -join '; '
            OS = $vm.OS; Owner = $vm.Owner; Request = 'Remove firewall rules, proxy rules and QRadar log source' }
    }
}
$out = Join-Path $ReportDir "handoff-wave-$Wave.csv"
$rows | Export-Csv $out -NoTypeInformation
Write-Host "Handoff list: $out ($(@($rows).Count) IPs)" -ForegroundColor Cyan
