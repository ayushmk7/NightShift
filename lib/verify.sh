# shellcheck shell=bash
# lib/verify.sh — S4 (TechnicalPRD 7-S4): fail-closed gate. Any red after retry → branch deleted.

BASELINE_DIR="$NS_ROOT/state/test-baseline"

# The target suite is not green on main here (env/infra failures) and is slow, so we gate on a
# per-package BASELINE of already-failing tests (see testgate.jac) rather than a fully-green run.
# The bundled pytest runner needs a clean HOME or its conftest import fails.
#
# pkg_test_raw <pkg> <outfile>: run <pkg>'s CI-accurate test command(s), combined output to outfile.
# Returns 2 for packages with no local test gate (jac-scale: needs k8s). The runner's own exit code
# is ignored — baseline failures are expected; testgate decides pass/fail on NEW failures only.
pkg_test_raw() {
    local pkg=$1 out=$2 H; H="$(mktemp -d)"; : > "$out"
    case "$pkg" in
        jac)
            ( cd "$REPO/jac" && HOME="$H" JAC_TEST_JOBS=auto "$NS_PATHS_JAC_REPO" test tests/ --ignore tests/compiler ) >> "$out" 2>&1 || true
            ( cd "$REPO/jac" && HOME="$H" JAC_TEST_JOBS=auto "$NS_PATHS_JAC_REPO" test tests/compiler ) >> "$out" 2>&1 || true ;;
        jac-byllm)
            # byllm SOURCE + TESTS both live in the jac tree; the tests SHARE a SQLite mock-LLM cache
            # so they must run SERIAL (JAC_TEST_JOBS=0), exactly as ci.yml does. Parallel = flaky.
            ( cd "$REPO" && HOME="$H" JAC_TEST_JOBS=0 "$NS_PATHS_JAC_REPO" test jac/jaclang/byllm/tests ) >> "$out" 2>&1 || true ;;
        *) return 2 ;;
    esac
}

# Map each changed path to the test-package that actually COVERS it, emit the unique set.
# byllm SOURCE lives under jac/jaclang/byllm/** but its TESTS live in jac-byllm/tests, so a
# byllm-only change must gate on the (small) byllm suite, NOT the large, env-flaky jac core suite.
# `cut -d/ -f1` got this wrong (jac/jaclang/byllm -> "jac" -> ran core tests full of CEF/pip flakes).
#
# jac-mcp's CLI-level integration is scattered outside jac/jaclang/byllm too (see
# ns_audit_scope in lib/common.sh for the same real paths) and has no test suite of its own
# (confirmed: "no tests ran" on the recorded baseline) -- without an explicit case here it fell
# into the "jac" catch-all and triggered the ~95min core suite for a 1-file CLI change, confirmed
# live. Route it (and jac-scale, needs k8s) to pkg_test_raw's `*) return 2` no-gate path instead,
# same as jac-scale already got.
gated_pkgs_from_diff() {
    git -C "$REPO" diff --name-only "$NS_REPO_DEFAULT_BRANCH...HEAD" | while IFS= read -r p; do
        case "$p" in
            jac/jaclang/byllm/*|jac-byllm/*)                                 echo jac-byllm ;;
            jac/jaclang/cli/mcp/*|jac/jaclang/cli/commands/*mcp*)            echo jac-mcp ;;
            jac/jaclang/scale/*)                                            echo jac-scale ;;
            jac/*)                                                          echo jac ;;
        esac
    done | sort -u
}

# Record the per-package baseline of already-failing tests on main. Slow (runs the real suites);
# run once at M0 and re-run after a major upstream sync. `nightshift.sh baseline`.
baseline_main() {
    mkdir -p "$BASELINE_DIR"
    cd "$REPO"; git checkout "$NS_REPO_DEFAULT_BRANCH"
    local tp raw n
    for tp in jac jac-byllm; do
        raw="$LOG_DIR/baseline-raw-$tp.txt"
        ns_log BASELINE "recording $tp (slow)..."
        pkg_test_raw "$tp" "$raw"
        n="$(ns_jac testgate record "$tp" "$raw" "$BASELINE_DIR")"
        ns_log BASELINE "$tp: $n known-failing tests recorded"
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

    # 1. scope containment FIRST — reject before spending a second on tests (anti-injection, T1)
    if [ "$theme" != "-" ]; then
        if ! git diff --name-only "$NS_REPO_DEFAULT_BRANCH...HEAD" \
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

    # 3. tests: baseline-diff gate. Run the CI suite for each gated package the branch changed,
    #    fail only on NEW failures vs the recorded main baseline (testgate.jac). jac-scale changes
    #    get no test gate (k8s) — jac check + pre-commit still gate them.
    local tpkg raw
    for tpkg in $(gated_pkgs_from_diff); do
        raw="$LOG_DIR/tests-raw-$(basename "$branch")-$tpkg.txt"
        pkg_test_raw "$tpkg" "$raw"
        if ! ns_jac testgate gate "$tpkg" "$raw" "$BASELINE_DIR"; then
            # One retry: the target suite has documented flaky tests (ci.yml retries `-x || -x`).
            # Only a failure that reproduces on a second run counts.
            # ponytail: two *different* flakes across the two runs could still red; acceptable —
            #           the branch just gets re-attempted next night. Tighten to id-intersection if it bites.
            ns_log S4 "$tpkg: new failures on run 1 — retrying once (flaky-test guard)"
            pkg_test_raw "$tpkg" "$raw"
            if ! ns_jac testgate gate "$tpkg" "$raw" "$BASELINE_DIR"; then
                verify_red "$branch" "$tpkg: new test failures vs baseline (2 runs; see $(basename "$raw"))"
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
