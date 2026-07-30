#!/usr/bin/env bash
# bin/test-harness.sh — CI-of-the-harness (TechnicalPRD 14). Run after any harness change.
set -euo pipefail
NS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$NS_ROOT"
fail() { echo "FAIL: $1" >&2; exit 1; }

echo "== 1. jac helpers: check + test sweep =="
rm -rf .jac
for f in scripts/*.jac; do
    jac check "$f" >/dev/null 2>&1 || fail "jac check $f"
done
# DERIVED from scripts/*.jac, never hand-listed. The old hand-maintained list was the project's own
# "did not run scored as passed" defect wearing a different hat: a new helper got `jac check`ed by
# the loop above, was simply absent from the list below, and its `test` blocks never ran -- with the
# harness still printing ALL TESTS PASSED. Four new helpers arrive across Plans 2-5.
#
# `Ran 0 tests` is a FAILURE here, not a pass. `jac test` on a file with no test blocks prints
# "NO TESTS RAN" and exits 0 (measured), so trusting its exit code alone would re-open the same hole
# from the other side: a helper whose tests were deleted, or never written, would sail through.
# This project's rule is that non-trivial logic leaves one runnable check behind; this enforces it.
for f in scripts/*.jac; do
    out="$(jac test "$f" 2>&1)" || fail "jac test $f"
    case "$out" in
        *"NO TESTS RAN"*|*"Ran 0 tests"*)
            fail "$f has no test blocks -- every scripts/*.jac must leave at least one runnable check behind (jac test exits 0 on an empty file, so this is checked on the output, not the status)" ;;
    esac
done
rm -rf .jac

echo "== 2. bash: syntax sweep =="
for f in bin/*.sh lib/*.sh; do bash -n "$f" || fail "bash -n $f"; done

echo "== 3. golden-audit replay: selector must be deterministic =="
T="$(mktemp -d)"
jac run scripts/parse_result.jac findings < fixtures/golden-audit.json > "$T/f.json" \
    || fail "golden audit no longer parses"
[ "$(jac run scripts/parse_result.jac len < "$T/f.json")" = "1" ] || fail "parse_result len miscounts golden findings"
jac run scripts/selector.jac select config/nightshift.toml /nonexistent /nonexistent 999 /nonexistent-repo \
    < "$T/f.json" > "$T/s1.json"
jac run scripts/selector.jac select config/nightshift.toml /nonexistent /nonexistent 999 /nonexistent-repo \
    < "$T/f.json" > "$T/s2.json"
cmp -s "$T/s1.json" "$T/s2.json" || fail "selector output not deterministic"

echo "== 3b. findings merge: dedupe on (file, rule), stable order =="
cp "$T/f.json" "$T/f2.json"
jac run scripts/parse_result.jac merge "$T/f.json" "$T/f2.json" > "$T/m.json"
[ "$(jac run scripts/parse_result.jac len < "$T/m.json")" = "1" ] \
    || fail "merge failed to dedupe an identical findings array"

echo "== 4. scope gate: protected diff must be rejected =="
# no "package" key: check_scope.jac has not read one since the audit went whole-repo/sharded
# (violations() reads only files / fragment_kind / vestigial_deletions), and a dead key in a
# fixture reads as a requirement the code no longer has.
printf '{"files":["pkg/tests/fixtures/weird.jac"]}' > "$T/theme.json"
if printf 'M\tpkg/tests/fixtures/weird.jac\n' \
    | jac run scripts/check_scope.jac check "$T/theme.json" config/nightshift.toml >/dev/null; then
    fail "scope gate let a protected path through"
fi

echo "== 5. ci.yml drift tripwire =="
CI_YML="$NS_ROOT/work/repo/.github/workflows/ci.yml"
if [ -f "$CI_YML" ]; then
    want="$(sed -n 's/^sha256 *= *"\(.*\)"/\1/p' config/ci-mirror.toml | head -1)"
    have="$(shasum -a 256 "$CI_YML" | awk '{print $1}')"
    if [ "$want" != "$have" ]; then
        echo "FAIL: ci.yml changed upstream." >&2
        echo "  recorded: $want" >&2
        echo "  actual:   $have" >&2
        echo "  Re-read the ci.yml diff, re-sync config/ci-mirror.toml commands, then update" >&2
        echo "  the sha256. Do NOT just bump the hash." >&2
        exit 1
    fi
    echo "ci.yml matches the recorded hash"
else
    echo "SKIP: no work/repo clone present"
fi

echo "== 6. no mirror job may MUTATE the tree: every command verifies, none applies =="
# Tier-1 (and with it [jobs.fmt_autofix], the only apply entry) was retired 2026-07-30, so this file
# is now uniformly read-only. That is a property worth pinning: a gate that rewrites the branch it is
# judging would silently make its own verdict true. Every `jac fmt` in the registry must carry
# --check; `--lintfix` without --check is an apply step and must never reappear here.
rm -rf .jac
all_cmds="$(jac run scripts/cimirror.jac jobs config/ci-mirror.toml | while read -r j; do
    jac run scripts/cimirror.jac cmds "$j" config/ci-mirror.toml
done)"
rm -rf .jac
case "$all_cmds" in "") fail "could not read any mirror commands -- the checks below would be vacuous" ;; esac
printf '%s\n' "$all_cmds" | while IFS= read -r c; do
    case "$c" in
        *'jac fmt'*'--check'*) : ;;
        *'jac fmt'*) echo "MUTATING: $c" ;;
    esac
done | grep -q . && fail "a mirror job runs 'jac fmt' without --check -- the gate would rewrite the branch it is judging"
case "$all_cmds" in
    *'jac format'*) fail "mirror regressed to 'jac format' (removed by CLI cleanup #7255)" ;;
esac
case "$all_cmds" in
    *'jac lint --fix'*) fail "mirror regressed to 'jac lint --fix' (removed by CLI cleanup #7255)" ;;
esac
# `|| true`: an absent regex must reach the empty-string check as a clean FAIL, not kill this script
# via set -e + pipefail (grep's rc=1-on-no-match is the rightmost nonzero in the pipeline).
fmt_cmd="$(printf '%s\n' "$all_cmds" | grep -- '--check --lintfix' | head -1 || true)"
fmt_regex="$(printf '%s' "$fmt_cmd" | grep -oE -- '\(/fixtures/[^)]*\)' | head -1 || true)"
case "$fmt_regex" in "") fail "could not extract an exclusion regex from [jobs.fmt]" ;; esac
echo "every mirror job verifies, none applies; [jobs.fmt] keeps --check and its exclusion regex ($fmt_regex)"

echo "== 7. test-gate routing: case ORDER, and the two path classes that must gate nothing =="
# lib/*.sh gets `bash -n` only, so nothing else in this file executes gated_suites_from_diff --
# yet its own comment says "ORDER MATTERS ... do not alphabetize it", and this codebase has already
# shipped the exact mis-route it warns about (`cut -d/ -f1` sent jac/jaclang/byllm -> "jac" ->
# the large, env-flaky core suite). Drive the REAL function against a scratch repo; ~2s.
R="$T/routerepo"
mkdir -p "$R"
(
    cd "$R" && git init -q . && git config user.email t@t && git config user.name t \
      && echo x > README && git add -A && git commit -qm base && git branch -M main
) >/dev/null 2>&1 || fail "could not build the routing scratch repo"

# route_probe <branch> <path>... -> prints the suites, one per line. Every caller MUST capture the
# status separately from the output: `got="$(route_probe … | tr …)"` loses the return through the
# pipe, and the last assertion below EXPECTS the empty string -- so a scratch repo that failed to
# build would have made "mcp/fragment-only must gate nothing" pass vacuously. That is the same
# discarded-reader bug this file's section exists to guard against, inside the guard itself
# (code review 2026-07-30). Hence probe(): run, check, THEN compare.
route_probe() {
    local br=$1; shift
    (
        cd "$R" && git checkout -q main && git checkout -qb "$br" \
          && for p in "$@"; do mkdir -p "$(dirname "$p")"; echo c > "$p"; done \
          && git add -A && git commit -qm "$br"
    ) >/dev/null 2>&1 || return 1
    ( . "$NS_ROOT/lib/verify.sh"; REPO="$R"; NS_REPO_DEFAULT_BRANCH=main; gated_suites_from_diff )
}

probe() {              # probe <label> <branch> <path>... -> sets $got, fails loudly on any error
    local label=$1; shift
    local raw probe_rc=0
    raw="$(route_probe "$@")" || probe_rc=$?
    case "$probe_rc" in
        0) : ;;
        *) fail "routing probe '$label' could not run (rc=$probe_rc) -- the assertion below would have been vacuous" ;;
    esac
    got="$(printf '%s' "$raw" | tr '\n' ' ')"
}

# every routed class at once: compiler src, compiler tests, byllm, runtime, and the no-gate one
probe "all classes" all jac/jaclang/compiler/x.jac jac/tests/compiler/t.jac jac/jaclang/byllm/b.jac \
                        jac/jaclang/runtimelib/y.jac \
                        release_notes/unreleased/jaclang/1.refactor.md
case "$got" in
    "byllm compiler runtime") : ;;
    *) fail "routing drifted: expected 'byllm compiler runtime', got '$got'" ;;
esac

# THE load-bearing case: a byllm-only change must gate byllm and NOT fall through to jac/* -> runtime
probe "byllm-only" byllmonly jac/jaclang/byllm/only.jac
case "$got" in
    "byllm") : ;;
    *) fail "byllm-only change mis-routed to '$got' -- the jac/* catch-all is winning again" ;;
esac

# compiler tests must reach the suite that actually collects them, not runtime (which --ignores them)
probe "compiler-tests" comptests jac/tests/compiler/only.jac
case "$got" in
    "compiler") : ;;
    *) fail "jac/tests/compiler routed to '$got' -- runtime --ignores exactly those tests" ;;
esac

# a fragment-only change must gate NO suite at all. This is the assertion whose expected value IS
# the empty string, so probe()'s status check above is what keeps it honest.
# (The jac-mcp/ probe that used to share this case was dropped 2026-07-30 along with the shard
# registry entry and gated_suites_from_diff's arm: upstream deleted jac-mcp in 59f68a7a1, so no
# path the harness can produce starts with it.)
probe "fragment-only" nogate release_notes/unreleased/jaclang/2.docs.md
case "$got" in
    "") : ;;
    *) fail "a fragment-only change should gate no suite, got '$got'" ;;
esac
echo "routing correct: byllm-only stays byllm, compiler tests reach compiler, fragments gate nothing"

echo "== 8. S4 gate order: the cheap CI-mirror jobs must precede the expensive test suites =="
# Ordering is a CORRECTNESS property here, not style. Get it backwards and every doomed branch pays
# ~40min of test suites before a 0-second `jac fmt --check` rejects it -- silently expensive rather
# than visibly broken, so nothing else in this file would ever notice.
#
# Anchored on the real CALL SITES, not on the "# 3." / "# 4." step comments and not on a marker
# string planted for this test: a comment can be left behind when the code it labels moves, and a
# planted marker can be moved without moving the code. `cimirror_job "$fastjob"`,
# `for suite in $suites` and `cimirror_job contribution` ARE the stages, so they cannot drift from
# what they assert about.
#
# gate_line demands EXACTLY ONE match. A pattern that finds nothing must FAIL, not return the empty
# string -- otherwise a rename would leave this section comparing "" against "" and passing
# vacuously. This plan has already shipped one regression test with exactly that bug (section 7's
# route_probe, code review 2026-07-30), so gate_line's own failure mode is self-tested below before
# any real assertion uses it.
gate_line() {                 # gate_line <label> <ere> -> the single matching line number
    local label=$1 pat=$2 hits n
    hits="$(grep -nE -- "$pat" lib/verify.sh || true)"
    case "$hits" in
        "") fail "gate-order stage '$label' not found in lib/verify.sh (pattern: $pat) -- the ordering comparison would have been vacuous" ;;
    esac
    n="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
    case "$n" in
        1) : ;;
        *) fail "gate-order stage '$label' matched $n lines in lib/verify.sh; it must be unique or the ordering comparison is meaningless" ;;
    esac
    printf '%s\n' "$hits" | cut -d: -f1
}
# self-test: a stage that cannot exist must make gate_line exit nonzero, not print an empty string.
if selftest="$(gate_line self-test 'ZZ_THIS_MARKER_MUST_NOT_EXIST_ZZ' 2>/dev/null)"; then
    fail "gate_line succeeded for a stage that does not exist (printed '$selftest') -- section 8 cannot be trusted"
fi

fast_ln="$(gate_line "fast mirror jobs" 'cimirror_job "\$fastjob"')"
suite_ln="$(gate_line "test suites" 'for suite in \$suites')"
contrib_ln="$(gate_line "contribution job" 'cimirror_job contribution')"
for n in "$fast_ln" "$suite_ln" "$contrib_ln"; do
    case "$n" in
        ''|*[!0-9]*) fail "gate_line produced a non-numeric line number ('$n') -- refusing to compare it" ;;
    esac
done
[ "$fast_ln" -lt "$suite_ln" ] \
    || fail "the fast CI-mirror jobs (line $fast_ln) must run BEFORE the test suites (line $suite_ln)"
[ "$suite_ln" -lt "$contrib_ln" ] \
    || fail "the contribution job (line $contrib_ln) must run AFTER the test suites (line $suite_ln)"

# Ordering alone is not enough: emptying the fast job list would leave every assertion above green
# while removing the whole point of the stage. Pin its membership, and pin that no ~40min suite has
# been smuggled into the "fast" loop.
fast_list="$(grep -E '^[[:space:]]*for fastjob in ' lib/verify.sh || true)"
case "$fast_list" in
    "") fail "could not find the fast-job loop header in lib/verify.sh" ;;
esac
for j in fmt check jir; do
    case "$fast_list" in
        *" $j"*) : ;;
        *) fail "fast CI-mirror job '$j' is no longer in the pre-suite loop: $fast_list" ;;
    esac
done
for j in byllm compiler runtime; do
    case "$fast_list" in
        *" $j"*) fail "suite job '$j' was added to the 'fast' pre-suite loop; it takes tens of minutes: $fast_list" ;;
    esac
done
echo "gate order correct (fast mirror jobs $fast_ln < suites $suite_ln < contribution $contrib_ln)"

echo "== 9a. S7 theme resolution: a missing theme file is ALWAYS fatal, never 'no theme' =="
# lib/promote.sh used to do `[ -f "$LOG_DIR/theme-….json" ] && theme=…`, which under promote_main's
# live errexit (it is called bare from bin/nightshift.sh, and ns_run_inner's EXIT trap does not
# exist on that path) aborted `nightshift.sh promote` with a bare status 1 whenever the file was
# absent -- the normal case, since $LOG_DIR is date-keyed and a human promotes on a later day. The
# naive fix is worse than the bug: a theme of "-" makes verify_branch skip scope containment, so an
# aged-out theme would silently re-gate an LLM-written branch with the anti-injection check off.
# Since tier-1 was retired (2026-07-30) EVERY branch is agent-written, so absence is unambiguously
# fatal and no positive tier-1 recognition is needed any more.
case "$(grep -c '^[[:space:]]*\[ -f .*\] &&[[:space:]]*theme=' lib/promote.sh || true)" in
    0) : ;;
    *) fail "lib/promote.sh resolves the theme with a '[ -f … ] && theme=…' list again -- a false && list is a nonzero return, and promote_main runs with errexit live and no EXIT trap" ;;
esac
grep -q 'ns_die "\$EX_BUG" "no theme file for' lib/promote.sh \
    || fail "lib/promote.sh no longer dies on a missing theme file -- it would re-gate an agent-written branch without scope containment"
# The retirement must stay retired: a resurrected theme-less branch class would re-open the hole.
case "$(git ls-files lib/tier1.sh | wc -l | tr -d ' ')" in
    0) : ;;
    *) fail "lib/tier1.sh is back -- it queues a theme-less branch, so lib/promote.sh's unconditional ns_die would reject it; reinstate the positive tier-1 recognition if you revive the stage" ;;
esac
grep -q 'ns_is_tier1_branch\|NS_TIER1_SLUG' lib/promote.sh lib/common.sh 2>/dev/null \
    && fail "tier-1 recognition helpers are back without lib/tier1.sh -- dead code guarding a branch class that no longer exists"
echo "theme resolution explicit: absence is fatal for every branch, tier-1 stays retired"

echo "== 9b. mirror skip-detection must track the strings the mirror actually prints =="
# [jobs.fmt] and [jobs.check] both EXIT 0 after printing a skip line when the branch changed no
# (formattable) .jac file. lib/verify.sh keys the PR-body tests line off those two literals, so if
# config/ci-mirror.toml rewords them the gate would silently go back to publishing
# "mirror fmt+check+jir ✓" for jobs that checked nothing -- into a PR body a human reads.
rm -rf .jac
for pair in 'fmt|No formattable .jac files changed; skipping format check.|Formatting jac/jaclang/x.jac' \
            'check|No .jac files changed; skipping jac check.|=========== 1 passed in 0.52s ==========='; do
    mjob="$(printf '%s' "$pair" | cut -d'|' -f1)"
    printed="$(printf '%s' "$pair" | cut -d'|' -f2)"
    did_work="$(printf '%s' "$pair" | cut -d'|' -f3)"
    mcmd="$(jac run scripts/cimirror.jac cmds "$mjob" config/ci-mirror.toml | head -1)"
    case "$mcmd" in
        "") fail "could not read [jobs.$mjob]'s command -- the skip-string check would have been vacuous" ;;
        *"$printed"*) : ;;
        *) fail "[jobs.$mjob] no longer prints '$printed'; lib/verify.sh keys its honest tests line off that exact string" ;;
    esac
    # Behavioural, not a grep-for-a-grep: drive the REAL mirror_job_skipped against two synthetic
    # captures built the way lib/cimirror.sh actually writes one.
    #
    # Capture A is the trap this test exists for. cimirror_job echoes each command as `$ <cmd>`
    # BEFORE running it, and [jobs.fmt]/[jobs.check] carry their own skip sentence inside an `echo`
    # argument -- so the needle is in the capture even when the job did full work. The first version
    # of this feature used an unanchored grep and therefore reported EVERY branch as "skipped";
    # caught only by running it against a real capture. Anchoring is what makes it right, and this
    # is the assertion that keeps it that way.
    printf '\n$ %s\n%s\n' "$mcmd" "$did_work" > "$T/cap-ran-$mjob.txt"
    printf '\n$ %s\n%s\n' "$mcmd" "$printed"  > "$T/cap-skip-$mjob.txt"
    if ( . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/verify.sh"; mirror_job_skipped "$mjob" "$T/cap-ran-$mjob.txt" ); then
        fail "mirror_job_skipped calls [jobs.$mjob] SKIPPED on a capture where it did work -- it is matching the echoed command text, so every branch would under-report"
    fi
    ( . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/verify.sh"; mirror_job_skipped "$mjob" "$T/cap-skip-$mjob.txt" ) \
        || fail "mirror_job_skipped missed [jobs.$mjob]'s real skip line -- a job that checked nothing would be published as passed"
done
# An unrecognised job must be FATAL, never a silent answer. Checking only "nonzero" is not enough
# and was itself caught by mutation: a `*) return 1` arm is nonzero AND means "did not skip", so it
# would publish a brand-new conditionally-skipping job as having run. Demand the ns_die exit code.
mjs_rc=0
( . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/verify.sh"; mirror_job_skipped byllm /dev/null ) \
    >/dev/null 2>&1 || mjs_rc=$?
case "$mjs_rc" in
    70) : ;;
    *) fail "mirror_job_skipped answered rc=$mjs_rc for a job with no known skip line; it must ns_die (70) instead, or a future job with a skip path would silently be published as having run" ;;
esac
rm -rf .jac
# Comment lines stripped first: the block above this line in lib/verify.sh quotes the old literal
# while explaining why it was wrong, and matching that prose would fail the check forever.
case "$(grep -vE '^[[:space:]]*#' lib/verify.sh | grep -c 'mirror fmt+check+jir ✓' || true)" in
    0) : ;;
    *) fail "lib/verify.sh publishes the flat literal 'mirror fmt+check+jir ✓' again -- fmt and check legitimately skip, so it must name only the jobs that ran" ;;
esac
echo "skip strings in lockstep with config/ci-mirror.toml; no flat mirror ✓ literal"

echo "== 10. the did-not-run guards themselves: suite_test_raw / assert_suite_ran / assert_check_ran =="
# These three functions carry this whole plan's thesis -- "a stage that did not run must never
# score as passed" -- and until now NONE of them appeared anywhere in this file. They are correct
# today, but they are also exactly one character away from being useless: deleting the `|0` from
# either numeric guard (lib/verify.sh's `case "$want"` / `case "$collected"` / assert_check_ran's
# `case "$ran"`) or the `*"jac test"*) return 0` arm in suite_test_raw made the ENTIRE harness pass.
# mirror_job_skipped -- the sibling with the least consequence -- got a behavioural test in section
# 9b; these did not.
#
# Driven behaviourally against fixture captures under $T, never against work/repo: cimirror_job is
# STUBBED for the suite_test_raw cases (the thing under test is the classification of its rc, not
# the running of real commands), and assert_suite_ran/assert_check_ran only read a file plus
# config/ci-mirror.toml. Nothing here checks out a branch or runs a suite.
G="$T/guards"
mkdir -p "$G/logs"

# A healthy single-session capture, written the way lib/cimirror.sh actually appends one
# (`\n$ <cmd>` before the command's own output).
cat > "$G/healthy.txt" <<'EOF'

$ jac test jac/jaclang/byllm/tests
============================= test session starts ==============================
18 workers [219 items]
...............................................................................
========================= 219 passed in 30.11s =========================
EOF
# The runner STARTED (banner present) but collected nothing -- the exact shape of a collection
# error. `collected 0 items` is what makes this different from the healthy capture.
cat > "$G/collected0.txt" <<'EOF'

$ jac test jac/jaclang/byllm/tests
============================= test session starts ==============================
collected 0 items / 1 error
========================= 1 error in 0.30s =========================
EOF
# Items reported with NO session banner at all. Nonsense in practice, and that is the point: it is
# the only capture shape that reaches the `case "$want"` guard's `0` arm with everything else
# looking fine, so it is what keeps that arm honest (see the fmt case below).
cat > "$G/nosession.txt" <<'EOF'

$ jac fmt --check --lintfix
18 workers [219 items]
EOF
cat > "$G/check-ran.txt" <<'EOF'
✖ Error: error[E1053]: Cannot assign Any
  10 |     x = float(cfg.get('a', 1.0))
     |         ^^^^^^^^^^^^^^^^^^^^^^^
============================== 1 failed in 0.25s ===============================
EOF
# `jac check` never started: a missing/unexecutable binary exits 127 and prints no run summary.
printf '(eval): no such file or directory: /nonexistent/jac\n' > "$G/check-never.txt"

# guard_env runs one call against the REAL functions in a subshell, with $LOG_DIR redirected into
# the scratch dir so ns_log/ns_die cannot write into logs/<today>/.
guard_suite() {        # guard_suite <label> <want-rc> <suite> <capture> <rc-from-suite_test_raw>
    local label=$1 want=$2 suite=$3 cap=$4 srr=$5 got=0
    (
        . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/cimirror.sh"; . "$NS_ROOT/lib/verify.sh"
        LOG_DIR="$G/logs"; ns_bootstrap_jac
        rc=0; assert_suite_ran "$suite" "$cap" "$srr" harness-test || rc=$?; exit "$rc"
    ) >/dev/null 2>&1 || got=$?
    case "$got" in
        "$want") : ;;
        *) fail "assert_suite_ran '$label': expected rc=$want, got rc=$got" ;;
    esac
}
guard_check() {        # guard_check <label> <want-rc> <capture>
    local label=$1 want=$2 cap=$3 got=0
    (
        . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/cimirror.sh"; . "$NS_ROOT/lib/verify.sh"
        LOG_DIR="$G/logs"; ns_bootstrap_jac
        rc=0; assert_check_ran harness-branch "$cap" branch || rc=$?; exit "$rc"
    ) >/dev/null 2>&1 || got=$?
    case "$got" in
        "$want") : ;;
        *) fail "assert_check_ran '$label': expected rc=$want, got rc=$got" ;;
    esac
}
guard_raw() {          # guard_raw <label> <want-rc> <stub-rc> <stub-failed-cmd>
    local label=$1 want=$2 stub_rc=$3 stub_cmd=$4 got=0
    (
        . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/cimirror.sh"; . "$NS_ROOT/lib/verify.sh"
        LOG_DIR="$G/logs"; ns_bootstrap_jac
        # The unit under test is how suite_test_raw CLASSIFIES cimirror_job's outcome, so
        # cimirror_job itself is replaced. Nothing touches work/repo.
        cimirror_job() { CIMIRROR_FAILED_CMD="$stub_cmd"; return "$stub_rc"; }
        rc=0; suite_test_raw byllm "$G/raw-out.txt" || rc=$?; exit "$rc"
    ) >/dev/null 2>&1 || got=$?
    case "$got" in
        "$want") : ;;
        *) fail "suite_test_raw '$label': expected rc=$want, got rc=$got" ;;
    esac
}

# --- assert_suite_ran ---------------------------------------------------------------------------
# healthy: [jobs.byllm] declares 1 test command, the capture has 1 session and 219 items.
guard_suite "healthy byllm" 0 byllm "$G/healthy.txt" 0
# THE COLLECTED-0 CASE. Guards the `|0` in `case "$collected"`: a run that starts and collects
# nothing scores every unreached test as "not failing", and a baseline recorded from it disables
# the collection floor permanently. Delete that `|0` and this line goes green.
guard_suite "collected 0" 70 byllm "$G/collected0.txt" 0
# SESSION-COUNT MISMATCH. [jobs.compiler] declares TWO test commands (tests/compiler and the
# cross-backend equivalence suite), so a one-session capture means half of it never ran -- which is
# precisely how the equivalence suite could silently not run behind a plausible baseline.
guard_suite "session mismatch" 70 compiler "$G/healthy.txt" 0
# THE want=0 CASE. Guards the `|0` in `case "$want"`: [jobs.fmt] declares no test command at all,
# and a capture with zero sessions would MATCH that zero. Delete that `|0` and a job that cannot
# run a single test is accepted as a passing gate; this is the only fixture shape that reaches it.
guard_suite "job declares no test command" 70 fmt "$G/nosession.txt" 0
# every rc suite_test_raw can hand over is fatal here, and none may be read as "ran clean"
guard_suite "reader failure rc" 70 byllm "$G/healthy.txt" 70
guard_suite "setup failure rc"  70 byllm "$G/healthy.txt" 71
guard_suite "unexpected rc"     70 byllm "$G/healthy.txt" 99

# --- assert_check_ran ---------------------------------------------------------------------------
guard_check "checker ran" 0 "$G/check-ran.txt"
# Guards the `|0` in `case "$ran"`: both `jac check` calls in verify_branch end in `|| true`, so a
# missing $NS_PATHS_JAC_REPO yields an empty capture, checkgate finds no NEW identity, and the PR
# body says "jac check ✓".
guard_check "checker never ran" 70 "$G/check-never.txt"

# --- suite_test_raw -----------------------------------------------------------------------------
guard_raw "green job" 0 0 ""
# a TEST command failing is the NORMAL case (baseline failures live on main; testgate.jac decides
# on NEW failures only) -- deleting the `*"jac test"*) return 0` arm turns every red suite into a
# night-fatal EX_MIRROR_SETUP
guard_raw "test command failed"  0  1 "cd jac && JAC_TEST_JOBS=auto jac test tests/compiler"
# ...but a SETUP command failing is night-wide, not branch-attributable ([jobs.byllm] leads with
# ci.yml's `jac install --global`; without it byllm collects 105 instead of 219 on EVERY branch)
guard_raw "setup command failed" 71 1 'jac install "litellm>=1.70.0" --global'
# an empty CIMIRROR_FAILED_CMD next to a nonzero rc should be impossible -> fail closed, not guess
guard_raw "nonzero rc, no failed command" 71 1 ""
# a reader failure is propagated verbatim, never collapsed into "the suite ran"
guard_raw "reader failure" 70 70 ""
rm -rf .jac
echo "did-not-run guards behave: collected-0 and session-mismatch are fatal, a healthy capture is not"

# Sections 11-18 are RESERVED: docs/superpowers/plans/RECONCILIATION.md allocates 11-14 to Plan 2
# (task registry) and 15-18 to Plan 3 (ship path); all four v2 plans independently claimed "section
# 11". Plan 4 owns 19-23. The gap is deliberate — renumbering later would silently reorder the
# other two plans' tripwires into someone else's range.

echo "== 19. the digest's transport guards: receipt required, credentials scrubbed =="
# scripts/sendmail.jac's own tests cover the two pure functions (section 1 runs them). What is NOT
# covered there is that lib/email.sh actually CONSUMES the receipt rather than the exit code --
# the exact shape of the bug this task exists to remove. Driven, not grepped for.
rm -rf .jac
E="$T/email"; mkdir -p "$E"
# A stub `ns_jac sendmail send` that exits 0 and prints NOTHING is a send that did not happen.
(
    . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/email.sh"
    LOG_DIR="$E"; NS_DATE=2026-01-02; NS_EMAIL_TO=t@t; NS_EMAIL_SMTP_HOST=h
    ns_jac() { case "$2" in summarize) echo '{"date":"2026-01-02"}' ;; send) return 0 ;; esac; }
    osascript() { return 0; }
    email_main
) > /dev/null 2>&1
[ -f "$E/EMAIL_FAILED" ] \
    || fail "email_main reported success for a send that produced NO receipt -- 'exited 0' is not 'delivered'"
[ -f "$E/SMTP_RECEIPT" ] && fail "email_main recorded an SMTP_RECEIPT for a send that produced none"
rm -f "$E/EMAIL_FAILED"
# ...and a stub that prints a receipt must be believed, and must record it.
(
    . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/email.sh"
    LOG_DIR="$E"; NS_DATE=2026-01-02; NS_EMAIL_TO=t@t; NS_EMAIL_SMTP_HOST=h
    ns_jac() { case "$2" in summarize) echo '{"date":"2026-01-02"}' ;; send) echo "2.0.0 OK q1 - gsmtp" ;; esac; }
    email_main
) > /dev/null 2>&1
[ -f "$E/SMTP_RECEIPT" ] || fail "email_main did not record the server receipt it was handed"
grep -q "2.0.0 OK q1 - gsmtp" "$E/SMTP_RECEIPT" \
    || fail "SMTP_RECEIPT does not contain the receipt the server issued"
[ -f "$E/EMAIL_FAILED" ] && fail "email_main flagged a receipted send as failed"
echo "transport guards behave: no receipt means not delivered"

echo "== 20. same-night re-run must not report a STALE fatal stage =="
# ERROR_STAGE was cleared nowhere while FATAL_REASON was cleared in ns_run, so a green re-run
# after a red one mailed "ERROR S4" with no reason attached -- the digest's only outright lie.
# Driven against the REAL statement, extracted from bin/nightshift.sh, so moving or narrowing it
# fails here rather than passing a grep. `|| true` on the extraction because errexit+pipefail
# would otherwise abort the harness before the case arm below could name what went wrong.
clear_stmt="$(grep -E '^[[:space:]]*rm -f "\$LOG_DIR/FATAL_REASON"' bin/nightshift.sh | head -1 || true)"
case "$clear_stmt" in
    "") fail "bin/nightshift.sh no longer clears FATAL_REASON in ns_run -- section 20 would be vacuous" ;;
esac
S="$T/staleclear"; mkdir -p "$S"
( LOG_DIR="$S"; touch "$S/FATAL_REASON" "$S/ERROR_STAGE"; eval "$clear_stmt" )
[ -e "$S/FATAL_REASON" ] && fail "the extracted clear statement did not remove FATAL_REASON"
[ -e "$S/ERROR_STAGE" ] && fail "a same-night re-run leaves a STALE ERROR_STAGE; the digest would report a green run as failed"
# ...and the Plan 1 stopgap must be GONE, not kept alongside the first-class field: summarize()
# now reads FATAL_REASON itself, so a surviving fold would print the same reason twice.
grep -q 'FATAL (%s)' bin/nightshift.sh \
    && fail "ns_on_exit still folds FATAL_REASON into warnings.txt; the digest would report it twice"
echo "same-night re-run clears both fatal markers; the warnings.txt stopgap is gone"

echo "ALL HARNESS TESTS PASSED"
