#Requires -Version 5.1
<#
.SYNOPSIS  OpCon: agent machine definitions and master jobs that run on the VMs.
.NOTES     OpCon REST API. Endpoint names and payloads change between OpCon releases:
           CHECK EVERY CALL AGAINST YOUR SERVER'S API (Swagger) DOCS BEFORE RUNNING WITH -Execute.
           Jobs that run through a MACHINE GROUP don't name the machine directly. Also remove the
           machine from its groups (GET /api/machineGroups), or the job just runs on another member.

  .\05-opcon.ps1 -Mode Fetch -Wave 1
  .\05-opcon.ps1 -Mode MachineDown -Wave 1 -Execute   # soft off: stop OpCon sending work to the agent
  .\05-opcon.ps1 -Mode Delete -Wave 1 [-Execute]      # deletes approved master jobs, then machines

  curl equivalents:
    curl -X POST "$OPCON/api/tokens" -H "Content-Type: application/json" \
         -d '{"user":{"loginName":"svc_decom","password":"..."},"tokenType":{"type":"User"}}'
    curl -H "Authorization: Token <id>" "$OPCON/api/machines?name=APPSRV01"
    curl -H "Authorization: Token <id>" "$OPCON/api/masterJobs/<jobId>"
    curl -X DELETE -H "Authorization: Token <id>" "$OPCON/api/masterJobs/<jobId>"
#>
[CmdletBinding()]
param(
    [string]$OpConUrl = $env:OPCON_URL,     # e.g. https://opcon.corp.example.com:9010
    [pscredential]$Credential,
    [string]$Manifest = "$PSScriptRoot/manifest.csv",
    [string]$Wave,
    [switch]$RefreshJobCache,               # re-download master job definitions
    [ValidateSet('Fetch', 'MachineDown', 'Delete')][string]$Mode = 'Fetch',
    [switch]$Execute
)
. "$PSScriptRoot/_common.ps1"
if (-not $Credential) { $Credential = Get-Credential -Message 'OpCon API user' }

$tokenBody = @{ user = @{ loginName = $Credential.UserName; password = $Credential.GetNetworkCredential().Password }
                tokenType = @{ type = 'User' } } | ConvertTo-Json
$token = Invoke-Api -Method Post -Uri "$OpConUrl/api/tokens" -ContentType 'application/json' -Body $tokenBody
$h = @{ Authorization = "Token $($token.id)"; Accept = 'application/json' }

if ($Mode -eq 'Fetch') {
    $vms = @(Get-Manifest $Manifest $Wave)
    $machines = Invoke-Api -Uri "$OpConUrl/api/machines" -Headers $h

    # The master job list doesn't always include the machine, so pull each job's full definition once and cache it.
    $cache = Join-Path $ReportDir 'opcon-masterjobs.json'
    if ($RefreshJobCache -or -not (Test-Path $cache)) {
        $list = Invoke-Api -Uri "$OpConUrl/api/masterJobs" -Headers $h
        $full = foreach ($j in $list) { Invoke-Api -Uri "$OpConUrl/api/masterJobs/$($j.id)" -Headers $h }
        $full | ConvertTo-Json -Depth 20 | Set-Content $cache -Encoding UTF8
    }
    $jobs = ConvertFrom-JsonLarge (Get-Content $cache -Raw -Encoding UTF8)

    $rows = foreach ($vm in $vms) {
        $names = @($vm.Hostname, $vm.FQDN) | Where-Object { $_ }
        foreach ($m in ($machines | Where-Object { $_.name -in $names })) {
            [pscustomobject]@{ Hostname = $vm.Hostname; Kind = 'Machine'; Id = $m.id; Name = $m.name; Schedule = ''
                Detail = "type=$($m.machineType.description) status=$($m.status.state)"; Action = 'Delete' }
        }
        # Match the hostname anywhere in the job definition (machine, command line, file paths...)
        $pattern = ($names | ForEach-Object { '\b' + [regex]::Escape($_) + '\b' }) -join '|'
        foreach ($j in $jobs) {
            if (($j | ConvertTo-Json -Depth 20 -Compress) -match $pattern) {
                [pscustomobject]@{ Hostname = $vm.Hostname; Kind = 'MasterJob'; Id = $j.id; Name = $j.name
                    Schedule = $j.schedule.name; Detail = 'Hostname found in job definition - check dependencies'; Action = 'Review' }
            }
        }
    }
    Export-Review $rows 'opcon'
    return
}

$approved = Import-Review 'opcon'
if ($Mode -eq 'MachineDown') {
    foreach ($r in $approved | Where-Object Kind -eq 'Machine') {
        Invoke-Step -Execute:$Execute $r.Hostname 'OpCon-Down' "Machine $($r.Name) -> down" {
            $body = @{ action = 'down'; machines = @(@{ id = [int]$r.Id }) } | ConvertTo-Json -Depth 5
            Invoke-Api -Method Post -Uri "$OpConUrl/api/machineActions" -Headers $h -ContentType 'application/json' -Body $body
        }
    }
    return
}

# Jobs first, then the machine definitions they reference
foreach ($r in $approved | Sort-Object { if ($_.Kind -eq 'MasterJob') { 0 } else { 1 } }) {
    $path = if ($r.Kind -eq 'MasterJob') { 'masterJobs' } else { 'machines' }
    Invoke-Step -Execute:$Execute $r.Hostname "OpCon-Delete$($r.Kind)" "Delete $($r.Kind) $($r.Name) ($($r.Schedule)) id=$($r.Id)" {
        Invoke-Api -Method Delete -Uri "$OpConUrl/api/$path/$($r.Id)" -Headers $h
    }
}
