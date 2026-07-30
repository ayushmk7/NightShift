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

# Refuse to write a baseline from a run that never actually EXECUTED.
#
# This is the most dangerous failure mode in the whole gate, and it was LIVE: `failing_ids` cannot
# tell "the suite ran and nothing failed" from "the suite never started" -- both parse to zero ids.
# Confirmed 2026-07-30: [jobs.compiler]/[jobs.runtime] carried ci.yml's `working-directory: jac`
# relative paths but cimirror_job runs from the repo ROOT, so all three commands died instantly on
# `File not found: 'tests/compiler'`. A baseline recorded from that capture would have said
# count:0 for 4644 real tests, and every subsequent branch would have "passed" a gate running
# nothing. testgate.jac's `sessions` verb is the signal that separates the two cases.
baseline_assert_ran() {
    local suite=$1 raw=$2 rc=$3 sessions want
    case "$rc" in
        0) : ;;
        *) ns_die "$EX_BUG" "baseline $suite: cimirror could not read [jobs.$suite] from config/ci-mirror.toml (rc=$rc). Refusing to record a baseline from an empty capture." ;;
    esac
    sessions="$(ns_jac testgate sessions "$raw")"
    case "$sessions" in
        0) ns_die "$EX_BUG" "baseline $suite: the test runner never started (0 sessions in $(basename "$raw")). Refusing to record a baseline of 0 known failures -- that makes the gate vacuously green. Check [jobs.$suite]'s command paths and cwd in config/ci-mirror.toml." ;;
    esac
    # Per-command accounting: [jobs.compiler] has TWO commands, and one of them silently not
    # running is exactly the half-broken state the check above would still wave through.
    # `|| want=""` because `grep -c` exits 1 on a zero count, which pipefail would turn into an
    # errexit abort of this whole function; an unreadable count degrades to "skip the warning".
    want="$(cimirror_cmds "$suite" | grep -c . | tr -d ' ')" || want=""
    case "$want" in
        ''|"$sessions") : ;;
        *) ns_warn "baseline $suite: $sessions runner sessions but [jobs.$suite] declares $want commands -- one may not have run (see $(basename "$raw"))" ;;
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
        baseline_assert_ran "$suite" "$raw1" "$rc"
        ns_log BASELINE "recording $suite, run 2 of 2 (slow)..."
        rc=0; suite_test_raw "$suite" "$raw2" || rc=$?
        baseline_assert_ran "$suite" "$raw2" "$rc"
        n="$(ns_jac testgate record-union "$suite" "$raw1" "$raw2" "$BASELINE_DIR")"
        ns_log BASELINE "$suite: $n known-failing tests recorded (union of 2 runs)"
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
    local changed_jac main_jac f br mr
    changed_jac="$(git -C "$REPO" diff --name-only "$NS_REPO_DEFAULT_BRANCH...HEAD" | grep '\.jac$' || true)"
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
    local suite raw rc srr
    for suite in $(gated_suites_from_diff); do
        raw="$LOG_DIR/tests-raw-$(basename "$branch")-$suite.txt"
        # A cimirror reader failure is a broken HARNESS, not a bad branch, and it is night-wide
        # (the same malformed TOML fails identically for every queued branch). Burning this
        # branch's attempt counter over it would, after two nights, auto-reject every finding in
        # the ledger for a config typo. Abort loudly instead: the EXIT trap still fires the autopsy
        # email, nothing is shipped, and no finding is blamed.
        srr=0; suite_test_raw "$suite" "$raw" || srr=$?
        case "$srr" in
            0) : ;;
            *) ns_die "$EX_BUG" "$suite: cimirror could not read [jobs.$suite] from config/ci-mirror.toml (rc=$srr) -- the gate is broken, not the branch. Aborting instead of mis-reading an empty capture as a clean suite." ;;
        esac
        ns_jac testgate gate "$suite" "$raw" "$BASELINE_DIR"; rc=$?
        if [ "$rc" -eq 2 ]; then
            ns_log S4 "$suite: no test baseline recorded — no gate, skipping"
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
            case "$srr" in
                0) : ;;
                *) ns_die "$EX_BUG" "$suite: cimirror could not read [jobs.$suite] on retry (rc=$srr) -- the gate is broken, not the branch." ;;
            esac
            ns_jac testgate gate "$suite" "$raw" "$BASELINE_DIR"; rc=$?
            if [ "$rc" -eq 2 ]; then
                ns_log S4 "$suite: no test baseline recorded on retry — no gate, skipping"
                continue
            fi
            if [ "$rc" -ne 0 ]; then
                verify_red "$branch" "$suite: new test failures vs baseline (2 runs; see $(basename "$raw"))"
                return 1
            fi
        fi
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
    echo "jac check ✓ · tests (no new failures vs baseline) ✓ · pre-commit ✓ (${dur_min} min)" \
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
