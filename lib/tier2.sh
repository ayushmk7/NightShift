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
}

# Phase A — audit, physically read-only (dontAsk + no Edit/Write in the allow-list)
tier2_audit() {
    local pkg=$1 prompt
    prompt="$(render_prompt "$NS_ROOT/prompts/audit.md" \
        "pkg=$pkg" "protect_globs=$NS_PROTECT_GLOBS" "ponytail_mode=$NS_AGENT_PONYTAIL_MODE")"

    (cd "$REPO" && ns_timebox "$NS_BUDGETS_AUDIT_TIMEOUT_MIN" "$NS_PATHS_CLAUDE" -p "$prompt" \
        --permission-mode dontAsk \
        --allowedTools "Read,Grep,Glob,Bash(jac code *),Bash(jac check *),Bash(jac guide *),mcp__jac__*" \
        --max-turns 25 --output-format json) > "$LOG_DIR/audit.json" || true

    ns_jac parse_result meta < "$LOG_DIR/audit.json" > "$LOG_DIR/meta-audit.json" || true

    if ! ns_jac parse_result findings < "$LOG_DIR/audit.json" > "$LOG_DIR/findings.json"; then
        ns_fail "audit ($pkg)" "malformed findings JSON (exit 50) — agentic tier skipped tonight"
        return 1
    fi
    ns_log S3 "audit produced $(grep -c '"file"' "$LOG_DIR/findings.json" || echo 0) findings"
}

# Phase B — select (pure function in selector.jac; deterministic, unit-tested)
tier2_select() {
    local pkg=$1
    ns_jac selector select "$pkg" "$CONFIG" "$LEDGER" "$STATE" "$(ns_remaining_min)" \
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
    local pkg=$1 slug branch theme_file prompt remaining
    ns_jac selector split "$LOG_DIR/selection.json" "$LOG_DIR" | while IFS= read -r slug; do
        theme_file="$LOG_DIR/theme-$slug.json"
        branch="nightshift/$NS_DATE/$slug"

        remaining="$(ns_remaining_min)"
        if [ "$remaining" -lt $(( NS_BUDGETS_APPLY_TIMEOUT_MIN + 20 )) ]; then
            ns_fail "theme $slug" "no clock left — deferred to a future night"
            continue
        fi

        cd "$REPO"
        git checkout -B "$branch" "$NS_REPO_DEFAULT_BRANCH"

        prompt="$(render_prompt "$NS_ROOT/prompts/apply.md" \
            "pkg=$pkg" "theme=$(cat "$theme_file")" "ponytail_mode=$NS_AGENT_PONYTAIL_MODE")"

        (cd "$REPO" && ns_timebox "$NS_BUDGETS_APPLY_TIMEOUT_MIN" "$NS_PATHS_CLAUDE" -p "$prompt" \
            --permission-mode acceptEdits \
            --allowedTools "Read,Edit,Grep,Glob,Bash(jac fmt *),Bash(jac format *),Bash(jac lint *),Bash(jac check *),Bash(jac code *),Bash(jac test *),Bash(git diff *),Bash(git status *),Bash(git log *),Bash(git add *),Bash(git commit *),mcp__jac__*" \
            --max-turns "$NS_BUDGETS_MAX_TURNS" --max-budget-usd "$NS_BUDGETS_MAX_BUDGET_USD" \
            --output-format json) > "$LOG_DIR/apply-$slug.json" || true

        ns_jac parse_result meta < "$LOG_DIR/apply-$slug.json" > "$LOG_DIR/meta-apply-$slug.json" || true

        if ! ns_jac parse_result report < "$LOG_DIR/apply-$slug.json" > "$LOG_DIR/report-$slug.json"; then
            ns_fail "theme $slug" "apply session died or returned malformed report — branch discarded"
            git checkout "$NS_REPO_DEFAULT_BRANCH"; git branch -D "$branch" || true
            continue
        fi

        if git diff --quiet "$NS_REPO_DEFAULT_BRANCH...HEAD" 2>/dev/null; then
            ns_fail "theme $slug" "agent made no committed changes — branch discarded"
            git checkout "$NS_REPO_DEFAULT_BRANCH"; git branch -D "$branch" || true
            continue
        fi

        # The ORCHESTRATOR writes the release-note fragment — the agent has no Write tool (TPRD S3-C)
        local fragment="docs/docs/community/release_notes/unreleased/$pkg/0000.refactor.md"
        mkdir -p "$(dirname "$REPO/$fragment")"
        ns_jac parse_result field release_note_md < "$LOG_DIR/report-$slug.json" > "$REPO/$fragment"
        git add "$fragment"
        git commit -m "docs($pkg): release note fragment (nightshift)"

        ns_jac ledger upsert-theme "$theme_file" "$branch" "$LEDGER" >/dev/null
        ns_queue_branch "$branch" "$theme_file" "$LOG_DIR/report-$slug.json"
        git checkout "$NS_REPO_DEFAULT_BRANCH"
    done
}
