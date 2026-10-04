# Functions behind /session-restore:restore. Free of PowerShell 7-only syntax so it runs in the Windows
# PowerShell 5.1 every Windows PC has, and ASCII only because 5.1 reads BOM-less scripts as ANSI.

. (Join-Path $PSScriptRoot '..\..\..\scripts\SessionStore.ps1')

# A session closed with the window's X stays tracked; plain restore skips those unused for longer than this.
$script:RecentDays = 7
# Claude Code deletes transcripts after 30 days by default, so older entries can't be resumed anyway.
$script:ExpiryDays = 30
# Claude keeps re-appending its title lines, so the end of a transcript is enough; transcripts can be hundreds of MB.
$script:TitleSearchBytes = 1MB

$script:Usage = @'
Usage: /session-restore:restore [list | all | NUMBERS | forget NUMBERS]

  (nothing)   reopen the closed sessions used in the last 7 days
  list        show every tracked session with its number
  all         reopen every closed session, however old
  1,3         reopen sessions #1 and #3 from the list
  forget 2    stop tracking session #2 without reopening it
'@

function ConvertTo-RestoreRequest([string]$Arguments) {
    $words = @($Arguments -split '[\s,]+' | Where-Object { $_ })
    # Unique, so "1,1" can't open the same session twice.
    $numbers = @($words | Where-Object { $_ -match '^#?\d+$' } | ForEach-Object { [int]$_.TrimStart('#') } | Select-Object -Unique)
    $action = switch (@($words | Where-Object { $_ -notmatch '^#?\d+$' }) -join ' ') {
        '' { 'restore' }
        'list' { 'list' }
        'all' { 'all' }
        # .Count, because a lone 0 would make @(0) false.
        'forget' { if ($numbers.Count) { 'forget' } else { 'help' } }
        default { 'help' }
    }
    [pscustomobject]@{ Action = $action; Numbers = $numbers }
}

function Get-SessionTitle([string]$Transcript) {
    # The /rename title if there is one, else the automatic title; '' when neither can be read.
    try {
        $stream = [IO.File]::Open($Transcript, 'Open', 'Read', 'ReadWrite')
        try {
            [void]$stream.Seek([Math]::Max(0, $stream.Length - $script:TitleSearchBytes), 'Begin')
            $lines = (New-Object IO.StreamReader $stream).ReadToEnd() -split "`n"
        }
        finally { $stream.Dispose() }
        $line = $lines -match '^\{"type":"custom-title"' | Select-Object -Last 1
        if (-not $line) { $line = $lines -match '^\{"type":"ai-title"' | Select-Object -Last 1 }
        if (-not $line) { return '' }
        $title = $line | ConvertFrom-Json
        if ($title.customTitle) { $title.customTitle } else { $title.aiTitle }
    }
    catch { '' }
}

function Get-ResumingCommandLines {
    # Command lines of the claude processes resuming a session. Only claude itself counts: the shell around it may
    # outlive it.
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue `
            -Filter "(Name='claude.exe' OR Name='node.exe') AND CommandLine LIKE '%-r%'" | ForEach-Object CommandLine)
}

function Test-SessionRunning($Entry, [string[]]$ResumingCommandLines) {
    # Same PID and start time means the claude process that recorded the session still runs (PIDs get reused).
    $process = if ($Entry.pid) { Get-Process -Id $Entry.pid -ErrorAction SilentlyContinue }
    if ($process -and $process.StartTime -and $Entry.pidStarted -and
        [Math]::Abs(($process.StartTime.ToUniversalTime() - (ConvertTo-UniversalTime $Entry.pidStarted)).TotalSeconds) -lt 1) {
        return $true
    }
    # A session reopened moments ago runs under a PID its hook hasn't recorded yet, or waits at the folder trust
    # prompt before any hook runs. It counts as running too, or a second restore would start another claude on the
    # same conversation.
    $resumeArgument = '(^|\s)(-r|--resume)[\s=]+"?' + [regex]::Escape($Entry.sessionId) + '("|\s|$)'
    [bool]($ResumingCommandLines -match $resumeArgument)
}

function Get-TrackedSessions {
    # Every readable entry, in the order the sessions were opened, not yet numbered (see Set-SessionNumbers).
    # Expired entries are marked; unreadable ones produce a warning.
    [CmdletBinding()]
    param([string]$DataDir)

    $resuming = Get-ResumingCommandLines
    $expiry = (Get-Date).AddDays(-$script:ExpiryDays)
    foreach ($file in Get-SessionFiles $DataDir) {
        $entry = Read-SessionEntry $file.FullName
        if (-not $entry) {
            Write-Warning "Skipped the unreadable entry $($file.Name)."
            continue
        }
        $running = Test-SessionRunning $entry $resuming
        $hasTranscript = [bool]($entry.transcript -and (Test-Path -LiteralPath $entry.transcript))
        # Nothing was typed in a session without a transcript; its entry was written when it started.
        $lastActive = if ($hasTranscript) { (Get-Item -LiteralPath $entry.transcript).LastWriteTime } else { $file.LastWriteTime }
        [pscustomobject]@{
            Number        = $null
            Folder        = Split-Path $entry.cwd -Leaf
            Title         = if ($hasTranscript) { Get-SessionTitle $entry.transcript } else { '' }
            Shell         = $entry.shell
            LastActive    = $lastActive
            Running       = $running
            Expired       = -not $running -and $lastActive -lt $expiry
            SessionId     = $entry.sessionId
            Cwd           = $entry.cwd
            Flags         = $entry.flags
            HasTranscript = $hasTranscript
            File          = $file.FullName
        }
    }
}

function Get-ListedSessionIds([string]$DataDir) {
    # The sessions the last "list" showed, in its order: #1 first.
    try { $ids = [IO.File]::ReadAllText((Join-Path $DataDir 'list.json')) | ConvertFrom-Json } catch { return @() }
    # Windows PowerShell passes a JSON array on as one object, which @(...) around the pipeline would wrap again;
    # @() around the variable gives the same array in every version.
    [string[]]@($ids)
}

function Save-ListedSessionIds([string]$DataDir, [string[]]$SessionIds) {
    [void][IO.Directory]::CreateDirectory($DataDir)
    [IO.File]::WriteAllText((Join-Path $DataDir 'list.json'), (ConvertTo-Json @($SessionIds)), (New-Object Text.UTF8Encoding $false))
}

function Set-SessionNumbers($Sessions, [string[]]$ListedIds) {
    # Sessions the last "list" showed keep the numbers it showed, so a number typed afterwards means the same session
    # even after other sessions are used. The rest are numbered after those, most recently used first.
    $listed = @{}
    for ($i = 0; $i -lt $ListedIds.Count; $i++) { $listed[$ListedIds[$i]] = $i + 1 }
    $next = $ListedIds.Count
    foreach ($session in ($Sessions | Sort-Object LastActive -Descending)) {
        $session.Number = if ($listed.ContainsKey($session.SessionId)) { $listed[$session.SessionId] } else { (++$next) }
    }
}

function Format-Session($Session) {
    $text = "#$($Session.Number) $($Session.Folder)"
    if ($Session.Title) { $text += ": $($Session.Title)" }
    $text
}

function Show-TrackedSessions($Sessions) {
    $Sessions | Sort-Object Number |
        Format-Table @{ n = '#'; e = { $_.Number } }, @{ n = 'Folder'; e = { $_.Cwd } }, Title, Shell,
        @{ n = 'Last active'; e = { $_.LastActive.ToString('yyyy-MM-dd HH:mm') } },
        @{ n = 'Status'; e = { if ($_.Running) { 'open' } else { 'closed' } } } -AutoSize
}

function Remove-TrackedSessions($Sessions, [int[]]$Numbers) {
    # "forget": stops tracking sessions without reopening them.
    foreach ($number in $Numbers) {
        $session = $Sessions | Where-Object Number -eq $number
        if (-not $session) { "There is no session #$number."; continue }
        Remove-SessionFile $session.File
        "Forgot $(Format-Session $session)."
    }
}

function Select-SessionsToRestore($Sessions, $Request) {
    # The closed sessions a request asks for, and notes about the ones it can't or won't reopen.
    $selected = New-Object Collections.Generic.List[object]
    $notes = New-Object Collections.Generic.List[string]
    $closed = @($Sessions | Where-Object { -not $_.Running })
    if ($Request.Numbers.Count) {
        foreach ($number in $Request.Numbers) {
            $session = $Sessions | Where-Object Number -eq $number
            if (-not $session) { $notes.Add("There is no session #$number.") }
            elseif ($session.Running) { $notes.Add("$(Format-Session $session) is already open.") }
            else { $selected.Add($session) }
        }
    }
    elseif ($Request.Action -eq 'all') { $closed | ForEach-Object { $selected.Add($_) } }
    else {
        $cutoff = (Get-Date).AddDays(-$script:RecentDays)
        $closed | Where-Object { $_.LastActive -gt $cutoff } | ForEach-Object { $selected.Add($_) }
        $stale = $closed.Count - $selected.Count
        if ($stale) {
            $notes.Add("Skipped $stale session(s) unused for over $($script:RecentDays) days; 'all', or their numbers from 'list', reopen them.")
        }
    }
    [pscustomobject]@{ Sessions = $selected.ToArray(); Notes = $notes.ToArray() }
}

function Get-TabCommand($Session, [bool]$HasPwsh) {
    # Nothing was typed in a session without a transcript, so there is no conversation to resume: start a fresh one.
    $claude = if ($Session.HasTranscript) { "claude --resume $($Session.SessionId)" } else { 'claude' }
    if ($Session.Flags) { $claude += " $($Session.Flags)" }

    # Reopen in the shell it was started from; Git Bash and others get PowerShell.
    $shell = $Session.Shell
    if ($shell -notin 'cmd', 'powershell', 'pwsh') { $shell = 'pwsh' }
    if ($shell -eq 'pwsh' -and -not $HasPwsh) { $shell = 'powershell' }
    if ($shell -eq 'cmd') { return 'cmd', '/k', $claude }
    # A PowerShell profile may change folder after the tab opens, and claude would then work in that folder instead.
    # The escaper also handles the curly quotes PowerShell accepts as single quotes.
    $folder = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Session.Cwd)
    $shell, '-NoExit', '-Command', ("Set-Location -LiteralPath '$folder'; " + $claude)
}

function ConvertTo-CommandLine([string[]]$Arguments) {
    # Quote each argument the way CommandLineToArgvW splits them, which is how wt.exe reads its command line.
    @($Arguments | ForEach-Object {
            if ($_ -and $_ -notmatch '[\s"]') { $_ }
            else { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
        }) -join ' '
}

function Get-LoginEnvironment {
    # The environment a tab opened by hand would get. Claude's shells add variables such as CLAUDECODE, NO_COLOR and
    # GIT_EDITOR=true, and Windows Terminal hands the caller's environment to new tabs, so don't pass ours on.
    if (-not ('SessionRestore.LoginEnvironment' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace SessionRestore {
    public static class LoginEnvironment {
        [DllImport("userenv.dll", SetLastError = true)]
        static extern bool CreateEnvironmentBlock(out IntPtr block, IntPtr token, bool inherit);

        [DllImport("userenv.dll", SetLastError = true)]
        static extern bool DestroyEnvironmentBlock(IntPtr block);

        public static Hashtable Get() {
            IntPtr block;
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) {
                if (!CreateEnvironmentBlock(out block, identity.Token, false))
                    throw new System.ComponentModel.Win32Exception();
            }
            Hashtable variables = new Hashtable(StringComparer.OrdinalIgnoreCase);
            try {
                IntPtr entry = block;
                while (true) {
                    string text = Marshal.PtrToStringUni(entry);
                    if (string.IsNullOrEmpty(text)) break;
                    int equals = text.IndexOf('=', 1);
                    if (equals > 0) variables[text.Substring(0, equals)] = text.Substring(equals + 1);
                    entry = IntPtr.Add(entry, (text.Length + 1) * 2);
                }
            }
            finally { DestroyEnvironmentBlock(block); }
            return variables;
        }
    }
}
'@
    }
    [SessionRestore.LoginEnvironment]::Get()
}

function New-TabStartInfo($Session, [string[]]$ShellCommand, [hashtable]$Environment, [string]$WindowsTerminal) {
    if ($WindowsTerminal) {
        # wt reads a bare ";" as the start of its next command.
        $arguments = @('-w', '0', 'new-tab', '--title', $Session.Folder, '-d', $Session.Cwd) + $ShellCommand |
            ForEach-Object { $_ -replace ';', '\;' }
        $info = New-Object Diagnostics.ProcessStartInfo $WindowsTerminal, (ConvertTo-CommandLine $arguments)
    }
    else {
        # No Windows Terminal: cmd's start opens a console window instead.
        $line = '/c start "' + $Session.Folder + '" /d "' + $Session.Cwd + '" ' + (ConvertTo-CommandLine $ShellCommand)
        $info = New-Object Diagnostics.ProcessStartInfo (Join-Path $env:SystemRoot 'System32\cmd.exe'), $line
        $info.CreateNoWindow = $true
    }
    $info.UseShellExecute = $false
    $info.EnvironmentVariables.Clear()
    foreach ($name in $Environment.Keys) { $info.EnvironmentVariables[$name] = $Environment[$name] }
    $info
}

function Start-SessionTab($Session, [string[]]$ShellCommand, [hashtable]$Environment) {
    $wt = Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    ([Diagnostics.Process]::Start((New-TabStartInfo $Session $ShellCommand $Environment $wt.Source))).Dispose()
}

function Open-SessionTabs($Sessions) {
    # Opens a tab per session. Returns the sessions opened and notes about the ones that weren't.
    $opened = New-Object Collections.Generic.List[object]
    $notes = New-Object Collections.Generic.List[string]
    if ($Sessions) {
        $environment = Get-LoginEnvironment
        $hasPwsh = [bool](Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue)
        foreach ($session in $Sessions) {
            if (-not (Test-Path -LiteralPath $session.Cwd)) {
                $notes.Add("Skipped $(Format-Session $session): $($session.Cwd) can't be found ('forget $($session.Number)' removes it).")
                continue
            }
            try { Start-SessionTab $session (Get-TabCommand $session $hasPwsh) $environment }
            catch {
                $notes.Add("Couldn't open $(Format-Session $session): $($_.Exception.Message)")
                continue
            }
            # The fresh claude started for a session without a conversation registers itself.
            if (-not $session.HasTranscript) { Remove-SessionFile $session.File }
            $opened.Add($session)
            # Gives Windows Terminal time to open the tabs in this order.
            Start-Sleep -Milliseconds 300
        }
    }
    [pscustomobject]@{ Opened = $opened.ToArray(); Notes = $notes.ToArray() }
}

function Invoke-SessionRestore([string]$DataDir, [string]$Arguments) {
    $request = ConvertTo-RestoreRequest $Arguments
    if ($request.Action -eq 'help') { return $script:Usage }

    $tracked = @(Get-TrackedSessions $DataDir -WarningVariable problems -WarningAction SilentlyContinue)
    $tracked | Where-Object Expired | ForEach-Object { Remove-SessionFile $_.File }
    $sessions = @($tracked | Where-Object { -not $_.Expired })
    $notes = @($problems | ForEach-Object { "$_" })
    if (-not $sessions) {
        'No tracked sessions yet. Sessions are tracked from when they start, once the plugin is installed.'
        return $notes
    }

    if ($request.Action -eq 'list') {
        # Rows are numbered 1, 2, 3... most recently used first, and that numbering is kept for the next commands.
        Set-SessionNumbers $sessions @()
        Save-ListedSessionIds $DataDir ($sessions | Sort-Object Number | ForEach-Object SessionId)
        Show-TrackedSessions $sessions
        return $notes
    }
    Set-SessionNumbers $sessions (Get-ListedSessionIds $DataDir)
    if ($request.Action -eq 'forget') {
        Remove-TrackedSessions $sessions $request.Numbers
        return $notes
    }

    $selection = Select-SessionsToRestore $sessions $request
    $result = Open-SessionTabs $selection.Sessions
    if ($result.Opened) {
        "Reopened $($result.Opened.Count) session(s) in new tabs:"
        $result.Opened | ForEach-Object { "  $(Format-Session $_)" }
    }
    elseif (-not ($sessions | Where-Object { -not $_.Running })) { 'Nothing to reopen: every tracked session is still open.' }
    else { 'Nothing reopened.' }
    $notes + $selection.Notes + $result.Notes
}
