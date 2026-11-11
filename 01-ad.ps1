<#
.SYNOPSIS  Active Directory computer objects.
.NOTES     Requires the ActiveDirectory module (RSAT).

  .\01-ad.ps1 -Mode Fetch  -Wave 1
  .\01-ad.ps1 -Mode Disable -Wave 1 -Execute      # optional, during the soft-off period
  .\01-ad.ps1 -Mode Delete -Wave 1                # dry run
  .\01-ad.ps1 -Mode Delete -Wave 1 -Execute
#>
[CmdletBinding()]
param(
    [string]$Server = $env:USERDNSDOMAIN,   # domain controller or domain name
    [string]$Manifest = "$PSScriptRoot/manifest.csv",
    [string]$Wave,
    [int]$RecentLogonDays = 14,             # a logon newer than this means "still alive?" -> Review
    [ValidateSet('Fetch', 'Disable', 'Delete')][string]$Mode = 'Fetch',
    [switch]$Execute
)
. "$PSScriptRoot/_common.ps1"
Import-Module ActiveDirectory

if ($Mode -eq 'Fetch') {
    $rows = foreach ($vm in Get-Manifest $Manifest $Wave) {
        # FETCH: equivalent one-liner
        #   Get-ADComputer -Filter "Name -eq 'APPSRV01'" -Properties LastLogonDate,OperatingSystem,IPv4Address
        $c = Get-ADComputer -Server $Server -Filter "Name -eq '$($vm.Hostname)'" `
                -Properties Enabled, LastLogonDate, OperatingSystem, IPv4Address, Description, ManagedBy
        if (-not $c) {
            [pscustomobject]@{ Hostname = $vm.Hostname; DistinguishedName = ''; Enabled = ''; LastLogonDate = ''
                OperatingSystem = ''; IPv4Address = ''; ChildObjects = ''; Action = 'None'; Reason = 'Not in AD' }
            continue
        }
        # Child objects (BitLocker keys, Hyper-V/cluster SCPs...) are removed too by -Recursive
        $children = Get-ADObject -Server $Server -SearchBase $c.DistinguishedName -SearchScope OneLevel -Filter * |
                    ForEach-Object ObjectClass
        $recent = $c.LastLogonDate -and $c.LastLogonDate -gt (Get-Date).AddDays(-$RecentLogonDays)
        [pscustomobject]@{
            Hostname          = $vm.Hostname
            DistinguishedName = $c.DistinguishedName
            Enabled           = $c.Enabled
            LastLogonDate     = $c.LastLogonDate
            OperatingSystem   = $c.OperatingSystem
            IPv4Address       = $c.IPv4Address
            ChildObjects      = ($children -join ';')
            Action            = if ($recent) { 'Review' } else { 'Delete' }
            Reason            = if ($recent) { "Logged on in the last $RecentLogonDays days" } else { '' }
        }
    }
    Export-Review $rows 'ad'
    return
}

# Disable uses the same approved rows as Delete
foreach ($r in Import-Review 'ad') {
    if ($Mode -eq 'Disable') {
        Invoke-Step $r.Hostname 'AD-Disable' "Disable-ADAccount $($r.DistinguishedName)" {
            Disable-ADAccount -Server $Server -Identity $r.DistinguishedName
        }
    } else {
        # DELETE: Remove-ADObject -Identity '<DN>' -Recursive -Confirm:$false
        Invoke-Step $r.Hostname 'AD-Delete' "Remove-ADObject $($r.DistinguishedName) -Recursive" {
            Remove-ADObject -Server $Server -Identity $r.DistinguishedName -Recursive -Confirm:$false
        }
    }
}
