---
name: restore
description: Reopen the Claude Code sessions that were open before a reboot or a closed terminal window, each in its own Windows Terminal tab. Also lists or forgets tracked sessions.
argument-hint: "[list | all | 1,3 | forget 2 | help]"
disable-model-invocation: true
allowed-tools: Bash(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/restore.ps1" -DataDir "${CLAUDE_PLUGIN_DATA}" *), PowerShell(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/restore.ps1" -DataDir "${CLAUDE_PLUGIN_DATA}" *)
---

!`powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/restore.ps1" -DataDir "${CLAUDE_PLUGIN_DATA}" '$ARGUMENTS'`

The output above comes from the session-restore script, which has already done everything requested. Show that output to the user as it is, without commentary, and don't run any commands.
