<#
.SYNOPSIS  Checkmk: schedule downtime during the soft-off period, then delete hosts and activate changes.
.NOTES     REST API (Checkmk 2.x). Use an automation user.
           CMK_URL = https://monitor.corp.example.com/<site>

  .\07-checkmk.ps1 -Mode Fetch    -Wave 1
  .\07-checkmk.ps1 -Mode Downtime -Wave 1 -DowntimeDays 30 -Execute
  .\07-checkmk.ps1 -Mode Delete   -Wave 1 [-Execute]          # deletes, then one activate-changes

  curl equivalents (API=$CMK_URL/check_mk/api/1.0, AUTH="Authorization: Bearer automation <secret>"):
    curl -H "$AUTH" "$API/objects/host_config/appsrv01"
    curl -X POST -H "$AUTH" -H "Content-Type: application/json" "$API/domain-types/downtime/collections/host" \
         -d '{"downtime_type":"host","host_name":"appsrv01","start_time":"2026-11-11T09:00:00Z","end_time":"2026-12-11T09:00:00Z","comment":"Decom"}'
    curl -X DELETE -H "$AUTH" "$API/objects/host_config/appsrv01"
    curl -X POST -H "$AUTH" -H "If-Match: *" -H "Content-Type: application/json" \
         "$API/domain-types/activation_run/actions/activate-changes/invoke" -d '{"redirect":false,"sites":[],"force_foreign_changes":false}'
#>
[CmdletBinding()]
param(
    [string]$CmkUrl = $env:CMK_URL,
    [string]$CmkUser = $env:CMK_USER,
    [string]$CmkSecret = $env:CMK_SECRET,
    [int]$DowntimeDays = 30,
    [string]$Manifest = "$PSScriptRoot/manifest.csv",
    [string]$Wave,
    [ValidateSet('Fetch', 'Downtime', 'Delete')][string]$Mode = 'Fetch',
    [switch]$Execute
)
. "$PSScriptRoot/_common.ps1"
$api = "$CmkUrl/check_mk/api/1.0"
$h = @{ Authorization = "Bearer $CmkUser $CmkSecret"; Accept = 'application/json' }

if ($Mode -eq 'Fetch') {
    # One call for all hosts, then match on name or IP
    $all = (Invoke-RestMethod -Uri "$api/domain-types/host_config/collections/all" -Headers $h).value
    $rows = foreach ($vm in Get-Manifest $Manifest $Wave) {
        $names = @($vm.Hostname, $vm.FQDN) | Where-Object { $_ }
        $hits = @($all | Where-Object { $_.id -in $names -or $_.extensions.attributes.ipaddress -in $vm.IPList })
        foreach ($c in $hits) {
            $exact = $c.id -in $names
            [pscustomobject]@{ Hostname = $vm.Hostname; CmkHost = $c.id; Folder = $c.extensions.folder
                IP = $c.extensions.attributes.ipaddress
                Action = if ($exact) { 'Delete' } else { 'Review' }
                Reason = if ($exact) { '' } else { 'Matched on IP only - different host name' } }
        }
        if (-not $hits) { [pscustomobject]@{ Hostname = $vm.Hostname; CmkHost = ''; Folder = ''; IP = ''; Action = 'None'; Reason = 'Not monitored' } }
    }
    Export-Review $rows 'checkmk'
    return
}

$approved = @(Import-Review 'checkmk')
if ($Mode -eq 'Downtime') {
    $start = (Get-Date).ToUniversalTime()
    foreach ($r in $approved) {
        Invoke-Step $r.Hostname 'Checkmk-Downtime' "Downtime $($r.CmkHost) for $DowntimeDays days" {
            $body = @{ downtime_type = 'host'; host_name = $r.CmkHost
                start_time = $start.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                end_time   = $start.AddDays($DowntimeDays).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                comment    = "Decommission wave $Wave - powered off pending deletion" } | ConvertTo-Json
            Invoke-RestMethod -Method Post -Uri "$api/domain-types/downtime/collections/host" -Headers $h -ContentType 'application/json' -Body $body
        }
    }
    return
}

foreach ($r in $approved) {
    Invoke-Step $r.Hostname 'Checkmk-Delete' "Delete host $($r.CmkHost)" {
        Invoke-RestMethod -Method Delete -Uri "$api/objects/host_config/$([uri]::EscapeDataString($r.CmkHost))" -Headers $h
    }
}
if ($approved) {
    Invoke-Step '*' 'Checkmk-Activate' 'Activate pending changes' {
        $body = @{ redirect = $false; sites = @(); force_foreign_changes = $false } | ConvertTo-Json
        Invoke-RestMethod -Method Post -Uri "$api/domain-types/activation_run/actions/activate-changes/invoke" `
            -Headers ($h + @{ 'If-Match' = '*' }) -ContentType 'application/json' -Body $body
    }
}
