"""Read config/nightshift.toml and expose it to bash: flat env lines, JSON, or one dotted key."""
import sys;
import os;
import json;
import tomllib;
import from shlex { quote }

def eprint(msg: str) {
    err: any = sys.stderr;
    err.write(msg + "\n");
}

def load_config(path: str) -> dict {
    with open(path, "rb") as f {
        parsed: any = tomllib.load(f);
        if isinstance(parsed, dict) {
            return parsed;
        }
    }
    raise ValueError("not a TOML table: " + path);
}

def get_key(cfg: dict, dotted: str) -> any {
    cur: any = cfg;
    for part in dotted.split(".") {
        cur = cur[part];
    }
    return cur;
}

def env_value(value: any) -> str {
    if isinstance(value, list) or isinstance(value, dict) {
        return json.dumps(value);
    }
    return str(value);
}

def as_env_lines(cfg: dict) -> list[str] {
    lines: list[str] = [];
    for (section, table) in cfg.items() {
        if isinstance(table, dict) {
            for (key, value) in table.items() {
                name: str = ("NS_" + str(section) + "_" + str(key)).upper().replace("-", "_");
                lines.append(name + "=" + quote(env_value(value)));
            }
        }
    }
    return lines;
}

def config_path(args: list[str], idx: int) -> str {
    if len(args) > idx {
        return args[idx];
    }
    from_env: str | None = os.environ.get("NS_CONFIG");
    if from_env is not None {
        return from_env;
    }
    return "config/nightshift.toml";
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "env" {
        for line in as_env_lines(load_config(config_path(args, 2))) {
            print(line);
        }
    } elif cmd == "json" {
        print(json.dumps(load_config(config_path(args, 2))));
    } elif cmd == "get" and len(args) > 2 {
        print(env_value(get_key(load_config(config_path(args, 3)), args[2])));
    } else {
        eprint("usage: jac run config.jac env|json|get <dotted.key> [config.toml]");
    }
}

test "env lines flatten sections and quote values" {
    import tempfile;
    body: str = "[repo]\nfork = \"me/jaseci\"\n[budgets]\nmax_turns = 80\n[protect]\nglobs = [\"docs/**\"]\n";
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        tf.write(body);
        path: str = tf.name;
    }
    lines: list[str] = as_env_lines(load_config(path));
    assert "NS_REPO_FORK=me/jaseci" in lines;
    assert "NS_BUDGETS_MAX_TURNS=80" in lines;
    assert get_key(load_config(path), "budgets.max_turns") == 80;
}
