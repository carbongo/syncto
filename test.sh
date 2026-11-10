#!/usr/bin/env bash
# test.sh: syncto's test suite. Each test runs in its own mktemp -d sandbox
# with HOME and the XDG dirs inside it. Usage: ./test.sh [-v]

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

# new_sandbox -> prints a fresh sandbox root, registered for cleanup.
new_sandbox() {
    _ns_dir=$(mktemp -d "${TMPDIR:-/tmp}/syncto-test.XXXXXX")
    SANDBOXES="$SANDBOXES $_ns_dir"
    printf '%s' "$_ns_dir"
}

# run_syncto SANDBOX ARGS...: runs syncto.sh with HOME and the XDG dirs inside
# SANDBOX/home; sets OUT and RC.
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
    # git_q PATH ARGS...: quiet git with a fixed identity, no gpg signing.
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

    run_syncto "$_t_sb" add proj "$_t_target" "interval=60,watch=on,prefix=proj"
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

    # shellcheck disable=SC2088 # a literal ~ is the point
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
        *"not synced yet"*"on save"*) ok "status: a new watched target is not synced yet, on save" ;;
        *) fail "status: a new watched target is not synced yet, on save" "$OUT" ;;
    esac
    case "$OUT" in
        *"Background: off"*"syncto start"*) ok "status: says background is off and how to start it" ;;
        *) fail "status: says background is off and how to start it" "$OUT" ;;
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

    run_syncto "$_t_sb" remove proj
    assert_status "remove: exit 0" 0 "$RC" "$OUT"

    if grep -Fq "$(printf 'proj\t')" "$_targets_file" 2>/dev/null; then
        fail "remove: target gone from targets file" "$(cat "$_targets_file")"
    else
        ok "remove: target gone from targets file"
    fi

    run_syncto "$_t_sb" status
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

    run_syncto "$_t_sb" add work "$_t_work" "branch=main,remote=origin,prefix=t"
    assert_status "sync-basic: add exit 0" 0 "$RC" "$OUT"

    # new file committed and pushed
    printf 'hello\n' >"$_t_work/newfile.txt"
    run_syncto "$_t_sb" sync work
    assert_status "sync-basic: sync of new file exits 0" 0 "$RC" "$OUT"
    run_syncto "$_t_sb" status
    case "$OUT" in
        *"✓ synced just now"*) ok "status: a synced target says synced just now" ;;
        *) fail "status: a synced target says synced just now" "$OUT" ;;
    esac

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
    run_syncto "$_t_sb" sync work
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

    run_syncto "$_t_sb" sync work
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
    # A bare repo's HEAD follows init.defaultBranch: pin it to main, or the
    # clones below never diverge.
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

    run_syncto "$_t_sb" add work "$_t_work" "branch=main,remote=origin,prefix=t"

    run_syncto "$_t_sb" sync work
    assert_status "conflict: sync exits 2" 2 "$RC" "$OUT"
    _t_rc=$RC _t_out=$OUT
    run_syncto "$_t_sb" status
    case "$OUT" in
        *"needs you"*"both sides changed conflict.txt"*"fix: "*"git rebase --continue"*)
            ok "status: a conflict names the file and the fix" ;;
        *) fail "status: a conflict names the file and the fix" "$OUT" ;;
    esac
    RC=$_t_rc OUT=$_t_out

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

    # Interactive runs echo the conflict to stderr; -d must not, because the
    # service units point stderr at the log file and every line would land twice.
    case "$OUT" in
        *"level=conflict"*) ok "conflict: interactive run echoes the conflict to stderr" ;;
        *) fail "conflict: interactive run echoes the conflict to stderr" "$OUT" ;;
    esac
    rm -rf "$_t_sb/home/.local/state/syncto/last"   # make the target due again
    run_syncto "$_t_sb" run
    assert_status "conflict: -d hits the conflict too" 2 "$RC" "$OUT"
    case "$OUT" in
        *"level=conflict"*) fail "conflict: -d does not echo to stderr" "$OUT" ;;
        *) ok "conflict: -d does not echo to stderr" ;;
    esac
}

# ---------------------------------------------------------------------------
# network failure: a dropped connection is not a conflict
# ---------------------------------------------------------------------------

# fake_ssh_target MESSAGE [EXTRA_OPTIONS]: sets _t_sb/_t_work to a target
# whose ssh always fails with MESSAGE on stderr, the way a real one would.
fake_ssh_target() {
    _t_sb=$(new_sandbox)
    mkdir -p "$_t_sb/home/work"
    _t_work="$_t_sb/home/work"
    git_q "$_t_work" init
    git_q "$_t_work" checkout -B main
    git_q "$_t_work" commit --allow-empty -m init
    git_q "$_t_work" remote add origin "ssh://git@example.invalid/x.git"
    printf '#!/bin/sh\necho "%s" >&2\nexit 255\n' "$1" >"$_t_sb/fake-ssh"
    chmod +x "$_t_sb/fake-ssh"
    run_syncto "$_t_sb" add work "$_t_work" "branch=main,remote=origin,prefix=t,ssh=$_t_sb/fake-ssh,notify=touch $_t_sb/notified${2:-}"
}

# assert_log NAME PATTERN [FORBIDDEN]: the sandbox log matches PATTERN and,
# if given, does not match FORBIDDEN.
# shellcheck disable=SC2254 # PATTERN and FORBIDDEN are globs
assert_log() {
    _al_log=$(cat "$_t_sb/home/.local/state/syncto/syncto.log" 2>/dev/null)
    case "$_al_log" in
        ${3:-__none__}) fail "$1" "$_al_log"; return 0 ;;
    esac
    case "$_al_log" in
        $2) ok "$1" ;;
        *) fail "$1" "$_al_log" ;;
    esac
}

test_network_error_not_conflict() {
    # Fails the way GitHub's ssh-over-443 does when it drops us.
    fake_ssh_target "Connection reset by 140.82.121.36 port 443"
    run_syncto "$_t_sb" sync work
    assert_status "network: dropped connection exits 0" 0 "$RC" "$OUT"
    if [ -e "$_t_sb/notified" ]; then
        fail "network: dropped connection does not notify" "notify hook ran"
    else
        ok "network: dropped connection does not notify"
    fi
    _log=$(cat "$_t_sb/home/.local/state/syncto/syncto.log" 2>/dev/null)
    case "$_log" in
        *"level=conflict"*) fail "network: logged as warn, not conflict" "$_log" ;;
        *"network unreachable"*) ok "network: logged as warn, not conflict" ;;
        *) fail "network: logged as warn, not conflict" "$_log" ;;
    esac
    run_syncto "$_t_sb" status
    case "$OUT" in
        *"offline, retrying"*"Connection reset by"*) ok "status: offline with the reason" ;;
        *) fail "status: offline with the reason" "$OUT" ;;
    esac
}

test_closed_by_remote_host() {
    fake_ssh_target "Connection to example.invalid closed by remote host."
    run_syncto "$_t_sb" sync work
    assert_status "network: closed by remote host exits 0" 0 "$RC" "$OUT"
    assert_log "network: closed by remote host logged as warn, not conflict" \
        '*network unreachable*' '*level=conflict*'
}

test_push_network_error() {
    fake_ssh_target "ssh: connect to host example.invalid port 443: Operation timed out" ",mode=push"
    run_syncto "$_t_sb" sync work
    assert_status "network: push timeout exits 0" 0 "$RC" "$OUT"
    assert_log "network: push timeout logged as warn, not error" \
        '*network unreachable*' '*level=error*'
    assert_log "network: push timeout is not logged as a success" \
        '*network unreachable*' '*sync ok*'
}

test_auth_error_not_conflict() {
    fake_ssh_target "git@example.invalid: Permission denied (publickey)."
    run_syncto "$_t_sb" sync work
    assert_status "auth: refused key exits 1" 1 "$RC" "$OUT"
    if [ -e "$_t_sb/notified" ]; then
        fail "auth: refused key does not notify" "notify hook ran"
    else
        ok "auth: refused key does not notify"
    fi
    assert_log "auth: logged as error, not conflict" \
        '*level=error*authentication refused*' '*level=conflict*'
    run_syncto "$_t_sb" status
    case "$OUT" in
        *"failing"*"refused the credentials"*"fix: "*) ok "status: refused credentials say so" ;;
        *) fail "status: refused credentials say so" "$OUT" ;;
    esac
}

test_missing_remote() {
    _t_sb=$(new_sandbox)
    _t_work="$_t_sb/home/work"
    mkdir -p "$_t_work"
    git_q "$_t_work" init
    git_q "$_t_work" checkout -B main
    git_q "$_t_work" commit --allow-empty -m init
    run_syncto "$_t_sb" add work "$_t_work" "branch=main,notify=touch $_t_sb/notified"
    run_syncto "$_t_sb" sync work
    assert_status "remote: a missing remote exits 3" 3 "$RC" "$OUT"
    if [ -e "$_t_sb/notified" ]; then
        fail "remote: a missing remote does not notify" "notify hook ran"
    else
        ok "remote: a missing remote does not notify"
    fi
    assert_log "remote: logged as error, not conflict" '*level=error*not found*' '*level=conflict*'
    run_syncto "$_t_sb" status
    case "$OUT" in
        *"failing"*"remote 'origin' is missing"*"git remote add origin URL"*) ok "status: a missing remote says how to add it" ;;
        *) fail "status: a missing remote says how to add it" "$OUT" ;;
    esac
}

test_add_failure_logged() {
    fake_ssh_target "unused"
    printf 'x\n' >"$_t_work/new.txt"
    : >"$_t_work/.git/index.lock"
    run_syncto "$_t_sb" sync work
    assert_status "add: failing git add exits 1" 1 "$RC" "$OUT"
    assert_log "add: git's own error is logged" '*git add -A failed: *index.lock*'
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

    run_syncto "$_t_sb" add work "$_t_work" "branch=main,mode=push,interval=60"

    _lock_dir="$_t_sb/home/.local/state/syncto/locks/work.lock"

    # A live owner keeps its lock.
    sleep 30 &
    _t_live=$!
    mkdir -p "$_lock_dir"
    printf '%s %s\n' "$_t_live" "$(date +%s)" >"$_lock_dir/owner"
    run_syncto "$_t_sb" sync work
    assert_status "locking: a live owner's lock makes sync exit 4" 4 "$RC" "$OUT"
    kill "$_t_live" 2>/dev/null
    wait "$_t_live" 2>/dev/null

    # A lock whose owner is still being written is busy, not stale.
    rm -f "$_lock_dir/owner"
    run_syncto "$_t_sb" sync work
    assert_status "locking: a lock with no owner yet makes sync exit 4" 4 "$RC" "$OUT"

    # A dead owner's lock is taken over.
    sh -c 'exit 0' &
    _t_dead=$!
    wait "$_t_dead"
    printf '%s %s\n' "$_t_dead" "$(date +%s)" >"$_lock_dir/owner"
    run_syncto "$_t_sb" sync work
    case "$RC" in
        4) fail "locking: a dead owner's lock is taken over" "exit 4" ;;
        *) assert_log "locking: a dead owner's lock is taken over" '*took over a stale lock: run * is gone*' ;;
    esac
    if [ -d "$_lock_dir" ]; then
        fail "locking: the lock is released after the sync" "still there"
    else
        ok "locking: the lock is released after the sync"
    fi

    # Two runs at once: exactly one syncs, the other finds the lock held.
    run_syncto "$_t_sb" edit work "guard=sleep 2"
    ( run_syncto "$_t_sb" sync work; echo "$RC" >"$_t_sb/rc1" ) &
    ( run_syncto "$_t_sb" sync work; echo "$RC" >"$_t_sb/rc2" ) &
    wait
    case "$(cat "$_t_sb/rc1")$(cat "$_t_sb/rc2")" in
        [0-3]4|4[0-3]) ok "locking: of two runs at once one syncs and one exits 4" ;;
        *) fail "locking: of two runs at once one syncs and one exits 4" "$(cat "$_t_sb/rc1") $(cat "$_t_sb/rc2")" ;;
    esac
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

    run_syncto "$_t_sb" add work "$_t_work" "branch=main,mode=push,guard=exit 7"

    printf 'x\n' >"$_t_work/f.txt"
    _head_before=$(git -C "$_t_work" rev-parse HEAD)

    run_syncto "$_t_sb" sync work
    assert_status "guard: skip still exits 0" 0 "$RC" "$OUT"

    _head_after=$(git -C "$_t_work" rev-parse HEAD)
    assert_eq "guard: non-zero guard skips the target (no commit)" "$_head_before" "$_head_after"
}

# ---------------------------------------------------------------------------
# 5b. staleness alarm
# ---------------------------------------------------------------------------

# A guard that never passes again is the failure this exists for: every pass is
# individually "fine" and silent, and nothing syncs for hours.
test_stale_alarm() {
    _t_sb=$(new_sandbox)
    mkdir -p "$_t_sb/home"
    _t_work="$_t_sb/home/work"
    _t_alert="$_t_sb/home/alert.txt"
    mkdir -p "$_t_work"
    git_q "$_t_work" init
    git_q "$_t_work" checkout -B main
    git_q "$_t_work" config user.email test@example.com
    git_q "$_t_work" config user.name Test
    git_q "$_t_work" commit --allow-empty -m init

    run_syncto "$_t_sb" add work "$_t_work" \
        "branch=main,mode=push,stale=600,guard=exit 7,notify=printf '%s' \"\$SYNCTO_MESSAGE\" >>$_t_alert"

    _ok_file="$_t_sb/home/.local/state/syncto/lastok/work"

    # First pass seeds the clock instead of alerting on a brand-new target.
    run_syncto "$_t_sb" sync work
    if [ -f "$_t_alert" ]; then
        fail "stale: a never-synced target does not alert on its first pass" "$(cat "$_t_alert")"
    else
        ok "stale: a never-synced target does not alert on its first pass"
    fi
    if [ -f "$_ok_file" ]; then
        ok "stale: the first pass seeds the last-success clock"
    else
        fail "stale: the first pass seeds the last-success clock" "no $_ok_file"
    fi

    # Age the clock past the limit: the guard is still failing, so nothing synced.
    printf '%s\n' "$(( $(date +%s) - 4000 ))" >"$_ok_file"
    run_syncto "$_t_sb" sync work
    assert_status "stale: an alerting pass still exits 0" 0 "$RC" "$OUT"
    case "$(cat "$_t_alert" 2>/dev/null)" in
        *"has not synced"*) ok "stale: a stuck guard fires the notify hook" ;;
        *) fail "stale: a stuck guard fires the notify hook" "alert: $(cat "$_t_alert" 2>/dev/null)" ;;
    esac

    # Throttled: the same alert does not go out on every following pass.
    _t_size=$(wc -c <"$_t_alert")
    run_syncto "$_t_sb" sync work
    assert_eq "stale: the alert is throttled, not repeated every pass" \
        "$_t_size" "$(wc -c <"$_t_alert")"

    # A working target never alerts: drop the guard, sync, clock resets.
    run_syncto "$_t_sb" remove work
    run_syncto "$_t_sb" add work "$_t_work" "branch=main,mode=push,stale=600"
    printf 'x\n' >"$_t_work/f.txt"
    run_syncto "$_t_sb" sync work
    _t_now=$(date +%s)
    _t_last=$(cat "$_ok_file" 2>/dev/null || printf '0')
    if [ "$((_t_now - _t_last))" -lt 60 ]; then
        ok "stale: a successful sync refreshes the last-success clock"
    else
        fail "stale: a successful sync refreshes the last-success clock" "last_ok=$_t_last now=$_t_now"
    fi
}

test_stale_off() {
    _t_sb=$(new_sandbox)
    mkdir -p "$_t_sb/home"
    _t_work="$_t_sb/home/work"
    _t_alert="$_t_sb/home/alert.txt"
    mkdir -p "$_t_work"
    git_q "$_t_work" init
    git_q "$_t_work" checkout -B main
    git_q "$_t_work" config user.email test@example.com
    git_q "$_t_work" config user.name Test
    git_q "$_t_work" commit --allow-empty -m init

    run_syncto "$_t_sb" add work "$_t_work" \
        "branch=main,mode=push,stale=off,guard=exit 7,notify=printf '%s' \"\$SYNCTO_MESSAGE\" >>$_t_alert"
    run_syncto "$_t_sb" sync work
    printf '%s\n' "0" >"$_t_sb/home/.local/state/syncto/lastok/work" 2>/dev/null || :
    run_syncto "$_t_sb" sync work
    if [ -f "$_t_alert" ]; then
        fail "stale: stale=off never alerts" "$(cat "$_t_alert")"
    else
        ok "stale: stale=off never alerts"
    fi
}

# ---------------------------------------------------------------------------
# 6. help / version / unknown input
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
        *"syncto help"*) ok "unknown flag: prints a usage hint" ;;
        *) fail "unknown flag: prints a usage hint" "$OUT" ;;
    esac

    run_syncto "$_t_sb" help
    assert_status "help command: exits 0" 0 "$RC" "$OUT"

    run_syncto "$_t_sb" frobnicate
    case "$RC:$OUT" in
        0:*) fail "unknown command: exits non-zero" "exit 0" ;;
        *"unknown command"*"syncto help"*) ok "unknown command: names it and points to help" ;;
        *) fail "unknown command: names it and points to help" "$OUT" ;;
    esac

    run_syncto "$_t_sb" -d
    case "$RC:$OUT" in
        1:*"replaced by commands"*"syncto start"*) ok "old flag: exits 1 and says how to update the scheduler" ;;
        *) fail "old flag: exits 1 and says how to update the scheduler" "$RC $OUT" ;;
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
    # A bare repo's HEAD follows init.defaultBranch: pin it to main, or the
    # clones below never diverge.
    git -C "$_t_bare" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || :
    git clone "$_t_bare" "$_t_work" >/dev/null 2>&1
    git_q "$_t_work" config user.email test@example.com
    git_q "$_t_work" config user.name Test
    git_q "$_t_work" checkout -B main
    git_q "$_t_work" commit --allow-empty -m init
    git_q "$_t_work" push origin main

    run_syncto "$_t_sb" add "spacey" "$_t_work" "branch=main,remote=origin,prefix=t"
    assert_status "spaces: add exits 0" 0 "$RC" "$OUT"

    printf 'y\n' >"$_t_work/a file.txt"
    run_syncto "$_t_sb" sync spacey
    assert_status "spaces: sync of a spacey path exits 0" 0 "$RC" "$OUT"

    _local_head=$(git -C "$_t_work" rev-parse main)
    _remote_head=$(git -C "$_t_bare" rev-parse main)
    assert_eq "spaces: pushed successfully with spaces in path" "$_local_head" "$_remote_head"
}


# ---------------------------------------------------------------------------
# 8. watch: .git writes must never trigger a sync
# ---------------------------------------------------------------------------

# run_syncto_path SANDBOX STUBDIR ARGS...: as run_syncto, but with STUBDIR
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

# Sandbox with a working target and a stub watcher that replays the given
# paths, one per line, then exits (which ends the watch loop).
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
    # has to live in the repo config: the sandbox HOME has no global one.
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
    # Stub fswatch too: cmd_watch prefers it, and a real one never exits.
    # fswatch runs with -0, so events are NUL separated.
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

    run_syncto_path "$_t_sb" "$_t_sb/stub" add work "$_t_work" \
        "branch=main,remote=origin,prefix=t,watch=on,debounce=1"

    # A dirty file exists but was never announced by the watcher, so the only
    # thing that could start a sync is a .git event.
    printf 'untracked\n' >"$_t_work/note.md"
    _before=$(git -C "$_t_work" rev-list --count main)

    run_syncto_path "$_t_sb" "$_t_sb/stub" watch work
    _after=$(git -C "$_t_work" rev-list --count main)

    assert_eq "watch: .git-only events trigger no sync" "$_before" "$_after" "$OUT"
}

test_watch_syncs_real_edit() {
    _t_sb=$(new_sandbox)
    _t_work="$_t_sb/home/work"
    # A .git burst *and* a real edit: the real edit must still get through.
    watch_fixture "$_t_sb" "$_t_sb/home/work/.git/index" "$_t_sb/home/work" \
                           "$_t_sb/home/work/.git/FETCH_HEAD"

    run_syncto_path "$_t_sb" "$_t_sb/stub" add work "$_t_work" \
        "branch=main,remote=origin,prefix=t,watch=on,debounce=1"

    printf 'real edit\n' >"$_t_work/note.md"
    _before=$(git -C "$_t_work" rev-list --count main)

    run_syncto_path "$_t_sb" "$_t_sb/stub" watch work
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
    # gitignored file: no sync, and no network round trip.
    watch_fixture "$_t_sb" "$_t_sb/home/work"

    printf 'scratch/\n' >"$_t_work/.gitignore"
    git_q "$_t_work" add -A
    git_q "$_t_work" commit -m ignore
    git_q "$_t_work" push origin main

    run_syncto_path "$_t_sb" "$_t_sb/stub" add work "$_t_work" \
        "branch=main,remote=origin,prefix=t,watch=on,debounce=1"

    mkdir -p "$_t_work/scratch"
    printf 'noise\n' >"$_t_work/scratch/tmp.txt"
    _before=$(git -C "$_t_work" rev-list --count main)

    run_syncto_path "$_t_sb" "$_t_sb/stub" watch work
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

    run_syncto "$_t_sb" add proj "$_t_target" "debounce=5,watch=on"
    assert_status "debounce: a numeric value is accepted" 0 "$RC" "$OUT"

    _targets_file="$_t_sb/home/.config/syncto/targets"
    case "$(cat "$_targets_file" 2>/dev/null)" in
        *debounce=5*) ok "debounce: round-trips into the targets file" ;;
        *) fail "debounce: round-trips into the targets file" "$(cat "$_targets_file" 2>/dev/null)" ;;
    esac

    run_syncto "$_t_sb" add bad "$_t_target" "debounce=soon"
    case "$OUT" in
        *"debounce must be"*) ok "debounce: a non-numeric value is rejected" ;;
        *) fail "debounce: a non-numeric value is rejected" "$OUT" ;;
    esac
}

test_dirty_tree_defers_pull() {
    # A dirty tree defers the pull. mode=pull commits nothing, so the tree
    # is still dirty when the pull is reached.
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

    run_syncto "$_t_sb" add work "$_t_work" "branch=main,remote=origin,prefix=t,mode=pull"
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

    run_syncto "$_t_sb" sync work
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
    run_syncto "$_t_sb" sync work
    assert_status "dirty-pull: sync of a clean tree exits 0" 0 "$RC" "$OUT"

    if [ -f "$_t_work/other.txt" ]; then
        ok "dirty-pull: the remote change lands once the tree is clean"
    else
        fail "dirty-pull: the remote change lands once the tree is clean" "$OUT"
    fi
}

# ---------------------------------------------------------------------------
# 11. remote_poll: the watch daemon pulls a push it was never told about
# ---------------------------------------------------------------------------

test_remote_poll() {
    _t_sb=$(new_sandbox)
    _t_work="$_t_sb/home/work"
    watch_fixture "$_t_sb"
    # Watchers that report nothing and stay up long enough for a few poll ticks.
    printf '#!/bin/sh\nsleep 4\nexit 0\n' >"$_t_sb/stub/fswatch"
    cp "$_t_sb/stub/fswatch" "$_t_sb/stub/inotifywait"

    run_syncto_path "$_t_sb" "$_t_sb/stub" add work "$_t_work" \
        "branch=main,remote=origin,prefix=t,watch=on,remote_poll=1"
    assert_status "remote_poll: a numeric value is accepted" 0 "$RC" "$OUT"

    _t_log="$_t_sb/home/.local/state/syncto/syncto.log"
    run_syncto_path "$_t_sb" "$_t_sb/stub" watch work
    if grep -q 'remote_poll:' "$_t_log" 2>/dev/null; then
        fail "remote_poll: an unchanged remote triggers no sync" "$(cat "$_t_log")"
    else
        ok "remote_poll: an unchanged remote triggers no sync"
    fi

    _t_other="$_t_sb/other-clone"
    git clone "$_t_sb/remote.git" "$_t_other" >/dev/null 2>&1
    printf 'from elsewhere\n' >"$_t_other/other.txt"
    git_q "$_t_other" add -A
    git_q "$_t_other" commit -m "other machine change"
    git_q "$_t_other" push origin main

    run_syncto_path "$_t_sb" "$_t_sb/stub" watch work
    if [ -f "$_t_work/other.txt" ]; then
        ok "remote_poll: a remote push is pulled without any local event"
    else
        fail "remote_poll: a remote push is pulled without any local event" "$OUT
$(cat "$_t_log" 2>/dev/null)"
    fi

    run_syncto "$_t_sb" add bad "$_t_work" "remote_poll=soon"
    case "$RC" in
        0) fail "remote_poll: a non-numeric value is rejected" "$OUT" ;;
        *) ok "remote_poll: a non-numeric value is rejected" ;;
    esac
}

# ---------------------------------------------------------------------------
# edit NAME key=value
# ---------------------------------------------------------------------------

test_edit_options() {
    _t_sb=$(new_sandbox)
    _t_target="$_t_sb/home/proj"
    mkdir -p "$_t_target"
    git_q "$_t_target" init
    _t_file="$_t_sb/home/.config/syncto/targets"
    run_syncto "$_t_sb" add proj "$_t_target" "interval=60,prefix=p"

    run_syncto "$_t_sb" edit proj watch=on "notify=echo a\,b"
    assert_status "edit: exits 0" 0 "$RC" "$OUT"
    _t_line=$(grep -F "$(printf 'proj\t')" "$_t_file")
    case "$_t_line" in
        *interval=60*prefix=p*watch=on*'notify=echo a\,b'*) ok "edit: merges new options, keeps the rest, escapes commas" ;;
        *) fail "edit: merges new options, keeps the rest, escapes commas" "$_t_line" ;;
    esac
    case "$OUT" in
        *"syncto start"*) ok "edit: a watch change says to run syncto start" ;;
        *) fail "edit: a watch change says to run syncto start" "$OUT" ;;
    esac

    run_syncto "$_t_sb" edit proj interval=
    _t_line=$(grep -F "$(printf 'proj\t')" "$_t_file")
    case "$_t_line" in
        *interval=*) fail "edit: key= resets an option" "$_t_line" ;;
        *prefix=p*) ok "edit: key= resets an option" ;;
        *) fail "edit: key= resets an option" "$_t_line" ;;
    esac

    run_syncto "$_t_sb" edit proj colour=blue
    assert_status "edit: an unknown option exits 3" 3 "$RC" "$OUT"
    run_syncto "$_t_sb" edit nope watch=on
    assert_status "edit: an unknown target exits 3" 3 "$RC" "$OUT"
}

# ---------------------------------------------------------------------------
# paused=on
# ---------------------------------------------------------------------------

test_paused() {
    _t_sb=$(new_sandbox)
    mkdir -p "$_t_sb/home"
    _t_bare="$_t_sb/remote.git"
    _t_work="$_t_sb/home/work"
    git init -q --bare "$_t_bare"
    git -C "$_t_bare" symbolic-ref HEAD refs/heads/main
    git clone -q "$_t_bare" "$_t_work" 2>/dev/null
    git_q "$_t_work" checkout -B main
    git_q "$_t_work" commit --allow-empty -m init
    git_q "$_t_work" push -q origin main
    git -C "$_t_work" config user.email t@example.invalid
    git -C "$_t_work" config user.name t
    run_syncto "$_t_sb" add work "$_t_work" "branch=main,remote=origin,prefix=t,paused=on"

    printf 'x\n' >"$_t_work/a.txt"
    run_syncto "$_t_sb" sync
    assert_status "paused: plain sync exits 0" 0 "$RC" "$OUT"
    if [ -n "$(git -C "$_t_work" status --porcelain)" ]; then
        ok "paused: plain sync leaves it alone"
    else
        fail "paused: plain sync leaves it alone" "a.txt was committed"
    fi
    run_syncto "$_t_sb" run
    if [ -n "$(git -C "$_t_work" status --porcelain)" ]; then
        ok "paused: a scheduled pass leaves it alone"
    else
        fail "paused: a scheduled pass leaves it alone" "a.txt was committed"
    fi
    run_syncto "$_t_sb" status
    case "$OUT" in
        *"paused"*"paused=off"*) ok "status: says paused and how to resume" ;;
        *) fail "status: says paused and how to resume" "$OUT" ;;
    esac

    run_syncto "$_t_sb" sync work
    assert_status "paused: sync NAME still syncs it" 0 "$RC" "$OUT"
    if [ -z "$(git -C "$_t_work" status --porcelain)" ]; then
        ok "paused: sync NAME commits the change"
    else
        fail "paused: sync NAME commits the change" "$(git -C "$_t_work" status --porcelain)"
    fi

    run_syncto "$_t_sb" edit work paused=off
    printf 'y\n' >"$_t_work/b.txt"
    run_syncto "$_t_sb" sync
    if [ -z "$(git -C "$_t_work" status --porcelain)" ]; then
        ok "paused: resumed target syncs again"
    else
        fail "paused: resumed target syncs again" "b.txt left uncommitted"
    fi
}

# ---------------------------------------------------------------------------
# dashboard (plain syncto in a terminal)
# ---------------------------------------------------------------------------

# run_in_pty SANDBOX KEYS: plain syncto in a pseudo-terminal fed KEYS; sets RAW,
# OUT (escapes stripped) and RC. Uses BSD or util-linux script, whichever exists.
run_in_pty() {
    if script --version >/dev/null 2>&1; then
        RAW=$(printf '%s' "$2" | HOME="$1/home" XDG_CONFIG_HOME="$1/home/.config" \
            XDG_STATE_HOME="$1/home/.local/state" TERM=xterm \
            script -qec "'$SYNCTO'" /dev/null 2>&1)
    else
        RAW=$(printf '%s' "$2" | HOME="$1/home" XDG_CONFIG_HOME="$1/home/.config" \
            XDG_STATE_HOME="$1/home/.local/state" TERM=xterm \
            script -q /dev/null "$SYNCTO" 2>&1)
    fi
    RC=$?
    OUT=$(printf '%s' "$RAW" | LC_ALL=C sed $'s/\033\\[[0-9;?]*[A-Za-z]//g')
}

test_dashboard() {
    if ! command -v script >/dev/null 2>&1; then
        ok "dashboard: skipped, no script(1) here"
        return 0
    fi
    _t_sb=$(new_sandbox)
    _t_target="$_t_sb/home/notes"
    mkdir -p "$_t_target"
    git_q "$_t_target" init
    run_syncto "$_t_sb" add notes "$_t_target" watch=on

    run_in_pty "$_t_sb" q
    assert_status "dashboard: q quits with 0" 0 "$RC" "$OUT"
    case "$OUT" in
        *notes*"not synced yet"*"q quit"*) ok "dashboard: lists repos with health and keys" ;;
        *) fail "dashboard: lists repos with health and keys" "$OUT" ;;
    esac
    case "$RAW" in
        *$'\033[?1049l'*) ok "dashboard: restores the terminal on quit" ;;
        *) fail "dashboard: restores the terminal on quit" "$RAW" ;;
    esac

    run_in_pty "$_t_sb" "?xq"
    case "$OUT" in
        *"How syncto works"*) ok "dashboard: ? shows how syncto works" ;;
        *) fail "dashboard: ? shows how syncto works" "$OUT" ;;
    esac

    run_in_pty "$_t_sb" pq
    case "$(cat "$_t_sb/home/.config/syncto/targets")" in
        *paused=on*) ok "dashboard: p pauses the selected repo" ;;
        *) fail "dashboard: p pauses the selected repo" "$(cat "$_t_sb/home/.config/syncto/targets")" ;;
    esac
}

# ---------------------------------------------------------------------------
# start reloads units that are already running
# ---------------------------------------------------------------------------

test_start_reloads() {
    _t_sb=$(new_sandbox)
    _t_target="$_t_sb/home/notes"
    mkdir -p "$_t_target" "$_t_sb/stub"
    git_q "$_t_target" init
    for _t_b in launchctl systemctl; do
        printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\nexit 0\n' "$_t_b" "$_t_sb" >"$_t_sb/stub/$_t_b"
        chmod +x "$_t_sb/stub/$_t_b"
    done
    run_syncto_path "$_t_sb" "$_t_sb/stub" add notes "$_t_target" watch=on
    run_syncto_path "$_t_sb" "$_t_sb/stub" start
    assert_status "start: exits 0" 0 "$RC" "$OUT"
    _t_calls=$(cat "$_t_sb/calls" 2>/dev/null)
    case "$(uname -s)" in
        Darwin)
            case "$_t_calls" in
                *"bootout gui/"*"/com.user.syncto-watch"*"bootstrap gui/"*"com.user.syncto-watch.plist"*)
                    ok "start: reloads a running launchd watch agent" ;;
                *) fail "start: reloads a running launchd watch agent" "$_t_calls" ;;
            esac
            if xcode-select -p >/dev/null 2>&1; then
                _t_args=$(plutil -extract ProgramArguments.0 raw -o - \
                    "$_t_sb/home/Library/LaunchAgents/com.user.syncto.plist" 2>/dev/null)
                case "$_t_args" in
                    */.local/share/syncto/launcher) ok "start: launchd starts the launcher, not /bin/bash" ;;
                    *) fail "start: launchd starts the launcher, not /bin/bash" "$_t_args" ;;
                esac
                case "$("$_t_args" "$SYNCTO" version 2>&1)" in
                    "syncto "*) ok "start: the launcher runs syncto" ;;
                    *) fail "start: the launcher runs syncto" "$("$_t_args" "$SYNCTO" version 2>&1)" ;;
                esac
            fi
            ;;
        *)
            case "$_t_calls" in
                *"restart syncto.timer"*"restart syncto-watch.service"*)
                    ok "start: restarts running systemd units" ;;
                *) fail "start: restarts running systemd units" "$_t_calls" ;;
            esac
            ;;
    esac
}

# ---------------------------------------------------------------------------
# security: branch and remote values
# ---------------------------------------------------------------------------

test_branch_remote_values() {
    _t_sb=$(new_sandbox)
    _t_work="$_t_sb/home/work"
    mkdir -p "$_t_work"
    git_q "$_t_work" init
    run_syncto "$_t_sb" add a "$_t_work" "remote=--upload-pack=touch $_t_sb/PWNED"
    assert_status "values: a remote starting with - is refused" 3 "$RC" "$OUT"
    run_syncto "$_t_sb" add b "$_t_work" 'branch=main\,guard=touch x'
    assert_status "values: a branch with a comma is refused" 3 "$RC" "$OUT"
    run_syncto "$_t_sb" add c "$_t_work" "branch=-x"
    assert_status "values: a branch starting with - is refused" 3 "$RC" "$OUT"

    # The dashboard's add form takes the branch the clone checked out.
    if command -v script >/dev/null 2>&1; then
        _t_evil='main,guard=touch${IFS}'"$_t_sb"'/PWNED'
        _t_up="$_t_sb/home/up"
        mkdir -p "$_t_up"
        git_q "$_t_up" init
        git_q "$_t_up" checkout -b "$_t_evil"
        git_q "$_t_up" commit --allow-empty -m init
        git clone -q "$_t_up" "$_t_sb/home/victim" 2>/dev/null
        run_in_pty "$_t_sb" "a$_t_sb/home/victim"$'\r\r'nnq
        run_syncto "$_t_sb" sync
        if [ -e "$_t_sb/PWNED" ] || grep -q 'guard=' "$_t_sb/home/.config/syncto/targets" 2>/dev/null; then
            fail "values: a branch name cannot plant a guard through the add form" "$(cat "$_t_sb/home/.config/syncto/targets")"
        else
            ok "values: a branch name cannot plant a guard through the add form"
        fi
    fi
}

test_control_characters() {
    _t_sb=$(new_sandbox)
    _t_work="$_t_sb/home/work"
    mkdir -p "$_t_work"
    git_q "$_t_work" init
    # A guard's output is logged; make it try to set the window title.
    run_syncto "$_t_sb" add work "$_t_work" "guard=printf '\033]0;OWNED\007\033[2K\302\233X'; exit 7"
    run_syncto "$_t_sb" sync work
    _t_esc=$(printf '\033')
    _t_csi=$(printf '\302\233')
    case "$(cat "$_t_sb/home/.local/state/syncto/syncto.log")" in
        *"$_t_esc"*|*"$_t_csi"*|*$'\007'*) fail "control: the log keeps no control characters" "$(cat -v "$_t_sb/home/.local/state/syncto/syncto.log")" ;;
        *OWNED*) ok "control: the log keeps no control characters" ;;
        *) fail "control: the log keeps no control characters" "guard output missing" ;;
    esac
    # Text written by an older version is cleaned when shown.
    mkdir -p "$_t_sb/home/.local/state/syncto/outcome"
    printf 'error\t1\tbad %s]0;X%s\n' "$_t_esc" "$(printf '\007')" >"$_t_sb/home/.local/state/syncto/outcome/work"
    printf '2026-01-01T00:00:00+0000 level=error target=work msg="raw %s[31m"\n' "$_t_esc" >>"$_t_sb/home/.local/state/syncto/syncto.log"
    run_syncto "$_t_sb" status
    case "$OUT" in
        *"$_t_esc"*) fail "control: status shows no control characters" "$(printf '%s' "$OUT" | cat -v)" ;;
        *"failing"*"bad ]0;X"*) ok "control: status shows no control characters" ;;
        *) fail "control: status shows no control characters" "$OUT" ;;
    esac
    run_syncto "$_t_sb" log
    case "$OUT" in
        *"$_t_esc"*) fail "control: syncto log shows no control characters" "$(printf '%s' "$OUT" | cat -v)" ;;
        *) ok "control: syncto log shows no control characters" ;;
    esac
}

test_subfolder_target() {
    _t_sb=$(new_sandbox)
    _t_outer="$_t_sb/home/outer"
    mkdir -p "$_t_outer/notes" "$_t_outer/.ssh"
    git_q "$_t_outer" init
    git_q "$_t_outer" checkout -B main
    git_q "$_t_outer" commit --allow-empty -m init
    git -C "$_t_outer" config user.email t@example.invalid
    git -C "$_t_outer" config user.name t
    printf 'secret\n' >"$_t_outer/.ssh/id_test"
    printf 'note\n' >"$_t_outer/notes/a.md"
    run_syncto "$_t_sb" add notes "$_t_outer/notes"
    case "$RC:$OUT" in
        3:*"inside the git repo"*) ok "subfolder: add refuses a folder inside a repo" ;;
        *) fail "subfolder: add refuses a folder inside a repo" "$RC $OUT" ;;
    esac
    mkdir -p "$_t_sb/home/.config/syncto"
    printf 'notes\t%s\tbranch=main\n' "$_t_outer/notes" >"$_t_sb/home/.config/syncto/targets"
    run_syncto "$_t_sb" sync notes
    assert_status "subfolder: sync refuses it with exit 3" 3 "$RC" "$OUT"
    if [ "$(git -C "$_t_outer" rev-list --count HEAD)" = "1" ]; then
        ok "subfolder: nothing in the enclosing repo is committed"
    else
        fail "subfolder: nothing in the enclosing repo is committed" "$(git -C "$_t_outer" log --stat -1)"
    fi
    run_syncto "$_t_sb" status
    case "$OUT" in
        *"inside another repo"*) ok "status: a subfolder says it is inside another repo" ;;
        *) fail "status: a subfolder says it is inside another repo" "$OUT" ;;
    esac
}

# ---------------------------------------------------------------------------
# run everything
# ---------------------------------------------------------------------------

test_config_roundtrip
test_edit_options
test_paused
test_dashboard
test_start_reloads
test_branch_remote_values
test_control_characters
test_subfolder_target
test_sync_basic
test_conflict
test_network_error_not_conflict
test_closed_by_remote_host
test_push_network_error
test_auth_error_not_conflict
test_add_failure_logged
test_missing_remote
test_locking
test_guard
test_stale_alarm
test_stale_off
test_help_version_unknown
test_spaces
test_watch_ignores_git
test_watch_syncs_real_edit
test_watch_skips_ignored
test_debounce_option
test_dirty_tree_defers_pull
test_remote_poll

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
