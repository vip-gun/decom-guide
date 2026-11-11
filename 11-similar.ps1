<#
.SYNOPSIS  For each VM to decommission, find similarly named VMs in vCenter and report whether they are powered on.
.NOTES     Read-only: nothing is changed. Requires VMware PowerCLI.
           Run it BEFORE powering anything off (Phase 1), after the manifest exists.

  .\11-similar.ps1 -VCenter vc01                         # every VM in manifest.csv
  .\11-similar.ps1 -VCenter vc01 -Wave 1                 # one wave
  .\11-similar.ps1 -VCenter vc01 -VMName VMTEST010-OFF   # ad-hoc, no manifest needed
  .\11-similar.ps1 -VCenter vc01 -MaxDistance 1          # also catch typos (VMTEST01O)

  How names are compared:
    1. Noise tokens at the start or end are dropped (-off, -old, -decom ...), then - _ and spaces are removed.
         VMTEST010-OFF  ->  vmtest010
    2. A VM is "similar" when its reduced name
         SameCore  equals the target's        VMTEST010  vs VMTEST010-OFF
         Contains  holds the target's or is held by it   VMTEST010DR, XVMTEST010
         Typo      is within -MaxDistance edits (off by default)
       Names that differ only by trailing digits (VMTEST010 vs VMTEST0101, web01 vs web02) are NOT
       reported: those are normally different servers, and listing them would bury the real findings.

  Flag column:
    WARNING  similar VM is powered ON and is not on the decommission list: make sure it is not the live server
    CHECK    similar VM is powered off and not on the list: leftover, or the real server that is switched off
    INFO     similar VM is also on the decommission list
    NONE     nothing similar found
#>
[CmdletBinding()]
# The three tuning parameters are read inside the helper functions, which the analyzer cannot see.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
param(
    [Parameter(Mandatory)][string]$VCenter,
    [string[]]$VMName,                                    # skip the manifest and check these names
    [string]$Manifest = "$PSScriptRoot/manifest.csv",
    [string]$Wave,
    [string[]]$NoiseTokens = @('off', 'old', 'decom', 'decomm', 'decommissioned', 'retired', 'archive', 'archived', 'bak', 'copy', 'clone', 'new', 'temp'),
    [int]$MinCoreLength = 5,                              # reduced names shorter than this are only matched when equal
    [int]$MaxDistance = 0                                 # 0 = off; 1 or 2 also reports near-typos
)
. "$PSScriptRoot/_common.ps1"

function Get-Core([string]$Name) {
    $n = $Name.Split('.')[0].ToLower()                    # drop the domain of an FQDN
    $tokens = ($NoiseTokens | ForEach-Object { [regex]::Escape($_.ToLower()) }) -join '|'
    do {                                                  # repeat for stacked tokens, e.g. web01-old-bak
        $before = $n
        $n = $n -replace "[-_ ]+($tokens)$", ''
        $n = $n -replace "^($tokens)[-_ ]+", ''
    } while ($n -ne $before)
    $n -replace '[-_ ]', ''
}

function Get-Distance([string]$a, [string]$b) {           # Levenshtein edit distance
    $d = [int[,]]::new($a.Length + 1, $b.Length + 1)
    for ($i = 0; $i -le $a.Length; $i++) { $d[$i, 0] = $i }
    for ($j = 0; $j -le $b.Length; $j++) { $d[0, $j] = $j }
    for ($i = 1; $i -le $a.Length; $i++) {
        for ($j = 1; $j -le $b.Length; $j++) {
            $cost = if ($a[$i - 1] -eq $b[$j - 1]) { 0 } else { 1 }
            $d[$i, $j] = [Math]::Min([Math]::Min($d[($i - 1), $j] + 1, $d[$i, ($j - 1)] + 1), $d[($i - 1), ($j - 1)] + $cost)
        }
    }
    $d[$a.Length, $b.Length]
}

function Get-MatchType([string]$tCore, [string]$cCore) {
    if ($cCore -eq $tCore) { return 'SameCore' }
    if ($tCore.Length -ge $MinCoreLength -and $cCore.Length -ge $MinCoreLength) {
        $long, $short = if ($cCore.Length -ge $tCore.Length) { $cCore, $tCore } else { $tCore, $cCore }
        # only the digits differ (010 vs 0101, 01 vs 010): a different server in a numbered series
        if ($long.Contains($short) -and $long.Replace($short, '') -notmatch '^\d*$') { return 'Contains' }
    }
    if ($MaxDistance -gt 0 -and (Get-Distance $tCore $cCore) -le $MaxDistance) { return 'Typo' }
    return $null
}

# Targets, and the full decommission list (so a similar VM that is also being decommissioned shows as INFO)
$targets = if ($VMName) { @($VMName | ForEach-Object { [pscustomobject]@{ VMName = $_ } }) } else { @(Get-Manifest $Manifest $Wave) }
$listed = @($VMName) + @(if (Test-Path $Manifest) { (Import-Csv $Manifest).VMName }) | Where-Object { $_ } | ForEach-Object { $_.ToLower() }

Connect-VIServer -Server $VCenter | Out-Null
$inventory = @(Get-VM | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Core = Get-Core $_.Name; PowerState = [string]$_.PowerState
                       Cluster = $_.VMHost.Parent.Name; Vm = $_ }
})
Write-Host "Checking $($targets.Count) VM(s) against $($inventory.Count) VMs in vCenter." -ForegroundColor Cyan

$rows = foreach ($t in $targets) {
    $tName = $t.VMName
    $tCore = Get-Core $tName
    $self  = $inventory | Where-Object Name -eq $tName | Select-Object -First 1
    $hits  = @(foreach ($c in $inventory) {
        if ($c.Name -eq $tName) { continue }
        $type = Get-MatchType $tCore $c.Core
        if ($type) { $c | Add-Member -NotePropertyName MatchType -NotePropertyValue $type -PassThru }
    })

    if (-not $hits) {
        [pscustomobject]@{ Target = $tName; TargetPower = $(if ($self) { $self.PowerState } else { 'NOT FOUND' })
            SimilarVM = ''; MatchType = ''; PowerState = ''; Cluster = ''; IPs = ''; OnDecomList = ''; Flag = 'NONE'
            Note = $(if ($self) { 'Nothing similar found' } else { 'Target VM not found in vCenter' }) }
        continue
    }
    foreach ($h in $hits) {
        $onList = $listed -contains $h.Name.ToLower()
        $on = $h.PowerState -eq 'PoweredOn'
        $flag, $note = if ($onList)  { 'INFO',    'Similar VM is also on the decommission list' }
                       elseif ($on)  { 'WARNING', 'Similar VM is powered ON and not on the decommission list: confirm it is not the live server' }
                       else          { 'CHECK',   'Similar VM is powered off and not on the decommission list: leftover, or the real server switched off?' }
        $ips = @($h.Vm.Guest.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })
        [pscustomobject]@{ Target = $tName; TargetPower = $(if ($self) { $self.PowerState } else { 'NOT FOUND' })
            SimilarVM = $h.Name; MatchType = $h.MatchType; PowerState = $h.PowerState; Cluster = $h.Cluster
            IPs = $ips -join ';'; OnDecomList = $onList; Flag = $flag; Note = $note }
    }
}

$order = @{ WARNING = 0; CHECK = 1; INFO = 2; NONE = 3 }
$rows = @($rows | Sort-Object { $order[$_.Flag] }, Target, SimilarVM)
$out = Join-Path $ReportDir 'similar-hosts.csv'
$rows | Export-Csv -Path $out -NoTypeInformation
Write-Host "Report written to $out" -ForegroundColor Cyan

$flagged = @($rows | Where-Object Flag -in 'WARNING', 'CHECK')
$counts = $rows | Group-Object Flag | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host "Rows: $($rows.Count)  ($($counts -join ', '))" -ForegroundColor Cyan
if ($flagged) {
    Write-Host "`nNeeds a look before decommissioning:" -ForegroundColor Yellow
    $flagged | Format-Table Flag, Target, TargetPower, SimilarVM, MatchType, PowerState, IPs -AutoSize
}
