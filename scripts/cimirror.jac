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

"""How many of a job's commands actually INVOKE THE TEST RUNNER.

lib/verify.sh asserts that a suite produced one runner session per test command -- the check that
catches "[jobs.compiler]'s equivalence half silently did not run" while the other half still writes
a plausible-looking baseline. That accounting has to ignore SETUP commands, which produce no
session: [jobs.byllm] leads with ci.yml's `jac install --global` for its four soft dependencies.
Counting every command instead would make a correct byllm job look half-broken forever."""
def test_cmd_count(cfg: dict, job: str) -> int {
    return len([c for c in job_cmds(cfg, job) if "jac test" in c]);
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
    } elif cmd == "testcmds" and len(args) == 4 {
        print(test_cmd_count(load_config_toml(args[3]), args[2]));
    } elif cmd == "cmds" and len(args) == 4 {
        for c in job_cmds(load_config_toml(args[3]), args[2]) {
            print(c);
        }
    } elif cmd == "hash" and len(args) == 3 {
        print(str(load_config_toml(args[2])["source"]["sha256"]));
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run cimirror.jac jobs|hash <ci-mirror.toml>");
        eprint("       jac run cimirror.jac cmds|testcmds <job> <ci-mirror.toml>");
    }
}

test "every declared job (gate jobs and tier-1's local-only step alike) has at least one command" {
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    names: list[str] = job_names(cfg);
    expected: list[str] = [
        "fmt", "fmt_autofix", "check", "jir", "byllm", "compiler", "runtime", "contribution"
    ];
    assert sorted(names) == sorted(expected);
    for n in names {
        assert len(job_cmds(cfg, n)) >= 1;
    }
}

test "the gate job list mirrors only real ci.yml jobs, excluding tier-1's own autofix step" {
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    gate: list[str] = gate_job_names(cfg);
    expected_gate: list[str] = ["fmt", "check", "jir", "byllm", "compiler", "runtime", "contribution"];
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
    # pins the regression this whole entry exists to fix: NOT the whole-repo git-ls-files sweep
    assert "--diff-filter=ACMR" in fmt;
    assert "merge-base" in fmt;
    assert "git ls-files" not in fmt;
    assert "No formattable .jac files changed" in fmt;
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

test "fmt and check both fail loud on a broken merge-base instead of silently skipping" {
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    for job in ["fmt", "check"] {
        cmd: str = job_cmds(cfg, job)[0];
        # the merge-base computation must NOT be inside the same `|| true` as the diff/skip logic
        assert "merge-base" in cmd;
        assert "exit 70" in cmd;
        # `|| true` must appear only after the diff pipeline, never immediately after merge-base
        assert 'HEAD 2>&1)" ||' in cmd;
    }
}

test "the two suites ci.yml runs under `working-directory: jac` cd there; the root-run one does not" {
    # Regression pin for a CONFIRMED silent false-green (2026-07-30). cimirror_job evals every
    # command from the repo ROOT, but ci.yml runs test-compiler (:182) and test-runtime (:251)
    # with `working-directory: jac`. Without the `cd jac`, all three commands died on
    # "File not found: 'tests/compiler'" -- and because the runner emits no FAILED/ERROR lines
    # when it never starts, testgate.jac parsed an EMPTY failing set, identical to a green run.
    # 4644 tests would have been baselined as count:0 and every branch would have passed a gate
    # that executed nothing.
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    for job in ["compiler", "runtime"] {
        for cmd in job_cmds(cfg, job) {
            assert cmd.startswith("cd jac && ");
        }
    }
    # test-packages-and-docs declares NO working-directory, so byllm must stay at the repo root
    # with a root-relative path. A `cd jac` here would break it in the opposite direction.
    for cmd in job_cmds(cfg, "byllm") {
        assert not cmd.startswith("cd jac");
    }
    assert "jac/jaclang/byllm/tests" in job_cmds(cfg, "byllm")[-1];
    # ci.yml:202-203 forces the equivalence suite back through the checkout's dev-source loop
    assert 'JAC_NO_DEV_SOURCE=""' in job_cmds(cfg, "compiler")[1];
}

test "byllm installs its four soft dependencies before running, and the counts stay honest" {
    # Regression pin for a MEASURED coverage hole: without this install under cimirror_job's clean
    # HOME, byllm collected 105 items instead of 219 -- the _optdeps shims turn a missing
    # dependency into silently-absent tests, not an error, so nothing downstream could notice.
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    cmds: list[str] = job_cmds(cfg, "byllm");
    install: str = cmds[0];
    assert install.startswith("jac install ");
    assert "--global" in install;
    for dep in ["litellm", "pillow", "httpx", "loguru"] {
        assert dep in install;
    }
    # test_cmd_count must ignore the setup command, or lib/verify.sh's session accounting would
    # declare a perfectly healthy byllm run half-broken forever.
    assert len(cmds) == 2;
    assert test_cmd_count(cfg, "byllm") == 1;
    assert test_cmd_count(cfg, "compiler") == 2;
    assert test_cmd_count(cfg, "runtime") == 1;
}

test "check mirrors ci.yml's literal IGNORE_ARGS shape: --ignore present, static globs present" {
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    check: str = job_cmds(cfg, "check")[0];
    assert "jac check" in check;
    assert "--ignore" in check;
    assert "IGNORE_ARGS" in check;
    assert "checker_*.jac" in check;
    assert "*_err.jac" in check;
}
