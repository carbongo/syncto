# Options and files

Options are `key=value`, comma separated; `\,` is a literal comma. Set them per repo
(`syncto add`, `syncto edit`) or as defaults in the global config.

| Key | Meaning | Default |
|---|---|---|
| `interval=SECONDS` | minimum time between scheduled syncs | `120` |
| `watch=on\|off` | sync within seconds of a file changing ([watch](watch.md)) | `off` |
| `paused=on\|off` | skip in background syncing and plain `syncto sync`; `sync NAME` still runs | `off` |
| `debounce=SECONDS` | quiet time a watcher waits before syncing | `2` |
| `mode=sync\|push\|pull` | both ways, push only, pull only | `sync` |
| `branch=NAME` | branch to pull and push | `main` |
| `remote=NAME` | remote to pull and push | `origin` |
| `prefix=TEXT` | commit message prefix: `TEXT: notes.md`, `TEXT: 3 files` | `syncto` |
| `guard=CMD` | runs first; non-zero skips this pass quietly | none |
| `notify=CMD` | runs on a conflict or when a repo goes stale, at most every 30 min | none |
| `peer=CMD` | runs after a push that carried a new commit | none |
| `stale=SECONDS\|off` | time without a sync before `notify=` fires; `0` = 12 × interval, at least 600 | `0` |
| `remote_poll=SECONDS\|off` | the watch daemon checks the remote this often | `off` |
| `key=PATH` | ssh key for git ([why](scheduling.md#ssh-keys)) | none |
| `GIT_SSH_COMMAND=CMD` | full ssh command, wins over `key=`; alias `ssh=` | none |

Global config only: `log=PATH` (`~/.local/state/syncto/syncto.log`) and `log_max=BYTES`
(`2097152`; the log rotates to `.1` past it, `0` disables).

## Files

| Path | Holds |
|---|---|
| `~/.config/syncto/targets` | one repo per line: `NAME<TAB>PATH<TAB>OPTIONS`, `$HOME` stored as `~` |
| `~/.config/syncto/config` | global defaults, one `key=value` per line ([example](../config.example)) |
| `~/.local/state/syncto/` | log, last pass, last success and last problem per repo, locks |

`$XDG_CONFIG_HOME` and `$XDG_STATE_HOME` replace `~/.config` and `~/.local/state` when set.

## Hooks

`guard=`, `notify=` and `peer=` run through `sh -c` inside the repo, with:

| Variable | Value |
|---|---|
| `SYNCTO_NAME`, `SYNCTO_PATH` | the repo's name and absolute path |
| `SYNCTO_BRANCH`, `SYNCTO_REMOTE` | branch and remote in use |
| `SYNCTO_MESSAGE` | the commit message, or for `notify=` the problem |

Only `guard=`'s exit status matters; `notify=` and `peer=` never fail a sync.
