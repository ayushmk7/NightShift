# shellcheck shell=bash
# lib/ship.sh — S5 (TechnicalPRD 7-S5): push green branches, render drafts, update the ledger.

ship_main() {
    [ -f "$LOG_DIR/green.tsv" ] || { ns_log S5 "nothing green to ship"; return 0; }
    local branch theme report
    while IFS=$'\t' read -r branch theme report; do
        ship_branch "$branch" "$theme" "$report"
    done < "$LOG_DIR/green.tsv"

    # publish drafts + ledger to the fork's orphan branch
    cp "$LEDGER" "$DRAFTS/ledger.jsonl"
    git -C "$DRAFTS" add -A
    if ! git -C "$DRAFTS" diff --cached --quiet; then
        git -C "$DRAFTS" commit -m "drafts: $NS_DATE"
        ns_git_push "$DRAFTS" origin nightshift/drafts
    fi
}

ship_branch() {
    local branch=$1 theme=$2 report=$3
    local slug pkg tests_line draft_path

    slug="$(basename "$branch")"
    if [ "$theme" != "-" ]; then
        # Themes carry no `package` key since the audit went whole-repo/sharded, so this is normally
        # empty now. Fall back to the same "repo" the tier-1 branch below uses: pkg reaches the draft
        # title AND dataset_record_refactor's row, where "" would sit inconsistently next to
        # nights.jsonl's "repo" and historical rows' real package names.
        pkg="$(ns_jac parse_result field package < "$theme")"
        [ -n "$pkg" ] || pkg="repo"
    else
        pkg="repo"          # tier-1 autofix touches whichever packages drifted
    fi
    tests_line="$(cat "$LOG_DIR/tests-$slug.txt" 2>/dev/null || echo "gates green (see logs)")"

    # explicit refspec, only nightshift/* refs, never force (threat T3)
    ns_git_push "$REPO" -u origin "refs/heads/$branch:refs/heads/$branch"

    # Real added/removed line counts from git itself, not the agent's self-reported loc_before/after
    # (which is a FILE line count, not a diff stat, and was off by a few lines on a real run: agent
    # said +11 net, actual diff was +90/-77). Overrides render()'s loc_before/loc_after args below --
    # same convention render_draft.jac's git_report() already uses for tier-1's own reports.
    local added removed
    read -r added removed < <(ns_diff_numstat "$REPO" "$NS_REPO_DEFAULT_BRANCH...$branch")

    draft_path="$DRAFTS/drafts/$NS_DATE--$slug.md"
    ns_jac render_draft render "$report" \
        "branch=$branch" "package=$pkg" "date=$NS_DATE" "tests=$tests_line" \
        "loc_before=$removed" "loc_after=$added" \
        > "$draft_path"

    # findings on this branch: drafted (autofix has no ledger rows — that's fine)
    local fp
    ns_jac ledger by-branch "$branch" "$LEDGER" | while IFS= read -r fp; do
        ns_jac ledger set-status "$fp" drafted "$LEDGER" >/dev/null
    done

    dataset_record_refactor "$branch" "$pkg" "$theme" "$report" "$added" "$removed" \
        "$tests_line" "https://github.com/$NS_REPO_FORK/tree/$branch"

    ns_log S5 "shipped $branch + draft $(basename "$draft_path")"
}
