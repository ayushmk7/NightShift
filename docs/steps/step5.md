# Step 5 — S1 Sync & worktrees

## Goal

`lib/sync.sh`: fast-forward the fork's `main` from upstream, hard-align the local
clone, maintain the **two-worktree** layout (`work/repo` on nightly branches,
`work/drafts` permanently pinned to the orphan branch `nightshift/drafts`), create
that orphan branch on first run, prune stale shipped/rejected branches (ledger is
the authority), and pull the ledger cache down from the fork. Implements
TechnicalPRD §7-S1 and the §3 architecture's worktree split.

## Prerequisites

Steps 2–4. `work/repo` clone exists (step 1).

## Files created

```
~/nightshift/lib/sync.sh
~/nightshift/work/drafts/           # appears on first run (orphan-branch worktree)
```

## Why an orphan branch (design, from PRD §7 stage 5)

Draft `.md` files must live *in the fork* (reviewable from a phone) but must never
contaminate a code branch's history or the pristine `main` mirror. An orphan branch
shares no history with `main`; a second worktree pinned to it lets S5 commit drafts
without ever switching `work/repo` off its work branch.

## Full implementation

### `lib/sync.sh`

```bash
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
drafts_bootstrap() {
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
```

## Commands

```bash
bash -n ~/nightshift/lib/sync.sh
```

## Acceptance criteria

- [ ] First run: `work/drafts/` exists, `git -C work/drafts branch --show-current`
      → `nightshift/drafts`, and the fork has the branch with `drafts/.keep` +
      empty `ledger.jsonl`.
- [ ] `git -C work/drafts log --oneline` shares **no** commits with `main`
      (`git merge-base` fails — orphan confirmed).
- [ ] Second run: idempotent (pull --ff-only, no new commits).
- [ ] `work/repo` is on `main`, byte-identical to `origin/main`
      (`git status --porcelain` empty, `git rev-parse main origin/main` equal).
- [ ] A ledger row with status `shipped`, a `branch`, and `last_seen` 15+ days ago
      causes exactly that remote branch to be deleted on the next run.

## Verification procedure

```bash
cd ~/nightshift
export NS_ROOT="$PWD"; . lib/common.sh; ns_load_config
. lib/sync.sh
mkdir -p "$LOG_DIR"
sync_main
git -C work/drafts branch --show-current              # nightshift/drafts
git merge-base main nightshift/drafts 2>&1 || echo "orphan ✓"   # run inside work/repo
```

Prune test (safe, uses a throwaway branch):

```bash
git -C work/repo push origin main:refs/heads/nightshift/prune-test
FP=$(jac run scripts/ledger.jac fingerprint prune test x)
echo "{\"fingerprint\":\"$FP\",\"package\":\"jac\",\"file\":\"x\",\"rule\":\"dead-code\",\"summary\":\"s\",\"branch\":\"nightshift/prune-test\",\"status\":\"shipped\"}" \
  | jac run scripts/ledger.jac upsert state/ledger.jsonl.cache
# backdate last_seen to 20 days ago by editing the JSONL line, then:
sync_main    # the branch disappears from the fork
```

## Notes & traps

- `gh repo sync` only fast-forwards. If the fork's `main` ever diverges (someone
  committed to it directly), the stage exits 44 and the email tells you to fix it
  by hand — the harness must never rewrite `main` (threat T3).
- Pruning consults **the ledger**, not just branch age: an unpromoted `drafted`
  branch is never pruned no matter how old — the draft file existing means "PR not
  yet opened" and the queue must not rot out from under you.
- The ledger cache copy direction matters: S1 pulls fork→local; only S5/S7 push
  local→fork. If both happened in S1 you'd clobber overnight promote/discard edits.
- All pushes go through `ns_git_push` — the dry-run seam (step 14).
