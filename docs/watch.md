# Watch mode and syncing between machines

`watch=on` syncs a repo `debounce` seconds after its files stop changing. Each save
restarts the wait, so typing into an editor that autosaves syncs once you pause, never
mid-sentence; raise `debounce` (say `60`) for editors like that. `syncto start` runs the
watch daemon; `syncto watch [NAME]` runs the same loop in the foreground.

- Watcher, first one found: `fswatch`, `inotifywait` (inotify-tools), else a poll of
  `git status --porcelain`.
- One daemon watches every repo and uses the longest `debounce` among them.
- `.git` is never watched: syncing writes there, so it would trigger itself forever.
- A change that leaves `git status` clean (an ignored path) does not sync.

## Changes from other machines

A watcher only sees local edits. Two options pull other machines' work promptly:

| Option | Covers | How |
|---|---|---|
| `peer=CMD` | machines running syncto | after a push with a new commit, wake the other one: `peer=ssh -o BatchMode=yes HOST '~/.local/bin/syncto sync NAME'` |
| `remote_poll=SECONDS` | pushes from anywhere (CI, web editors) | the watch daemon runs `git ls-remote` this often and syncs when the remote has a commit the repo lacks |

With both, the scheduled pass is only a backstop and `interval` can be long. Losing the
watcher or a wake falls back to scheduled syncing, never to a stall.
