# shellcheck shell=bash
# lib/dataset.sh — training-data capture (scripts/dataset.jac). Every real night's audit
# findings, shipped refactor diffs, and (eventually) human promote/discard decisions land in
# dataset/*.jsonl for later fine-tuning a jac-focused model.

DATASET_DIR="$NS_ROOT/dataset"

# Called once per night after select+apply (findings.json exists, whether 0 or N).
# Dry-runs record nothing: rehearsal nights are sandbox data, same reason backfill skips
# suffixed log dirs.
dataset_record_night() {
    # The audit is whole-repo (sharded) now, so a night has no single package. "repo" keeps
    # record-audit's argv arity and its (date, package) idempotency key intact; backfill still
    # passes a real package for historical nights that had rotation. `local pkg=$1` would abort
    # under `set -u` here.
    local pkg="${1:-repo}"
    [ -n "${NS_DRY_RUN:-}" ] && return 0
    [ -f "$LOG_DIR/findings.json" ] || return 0
    mkdir -p "$DATASET_DIR"
    ns_jac dataset record-audit "$LOG_DIR" "$DATASET_DIR" "$NS_DATE" "$pkg" >/dev/null
}

# Called once per shipped branch (lib/ship.sh), after it has been pushed.
dataset_record_refactor() {
    local branch=$1 pkg=$2 theme=$3 report=$4 added=$5 removed=$6 verify_line=$7 url=$8
    [ -n "${NS_DRY_RUN:-}" ] && return 0
    local base_ref
    base_ref="$(git -C "$REPO" merge-base "$NS_REPO_DEFAULT_BRANCH" "$branch")" || return 0
    mkdir -p "$DATASET_DIR"
    ns_jac dataset record-refactor "$base_ref" "$branch" "$REPO" "$DATASET_DIR" "$NS_DATE" \
        "$pkg" "$theme" "$report" "$added" "$removed" "$verify_line" "$url" >/dev/null
}

# Called from lib/promote.sh (promote_main / discard_main) — the highest-quality supervision
# signal, joined to refactors.jsonl by branch name at training time.
dataset_record_review() {
    local branch=$1 accepted=$2 reason=$3
    mkdir -p "$DATASET_DIR"
    ns_jac dataset record-review "$branch" "$DATASET_DIR" "$accepted" "$reason" >/dev/null
}

# One-time (or re-runnable) sweep over every REAL past night still on disk, rebuilding the
# dataset from historical artifacts. Skips suffixed log dirs (logs/<date>.anything) -- those are
# sandbox/demo test-fires from harness development, not representative jac code.
dataset_backfill() {
    mkdir -p "$DATASET_DIR"
    local d date_only branch theme report added removed tests_line url pkg base_ref n=0
    for d in "$NS_ROOT"/logs/20*; do
        [ -d "$d" ] || continue
        date_only="$(basename "$d")"
        case "$date_only" in *.*) continue ;; esac

        if [ -f "$d/findings.json" ]; then
            # Nights from the rotation era logged their package; sharded nights do not log one at
            # all. The fallback MUST match dataset_record_night's "repo" -- record_audit's
            # idempotency key is exactly (date, package), so "unknown" here would make a backfill
            # append a duplicate nights row and a duplicate audit_findings set for every night the
            # live path already recorded.
            pkg="$(grep -m1 "tonight's package:" "$d/run.log" 2>/dev/null | sed 's/.*tonight.s package: //')"
            [ -n "$pkg" ] || pkg="repo"
            ns_jac dataset record-audit "$d" "$DATASET_DIR" "$date_only" "$pkg" >/dev/null
            ns_log DATASET "backfilled audit findings for $date_only"
        fi

        [ -f "$d/green.tsv" ] || continue
        while IFS=$'\t' read -r branch theme report; do
            [ -n "$branch" ] || continue
            git -C "$REPO" fetch origin "$branch" -q 2>/dev/null || { ns_log DATASET "skip $branch (not on fork anymore)"; continue; }
            if [ "$theme" != "-" ] && [ -f "$theme" ]; then
                pkg="$(ns_jac parse_result field package < "$theme" 2>/dev/null)"
            else
                pkg="repo"
            fi
            base_ref="$(git -C "$REPO" merge-base "$NS_REPO_DEFAULT_BRANCH" "origin/$branch" 2>/dev/null)"
            [ -n "$base_ref" ] || { ns_log DATASET "skip $branch (no merge-base)"; continue; }
            read -r added removed < <(ns_diff_numstat "$REPO" "$base_ref...origin/$branch")
            tests_line="$(cat "$d/tests-$(basename "$branch").txt" 2>/dev/null || echo "verified")"
            url="https://github.com/$NS_REPO_FORK/tree/$branch"
            [ -f "$report" ] || continue
            n=$(( n + $(ns_jac dataset record-refactor "$base_ref" "origin/$branch" "$REPO" "$DATASET_DIR" \
                "$date_only" "$pkg" "$theme" "$report" "$added" "$removed" "$tests_line" "$url") ))
        done < "$d/green.tsv"
    done
    ns_log DATASET "backfill done: $n refactor rows"
    wc -l "$DATASET_DIR"/*.jsonl 2>/dev/null
}
