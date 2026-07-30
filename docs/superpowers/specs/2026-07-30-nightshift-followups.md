# Nightshift v2: carry-forward items after Plan 1

Date: 2026-07-30
Source: the Plan 1 execution ledger, preserved here because the workspace is scratch and git is the record.

Plan 1 (foundations) is complete and merged. These are the items it deliberately did not resolve,
with the evidence behind each so nobody re-litigates them from scratch.

## 1. Decisions the human owner still owes

**Tier-1's formatting scope is arbitrary.** `[jobs.fmt_autofix]` formats only `jac/jaclang/byllm/*.jac`.
That directory choice is a leftover of the package rotation Plan 1 deleted, and nothing justifies it now.
The options are not equal:

- **Keep the narrow scope.** Smallest risk. The directory remains meaningless.
- **Retire tier-1.** Upstream's `main` carries ~259 whole-repo formatting violations and CI only checks
  formatting repo-wide on `push`, so upstream evidently tolerates them. A 259-file formatting PR is
  unmergeable; a byllm-only one is noise.
- **Diff-scope it like CI.** Structurally awkward: tier-1 runs *before* the agentic tier, so there is no
  diff to scope against yet.

A fourth option worth considering: fold formatting into each theme's own branch, so fmt fixes ride along
with changes that were going to touch those files anyway. Strictly less machinery than a standalone pass.

Plan 1's tier-1 release-note fragment fix was verified to survive **all three** outcomes: the fragment path
derives from the actual diff via `render_draft frag`, never from `fmt_autofix`'s scope.

## 2. Open questions only a live night can answer

- **Does 2-concurrent Opus tripping provider rate limits make `.session-limit` the normal path
  rather than the exception?** If so, `[shards].concurrency` drops to 1 and the audit phase roughly
  doubles in wall time. Config knob, not a code change.
- **Whether to `break` after a second consecutive session limit** instead of collapsing to serial.
  The collapse burns one guaranteed-failing session plus a repair prompt per remaining shard, up to
  8 `FAIL` rows. `tier2_apply` already breaks; the audit driver does not.

## 3. Assigned to Plan 2 (task registry)

- `lib/promote.sh:77` hardcodes `0000.refactor.md`, so the PR-number rename silently no-ops for the
  other four fragment kinds. A `LATENT COUPLING` note is in place at both sites.
- Nothing sets `fragment_kind` anywhere; `check_scope.jac:23` honours it while `render_draft.jac`'s
  `frag_for_report` and `promote.sh` hardcode `refactor`. Consume it or delete it.
- `COLLECTION_FLOOR = 0.75` is held up by `selector.jac`'s `import_allowlist` tuning, not by anything
  structural. Widening that allowlist would make `test_byllm.jac` (100 of byllm's 219 collected items,
  46%) vestigially deletable and break the floor. Cross-reference comments are at both sites. The exact
  upgrade is to subtract the item count of the test files a theme actually deletes.
- Concurrent audit sessions share `$REPO/.jac`. Safe today only because the audit allow-list has no
  Edit/Write and `tier2_apply` is serial — an invariant nothing enforces.

## 4. Assigned to Plan 3 (ship path / CI repair)

- `[jobs.contribution]` reds a branch for **whole-repo** state: `validate_docs_code.jac` (852 blocks)
  and the bun/zig version lockstep validate repo-wide, not the branch diff. An upstream-introduced
  breakage there reds every queued branch and auto-rejects the whole ledger after two nights. Green on
  `main` today; documented with an `ns_warn` at `lib/verify.sh`.
- `suite_test_raw` classifies setup-vs-test commands by the substring `jac test`, but
  `[jobs.compiler]`/`[jobs.runtime]` register `cd jac && … jac test …` as one command, so a failing
  `cd jac` is misclassified. Not a false green — the session-count check still aborts — but the message
  misleads.

## 5. Assigned to Plan 4 (digest)

- **The operator's only unattended channel cannot say why a night died.** All `ns_die` sites in the
  gate exit `EX_BUG=70`, and the digest reports only the stage name. Plan 1 shipped a stopgap:
  `ns_die` writes `$*` to `$LOG_DIR/FATAL_REASON` and `ns_on_exit` surfaces it. The digest should
  consume it properly.
- `ERROR_STAGE` is not cleared on a same-night re-run (`FATAL_REASON` is), so a green re-run still
  reports a stale `error_stage`. One line: `rm -f "$LOG_DIR/ERROR_STAGE"` beside the `FATAL_REASON` clear.

## 6. Assigned to Plan 5 (migration)

- `render_draft.jac`'s `git_report` hardcodes `main...HEAD` instead of `$NS_REPO_DEFAULT_BRANCH`.
  It fails closed (both `subprocess.run` calls use `check=True`, so the night aborts rather than
  producing an empty file list), but tier-1's fragment path now leans on it.
- **Nights are currently disabled** via `~/.nightshift/DISABLE`. Re-enable only after the Plan 5 cutover.

## 7. Dropped, with reasons — do not revisit

- **`TEST_ENV=true`** is vestigial upstream. `grep -rn TEST_ENV` over the target repo hits only
  `ci.yml:563,605`; nothing reads it.
- **The docs-corpus CI step** needs no separate mirror entry: `jac/tests/cli/test_docs_content.jac` and
  `test_guide_docs.jac` live under `jac/tests/`, which `[jobs.runtime]` already collects.
- **`ns_jobs_wait`'s multi-digit-zero gap** (`"00"`) is unreachable: TOML forbids leading zeros in integers.
- **Shard coverage of `jac/tests`, `examples`, `editor`, `launcher`, `native`** is intentionally absent,
  matching the spec's stated "deep, not exhaustive" ceiling, and carries a `ponytail:` upgrade note.

## 8. The defect class this plan kept finding — read before writing a gate

**"Did not run" scoring as "passed."** Seven separate instances were found across seven tasks, every one
in the gate, none caught by tests that were passing:

1. Mirror `compiler`/`runtime` commands carried CI's `working-directory: jac` while the executor ran from
   the repo root, so all three died on `File not found` — **4644 tests** — and a `FAILED `-line parser
   cannot distinguish "runner never started" from "clean run". It would have been frozen into the baselines.
2. `for x in $(reader)` swallowing an rc=128 reader failure, skipping the whole test gate.
3. A `collected: 0` baseline letting a branch collecting 3-of-200 pass.
4. A job printing "skipping" reported as `✓` in the PR body.
5. The fmt gate's `|| true` wrapping the merge-base computation, so a bad branch name read as "no files changed".
6. Reader failures returning green because process substitution discards exit status.
7. `[jobs.contribution]`'s `if git … | grep …` reporting clean when the git command itself failed.

The cause is structural: this gate is assembled from commands that exit 0 for "nothing to do" and 0 for
"all good", and nothing forces the distinction. The countermeasure that worked is a **positive assertion
that the work happened** — `assert_suite_ran`, `assert_check_ran`, and the collected-count floor — rather
than inferring success from an absence of failure lines.

A sibling class recurred just as often: **an assertion that cannot fail.** A `grep` comparing empty to
empty; a test asserting "nonzero" that a `return 1` satisfies while meaning something else; a regression
test containing the very bug it guards against; and a verification shim that drifted from the interface it
stood in for and manufactured a green. Mutation-test any tripwire you add — reading it is not enough.
Both times a guard here was found weaker than it looked, mutation found it and reading did not.
