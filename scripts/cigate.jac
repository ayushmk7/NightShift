"""Baseline-diff CI gate (Nightshift S1.6, spec section 8).

Upstream CI is frequently RED on main -- five consecutive non-passing ci.yml runs measured
2026-07-30, and `jac-check` sitting at conclusion=failure on main's own head commit while this
was written. A plain "all checks green" gate would reject every Nightshift PR for other people's
breakage, so this records which checks PASS on main and calls a PR red only on a check that fails
on the branch and passes on main.

Both sides come from ONE endpoint and therefore one shape:
    gh api "repos/<repo>/commits/<sha>/check-runs?per_page=100"
with <sha> = main for the baseline and the PR's headRefOid for a branch. Deliberately wider than
the spec's "main's latest ci.yml run": the commit endpoint returns EVERY check on the commit --
ci.yml's jobs, the other workflows (`build / ...`, `prepare`, `microservice e2e`) and any
third-party app -- which is what a PR is actually judged by, with no second parser for a second
shape.

`gate`'s exit codes mirror scripts/testgate.jac EXACTLY: 0 no new failures, 1 new failures, 2 no
baseline (== no gate). lib/*.sh already encodes that 2 is not a red, and conflating 2 with "any
nonzero" once rejected a safe branch as broken.

argv:
  parse  <checks.json>                  print name<TAB>status<TAB>conclusion, sorted
  ran    <checks.json>                  print how many check runs have COMPLETED
  record <checks.json> <baseline.json>  write the passing-on-main baseline; print its size
  gate   <checks.json> <baseline.json>  exit 0 / 1 / 2 as above
  prs    <prefix>                       stdin: gh pr list --json number,headRefName,url,title
                                        stdout: number<TAB>branch<TAB>url<TAB>title per matching PR
  row    k=v ...                        stdout: ONE prs.jsonl line (see PR_ROW_KEYS)
"""
import sys;
import json;
import os;
import from nslib { eprint, read_stdin, parse_obj, parse_list, as_list, as_dict, today }

"""A conclusion that means THIS BRANCH BROKE SOMETHING.

`cancelled`, `skipped`, `neutral` and `stale` are deliberately absent. Upstream cancels superseded
runs routinely (three of the last five ci.yml runs on main were cancelled), and a cancelled or
path-filtered check says nothing at all about the branch. Reading it as red would red every PR
whenever upstream force-pushes main."""
glob RED_CONCLUSIONS: list[str] = ["failure", "timed_out", "action_required"];

"""Parse a check-runs payload into (name, status, conclusion), asserting the capture is COMPLETE.

total_count vs len(check_runs) is not a formality: main's head commit carried exactly 30 check
runs on 2026-07-30 and this endpoint's default page size is 30, so a caller that forgets
?per_page=100 gets a silently truncated list. Truncation on the BASELINE side quietly removes
names from the passing set, which un-gates those checks forever -- a "did not run" scoring as
"nothing to gate". Refuse the capture instead of gating against half of it."""
def check_rows(raw: str) -> list[tuple[str, str, str]] {
    payload: dict = parse_obj(raw);
    runs: list = as_list(payload["check_runs"]);
    total: int = int(payload["total_count"]);
    if total != len(runs) {
        raise ValueError("check-runs capture is truncated: total_count=" + str(total)
                         + " but the payload carries " + str(len(runs))
                         + " runs. Re-fetch with ?per_page=100.");
    }
    rows: list[tuple[str, str, str]] = [];
    for item in runs {
        run: dict = as_dict(item);
        concl: any = run.get("conclusion");
        rows.append((str(run["name"]), str(run["status"]),
                     str(concl) if concl is not None else ""));
    }
    rows.sort();
    return rows;
}

"""How many check runs have finished. Zero means CI has not reported yet -- which produces zero
failures AND zero passes, i.e. it is indistinguishable from a clean run to anything that only
counts failures. The bash caller checks this before it reads meaning into `gate`'s answer, exactly
as lib/verify.sh's assert_suite_ran does for the test suites."""
def completed_count(raw: str) -> int {
    n: int = 0;
    for (_name, status, _concl) in check_rows(raw) {
        if status == "completed" {
            n += 1;
        }
    }
    return n;
}

"""Checks that are KNOWN GOOD on this commit. `success` only -- see RED_CONCLUSIONS for why the
asymmetry runs this way round: recording is strict (a name must have actually passed to become
gateable) and gating is strict too (only a real failure reds), so both edges fail towards
"cannot judge" rather than towards a false red on someone else's breakage."""
def passing_names(raw: str) -> list[str] {
    out: set[str] = set();
    for (name, status, concl) in check_rows(raw) {
        if status == "completed" and concl == "success" {
            out.add(name);
        }
    }
    return sorted(out);
}

def failing_names(raw: str) -> list[str] {
    out: set[str] = set();
    for (name, status, concl) in check_rows(raw) {
        if status == "completed" and concl in RED_CONCLUSIONS {
            out.add(name);
        }
    }
    return sorted(out);
}

def read_file(path: str) -> str {
    with open(path, "r") as f {
        return f.read();
    }
}

def record(raw_path: str, baseline_path: str) -> int {
    passing: list[str] = passing_names(read_file(raw_path));
    with open(baseline_path, "w") as f {
        f.write(json.dumps({"passing": passing, "count": len(passing),
                            "recorded": today()}, indent=2) + "\n");
    }
    return len(passing);
}

"""(code, new_failures). Code 2 covers BOTH "no baseline file" and "a baseline with nothing green
in it" -- a totally red night upstream is "cannot gate", never "everything is a new failure"."""
def gate(raw_path: str, baseline_path: str) -> tuple[int, list[str]] {
    if not os.path.exists(baseline_path) {
        return (2, []);
    }
    baseline: dict = parse_obj(read_file(baseline_path));
    known_good: list[str] = [str(x) for x in as_list(baseline["passing"])];
    if not known_good {
        return (2, []);
    }
    new_fails: list[str] = [n for n in failing_names(read_file(raw_path)) if n in known_good];
    return ((1 if new_fails else 0), new_fails);
}

"""Project `gh pr list --json number,headRefName,url,title` into TSV, keeping ONLY heads under
<prefix>.

The filter is a SAFETY INVARIANT, not a convenience. `gh pr list --author @me` also matches a PR
the operator opened by hand from an unrelated branch, and everything downstream of this projection
fetches, rebases and force-pushes what it is handed. Tabs in a title are replaced because the
consumer is a `while IFS=$'\\t' read` loop."""
def pr_rows(raw: str, prefix: str) -> list[str] {
    rows: list[str] = [];
    for item in parse_list(raw) {
        pr: dict = as_dict(item);
        head: str = str(pr["headRefName"]);
        if head.startswith(prefix) {
            rows.append("\t".join([str(pr["number"]), head, str(pr["url"]),
                                   str(pr["title"]).replace("\t", " ")]));
        }
    }
    return rows;
}

"""The exact schema of one $LOG_DIR/prs.jsonl line, and which of its keys are numeric.

RECONCILIATION B3: this artifact is JSONL, not TSV, because Plan 4's digest reads prs.jsonl and its
reader returns [] for a file it cannot parse -- so a wrong shape here renders an EMPTY PR table
every night, forever, with no error anywhere. That is the "did not run scored as passed" class in
the one unattended channel this project has.

Which is also why every key is REQUIRED and no unknown key is tolerated: bash composing this by
hand is exactly how a key gets dropped or misspelled, and the digest cannot tell a missing key from
a PR that had nothing to say."""
glob PR_ROW_KEYS: list[str] = ["number", "title", "task", "url", "mirror", "ci", "attempts"];
glob PR_ROW_INT_KEYS: list[str] = ["number", "attempts"];

"""Project `k=v` argv into one prs.jsonl line. bash never composes JSON (global constraint).

`number` and `attempts` are parsed with int(), which RAISES on anything non-numeric rather than
defaulting to 0: a silent 0 would render in the digest as a real PR #0 with zero attempts."""
def pr_json(kvs: list[str]) -> str {
    row: dict = {};
    for kv in kvs {
        if "=" not in kv {
            raise ValueError("cigate row: '" + kv + "' is not key=value");
        }
        parts: list[str] = kv.split("=", 1);
        row[parts[0]] = parts[1];
    }
    missing: list[str] = [k for k in PR_ROW_KEYS if k not in row];
    if missing {
        raise ValueError("cigate row: missing required key(s): " + ",".join(missing)
                         + ". The digest reads all of " + ",".join(PR_ROW_KEYS)
                         + " and renders nothing for a row it cannot read.");
    }
    # str(k), not k: `row` is dict[any] here (it came from argv), so the comprehension is
    # list[<any>] and `extra: list[str] = ...` fails jac check with E1001.
    extra: list[str] = [str(k) for k in row.keys() if str(k) not in PR_ROW_KEYS];
    if extra {
        raise ValueError("cigate row: unknown key(s): " + ",".join(sorted(extra))
                         + ". Add it to PR_ROW_KEYS and to Plan 4's digest together, or the value"
                         + " is written every night and read by nothing.");
    }
    for k in PR_ROW_INT_KEYS {
        row[k] = int(str(row[k]));
    }
    return json.dumps(row);
}

with entry:__main__ {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "parse" and len(args) == 3 {
        for (name, status, concl) in check_rows(read_file(args[2])) {
            print(name + "\t" + status + "\t" + concl);
        }
    } elif cmd == "ran" and len(args) == 3 {
        print(completed_count(read_file(args[2])));
    } elif cmd == "record" and len(args) == 4 {
        print(record(args[2], args[3]));
    } elif cmd == "gate" and len(args) == 4 {
        (code, new_fails) = gate(args[2], args[3]);
        if code == 2 {
            eprint("cigate: no usable CI baseline (" + args[3] + ") -- not gating this PR");
        }
        for f in new_fails {
            eprint("NEW CI FAILURE: " + f);
        }
        sys.exit(code);
    } elif cmd == "prs" and len(args) == 3 {
        for row in pr_rows(read_stdin(), args[2]) {
            print(row);
        }
    } elif cmd == "row" and len(args) > 2 {
        print(pr_json(args[2:]));
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run cigate.jac parse|ran <checks.json>");
        eprint("       jac run cigate.jac record <checks.json> <baseline.json>");
        eprint("       jac run cigate.jac gate   <checks.json> <baseline.json>");
        eprint("       jac run cigate.jac prs <branch-prefix>   (gh pr list --json ... on stdin)");
        eprint("       jac run cigate.jac row number=.. title=.. task=.. url=.. mirror=.. ci=.. attempts=..");
        sys.exit(2);
    }
}

"""A synthetic check-runs payload, in the endpoint's real shape."""
def _payload(triples: list[tuple[str, str, str]]) -> str {
    runs: list[dict] = [];
    for (name, status, concl) in triples {
        runs.append({"name": name, "status": status,
                     "conclusion": None if concl == "" else concl});
    }
    return json.dumps({"total_count": len(runs), "check_runs": runs});
}

test "a check red on the branch AND red on main is NOT a new failure" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    # main's real shape on 2026-07-30: jac-check failing, two jobs still in_progress
    main_p: str = d + "/main.json";
    with open(main_p, "w") as f {
        f.write(_payload([("jac-check", "completed", "failure"),
                          ("build-jac", "completed", "success"),
                          ("test-compiler", "in_progress", ""),
                          ("installer-test", "completed", "skipped")]));
    }
    base: str = d + "/ci.json";
    assert record(main_p, base) == 1;                 # only build-jac is known-good
    br: str = d + "/branch.json";
    with open(br, "w") as f {
        f.write(_payload([("jac-check", "completed", "failure"),
                          ("build-jac", "completed", "success")]));
    }
    (code, new_fails) = gate(br, base);
    assert code == 0 and new_fails == [];             # THE point of the whole file
    # ...but breaking a check that passes on main IS red
    bad: str = d + "/bad.json";
    with open(bad, "w") as f {
        f.write(_payload([("jac-check", "completed", "failure"),
                          ("build-jac", "completed", "failure")]));
    }
    (c2, n2) = gate(bad, base);
    assert c2 == 1 and n2 == ["build-jac"];
}

test "only `success` counts as passing on main; cancelled and in_progress do not" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    main_p: str = d + "/main.json";
    with open(main_p, "w") as f {
        # three of the last five ci.yml runs on main were CANCELLED -- a cancelled check says
        # nothing about the branch, so it must not become a baseline the branch can violate.
        f.write(_payload([("test-runtime", "completed", "cancelled"),
                          ("test-compiler", "in_progress", ""),
                          ("changes", "completed", "success")]));
    }
    base: str = d + "/ci.json";
    assert record(main_p, base) == 1;
    assert as_list(parse_obj(read_file(base))["passing"]) == ["changes"];
    br: str = d + "/branch.json";
    with open(br, "w") as f {
        f.write(_payload([("test-runtime", "completed", "failure"),
                          ("test-compiler", "completed", "failure"),
                          ("changes", "completed", "success")]));
    }
    (code, new_fails) = gate(br, base);
    assert code == 0 and new_fails == [];
}

test "the branch side reds only on real failures, and a missing check gates nothing" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    main_p: str = d + "/main.json";
    with open(main_p, "w") as f {
        f.write(_payload([("a", "completed", "success"), ("b", "completed", "success"),
                          ("c", "completed", "success"), ("d", "completed", "success")]));
    }
    base: str = d + "/ci.json";
    assert record(main_p, base) == 4;
    br: str = d + "/branch.json";
    with open(br, "w") as f {
        # a: skipped by a path filter -- not red. b: cancelled -- not red. c: timed out -- RED.
        # d: absent entirely (CI's path filters legitimately drop jobs) -- not red.
        f.write(_payload([("a", "completed", "skipped"), ("b", "completed", "cancelled"),
                          ("c", "completed", "timed_out")]));
    }
    (code, new_fails) = gate(br, base);
    assert code == 1 and new_fails == ["c"];
}

test "no baseline, and an EMPTY baseline, both mean no gate -- never a red" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    br: str = d + "/branch.json";
    with open(br, "w") as f {
        f.write(_payload([("a", "completed", "failure")]));
    }
    (c1, _n1) = gate(br, d + "/nosuch.json");
    assert c1 == 2;
    # nothing green on main at all (a totally red night upstream) is "cannot gate", not "all red"
    empty: str = d + "/empty.json";
    with open(empty, "w") as f {
        f.write(json.dumps({"passing": [], "count": 0, "recorded": "2026-07-30"}));
    }
    (c2, _n2) = gate(br, empty);
    assert c2 == 2;
}

test "a capture CI has not finished is counted, not guessed at" {
    # `ran` is this file's assert_suite_ran: an all-queued capture has zero failures and zero
    # passes, which is indistinguishable from a clean run by any failure-counting logic. The
    # caller checks this BEFORE reading anything into the gate's answer.
    import tempfile;
    d: str = tempfile.mkdtemp();
    p: str = d + "/queued.json";
    with open(p, "w") as f {
        f.write(_payload([("a", "queued", ""), ("b", "in_progress", "")]));
    }
    assert completed_count(read_file(p)) == 0;
    assert failing_names(read_file(p)) == [];         # green-looking WITHOUT the ran check
    q: str = d + "/mixed.json";
    with open(q, "w") as f {
        f.write(_payload([("a", "completed", "success"), ("b", "in_progress", "")]));
    }
    assert completed_count(read_file(q)) == 1;
}

test "a truncated capture is refused, not silently under-gated" {
    # main's head commit carried EXACTLY 30 check runs on 2026-07-30 and the endpoint's default
    # page size is 30. Forget ?per_page=100 and the baseline silently loses names, which un-gates
    # those checks forever. total_count is the only signal that this happened.
    import tempfile;
    d: str = tempfile.mkdtemp();
    p: str = d + "/truncated.json";
    with open(p, "w") as f {
        f.write(json.dumps({"total_count": 30, "check_runs": [
            {"name": "a", "status": "completed", "conclusion": "success"}]}));
    }
    caught: bool = False;
    try {
        completed_count(read_file(p));
    } except ValueError as e {
        caught = True;
        assert "truncated" in str(e);
    }
    assert caught;
}

test "a prs.jsonl row is one typed JSON line, and every schema slip raises" {
    line: str = pr_json(["number=7301", "title=remove dead pipe", "task=dead-code",
                         "url=https://github.com/jaseci-labs/jac/pull/7301",
                         "mirror=green", "ci=pending", "attempts=0"]);
    assert "\n" not in line;                          # JSONL: one object, one line
    got: dict = parse_obj(line);
    # number/attempts are INTS, not the strings bash handed over
    assert got["number"] == 7301 and got["attempts"] == 0;
    assert got["task"] == "dead-code" and got["ci"] == "pending";
    # a title carrying a tab or a newline must not break the line discipline
    multi: str = pr_json(["number=1", "title=a\tb\nc", "task=t", "url=u", "mirror=green",
                          "ci=pending", "attempts=0"]);
    assert "\n" not in multi;
    assert parse_obj(multi)["title"] == "a\tb\nc";
    # a MISSING key must raise: the digest cannot tell it from a PR that had nothing to say
    missing: bool = False;
    try {
        pr_json(["number=1", "title=t", "task=t", "url=u", "mirror=green", "ci=pending"]);
    } except ValueError as e {
        missing = True;
        assert "attempts" in str(e);
    }
    assert missing;
    # an UNKNOWN key must raise too, or bash writes a field nothing ever reads
    unknown: bool = False;
    try {
        pr_json(["number=1", "title=t", "task=t", "url=u", "mirror=green", "ci=pending",
                 "attempts=0", "state=open"]);
    } except ValueError as e {
        unknown = True;
        assert "state" in str(e);
    }
    assert unknown;
    # a non-numeric number must RAISE, never default to 0 -- a silent 0 renders as a real PR #0
    nonnum: bool = False;
    try {
        pr_json(["number=-", "title=t", "task=t", "url=u", "mirror=green", "ci=pending",
                 "attempts=0"]);
    } except ValueError {
        nonnum = True;
    }
    assert nonnum;
}

test "prs keeps only nightshift heads and survives a tab in a title" {
    raw: str = json.dumps([
        {"number": 1, "headRefName": "nightshift/2026-07-30/dead-cli", "url": "u1",
         "title": "refactor: a\tb"},
        {"number": 2, "headRefName": "my-manual-branch", "url": "u2", "title": "hand-written"},
        {"number": 3, "headRefName": "nightshift/2026-07-29/unused", "url": "u3", "title": "t3"},
    ]);
    rows: list[str] = pr_rows(raw, "nightshift/");
    assert len(rows) == 2;
    assert rows[0] == "1\tnightshift/2026-07-30/dead-cli\tu1\trefactor: a b";
    assert rows[1].startswith("3\t");
    # an empty PR list is a legitimate answer and must not raise
    assert pr_rows("[]", "nightshift/") == [];
}
