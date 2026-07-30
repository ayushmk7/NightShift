# shellcheck shell=bash
# lib/cimirror.sh — local replica of the ci.yml jobs a FORK PR cannot reach.
#
# 13 of ~16 ci.yml jobs run on blacksmith-4vcpu-ubuntu-2404, runners attached to the upstream
# org. On the fork they queue forever (confirmed 2026-07-30), so fork CI is not a pre-PR gate
# and this file is. Commands live in config/ci-mirror.toml next to a hash of ci.yml;
# bin/test-harness.sh fails when that hash drifts.

CI_MIRROR_CONFIG="$NS_ROOT/config/ci-mirror.toml"
EX_MIRROR_READ=70   # matches lib/common.sh's EX_BUG: the harness's own reader is broken, not the
                     # candidate branch -- must never look like a clean pass or a clean skip.

# Print the commands of one [jobs.<name>] table, one per line.
cimirror_cmds() {
    ns_jac cimirror cmds "$1" "$CI_MIRROR_CONFIG"
}

# CI's exact fmt-CHECK invocation (PR/diff-scoped -- ci.yml's mode=scoped branch, the one that
# always applies to a Nightshift-opened PR). Verifies; does not modify.
cimirror_fmt_cmd() {
    cimirror_cmds fmt | head -1
}

# tier-1's fmt-APPLY invocation: [jobs.fmt_autofix], NOT a ci.yml job. Same tool/flags (minus
# --check)/exclusion-regex as cimirror_fmt_cmd, scoped to jac/jaclang/byllm instead of by diff --
# see config/ci-mirror.toml's [jobs.fmt_autofix] comment for why tier-1 can't reuse the diff-scoped
# check command directly (there is no diff yet when tier-1 runs; it runs before any other stage).
cimirror_fmt_autofix_cmd() {
    cimirror_cmds fmt_autofix | head -1
}

# Run one mirrored job. Repo dev binary first on PATH so `jac` means the target repo's jac.
#
# HOME is set to $LOG_DIR/mirror-home (created once, reused by every job/call in the SAME
# nightly run -- keyed by $LOG_DIR, which is stable for the whole night), not a fresh `mktemp -d`
# per job: measured on this host, a cold HOME makes `jac --version` alone take ~45s and write
# ~100MB ("Setting up Jac for first use... Jac setup complete (224 modules compiled and cached)"),
# so six gate jobs with a fresh HOME each would cost ~4.5min and ~600MB of throwaway cache EVERY
# mirror run -- CI itself avoids exactly this cost with its own "Warm up compiler cache" step
# (ci.yml:326-327) and a HOME it reuses across a job's own steps. Still isolated from the real
# $HOME (a human's actual jac cache/config is never touched), just not re-paid per job. Lives
# under logs/, which is already gitignored and already whatever a human does with old log
# directories -- no separate retention policy invented here.
#
# Reader failures must never look like success (code review 2026-07-30, Critical): `cimirror_cmds`
# is materialized into a variable and its exit status AND non-emptiness are both checked before
# the loop runs. The previous `done < <(cimirror_cmds "$job")` discarded the reader's exit status
# entirely (process substitution runs in its own subshell; bash does not propagate its exit code
# to the `read` loop it feeds) -- a malformed TOML, a renamed job, or any jac error in the reader
# produced ZERO commands, so the `while read` loop simply never ran, `first_rc` stayed 0, and the
# job silently reported green. Reproduced: `cimirror_job nosuchjob ...` used to print a Jac
# traceback, create no output, and return rc=0. Iterating via a here-string (`<<<`) instead of
# process substitution means there is no subshell losing an exit code in the first place.
cimirror_job() {
    local job=$1 out=$2 cmd rc=0 first_rc=0 H cmds read_rc=0
    H="$LOG_DIR/mirror-home"
    mkdir -p "$H"
    ns_log MIRROR "job $job"
    # `|| read_rc=$?`, not a bare assignment then `[ $? ... ]`: under bin/nightshift.sh's
    # `set -euo pipefail`, `cmds="$(cimirror_cmds "$job")"` alone would abort the WHOLE harness
    # the instant the reader fails (verified: `x="$(false)"` under `set -e` exits immediately,
    # never reaching a following `if [ $? -ne 0 ]`) -- exactly the kind of failure this fix exists
    # to catch, just one line earlier. The `||` keeps errexit from firing so this function can
    # report the failure itself instead of silently taking the whole night down with it.
    cmds="$(cimirror_cmds "$job")" || read_rc=$?
    if [ "$read_rc" -ne 0 ]; then
        ns_log MIRROR "job $job: reader failed to list its commands -- treating as a hard failure, not a skip"
        printf '\n$ (reader failure: could not read [jobs.%s].commands from %s)\n' "$job" "$CI_MIRROR_CONFIG" >> "$out"
        return "$EX_MIRROR_READ"
    fi
    case "$cmds" in
        "")
            ns_log MIRROR "job $job: reader returned zero commands -- treating as a hard failure, not a clean pass"
            printf '\n$ (reader returned no commands for job "%s" -- check the job name and %s)\n' "$job" "$CI_MIRROR_CONFIG" >> "$out"
            return "$EX_MIRROR_READ"
            ;;
    esac
    while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue
        printf '\n$ %s\n' "$cmd" >> "$out"
        ( cd "$REPO" && export PATH="$(dirname "$NS_PATHS_JAC_REPO"):$PATH" HOME="$H" \
            && eval "$cmd" ) >> "$out" 2>&1 || rc=$?
        if [ "$rc" -ne 0 ] && [ "$first_rc" -eq 0 ]; then
            first_rc=$rc
            ns_log MIRROR "job $job: command failed (rc=$rc): $cmd"
        fi
        rc=0
    done <<< "$cmds"
    return "$first_rc"
}

# Run every mirrored job in config order, stopping at the first failure.
# Fail-fast on purpose: a formatting failure makes the ~40min test jobs pointless.
#
# Same reader-failure-must-not-look-like-success fix as cimirror_job, one level up: the job LIST
# itself is materialized and checked before the loop, instead of `for job in $(ns_jac cimirror
# jobs ...)`, whose failure or empty output previously made the `for` iterate zero times --
# `set -e` does not fire on `for x in $(false)`, so a broken reader here used to fall straight
# through to "all jobs green" and rc=0. Also returns the FAILING JOB'S OWN exit code (the brief's
# interface says "returns its code"), not a hardcoded 1 -- verified: a job that exits 7 now makes
# cimirror_all return 7, not 1.
cimirror_all() {
    local out=$1 job job_list rc=0
    : > "$out"
    # `|| rc=$?`, not a bare assignment then `[ $? ... ]` -- same `set -e` trap as cimirror_job:
    # `job_list="$(cmd)"` alone would abort this whole function (and the calling
    # bin/nightshift.sh) the instant the reader fails, before any check of it ever runs.
    job_list="$(ns_jac cimirror jobs "$CI_MIRROR_CONFIG")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        ns_log MIRROR "job list read failed -- treating as a hard failure, not a clean pass"
        echo "(job-list-read-failure)" > "$LOG_DIR/mirror-failed-job.txt"
        return "$EX_MIRROR_READ"
    fi
    case "$job_list" in
        "")
            ns_log MIRROR "job list is empty -- treating as a hard failure, not a clean pass"
            echo "(empty-job-list)" > "$LOG_DIR/mirror-failed-job.txt"
            return "$EX_MIRROR_READ"
            ;;
    esac
    for job in $job_list; do
        rc=0
        # `|| rc=$?`, not a bare call then `rc=$?`: cimirror_job returning nonzero is the NORMAL,
        # expected way a real job failure is reported, not an error in this script -- as a bare
        # simple command it would trip `set -e` and kill bin/nightshift.sh outright instead of
        # letting this function decide what to do with the failure (same class of bug as above,
        # just on the "a job legitimately failed" path instead of the "reader is broken" path).
        cimirror_job "$job" "$out" || rc=$?
        if [ "$rc" -ne 0 ]; then
            ns_log MIRROR "FAILED at job $job (rc=$rc) — skipping the rest"
            echo "$job" > "$LOG_DIR/mirror-failed-job.txt"
            return "$rc"
        fi
    done
    rm -f "$LOG_DIR/mirror-failed-job.txt"
    ns_log MIRROR "all jobs green"
    return 0
}
