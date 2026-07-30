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

def shard_scope(cfg: dict, name: str) -> str {
    shards: dict = as_dict(cfg["shards"]);
    paths_table: dict = as_dict(shards["paths"]);
    paths: list[str] = [str(p) for p in as_list(paths_table[name])];
    excl_table: dict = as_dict(shards.get("exclude", {}));
    excl: list[str] = [str(p) for p in as_list(excl_table.get(name, []))];
    scope: str = ", ".join(paths);
    if excl {
        scope = scope + " (excluding " + ", ".join(excl) + ")";
    }
    return scope;
}

with entry {
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
