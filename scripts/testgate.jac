"""Baseline-diff test gate (Nightshift verify, S4).

The target repo's suite is not green on this machine (env/infra-dependent failures) and is too
slow to demand a fully-green run per branch. Instead we record a per-package BASELINE of tests
that already fail on main, then gate each branch on introducing NO NEW failures.

Failing test ids are parsed from the bundled pytest runner's output: lines beginning
`FAILED ` or `ERROR ` (collection errors count as failures). A branch is red only if it fails a
test that passes on main.

`<pkg>` is really a MIRROR SUITE NAME since Task 6 (`compiler`, `runtime`, `byllm` -- the
config/ci-mirror.toml job names lib/verify.sh's gated_suites_from_diff emits). The argv label and
the JSON's "package" key keep the old spelling so already-recorded baselines stay readable.

argv:
  parse  <raw.txt>                        print sorted unique failing test ids
  record <pkg> <raw.txt> <baseline_dir>   write baseline_dir/<pkg>.json from a main-branch run
  record-union <pkg> <raw1.txt> <raw2.txt> <baseline_dir>
                                          same, but baseline the UNION of two main-branch runs so
                                          a test that flakes in either run stops reding branches
  sessions <raw.txt>                      print how many runner sessions the capture contains
                                          (0 == the suite never started; see session_count)
  collected <raw.txt>                     print how many tests the capture collected
  collection-check <pkg> <raw.txt> <baseline_dir>
                                          exit 0 if the run collected >= COLLECTION_FLOOR of the
                                          baseline's count, 1 if materially fewer, 2 if there is
                                          no baseline count to compare against
  gate   <pkg> <raw.txt> <baseline_dir>   exit 0 if no new failures vs baseline, 1 if new
                                          (prints the new failures), 2 if no baseline recorded
"""
import sys;
import json;
import os;
import re;
import from nslib { eprint, parse_obj }

"""Fraction of the baseline's collected-item count a branch run must still reach.

`session_count` catches "the runner never started". This catches the softer sibling: the runner
STARTS, prints its banner, and then collects far less than it should -- a half-broken suite whose
unreached tests all score as "not failing", i.e. green. Both of the false-greens this file has had
to defend against were of that family, so the gate now positively asserts the branch ran about as
much as the baseline did instead of only checking what failed.

0.75 is deliberately loose, because DELETING tests is a legitimate and common Nightshift outcome --
vestigial-test sweeps are its bread and butter, and they legitimately shrink collection.

The margin needs care, and an earlier version of this comment justified it with two claims that are
both FALSE (corrected after review, 2026-07-30; the NUMBER survived the correction, the reasoning
did not):
  - "[budgets] caps a theme at 10 files, so a sweep is bounded." It does not. selector.jac:172
    applies files_per_theme/loc_per_theme to FINDINGS only; vestigial_test_files is called at :199,
    AFTER packing, and its result is appended to the theme with no budget check at all.
  - "10 of byllm's 76 test files is ~13%." byllm has TEN test-bearing files; the other 66 are
    fixtures/. Ten files IS the whole suite. And the item distribution is severely skewed:
    test_byllm.jac ALONE is 100 of the suite's 219 collected items (46%), which on its own would
    blow through any floor above 0.55.
    (A per-file list used to sit here -- 100 / 42 / 29 / 14 / 13 / 13 / 11 / 5 / 5 / 1 -- and it
    SUMMED TO 233, not the 219 the suite actually collects, so at least one of its numbers was
    wrong. Dropped rather than re-guessed: this comment has already had one round of false
    justifying claims, and only the three per-file counts cited below are load-bearing. Re-measure
    with `jac test jac/jaclang/byllm/tests` under a warm HOME before quoting a full distribution
    again.)

The real ceiling is incidental, which is the thing to keep an eye on: is_vestigial's import
allowlist (selector.jac:24-30) fails closed on any import that is neither stdlib-ish nor one of the
theme's own file stems. Measured against byllm's ten files, that permanently disqualifies seven of
them on imports no theme can ever delete (io, shutil, uuid, ast, contextlib, contextvars, jaclang,
fixtures, enum_with_semstr). Only validate_schema (13 items), test_multimodal_tool_results (5) and
test_truncated_tool_calls (1) can qualify today = 19 items = 8.7% of the suite. So the live margin
is 8.7% against a 25% floor -- comfortable, but held up by an unrelated function's tuning rather
than by anything structural. Adding io/shutil/uuid/contextlib/ast to that allowlist, a small and
entirely benign-looking change, makes test_byllm.jac (46%) eligible and would turn one legitimate
theme into two reds and a permanent failed_verify auto-reject.

UPGRADE PATH when that margin gets uncomfortable: stop guessing and subtract. verify_branch already
has the theme, and check_scope.jac:27 already reads its vestigial_deletions, so the deleted test
files are known by name -- count the `test ` declarations in each one's MAIN-branch content, add
that to `got`, and keep 0.75 as the residual backstop for everything else. Not done yet because
today's 8.7% worst case does not need it, and the plumbing is not free.

The other two suites are not exposed: compiler collects 2792 items and runtime ~1852, so no
single-file deletion moves them measurably. The failure modes this exists to catch lose far more
than any of this: the measured byllm dependency hole dropped collection 219 -> 105 (-52%).

NOTE, deliberately not handled: there is no absolute floor, only a proportional one. Harmless today
(the smallest baseline is 219 items) but a future suite of, say, 12 tests would red on a 3-item
loss. Add a minimum-items clause if such a suite is ever registered."""
glob COLLECTION_FLOOR: float = 0.75;

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

"""Count the test-runner sessions in a raw capture.

`failing_ids` CANNOT distinguish "the suite ran and nothing failed" from "the suite never started":
both yield zero FAILED/ERROR lines. That ambiguity is not theoretical -- confirmed live 2026-07-30,
[jobs.compiler]/[jobs.runtime] were registered with ci.yml's `working-directory: jac` relative paths
but executed from the repo ROOT, so every command died on `File not found: 'tests/compiler'` and
produced a capture with no test ids at all. Recording that as a baseline would have written
count:0 for 4644 real tests and made the gate vacuously green forever.

The runner prints exactly one `test session starts` banner per invocation, including for the
legitimate "no tests ran" case (which correctly counts as HAVING run), so this is the signal that
separates the two. baseline_main refuses to record a baseline when this returns 0."""
def session_count(raw: str) -> int {
    n: int = 0;
    for line in raw.splitlines() {
        if "test session starts" in line {
            n += 1;
        }
    }
    return n;
}

"""Total tests COLLECTED across every session in a capture.

Two shapes, because the runner reports collection differently with and without xdist:
  `18 workers [219 items]`                          (JAC_TEST_JOBS=auto, the normal case)
  `collected 11 items / 11 deselected / 0 selected` (serial)
Matched line-anchored rather than by a bare `\\d+ items` sweep of the whole capture, so a test that
happens to print something like "[5 items]" cannot inflate the number. Summed across sessions
because a suite may declare several test commands ([jobs.compiler] has two)."""
def collected_count(raw: str) -> int {
    total: int = 0;
    for line in raw.splitlines() {
        s: str = line.strip();
        hits: list[str] = [];
        if s.startswith("collected ") {
            hits = re.findall(r"^collected\s+(\d+)\s+items?", s);
        } elif " workers [" in s {
            hits = re.findall(r"\[(\d+)\s+items?\]", s);
        }
        for h in hits {
            total += int(h);
        }
    }
    return total;
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

"""Baseline the UNION of two main-branch runs. A test that fails in EITHER run is treated as
known-failing, which is the fix for the observed failure mode where the same branch reded on
run 1, passed on run 2, and burned 2h of the night in retries (nights 07-21 and 07-23).

Deliberately asymmetric with `gate`: recording is permissive (union -> the widest known-failing
set), gating stays strict (any id not in that set is new). Intersection would be the wrong
operator here -- it would drop every flake back out of the baseline and reintroduce the exact
bug this exists to fix."""
def record_union(pkg: str, raw1: str, raw2: str, baseline_dir: str) -> int {
    os.makedirs(baseline_dir, exist_ok=True);
    text1: str = read_file(raw1);
    text2: str = read_file(raw2);
    both: set[str] = set(failing_ids(text1)) | set(failing_ids(text2));
    ids: list[str] = sorted(both);
    # `collected` is the floor a later branch run is measured against (see collection_check). The
    # MIN of the two runs, not the max or the mean: it is the conservative choice, so ordinary
    # run-to-run collection jitter can never make a healthy branch look under-collected.
    c1: int = collected_count(text1);
    c2: int = collected_count(text2);
    with open(baseline_path(baseline_dir, pkg), "w") as f {
        f.write(json.dumps({
            "package": pkg, "failing": ids, "count": len(ids), "runs": 2,
            "collected": min(c1, c2), "collected_runs": [c1, c2]
        }, indent=2) + "\n");
    }
    return len(ids);
}

"""Did this branch run collect about as many tests as the baseline run did?

Returns (code, got, want): code 0 = collection intact, 1 = materially under-collected,
2 = no baseline, or a baseline recorded before `collected` existed (nothing to compare against,
so it cannot be a gate -- same "no baseline == no gate" semantics `gate` uses for code 2)."""
def collection_check(pkg: str, raw_path: str, baseline_dir: str) -> (int, int, int) {
    bp: str = baseline_path(baseline_dir, pkg);
    if not os.path.exists(bp) {
        return (2, 0, 0);
    }
    baseline: dict = parse_obj(read_file(bp));
    want: int = int(baseline.get("collected", 0));
    if want <= 0 {
        return (2, 0, 0);
    }
    got: int = collected_count(read_file(raw_path));
    floor: int = int(want * COLLECTION_FLOOR);
    return (1 if got < floor else 0, got, want);
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
    # `parse` was documented in this file's own argv header from the start but had NO dispatch
    # branch, so it silently fell through to the usage message and printed nothing to stdout
    # (found 2026-07-30 while validating `sessions` against real captures). The flake-quantifying
    # sanity check that follows a `nightshift.sh baseline` run is built on it, so it has to exist.
    if cmd == "parse" and len(args) == 3 {
        for f in failing_ids(read_file(args[2])) {
            print(f);
        }
    } elif cmd == "record" and len(args) == 5 {
        print(record(args[2], args[3], args[4]));
    } elif cmd == "record-union" and len(args) == 6 {
        print(record_union(args[2], args[3], args[4], args[5]));
    } elif cmd == "sessions" and len(args) == 3 {
        print(session_count(read_file(args[2])));
    } elif cmd == "collected" and len(args) == 3 {
        print(collected_count(read_file(args[2])));
    } elif cmd == "collection-check" and len(args) == 5 {
        (ccode, got, want) = collection_check(args[2], args[3], args[4]);
        if ccode == 1 {
            eprint("UNDER-COLLECTED: " + args[2] + " collected " + str(got)
                   + " tests, baseline collected " + str(want)
                   + " -- the suite did not run to completion, so its unreached tests cannot be "
                   + "read as passing");
        }
        sys.exit(ccode);
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
        eprint("usage: jac run testgate.jac parse <raw.txt>");
        eprint("       jac run testgate.jac record <pkg> <raw.txt> <baseline_dir>");
        eprint("       jac run testgate.jac record-union <pkg> <raw1.txt> <raw2.txt> <baseline_dir>");
        eprint("       jac run testgate.jac sessions|collected <raw.txt>");
        eprint("       jac run testgate.jac collection-check <pkg> <raw.txt> <baseline_dir>");
        eprint("       jac run testgate.jac gate <pkg> <raw.txt> <baseline_dir>");
    }
}

test "parse extracts FAILED and ERROR node ids, sorted unique" {
    raw: str = "some noise\nFAILED tests/a.jac::one\nPASSED tests/a.jac::two\nERROR tests/b.jac::setup\nFAILED tests/a.jac::one\n==== 2 failed ====";
    ids: list[str] = failing_ids(raw);
    assert ids == ["tests/a.jac::one", "tests/b.jac::setup"];
}

test "session_count tells a suite that never started apart from one that ran clean" {
    # the real capture shape of the bug this exists to catch: cimirror ran the command, the command
    # could not find its paths, zero test ids, zero sessions
    never_ran: str = "\n$ JAC_TEST_JOBS=auto jac test tests/compiler\n"
        + "✖ Error: File not found: 'tests/compiler'\n"
        + "Make sure you are in the correct directory or provide the full path.\n";
    assert session_count(never_ran) == 0;
    assert failing_ids(never_ran) == [];          # indistinguishable from green WITHOUT this check
    # a real run that happens to be green still counts as HAVING run
    ran_clean: str = "============ test session starts ============\n"
        + "collected 11 items\n...........\n=========== 11 passed in 4.17s ===========\n";
    assert session_count(ran_clean) == 1;
    assert failing_ids(ran_clean) == [];
    # the legitimate "no tests ran" case (jac-mcp) also counts as having run
    assert session_count("==== test session starts ====\n==== no tests ran in 0.30s ====\n") == 1;
    # a multi-command suite ([jobs.compiler] has two) prints one banner per invocation
    assert session_count(ran_clean + ran_clean) == 2;
}

test "collected_count reads both runner shapes and ignores incidental bracket text" {
    xdist: str = "created: 18/18 workers\n18 workers [219 items]\n";
    assert collected_count(xdist) == 219;
    serial: str = "collected 11 items / 11 deselected / 0 selected\n";
    assert collected_count(serial) == 11;
    # a multi-command suite sums its sessions
    assert collected_count(xdist + "18 workers [180 items]\n") == 399;
    # a test that merely PRINTS something bracket-shaped must not inflate the count
    noise: str = xdist + "INFO - batch dispatch=parallel [5 items] tools=['a']\n"
        + "some log line mentioning 42 items\n";
    assert collected_count(noise) == 219;
    # the capture from a suite that never started has no count at all
    assert collected_count("✖ Error: File not found: 'tests/compiler'\n") == 0;
}

test "collection-check reds a half-collected run and passes a legitimate test deletion" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    # baseline: the REAL measured byllm collection under a warm HOME with deps present
    r1: str = d + "/r1.txt";
    with open(r1, "w") as f {
        f.write("== test session starts ==\n18 workers [219 items]\nFAILED t.jac::known\n");
    }
    r2: str = d + "/r2.txt";
    with open(r2, "w") as f {
        f.write("== test session starts ==\n18 workers [221 items]\nFAILED t.jac::known\n");
    }
    record_union("byllm", r1, r2, d);
    base: dict = parse_obj(read_file(d + "/byllm.json"));
    assert base["collected"] == 219;            # the MIN of the two runs, not the max
    assert base["collected_runs"] == [219, 221];
    # the REAL measured clean-HOME regression: 105 of 219 -> must be caught
    bad: str = d + "/bad.txt";
    with open(bad, "w") as f {
        f.write("== test session starts ==\n18 workers [105 items]\n");
    }
    (c1, got1, want1) = collection_check("byllm", bad, d);
    assert c1 == 1 and got1 == 105 and want1 == 219;
    # a vestigial-test sweep at the budget ceiling must NOT red: 10 of byllm's 76 test files is
    # roughly 29 items, well inside COLLECTION_FLOOR
    ok: str = d + "/ok.txt";
    with open(ok, "w") as f {
        f.write("== test session starts ==\n18 workers [190 items]\n");
    }
    (c2, _g2, _w2) = collection_check("byllm", ok, d);
    assert c2 == 0;
    # no baseline at all -> no gate, never a red
    (c3, _g3, _w3) = collection_check("nosuch", ok, d);
    assert c3 == 2;
    # a baseline predating the `collected` key is also "cannot gate", not "red"
    with open(d + "/legacy.json", "w") as f {
        f.write("{\"package\": \"legacy\", \"failing\": [], \"count\": 0}");
    }
    (c4, _g4, _w4) = collection_check("legacy", ok, d);
    assert c4 == 2;
}

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
