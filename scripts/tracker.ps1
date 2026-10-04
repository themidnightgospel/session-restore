# SessionStart/SessionEnd hook of the session-restore plugin: tracks open interactive Claude Code sessions so
# /session-restore:restore can reopen the ones still open at a reboot.
# Runs in Windows PowerShell 5.1 and PowerShell 7. ASCII only: 5.1 reads BOM-less scripts as ANSI.
param([Parameter(Mandatory)][ValidateSet('start', 'end')][string]$HookEvent)

$ErrorActionPreference = 'Stop'
# Start hooks run in the background and can finish out of order, so note when this one started.
$hookStarted = [DateTime]::UtcNow.Ticks
. (Join-Path $PSScriptRoot 'SessionTracker.ps1')

if (-not $env:CLAUDE_PLUGIN_DATA) { exit 0 }
$hook = Read-HookInput
if (-not (Test-SessionId $hook.session_id)) { exit 0 }
if ($HookEvent -eq 'start') { Register-Session $hook $env:CLAUDE_PLUGIN_DATA $hookStarted }
else { Unregister-Session $hook $env:CLAUDE_PLUGIN_DATA }
