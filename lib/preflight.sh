# shellcheck shell=bash
# lib/preflight.sh — S0 (TechnicalPRD 7-S0). Any failure emails and aborts the night.

claude_pong() {
    # </dev/null like every other claude invocation: nothing feeds this one a list today, but it is
    # the last session that would inherit the caller's stdin if one ever did.
    (unset ANTHROPIC_API_KEY; ns_timebox 3 "$NS_PATHS_CLAUDE" -p "reply with exactly: pong" \
        --max-turns 1 --output-format json 2>/dev/null < /dev/null) \
        | grep -q '"result"[[:space:]]*:[[:space:]]*"pong"'
}

preflight_main() {
    if [ -f "$HOME/.nightshift/DISABLE" ]; then
        touch "$LOG_DIR/DISABLED"
        ns_die "$EX_DISABLED" "kill switch present (~/.nightshift/DISABLE)"
    fi

    # A blank NS_PATHS_* here once produced the useless "missing binary: " (empty name).
    [ -n "${NS_PATHS_JAC:-}" ] && [ -n "${NS_PATHS_CLAUDE:-}" ] && [ -n "${NS_PATHS_GH:-}" ] \
        || ns_die "$EX_BUG" "NS_PATHS_* empty — config not loaded (run via nightshift.sh, not sourced)"

    local bin
    for bin in "$NS_PATHS_JAC" "$NS_PATHS_CLAUDE" "$NS_PATHS_GH" git python3 gtimeout; do
        command -v "$bin" >/dev/null 2>&1 || ns_die "$EX_BUG" "missing binary: $bin"
        ns_log S0 "$bin -> $("$bin" --version 2>&1 | head -1)"
    done

    # A BARE `jac` must resolve, and must resolve to the TARGET REPO's binary. Two populations
    # depend on it and neither goes through $NS_PATHS_*: work/repo's git hooks
    # (`exec jac precommit --staged --verify`, installed by fresh_env.sh) fire on every commit the
    # harness or the agent makes, and the apply session's allowedTools grant `Bash(jac fmt *)`,
    # `Bash(jac check *)`, `Bash(jac test *)` -- all unqualified.
    #
    # Checked here rather than trusted because the failure is silent-shaped: an absent `jac` makes
    # the hook print `exec: jac: not found` and `git commit` return 1, which under errexit inside
    # ns_stage kills the night with a bare status and no [FATAL] line. Observed exactly that at S1
    # during the Plan 5 cutover rehearsal. And a jac that resolves to the WRONG binary is worse than
    # none: the gates would judge the branch with a different compiler than the one that built it.
    local bare_jac
    bare_jac="$(command -v jac 2>/dev/null || true)"
    [ -n "$bare_jac" ] \
        || ns_die "$EX_BUG" "no bare \`jac\` on PATH — work/repo's git hooks (\`exec jac precommit …\`) and the apply session's Bash(jac …) tools all need one, and their failure looks like a plain \`git commit\` exit 1. PATH=$PATH"
    [ "$bare_jac" = "$NS_PATHS_JAC_REPO" ] \
        || ns_die "$EX_BUG" "bare \`jac\` resolves to $bare_jac, not the target repo's dev binary $NS_PATHS_JAC_REPO — the git hooks and the agent's Bash(jac …) tools would run a different compiler than the gates do"
    ns_log S0 "bare jac -> $bare_jac (git hooks + agent Bash(jac …) tools)"

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

    # `claude` resolves its stored credentials through a $USER-derived lookup. With USER unset it
    # answers `{"is_error": true, "result": "Not logged in · Please run /login"}` with
    # duration_api_ms 0 -- it never reaches the network -- and the probe below then dies EX_AUTH
    # with a message that sends the operator to re-authenticate something that is in fact perfectly
    # healthy. Measured 2026-07-30 while rehearsing this plan's direct-invocation plist:
    # `env -i HOME=… PATH=…` reproduces it exactly, and adding USER=… alone makes it answer "pong".
    #
    # This could not bite under the OLD osascript plist, because Terminal.app handed the script a
    # full login environment. The direct launchd invocation does not, so environment completeness
    # became load-bearing with Plan 5. A real LaunchAgent DOES get USER -- measured with a
    # throwaway probe agent, which printed HOME/LOGNAME/SHELL/TMPDIR/USER/PATH -- so this is a
    # diagnosis aid for the day something strips it, not a workaround for a known-broken schedule.
    [ -n "${USER:-}" ] \
        || ns_die "$EX_BUG" "USER is unset — claude looks its credentials up by \$USER and will report 'Not logged in' however healthy the auth really is. A launchd agent inherits USER normally; if this fires, something stripped the environment (a bare \`env -i\` does)."

    # Claude auth pong probe (subscription creds via Keychain or CLAUDE_CODE_OAUTH_TOKEN);
    # ANTHROPIC_API_KEY is unset so a stale key can't shadow the subscription auth
    ns_retry 3 2 claude_pong \
        || ns_die "$EX_AUTH" "claude pong probe failed (3 attempts) — run /login or set CLAUDE_CODE_OAUTH_TOKEN"

    # CI/CD automation: validate SMTP credentials before we need them (catch config errors early)
    if [ -z "${SMTP_USER:-}" ] || [ -z "${SMTP_PASS:-}" ]; then
        ns_die "$EX_BUG" "SMTP_USER/SMTP_PASS not set — source ~/.nightshift.env or fix nightshift.env"
    fi

    # Missed-night detection, two classes, because they have different causes and different fixes.
    #
    # FIRED-BUT-NO-RUN: the plist ran and the harness died before mkdir -p $LOG_DIR, so it left no
    # trace of its own. Diagnosed 2026-07-30 for 07-25/26/29 -- under the OLD osascript plist,
    # launchd's exit code measured osascript, not the harness. The direct-invocation plist makes
    # StandardErrorPath the evidence for this class; the warning stays as the cheap index.
    #
    # NEVER-FIRED: no fire line AND no run dir. 07-28 was exactly this and was INVISIBLE, because
    # the old loop only iterated over fire lines -- an absence of evidence cannot appear in a list
    # of events. This is the class the spec calls worthless-if-silent, so it is enumerated over
    # CALENDAR DATES, not over the log.
    #
    # ponytail: 7 days of `date -v-Nd`, not a scheduler-health subsystem. The ceiling is that eight
    #           consecutive misses roll off the window. Upgrade path: raise the 7, or have S0 stamp
    #           a "last successful night" date into state.json and diff against today.
    local d back fired_log="$HOME/Library/Logs/nightshift-fired.log"
    for back in 1 2 3 4 5 6 7; do
        d="$(date -v-${back}d +%F)"
        [ -d "$NS_ROOT/logs/$d" ] && continue
        # `if`, not `[ … ] && …`: a false && list returns nonzero, and this loop body is the last
        # thing that runs before the log prune under an errexit-active caller.
        #
        # grep -qxF, not grep -q: fixed-string and whole-line. A bare grep -q "$d" treats the date
        # as a regex (the dashes are literal but the dots in a future format would not be) and
        # matches 2026-07-02 inside a longer line.
        if [ -f "$fired_log" ] && grep -qxF "$d" "$fired_log"; then
            ns_warn "missed night: $d (launchd fired, no run dir — see ~/Library/Logs/nightshift-launchd.err)"
        else
            ns_warn "missed night: $d (launchd NEVER FIRED — check: launchctl list | grep nightshift)"
        fi
    done

    # prune logs older than 60 nights (TPRD 13)
    find "$NS_ROOT/logs" -maxdepth 1 -type d -name '20*' -mtime +60 -exec rm -rf {} + 2>/dev/null || true
}
