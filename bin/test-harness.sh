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

echo "ALL HARNESS TESTS PASSED"
