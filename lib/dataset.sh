# shellcheck shell=bash
# lib/dataset.sh — training-data capture (scripts/dataset.jac). Every real night's audit
# findings, shipped refactor diffs, and (eventually) human promote/discard decisions land in
# dataset/*.jsonl for later fine-tuning a jac-focused model.

DATASET_DIR="$NS_ROOT/dataset"

# A DRY RUN IS RECORDED, flagged. Only `git push` and `gh pr create` are stubbed under NS_DRY_RUN --
# the audit sessions, the apply sessions, the commits, the branches and the whole S4 gate are real,
# and so is the bill. The old rule here ("rehearsal nights are sandbox data") threw 112 findings, 27
# sessions, 6 shipped branches and $76.55 of genuine training data off 2026-07-31 on a technicality.
# The ONE field a dry run makes untrue is the fork URL, and that is nulled at the call below rather
# than the whole row being withheld. dataset_record_review keeps its guard; see there for why.

# Called once per night after select+apply. Runs when EITHER phase left a findings file: the
# reactive pass has its own (findings-reactive.json) and produced 3 of the 6 branches on 2026-07-31,
# so gating solely on findings.json made a whole phase invisible. The jac side is what decides
# whether a phase parsed; this only avoids the process spawn when there is provably nothing at all.
dataset_record_night() {
    # The audit is whole-repo (sharded) now, so a night has no single package. "repo" keeps
    # record-audit's argv arity and its (date, package) idempotency key intact; backfill still
    # passes a real package for historical nights that had rotation. `local pkg=$1` would abort
    # under `set -u` here.
    local pkg="${1:-repo}"
    # `case`, not `[ -f ] || [ -f ] || return`: this is called on tier2_main's success path under
    # errexit, and a false `&&`/`||` list is itself a nonzero return.
    case "$(ls "$LOG_DIR"/findings.json "$LOG_DIR"/findings-reactive.json 2>/dev/null)" in
        "") return 0 ;;
    esac
    mkdir -p "$DATASET_DIR"
    ns_jac dataset record-audit "$LOG_DIR" "$DATASET_DIR" "$NS_DATE" "$pkg" "$CONFIG" \
        "$(dataset_dry_flag)" >/dev/null
}

# "true" / "false", never the empty string: the jac side reads it as a positional argument, and an
# empty argv slot would shift every later argument by one.
dataset_dry_flag() {
    case "${NS_DRY_RUN:-}" in
        "") printf 'false\n' ;;
        *)  printf 'true\n' ;;
    esac
}

# Called once per shipped branch (lib/ship.sh), after it has been pushed.
dataset_record_refactor() {
    local branch=$1 pkg=$2 theme=$3 report=$4 added=$5 removed=$6 verify_line=$7 url=$8
    # THE URL IS THE ONLY THING A DRY RUN FALSIFIES. ship_branch composes
    # https://github.com/<fork>/tree/<branch> unconditionally, but ns_git_push was stubbed, so on a
    # rehearsal that link points at a branch the fork has never seen. Emptied here and stored as
    # null by scripts/dataset.jac; the diff, the finding, the gate result and the cost are all real
    # and are all kept.
    case "${NS_DRY_RUN:-}" in
        "") : ;;
        *)  url="" ;;
    esac
    local base_ref
    base_ref="$(git -C "$REPO" merge-base "$NS_REPO_DEFAULT_BRANCH" "$branch")" || return 0
    mkdir -p "$DATASET_DIR"
    ns_jac dataset record-refactor "$base_ref" "$branch" "$REPO" "$DATASET_DIR" "$LOG_DIR" \
        "$NS_DATE" "$pkg" "$theme" "$report" "$added" "$removed" "$verify_line" "$url" \
        "$(dataset_dry_flag)" >/dev/null
}

# Called from lib/promote.sh (promote_main / discard_main) — the highest-quality supervision
# signal, joined to refactors.jsonl by branch name at training time.
dataset_record_review() {
    local branch=$1 accepted=$2 reason=$3
    # THE ONE RECORDER THAT KEEPS ITS DRY-RUN GUARD, and the reason the siblings above no longer
    # need theirs. This is the only recorder reached from an INTERACTIVE command (promote/discard)
    # rather than from a night: nothing behind it ran, no session was spent, and the "decision" is a
    # human rehearsing the CLI. Every rehearsal of the ship or kill path used to append a synthetic
    # row to dataset/human_reviews.jsonl -- which, unlike logs/ and state/, is TRACKED. Caught during
    # a Plan 3 rehearsal that dirtied the tree.
    [ -n "${NS_DRY_RUN:-}" ] && return 0
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
            # dry_run=false: a backfill describes nights that already happened, and whether THIS
            # process is a rehearsal says nothing about them. The per-night truth is not recoverable
            # from a log dir written before the DRY_RUN marker existed, so it is not guessed.
            ns_jac dataset record-audit "$d" "$DATASET_DIR" "$date_only" "$pkg" "$CONFIG" false >/dev/null
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
                "$d" "$date_only" "$pkg" "$theme" "$report" "$added" "$removed" "$tests_line" "$url" false) ))
        done < "$d/green.tsv"
    done
    ns_log DATASET "backfill done: $n refactor rows"
    wc -l "$DATASET_DIR"/*.jsonl 2>/dev/null
}
