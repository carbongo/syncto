# syncto

Keeps git repos in sync by themselves: commit, pull and push on a timer or as you save.
When both sides changed the same lines it stops and tells you instead of guessing.
One bash script for macOS and Linux.

## Install

```sh
brew install carbongo/tap/syncto
```

or without Homebrew, into `~/.local`:

```sh
curl --proto '=https' --tlsv1.2 -fsSL https://github.com/carbongo/syncto/releases/latest/download/install.sh | sh
```

Needs git and bash 3.2 or newer (the bash macOS ships works). `fswatch` or
`inotifywait` make watching cheaper but are optional.

## Quick start

```sh
syncto add notes ~/notes watch=on   # sync ~/notes on every save
syncto start                        # keep syncing in the background
syncto                              # dashboard: see, add, edit, pause and sync repos
```

`syncto status` prints the same health as text:

```
notes     ✓ synced 2 min ago      on save         ~/notes
dotfiles  · offline, retrying     every 10 min    ~/.dotfiles
            last synced 3 h ago. ssh: connect to host github.com port 22: Opera…
work      ✗ needs you             on save         ~/work
            both sides changed README.md
            fix: cd ~/work && git pull --rebase, fix the files, git rebase --continue

Background: on, every 10 min, and on every save.
```

## Docs

- [Commands, exit codes, status words](docs/cli.md)
- [Options and config files](docs/options.md)
- [Background syncing: launchd, systemd, ssh keys](docs/scheduling.md)
- [Watch mode and syncing between machines](docs/watch.md)
- [What one sync does and how failures are handled](docs/sync.md)
- [Security](docs/security.md)

MIT licence.
