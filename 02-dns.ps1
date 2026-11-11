<#
.SYNOPSIS  Find every A / PTR / CNAME record tied to the VMs' IPs and names, then remove the approved ones.
.NOTES     Requires the DnsServer module (RSAT). Microsoft DNS only.

  .\02-dns.ps1 -DnsServer dc01 -Mode Fetch -Wave 1
  .\02-dns.ps1 -DnsServer dc01 -Mode Delete -Wave 1 [-Execute]

  How the Action column is pre-filled:
    A  record for the VM's own name           -> Delete
    PTR record for the VM's IP or name        -> Delete
    A  record with ANOTHER name on the VM's IP -> Review  (service alias? VIP? IP already reused?)
    VM's name pointing at an IP not in manifest -> Review (stale record, or the manifest is missing an IP)
    CNAME pointing at the VM                  -> Review  (something may still use the alias)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DnsServer,
    [string]$Manifest = "$PSScriptRoot/manifest.csv",
    [string]$Wave,
    [ValidateSet('Fetch', 'Delete')][string]$Mode = 'Fetch',
    [switch]$Execute
)
. "$PSScriptRoot/_common.ps1"
Import-Module DnsServer

if ($Mode -eq 'Fetch') {
    $vms = @(Get-Manifest $Manifest $Wave)

    # FETCH (single-record equivalents):
    #   Get-DnsServerResourceRecord -ComputerName dc01 -ZoneName corp.example.com -RRType A |
    #       Where-Object { $_.RecordData.IPv4Address -eq '10.10.20.15' }
    #   Get-DnsServerResourceRecord -ComputerName dc01 -ZoneName 20.10.10.in-addr.arpa -Name 15 -RRType Ptr
    #   Get-DnsServerResourceRecord -ComputerName dc01 -ZoneName corp.example.com -RRType CName |
    #       Where-Object { $_.RecordData.HostNameAlias -eq 'appsrv01.corp.example.com.' }
    #
    # Read every primary zone once, instead of querying once per VM.
    $zones = Get-DnsServerZone -ComputerName $DnsServer |
             Where-Object { -not $_.IsAutoCreated -and $_.ZoneType -eq 'Primary' -and $_.ZoneName -ne 'TrustAnchors' }
    $all = foreach ($z in $zones) {
        Get-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $z.ZoneName |
        Where-Object { $_.RecordType -in 'A', 'PTR', 'CNAME' } |
        ForEach-Object {
            $data = switch ($_.RecordType) {
                'A'     { $_.RecordData.IPv4Address.IPAddressToString }
                'PTR'   { $_.RecordData.PtrDomainName }
                'CNAME' { $_.RecordData.HostNameAlias }
            }
            [pscustomobject]@{
                Zone       = $z.ZoneName
                RecordName = $_.HostName
                Fqdn       = $(if ($_.HostName -eq '@') { $z.ZoneName } else { "$($_.HostName).$($z.ZoneName)" }).ToLower()
                RecordType = $_.RecordType
                Data       = $data
                Target     = "$data".TrimEnd('.').ToLower()
                Dynamic    = [bool]$_.Timestamp
            }
        }
    }

    $rows = foreach ($vm in $vms) {
        $fqdn = "$($vm.FQDN)".ToLower()
        $revNames = foreach ($ip in $vm.IPList) { $o = $ip.Split('.'); "$($o[3]).$($o[2]).$($o[1]).$($o[0]).in-addr.arpa" }

        $aRecs = $all | Where-Object { $_.RecordType -eq 'A' -and ($_.Data -in $vm.IPList -or ($fqdn -and $_.Fqdn -eq $fqdn)) }
        $names = @(@($fqdn) + @($aRecs.Fqdn) | Where-Object { $_ } | Sort-Object -Unique)
        $ptrs  = $all | Where-Object { $_.RecordType -eq 'PTR' -and ($_.Fqdn -in $revNames -or $_.Target -in $names) }
        $cname = $all | Where-Object { $_.RecordType -eq 'CNAME' -and $_.Target -in $names }

        foreach ($rec in @($aRecs) + @($ptrs) + @($cname)) {
            $action, $reason = switch ($rec.RecordType) {
                'A' {
                    if ($rec.Fqdn -eq $fqdn -and $rec.Data -in $vm.IPList) { 'Delete', 'Host record' }
                    elseif ($rec.Fqdn -eq $fqdn)                         { 'Review', 'VM name points at an IP not in the manifest' }
                    else                                                 { 'Review', 'Other name on the VM IP - alias, VIP or reused IP?' }
                }
                'PTR' {
                    if ($rec.Target -in $names) { 'Delete', 'Reverse record' }
                    else                        { 'Review', "PTR for the VM IP points to $($rec.Target)" }
                }
                'CNAME' { 'Review', 'Alias pointing at the VM - check nothing still uses it' }
            }
            $rec | Select-Object @{ n = 'Hostname'; e = { $vm.Hostname } }, Zone, RecordName, Fqdn, RecordType, Data, Dynamic,
                                 @{ n = 'Action'; e = { $action } }, @{ n = 'Reason'; e = { $reason } }
        }
    }
    Export-Review ($rows | Sort-Object Hostname, Zone, RecordName, RecordType, Data -Unique) 'dns'
    return
}

foreach ($r in Import-Review 'dns') {
    # DELETE: Remove-DnsServerResourceRecord -ComputerName dc01 -ZoneName corp.example.com -Name appsrv01 `
    #             -RRType A -RecordData 10.10.20.15 -Force
    Invoke-Step -Execute:$Execute $r.Hostname 'DNS' "Remove $($r.RecordType) $($r.Fqdn) -> $($r.Data)" {
        Remove-DnsServerResourceRecord -ComputerName $DnsServer -ZoneName $r.Zone -Name $r.RecordName `
            -RRType $r.RecordType -RecordData $r.Data -Force
    }
}
