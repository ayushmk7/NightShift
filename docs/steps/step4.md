# Step 4 — S0 Preflight

## Goal

`lib/preflight.sh`: the fail-fast stage that verifies the world before anything is
touched — kill switch, binaries + versions, `gh` auth, network probe, toolchain
drift detection (warn-don't-upgrade, TechnicalPRD §17), and the Claude headless
"pong" probe. Any failure exits with a specific code (TechnicalPRD §18) and the
EXIT trap (step 8) still emails. Implements TechnicalPRD §7-S0.

## Prerequisites

Steps 2–3 (`common.sh` env + `ledger.jac` for state drift bookkeeping).
Step 1's pong probe worked interactively.

## Files created

```
~/nightshift/lib/preflight.sh
```

## Full implementation

### `lib/preflight.sh`

```bash
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
```

## Commands

```bash
bash -n ~/nightshift/lib/preflight.sh
```

## Acceptance criteria

- [ ] `bash -n` silent.
- [ ] With `~/.nightshift/DISABLE` touched, running the stage exits 41 and leaves
      `$LOG_DIR/DISABLED` behind (so the digest says "disabled" — step 8).
- [ ] With Wi-Fi off, the stage exits 43 without modifying anything.
- [ ] With everything healthy, the stage passes and `$LOG_DIR/S0.log` records one
      version line per binary.
- [ ] Changing `state.json`'s `last_jac_version` by hand then running the stage
      produces a drift warning in `$LOG_DIR/warnings.txt` and rewrites the state key.

## Verification procedure

The stage functions are sourced, so test them without the full entry script:

```bash
cd ~/nightshift
export NS_ROOT="$PWD"
. lib/common.sh; ns_load_config; . lib/preflight.sh
mkdir -p "$LOG_DIR"; date +%s > "$LOG_DIR/start_epoch"

touch ~/.nightshift/DISABLE
( preflight_main ); echo "exit=$?"          # expect 41 + DISABLED marker
rm ~/.nightshift/DISABLE

( preflight_main ); echo "exit=$?"          # expect 0 on a healthy machine
grep -c . "$LOG_DIR/warnings.txt" 2>/dev/null || echo "no warnings"
```

(Subshell parentheses keep `ns_die`'s `exit` from killing your shell.)

## Notes & traps

- The pong probe is the **real** auth assertion, not `claude --version`: version
  checks pass while credentials are broken. Expect ~5–15 s; it's time-boxed to 3 min.
- The probe greps the envelope for `"result":"pong"` instead of using
  `parse_result.jac` — at S0 the concern is auth, not schema, and grep can't be
  broken by the thing it's checking.
- Drift policy is *warn, don't upgrade* (TechnicalPRD §17): the harness edits a
  compiler; changing the compiler the same night it edits code is two variables at
  once. Upgrading `jac` is always a manual, daytime act.
- The log-retention prune (60 nights) lives here because S0 is the one stage
  guaranteed to run every night.
