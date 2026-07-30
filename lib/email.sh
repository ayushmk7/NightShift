# shellcheck shell=bash
# lib/email.sh — S6 (TechnicalPRD 7-S6). Runs from the EXIT trap: fires on success,
# failure, ceiling kill (TERM), and DISABLE alike. Silence must stay detectable.

email_main() {
    local summary
    # This runs inside the EXIT trap of a `set -euo pipefail` script, so it must return 0 on every
    # path -- a nonzero would change the exit code the night reports and skip ns_lock_release,
    # holding /tmp/nightshift.lock and blocking every subsequent night. ns_on_exit's `|| true` is
    # asserted by bin/test-harness.sh section 23, but relying on it alone would mean the failure of
    # one careless refactor is silent for weeks, so every write below is guarded on its own too.
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    if ! summary="$(ns_jac sendmail summarize "$LOG_DIR" "$DRAFTS/drafts" "$NS_DATE" "$CONFIG")"; then
        email_last_ditch "summarize failed"
        return 0
    fi
    # Best-effort: the digest still has the summary in hand, so an unwritable $LOG_DIR must not
    # stop it being SENT -- which is the only copy that reaches a human anyway.
    printf '%s' "$summary" 2>/dev/null > "$LOG_DIR/run-summary.json" \
        || ns_log S6 "could not persist run-summary.json under $LOG_DIR — sending anyway"

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
            *)  printf '%s\n' "$receipt" 2>/dev/null > "$LOG_DIR/SMTP_RECEIPT" || true
                ns_log S6 "digest accepted by $NS_EMAIL_SMTP_HOST for $NS_EMAIL_TO — receipt: $receipt" ;;
        esac
    else
        email_last_ditch "smtp send failed — see $LOG_DIR/smtp-debug.txt"
    fi
    return 0
}

# SMTP down → marker file + macOS banner, so a missing morning email is still a signal (TPRD 12)
email_last_ditch() {
    touch "$LOG_DIR/EMAIL_FAILED" 2>/dev/null || true
    ns_log S6 "EMAIL FAILED: $1"
    osascript -e 'display notification "digest email failed — check logs" with title "Nightshift"' \
        2>/dev/null || true
}
