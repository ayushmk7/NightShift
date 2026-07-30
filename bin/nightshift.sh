#!/usr/bin/env bash
# bin/nightshift.sh — Nightshift entry point: run | dry-run | promote | discard | status
set -euo pipefail

NS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NS_ROOT

# CI/CD ENVIRONMENT FIX: launchd fires Terminal.app with minimal environment, missing Homebrew PATH.
# Add common paths before anything else to ensure gh, jac, claude, etc. are found.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# shellcheck source=../lib/common.sh
. "$NS_ROOT/lib/common.sh"
. "$NS_ROOT/lib/preflight.sh"
. "$NS_ROOT/lib/sync.sh"
. "$NS_ROOT/lib/tier2.sh"
. "$NS_ROOT/lib/verify.sh"
. "$NS_ROOT/lib/ship.sh"
. "$NS_ROOT/lib/email.sh"
. "$NS_ROOT/lib/promote.sh"
. "$NS_ROOT/lib/dataset.sh"
. "$NS_ROOT/lib/cimirror.sh"

ns_on_exit() {
    local code=$?
    if [ "$code" -ne 0 ] && [ -f "$LOG_DIR/CURRENT_STAGE" ]; then
        cp "$LOG_DIR/CURRENT_STAGE" "$LOG_DIR/ERROR_STAGE"
    fi
    # ERROR_STAGE names WHERE the night died; FATAL_REASON (written by ns_die, lib/common.sh) says
    # WHY. Folded into warnings.txt because that is the one channel scripts/sendmail.jac already
    # renders verbatim in the digest -- the operator's only unattended feedback loop. Without this
    # every ns_die in the pipeline reads identically as "ERROR S4" in the email, and there are 13
    # of them in lib/verify.sh alone. `>>` on the same file the digest reads, not a new schema
    # field: the full digest treatment is Plan 4's job.
    if [ "$code" -ne 0 ] && [ -f "$LOG_DIR/FATAL_REASON" ]; then
        printf 'FATAL (%s): %s\n' \
            "$(cat "$LOG_DIR/ERROR_STAGE" 2>/dev/null || echo "no stage")" \
            "$(cat "$LOG_DIR/FATAL_REASON")" >> "$LOG_DIR/warnings.txt" 2>/dev/null || true
    fi
    email_main >> "$LOG_DIR/S6.log" 2>&1 || true
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
    # Unconditional: the watchdog sleeps from *process* start, so the budget clock must too.
    # A same-day re-run inheriting the 02:00 epoch once yielded "-414m remaining" and a skipped S3.
    date +%s > "$LOG_DIR/start_epoch"
    # Same-night re-runs share $LOG_DIR (it is date-keyed), so a FATAL_REASON left by an earlier
    # attempt would be re-reported against this one. Cleared here, next to the epoch, for the same
    # reason that is unconditional.
    rm -f "$LOG_DIR/FATAL_REASON"

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
    # S2 (tier-1 deterministic autofix) was retired 2026-07-30: a byllm-only formatting PR is noise,
    # a repo-wide one is unmergeable (~259 pre-existing violations on main), and upstream only checks
    # formatting repo-wide on push. Themes now format their own edits; [jobs.fmt] gates that.
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
       nightshift.sh mirror [branch]            # run the whole CI mirror against a branch (slow)
       nightshift.sh dataset-backfill           # rebuild dataset/*.jsonl from past real nights
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
    # Hand-debugging a red branch. Runs EVERY gate job in config order (fmt, check, jir, byllm,
    # compiler, runtime, contribution), stopping at the first failure -- so it is fast on a branch
    # that is broken early and ~40min+ on one that is only broken late. That breadth is the point:
    # S4 runs a deliberately narrowed subset (only the suites gated_suites_from_diff routes to), and
    # this is the command for "CI is red and the gate was green, what did the gate not run?".
    #
    # Every line below is written the way it is because bin/nightshift.sh runs under `set -e`:
    #   * `|| rc=$?`, not `cimirror_all ...; rc=$?` -- a nonzero from cimirror_all is the NORMAL way
    #     a red job is reported, and as a bare simple command it would abort this script before
    #     `rc=$?` ever ran, losing both the exit code and the tail below.
    #   * `if`, not `[ -f ... ] && echo ...` -- on a GREEN run the file does not exist, the `&&` list
    #     returns nonzero, and errexit would kill the script right before `exit "$rc"`, turning a
    #     passing mirror into a nonzero exit.
    # mirror-failed-job.txt is cleared first so a stale one from an earlier run in the same night
    # cannot be reported against this one, and its two reader sentinels are handled by name
    # (lib/cimirror.sh writes "(job-list-read-failure)" / "(empty-job-list)" there instead of a job).
    mirror)     mkdir -p "$LOG_DIR"; ns_load_env
                # Refuse to run underneath a live night. This is the command an operator is most
                # tempted to fire mid-run, and it would `git checkout` in $REPO out from under
                # S2/S3/S4 and share $LOG_DIR/mirror-home with them. It deliberately does NOT call
                # ns_lock_acquire: that reclaims a stale lock and there is no EXIT trap on this path
                # to release it, so a manual mirror would leave /tmp/nightshift.lock held forever
                # and block every subsequent night. Read-only liveness check instead.
                if [ -f "$LOCK_DIR/pid" ]; then
                    holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
                    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
                        ns_die "$EX_LOCK" "a nightly run (pid $holder) is live; 'mirror' would git-checkout in $REPO underneath it and share its mirror-home. Wait for it to finish, or stop it first."
                    fi
                fi
                rm -f "$LOG_DIR/mirror-failed-job.txt"
                # `|| ns_die`: a typo'd branch name otherwise exits 1 under errexit — the SAME code a
                # genuinely red job returns — with none of this arm's diagnostics printed.
                if [ $# -ge 1 ]; then
                    git -C "$REPO" checkout "$1" \
                        || ns_die "$EX_BUG" "no such branch '$1' in $REPO — nothing was mirrored."
                fi
                rc=0; cimirror_all "$LOG_DIR/mirror-manual.txt" || rc=$?
                if [ -f "$LOG_DIR/mirror-failed-job.txt" ]; then
                    failed_job="$(cat "$LOG_DIR/mirror-failed-job.txt")"
                    case "$failed_job" in
                        '(job-list-read-failure)')
                            echo "mirror: could not read the job list from config/ci-mirror.toml — the harness is broken, not the branch" >&2 ;;
                        '(empty-job-list)')
                            echo "mirror: config/ci-mirror.toml yielded an EMPTY job list — the harness is broken, not the branch" >&2 ;;
                        *)  echo "failed job: $failed_job" >&2 ;;
                    esac
                elif [ "$rc" -ne 0 ]; then
                    # Should be unreachable: cimirror_all writes that file on every failure path.
                    echo "mirror: rc=$rc but no failing job was recorded — see $LOG_DIR/mirror-manual.txt" >&2
                fi
                tail -40 "$LOG_DIR/mirror-manual.txt"
                exit "$rc" ;;
    dataset-backfill) mkdir -p "$LOG_DIR"; dataset_backfill ;;
    *)          usage ;;
esac
