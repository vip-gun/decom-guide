#Requires -Version 5.1
<#
.SYNOPSIS  ServiceNow CMDB: find the CI(s) and their relationships, then set them to retired/archived.
.NOTES     Table API with basic auth. SNOW_URL = https://<instance>.service-now.com
           Status values differ between instances. Run -Mode Choices first and pass the right values.
           Out of the box: install_status 7 = Retired, operational_status 6 = Retired.

  .\09-servicenow.ps1 -Mode Choices
  .\09-servicenow.ps1 -Mode Fetch   -Wave 1          # Related column helps find apps/DBs that depend on the VM
  .\09-servicenow.ps1 -Mode Archive -Wave 1 -InstallStatus 7 -OperationalStatus 6 [-Execute]

  curl equivalents:
    curl -u user:pass "$SN/api/now/table/cmdb_ci?sysparm_query=name=appsrv01^ORfqdn=appsrv01.corp.example.com&sysparm_fields=sys_id,name,sys_class_name,install_status"
    curl -u user:pass "$SN/api/now/table/cmdb_rel_ci?sysparm_query=parent=<sys_id>^ORchild=<sys_id>&sysparm_display_value=true"
    curl -u user:pass -X PATCH -H "Content-Type: application/json" \
         -d '{"install_status":"7","operational_status":"6"}' "$SN/api/now/table/cmdb_ci_win_server/<sys_id>"
#>
[CmdletBinding()]
param(
    [string]$SnowUrl = $env:SNOW_URL,
    [pscredential]$Credential,
    [string]$InstallStatus = '7',
    [string]$OperationalStatus = '6',
    [string]$Manifest = "$PSScriptRoot/manifest.csv",
    [string]$Wave,
    [ValidateSet('Choices', 'Fetch', 'Archive')][string]$Mode = 'Fetch',
    [switch]$Execute
)
. "$PSScriptRoot/_common.ps1"
if (-not $Credential) { $Credential = Get-Credential -Message 'ServiceNow user' }
$sn = @{ Credential = $Credential; Headers = @{ Accept = 'application/json' } }
function Get-Sn([string]$Table, [string]$Query, [string]$Fields, [string]$Display = 'false') {
    $u = "$SnowUrl/api/now/table/$Table" + "?sysparm_query=$([uri]::EscapeDataString($Query))&sysparm_display_value=$Display"
    if ($Fields) { $u += "&sysparm_fields=$Fields" }
    (Invoke-Api -Uri $u @sn).result
}

switch ($Mode) {
    'Choices' {
        Get-Sn 'sys_choice' 'name=cmdb_ci^elementINinstall_status,operational_status^inactive=false' 'element,value,label' |
            Sort-Object element, value | Format-Table element, value, label
    }

    'Fetch' {
        $fields = 'sys_id,name,sys_class_name,fqdn,ip_address,install_status,operational_status,owned_by,support_group'
        $rows = foreach ($vm in Get-Manifest $Manifest $Wave) {
            $q = if ($vm.SnowSysId) { "sys_id=$($vm.SnowSysId)" }
                 else { "name=$($vm.Hostname)^ORname=$($vm.FQDN)^ORfqdn=$($vm.FQDN)" }
            $cis = @(Get-Sn 'cmdb_ci' $q $fields 'all')
            foreach ($ci in $cis) {
                $id = $ci.sys_id.value
                $rels = Get-Sn 'cmdb_rel_ci' "parent=$id^ORchild=$id" 'parent,child,type' 'true'
                [pscustomobject]@{
                    Hostname          = $vm.Hostname
                    SysId             = $id
                    Class             = $ci.sys_class_name.value
                    Name              = $ci.name.value
                    IP                = $ci.ip_address.value
                    InstallStatus     = $ci.install_status.display_value
                    OperationalStatus = $ci.operational_status.display_value
                    Owner             = $ci.owned_by.display_value
                    SupportGroup      = $ci.support_group.display_value
                    Related           = (($rels | ForEach-Object { "$($_.parent.display_value) [$($_.type.display_value)] $($_.child.display_value)" }) -join ' | ')
                    Action            = if ($cis.Count -gt 1) { 'Review' } else { 'Delete' }   # Delete = archive in this script
                    Reason            = if ($cis.Count -gt 1) { 'Several CIs match - pick the right one(s)' } else { '' }
                }
            }
            if (-not $cis) { [pscustomobject]@{ Hostname = $vm.Hostname; SysId = ''; Class = ''; Name = ''; IP = ''; InstallStatus = ''
                OperationalStatus = ''; Owner = ''; SupportGroup = ''; Related = ''; Action = 'None'; Reason = 'No CI found' } }
        }
        Export-Review $rows 'servicenow'
    }

    'Archive' {
        foreach ($r in Import-Review 'servicenow') {
            Invoke-Step -Execute:$Execute $r.Hostname 'ServiceNow' "$($r.Class)/$($r.SysId) install_status=$InstallStatus operational_status=$OperationalStatus" {
                $body = @{ install_status = $InstallStatus; operational_status = $OperationalStatus } | ConvertTo-Json
                Invoke-Api -Method Patch -Uri "$SnowUrl/api/now/table/$($r.Class)/$($r.SysId)" @sn `
                    -ContentType 'application/json' -Body $body
            }
        }
    }
}
