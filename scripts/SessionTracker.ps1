# What the session-restore hook records when an interactive Claude Code session starts, and when it stops tracking
# one. Runs in Windows PowerShell 5.1 and PowerShell 7. ASCII only: 5.1 reads BOM-less scripts as ANSI.

. (Join-Path $PSScriptRoot 'SessionStore.ps1')

$script:Shells = 'cmd', 'pwsh', 'powershell', 'bash', 'sh', 'zsh', 'fish', 'nu'
# Launchers between a shell and claude, such as Scoop and Volta shims, are named like claude.
$script:Launchers = 'claude', 'node'
$script:PermissionModes = 'acceptEdits', 'auto', 'bypassPermissions', 'dontAsk', 'manual', 'plan'
# How a session starts when its claude process switches to it from another one: /branch, /resume, /clear.
$script:SessionSwitches = 'fork', 'resume', 'clear'
# How a session ends when it's closed on purpose: /exit or Ctrl+C/D, /clear, /resume to another session, logout.
# A closed window, crash or reboot ends with 'other', or with no hook at all, so the session stays tracked.
$script:DeliberateEnds = 'prompt_input_exit', 'clear', 'resume', 'logout'

function Read-HookInput {
    # Claude sends UTF-8; piped stdin is otherwise decoded with the OEM code page, which mangles non-ASCII folder names.
    [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.UTF8Encoding]::new($false)).ReadToEnd() | ConvertFrom-Json
}

function Test-InteractiveSession {
    # Not `claude -p`, SDK, IDE-extension, desktop or background sessions.
    $env:CLAUDE_CODE_ENTRYPOINT -eq 'cli' -and $env:CLAUDE_CODE_SESSION_KIND -notin 'bg', 'daemon', 'daemon-worker'
}

function Get-ProcessTable {
    # Every running process by ID. Each WMI query takes most of a second, so read them all at once.
    $table = @{}
    Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate, CommandLine |
        ForEach-Object { $table[[int]$_.ProcessId] = $_ }
    $table
}

function Find-LaunchShell([hashtable]$Processes, $Process) {
    # The shell a claude process was started from, so it reopens in the same one. $null when some other program
    # started it, since that isn't a terminal session, except that a Windows Terminal profile may start claude itself.
    $child = $Process
    for ($level = 0; $level -lt 3; $level++) {
        $parent = $Processes[[int]$child.ParentProcessId]
        # A parent started after its child is an unrelated process that reused a dead parent's PID.
        if (-not $parent -or $parent.CreationDate -gt $child.CreationDate) { return $null }
        $name = [IO.Path]::GetFileNameWithoutExtension($parent.Name)
        if ($name -eq 'WindowsTerminal') { return 'pwsh' }
        if ($name -in $script:Shells) { return $name }
        if ($name -notin $script:Launchers) { return $null }
        $child = $parent
    }
    $null
}

function Split-CommandLine([string]$CommandLine) {
    # Splits roughly as the C runtime does: double quotes group words and are dropped.
    @([regex]::Matches($CommandLine, '(?:"(?:\\.|[^"\\])*"|[^\s"])+') | ForEach-Object { $_.Value.Trim('"') })
}

function Get-PermissionFlags([string]$CommandLine) {
    # The hook input has no permission mode, so keep the permission flags claude was launched with. Only whole
    # arguments count: in claude "what does --dangerously-skip-permissions do?" the flag is just text in the prompt.
    $arguments = @(Split-CommandLine $CommandLine)
    # The first word is the program itself.
    $flags = for ($i = 1; $i -lt $arguments.Count; $i++) {
        $argument = $arguments[$i]
        if ($argument -in '--dangerously-skip-permissions', '--allow-dangerously-skip-permissions') { $argument }
        elseif ($argument -eq '--permission-mode' -and $i + 1 -lt $arguments.Count -and
            $arguments[$i + 1] -in $script:PermissionModes) {
            "--permission-mode $($arguments[++$i])"
        }
        elseif ($argument -match '^--permission-mode=(.+)$' -and $Matches[1] -in $script:PermissionModes) {
            "--permission-mode $($Matches[1])"
        }
    }
    @($flags) -join ' '
}

function Register-Session($Hook, [string]$DataDir, [long]$HookStarted) {
    if (-not (Test-InteractiveSession) -or -not $Hook.cwd) { return }
    $claude = if ($env:CLAUDE_PID) { Get-Process -Id $env:CLAUDE_PID -ErrorAction SilentlyContinue }
    # Without the PID, restore can't tell whether the session is still running and would open it twice.
    if (-not $claude) { return }
    $processes = Get-ProcessTable
    $process = $processes[$claude.Id]
    if (-not $process) { return }
    $shell = Find-LaunchShell $processes $process
    if (-not $shell) { return }

    $entry = [ordered]@{
        sessionId   = $Hook.session_id
        cwd         = $Hook.cwd
        shell       = $shell
        flags       = Get-PermissionFlags $process.CommandLine
        transcript  = $Hook.transcript_path
        pid         = $claude.Id
        pidStarted  = $claude.StartTime.ToUniversalTime().ToString('o')
        source      = $Hook.source
        hookStarted = $HookStarted
    }
    # If claude already exited, its end hook has run too, so don't track it.
    $claude.Refresh()
    if ($claude.HasExited) { return }
    Write-SessionEntry $DataDir $entry
    Remove-SwitchedAwaySession $DataDir $entry
}

function Remove-SwitchedAwaySession([string]$DataDir, $Entry) {
    # A claude process runs one session at a time. When it switches to another (/branch, /resume, /clear), the
    # session it left goes, in case no end hook reported it. Start hooks run in the background and can finish out of
    # order, so the session whose hook started later is the one the process is on.
    $started = ConvertTo-UniversalTime $Entry.pidStarted
    $sameProcess = @(Get-SessionFiles $DataDir | Where-Object BaseName -ne $Entry.sessionId | ForEach-Object {
            $other = Read-SessionEntry $_.FullName
            if ($other.hookStarted -and $other.pid -eq $Entry.pid -and (ConvertTo-UniversalTime $other.pidStarted) -eq $started) {
                [pscustomobject]@{ File = $_.FullName; Entry = $other }
            }
        })
    if ($Entry.source -in $script:SessionSwitches) {
        $sameProcess | Where-Object { $_.Entry.hookStarted -lt $Entry.hookStarted } | ForEach-Object { Remove-SessionFile $_.File }
    }
    if ($sameProcess | Where-Object { $_.Entry.hookStarted -gt $Entry.hookStarted -and $_.Entry.source -in $script:SessionSwitches }) {
        Remove-SessionFile (Get-SessionFile $DataDir $Entry.sessionId)
    }
}

function Unregister-Session($Hook, [string]$DataDir) {
    if ($Hook.reason -in $script:DeliberateEnds) { Remove-SessionFile (Get-SessionFile $DataDir $Hook.session_id) }
}
