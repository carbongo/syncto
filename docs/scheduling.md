# Background syncing

`syncto start` installs and starts the units, `syncto stop` removes them. Run `start`
again after upgrading or changing `interval`, `watch` or `remote_poll`.

| Unit | macOS (launchd) | Linux (systemd --user) |
|---|---|---|
| scheduled pass, every global `interval` | `~/Library/LaunchAgents/com.user.syncto.plist` | `~/.config/systemd/user/syncto.{service,timer}` |
| watch daemon, only when a repo has `watch=on` or `remote_poll` | `com.user.syncto-watch.plist`, kept alive | `syncto-watch.service`, restarts on exit |

A per-repo `interval` longer than the global one makes that repo skip passes until it is
due. Elsewhere, run `syncto run` from cron.

## SSH keys

launchd and systemd start syncs without an ssh-agent. A repo that pulls or pushes over
ssh needs a passphrase-less key named with `key=PATH` (or `GIT_SSH_COMMAND=`), or its
scheduled syncs fail while manual ones work. Prefer a deploy key limited to that repo.

## macOS protected folders

iCloud Drive, `~/Documents` and `~/Desktop` need Full Disk Access for the program launchd
starts. `syncto start` builds that program once, `~/.local/share/syncto/launcher`, if the
Xcode Command Line Tools are installed. Grant it alone: System Settings → Privacy &
Security → Full Disk Access → + → ⇧⌘G, paste the path. Never grant `/bin/bash`: every
LaunchAgent could then use it. Without the tools syncto starts `/bin/bash` and does not
support protected folders; their folder reads as empty and `status` says "not a git repo".
