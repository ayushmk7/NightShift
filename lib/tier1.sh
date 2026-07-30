# shellcheck shell=bash
# lib/tier1.sh — S2 (TechnicalPRD 7-S2): deterministic clean, no LLM, near-zero risk.

tier1_main() {
    # $NS_TIER1_SLUG, not a literal "autofix": lib/promote.sh identifies the theme-less tier-1 branch
    # by this exact slug, and a rename here that did not reach there would make every tier-1 promote
    # die on the "tier-2 branch with no theme file" guard. bin/test-harness.sh section 9 pins it.
    local branch="nightshift/$NS_DATE/$NS_TIER1_SLUG"
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

    # RELEASE-NOTE FRAGMENT — tier-1 needs one for exactly the same reason tier-2 does
    # (lib/tier2.sh:253-269, mirrored here rather than shared because the two stages have nothing
    # else in common). Until this existed, tier-1's branch could NEVER pass S4:
    # [jobs.fmt_autofix] scopes the formatter to jac/jaclang/byllm/*.jac, so every non-empty
    # tier-1 diff contains a jac/jaclang/ path; fragcheck.is_gated_change (scripts/fragcheck.jac:47,
    # mirroring check-release-notes.sh:131) then demands a fragment; [jobs.contribution] is a hard
    # gate at the END of verify_branch; and verify_red deletes the branch. Reproduced 2026-07-30:
    #   $ printf 'jac/jaclang/byllm/llm.jac\n' | jac run scripts/fragcheck.jac check   -> rc=1
    # Exempting tier-1 in fragcheck.jac would NOT be a fix: real upstream CI runs the same rule on
    # the PR, so the branch would just die there instead, after a human looked at it.
    #
    # THE KIND MUST BE `refactor`. lib/promote.sh:79 renames only `*0000.refactor.md` when the PR
    # number is known; any other kind silently no-ops that rename and ships a `0000.` fragment.
    # `render_draft frag` hardcodes exactly that kind (see its LATENT COUPLING note), which is why
    # the path is taken from there rather than composed here.
    #
    # Guarded, not bare: tier1_main runs under bin/nightshift.sh's live errexit via ns_stage, where
    # a bare failing `x="$(...)"` would abort the night with no [FATAL] line -- and, worse, a
    # swallowed reader failure would produce an EMPTY path that reads exactly like "no fragment
    # needed", i.e. this plan's dominant did-not-run-scored-as-passed defect.
    local t1_frag t1_frag_rc=0
    t1_frag="$(ns_jac render_draft frag "$LOG_DIR/report-autofix.json")" || t1_frag_rc=$?
    if [ "$t1_frag_rc" -ne 0 ]; then
        ns_die "$EX_BUG" "tier-1: could not compute the release-note fragment path from $LOG_DIR/report-autofix.json (rc=$t1_frag_rc). An empty path is indistinguishable from 'this diff needs no fragment', and shipping without one makes [jobs.contribution] red every night."
    fi
    if [ -n "$t1_frag" ]; then
        mkdir -p "$(dirname "$REPO/$t1_frag")"
        # Through parse_result's `fragment` verb, not a bare `printf > file`: that verb is the one
        # place normalize_fragment_body is applied, and check-release-notes.sh's content-format
        # check (~line 176, mirrored in fragcheck.is_malformed_line) rejects any line that does not
        # start with whitespace or '-'. Body follows the house shape documented in
        # work/repo/release_notes/unreleased/README.md ("- **Refactor: Brief title**: Description.")
        # and contains no em-dash (the repo's pre-commit bans that character in markdown).
        printf '%s' '{"body":"**Refactor: Nightly jac fmt + lint autofix**: Formatting-only sweep of the tier-1 scope; no behavior change."}' \
            | ns_jac parse_result fragment body > "$REPO/$t1_frag"
        git add "$t1_frag"
        git commit -m "docs: release note fragment (nightshift)"
    else
        ns_log S2 "autofix diff touches no non-test jac/jaclang/ path — no fragment required"
    fi

    ns_queue_branch "$branch" "-" "$LOG_DIR/report-autofix.json"
    git checkout "$NS_REPO_DEFAULT_BRANCH"
}
