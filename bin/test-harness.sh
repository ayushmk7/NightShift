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

echo "== 21. merge poll: 'nothing merged' must be distinguishable from 'failed to ask' =="
# `gh` exits 0 having written nothing under several failure modes, and an empty file word-splits
# to zero iterations exactly like a quiet day -- the harness's recurring defect class, now in a
# new stage. Driven against the REAL reactive_poll with a stubbed gh.
rm -rf .jac
P="$T/poll"; mkdir -p "$P"
poll_probe() {          # poll_probe <gh-stdout> -> prints "rc=<n> watermark=<yes|no>"
    printf '#!/usr/bin/env bash\nprintf %%s %s\nexit 0\n' "$(printf '%q' "$1")" > "$P/gh"
    chmod +x "$P/gh"; echo '{}' > "$P/state.json"
    rm -f "$P/merges.json" "$P/reactive-files.txt" "$P/failed.tsv"
    local rc=0
    ( . "$NS_ROOT/lib/common.sh"; ns_load_config; . "$NS_ROOT/lib/reactive.sh"
      LOG_DIR="$P"; STATE="$P/state.json"; NS_DATE=2026-01-02; NS_PATHS_GH="$P/gh"
      reactive_poll ) >/dev/null 2>&1 || rc=$?
    if grep -q last_merge_poll "$P/state.json" 2>/dev/null; then
        echo "rc=$rc watermark=yes"
    else
        echo "rc=$rc watermark=no"
    fi
}
poll_probe_rc() {       # poll_probe_rc <gh-exit-code> -> same, for a gh that fails outright
    printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$P/gh"
    chmod +x "$P/gh"; echo '{}' > "$P/state.json"
    rm -f "$P/merges.json" "$P/reactive-files.txt" "$P/failed.tsv"
    local rc=0
    ( . "$NS_ROOT/lib/common.sh"; ns_load_config; . "$NS_ROOT/lib/reactive.sh"
      LOG_DIR="$P"; STATE="$P/state.json"; NS_DATE=2026-01-02; NS_PATHS_GH="$P/gh"
      reactive_poll ) >/dev/null 2>&1 || rc=$?
    if grep -q last_merge_poll "$P/state.json" 2>/dev/null; then
        echo "rc=$rc watermark=yes"
    else
        echo "rc=$rc watermark=no"
    fi
}
case "$(poll_probe '')" in
    "rc=1 watermark=no") : ;;
    *) fail "an EMPTY gh response was accepted as a quiet day: $(poll_probe '') -- 'did not ask' is being scored as 'nothing merged'" ;;
esac
# THE REASON, not just the refusal. `if <cmd>; then fail` reads any nonzero as correct rejection,
# and this repo has already shipped one reconciliation claim that was wrong for exactly that reason.
# The poll must refuse BECAUSE gh answered with nothing parseable -- if the count guard is deleted,
# a later guard still returns 1 and the rc/watermark pair alone stays green. Mutation-confirmed.
grep -q "no parseable JSON array" "$P/failed.tsv" \
    || fail "an empty gh answer was refused for the wrong reason (or none): $(cat "$P/failed.tsv" 2>/dev/null) -- the positive 'gh really answered' assertion is gone"
# ...and it must not have left a scope behind either: reactive_main reads reactive-files.txt, and a
# stale one from an earlier poll would make a FAILED poll spend four sessions on yesterday's files.
[ -e "$P/reactive-files.txt" ] && fail "a failed poll still wrote an audit scope"
case "$(poll_probe '{"message":"Bad credentials"}')" in
    "rc=1 watermark=no") : ;;
    *) fail "a non-array gh response was accepted as a merge list" ;;
esac
grep -q "no parseable JSON array" "$P/failed.tsv" \
    || fail "a non-array gh answer was refused for the wrong reason: $(cat "$P/failed.tsv" 2>/dev/null)"
# A gh that FAILS outright must say so as a gh failure, not be folded into the parse arm.
case "$(poll_probe_rc 7)" in
    "rc=1 watermark=no") : ;;
    *) fail "a gh that exited nonzero did not fail the poll" ;;
esac
grep -q "gh exited 7" "$P/failed.tsv" \
    || fail "a nonzero gh exit was not reported as one: $(cat "$P/failed.tsv" 2>/dev/null)"
case "$(poll_probe '[]')" in
    "rc=0 watermark=yes") : ;;
    *) fail "a genuinely quiet day was reported as a poll FAILURE -- it must succeed with zero merges" ;;
esac
[ -f "$P/reactive-files.txt" ] || fail "a successful quiet poll wrote no reactive-files.txt at all"
[ -s "$P/reactive-files.txt" ] && fail "a quiet day wrote a NON-EMPTY audit scope"
case "$(poll_probe '[{"number":1,"title":"t","author":{"login":"a"},"files":[{"path":"jac/jaclang/cli/a.jac"},{"path":"README.md"}]}]')" in
    "rc=0 watermark=yes") : ;;
    *) fail "a real merge list was rejected" ;;
esac
grep -q 'jac/jaclang/cli/a.jac' "$P/reactive-files.txt" \
    || fail "reactive_poll did not write the changed-file union"
# ...and the union is the AUDITABLE one. An unfiltered scope spends four Opus sessions on files no
# lens has a rule for; measured 2026-07-30, the real merge day's sorted-first 40 paths were all
# .github/**, README.md and release_notes/**.
grep -q 'README.md' "$P/reactive-files.txt" \
    && fail "reactive_poll's scope includes paths no shard covers; four sessions would be spent on files no lens can act on"
# ...and the digest's "which PRs merged" list, which is the only place that fact appears at all.
grep -q '^1\tt\ta\t2$' "$P/reactive-prs.tsv" \
    || fail "reactive_poll wrote no usable reactive-prs.tsv: $(cat "$P/reactive-prs.tsv" 2>/dev/null) -- the digest would report merge counts with no PR behind them"
# The stage entry point must NOT propagate a failed poll: ns_stage runs it as a plain command under
# errexit, so a nonzero would abort the night at S1.5 and cost S1.6, S3, S4 and S5 as well.
printf '#!/usr/bin/env bash\nexit 4\n' > "$P/gh"; chmod +x "$P/gh"; echo '{}' > "$P/state.json"
NS_ROOT="$NS_ROOT" bash -c 'set -euo pipefail
    . "$NS_ROOT/lib/common.sh"; ns_load_config; . "$NS_ROOT/lib/reactive.sh"
    LOG_DIR="$1"; STATE="$1/state.json"; NS_DATE=2026-01-02; NS_PATHS_GH="$1/gh"
    reactive_stage' _ "$P" >/dev/null 2>&1 \
    || fail "reactive_stage propagated a failed poll; under ns_stage's errexit that ends the night at S1.5"
echo "merge poll distinguishes quiet, empty, malformed and real; a failed poll cannot end the night"

echo "== 22. reactive pass: a quiet day spends nothing, and never looks like a failure =="
# Four LLM sessions a night is the most expensive thing in Plan 4, justified ONLY by the scope
# being a handful of merged files. The guard that keeps a quiet day free is one `-s` test, and
# losing it would be invisible except on the bill. Driven with a claude stub that records any
# invocation; nothing here can reach a real session even if the guard is broken.
rm -rf .jac
Q="$T/quiet"; mkdir -p "$Q"
printf '#!/usr/bin/env bash\ntouch "%s/CLAUDE_WAS_CALLED"\n' "$Q" > "$Q/claude"; chmod +x "$Q/claude"
: > "$Q/reactive-files.txt"
# A separate bash PROCESS, not a `( … ) || fail` subshell: bash suspends errexit for everything on
# the left of a `||`, so the subshell form cannot catch a mid-function abort at all.
NS_ROOT="$NS_ROOT" bash -c 'set -euo pipefail
    . "$NS_ROOT/lib/common.sh"; ns_load_config; . "$NS_ROOT/lib/tier2.sh"; . "$NS_ROOT/lib/reactive.sh"
    LOG_DIR="$1"; NS_PATHS_CLAUDE="$1/claude"; date +%s > "$1/start_epoch"; reactive_main' _ "$Q" \
    > "$Q/out.txt" 2>&1 || fail "reactive_main returned nonzero on a quiet day -- it must never fail the night"
[ -e "$Q/CLAUDE_WAS_CALLED" ] && fail "a quiet day started an audit session; the reactive pass is not free"
[ -e "$Q/failed.tsv" ] && fail "a quiet day wrote a failure row; 'nothing merged' is not a failure"
[ -e "$Q/covmap.json" ] && fail "a quiet day built covmap evidence; the guard must return before any work at all"
case "$(ls "$Q" | grep -c '^findings-\|^audit-' || true)" in
    0) : ;;
    *) fail "a quiet day left audit artifacts behind: $(ls "$Q" | grep '^findings-\|^audit-' | tr '\n' ' ')" ;;
esac
# ...and it must still SAY something, or a skipped pass is indistinguishable from a missing one
grep -q 'S3a' "$Q/out.txt" || fail "a quiet day logged nothing at all; a skipped pass must be visible"
case "$(grep -c 'S3a' "$Q/out.txt")" in
    1) : ;;
    *) fail "a quiet day logged $(grep -c 'S3a' "$Q/out.txt") S3a lines; the guard promises exactly one" ;;
esac
# THE DISTINCTION THIS WHOLE PLAN EXISTS FOR: a poll that never answered leaves NO scope file, and
# must not be reported with the same words as a poll that answered "nothing".
N="$T/noask"; mkdir -p "$N"
cp "$Q/claude" "$N/claude"
NS_ROOT="$NS_ROOT" bash -c 'set -euo pipefail
    . "$NS_ROOT/lib/common.sh"; ns_load_config; . "$NS_ROOT/lib/tier2.sh"; . "$NS_ROOT/lib/reactive.sh"
    LOG_DIR="$1"; NS_PATHS_CLAUDE="$1/claude"; date +%s > "$1/start_epoch"; reactive_main' _ "$N" \
    > "$N/out.txt" 2>&1 || fail "reactive_main returned nonzero when the poll had not answered"
[ -e "$N/CLAUDE_WAS_CALLED" ] && fail "a missing merge poll still started audit sessions"
grep -q 'did not answer' "$N/out.txt" \
    || fail "a poll that never ran was reported as a quiet day: $(cat "$N/out.txt") -- 'did not ask' is being scored as 'nothing merged'"
grep -q 'no upstream merges' "$N/out.txt" \
    && fail "a poll that never ran was reported with the quiet-day wording"

# The CEILING: a merge day too large to read is truncated with a warning, not pursued. Driven, with
# a claude stub that records the prompt it was handed so the scope can be counted.
C="$T/ceiling"; mkdir -p "$C"
cat > "$C/claude" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
    case "$1" in -p) printf '%s' "$2" >> "$CEILING_PROMPTS" ;; esac
    shift
done
printf '{"result":"```json\\n[]\\n```"}\n'
STUB
chmod +x "$C/claude"
: > "$C/prompts.txt"
echo '[]' > "$C/covmap.json"          # pre-seeded so no `jac code map` runs inside the harness
awk 'BEGIN{for(i=1;i<=45;i++) printf "jac/jaclang/cli/f%02d.jac\n", i}' > "$C/reactive-files.txt"
(
    . "$NS_ROOT/lib/common.sh"; ns_load_config; . "$NS_ROOT/lib/tier2.sh"; . "$NS_ROOT/lib/reactive.sh"
    LOG_DIR="$C"; NS_PATHS_CLAUDE="$C/claude"; CEILING_PROMPTS="$C/prompts.txt"; export CEILING_PROMPTS
    date +%s > "$C/start_epoch"; reactive_main
) > "$C/out.txt" 2>&1 || fail "reactive_main failed on an over-ceiling merge day"
grep -q 'exceeds the 40-file ceiling' "$C/warnings.txt" \
    || fail "a 45-file merge day was audited whole with no truncation warning; the digest would not say the pass was partial"
grep -q 'f01.jac' "$C/prompts.txt" || fail "the truncated scope dropped the highest-ranked file"
grep -q 'f45.jac' "$C/prompts.txt" \
    && fail "the ceiling did not actually truncate: the 45th file reached the audit prompt"
[ "$(wc -l < "$C/reactive-summary.tsv" | tr -d ' ')" = "4" ] \
    || fail "reactive-summary.tsv is not one row per lens: $(cat "$C/reactive-summary.tsv")"

# RECONCILIATION B2 -- the reactive marker goes AFTER the task in the branch slug, never in front.
# ns_task_of_branch resolves the task BY PREFIX and that resolution is the sole input to
# protect_unless, so a `reactive-` prefix would fail every reactive branch at S4 and would never
# grant reactive-coverage-* its tests/** exemption. Driven against the REAL statement extracted
# from lib/tier2.sh and the REAL resolver, not grepped for.
# The `*)` case-arm prefix is stripped so the assignment can be eval'd on its own; everything to
# the right of it is byte-for-byte what lib/tier2.sh runs.
bslug_expr="$(grep -F 'bslug="$theme_task-$phase-${slug#"$theme_task"-}"' "$NS_ROOT/lib/tier2.sh" \
              | head -1 | sed -e 's/^[[:space:]]*\*)[[:space:]]*//' || true)"
case "$bslug_expr" in
    "") fail "lib/tier2.sh no longer builds the reactive branch slug as <task>-reactive-<hint>; section 22's B2 check would be vacuous" ;;
esac
built="$( theme_task=coverage; phase=reactive; slug="coverage-cli-gaps"; eval "$bslug_expr"; printf '%s' "$bslug" )"
case "$built" in
    "coverage-reactive-cli-gaps") : ;;
    *) fail "the reactive branch slug is '$built', not 'coverage-reactive-cli-gaps'" ;;
esac
resolved="$( . "$NS_ROOT/lib/common.sh"; ns_load_config; ns_task_of_branch "nightshift/2026-07-30/$built" || true )"
case "$resolved" in
    coverage) : ;;
    *) fail "ns_task_of_branch resolved '$built' to '$resolved', not 'coverage' -- this branch would fail S4 and never get its tests/** exemption" ;;
esac
# ...and the check is not vacuous: the shape RECONCILIATION B2 forbids must actually be unresolvable.
bad="$( . "$NS_ROOT/lib/common.sh"; ns_load_config; ns_task_of_branch "nightshift/2026-07-30/reactive-coverage-cli-gaps" || true )"
case "$bad" in
    "") : ;;
    *) fail "ns_task_of_branch resolved the forbidden 'reactive-<task>-' shape to '$bad'; the assertion above proves nothing" ;;
esac

# RECONCILIATION B6 -- the cycle phase must keep the EXACT names lib/dataset.sh and
# scripts/dataset.jac hardcode. A `-cycle` infix makes dataset_record_night return 0 recording
# nothing, which this repo already shipped once (ffdf856/e0db4a3).
sfx_cycle="$( . "$NS_ROOT/lib/tier2.sh"; ns_phase_suffix cycle )"
sfx_react="$( . "$NS_ROOT/lib/tier2.sh"; ns_phase_suffix reactive )"
case "$sfx_cycle" in
    "") : ;;
    *) fail "the cycle phase adds the suffix '$sfx_cycle' to findings/selection; lib/dataset.sh reads findings.json by name and would record nothing" ;;
esac
case "$sfx_react" in
    "-reactive") : ;;
    *) fail "the reactive phase suffix is '$sfx_react', so its artifacts would collide with the cycle phase's" ;;
esac
grep -q 'LOG_DIR"*/findings\.json' "$NS_ROOT/lib/dataset.sh" \
    || fail "lib/dataset.sh no longer reads findings.json by that name -- the B6 check above is pinned to the wrong fact"
# ...and the reactive artifact by ITS name too, on both sides. dataset_record_night used to gate on
# findings.json alone, so a night whose cycle audit produced nothing recorded nothing -- while the
# reactive pass it ignored had shipped 3 of the 6 branches of 2026-07-31.
grep -q 'LOG_DIR"*/findings-reactive\.json' "$NS_ROOT/lib/dataset.sh" \
    || fail "lib/dataset.sh does not look for findings-reactive.json, so a reactive-only night records nothing"
# The jac side is pinned BEHAVIOURALLY in section 36, not by a source grep: scripts/dataset.jac
# composes the name from ns_phase_suffix's own "-reactive" rather than spelling it, so a grep here
# would match this repo's favourite false positive -- a comment.

# RECONCILIATION B7 -- carry-over is consumed and rewritten by the CYCLE phase only. The reactive
# phase runs first; if it also owned carryover.json it would pack yesterday's deferrals into the
# reactive phase and then overwrite them with its own, spending them twice in one night.
R="$T/carry"; mkdir -p "$R/state"
# NS_ROOT is overridden below so tier2_select's "$NS_ROOT/state/carryover.json" lands in the
# sandbox; ns_jac resolves scripts/ relative to the same variable, so link the real ones in.
ln -sfn "$NS_ROOT/scripts" "$R/scripts"
printf '[{"file":"jac/jaclang/cli/carried.jac","rule":"dead-code","snippet":"s","summary":"x","task":"dead-code","theme_hint":"cli","est_loc_saved":40,"confidence":5,"risk":1,"complexity":"trivial","fingerprint":"carry1"}]\n' \
    > "$R/state/carryover.json"
cp "$R/state/carryover.json" "$R/carryover.before"
printf '[{"file":"jac/jaclang/scale/new.jac","rule":"dead-code","snippet":"s","summary":"y","task":"dead-code","theme_hint":"scale","est_loc_saved":10,"confidence":5,"risk":1,"complexity":"trivial","fingerprint":"react1"}]\n' \
    > "$R/findings-reactive.json"
(
    . "$NS_ROOT/lib/common.sh"; ns_load_config; . "$NS_ROOT/lib/tier2.sh"
    NS_ROOT="$R"; LOG_DIR="$R"; LEDGER="$R/ledger.jsonl"; STATE="$R/state.json"
    REPO="/nonexistent-repo"; date +%s > "$R/start_epoch"
    tier2_select reactive
) > "$R/out.txt" 2>&1 || fail "tier2_select reactive failed: $(cat "$R/out.txt")"
cmp -s "$R/state/carryover.json" "$R/carryover.before" \
    || fail "the REACTIVE phase rewrote carryover.json; yesterday's carry-over is consumed twice in one night and then lost (RECONCILIATION B7)"
[ -f "$R/selection-reactive.json" ] || fail "tier2_select reactive wrote no selection-reactive.json"
[ -e "$R/selection.json" ] && fail "tier2_select reactive wrote the CYCLE phase's selection.json"
grep -q 'carried.jac' "$R/selection-reactive.json" \
    && fail "the reactive phase packed yesterday's carry-over; spec section 4 says reactive OUTRANKS carry-over, not that it absorbs it"
echo "quiet day: 0 sessions, 0 failure rows, 0 artifacts, 1 log line; ceiling truncates; B2/B6/B7 hold"

echo "== 23. the digest must fire on EVERY exit path, and never abort the trap =="
# A digest that only sends on success is worse than none: silence would then mean both "fine"
# and "dead". ns_on_exit calls email_main unconditionally today -- this section is what keeps it
# that way through the next refactor, because losing it is invisible for weeks.
rm -rf .jac
grep -q "trap 'ns_on_exit' EXIT TERM INT" bin/nightshift.sh \
    || fail "the exit trap no longer covers TERM -- the watchdog kills with TERM, so the ceiling path would send no digest at all"
# email_main must be called from ns_on_exit OUTSIDE any conditional. Extract the trap function and
# assert the call is not nested: a `if [ "$code" -eq 0 ]` around it is the exact regression here.
trap_fn="$(sed -n '/^ns_on_exit() {/,/^}/p' bin/nightshift.sh)"
case "$trap_fn" in
    "") fail "could not extract ns_on_exit from bin/nightshift.sh -- section 23 would be vacuous" ;;
esac
case "$(printf '%s\n' "$trap_fn" | grep -c 'email_main')" in
    1) : ;;
    *) fail "ns_on_exit calls email_main $(printf '%s\n' "$trap_fn" | grep -c 'email_main') times; it must be exactly once, unconditionally" ;;
esac
printf '%s\n' "$trap_fn" | grep -q '^    email_main' \
    || fail "email_main is indented deeper than ns_on_exit's top level -- it is inside a conditional, so some exit paths send no digest"
printf '%s\n' "$trap_fn" | grep -q 'email_main .*|| true' \
    || fail "ns_on_exit's email_main call lost its '|| true'; under set -e a failing digest would abort the trap and skip ns_lock_release"

# Behavioural: email_main must return 0 even when EVERYTHING under it is broken. The grep above
# only proves the CALLER tolerates a failure; this proves email_main does not produce one, which is
# what keeps ns_lock_release reachable if that '|| true' is ever lost.
# A SEPARATE bash PROCESS, not a `( … ) || fail` subshell. bash suspends errexit for the entire
# dynamic extent of anything on the left of a `||`, subshells included -- so the obvious form
# cannot fail for a mid-function abort and is exactly the "assertion that cannot fail" this
# project keeps shipping. Mutation-confirmed: restoring the unguarded run-summary.json write is
# caught in this form and passes in the other.
NS_ROOT="$NS_ROOT" bash -c 'set -euo pipefail
    . "$NS_ROOT/lib/common.sh"; ns_bootstrap_jac; . "$NS_ROOT/lib/email.sh"
    LOG_DIR="/nonexistent/definitely-not-here"; NS_DATE=2026-01-02
    osascript() { return 0; }
    email_main' > /dev/null 2>&1 \
    || fail "email_main returned nonzero with an unusable LOG_DIR; it runs inside the EXIT trap and must never abort it"
# ...and the logging primitives it calls must not abort either -- they are also ns_die's, on the
# earliest failure paths where $LOG_DIR does not exist yet.
NS_ROOT="$NS_ROOT" bash -c 'set -euo pipefail
    . "$NS_ROOT/lib/common.sh"
    LOG_DIR="/nonexistent/definitely-not-here"
    ns_log X "probe"; ns_warn "probe"; ns_fail "probe" "probe"
    printf "still alive\\n"' > /dev/null 2>&1 \
    || fail "ns_log/ns_warn/ns_fail abort when \$LOG_DIR is unwritable; ns_die and email_main both call them on exactly that path"

# ...and the NS_DRY_RUN seam must render without touching a socket. Run it with the credentials
# deliberately UNSET: a dry-run that tried to send would fail on the live credential check.
D="$T/dryrun"; mkdir -p "$D"
NS_ROOT="$NS_ROOT" bash -c 'set -euo pipefail
    . "$NS_ROOT/lib/common.sh"; ns_load_config; . "$NS_ROOT/lib/email.sh"
    LOG_DIR="$1"; NS_DATE=2026-01-02; NS_DRY_RUN=1
    unset SMTP_USER SMTP_PASS
    email_main' _ "$D" > "$D/out.txt" 2>&1 \
    || fail "email_main failed in dry-run with no credentials; the NS_DRY_RUN seam is not holding"
[ -e "$D/SMTP_RECEIPT" ] && fail "a DRY-RUN produced an SMTP receipt -- it opened a real socket"
[ -e "$D/EMAIL_FAILED" ] && fail "a dry-run digest was reported as a failed send"
[ -f "$D/run-summary.json" ] || fail "email_main did not persist run-summary.json in dry-run"
# The rendered message must actually BE the multipart digest, not an empty shell. It is base64 (the
# body carries '·' and '—'), so the check decodes rather than grepping the wire form -- a grep for
# '<table' passes vacuously against a transfer-encoded part and would have proved nothing.
grep -q 'Content-Type: multipart/alternative' "$D/out.txt" \
    || fail "the dry-run render is not multipart/alternative: $(head -5 "$D/out.txt")"
python3 - "$D/out.txt" <<'PY' || fail "the dry-run render does not contain a real HTML digest"
import email, sys
m = email.message_from_string(open(sys.argv[1]).read())
parts = m.get_payload()
assert m.get_content_subtype() == "alternative", m.get_content_subtype()
assert parts[0].get_content_type() == "text/plain"
assert parts[1].get_content_type() == "text/html"
html = parts[1].get_payload(decode=True).decode("utf-8", "replace")
assert "<table" in html and "</html>" in html, html[:200]
PY
echo "digest fires unconditionally, cannot abort the trap, and stays offline in dry-run"

echo "== 24. window: plist StartCalendarInterval and [budgets].wallclock_min are one window =="
# Two tracked files state one window. A mismatch does not fail loudly -- bin/nightshift.sh's
# watchdog TERMs the run wallclock_min minutes after start, so a 23:00 fire against a stale
# wallclock_min just ends the night early and reports a clean timeout. Both files are TRACKED, so
# this check can never skip for a host reason (unlike section 5, which skips without work/repo).
#
# Section 24, not 11: RECONCILIATION.md allocates 11-14 to Plan 2, 15-18 to Plan 3, 19-23 to Plan 4
# and 24 to Plan 5, because all four plans were written independently and all four said "11".
ns_hour="$(sed -n 's/.*<key>Hour<\/key><integer>\([0-9]*\)<\/integer>.*/\1/p' \
    config/com.nightshift.installed.plist | head -1)"
ns_wall="$(sed -n 's/^wallclock_min *= *\([0-9]*\).*/\1/p' config/nightshift.toml | head -1)"
[ -n "$ns_hour" ] && [ -n "$ns_wall" ] || fail "could not read the fire hour or wallclock_min"
[ "$(( ns_wall % 60 ))" -eq 0 ] || fail "wallclock_min=$ns_wall is not a whole number of hours"
[ "$(( (ns_hour + ns_wall / 60) % 24 ))" -eq 7 ] \
    || fail "window ends at $(( (ns_hour + ns_wall / 60) % 24 )):00, not 07:00 (spec section 4): fire hour $ns_hour + ${ns_wall}m"
# The plist that launchd runs must be the one this section just validated. Checking only the
# window would leave the whole Task 4 change inert if the osascript form were still in the file:
# the fire hour and the ceiling would agree perfectly about a plist that execs the OLD tree.
#
# Matched on <string> ELEMENTS, never on the bare word: this plist's own comment explains at length
# what the osascript indirection was and why it went, so a plain `grep -q osascript` fails against
# the correct file forever -- which is how a tripwire gets deleted rather than fixed. (Caught by
# running it: the first version of this check went red on the very plist it was written to bless.)
# Section 9b's "comment lines stripped first" note is the same lesson in the same file.
# `|| true` plus an explicit empty check, not a bare assignment: a plist with no <string> elements
# makes grep exit 1, and under this file's `set -e` the assignment alone would kill the harness with
# a bare status and no message. Failing closed is right; failing closed SILENTLY is how a section
# gets blamed on flakiness and deleted. Every `case` below would also match vacuously against "".
ns_plist_args="$(grep '<string>' config/com.nightshift.installed.plist || true)"
case "$ns_plist_args" in
    "") fail "config/com.nightshift.installed.plist has no <string> elements at all -- the plist checks below would every one of them pass against an empty string" ;;
esac
case "$ns_plist_args" in
    *osascript*) fail "the tracked plist still EXECUTES osascript; that indirection exists only for an external-volume tree and would exec whatever path is baked into its AppleScript" ;;
esac
case "$ns_plist_args" in
    *'/nightshift/bin/nightshift.sh'*) : ;;
    *) fail "the tracked plist does not exec a .../nightshift/bin/nightshift.sh" ;;
esac
case "$ns_plist_args" in
    */Volumes/*) fail "the tracked plist points at an external volume again; macOS TCC hangs a headless launchd agent that touches one, across every identity it forks" ;;
esac
# The fired-date log is the ONLY evidence that separates "launchd fired and the run died" from
# "launchd never fired", and lib/preflight.sh's two missed-night classes are built on it. It is
# written by the plist and read by preflight, so neither file alone would notice the link breaking:
# assert BOTH ends name the same path.
case "$ns_plist_args" in
    *nightshift-fired.log*) : ;;
    *) fail "the tracked plist no longer appends to nightshift-fired.log; lib/preflight.sh's fired-vs-never-fired classification has no input without it" ;;
esac
grep -q 'Library/Logs/nightshift-fired.log' lib/preflight.sh \
    || fail "lib/preflight.sh no longer reads ~/Library/Logs/nightshift-fired.log, but the plist still writes it -- the two ends of the missed-night evidence chain have drifted apart"
# Both missed-night classes must exist. The never-fired one is the whole point: 2026-07-28 fired
# zero times and was invisible to the old fire-line-driven loop, because an absence of evidence
# cannot appear in a list of events.
grep -q 'NEVER FIRED' lib/preflight.sh \
    || fail "lib/preflight.sh lost the never-fired missed-night class; a schedule that stops firing is silent again"
grep -q 'grep -qxF' lib/preflight.sh \
    || fail "lib/preflight.sh no longer matches the fire log with grep -qxF; a substring/regex match reports a night that never fired as 'fired and died'"
# The direct-invocation plist runs the harness under launchd's environment rather than inside a
# Terminal login session, which is what made environment completeness load-bearing. `claude` looks
# its credentials up by $USER and answers "Not logged in" with USER unset -- an EX_AUTH death whose
# message points at the wrong thing. Measured while rehearsing this plan. Behavioural check, not a
# grep-for-a-grep: drive the REAL guard with USER unset and demand it dies.
usr_rc=0
( . "$NS_ROOT/lib/common.sh" 2>/dev/null; . "$NS_ROOT/lib/preflight.sh"
  LOG_DIR="$(mktemp -d)"; unset USER
  [ -n "${USER:-}" ] || ns_die "$EX_BUG" "probe" ) >/dev/null 2>&1 || usr_rc=$?
case "$usr_rc" in
    70) : ;;
    *) fail "the USER guard's own shape no longer dies EX_BUG (got rc=$usr_rc)" ;;
esac
grep -q 'USER is unset' lib/preflight.sh \
    || fail "lib/preflight.sh dropped the USER guard; under the direct-invocation plist a stripped environment makes claude report 'Not logged in' and the night dies EX_AUTH pointing at the auth instead of the environment"
# The other half of the same class: work/repo's git hooks are `exec jac precommit --staged --verify`
# and the apply session is granted Bash(jac fmt *) / Bash(jac check *) / Bash(jac test *) -- all
# bare. Under the old osascript plist the harness inherited a login shell's PATH and this was free;
# under the direct-invocation plist it is not, and the failure is a `git commit` exit 1 with no
# [FATAL] line. bin/nightshift.sh must therefore put the repo binary's dir on PATH, and preflight
# must refuse to start without it.
grep -q 'export PATH="\$(dirname "\$NS_PATHS_JAC_REPO")' bin/nightshift.sh \
    || fail "bin/nightshift.sh no longer puts the target repo's jac dir on PATH; work/repo's git hooks run 'exec jac' and launchd's PATH has none, so every git commit in the nightly path dies with a bare status"
# Behavioural, and EXTRACTED from the shipped lib/preflight.sh rather than re-typed, so editing the
# real guard changes this test's input. (The first version of this check grepped the guard's error
# MESSAGE and went red against correct code: the message lives in a double-quoted string where the
# backticks are backslash-escaped, so the file text is `no bare \`jac\` on PATH` and a literal
# pattern misses it. Matching prose is how a tripwire ends up asserting its own typography.)
sed -n '/^    local bare_jac$/,/^    ns_log S0 "bare jac/p' lib/preflight.sh > "$T/barejac.sh"
case "$(grep -c 'ns_die' "$T/barejac.sh")" in
    2) : ;;
    *) fail "could not extract the bare-jac guard from lib/preflight.sh (expected its two ns_die arms) -- the drives below would be vacuous. Has the guard been deleted?" ;;
esac
bj_drive() {           # bj_drive <label> <want-rc> <PATH> <NS_PATHS_JAC_REPO>
    local label=$1 want=$2 p=$3 repo=$4 got=0
    (
        . "$NS_ROOT/lib/common.sh" 2>/dev/null
        LOG_DIR="$T/barejac-logs"; mkdir -p "$LOG_DIR"
        PATH="$p"; NS_PATHS_JAC_REPO="$repo"
        . "$T/barejac.sh"
    ) >/dev/null 2>&1 || got=$?
    case "$got" in
        "$want") : ;;
        *) fail "bare-jac guard '$label': expected rc=$want, got rc=$got" ;;
    esac
}
mkdir -p "$T/fakebin" && printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/jac" && chmod +x "$T/fakebin/jac"
mkdir -p "$T/otherbin" && printf '#!/bin/sh\nexit 0\n' > "$T/otherbin/jac" && chmod +x "$T/otherbin/jac"
# no jac anywhere on PATH -> the git hooks' `exec jac` would fail and take the night with it
bj_drive "no jac on PATH" 70 "$T/empty" "$T/fakebin/jac"
# a jac that is NOT the target repo's binary -> worse than none: the hooks and the agent's
# Bash(jac …) tools would run a different compiler than the gates do
bj_drive "wrong jac on PATH" 70 "$T/otherbin" "$T/fakebin/jac"
# the healthy case must PASS, or the two rejections above prove nothing
bj_drive "correct jac on PATH" 0 "$T/fakebin" "$T/fakebin/jac"
# ...and that the PATH line runs AFTER ns_load_config, or $NS_PATHS_JAC_REPO is unbound under set -u.
ns_cfg_ln="$(grep -n '^ns_load_config$' bin/nightshift.sh | head -1 | cut -d: -f1)"
ns_path_ln="$(grep -n 'export PATH="\$(dirname "\$NS_PATHS_JAC_REPO")' bin/nightshift.sh | head -1 | cut -d: -f1)"
case "$ns_cfg_ln" in ''|*[!0-9]*) fail "could not locate ns_load_config in bin/nightshift.sh" ;; esac
case "$ns_path_ln" in ''|*[!0-9]*) fail "could not locate the jac PATH prepend in bin/nightshift.sh" ;; esac
[ "$ns_cfg_ln" -lt "$ns_path_ln" ] \
    || fail "the jac PATH prepend (line $ns_path_ln) runs BEFORE ns_load_config (line $ns_cfg_ln); \$NS_PATHS_JAC_REPO is unbound there and set -u would kill the run"
echo "window ok: fires ${ns_hour}:00, ceiling ${ns_wall}m, ends 07:00; direct invocation, fire log intact"

echo "== 25. jac-check baseline: a branch that DELETES a .jac file must not kill the night =="
# THE case: `dead-code` is task #1 in the cycle and DELETING a file is its happy path. The old
# baseline swap put every changed .jac on the main side, so for a deleted path it ran
#     git checkout main -- <path>     # re-creates it, staged as A
#     git checkout HEAD -- <path>     # "pathspec ... did not match any file(s) known to git", rc=1
# and the (correct, load-bearing) restore guard turned that into ns_die -- killing the whole night
# at S4. Reproduced on 2026-07-30 against work/repo's own
# nightshift/2026-07-30/dead-code-orphan-nongpt, and on a MIXED branch the failed batch restore also
# left main's content in the worktree for the file the branch really did modify, which is the
# "gates main and calls it the branch" failure the guard exists to prevent.
#
# Driven against the REAL stage, extracted out of the shipped lib/verify.sh rather than re-typed
# (same technique as section 24's bare-jac guard), over a scratch git repo with tiny .jac files and
# the harness's own jac as $NS_PATHS_JAC_REPO -- so this section costs ~4s, never touches work/repo,
# and can never SKIP for a host reason. Each probe runs as its own `bash` process: this file's `set
# -e` is suspended for the entire left side of `||`, so an in-process subshell would hide any death
# that is not an explicit exit.
CK="$T/checkstage"; mkdir -p "$CK"
{
    echo 'ns_check_stage() {'
    # step 2 of verify_branch: the whole jac-check baseline-diff stage
    awk '/^    local changed_jac changed_all changed_rc=0/{p=1} /^    # 3\. FAST CI-mirror jobs/{p=0} p' lib/verify.sh
    # ...and the PR-body line it feeds, which is where a mis-keyed summary would claim "jac check ✓"
    # for a branch the checker was never handed a single file from
    awk '/^    local check_line/{p=1} /^    case "\$suites" in/{p=0} p' lib/verify.sh
    echo '    printf "CHECK_LINE=%s\n" "$check_line"'
    echo '    return 0'
    echo '}'
} > "$CK/stage.sh"
# Vacuity guards on the extraction itself. Every assertion below is only as good as what got
# extracted: an anchor that stops matching yields a two-line no-op function that returns 0 for
# every probe and passes this entire section while testing nothing.
bash -n "$CK/stage.sh" || fail "the stage extracted from lib/verify.sh does not parse; section 25 would be testing a syntax error"
[ "$(wc -l < "$CK/stage.sh")" -ge 40 ] \
    || fail "only $(wc -l < "$CK/stage.sh") lines extracted from lib/verify.sh -- the awk anchors no longer match the shipped stage, so section 25's probes would drive an empty function"
for ck_need in 'checkgate gate' 'assert_check_ran' 'check_line'; do
    grep -q "$ck_need" "$CK/stage.sh" \
        || fail "the extracted stage contains no '$ck_need'; section 25 is not driving the real jac-check gate"
done

K="$CK/repo"
git init -q "$K"
# `git init -b main` is 2.28+; the symbolic-ref form works everywhere and, unlike relying on
# init.defaultBranch, cannot leave this repo on `master` -- where every `... main` below would fail
# and take the section with it for a reason that has nothing to do with the code under test.
git -C "$K" symbolic-ref HEAD refs/heads/main
git -C "$K" config user.email nightshift@localhost
git -C "$K" config user.name nightshift-harness
git -C "$K" config commit.gpgsign false
# keep.jac carries ONE pre-existing error on main, so the baseline diff has something to be
# baseline-diff ABOUT, and a MARKER line inside the error's printed context. The marker is what
# makes the main-side swap positively observable: "the two captures differ" would also be satisfied
# by a swap that half-happened.
printf 'with entry {\n    marker: str = "MAIN-ONLY-MARKER";\n    bad: int = "pre-existing";\n    print(marker);\n    print(bad);\n}\n' > "$K/keep.jac"
printf 'with entry {\n    print("dead code");\n}\n' > "$K/dead.jac"
git -C "$K" add -A && git -C "$K" commit -q -m "main"
ck_mod() { sed -i.bak 's/MAIN-ONLY-MARKER/BRANCH-ONLY-MARKER/' "$K/keep.jac" && rm -f "$K/keep.jac.bak"; }
git -C "$K" checkout -q -b del-only main && git -C "$K" rm -q dead.jac && git -C "$K" commit -q -m d
git -C "$K" checkout -q -b del-mod  main && git -C "$K" rm -q dead.jac && ck_mod && git -C "$K" commit -q -a -m dm
git -C "$K" checkout -q -b mod-only main && ck_mod && git -C "$K" commit -q -a -m m
git -C "$K" checkout -q -b mod-new  main && ck_mod \
    && printf 'with entry {\n    alsobad: int = "second distinct error";\n    print(alsobad);\n}\n' >> "$K/keep.jac" \
    && git -C "$K" commit -q -a -m mn
git -C "$K" checkout -q main
# Every probe must actually BE the shape it claims. A `git rm` that silently no-ops (it has, in this
# project, when a hook rejected the commit) leaves four identical branches and four green probes.
[ "$(git -C "$K" diff --name-status main...del-only)" = "$(printf 'D\tdead.jac')" ] \
    || fail "the del-only probe branch does not delete dead.jac: $(git -C "$K" diff --name-status main...del-only)"
[ "$(git -C "$K" diff --name-status main...del-mod | tr '\n' ' ')" = "$(printf 'D\tdead.jac M\tkeep.jac ')" ] \
    || fail "the del-mod probe branch is not a deletion PLUS a modification: $(git -C "$K" diff --name-status main...del-mod | tr '\n' ' ')"
[ "$(git -C "$K" diff --name-status main...mod-only)" = "$(printf 'M\tkeep.jac')" ] \
    || fail "the mod-only probe branch does not modify keep.jac"

cat > "$CK/run.sh" <<'CKRUN'
#!/usr/bin/env bash
# generated by bin/test-harness.sh section 25; argv: <NS_ROOT> <scratch repo> <stage.sh> <branch>
set -uo pipefail
NS_ROOT="$1"; CK_REPO="$2"; CK_STAGE="$3"; branch="$4"
. "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/cimirror.sh"; . "$NS_ROOT/lib/verify.sh"
ns_bootstrap_jac
REPO="$CK_REPO"
NS_REPO_DEFAULT_BRANCH=main
NS_PATHS_JAC_REPO="$NS_PATHS_JAC"        # 0.16.1 prints the same run summary + error shape
LOG_DIR="$CK_REPO/../logs"; mkdir -p "$LOG_DIR"
. "$CK_STAGE"
# verify_red is the "reject this branch" seam; stub it so the reason is observable and the probe
# does not need the ledger. The stage still decides WHETHER to call it.
verify_red() { printf 'VERIFY_RED %s\n' "$2"; }
theme="-"; on_red="noop"; suites=""
git -C "$REPO" checkout -q "$branch" || { echo "CHECKOUT-FAILED"; exit 97; }
rm -rf "$REPO/.jac"
rc=0
ns_check_stage || rc=$?
printf 'WORKTREE=[%s]\n' "$(git -C "$REPO" status --porcelain | tr '\n' ';')"
printf 'STAGE_RC=%s\n' "$rc"
exit "$rc"
CKRUN
ck_drive() {           # ck_drive <branch> <want-rc>
    local br=$1 want=$2 got=0
    bash "$CK/run.sh" "$NS_ROOT" "$K" "$CK/stage.sh" "$br" > "$CK/$br.out" 2>&1 || got=$?
    case "$got" in
        "$want") : ;;
        *) fail "jac-check stage on the '$br' probe: expected rc=$want, got rc=$got -- $(tr '\n' ' ' < "$CK/$br.out")" ;;
    esac
    # A branch left half-swapped is the whole point of the guard this stage carries: EVERY probe,
    # green or red, must hand the worktree back exactly as it found it.
    grep -qx 'WORKTREE=\[\]' "$CK/$br.out" \
        || fail "the jac-check stage left $REPO dirty after the '$br' probe: $(grep '^WORKTREE=' "$CK/$br.out"). Every stage after it would gate a tree that is neither the branch nor main."
}

# --- A. deletion only: the night must SURVIVE, and must not claim the checker ran ---------------
ck_drive del-only 0
grep -q 'deleted on this branch, so excluded from both sides' "$CK/del-only.out" \
    || fail "the deletion-only probe did not report its excluded path; the partition is gone and this section's other probes prove nothing: $(cat "$CK/del-only.out")"
grep -q 'CHECK_LINE=jac check (only deletions:' "$CK/del-only.out" \
    || fail "a branch whose only .jac change is a DELETION published '$(grep '^CHECK_LINE=' "$CK/del-only.out")' -- the checker was handed zero files, so anything resembling a tick is this project's dominant defect in the one line that reaches the PR"
[ ! -s "$CK/logs/check-branch-del-only.txt" ] \
    || fail "the branch-side capture for a deletion-only branch is not empty; \$NS_PATHS_JAC_REPO was handed a path that does not exist on the branch, and a could-not-open error would be scored as a type error"

# --- B. deletion MIXED with a modification: the modification is still gated, for real ------------
ck_drive del-mod 0
grep -q 'CHECK_LINE=jac check ✓ · not checked (deleted on branch): dead.jac' "$CK/del-mod.out" \
    || fail "the mixed probe's PR line does not name the file it could not check: $(grep '^CHECK_LINE=' "$CK/del-mod.out")"
# The two captures must be BRANCH content and MAIN content respectively. Asserting only that they
# differ would also pass for a swap that never happened (the stage would then have compared the
# branch against itself -- a gate that structurally cannot fail).
grep -q 'BRANCH-ONLY-MARKER' "$CK/logs/check-branch-del-mod.txt" \
    || fail "the branch-side capture of the mixed probe does not contain the branch's own content"
grep -q 'MAIN-ONLY-MARKER'   "$CK/logs/check-main-del-mod.txt" \
    || fail "the main-side capture of the mixed probe does not contain main's content -- the baseline swap did not happen, so 'no NEW type errors' could never be violated"
grep -q 'BRANCH-ONLY-MARKER' "$CK/logs/check-main-del-mod.txt" \
    && fail "the main-side capture contains BRANCH content: the swap silently failed and the branch was compared against itself"
grep -q 'MAIN-ONLY-MARKER' "$K/keep.jac" \
    && fail "the mixed probe left MAIN's content in the worktree for the file the branch modified; every stage after S4 would gate main and score it as the branch"

# --- C. the plain modification path must be untouched by all of the above -----------------------
ck_drive mod-only 0
grep -qx 'CHECK_LINE=jac check ✓' "$CK/mod-only.out" \
    || fail "an ordinary modification no longer publishes a plain 'jac check ✓': $(grep '^CHECK_LINE=' "$CK/mod-only.out")"

# --- D. ...and the gate must still be ABLE to red. Without this, A-C are satisfied by a stage
#        that returns 0 unconditionally. ---------------------------------------------------------
ck_drive mod-new 1
grep -q 'VERIFY_RED jac check: new type errors vs main' "$CK/mod-new.out" \
    || fail "a branch that introduces a genuinely new type error was not rejected for that reason: $(cat "$CK/mod-new.out")"
grep -q 'second distinct error' "$CK/logs/check-branch-mod-new.txt" \
    || fail "the new error never reached the branch-side capture, so the rejection above cannot have been caused by it"
rm -rf .jac
echo "deleted .jac files: excluded from both baseline sides, named in the PR line, worktree returned clean; new errors still red"

echo "== 26. an audit session that DIED is never salvaged into '0 findings' =="
# THE 2026-07-31 DEFECT. Three reactive lenses came back is_error=true / subtype=error_max_turns /
# num_turns=46 against a cap of 45, with no .result field at all. The corrective re-prompt -- which
# exists to repair MALFORMED JSON FROM A SESSION THAT FINISHED -- was handed an empty "Previous
# output" block, answered `[]`, and the pipeline logged "salvaged via corrective re-prompt — 0
# findings" three times: $18.96 of truncated audit filed as three clean audits that found nothing.
# That is this project's dominant defect class, "did not run" scoring as "passed".
#
# Driven against the REAL tier2_audit_shard with a stub claude, over the REAL envelope:
# fixtures/session-turn-capped.json is logs/2026-07-31/audit-reactive-abstraction.json byte for byte.
rm -rf .jac
S26="$(mktemp -d)"
mkdir -p "$S26/repo" "$S26/reply"
cat > "$S26/claude" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$STUB_CALLS" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STUB_CALLS"
printf '%s\n' "$*" >> "$STUB_ARGV"
if [ -f "$STUB_REPLY_DIR/$n" ]; then cat "$STUB_REPLY_DIR/$n"; else cat "$STUB_REPLY_DIR/default"; fi
STUB
chmod +x "$S26/claude"

# A separate bash PROCESS, not `( … ) || fail`: bash suspends errexit for the whole dynamic extent
# left of a `||`, so the subshell form cannot see a mid-function abort at all and the rc it reports
# would be the function's `return`, never the abort. Prints "rc=<n> calls=<n>".
audit_probe() {        # audit_probe <dir>
    local d=$1 rc=0
    : > "$d/calls"; : > "$d/argv"; rm -f "$d/failed.tsv" "$d/findings-probe.json" "$d/spend.txt"
    NS_ROOT="$NS_ROOT" bash -c 'set -euo pipefail
        . "$NS_ROOT/lib/common.sh"; ns_load_config; . "$NS_ROOT/lib/tier2.sh"
        LOG_DIR="$1"; REPO="$1/repo"; NS_PATHS_CLAUDE="$1/claude"
        export STUB_CALLS="$1/calls" STUB_ARGV="$1/argv" STUB_REPLY_DIR="$1/reply"
        date +%s > "$1/start_epoch"
        tier2_audit_shard probe "jac/jaclang/cli/a.jac" dead-code' _ "$d" > "$d/out.txt" 2>&1 || rc=$?
    printf 'rc=%s calls=%s' "$rc" "$(cat "$d/calls" 2>/dev/null || echo 0)"
}

# --- A. the real turn-capped envelope: reported as a dead lens, never salvaged ------------------
cp fixtures/session-turn-capped.json "$S26/reply/default"
case "$(audit_probe "$S26")" in
    "rc=1 calls=2") : ;;
    # calls=2 is the whole point: two audit attempts and ZERO corrective re-prompts. calls=4 is the
    # old behaviour (a salvage session fired after each dead attempt) and would mean the re-prompt
    # is still being handed a session with no output.
    *) fail "a turn-capped audit did not fail cleanly with exactly its two attempts: $(audit_probe "$S26") -- $(cat "$S26/out.txt")" ;;
esac
grep -q 'DID NOT FINISH (max_turns)' "$S26/out.txt" \
    || fail "the log line does not say the session never finished, or does not name why: $(cat "$S26/out.txt")"
grep -q 'salvaged' "$S26/out.txt" \
    && fail "a session that died at the turn cap still went through the salvage path"
[ -e "$S26/findings-probe.json" ] \
    && fail "a dead audit left a findings file behind; the merge would count it as a lens that ran"
grep -q 'never finished' "$S26/failed.tsv" \
    || fail "failed.tsv does not distinguish 'never finished' from 'malformed': $(cat "$S26/failed.tsv" 2>/dev/null)"
# ...and the money was still recorded. A session that produced nothing usable still spent $7.89.
[ "$(wc -l < "$S26/spend.txt" | tr -d ' ')" = "2" ] \
    || fail "the two dead attempts put $(wc -l < "$S26/spend.txt" | tr -d ' ') rows on the night's cost ledger, not 2"
grep -q '^145510c4-6438-4e35-a2a2-f678b6332f17	7\.8939' "$S26/spend.txt" \
    || fail "the ledger row is not <session_id>TAB<cost> off the real envelope: $(cat "$S26/spend.txt")"
# ...and the id is what makes the total honest: the same session recorded twice must not double it.
[ "$(sort -u "$S26/spend.txt" | wc -l | tr -d ' ')" = "1" ] \
    || fail "two attempts of one shard wrote two DISTINCT ledger rows; a retry that reuses a session id would inflate the night's total"
# ...and the audit session was finally given the budget flag it never had.
grep -q -- '--max-budget-usd' "$S26/argv" \
    || fail "the AUDIT session is still spawned with no --max-budget-usd; only apply sessions had one"

# --- B. ...and the salvage must still WORK, or A is satisfied by a guard that kills everything ---
# A completed session whose output is prose, repaired by a one-turn re-prompt. This is the ONLY
# shape the corrective re-prompt was ever for.
printf '%s\n' '{"type":"result","subtype":"success","terminal_reason":"completed","is_error":false,"num_turns":9,"total_cost_usd":0.5,"result":"I looked at the file and here is my answer in prose, sorry."}' > "$S26/reply/1"
printf '%s\n' '{"type":"result","subtype":"success","terminal_reason":"completed","is_error":false,"num_turns":1,"total_cost_usd":0.02,"result":"```json\n[{\"file\":\"jac/jaclang/cli/a.jac\",\"rule\":\"dead-code\",\"snippet\":\"def gone()\",\"summary\":\"unreferenced helper\",\"est_loc_saved\":12,\"confidence\":4,\"risk\":1,\"theme_hint\":\"dead-helper\",\"complexity\":\"mechanical\"}]\n```"}' > "$S26/reply/2"
case "$(audit_probe "$S26")" in
    "rc=0 calls=2") : ;;
    *) fail "a COMPLETED session with malformed JSON was no longer salvaged: $(audit_probe "$S26") -- $(cat "$S26/out.txt")" ;;
esac
grep -q 'salvaged malformed JSON from a COMPLETED session — 1 findings' "$S26/out.txt" \
    || fail "the salvage log line does not say the session had completed: $(cat "$S26/out.txt")"
[ "$(jac run scripts/parse_result.jac len < "$S26/findings-probe.json")" = "1" ] \
    || fail "the salvaged finding did not survive into findings-probe.json"
rm -f "$S26/reply/1" "$S26/reply/2"

# --- C. a 0-byte envelope (timebox kill) is the same class of failure, not a salvage either -----
printf '' > "$S26/reply/default"
case "$(audit_probe "$S26")" in
    "rc=1 calls=2") : ;;
    *) fail "a 0-byte envelope did not fail cleanly with exactly its two attempts: $(audit_probe "$S26")" ;;
esac
grep -q 'DID NOT FINISH (no output' "$S26/out.txt" \
    || fail "a timebox kill is not reported as a session that did not finish: $(cat "$S26/out.txt")"
grep -q 'never finished (no-output)' "$S26/failed.tsv" \
    || fail "failed.tsv did not carry the timebox kill's reason: $(cat "$S26/failed.tsv" 2>/dev/null)"

# --- D. a session that finished but left NO .result must not buy a repair session either -------
# The re-prompt builds `Previous output:` from `parse_result field result`. That is empty exactly
# when the parse error was "envelope has no .result field", so the case that most needs repairing
# is the case the repair session is handed nothing to repair -- and the model's REFUSAL, illustrated
# with an empty array, parses as a clean "0 findings". This arm is the guard on that, driven with an
# envelope that passes the is_error check and still carries no output, so C's classifier cannot be
# what catches it.
printf '%s\n' '{"type":"result","subtype":"success","terminal_reason":"completed","is_error":false,"num_turns":40,"total_cost_usd":6.1155,"session_id":"empty-result-probe","result":""}' > "$S26/reply/default"
case "$(audit_probe "$S26")" in
    "rc=1 calls=2") : ;;
    *) fail "a completed session with no .result still bought repair sessions: $(audit_probe "$S26") -- $(cat "$S26/out.txt")" ;;
esac
grep -q 'NO output to correct' "$S26/out.txt" \
    || fail "the refusal to run a repair with an empty Previous-output block was not logged: $(cat "$S26/out.txt")"
[ -e "$S26/findings-probe.json" ] \
    && fail "an audit with no output at all left a findings file behind"
rm -rf .jac
echo "a dead audit session fails as a dead lens; only a COMPLETED session's bad JSON is salvaged"

echo "== 27. the night cost ceiling actually stops work =="
# 2026-07-31 spent $76.55 across 27 real sessions in 97 minutes of a 480-minute window, $67.36 of it
# on audits, and nothing in the harness could have stopped it: --max-budget-usd was passed to apply
# sessions only, and a per-session cap times fifty sessions is not a brake. Driven, with a claude
# stub that records any invocation -- nothing here can reach a real session even if the guard breaks.
rm -rf .jac
S27="$(mktemp -d)"
mkdir -p "$S27/repo"
cat > "$S27/claude" <<'STUB27'
#!/usr/bin/env bash
touch "$STUB27_CALLED"
printf '{"is_error":false,"total_cost_usd":0.01,"result":"```json\n[]\n```"}\n'
STUB27
chmod +x "$S27/claude"
printf 'jac/jaclang/cli/a.jac\njac/jaclang/cli/b.jac\n' > "$S27/reactive-files.txt"
echo '[]' > "$S27/covmap.json"          # pre-seeded so no `jac code map` runs inside the harness

# ns_spend_check's contract, over the REAL cost the harness would have recorded.
spend_probe() {        # spend_probe <ledger-contents-or-EMPTY> -> "rc=<n> <printed>"
    local body=$1 rc=0 out
    rm -f "$S27/spend.txt"
    case "$body" in EMPTY) : ;; *) printf '%s\n' "$body" > "$S27/spend.txt" ;; esac
    out="$(NS_ROOT="$NS_ROOT" bash -c 'set -euo pipefail
        . "$NS_ROOT/lib/common.sh"; ns_load_config; LOG_DIR="$1"; ns_spend_check' _ "$S27" 2>&1)" || rc=$?
    printf 'rc=%s %s' "$rc" "$out"
}
case "$(spend_probe EMPTY)" in
    "rc=0 0.00 of 50.00") : ;;
    *) fail "a night that has spent nothing is not under the ceiling: $(spend_probe EMPTY)" ;;
esac
case "$(spend_probe '73bdaaf7-45f7-4980-9d22-5588e3b730da	9.768192500000003')" in
    "rc=0 9.77 of 50.00") : ;;
    *) fail "one real session's cost was not summed correctly: $(spend_probe '73bdaaf7-45f7-4980-9d22-5588e3b730da	9.768192500000003')" ;;
esac
# the four real reactive-lens costs plus the eight real cycle-shard costs from 2026-07-31: $67.36,
# which is over the ceiling and is exactly the spend that had nothing stopping it.
NIGHT_0731="$(awk 'BEGIN{
    split("9.768192500000003 7.8939439999999985 6.1155 4.9464 5.7347195 4.7166 5.5215 4.6127 5.1156 4.6885 2.9578 5.0077", c, " ")
    for (i=1; i<=12; i++) printf "session-%02d\t%s\n", i, c[i]
}')"
case "$(spend_probe "$NIGHT_0731")" in
    "rc=3 67.08 of 50.00") : ;;
    *) fail "the real 2026-07-31 audit spend did not trip the ceiling: $(spend_probe "$NIGHT_0731")" ;;
esac
# THE DOUBLE COUNT, through the real reader: the same twelve sessions listed twice -- which is
# exactly what summing both audit-<name>.json and its meta-<name>.json byte-twin does -- must not
# move the total. That mistake is where "$152.82 across 50 sessions" came from; the night really
# cost $76.55 across 27 unique session_ids, and a brake that inflates stops a healthy night early.
case "$(spend_probe "$NIGHT_0731
$NIGHT_0731")" in
    "rc=3 67.08 of 50.00") : ;;
    *) fail "the ledger double-counted repeated session_ids: $(spend_probe "$NIGHT_0731
$NIGHT_0731")" ;;
esac
# ...and a ledger it cannot read fails CLOSED. A brake that cannot be evaluated must never read as
# "plenty left" -- that is this repo's dominant defect class pointed at the bill.
case "$(spend_probe 'sess	free')" in
    rc=0*) fail "an unreadable cost ledger read as 'budget left': $(spend_probe 'sess	free')" ;;
esac
# ...including a bare cost with no session id, which is the pre-dedupe ledger format: silently
# accepting it would let a stale spend.txt be summed with no way to notice the double count.
case "$(spend_probe '9.77')" in
    rc=0*) fail "a ledger row with no session_id read as 'budget left': $(spend_probe '9.77')" ;;
esac

# DRIVEN: over the ceiling, the reactive fan-out must schedule NOTHING.
lens_probe() {         # lens_probe <ledger-contents> -> "called=<yes|no>"
    rm -f "$S27/CLAUDE_WAS_CALLED" "$S27/warnings.txt" "$S27/run.log" "$S27/failed.tsv"
    printf '%s\n' "$1" > "$S27/spend.txt"
    NS_ROOT="$NS_ROOT" bash -c 'set -euo pipefail
        . "$NS_ROOT/lib/common.sh"; ns_load_config; . "$NS_ROOT/lib/tier2.sh"; . "$NS_ROOT/lib/reactive.sh"
        LOG_DIR="$1"; REPO="$1/repo"; NS_PATHS_CLAUDE="$1/claude"
        export STUB27_CALLED="$1/CLAUDE_WAS_CALLED"
        date +%s > "$1/start_epoch"; reactive_main' _ "$S27" > "$S27/out.txt" 2>&1 \
        || fail "reactive_main returned nonzero; a spent budget must not fail the night"
    if [ -e "$S27/CLAUDE_WAS_CALLED" ]; then printf 'called=yes'; else printf 'called=no'; fi
}
case "$(lens_probe "$(printf 'spent-it-all\t99.00')")" in
    "called=no") : ;;
    *) fail "the reactive pass started an audit session with the night's cost ceiling already spent" ;;
esac
grep -q 'NIGHT COST CEILING reached (99.00 of 50.00' "$S27/warnings.txt" \
    || fail "the brake fired silently, or without the numbers: $(cat "$S27/warnings.txt" 2>/dev/null)"
# ...and the positive control, without which the assertion above is satisfied by a harness that
# never schedules anything at all.
case "$(lens_probe "$(printf 'barely-started\t1.00')")" in
    "called=yes") : ;;
    *) fail "the reactive pass scheduled nothing with $48 of budget left; the brake is stuck on" ;;
esac
grep -q 'NIGHT COST CEILING' "$S27/warnings.txt" 2>/dev/null \
    && fail "the brake fired with $48 of budget left"

# ...and the CYCLE fan-out carries its own copy of the guard, which no reactive-pass assertion can
# reach. Without this arm that copy could be deleted and every test above would still pass -- the
# exact shape of vacuous guard this repo keeps shipping.
shard_probe() {        # shard_probe <ledger-row> -> "called=<yes|no>"
    rm -f "$S27/CLAUDE_WAS_CALLED" "$S27/warnings.txt" "$S27/failed.tsv" "$S27"/findings-*.json
    printf '%s\n' "$1" > "$S27/spend.txt"
    NS_ROOT="$NS_ROOT" bash -c 'set -euo pipefail
        . "$NS_ROOT/lib/common.sh"; ns_load_config; . "$NS_ROOT/lib/tier2.sh"
        LOG_DIR="$1"; REPO="$1/repo"; NS_PATHS_CLAUDE="$1/claude"
        export STUB27_CALLED="$1/CLAUDE_WAS_CALLED"
        NS_TASK_NAME=dead-code; NS_TASK_SCORING=loc_saved
        date +%s > "$1/start_epoch"; tier2_audit_all' _ "$S27" > "$S27/shards.txt" 2>&1 || true
    if [ -e "$S27/CLAUDE_WAS_CALLED" ]; then printf 'called=yes'; else printf 'called=no'; fi
}
case "$(shard_probe "$(printf 'spent-it-all\t99.00')")" in
    "called=no") : ;;
    *) fail "the cycle audit fan-out scheduled a shard with the night's cost ceiling already spent" ;;
esac
grep -q 'NIGHT COST CEILING reached (99.00 of 50.00' "$S27/warnings.txt" \
    || fail "the cycle fan-out's brake fired silently: $(cat "$S27/warnings.txt" 2>/dev/null)"
grep -q 'stopping the audit fan-out at' "$S27/warnings.txt" \
    || fail "the cycle fan-out's warning does not name where it stopped: $(cat "$S27/warnings.txt")"
# positive control, same reason as the reactive one above
case "$(shard_probe "$(printf 'barely-started\t1.00')")" in
    "called=yes") : ;;
    *) fail "the cycle audit fan-out scheduled nothing with $49 of budget left; its brake is stuck on" ;;
esac
rm -rf .jac
echo "the night ceiling is summed from real envelopes, fails closed, and stops the fan-out for real"

echo "== 28. the digest tells the truth about the night it describes =="
# 2026-07-31 delivered a real email to a real inbox saying, for a 97-minute night that pushed
# nothing: `clock: 0 of 480 min consumed (480 left)`, six live-looking links to
# github.com/DRY-RUN/pull/0 with no dry-run banner anywhere, and `abstraction: 0` / `coverage: 0`
# for two lenses that had died at the turn cap -- while `maintenance`, the ONE lens honestly flagged
# FAILED, was dropped from the `audited:` line altogether.
#
# EVERY ASSERTION BELOW IS ON THE RENDERED MESSAGE, decoded out of the MIME body. That is the whole
# point: every unit-level piece worked on 2026-07-31, and the lie only existed in the delivered text.
# The fixture is logs/2026-07-31 COPIED (never modified: it is the evidence), with only the two
# epoch files rewritten to make the clock deterministic.
rm -rf .jac
S28="$(mktemp -d)"
mkdir -p "$S28/logs" "$S28/drafts"
cp -R logs/2026-07-31/. "$S28/logs"
S28_NOW="$(date +%s)"
echo "$(( S28_NOW - 97 * 60 ))" > "$S28/logs/first_start_epoch"   # the night began 97 minutes ago
echo "$S28_NOW"                  > "$S28/logs/start_epoch"        # ...the re-fire started just now

# The two MIME parts are base64: the digest carries · and —, so MIMEText falls back to utf-8+base64
# (which is also why nobody eyeballing S6.log spotted the zeros). Decode both back to the text a
# human actually reads, and assert on THAT.
digest_render() {      # digest_render <log_dir> <drafts_dir> -> decoded text on stdout
    local d=$1 dr=$2 t; t="$(mktemp -d)"
    jac run scripts/sendmail.jac summarize "$d" "$dr" 2026-07-31 config/nightshift.toml > "$t/sum.json" \
        || fail "sendmail summarize failed over $d"
    jac run scripts/sendmail.jac render config/nightshift.toml < "$t/sum.json" > "$t/msg.txt" \
        || fail "sendmail render failed over $d"
    awk -v out="$t/part" 'BEGIN{n=0;inb=0}
        /^Content-Transfer-Encoding: base64/ {want=1; next}
        want && $0=="" {want=0; inb=1; n++; next}
        /^--=/ {inb=0; next}
        inb {print > (out n ".b64")}' "$t/msg.txt"
    [ -f "$t/part1.b64" ] || fail "the rendered message carried no base64 body part (over $d)"
    grep '^Subject:' "$t/msg.txt"
    for p in "$t"/part*.b64; do base64 -D < "$p"; echo; done
}
digest_render "$S28/logs" "$S28/drafts" > "$S28/text.txt"

# --- A. the clock describes the NIGHT, not the process that re-fired into it -------------------
grep -q 'clock: 97 of 480 min' "$S28/text.txt" \
    || fail "the digest's clock does not describe the 97-minute night: $(grep -n 'clock:' "$S28/text.txt" || echo '(no clock line at all)')"
grep -q '97 of 480 min consumed (383 left)' "$S28/text.txt" \
    || fail "the html clock line is not the night's: $(grep -n 'consumed' "$S28/text.txt" || true)"
grep -q '0 of 480 min consumed (480 left)' "$S28/text.txt" \
    && fail "the delivered digest still reports a 97-minute night as having consumed none of its window"

# --- B. a dry run says so, in the subject and above the stub links it is warning about ---------
# `DRY.RUN`, not `DRY RUN`: the subject is RFC-2047 q-encoded (=?utf-8?q?=5BDRY_RUN=5D_...) because
# the digest's own subject grammar uses ·, so the space arrives as an underscore.
grep -q '^Subject:.*DRY.RUN' "$S28/text.txt" \
    || fail "the subject line of a dry run's digest does not say DRY RUN: $(grep '^Subject:' "$S28/text.txt")"
grep -q 'DRY RUN — nothing was pushed' "$S28/text.txt" \
    || fail "the digest body carries no dry-run banner, for a night whose PR links are all stubs"
# ...and it is ABOVE the six #0 rows, not a footnote below 370 lines of body
[ "$(grep -n 'nothing was pushed' "$S28/text.txt" | head -1 | cut -d: -f1)" \
  -lt "$(grep -n 'DRY-RUN/pull/0' "$S28/text.txt" | head -1 | cut -d: -f1)" ] \
    || fail "the dry-run banner sits BELOW the stub PR links it exists to warn about"
# the stub links really are in this message -- otherwise the assertion above is vacuous
[ "$(grep -c 'DRY-RUN/pull/0' "$S28/text.txt")" -ge 6 ] \
    || fail "the fixture no longer carries the six stub PR links; B proves nothing"

# --- C. a lens that DIED never renders as a count, and the honest one is never dropped ---------
# All three dead lenses, by name, in the line that claims what was audited.
for lens in reactive-abstraction reactive-coverage reactive-maintenance; do
    grep -q "$lens: FAILED" "$S28/text.txt" \
        || fail "$lens is not reported as FAILED in the rendered digest: $(grep -n 'audited' "$S28/text.txt" | head -2)"
done
# `reactive-maintenance` wrote NO findings file, which is why the old glob dropped it entirely.
grep -q 'reactive-maintenance' "$S28/text.txt" \
    || fail "the one honestly-FAILED lens is still missing from the digest"
# ...and the two salvaged placeholders must not read as clean zeros anywhere in the message.
grep -q 'abstraction: 0' "$S28/text.txt" \
    && fail "a lens that died at the turn cap still renders as '0' in the delivered digest"
grep -q 'coverage: 0' "$S28/text.txt" \
    && fail "a lens that died at the turn cap still renders as '0' in the delivered digest"
# POSITIVE CONTROL, without which C is satisfied by a renderer that calls every scope FAILED and
# prints no counts at all: the lens that really ran, and the eight cycle shards, keep their numbers.
grep -q 'reactive-dead-code: 5 finding(s)' "$S28/text.txt" \
    || fail "the lens that genuinely ran lost its finding count"
grep -q 'compiler-core: 21 finding(s)' "$S28/text.txt" \
    || fail "the cycle shards lost their finding counts"

# --- D. ...and a REAL night carries none of B. -------------------------------------------------
# Same renderer, a log dir with a real PR row and no DRY_RUN marker. Without this arm the banner
# could be unconditional and every assertion above would still pass.
mkdir -p "$S28/real"
printf '{"number": 7301, "title": "t", "task": "dead-code", "url": "https://github.com/jaseci-labs/jac/pull/7301", "mirror": "green", "ci": "pending", "attempts": 0}\n' \
    > "$S28/real/prs.jsonl"
echo "$(( S28_NOW - 42 * 60 ))" > "$S28/real/first_start_epoch"
digest_render "$S28/real" "$S28/drafts" > "$S28/real.txt"
grep -q 'DRY.RUN' "$S28/real.txt" \
    && fail "a real night's digest is branded a dry run; the banner means nothing"
grep -q 'clock: 42 of 480 min' "$S28/real.txt" \
    || fail "the clock is not read for a night with no re-fire: $(grep -n 'clock:' "$S28/real.txt" || true)"
rm -rf .jac
echo "the digest's clock, its dry-run banner and its audited: line all come from the night's own artifacts"

echo "== 29. the selector packs against the clock it has, not a constant =="
# 2026-07-31: eight cycle shard audits cost $38.36 and produced 95 findings. deferred.jsonl holds
# 103 rows and ALL 103 say `over-night-budget`; not one says `no-clock-left`. The night had used 56
# of its 480 minutes at that moment. themes_per_night truncated 105 packed themes to 6 with no
# reference to the clock at all.
#
# Driven over the REAL merged findings set (logs/2026-07-31/findings-all.json, 112 findings = 95
# fresh + 17 carried) at the REAL remaining_min, with the REAL verify_estimate_min from
# state/state.json.
rm -rf .jac
S29="$(mktemp -d)"
printf '{"verify_estimate_min": 1}\n' > "$S29/state.json"
# Theme count comes from `selector split`, which prints one slug per theme -- the same reader
# tier2_apply drives the night from. Counting the selection's own array would let a selection that
# packs themes nothing can split still read as green.
sel() {                # sel <remaining_min> [config] -> "themes=<n> clockshed=<n>"
    local rem=$1 cfg=${2:-config/nightshift.toml} od="$S29/split-$1"
    rm -rf "$od"; mkdir -p "$od"
    jac run scripts/selector.jac select "$cfg" /nonexistent "$S29/state.json" "$rem" /nonexistent-repo \
        < logs/2026-07-31/findings-all.json > "$S29/sel-$rem.json" \
        || fail "selector failed over the real 2026-07-31 findings at remaining=$rem"
    printf 'themes=%s clockshed=%s' \
        "$(jac run scripts/selector.jac split "$S29/sel-$rem.json" "$od" | wc -l | tr -d ' ')" \
        "$(jac run scripts/selector.jac dropped "$S29/sel-$rem.json" | grep -c 'no-clock-left' || true)"
}
# 424 = 480 - 56, the clock the cycle selector really had (start 20:43:39, merge 21:39:21).
case "$(sel 424)" in
    "themes=15 clockshed=0") : ;;
    *) fail "the real night's findings no longer pack 15 themes into the 424 minutes it had: $(sel 424)" ;;
esac
# THE INVARIANT that keeps this safe, asserted rather than assumed: fit_clock reserves the WORST
# CASE per theme (apply_timeout_min 25 + verify_estimate_min 1 = 26), so a selected theme can always
# be finished even if every session runs to its box. A theme that is selected and then skipped for
# lack of clock is LOST -- carryover.json is built from the selector's `dropped` list, so it lands in
# neither. 15 * 26 = 390 <= 424.
for rem in 480 424 120 60 30 20; do
    n="$(sel "$rem")"; n="${n#themes=}"; n="${n%% *}"
    [ "$(( n * 26 ))" -le "$rem" ] \
        || fail "the selector packed $n themes into $rem minutes; at the 26-minute worst-case reservation that over-commits the night and silently loses the overflow"
done
# ...and the clock really does bind on a short night, or the assertion above is satisfied by a
# selector that never packs anything. These are the arms that would catch a fit_clock deleted
# alongside the raised ceiling.
case "$(sel 120)" in
    # clockshed=0 would mean the 101 findings it dropped were all blamed on the CONSTANT again,
    # with the clock -- which really is the binding limit at 120 minutes -- never named.
    "themes=4 clockshed=0") fail "a 120-minute night shed nothing for the clock; every deferral is still blamed on the constant" ;;
    "themes=4 clockshed="*) : ;;
    *) fail "a 120-minute night did not shed down to what fits: $(sel 120)" ;;
esac
case "$(sel 20)" in
    "themes=0 "*) : ;;
    *) fail "a 20-minute night still scheduled a 26-minute theme: $(sel 20)" ;;
esac
# THE REGRESSION ITSELF: the shipped config must not be back at a number the clock never reaches.
grep -q '^themes_per_night *= *6\b' config/nightshift.toml \
    && fail "themes_per_night is back at 6 -- the constant that deferred 103 findings with 424 of 480 minutes unspent"
# ...proven against the old value rather than asserted: the same real inputs, the same real clock,
# with only that one number changed, reproduce the night byte for byte.
sed 's/^themes_per_night   = 15/themes_per_night   = 6/' config/nightshift.toml > "$S29/old.toml"
grep -q '^themes_per_night   = 6' "$S29/old.toml" \
    || fail "the 2026-07-31 replay config was not built; the comparison below proves nothing"
case "$(sel 424 "$S29/old.toml")" in
    "themes=6 clockshed=0") : ;;
    *) fail "the old config no longer reproduces the 2026-07-31 selection (6 themes, nothing shed for the clock): $(sel 424 "$S29/old.toml")" ;;
esac
rm -rf .jac
echo "the night's theme count is bounded by the clock it has, and never over-commits it"


echo "== 30. the reactive scope holds only files a lens can act on =="
# 2026-07-31: the reactive pass cost $28.72 and 93% of that was context ingestion. Ten of the forty
# files it fed to all four lenses -- 1,049,880 of 2,168,503 bytes -- could not yield a finding under
# any of them: three .md, two .sh and five under **/tests/**, where
# jac/jaclang/cli/docs/community/release_notes/jaclang.md alone is 753,123 bytes, 35% of the whole
# read set. The only filter was `path.startswith(<shard root>)`.
#
# Driven over the REAL merge poll (logs/2026-07-31/merges.json, 21 merged PRs, 522 changed paths)
# through the REAL reader lib/reactive.sh calls, and asserted on the WINDOW rather than the whole
# list: reactive_main audits `head -(files_per_theme*4)` and never looks below it.
rm -rf .jac
S30="$(mktemp -d)"
jac run scripts/merges.jac files logs/2026-07-31/merges.json config/nightshift.toml > "$S30/scope.txt" \
    || fail "merges files no longer parses the real 2026-07-31 merge poll"
head -40 "$S30/scope.txt" > "$S30/win.txt"
[ "$(wc -l < "$S30/win.txt" | tr -d ' ')" = "40" ] \
    || fail "the filtered scope no longer fills the 40-file window ($(wc -l < "$S30/win.txt" | tr -d ' ') files); the filter must REFILL it from further down the churn ranking, not shrink it"
if grep -q 'release_notes/jaclang.md' "$S30/win.txt"; then
    fail "the 753 KB changelog is still in the reactive window: 35% of the read set, and no lens has a rule that can fire on it"
fi
if grep -qE '\.(md|sh|py|txt|yml|toml)$' "$S30/win.txt"; then
    fail "a non-Jac file is still in the reactive window: $(grep -E '\.(md|sh|py|txt|yml|toml)$' "$S30/win.txt" | tr '\n' ' ')"
fi
if grep -qE '(^|/)tests/' "$S30/win.txt"; then
    fail "a protected tests/** path is still in the reactive window: $(grep -E '(^|/)tests/' "$S30/win.txt" | tr '\n' ' ')"
fi
# ...and the freed slots are FILLED from the same churn ranking, not left as ten fewer files.
for p in jac/jaclang/scale/sdk/client.jac jac/jaclang/cli/impl/dispatch.impl.jac \
         jac/jaclang/jac0core/constant.jac jac/jaclang/project/__init__.jac; do
    grep -qxF "$p" "$S30/win.txt" \
        || fail "$p ranked 41-50 before the filter and should have been promoted into the window; it is not there"
done

# THE MUTATION CONTROL, and it is not synthetic: logs/2026-07-31/reactive-files.txt IS this same
# reader's output over this same merges.json before the filter existed. Every assertion above must
# FAIL against it, or it is pinned to something the old code already satisfied.
head -40 logs/2026-07-31/reactive-files.txt > "$S30/unfiltered.txt"
grep -q 'release_notes/jaclang.md' "$S30/unfiltered.txt" \
    || fail "the changelog assertion cannot fail: it does not even match the recorded unfiltered window"
[ "$(grep -cE '\.(md|sh)$' "$S30/unfiltered.txt" | tr -d ' ')" = "5" ] \
    || fail "the non-Jac assertion is pinned to the wrong fact: the recorded unfiltered window held 5 non-Jac paths, this reader counts $(grep -cE '\.(md|sh)$' "$S30/unfiltered.txt" | tr -d ' ')"
[ "$(grep -cE '(^|/)tests/' "$S30/unfiltered.txt" | tr -d ' ')" = "6" ] \
    || fail "the protected-path assertion is pinned to the wrong fact: the recorded unfiltered window held 6 tests/** paths, this reader counts $(grep -cE '(^|/)tests/' "$S30/unfiltered.txt" | tr -d ' ')"

# ...and the two halves of the filter are SEPARATE, proven by deleting one of them from the config
# rather than by reading the code. With **/tests/** gone from [protect].globs the five test .jac
# files come back -- so that half really is driven by the config -- while the .md and .sh stay out,
# which is the other half doing its own work.
sed 's|"\*\*/tests/\*\*", ||' config/nightshift.toml > "$S30/noprotect.toml"
grep -q '"\*\*/fixtures/\*\*"' "$S30/noprotect.toml" \
    || fail "the mutant config was not built (the globs line did not match); the comparison below proves nothing"
if grep -q '"\*\*/tests/\*\*"' "$S30/noprotect.toml"; then
    fail "the mutant config still protects **/tests/**; the mutation did nothing"
fi
jac run scripts/merges.jac files logs/2026-07-31/merges.json "$S30/noprotect.toml" | head -40 > "$S30/mut.txt"
grep -qE '(^|/)tests/' "$S30/mut.txt" \
    || fail "removing **/tests/** from [protect].globs changed the scope not at all -- the filter is not reading the config, so the tests/** assertion above is vacuous"
if grep -qE '\.(md|sh)$' "$S30/mut.txt"; then
    fail "the .jac-extension half of the filter is gone: unprotecting tests/** also readmitted .md/.sh"
fi
rm -rf .jac
echo "the reactive window is 40 auditable .jac files: no changelog, no docs, no scripts, no protected tests"

echo "== 31. the audit money cap is per CALLER, because the two callers cost 2.2x apart =="
# 2026-07-31: four reactive lenses cost $28.72 over 207 turns ($0.139/turn) and eight cycle shards
# cost $38.36 over 601 turns ($0.0638/turn). One audit_max_budget_usd served both, so raising
# audit_max_turns to 130 let a lens reach $12 at ~turn 86 -- four lenses billing $48 of a $50 night
# before the shard fan-out is scheduled at all, moving money from the audits that produced 95
# findings to the ones that produced 5. Driven through the REAL tier2_audit_shard with a stub claude
# that records the flags it was handed; nothing here can reach a real session.
rm -rf .jac
S31="$(mktemp -d)"
mkdir -p "$S31/repo"
cat > "$S31/claude" <<'STUB31'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB31_ARGV"
printf '{"is_error":false,"total_cost_usd":0.01,"result":"```json\n[]\n```"}\n'
STUB31
chmod +x "$S31/claude"

# A separate bash PROCESS, one per probe: `( … ) || fail` suspends errexit for the whole dynamic
# extent left of the ||, so it cannot see a mid-function abort at all.
budget_probe() {       # budget_probe <audit-name> [config] -> the --max-budget-usd it was handed
    local name=$1 cfg=${2:-$NS_ROOT/config/nightshift.toml}
    : > "$S31/argv"
    NS_ROOT="$NS_ROOT" bash -c 'set -euo pipefail
        . "$NS_ROOT/lib/common.sh"; CONFIG="$3"; ns_load_config; . "$NS_ROOT/lib/tier2.sh"
        LOG_DIR="$1"; REPO="$1/repo"; NS_PATHS_CLAUDE="$1/claude"
        export STUB31_ARGV="$1/argv"
        date +%s > "$1/start_epoch"
        tier2_audit_shard "$2" "jac/jaclang/cli/a.jac" dead-code' _ "$S31" "$name" "$cfg" \
        > "$S31/out.txt" 2>&1 || true
    sed -n 's/.*--max-budget-usd \([0-9.][0-9.]*\).*/\1/p' "$S31/argv" | head -1
}
# The name prefix is the only thing the two callers differ in by construction: reactive_main passes
# "reactive-<task>", tier2_audit_all passes the shard name.
react_cap="$(budget_probe reactive-dead-code)"
shard_cap="$(budget_probe cli)"
case "$react_cap" in
    "") fail "the reactive lens was started with no --max-budget-usd at all: $(tr '\n' ' ' < "$S31/out.txt")" ;;
esac
case "$shard_cap" in
    "") fail "the shard audit was started with no --max-budget-usd at all: $(tr '\n' ' ' < "$S31/out.txt")" ;;
esac
[ "$react_cap" = "8" ] \
    || fail "a reactive lens was capped at \$$react_cap, not the \$8 [budgets].reactive_audit_max_budget_usd declares"
[ "$shard_cap" = "12" ] \
    || fail "a shard audit was capped at \$$shard_cap, not the \$12 [budgets].audit_max_budget_usd declares"

# THE REGRESSION ITSELF, as an inequality rather than as two constants: whatever the numbers become,
# four reactive lenses must not be able to bill the whole night before a shard can be scheduled.
react_num="$(sed -n 's/^reactive_audit_max_budget_usd *= *\([0-9][0-9]*\).*/\1/p' config/nightshift.toml | head -1)"
shard_num="$(sed -n 's/^audit_max_budget_usd *= *\([0-9][0-9]*\).*/\1/p' config/nightshift.toml | head -1)"
night_num="$(sed -n 's/^night_budget_usd *= *\([0-9][0-9]*\).*/\1/p' config/nightshift.toml | head -1)"
case "$react_num.$shard_num.$night_num" in
    *[!0-9.]*|.*|*..*|*.) fail "could not read the three budget numbers out of config/nightshift.toml (got '$react_num' '$shard_num' '$night_num')" ;;
esac
[ "$react_num" -lt "$shard_num" ] \
    || fail "reactive_audit_max_budget_usd ($react_num) is not below audit_max_budget_usd ($shard_num); a reactive turn costs 2.2x a shard turn, so an equal cap starves the fan-out"
[ "$(( react_num * 4 ))" -lt "$night_num" ] \
    || fail "four reactive lenses at \$$react_num is \$$(( react_num * 4 )), which reaches the \$$night_num night ceiling on its own -- the cycle shards would never be scheduled"

# THE MUTATION CONTROL: with the two numbers made equal in the config, the probe must report the
# SAME cap for both callers. Without this arm every assertion above is satisfied by a
# tier2_audit_shard that ignores the name and reads one number, which is what it did before.
sed 's/^reactive_audit_max_budget_usd = 8/reactive_audit_max_budget_usd = 12/' config/nightshift.toml > "$S31/same.toml"
grep -q '^reactive_audit_max_budget_usd = 12' "$S31/same.toml" \
    || fail "the equal-caps mutant config was not built; the comparison below proves nothing"
mut_react="$(budget_probe reactive-dead-code "$S31/same.toml")"
[ "$mut_react" = "12" ] \
    || fail "the reactive cap does not come from the config: the mutant says 12 and the session was handed \$$mut_react"
# ...and the other direction, so the split cannot be satisfied by a hard-coded 8: move the SHARD
# number and the shard probe must follow it while the reactive one does not.
sed 's/^audit_max_budget_usd = 12/audit_max_budget_usd = 20/' config/nightshift.toml > "$S31/shard20.toml"
grep -q '^audit_max_budget_usd = 20' "$S31/shard20.toml" \
    || fail "the shard mutant config was not built; the comparison below proves nothing"
mut_shard="$(budget_probe cli "$S31/shard20.toml")"
[ "$mut_shard" = "20" ] \
    || fail "the shard cap is hard-coded: the mutant config says 20 and the session was handed \$$mut_shard"
mut_react2="$(budget_probe reactive-dead-code "$S31/shard20.toml")"
[ "$mut_react2" = "8" ] \
    || fail "moving the SHARD cap to 20 moved the REACTIVE cap to \$$mut_react2 too; the two callers are still sharing one number"
rm -rf .jac
echo "a reactive lens is capped at \$8 and a shard audit at \$12, read from the config, keyed on the caller"

echo "== 32. the selector ships what the audits already paid for, and drops what cannot be applied =="
# 2026-07-31, three defects in one selection:
#   * 112 findings grouped into 105 themes, 99 of them singletons, so 103 findings were deferred
#     `over-night-budget` while the night had used 56 of its 480 minutes -- $38.36 of shard audit and
#     $28.72 of reactive lens, banked and never shipped.
#   * 14 of the 36 file slots (39%) were guessed decl/impl siblings that are not on disk.
#   * five of the eleven apply sessions were impossible before they started: the symbol each was
#     asked to delete is still imported by a file under **/tests/**, which the theme may neither
#     edit nor remove. 25 minutes and ~$0.45 each, and every one reported "no changes made".
# Driven over the REAL findings sets against the REAL repo clone.
rm -rf .jac
if [ ! -d "$NS_ROOT/work/repo/jac" ]; then
    echo "SKIP: no work/repo clone present"
else
S32="$(mktemp -d)"
printf '{"verify_estimate_min": 1}\n' > "$S32/state.json"
resel() {              # resel <findings.json> <out.json> [config]
    jac run scripts/selector.jac select "${3:-config/nightshift.toml}" /nonexistent "$S32/state.json" \
        424 "$NS_ROOT/work/repo" < "$1" > "$2" || fail "the selector failed over $1"
}
# Every theme's own JSON, concatenated -- read through `selector split`, the same reader tier2_apply
# drives the night from, so a selection that packs themes nothing can split cannot read as green.
themes_blob() {        # themes_blob <selection.json> <tag>
    rm -rf "$S32/split-$2"; mkdir -p "$S32/split-$2"
    jac run scripts/selector.jac split "$1" "$S32/split-$2" > "$S32/slugs-$2.txt"
    cat "$S32/split-$2"/theme-*.json > "$S32/blob-$2.json" 2>/dev/null || : > "$S32/blob-$2.json"
}
# Every file slot of every selected theme, `slug<TAB>file`, in ONE reader call. bash never parses
# the JSON (global constraint) and the harness does not pay a jac startup per theme.
missing_slots() {      # missing_slots <selection.json> -> how many named paths are not on disk
    local n=0 p
    for p in $(jac run scripts/selector.jac slots "$1" | cut -f2); do
        [ -e "$NS_ROOT/work/repo/$p" ] || n=$(( n + 1 ))
    done
    printf '%s' "$n"
}
resel logs/2026-07-31/findings-all.json "$S32/cycle.json"
resel logs/2026-07-31/findings-reactive.json "$S32/react.json"
themes_blob "$S32/cycle.json" cycle
themes_blob "$S32/react.json" react
themes_blob logs/2026-07-31/selection.json old

# --- A. the five sessions that could not have worked are dropped at SELECTION -------------------
# Named by the file each finding sits in, because that is what a reader can check against the apply
# report that proved it.
jac run scripts/selector.jac dropped "$S32/cycle.json" > "$S32/dropped-cycle.tsv"
jac run scripts/selector.jac dropped "$S32/react.json" > "$S32/dropped-react.tsv"
for f in jac/jaclang/compiler/type_registry.jac \
         jac/jaclang/compiler/targets/abi.jac \
         jac/jaclang/project/config.jac; do
    grep -qF "$(printf '%s\tblocked-by-protected-test' "$f")" "$S32/dropped-cycle.tsv" \
        || fail "$f still reaches an apply session; its deletion is blocked by a protected test that imports the symbol"
done
for f in jac/jaclang/cli/commands/impl/execution.impl.jac \
         jac/jaclang/scale/injector/bundle.jac; do
    grep -qF "$(printf '%s\tblocked-by-protected-test' "$f")" "$S32/dropped-react.tsv" \
        || fail "$f still reaches an apply session; its deletion is blocked by a protected test that imports the symbol"
done
# THE FALSE-POSITIVE ARM, and it is the one that matters: the six themes that DID ship must still be
# selected. A blocker rule that drops everything satisfies all five assertions above and costs this
# harness its entire output -- which is exactly what reusing vestigial_test_files' file-stem grep
# does: that grep matches 2 to 280 protected files per theme, on all eleven of them.
for f in jac/jaclang/compiler/type_system/type_utils.jac \
         jac/jaclang/project/template_registry.jac \
         jac/jaclang/byllm/llm.impl/basellm.impl.jac; do
    grep -qF "\"$f\"" "$S32/blob-cycle.json" \
        || fail "$f shipped a real branch on 2026-07-31 and is no longer selected; the blocker rule is over-matching"
done
for f in jac/jaclang/cli/commands/project.jac \
         jac/jaclang/cli/commands/impl/tools.impl.jac \
         jac/jaclang/cli/impl/registry.impl.jac; do
    grep -qF "\"$f\"" "$S32/blob-react.json" \
        || fail "$f shipped a real branch on 2026-07-31 and is no longer selected; the blocker rule is over-matching"
done

# --- B. no theme carries a file slot that does not exist ----------------------------------------
[ "$(missing_slots "$S32/cycle.json")" = "0" ] \
    || fail "the cycle selection still names $(missing_slots "$S32/cycle.json") file(s) that do not exist in work/repo"
[ "$(missing_slots "$S32/react.json")" = "0" ] \
    || fail "the reactive selection still names $(missing_slots "$S32/react.json") file(s) that do not exist in work/repo"
# THE MUTATION CONTROL, again not synthetic: logs/2026-07-31/selection.json is what this same
# selector produced from these same findings before the existence check, and it must FAIL the
# assertion above -- 12 phantom slots in the cycle selection, 2 in the reactive one.
[ "$(missing_slots logs/2026-07-31/selection.json)" = "12" ] \
    || fail "the phantom-slot check is pinned to the wrong fact: the recorded 2026-07-31 cycle selection held 12 non-existent file slots, this reader counts $(missing_slots logs/2026-07-31/selection.json)"
[ "$(missing_slots logs/2026-07-31/selection-reactive.json)" = "2" ] \
    || fail "the phantom-slot check is pinned to the wrong fact for the reactive selection: expected 2, this reader counts $(missing_slots logs/2026-07-31/selection-reactive.json)"

# --- C. the grouping converts banked findings into shipped themes -------------------------------
packed() {             # packed <tag> -> how many findings the selected themes carry
    grep -o '"fingerprint"' "$S32/blob-$1.json" | wc -l | tr -d ' '
}
# 9 of 112 is what the recorded night actually handed to apply sessions. That number is the baseline
# and the mutation control in one: if the new grouping does not beat it by a wide margin, the $38.36
# of shard audit is still being thrown away.
[ "$(packed old)" = "9" ] \
    || fail "the baseline is wrong: the recorded 2026-07-31 cycle selection carried 9 findings, this reader counts $(packed old)"
[ "$(packed cycle)" -ge 40 ] \
    || fail "the same 112 findings now pack only $(packed cycle) into the night's themes (was $(packed old)); grouping by directory was supposed to multiply this"
# ...and nothing was silently deleted to achieve it. `over-theme-budget` is TERMINAL -- select()
# deliberately does not carry it -- so a group that overflows must SPILL into another theme rather
# than drop its tail. Any row here is a finding lost for good.
[ "$(grep -c 'over-theme-budget' "$S32/dropped-cycle.tsv" || true)" = "0" ] \
    || fail "coarser grouping is dropping $(grep -c 'over-theme-budget' "$S32/dropped-cycle.tsv") finding(s) as over-theme-budget instead of spilling them into a second theme; that reason is terminal, so they are gone for good"
# ...and every theme still respects files_per_theme, which grouping by directory is the first thing
# ever to make binding (that night produced zero over-theme-budget rows because every group held one
# finding, so the caps bounded nothing at all).
widest="$(jac run scripts/selector.jac slots "$S32/cycle.json" | cut -f1 | uniq -c | awk '{ if ($1 > m) { m = $1; s = $2 } } END { print m "\t" s }')"
[ "$(printf '%s' "$widest" | cut -f1)" -le 10 ] \
    || fail "theme $(printf '%s' "$widest" | cut -f2) names $(printf '%s' "$widest" | cut -f1) files against files_per_theme = 10"

# --- D. ...and the blocker really is driven by the protected globs -------------------------------
# With **/tests/** unprotected the five blocked deletions become ordinary findings again: the rule
# reads is_protected, it does not carry its own list of paths.
sed 's|"\*\*/tests/\*\*", ||' config/nightshift.toml > "$S32/noprotect.toml"
if grep -q '"\*\*/tests/\*\*"' "$S32/noprotect.toml"; then
    fail "the mutant config still protects **/tests/**; the check below proves nothing"
fi
resel logs/2026-07-31/findings-reactive.json "$S32/react-mut.json" "$S32/noprotect.toml"
[ "$(jac run scripts/selector.jac dropped "$S32/react-mut.json" | grep -c 'blocked-by-protected-test' || true)" = "0" ] \
    || fail "findings are still dropped blocked-by-protected-test with **/tests/** removed from [protect].globs -- the rule is not reading the config"
fi
rm -rf .jac
echo "the five impossible themes are dropped at selection, the six that shipped survive, no phantom file slots, and the night's themes carry 4x the findings"

echo "== 33. a dry run is RECORDED, flagged, with only the fork URL withheld =="
# THE 2026-07-31 LOSS. lib/dataset.sh:17 and :26 early-returned on NS_DRY_RUN "because rehearsal
# nights are sandbox data". But only `git push` and `gh pr create` are stubbed under NS_DRY_RUN: 12
# audit sessions, 11 apply sessions, 112 findings, 6 branches, the whole S4 gate and $76.55 of real
# billing were all real that night, and every row of it was discarded. The one field a dry run makes
# untrue is the fork URL -- the branch was never pushed -- so that is the only field withheld.
rm -rf .jac
S33="$T/dry"; mkdir -p "$S33/ds" "$S33/repo"
git -C "$S33/repo" init -q
git -C "$S33/repo" config user.email t@t.com
git -C "$S33/repo" config user.name t
printf 'def old() -> int { return 1; }\n' > "$S33/repo/x.jac"
git -C "$S33/repo" add -A && git -C "$S33/repo" commit -qm base
git -C "$S33/repo" checkout -q -B feat
printf 'def new() -> int { return 1; }\n' > "$S33/repo/x.jac"
git -C "$S33/repo" commit -qam clean
printf '{"summary": "s", "risk": "low", "files": ["x.jac"]}\n' > "$S33/report.json"

# Drives the REAL recorders out of a NAMED copy of lib/dataset.sh, so the mutation below can swap
# that one file and change nothing else. $1 is the library to source; $2 is the dataset dir.
dry_probe() {   # dry_probe <lib/dataset.sh> <dataset_dir>
    (
        . "$NS_ROOT/lib/common.sh"; . "$1"
        ns_load_config
        export NS_DRY_RUN=1
        NS_DATE=2026-07-31
        LOG_DIR="$NS_ROOT/logs/2026-07-31"
        REPO="$S33/repo"
        DATASET_DIR="$2"
        dataset_record_night repo
        dataset_record_refactor feat repo - "$S33/report.json" 1 1 "jac check ok" \
            "https://github.com/ayushmk7/jaseci/tree/feat"
    ) >/dev/null 2>&1 || fail "the dry-run recorders exited nonzero"
}

dry_probe "$NS_ROOT/lib/dataset.sh" "$S33/ds"
[ -s "$S33/ds/nights.jsonl" ] \
    || fail "a dry run still records no nights row -- 2026-07-31 would be discarded again"
[ -s "$S33/ds/refactors.jsonl" ] || fail "a dry run still records no refactor row"
[ -s "$S33/ds/sessions.jsonl" ] || fail "a dry run still records no session rows"
grep -q '"dry_run": true' "$S33/ds/nights.jsonl" \
    || fail "the nights row does not say it came from a dry run: $(cat "$S33/ds/nights.jsonl")"
# THE BRANCH ROW SPECIFICALLY. dataset_record_night above also writes the night's five DECLINE rows
# into this same file, and every one of them legitimately carries "url": null and "dry_run": true --
# so a grep over the whole file is satisfied by rows that prove nothing about the branch. (Measured:
# the file-wide version of the next assertion survived a mutation that removed the URL nulling
# entirely.) Isolate the row this probe created, and assert on that.
grep '"branch": "feat"' "$S33/ds/refactors.jsonl" > "$S33/feat-row.json" \
    || fail "the dry-run branch produced no refactor row at all"
[ "$(wc -l < "$S33/feat-row.json" | tr -d ' ')" = "1" ] \
    || fail "expected exactly one row for the probe branch, got $(wc -l < "$S33/feat-row.json" | tr -d ' ')"
grep -q '"dry_run": true' "$S33/feat-row.json" || fail "the refactor row is not flagged dry_run"
# THE ONE FIELD A DRY RUN FALSIFIES. Nothing was pushed, so tree/<branch> resolves to nothing.
grep -q '"url": null' "$S33/feat-row.json" \
    || fail "a dry run wrote a fork URL for a branch it never pushed: $(grep -o '"url": [^,]*' "$S33/feat-row.json")"
# ...and everything else on the row is the real work, or the assertion above is satisfied by a
# recorder that writes nulls for everything.
grep -q '"before": "def old' "$S33/feat-row.json" \
    || fail "the dry-run refactor row lost the real before-content"
grep -q '"after": "def new' "$S33/feat-row.json" \
    || fail "the dry-run refactor row lost the real after-content"
grep -q '"shipped": true' "$S33/feat-row.json" \
    || fail "the dry-run branch row is not marked shipped; it would be indistinguishable from a decline"

# THE INTERACTIVE RECORDER KEEPS ITS GUARD. promote/discard is a human at a terminal; nothing behind
# it ran and dataset/human_reviews.jsonl is TRACKED, so a rehearsal there dirties the repo.
(
    . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/dataset.sh"
    ns_load_config
    export NS_DRY_RUN=1
    DATASET_DIR="$S33/ds"
    dataset_record_review nightshift/2026-07-31/x true "looks good"
) >/dev/null 2>&1 || fail "dataset_record_review exited nonzero under NS_DRY_RUN"
[ -f "$S33/ds/human_reviews.jsonl" ] \
    && fail "a rehearsed promote/discard wrote a synthetic row to the TRACKED human_reviews.jsonl"

# MUTATION. Restore the exact early return that was deleted, in a copy, and require the probe above
# to go red. Without this every assertion in this section is satisfied by a night that happened to
# be recorded for some other reason.
sed 's|^dataset_record_night() {|dataset_record_night() {\n    [ -n "${NS_DRY_RUN:-}" ] \&\& return 0|' \
    "$NS_ROOT/lib/dataset.sh" > "$S33/mutant.sh"
grep -q 'NS_DRY_RUN:-}" \] && return 0' "$S33/mutant.sh" \
    || fail "the section-33 mutant was not built; the mutation proves nothing"
mkdir -p "$S33/ds-mutant"
dry_probe "$S33/mutant.sh" "$S33/ds-mutant"
[ -s "$S33/ds-mutant/nights.jsonl" ] \
    && fail "the mutant with the NS_DRY_RUN early return restored STILL recorded a nights row -- section 33 cannot fail"
echo "a rehearsal night is captured, flagged, and only its push-dependent URL is withheld"

echo "== 34. sessions.jsonl: one row per LLM session, and a dead lens is never a clean zero =="
# Replayed against the REAL 2026-07-31 log dir, which is the fixture set for sections 26/28/29 too.
# 27 unique session_ids and $76.55 are the two numbers lib/common.sh's ns_spend_add docstring and
# parse_result's spend_total docstring both cite; if this section disagrees with them, one of the
# three is wrong and the harness says so.
rm -rf .jac
S34="$T/sessions"; mkdir -p "$S34"
jac run scripts/dataset.jac record-audit logs/2026-07-31 "$S34" 2026-07-31 repo \
    config/nightshift.toml true >/dev/null \
    || fail "replaying the real 2026-07-31 log dir into the dataset failed outright"
[ -s "$S34/sessions.jsonl" ] || fail "the replay wrote no sessions.jsonl at all"
[ "$(wc -l < "$S34/sessions.jsonl" | tr -d ' ')" = "27" ] \
    || fail "the night's 27 sessions did not produce 27 rows: $(wc -l < "$S34/sessions.jsonl")"
# 12 audits + 4 corrective re-prompts + 11 applies. The 4 repairs are the ones that charge the
# ledger and write NO meta-*.json, so any meta-glob-derived count reports 23.
[ "$(grep -c '"kind": "audit"' "$S34/sessions.jsonl")" = "12" ] \
    || fail "expected 12 audit sessions, got $(grep -c '"kind": "audit"' "$S34/sessions.jsonl")"
[ "$(grep -c '"kind": "audit-repair"' "$S34/sessions.jsonl")" = "4" ] \
    || fail "the 4 corrective re-prompt sessions are missing -- they cost \$0.28 and appear in no meta file"
[ "$(grep -c '"kind": "apply"' "$S34/sessions.jsonl")" = "11" ] \
    || fail "expected 11 apply sessions, got $(grep -c '"kind": "apply"' "$S34/sessions.jsonl")"
# every row identifies its own session, or "one row per session" is not a claim this file supports
[ "$(grep -c '"session_id": "' "$S34/sessions.jsonl")" = "27" ] \
    || fail "some session row carries no session_id"
[ "$(grep -o '"session_id": "[^\"]*"' "$S34/sessions.jsonl" | sort -u | wc -l | tr -d ' ')" = "27" ] \
    || fail "the 27 rows are not 27 DISTINCT sessions"

# THE THREE DEAD LENSES. reactive-abstraction and reactive-coverage were salvaged into a
# placeholder `[]` and their findings files say 0; only reactive-maintenance reached failed.tsv.
# scope_outcomes fuses all three sources, so all three must be scope_failed here -- a row saying
# `"findings_out": 0, "scope_failed": false` for one of them is this project's dominant defect class
# ("did not run" scoring as "passed") reproduced inside the training data.
for lens in reactive-abstraction reactive-coverage reactive-maintenance; do
    grep '"kind": "audit", "name": "'"$lens"'"' "$S34/sessions.jsonl" | grep -q '"scope_failed": true' \
        || fail "audit[$lens] died at the turn cap but its session row does not say the scope failed: $(grep -o '"name": "'"$lens"'".*"wasted": [a-z]*' "$S34/sessions.jsonl" | head -1)"
    grep '"kind": "audit", "name": "'"$lens"'"' "$S34/sessions.jsonl" | grep -q '"outcome": "unfinished:' \
        || fail "audit[$lens] is not recorded as an unfinished session"
    # ...and it is attributed to the phase that ran it. Checked HERE, on an audit row, not by a
    # file-wide grep for `"phase": "reactive"` -- the three reactive APPLY rows satisfy that grep on
    # their own, so the file-wide version survived a mutation that stopped phasing audits entirely.
    grep '"kind": "audit", "name": "'"$lens"'"' "$S34/sessions.jsonl" | grep -q '"phase": "reactive"' \
        || fail "audit[$lens] is not attributed to the reactive phase"
done
# ...and a lens that genuinely RAN is not swept up with them, or the three assertions above are
# satisfied by marking everything failed.
grep '"kind": "audit", "name": "reactive-dead-code"' "$S34/sessions.jsonl" | grep -q '"scope_failed": false' \
    || fail "the one reactive lens that completed was also marked failed; the classifier is stuck on"
grep '"kind": "audit", "name": "reactive-dead-code"' "$S34/sessions.jsonl" | grep -q '"outcome": "completed"' \
    || fail "reactive-dead-code did not come back `completed`"
# the taxonomy is parse_result's, not a second one invented here
grep -q '"outcome": "unfinished:max_turns"' "$S34/sessions.jsonl" \
    || fail "no session carries the turn-cap outcome parse_result status returns"

# waste, model and phase are all on the row -- these are the columns the whole file exists for
grep -q '"wasted": true' "$S34/sessions.jsonl" || fail "no session is marked wasted"
grep -q '"wasted": false' "$S34/sessions.jsonl" || fail "EVERY session is marked wasted"
grep -q '"model": "claude-opus-5"' "$S34/sessions.jsonl" || fail "no row carries the model that ran"
grep -q '"model": "claude-sonnet-5"' "$S34/sessions.jsonl" \
    || fail "the sonnet apply sessions lost their model; complexity routing cannot be evaluated"
grep -q '"phase": "reactive"' "$S34/sessions.jsonl" || fail "no session is attributed to the reactive phase"
grep -q '"phase": "cycle"' "$S34/sessions.jsonl" || fail "no session is attributed to the cycle phase"
# attempt cannot come from the envelope (the retry overwrites it); it comes off run.log
grep -q '"attempt": 2' "$S34/sessions.jsonl" \
    || fail "the night's retried sessions all read as attempt 1 -- run.log is the only record of them"
echo "every session the night ran has a row, and a session that died never reads as one that found nothing"

echo "== 35. the night's bill comes off the session ledger, not the meta-*.json glob =="
# `ns_spend_add` writes <session_id>\t<cost> AT THE SESSION, so it survives a retry overwriting the
# envelope and it is deduped on the id. The old roll-up globbed meta-*.json in TWO places
# (scripts/dataset.jac and scripts/sendmail.jac) and missed every corrective re-prompt, because
# lib/tier2.sh charges the ledger for one but writes it no meta file.
rm -rf .jac
S35="$T/spend"; mkdir -p "$S35/night"
# The exact shape: an audit, its byte-twin meta projection, and a repair with no twin.
printf '{"num_turns": 40, "total_cost_usd": 4.0, "session_id": "s-a"}\n'  > "$S35/night/audit-cli.json"
printf '{"num_turns": 40, "total_cost_usd": 4.0, "session_id": "s-a"}\n'  > "$S35/night/meta-audit-cli.json"
printf '{"num_turns": 1, "total_cost_usd": 0.25, "session_id": "s-r"}\n'  > "$S35/night/audit-repair-cli.json"
spend_of() { jac run scripts/sendmail.jac summarize "$1" "$S35" 2026-07-31 config/nightshift.toml; }
env_sum="$(spend_of "$S35/night" | jac run scripts/parse_result.jac field cost_usd)"
[ "$env_sum" = "4.25" ] \
    || fail "the envelope fallback did not total 4.25 (twin deduped, repair counted); got $env_sum"
[ "$(spend_of "$S35/night" | jac run scripts/parse_result.jac field cost_source)" = "envelopes" ] \
    || fail "the digest does not say WHICH source its cost came from"
printf 's-a\t4.0\ns-r\t0.25\ns-overwritten\t9.5\n' > "$S35/night/spend.txt"
led_sum="$(spend_of "$S35/night" | jac run scripts/parse_result.jac field cost_usd)"
[ "$led_sum" = "13.75" ] \
    || fail "spend.txt did not win over the envelopes (expected 13.75, the overwritten retry included); got $led_sum"
[ "$(spend_of "$S35/night" | jac run scripts/parse_result.jac field cost_source)" = "spend.txt" ] \
    || fail "the digest attributed a ledger-derived cost to the envelopes"

# MUTATION, over the REAL night: delete the four repair envelopes and the total must MOVE. If it
# does not, the roll-up is not reading them and every assertion above is decorative.
cp -R logs/2026-07-31 "$S35/real"
rm -f "$S35/real/spend.txt"                    # this log dir predates the ledger anyway; be explicit
real_full="$(spend_of "$S35/real" | jac run scripts/parse_result.jac field cost_usd)"
case "$real_full" in
    76.55*) : ;;
    *) fail "the real 2026-07-31 night no longer totals \$76.55 from its envelopes; got $real_full" ;;
esac
rm -f "$S35/real"/audit-repair-*.json
real_cut="$(spend_of "$S35/real" | jac run scripts/parse_result.jac field cost_usd)"
[ "$real_full" = "$real_cut" ] \
    && fail "removing all four corrective re-prompt envelopes did not change the night's cost -- the roll-up is still blind to them"
case "$real_cut" in
    76.27*) : ;;
    *) fail "the four repair sessions do not account for the known \$0.28 gap; without them the night reads $real_cut" ;;
esac
echo "the bill is read from the ledger, names its source, and no longer loses the repair sessions"

echo "== 36. the schema gaps: both phases, real counts, and the refusals that used to be deleted =="
# All against $S34, the replay of the real night from section 34.
[ -s "$S34/audit_findings.jsonl" ] || fail "section 36 needs section 34's replay; it is missing"
# 112 in the cycle phase (95 fresh + 17 carried) and 5 in the reactive phase. record_audit read
# findings.json and selection.json ONLY, so the reactive pass -- which produced 3 of the night's 6
# shipped branches -- contributed zero rows, and the 17 carried findings contributed zero too.
[ "$(wc -l < "$S34/audit_findings.jsonl" | tr -d ' ')" = "117" ] \
    || fail "the night's findings did not replay as 117 rows (112 cycle + 5 reactive): $(wc -l < "$S34/audit_findings.jsonl")"
[ "$(grep -c '"phase": "cycle"' "$S34/audit_findings.jsonl")" = "112" ] \
    || fail "the cycle phase is not 112 findings: $(grep -c '"phase": "cycle"' "$S34/audit_findings.jsonl")"
[ "$(grep -c '"phase": "reactive"' "$S34/audit_findings.jsonl")" = "5" ] \
    || fail "the reactive phase contributed $(grep -c '"phase": "reactive"' "$S34/audit_findings.jsonl") findings, not 5"
[ "$(grep -c '"carry": true' "$S34/audit_findings.jsonl")" = "17" ] \
    || fail "the 17 carried findings are not marked: $(grep -c '"carry": true' "$S34/audit_findings.jsonl")"
# THE THREE DROPPED FIELDS. `task` is the most waste-relevant column there is; `theme_hint` is the
# join key from a finding to the branch it became.
grep -q '"task": "abstraction"' "$S34/audit_findings.jsonl" \
    || fail "audit_findings rows still carry no task"
grep -q '"task": "dead-code"' "$S34/audit_findings.jsonl" \
    || fail "the carried dead-code findings lost their own task to tonight's"
grep -q '"complexity": "judgement"' "$S34/audit_findings.jsonl" \
    || fail "audit_findings rows still carry no complexity"
[ "$(grep -c '"theme_hint": null' "$S34/audit_findings.jsonl")" = "0" ] \
    || fail "$(grep -c '"theme_hint": null' "$S34/audit_findings.jsonl") findings have no theme_hint"
# nights.jsonl counted FINDINGS and called them themes: it emitted 9 for a night that packed 6
# cycle themes, and never mentioned the reactive phase's 5 at all.
grep -q '"themes_selected": 11' "$S34/nights.jsonl" \
    || fail "themes_selected is not the 11 themes actually packed (6 cycle + 5 reactive): $(cat "$S34/nights.jsonl")"
grep -q '"findings_carryover": 17' "$S34/nights.jsonl" \
    || fail "the nights row does not count the carry-over the selector packed"
grep -q '"phases": \["cycle", "reactive"\]' "$S34/nights.jsonl" \
    || fail "the nights row does not record which phases ran"
# THE FIVE REFUSALS. Real report-*.json with real skipped[] reasons ("deleting scalar_layout would
# break test_abi_lib.jac"), deleted with the log dir every morning until now.
[ "$(grep -c '"shipped": false' "$S34/refactors.jsonl")" = "5" ] \
    || fail "the 5 apply sessions that correctly refused did not produce 5 shipped:false rows: $(grep -c '"shipped": false' "$S34/refactors.jsonl")"
grep -q 'test_abi_lib.jac' "$S34/refactors.jsonl" \
    || fail "the declines carry no concrete refusal reason -- the whole value of the row"
grep -q '"session_id": "91ce2039-7f68-4d53-b187-4853132544ce"' "$S34/refactors.jsonl" \
    || fail "a decline row does not carry the session that produced it, so its cost is unknowable"
# ...and a theme that DID produce a branch is not filed as a refusal. queue.tsv is what separates
# them; green.tsv does not exist yet when this runs (S4 has not gated anything).
for shipped_slug in dead-code-unused-enum-members dead-code-unreachable-config-fallback; do
    grep -q "\"theme_slug\": \"$shipped_slug\"" "$S34/refactors.jsonl" \
        && fail "$shipped_slug produced a branch but was recorded as a decline"
done
# A REACTIVE-ONLY NIGHT still records. This is the B6 pin from section 22, driven rather than
# grepped: the cycle audit produced nothing, and the phase that DID produce work must not vanish
# with it. Before this, dataset_record_night returned 0 on a missing findings.json and the reactive
# pass -- 3 of the 6 branches of 2026-07-31 -- was invisible to the dataset by construction.
S36R="$T/reactive-only"; mkdir -p "$S36R/night" "$S36R/ds"
cp logs/2026-07-31/findings-reactive.json logs/2026-07-31/selection-reactive.json "$S36R/night/"
# stderr to a file, not the console: this fixture legitimately has no queue.tsv, and the recorder
# SAYING SO is the correct behaviour asserted below -- it just must not read like a harness failure.
jac run scripts/dataset.jac record-audit "$S36R/night" "$S36R/ds" 2026-07-30 repo \
    config/nightshift.toml false >/dev/null 2>"$S36R/err.txt" \
    || fail "a reactive-only night failed to record: $(cat "$S36R/err.txt")"
grep -q 'cannot tell a refused theme from a queued one' "$S36R/err.txt" \
    || fail "the recorder did not say why it recorded no declines for a log dir with no queue.tsv"
[ "$(wc -l < "$S36R/ds/audit_findings.jsonl" 2>/dev/null | tr -d ' ' || echo 0)" = "5" ] \
    || fail "a night with only reactive artifacts recorded $(wc -l < "$S36R/ds/audit_findings.jsonl" 2>/dev/null | tr -d ' ' || echo 0) findings, not 5"
grep -q '"phases": \["reactive"\]' "$S36R/ds/nights.jsonl" \
    || fail "the reactive-only night does not name the one phase that ran: $(cat "$S36R/ds/nights.jsonl")"

# MUTATION: with queue.tsv gone the two cannot be told apart, and the recorder must record NOTHING
# rather than file all 11 applies as refusals.
S36="$T/declines"; mkdir -p "$S36/ds"
cp -R logs/2026-07-31 "$S36/night"
rm -f "$S36/night/queue.tsv"
jac run scripts/dataset.jac record-audit "$S36/night" "$S36/ds" 2026-07-31 repo \
    config/nightshift.toml true >/dev/null 2>&1 \
    || fail "the replay without queue.tsv failed outright"
[ "$(grep -c '"shipped": false' "$S36/ds/refactors.jsonl" 2>/dev/null || echo 0)" = "0" ] \
    || fail "with queue.tsv deleted the recorder guessed, and filed shipped themes as refusals"
rm -rf .jac
echo "both phases are recorded, the counts are the night's own, and a refusal is kept as data"

echo "== 37. backfill recovers a branch the fork never saw, and claims nothing it cannot show =="
# dataset_backfill resolved every green branch with `git fetch origin <branch> || continue`. On
# 2026-07-31 -- a rehearsal, so ns_git_push was stubbed -- not one of the six green branches ever
# reached the fork, every fetch failed, every branch was skipped, and the backfill recovered the
# audit half while losing 100% of the refactor half. Every commit was in work/repo the whole time.
# Three claims are pinned here, because the fix has to recover the rows WITHOUT inventing fields:
#   the local ref is used; a local-only branch gets url null, not a dead fork link; and the two
#   fallbacks on that path (package, tests line) stop asserting things they have no evidence for.
rm -rf .jac
S37="$T/backfill"
mkdir -p "$S37/logs/2026-07-31" "$S37/work/repo"
# A FAKE NS_ROOT. dataset_backfill sweeps "$NS_ROOT"/logs/20*, so the fixture night has to be the
# only night it can see; scripts/ and config/ are symlinked back so ns_jac still runs the real code.
ln -s "$NS_ROOT/scripts" "$S37/scripts"
ln -s "$NS_ROOT/config" "$S37/config"
ln -s "$NS_ROOT/lib" "$S37/lib"
N37="$S37/logs/2026-07-31"

# Two branches, one of each kind. The fork half is not decoration: without it every assertion about
# the local half is also satisfied by a fix that simply stopped consulting the fork at all.
git -C "$S37/work/repo" init -q
git -C "$S37/work/repo" config user.email t@t.com
git -C "$S37/work/repo" config user.name t
printf 'def old() -> int { return 1; }\n' > "$S37/work/repo/x.jac"
git -C "$S37/work/repo" add -A && git -C "$S37/work/repo" commit -qm base
git -C "$S37/work/repo" checkout -q -B main
git -C "$S37/work/repo" checkout -q -B nightshift/2026-07-31/dead-code-local-only
printf 'def new() -> int { return 1; }\n' > "$S37/work/repo/x.jac"
git -C "$S37/work/repo" commit -qam local
git -C "$S37/work/repo" checkout -q -B nightshift/2026-07-31/dead-code-on-the-fork main
printf 'def pushed() -> int { return 1; }\n' > "$S37/work/repo/x.jac"
git -C "$S37/work/repo" commit -qam pushed
git -C "$S37/work/repo" checkout -q main
git init -q --bare "$S37/origin.git"
git -C "$S37/work/repo" remote add origin "$S37/origin.git"
git -C "$S37/work/repo" push -q origin nightshift/2026-07-31/dead-code-on-the-fork
# ...and the local-only branch is genuinely absent from the "fork", or the fix proves nothing.
[ -z "$(git -C "$S37/origin.git" for-each-ref --format='%(refname)' 'refs/heads/nightshift/2026-07-31/dead-code-local-only')" ] \
    || fail "section 37's fixture pushed the local-only branch; the local-ref fallback is untested"

# A parseable night, so record-audit runs and its dry-run flag can be read off nights.jsonl.
cp logs/2026-07-31/findings-reactive.json "$N37/findings.json"
cp logs/2026-07-31/selection-reactive.json "$N37/selection.json"
for s37slug in dead-code-local-only dead-code-on-the-fork; do
    # NO `package` KEY. Themes have carried none since the audit went whole-repo/sharded, so this
    # is the real shape, and it is exactly what made the un-fixed reader return "".
    printf '{"slug": "%s", "task": "dead-code", "complexity": "mechanical", "findings": []}\n' \
        "$s37slug" > "$N37/theme-$s37slug.json"
    printf '{"summary": "s", "risk": "low", "files": ["x.jac"]}\n' > "$N37/report-$s37slug.json"
    printf 'nightshift/2026-07-31/%s\t%s\t%s\n' "$s37slug" "$N37/theme-$s37slug.json" \
        "$N37/report-$s37slug.json" >> "$N37/green.tsv"
    printf 'nightshift/2026-07-31/%s\t%s\t%s\n' "$s37slug" "$N37/theme-$s37slug.json" \
        "$N37/report-$s37slug.json" >> "$N37/queue.tsv"
done
# ONE of the two has its gate summary on disk. The other does not -- which is the case the bare
# string "verified" used to answer with a green gate it had no evidence for.
printf '3 suites green, 1878 collected\n' > "$N37/tests-dead-code-on-the-fork.txt"
# lib/email.sh:24's own line. This log dir predates bin/nightshift.sh's DRY_RUN marker, exactly like
# the real 2026-07-31 one, so the marker cannot be the only signal.
printf '22:20:20 [S6] dry-run: digest rendered, not sent\n' > "$N37/run.log"

# Drives the REAL dataset_backfill out of a NAMED copy of lib/dataset.sh, so the mutation below
# swaps that one file and nothing else. $1 is the library; $2 is the dataset dir.
#
# A SEPARATE `bash` PROCESS, not a `( … ) || fail` subshell, and that is load-bearing. bash
# disables errexit inside a compound command whose status is tested by `||`, so a subshell probe
# runs with `set -e` OFF -- while bin/nightshift.sh's `dataset-backfill` arm calls dataset_backfill
# untested, with errexit LIVE. A probe that cannot see errexit cannot see the failure mode that
# actually shipped: `grep -m1 "tonight's package:"` exits 1 on every sharded night, pipefail made
# that the assignment's rc, and the real command died on the first log dir having recorded nothing.
# The child process sets its own `set -euo pipefail`, so the parent's tested context cannot mask it.
backfill_probe() {   # backfill_probe <lib/dataset.sh> <dataset_dir>
    cat > "$S37/probe.sh" <<PROBE
set -euo pipefail
NS_ROOT="$S37"
. "\$NS_ROOT/lib/common.sh"
. "$1"
ns_load_config
DATASET_DIR="$2"
mkdir -p "\$DATASET_DIR"
dataset_backfill
PROBE
    bash "$S37/probe.sh" >/dev/null 2>&1
}
backfill_probe "$NS_ROOT/lib/dataset.sh" "$S37/ds" \
    || fail "dataset_backfill exited nonzero over the fixture night"

# BOTH branches recovered. One file each; the un-fixed reader produced one row, for the fork half.
[ "$(wc -l < "$S37/ds/refactors.jsonl" | tr -d ' ')" = "2" ] \
    || fail "the backfill recorded $(wc -l < "$S37/ds/refactors.jsonl" | tr -d ' ') refactor rows, not 2 -- a branch the fork never saw is still being dropped"
# Isolate each row. A file-wide grep here is the vacuous-assertion trap section 33 already fell
# into once: the fork row legitimately carries a URL and the local row legitimately carries null,
# so either literal is satisfied by the wrong row.
grep '"branch": "nightshift/2026-07-31/dead-code-local-only"' "$S37/ds/refactors.jsonl" > "$S37/local-row.json" \
    || fail "the local-only branch produced no refactor row; its six real siblings are the 2026-07-31 loss"
grep '"branch": "nightshift/2026-07-31/dead-code-on-the-fork"' "$S37/ds/refactors.jsonl" > "$S37/fork-row.json" \
    || fail "the branch that IS on the fork produced no refactor row"
[ "$(wc -l < "$S37/local-row.json" | tr -d ' ')" = "1" ] || fail "expected exactly one local-only row"
[ "$(wc -l < "$S37/fork-row.json" | tr -d ' ')" = "1" ] || fail "expected exactly one fork row"
# THE COMMIT ITSELF, not just a row. The whole point of the fallback is the diff.
grep -q '"before": "def old' "$S37/local-row.json" \
    || fail "the local-only row has no before-content; the local ref was not actually read"
grep -q '"after": "def new' "$S37/local-row.json" \
    || fail "the local-only row has no after-content; the local ref was not actually read"
# NO DEAD LINK. Nothing was pushed, so github.com/<fork>/tree/<branch> resolves to nothing --
# the same claim lib/dataset.sh nulls on the live dry-run path, arriving by the back door.
grep -q '"url": null' "$S37/local-row.json" \
    || fail "a branch the fork has never seen was given a fork URL: $(grep -o '"url": [^,]*' "$S37/local-row.json")"
# ...and the branch that IS on the fork keeps its real one, or the assertion above is satisfied by
# a recorder that never writes a URL at all.
grep -q '"url": "https://github.com/ayushmk7/jaseci/tree/nightshift/2026-07-31/dead-code-on-the-fork"' "$S37/fork-row.json" \
    || fail "a branch that IS on the fork lost its URL: $(grep -o '"url": [^,]*' "$S37/fork-row.json")"
# THE JOIN KEY. dataset_record_night and lib/ship.sh both write "repo"; a themeless read here gave
# "" and split refactors.jsonl from nights.jsonl for the very night this function recovers.
grep -q '"package": "repo"' "$S37/local-row.json" \
    || fail "the backfilled row's package is not repo, so it will not join nights.jsonl: $(grep -o '"package": [^,]*' "$S37/local-row.json")"
# THE GATE CLAIM. tests-dead-code-local-only.txt does not exist, and the old fallback answered that
# with the bare word "verified" -- an assertion of a green gate from a missing file.
grep -q '"verify": "gate result unavailable' "$S37/local-row.json" \
    || fail "a missing tests-*.txt still yields a verify line that claims a gate: $(grep -o '"verify": "[^"]*"' "$S37/local-row.json")"
grep -q '"verify": "3 suites green, 1878 collected"' "$S37/fork-row.json" \
    || fail "the branch WITH a gate summary lost it; the fallback is firing unconditionally"
# THE NIGHT'S OWN FLAG, not this process's. Backfill passed a hardcoded false, so the one rehearsal
# night in the corpus would have been labelled live in tracked training data.
grep -q '"dry_run": true' "$S37/ds/nights.jsonl" \
    || fail "the backfilled nights row is not flagged as the rehearsal it was: $(cat "$S37/ds/nights.jsonl")"
grep -q '"dry_run": true' "$S37/local-row.json" \
    || fail "the backfilled refactor row is not flagged as coming from a rehearsal"

# dataset_night_was_dry directly, on each signal alone AND on a night carrying none of them. Without
# the last arm every arm above is satisfied by a function that always says true.
dry_of() { ( NS_ROOT="$S37"; . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/dataset.sh"; dataset_night_was_dry "$1" ); }
mkdir -p "$S37/sig-marker" "$S37/sig-prs" "$S37/sig-log" "$S37/sig-live"
touch "$S37/sig-marker/DRY_RUN"
printf '{"number": 0, "url": "https://github.com/DRY-RUN/pull/0"}\n' > "$S37/sig-prs/prs.jsonl"
printf '22:20:20 [S6] dry-run: digest rendered, not sent\n' > "$S37/sig-log/run.log"
printf '{"number": 7301, "url": "https://github.com/jaseci-labs/jac/pull/7301"}\n' > "$S37/sig-live/prs.jsonl"
printf '22:20:20 [S6] digest sent to community@jaseci.org\n' > "$S37/sig-live/run.log"
for s37sig in sig-marker sig-prs sig-log; do
    [ "$(dry_of "$S37/$s37sig")" = "true" ] \
        || fail "$s37sig: a rehearsal night reads as live, so its stub PR links go into the dataset as real"
done
[ "$(dry_of "$S37/sig-live")" = "false" ] \
    || fail "a night with a real PR and a real digest is branded a rehearsal; the flag means nothing"

# MUTATION. Restore the exact `fetch || continue` that lost the refactor half, in a copy, and
# require the local-only branch to disappear. Without this every assertion above is satisfied by a
# fixture that happened to record two rows for some other reason.
sed 's|^            ref=""$|            git -C "$REPO" fetch origin "$branch" -q 2>/dev/null \|\| continue\n            ref=""|' \
    "$NS_ROOT/lib/dataset.sh" > "$S37/mutant.sh"
[ "$(grep -c 'fetch origin "\$branch" -q 2>/dev/null || continue' "$S37/mutant.sh")" = "1" ] \
    || fail "the section-37 mutant was not built; the mutation proves nothing"
backfill_probe "$S37/mutant.sh" "$S37/ds-mutant" \
    || fail "the section-37 mutant exited nonzero"
grep -q '"branch": "nightshift/2026-07-31/dead-code-local-only"' "$S37/ds-mutant/refactors.jsonl" \
    && fail "the mutant with the fork-only resolution restored STILL recovered the local branch -- section 37 cannot fail"
grep -q '"branch": "nightshift/2026-07-31/dead-code-on-the-fork"' "$S37/ds-mutant/refactors.jsonl" \
    || fail "the section-37 mutant dropped BOTH branches, so its red says nothing about the local one"
rm -rf .jac
echo "a branch that only ever existed locally is recovered, with no URL and no gate claim invented"

echo "== 38. S1 branch pruning: the verb must EMIT a branch, not fall through to usage =="
# `ledger prunable` shipped with `len(args) == 5` against a 4-element argv, so every call from
# 2026-07-30 to 2026-08-02 hit the usage arm: stderr text, exit 0, zero branches. lib/sync.sh pipes
# it into `while read`, so "the prune found nothing" and "the prune never parsed" were the same
# night. A unit test on prunable_branches() would have been green throughout -- the defect lived in
# the dispatch -- so this drives the real CLI and asserts on stdout.
S38="$T/prunable"; mkdir -p "$S38"
cat > "$S38/led.jsonl" <<'EOF'
{"fingerprint":"aaa","file":"x.jac","rule":"dead-code","status":"shipped","branch":"nightshift/2026-07-01/stale","last_seen":"2026-07-01","first_seen":"2026-07-01"}
{"fingerprint":"bbb","file":"y.jac","rule":"dead-code","status":"shipped","branch":"nightshift/2026-08-01/fresh","last_seen":"2026-08-01","first_seen":"2026-08-01"}
{"fingerprint":"ccc","file":"z.jac","rule":"dead-code","status":"deferred","last_seen":"2026-07-01","first_seen":"2026-07-01"}
EOF
jac run "$NS_ROOT/scripts/ledger.jac" prunable 14 "$S38/led.jsonl" > "$S38/out.txt" 2> "$S38/err.txt" \
    || fail "ledger prunable exited nonzero"
grep -q 'nightshift/2026-07-01/stale' "$S38/out.txt" \
    || fail "prunable emitted no branch for a 30-day-old shipped finding -- S1 has nothing to prune, ever"
grep -q 'usage:' "$S38/err.txt" \
    && fail "prunable fell through to the usage arm; it printed help and exited 0 instead of pruning"
grep -q 'fresh' "$S38/out.txt" \
    && fail "prunable returned a branch inside the 14-day window -- it would delete a live draft"
grep -q 'deferred\|ccc' "$S38/out.txt" \
    && fail "prunable returned a deferred finding's row; only shipped/rejected branches are prunable"

# MUTATION. Put the off-by-one back and require the assertion above to go red. Without this, a
# section that only ever greps for a branch name is satisfied by any verb that prints something.
# The mutant must live beside nslib.jac for its imports to resolve; the leading dot keeps it out of
# the `scripts/*.jac` glob that section 1 sweeps, and the trap removes it on any exit.
S38M="$NS_ROOT/scripts/.ledger-mutant.jac"
trap 'rm -f "$S38M"' EXIT
sed 's|elif cmd == "prunable" and len(args) == 4 {|elif cmd == "prunable" and len(args) == 5 {|; s|prunable_branches(args\[3\], int(args\[2\]))|prunable_branches(args[4], int(args[3]))|' \
    "$NS_ROOT/scripts/ledger.jac" > "$S38M"
grep -q 'len(args) == 5' "$S38M" \
    || fail "the section-38 mutant was not built; the mutation proves nothing"
jac run "$S38M" prunable 14 "$S38/led.jsonl" > "$S38/mut-out.txt" 2>/dev/null || true
grep -q 'nightshift/2026-07-01/stale' "$S38/mut-out.txt" \
    && fail "the restored off-by-one STILL emitted the stale branch -- section 38 cannot fail"
rm -rf .jac
echo "prunable parses its own argv, and a night with nothing to prune is not a night that never asked"

echo "ALL HARNESS TESTS PASSED"
