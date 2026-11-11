#Requires -Version 5.1
<#
.SYNOPSIS  SQL Server: databases hosted ON the VM, and databases/logins on SHARED instances used BY the VM.
.NOTES     Requires the SqlServer module (Install-Module SqlServer).
           Fetch is point-in-time: sys.dm_exec_sessions only shows who is connected right now.
           Run it several times over a few days (or use SQL Audit / Extended Events) before the power-off,
           and confirm with the app owner. Nothing here is pre-approved: every row starts as Review.

  .\04-databases.ps1 -Mode Fetch -Wave 1 -SqlInstances sqlcl01\PROD,sqlcl02
  .\04-databases.ps1 -Mode Delete -Wave 1 -BackupPath '\\backup\decom' [-Execute]

  Review file rows you can approve (Action = Delete):
    Kind = Database -> COPY_ONLY backup, then DROP DATABASE  (on the shared instance in the Instance column)
    Kind = Login    -> DROP LOGIN  (database users mapped to it become orphaned; drop those per DB if needed)
    Kind = Local    -> information only: a database ON the VM; it goes with the VM. Archive it first if required.

  -- PostgreSQL equivalents (run on each shared cluster):
  -- SELECT datname, usename, client_addr, client_hostname, application_name
  --   FROM pg_stat_activity WHERE client_addr IN ('10.10.20.15');
  -- \! pg_dump -Fc -f /backup/decom/appdb.dump appdb
  -- SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'appdb';
  -- DROP DATABASE appdb;
#>
[CmdletBinding()]
param(
    [string[]]$SqlInstances = @(),          # shared instances to scan for connections from the VMs
    [string]$BackupPath,                    # UNC path the SQL service account can write to
    [string]$Manifest = "$PSScriptRoot/manifest.csv",
    [string]$Wave,
    [ValidateSet('Fetch', 'Delete')][string]$Mode = 'Fetch',
    [switch]$Execute
)
. "$PSScriptRoot/_common.ps1"
Import-Module SqlServer
$sql = @{ TrustServerCertificate = $true; ErrorAction = 'Stop' }
function Q([string]$Name) { '[' + $Name.Replace(']', ']]') + ']' }

if ($Mode -eq 'Fetch') {
    $vms = @(Get-Manifest $Manifest $Wave)
    $rows = [System.Collections.Generic.List[object]]::new()

    # (a) Is the VM itself a SQL Server? (default instance; named instances need SQL Browser)
    foreach ($vm in $vms | Where-Object OS -eq 'Windows') {
        try {
            $dbs = Invoke-Sqlcmd @sql -ServerInstance $vm.FQDN -ConnectionTimeout 5 -Query @'
SELECT name, state_desc, create_date, recovery_model_desc FROM sys.databases WHERE database_id > 4
'@
            foreach ($d in $dbs) {
                $rows.Add([pscustomobject]@{ Hostname = $vm.Hostname; Kind = 'Local'; Instance = $vm.FQDN; Database = $d.name
                    LoginName = ''; Detail = "$($d.state_desc), created $($d.create_date)"; Action = 'Review' })
            }
        } catch { }   # no SQL listening = nothing local
    }

    # (b) On each shared instance: live sessions + logins that belong to the VMs
    foreach ($inst in $SqlInstances) {
        $sessions = Invoke-Sqlcmd @sql -ServerInstance $inst -Query @'
SELECT s.host_name, s.login_name, DB_NAME(s.database_id) AS database_name, s.program_name, c.client_net_address
FROM sys.dm_exec_sessions s
JOIN sys.dm_exec_connections c ON c.session_id = s.session_id
WHERE s.is_user_process = 1
'@
        $logins = Invoke-Sqlcmd @sql -ServerInstance $inst -Query @'
SELECT name, type_desc, create_date FROM sys.server_principals WHERE type IN ('U','S','G')
'@
        foreach ($vm in $vms) {
            $mine = $sessions | Where-Object { $_.host_name -eq $vm.Hostname -or $_.client_net_address -in $vm.IPList }
            foreach ($g in ($mine | Group-Object database_name)) {
                $rows.Add([pscustomobject]@{ Hostname = $vm.Hostname; Kind = 'Database'; Instance = $inst; Database = $g.Name
                    LoginName = (($g.Group.login_name | Sort-Object -Unique) -join ';')
                    Detail = 'Live session(s): ' + (($g.Group.program_name | Sort-Object -Unique) -join '; ')
                    Action = 'Review' })
            }
            # DOMAIN\HOSTNAME$ is the VM's machine account; any login containing the hostname is worth a look
            foreach ($l in ($logins | Where-Object { $_.name -like "*$($vm.Hostname)*" })) {
                $rows.Add([pscustomobject]@{ Hostname = $vm.Hostname; Kind = 'Login'; Instance = $inst; Database = ''
                    LoginName = $l.name; Detail = "$($l.type_desc), created $($l.create_date)"; Action = 'Review' })
            }
        }
    }
    Export-Review $rows 'databases'
    return
}

foreach ($r in Import-Review 'databases') {
    switch ($r.Kind) {
        'Database' {
            if (-not $BackupPath) { throw 'Pass -BackupPath so a final backup is taken before any DROP.' }
            $file = Join-Path $BackupPath "$($r.Database)_decom_$(Get-Date -Format yyyyMMdd).bak"
            $tsql = @"
BACKUP DATABASE $(Q $r.Database) TO DISK = N'$($file.Replace("'", "''"))' WITH COPY_ONLY, COMPRESSION, CHECKSUM;
ALTER DATABASE $(Q $r.Database) SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE $(Q $r.Database);
"@
            Invoke-Step -Execute:$Execute $r.Hostname 'DB-Drop' "Backup to $file then DROP $($r.Database) on $($r.Instance)" {
                Invoke-Sqlcmd @sql -ServerInstance $r.Instance -Query $tsql -QueryTimeout 0
            }
        }
        'Login' {
            Invoke-Step -Execute:$Execute $r.Hostname 'DB-DropLogin' "DROP LOGIN $($r.LoginName) on $($r.Instance)" {
                Invoke-Sqlcmd @sql -ServerInstance $r.Instance -Query "DROP LOGIN $(Q $r.LoginName);"
            }
        }
        default { Write-Host "Skipping $($r.Kind) row for $($r.Hostname) ($($r.Database)) - goes with the VM." }
    }
}
