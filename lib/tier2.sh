# shellcheck shell=bash
# lib/tier2.sh — S3 (TechnicalPRD 7-S3): audit (read-only) → select (pure) → apply (one branch per theme).

# {placeholder} substitution in prompt templates — bash-native, no envsubst dependency
render_prompt() {
    local template=$1; shift
    local text; text="$(cat "$template")"
    local kv key val
    for kv in "$@"; do
        key="${kv%%=*}"; val="${kv#*=}"
        text="${text//\{$key\}/$val}"
    done
    printf '%s' "$text"
}

tier2_main() {
    local remaining; remaining="$(ns_remaining_min)"
    if [ "$remaining" -lt $(( NS_BUDGETS_AUDIT_TIMEOUT_MIN + NS_BUDGETS_APPLY_TIMEOUT_MIN )) ]; then
        ns_warn "no clock left for the agentic tier (${remaining}m remaining) — skipping S3"
        return 0
    fi

    tier2_audit_all || return 0        # no usable findings skips the tier; tier-1 still ships
    tier2_select
    tier2_apply
    dataset_record_night               # after select+apply: selection.json + every meta-*.json exist
}

# Phase A — audit, physically read-only (dontAsk + no Edit/Write in the allow-list).
# ONE SHARD per session: 365k LOC cannot be audited in one context (design spec 5).
# Writes $LOG_DIR/findings-<shard>.json on success. Never returns nonzero for a single
# shard failure -- a dead shard must not kill the tier, the way a dead package used to.
tier2_audit_shard() {
    local shard=$1 prompt attempt scope
    scope="$(ns_jac shards scope "$shard" "$CONFIG")"
    prompt="$(render_prompt "$NS_ROOT/prompts/audit.md" \
        "shard=$shard" "scope=$scope" \
        "protect_globs=$NS_PROTECT_GLOBS" "ponytail_mode=$NS_AGENT_PONYTAIL_MODE")"

    # empty NS_AGENT_MODEL (config: [agent].model) means "account default" -- that's the exact
    # silent-drift footgun the config comment warns about, so the default ships pinned to "sonnet";
    # only actually omit the flag if someone deliberately blanks it back out.
    local -a model_args=()
    [ -n "$NS_AGENT_MODEL" ] && model_args=(--model "$NS_AGENT_MODEL")

    # Up to 2 attempts: a transient API error (e.g. "Connection closed mid-response") shouldn't
    # burn this shard. Each attempt is time-boxed; the parse decides success.
    # </dev/null on every claude call is load-bearing: the driver loop feeds stdin, and without
    # it one session EATS the remaining shard list (the same bug that cost 5 of 6 themes in
    # tier2_apply — see the comment there).
    for attempt in 1 2; do
        # dev jac first on PATH so the agent's Bash(jac *) and the jac MCP server hit the repo binary.
        (cd "$REPO" && export PATH="$(dirname "$NS_PATHS_JAC_REPO"):$PATH" \
            && ns_timebox "$NS_BUDGETS_AUDIT_TIMEOUT_MIN" "$NS_PATHS_CLAUDE" -p "$prompt" \
            ${model_args[@]+"${model_args[@]}"} \
            --permission-mode dontAsk \
            --allowedTools "Read,Grep,Glob,Bash(jac code *),Bash(jac check *),Bash(jac guide *),mcp__jac__*" \
            --max-turns "$NS_BUDGETS_AUDIT_MAX_TURNS" --output-format json) \
            > "$LOG_DIR/audit-$shard.json" < /dev/null || true

        # 0-byte envelope = the timebox killed the session before it printed anything; a longer
        # audit_timeout_min (not a re-prompt) is the lever for that failure mode.
        if [ ! -s "$LOG_DIR/audit-$shard.json" ]; then
            ns_log S3 "audit[$shard] attempt $attempt produced no output (killed at ${NS_BUDGETS_AUDIT_TIMEOUT_MIN}m?)"
            continue
        fi

        ns_jac parse_result meta < "$LOG_DIR/audit-$shard.json" > "$LOG_DIR/meta-audit-$shard.json" || true

        if ns_jac parse_result findings < "$LOG_DIR/audit-$shard.json" \
                > "$LOG_DIR/findings-$shard.json" 2> "$LOG_DIR/parse-err-audit-$shard.txt"; then
            ns_log S3 "audit[$shard]: $(ns_jac parse_result len < "$LOG_DIR/findings-$shard.json" || echo 0) findings"
            return 0
        fi

        # Hard account limit: leave a marker so the DRIVER can drop to serial / stop scheduling.
        if grep -q "hit your session limit" "$LOG_DIR/audit-$shard.json"; then
            touch "$LOG_DIR/.session-limit"
            ns_fail "audit[$shard]" "Claude session limit hit"
            rm -f "$LOG_DIR/findings-$shard.json"
            return 1
        fi

        # Live envelope, bad JSON: one cheap single-turn corrective re-prompt before burning
        # the attempt — two whole nights died to malformed audit output with no salvage.
        ns_timebox 3 "$NS_PATHS_CLAUDE" -p "Your audit output failed validation: $(cat "$LOG_DIR/parse-err-audit-$shard.txt")
Previous output:
$(ns_jac parse_result field result < "$LOG_DIR/audit-$shard.json")
Re-emit ONLY the corrected \`\`\`json fenced findings array — same schema, no prose." \
            ${model_args[@]+"${model_args[@]}"} --max-turns 1 --output-format json \
            > "$LOG_DIR/audit-repair-$shard.json" < /dev/null || true
        if ns_jac parse_result findings < "$LOG_DIR/audit-repair-$shard.json" > "$LOG_DIR/findings-$shard.json"; then
            ns_log S3 "audit[$shard] salvaged via corrective re-prompt — $(ns_jac parse_result len < "$LOG_DIR/findings-$shard.json" || echo 0) findings"
            return 0
        fi
        ns_log S3 "audit[$shard] attempt $attempt failed to parse even after corrective re-prompt"
    done
    ns_fail "audit[$shard]" "malformed/failed audit after retry — this shard contributes nothing"
    rm -f "$LOG_DIR/findings-$shard.json"
    return 1
}

# Fan out audit shards, <concurrency> at a time, then merge into one findings array.
# A session limit collapses the fan-out to serial rather than aborting the tier: the old
# behavior lost every remaining shard to one limit signal.
tier2_audit_all() {
    local shard conc merged
    conc="${NS_SHARDS_CONCURRENCY:-2}"
    rm -f "$LOG_DIR/.session-limit"

    # `for` over command substitution, NOT a pipe: a piped `while` loop would run in a subshell
    # whose `jobs -rp` cannot see the sessions, and ns_jobs_wait would never throttle anything.
    # Concurrent shards each fork their own `ns_jac` calls, which SHARE one .jac/data/anchor_store.db;
    # jac can print "database is locked" on stderr under that contention (exit status and stdout stay
    # correct). That stderr lands in parse-err-audit-$shard.txt, which the corrective re-prompt below
    # pastes verbatim — so a lock warning can show up inside a re-prompt. Cosmetic, not a failure.
    for shard in $(ns_jac shards list "$CONFIG"); do
        # log the collapse ONCE, not once per remaining shard
        if [ -f "$LOG_DIR/.session-limit" ] && [ "$conc" != 1 ]; then
            ns_log S3 "session limit seen — dropping to serial for the remaining shards"
            conc=1
        fi
        if [ "$(ns_remaining_min)" -lt $(( NS_BUDGETS_AUDIT_TIMEOUT_MIN + NS_BUDGETS_APPLY_TIMEOUT_MIN )) ]; then
            ns_warn "clock too short to audit remaining shards — stopping the fan-out at $shard"
            break
        fi
        ns_jobs_wait "$conc"
        tier2_audit_shard "$shard" &
    done
    wait

    # Collect the shards that produced findings. NOT a bash array: under `set -u` (which
    # bin/nightshift.sh sets) bash 3.2 aborts on ${#arr[@]} and "${arr[@]}" when the array is
    # EMPTY -- and "every shard failed" is exactly the case this branch has to survive.
    # ponytail: a space-joined string is fine because $NS_ROOT (and so $LOG_DIR) contains no space --
    # a property of the install path, not of the shard names. If the harness is ever installed under a
    # path with a space, the word-split below hands `merge` broken paths and the guard on it fires.
    local found="" n_found=0
    for shard in $(ns_jac shards list "$CONFIG"); do
        if [ -s "$LOG_DIR/findings-$shard.json" ]; then
            found="$found $LOG_DIR/findings-$shard.json"
            n_found=$(( n_found + 1 ))
        fi
    done
    if [ "$n_found" -eq 0 ]; then
        ns_fail "audit" "every shard failed or produced nothing — agentic tier skipped tonight"
        return 1
    fi
    # Guarded: the redirect has already TRUNCATED findings.json by the time merge can fail, and an
    # unguarded failure here would leave 0 bytes, fail tier2_select, and abort the whole night under
    # errexit -- taking S4/S5 and tier-1's already-queued branches with it. Skip the tier instead.
    # shellcheck disable=SC2086  # deliberate word-split into one arg per shard findings file
    if ! ns_jac parse_result merge $found > "$LOG_DIR/findings.json"; then
        ns_fail "audit" "merge of $n_found shard findings failed — agentic tier skipped tonight"
        rm -f "$LOG_DIR/findings.json"
        return 1
    fi
    merged="$(ns_jac parse_result len < "$LOG_DIR/findings.json" || echo 0)"
    ns_log S3 "merged $n_found/$(ns_jac shards count "$CONFIG") shards into $merged findings"
    return 0
}

# Phase B — select (pure function in selector.jac; deterministic, unit-tested)
tier2_select() {
    ns_jac selector select "$CONFIG" "$LEDGER" "$STATE" "$(ns_remaining_min)" "$REPO" \
        < "$LOG_DIR/findings.json" > "$LOG_DIR/selection.json"

    # findings the selector shed for budget/clock reasons are remembered as deferred (TPRD 9)
    local fp file reason
    ns_jac selector dropped "$LOG_DIR/selection.json" | while IFS=$'\t' read -r fp file reason; do
        case "$reason" in
            over-theme-budget|over-night-budget|no-clock-left)
                printf '{"fingerprint":"%s","file":"%s","rule":"unknown","summary":"deferred by selector","status":"deferred"}\n' "$fp" "$file" \
                    | ns_jac ledger upsert "$LEDGER" >/dev/null ;;
        esac
    done
}

# Phase C — apply: fresh branch + fresh headless session per theme
tier2_apply() {
    local slug branch theme_file prompt remaining attempt got_report limit_hit
    local -a model_args=()
    [ -n "$NS_AGENT_MODEL" ] && model_args=(--model "$NS_AGENT_MODEL")
    ns_jac selector split "$LOG_DIR/selection.json" "$LOG_DIR" | while IFS= read -r slug; do
        theme_file="$LOG_DIR/theme-$slug.json"
        branch="nightshift/$NS_DATE/$slug"

        remaining="$(ns_remaining_min)"
        if [ "$remaining" -lt $(( NS_BUDGETS_APPLY_TIMEOUT_MIN + 20 )) ]; then
            ns_fail "theme $slug" "no clock left — deferred to a future night"
            continue
        fi

        prompt="$(render_prompt "$NS_ROOT/prompts/apply.md" \
            "theme=$(cat "$theme_file")" "ponytail_mode=$NS_AGENT_PONYTAIL_MODE")"

        # Up to 2 attempts, each on a FRESH branch: a transient API error mid-session (same class
        # tier2_audit already retries) shouldn't burn the whole theme for the night.
        # checkout -f everywhere: a session killed mid-edit leaves uncommitted changes that would
        # otherwise ride along to main and get committed fail-open by the next night's autofix.
        got_report=0
        limit_hit=0
        for attempt in 1 2; do
            cd "$REPO"
            git checkout -f "$NS_REPO_DEFAULT_BRANCH" 2>/dev/null || true
            git branch -D "$branch" 2>/dev/null || true
            git checkout -B "$branch" "$NS_REPO_DEFAULT_BRANCH"

            # </dev/null is load-bearing: claude reads stdin, and stdin here is the slug pipe
            # from `selector split` — without it the first session EATS the remaining themes
            # (observed live: 6 themes selected, 1 attempted, 5 silently never ran).
            (cd "$REPO" && export PATH="$(dirname "$NS_PATHS_JAC_REPO"):$PATH" \
                && ns_timebox "$NS_BUDGETS_APPLY_TIMEOUT_MIN" "$NS_PATHS_CLAUDE" -p "$prompt" \
                ${model_args[@]+"${model_args[@]}"} \
                --permission-mode acceptEdits \
                --allowedTools "Read,Edit,Grep,Glob,Bash(jac fmt *),Bash(jac check *),Bash(jac code *),Bash(jac test *),Bash(git diff *),Bash(git status *),Bash(git log *),Bash(git add *),Bash(git rm *),Bash(git commit *),mcp__jac__*" \
                --max-turns "$NS_BUDGETS_MAX_TURNS" --max-budget-usd "$NS_BUDGETS_MAX_BUDGET_USD" \
                --output-format json) > "$LOG_DIR/apply-$slug.json" < /dev/null || true

            ns_jac parse_result meta < "$LOG_DIR/apply-$slug.json" > "$LOG_DIR/meta-apply-$slug.json" || true

            if ns_jac parse_result report < "$LOG_DIR/apply-$slug.json" > "$LOG_DIR/report-$slug.json"; then
                got_report=1
                break
            fi
            # A hard account limit fails every retry and every later theme until it resets —
            # observed: "You've hit your session limit · resets 7am". Stop burning the night.
            if grep -q "hit your session limit" "$LOG_DIR/apply-$slug.json"; then
                limit_hit=1
                ns_log S3 "Claude session limit hit — retrying is pointless until it resets"
                break
            fi
            ns_log S3 "apply $slug attempt $attempt failed to parse (transient API error?) — $([ "$attempt" = 1 ] && echo retrying || echo giving up)"
        done

        if [ "$got_report" -ne 1 ]; then
            ns_fail "theme $slug" "apply session died or returned malformed report after retry — branch discarded"
            rm -f "$LOG_DIR/report-$slug.json"    # empty/invalid leftover from the failed redirect — sendmail's digest globs report-*.json
            git checkout -f "$NS_REPO_DEFAULT_BRANCH"; git branch -D "$branch" || true
            if [ "$limit_hit" = 1 ]; then
                ns_fail "agentic tier" "session limit — remaining themes deferred to a future night"
                break
            fi
            continue
        fi

        if git diff --quiet "$NS_REPO_DEFAULT_BRANCH...HEAD" 2>/dev/null; then
            ns_fail "theme $slug" "agent made no committed changes — branch discarded"
            git checkout -f "$NS_REPO_DEFAULT_BRANCH"; git branch -D "$branch" || true
            continue
        fi

        # The ORCHESTRATOR writes the release-note fragment — the agent has no Write tool (TPRD S3-C).
        # Path derives from the theme's own files (via the report the agent returned): only
        # jac/jaclang/** needs a fragment at all, and a theme can now span shards, so there is
        # no package name left to put in the path or the commit subject.
        local fragment; fragment="$(ns_jac render_draft frag "$LOG_DIR/report-$slug.json")"
        if [ -n "$fragment" ]; then
            mkdir -p "$(dirname "$REPO/$fragment")"
            # `fragment`, not `field`: normalizes into bullet form (nslib.normalize_fragment_body)
            # so an agent's plain-English release_note_md can't reach a commit unbulleted and
            # fail CI's content-format check (ci.yml contribution-checks, check-release-notes.sh
            # ~line 176) while the local gate (fragcheck.jac) would have passed it.
            ns_jac parse_result fragment release_note_md < "$LOG_DIR/report-$slug.json" > "$REPO/$fragment"
            git add "$fragment"
            git commit -m "docs: release note fragment (nightshift)"
        else
            ns_log S3 "theme $slug touches no jac/jaclang/ path — no fragment required"
        fi

        ns_jac ledger upsert-theme "$theme_file" "$branch" "$LEDGER" >/dev/null
        ns_queue_branch "$branch" "$theme_file" "$LOG_DIR/report-$slug.json"
        git checkout -f "$NS_REPO_DEFAULT_BRANCH"
    done
}
