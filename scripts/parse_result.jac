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
       status                        (stdin: an envelope; print `completed` or `unfinished:<why>`)
       spend <ledger> <ceiling>      (whole-night cost brake; rc 3 once the sum reaches <ceiling>)
- findings: validate the audit's fenced JSON array; print the normalized array.
- report:   validate the apply session's fenced JSON object; print the normalized object.
- meta:     print {num_turns, total_cost_usd, session_id, is_error} for logging/email.
Malformed output → message on stderr, exit 50 (TPRD 18) so the caller skips the phase.
"""
import sys;
import os;
import glob;
import json;
import from nslib {
    eprint, read_stdin, parse_obj, parse_list, as_dict, as_int, normalize_fragment_body, score_of
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

"""Did the session RUN TO COMPLETION, or did it die mid-flight?

These are OPPOSITE failures and the corrective re-prompt in tier2_audit_shard only repairs one of
them. A session killed at the turn cap, at the timebox, or by an API error has NO output to
correct: the 1-turn re-prompt is handed an empty "Previous output" block, answers `[]`, and an
expensive truncated audit is recorded as a clean audit that found nothing -- the project's dominant
defect class, "did not run" scoring as "passed". Observed live 2026-07-31: three reactive lenses
came back is_error=true / subtype=error_max_turns / num_turns=46 against a cap of 45, with NO
.result field at all, and all three were logged "salvaged via corrective re-prompt - 0 findings".
fixtures/session-turn-capped.json is one of those three envelopes, byte for byte.

TOTAL on purpose -- it never raises. A 0-byte or non-JSON envelope is also a session that did not
finish, and the one thing this must never do is leave the caller with no answer, because the
caller's fallback for "no answer" is the salvage path this exists to keep it out of."""
def terminal_status(text: str) -> str {
    envelope: dict = {};
    try {
        envelope = parse_obj(text);
    } except ValueError {
        return "unfinished:no-envelope";
    }
    if envelope.get("is_error", False) {
        reason: any = envelope.get("terminal_reason");
        if reason is None {
            reason = envelope.get("subtype");
        }
        if reason is None {
            reason = "unknown";
        }
        return "unfinished:" + str(reason);
    }
    # `.result` absent is the second half, kept separate so the reason NAMES it: the real max-turns
    # envelope happens to carry both signals, but they are independent and a night is easier to read
    # when "died at the turn cap" and "ended without ever answering" are different words.
    if "result" not in envelope {
        return "unfinished:no-result";
    }
    return "completed";
}

"""Sum a `<session_id>\t<total_cost_usd>` ledger, DEDUPED ON session_id.

--max-budget-usd bounds ONE session; nothing bounded the fifty a night starts, and on 2026-07-31
the audits alone spent $67.36 of the night's $76.55. Raising audit_max_turns (which this same fix
does) raises that number, so this sum is what keeps it bounded.

THE ID IS NOT DECORATION. The first attempt to total that night's cost read the logs/ envelopes and
got $152.82 across "50 sessions" -- exactly double, because every meta-<name>.json is a byte-twin
of the <name>.json it was projected from and both were summed. The real figure is 27 unique
session_ids totalling $76.55. Deduping here means a ledger row written twice (a resumed night
re-entering a stage, a retry loop that records before and after) cannot inflate the total and stop
the night early, and it makes the ledger checkable against `sort -u`.

The row is appended AT THE SESSION, not summed from envelopes afterwards, for the other half of the
same lesson: audit-<name>.json is OVERWRITTEN in place by its retry, so two real attempt-1 Opus
sessions from that night survive in no file and appear in no envelope-derived total at all.

A junk row RAISES rather than being skipped: the caller reads a nonzero status as "stop
scheduling", so an unparseable ledger fails CLOSED. A brake that cannot be evaluated must never
read as "plenty left"."""
def spend_total(lines: list[str]) -> float {
    seen: set[str] = set();
    total: float = 0.0;
    for line in lines {
        text: str = str(line).strip();
        if text == "" {
            continue;
        }
        parts: list[str] = text.split("\t");
        if len(parts) != 2 {
            raise ValueError("malformed spend row (want <session_id>\\t<usd>): " + text);
        }
        sid: str = parts[0];
        if sid in seen {
            continue;
        }
        seen.add(sid);
        total += float(parts[1]);
    }
    return total;
}

def read_spend_ledger(path: str) -> list[str] {
    if not os.path.exists(path) {
        return [];           # no session has reported a cost yet -- $0.00 spent, not an error
    }
    with open(path, "r") as fh {
        return fh.read().splitlines();
    }
}

"""The three envelope families one night writes, and the ONLY files a cost roll-up may read.

`meta-*.json` is a byte-twin projection of the `audit-*.json` / `apply-*.json` it came from, and
`audit-*.json` also matches the `audit-repair-*.json` written by the corrective re-prompt. All three
are listed deliberately -- deduping on session_id below is what makes listing a twin harmless, and
listing the twin is what makes the roll-up survive a night where one half is missing (the repair
sessions write an envelope but NO meta file, which is the $0.28 the old `meta-*.json` glob lost)."""
glob SESSION_ENVELOPE_GLOBS: list[str] = ["audit-*.json", "apply-*.json", "meta-*.json"];

"""Cost/turns/session-count recovered from a log dir's envelopes, DEDUPED ON session_id.

This is the FALLBACK path only. `logs/2026-07-31/` predates lib/common.sh's ns_spend_add and has no
spend.txt at all, so a replay of it has nothing else to read; every night since writes the ledger.

Deduping is not optional. The first attempt to total that night summed every envelope in the dir and
got $152.82 across "50 sessions" -- exactly double, because of the byte-twins described above. The
real night was 27 unique session_ids and $76.55.

It is a FLOOR, not the truth: `audit-<name>.json` is OVERWRITTEN in place by its own retry, so a
night's superseded attempts survive in no envelope and are absent from any number derived here.
That is the whole reason ns_spend_add writes the ledger AT the session -- and the reason this
function reports how it got its answer rather than letting a caller assume."""
def envelope_totals(log_dir: str) -> dict {
    seen: set[str] = set();
    cost: float = 0.0;
    turns: int = 0;
    for pattern in SESSION_ENVELOPE_GLOBS {
        for path in sorted(glob.glob(os.path.join(log_dir, pattern))) {
            with open(path, "r") as fh {
                text: str = fh.read();
            }
            if not text.strip() {
                continue;               # 0-byte envelope: the timebox killed it before it printed
            }
            env: dict = {};
            try {
                env = parse_obj(text);
            } except Exception {
                continue;
            }
            sid_any: any = env.get("session_id");
            if sid_any is None {
                continue;
            }
            sid: str = str(sid_any);
            if sid in seen {
                continue;
            }
            seen.add(sid);
            turns += as_int(env.get("num_turns", 0) or 0);
            cost += float(str(env.get("total_cost_usd", 0) or 0));
        }
    }
    return {"cost_usd": cost, "turns": turns, "sessions": len(seen), "source": "envelopes"};
}

"""What a night actually cost, preferring the ledger and SAYING which source answered.

`spend.txt` is written at the session by ns_spend_add and deduped on session_id by spend_total, so
it is retry-complete and overwrite-proof; the envelopes are neither. Both the digest and the dataset
read this, so neither can quietly disagree with the brake that stopped the night.

Turns always come from the envelopes: the ledger carries cost only, by design (one number per line).

An UNREADABLE ledger falls back rather than raising. spend_total fails closed on purpose -- for
ns_spend_check, whose caller reads nonzero as "stop scheduling" -- but here the caller is a digest or
a dataset row, and a reporting path that dies on a junk line reports nothing at all. The source
string carries the fact instead."""
def night_spend(log_dir: str) -> dict {
    env: dict = envelope_totals(log_dir);
    lines: list[str] = read_spend_ledger(os.path.join(log_dir, "spend.txt"));
    if not lines {
        return env;
    }
    total: float = 0.0;
    try {
        total = spend_total(lines);
    } except ValueError {
        env["source"] = "envelopes (spend.txt unreadable)";
        return env;
    }
    ids: set[str] = set();
    for line in lines {
        stripped: str = str(line).strip();
        if stripped {
            ids.add(stripped.split("\t")[0]);
        }
    }
    return {"cost_usd": total, "turns": as_int(env["turns"]),
            "sessions": len(ids), "source": "spend.txt"};
}

def meta(envelope: dict) -> dict {
    return {
        "num_turns": envelope.get("num_turns"),
        "total_cost_usd": envelope.get("total_cost_usd"),
        "session_id": envelope.get("session_id"),
        "is_error": envelope.get("is_error", False),
    };
}

with entry:__main__ {   # only dispatch the CLI on direct `jac run`; dataset.jac imports the readers
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
    } elif cmd == "status" {
        print(terminal_status(read_stdin()));
    } elif cmd == "spend-row" {
        # One ledger row for one session, or nothing and rc 1. Emitted at the session rather than
        # recovered from the envelope later, because the envelope file is overwritten by the retry.
        row_env: dict = {};
        try {
            row_env = parse_obj(read_stdin());
        } except ValueError {
            sys.exit(1);
        }
        sid_v: any = row_env.get("session_id");
        cost_v: any = row_env.get("total_cost_usd");
        if sid_v is None or cost_v is None {
            sys.exit(1);        # a session that reported no cost puts no row on the ledger
        }
        # str() first: `cost_v` is Any out of a dict, and float(Any) does not type-check (E1053).
        print(str(sid_v) + "\t" + str(float(str(cost_v))));
    } elif cmd == "spend" and len(args) == 4 {
        # Prints the running total EITHER WAY so the caller can log the number it stopped on.
        # rc 3 (not 0/1) so a `spend` that dies for any other reason is still nonzero and still
        # stops the fan-out: every failure direction here is "stop spending".
        spent: float = spend_total(read_spend_ledger(args[2]));
        ceiling: float = float(args[3]);
        print(f"{spent:.2f} of {ceiling:.2f}");
        if spent >= ceiling {
            sys.exit(3);
        }
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

test "a turn-capped session is UNFINISHED, and a completed one is not -- both off the real envelopes" {
    # fixtures/session-turn-capped.json is logs/2026-07-31/audit-reactive-abstraction.json byte for
    # byte: is_error true, subtype error_max_turns, num_turns 46 against a cap of 45, no .result.
    # It was salvaged into "0 findings" on the night it was written; this is the check that says no.
    with open("fixtures/session-turn-capped.json", "r") as f1 {
        capped: str = f1.read();
    }
    assert terminal_status(capped) == "unfinished:max_turns";
    # ...and the other half, without which a classifier hardwired to "unfinished" would pass above
    # and kill every audit in the harness. fixtures/session-completed.json is a real completed one.
    with open("fixtures/session-completed.json", "r") as f2 {
        done: str = f2.read();
    }
    assert terminal_status(done) == "completed";
}

test "every shape of 'no usable envelope' is unfinished, never completed" {
    assert terminal_status("") == "unfinished:no-envelope";            # 0-byte timebox kill
    assert terminal_status("not json at all") == "unfinished:no-envelope";
    # an error envelope that names no reason still must not read as completed
    assert terminal_status(json.dumps({"is_error": True, "result": "partial"})) == "unfinished:unknown";
    # ...and a session that reports success while having answered nothing is named for THAT
    assert terminal_status(json.dumps({"is_error": False, "terminal_reason": "completed"})) == "unfinished:no-result";
    # ...and a plain success envelope with a result is completed, so the salvage still has a caller
    assert terminal_status(json.dumps({"is_error": False, "result": "x"})) == "completed";
}

test "spend sums the ledger, dedupes on session_id, and refuses to guess at junk" {
    assert spend_total([]) == 0.0;
    assert spend_total(["", "  "]) == 0.0;
    # the four real reactive-lens costs from 2026-07-31, with their real session ids
    four: list[str] = ["73bdaaf7-45f7-4980-9d22-5588e3b730da\t9.7682",
                       "145510c4-6438-4e35-a2a2-f678b6332f17\t7.8939",
                       "b0000000-0000-0000-0000-000000000003\t6.1155",
                       "b0000000-0000-0000-0000-000000000004\t4.9464"];
    assert abs(spend_total(four) - 28.724) < 0.001;
    # THE DOUBLE COUNT. Summing the same four sessions twice -- which is exactly what reading both
    # audit-*.json and its meta-*.json byte-twin does -- must not move the total. $152.82 "across 50
    # sessions" was this bug; the night really cost $76.55 across 27 unique session_ids.
    assert abs(spend_total(four + four) - 28.724) < 0.001;
    raised: bool = False;
    try {
        spend_total(["abc\t9.77", "def\tfree"]);
    } except ValueError {
        raised = True;
    }
    assert raised;      # fails CLOSED: the caller reads nonzero as "stop scheduling"
    # ...and a row with no session_id at all is junk too, not a free session
    bare: bool = False;
    try {
        spend_total(["9.77"]);
    } except ValueError {
        bare = True;
    }
    assert bare;
}

test "a ledger that does not exist yet is $0.00 spent, not an error" {
    assert read_spend_ledger("/nonexistent/nightshift/spend.txt") == [];
    assert spend_total(read_spend_ledger("/nonexistent/nightshift/spend.txt")) == 0.0;
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
