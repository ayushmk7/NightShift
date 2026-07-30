"""Read config/ci-mirror.toml. bash owns process sequencing; Jac owns the data (project rule).

argv:
  jobs <ci-mirror.toml>          print each GATE job name (mirrors a real ci.yml job), file order
  cmds <job> <ci-mirror.toml>    print that job's commands, one per line
  hash <ci-mirror.toml>          print the recorded ci.yml sha256
"""
import sys;
import from nslib { eprint, load_config_toml, as_dict, as_list }

"""Every [jobs.*] table name, unfiltered -- includes tier-1's own [jobs.fmt_autofix], which is
NOT a ci.yml job and must never appear in the gate iteration (see gate_job_names)."""
def job_names(cfg: dict) -> list[str] {
    jobs: dict = as_dict(cfg["jobs"]);
    return [str(k) for k in jobs.keys()];
}

def job_cmds(cfg: dict, job: str) -> list[str] {
    jobs: dict = as_dict(cfg["jobs"]);
    job_tbl: dict = as_dict(jobs[job]);
    return [str(c) for c in as_list(job_tbl["commands"])];
}

def job_ci_job(cfg: dict, job: str) -> str {
    jobs: dict = as_dict(cfg["jobs"]);
    job_tbl: dict = as_dict(jobs[job]);
    return str(job_tbl["ci_job"]);
}

"""The job names cimirror_all / `nightshift.sh mirror` (Task 7) should actually iterate as a
gate: every entry whose `ci_job` names a real ci.yml job. A `ci_job` starting with "none" marks a
LOCAL-ONLY step (currently just fmt_autofix, tier-1's own apply command) that must be reachable by
name via `cmds <job>` but must NEVER run inside a read-only verification pass -- fmt_autofix's
command is `jac fmt --lintfix` with no --check, i.e. it MUTATES files; running it as part of a
gate would silently rewrite a candidate branch's content while deciding whether to ship it."""
def gate_job_names(cfg: dict) -> list[str] {
    return [n for n in job_names(cfg) if not job_ci_job(cfg, n).startswith("none")];
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "jobs" and len(args) == 3 {
        for n in gate_job_names(load_config_toml(args[2])) {
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

test "every declared job (gate jobs and tier-1's local-only step alike) has at least one command" {
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    names: list[str] = job_names(cfg);
    expected: list[str] = ["fmt", "fmt_autofix", "jir", "byllm", "compiler", "runtime", "contribution"];
    assert sorted(names) == sorted(expected);
    for n in names {
        assert len(job_cmds(cfg, n)) >= 1;
    }
}

test "the gate job list mirrors only real ci.yml jobs, excluding tier-1's own autofix step" {
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    gate: list[str] = gate_job_names(cfg);
    expected_gate: list[str] = ["fmt", "jir", "byllm", "compiler", "runtime", "contribution"];
    assert sorted(gate) == sorted(expected_gate);
    assert "fmt_autofix" not in gate;
    # every gate job's ci_job must NOT look like a local-only marker
    for n in gate {
        assert not job_ci_job(cfg, n).startswith("none");
    }
    assert job_ci_job(cfg, "fmt_autofix").startswith("none");
}

test "the fmt command is CI's exact PR-scoped invocation, not jac format" {
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    fmt: str = job_cmds(cfg, "fmt")[0];
    assert "jac fmt --check --lintfix" in fmt;
    assert "/fixtures/" in fmt and "_err" in fmt;
    assert "jac format" not in fmt;
    assert "jac lint --fix" not in fmt;
}

test "fmt (check) and fmt_autofix (apply) share one exclusion regex, differing only in scope" {
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    fmt: str = job_cmds(cfg, "fmt")[0];
    autofix: str = job_cmds(cfg, "fmt_autofix")[0];
    regex: str = "(/fixtures/|^scripts/|/passes/native/llvm/|_err\\.jac$)";
    assert regex in fmt;
    assert regex in autofix;
    assert "--check" in fmt;
    assert "--check" not in autofix;
    assert "jac/jaclang/byllm" in autofix;
    assert "jac/jaclang/byllm" not in fmt;
}
