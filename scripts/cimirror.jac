"""Read config/ci-mirror.toml. bash owns process sequencing; Jac owns the data (project rule).

argv:
  jobs <ci-mirror.toml>          print each [jobs.*] table name, in file order
  cmds <job> <ci-mirror.toml>    print that job's commands, one per line
  hash <ci-mirror.toml>          print the recorded ci.yml sha256
"""
import sys;
import from nslib { eprint, load_config_toml, as_dict, as_list }

def job_names(cfg: dict) -> list[str] {
    jobs: dict = as_dict(cfg["jobs"]);
    return [str(k) for k in jobs.keys()];
}

def job_cmds(cfg: dict, job: str) -> list[str] {
    jobs: dict = as_dict(cfg["jobs"]);
    job_tbl: dict = as_dict(jobs[job]);
    return [str(c) for c in as_list(job_tbl["commands"])];
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "jobs" and len(args) == 3 {
        for n in job_names(load_config_toml(args[2])) {
            print(n);
        }
    } elif cmd == "cmds" and len(args) == 4 {
        for c in job_cmds(load_config_toml(args[3]), args[2]) {
            print(c);
        }
    } elif cmd == "hash" and len(args) == 3 {
        print(str(load_config_toml(args[2])["source"]["sha256"]));
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run cimirror.jac jobs|hash <ci-mirror.toml>");
        eprint("       jac run cimirror.jac cmds <job> <ci-mirror.toml>");
    }
}

test "declared jobs match the config exactly, each with at least one command" {
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    names: list[str] = job_names(cfg);
    expected: list[str] = ["fmt", "jir", "byllm", "compiler", "runtime", "contribution"];
    assert sorted(names) == sorted(expected);
    for n in names {
        assert len(job_cmds(cfg, n)) >= 1;
    }
}

test "the fmt command is CI's exact invocation, not jac format" {
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    fmt: str = job_cmds(cfg, "fmt")[0];
    assert "jac fmt --check --lintfix" in fmt;
    assert "/fixtures/" in fmt and "_syntax_err" in fmt;
    assert "jac format" not in fmt;
    assert "jac lint --fix" not in fmt;
}
