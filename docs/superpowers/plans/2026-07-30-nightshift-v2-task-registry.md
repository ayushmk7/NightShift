# Nightshift v2 Plan 2: The four-task registry

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the single ponytail-audit pass into four task types — one per night, cycling `dead-code → abstraction → maintenance → coverage` — each with its own audit prompt, its own scoring shape, its own write permissions, and its own model routing, with unfinished work carried to the next night ahead of that night's own task.

**Architecture:** The cycle order is the product decision (delete first, so every later task audits a smaller surface; simplify what survives; fix drift in what remains; write tests against the settled shape), so it is declared once — the order of the `[tasks.*]` tables in `config/nightshift.toml` — and pinned by a harness test. Everything else hangs off the task name as a key: `prompts/audit-<task>.md` and `prompts/apply-rules-<task>.md` are looked up by name, `[tasks.<task>].scoring` selects which finding schema the parser demands, `[tasks.<task>].fragment` decides the release-note kind, and `[tasks.<task>].protect_unless` — read from the config file by `check_scope.jac`, never from the theme — decides whether that task may write inside a protected glob. The task travels through the night in exactly one place the agent cannot touch: the branch-name slug the harness builds (`nightshift/<date>/<task>-<theme-hint>`). Findings self-describe their scoring shape (a coverage finding carries `gap_severity`/`est_loc_added`, a shrink finding carries `est_loc_saved`), so the mode is never plumbed through three scripts.

**Tech Stack:** bash 3.2 (macOS stock), Jac 0.16.1 for every data/logic transformation, the target repo's dev-built `jac` binary for `jac code map`, `claude` headless for audit and apply.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-30-nightshift-4task-design.md`, sections 3, 5, 11-Phase A, and 13. Carry-forward items: `docs/superpowers/specs/2026-07-30-nightshift-followups.md` sections 3 and 8.
- **No Python files.** bash sequences processes; Jac owns every data and logic transformation. Standing project rule.
- **bash is 3.2.57.** No `wait -n`, no associative arrays, no `${var^^}`. Under `set -u` an **empty** array aborts on `${#arr[@]}` and `"${arr[@]}"` — use a space-joined string and a counter instead.
- **A guard must not return nonzero on its own success path.** `[ "$x" -lt 1 ] && x=1` returns 1 when `$x` is already 1, which aborts every errexit caller. Use `case`/`if`, never a trailing `&&` list. Every new function in this plan obeys this.
- **Two jac binaries, never mixed.** `$NS_PATHS_JAC` runs `scripts/*.jac`. `$NS_PATHS_JAC_REPO` is the target repo's dev binary — the only one that may run `jac code map` against `work/repo`.
- **Jac type-narrowing is mandatory.** A raw nested subscript (`cfg["tasks"][task]["scoring"]`) fails `jac check` with E1001/E1053. Narrow at every level with `nslib`'s `as_dict` / `as_list`.
- **`bin/test-harness.sh` must print `ALL HARNESS TESTS PASSED`** at every commit in this plan. No task may leave it red.
- **`work/`, `state/`, `logs/` are gitignored with nothing tracked.** Never `git add` or `git rm` there; edit those files in place.
- **Phase B (compiler-instrumented line coverage) is out of scope.** `scripts/covmap.jac` ships the static symbol proxy only; Phase B gets its own spec.

### The defect class to design against

**"Did not run" scoring as "passed."** Seven instances were found in Plan 1, every one in the gate, none caught by a passing test. The cause is structural: the gate is assembled from commands that exit 0 for "nothing to do" and 0 for "all good". The countermeasure that worked is a **positive assertion that the work happened** — a count, a session banner, a compared-file tally — not the absence of failure lines. Its sibling is **an assertion that cannot fail**: a grep comparing empty to empty, a test asserting "nonzero" that a `return 1` satisfies, a regression test containing the bug it guards. This plan adds four tripwires (`protect_unless`, the tests-only rule, the test-weakening guard, the model router). **Mutation-test every one of them** — in Plan 1, mutation found weak guards twice where reading did not. Each mutation check in this plan is written so that a degenerate implementation (always-pass, always-fail, ignore-one-dimension) fails at least one assertion.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `config/nightshift.toml` | every knob | Modify: add `[tasks.*]`, `[agent].model`/`model_simple`, drop `[agent].ponytail_mode` |
| `scripts/tasks.jac` | task registry + four-night cycle | **Create** |
| `scripts/covmap.jac` | coverage evidence, Phase A | **Create** |
| `scripts/nslib.jac` | shared pure helpers | Modify: `score_of` infers its weight, `fragment_path` honours an empty kind |
| `scripts/parse_result.jac` | envelope → validated findings/report | Modify: per-task finding schema, `complexity`, task stamp |
| `scripts/selector.jac` | score, pack, carry over | Modify: task-qualified slugs, per-task budget field, carry-over |
| `scripts/check_scope.jac` | S4 diff gate | Modify: `protect_unless` by task argv, test-weakening verb |
| `scripts/render_draft.jac` | draft/PR body + fragment path | Modify: `frag` takes the kind |
| `scripts/shards.jac` | shard registry | Modify: expose `shard_paths` |
| `prompts/audit-<task>.md` | four audit prompts | **Create** (from `prompts/audit.md`) |
| `prompts/apply-rules-<task>.md` | four per-task rule snippets | **Create** |
| `prompts/apply.md` | shared apply prompt | Modify: `{task_apply_rules}` placeholder |
| `lib/tier2.sh` | S3 audit/select/apply | Modify: per-task everything, carry-over, model routing |
| `lib/verify.sh` | S4 gate | Modify: task argv into `check_scope`, test-weakening stage |
| `lib/promote.sh` | S7 ship | Modify: kind-agnostic fragment rename |
| `fixtures/golden-audit.json` | deterministic replay input | Modify: new required finding keys |
| `bin/test-harness.sh` | CI of the harness | Modify: sections 11-14 |

---

### Task 1: The task registry and the four-night cycle

Four tasks are declared in config and read by one small Jac script. The cycle is the declaration order, and the scheduler is an index in `state.json`.

**Files:**
- Create: `scripts/tasks.jac`
- Modify: `config/nightshift.toml` (add `[tasks.*]`, rework `[agent]`)
- Modify: `bin/test-harness.sh:13` (register `tasks` in the jac test sweep)
- Edit (untracked, gitignored): `state/state.json`

**Interfaces:**
- Produces: `jac run scripts/tasks.jac list <config.toml>` — one task name per line, in cycle order.
- Produces: `jac run scripts/tasks.jac env <task> <config.toml>` — shell assignments `NS_TASK_NAME`, `NS_TASK_PONYTAIL`, `NS_TASK_SCORING`, `NS_TASK_FRAGMENT`, for `eval`. Exits nonzero for an unknown task. **`protect_unless` is deliberately not exported** — it never leaves the config file and `check_scope.jac`.
- Produces: `jac run scripts/tasks.jac next <config.toml> <state.json>` — prints tonight's task and advances `cycle_index` in place.
- Consumed by: `lib/tier2.sh` (Task 9), `lib/common.sh`'s `ns_task_of_branch` (Task 6), `bin/test-harness.sh`.

- [ ] **Step 1: Add `[tasks.*]` to `config/nightshift.toml`**

Insert after the `[shards.exclude]` block, before `[budgets]`:

```toml
[tasks]                                      # ONE task per night, cycling in the order these
# tables appear below. scripts/tasks.jac reads that order straight from the file (tomllib
# preserves it) and bin/test-harness.sh section 11 pins the sequence, so there is deliberately
# no `order = N` key: two sources of truth for one ordering is a drift bug waiting to happen.
#
# The order IS the design. Delete first (every later task then audits a smaller surface), then
# simplify what survives, then fix drift in what remains, then write tests against the settled
# shape. Writing coverage first means testing code that is about to be deleted.
#
# There is deliberately no per-task `model` either: the audit is always Opus and the apply
# session routes on the finding's own `complexity` tag ([agent] below). Upgrade path: add
# `model = ...` here the day one task genuinely needs a different one.

[tasks.dead-code]
ponytail = "full"
scoring  = "loc_saved"
fragment = "refactor"

[tasks.abstraction]
ponytail = "full"
scoring  = "loc_saved"
fragment = "refactor"

[tasks.maintenance]
ponytail = "full"
scoring  = "loc_saved"
fragment = "auto"        # the agent returns the kind; fragment_path clamps an invalid one

[tasks.coverage]
ponytail = "lite"        # so it actually writes a test instead of YAGNI-ing it away
scoring  = "risk_weighted"
fragment = ""            # tests-only changes need no release-note fragment
# The ONLY task permitted to write inside a protected glob, and the permission lives HERE --
# in the config file, keyed by task name -- never in a theme. See scripts/check_scope.jac.
# Presence of this key ALSO means "this task may write nothing else": every changed path on a
# coverage branch must match one of these globs.
protect_unless = ["**/tests/**", "**/*.test.jac"]
```

- [ ] **Step 2: Rework `[agent]` in the same file**

Replace the whole `[agent]` table:

```toml
[agent]
# Two models, both pinned. An empty value means "account default", which silently drifts with
# whatever the interactive session default is at 2am -- confirmed live, an unnoticed model change
# between two real runs.
model        = "opus"                        # the audit is always judgement work (spec 13), and
                                              # it is also the escalation target for a failed
                                              # apply. Costs more per night than the old sonnet
                                              # default; that is the deliberate trade.
model_simple = "sonnet"                       # apply sessions for `trivial`/`mechanical` findings,
                                              # plus every mechanical re-prompt
# [agent].ponytail_mode is GONE: every task now sets its own `ponytail` (coverage needs "lite" or
# it YAGNIs its own test away), so a global default would only ever be the value nobody uses.
```

- [ ] **Step 3: Write `scripts/tasks.jac` with its tests**

```jac
"""Task registry and the four-night cycle (design spec 3, 13).

The cycle order is the order the [tasks.*] tables appear in config/nightshift.toml. There is no
`order` key on purpose -- see the config comment.

argv:
  list <config.toml>                 print one task name per line, in cycle order
  env  <task> <config.toml>          print NS_TASK_* shell assignments for one task
  next <config.toml> <state.json>    print TONIGHT's task and advance the cycle index
"""
import sys;
import from shlex { quote }
import from nslib { eprint, load_config_toml, as_dict, state_read, state_write }

"""Only sub-TABLES count as tasks, so a stray scalar under [tasks] cannot become a phantom task
whose prompt files do not exist."""
def task_names(cfg: dict) -> list[str] {
    tasks: dict = as_dict(cfg["tasks"]);
    return [str(k) for (k, v) in tasks.items() if isinstance(v, dict)];
}

def task_table(cfg: dict, task: str) -> dict {
    tasks: dict = as_dict(cfg["tasks"]);
    if task not in tasks {
        raise ValueError("unknown task: " + task);
    }
    return as_dict(tasks[task]);
}

"""Shell assignments for one task. protect_unless is NOT here and must never be: the moment a
write permission is an environment variable it can be inherited, overridden on a command line, or
logged. It is read straight from the config by check_scope.jac, in-process."""
def task_env(cfg: dict, task: str) -> list[str] {
    t: dict = task_table(cfg, task);
    lines: list[str] = ["NS_TASK_NAME=" + quote(task)];
    for key in ["ponytail", "scoring", "fragment"] {
        if key not in t {
            raise ValueError("[tasks." + task + "] is missing `" + key + "`");
        }
        lines.append("NS_TASK_" + key.upper() + "=" + quote(str(t[key])));
    }
    return lines;
}

"""Tonight's task, advancing the cycle as it reads. Advancing ON READ is deliberate: a night that
dies after S3 must not make every following night repeat the same task forever. Unfinished work
already survives on its own through carry-over (selector.jac), so the cycle is a CLOCK, not a work
queue."""
def next_task(cfg: dict, state_path: str) -> str {
    names: list[str] = task_names(cfg);
    if not names {
        raise ValueError("no [tasks.*] tables in the config");
    }
    st: dict = state_read(state_path);
    idx: int = int(st.get("cycle_index", 0)) % len(names);
    st["cycle_index"] = (idx + 1) % len(names);
    state_write(state_path, st);
    return names[idx];
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "list" and len(args) == 3 {
        for n in task_names(load_config_toml(args[2])) {
            print(n);
        }
    } elif cmd == "env" and len(args) == 4 {
        for line in task_env(load_config_toml(args[3]), args[2]) {
            print(line);
        }
    } elif cmd == "next" and len(args) == 4 {
        print(next_task(load_config_toml(args[2]), args[3]));
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run tasks.jac list <config.toml>");
        eprint("       jac run tasks.jac env <task> <config.toml>");
        eprint("       jac run tasks.jac next <config.toml> <state.json>");
    }
}

test "the four tasks are declared in the designed cycle order" {
    # The order IS the design (delete -> simplify -> fix drift -> test the settled shape), so it is
    # asserted literally rather than derived from the file it is meant to pin.
    assert task_names(load_config_toml("config/nightshift.toml"))
        == ["dead-code", "abstraction", "maintenance", "coverage"];
}

test "next advances the cycle and wraps, and a dead night does not stall it" {
    import tempfile;
    import os as _os;
    cfg: dict = load_config_toml("config/nightshift.toml");
    d: str = tempfile.mkdtemp();
    st: str = d + "/state.json";
    seen: list[str] = [];
    for _ in range(6) {
        seen.append(next_task(cfg, st));
    }
    assert seen == ["dead-code", "abstraction", "maintenance", "coverage",
                    "dead-code", "abstraction"];
    assert int(state_read(st)["cycle_index"]) == 2;
}

test "env exposes exactly the per-task knobs, and never protect_unless" {
    cfg: dict = load_config_toml("config/nightshift.toml");
    cov: list[str] = task_env(cfg, "coverage");
    assert "NS_TASK_NAME=coverage" in cov;
    assert "NS_TASK_PONYTAIL=lite" in cov;
    assert "NS_TASK_SCORING=risk_weighted" in cov;
    assert len(cov) == 4;
    for line in cov {
        assert "protect_unless" not in line.lower();
        assert "PROTECT" not in line;
    }
    dead: list[str] = task_env(cfg, "dead-code");
    assert "NS_TASK_SCORING=loc_saved" in dead;
    assert "NS_TASK_FRAGMENT=refactor" in dead;
}

test "an unknown task raises rather than returning empty settings" {
    cfg: dict = load_config_toml("config/nightshift.toml");
    raised: bool = False;
    try {
        task_env(cfg, "not-a-task");
    } except ValueError {
        raised = True;
    }
    assert raised;
}
```

- [ ] **Step 4: Run the tests**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/tasks.jac
```

Expected: PASS, four tests. A failure on the first test means the `[tasks.*]` tables are in the wrong order in the config.

- [ ] **Step 5: Verify the CLI surface by hand**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
jac run scripts/tasks.jac list config/nightshift.toml
jac run scripts/tasks.jac env coverage config/nightshift.toml
T="$(mktemp -d)"; printf '{}' > "$T/s.json"
for i in 1 2 3 4 5; do jac run scripts/tasks.jac next config/nightshift.toml "$T/s.json"; done
cat "$T/s.json"
```

Expected: the four names; four `NS_TASK_*=` lines with no `protect_unless`; then `dead-code abstraction maintenance coverage dead-code` one per line, and a state file containing `"cycle_index": 1`.

- [ ] **Step 6: Seed the cycle index in the live state**

`state/` is gitignored and untracked, so this is a plain file edit with nothing to commit:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
jac run scripts/ledger.jac state-set cycle_index 0 state/state.json
cat state/state.json
```

Expected: the existing keys plus `"cycle_index": 0`, so the first live night runs `dead-code`.

- [ ] **Step 7: Register the script in `bin/test-harness.sh`**

Line 13, extend the sweep list:

```bash
for f in nslib config ledger check_scope parse_result selector render_draft sendmail testgate checkgate dataset shards fragcheck cimirror tasks; do
```

- [ ] **Step 8: Confirm nothing still reads the deleted `[agent].ponytail_mode`**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && grep -rn "NS_AGENT_PONYTAIL_MODE" bin lib scripts
```

Expected: two hits, both in `lib/tier2.sh` (`tier2_audit_shard` and `tier2_apply`). They are replaced in Task 9. To keep this commit green, substitute the task-agnostic default now — Task 9 replaces the whole call:

```bash
sed -i '' 's/"ponytail_mode=\$NS_AGENT_PONYTAIL_MODE"/"ponytail_mode=full"/' lib/tier2.sh
grep -n "ponytail_mode=" lib/tier2.sh
```

Expected: two lines reading `"ponytail_mode=full"`.

- [ ] **Step 9: Run the harness suite and commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add config/nightshift.toml scripts/tasks.jac lib/tier2.sh bin/test-harness.sh
git commit -m "Declare the four task types and the night cycle

One janitorial task per night, cycling dead-code -> abstraction -> maintenance
-> coverage. That order is the design: deleting first shrinks the surface every
later task audits, and writing coverage before deletion means testing code that
is about to be deleted.

The cycle order is the order the [tasks.*] tables appear in the config, with no
`order` key -- two sources of truth for one ordering drift apart. There is no
per-task model either: audit is always Opus and apply routes on each finding's
own complexity tag, so [agent] carries model + model_simple instead.
[agent].ponytail_mode is deleted; every task sets its own.

protect_unless is declared in config but deliberately NOT exported by
tasks.jac env: a write permission that lives in the environment can be
inherited, overridden, or logged."
```

---

### Task 2: Per-task finding schema, complexity tag, and self-describing scores

The audit's output shape now depends on the task. Coverage findings ADD lines and are scored on gap severity; the other three REMOVE lines and are scored on lines saved. Every finding also carries the `complexity` tag that routes its apply session.

**Files:**
- Modify: `scripts/parse_result.jac` (`valid_rules`, `validate_finding`, `validate_findings`, the `findings` dispatch)
- Modify: `scripts/nslib.jac` (`score_of`)
- Modify: `fixtures/golden-audit.json`
- Modify: `bin/test-harness.sh` (sections 3 and 3b pass the new argv)

**Interfaces:**
- Produces: `jac run scripts/parse_result.jac findings <task> <scoring>` — validates the envelope's fenced array against the schema `<scoring>` demands, clamps `confidence`/`risk`/`complexity`, stamps `"task": <task>` on every finding, and drops the other mode's weight fields.
- Produces: `score_of(f: dict) -> float` in `nslib.jac`, unchanged signature, now reading `gap_severity` when present and `est_loc_saved` otherwise.
- Consumed by: `lib/tier2.sh` (Task 9), `scripts/selector.jac` (Task 3), `scripts/dataset.jac` (unchanged — it calls `score_of(fd)` and keeps working).

- [ ] **Step 1: Write the failing tests in `scripts/parse_result.jac`**

Append after the existing `test "findings: fenced array validated and clamped"`:

```jac
test "loc_saved schema: est_loc_saved required, complexity clamped, task stamped" {
    body: str = "```json\n[{\"file\": \"a.jac\", \"rule\": \"dead-code\", \"snippet\": \"x\", \"summary\": \"s\", \"est_loc_saved\": 10, \"confidence\": 4, \"risk\": 2, \"theme_hint\": \"dead\", \"complexity\": \"trivial\"}]\n```";
    found: list[dict] = validate_findings(body, "dead-code", "loc_saved");
    assert len(found) == 1;
    assert found[0]["task"] == "dead-code";
    assert found[0]["complexity"] == "trivial";
    assert score_of(found[0]) == 20.0;
}

test "an unrecognised complexity fails SAFE to judgement, not to the cheap model" {
    body: str = "```json\n[{\"file\": \"a.jac\", \"rule\": \"simplify\", \"snippet\": \"x\", \"summary\": \"s\", \"est_loc_saved\": 4, \"confidence\": 3, \"risk\": 1, \"theme_hint\": \"t\", \"complexity\": \"easy-peasy\"}]\n```";
    assert validate_findings(body, "abstraction", "loc_saved")[0]["complexity"] == "judgement";
}

test "risk_weighted schema: gap_severity + est_loc_added + test_file required" {
    ok: str = "```json\n[{\"file\": \"jac/jaclang/cli/pipe.jac\", \"rule\": \"missing-test\", \"snippet\": \"x\", \"summary\": \"s\", \"gap_severity\": 40, \"est_loc_added\": 30, \"test_file\": \"jac/tests/cli/test_pipe.jac\", \"confidence\": 4, \"risk\": 2, \"theme_hint\": \"cli\", \"complexity\": \"mechanical\"}]\n```";
    found: list[dict] = validate_findings(ok, "coverage", "risk_weighted");
    assert found[0]["est_loc_added"] == 30;
    assert score_of(found[0]) == 80.0;
    # a coverage finding with no test_file has no legal path to write anything: reject it here
    # rather than let the S4 scope gate discard the whole theme after a 25-minute apply session.
    bad: str = "```json\n[{\"file\": \"a.jac\", \"rule\": \"missing-test\", \"snippet\": \"x\", \"summary\": \"s\", \"gap_severity\": 4, \"est_loc_added\": 3, \"confidence\": 4, \"risk\": 2, \"theme_hint\": \"t\", \"complexity\": \"trivial\"}]\n```";
    raised: bool = False;
    try {
        validate_findings(bad, "coverage", "risk_weighted");
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "the other mode's weight field is stripped, so score_of can never read the wrong one" {
    # An audit that emits BOTH keys would otherwise be scored by whichever branch happens to win.
    body: str = "```json\n[{\"file\": \"a.jac\", \"rule\": \"missing-test\", \"snippet\": \"x\", \"summary\": \"s\", \"gap_severity\": 40, \"est_loc_added\": 30, \"est_loc_saved\": 999, \"test_file\": \"jac/tests/t.jac\", \"confidence\": 1, \"risk\": 1, \"theme_hint\": \"t\", \"complexity\": \"trivial\"}]\n```";
    f: dict = validate_findings(body, "coverage", "risk_weighted")[0];
    assert "est_loc_saved" not in f;
    assert score_of(f) == 40.0;
}
```

Add `score_of` to `parse_result.jac`'s nslib import list (line 19).

- [ ] **Step 2: Run the tests and watch them fail**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/parse_result.jac
```

Expected: FAIL — `validate_findings` takes one argument, not three.

- [ ] **Step 3: Rewrite the validators in `scripts/parse_result.jac`**

Replace `valid_rules`, `validate_finding` and `validate_findings` (lines 52-79) with:

```jac
"""ONE union of rule strings across all four tasks, deliberately not a per-task table. The rule
only feeds the fingerprint (nslib.fingerprint) and the digest; nothing branches on it except
selector.jac's vestigial-test sweep, and that path independently verifies every file it touches
(is_vestigial) rather than trusting the label. A per-task rule list would be config nothing reads."""
def valid_rules() -> list[str] {
    return ["dead-code", "duplication", "over-abstraction", "reinvented-stdlib", "unneeded-dep",
            "simplify",                                             # dead-code / abstraction
            "dep-drift", "todo", "doc-drift", "warning", "skipped-test",   # maintenance
            "missing-test"];                                        # coverage
}

glob COMPLEXITY_LEVELS: list[str] = ["trivial", "mechanical", "judgement"];

"""Which keys a finding must carry, per [tasks.<task>].scoring (design spec 3.2).

  loc_saved      the change REMOVES lines: est_loc_saved is both the score weight and what the
                 theme budgets against loc_per_theme.
  risk_weighted  the change ADDS lines: gap_severity is the weight, est_loc_added is what gets
                 budgeted, and test_file is the path the agent intends to write -- without it a
                 coverage theme has no legal write target at all.

Returned as (required-keys, key-to-strip) so the surviving finding SELF-DESCRIBES its mode and
nothing downstream has to be told which one it is."""
def schema_for(mode: str) -> (list[str], str) {
    if mode == "loc_saved" {
        return (["est_loc_saved"], "gap_severity");
    }
    if mode == "risk_weighted" {
        return (["gap_severity", "est_loc_added", "test_file"], "est_loc_saved");
    }
    raise ValueError("unknown scoring mode: " + mode);
}

def validate_finding(f: dict, task: str, mode: str) -> dict {
    (extra, strip) = schema_for(mode);
    for key in ["file", "rule", "snippet", "summary", "confidence", "risk", "theme_hint",
                "complexity"] + extra {
        require(key in f, "finding missing key: " + key);
    }
    require(str(f["rule"]) in valid_rules(), "unknown rule: " + str(f["rule"]));
    for key in extra {
        if key != "test_file" {
            f[key] = int(f[key]);
        }
    }
    if strip in f {
        del f[strip];
    }
    # clamp confidence/risk to [1..5] -- the orchestrator, not the agent, is the authority (TPRD S3-B)
    f["confidence"] = max(1, min(5, int(f["confidence"])));
    f["risk"] = max(1, min(5, int(f["risk"])));
    # An unrecognised complexity clamps to `judgement`, the EXPENSIVE model. Failing the other way
    # would hand a hard refactor to the cheap model on the strength of a typo, and the one-way
    # escalation in tier2_apply means a judgement theme never gets demoted anyway.
    if str(f.get("complexity", "")) not in COMPLEXITY_LEVELS {
        f["complexity"] = "judgement";
    }
    # The TASK is stamped by the harness, never taken from the agent: it decides which prompt, which
    # budget, and (through the branch name) which write permissions the theme gets.
    f["task"] = task;
    return f;
}

def validate_findings(raw: str, task: str, mode: str) -> list[dict] {
    items: list = parse_list(extract_fenced_json(raw));
    out: list[dict] = [];
    for item in items {
        if isinstance(item, dict) {
            out.append(validate_finding(item, task, mode));
        } else {
            raise ValueError("finding is not an object");
        }
    }
    return out;
}
```

- [ ] **Step 4: Update the `findings` dispatch**

In `with entry`, the `cmd in ["findings", "report", "meta"]` branch currently calls `validate_findings(envelope_result(envelope))`. Replace that call and guard the argv:

```jac
            } elif cmd == "findings" {
                require(len(args) == 4, "findings needs <task> <scoring>");
                print(json.dumps(validate_findings(envelope_result(envelope), args[2], args[3])));
```

Update the usage lines at the bottom:

```jac
        eprint("usage: claude -p ... --output-format json | jac run parse_result.jac findings <task> <scoring>");
        eprint("       ... | jac run parse_result.jac report|meta");
```

Also fix the pre-existing test at line 168-175 (`findings: fenced array validated and clamped`) — it calls `validate_findings` with one argument and its fixture has no `complexity`. Add `\"complexity\": \"mechanical\"` to the fixture JSON and pass `"dead-code", "loc_saved"`.

- [ ] **Step 5: Make `score_of` infer its weight in `scripts/nslib.jac`**

Replace `score_of` (lines 84-88):

```jac
"""Selection score (TPRD S3-B step 3, design spec 3.2): weight * confidence / risk.

The WEIGHT is read off the finding itself rather than passed in, because the finding already says
which mode it is: parse_result.validate_finding requires gap_severity for risk_weighted tasks and
est_loc_saved for loc_saved ones, and DELETES the other. Passing a mode instead would mean
plumbing it through selector, dataset, and every caller that only ever has one finding in hand --
and a carry-over night legitimately holds findings of two different modes at once."""
def score_of(f: dict) -> float {
    weight: int = int(f["gap_severity"]) if "gap_severity" in f else int(f["est_loc_saved"]);
    return float(weight * int(f["confidence"])) / float(int(f["risk"]));
}
```

Add a test next to the existing nslib tests:

```jac
test "score_of reads gap_severity for coverage findings and est_loc_saved otherwise" {
    shrink: dict = {"est_loc_saved": 30, "confidence": 4, "risk": 2};
    grow: dict = {"gap_severity": 30, "est_loc_added": 90, "confidence": 4, "risk": 2};
    assert score_of(shrink) == 60.0;
    assert score_of(grow) == 60.0;
}
```

- [ ] **Step 6: Run both test files**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac \
  && jac test scripts/nslib.jac && jac test scripts/parse_result.jac
```

Expected: PASS in both.

- [ ] **Step 7: Update the golden replay fixture**

`fixtures/golden-audit.json` predates `complexity`, so `parse_result findings` now rejects it:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
cat > fixtures/golden-audit.json <<'EOF'
{"result":"Audit complete.\n```json\n[{\"file\":\"pkg/main.jac\",\"rule\":\"dead-code\",\"snippet\":\"def never_called(x: int) -> int { return x * 999; }\",\"summary\":\"never_called is unreferenced\",\"est_loc_saved\":3,\"confidence\":5,\"risk\":1,\"theme_hint\":\"dead code\",\"complexity\":\"trivial\"}]\n```","is_error":false,"num_turns":8,"total_cost_usd":0}
EOF
jac run scripts/parse_result.jac findings dead-code loc_saved < fixtures/golden-audit.json
```

Expected: a one-element array carrying `"task": "dead-code"` and `"complexity": "trivial"`.

- [ ] **Step 8: Update `bin/test-harness.sh` sections 3 and 3b**

Line 23 gains the two new arguments:

```bash
jac run scripts/parse_result.jac findings dead-code loc_saved < fixtures/golden-audit.json > "$T/f.json" \
    || fail "golden audit no longer parses"
```

Then add, right after the existing `len` assertion on line 25, a positive check that the stamp actually happened — an unstamped finding would blow up in the selector much later, on a live night:

```bash
grep -q '"task": *"dead-code"' "$T/f.json" || fail "parse_result no longer stamps the task onto findings"
grep -q '"complexity"' "$T/f.json" || fail "parse_result no longer requires a complexity tag"
```

- [ ] **Step 9: Run the harness suite and commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add scripts/parse_result.jac scripts/nslib.jac fixtures/golden-audit.json bin/test-harness.sh
git commit -m "Give each task its own finding schema and a complexity tag

A coverage finding ADDS lines, so it carries gap_severity (the score weight),
est_loc_added (what the theme budgets), and test_file (the only path it has any
legal way to write). The other three tasks keep est_loc_saved. The parser
requires the right set per [tasks.<task>].scoring and DELETES the other mode's
weight key, so the finding self-describes and score_of never has to be told
which mode it is -- which matters on a carry-over night, when findings of two
modes are packed together.

Every finding now carries complexity: trivial | mechanical | judgement, which
routes its apply session. An unrecognised value clamps to judgement, the
expensive model: failing the other way would hand a hard refactor to the cheap
model on the strength of a typo."
```

---

### Task 3: Task-aware selection and carry-over

Themes become per-task, deferred work is written to a carry-over file, and next night's packing puts it first.

**Files:**
- Modify: `scripts/selector.jac` (`pack_themes`, `fit_clock`, `select`, tests)

**Interfaces:**
- Produces: themes carrying `task`, `complexity`, `fragment_kind`, `carry`, and a slug of the form `<task>-<theme-hint>`.
- Produces: `selection["carryover"]` — the full finding objects dropped for `over-night-budget` / `no-clock-left`, each stamped `"carry": true`. `lib/tier2.sh` writes it to `state/carryover.json`; the next night merges it ahead of that night's own findings.
- Consumed by: `lib/tier2.sh` (Task 9), `scripts/check_scope.jac` (Task 5, `fragment_kind`), `lib/verify.sh` (Task 6, via the branch name).

- [ ] **Step 1: Write the failing tests in `scripts/selector.jac`**

Append after the existing `test "clock shedding removes lowest-scored theme"`:

```jac
test "themes are task-scoped: same theme_hint from two tasks never merges into one theme" {
    import tempfile;
    body: str = "[budgets]\nthemes_per_night = 4\nfiles_per_theme = 5\nloc_per_theme = 500\napply_timeout_min = 25\n[protect]\nglobs = []\n[tasks.dead-code]\nponytail=\"full\"\nscoring=\"loc_saved\"\nfragment=\"refactor\"\n[tasks.coverage]\nponytail=\"lite\"\nscoring=\"risk_weighted\"\nfragment=\"\"\n";
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    findings: list[dict] = [
        {"file": "p/a.jac", "rule": "dead-code", "snippet": "s", "summary": "x", "task": "dead-code",
         "est_loc_saved": 40, "confidence": 4, "risk": 2, "theme_hint": "cli", "complexity": "trivial"},
        {"file": "p/b.jac", "rule": "missing-test", "snippet": "s", "summary": "x", "task": "coverage",
         "gap_severity": 40, "est_loc_added": 60, "test_file": "jac/tests/test_b.jac",
         "confidence": 4, "risk": 2, "theme_hint": "cli", "complexity": "judgement"},
    ];
    result: dict = select(findings, cfg_path, "/nonexistent", "/nonexistent", 999, "/nonexistent-repo");
    slugs: list[str] = sorted([str(as_dict(t)["slug"]) for t in as_list(result["themes"])]);
    assert slugs == ["coverage-cli", "dead-code-cli"];
    for t in as_list(result["themes"]) {
        theme: dict = as_dict(t);
        if str(theme["task"]) == "coverage" {
            assert str(theme["fragment_kind"]) == "";
            assert str(theme["complexity"]) == "judgement";
            # the intended test file is pulled into scope; without it the theme cannot write at all
            assert "jac/tests/test_b.jac" in [str(f) for f in as_list(theme["files"])];
            assert int(theme["est_loc"]) == 60;          # budgets est_loc_added, not gap_severity
        } else {
            assert str(theme["fragment_kind"]) == "refactor";
            assert int(theme["est_loc"]) == 40;
        }
    }
}

test "carry-over: deferred findings are emitted, and pack FIRST the next night" {
    import tempfile;
    body: str = "[budgets]\nthemes_per_night = 1\nfiles_per_theme = 5\nloc_per_theme = 500\napply_timeout_min = 25\n[protect]\nglobs = []\n[tasks.dead-code]\nponytail=\"full\"\nscoring=\"loc_saved\"\nfragment=\"refactor\"\n";
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    def mk(hint: str, loc: int) -> dict {
        return {"file": "p/" + hint + ".jac", "rule": "dead-code", "snippet": "s", "summary": "x",
                "task": "dead-code", "est_loc_saved": loc, "confidence": 5, "risk": 1,
                "theme_hint": hint, "complexity": "trivial"};
    }
    # themes_per_night = 1, so the smaller theme is dropped over-night-budget and carried
    night1: dict = select([mk("big", 200), mk("small", 10)], cfg_path,
                          "/nonexistent", "/nonexistent", 999, "/nonexistent-repo");
    carried: list[dict] = [as_dict(c) for c in as_list(night1["carryover"])];
    assert len(carried) == 1;
    assert str(carried[0]["theme_hint"]) == "small";
    assert carried[0]["carry"] == True;

    # night 2: the carried finding is packed FIRST even though tonight's finding scores higher
    night2: dict = select(carried + [mk("huge", 500)], cfg_path,
                          "/nonexistent", "/nonexistent", 999, "/nonexistent-repo");
    assert str(as_dict(as_list(night2["themes"])[0])["slug"]) == "dead-code-small";
}

test "over-theme-budget findings are NOT carried: they never fit, and would carry forever" {
    import tempfile;
    body: str = "[budgets]\nthemes_per_night = 4\nfiles_per_theme = 5\nloc_per_theme = 50\napply_timeout_min = 25\n[protect]\nglobs = []\n[tasks.dead-code]\nponytail=\"full\"\nscoring=\"loc_saved\"\nfragment=\"refactor\"\n";
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    too_big: list[dict] = [{"file": "p/a.jac", "rule": "dead-code", "snippet": "s", "summary": "x",
        "task": "dead-code", "est_loc_saved": 900, "confidence": 5, "risk": 1,
        "theme_hint": "whale", "complexity": "trivial"}];
    result: dict = select(too_big, cfg_path, "/nonexistent", "/nonexistent", 999, "/nonexistent-repo");
    assert [str(d["reason"]) for d in as_list(result["dropped"])] == ["over-theme-budget"];
    assert as_list(result["carryover"]) == [];
}
```

Also update the four pre-existing selector tests: every finding literal needs `"task": "dead-code"` (or the matching task) and `"complexity"`, and every inline config body needs a `[tasks.<task>]` table. The "packing respects caps" test's `dup` finding becomes `"task": "abstraction"`, so its expected theme count stays 2 while the slugs become task-qualified.

- [ ] **Step 2: Run them and watch them fail**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/selector.jac
```

Expected: FAIL — `KeyError: 'task'` from `slugify`, and `carryover` missing from the result.

- [ ] **Step 3: Add the per-task helpers to `scripts/selector.jac`**

Insert after `slugify` (line 113):

```jac
"""[tasks.<task>] as a narrowed dict. Every level goes through as_dict: a raw
cfg["tasks"][task]["fragment"] fails `jac check` with E1001."""
def task_table(cfg: dict, task: str) -> dict {
    tasks: dict = as_dict(cfg["tasks"]);
    if task not in tasks {
        raise ValueError("finding names an unknown task: " + task);
    }
    return as_dict(tasks[task]);
}

"""What this finding costs against [budgets].loc_per_theme. A coverage finding budgets the lines
it ADDS; every other task budgets the lines it removes. Read off the finding, which already
carries exactly one of the two (parse_result.validate_finding deletes the other)."""
def budget_of(f: dict) -> int {
    return int(f["est_loc_added"]) if "est_loc_added" in f else int(f["est_loc_saved"]);
}

"""A theme is as expensive as its hardest finding: one judgement finding makes the whole apply
session judgement work, because it is one session over all of them."""
def theme_complexity(picked: list[dict]) -> str {
    levels: list[str] = [str(f.get("complexity", "judgement")) for f in picked];
    if "judgement" in levels {
        return "judgement";
    }
    if "mechanical" in levels {
        return "mechanical";
    }
    return "trivial";
}
```

- [ ] **Step 4: Make `pack_themes` task-aware**

Change the signature to take the whole config (it needs `[tasks.*]` as well as `[budgets]`) and rework the grouping, budgeting, and theme dict:

```jac
def pack_themes(eligible: list[dict], cfg: dict, repo_dir: str,
                 protect_globs: list[str]) -> (list[dict], list[dict]) {
    budgets: dict = as_dict(cfg["budgets"]);
    groups: dict[str, list[dict]] = {};
    for f in eligible {
        # Task-QUALIFIED slug. Two tasks legitimately produce the same theme_hint ("cli"), and
        # merging them would give one branch two tasks -- and therefore an ambiguous set of write
        # permissions at the S4 gate. It also makes the task recoverable from the branch name
        # alone (lib/common.sh ns_task_of_branch), which is the one place the agent cannot reach.
        slug: str = slugify(str(f["task"]) + "-" + str(f["theme_hint"]));
        if slug not in groups {
            groups[slug] = [];
        }
        groups[slug].append(f);
    }
    themes: list[dict] = [];
    dropped: list[dict] = [];
    for (slug, group) in groups.items() {
        group.sort(key=lambda f: dict -> tuple { return (-score_of(f), str(f["fingerprint"])); });
        task: str = str(group[0]["task"]);
        files: list[str] = [];
        picked: list[dict] = [];
        est_loc: int = 0;
        for f in group {
            file: str = str(f["file"]);
            new_file: int = 0 if file in files else 1;
            if len(files) + new_file > int(budgets["files_per_theme"])
               or est_loc + budget_of(f) > int(budgets["loc_per_theme"]) {
                dropped.append({"fingerprint": f["fingerprint"], "file": file, "rule": f["rule"], "reason": "over-theme-budget"});
                continue;
            }
            if new_file == 1 {
                files.append(file);
            }
            # The file the coverage agent intends to WRITE. Without it in the allow-list the theme
            # has no legal write target and the S4 gate discards the whole branch after a
            # 25-minute session. Not budgeted as a file slot: it is the point of the theme.
            if "test_file" in f and str(f["test_file"]) not in files {
                files.append(str(f["test_file"]));
            }
            picked.append(f);
            est_loc += budget_of(f);
        }
        if picked {
            for f in list(files) {
                for sib in impl_siblings(f) {
                    if sib not in files and len(files) < int(budgets["files_per_theme"]) {
                        files.append(sib);
                    }
                }
            }
            vestigial: list[str] = [];
            # Vestigial test deletion belongs to the dead-code TASK only, and still only when every
            # finding in the theme is a dead-code rule. Both conditions, not one: the rule vocabulary
            # is a single union across tasks now, so the task check alone would let an abstraction-
            # flavoured finding inside a dead-code theme widen what gets deleted.
            if task == "dead-code" and all([str(f["rule"]) == "dead-code" for f in picked]) {
                vestigial = vestigial_test_files(repo_dir, files, protect_globs);
            }
            themes.append({
                "name": str(picked[0]["theme_hint"]), "slug": slug, "task": task,
                "complexity": theme_complexity(picked),
                "fragment_kind": str(task_table(cfg, task)["fragment"]),
                "carry": any([bool(f.get("carry", False)) for f in picked]),
                "files": files, "vestigial_deletions": vestigial,
                "findings": picked, "est_loc": est_loc,
                "score": sum([score_of(f) for f in picked]),
            });
        }
    }
    # CARRIED THEMES FIRST, unconditionally -- ahead of tonight's own task, however well tonight's
    # scores (design spec 4). Work resumes across nights while the cycle still advances. fit_clock
    # sheds from the END, so this ordering also decides what survives a short night.
    themes.sort(key=lambda t: dict -> tuple {
        return (0 if t.get("carry", False) else 1, -as_float(t["score"]), str(t["slug"]));
    });
    for t in themes[int(budgets["themes_per_night"]):] {
        for f in as_list(t["findings"]) {
            dropped.append({"fingerprint": f["fingerprint"], "file": f["file"], "rule": as_dict(f)["rule"], "reason": "over-night-budget"});
        }
    }
    return (themes[:int(budgets["themes_per_night"])], dropped);
}
```

- [ ] **Step 5: Emit the carry-over set from `select`**

Replace `select`'s body from the `pack_themes` call onward:

```jac
    (themes, dropped2) = pack_themes(eligible, cfg, repo_dir, globs);
    (themes2, dropped3) = fit_clock(themes, dropped2, budgets, verify_estimate, remaining_min);
    all_dropped: list[dict] = dropped + dropped3;

    # Carry-over (design spec 4). Only the two "it fitted a theme but not the night" reasons are
    # carried. over-theme-budget is deliberately excluded: such a finding is too big for ANY theme,
    # so carrying it would re-drop it for the same reason every night, forever, while the file grew.
    # protected-path and the ledger reasons are terminal by definition.
    index: dict[str, dict] = {};
    for f in findings {
        index[str(f["fingerprint"])] = f;
    }
    carryover: list[dict] = [];
    for d in all_dropped {
        if str(d["reason"]) in ["over-night-budget", "no-clock-left"] {
            item: dict = as_dict(index.get(str(d["fingerprint"]), {}));
            if item {
                item["carry"] = True;
                carryover.append(item);
            }
        }
    }
    return {"themes": themes2, "dropped": all_dropped, "carryover": carryover};
```

- [ ] **Step 6: Run the selector tests**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/selector.jac
```

Expected: PASS, all tests (four updated, three new).

- [ ] **Step 7: Verify determinism and the carry-over shape end to end**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac
jac run scripts/parse_result.jac findings dead-code loc_saved < fixtures/golden-audit.json \
  | jac run scripts/selector.jac select config/nightshift.toml /nonexistent /nonexistent 999 /nonexistent-repo \
  | jac run scripts/parse_result.jac field carryover
```

Expected: `[]` (one small finding, nothing deferred). Then confirm the theme slug is task-qualified:

```bash
jac run scripts/parse_result.jac findings dead-code loc_saved < fixtures/golden-audit.json \
  | jac run scripts/selector.jac select config/nightshift.toml /nonexistent /nonexistent 999 /nonexistent-repo \
  | grep -o '"slug": *"[^"]*"'
```

Expected: `"slug": "dead-code-dead-code"` (task `dead-code` + theme_hint `dead code`).

- [ ] **Step 8: Run the harness suite and commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add scripts/selector.jac
git commit -m "Scope themes to their task and carry deferred work to the next night

Theme slugs are task-qualified (<task>-<theme-hint>). Two tasks legitimately
produce the same theme_hint, and merging them would give one branch two tasks
and an ambiguous set of write permissions at the S4 gate. It also makes the
task recoverable from the branch name alone, which is the one carrier the agent
cannot influence.

Budgeting reads the finding's own weight key, so a coverage theme budgets the
lines it ADDS while the other three budget lines removed, with no mode plumbed
through the call chain.

Findings shed for over-night-budget or no-clock-left are returned as a
carryover set and packed FIRST the next night, ahead of that night's own task,
so work resumes across nights while the cycle still advances.
over-theme-budget is excluded on purpose: it never fits any theme, so carrying
it would re-drop it every night forever."
```

---

### Task 4: Four audit prompts and one shared apply prompt

The four audits genuinely hunt different things, so they are four files. Apply is one file with a small per-task rules block injected — not a template engine.

**Files:**
- Create: `prompts/audit-dead-code.md` (git mv from `prompts/audit.md`), `prompts/audit-abstraction.md`, `prompts/audit-maintenance.md`, `prompts/audit-coverage.md`
- Create: `prompts/apply-rules-dead-code.md`, `apply-rules-abstraction.md`, `apply-rules-maintenance.md`, `apply-rules-coverage.md`
- Modify: `prompts/apply.md`
- Modify: `bin/test-harness.sh` (section 11)

**Interfaces:**
- Produces: `prompts/audit-<task>.md` for every name `tasks.jac list` prints. Placeholders: `{shard}`, `{scope}`, `{protect_globs}`, `{ponytail_mode}`, plus `{coverage_evidence}` in `audit-coverage.md` only.
- Produces: `prompts/apply-rules-<task>.md` for every task, substituted into `prompts/apply.md`'s `{task_apply_rules}`.
- Consumed by: `lib/tier2.sh` (Task 9).

- [ ] **Step 1: Rename the existing audit prompt and add the shared finding schema**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && git mv prompts/audit.md prompts/audit-dead-code.md
```

Then edit `prompts/audit-dead-code.md`: narrow its rule list to this task, and add `complexity` to the schema. Replace the `Hard rules` bullet about finding kinds and the JSON schema block with:

```
Hard rules:
- Do NOT edit anything. This session is read-only.
- Do NOT report anything under these protected globs: {protect_globs}
- ONLY dead code: unreachable branches, unreferenced symbols, orphaned files, vestigial tests,
  config keys nothing reads, and dependencies nothing imports. Not duplication, not
  over-abstraction, not drift, not missing tests -- other nights hunt those. If the code runs, it
  is not this task's business.
- Never propose feature work, bug fixes, or performance tuning.

Output ONLY a fenced ```json array of findings — no prose before or after. Each finding:

{
  "file": "relative/path/from/repo/root.jac",
  "rule": "dead-code | unneeded-dep",
  "snippet": "<= 3 lines, verbatim from the file",
  "summary": "detailed, 3-6 sentences: what exactly is wrong, why it's safe to remove, and the
      CONCRETE EVIDENCE you gathered (what you grepped, what you read, what you confirmed --
      e.g. 'grepped all 340 .jac files for X(, zero call sites outside its own definition and one
      disabled test'). A reviewer with zero prior context should be able to verify your claim from
      the summary alone, without re-doing your research.",
  "est_loc_saved": <int>,
  "confidence": <1-5>,
  "risk": <1-5>,
  "complexity": "trivial | mechanical | judgement",
  "theme_hint": "short-slug"
}

`complexity` decides which model executes the change, so be honest about it:
- trivial     — a deletion with no callers and no signature change.
- mechanical  — a deletion that ripples predictably (remove the symbol, remove its imports).
- judgement   — anything where a human would have to think about whether it is really unused.
```

- [ ] **Step 2: Create `prompts/audit-abstraction.md`**

Copy `audit-dead-code.md` and replace the framing paragraph, the rule list, and the `rule` enum:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && cp prompts/audit-dead-code.md prompts/audit-abstraction.md
```

Then edit the header line and the two task-specific blocks:

```
/ponytail-audit

You are auditing ONLY {scope} of the Jaseci monorepo (audit shard: `{shard}`) for
OVER-ABSTRACTION — using the ponytail ladder (mode: {ponytail_mode}).

The code you are reading RUNS. Your question is not "is this dead" (another night hunts that) but
"is this more machinery than the job needs": duplication that wants collapsing, an interface with
exactly one implementation, a wrapper that only forwards, a hand-rolled version of something the
standard library or the Jac runtime already provides, a factory that constructs one thing, a
configuration knob whose value never changes.
```

Rule enum: `"rule": "duplication | over-abstraction | reinvented-stdlib | simplify"`. Complexity guidance:

```
- trivial     — collapse a wrapper, inline a single-use helper.
- mechanical  — replace a reinvented helper with the stdlib equivalent at every call site.
- judgement   — anything that changes a shape other code depends on.
```

- [ ] **Step 3: Create `prompts/audit-maintenance.md`**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && cp prompts/audit-dead-code.md prompts/audit-maintenance.md
```

Header and task block:

```
You are auditing ONLY {scope} of the Jaseci monorepo (audit shard: `{shard}`) for DRIFT —
things that were true once and are not true now (ponytail mode: {ponytail_mode}).

What counts: a dependency pinned to a version nothing needs any more, a TODO/FIXME whose subject
was resolved years ago, a docstring or comment that describes code that has since changed, a
compiler warning the build has learned to ignore, a test marked skip permanently. What does NOT
count: anything that would change behaviour, and anything you cannot prove is stale. "This comment
is vague" is not drift; "this comment says the function returns a list, it returns a dict" is.
```

Rule enum: `"rule": "dep-drift | todo | doc-drift | warning | skipped-test"`. Maintenance is the one task whose fragment kind is `auto`, so add one extra schema key and explain it:

```
  "fragment_kind": "feature | bugfix | breaking | refactor | docs",
```

```
`fragment_kind` is the release-note category this change belongs to. The harness writes the
fragment file, not you; it validates your answer and falls back to `refactor` if it is not one of
those five.
```

- [ ] **Step 4: Create `prompts/audit-coverage.md`**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && cp prompts/audit-dead-code.md prompts/audit-coverage.md
```

Header, evidence block, and task rules:

```
You are auditing ONLY {scope} of the Jaseci monorepo (audit shard: `{shard}`) for UNTESTED
BEHAVIOUR (ponytail mode: {ponytail_mode} — lite, because your output is a test that must exist).

EVIDENCE. The harness has already resolved which public symbols in this shard are never referenced
from any file under a test tree. This is a static proxy, not line coverage: a symbol can appear
here and still be exercised indirectly, and a symbol absent from this list can still have
completely untested error paths. Verify before you report.

{coverage_evidence}

Hunt, in this order: error paths that no test provokes, edge cases at boundaries (empty, zero,
maximum, unicode), and public entry points with no test reference at all.

Hard rules:
- Do NOT edit anything. This session is read-only.
- Report the SOURCE file that lacks coverage in `file`, and the test file you would write in
  `test_file`. `test_file` must live under a test tree — an existing `**/tests/**` file for that
  module if there is one, otherwise the conventional path next to its siblings. It is the only
  path the apply session will be permitted to write, so choose it carefully.
- Never propose changing the source file to make it easier to test. This task adds tests to the
  code as it is.
- Do NOT report a symbol whose absence of tests is the point (generated code, a `__main__` shim).
```

Schema: replace `est_loc_saved` with the coverage triple and keep the rest:

```
  "rule": "missing-test",
  "gap_severity": <int>,   # LOC of behaviour left unprotected -- the same units as est_loc_saved
                           # on other nights, so the two are comparable when carried-over work
                           # from a different task is packed alongside tonight's.
  "est_loc_added": <int>,  # how many lines of test you expect to write
  "test_file": "relative/path/to/the/test/file.jac",
```

Complexity guidance:

```
- trivial     — one more case in an existing, well-shaped test.
- mechanical  — a new test that follows the pattern of the tests already in that file.
- judgement   — anything needing a fixture, a mock, or a decision about what the behaviour SHOULD be.
```

- [ ] **Step 5: Create the four apply-rules snippets**

`prompts/apply-rules-dead-code.md`:

```markdown
TASK: dead-code. You are DELETING. Every edit you make should make the file shorter.

- If a deletion turns out to ripple further than the theme's file list allows, skip it and say so
  in `skipped` rather than editing a file the harness will reject the whole branch for.
- If the theme has a non-empty `vestigial_deletions` list: those paths live under a normally-
  protected `tests/**` glob, but the harness has already independently confirmed -- before this
  session started, not from anything you tell it -- that every remaining reference in each of them
  is to a symbol this theme is deleting. You MAY `git rm` them wholesale for that reason alone.
  You may NOT edit them; a partial edit is rejected. If your own reading disagrees, leave the file
  alone and say why in `skipped`.
- Deleting a symbol can invalidate the generated `jir_registry.jac`, which CI verifies. The
  harness re-checks it after you finish; you do not need to regenerate anything.
```

`prompts/apply-rules-abstraction.md`:

```markdown
TASK: abstraction. You are COLLAPSING machinery, not deleting features.

- Behaviour-preserving or rejected. Every call site of anything you change must keep working.
- Prefer deleting the abstraction over rewriting it. If the simplification needs a redesign, skip
  it and record why in `skipped` -- redesigns need intent, which a janitorial session does not have.
- Replacing a hand-rolled helper with a stdlib or Jac-runtime equivalent counts as done only when
  every call site is migrated and the helper itself is gone.
```

`prompts/apply-rules-maintenance.md`:

```markdown
TASK: maintenance. You are fixing DRIFT: making the text match the code, or the pin match the need.

- Behaviour-preserving or rejected. Bumping a dependency to fix a bug is not this task.
- A resolved TODO gets deleted, not rewritten. A wrong comment gets corrected, not expanded.
- Include `"fragment_kind"` in your final report: which of feature | bugfix | breaking | refactor |
  docs this change belongs to. The harness writes the release-note file itself and validates your
  answer, falling back to `refactor`.
```

`prompts/apply-rules-coverage.md`:

```markdown
TASK: coverage. You are ADDING tests. This is the one task that writes inside `tests/**`, and the
only files you may WRITE are the test files in the theme (the harness rejects any other write,
including to the source file the gap is in -- read it all you like, do not touch it).

- Never weaken an existing test. The gate rejects any diff that reduces the assert count or the
  test count of a test file that already existed, whatever else the diff does. Refactoring three
  asserts into one parametrised case will be rejected: add, do not restructure.
- A test that cannot fail is worse than no test. Before you finish, break the code under test in
  your head and confirm your assertion would catch it. If it would not, the assertion is wrong.
- Ponytail mode is `lite` here on purpose: do not YAGNI your own test away.
- Run the new test and paste what you saw into `summary`. A test you did not run is not a finding,
  it is a hope.
```

- [ ] **Step 6: Add the placeholder to `prompts/apply.md`**

Replace the `HARD RULES:` opening (line 6) with the task block, and delete the `vestigial_deletions` bullet (it moved into the dead-code snippet where it belongs):

```
{task_apply_rules}

HARD RULES (every task):
- Touch ONLY the files listed in the theme. The harness discards any diff outside this list,
  no matter how green the tests are.
```

Keep the rest of the file as-is, and add `fragment_kind` to the report schema as an optional key:

```
  "fragment_kind": "only for the maintenance task: feature | bugfix | breaking | refactor | docs",
```

- [ ] **Step 7: Add the prompt-completeness check to `bin/test-harness.sh`**

Append before the final echo:

```bash
echo "== 11. task registry: every task has both prompts, and no placeholder is left unrendered =="
rm -rf .jac
tasks="$(jac run scripts/tasks.jac list config/nightshift.toml)" || fail "tasks.jac list failed"
n_tasks="$(printf '%s\n' "$tasks" | grep -c .)"
# An empty list would make every loop below pass vacuously -- the exact shape of assertion this
# project keeps shipping. Pin the count first.
case "$n_tasks" in
    4) : ;;
    *) fail "expected 4 tasks, tasks.jac list printed $n_tasks" ;;
esac
# The cycle order is a product decision (delete -> simplify -> fix drift -> test), so pin it here
# too: scripts/tasks.jac's own test pins it from inside Jac, this pins what bash actually sees.
case "$(printf '%s' "$tasks" | tr '\n' ' ')" in
    "dead-code abstraction maintenance coverage ") : ;;
    *) fail "cycle order changed: '$tasks'" ;;
esac
# No task name may be a prefix of another: lib/common.sh's ns_task_of_branch resolves the task from
# the branch slug by prefix, and an ambiguous pair would silently hand a branch the wrong task --
# and therefore the wrong write permissions.
for a in $tasks; do
    for b in $tasks; do
        case "$a" in
            "$b") : ;;
            "$b"*) fail "task name '$b' is a prefix of '$a'; ns_task_of_branch could not tell them apart" ;;
        esac
    done
done
for t in $tasks; do
    [ -f "prompts/audit-$t.md" ] || fail "no prompts/audit-$t.md for declared task '$t'"
    [ -f "prompts/apply-rules-$t.md" ] || fail "no prompts/apply-rules-$t.md for declared task '$t'"
    [ -s "prompts/apply-rules-$t.md" ] || fail "prompts/apply-rules-$t.md is empty"
done
# Render each prompt through the REAL render_prompt with the real substitution set and demand that
# nothing {braced} survives. A prompt shipped with a live {placeholder} reaches the model verbatim.
for t in $tasks; do
    left="$( . "$NS_ROOT/lib/tier2.sh" >/dev/null 2>&1
             render_prompt "prompts/audit-$t.md" "shard=s" "scope=sc" "protect_globs=g" \
                           "ponytail_mode=full" "coverage_evidence=e" \
               | grep -o '{[a-z_]*}' | sort -u | tr '\n' ' ' )"
    case "$left" in
        "") : ;;
        *) fail "prompts/audit-$t.md has unrendered placeholders: $left" ;;
    esac
done
left="$( . "$NS_ROOT/lib/tier2.sh" >/dev/null 2>&1
         render_prompt prompts/apply.md "theme={}" "ponytail_mode=full" \
                       "task_apply_rules=$(cat prompts/apply-rules-coverage.md)" \
           | grep -o '{[a-z_]*}' | sort -u | tr '\n' ' ' )"
case "$left" in
    "") : ;;
    *) fail "prompts/apply.md has unrendered placeholders: $left" ;;
esac
rm -rf .jac
echo "4 tasks, 8 prompt files, no unrendered placeholders"
```

- [ ] **Step 8: Run it and commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add prompts bin/test-harness.sh
git commit -m "Split the audit prompt four ways; inject per-task rules into one apply prompt

The four audits hunt genuinely different things and share almost no wording, so
they are four files. Apply is one file with a small per-task rules block
substituted into {task_apply_rules} -- four snippets of 5-12 lines each, no
template engine.

Every audit prompt now demands a complexity tag per finding, with concrete
per-task guidance on what trivial/mechanical/judgement mean, because that tag
decides which model executes the change.

bin/test-harness.sh pins the cycle order as bash sees it, asserts no task name
is a prefix of another (ns_task_of_branch resolves the task by prefix), and
renders every prompt through the real render_prompt to prove no {placeholder}
survives into a live session."
```

---

### Task 5: Consume `fragment_kind` end to end

`fragment_kind` is set by nothing today while three sites disagree about it (follow-ups section 3). The task registry gives it a source, so it gets consumed — and the hardcoded `0000.refactor.md` rename that silently no-ops for four of the five kinds is deleted rather than documented again.

**Files:**
- Modify: `scripts/nslib.jac` (`fragment_path` honours an empty kind)
- Modify: `scripts/check_scope.jac` (allow all kinds when the theme's kind is `auto`)
- Modify: `scripts/render_draft.jac` (`frag` takes the kind)
- Modify: `lib/promote.sh` (kind-agnostic rename)
- Modify: `lib/tier2.sh` (pass the kind to `render_draft frag`)

**Interfaces:**
- Produces: `fragment_path(paths, "") -> ""` — an explicit "this task needs no fragment", distinct from "these paths need none".
- Produces: `jac run scripts/render_draft.jac frag <report.json> <kind>` — the fragment path for a report, resolving `auto` from the report's own validated `fragment_kind`.
- Consumed by: `lib/tier2.sh` (Task 9), `lib/promote.sh`.

- [ ] **Step 1: Write the failing tests**

In `scripts/nslib.jac`, extend the existing `fragment_path` test:

```jac
test "an empty kind means the TASK needs no fragment at all" {
    # Distinct from "these paths need none": the coverage task sets fragment = "" in config, and
    # without this branch the empty string would fall through the validity check and be clamped
    # to `refactor` -- writing a release note for a tests-only change.
    assert fragment_path(["jac/jaclang/cli/b.jac"], "") == "";
    assert fragment_path(["jac/jaclang/cli/b.jac"], "auto")
        == "release_notes/unreleased/jaclang/0000.refactor.md";
}
```

In `scripts/check_scope.jac`:

```jac
test "an auto-kind theme may write any of the five valid fragment names" {
    theme: dict = {"files": ["jac/jaclang/cli/pipe.jac"], "fragment_kind": "auto"};
    globs: list[str] = ["**/tests/**"];
    for kind in ["feature", "bugfix", "breaking", "refactor", "docs"] {
        changed: list[tuple[str, str]] = [
            ("M", "jac/jaclang/cli/pipe.jac"),
            ("A", "release_notes/unreleased/jaclang/0000." + kind + ".md"),
        ];
        assert violations(changed, theme, globs, []) == [];
    }
    # ...but not an invented one: the filename regex is what CI enforces
    bad: list[tuple[str, str]] = [("A", "release_notes/unreleased/jaclang/0000.chore.md")];
    assert len(violations(bad, theme, globs, [])) == 1;
}

test "a task with fragment = '' may not write a fragment at all" {
    theme: dict = {"files": ["jac/jaclang/cli/pipe.jac"], "fragment_kind": ""};
    found: list[str] = violations(
        [("A", "release_notes/unreleased/jaclang/0000.refactor.md")], theme, [], []);
    assert len(found) == 1;
}
```

(The fourth `violations` argument is the `protect_unless` list added in Task 6; add the parameter now with a default of `[]` so both tasks compile — Task 6 gives it behaviour.)

- [ ] **Step 2: Run them and watch them fail**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac \
  && jac test scripts/nslib.jac; jac test scripts/check_scope.jac
```

Expected: FAIL in both — `fragment_path` clamps `""` to `refactor`, and `violations` takes three arguments.

- [ ] **Step 3: Teach `fragment_path` about the empty kind**

`scripts/nslib.jac`, in `fragment_path`, before the loop:

```jac
def fragment_path(paths: list[str], kind: str) -> str {
    # "" means the TASK declares it needs no fragment ([tasks.coverage].fragment). Checked before
    # the validity clamp below, which would otherwise turn it into "refactor" and write a release
    # note for a tests-only change.
    if kind == "" {
        return "";
    }
    safe_kind: str = kind if kind in VALID_FRAGMENT_KINDS else "refactor";
    ...
```

- [ ] **Step 4: Widen the allow-list for `auto` in `scripts/check_scope.jac`**

Replace the fragment block inside `violations` (lines 20-26):

```jac
    theme_files: list[str] = [str(f) for f in theme["files"]];
    allowed: list[str] = list(theme_files);
    # The ORCHESTRATOR writes the fragment, but the gate must still let it through. `auto`
    # (the maintenance task) means the AGENT picks the kind and the harness validates it, so all
    # five legal names are allowed here -- the directory and the 0000 stem are fixed either way,
    # which is what CI's filename regex actually checks. "" means the task needs no fragment and
    # therefore may not write one.
    kind: str = str(theme.get("fragment_kind", "refactor"));
    kinds: list[str] = VALID_FRAGMENT_KINDS if kind == "auto" else [kind];
    for k in kinds {
        frag: str = fragment_path(theme_files, k);
        if frag and frag not in allowed {
            allowed.append(frag);
        }
    }
```

Import `VALID_FRAGMENT_KINDS` from `nslib` on line 16.

- [ ] **Step 5: Give `render_draft.jac`'s `frag` verb the kind**

Replace `frag_for_report` (lines 91-103) and its dispatch:

```jac
"""The fragment path implied by the files the agent actually touched, at the kind the TASK
declares. `auto` (maintenance) resolves from the agent's own reported fragment_kind, which
fragment_path then clamps to a valid name -- so an agent cannot invent a filename CI will reject.
This was one of three sites that hardcoded `refactor`; the other two are gone with it."""
def frag_for_report(report_path: str, kind: str) -> str {
    with open(report_path, "r") as f {
        rep: dict = parse_obj(f.read());
    }
    resolved: str = kind;
    if kind == "auto" {
        resolved = str(rep.get("fragment_kind", "refactor"));
    }
    return fragment_path([str(p) for p in as_list(rep["files"])], resolved);
}
```

Dispatch (line 152):

```jac
    if cmd == "frag" and len(args) == 4 {
        print(frag_for_report(args[2], args[3]));
```

Update the usage line and the existing `frag` test to pass a kind, and add:

```jac
test "auto resolves the kind from the agent's report and clamps an invented one" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    p: str = d + "/r.json";
    with open(p, "w") as f {
        f.write(json.dumps({"files": ["jac/jaclang/cli/a.jac"], "fragment_kind": "bugfix"}));
    }
    assert frag_for_report(p, "auto") == "release_notes/unreleased/jaclang/0000.bugfix.md";
    assert frag_for_report(p, "refactor") == "release_notes/unreleased/jaclang/0000.refactor.md";
    assert frag_for_report(p, "") == "";
    q: str = d + "/q.json";
    with open(q, "w") as f {
        f.write(json.dumps({"files": ["jac/jaclang/cli/a.jac"], "fragment_kind": "chore"}));
    }
    assert frag_for_report(q, "auto") == "release_notes/unreleased/jaclang/0000.refactor.md";
}
```

- [ ] **Step 6: Make the promote-time rename kind-agnostic**

`lib/promote.sh`, replace the `LATENT COUPLING` comment block and the `git mv` line (around line 77):

```bash
    # 3. rename the release-note fragment 0000 -> <PR#> (the PR updates itself on push).
    # Kind-agnostic: only the leading `0000.` is replaced, so this works for all five kinds. It
    # used to strip the literal suffix `0000.refactor.md`, which made the rename a silent no-op
    # for the other four -- shipping a fragment still called 0000 the moment anything emitted a
    # fragment_kind. Plan 2 made things emit one.
    fragment="$(ns_jac render_draft meta "$draft" | ns_jac parse_result field release_note)"
    if [ -n "$fragment" ] && git -C "$REPO" ls-files --error-unmatch "$fragment" >/dev/null 2>&1; then
        frag_base="$(basename "$fragment")"
        case "$frag_base" in
            0000.*) : ;;
            *) ns_die "$EX_BUG" "fragment '$fragment' does not start with the 0000 placeholder, so the PR-number rename cannot be applied -- shipping it unrenamed would fail CI's release-note check." ;;
        esac
        git -C "$REPO" checkout "$branch"
        git -C "$REPO" mv "$fragment" "$(dirname "$fragment")/${frag_base/#0000./$pr_num.}"
        git -C "$REPO" commit -m "docs: release note fragment for #$pr_num"
        git -C "$REPO" push origin "refs/heads/$branch:refs/heads/$branch"
    fi
```

Note the `docs($pkg):` subject also loses `$pkg`, which has not existed since Plan 1.

- [ ] **Step 7: Update the one `render_draft frag` caller**

`lib/tier2.sh`, in `tier2_apply`, the fragment block. Task 9 rewrites this function wholesale; for now just pass the theme's kind so this commit is green:

```bash
        local frag_kind fragment
        frag_kind="$(ns_jac parse_result field fragment_kind < "$theme_file")"
        fragment="$(ns_jac render_draft frag "$LOG_DIR/report-$slug.json" "$frag_kind")"
```

- [ ] **Step 8: Run everything and commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add scripts/nslib.jac scripts/check_scope.jac scripts/render_draft.jac lib/promote.sh lib/tier2.sh
git commit -m "Consume fragment_kind instead of hardcoding refactor in three places

Nothing set fragment_kind, so check_scope honoured it while render_draft and
promote.sh hardcoded 'refactor' -- a LATENT COUPLING note at both sites. The
task registry sets it, so it is now consumed end to end.

fragment = \"\" (coverage) means the task writes no fragment at all, and
fragment_path returns \"\" for it rather than clamping to refactor. fragment =
\"auto\" (maintenance) means the agent picks a kind, the harness validates it,
and the scope gate allows all five legal names since the directory and the 0000
stem are fixed either way.

The promote-time rename now replaces only the leading '0000.', so it works for
every kind, and dies loudly if the placeholder is missing rather than shipping
an unrenamed fragment."
```

---

### Task 6: `protect_unless` — the security-critical piece

The coverage task may write inside `tests/**`. Nothing else may, and no theme may grant itself the permission.

**Files:**
- Modify: `scripts/check_scope.jac` (`protect_unless` reader, `violations` signature, `check` argv)
- Modify: `lib/common.sh` (`ns_task_of_branch`)
- Modify: `lib/verify.sh` (pass the task into the gate)
- Modify: `bin/test-harness.sh` (section 12)

**Interfaces:**
- Produces: `jac run scripts/check_scope.jac check <theme.json> <config.toml> <task>` — exit 1 with `VIOLATION <path> <reason>` lines. Exemptions come from `[tasks.<task>].protect_unless` in the config; an unknown task is fatal.
- Produces: `ns_task_of_branch <branch>` in `lib/common.sh` — prints the task, returns 1 when the slug matches no declared task.
- Consumed by: `lib/verify.sh`, `lib/promote.sh` (through `verify_branch`).

- [ ] **Step 1: Write the failing security tests in `scripts/check_scope.jac`**

```jac
test "protect_unless: coverage may write tests, dead-code may not, and the THEME cannot decide" {
    globs: list[str] = ["**/tests/**", "**/*.test.jac"];
    cov: list[str] = protect_unless("config/nightshift.toml", "coverage");
    dead: list[str] = protect_unless("config/nightshift.toml", "dead-code");
    assert cov == ["**/tests/**", "**/*.test.jac"];
    assert dead == [];

    # THE ATTACK. The theme is assembled from agent-authored findings, so it claims whatever the
    # audit put in it -- here, that it is a coverage theme with its own exemption. The gate reads
    # NEITHER: the exemption comes from the config keyed by the task argv, which the harness
    # derived from the branch name it built itself.
    hostile: dict = {"files": ["jac/tests/test_x.jac"], "task": "coverage",
                     "protect_unless": ["**/tests/**"], "fragment_kind": "refactor"};
    changed: list[tuple[str, str]] = [("M", "jac/tests/test_x.jac")];
    assert len(violations(changed, hostile, globs, dead)) == 1;      # gated as dead-code: rejected
    assert violations(changed, hostile, globs, cov) == [];           # gated as coverage: allowed
}

test "a task WITH protect_unless may write nothing else -- coverage is tests-only" {
    globs: list[str] = ["**/tests/**", "**/*.test.jac"];
    cov: list[str] = ["**/tests/**", "**/*.test.jac"];
    # The source file with the gap is in `files` so the agent can read it. Writing it is still a
    # violation: [tasks.coverage].fragment = "" says this task's output is tests, and only tests.
    theme: dict = {"files": ["jac/jaclang/cli/pipe.jac", "jac/tests/cli/test_pipe.jac"],
                   "fragment_kind": ""};
    ok: list[str] = violations([("A", "jac/tests/cli/test_pipe.jac")], theme, globs, cov);
    assert ok == [];
    bad: list[str] = violations([("M", "jac/jaclang/cli/pipe.jac")], theme, globs, cov);
    assert len(bad) == 1;
    assert "tests-only" in bad[0];
}

test "an unknown task is fatal, never an empty exemption list" {
    raised: bool = False;
    try {
        protect_unless("config/nightshift.toml", "coverage-but-evil");
    } except ValueError {
        raised = True;
    }
    assert raised;
}
```

- [ ] **Step 2: Run them and watch them fail**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/check_scope.jac
```

Expected: FAIL — `protect_unless` is not defined.

- [ ] **Step 3: Implement it in `scripts/check_scope.jac`**

Add after the imports (which gain `load_config_toml`, `as_dict`):

```jac
"""Per-task write exemptions, read from the CONFIG FILE by task name.

THIS IS THE SECURITY BOUNDARY. The theme JSON is assembled from agent-authored findings, so
anything in it -- including a `task` key or a `protect_unless` list -- is attacker-controlled in
the T1 prompt-injection threat model this gate exists to backstop. The task name arrives as an
ARGV from bash, derived from the branch name the harness itself built (lib/common.sh
ns_task_of_branch), and the permission is looked up here, in this process, from the file on disk.
An audit session therefore cannot widen its own write scope by asking for it.

Presence of the key also means "and nothing else": a task that is allowed inside a protected glob
is allowed ONLY there. [tasks.coverage].fragment = "" says the same thing from the other side --
its output is tests, so it needs no release note."""
def protect_unless(config_path: str, task: str) -> list[str] {
    tasks: dict = as_dict(load_config_toml(config_path).get("tasks", {}));
    if task not in tasks {
        raise ValueError("unknown task: " + task);
    }
    return [str(g) for g in as_list(as_dict(tasks[task]).get("protect_unless", []))];
}
```

Then the `violations` signature and its protected-path arm:

```jac
def violations(changed: list[tuple[str, str]], theme: dict, globs: list[str],
               unless: list[str]) -> list[str] {
```

```jac
        if path not in allowed {
            out.append("VIOLATION " + path + " not-in-theme-allowlist");
        } elif unless and not is_protected(path, unless) {
            # A task with an exemption writes ONLY inside it.
            out.append("VIOLATION " + path + " task-writes-tests-only");
        } elif is_protected(path, globs) and not is_protected(path, unless) {
            out.append("VIOLATION " + path + " protected-glob");
        }
```

And the `check` dispatch takes a fourth argv:

```jac
    if len(args) == 5 and args[1] == "check" {
        with open(args[2], "r") as f {
            theme: dict = parse_obj(f.read());
        }
        changed: list[tuple[str, str]] = parse_name_status(read_stdin());
        found: list[str] = violations(changed, theme, load_globs(args[3]),
                                      protect_unless(args[3], args[4]));
```

Update the usage line and add `unless=[]` to the three pre-existing tests' `violations` calls.

- [ ] **Step 4: Run the tests to green**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/check_scope.jac
```

Expected: PASS, all tests.

- [ ] **Step 5: Add `ns_task_of_branch` to `lib/common.sh`**

Insert after `ns_is_tier1_branch` (line 28):

```bash
# The task a branch belongs to, derived from the branch NAME the harness built:
# nightshift/<date>/<task>-<theme-hint>. NEVER from the theme file -- the theme is assembled from
# agent-authored findings, and if the gate read the task from there, a dead-code audit could ask
# for the coverage task's tests/** write exemption and be given it.
#
# Prints the task and returns 0, or returns 1 having printed nothing. Callers MUST treat rc=1 as
# fatal, never as "no task": an unresolved task means no permission set can be applied at all.
# A failure inside `tasks list` also lands here as rc=1 (the loop iterates zero times), which is
# the safe direction -- the discarded-reader bug this codebase keeps finding fails CLOSED here.
ns_task_of_branch() {
    local slug task
    slug="$(basename "$1")"
    for task in $(ns_jac tasks list "$CONFIG"); do
        case "$slug" in
            "$task"-*) printf '%s\n' "$task"; return 0 ;;
        esac
    done
    return 1
}
```

- [ ] **Step 6: Wire it into `lib/verify.sh`**

In `verify_branch`, stage 1, replace the containment block:

```bash
    # 1. scope containment FIRST — reject before spending a second on tests (anti-injection, T1).
    # --name-status (not --name-only): a vestigial test deletion must be a clean delete, never a
    # modification -- the gate needs to see which each changed path actually is.
    # The TASK comes from the branch name, not the theme: [tasks.<task>].protect_unless decides
    # whether this branch may write inside a protected glob, and the theme is agent-derived.
    if [ "$theme" != "-" ]; then
        local btask
        btask="$(ns_task_of_branch "$branch")" || ns_die "$EX_BUG" "cannot derive a task from branch '$branch': its slug matches no name in [tasks.*]. Refusing to gate it -- with no task there is no permission set to apply, and defaulting to one would either reject every coverage branch or hand every branch the coverage exemption."
        if ! git diff --name-status "$NS_REPO_DEFAULT_BRANCH...HEAD" \
                | ns_jac check_scope check "$theme" "$CONFIG" "$btask" > "$LOG_DIR/scope-violations.txt"; then
            verify_red "$branch" "scope violation (possible prompt injection): $(head -3 "$LOG_DIR/scope-violations.txt" | tr '\n' ' ')"
            return 1
        fi
    fi
```

- [ ] **Step 7: Add the security section to `bin/test-harness.sh`**

Append before the final echo:

```bash
echo "== 12. protect_unless: a theme cannot grant itself a write exemption =="
# THE security-critical case in this plan. Driven through the REAL CLI with the REAL config, not
# through the Jac unit tests alone: what matters is that the argv the gate is called with wins over
# anything the theme says, and only the CLI path proves the argv is even threaded through.
rm -rf .jac
S="$T/scope"; mkdir -p "$S"
# A hostile theme: it claims to be a coverage theme and carries its own exemption list.
printf '{"files":["jac/tests/test_x.jac"],"task":"coverage","protect_unless":["**/tests/**"],"fragment_kind":"refactor"}' \
    > "$S/hostile.json"
if printf 'M\tjac/tests/test_x.jac\n' \
    | jac run scripts/check_scope.jac check "$S/hostile.json" config/nightshift.toml dead-code >/dev/null; then
    fail "a dead-code branch was allowed to write tests/** because the THEME claimed to be coverage"
fi
# ...and the same diff under the coverage task must be ALLOWED, or the assertion above would pass
# for a gate that simply rejects everything.
printf '{"files":["jac/tests/test_x.jac"],"fragment_kind":""}' > "$S/cov.json"
printf 'M\tjac/tests/test_x.jac\n' \
    | jac run scripts/check_scope.jac check "$S/cov.json" config/nightshift.toml coverage >/dev/null \
    || fail "the coverage task cannot write tests/** -- protect_unless is not being applied at all"
# tests-only: a coverage branch touching a source file in its OWN allow-list is still rejected.
printf '{"files":["jac/jaclang/cli/pipe.jac","jac/tests/test_x.jac"],"fragment_kind":""}' > "$S/cov2.json"
if printf 'M\tjac/jaclang/cli/pipe.jac\n' \
    | jac run scripts/check_scope.jac check "$S/cov2.json" config/nightshift.toml coverage >/dev/null; then
    fail "a coverage branch modified a source file; the task is tests-only"
fi
# an unknown task must be FATAL, not an empty exemption list
if printf 'M\tjac/tests/test_x.jac\n' \
    | jac run scripts/check_scope.jac check "$S/cov.json" config/nightshift.toml not-a-task >/dev/null 2>&1; then
    fail "an unknown task was gated anyway; it must fail closed"
fi
rm -rf .jac

# ns_task_of_branch drives the whole thing, so mutate it too: the task must come from the BRANCH.
( . "$NS_ROOT/lib/common.sh"; ns_bootstrap_jac
  got="$(ns_task_of_branch nightshift/2026-07-30/coverage-cli-error-paths)" || exit 1
  [ "$got" = coverage ] || { echo "got '$got'" >&2; exit 1; }
  got="$(ns_task_of_branch nightshift/2026-07-30/dead-code-unused-imports)" || exit 1
  [ "$got" = dead-code ] || { echo "got '$got'" >&2; exit 1; }
  if ns_task_of_branch nightshift/2026-07-30/autofix >/dev/null 2>&1; then
      echo "a tier-1 branch resolved to a task; it has none" >&2; exit 1
  fi
) || fail "ns_task_of_branch does not resolve the task from the branch slug"
echo "protect_unless is config-keyed by an argv task: a theme cannot grant itself tests/** access"
```

- [ ] **Step 8: Run the harness suite and commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add scripts/check_scope.jac lib/common.sh lib/verify.sh bin/test-harness.sh
git commit -m "Gate per-task write exemptions on the config, keyed by an argv task

The coverage task may write inside tests/**. Nothing else may, and no theme may
grant itself the permission: the theme JSON is assembled from agent-authored
findings, so a task name or a protect_unless list inside it is attacker-
controlled under the T1 injection model this gate backstops. The exemption is
read from config/nightshift.toml by task name, and the task name arrives as an
argv derived from the branch name the harness itself built.

Presence of protect_unless also means 'and nothing else': a coverage branch that
modifies a source file in its own allow-list is rejected as tests-only.

The harness drives all four cases through the real CLI -- hostile theme
rejected, legitimate coverage allowed, source write rejected, unknown task
fatal. The second case is what stops the first from passing for a gate that
simply rejects everything."
```

---

### Task 7: The test-weakening guard

Coverage may modify an existing test file. It must never weaken one, and "delete the assertion that fails" is the obvious way this task goes wrong while gating green.

**Files:**
- Modify: `scripts/check_scope.jac` (`test_strength`, `weakened`, the `weakened` verb)
- Modify: `lib/verify.sh` (stage 1b)
- Modify: `bin/test-harness.sh` (section 13)

**Interfaces:**
- Produces: `jac run scripts/check_scope.jac weakened <path> <old_file> <new_file>` — exit 1 and one `VIOLATION` line when the new content has fewer asserts or fewer test blocks than the old; exit 0 otherwise, printing `SKIP <path> no test blocks on <default-branch>` when the old side is not a test file.
- Consumed by: `lib/verify.sh`.

- [ ] **Step 1: Write the failing tests in `scripts/check_scope.jac`**

```jac
test "test_strength counts asserts and test blocks, and ignores prose" {
    src: str = "test \"a\" {\n    assert x == 1;\n    assert(y);\n}\n# assertion in a comment\ntest \"b\" {\n    assert z;\n}\n";
    (a, t) = test_strength(src);
    assert a == 3;
    assert t == 2;
}

test "weakened fires on EITHER dimension, independently" {
    old: str = "test \"a\" {\n    assert x;\n    assert y;\n}\ntest \"b\" {\n    assert z;\n}\n";
    # fewer asserts, same number of tests
    fewer_asserts: str = "test \"a\" {\n    assert x;\n}\ntest \"b\" {\n    assert z;\n}\n";
    assert len(weakened("t.jac", old, fewer_asserts)) == 1;
    # same number of asserts, one fewer test block
    fewer_tests: str = "test \"a\" {\n    assert x;\n    assert y;\n    assert z;\n}\n";
    assert len(weakened("t.jac", old, fewer_tests)) == 1;
    # strictly more of both is the whole point of the coverage task
    stronger: str = old + "test \"c\" {\n    assert w;\n}\n";
    assert weakened("t.jac", old, stronger) == [];
    # unchanged is fine
    assert weakened("t.jac", old, old) == [];
}

test "a file that was never a test file cannot be weakened" {
    src: str = "def f(x: int) -> int {\n    return x;\n}\n";
    assert weakened("f.jac", src, "def f(x: int) -> int {\n    return 0;\n}\n") == [];
}
```

- [ ] **Step 2: Run them and watch them fail**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/check_scope.jac
```

Expected: FAIL — `test_strength` undefined.

- [ ] **Step 3: Implement it**

Add `import re;` at the top of `scripts/check_scope.jac`, then:

```jac
"""Assert count and test-block count for one file's contents.

ponytail: token counting, not semantics. "Is this test weaker" is a semantic question, and the
failure mode actually being defended against -- delete the assertion that fails, keep the suite
green -- moves both counters. The word boundary keeps `assertion` in a comment from counting; a
string literal containing the word still would, and that false POSITIVE is the safe direction.
Upgrade path: compare `jac test` collected item ids before and after, which also catches a test
renamed out of existence while the counts stay equal."""
def test_strength(text: str) -> (int, int) {
    asserts: int = len(re.findall("(?:^|[^\\w])assert(?![\\w])", text));
    tests: int = len(re.findall("(?m)^\\s*test\\s", text));
    return (asserts, tests);
}

"""The coverage task MAY modify an existing test file. It may never weaken one. Returns one
VIOLATION per reduced dimension. A file with no test blocks on the default branch has no strength
to lose, so it returns nothing -- correct rather than vacuous, since the caller only ever hands
this MODIFIED files and logs how many it compared."""
def weakened(path: str, old_text: str, new_text: str) -> list[str] {
    (old_a, old_t) = test_strength(old_text);
    if old_t == 0 {
        return [];
    }
    (new_a, new_t) = test_strength(new_text);
    out: list[str] = [];
    if new_a < old_a {
        out.append("VIOLATION " + path + " assert-count-reduced-" + str(old_a) + "-to-" + str(new_a));
    }
    if new_t < old_t {
        out.append("VIOLATION " + path + " test-count-reduced-" + str(old_t) + "-to-" + str(new_t));
    }
    return out;
}
```

Dispatch, before the usage arm:

```jac
    } elif len(args) == 5 and args[1] == "weakened" {
        with open(args[3], "r") as fo {
            old_text: str = fo.read();
        }
        with open(args[4], "r") as fn {
            new_text: str = fn.read();
        }
        found2: list[str] = weakened(args[2], old_text, new_text);
        for v in found2 {
            print(v);
        }
        if not found2 {
            (chk_a, chk_t) = test_strength(old_text);
            if chk_t == 0 {
                print("SKIP " + args[2] + " no test blocks on the default branch");
            } else {
                print("OK " + args[2] + " " + str(chk_a) + " asserts / " + str(chk_t) + " tests preserved");
            }
        }
        sys.exit(1 if found2 else 0);
```

Add the verb to the usage lines and the module docstring.

- [ ] **Step 4: Run the tests to green**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/check_scope.jac
```

Expected: PASS.

- [ ] **Step 5: Add stage 1b to `lib/verify.sh`**

Immediately after the scope-containment block, inside the same `if [ "$theme" != "-" ]`:

```bash
        # 1b. TEST-WEAKENING guard. The coverage task may modify an existing test file; weakening
        #     one is how this task fails while gating green, so it is checked before anything
        #     expensive. Applied to EVERY task, not just coverage: the cheapest way for any theme
        #     to turn a red suite green is to delete the assertion.
        local tw_files tw_rc=0 tw_checked=0 tw_f tw_old
        tw_files="$(git diff --name-status "$NS_REPO_DEFAULT_BRANCH...HEAD" | awk '$1 == "M" { print $2 }')" || tw_rc=$?
        case "$tw_rc" in
            0) : ;;
            *) ns_die "$EX_BUG" "could not list modified files for the test-weakening guard (rc=$tw_rc). An empty list here is indistinguishable from 'this branch modified nothing', which is exactly how a weakened test would sail through." ;;
        esac
        : > "$LOG_DIR/test-weakening.txt"
        # word-split is deliberate; repo paths contain no spaces (same assumption as the shard
        # findings list in lib/tier2.sh, and a violation of it fails loudly on the git show below)
        for tw_f in $tw_files; do
            git -C "$REPO" cat-file -e "$NS_REPO_DEFAULT_BRANCH:$tw_f" 2>/dev/null || continue
            tw_old="$LOG_DIR/tw-old-$(printf '%s' "$tw_f" | tr / _)"
            git -C "$REPO" show "$NS_REPO_DEFAULT_BRANCH:$tw_f" > "$tw_old" \
                || ns_die "$EX_BUG" "git show $NS_REPO_DEFAULT_BRANCH:$tw_f failed; the test-weakening guard cannot compare what it cannot read, and skipping it silently is how a weakened test ships."
            if ! ns_jac check_scope weakened "$tw_f" "$tw_old" "$REPO/$tw_f" >> "$LOG_DIR/test-weakening.txt"; then
                verify_red "$branch" "test weakened: $(grep VIOLATION "$LOG_DIR/test-weakening.txt" | head -2 | tr '\n' ' ')"
                return 1
            fi
            tw_checked=$((tw_checked + 1))
        done
        ns_log S4 "test-weakening guard: compared $tw_checked modified file(s) against $NS_REPO_DEFAULT_BRANCH"
```

- [ ] **Step 6: Add section 13 to `bin/test-harness.sh`**

```bash
echo "== 13. test-weakening guard: both dimensions, driven through the real CLI =="
rm -rf .jac
W="$T/weaken"; mkdir -p "$W"
cat > "$W/old.jac" <<'EOF'
test "a" {
    assert x == 1;
    assert y == 2;
}
test "b" {
    assert z;
}
EOF
cat > "$W/fewer-asserts.jac" <<'EOF'
test "a" {
    assert x == 1;
}
test "b" {
    assert z;
}
EOF
cat > "$W/fewer-tests.jac" <<'EOF'
test "a" {
    assert x == 1;
    assert y == 2;
    assert z;
}
EOF
cat > "$W/stronger.jac" <<'EOF'
test "a" {
    assert x == 1;
    assert y == 2;
}
test "b" {
    assert z;
    assert z2;
}
test "c" {
    assert w;
}
EOF
printf 'def f(x: int) -> int {\n    return x;\n}\n' > "$W/notatest.jac"
# Each dimension INDEPENDENTLY: an implementation that only counts asserts passes the first case
# and fails the second, and vice versa. An always-reject implementation fails the fourth.
if jac run scripts/check_scope.jac weakened t.jac "$W/old.jac" "$W/fewer-asserts.jac" >/dev/null; then
    fail "guard accepted a diff that deleted an assert"
fi
if jac run scripts/check_scope.jac weakened t.jac "$W/old.jac" "$W/fewer-tests.jac" >/dev/null; then
    fail "guard accepted a diff that deleted a whole test block while keeping the assert count"
fi
jac run scripts/check_scope.jac weakened t.jac "$W/old.jac" "$W/stronger.jac" >/dev/null \
    || fail "guard rejected a diff that STRENGTHENED the tests; the coverage task could never ship"
jac run scripts/check_scope.jac weakened f.jac "$W/notatest.jac" "$W/notatest.jac" > "$W/out.txt" \
    || fail "guard rejected a non-test file"
# ...and it must say WHICH of the two it did, so a night's log can never claim a comparison that
# did not happen. This is the positive assertion, not the absence of a VIOLATION line.
grep -q '^SKIP f.jac' "$W/out.txt" || fail "guard did not report that it skipped a non-test file"
jac run scripts/check_scope.jac weakened t.jac "$W/old.jac" "$W/stronger.jac" > "$W/out2.txt"
grep -q '^OK t.jac 3 asserts / 2 tests preserved' "$W/out2.txt" \
    || fail "guard did not report the strength it actually compared: $(cat "$W/out2.txt")"
rm -rf .jac
echo "test-weakening guard fires on assert count and test count independently"
```

- [ ] **Step 7: Prove it on a real branch**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo
git checkout -B nightshift/probe/coverage-weaken main
f="$(git ls-files 'jac/tests/**/*.jac' | head -1)"; echo "$f"
perl -0pi -e 's/assert[^\n]*\n//' "$f"
git commit -aqm "probe: delete asserts from an existing test"
cd /Volumes/ExtremePro/JaseciLabs/NightShift
printf '{"files":["%s"],"fragment_kind":""}' "$f" > /tmp/probe-theme.json
NS_ROOT="$PWD" bash -c '. lib/common.sh; ns_load_config; . lib/cimirror.sh; . lib/verify.sh
  LOG_DIR="/tmp/ns-tw"; mkdir -p "$LOG_DIR"; date +%s > "$LOG_DIR/start_epoch"
  verify_branch nightshift/probe/coverage-weaken /tmp/probe-theme.json; echo "rc=$?"'
grep VIOLATION /tmp/ns-tw/test-weakening.txt
```

Expected: `rc=1`, a `VIOLATION ... assert-count-reduced-N-to-M` line, and the rejection logged before any test suite runs. Then clean up:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo \
  && git checkout -f main && git branch -D nightshift/probe/coverage-weaken
```

- [ ] **Step 8: Run the harness suite and commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add scripts/check_scope.jac lib/verify.sh bin/test-harness.sh
git commit -m "Reject any diff that weakens an existing test file

The coverage task may modify an existing test; weakening one is how this task
fails while gating green, and 'delete the failing assertion' is the cheapest
way for ANY theme to turn a red suite green, so the guard applies to all four.

Assert count and test-block count are checked independently, so an
implementation that watches only one dimension fails the harness. The guard
also PRINTS what it compared (OK <n> asserts / <n> tests preserved, or SKIP for
a non-test file) rather than staying silent on success: a night's log must never
be able to claim a comparison that did not happen. A git failure while reading
the default-branch copy is fatal, not a skip."
```

---

### Task 8: `scripts/covmap.jac` — coverage evidence, Phase A

The coverage audit needs evidence, not vibes. `jac code map` enumerates the repo's archetypes in ~3s warm; subtract every identifier that appears under a test tree and rank what is left.

**Files:**
- Create: `scripts/covmap.jac`
- Modify: `scripts/shards.jac` (expose `shard_paths`)
- Modify: `bin/test-harness.sh:13` (register `covmap`)

**Interfaces:**
- Produces: `jac run scripts/covmap.jac rank <repo_dir> <jac_repo_bin>` — a JSON array of `{symbol, kind, file, line, weight}`, ranked by `weight` descending, of public archetypes under `jac/jaclang/**` whose name appears nowhere in the test tree.
- Produces: `jac run scripts/covmap.jac top <covmap.json> <shard> <config.toml> <limit>` — markdown evidence lines for one shard's paths.
- Produces: `shard_paths(cfg: dict, name: str) -> list[str]` in `shards.jac`.
- Consumed by: `lib/tier2.sh` (Task 9), `prompts/audit-coverage.md`'s `{coverage_evidence}`.

- [ ] **Step 1: Extract `shard_paths` in `scripts/shards.jac`**

Replace the first two lines of `shard_scope` with a call, so covmap and the prompt cannot disagree about a shard's extent:

```jac
def shard_paths(cfg: dict, name: str) -> list[str] {
    shards: dict = as_dict(cfg["shards"]);
    paths_table: dict = as_dict(shards["paths"]);
    return [str(p) for p in as_list(paths_table[name])];
}

def shard_scope(cfg: dict, name: str) -> str {
    shards: dict = as_dict(cfg["shards"]);
    paths: list[str] = shard_paths(cfg, name);
    excl_table: dict = as_dict(shards.get("exclude", {}));
    ...
```

- [ ] **Step 2: Confirm what `jac code map` actually returns**

Do not write the parser against a guess:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo/jac
time ./zig-out/bin/jac code map > /tmp/codemap.json 2>/tmp/codemap.err
head -c 200 /tmp/codemap.json; echo; head -2 /tmp/codemap.err
jac run /dev/stdin <<'EOF' 2>/dev/null || python3 - <<'PY'
PY
EOF
```

Expected, verified on 2026-07-30: exit 0 in ~3.2s warm (the first run after a fresh `.jac` compiles the compiler and takes minutes), stdout is pure JSON starting `{"schema_version": 1, "command": "map"`, the `🛠 jac dev mode` banner goes to **stderr**, and `archetypes` holds 3348 entries (`obj` 1992, `class` 489, `walker` 431, `node` 330, `edge` 106) with absolute `file` paths, 1652 of them under `jac/jaclang`. Note what is **not** there: module-level `def`s. The map reports archetypes and their abilities only.

- [ ] **Step 3: Write `scripts/covmap.jac`**

```jac
"""Coverage evidence, Phase A (design spec 11).

Enumerate the repo's public archetypes with `jac code map`, subtract every identifier that appears
anywhere under a test tree, and rank what is left. The coverage audit prompt consumes this as
EVIDENCE. It is a proxy for coverage, not line coverage.

ponytail: NAME-BASED resolution, deliberately. A symbol whose name merely appears in a test's
string literal or comment counts as referenced (a false "tested"), and two same-named symbols in
different modules share one verdict. That is the right trade at ~3s for the whole repo, and the
audit is told to verify before reporting. Upgrade path: `jac code uses <symbol>` is def/use-precise
and perfectly affordable once this list has narrowed the candidates to a few dozen.

Known ceiling, stated because the obvious reading is wrong: `jac code map` reports ARCHETYPES
(obj/class/node/edge/walker) and their abilities. A module-level `def` with no tests is invisible
here. Upgrade path: the same subtraction over `jac code symbol` output per file.

Phase B -- real line coverage as a compiler pass -- is explicitly NOT this and has its own spec.

argv:
  rank <repo_dir> <jac_repo_bin>                    print the ranked untested-symbol JSON array
  top  <covmap.json> <shard> <config.toml> <limit>  markdown evidence lines for one shard
"""
import sys;
import os;
import re;
import json;
import subprocess;
import from nslib { eprint, parse_obj, as_dict, as_list, load_config_toml }
import from shards { shard_paths }

glob SKIP_MARKERS: list[str] = ["/tests/", "/fixtures/", "/examples/"];

"""Every identifier appearing anywhere under a test tree. One pass over the test corpus, not one
subprocess per symbol: `jac code uses` per candidate would be ~1600 compiler invocations."""
def test_identifiers(repo_dir: str) -> set[str] {
    ids: set[str] = set();
    for (root, dirs, files) in os.walk(repo_dir + "/jac") {
        if "/tests" not in root and not root.endswith("/tests") {
            continue;
        }
        for name in files {
            if not str(name).endswith(".jac") {
                continue;
            }
            try {
                with open(os.path.join(root, name), "r") as f {
                    for tok in re.findall("[A-Za-z_][A-Za-z0-9_]*", f.read()) {
                        ids.add(str(tok));
                    }
                }
            } except Exception {
                continue;                  # an unreadable test file must not kill the night
            }
        }
    }
    return ids;
}

def ability_name(sig: str) -> str {
    return str(sig).split("(")[0].strip();
}

"""Public archetypes under jac/jaclang whose name appears nowhere in the test corpus, ranked by a
size proxy (fields + abilities): the more surface a type has, the more behaviour is unprotected.
`weight` orders the EVIDENCE; the audit assigns each finding its own gap_severity in LOC."""
def rank(repo_dir: str, jac_bin: str) -> list[dict] {
    # check=True on purpose. A failed `jac code map` must NOT come back as an empty evidence list
    # that reads exactly like "everything is tested" -- that is the did-not-run-scored-as-passed
    # shape this project keeps finding.
    proc = subprocess.run([jac_bin, "code", "map"], cwd=repo_dir + "/jac",
                          capture_output=True, text=True, check=True);
    data: dict = parse_obj(proc.stdout);
    tested: set[str] = test_identifiers(repo_dir);
    prefix: str = repo_dir + "/";
    out: list[dict] = [];
    for a in as_list(data["archetypes"]) {
        arch: dict = as_dict(a);
        name: str = str(arch["name"]);
        path: str = str(arch["file"]);
        rel: str = path[len(prefix):] if path.startswith(prefix) else path;
        if not rel.startswith("jac/jaclang/") or name.startswith("_") {
            continue;
        }
        skip: bool = False;
        for marker in SKIP_MARKERS {
            if marker in rel {
                skip = True;
            }
        }
        if skip or name in tested {
            continue;
        }
        members: list[str] = [str(x) for x in as_list(arch.get("fields", []))]
                             + [ability_name(x) for x in as_list(arch.get("abilities", []))];
        out.append({"symbol": name, "kind": str(arch["kind"]), "file": rel,
                    "line": int(arch.get("line", 0)), "weight": len(members)});
    }
    out.sort(key=lambda d: dict -> tuple { return (-int(d["weight"]), str(d["symbol"])); });
    return out;
}

def top_lines(entries: list[dict], paths: list[str], limit: int) -> list[str] {
    out: list[str] = [];
    for e in entries {
        for p in paths {
            if str(e["file"]).startswith(p) and len(out) < limit {
                out.append("- `" + str(e["symbol"]) + "` (" + str(e["kind"]) + ", "
                           + str(e["file"]) + ":" + str(e["line"]) + ") - "
                           + str(e["weight"]) + " members, no test-tree reference");
                break;
            }
        }
    }
    return out;
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "rank" and len(args) == 4 {
        print(json.dumps(rank(args[2], args[3])));
    } elif cmd == "top" and len(args) == 6 {
        with open(args[2], "r") as f {
            entries: list[dict] = [as_dict(e) for e in json.loads(f.read())];
        }
        paths: list[str] = shard_paths(load_config_toml(args[4]), args[3]);
        lines: list[str] = top_lines(entries, paths, int(args[5]));
        if not lines {
            print("(no untested public archetypes resolved in this shard)");
        }
        for line in lines {
            print(line);
        }
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run covmap.jac rank <repo_dir> <jac_repo_bin>");
        eprint("       jac run covmap.jac top <covmap.json> <shard> <config.toml> <limit>");
    }
}

test "test_identifiers reads only the test tree" {
    import tempfile;
    import os as _os;
    repo: str = tempfile.mkdtemp();
    _os.makedirs(repo + "/jac/jaclang/cli");
    _os.makedirs(repo + "/jac/tests/cli");
    with open(repo + "/jac/jaclang/cli/pipe.jac", "w") as f {
        f.write("obj OnlyInSource {}\n");
    }
    with open(repo + "/jac/tests/cli/test_pipe.jac", "w") as f {
        f.write("import from jaclang.cli.pipe { Referenced }\ntest \"x\" { assert Referenced; }\n");
    }
    ids: set[str] = test_identifiers(repo);
    assert "Referenced" in ids;
    assert "OnlyInSource" not in ids;
}

test "top_lines filters to the shard's paths and honours the limit" {
    entries: list[dict] = [
        {"symbol": "A", "kind": "obj", "file": "jac/jaclang/cli/a.jac", "line": 3, "weight": 9},
        {"symbol": "B", "kind": "walker", "file": "jac/jaclang/scale/b.jac", "line": 5, "weight": 8},
        {"symbol": "C", "kind": "obj", "file": "jac/jaclang/cli/c.jac", "line": 7, "weight": 7},
    ];
    lines: list[str] = top_lines(entries, ["jac/jaclang/cli"], 5);
    assert len(lines) == 2;
    assert "`A`" in lines[0] and "jac/jaclang/cli/a.jac:3" in lines[0];
    assert len(top_lines(entries, ["jac/jaclang/cli"], 1)) == 1;
    assert top_lines(entries, ["jac/jaclang/byllm"], 5) == [];
}
```

- [ ] **Step 4: Run the unit tests**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac \
  && jac test scripts/shards.jac && jac test scripts/covmap.jac
```

Expected: PASS in both. Neither test invokes the repo binary — `rank` is exercised for real in the next step, because a unit test that stubs `jac code map` would only prove the stub.

- [ ] **Step 5: Run `rank` against the real repo and sanity-check the result**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
time jac run scripts/covmap.jac rank "$PWD/work/repo" "$PWD/work/repo/jac/zig-out/bin/jac" > /tmp/covmap.json
jac run scripts/parse_result.jac len < /tmp/covmap.json
head -c 400 /tmp/covmap.json
jac run scripts/covmap.jac top /tmp/covmap.json cli config/nightshift.toml 10
```

Expected: a few seconds, a count comfortably below the 1652 archetypes under `jac/jaclang` (a count EQUAL to it means the test-identifier subtraction is not running at all — investigate before trusting it), entries sorted by `weight` descending, and up to 10 markdown lines all under `jac/jaclang/cli`.

- [ ] **Step 6: Confirm a failed `jac code map` is loud, not empty**

The whole point of `check=True`:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
jac run scripts/covmap.jac rank "$PWD/work/repo" /nonexistent/jac > /tmp/covmap-fail.json; echo "rc=$?"
wc -c /tmp/covmap-fail.json
```

Expected: nonzero rc and a 0-byte output — not `[]`. An empty JSON array here would read to every downstream consumer as "nothing is untested".

- [ ] **Step 7: Register and commit**

Add `covmap` to the sweep list at `bin/test-harness.sh:13`, then:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add scripts/covmap.jac scripts/shards.jac bin/test-harness.sh
git commit -m "Add covmap: static untested-symbol evidence for the coverage audit

jac code map enumerates the repo's archetypes in ~3s warm; subtracting every
identifier that appears under a test tree leaves a ranked list of public
symbols with no test reference, which the coverage audit consumes as evidence.

Name-based resolution is the deliberate ceiling: a symbol named in a test's
string literal counts as referenced, and same-named symbols in different modules
share one verdict. Upgrade path is jac code uses, which is def/use-precise and
affordable once this list has narrowed the candidates. jac code map also does
not enumerate module-level defs, which is written down rather than discovered
later. Phase B (real line coverage as a compiler pass) is a separate spec.

subprocess runs with check=True: a failed map must not come back as an empty
array that reads exactly like 'everything is tested'."
```

---

### Task 9: Wire the night — per-task prompts, carry-over, and one-way model escalation

`lib/tier2.sh` currently runs one hardcoded pass. This is the task that makes the registry real.

**Files:**
- Modify: `lib/tier2.sh` (`tier2_main`, `tier2_audit_shard`, `tier2_audit_all`, `tier2_select`, `tier2_apply`, new `ns_attempt_model`)
- Modify: `bin/test-harness.sh` (section 14)

**Interfaces:**
- Consumes: `tasks.jac next|env|list`, `covmap.jac rank|top`, `parse_result findings <task> <scoring>`, `selector select` (returning `carryover`), `check_scope check <theme> <config> <task>`.
- Produces: `ns_attempt_model <attempt> <complexity>` in `lib/tier2.sh` — the model for one apply attempt. Attempt 1 routes on complexity; every later attempt is `$NS_AGENT_MODEL`. Escalation is one-way by construction.
- Produces: `state/carryover.json` — the findings deferred by tonight's selection, merged ahead of tomorrow's.

- [ ] **Step 1: Add the model router to `lib/tier2.sh`**

Insert after `render_prompt`:

```bash
# Which model executes one apply attempt (design spec 13).
#
# Attempt 1 routes on the theme's complexity: trivial/mechanical go to the cheap model, judgement
# to the expensive one. Every later attempt is $NS_AGENT_MODEL, unconditionally -- ESCALATION IS
# ONE-WAY. A judgement theme that failed on Opus is never retried on Sonnet in the hope of a
# different answer, and a Sonnet theme that failed gets exactly one Opus attempt.
#
# `case`, not `[ ] && ...`: a trailing && list returns nonzero when its test fails, and this
# function is called in a command substitution inside an errexit caller.
ns_attempt_model() {   # ns_attempt_model <attempt> <complexity>
    case "$1" in
        1)
            case "$2" in
                trivial|mechanical) printf '%s\n' "$NS_AGENT_MODEL_SIMPLE" ;;
                *)                  printf '%s\n' "$NS_AGENT_MODEL" ;;
            esac
            ;;
        *) printf '%s\n' "$NS_AGENT_MODEL" ;;
    esac
}
```

- [ ] **Step 2: Select tonight's task in `tier2_main`**

```bash
tier2_main() {
    local remaining; remaining="$(ns_remaining_min)"
    if [ "$remaining" -lt $(( NS_BUDGETS_AUDIT_TIMEOUT_MIN + NS_BUDGETS_APPLY_TIMEOUT_MIN )) ]; then
        ns_warn "no clock left for the agentic tier (${remaining}m remaining) — skipping S3"
        return 0
    fi

    # Tonight's task, and the cycle advances as it is read: a night that dies later must not make
    # every following night repeat the same task. Deferred work carries over on its own.
    local task task_rc=0
    task="$(ns_jac tasks next "$CONFIG" "$STATE")" || task_rc=$?
    if [ "$task_rc" -ne 0 ] || [ -z "$task" ]; then
        ns_die "$EX_BUG" "could not read tonight's task from $CONFIG / $STATE (rc=$task_rc). Every prompt, budget, and write permission is keyed by it; there is no safe default."
    fi
    eval "$(ns_jac tasks env "$task" "$CONFIG")"
    ns_log S3 "tonight's task: $NS_TASK_NAME (ponytail=$NS_TASK_PONYTAIL, scoring=$NS_TASK_SCORING)"

    # Coverage evidence, once for the night, before the fan-out. Only the coverage audit reads it.
    if [ "$NS_TASK_NAME" = coverage ]; then
        if ns_jac covmap rank "$REPO" "$NS_PATHS_JAC_REPO" > "$LOG_DIR/covmap.json"; then
            ns_log S3 "covmap: $(ns_jac parse_result len < "$LOG_DIR/covmap.json") untested public archetypes"
        else
            # No evidence means the audit would be guessing, and an empty evidence block reads to
            # the model exactly like "everything is tested". Skip tonight's fresh coverage audit;
            # carried-over themes below still run, because they need no audit at all.
            ns_fail "audit[coverage]" "covmap failed — no evidence, so no fresh coverage audit tonight"
            rm -f "$LOG_DIR/covmap.json"
        fi
    fi

    tier2_audit_all || ns_log S3 "no fresh findings tonight — carry-over only"
    tier2_select
    tier2_apply
    dataset_record_night
}
```

Note `tier2_audit_all`'s failure no longer returns from `tier2_main`: with carry-over, a night with zero fresh findings still has work to do.

- [ ] **Step 3: Make `tier2_audit_shard` task-aware**

Three changes inside it. The prompt file, the evidence, and the parse:

```bash
tier2_audit_shard() {
    local shard=$1 prompt attempt scope evidence=""
    scope="$(ns_jac shards scope "$shard" "$CONFIG")"
    if [ "$NS_TASK_NAME" = coverage ]; then
        evidence="$(ns_jac covmap top "$LOG_DIR/covmap.json" "$shard" "$CONFIG" 40)"
    fi
    prompt="$(render_prompt "$NS_ROOT/prompts/audit-$NS_TASK_NAME.md" \
        "shard=$shard" "scope=$scope" "coverage_evidence=$evidence" \
        "protect_globs=$NS_PROTECT_GLOBS" "ponytail_mode=$NS_TASK_PONYTAIL")"
```

and both `parse_result findings` invocations (the main one and the corrective re-prompt salvage):

```bash
        if ns_jac parse_result findings "$NS_TASK_NAME" "$NS_TASK_SCORING" < "$LOG_DIR/audit-$shard.json" \
                > "$LOG_DIR/findings-$shard.json" 2> "$LOG_DIR/parse-err-audit-$shard.txt"; then
```

The audit session's `--model` becomes `$NS_AGENT_MODEL` (Opus) unconditionally — replace the `model_args` block:

```bash
    # The audit is always the expensive model: it is judgement work, and a bad finding costs a
    # whole 25-minute apply session downstream (design spec 13).
    local -a model_args=(--model "$NS_AGENT_MODEL")
```

And the coverage audit must be skipped when there is no evidence:

```bash
    if [ "$NS_TASK_NAME" = coverage ] && [ ! -s "$LOG_DIR/covmap.json" ]; then
        ns_log S3 "audit[$shard] skipped: coverage task with no covmap evidence"
        return 1
    fi
```

- [ ] **Step 4: Merge the carry-over into `tier2_select`**

```bash
tier2_select() {
    local carry="$NS_ROOT/state/carryover.json" input="$LOG_DIR/findings.json"

    # Carried themes are packed FIRST the next night (selector.jac sorts on the carry flag), and
    # merging them AHEAD of tonight's findings also makes the carried copy win the (file, rule)
    # dedupe in parse_result merge -- so a re-discovered finding keeps its carry flag.
    if [ -s "$carry" ]; then
        if ns_jac parse_result merge "$carry" "$LOG_DIR/findings.json" > "$LOG_DIR/findings-all.json"; then
            input="$LOG_DIR/findings-all.json"
            ns_log S3 "carry-over: $(ns_jac parse_result len < "$carry") deferred finding(s) packed ahead of tonight's task"
        else
            ns_fail "carry-over" "could not merge $carry — proceeding with tonight's findings only"
        fi
    fi
    [ -s "$input" ] || { ns_log S3 "nothing to select"; return 0; }

    ns_jac selector select "$CONFIG" "$LEDGER" "$STATE" "$(ns_remaining_min)" "$REPO" \
        < "$input" > "$LOG_DIR/selection.json"

    # Tonight's own deferrals become tomorrow's carry-over. Written to a temp file and moved, so a
    # failure here leaves YESTERDAY's carry-over intact rather than truncating it to nothing --
    # the redirect would otherwise have emptied the file before the reader could fail.
    if ns_jac parse_result field carryover < "$LOG_DIR/selection.json" > "$carry.tmp"; then
        mv "$carry.tmp" "$carry"
        ns_log S3 "carry-over for the next night: $(ns_jac parse_result len < "$carry" || echo 0) finding(s)"
    else
        rm -f "$carry.tmp"
        ns_fail "carry-over" "could not extract tonight's carryover set — yesterday's file left untouched"
    fi

    local fp file reason
    ns_jac selector dropped "$LOG_DIR/selection.json" | while IFS=$'\t' read -r fp file reason; do
        case "$reason" in
            over-theme-budget|over-night-budget|no-clock-left)
                printf '{"fingerprint":"%s","file":"%s","rule":"unknown","summary":"deferred by selector","status":"deferred"}\n' "$fp" "$file" \
                    | ns_jac ledger upsert "$LEDGER" >/dev/null ;;
        esac
    done
}
```

- [ ] **Step 5: Make `tier2_apply` per-theme**

Inside the `while read -r slug` loop, before rendering the prompt:

```bash
        # Per-THEME, not per-night: a carried theme belongs to an earlier night's task and keeps
        # its own ponytail mode, its own rules block, and its own fragment kind.
        local theme_task theme_cx
        theme_task="$(ns_jac parse_result field task < "$theme_file")"
        theme_cx="$(ns_jac parse_result field complexity < "$theme_file")"
        if [ -z "$theme_task" ]; then
            ns_fail "theme $slug" "theme carries no task — cannot choose a prompt or a permission set"
            continue
        fi
        eval "$(ns_jac tasks env "$theme_task" "$CONFIG")"

        prompt="$(render_prompt "$NS_ROOT/prompts/apply.md" \
            "theme=$(cat "$theme_file")" "ponytail_mode=$NS_TASK_PONYTAIL" \
            "task_apply_rules=$(cat "$NS_ROOT/prompts/apply-rules-$theme_task.md")")"
```

Then replace the fixed `model_args` with a per-attempt choice inside the retry loop:

```bash
        for attempt in 1 2; do
            local attempt_model
            attempt_model="$(ns_attempt_model "$attempt" "$theme_cx")"
            ns_log S3 "apply $slug attempt $attempt on $attempt_model (complexity=$theme_cx)"
            cd "$REPO"
            ...
                && ns_timebox "$NS_BUDGETS_APPLY_TIMEOUT_MIN" "$NS_PATHS_CLAUDE" -p "$prompt" \
                --model "$attempt_model" \
```

Delete the `local -a model_args=()` declaration and its two `${model_args[@]+...}` expansions in this function — an explicit `--model` per attempt replaces them, and it removes one of the empty-array hazards the constraints warn about.

The branch line needs no change at all: `nightshift/$NS_DATE/$slug` already carries the task, because the slug is `<task>-<theme-hint>`.

- [ ] **Step 6: Add section 14 to `bin/test-harness.sh`**

```bash
echo "== 14. apply model routing: complexity decides attempt 1, escalation is ONE-WAY =="
route() { ( . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/tier2.sh"
            NS_AGENT_MODEL=opus; NS_AGENT_MODEL_SIMPLE=sonnet; ns_attempt_model "$1" "$2" ); }
# attempt 1 routes on complexity
[ "$(route 1 trivial)"    = sonnet ] || fail "trivial did not route to model_simple"
[ "$(route 1 mechanical)" = sonnet ] || fail "mechanical did not route to model_simple"
[ "$(route 1 judgement)"  = opus ]   || fail "judgement did not route to model"
# an unknown or empty complexity fails SAFE to the expensive model
[ "$(route 1 "")"         = opus ]   || fail "an empty complexity must fail safe to model, not model_simple"
[ "$(route 1 wat)"        = opus ]   || fail "an unknown complexity must fail safe to model"
# attempt 2 is ALWAYS the expensive model: a cheap theme escalates, an expensive one never demotes.
# Both directions are asserted, because an implementation that just returns $NS_AGENT_MODEL for
# everything passes the judgement cases above and would silently stop routing anything cheaply.
[ "$(route 2 trivial)"    = opus ]   || fail "a failed cheap attempt did not escalate to model"
[ "$(route 2 judgement)"  = opus ]   || fail "a judgement retry left the expensive model"
case "$(route 1 trivial)$(route 2 trivial)" in
    sonnetopus) : ;;
    *) fail "escalation is not one-way: attempt1/attempt2 for a trivial theme was '$(route 1 trivial)/$(route 2 trivial)'" ;;
esac
echo "routing: trivial/mechanical -> model_simple, judgement -> model, retry always -> model"
```

- [ ] **Step 7: Rehearse a whole tier against a stub `claude`**

No tokens, no network. The stub records which model each session was asked for, fails the first apply so the escalation path actually executes, and emits valid envelopes:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
T="$(mktemp -d)"; rm -f /tmp/ns-models.log
cat > "$T/claude" <<'EOF'
#!/usr/bin/env bash
model=""; prompt=""
while [ $# -gt 0 ]; do
    case "$1" in
        --model) model=$2; shift 2 ;;
        -p) prompt=$2; shift 2 ;;
        *) shift ;;
    esac
done
case "$prompt" in
    *"audit shard"*) echo "AUDIT $model" >> /tmp/ns-models.log
        printf '{"result":"```json\\n[{\\"file\\":\\"jac/jaclang/cli/x.jac\\",\\"rule\\":\\"dead-code\\",\\"snippet\\":\\"s\\",\\"summary\\":\\"s\\",\\"est_loc_saved\\":5,\\"confidence\\":5,\\"risk\\":1,\\"theme_hint\\":\\"stub\\",\\"complexity\\":\\"trivial\\"}]\\n```","is_error":false}\n' ;;
    *) n=$(grep -c '^APPLY' /tmp/ns-models.log || true); echo "APPLY $model" >> /tmp/ns-models.log
       case "$n" in
           0) printf '{"result":"not json at all","is_error":false}\n' ;;   # force one escalation
           *) printf '{"result":"```json\\n{\\"summary\\":\\"s\\",\\"files\\":[],\\"loc_before\\":1,\\"loc_after\\":0,\\"risk\\":\\"low\\",\\"release_note_md\\":\\"- x\\"}\\n```","is_error":false}\n' ;;
       esac ;;
esac
EOF
chmod +x "$T/claude"
NS_ROOT="$PWD" bash -c '
  set -uo pipefail
  . lib/common.sh; ns_load_config; . lib/cimirror.sh; . lib/tier2.sh; . scripts/../lib/verify.sh
  NS_PATHS_CLAUDE="'"$T"'/claude"; LOG_DIR="'"$T"'/logs"; mkdir -p "$LOG_DIR"
  date +%s > "$LOG_DIR/start_epoch"
  STATE="'"$T"'/state.json"; printf "{}" > "$STATE"
  tier2_main' || true
cat /tmp/ns-models.log
```

Expected: eight `AUDIT opus` lines (one per shard, the audit is always Opus), then `APPLY sonnet` followed by `APPLY opus` for the same theme — the trivial theme routed cheap, failed to parse, and escalated exactly once. If the second APPLY line says `sonnet`, `ns_attempt_model` is not being consulted per attempt.

- [ ] **Step 8: Confirm the cycle and carry-over files moved**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
jac run scripts/ledger.jac state-get cycle_index state/state.json
ls -l state/carryover.json 2>/dev/null || echo "(no carry-over yet)"
```

Expected: `cycle_index` is 1 after one rehearsal against the live state (the rehearsal above used a scratch state file, so this shows 0 unless a real night has run), and no carry-over file until a night defers something.

- [ ] **Step 9: Run the harness suite and commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add lib/tier2.sh bin/test-harness.sh
git commit -m "Run one task per night, carry deferred work, route apply by complexity

tier2_main reads tonight's task from the cycle (advancing it on read, so a
night that dies does not stall the rotation), loads that task's knobs, renders
that task's audit prompt, and parses findings against that task's schema. The
coverage task additionally builds its covmap evidence first, and skips its own
audit entirely when that fails -- an empty evidence block reads to the model
exactly like 'everything is tested'.

tier2_select merges state/carryover.json AHEAD of tonight's findings, so
deferred themes pack first, and writes tonight's deferrals back through a temp
file: a straight redirect would have truncated yesterday's carry-over before
the reader could fail.

tier2_apply is per-theme, not per-night: a carried theme keeps its own task's
ponytail mode, rules snippet, and fragment kind. Attempt 1 routes on the theme's
complexity and every retry is the expensive model, so escalation is one-way by
construction rather than by comment. The branch name needed no change -- the
slug is already <task>-<theme-hint>, which is what the S4 gate reads the task
from."
```

---

## Deliberately not built

- **Per-task `model` / `model_simple` in `[tasks.*]`.** The spec's table gives all four tasks the same pair, and config for a value that never changes is a knob nobody can be wrong about only because nobody can change it. They live in `[agent]` instead. Add them back to `[tasks.*]` the first time one task genuinely needs a different model — the reader (`tasks.jac task_env`) already walks a per-task table, so it is a two-line change.
- **A per-task `order` key.** The cycle order is the order the tables appear in the file. Two sources of truth for one ordering drift apart; `bin/test-harness.sh` section 11 pins the sequence from outside instead.
- **A per-task rule vocabulary in config.** `parse_result.valid_rules()` is one union across all four tasks. Nothing branches on the rule except the vestigial-test sweep, which independently verifies every file it touches. Add per-task rule lists the day something actually dispatches on a rule.
- **Escalation on a red S4 gate.** Spec 13 says a Sonnet apply that "fails the gate" retries once on Opus; this plan escalates on a malformed or dead session only, because the gate runs in S4 — a different stage, after every theme has been applied — and re-entering apply from there is the same machinery as Plan 3's CI repair loop. Build it there, once, for both.
- **Phase B coverage instrumentation.** `covmap.jac` ships the static symbol proxy. Real line coverage is a compiler pass in a repo we do not control and has its own spec.
- **A template engine for prompts.** Nine prompt files and `render_prompt`'s eight-line string substitution. The moment a prompt needs a conditional, write two prompts.
- **Semantic test-strength analysis.** The weakening guard counts asserts and test blocks. It will reject a legitimate parametrisation that folds three asserts into one, and the coverage apply prompt tells the agent so. The upgrade path (compare collected item ids) is written into the docstring.
- **A cap on the carry-over file.** Only `over-night-budget` and `no-clock-left` findings are carried, and both drain by being packed first the next night. `over-theme-budget` — the one class that can never fit and would therefore accumulate forever — is excluded. If a live night ever shows the file growing across a week, cap it by score there rather than adding a knob now.
