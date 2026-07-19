"""PR-draft .md files (PRD 8, TechnicalPRD 8.3): render at ship time, read back at promote time.

argv:
  render <report.json> [k=v ...]   report from parse_result.jac plus string overrides
                                   (branch=, package=, date=, tests=) so bash never
                                   composes JSON; stdout: full draft (frontmatter + body)
  git-report <repo_dir> <summary>  synthesize a report JSON from the branch's git diff
                                   (used for the tier-1 autofix branch, which has no agent report)
  meta <draft.md>                  stdout: frontmatter as JSON (machine side of the draft)
  body <draft.md>                  stdout: body only (verbatim `gh pr create --body-file` payload)
"""
import sys;
import json;
import subprocess;
import from nslib { eprint, read_stdin, parse_obj, as_list, as_int, release_fragment }

"""Frontmatter values are JSON literals, so `meta` can parse every value with json.loads."""
def frontmatter_lines(d: dict) -> list[str] {
    lines: list[str] = ["---"];
    for key in ["branch", "package", "date", "title", "risk", "tests", "release_note"] {
        lines.append(key + ": " + json.dumps(d[key]));
    }
    lines.append("files: " + json.dumps(len(as_list(d["files"]))));
    # "loc_before"/"loc_after" carry real git-diff removed/added line counts (ship.sh always
    # overrides these via `git diff --numstat`, not the agent's self-reported file line count).
    lines.append("loc: " + json.dumps({"added": as_int(d["loc_after"]), "removed": as_int(d["loc_before"])}));
    lines.append("---");
    return lines;
}

def body_lines(d: dict) -> list[str] {
    added: int = as_int(d["loc_after"]);
    removed: int = as_int(d["loc_before"]);
    net: int = added - removed;
    net_str: str = ("+" + str(net)) if net >= 0 else ("-" + str(-net));
    lines: list[str] = [
        "# " + str(d["title"]),
        "",
        "## What & why",
        "",
        str(d["summary"]),
        "",
        "This is a nightly-janitor cleanup: existing behavior is preserved, code is removed or",
        "simplified per the ponytail ladder (does it need to exist → stdlib → one line → minimum code).",
        "",
        "## Changes",
        "",
    ];
    for f in as_list(d["files"]) {
        lines.append("- `" + str(f) + "`");
    }
    lines.append("");
    lines.append("Lines: **+" + str(added) + " -" + str(removed) + "** (net " + net_str + ").");
    skipped: list = as_list(d.get("skipped", []));
    if skipped {
        lines.append("");
        lines.append("## Consciously deferred");
        lines.append("");
        for s in skipped {
            lines.append("- `" + str(s["file"]) + "` — " + str(s["reason"]));
        }
    }
    lines += [
        "",
        "## Verification",
        "",
        str(d["tests"]),
        "",
        "## Reviewer checklist",
        "",
        "- [ ] Diff touches only the listed files",
        "- [ ] No behavior change intended or observed",
        "- [ ] Release-note fragment present (`" + str(d["release_note"]) + "`)",
        "- [ ] Risk level (" + str(d["risk"]) + ") matches the nature of the change",
    ];
    return lines;
}

def render(d: dict) -> str {
    if "title" not in d {
        d["title"] = "refactor(" + str(d["package"]) + "): " + str(d["summary"])[:60];
    }
    if "release_note" not in d {
        d["release_note"] = release_fragment(str(d["package"]));
    }
    return "\n".join(frontmatter_lines(d) + [""] + body_lines(d)) + "\n";
}

"""Inverse of render: (frontmatter dict, body string)."""
def split_draft(text: str) -> (dict, str) {
    parts: list[str] = text.split("---\n");
    if len(parts) < 3 {
        raise ValueError("draft has no frontmatter block");
    }
    meta: dict = {};
    for line in parts[1].splitlines() {
        stripped: str = line.strip();
        if stripped and ":" in stripped {
            key: str = stripped.split(":", 1)[0].strip();
            raw: str = stripped.split(":", 1)[1].strip();
            meta[key] = json.loads(raw);
        }
    }
    return (meta, "---\n".join(parts[2:]).lstrip("\n"));
}

"""Report for a branch with no agent session (tier-1 autofix): files + LOC from git itself.
loc_before/after here are diff-relative (removed vs added lines), which is what the digest shows."""
def git_report(repo_dir: str, summary: str) -> dict {
    files_out: str = subprocess.run(
        ["git", "-C", repo_dir, "diff", "--name-only", "main...HEAD"],
        capture_output=True, text=True, check=True).stdout;
    numstat: str = subprocess.run(
        ["git", "-C", repo_dir, "diff", "--numstat", "main...HEAD"],
        capture_output=True, text=True, check=True).stdout;
    added: int = 0;
    removed: int = 0;
    for line in numstat.splitlines() {
        parts: list[str] = line.split("\t");
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit() {
            added += int(parts[0]);
            removed += int(parts[1]);
        }
    }
    return {
        "summary": summary,
        "files": [l.strip() for l in files_out.splitlines() if l.strip()],
        "loc_before": removed, "loc_after": added,
        "risk": "low", "release_note_md": summary, "skipped": [], "suspected_bugs": [],
    };
}

with entry:__main__ {   # only dispatch the CLI on direct `jac run`; sendmail.jac imports split_draft
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "frag" and len(args) == 3 {
        print(release_fragment(args[2]));
    } elif cmd == "git-report" and len(args) == 4 {
        print(json.dumps(git_report(args[2], args[3])));
    } elif cmd == "render" and len(args) >= 3 {
        with open(args[2], "r") as f {
            d: dict = parse_obj(f.read());
        }
        for kv in args[3:] {
            if "=" in kv {
                d[kv.split("=", 1)[0]] = kv.split("=", 1)[1];
            }
        }
        print(render(d), end="");
    } elif cmd in ["meta", "body"] and len(args) == 3 {
        with open(args[2], "r") as f {
            (meta, body) = split_draft(f.read());
        }
        if cmd == "meta" {
            print(json.dumps(meta));
        } else {
            print(body, end="");
        }
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run render_draft.jac render <report.json> [branch=... package=... date=... tests=... url=...]");
        eprint("       jac run render_draft.jac frag <pkg>");
        eprint("       jac run render_draft.jac git-report <repo_dir> <summary>");
        eprint("       jac run render_draft.jac meta <draft.md>");
        eprint("       jac run render_draft.jac body <draft.md>");
    }
}

test "render then split roundtrips the frontmatter" {
    d: dict = {
        "branch": "nightshift/2026-07-10/dead-code-jac-client", "package": "jac-client",
        "date": "2026-07-10", "risk": "low",
        "tests": "jac check ok; jac test ok; pre-commit ok",
        "summary": "remove dead render-path duplication",
        "files": ["jac-client/render/pipe.jac"], "loc_before": 512, "loc_after": 143,
        "skipped": [{"file": "jac-client/render/pipe.jac", "reason": "ponytail: kept boundary check"}],
    };
    text: str = render(d);
    (meta, body) = split_draft(text);
    assert meta["branch"] == d["branch"];
    assert meta["loc"]["removed"] == 512;
    assert meta["loc"]["added"] == 143;
    assert meta["files"] == 1;
    assert meta["release_note"] == "docs/docs/community/release_notes/unreleased/jac-client/0000.refactor.md";
    assert body.startswith("# refactor(jac-client):");
    assert "+143 -512" in body;
    assert "net -369" in body;
    assert "Consciously deferred" in body;
}
