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

"""Finding identity (TechnicalPRD 8.1): sha1(relpath \\x1f rule \\x1f whitespace-normalized snippet)."""
def fingerprint(relpath: str, rule: str, snippet: str) -> str {
    norm: str = " ".join(snippet.split());
    return sha1((relpath + "\x1f" + rule + "\x1f" + norm).encode("utf-8")).hexdigest();
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

"""The repo's release-note dir names differ from package names (check-release-notes.sh):
jac code lives in jac/jaclang -> fragment dir 'jaclang'; jac-byllm/byllm -> 'byllm'."""
def fragment_dir(pkg: str) -> str {
    mapping: dict[str, str] = {"jac": "jaclang", "jac-byllm": "byllm",
                               "jac-mcp": "jac-mcp", "jac-scale": "jac-scale"};
    return mapping[pkg] if pkg in mapping else pkg;
}

def release_fragment(pkg: str) -> str {
    return "docs/docs/community/release_notes/unreleased/" + fragment_dir(pkg) + "/0000.refactor.md";
}

test "fingerprint normalizes whitespace" {
    assert fingerprint("f.jac", "dup", "x   y") == fingerprint("f.jac", "dup", "x y");
    assert fingerprint("f.jac", "dup", "x y") != fingerprint("g.jac", "dup", "x y");
}

test "protected globs with negation" {
    globs: list[str] = ["**/tests/**", "docs/**", "!docs/docs/community/release_notes/unreleased/**"];
    assert is_protected("jac/tests/fixtures/x.jac", globs);
    assert is_protected("docs/guide/intro.md", globs);
    assert not is_protected("docs/docs/community/release_notes/unreleased/jac/0000.refactor.md", globs);
    assert not is_protected("jac/compiler/passes.jac", globs);
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
