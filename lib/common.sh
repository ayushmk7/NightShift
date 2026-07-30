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

# The slug of tier-1's agent-less autofix branch (`nightshift/<date>/autofix`). SINGLE SOURCE OF
# TRUTH: lib/tier1.sh builds its branch name from it, lib/promote.sh tests against it, and
# bin/test-harness.sh section 9 asserts the two stay in lockstep.
#
# It exists because "this branch has no theme file" is AMBIGUOUS and the two meanings need opposite
# handling. Tier-1 legitimately has none — it is deterministic `jac fmt --lintfix` output with no
# agent and nothing to scope-check. A tier-2 branch always had one, but $LOG_DIR is DATE-KEYED
# (line 6 above), so the file is simply not where S7 looks the moment a human promotes on a
# different calendar day than the run that produced it — the normal case for a 23:00 night. Reading
# that absence as "no theme" would hand verify_branch a theme of "-", which makes it skip scope
# containment entirely (lib/verify.sh stage 1) — i.e. re-gate the one class of branch an LLM wrote,
# without the anti-injection check. So tier-1 is recognised POSITIVELY, by name, and every other
# branch must produce its theme file or die loudly.
NS_TIER1_SLUG="autofix"
ns_is_tier1_branch() { [ "$(basename "$1")" = "$NS_TIER1_SLUG" ]; }

# --- exit codes (TechnicalPRD 18; 50=audit-parse and 60=ceiling live in their tools) ---
EX_LOCK=40; EX_DISABLED=41; EX_AUTH=42; EX_OFFLINE=43; EX_SYNC=44; EX_ALLFAIL=51; EX_BUG=70

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
# ns_die RECORDS WHY, not just that. bin/nightshift.sh's ns_on_exit copies only CURRENT_STAGE to
# ERROR_STAGE, and the stage NAME is all the digest reports -- but this branch multiplied ns_die
# call sites in the unattended path (13 in lib/verify.sh alone, every one of them EX_BUG=70), so
# "the night died in S4" is now almost no information at all. The reason text is written here and
# folded into the digest by ns_on_exit. Best-effort (`|| true`): $LOG_DIR may not exist yet on the
# earliest failure paths, and losing the reason must never change the exit code the caller asked
# for. Stopgap for the unattended channel; the real digest work is Plan 4.
ns_die()  {
    local code=$1; shift
    ns_log FATAL "$*"
    printf '%s\n' "$*" > "$LOG_DIR/FATAL_REASON" 2>/dev/null || true
    exit "$code"
}

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
# gtimeout (brew coreutils, hard dep — preflight checks it). Arg is minutes.
ns_timebox() {
    local min=$1; shift
    gtimeout "${min}m" "$@"
}

# Block until fewer than <max> of THIS shell's background jobs are still running.
# bash 3.2 (macOS stock, confirmed 3.2.57) has no `wait -n`, so poll instead of blocking on one job.
# ponytail: 5s poll, not a job-control state machine. Audit sessions run for minutes.
# LOAD-BEARING DEPENDENCY: this counts *every* running job of the calling shell, so the `disown`s on
# the caffeinate and watchdog children (bin/nightshift.sh:60,66) are what keep them out of the count.
# Drop either disown and the two long-lived children occupy the budget forever -- ns_jobs_wait 2 then
# blocks until the watchdog kills the night, and no audit shard ever starts.
# max<1 (or a non-numeric [shards].concurrency) would make `-ge` always true and spin here until
# that same watchdog fires, so clamp to 1. `case`, not `[ -lt ] &&`, because a false `&&` list is
# itself a nonzero return that would abort any caller running with errexit active.
ns_jobs_wait() {
    local max=$1
    case "$max" in ''|0|*[!0-9]*) max=1 ;; esac
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$max" ]; do
        sleep 5
    done
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

# summed added/removed line counts across a diff range — ship (draft stats) + dataset backfill
ns_diff_numstat() {   # ns_diff_numstat <dir> <range>
    git -C "$1" diff --numstat "$2" \
        | awk '{if ($1 ~ /^[0-9]+$/) a+=$1; if ($2 ~ /^[0-9]+$/) r+=$2} END {print a+0, r+0}'
}

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

# --- secrets ---
ns_load_env() {
    # `if`, never `[ -f x ] && . x`: a false `&&` list is itself a nonzero return, and this function
    # is called BARE (not from an `if`) by bin/nightshift.sh's promote / baseline / mirror arms,
    # where errexit is live and ns_run_inner's EXIT trap does not exist — so a missing env file
    # would abort the command with status 1, no [FATAL] line and no autopsy email. Latent only
    # because the file happens to exist on this host; Plan 5's move to ~/nightshift is exactly the
    # kind of change that makes it not.
    if [ -f "$HOME/.nightshift.env" ]; then
        # shellcheck disable=SC1090
        . "$HOME/.nightshift.env"
    fi
    # A set ANTHROPIC_API_KEY silently outranks the subscription (TPRD feasibility row 7).
    unset ANTHROPIC_API_KEY
}
