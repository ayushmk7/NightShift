#!/usr/bin/env bash
# bin/nightshift.sh — Nightshift entry point: run | dry-run | promote | discard | status
set -euo pipefail

NS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NS_ROOT

# shellcheck source=../lib/common.sh
. "$NS_ROOT/lib/common.sh"
. "$NS_ROOT/lib/preflight.sh"
. "$NS_ROOT/lib/sync.sh"
. "$NS_ROOT/lib/tier1.sh"
. "$NS_ROOT/lib/tier2.sh"
. "$NS_ROOT/lib/verify.sh"
. "$NS_ROOT/lib/ship.sh"
. "$NS_ROOT/lib/email.sh"
. "$NS_ROOT/lib/promote.sh"

ns_on_exit() {
    local code=$?
    if [ "$code" -ne 0 ] && [ -f "$LOG_DIR/CURRENT_STAGE" ]; then
        cp "$LOG_DIR/CURRENT_STAGE" "$LOG_DIR/ERROR_STAGE"
    fi
    email_main || true
    ns_lock_release
    exit "$code"
}

ns_run() {
    mkdir -p "$LOG_DIR" "$NS_ROOT/state"
    [ -f "$LOG_DIR/start_epoch" ] || date +%s > "$LOG_DIR/start_epoch"

    # hard wall-clock ceiling (TPRD budgets): re-exec self under a timeout wrapper.
    # gtimeout sends TERM first, so the child's EXIT trap still emails the autopsy.
    # (NS_DRY_RUN survives the exec because it is exported.)
    if [ -z "${NS_TIMEBOXED:-}" ] && command -v gtimeout >/dev/null 2>&1; then
        export NS_TIMEBOXED=1
        exec gtimeout --signal=TERM "${NS_BUDGETS_WALLCLOCK_MIN}m" "$0" run
    fi
    # no gtimeout → run un-boxed; the per-stage boxes still bound the damage
    ns_run_inner
}

ns_run_inner() {
    ns_lock_acquire
    ns_load_env
    trap 'ns_on_exit' EXIT TERM INT

    ns_stage S0 preflight_main
    ns_stage S1 sync_main
    ns_stage S2 tier1_main
    ns_stage S3 tier2_main
    ns_stage S4 verify_main
    ns_stage S5 ship_main
    # S6 (email) runs from the EXIT trap — success and failure paths alike
}

usage() {
    cat >&2 <<'EOF'
usage: nightshift.sh run                        # the nightly pipeline (launchd calls this)
       nightshift.sh dry-run                    # same, but pushes/email stubbed to stdout
       nightshift.sh promote <branch> [repo]    # open the real PR (default: upstream)
       nightshift.sh discard <branch> [reason]  # bury the branch; the finding never resurfaces
       nightshift.sh status                     # last run summary + ledger tallies
       nightshift.sh baseline                   # record the test baseline on main (slow; M0)
EOF
    exit 2
}

cmd="${1:-}"; shift || true
ns_load_config

case "$cmd" in
    run)        ns_run ;;
    dry-run)    export NS_DRY_RUN=1; ns_run ;;
    promote)    [ $# -ge 1 ] || usage; mkdir -p "$LOG_DIR"; ns_load_env; promote_main "$@" ;;
    discard)    [ $# -ge 1 ] || usage; mkdir -p "$LOG_DIR"; discard_main "$@" ;;
    status)     status_main ;;
    baseline)   mkdir -p "$LOG_DIR" "$NS_ROOT/state"; ns_load_env; baseline_main ;;
    *)          usage ;;
esac
