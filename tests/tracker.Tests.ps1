# Runs scripts/tracker.ps1 the way Claude Code does: a powershell.exe process with the hook input on stdin.
# SessionTracker.Tests.ps1 covers the logic case by case; these tests check the hook end to end.
# Run with Pester 5 or later, from Windows PowerShell 5.1 or PowerShell 7.

BeforeAll {
    $script:tracker = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\tracker.ps1')).Path
    $script:data = Join-Path $TestDrive 'data'
    $script:sessions = Join-Path $script:data 'sessions'
    $script:testShell = (Get-Process -Id $PID).ProcessName

    # Stand-in for claude.exe, started from this test shell with a permission flag on its command line. It lives
    # until AfterAll stops it.
    $script:claude = Start-Process cmd.exe -ArgumentList '/c', 'ping -n 3600 127.0.0.1 >nul & rem --dangerously-skip-permissions' -WindowStyle Hidden -PassThru
    # A process no shell started (WMI starts it), like claude launched by some other program.
    $script:noShell = (Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = 'ping -n 3600 127.0.0.1' }).ProcessId

    function Invoke-Tracker([string]$HookEvent, [hashtable]$Hook, [hashtable]$Environment = @{}) {
        $info = New-Object Diagnostics.ProcessStartInfo 'powershell.exe', "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script:tracker`" $HookEvent"
        $info.UseShellExecute = $false
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        foreach ($name in 'CLAUDE_PID', 'CLAUDE_CODE_SESSION_KIND') { $info.EnvironmentVariables.Remove($name) }
        $info.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $script:data
        $info.EnvironmentVariables['CLAUDE_CODE_ENTRYPOINT'] = 'cli'
        $info.EnvironmentVariables['CLAUDE_PID'] = [string]$script:claude.Id
        foreach ($name in $Environment.Keys) {
            if ($null -eq $Environment[$name]) { $info.EnvironmentVariables.Remove($name) }
            else { $info.EnvironmentVariables[$name] = [string]$Environment[$name] }
        }
        $process = [Diagnostics.Process]::Start($info)
        # Write UTF-8 bytes, the way Claude Code sends hook input.
        $bytes = (New-Object Text.UTF8Encoding $false).GetBytes(($Hook | ConvertTo-Json -Compress))
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.Close()
        $errors = $process.StandardError.ReadToEnd()
        [void]$process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        [pscustomobject]@{ ExitCode = $process.ExitCode; Errors = $errors }
    }

    function Get-Entry([string]$SessionId, [string]$Sessions = $script:sessions) {
        $file = Join-Path $Sessions "$SessionId.json"
        if ([IO.File]::Exists($file)) { [IO.File]::ReadAllText($file) | ConvertFrom-Json }
    }

    function New-StartHook([string]$SessionId = 's1', [string]$Cwd = 'C:\work\app', [string]$Source = 'startup') {
        @{ session_id = $SessionId; cwd = $Cwd; transcript_path = 'C:\t.jsonl'; hook_event_name = 'SessionStart'; source = $Source }
    }
}

AfterAll {
    # /T also stops the ping inside the stand-in.
    foreach ($id in $script:claude.Id, $script:noShell) { taskkill /PID $id /T /F 2>&1 | Out-Null }
}

Describe 'tracker.ps1 start' {
    BeforeEach { Remove-Item $script:sessions -Recurse -Force -ErrorAction SilentlyContinue }

    It 'records an interactive session: its folder (non-ASCII too), shell, permission flags and process' {
        $georgian = -join ([char[]](0x10E2, 0x10D4, 0x10E1, 0x10E2, 0x10D8))
        $result = Invoke-Tracker start (New-StartHook -Cwd "C:\work\$georgian")
        $result.ExitCode | Should -Be 0
        $result.Errors | Should -BeNullOrEmpty
        $entry = Get-Entry 's1'
        $entry.cwd | Should -Be "C:\work\$georgian"
        $entry.shell | Should -Be $script:testShell
        $entry.flags | Should -Be '--dangerously-skip-permissions'
        $entry.transcript | Should -Be 'C:\t.jsonl'
        $entry.pid | Should -Be $script:claude.Id
        $entry.source | Should -Be 'startup'
        $entry.hookStarted | Should -BeGreaterThan 0
    }

    It 'ignores <Name>' -ForEach @(
        @{ Name = 'a non-interactive session'; Environment = @{ CLAUDE_CODE_ENTRYPOINT = 'sdk-cli' } }
        @{ Name = 'a session without CLAUDE_PID'; Environment = @{ CLAUDE_PID = $null } }
        @{ Name = 'a claude whose PID is gone'; Environment = @{ CLAUDE_PID = '999999' } }
    ) {
        $result = Invoke-Tracker start (New-StartHook) $Environment
        $result.ExitCode | Should -Be 0
        Get-Entry 's1' | Should -BeNullOrEmpty
    }

    It 'ignores a claude that no shell started' {
        Invoke-Tracker start (New-StartHook) @{ CLAUDE_PID = $script:noShell } | Out-Null
        Get-Entry 's1' | Should -BeNullOrEmpty
    }

    It 'skips a session without a folder' {
        Invoke-Tracker start (New-StartHook -Cwd '') | Out-Null
        Get-Entry 's1' | Should -BeNullOrEmpty
    }

    It 'refuses a session ID that is not a plain file name' {
        $result = Invoke-Tracker start (New-StartHook -SessionId '..\evil')
        $result.ExitCode | Should -Be 0
        Test-Path $script:sessions | Should -BeFalse
    }

    It 'drops the session its process switched away from' {
        Invoke-Tracker start (New-StartHook -SessionId 'before') | Out-Null
        Invoke-Tracker start (New-StartHook -SessionId 'after' -Source 'clear') | Out-Null
        Get-Entry 'before' | Should -BeNullOrEmpty
        Get-Entry 'after' | Should -Not -BeNullOrEmpty
    }

    It 'works with brackets in the data folder path' {
        $bracketed = Join-Path $TestDrive 'user[1]'
        Invoke-Tracker start (New-StartHook -SessionId 'before') @{ CLAUDE_PLUGIN_DATA = $bracketed } | Out-Null
        $result = Invoke-Tracker start (New-StartHook -SessionId 'after' -Source 'clear') @{ CLAUDE_PLUGIN_DATA = $bracketed }
        $result.Errors | Should -BeNullOrEmpty
        Get-Entry 'before' (Join-Path $bracketed 'sessions') | Should -BeNullOrEmpty
        Get-Entry 'after' (Join-Path $bracketed 'sessions') | Should -Not -BeNullOrEmpty
    }

    It 'does nothing without CLAUDE_PLUGIN_DATA' {
        $result = Invoke-Tracker start (New-StartHook) @{ CLAUDE_PLUGIN_DATA = $null }
        $result.ExitCode | Should -Be 0
        Test-Path $script:sessions | Should -BeFalse
    }
}

Describe 'tracker.ps1 end' {
    BeforeEach {
        Remove-Item $script:sessions -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-Tracker start (New-StartHook) | Out-Null
    }

    It 'stops tracking a session closed on purpose' {
        $result = Invoke-Tracker end @{ session_id = 's1'; reason = 'prompt_input_exit'; hook_event_name = 'SessionEnd' }
        $result.ExitCode | Should -Be 0
        Get-Entry 's1' | Should -BeNullOrEmpty
    }

    It 'keeps tracking a session whose window was closed' {
        Invoke-Tracker end @{ session_id = 's1'; reason = 'other'; hook_event_name = 'SessionEnd' } | Out-Null
        Get-Entry 's1' | Should -Not -BeNullOrEmpty
    }

    It 'is quiet about a session it never tracked' {
        $result = Invoke-Tracker end @{ session_id = 'unknown'; reason = 'prompt_input_exit'; hook_event_name = 'SessionEnd' }
        $result.ExitCode | Should -Be 0
        $result.Errors | Should -BeNullOrEmpty
    }
}
