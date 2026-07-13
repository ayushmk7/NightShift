# shellcheck shell=bash
# lib/tier1.sh — S2 (TechnicalPRD 7-S2): deterministic clean, no LLM, near-zero risk.

tier1_main() {
    local branch="nightshift/$NS_DATE/autofix"
    cd "$REPO"
    git checkout -B "$branch" "$NS_REPO_DEFAULT_BRANCH"

    rm -rf "$REPO/.jac"                                # `jac clean --cache` prompts [y/N] non-interactively -> aborts
    # `jac format`/`jac lint` were removed (CLI cleanup #7255); `jac fmt --lintfix` does both in one
    # pass, respects .jacignore.
    #
    # Scoped to jac/jaclang/byllm, NOT repo-wide (`.`), for reasons found the hard way on the first
    # real night: a repo-wide pass (a) maps via gated_pkgs_from_diff to the "jac" core package,
    # triggering its ~95min test suite on EVERY autofix night — the nightly wall-clock budget can't
    # absorb that; (b) touches hundreds of files already listed in .jacignore for known, pre-existing
    # type-check gaps, where a blind auto-fix is genuinely risky, not "near-zero risk" as S2 is meant
    # to be; (c) jac-mcp/ is an empty placeholder (nothing to format) and jac/jaclang/scale has no
    # test gate yet (needs k8s). byllm is the one subtree with a proven, fast, baseline-diff-gated
    # test suite (see lib/verify.sh) — same scope tier2's agentic apply already trusts.
    "$NS_PATHS_JAC_REPO" fmt jac/jaclang/byllm --lintfix || true

    # Backstop even though the formatter is scoped now: protected paths must never ship edited (PRD 9).
    local protected
    protected="$(git diff --name-only | ns_jac check_scope protected "$CONFIG")"
    if [ -n "$protected" ]; then
        ns_log S2 "reverting formatter overreach on protected paths"
        echo "$protected" | while IFS= read -r p; do git checkout -- "$p"; done
    fi

    # pre-commit (from PATH, pipx-installed at M0) may self-mutate on the first pass; the second must pass.
    # SKIP jac-format: that hook itself shells out to `jac fmt --lintfix` against EVERY .jac file in
    # the repo on `--all-files` (its own `files: \.jac$` pattern, not scoped to our diff), completely
    # undoing the scoping above the moment it runs — confirmed live: with it included, this stage was
    # still running past 2 minutes. The scoped fmt call three lines up already did this job.
    SKIP=jac-format ns_precommit run --all-files || SKIP=jac-format ns_precommit run --all-files

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
