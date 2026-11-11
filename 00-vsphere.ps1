#Requires -Version 5.1
<#
.SYNOPSIS  Build the manifest from vCenter; later power off and delete the VMs.
.NOTES     Requires VMware PowerCLI (Install-Module VMware.PowerCLI).
           Run Fetch BEFORE powering anything off: guest IPs and hostnames come from VMware Tools
           and are only reported while the VM is running.

  .\00-vsphere.ps1 -VCenter vc01 -Mode Fetch                 # vm-list.txt -> manifest.csv
  .\00-vsphere.ps1 -VCenter vc01 -Mode PowerOff -Wave 1 -Change CHG0012345 -Execute
  .\00-vsphere.ps1 -VCenter vc01 -Mode Delete   -Wave 1 -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VCenter,
    [string]$InputList = "$PSScriptRoot/vm-list.txt",   # one VM name per line
    [string]$Manifest  = "$PSScriptRoot/manifest.csv",
    [string]$Wave,
    [string]$Change,                                    # change number, written to the VM notes
    [ValidateSet('Fetch', 'PowerOff', 'Delete')][string]$Mode = 'Fetch',
    [switch]$Execute
)
. "$PSScriptRoot/_common.ps1"
Connect-VIServer -Server $VCenter | Out-Null

switch ($Mode) {
    'Fetch' {
        $rows = foreach ($name in (Get-Content $InputList -Encoding UTF8 | ForEach-Object Trim | Where-Object { $_ })) {
            $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
            if (-not $vm) {
                [pscustomobject]@{ Wave = ''; VMName = $name; Hostname = ''; FQDN = ''; IPs = ''; OS = ''; GuestOS = ''
                    PowerState = 'NOT FOUND'; Cluster = ''; Folder = ''; Owner = ''; SnowSysId = ''; Notes = 'Not found in vCenter' }
                continue
            }
            $ips  = $vm.Guest.Nics | ForEach-Object IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Sort-Object -Unique
            $fqdn = $vm.Guest.HostName
            [pscustomobject]@{
                Wave       = ''
                VMName     = $vm.Name
                Hostname   = if ($fqdn) { $fqdn.Split('.')[0] } else { $vm.Name }   # AD computer name
                FQDN       = $fqdn
                IPs        = $ips -join ';'
                OS         = if ($vm.Guest.OSFullName -match 'Windows') { 'Windows' } else { 'Linux' }
                GuestOS    = $vm.Guest.OSFullName
                PowerState = $vm.PowerState
                Cluster    = $vm.VMHost.Parent.Name
                Folder     = $vm.Folder.Name
                Owner      = ''
                SnowSysId  = ''
                Notes      = if (-not $ips) { 'No guest IPs - VMware Tools down? Get them from NetBox' } else { '' }
            }
        }
        $rows | Export-Csv $Manifest -NoTypeInformation -Encoding UTF8
        Write-Host "Manifest written to $Manifest. Fill in Wave/Owner and fix rows flagged in Notes." -ForegroundColor Cyan
    }

    'PowerOff' {
        foreach ($r in Get-Manifest $Manifest $Wave) {
            Invoke-Step -Execute:$Execute $r.Hostname 'vSphere-PowerOff' "Shut down guest $($r.VMName) and tag notes" {
                $vm = Get-VM -Name $r.VMName
                Set-VM -VM $vm -Notes "DECOM wave $Wave $Change powered off $(Get-Date -Format yyyy-MM-dd). $($vm.Notes)" -Confirm:$false
                if ($vm.PowerState -eq 'PoweredOn') { Stop-VMGuest -VM $vm -Confirm:$false }   # graceful; use Stop-VM for hard off
            }
        }
    }

    'Delete' {
        foreach ($r in Get-Manifest $Manifest $Wave) {
            Invoke-Step -Execute:$Execute $r.Hostname 'vSphere-Delete' "Remove-VM $($r.VMName) -DeletePermanently" {
                $vm = Get-VM -Name $r.VMName -ErrorAction Stop
                if ($vm.PowerState -ne 'PoweredOff') { throw "VM is $($vm.PowerState); refusing to delete a running VM" }
                Remove-VM -VM $vm -DeletePermanently -Confirm:$false
            }
        }
    }
}
