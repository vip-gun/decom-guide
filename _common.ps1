# Shared helpers. Every script dot-sources this file:  . "$PSScriptRoot/_common.ps1"
#
# Pattern used by every script:
#   1. -Mode Fetch        -> writes reports/<system>-review.csv with an Action column
#   2. A human validates  -> sets Action to Delete / Keep / Review on each row
#   3. -Mode Delete       -> dry run: prints what it WOULD do for rows with Action = Delete
#   4. -Mode Delete -Execute -> actually does it, and logs every step to reports/results.csv

# Works on Windows PowerShell 5.1 and PowerShell 7.
# Windows PowerShell 5.1 offers only TLS 1.0/1.1 by default, which nearly every API server now refuses.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 }
catch { Write-Verbose "Could not enable TLS 1.2: $($_.Exception.Message)" }

$ReportDir = Join-Path $PSScriptRoot 'reports'
$ResultLog = Join-Path $ReportDir 'results.csv'
New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null

function Get-Manifest {
    param([Parameter(Mandatory)][string]$Path, [string]$Wave)
    $rows = Import-Csv -Path $Path -Encoding UTF8
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
    @($Rows) | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
    Write-Host "Wrote $(@($Rows).Count) rows to $path - validate the Action column before deleting." -ForegroundColor Cyan
}

function Import-Review {
    # Returns only rows a human approved (Action = Delete unless told otherwise).
    param([Parameter(Mandatory)][string]$Name, [string]$Action = 'Delete')
    $path = Join-Path $ReportDir "$Name-review.csv"
    if (-not (Test-Path $path)) { throw "No review file at $path. Run the script with -Mode Fetch first." }
    Import-Csv -Path $path -Encoding UTF8 | Where-Object Action -eq $Action
}

function Write-Result {
    param($Hostname, $Step, $Status, $Detail)
    [pscustomobject]@{
        Timestamp = Get-Date -Format s; Hostname = $Hostname; Step = $Step; Status = $Status; Detail = $Detail
    } | Export-Csv -Path $ResultLog -Append -NoTypeInformation -Encoding UTF8
}

function Invoke-Step {
    # Dry run unless -Execute is passed (every script forwards its own -Execute switch).
    # Safe to re-run: a "not found" error is logged as AlreadyGone instead of Failed.
    param([string]$Hostname, [string]$Step, [string]$What, [scriptblock]$Action, [switch]$Execute)
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

function ConvertTo-PSObjectTree {
    # Turns the dictionaries and lists returned by JavaScriptSerializer into PSCustomObjects and arrays,
    # i.e. the same shape ConvertFrom-Json produces.
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $h[[string]$k] = ConvertTo-PSObjectTree $InputObject[$k] }
        return [pscustomobject]$h
    }
    if ($InputObject -is [System.Collections.IList]) {
        $items = @(foreach ($i in $InputObject) { ConvertTo-PSObjectTree $i })
        return , $items
    }
    $InputObject
}

function ConvertFrom-JsonLarge {
    # Windows PowerShell 5.1: ConvertFrom-Json and Invoke-RestMethod fail on JSON over 2 MB
    # ("maxJsonLength"). Large inventories (all Checkmk hosts, all OpCon jobs) can exceed that.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return }
    if ($PSVersionTable.PSVersion.Major -ge 6) { return ($Json | ConvertFrom-Json) }
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $ser.RecursionLimit = 200
    $tree = ConvertTo-PSObjectTree ($ser.DeserializeObject($Json))
    $tree      # written out as a variable, so a top-level array is enumerated into items, as ConvertFrom-Json does on PowerShell 7
}

function Invoke-Api {
    # Replacement for Invoke-RestMethod with the same parameter names, that also works on Windows PowerShell 5.1:
    #  - -Credential sends HTTP Basic auth (Invoke-RestMethod's own -Authentication Basic is PowerShell 6+ only)
    #  - JSON is parsed without the 2 MB limit (see ConvertFrom-JsonLarge)
    #  - HTTP errors throw, exactly as with Invoke-RestMethod, so Invoke-Step can recognise a 404
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'Get',
        [hashtable]$Headers,
        [string]$ContentType,
        $Body,
        [pscredential]$Credential
    )
    $hdr = @{ Accept = 'application/json' }
    if ($Headers) { foreach ($k in $Headers.Keys) { $hdr[$k] = $Headers[$k] } }
    if ($Credential -and $Credential.UserName) {
        $pair = '{0}:{1}' -f $Credential.UserName, $Credential.GetNetworkCredential().Password
        $hdr['Authorization'] = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    }
    $req = @{ Uri = $Uri; Method = $Method; Headers = $hdr; UseBasicParsing = $true }
    if ($ContentType) { $req.ContentType = $ContentType }
    if ($PSBoundParameters.ContainsKey('Body')) { $req.Body = $Body }
    $resp = Invoke-WebRequest @req
    $text = $resp.Content
    if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
    $text = [string]$text
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    if ($text.TrimStart() -notmatch '^[\[{]') { return $text }     # not JSON: hand back the raw text
    ConvertFrom-JsonLarge $text
}
