# Entry point of /session-restore:restore. Runs in Windows PowerShell 5.1 and PowerShell 7.
param(
    [Parameter(Mandatory)][string]$DataDir,
    [Parameter(ValueFromRemainingArguments)][string[]]$Arguments
)

. (Join-Path $PSScriptRoot 'SessionRestore.ps1')
# Claude reads this output as UTF-8; Windows PowerShell would write it in the ANSI code page and garble non-English
# folder names and titles.
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
try {
    # Wide enough for full folder paths and long titles: Format-Table drops columns that don't fit.
    Invoke-SessionRestore -DataDir $DataDir -Arguments ($Arguments -join ' ') | Out-String -Width 500
}
catch {
    # A non-zero exit aborts the slash command, so report failures as regular output.
    "session-restore failed: $($_.Exception.Message)"
}
exit 0
