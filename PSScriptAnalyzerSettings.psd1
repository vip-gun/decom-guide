# Run with:  Invoke-ScriptAnalyzer -Path . -Settings ./PSScriptAnalyzerSettings.psd1
# The scripts must work on Windows PowerShell 5.1 and PowerShell 7, so the compatibility rules below
# check syntax, cmdlets, parameters and .NET types against a clean Windows PowerShell 5.1 install.
# (Parameters passed through a splatted hashtable are invisible to these rules: review those by hand.)
@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # Intentional: the scripts print coloured [DRY-RUN] / [DONE] / [GONE] lines for the engineer
        # running them. Every action is also written to reports/results.csv, so nothing depends on this output.
        'PSAvoidUsingWriteHost'

        # Intentional: 04-databases.ps1 probes each VM for a local SQL Server.
        # No answer simply means the VM has no local databases to report.
        'PSAvoidUsingEmptyCatchBlock'
    )

    Rules        = @{
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
        PSUseCompatibleTypes    = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}
