# Run with:  Invoke-ScriptAnalyzer -Path . -Settings ./PSScriptAnalyzerSettings.psd1
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
}
