"""Baseline-diff test gate (Nightshift verify, S4).

The target repo's suite is not green on this machine (env/infra-dependent failures) and is too
slow to demand a fully-green run per branch. Instead we record a per-package BASELINE of tests
that already fail on main, then gate each branch on introducing NO NEW failures.

Failing test ids are parsed from the bundled pytest runner's output: lines beginning
`FAILED ` or `ERROR ` (collection errors count as failures). A branch is red only if it fails a
test that passes on main.

argv:
  parse  <raw.txt>                        print sorted unique failing test ids
  record <pkg> <raw.txt> <baseline_dir>   write baseline_dir/<pkg>.json from a main-branch run
  gate   <pkg> <raw.txt> <baseline_dir>   exit 0 if no new failures vs baseline, 1 if new
                                          (prints the new failures), 2 if no baseline recorded
"""
import sys;
import json;
import os;
import from nslib { eprint, parse_obj }

def failing_ids(raw: str) -> list[str] {
    ids: set[str] = set();
    for line in raw.splitlines() {
        stripped: str = line.strip();
        for prefix in ["FAILED ", "ERROR "] {
            if stripped.startswith(prefix) {
                # node id is the token after the prefix, before any trailing " - reason"
                rest: str = stripped[len(prefix):].strip();
                nodeid: str = rest.split(" - ")[0].strip();
                if nodeid {
                    ids.add(nodeid);
                }
            }
        }
    }
    return sorted(ids);
}

def read_file(path: str) -> str {
    with open(path, "r") as f {
        return f.read();
    }
}

def baseline_path(baseline_dir: str, pkg: str) -> str {
    return os.path.join(baseline_dir, pkg + ".json");
}

def record(pkg: str, raw_path: str, baseline_dir: str) -> int {
    os.makedirs(baseline_dir, exist_ok=True);
    ids: list[str] = failing_ids(read_file(raw_path));
    with open(baseline_path(baseline_dir, pkg), "w") as f {
        f.write(json.dumps({"package": pkg, "failing": ids, "count": len(ids)}, indent=2) + "\n");
    }
    return len(ids);
}

def gate(pkg: str, raw_path: str, baseline_dir: str) -> (int, list[str]) {
    bp: str = baseline_path(baseline_dir, pkg);
    if not os.path.exists(bp) {
        return (2, []);
    }
    baseline: dict = parse_obj(read_file(bp));
    known: set[str] = set([str(x) for x in baseline["failing"]]);
    current: list[str] = failing_ids(read_file(raw_path));
    new_fails: list[str] = [f for f in current if f not in known];
    return (1 if new_fails else 0, new_fails);
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "record" and len(args) == 5 {
        print(record(args[2], args[3], args[4]));
    } elif cmd == "gate" and len(args) == 5 {
        (code, new_fails) = gate(args[2], args[3], args[4]);
        if code == 2 {
            eprint("testgate: no baseline for " + args[2] + " (run: nightshift.sh baseline)");
        }
        for f in new_fails {
            eprint("NEW FAILURE: " + f);
        }
        sys.exit(code);
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run testgate.jac record <pkg> <raw.txt> <baseline_dir>");
        eprint("       jac run testgate.jac gate <pkg> <raw.txt> <baseline_dir>");
    }
}

test "parse extracts FAILED and ERROR node ids, sorted unique" {
    raw: str = "some noise\nFAILED tests/a.jac::one\nPASSED tests/a.jac::two\nERROR tests/b.jac::setup\nFAILED tests/a.jac::one\n==== 2 failed ====";
    ids: list[str] = failing_ids(raw);
    assert ids == ["tests/a.jac::one", "tests/b.jac::setup"];
}

test "gate: new failure vs baseline is red, subset is green" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    with open(d + "/pkg.json", "w") as f {
        f.write("{\"package\": \"pkg\", \"failing\": [\"t.jac::known\"], \"count\": 1}");
    }
    raw_ok: str = d + "/ok.txt";
    with open(raw_ok, "w") as f {
        f.write("FAILED t.jac::known\n");         # only the known failure -> green
    }
    raw_bad: str = d + "/bad.txt";
    with open(raw_bad, "w") as f {
        f.write("FAILED t.jac::known\nFAILED t.jac::regression\n");   # a new one -> red
    }
    (c1, n1) = gate("pkg", raw_ok, d);
    (c2, n2) = gate("pkg", raw_bad, d);
    assert c1 == 0 and n1 == [];
    assert c2 == 1 and n2 == ["t.jac::regression"];
    (c3, _n3) = gate("missing", raw_ok, d);
    assert c3 == 2;
}
