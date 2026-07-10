# Step 3 — Ledger & rotation state (Jac)

## Goal

Build the harness's only database: `scripts/ledger.jac`, a CLI over an append-only
JSONL file (one finding per line, **last writer wins** per fingerprint) plus the
tiny `state.json` (rotation pointer, verify-time estimate, last jac version).
Implements TechnicalPRD §8.1/§8.2 and the finding lifecycle §9. Goal 3 of the PRD
lives here: *never re-litigate* — a finding that was applied, rejected, or deferred
is remembered.

## Prerequisites

Step 2 (`nslib.jac` provides `fingerprint`, `load_ledger`, `append_row`,
`state_read/state_write`, the `as_*` casts).

## Files created

```
~/nightshift/scripts/ledger.jac
~/nightshift/state/                 # ledger.jsonl.cache + state.json appear at runtime
```

## Data shapes (from the TechnicalPRD, unchanged)

Ledger row:

```json
{"fingerprint":"a1b2…","package":"jac-client","file":"jac-client/render/pipe.jac",
 "rule":"dead-code","summary":"unreachable branch after v0.15 kind-dispatch",
 "score":42.0,"est_loc_saved":58,"confidence":4,"risk":2,
 "status":"drafted","attempts":1,"branch":"nightshift/2026-07-10/dead-code-jac-client",
 "pr_url":null,"loc_delta":null,"reason":null,
 "first_seen":"2026-07-10","last_seen":"2026-07-10"}
```

`status ∈ {new, drafted, shipped, rejected, failed_verify, deferred}`.
`state.json`: `{next_package, last_jac_version, verify_estimate_min, ...}`.

Lifecycle (TechnicalPRD §9):

```
            audit           select+apply        S4 green → S5
  (seen) ──▶ new ──────────▶ (in theme) ───────────▶ drafted ──promote──▶ shipped
              │                    │  S4 red                     └─discard─▶ rejected
              │                    ▼                                  ▲
              │              failed_verify ──(attempts<2: retry later)┘
              └──▶ deferred (didn't fit budget; auto-eligible next rotation pass)
```

## Full implementation

### `scripts/ledger.jac`

```jac
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
            "fingerprint": f["fingerprint"], "package": theme["package"], "file": f["file"],
            "rule": f["rule"], "summary": f["summary"], "score": f.get("score"),
            "est_loc_saved": f["est_loc_saved"], "confidence": f["confidence"], "risk": f["risk"],
            "branch": branch,
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
    if cmd == "fingerprint" and len(args) == 5 {
        print(fingerprint(args[2], args[3], args[4]));
    } elif cmd == "get" and len(args) == 4 {
        rows: dict[str, dict] = load_ledger(args[3]);
        if args[2] in rows {
            print(json.dumps(rows[args[2]]));
        }
    } elif cmd == "upsert" and len(args) == 3 {
        print(json.dumps(upsert(args[2], parse_obj(read_stdin()))));
    } elif cmd == "set-status" and len(args) >= 5 {
        extra: dict = parse_obj(args[5]) if len(args) > 5 else {};
        print(json.dumps(set_status(args[4], args[2], args[3], extra)));
    } elif cmd == "tally" and len(args) == 3 {
        print(json.dumps(tally(args[2])));
    } elif cmd == "prunable" and len(args) == 5 {
        for b in prunable_branches(args[4], int(args[3])) {
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
        eprint("usage: jac run ledger.jac fingerprint <relpath> <rule> <snippet>");
        eprint("       jac run ledger.jac get <fp> <ledger.jsonl>");
        eprint("       jac run ledger.jac upsert <ledger.jsonl>            (row JSON on stdin)");
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
    fp: str = fingerprint("a/b.jac", "dead-code", "if x { y; }");
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

test "state roundtrip" {
    import tempfile;
    import os;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as tf {
        path: str = tf.name;
    }
    os.remove(path);
    state: dict = state_read(path);
    state["next_package"] = "jac-byllm";
    state_write(path, state);
    assert state_read(path)["next_package"] == "jac-byllm";
}
```

## Commands

```bash
cd ~/nightshift
jac check scripts/ledger.jac
jac test  scripts/ledger.jac
```

## Acceptance criteria

- [ ] `jac check` clean, `jac test` green (3 tests: upsert/set-status/attempts,
      state roundtrip — plus nslib's last-writer-wins).
- [ ] `jac run scripts/ledger.jac fingerprint a/b.jac dead-code "if x { y; }"`
      prints a 40-char sha1, identical across runs and across whitespace variants
      of the snippet.
- [ ] Full CLI cycle below behaves exactly as shown.

## Verification procedure

```bash
cd ~/nightshift
L=/tmp/ledger-check.jsonl; rm -f "$L"
FP=$(jac run scripts/ledger.jac fingerprint a/b.jac dead-code "if x")
echo "{\"fingerprint\":\"$FP\",\"package\":\"jac\",\"file\":\"a/b.jac\",\"rule\":\"dead-code\",\"summary\":\"s\"}" \
  | jac run scripts/ledger.jac upsert "$L"
jac run scripts/ledger.jac set-status "$FP" failed_verify "$L"        # attempts → 1
jac run scripts/ledger.jac set-status "$FP" failed_verify "$L"        # attempts → 2
jac run scripts/ledger.jac get "$FP" "$L"       # status failed_verify, attempts 2
jac run scripts/ledger.jac tally "$L"           # {"failed_verify": 1}
jac run scripts/ledger.jac state-set next_package '"jac-byllm"' /tmp/state-check.json
jac run scripts/ledger.jac state-get next_package /tmp/state-check.json   # "jac-byllm"
```

The file `/tmp/ledger-check.jsonl` should now contain **three** lines (append-only)
while `get` reflects only the last — that asymmetry *is* the design.

## Notes & traps

- **Append-preferred**: rewriting the file in place would lose the audit trail
  (PRD goal 5). Compaction is deliberately absent from v1 — the file grows by a few
  KB per night; revisit if it ever matters (ponytail: it won't for years).
- The **source of truth** copy lives on the `nightshift/drafts` orphan branch in the
  fork (`ledger.jsonl`); `state/ledger.jsonl.cache` is the working copy. S1 pulls
  it down (step 5), S5/promote/discard push it back (steps 12–13). Two machines
  running Nightshift against one fork would race this — don't do that.
- `set-status` on an unknown fingerprint raises `KeyError` on purpose: a status
  change for a row that was never upserted is a harness bug, not data.
- `upsert-theme` and `by-branch` exist for tier-2/S4/S7 (steps 11–13): rows get a
  `branch` stamp when applied, and later stages resolve rows *by branch* so bash
  never parses theme JSON.
