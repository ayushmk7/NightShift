"""Parse a headless Claude Code JSON envelope (TechnicalPRD 7 S3-A/S3-C).

argv:  findings | report | meta      (stdin: the full envelope from --output-format json)
       field <key>                   (stdin: any JSON object; print the raw value — bash's jq)
- findings: validate the audit's fenced JSON array; print the normalized array.
- report:   validate the apply session's fenced JSON object; print the normalized object.
- meta:     print {num_turns, total_cost_usd, session_id, is_error} for logging/email.
Malformed output → message on stderr, exit 50 (TPRD 18) so the caller skips the phase.
"""
import sys;
import json;
import from nslib { eprint, read_stdin, parse_obj, parse_list }

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

def valid_rules() -> list[str] {
    return ["dead-code", "duplication", "over-abstraction", "reinvented-stdlib", "unneeded-dep", "simplify"];
}

def validate_finding(f: dict) -> dict {
    for key in ["file", "rule", "snippet", "summary", "est_loc_saved", "confidence", "risk", "theme_hint"] {
        require(key in f, "finding missing key: " + key);
    }
    require(str(f["rule"]) in valid_rules(), "unknown rule: " + str(f["rule"]));
    f["est_loc_saved"] = int(f["est_loc_saved"]);
    # clamp confidence/risk to [1..5] — the orchestrator, not the agent, is the authority (TPRD S3-B)
    f["confidence"] = max(1, min(5, int(f["confidence"])));
    f["risk"] = max(1, min(5, int(f["risk"])));
    return f;
}

def validate_findings(raw: str) -> list[dict] {
    items: list = parse_list(extract_fenced_json(raw));
    out: list[dict] = [];
    for item in items {
        if isinstance(item, dict) {
            out.append(validate_finding(item));
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
    } elif cmd in ["findings", "report", "meta"] {
        try {
            envelope: dict = parse_obj(read_stdin());
            if cmd == "meta" {
                print(json.dumps(meta(envelope)));
            } elif cmd == "findings" {
                print(json.dumps(validate_findings(envelope_result(envelope))));
            } else {
                print(json.dumps(validate_report(envelope_result(envelope))));
            }
        } except ValueError as e {
            eprint("parse_result: " + str(e));
            sys.exit(50);
        }
    } elif cmd != "" and cmd != "test" {
        eprint("usage: claude -p ... --output-format json | jac run parse_result.jac findings|report|meta");
        eprint("       ... | jac run parse_result.jac field <key>");
    }
}

test "findings: fenced array validated and clamped" {
    result: str = "prose before\n```json\n[{\"file\": \"a.jac\", \"rule\": \"dead-code\", \"snippet\": \"x\", \"summary\": \"s\", \"est_loc_saved\": 10, \"confidence\": 9, \"risk\": 0, \"theme_hint\": \"dead\"}]\n```";
    envelope: str = json.dumps({"result": result, "is_error": False});
    found: list[dict] = validate_findings(envelope_result(parse_obj(envelope)));
    assert len(found) == 1;
    assert found[0]["confidence"] == 5;
    assert found[0]["risk"] == 1;
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

test "error envelope raises" {
    raised: bool = False;
    try {
        envelope_result({"result": "boom", "is_error": True});
    } except ValueError {
        raised = True;
    }
    assert raised;
}
