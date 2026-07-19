"""Nightshift training-data capture: turns every real night's artifacts into JSONL rows meant
for later fine-tuning a jac-focused model. Append-only, one file per signal type so records can
be joined at training time rather than mutated in place:

  audit_findings.jsonl  one row per RAW finding an audit surfaced, whether or not it shipped
                        (status: applied | dropped_ledger | dropped_protected |
                                 over-theme-budget | over-night-budget | no-clock-left |
                                 not_selected). Captures the model's own judgment (confidence,
                                 risk, score) alongside what actually happened to the finding.
  refactors.jsonl       one row PER FILE in a shipped branch: full before/after content, unified
                        diff, the finding that drove it (null for tier1 autofix), the agent's own
                        summary/risk, real added/removed line counts, and the verify-gate outcome.
                        This is the core (buggy-jac -> clean-jac) pair data.
  nights.jsonl          one row per night whose audit ran AND parsed, including zero-finding
                        nights (real negative signal: "here's real jac-byllm code, nothing worth
                        flagging"). Failed/unparseable audits record nothing. Idempotent per
                        (date, package).
  human_reviews.jsonl   one row per promote/discard decision -- the highest-quality supervision
                        signal, joined to refactors.jsonl by branch name at read time. Empty until
                        `nightshift.sh promote` is actually used.

argv:
  record-audit    <log_dir> <dataset_dir> <date> <package>
  record-refactor <base_ref> <branch_ref> <repo_dir> <dataset_dir> <date> <package>
                  <theme_file_or_dash> <report_file> <added> <removed> <verify_line> <url>
  record-review   <branch> <dataset_dir> <accepted:true|false> <reason>
"""
import sys;
import os;
import json;
import glob;
import subprocess;
import from nslib { eprint, parse_obj, parse_list, as_dict, as_list, as_int, fingerprint, score_of }

def git_show(repo_dir: str, ref: str, path: str) -> str {
    r = subprocess.run(["git", "-C", repo_dir, "show", ref + ":" + path],
        capture_output=True, text=True);
    return r.stdout if r.returncode == 0 else "";
}

def git_diff(repo_dir: str, base_ref: str, branch_ref: str, path: str) -> str {
    r = subprocess.run(["git", "-C", repo_dir, "diff", base_ref, branch_ref, "--", path],
        capture_output=True, text=True);
    return r.stdout;
}

def append_row(path: str, row: dict) {
    with open(path, "a") as f {
        f.write(json.dumps(row) + "\n");
    }
}

"""Every raw finding an audit surfaced tonight, cross-referenced against selection.json to record
what actually happened to it. Idempotent per (date, package) -- a same-day re-run must not append
duplicate rows. A nights row is written only when findings.json parses as a JSON list ([] counts:
"real code, nothing to flag" is signal); an absent or unparseable file is a FAILED audit, not a
clean night, and records nothing."""
def record_audit(log_dir: str, dataset_dir: str, date_s: str, package: str) -> int {
    os.makedirs(dataset_dir, exist_ok=True);
    nights_path: str = os.path.join(dataset_dir, "nights.jsonl");
    if os.path.exists(nights_path) {
        with open(nights_path, "r") as f {
            for line in f {
                stripped: str = line.strip();
                if stripped {
                    row: dict = parse_obj(stripped);
                    if str(row.get("date")) == date_s and str(row.get("package")) == package {
                        eprint("dataset: " + date_s + "/" + package + " already recorded — skipping");
                        return 0;
                    }
                }
            }
        }
    }

    findings_path: str = os.path.join(log_dir, "findings.json");
    if not os.path.exists(findings_path) {
        return 0;
    }
    findings: list = [];
    try {
        findings = parse_list(open(findings_path, "r").read());
    } except Exception {
        eprint("dataset: " + findings_path + " unparseable — failed audit, no row recorded");
        return 0;
    }

    # selection.json carries full finding objects; recompute fingerprints from (file, rule) so
    # the join survives fingerprint-formula changes (legacy files hashed the snippet too).
    # Dropped rows only started carrying "rule" later -- fall back to a file-level join for old ones.
    selected_fps: set[str] = set();
    dropped_by_fp: dict[str, str] = {};
    dropped_by_file: dict[str, str] = {};
    selection_path: str = os.path.join(log_dir, "selection.json");
    if os.path.exists(selection_path) {
        selection: dict = parse_obj(open(selection_path, "r").read());
        for t in as_list(selection.get("themes", [])) {
            for f in as_list(as_dict(t).get("findings", [])) {
                sel: dict = as_dict(f);
                selected_fps.add(fingerprint(str(sel.get("file", "")), str(sel.get("rule", ""))));
            }
        }
        for d in as_list(selection.get("dropped", [])) {
            dd: dict = as_dict(d);
            if "rule" in dd {
                dropped_by_fp[fingerprint(str(dd.get("file", "")), str(dd.get("rule", "")))] = str(dd.get("reason", ""));
            } else {
                dropped_by_file[str(dd.get("file", ""))] = str(dd.get("reason", ""));
            }
        }
    }

    audit_out: str = os.path.join(dataset_dir, "audit_findings.jsonl");
    for f in findings {
        fd: dict = as_dict(f);
        fp: str = fingerprint(str(fd.get("file", "")), str(fd.get("rule", "")));
        status: str = "not_selected";
        if fp in selected_fps {
            status = "applied";
        } elif fp in dropped_by_fp {
            status = dropped_by_fp[fp];
        } elif str(fd.get("file", "")) in dropped_by_file {
            status = dropped_by_file[str(fd.get("file", ""))];
        }
        append_row(audit_out, {
            "date": date_s, "package": package, "file": fd.get("file", ""),
            "rule": fd.get("rule", ""), "summary": fd.get("summary", ""),
            "snippet": fd.get("snippet", ""), "confidence": fd.get("confidence"),
            "risk": fd.get("risk"), "score": score_of(fd),
            "est_loc_saved": fd.get("est_loc_saved"), "fingerprint": fp, "status": status,
        });
    }

    # Whole-night cost: sum every session's meta (audit + one per applied theme), the same
    # convention as sendmail's digest. meta-audit.json alone undercounted the night badly.
    turns: int = 0;
    cost: float = 0.0;
    for mp in sorted(glob.glob(os.path.join(log_dir, "meta-*.json"))) {
        try {
            m: dict = parse_obj(open(mp, "r").read());
        } except Exception {
            continue;
        }
        turns += as_int(m.get("num_turns", 0) or 0);
        cost += float(str(m.get("total_cost_usd", 0) or 0));
    }
    append_row(nights_path, {
        "date": date_s, "package": package, "findings_count": len(findings),
        "themes_selected": len(selected_fps),
        "cost_usd": cost, "turns": turns,
    });
    return len(findings);
}

"""One row per file actually changed in a shipped branch: full before/after content (via `git
show` at the merge-base and at the branch tip -- robust to files that were created or deleted),
the unified diff, and the finding + verify outcome that justified shipping it."""
def record_refactor(base_ref: str, branch_ref: str, repo_dir: str, dataset_dir: str, date_s: str,
                     package: str, theme_file: str, report_file: str, added: int, removed: int,
                     verify_line: str, url: str) -> int {
    os.makedirs(dataset_dir, exist_ok=True);
    rpt: dict = parse_obj(open(report_file, "r").read());

    finding: dict | None = None;
    if theme_file != "-" and os.path.exists(theme_file) {
        theme: dict = parse_obj(open(theme_file, "r").read());
        theme_findings: list = as_list(theme.get("findings", []));
        if theme_findings {
            finding = as_dict(theme_findings[0]);
        }
    }

    files: list[str] = [str(x) for x in as_list(rpt.get("files", []))];
    out_path: str = os.path.join(dataset_dir, "refactors.jsonl");
    n: int = 0;
    for path in files {
        append_row(out_path, {
            # branch_ref may arrive as origin/<branch> (backfill) or bare (live) -- store bare
            "date": date_s, "package": package, "branch": branch_ref.removeprefix("origin/"), "file": path,
            "before": git_show(repo_dir, base_ref, path),
            "after": git_show(repo_dir, branch_ref, path),
            "diff": git_diff(repo_dir, base_ref, branch_ref, path),
            "finding": finding,
            "agent_summary": rpt.get("summary", ""), "risk": rpt.get("risk", "?"),
            "loc_added": added, "loc_removed": removed, "verify": verify_line, "url": url,
            "suspected_bugs": as_list(rpt.get("suspected_bugs", [])),
            "skipped": as_list(rpt.get("skipped", [])),
        });
        n += 1;
    }
    return n;
}

"""The highest-quality supervision signal: a human actually accepted (promoted to a real PR) or
rejected (discarded) this branch. Joined to refactors.jsonl by branch name at training time."""
def record_review(branch: str, dataset_dir: str, accepted: bool, reason: str) -> int {
    os.makedirs(dataset_dir, exist_ok=True);
    append_row(os.path.join(dataset_dir, "human_reviews.jsonl"),
        {"branch": branch, "accepted": accepted, "reason": reason});
    return 1;
}

with entry:__main__ {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "record-audit" and len(args) == 6 {
        print(record_audit(args[2], args[3], args[4], args[5]));
    } elif cmd == "record-refactor" and len(args) == 14 {
        n: int = record_refactor(args[2], args[3], args[4], args[5], args[6], args[7], args[8],
            args[9], as_int(args[10]), as_int(args[11]), args[12], args[13]);
        print(n);
    } elif cmd == "record-review" and len(args) == 6 {
        print(record_review(args[2], args[3], args[4].lower() == "true", args[5]));
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run dataset.jac record-audit <log_dir> <dataset_dir> <date> <package>");
        eprint("       jac run dataset.jac record-refactor <base_ref> <branch_ref> <repo_dir>");
        eprint("                <dataset_dir> <date> <package> <theme_or_dash> <report_file>");
        eprint("                <added> <removed> <verify_line> <url>");
        eprint("       jac run dataset.jac record-review <branch> <dataset_dir> <accepted> <reason>");
    }
}

test "record_audit joins status+score from selection, sums all metas, stays idempotent" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    fp_a: str = fingerprint("a.jac", "dup");
    fp_b: str = fingerprint("b.jac", "dead");
    with open(d + "/findings.json", "w") as f {
        f.write(json.dumps([
            {"file": "a.jac", "rule": "dup", "snippet": "snip a", "summary": "s1", "confidence": 4, "risk": 2, "est_loc_saved": 10},
            {"file": "b.jac", "rule": "dead", "snippet": "snip b", "summary": "s2", "confidence": 3, "risk": 3, "est_loc_saved": 6},
            {"file": "c.jac", "rule": "simplify", "snippet": "s", "summary": "s3", "confidence": 2, "risk": 1, "est_loc_saved": 4},
        ]));
    }
    with open(d + "/selection.json", "w") as f {
        f.write(json.dumps({
            "themes": [{"findings": [{"file": "a.jac", "rule": "dup", "fingerprint": fp_a}]}],
            "dropped": [
                {"fingerprint": fp_b, "file": "b.jac", "rule": "dead", "reason": "over-night-budget"},
                {"fingerprint": "legacy-snippet-hash", "file": "c.jac", "reason": "over-theme-budget"},
            ],
        }));
    }
    with open(d + "/meta-audit.json", "w") as f {
        f.write(json.dumps({"num_turns": 2, "total_cost_usd": 1.5}));
    }
    with open(d + "/meta-apply-x.json", "w") as f {
        f.write(json.dumps({"num_turns": 3, "total_cost_usd": 2.0}));
    }
    ds: str = tempfile.mkdtemp();
    n: int = record_audit(d, ds, "2026-01-01", "jac-byllm");
    assert n == 3;
    with open(ds + "/audit_findings.jsonl", "r") as f {
        rows: list[dict] = [as_dict(json.loads(line)) for line in f.read().splitlines()];
    }
    assert rows[0]["status"] == "applied";
    assert rows[0]["score"] == 20.0;
    assert rows[1]["status"] == "over-night-budget";
    # legacy dropped row without "rule" still joins by file
    assert rows[2]["status"] == "over-theme-budget";
    with open(ds + "/nights.jsonl", "r") as f {
        night: dict = as_dict(json.loads(f.read().splitlines()[0]));
    }
    assert night["findings_count"] == 3 and night["themes_selected"] == 1;
    assert night["turns"] == 5 and night["cost_usd"] == 3.5;

    # same (date, package) again: idempotent, nothing appended
    assert record_audit(d, ds, "2026-01-01", "jac-byllm") == 0;
    with open(ds + "/nights.jsonl", "r") as f {
        assert len(f.read().splitlines()) == 1;
    }

    # unparseable findings.json (0-byte marker of a failed audit) records nothing
    d2: str = tempfile.mkdtemp();
    with open(d2 + "/findings.json", "w") as f {
        f.write("");
    }
    assert record_audit(d2, ds, "2026-01-02", "jac") == 0;

    # a real zero-finding audit ([]) still logs a night row
    d3: str = tempfile.mkdtemp();
    with open(d3 + "/findings.json", "w") as f {
        f.write("[]");
    }
    assert record_audit(d3, ds, "2026-01-03", "jac-byllm") == 0;
    with open(ds + "/nights.jsonl", "r") as f {
        lines: list[str] = f.read().splitlines();
    }
    assert len(lines) == 2;
    assert json.loads(lines[1])["findings_count"] == 0;
}

test "record_refactor pulls real before/after content via git and counts files" {
    import tempfile;
    import subprocess as sp;
    repo: str = tempfile.mkdtemp();
    sp.run(["git", "init", "-q", repo]);
    sp.run(["git", "-C", repo, "config", "user.email", "t@t.com"]);
    sp.run(["git", "-C", repo, "config", "user.name", "t"]);
    with open(repo + "/x.jac", "w") as f {
        f.write("def old() -> int { return 1; }\n");
    }
    sp.run(["git", "-C", repo, "add", "-A"]);
    sp.run(["git", "-C", repo, "commit", "-q", "-m", "base"]);
    base_ref: str = sp.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip();
    # a local branch literally named origin/feat: exercises the origin/-prefix stripping the
    # backfill path needs while keeping every git call resolvable
    sp.run(["git", "-C", repo, "checkout", "-q", "-b", "origin/feat"]);
    with open(repo + "/x.jac", "w") as f {
        f.write("def new() -> int { return 1; }\n");
    }
    sp.run(["git", "-C", repo, "commit", "-q", "-am", "clean"]);

    ds: str = tempfile.mkdtemp();
    with open(ds + "/report.json", "w") as f {
        f.write(json.dumps({"summary": "renamed", "risk": "low", "files": ["x.jac"]}));
    }
    n: int = record_refactor(base_ref, "origin/feat", repo, ds, "2026-01-01", "jac", "-",
        ds + "/report.json", 1, 1, "jac check ok", "https://example.test/feat");
    assert n == 1;
    with open(ds + "/refactors.jsonl", "r") as f {
        row: dict = as_dict(json.loads(f.read().splitlines()[0]));
    }
    assert "def old" in row["before"] and "def new" in row["after"];
    assert row["file"] == "x.jac" and row["agent_summary"] == "renamed";
    assert row["branch"] == "feat";
}
