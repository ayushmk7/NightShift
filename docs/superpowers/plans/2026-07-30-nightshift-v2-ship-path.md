# Nightshift v2 Plan 3: The ship path (draft PRs upstream + the inventory that keeps them current)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A green branch becomes a **draft PR on `jaseci-labs/jac`** the same night, and every open Nightshift PR is rebased, re-gated and CI-judged on every subsequent night, so the inventory converges instead of growing. Nothing merges. Nothing pushes to `main`.

**Architecture:** Four layers, bottom-up. First a **`gh` seam** in `lib/common.sh` that separates read-only calls (always run, even under `NS_DRY_RUN`) from mutating ones (stubbed by the seam), and refuses `pr merge` outright. Then **`scripts/cigate.jac`**, a baseline-diff CI gate built on one endpoint — `repos/<repo>/commits/<sha>/check-runs` — used for both sides, with `testgate.jac`'s exact `0/1/2` exit contract. Then **`lib/ship.sh`** grows PR opening: push → `gh pr create --draft` → renumber the release-note fragment to the PR number → ledger `shipped`. Then **`lib/inventory.sh`**, a new S1.6 stage that runs *before* any new work: list nightshift's open PRs, read each one's CI verdict against tonight's baseline, then fetch/rebase/re-gate/push.

The draft `.md` files and the `promote` / `discard` CLI stay as a parallel kill path — `discard` now also closes the PR it is killing.

**Tech Stack:** bash 3.2.57 (macOS stock), Jac 0.16.1 for every data transformation, `gh` 2.93.0 (verified on this host), the target repo's dev-built `jac` for repo gates.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-30-nightshift-4task-design.md`, sections 6, 8, 9, 12. Carry-forward: `docs/superpowers/specs/2026-07-30-nightshift-followups.md` section 4. Every fact in spec section 2 was verified on 2026-07-30 — do not re-derive it, and do not assume anything it contradicts.
- **No Python files.** bash sequences processes; Jac owns every data and logic transformation. That includes JSON projection: pipe `gh --json` output into a Jac script, never into `--jq` or `--template`.
- **bash is 3.2.57.** No `wait -n`, no associative arrays, no `${var^^}`. Under `set -u` an EMPTY array aborts on `${#arr[@]}` and `"${arr[@]}"` — use a space-joined string and a counter.
- **A guard must not return nonzero on its success path.** Use `case`, never `[ x ] && y`. `[ -f x ] && y=1` is survivable mid-sequence but aborts an errexit caller when it is a function's or script's last statement. `bin/nightshift.sh` runs `set -euo pipefail`; `promote_main`, `discard_main` and the new `inventory_main` are all invoked **bare** from its `case`, so errexit is live in them and `ns_run_inner`'s EXIT trap does not exist on the `promote`/`discard`/`inventory` paths.
- **Two jac binaries, never mixed.** `$NS_PATHS_JAC` runs the harness's own `scripts/*.jac`; `$NS_PATHS_JAC_REPO` is the target repo's dev binary for every repo-facing gate.
- **Jac type-narrowing is mandatory.** Nested subscripts on `json.loads` output fail `jac check` with E1001/E1053. Use `nslib`'s `as_dict` / `as_list` / `as_int` at every boundary. Every new Jac helper gets `test` blocks in the same file and is registered in `bin/test-harness.sh` section 1.
- **Everything that touches the network goes through a seam.** `git push` already does (`ns_git_push`). This plan adds `ns_gh` / `ns_gh_write` for `gh`. `nightshift.sh dry-run` must never open, edit or close a real PR.
- `bin/test-harness.sh` must print `ALL HARNESS TESTS PASSED` at every commit in this plan.
- `work/`, `state/`, `logs/` are gitignored and nothing under them is tracked (`git ls-files state/` is empty) — edits there are plain file edits, never `git rm`.

### Verified facts this plan rests on

- Upstream is **`jaseci-labs/jac`**, permissions `{admin:false, push:false, pull:true}`. No webhook is possible. The fork `ayushmk7/jaseci` is `admin:true`.
- **A draft PR runs full CI.** `ci.yml` triggers on `pull_request: [opened, synchronize, reopened, labeled]` with **no draft guard in any job**. That is the mechanism for "goes through CI without merging". Pushing to a fork branch does *not* trigger it (`push: branches:[main]` only).
- **Fork CI is unusable as a gate.** 13 of ~16 jobs are `runs-on: blacksmith-4vcpu-ubuntu-2404` and queue forever on a fork (one observed stuck 2h). `config/ci-mirror.toml` + `lib/cimirror.sh` exist because of this and are the real pre-PR gate.
- **Upstream CI is frequently red on `main`.** Five consecutive non-passes observed, and re-confirmed while writing this plan: `repos/jaseci-labs/jac/commits/main/check-runs` shows `jac-check` at `conclusion: failure` on main's own head commit. A gate must be **baseline-diff**, never all-green.
- CI wall time ≈ 35 min per run.
- `jac-check` runs a `jac fmt` autofix bot that pushes to PR branches, but **only same-repo** (`head.repo.full_name == github.repository`). A fork PR gets no autofix and hard-fails instead — which is why the local mirror must be green *before* the PR is opened.
- `lib/promote.sh:88` renames only `*0000.refactor.md`, so the PR-number rename silently no-ops for the other four fragment kinds. This plan replaces it with a kind-agnostic helper.
- **Measured while writing this plan:** `repos/jaseci-labs/jac/commits/main/check-runs` returns `total_count: 30` — exactly the endpoint's default page size. `?per_page=100` is mandatory, and a truncated capture must be refused, not silently under-gated.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `lib/common.sh` | shared plumbing | Modify: add `ns_gh`, `ns_gh_write`, `ns_theme_for_branch`; harden `ns_git_push` |
| `scripts/cigate.jac` | CI baseline-diff + PR-list projection | **Create** |
| `lib/ship.sh` | S5 push + draft + PR | Modify: open the draft PR, renumber the fragment, persist the theme |
| `lib/promote.sh` | S7 human kill path | Modify: `discard` closes the PR; `promote` refuses a duplicate; shared fragment renumber |
| `lib/inventory.sh` | S1.6 PR inventory maintenance | **Create** |
| `lib/verify.sh` | S4 gate | Modify: `verify_branch` gains an `on_red` mode so a re-gate cannot burn attempt counters |
| `bin/nightshift.sh` | entry point | Modify: source `inventory.sh`, add the S1.6 stage and an `inventory` command |
| `bin/test-harness.sh` | CI of the harness | Modify: sections 11-13 |
| `config/nightshift.toml` | every knob | Modify: `[budgets].inventory_min` (and `[repo].pr_target` **only if** Task 1's probe fails) |

---

### Task 1: Verify what `gh` can actually do upstream, before anything is built on it

Everything downstream rests on one unverified assumption: that `gh pr create` works against `jaseci-labs/jac` from a fork with **pull-only** permission. It is expected to (a public repo accepts PRs from anyone), but "expected to" is how this codebase acquired seven false greens. Three separate permissions matter and only one of them is the obvious one:

1. **create a draft PR** upstream from `ayushmk7:<branch>` — the whole plan.
2. **add a label** to that PR — the spec's "label the PR and report it" step. Labelling requires *triage* permission; a PR author with pull-only almost certainly **cannot**. If it cannot, the plan does not build labelling at all.
3. **close your own PR** — required by Task 5's `discard`.

Also unverified: that `ayushmk7/jaseci` is still recognised as a fork of `jaseci-labs/jac` after the upstream **rename**, which is what makes `--head ayushmk7:<branch>` resolvable.

`gh` 2.93.0 on this host has `gh pr create --dry-run` ("Print details instead of creating the PR"), which resolves head/base **without creating anything** — so the noisy step is only reached if the quiet one passes.

**Files:** none yet. This task produces evidence and one commit that records it.

**Interfaces:**
- Produces: `docs/superpowers/specs/2026-07-30-nightshift-followups.md` gains a short "Plan 3 probe results" subsection under section 4 recording the three answers with the commands that produced them. Evidence lives in git, not in a scratch workspace.

- [ ] **Step 1: Confirm the fork relationship survived the upstream rename**

```bash
/opt/homebrew/bin/gh repo view ayushmk7/jaseci --json parent,isFork
```

Expected: `"isFork": true` and `parent` naming `jaseci-labs/jac` (post-rename) or `jaseci-labs/jaseci` (if GitHub reports the old name, the relationship still holds — the redirect is what matters). If `isFork` is false, stop: `--head ayushmk7:<branch>` cannot work and the whole plan needs re-planning around a same-repo branch on the fork.

- [ ] **Step 2: Build the smallest defensible probe branch**

A PR needs a diff. Use one real, trivially reviewable change — do not invent a file, and do not touch anything the harness audits.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo
git fetch origin && git checkout -B nightshift/probe-pr-permissions origin/main
grep -rn "recieve\|seperate\|occured\|paramter" --include=*.jac --include=*.md jac/jaclang | head -5
```

Pick one hit, fix the typo, and commit. If there is no hit, add a single missing article or article-level clarity fix to one comment. Keep the diff to one line.

```bash
git commit -aqm "docs: fix a comment typo" && git log --oneline -1
```

- [ ] **Step 3: Probe `pr create` WITHOUT creating anything**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo
git push -u origin refs/heads/nightshift/probe-pr-permissions:refs/heads/nightshift/probe-pr-permissions
/opt/homebrew/bin/gh pr create --dry-run --repo jaseci-labs/jac --draft \
    --base main --head ayushmk7:nightshift/probe-pr-permissions \
    --title "[nightshift probe] please ignore: verifying automation permissions" \
    --body "Automated permission probe. Will be closed within minutes."
echo "exit=$?"
```

Expected: a printout of the PR that *would* be created, exit 0. A nonzero exit here names the real obstacle (head not resolvable, base branch wrong, auth scope) before a single line of `lib/ship.sh` is written.

- [ ] **Step 4: Open the real draft PR and read back what GitHub says it is**

`--dry-run` does not exercise permission. This does.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo
PR_URL="$(/opt/homebrew/bin/gh pr create --repo jaseci-labs/jac --draft \
    --base main --head ayushmk7:nightshift/probe-pr-permissions \
    --title "[nightshift probe] please ignore: verifying automation permissions" \
    --body "Automated permission probe for an unattended janitorial bot. Closing immediately.")"
echo "url=$PR_URL"
PR_NUM="${PR_URL##*/}"
/opt/homebrew/bin/gh pr view "$PR_NUM" --repo jaseci-labs/jac --json isDraft,state,headRefName,author
```

Expected: a URL, `"isDraft": true`, `"state": "OPEN"`. **A blank `$PR_URL` with exit 0 is the failure mode this whole plan is written against** — check the value, not the exit code.

- [ ] **Step 5: Probe labelling, which is the one likely to be refused**

```bash
/opt/homebrew/bin/gh pr edit "$PR_NUM" --repo jaseci-labs/jac --add-label "bug"; echo "label exit=$?"
```

Expected: **failure** (HTTP 403 / "Resource not accessible by integration" or a label-not-found error). Record whichever it is. If it fails, Task 6 records the CI verdict **locally only** and the digest is the operator's channel — no upstream mutation. If it unexpectedly succeeds, still do not use it: `ci.yml` triggers on `labeled`, so labelling a PR re-fires a 35-minute CI run for a cosmetic marker. Record that reasoning.

- [ ] **Step 6: Probe closing your own PR, then clean up**

```bash
/opt/homebrew/bin/gh pr close "$PR_NUM" --repo jaseci-labs/jac \
    --comment "Automated permission probe, closing as planned. Sorry for the noise."
echo "close exit=$?"
/opt/homebrew/bin/gh pr view "$PR_NUM" --repo jaseci-labs/jac --json state
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo \
  && git push origin --delete nightshift/probe-pr-permissions \
  && git checkout main && git branch -D nightshift/probe-pr-permissions
```

Expected: `"state": "CLOSED"`. If closing fails, Task 5's `discard` cannot close a PR and must instead delete the branch (GitHub auto-closes a PR whose head branch is deleted) — record that.

- [ ] **Step 7: Confirm a fork draft PR really does fire CI, from the run list**

Do this before closing, or immediately after using the recorded head sha. Do **not** wait 35 minutes for completion — check runs appear within a minute of the PR opening and their *names* are all that is needed.

```bash
HEAD_SHA="$(cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo && git rev-parse origin/nightshift/probe-pr-permissions)"
/opt/homebrew/bin/gh api "repos/jaseci-labs/jac/commits/$HEAD_SHA/check-runs?per_page=100" \
  | head -c 400
```

Expected: a `check_runs` array with names like `jac-check`, `build-jac`, `Contribution Checks`. Zero check runs means the "a draft PR runs full CI" premise is wrong for a *fork* PR, and Task 3's gate has nothing to gate — record it loudly.

- [ ] **Step 8: Record the answers where the next reader will find them**

Append a subsection to `docs/superpowers/specs/2026-07-30-nightshift-followups.md`, at the end of section 4:

```markdown
### 4.1 Plan 3 probe results (2026-07-__)

Measured, not assumed, before any of the ship path was built. Commands are in the commit that
added this section.

| Capability | Result | Consequence |
|---|---|---|
| `gh pr create --draft --repo jaseci-labs/jac --head ayushmk7:<branch>` | ___ | ___ |
| `gh pr edit --add-label` on our own PR | ___ | ___ |
| `gh pr close` on our own PR | ___ | ___ |
| check runs created on a fork draft PR | ___ | ___ |
```

- [ ] **Step 9: If — and only if — `pr create` was refused, add the fallback knob**

Skip this step when Step 4 succeeded. A fallback for a branch that has been *measured* not to happen is exactly the speculative abstraction this project's ladder forbids.

If it was refused, add to `config/nightshift.toml` under `[repo]`:

```toml
# MEASURED 2026-07-__: `gh pr create` against [repo].upstream was refused with pull-only
# permission (see docs/superpowers/specs/2026-07-30-nightshift-followups.md 4.1). PRs therefore
# target the FORK's own main and the digest says so. Flip back to "upstream" the day the
# permission changes; lib/ship.sh reads this and nothing else branches on it.
pr_target = "fork"
```

and have Task 4's `ship_open_pr` resolve its `--repo` from it. Every later task's `--repo "$NS_REPO_UPSTREAM"` becomes `--repo "$(ship_pr_repo)"`.

- [ ] **Step 10: Commit the evidence**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add docs/superpowers/specs/2026-07-30-nightshift-followups.md
git commit -m "Record what gh can actually do against jaseci-labs/jac

Probed with a real throwaway draft PR (opened, inspected, closed, branch deleted)
rather than inferred from the repo's permissions block, because the whole ship
path rests on the answer. Records three separate capabilities -- create a draft
PR from the fork, label it, close it -- since they need different permission
levels and only the first is the obvious one."
```

---

### Task 2: The `gh` seam — read-only always runs, mutating goes through dry-run, merging is refused

`ns_git_push` already gives `git push` a dry-run seam. `gh` has none: `lib/promote.sh:69` calls `"$NS_PATHS_GH" pr create` directly, which was safe only because `promote` is human-invoked. From Task 4 onward the *nightly* path opens PRs, so it needs the same seam — with one asymmetry: **read-only `gh` calls must run for real even under `NS_DRY_RUN`**, or a dry-run inventory tests nothing.

That asymmetry is the risk. Two functions, and each refuses what belongs to the other.

**Files:**
- Modify: `lib/common.sh` (after `ns_git_push`, ~line 167)
- Modify: `bin/test-harness.sh` (new section 11)

**Interfaces:**
- Produces: `ns_gh <args...>` — read-only `gh`. Runs unconditionally, `NS_DRY_RUN` or not. `ns_die`s (`EX_BUG`) on any call it does not recognise as read-only.
- Produces: `ns_gh_write <args...>` — mutating `gh`. Under `NS_DRY_RUN` it logs and returns 0, emitting `https://github.com/DRY-RUN/pull/0` for `pr create` so the caller's URL-shape assertion still exercises. `ns_die`s on `pr merge` and `pr ready`.
- Modifies: `ns_git_push` refuses a bare `--force` and refuses any push whose refspec targets `$NS_REPO_DEFAULT_BRANCH`.
- Consumed by: `lib/ship.sh` (Task 4), `lib/promote.sh` (Task 5), `lib/inventory.sh` (Tasks 6-7).

- [ ] **Step 1: Write the failing harness section first**

Append to `bin/test-harness.sh`, before the final `echo`:

```bash
echo "== 11. the gh seam: read-only always runs, writes are stubbed, merge is refused =="
# Two functions with opposite defaults share one binary, so each one's REFUSAL is what keeps the
# other honest: a mutating call routed through ns_gh would execute for real during a dry run, and
# a read-only call routed through ns_gh_write would return nothing during one. Driven behaviourally
# with $NS_PATHS_GH stubbed -- nothing here touches GitHub.
seam() {                   # seam <label> <want-rc> <dry?> <fn> <args...>
    local label=$1 want=$2 dry=$3 fn=$4; shift 4
    local got=0 out
    out="$(
        . "$NS_ROOT/lib/common.sh"
        LOG_DIR="$T"; NS_PATHS_GH="$T/fake-gh"; NS_REPO_DEFAULT_BRANCH=main
        if [ "$dry" = dry ]; then NS_DRY_RUN=1; fi
        "$fn" "$@"
    )" 2>/dev/null || got=$?
    case "$got" in
        "$want") : ;;
        *) fail "$fn '$label': expected rc=$want, got rc=$got" ;;
    esac
    seam_out="$out"
}
printf '#!/bin/sh\necho REAL-GH-RAN "$@"\n' > "$T/fake-gh"; chmod +x "$T/fake-gh"

# read-only calls run for real, dry-run or not -- an inventory that cannot list PRs tests nothing
seam "pr list live" 0 live ns_gh pr list --repo o/r --state open
case "$seam_out" in *REAL-GH-RAN*) : ;; *) fail "ns_gh did not invoke gh at all: '$seam_out'" ;; esac
seam "pr list dry"  0 dry  ns_gh pr list --repo o/r --state open
case "$seam_out" in *REAL-GH-RAN*) : ;; *) fail "ns_gh must still run under NS_DRY_RUN" ;; esac
# ...but a MUTATING call routed through the read-only seam is fatal, never silently executed
seam "write via ns_gh" 70 dry ns_gh pr create --repo o/r --draft
# `gh api` with an explicit method is a write however innocent the path looks
seam "api PATCH via ns_gh" 70 live ns_gh api "repos/o/r/pulls/1" -X PATCH -f state=closed
seam "api GET via ns_gh"    0 live ns_gh api "repos/o/r/commits/main/check-runs?per_page=100"

# writes are stubbed under dry-run and produce a shape-valid, obviously fake URL
seam "create dry" 0 dry ns_gh_write pr create --repo o/r --draft --title t --body b
case "$seam_out" in
    https://github.com/DRY-RUN/pull/0) : ;;
    *) fail "ns_gh_write pr create must emit a shape-valid sentinel URL under dry-run, got '$seam_out'" ;;
esac
case "$seam_out" in *REAL-GH-RAN*) fail "ns_gh_write invoked gh under NS_DRY_RUN" ;; esac
seam "create live" 0 live ns_gh_write pr create --repo o/r --draft
case "$seam_out" in *REAL-GH-RAN*) : ;; *) fail "ns_gh_write must invoke gh when not dry-running" ;; esac
# merging is refused in BOTH modes: a dry-run stub would let a merge call ship unnoticed
for mode in live dry; do
    seam "merge $mode" 70 "$mode" ns_gh_write pr merge 12 --repo o/r
    seam "ready $mode" 70 "$mode" ns_gh_write pr ready 12 --repo o/r
done

# ns_git_push: never main, never a bare --force
push_seam() {              # push_seam <label> <want-rc> <args...>
    local label=$1 want=$2; shift 2
    local got=0
    ( . "$NS_ROOT/lib/common.sh"; LOG_DIR="$T"; NS_DRY_RUN=1; NS_REPO_DEFAULT_BRANCH=main
      ns_git_push /nonexistent "$@" ) >/dev/null 2>&1 || got=$?
    case "$got" in
        "$want") : ;;
        *) fail "ns_git_push '$label': expected rc=$want, got rc=$got" ;;
    esac
}
push_seam "nightshift refspec"  0 origin "refs/heads/nightshift/a/b:refs/heads/nightshift/a/b"
push_seam "force-with-lease"    0 --force-with-lease origin "refs/heads/nightshift/a/b:refs/heads/nightshift/a/b"
push_seam "bare force"         70 --force origin "refs/heads/nightshift/a/b:refs/heads/nightshift/a/b"
push_seam "refspec onto main"  70 origin "refs/heads/nightshift/a/b:refs/heads/main"
push_seam "bare main"          70 origin main
echo "gh seam correct: reads live, writes stubbed, merge/ready/force/main all refused"
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
```

Expected: `FAIL: ns_gh 'pr list live': expected rc=0, got rc=127` — the functions do not exist.

- [ ] **Step 3: Add the two seam functions to `lib/common.sh`**

Insert directly after `ns_git_push`:

```bash
# --- gh seam ---------------------------------------------------------------------------------
# `gh` splits into two populations with OPPOSITE dry-run behavior, so it gets two functions rather
# than one with a flag. Read-only calls must run during a dry run (an inventory that cannot list
# PRs rehearses nothing); mutating calls must not (a dry run that opens a real upstream PR is the
# single worst outcome this seam exists to prevent). Each function refuses the other's population,
# because the failure of a one-function design is silent in exactly one direction.
#
# `case`, never `[ ... ] && ns_die`: these are called from promote_main / discard_main /
# inventory_main, which bin/nightshift.sh invokes BARE, so errexit is live and a false `&&` list
# would abort the command with a bare status 1, no [FATAL] line and no autopsy email.
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
```

- [ ] **Step 4: Harden `ns_git_push`**

Replace the body of `ns_git_push` with:

```bash
ns_git_push() {   # ns_git_push <dir> <push-args...>
    local dir=$1; shift
    # Two refusals, both cheap and both about damage that cannot be undone from here:
    #   * a bare --force (threat T3). --force-with-lease is explicitly allowed: S1.6 rebases open
    #     PR branches and cannot push the result without it.
    #   * anything targeting the default branch. Nightshift pushes nightshift/* refs and the
    #     nightshift/drafts orphan, never main -- on the fork or anywhere else.
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
```

- [ ] **Step 5: Run the harness — section 11 must pass and nothing else may regress**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
```

Expected: `ALL HARNESS TESTS PASSED`, including `gh seam correct: ...`.

- [ ] **Step 6: Mutate the seam and confirm the tests notice**

Reading a guard is not evidence. Three one-line mutations, each of which must turn the harness red:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
cp lib/common.sh /tmp/common.sh.bak
# (a) delete the `*)` refusal arm in ns_gh   -> "write via ns_gh" must fail
# (b) drop the `pr merge` arm                -> "merge live"/"merge dry" must fail
# (c) drop the `return 0` in the NS_DRY_RUN branch of ns_gh_write -> "create dry" must fail
#     (control falls through and gh runs for real)
# after each: bin/test-harness.sh ; expect FAIL ; then:
cp /tmp/common.sh.bak lib/common.sh && bin/test-harness.sh
```

Expected: each mutation produces a specific `FAIL:` naming the right assertion, and the restore returns `ALL HARNESS TESTS PASSED`. If any mutation stays green, the assertion is decorative — fix it before moving on.

- [ ] **Step 7: Commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add lib/common.sh bin/test-harness.sh
git commit -m "Give gh a dry-run seam, in two halves that refuse each other

Read-only gh calls must run during a dry run or an inventory rehearsal tests
nothing; mutating ones must not, or a rehearsal opens a real upstream PR. One
function with a flag hides that asymmetry, so there are two, and each ns_dies on
the other's population -- including 'gh api' with an explicit method, which is a
write behind a read-shaped path.

pr merge and pr ready are refused in BOTH modes: Nightshift never merges and
never takes a PR out of draft (spec 6), and a dry-run stub would let such a call
sit in the tree looking exercised. ns_git_push additionally refuses a bare
--force and any refspec targeting the default branch, while still allowing the
--force-with-lease that S1.6's rebase needs."
```

---

### Task 3: `scripts/cigate.jac` — CI baseline-diff with `testgate.jac`'s exit contract

Upstream CI is red on `main`, so "all checks green" would reject every PR for other people's breakage — measured again while writing this plan: `jac-check` is at `conclusion: failure` on main's own head commit. The gate records what **passes** on main and reds a PR only on a check that fails on the branch and passes on main.

Both sides come from **one endpoint**, `repos/<repo>/commits/<sha>/check-runs?per_page=100` — `main` for the baseline, the PR's `headRefOid` for a branch. That is wider than the spec's "main's latest `ci.yml` run": it returns every check on the commit (`ci.yml`'s jobs, `build / ...`, `prepare`, `microservice e2e`, any third-party app), which is what a PR is actually judged by, and it means one shape and one parser instead of two.

**The trap that has to be closed first:** main's head commit carried **exactly 30** check runs on 2026-07-30, and the endpoint's default page size is **30**. A caller that forgets `?per_page=100` gets a silently truncated list, which on the baseline side removes check names from the passing set and un-gates them permanently. That is "did not run" scoring as "nothing to gate", so the parser refuses a capture whose `total_count` disagrees with its payload.

**Files:**
- Create: `scripts/cigate.jac`
- Modify: `bin/test-harness.sh:13` (register `cigate` in the jac test sweep)

**Interfaces:**
- Produces: `jac run scripts/cigate.jac parse <checks.json>` — `name<TAB>status<TAB>conclusion`, sorted.
- Produces: `jac run scripts/cigate.jac ran <checks.json>` — how many check runs are `completed`. `0` means CI has not reported; never read that as green.
- Produces: `jac run scripts/cigate.jac record <checks.json> <baseline.json>` — writes the passing-on-main baseline, prints its size.
- Produces: `jac run scripts/cigate.jac gate <checks.json> <baseline.json>` — exit `0` no new failures, `1` new failures (names on stderr), `2` no baseline / nothing green on main to gate against.
- Produces: `jac run scripts/cigate.jac prs <prefix>` — stdin `gh pr list --json number,headRefName,url,title`; stdout one `number<TAB>branch<TAB>url<TAB>title` row per PR whose head starts with `<prefix>`.
- Consumed by: `lib/inventory.sh` (Tasks 6-7).

`prs` lives here rather than in a new file because it is the same subsystem's data (the PR set the gate is about) and this project's ladder says fewest files. It is not a formatting convenience: the `<prefix>` filter is a **safety invariant** — `--author @me` also matches a PR the operator opened by hand from some unrelated branch, and everything downstream of this projection rebases and force-pushes what it is handed.

- [ ] **Step 1: Write `scripts/cigate.jac` header, imports, and the tests — tests first**

Create the file with the docstring, imports, and the test blocks only, so the first run fails on missing functions rather than on a typo.

```jac
"""Baseline-diff CI gate (Nightshift S1.6, spec section 8).

Upstream CI is frequently RED on main -- five consecutive non-passing ci.yml runs measured
2026-07-30, and `jac-check` sitting at conclusion=failure on main's own head commit while this
was written. A plain "all checks green" gate would reject every Nightshift PR for other people's
breakage, so this records which checks PASS on main and calls a PR red only on a check that fails
on the branch and passes on main.

Both sides come from ONE endpoint and therefore one shape:
    gh api "repos/<repo>/commits/<sha>/check-runs?per_page=100"
with <sha> = main for the baseline and the PR's headRefOid for a branch. Deliberately wider than
the spec's "main's latest ci.yml run": the commit endpoint returns EVERY check on the commit --
ci.yml's jobs, the other workflows (`build / ...`, `prepare`, `microservice e2e`) and any
third-party app -- which is what a PR is actually judged by, with no second parser for a second
shape.

`gate`'s exit codes mirror scripts/testgate.jac EXACTLY: 0 no new failures, 1 new failures, 2 no
baseline (== no gate). lib/*.sh already encodes that 2 is not a red, and conflating 2 with "any
nonzero" once rejected a safe branch as broken.

argv:
  parse  <checks.json>                  print name<TAB>status<TAB>conclusion, sorted
  ran    <checks.json>                  print how many check runs have COMPLETED
  record <checks.json> <baseline.json>  write the passing-on-main baseline; print its size
  gate   <checks.json> <baseline.json>  exit 0 / 1 / 2 as above
  prs    <prefix>                       stdin: gh pr list --json number,headRefName,url,title
                                        stdout: number<TAB>branch<TAB>url<TAB>title per matching PR
"""
import sys;
import json;
import os;
import from nslib { eprint, read_stdin, parse_obj, parse_list, as_list, as_dict, today }
```

Then the tests (append at the end of the file):

```jac
"""A synthetic check-runs payload, in the endpoint's real shape."""
def _payload(triples: list[tuple[str, str, str]]) -> str {
    runs: list[dict] = [];
    for (name, status, concl) in triples {
        runs.append({"name": name, "status": status,
                     "conclusion": None if concl == "" else concl});
    }
    return json.dumps({"total_count": len(runs), "check_runs": runs});
}

test "a check red on the branch AND red on main is NOT a new failure" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    # main's real shape on 2026-07-30: jac-check failing, two jobs still in_progress
    main_p: str = d + "/main.json";
    with open(main_p, "w") as f {
        f.write(_payload([("jac-check", "completed", "failure"),
                          ("build-jac", "completed", "success"),
                          ("test-compiler", "in_progress", ""),
                          ("installer-test", "completed", "skipped")]));
    }
    base: str = d + "/ci.json";
    assert record(main_p, base) == 1;                 # only build-jac is known-good
    br: str = d + "/branch.json";
    with open(br, "w") as f {
        f.write(_payload([("jac-check", "completed", "failure"),
                          ("build-jac", "completed", "success")]));
    }
    (code, new_fails) = gate(br, base);
    assert code == 0 and new_fails == [];             # THE point of the whole file
    # ...but breaking a check that passes on main IS red
    bad: str = d + "/bad.json";
    with open(bad, "w") as f {
        f.write(_payload([("jac-check", "completed", "failure"),
                          ("build-jac", "completed", "failure")]));
    }
    (c2, n2) = gate(bad, base);
    assert c2 == 1 and n2 == ["build-jac"];
}

test "only `success` counts as passing on main; cancelled and in_progress do not" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    main_p: str = d + "/main.json";
    with open(main_p, "w") as f {
        # three of the last five ci.yml runs on main were CANCELLED -- a cancelled check says
        # nothing about the branch, so it must not become a baseline the branch can violate.
        f.write(_payload([("test-runtime", "completed", "cancelled"),
                          ("test-compiler", "in_progress", ""),
                          ("changes", "completed", "success")]));
    }
    base: str = d + "/ci.json";
    assert record(main_p, base) == 1;
    assert parse_obj(read_file(base))["passing"] == ["changes"];
    br: str = d + "/branch.json";
    with open(br, "w") as f {
        f.write(_payload([("test-runtime", "completed", "failure"),
                          ("test-compiler", "completed", "failure"),
                          ("changes", "completed", "success")]));
    }
    (code, new_fails) = gate(br, base);
    assert code == 0 and new_fails == [];
}

test "the branch side reds only on real failures, and a missing check gates nothing" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    main_p: str = d + "/main.json";
    with open(main_p, "w") as f {
        f.write(_payload([("a", "completed", "success"), ("b", "completed", "success"),
                          ("c", "completed", "success"), ("d", "completed", "success")]));
    }
    base: str = d + "/ci.json";
    assert record(main_p, base) == 4;
    br: str = d + "/branch.json";
    with open(br, "w") as f {
        # a: skipped by a path filter -- not red. b: cancelled -- not red. c: timed out -- RED.
        # d: absent entirely (CI's path filters legitimately drop jobs) -- not red.
        f.write(_payload([("a", "completed", "skipped"), ("b", "completed", "cancelled"),
                          ("c", "completed", "timed_out")]));
    }
    (code, new_fails) = gate(br, base);
    assert code == 1 and new_fails == ["c"];
}

test "no baseline, and an EMPTY baseline, both mean no gate -- never a red" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    br: str = d + "/branch.json";
    with open(br, "w") as f {
        f.write(_payload([("a", "completed", "failure")]));
    }
    (c1, _n1) = gate(br, d + "/nosuch.json");
    assert c1 == 2;
    # nothing green on main at all (a totally red night upstream) is "cannot gate", not "all red"
    empty: str = d + "/empty.json";
    with open(empty, "w") as f {
        f.write(json.dumps({"passing": [], "count": 0, "recorded": "2026-07-30"}));
    }
    (c2, _n2) = gate(br, empty);
    assert c2 == 2;
}

test "a capture CI has not finished is counted, not guessed at" {
    # `ran` is this file's assert_suite_ran: an all-queued capture has zero failures and zero
    # passes, which is indistinguishable from a clean run by any failure-counting logic. The
    # caller checks this BEFORE reading anything into the gate's answer.
    import tempfile;
    d: str = tempfile.mkdtemp();
    p: str = d + "/queued.json";
    with open(p, "w") as f {
        f.write(_payload([("a", "queued", ""), ("b", "in_progress", "")]));
    }
    assert completed_count(read_file(p)) == 0;
    assert failing_names(read_file(p)) == [];         # green-looking WITHOUT the ran check
    q: str = d + "/mixed.json";
    with open(q, "w") as f {
        f.write(_payload([("a", "completed", "success"), ("b", "in_progress", "")]));
    }
    assert completed_count(read_file(q)) == 1;
}

test "a truncated capture is refused, not silently under-gated" {
    # main's head commit carried EXACTLY 30 check runs on 2026-07-30 and the endpoint's default
    # page size is 30. Forget ?per_page=100 and the baseline silently loses names, which un-gates
    # those checks forever. total_count is the only signal that this happened.
    import tempfile;
    d: str = tempfile.mkdtemp();
    p: str = d + "/truncated.json";
    with open(p, "w") as f {
        f.write(json.dumps({"total_count": 30, "check_runs": [
            {"name": "a", "status": "completed", "conclusion": "success"}]}));
    }
    caught: bool = False;
    try {
        completed_count(read_file(p));
    } except ValueError as e {
        caught = True;
        assert "truncated" in str(e);
    }
    assert caught;
}

test "prs keeps only nightshift heads and survives a tab in a title" {
    raw: str = json.dumps([
        {"number": 1, "headRefName": "nightshift/2026-07-30/dead-cli", "url": "u1",
         "title": "refactor: a\tb"},
        {"number": 2, "headRefName": "my-manual-branch", "url": "u2", "title": "hand-written"},
        {"number": 3, "headRefName": "nightshift/2026-07-29/unused", "url": "u3", "title": "t3"},
    ]);
    rows: list[str] = pr_rows(raw, "nightshift/");
    assert len(rows) == 2;
    assert rows[0] == "1\tnightshift/2026-07-30/dead-cli\tu1\trefactor: a b";
    assert rows[1].startswith("3\t");
    # an empty PR list is a legitimate answer and must not raise
    assert pr_rows("[]", "nightshift/") == [];
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/cigate.jac
```

Expected: FAIL — `record`, `gate`, `completed_count`, `failing_names`, `pr_rows`, `read_file` are not defined.

- [ ] **Step 3: Implement the parser and the two name sets**

Insert between the imports and the tests:

```jac
"""A conclusion that means THIS BRANCH BROKE SOMETHING.

`cancelled`, `skipped`, `neutral` and `stale` are deliberately absent. Upstream cancels superseded
runs routinely (three of the last five ci.yml runs on main were cancelled), and a cancelled or
path-filtered check says nothing at all about the branch. Reading it as red would red every PR
whenever upstream force-pushes main."""
glob RED_CONCLUSIONS: list[str] = ["failure", "timed_out", "action_required"];

"""Parse a check-runs payload into (name, status, conclusion), asserting the capture is COMPLETE.

total_count vs len(check_runs) is not a formality: main's head commit carried exactly 30 check
runs on 2026-07-30 and this endpoint's default page size is 30, so a caller that forgets
?per_page=100 gets a silently truncated list. Truncation on the BASELINE side quietly removes
names from the passing set, which un-gates those checks forever -- a "did not run" scoring as
"nothing to gate". Refuse the capture instead of gating against half of it."""
def check_rows(raw: str) -> list[tuple[str, str, str]] {
    payload: dict = parse_obj(raw);
    runs: list = as_list(payload["check_runs"]);
    total: int = int(payload["total_count"]);
    if total != len(runs) {
        raise ValueError("check-runs capture is truncated: total_count=" + str(total)
                         + " but the payload carries " + str(len(runs))
                         + " runs. Re-fetch with ?per_page=100.");
    }
    rows: list[tuple[str, str, str]] = [];
    for item in runs {
        run: dict = as_dict(item);
        concl: any = run.get("conclusion");
        rows.append((str(run["name"]), str(run["status"]),
                     str(concl) if concl is not None else ""));
    }
    rows.sort();
    return rows;
}

"""How many check runs have finished. Zero means CI has not reported yet -- which produces zero
failures AND zero passes, i.e. it is indistinguishable from a clean run to anything that only
counts failures. The bash caller checks this before it reads meaning into `gate`'s answer, exactly
as lib/verify.sh's assert_suite_ran does for the test suites."""
def completed_count(raw: str) -> int {
    n: int = 0;
    for (_name, status, _concl) in check_rows(raw) {
        if status == "completed" {
            n += 1;
        }
    }
    return n;
}

"""Checks that are KNOWN GOOD on this commit. `success` only -- see RED_CONCLUSIONS for why the
asymmetry runs this way round: recording is strict (a name must have actually passed to become
gateable) and gating is strict too (only a real failure reds), so both edges fail towards
"cannot judge" rather than towards a false red on someone else's breakage."""
def passing_names(raw: str) -> list[str] {
    out: set[str] = set();
    for (name, status, concl) in check_rows(raw) {
        if status == "completed" and concl == "success" {
            out.add(name);
        }
    }
    return sorted(out);
}

def failing_names(raw: str) -> list[str] {
    out: set[str] = set();
    for (name, status, concl) in check_rows(raw) {
        if status == "completed" and concl in RED_CONCLUSIONS {
            out.add(name);
        }
    }
    return sorted(out);
}

def read_file(path: str) -> str {
    with open(path, "r") as f {
        return f.read();
    }
}

def record(raw_path: str, baseline_path: str) -> int {
    passing: list[str] = passing_names(read_file(raw_path));
    with open(baseline_path, "w") as f {
        f.write(json.dumps({"passing": passing, "count": len(passing),
                            "recorded": today()}, indent=2) + "\n");
    }
    return len(passing);
}

"""(code, new_failures). Code 2 covers BOTH "no baseline file" and "a baseline with nothing green
in it" -- a totally red night upstream is "cannot gate", never "everything is a new failure"."""
def gate(raw_path: str, baseline_path: str) -> (int, list[str]) {
    if not os.path.exists(baseline_path) {
        return (2, []);
    }
    baseline: dict = parse_obj(read_file(baseline_path));
    known_good: list[str] = [str(x) for x in as_list(baseline["passing"])];
    if not known_good {
        return (2, []);
    }
    new_fails: list[str] = [n for n in failing_names(read_file(raw_path)) if n in known_good];
    return (1 if new_fails else 0, new_fails);
}

"""Project `gh pr list --json number,headRefName,url,title` into TSV, keeping ONLY heads under
<prefix>.

The filter is a SAFETY INVARIANT, not a convenience. `gh pr list --author @me` also matches a PR
the operator opened by hand from an unrelated branch, and everything downstream of this projection
fetches, rebases and force-pushes what it is handed. Tabs in a title are replaced because the
consumer is a `while IFS=$'\\t' read` loop."""
def pr_rows(raw: str, prefix: str) -> list[str] {
    rows: list[str] = [];
    for item in parse_list(raw) {
        pr: dict = as_dict(item);
        head: str = str(pr["headRefName"]);
        if head.startswith(prefix) {
            rows.append("\t".join([str(pr["number"]), head, str(pr["url"]),
                                   str(pr["title"]).replace("\t", " ")]));
        }
    }
    return rows;
}
```

- [ ] **Step 4: Add the dispatch block**

`testgate.jac` shipped with `parse` documented but never dispatched, so it silently printed nothing for weeks. Write every documented verb into the dispatch, and give `prs` its own arity check.

```jac
with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "parse" and len(args) == 3 {
        for (name, status, concl) in check_rows(read_file(args[2])) {
            print(name + "\t" + status + "\t" + concl);
        }
    } elif cmd == "ran" and len(args) == 3 {
        print(completed_count(read_file(args[2])));
    } elif cmd == "record" and len(args) == 4 {
        print(record(args[2], args[3]));
    } elif cmd == "gate" and len(args) == 4 {
        (code, new_fails) = gate(args[2], args[3]);
        if code == 2 {
            eprint("cigate: no usable CI baseline (" + args[3] + ") -- not gating this PR");
        }
        for f in new_fails {
            eprint("NEW CI FAILURE: " + f);
        }
        sys.exit(code);
    } elif cmd == "prs" and len(args) == 3 {
        for row in pr_rows(read_stdin(), args[2]) {
            print(row);
        }
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run cigate.jac parse|ran <checks.json>");
        eprint("       jac run cigate.jac record <checks.json> <baseline.json>");
        eprint("       jac run cigate.jac gate   <checks.json> <baseline.json>");
        eprint("       jac run cigate.jac prs <branch-prefix>   (gh pr list --json ... on stdin)");
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac check scripts/cigate.jac && jac test scripts/cigate.jac
```

Expected: `jac check` clean (watch for E1001/E1053 on the `payload["check_runs"]` boundary — that is what `as_list`/`as_dict` are there for) and all seven tests passing.

- [ ] **Step 6: Drive it against the real endpoint, not just fixtures**

The fixtures are hand-written; the endpoint is not. One live read proves the parser matches reality.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
/opt/homebrew/bin/gh api "repos/jaseci-labs/jac/commits/main/check-runs?per_page=100" > /tmp/ci-main.json
jac run scripts/cigate.jac parse /tmp/ci-main.json | head -10
jac run scripts/cigate.jac ran /tmp/ci-main.json
jac run scripts/cigate.jac record /tmp/ci-main.json /tmp/ci-baseline.json
cat /tmp/ci-baseline.json | head -20
```

Expected: real names (`build-jac`, `jac-check`, `Contribution Checks`, `test-launcher (ubuntu-latest)`, matrix-suffixed `build / build (...)`), a completed count in the twenties, and a baseline whose `passing` list **excludes** `jac-check` while main is red on it. If `passing` contains every name, `record` is not filtering on `conclusion == "success"`.

- [ ] **Step 7: Prove the truncation guard on real data**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
/opt/homebrew/bin/gh api "repos/jaseci-labs/jac/commits/main/check-runs" > /tmp/ci-trunc.json
jac run scripts/cigate.jac ran /tmp/ci-trunc.json; echo "exit=$?"
```

Expected: a nonzero exit with `truncated` in the message *if* main currently has more than 30 checks. If `total_count` happens to be ≤ 30 today this passes cleanly — that is fine, the fixture test in Step 1 is the permanent guard; note the live result either way.

- [ ] **Step 8: Register `cigate` in the harness sweep and commit**

`bin/test-harness.sh:13`, append `cigate` to the list:

```bash
for f in nslib config ledger check_scope parse_result selector render_draft sendmail testgate checkgate dataset shards fragcheck cimirror cigate; do
```

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add scripts/cigate.jac bin/test-harness.sh
git commit -m "Add cigate.jac: CI baseline-diff with testgate's exit contract

Upstream CI is red on main -- jac-check sits at conclusion=failure on main's own
head commit right now -- so a PR can only be judged against what actually passes
there. Records the passing set from main's check runs and reds a PR only on a
check that fails on the branch and passes on main. Exit codes are testgate.jac's
0/1/2 because lib/*.sh already encodes that 2 is not a red.

Both sides read repos/<repo>/commits/<sha>/check-runs, which covers every check
a PR is judged by (other workflows and third-party apps included), not just
ci.yml, and needs only one parser.

The capture is refused when total_count disagrees with the payload: main carried
exactly 30 check runs and this endpoint's default page size is 30, so a missing
?per_page=100 would silently drop names out of the baseline and un-gate them."
```

---

### Task 4: S5 opens the draft PR

`ship_branch` already pushes the branch, renders the draft `.md`, and records the ledger and dataset rows. It gains three things: the PR itself, a kind-agnostic fragment renumber, and a copy of the theme on the drafts branch so any later night can re-gate this branch **with** scope containment.

That last one is not incidental. `$LOG_DIR` is date-keyed, so `promote` already dies on a tier-2 branch promoted on a different calendar day than its run — documented at length at `lib/promote.sh:38-61` and worked around by hand with `NS_DATE=<night> nightshift.sh promote`. S1.6 re-gates branches from *arbitrary* earlier nights, so it would hit that wall on every PR. Persisting the theme next to its draft deletes the workaround instead of reproducing it.

**Files:**
- Modify: `lib/ship.sh` (`ship_branch`, plus two new functions)
- Modify: `lib/common.sh` (add `ns_theme_for_branch`)
- Modify: `bin/test-harness.sh` (section 12)

**Interfaces:**
- Produces: `ship_open_pr <branch> <draft_path> <slug>` — opens the draft PR upstream, renumbers the fragment, marks the ledger rows `shipped` with `pr_url`, appends a row to `$LOG_DIR/prs.tsv`. Returns 1 (never dies) when the PR cannot be opened: the branch is pushed and the draft exists, so `promote` remains available.
- Produces: `ns_renumber_fragment <branch> <pr_num> <fragment_path>` in `lib/ship.sh` — renames `.../0000.<kind>.md` to `.../<pr>.<kind>.md`, commits and pushes. Kind-agnostic.
- Produces: `ns_theme_for_branch <branch>` in `lib/common.sh` — prints `-` for the tier-1 branch, the theme JSON path for a tier-2 branch, and `ns_die`s when a tier-2 branch has no theme anywhere.
- Produces: `$LOG_DIR/prs.tsv`, `number<TAB>branch<TAB>action<TAB>detail<TAB>url`. Plan 4's digest consumes it; until then `ns_warn` carries the bad rows into `warnings.txt`, which `sendmail.jac` already renders verbatim.
- Consumed by: `lib/promote.sh` (Task 5), `lib/inventory.sh` (Tasks 6-7).

- [ ] **Step 1: Add `ns_theme_for_branch` to `lib/common.sh`**

Directly under `ns_is_tier1_branch`:

```bash
# Which theme file re-gates this branch, for any night, not just tonight.
#
# Tier-1 legitimately has none (deterministic `jac fmt --lintfix`, no agent, nothing to scope) and
# is recognised POSITIVELY by slug. A tier-2 branch always had one -- but $LOG_DIR is DATE-KEYED,
# so it is simply not where a later night looks. Reading that absence as "no theme" hands
# verify_branch a theme of "-", which makes it SKIP scope containment (lib/verify.sh stage 1) --
# i.e. re-gate the one class of branch an LLM wrote with the anti-injection check switched off.
#
# So lib/ship.sh copies each theme to the drafts branch beside its draft .md, and this resolver
# looks in tonight's logs first and there second. Absence in both is fatal, never "-".
ns_theme_for_branch() {
    local branch=$1 slug
    slug="$(basename "$branch")"
    if ns_is_tier1_branch "$branch"; then
        echo "-"
        return 0
    fi
    if [ -f "$LOG_DIR/theme-$slug.json" ]; then
        echo "$LOG_DIR/theme-$slug.json"
        return 0
    fi
    if [ -f "$DRAFTS/themes/$slug.json" ]; then
        echo "$DRAFTS/themes/$slug.json"
        return 0
    fi
    ns_die "$EX_BUG" "no theme file for the agent-written branch $branch (looked in $LOG_DIR/theme-$slug.json and $DRAFTS/themes/$slug.json). Re-gating it with theme '-' would skip verify_branch's scope-containment/anti-injection check -- refusing."
}
```

- [ ] **Step 2: Persist the theme beside the draft, in `ship_branch`**

In `lib/ship.sh`, immediately after the `ns_jac render_draft render ... > "$draft_path"` block:

```bash
    # Copy the theme next to its draft so ANY later night can re-gate this branch with scope
    # containment intact. $LOG_DIR is date-keyed; the drafts branch is not. See
    # ns_theme_for_branch (lib/common.sh) for the failure this prevents. `if`, not `[ -f ] &&`:
    # a tier-1 branch legitimately has no theme and this must not return nonzero on that path.
    if [ -f "$LOG_DIR/theme-$slug.json" ]; then
        mkdir -p "$DRAFTS/themes"
        cp "$LOG_DIR/theme-$slug.json" "$DRAFTS/themes/$slug.json"
    fi
```

`ship_main` already does `git -C "$DRAFTS" add -A`, so the copy is committed and pushed with the drafts.

- [ ] **Step 3: Add the fragment renumber, kind-agnostic**

Append to `lib/ship.sh`:

```bash
# Rename release_notes/unreleased/jaclang/0000.<kind>.md -> <PR#>.<kind>.md and push.
#
# The predecessor at lib/promote.sh:88 stripped the literal suffix `0000.refactor.md`, so the
# rename silently NO-OPPED for the other four kinds (feature/bugfix/breaking/docs) and shipped a
# fragment still named 0000 -- which upstream's scripts/check-release-notes.sh rejects. Nothing
# emits a non-refactor kind today (Plan 2's job), so this is written kind-agnostically now rather
# than becoming a fourth site that has to change in lockstep later.
#
# The push fires a second CI run on the PR (`synchronize`). That is accepted: the fragment MUST
# carry the PR number, and the number does not exist until the PR does.
ns_renumber_fragment() {   # <branch> <pr_num> <fragment_path>
    local branch=$1 pr=$2 frag=$3 base new
    case "$frag" in "") return 0 ;; esac          # tests-only / jac-mcp change: no fragment at all
    base="${frag##*/}"
    case "$base" in
        0000.*) : ;;
        *) ns_die "$EX_BUG" "fragment '$frag' does not carry the 0000 placeholder, so the PR-number rename cannot be derived from it. nslib.fragment_path is the only thing that should be naming these." ;;
    esac
    new="${frag%/*}/$pr.${base#0000.}"
    if ! git -C "$REPO" ls-files --error-unmatch "$frag" >/dev/null 2>&1; then
        ns_warn "$branch: expected release-note fragment $frag is not tracked on the branch; upstream's check-release-notes.sh will red this PR"
        return 0
    fi
    git -C "$REPO" mv "$frag" "$new"
    git -C "$REPO" commit -qm "docs: release note fragment for #$pr"
    ns_git_push "$REPO" origin "refs/heads/$branch:refs/heads/$branch"
    ns_log S5 "fragment renamed $base -> ${new##*/}"
}
```

- [ ] **Step 4: Add `ship_open_pr`**

Append to `lib/ship.sh`:

```bash
# Open the DRAFT PR upstream (spec 6). Never merges, never leaves draft, never pushes to main.
#
# Returns 1 rather than dying when the PR cannot be opened: the branch is already pushed and the
# draft .md already exists, so the night's other branches should still ship and a human can run
# `nightshift.sh promote <branch>` for this one. The failure is recorded in failed.tsv, which the
# digest renders.
ship_open_pr() {
    local branch=$1 draft=$2 slug=$3
    local title pr_url pr_num frag fp pr_rc=0
    title="$(ns_jac render_draft meta "$draft" | ns_jac parse_result field title)"
    case "$title" in
        "") ns_fail "$branch" "draft $draft has no title; refusing to open a PR without one"
            return 1 ;;
    esac
    ns_jac render_draft body "$draft" > "$LOG_DIR/pr-body-$slug.md"

    pr_url="$(ns_gh_write pr create --repo "$NS_REPO_UPSTREAM" --draft \
        --base "$NS_REPO_DEFAULT_BRANCH" --head "${NS_REPO_FORK%%/*}:$branch" \
        --title "$title" --body-file "$LOG_DIR/pr-body-$slug.md" \
        2> "$LOG_DIR/pr-create-$slug.err")" || pr_rc=$?

    # POSITIVE assertion. `gh pr create` can exit 0 having printed nothing (and does, whenever a
    # future gh decides to route its output differently), and an empty $pr_url would then flow
    # into the ledger as a shipped PR that does not exist. The rc alone is not evidence; the URL
    # is. This is the same class as lib/verify.sh's assert_suite_ran.
    case "$pr_url" in
        https://github.com/*/pull/[0-9]*) : ;;
        *)  ns_fail "$branch" "gh pr create returned no PR URL (rc=$pr_rc, got '$pr_url'): $(head -3 "$LOG_DIR/pr-create-$slug.err" 2>/dev/null | tr '\n' ' ')"
            printf '%s\t%s\t%s\t%s\t%s\n' "-" "$branch" "pr-failed" "rc=$pr_rc" "-" >> "$LOG_DIR/prs.tsv"
            return 1 ;;
    esac
    pr_num="${pr_url##*/}"
    ns_log S5 "opened draft PR $pr_url for $branch"

    frag="$(ns_jac render_draft meta "$draft" | ns_jac parse_result field release_note)"
    ns_renumber_fragment "$branch" "$pr_num" "$frag"

    # The findings on this branch are SHIPPED now, not merely drafted: a PR exists upstream. The
    # draft .md deliberately STAYS on disk -- with S5 opening PRs it no longer means "not yet
    # submitted", it means "there is an open PR and `nightshift.sh discard <branch>` is how you
    # kill it" (Task 5 makes discard close the PR).
    ns_jac ledger by-branch "$branch" "$LEDGER" | while IFS= read -r fp; do
        ns_jac ledger set-status "$fp" shipped "$LEDGER" "{\"pr_url\":\"$pr_url\"}" >/dev/null
    done
    printf '%s\t%s\t%s\t%s\t%s\n' "$pr_num" "$branch" "opened" "$title" "$pr_url" >> "$LOG_DIR/prs.tsv"
    return 0
}
```

- [ ] **Step 5: Call it from `ship_branch`**

In `ship_branch`, after `dataset_record_refactor ...` and before the closing `ns_log S5`:

```bash
    # `|| true`: a PR that could not be opened is recorded by ship_open_pr itself and must not
    # take the remaining branches down with it. ship_branch is called from a `while read` loop.
    ship_open_pr "$branch" "$draft_path" "$slug" || true
```

Replace the trailing log line so it says what actually happened:

```bash
    ns_log S5 "shipped $branch + draft $(basename "$draft_path")"
```

stays as-is — `ship_open_pr` logs the PR separately, and conflating them would let a failed PR read as a successful one.

- [ ] **Step 6: Prove it end to end under dry-run, against a real branch**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo
git fetch origin && git checkout -B nightshift/ship-probe origin/main
printf '\n# nightshift ship probe\n' >> jac/jaclang/utils/treeprinter.jac
git commit -aqm "probe: ship path rehearsal"
cd /Volumes/ExtremePro/JaseciLabs/NightShift
export NS_DATE="$(date +%F)"; mkdir -p "logs/$NS_DATE"
printf '%s\t-\t-\n' nightshift/ship-probe > "logs/$NS_DATE/green.tsv"
NS_DRY_RUN=1 bash -c '. lib/common.sh; ns_load_config; ns_load_env
  . lib/dataset.sh; . lib/ship.sh; ship_main' 2>&1 | tail -20
cat "logs/$NS_DATE/prs.tsv"
```

Expected: `[DRY] git -C ... push`, `[DRY] gh pr create --repo jaseci-labs/jac --draft ...`, a `prs.tsv` row with PR number `0` and the `DRY-RUN` URL, and **no real PR**. Confirm the last part directly:

```bash
/opt/homebrew/bin/gh pr list --repo jaseci-labs/jac --author @me --state open
```

Expected: no `ship-probe` PR. Clean up:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo \
  && git checkout -f main && git branch -D nightshift/ship-probe
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -f "logs/$NS_DATE/green.tsv" "logs/$NS_DATE/prs.tsv"
```

- [ ] **Step 7: Pin the ship path's two structural invariants in the harness**

Append section 12 to `bin/test-harness.sh`:

```bash
echo "== 12. ship path: the PR URL is asserted, and the fragment rename is kind-agnostic =="
# (a) `gh pr create` exiting 0 with no output must NOT reach the ledger as a shipped PR. The
# assertion lives in a `case` on the URL, so grep for the SHAPE, not for a comment about it.
grep -q 'https://github.com/\*/pull/\[0-9\]\*' lib/ship.sh \
    || fail "lib/ship.sh no longer asserts the SHAPE of the URL gh pr create returned -- a silent empty result would be recorded as a shipped PR"
# (b) the kind-agnostic rename: the literal '0000.refactor.md' must appear NOWHERE in the rename
# path, in either file. That literal is what made the old rename a no-op for four of five kinds.
case "$(grep -c '0000\.refactor\.md' lib/ship.sh lib/promote.sh | grep -v ':0$' | wc -l | tr -d ' ')" in
    0) : ;;
    *) fail "a hardcoded 0000.refactor.md is back in the fragment rename path; it silently no-ops for feature/bugfix/breaking/docs" ;;
esac
# (c) behavioural: the rename derives <pr>.<kind>.md for a kind nothing emits yet
( . "$NS_ROOT/lib/common.sh"
  frag="release_notes/unreleased/jaclang/0000.bugfix.md"
  base="${frag##*/}"; new="${frag%/*}/4321.${base#0000.}"
  [ "$new" = "release_notes/unreleased/jaclang/4321.bugfix.md" ] ) \
    || fail "the fragment rename expression does not preserve a non-refactor kind"
echo "ship path: URL asserted, fragment rename kind-agnostic"
```

- [ ] **Step 8: Run the harness and commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add lib/ship.sh lib/common.sh bin/test-harness.sh
git commit -m "S5 opens the draft PR upstream

Green branch -> push to the fork -> gh pr create --draft against
jaseci-labs/jac. Never merges, never pushes to main; the PR is terminal until a
human merges it. The draft .md and the promote/discard CLI stay as a parallel
kill path -- the draft file's meaning changes from 'not yet submitted' to 'there
is an open PR and discard is how you kill it'.

The URL is asserted by shape, not inferred from gh's exit code: a call that
silently returns nothing would otherwise be recorded in the ledger as a shipped
PR that does not exist.

The fragment rename is kind-agnostic. lib/promote.sh stripped the literal
0000.refactor.md, so it no-opped for the other four kinds and would have shipped
a fragment upstream's check-release-notes.sh rejects.

Each theme is copied to the drafts branch beside its draft. \$LOG_DIR is
date-keyed, so a later night re-gating this branch would otherwise find no theme
and either die or -- worse -- re-gate an agent-written branch with scope
containment switched off. S1.6 re-gates branches from arbitrary earlier nights,
so this is the difference between a working inventory and a documented
workaround."
```

---

### Task 5: Keep the kill path coherent — `discard` closes the PR, `promote` refuses a duplicate

S5 now opens PRs, which breaks two assumptions in `lib/promote.sh`. `discard` deletes the branch but leaves an open draft PR in someone else's repo. `promote` would open a **second** PR for a branch that already has one. Both are new bugs created by Task 4, and both are fixed here.

`promote` keeps its job — it is the manual path for a branch whose PR S5 could not open (dry-run night, network failure, permission change) — and gets shorter, because `ns_theme_for_branch` replaces its 24-line theme-resolution block and `ns_renumber_fragment` replaces its hardcoded rename.

**Files:**
- Modify: `lib/promote.sh` (`promote_main`, `discard_main`)
- Modify: `bin/test-harness.sh` (extend section 9a, which currently pins the block being deleted)

**Interfaces:**
- Produces: `ns_pr_for_branch <branch>` in `lib/promote.sh` — prints the open PR number whose head is `<branch>`, or nothing. Read-only; runs under dry-run.
- Consumed by: `lib/inventory.sh` (Task 7) for the same lookup.

- [ ] **Step 1: Add the lookup**

At the top of `lib/promote.sh`, after `find_draft`:

```bash
# The open PR number for a branch, or "" when there is none. Read-only, so it runs under dry-run
# too -- `discard` has to know whether there is a PR to close even during a rehearsal.
#
# Materialized and shape-checked rather than used inline: `gh pr list` failing (offline, auth
# expired) prints nothing and would otherwise be indistinguishable from "no PR exists", which is
# exactly the answer that makes discard skip the close and delete the branch anyway.
ns_pr_for_branch() {
    local branch=$1 raw rc=0 num
    raw="$(ns_gh pr list --repo "$NS_REPO_UPSTREAM" --head "$branch" --state open \
              --json number,headRefName,url,title)" || rc=$?
    case "$rc" in
        0) : ;;
        *) ns_die "$EX_BUG" "could not list PRs for $branch (gh rc=$rc). An empty result and a failed query look identical downstream, and the difference decides whether an open PR is left dangling." ;;
    esac
    num="$(printf '%s' "$raw" | ns_jac cigate prs "nightshift/" | cut -f1 | head -1)"
    printf '%s' "$num"
}
```

- [ ] **Step 2: Make `discard` close the PR before it deletes anything**

In `discard_main`, insert immediately after the `reason_sane` assignment:

```bash
    # Close the PR BEFORE deleting the branch. Deleting the head branch of an open PR does close
    # it on GitHub, but leaves no explanation on someone else's repo -- and if the close fails we
    # need to find out while the branch still exists to retry against.
    local pr_num
    pr_num="$(ns_pr_for_branch "$branch")"
    case "$pr_num" in
        "") ns_log S7 "no open PR for $branch — nothing to close upstream" ;;
        *)  ns_gh_write pr close "$pr_num" --repo "$NS_REPO_UPSTREAM" \
                --comment "Closing: this automated cleanup was discarded by its operator ($reason_sane). No action needed." \
                || ns_die "$EX_BUG" "could not close PR #$pr_num for $branch — refusing to delete the branch and leave a dangling open PR upstream. Close it by hand, then re-run discard."
            ns_log S7 "closed PR #$pr_num" ;;
    esac
```

- [ ] **Step 3: Make `promote` refuse a branch that already has a PR**

At the top of `promote_main`, right after the `local` declarations:

```bash
    # S5 opens PRs automatically now, so promote is the manual path for a branch whose PR could
    # not be opened (a dry-run night, a network failure, a permission change). Opening a SECOND
    # PR for the same branch would be pure noise upstream, and the ledger would record whichever
    # URL was written last.
    local existing
    existing="$(ns_pr_for_branch "$branch")"
    case "$existing" in
        "") : ;;
        *)  ns_die "$EX_BUG" "$branch already has open PR #$existing upstream — S5 opened it. Nothing to promote. Use 'nightshift.sh discard $branch <reason>' to kill it, or review it on GitHub." ;;
    esac
```

- [ ] **Step 4: Delete promote's theme-resolution block and its hardcoded rename**

Replace lines 36-61 of `lib/promote.sh` (the whole `local theme="-" tf` block and its comment) with:

```bash
    # Which theme (if any) verify_branch re-gates this branch against. The 24 lines of reasoning
    # that used to live here now live at ns_theme_for_branch (lib/common.sh), which also looks on
    # the drafts branch -- so promoting on a different calendar day than the run no longer needs
    # the NS_DATE=<night> workaround this comment used to prescribe.
    local theme
    theme="$(ns_theme_for_branch "$branch")"
```

and replace the fragment block (lines 75-91) with:

```bash
    # 3. rename the release-note fragment 0000 -> <PR#> (the PR updates itself on push)
    fragment="$(ns_jac render_draft meta "$draft" | ns_jac parse_result field release_note)"
    ns_renumber_fragment "$branch" "$pr_num" "$fragment"
```

Route promote's own `gh pr create` through the seam while you are there — `"$NS_PATHS_GH" pr create` becomes `ns_gh_write pr create`, and add the same URL-shape assertion `ship_open_pr` uses. Also replace the bare `git -C "$REPO" push --force-with-lease ...` at line 65 and the two `git -C "$DRAFTS" push` calls with `ns_git_push`, so `promote` is dry-runnable at all.

- [ ] **Step 5: Update harness section 9a, which pins the block just deleted**

Section 9a asserts `grep -q 'ns_is_tier1_branch "$branch"' lib/promote.sh` and `grep -q 'ns_die "$EX_BUG" "no theme file for' lib/promote.sh`. Both now live in `lib/common.sh`. Point the assertions at their new home and add the one that matters more:

```bash
grep -q 'ns_is_tier1_branch "\$branch"' lib/common.sh \
    || fail "ns_theme_for_branch no longer identifies the tier-1 branch positively by slug; absence of a theme file must never be read as 'no theme'"
grep -q 'ns_die "\$EX_BUG" "no theme file for' lib/common.sh \
    || fail "ns_theme_for_branch no longer dies on a missing tier-2 theme -- it would re-gate an agent-written branch without scope containment"
grep -q 'ns_theme_for_branch' lib/promote.sh \
    || fail "lib/promote.sh resolves the theme by hand again instead of through ns_theme_for_branch"
# behavioural: a tier-2 branch with a theme ONLY on the drafts branch must resolve, not die --
# this is the case S1.6 hits on every PR from an earlier night.
( . "$NS_ROOT/lib/common.sh"
  LOG_DIR="$T/nologs"; DRAFTS="$T/drafts"; mkdir -p "$DRAFTS/themes" "$LOG_DIR"
  echo '{}' > "$DRAFTS/themes/dead-cli.json"
  got="$(ns_theme_for_branch nightshift/2026-07-01/dead-cli)"
  [ "$got" = "$DRAFTS/themes/dead-cli.json" ] ) \
    || fail "ns_theme_for_branch does not fall back to the drafts branch; every S1.6 re-gate of an older PR would die"
```

- [ ] **Step 6: Prove `discard` closes before it deletes, under dry-run**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
NS_DRY_RUN=1 bin/nightshift.sh discard nightshift/2026-07-01/nonexistent "harness rehearsal" 2>&1 | tail -20
```

Expected: an `[DRY]`-free `gh pr list` actually running (read-only), then either `no open PR ... nothing to close` or `[DRY] gh pr close`, and `[DRY] git -C ... push` for the branch deletion — never a real close. Confirm the ordering by reading the log: the close line must precede the delete line.

- [ ] **Step 7: Run the harness and commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add lib/promote.sh bin/test-harness.sh
git commit -m "Keep the kill path coherent now that S5 opens PRs

Two bugs the previous commit created. discard deleted the branch and left an
open draft PR dangling in someone else's repo; it now closes the PR first, with
a comment, and refuses to delete the branch if the close fails. promote would
have opened a SECOND PR for a branch S5 already submitted; it now refuses.

promote also loses its 24-line theme-resolution block and its hardcoded
0000.refactor.md rename to the shared helpers, which incidentally retires the
NS_DATE=<night> workaround its own comment used to prescribe: the theme is on
the drafts branch now, so any night can find it."
```

---

### Task 6: S1.6 part 1 — the inventory and its CI verdict

The inventory runs **before any new work** (spec section 4: S1.6 > S3a > carry-over > tonight's task), so the PR set converges instead of growing. This task builds the listing and the CI verdict; Task 7 adds the rebase.

**The CI verdict is read at the start of the night, for CI that ran during the previous one.** That is the whole reason there is no polling anywhere in this plan: a PR opened last night has had ~24h, so its checks are long finished, and reading them costs one API call instead of 35 minutes of waiting. Nothing waits for CI, ever.

Order within a PR matters: **read the verdict first, then rebase.** A rebase force-pushes and invalidates the very checks being judged.

**Files:**
- Create: `lib/inventory.sh`
- Modify: `config/nightshift.toml` (`[budgets].inventory_min`)

**Interfaces:**
- Produces: `inventory_main` — the S1.6 stage.
- Produces: `inventory_record_baseline` — writes `$CI_BASELINE` from main's head check runs; never fatal.
- Produces: `inventory_ci_verdict <num> <branch>` — appends a `prs.tsv` row and `ns_warn`s a red PR.
- Produces: `CI_BASELINE="$NS_ROOT/state/ci-baseline.json"`. One file, not a directory: `testgate`'s per-suite directory exists because there are three suites, and there is exactly one CI baseline.
- Consumes: `ns_gh`, `ns_jac cigate {record,ran,gate,prs}`, `$LOG_DIR/prs.tsv`.

- [ ] **Step 1: Add the clock budget**

`config/nightshift.toml`, in `[budgets]`:

```toml
inventory_min      = 120                     # ceiling for S1.6. Re-gating one PR costs what S4
                                              # costs (~40min worst case), so N open PRs can eat
                                              # the whole night and ship nothing new. When this is
                                              # spent the remaining PRs are left for the next
                                              # night -- the inventory converges over nights, not
                                              # within one. Raise it once the steady state is known.
```

- [ ] **Step 2: Create `lib/inventory.sh` with the baseline recorder**

```bash
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

CI_BASELINE="$NS_ROOT/state/ci-baseline.json"

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
    n="$(ns_jac cigate record "$cap" "$CI_BASELINE")" || rc=$?
    case "$rc" in
        0) : ;;
        *) ns_warn "cigate could not record a CI baseline from $(basename "$cap") (rc=$rc) — the capture may be truncated; no PR will be CI-gated tonight"
           return 0 ;;
    esac
    ns_log S1.6 "CI baseline: $n checks currently passing on $NS_REPO_DEFAULT_BRANCH"
}
```

- [ ] **Step 3: Add the per-PR CI verdict**

```bash
# The CI verdict for one open PR, judged against tonight's baseline.
#
# Reads the checks on the PR's OWN head commit, which is why it must run BEFORE the rebase in
# inventory_refresh: a rebase force-pushes and replaces the very commit whose checks are being
# read. Records a prs.tsv row in every case, including the ones that are not a verdict at all --
# "CI has not reported" and "no baseline" are different from "green", and the operator's only
# channel is the digest.
inventory_ci_verdict() {   # <num> <branch>
    local num=$1 branch=$2 sha cap ran rc=0 detail
    sha="$(ns_gh pr view "$num" --repo "$NS_REPO_UPSTREAM" --json headRefOid \
             | ns_jac parse_result field headRefOid)" || rc=$?
    case "$sha" in
        ''|*[!0-9a-f]*)
            ns_warn "PR #$num ($branch): could not read a head sha (rc=$rc, got '$sha') — no CI verdict"
            printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$branch" "ci-unknown" "no head sha" "-" >> "$LOG_DIR/prs.tsv"
            return 0 ;;
    esac
    cap="$LOG_DIR/ci-pr-$num.json"
    rc=0
    ns_gh api "repos/$NS_REPO_UPSTREAM/commits/$sha/check-runs?per_page=100" \
        > "$cap" 2>> "$LOG_DIR/inventory.err" || rc=$?
    case "$rc" in
        0) : ;;
        *) ns_warn "PR #$num ($branch): could not read its check runs (gh rc=$rc) — no CI verdict"
           printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$branch" "ci-unknown" "gh rc=$rc" "-" >> "$LOG_DIR/prs.tsv"
           return 0 ;;
    esac
    # A capture where nothing has COMPLETED has zero failures and zero passes -- indistinguishable
    # from a clean run to anything that counts failures. Assert the work happened before reading
    # meaning into it, exactly as assert_suite_ran does for the test suites.
    rc=0
    ran="$(ns_jac cigate ran "$cap")" || rc=$?
    case "$ran" in
        ''|*[!0-9]*)
            ns_warn "PR #$num ($branch): could not count completed checks (rc=$rc, got '$ran') — refusing to read the capture as green"
            printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$branch" "ci-unknown" "unreadable capture" "-" >> "$LOG_DIR/prs.tsv"
            return 0 ;;
        0)  ns_log S1.6 "PR #$num: CI has not reported yet ($sha)"
            printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$branch" "ci-pending" "0 checks completed" "-" >> "$LOG_DIR/prs.tsv"
            return 0 ;;
    esac
    rc=0
    ns_jac cigate gate "$cap" "$CI_BASELINE" 2>> "$LOG_DIR/inventory.err" || rc=$?
    case "$rc" in
        0)  ns_log S1.6 "PR #$num: CI green vs baseline ($ran checks)"
            printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$branch" "ci-green" "$ran checks" "-" >> "$LOG_DIR/prs.tsv" ;;
        2)  ns_log S1.6 "PR #$num: no usable CI baseline — not gated"
            printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$branch" "ci-nobaseline" "-" "-" >> "$LOG_DIR/prs.tsv" ;;
        *)  # RED vs baseline: a check that fails here and passes on main. Reported, not repaired
            # -- see this plan's "deliberately not built". Nothing is closed and no attempt
            # counter moves; a human decides.
            detail="$(grep '^NEW CI FAILURE: ' "$LOG_DIR/inventory.err" | tail -5 | sed 's/^NEW CI FAILURE: //' | tr '\n' ' ')"
            ns_warn "PR #$num ($branch): CI RED vs main's baseline on: ${detail:-unknown}. The local mirror was green when this was opened, so this is worth reading before the next night re-pushes it."
            printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$branch" "ci-red" "${detail:-unknown}" "-" >> "$LOG_DIR/prs.tsv" ;;
    esac
}
```

- [ ] **Step 4: Add the driver**

```bash
# The S1.6 stage. Lists nightshift's open PRs upstream and processes each one.
#
# The LIST is materialized and its exit status checked before anything iterates it. `gh pr list`
# failing prints nothing, and "no open PRs" is a perfectly normal answer -- so an unchecked reader
# failure would silently report a converged, empty inventory on the night the token expired. This
# is the exact shape of six of the seven false greens this codebase has already shipped.
inventory_main() {
    : >> "$LOG_DIR/prs.tsv"
    : >> "$LOG_DIR/inventory.err"
    inventory_record_baseline

    local raw rows rc=0 n=0 num branch url title deadline
    raw="$(ns_gh pr list --repo "$NS_REPO_UPSTREAM" --author "@me" --state open \
              --limit 100 --json number,headRefName,url,title)" || rc=$?
    case "$rc" in
        0) : ;;
        *) ns_warn "S1.6: could not list open PRs (gh rc=$rc) — the inventory did NOT run tonight. This is not the same as having none."
           return 0 ;;
    esac
    rc=0
    rows="$(printf '%s' "$raw" | ns_jac cigate prs "nightshift/")" || rc=$?
    case "$rc" in
        0) : ;;
        *) ns_warn "S1.6: could not project the PR list (rc=$rc) — the inventory did NOT run tonight."
           return 0 ;;
    esac
    case "$rows" in
        "") ns_log S1.6 "no open nightshift PRs upstream — nothing to maintain"
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
        inventory_refresh "$num" "$branch"        # Task 7
    done <<< "$rows"
    ns_log S1.6 "processed $n open PR(s)"
}
```

- [ ] **Step 5: Stub `inventory_refresh` so this task is independently green**

Append, to be replaced wholesale in Task 7:

```bash
# Replaced in Task 7 with fetch/rebase/re-gate/push.
inventory_refresh() {
    ns_log S1.6 "PR #$1 ($2): refresh not implemented yet"
}
```

- [ ] **Step 6: Drive it against the real upstream, read-only**

The listing and verdict paths are entirely read-only, so this is safe to run for real right now.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
export NS_DATE="$(date +%F)"; mkdir -p "logs/$NS_DATE"
bash -c '. lib/common.sh; ns_load_config; ns_load_env; . lib/inventory.sh; inventory_main' 2>&1 | tail -30
cat "state/ci-baseline.json" | head -8
cat "logs/$NS_DATE/prs.tsv" 2>/dev/null || echo "(no PRs)"
```

Expected: `CI baseline: N checks currently passing on main` with N in the twenties and **not** including `jac-check`; then either `no open nightshift PRs upstream` (the state today) or one row per PR. If it reports "no open PRs" while `gh pr list` shows some, the `nightshift/` prefix filter is wrong.

- [ ] **Step 7: Prove the reader-failure path is not a silent "converged"**

The single most valuable assertion in this task. Point `gh` at a binary that fails and confirm the run says so.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
printf '#!/bin/sh\nexit 4\n' > /tmp/fake-gh && chmod +x /tmp/fake-gh
bash -c '. lib/common.sh; ns_load_config; ns_load_env; NS_PATHS_GH=/tmp/fake-gh
         . lib/inventory.sh; inventory_main; echo "rc=$?"' 2>&1 | tail -5
grep -c "inventory did NOT run" "logs/$NS_DATE/warnings.txt"
```

Expected: `rc=0` (the night continues) **and** a warning containing `the inventory did NOT run tonight. This is not the same as having none.` A run that printed `no open nightshift PRs upstream` here would be the defect this plan exists to prevent.

- [ ] **Step 8: Commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add lib/inventory.sh config/nightshift.toml
git commit -m "Add S1.6: list nightshift's open PRs and read their CI verdict

Runs before any new work so the PR inventory converges rather than growing.
Records what passes on main tonight, then judges each open PR's own head commit
against it -- red only on a check that fails on the branch and passes on main,
because upstream CI is red on main often enough that all-green would reject
everything.

Nothing polls. A PR opened last night has had ~24h, so its verdict costs one API
call instead of ~35min of waiting, and a PR opened tonight is judged tomorrow.

A failed 'gh pr list' is reported as 'the inventory did NOT run', never as an
empty inventory: an unchecked reader that prints nothing looks exactly like a
converged one, which is the shape of six of the seven false greens this
codebase has already shipped."
```

---

### Task 7: S1.6 part 2 — fetch, rebase, re-gate, push

This is what makes the inventory *maintenance* rather than reporting: each open PR is pulled up to fresh main, re-run through the local CI mirror, and pushed. A rebase conflict is labelled in the digest and left alone — never forced.

One hazard has to be closed first. `verify_branch` calls `verify_red` on any red, and `verify_red` increments the finding's `attempts` (auto-rejecting at 2) **and deletes the branch**. Running it unchanged in the inventory would mean an upstream-introduced breakage — `[jobs.contribution]`'s two whole-repo checks are the documented example, see followups section 4 — reds every open PR identically and auto-rejects the entire ledger after two nights, over something no branch caused. So `verify_branch` gains an explicit `on_red` mode.

**Files:**
- Modify: `lib/verify.sh` (`verify_branch` signature and its eight `verify_red` call sites; `verify_red` signature)
- Modify: `lib/inventory.sh` (`inventory_refresh`)
- Modify: `bin/test-harness.sh` (section 13)

**Interfaces:**
- Modifies: `verify_branch <branch> <theme> [on_red]` where `on_red` is `demote` (default, today's behavior) or `report` (log only: no ledger write, no attempts++, no branch delete).
- Modifies: `verify_red <branch> <why> [on_red]`.
- Produces: `inventory_refresh <num> <branch>` — fetch, hard-align to the remote, rebase, re-gate, push; appends a `prs.tsv` row for every outcome.

- [ ] **Step 1: Write the failing harness section**

Append section 13 to `bin/test-harness.sh`:

```bash
echo "== 13. S1.6 re-gate must not burn attempt counters or delete branches =="
# [jobs.contribution] validates WHOLE-REPO state (validate_docs_code.jac's 852 blocks, the bun/zig
# version lockstep), so an upstream-introduced breakage reds every open PR identically. With the
# default demote mode that bumps every finding's attempts and auto-rejects the whole ledger after
# two nights, over something no branch caused. The inventory therefore re-gates in report mode.
grep -qE 'verify_branch "\$branch" "\$theme" report' lib/inventory.sh \
    || fail "lib/inventory.sh does not re-gate in report mode; an upstream breakage would auto-reject the entire ledger in two nights"
# every verify_red call INSIDE verify_branch must forward the mode, or the mode is decorative
vr_total="$(grep -c 'verify_red "\$branch"' lib/verify.sh || true)"
vr_moded="$(grep -c 'verify_red "\$branch" .* "\$on_red"' lib/verify.sh || true)"
case "$vr_total" in
    0) fail "no verify_red call sites found in lib/verify.sh -- section 13 would be vacuous" ;;
esac
[ "$vr_total" = "$vr_moded" ] \
    || fail "$((vr_total - vr_moded)) of $vr_total verify_red calls do not forward \$on_red; those paths still demote during an S1.6 re-gate"
# behavioural: report mode must write NOTHING to the ledger and must not delete the branch
VR="$T/vr"; mkdir -p "$VR"
( . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/verify.sh"
  LOG_DIR="$VR"; LEDGER="$VR/ledger.jsonl"; REPO="$VR/norepo"
  ns_jac() { echo "LEDGER-WRITE $*" >> "$VR/calls.txt"; }
  git() { echo "GIT $*" >> "$VR/calls.txt"; }
  verify_red somebranch "a reason" report ) >/dev/null 2>&1
case "$(cat "$VR/calls.txt" 2>/dev/null || true)" in
    *LEDGER-WRITE*) fail "verify_red in report mode still wrote to the ledger -- attempts would be burned by every S1.6 re-gate" ;;
esac
case "$(cat "$VR/calls.txt" 2>/dev/null || true)" in
    *"branch -D"*) fail "verify_red in report mode still deleted the branch -- an open PR's head would vanish" ;;
esac
# ...and demote mode must still do both, or the guard has simply disabled the gate
rm -f "$VR/calls.txt"
( . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/verify.sh"
  LOG_DIR="$VR"; LEDGER="$VR/ledger.jsonl"; REPO="$VR/norepo"
  ns_jac() { echo "LEDGER-WRITE $*" >> "$VR/calls.txt"; }
  git() { echo "GIT $*" >> "$VR/calls.txt"; }
  verify_red somebranch "a reason" ) >/dev/null 2>&1
case "$(cat "$VR/calls.txt" 2>/dev/null || true)" in
    *LEDGER-WRITE*) : ;;
    *) fail "verify_red in the DEFAULT mode no longer demotes -- the S4 gate has been silently disabled" ;;
esac
# the inventory never force-pushes bare, and never rebases a branch it did not author
grep -q 'force-with-lease' lib/inventory.sh \
    || fail "lib/inventory.sh does not push a rebased branch with --force-with-lease"
grep -q 'cigate prs "nightshift/"' lib/inventory.sh \
    || fail "lib/inventory.sh no longer filters PR heads to nightshift/ -- it would rebase and force-push a human's branch"
echo "S1.6 re-gate is report-only; demote mode intact; heads filtered; lease-only force"
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
```

Expected: `FAIL: lib/inventory.sh does not re-gate in report mode`.

- [ ] **Step 3: Give `verify_branch` and `verify_red` the mode**

`lib/verify.sh`, at the top of `verify_branch`:

```bash
verify_branch() {
    local branch=$1 theme=$2 on_red="${3:-demote}" t0 t1
```

with the comment:

```bash
    # on_red: `demote` (default) is the S4 behavior -- a red branch is failed_verify'd (attempts++,
    # auto-rejected at 2) and deleted. `report` is for S1.6's re-gate of an ALREADY-OPEN PR, where
    # the branch is upstream and the red may not be its fault at all: [jobs.contribution] validates
    # whole-repo state (validate_docs_code.jac, the bun/zig lockstep), so an upstream breakage reds
    # every open PR identically and would auto-reject the entire ledger in two nights. Passed
    # EXPLICITLY to every verify_red below rather than read out of dynamic scope, because bash's
    # dynamic scoping would make this work by accident and break silently when a call site moves.
```

Append `"$on_red"` to all eight `verify_red "$branch" "..."` calls inside `verify_branch`, then:

```bash
verify_red() {
    local branch=$1 why=$2 on_red="${3:-demote}" fp why_sane
    ns_fail "$branch" "$why"
    case "$on_red" in
        report)
            # S1.6: report and move on. No ledger write (attempts must not move), no branch delete
            # (the branch is an open PR's head upstream).
            ns_log S1.6 "$branch: gate red, reported only — no attempt counter moved, branch kept"
            return 0 ;;
    esac
    why_sane="$(printf '%s' "$why" | tr -d '"\\')"
    ns_jac ledger by-branch "$branch" "$LEDGER" | while IFS= read -r fp; do
        ns_jac ledger set-status "$fp" failed_verify "$LEDGER" "{\"reason\":\"$why_sane\"}" >/dev/null
    done
    git checkout "$NS_REPO_DEFAULT_BRANCH"
    git branch -D "$branch" || true
}
```

- [ ] **Step 4: Replace the `inventory_refresh` stub**

```bash
# Bring one open PR up to fresh main and re-gate it.
#
# Sequence is load-bearing:
#   1. fetch and hard-align the local branch to the REMOTE. The local copy is stale by a night, and
#      the remote may carry commits nobody here wrote (a human's review fix; CI's jac fmt autofix
#      bot cannot reach a fork PR, but that is upstream's rule, not ours to depend on). Rebasing a
#      stale local copy and force-pushing it would DELETE those commits.
#   2. rebase onto fresh main. A conflict is reported and abandoned -- never forced, never resolved
#      by an agent.
#   3. re-gate in `report` mode.
#   4. push with --force-with-lease, which fires CI (`synchronize`); tomorrow night reads the result.
#
# Scope containment is intact through all of it: ns_theme_for_branch finds the theme on the drafts
# branch, so the re-gate is not the "theme = -" shortcut that skips the anti-injection check.
# KNOWN CEILING (`ponytail:`): commits pushed to the branch by someone else are re-gated by the
# mirror and the test suites but were never scope-checked, since the theme describes what
# Nightshift planned, not what a human added. Upgrade path if that ever happens: refuse to refresh
# a branch carrying a commit whose author is not the harness.
inventory_refresh() {   # <num> <branch>
    local num=$1 branch=$2 theme head remote
    cd "$REPO"
    if ! git fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch"; then
        ns_warn "PR #$num ($branch): could not fetch the branch from the fork — left untouched"
        printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$branch" "fetch-failed" "-" "-" >> "$LOG_DIR/prs.tsv"
        return 0
    fi
    # Align to the REMOTE, not to whatever is in the local clone. `checkout -B` is what makes this
    # a reset rather than a merge.
    git checkout -qB "$branch" "origin/$branch" \
        || ns_die "$EX_BUG" "could not check out $branch from origin in $REPO — every stage below would have run against whatever is currently checked out."
    head="$(git rev-parse HEAD)"; remote="$(git rev-parse "origin/$branch")"
    case "$head" in
        "$remote") : ;;
        *) ns_die "$EX_BUG" "after checkout -B, $branch is at $head but origin/$branch is at $remote — refusing to rebase and force-push a tree that is not the remote's." ;;
    esac

    # Already on top of main and nothing new pushed: nothing to do. This is the steady state, and
    # skipping it is what keeps a converged inventory cheap (~2s per PR instead of ~40min).
    if git merge-base --is-ancestor "$NS_REPO_DEFAULT_BRANCH" HEAD; then
        ns_log S1.6 "PR #$num: already on top of $NS_REPO_DEFAULT_BRANCH — nothing to rebase"
        printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$branch" "current" "-" "-" >> "$LOG_DIR/prs.tsv"
        git checkout -q "$NS_REPO_DEFAULT_BRANCH"
        return 0
    fi

    if ! git rebase -q "$NS_REPO_DEFAULT_BRANCH"; then
        git rebase --abort || true
        git checkout -q "$NS_REPO_DEFAULT_BRANCH"
        ns_warn "PR #$num ($branch): rebase conflict onto $NS_REPO_DEFAULT_BRANCH — left exactly as it was, needs a human. Nothing was forced."
        printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$branch" "conflict" "rebase onto $NS_REPO_DEFAULT_BRANCH" "-" >> "$LOG_DIR/prs.tsv"
        return 0
    fi

    theme="$(ns_theme_for_branch "$branch")"
    if ! verify_branch "$branch" "$theme" report; then
        ns_warn "PR #$num ($branch): rebased onto fresh $NS_REPO_DEFAULT_BRANCH but the local gate is now red — NOT pushed, so the PR still shows the last green state. See failed.tsv."
        printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$branch" "regate-red" "not pushed" "-" >> "$LOG_DIR/prs.tsv"
        git checkout -q "$NS_REPO_DEFAULT_BRANCH"
        return 0
    fi

    ns_git_push "$REPO" --force-with-lease origin "refs/heads/$branch:refs/heads/$branch"
    ns_log S1.6 "PR #$num: rebased onto fresh $NS_REPO_DEFAULT_BRANCH, re-gated green, pushed"
    printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$branch" "rebased" "gate green" "-" >> "$LOG_DIR/prs.tsv"
    git checkout -q "$NS_REPO_DEFAULT_BRANCH"
}
```

- [ ] **Step 5: Run the harness — section 13 must pass**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
```

Expected: `ALL HARNESS TESTS PASSED` including `S1.6 re-gate is report-only; ...`. If sections 8 or 10 broke, the `verify_red` edits changed a line the gate-order or did-not-run guards anchor on.

- [ ] **Step 6: Rehearse a rebase conflict for real**

The conflict path is the one that must never force, and it is the one no unit test reaches. Manufacture one.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo
git fetch origin && git checkout -B nightshift/conflict-probe origin/main
printf 'CONFLICT-SIDE-A\n' >> jac/jaclang/utils/treeprinter.jac
git commit -aqm "probe: side A"
git checkout -q main && printf 'CONFLICT-SIDE-B\n' >> jac/jaclang/utils/treeprinter.jac
git commit -aqm "probe: side B (local main only)"
cd /Volumes/ExtremePro/JaseciLabs/NightShift
NS_DRY_RUN=1 bash -c '. lib/common.sh; ns_load_config; ns_load_env
  . lib/cimirror.sh; . lib/verify.sh; . lib/inventory.sh
  git -C "$REPO" branch -f origin/nightshift/conflict-probe nightshift/conflict-probe 2>/dev/null
  inventory_refresh 999 nightshift/conflict-probe' 2>&1 | tail -10
```

Expected: `rebase conflict ... left exactly as it was, needs a human. Nothing was forced.`, a `conflict` row in `prs.tsv`, and — critically — `git -C work/repo status` clean with no rebase in progress. Clean up:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo \
  && git rebase --abort 2>/dev/null; git checkout -qf main \
  && git reset --hard origin/main && git branch -D nightshift/conflict-probe
```

- [ ] **Step 7: Commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add lib/verify.sh lib/inventory.sh bin/test-harness.sh
git commit -m "S1.6 rebases, re-gates and pushes each open PR

The half that makes the inventory maintenance rather than reporting: align to
the remote (a force-push of a stale local copy would delete commits pushed by
anyone else), rebase onto fresh main, re-run the local mirror and gate, push
with --force-with-lease. A rebase conflict is reported and abandoned -- never
forced, never handed to an agent.

verify_branch gains an explicit on_red mode because the S4 default is wrong
here: verify_red bumps attempts (auto-rejecting at 2) and deletes the branch,
and [jobs.contribution] validates WHOLE-REPO state, so one upstream breakage
would red every open PR identically and auto-reject the entire ledger in two
nights. Report mode logs and moves on. The mode is forwarded explicitly to all
eight call sites -- bash's dynamic scoping would have made it work by accident.

A PR already on top of main and unchanged skips the ~40min re-gate entirely,
which is what keeps a converged inventory cheap."
```

---

### Task 8: Wire S1.6 into the night, rehearse it dry, and close the two carry-forwards

**Files:**
- Modify: `bin/nightshift.sh` (source `inventory.sh`, add the stage and an `inventory` command)
- Modify: `lib/verify.sh` (the misleading setup-vs-test message, followups 4.2)
- Modify: `bin/test-harness.sh` (section 14)

**Interfaces:**
- Produces: `nightshift.sh inventory` — runs S1.6 by hand, with the same live-run refusal as `mirror`.
- Produces: the `S1.6` stage between S1 and S2.

- [ ] **Step 1: Source `inventory.sh` and add the stage**

`bin/nightshift.sh`, after `. "$NS_ROOT/lib/cimirror.sh"`:

```bash
. "$NS_ROOT/lib/inventory.sh"
```

`lib/inventory.sh` uses `verify_branch` and `ns_theme_for_branch`, so it must be sourced after `lib/verify.sh` — it already is, since `cimirror.sh` is last today.

In `ns_run_inner`:

```bash
    ns_stage S0 preflight_main
    ns_stage S1 sync_main
    # S1.6 runs BEFORE any new work (spec section 4): existing PRs outrank fresh findings, which
    # is what makes the inventory converge rather than grow.
    ns_stage S1.6 inventory_main
    ns_stage S2 tier1_main
```

- [ ] **Step 2: Add the manual `inventory` command**

In `usage()`:

```
       nightshift.sh inventory                  # run S1.6 by hand (list/rebase/re-gate open PRs)
```

In the `case`, modelled on the `mirror` arm — it checks out branches in `$REPO`, so it must refuse to run under a live night for exactly the same reason, and must not take the lock (there is no EXIT trap on this path to release it):

```bash
    inventory)  mkdir -p "$LOG_DIR"; ns_load_env
                if [ -f "$LOCK_DIR/pid" ]; then
                    holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
                    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
                        ns_die "$EX_LOCK" "a nightly run (pid $holder) is live; 'inventory' would git-checkout in $REPO underneath it. Wait for it to finish, or stop it first."
                    fi
                fi
                inventory_main ;;
```

- [ ] **Step 3: Close followups 4.2 — the misleading setup-vs-test message**

`suite_test_raw` classifies a failed command as setup-vs-test by the substring `jac test`, and `[jobs.compiler]`/`[jobs.runtime]` register `cd jac && … jac test …` as one command — so a failing `cd jac` matches and is reported as a test failure. It is not a false green (`assert_suite_ran`'s session count still aborts), but the operator is told the wrong thing. The honest fix is the message, not the classification: name the command in the death.

In `assert_suite_ran`, the session-mismatch arm:

```bash
        *) ns_die "$EX_BUG" "$where $suite: expected $want test-runner session(s), one per test command in [jobs.$suite], but $(basename "$raw") has $sessions. Refusing to score a suite that did not run as a pass. The last failing command in this job was: ${CIMIRROR_FAILED_CMD:-(none — every command exited 0, so the runner started fewer times than there are test commands)}. Note that a compound command like 'cd jac && … jac test …' is classified as a TEST command by substring, so a failing 'cd jac' arrives here rather than as a setup failure — check the cwd and paths in config/ci-mirror.toml." ;;
```

Add a line to harness section 10 asserting the message names the command:

```bash
grep -q 'The last failing command in this job was' lib/verify.sh \
    || fail "assert_suite_ran's session-mismatch death no longer names the failing command; a failing 'cd jac' is classified as a test command and the operator is told the wrong thing"
```

- [ ] **Step 4: Assert the structural absence of a repair loop**

The clearest statement that the CI repair loop was not built is that the inventory cannot invoke an agent at all. Append section 14 to `bin/test-harness.sh`:

```bash
echo "== 14. S1.6 runs no agent: the CI repair loop is deliberately absent =="
# Spec 8.1 describes rerunning failed jobs then up to two Opus repair attempts. It is NOT built --
# see the plan's 'deliberately not built'. This is the structural version of that decision: the
# inventory has no path to a model at all, so a red PR can only ever be reported. A future repair
# loop has to delete this assertion on purpose, in a commit that says so.
case "$(grep -cE '\$NS_PATHS_CLAUDE|claude |run rerun' lib/inventory.sh || true)" in
    0) : ;;
    *) fail "lib/inventory.sh invokes an agent or reruns CI jobs; the repair loop is out of scope for this plan and must be added deliberately, not smuggled in" ;;
esac
# S1.6 must precede S2 in the night, or existing PRs stop outranking fresh findings
inv_ln="$(grep -n 'ns_stage S1.6 inventory_main' bin/nightshift.sh | cut -d: -f1)"
t1_ln="$(grep -n 'ns_stage S2 tier1_main' bin/nightshift.sh | cut -d: -f1)"
case "$inv_ln$t1_ln" in
    "") fail "could not find the S1.6 / S2 stage lines in bin/nightshift.sh -- the ordering check would be vacuous" ;;
esac
[ "$inv_ln" -lt "$t1_ln" ] \
    || fail "S1.6 (line $inv_ln) must run BEFORE S2 (line $t1_ln): existing PRs outrank new work, or the inventory never converges"
echo "S1.6 is agent-free and runs before new work"
```

- [ ] **Step 5: Rehearse the whole ship path dry, and prove nothing escaped**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
BEFORE="$(/opt/homebrew/bin/gh pr list --repo jaseci-labs/jac --author @me --state all --limit 100 --json number | tr -d ' \n' | wc -c)"
NS_DRY_RUN=1 bin/nightshift.sh inventory 2>&1 | tail -30
AFTER="$(/opt/homebrew/bin/gh pr list --repo jaseci-labs/jac --author @me --state all --limit 100 --json number | tr -d ' \n' | wc -c)"
[ "$BEFORE" = "$AFTER" ] && echo "no PR was created, edited or closed" || echo "PR SET CHANGED — investigate"
grep -c '^\[DRY\]\|\[DRY\]' "logs/$(date +%F)/run.log" || true
```

Expected: the PR set is unchanged, and every mutating call appears as a `[DRY]` line. Then the live read-only run, which is the real thing:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/nightshift.sh inventory 2>&1 | tail -30
cat "logs/$(date +%F)/prs.tsv" 2>/dev/null || echo "(no open PRs yet)"
```

- [ ] **Step 6: Run the full harness**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
```

Expected: `ALL HARNESS TESTS PASSED` with sections 11-14 present.

- [ ] **Step 7: Mutate the four new tripwires**

Reading is not evidence, and in Plan 1 mutation caught weak guards twice where reading did not. Each of these must turn the harness red:

| Mutation | Must fail |
|---|---|
| delete the `nightshift/` prefix argument in `inventory_main`'s `cigate prs` call | section 13, "would rebase and force-push a human's branch" |
| change `verify_branch "$branch" "$theme" report` to drop the third argument | section 13, "does not re-gate in report mode" |
| drop one `"$on_red"` from a `verify_red` call inside `verify_branch` | section 13, "do not forward $on_red" |
| replace the `case "$pr_url"` shape check in `ship_open_pr` with `[ -n "$pr_url" ]` | section 12, "no longer asserts the SHAPE of the URL" |
| add `ns_log S1.6 "$($NS_PATHS_CLAUDE --version)"` to `lib/inventory.sh` | section 14, "invokes an agent" |

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git stash list >/dev/null   # work on a clean tree; apply each mutation, run, revert with git checkout --
```

Any mutation that stays green means the assertion is decorative — fix the assertion before committing.

- [ ] **Step 8: Commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add bin/nightshift.sh lib/verify.sh bin/test-harness.sh
git commit -m "Wire S1.6 into the night; assert the repair loop's absence structurally

S1.6 runs between S1 and S2, before any new work, and the harness asserts that
ordering: existing PRs outrank fresh findings or the inventory never converges.
Adds 'nightshift.sh inventory' for hand-running it, with the same
refuse-under-a-live-night check 'mirror' has, since both git-checkout in
work/repo.

The CI repair loop is deliberately not built, and the harness now enforces that
by structure rather than by comment: lib/inventory.sh may not reference an agent
binary or rerun a CI job, so adding one is a deliberate act in a commit that
says so.

Closes the followups' misleading setup-vs-test message: a compound
'cd jac && … jac test …' is classified as a test command by substring, so a
failing 'cd jac' reaches assert_suite_ran's session-mismatch death -- which now
names the command instead of leaving the operator to guess."
```

---

## Deliberately NOT built

Named on purpose, with the trigger that should change the answer.

**1. The CI repair loop (spec section 8.1) — the biggest cut in this plan.** The spec describes: poll checks for ~35 min → on red, `gh run rerun --failed` once → then up to two Opus repair sessions → then close the PR, delete the branch, `failed_ci`, auto-reject after two lifetime CI failures. None of it is built.

The reasoning is that its whole justification is conditional on a frequency nobody has measured. The local mirror now replicates every Blacksmith-only job faithfully and is green before any PR is opened, so a red PR is supposed to be the *exception* — and each repair iteration costs ~35 min of an 8-hour night, on a machine that also has to run a 100-minute sharded audit. Building a three-stage repair pipeline for an event that has happened **zero** times is the definition of speculative machinery, and it is machinery with teeth: an auto-reject rule fed by an unproven failure signal is how a whole ledger gets buried by one upstream breakage.

What is built instead: `cigate.jac` judges the PR against main's baseline on the *next* night, and a red PR is reported in the digest with the failing check names. Nothing waits, nothing repairs, nothing is auto-rejected.

**Upgrade path and its trigger:** when `prs.tsv` shows `ci-red` rows appearing regularly — say three PRs red-vs-baseline across a week, on checks the local mirror covers — the mirror has a specific fidelity gap, and the *first* response is to close that gap in `config/ci-mirror.toml`, not to build a repair loop. Only if red PRs persist on checks the mirror genuinely cannot run locally (network-dependent jobs, upstream-secret-dependent jobs) does the repair loop earn its cost, and it should then start with the free half — a single `gh run rerun --failed` as a flake filter — and stop there until data justifies the agent sessions.

**2. Labelling PRs upstream.** The spec says "label the PR". Labelling requires triage permission and the harness has `pull` only (Task 1 measures this rather than assuming it), and `ci.yml` triggers on `labeled`, so a cosmetic marker would re-fire a 35-minute CI run. The verdict is recorded in `$LOG_DIR/prs.tsv` and `warnings.txt` instead, where the operator actually reads it. Add labelling if the harness is ever granted triage **and** the `labeled` trigger is gone from `ci.yml`.

**3. A fork-target fallback for `gh pr create`.** Task 1 measures whether upstream PRs work before anything is built on it. If they work, no fallback is written — a second code path for a branch measured not to exist is exactly what the ladder forbids. Task 1 Step 9 carries the exact three-line change to make if the measurement comes back the other way.

**4. Polling a PR's CI within the same night.** The spec's shape implies waiting for checks after opening a PR. Reading the verdict on the *next* night gives the same information, one night later, for one API call instead of ~35 minutes per PR. Add polling only if a night ever needs to act on its own PR's CI result — which, with no repair loop, it does not.

**5. The human merge/close signal into `dataset/reviews.jsonl`.** `dataset_record_review` is called from `promote` / `discard`, and those stop being the normal path the moment S5 opens PRs by itself — so the highest-quality supervision signal (a human accepting or rejecting the work) will stop being captured. The fix is a terminal-PR sweep in S1.6: for each ledger row with status `shipped` and a `pr_url`, look up the PR's state, and on `MERGED` / `CLOSED` record a review row and settle the ledger. Not built now because there is not yet a single merged Nightshift PR to learn from, and the sweep needs a ledger query (`shipped rows with a pr_url`) that does not exist. **Trigger: the first PR that a human merges or closes.**

**6. `refactor(repo):` as the PR title scope.** `render_draft`'s default title is `refactor(<package>): …` and `ship.sh` passes `package=repo` since the audit went whole-repo, so upstream reviewers see `refactor(repo):`. It is odd but harmless, and the right fix is the task name (`refactor(dead-code): …`), which belongs to Plan 2's task registry. Left alone rather than guessed at.

**7. Scope-checking commits that someone else pushed to a PR branch.** S1.6 re-gates with the original theme, which describes what Nightshift planned — so a commit a human added to the branch passes the mirror, the type-check and the suites, but is not scope-checked. `ponytail:` known ceiling; the upgrade is to refuse to refresh a branch carrying a commit the harness did not author. Not built because it has not happened and the gate below it is not weak.

**8. A second CI run per PR from the fragment renumber.** The release-note fragment must carry the PR number, and the number does not exist until the PR does, so the rename is a second push and CI fires twice. Avoidable only by not requiring the fragment or by predicting the PR number — both worse. Accepted and documented at the call site.

---

## Where this leaves the remaining plans

Plan 3 stops at "a green branch becomes a maintained draft PR upstream". Two subsystems the spec assigns elsewhere now have concrete inputs waiting for them:

- **Plan 4 (reactive pass + digest)** inherits `$LOG_DIR/prs.tsv` — `number, branch, action, detail, url`, one row per PR event — which is exactly the spec's section 14 "PR table" and "PR inventory section". Until it lands, the bad rows reach the operator through `ns_warn` → `warnings.txt`, which `sendmail.jac` already renders verbatim. Plan 4 also owns the `ERROR_STAGE` / `FATAL_REASON` consumption from followups section 5.
- **Plan 2 (task registry)** owns `fragment_kind`. `ns_renumber_fragment` is already kind-agnostic, so Plan 2 only has to make `check_scope.jac`, `render_draft.jac` and the theme agree on the kind — the third site that used to have to change in lockstep is gone.
