# Unit tests for skills/restore/scripts/SessionRestore.ps1. Opening tabs is mocked.
# Run with Pester 5 or later, from Windows PowerShell 5.1 or PowerShell 7.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\skills\restore\scripts\SessionRestore.ps1')

    $script:data = Join-Path $TestDrive 'data'
    $script:me = Get-Process -Id $PID
    $script:georgian = -join ([char[]](0x10E2, 0x10D4, 0x10E1, 0x10E2, 0x10D8))

    # Tracks a session the way the hook does and returns its entry file. Sessions are numbered in the order they're
    # created; -DaysAgo sets when it was last active.
    function New-Entry {
        param(
            [string]$Id,
            [string]$Cwd = $TestDrive,
            [string]$Shell = 'pwsh',
            [string]$Flags = '',
            [int]$DaysAgo = 0,
            [switch]$Running,
            [switch]$NoConversation
        )
        $transcript = Join-Path $TestDrive "$Id.jsonl"
        $lastActive = (Get-Date).AddDays(-$DaysAgo)
        if (-not $NoConversation) {
            Set-Content $transcript "{`"type`":`"ai-title`",`"aiTitle`":`"Title of $Id`"}"
            (Get-Item $transcript).LastWriteTime = $lastActive
        }
        Write-SessionEntry $script:data ([ordered]@{
                sessionId = $Id; cwd = $Cwd; shell = $Shell; flags = $Flags; transcript = $transcript
                pid = if ($Running) { $script:me.Id } else { 999999 }
                pidStarted = $script:me.StartTime.ToUniversalTime().ToString('o')
            })
        $file = Get-Item -LiteralPath (Get-SessionFile $script:data $Id)
        $file.CreationTime = (Get-Date).AddMinutes(-1000 + @(Get-SessionFiles $script:data).Count)
        $file.LastWriteTime = $lastActive
        $file.FullName
    }

    function Reset-Sessions { Remove-Item $script:data -Recurse -Force -ErrorAction SilentlyContinue }

    # The tracked sessions numbered as a fresh "list" numbers them: 1, 2, 3... most recently used first.
    function Get-NumberedSessions {
        $sessions = @(Get-TrackedSessions $script:data)
        Set-SessionNumbers $sessions @()
        $sessions
    }
}

Describe 'ConvertTo-RestoreRequest' {
    It 'reads "<Text>" as <Action> <Numbers>' -ForEach @(
        @{ Text = ''; Action = 'restore'; Numbers = @() }
        @{ Text = '   '; Action = 'restore'; Numbers = @() }
        @{ Text = 'list'; Action = 'list'; Numbers = @() }
        @{ Text = 'LIST'; Action = 'list'; Numbers = @() }
        @{ Text = 'all'; Action = 'all'; Numbers = @() }
        @{ Text = '1,3'; Action = 'restore'; Numbers = @(1, 3) }
        @{ Text = '1 3'; Action = 'restore'; Numbers = @(1, 3) }
        @{ Text = '#2'; Action = 'restore'; Numbers = @(2) }
        @{ Text = '1,1'; Action = 'restore'; Numbers = @(1) }
        @{ Text = '3 1 3'; Action = 'restore'; Numbers = @(3, 1) }
        @{ Text = '0'; Action = 'restore'; Numbers = @(0) }
        @{ Text = 'forget 0'; Action = 'forget'; Numbers = @(0) }
        @{ Text = 'forget 2'; Action = 'forget'; Numbers = @(2) }
        @{ Text = 'forget'; Action = 'help'; Numbers = @() }
        @{ Text = 'help'; Action = 'help'; Numbers = @() }
        @{ Text = 'please restore'; Action = 'help'; Numbers = @() }
    ) {
        $request = ConvertTo-RestoreRequest $Text
        $request.Action | Should -Be $Action
        $request.Numbers -join ',' | Should -Be ($Numbers -join ',')
    }
}

Describe 'Get-SessionTitle' {
    It 'prefers the /rename title over the automatic one' {
        $file = Join-Path $TestDrive 'titles.jsonl'
        Set-Content $file @(
            '{"type":"custom-title","customTitle":"Old name"}'
            '{"type":"ai-title","aiTitle":"Automatic"}'
            '{"type":"custom-title","customTitle":"My name"}'
            '{"type":"user","message":"{\"type\":\"custom-title\",\"customTitle\":\"not a title line\"}"}'
        )
        Get-SessionTitle $file | Should -Be 'My name'
    }

    It 'falls back to the automatic title, with Windows line endings too' {
        $file = Join-Path $TestDrive 'ai.jsonl'
        [IO.File]::WriteAllText($file, "{`"type`":`"user`"}`r`n{`"type`":`"ai-title`",`"aiTitle`":`"Automatic`"}`r`n")
        Get-SessionTitle $file | Should -Be 'Automatic'
    }

    It 'reads only the end of a large transcript' {
        $file = Join-Path $TestDrive 'big.jsonl'
        $writer = [IO.StreamWriter]::new($file)
        $writer.WriteLine('{"type":"custom-title","customTitle":"Too far back"}')
        $filler = '{"type":"user","text":"' + ('x' * 1000) + '"}'
        for ($i = 0; $i -lt 2000; $i++) { $writer.WriteLine($filler) }
        $writer.WriteLine('{"type":"ai-title","aiTitle":"Recent"}')
        $writer.Close()
        Get-SessionTitle $file | Should -Be 'Recent'
    }

    It 'returns nothing for a missing or titleless transcript' {
        Get-SessionTitle (Join-Path $TestDrive 'missing.jsonl') | Should -BeNullOrEmpty
        $file = Join-Path $TestDrive 'plain.jsonl'
        Set-Content $file '{"type":"user"}'
        Get-SessionTitle $file | Should -BeNullOrEmpty
    }
}

Describe 'Test-SessionRunning' {
    BeforeAll {
        $started = $script:me.StartTime.ToUniversalTime().ToString('o')
    }

    It 'is true while the claude process that recorded the session runs' {
        Test-SessionRunning ([pscustomobject]@{ sessionId = 'abc-1'; pid = $script:me.Id; pidStarted = $started }) @() | Should -BeTrue
    }

    It 'is false once its PID belongs to a process started at another time' {
        $reused = $script:me.StartTime.AddMinutes(-5).ToUniversalTime().ToString('o')
        Test-SessionRunning ([pscustomobject]@{ sessionId = 'abc-1'; pid = $script:me.Id; pidStarted = $reused }) @() | Should -BeFalse
    }

    It 'is true while a claude resumes it: <CommandLine>' -ForEach @(
        @{ CommandLine = '"C:\bin\claude.exe" --resume abc-1 --dangerously-skip-permissions' }
        @{ CommandLine = 'claude -r abc-1' }
        @{ CommandLine = 'claude --resume=abc-1' }
        @{ CommandLine = 'claude --resume "abc-1"' }
    ) {
        Test-SessionRunning ([pscustomobject]@{ sessionId = 'abc-1'; pid = 999999 }) @($CommandLine) | Should -BeTrue
    }

    It 'is false for a claude resuming another session: <CommandLine>' -ForEach @(
        @{ CommandLine = 'claude --resume abc-12' }
        @{ CommandLine = 'claude --resume xabc-1' }
        @{ CommandLine = 'claude abc-1' }
        @{ CommandLine = 'claude --resume' }
    ) {
        Test-SessionRunning ([pscustomobject]@{ sessionId = 'abc-1'; pid = 999999 }) @($CommandLine) | Should -BeFalse
    }
}

Describe 'Get-ResumingCommandLines' {
    It 'sees a claude resuming a session, but not a shell that mentions one' {
        Copy-Item (Join-Path $env:SystemRoot 'System32\cmd.exe') (Join-Path $TestDrive 'claude.exe') -Force
        $claude = Start-Process (Join-Path $TestDrive 'claude.exe') -ArgumentList '/c', 'ping -n 60 127.0.0.1 >nul & rem --resume being-resumed' -WindowStyle Hidden -PassThru
        $shell = Start-Process cmd.exe -ArgumentList '/c', 'ping -n 60 127.0.0.1 >nul & rem claude --resume other' -WindowStyle Hidden -PassThru
        try {
            Start-Sleep -Milliseconds 500
            # @(): with a single command line, -match would answer true or false instead of filtering.
            $lines = @(Get-ResumingCommandLines)
            $lines -match 'being-resumed' | Should -Not -BeNullOrEmpty
            $lines -match 'resume other' | Should -BeNullOrEmpty
        }
        finally { foreach ($id in $claude.Id, $shell.Id) { taskkill /PID $id /T /F 2>&1 | Out-Null } }
    }
}

Describe 'Get-TrackedSessions' {
    BeforeEach { Reset-Sessions }

    It 'returns sessions in the order they were opened and tells open from closed' {
        New-Entry 'first' -Running | Out-Null
        New-Entry 'second' | Out-Null
        $sessions = @(Get-TrackedSessions $script:data)
        $sessions.SessionId | Should -Be @('first', 'second')
        $sessions.Running | Should -Be @($true, $false)
        $sessions[0].Title | Should -Be 'Title of first'
    }

    It 'marks closed entries unused for over 30 days as expired' {
        New-Entry 'old' -DaysAgo 40 | Out-Null
        New-Entry 'recent' -DaysAgo 10 | Out-Null
        (Get-TrackedSessions $script:data).Expired | Should -Be @($true, $false)
    }

    It 'dates a session with no conversation by its entry' {
        New-Entry 'blank' -NoConversation -DaysAgo 3 | Out-Null
        $session = Get-TrackedSessions $script:data
        $session.HasTranscript | Should -BeFalse
        $session.LastActive.Date | Should -Be (Get-Date).AddDays(-3).Date
    }

    It 'skips damaged entries with a warning' {
        New-Entry 'good' | Out-Null
        Set-Content (Join-Path $script:data 'sessions\half.json') '{"sessionId": "trunc'
        $sessions = @(Get-TrackedSessions $script:data -WarningVariable problems -WarningAction SilentlyContinue)
        $sessions.SessionId | Should -Be @('good')
        $problems.Count | Should -Be 1
    }

    It 'keeps non-ASCII folder names' {
        New-Entry 'unicode' -Cwd "C:\work\$georgian" | Out-Null
        (Get-TrackedSessions $script:data).Folder | Should -Be $georgian
    }

    It 'reads a data folder whose path has brackets' {
        $source = New-Entry 'bracketed'
        $folder = Join-Path $TestDrive 'user[1]'
        [void][IO.Directory]::CreateDirectory((Join-Path $folder 'sessions'))
        [IO.File]::Copy($source, (Join-Path $folder 'sessions\bracketed.json'), $true)
        (Get-TrackedSessions $folder).SessionId | Should -Be 'bracketed'
    }
}

Describe 'Save-ListedSessionIds and Get-ListedSessionIds' {
    It 'round-trip <Name>' -ForEach @(
        @{ Name = 'several IDs in order'; Ids = @('id-c', 'id-a', 'id-b') }
        @{ Name = 'a single ID'; Ids = @('id-a') }
        @{ Name = 'no IDs'; Ids = @() }
    ) {
        $folder = Join-Path $TestDrive 'listed'
        Save-ListedSessionIds $folder $Ids
        $read = @(Get-ListedSessionIds $folder)
        $read.Count | Should -Be $Ids.Count
        $read -join '|' | Should -BeExactly ($Ids -join '|')
    }

    It 'reads nothing before the first list' {
        @(Get-ListedSessionIds (Join-Path $TestDrive 'never-listed')).Count | Should -Be 0
    }
}

Describe 'Set-SessionNumbers' {
    BeforeEach { Reset-Sessions }

    It 'numbers sessions 1, 2, 3... most recently used first' {
        New-Entry 'middle' -DaysAgo 2 | Out-Null
        New-Entry 'newest' -DaysAgo 1 | Out-Null
        New-Entry 'oldest' -DaysAgo 3 | Out-Null
        $sessions = @(Get-NumberedSessions)
        ($sessions | Sort-Object Number).SessionId | Should -Be @('newest', 'middle', 'oldest')
        ($sessions | Sort-Object Number).Number | Should -Be @(1, 2, 3)
    }

    It 'keeps the numbers of the last list and numbers sessions it did not show after them' {
        New-Entry 'b' -DaysAgo 1 | Out-Null
        New-Entry 'new' | Out-Null
        $sessions = @(Get-TrackedSessions $script:data)
        # The list showed a session that is gone since, then 'b'.
        Set-SessionNumbers $sessions @('gone', 'b')
        ($sessions | Where-Object SessionId -eq 'b').Number | Should -Be 2
        ($sessions | Where-Object SessionId -eq 'new').Number | Should -Be 3
    }
}

Describe 'Show-TrackedSessions' {
    BeforeEach { Reset-Sessions }

    It 'lists full folders in number order' {
        New-Entry 'older' -DaysAgo 3 | Out-Null
        New-Entry 'newer' -DaysAgo 1 | Out-Null
        $text = Show-TrackedSessions (Get-NumberedSessions) | Out-String -Width 300
        $rows = @($text -split "`n" | Where-Object { $_ -match 'Title of' })
        $rows[0] | Should -Match ('^\s*1\s+' + [regex]::Escape($TestDrive) + '\s.*Title of newer.*closed')
        $rows[1] | Should -Match '^\s*2\s.*Title of older'
    }
}

Describe 'Remove-TrackedSessions' {
    BeforeEach { Reset-Sessions }

    It 'forgets each numbered session and reports unknown numbers' {
        $one = New-Entry 'one' -DaysAgo 1
        $two = New-Entry 'two' -DaysAgo 2
        $keep = New-Entry 'keep' -DaysAgo 3
        $text = (Remove-TrackedSessions (Get-NumberedSessions) 1, 2, 9) -join "`n"
        $text | Should -Match 'Forgot #1 .*Title of one'
        $text | Should -Match 'Forgot #2 .*Title of two'
        $text | Should -Match 'There is no session #9'
        Test-Path $one, $two, $keep | Should -Be @($false, $false, $true)
    }
}

Describe 'Select-SessionsToRestore' {
    BeforeAll {
        Reset-Sessions
        New-Entry 'open' -Running | Out-Null
        New-Entry 'recent' -DaysAgo 1 | Out-Null
        New-Entry 'stale' -DaysAgo 10 | Out-Null
        $sessions = @(Get-NumberedSessions)
    }

    It 'picks closed sessions used in the last 7 days and notes the older ones' {
        $selection = Select-SessionsToRestore $sessions (ConvertTo-RestoreRequest '')
        $selection.Sessions.SessionId | Should -Be @('recent')
        $selection.Notes | Should -Match 'Skipped 1 session\(s\) unused for over 7 days'
    }

    It 'picks every closed session with "all"' {
        (Select-SessionsToRestore $sessions (ConvertTo-RestoreRequest 'all')).Sessions.SessionId | Should -Be @('recent', 'stale')
    }

    It 'picks the chosen numbers, whatever their age' {
        $selection = Select-SessionsToRestore $sessions (ConvertTo-RestoreRequest '3')
        $selection.Sessions.SessionId | Should -Be @('stale')
        $selection.Notes | Should -BeNullOrEmpty
    }

    It 'explains numbers that are open or unknown, 0 included' {
        $selection = Select-SessionsToRestore $sessions (ConvertTo-RestoreRequest '1,0,9')
        $selection.Sessions | Should -BeNullOrEmpty
        $selection.Notes -join "`n" | Should -Match '#1 .* is already open'
        $selection.Notes -join "`n" | Should -Match 'There is no session #0'
        $selection.Notes -join "`n" | Should -Match 'There is no session #9'
    }
}

Describe 'Get-TabCommand' {
    BeforeAll {
        $session = [pscustomobject]@{ SessionId = 'abc'; HasTranscript = $true; Flags = '--dangerously-skip-permissions'; Shell = 'pwsh'; Cwd = 'C:\work' }
        $resume = "Set-Location -LiteralPath 'C:\work'; claude --resume abc --dangerously-skip-permissions"
    }

    It 'reopens <Shell> sessions in <Expected>' -ForEach @(
        @{ Shell = 'powershell'; HasPwsh = $true; Expected = 'powershell' }
        @{ Shell = 'pwsh'; HasPwsh = $true; Expected = 'pwsh' }
        @{ Shell = 'bash'; HasPwsh = $true; Expected = 'pwsh' }
        @{ Shell = 'pwsh'; HasPwsh = $false; Expected = 'powershell' }
        @{ Shell = $null; HasPwsh = $true; Expected = 'pwsh' }
    ) {
        $session.Shell = $Shell
        (Get-TabCommand $session $HasPwsh) -join '|' | Should -BeExactly "$Expected|-NoExit|-Command|$resume"
    }

    It 'reopens cmd sessions in cmd' {
        $session.Shell = 'cmd'
        (Get-TabCommand $session $true) -join '|' | Should -BeExactly 'cmd|/k|claude --resume abc --dangerously-skip-permissions'
    }

    It 'quotes a folder <Name> so PowerShell changes to exactly that folder' -ForEach @(
        @{ Name = 'with an apostrophe'; Folder = "C:\it's here" }
        @{ Name = 'with curly quotes'; Folder = 'C:\Bob' + [char]0x2019 + 's ' + [char]0x2018 + 'project' + [char]0x2019 }
        @{ Name = 'with a dollar sign'; Folder = 'C:\$env:TEMP' }
    ) {
        $quoted = [pscustomobject]@{ SessionId = 'abc'; HasTranscript = $true; Flags = ''; Shell = 'pwsh'; Cwd = $Folder }
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput((Get-TabCommand $quoted $true)[-1], [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
        $location = $ast.Find({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
                $node.StringConstantType -eq 'SingleQuoted' }, $true)
        $location.Value | Should -BeExactly $Folder
    }

    It 'starts a fresh claude when there is no conversation to resume' {
        $fresh = [pscustomobject]@{ SessionId = 'abc'; HasTranscript = $false; Flags = ''; Shell = 'cmd'; Cwd = 'C:\work' }
        (Get-TabCommand $fresh $true) -join '|' | Should -BeExactly 'cmd|/k|claude'
    }
}

Describe 'ConvertTo-CommandLine' {
    It 'quotes <Argument> as <Expected>' -ForEach @(
        @{ Argument = 'plain'; Expected = 'plain' }
        @{ Argument = 'C:\My Folder'; Expected = '"C:\My Folder"' }
        @{ Argument = 'C:\My Folder\'; Expected = '"C:\My Folder\\"' }
        @{ Argument = 'say "hi"'; Expected = '"say \"hi\""' }
        @{ Argument = 'a\"b'; Expected = '"a\\\"b"' }
        @{ Argument = ''; Expected = '""' }
    ) {
        ConvertTo-CommandLine @($Argument) | Should -BeExactly $Expected
    }

    It 'joins arguments with spaces' {
        ConvertTo-CommandLine @('-d', 'C:\a b', 'cmd') | Should -BeExactly '-d "C:\a b" cmd'
    }
}

Describe 'New-TabStartInfo' {
    BeforeAll {
        $session = [pscustomobject]@{ Folder = 'my;app'; Cwd = 'C:\a b\' }
        $command = @('pwsh', '-NoExit', '-Command', "Set-Location -LiteralPath 'C:\a b\'; claude")
        $env:SESSION_RESTORE_TEST_ONLY = '1'
    }
    AfterAll { Remove-Item env:SESSION_RESTORE_TEST_ONLY }

    It 'builds the Windows Terminal command line' {
        $info = New-TabStartInfo $session $command @{ Path = 'C:\x' } 'C:\wt.exe'
        $info.FileName | Should -Be 'C:\wt.exe'
        $info.Arguments | Should -BeExactly ('-w 0 new-tab --title my\;app -d "C:\a b\\" pwsh -NoExit -Command ' +
            '"Set-Location -LiteralPath ''C:\a b\''\; claude"')
    }

    It 'falls back to a console window through cmd start' {
        $info = New-TabStartInfo $session $command @{ Path = 'C:\x' } ''
        $info.FileName | Should -Match 'cmd\.exe$'
        $info.Arguments | Should -BeExactly ('/c start "my;app" /d "C:\a b\" pwsh -NoExit -Command ' +
            '"Set-Location -LiteralPath ''C:\a b\''; claude"')
    }

    It 'gives the tab only the environment it is handed' {
        $info = New-TabStartInfo $session $command @{ Path = 'C:\x'; USERPROFILE = 'C:\u' } 'C:\wt.exe'
        $info.UseShellExecute | Should -BeFalse
        $info.EnvironmentVariables.Count | Should -Be 2
        $info.EnvironmentVariables['Path'] | Should -Be 'C:\x'
        $info.EnvironmentVariables.ContainsKey('SESSION_RESTORE_TEST_ONLY') | Should -BeFalse
    }
}

Describe 'Open-SessionTabs' {
    BeforeAll {
        Mock Start-SessionTab {}
        Mock Start-Sleep {}
        Mock Get-LoginEnvironment { @{ Path = 'C:\Windows' } }
    }
    BeforeEach { Reset-Sessions }

    It 'opens each session in the shell it was started from, with the login environment' {
        New-Entry 'fromcmd' -Shell cmd -Flags '--dangerously-skip-permissions' | Out-Null
        $result = Open-SessionTabs (Get-TrackedSessions $script:data)
        $result.Opened.SessionId | Should -Be 'fromcmd'
        Should -Invoke Start-SessionTab -Times 1 -Exactly -ParameterFilter {
            ($ShellCommand -join '|') -eq 'cmd|/k|claude --resume fromcmd --dangerously-skip-permissions' -and
            $Environment.Path -eq 'C:\Windows'
        }
    }

    It 'starts a fresh claude for a session with no conversation and drops its entry' {
        $file = New-Entry 'blank' -NoConversation
        Open-SessionTabs (Get-TrackedSessions $script:data) | Out-Null
        Should -Invoke Start-SessionTab -Times 1 -Exactly -ParameterFilter { $ShellCommand[-1] -match '; claude$' }
        Test-Path $file | Should -BeFalse
    }

    It 'skips a session whose folder is gone' {
        New-Entry 'moved' -Cwd (Join-Path $TestDrive 'deleted-folder') | Out-Null
        $result = Open-SessionTabs (Get-TrackedSessions $script:data)
        $result.Opened | Should -BeNullOrEmpty
        $result.Notes | Should -Match "can't be found"
        Should -Invoke Start-SessionTab -Times 0 -Exactly
    }

    It 'notes a tab that failed to open and opens the rest' {
        Mock Start-SessionTab { throw 'no terminal' } -ParameterFilter { $Session.SessionId -eq 'broken' }
        New-Entry 'broken' -DaysAgo 1 | Out-Null
        New-Entry 'fine' | Out-Null
        $result = Open-SessionTabs (Get-NumberedSessions)
        $result.Opened.SessionId | Should -Be 'fine'
        $result.Notes | Should -Match "Couldn't open #2 .*no terminal"
    }

    It 'does nothing for no sessions' {
        $result = Open-SessionTabs @()
        $result.Opened | Should -BeNullOrEmpty
        Should -Invoke Get-LoginEnvironment -Times 0 -Exactly
    }
}

Describe 'Invoke-SessionRestore' {
    BeforeAll {
        Mock Start-SessionTab {}
        Mock Start-Sleep {}
        Mock Get-LoginEnvironment { @{ Path = 'C:\Windows' } }
    }
    BeforeEach { Reset-Sessions }

    It 'says so when nothing is tracked yet' {
        Invoke-SessionRestore $script:data '' | Should -Match 'No tracked sessions yet'
    }

    It 'shows usage for unknown arguments' {
        (Invoke-SessionRestore $script:data 'bogus') -join "`n" | Should -Match 'Usage:'
    }

    It 'drops expired entries' {
        $old = New-Entry 'old' -DaysAgo 40
        New-Entry 'recent' -Running | Out-Null
        Invoke-SessionRestore $script:data 'list' | Out-Null
        Test-Path $old | Should -BeFalse
    }

    It 'reopens the closed sessions and lists them' {
        New-Entry 'open' -Running | Out-Null
        New-Entry 'recent' -DaysAgo 1 | Out-Null
        New-Entry 'stale' -DaysAgo 10 | Out-Null
        $text = (Invoke-SessionRestore $script:data '') -join "`n"
        Should -Invoke Start-SessionTab -Times 1 -Exactly
        $text | Should -Match 'Reopened 1 session\(s\) in new tabs:\s+#2 '
        $text | Should -Match 'Skipped 1 session'
    }

    It 'says when every session is still open' {
        New-Entry 'open' -Running | Out-Null
        Invoke-SessionRestore $script:data '' | Should -Match 'every tracked session is still open'
    }

    It 'numbers the list 1, 2, 3... and keeps those numbers after other sessions are used' {
        New-Entry 'a' -DaysAgo 2 | Out-Null
        New-Entry 'b' -DaysAgo 1 | Out-Null
        $rows = @((Invoke-SessionRestore $script:data 'list' | Out-String -Width 300) -split "`n" | Where-Object { $_ -match 'Title of' })
        $rows[0] | Should -Match '^\s*1\s.*Title of b'
        $rows[1] | Should -Match '^\s*2\s.*Title of a'
        # 'a' is used again, so it's now the most recent; #1 must still mean 'b' and #2 'a'.
        (Get-Item (Join-Path $TestDrive 'a.jsonl')).LastWriteTime = Get-Date
        (Invoke-SessionRestore $script:data 'forget 1') -join "`n" | Should -Match 'Forgot #1 .*Title of b'
        (Invoke-SessionRestore $script:data 'forget 2') -join "`n" | Should -Match 'Forgot #2 .*Title of a'
    }

    It 'reopens by the numbers the list showed' {
        New-Entry 'older' -DaysAgo 2 | Out-Null
        New-Entry 'newer' -DaysAgo 1 | Out-Null
        Invoke-SessionRestore $script:data 'list' | Out-Null
        (Invoke-SessionRestore $script:data '1') -join "`n" | Should -Match 'Reopened 1 session\(s\) in new tabs:\s+#1 .*Title of newer'
        Should -Invoke Start-SessionTab -Times 1 -Exactly -ParameterFilter { $Session.SessionId -eq 'newer' }
    }

    It 'says when nothing was reopened' {
        New-Entry 'stale' -DaysAgo 10 | Out-Null
        (Invoke-SessionRestore $script:data '') -join "`n" | Should -Match 'Nothing reopened'
    }
}

Describe 'Get-LoginEnvironment' {
    It 'returns the user login environment without variables set only in this process' {
        $env:SESSION_RESTORE_TEST_ONLY = '1'
        try {
            $environment = Get-LoginEnvironment
            $environment['SystemRoot'] | Should -Not -BeNullOrEmpty
            $environment['USERPROFILE'] | Should -Be $env:USERPROFILE
            $environment['Path'] | Should -Not -BeNullOrEmpty
            $environment.ContainsKey('SESSION_RESTORE_TEST_ONLY') | Should -BeFalse
        }
        finally { Remove-Item env:SESSION_RESTORE_TEST_ONLY }
    }
}
