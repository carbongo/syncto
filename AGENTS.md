# syncto

Unattended git auto-sync: commit, rebase-pull and push on a timer or on file change.
One bash script, no build step. Public repo: changes go through PRs.

## Start

| Task | Command |
|---|---|
| run from source | `./syncto.sh <command>` |
| install | `./install.sh` (script to `~/.local/share/syncto/`, entry point `~/.local/bin/syncto`) |
| test | `./test.sh`, and `/bin/bash ./test.sh` for bash 3.2 |
| lint | `shellcheck -S warning syncto.sh install.sh uninstall.sh test.sh` |

CI (`.github/workflows/ci.yml`) runs the lint, and the tests on macOS (bash 3.2) and Ubuntu.

## Constraints

- bash 3.2 and 5, BSD and GNU userland: no `declare -A`, `${v^^}`, `mapfile`,
  `readlink -f`, `date -d`, `stat -c`, or `sed -i` without a suffix.
- `main` runs as `main || rc=$?`, so `set -e` is off inside it: check `$(…)` failures.
- Brace a variable followed by a non-ASCII character (`${name}…`): bash 3.2 reads the
  bytes as part of the name.
- Never auto-resolve a conflict; never rebase into a dirty tree (no `--autostash`).
- launchd and systemd have no ssh-agent: targets use `key=` or `GIT_SSH_COMMAND`.
- Comments: one line, only where the code alone would mislead.
- Tests stub `fswatch` and `inotifywait`; a real watcher never exits and hangs the suite.

## Docs

- `docs/cli.md`: commands, exit codes, status words
- `docs/options.md`: options and defaults, config files, hook environment
- `docs/scheduling.md`: start/stop units, ssh keys, macOS Full Disk Access
- `docs/watch.md`: watch mode, watchers, peer wake, remote poll
- `docs/sync.md`: one pass step by step, failure handling, rules that must not change
- `docs/security.md`: what gets committed, where config and keys live
