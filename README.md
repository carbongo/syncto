# gitsync

Unattended git auto-sync for your own repos. Point it at a directory that's a git
checkout, and it keeps that directory and its remote in sync on a schedule (or on file
change): stage, commit, rebase-pull, push — and stop and tell you the moment something
needs a human, instead of guessing.

## Problem it solves

If you keep a notes vault, a dotfiles repo, or any small personal repo checked out on
more than one machine, you've done this dance: edit on machine A, forget to push; open
machine B, forget to pull first; now you have a conflict, or worse, silently diverging
history you don't notice for a week. `gitsync` automates the safe, repetitive part of
that loop (add → commit → pull --rebase → push) on an interval or on save, for as many
repos as you want, each with its own settings — and it refuses to auto-resolve a real
conflict. It aborts, leaves your repo exactly as it was, and runs a notification hook
you control, so a human decides.

It is not a backup tool, not a CI system, and not a general git wrapper — it does one
narrow job (keep a small number of personal repos in sync) and tries to do it
predictably.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/PLACEHOLDER_USER/gitsync/main/install.sh | sh
```

This copies the tool to `~/.local/share/gitsync/gitsync.sh` and installs the `gitsync`
entry point on your `$PATH` at `~/.local/bin/gitsync` (make sure that directory is on
your `$PATH` — most shells' default rc files already add it). The installer is
idempotent: run it again any time to update in place.

Requires: a POSIX shell, bash (3.2 or newer — the stock macOS bash works as-is), and
`git`. Nothing else is required to run; `fswatch` or `inotifywait` are optional and only
improve watch mode (see below).

## Quickstart

```sh
# Register a repo you already have checked out
gitsync --add notes ~/notes

# Sync it once, right now
gitsync --sync notes

# See all your targets and their last-sync status
gitsync

# Let it run in the background on your machine's scheduler
gitsync --install-service
```

That's it — `notes` now syncs itself every 120 seconds (the default interval) once the
scheduler is installed, using `git pull --rebase --autostash` then `git push`, with
sensible commit messages generated automatically.

## CLI reference

Flags, not subcommands — bare `gitsync` is the default (list) action, matching the style
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
gitsync -a dotfiles ~/dotfiles mode=sync,interval=300,branch=main
gitsync -s dotfiles          # sync just that target
gitsync -s                   # sync every target
gitsync -r dotfiles          # stop tracking it (does not touch the repo itself)
gitsync -w notes             # watch just `notes` in the foreground
gitsync -L                   # tail the log
```

## Configuration

Two files, both under `${XDG_CONFIG_HOME:-$HOME/.config}/gitsync/`:

- **`targets`** — one repo per line, tab-separated: `name<TAB>path<TAB>options`. `path`
  stores `$HOME` literally as `~` so the file is portable across machines and usernames;
  `gitsync` expands it when it reads the file. `options` is a comma-separated list of
  `key=value` pairs, all optional:

  | Key | Meaning | Default |
  |---|---|---|
  | `interval=<seconds>` | how often this target is synced | global default |
  | `watch=on\|off` | also sync on file-change | global default |
  | `mode=sync\|push\|pull` | two-way, push-only, or pull-only | `sync` |
  | `branch=<name>` | branch to sync | global default |
  | `remote=<name>` | remote to sync with | global default |
  | `prefix=<msg>` | commit message prefix | target name |
  | `guard=<cmd>` | must exit 0 or this target is skipped this pass | none |
  | `notify=<cmd>` | run on unresolved conflict (exit 2), best-effort | none |
  | `peer=<cmd>` | run after a successful commit+push, best-effort | none |

- **`config`** — global defaults, `key=value` lines: `interval`, `watch`, `mode`,
  `branch`, `remote`, `log` (defaults: `120`, `off`, `sync`, `main`, `origin`,
  `~/.local/state/gitsync/gitsync.log`).

See [`config.example`](./config.example) for a fully commented, worked example of both
files — copy the relevant half into place and edit it.

Minimal worked example. Given:

```
# ~/.config/gitsync/targets
notes	~/notes	interval=60,watch=on,prefix=notes
```

running `gitsync -s notes` will, in `~/notes`: `git add -A`; if anything was staged,
commit as `notes: <file>` or `notes: N files`; `git pull --rebase --autostash origin
main`; `git push origin main`.

## Scheduling

`gitsync --daemon` runs exactly one pass over every due target and exits — it's meant to
be invoked repeatedly by your OS's scheduler, not left running itself. `gitsync
--install-service` sets that scheduler up for you:

- **macOS (launchd):** installs a `LaunchAgent` plist under `~/Library/LaunchAgents/`
  that runs `gitsync --daemon` on an interval and at login.
- **Linux (systemd):** installs a user timer + oneshot service under
  `~/.config/systemd/user/` and enables it (`systemctl --user enable --now`).

`gitsync --uninstall-service` reverses whichever of the two applies to the current
platform. Both scheduler types run **without an `ssh-agent`** — if a target pushes or
pulls over SSH, set a passphrase-less key for it via `key=<path>` (or a full
`GIT_SSH_COMMAND=`) in `config` or the target's options; see `config.example`. This is a
real, tested failure mode, not a hypothetical: a scheduled sync that needs to type a
passphrase simply never succeeds, silently.

## Watch mode

`gitsync --watch [name]` runs in the foreground and syncs a target as soon as its files
change, instead of waiting for the next scheduled interval. It picks the best available
watcher automatically:

1. `fswatch`, if installed.
2. `inotifywait` (from `inotify-tools`), if installed.
3. A debounced poll loop over `git status --porcelain` as a universal fallback — works
   with no extra dependency, at the cost of some CPU.

All three paths debounce for 2 seconds, so a burst of saves triggers one sync, not one
per file. Set `watch=on` in a target's options to have the installed scheduler also
launch (or delegate to) a watcher for that target, in addition to its regular interval.

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
Resolve the conflict by hand in the repo, the normal way, then re-run `gitsync -s
<name>`.

## Design notes

See [`docs/design.md`](./docs/design.md) for why the tool is built this way: the sync
algorithm in detail, the locking scheme, the conflict policy, the bash-3.2 constraint,
and the security posture.

## License

MIT, see [`LICENSE`](./LICENSE).
