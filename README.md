<div align="center">

<pre>
╭──▶╮  ┌─┐┬ ┬┌┐┌┌─┐┌┬┐┌─┐
│ ● │  └─┐└┬┘││││   │ │ │
╰◀──╯  └─┘ ┴ ┘└┘└─┘ ┴ └─┘
</pre>

# syncto

**Git repos that keep themselves in sync.**<br>
Commit, pull and push on a timer or as you save. When both sides changed the same
lines it stops and tells you what to run, instead of guessing.

[![CI](https://github.com/carbongo/syncto/actions/workflows/ci.yml/badge.svg)](https://github.com/carbongo/syncto/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/carbongo/syncto?color=2ea043)](https://github.com/carbongo/syncto/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-carbongo%2Ftap%2Fsyncto-fbb040?logo=homebrew&logoColor=white)](https://github.com/carbongo/homebrew-tap)
[![Platforms](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-555?logo=apple&logoColor=white)](docs/scheduling.md)
[![bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-4eaa25?logo=gnubash&logoColor=white)](AGENTS.md)
[![Dependencies](https://img.shields.io/badge/dependencies-only%20git-blue?logo=git&logoColor=white)](#install)
[![License: MIT](https://img.shields.io/github/license/carbongo/syncto?color=blue)](LICENSE)

</div>

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
