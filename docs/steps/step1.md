# Step 1 — Bootstrap & environment (PRD M0)

## Goal

Stand up everything Nightshift assumes exists: the fork and clone, the `jac`
toolchain green on a virgin clone, Claude Code authenticated on the Pro/Max
subscription and verified **headless**, the ponytail plugin, the exported Jac agent
skills, the `jac mcp` compiler server registered, `gh` authenticated, and the
`~/nightshift/` workspace scaffold with absolute binary paths pinned. Implements
PRD §13-M0 and resolves the three empirical facts from TechnicalPRD §2 (rows
13–15): pytest wall time, launchd↔Keychain, launchd PATH.

## Prerequisites

- macOS, logged-in user account (LaunchAgents run in the user domain — PRD §10).
- A GitHub account with a fork of `jaseci-labs/jaseci` (create below if missing).
- Homebrew (for `gh`, `coreutils`); Node ≥ 18 on PATH (ponytail's hooks need it).
- A Claude Pro/Max subscription.

## Files created

```
~/nightshift/
├── bin/  lib/  scripts/  prompts/  config/
├── work/                    # repo/ and drafts/ worktrees arrive in step 5
├── state/
└── logs/
~/.nightshift.env            # chmod 600
~/.nightshift/               # kill-switch directory (empty for now)
```

## Implementation

### 1.1 Fork, clone, remotes

```bash
gh auth login                # if not already; needs repo scope on your fork
gh repo fork jaseci-labs/jaseci --clone=false   # no-op if the fork exists

mkdir -p ~/nightshift/{bin,lib,scripts,prompts,config,work,state,logs}
git clone "https://github.com/$(gh api user -q .login)/jaseci.git" ~/nightshift/work/repo
cd ~/nightshift/work/repo
git remote add upstream https://github.com/jaseci-labs/jaseci.git
git fetch upstream
# safety net: no accidental pushes without an explicit refspec (threat T3)
git config push.default nothing
```

### 1.2 Jac toolchain green on a virgin clone

```bash
# install jac (official installer or pipx/uv — pick one and stick with it)
uv tool install jaclang        # or: pip install jaclang
jac --version                  # expect 0.16.x or newer

cd ~/nightshift/work/repo
python3 -m venv .venv && .venv/bin/pip install -e ".[dev]" pre-commit pytest-xdist  # per repo README
jac check                      # must be green on the virgin clone
.venv/bin/pre-commit install --install-hooks
```

### 1.3 The timing run (calibrates the whole harness)

```bash
cd ~/nightshift/work/repo
time .venv/bin/python -m pytest jac -n auto -q   # WRITE THIS NUMBER DOWN
```

This number is **the** input to the budget math (TechnicalPRD §15): the S4 box is
65 min for up to 4 branches, so per-branch verify must average ≤ ~16 min. If the
suite takes > 20 min, set `themes_per_night = 2` in step 2's config — do **not**
subset the suite (PRD §14-Q4).

### 1.4 Claude Code: subscription auth, verified headless

```bash
claude          # interactive once: /login with your Pro/Max account, then exit
# the actual assertion Nightshift's preflight will make every night:
claude -p "reply with exactly: pong" --max-turns 1 --output-format json
# expect: {"result":"pong", ...}
```

If a later launchd test-fire (step 14) can't reach the Keychain credentials, the
sanctioned fallback is:

```bash
claude setup-token             # 1-year inference-only OAuth token
# put the token in ~/.nightshift.env as CLAUDE_CODE_OAUTH_TOKEN=...
```

### 1.5 Ponytail plugin + Jac agent skills + jac MCP server

```bash
claude          # inside the REPL:
#   /plugin marketplace add DietrichGebert/ponytail
#   /plugin install ponytail@ponytail
#   exit

jac guide --export ~/.claude/skills     # Jac reference guides as auto-loading Agent Skills

# register the compiler MCP server at LOCAL scope, keyed to the clone's path —
# stored in ~/.claude.json, so the clone stays a pristine mirror (no committed .mcp.json)
cd ~/nightshift/work/repo
claude mcp add jac -- jac mcp
claude mcp list                         # expect: jac (stdio) — connected
```

Pin the ponytail version you installed (note it somewhere you'll see during
upgrades). Policy: never auto-update; review release notes first (threat T5).

### 1.6 Secrets file and kill-switch directory

```bash
mkdir -p ~/.nightshift
cat > ~/.nightshift.env <<'EOF'
SMTP_USER=you@gmail.com
SMTP_PASS=your-app-password        # Gmail: 2FA + app password
# CLAUDE_CODE_OAUTH_TOKEN=...      # only if the Keychain path fails (step 14)
EOF
chmod 600 ~/.nightshift.env
```

### 1.7 Pin absolute paths

launchd's PATH is minimal; every binary is pinned as an absolute path in step 2's
`config/nightshift.toml [paths]`. Collect them now:

```bash
command -v jac claude gh node
echo "venv: $HOME/nightshift/work/repo/.venv"
brew install coreutils            # gtimeout — stage time-boxes (fallback exists, but this is better)
```

## Commands (recap, in order)

All commands above, top to bottom. Nothing else.

## Acceptance criteria

- [ ] `git -C ~/nightshift/work/repo remote -v` shows `origin` = your fork, `upstream` = jaseci-labs.
- [ ] `git -C ~/nightshift/work/repo config push.default` prints `nothing`.
- [ ] `jac check` green on the virgin clone; `pytest jac -n auto` green, wall time recorded.
- [ ] `claude -p "reply with exactly: pong" --max-turns 1 --output-format json` returns `"result":"pong"` from a **non-interactive** shell (e.g. `zsh -c '...'`).
- [ ] `/plugin` list shows ponytail installed; `ls ~/.claude/skills` shows the exported jac-* skills.
- [ ] `claude mcp list` run from inside the clone shows the `jac` stdio server connected.
- [ ] `~/.nightshift.env` exists with mode 600.
- [ ] Absolute paths for `jac`, `claude`, `gh`, node dir, venv written down for step 2.

## Verification procedure

Run the pong probe and `jac check` from a fresh terminal with a **minimal PATH** to
simulate launchd:

```bash
env -i HOME="$HOME" PATH="/usr/bin:/bin" "$(command -v claude)" -p "reply with exactly: pong" --max-turns 1 --output-format json
```

If this fails while the normal-shell probe passes, you have found the launchd PATH
problem *now* instead of at 02:00 — the plist's PATH (step 14) and the pinned
`[paths]` (step 2) are the fix.

## Notes & traps

- **`ANTHROPIC_API_KEY`**: if it is set anywhere in your environment, headless runs
  silently bill per-token instead of using the subscription. The harness force-unsets
  it (step 2), but also remove it from your dotfiles if you don't need it.
- The test-suite timing (1.3) is a *budget input*, not trivia. Re-measure after big
  upstream changes; `nightshift.sh status` nights drifting past the verify box is
  the symptom.
- ponytail needs Node for its lifecycle hooks; a missing node under launchd fails
  *silently* (skills just don't load). That's why `node_dir` is pinned in config.
- Do not commit a `.mcp.json` into the clone — local-scope registration keeps the
  clone byte-identical to upstream.
