"""Read config/ci-mirror.toml. bash owns process sequencing; Jac owns the data (project rule).

argv:
  jobs <ci-mirror.toml>          print each GATE job name (mirrors a real ci.yml job), file order
  cmds <job> <ci-mirror.toml>    print that job's commands, one per line
  hash <ci-mirror.toml>          print the recorded ci.yml sha256
  filter-survivors <jacignore>   read candidate paths on stdin, one per line; print only the
                                 ones [jobs.check] should actually check (see below for why this
                                 exists instead of just passing everything to `jac check --ignore`)
"""
import sys;
import os;
import from fnmatch { fnmatch }
import from nslib { eprint, read_stdin, load_config_toml, as_dict, as_list }

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

"""[jobs.check]'s exclusion list, without ever handing all ~570 of them to `jac check --ignore`
as separate argv tokens (see path_matches_ignore for why). The two static globs plus `tests`
mirror ci.yml:415's literal IGNORE_ARGS prefix; the rest is every non-comment, non-blank line of
the target repo's own .jacignore -- the exact same source CI's IGNORE_ARGS reads."""
def load_ignore_patterns(jacignore_path: str) -> list[str] {
    patterns: list[str] = ["tests", "checker_*.jac", "*_err.jac"];
    if os.path.exists(jacignore_path) {
        with open(jacignore_path, "r") as f {
            for line in f {
                stripped: str = line.strip();
                if stripped and not stripped.startswith("#") {
                    patterns.append(stripped);
                }
            }
        }
    }
    return patterns;
}

"""Port of jaclang.jac0core.helpers.path_matches_exclude (jac/jaclang/jac0core/helpers.jac):
a slash-free pattern matches if ANY path component matches it (fnmatch, not just the basename);
a pattern with a slash matches the whole normalized path, or the path with any prefix ending in
'/' stripped (i.e. as a path suffix). Dropped only the third, rarely-hit variant of the original
(`fnmatch('_/' + norm, pattern)`, for patterns that themselves already start with '*/') -- none of
the two static globs or any of .jacignore's ~570 entries start with '*/' (verified 2026-07-30), so
this is a no-op simplification for this codebase's actual pattern set, not a behavior change.

WHY THIS EXISTS AT ALL, not just `jac check <files> --ignore <everything>`: verified empirically
that `jac check`'s own `--ignore` flag (argparse `nargs='*'`, following a required `nargs='+'`
positional) silently breaks once it receives roughly 100-150 values under this host's Python
3.14.5 -- `paths`/`ignore` still parse, but `jac check` then reports "0 collected" (a clean exit
0, not an error) regardless of real type errors in the files given. Confirmed via a minimal,
jac-independent reproduction (bare `argparse.ArgumentParser` with the identical `paths`
nargs='+' + `--ignore` nargs='*' shape) that this is upstream CPython/argparse behavior, not a
bug in jac's own CLI registration code (jac/jaclang/cli/impl/registry.impl.jac uses plain
stdlib argparse). Binary-searched the threshold: 100 values still worked, 120-150 did not.
.jacignore has 570 non-comment lines, so mirroring ci.yml:415 literally
(`jac check $FILES --ignore $IGNORE_ARGS --nowarn`) is silently, permanently broken on this host
-- exactly the "gate reports green when it cannot actually tell" failure mode this whole review
round exists to close, just discovered one command over. Filtering candidate files against the
ignore list OURSELVES (this function), then calling `jac check <survivors> --nowarn` with NO
--ignore at all, sidesteps the argparse limitation entirely: the diff-scoped file list is always
small (a PR's own changed files), so filtering it here costs nothing."""
def path_matches_ignore(file_path: str, patterns: list[str]) -> bool {
    norm: str = file_path.replace("\\", "/");
    parts: list[str] = [p for p in norm.split("/") if p];
    for pattern in patterns {
        if "/" in pattern {
            if fnmatch(norm, pattern) or fnmatch(norm, "*/" + pattern) {
                return True;
            }
        } else {
            for part in parts {
                if fnmatch(part, pattern) {
                    return True;
                }
            }
        }
    }
    return False;
}

def filter_survivors(paths: list[str], patterns: list[str]) -> list[str] {
    return [p for p in paths if p and not path_matches_ignore(p, patterns)];
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
    } elif cmd == "filter-survivors" and len(args) == 3 {
        patterns: list[str] = load_ignore_patterns(args[2]);
        candidates: list[str] = [
            line for line in read_stdin().splitlines() if line.strip()
        ];
        for p in filter_survivors(candidates, patterns) {
            print(p);
        }
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run cimirror.jac jobs|hash <ci-mirror.toml>");
        eprint("       jac run cimirror.jac cmds <job> <ci-mirror.toml>");
        eprint("       jac run cimirror.jac filter-survivors <jacignore> < paths.txt");
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

test "check does not hand jac check's --ignore hundreds of raw argv tokens" {
    cfg: dict = load_config_toml("config/ci-mirror.toml");
    check: str = job_cmds(cfg, "check")[0];
    assert "jac check" in check;
    assert "filter-survivors" in check;
    assert "--ignore" not in check;

    # and filter_survivors itself must actually reproduce path_matches_exclude's semantics
    patterns: list[str] = ["checker_*.jac", "*_err.jac", "AlertContext.jac", "passes/native/llvm/*"];
    survivors: list[str] = filter_survivors(
        [
            "jac/jaclang/byllm/tool_protocol.jac",
            "jac/jaclang/byllm/tests/checker_foo.jac",
            "jac/jaclang/byllm/tests/fixtures/model_pool_err.jac",
            "jac/some/AlertContext.jac",
            "jac/jaclang/compiler/passes/native/llvm/binding/dylib.jac",
        ],
        patterns
    );
    assert survivors == ["jac/jaclang/byllm/tool_protocol.jac"];
}
