"""Read config/ci-mirror.toml. bash owns process sequencing; Jac owns the data (project rule).

argv:
  jobs <ci-mirror.toml>          print each GATE job name (mirrors a real ci.yml job), file order
  cmds <job> <ci-mirror.toml>    print that job's commands, one per line
"""
import sys;
import from nslib { eprint, load_config_toml, as_dict, as_list }

"""Every [jobs.*] table name. Since tier-1 and its [jobs.fmt_autofix] apply step were retired
(2026-07-30) every entry here is a read-only gate job, so this list IS the gate list.
ponytail: no local-only/gate filter, because there is nothing to filter -- reintroduce one only if
a genuinely local, MUTATING step ever earns a place in this file. The real invariant (no command
applies formatting) is pinned by bin/test-harness.sh section 6, which checks the commands
themselves rather than trusting a `ci_job` label to be set correctly."""
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

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "jobs" and len(args) == 3 {
        for n in job_names(load_config_toml(args[2])) {
            print(n);
        }
    } elif cmd == "testcmds" and len(args) == 4 {
        print(test_cmd_count(load_config_toml(args[3]), args[2]));
    } elif cmd == "cmds" and len(args) == 4 {
        for c in job_cmds(load_config_toml(args[3]), args[2]) {
            print(c);
        }
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run cimirror.jac jobs <ci-mirror.toml>");
        eprint("       jac run cimirror.jac cmds|testcmds <job> <ci-mirror.toml>");
    }
}

test "every declared job is a real ci.yml gate job with at least one command" {
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    names: list[str] = job_names(cfg);
    expected: list[str] = [
        "fmt", "check", "jir", "byllm", "compiler", "runtime", "contribution"
    ];
    assert sorted(names) == sorted(expected);
    for n in names {
        assert len(job_cmds(cfg, n)) >= 1;
        # No entry may reintroduce a local-only marker without also reintroducing the gate filter
        # this file deleted with tier-1: an unfiltered "none" job would run inside the S4 gate.
        assert not job_ci_job(cfg, n).startswith("none");
    }
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

test "no job applies formatting: every jac fmt in the registry carries --check" {
    # Tier-1 was the only APPLY step and is retired, so this file must stay uniformly read-only --
    # a gate that rewrites the branch it is judging would silently make its own verdict true.
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    for n in job_names(cfg) {
        for c in job_cmds(cfg, n) {
            if "jac fmt" in c {
                assert "--check" in c;
            }
            assert "jac format" not in c;
            assert "jac lint --fix" not in c;
        }
    }
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
