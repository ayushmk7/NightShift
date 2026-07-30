# shellcheck shell=bash
# lib/cimirror.sh — local replica of the ci.yml jobs a FORK PR cannot reach.
#
# 13 of ~16 ci.yml jobs run on blacksmith-4vcpu-ubuntu-2404, runners attached to the upstream
# org. On the fork they queue forever (confirmed 2026-07-30), so fork CI is not a pre-PR gate
# and this file is. Commands live in config/ci-mirror.toml next to a hash of ci.yml;
# bin/test-harness.sh fails when that hash drifts.

CI_MIRROR_CONFIG="$NS_ROOT/config/ci-mirror.toml"

# Print the commands of one [jobs.<name>] table, one per line.
cimirror_cmds() {
    ns_jac cimirror cmds "$1" "$CI_MIRROR_CONFIG"
}

# CI's exact fmt invocation, single source of truth for both tier-1 and the mirror.
cimirror_fmt_cmd() {
    cimirror_cmds fmt | head -1
}

# Run one mirrored job. Repo dev binary first on PATH so `jac` means the target repo's jac.
# Clean HOME per job: the bundled test runner's conftest import fails against a populated HOME.
# It lives HERE, not in the caller, so `nightshift.sh mirror` gets it too -- a caller-side HOME
# would silently omit it from the one path a human uses to debug a red branch.
cimirror_job() {
    local job=$1 out=$2 cmd rc=0 first_rc=0 H
    H="$(mktemp -d)"
    ns_log MIRROR "job $job"
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
    done < <(cimirror_cmds "$job")
    return "$first_rc"
}

# Run every mirrored job in config order, stopping at the first failure.
# Fail-fast on purpose: a formatting failure makes the ~40min test jobs pointless.
cimirror_all() {
    local out=$1 job
    : > "$out"
    for job in $(ns_jac cimirror jobs "$CI_MIRROR_CONFIG"); do
        if ! cimirror_job "$job" "$out"; then
            ns_log MIRROR "FAILED at job $job — skipping the rest"
            echo "$job" > "$LOG_DIR/mirror-failed-job.txt"
            return 1
        fi
    done
    rm -f "$LOG_DIR/mirror-failed-job.txt"
    ns_log MIRROR "all jobs green"
    return 0
}
