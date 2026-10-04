# Tests scripts/SessionStore.ps1. Run with Pester 5 or later, from Windows PowerShell 5.1 or PowerShell 7.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\SessionStore.ps1')
    $script:georgian = -join ([char[]](0x10E2, 0x10D4, 0x10E1, 0x10E2, 0x10D8))
}

Describe 'Test-SessionId' {
    It 'accepts <Id>' -ForEach @(
        @{ Id = '3522f2ce-4769-40e5-b98e-145a09c592df' }
        @{ Id = 's1' }
    ) {
        Test-SessionId $Id | Should -BeTrue
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a path'; Id = '..\evil' }
        @{ Name = 'spaces'; Id = 'a b' }
        @{ Name = 'an empty ID'; Id = '' }
        @{ Name = 'a missing ID'; Id = $null }
    ) {
        Test-SessionId $Id | Should -BeFalse
    }
}

Describe 'Write-SessionEntry and Read-SessionEntry' {
    It 'round-trip an entry, non-ASCII folder included' {
        $data = Join-Path $TestDrive 'roundtrip'
        Write-SessionEntry $data ([ordered]@{ sessionId = 's1'; cwd = "C:\work\$georgian"; shell = 'cmd' })
        $entry = Read-SessionEntry (Get-SessionFile $data 's1')
        $entry.cwd | Should -Be "C:\work\$georgian"
        $entry.shell | Should -Be 'cmd'
    }

    It 'write UTF-8 without a byte order mark' {
        $data = Join-Path $TestDrive 'nobom'
        Write-SessionEntry $data ([ordered]@{ sessionId = 's1'; cwd = 'C:\work' })
        [IO.File]::ReadAllBytes((Get-SessionFile $data 's1'))[0] | Should -Be ([byte][char]'{')
    }

    It 'write into a data folder whose path has brackets' {
        $data = Join-Path $TestDrive 'user[1]'
        Write-SessionEntry $data ([ordered]@{ sessionId = 's1'; cwd = 'C:\work' })
        (Read-SessionEntry (Get-SessionFile $data 's1')).cwd | Should -Be 'C:\work'
    }

    It 'read nothing from <Name>' -ForEach @(
        @{ Name = 'a half-written file'; Content = '{"sessionId": "trunc' }
        @{ Name = 'an empty file'; Content = '' }
        @{ Name = 'an entry without a folder'; Content = '{"sessionId":"s1"}' }
        @{ Name = 'an entry with a path for an ID'; Content = '{"sessionId":"..\\x","cwd":"C:\\work"}' }
    ) {
        $file = Join-Path $TestDrive 'bad.json'
        [IO.File]::WriteAllText($file, $Content)
        Read-SessionEntry $file | Should -BeNullOrEmpty
    }

    It 'read nothing from a missing file' {
        Read-SessionEntry (Join-Path $TestDrive 'missing.json') | Should -BeNullOrEmpty
    }
}

Describe 'Get-SessionFiles' {
    It 'lists entries oldest first' {
        $data = Join-Path $TestDrive 'order'
        foreach ($id in 'b', 'a', 'c') { Write-SessionEntry $data ([ordered]@{ sessionId = $id; cwd = 'C:\work' }) }
        (Get-Item (Get-SessionFile $data 'b')).CreationTime = (Get-Date).AddMinutes(-3)
        (Get-Item (Get-SessionFile $data 'a')).CreationTime = (Get-Date).AddMinutes(-2)
        (Get-Item (Get-SessionFile $data 'c')).CreationTime = (Get-Date).AddMinutes(-1)
        (Get-SessionFiles $data).BaseName | Should -Be @('b', 'a', 'c')
    }

    It 'returns nothing when no session was ever tracked' {
        @(Get-SessionFiles (Join-Path $TestDrive 'nothing-here')).Count | Should -Be 0
    }
}

Describe 'Remove-SessionFile' {
    It 'is quiet about a file that is already gone' {
        { $ErrorActionPreference = 'Stop'; Remove-SessionFile (Join-Path $TestDrive 'gone.json') } | Should -Not -Throw
    }
}

Describe 'ConvertTo-UniversalTime' {
    It 'reads a stored time back the same way in every PowerShell version' {
        $stored = '2026-10-04T15:58:17.1828544Z'
        (ConvertTo-UniversalTime $stored).ToString('o') | Should -Be $stored
        $fromJson = ('{"time":"' + $stored + '"}' | ConvertFrom-Json).time
        (ConvertTo-UniversalTime $fromJson).ToString('o') | Should -Be $stored
    }
}
