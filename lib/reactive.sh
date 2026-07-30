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

    # WHICH PRs merged, for the digest. Never fatal and never a reason to skip the pass: losing the
    # report must not also lose the cleanup. Same temp-file discipline, for the same reason.
    rc=0
    ns_jac merges prs "$LOG_DIR/merges.json" > "$LOG_DIR/reactive-prs.tsv.tmp" || rc=$?
    if [ "$rc" -eq 0 ]; then
        mv "$LOG_DIR/reactive-prs.tsv.tmp" "$LOG_DIR/reactive-prs.tsv"
    else
        rm -f "$LOG_DIR/reactive-prs.tsv.tmp"
        ns_warn "could not list the merged PRs for the digest (rc=$rc) — the reactive section will show counts only"
    fi
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

# S3a — all four task lenses over the files that merged upstream today (design spec section 10).
# Runs BEFORE the cycle task so fresh merges are cleaned the same night. Priority order for a
# night is: PR inventory (S1.6) > this > carry-over > tonight's cycle task.
#
# COST, stated plainly because four LLM sessions a night is the most expensive thing Plan 4 adds:
# the justification is that the scope is a handful of files, not an 87k-LOC shard. The moment that
# stops being true the justification is gone, so both ends are guarded -- zero merged files costs
# zero sessions, and a huge merge day is truncated rather than pursued.
#
# Returns 0 ALWAYS. A failed lens costs its own findings, never the night: this runs inside
# tier2_main, which ns_stage invokes with errexit live.
reactive_main() {
    local scope n_files conc task task_list rc=0

    # A poll that never answered is NOT a quiet day, and the two must not read the same. S1.5
    # already wrote the failure row; this only has to avoid claiming the pass was skipped for lack
    # of work.
    if [ ! -f "$LOG_DIR/reactive-files.txt" ]; then
        ns_log S3a "no merge-poll result on disk — the S1.5 poll did not answer, so there is no reactive scope tonight (see failed.tsv)"
        return 0
    fi
    # A quiet day must cost NOTHING: no session, no audit-*.json, no ns_fail row, one log line.
    # `-s`, not `-f`: reactive_poll writes an EMPTY file for a real merge day that touched nothing
    # any lens audits, and that is a genuine quiet day rather than a failure.
    if [ ! -s "$LOG_DIR/reactive-files.txt" ]; then
        ns_log S3a "no upstream merges to clean tonight — reactive pass skipped (0 sessions)"
        return 0
    fi
    n_files="$(wc -l < "$LOG_DIR/reactive-files.txt" | tr -d ' ')"

    # ponytail: CEILING. An audit session cannot usefully read an unbounded file list, and a
    #           200-file merge day is a release, not a janitorial opportunity. Above the cap the
    #           pass audits the first files_per_theme*4 paths and SAYS SO in the digest, rather
    #           than silently truncating or silently spending four max-turn sessions on a list it
    #           cannot hold. The list is CHURN-RANKED by merges.jac, so "the first N" really is the
    #           largest-signal subset and is reproducible from merges.json.
    #           Upgrade path: shard the merged file set the way the repo is sharded, reusing
    #           tier2_audit_all's fan-out with per-chunk scopes. Measured 2026-07-30, one real day
    #           was 376 auditable files, so this ceiling fires on a busy day rather than never.
    local cap=$(( NS_BUDGETS_FILES_PER_THEME * 4 ))
    if [ "$n_files" -gt "$cap" ]; then
        ns_warn "reactive pass: $n_files merged file(s) exceeds the $cap-file ceiling — auditing the $cap most-churned"
        scope="$(head -"$cap" "$LOG_DIR/reactive-files.txt" | tr '\n' ' ')"
    else
        scope="$(tr '\n' ' ' < "$LOG_DIR/reactive-files.txt")"
    fi

    # Same materialize-and-check discipline as tier2_audit_all: `for x in $(reader)` does not fire
    # set -e, so a broken reader would run ZERO lenses and look exactly like a quiet day -- which
    # is the one thing this whole task is built to distinguish.
    task_list="$(ns_jac tasks list "$CONFIG")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$task_list" ]; then
        ns_fail "S3a reactive" "could not read the task list from $CONFIG (rc=$rc) — reactive pass skipped"
        return 0
    fi

    # The coverage lens needs covmap evidence or it skips, and tier2_main only builds covmap.json on
    # a COVERAGE night -- so three nights in four the reactive coverage lens would report a failure
    # for want of a file nobody asked for. `covmap rank` is a deterministic `jac code map` pass with
    # no LLM in it, so build it here when it is missing rather than shipping a lens that is dead 75%
    # of the time. Written through a temp file: covmap.jac refuses to emit `[]` on failure, and a
    # truncated covmap.json reads to the audit as "everything is tested".
    if [ ! -s "$LOG_DIR/covmap.json" ]; then
        if ns_jac covmap rank "$REPO" "$NS_PATHS_JAC_REPO" > "$LOG_DIR/covmap.json.tmp" 2>> "$LOG_DIR/covmap-err.txt"; then
            mv "$LOG_DIR/covmap.json.tmp" "$LOG_DIR/covmap.json"
        else
            rm -f "$LOG_DIR/covmap.json.tmp"
            ns_warn "reactive pass: covmap produced no evidence — the coverage lens is skipped tonight, not failed"
        fi
    fi

    conc="${NS_SHARDS_CONCURRENCY:-2}"
    ns_log S3a "reactive pass over $n_files merged file(s), $(printf '%s' "$task_list" | wc -w | tr -d ' ') lenses"
    for task in $task_list; do
        if [ "$(ns_remaining_min)" -lt $(( NS_BUDGETS_AUDIT_TIMEOUT_MIN + NS_BUDGETS_APPLY_TIMEOUT_MIN )) ]; then
            ns_warn "clock too short to schedule more reactive lenses — stopping at $task"
            break
        fi
        ns_jobs_wait "$conc"
        # `reactive-<task>` is the AUDIT ARTIFACT name, not a branch name -- tier2_apply builds the
        # branch slug as <task>-reactive-<hint> so lib/common.sh's prefix-based task resolver still
        # works (RECONCILIATION B2). tier2_audit_shard keys its coverage-evidence filter on this
        # prefix.
        tier2_audit_shard "reactive-$task" "$scope" "$task" &
    done
    wait

    # Collect. Space-joined string, not a bash array: under set -u bash 3.2 aborts on ${#arr[@]}
    # and "${arr[@]}" when the array is EMPTY, and "every lens failed" is exactly the case this
    # has to survive.
    local found="" n_found=0
    : > "$LOG_DIR/reactive-summary.tsv"
    for task in $task_list; do
        if [ -s "$LOG_DIR/findings-reactive-$task.json" ]; then
            found="$found $LOG_DIR/findings-reactive-$task.json"
            n_found=$(( n_found + 1 ))
            printf '%s\t%s\n' "$task" \
                "$(ns_jac parse_result len < "$LOG_DIR/findings-reactive-$task.json" || echo 0)" \
                >> "$LOG_DIR/reactive-summary.tsv"
        elif [ "$task" = coverage ] && [ ! -s "$LOG_DIR/covmap.json" ]; then
            # "did not run" and "ran and found nothing" are the two things this plan refuses to
            # conflate; so are "did not run" and "FAILED". A lens with no evidence never started.
            printf '%s\tskipped (no coverage evidence)\n' "$task" >> "$LOG_DIR/reactive-summary.tsv"
        else
            printf '%s\tFAILED\n' "$task" >> "$LOG_DIR/reactive-summary.tsv"
        fi
    done
    if [ "$n_found" -eq 0 ]; then
        ns_fail "S3a reactive" "every lens failed or produced nothing over $n_files merged files"
        return 0
    fi

    # shellcheck disable=SC2086  # deliberate word-split into one arg per lens findings file
    if ! ns_jac parse_result merge $found > "$LOG_DIR/findings-reactive.json"; then
        ns_fail "S3a reactive" "merge of $n_found lens findings failed — reactive pass contributes nothing"
        rm -f "$LOG_DIR/findings-reactive.json"
        return 0
    fi
    ns_log S3a "merged $n_found lens result(s) into $(ns_jac parse_result len < "$LOG_DIR/findings-reactive.json" || echo 0) findings"
    tier2_select reactive
    tier2_apply reactive
    return 0
}
