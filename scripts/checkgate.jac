"""Baseline-diff `jac check` gate (Nightshift verify, S4).

The target repo does not pass `jac check` cleanly on main: several .jac files carry pre-existing
type errors (e.g. `float(dict.get(...))` -> E1053 "Cannot assign Any"). A plain "jac check must
pass" gate would reject EVERY branch that merely touches such a file, even one that changed only a
comment. So, like testgate, we gate on introducing NO NEW errors: the verify step runs `jac check`
on the changed files as they are on main AND on the branch, and this tool fails only if the branch
output contains an error identity absent from the main output.

Error identity = (file path, error code, offending source-line text). Source text (not line number)
is used so that inserting/removing lines elsewhere never fabricates a "new" error; the file path is
still included so the same code/text pair in two different files is not treated as one error. Only
hard errors count (lines beginning `✖ Error: error[`); warnings (`⚠ warning`) are ignored.

argv:
  parse <raw.txt>                 print sorted unique error identities (file<TAB>code<TAB>src)
  ran   <raw.txt>                 print how many checker runs the capture contains
                                  (0 == `jac check` never started; see run_count)
  gate  <main_raw> <branch_raw>   exit 0 if branch adds no new error identity, 1 if it does
                                  (prints the new ones), 2 if main_raw is missing
"""
import sys;
import os;
import re;
import from nslib { eprint }

"""How many `jac check` runs the capture contains -- 0 means the checker never actually ran.

Same hole `testgate.jac`'s session_count closes for the test gate, on this gate: `identities()`
returns an empty set both for "the checker ran and found nothing" and for "the checker never
started" (missing/unexecutable $NS_PATHS_JAC_REPO, an argument list too long for exec, a crash).
`gate` then finds no new identity and returns 0, and verify_branch publishes `jac check ✓`.

The signal is the run summary the checker always prints when it truly ran -- measured 2026-07-30
against the repo's own binary: a clean file, a file with real errors, and even a NONEXISTENT path
all end in `N passed in Xs` / `N failed in Xs` (exit 1 whenever errors exist, which is why the
caller's `|| true` is legitimate and stays). A missing binary exits 127 and prints no summary at
all."""
def run_count(raw: str) -> int {
    n: int = 0;
    for line in raw.splitlines() {
        if re.search(r"\d+ (passed|failed) in ", line) {
            n += 1;
        }
    }
    return n;
}

def is_caret(line: str) -> bool {
    stripped: str = line.strip();
    if "^" not in stripped {
        return False;
    }
    for ch in stripped {
        if ch not in "|^ " {
            return False;
        }
    }
    return True;
}

def after_pipe(line: str) -> str {
    if "|" in line {
        return line.split("|", 1)[1].strip();
    }
    return "";
}

def identities(raw: str) -> list[str] {
    ids: set[str] = set();
    cur: str = "";                       # current hard-error code, "" when inside a warning/none
    cur_file: str = "";                  # current error's file path, from its "--> path:line:col"
    lines: list[str] = raw.splitlines();
    idx: int = 0;
    for line in lines {
        stripped: str = line.strip();
        if stripped.startswith("✖ Error: error[") {
            a: int = stripped.find("error[") + 6;
            b: int = stripped.find("]", a);
            cur = stripped[a:b] if b > a else "";
            cur_file = "";
        } elif stripped.startswith("⚠ warning") {
            cur = "";
            cur_file = "";
        } elif cur and stripped.startswith("--> ") {
            cur_file = stripped[4:].rsplit(":", 2)[0];
        } elif cur and idx > 0 and is_caret(line) {
            src: str = after_pipe(lines[idx - 1]);
            if src and cur_file {
                ids.add(cur_file + "\t" + cur + "\t" + src);
            }
        }
        idx += 1;
    }
    return sorted(ids);
}

def read_file(path: str) -> str {
    with open(path, "r") as f {
        return f.read();
    }
}

def gate(main_path: str, branch_path: str) -> (int, list[str]) {
    if not os.path.exists(main_path) {
        return (2, []);
    }
    known: set[str] = set(identities(read_file(main_path)));
    current: list[str] = identities(read_file(branch_path));
    new_errs: list[str] = [e for e in current if e not in known];
    return (1 if new_errs else 0, new_errs);
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    # `parse` was documented in this file's argv header from the start but had no dispatch branch,
    # so it silently printed nothing -- the identical omission testgate.jac carried. Found by
    # running it against a real capture with two known errors and getting zero back.
    if cmd == "parse" and len(args) == 3 {
        with open(args[2], "r") as f {
            for i in identities(f.read()) {
                print(i);
            }
        }
    } elif cmd == "ran" and len(args) == 3 {
        with open(args[2], "r") as f {
            print(run_count(f.read()));
        }
    } elif cmd == "gate" and len(args) == 4 {
        (code, new_errs) = gate(args[2], args[3]);
        if code == 2 {
            eprint("checkgate: main-side check output missing: " + args[2]);
        }
        for e in new_errs {
            eprint("NEW CHECK ERROR: " + e);
        }
        sys.exit(code);
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run checkgate.jac parse <raw.txt>");
        eprint("       jac run checkgate.jac gate <main_raw> <branch_raw>");
        eprint("       jac run checkgate.jac ran <raw.txt>");
    }
}

test "identities keys on (code, source line), ignores warnings and line numbers" {
    raw: str = "✖ Error: error[E1053]: Cannot assign Any to parameter 'x'\n"
        + "  --> f.jac:112:26\n"
        + "  111 |     'num_retries': int(fallback_config.get('num_retries', 1)),\n"
        + "  112 |     'timeout': float(fallback_config.get('timeout', 60.0))\n"
        + "      |              ^^^^^^^^^^^^^^^^^^^^^^^^\n"
        + "⚠ warning[W1037]: Explicit 'any'\n"
        + "  81 |     result: dict[str, any] = {\n"
        + "     |                       ^^^\n";
    ids: list[str] = identities(raw);
    assert ids == ["f.jac\tE1053\t'timeout': float(fallback_config.get('timeout', 60.0))"];
}

test "run_count tells a checker that never started apart from one that found nothing" {
    # the real summary shapes, measured against the repo binary on 2026-07-30
    assert run_count("============================== 1 passed in 0.81s ===============================") == 1;
    assert run_count("============================== 1 failed in 1.48s ===============================") == 1;
    assert run_count("=== 12 failed in 31.02s ===\n=== 3 passed in 0.40s ===\n") == 2;
    # the "never ran" capture: a missing binary exits 127 and prints no summary
    never: str = "(eval): no such file or directory: /nonexistent/jac\n";
    assert run_count(never) == 0;
    assert identities(never) == [];        # indistinguishable from clean WITHOUT this check
    # a real error capture still counts as HAVING run
    errcap: str = "✖ Error: error[E1053]: bad\n"
        + "  --> f.jac:10:1\n"
        + "  10 |     x = float(cfg.get('a', 1.0))\n"
        + "     |         ^^^^^^^^^^^^^^^^^^^^^^^\n"
        + "============================== 1 failed in 0.25s ===============================\n";
    assert run_count(errcap) == 1;
    assert len(identities(errcap)) == 1;
}

test "gate: branch error absent on main is new (red); same set is green" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    main_raw: str = d + "/main.txt";
    with open(main_raw, "w") as f {
        f.write("✖ Error: error[E1053]: bad\n"
            + "  --> f.jac:10:1\n"
            + "  10 |     x = float(cfg.get('a', 1.0))\n"
            + "     |         ^^^^^^^^^^^^^^^^^^^^^^^\n");
    }
    branch_same: str = d + "/same.txt";           # same error, shifted line number -> green
    with open(branch_same, "w") as f {
        f.write("✖ Error: error[E1053]: bad\n"
            + "  --> f.jac:14:1\n"
            + "  14 |     x = float(cfg.get('a', 1.0))\n"
            + "     |         ^^^^^^^^^^^^^^^^^^^^^^^\n");
    }
    branch_new: str = d + "/new.txt";             # extra distinct error line -> red
    with open(branch_new, "w") as f {
        f.write("✖ Error: error[E1053]: bad\n"
            + "  --> f.jac:10:1\n"
            + "  10 |     x = float(cfg.get('a', 1.0))\n"
            + "     |         ^^^^^^^^^^^^^^^^^^^^^^^\n"
            + "✖ Error: error[E1053]: bad\n"
            + "  --> f.jac:20:1\n"
            + "  20 |     y = float(cfg.get('b', 2.0))\n"
            + "     |         ^^^^^^^^^^^^^^^^^^^^^^^\n");
    }
    branch_other_file: str = d + "/other_file.txt";  # same code+text, DIFFERENT file -> still red
    with open(branch_other_file, "w") as f {
        f.write("✖ Error: error[E1053]: bad\n"
            + "  --> g.jac:10:1\n"
            + "  10 |     x = float(cfg.get('a', 1.0))\n"
            + "     |         ^^^^^^^^^^^^^^^^^^^^^^^\n");
    }
    (c1, n1) = gate(main_raw, branch_same);
    (c2, n2) = gate(main_raw, branch_new);
    (c4, n4) = gate(main_raw, branch_other_file);
    assert c1 == 0 and n1 == [];
    assert c2 == 1 and n2 == ["f.jac\tE1053\ty = float(cfg.get('b', 2.0))"];
    assert c4 == 1 and n4 == ["g.jac\tE1053\tx = float(cfg.get('a', 1.0))"];
    (c3, _n3) = gate(d + "/missing.txt", branch_same);
    assert c3 == 2;
}
