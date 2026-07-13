# shellcheck shell=bash
# lib/tier1.sh — S2 (TechnicalPRD 7-S2): deterministic clean, no LLM, near-zero risk.

tier1_main() {
    local branch="nightshift/$NS_DATE/autofix"
    cd "$REPO"
    git checkout -B "$branch" "$NS_REPO_DEFAULT_BRANCH"

    rm -rf "$REPO/.jac"                                # `jac clean --cache` prompts [y/N] non-interactively -> aborts
    # `jac format`/`jac lint` were removed (CLI cleanup #7255); `jac fmt --lintfix` does both in one
    # pass, respects .jacignore. (Avoids a separate `jac check --lint` sweep, which would type-check
    # the whole repo incl. its intentionally-broken test fixtures.)
    "$NS_PATHS_JAC_REPO" fmt . --lintfix || true

    # The formatter runs repo-wide; protected paths must never ship edited (PRD 9).
    local protected
    protected="$(git diff --name-only | ns_jac check_scope protected "$CONFIG")"
    if [ -n "$protected" ]; then
        ns_log S2 "reverting formatter overreach on protected paths"
        echo "$protected" | while IFS= read -r p; do git checkout -- "$p"; done
    fi

    # pre-commit (from PATH, pipx-installed at M0) may self-mutate on the first pass; the second must pass
    ns_precommit run --all-files || ns_precommit run --all-files

    git add -A
    if git diff --cached --quiet; then
        ns_log S2 "empty diff — nothing to autofix tonight"
        git checkout "$NS_REPO_DEFAULT_BRANCH"
        git branch -D "$branch"
        return 0
    fi
    git commit -m "style: nightly jac fmt + lint autofix (nightshift)"

    # synthesize the agent-less report so S5 can render a draft for this branch too
    ns_jac render_draft git-report "$REPO" "nightly jac fmt + lint autofix" \
        > "$LOG_DIR/report-autofix.json"
    ns_queue_branch "$branch" "-" "$LOG_DIR/report-autofix.json"
    git checkout "$NS_REPO_DEFAULT_BRANCH"
}
