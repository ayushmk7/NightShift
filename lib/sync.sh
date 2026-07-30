# shellcheck shell=bash
# lib/sync.sh — S1 (TechnicalPRD 7-S1): fast-forward fork, align worktrees, prune stale branches.

sync_main() {
    "$NS_PATHS_GH" repo sync "$NS_REPO_FORK" --source "$NS_REPO_UPSTREAM" --branch "$NS_REPO_DEFAULT_BRANCH" \
        || ns_die "$EX_SYNC" "fork sync failed (diverged main? fix manually)"

    git -C "$REPO" fetch origin --prune
    git -C "$REPO" checkout -B "$NS_REPO_DEFAULT_BRANCH" "origin/$NS_REPO_DEFAULT_BRANCH"

    # drafts worktree: permanently pinned to orphan branch nightshift/drafts
    if [ ! -d "$DRAFTS" ]; then
        drafts_bootstrap
    else
        git -C "$DRAFTS" pull --ff-only origin nightshift/drafts || true
    fi

    # prune shipped/rejected nightshift branches older than 14 days (ledger is the authority)
    local branch
    ns_jac ledger prunable 14 "$LEDGER" | while IFS= read -r branch; do
        if git -C "$REPO" ls-remote --exit-code origin "refs/heads/$branch" >/dev/null 2>&1; then
            ns_log S1 "pruning stale branch $branch"
            ns_git_push "$REPO" origin --delete "$branch"
        fi
    done

    # refresh the local ledger cache from the drafts branch (source of truth lives in the fork)
    [ -f "$DRAFTS/ledger.jsonl" ] && cp "$DRAFTS/ledger.jsonl" "$LEDGER"
    return 0
}

# First run only: create the orphan branch so fork main stays a pristine mirror (PRD 7 stage 5).
#
# The prune is NOT hygiene, it is the precondition. `git worktree add` REFUSES a path that is still
# registered even when the directory is gone -- "fatal: '../wt' is a missing but already registered
# worktree" -- and that is exactly the state work/repo is in right now: Plan 5's reset deleted
# work/drafts with `rm -rf` and left the registration behind (`git worktree list` shows it
# `prunable`). Reproduced on a scratch repo 2026-07-30: add, rm -rf, add again -> rc=128; prune
# first -> rc=0. Without this line the FIRST live S1 dies at `worktree add`, under errexit inside
# ns_stage, so no night reaches S1.6 (whose theme resolver looks in $DRAFTS/themes) or anything
# after it. Prune only removes registrations whose directory is already missing, so it is a no-op
# on a healthy tree.
drafts_bootstrap() {
    git -C "$REPO" worktree prune
    if git -C "$REPO" ls-remote --exit-code origin refs/heads/nightshift/drafts >/dev/null 2>&1; then
        git -C "$REPO" worktree add "$DRAFTS" nightshift/drafts
        return 0
    fi
    git -C "$REPO" worktree add --detach "$DRAFTS"
    git -C "$DRAFTS" checkout --orphan nightshift/drafts
    git -C "$DRAFTS" rm -rf . >/dev/null 2>&1 || true
    mkdir -p "$DRAFTS/drafts"
    : > "$DRAFTS/ledger.jsonl"
    touch "$DRAFTS/drafts/.keep"
    git -C "$DRAFTS" add -A
    git -C "$DRAFTS" commit -m "init nightshift drafts (orphan)"
    ns_git_push "$DRAFTS" -u origin nightshift/drafts
}
