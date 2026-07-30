# Nightshift v2 Plan 1: Foundations (whole-repo audit + faithful CI mirror)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the harness tell the truth about the restructured target repo, audit the whole repo in LOC-balanced shards, and gate every branch against a faithful local replica of the CI jobs that a fork PR cannot otherwise reach.

**Architecture:** Three independent changes layered bottom-up. First correct the stale facts baked into `config/nightshift.toml` and `scripts/nslib.jac` (upstream repo name, package list, release-note fragment path). Then replace single-package audit scope with a shard registry plus a 2-concurrent audit driver in `lib/tier2.sh`. Then add `lib/cimirror.sh`, a local replica of the five Blacksmith-only CI jobs, wired into S4 ahead of the existing test gate, with a `ci.yml` hash-drift tripwire so the replica cannot silently rot.

**Tech Stack:** bash 3.2 (macOS stock, no `wait -n`), Jac 0.16.1 for all data/logic helpers, `gh` CLI, `pre-commit` from pipx, the target repo's own dev-built `jac` binary for repo gates.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-30-nightshift-4task-design.md`. Every fact in its section 2 was verified on 2026-07-30 by inspection; do not re-derive, and do not assume anything it contradicts.
- **bash is 3.2.57** (confirmed: `/bin/bash` is what `#!/usr/bin/env bash` resolves to). No `wait -n`, no associative arrays, no `${var^^}`. Concurrency must poll `jobs -rp`.
- **bash 3.2 + `set -u` aborts on empty arrays.** `${#arr[@]}` and `"${arr[@]}"` both fail when `arr` is empty, and `bin/nightshift.sh` runs `set -euo pipefail`. Never introduce a bash array that can legitimately be empty; use a space-joined string and a counter. (The existing `model_args=()` pattern only survives because `[agent].model` is never blank in practice.)
- **No Python files.** bash sequences processes; Jac owns every data and logic transformation. This is a standing project rule.
- **Every Jac helper gets `test` blocks in the same file** and is registered in `bin/test-harness.sh` section 1.
- **Upstream is `jaseci-labs/jac`.** Not `jaseci-labs/jaseci`.
- **Release-note fragments live at `release_notes/unreleased/jaclang/<PR#>.<kind>.md`.** Valid kinds: `feature|bugfix|breaking|refactor|docs`. Only `jac/jaclang/**` changes need one.
- **CI's format command is exactly** `jac fmt --check --lintfix` with exclusion regex `(/fixtures/|^scripts/|/passes/native/llvm/|_err\.jac$|_syntax_err\.jac$)`. Never `jac format .` or `jac lint --fix`.
- **Two jac binaries.** `$NS_PATHS_JAC` runs the harness's own `scripts/*.jac`. `$NS_PATHS_JAC_REPO` is the target repo's dev binary for every repo-facing gate. Never mix them.
- Run `bin/test-harness.sh` before every commit in this plan. It must print `ALL HARNESS TESTS PASSED`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `config/nightshift.toml` | every knob | Modify: repo name, drop `[rotation]`, add `[shards]`, fix `[protect].globs` |
| `config/ci-mirror.toml` | the mirror's command list + `ci.yml` hash | **Create** |
| `scripts/nslib.jac` | shared pure helpers | Modify: replace `fragment_dir`/`release_fragment` with `fragment_path` |
| `scripts/shards.jac` | shard registry queries | **Create** |
| `scripts/check_scope.jac` | S4 scope containment | Modify: use `fragment_path` |
| `lib/common.sh` | shared plumbing | Modify: delete `ns_audit_scope`, add `ns_jobs_wait` |
| `lib/cimirror.sh` | local replica of the Blacksmith CI jobs | **Create** |
| `lib/tier2.sh` | S3 audit/select/apply | Modify: sharded concurrent audit |
| `lib/tier1.sh` | S2 deterministic autofix | Modify: CI's exact fmt invocation |
| `lib/verify.sh` | S4 gate | Modify: mirror first, new package routing, equivalence suite |
| `bin/nightshift.sh` | entry point | Modify: source `cimirror.sh` |
| `bin/test-harness.sh` | CI of the harness | Modify: new tests + hash tripwire |

---

### Task 1: Correct the stale repo facts

The target repo restructured. `jac-byllm` and `jac-scale` are gone as packages, upstream renamed, and the release-note path moved. Everything downstream reads these, so they go first.

**Files:**
- Modify: `scripts/nslib.jac:177-187` (replace `fragment_dir` + `release_fragment`)
- Modify: `scripts/nslib.jac:195-201` (the negation-glob test, whose fixture path no longer exists)
- Modify: `scripts/check_scope.jac:16` (import), `scripts/check_scope.jac:21` (call site)
- Modify: `config/nightshift.toml` (`[repo].upstream`, `[protect].globs`)

**Interfaces:**
- Produces: `fragment_path(paths: list[str], kind: str) -> str` in `nslib.jac` — returns the fragment path for a change touching `jac/jaclang/**`, or `""` when no fragment is required. Replaces `release_fragment(pkg)` and `fragment_dir(pkg)`, both deleted.
- Produces: `VALID_FRAGMENT_KINDS: list[str]` in `nslib.jac`.
- Consumed by: `check_scope.jac` (Task 1), `lib/tier2.sh` fragment writing (Plan 2), `render_draft.jac` (Plan 3).

- [ ] **Step 1: Write the failing tests in `scripts/nslib.jac`**

Append to the test block region (after the existing `test "protected globs with negation"`):

```jac
test "fragment_path maps only jac/jaclang changes, and validates the kind" {
    assert fragment_path(["jac/jaclang/compiler/x.jac"], "refactor")
        == "release_notes/unreleased/jaclang/0000.refactor.md";
    assert fragment_path(["jac/jaclang/byllm/y.jac"], "bugfix")
        == "release_notes/unreleased/jaclang/0000.bugfix.md";
    # jac-mcp and the top-level test tree map to nothing: no fragment required
    assert fragment_path(["jac-mcp/server.jac"], "refactor") == "";
    assert fragment_path(["jac/tests/test_x.jac"], "refactor") == "";
    # first matching path wins; a mixed diff still gets exactly one fragment
    assert fragment_path(["jac-mcp/a.jac", "jac/jaclang/cli/b.jac"], "docs")
        == "release_notes/unreleased/jaclang/0000.docs.md";
    # an invalid kind falls back to refactor rather than emitting a path CI will reject
    assert fragment_path(["jac/jaclang/cli/b.jac"], "nonsense")
        == "release_notes/unreleased/jaclang/0000.refactor.md";
}
```

Also replace the now-invalid negation test, because the `docs/docs/community/...` path it asserts on no longer exists in the repo:

```jac
test "protected globs with negation" {
    globs: list[str] = ["**/tests/**", "docs/**", "!release_notes/unreleased/**"];
    assert is_protected("jac/tests/fixtures/x.jac", globs);
    assert is_protected("docs/guide/intro.md", globs);
    # fragments live outside docs/ now, so they are simply never protected
    assert not is_protected("release_notes/unreleased/jaclang/0000.refactor.md", globs);
    assert not is_protected("jac/jaclang/compiler/passes.jac", globs);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/nslib.jac
```

Expected: FAIL — `fragment_path` is not defined.

- [ ] **Step 3: Replace `fragment_dir` and `release_fragment` in `scripts/nslib.jac`**

Delete lines 177-187 entirely and put this in their place:

```jac
"""scripts/check-release-notes.sh in the target repo maps exactly one folder:
jac/jaclang/ -> release_notes/unreleased/jaclang/. Everything else (jac-mcp/,
jac/tests/, docs/) requires no fragment, so return "" and let callers skip it.
The 0000 placeholder is renamed to the PR number after the PR is opened."""
glob VALID_FRAGMENT_KINDS: list[str] = ["feature", "bugfix", "breaking", "refactor", "docs"];

def fragment_path(paths: list[str], kind: str) -> str {
    safe_kind: str = kind if kind in VALID_FRAGMENT_KINDS else "refactor";
    for p in paths {
        if str(p).startswith("jac/jaclang/") {
            return "release_notes/unreleased/jaclang/0000." + safe_kind + ".md";
        }
    }
    return "";
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/nslib.jac
```

Expected: PASS, all tests.

- [ ] **Step 5: Update `scripts/check_scope.jac` to the new helper**

Line 16, change the import list: replace `release_fragment` with `fragment_path`.

```jac
import from nslib { eprint, read_stdin, parse_obj, as_list, is_protected, load_globs, fragment_path }
```

In `violations`, replace line 21 (`allowed.append(release_fragment(str(theme["package"])));`) with:

```jac
    # The orchestrator, not the agent, writes the fragment -- but the gate must still allow it
    # through. Kind comes from the theme; fragment_path clamps an invalid kind to refactor, so a
    # tampered theme cannot smuggle an arbitrary filename past the regex CI enforces.
    frag: str = fragment_path(allowed, str(theme.get("fragment_kind", "refactor")));
    if frag {
        allowed.append(frag);
    }
```

- [ ] **Step 6: Fix the `check_scope.jac` test whose fixture used the old path**

Replace the first test (lines 81-92) with:

```jac
test "diff outside allow-list is a violation, fragment is allowed" {
    theme: dict = {"package": "jac", "files": ["jac/jaclang/cli/pipe.jac"]};
    globs: list[str] = ["**/tests/**"];
    changed: list[tuple[str, str]] = [
        ("M", "jac/jaclang/cli/pipe.jac"),
        ("A", "release_notes/unreleased/jaclang/0000.refactor.md"),
        ("M", "jac/jaclang/cli/rogue.jac"),
    ];
    found: list[str] = violations(changed, theme, globs);
    assert len(found) == 1;
    assert "rogue.jac" in found[0];
}
```

- [ ] **Step 7: Run the check_scope tests**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/check_scope.jac
```

Expected: PASS, all four tests.

- [ ] **Step 8: Correct `config/nightshift.toml`**

In `[repo]`, change `upstream`:

```toml
upstream       = "jaseci-labs/jac"          # renamed from jaseci-labs/jaseci
```

Delete the whole `[rotation]` section including its comment block (lines 8-12). Whole-repo audit replaces it; Task 2 adds `[shards]`.

In `[protect].globs`, drop the dead negation and stop protecting the fragment tree that no longer lives under `docs/`:

```toml
[protect]                                    # glob deny-list; enforced twice (prompt + S4 gate)
# release_notes/ is NOT listed: fragments live outside docs/ since the restructure, so they need
# no negation entry. The old "!docs/docs/community/release_notes/unreleased/**" was dead.
globs = [
  "**/tests/**", "**/fixtures/**", "**/*.test.jac",
  "**/jac.spec", "**/grammar/**", "**/generated/**", "**/vendor/**",
  "docs/**",
  ".github/**", "examples/**",
]
```

- [ ] **Step 9: Delete `ns_audit_scope` from `lib/common.sh`**

Remove lines 129-136 entirely. It hardcodes the pre-restructure package geography and Task 2 replaces it with the shard registry. Nothing else may call it after this step; verify:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && grep -rn "ns_audit_scope" bin lib scripts prompts || echo "no callers remain"
```

Expected: one hit in `lib/tier2.sh:37` (fixed in Task 3). Note it and continue.

- [ ] **Step 10: Run the harness tests**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
```

Expected: section 3's golden replay may now fail, because `selector.jac select` is still called with a package argument. If it fails on anything other than the golden replay, stop and fix. The golden replay is repaired in Task 3.

- [ ] **Step 11: Commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add scripts/nslib.jac scripts/check_scope.jac config/nightshift.toml lib/common.sh
git commit -m "Correct stale target-repo facts after the upstream restructure

Upstream renamed to jaseci-labs/jac. jac-byllm and jac-scale no longer exist
as packages; they are jac/jaclang/byllm and jac/jaclang/scale. Release-note
fragments moved to release_notes/unreleased/jaclang/, which also makes the
docs/** negation glob dead.

Replaces release_fragment(pkg) and fragment_dir(pkg) with
fragment_path(paths, kind), which returns \"\" when a change needs no fragment
and clamps an invalid kind to refactor so a tampered theme cannot smuggle a
filename past the regex CI enforces."
```

---

### Task 2: Shard registry

Eight LOC-balanced shards replace one-package-per-night. LOC figures are measured, not guessed (spec section 2).

**Files:**
- Create: `scripts/shards.jac`
- Modify: `config/nightshift.toml` (add `[shards]`)
- Modify: `bin/test-harness.sh:13` (register `shards` in the jac test sweep)

**Interfaces:**
- Produces: `jac run scripts/shards.jac list <config.toml>` — prints one shard name per line, in config order.
- Produces: `jac run scripts/shards.jac scope <name> <config.toml>` — prints the audit-scope string for one shard (the paths, plus any exclusions), for interpolation into the audit prompt's `{scope}`.
- Produces: `jac run scripts/shards.jac count <config.toml>` — prints the shard count.
- Consumed by: `lib/tier2.sh` (Task 3).

- [ ] **Step 1: Add `[shards]` to `config/nightshift.toml`**

Insert where `[rotation]` used to be:

```toml
[shards]                                     # whole-repo audit, LOC-balanced. Measured 2026-07-30:
# compiler 130920 - scale 86566 - jac0core 46711 - runtimelib 40719 - cli 31630 - byllm 16732 -
# project 4465 - publish 3022 - langserve 1730 - utils 1486 - lsp 1182. ~365k LOC of Jac total.
# ponytail: the largest shard is still ~87k LOC, so a night is DEEP, not exhaustive. Full-repo
#           coverage emerges over many nights. Upgrade path: split scale/compiler further here.
concurrency = 2                              # bash 3.2 has no `wait -n`; the driver polls jobs -rp
names = ["compiler-passes", "compiler-core", "scale", "jac0core",
         "runtimelib", "cli", "byllm", "periphery"]

[shards.paths]
compiler-passes = ["jac/jaclang/compiler/passes"]
compiler-core   = ["jac/jaclang/compiler"]
scale           = ["jac/jaclang/scale"]
jac0core        = ["jac/jaclang/jac0core"]
runtimelib      = ["jac/jaclang/runtimelib"]
cli             = ["jac/jaclang/cli"]
byllm           = ["jac/jaclang/byllm"]
periphery       = ["jac/jaclang/langserve", "jac/jaclang/lsp", "jac/jaclang/project",
                   "jac/jaclang/publish", "jac/jaclang/utils", "jac-mcp"]

[shards.exclude]                             # subtracted from the shard's own paths in the prompt
compiler-core   = ["jac/jaclang/compiler/passes", "jac/jaclang/compiler/tests"]
```

- [ ] **Step 2: Write the failing test file `scripts/shards.jac`**

Create the file with its tests and a stub, so the test run fails on behavior rather than on a missing file:

```jac
"""Shard registry for the whole-repo audit (design spec section 5).

The audit cannot read 365k LOC in one session, so the repo is split into
LOC-balanced shards that are audited concurrently and merged into one selection.

argv:
  list  <config.toml>          print one shard name per line, in config order
  count <config.toml>          print the number of shards
  scope <name> <config.toml>   print the prompt-ready scope string for one shard
"""
import sys;
import from nslib { eprint, load_config_toml }

def shard_names(cfg: dict) -> list[str] {
    return [str(n) for n in cfg["shards"]["names"]];
}

def shard_scope(cfg: dict, name: str) -> str {
    paths: list[str] = [str(p) for p in cfg["shards"]["paths"][name]];
    excl_table: dict = cfg["shards"].get("exclude", {});
    excl: list[str] = [str(p) for p in excl_table.get(name, [])];
    scope: str = ", ".join(paths);
    if excl {
        scope = scope + " (excluding " + ", ".join(excl) + ")";
    }
    return scope;
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "list" and len(args) == 3 {
        for n in shard_names(load_config_toml(args[2])) {
            print(n);
        }
    } elif cmd == "count" and len(args) == 3 {
        print(len(shard_names(load_config_toml(args[2]))));
    } elif cmd == "scope" and len(args) == 4 {
        print(shard_scope(load_config_toml(args[3]), args[2]));
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run shards.jac list|count <config.toml>");
        eprint("       jac run shards.jac scope <name> <config.toml>");
    }
}

test "every declared shard name has paths, and none is empty" {
    cfg: dict = load_config_toml("config/nightshift.toml");
    names: list[str] = shard_names(cfg);
    assert len(names) == 8;
    for n in names {
        assert n in cfg["shards"]["paths"];
        assert len(cfg["shards"]["paths"][n]) >= 1;
    }
}

test "scope renders paths and appends exclusions only when present" {
    cfg: dict = load_config_toml("config/nightshift.toml");
    assert shard_scope(cfg, "scale") == "jac/jaclang/scale";
    core: str = shard_scope(cfg, "compiler-core");
    assert core.startswith("jac/jaclang/compiler (excluding ");
    assert "jac/jaclang/compiler/passes" in core;
    assert "jac/jaclang/compiler/tests" in core;
    assert ", " in shard_scope(cfg, "periphery");
}

test "shards do not overlap once exclusions are applied" {
    cfg: dict = load_config_toml("config/nightshift.toml");
    # compiler-core must exclude compiler-passes or the two shards audit the same files twice
    assert "jac/jaclang/compiler/passes" in [
        str(p) for p in cfg["shards"]["exclude"]["compiler-core"]
    ];
}
```

- [ ] **Step 3: Run the tests**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/shards.jac
```

Expected: PASS, three tests. If `load_config_toml` cannot resolve the relative config path, run from `NS_ROOT` (all Jac helpers do; `ns_jac` enforces it).

- [ ] **Step 4: Verify the CLI surface by hand**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
jac run scripts/shards.jac list config/nightshift.toml
jac run scripts/shards.jac count config/nightshift.toml
jac run scripts/shards.jac scope compiler-core config/nightshift.toml
```

Expected: 8 names one per line; `8`; `jac/jaclang/compiler (excluding jac/jaclang/compiler/passes, jac/jaclang/compiler/tests)`.

- [ ] **Step 5: Confirm every shard path actually exists in the target repo**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
for n in $(jac run scripts/shards.jac list config/nightshift.toml); do
  for p in $(jac run scripts/shards.jac scope "$n" config/nightshift.toml | tr ',' ' ' | sed 's/(excluding.*//'); do
    [ -d "work/repo/$p" ] && echo "ok   $p" || echo "MISS $p"
  done
done
```

Expected: every line `ok`. Any `MISS` means the shard config is wrong; fix it before committing.

- [ ] **Step 6: Register in `bin/test-harness.sh`**

Line 13, add `shards` to the test sweep list:

```bash
for f in nslib config ledger check_scope parse_result selector render_draft sendmail testgate checkgate dataset shards; do
```

- [ ] **Step 7: Commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add scripts/shards.jac config/nightshift.toml bin/test-harness.sh
git commit -m "Add shard registry for whole-repo audit

Eight LOC-balanced shards replace one-package-per-night rotation, which the
restructure invalidated anyway. LOC figures in the config comment are measured,
not estimated. compiler-core excludes compiler-passes and compiler/tests so the
two compiler shards do not audit the same files twice."
```

---

### Task 3: Sharded concurrent audit driver

`tier2_audit` currently runs one session for one package. It becomes N sessions over shards, 2 at a time, with findings merged into one array before selection.

**Files:**
- Modify: `lib/tier2.sh:16-91` (`tier2_main`, `tier2_audit`)
- Modify: `lib/tier2.sh:94-108` (`tier2_select` loses its package argument)
- Modify: `lib/common.sh` (add `ns_jobs_wait`)
- Modify: `scripts/parse_result.jac` (add a `merge` verb)
- Modify: `bin/test-harness.sh:26-30` (golden replay drops the package arg)

**Interfaces:**
- Consumes: `shards.jac list|scope|count` (Task 2).
- Produces: `ns_jobs_wait <max>` in `lib/common.sh` — blocks until fewer than `<max>` background jobs of the current shell are running. bash 3.2 compatible.
- Produces: `jac run scripts/parse_result.jac merge <findings1.json> <findings2.json> ...` — concatenates findings arrays into one, dropping duplicate `(file, rule)` pairs, and prints the merged array.
- Produces: `$LOG_DIR/findings.json` with the same schema as today, so `selector.jac` needs no change beyond the dropped package argument.

- [ ] **Step 1: Add `ns_jobs_wait` to `lib/common.sh`**

Insert after `ns_timebox` (around line 79):

```bash
# Block until fewer than <max> of THIS shell's background jobs are still running.
# bash 3.2 (macOS stock, confirmed 3.2.57) has no `wait -n`, so poll instead of blocking on one job.
# ponytail: 5s poll, not a job-control state machine. Audit sessions run for minutes.
ns_jobs_wait() {
    local max=$1
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$max" ]; do
        sleep 5
    done
}
```

- [ ] **Step 2: Add the `merge` verb to `scripts/parse_result.jac`**

Read the file first to match its existing style and the helper it uses to load a findings array. Add to the `with entry` dispatch, and add this function alongside the existing ones:

```jac
"""Merge per-shard findings arrays into one. Two shards can legitimately surface the
same (file, rule) pair when a file sits on a shard boundary; the ledger fingerprint is
sha1(file \x1f rule), so shipping both would double-count one finding. First wins."""
def merge_findings(arrays: list[list[dict]]) -> list[dict] {
    seen: set[str] = set();
    out: list[dict] = [];
    for arr in arrays {
        for f in arr {
            key: str = str(f.get("file", "")) + "\x1f" + str(f.get("rule", ""));
            if key not in seen {
                seen.add(key);
                out.append(f);
            }
        }
    }
    return out;
}
```

Dispatch branch. `parse_result.jac:13` already imports `parse_list` from `nslib`, so use that; do not introduce a second array parser. Insert this branch before the final `elif cmd != "" and cmd != "test"` at line 125:

```jac
    } elif cmd == "merge" and len(args) >= 3 {
        arrays: list[list[dict]] = [];
        for path in args[2:] {
            with open(path, "r") as f {
                arrays.append(parse_list(f.read()));
            }
        }
        print(json.dumps(merge_findings(arrays)));
```

- [ ] **Step 3: Write the failing test for merge in `scripts/parse_result.jac`**

```jac
test "merge dedupes on (file, rule) and preserves first-seen order" {
    a: list[dict] = [{"file": "x.jac", "rule": "dead-code", "confidence": 5},
                     {"file": "y.jac", "rule": "simplify", "confidence": 3}];
    b: list[dict] = [{"file": "x.jac", "rule": "dead-code", "confidence": 1},
                     {"file": "z.jac", "rule": "duplication", "confidence": 4}];
    merged: list[dict] = merge_findings([a, b]);
    assert len(merged) == 3;
    assert merged[0]["file"] == "x.jac" and merged[0]["confidence"] == 5;
    assert [str(m["file"]) for m in merged] == ["x.jac", "y.jac", "z.jac"];
}

test "merge tolerates empty and single arrays" {
    assert merge_findings([]) == [];
    assert merge_findings([[], []]) == [];
    one: list[dict] = [{"file": "a.jac", "rule": "simplify"}];
    assert len(merge_findings([one])) == 1;
}
```

- [ ] **Step 4: Run it, expect failure, then pass**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/parse_result.jac
```

Expected before Step 2's code is in place: FAIL on `merge_findings` undefined. After: PASS.

- [ ] **Step 5: Rewrite `tier2_audit` as a per-shard function in `lib/tier2.sh`**

Replace `tier2_audit()` (lines 32-91) with a shard-scoped version. The retry, corrective re-prompt, and session-limit detection logic is preserved verbatim; only the scope, the output paths, and the return contract change.

```bash
# Phase A — audit, physically read-only (dontAsk + no Edit/Write in the allow-list).
# ONE SHARD per session: 365k LOC cannot be audited in one context (design spec 5).
# Writes $LOG_DIR/findings-<shard>.json on success. Never returns nonzero for a single
# shard failure -- a dead shard must not kill the tier, the way a dead package used to.
tier2_audit_shard() {
    local shard=$1 prompt attempt scope
    scope="$(ns_jac shards scope "$shard" "$CONFIG")"
    prompt="$(render_prompt "$NS_ROOT/prompts/audit.md" \
        "shard=$shard" "scope=$scope" \
        "protect_globs=$NS_PROTECT_GLOBS" "ponytail_mode=$NS_AGENT_PONYTAIL_MODE")"

    local -a model_args=()
    [ -n "$NS_AGENT_MODEL" ] && model_args=(--model "$NS_AGENT_MODEL")

    for attempt in 1 2; do
        (cd "$REPO" && export PATH="$(dirname "$NS_PATHS_JAC_REPO"):$PATH" \
            && ns_timebox "$NS_BUDGETS_AUDIT_TIMEOUT_MIN" "$NS_PATHS_CLAUDE" -p "$prompt" \
            "${model_args[@]}" \
            --permission-mode dontAsk \
            --allowedTools "Read,Grep,Glob,Bash(jac code *),Bash(jac check *),Bash(jac guide *),mcp__jac__*" \
            --max-turns "$NS_BUDGETS_AUDIT_MAX_TURNS" --output-format json) \
            > "$LOG_DIR/audit-$shard.json" < /dev/null || true

        if [ ! -s "$LOG_DIR/audit-$shard.json" ]; then
            ns_log S3 "audit[$shard] attempt $attempt produced no output (killed at ${NS_BUDGETS_AUDIT_TIMEOUT_MIN}m?)"
            continue
        fi

        ns_jac parse_result meta < "$LOG_DIR/audit-$shard.json" > "$LOG_DIR/meta-audit-$shard.json" || true

        if ns_jac parse_result findings < "$LOG_DIR/audit-$shard.json" \
                > "$LOG_DIR/findings-$shard.json" 2> "$LOG_DIR/parse-err-audit-$shard.txt"; then
            ns_log S3 "audit[$shard]: $(ns_jac parse_result len < "$LOG_DIR/findings-$shard.json" || echo 0) findings"
            return 0
        fi

        # Hard account limit: leave a marker so the DRIVER can drop to serial / stop scheduling.
        if grep -q "hit your session limit" "$LOG_DIR/audit-$shard.json"; then
            touch "$LOG_DIR/.session-limit"
            ns_fail "audit[$shard]" "Claude session limit hit"
            rm -f "$LOG_DIR/findings-$shard.json"
            return 1
        fi

        ns_timebox 3 "$NS_PATHS_CLAUDE" -p "Your audit output failed validation: $(cat "$LOG_DIR/parse-err-audit-$shard.txt")
Previous output:
$(ns_jac parse_result field result < "$LOG_DIR/audit-$shard.json")
Re-emit ONLY the corrected \`\`\`json fenced findings array — same schema, no prose." \
            "${model_args[@]}" --max-turns 1 --output-format json \
            > "$LOG_DIR/audit-repair-$shard.json" < /dev/null || true
        if ns_jac parse_result findings < "$LOG_DIR/audit-repair-$shard.json" > "$LOG_DIR/findings-$shard.json"; then
            ns_log S3 "audit[$shard] salvaged via corrective re-prompt — $(ns_jac parse_result len < "$LOG_DIR/findings-$shard.json" || echo 0) findings"
            return 0
        fi
        ns_log S3 "audit[$shard] attempt $attempt failed to parse even after corrective re-prompt"
    done
    ns_fail "audit[$shard]" "malformed/failed audit after retry — this shard contributes nothing"
    rm -f "$LOG_DIR/findings-$shard.json"
    return 1
}
```

Note `< /dev/null` on every `claude` invocation. The original had it only on apply; here the driver loop also feeds stdin, so an audit session would eat the remaining shard list without it. That exact bug cost 5 of 6 themes on a real night (see the comment at `lib/tier2.sh:140`).

- [ ] **Step 6: Add the concurrency driver**

Insert after `tier2_audit_shard`:

```bash
# Fan out audit shards, <concurrency> at a time, then merge into one findings array.
# A session limit collapses the fan-out to serial rather than aborting the tier: the old
# behavior lost every remaining shard to one limit signal.
tier2_audit_all() {
    local shard conc merged=0
    conc="${NS_SHARDS_CONCURRENCY:-2}"
    rm -f "$LOG_DIR/.session-limit"

    for shard in $(ns_jac shards list "$CONFIG"); do
        if [ -f "$LOG_DIR/.session-limit" ]; then
            ns_log S3 "session limit seen — dropping to serial for the remaining shards"
            conc=1
        fi
        if [ "$(ns_remaining_min)" -lt $(( NS_BUDGETS_AUDIT_TIMEOUT_MIN + NS_BUDGETS_APPLY_TIMEOUT_MIN )) ]; then
            ns_warn "clock too short to audit remaining shards — stopping the fan-out at $shard"
            break
        fi
        ns_jobs_wait "$conc"
        tier2_audit_shard "$shard" &
    done
    wait

    # Collect the shards that produced findings. NOT a bash array: under `set -u` (which
    # bin/nightshift.sh sets) bash 3.2 aborts on ${#arr[@]} and "${arr[@]}" when the array is
    # EMPTY -- and "every shard failed" is exactly the case this branch has to survive.
    # ponytail: a space-joined string is fine; these are repo-relative log paths with no spaces.
    local found="" n_found=0
    for shard in $(ns_jac shards list "$CONFIG"); do
        if [ -s "$LOG_DIR/findings-$shard.json" ]; then
            found="$found $LOG_DIR/findings-$shard.json"
            n_found=$(( n_found + 1 ))
        fi
    done
    if [ "$n_found" -eq 0 ]; then
        ns_fail "audit" "every shard failed or produced nothing — agentic tier skipped tonight"
        return 1
    fi
    # shellcheck disable=SC2086  # deliberate word-split into one arg per shard findings file
    ns_jac parse_result merge $found > "$LOG_DIR/findings.json"
    merged="$(ns_jac parse_result len < "$LOG_DIR/findings.json" || echo 0)"
    ns_log S3 "merged ${#found[@]}/$(ns_jac shards count "$CONFIG") shards into $merged findings"
    return 0
}
```

- [ ] **Step 7: Rewrite `tier2_main` to drop package rotation**

Replace lines 16-30:

```bash
tier2_main() {
    local remaining; remaining="$(ns_remaining_min)"
    if [ "$remaining" -lt $(( NS_BUDGETS_AUDIT_TIMEOUT_MIN + NS_BUDGETS_APPLY_TIMEOUT_MIN )) ]; then
        ns_warn "no clock left for the agentic tier (${remaining}m remaining) — skipping S3"
        return 0
    fi

    tier2_audit_all || return 0        # no usable findings skips the tier; tier-1 still ships
    tier2_select
    tier2_apply
    dataset_record_night               # after select+apply: selection.json + every meta-*.json exist
}
```

- [ ] **Step 8a: Remove the package concept from `scripts/selector.jac`**

Package rotation is gone, so `rotate` would crash on the deleted `[rotation]` table and `theme["package"]` no longer has a meaning (a theme can now span shards). Four concrete edits:

1. **`def select` (line 233):** delete the `package: str` parameter. Update the docstring at line 4 to `select <config.toml> <ledger.jsonl> <state.json> <remaining_min> <repo_dir>`.
2. **`def pack_themes` (line 152):** delete the `package: str` parameter, and at line 203 delete the `"package": package,` entry from the theme dict. Update the call at line 253 to drop the argument.
3. **`def rotate` (lines 258-268) and its dispatch (lines 297-298):** delete both outright. Also delete the usage line for `rotate` at line 8.
4. **Dispatch for `select` (lines 273-276):** now takes 7 argv, not 8. Reindex:

```jac
    if len(args) == 7 and args[1] == "select" {
        findings: list[dict] = parse_list(read_stdin());
        print(json.dumps(select(findings, args[2], args[3], args[4], int(args[5]), args[6])));
```

Match the existing body's variable names and helper calls; read lines 270-280 before editing. Update the usage string at line 300 to match. Then remove `next_package` from `state/state.json`:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
jac run scripts/ledger.jac state-set next_package '' state/state.json 2>/dev/null \
  || printf '{\n  "last_jac_version": "0.16.1",\n  "verify_estimate_min": 1\n}\n' > state/state.json
cat state/state.json
```

Expected: no `next_package` key. Then run selector's own tests, fixing any that pass a package positionally:

```bash
rm -rf .jac && jac test scripts/selector.jac
```

Expected: PASS.

- [ ] **Step 8b: Drop the package argument from `tier2_select` and `tier2_apply`**

`tier2_select()`: delete `local pkg=$1` and remove `"$pkg"` from the `ns_jac selector select` call. `tier2_apply()`: delete `local pkg=$1`; the fragment and commit message need a package name, which no longer exists at theme level. Until Plan 2 introduces per-task fragment kinds, derive it from the theme's own files:

```bash
        # The ORCHESTRATOR writes the release-note fragment — the agent has no Write tool.
        # Path derives from the theme's own files: only jac/jaclang/** needs one at all.
        local fragment
        fragment="$(ns_jac render_draft frag "$theme_file")"
        if [ -n "$fragment" ]; then
            mkdir -p "$(dirname "$REPO/$fragment")"
            ns_jac parse_result field release_note_md < "$LOG_DIR/report-$slug.json" > "$REPO/$fragment"
            git add "$fragment"
            git commit -m "docs: release note fragment (nightshift)"
        else
            ns_log S3 "theme $slug touches no jac/jaclang/ path — no fragment required"
        fi
```

Update `render_draft.jac`'s `frag` verb to take a theme file and call `fragment_path(theme["files"], theme.get("fragment_kind", "refactor"))`. Add a test in `render_draft.jac`:

```jac
test "frag returns a jaclang path for core changes and empty for jac-mcp only" {
    core: dict = {"files": ["jac/jaclang/cli/a.jac"], "fragment_kind": "refactor"};
    assert fragment_path([str(f) for f in core["files"]], str(core["fragment_kind"]))
        == "release_notes/unreleased/jaclang/0000.refactor.md";
    mcp: dict = {"files": ["jac-mcp/server.jac"]};
    assert fragment_path([str(f) for f in mcp["files"]], "refactor") == "";
}
```

Also change the theme commit message in `tier2_apply` from `refactor({pkg}): ...` to `refactor: <theme-name> (nightshift)` in `prompts/apply.md`, since `{pkg}` no longer exists. Plan 2 replaces this prompt wholesale; keep the edit minimal.

- [ ] **Step 9: Update `prompts/audit.md` placeholders**

Change `{pkg}` to `{shard}` in the two places it appears (the header line and the opening sentence), so the render call in Step 5 substitutes correctly:

```
You are auditing ONLY {scope} of the Jaseci monorepo (audit shard: `{shard}`) for over-engineering,
```

Verify no unsubstituted placeholder survives:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && grep -o '{[a-z_]*}' prompts/audit.md | sort -u
```

Expected exactly: `{ponytail_mode}`, `{protect_globs}`, `{scope}`, `{shard}`.

- [ ] **Step 10: Repair the golden replay in `bin/test-harness.sh`**

`selector.jac select` no longer takes a package. Update both invocations (lines 26-29) by removing the `jac` argument, and add a merge determinism check:

```bash
jac run scripts/selector.jac select config/nightshift.toml /nonexistent /nonexistent 999 /nonexistent-repo \
    < "$T/f.json" > "$T/s1.json"
jac run scripts/selector.jac select config/nightshift.toml /nonexistent /nonexistent 999 /nonexistent-repo \
    < "$T/f.json" > "$T/s2.json"
cmp -s "$T/s1.json" "$T/s2.json" || fail "selector output not deterministic"

echo "== 3b. findings merge: dedupe on (file, rule), stable order =="
cp "$T/f.json" "$T/f2.json"
jac run scripts/parse_result.jac merge "$T/f.json" "$T/f2.json" > "$T/m.json"
[ "$(jac run scripts/parse_result.jac len < "$T/m.json")" = "1" ] \
    || fail "merge failed to dedupe an identical findings array"
```

If `selector.jac`'s `select` verb still requires the package positionally, change its signature there too and update its own in-file tests. Read `scripts/selector.jac` before editing; it is 427 lines and the package name may also feed theme construction.

- [ ] **Step 11: Run the full harness test suite**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
```

Expected: `ALL HARNESS TESTS PASSED`.

- [ ] **Step 12: Verify the driver's concurrency without spending Opus tokens**

Temporarily stub the session by exporting a fake claude that sleeps and emits a valid envelope, then confirm only 2 run at once:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
T="$(mktemp -d)"; cat > "$T/claude" <<'EOF'
#!/usr/bin/env bash
echo "$(date +%s) START $$" >> /tmp/ns-conc.log
sleep 8
echo '{"result":"```json\n[]\n```"}'
echo "$(date +%s) END $$" >> /tmp/ns-conc.log
EOF
chmod +x "$T/claude"; rm -f /tmp/ns-conc.log
NS_PATHS_CLAUDE="$T/claude" bash -c '
  NS_ROOT="$PWD"; . lib/common.sh; ns_load_config
  NS_PATHS_CLAUDE="'"$T"'/claude"; LOG_DIR="'"$T"'/logs"; mkdir -p "$LOG_DIR"
  date +%s > "$LOG_DIR/start_epoch"
  . lib/tier2.sh; tier2_audit_all' || true
awk '/START/{n++; if(n>max)max=n} /END/{n--} END{print "peak concurrency:", max}' /tmp/ns-conc.log
```

Expected: `peak concurrency: 2`. If it prints 8, `ns_jobs_wait` is not being reached; check that `jobs -rp` sees the children (it will not if the loop runs in a subshell created by a pipe).

- [ ] **Step 13: Commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add lib/tier2.sh lib/common.sh scripts/parse_result.jac scripts/render_draft.jac \
        scripts/selector.jac prompts/audit.md prompts/apply.md bin/test-harness.sh
git commit -m "Replace package rotation with a 2-concurrent sharded whole-repo audit

One session cannot audit 365k LOC, and package rotation no longer maps to the
restructured repo. Eight shards are audited two at a time and merged, deduped on
(file, rule) so a file on a shard boundary is not double-counted.

A single dead shard no longer kills the tier. A session-limit signal collapses
the fan-out to serial instead of aborting, which previously lost every remaining
shard to one limit. Every claude invocation gets </dev/null: the driver loop
feeds stdin, and without it an audit session eats the remaining shard list."
```

---

### Task 4: CI mirror command registry and drift tripwire

The mirror must not silently rot when upstream edits `ci.yml`. Config holds the commands and a hash; the harness test fails loudly on drift.

**Files:**
- Create: `config/ci-mirror.toml`
- Modify: `bin/test-harness.sh` (add the hash tripwire as a new section)

**Interfaces:**
- Produces: `config/ci-mirror.toml` with a `[source]` table (`workflow`, `sha256`) and one `[jobs.<name>]` table per mirrored CI job, each with `ci_job` and `commands`.
- Consumed by: `lib/cimirror.sh` (Tasks 5 and 6) and the tripwire below.

- [ ] **Step 1: Record the current `ci.yml` hash**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && shasum -a 256 work/repo/.github/workflows/ci.yml
```

Note the hash; it goes into the config in the next step verbatim.

- [ ] **Step 2: Create `config/ci-mirror.toml`**

```toml
# config/ci-mirror.toml — local replica of the CI jobs a FORK PR cannot reach.
#
# Why this file exists: 13 of ~16 ci.yml jobs are `runs-on: blacksmith-4vcpu-ubuntu-2404`,
# third-party runners attached to the upstream org. Confirmed empirically on 2026-07-30 against
# ayushmk7/jaseci: ubuntu-latest/macos-latest jobs complete, every Blacksmith job sits `queued`
# indefinitely (one observed stuck 2h). The Blacksmith subset is exactly what matters for
# janitorial diffs, so fork CI is not a usable pre-PR gate and this replica is.
#
# ponytail: a hash tripwire, NOT a yaml interpreter. Parsing ci.yml at runtime to derive these
#           commands would be a parser to maintain forever; a hash mismatch that forces a human
#           to re-read the diff is three lines and cannot silently be wrong.

[source]
workflow = ".github/workflows/ci.yml"
sha256   = "PASTE_THE_HASH_FROM_STEP_1"

[jobs.fmt]
ci_job = "jac-check"
# CI's EXACT invocation. Not `jac format .`, not `jac lint --fix`. The exclusion regex is copied
# verbatim from ci.yml. A fork PR gets no autofix (the bot at ci.yml:303 is gated on same-repo
# PRs), so it hits the hard failure at ci.yml:342 instead -- formatting must be right locally.
commands = [
  "git ls-files -z '*.jac' | grep -zv -E '(/fixtures/|^scripts/|/passes/native/llvm/|_err\\.jac$|_syntax_err\\.jac$)' | xargs -0 jac fmt --check --lintfix",
]

[jobs.jir]
ci_job = "jac-check"
# ci.yml:408-410. Deleting a symbol during a dead-code sweep can invalidate the generated
# registry, which CI verifies. Without this, dead-code PRs fail CI on a file the agent
# never touched.
commands = ["jac gen-jir-registry --verify"]

[jobs.byllm]
ci_job = "test-packages-and-docs"
# ci.yml:608, run from the repo root. Note ci.yml:946 runs the SAME tests serially
# (JAC_TEST_JOBS=0) in test-pypi-build because "byllm tests share a SQLite mock-LLM cache".
# We mirror the PR-path job (608) for fidelity; the flake that serialization exists to avoid is
# absorbed by the union-of-two-runs baseline instead (see scripts/testgate.jac record-union).
commands = ["jac test jac/jaclang/byllm/tests"]

[jobs.compiler]
ci_job = "test-compiler"
# The second command is the cross-backend equivalence suite. The harness has NEVER gated it:
# lib/verify.sh's pkg_test_raw ran only tests/ and tests/compiler.
commands = [
  "JAC_TEST_JOBS=auto jac test tests/compiler",
  "JAC_TEST_JOBS=auto jac test jaclang/compiler/tests",
]

[jobs.runtime]
ci_job = "test-runtime"
commands = ["JAC_TEST_JOBS=auto jac test tests/ --ignore tests/compiler"]

[jobs.contribution]
ci_job = "contribution-checks"
commands = ["scripts/check-release-notes.sh", "pre-commit run --all-files"]
```

Replace `PASTE_THE_HASH_FROM_STEP_1` with the real hash. Then confirm every command's entry point exists:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo
ls -1 scripts/check-release-notes.sh
work=jac/zig-out/bin/jac; $work gen-jir-registry --help >/dev/null 2>&1 \
  && echo "gen-jir-registry ok" || echo "MISSING: jac gen-jir-registry"
```

Expected: the script listed, and `gen-jir-registry ok`.

- [ ] **Step 2b: Decide whether CI's whole-repo `jac check` belongs in the mirror**

`ci.yml:412` runs a whole-repo `jac check` using `.jacignore`, inside the same `jac-check` job. `lib/verify.sh:99-103` deliberately avoids a whole-repo check because it "would trip the repo's broken test fixtures" — but that comment predates `.jacignore`. This is decidable in one command:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo && git checkout main
sed -n '412,430p' .github/workflows/ci.yml          # read CI's exact invocation first
# then run that exact command here and record the exit code
```

- If it is **green on main**: add it as `[jobs.check]` with CI's exact command. It becomes a hard mirror gate, and the per-branch baseline-diff `checkgate.jac` stays as the cheaper first filter.
- If it is **red on main**: do NOT add it. Main's own CI run is red on that job, so Plan 3's CI baseline-diff is what handles it. Record the finding in a comment in `config/ci-mirror.toml` so the next person does not re-litigate it.

Either way, write down which branch you took and why.

- [ ] **Step 3: Add the drift tripwire to `bin/test-harness.sh`**

Append before the final `echo "ALL HARNESS TESTS PASSED"`:

```bash
echo "== 5. ci.yml drift tripwire =="
CI_YML="$NS_ROOT/work/repo/.github/workflows/ci.yml"
if [ -f "$CI_YML" ]; then
    want="$(sed -n 's/^sha256 *= *"\(.*\)"/\1/p' config/ci-mirror.toml | head -1)"
    have="$(shasum -a 256 "$CI_YML" | awk '{print $1}')"
    if [ "$want" != "$have" ]; then
        echo "FAIL: ci.yml changed upstream." >&2
        echo "  recorded: $want" >&2
        echo "  actual:   $have" >&2
        echo "  Re-read the ci.yml diff, re-sync config/ci-mirror.toml commands, then update" >&2
        echo "  the sha256. Do NOT just bump the hash." >&2
        exit 1
    fi
    echo "ci.yml matches the recorded hash"
else
    echo "SKIP: no work/repo clone present"
fi
```

- [ ] **Step 4: Verify the tripwire fires**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
bin/test-harness.sh | tail -3                          # expect: pass
sed -i '' 's/^sha256   = "/sha256   = "0/' config/ci-mirror.toml
bin/test-harness.sh > /dev/null 2>&1 && echo "BUG: tripwire did not fire" || echo "tripwire fires correctly"
git checkout config/ci-mirror.toml 2>/dev/null || sed -i '' 's/^sha256   = "0/sha256   = "/' config/ci-mirror.toml
bin/test-harness.sh | tail -1                          # expect: ALL HARNESS TESTS PASSED
```

- [ ] **Step 5: Commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add config/ci-mirror.toml bin/test-harness.sh
git commit -m "Add CI mirror command registry with a ci.yml drift tripwire

Fork CI cannot gate a nightshift PR: confirmed empirically that every
blacksmith-4vcpu job queues indefinitely on the fork while only the
ubuntu/macos-latest jobs run. The Blacksmith subset is precisely what matters
for janitorial diffs, so a local replica is the real pre-PR gate.

Records ci.yml's hash rather than parsing the workflow at runtime; the harness
test fails loudly on drift and forces a human to re-sync the commands."
```

---

### Task 5: Mirror the formatting and registry jobs

These two are the highest-value part of the mirror: without them, essentially every fork PR fails CI on formatting alone.

**Files:**
- Create: `lib/cimirror.sh`
- Modify: `bin/nightshift.sh:22` (source it)
- Modify: `lib/tier1.sh` (use CI's exact fmt invocation)

**Interfaces:**
- Produces: `cimirror_job <job-name> <outfile>` — runs one `[jobs.<name>]` entry's commands in `$REPO` with the repo dev binary first on PATH, appending combined output to `<outfile>`. Returns the first nonzero exit code, or 0.
- Produces: `cimirror_fmt_cmd` — prints CI's exact fmt command string, so tier-1 and the mirror cannot drift from each other.
- Produces: `cimirror_all <outfile>` — runs every job in config order, stops at the first failure, returns its code. Used in Task 7.
- Consumed by: `lib/verify.sh` (Task 7), `lib/tier1.sh` (this task).

- [ ] **Step 1: Create `lib/cimirror.sh`**

```bash
# shellcheck shell=bash
# lib/cimirror.sh — local replica of the ci.yml jobs a FORK PR cannot reach.
#
# 13 of ~16 ci.yml jobs run on blacksmith-4vcpu-ubuntu-2404, runners attached to the upstream
# org. On the fork they queue forever (confirmed 2026-07-30), so fork CI is not a pre-PR gate
# and this file is. Commands live in config/ci-mirror.toml next to a hash of ci.yml;
# bin/test-harness.sh fails when that hash drifts.

CI_MIRROR_CONFIG="$NS_ROOT/config/ci-mirror.toml"

# Print the commands of one [jobs.<name>] table, one per line.
cimirror_cmds() {
    ns_jac cimirror cmds "$1" "$CI_MIRROR_CONFIG"
}

# CI's exact fmt invocation, single source of truth for both tier-1 and the mirror.
cimirror_fmt_cmd() {
    cimirror_cmds fmt | head -1
}

# Run one mirrored job. Repo dev binary first on PATH so `jac` means the target repo's jac.
cimirror_job() {
    local job=$1 out=$2 cmd rc=0 first_rc=0
    ns_log MIRROR "job $job"
    while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue
        printf '\n$ %s\n' "$cmd" >> "$out"
        ( cd "$REPO" && export PATH="$(dirname "$NS_PATHS_JAC_REPO"):$PATH" \
            && eval "$cmd" ) >> "$out" 2>&1 || rc=$?
        if [ "$rc" -ne 0 ] && [ "$first_rc" -eq 0 ]; then
            first_rc=$rc
            ns_log MIRROR "job $job: command failed (rc=$rc): $cmd"
        fi
        rc=0
    done < <(cimirror_cmds "$job")
    return "$first_rc"
}

# Run every mirrored job in config order, stopping at the first failure.
# Fail-fast on purpose: a formatting failure makes the ~40min test jobs pointless.
cimirror_all() {
    local out=$1 job
    : > "$out"
    for job in $(ns_jac cimirror jobs "$CI_MIRROR_CONFIG"); do
        if ! cimirror_job "$job" "$out"; then
            ns_log MIRROR "FAILED at job $job — skipping the rest"
            echo "$job" > "$LOG_DIR/mirror-failed-job.txt"
            return 1
        fi
    done
    rm -f "$LOG_DIR/mirror-failed-job.txt"
    ns_log MIRROR "all jobs green"
    return 0
}
```

- [ ] **Step 2: Create the Jac reader `scripts/cimirror.jac`**

```jac
"""Read config/ci-mirror.toml. bash owns process sequencing; Jac owns the data (project rule).

argv:
  jobs <ci-mirror.toml>          print each [jobs.*] table name, in file order
  cmds <job> <ci-mirror.toml>    print that job's commands, one per line
  hash <ci-mirror.toml>          print the recorded ci.yml sha256
"""
import sys;
import from nslib { eprint, load_config_toml }

def job_names(cfg: dict) -> list[str] {
    return [str(k) for k in cfg["jobs"].keys()];
}

def job_cmds(cfg: dict, job: str) -> list[str] {
    return [str(c) for c in cfg["jobs"][job]["commands"]];
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "jobs" and len(args) == 3 {
        for n in job_names(load_config_toml(args[2])) {
            print(n);
        }
    } elif cmd == "cmds" and len(args) == 4 {
        for c in job_cmds(load_config_toml(args[3]), args[2]) {
            print(c);
        }
    } elif cmd == "hash" and len(args) == 3 {
        print(str(load_config_toml(args[2])["source"]["sha256"]));
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run cimirror.jac jobs|hash <ci-mirror.toml>");
        eprint("       jac run cimirror.jac cmds <job> <ci-mirror.toml>");
    }
}

test "every mirrored job has at least one command" {
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    names: list[str] = job_names(cfg);
    assert len(names) >= 5;
    for n in names {
        assert len(job_cmds(cfg, n)) >= 1;
    }
}

test "the fmt command is CI's exact invocation, not jac format" {
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    fmt: str = job_cmds(cfg, "fmt")[0];
    assert "jac fmt --check --lintfix" in fmt;
    assert "/fixtures/" in fmt and "_syntax_err" in fmt;
    assert "jac format" not in fmt;
    assert "jac lint --fix" not in fmt;
}
```

- [ ] **Step 3: Run the tests, register the script**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/cimirror.jac
```

Expected: PASS, two tests. Then add `cimirror` to the sweep list at `bin/test-harness.sh:13`.

- [ ] **Step 4: Source `cimirror.sh` in the entry point**

`bin/nightshift.sh`, after line 22:

```bash
. "$NS_ROOT/lib/cimirror.sh"
```

- [ ] **Step 5: Fix tier-1 to use CI's exact fmt invocation**

Read `lib/tier1.sh` and replace the `jac format .` / `jac lint --fix` step with CI's command, so tier-1 produces exactly the formatting CI demands:

```bash
    # CI's EXACT command (config/ci-mirror.toml [jobs.fmt]). `jac format .` / `jac lint --fix`
    # are NOT the same thing, and a fork PR gets no autofix rescue (ci.yml:303 is same-repo only),
    # so anything tier-1 leaves unformatted becomes a hard CI failure at ci.yml:342.
    ( cd "$REPO" && export PATH="$(dirname "$NS_PATHS_JAC_REPO"):$PATH" \
        && eval "$(cimirror_fmt_cmd | sed 's/ --check//')" ) || true
```

Note the `--check` strip: tier-1 *applies* the formatting, the mirror *verifies* it. Same command otherwise, derived from one source.

- [ ] **Step 6: Verify the fmt job runs against the real repo**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
NS_ROOT="$PWD" bash -c '. lib/common.sh; ns_load_config; . lib/cimirror.sh
  LOG_DIR="/tmp/ns-mirror"; mkdir -p "$LOG_DIR"; date +%s > "$LOG_DIR/start_epoch"
  cimirror_job fmt /tmp/ns-mirror/fmt.txt; echo "rc=$?"'
tail -20 /tmp/ns-mirror/fmt.txt
```

Expected: `rc=0` on a clean main checkout. A nonzero rc here means main itself is unformatted under this command; capture the output and confirm against a real CI run before assuming the mirror is wrong.

- [ ] **Step 7: Verify the jir job**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
NS_ROOT="$PWD" bash -c '. lib/common.sh; ns_load_config; . lib/cimirror.sh
  LOG_DIR="/tmp/ns-mirror"; cimirror_job jir /tmp/ns-mirror/jir.txt; echo "rc=$?"'
cat /tmp/ns-mirror/jir.txt
```

Expected: `rc=0`. If the script path is wrong, fix `config/ci-mirror.toml` and re-run.

- [ ] **Step 8: Run the harness suite and commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add lib/cimirror.sh scripts/cimirror.jac lib/tier1.sh bin/nightshift.sh bin/test-harness.sh
git commit -m "Mirror CI's formatting and jir-registry jobs locally

Formatting is the failure mode that would kill essentially every nightshift PR:
the jac fmt autofix bot at ci.yml:303 only pushes to same-repo PR branches, so a
fork PR gets no rescue and hits the hard failure at ci.yml:342 instead. Tier-1
was running \`jac format .\` / \`jac lint --fix\`, which is not CI's
\`jac fmt --check --lintfix\` with its exclusion regex. Both now derive from one
source in config/ci-mirror.toml.

Also mirrors the jir_registry check, which a dead-code deletion can invalidate."
```

---

### Task 6: Mirror the test jobs, including the never-gated equivalence suite

`pkg_test_raw` predates the restructure and omits the cross-backend equivalence suite entirely.

**Files:**
- Modify: `lib/verify.sh:13-25` (`pkg_test_raw` becomes mirror-driven)
- Modify: `lib/verify.sh:38-47` (`gated_pkgs_from_diff` for the new layout)
- Modify: `lib/verify.sh:51-62` (`baseline_main` records the union of two runs)
- Modify: `scripts/testgate.jac` (add a `record-union` verb)

**Interfaces:**
- Consumes: `cimirror_job` (Task 5).
- Produces: `jac run scripts/testgate.jac record-union <pkg> <raw1.txt> <raw2.txt> <baseline_dir>` — records the UNION of failing ids across two runs, so a test that flakes in either run is baselined and stops reding branches.
- Produces: `gated_suites_from_diff` replacing `gated_pkgs_from_diff` — emits mirror job names (`compiler`, `runtime`), not package names.

- [ ] **Step 1: Write the failing test for `record-union` in `scripts/testgate.jac`**

```jac
test "record-union baselines a test that fails in EITHER run" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    r1: str = d + "/r1.txt";
    with open(r1, "w") as f {
        f.write("FAILED t.jac::always\nFAILED t.jac::flaky_a\n");
    }
    r2: str = d + "/r2.txt";
    with open(r2, "w") as f {
        f.write("FAILED t.jac::always\nFAILED t.jac::flaky_b\n");
    }
    n: int = record_union("pkg", r1, r2, d);
    assert n == 3;
    # a branch that reproduces only the known set is green
    with open(d + "/ok.txt", "w") as f {
        f.write("FAILED t.jac::always\nFAILED t.jac::flaky_b\n");
    }
    (c, new_fails) = gate("pkg", d + "/ok.txt", d);
    assert c == 0 and new_fails == [];
    # a genuinely new failure is still red
    with open(d + "/bad.txt", "w") as f {
        f.write("FAILED t.jac::always\nFAILED t.jac::regression\n");
    }
    (c2, n2) = gate("pkg", d + "/bad.txt", d);
    assert c2 == 1 and n2 == ["t.jac::regression"];
}
```

- [ ] **Step 2: Run it, expect failure**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/testgate.jac
```

Expected: FAIL — `record_union` undefined.

- [ ] **Step 3: Implement `record_union` in `scripts/testgate.jac`**

Add next to `record`:

```jac
"""Baseline the UNION of two main-branch runs. A test that fails in either run is treated as
known-failing, which is the fix for the observed failure mode where the same branch reded on
run 1, passed on run 2, and burned 2h of the night in retries (nights 07-21 and 07-23)."""
def record_union(pkg: str, raw1: str, raw2: str, baseline_dir: str) -> int {
    os.makedirs(baseline_dir, exist_ok=True);
    ids: list[str] = sorted(set(failing_ids(read_file(raw1))) | set(failing_ids(read_file(raw2))));
    with open(baseline_path(baseline_dir, pkg), "w") as f {
        f.write(json.dumps({"package": pkg, "failing": ids, "count": len(ids), "runs": 2}, indent=2) + "\n");
    }
    return len(ids);
}
```

Add the dispatch branch in `with entry`, next to `record`:

```jac
    } elif cmd == "record-union" and len(args) == 6 {
        print(record_union(args[2], args[3], args[4], args[5]));
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/testgate.jac
```

Expected: PASS, all tests including the two pre-existing ones.

- [ ] **Step 5: Rewrite `pkg_test_raw` to run mirror jobs**

Replace `lib/verify.sh:13-25`:

```bash
# Run one mirrored TEST suite's commands, combined output to <out>. The runner's own exit code
# is ignored on purpose -- baseline failures are expected, and testgate.jac decides pass/fail on
# NEW failures only. Suite names are mirror job names from config/ci-mirror.toml.
# The bundled test runner needs a clean HOME or its conftest import fails.
suite_test_raw() {
    local suite=$1 out=$2 H; H="$(mktemp -d)"; : > "$out"
    HOME="$H" cimirror_job "$suite" "$out" || true
}
```

Delete the old `jac-byllm` / `jac-scale` cases; those packages no longer exist as top-level dirs, and `[jobs.byllm]` (added in Task 4) now carries the byllm suite.

- [ ] **Step 6: Rewrite the diff-to-suite routing**

Replace `gated_pkgs_from_diff` (lines 38-47):

```bash
# Map changed paths to the mirrored TEST suites that cover them. Post-restructure geography:
# byllm and scale live under jac/jaclang/, and jac-mcp has no suite of its own (a recorded
# baseline confirmed "no tests ran"), so an mcp-only change gets no test gate -- the fmt, jir,
# and contribution jobs still gate it.
# ORDER MATTERS: the byllm and compiler cases must precede the jac/* catch-all, or a byllm-only
# change routes to the large, env-flaky runtime suite. That exact mis-routing (via `cut -d/ -f1`)
# is why the old function existed in the shape it did.
gated_suites_from_diff() {
    git -C "$REPO" diff --name-only "$NS_REPO_DEFAULT_BRANCH...HEAD" | while IFS= read -r p; do
        case "$p" in
            jac/jaclang/compiler/*) echo compiler ;;
            jac/jaclang/byllm/*)    echo byllm ;;
            jac-mcp/*)              ;;                 # no suite
            release_notes/*)        ;;                 # fragment only
            jac/*)                  echo runtime ;;
        esac
    done | sort -u
}
```

Then update the loop in `verify_branch` (lines 143-169) to iterate `gated_suites_from_diff` and call `suite_test_raw`, keeping the exit-code-2 (no baseline) and single-retry behavior exactly as it is. The `rc -eq 2` distinction is load-bearing: conflating it with `rc -ne 0` once rejected a safe branch as "new test failures" when the truth was "no baseline recorded."

- [ ] **Step 7: Rewrite `baseline_main` for two runs and the new suite names**

```bash
# Record the per-suite baseline of already-failing tests on main, as the UNION of TWO runs so a
# flaky test is baselined instead of reding branches. Slow (two full suite runs each); run once
# after migration and after any major upstream sync. `nightshift.sh baseline`.
baseline_main() {
    mkdir -p "$BASELINE_DIR"
    cd "$REPO"; git checkout "$NS_REPO_DEFAULT_BRANCH"
    local suite raw1 raw2 n
    for suite in compiler runtime byllm; do
        raw1="$LOG_DIR/baseline-raw-$suite-1.txt"
        raw2="$LOG_DIR/baseline-raw-$suite-2.txt"
        ns_log BASELINE "recording $suite, run 1 of 2 (slow)..."
        suite_test_raw "$suite" "$raw1"
        ns_log BASELINE "recording $suite, run 2 of 2 (slow)..."
        suite_test_raw "$suite" "$raw2"
        n="$(ns_jac testgate record-union "$suite" "$raw1" "$raw2" "$BASELINE_DIR")"
        ns_log BASELINE "$suite: $n known-failing tests recorded (union of 2 runs)"
    done
}
```

- [ ] **Step 8: Delete the stale baselines**

They predate the restructure and name packages that no longer exist:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && git rm state/test-baseline/jac.json state/test-baseline/jac-byllm.json
```

- [ ] **Step 9: Verify the routing logic without running the suites**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bash -n lib/verify.sh && echo "syntax ok"
NS_ROOT="$PWD" bash -c '
  . lib/common.sh; ns_load_config
  REPO="$PWD/work/repo"; NS_REPO_DEFAULT_BRANCH=main
  route() {
      printf "%s\n" jac/jaclang/compiler/x.jac jac/jaclang/runtimelib/y.jac \
                    jac/jaclang/byllm/b.jac jac-mcp/z.jac release_notes/unreleased/jaclang/0000.refactor.md \
        | while IFS= read -r p; do case "$p" in
            jac/jaclang/compiler/*) echo compiler ;;
            jac/jaclang/byllm/*)    echo byllm ;;
            jac-mcp/*)              ;;
            release_notes/*)        ;;
            jac/*)                  echo runtime ;;
          esac; done | sort -u
  }
  route'
```

Expected exactly three lines: `byllm`, `compiler`, `runtime`. Critically, `jac-mcp/z.jac` and the fragment must produce nothing, and the byllm path must NOT also produce `runtime`.

- [ ] **Step 10: Record the real baselines**

Slow: six full suite runs (three suites x two runs), plausibly 4-5h given 21-43min per run for the big ones. Run it in the background and check back rather than blocking:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/nightshift.sh baseline
```

Expected: `state/test-baseline/compiler.json`, `runtime.json`, and `byllm.json`, each with `"runs": 2`.

Sanity-check the result rather than accepting it:
- A `count` of 0 for `runtime` or `compiler` would be surprising given the repo's known env-dependent failures. Investigate before trusting it.
- Compare run 1 against run 2 to see how much flake the union actually absorbed:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
for s in compiler runtime byllm; do
  a="$(jac run scripts/testgate.jac parse "logs/$(date +%F)/baseline-raw-$s-1.txt" | sort)"
  b="$(jac run scripts/testgate.jac parse "logs/$(date +%F)/baseline-raw-$s-2.txt" | sort)"
  echo "$s: run1=$(echo "$a" | grep -c .) run2=$(echo "$b" | grep -c .) flaky=$(comm -3 <(echo "$a") <(echo "$b") | grep -c .)"
done
```

A large `flaky` count is the quantified version of the 07-21/07-23 failure mode and is worth noting in the commit message.

- [ ] **Step 11: Commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add lib/verify.sh scripts/testgate.jac state/test-baseline config/ci-mirror.toml
git commit -m "Drive the test gate from the CI mirror; baseline the union of two runs

pkg_test_raw named packages that no longer exist and omitted the cross-backend
equivalence suite (jac test jaclang/compiler/tests) entirely, so it has never
been gated locally despite being a CI job. Test running now goes through the
mirror, so the gate and CI cannot drift.

Baselines record the UNION of two main-branch runs. A test that flakes in either
run is treated as known-failing, which is the fix for nights 07-21 and 07-23:
the same branch reded on run 1, passed on run 2, and burned 2h in retries.
Deletes the pre-restructure jac/jac-byllm baselines."
```

---

### Task 7: Wire the mirror into the S4 gate

The mirror runs before the expensive suites, so a formatting or registry failure costs seconds instead of 40 minutes.

**Files:**
- Modify: `lib/verify.sh:81-191` (`verify_branch` gate order)
- Modify: `bin/nightshift.sh` (add a `mirror` command for manual runs)
- Modify: `bin/test-harness.sh` (mirror-ordering assertion)

**Interfaces:**
- Consumes: `cimirror_job`, `cimirror_all` (Task 5), `suite_test_raw`, `gated_suites_from_diff` (Task 6).
- Produces: `nightshift.sh mirror [branch]` — runs the full mirror against a branch (or the current checkout) and prints the failing job. For hand-debugging a red branch.

- [ ] **Step 1: Insert the fast mirror jobs into `verify_branch`**

After the existing step 2 (`checkgate`) and *before* the test loop, add:

```bash
    # 3. FAST mirror jobs first (seconds): formatting and the generated registry. A fork PR gets
    #    no jac fmt autofix (ci.yml:303 is same-repo only) and dies at ci.yml:342, so a branch
    #    that fails these is dead on arrival -- reject it before spending ~40min on the suites.
    local mrr="$LOG_DIR/mirror-fast-$(basename "$branch").txt"
    : > "$mrr"
    local fastjob
    for fastjob in fmt jir; do
        if ! cimirror_job "$fastjob" "$mrr"; then
            verify_red "$branch" "CI mirror job '$fastjob' red (see $(basename "$mrr"))"
            return 1
        fi
    done
```

Renumber the existing comments: the test loop becomes step 4, pre-commit step 5.

- [ ] **Step 2: Replace step 4's package loop with the suite loop**

Change the loop header from `for tpkg in $(gated_pkgs_from_diff)` to `for tpkg in $(gated_suites_from_diff)` and the two `pkg_test_raw "$tpkg" "$raw"` calls to `suite_test_raw "$tpkg" "$raw"`. Leave the `rc -eq 2` handling and the single flaky retry exactly as they are.

- [ ] **Step 3: Run the contribution job as the last gate**

Replace the standalone `ns_precommit run --all-files` block (step 4 in the current numbering, lines 172-180) with the mirror's `contribution` job, keeping the self-mutation fold:

```bash
    # 5. contribution-checks: release-note fragments + pre-commit. Hooks may self-mutate; fold the
    #    result in and demand a clean second pass.
    local cj="$LOG_DIR/mirror-contribution-$(basename "$branch").txt"
    if ! cimirror_job contribution "$cj"; then
        git add -A
        git diff --cached --quiet || git commit -m "style: pre-commit autofix (nightshift)"
        if ! cimirror_job contribution "$cj"; then
            verify_red "$branch" "CI mirror job 'contribution' red (see $(basename "$cj"))"
            return 1
        fi
    fi
```

- [ ] **Step 4: Update the green tests line**

Replace the `echo "jac check ✓ · tests ..."` line so the draft and digest report what actually ran:

```bash
    echo "mirror fmt+jir ✓ · jac check ✓ · suites ($(gated_suites_from_diff | tr '\n' ' ')) no new failures vs baseline ✓ · contribution ✓ (${dur_min} min)" \
        > "$LOG_DIR/tests-$(basename "$branch").txt"
```

- [ ] **Step 5: Add the `mirror` command to `bin/nightshift.sh`**

In `usage()`:

```
       nightshift.sh mirror [branch]             # run the full CI mirror against a branch
```

In the `case`:

```bash
    mirror)     mkdir -p "$LOG_DIR"
                if [ $# -ge 1 ]; then git -C "$REPO" checkout "$1"; fi
                cimirror_all "$LOG_DIR/mirror-manual.txt"; rc=$?
                [ -f "$LOG_DIR/mirror-failed-job.txt" ] \
                    && echo "failed job: $(cat "$LOG_DIR/mirror-failed-job.txt")" >&2
                tail -40 "$LOG_DIR/mirror-manual.txt"; exit "$rc" ;;
```

- [ ] **Step 6: Assert the gate order in `bin/test-harness.sh`**

Ordering is a correctness property here: a mirror that runs after the suites wastes 40 minutes per doomed branch. Add before the final echo:

```bash
echo "== 6. S4 gate order: fast mirror jobs precede the test suites =="
fast_ln="$(grep -n 'for fastjob in fmt jir' lib/verify.sh | cut -d: -f1)"
test_ln="$(grep -n 'for tpkg in \$(gated_suites_from_diff)' lib/verify.sh | cut -d: -f1)"
[ -n "$fast_ln" ] && [ -n "$test_ln" ] || fail "gate order markers not found in lib/verify.sh"
[ "$fast_ln" -lt "$test_ln" ] || fail "fast mirror jobs must run BEFORE the test suites"
echo "gate order correct (fmt/jir at line $fast_ln, suites at $test_ln)"
```

- [ ] **Step 7: Run the harness suite**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
```

Expected: `ALL HARNESS TESTS PASSED`, including sections 5 and 6.

- [ ] **Step 8: Prove the gate on a real branch that must fail**

Create a deliberately misformatted branch and confirm the mirror rejects it in seconds rather than after the suites:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo
git checkout -B nightshift/mirror-probe main
printf '\n\ndef   badly_formatted( x:int )->int {return  x;}\n' >> jac/jaclang/utils/treeprinter.jac
git commit -aqm "probe: deliberate formatting violation"
cd /Volumes/ExtremePro/JaseciLabs/NightShift
time bin/nightshift.sh mirror nightshift/mirror-probe; echo "exit=$?"
```

Expected: nonzero exit, `failed job: fmt`, elapsed well under a minute. If it instead runs the test suites, the ordering change did not take effect.

- [ ] **Step 9: Clean up the probe branch**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift/work/repo \
  && git checkout -f main && git branch -D nightshift/mirror-probe
```

- [ ] **Step 10: Commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add lib/verify.sh bin/nightshift.sh bin/test-harness.sh
git commit -m "Gate every branch on the CI mirror, fast jobs first

Gate order is now: scope containment, jac check baseline-diff, fast mirror jobs
(fmt, jir), test suites, contribution checks. Formatting and registry failures
are fatal for a fork PR and cost seconds to detect, so checking them before the
~40min suites saves the night on a doomed branch. bin/test-harness.sh asserts
that ordering, since getting it backwards is silently expensive rather than
visibly broken.

Adds \`nightshift.sh mirror [branch]\` for hand-debugging a red branch."
```

---

## Remaining plans

This plan deliberately stops at "the harness tells the truth and gates faithfully." The spec's other subsystems each produce working software on their own and get their own plan, written when their turn comes so each is informed by what the previous one actually found. Writing them all now would bake in guesses about facts Plan 1 is about to establish (most importantly whether `gh pr create` works against upstream with pull-only permission, which Plan 3 is built on).

**Plan 2 — Task registry (spec 3, 5, 11, 13).** `[tasks.*]` config, four audit prompts, shared apply prompt with per-task rules, `scoring` modes in `selector.jac`, per-task `protect_unless` in `check_scope.jac` (the security-critical piece), `complexity` tagging and Opus/Sonnet routing, the four-night cycle scheduler with carry-over, and `scripts/covmap.jac` for the coverage task's evidence.

**Plan 3 — Ship path (spec 6, 8, 9, 12).** Draft PRs upstream, `scripts/cigate.jac` CI baseline-diff, the CI repair loop with its two bounded attempts, terminal handling (close PR, delete branch, `failed_ci`), and S1.6 PR inventory maintenance.

**Plan 4 — Reactive pass and digest (spec 10, 14).** Merge polling, the four-lens reactive pass over merged-PR files, HTML digest with finding detail, and the SMTP fix that has never once worked.

**Plan 5 — Migration, reset, cutover (spec 15, 16, 17).** Move to `~/nightshift`, new plist at 23:00 with the 8h ceiling and no osascript, missed-night diagnosis, the branch reset behind a second confirmation, and the dry-run-only overlap of the old harness.

**Separate spec — coverage instrumentation (spec 11 Phase B).** Real line coverage as a Jac compiler pass, developed as a fork-local measurement branch and an upstream feature PR. This is a compiler feature in a repo you do not control, not harness work, and needs its own brainstorm and spec.
