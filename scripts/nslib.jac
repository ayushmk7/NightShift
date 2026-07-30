"""Shared primitives for every Nightshift Jac helper.

Everything here is a pure function or thin IO wrapper; CLI entry points live in the
sibling scripts that `import from nslib { ... }`.
"""
import sys;
import os;
import json;
import tomllib;
import from hashlib { sha1 }
import from datetime { date, timedelta }
import from pathlib { PurePosixPath }

def eprint(msg: str) {
    err: any = sys.stderr;
    err.write(msg + "\n");
}

def read_stdin() -> str {
    stream: any = sys.stdin;
    return str(stream.read());
}

"""JSON boundary guards: json.loads returns Any; narrow it or die loudly."""
def parse_obj(s: str) -> dict {
    parsed: any = json.loads(s);
    if isinstance(parsed, dict) {
        return parsed;
    }
    raise ValueError("expected JSON object, got " + type(parsed).__name__);
}

def parse_list(s: str) -> list {
    parsed: any = json.loads(s);
    if isinstance(parsed, list) {
        return parsed;
    }
    raise ValueError("expected JSON array, got " + type(parsed).__name__);
}

"""Any-boundary casts: JSON/TOML values come back as `any`; these narrow with a loud failure."""
def as_dict(v: any) -> dict {
    if isinstance(v, dict) {
        return v;
    }
    raise ValueError("expected dict, got " + type(v).__name__);
}

def as_list(v: any) -> list {
    if isinstance(v, list) {
        return v;
    }
    raise ValueError("expected list, got " + type(v).__name__);
}

def as_int(v: any) -> int {
    if isinstance(v, bool) {
        raise ValueError("expected int, got bool");
    }
    if isinstance(v, int) {
        return v;
    }
    return int(str(v));
}

def as_float(v: any) -> float {
    if isinstance(v, float) {
        return v;
    }
    if isinstance(v, int) {
        return float(v);
    }
    return float(str(v));
}

"""Finding identity (TechnicalPRD 8.1): sha1(relpath \\x1f rule). The snippet is deliberately
NOT hashed: it is LLM-authored prose, re-worded every audit, and hashing it made the same
finding a new fingerprint each night — the ledger never deduped and the same refactor shipped
twice. Collision (two same-rule findings in one file) dedupes conservatively together."""
def fingerprint(relpath: str, rule: str) -> str {
    return sha1((relpath + "\x1f" + rule).encode("utf-8")).hexdigest();
}

"""Selection score (TPRD S3-B step 3, design spec 3.2): weight * confidence / risk. Shared by
selector (packing) and dataset (capture).

The WEIGHT is read off the finding itself rather than passed in, because the finding already says
which mode it is: parse_result.validate_finding requires gap_severity for risk_weighted tasks and
est_loc_saved for loc_saved ones, and DELETES the other. Passing a mode instead would mean
plumbing it through selector, dataset, and every caller that only ever has one finding in hand --
and a carry-over night legitimately holds findings of two different modes at once."""
def score_of(f: dict) -> float {
    weight: int = int(f["gap_severity"]) if "gap_severity" in f else int(f["est_loc_saved"]);
    return float(weight * int(f["confidence"])) / float(int(f["risk"]));
}

def today() -> str {
    return date.today().isoformat();
}

def days_ago(iso: str) -> int {
    return (date.today() - date.fromisoformat(iso)).days;
}

def valid_statuses() -> list[str] {
    return ["new", "drafted", "shipped", "rejected", "failed_verify", "deferred"];
}

"""Ledger IO: append-only JSONL, one row per finding, last line per fingerprint wins."""
def load_ledger(path: str) -> dict[str, dict] {
    rows: dict[str, dict] = {};
    if not os.path.exists(path) {
        return rows;
    }
    with open(path, "r") as f {
        for line in f {
            stripped: str = line.strip();
            if stripped {
                row: dict = parse_obj(stripped);
                rows[str(row["fingerprint"])] = row;
            }
        }
    }
    return rows;
}

def append_row(path: str, row: dict) {
    with open(path, "a") as f {
        f.write(json.dumps(row) + "\n");
    }
}

def state_read(path: str) -> dict {
    if not os.path.exists(path) {
        return {};
    }
    with open(path, "r") as f {
        return parse_obj(f.read());
    }
}

def state_write(path: str, state: dict) {
    with open(path, "w") as f {
        f.write(json.dumps(state, indent=2) + "\n");
    }
}

"""Config access ([protect].globs et al) straight from nightshift.toml."""
def load_config_toml(path: str) -> dict {
    with open(path, "rb") as f {
        parsed: any = tomllib.load(f);
        if isinstance(parsed, dict) {
            return parsed;
        }
    }
    raise ValueError("not a TOML table: " + path);
}

def load_globs(config_path: str) -> list[str] {
    globs: any = load_config_toml(config_path)["protect"]["globs"];
    if isinstance(globs, list) {
        return [str(g) for g in globs];
    }
    raise ValueError("[protect].globs missing in " + config_path);
}

"""Positive glob marks protected; a later `!glob` carves an exception (TPRD 6 [protect]).
Uses PurePosixPath.full_match, so `**` crosses directories (needs Python >= 3.13)."""
def is_protected(path: str, globs: list[str]) -> bool {
    p = PurePosixPath(path);
    hit: bool = False;
    for g in globs {
        if g.startswith("!") {
            if p.full_match(g[1:]) {
                hit = False;
            }
        } elif p.full_match(g) {
            hit = True;
        }
    }
    return hit;
}

"""scripts/check-release-notes.sh in the target repo maps exactly one folder:
jac/jaclang/ -> release_notes/unreleased/jaclang/. Everything else (jac/tests/, docs/) requires
no fragment, so return "" and let callers skip it.
The 0000 placeholder is renamed to the PR number after the PR is opened.

The `/tests/` exclusion mirrors check-release-notes.sh:131's `[[ "$file" != */tests/* ]]`, which
fragcheck.is_gated_change already reproduces. Without it the two disagreed in the permissive-
looking but wrong direction: a tests-only jac/jaclang/** theme -- the vestigial test sweep, which
is Nightshift's single most common outcome -- got a fragment that CI does not require, written and
committed by the orchestrator, on every such branch. Both encodings of the rule now live here and
in fragcheck.is_gated_change; they must stay in lockstep."""
glob VALID_FRAGMENT_KINDS: list[str] = ["feature", "bugfix", "breaking", "refactor", "docs"];

def fragment_path(paths: list[str], kind: str) -> str {
    # "" means the TASK declares it needs no fragment ([tasks.coverage].fragment). Checked before
    # the validity clamp below, which would otherwise turn it into "refactor" and write a release
    # note for a tests-only change.
    if kind == "" {
        return "";
    }
    safe_kind: str = kind if kind in VALID_FRAGMENT_KINDS else "refactor";
    for p in paths {
        if str(p).startswith("jac/jaclang/") and "/tests/" not in str(p) {
            return "release_notes/unreleased/jaclang/0000." + safe_kind + ".md";
        }
    }
    return "";
}

"""scripts/check-release-notes.sh's content-format check (~line 176) rejects any fragment line
that does not start with whitespace or '-': a bare sentence like "Removed dead plugin config."
fails CI even though the local gate used to pass it. The agent's `release_note_md` is free-form
English with no format requirement in its own prompt schema, so the write path -- not just the
prompt -- must not let an unbulleted sentence reach a commit. If the text already starts with '-'
(the agent followed the convention), it is left alone; otherwise it is prefixed. This does not
attempt to repair a "- #### heading" disguised as a bullet (check-release-notes.sh's OTHER
malformed-content branch) -- that shape essentially never falls out of a plain-English sentence,
so fragcheck.jac's content-format check exists to catch it rather than this function guessing
how to un-disguise it."""
def normalize_fragment_body(text: str) -> str {
    stripped: str = text.strip();
    if stripped.startswith("-") {
        return stripped + "\n";
    }
    return "- " + stripped + "\n";
}

test "fingerprint is stable per (file, rule) and sensitive to both" {
    assert fingerprint("f.jac", "dup") == fingerprint("f.jac", "dup");
    assert fingerprint("f.jac", "dup") != fingerprint("g.jac", "dup");
    assert fingerprint("f.jac", "dup") != fingerprint("f.jac", "dead-code");
}

test "score_of reads gap_severity for coverage findings and est_loc_saved otherwise" {
    shrink: dict = {"est_loc_saved": 30, "confidence": 4, "risk": 2};
    grow: dict = {"gap_severity": 30, "est_loc_added": 90, "confidence": 4, "risk": 2};
    assert score_of(shrink) == 60.0;
    assert score_of(grow) == 60.0;
    # est_loc_added is NOT the weight -- it is what the theme budgets. A score_of that reached for
    # it would rank a coverage theme by how much test code it writes rather than by how much
    # untested behaviour it protects.
    assert score_of({"gap_severity": 10, "est_loc_added": 900, "confidence": 1, "risk": 1}) == 10.0;
}

test "protected globs with negation" {
    globs: list[str] = ["**/tests/**", "docs/**", "!release_notes/unreleased/**"];
    assert is_protected("jac/tests/fixtures/x.jac", globs);
    assert is_protected("docs/guide/intro.md", globs);
    # fragments live outside docs/ now, so they are simply never protected
    assert not is_protected("release_notes/unreleased/jaclang/0000.refactor.md", globs);
    assert not is_protected("jac/jaclang/compiler/passes.jac", globs);
    # The `!` branch above is NOT exercised by the release_notes assertion: no positive glob in
    # that list matches a release_notes/ path, so the negation never has a `hit` to flip and the
    # assertion passes with the whole `startswith("!")` arm deleted (verified by mutation).
    # This pair is the one that actually flips: `docs/**` marks both files protected, and only the
    # negation carves the first one back out.
    carve: list[str] = ["docs/**", "!docs/api/generated.md"];
    assert not is_protected("docs/api/generated.md", carve);
    assert is_protected("docs/api/other.md", carve);
}

test "fragment_path maps only jac/jaclang changes, and validates the kind" {
    assert fragment_path(["jac/jaclang/compiler/x.jac"], "refactor")
        == "release_notes/unreleased/jaclang/0000.refactor.md";
    assert fragment_path(["jac/jaclang/byllm/y.jac"], "bugfix")
        == "release_notes/unreleased/jaclang/0000.bugfix.md";
    # jac-mcp and the top-level test tree map to nothing: no fragment required
    assert fragment_path(["jac-mcp/server.jac"], "refactor") == "";
    assert fragment_path(["jac/tests/test_x.jac"], "refactor") == "";
    # a tests-only jac/jaclang/** change needs none either -- check-release-notes.sh:131 excludes
    # */tests/*, and fragcheck.is_gated_change mirrors it. This is the vestigial-test sweep, which
    # used to get a fragment CI never asked for.
    assert fragment_path(["jac/jaclang/compiler/tests/test_x.jac"], "refactor") == "";
    assert fragment_path(["jac/jaclang/byllm/tests/test_byllm.jac"], "refactor") == "";
    # a mixed diff (deleted tests plus real source) still gets exactly one fragment
    assert fragment_path(["jac/jaclang/byllm/tests/test_x.jac", "jac/jaclang/byllm/y.jac"], "refactor")
        == "release_notes/unreleased/jaclang/0000.refactor.md";
    # first matching path wins; a mixed diff still gets exactly one fragment
    assert fragment_path(["jac-mcp/a.jac", "jac/jaclang/cli/b.jac"], "docs")
        == "release_notes/unreleased/jaclang/0000.docs.md";
    # an invalid kind falls back to refactor rather than emitting a path CI will reject
    assert fragment_path(["jac/jaclang/cli/b.jac"], "nonsense")
        == "release_notes/unreleased/jaclang/0000.refactor.md";
}

test "an empty kind means the TASK needs no fragment at all" {
    # Distinct from "these paths need none": the coverage task sets fragment = "" in config, and
    # without this branch the empty string would fall through the validity check and be clamped
    # to `refactor` -- writing a release note for a tests-only change.
    assert fragment_path(["jac/jaclang/cli/b.jac"], "") == "";
    # ...and it is the KIND that is empty, not the answer: the same paths at any other kind still
    # produce a fragment, so an implementation that returned "" unconditionally fails here.
    assert fragment_path(["jac/jaclang/cli/b.jac"], "auto")
        == "release_notes/unreleased/jaclang/0000.refactor.md";
    assert fragment_path(["jac/jaclang/cli/b.jac"], "bugfix")
        == "release_notes/unreleased/jaclang/0000.bugfix.md";
}

test "normalize_fragment_body bullets a bare sentence, leaves an already-bulleted one alone" {
    assert normalize_fragment_body("Removed dead plugin config.") == "- Removed dead plugin config.\n";
    assert normalize_fragment_body("- **Fix: x**: y") == "- **Fix: x**: y\n";
    # leading/trailing whitespace on the raw agent string is stripped before the bullet check
    assert normalize_fragment_body("  Removed dead plugin config.  ") == "- Removed dead plugin config.\n";
}

test "ledger last-writer-wins" {
    import tempfile;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as tf {
        path: str = tf.name;
    }
    append_row(path, {"fingerprint": "abc", "status": "new"});
    append_row(path, {"fingerprint": "abc", "status": "drafted"});
    rows: dict[str, dict] = load_ledger(path);
    assert rows["abc"]["status"] == "drafted";
    assert len(rows) == 1;
}
