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
        ns_log S6 "dry-run: digest rendered, not sent"
        return 0
    fi
    # `digest sent` used to be logged whenever sendmail exited 0, which is an assertion that
    # cannot fail: sendmail exits 0 whenever smtplib does not raise, and smtplib does not raise
    # for a send that never transmitted. The RECEIPT is the server's own 250 acceptance of the
    # DATA payload; no non-send produces one. Stdout carries it, stderr carries the scrubbed
    # protocol transcript (see scrub_smtp_debug -- the raw one contains the password).
    local receipt=""
    if receipt="$(printf '%s' "$summary" | ns_jac sendmail send "$CONFIG" 2> "$LOG_DIR/smtp-debug.txt")"; then
        case "$receipt" in
            "") email_last_ditch "sendmail exited 0 with NO server receipt — treat as not delivered" ;;
            *)  printf '%s\n' "$receipt" > "$LOG_DIR/SMTP_RECEIPT"
                ns_log S6 "digest accepted by $NS_EMAIL_SMTP_HOST for $NS_EMAIL_TO — receipt: $receipt" ;;
        esac
    else
        email_last_ditch "smtp send failed — see $LOG_DIR/smtp-debug.txt"
    fi
}

# SMTP down → marker file + macOS banner, so a missing morning email is still a signal (TPRD 12)
email_last_ditch() {
    touch "$LOG_DIR/EMAIL_FAILED"
    ns_log S6 "EMAIL FAILED: $1"
    osascript -e 'display notification "digest email failed — check logs" with title "Nightshift"' \
        2>/dev/null || true
}
