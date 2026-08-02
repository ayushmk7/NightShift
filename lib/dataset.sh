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

# Was the night in <log_dir> a REHEARSAL? Prints "true" or "false"; never returns nonzero.
#
# Phase 2 recorded "the per-night truth is not recoverable from a log dir written before the
# DRY_RUN marker existed" and hardcoded false at the record-audit call below. That is wrong on the
# artifacts: logs/2026-07-31 -- the one rehearsal night in the corpus, and the only complete
# end-to-end run that exists -- carries two independent traces of its own dry run. Labelling it
# `dry_run: false` writes a false field into tracked training data, which is precisely the class of
# defect the DRY_RUN marker was added to close.
#
# Three signals, any one conclusive, each written by the dry-run seam itself:
#   1. <log_dir>/DRY_RUN            -- bin/nightshift.sh:80's marker. Definitive, but only exists
#                                      for nights after it was added, which is why it is not alone.
#   2. prs.jsonl holding ns_gh_write's stub URL (lib/common.sh:330, "DRY-RUN/pull/0"). A DATA
#                                      artifact emitted by the stub, not a log line.
#   3. run.log's "[S6] dry-run: digest rendered, not sent" (lib/email.sh:24).
# DIRECTION OF ERROR: a rehearsal that shipped nothing AND died before S6 reads as live. That can
# only under-claim a rehearsal, never invent one -- and a night with no branches and no digest has
# no field a dry run would falsify anyway. `case`/`if`, never a bare `&&` list: this runs under
# bin/nightshift.sh's errexit.
dataset_night_was_dry() {
    local d=$1
    case "$(ls "$d/DRY_RUN" 2>/dev/null)" in
        "") : ;;
        *)  printf 'true\n'; return 0 ;;
    esac
    if grep -q 'DRY-RUN/pull/0' "$d/prs.jsonl" 2>/dev/null; then
        printf 'true\n'; return 0
    fi
    if grep -q '\[S6\] dry-run:' "$d/run.log" 2>/dev/null; then
        printf 'true\n'; return 0
    fi
    printf 'false\n'
}

# One-time (or re-runnable) sweep over every REAL past night still on disk, rebuilding the
# dataset from historical artifacts. Skips suffixed log dirs (logs/<date>.anything) -- those are
# sandbox/demo test-fires from harness development, not representative jac code.
#
# NOT IDEMPOTENT for refactors.jsonl. record_audit/session/decline rows each carry their own
# `already_has` key, but record_refactor has none, so a second sweep over the same green.tsv
# appends the same file rows again. Run it once, against a scratch DATASET_DIR first if unsure.
dataset_backfill() {
    mkdir -p "$DATASET_DIR"
    local d date_only branch theme report added removed tests_line url pkg base_ref ref dry n=0
    for d in "$NS_ROOT"/logs/20*; do
        [ -d "$d" ] || continue
        date_only="$(basename "$d")"
        case "$date_only" in *.*) continue ;; esac
        dry="$(dataset_night_was_dry "$d")"

        if [ -f "$d/findings.json" ]; then
            # Nights from the rotation era logged their package; sharded nights do not log one at
            # all. The fallback MUST match dataset_record_night's "repo" -- record_audit's
            # idempotency key is exactly (date, package), so "unknown" here would make a backfill
            # append a duplicate nights row and a duplicate audit_findings set for every night the
            # live path already recorded.
            # `sed -n .../p`, not `grep -m1 … | sed …`. bin/nightshift.sh runs this command under
            # `set -euo pipefail` with errexit LIVE (dataset_backfill is not called from a tested
            # context there), and grep exits 1 when it matches nothing -- which is the NORMAL case
            # since the audit went whole-repo and no night logs a package any more. With pipefail
            # that rc becomes the assignment's, and `nightshift.sh dataset-backfill` died on the
            # first sharded log dir having recorded nothing at all. Driven: this is why backfilling
            # 2026-07-31 aborted before its first row. sed prints nothing and exits 0 on no match.
            pkg="$(sed -n 's/.*tonight.s package: //p' "$d/run.log" 2>/dev/null | head -1)"
            [ -n "$pkg" ] || pkg="repo"
            # The flag describes THE NIGHT, not this process: whether the backfill itself is a
            # rehearsal says nothing about a night that already happened. Read off that night's own
            # artifacts -- see dataset_night_was_dry, and why the hardcoded `false` this replaces
            # was wrong for the only complete night in the corpus.
            ns_jac dataset record-audit "$d" "$DATASET_DIR" "$date_only" "$pkg" "$CONFIG" "$dry" >/dev/null
            ns_log DATASET "backfilled audit findings for $date_only"
        fi

        [ -f "$d/green.tsv" ] || continue
        while IFS=$'\t' read -r branch theme report; do
            [ -n "$branch" ] || continue
            # RESOLVE THE COMMIT: fork first, LOCAL SECOND. A bare `fetch || continue` was the only
            # resolution this had, and it lost 100% of the refactor half of 2026-07-31 -- that night
            # was a rehearsal, ns_git_push was stubbed, so not one of its six green branches ever
            # reached the fork, while every commit sat in work/repo the whole time. A branch the
            # fork does not have is not a branch that does not exist.
            ref=""
            if git -C "$REPO" fetch origin "$branch" -q 2>/dev/null; then
                ref="origin/$branch"
                # ONLY a branch the fork actually has gets a fork URL. Composing
                # https://<fork>/tree/<branch> for a local-only ref would put a dead link in tracked
                # training data -- the identical false claim dataset_record_refactor nulls on the
                # live dry-run path, arriving here by the back door. Keyed on fork presence rather
                # than on `$dry` because those are different questions: a rehearsal branch promoted
                # by hand afterwards IS on the fork and does have a real URL.
                url="https://github.com/$NS_REPO_FORK/tree/$branch"
            elif git -C "$REPO" rev-parse --verify -q "refs/heads/$branch^{commit}" >/dev/null 2>&1; then
                ref="$branch"
                url=""
                ns_log DATASET "$branch: not on the fork, recovering from the local ref"
            else
                ns_log DATASET "skip $branch (on neither the fork nor work/repo)"
                continue
            fi
            pkg=""
            if [ "$theme" != "-" ] && [ -f "$theme" ]; then
                pkg="$(ns_jac parse_result field package < "$theme" 2>/dev/null)"
            fi
            # Same fallback, same reason, as lib/ship.sh:36-37 on the live path: themes have carried
            # no `package` key since the audit went whole-repo/sharded, so this read is normally
            # EMPTY. Without the fallback every backfilled refactor row gets package "" while the
            # live path and dataset_record_night both write "repo" -- silently splitting the join
            # key against nights.jsonl for the very night this function exists to recover.
            [ -n "$pkg" ] || pkg="repo"
            # `|| true` for the same errexit reason as the two reads above: without it a branch with
            # no common ancestor kills the whole sweep instead of reaching the guard on the next
            # line, which exists precisely to skip it.
            base_ref="$(git -C "$REPO" merge-base "$NS_REPO_DEFAULT_BRANCH" "$ref" 2>/dev/null || true)"
            [ -n "$base_ref" ] || { ns_log DATASET "skip $branch (no merge-base)"; continue; }
            read -r added removed < <(ns_diff_numstat "$REPO" "$base_ref...$ref")
            # The fallback must NOT assert a green gate. lib/ship.sh:41-50 already fixed exactly this
            # over-claim on the live path: this string goes verbatim into refactors.jsonl's `verify`
            # field, and the file is missing precisely when the gate summary could not be found, so
            # the bare literal "verified" asserted a passing gate on the strength of a file that was
            # not there. Empty counts as missing -- an empty tests-<slug>.txt is no more evidence
            # than an absent one.
            # `|| true` inside the substitution, not around the assignment: a missing file makes
            # cat exit 1, and under bin/nightshift.sh's live errexit that rc IS the assignment's --
            # the backfill would abort on the first branch with no gate summary instead of falling
            # back. (The old `|| echo "verified"` hid this by never failing; removing the false
            # claim without also neutralising the rc would have traded one bug for another.)
            tests_line="$(cat "$d/tests-$(basename "$branch").txt" 2>/dev/null || true)"
            [ -n "$tests_line" ] \
                || tests_line="gate result unavailable (tests-$(basename "$branch").txt missing)"
            [ -f "$report" ] || continue
            n=$(( n + $(ns_jac dataset record-refactor "$base_ref" "$ref" "$REPO" "$DATASET_DIR" \
                "$d" "$date_only" "$pkg" "$theme" "$report" "$added" "$removed" "$tests_line" "$url" "$dry") ))
        done < "$d/green.tsv"
    done
    ns_log DATASET "backfill done: $n refactor rows"
    wc -l "$DATASET_DIR"/*.jsonl 2>/dev/null
}
