# How session-restore stores what it tracks: one JSON file per session in the plugin's data folder. Shared by the
# hook (scripts/tracker.ps1) and the restore command (skills/restore/scripts/restore.ps1).
# Runs in Windows PowerShell 5.1 and PowerShell 7. ASCII only: 5.1 reads BOM-less scripts as ANSI.

function Test-SessionId([string]$SessionId) {
    # Session IDs become file names.
    $SessionId -match '^[\w-]+$'
}

function Get-SessionFile([string]$DataDir, [string]$SessionId) {
    Join-Path $DataDir "sessions\$SessionId.json"
}

function Get-SessionFiles([string]$DataDir) {
    # Oldest first: the order the sessions were opened in, and the order they reopen in.
    Get-ChildItem -LiteralPath (Join-Path $DataDir 'sessions') -Filter *.json -ErrorAction SilentlyContinue |
        Sort-Object CreationTime
}

function Read-SessionEntry([string]$File) {
    # $null for anything but a complete entry, such as a file half-written when the power went out.
    try { $entry = [IO.File]::ReadAllText($File) | ConvertFrom-Json } catch { return $null }
    if ($entry -and (Test-SessionId $entry.sessionId) -and $entry.cwd) { $entry }
}

function Write-SessionEntry([string]$DataDir, $Entry) {
    $file = Get-SessionFile $DataDir $Entry.sessionId
    [void][IO.Directory]::CreateDirectory((Split-Path $file))
    [IO.File]::WriteAllText($file, ($Entry | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}

function Remove-SessionFile([string]$File) {
    # A hook or a restore running at the same time may have removed it already.
    Remove-Item -LiteralPath $File -ErrorAction SilentlyContinue
}

function ConvertTo-UniversalTime($Time) {
    # Times are stored as ISO 8601 text, which Windows PowerShell reads back as text and PowerShell 7 as a local or
    # UTC time, so compare them in UTC.
    ([datetime]$Time).ToUniversalTime()
}
