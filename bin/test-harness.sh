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
jac run scripts/parse_result.jac findings dead-code loc_saved < fixtures/golden-audit.json > "$T/f.json" \
    || fail "golden audit no longer parses"
[ "$(jac run scripts/parse_result.jac len < "$T/f.json")" = "1" ] || fail "parse_result len miscounts golden findings"
# Positive assertions that the per-task stamping actually HAPPENED. An unstamped finding does not
# fail here today -- it blows up much later, in selector.jac's slugify, on a live night.
grep -q '"task": *"dead-code"' "$T/f.json" || fail "parse_result no longer stamps the task onto findings"
grep -q '"complexity"' "$T/f.json" || fail "parse_result no longer requires a complexity tag"
# `findings` with no task/scoring must FAIL, not fall back to a default schema. A default would
# silently gate every coverage night against the loc_saved shape and reject every finding.
if jac run scripts/parse_result.jac findings < fixtures/golden-audit.json >/dev/null 2>&1; then
    fail "parse_result findings accepted no task/scoring argv -- it must require both"
fi
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
# The 4th argv is the TASK (Plan 2 Task 6 / RECONCILIATION B8): dead-code has no protect_unless, so
# a protected path stays rejected. Section 12 drives the permission logic itself.
#
# The rejection is asserted as rc=1 PLUS the VIOLATION line, not as "nonzero". Measured while
# implementing Task 6: with the old 4-argv call left in place, this gate falls through to the usage
# arm and exits 2 -- which an `if <cmd>; then fail` reads as "correctly rejected", so the harness
# stayed green while every S4 invocation was unparsable. That is this project's signature defect
# (did-not-run scored as passed) sitting inside the test for it. B8 says updating this call keeps
# the harness from going red; it does not, and that is worse.
scope_rc=0
printf 'M\tpkg/tests/fixtures/weird.jac\n' \
    | jac run scripts/check_scope.jac check "$T/theme.json" config/nightshift.toml dead-code > "$T/scope4.out" \
    || scope_rc=$?
case "$scope_rc" in
    1) : ;;
    0) fail "scope gate let a protected path through" ;;
    *) fail "scope gate answered rc=$scope_rc for a protected path -- it did not run the check at all (argv drift?): $(tr '\n' ' ' < "$T/scope4.out")" ;;
esac
grep -q '^VIOLATION pkg/tests/fixtures/weird.jac protected-glob$' "$T/scope4.out" \
    || fail "scope gate rejected the protected path without saying why: $(tr '\n' ' ' < "$T/scope4.out")"
# A gate that cannot parse its own arguments must never be the reason a branch passes. lib/verify.sh
# reads `if ! … | ns_jac check_scope check …`, so an exit 0 from the usage arm reports the diff as
# CONTAINED. The arm exited 0 until this commit; Plan 2 Task 6 changes this verb's arity, which is
# exactly when that bites. rc=1 is also wrong here -- it is the "violations found" code, so the
# caller could not tell a rejected diff from an unparsable invocation.
scope_rc=0
jac run scripts/check_scope.jac check "$T/theme.json" >/dev/null 2>&1 || scope_rc=$?
case "$scope_rc" in
    0) fail "check_scope exited 0 for a malformed argv -- the S4 gate would report an unparsed diff as contained" ;;
    1) fail "check_scope answered rc=1 (its 'violations found' code) for a malformed argv; the caller cannot tell those apart" ;;
esac

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

echo "== 9a. S7 kill path: theme resolution, no duplicate PR, close before delete =="
# lib/promote.sh used to do `[ -f "$LOG_DIR/theme-….json" ] && theme=…`, which under promote_main's
# live errexit (it is called bare from bin/nightshift.sh, and ns_run_inner's EXIT trap does not
# exist on that path) aborted `nightshift.sh promote` with a bare status 1 whenever the file was
# absent -- the normal case, since $LOG_DIR is date-keyed and a human promotes on a later day. The
# naive fix is worse than the bug: a theme of "-" makes verify_branch skip scope containment, so an
# aged-out theme would silently re-gate an LLM-written branch with the anti-injection check off.
# Since tier-1 was retired (2026-07-30) EVERY branch is agent-written, so absence is unambiguously
# fatal and no positive tier-1 recognition is needed any more. The resolution now lives in
# ns_theme_for_branch (lib/common.sh) because S1.6 re-gates PRs from arbitrary earlier nights.
for tf in lib/promote.sh lib/common.sh; do
    case "$(grep -c '^[[:space:]]*\[ -f .*\] &&[[:space:]]*theme=' "$tf" || true)" in
        0) : ;;
        *) fail "$tf resolves the theme with a '[ -f … ] && theme=…' list again -- a false && list is a nonzero return, and promote_main runs with errexit live and no EXIT trap" ;;
    esac
done
grep -q 'ns_die "\$EX_BUG" "no theme file for' lib/common.sh \
    || fail "ns_theme_for_branch no longer dies on a missing theme file -- it would re-gate an agent-written branch without scope containment"
grep -q 'ns_theme_for_branch' lib/promote.sh \
    || fail "lib/promote.sh resolves the theme by hand again instead of through ns_theme_for_branch"
# The retirement must stay retired: a resurrected theme-less branch class would re-open the hole.
case "$(git ls-files lib/tier1.sh | wc -l | tr -d ' ')" in
    0) : ;;
    *) fail "lib/tier1.sh is back -- it queues a theme-less branch, so ns_theme_for_branch's unconditional ns_die would reject it; reinstate the positive tier-1 recognition if you revive the stage" ;;
esac
grep -q 'ns_is_tier1_branch\|NS_TIER1_SLUG' lib/promote.sh lib/common.sh 2>/dev/null \
    && fail "tier-1 recognition helpers are back without lib/tier1.sh -- dead code guarding a branch class that no longer exists"
# ...and behaviourally, in all three directions. The greps above cannot tell a resolver that reads
# the drafts branch from one that merely mentions it.
TH="$T/theme"; mkdir -p "$TH/logs" "$TH/drafts/themes"
theme_probe() {        # theme_probe <label> <want-rc> <branch> -> sets $theme_got
    local label=$1 want=$2 br=$3 got=0
    theme_got="$( . "$NS_ROOT/lib/common.sh" 2>/dev/null; LOG_DIR="$TH/logs"; DRAFTS="$TH/drafts"
                  ns_theme_for_branch "$br" 2>/dev/null )" || got=$?
    case "$got" in
        "$want") : ;;
        *) fail "ns_theme_for_branch '$label': expected rc=$want, got rc=$got" ;;
    esac
}
# neither place has it -> FATAL, never "-" (which makes verify_branch skip scope containment)
theme_probe "no theme anywhere" 70 nightshift/2026-07-01/dead-code-gone
case "$theme_got" in
    -|"-") fail "ns_theme_for_branch returned '-' for a branch with no theme; verify_branch would re-gate an LLM-written branch with the anti-injection check off" ;;
esac
# only on the drafts branch -> resolves. THE case S1.6 hits on every PR from an earlier night.
echo '{}' > "$TH/drafts/themes/dead-code-old.json"
theme_probe "drafts branch only" 0 nightshift/2026-07-01/dead-code-old
[ "$theme_got" = "$TH/drafts/themes/dead-code-old.json" ] \
    || fail "ns_theme_for_branch does not fall back to the drafts branch (got '$theme_got'); every S1.6 re-gate of an older PR would die"
# tonight's logs win over the drafts copy: the drafts copy is a snapshot, the logs one is current
echo '{}' > "$TH/logs/theme-dead-code-old.json"
theme_probe "logs beat drafts" 0 nightshift/2026-07-01/dead-code-old
[ "$theme_got" = "$TH/logs/theme-dead-code-old.json" ] \
    || fail "ns_theme_for_branch prefers the drafts snapshot over tonight's logs (got '$theme_got')"

# --- ns_pr_for_branch: a FAILED query must never read as "there is no PR" ------------------------
# This is the lookup both promote's duplicate refusal and discard's close-before-delete are built
# on, and an unchecked `gh pr list` prints nothing when the token expires -- indistinguishable from
# a clean "no PR exists", which is the answer that makes discard delete the branch and leave the PR
# dangling. Driven against a stub gh, three ways.
PB="$T/prfor"; mkdir -p "$PB"
printf '#!/bin/sh\nexit 4\n' > "$PB/gh-fails"; chmod +x "$PB/gh-fails"
printf '%s\n' '#!/bin/sh' 'cat <<JSON' \
  '[{"number": 812, "headRefName": "nightshift/2026-07-01/dead-code-x", "url": "u", "title": "t"}]' \
  'JSON' > "$PB/gh-ok"; chmod +x "$PB/gh-ok"
printf '%s\n' '#!/bin/sh' 'cat <<JSON' \
  '[{"number": 99, "headRefName": "someones-manual-branch", "url": "u", "title": "t"}]' \
  'JSON' > "$PB/gh-foreign"; chmod +x "$PB/gh-foreign"
pr_for() {             # pr_for <label> <want-rc> <stub> -> sets $pr_for_out
    local label=$1 want=$2 stub=$3 got=0
    pr_for_out="$( . "$NS_ROOT/lib/common.sh" 2>/dev/null; . "$NS_ROOT/lib/promote.sh"
                   LOG_DIR="$PB"; NS_PATHS_GH="$PB/$stub"; NS_REPO_UPSTREAM=o/r; ns_bootstrap_jac
                   ns_pr_for_branch nightshift/2026-07-01/dead-code-x 2>/dev/null )" || got=$?
    case "$got" in
        "$want") : ;;
        *) fail "ns_pr_for_branch '$label': expected rc=$want, got rc=$got (out '$pr_for_out')" ;;
    esac
}
pr_for "gh fails" 70 gh-fails
case "$pr_for_out" in
    "") : ;;
    *) fail "ns_pr_for_branch returned '$pr_for_out' for a FAILED gh call; it must die, not answer" ;;
esac
pr_for "gh answers" 0 gh-ok
[ "$pr_for_out" = "812" ] || fail "ns_pr_for_branch did not extract the PR number (got '$pr_for_out')"
# the nightshift/ prefix filter is a SAFETY invariant: everything downstream force-pushes what it
# is handed, and `--head` alone would match a PR opened by hand from an unrelated branch.
pr_for "foreign head" 0 gh-foreign
case "$pr_for_out" in
    "") : ;;
    *) fail "ns_pr_for_branch returned #$pr_for_out for a PR whose head is not under nightshift/" ;;
esac

# --- promote must refuse a branch that already has a PR -----------------------------------------
# S5 opens PRs now, so promote is only the manual fallback. A second PR for the same branch is
# noise upstream, and the ledger would record whichever URL was written last.
PM="$T/promote"; mkdir -p "$PM/drafts"
# A REAL draft, so find_draft succeeds and the run actually reaches sync_main. With no draft the
# "sync_main must not have run" assertion below is vacuous -- promote would die at the draft lookup
# either way, which is the shape of decorative assertion this project keeps shipping.
cat > "$PM/report.json" <<'EOF'
{"summary": "probe", "files": ["jac/jaclang/cli/pipe.jac"], "risk": "low",
 "release_note": "release_notes/unreleased/jaclang/0000.refactor.md",
 "tests": "t", "loc_before": 1, "loc_after": 0,
 "branch": "nightshift/2026-07-01/dead-code-x", "package": "repo", "date": "2026-07-01"}
EOF
jac run scripts/render_draft.jac render "$PM/report.json" > "$PM/drafts/2026-07-01--dead-code-x.md" \
    || fail "could not render the promote probe draft -- the assertions below would be vacuous"
promote_probe() {      # promote_probe <label> <existing-pr> -> sets $promote_reason
    # NS_PROBE_PR, not a `local existing`: promote_main declares its OWN `local existing`, and bash
    # is dynamically scoped -- the stub would read the callee's empty variable, answer "", and the
    # probe would silently test the wrong arm. (Observed while writing this section.)
    local label=$1 NS_PROBE_PR=$2
    rm -f "$PM/FATAL_REASON" "$PM/order.log"
    (
        . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/ship.sh"; . "$NS_ROOT/lib/promote.sh"
        ns_bootstrap_jac
        LOG_DIR="$PM"; DRAFTS="$PM"; REPO="$PM/norepo"; NS_REPO_UPSTREAM=o/r
        ns_pr_for_branch() { printf '%s' "$NS_PROBE_PR"; }
        sync_main() { echo "SYNC-RAN" >> "$PM/order.log"; }
        promote_main nightshift/2026-07-01/dead-code-x
    ) >/dev/null 2>&1 || true
    promote_reason="$(cat "$PM/FATAL_REASON" 2>/dev/null || true)"
}
promote_probe "existing PR" 9999
case "$promote_reason" in
    *"already has open PR #9999"*) : ;;
    *) fail "promote did not refuse a branch that already has an open PR (reason: '$promote_reason')" ;;
esac
[ -f "$PM/order.log" ] \
    && fail "promote ran sync_main before refusing a duplicate PR -- the refusal must precede the re-sync/rebase/re-gate it does not depend on"
# POSITIVE CONTROL: with no existing PR the SAME run must get past the refusal and reach sync_main.
# Without this, a promote_main that died on its first line satisfies both assertions above.
promote_probe "no existing PR" ""
grep -q SYNC-RAN "$PM/order.log" 2>/dev/null \
    || fail "promote with no existing PR never reached sync_main (reason: '$promote_reason'); the duplicate check is rejecting everything and the assertion above is vacuous"

# --- discard must close the PR BEFORE it deletes the branch --------------------------------------
DC="$T/discard"; mkdir -p "$DC/drafts"
(
    cd "$DC" && git init -q . && git config user.email t@t && git config user.name t \
      && : > led.jsonl && touch drafts/.keep && git add -A && git commit -qm init
) >/dev/null 2>&1 || fail "could not build the discard scratch repo -- the ordering assertions would be vacuous"
discard_probe() {      # discard_probe <label> <want-rc> <pr-num> <close-rc>
    local label=$1 want=$2 NS_PROBE_PR=$3 NS_PROBE_CLOSE_RC=$4 got=0
    : > "$DC/order.log"
    (
        . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/ship.sh"; . "$NS_ROOT/lib/promote.sh"
        LOG_DIR="$DC"; DRAFTS="$DC"; LEDGER="$DC/led.jsonl"; REPO="$DC/norepo"
        NS_REPO_UPSTREAM=o/r; NS_REPO_DEFAULT_BRANCH=main
        ns_pr_for_branch() { printf '%s' "$NS_PROBE_PR"; }
        ns_gh_write() { echo "CLOSE $*" >> "$DC/order.log"; return "$NS_PROBE_CLOSE_RC"; }
        ns_git_push() { echo "PUSH $*" >> "$DC/order.log"; }
        ns_jac() { :; }
        dataset_record_review() { :; }
        discard_main nightshift/2026-07-01/dead-code-x "harness rehearsal"
    ) >/dev/null 2>&1 || got=$?
    case "$got" in
        "$want") : ;;
        *) fail "discard_main '$label': expected rc=$want, got rc=$got" ;;
    esac
}
discard_probe "open PR, close succeeds" 0 4242 0
case "$(head -1 "$DC/order.log")" in
    "CLOSE pr close 4242 "*) : ;;
    *) fail "discard's FIRST upstream action is not closing the PR: $(tr '\n' '|' < "$DC/order.log")" ;;
esac
grep -q '^PUSH .*--delete' "$DC/order.log" \
    || fail "discard did not delete the branch after closing the PR: $(tr '\n' '|' < "$DC/order.log")"
# a FAILED close must abort before the branch is deleted, or the PR is left dangling with its head
# branch gone and no explanation on someone else's repo
discard_probe "open PR, close fails" 70 4242 1
grep -q '^PUSH .*--delete' "$DC/order.log" \
    && fail "discard deleted the branch after FAILING to close the PR -- the open PR is now dangling upstream"
# ...and with no PR at all it must still discard cleanly (positive control for the arm above)
discard_probe "no open PR" 0 "" 0
grep -q '^CLOSE' "$DC/order.log" && fail "discard tried to close a PR that does not exist"
grep -q '^PUSH .*--delete' "$DC/order.log" \
    || fail "discard did not delete the branch when there was no PR to close"
echo "kill path: theme resolves logs->drafts->fatal, promote refuses a duplicate, discard closes before deleting"

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
# followups 4.2: suite_test_raw classifies setup-vs-test by the substring `jac test`, and
# [jobs.compiler]/[jobs.runtime] register `cd jac && … jac test …` as ONE command -- so a failing
# `cd jac` is classified as a TEST failure and surfaces at assert_suite_ran's session-mismatch death
# instead of the setup arm. Not a false green (the session count still aborts), but the operator is
# told the wrong thing unless that death NAMES the command it actually ran.
grep -q 'The last failing command in this job was' lib/verify.sh \
    || fail "assert_suite_ran's session-mismatch death no longer names the failing command; a failing 'cd jac' is classified as a test command by substring and the operator is told the wrong thing"
( . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/cimirror.sh"; . "$NS_ROOT/lib/verify.sh"
  LOG_DIR="$G"; CIMIRROR_FAILED_CMD="cd jac && jac test tests/compiler"
  ns_jac() { case "$2" in sessions) echo 1 ;; testcmds) echo 2 ;; collected) echo 500 ;; esac; }
  assert_suite_ran compiler "$G/raw.txt" 0 gate ) > "$G/sess.txt" 2>&1 || true
grep -q 'cd jac && jac test tests/compiler' "$G/sess.txt" \
    || fail "the session-mismatch death did not name the failing command it was handed: $(cat "$G/sess.txt")"
rm -rf .jac
echo "did-not-run guards behave: collected-0 and session-mismatch are fatal, a healthy capture is not"

echo "== 11. task registry: every task has both prompts, and no placeholder is left unrendered =="
rm -rf .jac
tasks="$(jac run scripts/tasks.jac list config/nightshift.toml)" || fail "tasks.jac list failed"
n_tasks="$(printf '%s\n' "$tasks" | grep -c .)"
# An empty list would make every loop below pass vacuously -- the exact shape of assertion this
# project keeps shipping. Pin the count first.
case "$n_tasks" in
    4) : ;;
    *) fail "expected 4 tasks, tasks.jac list printed $n_tasks" ;;
esac
# The cycle order is a product decision (delete -> simplify -> fix drift -> test), so pin it here
# too: scripts/tasks.jac's own test pins it from inside Jac, this pins what bash actually sees.
case "$(printf '%s\n' "$tasks" | tr '\n' ' ')" in
    "dead-code abstraction maintenance coverage ") : ;;
    *) fail "cycle order changed: '$tasks'" ;;
esac
# No task name may be a prefix of another: lib/common.sh's ns_task_of_branch resolves the task from
# the branch slug by prefix, and an ambiguous pair would silently hand a branch the wrong task --
# and therefore the wrong write permissions.
for a in $tasks; do
    for b in $tasks; do
        case "$a" in
            "$b") : ;;
            "$b"*) fail "task name '$b' is a prefix of '$a'; ns_task_of_branch could not tell them apart" ;;
        esac
    done
done
for t in $tasks; do
    [ -f "prompts/audit-$t.md" ] || fail "no prompts/audit-$t.md for declared task '$t'"
    [ -f "prompts/apply-rules-$t.md" ] || fail "no prompts/apply-rules-$t.md for declared task '$t'"
    [ -s "prompts/apply-rules-$t.md" ] || fail "prompts/apply-rules-$t.md is empty"
done
# Render each prompt through the REAL render_prompt with the real substitution set and demand that
# nothing {braced} survives. A prompt shipped with a live {placeholder} reaches the model verbatim.
#
# `|| true` on the grep is load-bearing in the OTHER direction from usual: the PASS case is "no
# match", which grep reports as rc=1, and under set -e + pipefail that would abort the harness
# before the case arm below could run. The count check underneath is what stops the `|| true` from
# also swallowing a render_prompt that produced nothing at all.
for t in $tasks; do
    rendered="$( . "$NS_ROOT/lib/tier2.sh" >/dev/null 2>&1
                 render_prompt "prompts/audit-$t.md" "shard=s" "scope=sc" "protect_globs=g" \
                               "ponytail_mode=full" "coverage_evidence=e" )"
    case "$rendered" in
        "") fail "render_prompt produced nothing for prompts/audit-$t.md -- the placeholder check below would be vacuous" ;;
    esac
    left="$(printf '%s' "$rendered" | grep -o '{[a-z_]*}' | sort -u | tr '\n' ' ' || true)"
    case "$left" in
        "") : ;;
        *) fail "prompts/audit-$t.md has unrendered placeholders: $left" ;;
    esac
    # ...and the substitution really happened, rather than the file never having had the
    # placeholder. Every audit prompt names its shard and its scope.
    case "$rendered" in
        *"audit shard: \`s\`"*) : ;;
        *) fail "prompts/audit-$t.md did not substitute {shard} -- it must carry the placeholder" ;;
    esac
done
# apply.md, with a real theme object (NOT `{}`: the placeholder grep matches a bare `{}` and would
# report the substituted value as an unrendered placeholder).
rendered="$( . "$NS_ROOT/lib/tier2.sh" >/dev/null 2>&1
             render_prompt prompts/apply.md 'theme={"slug":"t","files":[]}' "ponytail_mode=full" \
                           "task_apply_rules=$(cat prompts/apply-rules-coverage.md)" )"
case "$rendered" in
    *"TASK: coverage"*) : ;;
    *) fail "prompts/apply.md did not substitute {task_apply_rules} -- the per-task rules never reach the session" ;;
esac
left="$(printf '%s' "$rendered" | grep -o '{[a-z_]*}' | sort -u | tr '\n' ' ' || true)"
case "$left" in
    "") : ;;
    *) fail "prompts/apply.md has unrendered placeholders: $left" ;;
esac
# The self-test the two loops above need to be worth anything: a prompt that DOES carry a live
# placeholder must be detected. Without this, a render_prompt that silently stripped every brace
# would make both loops pass.
printf 'hello {not_substituted} world\n' > "$T/decoy.md"
left="$( . "$NS_ROOT/lib/tier2.sh" >/dev/null 2>&1
         render_prompt "$T/decoy.md" "shard=s" | grep -o '{[a-z_]*}' | sort -u | tr '\n' ' ' || true )"
case "$left" in
    "{not_substituted} ") : ;;
    *) fail "the unrendered-placeholder detector did not fire on a prompt that has one (saw '$left'); sections 11's loops would pass vacuously" ;;
esac
rm -rf .jac
echo "4 tasks, 8 prompt files, no unrendered placeholders"

echo "== 12. protect_unless: a theme cannot grant itself a write exemption =="
# THE security-critical case in this plan. Driven through the REAL CLI with the REAL config, not
# through the Jac unit tests alone: what matters is that the argv the gate is called with wins over
# anything the theme says, and only the CLI path proves the argv is even threaded through.
rm -rf .jac
S="$T/scope"; mkdir -p "$S"
# A hostile theme: it claims to be a coverage theme and carries its own exemption list.
printf '{"files":["jac/tests/test_x.jac"],"task":"coverage","protect_unless":["**/tests/**"],"fragment_kind":"refactor"}' \
    > "$S/hostile.json"
if printf 'M\tjac/tests/test_x.jac\n' \
    | jac run scripts/check_scope.jac check "$S/hostile.json" config/nightshift.toml dead-code > "$S/hostile.out"; then
    fail "a dead-code branch was allowed to write tests/** because the THEME claimed to be coverage"
fi
# ...and it was rejected for the RIGHT reason. Without this the assertion above is satisfied by any
# nonzero exit — a typo'd argv (rc=2 from the usage arm), an unreadable theme file, a jac crash.
# "the gate said no" and "the gate ran and said no" are the distinction this whole project keeps
# losing.
grep -q '^VIOLATION jac/tests/test_x.jac protected-glob$' "$S/hostile.out" \
    || fail "the hostile theme was rejected, but not as protected-glob: $(tr '\n' ' ' < "$S/hostile.out")"
# ...and the same diff under the coverage task must be ALLOWED, or the assertion above would pass
# for a gate that simply rejects everything.
printf '{"files":["jac/tests/test_x.jac"],"fragment_kind":""}' > "$S/cov.json"
printf 'M\tjac/tests/test_x.jac\n' \
    | jac run scripts/check_scope.jac check "$S/cov.json" config/nightshift.toml coverage >/dev/null \
    || fail "the coverage task cannot write tests/** -- protect_unless is not being applied at all"
# tests-only: a coverage branch touching a source file in its OWN allow-list is still rejected.
printf '{"files":["jac/jaclang/cli/pipe.jac","jac/tests/test_x.jac"],"fragment_kind":""}' > "$S/cov2.json"
if printf 'M\tjac/jaclang/cli/pipe.jac\n' \
    | jac run scripts/check_scope.jac check "$S/cov2.json" config/nightshift.toml coverage > "$S/cov2.out"; then
    fail "a coverage branch modified a source file; the task is tests-only"
fi
grep -q 'task-writes-tests-only' "$S/cov2.out" \
    || fail "a coverage source write was rejected for the wrong reason: $(tr '\n' ' ' < "$S/cov2.out")"
# an unknown task must be FATAL, not an empty exemption list. Nonzero alone is not enough: rc=1 is
# the gate's own "violations found" code, and an implementation that silently gave an unknown task
# dead-code's (empty) permissions would produce exactly that on this diff. Demand the exception.
if printf 'M\tjac/tests/test_x.jac\n' \
    | jac run scripts/check_scope.jac check "$S/cov.json" config/nightshift.toml not-a-task \
      > "$S/unknown.out" 2> "$S/unknown.err"; then
    fail "an unknown task was gated anyway; it must fail closed"
fi
grep -q 'unknown task: not-a-task' "$S/unknown.err" \
    || fail "an unknown task did not raise -- it was gated under some default permission set instead: $(tr '\n' ' ' < "$S/unknown.err" | tail -c 200)"
rm -rf .jac

# ns_task_of_branch drives the whole thing, so mutate it too: the task must come from the BRANCH.
( . "$NS_ROOT/lib/common.sh"; ns_bootstrap_jac
  got="$(ns_task_of_branch nightshift/2026-07-30/coverage-cli-error-paths)" || exit 1
  [ "$got" = coverage ] || { echo "got '$got'" >&2; exit 1; }
  got="$(ns_task_of_branch nightshift/2026-07-30/dead-code-unused-imports)" || exit 1
  [ "$got" = dead-code ] || { echo "got '$got'" >&2; exit 1; }
  if ns_task_of_branch nightshift/2026-07-30/autofix >/dev/null 2>&1; then
      echo "a tier-1 branch resolved to a task; it has none" >&2; exit 1
  fi
  # A bare task name with no theme hint is NOT a nightshift apply branch: the slug the harness
  # builds is always <task>-<hint>. Accepting it would mean a branch called `coverage` inherited
  # the coverage write exemption, and `"$task"-*` is one character away from `"$task"*`.
  if ns_task_of_branch nightshift/2026-07-30/coverage >/dev/null 2>&1; then
      echo "a bare task name resolved to a task; the slug must be <task>-<hint>" >&2; exit 1
  fi
) || fail "ns_task_of_branch does not resolve the task from the branch slug"
# lib/verify.sh must actually PASS the derived task to the gate. A call site that dropped it would
# hit check_scope's usage arm (exit 2), which `if ! …` reads as a violation -- every branch red,
# loudly. But a call site that passed a CONSTANT would be silent, and that is what this pins.
grep -q 'check_scope check "\$theme" "\$CONFIG" "\$btask"' lib/verify.sh \
    || fail "lib/verify.sh no longer passes the branch-derived task to check_scope; the gate would apply some other task's write permissions"
echo "protect_unless is config-keyed by an argv task: a theme cannot grant itself tests/** access"

echo "== 13. test-weakening guard: both dimensions, driven through the real CLI =="
rm -rf .jac
W="$T/weaken"; mkdir -p "$W"
cat > "$W/old.jac" <<'EOF'
test "a" {
    assert x == 1;
    assert y == 2;
}
test "b" {
    assert z;
}
EOF
cat > "$W/fewer-asserts.jac" <<'EOF'
test "a" {
    assert x == 1;
}
test "b" {
    assert z;
}
EOF
cat > "$W/fewer-tests.jac" <<'EOF'
test "a" {
    assert x == 1;
    assert y == 2;
    assert z;
}
EOF
cat > "$W/stronger.jac" <<'EOF'
test "a" {
    assert x == 1;
    assert y == 2;
}
test "b" {
    assert z;
    assert z2;
}
test "c" {
    assert w;
}
EOF
printf 'def f(x: int) -> int {\n    return x;\n}\n' > "$W/notatest.jac"
# Each dimension INDEPENDENTLY: an implementation that only counts asserts passes the first case
# and fails the second, and vice versa. An always-reject implementation fails the fourth.
#
# Each rejection is asserted on its REASON, not merely on a nonzero exit. `if <cmd>; then fail` is
# satisfied by ANY nonzero -- including check_scope's usage arm (exit 2) after an arity change, and
# including a crash on an unreadable file. Section 4 shipped exactly that hole until Task 6.
if jac run scripts/check_scope.jac weakened t.jac "$W/old.jac" "$W/fewer-asserts.jac" > "$W/fa.txt"; then
    fail "guard accepted a diff that deleted an assert"
fi
grep -q '^VIOLATION t.jac assert-count-reduced-3-to-2$' "$W/fa.txt" \
    || fail "the deleted assert was not reported as an assert-count reduction: $(tr '\n' ' ' < "$W/fa.txt")"
if jac run scripts/check_scope.jac weakened t.jac "$W/old.jac" "$W/fewer-tests.jac" > "$W/ft.txt"; then
    fail "guard accepted a diff that deleted a whole test block while keeping the assert count"
fi
grep -q '^VIOLATION t.jac test-count-reduced-2-to-1$' "$W/ft.txt" \
    || fail "the deleted test block was not reported as a test-count reduction: $(tr '\n' ' ' < "$W/ft.txt")"
# ...and the deleted-test case must NOT also claim an assert reduction: the fixture keeps all three
# asserts, so a guard reporting both dimensions on every rejection would be indistinguishable from
# one that watches only a single counter and labels it twice.
grep -q 'assert-count-reduced' "$W/ft.txt" \
    && fail "the guard reported an assert-count reduction for a diff that kept every assert"
jac run scripts/check_scope.jac weakened t.jac "$W/old.jac" "$W/stronger.jac" >/dev/null \
    || fail "guard rejected a diff that STRENGTHENED the tests; the coverage task could never ship"
jac run scripts/check_scope.jac weakened f.jac "$W/notatest.jac" "$W/notatest.jac" > "$W/out.txt" \
    || fail "guard rejected a non-test file"
# ...and it must say WHICH of the two it did, so a night's log can never claim a comparison that
# did not happen. This is the positive assertion, not the absence of a VIOLATION line.
grep -q '^SKIP f.jac' "$W/out.txt" || fail "guard did not report that it skipped a non-test file"
jac run scripts/check_scope.jac weakened t.jac "$W/old.jac" "$W/stronger.jac" > "$W/out2.txt"
grep -q '^OK t.jac 3 asserts / 2 tests preserved' "$W/out2.txt" \
    || fail "guard did not report the strength it actually compared: $(cat "$W/out2.txt")"
rm -rf .jac
# The CLI being correct is worthless if S4 never calls it. Source-level, and said plainly: this is
# a grep, not a behavioural test -- verify_branch cannot be driven here without a checkout, a jac
# check and the CI mirror. Plan 2 Task 7 Step 7 exercises the real stage against a real branch once,
# by hand; this only stops the whole stage from being deleted while section 13 stays green.
grep -q 'ns_jac check_scope weakened' lib/verify.sh \
    || fail "lib/verify.sh no longer runs the test-weakening guard; section 13 would keep testing a CLI nothing calls"
grep -q 'test-weakening guard: compared' lib/verify.sh \
    || fail "lib/verify.sh no longer logs how many files the test-weakening guard compared; a stage that silently compared zero is the failure this guard exists to prevent"
echo "test-weakening guard fires on assert count and test count independently"

echo "== 14. apply model routing: complexity decides attempt 1, escalation is ONE-WAY =="
route() { ( . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/tier2.sh"
            NS_AGENT_MODEL=opus; NS_AGENT_MODEL_SIMPLE=sonnet; ns_attempt_model "$1" "$2" ); }
# attempt 1 routes on complexity
[ "$(route 1 trivial)"    = sonnet ] || fail "trivial did not route to model_simple"
[ "$(route 1 mechanical)" = sonnet ] || fail "mechanical did not route to model_simple"
[ "$(route 1 judgement)"  = opus ]   || fail "judgement did not route to model"
# an unknown or empty complexity fails SAFE to the expensive model
[ "$(route 1 "")"         = opus ]   || fail "an empty complexity must fail safe to model, not model_simple"
[ "$(route 1 wat)"        = opus ]   || fail "an unknown complexity must fail safe to model"
# attempt 2 is ALWAYS the expensive model: a cheap theme escalates, an expensive one never demotes.
# Both directions are asserted, because an implementation that just returns $NS_AGENT_MODEL for
# everything passes the judgement cases above and would silently stop routing anything cheaply.
[ "$(route 2 trivial)"    = opus ]   || fail "a failed cheap attempt did not escalate to model"
[ "$(route 2 judgement)"  = opus ]   || fail "a judgement retry left the expensive model"
case "$(route 1 trivial)$(route 2 trivial)" in
    sonnetopus) : ;;
    *) fail "escalation is not one-way: attempt1/attempt2 for a trivial theme was '$(route 1 trivial)/$(route 2 trivial)'" ;;
esac

# ns_attempt_model being correct proves nothing if tier2_apply consults it ONCE, outside the retry
# loop: every assertion above still passes while attempt 2 silently reuses attempt 1's model, and
# escalation -- the whole point -- is gone. Source-level ordering, stated plainly as a grep: a
# behavioural test would have to run tier2_apply, which checks out branches in work/repo.
# Plan 2 Task 9 Step 7 rehearses the real loop against a stub `claude` once, by hand.
one_line() {           # one_line <label> <ere> -> the single matching line number in lib/tier2.sh
    local label=$1 pat=$2 hits n
    hits="$(grep -nE -- "$pat" lib/tier2.sh || true)"
    case "$hits" in
        "") fail "routing anchor '$label' not found in lib/tier2.sh (pattern: $pat) -- the ordering check would be vacuous" ;;
    esac
    n="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
    case "$n" in
        1) : ;;
        *) fail "routing anchor '$label' matched $n lines in lib/tier2.sh; it must be unique" ;;
    esac
    printf '%s\n' "$hits" | cut -d: -f1
}
apply_loop_ln="$(grep -n 'for attempt in 1 2; do' lib/tier2.sh | tail -1 | cut -d: -f1)"
case "$apply_loop_ln" in
    ''|*[!0-9]*) fail "could not find tier2_apply's retry loop in lib/tier2.sh" ;;
esac
route_ln="$(one_line "per-attempt route" 'attempt_model="\$\(ns_attempt_model "\$attempt"')"
use_ln="$(one_line "apply --model" '\-\-model "\$attempt_model"')"
[ "$apply_loop_ln" -lt "$route_ln" ] \
    || fail "ns_attempt_model is called at line $route_ln, BEFORE tier2_apply's retry loop at $apply_loop_ln -- attempt 2 would reuse attempt 1's model and escalation would never happen"
[ "$route_ln" -lt "$use_ln" ] \
    || fail "the apply session's --model (line $use_ln) is not the value routed at line $route_ln"
# The audit is the expensive model unconditionally; the old conditional model_args array is gone.
grep -q 'local audit_model="\$NS_AGENT_MODEL"' lib/tier2.sh \
    || fail "the audit no longer pins \$NS_AGENT_MODEL; an unset --model means 'account default', which drifts silently"
# Comments stripped first: lib/tier2.sh explains in prose why the array is gone, and matching that
# explanation would fail this check forever (same shape as section 9b's stripped grep).
grep -vE '^[[:space:]]*#' lib/tier2.sh | grep -q 'model_args' \
    && fail "the model_args array is back in lib/tier2.sh -- under set -u bash 3.2 aborts on an empty one, and both sessions now take an explicit --model"

# covmap's fail-loud contract, which tier2_main's coverage arm is built on: `rank` must NOT come
# back as an empty array when `jac code map` fails. Both directions, so the failure assertion
# cannot be satisfied by a covmap that never produces anything.
rm -rf .jac
CVR="$T/covrepo"; mkdir -p "$CVR/jac/jaclang/cli"
cat > "$CVR/fakejac" <<EOF
#!/usr/bin/env bash
printf '{"schema_version":1,"command":"map","archetypes":[{"name":"WidgetNoTests","kind":"obj","file":"$CVR/jac/jaclang/cli/w.jac","line":4,"fields":["a: int"],"abilities":["go()"]}]}\n'
EOF
chmod +x "$CVR/fakejac"
jac run scripts/covmap.jac rank "$CVR" "$CVR/fakejac" > "$CVR/ok.json" \
    || fail "covmap rank failed against a working map stub -- the failure assertion below would be vacuous"
grep -q 'WidgetNoTests' "$CVR/ok.json" \
    || fail "covmap rank produced no untested symbol for a map with exactly one: $(cat "$CVR/ok.json")"
cov_rc=0
jac run scripts/covmap.jac rank "$CVR" /usr/bin/false > "$CVR/fail.json" 2>/dev/null || cov_rc=$?
case "$cov_rc" in
    0) fail "covmap rank exited 0 for a FAILED jac code map; its output ('$(cat "$CVR/fail.json")') reads to the audit as 'everything is tested'" ;;
esac
[ ! -s "$CVR/fail.json" ] \
    || fail "covmap rank wrote output for a failed map: $(cat "$CVR/fail.json")"
rm -rf .jac
echo "routing: trivial/mechanical -> model_simple, judgement -> model, retry always -> model; covmap fails loud"

echo "== 15. the gh seam: read-only always runs, writes are stubbed, merge is refused =="
# Two functions with opposite defaults share one binary, so each one's REFUSAL is what keeps the
# other honest: a mutating call routed through ns_gh would execute for real during a dry run, and
# a read-only call routed through ns_gh_write would return nothing during one. Driven behaviourally
# with $NS_PATHS_GH stubbed -- nothing here touches GitHub.
seam() {                   # seam <label> <want-rc> <dry?> <fn> <args...>
    local label=$1 want=$2 dry=$3 fn=$4; shift 4
    local got=0 out
    out="$(
        . "$NS_ROOT/lib/common.sh"
        LOG_DIR="$T"; NS_PATHS_GH="$T/fake-gh"; NS_REPO_DEFAULT_BRANCH=main
        if [ "$dry" = dry ]; then NS_DRY_RUN=1; fi
        "$fn" "$@"
    )" 2>/dev/null || got=$?
    case "$got" in
        "$want") : ;;
        *) fail "$fn '$label': expected rc=$want, got rc=$got" ;;
    esac
    seam_out="$out"
}
printf '#!/bin/sh\necho REAL-GH-RAN "$@"\n' > "$T/fake-gh"; chmod +x "$T/fake-gh"

# read-only calls run for real, dry-run or not -- an inventory that cannot list PRs tests nothing
seam "pr list live" 0 live ns_gh pr list --repo o/r --state open
case "$seam_out" in *REAL-GH-RAN*) : ;; *) fail "ns_gh did not invoke gh at all: '$seam_out'" ;; esac
seam "pr list dry"  0 dry  ns_gh pr list --repo o/r --state open
case "$seam_out" in *REAL-GH-RAN*) : ;; *) fail "ns_gh must still run under NS_DRY_RUN" ;; esac
# ...but a MUTATING call routed through the read-only seam is fatal, never silently executed
seam "write via ns_gh" 70 dry ns_gh pr create --repo o/r --draft
case "$seam_out" in *REAL-GH-RAN*) fail "ns_gh EXECUTED a mutating call before refusing it" ;; esac
# `gh api` with an explicit method is a write however innocent the path looks
seam "api PATCH via ns_gh" 70 live ns_gh api "repos/o/r/pulls/1" -X PATCH -f state=closed
case "$seam_out" in *REAL-GH-RAN*) fail "ns_gh EXECUTED 'gh api -X PATCH' before refusing it" ;; esac
seam "api GET via ns_gh"    0 live ns_gh api "repos/o/r/commits/main/check-runs?per_page=100"
case "$seam_out" in *REAL-GH-RAN*) : ;; *) fail "ns_gh refused a plain GET; the CI gate could never read a capture" ;; esac

# writes are stubbed under dry-run and produce a shape-valid, obviously fake URL
seam "create dry" 0 dry ns_gh_write pr create --repo o/r --draft --title t --body b
case "$seam_out" in
    https://github.com/DRY-RUN/pull/0) : ;;
    *) fail "ns_gh_write pr create must emit a shape-valid sentinel URL under dry-run, got '$seam_out'" ;;
esac
case "$seam_out" in *REAL-GH-RAN*) fail "ns_gh_write invoked gh under NS_DRY_RUN" ;; esac
seam "create live" 0 live ns_gh_write pr create --repo o/r --draft
case "$seam_out" in *REAL-GH-RAN*) : ;; *) fail "ns_gh_write must invoke gh when not dry-running" ;; esac
# merging is refused in BOTH modes: a dry-run stub would let a merge call ship unnoticed
for mode in live dry; do
    seam "merge $mode" 70 "$mode" ns_gh_write pr merge 12 --repo o/r
    case "$seam_out" in *REAL-GH-RAN*) fail "ns_gh_write EXECUTED 'pr merge' ($mode) before refusing it" ;; esac
    seam "ready $mode" 70 "$mode" ns_gh_write pr ready 12 --repo o/r
    case "$seam_out" in *REAL-GH-RAN*) fail "ns_gh_write EXECUTED 'pr ready' ($mode) before refusing it" ;; esac
done

# ns_git_push: never main, never a bare --force
push_seam() {              # push_seam <label> <want-rc> <args...>
    local label=$1 want=$2; shift 2
    local got=0
    ( . "$NS_ROOT/lib/common.sh"; LOG_DIR="$T"; NS_DRY_RUN=1; NS_REPO_DEFAULT_BRANCH=main
      ns_git_push /nonexistent "$@" ) >/dev/null 2>&1 || got=$?
    case "$got" in
        "$want") : ;;
        *) fail "ns_git_push '$label': expected rc=$want, got rc=$got" ;;
    esac
}
push_seam "nightshift refspec"  0 origin "refs/heads/nightshift/a/b:refs/heads/nightshift/a/b"
push_seam "force-with-lease"    0 --force-with-lease origin "refs/heads/nightshift/a/b:refs/heads/nightshift/a/b"
push_seam "bare force"         70 --force origin "refs/heads/nightshift/a/b:refs/heads/nightshift/a/b"
push_seam "short force"        70 -f origin "refs/heads/nightshift/a/b:refs/heads/nightshift/a/b"
push_seam "refspec onto main"  70 origin "refs/heads/nightshift/a/b:refs/heads/main"
push_seam "short refspec main" 70 origin "refs/heads/nightshift/a/b:main"
push_seam "bare main"          70 origin main
echo "gh seam correct: reads live, writes stubbed, merge/ready/force/main all refused"

echo "== 16. ship path: the PR URL is asserted BEHAVIOURALLY, the fragment rename is kind-agnostic =="
# RECONCILIATION: the planned version of this section was a source grep for the URL pattern, which
# an implementation with that pattern in a `case` arm lacking a rejecting `*)` satisfies while
# still recording an empty URL. So ship_open_pr is DRIVEN, with ns_gh_write stubbed three ways.
rm -rf .jac
P="$T/ship"; mkdir -p "$P/drafts"
cat > "$P/report.json" <<'EOF'
{"summary": "remove the dead render-path duplication",
 "files": ["jac/jaclang/cli/pipe.jac"],
 "risk": "low",
 "title": "refactor(cli): remove dead render-path duplication",
 "release_note": "release_notes/unreleased/jaclang/0000.refactor.md",
 "tests": "mirror fmt ✓; jac test compiler ✓",
 "loc_before": 40, "loc_after": 3,
 "branch": "nightshift/2026-07-30/dead-code-pipe",
 "package": "repo", "date": "2026-07-30"}
EOF
jac run scripts/render_draft.jac render "$P/report.json" > "$P/drafts/d.md" \
    || fail "could not render the probe draft -- section 16 would be vacuous"
grep -q '^title: ' "$P/drafts/d.md" || fail "the probe draft carries no title; the assertions below would test the wrong arm"

# ship_probe <label> <want-rc> <stub-stdout> <stub-rc>
# Drives the REAL ship_open_pr. ns_gh_write and ns_renumber_fragment are the only stubs: the first
# IS the thing whose output must be distrusted, the second would need a git repo (driven for real
# further down). Nothing here touches GitHub or work/repo.
ship_probe() {
    local label=$1 want=$2 out=$3 stub_rc=$4 got=0
    rm -f "$P/prs.jsonl" "$P/failed.tsv" "$P/renumber.log"
    (
        . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/ship.sh"
        ns_load_config
        LOG_DIR="$P"; LEDGER="$P/ledger.jsonl"; : > "$LEDGER"
        ns_gh_write() { printf '%s' "$out"; return "$stub_rc"; }
        ns_renumber_fragment() { printf '%s\n' "$*" >> "$P/renumber.log"; }
        ship_open_pr nightshift/2026-07-30/dead-code-pipe "$P/drafts/d.md" dead-code-pipe
    ) >/dev/null 2>&1 || got=$?
    case "$got" in
        "$want") : ;;
        *) fail "ship_open_pr '$label': expected rc=$want, got rc=$got" ;;
    esac
}

# THE case this section exists for: gh exits 0 and prints NOTHING. rc alone says success.
ship_probe "gh exits 0 printing nothing" 1 "" 0
grep -q 'no PR URL' "$P/failed.tsv" \
    || fail "an empty 'gh pr create' result was not recorded as a failure: $(cat "$P/failed.tsv" 2>/dev/null)"
[ -s "$P/prs.jsonl" ] || fail "a failed PR open wrote no prs.jsonl row at all; the digest would show nothing happened"
grep -q '"ci": "pr-create-failed"' "$P/prs.jsonl" \
    || fail "the failed PR open was not marked pr-create-failed in prs.jsonl: $(cat "$P/prs.jsonl")"
[ -f "$P/renumber.log" ] \
    && fail "ship_open_pr renumbered the release-note fragment for a PR that was never opened"
# ...and a non-URL string that is merely NON-EMPTY must be rejected too, or the assertion above is
# satisfied by any implementation that only checks for the empty string.
ship_probe "gh prints a warning, not a URL" 1 "Warning: 3 uncommitted changes" 0
grep -q 'no PR URL' "$P/failed.tsv" || fail "a non-URL stdout was accepted as a PR URL"
# ...and a URL-shaped result from a NONZERO gh must not be trusted into the ledger either.
ship_probe "gh fails after printing a URL" 1 "https://github.com/o/r/pull/9" 3
grep -q 'no PR URL' "$P/failed.tsv" \
    || fail "a nonzero 'gh pr create' was accepted because its stdout happened to look like a URL"

# POSITIVE CONTROL. Without this, every assertion above is satisfied by a ship_open_pr that always
# fails.
ship_probe "gh returns a real URL" 0 "https://github.com/jaseci-labs/jac/pull/7301" 0
[ -f "$P/failed.tsv" ] && fail "ship_open_pr recorded a failure for a PR that opened cleanly"
grep -q '"number": 7301' "$P/prs.jsonl" || fail "prs.jsonl lost the PR number: $(cat "$P/prs.jsonl")"
grep -q '"url": "https://github.com/jaseci-labs/jac/pull/7301"' "$P/prs.jsonl" \
    || fail "prs.jsonl lost the PR url: $(cat "$P/prs.jsonl")"
# the task label comes from the BRANCH slug, not from the theme or the draft
grep -q '"task": "dead-code"' "$P/prs.jsonl" \
    || fail "prs.jsonl does not carry the branch-derived task; the digest cannot group PRs: $(cat "$P/prs.jsonl")"
grep -q '"ci": "pending"' "$P/prs.jsonl" \
    || fail "a freshly opened PR must be recorded ci=pending, never green -- its checks are seconds old"
[ "$(wc -l < "$P/prs.jsonl" | tr -d ' ')" = "1" ] \
    || fail "prs.jsonl is not one JSON object per line: $(cat "$P/prs.jsonl")"
grep -q '^nightshift/2026-07-30/dead-code-pipe 7301 ' "$P/renumber.log" \
    || fail "ship_open_pr did not hand the PR NUMBER to the fragment rename: $(cat "$P/renumber.log" 2>/dev/null)"

# --- the fragment rename, driven for real against a scratch git repo -----------------------------
# The literal '0000.refactor.md' is what made the old rename a no-op for four of five kinds. Pin
# both: that the literal is gone from the rename path, and that a NON-refactor kind really is
# renamed. The grep alone would pass for an implementation that simply stopped renaming anything.
# Comments stripped first (same shape as sections 9b and 14): both files explain in prose WHY the
# literal was wrong, and matching that explanation would fail this check forever.
for frf in lib/ship.sh lib/promote.sh; do
    case "$(grep -vE '^[[:space:]]*#' "$frf" | grep -c '0000\.refactor\.md' || true)" in
        0) : ;;
        *) fail "a hardcoded 0000.refactor.md is back in $frf's rename path; it silently no-ops for feature/bugfix/breaking/docs" ;;
    esac
done
FR="$T/frag"
mkdir -p "$FR/release_notes/unreleased/jaclang"
(
    cd "$FR" && git init -q . && git config user.email t@t && git config user.name t \
      && echo base > README && git add -A && git commit -qm base && git branch -M main \
      && git checkout -qb nightshift/2026-07-30/maintenance-x \
      && echo "a note" > release_notes/unreleased/jaclang/0000.bugfix.md \
      && git add -A && git commit -qm frag
) >/dev/null 2>&1 || fail "could not build the fragment scratch repo -- the rename assertions would be vacuous"
frag_rc=0
( . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/ship.sh"
  LOG_DIR="$T"; REPO="$FR"; NS_DRY_RUN=1; NS_REPO_DEFAULT_BRANCH=main
  ns_renumber_fragment nightshift/2026-07-30/maintenance-x 4321 \
      release_notes/unreleased/jaclang/0000.bugfix.md ) >/dev/null 2>&1 || frag_rc=$?
case "$frag_rc" in
    0) : ;;
    *) fail "ns_renumber_fragment exited $frag_rc on a tracked bugfix fragment" ;;
esac
[ -f "$FR/release_notes/unreleased/jaclang/4321.bugfix.md" ] \
    || fail "ns_renumber_fragment did not rename a NON-refactor kind: $(ls "$FR/release_notes/unreleased/jaclang")"
[ -f "$FR/release_notes/unreleased/jaclang/0000.bugfix.md" ] \
    && fail "ns_renumber_fragment left the 0000 placeholder behind; upstream's check-release-notes.sh reds the PR"
( cd "$FR" && git diff --quiet && git diff --cached --quiet ) \
    || fail "ns_renumber_fragment left the rename uncommitted, so the PR would never carry it"
# the empty fragment ([tasks.coverage].fragment = "") must be a clean no-op, NOT an error and NOT a
# rename of the empty path
empty_rc=0
( . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/ship.sh"
  LOG_DIR="$T"; REPO="$FR"; NS_DRY_RUN=1; NS_REPO_DEFAULT_BRANCH=main
  ns_renumber_fragment nightshift/2026-07-30/coverage-x 99 "" ) >/dev/null 2>&1 || empty_rc=$?
case "$empty_rc" in
    0) : ;;
    *) fail "ns_renumber_fragment exited $empty_rc for the empty fragment the coverage task produces; every coverage PR would report a failure" ;;
esac
# a fragment that does not carry the 0000 placeholder is a BUG, not something to rename by guesswork
bad_rc=0
( . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/ship.sh"
  LOG_DIR="$T"; REPO="$FR"; NS_DRY_RUN=1; NS_REPO_DEFAULT_BRANCH=main
  ns_renumber_fragment nightshift/2026-07-30/maintenance-x 7 \
      release_notes/unreleased/jaclang/1234.bugfix.md ) >/dev/null 2>&1 || bad_rc=$?
case "$bad_rc" in
    70) : ;;
    *) fail "ns_renumber_fragment answered rc=$bad_rc for a fragment with no 0000 placeholder; it must ns_die (70)" ;;
esac
rm -rf .jac
echo "ship path: an empty/garbled/failed gh result never becomes a shipped PR; the rename is kind-agnostic"

echo "== 17. S1.6 inventory: an empty answer is not a failed query, and the re-gate never demotes =="
# THE assertion this section exists for: `gh pr list` failing prints NOTHING, and "no open PRs" is a
# perfectly normal answer -- so an unchecked reader failure reports a converged, empty inventory on
# the night the token expires. That is the shape of six of the seven false greens this codebase has
# already shipped, and today there are genuinely zero open PRs, so the empty path is the one that
# actually runs every night. Driven with a fake gh; nothing here touches GitHub or work/repo.
rm -rf .jac
INV="$T/inv"; mkdir -p "$INV"
cat > "$INV/fake-gh" <<EOF
#!/bin/sh
echo "GH \$*" >> "$INV/gh-calls.txt"
case "\$1 \$2" in
    "pr list") cat "$INV/pr-list.out"; exit "\$(cat "$INV/pr-list.rc")" ;;
    "pr view") echo "{\"headRefOid\": \"\$(cat "$INV/sha-\$3")\"}" ;;
    "api "*)   case "\$2" in
                   *"/commits/main/"*) cat "$INV/checks-main.json" ;;
                   *"/commits/aaa111/"*) cat "$INV/checks-green.json" ;;
                   *) cat "$INV/checks-red.json" ;;
               esac ;;
esac
exit 0
EOF
chmod +x "$INV/fake-gh"
echo aaa111 > "$INV/sha-7301"; echo bbb222 > "$INV/sha-7302"
inv_checks() {             # inv_checks <file> <name:status:conclusion> ...
    local out=$1 first=1 spec; shift
    printf '{"total_count": %d, "check_runs": [' "$#" > "$out"
    for spec in "$@"; do
        case "$first" in 0) printf ', ' >> "$out" ;; esac
        first=0
        printf '{"name": "%s", "status": "%s", "conclusion": "%s"}' \
            "${spec%%:*}" "$(echo "$spec" | cut -d: -f2)" "${spec##*:}" >> "$out"
    done
    printf ']}\n' >> "$out"
}
inv_checks "$INV/checks-main.json"  build-jac:completed:success jac-check:completed:failure
inv_checks "$INV/checks-green.json" build-jac:completed:success jac-check:completed:failure
inv_checks "$INV/checks-red.json"   build-jac:completed:failure jac-check:completed:failure
# THE point of the baseline diff, driven end to end: jac-check is red on the branch AND red on main,
# so it must NOT red the PR; build-jac is red on the branch and green on main, so it must.

inv_run() {                # inv_run  -> rc in $inv_rc; fresh $INV/log each time
    rm -rf "$INV/log"; mkdir -p "$INV/log"; rm -f "$INV/gh-calls.txt" "$INV/ci-baseline.json"
    inv_rc=0
    (
        . "$NS_ROOT/lib/common.sh"; ns_load_config
        . "$NS_ROOT/lib/inventory.sh"
        LOG_DIR="$INV/log"; CI_BASELINE="$INV/ci-baseline.json"
        NS_PATHS_GH="$INV/fake-gh"; NS_REPO_UPSTREAM=o/r; NS_REPO_DEFAULT_BRANCH=main
        # inventory_refresh is stubbed: it fetches/rebases/force-pushes a real branch, and section
        # 17's subject is the LISTING and the VERDICT. Its own guards are driven further down.
        inventory_refresh() { echo "REFRESH $*" >> "$INV/log/refresh.txt"; }
        inventory_main
    ) >/dev/null 2>&1 || inv_rc=$?
}
inv_saw() { grep -q "$1" "$INV/log/$2" 2>/dev/null; }

# --- A. the query ran and there is genuinely nothing to do -----------------------------------
echo '[]' > "$INV/pr-list.out"; echo 0 > "$INV/pr-list.rc"
inv_run
[ "$inv_rc" = 0 ] || fail "S1.6 exited $inv_rc on an empty PR list; an empty inventory is the normal state and must not end the night"
inv_saw "the inventory ran and is empty" run.log \
    || fail "S1.6 did not positively record that it QUERIED and got zero PRs: $(cat "$INV/log/run.log" 2>/dev/null)"
inv_saw "did NOT run" warnings.txt \
    && fail "S1.6 warned that the inventory did not run when the query succeeded and simply returned nothing"
grep -q '^GH pr list' "$INV/gh-calls.txt" \
    || fail "S1.6 reported an empty inventory without ever calling 'gh pr list' -- 'nothing to maintain' with no query behind it"
[ -f "$INV/log/pr-inventory.jsonl" ] \
    || fail "S1.6 did not create pr-inventory.jsonl; Plan 4's digest reader returns [] for a missing file, so the section would render empty forever with no error"

# --- B. ...and a FAILED query must not look like A ---------------------------------------------
: > "$INV/pr-list.out"; echo 4 > "$INV/pr-list.rc"
inv_run
[ "$inv_rc" = 0 ] || fail "S1.6 exited $inv_rc when gh failed; a night must survive an unreachable API"
inv_saw "the inventory did NOT run tonight" warnings.txt \
    || fail "a failed 'gh pr list' produced no warning; the digest would show a converged inventory on the night the token expired: $(cat "$INV/log/warnings.txt" 2>/dev/null)"
inv_saw "This is not the same as having none" warnings.txt \
    || fail "the failed-query warning does not say that it differs from having no PRs -- the distinction IS the assertion"
# ...and it must be the READER's own rc that was noticed, named, in this warning. Mutation found
# this the hard way: deleting inventory_main's `gh pr list` rc check entirely left the harness GREEN,
# because the empty $raw then fails the cigate PROJECTION and that guard raises the same sentence.
# Safe only by accident -- the day `cigate prs` tolerates empty input (returning []), an expired
# token renders as a converged inventory with no warning at all. Pinning gh's own exit code is what
# makes the first guard non-decorative.
inv_saw "could not list open PRs (gh rc=4)" warnings.txt \
    || fail "the failed query was not caught at the READER: nothing names gh's own rc=4, so the failure is being noticed downstream (by the projection) rather than where it happened: $(cat "$INV/log/warnings.txt" 2>/dev/null)"
inv_saw "the inventory ran and is empty" run.log \
    && fail "a failed 'gh pr list' was reported as an inventory that ran and found nothing -- the exact false green this section exists for"
case "$(wc -l < "$INV/log/pr-inventory.jsonl" | tr -d ' ')" in
    0) : ;;
    *) fail "a failed query invented $(wc -l < "$INV/log/pr-inventory.jsonl") inventory row(s)" ;;
esac

# --- C. a real list: the nightshift/ prefix filter, and the baseline diff in both directions ---
cat > "$INV/pr-list.out" <<'EOF'
[{"number": 7301, "headRefName": "nightshift/2026-07-29/dead-code-pipe",
  "url": "https://github.com/o/r/pull/7301", "title": "refactor: drop dead pipe"},
 {"number": 7302, "headRefName": "nightshift/2026-07-28/coverage-cli",
  "url": "https://github.com/o/r/pull/7302", "title": "test: cover the cli"},
 {"number": 9999, "headRefName": "my-own-hand-written-branch",
  "url": "https://github.com/o/r/pull/9999", "title": "a human's PR"}]
EOF
echo 0 > "$INV/pr-list.rc"
inv_run
[ "$inv_rc" = 0 ] || fail "S1.6 exited $inv_rc on a normal three-PR list"
inv_saw "1 checks currently passing on main" run.log \
    || fail "S1.6 recorded no CI baseline from a readable capture: $(cat "$INV/log/run.log")"
# the prefix filter is a SAFETY invariant: everything downstream fetches, rebases and force-pushes
# what this projection hands it, so a human's PR reaching the loop is a force-push of their branch.
grep -q 'my-own-hand-written-branch' "$INV/log/refresh.txt" \
    && fail "S1.6 handed a NON-nightshift branch to the refresh path; it would rebase and force-push a human's branch"
grep -q '9999' "$INV/log/pr-inventory.jsonl" \
    && fail "S1.6 recorded a verdict for a PR whose head is not under nightshift/"
case "$(wc -l < "$INV/log/refresh.txt" | tr -d ' ')" in
    2) : ;;
    *) fail "S1.6 refreshed $(wc -l < "$INV/log/refresh.txt") branch(es); the two nightshift PRs and only those must be processed" ;;
esac
# #7301: build-jac green on the branch, jac-check red on BOTH -> green. This is the whole reason
# cigate exists (upstream main is red on jac-check right now); a plain all-green gate would red it.
grep -q '"number": 7301.*"action": "ci-green"' "$INV/log/pr-inventory.jsonl" \
    || fail "PR #7301 was not scored ci-green: a check that is red on main too must not red the PR. Got: $(cat "$INV/log/pr-inventory.jsonl")"
inv_saw 'CI RED' warnings.txt || fail "PR #7302 broke build-jac, which is green on main, and no CI-red warning was raised"
grep -q '"number": 7302.*"action": "ci-red"' "$INV/log/pr-inventory.jsonl" \
    || fail "PR #7302 was not scored ci-red: $(cat "$INV/log/pr-inventory.jsonl")"
grep -q '"number": 7302.*build-jac' "$INV/log/pr-inventory.jsonl" \
    || fail "the ci-red row does not name the failing check, so the digest tells the operator nothing actionable: $(cat "$INV/log/pr-inventory.jsonl")"
grep -q '"number": 7302.*jac-check' "$INV/log/pr-inventory.jsonl" \
    && fail "the ci-red row blames jac-check, which fails on main too -- the baseline diff is not being applied"

# --- D. no usable baseline is "cannot gate", never "green" and never fatal ---------------------
printf '{"total_count": 30, "check_runs": []}\n' > "$INV/checks-main.json"
inv_run
[ "$inv_rc" = 0 ] || fail "S1.6 exited $inv_rc when main's capture was unreadable; a baseline failure must never end the night"
inv_saw "no PR will be CI-gated tonight" warnings.txt \
    || fail "a truncated main capture produced no warning: $(cat "$INV/log/warnings.txt" 2>/dev/null)"
grep -q '"action": "ci-nobaseline"' "$INV/log/pr-inventory.jsonl" \
    || fail "with no baseline the PRs were not recorded as ungated; 'cannot gate' must never render as green: $(cat "$INV/log/pr-inventory.jsonl")"
grep -q '"action": "ci-green"' "$INV/log/pr-inventory.jsonl" \
    && fail "a PR was scored ci-green against a baseline that could not be recorded"
inv_checks "$INV/checks-main.json" build-jac:completed:success jac-check:completed:failure

# --- the re-gate must not burn attempt counters or delete an open PR's branch -----------------
# [jobs.contribution] validates WHOLE-REPO state (validate_docs_code.jac's 852 blocks, the bun/zig
# lockstep), so an upstream-introduced breakage reds every open PR identically. With the default
# demote mode that bumps every finding's attempts and auto-rejects the whole ledger after two
# nights, over something no branch caused. The inventory therefore re-gates in report mode.
grep -qE 'verify_branch "\$branch" "\$theme" report' lib/inventory.sh \
    || fail "lib/inventory.sh does not re-gate in report mode; an upstream breakage would auto-reject the entire ledger in two nights"
# every verify_red call INSIDE verify_branch must forward the mode, or the mode is decorative
vr_total="$(grep -c 'verify_red "\$branch"' lib/verify.sh || true)"
vr_moded="$(grep -c 'verify_red "\$branch" .* "\$on_red"' lib/verify.sh || true)"
case "$vr_total" in
    0) fail "no verify_red call sites found in lib/verify.sh -- this assertion would be vacuous" ;;
esac
[ "$vr_total" = "$vr_moded" ] \
    || fail "$((vr_total - vr_moded)) of $vr_total verify_red calls do not forward \$on_red; those paths still demote during an S1.6 re-gate"
VR="$T/vr"; mkdir -p "$VR"
vr_probe() {               # vr_probe <mode-args...>
    rm -f "$VR/calls.txt"
    vr_rc=0
    ( . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/verify.sh"
      LOG_DIR="$VR"; LEDGER="$VR/ledger.jsonl"; REPO="$VR/norepo"; NS_REPO_DEFAULT_BRANCH=main
      ns_jac() { echo "LEDGER-WRITE $*" >> "$VR/calls.txt"; }
      git() { echo "GIT $*" >> "$VR/calls.txt"; }
      verify_red somebranch "a reason" "$@" ) >/dev/null 2>&1 || vr_rc=$?
}
vr_probe report
[ "$vr_rc" = 0 ] || fail "verify_red in report mode returned $vr_rc; verify_branch's own 'return 1' is what marks the branch red"
case "$(cat "$VR/calls.txt" 2>/dev/null || true)" in
    *LEDGER-WRITE*) fail "verify_red in report mode still wrote to the ledger -- attempts would be burned by every S1.6 re-gate" ;;
esac
case "$(cat "$VR/calls.txt" 2>/dev/null || true)" in
    *"branch -D"*) fail "verify_red in report mode still deleted the branch -- an open PR's head would vanish" ;;
esac
grep -q 'somebranch' "$VR/failed.tsv" \
    || fail "verify_red in report mode recorded nothing in failed.tsv; a silent red is worse than a demoting one"
# ...and demote mode must still do both, or the guard has simply disabled the S4 gate
vr_probe
case "$(cat "$VR/calls.txt" 2>/dev/null || true)" in
    *LEDGER-WRITE*) : ;;
    *) fail "verify_red in the DEFAULT mode no longer demotes -- the S4 gate has been silently disabled" ;;
esac
case "$(cat "$VR/calls.txt" 2>/dev/null || true)" in
    *"branch -D"*) : ;;
    *) fail "verify_red in the DEFAULT mode no longer deletes the red branch" ;;
esac

# The inventory never force-pushes bare. COMMENTS STRIPPED FIRST, and the bare form asserted absent
# as well as the leased form present: mutation found that the plain `grep -q force-with-lease` stayed
# green after the actual push was changed to `--force`, because this file's header explains in prose
# why the push is leased. `--force-with-lease` cannot match `--force([^-]|$)`, so the two checks do
# not cancel. (ns_git_push refuses a bare --force at runtime, but that refusal is an ns_die: S1.6
# runs before all new work, so it would end the night rather than skip a push.)
inv_code="$(grep -vE '^[[:space:]]*#' lib/inventory.sh)"
printf '%s\n' "$inv_code" | grep -q -- '--force-with-lease' \
    || fail "lib/inventory.sh does not push a rebased branch with --force-with-lease (checked against the CODE, not the comments)"
printf '%s\n' "$inv_code" | grep -qE -- '--force([^-]|$)' \
    && fail "lib/inventory.sh pushes with a BARE --force; ns_git_push ns_dies on it, so every night would end at S1.6 before any new work"
grep -q 'cigate prs "nightshift/"' lib/inventory.sh \
    || fail "lib/inventory.sh no longer filters PR heads to nightshift/ -- it would rebase and force-push a human's branch"
# a rebase conflict is REPORTED, never resolved and never forced
grep -q 'git rebase --abort' lib/inventory.sh \
    || fail "lib/inventory.sh does not abort a conflicting rebase; work/repo would be left mid-rebase for every later stage"
case "$(grep -vE '^[[:space:]]*#' lib/inventory.sh | grep -cE 'rebase.*(--continue|-Xours|-Xtheirs|--strategy)' || true)" in
    0) : ;;
    *) fail "lib/inventory.sh tries to RESOLVE a rebase conflict; a conflict is reported and left for a human, never merged by the harness" ;;
esac
rm -rf .jac
echo "S1.6: an empty answer is distinguishable from a failed query; heads filtered; re-gate report-only; lease-only force"

echo "== 18. S1.6 is agent-free and runs before any new work =="
# Spec 8.1 describes rerunning failed jobs then up to two Opus repair attempts. It is NOT built --
# see the plan's 'deliberately not built'. This is the structural version of that decision: the
# inventory has no path to a model at all, so a red PR can only ever be reported. A future repair
# loop has to delete this assertion on purpose, in a commit that says so. Comments are stripped
# first: this file explains in prose WHY there is no repair loop, and matching that explanation
# would fail the check forever.
case "$(grep -vE '^[[:space:]]*#' lib/inventory.sh | grep -cE '\$NS_PATHS_CLAUDE|claude |run rerun' || true)" in
    0) : ;;
    *) fail "lib/inventory.sh invokes an agent or reruns CI jobs; the repair loop is out of scope for this plan and must be added deliberately, not smuggled in" ;;
esac
# The stage has to actually be wired in, and every source has to still load: `ns_stage S1.6
# inventory_main` in a file that never sources lib/inventory.sh fails at 02:00, not here.
grep -q '^\. "\$NS_ROOT/lib/inventory.sh"' bin/nightshift.sh \
    || fail "bin/nightshift.sh does not source lib/inventory.sh, so 'ns_stage S1.6 inventory_main' would die with 'command not found' on the first live night"
ns_probe_rc=0
bin/nightshift.sh __harness_source_probe__ >/dev/null 2>&1 || ns_probe_rc=$?
case "$ns_probe_rc" in
    2) : ;;
    *) fail "bin/nightshift.sh exited $ns_probe_rc on an unknown command instead of 2 (usage); one of its sourced libs no longer loads" ;;
esac
# ORDERING. RECONCILIATION: the planned version of this guard fired only when BOTH line numbers were
# empty, and anchored on `ns_stage S2 tier1_main`, which no longer exists -- so post-retirement it
# fell through to `[ "93" -lt "" ]`, a malformed integer comparison rather than a verdict. Re-anchored
# on S1 and S3, and EACH variable is validated on its own. `|| true` on both pipelines because
# grep exits 1 when it matches nothing and this harness runs under `set -o pipefail`: without it the
# tripwire would abort the run with no message at all, which is a tripwire that cannot report.
s1_ln="$(grep -n 'ns_stage S1 sync_main' bin/nightshift.sh | cut -d: -f1 || true)"
inv_ln="$(grep -n 'ns_stage S1\.6 inventory_main' bin/nightshift.sh | cut -d: -f1 || true)"
s3_ln="$(grep -n 'ns_stage S3 tier2_main' bin/nightshift.sh | cut -d: -f1 || true)"
case "$s1_ln"  in ''|*[!0-9]*) fail "no 'ns_stage S1 sync_main' line in bin/nightshift.sh (got '$s1_ln') -- the S1.6 ordering check has nothing to anchor on" ;; esac
case "$inv_ln" in ''|*[!0-9]*) fail "no 'ns_stage S1.6 inventory_main' line in bin/nightshift.sh (got '$inv_ln') -- S1.6 is not wired into the night at all" ;; esac
case "$s3_ln"  in ''|*[!0-9]*) fail "no 'ns_stage S3 tier2_main' line in bin/nightshift.sh (got '$s3_ln') -- the S1.6 ordering check has nothing to anchor on" ;; esac
[ "$s1_ln" -lt "$inv_ln" ] \
    || fail "S1.6 (line $inv_ln) must run AFTER S1 (line $s1_ln): it rebases onto fresh main and resolves themes out of the work/drafts worktree, both of which S1 refreshes"
[ "$inv_ln" -lt "$s3_ln" ] \
    || fail "S1.6 (line $inv_ln) must run BEFORE S3 (line $s3_ln): existing PRs outrank new work, or the inventory never converges"
# `nightshift.sh inventory` must refuse to run underneath a live night (it git-checkouts and rebases
# in work/repo), and must NOT take the lock -- there is no EXIT trap on that path to release it.
inv_arm="$(awk '/^    inventory\)/,/;;$/' bin/nightshift.sh)"
case "$inv_arm" in
    "") fail "bin/nightshift.sh has no 'inventory)' arm; S1.6 cannot be hand-run" ;;
esac
case "$inv_arm" in
    *'$LOCK_DIR/pid'*) : ;;
    *) fail "the 'inventory' arm does not check for a live night; it would git-checkout and rebase in work/repo underneath a running S3/S4/S5" ;;
esac
case "$inv_arm" in
    *ns_lock_acquire*) fail "the 'inventory' arm calls ns_lock_acquire; there is no EXIT trap on that path to release it, so /tmp/nightshift.lock would be held forever and block every subsequent night" ;;
esac
case "$inv_arm" in
    *'$EX_LOCK'*) : ;;
    *) fail "the 'inventory' arm detects a live night but does not ns_die EX_LOCK on it" ;;
esac
# S1.6's theme resolver looks in $DRAFTS/themes second, and S1 is what puts $DRAFTS on disk -- so
# S1.6 inherits drafts_bootstrap's one hard precondition. Driven against a real scratch repo, not
# grepped: `git worktree add` REFUSES a path that is still registered after the directory was
# rm -rf'd, which is precisely the state Plan 5's reset left work/repo in (`git worktree list` shows
# work/drafts `prunable` today). Without the prune the first live S1 dies at rc=128 under errexit
# and no night ever reaches S1.6.
WT="$T/wt"; mkdir -p "$WT"
( cd "$WT" && git init -q r && cd r && git config user.email t@t && git config user.name t \
    && echo a > a && git add -A && git commit -qm a && git worktree add -q ../gone \
    && rm -rf ../gone ) >/dev/null 2>&1 \
    || fail "could not build the worktree scratch repo -- this assertion would be vacuous"
wt_rc=0
( cd "$WT/r" && git worktree add ../gone ) >/dev/null 2>&1 || wt_rc=$?
case "$wt_rc" in
    0) fail "git no longer refuses to re-add a rm -rf'd worktree, so this assertion no longer proves anything -- re-derive it before deleting it" ;;
esac
( cd "$WT/r" && git worktree prune && git worktree add ../gone ) >/dev/null 2>&1 \
    || fail "git worktree prune did not clear the stale registration; drafts_bootstrap's fix is built on a premise that no longer holds"
db_body="$(awk '/^drafts_bootstrap\(\)/,/^}/' lib/sync.sh)"
case "$db_body" in
    "") fail "no drafts_bootstrap in lib/sync.sh -- S1 cannot create work/drafts at all" ;;
esac
prune_ln="$(printf '%s\n' "$db_body" | grep -n 'worktree prune' | cut -d: -f1 || true)"
add_ln="$(printf '%s\n' "$db_body" | grep -n 'worktree add' | head -1 | cut -d: -f1 || true)"
case "$prune_ln" in ''|*[!0-9]*) fail "drafts_bootstrap does not 'git worktree prune' before adding work/drafts; work/repo currently carries a stale registration for it, so the first live S1 dies at rc=128 and no night reaches S1.6" ;; esac
case "$add_ln"   in ''|*[!0-9]*) fail "drafts_bootstrap no longer calls 'git worktree add' -- the ordering check below would be vacuous" ;; esac
[ "$prune_ln" -lt "$add_ln" ] \
    || fail "drafts_bootstrap prunes (line $prune_ln of the function) AFTER adding the worktree (line $add_ln); the add is what fails, so the prune has to precede it"
echo "S1.6 is agent-free, sourced, ordered S1 < S1.6 < S3, hand-runnable only outside a live night; drafts_bootstrap prunes first"

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
