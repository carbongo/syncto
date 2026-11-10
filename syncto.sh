#!/usr/bin/env bash
# syncto: unattended git auto-sync. MIT licence.
# Must run on bash 3.2 (macOS stock) and bash 5, BSD and GNU userland.

set -eu

SYNCTO_VERSION="1.0.1"
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
# 1 under run and watch: the units already send stderr to LOG_FILE.
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
    if [ -n "${EPOCHSECONDS:-}" ]; then
        printf '%s' "$EPOCHSECONDS"
    else
        date '+%s'
    fi
}

# Strip newlines so a log record always stays on one line.
# Strip newlines so a log record always stays on one line, and every other
# control character so git or remote output cannot drive the terminal.
oneline() {
    printf '%s' "$1" | LC_ALL=C tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' |
        LC_ALL=C sed "s/$C1_RE//g; s/  */ /g; s/^ //; s/ \$//"
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
            # shellcheck disable=SC2174 # only the last folder needs to be private
            mkdir -p -m 700 "$_lg_dir" 2>/dev/null || :
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
    # Copy, then truncate: a daemon's stderr stays open on this same file.
    cp -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || return 0
    : >"$LOG_FILE"
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
    path_enc_r "$1"
    printf '%s' "$REPLY"
}

# path_enc_r PATH: REPLY is PATH with $HOME written as ~.
path_enc_r() {
    case "$1" in
        "$HOME") REPLY='~' ;;
        "$HOME"/*) REPLY="~${1#"$HOME"}" ;;
        *) REPLY=$1 ;;
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
    split_opts_a "$1"
    [ "${#SO[@]}" -eq 0 ] || printf '%s\n' "${SO[@]}"
    return 0
}

# split_opts_a OPTS: array SO holds the options, with "\," kept as a comma.
split_opts_a() {
    SO=()
    _so_s=${1//\\,/$SO_SEP}
    while [ -n "$_so_s" ]; do
        _so_i=${_so_s%%,*}
        case "$_so_s" in
            *,*) _so_s=${_so_s#*,} ;;
            *) _so_s="" ;;
        esac
        [ -n "$_so_i" ] && SO[${#SO[@]}]=${_so_i//$SO_SEP/,}
    done
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
    trim_r "$1"
    printf '%s' "$REPLY"
}

# trim_r TEXT: REPLY is TEXT without surrounding whitespace, without a subshell.
trim_r() {
    REPLY=${1#"${1%%[![:space:]]*}"}
    REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
}

validate_value() {
    # validate_value KEY VALUE -> 0 ok, 1 bad (message on stderr)
    case "$1" in
        branch|remote)
            # Passed to git as arguments: no option lookalikes, separators or controls.
            case "$2" in
                ''|-*|*[[:space:],]*|*[[:cntrl:]]*)
                    warn "$1 must be a plain name (no leading '-', spaces, commas or control characters), got '$2'"
                    return 1
                    ;;
            esac
            ;;
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
        trim_r "${_lc_line%%=*}"
        _lc_k=$REPLY
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
        # git runs this through sh: single-quote the path so nothing in it expands.
        _ak_q="'\\''"
        _ak_key=${2//\'/$_ak_q}
        GIT_SSH_COMMAND="ssh -i '$_ak_key' -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10"
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
# C1 control characters (UTF-8 U+0080..U+009F), such as the 8-bit CSI.
C1_RE=$'\302'"["$'\200'"-"$'\237'"]"
SO_SEP=$'\001'

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
        _tl_name=${_tl_line%%"$TAB"*}
        _tl_rest=${_tl_line#*"$TAB"}
        _tl_path=${_tl_rest%%"$TAB"*}
        case "$_tl_rest" in
            *"$TAB"*) _tl_opts=${_tl_rest#*"$TAB"} ;;
            *) _tl_opts="" ;;
        esac
        if [ "$_tl_name" = "$_tl_line" ] || [ -z "$_tl_name" ] || [ -z "$_tl_path" ]; then
            warn "$TARGETS_FILE:$_tl_n: expected NAME<TAB>PATH[<TAB>OPTIONS], ignored"
            TG_MALFORMED=1
            continue
        fi
        case "$_tl_path" in
            \~) _tl_path=$HOME ;;
            \~/*) _tl_path="$HOME${_tl_path#\~}" ;;
        esac
        eval "TG_NAME_$TG_COUNT=\$_tl_name TG_PATH_$TG_COUNT=\$_tl_path TG_OPTS_$TG_COUNT=\$_tl_opts"
        TG_COUNT=$((TG_COUNT + 1))
    done <"$TARGETS_FILE"
    return 0
}

# tg_get INDEX: TGN, TGP and TGO are that target's name, path and options.
tg_get() {
    eval "TGN=\$TG_NAME_$1 TGP=\$TG_PATH_$1 TGO=\$TG_OPTS_$1"
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
    [ -n "$1" ] || return 0
    split_opts_a "$1"
    for _ro_kv in ${SO[@]+"${SO[@]}"}; do
        trim_r "$_ro_kv"
        _ro_kv=$REPLY
        [ -n "$_ro_kv" ] || continue
        case "$_ro_kv" in
            *=*) : ;;
            *)
                warn "option '$_ro_kv' is not key=value, ignored"
                t_rc=3
                continue
                ;;
        esac
        trim_r "${_ro_kv%%=*}"
        _ro_k=$REPLY
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
    done
    [ "$t_remote_poll" = "off" ] && t_remote_poll=0
    return 0
}

# ---------------------------------------------------------------------------
# locking (mkdir is the only portable atomic create)
# ---------------------------------------------------------------------------

safe_name() {
    printf '%s' "${1//[!A-Za-z0-9._-]/_}"
}

lock_acquire() {
    # lock_acquire NAME STALE_AFTER_SECONDS -> 0 acquired, 1 held by another run
    _la_dir="$LOCK_DIR/${1//[!A-Za-z0-9._-]/_}.lock"
    _la_stale=$2
    [ "$_la_stale" -lt 3600 ] && _la_stale=3600
    mkdir -p "$LOCK_DIR" 2>/dev/null || :
    lock_take "$_la_dir" && return 0
    _la_owner=""
    { read -r _la_owner || :; } <"$_la_dir/owner" 2>/dev/null
    _la_pid=${_la_owner%% *}
    _la_started=${_la_owner#* }
    case "$_la_pid" in ''|*[!0-9]*) _la_pid="" ;; esac
    case "$_la_started" in ''|*[!0-9]*) _la_started=0 ;; esac
    if [ -z "$_la_pid" ]; then
        # No owner yet: another run is between mkdir and writing it. Only a
        # lock left like that for over a minute is abandoned.
        [ -n "$(find "$_la_dir" -prune -mmin +1 2>/dev/null)" ] || return 1
        _la_why="it had no owner"
    elif kill -0 "$_la_pid" 2>/dev/null; then
        # A live owner keeps it, unless it has held it far too long (a hung
        # git, or a PID the system has since reused).
        [ $(( $(epoch) - _la_started )) -gt "$_la_stale" ] || return 1
        _la_why="run $_la_pid held it over ${_la_stale}s"
    else
        _la_why="run $_la_pid is gone"
    fi
    # Take it over by renaming: of several racing runs only one can.
    _la_now=""
    { read -r _la_now || :; } <"$_la_dir/owner" 2>/dev/null
    [ "$_la_now" = "$_la_owner" ] || return 1
    mv "$_la_dir" "$_la_dir.stale.$$" 2>/dev/null || return 1
    rm -rf "$_la_dir.stale.$$" 2>/dev/null || :
    log warn "$1" "took over a stale lock: $_la_why"
    lock_take "$_la_dir"
}

# lock_take DIR -> 0 if this run created DIR; its owner file appears atomically.
lock_take() {
    mkdir "$1" 2>/dev/null || return 1
    printf '%s %s\n' "$$" "$(epoch)" >"$1/.owner.$$" 2>/dev/null &&
        mv "$1/.owner.$$" "$1/owner" 2>/dev/null
    HELD_LOCK=$1
    return 0
}

# lock_release: removes the lock only while this run still owns it.
lock_release() {
    if [ -n "$HELD_LOCK" ]; then
        _lr_owner=""
        { read -r _lr_owner || :; } <"$HELD_LOCK/owner" 2>/dev/null
        if [ "${_lr_owner%% *}" = "$$" ]; then
            rm -rf "$HELD_LOCK" 2>/dev/null || :
        fi
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

# repo_root_ok PATH -> 0 if PATH is the top folder of its git work tree; sets _rr_top
repo_root_ok() {
    _rr_top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
    _rr_here=$(cd "$1" 2>/dev/null && pwd -P) || return 1
    [ "$_rr_top" = "$_rr_here" ]
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
    # git add -A stages the whole work tree, so a subfolder would sync its parent repo.
    if [ ! -e "$path/.git" ] && ! repo_root_ok "$path"; then
        outcome "$name" error "not the top folder of its git repo: $path"
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
    _lo_f="$OK_DIR/${1//[!A-Za-z0-9._-]/_}"
    REPLY=0
    if [ -f "$_lo_f" ]; then
        { read -r REPLY || :; } <"$_lo_f" 2>/dev/null
    fi
    case "$REPLY" in
        ''|*[!0-9]*) REPLY=0 ;;
    esac
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
    stale_limit_r
    printf '%s' "$REPLY"
}

# stale_limit_r: REPLY is stale_limit's answer, without a subshell.
stale_limit_r() {
    if [ "$t_stale" = "off" ]; then
        REPLY=off
        return 0
    fi
    REPLY=$t_stale
    [ "$REPLY" -eq 0 ] && REPLY=$((t_interval * 12))
    [ "$REPLY" -lt 600 ] && REPLY=600
    return 0
}

# stale_check NAME: alert when a target has not synced for too long,
# whatever the cause. Uses the caller's t_*.
stale_check() {
    _sc_name=$1
    _sc_limit=$(stale_limit)
    [ "$_sc_limit" = "off" ] && return 0
    last_ok "$_sc_name"
    _sc_last=$REPLY
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
    _lr_f="$LAST_DIR/${1//[!A-Za-z0-9._-]/_}"
    REPLY=0
    if [ -f "$_lr_f" ]; then
        { read -r REPLY || :; } <"$_lr_f" 2>/dev/null
    fi
    case "$REPLY" in
        ''|*[!0-9]*) REPLY=0 ;;
    esac
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
        last_run "$_cd_name"
        _cd_last=$REPLY
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
    human_ago_r "$1"
    printf '%s' "$REPLY"
}

# human_ago_r SECONDS: REPLY is human_ago's answer, without a subshell.
human_ago_r() {
    if [ "$1" -lt 60 ]; then
        REPLY="just now"
    elif [ "$1" -lt 3600 ]; then
        REPLY="$(($1 / 60)) min ago"
    elif [ "$1" -lt 172800 ]; then
        REPLY="$(($1 / 3600)) h ago"
    else
        REPLY="$(($1 / 86400)) days ago"
    fi
}

# human_every SECONDS -> "every 10 min", "every 1 h", "every 90 s"
human_every() {
    human_every_r "$1"
    printf '%s' "$REPLY"
}

# human_every_r SECONDS: REPLY is human_every's answer, without a subshell.
human_every_r() {
    if [ $(($1 % 3600)) -eq 0 ]; then
        REPLY="every $(($1 / 3600)) h"
    elif [ $(($1 % 60)) -eq 0 ]; then
        REPLY="every $(($1 / 60)) min"
    else
        REPLY="every $1 s"
    fi
}

# cd_hint PATH -> a cd command a user can paste
cd_hint() {
    case "$1" in
        *" "*) printf 'cd "%s"' "$1" ;;
        *) path_enc_r "$1"; printf 'cd %s' "$REPLY" ;;
    esac
}

# target_health INDEX: sets H_LEVEL (ok, wait, warn, bad), H_TEXT, H_DETAIL,
# H_FIX and H_HOW for that target, in words a person can act on.
target_health() {
    tg_get "$1"
    _th_name=$TGN
    _th_path=$TGP
    resolve_opts "$TGO" || :
    H_DETAIL=""
    H_FIX=""
    if [ "$t_watch" = "on" ]; then
        H_HOW="on save"
    else
        human_every_r "$t_interval"
        H_HOW=$REPLY
    fi
    case "$t_mode" in
        push) H_HOW="$H_HOW, push only" ;;
        pull) H_HOW="$H_HOW, pull only" ;;
    esac

    if [ ! -d "$_th_path" ]; then
        H_LEVEL=bad H_TEXT="folder is missing" H_FIX="restore it, or: syncto remove $_th_name"
        return 0
    fi
    if [ ! -e "$_th_path/.git" ]; then
        if ! git_in "$_th_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            H_LEVEL=bad H_TEXT="not a git repo" H_FIX="git init it, or: syncto remove $_th_name"
            return 0
        fi
        if ! repo_root_ok "$_th_path"; then
            path_enc_r "$_rr_top"
            H_LEVEL=bad H_TEXT="inside another repo"
            H_DETAIL="syncto syncs whole repos, and this folder is part of $REPLY"
            H_FIX="sync $REPLY instead, or: syncto remove $_th_name"
            return 0
        fi
    fi

    _th_now=${NOW:-}
    [ -n "$_th_now" ] || _th_now=$(epoch)
    last_ok "$_th_name"
    _th_ok=$REPLY
    _th_kind=""
    _th_msg=""
    _th_f="$OUTCOME_DIR/${_th_name//[!A-Za-z0-9._-]/_}"
    if [ -f "$_th_f" ]; then
        IFS="$TAB" read -r _th_kind _th_since _th_msg <"$_th_f" || :
        _th_msg=${_th_msg//[[:cntrl:]]/}
    fi
    case "$_th_path" in
        *" "*) _th_cd="cd \"$_th_path\"" ;;
        *) path_enc_r "$_th_path"; _th_cd="cd $REPLY" ;;
    esac
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
                human_ago_r $((_th_now - _th_ok))
                H_DETAIL="last synced $REPLY. $_th_msg"
            else
                H_DETAIL=$_th_msg
            fi
            return 0
            ;;
    esac

    last_run "$_th_name"
    if [ "$REPLY" -eq 0 ]; then
        H_LEVEL=wait H_TEXT="not synced yet"
        return 0
    fi
    stale_limit_r
    _th_limit=$REPLY
    human_ago_r $((_th_now - _th_ok))
    if [ "$_th_limit" != "off" ] && [ $((_th_now - _th_ok)) -ge "$_th_limit" ]; then
        H_LEVEL=warn H_TEXT="no sync for ${REPLY% ago}"
        H_DETAIL="passes keep being skipped (guard, or edits in progress)"
        H_FIX="syncto log"
        return 0
    fi
    H_LEVEL=ok H_TEXT="synced $REPLY"
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

    colors_init
    NOW=$(epoch)
    _st_cols=${COLUMNS:-}
    if [ -z "$_st_cols" ] && [ -t 1 ]; then
        _st_cols=$(stty size 2>/dev/null || printf '0 100')
        _st_cols=${_st_cols#* }
    fi
    case "$_st_cols" in ''|*[!0-9]*) _st_cols=100 ;; esac

    _st_w=4
    _st_i=0
    while [ "$_st_i" -lt "$TG_COUNT" ]; do
        tg_get "$_st_i"
        [ "${#TGN}" -gt "$_st_w" ] && _st_w=${#TGN}
        _st_i=$((_st_i + 1))
    done
    printf -v _st_pad "%$((_st_w + 4))s" ""
    _st_room=$((_st_cols - _st_w - 4))
    [ "$_st_room" -lt 20 ] && _st_room=20

    _st_i=0
    while [ "$_st_i" -lt "$TG_COUNT" ]; do
        target_health "$_st_i"
        level_style "$H_LEVEL"
        path_enc_r "$TGP"
        printf "%-${_st_w}s  %s%s %-20s%s  %-15s %s\n" "$TGN" \
            "$L_C" "$L_SYM" "$H_TEXT" "$C_OFF" "$H_HOW" "$REPLY"
        _st_line=$H_DETAIL
        # Long git output is cut to the terminal width; the fix line never is.
        if [ -t 1 ]; then
            fit_r "$_st_line" "$_st_room"
            _st_line=$REPLY
        fi
        [ -n "$_st_line" ] && printf '%s%s%s%s\n' "$_st_pad" "$C_DIM" "$_st_line" "$C_OFF"
        [ -n "$H_FIX" ] && printf '%sfix: %s\n' "$_st_pad" "$H_FIX"
        _st_i=$((_st_i + 1))
    done

    printf '\n%s\n' "$(background_words "$(background_state)")"
    if [ "$TG_MALFORMED" -eq 1 ]; then
        return 3
    fi
    return 0
}

# secure_dirs: config and state hold hook commands and git output, so only the
# owner may read them. Run by start; new installs create them private anyway.
secure_dirs() {
    for _sd in "$CONFIG_DIR" "$STATE_DIR"; do
        [ -d "$_sd" ] && chmod 700 "$_sd" 2>/dev/null
    done
    for _sd in "$TARGETS_FILE" "$CONFIG_FILE"; do
        [ -f "$_sd" ] && chmod 600 "$_sd" 2>/dev/null
    done
    return 0
}

ensure_targets_file() {
    if [ ! -f "$TARGETS_FILE" ]; then
        # shellcheck disable=SC2174 # only the last folder needs to be private
        [ -d "$CONFIG_DIR" ] || mkdir -p -m 700 "$CONFIG_DIR" || die 3 "cannot create $CONFIG_DIR"
        {
            printf '# syncto targets\n'
            printf '# NAME<TAB>PATH<TAB>OPTIONS   ($HOME is written as ~ so this file travels)\n'
            printf '# OPTIONS: comma separated key=value, see: syncto help\n'
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
    # A temp file next to the targets file, renamed over it, so a reader never
    # sees it half written. A symlinked targets file is rewritten in place.
    if [ -L "$TARGETS_FILE" ]; then
        _tr_tmp=$(mktemp "${TMPDIR:-/tmp}/syncto.XXXXXX") || die 1 "cannot create a temp file"
    else
        _tr_tmp=$(mktemp "$TARGETS_FILE.XXXXXX") || die 1 "cannot create a temp file"
    fi
    while IFS= read -r _tr_line || [ -n "$_tr_line" ]; do
        _tr_first=${_tr_line%%"$TAB"*}
        if [ "$_tr_first" = "$1" ] && [ "$_tr_first" != "$_tr_line" ]; then
            [ -n "$2" ] && printf '%s\n' "$2" >>"$_tr_tmp"
            continue
        fi
        printf '%s\n' "$_tr_line" >>"$_tr_tmp"
    done <"$TARGETS_FILE"
    if [ -L "$TARGETS_FILE" ]; then
        cat "$_tr_tmp" >"$TARGETS_FILE" || { rm -f "$_tr_tmp"; die 1 "cannot rewrite $TARGETS_FILE"; }
        rm -f "$_tr_tmp"
    else
        chmod 600 "$_tr_tmp" 2>/dev/null || :
        mv -f "$_tr_tmp" "$TARGETS_FILE" || { rm -f "$_tr_tmp"; die 1 "cannot rewrite $TARGETS_FILE"; }
    fi
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
    elif ! repo_root_ok "$_ca_abs"; then
        die 3 "$(path_encode "$_ca_abs") is inside the git repo $(path_encode "$_rr_top"); syncto syncs whole repos, so add that folder instead"
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
    tail -n 100 "$LOG_FILE" | LC_ALL=C tr -d '\000-\010\013-\037\177' | LC_ALL=C sed "s/$C1_RE//g"
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

# macOS privacy grants (Full Disk Access) attach to the program launchd starts.
# Granting them to /bin/bash would hand them to every LaunchAgent, so syncto
# builds this launcher once: it stays the started process and runs bash as its
# child, so a grant can go to it alone.
LAUNCHER="$HOME/.local/share/syncto/launcher"

launcher_source() {
    cat <<'EOF'
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

static pid_t child;

static void pass_on(int sig) {
    if (child > 0) kill(child, sig);
}

int main(int argc, char **argv) {
    int status;
    (void)argc;
    signal(SIGTERM, pass_on);
    signal(SIGINT, pass_on);
    signal(SIGHUP, pass_on);
    child = fork();
    if (child < 0) return 1;
    if (child == 0) {
        argv[0] = "/bin/bash";
        execv("/bin/bash", argv);
        _exit(127);
    }
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return 1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
EOF
}

# launcher_build -> 0 if the launcher exists or was built. Needs the developer
# tools already installed; never triggers Apple's install dialog.
launcher_build() {
    [ -x "$LAUNCHER" ] && return 0
    xcode-select -p >/dev/null 2>&1 || return 1
    command -v cc >/dev/null 2>&1 || return 1
    mkdir -p "${LAUNCHER%/*}" || return 1
    _lb_src=$(mktemp "${TMPDIR:-/tmp}/syncto-launcher.XXXXXX") || return 1
    launcher_source >"$_lb_src"
    if cc -x c -O2 -o "$LAUNCHER.tmp" "$_lb_src" >/dev/null 2>&1; then
        codesign -s - -f -i local.syncto.launcher "$LAUNCHER.tmp" >/dev/null 2>&1 || :
        mv -f "$LAUNCHER.tmp" "$LAUNCHER"
    fi
    rm -f "$_lb_src" "$LAUNCHER.tmp"
    [ -x "$LAUNCHER" ]
}

# sched_runner -> what launchd or systemd starts in front of the script: the
# launcher (macOS), /bin/bash (macOS without developer tools, or a script that
# is not executable), or nothing.
sched_runner() {
    if [ "$(uname -s)" = "Darwin" ]; then
        if launcher_build; then
            printf '%s' "$LAUNCHER"
        else
            printf '%s' "$SHELL_BIN"
        fi
    else
        # systemd refuses special characters in the program path; as an argument
        # the escaped path is fine.
        _sr_exec=$(sched_exec)
        case "$_sr_exec" in
            *[!A-Za-z0-9/._+-]*) printf '%s' "$SHELL_BIN" ;;
            *) [ -x "$_sr_exec" ] || printf '%s' "$SHELL_BIN" ;;
        esac
    fi
}

# Print the ProgramArguments / ExecStart words, one per line.
sched_argv() {
    _sa_runner=$(sched_runner)
    [ -n "$_sa_runner" ] && printf '%s\n' "$_sa_runner"
    printf '%s\nrun\n' "$(sched_exec)"
}

# sd_words: lines on stdin -> one ExecStart value, each word quoted for systemd
# (backslash, quote, % specifiers and $ variables escaped).
sd_words() {
    _sw_q='"'
    _sw_out=""
    while IFS= read -r _sw; do
        [ -n "$_sw" ] || continue
        _sw=${_sw//\\/\\\\}
        _sw=${_sw//$_sw_q/\\$_sw_q}
        _sw=${_sw//%/%%}
        _sw=${_sw//\$/\$\$}
        _sw_out="$_sw_out $_sw_q$_sw$_sw_q"
    done
    printf '%s' "${_sw_out# }"
}

# sched_runner_line: sched_runner on a line of its own, or nothing
sched_runner_line() {
    _srl=$(sched_runner)
    [ -n "$_srl" ] && printf '%s\n' "$_srl"
    return 0
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
            printf '        <string>%s</string>\n' "$(xml_escape "$(sched_runner)")"
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

    _is_argv=$(sched_argv | sd_words)
    cat >"$_is_dir/syncto.service" <<EOF || die 1 "cannot write $_is_dir/syncto.service"
[Unit]
Description=syncto scheduled sync pass
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$_is_argv
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
ExecStart=$( { sched_runner_line; sched_exec; printf "\nwatch\n"; } | sd_words)
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
    fi

    systemctl --user daemon-reload >/dev/null 2>&1 || :
    # restart, not just enable --now: a running unit must pick up new code and options.
    { systemctl --user enable syncto.timer && systemctl --user restart syncto.timer; } >/dev/null 2>&1 ||
        die 1 "wrote the units but could not enable and restart syncto.timer"
    printf 'Installed systemd user timer syncto.timer (every %ss)\n' "$G_INTERVAL"
    printf '  units: %s/syncto.{service,timer}\n' "$(path_encode "$_is_dir")"
    log info "" "installed systemd user timer interval=$G_INTERVAL"

    if [ "$_is_watch" -eq 1 ]; then
        { systemctl --user enable syncto-watch.service && systemctl --user restart syncto-watch.service; } \
            >/dev/null 2>&1 || die 1 "wrote the units but could not enable and restart syncto-watch.service"
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
    secure_dirs
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
# dashboard
# ---------------------------------------------------------------------------

# The logo: a sync loop and the name. Kept in parts, so it is never cut mid-character.
LOGO_A1='╭──▶╮' LOGO_B1='┌─┐┬ ┬┌┐┌┌─┐┌┬┐┌─┐'
LOGO_A2='│ ● │' LOGO_B2='└─┐└┬┘││││   │ │ │'
LOGO_A3='╰◀──╯' LOGO_B3='└─┘ ┴ ┘└┘└─┘ ┴ └─┘'

# logo_r [TEXT2 [TEXT3]]: REPLY is the three logo lines, TEXT2 and TEXT3 beside
# its second and third line. Uses the C_* colours set by colors_init.
logo_r() {
    REPLY="${C_OK}${LOGO_A1}${C_OFF}  ${C_BOLD}${LOGO_B1}${C_OFF}
${C_OK}${LOGO_A2}${C_OFF}  ${C_BOLD}${LOGO_B2}${C_OFF}${1:+   $1}
${C_OK}${LOGO_A3}${C_OFF}  ${C_BOLD}${LOGO_B3}${C_OFF}${2:+   $2}"
}

# colors_init: C_* escapes when stdout is a colour terminal, else empty.
colors_init() {
    C_OK="" C_WAIT="" C_WARN="" C_BAD="" C_DIM="" C_OFF="" C_BOLD="" C_REV=""
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
        C_OK=$(printf '\033[32m') C_WAIT=$(printf '\033[2m') C_WARN=$(printf '\033[33m')
        C_BAD=$(printf '\033[31m') C_DIM=$(printf '\033[2m') C_OFF=$(printf '\033[0m')
        C_BOLD=$(printf '\033[1m') C_REV=$(printf '\033[7m')
    fi
}

# level_style LEVEL: sets L_SYM and L_C for a health level.
level_style() {
    case "$1" in
        ok) L_SYM="✓" L_C=$C_OK ;;
        wait) L_SYM="·" L_C=$C_WAIT ;;
        warn) L_SYM="!" L_C=$C_WARN ;;
        *) L_SYM="✗" L_C=$C_BAD ;;
    esac
}

# background_words STATE -> the sentence status and the dashboard show
background_words() {
    case "$1" in
        on+watch) printf 'Background: on, %s, and on every save.' "$(human_every "$G_INTERVAL")" ;;
        on) printf 'Background: on, %s.' "$(human_every "$G_INTERVAL")" ;;
        stopped) printf 'Background: installed but not running. Restart it with: syncto start' ;;
        *) printf 'Background: off. Turn it on with: syncto start' ;;
    esac
}

# fit TEXT WIDTH -> TEXT cut to WIDTH characters, ending in … when cut
fit() {
    fit_r "$1" "$2"
    printf '%s' "$REPLY"
}

# fit_r TEXT WIDTH: REPLY is fit's answer, without a subshell.
fit_r() {
    if [ "$2" -lt 1 ]; then
        REPLY=""
    elif [ "${#1}" -le "$2" ]; then
        REPLY=$1
    elif [ "$2" -lt 2 ]; then
        REPLY=${1:0:$2}
    else
        REPLY="${1:0:$(($2 - 1))}…"
    fi
}

# parse_duration TEXT -> seconds from "90", "90s", "10m", "10 min", "2h"; 1 if not one
parse_duration() {
    _pd=$(printf '%s' "$1" | tr -d ' ' | tr 'A-Z' 'a-z')
    case "$_pd" in
        ''|*[!0-9smhin]*) return 1 ;;
    esac
    _pd_n=${_pd%%[!0-9]*}
    [ -n "$_pd_n" ] || return 1
    case "${_pd#"$_pd_n"}" in
        ''|s) printf '%s' "$_pd_n" ;;
        m|min) printf '%s' $((_pd_n * 60)) ;;
        h) printf '%s' $((_pd_n * 3600)) ;;
        *) return 1 ;;
    esac
}

# opt_is_set OPTS KEY -> 0 if KEY is given explicitly in a target's options
opt_is_set() {
    split_opts "$1" | grep -q "^$2="
}

# url_safe_r URL: REPLY is URL without user:password@, safe to show on screen.
url_safe_r() {
    REPLY=$1
    case "$1" in
        *://*@*)
            _us_rest=${1#*://}
            _us_auth=${_us_rest%%@*}
            case "$_us_auth" in
                */*) : ;;
                *) REPLY="${1%%://*}://${_us_rest#*@}" ;;
            esac
            ;;
    esac
}

dash_can_run() {
    [ -t 0 ] && [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]
}

dash_enter() {
    D_STTY=$(stty -g 2>/dev/null || printf '')
    stty -echo -icanon 2>/dev/null || :
    printf '\033[?1049h\033[?25l'
    trap 'dash_leave; exit 130' INT TERM
    trap 'dash_leave' EXIT
    # A resize interrupts the key wait, and every frame re-reads the size.
    trap 'D_RESIZED=1' WINCH
}

dash_leave() {
    trap - EXIT INT TERM WINCH
    printf '\033[?25h\033[?1049l'
    if [ -n "${D_STTY:-}" ]; then
        stty "$D_STTY" 2>/dev/null || :
    fi
}

dash_size() {
    [ "${D_RESIZED:-1}" -eq 1 ] || return 0
    D_RESIZED=0
    # stty reads the terminal on stdin; tput inside $(...) can miss it.
    _ds_size=$(stty size 2>/dev/null || printf '24 80')
    D_LINES=${_ds_size% *}
    D_COLS=${_ds_size#* }
    case "$D_COLS" in ''|*[!0-9]*) D_COLS=80 ;; esac
    case "$D_LINES" in ''|*[!0-9]*) D_LINES=24 ;; esac
    # A pty created without a size reports 0 0.
    [ "$D_COLS" -lt 20 ] && D_COLS=80
    [ "$D_LINES" -lt 8 ] && D_LINES=24
    printf -v D_SEP '%*s' "$D_COLS" ""
    D_SEP=${D_SEP// /─}
}

# dash_key: waits up to D_TICK seconds and sets D_KEY to up, down, left, right,
# enter, esc, tick (nothing pressed) or the character typed.
dash_key() {
    D_KEY=tick
    _dk=""
    IFS= read -rsn1 -t "$D_TICK" _dk || return 0
    case "$_dk" in
        "") D_KEY=enter ;;
        $'\033')
            _dk2=""
            IFS= read -rsn2 -t 1 _dk2 || :
            case "$_dk2" in
                "[A"|OA) D_KEY=up ;;
                "[B"|OB) D_KEY=down ;;
                "[C"|OC) D_KEY=right ;;
                "[D"|OD) D_KEY=left ;;
                *) D_KEY=esc ;;
            esac
            ;;
        $'\177'|$'\010') D_KEY=left ;;
        *) D_KEY=$_dk ;;
    esac
}

# dash_paint: draws D_FRAME (newline separated) over the screen without flicker
dash_paint() {
    _dp_out=$(printf '\033[H')
    _dp_n=0
    while IFS= read -r _dp_l; do
        _dp_n=$((_dp_n + 1))
        [ "$_dp_n" -gt "$D_LINES" ] && break
        if [ "$_dp_n" -lt "$D_LINES" ]; then
            _dp_out="$_dp_out$_dp_l"$'\033[K\n'
        else
            _dp_out="$_dp_out$_dp_l"$'\033[K'
        fi
    done <<EOF
$D_FRAME
EOF
    printf '%s\033[J' "$_dp_out"
}

dash_add_line() {
    D_FRAME="$D_FRAME$1"$'\n'
    D_FL=$((D_FL + 1))
}

# dash_finish FOOTER: pads the frame, adds the message and footer lines, paints.
dash_finish() {
    while [ "$D_FL" -lt $((D_LINES - 2)) ]; do
        dash_add_line ""
    done
    fit_r "$D_MSG" $((D_COLS - 2))
    dash_add_line " ${D_MSG:+$C_BOLD$REPLY$C_OFF}"
    fit_r "$1" $((D_COLS - 2))
    D_FRAME="$D_FRAME $C_DIM$REPLY$C_OFF"
    dash_paint
}

dash_header() {
    D_FRAME=""
    D_FL=0
    _dh_vis=$2
    for _dh_c in "$C_OK" "$C_WAIT" "$C_WARN" "$C_BAD" "$C_DIM" "$C_OFF" "$C_BOLD" "$C_REV"; do
        [ -n "$_dh_c" ] && _dh_vis=${_dh_vis//"$_dh_c"/}
    done
    _dh_room=$((D_COLS - ${#_dh_vis} - 3))
    [ "$_dh_room" -lt 1 ] && _dh_room=1
    fit_r "$1" "$_dh_room"
    printf -v _dh_left "%-${_dh_room}s" "$REPLY"
    dash_add_line " $C_BOLD$_dh_left$C_OFF $2"
    dash_add_line "$C_DIM$D_SEP$C_OFF"
}

# dash_refresh: health of every target into D_* variables
dash_refresh() {
    targets_load
    NOW=$(epoch)
    D_N=$TG_COUNT
    [ "$D_SEL" -ge "$D_N" ] && D_SEL=$((D_N - 1))
    [ "$D_SEL" -lt 0 ] && D_SEL=0
    _dr_i=0
    while [ "$_dr_i" -lt "$D_N" ]; do
        target_health "$_dr_i"
        eval "D_LV_$_dr_i=\$H_LEVEL D_TX_$_dr_i=\$H_TEXT D_DT_$_dr_i=\$H_DETAIL D_FX_$_dr_i=\$H_FIX D_HW_$_dr_i=\$H_HOW"
        _dr_i=$((_dr_i + 1))
    done
    # launchctl and systemctl are slow: ask at most every 30 s unless forced.
    if [ "${1:-}" = "all" ] || [ $((NOW - ${D_BG_AT:-0})) -ge 30 ]; then
        D_BG=$(background_state)
        D_BG_AT=$NOW
    fi
    NOW=""
}

# dash_rows INDEX -> screen lines target INDEX takes in the list
dash_rows() {
    dash_rows_r "$1"
    printf '%s' "$REPLY"
}

# dash_rows_r INDEX: REPLY is dash_rows' answer, without a subshell.
dash_rows_r() {
    eval "_dr_lv=\$D_LV_$1 _dr_dt=\$D_DT_$1 _dr_fx=\$D_FX_$1"
    REPLY=1
    # shellcheck disable=SC2154 # set by eval
    if [ "$_dr_lv" = "bad" ] || [ "$_dr_lv" = "warn" ]; then
        [ -n "$_dr_dt" ] && REPLY=$((REPLY + 1))
        [ -n "$_dr_fx" ] && REPLY=$((REPLY + 1))
    fi
    return 0
}

dash_draw_list() {
    dash_size
    if [ "$D_N" -eq 1 ]; then _dl_count="1 repo"; else _dl_count="$D_N repos"; fi
    dash_header "syncto" "$_dl_count"
    if [ "$D_N" -eq 0 ]; then
        dash_add_line ""
        logo_r "v$SYNCTO_VERSION" "keeps git repos in sync by themselves"
        while IFS= read -r _dl_l; do
            dash_add_line "   $_dl_l"
        done <<EOF
$REPLY
EOF
        dash_add_line ""
        dash_add_line "   No repos yet. Press a to add one, or ? to see how syncto works."
        dash_add_line ""
        dash_add_line "   $(background_words "$D_BG")"
        dash_finish "a add  b background  ? help  q quit"
        return 0
    fi

    _dl_w=4
    _dl_i=0
    while [ "$_dl_i" -lt "$D_N" ]; do
        tg_get "$_dl_i"
        [ "${#TGN}" -gt "$_dl_w" ] && _dl_w=${#TGN}
        _dl_i=$((_dl_i + 1))
    done
    printf -v _dl_pad "%$((_dl_w + 5))s" ""
    _dl_room=$((D_COLS - _dl_w - 6))

    # Scroll so the selected row is on screen.
    _dl_avail=$((D_LINES - 6))
    [ "$D_SEL" -lt "$D_TOP" ] && D_TOP=$D_SEL
    while :; do
        _dl_used=0
        _dl_i=$D_TOP
        while [ "$_dl_i" -le "$D_SEL" ]; do
            dash_rows_r "$_dl_i"
            _dl_used=$((_dl_used + REPLY))
            _dl_i=$((_dl_i + 1))
        done
        if [ "$_dl_used" -le "$_dl_avail" ] || [ "$D_TOP" -ge "$D_SEL" ]; then
            break
        fi
        D_TOP=$((D_TOP + 1))
    done

    _dl_rest=$((D_COLS - _dl_w - 44))
    [ "$_dl_rest" -lt 1 ] && _dl_rest=1
    _dl_i=$D_TOP
    while [ "$_dl_i" -lt "$D_N" ] && [ "$D_FL" -lt $((D_LINES - 4)) ]; do
        eval "_dl_lv=\$D_LV_$_dl_i _dl_tx=\$D_TX_$_dl_i _dl_dt=\$D_DT_$_dl_i _dl_fx=\$D_FX_$_dl_i _dl_hw=\$D_HW_$_dl_i"
        # shellcheck disable=SC2154 # set by eval
        level_style "$_dl_lv"
        tg_get "$_dl_i"
        printf -v _dl_name "%-${_dl_w}s" "$TGN"
        if [ "$_dl_i" -eq "$D_SEL" ]; then
            _dl_mark="▸" _dl_name="$C_REV$_dl_name$C_OFF"
        else
            _dl_mark=" "
        fi
        # shellcheck disable=SC2154 # set by eval
        printf -v _dl_cols '%-20s%s %-15s' "$_dl_tx" "$C_OFF" "$_dl_hw"
        path_enc_r "$TGP"
        fit_r "$REPLY" "$_dl_rest"
        dash_add_line " ${_dl_mark} $_dl_name  $L_C$L_SYM $_dl_cols $C_DIM$REPLY$C_OFF"
        if [ "$_dl_lv" = "bad" ] || [ "$_dl_lv" = "warn" ]; then
            if [ -n "$_dl_dt" ]; then
                fit_r "$_dl_dt" "$_dl_room"
                dash_add_line "$_dl_pad$C_DIM$REPLY$C_OFF"
            fi
            if [ -n "$_dl_fx" ]; then
                fit_r "$_dl_fx" $((_dl_room - 5))
                dash_add_line "${_dl_pad}fix: $REPLY"
            fi
        fi
        _dl_i=$((_dl_i + 1))
    done
    dash_add_line ""
    dash_add_line " $(background_words "$D_BG")"
    dash_finish "↑↓ move  ⏎ open  a add  e edit  s sync  p pause  b background  ? help  q quit"
}

# dash_prompt TEXT: reads a line with editing into D_IN; 1 when left empty
dash_prompt() {
    printf '\033[%s;1H\033[K\033[?25h' "$((D_LINES - 1))"
    [ -n "${D_STTY:-}" ] && stty "$D_STTY" 2>/dev/null
    D_IN=""
    IFS= read -r -e -p " $1" D_IN || D_IN=""
    stty -echo -icanon 2>/dev/null || :
    printf '\033[?25l'
    [ -n "$D_IN" ]
}

# dash_confirm TEXT DEFAULT(y|n) -> 0 for yes
dash_confirm() {
    if [ "$2" = "y" ]; then _dc_hint="[Y/n]"; else _dc_hint="[y/N]"; fi
    printf '\033[%s;1H\033[K %s%s %s%s ' "$((D_LINES - 1))" "$C_BOLD" "$1" "$_dc_hint" "$C_OFF"
    _dc=""
    IFS= read -rsn1 _dc || :
    case "$_dc" in
        y|Y) return 0 ;;
        n|N) return 1 ;;
        "") [ "$2" = "y" ] ;;
        *) return 1 ;;
    esac
}

# dash_do MESSAGE CMD...: runs a syncto action in a subshell so its errors
# cannot end the dashboard; sets D_MSG to MESSAGE or to the first error line.
dash_do() {
    D_BG_AT=0
    _dd_msg=$1
    shift
    _dd_out=$( ("$@") 2>&1 ) && _dd_rc=0 || _dd_rc=$?
    if [ "$_dd_rc" -eq 0 ]; then
        D_MSG=$_dd_msg
    else
        D_MSG=$(printf '%s\n' "$_dd_out" | grep -v '^$' | head -n 1 | sed 's/^syncto: //')
        [ -n "$D_MSG" ] || D_MSG="That did not work (exit $_dd_rc). See: syncto log"
    fi
    return "$_dd_rc"
}

# dash_apply_background: offers to reinstall the units after a watch change
dash_apply_background() {
    case "$D_BG" in
        on|on+watch|stopped)
            if dash_confirm "Apply this to background syncing now?" y; then
                dash_do "Background syncing updated." cmd_start || :
            fi
            ;;
    esac
}

# dash_sync INDEX: sync now, then say how it went in the repo's own health words
dash_sync() {
    _ds_name=$(tg_name "$1")
    D_MSG="Syncing ${_ds_name}…"
    dash_draw_list
    dash_do "" cmd_sync "$_ds_name" || :
    dash_refresh
    eval "_ds_lv=\$D_LV_$1 _ds_tx=\$D_TX_$1"
    # shellcheck disable=SC2154 # set by eval
    if [ "$_ds_lv" = "ok" ]; then
        D_MSG="Synced $_ds_name."
    else
        D_MSG="$_ds_name: $_ds_tx"
    fi
}

dash_pause() {
    _dp_name=$(tg_name "$1")
    if tg_paused "$1"; then
        dash_do "Resumed $_dp_name." cmd_edit "$_dp_name" paused=off || :
    else
        dash_do "Paused $_dp_name. Press p again to resume." cmd_edit "$_dp_name" paused=on || :
    fi
    dash_refresh
}

dash_remove() {
    _dx_name=$(tg_name "$1")
    if dash_confirm "Stop syncing $_dx_name? Its files stay." n; then
        dash_do "Stopped syncing $_dx_name." cmd_remove "$_dx_name" || :
        dash_refresh
        return 0
    fi
    D_MSG=""
    return 1
}

dash_background() {
    case "$D_BG" in
        on|on+watch)
            if dash_confirm "Stop background syncing?" n; then
                dash_do "Background syncing is off." cmd_stop || :
            fi
            ;;
        *) dash_do "Background syncing is on." cmd_start || : ;;
    esac
    dash_refresh
}

dash_add() {
    dash_header "Add a repo" ""
    dash_add_line ""
    dash_add_line "   Pick a folder that is a git checkout with a remote. Tab completes paths."
    dash_add_line "   Leave an answer empty to cancel."
    D_MSG=""
    dash_finish ""
    dash_prompt "Folder: " || return 0
    _da_path=$(abs_path "$D_IN")
    if [ ! -d "$_da_path" ]; then
        D_MSG="No such folder: $(path_encode "$_da_path")"
        return 0
    fi
    if ! git -C "$_da_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        D_MSG="$(path_encode "$_da_path") is not a git repo: run git init and add a remote first."
        return 0
    fi
    _da_branch=$(git -C "$_da_path" symbolic-ref -q --short HEAD 2>/dev/null || printf '')
    _da_remote=$G_REMOTE
    if ! git -C "$_da_path" remote get-url "$_da_remote" >/dev/null 2>&1; then
        _da_remote=$(git -C "$_da_path" remote 2>/dev/null | head -n 1)
    fi
    _da_url=""
    [ -n "$_da_remote" ] && _da_url=$(git -C "$_da_path" remote get-url "$_da_remote" 2>/dev/null || printf '')
    url_safe_r "$_da_url"
    _da_url=$REPLY

    dash_header "Add a repo" ""
    dash_add_line ""
    dash_add_line "   Folder   $(path_encode "$_da_path")"
    dash_add_line "   Branch   ${_da_branch:-none checked out}"
    if [ -n "$_da_url" ]; then
        dash_add_line "   Remote   $_da_remote  $_da_url"
    else
        dash_add_line "   Remote   ${C_WARN}none yet: syncing fails until you add one${C_OFF}"
    fi
    dash_finish ""
    _da_def=$(basename "$_da_path" | sed 's/^\.//; s/[^A-Za-z0-9._-]/-/g')
    dash_prompt "Name [$_da_def]: " || D_IN=$_da_def
    _da_name=$D_IN
    if dash_confirm "Sync on every save? (no: every $(human_every "$G_INTERVAL" | sed 's/^every //'))" y; then
        _da_opts="watch=on"
    else
        _da_opts="watch=off"
    fi
    # Branch and remote names come from the repo: escape commas so neither can add options.
    [ -n "$_da_branch" ] && [ "$_da_branch" != "$G_BRANCH" ] &&
        _da_opts="$_da_opts,branch=${_da_branch//,/\\,}"
    [ -n "$_da_remote" ] && [ "$_da_remote" != "$G_REMOTE" ] &&
        _da_opts="$_da_opts,remote=${_da_remote//,/\\,}"
    if dash_do "Added $_da_name." cmd_add "$_da_name" "$_da_path" "$_da_opts"; then
        dash_refresh
        _da_i=0
        while [ "$_da_i" -lt "$D_N" ]; do
            [ "$(tg_name "$_da_i")" = "$_da_name" ] && D_SEL=$_da_i
            _da_i=$((_da_i + 1))
        done
        case "$D_BG" in
            off) dash_confirm "Added $_da_name. Turn on background syncing now?" y &&
                dash_do "Added $_da_name; background syncing is on." cmd_start ;;
            *) [ "$_da_opts" != "${_da_opts#watch=on}" ] && dash_apply_background ;;
        esac
        dash_refresh
    fi
    return 0
}

# Fields of the edit screen: key|label|kind
DASH_FIELDS="watch|Sync on every save|toggle
paused|Paused|toggle
interval|Scheduled every|secs
mode|Direction|mode
branch|Branch|text
remote|Remote|text
prefix|Commit prefix|text
remote_poll|Check the remote every|secs_off
stale|Alert after no sync for|stale
guard|Guard command|text
notify|Notify command|text
peer|Peer command|text
key|SSH key|text"

# dash_field_value KEY -> the effective value in words (uses t_*)
dash_field_value() {
    case "$1" in
        watch) printf '%s' "$t_watch" ;;
        paused) printf '%s' "$t_paused" ;;
        interval) human_every "$t_interval" | sed 's/^every //' ;;
        mode)
            case "$t_mode" in
                push) printf 'push only' ;;
                pull) printf 'pull only' ;;
                *) printf 'both ways' ;;
            esac
            ;;
        remote_poll)
            if [ "$t_remote_poll" -gt 0 ] 2>/dev/null; then
                human_every "$t_remote_poll" | sed 's/^every //'
            else
                printf 'off'
            fi
            ;;
        stale)
            case "$t_stale" in
                off) printf 'off' ;;
                0) printf 'auto (%s)' "$(human_ago "$(stale_limit)" | sed 's/ ago$//')" ;;
                *) human_ago "$t_stale" | sed 's/ ago$//' ;;
            esac
            ;;
        *) eval "_fv=\${t_$1:-}"; printf '%s' "${_fv:-none}" ;;
    esac
}

dash_edit() {
    _de_name=$(tg_name "$1")
    _de_sel=0
    _de_count=$(printf '%s\n' "$DASH_FIELDS" | wc -l | tr -d ' ')
    D_MSG=""
    while :; do
        dash_size
        targets_load
        _de_i=$(tg_index_of "$_de_name") || return 0
        _de_opts=$(tg_opts "$_de_i")
        resolve_opts "$_de_opts" || :
        dash_header "Edit $_de_name" ""
        _de_n=0
        while IFS='|' read -r _de_key _de_label _de_kind; do
            _de_val=$(dash_field_value "$_de_key")
            _de_tag=""
            opt_is_set "$_de_opts" "$_de_key" || _de_tag=" ${C_DIM}(default)$C_OFF"
            if [ "$_de_n" -eq "$_de_sel" ]; then
                dash_add_line " ▸ $C_REV$(printf '%-24s' "$_de_label")$C_OFF $(fit "$_de_val" $((D_COLS - 40)))$_de_tag"
            else
                dash_add_line "   $(printf '%-24s' "$_de_label") $(fit "$_de_val" $((D_COLS - 40)))$_de_tag"
            fi
            _de_n=$((_de_n + 1))
        done <<EOF
$DASH_FIELDS
EOF
        dash_finish "↑↓ choose  ⏎ change  - reset to default  ← back"
        dash_key
        case "$D_KEY" in
            tick) continue ;;
            up) [ "$_de_sel" -gt 0 ] && _de_sel=$((_de_sel - 1)) ;;
            down) [ "$_de_sel" -lt $((_de_count - 1)) ] && _de_sel=$((_de_sel + 1)) ;;
            left|esc|q) D_MSG=""; return 0 ;;
            -)
                _de_line=$(printf '%s\n' "$DASH_FIELDS" | sed -n "$((_de_sel + 1))p")
                _de_key=${_de_line%%|*}
                _de_label=${_de_line#*|}
                dash_do "${_de_label%|*} is back to the default." cmd_edit "$_de_name" "$_de_key=" || :
                case "$_de_key" in watch|remote_poll) dash_apply_background ;; esac
                ;;
            enter|right) dash_edit_field "$_de_name" "$(printf '%s\n' "$DASH_FIELDS" | sed -n "$((_de_sel + 1))p")" ;;
            *) D_MSG="" ;;
        esac
    done
}

# dash_edit_field NAME "key|label|kind"
dash_edit_field() {
    _ef_key=${2%%|*}
    _ef_kind=${2##*|}
    _ef_label=${2#*|}
    _ef_label=${_ef_label%|*}
    _ef_val=""
    case "$_ef_kind" in
        toggle)
            eval "_ef_cur=\$t_$_ef_key"
            # shellcheck disable=SC2154 # set by eval
            if [ "$_ef_cur" = "on" ]; then _ef_val=off; else _ef_val=on; fi
            ;;
        mode)
            case "$t_mode" in
                sync) _ef_val=push ;;
                push) _ef_val=pull ;;
                *) _ef_val=sync ;;
            esac
            ;;
        secs|secs_off|stale)
            _ef_hint="like 10m, 1h or 90s"
            [ "$_ef_kind" = "secs_off" ] && _ef_hint="$_ef_hint, or off"
            [ "$_ef_kind" = "stale" ] && _ef_hint="$_ef_hint, off, or auto"
            dash_prompt "$_ef_label ($_ef_hint): " || return 0
            case "$D_IN" in
                off) [ "$_ef_kind" = "secs" ] || _ef_val=off ;;
                auto) [ "$_ef_kind" = "stale" ] && _ef_val=0 ;;
                *) _ef_val=$(parse_duration "$D_IN") || _ef_val="" ;;
            esac
            if [ -z "$_ef_val" ]; then
                D_MSG="'$D_IN' is not a duration ($_ef_hint)."
                return 0
            fi
            ;;
        *)
            dash_prompt "$_ef_label (empty keeps it): " || return 0
            _ef_val=$(printf '%s' "$D_IN" | sed 's/,/\\,/g')
            ;;
    esac
    dash_do "" cmd_edit "$1" "$_ef_key=$_ef_val" || return 0
    targets_load
    resolve_opts "$(tg_opts "$(tg_index_of "$1")")" || :
    D_MSG="$_ef_label: $(dash_field_value "$_ef_key")"
    case "$_ef_key" in watch|remote_poll) dash_apply_background ;; esac
    return 0
}

# dash_details INDEX: one repo in full, with its recent activity
dash_details() {
    _dt_name=$(tg_name "$1")
    D_MSG=""
    while :; do
        dash_size
        targets_load
        _dt_i=$(tg_index_of "$_dt_name") || return 0
        target_health "$_dt_i"
        level_style "$H_LEVEL"
        _dt_path=$(tg_path "$_dt_i")
        dash_header "$_dt_name" "$L_C$L_SYM $H_TEXT$C_OFF"
        _dt_url=$(git -C "$_dt_path" remote get-url "$t_remote" 2>/dev/null || printf 'not set up')
        url_safe_r "$_dt_url"
        _dt_url=$REPLY
        case "$t_mode" in
            push) _dt_dir="push only, never pulls" ;;
            pull) _dt_dir="pull only, never commits" ;;
            *) _dt_dir="both ways" ;;
        esac
        if [ "$t_watch" = "on" ]; then
            _dt_when="on every save, and $(human_every "$t_interval") as a backstop"
        else
            _dt_when=$(human_every "$t_interval")
        fi
        _dt_w=$((D_COLS - 15))
        dash_add_line ""
        dash_add_line "   Folder     $(fit "$(path_encode "$_dt_path")" "$_dt_w")"
        dash_add_line "   Remote     $(fit "$t_remote, $_dt_url" "$_dt_w")"
        dash_add_line "   Branch     $t_branch"
        dash_add_line "   Syncs      $(fit "$_dt_when, $_dt_dir" "$_dt_w")"
        [ "$t_remote_poll" -gt 0 ] 2>/dev/null &&
            dash_add_line "              $(fit "checks the remote $(human_every "$t_remote_poll")" "$_dt_w")"
        dash_add_line "   Commits    $(fit "\"$t_prefix: notes.md\", \"$t_prefix: 3 files\"" "$_dt_w")"
        [ "$t_paused" = "on" ] && dash_add_line "   Paused     yes: background syncing skips it"
        [ -n "$t_guard" ] && dash_add_line "   Guard      $(fit "$t_guard" "$_dt_w")"
        [ -n "$t_notify" ] && dash_add_line "   Notify     $(fit "$t_notify" "$_dt_w")"
        [ -n "$t_peer" ] && dash_add_line "   Peer       $(fit "$t_peer" "$_dt_w")"
        if [ -n "$H_DETAIL" ] || { [ -n "$H_FIX" ] && [ "$H_LEVEL" != "wait" ]; }; then
            dash_add_line ""
            [ -n "$H_DETAIL" ] && dash_add_line "   $L_C$(fit "$H_DETAIL" $((D_COLS - 4)))$C_OFF"
            if [ "$H_LEVEL" = "bad" ] || [ "$H_LEVEL" = "warn" ]; then
                [ -n "$H_FIX" ] && dash_add_line "   fix: $(fit "$H_FIX" $((D_COLS - 9)))"
            fi
        fi
        dash_add_line ""
        dash_add_line "   ${C_BOLD}Recent activity$C_OFF"
        _dt_room=$((D_LINES - D_FL - 3))
        if [ "$_dt_room" -gt 0 ] && [ -f "$LOG_FILE" ]; then
            while IFS= read -r _dt_l; do
                _dt_ts=${_dt_l%% *}
                _dt_msg=${_dt_l#*msg=\"}
                _dt_msg=${_dt_msg%\"}
                _dt_msg=${_dt_msg//[[:cntrl:]]/}
                case "$_dt_msg" in
                    "sync ok ("*"committed=1"*) _dt_msg="synced: committed and pushed" ;;
                    "sync ok ("*"pulled=0"*) _dt_msg="synced: pushed, pull left for later" ;;
                    "sync ok ("*) _dt_msg="synced" ;;
                    "committed: "*) _dt_msg="committed \"${_dt_msg#committed: }\"" ;;
                esac
                dash_add_line "   $C_DIM${_dt_ts:5:5} ${_dt_ts:11:5}$C_OFF  $(fit "$_dt_msg" $((D_COLS - 16)))"
            done <<EOF
$(awk -v t="target=$_dt_name" '$3 == t' "$LOG_FILE" 2>/dev/null | tail -n "$_dt_room")
EOF
        fi
        dash_finish "e edit  s sync now  p pause  x remove  ← back"
        dash_key
        case "$D_KEY" in
            tick) continue ;;
            left|esc|q) D_MSG=""; return 0 ;;
            e) dash_edit "$_dt_i" ;;
            s)
                D_MSG="Syncing ${_dt_name}…"
                dash_finish "e edit  s sync now  p pause  x remove  ← back"
                dash_do "" cmd_sync "$_dt_name" || :
                target_health "$_dt_i"
                if [ "$H_LEVEL" = "ok" ]; then D_MSG="Synced $_dt_name."; else D_MSG="$_dt_name: $H_TEXT"; fi
                ;;
            p) dash_pause "$_dt_i" ;;
            x) dash_remove "$_dt_i" && return 0 ;;
            *) D_MSG="" ;;
        esac
    done
}

dash_help() {
    dash_size
    dash_header "How syncto works" ""
    dash_add_line ""
    logo_r "v$SYNCTO_VERSION" "keeps git repos in sync by themselves"
    while IFS= read -r _hl; do
        dash_add_line "   $_hl"
    done <<EOF
$REPLY
EOF
    dash_add_line ""
    dash_add_line "   Each repo is a git folder with a remote. A sync commits your changes,"
    dash_add_line "   pulls with rebase and pushes. Background syncing (b) runs it on a"
    dash_add_line "   schedule, and right after a save for repos set to sync on save."
    dash_add_line "   If both sides changed the same lines, syncto stops, leaves the repo"
    dash_add_line "   as it was and shows what to run to fix it."
    dash_add_line ""
    dash_add_line "   ${C_OK}✓$C_OFF synced   ${C_DIM}·$C_OFF waiting: new, paused or offline   $C_WARN!$C_OFF no sync for a while   ${C_BAD}✗$C_OFF needs you"
    dash_add_line ""
    dash_add_line "   ↑ ↓  choose a repo        ⏎  details and recent activity"
    dash_add_line "   a    add a repo           e  edit its settings"
    dash_add_line "   s    sync now             p  pause or resume"
    dash_add_line "   x    stop syncing it      b  background syncing on or off"
    dash_add_line "   q    quit"
    dash_add_line ""
    dash_add_line "   The same from the command line: syncto help"
    D_MSG=""
    dash_finish "any key: back"
    D_TICK=3600
    dash_key
    D_TICK=5
}

cmd_dashboard() {
    D_SEL=0 D_TOP=0 D_MSG="" D_TICK=5
    colors_init
    dash_enter
    dash_refresh
    while :; do
        dash_draw_list
        dash_key
        case "$D_KEY" in
            tick) dash_refresh ;;
            up) [ "$D_SEL" -gt 0 ] && D_SEL=$((D_SEL - 1)); D_MSG="" ;;
            down) [ "$D_SEL" -lt $((D_N - 1)) ] && D_SEL=$((D_SEL + 1)); D_MSG="" ;;
            q|esc) break ;;
            a) dash_add ;;
            b) dash_background ;;
            '?') dash_help ;;
            *)
                if [ "$D_N" -eq 0 ]; then
                    D_MSG=""
                    continue
                fi
                case "$D_KEY" in
                    enter|right) dash_details "$D_SEL"; dash_refresh ;;
                    e) dash_edit "$D_SEL"; dash_refresh ;;
                    s) dash_sync "$D_SEL" ;;
                    p) dash_pause "$D_SEL" ;;
                    x) dash_remove "$D_SEL" || : ;;
                    *) D_MSG="" ;;
                esac
                ;;
        esac
    done
    dash_leave
    return 0
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------

usage() {
    colors_init
    logo_r "v$SYNCTO_VERSION" "keeps git repos in sync by themselves: commit, pull, push"
    cat <<EOF
$REPLY

USAGE
  syncto [-v] [COMMAND]

COMMANDS
  (none)                    dashboard: see, add, edit, pause and sync repos
  status                    how every sync is doing, as text
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
    # shellcheck disable=SC2174 # only the last folder needs to be private
    [ -d "$STATE_DIR" ] || mkdir -p -m 700 "$STATE_DIR" 2>/dev/null || :
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
            if dash_can_run; then
                cmd_dashboard
            else
                cmd_status
            fi
            ;;
        status) cmd_status ;;
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
