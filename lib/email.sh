# shellcheck shell=bash
# lib/email.sh — S6 (TechnicalPRD 7-S6). Runs from the EXIT trap: fires on success,
# failure, ceiling kill (TERM), and DISABLE alike. Silence must stay detectable.

email_main() {
    local summary
    if ! summary="$(ns_jac sendmail summarize "$LOG_DIR" "$DRAFTS/drafts" "$NS_DATE" "$CONFIG")"; then
        email_last_ditch "summarize failed"
        return 0
    fi
    printf '%s' "$summary" > "$LOG_DIR/run-summary.json"

    if [ -n "${NS_DRY_RUN:-}" ]; then
        printf '%s' "$summary" | ns_jac sendmail render "$CONFIG"
        return 0
    fi
    if ! printf '%s' "$summary" | ns_jac sendmail send "$CONFIG"; then
        email_last_ditch "smtp send failed"
    fi
}

# SMTP down → marker file + macOS banner, so a missing morning email is still a signal (TPRD 12)
email_last_ditch() {
    touch "$LOG_DIR/EMAIL_FAILED"
    ns_log S6 "EMAIL FAILED: $1"
    osascript -e 'display notification "digest email failed — check logs" with title "Nightshift"' \
        2>/dev/null || true
}
