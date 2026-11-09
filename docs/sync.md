# One sync, step by step

1. **Lock**: `mkdir` a per-repo lock; if another run holds it, exit 4. A lock older than
   10 × `interval` is taken over.
2. **Check** the folder exists and is a git repo, else exit 3.
3. **Guard**: `guard=` exiting non-zero skips this pass, not an error.
4. **Refuse** a repo mid-rebase or mid-merge, or with a detached HEAD: needs you.
5. **Commit**: `git add -A`, then `PREFIX: file` or `PREFIX: N files`.
6. **Pull**: `git pull --rebase --no-autostash`, only into a clean tree. A tree that went
   dirty again defers the pull to the next pass.
7. **Push**, except `mode=pull`. Rejected after a deferred pull: expected, retried next pass.
8. **Peer**: `peer=` after a push that carried a new commit; its failure never fails the sync.

## Failures

| What happened | Log level | Exit | `notify=` | `status` |
|---|---|---|---|---|
| rebase conflict | conflict | 2 | yes | ✗ needs you, the files and a fix |
| network: DNS, timeout, dropped connection | warn | 0 | no | · offline, retrying |
| auth refused | error | 1 | no | ✗ failing |
| other git failure | error | 1 | no | ✗ failing |
| no success for `stale=` | warn | 0 | yes | ! no sync for N h |

`notify=` fires at most once per 30 min per repo and re-arms after a good sync.

## Rules that must not change

- Never auto-resolve a conflict: abort the rebase, leave the repo as it was, tell a human.
- Never rebase into a dirty tree or use `--autostash`: rewriting a file open in an editor
  moves its caret.
- Staleness is judged from the last success, so a new kind of skip is covered without
  listing causes.
- The log rotates to one `.1` generation past `log_max`, checked once per run.
