# shellcheck shell=bash
# lib/verify.sh — S4 (TechnicalPRD 7-S4): fail-closed gate. Any red after retry → branch deleted.

BASELINE_DIR="$NS_ROOT/state/test-baseline"

# The target suite is not green on main here (env/infra failures) and is slow, so we gate on a
# per-SUITE BASELINE of already-failing tests (see testgate.jac) rather than a fully-green run.
#
# suite_test_raw <suite> <outfile>: run one mirrored TEST suite's commands, combined output to
# <outfile>. <suite> is a config/ci-mirror.toml JOB NAME (compiler | runtime | byllm), never a
# package name. Routing test running through lib/cimirror.sh is the whole point: the gate and real
# CI now read their commands out of one registry, so they cannot drift apart. The predecessor
# (pkg_test_raw) hardcoded its own invocations, named packages that the restructure deleted, and
# omitted the cross-backend equivalence suite (jac test jaclang/compiler/tests) entirely.
#
# The RUNNER's own exit code is ignored ON PURPOSE: baseline failures are expected on main, and
# testgate.jac decides pass/fail on NEW failures only. Do not "fix" that by propagating it.
#
# A cimirror READER failure is NOT that, and IS propagated. cimirror_job returns EX_MIRROR_READ (70)
# when it cannot list a job's commands at all -- malformed TOML, a renamed or missing [jobs.*]
# entry -- and writes no command output. Swallowed, that yields an empty capture, an empty
# failing-id set, and a gate that reports green while testing nothing. A config error must never be
# read as "the suite ran and had baseline failures". (70 is unambiguous for the three TEST suites:
# unlike [jobs.fmt]/[jobs.check], none of their commands contain an `exit 70` of their own, and the
# runner itself only ever exits 0-5.)
#
# HOME is deliberately NOT set here. cimirror_job already runs every command under
# $LOG_DIR/mirror-home -- one clean-but-warm HOME per NIGHT, see lib/cimirror.sh's header for why it
# is not per-job. A second HOME here would re-pay that ~45s/~100MB cold-cache cost per suite and put
# the test jobs in a different environment from every other mirrored job. Measured 2026-07-30: the
# often-repeated claim that the bundled runner "needs a clean HOME or its conftest import fails" is
# FOLKLORE -- `jac test tests/utils` under this host's real HOME collects and passes 11/11 in 4.17s,
# conftest.py imported fine. Clean-HOME isolation is still the right call, but for the honest reason:
# ci.yml:187/208/256 run the compiler and runtime suites under `HOME="$WORK"` (a fresh mktemp -d),
# so matching CI is the fidelity argument. See the byllm caveat in config/ci-mirror.toml.
suite_test_raw() {
    local suite=$1 out=$2 rc=0
    : > "$out"
    cimirror_job "$suite" "$out" || rc=$?
    # `case`, never `[ "$rc" -eq "$EX_MIRROR_READ" ] && return "$EX_MIRROR_READ"`: a false `&&` list
    # is itself a nonzero return, which aborts an errexit caller (e.g. baseline_main) on the
    # SUCCESS path. Project rule; this file's callers include one that runs with errexit live.
    case "$rc" in
        0)                 return 0 ;;
        "$EX_MIRROR_READ") return "$EX_MIRROR_READ" ;;
    esac
    # Some command in the job failed. "Ignore the runner's exit code" means ignore a TEST command's
    # -- baseline failures are expected and testgate.jac decides on NEW failures only. It does NOT
    # mean ignore a SETUP command's. [jobs.byllm] leads with ci.yml's `jac install --global`, and a
    # failed or skipped install (offline night, upstream index outage) is night-wide by
    # construction: every byllm branch then collects 105 instead of 219 and reds IDENTICALLY on the
    # collection floor, incrementing attempts each time. Two such nights auto-reject every byllm
    # finding in the ledger. So a setup failure is harness-fatal, exactly like a reader failure, and is the
    # counterexample to treating "the suite ran and under-collected" as always branch-attributable.
    # An empty CIMIRROR_FAILED_CMD alongside a nonzero rc should be impossible; treat it as fatal
    # too rather than guessing (fail closed).
    case "$CIMIRROR_FAILED_CMD" in
        *"jac test"*) return 0 ;;
    esac
    return "$EX_MIRROR_SETUP"
}

# Map changed paths to the mirrored TEST suites that cover them, and emit the unique set.
# Post-restructure geography: byllm and scale live under jac/jaclang/. A release-note-fragment-only
# change gets no test gate -- the fmt, check, jir and contribution jobs still gate it.
#
# There is deliberately NO `jac-mcp/*` arm any more (removed 2026-07-30 with the shard-registry
# entry): upstream deleted jac-mcp in 59f68a7a1 and `git ls-files jac-mcp` returns 0 tracked files,
# so nothing this harness audits can produce such a path. The arm's justifying evidence -- "a
# recorded baseline confirmed no tests ran" -- was a baseline for a directory that no longer exists
# upstream, i.e. it proved nothing about today's repo. A stray `jac-mcp/` path would now simply
# match no case arm, which is the same "gates no suite" answer the explicit arm gave.
#
# ORDER MATTERS: the compiler and byllm cases MUST precede the jac/* catch-all, or a byllm-only
# change routes to the large, env-flaky runtime suite. That exact mis-routing (via `cut -d/ -f1`,
# which mapped jac/jaclang/byllm -> "jac") is why the predecessor existed in the shape it did, and
# it is a bug this codebase has already been bitten by. Case arms are matched top-down and the
# first match wins, so the order below IS the contract -- do not alphabetize it.
#
# This is deliberately NARROWER than real CI, which is worth knowing before "fixing" it: ci.yml's
# path filter is `core: jac/**` (ci.yml:41-44), so upstream a byllm-only or compiler-only change
# ALSO runs test-runtime, and `docs: release_notes/**` (ci.yml:49-52) makes a fragment-only change
# run test-packages-and-docs. Mirroring that breadth locally would drag the 1852-test runtime suite
# into nearly every night for no janitorial signal. The narrowing is a cost decision, not an
# oversight; CI remains the authority and still runs the full matrix on the PR.
gated_suites_from_diff() {
    git -C "$REPO" diff --name-only "$NS_REPO_DEFAULT_BRANCH...HEAD" | while IFS= read -r p; do
        case "$p" in
            jac/jaclang/compiler/*) echo compiler ;;
            jac/jaclang/byllm/*)    echo byllm ;;
            # The compiler suite's own test tree. It must NOT fall through to the jac/* catch-all:
            # [jobs.runtime]'s command is `jac test tests/ --ignore tests/compiler`, so runtime is
            # the one suite guaranteed NOT to collect these files, while [jobs.compiler]'s first
            # command (`jac test tests/compiler`) is exactly the one that does. Reachable in
            # practice even though [protect] lists `**/tests/**`: check_scope.jac lets a theme's
            # `vestigial_deletions` paths bypass the protected-glob check when the change is a clean
            # delete, which is precisely how a dead-test sweep -- Nightshift's most common theme --
            # reaches this gate. Without this arm, deleting a compiler test that another compiler
            # test depends on would be "gated" by a suite that never collects either of them.
            jac/tests/compiler/*)   echo compiler ;;
            release_notes/*)        ;;                 # fragment only
            jac/*)                  echo runtime ;;
        esac
    done | sort -u
}

# Positively assert that a suite RAN, before anything is allowed to read meaning into its capture.
# Used on BOTH paths -- recording a baseline and gating a branch. Dies; never returns nonzero.
#
# `failing_ids` cannot tell "the suite ran and nothing failed" from "the suite never started":
# both parse to zero ids. Confirmed live 2026-07-30 -- [jobs.compiler]/[jobs.runtime] carried
# ci.yml's `working-directory: jac` relative paths but cimirror_job runs from the repo ROOT, so all
# three commands died instantly on `File not found: 'tests/compiler'`, 4644 tests silently unrun.
#
# Guarding only baseline_main was not enough, and shipping it that way was the mistake this
# function exists to correct (code review 2026-07-30, Critical): suite_test_raw converts every
# nonzero except EX_MIRROR_READ into `return 0`, so on the BRANCH path a suite that never started
# arrived at `testgate gate` as an empty capture and scored as a clean pass -- the same false-green,
# on the path that actually decides which branches become PRs. Baselines are recorded once and
# reused for months, so the next upstream restructure that moves jac/tests/ would have re-opened it
# on every branch, silently.
#
# Session count is compared against the number of TEST commands ([jobs.byllm] leads with a non-test
# `jac install`, so "one session per command" would be wrong), and a mismatch is FATAL rather than a
# warning: none of the three test suites has a conditional command -- unlike [jobs.fmt]/[jobs.check],
# which legitimately skip when nothing changed -- so a mismatch is always a bug. Concretely, it is
# how [jobs.compiler]'s cross-backend equivalence half (the suite this whole task exists to start
# gating) could silently not run while a plausible-looking baseline was written from the other half.
assert_suite_ran() {
    local suite=$1 raw=$2 rc=$3 where=$4 sessions want collected sub_rc=0
    case "$rc" in
        0) : ;;
        "$EX_MIRROR_READ")
            ns_die "$EX_BUG" "$where $suite: cimirror could not read [jobs.$suite] from config/ci-mirror.toml (rc=$rc) -- the gate is broken, not the branch." ;;
        "$EX_MIRROR_SETUP")
            ns_die "$EX_BUG" "$where $suite: a SETUP command in [jobs.$suite] failed, so the suite ran in a broken environment: $CIMIRROR_FAILED_CMD -- this is night-wide, not this branch's fault; fix the environment rather than letting every branch red on the collection floor." ;;
        *)  ns_die "$EX_BUG" "$where $suite: suite_test_raw returned an unexpected rc=$rc -- refusing to interpret the capture." ;;
    esac
    # `|| sub_rc=$?` on every substitution: baseline_main runs with errexit LIVE, where a bare
    # `x="$(cmd)"` that fails exits the shell instantly with no [FATAL] line -- safe direction, but
    # the autopsy email then loses the reason. Same rule this file states for baseline_main.
    sessions="$(ns_jac testgate sessions "$raw")" || sub_rc=$?
    want="$(ns_jac cimirror testcmds "$suite" "$CI_MIRROR_CONFIG")" || sub_rc=$?
    collected="$(ns_jac testgate collected "$raw")" || sub_rc=$?
    case "$sub_rc" in
        0) : ;;
        *) ns_die "$EX_BUG" "$where $suite: could not read back the capture's own counters (rc=$sub_rc) -- see $(basename "$raw")." ;;
    esac
    # Numeric-validate BOTH sides before comparing. Matching only the literal string `0` was a real
    # hole (code review, Minor): the cold-cache "Setting up Jac for first use..." banner that
    # lib/cimirror.sh's own header documents can land on stdout, and a non-numeric session count
    # would then have silently failed to equal "0" and sailed through.
    case "$sessions" in
        ''|*[!0-9]*) ns_die "$EX_BUG" "$where $suite: could not read a session count from $(basename "$raw") (got '$sessions')." ;;
    esac
    case "$want" in
        ''|*[!0-9]*|0) ns_die "$EX_BUG" "$where $suite: [jobs.$suite] declares no runnable test command (got '$want') -- a suite that cannot run must not be treated as a gate." ;;
    esac
    case "$sessions" in
        "$want") : ;;
        *) ns_die "$EX_BUG" "$where $suite: expected $want test-runner session(s), one per test command in [jobs.$suite], but $(basename "$raw") has $sessions. Refusing to score a suite that did not run as a pass -- check that job's command paths and cwd in config/ci-mirror.toml." ;;
    esac
    # A session banner is not proof the run COLLECTED anything: a collection-error run prints
    # `collected 0 items / 1 error` under a perfectly normal banner. Left unchecked on the baseline
    # path that writes `collected: 0`, and collection_check answers 2 ("cannot gate") for a zero
    # count -- silently and permanently disabling the very backstop it belongs to. Verified: with
    # `"collected": 0` recorded, a branch collecting 3 of 200 went GREEN and published
    # "tests (no new failures vs baseline) ✓". Enforced HERE rather than in baseline_main so it
    # also covers the branch path, where a run that collects nothing is equally meaningless.
    case "$collected" in
        ''|*[!0-9]*|0) ns_die "$EX_BUG" "$where $suite: the runner started but collected $collected tests (see $(basename "$raw")). A baseline recorded from this could never gate anything, and a branch run this empty cannot be read as passing." ;;
    esac
}

# Did one of the two conditionally-skipping mirror jobs decline to check anything?
#
# [jobs.fmt] and [jobs.check] both EXIT 0 after printing a skip line when the branch changed no
# (formattable) .jac file, so their rc says nothing about whether they did work. verify_branch keys
# the line it publishes to the PR body off this, so a wrong answer here puts "did not run" into a
# human's review as "passed" -- this plan's dominant defect, in its most visible location.
#
# ANCHORED `^...$`, and that anchoring is the whole point (found the hard way while proving the fix:
# an unanchored `grep -q 'skipping format check\.'` reported EVERY branch as skipped). cimirror_job
# echoes each command into the capture as `$ <cmd>` BEFORE running it, and these two commands
# contain their own skip sentence as an `echo` argument -- so the needle is always present in the
# capture whether the job skipped or not. Only the job's real, unprefixed, whole-line output can
# tell. Anchoring on the line rather than on cimirror_job's `$ ` prefix keeps this correct even if
# that prefix ever changes.
#
# An unknown job is FATAL rather than "did not skip": every job this is not asked about would
# otherwise be silently reported as having run. Only fmt and check have a skip path at all.
mirror_job_skipped() {
    local job=$1 cap=$2 needle
    case "$job" in
        fmt)   needle='^No formattable \.jac files changed; skipping format check\.$' ;;
        check) needle='^No \.jac files changed; skipping jac check\.$' ;;
        *)     ns_die "$EX_BUG" "mirror_job_skipped: '$job' has no known skip line; refusing to guess whether it ran." ;;
    esac
    grep -qE "$needle" "$cap"
}

# Assert `jac check` actually ran before its (empty) output is read as "clean". Sibling of
# assert_suite_ran, for the type-check stage; see the call sites for the full reasoning. A broken
# checker is a harness problem, night-wide and not this branch's fault, so it aborts rather than
# reding -- same judgement as a cimirror reader failure.
assert_check_ran() {
    local branch=$1 raw=$2 side=$3 ran sub_rc=0
    ran="$(ns_jac checkgate ran "$raw")" || sub_rc=$?
    case "$sub_rc" in
        0) : ;;
        *) ns_die "$EX_BUG" "jac check ($side side, $branch): could not read back the capture's run count (rc=$sub_rc) -- see $(basename "$raw")." ;;
    esac
    case "$ran" in
        ''|*[!0-9]*|0) ns_die "$EX_BUG" "jac check ($side side, $branch): the checker never ran -- $(basename "$raw") has no run summary (got '$ran'). Refusing to read an empty capture as a clean type-check; check \$NS_PATHS_JAC_REPO." ;;
    esac
}

# Record the per-suite baseline of already-failing tests on main, as the UNION of TWO runs so a
# flaky test is baselined instead of reding branches. Slow (two full suite runs each); run once
# after migration and after any major upstream sync. `nightshift.sh baseline`.
#
# Runs under bin/nightshift.sh's `set -euo pipefail` with errexit LIVE (unlike verify_branch, which
# bash silently exempts because it is always called from an `if` condition), so every nonzero here
# must be captured with `|| rc=$?` rather than left bare.
baseline_main() {
    mkdir -p "$BASELINE_DIR"
    cd "$REPO"; git checkout "$NS_REPO_DEFAULT_BRANCH"
    local suite raw1 raw2 n rc ncoll
    for suite in compiler runtime byllm; do
        raw1="$LOG_DIR/baseline-raw-$suite-1.txt"
        raw2="$LOG_DIR/baseline-raw-$suite-2.txt"
        ns_log BASELINE "recording $suite, run 1 of 2 (slow)..."
        rc=0; suite_test_raw "$suite" "$raw1" || rc=$?
        assert_suite_ran "$suite" "$raw1" "$rc" baseline
        ns_log BASELINE "recording $suite, run 2 of 2 (slow)..."
        rc=0; suite_test_raw "$suite" "$raw2" || rc=$?
        assert_suite_ran "$suite" "$raw2" "$rc" baseline
        rc=0
        n="$(ns_jac testgate record-union "$suite" "$raw1" "$raw2" "$BASELINE_DIR")" || rc=$?
        ncoll="$(ns_jac testgate collected "$raw1")" || rc=$?
        case "$rc" in
            0) : ;;
            *) ns_die "$EX_BUG" "baseline $suite: failed to record the baseline (rc=$rc) -- state/test-baseline/$suite.json may be missing or partial." ;;
        esac
        ns_log BASELINE "$suite: $n known-failing tests recorded (union of 2 runs), $ncoll tests collected"
    done
}

verify_main() {
    [ -f "$LOG_DIR/queue.tsv" ] || { ns_log S4 "no branches queued"; return 0; }
    local branch theme report shipped=0
    while IFS=$'\t' read -r branch theme report; do
        if verify_branch "$branch" "$theme"; then
            ns_mark_green "$branch" "$theme" "$report"
            shipped=$((shipped + 1))
        fi
    done < "$LOG_DIR/queue.tsv"
    if [ "$shipped" -eq 0 ] && [ -s "$LOG_DIR/queue.tsv" ]; then
        ns_log S4 "every queued branch failed the gate"
        return "$EX_ALLFAIL"
    fi
    return 0
}

# Gate order: scope containment → jac check baseline-diff (changed files) → the FAST CI-mirror jobs
# (fmt, check, jir) → baseline-diff test gate → pre-commit → the contribution CI-mirror job.
#
# The fast mirror jobs sit deliberately BEFORE the suites: they cost ~3s warm and are each fatal for
# a fork PR, so a doomed branch dies in seconds instead of after ~40min of tests. bin/test-harness.sh
# section 8 asserts that ordering, because getting it backwards is silently expensive rather than
# visibly broken.
verify_branch() {
    # on_red: `demote` (default) is the S4 behavior -- a red branch is failed_verify'd (attempts++,
    # auto-rejected at 2) and deleted. `report` is for S1.6's re-gate of an ALREADY-OPEN PR, where
    # the branch is upstream and the red may not be its fault at all: [jobs.contribution] validates
    # whole-repo state (validate_docs_code.jac's 852 blocks, the bun/zig BUN_VERSION lockstep), so
    # an upstream-introduced breakage reds every open PR identically and would auto-reject the
    # entire ledger in two nights over something no branch caused. Passed EXPLICITLY to every
    # verify_red below rather than read out of dynamic scope, because bash's dynamic scoping would
    # make this work by accident and then break silently the day a call site moves.
    local branch=$1 theme=$2 on_red="${3:-demote}" t0 t1
    t0="$(date +%s)"
    cd "$REPO"
    # `|| ns_die`, NOT bare. verify_branch is only ever invoked as an `if` CONDITION
    # (lib/verify.sh's verify_main, lib/promote.sh:62), so bash suspends errexit for its entire
    # body -- and the suspension propagates into the `( ... )` subshells below too. A bare
    # `git checkout` that failed (a branch deleted underneath us, an index lock, a dirty tree from
    # a killed apply session) would therefore run every stage below against whatever IS checked
    # out -- normally main, which passes -- return 0, reach ns_mark_green, and hand ship_branch a
    # ref that does not exist. Did-not-run scored as passed, in the function that decides what
    # becomes a PR.
    git checkout "$branch" || ns_die "$EX_BUG" "could not check out $branch in $REPO -- the gate would otherwise have run against whatever is currently checked out (normally $NS_REPO_DEFAULT_BRANCH) and scored THAT as this branch passing."
    rm -rf "$REPO/.jac"        # `jac clean --cache` prompts [y/N] non-interactively -> aborts; nuke directly

    # 1. scope containment FIRST — reject before spending a second on tests (anti-injection, T1).
    # --name-status (not --name-only): a vestigial test deletion must be a clean delete, never a
    # modification -- the gate needs to see which each changed path actually is.
    # The TASK comes from the branch name, not the theme: [tasks.<task>].protect_unless decides
    # whether this branch may write inside a protected glob, and the theme is agent-derived.
    if [ "$theme" != "-" ]; then
        local btask
        btask="$(ns_task_of_branch "$branch")" || ns_die "$EX_BUG" "cannot derive a task from branch '$branch': its slug matches no name in [tasks.*]. Refusing to gate it -- with no task there is no permission set to apply, and defaulting to one would either reject every coverage branch or hand every branch the coverage exemption."
        if ! git diff --name-status "$NS_REPO_DEFAULT_BRANCH...HEAD" \
                | ns_jac check_scope check "$theme" "$CONFIG" "$btask" > "$LOG_DIR/scope-violations.txt"; then
            verify_red "$branch" "scope violation (possible prompt injection): $(head -3 "$LOG_DIR/scope-violations.txt" | tr '\n' ' ')" "$on_red"
            return 1
        fi

        # 1b. TEST-WEAKENING guard. The coverage task may modify an existing test file; weakening
        #     one is how this task fails while gating green, so it is checked before anything
        #     expensive. Applied to EVERY task, not just coverage: the cheapest way for any theme
        #     to turn a red suite green is to delete the assertion.
        local tw_files tw_rc=0 tw_checked=0 tw_f tw_old
        tw_files="$(git diff --name-status "$NS_REPO_DEFAULT_BRANCH...HEAD" | awk '$1 == "M" { print $2 }')" || tw_rc=$?
        case "$tw_rc" in
            0) : ;;
            *) ns_die "$EX_BUG" "could not list modified files for the test-weakening guard (rc=$tw_rc). An empty list here is indistinguishable from 'this branch modified nothing', which is exactly how a weakened test would sail through." ;;
        esac
        : > "$LOG_DIR/test-weakening.txt"
        # word-split is deliberate; repo paths contain no spaces (same assumption as the shard
        # findings list in lib/tier2.sh, and a violation of it fails loudly on the git show below)
        for tw_f in $tw_files; do
            git -C "$REPO" cat-file -e "$NS_REPO_DEFAULT_BRANCH:$tw_f" 2>/dev/null || continue
            tw_old="$LOG_DIR/tw-old-$(printf '%s' "$tw_f" | tr / _)"
            git -C "$REPO" show "$NS_REPO_DEFAULT_BRANCH:$tw_f" > "$tw_old" \
                || ns_die "$EX_BUG" "git show $NS_REPO_DEFAULT_BRANCH:$tw_f failed; the test-weakening guard cannot compare what it cannot read, and skipping it silently is how a weakened test ships."
            if ! ns_jac check_scope weakened "$tw_f" "$tw_old" "$REPO/$tw_f" >> "$LOG_DIR/test-weakening.txt"; then
                verify_red "$branch" "test weakened: $(grep VIOLATION "$LOG_DIR/test-weakening.txt" | head -2 | tr '\n' ' ')" "$on_red"
                return 1
            fi
            tw_checked=$((tw_checked + 1))
        done
        ns_log S4 "test-weakening guard: compared $tw_checked modified file(s) against $NS_REPO_DEFAULT_BRANCH"
    fi

    # 2. type-check changed .jac files, BASELINE-DIFF style. The repo is not clean under
    #    `jac check` on main (pre-existing E1053 "Cannot assign Any" etc.), so a plain "must pass"
    #    gate would reject any branch that merely touches such a file. Instead: check the changed
    #    files on the branch AND on their main content, fail only on NEW errors (checkgate.jac).
    #    A whole-repo check is avoided anyway — it would trip the repo's broken test fixtures.
    #
    #    The diff is materialized and its exit status checked BEFORE the `|| true` grep. Previously
    #    the whole pipeline was wrapped in one `|| true`, so a failing `git diff` (bad or unset
    #    $NS_REPO_DEFAULT_BRANCH, detached HEAD, no shared history) collapsed into an empty file
    #    list -- indistinguishable from "this branch changed no .jac files" -- and skipped the
    #    entire jac-check stage silently. Same shape as the reader bugs already fixed in
    #    lib/cimirror.sh; found in the same code review. The `|| true` on the grep itself is
    #    legitimate and stays: grep exits 1 when a branch genuinely touches no .jac file.
    local changed_jac changed_all changed_rc=0 main_jac f br mr
    changed_all="$(git -C "$REPO" diff --name-only "$NS_REPO_DEFAULT_BRANCH...HEAD")" || changed_rc=$?
    case "$changed_rc" in
        0) : ;;
        *) ns_die "$EX_BUG" "could not diff $NS_REPO_DEFAULT_BRANCH...HEAD in $REPO (rc=$changed_rc) -- with no reliable file list neither the type-check nor the test gate can run, and an empty list would look like a clean branch." ;;
    esac
    changed_jac="$(printf '%s\n' "$changed_all" | grep '\.jac$' || true)"
    if [ -n "$changed_jac" ]; then
        br="$LOG_DIR/check-branch-$(basename "$branch").txt"
        mr="$LOG_DIR/check-main-$(basename "$branch").txt"
        # branch side (the branch is checked out)
        rm -rf "$REPO/.jac"
        # shellcheck disable=SC2086  # word-split into per-file args; jac paths have no spaces
        ( cd "$REPO" && "$NS_PATHS_JAC_REPO" check $changed_jac ) > "$br" 2>&1 || true
        # main side: only files that exist on main (new-on-branch files have no baseline -> their
        # errors all count as new). Restore just those files to main content, check, then put back.
        main_jac=""
        for f in $changed_jac; do
            git -C "$REPO" cat-file -e "$NS_REPO_DEFAULT_BRANCH:$f" 2>/dev/null && main_jac="$main_jac $f"
        done
        if [ -n "$main_jac" ]; then
            # Both checkouts are `|| ns_die` for the same errexit-is-suspended reason as the branch
            # checkout at the top of this function, and each has its own did-not-run failure mode:
            #   * a failed SWAP-TO-MAIN leaves branch content in place, so `$mr` is captured from
            #     the BRANCH -- identical to `$br` -- and checkgate can then never see a new error
            #     while assert_check_ran still passes happily. A gate that structurally cannot fail.
            #   * a failed RESTORE leaves MAIN's content for those files in the working tree, so
            #     every stage below (fmt/check/jir, the test suites, pre-commit, contribution)
            #     gates main instead of the branch, and the branch ships ungated.
            # shellcheck disable=SC2086
            git -C "$REPO" checkout "$NS_REPO_DEFAULT_BRANCH" -- $main_jac \
                || ns_die "$EX_BUG" "could not restore $NS_REPO_DEFAULT_BRANCH content for the jac-check baseline side ($main_jac) in $REPO. The main-side capture would have been taken from BRANCH content, making 'no NEW type errors' impossible to violate."
            rm -rf "$REPO/.jac"
            # shellcheck disable=SC2086
            ( cd "$REPO" && "$NS_PATHS_JAC_REPO" check $main_jac ) > "$mr" 2>&1 || true
            # shellcheck disable=SC2086
            git -C "$REPO" checkout HEAD -- $main_jac \
                || ns_die "$EX_BUG" "could not restore BRANCH content for $main_jac in $REPO after the jac-check baseline side. Every remaining gate stage would have run against $NS_REPO_DEFAULT_BRANCH's version of those files."
        else
            : > "$mr"
        fi
        # Same did-not-run hole as the test gate, on this stage. Both `jac check` invocations above
        # end in `|| true` -- legitimately, since the checker exits 1 whenever the file has any
        # error -- which discards the difference between "ran, exit 1, found errors" and "never
        # ran at all" (missing/unexecutable $NS_PATHS_JAC_REPO, an exec arg-list blowup, a crash).
        # checkgate's identities() returns empty for both, gate() then finds no NEW identity,
        # returns 0, and this function publishes "jac check ✓". Measured: a real run always prints
        # an `N passed|failed in Xs` summary, a missing binary exits 127 and prints none.
        # The main side is asserted only when it actually ran: `$mr` is deliberately left EMPTY
        # when no changed file exists on main (every branch error is then correctly new).
        assert_check_ran "$branch" "$br" "branch"
        case "$main_jac" in "") : ;; *) assert_check_ran "$branch" "$mr" "main" ;; esac
        if ! ns_jac checkgate gate "$mr" "$br"; then
            verify_red "$branch" "jac check: new type errors vs main (see $(basename "$br"))" "$on_red"
            return 1
        fi
    fi

    # 3. FAST CI-mirror jobs, BEFORE the expensive suites. All three are ci.yml `jac-check` steps,
    #    all three cost seconds, and all three are FATAL for a Nightshift PR:
    #      fmt   — the check step itself carries `continue-on-error: true` (ci.yml:341), but the
    #              autofix push that would rescue it is same-repo-only
    #              (ci.yml:363-367, `head.repo.full_name == github.repository`) and Nightshift opens
    #              FORK PRs, so the follow-up "Fail if formatting was not clean" step
    #              (ci.yml:401-405) hard-fails the job anyway. A misformatted branch is dead on
    #              arrival upstream.
    #      jir   — ci.yml:407-409, no continue-on-error. A dead-code sweep that deletes a symbol can
    #              invalidate the generated registry, i.e. CI reds on a file the agent never touched.
    #      check — ci.yml:411-424, no continue-on-error.
    #
    #    `check` is in the fast set ON PURPOSE and is NOT a duplicate of step 2 above. Step 2 is a
    #    BASELINE-DIFF check (new errors vs the same files' main content, no --ignore), deliberately
    #    permissive so a branch is not punished for a file's pre-existing errors. [jobs.check] is
    #    CI's literal `jac check $FILES --ignore $IGNORE_ARGS --nowarn`: a hard must-exit-0 gate
    #    whose ~570-entry .jacignore list is precisely the set of files upstream has already excused.
    #    A branch can pass step 2 and still be red in real CI (touching a non-ignored file that has
    #    a pre-existing error), and this is the only stage that notices — while step 2 is the only
    #    stage that notices a NEW error in a file .jacignore excuses. They cover different holes.
    #    Measured on this host, warm mirror-home, one changed file: fmt 0s, check 2s, jir 1s.
    #
    #    rc=EX_MIRROR_READ (70) ABORTS THE NIGHT rather than reding the branch. Two distinct things
    #    return 70 here and both are harness faults, not branch faults: cimirror_job's own
    #    EX_MIRROR_READ (unreadable/renamed [jobs.*] in config/ci-mirror.toml) and
    #    [jobs.fmt]/[jobs.check]'s own `exit 70` for an uncomputable merge-base (bad or unset
    #    $NS_REPO_DEFAULT_BRANCH, detached HEAD, no shared history). The ambiguity does not matter
    #    because the response is the same: both fail identically for EVERY queued branch, so reding
    #    would burn every finding's attempt counter and auto-reject the whole ledger after two nights
    #    over one config typo. Same judgement assert_suite_ran already applies to the test suites.
    #    (No mirror job may MUTATE the branch it is judging. Since tier-1's apply step was retired
    #    the whole registry is read-only, and bin/test-harness.sh section 6 pins that by inspecting
    #    the commands themselves rather than trusting a label.)
    local mrr fastjob fast_rc
    mrr="$LOG_DIR/mirror-fast-$(basename "$branch").txt"
    : > "$mrr"
    for fastjob in fmt check jir; do
        fast_rc=0
        cimirror_job "$fastjob" "$mrr" || fast_rc=$?
        case "$fast_rc" in
            0) : ;;
            "$EX_MIRROR_READ")
                ns_die "$EX_BUG" "CI mirror job '$fastjob' returned $EX_MIRROR_READ: either config/ci-mirror.toml could not be read, or the job could not compute a merge-base against '$NS_REPO_DEFAULT_BRANCH'. Both are harness faults that would fail identically for every queued branch, so $branch is not being blamed for it (see $(basename "$mrr"))." ;;
            *)  verify_red "$branch" "CI mirror job '$fastjob' red (see $(basename "$mrr"))" "$on_red"
                return 1 ;;
        esac
    done

    # 4. tests: baseline-diff gate. Run the mirrored CI suite for each gated SUITE the branch
    #    touched, and fail only on NEW failures vs the recorded main baseline (testgate.jac).
    #    A fragment-only change gets no test gate — fmt/check/jir/contribution and pre-commit
    #    still gate it (see gated_suites_from_diff).
    #
    #    testgate.jac exit codes: 0 = no new failures, 1 = new failures, 2 = no baseline recorded
    #    (== no gate for this suite). This loop used to `if !` on the raw exit status, which cannot
    #    tell 1 and 2 apart -- confirmed live: a genuinely safe branch got rejected as "new test
    #    failures" when the real story was "this suite has no baseline, so it cannot be gated."
    #    That distinction is load-bearing; keep 2 handled separately from any other nonzero.
    #
    #    The suite list is materialized and its exit status checked, rather than iterated straight
    #    out of `for suite in $(gated_suites_from_diff)`. `set -e` does not fire on
    #    `for x in $(false)`, so a failing reader produced an empty list, iterated zero times, and
    #    skipped the ENTIRE test gate on the way to a green branch -- verified: a bad
    #    $NS_REPO_DEFAULT_BRANCH makes that function return 128 with no output. This is byte-for-byte
    #    the bug lib/cimirror.sh:105-108 already documents fixing one file over. An EMPTY list is
    #    still perfectly legal here (an mcp-only or fragment-only change gates no suite), so only a
    #    nonzero status is fatal.
    local suites suites_rc=0
    suites="$(gated_suites_from_diff)" || suites_rc=$?
    case "$suites_rc" in
        0) : ;;
        *) ns_die "$EX_BUG" "could not compute the gated suite list for $branch (rc=$suites_rc) -- an empty list is indistinguishable from 'no suite covers this change', so this must not fall through to a green branch." ;;
    esac

    # `gated` / `ungated` record what actually happened, so the line published to the PR body can
    # tell the truth instead of always claiming the tests passed (see the summary below).
    local suite raw rc srr gated="" ungated=""
    for suite in $suites; do
        raw="$LOG_DIR/tests-raw-$(basename "$branch")-$suite.txt"
        # A cimirror reader failure, or a suite that did not run, is a broken HARNESS rather than a
        # bad branch, and it is night-wide (the same malformed TOML or bad path fails identically
        # for every queued branch). Burning this branch's attempt counter over it would, after two
        # nights, auto-reject every finding in the ledger for a config typo. assert_suite_ran
        # aborts loudly instead: the EXIT trap still fires the autopsy email, nothing ships, and no
        # finding is blamed.
        srr=0; suite_test_raw "$suite" "$raw" || srr=$?
        assert_suite_ran "$suite" "$raw" "$srr" gate
        ns_jac testgate gate "$suite" "$raw" "$BASELINE_DIR"; rc=$?
        if [ "$rc" -eq 2 ]; then
            ns_log S4 "$suite: no test baseline recorded — no gate, skipping"
            ungated="$ungated $suite"
            continue
        fi
        if [ "$rc" -ne 0 ]; then
            # One retry: the target suite has documented flaky tests (ci.yml retries `-x || -x`).
            # Only a failure that reproduces on a second run counts. Note the union-of-two-runs
            # baseline (testgate.jac record-union) now absorbs most of what this retry existed to
            # paper over; the retry stays as the second line of defence.
            # ponytail: two *different* flakes across the two runs could still red; acceptable —
            #           the branch just gets re-attempted next night. Tighten to id-intersection if it bites.
            ns_log S4 "$suite: new failures on run 1 — retrying once (flaky-test guard)"
            srr=0; suite_test_raw "$suite" "$raw" || srr=$?
            assert_suite_ran "$suite" "$raw" "$srr" "gate retry"
            ns_jac testgate gate "$suite" "$raw" "$BASELINE_DIR"; rc=$?
            if [ "$rc" -eq 2 ]; then
                ns_log S4 "$suite: no test baseline recorded on retry — no gate, skipping"
                ungated="$ungated $suite"
                continue
            fi
            if [ "$rc" -ne 0 ]; then
                verify_red "$branch" "$suite: new test failures vs baseline (2 runs; see $(basename "$raw"))" "$on_red"
                return 1
            fi
        fi
        # "Nothing NEW failed" is only meaningful if the run reached as much of the suite as the
        # baseline did. assert_suite_ran proves the runner STARTED; this proves it did not die
        # partway, and catches any future recurrence of the byllm dependency hole (219 -> 105
        # collected, every unreached test scoring as "not failing"). Unlike a reader failure this
        # IS branch-attributable -- a broken import in a changed file drops its whole test module
        # out of collection -- so it reds the branch rather than aborting the night.
        ns_jac testgate collection-check "$suite" "$raw" "$BASELINE_DIR"; rc=$?
        # rc=2 means the baseline carries no usable collected count, so the floor cannot be
        # enforced for this suite. assert_suite_ran now refuses to WRITE such a baseline, so this
        # should only ever be a pre-`collected` legacy file -- but say so out loud rather than
        # letting a silently-unenforced backstop look identical to a passing one.
        case "$rc" in
            2) ns_warn "$suite: baseline records no collected count — the collection floor is NOT enforced for this suite; re-run nightshift.sh baseline" ;;
        esac
        if [ "$rc" -eq 1 ]; then
            # Same single retry the failure gate gets: collection can dip on a genuinely flaky
            # run (a worker dying takes its share of the items with it), and burning the branch's
            # attempt counter on one bad sample would be the same over-reaction the flake guard
            # exists to prevent.
            ns_log S4 "$suite: under-collected on run 1 — retrying once (flaky-collection guard)"
            srr=0; suite_test_raw "$suite" "$raw" || srr=$?
            assert_suite_ran "$suite" "$raw" "$srr" "collection retry"
            ns_jac testgate collection-check "$suite" "$raw" "$BASELINE_DIR"; rc=$?
            if [ "$rc" -eq 1 ]; then
                verify_red "$branch" "$suite: collected far fewer tests than the baseline on 2 runs — the suite did not run to completion, so its unreached tests cannot be read as passing (check the branch for an import error, or the environment for missing suite dependencies; see $(basename "$raw"))" "$on_red"
                return 1
            fi
        fi
        gated="$gated $suite"
    done

    # 5. pre-commit (standalone contributor tool from PATH, installed via pipx at M0 — NOT a git
    #    hook, so orchestrator commits stay unhooked). Hooks may self-mutate; fold in, demand clean.
    #
    #    KEPT, deliberately, even though this task replaced the rest of the hand-rolled gate with
    #    mirrored ci.yml jobs. pre-commit is NOT part of [jobs.contribution] — Task 5 removed it
    #    from there after reading work/repo/.pre-commit-config.yaml's own header ("Manifest for
    #    pre-commit.ci only ... Contributors do not install pre-commit locally"). But pre-commit.ci
    #    is a real third-party check that runs on the PR, fork or not, and its two hooks are
    #    markdownlint-cli2 and a pygrep ban on em-dashes in markdown. Nightshift writes markdown
    #    release-note fragments with an LLM, which is about the most reliable em-dash source there
    #    is, so dropping this stage would trade a local seconds-long gate for a red check on an
    #    upstream PR a human has to look at. It is not a ci.yml job, so it is not in the mirror; it
    #    stays here as its own stage.
    if ! ns_precommit run --all-files; then
        git add -A
        git diff --cached --quiet || git commit -m "style: pre-commit autofix (nightshift)"
        if ! ns_precommit run --all-files; then
            verify_red "$branch" "pre-commit red" "$on_red"
            return 1
        fi
    fi

    # 6. contribution-checks (ci.yml:449-512), the LAST gate: AI co-author attribution, no new
    #    Python files, bun/zig BUN_VERSION lockstep, docs-corpus validation, release-note fragment.
    #    The first of those is the one most likely to bite this harness specifically — Nightshift IS
    #    an AI agent producing commits.
    #
    #    Last on purpose. It is not a pre-filter for the suites (nothing downstream of it is
    #    expensive), and two of its five commands read the branch's FINAL commit set — the
    #    AI-co-author `git log $NS_REPO_DEFAULT_BRANCH..HEAD` range and the fragment check's
    #    `git diff --name-only "$NS_REPO_DEFAULT_BRANCH...HEAD"` — which the pre-commit autofix fold
    #    directly above can still add a commit to. Running it earlier would judge a tree that is not
    #    the one being shipped.
    #
    #    No self-mutation fold here (the brief's sketch had one, copied from the pre-commit block it
    #    was replacing): none of [jobs.contribution]'s five commands writes to the tree, so a second
    #    pass could only ever reproduce the first pass's verdict.
    #
    #    rc=70 here is handled exactly like the fast three, and for the same reason. TWO things
    #    return it, both harness/repo-state faults rather than branch faults: cimirror_job's own
    #    EX_MIRROR_READ (unreadable or renamed [jobs.contribution]), and the AI-co-author and
    #    added-.py commands' own `exit 70` when their git range cannot be computed at all (bad or
    #    unset $NS_REPO_DEFAULT_BRANCH, detached HEAD, no shared history). Both fail identically for
    #    every queued branch, so reding would burn every finding's attempt counter and auto-reject
    #    the whole ledger after two nights over one config or checkout problem.
    #    (This block used to assert that no command in [jobs.contribution] exits 70 of its own
    #    accord. That stopped being true when those two commands gained explicit merge-range guards
    #    — see config/ci-mirror.toml's note — and the ambiguity is harmless because the correct
    #    response to either cause is identical.)
    #
    #    KNOWN EXPOSURE, recorded rather than fixed (code review 2026-07-30, Minor). Three of the
    #    five commands are branch-scoped (the AI-co-author log range, the added-.py diff, the
    #    fragment check) but TWO validate WHOLE-REPO state regardless of the diff:
    #      `jac run scripts/validate_docs_code.jac`  — parses every Jac block in the docs corpus
    #                                                  (852 blocks today), branch-touched or not
    #      the bun_installer.jac / payload.zig BUN_VERSION lockstep — two fixed files
    #    So an UPSTREAM-introduced breakage in either reds every queued branch identically, bumps
    #    every finding's attempts, and auto-rejects the whole ledger after two such nights — the
    #    same harm the rc=70 handling above exists to prevent, reached by a different door. Both are
    #    green on main today (measured 2026-07-30, whole job 21s). NOT auto-escalated to ns_die: a
    #    branch CAN legitimately break either (editing a docs markdown block, or bumping BUN_VERSION
    #    on one side only), and aborting the night would ungate every branch behind this one — the
    #    disproportionate direction. Instead the failing command is matched and an ns_warn is raised,
    #    which lands in warnings.txt and therefore in the digest, so the operator sees the pattern
    #    before the second night rejects the ledger. If this ever bites for real, the precise fix is
    #    to re-run just the offending command against main content and only red the branch when main
    #    is clean.
    local cj cj_rc=0
    cj="$LOG_DIR/mirror-contribution-$(basename "$branch").txt"
    : > "$cj"
    cimirror_job contribution "$cj" || cj_rc=$?
    case "$cj_rc" in
        0) : ;;
        "$EX_MIRROR_READ")
            ns_die "$EX_BUG" "CI mirror job 'contribution' returned $EX_MIRROR_READ: either config/ci-mirror.toml could not be read, or one of its git-range guards could not compute a range against '$NS_REPO_DEFAULT_BRANCH'. Both are harness faults, identical for every queued branch, so $branch is not being blamed for it (see $(basename "$cj"))." ;;
        *)  case "$CIMIRROR_FAILED_CMD" in
                *validate_docs_code*|*BUN_VERSION*)
                    ns_warn "$(basename "$branch"): the contribution job failed on a WHOLE-REPO check, not a branch-scoped one ($CIMIRROR_FAILED_CMD). If every branch reds here tonight the cause is upstream, not the branches — verify it against main before letting a second night auto-reject their findings." ;;
            esac
            verify_red "$branch" "CI mirror job 'contribution' red (see $(basename "$cj"))" "$on_red"
            return 1 ;;
    esac

    # record the tests line for the draft, and self-tune the verify estimate (TPRD S3-B step 5)
    t1="$(date +%s)"
    local dur_min=$(( (t1 - t0) / 60 )); [ "$dur_min" -lt 1 ] && dur_min=1
    local old_est; old_est="$(ns_jac ledger state-get verify_estimate_min "$STATE" | tr -d '"')"
    ns_jac ledger state-set verify_estimate_min $(( ( ${old_est:-30} + dur_min ) / 2 )) "$STATE"

    # This line goes STRAIGHT INTO THE PR BODY a human reviews (lib/ship.sh:35), so it has to be
    # true. It used to be the hardcoded string "jac check ✓ · tests (no new failures vs baseline) ✓",
    # which claimed a passing test gate for a fragment-only change that gates no suite, for any suite
    # with no baseline recorded, and — since state/test-baseline/ is currently empty — for every
    # branch until `nightshift.sh baseline` has run. Telling an upstream reviewer the tests passed
    # when nothing ran is the one failure in this file that escapes the repo.
    #
    # `mirror fmt+check+jir ✓` USED TO BE A FLAT LITERAL HERE, and it was the sixth instance of this
    # plan's dominant defect in the one line that escapes the repo (code review, Important). Two of
    # those three jobs have a legitimate skip path — [jobs.fmt] prints "No formattable .jac files
    # changed; skipping format check." and [jobs.check] prints "No .jac files changed; skipping jac
    # check.", both EXIT 0 — which this very file already says out loud at assert_suite_ran's header
    # ("unlike [jobs.fmt]/[jobs.check], which legitimately skip when nothing changed") and which
    # config/ci-mirror.toml documents at [jobs.fmt]. Reproduced on a fragment-only branch: all three
    # rc=0, two of them having checked nothing, and the PR body claimed all three passed.
    #
    # Keyed off THE CAPTURE, not off $changed_jac: [jobs.fmt] additionally drops /fixtures/,
    # ^scripts/, /passes/native/llvm/ and _err.jac$ paths, so a branch touching only those has a
    # NON-empty $changed_jac and still skips. Only the job's own printed skip line knows what it did.
    # [jobs.jir] has no skip path — one unconditional `jac gen-jir-registry --verify` — so it always
    # ran by the time control reaches here. bin/test-harness.sh section 9 pins both literals against
    # config/ci-mirror.toml so a wording change upstream cannot silently turn a skip back into a ✓.
    local mirror_ran="" mirror_skipped="" mj
    for mj in fmt check; do
        if mirror_job_skipped "$mj" "$mrr"; then
            mirror_skipped="$mirror_skipped $mj"
        else
            mirror_ran="$mirror_ran $mj"
        fi
    done
    mirror_ran="$mirror_ran jir"
    local mirror_line="mirror (${mirror_ran# }) ✓"
    case "$mirror_skipped" in
        "") : ;;
        *)  mirror_line="$mirror_line · mirror not applicable:${mirror_skipped} (no .jac files to check)" ;;
    esac

    local check_line="jac check ✓" tests_line
    case "$changed_jac" in "") check_line="jac check (no .jac files changed)" ;; esac
    case "$suites" in
        "") tests_line="tests (no suite covers this change)" ;;
        *)  case "$gated" in
                "") tests_line="tests (no baseline for${ungated} — not gated)" ;;
                *)  tests_line="tests (no new failures vs baseline:${gated}) ✓"
                    case "$ungated" in
                        "") : ;;
                        *) tests_line="$tests_line · not gated (no baseline):${ungated}" ;;
                    esac ;;
            esac ;;
    esac
    # `contribution ✓` stays a flat literal, and that one IS honest: all five of its commands are
    # unconditional (none prints a skip), and the stage `return 1`s above on anything but rc=0.
    echo "$mirror_line · $check_line · $tests_line · pre-commit ✓ · contribution ✓ (${dur_min} min)" \
        > "$LOG_DIR/tests-$(basename "$branch").txt"
    git checkout "$NS_REPO_DEFAULT_BRANCH"
    return 0
}

verify_red() {
    local branch=$1 why=$2 on_red="${3:-demote}" fp why_sane
    ns_fail "$branch" "$why"
    case "$on_red" in
        report)
            # S1.6's re-gate of an already-open PR. No ledger write (attempts must not move -- an
            # upstream-introduced red would otherwise auto-reject every finding in the ledger after
            # two nights) and no branch delete (the branch is an open PR's head upstream; deleting
            # it locally is pointless and deleting it at all would orphan the PR).
            ns_log S1.6 "$branch: gate red, reported only — no attempt counter moved, branch kept"
            return 0 ;;
    esac
    # reason goes into a JSON literal: strip the two characters that could break it
    why_sane="$(printf '%s' "$why" | tr -d '"\\')"
    # findings on this branch become failed_verify (attempts++; auto-rejected after 2, TPRD S3-B)
    ns_jac ledger by-branch "$branch" "$LEDGER" | while IFS= read -r fp; do
        ns_jac ledger set-status "$fp" failed_verify "$LEDGER" "{\"reason\":\"$why_sane\"}" >/dev/null
    done
    git checkout "$NS_REPO_DEFAULT_BRANCH"
    git branch -D "$branch" || true
}
