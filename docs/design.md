# Design notes

## Why this exists

Keeping a handful of personal git repos (notes vaults, config repos, small local
projects) in sync across machines by hand is error-prone: forgetting to pull before you
edit, forgetting to push after, or editing the same file on two machines and only
noticing when a `push` is rejected. `syncto` automates the boring, safe 90% of that
loop — add/commit/pull/push on a schedule or on file-change — and refuses to guess on
the dangerous 10% (a real merge conflict), where it stops and asks a human instead.

It replaced two hand-written, machine-specific scripts (a launchd-driven one and a
systemd-driven one) that did the same job for one repo each, with copy-pasted logic and
no shared config format. `syncto` generalizes that logic into one tool that manages any
number of targets, each with its own path, remote, branch, interval, and hooks.

## The sync algorithm, step by step

For each target, in order:

1. **Acquire the lock.** `mkdir` a per-target lock directory (atomic across POSIX
   filesystems, unlike a lock *file*). If the lock directory already exists and its
   mtime is older than 10× the target's interval, treat it as stale (a previous run
   crashed or was killed) and steal it. Otherwise, another run is in progress: exit 4.
2. **Run the guard, if configured.** A target may set `guard=<shell cmd>` — an arbitrary
   command that must exit 0 for the sync to proceed (e.g. "not mid-way through a cloud
   placeholder rehydration", "battery not critical", "VPN connected"). A non-zero exit
   skips this target for this pass, logs why, and is *not* treated as an error — the
   overall run still exits 0.
3. **Stage.** `git add -A`. If nothing ends up staged and the target isn't `mode=pull`,
   skip straight to the pull step — there's nothing to commit, but there may still be
   upstream changes to bring down.
4. **Commit.** Message is `<prefix>: <basename>` when exactly one file changed, else
   `<prefix>: N files` — cheap, greppable, and never leaks full paths into history.
5. **Pull.** `git pull --rebase --autostash <remote> <branch>`. `--autostash` protects
   any uncommitted work that slipped in between steps 3 and 5; `--rebase` keeps history
   linear instead of accumulating merge-bubble commits on every sync. See below for what
   happens on failure.
6. **Push.** `git push <remote> <branch>`, skipped entirely when the target is
   `mode=pull` (pull-only targets never write upstream).
7. **Poke the peer, best-effort.** If step 4 produced a commit and `peer=<shell cmd>` is
   configured, run it (e.g. wake a paired machine so it syncs sooner). Its failure is
   swallowed and logged — it must never turn a successful sync into a failed run.

The lock is released (lock dir removed) whether the target succeeded, was skipped, or
errored, so one bad target never wedges the rest of the run or the next scheduled pass.

## Locking scheme

A lock is a directory, not a file, because `mkdir` is atomic on every filesystem this
tool targets (macOS APFS, Linux ext4/btrfs/etc.) in a way a `test -f && touch` file lock
is not — two processes racing `mkdir` on the same path, exactly one succeeds. The
staleness threshold (10× the target's configured interval) is deliberately generous: it
only exists to recover from a crashed prior run (killed daemon, kernel panic, forced
reboot mid-sync), not to arbitrate between two live runs that happen to overlap. A run
that's still alive well past 10 intervals is itself a bug worth surfacing, not silently
overriding.

## Conflict policy: abort and notify, never auto-resolve

If the rebase in step 5 fails — a real conflict, not something git can reconcile on its
own — `syncto` runs `git rebase --abort`, restoring the repo to exactly the state it
was in before the pull attempt (including the autostash pop), runs the target's
`notify=<shell cmd>` hook if one is set, and exits 2 (the dedicated "needs a human"
exit code, distinct from a generic error).

This is a hard rule, not a default that more code could someday override: `syncto`
never guesses which side of a conflict is "right". Silent auto-resolution (`-X ours`,
"take theirs", merge-and-hope) can silently discard real work, and the failure mode is
invisible until much later. A human looking at the actual conflicting hunks is the only
safe resolution path. The tool's job stops at *telling you it happened* as loudly as its
`notify=` hook allows (desktop notification, chat message, whatever the user wires up) —
it does not attempt anything past that.

## Why bash 3.2

macOS ships bash 3.2 (last GPLv2 release) as `/bin/bash` and does not update it; Linux
boxes commonly run bash 5.x. A tool meant to run unattended on both, launched by launchd
on one and systemd on the other, has to work on the lower common denominator or it
silently breaks the moment it lands on a Mac. Concretely this rules out associative
arrays (`declare -A`), `${var^^}`/`${var,,}` case conversion, `mapfile`/`readarray`, and
relying on `BASH_REMATCH` quirks introduced after 3.2. Everything is written to also run
correctly under bash 5 — the constraint is "3.2-safe", not "avoid anything bash 5
improved on".

The same portability concern rules out GNU-only flags entirely: no `sed -i` without an
explicit (empty, quoted) suffix argument, no `date -d`, no `readlink -f`, no `stat -c` —
macOS ships BSD versions of these tools that reject the GNU-only forms outright.

## Watcher fallback chain

Watch mode needs to notice a file changed without polling expensively. Neither of the
two reference machines ship a file-watcher binary out of the box, so `syncto` degrades
gracefully rather than hard-requiring one:

1. `fswatch`, if installed — efficient, cross-platform (macOS/Linux), the preferred path.
2. `inotifywait` (inotify-tools), if installed — the common Linux-native choice when
   `fswatch` isn't present.
3. A debounced poll loop as the universal fallback — compare a cheap fingerprint of
   `git status --porcelain` output on a short interval. It costs more CPU than a real
   watcher but needs nothing beyond git itself, so watch mode always works, even on a
   bare-bones box.

All three paths debounce for 2 seconds after a change is seen, so a burst of saves
(editor autosave, a build tool touching several files) triggers one sync, not one per
file.

## Security posture

- `syncto` never commits secrets. It has no notion of what a "secret" is; it commits
  whatever is in the working tree, so keeping tokens and credentials out of a synced
  repo (or `.gitignore`-ing them) is the user's responsibility, same as with git itself.
- The tool's own config (`targets`, `config`, and anything a `guard=`/`notify=`/`peer=`
  hook needs, such as key material referenced via `key=`/`GIT_SSH_COMMAND`) lives
  entirely outside the repos it manages, under `$XDG_CONFIG_HOME` or `$HOME`. Nothing
  target-specific — paths, hostnames, hook commands — is baked into the tool's own
  source; it is all read from user-supplied config at runtime.
- Schedulers (launchd, systemd user units) run without an `ssh-agent` in scope, so any
  target that pushes/pulls over SSH needs a passphrase-less key and an explicit
  `GIT_SSH_COMMAND` (or the `key=` shorthand that builds one). This is a known, deliberate
  trade-off: the alternative is a scheduled job that silently never succeeds because it
  can't prompt for a passphrase. Protect that key the way you'd protect any
  passphrase-less key — restrict it to the narrowest scope you can (a deploy key with
  push access to one repo beats a general-purpose personal key).
- Notification and peer-wake hooks (`notify=`, `peer=`) are opaque shell commands
  supplied by the user in their own config; `syncto` has no built-in integration with
  any specific chat/notification service, so no service-specific wiring or credentials
  live in this repo.
