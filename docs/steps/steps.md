# Nightshift — Implementation Steps

This folder turns the two PRDs — [`docs/PRD.md`](../PRD.md) (what & why) and
[`docs/TechnicalPRD.md`](../TechnicalPRD.md) (exactly how) — into fourteen
executable steps. Each `stepN.md` is a self-contained recipe: goal, prerequisites,
full file contents, commands, acceptance criteria, verification procedure, and traps.
Follow them in order; every step ends with something you can run and check.

**What is being built.** Nightshift is an unattended nightly harness on a Mac that
syncs a fork of `jaseci-labs/jaseci`, runs a deterministic clean (`jac format` /
`jac lint --fix` / pre-commit), then bounded headless Claude Code sessions (ponytail
skill + Jac agent skills + `jac mcp`) that audit and apply cleanup themes, gates
every branch behind `jac check` + full `jac test` (per package) + `pre-commit`
(fail-closed), pushes survivors to the fork with PR-draft `.md` files on an orphan
`nightshift/drafts` branch, updates a JSONL ledger, and emails a digest. Morning
commands `promote`/`discard` open the real PR or bury the branch.

## Nightly flow (PRD §6)

```
02:00 local ──▶ [S0 Preflight] ─▶ [S1 Sync fork w/ upstream main]
                                      │
                                      ▼
                          [S2 Tier 1: deterministic clean]
                            jac fmt · lint --fix · pre-commit
                                      │
                                      ▼
                          [S3 Tier 2: agentic clean]
                            claude -p  (ponytail + jac mcp + jac skills)
                            audit ─▶ select ─▶ apply (≤3 themes)
                                      │
                                      ▼
                          [S4 Verify gate — fail closed]
                            scope · jac check · jac test (per pkg) · pre-commit
                              red? ─▶ discard branch, log, continue
                                      │ green
                                      ▼
                          [S5 Ship to fork]
                            push branch · write PR-draft .md · update ledger
                                      │
                                      ▼
                          [S6 Email digest]
                                      │
        morning ──▶ [S7 Human loop]  promote │ discard
```

## The language split (locked decision)

> **bash sequences processes; Jac owns every data and logic transformation.
> There are no Python files in this harness.**

- **bash** (`bin/nightshift.sh`, `lib/*.sh`): stage ordering, git/gh/claude/jac-test
  invocations, traps, time-boxes, lock files. Bash never parses or composes JSON.
- **Jac** (`scripts/*.jac`): fingerprinting, ledger, config flattening, finding
  selection/packing, Claude-envelope parsing, scope gate, draft rendering, email.
  Jac reaches Python's stdlib through its interop (`import from hashlib { sha1 }`),
  so nothing needs a `.py` file.
- Unchanged from the PRDs: the launchd plist stays XML, prompts stay markdown.

Invocation convention: every Jac helper is a standalone CLI —
`jac run scripts/<name>.jac <subcommand> [args…]` — always executed **from
`~/nightshift/`** (the `ns_jac` wrapper in `lib/common.sh` guarantees this; jac
writes a `.jac` cache directory into the cwd).

## Jac 0.16.1 ground rules (compiler-verified)

Every Jac file in these docs was validated with `jac check` and `jac test` against
**jac 0.16.1**. When you (or an agent) modify them, these are the rules that bit
during authoring — all confirmed empirically:

1. **Blocks `{}`, statements end `;`**. Brace imports take **no** trailing
   semicolon: `import from hashlib { sha1 }` — but `import os;` does.
2. **Docstrings go immediately *above* a `def`, never inside its body** (in-body
   docstrings are a parse error / W0060).
3. **Tests**: `test "name" { assert <expr>; }`, run with `jac test file.jac`.
   There is no `check` keyword in 0.16.1 — use `assert`.
4. **`jac test` also executes the `with entry` block**, with `sys.argv` set to the
   jac CLI's own arguments. Therefore every entry block dispatches on an exact
   subcommand match and **never reads stdin or exits non-zero by default**.
5. **JSON/TOML boundaries are `any`** and Jac's checker refuses `any → T`
   assignment. Narrow with `isinstance` guards — `nslib.jac` provides
   `parse_obj/parse_list/as_dict/as_list/as_int/as_float` for exactly this.
6. **`sys.stderr`/`sys.stdin` are typed `TextIO | Any`** — attribute access fails.
   Use `nslib.eprint()` / `nslib.read_stdin()` (bind to `any` first).
   `print(..., file=sys.stderr)` does not typecheck either.
7. **Reserved keywords** you will actually trip on: `report`, `glob`, `visit`,
   `node`, `edge`, `walker`. A variable named `report` or an
   `import from glob { glob }` is a hard error (use `rep`, and
   `pathlib.Path.glob` instead of the glob module).
8. **Never name a helper file after a Python stdlib module.** A file called
   `select.jac` shadows stdlib `select` inside jaclang's importer and breaks the
   entire compiler with a circular-import error — hence `selector.jac`. (The
   TechnicalPRD's `select.py` would have hit the same mine.)
9. Unused names fail a clean check (W2003) — prefix with `_`. Booleans are
   `True`/`False`, null is `None`. No `pass` statement — use `{}`.
10. Stale bytecode is real: `rm -rf .jac` in the working dir (or `jac clean
    --cache` inside a project) when errors make no sense.

## Step order and dependency graph

| Step | Builds | Stage | Milestone |
|---|---|---|---|
| [step1](step1.md) | Bootstrap: fork, toolchain, Claude auth, ponytail, workspace | — | M0 |
| [step2](step2.md) | `nightshift.toml`, `nslib.jac`, `config.jac`, `timeout.jac`, `lib/common.sh` | — | M0/M1 |
| [step3](step3.md) | `ledger.jac` + `state.json` lifecycle | — | M3 (early) |
| [step4](step4.md) | `lib/preflight.sh` | S0 | M1 |
| [step5](step5.md) | `lib/sync.sh` + worktrees + orphan drafts branch | S1 | M1 |
| [step6](step6.md) | `lib/tier1.sh` deterministic clean | S2 | M1 |
| [step7](step7.md) | `check_scope.jac` + `lib/verify.sh` fail-closed gate | S4 | M1 |
| [step8](step8.md) | `sendmail.jac` + `lib/email.sh` + entry script + trap | S6 | M1 ✅ end-to-end |
| [step9](step9.md) | `prompts/audit.md` + `parse_result.jac` + audit phase | S3-A | M2 |
| [step10](step10.md) | `selector.jac` scoring/packing/rotation | S3-B | M2 |
| [step11](step11.md) | `prompts/apply.md` + apply phase | S3-C | M2 |
| [step12](step12.md) | `render_draft.jac` + `lib/ship.sh` | S5 | M2/M3 |
| [step13](step13.md) | `promote` / `discard` / `status` commands | S7 | M4 |
| [step14](step14.md) | launchd install, dry-run, harness test suite | — | M4 ✅ done |

Dependencies: `1 → 2 → {3,4,5,6} → 7 → 8` (after step8 the deterministic tier is a
complete, gated, emailed pipeline — PRD milestone M1), then `9 → 10 → 11 → 12`
(agentic tier, M2/M3), then `13 → 14` (morning loop + hardening, M4).

## Execution protocol (for the human or agent doing the build)

1. Do the steps **in order**; don't start a step before its prerequisites' acceptance
   checklists pass.
2. Every `.jac` file goes through `jac check` (and `jac test` where the file has
   tests) **before** it is considered written. The code in these docs compiled
   against jac 0.16.1 on 2026-07-10; a newer jac may need adjustments — the ground
   rules above tell you where to look first.
3. Every `.sh` file goes through `bash -n` at minimum; step14's harness tests are
   the real check.
4. Nothing is pushed anywhere except: the fork (`origin`), only `nightshift/*`
   refs, never force (except promote's `--force-with-lease` after a rebase). The
   human is the only path to upstream.
5. When a step's verification needs the real jaseci clone and one isn't ready,
   step14's `fixtures/mini-jac-repo` stands in.

## Budgets & guardrails (PRD §9 — invariants no step may violate)

| Guardrail | Default |
|---|---|
| Themes/night · files/theme · changed LOC/theme | ≤ 3 · ≤ 10 · ≤ 300 |
| Agent session limits | `--max-turns 80` (the real brake on subscription), `--max-budget-usd 5` (belt) |
| Wall clock | 180 min hard ceiling; stage boxes 15/90/65/10 |
| Protected paths | `**/tests/**`, fixtures, `jac.spec`/grammar, generated/vendored, `docs/**` (except release-note fragments), `.github/**`, `examples/**` |
| Branch hygiene | bot touches only `nightshift/*`; never force-push; never touches `main` |
| Ponytail never-cut | trust-boundary validation, data-loss error handling, security, accessibility |
| Secrets | `~/.nightshift.env` chmod 600; **`ANTHROPIC_API_KEY` force-unset** every run |
| Kill switch | `~/.nightshift/DISABLE` file; mkdir lock prevents overlap |

## Glossary

- **Workspace** `~/nightshift/` — layout in TechnicalPRD §4; created in step1.
- **Exit codes** (TechnicalPRD §18): `0` ok · `40` lock held · `41` disabled ·
  `42` claude auth · `43` offline · `44` sync conflict · `50` audit malformed ·
  `51` all themes failed verify · `60` wall-clock ceiling · `70` internal bug.
- **Finding statuses** (TechnicalPRD §9): `new → drafted → shipped` (happy path),
  `rejected` (never resurfaces), `failed_verify` (retry once, then auto-reject),
  `deferred` (didn't fit budget; eligible next rotation).
- **Fingerprint**: `sha1(relpath + "\x1f" + rule + "\x1f" + whitespace-normalized
  snippet)` — a finding's identity across nights.
- **Draft**: `nightshift/drafts:drafts/YYYY-MM-DD--<slug>.md` — frontmatter is
  machine-read by `promote`; its body is the verbatim PR body. A draft file
  existing means "PR not yet opened."
- **queue.tsv / green.tsv** (per-night, in the log dir): the S2/S3 → S4 → S5
  handoff. Line format `branch⇥theme.json-or-"-"⇥report.json-or-"-"`.
