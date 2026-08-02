"""Task registry and the four-night cycle (design spec 3, 13).

The cycle order is the order the [tasks.*] tables appear in config/nightshift.toml. There is no
`order` key on purpose -- see the config comment.

argv:
  list <config.toml>                 print one task name per line, in cycle order
  env  <task> <config.toml>          print NS_TASK_* shell assignments for one task
  next <config.toml> <state.json>    print TONIGHT's task and advance the cycle index
"""
import sys;
import from shlex { quote }
import from nslib { eprint, load_config_toml, as_dict, state_read, state_write }

"""Only sub-TABLES count as tasks, so a stray scalar under [tasks] cannot become a phantom task
whose prompt files do not exist."""
def task_names(cfg: dict) -> list[str] {
    tasks: dict = as_dict(cfg["tasks"]);
    return [str(k) for (k, v) in tasks.items() if isinstance(v, dict)];
}

def task_table(cfg: dict, task: str) -> dict {
    tasks: dict = as_dict(cfg["tasks"]);
    if task not in tasks {
        raise ValueError("unknown task: " + task);
    }
    return as_dict(tasks[task]);
}

"""Shell assignments for one task. protect_unless is NOT here and must never be.

Note what that does and does not buy, because the tempting stronger claim is false:
scripts/config.jac already flattens [tasks.coverage] wholesale into a single JSON-valued
NS_TASKS_COVERAGE assignment, protect_unless included, so the value DOES reach a shell variable
on every run. What keeps it away from the agent is that lib/common.sh's ns_load_config evals
those lines bare -- no export, no `set -a` -- so nothing is inherited by a child process. This
function refusing to emit it closes the second route: an NS_TASK_* line is the one the apply
path passes around per theme, and a write permission that travels with the theme can be
overridden on a command line or logged next to it."""
def task_env(cfg: dict, task: str) -> list[str] {
    t: dict = task_table(cfg, task);
    lines: list[str] = ["NS_TASK_NAME=" + quote(task)];
    for key in ["ponytail", "scoring", "fragment"] {
        if key not in t {
            raise ValueError("[tasks." + task + "] is missing `" + key + "`");
        }
        lines.append("NS_TASK_" + key.upper() + "=" + quote(str(t[key])));
    }
    return lines;
}

"""Tonight's task, advancing the cycle as it reads. Advancing ON READ is deliberate: a night that
dies after S3 must not make every following night repeat the same task forever. Unfinished work
already survives on its own through carry-over (selector.jac), so the cycle is a CLOCK, not a work
queue."""
def next_task(cfg: dict, state_path: str) -> str {
    names: list[str] = task_names(cfg);
    if not names {
        raise ValueError("no [tasks.*] tables in the config");
    }
    st: dict = state_read(state_path);
    idx: int = int(st.get("cycle_index", 0)) % len(names);
    st["cycle_index"] = (idx + 1) % len(names);
    state_write(state_path, st);
    return names[idx];
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "list" and len(args) == 3 {
        for n in task_names(load_config_toml(args[2])) {
            print(n);
        }
    } elif cmd == "env" and len(args) == 4 {
        for line in task_env(load_config_toml(args[3]), args[2]) {
            print(line);
        }
    } elif cmd == "next" and len(args) == 4 {
        print(next_task(load_config_toml(args[2]), args[3]));
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run tasks.jac list <config.toml>");
        eprint("       jac run tasks.jac env <task> <config.toml>");
        eprint("       jac run tasks.jac next <config.toml> <state.json>");
        sys.exit(2);
    }
}

test "the four tasks are declared in the designed cycle order" {
    # The order IS the design (delete -> simplify -> fix drift -> test the settled shape), so it is
    # asserted literally rather than derived from the file it is meant to pin.
    assert task_names(load_config_toml("config/nightshift.toml"))
        == ["dead-code", "abstraction", "maintenance", "coverage"];
}

test "next advances the cycle and wraps, and a dead night does not stall it" {
    import tempfile;
    cfg: dict = load_config_toml("config/nightshift.toml");
    d: str = tempfile.mkdtemp();
    st: str = d + "/state.json";
    seen: list[str] = [];
    for _ in range(6) {
        seen.append(next_task(cfg, st));
    }
    assert seen == ["dead-code", "abstraction", "maintenance", "coverage",
                    "dead-code", "abstraction"];
    assert int(state_read(st)["cycle_index"]) == 2;
}

test "next preserves the rest of state.json rather than rewriting the file" {
    # cycle_index lands in the SAME state.json that carries verify_estimate_min and
    # last_merge_poll. A next_task that wrote {"cycle_index": n} would silently collapse the
    # merge window (RECONCILIATION B9 documents that exact failure from the other direction).
    import tempfile;
    import json;
    cfg: dict = load_config_toml("config/nightshift.toml");
    d: str = tempfile.mkdtemp();
    st: str = d + "/state.json";
    with open(st, "w") as f {
        f.write(json.dumps({"verify_estimate_min": 7, "last_merge_poll": "2026-07-29"}));
    }
    next_task(cfg, st);
    after: dict = state_read(st);
    assert int(after["verify_estimate_min"]) == 7;
    assert str(after["last_merge_poll"]) == "2026-07-29";
    assert int(after["cycle_index"]) == 1;
}

test "env exposes exactly the per-task knobs, and never protect_unless" {
    cfg: dict = load_config_toml("config/nightshift.toml");
    cov: list[str] = task_env(cfg, "coverage");
    assert "NS_TASK_NAME=coverage" in cov;
    assert "NS_TASK_PONYTAIL=lite" in cov;
    assert "NS_TASK_SCORING=risk_weighted" in cov;
    assert len(cov) == 4;
    for line in cov {
        assert "protect_unless" not in line.lower();
        assert "PROTECT" not in line;
        # The glob itself, not just the key name: emitting the list under any other label would
        # still hand the permission to whatever reads these lines.
        assert "tests" not in line;
    }
    dead: list[str] = task_env(cfg, "dead-code");
    assert "NS_TASK_SCORING=loc_saved" in dead;
    assert "NS_TASK_FRAGMENT=refactor" in dead;
}

test "an unknown task raises rather than returning empty settings" {
    cfg: dict = load_config_toml("config/nightshift.toml");
    raised: bool = False;
    try {
        task_env(cfg, "not-a-task");
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "a task table missing a knob raises rather than shipping a partial env" {
    # A [tasks.x] with no `scoring` would otherwise yield three NS_TASK_* lines, and the caller
    # would run the night with whatever the previous eval left in NS_TASK_SCORING.
    partial: dict = {"tasks": {"halfdone": {"ponytail": "full", "fragment": "refactor"}}};
    raised: bool = False;
    try {
        task_env(partial, "halfdone");
    } except ValueError {
        raised = True;
    }
    assert raised;
}
