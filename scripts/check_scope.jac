"""S4 scope-containment gate (TechnicalPRD 7-S4, threat T1 backstop).

stdin: `check` mode: git diff --name-status output (STATUS<TAB>path per line). `protected` mode:
newline-separated paths (git diff --name-only).
argv:  check <theme.json> <config.toml>       theme-scoped gate (apply branches)
       protected <config.toml>                print the stdin paths that hit a protected glob
                                              (tier-1 uses this to revert formatter overreach)
Exit 0 = diff contained; exit 1 = violation(s), one `VIOLATION <path> <reason>` line each.
A diff outside the theme's declared files or inside a protected glob is rejected
no matter how green the tests are -- UNLESS the path is in the theme's own
`vestigial_deletions` (selector.jac already independently verified, before the agent ever saw
this theme, that the file is entirely about code the theme is deleting) AND the change is a
clean deletion (status "D"), never a modification.
"""
import sys;
import from nslib { eprint, read_stdin, parse_obj, as_list, is_protected, load_globs, fragment_path }

def violations(changed: list[tuple[str, str]], theme: dict, globs: list[str]) -> list[str] {
    allowed: list[str] = [str(f) for f in theme["files"]];
    # The orchestrator, not the agent, writes the fragment -- but the gate must still allow it
    # through. Kind comes from the theme; fragment_path clamps an invalid kind to refactor, so a
    # tampered theme cannot smuggle an arbitrary filename past the regex CI enforces.
    frag: str = fragment_path(allowed, str(theme.get("fragment_kind", "refactor")));
    if frag {
        allowed.append(frag);
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
        } elif is_protected(path, globs) {
            out.append("VIOLATION " + path + " protected-glob");
        }
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
    if len(args) == 4 and args[1] == "check" {
        with open(args[2], "r") as f {
            theme: dict = parse_obj(f.read());
        }
        changed: list[tuple[str, str]] = parse_name_status(read_stdin());
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
        eprint("usage: git diff --name-status main...HEAD | jac run check_scope.jac check <theme.json> <config.toml>");
        eprint("       git diff --name-only | jac run check_scope.jac protected <config.toml>");
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
    found: list[str] = violations(changed, theme, globs);
    assert len(found) == 1;
    assert "rogue.jac" in found[0];
}

test "allowed file inside a protected glob is still rejected" {
    theme: dict = {"package": "jac", "files": ["jac/tests/fixtures/x.jac"]};
    found: list[str] = violations([("M", "jac/tests/fixtures/x.jac")], theme, ["**/tests/**"]);
    assert len(found) == 1;
    assert "protected-glob" in found[0];
}

test "vestigial deletion is allowed only as a clean delete, modifying it is still rejected" {
    theme: dict = {"package": "jac", "files": ["jac/pkg/gateway.jac"],
        "vestigial_deletions": ["jac/pkg/tests/test_gateway.jac"]};
    globs: list[str] = ["**/tests/**"];
    ok: list[str] = violations([("D", "jac/pkg/tests/test_gateway.jac")], theme, globs);
    assert ok == [];
    bad: list[str] = violations([("M", "jac/pkg/tests/test_gateway.jac")], theme, globs);
    assert len(bad) == 1 and "must-be-a-clean-delete" in bad[0];
}

test "parse_name_status splits STATUS and path, tolerates blank lines" {
    rows: list[tuple[str, str]] = parse_name_status("M\ta/b.jac\n\nD\tc/d.jac\n");
    assert rows == [("M", "a/b.jac"), ("D", "c/d.jac")];
}
