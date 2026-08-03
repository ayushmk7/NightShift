"""Nightshift ledger + rotation state CLI (TechnicalPRD 8.1, 8.2, 9).

Ledger = append-only JSONL, one finding per line, last-writer-wins per fingerprint.
Subcommands are called from lib/*.sh; only `upsert` reads stdin.
"""
import sys;
import json;
import from nslib {
    eprint, read_stdin, parse_obj, fingerprint, today, valid_statuses,
    load_ledger, append_row, state_read, state_write, days_ago, as_list, as_dict
}

"""New finding row: stamp dates, default status/attempts, keep first_seen of any prior row."""
def upsert(path: str, row: dict) -> dict {
    existing: dict[str, dict] = load_ledger(path);
    fp: str = str(row["fingerprint"]);
    prior: dict | None = existing[fp] if fp in existing else None;
    if "status" not in row {
        row["status"] = "new";
    }
    if "attempts" not in row {
        row["attempts"] = prior["attempts"] if prior is not None else 0;
    }
    row["first_seen"] = prior["first_seen"] if prior is not None else today();
    row["last_seen"] = today();
    append_row(path, row);
    return row;
}

def set_status(path: str, fp: str, status: str, extra: dict) -> dict {
    if status not in valid_statuses() {
        raise ValueError("invalid status: " + status);
    }
    existing: dict[str, dict] = load_ledger(path);
    if fp not in existing {
        raise KeyError("unknown fingerprint: " + fp);
    }
    row: dict = existing[fp];
    row["status"] = status;
    row["last_seen"] = today();
    if status == "failed_verify" {
        row["attempts"] = int(row["attempts"]) + 1 if "attempts" in row else 1;
    }
    for (k, v) in extra.items() {
        row[k] = v;
    }
    append_row(path, row);
    return row;
}

def tally(path: str) -> dict[str, int] {
    counts: dict[str, int] = {};
    for (_fp, row) in load_ledger(path).items() {
        status: str = str(row["status"]);
        counts[status] = counts[status] + 1 if status in counts else 1;
    }
    return counts;
}

"""Branches whose finding is shipped/rejected and last_seen older than N days (S1 pruning)."""
def prunable_branches(path: str, days: int) -> list[str] {
    branches: list[str] = [];
    for (_fp, row) in load_ledger(path).items() {
        if str(row["status"]) in ["shipped", "rejected"] and "branch" in row and row["branch"] {
            if days_ago(str(row["last_seen"])) > days {
                branch: str = str(row["branch"]);
                if branch not in branches {
                    branches.append(branch);
                }
            }
        }
    }
    return branches;
}

"""One row per theme finding, stamped with the branch (tier-2 calls this after a green apply)."""
def upsert_theme(path: str, theme: dict, branch: str) -> int {
    n: int = 0;
    for item in as_list(theme["findings"]) {
        f: dict = as_dict(item);
        row: dict = {
            "fingerprint": f["fingerprint"], "file": f["file"],
            "rule": f["rule"], "summary": f["summary"], "score": f.get("score"),
            "est_loc_saved": f["est_loc_saved"], "confidence": f["confidence"], "risk": f["risk"],
            "branch": branch,
            # Called only from lib/tier2.sh AFTER the branch is queued, so this is never stamped on
            # a theme whose apply session failed -- those rows stay `new` and are eligible again
            # tomorrow. From here S4 always rules: verify_red writes failed_verify, ship writes
            # drafted/shipped. The one way to get stuck is a night that dies between the queue and
            # the gate, which also leaves an undeleted branch behind and is already a manual clean-up.
            "status": "in_theme",
        };
        upsert(path, row);
        n += 1;
    }
    return n;
}

"""Fingerprints currently attached to a branch — promote/discard resolve rows this way."""
def by_branch(path: str, branch: str) -> list[str] {
    fps: list[str] = [];
    for (fp, row) in load_ledger(path).items() {
        if row.get("branch", "") == branch {
            fps.append(fp);
        }
    }
    fps.sort();
    return fps;
}

"""state-set values: JSON when it parses, raw string otherwise."""
def parse_value(raw: str) -> any {
    try {
        return json.loads(raw);
    } except ValueError {
        return raw;
    }
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "upsert" and len(args) == 3 {
        print(json.dumps(upsert(args[2], parse_obj(read_stdin()))));
    } elif cmd == "set-status" and len(args) >= 5 {
        extra: dict = parse_obj(args[5]) if len(args) > 5 else {};
        print(json.dumps(set_status(args[4], args[2], args[3], extra)));
    } elif cmd == "tally" and len(args) == 3 {
        print(json.dumps(tally(args[2])));
    } elif cmd == "prunable" and len(args) == 4 {
        # argv is [script, "prunable", days, ledger] -- FOUR, not five. This arm demanded 5 and read
        # args[3]/args[4] (the shape of the 3-argument verbs below it) from 2026-07-30 until
        # 2026-08-02, so every call fell through to the usage arm: it printed usage to stderr, exited
        # 0, and emitted no branches. lib/sync.sh:20 pipes this into a `while read` loop, so a prune
        # that never ran was indistinguishable from a night with nothing to prune. No stale branch
        # has ever been deleted. Harness section 38 now runs the real CLI and asserts a branch comes
        # back, because a unit test on prunable_branches() would have passed throughout.
        for b in prunable_branches(args[3], int(args[2])) {
            print(b);
        }
    } elif cmd == "upsert-theme" and len(args) == 5 {
        with open(args[2], "r") as f {
            theme: dict = parse_obj(f.read());
        }
        print(upsert_theme(args[4], theme, args[3]));
    } elif cmd == "by-branch" and len(args) == 4 {
        for fp in by_branch(args[3], args[2]) {
            print(fp);
        }
    } elif cmd == "state-get" and len(args) == 4 {
        state: dict = state_read(args[3]);
        if args[2] in state {
            print(json.dumps(state[args[2]]));
        }
    } elif cmd == "state-set" and len(args) == 5 {
        state2: dict = state_read(args[4]);
        state2[args[2]] = parse_value(args[3]);
        state_write(args[4], state2);
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run ledger.jac upsert <ledger.jsonl>            (row JSON on stdin)");
        eprint("       jac run ledger.jac set-status <fp> <status> <ledger.jsonl> [extra-json]");
        eprint("       jac run ledger.jac tally <ledger.jsonl>");
        eprint("       jac run ledger.jac prunable <days> <ledger.jsonl>");
        eprint("       jac run ledger.jac upsert-theme <theme.json> <branch> <ledger.jsonl>");
        eprint("       jac run ledger.jac by-branch <branch> <ledger.jsonl>");
        eprint("       jac run ledger.jac state-get <key> <state.json>");
        eprint("       jac run ledger.jac state-set <key> <value> <state.json>");
    }
}

test "upsert then set-status: last writer wins, attempts increment" {
    import tempfile;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as tf {
        path: str = tf.name;
    }
    fp: str = fingerprint("a/b.jac", "dead-code");
    upsert(path, {"fingerprint": fp, "package": "jac", "file": "a/b.jac",
                  "rule": "dead-code", "summary": "s"});
    set_status(path, fp, "failed_verify", {});
    set_status(path, fp, "failed_verify", {"reason": "tests red"});
    rows: dict[str, dict] = load_ledger(path);
    assert rows[fp]["status"] == "failed_verify";
    assert rows[fp]["attempts"] == 2;
    assert rows[fp]["reason"] == "tests red";
    assert tally(path)["failed_verify"] == 1;
}

test "upsert_theme accepts a theme shaped like selector split's real output (no package key)" {
    import tempfile;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as tf {
        path: str = tf.name;
    }
    fp: str = fingerprint("jac/jaclang/cli/pipe.jac", "dead-code");
    # selector.jac's pack_themes/split no longer emit a "package" key at all -- this is the real
    # shape (name/slug/files/vestigial_deletions/findings/est_loc/score), not a hypothetical one.
    theme: dict = {
        "name": "pipe cleanup", "slug": "pipe-cleanup",
        "files": ["jac/jaclang/cli/pipe.jac"], "vestigial_deletions": [],
        "findings": [{"fingerprint": fp, "file": "jac/jaclang/cli/pipe.jac", "rule": "dead-code",
                       "summary": "dead branch", "est_loc_saved": 40, "confidence": 5, "risk": 1,
                       "theme_hint": "pipe cleanup", "score": 200.0}],
        "est_loc": 40, "score": 200.0,
    };
    n: int = upsert_theme(path, theme, "nightshift/2026-07-30/pipe-cleanup");
    assert n == 1;
    rows: dict[str, dict] = load_ledger(path);
    assert "package" not in rows[fp];
    assert rows[fp]["branch"] == "nightshift/2026-07-30/pipe-cleanup";
    assert rows[fp]["file"] == "jac/jaclang/cli/pipe.jac";
}

test "state roundtrip" {
    import tempfile;
    import os;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as tf {
        path: str = tf.name;
    }
    os.remove(path);
    state: dict = state_read(path);
    state["verify_estimate_min"] = 7;
    state_write(path, state);
    assert state_read(path)["verify_estimate_min"] == 7;
}
