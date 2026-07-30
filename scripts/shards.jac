"""Shard registry for the whole-repo audit (design spec section 5).

The audit cannot read 365k LOC in one session, so the repo is split into
LOC-balanced shards that are audited concurrently and merged into one selection.

argv:
  list  <config.toml>          print one shard name per line, in config order
  scope <name> <config.toml>   print the prompt-ready scope string for one shard
"""
import sys;
import from nslib { eprint, load_config_toml, as_dict, as_list }

def shard_names(cfg: dict) -> list[str] {
    shards: dict = as_dict(cfg["shards"]);
    return [str(n) for n in as_list(shards["names"])];
}

"""One shard's declared paths. Extracted so covmap.jac and the audit prompt cannot disagree about
a shard's extent -- the evidence a coverage audit is handed must cover exactly the tree it is being
asked to audit, or it reads as "nothing untested here" for files nobody looked at."""
def shard_paths(cfg: dict, name: str) -> list[str] {
    shards: dict = as_dict(cfg["shards"]);
    paths_table: dict = as_dict(shards["paths"]);
    return [str(p) for p in as_list(paths_table[name])];
}

def shard_scope(cfg: dict, name: str) -> str {
    shards: dict = as_dict(cfg["shards"]);
    paths: list[str] = shard_paths(cfg, name);
    excl_table: dict = as_dict(shards.get("exclude", {}));
    excl: list[str] = [str(p) for p in as_list(excl_table.get(name, []))];
    scope: str = ", ".join(paths);
    if excl {
        scope = scope + " (excluding " + ", ".join(excl) + ")";
    }
    return scope;
}

# `entry:__main__`, not a bare `entry`: scripts/covmap.jac now imports shard_paths from here, and a
# bare entry block runs on IMPORT too -- so every `covmap rank|top` invocation printed this file's
# usage text to stderr while parsing covmap's own argv. Harmless today; not harmless the day this
# arm gains a sys.exit(2), which tasks.jac's and check_scope.jac's already have.
with entry:__main__ {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "list" and len(args) == 3 {
        for n in shard_names(load_config_toml(args[2])) {
            print(n);
        }
    } elif cmd == "scope" and len(args) == 4 {
        print(shard_scope(load_config_toml(args[3]), args[2]));
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run shards.jac list <config.toml>");
        eprint("       jac run shards.jac scope <name> <config.toml>");
    }
}

test "every declared shard name has paths, and none is empty" {
    cfg: dict = load_config_toml("config/nightshift.toml");
    names: list[str] = shard_names(cfg);
    assert len(names) == 8;
    paths_table: dict = as_dict(as_dict(cfg["shards"])["paths"]);
    for n in names {
        assert n in paths_table;
        assert len(as_list(paths_table[n])) >= 1;
    }
}

test "shard_paths returns the declared paths, and an undeclared shard raises" {
    # covmap.jac filters its evidence with this; a shard_paths that quietly returned [] for an
    # unknown name would hand the coverage audit an EMPTY evidence block, which reads to the model
    # exactly like "everything in this shard is tested".
    cfg: dict = load_config_toml("config/nightshift.toml");
    assert shard_paths(cfg, "scale") == ["jac/jaclang/scale"];
    assert len(shard_paths(cfg, "periphery")) == 5;
    raised: bool = False;
    try {
        shard_paths(cfg, "not-a-shard");
    } except KeyError {
        raised = True;
    }
    assert raised;
}

test "scope renders paths and appends exclusions only when present" {
    cfg: dict = load_config_toml("config/nightshift.toml");
    assert shard_scope(cfg, "scale") == "jac/jaclang/scale";
    core: str = shard_scope(cfg, "compiler-core");
    assert core.startswith("jac/jaclang/compiler (excluding ");
    assert "jac/jaclang/compiler/passes" in core;
    assert "jac/jaclang/compiler/tests" in core;
    assert ", " in shard_scope(cfg, "periphery");
}

test "shards do not overlap once exclusions are applied" {
    cfg: dict = load_config_toml("config/nightshift.toml");
    # compiler-core must exclude compiler-passes or the two shards audit the same files twice.
    # The expected value is DERIVED from compiler-passes' own [shards.paths] entry, never retyped:
    # with the literal hardcoded, renaming that shard's path (say to .../passes2) left this test
    # green while the two shards silently started overlapping again -- the exact drift it exists
    # to catch.
    paths_table: dict = as_dict(as_dict(cfg["shards"])["paths"]);
    passes: list[str] = [str(p) for p in as_list(paths_table["compiler-passes"])];
    excl_table: dict = as_dict(as_dict(cfg["shards"])["exclude"]);
    excluded: list[str] = [str(p) for p in as_list(excl_table["compiler-core"])];
    for p in passes {
        assert p in excluded;
    }
}
