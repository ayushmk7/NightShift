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

    local pkg; pkg="$(ns_jac selector rotate "$CONFIG" "$STATE")"
    ns_log S3 "tonight's package: $pkg"

    tier2_audit "$pkg" || return 0        # malformed audit skips the tier; tier-1 still ships
    tier2_select "$pkg"
    tier2_apply "$pkg"
    dataset_record_night "$pkg"           # after select+apply: selection.json + every meta-*.json exist
}

# Phase A — audit, physically read-only (dontAsk + no Edit/Write in the allow-list)
tier2_audit() {
    local pkg=$1 prompt attempt
    prompt="$(render_prompt "$NS_ROOT/prompts/audit.md" \
        "pkg=$pkg" "scope=jac/jaclang/ and jac-mcp/" \
        "protect_globs=$NS_PROTECT_GLOBS" "ponytail_mode=$NS_AGENT_PONYTAIL_MODE")"

    # empty NS_AGENT_MODEL (config: [agent].model) means "account default" -- that's the exact
    # silent-drift footgun the config comment warns about, so the default ships pinned to "sonnet";
    # only actually omit the flag if someone deliberately blanks it back out.
    local -a model_args=()
    [ -n "$NS_AGENT_MODEL" ] && model_args=(--model "$NS_AGENT_MODEL")

    # Up to 2 attempts: a transient API error (e.g. "Connection closed mid-response") shouldn't
    # burn the whole agentic tier. Each attempt is time-boxed; the parse decides success.
    for attempt in 1 2; do
        # dev jac first on PATH so the agent's Bash(jac *) and the jac MCP server hit the repo binary.
        (cd "$REPO" && export PATH="$(dirname "$NS_PATHS_JAC_REPO"):$PATH" \
            && ns_timebox "$NS_BUDGETS_AUDIT_TIMEOUT_MIN" "$NS_PATHS_CLAUDE" -p "$prompt" \
            "${model_args[@]}" \
            --permission-mode dontAsk \
            --allowedTools "Read,Grep,Glob,Bash(jac code *),Bash(jac check *),Bash(jac guide *),mcp__jac__*" \
            --max-turns "$NS_BUDGETS_AUDIT_MAX_TURNS" --output-format json) > "$LOG_DIR/audit.json" || true

        # 0-byte envelope = the timebox killed the session before it printed anything; a longer
        # audit_timeout_min (not a re-prompt) is the lever for that failure mode.
        if [ ! -s "$LOG_DIR/audit.json" ]; then
            ns_log S3 "audit attempt $attempt produced no output (killed at ${NS_BUDGETS_AUDIT_TIMEOUT_MIN}m?) — $([ "$attempt" = 1 ] && echo retrying || echo giving up)"
            continue
        fi

        ns_jac parse_result meta < "$LOG_DIR/audit.json" > "$LOG_DIR/meta-audit.json" || true

        if ns_jac parse_result findings < "$LOG_DIR/audit.json" > "$LOG_DIR/findings.json" 2> "$LOG_DIR/parse-err-audit.txt"; then
            ns_log S3 "audit produced $(ns_jac parse_result len < "$LOG_DIR/findings.json" || echo 0) findings"
            return 0
        fi

        # Hard account limit: the retry and the corrective re-prompt both fail until it resets.
        if grep -q "hit your session limit" "$LOG_DIR/audit.json"; then
            ns_fail "audit ($pkg)" "Claude session limit hit — agentic tier skipped tonight"
            return 1
        fi

        # Live envelope, bad JSON: one cheap single-turn corrective re-prompt before burning
        # the attempt — two whole nights died to malformed audit output with no salvage.
        ns_timebox 3 "$NS_PATHS_CLAUDE" -p "Your audit output failed validation: $(cat "$LOG_DIR/parse-err-audit.txt")
Previous output:
$(ns_jac parse_result field result < "$LOG_DIR/audit.json")
Re-emit ONLY the corrected \`\`\`json fenced findings array — same schema, no prose." \
            "${model_args[@]}" --max-turns 1 --output-format json > "$LOG_DIR/audit-repair.json" || true
        if ns_jac parse_result findings < "$LOG_DIR/audit-repair.json" > "$LOG_DIR/findings.json"; then
            ns_log S3 "audit salvaged via corrective re-prompt — $(ns_jac parse_result len < "$LOG_DIR/findings.json" || echo 0) findings"
            return 0
        fi
        ns_log S3 "audit attempt $attempt failed to parse even after corrective re-prompt — $([ "$attempt" = 1 ] && echo retrying || echo giving up)"
    done
    ns_fail "audit ($pkg)" "malformed/failed audit after retry (exit 50) — agentic tier skipped tonight"
    return 1
}

# Phase B — select (pure function in selector.jac; deterministic, unit-tested)
tier2_select() {
    local pkg=$1
    ns_jac selector select "$pkg" "$CONFIG" "$LEDGER" "$STATE" "$(ns_remaining_min)" "$REPO" \
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
    local pkg=$1 slug branch theme_file prompt remaining attempt got_report limit_hit
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
            "pkg=$pkg" "theme=$(cat "$theme_file")" "ponytail_mode=$NS_AGENT_PONYTAIL_MODE")"

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
                "${model_args[@]}" \
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
        # Fragment dir is the repo's name (jac->jaclang, jac-byllm->byllm), not the package name.
        local fragment; fragment="$(ns_jac render_draft frag "$pkg")"
        mkdir -p "$(dirname "$REPO/$fragment")"
        ns_jac parse_result field release_note_md < "$LOG_DIR/report-$slug.json" > "$REPO/$fragment"
        git add "$fragment"
        git commit -m "docs($pkg): release note fragment (nightshift)"

        ns_jac ledger upsert-theme "$theme_file" "$branch" "$LEDGER" >/dev/null
        ns_queue_branch "$branch" "$theme_file" "$LOG_DIR/report-$slug.json"
        git checkout -f "$NS_REPO_DEFAULT_BRANCH"
    done
}
