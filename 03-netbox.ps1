<#
.SYNOPSIS  NetBox: the VM object and its IP addresses.
.NOTES     REST API. Set NETBOX_URL (https://netbox.corp.example.com) and NETBOX_TOKEN.
           Run Delete only AFTER the firewall/proxy team confirms their rules are gone,
           so a freed IP cannot be handed to a new server that would inherit the old rules.

  .\03-netbox.ps1 -Mode Fetch     -Wave 1
  .\03-netbox.ps1 -Mode Deprecate -Wave 1 -Execute   # soft off: IP -> deprecated, VM -> decommissioning
  .\03-netbox.ps1 -Mode Delete    -Wave 1 -Execute   # deletes IPs (frees them), then the VM

  curl equivalents:
    curl -H "Authorization: Token $T" "$NB/api/virtualization/virtual-machines/?name__ie=appsrv01"
    curl -H "Authorization: Token $T" "$NB/api/ipam/ip-addresses/?address=10.10.20.15"
    curl -H "Authorization: Token $T" "$NB/api/ipam/ip-addresses/?virtual_machine_id=123"
    curl -X PATCH  -H "Authorization: Token $T" -H "Content-Type: application/json" \
         -d '{"status":"deprecated"}' "$NB/api/ipam/ip-addresses/456/"
    curl -X DELETE -H "Authorization: Token $T" "$NB/api/ipam/ip-addresses/456/"
#>
[CmdletBinding()]
param(
    [string]$NetboxUrl = $env:NETBOX_URL,
    [string]$NetboxToken = $env:NETBOX_TOKEN,
    [string]$Manifest = "$PSScriptRoot/manifest.csv",
    [string]$Wave,
    [ValidateSet('Fetch', 'Deprecate', 'Delete')][string]$Mode = 'Fetch',
    [switch]$Execute
)
. "$PSScriptRoot/_common.ps1"

# NetBox 4.5+ "v2" tokens use:  Authorization = "Bearer nbt_<key>.<token>"
$h = @{ Authorization = "Token $NetboxToken"; Accept = 'application/json' }
$endpoint = @{ 'ip-address' = '/api/ipam/ip-addresses'; 'virtual-machine' = '/api/virtualization/virtual-machines' }
function Get-Nb([string]$Path) { (Invoke-RestMethod -Uri "$NetboxUrl$Path" -Headers $h).results }

if ($Mode -eq 'Fetch') {
    $rows = foreach ($vm in Get-Manifest $Manifest $Wave) {
        $nbVms = @(Get-Nb "/api/virtualization/virtual-machines/?name__ie=$([uri]::EscapeDataString($vm.Hostname))")
        $ips = @()
        foreach ($v in $nbVms) {
            [pscustomobject]@{ Hostname = $vm.Hostname; ObjectType = 'virtual-machine'; Id = $v.id; Name = $v.name
                Address = ''; DnsName = ''; Status = $v.status.value; AssignedTo = $v.cluster.name
                Action = if ($nbVms.Count -gt 1) { 'Review' } else { 'Delete' }
                Reason = if ($nbVms.Count -gt 1) { 'Several NetBox VMs share this name' } else { '' } }
            $ips += Get-Nb "/api/ipam/ip-addresses/?virtual_machine_id=$($v.id)"
        }
        foreach ($ip in $vm.IPList) { $ips += Get-Nb "/api/ipam/ip-addresses/?address=$ip" }

        foreach ($ip in ($ips | Sort-Object id -Unique)) {
            $owner = if ($ip.assigned_object.virtual_machine) { $ip.assigned_object.virtual_machine.name }
                     elseif ($ip.assigned_object.device)       { $ip.assigned_object.device.name } else { '' }
            $ours = (-not $owner) -or ($owner -eq $vm.Hostname) -or ($owner -in $nbVms.name)
            [pscustomobject]@{ Hostname = $vm.Hostname; ObjectType = 'ip-address'; Id = $ip.id; Name = ''
                Address = $ip.address; DnsName = $ip.dns_name; Status = $ip.status.value; AssignedTo = $owner
                Action = if ($ours) { 'Delete' } else { 'Review' }
                Reason = if ($ours) { '' } else { "Assigned to $owner, not to this VM" } }
        }
        if (-not $nbVms -and -not $ips) {
            [pscustomobject]@{ Hostname = $vm.Hostname; ObjectType = ''; Id = ''; Name = ''; Address = ''; DnsName = ''
                Status = ''; AssignedTo = ''; Action = 'None'; Reason = 'Nothing in NetBox' }
        }
    }
    Export-Review $rows 'netbox'
    return
}

# IPs before VMs: deleting a VM does not delete its IPs, it just leaves them unassigned.
$approved = Import-Review 'netbox' | Sort-Object { if ($_.ObjectType -eq 'ip-address') { 0 } else { 1 } }
foreach ($r in $approved) {
    $uri = "$NetboxUrl$($endpoint[$r.ObjectType])/$($r.Id)/"
    $label = "$($r.ObjectType) $($r.Id) $($r.Address)$($r.Name)"
    if ($Mode -eq 'Deprecate') {
        $status = if ($r.ObjectType -eq 'ip-address') { 'deprecated' } else { 'decommissioning' }
        Invoke-Step -Execute:$Execute $r.Hostname 'NetBox-Deprecate' "Set $label status=$status" {
            Invoke-RestMethod -Method Patch -Uri $uri -Headers $h -ContentType 'application/json' -Body (@{ status = $status } | ConvertTo-Json)
        }
    } else {
        Invoke-Step -Execute:$Execute $r.Hostname 'NetBox-Delete' "Delete $label" {
            Invoke-RestMethod -Method Delete -Uri $uri -Headers $h
        }
    }
}
