"""Read config/nightshift.toml and expose it to bash as flat NS_* env lines."""
import sys;
import os;
import json;
import from shlex { quote }
import from nslib { eprint, load_config_toml }

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
        for line in as_env_lines(load_config_toml(config_path(args, 2))) {
            print(line);
        }
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run config.jac env [config.toml]");
    }
}

test "env lines flatten sections and quote values" {
    import tempfile;
    body: str = "[repo]\nfork = \"me/jaseci\"\n[budgets]\nmax_turns = 80\n[protect]\nglobs = [\"docs/**\"]\n";
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        tf.write(body);
        path: str = tf.name;
    }
    lines: list[str] = as_env_lines(load_config_toml(path));
    assert "NS_REPO_FORK=me/jaseci" in lines;
    assert "NS_BUDGETS_MAX_TURNS=80" in lines;
}
