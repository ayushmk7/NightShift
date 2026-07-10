# Step 6 — S2 Tier-1 deterministic clean

## Goal

`lib/tier1.sh`: the no-LLM, near-zero-risk pass — `jac clean --cache`,
`jac format .`, `jac lint . --fix`, double `pre-commit`, then commit to
`nightshift/<date>/autofix` **only if the diff is non-empty**, revert any formatter
overreach into protected paths, synthesize the agent-less report for the draft, and
queue the branch for the same S4 gate as everything else. Implements TechnicalPRD
§7-S2 (plus the protected-path revert that the PRD's §9 guardrail implies).

## Prerequisites

Steps 2–5. `pre-commit` is installed via pipx (step 1.2) and run from PATH — no venv.

## Files created

```
~/nightshift/lib/tier1.sh
```

## Full implementation

### `lib/tier1.sh`

```bash
# shellcheck shell=bash
# lib/tier1.sh — S2 (TechnicalPRD 7-S2): deterministic clean, no LLM, near-zero risk.

tier1_main() {
    local branch="nightshift/$NS_DATE/autofix"
    cd "$REPO"
    git checkout -B "$branch" "$NS_REPO_DEFAULT_BRANCH"

    "$NS_PATHS_JAC" clean --cache || true         # stale-bytecode footgun (upstream-documented)
    "$NS_PATHS_JAC" format .                      # respects .jacignore
    "$NS_PATHS_JAC" lint . --fix || true

    # The formatter runs repo-wide; protected paths must never ship edited (PRD 9).
    local protected
    protected="$(git diff --name-only | ns_jac check_scope protected "$CONFIG")"
    if [ -n "$protected" ]; then
        ns_log S2 "reverting formatter overreach on protected paths"
        echo "$protected" | while IFS= read -r p; do git checkout -- "$p"; done
    fi

    # pre-commit (from PATH, pipx-installed at M0) may self-mutate on the first pass; the second must pass
    pre-commit run --all-files || pre-commit run --all-files

    git add -A
    if git diff --cached --quiet; then
        ns_log S2 "empty diff — nothing to autofix tonight"
        git checkout "$NS_REPO_DEFAULT_BRANCH"
        git branch -D "$branch"
        return 0
    fi
    git commit -m "style: nightly jac fmt + lint autofix (nightshift)"

    # synthesize the agent-less report so S5 can render a draft for this branch too
    ns_jac render_draft git-report "$REPO" "nightly jac fmt + lint autofix" \
        > "$LOG_DIR/report-autofix.json"
    ns_queue_branch "$branch" "-" "$LOG_DIR/report-autofix.json"
    git checkout "$NS_REPO_DEFAULT_BRANCH"
}
```

## Commands

```bash
bash -n ~/nightshift/lib/tier1.sh
```

## Acceptance criteria

- [ ] On a clean repo (nothing to format): stage logs "empty diff", no branch
      survives, `queue.tsv` untouched.
- [ ] With a deliberately mis-formatted eligible `.jac` file: branch
      `nightshift/<date>/autofix` exists with exactly one commit
      `style: nightly jac fmt + lint autofix (nightshift)`, `queue.tsv` gains one
      line, and `report-autofix.json` lists the file with sane LOC numbers.
- [ ] With a deliberately mis-formatted file under `**/tests/**`: that file is
      **reverted** before commit (protected-glob check) and absent from the diff.
- [ ] `work/repo` ends the stage back on `main` in both cases.

## Verification procedure

```bash
cd ~/nightshift
export NS_ROOT="$PWD"; . lib/common.sh; ns_load_config; . lib/tier1.sh
mkdir -p "$LOG_DIR"

# plant format drift in an eligible file and a protected one
cd work/repo
printf 'with entry {\n        print( "x" ) ;\n}\n' >> jac/some_eligible_file.jac   # pick a real path
printf 'with entry {\n        print( "x" ) ;\n}\n' >> jac/tests/fixtures/some_fixture.jac
cd ~/nightshift

tier1_main
git -C work/repo log --oneline "nightshift/$(date +%F)/autofix" | head -2
git -C work/repo diff --name-only "main...nightshift/$(date +%F)/autofix" | grep tests && echo "LEAK" || echo "protected ✓"
cat "$LOG_DIR/queue.tsv"
# cleanup: git -C work/repo checkout main && git -C work/repo branch -D "nightshift/$(date +%F)/autofix"
```

## Notes & traps

- **`jac clean --cache` first**: stale bytecode is an upstream-documented footgun;
  formatting/linting against a stale cache produces phantom diffs.
- The formatter runs repo-wide and *will* touch test fixtures (fixture Jac is often
  intentionally weird — PRD §9). The `check_scope.jac protected` revert loop is the
  guardrail's enforcement, not an optimization. It arrives in step 7's helper but is
  already wired here — if you're building strictly in order, `jac check` the
  `check_scope.jac` from step 7 now or stub the call.
- `pre-commit` runs **twice** by design: the first pass may self-mutate (formatter
  hooks); the second must pass untouched or the stage fails.
- The autofix branch gets no ledger rows (there are no findings) — `queue.tsv`'s
  theme column is `-`, which S4 (step 7) interprets as "skip the theme-allowlist
  check, gates only".
- `report-autofix.json` comes from `render_draft.jac git-report` (step 12's helper).
  Same ordering note as above; the call is one line and can be stubbed with an
  empty JSON object until step 12 if you insist on strict order — but the simplest
  path is: write all Jac helpers (steps 2, 3, 7, 9, 10, 12 code blocks) in one
  sitting, then wire bash stages in order.
