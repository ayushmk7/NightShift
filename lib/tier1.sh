# shellcheck shell=bash
# lib/tier1.sh — S2 (TechnicalPRD 7-S2): deterministic clean, no LLM, near-zero risk.

tier1_main() {
    local branch="nightshift/$NS_DATE/autofix"
    cd "$REPO"
    git checkout -B "$branch" "$NS_REPO_DEFAULT_BRANCH"

    rm -rf "$REPO/.jac"                                # `jac clean --cache` prompts [y/N] non-interactively -> aborts

    # CI's EXACT tool/flags/exclusion-regex (config/ci-mirror.toml [jobs.fmt]), with `--check`
    # stripped (tier-1 APPLIES the fix; the mirror VERIFIES it) and the `git ls-files` PATHSPEC
    # narrowed from the whole repo to jac/jaclang/byllm. `jac format .` / `jac lint --fix` are
    # NOT the same tool invocation, and a fork PR gets no autofix rescue (ci.yml:303 is
    # same-repo only), so anything left unformatted in scope becomes a hard CI failure at
    # ci.yml:342 -- hence deriving from CI's exact command instead of a hand-rolled one.
    #
    # NOT the unscoped cimirror_fmt_cmd, though: CI's own fmt CHECK, when it actually runs on a
    # PR, is scoped by DIFF (changed-jac.txt), not by directory -- ci.yml has no "byllm" scope to
    # copy. `[jobs.fmt]`'s registered command is CI's PUSH-event branch (whole-repo git ls-files),
    # which is what the *mirror* should verify against (stricter than a real PR check is a safe
    # direction to err in). Running that same whole-repo command as tier-1's AUTOFIX would
    # `--lintfix` all ~260 currently-unformatted files repo-wide every night -- exactly the
    # "genuinely risky" repo-wide autofix this stage was scoped away from originally: it drags
    # the ~95min "jac" core test suite into every autofix night via gated_pkgs_from_diff, and
    # rewrites files with known pre-existing .jacignore type-check gaps. So only the PATHSPEC is
    # substituted here (byllm/*.jac for *.jac); the tool, flags, and exclusion regex still come
    # from the one canonical string, so they cannot drift from what the mirror verifies.
    ( cd "$REPO" && export PATH="$(dirname "$NS_PATHS_JAC_REPO"):$PATH" \
        && eval "$(cimirror_fmt_cmd | sed "s/ --check//; s#'\\*\\.jac'#'jac/jaclang/byllm/*.jac'#")" ) || true

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
