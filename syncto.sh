#!/usr/bin/env bash
# syncto: unattended git auto-sync. MIT licence.
# Must run on bash 3.2 (macOS stock) and bash 5, BSD and GNU userland.

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
OK_DIR="$STATE_DIR/lastok"
OUTCOME_DIR="$STATE_DIR/outcome"

# Absolute path of this script, without readlink -f (not portable).
SELF="$0"
case "$SELF" in
    /*) : ;;
    *)  SELF="$PWD/$SELF" ;;
esac

VERBOSE=0
# 1 under -d/-w: the units already send stderr to LOG_FILE.
DAEMON=0
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
    if [ "$VERBOSE" -eq 1 ] || { [ "$DAEMON" -eq 0 ] && { [ "$_lg_level" = "error" ] || [ "$_lg_level" = "conflict" ]; }; }; then
        printf '%s\n' "$_lg_line" >&2
    fi
    return 0
}

# log_rotate_maybe: checked once per run; keeps one old generation (.1).
# `wc -c`, not `stat`: stat's flags differ between BSD and GNU.
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
        \~) printf '%s' "$HOME" ;;
        \~/*) printf '%s%s' "$HOME" "${1#\~}" ;;
        *) printf '%s' "$1" ;;
    esac
}

abs_path() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        \~) printf '%s' "$HOME" ;;
        \~/*) printf '%s%s' "$HOME" "${1#\~}" ;;
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
        interval|watch|mode|branch|remote|prefix|guard|notify|peer|stale|paused) return 0 ;;
        key|ssh|GIT_SSH_COMMAND|log|debounce|log_max|remote_poll) return 0 ;;
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
        watch|paused)
            case "$2" in
                on|off) : ;;
                *) warn "$1 must be 'on' or 'off', got '$2'"; return 1 ;;
            esac
            ;;
        remote_poll)
            case "$2" in
                off) : ;;
                ''|*[!0-9]*) warn "remote_poll must be a whole number of seconds or 'off', got '$2'"; return 1 ;;
            esac
            ;;
        stale)
            case "$2" in
                off) : ;;
                ''|*[!0-9]*) warn "stale must be a whole number of seconds or 'off', got '$2'"; return 1 ;;
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
G_STALE=0
G_REMOTE_POLL=0
G_WATCH=off
G_PAUSED=off
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
# Rotate the log past this many bytes (0 disables).
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
            paused)   G_PAUSED=$_lc_v ;;
            debounce) G_DEBOUNCE=$_lc_v ;;
            log_max)  LOG_MAX=$_lc_v ;;
            mode)     G_MODE=$_lc_v ;;
            branch)   G_BRANCH=$_lc_v ;;
            remote)   G_REMOTE=$_lc_v ;;
            prefix)   G_PREFIX=$_lc_v ;;
            guard)    G_GUARD=$_lc_v ;;
            stale)    G_STALE=$_lc_v ;;
            remote_poll) G_REMOTE_POLL=$_lc_v ;;
            notify)   G_NOTIFY=$_lc_v ;;
            peer)     G_PEER=$_lc_v ;;
            key)      G_KEY=$(path_decode "$_lc_v") ;;
            ssh|GIT_SSH_COMMAND) G_SSH=$_lc_v ;;
            log)      LOG_FILE=$(path_decode "$_lc_v") ;;
        esac
    done <"$CONFIG_FILE"
    return 0
}

# Schedulers run without an ssh-agent, so git may need an explicit transport.
setup_git_env() {
    GIT_TERMINAL_PROMPT=0
    export GIT_TERMINAL_PROMPT
    apply_ssh_env "$G_SSH" "$G_KEY"
}

# apply_ssh_env SSH_COMMAND KEY_PATH: scoped per target, cleared when neither is set.
# shellcheck disable=SC2089,SC2090 # git runs GIT_SSH_COMMAND through a shell
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

# tg_paused INDEX -> 0 if the target has paused=on (sets t_* for it)
tg_paused() {
    resolve_opts "$(tg_opts "$1")" || :
    [ "$t_paused" = "on" ]
}

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
    t_paused=$G_PAUSED
    t_debounce=$G_DEBOUNCE
    t_mode=$G_MODE
    t_branch=$G_BRANCH
    t_remote=$G_REMOTE
    t_prefix=$G_PREFIX
    t_guard=$G_GUARD
    t_stale=$G_STALE
    t_remote_poll=$G_REMOTE_POLL
    t_notify=$G_NOTIFY
    t_peer=$G_PEER
    t_key=$G_KEY
    t_ssh=$G_SSH
    t_rc=0
    [ "$t_remote_poll" = "off" ] && t_remote_poll=0
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
            paused)   t_paused=$_ro_v ;;
            debounce) t_debounce=$_ro_v ;;
            mode)     t_mode=$_ro_v ;;
            branch)   t_branch=$_ro_v ;;
            remote)   t_remote=$_ro_v ;;
            prefix)   t_prefix=$_ro_v ;;
            guard)    t_guard=$_ro_v ;;
            stale)    t_stale=$_ro_v ;;
            remote_poll) t_remote_poll=$_ro_v ;;
            notify)   t_notify=$_ro_v ;;
            peer)     t_peer=$_ro_v ;;
            key)      t_key=$(path_decode "$_ro_v") ;;
            ssh|GIT_SSH_COMMAND) t_ssh=$_ro_v ;;
            log|log_max) : ;;
        esac
    done <<EOF
$(split_opts "$_ro_opts")
EOF
    [ "$t_remote_poll" = "off" ] && t_remote_poll=0
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
    if [ -n "${P_PID:-}" ]; then
        kill "$P_PID" 2>/dev/null || :
    fi
}
trap on_exit EXIT
trap 'lock_release; exit 1' INT TERM HUP

# ---------------------------------------------------------------------------
# notify throttle
# ---------------------------------------------------------------------------

NOTIFY_DIR="$STATE_DIR/notified"
NOTIFY_COOLDOWN=${SYNCTO_NOTIFY_COOLDOWN:-1800}

# notify_due NAME -> 0 if an alert may go out, 1 within the cooldown.
# Keyed by target, not message: git's wording varies between passes.
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

# notify_clear NAME: the target synced cleanly, so forget the last alert.
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

# Transport failures: warn, never notify; the next pass catches up.
is_transport_error() {
    case "$1" in
        *"Could not resolve hostname"*|\
        *"Temporary failure in name resolution"*|\
        *"Connection timed out"*|\
        *"Connection reset by "*|\
        *"Connection closed by "*|\
        *"closed by remote host"*|\
        *"Connection refused"*|\
        *"Network is unreachable"*|\
        *"No route to host"*|\
        *"Operation timed out"*|\
        *"kex_exchange_identification"*)
            return 0
            ;;
    esac
    return 1
}

# A remote that is not configured, or whose path is no repository: a setup
# problem (exit 3), not a conflict.
is_remote_missing() {
    case "$1" in
        *"does not appear to be a git repository"*|*"No such remote"*) return 0 ;;
    esac
    return 1
}

# Auth failures: an error, not a conflict; stale= reports them if they last.
is_auth_error() {
    case "$1" in
        *"Permission denied (publickey"*|\
        *"Authentication failed"*)
            return 0
            ;;
    esac
    return 1
}

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

    # 1. lock first: a second run must never race the first one.
    _s_stale=$((t_interval * 10))
    if ! lock_acquire "$name" "$_s_stale"; then
        log warn "$name" "lock held by another run, skipping"
        return 4
    fi

    if [ ! -d "$path" ]; then
        outcome "$name" error "path does not exist: $path"
        lock_release
        return 3
    fi
    if ! git_in "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        outcome "$name" error "not a git working tree: $path"
        lock_release
        return 3
    fi

    apply_ssh_env "$t_ssh" "$t_key"
    _s_code=0
    sync_locked || _s_code=$?
    apply_ssh_env "$G_SSH" "$G_KEY"
    lock_release
    stale_check "$name"
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
            outcome "$name" conflict "an unfinished rebase/merge is in progress, needs a human"
            return 2
        fi
    fi

    _head=$(git_in "$path" symbolic-ref -q --short HEAD 2>/dev/null || printf '')
    if [ -z "$_head" ]; then
        outcome "$name" conflict "HEAD is detached, refusing to sync"
        return 2
    fi
    if [ "$_head" != "$t_branch" ]; then
        log warn "$name" "checked out branch is '$_head' but configured branch is '$t_branch'"
    fi

    _committed=0
    _pull_skipped=0
    _rc=0

    # 3./4. stage and commit
    if [ "$t_mode" != "pull" ]; then
        _out=""
        if ! _out=$(git_in "$path" add -A 2>&1); then
            outcome "$name" error "git add -A failed: $_out"
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
                outcome "$name" error "commit failed ($_crc): $_out"
                return 1
            fi
            _committed=1
            log info "$name" "committed: $_msg"
        fi
    fi

    # Never rebase into a dirty tree: rewriting files moves an open editor's
    # caret. Defer the pull instead; the push below never touches the tree.
    if [ "$t_mode" != "push" ] && \
       [ -n "$(git_in "$path" status --porcelain 2>/dev/null)" ]; then
        log info "$name" "tree went dirty again, deferring the pull to the next pass"
        _pull_skipped=1
    fi

    # 5. pull --rebase, into a clean tree only
    if [ "$t_mode" != "push" ] && [ "$_pull_skipped" -eq 0 ]; then
        _out=""
        _prc=0
        _out=$(git_in "$path" pull --rebase --no-autostash "$t_remote" "$t_branch" 2>&1) || _prc=$?
        # The tree may go dirty after the check: without --autostash git then
        # refuses instead of clobbering, so defer quietly.
        if [ "$_prc" -ne 0 ]; then
            case "$_out" in
                *"unstaged changes"*|*"uncommitted changes"*|\
                *"local changes would be overwritten"*|\
                *"Please commit your changes or stash them"*)
                    git_in "$path" rebase --abort >/dev/null 2>&1 || :
                    log info "$name" "tree went dirty mid-pull, deferring to the next pass"
                    _pull_skipped=1
                    _prc=0
                    ;;
            esac
        fi
        # A concurrent `git pull` leaves two lines in FETCH_HEAD: retry once.
        if [ "$_prc" -ne 0 ]; then
            case "$_out" in
                *"Cannot rebase onto multiple branches"*)
                    log warn "$name" "FETCH_HEAD race with a concurrent git, retrying once"
                    git_in "$path" rebase --abort >/dev/null 2>&1 || :
                    sleep 3
                    _out=""
                    _prc=0
                    _out=$(git_in "$path" pull --rebase --no-autostash "$t_remote" "$t_branch" 2>&1) || _prc=$?
                    ;;
            esac
        fi
        if [ "$_prc" -ne 0 ] && is_transport_error "$_out"; then
            git_in "$path" rebase --abort >/dev/null 2>&1 || :
            outcome "$name" offline "$_out"
            return 0
        fi
        if [ "$_prc" -ne 0 ] && is_remote_missing "$_out"; then
            git_in "$path" rebase --abort >/dev/null 2>&1 || :
            outcome "$name" error "remote '$t_remote' not found: $_out"
            return 3
        fi
        if [ "$_prc" -ne 0 ] && is_auth_error "$_out"; then
            git_in "$path" rebase --abort >/dev/null 2>&1 || :
            outcome "$name" error "pull failed, authentication refused: $_out"
            return 1
        fi
        if [ "$_prc" -ne 0 ]; then
            case "$_out" in
                *"ouldn't find remote ref"*)
                    # The branch is not on the remote yet: the push below creates it.
                    log warn "$name" "$t_remote has no branch '$t_branch' yet, pushing to create it"
                    _prc=0
                    ;;
            esac
        fi
        if [ "$_prc" -ne 0 ]; then
            git_in "$path" rebase --abort >/dev/null 2>&1 || :
            outcome "$name" conflict "pull --rebase failed, aborted: $_out"
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
            # With the pull deferred, a rejected push is expected.
            if [ "$_pull_skipped" -eq 1 ]; then
                case "$_out" in
                    *"non-fast-forward"*|*"fetch first"*|*"rejected"*)
                        log info "$name" "push deferred with the pull, $t_remote is ahead"
                        return 0
                        ;;
                esac
            fi
            if is_transport_error "$_out"; then
                outcome "$name" offline "$_out"
                return 0
            fi
            if is_remote_missing "$_out"; then
                outcome "$name" error "remote '$t_remote' not found: $_out"
                return 3
            fi
            outcome "$name" error "push failed ($_prc): $_out"
            return 1
        fi
    fi

    notify_clear "$name"
    mark_ok "$name"
    rm -f "$OUTCOME_DIR/$(safe_name "$name")" 2>/dev/null || :
    _pulled=1
    [ "$_pull_skipped" -eq 1 ] && _pulled=0
    [ "$t_mode" = "push" ] && _pulled=0
    log info "$name" "sync ok (mode=$t_mode branch=$t_branch remote=$t_remote committed=$_committed pulled=$_pulled)"

    # 7. poke the peer, best effort; never fails the run
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

# mark_ok / last_ok: the last pass that actually synced (mark_run: attempted).
mark_ok() {
    mkdir -p "$OK_DIR" 2>/dev/null || :
    printf '%s\n' "$(epoch)" >"$OK_DIR/$(safe_name "$1")" 2>/dev/null || :
    return 0
}

last_ok() {
    _lo_f="$OK_DIR/$(safe_name "$1")"
    _lo_v=0
    if [ -f "$_lo_f" ]; then
        _lo_v=$(sed -n '1p' "$_lo_f" 2>/dev/null || printf '0')
    fi
    case "$_lo_v" in
        ''|*[!0-9]*) _lo_v=0 ;;
    esac
    printf '%s' "$_lo_v"
}

# outcome NAME KIND MESSAGE: log a failed pass and keep it for status.
# KIND is conflict, error or offline (logged as warn).
outcome() {
    if [ "$2" = "offline" ]; then
        log warn "$1" "network unreachable, retrying next pass: $3"
    else
        log "$2" "$1" "$3"
    fi
    mkdir -p "$OUTCOME_DIR" 2>/dev/null || :
    printf '%s\t%s\t%s\n' "$2" "$(epoch)" "$(oneline "$3")" \
        >"$OUTCOME_DIR/$(safe_name "$1")" 2>/dev/null || :
    return 0
}

# stale_limit -> seconds without a sync before a target is stale, or "off".
# 0 derives it from the interval. Uses the caller's t_*.
stale_limit() {
    if [ "$t_stale" = "off" ]; then
        printf 'off'
        return 0
    fi
    _sl=$t_stale
    [ "$_sl" -eq 0 ] && _sl=$((t_interval * 12))
    [ "$_sl" -lt 600 ] && _sl=600
    printf '%s' "$_sl"
}

# stale_check NAME: alert when a target has not synced for too long,
# whatever the cause. Uses the caller's t_*.
stale_check() {
    _sc_name=$1
    _sc_limit=$(stale_limit)
    [ "$_sc_limit" = "off" ] && return 0
    _sc_last=$(last_ok "$_sc_name")
    if [ "$_sc_last" -eq 0 ]; then
        # First run: start the clock instead of alerting.
        mark_ok "$_sc_name"
        return 0
    fi
    _sc_age=$(( $(epoch) - _sc_last ))
    [ "$_sc_age" -lt "$_sc_limit" ] && return 0
    log warn "$_sc_name" "no successful sync in ${_sc_age}s (limit ${_sc_limit}s)"
    if [ -n "$t_notify" ] && notify_due "$_sc_name"; then
        _sc_out=""
        _sc_rc=0
        _sc_out=$(run_hook "$t_notify" "$path" "$_sc_name" \
            "syncto: $_sc_name has not synced in ${_sc_age}s, see: syncto status") || _sc_rc=$?
        if [ "$_sc_rc" -ne 0 ]; then
            log warn "$_sc_name" "notify hook exited $_sc_rc: $_sc_out"
        fi
    fi
    return 0
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
    printf 'Add one with:  syncto add NAME PATH [key=value ...]\n' >&2
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
        if [ -z "$_cs_only" ] && tg_paused "$_cs_i"; then
            log info "$_cs_name" "paused, skipping"
            _cs_i=$((_cs_i + 1))
            continue
        fi
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

cmd_run() {
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
        if [ "$t_paused" = "on" ]; then
            _cd_i=$((_cd_i + 1))
            continue
        fi
        _cd_last=$(last_run "$_cd_name")
        _cd_age=$((_cd_now - _cd_last))
        # Grace window (10% of the interval, 5..30 s): schedulers drift, and an
        # exact interval would skip every other pass.
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

# human_ago SECONDS -> "just now", "4 min ago", "3 h ago", "2 days ago"
human_ago() {
    if [ "$1" -lt 60 ]; then
        printf 'just now'
    elif [ "$1" -lt 3600 ]; then
        printf '%s min ago' $(($1 / 60))
    elif [ "$1" -lt 172800 ]; then
        printf '%s h ago' $(($1 / 3600))
    else
        printf '%s days ago' $(($1 / 86400))
    fi
}

# human_every SECONDS -> "every 10 min", "every 1 h", "every 90 s"
human_every() {
    if [ $(($1 % 3600)) -eq 0 ]; then
        printf 'every %s h' $(($1 / 3600))
    elif [ $(($1 % 60)) -eq 0 ]; then
        printf 'every %s min' $(($1 / 60))
    else
        printf 'every %s s' "$1"
    fi
}

# cd_hint PATH -> a cd command a user can paste
cd_hint() {
    case "$1" in
        *" "*) printf 'cd "%s"' "$1" ;;
        *) printf 'cd %s' "$(path_encode "$1")" ;;
    esac
}

# target_health INDEX: sets H_LEVEL (ok, wait, warn, bad), H_TEXT, H_DETAIL,
# H_FIX and H_HOW for that target, in words a person can act on.
target_health() {
    _th_name=$(tg_name "$1")
    _th_path=$(tg_path "$1")
    resolve_opts "$(tg_opts "$1")" || :
    H_DETAIL=""
    H_FIX=""
    if [ "$t_watch" = "on" ]; then
        H_HOW="on save"
    else
        H_HOW=$(human_every "$t_interval")
    fi
    case "$t_mode" in
        push) H_HOW="$H_HOW, push only" ;;
        pull) H_HOW="$H_HOW, pull only" ;;
    esac

    if [ ! -d "$_th_path" ]; then
        H_LEVEL=bad H_TEXT="folder is missing" H_FIX="restore it, or: syncto remove $_th_name"
        return 0
    fi
    if ! git_in "$_th_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        H_LEVEL=bad H_TEXT="not a git repo" H_FIX="git init it, or: syncto remove $_th_name"
        return 0
    fi

    _th_now=$(epoch)
    _th_ok=$(last_ok "$_th_name")
    _th_kind=""
    _th_msg=""
    _th_f="$OUTCOME_DIR/$(safe_name "$_th_name")"
    if [ -f "$_th_f" ]; then
        IFS="$TAB" read -r _th_kind _th_since _th_msg <"$_th_f" || :
    fi
    _th_cd=$(cd_hint "$_th_path")
    if [ "$t_paused" = "on" ] && [ "$_th_kind" != "conflict" ] && [ "$_th_kind" != "error" ]; then
        H_LEVEL=wait H_TEXT="paused"
        H_FIX="resume: syncto edit $_th_name paused=off"
        return 0
    fi
    case "$_th_kind" in
        conflict)
            H_LEVEL=bad H_TEXT="needs you"
            case "$_th_msg" in
                *"unfinished rebase"*)
                    H_DETAIL="a rebase or merge was left unfinished"
                    H_FIX="$_th_cd && git status, then finish or abort it"
                    ;;
                *"HEAD is detached"*)
                    H_DETAIL="HEAD is detached"
                    H_FIX="$_th_cd && git switch $t_branch"
                    ;;
                *)
                    _th_files=$(printf '%s\n' "$_th_msg" | grep -o 'Merge conflict in [^ ]*' |
                        sed 's/^Merge conflict in //' | sort -u | paste -sd, - | sed 's/,/, /g')
                    if [ -n "$_th_files" ]; then
                        H_DETAIL="both sides changed $_th_files"
                    else
                        H_DETAIL="the pull could not be applied: $_th_msg"
                    fi
                    H_FIX="$_th_cd && git pull --rebase, fix the files, git rebase --continue"
                    ;;
            esac
            return 0
            ;;
        error)
            H_LEVEL=bad H_TEXT="failing"
            case "$_th_msg" in
                *"remote '"*"' not found"*)
                    H_DETAIL="the remote '$t_remote' is missing or not a git repository"
                    H_FIX="$_th_cd && git remote -v, and if it is missing: git remote add $t_remote URL"
                    ;;
                *"authentication refused"*)
                    H_DETAIL="the remote refused the credentials"
                    H_FIX="check the ssh key (key= option) can push to $t_remote"
                    ;;
                *) H_DETAIL=$_th_msg ;;
            esac
            return 0
            ;;
        offline)
            H_LEVEL=wait H_TEXT="offline, retrying"
            if [ "$_th_ok" -gt 0 ]; then
                H_DETAIL="last synced $(human_ago $((_th_now - _th_ok))). $_th_msg"
            else
                H_DETAIL=$_th_msg
            fi
            return 0
            ;;
    esac

    if [ "$(last_run "$_th_name")" -eq 0 ]; then
        H_LEVEL=wait H_TEXT="not synced yet"
        return 0
    fi
    _th_limit=$(stale_limit)
    if [ "$_th_limit" != "off" ] && [ $((_th_now - _th_ok)) -ge "$_th_limit" ]; then
        H_LEVEL=warn H_TEXT="no sync for $(human_ago $((_th_now - _th_ok)) | sed 's/ ago$//')"
        H_DETAIL="passes keep being skipped (guard, or edits in progress)"
        H_FIX="syncto log"
        return 0
    fi
    H_LEVEL=ok H_TEXT="synced $(human_ago $((_th_now - _th_ok)))"
    return 0
}

# background_state -> "on", "on+watch", "stopped" (installed, not running) or "off"
background_state() {
    case "$(uname -s)" in
        Darwin)
            [ -f "$(plist_path)" ] || { printf 'off'; return 0; }
            launchctl print "gui/$(id -u)/$SYNCTO_LABEL" >/dev/null 2>&1 || { printf 'stopped'; return 0; }
            if [ -f "$(watch_plist_path)" ] &&
               launchctl print "gui/$(id -u)/$SYNCTO_LABEL-watch" >/dev/null 2>&1; then
                printf 'on+watch'
            else
                printf 'on'
            fi
            ;;
        Linux)
            [ -f "$(systemd_dir)/syncto.timer" ] || { printf 'off'; return 0; }
            systemctl --user is-active --quiet syncto.timer 2>/dev/null || { printf 'stopped'; return 0; }
            if [ -f "$(systemd_dir)/syncto-watch.service" ] &&
               systemctl --user is-active --quiet syncto-watch.service 2>/dev/null; then
                printf 'on+watch'
            else
                printf 'on'
            fi
            ;;
        *) printf 'off' ;;
    esac
}

cmd_status() {
    targets_load
    if [ "$TG_COUNT" -eq 0 ]; then
        no_targets_notice
        return 0
    fi

    C_OK="" C_WAIT="" C_WARN="" C_BAD="" C_DIM="" C_OFF=""
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
        C_OK=$(printf '\033[32m') C_WAIT=$(printf '\033[2m') C_WARN=$(printf '\033[33m')
        C_BAD=$(printf '\033[31m') C_DIM=$(printf '\033[2m') C_OFF=$(printf '\033[0m')
    fi
    _st_cols=${COLUMNS:-$(tput cols 2>/dev/null || printf '100')}
    case "$_st_cols" in ''|*[!0-9]*) _st_cols=100 ;; esac

    _st_w=4
    _st_i=0
    while [ "$_st_i" -lt "$TG_COUNT" ]; do
        _st_n=$(tg_name "$_st_i")
        [ "${#_st_n}" -gt "$_st_w" ] && _st_w=${#_st_n}
        _st_i=$((_st_i + 1))
    done
    _st_pad=$(printf "%$((_st_w + 4))s" "")
    _st_room=$((_st_cols - _st_w - 4))
    [ "$_st_room" -lt 20 ] && _st_room=20

    _st_i=0
    while [ "$_st_i" -lt "$TG_COUNT" ]; do
        target_health "$_st_i"
        case "$H_LEVEL" in
            ok) _st_sym="✓" _st_c=$C_OK ;;
            wait) _st_sym="·" _st_c=$C_WAIT ;;
            warn) _st_sym="!" _st_c=$C_WARN ;;
            *) _st_sym="✗" _st_c=$C_BAD ;;
        esac
        printf "%-${_st_w}s  %s%s %-20s%s  %-15s %s\n" "$(tg_name "$_st_i")" \
            "$_st_c" "$_st_sym" "$H_TEXT" "$C_OFF" "$H_HOW" "$(path_encode "$(tg_path "$_st_i")")"
        _st_line=$H_DETAIL
        # Long git output is cut to the terminal width; the fix line never is.
        if [ -t 1 ] && [ "${#_st_line}" -gt "$_st_room" ]; then
            _st_line="$(printf '%s' "$_st_line" | cut -c1-$((_st_room - 1)))…"
        fi
        [ -n "$_st_line" ] && printf '%s%s%s%s\n' "$_st_pad" "$C_DIM" "$_st_line" "$C_OFF"
        [ -n "$H_FIX" ] && printf '%sfix: %s\n' "$_st_pad" "$H_FIX"
        _st_i=$((_st_i + 1))
    done

    printf '\n'
    case "$(background_state)" in
        on+watch) printf 'Background: on, %s, and on every save.\n' "$(human_every "$G_INTERVAL")" ;;
        on) printf 'Background: on, %s.\n' "$(human_every "$G_INTERVAL")" ;;
        stopped) printf "Background: installed but not running. Restart it with: syncto start\n" ;;
        *) printf "Background: off. Turn it on with: syncto start\n" ;;
    esac
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
            printf '# options: interval= watch= mode= branch= remote= prefix= guard= stale= notify= peer= remote_poll=\n'
        } >"$TARGETS_FILE" || die 3 "cannot write $TARGETS_FILE"
    fi
    return 0
}

# opts_from_args MODE ARGS...: validated key=value lines from options given one
# per argument, comma joined, or any mix. MODE edit accepts "key=" (reset).
opts_from_args() {
    _oa_mode=$1
    shift
    for _oa_arg in "$@"; do
        while IFS= read -r _oa_kv; do
            _oa_kv=$(trim "$_oa_kv")
            [ -n "$_oa_kv" ] || continue
            case "$_oa_kv" in
                *=*) : ;;
                *) die 3 "options must be key=value, got '$_oa_kv'" ;;
            esac
            _oa_k=$(trim "${_oa_kv%%=*}")
            _oa_v=${_oa_kv#*=}
            known_key "$_oa_k" || die 3 "unknown option '$_oa_k'"
            if [ -n "$_oa_v" ] || [ "$_oa_mode" != "edit" ]; then
                validate_value "$_oa_k" "$_oa_v" || die 3 "bad value for '$_oa_k'"
            fi
            printf '%s=%s\n' "$_oa_k" "$_oa_v"
        done <<EOF
$(split_opts "$_oa_arg")
EOF
    done
}

# opts_join: key=value lines on stdin -> one comma list, commas in values escaped.
opts_join() {
    _oj=""
    while IFS= read -r _oj_kv; do
        [ -n "$_oj_kv" ] || continue
        _oj_kv="${_oj_kv%%=*}=$(printf '%s' "${_oj_kv#*=}" | sed 's/,/\\,/g')"
        _oj="${_oj:+$_oj,}$_oj_kv"
    done
    printf '%s' "$_oj"
}

# targets_rewrite NAME LINE: replace NAME's line with LINE, or drop it if LINE is empty.
targets_rewrite() {
    _tr_tmp=$(mktemp "${TMPDIR:-/tmp}/syncto.XXXXXX") || die 1 "cannot create a temp file"
    while IFS= read -r _tr_line || [ -n "$_tr_line" ]; do
        _tr_first=${_tr_line%%"$TAB"*}
        if [ "$_tr_first" = "$1" ] && [ "$_tr_first" != "$_tr_line" ]; then
            [ -n "$2" ] && printf '%s\n' "$2" >>"$_tr_tmp"
            continue
        fi
        printf '%s\n' "$_tr_line" >>"$_tr_tmp"
    done <"$TARGETS_FILE"
    cat "$_tr_tmp" >"$TARGETS_FILE" || { rm -f "$_tr_tmp"; die 1 "cannot rewrite $TARGETS_FILE"; }
    rm -f "$_tr_tmp"
}

cmd_add() {
    _ca_name=${1:-}
    _ca_path=${2:-}
    [ -n "$_ca_name" ] || die 3 "usage: syncto add NAME PATH [key=value ...]"
    [ -n "$_ca_path" ] || die 3 "usage: syncto add NAME PATH [key=value ...]"
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

    _ca_kvs=$(opts_from_args add "$@") || exit $?
    _ca_opts=$(printf '%s\n' "$_ca_kvs" | opts_join)

    if ! git -C "$_ca_abs" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        warn "$_ca_abs is not a git working tree (yet): adding anyway"
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
    [ -n "$_cr_name" ] || die 3 "usage: syncto remove NAME"
    [ -f "$TARGETS_FILE" ] || die 3 "no such target: $_cr_name"

    targets_load
    tg_index_of "$_cr_name" >/dev/null || die 3 "no such target: $_cr_name"

    targets_rewrite "$_cr_name" ""
    printf 'Removed %s\n' "$_cr_name"
    log info "$_cr_name" "removed target"
    rm -f "$LAST_DIR/$(safe_name "$_cr_name")" 2>/dev/null || :
    rm -f "$OK_DIR/$(safe_name "$_cr_name")" 2>/dev/null || :
    rm -f "$OUTCOME_DIR/$(safe_name "$_cr_name")" 2>/dev/null || :
    return 0
}

cmd_edit() {
    if [ "$#" -eq 0 ]; then
        ensure_targets_file
        _ce_ed=${EDITOR:-${VISUAL:-vi}}
        # $EDITOR may carry flags, so let the shell split it, but keep the path quoted.
        sh -c "$_ce_ed \"\$1\"" sh "$TARGETS_FILE"
        return
    fi
    _ce_name=$1
    shift
    [ "$#" -gt 0 ] || die 3 "usage: syncto edit NAME key=value ...  (plain 'syncto edit' opens the file)"
    targets_load
    _ce_i=$(tg_index_of "$_ce_name") || die 3 "no such target: $_ce_name"
    _ce_new=$(opts_from_args edit "$@") || exit $?
    _ce_cur=$(split_opts "$(tg_opts "$_ce_i")")
    while IFS= read -r _ce_kv; do
        [ -n "$_ce_kv" ] || continue
        _ce_cur=$(printf '%s\n' "$_ce_cur" | grep -v "^${_ce_kv%%=*}=" || :)
        if [ -n "${_ce_kv#*=}" ]; then
            _ce_cur=$(printf '%s\n%s' "$_ce_cur" "$_ce_kv")
        fi
    done <<EOF
$_ce_new
EOF
    _ce_opts=$(printf '%s\n' "$_ce_cur" | opts_join)
    targets_rewrite "$_ce_name" \
        "$(printf '%s\t%s\t%s' "$_ce_name" "$(path_encode "$(tg_path "$_ce_i")")" "$_ce_opts")"
    printf 'Updated %s: %s\n' "$_ce_name" "${_ce_opts:-all defaults}"
    log info "$_ce_name" "edited target [$_ce_opts]"
    case "$_ce_new" in
        *watch=*|*remote_poll=*) printf "Run 'syncto start' so background syncing picks up the change.\n" ;;
    esac
    return 0
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
        # One watcher for all targets, so it uses the longest debounce.
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
    # Ignore .git: syncing writes there, so counting it would loop forever.
    # Backstop for watchers that don't exclude it themselves.
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
        # shellcheck disable=SC2154 # set by eval
        if [ "$_wf_p" -eq 1 ]; then
            eval "W_PEND_$_wf_i=0"
            _wf_idx=$(w_idx "$_wf_i")
            _wf_name=$(tg_name "$_wf_idx")
            if tg_paused "$_wf_idx"; then
                _wf_i=$((_wf_i + 1))
                continue
            fi
            # A clean tree means only ignored paths changed: skip the network
            # round trip. Inbound still arrives via peer= and the interval.
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
    poll_collect "${1:-}"
    if [ "$W_COUNT" -eq 0 ] && [ "$P_COUNT" -eq 0 ]; then
        if [ -n "${1:-}" ]; then
            die 3 "no such target: $1"
        fi
        die 3 "no targets have watch=on or remote_poll; add one with 'syncto add NAME PATH watch=on'"
    fi

    if [ "$P_COUNT" -gt 0 ]; then
        log info "" "polling ${P_COUNT} remote(s) every ${P_TICK}s"
        if [ "$W_COUNT" -eq 0 ]; then
            poll_loop
            return 0
        fi
        poll_loop &
        P_PID=$!
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
        printf 'syncto: watching %s target(s) with fswatch, ctrl-c to stop\n' "$W_COUNT" >&2
        watch_loop_fswatch "$@"
    elif command -v inotifywait >/dev/null 2>&1; then
        log info "" "watching ${W_COUNT} target(s) with inotifywait"
        printf 'syncto: watching %s target(s) with inotifywait, ctrl-c to stop\n' "$W_COUNT" >&2
        watch_loop_inotify "$@"
    else
        log info "" "watching ${W_COUNT} target(s) by polling"
        printf 'syncto: no fswatch or inotifywait found: polling every %ss, ctrl-c to stop\n' "$W_DEBOUNCE" >&2
        watch_loop_poll
    fi
    return 0
}

watch_loop_fswatch() {
    # -0: NUL separated. -E: without it --exclude is a basic regex and
    # silently matches nothing.
    fswatch -0 -r -E --exclude '/\.git(/|$)' "$@" | {
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
            # shellcheck disable=SC2154 # set by eval
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
# remote poll: the inbound direction for pushes no peer= wake announces
# ---------------------------------------------------------------------------

P_COUNT=0
P_PID=""

poll_collect() {
    # Poll set: NAME, or every target with remote_poll > 0 that pulls.
    _pc_only=${1:-}
    P_COUNT=0
    P_TICK=0
    _pc_i=0
    while [ "$_pc_i" -lt "$TG_COUNT" ]; do
        resolve_opts "$(tg_opts "$_pc_i")" || :
        if { [ -z "$_pc_only" ] || [ "$_pc_only" = "$(tg_name "$_pc_i")" ]; } &&
           [ "$t_remote_poll" -gt 0 ] && [ "$t_mode" != "push" ]; then
            eval "P_IDX_$P_COUNT=\$_pc_i"
            eval "P_EVERY_$P_COUNT=\$t_remote_poll"
            eval "P_LAST_$P_COUNT=0"
            if [ "$P_COUNT" -eq 0 ] || [ "$t_remote_poll" -lt "$P_TICK" ]; then
                P_TICK=$t_remote_poll
            fi
            P_COUNT=$((P_COUNT + 1))
        fi
        _pc_i=$((_pc_i + 1))
    done
    return 0
}

# remote_moved INDEX -> 0 if the remote head is a commit this clone lacks.
# One cheap ls-remote; an unreachable remote reads as not moved.
remote_moved() {
    _rm_path=$(tg_path "$1")
    resolve_opts "$(tg_opts "$1")" || :
    apply_ssh_env "$t_ssh" "$t_key"
    _rm_sha=$(git_in "$_rm_path" ls-remote "$t_remote" "refs/heads/$t_branch" 2>/dev/null |
        awk 'NR == 1 { print $1 }') || _rm_sha=""
    apply_ssh_env "$G_SSH" "$G_KEY"
    [ -n "$_rm_sha" ] || return 1
    if git_in "$_rm_path" merge-base --is-ancestor "$_rm_sha" HEAD >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

poll_loop() {
    trap 'lock_release; exit 0' INT TERM HUP
    while :; do
        # sleep in the background so a TERM interrupts the wait at once
        sleep "$P_TICK" &
        wait $! || :
        _pl_now=$(epoch)
        _pl_i=0
        while [ "$_pl_i" -lt "$P_COUNT" ]; do
            eval "_pl_last=\$P_LAST_$_pl_i; _pl_every=\$P_EVERY_$_pl_i; _pl_idx=\$P_IDX_$_pl_i"
            # shellcheck disable=SC2154 # set by eval
            if [ $((_pl_now - _pl_last)) -ge "$_pl_every" ]; then
                eval "P_LAST_$_pl_i=\$_pl_now"
                if ! tg_paused "$_pl_idx" && remote_moved "$_pl_idx"; then
                    _pl_name=$(tg_name "$_pl_idx")
                    log info "$_pl_name" "remote_poll: $t_remote/$t_branch moved, syncing"
                    _pl_one=0
                    sync_one "$_pl_idx" || _pl_one=$?
                    if [ "$_pl_one" -ne 4 ]; then
                        mark_run "$_pl_name"
                    fi
                fi
            fi
            _pl_i=$((_pl_i + 1))
        done
    done
}

# ---------------------------------------------------------------------------
# scheduler units
# ---------------------------------------------------------------------------

xml_escape() {
    printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

SHELL_BIN="/bin/bash"

# The scheduler's command: the installed entry point, else this file.
sched_exec() {
    if [ -x "$HOME/.local/bin/syncto" ]; then
        printf '%s' "$HOME/.local/bin/syncto"
    else
        printf '%s' "$SELF"
    fi
}

# Print the ProgramArguments / ExecStart words, one per line.
# macOS always goes through $SHELL_BIN: TCC grants (Full Disk Access) attach
# to the binary launchd exec'd, and a script holds none.
sched_argv() {
    _sa_exec=$(sched_exec)
    if [ ! -x "$_sa_exec" ] || [ "$(uname -s)" = "Darwin" ]; then
        printf '%s\n' "$SHELL_BIN"
    fi
    printf '%s\nrun\n' "$_sa_exec"
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
        {
            printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
            printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
            printf '%s\n' '<plist version="1.0">'
            printf '%s\n' '<dict>'
            printf '    <key>Label</key>\n    <string>%s-watch</string>\n' "$(xml_escape "$SYNCTO_LABEL")"
            printf '    <key>ProgramArguments</key>\n    <array>\n'
            printf '        <string>%s</string>\n' "$(xml_escape "$SHELL_BIN")"
            printf '        <string>%s</string>\n' "$(xml_escape "$(sched_exec)")"
            printf '        <string>watch</string>\n'
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
        printf 'Removed launchd watch agent (no target has watch=on or remote_poll)\n'
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

# any_watch_target -> 0 if a target has watch=on or remote_poll (both need
# the watch daemon).
any_watch_target() {
    targets_load
    _aw_i=0
    while [ "$_aw_i" -lt "$TG_COUNT" ]; do
        resolve_opts "$(tg_opts "$_aw_i")" || :
        if [ "$t_watch" = "on" ] || { [ "$t_remote_poll" -gt 0 ] && [ "$t_mode" != "push" ]; }; then
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

    _is_watch=0
    if any_watch_target; then
        _is_watch=1
        cat >"$_is_dir/syncto-watch.service" <<EOF || die 1 "cannot write $_is_dir/syncto-watch.service"
[Unit]
Description=syncto filesystem watch daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(sched_exec) watch
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
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
        printf 'Removed systemd user watch daemon (no target has watch=on or remote_poll)\n'
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

cmd_start() {
    case "$(uname -s)" in
        Darwin) install_launchd ;;
        Linux) install_systemd ;;
        *) die 1 "no scheduler support for $(uname -s); run 'syncto run' from cron" ;;
    esac
}

cmd_stop() {
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
syncto $SYNCTO_VERSION: keeps git repos in sync by itself (commit, pull, push)

USAGE
  syncto [-v] [COMMAND]

COMMANDS
  status                    how every sync is doing (also: plain 'syncto')
  add NAME PATH [K=V ...]   start syncing a repo
  edit NAME K=V ...         change a sync's options; K= resets one to its default
  edit                      open the targets file in \$EDITOR
  remove NAME               stop syncing a repo; its files stay
  sync [NAME]               sync now: every repo, or just NAME
  log                       recent activity
  start                     sync in the background (launchd or systemd)
  stop                      stop syncing in the background
  run                       one scheduled pass; what 'start' schedules
  watch [NAME]              the watch loop; what 'start' runs when a repo has watch=on
  help, version

  -v, --verbose             also print log lines (works with any command)

TARGET OPTIONS   comma separated key=value; write \\, for a literal comma
  interval=SECONDS      minimum seconds between scheduled syncs   [$G_INTERVAL]
  watch=on|off          sync within seconds of a file changing    [$G_WATCH]
  paused=on|off         skip in background syncing and plain 'sync' [$G_PAUSED]
  mode=sync|push|pull   commit+pull+push / commit+push / pull only [$G_MODE]
  branch=NAME           branch to pull and push                   [$G_BRANCH]
  remote=NAME           remote to pull and push                   [$G_REMOTE]
  prefix=TEXT           commit message prefix, "<prefix>: 3 files" [$G_PREFIX]
  guard=CMD             run first; non-zero exit skips this pass
  stale=SECS|off        alert when no sync succeeded for this long [$G_STALE]
  notify=CMD            run on a conflict, or when a target goes stale
  peer=CMD              run after a push that carried a new commit
  remote_poll=SECS|off  watch daemon syncs when the remote head moves [$G_REMOTE_POLL]

  Hooks run with the target as the working directory and with SYNCTO_NAME,
  SYNCTO_PATH, SYNCTO_BRANCH, SYNCTO_REMOTE and SYNCTO_MESSAGE in the
  environment. guard and notify decide the run; peer is always best effort.

FILES
  $(path_encode "$TARGETS_FILE")
      one target per line: NAME<TAB>PATH<TAB>OPTIONS  (\$HOME is stored as ~)
  $(path_encode "$CONFIG_FILE")
      global defaults, one key=value per line: any target option, plus
      log=PATH             where to write the log
      key=PATH             ssh key for git: launchd and systemd have no
                           ssh-agent, so name the key instead of relying on one
      GIT_SSH_COMMAND=CMD  a full ssh command; wins over key= (alias: ssh=)

  key=, GIT_SSH_COMMAND= and ssh= also work as per-target options.
  $(path_encode "$LOG_FILE")
      the log

EXIT CODES
  0  ok
  1  error
  2  conflict: a human has to look at it
  3  configuration error
  4  another run holds the lock

EXAMPLES
  syncto add notes ~/notes watch=on,prefix=notes
  syncto add site ~/site mode=pull,branch=trunk
  syncto start
  syncto sync notes
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
        ""|status) cmd_status ;;
        add) cmd_add "$@" ;;
        edit) cmd_edit "$@" ;;
        remove) cmd_remove "${1:-}" ;;
        sync) cmd_sync "${1:-}" ;;
        log) cmd_log ;;
        start) cmd_start ;;
        stop) cmd_stop ;;
        watch)
            DAEMON=1
            cmd_watch "${1:-}"
            ;;
        run)
            DAEMON=1
            cmd_run
            ;;
        help|-h|--help) usage ;;
        version|-V|--version) printf 'syncto %s\n' "$SYNCTO_VERSION" ;;
        -s|--sync|-a|--add|-r|--remove|-e|--edit|-w|--watch|-d|--daemon|\
        -i|--install-service|-u|--uninstall-service|-L|--log)
            die 1 "'$action' was replaced by commands (see 'syncto help'); if launchd or systemd runs this, update it with 'syncto start'"
            ;;
        -*)
            warn "unknown option: $action"
            printf "Try 'syncto help'.\n" >&2
            return 1
            ;;
        *)
            warn "unknown command: $action"
            printf "Try 'syncto help'.\n" >&2
            return 1
            ;;
    esac
}

rc=0
main "$@" || rc=$?
exit "$rc"
