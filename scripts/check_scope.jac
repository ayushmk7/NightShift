"""S4 scope-containment gate (TechnicalPRD 7-S4, threat T1 backstop).

stdin: `check` mode: git diff --name-status output (STATUS<TAB>path per line).
argv:  check <theme.json> <config.toml> <task>  theme-scoped gate (apply branches). <task> is the
                                              name lib/common.sh's ns_task_of_branch derived from
                                              the BRANCH, and it -- not the theme -- decides
                                              whether this diff may write inside a protected glob.
       weakened <path> <old_file> <new_file>  reject a diff that REMOVES asserts or test blocks
                                              from an existing test file (exit 1), else print what
                                              was compared (OK ...) or that there was nothing to
                                              compare (SKIP ...)

A third verb, `protected <config.toml>`, was deleted with tier-1 on 2026-08-02: it printed the
stdin paths hitting a protected glob so the S2 autofix could revert formatter overreach, and it
had zero callers once that stage went away. `is_protected` itself is very much alive -- the
`check` arm above and the reactive scope filter both use it.
Exit 0 = diff contained; exit 1 = violation(s), one `VIOLATION <path> <reason>` line each.
A diff outside the theme's declared files or inside a protected glob is rejected
no matter how green the tests are -- UNLESS the path is in the theme's own
`vestigial_deletions` (selector.jac already independently verified, before the agent ever saw
this theme, that the file is entirely about code the theme is deleting) AND the change is a
clean deletion (status "D"), never a modification.
"""
import sys;
import re;
import from nslib {
    eprint, read_stdin, parse_obj, as_dict, as_list, is_protected, load_globs, fragment_path,
    load_config_toml, VALID_FRAGMENT_KINDS
}

"""Per-task write exemptions, read from the CONFIG FILE by task name.

THIS IS THE SECURITY BOUNDARY. The theme JSON is assembled from agent-authored findings, so
anything in it -- including a `task` key or a `protect_unless` list -- is attacker-controlled in
the T1 prompt-injection threat model this gate exists to backstop. The task name arrives as an
ARGV from bash, derived from the branch name the harness itself built (lib/common.sh
ns_task_of_branch), and the permission is looked up here, in this process, from the file on disk.
An audit session therefore cannot widen its own write scope by asking for it.

Presence of the key also means "and nothing else": a task that is allowed inside a protected glob
is allowed ONLY there. [tasks.coverage].fragment = "" says the same thing from the other side --
its output is tests, so it needs no release note.

An unknown task RAISES. Returning [] would be the same permission set a task with no exemption
gets, so the gate would look like it was working while a typo'd or unresolved task silently ran
under dead-code's rules -- and, worse, a future task that legitimately needs an exemption would be
rejected for reasons nobody could see from the output."""
def protect_unless(config_path: str, task: str) -> list[str] {
    tasks: dict = as_dict(load_config_toml(config_path).get("tasks", {}));
    if task not in tasks {
        raise ValueError("unknown task: " + task);
    }
    return [str(g) for g in as_list(as_dict(tasks[task]).get("protect_unless", []))];
}

# `unless` has NO default on purpose: every call site must state which task's permissions it is
# gating under. A default of [] would let a new caller forget it and silently gate every branch as
# "no exemption", which rejects every coverage branch -- fail-closed, but invisibly so.
def violations(changed: list[tuple[str, str]], theme: dict, globs: list[str],
               unless: list[str]) -> list[str] {
    theme_files: list[str] = [str(f) for f in theme["files"]];
    allowed: list[str] = list(theme_files);
    # The ORCHESTRATOR writes the fragment, but the gate must still let it through. `auto`
    # (the maintenance task) means the AGENT picks the kind and the harness validates it, so all
    # five legal names are allowed here -- the directory and the 0000 stem are fixed either way,
    # which is what CI's filename regex actually checks. "" means the task needs no fragment and
    # therefore may not write one. Any other value allows exactly that one name, and
    # fragment_path clamps an invalid one to refactor, so a tampered theme cannot smuggle an
    # arbitrary filename past the regex CI enforces.
    kind: str = str(theme.get("fragment_kind", "refactor"));
    kinds: list[str] = VALID_FRAGMENT_KINDS if kind == "auto" else [kind];
    for k in kinds {
        frag: str = fragment_path(theme_files, k);
        if frag and frag not in allowed {
            allowed.append(frag);
        }
    }
    vestigial: list[str] = [str(f) for f in as_list(theme.get("vestigial_deletions", []))];
    out: list[str] = [];
    for (status, path) in changed {
        if path in vestigial {
            if status != "D" {
                out.append("VIOLATION " + path + " vestigial-deletion-must-be-a-clean-delete-not-" + status);
            }
            continue;
        }
        if path not in allowed {
            out.append("VIOLATION " + path + " not-in-theme-allowlist");
        } elif unless and not is_protected(path, unless) {
            # A task with an exemption writes ONLY inside it.
            out.append("VIOLATION " + path + " task-writes-tests-only");
        } elif is_protected(path, globs) and not is_protected(path, unless) {
            out.append("VIOLATION " + path + " protected-glob");
        }
    }
    return out;
}

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

def parse_name_status(text: str) -> list[tuple[str, str]] {
    out: list[tuple[str, str]] = [];
    for line in text.splitlines() {
        stripped: str = line.strip();
        if not stripped {
            continue;
        }
        parts: list[str] = stripped.split("\t");
        if len(parts) >= 2 {
            # a rename shows as "R100\told\tnew"; treat as delete-old + not-tracked-new is out of
            # scope here (renames never come from this pipeline), so only ever consume 2 parts.
            out.append((parts[0][:1], parts[-1]));
        }
    }
    return out;
}

with entry {
    args: list[str] = sys.argv;
    if len(args) == 5 and args[1] == "check" {
        with open(args[2], "r") as f {
            theme: dict = parse_obj(f.read());
        }
        changed: list[tuple[str, str]] = parse_name_status(read_stdin());
        found: list[str] = violations(changed, theme, load_globs(args[3]),
                                      protect_unless(args[3], args[4]));
        for v in found {
            print(v);
        }
        sys.exit(1 if found else 0);
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
            # PRINT what was compared. Silence on success is indistinguishable from a guard that
            # returned early, and lib/verify.sh logs a count it would otherwise have no way to
            # justify -- the did-not-run-scored-as-passed shape, in the stage that exists to catch
            # exactly that in the agent's work.
            (chk_a, chk_t) = test_strength(old_text);
            if chk_t == 0 {
                print("SKIP " + args[2] + " no test blocks on the default branch");
            } else {
                print("OK " + args[2] + " " + str(chk_a) + " asserts / " + str(chk_t) + " tests preserved");
            }
        }
        sys.exit(1 if found2 else 0);
    } elif len(args) > 1 and args[1] != "test" {
        eprint("usage: git diff --name-status main...HEAD | jac run check_scope.jac check <theme.json> <config.toml> <task>");
        eprint("       jac run check_scope.jac weakened <path> <old_file> <new_file>");
        # NONZERO, and deliberately not 1 (which means "violations found"). This arm used to exit
        # 0, so any future arity drift -- exactly the kind Task 6 is about to introduce when
        # `check` grows a <task> argv -- would make lib/verify.sh's `if ! ... check_scope`
        # succeed and report the diff as CONTAINED. A gate that cannot parse its own arguments
        # must never be the reason a branch passes. (RECONCILIATION B8.)
        sys.exit(2);
    }
}

test "diff outside allow-list is a violation, fragment is allowed" {
    theme: dict = {"package": "jac", "files": ["jac/jaclang/cli/pipe.jac"]};
    globs: list[str] = ["**/tests/**"];
    changed: list[tuple[str, str]] = [
        ("M", "jac/jaclang/cli/pipe.jac"),
        ("A", "release_notes/unreleased/jaclang/0000.refactor.md"),
        ("M", "jac/jaclang/cli/rogue.jac"),
    ];
    found: list[str] = violations(changed, theme, globs, []);
    assert len(found) == 1;
    assert "rogue.jac" in found[0];
}

test "allowed file inside a protected glob is still rejected" {
    theme: dict = {"package": "jac", "files": ["jac/tests/fixtures/x.jac"]};
    found: list[str] = violations([("M", "jac/tests/fixtures/x.jac")], theme, ["**/tests/**"], []);
    assert len(found) == 1;
    assert "protected-glob" in found[0];
}

test "vestigial deletion is allowed only as a clean delete, modifying it is still rejected" {
    theme: dict = {"package": "jac", "files": ["jac/pkg/gateway.jac"],
        "vestigial_deletions": ["jac/pkg/tests/test_gateway.jac"]};
    globs: list[str] = ["**/tests/**"];
    ok: list[str] = violations([("D", "jac/pkg/tests/test_gateway.jac")], theme, globs, []);
    assert ok == [];
    bad: list[str] = violations([("M", "jac/pkg/tests/test_gateway.jac")], theme, globs, []);
    assert len(bad) == 1 and "must-be-a-clean-delete" in bad[0];
}

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

test "a NON-auto theme may write only its own kind's fragment name" {
    # The half that stops the `auto` widening from becoming an unconditional widening: a
    # dead-code theme declares `refactor`, so 0000.bugfix.md is out of its allow-list.
    theme: dict = {"files": ["jac/jaclang/cli/pipe.jac"], "fragment_kind": "refactor"};
    assert violations([("A", "release_notes/unreleased/jaclang/0000.refactor.md")], theme, [], []) == [];
    assert len(violations([("A", "release_notes/unreleased/jaclang/0000.bugfix.md")], theme, [], [])) == 1;
}

test "a task with fragment = '' may not write a fragment at all" {
    theme: dict = {"files": ["jac/jaclang/cli/pipe.jac"], "fragment_kind": ""};
    found: list[str] = violations(
        [("A", "release_notes/unreleased/jaclang/0000.refactor.md")], theme, [], []);
    assert len(found) == 1;
}

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

test "parse_name_status splits STATUS and path, tolerates blank lines" {
    rows: list[tuple[str, str]] = parse_name_status("M\ta/b.jac\n\nD\tc/d.jac\n");
    assert rows == [("M", "a/b.jac"), ("D", "c/d.jac")];
}
