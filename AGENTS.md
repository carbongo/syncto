# syncto — agent entry point

Unattended git auto-sync for one or more local repos: add, commit, rebase-pull, push,
on an interval or a filesystem watch, per-target configurable. Pure shell, no build step.

Sync is event-driven when configured for it: `watch=on` installs a resident watch daemon
that pushes local edits within a debounce window, and `peer=` lets the pushing machine
wake its counterpart so the inbound direction is prompt too. The interval unit stays on
underneath as a backstop.

Facts:
- Everything lives in `syncto.sh` (bash 3.2 + bash 5 compatible — no associative arrays,
  no `${var^^}`, no `mapfile`, no `declare -A`; runs on macOS stock bash and Linux bash).
- Install layout: script → `~/.local/share/syncto/syncto.sh`, entry point symlink/shim
  → `~/.local/bin/syncto` (on `$PATH`).
- Targets config: `${XDG_CONFIG_HOME:-$HOME/.config}/syncto/targets` — TSV,
  `name<TAB>path<TAB>options`, `$HOME` stored as `~`. Global config:
  `${XDG_CONFIG_HOME:-$HOME/.config}/syncto/config` — `key=value` lines.
- CLI is flags, not subcommands (mirrors `cdto`): bare `syncto` lists targets;
  `-s/--sync`, `-a/--add`, `-r/--remove`, `-e/--edit`, `-w/--watch`, `-d/--daemon`,
  `-i/--install-service`, `-u/--uninstall-service`, `-L/--log`, `-v/--verbose`,
  `-h/--help`, `-V/--version`. See README for the full table.
- Test: `./test.sh` (runs the suite under bash; project targets bash 3.2 semantics even
  when tested under a newer bash). The watch tests stub both `fswatch` and `inotifywait`
  on `PATH` to replay a fixed event list, so they exercise the real watcher code path
  without needing either installed — and without the real watcher hanging the suite.
- Unit templates in `templates/`: `syncto.{service,timer}.in` + `com.user.syncto.plist.in`
  for the interval unit, `syncto-watch.service.in` + `com.user.syncto-watch.plist.in` for
  the resident watch daemon (installed only when some target has `watch=on`).
- Install: `./install.sh` (POSIX `sh`, idempotent) or the curl one-liner in the README.
- No ssh-agent under schedulers (launchd/systemd have none): use the `key=` /
  `GIT_SSH_COMMAND` escape hatch in the target's options, not an agent-dependent setup.
- Exit codes: `0` ok, `1` error, `2` conflict needing a human, `3` config error,
  `4` lock held.

docs/ map:
- `docs/design.md` — why this tool exists, the sync algorithm step by step, the locking
  scheme, why a rebase never runs into a dirty tree (an editor's caret is the thing being
  protected), the conflict policy (abort + notify, never auto-resolve), the event-driven
  model (watch out / peer in) and why the interval survives as a backstop, why bash 3.2,
  the watcher fallback chain including why `.git` must be excluded from it, log
  rotation, and the security posture.
