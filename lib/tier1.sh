# shellcheck shell=bash
# lib/tier1.sh — S2 (TechnicalPRD 7-S2): deterministic clean, no LLM, near-zero risk.

tier1_main() {
    local branch="nightshift/$NS_DATE/autofix"
    cd "$REPO"
    git checkout -B "$branch" "$NS_REPO_DEFAULT_BRANCH"

    rm -rf "$REPO/.jac"                                # `jac clean --cache` prompts [y/N] non-interactively -> aborts

    # config/ci-mirror.toml [jobs.fmt_autofix]: tier-1's OWN apply step, not a ci.yml job (there
    # is no diff yet when tier-1 runs -- it's the first stage -- so it can't reuse [jobs.fmt]'s
    # diff-scoped CHECK command; there's nothing to diff against yet). Same tool, flags (minus
    # --check), and exclusion regex as [jobs.fmt] -- kept byte-identical by
    # bin/test-harness.sh's drift guard -- scoped to jac/jaclang/byllm rather than the whole repo:
    # a repo-wide `--lintfix` would touch ~260 files nightly, drag the huge core test suites into
    # every autofix night via gated_suites_from_diff (Task 6 renamed it from gated_pkgs_from_diff;
    # a repo-wide diff now routes to BOTH `runtime` (1852 tests) and `compiler` (2792), where this
    # jac/jaclang/byllm scoping routes only to the small `byllm` suite), and rewrite files with
    # known pre-existing .jacignore type-check gaps -- exactly what this scope restriction avoids.
    # `jac format .` / `jac lint --fix` are NOT this tool: removed by CLI cleanup #7255. A fork PR
    # gets no autofix rescue from CI itself (the autofix-push step is ci.yml:363-367, same-repo
    # PRs only), so anything left unformatted in scope becomes a hard CI failure at ci.yml:402-406.
    #
    # Assign-then-check-then-eval, not `eval "$(cimirror_fmt_autofix_cmd)"` directly: a renamed or
    # missing [jobs.fmt_autofix] entry (or any reader failure) must not silently `eval ""` (a
    # harmless no-op that would make tier-1 format nothing, forever, without a trace). `|| rc=$?`
    # on the assignment itself, not a bare `x=$(...)` then `[ $? ... ]`: under this script's
    # inherited `set -euo pipefail`, a bare failing assignment aborts the whole night immediately,
    # before any check of it could run (verified while fixing the identical bug in cimirror_job).
    local autofix_cmd autofix_rc=0
    autofix_cmd="$(cimirror_fmt_autofix_cmd)" || autofix_rc=$?
    if [ "$autofix_rc" -ne 0 ] || [ -z "$autofix_cmd" ]; then
        ns_log S2 "WARNING: [jobs.fmt_autofix] resolved to no command (reader rc=$autofix_rc) -- formatted nothing this run; check config/ci-mirror.toml for a renamed/missing job"
    else
        ( cd "$REPO" && export PATH="$(dirname "$NS_PATHS_JAC_REPO"):$PATH" \
            && eval "$autofix_cmd" ) || true
    fi

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
