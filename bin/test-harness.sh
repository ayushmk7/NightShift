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
echo "fmt and fmt_autofix share one exclusion regex ($fmt_regex), no jac format / jac lint --fix"

echo "ALL HARNESS TESTS PASSED"
