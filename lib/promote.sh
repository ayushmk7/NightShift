# shellcheck shell=bash
# lib/promote.sh — S7 (TechnicalPRD 7-S7): the only path to upstream is this human-invoked command.

# find tonight-or-any-night's draft whose frontmatter names this branch
find_draft() {
    local branch=$1 f
    for f in "$DRAFTS"/drafts/*.md; do
        [ -e "$f" ] || continue
        if [ "$(ns_jac render_draft meta "$f" | ns_jac parse_result field branch)" = "$branch" ]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# The open PR number for a branch, or "" when there is none. Read-only, so it runs under dry-run
# too -- `discard` has to know whether there is a PR to close even during a rehearsal.
#
# Materialized and shape-checked rather than used inline: `gh pr list` failing (offline, auth
# expired) prints nothing and would otherwise be indistinguishable from "no PR exists", which is
# exactly the answer that makes discard skip the close and delete the branch anyway.
ns_pr_for_branch() {   # ns_pr_for_branch <branch> [repo]
    local branch=$1 repo="${2:-$NS_REPO_UPSTREAM}" raw rows rc=0 first
    raw="$(ns_gh pr list --repo "$repo" --head "$branch" --state open \
              --json number,headRefName,url,title)" || rc=$?
    case "$rc" in
        0) : ;;
        *) ns_die "$EX_BUG" "could not list PRs for $branch on $repo (gh rc=$rc). An empty result and a failed query look identical downstream, and the difference decides whether an open PR is left dangling." ;;
    esac
    rc=0
    rows="$(printf '%s' "$raw" | ns_jac cigate prs "nightshift/")" || rc=$?
    case "$rc" in
        0) : ;;
        *) ns_die "$EX_BUG" "could not project the PR list for $branch (cigate rc=$rc). Refusing to treat an unreadable answer as 'no PR'." ;;
    esac
    # First line, first field, by parameter expansion only: `| head -1 | cut -f1` under
    # `set -o pipefail` can report 141 (SIGPIPE) for a perfectly good answer, and this function's
    # whole point is that a failure must never look like "no PR".
    first="${rows%%$'\n'*}"
    printf '%s' "${first%%$'\t'*}"
}

promote_main() {
    local branch=$1 target="${2:-$NS_REPO_UPSTREAM}"
    local draft title fragment pr_url pr_num fp pr_rc=0

    # S5 opens PRs automatically now, so promote is the manual path for a branch whose PR could
    # not be opened (a dry-run night, a network failure, a permission change). Opening a SECOND
    # PR for the same branch would be pure noise upstream, and the ledger would record whichever
    # URL was written last. Checked FIRST, before sync/checkout/rebase/re-gate: the refusal does
    # not depend on any of that work, and the re-gate costs what S4 costs.
    local existing
    existing="$(ns_pr_for_branch "$branch" "$target")"
    case "$existing" in
        "") : ;;
        *)  ns_die "$EX_BUG" "$branch already has open PR #$existing on $target — S5 opened it. Nothing to promote. Use 'nightshift.sh discard $branch <reason>' to kill it, or review it on GitHub." ;;
    esac

    draft="$(find_draft "$branch")" || ns_die "$EX_BUG" "no draft found for $branch"
    title="$(ns_jac render_draft meta "$draft" | ns_jac parse_result field title)"

    # 1. re-sync + rebase + re-gate: upstream may have moved overnight (PRD 7 stage 7)
    sync_main
    cd "$REPO"
    git checkout "$branch"
    if ! git rebase "$NS_REPO_DEFAULT_BRANCH"; then
        git rebase --abort
        demote_branch "$branch" "rebase conflict at promote time"
        ns_die "$EX_SYNC" "rebase conflict — branch downgraded to failed_verify, no stale PR opened"
    fi

    # UNSTACK. The rebase above just moved this branch onto fresh main, so whatever it was stacked
    # on is no longer its parent: either those commits are in main now (the parent merged, which is
    # the case promote exists to service for a held child) or the rebase replayed over them.
    # Leaving the row behind would make the next re-gate measure this branch's diff from a ref that
    # is no longer an ancestor of it -- `parent...HEAD` would then report every main commit since
    # the fork point as this branch's own work, and the scope gate would reject it as an injection.
    # Removed AFTER the rebase succeeds and BEFORE verify_branch runs, which is the only window
    # where both statements are true.
    local pslug; pslug="$(basename "$branch")"
    if [ -f "$DRAFTS/stack/$pslug" ]; then
        ns_log S7 "$branch was stacked on $(cat "$DRAFTS/stack/$pslug"); rebased onto $NS_REPO_DEFAULT_BRANCH, clearing the stack record"
        rm -f "$DRAFTS/stack/$pslug"
    fi
    # Which theme (if any) verify_branch re-gates this branch against. The reasoning that used to
    # live here now lives at ns_theme_for_branch (lib/common.sh), which also looks on the drafts
    # branch -- so promoting on a different calendar day than the run no longer needs the
    # NS_DATE=<night> workaround this comment used to prescribe.
    local theme
    theme="$(ns_theme_for_branch "$branch")"
    if ! verify_branch "$branch" "$theme"; then
        ns_die "$EX_ALLFAIL" "re-gate red at promote time — branch downgraded, no stale PR opened"
    fi
    ns_git_push "$REPO" --force-with-lease origin "refs/heads/$branch:refs/heads/$branch"  # rebase moved it

    # 2. open the PR with the draft body. --draft, like S5: Nightshift never opens a
    # ready-for-review PR and ns_gh_write refuses `pr ready`, so promote must not be the one path
    # that quietly bypasses spec section 6.
    ns_jac render_draft body "$draft" > "$LOG_DIR/pr-body.md"
    pr_url="$(ns_gh_write pr create --repo "$target" --draft \
        --base "$NS_REPO_DEFAULT_BRANCH" --head "${NS_REPO_FORK%%/*}:$branch" \
        --title "$title" --body-file "$LOG_DIR/pr-body.md")" || pr_rc=$?
    # Same positive assertion ship_open_pr makes, for the same reason: `gh pr create` exiting 0
    # having printed nothing would otherwise write an empty pr_url into the ledger as a shipped PR.
    case "$pr_rc:$pr_url" in
        0:https://github.com/*/pull/[0-9]*) : ;;
        *)  ns_die "$EX_BUG" "gh pr create returned no PR URL (rc=$pr_rc, got '$pr_url') — nothing was promoted, the branch is still pushed and the draft still exists" ;;
    esac
    pr_num="${pr_url##*/}"
    ns_log S7 "opened $pr_url"

    # 3. rename the release-note fragment 0000 → <PR#> (the PR updates itself on push)
    #
    # The hardcoded `%0000.refactor.md` suffix strip that used to live here was a LIVE bug, not a
    # latent one: it made the rename a silent no-op for the other four kinds, so the fragment
    # shipped still named 0000 and CI's release-note check failed the PR --
    # [tasks.maintenance].fragment = "auto" means a non-refactor kind really is emitted now.
    # ns_renumber_fragment (lib/ship.sh) is kind-agnostic, handles the empty fragment
    # [tasks.coverage] produces, and pushes through ns_git_push so this path is dry-runnable.
    fragment="$(ns_jac render_draft meta "$draft" | ns_jac parse_result field release_note)"
    ns_renumber_fragment "$branch" "$pr_num" "$fragment"

    # 4. ledger → shipped; the draft file disappears = "this PR is opened" (PRD 1)
    ns_jac ledger by-branch "$branch" "$LEDGER" | while IFS= read -r fp; do
        ns_jac ledger set-status "$fp" shipped "$LEDGER" "{\"pr_url\":\"$pr_url\"}" >/dev/null
    done
    git -C "$DRAFTS" rm "drafts/$(basename "$draft")"
    cp "$LEDGER" "$DRAFTS/ledger.jsonl"
    git -C "$DRAFTS" add -A
    git -C "$DRAFTS" commit -m "promote: $branch -> #$pr_num"
    ns_git_push "$DRAFTS" origin nightshift/drafts
    git -C "$REPO" checkout "$NS_REPO_DEFAULT_BRANCH"

    dataset_record_review "$branch" true "promoted: $pr_url"
}

discard_main() {
    local branch=$1 reason="${2:-discarded by owner}" draft fp reason_sane pr_num
    reason_sane="$(printf '%s' "$reason" | tr -d '"\\')"

    # Close the PR BEFORE deleting the branch. Deleting the head branch of an open PR does close
    # it on GitHub, but leaves no explanation on someone else's repo -- and if the close fails we
    # need to find out while the branch still exists to retry against. ns_pr_for_branch ns_dies
    # rather than answering "" when the query itself fails, so a dead token can never route us
    # into the "no PR to close" arm and then delete the branch anyway.
    # Anything stacked on this branch is about to lose its base. Refused rather than warned: the
    # child's tree contains this branch's commits, so a `promote` on it afterwards would rebase
    # those onto main and open a PR carrying the very diff that was just discarded, under a
    # different theme's name. Discard the children first (or promote them, if the work is fine and
    # only this parent was wrong) and the order sorts itself out.
    local kids=""
    if [ -d "$DRAFTS/stack" ]; then
        kids="$(grep -lxF "$branch" "$DRAFTS/stack/"* 2>/dev/null | while IFS= read -r k; do basename "$k"; done | tr '\n' ' ')"
    fi
    case "$kids" in
        "") : ;;
        *)  ns_die "$EX_BUG" "$branch is the base of stacked branch(es): $kids. Discarding it would leave them carrying its discarded commits with no base, and a later promote would ship that diff under their name. Discard or promote the children first." ;;
    esac

    pr_num="$(ns_pr_for_branch "$branch")"
    case "$pr_num" in
        "") ns_log S7 "no open PR for $branch — nothing to close upstream" ;;
        *)  ns_gh_write pr close "$pr_num" --repo "$NS_REPO_UPSTREAM" \
                --comment "Closing: this automated cleanup was discarded by its operator ($reason_sane). No action needed." \
                || ns_die "$EX_BUG" "could not close PR #$pr_num for $branch — refusing to delete the branch and leave a dangling open PR upstream. Close it by hand, then re-run discard."
            ns_log S7 "closed PR #$pr_num" ;;
    esac

    ns_jac ledger by-branch "$branch" "$LEDGER" | while IFS= read -r fp; do
        ns_jac ledger set-status "$fp" rejected "$LEDGER" "{\"reason\":\"$reason_sane\"}" >/dev/null
    done
    # `|| true`: the remote branch may already be gone (a previous discard, an upstream prune).
    # NOT `2>/dev/null`: that swallowed ns_git_push's own [DRY] line, so a rehearsal looked like it
    # never tried to delete anything (observed while writing this).
    ns_git_push "$REPO" origin --delete "$branch" || true
    git -C "$REPO" branch -D "$branch" 2>/dev/null || true
    if draft="$(find_draft "$branch")"; then
        git -C "$DRAFTS" rm "drafts/$(basename "$draft")"
    fi
    cp "$LEDGER" "$DRAFTS/ledger.jsonl"
    git -C "$DRAFTS" add -A
    # `if !`, never a bare commit: discarding a branch that leaves the drafts tree unchanged (no
    # ledger rows and no draft file -- a branch discarded twice, or one that never shipped) makes
    # `git commit` exit 1. discard_main is invoked BARE from bin/nightshift.sh with errexit live
    # and no EXIT trap, so that aborted the command with a bare status 1 AFTER the PR was closed
    # and the branch deleted, and BEFORE the log line and the dataset row. Found by rehearsal.
    if ! git -C "$DRAFTS" diff --cached --quiet; then
        git -C "$DRAFTS" commit -qm "discard: $branch ($reason_sane)"
        ns_git_push "$DRAFTS" origin nightshift/drafts
    fi
    ns_log S7 "discarded $branch — the finding will never resurface"

    dataset_record_review "$branch" false "$reason_sane"
}

demote_branch() {
    local branch=$1 why=$2 fp why_sane
    why_sane="$(printf '%s' "$why" | tr -d '"\\')"
    ns_jac ledger by-branch "$branch" "$LEDGER" | while IFS= read -r fp; do
        ns_jac ledger set-status "$fp" failed_verify "$LEDGER" "{\"reason\":\"$why_sane\"}" >/dev/null
    done
}

status_main() {
    echo "== last run summary =="
    local last
    last="$(ls -d "$NS_ROOT"/logs/20* 2>/dev/null | sort | tail -1)"
    [ -n "$last" ] && cat "$last/run-summary.json" 2>/dev/null | head -40 || echo "(no runs yet)"
    echo
    echo "== ledger tallies =="
    ns_jac ledger tally "$LEDGER"
    echo
    # NOT "PRs not yet opened" any more: since S5 opens the draft PR itself, a draft .md on disk
    # means "there is (or was meant to be) an open PR upstream and `discard` is how you kill it".
    # Only the ledger's pr_url says whether one exists.
    echo "== drafts on the drafts branch (one per shipped branch; discard removes them) =="
    ls "$DRAFTS/drafts" 2>/dev/null | grep -v '^\.keep$' || echo "(none)"
}
