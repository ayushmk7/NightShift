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
for f in nslib config ledger check_scope parse_result selector render_draft sendmail testgate checkgate dataset shards fragcheck cimirror; do
    jac test "scripts/$f.jac" >/dev/null 2>&1 || fail "jac test $f"
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
printf '{"package":"pkg","files":["pkg/tests/fixtures/weird.jac"]}' > "$T/theme.json"
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

echo "== 6. fmt/fmt_autofix drift guard: check and apply must share one exclusion regex =="
rm -rf .jac
fmt_cmd="$(jac run scripts/cimirror.jac cmds fmt config/ci-mirror.toml | head -1)"
autofix_cmd="$(jac run scripts/cimirror.jac cmds fmt_autofix config/ci-mirror.toml | head -1)"
rm -rf .jac
# `|| true`: a genuinely absent regex must reach the empty-string check below as a clean FAIL,
# not silently kill this script via set -e + pipefail (grep's rc=1-on-no-match is the rightmost
# nonzero in the pipeline, which pipefail would otherwise propagate to the assignment itself).
fmt_regex="$(printf '%s' "$fmt_cmd" | grep -oE -- '\(/fixtures/[^)]*\)' | head -1 || true)"
autofix_regex="$(printf '%s' "$autofix_cmd" | grep -oE -- '\(/fixtures/[^)]*\)' | head -1 || true)"
case "$fmt_regex" in "") fail "could not extract an exclusion regex from [jobs.fmt]" ;; esac
case "$autofix_regex" in "") fail "could not extract an exclusion regex from [jobs.fmt_autofix]" ;; esac
case "$autofix_regex" in
    "$fmt_regex") : ;;
    *) fail "fmt and fmt_autofix exclusion regexes have drifted apart: '$fmt_regex' vs '$autofix_regex'" ;;
esac
case "$fmt_cmd$autofix_cmd" in
    *'jac format'*) fail "fmt/fmt_autofix regressed to 'jac format' (removed by CLI cleanup #7255)" ;;
esac
case "$fmt_cmd$autofix_cmd" in
    *'jac lint --fix'*) fail "fmt/fmt_autofix regressed to 'jac lint --fix' (removed by CLI cleanup #7255)" ;;
esac
# The regex/tool/flag checks above would all still pass if [jobs.fmt] quietly lost its `--check`
# flag -- the mirror's own VERIFY step would then silently start APPLYING formatting fixes
# instead of just checking them (confirmed: a copy of this file with `--check` stripped passes
# every check above). Pin both sides explicitly so the two guards don't depend on each other.
case "$fmt_cmd" in
    *'--check'*) : ;;
    *) fail "[jobs.fmt] lost --check -- it must VERIFY formatting, not apply it" ;;
esac
case "$autofix_cmd" in
    *'--check'*) fail "[jobs.fmt_autofix] gained --check -- it must APPLY formatting (tier-1's job), not just verify it" ;;
esac
echo "fmt and fmt_autofix share one exclusion regex ($fmt_regex), no jac format / jac lint --fix"

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

# every routed class at once: compiler src, compiler tests, byllm, runtime, and the two no-gate ones
probe "all classes" all jac/jaclang/compiler/x.jac jac/tests/compiler/t.jac jac/jaclang/byllm/b.jac \
                        jac/jaclang/runtimelib/y.jac jac-mcp/z.jac \
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

# an mcp-only or fragment-only change must gate NO suite at all. This is the assertion whose
# expected value IS the empty string, so probe()'s status check above is what keeps it honest.
probe "mcp+fragment" nogate jac-mcp/z.jac release_notes/unreleased/jaclang/2.docs.md
case "$got" in
    "") : ;;
    *) fail "mcp/fragment-only change should gate no suite, got '$got'" ;;
esac
echo "routing correct: byllm-only stays byllm, compiler tests reach compiler, mcp/fragments gate nothing"

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
# fmt_autofix APPLIES formatting (`jac fmt --lintfix`, no --check). Running it inside a read-only
# gate would silently rewrite the candidate branch while deciding whether to ship it.
case "$fast_list" in
    *fmt_autofix*) fail "fmt_autofix is a MUTATING apply step and must never run inside the S4 gate" ;;
esac
echo "gate order correct (fast mirror jobs $fast_ln < suites $suite_ln < contribution $contrib_ln)"

echo "== 9a. S7 theme resolution: tier-1 by NAME, tier-2 by FILE, absence is never 'no theme' =="
# lib/promote.sh used to do `[ -f "$LOG_DIR/theme-….json" ] && theme=…`, which under promote_main's
# live errexit (it is called bare from bin/nightshift.sh, and ns_run_inner's EXIT trap does not
# exist on that path) aborted `nightshift.sh promote` with a bare status 1 whenever the file was
# absent -- i.e. for EVERY tier-1 branch, and for every tier-2 branch promoted on a different
# calendar day than its date-keyed $LOG_DIR. The naive fix is worse than the bug: a theme of "-"
# makes verify_branch skip scope containment, so an aged-out tier-2 theme would silently re-gate an
# LLM-written branch with the anti-injection check off. Hence: tier-1 recognised POSITIVELY by slug,
# everything else must produce its file or ns_die.
case "$(grep -c '^[[:space:]]*\[ -f .*\] &&[[:space:]]*theme=' lib/promote.sh || true)" in
    0) : ;;
    *) fail "lib/promote.sh resolves the theme with a '[ -f … ] && theme=…' list again -- a false && list is a nonzero return, and promote_main runs with errexit live and no EXIT trap" ;;
esac
grep -q 'ns_is_tier1_branch "\$branch"' lib/promote.sh \
    || fail "lib/promote.sh no longer identifies the tier-1 branch positively by slug; absence of a theme file must never be read as 'no theme'"
grep -q 'ns_die "\$EX_BUG" "no theme file for' lib/promote.sh \
    || fail "lib/promote.sh no longer dies on a missing tier-2 theme file -- it would re-gate an agent-written branch without scope containment"
grep -q 'local branch="nightshift/\$NS_DATE/\$NS_TIER1_SLUG"' lib/tier1.sh \
    || fail "lib/tier1.sh no longer builds its branch from \$NS_TIER1_SLUG; a rename here would make every tier-1 promote die on the tier-2 guard"

# The lockstep itself, driven rather than grepped: rebuild tier-1's branch name from lib/tier1.sh's
# OWN expression and ask lib/common.sh's predicate about it. If either side is renamed alone, this
# fails. `if … then exit 1; fi`, never `pred && exit 1`: under set -e a false && list would exit the
# subshell 1 by itself and manufacture the very failure it is testing for.
tier1_expr="$(sed -n 's/.*local branch="\(nightshift[^"]*\)".*/\1/p' lib/tier1.sh | head -1)"
case "$tier1_expr" in
    "") fail "could not extract lib/tier1.sh's branch expression -- the lockstep check below would have been vacuous" ;;
esac
(
    . "$NS_ROOT/lib/common.sh"
    NS_DATE=2026-01-02
    eval "b=\"$tier1_expr\""
    ns_is_tier1_branch "$b" || { echo "tier-1 branch '$b' not recognised as tier-1" >&2; exit 1; }
    if ns_is_tier1_branch "nightshift/2026-01-02/unused-imports"; then
        echo "a tier-2 slug was misidentified as tier-1 -- it would re-gate with no theme" >&2; exit 1
    fi
) || fail "lib/tier1.sh's branch name and lib/common.sh's ns_is_tier1_branch have drifted apart"
echo "theme resolution explicit: tier-1 '$tier1_expr' matches \$NS_TIER1_SLUG, tier-2 absence is fatal"

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

echo "ALL HARNESS TESTS PASSED"
