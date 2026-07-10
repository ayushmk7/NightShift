# Step 12 — S5 Ship: push, draft, ledger

## Goal

`scripts/render_draft.jac` (render the PR-draft `.md` with machine-readable
JSON-literal frontmatter + human-ready body; parse it back at promote time; plus
`git-report` for the agent-less autofix branch) and `lib/ship.sh` (push each green
branch to the fork with an explicit refspec, write its draft onto the
`nightshift/drafts` worktree, flip ledger rows to `drafted`, publish drafts +
ledger to the fork). Implements TechnicalPRD §7-S5 and the §8.3 draft schema.

## Prerequisites

Steps 5 (drafts worktree), 7 (green.tsv + tests lines), 11 (reports).

## Files created

```
~/nightshift/scripts/render_draft.jac
~/nightshift/lib/ship.sh
```

## The draft contract (PRD §8)

```markdown
---
branch: "nightshift/2026-07-10/dead-code-jac-client"
package: "jac-client"
date: "2026-07-10"
title: "refactor(jac-client): remove dead render-path duplication"
risk: "low"
tests: "jac check ✓ · pytest jac -n auto ✓ · pre-commit ✓ (14 min)"
release_note: "docs/docs/community/release_notes/unreleased/jac-client/0000.refactor.md"
files: 6
loc: {"before": 512, "after": 143}
---

# refactor(jac-client): remove dead render-path duplication
<what/why · changes · deferred · verification · reviewer checklist>
```

Every frontmatter value is a **JSON literal**, so `render_draft meta` parses the
whole block with `json.loads` per line — no YAML dependency, and `promote` (step
13) gets typed values for free. The body below the second `---` is the verbatim
`gh pr create --body-file` payload.

## Full implementation

### `scripts/render_draft.jac`

```jac
"""PR-draft .md files (PRD 8, TechnicalPRD 8.3): render at ship time, read back at promote time.

argv:
  render <report.json> [k=v ...]   report from parse_result.jac plus string overrides
                                   (branch=, package=, date=, tests=, url=) so bash never
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
    lines.append("loc: " + json.dumps({"before": as_int(d["loc_before"]), "after": as_int(d["loc_after"])}));
    lines.append("---");
    return lines;
}

def body_lines(d: dict) -> list[str] {
    loc_delta: int = as_int(d["loc_before"]) - as_int(d["loc_after"]);
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
    lines.append("Net: **-" + str(loc_delta) + " LOC** (" + str(d["loc_before"]) + " → " + str(d["loc_after"]) + ").");
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

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "git-report" and len(args) == 4 {
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
        eprint("       jac run render_draft.jac git-report <repo_dir> <summary>");
        eprint("       jac run render_draft.jac meta <draft.md>");
        eprint("       jac run render_draft.jac body <draft.md>");
    }
}

test "render then split roundtrips the frontmatter" {
    d: dict = {
        "branch": "nightshift/2026-07-10/dead-code-jac-client", "package": "jac-client",
        "date": "2026-07-10", "risk": "low",
        "tests": "jac check ok; pytest ok; pre-commit ok",
        "summary": "remove dead render-path duplication",
        "files": ["jac-client/render/pipe.jac"], "loc_before": 512, "loc_after": 143,
        "skipped": [{"file": "jac-client/render/pipe.jac", "reason": "ponytail: kept boundary check"}],
    };
    text: str = render(d);
    (meta, body) = split_draft(text);
    assert meta["branch"] == d["branch"];
    assert meta["loc"]["before"] == 512;
    assert meta["files"] == 1;
    assert meta["release_note"] == "docs/docs/community/release_notes/unreleased/jac-client/0000.refactor.md";
    assert body.startswith("# refactor(jac-client):");
    assert "-369 LOC" in body;
    assert "Consciously deferred" in body;
}
```

### `lib/ship.sh`

```bash
# shellcheck shell=bash
# lib/ship.sh — S5 (TechnicalPRD 7-S5): push green branches, render drafts, update the ledger.

ship_main() {
    [ -f "$LOG_DIR/green.tsv" ] || { ns_log S5 "nothing green to ship"; return 0; }
    local branch theme report
    while IFS=$'\t' read -r branch theme report; do
        ship_branch "$branch" "$theme" "$report"
    done < "$LOG_DIR/green.tsv"

    # publish drafts + ledger to the fork's orphan branch
    cp "$LEDGER" "$DRAFTS/ledger.jsonl"
    git -C "$DRAFTS" add -A
    if ! git -C "$DRAFTS" diff --cached --quiet; then
        git -C "$DRAFTS" commit -m "drafts: $NS_DATE"
        ns_git_push "$DRAFTS" origin nightshift/drafts
    fi
}

ship_branch() {
    local branch=$1 theme=$2 report=$3
    local slug pkg tests_line draft_path

    slug="$(basename "$branch")"
    if [ "$theme" != "-" ]; then
        pkg="$(ns_jac parse_result field package < "$theme")"
    else
        pkg="repo"          # tier-1 autofix touches whichever packages drifted
    fi
    tests_line="$(cat "$LOG_DIR/tests-$slug.txt" 2>/dev/null || echo "gates green (see logs)")"

    # explicit refspec, only nightshift/* refs, never force (threat T3)
    ns_git_push "$REPO" -u origin "refs/heads/$branch:refs/heads/$branch"

    draft_path="$DRAFTS/drafts/$NS_DATE--$slug.md"
    ns_jac render_draft render "$report" \
        "branch=$branch" "package=$pkg" "date=$NS_DATE" "tests=$tests_line" \
        > "$draft_path"

    # findings on this branch: drafted (autofix has no ledger rows — that's fine)
    local fp
    ns_jac ledger by-branch "$branch" "$LEDGER" | while IFS= read -r fp; do
        ns_jac ledger set-status "$fp" drafted "$LEDGER" >/dev/null
    done
    ns_log S5 "shipped $branch + draft $(basename "$draft_path")"
}
```

## Commands

```bash
cd ~/nightshift
jac check scripts/render_draft.jac && jac test scripts/render_draft.jac
bash -n lib/ship.sh
```

## Acceptance criteria

- [ ] `jac test scripts/render_draft.jac` → roundtrip test green (render →
      `split_draft` → identical frontmatter, correct LOC delta, checklist present).
- [ ] `render → meta → body` CLI cycle:
      ```bash
      printf '{"summary":"kill dead code","files":["a.jac"],"loc_before":100,"loc_after":40,"risk":"low","release_note_md":"x","skipped":[],"suspected_bugs":[]}' > /tmp/rep.json
      jac run scripts/render_draft.jac render /tmp/rep.json branch=nightshift/x package=jac date=2026-07-10 tests=green > /tmp/d.md
      jac run scripts/render_draft.jac meta /tmp/d.md      # JSON with files:1, loc:{...}
      jac run scripts/render_draft.jac body /tmp/d.md      # starts with "# refactor(jac):"
      ```
- [ ] `git-report` on a branch with committed changes returns the changed files and
      plausible add/remove counts.
- [ ] After a real `ship_main`: branch visible on the fork; draft committed on
      `nightshift/drafts` as `drafts/<date>--<slug>.md`; `ledger.jsonl` on that
      branch matches the local cache; rows for the branch say `drafted`.
- [ ] `NS_DRY_RUN=1 ship_main` logs `DRY: git -C … push …` lines and pushes nothing.

## Verification procedure

With step 11's queued branch verified green (step 7), run:

```bash
cd ~/nightshift
export NS_ROOT="$PWD"; . lib/common.sh; ns_load_config; . lib/ship.sh
NS_DRY_RUN=1 ship_main            # rehearsal: read every DRY line
ship_main                         # the real push
gh api "repos/$NS_REPO_FORK/branches" -q '.[].name' | grep nightshift
git -C work/drafts log --oneline -3
```

Open the draft file on GitHub (fork → `nightshift/drafts` branch) — this is the
exact morning-review surface; check it reads well on a phone.

## Notes & traps

- Pushes use the explicit refspec `refs/heads/<branch>:refs/heads/<branch>` and the
  clone has `push.default nothing` (step 1) — the two together make an accidental
  `git push` of `main` structurally impossible (threat T3).
- The autofix branch reaches S5 with `theme = "-"`: no ledger rows to flip (fine),
  package labeled `repo`, and its report synthesized by `git-report` in step 6.
- The drafts commit is one commit per night (`drafts: <date>`), not per branch —
  the orphan branch's history stays a readable nightly journal.
- `render` fills `title` and `release_note` defaults when absent, so callers only
  override what they know better.
- LOC semantics differ by producer and that's okay: agent reports count file LOC
  before/after; `git-report` counts diff lines removed/added. Both render as
  "Net: −N LOC" and the digest sums deltas — directionally right is all the
  morning summary needs (a `ponytail:`-grade simplification, documented here).
