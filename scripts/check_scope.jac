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
