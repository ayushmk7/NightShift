# Step 13 — S7 Morning loop: promote / discard / status

## Goal

`lib/promote.sh`: the three human commands. `promote <branch> [repo]` re-syncs,
rebases on fresh `main`, **re-runs the full S4 gate** (upstream may have moved
overnight — never open a stale PR), opens the PR via `gh pr create --body-file`
with the draft's body, renames the release-note fragment `0000 → <PR#>`, marks
ledger rows `shipped`, and deletes the draft — restoring the invariant that *a
draft file existing means "PR not yet opened."* `discard <branch> [reason]` buries
the branch and remembers why (`rejected` never resurfaces). `status` prints the
last run summary + ledger tallies + the pending-drafts queue. Implements
TechnicalPRD §7-S7. Dispatch wiring is already in `bin/nightshift.sh` (step 8).

## Prerequisites

Steps 5, 7, 12 (sync/verify functions are reused; drafts exist).

## Files created

```
~/nightshift/lib/promote.sh
```

## Full implementation

### `lib/promote.sh`

```bash
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

promote_main() {
    local branch=$1 target="${2:-$NS_REPO_UPSTREAM}"
    local draft title pkg fragment pr_url pr_num fp

    draft="$(find_draft "$branch")" || ns_die "$EX_BUG" "no draft found for $branch"
    title="$(ns_jac render_draft meta "$draft" | ns_jac parse_result field title)"
    pkg="$(ns_jac render_draft meta "$draft" | ns_jac parse_result field package)"

    # 1. re-sync + rebase + re-gate: upstream may have moved overnight (PRD 7 stage 7)
    sync_main
    cd "$REPO"
    git checkout "$branch"
    if ! git rebase "$NS_REPO_DEFAULT_BRANCH"; then
        git rebase --abort
        demote_branch "$branch" "rebase conflict at promote time"
        ns_die "$EX_SYNC" "rebase conflict — branch downgraded to failed_verify, no stale PR opened"
    fi
    local theme="-"
    [ -f "$LOG_DIR/theme-$(basename "$branch").json" ] && theme="$LOG_DIR/theme-$(basename "$branch").json"
    if ! verify_branch "$branch" "$theme"; then
        ns_die "$EX_ALLFAIL" "re-gate red at promote time — branch downgraded, no stale PR opened"
    fi
    git -C "$REPO" push --force-with-lease origin "refs/heads/$branch:refs/heads/$branch"  # rebase moved it

    # 2. open the PR with the draft body
    ns_jac render_draft body "$draft" > "$LOG_DIR/pr-body.md"
    pr_url="$("$NS_PATHS_GH" pr create --repo "$target" \
        --head "${NS_REPO_FORK%%/*}:$branch" \
        --title "$title" --body-file "$LOG_DIR/pr-body.md")"
    pr_num="${pr_url##*/}"
    ns_log S7 "opened $pr_url"

    # 3. rename the release-note fragment 0000 → <PR#> (the PR updates itself on push)
    fragment="$(ns_jac render_draft frag "$pkg")"
    if git -C "$REPO" ls-files --error-unmatch "$fragment" >/dev/null 2>&1; then
        git -C "$REPO" checkout "$branch"
        git -C "$REPO" mv "$fragment" "${fragment%0000.refactor.md}$pr_num.refactor.md"
        git -C "$REPO" commit -m "docs($pkg): release note fragment for #$pr_num"
        git -C "$REPO" push origin "refs/heads/$branch:refs/heads/$branch"
    fi

    # 4. ledger → shipped; the draft file disappears = "this PR is opened" (PRD 1)
    ns_jac ledger by-branch "$branch" "$LEDGER" | while IFS= read -r fp; do
        ns_jac ledger set-status "$fp" shipped "$LEDGER" "{\"pr_url\":\"$pr_url\"}" >/dev/null
    done
    git -C "$DRAFTS" rm "drafts/$(basename "$draft")"
    cp "$LEDGER" "$DRAFTS/ledger.jsonl"
    git -C "$DRAFTS" add -A
    git -C "$DRAFTS" commit -m "promote: $branch -> #$pr_num"
    git -C "$DRAFTS" push origin nightshift/drafts
    git -C "$REPO" checkout "$NS_REPO_DEFAULT_BRANCH"
}

discard_main() {
    local branch=$1 reason="${2:-discarded by owner}" draft fp reason_sane
    reason_sane="$(printf '%s' "$reason" | tr -d '"\\')"

    ns_jac ledger by-branch "$branch" "$LEDGER" | while IFS= read -r fp; do
        ns_jac ledger set-status "$fp" rejected "$LEDGER" "{\"reason\":\"$reason_sane\"}" >/dev/null
    done
    git -C "$REPO" push origin --delete "$branch" 2>/dev/null || true
    git -C "$REPO" branch -D "$branch" 2>/dev/null || true
    if draft="$(find_draft "$branch")"; then
        git -C "$DRAFTS" rm "drafts/$(basename "$draft")"
    fi
    cp "$LEDGER" "$DRAFTS/ledger.jsonl"
    git -C "$DRAFTS" add -A
    git -C "$DRAFTS" commit -m "discard: $branch ($reason_sane)"
    git -C "$DRAFTS" push origin nightshift/drafts
    ns_log S7 "discarded $branch — the finding will never resurface"
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
    echo "== pending drafts (PRs not yet opened) =="
    ls "$DRAFTS/drafts" 2>/dev/null | grep -v '^\.keep$' || echo "(none)"
}
```

## Commands

```bash
bash -n ~/nightshift/lib/promote.sh
```

## Acceptance criteria

- [ ] `nightshift.sh status` shows last night's summary, ledger tallies, and the
      drafts queue.
- [ ] **Fork-internal staging promote** (safe rehearsal):
      `nightshift.sh promote nightshift/<date>/<slug> <you>/jaseci` → PR opens on
      your own fork; fragment renamed to `<PR#>.refactor.md` in a follow-up commit
      visible in the PR; ledger rows `shipped` with `pr_url`; draft file gone from
      `nightshift/drafts`; `status` no longer lists it.
- [ ] `discard` on a drafted branch: remote + local branch deleted, draft gone,
      ledger `rejected` with the reason — and the same finding reported by a later
      audit is dropped by the selector (`ledger-rejected`).
- [ ] Rebase-conflict path: with upstream moved incompatibly, promote aborts the
      rebase, downgrades the branch to `failed_verify`, and does **not** open a PR.

## Verification procedure

Full morning rehearsal against the fork (never upstream until you're ready):

```bash
cd ~/nightshift
bin/nightshift.sh status
bin/nightshift.sh promote "nightshift/$(date +%F)/autofix" "$(gh api user -q .login)/jaseci"
gh pr list --repo "$(gh api user -q .login)/jaseci"
bin/nightshift.sh status          # draft gone, tally shows shipped
# then clean up the staging PR: gh pr close … --delete-branch
```

First real upstream promote: pick the smallest, most obviously-correct deletion
branch (PRD §14-Q6: the first PRs introduce themselves on merit alone — be extra
conservative).

## Notes & traps

- **Re-gate before PR is non-negotiable**: the branch was green at 03:00 against
  that `main`; promote re-verifies against the 08:00 `main`. A red re-gate
  downgrades to `failed_verify` — the finding retries on a future night against
  fresher code.
- The post-rebase push uses `--force-with-lease` — the *only* forced push in the
  system, safe because only Nightshift writes `nightshift/*` refs and the lease
  catches anything else.
- The draft is located by **frontmatter `branch` field**, not filename — filenames
  are for humans, frontmatter is for machines.
- Fragment rename happens on the already-open PR's branch, so the PR updates
  itself on push (the upstream release-notes CI check then passes with the real
  number).
- `promote` runs with your interactive `gh` auth; the nightly run never has PR
  scopes in play. The human is the only path to upstream — by construction, not
  policy.
