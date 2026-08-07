"""Merged-PR poll data (design spec section 10). bash runs `gh`; Jac owns the parsing.

Merge detection is POLLING, not a webhook: a webhook needs repo admin on jaseci-labs/jac and the
token has {admin:false, push:false, pull:true}.

argv:
  since <state.json>                 print the ISO date to poll from (last_merge_poll, else yesterday)
  count <merges.json>                print the PR count; EXIT NONZERO if the file is not a JSON array
  files <merges.json> <config.toml>  print the sorted union of changed paths that any shard covers
  prs   <merges.json>                print number<TAB>title<TAB>author<TAB>nfiles, one per PR
"""
import sys;
import json;
import from datetime { date, timedelta }
import from nslib { eprint, as_dict, as_list, state_read, load_config_toml, is_protected }
import from shards { shard_names, shard_paths }

"""Default window is ONE DAY, not "since the harness started". A missed night (07-28 to 07-30
happened) leaves last_merge_poll stale by exactly the number of nights missed, and the >= date
search then catches all of them up on the next successful run -- which is the desired behavior
and needs no separate backfill path."""
def poll_since(state_path: str) -> str {
    state: dict = state_read(state_path);
    recorded: any = state.get("last_merge_poll", "");
    if recorded is not None and str(recorded) != "" {
        return str(recorded);
    }
    return str(date.today() - timedelta(days=1));
}

"""Load and VALIDATE. An empty file is not an empty list: `gh` can exit 0 having written nothing
(killed mid-write, rate-limited, auth expired mid-call), and an empty file word-splits to zero
iterations in bash exactly like a genuinely quiet day. Raising here is what lets lib/reactive.sh
tell "no merges" apart from "failed to ask" -- the defect class this whole harness keeps hitting."""
def load_merges(path: str) -> list[dict] {
    with open(path, "r") as f {
        text: str = str(f.read());
    }
    if not text.strip() {
        raise ValueError("merges file is EMPTY: gh exited 0 but wrote nothing — "
                         + "that is 'did not ask', not 'nothing merged'");
    }
    parsed: any = json.loads(text);
    if not isinstance(parsed, list) {
        raise ValueError("merges file is not a JSON array: " + str(type(parsed)));
    }
    return [as_dict(p) for p in parsed];
}

"""The union of paths every merged PR touched -- the reactive audit scope.

Paths are RELATIVE to the repo root, exactly as `gh pr list --json files` reports them, so they can
be handed to an audit session as a scope string unchanged."""
def changed_files(prs: list[dict]) -> list[str] {
    seen: set = set();
    for pr in prs {
        for f in as_list(pr.get("files", [])) {
            path: str = str(as_dict(f).get("path", ""));
            if path {
                seen.add(path);
            }
        }
    }
    return sorted([str(p) for p in seen]);
}

"""Every path declared by any shard -- the entire universe the four audit lenses can act on."""
def audited_roots(cfg: dict) -> list[str] {
    roots: list[str] = [];
    for name in shard_names(cfg) {
        for p in shard_paths(cfg, name) {
            if p not in roots {
                roots.append(p);
            }
        }
    }
    return sorted(roots);
}

"""[protect].globs off an ALREADY-PARSED config table.

Not nslib.load_globs, which takes a path: auditable_files is handed the parsed table (its callers
and every test already have it), and re-reading the file here would create a second read that could
disagree with the first. Raises rather than defaulting to []: an empty deny-list silently readmits
every protected path into the audit scope, which is the failure this filter exists to prevent."""
def protect_globs(cfg: dict) -> list[str] {
    globs: any = as_dict(cfg["protect"])["globs"];
    if isinstance(globs, list) {
        return [str(g) for g in globs];
    }
    raise ValueError("[protect].globs missing or not a list");
}

"""Can any of the four audit lenses produce a finding about this path at all?

TWO conditions, and both were measured on the real 2026-07-31 reactive scope rather than assumed:

* IT MUST BE JAC. Every lens's prompt is about Jac source, every finding is scored in Jac lines,
  and check_scope rejects a diff that touches anything else. The 40-file window that night carried
  three .md files, two .sh scripts and (on the wider list) a .py -- including
  jac/jaclang/cli/docs/community/release_notes/jaclang.md at 753,123 bytes, which is 35% of the
  ENTIRE 2,168,503-byte read set on its own, ingested by all four lenses, and cannot yield a
  finding under any of them. 93% of the reactive pass's $28.72 was context ingestion.
* IT MUST NOT BE PROTECTED. is_protected is the same matcher the S4 gate and the selector use --
  deliberately reused rather than re-encoded, because a second protected-path matcher that drifts
  from check_scope.jac's is a branch that passes selection and is discarded after a 25-minute apply
  session. A finding inside **/tests/** is dropped by selector.drop_reason as `protected-path`
  anyway, so auditing those files can only ever buy a drop reason. That night's window held five of
  them.

Filtering both, that window loses 1,049,880 bytes and gains ten real .jac files from further down
the churn ranking: 2,168,503 -> 1,324,887 bytes for the same 40 slots."""
def is_auditable(path: str, globs: list[str]) -> bool {
    if not path.endswith(".jac") {
        return False;
    }
    return not is_protected(path, globs);
}

"""The reactive audit SCOPE: the merged-file union, restricted to the tree the lenses can audit and
RANKED, most-churned first.

Two things this is not, and both were measured before being rejected. On 2026-07-30 one real day of
jaseci-labs/jac merges was 21 PRs touching 522 files:

* The unrestricted union is not a scope. Its sorted-first 40 paths are `.github/**`, `.jacignore`,
  `README.md` and `release_notes/**` -- not one line of Jac. Four Opus sessions would be spent to
  be told there is nothing to do, which is the "scored as passed" shape from the other end: the
  pass RAN and found nothing, because it was pointed at files no lens has a rule for. Restricting
  to [shards.paths] is the honest filter rather than an arbitrary one -- those paths are exactly
  the extent the nightly shard fan-out audits, so a merged file outside them is a file Nightshift
  never audits on any night.
* Alphabetical order is not a ranking. Even after the filter, 376 files remain -- well over
  lib/reactive.sh's ceiling -- and the sorted-first 40 of THOSE are all
  `jac/jaclang/byllm/examples/**`. A truncation that always audits whatever sorts first is a
  truncation that audits the same corner every busy night forever.

So the order is churn: how many of tonight's merged PRs touched the file, then how many lines
moved, then the path (which is what keeps it deterministic and replayable). Truncating a
churn-ranked list is the "largest-signal subset" the ceiling promises.

The is_auditable filter runs BEFORE the ranking, not after: lib/reactive.sh truncates this list at
files_per_theme*4, so a file that cannot yield a finding has to be gone before it can occupy one of
those slots. Filtering the truncated head instead would shrink the window rather than refill it."""
def auditable_files(prs: list[dict], cfg: dict) -> list[str] {
    roots: list[str] = audited_roots(cfg);
    globs: list[str] = protect_globs(cfg);
    touches: dict[str, int] = {};
    churn: dict[str, int] = {};
    for pr in prs {
        seen_here: set = set();
        for f in as_list(pr.get("files", [])) {
            entry: dict = as_dict(f);
            path: str = str(entry.get("path", ""));
            if not path or not is_auditable(path, globs) {
                continue;
            }
            covered: bool = False;
            for r in roots {
                if path == r or path.startswith(r + "/") {
                    covered = True;
                    break;
                }
            }
            if not covered {
                continue;
            }
            if path not in seen_here {
                seen_here.add(path);
                touches[path] = int(touches.get(path, 0)) + 1;
            }
            moved: int = int(entry.get("additions", 0) or 0) + int(entry.get("deletions", 0) or 0);
            churn[path] = int(churn.get(path, 0)) + moved;
        }
    }
    ranked: list[str] = sorted(touches.keys());
    ranked.sort(key=lambda p: str -> tuple {
        return (-int(touches[p]), -int(churn.get(p, 0)), p);
    });
    return ranked;
}

def pr_rows(prs: list[dict]) -> list[str] {
    rows: list[str] = [];
    for pr in prs {
        author: str = str(as_dict(pr.get("author", {})).get("login", "?"));
        rows.append(str(pr.get("number", "?")) + "\t" + str(pr.get("title", "")) + "\t"
                    + author + "\t" + str(len(as_list(pr.get("files", [])))));
    }
    return rows;
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "since" and len(args) == 3 {
        print(poll_since(args[2]));
    } elif cmd == "count" and len(args) == 3 {
        print(len(load_merges(args[2])));
    } elif cmd == "files" and len(args) == 4 {
        for p in auditable_files(load_merges(args[2]), load_config_toml(args[3])) {
            print(p);
        }
    } elif cmd == "prs" and len(args) == 3 {
        for r in pr_rows(load_merges(args[2])) {
            print(r);
        }
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run merges.jac since <state.json>");
        eprint("       jac run merges.jac count|prs <merges.json>");
        eprint("       jac run merges.jac files <merges.json> <config.toml>");
        # NONZERO, for the same reason covmap.jac's and check_scope.jac's usage arms are:
        # lib/reactive.sh decides whether the reactive pass runs from `count`'s exit status, and an
        # exit 0 printing nothing would be read as "gh answered, nothing merged".
        sys.exit(2);
    }
}

test "an empty or non-array merges file is an ERROR, never an empty result" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    empty: str = d + "/empty.json";
    with open(empty, "w") as f {
        f.write("");
    }
    raised: bool = False;
    try {
        load_merges(empty);
    } except ValueError {
        raised = True;
    }
    assert raised;                                  # NOT `== []`
    notarray: str = d + "/obj.json";
    with open(notarray, "w") as f {
        f.write("{\"message\": \"Bad credentials\"}");
    }
    raised2: bool = False;
    try {
        load_merges(notarray);
    } except ValueError {
        raised2 = True;
    }
    assert raised2;
    # ...and a real quiet day parses cleanly to zero
    quiet: str = d + "/quiet.json";
    with open(quiet, "w") as f {
        f.write("[]");
    }
    assert load_merges(quiet) == [];
    assert changed_files(load_merges(quiet)) == [];
}

test "changed_files is the deduped union across PRs, sorted" {
    prs: list[dict] = [
        {"number": 1, "title": "a", "author": {"login": "x"},
         "files": [{"path": "jac/jaclang/cli/a.jac"}, {"path": "jac/jaclang/cli/b.jac"}]},
        {"number": 2, "title": "b", "author": {"login": "nightshift"},
         "files": [{"path": "jac/jaclang/cli/b.jac"}, {"path": "jac/jaclang/scale/c.jac"}]},
    ];
    assert changed_files(prs) == ["jac/jaclang/cli/a.jac", "jac/jaclang/cli/b.jac",
                                  "jac/jaclang/scale/c.jac"];
    # ALL authors, nightshift's own merged PRs included (spec section 10)
    rows: list[str] = pr_rows(prs);
    assert rows[1].startswith("2\tb\tnightshift\t2");
    assert len(rows) == 2;
}

test "auditable_files keeps only what a shard covers AND what a lens can act on" {
    # The real 2026-07-30 poll returned 522 paths whose sorted-first 40 were .github/**, README.md
    # and release_notes/** -- so an unfiltered head-of-list scope would have spent four Opus
    # sessions on files no lens has a rule for and reported "nothing found".
    cfg: dict = load_config_toml("config/nightshift.toml");
    prs: list[dict] = [{"number": 1, "title": "t", "author": {"login": "x"}, "files": [
        {"path": ".github/workflows/ci.yml"},
        {"path": "README.md"},
        {"path": "release_notes/unreleased/jaclang/7628.refactor.md"},
        {"path": "jac/jaclang/cli/cli.jac"},
        {"path": "jac/jaclang/scale/plugin.jac"},
        # ...and three shapes that DO sit under a shard root but still cannot yield a finding.
        # All three are real paths from the 2026-07-31 window.
        {"path": "jac/jaclang/cli/docs/community/release_notes/jaclang.md"},   # the 753 KB changelog
        {"path": "jac/jaclang/scale/scripts/k8s_microservice_real_e2e.sh"},
        {"path": "jac/jaclang/byllm/tests/test_byllm.jac"},                    # **/tests/**
    ]}];
    assert changed_files(prs) == [".github/workflows/ci.yml", "README.md",
                                  "jac/jaclang/byllm/tests/test_byllm.jac",
                                  "jac/jaclang/cli/cli.jac",
                                  "jac/jaclang/cli/docs/community/release_notes/jaclang.md",
                                  "jac/jaclang/scale/plugin.jac",
                                  "jac/jaclang/scale/scripts/k8s_microservice_real_e2e.sh",
                                  "release_notes/unreleased/jaclang/7628.refactor.md"];
    assert sorted(auditable_files(prs, cfg))
        == ["jac/jaclang/cli/cli.jac", "jac/jaclang/scale/plugin.jac"];
    # The two halves of is_auditable, asserted separately: an assertion on the union alone is
    # satisfied by either filter doing all the work, and the .md/.sh half is the one that removes
    # the 753 KB changelog while the glob half is the one that removes the five test files.
    globs: list[str] = protect_globs(cfg);
    assert is_auditable("jac/jaclang/cli/cli.jac", globs);
    assert not is_auditable("jac/jaclang/cli/docs/community/release_notes/jaclang.md", globs);
    assert not is_auditable("jac/jaclang/scale/scripts/e2e_lib.sh", globs);
    assert not is_auditable("jac/jaclang/jac0core/parser/__init__.py", globs);
    assert not is_auditable("jac/jaclang/byllm/tests/test_byllm.jac", globs);
    assert not is_auditable("jac/jaclang/scale/tests/data/test_s3_storage.jac", globs);
    # a config with no [protect] table is an ERROR, not "nothing is protected"
    raised: bool = False;
    try {
        protect_globs({"shards": {}});
    } except Exception {
        raised = True;
    }
    assert raised;
    # a merge day that touched nothing auditable yields an EMPTY scope, which reactive_main treats
    # as a quiet day -- correctly: there is nothing for a lens to read.
    docs_only: list[dict] = [{"number": 2, "title": "t", "author": {"login": "x"},
                              "files": [{"path": "docs/x.md"}]}];
    assert auditable_files(docs_only, cfg) == [];
    # every declared shard path is a root, none lost
    assert "jac/jaclang/cli" in audited_roots(cfg);
    assert len(audited_roots(cfg)) >= 8;
}

test "auditable_files ranks by churn, not by name, and stays deterministic" {
    # lib/reactive.sh truncates this list at a ceiling, so the ORDER decides what a busy night
    # actually audits. Alphabetical order would audit jac/jaclang/byllm/examples/** and nothing
    # else, every busy night, forever -- measured against the real 2026-07-30 merge set.
    cfg: dict = load_config_toml("config/nightshift.toml");
    prs: list[dict] = [
        {"number": 1, "files": [{"path": "jac/jaclang/scale/z.jac", "additions": 2, "deletions": 0},
                                {"path": "jac/jaclang/cli/a.jac", "additions": 1, "deletions": 0}]},
        {"number": 2, "files": [{"path": "jac/jaclang/scale/z.jac", "additions": 5, "deletions": 5}]},
        {"number": 3, "files": [{"path": "jac/jaclang/cli/b.jac", "additions": 400, "deletions": 0}]},
    ];
    ranked: list[str] = auditable_files(prs, cfg);
    # z.jac was touched by TWO PRs, so it outranks b.jac's single 400-line churn
    assert ranked[0] == "jac/jaclang/scale/z.jac";
    # within one touch, more lines moved wins
    assert ranked[1] == "jac/jaclang/cli/b.jac";
    assert ranked[2] == "jac/jaclang/cli/a.jac";
    # ...and the same input gives the same order twice: the truncation must be replayable
    assert auditable_files(prs, cfg) == ranked;
    # a file listed twice inside ONE pr counts as one touch, not two
    dup: list[dict] = [{"number": 9, "files": [
        {"path": "jac/jaclang/cli/a.jac", "additions": 1, "deletions": 0},
        {"path": "jac/jaclang/cli/a.jac", "additions": 1, "deletions": 0},
        {"path": "jac/jaclang/cli/b.jac", "additions": 9, "deletions": 0}]}];
    assert auditable_files(dup, cfg) == ["jac/jaclang/cli/b.jac", "jac/jaclang/cli/a.jac"];
}

test "poll_since falls back to yesterday and honours a recorded date" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    fresh: str = d + "/state.json";
    with open(fresh, "w") as f {
        f.write("{}");
    }
    yesterday: str = str(date.today() - timedelta(days=1));
    assert poll_since(fresh) == yesterday;
    recorded: str = d + "/state2.json";
    with open(recorded, "w") as f {
        f.write("{\"last_merge_poll\": \"2026-07-27\"}");
    }
    # a missed night must widen the window, not reset it: 07-28..07-30 all get caught up
    assert poll_since(recorded) == "2026-07-27";
    # an ABSENT state file is a fresh install, not a reason to poll from the epoch
    assert poll_since(d + "/nope.json") == yesterday;
}
