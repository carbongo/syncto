# Commands

`syncto [-v] [COMMAND]`. `-v`/`--verbose` also prints log lines, with any command.

| Command | Does |
|---|---|
| `status` (or plain `syncto`) | each repo's health, how it syncs, a fix when it needs you; whether background syncing is on |
| `add NAME PATH [K=V ...]` | start syncing a repo; [options](options.md) comma separated or one per argument |
| `edit NAME K=V ...` | change a repo's options; `K=` resets one to its default |
| `edit` | open the targets file in `$EDITOR` |
| `remove NAME` | stop syncing a repo; its files stay |
| `sync [NAME]` | sync now: every repo, or NAME |
| `log` | last 100 log lines |
| `start` / `stop` | install or remove [background syncing](scheduling.md) |
| `run` | one scheduled pass over every due repo; what `start` schedules |
| `watch [NAME]` | the [watch](watch.md) loop in the foreground; what `start` runs for `watch=on` |
| `help`, `version` | also `-h`/`--help`, `-V`/`--version` |

The old flags (`-s`, `-a`, `-d`, …) exit 1 and say to run `syncto start`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | ok, including skipped passes and network outages |
| 1 | error: auth refused, push or git failure |
| 2 | needs you: conflict, unfinished rebase or detached HEAD; the repo is left as it was |
| 3 | config error, including a missing folder, a folder that is not a git repo, or a missing remote |
| 4 | another run holds the lock |

Several repos in one run exit with the worst code, in the order 2, 3, 1, 4, 0.

## Status words

| Shown | Meaning |
|---|---|
| ✓ synced 2 min ago | the last pass succeeded |
| · not synced yet | no pass has run |
| · paused | `paused=on`; a fix line says how to resume |
| · offline, retrying | the remote is unreachable; every pass retries |
| ! no sync for 5 h | passes keep being skipped (`guard=`, edits in progress) past `stale=` |
| ✗ needs you | a fix line says what to run |
| ✗ failing | auth refused, the remote is missing, or a push or git command failed |
| ✗ folder is missing, not a git repo | the path in the targets file is wrong |
