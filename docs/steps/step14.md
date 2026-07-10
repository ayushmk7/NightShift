# Step 14 — launchd, dry-run, and testing the harness itself (M4 complete)

## Goal

Make it *unattended* and make it *trustworthy*: the LaunchAgent (user domain — it
must see your login Keychain for the Claude subscription and your `gh` auth), the
02:00 schedule with wake-on-missed semantics, the empirical checks for TechnicalPRD
feasibility rows 13–15, and the harness's own test suite (TechnicalPRD §14): a
`fixtures/mini-jac-repo`, golden-audit replay through the selector, the scope-gate
test, the chaos-resume test, and the Jac helpers' `jac test` sweep. Implements
PRD §10 and TechnicalPRD §14/§16.

## Prerequisites

Steps 1–13 all green; at least one successful manual `bin/nightshift.sh run`.

## Files created

```
~/nightshift/config/com.nightshift.plist     → installed to ~/Library/LaunchAgents/
~/nightshift/fixtures/mini-jac-repo/         # tiny planted-defect Jac project
~/nightshift/fixtures/golden-audit.json      # canned audit envelope
~/nightshift/bin/test-harness.sh             # the whole suite, one command
```

## 14.1 launchd integration

### `config/com.nightshift.plist`

Replace `YOURUSER` (2 places); note the PATH line — launchd's default PATH is the
number-one documented cause of silent stdio/plugin failures (feasibility row 15).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.nightshift</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/caffeinate</string><string>-i</string>
    <string>/Users/YOURUSER/nightshift/bin/nightshift.sh</string><string>run</string>
  </array>
  <key>StartCalendarInterval</key><dict>
    <key>Hour</key><integer>2</integer><key>Minute</key><integer>0</integer>
  </dict>
  <key>EnvironmentVariables</key><dict>
    <!-- launchd's minimal PATH is the #1 documented cause of silent failures (TPRD row 15) -->
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>/Users/YOURUSER/nightshift/logs/launchd.out</string>
  <key>StandardErrorPath</key><string>/Users/YOURUSER/nightshift/logs/launchd.err</string>
</dict></plist>
```

### Install, test-fire, and the empirical checks

```bash
cp ~/nightshift/config/com.nightshift.plist ~/Library/LaunchAgents/
launchctl bootstrap "gui/$UID" ~/Library/LaunchAgents/com.nightshift.plist
launchctl print "gui/$UID/com.nightshift" | head -20        # loaded?

# THE empirical moment (rows 13–15): fire the whole night through launchd, now,
# while you're watching — not at 02:00 while you're asleep.
launchctl kickstart -k "gui/$UID/com.nightshift"
tail -f ~/nightshift/logs/launchd.err ~/nightshift/logs/"$(date +%F)"/run.log
```

- Keychain check (row 14): if S0's pong probe fails **only** under launchd, mint
  `claude setup-token` and put `CLAUDE_CODE_OAUTH_TOKEN` in `~/.nightshift.env`.
- PATH check (row 15): a `command not found` in `launchd.err` means a `[paths]`
  entry is empty or wrong.
- Optional self-wake: `sudo pmset repeat wakeorpoweron MTWRFSU 01:58:00`. A lid
  closed at 02:00 without it = a late run on wake (launchd runs missed
  `StartCalendarInterval` jobs), never a skipped one; the S0 lock prevents pile-ups.

## 14.2 `fixtures/mini-jac-repo`

A miniature stand-in for the jaseci clone: small enough that the full gate runs in
seconds, planted so every detector has something to detect.

```
fixtures/mini-jac-repo/
├── pkg/
│   ├── main.jac          # calls used(); contains an OBVIOUSLY dead function `never_called`
│   └── dup.jac           # the same 6-line helper pasted twice (duplication bait)
├── pkg/tests/
│   └── fixtures/weird.jac  # intentionally unformatted — must NEVER be touched
└── README.md
```

```bash
mkdir -p ~/nightshift/fixtures/mini-jac-repo/pkg/tests/fixtures
cd ~/nightshift/fixtures/mini-jac-repo
cat > pkg/main.jac <<'EOF'
def used(x: int) -> int {
    return x + 1;
}

def never_called(x: int) -> int {
    return x * 999;
}

with entry {
    print(used(1));
}
EOF
cat > pkg/tests/fixtures/weird.jac <<'EOF'
with entry {   print(   "intentionally weird formatting"   );   }
EOF
git init -q && git add -A && git commit -qm "mini fixture" && git branch -M main
```

### `fixtures/golden-audit.json`

Capture one real audit envelope (step 9's verification already produced
`logs/<date>/audit.json`) — or hand-write one in the same shape:

```bash
cp ~/nightshift/logs/<date>/audit.json ~/nightshift/fixtures/golden-audit.json
```

## 14.3 `bin/test-harness.sh` — the suite

```bash
#!/usr/bin/env bash
# bin/test-harness.sh — CI-of-the-harness (TechnicalPRD 14). Run after any harness change.
set -euo pipefail
NS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$NS_ROOT"
fail() { echo "FAIL: $1" >&2; exit 1; }

echo "== 1. jac helpers: check + test sweep =="
for f in scripts/*.jac; do
    jac check "$f" >/dev/null || fail "jac check $f"
done
for f in nslib config ledger check_scope parse_result selector render_draft sendmail; do
    jac test "scripts/$f.jac" >/dev/null || fail "jac test $f"
done

echo "== 2. bash: syntax sweep =="
for f in bin/nightshift.sh lib/*.sh; do bash -n "$f" || fail "bash -n $f"; done

echo "== 3. golden-audit replay: selector must be deterministic =="
T="$(mktemp -d)"
jac run scripts/parse_result.jac findings < fixtures/golden-audit.json > "$T/f.json" \
    || fail "golden audit no longer parses"
jac run scripts/selector.jac select jac config/nightshift.toml /nonexistent /nonexistent 999 \
    < "$T/f.json" > "$T/s1.json"
jac run scripts/selector.jac select jac config/nightshift.toml /nonexistent /nonexistent 999 \
    < "$T/f.json" > "$T/s2.json"
cmp -s "$T/s1.json" "$T/s2.json" || fail "selector output not deterministic"

echo "== 4. scope gate: protected diff must be rejected =="
printf '{"package":"pkg","files":["pkg/tests/fixtures/weird.jac"]}' > "$T/theme.json"
if printf 'pkg/tests/fixtures/weird.jac\n' \
    | jac run scripts/check_scope.jac check "$T/theme.json" config/nightshift.toml >/dev/null; then
    fail "scope gate let a protected path through"
fi

echo "== 5. chaos resume: kill mid-run, rerun, no duplicate stages =="
export NS_ROOT
( bin/nightshift.sh dry-run & pid=$!; sleep 20; kill -9 $pid ) || true
rm -rf /tmp/nightshift.lock                       # -9 skipped the trap; reclaim
before=$(ls ~/nightshift/logs/"$(date +%F)"/.done-S* 2>/dev/null | wc -l)
bin/nightshift.sh dry-run >/dev/null 2>&1 || true
after=$(ls ~/nightshift/logs/"$(date +%F)"/.done-S* 2>/dev/null | wc -l)
[ "$after" -ge "$before" ] || fail "resume lost stage markers"
grep -c "already done — skipping" ~/nightshift/logs/"$(date +%F)"/run.log >/dev/null \
    || fail "resume did not skip completed stages"

echo "ALL HARNESS TESTS PASSED"
```

```bash
chmod +x ~/nightshift/bin/test-harness.sh
```

## Commands

```bash
~/nightshift/bin/test-harness.sh
launchctl kickstart -k "gui/$UID/com.nightshift"
```

## Acceptance criteria

- [ ] `test-harness.sh` prints `ALL HARNESS TESTS PASSED`.
- [ ] The launchd kickstart run completes and the digest email arrives — proving
      Keychain + PATH + node under launchd (rows 13–15 all observed, not assumed).
- [ ] `~/.nightshift/DISABLE` + kickstart → exit 41 + "DISABLED" digest; remove the
      file after.
- [ ] The morning after the first scheduled 02:00 run: email in inbox, subject
      matches the grammar, and `nightshift.sh status` agrees with it.
- [ ] `nightshift.sh dry-run` never pushes and never emails (prints both) — the
      seams (`ns_git_push`, `sendmail render`) hold.

## Verification procedure

The step **is** verification. Sequence: `test-harness.sh` → kickstart → DISABLE
test → one real scheduled night → first fork-internal promote (step 13) → after a
week of promote-rate data, your first upstream promote.

## Notes & traps

- LaunchAgent, **not** LaunchDaemon: daemons run outside your login session and
  can't see the Keychain (Claude subscription) or your `gh` auth. User domain also
  means the Mac must be on (or wakeable) with you logged in — that's the honest
  constraint (PRD §10).
- `kill -9` in the chaos test bypasses the EXIT trap, so the lock survives; the
  next S0 reclaims it via the dead-pid check. That's the designed behavior — the
  test also documents it.
- `caffeinate -i` (in the plist's ProgramArguments) blocks *idle* sleep during the
  run but not lid-close; `pmset repeat` handles waking for the schedule.
- Keep the harness itself under version control (`git init ~/nightshift`) — it
  edits a compiler nightly, and you'll want to bisect the harness someday too.
- Re-run `test-harness.sh` after **every** harness edit and every `jac`/Claude
  Code/ponytail upgrade (which are manual and reviewed — TechnicalPRD §17).
