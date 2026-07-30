# shellcheck shell=bash
# lib/reactive.sh — S1.5 merge poll + S3a reactive pass (design spec section 10).
#
# Merge detection is POLLING, not a webhook: a webhook needs repo admin on jaseci-labs/jac and
# the token has {admin:false, push:false, pull:true} (spec section 2).
#
# `gh pr list --json files` returns the changed-file set inline — MEASURED 2026-07-30 against
# jaseci-labs/jac, which answered with `number`, `title`, `author.login` and a `files` array of
# {path, additions, deletions, changeType}. So the fallback branch (one `gh pr view <n> --json
# files` per number) was NOT taken and does not exist here. If that ever stops being true, build
# it rather than letting the union silently degrade to "no files": an empty scope is
# indistinguishable from a quiet day, which is the one thing this file exists to prevent.

# Ask which PRs merged upstream since the last SUCCESSFUL poll. Writes $LOG_DIR/merges.json and
# $LOG_DIR/reactive-files.txt. Returns 0 when the answer is trustworthy -- INCLUDING a genuinely
# empty one -- and 1 when it is not.
reactive_poll() {
    local since rc=0 n
    since="$(ns_jac merges since "$STATE")" || rc=$?
    case "$rc$since" in
        0?*) : ;;
        *)  ns_fail "S1.5 merge poll" "could not read last_merge_poll from $STATE (rc=$rc) — reactive pass skipped"
            return 1 ;;
    esac

    # NOT `$(gh …)` inside a conditional: the exit status must be captured on its own, because
    # `gh` exits 0 having written NOTHING under several failure modes (killed mid-write, rate
    # limit, token expiry mid-call) and an empty file iterates zero times in bash exactly like a
    # quiet day. `--limit 200`: at ~10 merges/day upstream a missed week still fits, and a
    # truncated list would silently narrow the audit scope rather than fail.
    #
    # ns_gh, not "$NS_PATHS_GH" directly: `pr list` is on the read-only allow-list and therefore
    # runs under NS_DRY_RUN too. A dry run whose merge poll is stubbed cannot rehearse the reactive
    # pass at all, which is the whole point of rehearsing it.
    rc=0
    ns_gh pr list --repo "$NS_REPO_UPSTREAM" --state merged \
        --search "merged:>=$since" --limit 200 \
        --json number,title,author,files \
        > "$LOG_DIR/merges.json" 2> "$LOG_DIR/merges-err.txt" || rc=$?
    if [ "$rc" -ne 0 ]; then
        ns_fail "S1.5 merge poll" "gh exited $rc — cannot tell 'no merges' from 'did not ask'; reactive pass skipped ($(tail -1 "$LOG_DIR/merges-err.txt" 2>/dev/null || echo "no stderr"))"
        rm -f "$LOG_DIR/merges.json"
        return 1
    fi

    # THE POSITIVE ASSERTION. `count` refuses an empty or non-array file, so reaching the next
    # line proves gh really answered. A quiet day prints 0 here and is a SUCCESS.
    rc=0
    n="$(ns_jac merges count "$LOG_DIR/merges.json")" || rc=$?
    case "$rc$n" in
        0[0-9]*) : ;;
        *)  ns_fail "S1.5 merge poll" "gh exited 0 but wrote no parseable JSON array (rc=$rc, count='$n') — treating as 'did not ask'"
            rm -f "$LOG_DIR/merges.json"
            return 1 ;;
    esac

    # Written to a temp file and MOVED. A bare `> reactive-files.txt` truncates the file before
    # the reader can fail, and a 0-byte reactive-files.txt is exactly what reactive_main reads as
    # "quiet day, spend nothing" -- so a broken reader would silently cancel the pass and look
    # like good news. Same shape as tier2_select's carry-over write.
    rc=0
    ns_jac merges files "$LOG_DIR/merges.json" "$CONFIG" > "$LOG_DIR/reactive-files.txt.tmp" || rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$LOG_DIR/reactive-files.txt.tmp"
        ns_fail "S1.5 merge poll" "could not extract the changed-file union from merges.json (rc=$rc) — reactive pass skipped"
        return 1
    fi
    mv "$LOG_DIR/reactive-files.txt.tmp" "$LOG_DIR/reactive-files.txt"
    # The count logged is the AUDITABLE one (merges.jac files filters the union to [shards.paths]),
    # not the raw churn -- the raw churn is in merges.json for anyone who wants it, and the number
    # that decides whether a session is spent is this one.
    ns_log S1.5 "$n PR(s) merged upstream since $since, $(wc -l < "$LOG_DIR/reactive-files.txt" | tr -d ' ') auditable file(s) changed"

    # Advanced ONLY on a trustworthy poll: a failed poll must not lose a day of merges.
    # ponytail: the window is date-granular, so re-running the same night re-audits the same PRs.
    #           Harmless -- findings already carry ledger fingerprints and the selector suppresses
    #           drafted/buried ones. Upgrade path if it ever stops being harmless: record the max
    #           PR number alongside the date and filter on it.
    ns_jac ledger state-set last_merge_poll "$NS_DATE" "$STATE"
    return 0
}

# The S1.5 stage entry point. ns_stage runs its function as a PLAIN COMMAND with errexit live, so a
# nonzero return aborts the whole night. reactive_poll deliberately returns 1 for "could not ask",
# which must cost the reactive pass and nothing else -- S1.6, S3, S4 and S5 all still have work to
# do. The failure is already in failed.tsv (ns_fail), which is where the digest reads it, so
# swallowing the status here loses nothing.
reactive_stage() {
    reactive_poll || true
    return 0
}
