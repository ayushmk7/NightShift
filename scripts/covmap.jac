"""Coverage evidence, Phase A (design spec 11).

Enumerate the repo's public archetypes with `jac code map`, subtract every identifier that appears
anywhere under a test tree, and rank what is left. The coverage audit prompt consumes this as
EVIDENCE. It is a proxy for coverage, not line coverage.

ponytail: NAME-BASED resolution, deliberately. A symbol whose name merely appears in a test's
string literal or comment counts as referenced (a false "tested"), and two same-named symbols in
different modules share one verdict. That is the right trade at ~3s for the whole repo, and the
audit is told to verify before reporting. Upgrade path: `jac code uses <symbol>` is def/use-precise
and perfectly affordable once this list has narrowed the candidates to a few dozen.

Known ceiling, stated because the obvious reading is wrong: `jac code map` reports ARCHETYPES
(obj/class/node/edge/walker) and their abilities. A module-level `def` with no tests is invisible
here. Upgrade path: the same subtraction over `jac code symbol` output per file.

Phase B -- real line coverage as a compiler pass -- is explicitly NOT this and has its own spec.

argv:
  rank <repo_dir> <jac_repo_bin>                    print the ranked untested-symbol JSON array
  top  <covmap.json> <shard> <config.toml> <limit>  markdown evidence lines for one shard
"""
import sys;
import os;
import re;
import json;
import subprocess;
import from nslib { eprint, parse_obj, as_dict, as_list, load_config_toml }
import from shards { shard_paths }

glob SKIP_MARKERS: list[str] = ["/tests/", "/fixtures/", "/examples/"];

"""Every identifier appearing anywhere under a test tree. One pass over the test corpus, not one
subprocess per symbol: `jac code uses` per candidate would be ~1600 compiler invocations."""
def test_identifiers(repo_dir: str) -> set[str] {
    ids: set[str] = set();
    # `walk_dir`, NOT `root`: `root` is Jac's graph-root builtin, and binding it here makes the
    # checker type the loop variable as `Root` -- E1030 "Type Root has no attribute endswith",
    # confirmed by running it. Every element is re-narrowed with str() for the same reason.
    for (walk_dir, walk_subdirs, walk_files) in os.walk(repo_dir + "/jac") {
        dir_path: str = str(walk_dir);
        if "/tests" not in dir_path and not dir_path.endswith("/tests") {
            continue;
        }
        for name in walk_files {
            file_name: str = str(name);
            if not file_name.endswith(".jac") {
                continue;
            }
            try {
                with open(os.path.join(dir_path, file_name), "r") as f {
                    text: str = str(f.read());
                }
                for tok in re.findall("[A-Za-z_][A-Za-z0-9_]*", text) {
                    ids.add(str(tok));
                }
            } except Exception {
                continue;                  # an unreadable test file must not kill the night
            }
        }
    }
    return ids;
}

def ability_name(sig: str) -> str {
    return str(sig).split("(")[0].strip();
}

"""Public archetypes under jac/jaclang whose name appears nowhere in the test corpus, ranked by a
size proxy (fields + abilities): the more surface a type has, the more behaviour is unprotected.
`weight` orders the EVIDENCE; the audit assigns each finding its own gap_severity in LOC."""
def rank(repo_dir: str, jac_bin: str) -> list[dict] {
    # check=True on purpose. A failed `jac code map` must NOT come back as an empty evidence list
    # that reads exactly like "everything is tested" -- that is the did-not-run-scored-as-passed
    # shape this project keeps finding.
    proc = subprocess.run([jac_bin, "code", "map"], cwd=repo_dir + "/jac",
                          capture_output=True, text=True, check=True);
    data: dict = parse_obj(proc.stdout);
    tested: set[str] = test_identifiers(repo_dir);
    prefix: str = repo_dir + "/";
    out: list[dict] = [];
    for a in as_list(data["archetypes"]) {
        arch: dict = as_dict(a);
        name: str = str(arch["name"]);
        path: str = str(arch["file"]);
        rel: str = path[len(prefix):] if path.startswith(prefix) else path;
        if not rel.startswith("jac/jaclang/") or name.startswith("_") {
            continue;
        }
        # `skip` would be a Jac keyword (the walker control statement), which the parser rejects
        # here as a missing ';'. Confirmed by running it.
        in_skip_tree: bool = False;
        for marker in SKIP_MARKERS {
            if marker in rel {
                in_skip_tree = True;
            }
        }
        if in_skip_tree or name in tested {
            continue;
        }
        members: list[str] = [str(x) for x in as_list(arch.get("fields", []))]
                             + [ability_name(str(x)) for x in as_list(arch.get("abilities", []))];
        out.append({"symbol": name, "kind": str(arch["kind"]), "file": rel,
                    "line": int(arch.get("line", 0)), "weight": len(members)});
    }
    out.sort(key=lambda d: dict -> tuple { return (-int(d["weight"]), str(d["symbol"])); });
    return out;
}

def top_lines(entries: list[dict], paths: list[str], limit: int) -> list[str] {
    out: list[str] = [];
    for e in entries {
        for p in paths {
            if str(e["file"]).startswith(p) and len(out) < limit {
                out.append("- `" + str(e["symbol"]) + "` (" + str(e["kind"]) + ", "
                           + str(e["file"]) + ":" + str(e["line"]) + ") - "
                           + str(e["weight"]) + " members, no test-tree reference");
                break;
            }
        }
    }
    return out;
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "rank" and len(args) == 4 {
        print(json.dumps(rank(args[2], args[3])));
    } elif cmd == "top" and len(args) == 6 {
        with open(args[2], "r") as f {
            entries: list[dict] = [as_dict(e) for e in json.loads(f.read())];
        }
        paths: list[str] = shard_paths(load_config_toml(args[4]), args[3]);
        lines: list[str] = top_lines(entries, paths, int(args[5]));
        if not lines {
            print("(no untested public archetypes resolved in this shard)");
        }
        for line in lines {
            print(line);
        }
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run covmap.jac rank <repo_dir> <jac_repo_bin>");
        eprint("       jac run covmap.jac top <covmap.json> <shard> <config.toml> <limit>");
        # NONZERO for the same reason check_scope.jac's usage arm is: lib/tier2.sh decides whether
        # tonight's coverage audit runs at all from this command's exit status, and an exit 0 with
        # no output would be recorded as "evidence gathered, nothing untested".
        sys.exit(2);
    }
}

test "test_identifiers reads only the test tree" {
    import tempfile;
    import os as _os;
    repo: str = tempfile.mkdtemp();
    _os.makedirs(repo + "/jac/jaclang/cli");
    _os.makedirs(repo + "/jac/tests/cli");
    with open(repo + "/jac/jaclang/cli/pipe.jac", "w") as f {
        f.write("obj OnlyInSource {}\n");
    }
    with open(repo + "/jac/tests/cli/test_pipe.jac", "w") as f {
        f.write("import from jaclang.cli.pipe { Referenced }\ntest \"x\" { assert Referenced; }\n");
    }
    ids: set[str] = test_identifiers(repo);
    assert "Referenced" in ids;
    assert "OnlyInSource" not in ids;
}

test "top_lines filters to the shard's paths and honours the limit" {
    entries: list[dict] = [
        {"symbol": "A", "kind": "obj", "file": "jac/jaclang/cli/a.jac", "line": 3, "weight": 9},
        {"symbol": "B", "kind": "walker", "file": "jac/jaclang/scale/b.jac", "line": 5, "weight": 8},
        {"symbol": "C", "kind": "obj", "file": "jac/jaclang/cli/c.jac", "line": 7, "weight": 7},
    ];
    lines: list[str] = top_lines(entries, ["jac/jaclang/cli"], 5);
    assert len(lines) == 2;
    assert "`A`" in lines[0] and "jac/jaclang/cli/a.jac:3" in lines[0];
    assert len(top_lines(entries, ["jac/jaclang/cli"], 1)) == 1;
    assert top_lines(entries, ["jac/jaclang/byllm"], 5) == [];
}

test "ability_name strips the signature, and a fieldless archetype weighs 0" {
    # `weight` is what ORDERS the evidence the coverage audit reads, so the two halves of it are
    # pinned here rather than only through `rank`, which needs the repo binary to run at all.
    assert ability_name("from_row()") == "from_row";
    assert ability_name("apply(self: Board, m: Move) -> None") == "apply";
    assert ability_name("  spaced ( x )") == "spaced";
}
