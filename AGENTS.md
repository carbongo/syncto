# syncto — agent entry point

Unattended git auto-sync for one or more local repos: add, commit, rebase-pull, push,
on an interval or a filesystem watch, per-target configurable. Pure shell, no build step.

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
  when tested under a newer bash).
- Install: `./install.sh` (POSIX `sh`, idempotent) or the curl one-liner in the README.
- No ssh-agent under schedulers (launchd/systemd have none): use the `key=` /
  `GIT_SSH_COMMAND` escape hatch in the target's options, not an agent-dependent setup.
- Exit codes: `0` ok, `1` error, `2` conflict needing a human, `3` config error,
  `4` lock held.

docs/ map:
- `docs/design.md` — why this tool exists, the sync algorithm step by step, the locking
  scheme, the conflict policy (abort + notify, never auto-resolve), why bash 3.2, the
  watcher fallback chain, and the security posture.
