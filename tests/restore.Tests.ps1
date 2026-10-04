# Runs skills/restore/scripts/restore.ps1 the way the slash command does: a powershell.exe process whose output
# Claude reads. Run with Pester 5 or later, from Windows PowerShell 5.1 or PowerShell 7.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\SessionStore.ps1')
    $script:restore = (Resolve-Path (Join-Path $PSScriptRoot '..\skills\restore\scripts\restore.ps1')).Path
    $script:data = Join-Path $TestDrive 'data'

    function Invoke-Restore([string]$Arguments) {
        $info = New-Object Diagnostics.ProcessStartInfo 'powershell.exe', "-NoProfile -ExecutionPolicy Bypass -File `"$script:restore`" -DataDir `"$script:data`" $Arguments"
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.StandardOutputEncoding = New-Object Text.UTF8Encoding $false
        $process = [Diagnostics.Process]::Start($info)
        $output = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output }
    }
}

Describe 'restore.ps1' {
    It 'prints non-ASCII folder names as UTF-8, which is how Claude reads the output' {
        $georgian = -join ([char[]](0x10E2, 0x10D4, 0x10E1, 0x10E2, 0x10D8))
        Write-SessionEntry $script:data ([ordered]@{ sessionId = 'unicode'; cwd = "C:\work\$georgian"; pid = 999999 })
        $result = Invoke-Restore 'list'
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match $georgian
    }

    It 'reports a failure as output and still exits 0, so the slash command shows it' {
        $result = Invoke-Restore '99999999999'
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'session-restore failed'
    }
}
