# Step 2 — Config system & shared foundations

## Goal

Create the four files everything else imports: the single config file
(`config/nightshift.toml`, TechnicalPRD §6), the shared Jac library
(`scripts/nslib.jac` — fingerprinting, JSON/TOML boundary guards, ledger IO,
protect-glob matching), the config bridge (`scripts/config.jac` — TOML → shell
env / JSON / single key), the portable time-box (`scripts/timeout.jac` — macOS has
no GNU `timeout`), and the bash plumbing every stage sources (`lib/common.sh` —
logging, exit codes, mkdir-lock, stage markers, branch queue, dry-run seam).

## Prerequisites

Step 1 complete (workspace exists, absolute paths collected).

## Files created

```
~/nightshift/config/nightshift.toml
~/nightshift/scripts/nslib.jac
~/nightshift/scripts/config.jac
~/nightshift/scripts/timeout.jac
~/nightshift/lib/common.sh
```

## Full implementation

### 2.1 `config/nightshift.toml`

Fill in `fork`, `[email] to`, and every `[paths]` entry with the values collected in
step 1.7.

```toml
# config/nightshift.toml — every knob in one file (TechnicalPRD 6). Values are defaults.

[repo]
upstream       = "jaseci-labs/jaseci"
fork           = "YOURUSER/jaseci"          # <- set at M0
default_branch = "main"

[rotation]                                   # one package per night, round-robin (PRD 7 stage 3)
packages = ["jac", "jac-byllm", "jac-client", "jac-scale", "jac-mcp", "jac-super", "jaseci-package"]

[budgets]                                    # PRD 9 guardrails — no step may violate these
themes_per_night   = 3
files_per_theme    = 10
loc_per_theme      = 300
wallclock_min      = 180                     # hard ceiling for the whole night
box_sync_tier1_min = 15
box_agentic_min    = 90
box_verify_min     = 65
box_ship_email_min = 10
audit_timeout_min  = 15
apply_timeout_min  = 25                      # per theme session
max_turns          = 80                      # the real cost brake on a subscription
max_budget_usd     = 5                       # inert on subscription; belt if ever on an API key

[agent]
model         = ""                           # empty = account default
ponytail_mode = "full"                       # PRD 14-Q5

[protect]                                    # glob deny-list; enforced twice (prompt + S4 gate)
globs = [
  "**/tests/**", "**/fixtures/**", "**/*.test.jac",
  "**/jac.spec", "**/grammar/**", "**/generated/**", "**/vendor/**",
  "docs/**", "!docs/docs/community/release_notes/unreleased/**",
  ".github/**", "examples/**",
]

[email]
to        = "you@example.com"                # <- set at M0
from      = "nightshift@localhost"
smtp_host = "smtp.gmail.com"
smtp_port = 465                              # SSL; creds live in ~/.nightshift.env, never here

[paths]                                      # absolute paths pinned at M0 (launchd PATH is minimal)
jac      = ""                                # e.g. /Users/you/.local/bin/jac  (bootstrap-grepped)
claude   = ""                                # e.g. /Users/you/.local/bin/claude
gh       = ""                                # e.g. /opt/homebrew/bin/gh
node_dir = ""                                # e.g. /opt/homebrew/bin (ponytail hooks need node)
venv     = ""                                # the jaseci clone's venv, e.g. .../work/repo/.venv
```

### 2.2 `scripts/nslib.jac` — shared primitives

Every other helper does `import from nslib { ... }`. The `as_*`/`parse_*` functions
are the sanctioned pattern for Jac's strict `any → T` boundary (steps.md ground
rule 5); `eprint`/`read_stdin` work around the `TextIO | Any` typing of
`sys.stderr`/`sys.stdin` (rule 6).

```jac
"""Shared primitives for every Nightshift Jac helper.

Everything here is a pure function or thin IO wrapper; CLI entry points live in the
sibling scripts that `import from nslib { ... }`.
"""
import sys;
import os;
import json;
import tomllib;
import from hashlib { sha1 }
import from datetime { date, timedelta }
import from pathlib { PurePosixPath }

def eprint(msg: str) {
    err: any = sys.stderr;
    err.write(msg + "\n");
}

def read_stdin() -> str {
    stream: any = sys.stdin;
    return str(stream.read());
}

"""JSON boundary guards: json.loads returns Any; narrow it or die loudly."""
def parse_obj(s: str) -> dict {
    parsed: any = json.loads(s);
    if isinstance(parsed, dict) {
        return parsed;
    }
    raise ValueError("expected JSON object, got " + type(parsed).__name__);
}

def parse_list(s: str) -> list {
    parsed: any = json.loads(s);
    if isinstance(parsed, list) {
        return parsed;
    }
    raise ValueError("expected JSON array, got " + type(parsed).__name__);
}

"""Any-boundary casts: JSON/TOML values come back as `any`; these narrow with a loud failure."""
def as_dict(v: any) -> dict {
    if isinstance(v, dict) {
        return v;
    }
    raise ValueError("expected dict, got " + type(v).__name__);
}

def as_list(v: any) -> list {
    if isinstance(v, list) {
        return v;
    }
    raise ValueError("expected list, got " + type(v).__name__);
}

def as_int(v: any) -> int {
    if isinstance(v, bool) {
        raise ValueError("expected int, got bool");
    }
    if isinstance(v, int) {
        return v;
    }
    return int(str(v));
}

def as_float(v: any) -> float {
    if isinstance(v, float) {
        return v;
    }
    if isinstance(v, int) {
        return float(v);
    }
    return float(str(v));
}

"""Finding identity (TechnicalPRD 8.1): sha1(relpath \\x1f rule \\x1f whitespace-normalized snippet)."""
def fingerprint(relpath: str, rule: str, snippet: str) -> str {
    norm: str = " ".join(snippet.split());
    return sha1((relpath + "\x1f" + rule + "\x1f" + norm).encode("utf-8")).hexdigest();
}

def today() -> str {
    return date.today().isoformat();
}

def days_ago(iso: str) -> int {
    return (date.today() - date.fromisoformat(iso)).days;
}

def valid_statuses() -> list[str] {
    return ["new", "drafted", "shipped", "rejected", "failed_verify", "deferred"];
}

"""Ledger IO: append-only JSONL, one row per finding, last line per fingerprint wins."""
def load_ledger(path: str) -> dict[str, dict] {
    rows: dict[str, dict] = {};
    if not os.path.exists(path) {
        return rows;
    }
    with open(path, "r") as f {
        for line in f {
            stripped: str = line.strip();
            if stripped {
                row: dict = parse_obj(stripped);
                rows[str(row["fingerprint"])] = row;
            }
        }
    }
    return rows;
}

def append_row(path: str, row: dict) {
    with open(path, "a") as f {
        f.write(json.dumps(row) + "\n");
    }
}

def state_read(path: str) -> dict {
    if not os.path.exists(path) {
        return {};
    }
    with open(path, "r") as f {
        return parse_obj(f.read());
    }
}

def state_write(path: str, state: dict) {
    with open(path, "w") as f {
        f.write(json.dumps(state, indent=2) + "\n");
    }
}

"""Config access ([protect].globs et al) straight from nightshift.toml."""
def load_config_toml(path: str) -> dict {
    with open(path, "rb") as f {
        parsed: any = tomllib.load(f);
        if isinstance(parsed, dict) {
            return parsed;
        }
    }
    raise ValueError("not a TOML table: " + path);
}

def load_globs(config_path: str) -> list[str] {
    globs: any = load_config_toml(config_path)["protect"]["globs"];
    if isinstance(globs, list) {
        return [str(g) for g in globs];
    }
    raise ValueError("[protect].globs missing in " + config_path);
}

"""Positive glob marks protected; a later `!glob` carves an exception (TPRD 6 [protect]).
Uses PurePosixPath.full_match, so `**` crosses directories (needs Python >= 3.13)."""
def is_protected(path: str, globs: list[str]) -> bool {
    p = PurePosixPath(path);
    hit: bool = False;
    for g in globs {
        if g.startswith("!") {
            if p.full_match(g[1:]) {
                hit = False;
            }
        } elif p.full_match(g) {
            hit = True;
        }
    }
    return hit;
}

def release_fragment(pkg: str) -> str {
    return "docs/docs/community/release_notes/unreleased/" + pkg + "/0000.refactor.md";
}

test "fingerprint normalizes whitespace" {
    assert fingerprint("f.jac", "dup", "x   y") == fingerprint("f.jac", "dup", "x y");
    assert fingerprint("f.jac", "dup", "x y") != fingerprint("g.jac", "dup", "x y");
}

test "protected globs with negation" {
    globs: list[str] = ["**/tests/**", "docs/**", "!docs/docs/community/release_notes/unreleased/**"];
    assert is_protected("jac/tests/fixtures/x.jac", globs);
    assert is_protected("docs/guide/intro.md", globs);
    assert not is_protected("docs/docs/community/release_notes/unreleased/jac/0000.refactor.md", globs);
    assert not is_protected("jac/compiler/passes.jac", globs);
}

test "ledger last-writer-wins" {
    import tempfile;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as tf {
        path: str = tf.name;
    }
    append_row(path, {"fingerprint": "abc", "status": "new"});
    append_row(path, {"fingerprint": "abc", "status": "drafted"});
    rows: dict[str, dict] = load_ledger(path);
    assert rows["abc"]["status"] == "drafted";
    assert len(rows) == 1;
}
```

### 2.3 `scripts/config.jac` — TOML → bash bridge

Emits `NS_<SECTION>_<KEY>=value` lines (lists/tables as JSON strings, shell-quoted)
for `eval` in bash, plus `json` and `get <dotted.key>` forms.

```jac
"""Read config/nightshift.toml and expose it to bash: flat env lines, JSON, or one dotted key."""
import sys;
import os;
import json;
import tomllib;
import from shlex { quote }

def eprint(msg: str) {
    err: any = sys.stderr;
    err.write(msg + "\n");
}

def load_config(path: str) -> dict {
    with open(path, "rb") as f {
        parsed: any = tomllib.load(f);
        if isinstance(parsed, dict) {
            return parsed;
        }
    }
    raise ValueError("not a TOML table: " + path);
}

def get_key(cfg: dict, dotted: str) -> any {
    cur: any = cfg;
    for part in dotted.split(".") {
        cur = cur[part];
    }
    return cur;
}

def env_value(value: any) -> str {
    if isinstance(value, list) or isinstance(value, dict) {
        return json.dumps(value);
    }
    return str(value);
}

def as_env_lines(cfg: dict) -> list[str] {
    lines: list[str] = [];
    for (section, table) in cfg.items() {
        if isinstance(table, dict) {
            for (key, value) in table.items() {
                name: str = ("NS_" + str(section) + "_" + str(key)).upper().replace("-", "_");
                lines.append(name + "=" + quote(env_value(value)));
            }
        }
    }
    return lines;
}

def config_path(args: list[str], idx: int) -> str {
    if len(args) > idx {
        return args[idx];
    }
    from_env: str | None = os.environ.get("NS_CONFIG");
    if from_env is not None {
        return from_env;
    }
    return "config/nightshift.toml";
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "env" {
        for line in as_env_lines(load_config(config_path(args, 2))) {
            print(line);
        }
    } elif cmd == "json" {
        print(json.dumps(load_config(config_path(args, 2))));
    } elif cmd == "get" and len(args) > 2 {
        print(env_value(get_key(load_config(config_path(args, 3)), args[2])));
    } else {
        eprint("usage: jac run config.jac env|json|get <dotted.key> [config.toml]");
    }
}

test "env lines flatten sections and quote values" {
    import tempfile;
    body: str = "[repo]\nfork = \"me/jaseci\"\n[budgets]\nmax_turns = 80\n[protect]\nglobs = [\"docs/**\"]\n";
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        tf.write(body);
        path: str = tf.name;
    }
    lines: list[str] = as_env_lines(load_config(path));
    assert "NS_REPO_FORK=me/jaseci" in lines;
    assert "NS_BUDGETS_MAX_TURNS=80" in lines;
    assert get_key(load_config(path), "budgets.max_turns") == 80;
}
```

### 2.4 `scripts/timeout.jac` — portable gtimeout

Used only when brew's `gtimeout` is absent. Exit 124 on timeout, mirroring
coreutils, so callers can't tell the difference.

```jac
"""Portable gtimeout replacement: run a command under a wall-clock limit (exit 124 on timeout)."""
import sys;
import subprocess;

def eprint(msg: str) {
    err: any = sys.stderr;
    err.write(msg + "\n");
}

def run_with_timeout(argv: list[str], seconds: float) -> int {
    try {
        return subprocess.run(argv, timeout=seconds).returncode;
    } except subprocess.TimeoutExpired {
        return 124;
    }
}

with entry {
    args: list[str] = sys.argv;
    # strict arg check: under `jac test` argv is the jac CLI's own args, so never dispatch loosely
    if len(args) >= 3 and args[1].replace(".", "", 1).isdigit() {
        sys.exit(run_with_timeout(args[2:], float(args[1])));
    }
    eprint("usage: jac run timeout.jac <seconds> <cmd> [args...]");
    sys.exit(2);
}
```

### 2.5 `lib/common.sh` — shared bash plumbing

The contract every stage lives by: `ns_stage` (idempotent `.done-S*` markers),
`ns_jac` (always run helpers from `NS_ROOT` — jac writes its `.jac` cache into the
cwd), `ns_timebox` (gtimeout or the Jac fallback), `ns_lock_*` (mkdir is atomic on
APFS; stock macOS has no `flock`), the queue/green handoff files, and the
`ns_git_push` dry-run seam.

```bash
# shellcheck shell=bash
# lib/common.sh — sourced by bin/nightshift.sh. Shared plumbing for every stage.
# Requires: NS_ROOT exported by the entry script.

NS_DATE="${NS_DATE:-$(date +%F)}"
LOG_DIR="$NS_ROOT/logs/$NS_DATE"
REPO="$NS_ROOT/work/repo"
DRAFTS="$NS_ROOT/work/drafts"
STATE="$NS_ROOT/state/state.json"
LEDGER="$NS_ROOT/state/ledger.jsonl.cache"
CONFIG="$NS_ROOT/config/nightshift.toml"
LOCK_DIR="/tmp/nightshift.lock"

# --- exit codes (TechnicalPRD 18) ---
EX_OK=0; EX_LOCK=40; EX_DISABLED=41; EX_AUTH=42; EX_OFFLINE=43; EX_SYNC=44
EX_AUDIT=50; EX_ALLFAIL=51; EX_CEILING=60; EX_BUG=70

# --- config bootstrap ---
# Chicken-and-egg: the jac binary path lives in the toml that jac itself reads.
# Grep the one bootstrap key, then let config.jac emit everything else.
ns_bootstrap_jac() {
    NS_PATHS_JAC="$(sed -n 's/^jac *= *"\(.*\)"/\1/p' "$CONFIG" | head -1)"
    NS_PATHS_JAC="${NS_PATHS_JAC:-$(command -v jac)}"
    [ -x "$NS_PATHS_JAC" ] || { echo "FATAL: jac binary not found" >&2; exit "$EX_BUG"; }
}

ns_load_config() {
    ns_bootstrap_jac
    eval "$(cd "$NS_ROOT" && "$NS_PATHS_JAC" run scripts/config.jac env "$CONFIG")"
}

# All Jac helpers run from NS_ROOT: jac writes its .jac cache dir into the cwd.
ns_jac() {
    local script=$1; shift
    (cd "$NS_ROOT" && "$NS_PATHS_JAC" run "scripts/$script.jac" "$@")
}

# --- logging & night bookkeeping ---
ns_log()  { printf '%s [%s] %s\n' "$(date '+%H:%M:%S')" "$1" "$2" | tee -a "$LOG_DIR/run.log" >&2; }
ns_warn() { ns_log WARN "$1"; echo "$1" >> "$LOG_DIR/warnings.txt"; }
ns_fail() { printf '%s\t%s\n' "$1" "$2" >> "$LOG_DIR/failed.tsv"; ns_log FAIL "$1: $2"; }
ns_die()  { local code=$1; shift; ns_log FATAL "$*"; exit "$code"; }

# --- lock (mkdir is atomic on APFS; no flock on stock macOS) ---
ns_lock_acquire() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        return 0
    fi
    local holder; holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        ns_die "$EX_LOCK" "lock held by live pid $holder"
    fi
    ns_log LOCK "reclaiming stale lock (pid ${holder:-unknown} is gone)"
    rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR"; echo $$ > "$LOCK_DIR/pid"
}
ns_lock_release() { rm -rf "$LOCK_DIR"; }

# --- time-boxes ---
# gtimeout (brew coreutils) when present, scripts/timeout.jac otherwise. Arg is minutes.
ns_timebox() {
    local min=$1; shift
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${min}m" "$@"
    else
        ns_jac timeout "$((min * 60))" "$@"
    fi
}

ns_remaining_min() {
    local start now elapsed
    start="$(cat "$LOG_DIR/start_epoch")"; now="$(date +%s)"
    elapsed=$(( (now - start) / 60 ))
    echo $(( NS_BUDGETS_WALLCLOCK_MIN - elapsed ))
}

# --- stage runner: .done markers make same-night re-runs idempotent (TPRD 7, 12) ---
ns_stage() {
    local id=$1 fn=$2
    if [ -f "$LOG_DIR/.done-$id" ]; then
        ns_log "$id" "already done — skipping"
        return 0
    fi
    echo "$id" > "$LOG_DIR/CURRENT_STAGE"
    ns_log "$id" "start"
    "$fn" >> "$LOG_DIR/$id.log" 2>&1
    touch "$LOG_DIR/.done-$id"
    ns_log "$id" "done"
}

# --- branch queue between S2/S3 (producers) and S4 (gate) / S5 (ship) ---
# queue.tsv line: branch<TAB>theme.json-or-"-"<TAB>report.json-or-"-"
ns_queue_branch()   { printf '%s\t%s\t%s\n' "$1" "${2:--}" "${3:--}" >> "$LOG_DIR/queue.tsv"; }
ns_mark_green()     { printf '%s\t%s\t%s\n' "$1" "${2:--}" "${3:--}" >> "$LOG_DIR/green.tsv"; }

# --- dry-run seam: every push in the nightly path goes through this (TPRD 14) ---
ns_git_push() {   # ns_git_push <dir> <push-args...>
    local dir=$1; shift
    if [ -n "${NS_DRY_RUN:-}" ]; then
        ns_log DRY "git -C $dir push $*"
    else
        git -C "$dir" push "$@"
    fi
}

# --- secrets ---
ns_load_env() {
    # shellcheck disable=SC1090
    [ -f "$HOME/.nightshift.env" ] && . "$HOME/.nightshift.env"
    # A set ANTHROPIC_API_KEY silently outranks the subscription (TPRD feasibility row 7).
    unset ANTHROPIC_API_KEY
}
```

## Commands

```bash
cd ~/nightshift
# write the five files above, then:
jac check scripts/nslib.jac scripts/config.jac scripts/timeout.jac
jac test  scripts/nslib.jac
jac test  scripts/config.jac
bash -n lib/common.sh
```

## Acceptance criteria

- [ ] `jac check` passes on all three Jac files (warnings W1036/W1037 at the
      JSON/TOML boundary are expected; errors are not).
- [ ] `jac test scripts/nslib.jac` → 3 tests pass (fingerprint normalization,
      protect-glob negation, ledger last-writer-wins).
- [ ] `jac test scripts/config.jac` → env-flattening test passes.
- [ ] `cd ~/nightshift && jac run scripts/config.jac env config/nightshift.toml`
      prints one `NS_*=value` line per config key, lists as quoted JSON.
- [ ] `jac run scripts/config.jac get budgets.max_turns config/nightshift.toml` → `80`.
- [ ] `jac run scripts/timeout.jac 2 sleep 5; echo $?` → `124` after ~2 s.
- [ ] `bash -n lib/common.sh` silent.

## Verification procedure

```bash
cd ~/nightshift
eval "$(jac run scripts/config.jac env config/nightshift.toml)"
echo "$NS_REPO_FORK / $NS_BUDGETS_THEMES_PER_NIGHT / $NS_PROTECT_GLOBS"
# expect your fork, 3, and the JSON globs array
```

Then exercise the lock from two shells: shell A
`source lib/common.sh; ns_lock_acquire; sleep 60` — shell B's `ns_lock_acquire`
must die with exit 40 while A lives, and succeed (stale reclaim) after A is killed.

## Notes & traps

- **Helper filenames must never shadow Python stdlib modules** (steps.md rule 8).
  `selector.jac`, not `select.jac`; if you ever add helpers, check
  `python3 -c "import <name>"` fails first.
- `config.jac env` output is `eval`-ed — values are shell-quoted via `shlex.quote`
  inside the helper. Don't "simplify" that away.
- The bootstrap chicken-and-egg (jac's own path lives in the toml jac reads) is
  solved by `ns_bootstrap_jac`'s one-line `sed` — the only config parsing bash is
  allowed to do.
- `NS_BUDGETS_WALLCLOCK_MIN` etc. become plain shell integers — bash arithmetic in
  later steps depends on `config.jac` emitting bare numbers for scalars (it does:
  only lists/tables are JSON-encoded).
