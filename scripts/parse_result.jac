"""Parse a headless Claude Code JSON envelope (TechnicalPRD 7 S3-A/S3-C).

argv:  findings | report | meta      (stdin: the full envelope from --output-format json)
       field <key>                   (stdin: any JSON object; print the raw value — bash's jq)
       fragment <key>                 (stdin: any JSON object; print field <key> NORMALIZED into
                                       release-note-fragment bullet form — see nslib.normalize_-
                                       fragment_body. Distinct from `field` on purpose: `field` is
                                       used for package/branch/title/etc. too, where prefixing a
                                       bullet would corrupt the value.)
       len                           (stdin: any JSON array; print its length)
       merge <f1.json> <f2.json> ..  (per-shard findings arrays; print one deduped array)
- findings: validate the audit's fenced JSON array; print the normalized array.
- report:   validate the apply session's fenced JSON object; print the normalized object.
- meta:     print {num_turns, total_cost_usd, session_id, is_error} for logging/email.
Malformed output → message on stderr, exit 50 (TPRD 18) so the caller skips the phase.
"""
import sys;
import json;
import from nslib {
    eprint, read_stdin, parse_obj, parse_list, as_dict, normalize_fragment_body, score_of
}

"""Return the body of the last ```json fenced block, or the whole text if none."""
def extract_fenced_json(text: str) -> str {
    marker: str = "```json";
    start: int = text.rfind(marker);
    if start == -1 {
        return text.strip();
    }
    body: str = text[start + len(marker):];
    end: int = body.find("```");
    if end == -1 {
        raise ValueError("unterminated ```json fence");
    }
    return body[:end].strip();
}

def envelope_result(envelope: dict) -> str {
    if "result" not in envelope {
        raise ValueError("envelope has no .result field");
    }
    if envelope.get("is_error", False) {
        raise ValueError("session ended in error: " + str(envelope.get("result"))[:200]);
    }
    return str(envelope["result"]);
}

def require(cond: bool, msg: str) {
    if not cond {
        raise ValueError(msg);
    }
}

"""ONE union of rule strings across all four tasks, deliberately not a per-task table. The rule
only feeds the fingerprint (nslib.fingerprint) and the digest; nothing branches on it except
selector.jac's vestigial-test sweep, and that path independently verifies every file it touches
(is_vestigial) rather than trusting the label. A per-task rule list would be config nothing reads."""
def valid_rules() -> list[str] {
    return ["dead-code", "duplication", "over-abstraction", "reinvented-stdlib", "unneeded-dep",
            "simplify",                                             # dead-code / abstraction
            "dep-drift", "todo", "doc-drift", "warning", "skipped-test",   # maintenance
            "missing-test"];                                        # coverage
}

glob COMPLEXITY_LEVELS: list[str] = ["trivial", "mechanical", "judgement"];

"""Which keys a finding must carry, per [tasks.<task>].scoring (design spec 3.2).

  loc_saved      the change REMOVES lines: est_loc_saved is both the score weight and what the
                 theme budgets against loc_per_theme.
  risk_weighted  the change ADDS lines: gap_severity is the weight, est_loc_added is what gets
                 budgeted, and test_file is the path the agent intends to write -- without it a
                 coverage theme has no legal write target at all.

Returned as (required-keys, key-to-strip) so the surviving finding SELF-DESCRIBES its mode and
nothing downstream has to be told which one it is."""
def schema_for(mode: str) -> (list[str], str) {
    if mode == "loc_saved" {
        return (["est_loc_saved"], "gap_severity");
    }
    if mode == "risk_weighted" {
        return (["gap_severity", "est_loc_added", "test_file"], "est_loc_saved");
    }
    raise ValueError("unknown scoring mode: " + mode);
}

def validate_finding(f: dict, task: str, mode: str) -> dict {
    (extra, strip) = schema_for(mode);
    for key in ["file", "rule", "snippet", "summary", "confidence", "risk", "theme_hint",
                "complexity"] + extra {
        require(key in f, "finding missing key: " + key);
    }
    require(str(f["rule"]) in valid_rules(), "unknown rule: " + str(f["rule"]));
    for key in extra {
        if key != "test_file" {
            f[key] = int(f[key]);
        }
    }
    if strip in f {
        del f[strip];
    }
    # clamp confidence/risk to [1..5] — the orchestrator, not the agent, is the authority (TPRD S3-B)
    f["confidence"] = max(1, min(5, int(f["confidence"])));
    f["risk"] = max(1, min(5, int(f["risk"])));
    # An unrecognised complexity clamps to `judgement`, the EXPENSIVE model. Failing the other way
    # would hand a hard refactor to the cheap model on the strength of a typo, and the one-way
    # escalation in tier2_apply means a judgement theme never gets demoted anyway.
    if str(f.get("complexity", "")) not in COMPLEXITY_LEVELS {
        f["complexity"] = "judgement";
    }
    # The TASK is stamped by the harness, never taken from the agent: it decides which prompt, which
    # budget, and (through the branch name) which write permissions the theme gets.
    f["task"] = task;
    return f;
}

def validate_findings(raw: str, task: str, mode: str) -> list[dict] {
    items: list = parse_list(extract_fenced_json(raw));
    out: list[dict] = [];
    for item in items {
        if isinstance(item, dict) {
            out.append(validate_finding(item, task, mode));
        } else {
            raise ValueError("finding is not an object");
        }
    }
    return out;
}

def validate_report(raw: str) -> dict {
    rep: dict = parse_obj(extract_fenced_json(raw));
    for key in ["summary", "files", "loc_before", "loc_after", "risk", "release_note_md"] {
        require(key in rep, "report missing key: " + key);
    }
    require(str(rep["risk"]) in ["low", "medium"], "risk must be low|medium");
    rep["loc_before"] = int(rep["loc_before"]);
    rep["loc_after"] = int(rep["loc_after"]);
    if "skipped" not in rep {
        rep["skipped"] = [];
    }
    if "suspected_bugs" not in rep {
        rep["suspected_bugs"] = [];
    }
    return rep;
}

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

def meta(envelope: dict) -> dict {
    return {
        "num_turns": envelope.get("num_turns"),
        "total_cost_usd": envelope.get("total_cost_usd"),
        "session_id": envelope.get("session_id"),
        "is_error": envelope.get("is_error", False),
    };
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "field" and len(args) == 3 {
        value: any = parse_obj(read_stdin()).get(args[2]);
        if value is not None {
            print(value if isinstance(value, str) else json.dumps(value));
        }
    } elif cmd == "fragment" and len(args) == 3 {
        value2: any = parse_obj(read_stdin()).get(args[2]);
        text: str = value2 if isinstance(value2, str) else json.dumps(value2);
        print(normalize_fragment_body(text), end="");
    } elif cmd == "len" {
        print(len(parse_list(read_stdin())));
    } elif cmd in ["findings", "report", "meta"] {
        try {
            envelope: dict = parse_obj(read_stdin());
            if cmd == "meta" {
                print(json.dumps(meta(envelope)));
            } elif cmd == "findings" {
                require(len(args) == 4, "findings needs <task> <scoring>");
                print(json.dumps(validate_findings(envelope_result(envelope), args[2], args[3])));
            } else {
                print(json.dumps(validate_report(envelope_result(envelope))));
            }
        } except ValueError as e {
            eprint("parse_result: " + str(e));
            sys.exit(50);
        }
    } elif cmd == "merge" and len(args) >= 3 {
        arrays: list[list[dict]] = [];
        for path in args[2:] {
            with open(path, "r") as f {
                arrays.append([as_dict(item) for item in parse_list(f.read())]);
            }
        }
        print(json.dumps(merge_findings(arrays)));
    } elif cmd != "" and cmd != "test" {
        eprint("usage: claude -p ... --output-format json | jac run parse_result.jac findings <task> <scoring>");
        eprint("       ... | jac run parse_result.jac report|meta");
        eprint("       ... | jac run parse_result.jac field <key> | fragment <key> | len");
        eprint("       jac run parse_result.jac merge <findings1.json> <findings2.json> ...");
    }
}

test "findings: fenced array validated and clamped" {
    result: str = "prose before\n```json\n[{\"file\": \"a.jac\", \"rule\": \"dead-code\", \"snippet\": \"x\", \"summary\": \"s\", \"est_loc_saved\": 10, \"confidence\": 9, \"risk\": 0, \"theme_hint\": \"dead\", \"complexity\": \"mechanical\"}]\n```";
    envelope: str = json.dumps({"result": result, "is_error": False});
    found: list[dict] = validate_findings(envelope_result(parse_obj(envelope)), "dead-code", "loc_saved");
    assert len(found) == 1;
    assert found[0]["confidence"] == 5;
    assert found[0]["risk"] == 1;
}

test "loc_saved schema: est_loc_saved required, complexity clamped, task stamped" {
    body: str = "```json\n[{\"file\": \"a.jac\", \"rule\": \"dead-code\", \"snippet\": \"x\", \"summary\": \"s\", \"est_loc_saved\": 10, \"confidence\": 4, \"risk\": 2, \"theme_hint\": \"dead\", \"complexity\": \"trivial\"}]\n```";
    found: list[dict] = validate_findings(body, "dead-code", "loc_saved");
    assert len(found) == 1;
    assert found[0]["task"] == "dead-code";
    assert found[0]["complexity"] == "trivial";
    assert score_of(found[0]) == 20.0;
}

test "the TASK is stamped from argv, never taken from the finding the agent wrote" {
    # The branch name -- and through it every write permission the S4 gate applies -- is built from
    # this field. An audit that names its own task would be choosing its own permissions.
    body: str = "```json\n[{\"file\": \"a.jac\", \"rule\": \"dead-code\", \"snippet\": \"x\", \"summary\": \"s\", \"task\": \"coverage\", \"est_loc_saved\": 10, \"confidence\": 4, \"risk\": 2, \"theme_hint\": \"d\", \"complexity\": \"trivial\"}]\n```";
    assert validate_findings(body, "dead-code", "loc_saved")[0]["task"] == "dead-code";
}

test "an unrecognised complexity fails SAFE to judgement, not to the cheap model" {
    body: str = "```json\n[{\"file\": \"a.jac\", \"rule\": \"simplify\", \"snippet\": \"x\", \"summary\": \"s\", \"est_loc_saved\": 4, \"confidence\": 3, \"risk\": 1, \"theme_hint\": \"t\", \"complexity\": \"easy-peasy\"}]\n```";
    assert validate_findings(body, "abstraction", "loc_saved")[0]["complexity"] == "judgement";
    # ...and a legitimate cheap value is NOT clamped: without this half, a validator that answered
    # "judgement" unconditionally would satisfy the assertion above and route every night to Opus.
    cheap: str = "```json\n[{\"file\": \"a.jac\", \"rule\": \"simplify\", \"snippet\": \"x\", \"summary\": \"s\", \"est_loc_saved\": 4, \"confidence\": 3, \"risk\": 1, \"theme_hint\": \"t\", \"complexity\": \"mechanical\"}]\n```";
    assert validate_findings(cheap, "abstraction", "loc_saved")[0]["complexity"] == "mechanical";
}

test "risk_weighted schema: gap_severity + est_loc_added + test_file required" {
    ok: str = "```json\n[{\"file\": \"jac/jaclang/cli/pipe.jac\", \"rule\": \"missing-test\", \"snippet\": \"x\", \"summary\": \"s\", \"gap_severity\": 40, \"est_loc_added\": 30, \"test_file\": \"jac/tests/cli/test_pipe.jac\", \"confidence\": 4, \"risk\": 2, \"theme_hint\": \"cli\", \"complexity\": \"mechanical\"}]\n```";
    found: list[dict] = validate_findings(ok, "coverage", "risk_weighted");
    assert found[0]["est_loc_added"] == 30;
    assert score_of(found[0]) == 80.0;
    # a coverage finding with no test_file has no legal path to write anything: reject it here
    # rather than let the S4 scope gate discard the whole theme after a 25-minute apply session.
    bad: str = "```json\n[{\"file\": \"a.jac\", \"rule\": \"missing-test\", \"snippet\": \"x\", \"summary\": \"s\", \"gap_severity\": 4, \"est_loc_added\": 3, \"confidence\": 4, \"risk\": 2, \"theme_hint\": \"t\", \"complexity\": \"trivial\"}]\n```";
    raised: bool = False;
    try {
        validate_findings(bad, "coverage", "risk_weighted");
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "a loc_saved task's finding is rejected when it carries only the coverage weight" {
    # The mirror of the case above, and the one that keeps schema_for from being a no-op: a
    # dead-code audit that emitted gap_severity instead of est_loc_saved must not be accepted and
    # then scored off a key its own task does not budget against.
    body: str = "```json\n[{\"file\": \"a.jac\", \"rule\": \"dead-code\", \"snippet\": \"x\", \"summary\": \"s\", \"gap_severity\": 40, \"confidence\": 4, \"risk\": 2, \"theme_hint\": \"t\", \"complexity\": \"trivial\"}]\n```";
    raised: bool = False;
    try {
        validate_findings(body, "dead-code", "loc_saved");
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "an unknown scoring mode raises rather than validating against nothing" {
    raised: bool = False;
    try {
        schema_for("vibes");
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "the other mode's weight field is stripped, so score_of can never read the wrong one" {
    # An audit that emits BOTH keys would otherwise be scored by whichever branch happens to win.
    body: str = "```json\n[{\"file\": \"a.jac\", \"rule\": \"missing-test\", \"snippet\": \"x\", \"summary\": \"s\", \"gap_severity\": 40, \"est_loc_added\": 30, \"est_loc_saved\": 999, \"test_file\": \"jac/tests/t.jac\", \"confidence\": 1, \"risk\": 1, \"theme_hint\": \"t\", \"complexity\": \"trivial\"}]\n```";
    f: dict = validate_findings(body, "coverage", "risk_weighted")[0];
    assert "est_loc_saved" not in f;
    assert score_of(f) == 40.0;
    # ...and the same in the other direction, so "strip" cannot be hardcoded to one key.
    body2: str = "```json\n[{\"file\": \"a.jac\", \"rule\": \"dead-code\", \"snippet\": \"x\", \"summary\": \"s\", \"gap_severity\": 999, \"est_loc_saved\": 40, \"confidence\": 1, \"risk\": 1, \"theme_hint\": \"t\", \"complexity\": \"trivial\"}]\n```";
    g: dict = validate_findings(body2, "dead-code", "loc_saved")[0];
    assert "gap_severity" not in g;
    assert score_of(g) == 40.0;
}

test "report: missing key raises" {
    raised: bool = False;
    try {
        validate_report("```json\n{\"summary\": \"s\"}\n```");
    } except ValueError {
        raised = True;
    }
    assert raised;
}

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

test "error envelope raises" {
    raised: bool = False;
    try {
        envelope_result({"result": "boom", "is_error": True});
    } except ValueError {
        raised = True;
    }
    assert raised;
}
