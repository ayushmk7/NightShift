# shellcheck shell=bash
# lib/ship.sh — S5 (TechnicalPRD 7-S5): push green branches, render drafts, update the ledger.

ship_main() {
    # Create prs.jsonl unconditionally, BEFORE the early return. The digest distinguishes "S5 ran and
    # shipped nothing" from "S5 never ran" by the file's existence, and S1.6's pr-inventory.jsonl
    # already works that way. Without this line an absent prs.jsonl means both, so a night that died
    # before S5 renders exactly like a quiet one -- this project's "did not run scored as passed",
    # arriving in the one channel nobody can cross-check. `>>` never truncates an existing file, so a
    # same-night re-run keeps the rows it already wrote.
    : >> "$LOG_DIR/prs.jsonl"
    [ -f "$LOG_DIR/green.tsv" ] || { ns_log S5 "nothing green to ship"; return 0; }
    local branch theme report
    while IFS=$'\t' read -r branch theme report; do
        ship_branch "$branch" "$theme" "$report"
    done < "$LOG_DIR/green.tsv"

    # publish drafts + ledger to the fork's orphan branch
    cp "$LEDGER" "$DRAFTS/ledger.jsonl"
    git -C "$DRAFTS" add -A
    if ! git -C "$DRAFTS" diff --cached --quiet; then
        git -C "$DRAFTS" commit -m "drafts: $NS_DATE"
        ns_git_push "$DRAFTS" origin nightshift/drafts
    fi
}

ship_branch() {
    local branch=$1 theme=$2 report=$3
    local slug pkg tests_line draft_path

    slug="$(basename "$branch")"
    if [ "$theme" != "-" ]; then
        # Themes carry no `package` key since the audit went whole-repo/sharded, so this is normally
        # empty now. Fall back to "repo": pkg reaches the draft title AND
        # dataset_record_refactor's row, where "" would sit inconsistently next to nights.jsonl's
        # "repo" and historical rows' real package names.
        pkg="$(ns_jac parse_result field package < "$theme")"
        [ -n "$pkg" ] || pkg="repo"
    else
        # theme "-" — nothing writes that today (tier-1, which did, was retired 2026-07-30), but
        # ship_main reads the column, so the fallback stays rather than becoming an unbound var.
        pkg="repo"
    fi
    # The fallback must NOT assert a green gate. This string goes verbatim into the draft's
    # "## Verification" section (render_draft.jac body_lines) and from there into the PR body a
    # human reviews, and the file is missing exactly when verify_branch's summary line cannot be
    # found -- most reachably when the draft is rendered under a different $NS_DATE than the night
    # that gated the branch, since $LOG_DIR is date-keyed. "gates green (see logs)" claimed a
    # passing gate on the strength of a file that was not there: an assertion with no evidence,
    # in the one line that escapes this repo.
    tests_line="$(cat "$LOG_DIR/tests-$slug.txt" 2>/dev/null \
        || echo "gate result unavailable (tests-$slug.txt missing)")"

    # explicit refspec, only nightshift/* refs, never force (threat T3)
    ns_git_push "$REPO" -u origin "refs/heads/$branch:refs/heads/$branch"

    # Real added/removed line counts from git itself, not the agent's self-reported loc_before/after
    # (which is a FILE line count, not a diff stat, and was off by a few lines on a real run: agent
    # said +11 net, actual diff was +90/-77). Overrides render()'s loc_before/loc_after args below.
    local added removed
    read -r added removed < <(ns_diff_numstat "$REPO" "$NS_REPO_DEFAULT_BRANCH...$branch")

    draft_path="$DRAFTS/drafts/$NS_DATE--$slug.md"
    ns_jac render_draft render "$report" \
        "branch=$branch" "package=$pkg" "date=$NS_DATE" "tests=$tests_line" \
        "loc_before=$removed" "loc_after=$added" \
        > "$draft_path"

    # Copy the theme next to its draft so ANY later night can re-gate this branch with scope
    # containment intact. $LOG_DIR is date-keyed; the drafts branch is not. See
    # ns_theme_for_branch (lib/common.sh) for the failure this prevents. `if`, not `[ -f ] &&`:
    # a green.tsv row can legitimately carry theme "-" (nothing produces one today, but ship_main
    # reads the column), and this must not return nonzero on that path.
    if [ -f "$LOG_DIR/theme-$slug.json" ]; then
        mkdir -p "$DRAFTS/themes"
        cp "$LOG_DIR/theme-$slug.json" "$DRAFTS/themes/$slug.json"
    fi

    # findings on this branch: drafted (a branch with no ledger rows simply loops zero times)
    local fp
    ns_jac ledger by-branch "$branch" "$LEDGER" | while IFS= read -r fp; do
        ns_jac ledger set-status "$fp" drafted "$LEDGER" >/dev/null
    done

    dataset_record_refactor "$branch" "$pkg" "$theme" "$report" "$added" "$removed" \
        "$tests_line" "https://github.com/$NS_REPO_FORK/tree/$branch"

    # `|| true`: a PR that could not be opened is recorded by ship_open_pr itself (ns_fail +
    # a prs.jsonl row) and must not take the remaining branches down with it. ship_branch is
    # called from a `while read` loop with errexit live.
    ship_open_pr "$branch" "$draft_path" "$slug" || true

    ns_log S5 "shipped $branch + draft $(basename "$draft_path")"
}

# One $LOG_DIR/prs.jsonl line, projected by Jac (bash never composes JSON).
#
# RECONCILIATION B3: the artifact is JSONL, not TSV. Plan 4's digest reads prs.jsonl and its reader
# returns [] for a file it cannot parse, so a wrong shape here renders an empty PR table every
# night, forever, with no error -- "did not run scored as passed" in the one unattended channel.
#
# Never fatal, always loud: a row that cannot be projected is a reporting loss, not a reason to
# abandon a PR that is already open.
ship_pr_row() {   # <number> <title> <task> <url> <mirror> <ci> <attempts>
    local line rc=0
    line="$(ns_jac cigate row "number=$1" "title=$2" "task=$3" "url=$4" \
                              "mirror=$5" "ci=$6" "attempts=$7" 2>&1)" || rc=$?
    case "$rc" in
        0) printf '%s\n' "$line" >> "$LOG_DIR/prs.jsonl" ;;
        *) ns_warn "could not project a prs.jsonl row for PR #$1 ($3): $line — the digest's PR table will not list it" ;;
    esac
}

# Rename release_notes/unreleased/jaclang/0000.<kind>.md -> <PR#>.<kind>.md and push.
#
# The predecessor at lib/promote.sh stripped the literal suffix `0000.refactor.md`, so the rename
# silently NO-OPPED for the other four kinds (feature/bugfix/breaking/docs) and shipped a fragment
# still named 0000 -- which upstream's scripts/check-release-notes.sh rejects. That was a LIVE bug,
# not a latent one: [tasks.maintenance].fragment = "auto" means a non-refactor kind really is
# emitted now. This is kind-agnostic, and it also handles fragment == "" (which
# [tasks.coverage].fragment = "" produces) rather than trying to rename the empty path.
#
# The push fires a second CI run on the PR (`synchronize`). That is accepted: the fragment MUST
# carry the PR number, and the number does not exist until the PR does.
ns_renumber_fragment() {   # <branch> <pr_num> <fragment_path>
    local branch=$1 pr=$2 frag=$3 base new
    case "$frag" in "") return 0 ;; esac          # tests-only change: no fragment at all
    base="${frag##*/}"
    case "$base" in
        0000.*) : ;;
        *) ns_die "$EX_BUG" "fragment '$frag' does not carry the 0000 placeholder, so the PR-number rename cannot be derived from it. nslib.fragment_path is the only thing that should be naming these." ;;
    esac
    new="${frag%/*}/$pr.${base#0000.}"
    # ship_branch does not leave $REPO on the branch (S4 checked out whatever it gated last), and
    # `ls-files` reads the INDEX, so the wrong HEAD would report the fragment as untracked and turn
    # the rename into the exact silent no-op this function replaces.
    if ! git -C "$REPO" checkout -q "$branch" 2>/dev/null; then
        ns_warn "$branch: could not check it out to renumber $base; the fragment ships still named 0000 and upstream's check-release-notes.sh will red this PR"
        return 0
    fi
    if ! git -C "$REPO" ls-files --error-unmatch "$frag" >/dev/null 2>&1; then
        ns_warn "$branch: expected release-note fragment $frag is not tracked on the branch; upstream's check-release-notes.sh will red this PR"
        return 0
    fi
    git -C "$REPO" mv "$frag" "$new"
    git -C "$REPO" commit -qm "docs: release note fragment for #$pr"
    ns_git_push "$REPO" origin "refs/heads/$branch:refs/heads/$branch"
    ns_log S5 "fragment renamed $base -> ${new##*/}"
}

# Open the DRAFT PR upstream (spec 6). Never merges, never leaves draft, never pushes to main.
#
# Returns 1 rather than dying when the PR cannot be opened: the branch is already pushed and the
# draft .md already exists, so the night's other branches should still ship and a human can run
# `nightshift.sh promote <branch>` for this one. The failure is recorded in failed.tsv and in
# prs.jsonl, both of which the digest renders.
ship_open_pr() {
    local branch=$1 draft=$2 slug=$3
    local title task pr_url pr_num frag fp pr_rc=0
    title="$(ns_jac render_draft meta "$draft" | ns_jac parse_result field title)"
    case "$title" in
        "") ns_fail "$branch" "draft $draft has no title; refusing to open a PR without one"
            return 1 ;;
    esac
    # The task label the digest's PR table groups by. Derived from the BRANCH NAME, the same way
    # the S4 write gate derives it -- never from the theme, which is agent-authored. Unresolvable
    # is reported, not silently blanked: verify_branch already ns_dies on it, so reaching this arm
    # means something upstream of S5 changed.
    task="$(ns_task_of_branch "$branch")" || task=""
    case "$task" in
        "") ns_warn "$branch: no task resolves from the branch slug; its prs.jsonl row says 'unknown'"
            task="unknown" ;;
    esac
    ns_jac render_draft body "$draft" > "$LOG_DIR/pr-body-$slug.md"

    pr_url="$(ns_gh_write pr create --repo "$NS_REPO_UPSTREAM" --draft \
        --base "$NS_REPO_DEFAULT_BRANCH" --head "${NS_REPO_FORK%%/*}:$branch" \
        --title "$title" --body-file "$LOG_DIR/pr-body-$slug.md" \
        2> "$LOG_DIR/pr-create-$slug.err")" || pr_rc=$?

    # POSITIVE assertion, on BOTH halves. `gh pr create` can exit 0 having printed nothing (and
    # does, whenever a future gh routes its output differently), and an empty $pr_url would then
    # flow into the ledger as a shipped PR that does not exist -- the same class as
    # lib/verify.sh's assert_suite_ran. The rc is demanded too, in the other direction: a
    # URL-shaped line next to a nonzero rc is not evidence the PR was created, and if a real PR
    # does exist despite it, promote's duplicate check and S1.6's `gh pr list` both find it, so
    # the fail-closed reading self-heals while the fail-open one does not.
    case "$pr_rc:$pr_url" in
        0:https://github.com/*/pull/[0-9]*) : ;;
        *)  ns_fail "$branch" "gh pr create returned no PR URL (rc=$pr_rc, got '$pr_url'): $(head -3 "$LOG_DIR/pr-create-$slug.err" 2>/dev/null | tr '\n' ' ')"
            ship_pr_row 0 "$title" "$task" "" green pr-create-failed 0
            return 1 ;;
    esac
    pr_num="${pr_url##*/}"
    ns_log S5 "opened draft PR $pr_url for $branch"

    frag="$(ns_jac render_draft meta "$draft" | ns_jac parse_result field release_note)"
    ns_renumber_fragment "$branch" "$pr_num" "$frag"

    # The findings on this branch are SHIPPED now, not merely drafted: a PR exists upstream. The
    # draft .md deliberately STAYS on disk -- with S5 opening PRs it no longer means "not yet
    # submitted", it means "there is an open PR and `nightshift.sh discard <branch>` is how you
    # kill it" (lib/promote.sh's discard_main closes the PR).
    ns_jac ledger by-branch "$branch" "$LEDGER" | while IFS= read -r fp; do
        ns_jac ledger set-status "$fp" shipped "$LEDGER" "{\"pr_url\":\"$pr_url\"}" >/dev/null
    done
    # mirror=green is a fact, not a hope: ship_main only ever reads green.tsv, which verify_main
    # writes after the CI mirror and the test suites pass. ci=pending is likewise honest -- the
    # checks were created seconds ago; S1.6 reads the verdict tomorrow night.
    ship_pr_row "$pr_num" "$title" "$task" "$pr_url" green pending 0
    return 0
}
