# Step 7 — S4 Verify gate + scope containment (fail-closed)

## Goal

The harness's central invariant: **never ship a broken branch** (PRD goal 1) and
**never ship a diff that escaped its declared scope** (threat T1's backstop). Two
pieces: `scripts/check_scope.jac` (pure gate: changed paths vs theme allow-list vs
protected globs) and `lib/verify.sh` (per-branch pipeline: scope → `jac check` →
full `pytest jac -n auto` with one retry of failures → `pre-commit`; red ⇒ branch
deleted + ledger `failed_verify` + email autopsy line). Implements TechnicalPRD
§7-S4 and the §12 failure rows.

## Prerequisites

Steps 2–3 (nslib, ledger). Consumes `queue.tsv` produced by steps 6 and 11.

## Files created

```
~/nightshift/scripts/check_scope.jac
~/nightshift/lib/verify.sh
```

## Gate order (why it matters)

1. **Scope containment first** — costs milliseconds and rejects a possibly
   adversarial diff *before* spending an hour of tests on it. A diff touching any
   file outside the theme's declared list, or inside a protected glob, is discarded
   **no matter how green the tests are**.
2. `jac check` — whole-program type check (minutes).
3. `pytest jac -n auto` — the full suite, the expensive one; one automatic retry of
   only-the-failures absorbs flakes (PRD §11).
4. `pre-commit` — with the self-mutation fold-in (commit the hook's fixes, demand a
   clean second pass).

## Full implementation

### `scripts/check_scope.jac`

```jac
"""S4 scope-containment gate (TechnicalPRD 7-S4, threat T1 backstop).

stdin: newline-separated changed paths (git diff --name-only main...HEAD).
argv:  check <theme.json> <config.toml>       theme-scoped gate (apply branches)
       protected <config.toml>                print the stdin paths that hit a protected glob
                                              (tier-1 uses this to revert formatter overreach)
Exit 0 = diff contained; exit 1 = violation(s), one `VIOLATION <path> <reason>` line each.
A diff outside the theme's declared files or inside a protected glob is rejected
no matter how green the tests are.
"""
import sys;
import from nslib { eprint, read_stdin, parse_obj, is_protected, load_globs, release_fragment }

def violations(changed: list[str], theme: dict, globs: list[str]) -> list[str] {
    allowed: list[str] = [str(f) for f in theme["files"]];
    allowed.append(release_fragment(str(theme["package"])));
    out: list[str] = [];
    for path in changed {
        if path not in allowed {
            out.append("VIOLATION " + path + " not-in-theme-allowlist");
        } elif is_protected(path, globs) {
            out.append("VIOLATION " + path + " protected-glob");
        }
    }
    return out;
}

with entry {
    args: list[str] = sys.argv;
    if len(args) == 4 and args[1] == "check" {
        with open(args[2], "r") as f {
            theme: dict = parse_obj(f.read());
        }
        changed: list[str] = [l.strip() for l in read_stdin().splitlines() if l.strip()];
        found: list[str] = violations(changed, theme, load_globs(args[3]));
        for v in found {
            print(v);
        }
        sys.exit(1 if found else 0);
    } elif len(args) == 3 and args[1] == "protected" {
        globs2: list[str] = load_globs(args[2]);
        for path in [l.strip() for l in read_stdin().splitlines() if l.strip()] {
            if is_protected(path, globs2) {
                print(path);
            }
        }
    } elif len(args) > 1 and args[1] != "test" {
        eprint("usage: git diff --name-only main...HEAD | jac run check_scope.jac check <theme.json> <config.toml>");
        eprint("       git diff --name-only | jac run check_scope.jac protected <config.toml>");
    }
}

test "diff outside allow-list is a violation, fragment is allowed" {
    theme: dict = {"package": "jac-client", "files": ["jac-client/render/pipe.jac"]};
    globs: list[str] = ["**/tests/**"];
    changed: list[str] = [
        "jac-client/render/pipe.jac",
        "docs/docs/community/release_notes/unreleased/jac-client/0000.refactor.md",
        "jac-client/render/rogue.jac",
    ];
    found: list[str] = violations(changed, theme, globs);
    assert len(found) == 1;
    assert "rogue.jac" in found[0];
}

test "allowed file inside a protected glob is still rejected" {
    theme: dict = {"package": "jac", "files": ["jac/tests/fixtures/x.jac"]};
    found: list[str] = violations(["jac/tests/fixtures/x.jac"], theme, ["**/tests/**"]);
    assert len(found) == 1;
    assert "protected-glob" in found[0];
}
```

### `lib/verify.sh`

```bash
# shellcheck shell=bash
# lib/verify.sh — S4 (TechnicalPRD 7-S4): fail-closed gate. Any red after retry → branch deleted.

verify_main() {
    [ -f "$LOG_DIR/queue.tsv" ] || { ns_log S4 "no branches queued"; return 0; }
    local branch theme report shipped=0
    while IFS=$'\t' read -r branch theme report; do
        if verify_branch "$branch" "$theme"; then
            ns_mark_green "$branch" "$theme" "$report"
            shipped=$((shipped + 1))
        fi
    done < "$LOG_DIR/queue.tsv"
    if [ "$shipped" -eq 0 ] && [ -s "$LOG_DIR/queue.tsv" ]; then
        ns_log S4 "every queued branch failed the gate"
        return "$EX_ALLFAIL"
    fi
    return 0
}

# Gate order (each time-boxed): scope containment → jac check → pytest (one retry) → pre-commit.
verify_branch() {
    local branch=$1 theme=$2 t0 t1
    t0="$(date +%s)"
    cd "$REPO"
    git checkout "$branch"
    "$NS_PATHS_JAC" clean --cache || true

    # 1. scope containment FIRST — reject before spending a second on tests (anti-injection, T1)
    if [ "$theme" != "-" ]; then
        if ! git diff --name-only "$NS_REPO_DEFAULT_BRANCH...HEAD" \
                | ns_jac check_scope check "$theme" "$CONFIG" > "$LOG_DIR/scope-violations.txt"; then
            verify_red "$branch" "scope violation (possible prompt injection): $(head -3 "$LOG_DIR/scope-violations.txt" | tr '\n' ' ')"
            return 1
        fi
    fi

    # 2. whole-program type check
    if ! ns_timebox 10 "$NS_PATHS_JAC" check; then
        verify_red "$branch" "jac check red"
        return 1
    fi

    # 3. full test suite; one retry of only the failures (flaky-test policy, PRD 11)
    if ! ns_timebox "$NS_BUDGETS_BOX_VERIFY_MIN" "$NS_PATHS_VENV/bin/python" -m pytest jac -n auto -q; then
        ns_log S4 "pytest red — retrying only the failures once"
        if ! ns_timebox 15 "$NS_PATHS_VENV/bin/python" -m pytest jac --last-failed -q; then
            verify_red "$branch" "pytest red after retry"
            return 1
        fi
    fi

    # 4. pre-commit; if hooks self-mutate, fold the mutation in and demand a clean second pass
    if ! "$NS_PATHS_VENV/bin/pre-commit" run --all-files; then
        git add -A
        git diff --cached --quiet || git commit -m "style: pre-commit autofix (nightshift)"
        if ! "$NS_PATHS_VENV/bin/pre-commit" run --all-files; then
            verify_red "$branch" "pre-commit red"
            return 1
        fi
    fi

    # record the tests line for the draft, and self-tune the verify estimate (TPRD S3-B step 5)
    t1="$(date +%s)"
    local dur_min=$(( (t1 - t0) / 60 )); [ "$dur_min" -lt 1 ] && dur_min=1
    local old_est; old_est="$(ns_jac ledger state-get verify_estimate_min "$STATE" | tr -d '"')"
    ns_jac ledger state-set verify_estimate_min $(( ( ${old_est:-30} + dur_min ) / 2 )) "$STATE"
    echo "jac check ✓ · pytest jac -n auto ✓ · pre-commit ✓ (${dur_min} min)" \
        > "$LOG_DIR/tests-$(basename "$branch").txt"
    git checkout "$NS_REPO_DEFAULT_BRANCH"
    return 0
}

verify_red() {
    local branch=$1 why=$2 fp why_sane
    ns_fail "$branch" "$why"
    # reason goes into a JSON literal: strip the two characters that could break it
    why_sane="$(printf '%s' "$why" | tr -d '"\\')"
    # findings on this branch become failed_verify (attempts++; auto-rejected after 2, TPRD S3-B)
    ns_jac ledger by-branch "$branch" "$LEDGER" | while IFS= read -r fp; do
        ns_jac ledger set-status "$fp" failed_verify "$LEDGER" "{\"reason\":\"$why_sane\"}" >/dev/null
    done
    git checkout "$NS_REPO_DEFAULT_BRANCH"
    git branch -D "$branch" || true
}
```

## Commands

```bash
cd ~/nightshift
jac check scripts/check_scope.jac && jac test scripts/check_scope.jac
bash -n lib/verify.sh
```

## Acceptance criteria

- [ ] `jac test scripts/check_scope.jac` → both tests green (allow-list violation
      detected; allowed-but-protected file still rejected).
- [ ] CLI behaves fail-closed:
      ```bash
      printf '{"package":"jac-client","files":["jac-client/render/pipe.jac"]}' > /tmp/theme.json
      printf 'jac-client/render/pipe.jac\njac-client/render/rogue.jac\n' \
        | jac run scripts/check_scope.jac check /tmp/theme.json config/nightshift.toml
      # → VIOLATION jac-client/render/rogue.jac not-in-theme-allowlist ; exit 1
      ```
- [ ] The release-note fragment path for the theme's package is allowed without
      being in the theme's file list (the orchestrator adds it in step 11).
- [ ] `verify_branch` on a branch with a planted failing test deletes the branch,
      appends to `failed.tsv`, and flips that branch's ledger rows to
      `failed_verify` with `attempts` incremented.
- [ ] A green branch lands in `green.tsv` with a `tests-<slug>.txt` line, and
      `state.json`'s `verify_estimate_min` moves toward the observed duration.

## Verification procedure

Scope gate: the CLI checks above, plus the negation glob:

```bash
printf 'docs/docs/community/release_notes/unreleased/jac-client/0000.refactor.md\n' \
  | jac run scripts/check_scope.jac protected config/nightshift.toml   # prints nothing (exception glob)
printf 'docs/guide/intro.md\n' \
  | jac run scripts/check_scope.jac protected config/nightshift.toml   # prints the path
```

Full gate: create a branch off `main`, edit one in-theme file, run
`verify_branch nightshift/test-gate /tmp/theme.json` and watch each gate line in
the log. Then plant `assert False` in a test the suite runs, re-verify, and confirm
the red path (branch gone, ledger updated). The chaos/e2e coverage is step 14's.

## Notes & traps

- **The scope gate cannot be reasoned with**: it runs *outside* the agent, on
  `git diff --name-only` output. That's the point — prompt injection that convinces
  the agent to edit `~/.zshrc`-adjacent files still dies here (TechnicalPRD §11 T1
  layer c).
- Glob semantics: `**` crosses directories via `PurePosixPath.full_match`
  (Python ≥ 3.13 — jac 0.16.1 ships on 3.13). A later `!glob` in the list carves an
  exception out of earlier positives; order matters.
- pytest's retry uses `--last-failed`, which needs pytest's cache from the failing
  run — don't add `-p no:cacheprovider` to "clean things up".
- The verify-estimate update (`(old + observed) / 2`) is the self-tuning input to
  step 10's time projection. First night uses the default 30 min; it converges in
  two or three nights.
- `verify_red` sanitizes the reason string (`tr -d '"\\'`) because it lands inside
  a JSON literal — keep that if you reword messages.
