# Shared helpers. Every script dot-sources this file:  . "$PSScriptRoot/_common.ps1"
#
# Pattern used by every script:
#   1. -Mode Fetch        -> writes reports/<system>-review.csv with an Action column
#   2. A human validates  -> sets Action to Delete / Keep / Review on each row
#   3. -Mode Delete       -> dry run: prints what it WOULD do for rows with Action = Delete
#   4. -Mode Delete -Execute -> actually does it, and logs every step to reports/results.csv

$ReportDir = Join-Path $PSScriptRoot 'reports'
$ResultLog = Join-Path $ReportDir 'results.csv'
New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null

function Get-Manifest {
    param([Parameter(Mandatory)][string]$Path, [string]$Wave)
    $rows = Import-Csv -Path $Path
    if ($Wave) { $rows = $rows | Where-Object Wave -eq $Wave }
    foreach ($r in $rows) {
        # IPs column may hold several addresses separated by ; , or space
        $ips = @($r.IPs -split '[;, ]+' | Where-Object { $_ })
        $r | Add-Member -NotePropertyName IPList -NotePropertyValue $ips -Force
        $r
    }
}

function Export-Review {
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Rows, [Parameter(Mandatory)][string]$Name)
    $path = Join-Path $ReportDir "$Name-review.csv"
    @($Rows) | Export-Csv -Path $path -NoTypeInformation
    Write-Host "Wrote $(@($Rows).Count) rows to $path - validate the Action column before deleting." -ForegroundColor Cyan
}

function Import-Review {
    # Returns only rows a human approved (Action = Delete unless told otherwise).
    param([Parameter(Mandatory)][string]$Name, [string]$Action = 'Delete')
    $path = Join-Path $ReportDir "$Name-review.csv"
    if (-not (Test-Path $path)) { throw "No review file at $path. Run the script with -Mode Fetch first." }
    Import-Csv -Path $path | Where-Object Action -eq $Action
}

function Write-Result {
    param($Hostname, $Step, $Status, $Detail)
    [pscustomobject]@{
        Timestamp = Get-Date -Format s; Hostname = $Hostname; Step = $Step; Status = $Status; Detail = $Detail
    } | Export-Csv -Path $ResultLog -Append -NoTypeInformation
}

function Invoke-Step {
    # Dry run unless the calling script was started with -Execute.
    # Safe to re-run: a "not found" error is logged as AlreadyGone instead of Failed.
    param([string]$Hostname, [string]$Step, [string]$What, [scriptblock]$Action)
    if (-not $Execute) {
        Write-Host "[DRY-RUN] $Hostname :: $What" -ForegroundColor Yellow
        Write-Result $Hostname $Step 'DryRun' $What
        return
    }
    try {
        & $Action | Out-Null
        Write-Host "[DONE] $Hostname :: $What" -ForegroundColor Green
        Write-Result $Hostname $Step 'Done' $What
    } catch {
        $msg = $_.Exception.Message
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        if ($code -eq 404 -or $msg -match 'not found|cannot find|does not exist') {
            Write-Host "[GONE] $Hostname :: $What (already removed)" -ForegroundColor DarkGray
            Write-Result $Hostname $Step 'AlreadyGone' $What
        } else {
            Write-Warning "[FAILED] $Hostname :: $What :: $msg"
            Write-Result $Hostname $Step 'Failed' "$What :: $msg"
        }
    }
}
