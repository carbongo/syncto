#!/usr/bin/env bash
#
# syncto — unattended git sync for working copies you care about.
#
# Single file, no dependencies beyond POSIX tools and git.
# Must stay bash 3.2 compatible (macOS stock) and run unchanged under bash 5:
# no associative arrays, no case-changing parameter expansions, no bulk
# read-a-file-into-an-array builtins, no bash-4-only declare flags.
# Must run on macOS (BSD userland) and Linux (GNU userland): no GNU-only flags.
#
# Licensed under the MIT license.

set -eu

SYNCTO_VERSION="0.2.0"
SYNCTO_LABEL="com.user.syncto"

# ---------------------------------------------------------------------------
# paths
# ---------------------------------------------------------------------------

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/syncto"
TARGETS_FILE="$CONFIG_DIR/targets"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/syncto"
LOCK_DIR="$STATE_DIR/locks"
LAST_DIR="$STATE_DIR/last"

# Absolute path of this script, without readlink -f (not portable).
SELF="$0"
case "$SELF" in
    /*) : ;;
    *)  SELF="$PWD/$SELF" ;;
esac
SELF_DIR=$(dirname "$SELF")

VERBOSE=0
HELD_LOCK=""

# ---------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------

timestamp() {
    # ISO-ish, works with both BSD and GNU date.
    date '+%Y-%m-%dT%H:%M:%S%z'
}

epoch() {
    date '+%s'
}

# Strip newlines so a log record always stays on one line.
oneline() {
    printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//'
}

# log LEVEL TARGET MESSAGE
log() {
    _lg_level=$1
    _lg_target=$2
    _lg_msg=$(oneline "$3")
    _lg_line="$(timestamp) level=$_lg_level target=${_lg_target:--} msg=\"$(printf '%s' "$_lg_msg" | sed 's/"/'"'"'/g')\""
    if [ -n "${LOG_FILE:-}" ]; then
        _lg_dir=$(dirname "$LOG_FILE")
        if [ ! -d "$_lg_dir" ]; then
            mkdir -p "$_lg_dir" 2>/dev/null || :
        fi
        printf '%s\n' "$_lg_line" >>"$LOG_FILE" 2>/dev/null || :
    fi
    if [ "$VERBOSE" -eq 1 ] || [ "$_lg_level" = "error" ] || [ "$_lg_level" = "conflict" ]; then
        printf '%s\n' "$_lg_line" >&2
    fi
    return 0
}

# log_rotate_maybe — keep the log from growing without bound. Checked once per
# invocation rather than per line: a size probe on every log() call would cost a
# stat per line for a file that only crosses the threshold once in thousands of
# passes. One generation is kept (.1); anything older is not worth the disk.
# `wc -c` rather than `stat`, whose flags differ between GNU and BSD.
log_rotate_maybe() {
    [ -n "${LOG_FILE:-}" ] || return 0
    [ "${LOG_MAX:-0}" -gt 0 ] || return 0
    [ -f "$LOG_FILE" ] || return 0
    _lr_size=$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' ')
    case "$_lr_size" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$_lr_size" -gt "$LOG_MAX" ] || return 0
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || return 0
    return 0
}

warn() {
    printf 'syncto: %s\n' "$1" >&2
}

die() {
    # die CODE MESSAGE
    printf 'syncto: %s\n' "$2" >&2
    exit "$1"
}

# Rank exit codes so the worst one survives a multi-target run.
# conflict (2) beats config (3) beats error (1) beats lock (4) beats ok (0).
code_rank() {
    case "$1" in
        0) printf '0' ;;
        4) printf '1' ;;
        1) printf '2' ;;
        3) printf '3' ;;
        2) printf '4' ;;
        *) printf '2' ;;
    esac
}

worst_code() {
    # worst_code CURRENT NEW -> prints the one that should win
    if [ "$(code_rank "$2")" -gt "$(code_rank "$1")" ]; then
        printf '%s' "$2"
    else
        printf '%s' "$1"
    fi
}

# ---------------------------------------------------------------------------
# ~ / $HOME portability (config files stay valid across machines and users)
# ---------------------------------------------------------------------------

path_encode() {
    case "$1" in
        "$HOME") printf '~' ;;
        "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
        *) printf '%s' "$1" ;;
    esac
}

path_decode() {
    case "$1" in
        "~") printf '%s' "$HOME" ;;
        "~/"*) printf '%s%s' "$HOME" "${1#\~}" ;;
        *) printf '%s' "$1" ;;
    esac
}

abs_path() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        "~") printf '%s' "$HOME" ;;
        "~/"*) printf '%s%s' "$HOME" "${1#\~}" ;;
        *) printf '%s/%s' "$PWD" "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# option parsing
# ---------------------------------------------------------------------------

# Split a comma separated option list, honouring "\," as a literal comma.
# One option per output line.
split_opts() {
    _so_in=$1
    _so_cur=""
    while [ -n "$_so_in" ]; do
        _so_c=${_so_in%"${_so_in#?}"}
        _so_in=${_so_in#?}
        if [ "$_so_c" = "\\" ] && [ -n "$_so_in" ]; then
            _so_n=${_so_in%"${_so_in#?}"}
            _so_in=${_so_in#?}
            if [ "$_so_n" = "," ]; then
                _so_cur="$_so_cur,"
            else
                _so_cur="$_so_cur$_so_c$_so_n"
            fi
        elif [ "$_so_c" = "," ]; then
            printf '%s\n' "$_so_cur"
            _so_cur=""
        else
            _so_cur="$_so_cur$_so_c"
        fi
    done
    if [ -n "$_so_cur" ]; then
        printf '%s\n' "$_so_cur"
    fi
    return 0
}

# Is this a known option key?
known_key() {
    case "$1" in
        interval|watch|mode|branch|remote|prefix|guard|notify|peer) return 0 ;;
        key|ssh|GIT_SSH_COMMAND|log|debounce|log_max) return 0 ;;
        *) return 1 ;;
    esac
}

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

validate_value() {
    # validate_value KEY VALUE -> 0 ok, 1 bad (message on stderr)
    case "$1" in
        interval)
            case "$2" in
                ''|*[!0-9]*) warn "interval must be a whole number of seconds, got '$2'"; return 1 ;;
            esac
            if [ "$2" -lt 1 ]; then
                warn "interval must be at least 1 second"
                return 1
            fi
            ;;
        watch)
            case "$2" in
                on|off) : ;;
                *) warn "watch must be 'on' or 'off', got '$2'"; return 1 ;;
            esac
            ;;
        debounce)
            case "$2" in
                ''|*[!0-9]*) warn "debounce must be a whole number of seconds, got '$2'"; return 1 ;;
            esac
            if [ "$2" -lt 1 ]; then
                warn "debounce must be at least 1 second"
                return 1
            fi
            ;;
        log_max)
            case "$2" in
                ''|*[!0-9]*) warn "log_max must be a whole number of bytes, got '$2'"; return 1 ;;
            esac
            ;;
        mode)
            case "$2" in
                sync|push|pull) : ;;
                *) warn "mode must be 'sync', 'push' or 'pull', got '$2'"; return 1 ;;
            esac
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# global config
# ---------------------------------------------------------------------------

G_INTERVAL=120
G_WATCH=off
G_DEBOUNCE=2
G_MODE=sync
G_BRANCH=main
G_REMOTE=origin
G_PREFIX=syncto
G_GUARD=""
G_NOTIFY=""
G_PEER=""
G_KEY=""
G_SSH=""
LOG_FILE="$STATE_DIR/syncto.log"
# Rotate the log once it passes this many bytes (0 disables). A watch-driven
# setup logs far less than a 2-minute timer did, but an unattended daemon that
# never rotates still grows without bound; one rotation keeps the previous
# generation around as .1 and nothing older.
LOG_MAX=${SYNCTO_LOG_MAX:-2097152}

load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    _lc_n=0
    while IFS= read -r _lc_line || [ -n "$_lc_line" ]; do
        _lc_n=$((_lc_n + 1))
        case "$_lc_line" in
            ''|'#'*) continue ;;
        esac
        case "$_lc_line" in
            *=*) : ;;
            *)
                warn "$CONFIG_FILE:$_lc_n: not a key=value line, ignored"
                continue
                ;;
        esac
        _lc_k=$(trim "${_lc_line%%=*}")
        _lc_v=${_lc_line#*=}
        if ! known_key "$_lc_k"; then
            warn "$CONFIG_FILE:$_lc_n: unknown key '$_lc_k', ignored"
            continue
        fi
        if ! validate_value "$_lc_k" "$_lc_v"; then
            warn "$CONFIG_FILE:$_lc_n: ignored"
            continue
        fi
        case "$_lc_k" in
            interval) G_INTERVAL=$_lc_v ;;
            watch)    G_WATCH=$_lc_v ;;
            debounce) G_DEBOUNCE=$_lc_v ;;
            log_max)  LOG_MAX=$_lc_v ;;
            mode)     G_MODE=$_lc_v ;;
            branch)   G_BRANCH=$_lc_v ;;
            remote)   G_REMOTE=$_lc_v ;;
            prefix)   G_PREFIX=$_lc_v ;;
            guard)    G_GUARD=$_lc_v ;;
            notify)   G_NOTIFY=$_lc_v ;;
            peer)     G_PEER=$_lc_v ;;
            key)      G_KEY=$(path_decode "$_lc_v") ;;
            ssh|GIT_SSH_COMMAND) G_SSH=$_lc_v ;;
            log)      LOG_FILE=$(path_decode "$_lc_v") ;;
        esac
    done <"$CONFIG_FILE"
    return 0
}

# Schedulers (launchd, systemd --user) run without an ssh-agent, so give git an
# explicit transport when the config asks for one.
setup_git_env() {
    GIT_TERMINAL_PROMPT=0
    export GIT_TERMINAL_PROMPT
    apply_ssh_env "$G_SSH" "$G_KEY"
}

# apply_ssh_env SSH_COMMAND KEY_PATH — scoped per target, cleared when neither is set.
apply_ssh_env() {
    if [ -n "$1" ]; then
        GIT_SSH_COMMAND=$1
        export GIT_SSH_COMMAND
    elif [ -n "$2" ]; then
        GIT_SSH_COMMAND="ssh -i \"$2\" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10"
        export GIT_SSH_COMMAND
    else
        unset GIT_SSH_COMMAND 2>/dev/null || :
    fi
    return 0
}

# ---------------------------------------------------------------------------
# targets file
# ---------------------------------------------------------------------------

TG_COUNT=0
TAB=$(printf '\t')

targets_load() {
    TG_COUNT=0
    TG_MALFORMED=0
    [ -f "$TARGETS_FILE" ] || return 0
    _tl_n=0
    while IFS= read -r _tl_line || [ -n "$_tl_line" ]; do
        _tl_n=$((_tl_n + 1))
        case "$_tl_line" in
            ''|'#'*) continue ;;
        esac
        _tl_name=""
        _tl_path=""
        _tl_opts=""
        IFS="$TAB" read -r _tl_name _tl_path _tl_opts <<EOF || :
$_tl_line
EOF
        if [ -z "$_tl_name" ] || [ -z "$_tl_path" ]; then
            warn "$TARGETS_FILE:$_tl_n: expected NAME<TAB>PATH[<TAB>OPTIONS], ignored"
            TG_MALFORMED=1
            continue
        fi
        eval "TG_NAME_$TG_COUNT=\$_tl_name"
        eval "TG_PATH_$TG_COUNT=\$(path_decode \"\$_tl_path\")"
        eval "TG_OPTS_$TG_COUNT=\$_tl_opts"
        TG_COUNT=$((TG_COUNT + 1))
    done <"$TARGETS_FILE"
    return 0
}

TG_MALFORMED=0

tg_name() { eval "printf '%s' \"\${TG_NAME_$1}\""; }
tg_path() { eval "printf '%s' \"\${TG_PATH_$1}\""; }
tg_opts() { eval "printf '%s' \"\${TG_OPTS_$1}\""; }

tg_index_of() {
    # prints the index of target NAME, or nothing
    _ti_i=0
    while [ "$_ti_i" -lt "$TG_COUNT" ]; do
        if [ "$(tg_name "$_ti_i")" = "$1" ]; then
            printf '%s' "$_ti_i"
            return 0
        fi
        _ti_i=$((_ti_i + 1))
    done
    return 1
}

# Resolve the effective options for a target into t_* variables.
resolve_opts() {
    t_interval=$G_INTERVAL
    t_watch=$G_WATCH
    t_debounce=$G_DEBOUNCE
    t_mode=$G_MODE
    t_branch=$G_BRANCH
    t_remote=$G_REMOTE
    t_prefix=$G_PREFIX
    t_guard=$G_GUARD
    t_notify=$G_NOTIFY
    t_peer=$G_PEER
    t_key=$G_KEY
    t_ssh=$G_SSH
    t_rc=0
    _ro_opts=$1
    [ -n "$_ro_opts" ] || return 0
    while IFS= read -r _ro_kv; do
        _ro_kv=$(trim "$_ro_kv")
        [ -n "$_ro_kv" ] || continue
        case "$_ro_kv" in
            *=*) : ;;
            *)
                warn "option '$_ro_kv' is not key=value, ignored"
                t_rc=3
                continue
                ;;
        esac
        _ro_k=$(trim "${_ro_kv%%=*}")
        _ro_v=${_ro_kv#*=}
        if ! known_key "$_ro_k"; then
            warn "unknown option '$_ro_k', ignored"
            t_rc=3
            continue
        fi
        if ! validate_value "$_ro_k" "$_ro_v"; then
            t_rc=3
            continue
        fi
        case "$_ro_k" in
            interval) t_interval=$_ro_v ;;
            watch)    t_watch=$_ro_v ;;
            debounce) t_debounce=$_ro_v ;;
            mode)     t_mode=$_ro_v ;;
            branch)   t_branch=$_ro_v ;;
            remote)   t_remote=$_ro_v ;;
            prefix)   t_prefix=$_ro_v ;;
            guard)    t_guard=$_ro_v ;;
            notify)   t_notify=$_ro_v ;;
            peer)     t_peer=$_ro_v ;;
            key)      t_key=$(path_decode "$_ro_v") ;;
            ssh|GIT_SSH_COMMAND) t_ssh=$_ro_v ;;
            log|log_max) : ;;
        esac
    done <<EOF
$(split_opts "$_ro_opts")
EOF
    return 0
}

# ---------------------------------------------------------------------------
# locking (mkdir is the only portable atomic create)
# ---------------------------------------------------------------------------

safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

lock_acquire() {
    # lock_acquire NAME STALE_AFTER_SECONDS -> 0 acquired, 1 held by someone else
    _la_dir="$LOCK_DIR/$(safe_name "$1").lock"
    _la_stale=$2
    mkdir -p "$LOCK_DIR" 2>/dev/null || :
    if mkdir "$_la_dir" 2>/dev/null; then
        printf '%s %s\n' "$$" "$(epoch)" >"$_la_dir/owner" 2>/dev/null || :
        HELD_LOCK=$_la_dir
        return 0
    fi
    # Someone holds it. Steal it if it is older than the stale window.
    _la_started=0
    if [ -f "$_la_dir/owner" ]; then
        _la_started=$(awk '{print $2}' "$_la_dir/owner" 2>/dev/null || printf '0')
    fi
    case "$_la_started" in
        ''|*[!0-9]*) _la_started=0 ;;
    esac
    _la_age=$(( $(epoch) - _la_started ))
    if [ "$_la_started" -eq 0 ] || [ "$_la_age" -gt "$_la_stale" ]; then
        log warn "$1" "stealing stale lock (age ${_la_age}s > ${_la_stale}s)"
        rm -rf "$_la_dir" 2>/dev/null || :
        if mkdir "$_la_dir" 2>/dev/null; then
            printf '%s %s\n' "$$" "$(epoch)" >"$_la_dir/owner" 2>/dev/null || :
            HELD_LOCK=$_la_dir
            return 0
        fi
    fi
    return 1
}

lock_release() {
    if [ -n "$HELD_LOCK" ]; then
        rm -rf "$HELD_LOCK" 2>/dev/null || :
        HELD_LOCK=""
    fi
    return 0
}

on_exit() {
    lock_release
}
trap on_exit EXIT
trap 'lock_release; exit 1' INT TERM HUP

# ---------------------------------------------------------------------------
# notify throttle
# ---------------------------------------------------------------------------

NOTIFY_DIR="$STATE_DIR/notified"
NOTIFY_COOLDOWN=${SYNCTO_NOTIFY_COOLDOWN:-1800}

# notify_due NAME -> 0 if this alert should be sent, 1 if one went out for the
# same target within the cooldown. A conflict persists until a human clears it,
# so without this the same message goes out on every pass — and an alert that
# arrives thirty times is one nobody reads. Keyed by target, not by the error
# text: git varies its own wording between passes (the fetch summary line comes
# and goes), so hashing the message would defeat the throttle entirely.
# notify_clear on a good pass re-arms it, so a fresh problem still alerts at once.
notify_due() {
    _nd_file="$NOTIFY_DIR/$(safe_name "$1")"
    mkdir -p "$NOTIFY_DIR" 2>/dev/null || :
    _nd_sent=0
    if [ -f "$_nd_file" ]; then
        _nd_sent=$(cat "$_nd_file" 2>/dev/null || printf '0')
    fi
    case "$_nd_sent" in
        ''|*[!0-9]*) _nd_sent=0 ;;
    esac
    if [ "$_nd_sent" -gt 0 ]; then
        _nd_age=$(( $(epoch) - _nd_sent ))
        if [ "$_nd_age" -lt "$NOTIFY_COOLDOWN" ]; then
            log info "$1" "same alert sent ${_nd_age}s ago, staying quiet"
            return 1
        fi
    fi
    printf '%s\n' "$(epoch)" >"$_nd_file" 2>/dev/null || :
    return 0
}

# notify_clear NAME — the target synced cleanly, so forget the last alert.
notify_clear() {
    rm -f "$NOTIFY_DIR/$(safe_name "$1")" 2>/dev/null || :
    return 0
}

# ---------------------------------------------------------------------------
# hooks
# ---------------------------------------------------------------------------

# run_hook CMD CWD NAME MESSAGE -> exit status of the hook, output on stdout
run_hook() {
    (
        cd "$2" 2>/dev/null || exit 127
        SYNCTO_NAME=$3
        SYNCTO_PATH=$2
        SYNCTO_MESSAGE=$4
        SYNCTO_BRANCH=${t_branch:-}
        SYNCTO_REMOTE=${t_remote:-}
        export SYNCTO_NAME SYNCTO_PATH SYNCTO_MESSAGE SYNCTO_BRANCH SYNCTO_REMOTE
        sh -c "$1" </dev/null 2>&1
    )
}

# ---------------------------------------------------------------------------
# the sync engine
# ---------------------------------------------------------------------------

git_in() {
    # git_in PATH ARGS...
    _gi_path=$1
    shift
    git -C "$_gi_path" "$@" </dev/null
}

# sync_one INDEX -> exit code for that target
sync_one() {
    _s_i=$1
    name=$(tg_name "$_s_i")
    path=$(tg_path "$_s_i")
    opts=$(tg_opts "$_s_i")

    resolve_opts "$opts"
    _s_rc=$t_rc

    # 1. lock first — a second run must never race the first one.
    _s_stale=$((t_interval * 10))
    if ! lock_acquire "$name" "$_s_stale"; then
        log warn "$name" "lock held by another run, skipping"
        return 4
    fi

    if [ ! -d "$path" ]; then
        log error "$name" "path does not exist: $path"
        lock_release
        return 3
    fi
    if ! git_in "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log error "$name" "not a git working tree: $path"
        lock_release
        return 3
    fi

    apply_ssh_env "$t_ssh" "$t_key"
    _s_code=0
    sync_locked || _s_code=$?
    apply_ssh_env "$G_SSH" "$G_KEY"
    lock_release
    if [ "$_s_code" -ne 0 ]; then
        _s_rc=$(worst_code "$_s_rc" "$_s_code")
    fi
    return "$_s_rc"
}

# The body of a sync, with the lock already held. Uses the caller's
# name/path/t_* variables.
sync_locked() {
    # 2. guard
    if [ -n "$t_guard" ]; then
        _g_out=""
        _g_rc=0
        _g_out=$(run_hook "$t_guard" "$path" "$name" "guard") || _g_rc=$?
        if [ "$_g_rc" -ne 0 ]; then
            log info "$name" "guard exited $_g_rc, skipping this pass: $_g_out"
            return 0
        fi
    fi

    # Refuse to touch a working tree a human is already in the middle of.
    _gitdir=$(git_in "$path" rev-parse --git-dir 2>/dev/null || printf '')
    if [ -n "$_gitdir" ]; then
        case "$_gitdir" in
            /*) : ;;
            *) _gitdir="$path/$_gitdir" ;;
        esac
        if [ -d "$_gitdir/rebase-merge" ] || [ -d "$_gitdir/rebase-apply" ] ||
           [ -f "$_gitdir/MERGE_HEAD" ] || [ -f "$_gitdir/CHERRY_PICK_HEAD" ]; then
            log conflict "$name" "an unfinished rebase/merge is in progress, needs a human"
            return 2
        fi
    fi

    _head=$(git_in "$path" symbolic-ref -q --short HEAD 2>/dev/null || printf '')
    if [ -z "$_head" ]; then
        log conflict "$name" "HEAD is detached, refusing to sync"
        return 2
    fi
    if [ "$_head" != "$t_branch" ]; then
        log warn "$name" "checked out branch is '$_head' but configured branch is '$t_branch'"
    fi

    _committed=0
    _rc=0

    # 3./4. stage and commit
    if [ "$t_mode" != "pull" ]; then
        if ! git_in "$path" add -A >/dev/null 2>&1; then
            log error "$name" "git add -A failed"
            return 1
        fi
        if git_in "$path" diff --cached --quiet 2>/dev/null; then
            log info "$name" "nothing to commit"
        else
            _n=$(git_in "$path" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
            case "$_n" in
                ''|*[!0-9]*) _n=0 ;;
            esac
            if [ "$_n" -eq 1 ]; then
                _file=$(git_in "$path" diff --cached --name-only 2>/dev/null | sed -n '1p')
                _what=${_file##*/}
            else
                _what="$_n files"
            fi
            _msg="$t_prefix: $_what"
            _out=""
            _crc=0
            _out=$(git_in "$path" commit -m "$_msg" 2>&1) || _crc=$?
            if [ "$_crc" -ne 0 ]; then
                log error "$name" "commit failed ($_crc): $_out"
                return 1
            fi
            _committed=1
            log info "$name" "committed: $_msg"
        fi
    fi

    # 5. pull --rebase --autostash
    if [ "$t_mode" != "push" ]; then
        _out=""
        _prc=0
        _out=$(git_in "$path" pull --rebase --autostash "$t_remote" "$t_branch" 2>&1) || _prc=$?
        # A concurrent `git pull` in the same repo (a human at the keyboard, an
        # agent session) appends a second for-merge line to FETCH_HEAD, and git
        # then refuses: "Cannot rebase onto multiple branches". Nothing is wrong
        # with the repo — the next fetch rewrites FETCH_HEAD. Retry once before
        # declaring a conflict, otherwise a harmless race pages a human.
        if [ "$_prc" -ne 0 ]; then
            case "$_out" in
                *"Cannot rebase onto multiple branches"*)
                    log warn "$name" "FETCH_HEAD race with a concurrent git, retrying once"
                    git_in "$path" rebase --abort >/dev/null 2>&1 || :
                    sleep 3
                    _out=""
                    _prc=0
                    _out=$(git_in "$path" pull --rebase --autostash "$t_remote" "$t_branch" 2>&1) || _prc=$?
                    ;;
            esac
        fi
        # The network is not the repository. A DNS hiccup or a dropped route
        # makes every pass fail identically for as long as it lasts, and at one
        # pass per two minutes that is a pager storm about nothing: the working
        # tree is untouched and the next good pass catches up on its own. Log
        # it, do not notify — only a real divergence is worth waking someone.
        if [ "$_prc" -ne 0 ]; then
            case "$_out" in
                *"Could not resolve hostname"*|\
                *"Temporary failure in name resolution"*|\
                *"Connection timed out"*|\
                *"Connection reset by peer"*|\
                *"Network is unreachable"*|\
                *"No route to host"*|\
                *"Operation timed out"*|\
                *"kex_exchange_identification"*)
                    git_in "$path" rebase --abort >/dev/null 2>&1 || :
                    log warn "$name" "network unreachable, retrying next pass: $(oneline "$_out")"
                    return 0
                    ;;
            esac
        fi
        if [ "$_prc" -ne 0 ]; then
            case "$_out" in
                *"ouldn't find remote ref"*)
                    # The branch is not on the remote yet — the push below creates it.
                    log warn "$name" "$t_remote has no branch '$t_branch' yet, pushing to create it"
                    _prc=0
                    ;;
            esac
        fi
        if [ "$_prc" -ne 0 ]; then
            git_in "$path" rebase --abort >/dev/null 2>&1 || :
            log conflict "$name" "pull --rebase failed, aborted: $_out"
            if [ -n "$t_notify" ] && notify_due "$name"; then
                _nout=""
                _nrc=0
                _nout=$(run_hook "$t_notify" "$path" "$name" "syncto: $name needs attention: $(oneline "$_out")") || _nrc=$?
                if [ "$_nrc" -ne 0 ]; then
                    log warn "$name" "notify hook exited $_nrc: $_nout"
                fi
            fi
            return 2
        fi
    fi

    # 6. push
    if [ "$t_mode" != "pull" ]; then
        _out=""
        _prc=0
        _out=$(git_in "$path" push "$t_remote" "$t_branch" 2>&1) || _prc=$?
        if [ "$_prc" -ne 0 ]; then
            log error "$name" "push failed ($_prc): $_out"
            return 1
        fi
    fi

    notify_clear "$name"
    log info "$name" "sync ok (mode=$t_mode branch=$t_branch remote=$t_remote committed=$_committed)"

    # 7. poke the peer, best effort — never fails the run
    if [ "$_committed" -eq 1 ] && [ -n "$t_peer" ]; then
        _pout=""
        _prc2=0
        _pout=$(run_hook "$t_peer" "$path" "$name" "peer") || _prc2=$?
        if [ "$_prc2" -ne 0 ]; then
            log warn "$name" "peer hook exited $_prc2: $_pout"
        fi
    fi

    return "$_rc"
}

mark_run() {
    mkdir -p "$LAST_DIR" 2>/dev/null || :
    printf '%s\n' "$(epoch)" >"$LAST_DIR/$(safe_name "$1")" 2>/dev/null || :
    return 0
}

last_run() {
    _lr_f="$LAST_DIR/$(safe_name "$1")"
    _lr_v=0
    if [ -f "$_lr_f" ]; then
        _lr_v=$(sed -n '1p' "$_lr_f" 2>/dev/null || printf '0')
    fi
    case "$_lr_v" in
        ''|*[!0-9]*) _lr_v=0 ;;
    esac
    printf '%s' "$_lr_v"
}

# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------

no_targets_notice() {
    printf 'No targets configured yet.\n' >&2
    printf 'Add one with:  syncto --add NAME PATH [key=value ...]\n' >&2
}

cmd_sync() {
    _cs_only=${1:-}
    targets_load
    if [ "$TG_COUNT" -eq 0 ]; then
        if [ -n "$_cs_only" ]; then
            die 3 "no such target: $_cs_only"
        fi
        no_targets_notice
        if [ "$TG_MALFORMED" -eq 1 ]; then
            return 3
        fi
        return 0
    fi

    _cs_rc=0
    if [ "$TG_MALFORMED" -eq 1 ]; then
        _cs_rc=3
    fi
    _cs_ran=0
    _cs_i=0
    _cs_conflicts=""
    while [ "$_cs_i" -lt "$TG_COUNT" ]; do
        _cs_name=$(tg_name "$_cs_i")
        if [ -n "$_cs_only" ] && [ "$_cs_only" != "$_cs_name" ]; then
            _cs_i=$((_cs_i + 1))
            continue
        fi
        _cs_ran=1
        _cs_one=0
        # A failure in one target must never stop the others.
        sync_one "$_cs_i" || _cs_one=$?
        if [ "$_cs_one" -ne 4 ]; then
            mark_run "$_cs_name"
        fi
        if [ "$_cs_one" -eq 2 ]; then
            _cs_conflicts="$_cs_conflicts $_cs_name"
        fi
        _cs_rc=$(worst_code "$_cs_rc" "$_cs_one")
        _cs_i=$((_cs_i + 1))
    done

    if [ -n "$_cs_only" ] && [ "$_cs_ran" -eq 0 ]; then
        die 3 "no such target: $_cs_only"
    fi
    if [ -n "$_cs_conflicts" ]; then
        printf 'syncto: needs a human:%s\n' "$_cs_conflicts" >&2
    fi
    return "$_cs_rc"
}

cmd_daemon() {
    targets_load
    if [ "$TG_COUNT" -eq 0 ]; then
        log info "" "no targets configured"
        return 0
    fi
    _cd_rc=0
    if [ "$TG_MALFORMED" -eq 1 ]; then
        _cd_rc=3
    fi
    _cd_now=$(epoch)
    _cd_i=0
    while [ "$_cd_i" -lt "$TG_COUNT" ]; do
        _cd_name=$(tg_name "$_cd_i")
        resolve_opts "$(tg_opts "$_cd_i")"
        _cd_last=$(last_run "$_cd_name")
        _cd_age=$((_cd_now - _cd_last))
        # Grace window: a scheduler firing every N seconds drifts by a second or two,
        # so an interval of exactly N would skip every other pass and halve the real
        # sync rate. Treat "nearly due" as due. 10% of the interval, clamped to 5..30s.
        _cd_slack=$((t_interval / 10))
        [ "$_cd_slack" -lt 5 ] && _cd_slack=5
        [ "$_cd_slack" -gt 30 ] && _cd_slack=30
        if [ "$_cd_last" -gt 0 ] && [ "$_cd_age" -lt $((t_interval - _cd_slack)) ]; then
            log info "$_cd_name" "skipped, last run ${_cd_age}s ago (interval ${t_interval}s)"
            _cd_i=$((_cd_i + 1))
            continue
        fi
        _cd_one=0
        sync_one "$_cd_i" || _cd_one=$?
        if [ "$_cd_one" -ne 4 ]; then
            mark_run "$_cd_name"
        fi
        _cd_rc=$(worst_code "$_cd_rc" "$_cd_one")
        _cd_i=$((_cd_i + 1))
    done
    return "$_cd_rc"
}

cmd_list() {
    targets_load
    if [ "$TG_COUNT" -eq 0 ]; then
        no_targets_notice
        return 0
    fi

    _cl_w=4
    _cl_i=0
    while [ "$_cl_i" -lt "$TG_COUNT" ]; do
        _cl_name=$(tg_name "$_cl_i")
        _cl_n=${#_cl_name}
        if [ "$_cl_n" -gt "$_cl_w" ]; then
            _cl_w=$_cl_n
        fi
        _cl_i=$((_cl_i + 1))
    done

    printf "%-${_cl_w}s  %-6s  %-5s  %-8s  %-12s  %-14s  %s\n" \
        NAME MODE WATCH EVERY BRANCH STATE PATH
    _cl_i=0
    while [ "$_cl_i" -lt "$TG_COUNT" ]; do
        _cl_name=$(tg_name "$_cl_i")
        _cl_path=$(tg_path "$_cl_i")
        resolve_opts "$(tg_opts "$_cl_i")" || :
        _cl_state="ok"
        if [ ! -d "$_cl_path" ]; then
            _cl_state="missing"
        elif ! git_in "$_cl_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            _cl_state="not a repo"
        else
            _cl_dirty=$(git_in "$_cl_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
            case "$_cl_dirty" in
                ''|*[!0-9]*) _cl_dirty=0 ;;
            esac
            _cl_ab=$(git_in "$_cl_path" rev-list --left-right --count \
                "$t_branch...$t_remote/$t_branch" 2>/dev/null || printf '')
            _cl_arrow=""
            if [ -n "$_cl_ab" ]; then
                _cl_ahead=$(printf '%s' "$_cl_ab" | awk '{print $1}')
                _cl_behind=$(printf '%s' "$_cl_ab" | awk '{print $2}')
                if [ "${_cl_ahead:-0}" != "0" ] || [ "${_cl_behind:-0}" != "0" ]; then
                    _cl_arrow=" +$_cl_ahead/-$_cl_behind"
                fi
            fi
            if [ "$_cl_dirty" -eq 0 ]; then
                _cl_state="clean$_cl_arrow"
            else
                _cl_state="$_cl_dirty dirty$_cl_arrow"
            fi
        fi
        printf "%-${_cl_w}s  %-6s  %-5s  %-8s  %-12s  %-14s  %s\n" \
            "$_cl_name" "$t_mode" "$t_watch" "${t_interval}s" "$t_branch" \
            "$_cl_state" "$(path_encode "$_cl_path")"
        _cl_i=$((_cl_i + 1))
    done
    if [ "$TG_MALFORMED" -eq 1 ]; then
        return 3
    fi
    return 0
}

ensure_targets_file() {
    if [ ! -f "$TARGETS_FILE" ]; then
        mkdir -p "$CONFIG_DIR" || die 3 "cannot create $CONFIG_DIR"
        {
            printf '# syncto targets\n'
            printf '# NAME<TAB>PATH<TAB>OPTIONS   ($HOME is written as ~ so this file travels)\n'
            printf '# options: interval= watch= mode= branch= remote= prefix= guard= notify= peer=\n'
        } >"$TARGETS_FILE" || die 3 "cannot write $TARGETS_FILE"
    fi
    return 0
}

cmd_add() {
    _ca_name=${1:-}
    _ca_path=${2:-}
    [ -n "$_ca_name" ] || die 3 "usage: syncto --add NAME PATH [key=value ...]"
    [ -n "$_ca_path" ] || die 3 "usage: syncto --add NAME PATH [key=value ...]"
    shift 2 || :

    case "$_ca_name" in
        *[!A-Za-z0-9._-]*) die 3 "name may only contain letters, digits, '.', '_' and '-'" ;;
    esac

    _ca_abs=$(abs_path "$_ca_path")
    [ -d "$_ca_abs" ] || die 3 "not a directory: $_ca_abs"

    targets_load
    if tg_index_of "$_ca_name" >/dev/null; then
        die 3 "target '$_ca_name' already exists (remove it first, or edit the file)"
    fi

    # Options may be given one per argument, comma joined, or any mix.
    _ca_opts=""
    for _ca_arg in "$@"; do
        while IFS= read -r _ca_kv; do
            _ca_kv=$(trim "$_ca_kv")
            [ -n "$_ca_kv" ] || continue
            case "$_ca_kv" in
                *=*) : ;;
                *) die 3 "options must be key=value, got '$_ca_kv'" ;;
            esac
            _ca_k=$(trim "${_ca_kv%%=*}")
            _ca_v=${_ca_kv#*=}
            known_key "$_ca_k" || die 3 "unknown option '$_ca_k'"
            validate_value "$_ca_k" "$_ca_v" || die 3 "bad value for '$_ca_k'"
            # commas inside a value have to survive the round trip
            _ca_v=$(printf '%s' "$_ca_v" | sed 's/,/\\,/g')
            if [ -n "$_ca_opts" ]; then
                _ca_opts="$_ca_opts,$_ca_k=$_ca_v"
            else
                _ca_opts="$_ca_k=$_ca_v"
            fi
        done <<EOF
$(split_opts "$_ca_arg")
EOF
    done

    if ! git -C "$_ca_abs" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        warn "$_ca_abs is not a git working tree (yet) — adding anyway"
    fi

    ensure_targets_file
    printf '%s\t%s\t%s\n' "$_ca_name" "$(path_encode "$_ca_abs")" "$_ca_opts" \
        >>"$TARGETS_FILE" || die 1 "cannot append to $TARGETS_FILE"
    printf 'Added %s -> %s\n' "$_ca_name" "$(path_encode "$_ca_abs")"
    log info "$_ca_name" "added target $(path_encode "$_ca_abs") [$_ca_opts]"
    return 0
}

cmd_remove() {
    _cr_name=${1:-}
    [ -n "$_cr_name" ] || die 3 "usage: syncto --remove NAME"
    [ -f "$TARGETS_FILE" ] || die 3 "no such target: $_cr_name"

    targets_load
    tg_index_of "$_cr_name" >/dev/null || die 3 "no such target: $_cr_name"

    _cr_tmp=$(mktemp "${TMPDIR:-/tmp}/syncto.XXXXXX") || die 1 "cannot create a temp file"
    while IFS= read -r _cr_line || [ -n "$_cr_line" ]; do
        _cr_first=${_cr_line%%"$TAB"*}
        if [ "$_cr_first" = "$_cr_name" ] && [ "$_cr_first" != "$_cr_line" ]; then
            continue
        fi
        printf '%s\n' "$_cr_line" >>"$_cr_tmp"
    done <"$TARGETS_FILE"
    cat "$_cr_tmp" >"$TARGETS_FILE" || { rm -f "$_cr_tmp"; die 1 "cannot rewrite $TARGETS_FILE"; }
    rm -f "$_cr_tmp"
    printf 'Removed %s\n' "$_cr_name"
    log info "$_cr_name" "removed target"
    rm -f "$LAST_DIR/$(safe_name "$_cr_name")" 2>/dev/null || :
    return 0
}

cmd_edit() {
    ensure_targets_file
    _ce_ed=${EDITOR:-${VISUAL:-vi}}
    # $EDITOR may carry flags, so let the shell split it, but keep the path quoted.
    sh -c "$_ce_ed \"\$1\"" sh "$TARGETS_FILE"
}

cmd_log() {
    if [ ! -f "$LOG_FILE" ]; then
        printf 'syncto: no log yet at %s\n' "$(path_encode "$LOG_FILE")" >&2
        return 0
    fi
    tail -n 100 "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# watch mode
# ---------------------------------------------------------------------------

W_COUNT=0

watch_collect() {
    # Build the watch set: NAME if given, else every target with watch=on.
    _wc_only=${1:-}
    targets_load
    W_COUNT=0
    W_DEBOUNCE=$G_DEBOUNCE
    _wc_first=1
    _wc_i=0
    while [ "$_wc_i" -lt "$TG_COUNT" ]; do
        _wc_name=$(tg_name "$_wc_i")
        resolve_opts "$(tg_opts "$_wc_i")" || :
        if [ -n "$_wc_only" ]; then
            [ "$_wc_only" = "$_wc_name" ] || { _wc_i=$((_wc_i + 1)); continue; }
        else
            [ "$t_watch" = "on" ] || { _wc_i=$((_wc_i + 1)); continue; }
        fi
        eval "W_IDX_$W_COUNT=\$_wc_i"
        eval "W_PATH_$W_COUNT=\$(tg_path \"\$_wc_i\")"
        eval "W_PEND_$W_COUNT=0"
        eval "W_FP_$W_COUNT=''"
        # One watcher process covers every watched target, so it gets a single
        # debounce: the most patient target's, so a slow writer is never cut off
        # mid-burst by a neighbour that wanted a tighter window.
        if [ "$_wc_first" -eq 1 ] || [ "$t_debounce" -gt "$W_DEBOUNCE" ]; then
            W_DEBOUNCE=$t_debounce
            _wc_first=0
        fi
        W_COUNT=$((W_COUNT + 1))
        _wc_i=$((_wc_i + 1))
    done
    return 0
}

w_idx()  { eval "printf '%s' \"\${W_IDX_$1}\""; }
w_path() { eval "printf '%s' \"\${W_PATH_$1}\""; }

# Mark whichever target owns this filesystem path.
watch_mark() {
    _wm_ev=$1
    # Ignore everything under .git. Syncing *writes* to .git (index, refs,
    # FETCH_HEAD, logs), so counting those as changes makes every sync trigger
    # the next one and the watcher never goes idle again. The watcher binaries
    # are told to exclude .git too; this is the backstop for any that don't, and
    # the reason the poll fallback was already safe (git status ignores .git).
    case "$_wm_ev" in
        */.git|*/.git/*) return 0 ;;
    esac
    _wm_i=0
    while [ "$_wm_i" -lt "$W_COUNT" ]; do
        _wm_p=$(w_path "$_wm_i")
        case "$_wm_ev" in
            "$_wm_p"|"$_wm_p"/*) eval "W_PEND_$_wm_i=1" ;;
        esac
        _wm_i=$((_wm_i + 1))
    done
    return 0
}

watch_flush() {
    _wf_i=0
    _wf_rc=0
    while [ "$_wf_i" -lt "$W_COUNT" ]; do
        eval "_wf_p=\$W_PEND_$_wf_i"
        if [ "$_wf_p" -eq 1 ]; then
            eval "W_PEND_$_wf_i=0"
            _wf_idx=$(w_idx "$_wf_i")
            _wf_name=$(tg_name "$_wf_idx")
            # A watcher fires on any write under the repo, including paths git
            # is told to ignore — editor scratch, trash folders, agent session
            # files. Syncing those costs a full network round trip to discover
            # there was nothing to commit, so ask git first: if the tree is
            # clean, the write was ignored and there is nothing to do. Only the
            # outbound direction is skipped; inbound still arrives via peer=
            # wakes and the interval backstop, neither of which comes through
            # here.
            if [ -z "$(git -C "$(w_path "$_wf_i")" status --porcelain 2>/dev/null | head -n 1)" ]; then
                log info "$_wf_name" "watch: only ignored paths changed, nothing to sync"
                _wf_i=$((_wf_i + 1))
                continue
            fi
            _wf_one=0
            sync_one "$_wf_idx" || _wf_one=$?
            if [ "$_wf_one" -ne 4 ]; then
                mark_run "$_wf_name"
            fi
            _wf_rc=$(worst_code "$_wf_rc" "$_wf_one")
        fi
        _wf_i=$((_wf_i + 1))
    done
    return 0
}

watch_fingerprint() {
    # Cheap "did anything change" probe for the poll fallback.
    ( git -C "$1" status --porcelain 2>/dev/null || printf 'ERR' ) | cksum
}

cmd_watch() {
    watch_collect "${1:-}"
    if [ "$W_COUNT" -eq 0 ]; then
        if [ -n "${1:-}" ]; then
            die 3 "no such target: $1"
        fi
        die 3 "no targets have watch=on; add one with 'syncto --add NAME PATH watch=on'"
    fi

    # Positional list of the paths to hand to the watcher binary.
    set --
    _cw_i=0
    while [ "$_cw_i" -lt "$W_COUNT" ]; do
        set -- "$@" "$(w_path "$_cw_i")"
        _cw_i=$((_cw_i + 1))
    done

    if command -v fswatch >/dev/null 2>&1; then
        log info "" "watching ${W_COUNT} target(s) with fswatch"
        printf 'syncto: watching %s target(s) with fswatch — ctrl-c to stop\n' "$W_COUNT" >&2
        watch_loop_fswatch "$@"
    elif command -v inotifywait >/dev/null 2>&1; then
        log info "" "watching ${W_COUNT} target(s) with inotifywait"
        printf 'syncto: watching %s target(s) with inotifywait — ctrl-c to stop\n' "$W_COUNT" >&2
        watch_loop_inotify "$@"
    else
        log info "" "watching ${W_COUNT} target(s) by polling"
        printf 'syncto: no fswatch/inotifywait found — polling every %ss — ctrl-c to stop\n' "$W_DEBOUNCE" >&2
        watch_loop_poll
    fi
    return 0
}

watch_loop_fswatch() {
    # -0: NUL separated, so paths with spaces or newlines survive.
    # --exclude is a regex over the full path; keep it in step with watch_mark.
    fswatch -0 -r --exclude '/\.git(/|$)' "$@" | {
        while IFS= read -r -d '' _wl_ev; do
            watch_mark "$_wl_ev"
            # debounce: keep draining until W_DEBOUNCE seconds of quiet
            while IFS= read -r -d '' -t "$W_DEBOUNCE" _wl_ev2; do
                watch_mark "$_wl_ev2"
            done
            watch_flush
        done
    }
    return 0
}

watch_loop_inotify() {
    inotifywait -m -r -q -e modify,create,delete,move \
        --exclude '(^|/)\.git(/|$)' --format '%w' "$@" | {
        while IFS= read -r _wl_ev; do
            watch_mark "${_wl_ev%/}"
            while IFS= read -r -t "$W_DEBOUNCE" _wl_ev2; do
                watch_mark "${_wl_ev2%/}"
            done
            watch_flush
        done
    }
    return 0
}

watch_loop_poll() {
    _wp_i=0
    while [ "$_wp_i" -lt "$W_COUNT" ]; do
        eval "W_FP_$_wp_i=\$(watch_fingerprint \"\$(w_path \"\$_wp_i\")\")"
        _wp_i=$((_wp_i + 1))
    done
    while :; do
        sleep "$W_DEBOUNCE"
        _wp_changed=0
        _wp_i=0
        while [ "$_wp_i" -lt "$W_COUNT" ]; do
            _wp_new=$(watch_fingerprint "$(w_path "$_wp_i")")
            eval "_wp_old=\$W_FP_$_wp_i"
            if [ "$_wp_new" != "$_wp_old" ]; then
                eval "W_FP_$_wp_i=\$_wp_new"
                eval "W_PEND_$_wp_i=1"
                _wp_changed=1
            fi
            _wp_i=$((_wp_i + 1))
        done
        if [ "$_wp_changed" -eq 1 ]; then
            # Let a burst of writes settle before syncing.
            sleep "$W_DEBOUNCE"
            _wp_i=0
            while [ "$_wp_i" -lt "$W_COUNT" ]; do
                eval "W_FP_$_wp_i=\$(watch_fingerprint \"\$(w_path \"\$_wp_i\")\")"
                _wp_i=$((_wp_i + 1))
            done
            watch_flush
        fi
    done
}

# ---------------------------------------------------------------------------
# scheduler units
# ---------------------------------------------------------------------------

xml_escape() {
    printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

SHELL_BIN="/bin/bash"

# The command the scheduler should run. Prefer the installed entry point, which is
# what the shipped unit templates document; fall back to this very file.
sched_exec() {
    if [ -x "$HOME/.local/bin/syncto" ]; then
        printf '%s' "$HOME/.local/bin/syncto"
    else
        printf '%s' "$SELF"
    fi
}

# render_template FILE -> prints the template with its @NAME@ placeholders filled in,
# or fails (1) if the file is missing, unreadable, or still has a placeholder left.
# Templates only ship in the source tree; an installed copy falls back to the
# inline units below, which are kept identical to them.
render_template() {
    [ -f "$1" ] || return 1
    _rt_exec=$(sched_exec)
    [ -x "$_rt_exec" ] || return 1
    _rt=$(cat "$1") || return 1
    _rt=${_rt//@EXEC@/$_rt_exec}
    _rt=${_rt//@INTERVAL@/$G_INTERVAL}
    _rt=${_rt//@LOG@/$LOG_FILE}
    _rt=${_rt//@LABEL@/$SYNCTO_LABEL}
    case "$_rt" in
        *@[A-Z]*@*) return 1 ;;
    esac
    printf '%s\n' "$_rt"
    return 0
}

# Print the ProgramArguments / ExecStart words, one per line: an executable entry
# point runs directly, anything else goes through bash.
#
# macOS is the exception: always go through $SHELL_BIN explicitly. macOS TCC grants
# file access (Full Disk Access, and the per-folder Documents/Desktop grants) to the
# *binary the scheduler exec'd*. Exec the script directly and the responsible process
# is the script itself, which holds no grant — so a launchd job silently reads a
# protected folder, such as an iCloud Drive path, as empty or missing. Naming
# /bin/bash keeps the grant on a stable, always-present binary the user can add once
# in System Settings > Privacy & Security > Full Disk Access.
sched_argv() {
    _sa_exec=$(sched_exec)
    if [ ! -x "$_sa_exec" ] || [ "$(uname -s)" = "Darwin" ]; then
        printf '%s\n' "$SHELL_BIN"
    fi
    printf '%s\n-d\n' "$_sa_exec"
}

plist_path() {
    printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$SYNCTO_LABEL"
}

watch_plist_path() {
    printf '%s/Library/LaunchAgents/%s-watch.plist' "$HOME" "$SYNCTO_LABEL"
}

install_launchd() {
    _il_plist=$(plist_path)
    mkdir -p "$HOME/Library/LaunchAgents" || die 1 "cannot create $HOME/Library/LaunchAgents"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || :
    if ! render_template "$SELF_DIR/templates/$SYNCTO_LABEL.plist.in" >"$_il_plist" 2>/dev/null; then
        {
            printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
            printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
            printf '%s\n' '<plist version="1.0">'
            printf '%s\n' '<dict>'
            printf '    <key>Label</key>\n    <string>%s</string>\n' "$(xml_escape "$SYNCTO_LABEL")"
            printf '    <key>ProgramArguments</key>\n    <array>\n'
            sched_argv | while IFS= read -r _il_a; do
                printf '        <string>%s</string>\n' "$(xml_escape "$_il_a")"
            done
            printf '    </array>\n'
            printf '    <key>EnvironmentVariables</key>\n    <dict>\n'
            printf '        <key>PATH</key>\n        <string>%s</string>\n' \
                '/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin'
            printf '    </dict>\n'
            printf '    <key>StartInterval</key>\n    <integer>%s</integer>\n' "$G_INTERVAL"
            printf '    <key>RunAtLoad</key>\n    <true/>\n'
            printf '    <key>ProcessType</key>\n    <string>Background</string>\n'
            printf '    <key>StandardOutPath</key>\n    <string>%s</string>\n' "$(xml_escape "$LOG_FILE")"
            printf '    <key>StandardErrorPath</key>\n    <string>%s</string>\n' "$(xml_escape "$LOG_FILE")"
            printf '%s\n' '</dict>'
            printf '%s\n' '</plist>'
        } >"$_il_plist" || die 1 "cannot write $_il_plist"
    fi

    _il_uid=$(id -u)
    launchctl bootout "gui/$_il_uid/$SYNCTO_LABEL" >/dev/null 2>&1 || :
    if ! launchctl bootstrap "gui/$_il_uid" "$_il_plist" >/dev/null 2>&1; then
        # older launchctl
        launchctl unload "$_il_plist" >/dev/null 2>&1 || :
        launchctl load "$_il_plist" >/dev/null 2>&1 ||
            die 1 "wrote $_il_plist but launchctl refused to load it"
    fi
    printf 'Installed launchd agent %s (every %ss)\n' "$SYNCTO_LABEL" "$G_INTERVAL"
    printf '  unit: %s\n' "$(path_encode "$_il_plist")"
    log info "" "installed launchd agent $SYNCTO_LABEL interval=$G_INTERVAL"

    _il_wplist=$(watch_plist_path)
    if any_watch_target; then
        if ! render_template "$SELF_DIR/templates/$SYNCTO_LABEL-watch.plist.in" \
                >"$_il_wplist" 2>/dev/null; then
            {
                printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
                printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
                printf '%s\n' '<plist version="1.0">'
                printf '%s\n' '<dict>'
                printf '    <key>Label</key>\n    <string>%s-watch</string>\n' "$(xml_escape "$SYNCTO_LABEL")"
                printf '    <key>ProgramArguments</key>\n    <array>\n'
                printf '        <string>%s</string>\n' "$(xml_escape "$SHELL_BIN")"
                printf '        <string>%s</string>\n' "$(xml_escape "$(sched_exec)")"
                printf '        <string>-w</string>\n'
                printf '    </array>\n'
                printf '    <key>EnvironmentVariables</key>\n    <dict>\n'
                printf '        <key>PATH</key>\n        <string>%s</string>\n' \
                    '/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin'
                printf '    </dict>\n'
                printf '    <key>RunAtLoad</key>\n    <true/>\n'
                printf '    <key>KeepAlive</key>\n    <true/>\n'
                printf '    <key>ProcessType</key>\n    <string>Background</string>\n'
                printf '    <key>StandardOutPath</key>\n    <string>%s</string>\n' "$(xml_escape "$LOG_FILE")"
                printf '    <key>StandardErrorPath</key>\n    <string>%s</string>\n' "$(xml_escape "$LOG_FILE")"
                printf '%s\n' '</dict>'
                printf '%s\n' '</plist>'
            } >"$_il_wplist" || die 1 "cannot write $_il_wplist"
        fi
        launchctl bootout "gui/$_il_uid/$SYNCTO_LABEL-watch" >/dev/null 2>&1 || :
        if ! launchctl bootstrap "gui/$_il_uid" "$_il_wplist" >/dev/null 2>&1; then
            launchctl unload "$_il_wplist" >/dev/null 2>&1 || :
            launchctl load "$_il_wplist" >/dev/null 2>&1 ||
                die 1 "wrote $_il_wplist but launchctl refused to load it"
        fi
        printf 'Installed launchd watch agent %s-watch\n' "$SYNCTO_LABEL"
        log info "" "installed launchd watch agent"
    elif [ -f "$_il_wplist" ]; then
        launchctl bootout "gui/$_il_uid/$SYNCTO_LABEL-watch" >/dev/null 2>&1 ||
            launchctl unload "$_il_wplist" >/dev/null 2>&1 || :
        rm -f "$_il_wplist" || :
        printf 'Removed launchd watch agent (no target has watch=on)\n'
    fi
    return 0
}

uninstall_launchd() {
    _ul_plist=$(plist_path)
    _ul_wplist=$(watch_plist_path)
    _ul_uid=$(id -u)
    launchctl bootout "gui/$_ul_uid/$SYNCTO_LABEL" >/dev/null 2>&1 ||
        launchctl unload "$_ul_plist" >/dev/null 2>&1 || :
    launchctl bootout "gui/$_ul_uid/$SYNCTO_LABEL-watch" >/dev/null 2>&1 ||
        launchctl unload "$_ul_wplist" >/dev/null 2>&1 || :
    if [ -f "$_ul_wplist" ]; then
        rm -f "$_ul_wplist" || die 1 "cannot remove $_ul_wplist"
        printf 'Removed launchd watch agent %s-watch\n' "$SYNCTO_LABEL"
    fi
    if [ -f "$_ul_plist" ]; then
        rm -f "$_ul_plist" || die 1 "cannot remove $_ul_plist"
        printf 'Removed launchd agent %s\n' "$SYNCTO_LABEL"
    else
        printf 'No launchd agent installed.\n'
    fi
    log info "" "uninstalled launchd agent"
    return 0
}

systemd_dir() {
    printf '%s/systemd/user' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# any_watch_target -> 0 if at least one configured target has watch=on. The
# watch daemon is only worth installing when something asked to be watched;
# without this a plain interval setup would gain a resident process that wakes
# for nothing.
any_watch_target() {
    targets_load
    _aw_i=0
    while [ "$_aw_i" -lt "$TG_COUNT" ]; do
        resolve_opts "$(tg_opts "$_aw_i")" || :
        if [ "$t_watch" = "on" ]; then
            return 0
        fi
        _aw_i=$((_aw_i + 1))
    done
    return 1
}

install_systemd() {
    command -v systemctl >/dev/null 2>&1 || die 1 "systemctl not found; install a unit by hand"
    _is_dir=$(systemd_dir)
    mkdir -p "$_is_dir" || die 1 "cannot create $_is_dir"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || :

    if ! render_template "$SELF_DIR/templates/syncto.service.in" >"$_is_dir/syncto.service" 2>/dev/null; then
        _is_argv=""
        while IFS= read -r _is_a; do
            _is_argv="$_is_argv \"$_is_a\""
        done <<EOF
$(sched_argv)
EOF
        cat >"$_is_dir/syncto.service" <<EOF || die 1 "cannot write $_is_dir/syncto.service"
[Unit]
Description=syncto scheduled sync pass
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${_is_argv# }
EOF
    fi

    if ! render_template "$SELF_DIR/templates/syncto.timer.in" >"$_is_dir/syncto.timer" 2>/dev/null; then
        cat >"$_is_dir/syncto.timer" <<EOF || die 1 "cannot write $_is_dir/syncto.timer"
[Unit]
Description=syncto scheduled sync timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=${G_INTERVAL}s
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF
    fi

    _is_watch=0
    if any_watch_target; then
        _is_watch=1
        if ! render_template "$SELF_DIR/templates/syncto-watch.service.in" \
                >"$_is_dir/syncto-watch.service" 2>/dev/null; then
            cat >"$_is_dir/syncto-watch.service" <<EOF || die 1 "cannot write $_is_dir/syncto-watch.service"
[Unit]
Description=syncto filesystem watch daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(sched_exec) -w
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
        fi
    fi

    systemctl --user daemon-reload >/dev/null 2>&1 || :
    systemctl --user enable --now syncto.timer >/dev/null 2>&1 ||
        die 1 "wrote the units but 'systemctl --user enable --now syncto.timer' failed"
    printf 'Installed systemd user timer syncto.timer (every %ss)\n' "$G_INTERVAL"
    printf '  units: %s/syncto.{service,timer}\n' "$(path_encode "$_is_dir")"
    log info "" "installed systemd user timer interval=$G_INTERVAL"

    if [ "$_is_watch" -eq 1 ]; then
        systemctl --user enable --now syncto-watch.service >/dev/null 2>&1 ||
            die 1 "wrote the units but 'systemctl --user enable --now syncto-watch.service' failed"
        printf 'Installed systemd user watch daemon syncto-watch.service\n'
        log info "" "installed systemd watch daemon"
    elif [ -f "$_is_dir/syncto-watch.service" ]; then
        # No target wants watching any more: don't leave a resident process behind.
        systemctl --user disable --now syncto-watch.service >/dev/null 2>&1 || :
        rm -f "$_is_dir/syncto-watch.service" || :
        systemctl --user daemon-reload >/dev/null 2>&1 || :
        printf 'Removed systemd user watch daemon (no target has watch=on)\n'
    fi
    return 0
}

uninstall_systemd() {
    _us_dir=$(systemd_dir)
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user disable --now syncto.timer >/dev/null 2>&1 || :
        systemctl --user disable --now syncto-watch.service >/dev/null 2>&1 || :
    fi
    _us_removed=0
    for _us_f in "$_us_dir/syncto.timer" "$_us_dir/syncto.service" \
                 "$_us_dir/syncto-watch.service"; do
        if [ -f "$_us_f" ]; then
            rm -f "$_us_f" || die 1 "cannot remove $_us_f"
            _us_removed=1
        fi
    done
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload >/dev/null 2>&1 || :
    fi
    if [ "$_us_removed" -eq 1 ]; then
        printf 'Removed systemd user timer syncto.timer\n'
    else
        printf 'No systemd user timer installed.\n'
    fi
    log info "" "uninstalled systemd user timer"
    return 0
}

cmd_install_service() {
    case "$(uname -s)" in
        Darwin) install_launchd ;;
        Linux) install_systemd ;;
        *) die 1 "no scheduler support for $(uname -s); run 'syncto --daemon' from cron" ;;
    esac
}

cmd_uninstall_service() {
    case "$(uname -s)" in
        Darwin) uninstall_launchd ;;
        Linux) uninstall_systemd ;;
        *) die 1 "no scheduler support for $(uname -s)" ;;
    esac
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
syncto $SYNCTO_VERSION — unattended git sync for working copies you care about

USAGE
  syncto [-v] [ACTION]

ACTIONS
  (no action)                   list every target with its status
  -s, --sync [NAME]             sync now — all targets, or just NAME
  -a, --add NAME PATH [K=V...]  add a target
  -r, --remove NAME             remove a target
  -e, --edit                    open the targets file in \$EDITOR
  -w, --watch [NAME]            foreground watch loop (NAME, else every watch=on target)
  -d, --daemon                  run one scheduled pass — what launchd/systemd calls
  -i, --install-service         install the launchd agent or systemd user timer
  -u, --uninstall-service       remove it again
  -L, --log                     show the tail of the log
  -v, --verbose                 also echo log lines to stderr (use with any action)
  -h, --help                    this text
  -V, --version                 print the version

TARGET OPTIONS   comma separated key=value; write \\, for a literal comma
  interval=SECONDS      minimum seconds between scheduled syncs   [$G_INTERVAL]
  watch=on|off          include in a bare 'syncto --watch'       [$G_WATCH]
  mode=sync|push|pull   commit+pull+push / commit+push / pull only [$G_MODE]
  branch=NAME           branch to pull and push                   [$G_BRANCH]
  remote=NAME           remote to pull and push                   [$G_REMOTE]
  prefix=TEXT           commit message prefix, "<prefix>: 3 files" [$G_PREFIX]
  guard=CMD             run first; non-zero exit skips this pass
  notify=CMD            run when a sync stops on a conflict
  peer=CMD              run after a push that carried a new commit

  Hooks run with the target as the working directory and with SYNCTO_NAME,
  SYNCTO_PATH, SYNCTO_BRANCH, SYNCTO_REMOTE and SYNCTO_MESSAGE in the
  environment. guard and notify decide the run; peer is always best effort.

FILES
  $(path_encode "$TARGETS_FILE")
      one target per line: NAME<TAB>PATH<TAB>OPTIONS  (\$HOME is stored as ~)
  $(path_encode "$CONFIG_FILE")
      global defaults, one key=value per line: any target option, plus
      log=PATH             where to write the log
      key=PATH             ssh key for git — launchd and systemd have no
                           ssh-agent, so name the key instead of relying on one
      GIT_SSH_COMMAND=CMD  a full ssh command; wins over key= (alias: ssh=)

  key=, GIT_SSH_COMMAND= and ssh= also work as per-target options.
  $(path_encode "$LOG_FILE")
      the log

EXIT CODES
  0  ok
  1  error
  2  conflict — a human has to look at it
  3  configuration error
  4  another run holds the lock

EXAMPLES
  syncto --add notes "\$HOME/notes" interval=300,watch=on,prefix=notes
  syncto --add site "\$HOME/site" mode=pull,branch=trunk
  syncto --sync notes
  syncto --install-service
EOF
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
    load_config
    log_rotate_maybe
    setup_git_env

    action=""
    args_seen=0
    set -- "$@"
    # First pass: pull out -v/--verbose wherever it sits, keep the rest in order.
    rest_count=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            --)
                shift
                while [ "$#" -gt 0 ]; do
                    eval "ARG_$rest_count=\$1"
                    rest_count=$((rest_count + 1))
                    shift
                done
                ;;
            *)
                eval "ARG_$rest_count=\$1"
                rest_count=$((rest_count + 1))
                shift
                ;;
        esac
    done
    set --
    i=0
    while [ "$i" -lt "$rest_count" ]; do
        eval "set -- \"\$@\" \"\$ARG_$i\""
        i=$((i + 1))
    done

    if ! command -v git >/dev/null 2>&1; then
        die 1 "git is not installed (or not on PATH)"
    fi

    action=${1:-}
    args_seen=$#
    if [ "$args_seen" -gt 0 ]; then
        shift
    fi

    case "$action" in
        "")
            cmd_list
            ;;
        -s|--sync)
            cmd_sync "${1:-}"
            ;;
        -a|--add)
            cmd_add "$@"
            ;;
        -r|--remove)
            cmd_remove "${1:-}"
            ;;
        -e|--edit)
            cmd_edit
            ;;
        -w|--watch)
            cmd_watch "${1:-}"
            ;;
        -d|--daemon)
            cmd_daemon
            ;;
        -i|--install-service)
            cmd_install_service
            ;;
        -u|--uninstall-service)
            cmd_uninstall_service
            ;;
        -L|--log)
            cmd_log
            ;;
        -h|--help)
            usage
            ;;
        -V|--version)
            printf 'syncto %s\n' "$SYNCTO_VERSION"
            ;;
        -*)
            warn "unknown option: $action"
            printf "Try 'syncto --help'.\n" >&2
            return 1
            ;;
        *)
            warn "unknown action: $action"
            printf "Try 'syncto --help'.\n" >&2
            return 1
            ;;
    esac
}

rc=0
main "$@" || rc=$?
exit "$rc"
