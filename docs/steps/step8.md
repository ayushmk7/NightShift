# Step 8 — S6 Email digest + entry script + trap wiring (M1 complete)

## Goal

Three pieces that close the deterministic loop: `scripts/sendmail.jac` (assemble
the TechnicalPRD §8.4 run summary from the night's on-disk artifacts, render the
digest with the exact §7-S6 subject grammar, send via stdlib `smtplib` over SSL),
`lib/email.sh` (the trap target, with the EMAIL_FAILED marker + macOS banner
last-ditch), and `bin/nightshift.sh` (the entry point: subcommand dispatch, lock,
wall-clock ceiling via self-exec under `gtimeout`, stage sequencing, and the EXIT
trap that makes the digest fire on **every** exit path — success, stage failure,
ceiling TERM, or DISABLE). After this step, milestone M1 is done: preflight → sync
→ tier-1 → verify → ship-less night → digest email, end to end.

## Prerequisites

Steps 2–7. `~/.nightshift.env` from step 1.6 (Gmail app password or any SMTP).
`render_draft.jac` (step 12) must exist for `sendmail.jac`'s import — see the
ordering note in step 6; write the step 12 helper now if building strictly in
sequence.

## Files created

```
~/nightshift/scripts/sendmail.jac
~/nightshift/lib/email.sh
~/nightshift/bin/nightshift.sh        (chmod +x)
```

## The run-summary conventions (what S6 reads)

`sendmail.jac summarize` rebuilds the whole picture from files earlier stages
already dropped — no stage needs to "report" to S6:

| Artifact | Producer | Meaning |
|---|---|---|
| `work/drafts/drafts/<date>--*.md` | S5 | one branch card + inline draft each |
| `$LOG_DIR/failed.tsv` | `ns_fail` anywhere | `what⇥reason` autopsy lines |
| `$LOG_DIR/report-*.json` | S3-C / S2 | `suspected_bugs` harvested from every report |
| `$LOG_DIR/meta-*.json` | S3 | `num_turns` / `total_cost_usd` per session, summed |
| `$LOG_DIR/warnings.txt` | `ns_warn` | drift banner etc. |
| `$LOG_DIR/start_epoch` | entry script | runtime minutes |
| `$LOG_DIR/DISABLED`, `$LOG_DIR/ERROR_STAGE` | S0 / trap | subject suffixes |

Subject grammar (TechnicalPRD S6, verified by unit test):
`Nightshift <date> · <n> ready · −<loc> LOC · <m> failed[ · DISABLED| · ERROR S<k>]`

## Full implementation

### `scripts/sendmail.jac`

```jac
"""S6 email digest (TechnicalPRD 7-S6). Always sent — the trap in nightshift.sh calls this
on every exit path; silence is itself a failure mode (PRD 11).

argv:  summarize <log_dir> <drafts_dir> <date> <config.toml>
                              assemble the run-summary JSON (TPRD 8.4) from the night's
                              artifacts (drafts, failed.tsv, report-*.json, meta-*.json,
                              warnings.txt, start_epoch, DISABLED, ERROR_STAGE) → stdout
       send <config.toml>     stdin: run-summary JSON; build + send the digest
       render <config.toml>   same, but print the RFC-2822 message instead of sending (dry-run)
env:   SMTP_USER, SMTP_PASS (from ~/.nightshift.env; never exported to agent sessions)
"""
import sys;
import os;
import json;
import time;
import smtplib;
import from pathlib { Path }
import from email.mime.text { MIMEText }
import from email.mime.multipart { MIMEMultipart }
import from nslib { eprint, read_stdin, parse_obj, as_dict, as_list, as_int, load_config_toml }
import from render_draft { split_draft }

"""Subject grammar (TPRD S6): Nightshift <date> · <n> ready · −<loc> LOC · <m> failed[ · DISABLED| ERROR S<k>]."""
def subject(summary: dict) -> str {
    branches: list = as_list(summary.get("branches", []));
    loc: int = sum([as_int(as_dict(b).get("loc_delta", 0)) for b in branches]);
    loc_str: str = ("−" + str(-loc)) if loc <= 0 else ("+" + str(loc));
    failed: int = len(as_list(summary.get("failed", [])));
    s: str = "Nightshift " + str(summary["date"]) + " · " + str(len(branches)) + " ready";
    s += " · " + loc_str + " LOC · " + str(failed) + " failed";
    if summary.get("disabled", False) {
        s += " · DISABLED";
    } elif summary.get("error_stage") is not None and summary.get("error_stage") != "" {
        s += " · ERROR " + str(summary["error_stage"]);
    }
    return s;
}

def branch_card(b: dict) -> list[str] {
    return [
        "== " + str(b.get("theme", b.get("branch", "?"))) + " ==",
        "branch:  " + str(b.get("branch", "?")),
        "files:   " + str(b.get("files", "?")) + "   loc: " + str(b.get("loc_delta", "?")),
        "tests:   " + str(b.get("tests", "?")),
        "risk:    " + str(b.get("risk", "?")),
        "url:     " + str(b.get("url", "")),
        "",
    ];
}

"""Body order per TPRD S6: verdict → branch cards → full inline drafts → suspected bugs →
skipped/failed → runtime/cost → warnings."""
def plain_body(summary: dict) -> str {
    lines: list[str] = [str(summary.get("verdict", "(no verdict)")), ""];
    for b in as_list(summary.get("branches", [])) {
        lines += branch_card(as_dict(b));
    }
    for b in as_list(summary.get("branches", [])) {
        card: dict = as_dict(b);
        if card.get("draft_text", "") {
            lines += ["---- draft: " + str(card.get("branch", "?")) + " ----",
                      str(card["draft_text"]), ""];
        }
    }
    bugs: list = as_list(summary.get("suspected_bugs", []));
    if bugs {
        lines.append("SUSPECTED BUGS (reported, never auto-fixed):");
        for bug in bugs {
            d: dict = as_dict(bug);
            lines.append("- " + str(d.get("file", "?")) + ":" + str(d.get("line", "?")) + " — " + str(d.get("note", "")));
        }
        lines.append("");
    }
    failed: list = as_list(summary.get("failed", []));
    if failed {
        lines.append("FAILED / SKIPPED:");
        for item in failed {
            d2: dict = as_dict(item);
            lines.append("- " + str(d2.get("what", "?")) + ": " + str(d2.get("reason", "")));
        }
        lines.append("");
    }
    lines.append("runtime: " + str(summary.get("runtime_min", "?")) + " min · turns: "
                 + str(summary.get("turns", "?")) + " · cost: $" + str(summary.get("cost_usd", "0")));
    for w in as_list(summary.get("warnings", [])) {
        lines.append("WARNING: " + str(w));
    }
    return "\n".join(lines) + "\n";
}

# `any` at the MIME boundary: jac 0.16.1's email stubs lack attach/send_message members
def build_message(summary: dict, cfg: dict) -> any {
    email_cfg: dict = as_dict(cfg["email"]);
    msg: any = MIMEMultipart("alternative");
    msg["Subject"] = subject(summary);
    msg["From"] = str(email_cfg["from"]);
    msg["To"] = str(email_cfg["to"]);
    text: str = plain_body(summary);
    msg.attach(MIMEText(text, "plain"));
    msg.attach(MIMEText("<pre>" + text.replace("&", "&amp;").replace("<", "&lt;") + "</pre>", "html"));
    return msg;
}

def send(summary: dict, cfg: dict) {
    email_cfg: dict = as_dict(cfg["email"]);
    user: str | None = os.environ.get("SMTP_USER");
    password: str | None = os.environ.get("SMTP_PASS");
    if user is None or password is None {
        raise ValueError("SMTP_USER/SMTP_PASS not set (source ~/.nightshift.env)");
    }
    msg: any = build_message(summary, cfg);
    with smtplib.SMTP_SSL(str(email_cfg["smtp_host"]), as_int(email_cfg["smtp_port"])) as server {
        smtp: any = server;
        smtp.login(user, password);
        smtp.send_message(msg);
    }
}

def read_lines(path: str) -> list[str] {
    if not os.path.exists(path) {
        return [];
    }
    with open(path, "r") as f {
        return [l.strip() for l in f.read().splitlines() if l.strip()];
    }
}

"""`glob` is a Jac keyword, so directory listing goes through pathlib instead of the glob module."""
def glob_paths(directory: str, pattern: str) -> list[str] {
    return sorted([str(m) for m in Path(directory).glob(pattern)]);
}

def read_json_files(directory: str, pattern: str) -> list[dict] {
    out: list[dict] = [];
    for path in glob_paths(directory, pattern) {
        with open(path, "r") as f {
            out.append(parse_obj(f.read()));
        }
    }
    return out;
}

"""Assemble the TPRD 8.4 run summary from the night's on-disk artifacts (see module docstring)."""
def summarize(log_dir: str, drafts_dir: str, date_s: str, cfg: dict) -> dict {
    fork: str = str(as_dict(cfg["repo"])["fork"]);
    branches: list[dict] = [];
    for path in glob_paths(drafts_dir, date_s + "--*.md") {
        with open(path, "r") as f {
            text: str = f.read();
        }
        (meta, _body) = split_draft(text);
        loc: dict = as_dict(meta.get("loc", {}));
        branches.append({
            "theme": meta.get("title", os.path.basename(path)),
            "branch": meta.get("branch", "?"),
            "files": meta.get("files", 0),
            "loc_delta": as_int(loc.get("after", 0)) - as_int(loc.get("before", 0)),
            "tests": meta.get("tests", "?"),
            "risk": meta.get("risk", "?"),
            "url": "https://github.com/" + fork + "/tree/" + str(meta.get("branch", "")),
            "draft_text": text,
        });
    }
    failed: list[dict] = [];
    for line in read_lines(os.path.join(log_dir, "failed.tsv")) {
        parts: list[str] = line.split("\t");
        failed.append({"what": parts[0], "reason": parts[1] if len(parts) > 1 else ""});
    }
    bugs: list = [];
    turns: int = 0;
    cost: float = 0.0;
    for rep in read_json_files(log_dir, "report-*.json") {
        bugs += as_list(rep.get("suspected_bugs", []));
    }
    for m in read_json_files(log_dir, "meta-*.json") {
        turns += as_int(m.get("num_turns", 0) or 0);
        cost += float(str(m.get("total_cost_usd", 0) or 0));
    }
    runtime: int = 0;
    start_lines: list[str] = read_lines(os.path.join(log_dir, "start_epoch"));
    if start_lines {
        runtime = int((time.time() - float(start_lines[0])) / 60.0);
    }
    error_lines: list[str] = read_lines(os.path.join(log_dir, "ERROR_STAGE"));
    return {
        "date": date_s,
        "verdict": str(len(branches)) + " branch(es) ready · " + str(len(failed)) + " failed",
        "branches": branches,
        "failed": failed,
        "suspected_bugs": bugs,
        "runtime_min": runtime,
        "turns": turns,
        "cost_usd": cost,
        "warnings": read_lines(os.path.join(log_dir, "warnings.txt")),
        "disabled": os.path.exists(os.path.join(log_dir, "DISABLED")),
        "error_stage": error_lines[0] if error_lines else None,
    };
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "summarize" and len(args) == 6 {
        print(json.dumps(summarize(args[2], args[3], args[4], load_config_toml(args[5]))));
    } elif cmd in ["send", "render"] and len(args) == 3 {
        summary: dict = parse_obj(read_stdin());
        cfg: dict = load_config_toml(args[2]);
        if cmd == "render" {
            print(str(build_message(summary, cfg)));
        } else {
            send(summary, cfg);
        }
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run sendmail.jac summarize <log_dir> <drafts_dir> <date> <config.toml>");
        eprint("       jac run sendmail.jac send|render <config.toml>   (run-summary JSON on stdin)");
    }
}

test "subject grammar covers ready/loc/failed and error suffix" {
    summary: dict = {
        "date": "2026-07-10",
        "branches": [{"loc_delta": -300}, {"loc_delta": -112}],
        "failed": [{"what": "theme x", "reason": "tests red"}],
        "error_stage": None,
    };
    assert subject(summary) == "Nightshift 2026-07-10 · 2 ready · −412 LOC · 1 failed";
    summary["error_stage"] = "S4";
    assert subject(summary).endswith("· ERROR S4");
}

test "summarize assembles branches, failures and bugs from disk conventions" {
    import tempfile;
    log_dir: str = tempfile.mkdtemp();
    drafts_dir: str = tempfile.mkdtemp();
    draft: str = "---\nbranch: \"nightshift/2026-07-10/dead-code\"\npackage: \"jac\"\ndate: \"2026-07-10\"\ntitle: \"refactor(jac): x\"\nrisk: \"low\"\ntests: \"green\"\nrelease_note: \"r.md\"\nfiles: 2\nloc: {\"before\": 100, \"after\": 40}\n---\n\n# refactor(jac): x\n";
    with open(os.path.join(drafts_dir, "2026-07-10--dead-code.md"), "w") as f {
        f.write(draft);
    }
    with open(os.path.join(log_dir, "failed.tsv"), "w") as f {
        f.write("theme y\ttests red\n");
    }
    with open(os.path.join(log_dir, "report-dead-code.json"), "w") as f {
        f.write("{\"suspected_bugs\": [{\"file\": \"a.jac\", \"line\": 3, \"note\": \"?\"}]}");
    }
    with open(os.path.join(log_dir, "meta-apply-dead-code.json"), "w") as f {
        f.write("{\"num_turns\": 41, \"total_cost_usd\": 0.7}");
    }
    cfg: dict = {"repo": {"fork": "me/jaseci"}};
    summary: dict = summarize(log_dir, drafts_dir, "2026-07-10", cfg);
    assert len(as_list(summary["branches"])) == 1;
    assert as_dict(as_list(summary["branches"])[0])["loc_delta"] == -60;
    assert as_dict(as_list(summary["failed"])[0])["reason"] == "tests red";
    assert len(as_list(summary["suspected_bugs"])) == 1;
    assert summary["turns"] == 41;
    assert subject(summary) == "Nightshift 2026-07-10 · 1 ready · −60 LOC · 1 failed";
}

test "body inlines drafts and bug reports" {
    summary: dict = {
        "date": "2026-07-10", "verdict": "2 branches ready",
        "branches": [{"theme": "dead-code", "branch": "nightshift/2026-07-10/dead-code",
                      "files": 3, "loc_delta": -100, "tests": "all green", "risk": "low",
                      "url": "https://github.com/x", "draft_text": "# refactor: kill dead code"}],
        "suspected_bugs": [{"file": "a.jac", "line": 10, "note": "off-by-one?"}],
        "failed": [], "runtime_min": 42, "turns": 61, "cost_usd": 0,
    };
    body: str = plain_body(summary);
    assert "# refactor: kill dead code" in body;
    assert "SUSPECTED BUGS" in body;
    assert "a.jac:10" in body;
}
```

### `lib/email.sh`

```bash
# shellcheck shell=bash
# lib/email.sh — S6 (TechnicalPRD 7-S6). Runs from the EXIT trap: fires on success,
# failure, ceiling kill (TERM), and DISABLE alike. Silence must stay detectable.

email_main() {
    local summary
    if ! summary="$(ns_jac sendmail summarize "$LOG_DIR" "$DRAFTS/drafts" "$NS_DATE" "$CONFIG")"; then
        email_last_ditch "summarize failed"
        return 0
    fi
    printf '%s' "$summary" > "$LOG_DIR/run-summary.json"

    if [ -n "${NS_DRY_RUN:-}" ]; then
        printf '%s' "$summary" | ns_jac sendmail render "$CONFIG"
        return 0
    fi
    if ! printf '%s' "$summary" | ns_jac sendmail send "$CONFIG"; then
        email_last_ditch "smtp send failed"
    fi
}

# SMTP down → marker file + macOS banner, so a missing morning email is still a signal (TPRD 12)
email_last_ditch() {
    touch "$LOG_DIR/EMAIL_FAILED"
    ns_log S6 "EMAIL FAILED: $1"
    osascript -e 'display notification "digest email failed — check logs" with title "Nightshift"' \
        2>/dev/null || true
}
```

### `bin/nightshift.sh`

```bash
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
    *)          usage ;;
esac
```

```bash
chmod +x ~/nightshift/bin/nightshift.sh
```

## Commands

```bash
cd ~/nightshift
jac check scripts/sendmail.jac && jac test scripts/sendmail.jac
bash -n lib/email.sh bin/nightshift.sh
```

## Acceptance criteria

- [ ] `jac test scripts/sendmail.jac` → 3 tests green (subject grammar, body
      inlining, summarize-from-disk).
- [ ] `echo '{"date":"2026-07-10","verdict":"x","branches":[],"failed":[]}' | jac
      run scripts/sendmail.jac render config/nightshift.toml` prints a well-formed
      multipart message with the UTF-8-encoded subject.
- [ ] A **real** email lands: `... | jac run scripts/sendmail.jac send
      config/nightshift.toml` with `~/.nightshift.env` sourced.
- [ ] `bin/nightshift.sh status` runs (empty output is fine — no runs yet).
- [ ] **The M1 milestone check**: `bin/nightshift.sh run` completes S0→S5 on the
      real clone and the digest email arrives, even if tonight's diff was empty.
- [ ] Kill the run mid-S4 (Ctrl-C): the digest still arrives, subject carries
      `· ERROR S4`.

## Verification procedure

```bash
cd ~/nightshift
set -a; . ~/.nightshift.env; set +a
bin/nightshift.sh dry-run          # full pipeline, pushes logged not executed, email printed
bin/nightshift.sh run              # the real thing
```

Then check the second-run idempotency: `bin/nightshift.sh run` again the same day
must skip every stage (`.done-S*` markers) in seconds and re-send only the digest.

## Notes & traps

- The trap is `EXIT TERM INT` — `gtimeout` sends TERM at the ceiling, so the
  autopsy email survives the kill. Only `kill -9` silences it, and then the missing
  email is itself the alarm (PRD §11) plus the `osascript` banner path.
- The ceiling re-exec happens **only when `gtimeout` exists**; without it the
  per-stage boxes still bound the damage. `brew install coreutils` was step 1.
- SMTP creds are loaded by `ns_load_env` inside the run and **never** exported into
  the agent sessions (tier-2 spawns `claude` with the same process env — the env
  file is sourced *after* the lock, and the agent allow-list has no `Bash(env *)`;
  threat T2's residual is acceptable for v1 — revisit with a env-scrubbed wrapper
  if it ever bothers you).
- `sendmail.jac` imports `split_draft` from `render_draft.jac` — helper files are
  modules too; that's the shared-`nslib` pattern paying off.
- The subject's `−` is a real minus sign (U+2212), matching the PRD; your mail
  client's threading treats each night as a new thread because the date changes.
