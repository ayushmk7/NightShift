> **SUPERSEDED for stages S3 onward (2026-07-30).** The target repo restructured and this document
> describes the world before it. Do not trust its facts: upstream is now **`jaseci-labs/jac`**,
> `jac-byllm`/`jac-scale` are no longer packages (they are `jac/jaclang/byllm` and `jac/jaclang/scale`),
> package rotation is gone in favour of an 8-shard whole-repo audit, and release-note fragments live at
> `release_notes/unreleased/jaclang/`. The current design is
> [`docs/superpowers/specs/2026-07-30-nightshift-4task-design.md`](superpowers/specs/2026-07-30-nightshift-4task-design.md);
> open items are in [`…-nightshift-followups.md`](superpowers/specs/2026-07-30-nightshift-followups.md).
> Sections 1-2 (goals, non-goals) and the S0-S2 stages still hold. Kept for provenance.

# PRD — Nightshift: a nightly Jac code-cleanup harness for jaseci-labs/jaseci

**Status:** Draft v0.4 · **Date:** 2026-07-10 · **Owner:** you · **Codename:** Nightshift (rename freely)
**v0.2:** resolved runtime = macOS (§10) and auth = Pro/Max subscription (§9, §13-M0, §14). **v0.3:** wall clock raised to a 3 h ceiling with adaptive stage boxes; full test suite every night (§9, §14-Q4). **v0.4:** scope definition sharpened (§3.1); all open questions resolved or defaulted (§14); feasibility audited.
**v0.5 (2026-07-10):** corrected for the real `jaseci-labs/jaseci`, which moved to a single Zig-built `jac` binary. Tests run via the binary's **bundled runner** (`JAC_TEST_JOBS=auto jac test tests` per package), NOT `pytest jac -n auto`; there is **no pip-installed jaclang and no `.venv`**; the toolchain is built with `./scripts/fresh_env.sh` (Zig 0.16.0). Only **4 package dirs exist** (`jac`, `jac-byllm`, `jac-mcp`, `jac-scale`), so the rotation is 4 not 7. Release-note fragment dirs differ from package names (`jac`→`jaclang`, `jac-byllm`→`byllm`). The repo's pre-commit **rejects em-dashes and AI co-author trailers** — Nightshift's commits and fragments avoid both, and pre-commit is run explicitly in the gate, never installed as a git hook.

---

## 1. Summary

Nightshift is an unattended agent loop that runs every night on your local machine. It syncs your fork of `jaseci-labs/jaseci` with upstream `main`, then cleans Jac code in two tiers: a deterministic tier (the `jac` toolchain's own formatter and linter) and an agentic tier (headless Claude Code running the **ponytail** anti-over-engineering skill, grounded in Jac via the `jac mcp` compiler server and the `jac guide` agent skills). Every change must pass a fail-closed verification gate (type check, tests, pre-commit) or the branch is discarded. Surviving work is pushed to your fork as small themed branches, each with a ready-to-ship PR draft written as a markdown file stored in the fork. The night ends with an email digest to you. In the morning, you review, run `nightshift promote <branch>` to open the real PR (to upstream or wherever you choose), and the draft `.md` is deleted — the drafts directory is always the queue of not-yet-shipped work.

The machine does the janitorial pass at night; the human makes the judgment call over coffee.

## 2. Background

**The target.** `jaseci-labs/jaseci` is the monorepo for the Jac language and the Jaseci stack: the `jac` compiler/runtime, `jac-byllm` (LLM integration), `jac-client`, `jac-scale`, `jac-mcp`, `jac-super`, and docs. The repo is ~95% Jac — the compiler is largely self-hosted — so "cleaning Jac code" means editing a live compiler, stdlib, and plugins. Tests are not optional decoration here; they are the only thing standing between a cleanup and a broken toolchain.

**The toolchain is already agent-ready.** The `jac` CLI ships formatting (`jac fmt` / `jac format .`), linting (`jac check --lint`, `jac lint . --fix`), whole-program type checking (`jac check`), and tests (run per package as `JAC_TEST_JOBS=auto jac test tests` via the binary's bundled runner — jaclang ships as one Zig-built `jac` binary, so there is no pip-installed jaclang and no `.venv`). A Model Context Protocol server is built into the binary — `jac mcp` — exposing `validate_jac` (full compile-pipeline type check), `check_syntax`, `lint` (with `auto_fix` returning corrected code), `format_jac`, plus resources for the grammar, docs, examples, and a common-AI-mistakes guide. `jac guide --export ~/.claude/skills` exports the compiler's bundled reference guides as auto-loading Agent Skills. Nightshift builds on all of this instead of reimplementing any of it.

**The cleaner's brain.** [ponytail](https://github.com/DietrichGebert/ponytail) (MIT, ~75k stars) makes an agent apply a decision ladder before writing code — does this need to exist, is it already in the codebase, does stdlib/native cover it, can it be one line — and ships `/ponytail-audit` (whole-repo ranked report of what to delete/simplify, applies nothing) and `/ponytail-review` (same, on a diff). It carries four hard guardrails the agent may never cut: trust-boundary input validation, data-loss-preventing error handling, security measures, and accessibility basics. Its `ponytail:` comments form a harvestable tech-debt ledger.

**The culture fit.** Jaseci's contributing guide requires focused PRs, passing pre-commit, and a release-note fragment per package-code PR (`docs/docs/community/release_notes/unreleased/<package>/<PR#>.<category>.md`, category `refactor` fits us) — and it explicitly tells contributors to have an AI assistant audit their diff for bloat. Nightshift is that instruction, automated. Still: nightly *bot* PRs to a repo you don't maintain would burn goodwill, so nothing leaves your fork without you pressing the button.

## 3. Goals

1. Every night, produce zero or more small, verified, themed cleanup branches on the fork — never a broken one.
2. Keep human effort to a single morning decision per branch: promote or discard, from a fully drafted PR.
3. Never re-litigate: a finding that was applied, rejected, or deferred is remembered in a ledger.
4. Stay cheap and bounded: hard caps on diff size, agent turns, dollars, and wall-clock time.
5. Leave an audit trail good enough to reconstruct any night from logs + ledger + email.

## 3.1 Scope — what "clean" means here, precisely

Nightshift only ever operates on **existing** code, and only in these ways: deleting dead/unreachable code, collapsing duplication, simplifying over-engineered structures (speculative abstractions, unneeded wrappers, dead flexibility), replacing reinvented wheels with stdlib/native/already-installed equivalents, and mechanical formatting/lint fixes. "More efficient" in this PRD means **leaner and more maintainable** — fewer lines, fewer concepts, fewer dependencies — not benchmark-measured runtime speed. Simpler code is often faster as a side effect, but performance is never the objective function, because chasing it responsibly would require a profiling/benchmark gate the harness doesn't have (that's a possible v2 mode). Nightshift never adds features, and if the agent believes it has found a genuine *bug* while cleaning, it does **not** fix it silently — it reports it in the morning email, because bug fixes need intent and context, not janitorial judgment.

## 4. Non-goals

- Auto-opening or auto-merging PRs anywhere, including the fork. Humans ship; the bot drafts.
- Feature work, bug hunting, dependency upgrades, or doc rewrites. Cleanup only (dead code, over-engineering, duplication, style drift the linter can't fix).
- Runtime performance optimization. No profiling, no benchmarks in v1 — see §3.1. Speed gains are welcome side effects, never goals.
- Cleaning Python glue, CI config, or docs in v1. Jac sources first; revisit later.
- Running anywhere but your machine in v1 (no CI, no VPS).

## 5. Locked decisions (from our discussion)

| Decision | Choice |
|---|---|
| Runtime | Your local machine, nightly schedule |
| Depth | Tiered: deterministic pass + ponytail agentic pass |
| Blast radius | Fork only; sync fork `main` with upstream first, then branch, commit, push |
| Handoff | Nightly email digest; PR drafts as `.md` files living in the fork; drafts deleted once the PR is opened next morning |

## 6. Nightly flow

```
02:00 local ──▶ [0 Preflight] ─▶ [1 Sync fork w/ upstream main]
                                      │
                                      ▼
                          [2 Tier 1: deterministic clean]
                            jac fmt · lint --fix · pre-commit
                                      │
                                      ▼
                          [3 Tier 2: agentic clean]
                            claude -p  (ponytail + jac mcp + jac skills)
                            /ponytail-audit ─▶ pick top-N ─▶ apply
                                      │
                                      ▼
                          [4 Verify gate — fail closed]
                            jac check · jac test (per pkg) · pre-commit
                              red? ─▶ discard branch, log, continue
                                      │ green
                                      ▼
                          [5 Ship to fork]
                            push branch · write PR-draft .md · update ledger
                                      │
                                      ▼
                          [6 Email digest to you]
                                      │
        morning ──▶ [7 Human loop]  promote │ discard  (draft .md deleted on promote)
```

## 7. Components & stage specs

The whole harness is deliberately boring: one orchestrator script (`nightshift.sh` or a single stdlib-only `nightshift.py`), a `promote`/`discard` helper, cron/launchd for scheduling, and a `.env` for secrets. No frameworks, no daemon, no database — a JSONL file is the database. (Ponytail would approve.)

### Stage 0 — Preflight
Acquire a lock file (`/tmp/nightshift.lock`) so overlapping runs are impossible; verify `git`, `gh auth status`, `jac --version`, `claude --version`, network, and disk; start a per-night log dir `~/.nightshift/logs/YYYY-MM-DD/`. Any preflight failure → skip straight to Stage 6 with a failure email. A `~/.nightshift/DISABLE` file is the kill switch.

### Stage 1 — Sync
`gh repo sync <you>/jaseci --source jaseci-labs/jaseci --branch main`, then hard-reset the local clone's `main` to the fork's `main`. Nightly work happens on branches named `nightshift/YYYY-MM-DD/<theme>`. Stale nightshift branches older than N days (default 14) with status `shipped` or `rejected` in the ledger are pruned.

### Stage 2 — Tier 1: deterministic clean (no LLM, near-zero risk)
Run `jac format .` and `jac lint . --fix` (equivalently the MCP `lint` tool with `auto_fix`) across eligible paths, then `pre-commit run --all-files`. If the diff is non-empty, commit to `nightshift/YYYY-MM-DD/autofix` as `style: nightly jac fmt + lint autofix`. This branch goes through the same Stage 4 gate as everything else.

### Stage 3 — Tier 2: agentic clean
One package per night on a rotation (`jac` → `jac-byllm` → `jac-mcp` → `jac-scale` → repeat — the four package dirs that exist in the repo), so attention is spread and diffs stay reviewable.

**Phase A — audit (read-only).** Headless call: prompt includes `/ponytail-audit` scoped to the night's package (skills and slash commands expand inside `-p` prompts). Tools locked to read-only. Output parsed into candidate findings.

**Phase B — select.** Merge audit findings with the ledger: drop anything previously `rejected`/`applied`, drop protected paths, rank by (LOC saved × confidence ÷ risk), and take the top findings that fit the night's budget (§9), grouped into at most 3 themes (e.g., "dead code in jac-client", "reinvented stdlib in byllm prompts module").

**Phase C — apply, one theme per branch.** For each theme, a fresh headless session on a fresh branch:

```bash
claude -p "$(cat prompts/apply.md)" \
  --permission-mode acceptEdits \
  --allowedTools "Read,Edit,Grep,Glob,Bash(jac *),Bash(git diff *),Bash(git status *),Bash(git add *),Bash(git commit *),mcp__jac__*" \
  --max-turns 80 --max-budget-usd 5 \
  --output-format json > "$LOG/apply-$THEME.json"
```

Notes that matter: we intentionally do **not** pass `--bare`, because we *want* auto-discovery of the ponytail plugin, the exported Jac skills in `~/.claude/skills`, and the repo's `.mcp.json` (which registers `jac mcp` as a stdio server). `acceptEdits` lets the agent write files without prompting; everything else runs only through the scoped allow-list — no network tools, no unscoped bash, and `Bash(git push *)` is deliberately absent (the orchestrator pushes, not the agent). `--max-budget-usd` applies only on API-key billing; on a subscription, `--max-turns` is the cost brake. The apply prompt instructs the agent to validate every edited file via the MCP `validate_jac` tool before committing, honor ponytail's four never-cut guardrails, leave `ponytail:` comments where it consciously defers, and write the release-note fragment `docs/docs/community/release_notes/unreleased/<package>/0000.refactor.md` (placeholder number, fixed at promote time).

### Stage 4 — Verify gate (fail-closed)
Per branch, in order: `jac check` (whole-program type check), then `jac test tests` for each package that has a `tests/` dir (`jac`, `jac-byllm`, `jac-mcp`) via the bundled runner (`JAC_TEST_JOBS=auto`; one retry per package absorbs flakes), then `pre-commit run --all-files`. Any red → the branch is deleted, the finding is marked `failed_verify` in the ledger (eligible for one retry on a future night, then auto-`rejected`), and the failure is summarized in the email. No partial shipping.

### Stage 5 — Ship to fork
Green branches are pushed to the fork. For each, a PR draft file is generated (spec §8) and committed to the **orphan branch `nightshift/drafts`** in the fork — an orphan branch so the fork's `main` stays a pristine mirror of upstream and draft files never contaminate a real PR's history. The ledger is updated (`status: drafted`).

### Stage 6 — Email digest
Always sent, success or failure. Subject like `Nightshift 2026-07-10 · 2 branches ready · −412 LOC · 1 discarded`. Body: per-branch summary (theme, files, LOC before/after, test result, link to branch and draft), the full text of each PR draft inline (so morning review works from your phone), skipped/failed findings with one-line reasons, runtime and cost, and any preflight warnings. Transport default: Python stdlib `smtplib` over SSL with an app-password (Gmail or any SMTP) read from `~/.nightshift.env` (chmod 600); `msmtp`/local sendmail as the alternative for the allergic-to-app-passwords.

### Stage 7 — Morning human loop
`nightshift promote <branch> [--repo jaseci-labs/jaseci]` — verifies the branch is still green and rebases on the freshly synced `main` if upstream moved overnight, opens the PR via `gh pr create --body-file <draft>` (default target: upstream, since the drafts are "what PRs to make"; `--repo <you>/jaseci` works for fork-internal staging), renames the release-note fragment from `0000.refactor.md` to `<PR#>.refactor.md` and pushes the rename, marks the ledger `shipped`, and **deletes the draft `.md` from `nightshift/drafts`** — fulfilling the rule that a draft file existing means "PR not yet opened."
`nightshift discard <branch> [--reason "..."]` — deletes branch + draft, marks the ledger `rejected` so the finding never resurfaces.

## 8. Artifact specs

**Ledger** — `nightshift/drafts:ledger.jsonl` (also cached locally). One JSON object per finding: `{fingerprint, package, file, rule, summary, first_seen, last_seen, status, branch?, pr_url?, loc_delta?, notes?}` where `fingerprint = sha1(relpath + rule + normalized_snippet)` and `status ∈ {new, drafted, shipped, rejected, failed_verify, deferred}`. Rotation state (`next_package`) lives in a sibling `state.json`.

**PR draft** — `nightshift/drafts:drafts/YYYY-MM-DD--<theme>.md`:

```markdown
---
branch: nightshift/2026-07-10/dead-code-jac-client
package: jac-client
date: 2026-07-10
files: 6
loc: {before: 512, after: 143}
risk: low            # low | medium — medium requires extra morning scrutiny
tests: "jac check ✓ · jac test ✓ · pre-commit ✓"
release_note: docs/docs/community/release_notes/unreleased/jac-client/0000.refactor.md
---
# refactor(jac-client): remove dead render-path duplication

<ready-to-paste PR body: what/why, before/after highlights, ponytail rationale,
verification evidence, and a reviewer checklist>
```

Frontmatter is machine-read by `promote`; the body below the frontmatter is the literal `--body-file` payload.

## 9. Guardrails & budgets

| Guardrail | Default |
|---|---|
| Themes per night / files per theme / changed LOC per theme | ≤ 3 / ≤ 10 / ≤ 300 |
| Agent limits per session | `--max-turns 80` — with the 3 h clock, turns (i.e. your Pro/Max quota), not time, are the binding constraint; raise toward 120 only if themes are getting truncated mid-apply. Keep `--max-budget-usd 5` in the command anyway (inert on subscription, active if you ever switch to an API key) |
| Total wall clock (whole night, incl. tests) | **180 min (3 h) hard ceiling**, then kill + failure email. Soft stage boxes inside it: preflight+sync+tier-1 ≤ 15 · agentic ≤ 90 · verify ≤ 65 · ship+email ≤ 10. Adaptive rule: before starting each theme, its projected apply+verify cost must fit the remaining clock, else the night stops shipping new themes and finishes what it has |
| Protected paths (never edited) | `**/tests/**` and all test fixtures (fixture Jac is often *intentionally* weird), grammar/spec files (`jac.spec`, token defs), generated & vendored code, `docs/**` except release-note fragments, `.github/**`, `examples/**` (v1) |
| Branch hygiene | Bot only touches `nightshift/*` branches; never force-pushes; never pushes `main` |
| Ponytail inherited | Never cut trust-boundary validation, data-loss error handling, security, accessibility |
| Secrets | `~/.nightshift.env` (SMTP app password), chmod 600; `gh` token scoped to the fork + PR creation. **Ensure `ANTHROPIC_API_KEY` is *not* set in the run's environment** — if present it takes precedence over the subscription and you'd be silently paying per token |
| Kill switch | `~/.nightshift/DISABLE` file; lock file prevents overlap |

Subscription reality check: headless runs draw from the same Pro/Max usage pool as your daytime coding. Scheduling at ~02:00 keeps the two from colliding within a session window, but if weekly caps ever pinch, the levers are (in order): lower `--max-turns`, run the agentic tier every other night, or drop the apply model to a cheaper tier while keeping the audit on the default.

## 10. Scheduling — macOS (resolved)

A **LaunchAgent** (user domain — *not* a LaunchDaemon) at `~/Library/LaunchAgents/com.nightshift.plist` with `StartCalendarInterval` set to 02:00, `StandardOutPath`/`StandardErrorPath` pointed at the night's log dir. User domain matters twice over: the job runs with your login Keychain available (where Claude Code's subscription OAuth credentials live) and with your `gh` auth. Unlike cron, launchd runs a missed calendar job when the Mac wakes, so a lid closed at 02:00 means a late run, not a skipped one; add `pmset repeat wakeorpoweron MTWRFSU 01:58:00` if you want the machine to wake itself on schedule. The orchestrator wraps itself in `caffeinate -i` so the Mac doesn't idle-sleep mid-verification. The honest constraint remains: the Mac must be on (or wakeable) and you logged in for the user-domain agent to fire.

Auth specifics on subscription: log in once interactively (`claude` → `/login`) on this Mac, then verify `claude -p "ping"` succeeds from a non-interactive shell (e.g. via `launchctl kickstart` of a test job). If the launchd context ever fails to reach the Keychain credentials, the sanctioned fallback is `claude setup-token` — a one-year, inference-only OAuth token for Pro/Max/Team plans that you export as `CLAUDE_CODE_OAUTH_TOKEN` from `~/.nightshift.env`. Same subscription pool, no per-token billing.

## 11. Failure handling & idempotency

Re-running the same night is a no-op past any stage that already completed (stage markers in the log dir). Upstream churn between night and morning is handled at promote time (rebase + re-gate). Flaky tests: one automatic retry of the failing subset before declaring red. Every abnormal exit still sends the email — silence is itself a failure mode, so a missing morning email means "check the machine."

## 12. Success metrics

Net LOC removed or simplified per week; % of drafted branches you actually promote (target > 60% after tuning — lower means the selector is wasting your mornings); upstream PR acceptance rate once you start promoting there; zero broken branches shipped (hard invariant); nightly run reliability > 95%; cost per night (subscription: turns; API: dollars).

## 13. Milestones

- **M0 — Bootstrap (½ day):** fork + clone, `jac` toolchain built via `./scripts/fresh_env.sh` (Zig 0.16.0) and `jac check`/`jac test` green on a virgin clone (time the test run — it sets the §14-Q4 budget), `pipx install pre-commit` (do NOT `pre-commit install` — the gate runs it explicitly), Claude Code authed via `/login` on your Pro/Max account and verified headless (`claude -p "ping"` from a non-interactive shell), ponytail installed (`/plugin marketplace add DietrichGebert/ponytail` → `/plugin install ponytail@ponytail`; needs Node on PATH for its hooks), `jac guide --export ~/.claude/skills`, register the compiler server at local scope from inside the clone (`claude mcp add jac -- jac mcp` — stored in `~/.claude.json` keyed to the project path, so the clone stays a pristine mirror; **not** a committed `.mcp.json`), `gh` authed.
- **M1 — Deterministic tier + email (1 day):** Stages 0–2 + 4–6 wired end to end; first real digest email lands.
- **M2 — Agentic tier (1–2 days):** audit → select → apply on one package with all caps enforced; first drafted branch.
- **M3 — Ledger + rotation (½ day):** dedupe across nights, package rotation, retry/reject lifecycle.
- **M4 — Promote/discard + polish (½ day):** morning commands, fragment renaming, stale-branch pruning, docs.

## 14. Open questions

1. ~~OS of the machine~~ **Resolved: macOS** → LaunchAgent plan in §10.
2. ~~Claude Code auth~~ **Resolved: Pro/Max subscription** → `--max-turns` is the cost brake (§9); `/login` once + `setup-token` fallback (§10).
3. ~~Email transport~~ **Defaulted: stdlib `smtplib` over SSL with an app password**; swap to msmtp later if desired (isolated in one module).
4. ~~Test scope~~ **Resolved: full `jac test` (every package with tests) every night** — the 3 h envelope accommodates it. The M0 timing run now calibrates *how many themes fit per night*, not whether to subset the suite.
5. ~~Ponytail mode~~ **Defaulted: `full` for the apply phase.** `ultra` may be enabled for the *audit's suggestions only* (never edits) after a few weeks of promote-rate data.
6. ~~Discord courtesy ping~~ **Resolved: no ping** (owner decision). Consequence: the first upstream PRs introduce themselves on merit alone, so the promote bar should be extra conservative early — small diffs, obviously-correct deletions first.

*Nothing remains open. The technical PRD's feasibility audit (§2 there) verifies every load-bearing assumption; three machine-specific facts remain empirical and sit in the M0 checklist.*

## 15. Appendix — verified command cheatsheet

```bash
# Jac toolchain
jac format .            # formatter        jac lint . --fix   # lint w/ autofix
jac check               # type-check gate  jac check --lint   # lint report
JAC_TEST_JOBS=auto jac test tests   # per-package tests (run inside each pkg dir); no pytest/.venv
jac mcp                 # built-in MCP server (stdio default; --mode lite|standard|full)
jac guide --export ~/.claude/skills   # export Jac guides as Agent Skills

# Claude Code headless (verified against official headless docs)
claude -p "<prompt with /ponytail-audit etc.>" \
  --permission-mode acceptEdits \
  --allowedTools "Read,Edit,Grep,Glob,Bash(jac *),mcp__jac__*" \
  --max-turns 80 --max-budget-usd 5 --output-format json
# Do NOT pass --bare: it would skip plugins (ponytail), skills, and .mcp.json.

# Fork sync + morning promote
gh repo sync <you>/jaseci --source jaseci-labs/jaseci --branch main
gh pr create --repo jaseci-labs/jaseci --head <you>:<branch> \
  --title "<from draft>" --body-file <draft.md>
```

**Sources:** docs.jaseci.org (CLI, MCP, config, contributing) · github.com/jaseci-labs/jaseci · github.com/DietrichGebert/ponytail · code.claude.com/docs/en/headless