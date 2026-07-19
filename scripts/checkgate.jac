"""Baseline-diff `jac check` gate (Nightshift verify, S4).

The target repo does not pass `jac check` cleanly on main: several .jac files carry pre-existing
type errors (e.g. `float(dict.get(...))` -> E1053 "Cannot assign Any"). A plain "jac check must
pass" gate would reject EVERY branch that merely touches such a file, even one that changed only a
comment. So, like testgate, we gate on introducing NO NEW errors: the verify step runs `jac check`
on the changed files as they are on main AND on the branch, and this tool fails only if the branch
output contains an error identity absent from the main output.

Error identity = (error code, offending source-line text). Source text (not line number) is used so
that inserting/removing lines elsewhere never fabricates a "new" error. Only hard errors count
(lines beginning `✖ Error: error[`); warnings (`⚠ warning`) are ignored.

argv:
  parse <raw.txt>                 print sorted unique error identities (code<TAB>src)
  gate  <main_raw> <branch_raw>   exit 0 if branch adds no new error identity, 1 if it does
                                  (prints the new ones), 2 if main_raw is missing
"""
import sys;
import os;
import from nslib { eprint }

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
    lines: list[str] = raw.splitlines();
    idx: int = 0;
    for line in lines {
        stripped: str = line.strip();
        if stripped.startswith("✖ Error: error[") {
            a: int = stripped.find("error[") + 6;
            b: int = stripped.find("]", a);
            cur = stripped[a:b] if b > a else "";
        } elif stripped.startswith("⚠ warning") {
            cur = "";
        } elif cur and idx > 0 and is_caret(line) {
            src: str = after_pipe(lines[idx - 1]);
            if src {
                ids.add(cur + "\t" + src);
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
    if cmd == "gate" and len(args) == 4 {
        (code, new_errs) = gate(args[2], args[3]);
        if code == 2 {
            eprint("checkgate: main-side check output missing: " + args[2]);
        }
        for e in new_errs {
            eprint("NEW CHECK ERROR: " + e);
        }
        sys.exit(code);
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run checkgate.jac gate <main_raw> <branch_raw>");
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
    assert ids == ["E1053\t'timeout': float(fallback_config.get('timeout', 60.0))"];
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
    (c1, n1) = gate(main_raw, branch_same);
    (c2, n2) = gate(main_raw, branch_new);
    assert c1 == 0 and n1 == [];
    assert c2 == 1 and n2 == ["E1053\ty = float(cfg.get('b', 2.0))"];
    (c3, _n3) = gate(d + "/missing.txt", branch_same);
    assert c3 == 2;
}
