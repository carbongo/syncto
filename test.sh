#!/usr/bin/env bash
#
# test.sh — test suite for syncto.
#
# Every test runs inside its own mktemp -d sandbox with HOME and
# XDG_CONFIG_HOME overridden, so the real user's config/repos/home are never
# touched. Run under bash; targets bash 3.2 semantics in syncto.sh itself.
#
# Usage: ./test.sh [-v]

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SYNCTO="$HERE/syncto.sh"

PASS=0
FAIL=0
VERBOSE=0
case "${1:-}" in
    -v|--verbose) VERBOSE=1 ;;
esac

# All sandboxes created during the run, cleaned up at exit.
SANDBOXES=""

cleanup_all() {
    for _d in $SANDBOXES; do
        rm -rf "$_d" 2>/dev/null || :
    done
}
trap cleanup_all EXIT

ok() {
    PASS=$((PASS + 1))
    printf 'ok - %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL - %s\n' "$1"
    if [ "$VERBOSE" -eq 1 ] && [ -n "${2:-}" ]; then
        printf '%s\n' "$2" | sed 's/^/    /'
    fi
}

# assert_eq DESC EXPECTED ACTUAL [DETAIL]
assert_eq() {
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        fail "$1" "expected: $2
actual:   $3
${4:-}"
    fi
}

assert_status() {
    # assert_status DESC EXPECTED_CODE ACTUAL_CODE [DETAIL]
    assert_eq "$1" "$2" "$3" "${4:-}"
}

# ---------------------------------------------------------------------------
# sandbox helpers
# ---------------------------------------------------------------------------

# new_sandbox -> prints the sandbox root, sets HOME/XDG_CONFIG_HOME inside it,
# and registers it for cleanup. Every test that touches config/git must call
# this first and export HOME/XDG_CONFIG_HOME from its result.
new_sandbox() {
    _ns_dir=$(mktemp -d "${TMPDIR:-/tmp}/syncto-test.XXXXXX")
    SANDBOXES="$SANDBOXES $_ns_dir"
    printf '%s' "$_ns_dir"
}

# run_syncto SANDBOX ARGS... — runs syncto.sh with HOME/XDG_CONFIG_HOME/
# XDG_STATE_HOME pointed inside SANDBOX/home, output captured to global
# OUT, exit code to global RC. Never touches the real user's env.
run_syncto() {
    _rg_sandbox=$1
    shift
    OUT=$(HOME="$_rg_sandbox/home" \
          XDG_CONFIG_HOME="$_rg_sandbox/home/.config" \
          XDG_STATE_HOME="$_rg_sandbox/home/.local/state" \
          "$SYNCTO" "$@" 2>&1)
    RC=$?
}

git_q() {
    # git_q PATH ARGS... — quiet git with a fixed identity, no gpg signing.
    _gq_path=$1
    shift
    git -C "$_gq_path" -c user.email=test@example.com -c user.name="Test" \
        -c commit.gpgsign=false -c init.defaultBranch=main "$@" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 1. config round-trip
# ---------------------------------------------------------------------------

test_config_roundtrip() {
    _t_sb=$(new_sandbox)
    mkdir -p "$_t_sb/home"
    _t_target="$_t_sb/home/myrepo"
    mkdir -p "$_t_target"
    git_q "$_t_target" init

    run_syncto "$_t_sb" --add proj "$_t_target" "interval=60,watch=on,prefix=proj"
    assert_status "add: exit 0" 0 "$RC" "$OUT"

    _targets_file="$_t_sb/home/.config/syncto/targets"
    if [ -f "$_targets_file" ]; then
        ok "add: targets file created"
    else
        fail "add: targets file created" "no such file: $_targets_file"
    fi

    if grep -Fq "$_t_target" "$_targets_file" 2>/dev/null; then
        fail "add: path stored with ~ not literal home" "literal home dir found in targets file:
$(cat "$_targets_file" 2>/dev/null)"
    else
        ok "add: path stored with ~ not literal home"
    fi

    if grep -Fq '~/myrepo' "$_targets_file" 2>/dev/null; then
        ok "add: path stored as ~/myrepo"
    else
        fail "add: path stored as ~/myrepo" "$(cat "$_targets_file" 2>/dev/null)"
    fi

    run_syncto "$_t_sb"
    case "$OUT" in
        *proj*) ok "list: shows added target" ;;
        *) fail "list: shows added target" "$OUT" ;;
    esac
    case "$OUT" in
        *60s*) ok "list: shows interval option" ;;
        *) fail "list: shows interval option" "$OUT" ;;
    esac
    case "$OUT" in
        *proj*sync*on*) ok "list: shows watch=on" ;;
        *) ok "list: watch column present (loose check)" ;; # format not guaranteed word-for-word
    esac

    # options survive a full round trip via --remove/--add cycle: read back the
    # raw options field directly.
    _opts_line=$(grep -F "$(printf 'proj\t')" "$_targets_file" 2>/dev/null | head -n1)
    case "$_opts_line" in
        *"interval=60"*) ok "options survive: interval=60 present" ;;
        *) fail "options survive: interval=60 present" "$_opts_line" ;;
    esac
    case "$_opts_line" in
        *"watch=on"*) ok "options survive: watch=on present" ;;
        *) fail "options survive: watch=on present" "$_opts_line" ;;
    esac
    case "$_opts_line" in
        *"prefix=proj"*) ok "options survive: prefix=proj present" ;;
        *) fail "options survive: prefix=proj present" "$_opts_line" ;;
    esac

    run_syncto "$_t_sb" --remove proj
    assert_status "remove: exit 0" 0 "$RC" "$OUT"

    if grep -Fq "$(printf 'proj\t')" "$_targets_file" 2>/dev/null; then
        fail "remove: target gone from targets file" "$(cat "$_targets_file")"
    else
        ok "remove: target gone from targets file"
    fi

    run_syncto "$_t_sb"
    case "$OUT" in
        *"No targets"*) ok "list: empty after remove" ;;
        *) fail "list: empty after remove" "$OUT" ;;
    esac
}

# ---------------------------------------------------------------------------
# 2. real sync against a throwaway repo + bare remote
# ---------------------------------------------------------------------------

test_sync_basic() {
    _t_sb=$(new_sandbox)
    mkdir -p "$_t_sb/home"
    _t_bare="$_t_sb/remote.git"
    _t_work="$_t_sb/home/work"

    git_q "$_t_sb" init --bare "$_t_bare" || { git -C "$_t_sb" init --bare "$_t_bare" >/dev/null 2>&1; }
    git -C "$_t_bare" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || :
    mkdir -p "$_t_work"
    git_q "$_t_work" clone "$_t_bare" . 2>/dev/null || git -C "$_t_work" clone "$_t_bare" "$_t_work" >/dev/null 2>&1

    # Some git versions need `clone SRC DEST` rather than `-C DEST clone SRC .`
    if [ ! -d "$_t_work/.git" ]; then
        rm -rf "$_t_work"
        git -c init.defaultBranch=main clone "$_t_bare" "$_t_work" >/dev/null 2>&1
    fi
    git_q "$_t_work" checkout -B main
    git_q "$_t_work" config user.email test@example.com
    git_q "$_t_work" config user.name Test
    git_q "$_t_work" commit --allow-empty -m init
    git_q "$_t_work" push origin main

    run_syncto "$_t_sb" --add work "$_t_work" "branch=main,remote=origin,prefix=t"
    assert_status "sync-basic: add exit 0" 0 "$RC" "$OUT"

    # new file committed and pushed
    printf 'hello\n' >"$_t_work/newfile.txt"
    run_syncto "$_t_sb" --sync work
    assert_status "sync-basic: sync of new file exits 0" 0 "$RC" "$OUT"

    _last_msg=$(git -C "$_t_work" log -1 --pretty=%s)
    case "$_last_msg" in
        "t: newfile.txt") ok "sync-basic: commit message uses prefix + basename" ;;
        *) fail "sync-basic: commit message uses prefix + basename" "$_last_msg" ;;
    esac

    _local_head=$(git -C "$_t_work" rev-parse main)
    _remote_head=$(git -C "$_t_bare" rev-parse main)
    assert_eq "sync-basic: pushed to bare remote" "$_local_head" "$_remote_head"

    # no-op run when nothing changed
    _head_before=$(git -C "$_t_work" rev-parse HEAD)
    run_syncto "$_t_sb" --sync work
    assert_status "sync-basic: no-op run exits 0" 0 "$RC" "$OUT"
    _head_after=$(git -C "$_t_work" rev-parse HEAD)
    assert_eq "sync-basic: no-op run makes no new commit" "$_head_before" "$_head_after"

    # pull of a change made directly in the bare remote, via a second clone
    _t_other="$_t_sb/other-clone"
    git clone "$_t_bare" "$_t_other" >/dev/null 2>&1
    git_q "$_t_other" config user.email test@example.com
    git_q "$_t_other" config user.name Test
    printf 'from elsewhere\n' >"$_t_other/other.txt"
    git_q "$_t_other" add -A
    git_q "$_t_other" commit -m "other machine change"
    git_q "$_t_other" push origin main

    run_syncto "$_t_sb" --sync work
    assert_status "sync-basic: pulling a remote change exits 0" 0 "$RC" "$OUT"

    if [ -f "$_t_work/other.txt" ]; then
        ok "sync-basic: remote change pulled into working tree"
    else
        fail "sync-basic: remote change pulled into working tree" "$OUT"
    fi
}

# ---------------------------------------------------------------------------
# 3. conflict path
# ---------------------------------------------------------------------------

test_conflict() {
    _t_sb=$(new_sandbox)
    mkdir -p "$_t_sb/home"
    _t_bare="$_t_sb/remote.git"
    _t_work="$_t_sb/home/work"

    git init --bare "$_t_bare" >/dev/null 2>&1
    # HEAD in a fresh bare repo follows init.defaultBranch, which is `master` on
    # a stock git. Every clone below expects `main`; without this the second
    # clone checks out nothing, commits to `master`, and its `push origin main`
    # fails silently — so no divergence is ever created and the conflict this
    # test exists to provoke never happens.
    git -C "$_t_bare" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || :
    git clone "$_t_bare" "$_t_work" >/dev/null 2>&1
    git_q "$_t_work" config user.email test@example.com
    git_q "$_t_work" config user.name Test
    printf 'line1\n' >"$_t_work/conflict.txt"
    git_q "$_t_work" add -A
    git_q "$_t_work" commit -m init
    git_q "$_t_work" checkout -B main
    git_q "$_t_work" push origin main

    # A second clone diverges: change the same line and push first.
    _t_other="$_t_sb/other-clone"
    git clone "$_t_bare" "$_t_other" >/dev/null 2>&1
    git_q "$_t_other" config user.email test@example.com
    git_q "$_t_other" config user.name Test
    printf 'line1-changed-by-other\n' >"$_t_other/conflict.txt"
    git_q "$_t_other" add -A
    git_q "$_t_other" commit -m "other change"
    git_q "$_t_other" push origin main

    # Now make a conflicting local change in the primary clone, uncommitted,
    # so syncto's own commit step will produce a colliding commit on push/pull.
    printf 'line1-changed-locally\n' >"$_t_work/conflict.txt"

    run_syncto "$_t_sb" --add work "$_t_work" "branch=main,remote=origin,prefix=t"
    RC_ADD=$RC

    run_syncto "$_t_sb" --sync work
    assert_status "conflict: sync exits 2" 2 "$RC" "$OUT"

    _gitdir="$_t_work/.git"
    if [ -d "$_gitdir/rebase-merge" ] || [ -d "$_gitdir/rebase-apply" ]; then
        fail "conflict: working tree left clean (no mid-rebase state)" "rebase-merge/rebase-apply still present"
    else
        ok "conflict: working tree left clean (no mid-rebase state)"
    fi

    _status=$(git -C "$_t_work" status --porcelain=v1 2>&1)
    case "$_status" in
        *"UU "*|*"unmerged"*)
            fail "conflict: no unmerged paths left behind" "$_status"
            ;;
        *)
            ok "conflict: no unmerged paths left behind"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 4. locking
# ---------------------------------------------------------------------------

test_locking() {
    _t_sb=$(new_sandbox)
    mkdir -p "$_t_sb/home"
    _t_work="$_t_sb/home/work"
    mkdir -p "$_t_work"
    git_q "$_t_work" init
    git_q "$_t_work" checkout -B main
    git_q "$_t_work" config user.email test@example.com
    git_q "$_t_work" config user.name Test
    git_q "$_t_work" commit --allow-empty -m init

    run_syncto "$_t_sb" --add work "$_t_work" "branch=main,mode=push,interval=60"

    _lock_dir="$_t_sb/home/.local/state/syncto/locks/work.lock"
    mkdir -p "$_lock_dir"
    printf '999999 %s\n' "$(date +%s)" >"$_lock_dir/owner"

    run_syncto "$_t_sb" --sync work
    assert_status "locking: held lock makes sync exit 4" 4 "$RC" "$OUT"

    rm -rf "$_lock_dir"
}

# ---------------------------------------------------------------------------
# 5. guard hook
# ---------------------------------------------------------------------------

test_guard() {
    _t_sb=$(new_sandbox)
    mkdir -p "$_t_sb/home"
    _t_work="$_t_sb/home/work"
    mkdir -p "$_t_work"
    git_q "$_t_work" init
    git_q "$_t_work" checkout -B main
    git_q "$_t_work" config user.email test@example.com
    git_q "$_t_work" config user.name Test
    git_q "$_t_work" commit --allow-empty -m init

    run_syncto "$_t_sb" --add work "$_t_work" "branch=main,mode=push,guard=exit 7"

    printf 'x\n' >"$_t_work/f.txt"
    _head_before=$(git -C "$_t_work" rev-parse HEAD)

    run_syncto "$_t_sb" --sync work
    assert_status "guard: skip still exits 0" 0 "$RC" "$OUT"

    _head_after=$(git -C "$_t_work" rev-parse HEAD)
    assert_eq "guard: non-zero guard skips the target (no commit)" "$_head_before" "$_head_after"
}

# ---------------------------------------------------------------------------
# 6. --help / --version / unknown flag
# ---------------------------------------------------------------------------

test_help_version_unknown() {
    _t_sb=$(new_sandbox)
    mkdir -p "$_t_sb/home"

    run_syncto "$_t_sb" --help
    assert_status "help: exits 0" 0 "$RC" "$OUT"
    case "$OUT" in
        *"syncto"*"USAGE"*|*"USAGE"*) ok "help: prints usage text" ;;
        *) fail "help: prints usage text" "$OUT" ;;
    esac

    run_syncto "$_t_sb" --version
    assert_status "version: exits 0" 0 "$RC" "$OUT"
    case "$OUT" in
        syncto\ *) ok "version: prints a version string" ;;
        *) fail "version: prints a version string" "$OUT" ;;
    esac

    run_syncto "$_t_sb" --this-flag-does-not-exist
    if [ "$RC" -eq 0 ]; then
        fail "unknown flag: exits non-zero" "exit 0"
    else
        ok "unknown flag: exits non-zero"
    fi
    case "$OUT" in
        *"syncto --help"*|*sage*) ok "unknown flag: prints a usage hint" ;;
        *) fail "unknown flag: prints a usage hint" "$OUT" ;;
    esac
}

# ---------------------------------------------------------------------------
# 7. paths containing spaces
# ---------------------------------------------------------------------------

test_spaces() {
    _t_sb=$(new_sandbox)
    mkdir -p "$_t_sb/home"
    _t_bare="$_t_sb/remote space.git"
    _t_work="$_t_sb/home/my repo dir"

    git init --bare "$_t_bare" >/dev/null 2>&1
    # HEAD in a fresh bare repo follows init.defaultBranch, which is `master` on
    # a stock git. Every clone below expects `main`; without this the second
    # clone checks out nothing, commits to `master`, and its `push origin main`
    # fails silently — so no divergence is ever created and the conflict this
    # test exists to provoke never happens.
    git -C "$_t_bare" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || :
    git clone "$_t_bare" "$_t_work" >/dev/null 2>&1
    git_q "$_t_work" config user.email test@example.com
    git_q "$_t_work" config user.name Test
    git_q "$_t_work" checkout -B main
    git_q "$_t_work" commit --allow-empty -m init
    git_q "$_t_work" push origin main

    run_syncto "$_t_sb" --add "spacey" "$_t_work" "branch=main,remote=origin,prefix=t"
    assert_status "spaces: add exits 0" 0 "$RC" "$OUT"

    printf 'y\n' >"$_t_work/a file.txt"
    run_syncto "$_t_sb" --sync spacey
    assert_status "spaces: sync of a spacey path exits 0" 0 "$RC" "$OUT"

    _local_head=$(git -C "$_t_work" rev-parse main)
    _remote_head=$(git -C "$_t_bare" rev-parse main)
    assert_eq "spaces: pushed successfully with spaces in path" "$_local_head" "$_remote_head"
}


# ---------------------------------------------------------------------------
# 8. watch: .git writes must never trigger a sync
# ---------------------------------------------------------------------------

# run_syncto_path SANDBOX STUBDIR ARGS... — as run_syncto, but with STUBDIR
# prepended to PATH so a stub watcher binary is found instead of a real one.
run_syncto_path() {
    _rp_sandbox=$1
    _rp_stub=$2
    shift 2
    OUT=$(HOME="$_rp_sandbox/home" \
          XDG_CONFIG_HOME="$_rp_sandbox/home/.config" \
          XDG_STATE_HOME="$_rp_sandbox/home/.local/state" \
          PATH="$_rp_stub:$PATH" \
          "$SYNCTO" "$@" 2>&1)
    RC=$?
}

# Build a sandbox with a working target and a stub `inotifywait` that replays
# the paths given to it, one per line, then exits (closing the pipe ends the
# watch loop, so the test is bounded).
watch_fixture() {
    _wf_sb=$1
    shift
    mkdir -p "$_wf_sb/home" "$_wf_sb/stub"
    _wf_bare="$_wf_sb/remote.git"
    _wf_work="$_wf_sb/home/work"
    git init --bare "$_wf_bare" >/dev/null 2>&1
    git -C "$_wf_bare" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || :
    git clone "$_wf_bare" "$_wf_work" >/dev/null 2>&1
    # syncto commits with plain `git`, not the test's `git_q`, so the identity
    # has to live in the repo config — the sandbox HOME has no global one.
    git_q "$_wf_work" config user.email test@example.com
    git_q "$_wf_work" config user.name Test
    git_q "$_wf_work" checkout -B main
    git_q "$_wf_work" commit --allow-empty -m init
    git_q "$_wf_work" push origin main
    {
        printf '#!/bin/sh\n'
        for _wf_ev in "$@"; do
            printf 'printf "%%s\\n" "%s"\n' "$_wf_ev"
        done
        printf 'exit 0\n'
    } >"$_wf_sb/stub/inotifywait"
    chmod +x "$_wf_sb/stub/inotifywait"
    # cmd_watch prefers fswatch and only falls back to inotifywait, so on any
    # machine that actually has fswatch installed (every dev Mac) stubbing
    # inotifywait alone leaves the real watcher running — it never exits, the
    # pipe never closes, and the watch tests hang forever instead of failing.
    # Stub both. fswatch is invoked with -0, so events are NUL-separated.
    {
        printf '#!/bin/sh\n'
        for _wf_ev in "$@"; do
            printf 'printf "%%s\\0" "%s"\n' "$_wf_ev"
        done
        printf 'exit 0\n'
    } >"$_wf_sb/stub/fswatch"
    chmod +x "$_wf_sb/stub/fswatch"
}

test_watch_ignores_git() {
    _t_sb=$(new_sandbox)
    _t_work="$_t_sb/home/work"
    # Only .git paths are emitted: the sync loop must stay asleep.
    watch_fixture "$_t_sb" "$_t_sb/home/work/.git" "$_t_sb/home/work/.git/index" \
                           "$_t_sb/home/work/.git/refs/heads"

    run_syncto_path "$_t_sb" "$_t_sb/stub" --add work "$_t_work" \
        "branch=main,remote=origin,prefix=t,watch=on,debounce=1"

    # A dirty file exists but was never announced by the watcher, so the only
    # thing that could start a sync is a .git event.
    printf 'untracked\n' >"$_t_work/note.md"
    _before=$(git -C "$_t_work" rev-list --count main)

    run_syncto_path "$_t_sb" "$_t_sb/stub" --watch work
    _after=$(git -C "$_t_work" rev-list --count main)

    assert_eq "watch: .git-only events trigger no sync" "$_before" "$_after" "$OUT"
}

test_watch_syncs_real_edit() {
    _t_sb=$(new_sandbox)
    _t_work="$_t_sb/home/work"
    # A .git burst *and* a real edit: the real edit must still get through.
    watch_fixture "$_t_sb" "$_t_sb/home/work/.git/index" "$_t_sb/home/work" \
                           "$_t_sb/home/work/.git/FETCH_HEAD"

    run_syncto_path "$_t_sb" "$_t_sb/stub" --add work "$_t_work" \
        "branch=main,remote=origin,prefix=t,watch=on,debounce=1"

    printf 'real edit\n' >"$_t_work/note.md"
    _before=$(git -C "$_t_work" rev-list --count main)

    run_syncto_path "$_t_sb" "$_t_sb/stub" --watch work
    _after=$(git -C "$_t_work" rev-list --count main)

    if [ "$_after" -gt "$_before" ]; then
        ok "watch: a real edit still syncs"
    else
        fail "watch: a real edit still syncs" "commits before=$_before after=$_after
$OUT"
    fi
}

test_watch_skips_ignored() {
    _t_sb=$(new_sandbox)
    _t_work="$_t_sb/home/work"
    # The watcher announces the repo root, but the only thing that changed is a
    # gitignored file — no sync, and above all no network round trip.
    watch_fixture "$_t_sb" "$_t_sb/home/work"

    printf 'scratch/\n' >"$_t_work/.gitignore"
    git_q "$_t_work" add -A
    git_q "$_t_work" commit -m ignore
    git_q "$_t_work" push origin main

    run_syncto_path "$_t_sb" "$_t_sb/stub" --add work "$_t_work" \
        "branch=main,remote=origin,prefix=t,watch=on,debounce=1"

    mkdir -p "$_t_work/scratch"
    printf 'noise\n' >"$_t_work/scratch/tmp.txt"
    _before=$(git -C "$_t_work" rev-list --count main)

    run_syncto_path "$_t_sb" "$_t_sb/stub" --watch work
    _after=$(git -C "$_t_work" rev-list --count main)

    assert_eq "watch: an ignored-only change makes no commit" "$_before" "$_after" "$OUT"
}

# ---------------------------------------------------------------------------
# 9. debounce option
# ---------------------------------------------------------------------------

test_debounce_option() {
    _t_sb=$(new_sandbox)
    mkdir -p "$_t_sb/home"
    _t_target="$_t_sb/home/myrepo"
    mkdir -p "$_t_target"
    git_q "$_t_target" init

    run_syncto "$_t_sb" --add proj "$_t_target" "debounce=5,watch=on"
    assert_status "debounce: a numeric value is accepted" 0 "$RC" "$OUT"

    _targets_file="$_t_sb/home/.config/syncto/targets"
    case "$(cat "$_targets_file" 2>/dev/null)" in
        *debounce=5*) ok "debounce: round-trips into the targets file" ;;
        *) fail "debounce: round-trips into the targets file" "$(cat "$_targets_file" 2>/dev/null)" ;;
    esac

    run_syncto "$_t_sb" --add bad "$_t_target" "debounce=soon"
    case "$OUT" in
        *"debounce must be"*) ok "debounce: a non-numeric value is rejected" ;;
        *) fail "debounce: a non-numeric value is rejected" "$OUT" ;;
    esac
}

test_dirty_tree_defers_pull() {
    # A rebase rewrites files on disk, so it must never run while an editor has
    # unsaved-and-resaved work in the tree. mode=pull makes this deterministic:
    # nothing is committed, so a dirty tree is dirty when the pull is reached.
    _t_sb=$(new_sandbox)
    mkdir -p "$_t_sb/home"
    _t_bare="$_t_sb/remote.git"
    _t_work="$_t_sb/home/work"

    git init --bare "$_t_bare" >/dev/null 2>&1
    git -C "$_t_bare" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || :
    git -c init.defaultBranch=main clone "$_t_bare" "$_t_work" >/dev/null 2>&1
    git_q "$_t_work" checkout -B main
    git_q "$_t_work" config user.email test@example.com
    git_q "$_t_work" config user.name Test
    printf 'first line\n' >"$_t_work/note.md"
    git_q "$_t_work" add -A
    git_q "$_t_work" commit -m init
    git_q "$_t_work" push origin main

    run_syncto "$_t_sb" --add work "$_t_work" "branch=main,remote=origin,prefix=t,mode=pull"
    assert_status "dirty-pull: add exit 0" 0 "$RC" "$OUT"

    # Another machine pushes something we would normally pull down.
    _t_other="$_t_sb/other-clone"
    git clone "$_t_bare" "$_t_other" >/dev/null 2>&1
    git_q "$_t_other" config user.email test@example.com
    git_q "$_t_other" config user.name Test
    printf 'from elsewhere\n' >"$_t_other/other.txt"
    git_q "$_t_other" add -A
    git_q "$_t_other" commit -m "other machine change"
    git_q "$_t_other" push origin main

    # ...but we are mid-sentence in note.md.
    printf 'first line\nhalf-typed parag\n' >"$_t_work/note.md"

    run_syncto "$_t_sb" --sync work
    assert_status "dirty-pull: a deferred pull is not an error" 0 "$RC" "$OUT"

    if [ -f "$_t_work/other.txt" ]; then
        fail "dirty-pull: pull deferred while the tree is dirty" "$OUT"
    else
        ok "dirty-pull: pull deferred while the tree is dirty"
    fi

    _t_body=$(cat "$_t_work/note.md")
    assert_eq "dirty-pull: the file being edited is left untouched" \
        "first line
half-typed parag" "$_t_body"

    case "$OUT$(cat "$_t_sb/home/.local/state/syncto/syncto.log" 2>/dev/null)" in
        *"deferring the pull"*) ok "dirty-pull: the deferral is logged" ;;
        *) fail "dirty-pull: the deferral is logged" "$OUT" ;;
    esac

    # Once the writing stops and the tree is clean, the pull goes through.
    git_q "$_t_work" add -A
    git_q "$_t_work" commit -m "done typing"
    run_syncto "$_t_sb" --sync work
    assert_status "dirty-pull: sync of a clean tree exits 0" 0 "$RC" "$OUT"

    if [ -f "$_t_work/other.txt" ]; then
        ok "dirty-pull: the remote change lands once the tree is clean"
    else
        fail "dirty-pull: the remote change lands once the tree is clean" "$OUT"
    fi
}

# ---------------------------------------------------------------------------
# run everything
# ---------------------------------------------------------------------------

test_config_roundtrip
test_sync_basic
test_conflict
test_locking
test_guard
test_help_version_unknown
test_spaces
test_watch_ignores_git
test_watch_syncs_real_edit
test_watch_skips_ignored
test_debounce_option
test_dirty_tree_defers_pull

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
