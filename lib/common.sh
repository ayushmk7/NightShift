# shellcheck shell=bash
# lib/common.sh — sourced by bin/nightshift.sh. Shared plumbing for every stage.
# Requires: NS_ROOT exported by the entry script.

NS_DATE="${NS_DATE:-$(date +%F)}"
LOG_DIR="$NS_ROOT/logs/$NS_DATE"
REPO="$NS_ROOT/work/repo"
DRAFTS="$NS_ROOT/work/drafts"
STATE="$NS_ROOT/state/state.json"
LEDGER="$NS_ROOT/state/ledger.jsonl.cache"
CONFIG="$NS_ROOT/config/nightshift.toml"
LOCK_DIR="/tmp/nightshift.lock"

# --- exit codes (TechnicalPRD 18) ---
EX_OK=0; EX_LOCK=40; EX_DISABLED=41; EX_AUTH=42; EX_OFFLINE=43; EX_SYNC=44
EX_AUDIT=50; EX_ALLFAIL=51; EX_CEILING=60; EX_BUG=70

# --- config bootstrap ---
# Chicken-and-egg: the jac binary path lives in the toml that jac itself reads.
# Grep the one bootstrap key, then let config.jac emit everything else.
ns_bootstrap_jac() {
    NS_PATHS_JAC="$(sed -n 's/^jac *= *"\(.*\)"/\1/p' "$CONFIG" | head -1)"
    NS_PATHS_JAC="${NS_PATHS_JAC:-$(command -v jac)}"
    [ -x "$NS_PATHS_JAC" ] || { echo "FATAL: jac binary not found" >&2; exit "$EX_BUG"; }
}

ns_load_config() {
    ns_bootstrap_jac
    eval "$(cd "$NS_ROOT" && "$NS_PATHS_JAC" run scripts/config.jac env "$CONFIG")"
}

# All Jac helpers run from NS_ROOT: jac writes its .jac cache dir into the cwd.
ns_jac() {
    local script=$1; shift
    (cd "$NS_ROOT" && "$NS_PATHS_JAC" run "scripts/$script.jac" "$@")
}

# --- logging & night bookkeeping ---
ns_log()  { printf '%s [%s] %s\n' "$(date '+%H:%M:%S')" "$1" "$2" | tee -a "$LOG_DIR/run.log" >&2; }
ns_warn() { ns_log WARN "$1"; echo "$1" >> "$LOG_DIR/warnings.txt"; }
ns_fail() { printf '%s\t%s\n' "$1" "$2" >> "$LOG_DIR/failed.tsv"; ns_log FAIL "$1: $2"; }
ns_die()  { local code=$1; shift; ns_log FATAL "$*"; exit "$code"; }

# --- lock (mkdir is atomic on APFS; no flock on stock macOS) ---
ns_lock_acquire() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        return 0
    fi
    local holder; holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        ns_die "$EX_LOCK" "lock held by live pid $holder"
    fi
    ns_log LOCK "reclaiming stale lock (pid ${holder:-unknown} is gone)"
    rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR"; echo $$ > "$LOCK_DIR/pid"
}
ns_lock_release() { rm -rf "$LOCK_DIR"; }

# --- CI/CD automation: retry logic for transient failures ---
# ns_retry <attempts> <delay_sec> <command> <args...>
# Retries a command multiple times with delays, returns last exit code
ns_retry() {
    local attempts=$1 delay=$2; shift 2
    local last_exit=1
    for ((i=1; i<=attempts; i++)); do
        "$@" && { last_exit=0; break; } || last_exit=$?
        if [ "$i" -lt "$attempts" ]; then
            ns_log RETRY "Command failed (attempt $i/$attempts), retrying in ${delay}s..."
            sleep "$delay"
        fi
    done
    return "$last_exit"
}

# --- time-boxes ---
# gtimeout (brew coreutils) when present, scripts/timeout.jac otherwise. Arg is minutes.
ns_timebox() {
    local min=$1; shift
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${min}m" "$@"
    else
        ns_jac timeout "$((min * 60))" "$@"
    fi
}

ns_remaining_min() {
    local start now elapsed
    start="$(cat "$LOG_DIR/start_epoch")"; now="$(date +%s)"
    elapsed=$(( (now - start) / 60 ))
    echo $(( NS_BUDGETS_WALLCLOCK_MIN - elapsed ))
}

# --- stage runner: .done markers make same-night re-runs idempotent (TPRD 7, 12) ---
ns_stage() {
    local id=$1 fn=$2
    if [ -f "$LOG_DIR/.done-$id" ]; then
        ns_log "$id" "already done — skipping"
        return 0
    fi
    echo "$id" > "$LOG_DIR/CURRENT_STAGE"
    ns_log "$id" "start"
    "$fn" >> "$LOG_DIR/$id.log" 2>&1
    touch "$LOG_DIR/.done-$id"
    ns_log "$id" "done"
}

# --- branch queue between S2/S3 (producers) and S4 (gate) / S5 (ship) ---
# queue.tsv line: branch<TAB>theme.json-or-"-"<TAB>report.json-or-"-"
ns_queue_branch()   { printf '%s\t%s\t%s\n' "$1" "${2:--}" "${3:--}" >> "$LOG_DIR/queue.tsv"; }
ns_mark_green()     { printf '%s\t%s\t%s\n' "$1" "${2:--}" "${3:--}" >> "$LOG_DIR/green.tsv"; }

# --- dry-run seam: every push in the nightly path goes through this (TPRD 14) ---
ns_git_push() {   # ns_git_push <dir> <push-args...>
    local dir=$1; shift
    if [ -n "${NS_DRY_RUN:-}" ]; then
        ns_log DRY "git -C $dir push $*"
    else
        git -C "$dir" push "$@"
    fi
}

# pre-commit's system-language hooks (jac-format, validate-fragments) shell out to `jac`;
# that must be the target repo's dev binary, so put its dir first on PATH for the hook run.
ns_precommit() {
    PATH="$(dirname "$NS_PATHS_JAC_REPO"):$PATH" "$NS_PATHS_PRECOMMIT" "$@"
}

# Real path(s) to audit for a "package" — none of these are actual top-level directories except
# jac-byllm (jac-mcp's dir is an empty placeholder; jac-scale and jac core both live under
# jac/jaclang/). Same mapping problem already fixed for the test/check gates in lib/verify.sh and
# tier1's format scope; the audit prompt was still saying "look in {pkg}/" literally, which for
# jac-mcp points at nothing. Confirmed live: a real jac-mcp audit night found 0 findings.
ns_audit_scope() {
    case "$1" in
        jac-byllm) echo "jac/jaclang/byllm/" ;;
        jac-mcp)   echo "jac/jaclang/byllm/mcp.jac, jac/jaclang/byllm/impl/mcp.impl.jac, jac/jaclang/cli/commands/mcp.jac, jac/jaclang/cli/commands/impl/mcp.impl.jac, jac/jaclang/cli/mcp/ (MCP protocol/server integration — scattered across cli and byllm, no single directory)" ;;
        jac-scale) echo "jac/jaclang/scale/" ;;
        *)         echo "jac/jaclang/ (excluding jac/jaclang/byllm/ and jac/jaclang/scale/, which are separate packages)" ;;
    esac
}

# --- secrets ---
ns_load_env() {
    # shellcheck disable=SC1090
    [ -f "$HOME/.nightshift.env" ] && . "$HOME/.nightshift.env"
    # A set ANTHROPIC_API_KEY silently outranks the subscription (TPRD feasibility row 7).
    unset ANTHROPIC_API_KEY
}
