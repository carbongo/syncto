# syncto

Unattended git auto-sync for your own repos. Point it at a directory that's a git
checkout, and it keeps that directory and its remote in sync on a schedule (or on file
change): stage, commit, rebase-pull, push — and stop and tell you the moment something
needs a human, instead of guessing.

## Problem it solves

If you keep a notes vault, a dotfiles repo, or any small personal repo checked out on
more than one machine, you've done this dance: edit on machine A, forget to push; open
machine B, forget to pull first; now you have a conflict, or worse, silently diverging
history you don't notice for a week. `syncto` automates the safe, repetitive part of
that loop (add → commit → pull --rebase → push) on an interval or on save, for as many
repos as you want, each with its own settings — and it refuses to auto-resolve a real
conflict. It aborts, leaves your repo exactly as it was, and runs a notification hook
you control, so a human decides.

It is not a backup tool, not a CI system, and not a general git wrapper — it does one
narrow job (keep a small number of personal repos in sync) and tries to do it
predictably.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/carbongo/syncto/main/install.sh | sh
```

This copies the tool to `~/.local/share/syncto/syncto.sh` and installs the `syncto`
entry point on your `$PATH` at `~/.local/bin/syncto` (make sure that directory is on
your `$PATH` — most shells' default rc files already add it). The installer is
idempotent: run it again any time to update in place.

Requires: a POSIX shell, bash (3.2 or newer — the stock macOS bash works as-is), and
`git`. Nothing else is required to run; `fswatch` or `inotifywait` are optional and only
improve watch mode (see below).

## Quickstart

```sh
# Register a repo you already have checked out
syncto --add notes ~/notes

# Sync it once, right now
syncto --sync notes

# See all your targets and their last-sync status
syncto

# Let it run in the background on your machine's scheduler
syncto --install-service
```

That's it — `notes` now syncs itself every 120 seconds (the default interval) once the
scheduler is installed, using `git pull --rebase` then `git push`, with
sensible commit messages generated automatically.

## CLI reference

Flags, not subcommands — bare `syncto` is the default (list) action, matching the style
of tools like `cdto`.

| Flag | Long form | Action |
|---|---|---|
| *(none)* | | List all configured targets with their status |
| `-s [name]` | `--sync [name]` | Sync once — all targets, or just `<name>` |
| `-a <name> <path> [k=v ...]` | `--add <name> <path> [k=v ...]` | Add a new target |
| `-r <name>` | `--remove <name>` | Remove a target |
| `-e` | `--edit` | Open the targets file in `$EDITOR` |
| `-w [name]` | `--watch [name]` | Foreground watch loop (Ctrl-C to stop) |
| `-d` | `--daemon` | Run one scheduled pass (what launchd/systemd invokes) |
| `-i` | `--install-service` | Install the scheduler unit for this platform |
| `-u` | `--uninstall-service` | Remove the installed scheduler unit |
| `-L` | `--log` | Tail the log file |
| `-v` | `--verbose` | Modifier: more detail on any of the above |
| `-h` | `--help` | Show usage |
| `-V` | `--version` | Show version |

Examples:

```sh
syncto -a dotfiles ~/dotfiles mode=sync,interval=300,branch=main
syncto -s dotfiles          # sync just that target
syncto -s                   # sync every target
syncto -r dotfiles          # stop tracking it (does not touch the repo itself)
syncto -w notes             # watch just `notes` in the foreground
syncto -L                   # tail the log
```

## Configuration

Two files, both under `${XDG_CONFIG_HOME:-$HOME/.config}/syncto/`:

- **`targets`** — one repo per line, tab-separated: `name<TAB>path<TAB>options`. `path`
  stores `$HOME` literally as `~` so the file is portable across machines and usernames;
  `syncto` expands it when it reads the file. `options` is a comma-separated list of
  `key=value` pairs, all optional:

  | Key | Meaning | Default |
  |---|---|---|
  | `interval=<seconds>` | how often this target is synced | global default |
  | `watch=on\|off` | also sync on file-change | global default |
  | `debounce=<seconds>` | quiet period a watcher waits before syncing | `2` |
  | `mode=sync\|push\|pull` | two-way, push-only, or pull-only | `sync` |
  | `branch=<name>` | branch to sync | global default |
  | `remote=<name>` | remote to sync with | global default |
  | `prefix=<msg>` | commit message prefix | target name |
  | `guard=<cmd>` | must exit 0 or this target is skipped this pass | none |
  | `notify=<cmd>` | run on unresolved conflict (exit 2), best-effort | none |
  | `peer=<cmd>` | run after a successful commit+push, best-effort | none |

- **`config`** — global defaults, `key=value` lines: `interval`, `watch`, `debounce`,
  `mode`, `branch`, `remote`, `log`, `log_max` (defaults: `120`, `off`, `2`, `sync`,
  `main`, `origin`, `~/.local/state/syncto/syncto.log`, `2097152`). `log_max` is the
  size in bytes past which the log is rotated to `.1` on the next run; `0` disables
  rotation.

See [`config.example`](./config.example) and [`targets.example`](./targets.example) for
fully commented, worked examples of the two files — copy either into place and edit it.
`install.sh` seeds `config` for you; targets are easiest to add with `syncto --add`.

Minimal worked example. Given:

```
# ~/.config/syncto/targets
notes	~/notes	interval=60,watch=on,prefix=notes
```

running `syncto -s notes` will, in `~/notes`: `git add -A`; if anything was staged,
commit as `notes: <file>` or `notes: N files`; `git pull --rebase origin
main`; `git push origin main`.

The pull is skipped for that pass if the working tree is dirty when it is reached. A
rebase rewrites files on disk, and doing that to a file open in an editor makes the
editor reload the buffer and lose the caret — so `syncto` waits for a clean tree instead,
and never uses `--autostash`. The push still happens; the pull catches up next pass. See
`docs/design.md` for the full rationale.

### Hook environment

`guard=`, `notify=` and `peer=` run via `sh -c`, with the working directory set to the
target's repo, and these variables exported:

| Variable | Value |
|---|---|
| `SYNCTO_NAME` | the target's name |
| `SYNCTO_PATH` | absolute path to the repo |
| `SYNCTO_MESSAGE` | the commit message just made, or the conflict message for `notify=` |
| `SYNCTO_BRANCH` / `SYNCTO_REMOTE` | branch and remote in effect for this target |

A hook's exit status only matters for `guard=` (non-zero skips the target this pass);
`notify=` and `peer=` are best-effort and can never fail a sync. If a hook value needs a
literal comma, escape it as `\,`.

## Scheduling

`syncto --daemon` runs exactly one pass over every due target and exits — it's meant to
be invoked repeatedly by your OS's scheduler, not left running itself. `syncto
--install-service` sets that scheduler up for you:

- **macOS (launchd):** installs a `LaunchAgent` plist under `~/Library/LaunchAgents/`
  that runs `syncto --daemon` on an interval and at login.
- **Linux (systemd):** installs a user timer + oneshot service under
  `~/.config/systemd/user/` and enables it (`systemctl --user enable --now`).

If any target has `watch=on`, a second, resident unit is installed alongside the interval
one to run `syncto --watch` — see [Watch mode](#watch-mode).

`syncto --uninstall-service` reverses whichever of the two applies to the current
platform. Both scheduler types run **without an `ssh-agent`** — if a target pushes or
pulls over SSH, set a passphrase-less key for it via `key=<path>` (or a full
`GIT_SSH_COMMAND=`) in `config` or the target's options; see `config.example`. This is a
real, tested failure mode, not a hypothetical: a scheduled sync that needs to type a
passphrase simply never succeeds, silently.

### macOS: protected folders

If a target lives somewhere macOS protects — iCloud Drive, `~/Documents`, `~/Desktop` —
a scheduled sync needs Full Disk Access, and the grant attaches to the **binary launchd
executed**, not to `syncto`. The installed agent therefore runs `/bin/bash <path> -d`, so
the grant you need is on `/bin/bash`: System Settings → Privacy & Security → Full Disk
Access → add `/bin/bash`.

Without it the symptom is quiet and confusing rather than a permission error: the folder
reads back as empty, so `syncto` reports `not a git working tree` and refuses the target.
It will not stage a protected folder it cannot see — a mass deletion is not a way this
can fail. Manual `syncto --sync` from your terminal works regardless, because your
terminal has its own grant; only the scheduled path needs this.

## Watch mode

`syncto --watch [name]` syncs a target as soon as its files change, instead of waiting
for the next scheduled interval. It picks the best available watcher automatically:

1. `fswatch`, if installed.
2. `inotifywait` (from `inotify-tools`), if installed.
3. A debounced poll loop over `git status --porcelain` as a universal fallback — works
   with no extra dependency, at the cost of some CPU.

All three paths debounce (`debounce=`, default 2 seconds) so a burst of saves triggers
one sync, not one per file. When several targets are watched by one process they share
the largest debounce among them, so a patient target is never cut off mid-burst.

A watch-triggered sync first checks that the tree is actually dirty. A watcher fires on
any write under the repo, including paths git is told to ignore (editor scratch, trash
folders, agent session files); syncing those would cost a network round trip to discover
there was nothing to commit. Only the outbound direction is skipped — inbound changes
still arrive via `peer=` and the interval.

**`.git` is excluded from every watcher.** Syncing writes to `.git` — index, refs,
`FETCH_HEAD`, reflogs — so counting those as changes would make each sync trigger the
next one and the watcher would never go idle. The watcher binaries are told to exclude
it and the event handler drops `.git` paths as a backstop.

Set `watch=on` in a target's options and `syncto --install-service` will additionally
install a **resident watch daemon** (`syncto-watch.service` on Linux,
`com.user.syncto-watch` on macOS) that restarts itself if it dies. It runs *alongside*
the interval unit, which stays on as a slow safety net for anything the watcher can't
see: changes made while it was down, and inbound changes pushed by another machine.
Turning `watch=on` back off and re-running `--install-service` removes the daemon again.

### Reacting to another machine's push

A watcher only sees *local* edits, so on its own it makes the outbound direction instant
and leaves the inbound direction on the interval. `peer=` closes that loop: it runs after
a successful commit+push, so the machine that just pushed can wake its counterpart and
have it pull immediately rather than up to one interval later.

```
# machine A                                        # machine B
peer=ssh -o BatchMode=yes -o ConnectTimeout=5 B 'systemctl --user start syncto.service'
```

With both halves in place — watch out, peer in — the interval exists only as a backstop
and can be lengthened considerably, which is also what shrinks the window in which two
machines can diverge far enough to conflict.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | OK |
| `1` | Error |
| `2` | Conflict — needs a human, nothing was auto-resolved |
| `3` | Config error |
| `4` | Lock held (another sync for this target is already running) |

On a `2`, your repo is left exactly as it was before the sync attempt (`git rebase
--abort` was run for you) and the target's `notify=` hook, if set, has already fired.
Resolve the conflict by hand in the repo, the normal way, then re-run `syncto -s
<name>`.

## Design notes

See [`docs/design.md`](./docs/design.md) for why the tool is built this way: the sync
algorithm in detail, the locking scheme, the conflict policy, the bash-3.2 constraint,
and the security posture.

## License

MIT, see [`LICENSE`](./LICENSE).
