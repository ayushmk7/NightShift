# Nightshift v2 Plan 5: Migration to `~/nightshift`, branch reset, cutover

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **THIS IS THE ONLY DESTRUCTIVE PLAN IN THE SERIES.** Tasks 7 and 8 delete branches on GitHub. That is irreversible. Every irreversible step is preceded by a listing step and an operator confirmation step that the operator can stop between. No step deletes anything it has not just printed.

**Goal:** Move the whole harness off the external volume to `~/nightshift`, which deletes the `osascript` → Terminal.app TCC workaround by removing its cause; widen the night to 23:00 → 07:00 with an 8h ceiling; harden missed-night detection so a schedule that stops firing is visible; reset the fork to base; and cut over with the old tree kept intact but scheduled-off.

**Architecture:** Five layers, strictly ordered, each one provable before the next. (1) A human decision gate on tier-1's scope, first, because "retire tier-1" would delete work every later task would otherwise carry across. (2) A new tree at `~/nightshift`: the harness repo cloned, the target repo cloned fresh and rebuilt with `scripts/fresh_env.sh`, and the three test baselines copied and proven byte-identical — they cost six full suite runs and `state/` is gitignored, so a naive clone loses them silently. (3) Config and plist repointed together: `[paths]`, `[budgets].wallclock_min`, and `StartCalendarInterval` are three knobs describing one window, and a harness tripwire keeps two of them in lockstep. (4) The reset, split into a read-only enumeration task and a deletion task with a confirmation between them. (5) Cutover, where the first scheduled fire happens with the kill switch still in place — a fire that proves the schedule while doing no work — and `rm ~/.nightshift/DISABLE` is the last step of the last task.

**Tech Stack:** bash 3.2.57 (macOS stock), Jac 0.16.1 for every data/logic helper, `gh` CLI, launchd LaunchAgent, the target repo's Zig-built dev `jac` binary.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-30-nightshift-4task-design.md`, sections 4 (window), 15 (migration), 16 (reset), 17 (missed nights). **Carry-forward:** `docs/superpowers/specs/2026-07-30-nightshift-followups.md` section 6, plus the unanswered tier-1 decision in section 1.
- **No Python files.** bash sequences processes; Jac owns every data and logic transformation. Standing project rule.
- **bash is 3.2.57.** No `wait -n`, no associative arrays, no `${var^^}`. Under `set -u` an **empty** array aborts both `${#arr[@]}` and `"${arr[@]}"`, and `bin/nightshift.sh` runs `set -euo pipefail` — use a space-joined string and a counter instead. A guard must not return nonzero on its success path; use `case`, not a trailing `[ … ] && …` list.
- **Two jac binaries, never mixed.** `$NS_PATHS_JAC` runs the harness's own `scripts/*.jac`; `$NS_PATHS_JAC_REPO` is the target repo's dev binary for every repo-facing gate. **Both paths change in this migration.** That is the single largest risk in this plan: if `jac_repo` is left pointing at `/Volumes/ExtremePro/...` and that volume is mounted, every repo gate silently runs the *old* binary against the *new* clone and reports green. Task 4 asserts against this explicitly.
- **`bin/test-harness.sh` must print `ALL HARNESS TESTS PASSED`** at every commit in this plan, **and must pass at the new location** before cutover (Task 5).
- **`work/`, `state/`, `logs/` are gitignored with nothing tracked.** Anything in them that must survive is copied by hand and verified at the destination, or it is gone.
- **Not `~/Downloads`.** Desktop, Documents, and Downloads are the three TCC-protected user folders on macOS; moving there would reproduce the exact permission class this move exists to escape. Home root is not TCC-protected.
- **Deliberate simplifications carry a `ponytail:` comment naming the ceiling AND the upgrade path.**

## The defect class to design against

**"Did not run" scoring as "passed."** Seven instances were found in Plan 1, every one in the gate, none caught by tests that were passing (followups §8). Migration-specific instances of the same class, which this plan asserts positively against rather than inferring from an absence of errors:

| Silent-pass risk | Where | Positive assertion |
|---|---|---|
| Harness green at the new location because section 5 printed `SKIP: no work/repo clone present` | `bin/test-harness.sh:63` | Task 5 greps for the *pass* line, not for absence of `FAIL` |
| Gate green because it ran the OLD `jac_repo` binary off the still-mounted volume | `config/nightshift.toml:86` | Task 4 asserts no `/Volumes` string survives in config, and that `$NS_PATHS_JAC_REPO` resolves under `$HOME/nightshift` |
| A baseline "copied" that is empty or truncated | `state/test-baseline/*.json` | Task 3 `cmp`s byte-for-byte **and** re-reads the counts at the destination |
| A dry run that passed because it audited nothing | Task 5 | Assert a nonzero findings count and a nonzero `collected` per suite |
| Missed-night detection reporting clean because the log it reads is absent | `lib/preflight.sh:62` | Task 6 makes "no fire line AND no run dir" its own warning class |

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `config/nightshift.toml` | every knob | Modify: `[paths].jac_repo`, `[budgets].wallclock_min` |
| `config/com.nightshift.installed.plist` | the LaunchAgent actually installed | Modify: direct invocation, 23:00, new paths, `osascript` deleted |
| `config/com.nightshift.plist` | the template plist | **Delete** — it now duplicates the installed one exactly |
| `lib/preflight.sh` | S0 | Modify: never-fired detection alongside fired-but-no-run |
| `scripts/render_draft.jac` | draft/fragment rendering | Modify: `main...HEAD` → `$NS_REPO_DEFAULT_BRANCH` (followups §6) |
| `bin/test-harness.sh` | CI of the harness | Modify: window-lockstep tripwire (section 11) |
| `~/nightshift/` | the new runtime root | **Create** (outside the repo) |

---

### Task 1: DECISION GATE — tier-1's formatting scope

**This task writes no code and blocks every task after it.** It is first because "retire tier-1" deletes work that Tasks 3-5 would otherwise carry across: `[jobs.fmt_autofix]` in `config/ci-mirror.toml`, tier-1's apply step in `lib/tier1.sh`, and `bin/test-harness.sh` section 6, which exists solely to keep `[jobs.fmt]` and `[jobs.fmt_autofix]` sharing one exclusion regex. Migrating all of it and then deleting it a week later is wasted verification, and verification is the expensive part of this plan.

**Files:** none. Output is a decision recorded in `docs/superpowers/specs/2026-07-30-nightshift-followups.md` §1.

**Interfaces:** none.

- [ ] **Step 1: Print the evidence the decision rests on**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
grep -n -A3 '^commands' config/ci-mirror.toml | grep -n 'byllm'
grep -c '' <(cd work/repo && git ls-files '*.jac')
```

Expected: `[jobs.fmt_autofix]`'s single command scoped to `jac/jaclang/byllm/*.jac`; a repo-wide `.jac` count in the ~1,475 range. The narrow scope is a leftover of the package rotation Plan 1 deleted (followups §1) — nothing justifies that directory now.

- [ ] **Step 2: Put the four options and their migration cost to the human owner**

| Option | Migration cost | Consequence |
|---|---|---|
| **Keep the narrow scope** | zero — everything moves as-is | The directory stays meaningless. Smallest risk. |
| **Retire tier-1** | *negative* — delete `[jobs.fmt_autofix]`, `lib/tier1.sh`'s fmt step, harness §6 | Upstream `main` carries ~259 whole-repo formatting violations and CI only checks repo-wide on `push`, so upstream evidently tolerates them. A 259-file PR is unmergeable; a byllm-only one is noise. |
| **Diff-scope it like CI** | structurally awkward | Tier-1 runs *before* the agentic tier, so there is no diff to scope against yet. |
| **Fold formatting into each theme's branch** | Plan 2/3 territory, not this plan | fmt fixes ride along with changes that were going to touch those files anyway. Strictly less machinery than a standalone pass. |

Plan 1 verified that its tier-1 release-note-fragment fix survives **all four** outcomes: the fragment path derives from the actual diff via `render_draft frag`, never from `fmt_autofix`'s scope. So no option here can break the fragment path.

- [ ] **Step 3: Record the answer and stop if there is none**

Append the decision, with its date and one line of reasoning, to §1 of `docs/superpowers/specs/2026-07-30-nightshift-followups.md`. **If the human has not answered, stop here.** Do not default to "keep" silently — an unanswered gate that quietly picks an option is the same defect class this plan is designed against, one layer up.

If the answer is **retire**, insert a new task between this one and Task 2 that deletes `[jobs.fmt_autofix]`, tier-1's fmt apply step, and harness section 6 on `main` **before** anything is copied to the new location, and commit it. Nothing else in this plan changes.

---

### Task 2: Pre-move inventory, and the one code fix Plan 5 owns

Two jobs: record exactly what has to survive the move so Task 3 can be checked against a list rather than against memory, and land the `render_draft.jac` hardcode from followups §6 on `main` *before* the clone, so the new location gets it for free.

**Files:**
- Modify: `scripts/render_draft.jac:127,130`
- Create (untracked, scratch): `/tmp/ns-migration-manifest.txt`

**Interfaces:**
- Produces: a manifest of every un-tracked artifact that must exist at the destination, used as the checklist in Task 3 Step 7.

- [ ] **Step 1: Record what is actually in the untracked runtime tree**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
du -sh work work/repo work/drafts state logs
find state -type f | sort
```

Expected, as measured 2026-07-30: `work` 1.4G (essentially all `work/repo`), `work/drafts` 136K, `state` 76K, `logs` 394M. `state/` holds exactly five files: `state.json`, `ledger.jsonl.cache`, and `test-baseline/{compiler,runtime,byllm}.json`.

- [ ] **Step 2: Decide, in one line each, what moves**

Write these decisions into `/tmp/ns-migration-manifest.txt` so Task 3 checks against a list:

```bash
cat > /tmp/ns-migration-manifest.txt <<'EOF'
MOVE   state/test-baseline/compiler.json   # 2792 collected / 9 known-failing, union of 2 runs
MOVE   state/test-baseline/runtime.json    # 1852 collected / 26 known-failing, union of 2 runs
MOVE   state/test-baseline/byllm.json      # 219 collected / 3 known-failing, union of 2 runs
FRESH  state/state.json                    # 2 keys, both re-derived on the first night
FRESH  state/ledger.jsonl.cache            # Task 8 clears the ledger anyway; copying then clearing is theatre
CLONE  work/repo                           # 1.4G; Task 8 resets main to fresh upstream and deletes every
                                           #   nightshift/* local branch, so a clone IS the reset, cheaper
                                           #   and more honest than copy-then-prune
SKIP   work/drafts                         # a git worktree pinned to nightshift/drafts, which Task 8 deletes;
                                           #   lib/sync.sh drafts_bootstrap recreates it on the first night
SKIP   logs/                               # 394M of historical run dirs, gitignored, read by exactly two things:
                                           #   dataset-backfill (already run; dataset/*.jsonl is COMMITTED) and
                                           #   preflight's missed-night check (Task 6 resets its input instead).
                                           #   The old tree stays on the volume; nothing is deleted by leaving it.
EOF
cat /tmp/ns-migration-manifest.txt
```

The three baselines are the only artifacts here that cannot be recreated cheaply: they cost six full suite runs (two per suite, unioned so a test that flakes in either run is treated as known-failing — the fix for the 07-21/07-23 failure mode).

- [ ] **Step 3: Fix `render_draft.jac`'s hardcoded `main`**

followups §6. Two `subprocess.run` calls at lines 127 and 130 pass the literal `"main...HEAD"`. It fails closed today (both use `check=True`, so the night aborts rather than producing an empty file list), but tier-1's fragment path now leans on it, and a migration that changes clone provenance is exactly when a hardcoded branch name stops being harmless. Read lines 118-135 first to match the surrounding style, then replace the two literals with a value read from the environment:

```jac
    base: str = os.environ.get("NS_REPO_DEFAULT_BRANCH", "main");
    rng: str = base + "...HEAD";
```

and use `rng` in both calls. `os` is already imported at the top of the file; confirm before adding an import.

- [ ] **Step 4: Add a test that the range is not hardcoded**

Append to `scripts/render_draft.jac`'s test block:

```jac
test "diff range follows NS_REPO_DEFAULT_BRANCH, not a hardcoded main" {
    os.environ["NS_REPO_DEFAULT_BRANCH"] = "develop";
    assert diff_range() == "develop...HEAD";
    del os.environ["NS_REPO_DEFAULT_BRANCH"];
    assert diff_range() == "main...HEAD";
}
```

This requires factoring the two lines into a `def diff_range() -> str` rather than inlining them — do that, so there is one place to test. A test asserting only `"main...HEAD"` would pass against the unfixed code and is worthless here (followups §8, "an assertion that cannot fail"): mutate the default to `"trunk"` and confirm the first assert still passes while the second fails.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/render_draft.jac
```

Expected: PASS, including the new test.

- [ ] **Step 5: Harness green, then commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh | tail -1
```

Expected: `ALL HARNESS TESTS PASSED`.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add scripts/render_draft.jac
git commit -m "Read the diff base from NS_REPO_DEFAULT_BRANCH instead of hardcoding main

render_draft's git_report passed a literal main...HEAD to both git calls. It
failed closed (check=True aborts the night rather than emitting an empty file
list), but tier-1's release-note fragment path now derives from it, and Plan 5
re-clones the target repo — the moment a hardcoded branch name stops being
harmless. Factored into diff_range() so there is one place to test, and the
test mutates the default so it cannot pass against the old code."
```

---

### Task 3: Build `~/nightshift`

Create the new tree and prove every artifact arrived. Nothing is deleted from the old location by this task; the old tree stays exactly as it is until the operator chooses otherwise, long after cutover.

**Files:**
- Create: `~/nightshift/` (harness clone), `~/nightshift/work/repo` (target repo clone), `~/nightshift/state/`, `~/nightshift/logs/`

**Interfaces:**
- Produces: `~/nightshift/bin/nightshift.sh` and the three baselines under `~/nightshift/state/test-baseline/`, verified byte-identical to their sources.

- [ ] **Step 1: Confirm the destination has room and is not TCC-protected**

```bash
df -h / | tail -1
ls -d ~/nightshift 2>/dev/null && echo "ALREADY EXISTS — stop and inspect" || echo "clear"
```

Expected: well over 3G available on `/` (measured 149Gi on 2026-07-30) — the target repo clone is 1.4G, `zig build fetch-llvm` adds ~0.35G, and the dev build adds more. And `clear`. Home root is not one of macOS's three TCC-protected user folders (Desktop, Documents, Downloads), which is the entire reason this destination and not those.

- [ ] **Step 2: Clone the harness repo**

```bash
git clone /Volumes/ExtremePro/JaseciLabs/NightShift ~/nightshift
cd ~/nightshift && git log --oneline -1 && git status --short
```

Expected: the Task 2 commit at HEAD, and a clean tree. Cloning rather than copying is deliberate: a `cp -R` would carry `.jac/`, `logs/`, `work/`, and `state/` — every gitignored thing — and hide the fact that they need explicit handling. The clone's `origin` points at the volume; leave it for now, Task 9 Step 6 repoints it.

- [ ] **Step 3: Clone the target repo and set both remotes**

```bash
mkdir -p ~/nightshift/work
git clone https://github.com/ayushmk7/jaseci.git ~/nightshift/work/repo
cd ~/nightshift/work/repo
git remote add upstream https://github.com/jaseci-labs/jac.git
git remote -v
```

Expected: `origin` → `ayushmk7/jaseci`, `upstream` → `jaseci-labs/jac`. **Use the canonical `jaseci-labs/jac` URL, not `jaseci-labs/jaseci`** — the old tree's remote still says `jaseci` and only works because GitHub redirects. `lib/preflight.sh:34` runs `git fetch --dry-run upstream` and dies `EX_OFFLINE` if it fails, so a wrong remote here kills every night at S0.

- [ ] **Step 4: Assert the clone is on main and has no nightshift branches**

```bash
cd ~/nightshift/work/repo
git branch -a | grep -c 'nightshift/\|prune/\|split/\|chore/dead-code' || echo 0
git rev-parse --abbrev-ref HEAD
```

Expected: the branch count is 0 for **local** branches (a fresh clone has only `main`); remote-tracking refs for the doomed branches will still be listed until Task 8 deletes them upstream and a fetch prunes them — that is fine and expected. `HEAD` is `main`.

- [ ] **Step 5: Build the dev jac binary**

```bash
cd ~/nightshift/work/repo && time scripts/fresh_env.sh 2>&1 | tail -20
```

Expected, in order: `zig build fetch-llvm` (~0.35G range-fetched into `jac/.llvm-build`), `fetch-bun`, then `zig build -Ddev -Dpayload-progress`, ending in `Built: /Users/ayush/nightshift/work/repo/jac/zig-out/bin/jac` and `Done. Ensure 'jac' stays on PATH for the git hooks.` This is the slowest step in the plan; budget real time for it.

Note what this step does **not** need to redo: `jac install --global` installs byLLM's `llm` deps into a HOME-derived location, and `jac precommit --install` writes hooks into the new clone. The first already survived the move by being global; the second is why `fresh_env.sh` is run rather than just `zig build`.

- [ ] **Step 6: Assert the new binary exists and is the one that will be used**

```bash
NEW=~/nightshift/work/repo/jac/zig-out/bin/jac
[ -x "$NEW" ] && "$NEW" --version | head -1 || echo "MISSING"
```

Expected: a version line, not `MISSING`. If this is missing, stop — Task 4 is about to write this path into the config, and a config pointing at a nonexistent binary makes every repo gate fail loudly (acceptable) while a config pointing at the *old* binary makes them pass misleadingly (not acceptable).

- [ ] **Step 7: Copy the three baselines and prove they arrived byte-identical**

This is the step the whole task exists for. `state/` is gitignored, so Step 2's clone brought none of it.

```bash
OLD=/Volumes/ExtremePro/JaseciLabs/NightShift
mkdir -p ~/nightshift/state/test-baseline
cp "$OLD"/state/test-baseline/*.json ~/nightshift/state/test-baseline/
for s in compiler runtime byllm; do
  cmp "$OLD/state/test-baseline/$s.json" ~/nightshift/state/test-baseline/$s.json \
    && echo "identical: $s" || echo "MISMATCH: $s"
done
```

Expected: three `identical:` lines. `cmp` with no output on success and an explicit `identical:` echo, rather than `cp && echo ok` — a `cp` that wrote a zero-byte file also exits 0.

- [ ] **Step 8: Re-read the counts at the destination, not at the source**

`cmp` proves the bytes match. It does not prove the bytes are a *usable* baseline — a pair of identically-empty files would pass Step 7. Assert the recorded numbers positively:

```bash
cd ~/nightshift
for s in compiler runtime byllm; do
  printf '%s\t%s\n' "$s" \
    "$(tr ',' '\n' < "state/test-baseline/$s.json" \
       | grep -oE '"(collected|count|runs)": *[0-9]+' | tr -d '"' | tr '\n' ' ')"
done
```

Expected exactly: `compiler` with `count: 9 runs: 2 collected: 2792`, `runtime` with `count: 26 runs: 2 collected: 1852`, `byllm` with `count: 3 runs: 2 collected: 219` (key order follows the file). Any `runs: 1`, any `collected: 0`, or any missing key means the baseline is not the one that cost six suite runs — recover it from the old tree before continuing. A `collected: 0` baseline is one of the seven Plan-1 false-greens by name (followups §8 item 3): it lets a branch collecting 3-of-200 tests pass the gate.

`grep`/`tr` rather than a Python one-liner: the no-Python-files rule is a standing project rule and this is a three-field read, not a data transformation that wants Jac.

- [ ] **Step 9: Write fresh state, do not copy it**

```bash
cd ~/nightshift
printf '{\n  "last_jac_version": "0.16.1",\n  "verify_estimate_min": 1\n}\n' > state/state.json
: > state/ledger.jsonl.cache
mkdir -p logs
cat state/state.json && wc -c < state/ledger.jsonl.cache
```

Expected: the two-key JSON, and `0` bytes of ledger. Task 8 clears the ledger as part of the reset; copying 113 rows across only to delete them is motion without progress. `last_jac_version` is re-derived by preflight on the first night anyway — it is seeded here only so the drift warning at `lib/preflight.sh:42` has something to compare against instead of firing spuriously.

---

### Task 4: Repoint config and install the new plist

The two absolute paths and the window live here. Config and plist are **two separate files stating the same window**, and a mismatch does not fail — it silently truncates the night, because `ns_run`'s watchdog (`bin/nightshift.sh:80`) sleeps `wallclock_min * 60` from process start and then `kill -TERM $$`. A 23:00 fire with `wallclock_min = 180` kills the night at 02:00 and reports it as a clean timeout.

**Files:**
- Modify: `~/nightshift/config/nightshift.toml` (`[paths].jac_repo`, `[budgets].wallclock_min`)
- Modify: `~/nightshift/config/com.nightshift.installed.plist` (direct invocation, 23:00, new paths)
- Delete: `~/nightshift/config/com.nightshift.plist`
- Modify: `~/nightshift/bin/test-harness.sh` (new section 11)

**Interfaces:**
- Produces: `bin/test-harness.sh` section 11 — asserts the tracked plist's `StartCalendarInterval` hour plus `[budgets].wallclock_min` land on 07:00, so the two files cannot drift apart silently.

- [ ] **Step 1: Find every absolute path that has to change**

```bash
cd ~/nightshift
grep -rn 'ExtremePro\|/Volumes/' bin lib scripts config prompts docs/superpowers/plans 2>/dev/null | grep -v '^docs/'
```

Expected exactly two hits in code/config: `config/nightshift.toml:86` (`jac_repo`) and `config/com.nightshift.installed.plist:21` (the `osascript` target). Everything else is already `$NS_ROOT`-relative or `$HOME`-relative. `[paths].jac`, `claude`, `gh`, and `precommit` are all home- or Homebrew-rooted and do not change.

- [ ] **Step 2: Repoint `jac_repo` and widen the window**

In `~/nightshift/config/nightshift.toml`:

```toml
wallclock_min      = 480                     # 23:00 -> 07:00, an 8h ceiling (spec section 4; was 180
                                              # with an 02:00 fire). THIS NUMBER AND THE PLIST'S
                                              # StartCalendarInterval ARE ONE WINDOW STATED TWICE:
                                              # bin/nightshift.sh's watchdog sleeps wallclock_min*60
                                              # from process start and TERMs the run, so a plist that
                                              # fires at 23:00 against a stale 180 kills the night at
                                              # 02:00 and it looks like a clean timeout. Change both
                                              # or neither; bin/test-harness.sh section 11 checks it.
```

```toml
jac_repo = "/Users/ayush/nightshift/work/repo/jac/zig-out/bin/jac"
```

Use the literal `/Users/ayush/...`, not `~` or `$HOME`: this file is read by `scripts/config.jac` and by `ns_bootstrap_jac`'s `sed` (`lib/common.sh:37`), neither of which expands shell metacharacters.

- [ ] **Step 3: Assert no volume path survives**

```bash
cd ~/nightshift
grep -rn '/Volumes/' config/ && echo "STILL POINTS AT THE VOLUME" || echo "no volume paths in config"
. lib/common.sh 2>/dev/null; NS_ROOT=~/nightshift ns_load_config 2>/dev/null
bash -c 'NS_ROOT=$HOME/nightshift; cd $NS_ROOT; . lib/common.sh; ns_load_config; echo "jac_repo=$NS_PATHS_JAC_REPO"; case "$NS_PATHS_JAC_REPO" in "$HOME"/nightshift/*) echo "OK under new root" ;; *) echo "WRONG ROOT" ;; esac'
```

Expected: `no volume paths in config`, then `jac_repo=/Users/ayush/nightshift/work/repo/jac/zig-out/bin/jac` and `OK under new root`. The `case` is deliberate rather than `[ … ] && echo`: a false `&&` list returns nonzero, and this snippet is the sort of thing that gets pasted into a script running under `errexit`.

- [ ] **Step 4: Rewrite the installed plist — direct invocation, 23:00**

Replace `~/nightshift/config/com.nightshift.installed.plist` entirely:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.nightshift</string>
  <!-- Direct invocation. The osascript -> Terminal.app indirection this replaces existed for ONE
       reason: macOS TCC hangs (blocks forever in open()/getcwd(), never errors) any headless
       launchd agent that touches an EXTERNAL VOLUME, across every identity it forks (jac's python,
       git, claude, ...), and Full Disk Access on individual binaries does not scale to a whole
       toolchain. The harness now lives under $HOME, which is not TCC-protected, so the cause is
       gone and the workaround goes with it.
       DO NOT transplant this plist back onto an external volume. If the tree ever moves back,
       restore the osascript form from git history -- and read bin/nightshift.sh's ns_run() comment
       first: its self-caffeinate and self-timebox children are FORKED, NEVER EXEC'D, and in that
       order, for TCC reasons that are INDEPENDENT of the volume and still load-bearing here.
       `date +%F >> nightshift-fired.log` stays: it is the ONLY record that distinguishes "launchd
       fired and the run died" from "launchd never fired" (lib/preflight.sh). It runs BEFORE the
       exec so the line lands even if nightshift.sh dies at line 1. -->
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>date +%F &gt;&gt; "$HOME/Library/Logs/nightshift-fired.log"; exec "$HOME/nightshift/bin/nightshift.sh" run</string>
  </array>
  <!-- 23:00 -> 07:00. [budgets].wallclock_min = 480 is the other half of this window; see the
       comment there. bin/test-harness.sh section 11 asserts the two agree. -->
  <key>StartCalendarInterval</key><dict>
    <key>Hour</key><integer>23</integer><key>Minute</key><integer>0</integer>
  </dict>
  <key>EnvironmentVariables</key><dict>
    <!-- launchd's minimal PATH is the #1 documented cause of silent failures (TPRD row 15) -->
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <!-- Kept in ~/Library/Logs beside the fired log: one directory to look in when a night vanishes,
       and no dependency on a gitignored logs/ dir existing before the first fire. Unlike the
       osascript form, these now capture nightshift.sh's OWN output, and launchd's recorded exit
       status is now the harness's exit code rather than osascript's. -->
  <key>StandardOutPath</key><string>/Users/ayush/Library/Logs/nightshift-launchd.out</string>
  <key>StandardErrorPath</key><string>/Users/ayush/Library/Logs/nightshift-launchd.err</string>
</dict></plist>
```

No `RunAtLoad`: loading the agent must not start a night.

- [ ] **Step 5: Delete the template plist**

```bash
cd ~/nightshift && git rm config/com.nightshift.plist
```

It existed only to document the internal-disk pattern that the installed plist was not using. Now the installed plist *is* that pattern, and two files that must say the same thing are one file too many.

`ponytail:` known ceiling — the remaining plist is configuration, not code, and there is exactly one of it. No generator, no template substitution, no `$HOME` interpolation pass. Upgrade path, if a second machine ever needs one: copy the file and change two strings.

- [ ] **Step 6: Add the window-lockstep tripwire to `bin/test-harness.sh`**

Append before the final `echo "ALL HARNESS TESTS PASSED"`:

```bash
echo "== 11. window: plist StartCalendarInterval and [budgets].wallclock_min are one window =="
# Two tracked files state one window. A mismatch does not fail loudly -- bin/nightshift.sh's
# watchdog TERMs the run wallclock_min minutes after start, so a 23:00 fire against a stale
# wallclock_min just ends the night early and reports a clean timeout. Both files are TRACKED, so
# this check can never skip for a host reason (unlike section 5, which skips without work/repo).
ns_hour="$(sed -n 's/.*<key>Hour<\/key><integer>\([0-9]*\)<\/integer>.*/\1/p' \
    config/com.nightshift.installed.plist | head -1)"
ns_wall="$(sed -n 's/^wallclock_min *= *\([0-9]*\).*/\1/p' config/nightshift.toml | head -1)"
[ -n "$ns_hour" ] && [ -n "$ns_wall" ] || fail "could not read the fire hour or wallclock_min"
[ "$(( ns_wall % 60 ))" -eq 0 ] || fail "wallclock_min=$ns_wall is not a whole number of hours"
[ "$(( (ns_hour + ns_wall / 60) % 24 ))" -eq 7 ] \
    || fail "window ends at $(( (ns_hour + ns_wall / 60) % 24 )):00, not 07:00 (spec section 4): fire hour $ns_hour + ${ns_wall}m"
echo "window ok: fires ${ns_hour}:00, ceiling ${ns_wall}m, ends 07:00"
```

- [ ] **Step 7: Mutate the tripwire to prove it can fail**

Reading a tripwire is not enough — both times a Plan 1 guard turned out weaker than it looked, mutation found it and reading did not (followups §8).

```bash
cd ~/nightshift
bin/test-harness.sh 2>&1 | grep 'window ok' || echo "SECTION 11 DID NOT RUN"
sed -i '' 's/^wallclock_min      = 480/wallclock_min      = 180/' config/nightshift.toml
bin/test-harness.sh >/dev/null 2>&1 && echo "BUG: tripwire did not fire on a 180 ceiling" || echo "tripwire fires on window mismatch"
sed -i '' 's/^wallclock_min      = 180/wallclock_min      = 480/' config/nightshift.toml
sed -i '' 's|<integer>23</integer>|<integer>2</integer>|' config/com.nightshift.installed.plist
bin/test-harness.sh >/dev/null 2>&1 && echo "BUG: tripwire did not fire on a 02:00 fire" || echo "tripwire fires on plist drift"
git checkout config/com.nightshift.installed.plist config/nightshift.toml 2>/dev/null || true
```

Expected: `window ok: …`, then `tripwire fires on window mismatch`, then `tripwire fires on plist drift`. The `git checkout` at the end reverts **both** edits — re-apply Steps 2 and 4 if it reverted more than the mutations, and re-run.

- [ ] **Step 8: Commit at the new location**

```bash
cd ~/nightshift
bin/test-harness.sh | tail -1
git add config/nightshift.toml config/com.nightshift.installed.plist bin/test-harness.sh
git rm --cached config/com.nightshift.plist 2>/dev/null || true
git commit -m "Move to ~/nightshift: direct launchd invocation, 23:00-07:00 window

The osascript -> Terminal.app indirection existed for exactly one reason: macOS
TCC hangs any headless launchd agent that touches an external volume, across
every identity it forks. Home root is not TCC-protected, so the cause is gone
and the workaround goes with it. The fired-date log stays -- it is the only
record that separates 'fired and died' from 'never fired'.

Window widens from 02:00+180m to 23:00+480m. Those are two files stating one
window, and a mismatch does not fail loudly: the watchdog just TERMs the night
early and it reads as a clean timeout. test-harness section 11 asserts the fire
hour plus the ceiling lands on 07:00. Both files are tracked, so unlike the
ci.yml tripwire this check can never skip for a host reason.

Deletes config/com.nightshift.plist: it documented the internal-disk pattern
the installed plist now uses, so it is a second file saying the same thing."
```

---

### Task 5: Prove the new location before anything is installed or deleted

The harness must be green **at the new location, against the new paths**, before the plist is loaded and long before Task 8 deletes anything. The failure mode this task is built against is a verification that passes because it silently checked nothing.

**Files:** none modified. This task only runs things and asserts.

**Interfaces:** none.

- [ ] **Step 1: Run the harness and assert section 5 did not skip**

`bin/test-harness.sh:63` prints `SKIP: no work/repo clone present` and continues when the target clone is missing. At a brand-new location that branch is exactly the one likely to be taken, and it ends in `ALL HARNESS TESTS PASSED` — a green that checked nothing.

```bash
cd ~/nightshift
bin/test-harness.sh 2>&1 | tee /tmp/ns-harness-new.txt | tail -1
grep -q 'ci.yml matches the recorded hash' /tmp/ns-harness-new.txt \
  && echo "section 5 really ran" || echo "SECTION 5 SKIPPED — the clone is not where the harness looks"
grep -c 'SKIP' /tmp/ns-harness-new.txt
```

Expected: `ALL HARNESS TESTS PASSED`, then `section 5 really ran`, then `0`. Grep for the **pass** line, never for the absence of `FAIL`.

- [ ] **Step 2: If the ci.yml tripwire fires, re-sync — do not bump the hash**

The fresh clone may carry a newer `ci.yml` than the hash Plan 1 recorded. If Step 1 reports the hash mismatch:

```bash
cd ~/nightshift/work/repo
git log --oneline -5 -- .github/workflows/ci.yml
git diff <last-known-good-sha> HEAD -- .github/workflows/ci.yml
```

Read the diff, decide whether any mirrored command in `config/ci-mirror.toml` changed, update the commands if so, and only then update `sha256`. Bumping the hash without reading the diff converts a working tripwire into decoration — the documented procedure at `config/ci-mirror.toml`'s `[source]` says exactly this.

- [ ] **Step 3: Assert the gate would use the NEW jac binary**

The principal risk of this plan, stated positively:

```bash
cd ~/nightshift
bash -c 'NS_ROOT=$HOME/nightshift; cd $NS_ROOT; . lib/common.sh; ns_load_config
  echo "harness jac: $NS_PATHS_JAC"
  echo "repo jac:    $NS_PATHS_JAC_REPO"
  "$NS_PATHS_JAC_REPO" --version | head -1
  case "$NS_PATHS_JAC_REPO" in "$HOME"/nightshift/*) echo "repo binary is under the new root" ;;
                               *) echo "FAIL: repo binary is NOT under the new root" ;; esac
  case "$NS_PATHS_JAC" in /Volumes/*) echo "FAIL: harness binary is on the volume" ;;
                          *) echo "harness binary is off the volume" ;; esac'
```

Expected: the two paths printed, a real version line from the repo binary, and both `case` arms reporting the safe branch. The old volume may still be mounted — that is precisely why this is checked by path rather than by "it worked."

- [ ] **Step 4: Run the CI mirror against clean main**

```bash
cd ~/nightshift && time bin/nightshift.sh mirror main 2>&1 | tail -25
```

Expected: exit 0 with no `failed job:` line, and the tail showing real command output — a jac fmt pass, `gen-jir-registry --verify`, and collected test counts in the thousands. If any suite reports `collected: 0`, stop: that is followups §8 item 3, and it is what a mirror looks like when the runner never started.

- [ ] **Step 5: Full dry run against the real repo at the new location**

`dry-run` sets `NS_DRY_RUN=1`, which routes every push in the nightly path through `ns_git_push`'s logging seam (`lib/common.sh:160`). Nothing reaches GitHub. The kill switch must be lifted for the duration, because preflight dies `EX_DISABLED` before anything else runs:

```bash
mv ~/.nightshift/DISABLE ~/.nightshift/DISABLE.parked
cd ~/nightshift && time bin/nightshift.sh dry-run; echo "exit=$?"
mv ~/.nightshift/DISABLE.parked ~/.nightshift/DISABLE
ls ~/.nightshift/
```

Expected: exit 0, and `DISABLE` back in place — moved, not deleted, so a mistake here cannot silently arm the schedule. If the dry run dies, the reason is in `logs/<date>/FATAL_REASON` and the stage in `ERROR_STAGE` (Plan 1's stopgap, `lib/common.sh:64`).

- [ ] **Step 6: Assert the dry run actually did work, rather than skipping to green**

```bash
cd ~/nightshift/logs/$(date +%F)
grep -c . warnings.txt 2>/dev/null || echo 0
jac run ~/nightshift/scripts/parse_result.jac len < findings.json
cat tests-*.txt 2>/dev/null
grep 'DRY' run.log | head -5
```

Expected: a **nonzero** findings count; at least one `tests-<branch>.txt` naming the suites that ran with no-new-failures-vs-baseline; and `[DRY] git -C … push …` lines proving the push seam was exercised and not reached. A dry run that produced zero findings and zero gated branches is a dry run that proved nothing about the new location.

- [ ] **Step 7: Reset the night's artifacts so the first real night starts clean**

```bash
rm -rf ~/nightshift/logs/$(date +%F)
: > ~/nightshift/state/ledger.jsonl.cache
ls ~/nightshift/logs/
```

Expected: an empty `logs/`. The dry run may have appended ledger rows locally; the authoritative ledger lives on `nightshift/drafts`, which Task 8 deletes anyway.

---

### Task 6: Harden missed-night detection

Diagnosed on 2026-07-30 against the real logs, and the spec's section 17 is **wrong in two directions** — record the corrected facts, because they change what needs building.

| Date | Fired? | Run dir? | Reality |
|---|---|---|---|
| 07-25 | yes | no | fired, died before `mkdir -p $LOG_DIR` |
| 07-26 | yes | no | same |
| 07-27 | yes | yes | ran |
| **07-28** | **no** | no | **launchd never fired at all — completely invisible to the current check** |
| 07-29 | yes | no | fired, died before `mkdir -p $LOG_DIR` |
| **07-30** | yes | **yes** | **a full night: S0-S5 all `.done`, 02:00 → 02:38** |

So the existing detector at `lib/preflight.sh:62-67` **works**: `logs/2026-07-27/warnings.txt` and `logs/2026-07-30/warnings.txt` both already carry the correct `missed night: …` lines. Three real defects remain:

1. **07-28 is undetectable.** No fire line and no run dir is an absence of evidence, and the loop only iterates over fire lines. "The schedule stopped firing" is the exact failure the spec calls worthless-if-silent, and it is the one case unguarded.
2. **Nobody ever read the warnings.** They land in `warnings.txt` → the digest → SMTP, which has never once sent successfully. Six days of missed nights went unnoticed for that reason, not for a detection reason. SMTP is Plan 4's; Task 9 Step 5 makes the cutover check the file directly instead of trusting the mail.
3. **`tail -7` is an arbitrary window.** Eight consecutive misses and the evidence rolls off the end.

Root cause of the fired-but-no-run nights: `~/Library/Logs/nightshift-launchd.out` holds 18 `tab 1 of window id …` lines against 11 fire dates, so `osascript` succeeded in opening a Terminal window on those nights and the script died between shell startup and `ns_run`'s first `mkdir` — i.e. inside the `. lib/*.sh` sourcing or `ns_load_config` (`bin/nightshift.sh:116`), which run **before** any log directory exists and therefore leave no trace. Task 4's direct-invocation plist removes that whole layer: launchd's recorded exit status now measures `nightshift.sh` rather than `osascript`, and `StandardErrorPath` captures the failure. The 23:00 fire also lands while the machine is far more likely to be awake and on AC (`pmset -g custom` shows `sleep 0` on AC, `sleep 1` on battery), which is the plausible cause of 07-28's non-fire.

**Files:**
- Modify: `~/nightshift/lib/preflight.sh:56-67`

**Interfaces:**
- Produces: two warning classes instead of one — `missed night: <date> (launchd fired, no run dir)` and `missed night: <date> (launchd NEVER FIRED — check the LaunchAgent)`.

- [ ] **Step 1: Replace the missed-night block**

Replace `lib/preflight.sh:56-67` with:

```bash
    # Missed-night detection, two classes, because they have different causes and different fixes.
    #
    # FIRED-BUT-NO-RUN: the plist ran and the harness died before mkdir -p $LOG_DIR, so it left no
    # trace of its own. Diagnosed 2026-07-30 for 07-25/26/29 -- under the OLD osascript plist,
    # launchd's exit code measured osascript, not the harness. The direct-invocation plist makes
    # StandardErrorPath the evidence for this class; the warning stays as the cheap index.
    #
    # NEVER-FIRED: no fire line AND no run dir. 07-28 was exactly this and was INVISIBLE, because
    # the old loop only iterated over fire lines -- an absence of evidence cannot appear in a list
    # of events. This is the class the spec calls worthless-if-silent, so it is enumerated over
    # CALENDAR DATES, not over the log.
    #
    # ponytail: 7 days of `date -v-Nd`, not a scheduler-health subsystem. The ceiling is that eight
    #           consecutive misses roll off the window. Upgrade path: raise the 7, or have S0 stamp
    #           a "last successful night" date into state.json and diff against today.
    local d back fired_log="$HOME/Library/Logs/nightshift-fired.log"
    for back in 1 2 3 4 5 6 7; do
        d="$(date -v-${back}d +%F)"
        [ -d "$NS_ROOT/logs/$d" ] && continue
        # `case`, not `[ … ] && …`: a false && list returns nonzero, and this loop body is the last
        # thing that runs before the log prune under an errexit-active caller.
        if [ -f "$fired_log" ] && grep -qxF "$d" "$fired_log"; then
            ns_warn "missed night: $d (launchd fired, no run dir — see ~/Library/Logs/nightshift-launchd.err)"
        else
            ns_warn "missed night: $d (launchd NEVER FIRED — check: launchctl list | grep nightshift)"
        fi
    done
```

Note `grep -qxF`: fixed-string, whole-line. A `grep -q "$d"` would match `2026-07-02` inside `2026-07-025` and, more importantly, treats the date as a regex.

- [ ] **Step 2: Prove both classes fire, and that neither fires on a good night**

Three cases, and the third is the one that matters — a check that warns on everything is as useless as one that warns on nothing:

```bash
cd ~/nightshift
T="$(mktemp -d)"; mkdir -p "$T/logs"
y1="$(date -v-1d +%F)"; y2="$(date -v-2d +%F)"
mkdir -p "$T/logs/$y1"                              # ran: must produce NO warning
printf '%s\n' "$y2" > "$T/fired.log"                # fired, no run dir: FIRED-BUT-NO-RUN
# every other day in the window: NEVER-FIRED
bash -c '
  NS_ROOT="'"$T"'"; LOG_DIR="'"$T"'/logs/probe"; mkdir -p "$LOG_DIR"
  ns_log() { :; }; ns_warn() { echo "$1" >> "$LOG_DIR/warnings.txt"; }
  fired_log="'"$T"'/fired.log"
  for back in 1 2 3 4 5 6 7; do
    d="$(date -v-${back}d +%F)"
    [ -d "$NS_ROOT/logs/$d" ] && continue
    if [ -f "$fired_log" ] && grep -qxF "$d" "$fired_log"; then
      ns_warn "missed night: $d (launchd fired, no run dir)"
    else
      ns_warn "missed night: $d (launchd NEVER FIRED)"
    fi
  done'
echo "--- warnings ---"; cat "$T/logs/probe/warnings.txt"
grep -c 'NEVER FIRED' "$T/logs/probe/warnings.txt"
grep -c 'fired, no run dir' "$T/logs/probe/warnings.txt"
grep -c "$y1" "$T/logs/probe/warnings.txt" || echo "0 — the night that ran produced no warning"
```

Expected: `5` never-fired, `1` fired-but-no-run, and `0` mentions of the date that has a run dir. If the third number is not 0 the check would warn every night forever and be ignored within a week, which is the same outcome as not having it.

- [ ] **Step 3: Reset the fired log at the destination**

The new tree has no `logs/` (Task 2 decided not to move 394M of history). Left alone, Step 1's loop would warn for the last seven days on the very first night — six spurious warnings that teach the operator to ignore the channel.

```bash
cp ~/Library/Logs/nightshift-fired.log ~/Library/Logs/nightshift-fired.log.pre-migration
: > ~/Library/Logs/nightshift-fired.log
wc -l < ~/Library/Logs/nightshift-fired.log
wc -l < ~/Library/Logs/nightshift-fired.log.pre-migration
```

Expected: `0` and `11`. The journal belongs to the plist that writes it, and Task 4 installed a new plist; the old journal is preserved beside it as the record of the 07-25/26/28/29 diagnosis. This still leaves seven days of `NEVER FIRED` warnings until the new tree accumulates run dirs — expected and correct, since the new schedule genuinely has not fired yet.

- [ ] **Step 4: Harness green, commit**

```bash
cd ~/nightshift && bash -n lib/preflight.sh && bin/test-harness.sh | tail -1
git add lib/preflight.sh
git commit -m "Detect nights that never fired, not just nights that fired and died

The old check iterated over fire-log lines, so it could only ever see a night
that FIRED. 2026-07-28 fired zero times and was invisible; 07-25, 07-26 and
07-29 fired and died before mkdir -p \$LOG_DIR, and were correctly reported.
(The spec's 07-28/29/30 list is wrong twice: 07-30 ran a full S0-S5 night, and
07-25/26 were missed too.)

Now enumerates the last seven CALENDAR dates and classifies each as ran /
fired-but-no-run / never-fired, because an absence of evidence cannot appear in
a list of events. grep -qxF, not grep -q: the date is data, not a regex.

The direct-invocation plist makes the first class self-diagnosing for the first
time -- launchd's exit status now measures nightshift.sh rather than osascript,
and StandardErrorPath captures a failure that happens before any log dir exists."
```

---

### Task 7: ENUMERATE what the reset would destroy — read-only, deletes nothing

**This task deletes nothing.** It exists so the operator sees every branch, its age, its subject, and its upstream PR status *before* being asked to confirm. Task 8 then deletes only from the file this task wrote. Splitting them is the point: a listing and a deletion in one script is a script that deletes whatever it happened to list, and nobody reads the listing.

**Files:**
- Create (untracked, scratch): `~/nightshift/reset-branches.txt`, `~/nightshift/reset-local-only.txt`

**Interfaces:**
- Produces: `~/nightshift/reset-branches.txt` — one branch name per line, exactly the set Task 8 deletes. Nothing else may be deleted.

- [ ] **Step 1: Fetch a current view of the fork**

```bash
cd ~/nightshift/work/repo && git fetch origin --prune && git fetch upstream --prune
```

- [ ] **Step 2: Enumerate every remote branch with age and subject**

```bash
cd ~/nightshift/work/repo
git for-each-ref --sort=committerdate \
  --format='%(committerdate:short)  %(committerdate:relative)|%(refname:short)|%(contents:subject)' \
  refs/remotes/origin | sed 's|refs/remotes/||'
```

Expected, as measured 2026-07-30: 30 refs. `nightshift/*` (11, including `nightshift/drafts`), `prune/*` (8, 2026-07-06/07), `split/*` (2, 2026-06-28), `chore/dead-code-removal` (1, 2026-06-28), plus `main` and `pre-commit-ci-update-config`.

- [ ] **Step 3: Write the delete set, and print the keep set beside it**

```bash
cd ~/nightshift/work/repo
git for-each-ref --format='%(refname:short)' refs/remotes/origin \
  | sed 's|^origin/||' | grep -vx 'origin' \
  | grep -E '^(nightshift/|prune/|split/|chore/dead-code-removal$)' \
  | sort > ~/nightshift/reset-branches.txt
echo "=== WILL DELETE ($(wc -l < ~/nightshift/reset-branches.txt)) ==="; cat ~/nightshift/reset-branches.txt
echo "=== WILL KEEP ==="
git for-each-ref --format='%(refname:short)' refs/remotes/origin \
  | sed 's|^origin/||' | grep -vx 'origin' \
  | grep -vE '^(nightshift/|prune/|split/|chore/dead-code-removal$)'
```

Expected: 27 in the delete set. The keep set is exactly `main` and `pre-commit-ci-update-config` — the latter is pre-commit.ci's own autoupdate branch, nothing to do with nightshift, and deleting it would be collateral damage.

- [ ] **Step 4: Annotate each doomed branch with its upstream PR state**

This is the step that changes what a reasonable person confirms. Several of these branches are the heads of **merged** upstream PRs:

```bash
gh pr list --repo jaseci-labs/jac --author ayushmk7 --state all --limit 50 \
  --json number,state,headRefName,title \
  --jq '.[] | "\(.headRefName)\t#\(.number)\t\(.state)\t\(.title[0:60])"' | sort > /tmp/ns-prs.txt
while IFS= read -r b; do
  hit="$(grep -F "$b	" /tmp/ns-prs.txt || true)"
  printf '%s\t%s\n' "$b" "${hit:-no PR}"
done < ~/nightshift/reset-branches.txt
```

Expected: `prune/*` maps to PRs #7231-#7236 (MERGED) and #7218-#7220 (CLOSED); `split/dead-code-{1,2}` to #7032/#7033 (MERGED); `chore/dead-code-removal` to #7031 (CLOSED); every `nightshift/*` shows `no PR`. **Confirm zero OPEN PRs** — measured 2026-07-30 there are none, and the reset must not orphan a live PR.

What deleting a merged PR's head branch does: the PR, its diff, and its commits stay on GitHub — upstream retains `refs/pull/N/head` permanently — but the branch on the fork is gone and the PR page will show "deleted". This is normal and is what the "delete branch after merge" button does. Say it out loud in the confirmation so it is not discovered afterwards.

- [ ] **Step 5: Flag anything that exists ONLY locally in the old tree**

The old `work/repo` is being abandoned, so a branch that never reached the fork disappears with it and no remote deletion would ever have mentioned it:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo
for b in $(git for-each-ref --format='%(refname:short)' refs/heads); do
  git show-ref --verify --quiet "refs/remotes/origin/$b" \
    || echo "LOCAL-ONLY: $b  $(git log -1 --format='%ad %s' --date=short "$b")"
done | tee ~/nightshift/reset-local-only.txt
```

Expected, as measured 2026-07-30: exactly one — `nightshift/2026-07-23/sourcemap-resolve-duplicate`. Decide deliberately whether that work is worth pushing before the old tree is abandoned. It is not covered by any remote deletion and would otherwise vanish without ever appearing in a confirmation prompt.

- [ ] **Step 6: STOP. Present the three lists and request the second confirmation.**

Present to the operator, verbatim:
- the 27 branches in `~/nightshift/reset-branches.txt`, each with age, subject and PR state;
- the 2 branches being kept;
- the local-only branch from `~/nightshift/reset-local-only.txt`;
- and this sentence: **"Remote branch deletion on GitHub is irreversible. Merged PRs keep their diffs; the branches do not come back."**

**Do not proceed to Task 8 without an explicit second confirmation from the human.** Config-level agreement to "reset to base" (spec §16) is not that confirmation; the confirmation is against *this list*.

---

### Task 8: THE RESET — irreversible

**Every step in this task except Step 1 and Step 7 is irreversible.** It runs only after Task 7's confirmation, and it deletes only what `~/nightshift/reset-branches.txt` names.

**Files:**
- Reads: `~/nightshift/reset-branches.txt` (written by Task 7)
- Modifies: nothing in the repo. All effects are on GitHub and in `~/nightshift/state/`.

**Interfaces:** none.

- [ ] **Step 1: Re-verify the file has not drifted since the confirmation** *(reversible)*

```bash
cd ~/nightshift/work/repo && git fetch origin --prune
comm -13 <(git for-each-ref --format='%(refname:short)' refs/remotes/origin | sed 's|^origin/||' | sort) \
         <(sort ~/nightshift/reset-branches.txt)
```

Expected: **empty output**. Any line here is a branch in the delete list that no longer exists on the fork — meaning the fork changed after the operator confirmed. Stop and re-run Task 7 if so. Deleting a list nobody re-checked is how a confirmation becomes a rubber stamp.

- [ ] **Step 2: Delete the remote branches, one per line, echoing each** *(IRREVERSIBLE)*

```bash
cd ~/nightshift/work/repo
while IFS= read -r b; do
  [ -n "$b" ] || continue
  echo "deleting origin/$b"
  git push origin --delete "$b" || echo "  FAILED: $b"
done < ~/nightshift/reset-branches.txt
```

Expected: 27 `deleting origin/…` lines, each followed by git's `- [deleted]` confirmation, and no `FAILED:` lines. Driven from the file rather than from a fresh `for-each-ref` on purpose: a re-derived pattern is a pattern that can match something the operator never saw.

- [ ] **Step 3: Confirm the fork is down to its keep set** *(verification)*

```bash
cd ~/nightshift/work/repo && git fetch origin --prune
git for-each-ref --format='%(refname:short)' refs/remotes/origin | sed 's|^origin/||' | grep -vx 'origin'
```

Expected exactly two lines: `main` and `pre-commit-ci-update-config`. Assert the *presence* of the expected two, not merely the absence of the deleted 27.

- [ ] **Step 4: Reset the fork's `main` to fresh upstream** *(IRREVERSIBLE for any local-only main commits)*

```bash
cd ~/nightshift/work/repo
gh repo sync ayushmk7/jaseci --source jaseci-labs/jac --branch main
git fetch origin --prune && git checkout -B main origin/main
git log --oneline -1 && git status --short
```

Expected: sync reports success, `main` at upstream's head, and a clean tree. `gh repo sync` is the same call `lib/sync.sh:5` makes every night, so this also proves S1 will work at the new location before a night depends on it.

- [ ] **Step 5: Clear the ledger and state** *(IRREVERSIBLE)*

The authoritative ledger lived on the `nightshift/drafts` branch, which Step 2 already deleted. What remains is the local cache and the runtime state:

```bash
cd ~/nightshift
: > state/ledger.jsonl.cache
printf '{\n  "last_jac_version": "0.16.1",\n  "verify_estimate_min": 1\n}\n' > state/state.json
wc -c < state/ledger.jsonl.cache && cat state/state.json
ls state/test-baseline/
```

Expected: `0` bytes of ledger, the two-key state, and **all three baselines still present**. That last `ls` is the point of the step: the reset must not take the baselines with it, and they sit in the same directory it is clearing.

`lib/sync.sh:32-47`'s `drafts_bootstrap` recreates the orphan `nightshift/drafts` branch with an empty `ledger.jsonl` on the first night, because `ls-remote --exit-code origin refs/heads/nightshift/drafts` now fails. No manual recreation is needed — verify that path runs in Task 9 Step 3 rather than assuming it.

- [ ] **Step 6: Confirm `dataset/*.jsonl` is untouched** *(verification — this is the thing being preserved)*

```bash
cd ~/nightshift
git status --short dataset/ && wc -l dataset/*.jsonl
```

Expected: no modifications, and the row counts unchanged from the old tree. The user explicitly chose to keep the dataset as the record of the old regime; the new schema is written alongside it with a `task` field added (spec §16), never over it.

- [ ] **Step 7: Disable Actions on the fork** *(reversible — flip `enabled` back to `true`)*

Every fork sync push starts a `ci.yml` run whose Blacksmith jobs queue forever, and the fork also runs a scheduled `Nightly` workflow. Measured 2026-07-30: one run `queued` for 11h43m, plus repeated `Nightly` failures. The harness never depends on fork CI — Plan 1's whole CI-mirror exists because fork CI is unusable as a gate.

```bash
gh api -X PUT repos/ayushmk7/jaseci/actions/permissions -F enabled=false
gh api repos/ayushmk7/jaseci/actions/permissions --jq .enabled
gh run list --repo ayushmk7/jaseci --limit 5
```

Expected: `false` from the read-back, and no new runs starting on subsequent syncs. Read back rather than trusting the `PUT`'s exit code.

---

### Task 9: Cutover

Install the schedule, prove it fires without letting it do any work, then arm it. `rm ~/.nightshift/DISABLE` is the last step of this plan and nothing follows it.

**Files:**
- Installs: `~/Library/LaunchAgents/com.nightshift.plist`
- Removes: `~/.nightshift/DISABLE` (final step)

**Interfaces:** none.

- [ ] **Step 1: Decide the old harness's overlap mode — and do less than was asked**

The request was to run old and new briefly in parallel with the old harness in dry-run-only mode, so the two cannot collide on `nightshift/<date>/<slug>` in the fork. Two structural facts make a *scheduled* parallel run impossible rather than merely unwise:

1. **Both plists use `Label = com.nightshift`.** launchd permits one job per label; a second scheduled harness needs a second label and a second Program path, i.e. a fork of the plist that then has to be maintained.
2. **Both harnesses take the same lock, `/tmp/nightshift.lock`** (`lib/common.sh:12`, hardcoded in both trees). The new night holds it from 23:00 to as late as 07:00, which swallows the old 02:00 slot entirely — the legacy run would die `EX_LOCK` every single night and prove nothing.

`ponytail:` so the overlap is **manual, not scheduled**. The old tree stays on the volume, fully intact and runnable by hand:

```bash
/Volumes/ExtremePro/JaseciLabs/NightShift/bin/nightshift.sh dry-run
```

`dry-run` routes every push through `ns_git_push`'s logging seam, so it cannot touch a fork branch even by accident — which is the actual requirement ("no push, no PR"), independent of scheduling. Ceiling: no unattended side-by-side comparison across several nights. Upgrade path, if that is ever genuinely wanted: give the legacy plist `Label = com.nightshift.legacy`, point `LOCK_DIR` in the old tree's `lib/common.sh` at `/tmp/nightshift-legacy.lock`, and schedule it at 20:00 so it finishes before 23:00. Do not build that now for a "briefly."

Do **not** unload the old LaunchAgent as a separate operation — Step 2 replaces it under the same label, which is the same thing with fewer moving parts.

- [ ] **Step 2: Install the new LaunchAgent**

```bash
cp ~/Library/LaunchAgents/com.nightshift.plist ~/Library/LaunchAgents/com.nightshift.plist.pre-migration
cp ~/nightshift/config/com.nightshift.installed.plist ~/Library/LaunchAgents/com.nightshift.plist
plutil -lint ~/Library/LaunchAgents/com.nightshift.plist
launchctl bootout gui/$(id -u)/com.nightshift 2>/dev/null || launchctl unload ~/Library/LaunchAgents/com.nightshift.plist 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.nightshift.plist \
  || launchctl load ~/Library/LaunchAgents/com.nightshift.plist
launchctl list | grep nightshift
```

Expected: `OK` from `plutil`, and a `com.nightshift` line from `launchctl list`. The `.pre-migration` copy is kept so a rollback is a single `cp` back plus a re-bootstrap.

- [ ] **Step 3: Assert the installed plist is byte-identical to the tracked one**

The tracked file is what section 11's tripwire checks; the installed file is what launchd runs. If they diverge, the tripwire is validating a document nothing executes — a check that passes because it silently checked the wrong thing.

```bash
cmp ~/Library/LaunchAgents/com.nightshift.plist ~/nightshift/config/com.nightshift.installed.plist \
  && echo "installed plist matches the tracked one" || echo "DIVERGED"
grep -c 'osascript' ~/Library/LaunchAgents/com.nightshift.plist || echo "0 — osascript workaround is gone"
grep -o '/Users/[a-z]*/nightshift/bin/nightshift.sh\|\$HOME/nightshift/bin/nightshift.sh' ~/Library/LaunchAgents/com.nightshift.plist
```

Expected: `installed plist matches the tracked one`, zero `osascript` hits, and the new script path. A nonzero `osascript` count means the old plist is still installed and the whole Task 4 change is inert.

- [ ] **Step 4: Let it fire once with the kill switch STILL in place**

This is the safest possible proof that the schedule works: `~/.nightshift/DISABLE` is checked at `lib/preflight.sh:13`, which runs inside `preflight_main` — *after* `ns_run` has already created `$LOG_DIR` (`bin/nightshift.sh:52`). So a fire under DISABLE creates a dated run dir and a `DISABLED` marker, then exits `EX_DISABLED=41` having done no git, no network, and no agent work at all.

Wait for the 23:00 fire (or trigger one deliberately with `launchctl kickstart -k gui/$(id -u)/com.nightshift`, which is equivalent for this purpose and does not need a late night), then:

```bash
ls -la ~/nightshift/logs/
cat ~/Library/Logs/nightshift-fired.log
ls ~/nightshift/logs/$(date +%F)/DISABLED && echo "fired, created a run dir, and stopped at the kill switch"
tail -5 ~/Library/Logs/nightshift-launchd.err
```

Expected: a dated run dir exists; the fired log has exactly one line, today's date; the `DISABLED` marker is present; and `nightshift-launchd.err` is empty or shows only the expected exit. **All four together** are the proof — the run dir alone would also appear if you had run the script by hand, and the fired-log line alone would also appear under the old osascript plist that then died.

If no run dir appears: `launchctl print gui/$(id -u)/com.nightshift` shows the last exit status, and — unlike every night before this migration — that status now measures `nightshift.sh` rather than `osascript`.

- [ ] **Step 5: Read the warnings file directly, not the email**

SMTP has never once sent successfully, and that — not a detection failure — is why six missed nights went unnoticed. Until Plan 4 fixes it, the cutover check reads the file:

```bash
cat ~/nightshift/logs/$(date +%F)/warnings.txt 2>/dev/null
```

Expected: seven `missed night: … (launchd NEVER FIRED …)` lines, one per day of the empty window at the new location. That is *correct* and expected on the first fire — and it is also the positive proof that Task 6's new never-fired class is live, since the fired log has exactly one entry and the old code could not have produced a single one of these lines.

- [ ] **Step 6: Repoint the harness clone's origin**

`~/nightshift`'s `origin` still points at the volume from Task 3 Step 2, which makes the volume a dependency of every future harness commit:

```bash
cd ~/nightshift
git remote -v
git remote set-url origin <the real harness remote, or `git remote remove origin` if there is none>
git remote -v
```

Decide deliberately: if the harness repo has no remote of its own, remove `origin` rather than leaving it pointing at a tree that is about to be deleted.

- [ ] **Step 7: Full dry run once more, from the installed schedule's exact environment**

Everything until now proved the pieces. This proves the assembly under launchd's minimal `PATH` rather than an interactive shell's:

```bash
mv ~/.nightshift/DISABLE ~/.nightshift/DISABLE.parked
env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  /bin/bash ~/nightshift/bin/nightshift.sh dry-run; echo "exit=$?"
mv ~/.nightshift/DISABLE.parked ~/.nightshift/DISABLE
```

Expected: `exit=0`. This is where a missing `gtimeout`, a `gh` that cannot reach the keychain, or a `claude` that fails its pong probe surfaces — all four are `ns_die` paths in `preflight_main` and all four are `PATH`- or session-sensitive. `bin/nightshift.sh:10` prepends the Homebrew paths itself, but `env -i` is the honest test of the assumption.

Then assert it did work rather than skipped to green, exactly as in Task 5 Step 6:

```bash
cd ~/nightshift/logs/$(date +%F)
jac run ~/nightshift/scripts/parse_result.jac len < findings.json
grep 'DRY' run.log | head -3
cat warnings.txt
```

Expected: nonzero findings, `[DRY] git … push` lines, and no new warning classes beyond the missed-night ones from Step 5.

- [ ] **Step 8: Commit the new location's state, then ARM**

```bash
cd ~/nightshift && bin/test-harness.sh | tail -1
git log --oneline -3
```

Expected: `ALL HARNESS TESTS PASSED` and the Task 2/4/6 commits.

```bash
rm ~/.nightshift/DISABLE
ls ~/.nightshift/ ; launchctl list | grep nightshift
```

Expected: the directory is empty and the agent is loaded. **This is the last step of the plan.** The next 23:00 fire is a real night: it will sync the fork from `jaseci-labs/jac`, bootstrap a fresh `nightshift/drafts` with an empty ledger, run the sharded audit, gate against the migrated baselines, and push to a fork that has exactly two branches on it.

- [ ] **Step 9: Do NOT delete the old tree**

Leave `/Volumes/ExtremePro/JaseciLabs/NightShift` exactly as it is. It is the rollback (`cp ~/Library/LaunchAgents/com.nightshift.plist.pre-migration` back and re-bootstrap), it holds the 394M of historical `logs/` that this plan deliberately did not move, and it is the only copy of the local-only branch Task 7 Step 5 found. Deleting it is a decision for the operator after several consecutive green nights at the new location, not a step in this plan.

---

## What this plan deliberately did NOT do, and when it should be done

- **Did not move `logs/`.** 394M, gitignored, and read by exactly two things: `dataset-backfill` (already run — `dataset/*.jsonl` is committed, which is the durable form) and preflight's missed-night check (Task 6 resets its input instead). *When:* never as a bulk move. If a specific old night is needed for forensics, copy that one directory.

- **Did not build a plist generator, template, or `$HOME` interpolation pass.** There is one plist. It is configuration, not code. *When:* if a second machine ever runs the harness — and even then, `cp` plus two string edits beats a generator for two files.

- **Did not add a second scheduled LaunchAgent for the old harness.** Blocked by two structural facts, not by taste: both trees hardcode `Label = com.nightshift` and `LOCK_DIR = /tmp/nightshift.lock`, and the 23:00→07:00 window swallows the legacy 02:00 slot, so the legacy night would die `EX_LOCK` nightly. The overlap is a manual `dry-run` from the old tree, which satisfies the actual requirement (no push, no PR). *When:* only if unattended multi-night side-by-side comparison is genuinely wanted — then re-label, re-lock, and schedule at 20:00.

- **Did not add a harness test that reads `~/Library/LaunchAgents/`.** It would print `SKIP` on any host without the agent installed and still reach `ALL HARNESS TESTS PASSED` — the exact defect class this plan is written against, reintroduced as a guard. Section 11 checks the two **tracked** files instead, and Task 9 Step 3 `cmp`s the installed copy against the tracked one as a one-time cutover assertion. *When:* never; the `cmp` is the right shape.

- **Did not touch `pmset repeat wake`, PowerNap, or any sleep configuration** to make the fire more reliable. The 23:00 window is itself the mitigation — the machine is far more likely awake and on AC then than at 02:00 (`sleep 0` on AC vs `sleep 1` on battery), which is the plausible cause of 07-28's non-fire. *When:* if a `NEVER FIRED` warning appears for a night the machine was demonstrably powered on.

- **Did not carry `work/drafts` across.** It is a git worktree pinned to `nightshift/drafts`, a branch Task 8 deletes; `drafts_bootstrap` recreates it empty. Task 9 Step 7's dry run is what verifies that path rather than assuming it.

- **Did not copy the ledger.** 113 rows copied and then cleared by Task 8 Step 5 is motion without progress. `dataset/*.jsonl` is the preserved record, per the user's explicit choice.

- **Did not resolve the tier-1 scope question.** Task 1 is a gate, not an answer — it belongs to the human. If the answer arrives as "retire", Task 1 Step 3 says exactly where the deletion task goes: before Task 2, on `main`, so the new location never receives the code.

- **Did not fix SMTP**, which is why the missed-night warnings this plan hardens were never actually read. That is Plan 4's, and Task 9 Step 5 reads `warnings.txt` from disk in the meantime. *When:* Plan 4.

- **Did not delete the old tree.** Task 9 Step 9. It is the rollback and the only copy of `logs/` and of one local-only branch. *When:* after several consecutive green nights at `~/nightshift`, at the operator's discretion.
