# shellcheck shell=bash
# lib/verify.sh — S4 (TechnicalPRD 7-S4): fail-closed gate. Any red after retry → branch deleted.

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

# Gate order (each time-boxed): scope containment → jac check → pytest (one retry) → pre-commit.
verify_branch() {
    local branch=$1 theme=$2 t0 t1
    t0="$(date +%s)"
    cd "$REPO"
    git checkout "$branch"
    "$NS_PATHS_JAC" clean --cache || true

    # 1. scope containment FIRST — reject before spending a second on tests (anti-injection, T1)
    if [ "$theme" != "-" ]; then
        if ! git diff --name-only "$NS_REPO_DEFAULT_BRANCH...HEAD" \
                | ns_jac check_scope check "$theme" "$CONFIG" > "$LOG_DIR/scope-violations.txt"; then
            verify_red "$branch" "scope violation (possible prompt injection): $(head -3 "$LOG_DIR/scope-violations.txt" | tr '\n' ' ')"
            return 1
        fi
    fi

    # 2. whole-program type check
    if ! ns_timebox 10 "$NS_PATHS_JAC" check; then
        verify_red "$branch" "jac check red"
        return 1
    fi

    # 3. full test suite; one retry of only the failures (flaky-test policy, PRD 11)
    if ! ns_timebox "$NS_BUDGETS_BOX_VERIFY_MIN" "$NS_PATHS_VENV/bin/python" -m pytest jac -n auto -q; then
        ns_log S4 "pytest red — retrying only the failures once"
        if ! ns_timebox 15 "$NS_PATHS_VENV/bin/python" -m pytest jac --last-failed -q; then
            verify_red "$branch" "pytest red after retry"
            return 1
        fi
    fi

    # 4. pre-commit; if hooks self-mutate, fold the mutation in and demand a clean second pass
    if ! "$NS_PATHS_VENV/bin/pre-commit" run --all-files; then
        git add -A
        git diff --cached --quiet || git commit -m "style: pre-commit autofix (nightshift)"
        if ! "$NS_PATHS_VENV/bin/pre-commit" run --all-files; then
            verify_red "$branch" "pre-commit red"
            return 1
        fi
    fi

    # record the tests line for the draft, and self-tune the verify estimate (TPRD S3-B step 5)
    t1="$(date +%s)"
    local dur_min=$(( (t1 - t0) / 60 )); [ "$dur_min" -lt 1 ] && dur_min=1
    local old_est; old_est="$(ns_jac ledger state-get verify_estimate_min "$STATE" | tr -d '"')"
    ns_jac ledger state-set verify_estimate_min $(( ( ${old_est:-30} + dur_min ) / 2 )) "$STATE"
    echo "jac check ✓ · pytest jac -n auto ✓ · pre-commit ✓ (${dur_min} min)" \
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
