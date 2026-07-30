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

# The task a branch belongs to, derived from the branch NAME the harness built:
# nightshift/<date>/<task>-<theme-hint>. NEVER from the theme file -- the theme is assembled from
# agent-authored findings, and if the gate read the task from there, a dead-code audit could ask
# for the coverage task's tests/** write exemption and be given it.
#
# Prints the task and returns 0, or returns 1 having printed nothing. Callers MUST treat rc=1 as
# fatal, never as "no task": an unresolved task means no permission set can be applied at all.
# A failure inside `tasks list` also lands here as rc=1 (the loop iterates zero times), which is
# the safe direction -- the discarded-reader bug this codebase keeps finding fails CLOSED here.
#
# Prefix matching is only unambiguous because no task name is a prefix of another;
# bin/test-harness.sh section 11 asserts that from outside, over the real config.
ns_task_of_branch() {
    local slug task
    slug="$(basename "$1")"
    for task in $(ns_jac tasks list "$CONFIG"); do
        case "$slug" in
            "$task"-*) printf '%s\n' "$task"; return 0 ;;
        esac
    done
    return 1
}

# Which theme file re-gates this branch, for any night, not just tonight.
#
# Since tier-1 was retired (2026-07-30) EVERY branch is agent-written, so there is no legitimate
# theme-less branch and no "-" arm here: verify_branch SKIPS scope containment (lib/verify.sh
# stage 1) whenever theme is "-", so resolving an absent theme to "-" would re-gate the one class
# of branch an LLM wrote with the anti-injection check switched off. Absence is fatal, never "-".
#
# The reason absence happens at all is that $LOG_DIR is DATE-KEYED, so a later night simply does
# not look where the theme was written. lib/ship.sh therefore copies each theme to the drafts
# branch beside its draft .md, and this resolver reads tonight's logs first and there second. That
# is what retires the `NS_DATE=<night> nightshift.sh promote` workaround lib/promote.sh used to
# prescribe, and what lets S1.6 re-gate a PR opened on an arbitrary earlier night.
#
# `if`, never `[ -f x ] && echo x`: this is called from promote_main, which bin/nightshift.sh
# invokes BARE with errexit live and no EXIT trap.
ns_theme_for_branch() {
    local branch=$1 slug
    slug="$(basename "$branch")"
    if [ -f "$LOG_DIR/theme-$slug.json" ]; then
        echo "$LOG_DIR/theme-$slug.json"
        return 0
    fi
    if [ -f "$DRAFTS/themes/$slug.json" ]; then
        echo "$DRAFTS/themes/$slug.json"
        return 0
    fi
    ns_die "$EX_BUG" "no theme file for the agent-written branch $branch (looked in $LOG_DIR/theme-$slug.json and $DRAFTS/themes/$slug.json). Re-gating it with theme '-' would skip verify_branch's scope-containment/anti-injection check — refusing. If the theme exists under some other night's logs/<date>/, copy it to $DRAFTS/themes/$slug.json so every later night can find it."
}

# --- logging & night bookkeeping ---
ns_log()  { printf '%s [%s] %s\n' "$(date '+%H:%M:%S')" "$1" "$2" | tee -a "$LOG_DIR/run.log" >&2; }
ns_warn() { ns_log WARN "$1"; echo "$1" >> "$LOG_DIR/warnings.txt"; }
ns_fail() { printf '%s\t%s\n' "$1" "$2" >> "$LOG_DIR/failed.tsv"; ns_log FAIL "$1: $2"; }
# ns_die RECORDS WHY, not just that. bin/nightshift.sh's ns_on_exit copies CURRENT_STAGE to
# ERROR_STAGE (WHERE), and this writes the reason text (WHY). Both are read as first-class fields
# by scripts/sendmail.jac's summarize() and appear in the subject line and the digest body --
# without the reason, all 13 ns_die sites in lib/verify.sh alone read identically as "ERROR S4".
# Best-effort (`|| true`): $LOG_DIR may not exist yet on the earliest failure paths, and losing
# the reason must never change the exit code the caller asked for.
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
    # Two refusals, both cheap and both about damage that cannot be undone from here:
    #   * a bare --force (threat T3). --force-with-lease is explicitly allowed: S1.6 rebases open
    #     PR branches and cannot push the result without it.
    #   * anything targeting the default branch. Nightshift pushes nightshift/* refs and the
    #     nightshift/drafts orphan, never main -- on the fork or anywhere else.
    # `case` inside a `for`, never `[ x ] && ns_die`: this runs on the success path of every push.
    local a
    for a in "$@"; do
        case "$a" in
            --force|-f)
                ns_die "$EX_BUG" "ns_git_push refuses a bare --force (use --force-with-lease): git -C $dir push $*" ;;
            "$NS_REPO_DEFAULT_BRANCH"|*":$NS_REPO_DEFAULT_BRANCH"|*":refs/heads/$NS_REPO_DEFAULT_BRANCH")
                ns_die "$EX_BUG" "ns_git_push refuses to push to '$NS_REPO_DEFAULT_BRANCH': git -C $dir push $*" ;;
        esac
    done
    if [ -n "${NS_DRY_RUN:-}" ]; then
        ns_log DRY "git -C $dir push $*"
    else
        git -C "$dir" push "$@"
    fi
}

# --- gh seam ---------------------------------------------------------------------------------
# `gh` splits into two populations with OPPOSITE dry-run behavior, so it gets two functions rather
# than one with a flag. Read-only calls must run during a dry run (an inventory that cannot list
# PRs rehearses nothing); mutating calls must not (a dry run that opens a real upstream PR is the
# single worst outcome this seam exists to prevent). Each function refuses the other's population,
# because the failure of a one-function design is silent in exactly one direction.
#
# `case`, never `[ ... ] && ns_die`: these are called from promote_main / discard_main, which
# bin/nightshift.sh invokes BARE, so errexit is live and a false `&&` list would abort the command
# with a bare status 1, no [FATAL] line and no autopsy email.
ns_gh() {   # READ-ONLY gh. Runs even under NS_DRY_RUN.
    local pair="${1:-} ${2:-}"
    case "$pair" in
        "pr list"|"pr view"|"pr checks"|"pr diff"|"repo view"|"run list") : ;;
        "api "*)
            # A path alone is a GET; an explicit method is a write however read-only the path looks.
            case " $* " in
                *" -X "*|*" --method "*)
                    ns_die "$EX_BUG" "ns_gh: 'gh api' with an explicit HTTP method mutates GitHub and must go through ns_gh_write -- ns_gh runs even under NS_DRY_RUN, so this would have written for real during a rehearsal: gh $*" ;;
            esac ;;
        *)  ns_die "$EX_BUG" "ns_gh: '$pair' is not a known read-only gh call, and ns_gh runs even under NS_DRY_RUN. If it changes anything on GitHub use ns_gh_write; if it is genuinely read-only, add it to this list deliberately." ;;
    esac
    "$NS_PATHS_GH" "$@"
}

# MUTATING gh. Stubbed under NS_DRY_RUN (TPRD 14, same seam contract as ns_git_push).
#
# `pr merge` and `pr ready` are refused in BOTH modes, not just the live one: a dry-run stub would
# let a merge call sit in the codebase looking exercised. Spec section 6 -- Nightshift never merges
# and never takes a PR out of draft; the PR is terminal until a human merges it on GitHub.
#
# The dry-run branch prints a shape-valid but obviously fake URL for `pr create`, because the
# caller's job is to assert it got a URL (a gh call that silently returns nothing must never read
# as success) and that assertion has to be exercised in rehearsal too. The sentinel reaches only
# gitignored state: state/ledger.jsonl.cache and $LOG_DIR, since ns_git_push stubs the drafts push
# and lib/dataset.sh already records nothing under NS_DRY_RUN.
ns_gh_write() {
    local pair="${1:-} ${2:-}"
    case "$pair" in
        "pr merge"|"pr ready")
            ns_die "$EX_BUG" "ns_gh_write refuses '$pair': Nightshift never merges a PR and never takes one out of draft. A human merges it on GitHub or it stays open." ;;
    esac
    if [ -n "${NS_DRY_RUN:-}" ]; then
        ns_log DRY "gh $*"
        case "$pair" in
            "pr create") echo "https://github.com/DRY-RUN/pull/0" ;;
        esac
        return 0
    fi
    "$NS_PATHS_GH" "$@"
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
