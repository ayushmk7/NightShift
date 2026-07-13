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
    # Explicitly reap our self-caffeinate/self-timebox background children instead of trusting
    # `disown` alone to let bash exit immediately — observed once (under launchd/Terminal-launch)
    # that this process stayed alive, idle, long after every stage finished.
    [ -n "${NS_CAFFEINATE_PID:-}" ] && kill "$NS_CAFFEINATE_PID" 2>/dev/null
    [ -n "${NS_WATCHDOG_PID:-}" ] && kill "$NS_WATCHDOG_PID" 2>/dev/null
    exit "$code"
}

ns_run() {
    mkdir -p "$LOG_DIR" "$NS_ROOT/state"
    [ -f "$LOG_DIR/start_epoch" ] || date +%s > "$LOG_DIR/start_epoch"

    # Self-caffeinate AND self-timebox as OUR OWN background children (forked, never exec'd/wrapped).
    # Two macOS/TCC footguns on an external-volume repo, both found the hard way under launchd:
    #   1. launchd -> caffeinate -> bash: TCC attributes disk access to the immediate spawning
    #      process (caffeinate), so Full Disk Access granted to /bin/bash never applied — every
    #      launchd-fired run died EPERM before touching a file.
    #   2. The old `exec gtimeout ... "$0" run` re-execs a FRESH process image over this pid; the
    #      resulting child (forked by gtimeout, execve'd again via the script's own shebang) reads to
    #      macOS as a new "responsible" identity needing a first-run TCC consent prompt — which a
    #      headless LaunchAgent can never show, so the very next open() blocks FOREVER instead of
    #      erroring (confirmed via `sample`: stuck in libsystem_kernel `open`).
    # Forked (not exec'd) children inherit this process's already-granted FDA identity — proven by
    # every subprocess the pipeline forks below (git, jac, claude, gh, pre-commit) all working fine.
    if command -v caffeinate >/dev/null 2>&1; then
        caffeinate -i -w $$ >/dev/null 2>&1 &
        NS_CAFFEINATE_PID=$!
        disown
    fi
    # gtimeout's default behavior: TERM first (EXIT trap still runs -> autopsy email), KILL after a
    # grace period if TERM didn't land.
    ( sleep "$(( NS_BUDGETS_WALLCLOCK_MIN * 60 ))"; kill -TERM $$ 2>/dev/null; sleep 30; kill -KILL $$ 2>/dev/null ) &
    NS_WATCHDOG_PID=$!
    disown

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
