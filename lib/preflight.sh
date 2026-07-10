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

    "$NS_PATHS_GH" auth status >/dev/null 2>&1 || ns_die "$EX_AUTH" "gh not authenticated"

    # network probe: can we reach upstream at all?
    git -C "$REPO" fetch --dry-run upstream >/dev/null 2>&1 \
        || ns_die "$EX_OFFLINE" "offline — cannot reach upstream"

    # toolchain drift (TPRD 17): warn, never auto-upgrade
    local jac_ver last_ver
    jac_ver="$("$NS_PATHS_JAC" --version 2>&1 | grep -oE 'Version:[[:space:]]+[0-9.]+' | awk '{print $2}')"
    last_ver="$(ns_jac ledger state-get last_jac_version "$STATE" | tr -d '"')"
    if [ -n "$last_ver" ] && [ "$jac_ver" != "$last_ver" ]; then
        ns_warn "toolchain drift: jac $last_ver -> $jac_ver (run proceeds; upgrade was manual?)"
    fi
    ns_jac ledger state-set last_jac_version "\"$jac_ver\"" "$STATE"

    # Claude auth pong probe (subscription creds via Keychain or CLAUDE_CODE_OAUTH_TOKEN)
    local pong
    pong="$(ns_timebox 3 "$NS_PATHS_CLAUDE" -p "reply with exactly: pong" \
            --max-turns 1 --output-format json 2>/dev/null || true)"
    echo "$pong" | grep -q '"result"[[:space:]]*:[[:space:]]*"pong"' \
        || ns_die "$EX_AUTH" "claude pong probe failed — run /login or set CLAUDE_CODE_OAUTH_TOKEN"

    # prune logs older than 60 nights (TPRD 13)
    find "$NS_ROOT/logs" -maxdepth 1 -type d -name '20*' -mtime +60 -exec rm -rf {} + 2>/dev/null || true
}
