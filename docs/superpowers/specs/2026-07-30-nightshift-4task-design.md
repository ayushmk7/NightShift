# Nightshift v2: four task types, draft-PR output, CI-aware

Date: 2026-07-30
Status: approved design, pending implementation plan

Supersedes the single-pass ponytail-audit design in `docs/PRD.md` / `docs/TechnicalPRD.md` (v0.5)
for stages S3 onward. S0-S2 survive largely intact.

## 1. Goal

Turn the harness from "one ponytail cleanup pass per night against one package" into "one of four
janitorial task types per night against the whole repo, output as draft PRs upstream that are
maintained until they are green or buried."

Four task types:

| Task | Order | What it hunts |
|---|---|---|
| `dead-code` | 1 | Unreachable/unreferenced code, orphaned files, vestigial tests |
| `abstraction` | 2 | Over-abstraction, duplication, reinvented stdlib, needless indirection |
| `maintenance` | 3 | Dep/version drift, TODO/FIXME triage, comment/doc drift, warnings, permanently-skipped tests |
| `coverage` | 4 | Untested behavior: error paths, edge cases, public entry points with no test reference |

Cycle order is deliberate: delete first (shrinks the surface every later task audits), then simplify
what survives, then fix drift in what remains, then write tests against the settled shape. Writing
coverage before deletion means testing code that is about to be deleted.

## 2. Verified facts this design rests on

Established by inspection on 2026-07-30, not assumed. Several contradict the current config.

**Target repo restructured.**
- Upstream is now `jaseci-labs/jac`, not `jaseci-labs/jaseci`. Config is stale.
- `jac-byllm` and `jac-scale` no longer exist as top-level packages. They are `jac/jaclang/byllm`
  and `jac/jaclang/scale`. Only `jac/` and `jac-mcp/` are top-level.
- Release-note fragments moved to `release_notes/unreleased/jaclang/`. The old
  `docs/docs/community/release_notes/unreleased/` path is gone, which also makes the
  `!docs/...` negation in `[protect].globs` dead.
- Fragment filename regex: `release_notes/unreleased/[^/]+/([0-9]+)\.(feature|bugfix|breaking|refactor|docs)\.md$`.
- `scripts/check-release-notes.sh` maps only `jac/jaclang/` -> `release_notes/unreleased/jaclang/`.
  A change confined to `jac-mcp/` or `jac/tests/` needs no fragment.

**Repo size (Jac LOC, measured).** compiler 130,920 - scale 86,566 - jac0core 46,711 -
runtimelib 40,719 - cli 31,630 - byllm 16,732 - project 4,465 - publish 3,022 - langserve 1,730 -
utils 1,486 - lsp 1,182. Total ~365k LOC of Jac across ~1,475 files, plus 1,820 files under
`jac/tests`. The compiler is written in Jac (285 `.jac` files) with only 12 `.zig` files in the
whole repo, which is what makes a coverage-instrumentation pass tractable.

**No coverage tooling exists.** `jac test` has no coverage flag. `--profile` is a config profile,
not a profiler. There is no coverage config anywhere in the repo.

**CI reality.**
- `ci.yml` triggers: `workflow_dispatch`, `pull_request: branches:[main] types:[opened, synchronize,
  reopened, labeled]`, `push: branches:[main]`.
- **No draft guard in any job.** A draft PR runs the full CI. This is the mechanism that satisfies
  "goes through CI without merging."
- Pushing a branch to a fork does NOT trigger `ci.yml` (push is `branches:[main]` only).
- `workflow_dispatch` runs take the `github.event_name != 'pull_request'` branch of every job `if:`,
  so a dispatch bypasses the `needs.changes.outputs.*` path filters and runs the full matrix.
- 13 of ~16 jobs are `runs-on: blacksmith-4vcpu-ubuntu-2404`.
- **Fork CI is not a usable gate.** Empirically confirmed on `ayushmk7/jaseci`: `ubuntu-latest` and
  `macos-latest` jobs (`changes`, `test-native-aarch64`, `test-launcher` x2, `test-native-macos`)
  complete successfully, while every Blacksmith job (`build-jac`, `jac-check`,
  `Contribution Checks`, `test-compiler`, `test-runtime`) sits `queued` indefinitely - one observed
  stuck 2h. The Blacksmith subset is precisely the part that matters for janitorial diffs.
- **Upstream CI is red on main right now.** Last five `ci.yml` runs on `jaseci-labs/jac`:
  failure, cancelled, failure, failure, cancelled. Zero passes. "Green" cannot be the bar.
- CI wall time is ~35 min (07:07->07:42, 06:48->07:24 observed). Each fix-and-rerun iteration
  costs ~35 min of the night.
- `jac-check` runs a `jac fmt` autofix bot (`secrets.JAC_AUTOFIX_TOKEN`, `ci.yml:303`) that pushes
  `style: jac fmt autofix` commits to PR branches, gated on same-repo PRs. Fork PRs get no autofix
  and instead hit the hard failure at `ci.yml:342`.

**Permissions.** `jaseci-labs/jac`: `{admin:false, push:false, pull:true}` - no webhook possible, no
direct push. `ayushmk7/jaseci` (the fork): `admin:true`.

**Test gate timing.** From real run logs: the jac suite takes 21-43 min per run; the flaky retry
doubles it. On 07-21 S4 burned 2h and shipped nothing; 07-23 the same. Both baselines
(`state/test-baseline/jac.json`, `jac-byllm.json`) predate the restructure and are stale.

**Missed nights.** No run dir for 2026-07-28, 07-29, 07-30. Last real run: 07-27.

## 3. Task registry

Today `prompts/audit.md` and `prompts/apply.md` are singletons and `lib/tier2.sh` hardcodes one
pass. Four tasks are declared in config; each gets its own audit prompt, and they share one apply
prompt with a per-task rules block injected.

```
prompts/
  audit-dead-code.md      audit-abstraction.md
  audit-maintenance.md    audit-coverage.md
  apply.md                              # shared, with a {task_apply_rules} placeholder
  apply-rules-dead-code.md  ...          # four small snippets
```

Config shape:

```toml
[tasks.dead-code]
order = 1
model = "opus"
model_simple = "sonnet"
ponytail = "full"
scoring = "loc_saved"
fragment = "refactor"

[tasks.abstraction]
order = 2
model = "opus"
model_simple = "sonnet"
ponytail = "full"
scoring = "loc_saved"
fragment = "refactor"

[tasks.maintenance]
order = 3
model = "opus"
model_simple = "sonnet"
ponytail = "full"
scoring = "loc_saved"
fragment = "auto"                 # agent returns the kind, harness validates it

[tasks.coverage]
order = 4
model = "opus"
model_simple = "sonnet"
ponytail = "lite"                 # so it will actually write a test rather than YAGNI it away
scoring = "risk_weighted"
fragment = ""                     # tests-only changes need no fragment
protect_unless = ["**/tests/**", "**/*.test.jac"]
```

### 3.1 Security invariant: `protect_unless` lives in config, never in a theme

The theme JSON is derived from agent output and must be treated as untrusted. A task's permission to
write inside a normally-protected glob therefore comes from `config/nightshift.toml`, keyed by task
name, and `check_scope.jac` reads it from the config file directly with the task name passed as an
argv. An audit session cannot widen its own write scope. This preserves the T1 injection backstop.

### 3.2 Scoring modes

- `loc_saved` - today's behavior: `est_loc_saved * confidence / risk`, budgeted against
  `loc_per_theme` as lines removed.
- `risk_weighted` - for coverage, where the change ADDS lines: `gap_severity * confidence / risk`,
  with `est_loc_added` budgeted instead.

## 4. Night shape

Window: **23:00 to 07:00**, 8h hard ceiling (was 02:00 + 180m).

| Stage | Purpose |
|---|---|
| S0 | Preflight, plus missed-night watchdog |
| S1 | Sync fork from upstream `jaseci-labs/jac` |
| S1.5 | Merge poll: `gh pr list --state merged --search merged:>=<last-run>` -> changed-file set |
| S1.6 | **PR inventory maintenance** (section 9) - highest priority |
| S2 | Tier-1 deterministic autofix |
| S3a | **Reactive pass** - all 4 lenses over the merged-PR file set |
| S3b | **Cycle task** - carry-over deferred themes first, then tonight's task |
| S4 | Local CI mirror + verify gate, fail-closed, per branch |
| S5 | Push branch, open draft PR upstream, write draft `.md`, ledger |
| S6 | HTML digest with finding detail |

**No theme cap.** Selection is score-ordered and clock-bounded. Anything that does not fit is
recorded `deferred` in the ledger with its task, and is packed **first** on the following night,
before that night's own task. Work therefore resumes across nights while the cycle still advances.

**Priority order within a night:** S1.6 (existing PRs) > S3a (fresh merges) > carry-over > tonight's
cycle task. An active repo day always gets same-night cleanup, and the PR inventory converges rather
than growing.

## 5. Sharded audit

One session cannot audit 365k LOC. Eight LOC-balanced shards, **2 concurrent**, findings merged into
a single selection:

```
1. jac/jaclang/compiler/passes
2. jac/jaclang/compiler          (excluding passes and tests)
3. jac/jaclang/scale
4. jac/jaclang/jac0core
5. jac/jaclang/runtimelib
6. jac/jaclang/cli
7. jac/jaclang/byllm
8. jac/jaclang/{langserve,lsp,project,publish,utils} + jac-mcp
```

Roughly 4 waves x ~25 min ~= 100 min of audit, leaving ~6h for apply, mirror, gate, PR, and CI.
On a session-limit signal, drop to serial and continue rather than aborting the tier (today it
aborts).

`ponytail:` known ceiling - the largest shard is still ~87k LOC, so a night is deep, not exhaustive.
Full-repo coverage emerges over many nights. Upgrade path is more shards, declared in config.

## 6. Output: draft PRs upstream, never merged

Green branch -> push to fork -> `gh pr create --draft --repo jaseci-labs/jac --head ayushmk7:<branch>`.

- Never merges. Never pushes to `main`. The PR is terminal until a human merges it on GitHub.
- Draft `.md` files and the `promote` / `discard` CLI **stay** as a parallel kill path.
- Tier-1 style autofix pass stays.
- Fragment path corrected to `release_notes/unreleased/jaclang/<PR#>.<kind>.md`; the harness (not the
  agent) writes it, kind determined by the task's `fragment` setting. `fragment = ""` means the
  change is tests-only and needs none. `fragment = "auto"` (maintenance) means the agent returns a
  kind and the harness validates it against the filename regex.
- **To verify during implementation:** `gh pr create` against upstream with pull-only permission.
  Expected to work for a public repo from a fork. If it does not, PRs target the fork's `main`
  instead and the digest says so.

## 7. Local CI mirror: the real pre-PR gate

Because fork CI cannot run the jobs that matter, the local mirror is the guardrail. It replicates
the Blacksmith-only jobs exactly:

| CI job | Mirror |
|---|---|
| `build-jac` | zig build, hermeticity smoke (`env -i`, no system Python), e2e jac programs, self-contained `jac test` smoke |
| `test-compiler` | `JAC_TEST_JOBS=auto jac test tests/compiler` **and** `jac test jaclang/compiler/tests` (cross-backend equivalence) |
| `test-runtime` | `JAC_TEST_JOBS=auto jac test tests/ --ignore tests/compiler` |
| `jac-check` | `jac fmt --check --lintfix` over changed `.jac` with CI's exact exclusion regex, **and** the `jir_registry.jac` up-to-date check |
| `contribution-checks` | release-note fragment validation, `pre-commit run --all-files` |

Two traps this closes:

1. **Formatting would kill every PR.** The autofix bot only pushes to same-repo PR branches, so
   nightshift's fork PRs get no autofix and fail hard at `ci.yml:342`. The current tier-1 runs
   `jac format .` / `jac lint --fix`, which is NOT CI's
   `jac fmt --check --lintfix` with the exclusion regex
   `(/fixtures/|^scripts/|/passes/native/llvm/|_err\.jac$|_syntax_err\.jac$)`. The mirror and
   tier-1 must both use CI's exact invocation.
2. **`jir_registry.jac`.** CI verifies it is up to date. Deleting a symbol during a dead-code sweep
   can invalidate it, so the mirror must check it or dead-code PRs fail CI.

Also note the current `pkg_test_raw` omits `jac test jaclang/compiler/tests` entirely, so the
cross-backend equivalence suite has never been gated locally.

**Drift protection.** The mirror does not parse `ci.yml` at runtime. Mirror commands live in
`config/ci-mirror.toml` next to a recorded hash of `.github/workflows/ci.yml`;
`bin/test-harness.sh` fails loudly when the hash changes, forcing a deliberate re-sync.
`ponytail:` cheap drift detector, not a YAML interpreter.

## 8. CI as a baseline-diff gate

Upstream CI is red on main, so a plain "all checks green" gate would reject every PR for other
people's breakage. New `scripts/cigate.jac`, mirroring `testgate.jac`:

- Each night records main's own latest `ci.yml` run conclusion **per check name** as the baseline.
- A nightshift PR is red only on a check that fails on the branch and **passes on main**.
- Exit codes match `testgate.jac`: `0` no new failures, `1` new failures, `2` no baseline (no gate).

### 8.1 CI repair loop

```
push branch -> draft PR (CI fires on `opened`) -> poll checks (~35 min)
  green vs baseline  -> done; PR stays open for human review
  red                -> gh run rerun --failed   (once; free flake filter)
       still red     -> repair session, failing job logs as input -> push
                        (CI re-fires on `synchronize`); max 2 repair attempts
  terminal           -> close PR with an explanatory comment, delete branch,
                        ledger failed_ci (attempts++), auto-reject after 2 lifetime CI failures
```

Because the local mirror must be green before any PR is opened, CI red is the exception, not the
loop's normal path.

## 9. PR inventory maintenance (S1.6)

Runs before any new work, so the inventory converges.

```
gh pr list --repo jaseci-labs/jac --author @me --state open
for each PR:
    git fetch                      # picks up any commits CI pushed to the branch
    rebase onto fresh main
    local CI mirror -> re-gate -> push -> poll CI -> repair loop if red
```

Rebase conflict: label the PR, report it in the digest, do not force. After a few nights the night
is mostly maintaining existing PRs rather than opening new ones, which is the intended steady state.

## 10. Reactive pass (S3a)

Merge detection is **polling**, not a webhook - a webhook needs repo admin on `jaseci-labs/jac`,
which is not available.

```
gh pr list --repo jaseci-labs/jac --state merged --search "merged:>=<last-run>" \
   --json number,title,author,files
```

The union of changed files becomes the audit scope, and **all four lenses** run over it (a small
file set, so four audits is cheap). All authors included, nightshift's own merged PRs included.
Runs before the cycle task so fresh merges are cleaned the same night.

## 11. Coverage: two phases

**Phase A, ships in v1.** `scripts/covmap.jac`: enumerate public symbols with `jac code symbol` /
`jac code map`, resolve which are referenced from test files, emit a ranked untested-symbol report.
The coverage audit prompt consumes it as evidence. A proxy for coverage, not line coverage, but
static, cheap, and available from night one.

**Phase B, parallel track.** Real line coverage as a compiler pass, written in Jac. Lives on a
long-lived fork branch `nightshift/coverage-instrumentation` that the harness rebases onto fresh
main and rebuilds nightly, used **only** to measure and never shipped in a PR. The same work is
opened as a feature PR to `jaseci-labs/jac`; when it merges, the patch branch is dropped.

**Guard.** Because the coverage task may modify existing tests, the gate rejects any diff that
reduces assert count or test count in an existing test file. Weakening a test to make it pass is the
obvious failure mode and would otherwise gate green.

## 12. "Meant to fail a check": harsh rule

Janitorial work is behavior-preserving or it is rejected. There is no agent-asserted "this check
needs updating."

The single exception is the existing `vestigial_deletions` mechanism: the harness independently
verifies, before the agent ever sees the theme, that a test file tests only code the theme is
deleting, and permits a whole-file clean delete (status `D`), never an edit. Everything else means
the theme is not janitorial: reject it and bury the finding.

The coverage task adds tests. It never weakens one.

## 13. Model routing

Static per task (`model`, `model_simple`) plus dynamic routing:

- Audit is always Opus (judgement work).
- The Opus audit tags each finding `complexity: trivial | mechanical | judgement`.
- Apply routes `trivial` and `mechanical` to **Sonnet**, `judgement` to **Opus**.
- Always Sonnet, regardless of task: release-note wording, PR body text, malformed-JSON repair
  re-prompts, formatting/lint CI failures, pure-deletion rebase conflict resolution.
- Escalation is one-way: a Sonnet apply that returns an invalid report or fails the gate retries
  **once on Opus**. Never the reverse.

## 14. Email digest

HTML `multipart/alternative` with a plain-text fallback part:

- Header: the night's verdict, window used, clock consumed.
- Per-task section: what was audited (shards), findings found / selected / deferred, full finding
  summaries inline.
- PR table: number, title, task, link, mirror result, CI check status, repair attempts.
- PR inventory section: rebased, updated, conflicted.
- Failures and deferred work.
- Diffstats inline so triage needs no clicks.

SMTP has never once sent successfully (every reached S6 failed; a 07-15 traceback suggested
DNS/smtplib). Fixing it is in scope: live credential check, explicit socket timeout, verbose
smtplib logging, and a real send verified before the first live night.

## 15. Migration

Everything moves to **`~/nightshift`**. Not `~/Downloads`: that is one of the three TCC-protected
user folders on macOS and would reproduce the permission class the move exists to escape. Home root
is not TCC-protected.

- Fresh clone at `~/nightshift/work/repo`, jac dev binary rebuilt via `scripts/fresh_env.sh`.
- New plist invokes `bin/nightshift.sh run` **directly**. The `osascript` -> Terminal.app
  workaround is deleted.
- `StartCalendarInterval` 23:00, ceiling 8h.
- Every absolute path in `[paths]` updated.

**Overlap.** Both harnesses run briefly, so to stop them fighting over the same fork branches the
**old harness is set to dry-run-only** for the overlap (no push, no PR). Otherwise they collide on
`nightshift/<date>/<slug>`.

**Fork Actions.** Recommend disabling Actions on `ayushmk7/jaseci`. Every fork sync push starts a
`ci.yml` run whose Blacksmith jobs queue forever; three were stuck at the time of writing. The
harness never depends on fork CI.

## 16. Reset to base

Executed only after an explicit second confirmation, with the full branch list shown first.

- Delete on `ayushmk7/jaseci`, local and remote: `nightshift/*`, `prune/*`, `split/*`,
  `chore/dead-code-removal`.
- Reset `work/repo` `main` to fresh upstream.
- Clear ledger, `state.json`, and the `nightshift/drafts` branch.
- **Keep `dataset/*.jsonl`** as a historical record of the old regime. The new schema is written
  alongside, with a `task` field added.

## 17. Also in scope

- Stale config: upstream repo name, rotation packages, `ns_audit_scope`, fragment path, dead
  `docs/**` negation glob.
- Test baselines re-recorded as the **union of two runs on main**, so known-flaky tests stop
  reding branches spuriously (the 07-21 and 07-23 failure mode).
- Missed nights 07-28 to 07-30: diagnose and harden, since a new schedule that silently does not
  fire is worthless.

## 18. Testing

`bin/test-harness.sh` grows:

- Golden audit/apply replay fixtures per task type (4 sets).
- Scope-gate tests for `protect_unless`: a coverage theme may write `tests/**`; a dead-code theme
  attempting the same must be rejected. This is the security-critical case.
- The assert/test-count-reduction guard.
- `cigate.jac` unit tests mirroring `testgate.jac`'s.
- `ci.yml` hash-drift check.
- Complexity-routing unit test: `trivial` routes to `model_simple`, `judgement` to `model`.

## 19. Deferred, explicitly not built

- GitHub webhook for merge detection (no repo admin; polling covers it).
- Real line coverage in v1 (Phase B is a parallel track; the symbol proxy ships first).
- Targeted/partial test selection in the gate (full suite per branch was chosen for thoroughness).
- Any auto-merge path. PRs are terminal until a human merges them.
