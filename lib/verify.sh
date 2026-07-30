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
        "$EX_MIRROR_READ") return "$EX_MIRROR_READ" ;;
    esac
    return 0
}

# Map changed paths to the mirrored TEST suites that cover them, and emit the unique set.
# Post-restructure geography: byllm and scale live under jac/jaclang/, and jac-mcp has no suite of
# its own (a recorded baseline confirmed "no tests ran"), so an mcp-only change gets no test gate --
# the fmt, check, jir and contribution jobs still gate it. A release-note-fragment-only change
# likewise gets no test gate.
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
            jac-mcp/*)              ;;                 # no suite of its own
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
    local suite=$1 raw=$2 rc=$3 where=$4 sessions want
    case "$rc" in
        0) : ;;
        *) ns_die "$EX_BUG" "$where $suite: cimirror could not read [jobs.$suite] from config/ci-mirror.toml (rc=$rc) -- the gate is broken, not the branch." ;;
    esac
    sessions="$(ns_jac testgate sessions "$raw")"
    want="$(ns_jac cimirror testcmds "$suite" "$CI_MIRROR_CONFIG")"
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
    local suite raw1 raw2 n rc
    for suite in compiler runtime byllm; do
        raw1="$LOG_DIR/baseline-raw-$suite-1.txt"
        raw2="$LOG_DIR/baseline-raw-$suite-2.txt"
        ns_log BASELINE "recording $suite, run 1 of 2 (slow)..."
        rc=0; suite_test_raw "$suite" "$raw1" || rc=$?
        assert_suite_ran "$suite" "$raw1" "$rc" baseline
        ns_log BASELINE "recording $suite, run 2 of 2 (slow)..."
        rc=0; suite_test_raw "$suite" "$raw2" || rc=$?
        assert_suite_ran "$suite" "$raw2" "$rc" baseline
        n="$(ns_jac testgate record-union "$suite" "$raw1" "$raw2" "$BASELINE_DIR")"
        ns_log BASELINE "$suite: $n known-failing tests recorded (union of 2 runs), $(ns_jac testgate collected "$raw1") tests collected"
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

# Gate order: scope containment → jac check (changed files) → baseline-diff test gate → pre-commit.
verify_branch() {
    local branch=$1 theme=$2 t0 t1
    t0="$(date +%s)"
    cd "$REPO"
    git checkout "$branch"
    rm -rf "$REPO/.jac"        # `jac clean --cache` prompts [y/N] non-interactively -> aborts; nuke directly

    # 1. scope containment FIRST — reject before spending a second on tests (anti-injection, T1).
    # --name-status (not --name-only): a vestigial test deletion must be a clean delete, never a
    # modification -- the gate needs to see which each changed path actually is.
    if [ "$theme" != "-" ]; then
        if ! git diff --name-status "$NS_REPO_DEFAULT_BRANCH...HEAD" \
                | ns_jac check_scope check "$theme" "$CONFIG" > "$LOG_DIR/scope-violations.txt"; then
            verify_red "$branch" "scope violation (possible prompt injection): $(head -3 "$LOG_DIR/scope-violations.txt" | tr '\n' ' ')"
            return 1
        fi
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
            # shellcheck disable=SC2086
            git -C "$REPO" checkout "$NS_REPO_DEFAULT_BRANCH" -- $main_jac
            rm -rf "$REPO/.jac"
            # shellcheck disable=SC2086
            ( cd "$REPO" && "$NS_PATHS_JAC_REPO" check $main_jac ) > "$mr" 2>&1 || true
            # shellcheck disable=SC2086
            git -C "$REPO" checkout HEAD -- $main_jac        # back to branch content
        else
            : > "$mr"
        fi
        if ! ns_jac checkgate gate "$mr" "$br"; then
            verify_red "$branch" "jac check: new type errors vs main (see $(basename "$br"))"
            return 1
        fi
    fi

    # 3. tests: baseline-diff gate. Run the mirrored CI suite for each gated SUITE the branch
    #    touched, and fail only on NEW failures vs the recorded main baseline (testgate.jac).
    #    jac-mcp-only and fragment-only changes get no test gate — fmt/check/jir/contribution and
    #    pre-commit still gate them (see gated_suites_from_diff).
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
                verify_red "$branch" "$suite: new test failures vs baseline (2 runs; see $(basename "$raw"))"
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
        if [ "$rc" -eq 1 ]; then
            verify_red "$branch" "$suite: collected far fewer tests than the baseline — the suite did not run to completion, so its unreached tests cannot be read as passing (check the branch for an import error, or the environment for missing suite dependencies; see $(basename "$raw"))"
            return 1
        fi
        gated="$gated $suite"
    done

    # 4. pre-commit (standalone contributor tool from PATH, installed via pipx at M0 — NOT a git
    #    hook, so orchestrator commits stay unhooked). Hooks may self-mutate; fold in, demand clean.
    if ! ns_precommit run --all-files; then
        git add -A
        git diff --cached --quiet || git commit -m "style: pre-commit autofix (nightshift)"
        if ! ns_precommit run --all-files; then
            verify_red "$branch" "pre-commit red"
            return 1
        fi
    fi

    # record the tests line for the draft, and self-tune the verify estimate (TPRD S3-B step 5)
    t1="$(date +%s)"
    local dur_min=$(( (t1 - t0) / 60 )); [ "$dur_min" -lt 1 ] && dur_min=1
    local old_est; old_est="$(ns_jac ledger state-get verify_estimate_min "$STATE" | tr -d '"')"
    ns_jac ledger state-set verify_estimate_min $(( ( ${old_est:-30} + dur_min ) / 2 )) "$STATE"

    # This line goes STRAIGHT INTO THE PR BODY a human reviews (lib/ship.sh:35), so it has to be
    # true. It used to be the hardcoded string "jac check ✓ · tests (no new failures vs baseline) ✓",
    # which claimed a passing test gate for a jac-mcp-only change that gates no suite, for any suite
    # with no baseline recorded, and — since state/test-baseline/ is currently empty — for every
    # branch until `nightshift.sh baseline` has run. Telling an upstream reviewer the tests passed
    # when nothing ran is the one failure in this file that escapes the repo.
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
    echo "$check_line · $tests_line · pre-commit ✓ (${dur_min} min)" \
        > "$LOG_DIR/tests-$(basename "$branch").txt"
    git checkout "$NS_REPO_DEFAULT_BRANCH"
    return 0
}

verify_red() {
    local branch=$1 why=$2 fp why_sane
    ns_fail "$branch" "$why"
    # reason goes into a JSON literal: strip the two characters that could break it
    why_sane="$(printf '%s' "$why" | tr -d '"\\')"
    # findings on this branch become failed_verify (attempts++; auto-rejected after 2, TPRD S3-B)
    ns_jac ledger by-branch "$branch" "$LEDGER" | while IFS= read -r fp; do
        ns_jac ledger set-status "$fp" failed_verify "$LEDGER" "{\"reason\":\"$why_sane\"}" >/dev/null
    done
    git checkout "$NS_REPO_DEFAULT_BRANCH"
    git branch -D "$branch" || true
}
