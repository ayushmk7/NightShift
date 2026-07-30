# Cross-plan reconciliation (binding)

Date: 2026-07-30

Plans 2-5 were written in parallel by four agents, none seeing the others. A cross-plan review found
nine blocking conflicts. **This file overrides the plans wherever they disagree with it.** Read it
alongside whichever plan you are implementing.

## Stage order — settled

```
S0 preflight → S1 sync → S1.5 reactive poll → S1.6 PR inventory
  → S3 (S3a reactive apply → carry-over → S3b cycle task) → S4 verify → S5 ship → S6 digest (EXIT trap)
```

There is **no S2**. Tier-1 was retired 2026-07-30. Any plan text ending a stage block with
`ns_stage S2 tier1_main` is stale — anchor inserts on `ns_stage S3 tier2_main` instead.

## Harness section ranges — settled

All four plans append "section 11". Shipped ends at §10. Binding allocation:

| Plan | Sections |
|---|---|
| 2 (task registry) | 11-14 |
| 3 (ship path) | 15-18 |
| 4 (reactive + digest) | 19-23 |
| 5 (migration) | 24 |

## Blocking conflicts and their resolutions

**B1 — Plan 4 Task 4 must be re-derived, not patched.** It was written against the *shipped*
`lib/tier2.sh`, not Plan 2 Task 9's output, despite naming Plan 2 a hard dependency. Four concrete
breaks: it calls `tier2_audit_shard` with a different signature; it passes `$NS_AGENT_PONYTAIL_MODE`,
a key Plan 2 **deletes** (unbound under `set -u`); it omits `coverage_evidence`, so `{coverage_evidence}`
reaches Opus verbatim; and it calls `parse_result findings` with no task/scoring args against Plan 2's
`require(len(args)==4)`, so **all four reactive lenses fail to parse**. It also replaces `tier2_main`
wholesale, reverting Plan 2 Task 9.
**Resolution:** keep Plan 4's `(name, scope, task)` argv — it is the better shape — but rebase its
Steps 1 and 4 onto Plan 2's function bodies. Plan 4 yields on everything else.

**B2 — reactive branch names must not break the S4 task resolver.** Plan 4's
`nightshift/$NS_DATE/reactive-<hint>` prefix defeats Plan 2's prefix-based task resolution, which is
the sole input to `protect_unless` — every reactive branch would fail S4, and `reactive-coverage-*`
would never get its `tests/**` exemption. **Plan 4 yields:** slug is `<task>-reactive-<hint>`.

**B3 — one PR artifact, JSONL.** Plan 3 writes `prs.tsv`; Plan 4 reads `prs.jsonl` **and**
`pr-inventory.jsonl`, and its readers return `[]` for a missing file — so the digest's PR table would
render empty every night, forever. That is the "did not run scored as passed" class in the one
unattended channel. **Plan 3 yields on format:** emit `prs.jsonl` and `pr-inventory.jsonl` via an
`ns_jac` projection, with `task` from `ns_task_of_branch`. **Plan 4 must positively assert the file
existed** rather than defaulting to `[]`.

**B4 — no tier-1 arm in the theme resolver.** Plan 3 Task 4 reintroduces `ns_is_tier1_branch`, which
the shipped harness §9a explicitly fails on, and returning `-` re-opens the scope-containment hole
`lib/promote.sh` documents. **Plan 3 yields:** resolver is logs → drafts → `ns_die`. Drop its §9a
rewrite entirely.

**B5 — see the stage order above.** Both Plans 3 and 4 anchor their insert on a retired stage and
neither mentions the other's; block-replacement would drop one.

**B6 — do not rename `findings.json` / `selection.json`.** Plan 4's `-cycle` suffix silently kills
dataset capture: `lib/dataset.sh:18` and `scripts/dataset.jac:70,88` hardcode the names, and
`dataset_record_night` returns 0 recording nothing. This repo already fixed this exact bug in
`ffdf856`/`e0db4a3`. Keep the names; distinguish phases by a field inside, not the filename.

**B7 — carry-over belongs to the cycle phase only.** Composed naively, `tier2_select reactive` runs
first, packs yesterday's carry-over into the reactive phase (spec §4 says reactive outranks
carry-over), then overwrites `carryover.json` with reactive deferrals — consuming yesterday's
carry-over twice in one night.

**B8 — Plan 2 Task 6 must update harness §4.** It moves `check_scope check` to `len(args)==5` while
shipped `bin/test-harness.sh:43-46` calls it with 4. Also add `sys.exit(2)` to `check_scope.jac`'s
usage arm: it currently exits **0**, so any future arity drift makes the S4 scope gate report
"contained".

**B9 — the reset must not wipe keys Plans 2-4 depend on.** Plan 5 Task 7 Step 5 rewrites
`state.json` with a literal `printf`, destroying Plan 2's `cycle_index` (recoverable) and Plan 4's
`last_merge_poll`, whose fallback is *yesterday* — silently collapsing the merge window and never
reactively auditing the gap. **Use per-key `state-set`.** Task 8 also deletes `nightshift/drafts`,
which is where Plan 3's theme resolver looks second. And Task 7 Step 4's "confirm zero OPEN PRs"
holds only until Plan 3 Task 4 ships — **run the reset before Plan 3 opens any PR.**

## Stale references to strike

- **Plan 5 Task 1 is obsolete in full** — all three premises false (`[jobs.fmt_autofix]` deleted,
  `lib/tier1.sh` gone, harness §6 repurposed). Its grep still matches `[jobs.byllm]`, which an
  operator could misread as confirmation. Replace with a one-line note that the decision landed.
- **Plan 5 Task 2 Step 3 is dead work** — it targets `subprocess.run` calls in
  `scripts/render_draft.jac` that went with `git_report`. The file imports no `subprocess`.
- Plan 2 `:1604` anchors on `ns_is_tier1_branch` in `lib/common.sh`; that line is now inside
  `ns_load_config`.
- Plan 4 `:1321` carries forward `# … tier-1 still ships`.
- Pre-existing dead arms the plans build on: `lib/ship.sh:27-33`'s `theme = "-"` tier-1 branch, and
  `scripts/check_scope.jac:7`'s "(tier-1 uses this to revert formatter overreach)". Also
  `check_scope.jac`'s `protected` verb has had zero callers since tier-1 retired.

## Tripwires that do not bite — must be fixed when their task lands

- **Plan 3 §14** (S1.6-before-S2 ordering): guards only when **both** line numbers are empty; the
  realistic failure is exactly one. Post-retirement `t1_ln` *is* empty, so it falls through to
  `[ "93" -lt "" ]` — a malformed comparison, not a verdict. Re-anchor on `ns_stage S3 tier2_main`
  and guard each variable separately.
- **Plan 3 §12(a)** (PR URL): a source grep, not a behavioural test. An impl with the pattern in a
  `case` arm lacking a rejecting `*)` satisfies it while recording an empty URL.
- **Plan 5 Task 5 Steps 1 and 3**: both `echo "FAIL: …"` and never exit nonzero. Step 3 guards what
  Plan 5's own header calls the single largest risk in the plan — a gate green because it ran the
  old binary off the still-mounted volume. Both must `exit 1`.

## Ownership of duplicated work

- **`ns_renumber_fragment` belongs to Plan 3** (`lib/ship.sh`), not Plan 2. Plan 3's is the superset:
  shared by ship and promote, handles `fragment == ""` (which Plan 2's own
  `[tasks.coverage].fragment = ""` produces), warns rather than dies on an untracked fragment, and
  routes through `ns_git_push` so `promote` is dry-runnable. **Skip Plan 2 Task 5 Step 6.**
- **Plan 3 Task 7 must land after Plan 2 Task 7**, or its `verify_red`/`on_red` count assertion fails.
  Note Plan 3 says "all eight `verify_red` calls"; shipped has **seven** — eight only after Plan 2
  Task 7.

## Correction to record

Plan 2 claims four times that `protect_unless` "never leaves the config file and `check_scope.jac`".
`scripts/config.jac:15-26` flattens `[tasks]` into `NS_TASKS_COVERAGE='{…"protect_unless":[…]}'`. The
property still holds — `ns_load_config` uses a bare `eval`, not `export`/`set -a`, so it is a shell
variable only and never reaches the agent — but the stated justification is wrong, and it breaks the
day anyone adds `set -a`.

## Implementation order (binding)

1. **Plan 3 Task 1** — the `gh` probe. Read-only, and a refusal re-plans the whole ship path.
2. **Plan 4 Tasks 1-2** — SMTP receipt, `FATAL_REASON`/`ERROR_STAGE`. Independent of everything, both
   unmet today (`bin/nightshift.sh` clears `FATAL_REASON` but not `ERROR_STAGE`).
3. **Plan 5 Tasks 7-8** — the reset, before Plan 3 opens any PR. Fix Step 5 to per-key `state-set`
   first.
4. **Plan 2 Tasks 1-9** — the substrate. Fold B8 into Task 6; skip Task 5 Step 6.
5. **Plan 3 Tasks 2-8** — B4 removed, §9a rewrite dropped, Task 7 hand-merged onto Plan 2's stage-1
   block, Task 8 re-anchored.
6. **Plan 4 Tasks 3-7** — Task 4 re-derived (B1); Tasks 4-5 also fix B6 and B7.
7. **Plan 5 Tasks 2-6, 9** — migration and cutover last, so the new tree receives finished code.
   Harden Task 5 Steps 1 and 3.
