# shellcheck shell=bash
# lib/preflight.sh — S0 (TechnicalPRD 7-S0). Any failure emails and aborts the night.

preflight_main() {
    if [ -f "$HOME/.nightshift/DISABLE" ]; then
        touch "$LOG_DIR/DISABLED"
        ns_die "$EX_DISABLED" "kill switch present (~/.nightshift/DISABLE)"
    fi

    local bin
    for bin in "$NS_PATHS_JAC" "$NS_PATHS_CLAUDE" "$NS_PATHS_GH" git python3; do
        command -v "$bin" >/dev/null 2>&1 || ns_die "$EX_BUG" "missing binary: $bin"
        ns_log S0 "$bin -> $("$bin" --version 2>&1 | head -1)"
    done

    # CI/CD automation: retry gh auth (may need keychain unlock time)
    if ! ns_retry 3 5 "$NS_PATHS_GH" auth status >/dev/null 2>&1; then
        ns_die "$EX_AUTH" "gh not authenticated (3 attempts failed)"
    fi

    # network probe: can we reach upstream at all? CI/CD automation: retry transient network failures
    if ! ns_retry 3 10 git -C "$REPO" fetch --dry-run upstream >/dev/null 2>&1; then
        ns_die "$EX_OFFLINE" "offline — cannot reach upstream (3 attempts failed)"
    fi

    # toolchain drift (TPRD 17): warn, never auto-upgrade
    local jac_ver last_ver
    jac_ver="$("$NS_PATHS_JAC" --version 2>&1 | grep -oE 'Version:[[:space:]]+[0-9.]+' | awk '{print $2}')"
    last_ver="$(ns_jac ledger state-get last_jac_version "$STATE" | tr -d '"')"
    if [ -n "$last_ver" ] && [ "$jac_ver" != "$last_ver" ]; then
        ns_warn "toolchain drift: jac $last_ver -> $jac_ver (run proceeds; upgrade was manual?)"
    fi
    ns_jac ledger state-set last_jac_version "\"$jac_ver\"" "$STATE"

    # Claude auth pong probe (subscription creds via Keychain or CLAUDE_CODE_OAUTH_TOKEN)
    # CI/CD automation: retry transient API failures, ensure ANTHROPIC_API_KEY doesn't interfere
    local pong pong_ok=false
    for attempt in $(seq 1 3); do
        pong="$(unset ANTHROPIC_API_KEY; ns_timebox 3 "$NS_PATHS_CLAUDE" -p "reply with exactly: pong" \
                --max-turns 1 --output-format json 2>/dev/null || true)"
        if echo "$pong" | grep -q '"result"[[:space:]]*:[[:space:]]*"pong"'; then
            pong_ok=true
            break
        fi
        [ "$attempt" -lt 3 ] && sleep 2 && ns_log RETRY "Claude pong failed (attempt $attempt/3), retrying..."
    done
    [ "$pong_ok" = true ] || ns_die "$EX_AUTH" "claude pong probe failed (3 attempts) — run /login or set CLAUDE_CODE_OAUTH_TOKEN"

    # CI/CD automation: validate SMTP credentials before we need them (catch config errors early)
    if [ -z "${SMTP_USER:-}" ] || [ -z "${SMTP_PASS:-}" ]; then
        ns_die "$EX_BUG" "SMTP_USER/SMTP_PASS not set — source ~/.nightshift.env or fix nightshift.env"
    fi

    # prune logs older than 60 nights (TPRD 13)
    find "$NS_ROOT/logs" -maxdepth 1 -type d -name '20*' -mtime +60 -exec rm -rf {} + 2>/dev/null || true
}
