# shellcheck shell=bash
# lib/inventory.sh — S1.6 (spec section 9): keep the open PR set current, before any new work.
#
# Runs FIRST in the night, ahead of the reactive pass and tonight's own task, so the inventory
# converges rather than growing. Per PR: read its CI verdict, then fetch, rebase onto fresh main,
# re-run the local mirror, re-gate, push.
#
# Nothing here waits for CI. A PR opened last night has had ~24h, so this reads a finished result
# for one API call instead of blocking ~35min per PR. A PR opened TONIGHT gets its verdict
# tomorrow night, which is the same information one night later and costs nothing.
#
# The whole file runs with errexit LIVE (ns_stage invokes inventory_main as a plain command, and
# bin/nightshift.sh's `inventory` arm invokes it bare), so every nonzero that is a legitimate
# outcome rather than a bug is captured with `|| rc=$?` and answered with a `case`. In particular
# NO ONE PR MAY END THE NIGHT: S1.6 sits in front of every other stage, so a single unprocessable
# PR that aborted here would block all new work, every night, until a human noticed.

CI_BASELINE="$NS_ROOT/state/ci-baseline.json"

# One $LOG_DIR/pr-inventory.jsonl line, projected by Jac (bash never composes JSON).
#
# RECONCILIATION B3: the artifact is JSONL, not TSV. Plan 4's digest reads prs.jsonl AND
# pr-inventory.jsonl and its readers return [] for a file they cannot parse, so a wrong shape here
# renders an empty inventory section every night, forever, with no error -- "did not run scored as
# passed" in the one unattended channel this project has.
#
# Never fatal, always loud: a row that cannot be projected is a reporting loss, and losing the
# report must not also lose the maintenance.
inventory_row() {   # <number> <branch> <action> <note>
    local line rc=0
    line="$(ns_jac cigate inv "number=$1" "branch=$2" "action=$3" "note=$4" 2>&1)" || rc=$?
    case "$rc" in
        0) printf '%s\n' "$line" >> "$LOG_DIR/pr-inventory.jsonl" ;;
        *) ns_warn "could not project a pr-inventory.jsonl row for PR #$1 ($3): $line — the digest's PR inventory will not list it" ;;
    esac
}

# Tonight's "what actually passes on main" baseline (scripts/cigate.jac).
#
# NEVER fatal: a night that cannot reach the API should still do its work, and a missing baseline
# makes cigate return 2 -- "no gate" -- which is the safe direction. Same reason the baseline is
# overwritten unconditionally even when main is having a bad night: a THINNER passing set gates
# FEWER checks, so a bad baseline can only ever under-report, never invent a red.
inventory_record_baseline() {
    local cap="$LOG_DIR/ci-main-checks.json" n rc=0
    ns_gh api "repos/$NS_REPO_UPSTREAM/commits/$NS_REPO_DEFAULT_BRANCH/check-runs?per_page=100" \
        > "$cap" 2>> "$LOG_DIR/inventory.err" || rc=$?
    case "$rc" in
        0) : ;;
        *) ns_warn "could not read $NS_REPO_DEFAULT_BRANCH's check runs (gh rc=$rc) — no CI baseline tonight, so no PR will be CI-gated"
           return 0 ;;
    esac
    rc=0
    n="$(ns_jac cigate record "$cap" "$CI_BASELINE" 2>> "$LOG_DIR/inventory.err")" || rc=$?
    # The COUNT is validated, not just the exit code. `cigate record` printing something
    # non-numeric while exiting 0 would be reported as "N checks currently passing" with N empty --
    # a baseline line that reads like success and says nothing.
    case "$n" in
        ''|*[!0-9]*)
            ns_warn "cigate could not record a CI baseline from $(basename "$cap") (rc=$rc, got '$n') — the capture may be truncated; no PR will be CI-gated tonight"
            return 0 ;;
    esac
    ns_log S1.6 "CI baseline: $n checks currently passing on $NS_REPO_DEFAULT_BRANCH"
}

# The CI verdict for one open PR, judged against tonight's baseline.
#
# Reads the checks on the PR's OWN head commit, which is why it must run BEFORE the rebase in
# inventory_refresh: a rebase force-pushes and replaces the very commit whose checks are being
# read. Records a pr-inventory.jsonl row in every case, including the ones that are not a verdict
# at all -- "CI has not reported" and "no baseline" are different from "green", and the operator's
# only channel is the digest.
inventory_ci_verdict() {   # <num> <branch>
    local num=$1 branch=$2 sha cap gerr ran rc=0 detail
    sha="$(ns_gh pr view "$num" --repo "$NS_REPO_UPSTREAM" --json headRefOid \
             2>> "$LOG_DIR/inventory.err" | ns_jac parse_result field headRefOid)" || rc=$?
    case "$sha" in
        ''|*[!0-9a-f]*)
            ns_warn "PR #$num ($branch): could not read a head sha (rc=$rc, got '$sha') — no CI verdict"
            inventory_row "$num" "$branch" "ci-unknown" "no head sha"
            return 0 ;;
    esac
    cap="$LOG_DIR/ci-pr-$num.json"
    rc=0
    ns_gh api "repos/$NS_REPO_UPSTREAM/commits/$sha/check-runs?per_page=100" \
        > "$cap" 2>> "$LOG_DIR/inventory.err" || rc=$?
    case "$rc" in
        0) : ;;
        *) ns_warn "PR #$num ($branch): could not read its check runs (gh rc=$rc) — no CI verdict"
           inventory_row "$num" "$branch" "ci-unknown" "gh rc=$rc"
           return 0 ;;
    esac
    # A capture where nothing has COMPLETED has zero failures and zero passes -- indistinguishable
    # from a clean run to anything that counts failures. Assert the work happened before reading
    # meaning into it, exactly as assert_suite_ran does for the test suites.
    rc=0
    ran="$(ns_jac cigate ran "$cap" 2>> "$LOG_DIR/inventory.err")" || rc=$?
    case "$ran" in
        ''|*[!0-9]*)
            ns_warn "PR #$num ($branch): could not count completed checks (rc=$rc, got '$ran') — refusing to read the capture as green"
            inventory_row "$num" "$branch" "ci-unknown" "unreadable capture"
            return 0 ;;
        0)  ns_log S1.6 "PR #$num: CI has not reported yet ($sha)"
            inventory_row "$num" "$branch" "ci-pending" "0 checks completed on $sha"
            return 0 ;;
    esac
    # PER-PR stderr file, NOT the shared inventory.err: the red arm below greps this file for the
    # failing check names, and a shared one would attribute the FIRST red PR's failures to every
    # later PR in the same night.
    gerr="$LOG_DIR/ci-gate-$num.err"
    : > "$gerr"
    rc=0
    ns_jac cigate gate "$cap" "$CI_BASELINE" 2>> "$gerr" || rc=$?
    case "$rc" in
        0)  ns_log S1.6 "PR #$num: CI green vs baseline ($ran checks)"
            inventory_row "$num" "$branch" "ci-green" "$ran checks completed, none red vs $NS_REPO_DEFAULT_BRANCH" ;;
        2)  ns_log S1.6 "PR #$num: no usable CI baseline — not gated"
            inventory_row "$num" "$branch" "ci-nobaseline" "no usable CI baseline tonight" ;;
        *)  # RED vs baseline: a check that fails here and passes on main. Reported, not repaired
            # -- see this plan's "deliberately not built". Nothing is closed and no attempt
            # counter moves; a human decides. `|| true` on the pipeline because grep exits 1 when
            # cigate reported the red some other way, and under pipefail that would abort the
            # night on the one path whose whole job is to report.
            detail="$(grep '^NEW CI FAILURE: ' "$gerr" | tail -5 | sed 's/^NEW CI FAILURE: //' | tr '\n' ' ' || true)"
            ns_warn "PR #$num ($branch): CI RED vs main's baseline on: ${detail:-unknown}. The local mirror was green when this was opened, so this is worth reading before the next night re-pushes it."
            inventory_row "$num" "$branch" "ci-red" "${detail:-unknown}" ;;
    esac
}

# Replaced in Task 7 with fetch / hard-align to the remote / rebase / re-gate / push.
inventory_refresh() {   # <num> <branch>
    ns_log S1.6 "PR #$1 ($2): refresh not implemented yet"
}

# The S1.6 stage. Lists nightshift's open PRs upstream and processes each one.
#
# The LIST is materialized and its exit status checked before anything iterates it. `gh pr list`
# failing prints nothing, and "no open PRs" is a perfectly normal answer -- so an unchecked reader
# failure would silently report a converged, empty inventory on the night the token expired. This
# is the exact shape of six of the seven false greens this codebase has already shipped.
#
# Which is also why the EMPTY answer is logged with the number the query returned rather than as a
# bare "nothing to do": "asked, and there are none" and "never asked" have to be different lines in
# run.log, not the same one. bin/test-harness.sh section 17 drives both.
inventory_main() {
    : >> "$LOG_DIR/pr-inventory.jsonl"
    : >> "$LOG_DIR/inventory.err"
    inventory_record_baseline

    local raw rows total rc=0 n=0 num branch url title deadline
    raw="$(ns_gh pr list --repo "$NS_REPO_UPSTREAM" --author "@me" --state open \
              --limit 100 --json number,headRefName,url,title 2>> "$LOG_DIR/inventory.err")" || rc=$?
    case "$rc" in
        0) : ;;
        *) ns_warn "S1.6: could not list open PRs (gh rc=$rc) — the inventory did NOT run tonight. This is not the same as having none."
           return 0 ;;
    esac
    rc=0
    rows="$(printf '%s' "$raw" | ns_jac cigate prs "nightshift/" 2>> "$LOG_DIR/inventory.err")" || rc=$?
    case "$rc" in
        0) : ;;
        *) ns_warn "S1.6: could not project the PR list (rc=$rc) — the inventory did NOT run tonight. This is not the same as having none."
           return 0 ;;
    esac
    # POSITIVE evidence that the query happened, independent of the projection. An unreadable count
    # is not fatal (the projection above already succeeded) but it must not silently become "0".
    rc=0
    total="$(printf '%s' "$raw" | ns_jac parse_result len 2>> "$LOG_DIR/inventory.err")" || rc=$?
    case "$total" in ''|*[!0-9]*) total="unreadable(rc=$rc)" ;; esac
    case "$rows" in
        "") ns_log S1.6 "queried $NS_REPO_UPSTREAM: $total open PR(s) authored by this account, 0 under nightshift/ — the inventory ran and is empty"
            return 0 ;;
    esac

    # Bounded by the clock. Re-gating one PR costs what S4 costs, so an unbounded inventory can
    # consume the night and ship nothing new. Remaining PRs wait for the next night: the inventory
    # is designed to converge ACROSS nights, and the ones left behind are the ones that were
    # already waiting longest for CI anyway.
    deadline=$(( $(date +%s) + NS_BUDGETS_INVENTORY_MIN * 60 ))
    while IFS=$'\t' read -r num branch url title; do
        case "$num" in "") continue ;; esac
        if [ "$(date +%s)" -ge "$deadline" ]; then
            ns_warn "S1.6: ${NS_BUDGETS_INVENTORY_MIN}min inventory budget spent after $n PR(s); the rest wait for tomorrow night"
            break
        fi
        n=$((n + 1))
        ns_log S1.6 "PR #$num ($branch): $title"
        inventory_ci_verdict "$num" "$branch"
        inventory_refresh "$num" "$branch"
    done <<< "$rows"
    ns_log S1.6 "queried $NS_REPO_UPSTREAM: $total open PR(s) authored by this account, processed $n under nightshift/"
}
