"""PR-draft .md files (PRD 8, TechnicalPRD 8.3): render at ship time, read back at promote time.

argv:
  render <report.json> [k=v ...]   report from parse_result.jac plus string overrides
                                   (branch=, package=, date=, tests=) so bash never
                                   composes JSON; stdout: full draft (frontmatter + body)
  frag <report.json> <kind>        stdout: release-note fragment path for this report's files at
                                   the task's declared fragment kind ("" if none of them touch
                                   jac/jaclang/, or if the kind itself is "")
  meta <draft.md>                  stdout: frontmatter as JSON (machine side of the draft)
  body <draft.md>                  stdout: body only (verbatim `gh pr create --body-file` payload)
"""
import sys;
import json;
import from nslib { eprint, read_stdin, parse_obj, as_list, as_int, fragment_path }

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
        d["release_note"] = fragment_path([str(f) for f in as_list(d["files"])], "refactor");
    }
    return "\n".join(frontmatter_lines(d) + [""] + body_lines(d)) + "\n";
}

"""The fragment path implied by the files the agent actually touched (the report's `files`, not
the theme's -- the theme lists what was planned), at the kind the TASK declares.

`auto` (maintenance) resolves from the agent's own reported fragment_kind, which fragment_path
then clamps to a valid name -- so an agent cannot invent a filename CI will reject. `""`
(coverage) means the task needs no fragment at all. This was one of three sites that hardcoded
`refactor` while check_scope.jac already honoured theme.fragment_kind; the LATENT COUPLING note
that used to live here is gone with the coupling."""
def frag_for_report(report_path: str, kind: str) -> str {
    with open(report_path, "r") as f {
        rep: dict = parse_obj(f.read());
    }
    resolved: str = kind;
    if kind == "auto" {
        resolved = str(rep.get("fragment_kind", "refactor"));
    }
    return fragment_path([str(p) for p in as_list(rep["files"])], resolved);
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

with entry:__main__ {   # only dispatch the CLI on direct `jac run`; sendmail.jac imports split_draft
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "frag" and len(args) == 4 {
        print(frag_for_report(args[2], args[3]));
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
        eprint("       jac run render_draft.jac frag <report.json> <fragment_kind>");
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
        "files": ["jac/jaclang/cli/pipe.jac"], "loc_before": 512, "loc_after": 143,
        "skipped": [{"file": "jac/jaclang/cli/pipe.jac", "reason": "ponytail: kept boundary check"}],
    };
    text: str = render(d);
    (meta, body) = split_draft(text);
    assert meta["branch"] == d["branch"];
    assert meta["loc"]["removed"] == 512;
    assert meta["loc"]["added"] == 143;
    assert meta["files"] == 1;
    assert meta["release_note"] == "release_notes/unreleased/jaclang/0000.refactor.md";
    assert body.startswith("# refactor(jac-client):");
    assert "+143 -512" in body;
    assert "net -369" in body;
    assert "Consciously deferred" in body;
}

test "frag returns a jaclang path for core changes and empty for jac-mcp only" {
    # Exercises what the VERB computes off a real report file, not nslib.fragment_path directly
    # (already covered in nslib.jac): pointing frag at the wrong key turns this red.
    import tempfile;
    d: str = tempfile.mkdtemp();
    core_path: str = d + "/report-core.json";
    mcp_path: str = d + "/report-mcp.json";
    with open(core_path, "w") as f {
        f.write(json.dumps({"summary": "s", "files": ["jac/jaclang/cli/a.jac"],
                            "loc_before": 10, "loc_after": 2, "risk": "low",
                            "release_note_md": "note"}));
    }
    with open(mcp_path, "w") as f {
        f.write(json.dumps({"summary": "s", "files": ["jac-mcp/server.jac"],
                            "loc_before": 10, "loc_after": 2, "risk": "low",
                            "release_note_md": "note"}));
    }
    assert frag_for_report(core_path, "refactor") == "release_notes/unreleased/jaclang/0000.refactor.md";
    assert frag_for_report(mcp_path, "refactor") == "";
}

test "auto resolves the kind from the agent's report and clamps an invented one" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    p: str = d + "/r.json";
    with open(p, "w") as f {
        f.write(json.dumps({"files": ["jac/jaclang/cli/a.jac"], "fragment_kind": "bugfix"}));
    }
    assert frag_for_report(p, "auto") == "release_notes/unreleased/jaclang/0000.bugfix.md";
    # a NON-auto task ignores whatever the agent reported: the task's declared kind wins, so an
    # implementation that always read rep["fragment_kind"] fails here.
    assert frag_for_report(p, "refactor") == "release_notes/unreleased/jaclang/0000.refactor.md";
    assert frag_for_report(p, "") == "";
    q: str = d + "/q.json";
    with open(q, "w") as f {
        f.write(json.dumps({"files": ["jac/jaclang/cli/a.jac"], "fragment_kind": "chore"}));
    }
    assert frag_for_report(q, "auto") == "release_notes/unreleased/jaclang/0000.refactor.md";
    # an auto task whose agent reported nothing at all still gets a valid name
    r: str = d + "/s.json";
    with open(r, "w") as f {
        f.write(json.dumps({"files": ["jac/jaclang/cli/a.jac"]}));
    }
    assert frag_for_report(r, "auto") == "release_notes/unreleased/jaclang/0000.refactor.md";
}

test "render leaves release_note empty when no file touches jac/jaclang/" {
    d: dict = {
        "branch": "nightshift/2026-07-10/dead-code-jac-mcp", "package": "jac-mcp",
        "date": "2026-07-10", "risk": "low",
        "tests": "jac check ok; jac test ok; pre-commit ok",
        "summary": "remove dead mcp handler",
        "files": ["jac-mcp/server.jac"], "loc_before": 20, "loc_after": 0,
    };
    (meta, _body) = split_draft(render(d));
    assert meta["release_note"] == "";
}
