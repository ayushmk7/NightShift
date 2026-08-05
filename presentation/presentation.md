# NightShift

### An autonomous overnight agent harness — and the night it taught us what a ceiling isn't

*Presentation content, 2026-08-04. All figures are measured from the harness's own artifacts
(`dataset/*.jsonl`, `logs/<date>/spend.txt`) unless stated otherwise.*

---

## 1. What NightShift is, and why it exists

**The problem.** `jaseci-labs/jac` is a large, actively moving codebase — roughly 365,000 lines of
Jac across eleven packages, with a compiler written in the language it compiles. Codebases that size
accumulate a specific kind of debt that nobody is ever paid to fix: dead code that no longer has a
caller, abstractions that were right two refactors ago, public archetypes with no test touching
them, small maintenance rot that every reviewer notices and nobody files. It is real work, it is
unglamorous, and it loses every prioritisation argument it is ever in. It is also, unusually, work
that an agent can do well: each item is small, local, mechanically verifiable, and independently
shippable as its own pull request. What it is *not* is work anyone wants to supervise turn by turn.

**What NightShift does.** It is a harness that runs a fleet of headless Claude Code sessions against
the target repository between 23:00 and 07:00, unattended, and leaves draft pull requests open
upstream by morning. It audits the repo through one of four rotating lenses, selects which findings
are worth spending a session on, gives each selected group of findings its own branch and its own
fresh agent, then puts every resulting branch through a local replica of the project's CI — the CI a
fork PR cannot actually reach — and throws away anything that does not go green. What survives is
pushed and opened as a *draft* PR. It never marks a PR ready for review and never merges: `ns_gh_write`
refuses `pr ready` and `pr merge` outright. A human merges, or nobody does. The morning job is
review, not dispatch.

The design constraint that shapes everything downstream: **the harness is unsupervised, so every
stage has to be safe when it is wrong**, and — the thing this presentation is really about — every
stage has to be *honest about not having run*.

---

## 2. Architecture — the pipeline end to end

Stages `S0`–`S6` run nightly and unattended; `S7` is the human loop. There is deliberately no `S2`:
the tier-1 deterministic autofix stage was retired 2026-07-30 (a formatting-only PR was noise, a
repo-wide one unmergeable against ~259 pre-existing violations on main). The numbering keeps the gap
so that every log line and spec reference written before that date still reads true.

![NightShift nightly pipeline, S0 through S6](images/pipeline-overview.png)

**Entry.** `launchd` fires at 23:00 in the user domain and directly executes `bin/nightshift.sh run`.
`caffeinate -i` keeps the machine awake; `gtimeout 480m` is a hard wall-clock ceiling in lockstep
with `[budgets].wallclock_min = 480`, so the 23:00–07:00 window is enforced twice by two mechanisms
that cannot silently disagree.

**S0 — Preflight.** Takes a `mkdir` lock, checks for the `~/.nightshift/DISABLE` kill file, resolves
every binary it will need by absolute path (`jac`, the *target repo's* dev `jac`, `claude`, `gh`,
`git`), confirms `gh` auth and network, and proves Claude answers by sending it a literal `pong`
probe. It also scans for missed nights, distinguishing "launchd fired and the run died" from
"launchd never fired at all" — two very different failures that used to look identical.

**S1 — Sync.** Syncs the fork from upstream main, refuses to proceed if main has diverged, cuts the
worktrees (`work/repo` for branches, `work/drafts` on an orphan branch), prunes shipped or rejected
branches older than 14 days, and pulls the finding ledger down from the drafts branch.

**S1.5 — Merge poll (agent-free).** Asks `gh` which of our PRs merged upstream since the last
successful poll, and builds the union of files they changed — `.jac` only, protected globs dropped,
churn-ranked, capped at 40. If the query *fails*, it says so and produces no reactive scope; it does
not report an empty answer.

**S1.6 — PR inventory (agent-free, before any new work).** Lists our own open PRs, rebases each on
fresh main, and re-runs the S4 gate on it. **Existing PRs outrank fresh findings** — there is no
point in generating a twelfth PR while three are rotting. A red re-gate never demotes an
already-open PR; it records the fact and moves on.

**S3 — The agentic tier**, in strict priority order:

- **S3a · Reactive.** Runs the task lenses over the files that merged upstream *today*, so code gets
  cleaned the same night it lands. Three of the four lenses share an empty write-permission set and
  are merged into one session (`reactive_single_session = true`) so the merged files are read twice
  instead of four times; coverage keeps its own session because it is the only task that carries a
  write exemption, and a swept finding's task label is necessarily agent-authored.
- **Carry-over.** Findings a past night paid to discover but had no clock or budget to apply are
  re-offered here at zero audit cost. As of this morning there are 103 findings in that queue.
- **S3b · Cycle.** Tonight's *one* task — the cycle rotates dead-code → abstraction → maintenance →
  coverage — audited across 8 LOC-balanced shards of the whole repo, concurrency 2, each session
  read-only (`--permission-mode dontAsk`, no Edit/Write in the allow-list), 130 turns, a 30-minute
  box, and an $8 cap. An audit session that *died* is treated as a dead lens and is never salvaged
  into "zero findings".
- **Selection.** `scripts/selector.jac` is a pure, unit-tested function: it drops findings that are
  ledger-known, protected, `file-gone`, blocked by a protected test, or twice-failed; scores the
  rest; groups them by **task + directory** (not by the agent's free-text `theme_hint`, which on
  2026-07-31 produced 105 groups from 112 findings, 99 of them singletons); and packs at most 15
  themes of at most 10 files and 600 LOC each, shed to fit the clock.
- **Apply.** One theme, one fresh branch, one fresh `claude -p` session at `acceptEdits` with a
  narrow tool allow-list and **no push, no `gh`, no network**. Attempt 1's model routes on the
  theme's complexity tag — trivial and mechanical go to Sonnet, judgement to Opus — and escalation is
  one-way. A theme sharing a file with one already applied tonight is *stacked* on that branch
  rather than cut from main.

**S4 — Verify gate, fail-closed, cheap jobs first.** Resolve the base (a deleted parent cascades
red) → scope containment (the diff must be a subset of the theme's own files plus its release-note
fragment; anything else is treated as possible prompt injection) → `jac check` baseline-diff, new
errors only → CI-mirror fast jobs (fmt diff-scoped, check, jir — seconds) → the mirrored CI suites
with one retry each → **a positive assertion that the suites actually ran** → pre-commit →
contribution rules (AI co-author trailer, no `.py` files, bun lockstep, docs, fragment). Anything red
deletes the branch and increments `failed_verify`.

**S5 — Ship.** Push to the fork on an explicit `nightshift/*` refspec, never forced. Render the
draft. Open the PR upstream as a **draft**, asserting on both a zero return code *and* a URL-shaped
result — either alone can lie. A stacked child's PR is *held* until its parent merges, because
GitHub's `--base` must name a branch in the repo the PR is opened on.

**S6 — Digest.** A multipart/alternative email, assembled from the night's own artifacts, fired from
an EXIT trap on every exit path including TERM and INT — and written so that a failure inside the
digest never aborts the trap.

**S7 — Human loop.** Review the draft PRs on GitHub. Merge, discard, or leave them; anything left
open gets rebased and re-gated by S1.6 every night until it is dealt with. What merges becomes
tomorrow's reactive scope, closing the loop.

**Implementation note worth stating once:** bash sequences processes and Jac owns every data and
logic transformation. There are **no Python files** — a standing project rule, enforced by the S4
contribution job on every branch the harness produces.

---

## 3. The cost model

An unattended fleet of Opus sessions is, in the most literal sense, a machine for spending money
while you sleep. NightShift bounds that in three layers.

**Layer 1 — per-session caps.** `max_budget_usd = 5` per apply session, `audit_max_budget_usd = 8`
per cycle shard, `reactive_audit_max_budget_usd = 8` per reactive lens. These are separate numbers
for an arithmetic reason, not a tidiness one: measured on 2026-07-31, the reactive lenses cost
$0.139/turn against the cycle shards' $0.0638/turn — a 2.2× difference. A single shared cap would
quietly move money from the shards that produced 95 findings for $38.36 to the lenses that produced
5 for $28.72.

**Layer 2 — the night ceiling.** `night_budget_usd = 50`. This is the only number that actually
bounds spend, because *a per-session cap times fifty sessions is not a brake*. The motivating
measurement: on 2026-07-31 one unattended night spent **$76.55 in 97 minutes** of a 480-minute
window across 27 unique sessions — $67.36 of it audits, and only $9.19 on the eleven applies that
produced all six shipped branches.

**Layer 3 — how spend is tracked.** `logs/<date>/spend.txt`, one `session_id<TAB>total_cost_usd` row
per session, appended *at the session* rather than reconstructed from envelopes afterwards. Both
halves of that sentence are scar tissue. The first attempt to total a night read the envelopes on
disk and got $152.82 across "50 sessions" — exactly double, because every `meta-<name>.json` is a
byte-twin of the `<name>.json` it was projected from; hence the `session_id` dedupe. And
`audit-<name>.json` is *overwritten in place* by its own retry, so two real attempt-1 Opus sessions
survive in no file at all and would be missing from any envelope-derived total.

`ns_spend_check` sums that ledger and returns non-zero to mean *stop scheduling*. It **fails
closed**: a missing ledger is legitimately $0.00, but a junk ledger, a `jac` error, or an unset
ceiling all come back non-zero and stop the work. Remember that property — section 6 is about the
one place that was not wired to it.

---

## 4. The carryover / selection loop

The unit of memory in this system is the **finding**, and its identity is
`fingerprint = sha1(file + rule)` — stable across nights and across both phases. Everything the
harness knows about a piece of work is keyed on that.

The economics are what make carry-over load-bearing rather than a nicety. On 2026-08-03 the night
surfaced **182 findings** — 79 fresh, **103 carried** from prior nights — packed **26 themes**, and
deferred **105 findings**. Every deferred finding has *already been paid for*: audit money is spent
at discovery, and a finding that is discovered and then forgotten is money burned twice, because the
next audit will rediscover it and charge again. Carry-over is what converts audit spend into shipped
PRs across nights instead of within one.

The lifecycle, as `WORKFLOW.md` §3 states it:

- `new` → `in_theme` — selected and applied. Recorded since 2026-08-02, which is what stops the
  cycle phase re-buying a finding the reactive pass already has a branch for.
- `new` → `deferred` — did not fit the theme, night, or clock budget at selection **or** (since
  2026-08-04) its theme was turned away at apply time. Same `carryover.json`, same schema, either
  way.
- `deferred` → `in_theme` — re-packed on a later night at zero audit cost. Carried findings sort
  first in `pack_themes`, and merging them *ahead* of tonight's findings makes the carried copy win
  the `(file, rule)` dedupe, so a rediscovered finding keeps its carry flag.
- `in_theme` → `drafted` → `shipped`, or → `failed_verify` → (retry once) → `rejected`.
- `new` → `blocked` when the only referencing file is a protected test; `new` → `file_gone` when
  upstream renamed or deleted the file — terminal, and deliberately not carried.

One constraint governs where carry-over may be written: **RECONCILIATION B7**. Carry-over belongs to
the *cycle* phase only. The reactive pass runs first; if it also consumed the carry-over it would
pack yesterday's deferrals into the reactive phase — the spec says reactive *outranks* carry-over,
not that it absorbs it — and then overwrite `carryover.json` with its own deferrals, spending
yesterday's carry-over twice in one night and losing it. B7 forbids *displacement*. It will matter in
section 6.

---

## 5. The one defect class this whole design is shaped around

> **"Did not run" scoring as "passed."**

Thirteen-plus instances have been found in this harness. Every one was in a gate or a guard. **None
of them was caught by a failing test** — they were all found by reading, or by an expensive night.

The cause is always the same shape: a command exits 0 for *nothing to do* and exits 0 for *all
good*, and the caller cannot tell the two apart.

![The "did not run scored as passed" defect class, and its countermeasure](images/defect-class.png)

A sample of the catalogue, because the pattern only becomes convincing when you see the range of
places it hides:

- `ledger prunable` demanded five argv where the caller passed four, so from 2026-07-30 to
  2026-08-02 every call printed usage, **exited 0**, and pruned nothing.
- `selector`'s usage arm also exited 0 — and `tier2_select` reads it on stdout. Any arity drift
  would have produced an empty selection, a log line reading "no themes tonight", and a night
  reporting success having shipped nothing. It exits **2** now, like `check_scope`.
- A `for shard in $(ns_jac shards list ...)` loop: `set -e` does not fire on `for x in $(false)`, so
  a malformed shard table made the loop iterate **zero times** — no session ever started — and the
  night logged "every shard failed or produced nothing", blaming the audit for a config error.
- `upsert_theme` hard-indexed `est_loc_saved`, which a coverage finding does not carry. It raised
  KeyError under `errexit` and killed the **first live night** at S3: $17.42 spent, two finished
  branches thrown away, nothing gated, nothing shipped. Broken since the task registry landed, and
  invisible for four days because no coverage theme had ever survived an apply.

The countermeasure is always the same too: **a positive assertion that the work happened**, not
merely that it did not fail. `assert_suite_ran` and `assert_check_ran` in S4, with a collection floor
on the test counts. S1.6 distinguishing "queried, zero PRs" from "the query failed". S5 creating
`prs.jsonl` *before* its early return, so an absent file proves S5 never ran. `ship_open_pr`
demanding rc 0 **and** a URL-shaped result.

And the sibling class — **assertions that cannot fail**. `( set -e; … ) || fail` is vacuous. A
`grep -q` can match the comment instead of the code. A regression test can contain the bug it
guards. This is why **every tripwire in `bin/test-harness.sh` is paired with a mutation that must
turn it red**, and that discipline keeps earning its keep: section 39's mutation caught that section
39's own `grep -A2` was looking *past* the line it checked; section 40's caught that section 38's
mutant was written to a dot-prefixed file that `jac run` cannot load at all — so the mutant emitted
nothing and "the mutant did not produce the bad output" was true for the wrong reason.

**Hold that frame for the next section.** All four of today's fixes are instances of it: a permission
that silently resolves to nothing, a ceiling that watches one of two spending paths, a memory that
remembers one of several ways to fail, and a validator that checks the wrong set of files.

---

## 6. The 2026-08-04 revamp — four fixes

### 6.1 Fix 1 — The environment: a tool grant that granted nothing, and a machine-wide permission hole

**Problem.** Both the audit and the apply allow-lists end with `mcp__jac__*` — the Jac language
server's MCP tools, which are how a session gets structural answers about Jac code instead of
grepping for them. The `jac` MCP server had never been registered against the live repo path.

**Root cause.** The registration is *local* — it lives in `~/.claude.json`, keyed by directory — not
a `.mcp.json` committed inside the target repo. The move to `~/nightshift` cut a fresh clone at
`work/repo`, and a fresh clone inherits nothing. An allow-list entry naming a server that does not
exist does not error; it simply matches no tool. Every session ran without the tools it was granted,
and reported success. **Textbook instance of the class**: the grant "did not run", and scored as
granted.

**Fix.** `cd work/repo && claude mcp add jac -- jac mcp`. And it is now written down in
`WORKFLOW.md` §4 as the one piece of per-machine setup a fresh deploy needs — because the failure is
silent, the documentation *is* the tripwire here.

**Second finding, same session, unrelated blast radius.** The user's global Claude Code settings
carried a machine-wide `bypassPermissions` default. **NightShift's own sessions were never affected
by it** — `lib/tier2.sh` names `--permission-mode dontAsk` for audits and `--permission-mode
acceptEdits` for applies on every single invocation, with an explicit `--allowedTools` list, so a
session's permissions are whatever the harness passes and nothing else. But it was a standing safety
hole for *every other* session on that machine. Removed. `WORKFLOW.md` §4 now asserts the property
explicitly: nothing here relies on the machine's global settings, and `~/.claude/settings.json`
carries no `bypassPermissions` default.

**Verification.** `claude mcp list` from `work/repo` returns `jac: jac mcp - ✔ Connected`.
`~/.claude/settings.json` has no `bypassPermissions` and no `defaultMode`.

---

### 6.2 Fix 2 — The budget ceiling was a brake on one of two wheels

![The night cost ceiling: the audit path was always gated, the apply path was not](images/budget-guard-before-after.png)

**Problem.** `night_budget_usd = 50`. On the night of **2026-08-03** the harness spent **$109.73
across 37 sessions** — 2.2× its own ceiling — and every assertion about the ceiling stayed green.

**Root cause.** `ns_spend_check` was only ever called from the two audit fan-outs (`tier2_audit_all`
and `reactive_main`). `tier2_apply` never consulted it. That was not an oversight; it was a
*deliberate, documented, and wrong* decision, justified in a config comment by the 2026-07-31 data:
audits were 88% of the bill, eleven applies were $9.19 of $76.55, and "refusing to spend $0.80
shipping work the night already paid $50 to find would be the expensive kind of thrift."

The 2026-08-03 numbers killed that premise:

| | |
|---|---|
| Cycle fan-out braked itself | **$54.78 of $50.00, at 00:19:30** |
| Apply sessions spawned *after* that brake fired | **16, between 00:26 and 01:56** |
| Apply spend | **$60.25 across 26 sessions — 55% of the bill** |
| Audit spend (incl. one $0.43 repair) | **$44.44 across 10 sessions** |
| Night total | **$109.73 across 37 sessions** |

The exempting comment assumed applies were 12% of spend. They were 55%. The premise had inverted and
nothing noticed, because the *shape* of the assertion never changed: harness section 27 proved the
ceiling was summed from real envelopes, that it failed closed, and that it stopped the audit fan-out.
All true. All still true on the night it let $109.73 through. **A ceiling that governs one of two
spending paths is not a ceiling** — and an assertion that covers one of the two paths an invariant
runs on is the most expensive variant of "did not run scored as passed" found in this project to
date.

**Fix.** `tier2_apply` now calls `ns_spend_check` **per theme, before every apply spawn**, sitting
directly beside the pre-existing clock guard because it is the same kind of guard and defers to the
same place. It **fails closed**: an unreadable, malformed, or unsummable spend ledger stops the theme
exactly as a genuinely-over-budget one does. The honest residual is stated in the code rather than
hidden: the check is per theme, so a theme that passes it and then retries can straddle the ceiling
by one more session, bounded by `max_budget_usd`. It cannot *start* a theme that is already over the
line. The apply-side `ns_spend_add` call was already there — the comment above it now says what it is
for ("which is what makes the per-theme brake at the top of this loop see its own cost") instead of
explaining why applies were exempt.

**Verification — and this is the part that matters.** Section 27 was extended to drive **the real
`tier2_apply`** against a stub `claude` in a sandboxed repo, not just the fan-out. Four arms:

1. **The defect itself:** ledger seeded at $99.00 → the stub is never called; `run.log` must contain
   the literal `NIGHT COST CEILING reached (99.00 of 50.00` (the numbers, not just the words), and
   the deferred theme must appear in `failed.tsv`.
2. **Fails closed:** ledger seeded with `no-session-id-column` → still no session. Without this arm
   the guard could have been written as `[ -s spend.txt ] && …` and every other assertion would
   still pass.
3. **The positive control:** ledger seeded at $1.00 → the stub **must** be called, and the brake must
   *not* have logged. Without this, "no session was started" is satisfied by a `tier2_apply` that
   never spawns anything at all — the vacuous-assertion trap.
4. The theme slug is read off the live selection rather than hardcoded, so the day `group_key`
   changes, the assertions naming it fail loudly instead of passing vacuously.

**What was deliberately not changed:** the number 50 itself. See section 7.

---

### 6.3 Fix 3 — Carry-over remembered one way to fail, out of several

![Where deferred findings flow into carryover.json, before and after 2026-08-04](images/carryover-before-after.png)

**Problem.** `state/carryover.json` is the system's memory for work it paid to find but could not
do. It only ever contained findings the selector **could not pack in the first place**. A theme that
*was* packed, *was* selected, and was then turned away at the apply loop's door left no memory at
all.

**Root cause.** Three places remember work, and an apply-time deferral fell outside all three:

- **No `in_theme` ledger row** — `ledger upsert-theme` runs only *after* a session succeeds.
- **Nothing in `carryover.json`** — `tier2_select` writes that file from `selection.json`'s
  `carryover` field, and that field only ever describes findings that were never packed
  (`over-theme-budget`, `over-night-budget`, `no-clock-left`). It is written *before* the apply loop
  ever runs.
- **Only an `ns_fail` row in `failed.tsv`** — which the digest reports, and which **nothing ever
  reads back**. It is a report, not memory.

So the findings behind that theme were neither retried nor rediscovered. They were gone. This looked
harmless while the only apply-time guard was the clock, which fires at the *tail* of a night on
themes tomorrow's audit would probably re-find anyway. **Fix 2 made it not harmless at all**: the
cost ceiling defers themes from the *front* of the loop, and on 2026-08-03's numbers that is most of
the selection. Shipping the budget brake without this fix would have converted a money leak into a
silent work-deletion machine.

**Fix.** A new helper, `tier2_defer_theme <theme.json> <label> <why>`, called from **both** apply-time
guards. It writes the `ns_fail` row exactly as before, then projects the theme's findings back into
the carry-over stream via a new `selector.jac` verb, `carryover`, backed by `carry_findings()`.

Three properties make this the *same* mechanism rather than a parallel one:

- **Same file, same schema.** `carry_findings` sets `carry = True` and adds nothing else — the
  findings already carry `fingerprint` and `score`, stamped by `select()` before they were ever
  packed. A reader genuinely cannot tell an apply-time entry from a selection-time one.
- **Append-only.** It is a `parse_result merge` over the existing file, oldest first, so the carried
  copy still wins the `(file, rule)` dedupe. **This is what keeps it inside RECONCILIATION B7**, and
  the plan document was amended today to say so: B7 forbids the reactive pass *displacing* the cycle
  phase's carry-over file, and a merge cannot displace anything. A reactive theme deferred here is
  simply offered to `tier2_select cycle` later the same night, and re-carried if it does not fit
  there either.
- **Never fatal, and loud when it fails.** It runs inside the apply loop under `errexit`; losing one
  carry-over row must not also lose the themes queued behind it.

And one deliberate refusal at the bottom: `carry_findings` **raises on an empty theme** rather than
returning `[]`. `pack_themes` only ever builds a theme from a non-empty bucket, so a theme with no
findings is malformed — and returning `[]` would let the caller merge nothing and log success, which
is the exact silent vanishing the function exists to stop, one layer down.

**Verification.** The strongest assertion in today's work is a **byte comparison**. Section 27 puts
one finding through the *real* selector twice: once with a full clock (it packs into a theme, which
`tier2_apply` then turns away) and once with no clock (the *selector* defers it, which is the shape
`carryover.json` has always had). The two outputs must be `cmp -s` identical. A parallel mechanism
that merely looks similar — a different key set, a missing carry flag, a lost fingerprint — cannot
pass that. Around it:

- **It appends, it does not replace.** Yesterday's carry-over is seeded before every probe and must
  still be there afterwards. Deferring one theme must not destroy the rest of the backlog.
- **Tomorrow can actually use it.** The written file is fed back through `selector select` and
  `selector slots`, and the deferred file must come out packed into a theme. Existing in the file is
  not the same as being usable.
- **The false-positive arm, which is the one that matters.** A theme that *reached* its session must
  **not** appear in `carryover.json`, and the seed file must be byte-unchanged. Without this,
  "it appears in carryover.json" is satisfied by a `tier2_apply` that carries everything it touches —
  and every finding the night actually shipped would be re-bought tomorrow.
- The control itself is checked for non-emptiness first, so the byte comparison cannot pass by
  comparing two empty lists.

**Two holes of the same shape are known and explicitly NOT fixed** — named in the code, in
`WORKFLOW.md` §7, and in the diagram above:

1. The **session-limit `break`** in `tier2_apply` exits the loop without draining the
   `selector split` pipe. The themes queued behind it are never *read*, so there is nothing to hand
   to `tier2_defer_theme`.
2. A theme whose **session dies or commits nothing** still gets only an `ns_fail` row.

Both are the same defect class, both are real, and both were left alone rather than bundled into a
fix that was already touching two guards.

---

### 6.4 Fix 4 — The selector validated the paths it guessed, and not the path it was given

![drop_reason: the sibling-only existence check versus the finding's own file](images/selector-file-check.png)

**Problem.** A finding pointing at a file upstream had renamed or deleted sailed through selection,
packed a theme, got a branch, got a model call, and burned a 25-minute apply box to report "no
changes made."

**Root cause.** `selector.jac`'s `drop_reason()` had an existence check — but it was in
`impl_siblings()`, which existence-checks the `X.impl.jac` **candidates it derives itself**. It never
checked the finding's own `file` field. The old docstring even argued the sibling check was the
important one because "only findings' own files ever drive an edit," which is exactly backwards: a
derived guess and a stale input are the same failure with different provenance. And the input goes
stale by *design* — the audit reads a clone, the clone is refreshed before the next night, and
upstream renames files in between. Measured on the 2026-07-31 replay:
`jac/jaclang/runtimelib/planner.jac` was audited, upstream renamed it to `query_planner.jac`, and the
finding still packed a theme naming a path that is not on disk.

This is the defect class at the file level. The check "passed" because it was never run against the
thing that mattered, and the failure surfaced downstream, expensively, as a session that did nothing.

**Fix.** `drop_reason()` now takes `repo_dir` and checks the finding's own file, returning a new drop
reason: **`file-gone`**. Two design decisions inside it:

- **Terminal, and deliberately not carried.** `select()` carries only `over-night-budget` and
  `no-clock-left`, and nothing about tomorrow puts a deleted path back. The finding does not *need*
  carrying — the next audit over the refreshed clone either re-finds the issue at its new path (a new
  fingerprint, since `fingerprint()` is keyed on the file) or does not find it at all. Carrying the
  dead path would re-drop it for the same reason every night, forever.
- **It stands down when there is no tree to check against** — when `repo_dir/jac` is not a directory,
  which covers a failed clone and the unit tests' `/nonexistent-repo` — on the same guard
  `vestigial_test_files` and `blocking_test_files` already use. Dropping the night's *entire*
  selection because the clone is missing, and then reporting a clean night, is a far more expensive
  failure than the one this catches.

**Verification.** A Jac unit test built on the real 2026-07-31 shape — a temp repo containing
`query_planner.jac` and not `planner.jac` — with three arms:

1. The stale finding is dropped, its reason is exactly `file-gone`, and it produces **no** carry-over
   entry (terminality is asserted, not assumed).
2. **The false-positive arm:** the finding naming the file that *is* on disk still packs, and drops
   nothing. A rule that drops everything satisfies arm 1 perfectly and costs the harness its entire
   output.
3. **The stand-down arm:** with `/nonexistent-repo` as the tree, the same stale finding still packs —
   proving a missing clone cannot silently empty the night.

`dataset/README.md` was updated in the same change: `file-gone` is now a documented `status` value,
with an explicit note that rows before 2026-08-04 carry the finding under whatever reason it drew
instead — usually `applied`, since the theme packed and the session then found nothing to change.

---

## 7. What's still open

**The budget sizing decision — deliberately deferred, not forgotten.** `night_budget_usd` is still
50. Fix 2 makes the number *mean* something; it does not claim the number is right. Three options,
none taken yet:

- **Raise the cap.** The 08-03 night produced real work at $109.73. If that work is worth it, the
  ceiling should say so rather than being routinely blown through.
- **Cut audit spend.** $44.44 of audit produced 79 fresh findings against a queue that already held
  103 unapplied ones. The bottleneck is not discovery.
- **Accept audit-only nights.** With the brake now real, a night that spends its ceiling auditing
  ships nothing — it banks findings into carry-over and applies them tomorrow. That is coherent, and
  it is what will actually happen tonight unless something changes, so it should be a decision rather
  than a discovery.

The data to decide this exists: `sessions.jsonl` carries per-session cost, model, phase, and
`findings_out`, so "findings per dollar, by model, by shard" is a query rather than an argument.

**The two remaining carry-over holes** (§6.3): the session-limit `break` that never drains the theme
pipe, and the theme whose session dies or commits nothing. Both are the same defect class. Both are
named in `WORKFLOW.md` §7 and in `tier2.sh`'s own comments, which is the project's standing rule —
**a known hole gets written down where the next person will trip over it, not filed elsewhere.**

**A reporting gap that follows from fix 3.** `nights.jsonl`'s `themes_deferred` counts
*selection-time* deferrals only. A theme that packed and was then turned away by `tier2_apply` is
correctly carried in `state/carryover.json` but is not counted in that field, so on a night whose
apply loop hits the cost ceiling the row **undercounts the real backlog**. Documented in
`dataset/README.md` today rather than papered over; the other half of the number is
`themes_selected` minus the branches that reached S4.

**Readiness state, honestly.** The system is armed and running unattended, and it is still young: the
v2 cutover was 2026-08-02, and the first live night after it died at S3 on a `KeyError`. Two of the
last four nights found a real defect in the harness rather than in the target repo. That ratio is
expected to keep falling, and it is *measured*, not asserted — every night writes its own row.

---

## 8. Where the system stands tonight

- **`bin/test-harness.sh`: 41 of 41 sections green**, up from red at section 32 when today's session
  started. Section 27 now drives the real apply loop, with a positive control, a fail-closed arm, and
  a byte-comparison against a selection-time carry-over control.
- **Every fix landed today was mutation-tested** — the new assertion was verified to go *red* against
  the broken behaviour, not merely green against the fix. That is the project's standing countermeasure
  to its own dominant defect class, and it is the reason these four fixes are believable at all.
- **The night ceiling is now a ceiling.** Both spending paths — audit fan-out and apply loop — consult
  the same `ns_spend_check` against the same `spend.txt`, and both fail closed when it cannot be read.
- **The carry-over queue holds 103 findings**, all already paid for, and now fed by both the
  selection-time and apply-time deferral paths through one file, one schema, and one reader.
- **The `jac` MCP server is registered and connected**, so the tool grants in both allow-lists finally
  resolve to real tools; the machine-wide `bypassPermissions` default is gone.
- **Nights are armed**: `com.nightshift` is loaded in launchd, there is no `DISABLE` file, and the
  window is 23:00–07:00 with a 480-minute hard ceiling.

**The through-line, one sentence:** every defect closed today was the same defect — something that
did not run, and read as something that passed — and the only reliable defence this project has found
is to demand positive evidence that work happened, and then to break the code on purpose to prove the
evidence can go missing.
