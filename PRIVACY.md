# Privacy

Session Restore runs only on your computer and makes no network requests.

## What it stores

For each interactive Claude Code session, one small JSON file in the plugin's data folder on your computer:

- the session ID and the folder the session was started in
- the shell it was started from and the permission flags it was started with
- the process ID and start time of that Claude Code process, and when the tracking hook ran
- the path of the session's transcript

When you run `/session-restore:restore list`, it also saves the order of that list, so the numbers you type afterwards
mean the sessions it showed.

## What it reads

- The list of running processes, to find the shell a session was started from and to tell open sessions from closed
  ones.
- The end of each tracked session's transcript, for the session's title.

## What it sends

Nothing. The plugin sends no data anywhere.

## How long it keeps data

An entry is deleted when its session ends on purpose (`/exit`, Ctrl+C or Ctrl+D, `/clear`, `/resume`, logout), when
you forget it with `/session-restore:restore forget`, or after 30 days without use. Uninstalling the plugin deletes the
plugin's data folder.

## Questions

Open an issue at https://github.com/themidnightgospel/session-restore/issues.
