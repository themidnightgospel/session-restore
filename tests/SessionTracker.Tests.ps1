# Unit tests for scripts/SessionTracker.ps1. tracker.Tests.ps1 runs the hook end to end.
# Run with Pester 5 or later, from Windows PowerShell 5.1 or PowerShell 7.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\SessionTracker.ps1')

    # A fake process table for a chain of processes, outermost first, each started a minute after its parent. The
    # last one is claude.
    function New-ProcessChain([string[]]$Names) {
        $table = @{}
        $started = (Get-Date).AddHours(-1)
        for ($i = 0; $i -lt $Names.Count; $i++) {
            $table[100 + $i] = [pscustomobject]@{
                ProcessId = 100 + $i; ParentProcessId = 99 + $i; Name = $Names[$i]; CreationDate = $started.AddMinutes($i)
            }
        }
        $table
    }
}

Describe 'Find-LaunchShell' {
    It 'finds <Expected> for <Name>' -ForEach @(
        @{ Name = 'PowerShell 7'; Chain = 'explorer.exe', 'pwsh.exe', 'claude.exe'; Expected = 'pwsh' }
        @{ Name = 'Windows PowerShell'; Chain = 'explorer.exe', 'powershell.exe', 'claude.exe'; Expected = 'powershell' }
        @{ Name = 'cmd'; Chain = 'explorer.exe', 'cmd.exe', 'claude.exe'; Expected = 'cmd' }
        @{ Name = 'Git Bash'; Chain = 'explorer.exe', 'bash.exe', 'claude.exe'; Expected = 'bash' }
        @{ Name = 'a Windows Terminal profile running claude'; Chain = 'WindowsTerminal.exe', 'claude.exe'; Expected = 'pwsh' }
        @{ Name = 'a Scoop shim'; Chain = 'pwsh.exe', 'claude.exe', 'claude.exe'; Expected = 'pwsh' }
        @{ Name = 'a Volta shim'; Chain = 'cmd.exe', 'claude.exe', 'node.exe'; Expected = 'cmd' }
        @{ Name = 'a claude another program started'; Chain = 'pwsh.exe', 'someapp.exe', 'claude.exe'; Expected = $null }
        @{ Name = 'a shell more than three levels up'; Chain = 'pwsh.exe', 'claude.exe', 'claude.exe', 'claude.exe', 'claude.exe'; Expected = $null }
        @{ Name = 'a claude whose parent is gone'; Chain = @('claude.exe'); Expected = $null }
    ) {
        $table = New-ProcessChain $Chain
        $shell = Find-LaunchShell $table $table[99 + $Chain.Count]
        $shell | Should -Be $Expected
    }

    It 'ignores a "parent" started after claude, which reused a dead parent''s PID' {
        $table = New-ProcessChain 'pwsh.exe', 'claude.exe'
        $table[100].CreationDate = (Get-Date)
        $shell = Find-LaunchShell $table $table[101]
        $shell | Should -BeNullOrEmpty
    }
}

Describe 'Split-CommandLine' {
    It 'groups quoted words and drops the quotes' {
        Split-CommandLine '"C:\Program Files\claude.exe" -p "two words" x' | Should -Be @('C:\Program Files\claude.exe', '-p', 'two words', 'x')
    }
}

Describe 'Get-PermissionFlags' {
    It 'finds <Expected> in: <CommandLine>' -ForEach @(
        @{ CommandLine = '"C:\bin\claude.exe" --dangerously-skip-permissions'; Expected = '--dangerously-skip-permissions' }
        @{ CommandLine = 'claude --permission-mode plan'; Expected = '--permission-mode plan' }
        @{ CommandLine = 'claude --permission-mode=acceptEdits'; Expected = '--permission-mode acceptEdits' }
        @{ CommandLine = 'claude --permission-mode "plan"'; Expected = '--permission-mode plan' }
        @{ CommandLine = 'claude "--dangerously-skip-permissions"'; Expected = '--dangerously-skip-permissions' }
        @{ CommandLine = 'claude --allow-dangerously-skip-permissions --permission-mode auto'; Expected = '--allow-dangerously-skip-permissions --permission-mode auto' }
        @{ CommandLine = 'claude "what does --dangerously-skip-permissions do?"'; Expected = '' }
        @{ CommandLine = 'claude "explain --permission-mode to me"'; Expected = '' }
        @{ CommandLine = 'claude "say \"hi\" --dangerously-skip-permissions"'; Expected = '' }
        @{ CommandLine = 'claude --permission-mode bogus'; Expected = '' }
        @{ CommandLine = 'claude --permission-mode'; Expected = '' }
        @{ CommandLine = '--dangerously-skip-permissions'; Expected = '' }
        @{ CommandLine = ''; Expected = '' }
    ) {
        Get-PermissionFlags $CommandLine | Should -BeExactly $Expected
    }
}

Describe 'Test-InteractiveSession' {
    BeforeEach {
        $saved = @{ Entry = $env:CLAUDE_CODE_ENTRYPOINT; Kind = $env:CLAUDE_CODE_SESSION_KIND }
    }
    AfterEach {
        $env:CLAUDE_CODE_ENTRYPOINT = $saved.Entry
        $env:CLAUDE_CODE_SESSION_KIND = $saved.Kind
    }

    It 'is <Expected> for entrypoint "<Entry>" and session kind "<Kind>"' -ForEach @(
        @{ Entry = 'cli'; Kind = ''; Expected = $true }
        @{ Entry = 'sdk-cli'; Kind = ''; Expected = $false }
        @{ Entry = 'claude-vscode'; Kind = ''; Expected = $false }
        @{ Entry = ''; Kind = ''; Expected = $false }
        @{ Entry = 'cli'; Kind = 'bg'; Expected = $false }
        @{ Entry = 'cli'; Kind = 'daemon-worker'; Expected = $false }
    ) {
        $env:CLAUDE_CODE_ENTRYPOINT = $Entry
        $env:CLAUDE_CODE_SESSION_KIND = $Kind
        Test-InteractiveSession | Should -Be $Expected
    }
}

Describe 'Remove-SwitchedAwaySession' {
    BeforeAll {
        $script:data = Join-Path $TestDrive 'switch'
        function New-TrackedEntry([string]$Id, [string]$Source, [long]$HookStarted, [int]$ProcessId = 10) {
            $entry = [ordered]@{
                sessionId = $Id; cwd = 'C:\work'; pid = $ProcessId; pidStarted = '2026-01-01T10:00:00.0000000Z'
                source = $Source; hookStarted = $HookStarted
            }
            Write-SessionEntry $script:data $entry
            $entry
        }
        function Test-Tracked([string]$Id) { Test-Path -LiteralPath (Get-SessionFile $script:data $Id) }
    }
    BeforeEach { Remove-Item $script:data -Recurse -Force -ErrorAction SilentlyContinue }

    It 'drops the session a process left when it switches to another (<Source>)' -ForEach @(
        @{ Source = 'fork' }, @{ Source = 'resume' }, @{ Source = 'clear' }
    ) {
        New-TrackedEntry 'before' 'startup' 1 | Out-Null
        Remove-SwitchedAwaySession $script:data (New-TrackedEntry 'after' $Source 2)
        Test-Tracked 'before' | Should -BeFalse
        Test-Tracked 'after' | Should -BeTrue
    }

    It 'drops its own session when the process had already switched away from it' {
        # The hook for 'before' started first but finished last.
        New-TrackedEntry 'after' 'clear' 2 | Out-Null
        Remove-SwitchedAwaySession $script:data (New-TrackedEntry 'before' 'startup' 1)
        Test-Tracked 'before' | Should -BeFalse
        Test-Tracked 'after' | Should -BeTrue
    }

    It 'keeps both when a second session starts fresh in the same process' {
        New-TrackedEntry 'first' 'startup' 1 | Out-Null
        Remove-SwitchedAwaySession $script:data (New-TrackedEntry 'second' 'startup' 2)
        Test-Tracked 'first' | Should -BeTrue
        Test-Tracked 'second' | Should -BeTrue
    }

    It 'leaves sessions of other processes alone' {
        New-TrackedEntry 'other' 'startup' 1 -ProcessId 11 | Out-Null
        Remove-SwitchedAwaySession $script:data (New-TrackedEntry 'after' 'clear' 2)
        Test-Tracked 'other' | Should -BeTrue
    }

    It 'leaves entries recorded before hook start times were kept alone' {
        Write-SessionEntry $script:data ([ordered]@{ sessionId = 'old'; cwd = 'C:\work'; pid = 10; pidStarted = '2026-01-01T10:00:00.0000000Z' })
        Remove-SwitchedAwaySession $script:data (New-TrackedEntry 'after' 'clear' 2)
        Test-Tracked 'old' | Should -BeTrue
    }
}

Describe 'Unregister-Session' {
    BeforeAll { $script:data = Join-Path $TestDrive 'end' }
    BeforeEach { Write-SessionEntry $script:data ([ordered]@{ sessionId = 's1'; cwd = 'C:\work' }) }

    It 'stops tracking a session closed on purpose (<Reason>)' -ForEach @(
        @{ Reason = 'prompt_input_exit' }, @{ Reason = 'clear' }, @{ Reason = 'resume' }, @{ Reason = 'logout' }
    ) {
        Unregister-Session ([pscustomobject]@{ session_id = 's1'; reason = $Reason }) $script:data
        Test-Path (Get-SessionFile $script:data 's1') | Should -BeFalse
    }

    It 'keeps tracking a session that ended for reason <Reason>' -ForEach @(
        @{ Reason = 'other' }, @{ Reason = 'some_future_reason' }
    ) {
        Unregister-Session ([pscustomobject]@{ session_id = 's1'; reason = $Reason }) $script:data
        Test-Path (Get-SessionFile $script:data 's1') | Should -BeTrue
    }
}
