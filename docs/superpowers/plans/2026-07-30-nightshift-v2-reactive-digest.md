# Nightshift v2 Plan 4: Reactive merged-PR pass + the nightly digest

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clean whatever landed upstream the same night it lands, and make the operator's one unattended channel — the morning email — carry enough detail to triage the night without opening a terminal, on a pipe that has been *proven* to deliver.

**Architecture:** Two independent halves that meet only in `scripts/sendmail.jac`.

The **reactive half** adds one poll and one pass. `lib/reactive.sh` asks `gh` which PRs merged upstream since the last successful poll, takes the union of their changed files as an audit scope, and runs all four task lenses over that scope before the cycle task starts. It reuses the existing audit session function rather than growing a second one; the only change to `lib/tier2.sh` is that `tier2_audit_shard` takes its scope as an argument instead of looking it up. A quiet day costs zero sessions and one log line.

The **digest half** is three layers stacked bottom-up, deliberately in that order. First a send that is *proven* to have been accepted by the server (Task 1). Then the data the digest reports — the fatal reason a night died (Task 2), the reactive artifacts (Tasks 3-4), and the assembled v2 summary (Task 5). Only last, the `multipart/alternative` HTML rendering (Task 6). Building a multipart HTML digest before proving the transport is polish on nothing: every byte of formatting work is wasted if the message never leaves the host, and formatting cannot tell you whether it left.

**Tech Stack:** bash 3.2.57 (macOS stock), Jac 0.16.1 for every data/logic transformation, Python stdlib via Jac imports (`smtplib`, `email.mime`, `io`, `re`, `contextlib` — no new dependency), `gh` CLI for the merge poll.

## Depends on Plan 2 and Plan 3

This plan is written assuming both have landed and does not re-derive their interfaces.

**From Plan 2 (task registry):**
- `jac run scripts/tasks.jac list <config.toml>` — the four task names in cycle order (`dead-code`, `abstraction`, `maintenance`, `coverage`), one per line.
- `prompts/audit-<task>.md` exists for each, taking the same placeholders `prompts/audit.md` takes today: `{shard}`, `{scope}`, `{protect_globs}`, `{ponytail_mode}`.
- `tier2_audit_shard` is task-aware — it selects the prompt by task name.
- Themes carry a `task` key, and `$LOG_DIR/selection.json` records it.

**From Plan 3 (ship path / PR machinery):**
- `$LOG_DIR/prs.jsonl`, one JSON object per PR opened or touched tonight: `{"number", "title", "task", "url", "mirror", "ci", "attempts"}`.
- `$LOG_DIR/pr-inventory.jsonl`, one object per PR the S1.6 inventory pass handled: `{"number", "action": "rebased"|"updated"|"conflicted", "note"}`.

**Both are read defensively.** Every consumer in Task 5 treats a missing file as an empty list, because the digest is the one thing that must render on a night where the stage that writes it never ran. That tolerance is load-bearing for the failure path and is unit-tested (Task 5, Step 2).

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-30-nightshift-4task-design.md`, sections 10 and 14. Carry-forward: `docs/superpowers/specs/2026-07-30-nightshift-followups.md` section 5.
- **No Python FILES.** bash sequences processes; Jac owns every data and logic transformation. Jac may import Python stdlib modules — `sendmail.jac` already imports `smtplib`. This is a standing project rule.
- **bash is 3.2.57.** No `wait -n`, no associative arrays, no `${var^^}`. Under `set -u` an EMPTY array aborts both `${#arr[@]}` and `"${arr[@]}"`; use a space-joined string and a counter. **A guard must not return nonzero on its success path** — use `case`, never `[ x ] && y`, because a false `&&` list is itself a nonzero return and `bin/nightshift.sh` runs `set -euo pipefail`.
- **Two jac binaries, never mixed.** `$NS_PATHS_JAC` runs the harness's own `scripts/*.jac`. `$NS_PATHS_JAC_REPO` is the target repo's dev binary. The digest and the merge poll only ever use the former.
- **Jac type-narrowing is mandatory.** Nested subscripts fail `jac check` with E1001/E1053. Every dict-of-dict or list-of-dict access goes through `nslib`'s `as_dict` / `as_list` / `as_int`. This is why `sendmail.jac` already reads `as_dict(b).get("added", 0)` rather than `b["added"]`.
- **`bin/test-harness.sh` must print `ALL HARNESS TESTS PASSED` at every commit.** Every Jac helper gets `test` blocks in the same file and is registered in section 1's sweep list.
- **`work/`, `state/`, `logs/` are gitignored and nothing under them is tracked.** Edits there are plain `rm`/`printf`, never `git rm`.
- **The digest runs from the EXIT trap and must fire on every path** — success, failure, ceiling TERM, and DISABLE alike. A digest that only sends on success is worse than none, because silence then means two different things. Task 7 proves it.
- **Anything network-touching respects the `NS_DRY_RUN` seam.** Writes are stubbed (`ns_git_push`, `sendmail render` instead of `send`). Read-only calls (`gh pr list`) still run in dry-run — a dry-run whose merge poll is stubbed cannot rehearse the reactive pass at all.
- **Credentials never enter the repo.** They stay in `~/.nightshift.env` (`export SMTP_USER` / `export SMTP_PASS`, sourced by `ns_load_env`). No test may print them, and Task 1 Step 3 exists specifically because smtplib's own debug output contains the password.

## The defect class to design against

**"Did not run" scored as "passed."** Seven instances in Plan 1, every one in the gate, none caught by tests that were passing, because the commands involved exit 0 for "nothing to do" and 0 for "all good". The countermeasure that worked is a **positive assertion that the work happened**, not an inference from the absence of failure. The sibling class is **an assertion that cannot fail**.

Two places in this plan are exactly that shape, and each gets a positive assertion:

1. **An email that "sent" must be proven to have sent.** `lib/email.sh` currently logs `digest sent to …` whenever `sendmail send` exits 0, and `sendmail send` exits 0 whenever `smtplib.send_message` does not raise. `send_message` returns an empty dict both when every recipient was accepted *and* when the call was short-circuited. The receipt is the SMTP server's own `250` acceptance of the DATA payload, which a send that did not happen cannot produce (Task 1).
2. **A reactive pass that found no merges must be distinguishable from one that failed to ask.** `gh` exits 0 having written nothing under several failure modes, and an empty file word-splits to zero iterations exactly like a genuinely quiet day. The poll demands a parseable JSON array before it believes "quiet" (Task 3).

**Mutation-test any tripwire.** Reading it is not enough — mutation caught weak guards twice in Plan 1 where reading did not. Every guard added here has a step that breaks it deliberately and confirms the harness goes red.

## What the evidence actually says about SMTP

The brief for this plan states that SMTP has never once sent successfully in ~20 nights. **The on-disk logs contradict that**, and the difference changes what Task 1 has to do. Established by inspection on 2026-07-30:

- `EMAIL_FAILED` markers exist for exactly seven runs, all on or before **2026-07-15**: `2026-07-10`, `2026-07-11` (three runs), `2026-07-12`, `2026-07-13.pre-demo-124034`, `2026-07-15`.
- Those failures have **three different causes, none of them a bug in `smtplib` usage**:
  - `2026-07-12`: `SMTP_USER/SMTP_PASS not set (source ~/.nightshift.env)` — the env file was not being sourced.
  - `2026-07-13.pre-demo`: `EMAIL FAILED: summarize failed` — never reached SMTP at all.
  - `2026-07-15`: `[Errno 8] nodename nor servname provided, or not known` at `socket.getaddrinfo` — a DNS failure, on a night whose S0 log two lines earlier reads `[FATAL] gh not authenticated`. **The machine was offline.** The traceback attributed to smtplib is the symptom, not the cause.
  - `2026-07-10` / `2026-07-11`: cause unrecoverable. `lib/email.sh` did not route trap-time stderr into `S6.log` until commit `2504da4` (2026-07-19), so those tracebacks are lost.
- Since `2504da4` added the success log line, **six nights logged `digest sent`**: 07-20, 07-21, 07-22, 07-24 (twice), 07-27, 07-30. Before that commit a successful send logged nothing at all, which is why the pipe looked dead.
- DNS and TCP to `smtp.gmail.com:465` both resolve and connect from this host today.

So the honest problem statement is not "SMTP is broken." It is: **`digest sent` is an assertion that cannot fail, so nobody can tell a delivered digest from a swallowed one, and an offline night blocks in `connect()` with no timeout instead of failing fast.** Task 1 fixes those two things and produces the one thing the record has never contained — a server-issued receipt — plus one human confirmation that a message actually arrives in the inbox. It also removes `[email].from = "nightshift@localhost"`, which Gmail rewrites to the authenticated user and which is a plausible spam-classification contributor for the nights that did send.

Write this down in the Task 1 commit message. The next person will otherwise re-derive it from the same seven markers.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `scripts/sendmail.jac` | summary assembly, digest build, proven send | Modify — the centre of this plan |
| `scripts/merges.jac` | merged-PR poll data: since-date, PR count, file union | **Create** |
| `lib/reactive.sh` | S1.5 merge poll + S3a four-lens reactive pass | **Create** |
| `lib/email.sh` | S6 driver, runs from the EXIT trap | Modify: consume the receipt |
| `lib/tier2.sh` | S3 audit/select/apply | Modify: explicit scope arg, phase-tagged select/apply |
| `lib/common.sh` | shared plumbing | Modify: `ns_reactive_scope_file` helper only |
| `bin/nightshift.sh` | entry point | Modify: clear `ERROR_STAGE`, source `reactive.sh`, S1.5/S3a stages, `smtp-doctor` |
| `config/nightshift.toml` | every knob | Modify: delete `[email].from` |
| `bin/test-harness.sh` | CI of the harness | Modify: sections 11-14 |

---

### Task 1: Prove one real send, with a server receipt

Nothing else in this plan is worth writing until a message provably leaves this host. This task adds no formatting, no HTML, no new summary field. It makes the existing plain-text digest send under a live credential check, an explicit socket timeout, and verbose smtplib logging, and it replaces the unfalsifiable success log with the SMTP server's own acceptance receipt.

**Files:**
- Modify: `scripts/sendmail.jac` (imports, `SMTP_TIMEOUT_SEC`, `scrub_smtp_debug`, `receipt_from_debug`, `smtp_send`, `send`, `build_message`, `doctor`, dispatch, tests)
- Modify: `lib/email.sh` (`email_main`)
- Modify: `config/nightshift.toml` (`[email]` loses `from`)
- Modify: `bin/nightshift.sh` (`smtp-doctor` command + usage)
- Modify: `bin/test-harness.sh` (section 11)

**Interfaces:**
- Produces: `scrub_smtp_debug(text: str) -> str` — removes every credential-bearing payload from an smtplib debug transcript, by allow-list of SMTP verbs.
- Produces: `receipt_from_debug(text: str) -> str` — the server's `250` acceptance of the DATA payload, or `""` if the transcript does not contain one.
- Produces: `smtp_send(msg: any, host: str, port: int, user: str, password: str) -> tuple[str, str]` — `(receipt, scrubbed_transcript)`. Raises if the transcript contains no receipt.
- Produces: `jac run scripts/sendmail.jac doctor <config.toml>` — sends a one-line probe to `[email].to`, prints the receipt on stdout and the scrubbed transcript on stderr. Exit 0 only with a receipt.
- Produces: `bin/nightshift.sh smtp-doctor` — the same, with `ns_load_env` in front of it.
- Produces: `$LOG_DIR/SMTP_RECEIPT` and `$LOG_DIR/smtp-debug.txt` on every real send attempt.
- Consumed by: `lib/email.sh` (this task), Task 7's fires-on-every-path check.

- [ ] **Step 1: Write the failing tests in `scripts/sendmail.jac`**

Append after the existing tests. These three fixtures are transcripts in exactly the shape `smtplib.set_debuglevel(1)` emits.

```jac
test "receipt_from_debug returns the 250 acceptance of the DATA payload" {
    ok: str = "send: 'ehlo [127.0.0.1]\\r\\n'\n"
        + "reply: b'250-smtp.gmail.com at your service\\r\\n'\n"
        + "reply: retcode (250); Msg: b'smtp.gmail.com at your service'\n"
        + "send: 'AUTH PLAIN AGZha2UAc2VjcmV0\\r\\n'\n"
        + "reply: retcode (235); Msg: b'2.7.0 Accepted'\n"
        + "send: 'mail FROM:<a@b.c> size=900\\r\\n'\n"
        + "reply: retcode (250); Msg: b'2.1.0 OK'\n"
        + "send: 'rcpt TO:<d@e.f>\\r\\n'\n"
        + "reply: retcode (250); Msg: b'2.1.5 OK'\n"
        + "send: 'data\\r\\n'\n"
        + "reply: retcode (354); Msg: b'Go ahead'\n"
        + "reply: retcode (250); Msg: b'2.0.0 OK  1753900000 a1sm42 - gsmtp'\n";
    assert receipt_from_debug(ok) == "2.0.0 OK  1753900000 a1sm42 - gsmtp";
}

test "receipt_from_debug refuses a transcript that never got its payload accepted" {
    # The server said "go ahead" and the connection then died. send_message would raise here --
    # but this is also EXACTLY the shape a stubbed/short-circuited send leaves behind, and the
    # whole point of the receipt is that it cannot be produced without a real acceptance.
    truncated: str = "send: 'data\\r\\n'\nreply: retcode (354); Msg: b'Go ahead'\n";
    assert receipt_from_debug(truncated) == "";
    # A 250 for RCPT is not a receipt: no DATA was ever sent.
    no_data: str = "send: 'rcpt TO:<d@e.f>\\r\\n'\nreply: retcode (250); Msg: b'2.1.5 OK'\n";
    assert receipt_from_debug(no_data) == "";
    assert receipt_from_debug("") == "";
}

test "scrub_smtp_debug removes every credential payload, keeps the protocol" {
    # AUTH PLAIN carries base64(user \0 user \0 password) as its ARGUMENT.
    # AUTH LOGIN carries them as bare base64 lines AFTER a 334 challenge, with no verb at all --
    # an AUTH-argument-only rule would leak the password on any server that negotiates LOGIN.
    raw: str = "send: 'AUTH PLAIN AGZha2UAc3VwZXJzZWNyZXQ=\\r\\n'\n"
        + "send: 'AUTH LOGIN\\r\\n'\n"
        + "reply: retcode (334); Msg: b'VXNlcm5hbWU6'\n"
        + "send: 'c3VwZXJzZWNyZXQ=\\r\\n'\n"
        + "send: 'ehlo [127.0.0.1]\\r\\n'\n"
        + "reply: retcode (250); Msg: b'2.0.0 OK  1753900000 a1sm42 - gsmtp'\n";
    scrubbed: str = scrub_smtp_debug(raw);
    assert "c3VwZXJzZWNyZXQ=" not in scrubbed;
    assert "AGZha2UAc3VwZXJzZWNyZXQ=" not in scrubbed;
    assert "AUTH PLAIN ***" in scrubbed;
    assert "send: ***" in scrubbed;
    # the diagnosable parts survive: verbs, reply codes, and the receipt itself
    assert "ehlo [127.0.0.1]" in scrubbed;
    assert "retcode (334)" in scrubbed;
    assert receipt_from_debug(scrubbed) == "2.0.0 OK  1753900000 a1sm42 - gsmtp";
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/sendmail.jac
```

Expected: FAIL — `receipt_from_debug` and `scrub_smtp_debug` are not defined.

- [ ] **Step 3: Implement the scrubber and the receipt parser**

In `scripts/sendmail.jac`, add to the imports at the top:

```jac
import io;
import re;
import from contextlib { redirect_stderr }
```

Then add these three definitions above `def send`:

```jac
"""Explicit socket timeout. Without one smtplib inherits the global default (None) and a night
with no network blocks inside connect() until the 8h watchdog kills the process -- meaning the
EXIT trap that exists to mail the autopsy is itself the thing that hangs. That is not
hypothetical: 2026-07-15 died at socket.getaddrinfo with `[Errno 8] nodename nor servname
provided` on a night whose S0 log also says `gh not authenticated`, i.e. the host was offline.
ponytail: a constant, not a config knob. 30s is longer than any healthy Gmail handshake and
shorter than every stage budget; nothing has ever wanted a different value. If one day something
does, it becomes [email].smtp_timeout_sec -- one line, in the file that already holds the port."""
glob SMTP_TIMEOUT_SEC: int = 30;

"""SMTP verbs whose full line is safe to keep in a saved transcript. Everything else a client
SENDS is either a base64 credential (the AUTH LOGIN challenge-response carries the password on a
bare line with no verb on it) or the message payload itself, and neither belongs in a log file."""
glob SMTP_SAFE_VERBS: list[str] = ["ehlo", "helo", "mail", "rcpt", "data", "quit",
                                   "rset", "noop", "starttls", "auth"];

"""smtplib at debuglevel 1 prints every byte it sends, which for a Gmail session includes
`send: 'AUTH PLAIN <base64 of user\\0user\\0password>'`. That transcript is written to
$LOG_DIR/smtp-debug.txt and quoted in failure reports, so the credential must be gone before it
is ever written. ALLOW-LIST, not deny-list: a `send:` line is kept only when its payload starts
with a known verb, and AUTH additionally loses its argument. Anything unrecognised -- including
the message body and any future auth mechanism -- becomes `send: ***`. Server `reply:` lines are
kept whole; the server never echoes the credential back."""
def scrub_smtp_debug(text: str) -> str {
    out: list[str] = [];
    for line in text.splitlines() {
        stripped: str = line.strip();
        if not stripped.startswith("send:") {
            out.append(line);
            continue;
        }
        payload: str = stripped[5:].strip().lstrip("b").strip("'\"").lower();
        verb: str = payload.split(" ")[0].strip();
        if verb == "auth" {
            # keep the mechanism name, drop its argument: "AUTH PLAIN <secret>" -> "AUTH PLAIN ***"
            out.append("send: 'AUTH " + payload.split(" ")[1].upper() + " ***'"
                       if len(payload.split(" ")) > 1 else "send: 'AUTH ***'");
        } elif verb in SMTP_SAFE_VERBS {
            out.append(line);
        } else {
            out.append("send: ***");
        }
    }
    return "\n".join(out);
}

"""The POSITIVE assertion that the message was accepted. smtplib.send_message() returns {} both
when every recipient was accepted and when nothing was actually transmitted, so "no exception
plus an empty dict" is an assertion that cannot fail -- the exact defect class this plan is
written against. The server's own 250 reply to the DATA PAYLOAD carries a queue id
(Gmail: `2.0.0 OK  1753900000 a1sm42 - gsmtp`) that no non-send can manufacture.

Requires the DATA verb to have been sent first: a 250 for RCPT means the envelope was accepted
and proves nothing about the message."""
def receipt_from_debug(text: str) -> str {
    data_sent: bool = False;
    receipt: str = "";
    for line in text.splitlines() {
        stripped: str = line.strip();
        if stripped.startswith("send:") and "'data" in stripped.lower() {
            data_sent = True;
            continue;
        }
        if data_sent and stripped.startswith("reply: retcode (250); Msg: ") {
            msg: str = stripped.split("Msg: ", 1)[1].strip();
            receipt = msg.lstrip("b").strip("'\"");
        }
    }
    return receipt;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/sendmail.jac
```

Expected: PASS, all tests including the three pre-existing ones.

- [ ] **Step 5: Replace `send` with a timed, logged, receipted send**

Replace the whole of `def send` (currently `scripts/sendmail.jac:104-117`) with:

```jac
"""Connect, authenticate, transmit, and RETURN THE RECEIPT. Raises on anything else.

set_debuglevel is called after the constructor has already connected, so the TCP/TLS handshake
itself is not in the transcript -- that failure mode raises with a perfectly clear errno of its
own (see the 07-15 traceback) and adding a bare SMTP_SSL()+connect() dance to capture it would
buy nothing. Everything from EHLO onwards, which is where the ambiguous failures live, IS
captured."""
def smtp_send(msg: any, host: str, port: int, user: str, password: str) -> tuple[str, str] {
    buf: any = io.StringIO();
    with redirect_stderr(buf) {
        with smtplib.SMTP_SSL(host, port, timeout=SMTP_TIMEOUT_SEC) as server {
            smtp: any = server;
            smtp.set_debuglevel(1);
            smtp.login(user, password);
            refused: dict = smtp.send_message(msg);
            if refused {
                raise ValueError("SMTP refused recipients: " + str(sorted(refused.keys())));
            }
        }
    }
    transcript: str = scrub_smtp_debug(buf.getvalue());
    receipt: str = receipt_from_debug(transcript);
    if not receipt {
        raise ValueError("no 250 acceptance of the DATA payload in the SMTP transcript — "
                         + "the message was NOT queued, whatever send_message returned");
    }
    return (receipt, transcript);
}

"""Live credential check BEFORE opening a socket: a missing env file is a config error the
operator can fix in seconds, and it should not look like a network failure (2026-07-12 spent a
whole night's autopsy on exactly that confusion)."""
def send(summary: dict, cfg: dict) -> tuple[str, str] {
    email_cfg: dict = as_dict(cfg["email"]);
    user: str | None = os.environ.get("SMTP_USER");
    password: str | None = os.environ.get("SMTP_PASS");
    if user is None or password is None or user == "" or password == "" {
        raise ValueError("SMTP_USER/SMTP_PASS not set or empty (source ~/.nightshift.env)");
    }
    return smtp_send(build_message(summary, cfg), str(email_cfg["smtp_host"]),
                     as_int(email_cfg["smtp_port"]), str(user), str(password));
}
```

- [ ] **Step 6: Make `From` the authenticated sender and delete the config knob**

`[email].from = "nightshift@localhost"` is not a deliverable address. Gmail rewrites a `From` it does not own to the authenticated user, so the header has never done anything except make the message look forged to spam classifiers. The authenticated user is the only value that can ever be right, so it stops being a knob.

In `scripts/sendmail.jac`, in `build_message`, replace the `From` line:

```jac
    # From is the AUTHENTICATED user, never config: Gmail rewrites any other value to exactly
    # this, so a [email].from knob could only ever be right by accident or wrong by drift.
    # ponytail: deletion over addition -- the knob is gone from config/nightshift.toml.
    msg["From"] = str(os.environ.get("SMTP_USER", "nightshift"))
```

In `config/nightshift.toml`, delete the `from` line from `[email]`:

```toml
[email]
to        = "contactayushmadhav@gmail.com"
# `from` deleted 2026-07-30: Gmail rewrites any From that is not the authenticated user, so
# sendmail.jac uses $SMTP_USER directly. A knob that can only ever hold one correct value is
# not a knob.
smtp_host = "smtp.gmail.com"
smtp_port = 465                              # SSL; creds live in ~/.nightshift.env, never here
```

Then confirm nothing else read it:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && grep -rn 'NS_EMAIL_FROM\|email_cfg\["from"\]\|"from"' lib bin scripts || echo "no readers remain"
```

Expected: `no readers remain`.

- [ ] **Step 7: Add the `doctor` verb and its dispatch**

Add above `with entry` in `scripts/sendmail.jac`:

```jac
"""One real send, smallest possible payload, printing the receipt. This is the command that
answers "does the pipe carry a byte", separately from "does the digest look right"."""
def doctor(cfg: dict) -> int {
    probe: dict = {
        "date": today(), "verdict": "SMTP doctor probe — not a real night.",
        "branches": [], "failed": [], "suspected_bugs": [], "warnings": [],
        "runtime_min": 0, "turns": 0, "cost_usd": 0, "error_stage": None,
    };
    (receipt, transcript) = send(probe, cfg);
    eprint(transcript);
    print(receipt);
    return 0;
}
```

`today` comes from `nslib`; extend the existing import line:

```jac
import from nslib { eprint, read_stdin, parse_obj, as_dict, as_list, as_int, load_config_toml, today }
```

In the `with entry` dispatch, add a `doctor` branch and make `send` print its receipt:

```jac
    } elif cmd == "doctor" and len(args) == 3 {
        doctor(load_config_toml(args[2]));
    } elif cmd in ["send", "render"] and len(args) == 3 {
        summary: dict = parse_obj(read_stdin());
        cfg: dict = load_config_toml(args[2]);
        if cmd == "render" {
            print(str(build_message(summary, cfg)));
        } else {
            (receipt, transcript) = send(summary, cfg);
            eprint(transcript);
            print(receipt);
        }
```

and add the usage line:

```jac
        eprint("       jac run sendmail.jac doctor <config.toml>          (one live probe send)");
```

- [ ] **Step 8: Consume the receipt in `lib/email.sh`**

Replace `email_main`'s send arm. `digest sent` may no longer be printed on the strength of an exit code alone.

```bash
    # `digest sent` used to be logged whenever sendmail exited 0, which is an assertion that
    # cannot fail: sendmail exits 0 whenever smtplib does not raise, and smtplib does not raise
    # for a send that never transmitted. The RECEIPT is the server's own 250 acceptance of the
    # DATA payload; no non-send produces one. Stdout carries it, stderr carries the scrubbed
    # protocol transcript (see scrub_smtp_debug -- the raw one contains the password).
    local receipt=""
    if receipt="$(printf '%s' "$summary" | ns_jac sendmail send "$CONFIG" 2> "$LOG_DIR/smtp-debug.txt")"; then
        case "$receipt" in
            "") email_last_ditch "sendmail exited 0 with NO server receipt — treat as not delivered" ;;
            *)  printf '%s\n' "$receipt" > "$LOG_DIR/SMTP_RECEIPT"
                ns_log S6 "digest accepted by $NS_EMAIL_SMTP_HOST for $NS_EMAIL_TO — receipt: $receipt" ;;
        esac
    else
        email_last_ditch "smtp send failed — see $LOG_DIR/smtp-debug.txt"
    fi
```

Note the `case`, not `[ -z "$receipt" ] && …`: `email_main` is called from the EXIT trap, and a false `&&` list returning nonzero there would change the exit code the night reports.

- [ ] **Step 9: Add `nightshift.sh smtp-doctor`**

In `usage()`:

```
       nightshift.sh smtp-doctor                # one live probe email; prints the server receipt
```

In the `case`, before `dataset-backfill`:

```bash
    smtp-doctor) mkdir -p "$LOG_DIR"; ns_load_env
                # Deliberately NOT gated on NS_DRY_RUN: this command exists to send for real.
                rc=0; ns_jac sendmail doctor "$CONFIG" > "$LOG_DIR/SMTP_RECEIPT" 2> "$LOG_DIR/smtp-debug.txt" || rc=$?
                case "$rc" in
                    0) echo "receipt: $(cat "$LOG_DIR/SMTP_RECEIPT")" ;;
                    *) echo "smtp-doctor FAILED (rc=$rc); scrubbed transcript:" >&2
                       tail -30 "$LOG_DIR/smtp-debug.txt" >&2 ;;
                esac
                exit "$rc" ;;
```

- [ ] **Step 10: Send one real email and read it**

This is the step the whole plan is ordered around. Do not skip it, and do not accept the exit code as the answer.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/nightshift.sh smtp-doctor
```

Expected: `receipt: 2.0.0 OK  <epoch> <queue-id> - gsmtp`, exit 0.

Then, in order:

1. Open the inbox at `[email].to` and confirm a message titled `Nightshift <today> · 0 ready · +0 -0 · 0 failed` **arrived**. Check the spam folder too; if it landed there, note it in the commit message — that is the `From` fix earning its place.
2. Confirm the transcript contains no credential:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
grep -c "AUTH PLAIN \*\*\*\|AUTH LOGIN \*\*\*" logs/$(date +%F)/smtp-debug.txt
grep -oE "^send: '?[A-Za-z]+" logs/$(date +%F)/smtp-debug.txt | sort -u
```

Expected: at least `1` from the first command, and the second lists only verbs (`ehlo`, `mail`, `rcpt`, `data`, `quit`) plus `send: ***` lines. **If any base64 blob appears in that file, stop and fix `scrub_smtp_debug` before committing** — the file is about to be committed to a log directory and quoted into failure reports.

- [ ] **Step 11: Mutation-test the receipt guard**

The guard's whole value is that it cannot pass for a send that did not happen. Prove it, rather than reading it.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
cp scripts/sendmail.jac /tmp/sendmail.jac.bak
# MUTATION: make receipt_from_debug accept a RCPT 250 by dropping the data_sent requirement.
perl -0pi -e 's/if data_sent and stripped\.startswith/if stripped.startswith/' scripts/sendmail.jac
rm -rf .jac && jac test scripts/sendmail.jac > /dev/null 2>&1 \
  && echo "BUG: the receipt guard is weaker than it looks" || echo "mutation caught: guard is real"
cp /tmp/sendmail.jac.bak scripts/sendmail.jac
# MUTATION 2: make the scrubber a no-op and confirm the credential test fails.
perl -0pi -e 's/def scrub_smtp_debug\(text: str\) -> str \{/def scrub_smtp_debug(text: str) -> str {\n    return text;/' scripts/sendmail.jac
rm -rf .jac && jac test scripts/sendmail.jac > /dev/null 2>&1 \
  && echo "BUG: the credential scrubber is not actually tested" || echo "mutation caught: scrubber is real"
cp /tmp/sendmail.jac.bak scripts/sendmail.jac
rm -rf .jac && jac test scripts/sendmail.jac
```

Expected: `mutation caught` twice, then a clean PASS.

- [ ] **Step 12: Add harness section 11 and run the suite**

Append to `bin/test-harness.sh` before the final echo:

```bash
echo "== 11. the digest's transport guards: receipt required, credentials scrubbed =="
# scripts/sendmail.jac's own tests cover the two pure functions (section 1 runs them). What is NOT
# covered there is that lib/email.sh actually CONSUMES the receipt rather than the exit code --
# the exact shape of the bug this task exists to remove. Driven, not grepped for.
rm -rf .jac
E="$T/email"; mkdir -p "$E"
# A stub `ns_jac sendmail send` that exits 0 and prints NOTHING is a send that did not happen.
(
    . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/email.sh"
    LOG_DIR="$E"; NS_DATE=2026-01-02; NS_EMAIL_TO=t@t; NS_EMAIL_SMTP_HOST=h
    ns_jac() { case "$2" in summarize) echo '{"date":"2026-01-02"}' ;; send) return 0 ;; esac; }
    osascript() { return 0; }
    email_main
) > /dev/null 2>&1
[ -f "$E/EMAIL_FAILED" ] \
    || fail "email_main reported success for a send that produced NO receipt -- 'exited 0' is not 'delivered'"
rm -f "$E/EMAIL_FAILED"
# ...and a stub that prints a receipt must be believed, and must record it.
(
    . "$NS_ROOT/lib/common.sh"; . "$NS_ROOT/lib/email.sh"
    LOG_DIR="$E"; NS_DATE=2026-01-02; NS_EMAIL_TO=t@t; NS_EMAIL_SMTP_HOST=h
    ns_jac() { case "$2" in summarize) echo '{"date":"2026-01-02"}' ;; send) echo "2.0.0 OK q1 - gsmtp" ;; esac; }
    email_main
) > /dev/null 2>&1
[ -f "$E/SMTP_RECEIPT" ] || fail "email_main did not record the server receipt it was handed"
[ -f "$E/EMAIL_FAILED" ] && fail "email_main flagged a receipted send as failed"
echo "transport guards behave: no receipt means not delivered"
```

Note the deliberate `[ -f … ] && fail` on the last line only: `fail` exits, so that `&&` list is never the last command of a successful path.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
```

Expected: `ALL HARNESS TESTS PASSED`.

- [ ] **Step 13: Commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add scripts/sendmail.jac lib/email.sh config/nightshift.toml bin/nightshift.sh bin/test-harness.sh
git commit -m "Prove the digest send with a server receipt, timeout, and scrubbed transcript

The record does not support 'SMTP has never worked'. Seven EMAIL_FAILED markers
exist, all on or before 07-15, with three different causes: SMTP_USER/SMTP_PASS
unset (07-12), summarize failing before SMTP was reached (07-13.pre-demo), and
socket.getaddrinfo returning [Errno 8] on 07-15 -- a night whose S0 log two lines
earlier says 'gh not authenticated', i.e. the host was offline. Six nights since
commit 2504da4 added the success log line report 'digest sent'.

The real defect is that 'digest sent' cannot fail. sendmail exits 0 whenever
smtplib does not raise, and send_message returns {} both for 'all recipients
accepted' and for a send that never transmitted. So send() now returns the
server's own 250 acceptance of the DATA payload -- a queue id no non-send can
manufacture -- and lib/email.sh logs success only when it has one.

Also: an explicit 30s socket timeout, so an offline night fails in seconds
instead of blocking in connect() until the watchdog kills the process that was
supposed to mail the autopsy; verbose smtplib logging captured to
\$LOG_DIR/smtp-debug.txt through an ALLOW-LIST scrubber, because a debuglevel-1
transcript contains 'AUTH PLAIN <base64 of the password>'; and [email].from is
deleted, since Gmail rewrites any From that is not the authenticated user."
```

---

### Task 2: Make the digest say *why* the night died

Follow-ups section 5. Every fatal path in the gate exits `EX_BUG=70` and `ns_on_exit` copies only the stage name to `ERROR_STAGE`, so `ERROR S4` is the operator's entire diagnosis across 13 distinct `ns_die` sites in `lib/verify.sh` alone. Plan 1 shipped a stopgap: `ns_die` writes `$*` to `$LOG_DIR/FATAL_REASON` and `ns_on_exit` appends it to `warnings.txt`, which the digest renders verbatim. This makes it a first-class field and deletes the stopgap.

The second half is a one-line bug: `ERROR_STAGE` is not cleared on a same-night re-run while `FATAL_REASON` is, so a green re-run reports a stale stage.

**Files:**
- Modify: `bin/nightshift.sh` (`ns_run` clear, `ns_on_exit` fold removed)
- Modify: `scripts/sendmail.jac` (`summarize`, `subject`, `plain_body`, tests)
- Modify: `bin/test-harness.sh` (section 12)

**Interfaces:**
- Produces: `summary["fatal_reason"]` — the text `ns_die` was called with, or `None`.
- Produces: a subject line that names the reason, not just the stage.
- Consumed by: Task 6's HTML body.

- [ ] **Step 1: Write the failing tests in `scripts/sendmail.jac`**

```jac
test "the subject names the fatal reason, not just the stage" {
    summary: dict = {
        "date": "2026-07-10", "branches": [], "failed": [],
        "error_stage": "S4", "fatal_reason": None,
    };
    assert subject(summary).endswith("· ERROR S4");
    summary["fatal_reason"] = "mirror job 'compiler' collected 0 items — the runner never started";
    # the stage alone is almost no information: 13 ns_die sites in lib/verify.sh share it
    assert "ERROR S4: mirror job 'compiler' collected 0 items" in subject(summary);
    # bounded, because a subject line is not a log: the full text lives in the body
    assert len(subject(summary)) <= 160;
}

test "summarize reads FATAL_REASON and ERROR_STAGE as separate facts" {
    import tempfile;
    log_dir: str = tempfile.mkdtemp();
    drafts_dir: str = tempfile.mkdtemp();
    with open(os.path.join(log_dir, "ERROR_STAGE"), "w") as f {
        f.write("S4\n");
    }
    with open(os.path.join(log_dir, "FATAL_REASON"), "w") as f {
        f.write("no theme file for nightshift/2026-07-10/x\n");
    }
    cfg: dict = {"repo": {"fork": "me/jaseci"}, "budgets": {"wallclock_min": 480}};
    s: dict = summarize(log_dir, drafts_dir, "2026-07-10", cfg);
    assert s["error_stage"] == "S4";
    assert s["fatal_reason"] == "no theme file for nightshift/2026-07-10/x";
    assert "no theme file" in plain_body(s);
    # a clean night carries neither
    clean: str = tempfile.mkdtemp();
    s2: dict = summarize(clean, drafts_dir, "2026-07-10", cfg);
    assert s2["error_stage"] is None and s2["fatal_reason"] is None;
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/sendmail.jac
```

Expected: FAIL — `fatal_reason` is not in the summary.

- [ ] **Step 3: Implement in `scripts/sendmail.jac`**

In `summarize`, next to the existing `error_lines` read:

```jac
    error_lines: list[str] = read_lines(os.path.join(log_dir, "ERROR_STAGE"));
    fatal_lines: list[str] = read_lines(os.path.join(log_dir, "FATAL_REASON"));
```

and in the returned dict:

```jac
        "error_stage": error_lines[0] if error_lines else None,
        # WHY the night died, not just where. ns_die (lib/common.sh) writes the message it was
        # called with; ERROR_STAGE alone is shared by 13 ns_die sites in lib/verify.sh.
        "fatal_reason": " ".join(fatal_lines) if fatal_lines else None,
```

In `subject`, extend the error suffix:

```jac
    } elif summary.get("error_stage") is not None and summary.get("error_stage") != "" {
        s += " · ERROR " + str(summary["error_stage"]);
        reason: any = summary.get("fatal_reason");
        if reason is not None and str(reason) != "" {
            # truncated to keep the subject scannable; plain_body and the HTML carry it in full
            s += ": " + str(reason)[:80];
        }
    }
```

In `plain_body`, immediately after the verdict line, so the reason is the first thing read:

```jac
    fatal: any = summary.get("fatal_reason");
    if fatal is not None and str(fatal) != "" {
        lines += ["FATAL (" + str(summary.get("error_stage", "?")) + "): " + str(fatal), ""];
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/sendmail.jac
```

Expected: PASS.

- [ ] **Step 5: Clear `ERROR_STAGE` on a same-night re-run**

In `bin/nightshift.sh`'s `ns_run`, extend the existing `FATAL_REASON` clear:

```bash
    # Same-night re-runs share $LOG_DIR (it is date-keyed), so markers left by an earlier attempt
    # would be re-reported against this one. ERROR_STAGE was missing from this line, so a GREEN
    # re-run after a red one still mailed "ERROR S4" -- the one case where the digest actively
    # lies (follow-ups section 5).
    rm -f "$LOG_DIR/FATAL_REASON" "$LOG_DIR/ERROR_STAGE"
```

- [ ] **Step 6: Delete the Plan 1 stopgap from `ns_on_exit`**

`summarize` now reads `FATAL_REASON` directly, so folding it into `warnings.txt` would print it twice and keep a second, lossier copy of the same fact. Delete the whole `if [ "$code" -ne 0 ] && [ -f "$LOG_DIR/FATAL_REASON" ]; then … fi` block and its comment, leaving:

```bash
ns_on_exit() {
    local code=$?
    if [ "$code" -ne 0 ] && [ -f "$LOG_DIR/CURRENT_STAGE" ]; then
        cp "$LOG_DIR/CURRENT_STAGE" "$LOG_DIR/ERROR_STAGE"
    fi
    # ERROR_STAGE names WHERE the night died; FATAL_REASON (written by ns_die, lib/common.sh) says
    # WHY. Both are read as first-class fields by scripts/sendmail.jac's summarize(); the Plan 1
    # stopgap that appended the reason into warnings.txt is gone with them.
    email_main >> "$LOG_DIR/S6.log" 2>&1 || true
```

Also update the comment on `ns_die` in `lib/common.sh` — it says "the real digest work is Plan 4", which is now done:

```bash
# ns_die RECORDS WHY, not just that. bin/nightshift.sh's ns_on_exit copies CURRENT_STAGE to
# ERROR_STAGE (WHERE), and this writes the reason text (WHY). Both are read as first-class fields
# by scripts/sendmail.jac's summarize() and appear in the subject line and the digest body.
# Best-effort (`|| true`): $LOG_DIR may not exist yet on the earliest failure paths, and losing
# the reason must never change the exit code the caller asked for.
```

- [ ] **Step 7: Prove the stale-stage bug is fixed, by driving the real line**

A grep would pass against a line that was moved somewhere it never runs. Extract `ns_run`'s actual clearing statement and execute it. Append to `bin/test-harness.sh`:

```bash
echo "== 12. same-night re-run must not report a STALE fatal stage =="
# ERROR_STAGE was cleared nowhere while FATAL_REASON was cleared in ns_run, so a green re-run
# after a red one mailed "ERROR S4" with no reason attached -- the digest's only outright lie.
# Driven against the REAL statement, extracted from bin/nightshift.sh, so moving or narrowing it
# fails here rather than passing a grep.
clear_stmt="$(grep -E '^[[:space:]]*rm -f "\$LOG_DIR/FATAL_REASON"' bin/nightshift.sh | head -1)"
case "$clear_stmt" in
    "") fail "bin/nightshift.sh no longer clears FATAL_REASON in ns_run -- section 12 would be vacuous" ;;
esac
S="$T/staleclear"; mkdir -p "$S"
( LOG_DIR="$S"; touch "$S/FATAL_REASON" "$S/ERROR_STAGE"; eval "$clear_stmt" )
[ -e "$S/FATAL_REASON" ] && fail "the extracted clear statement did not remove FATAL_REASON"
[ -e "$S/ERROR_STAGE" ] && fail "a same-night re-run leaves a STALE ERROR_STAGE; the digest would report a green run as failed"
echo "same-night re-run clears both fatal markers"
```

- [ ] **Step 8: Mutation-test it**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
cp bin/nightshift.sh /tmp/ns.bak
perl -0pi -e 's{rm -f "\$LOG_DIR/FATAL_REASON" "\$LOG_DIR/ERROR_STAGE"}{rm -f "\$LOG_DIR/FATAL_REASON"}' bin/nightshift.sh
bin/test-harness.sh > /dev/null 2>&1 && echo "BUG: section 12 does not actually check ERROR_STAGE" \
                                     || echo "mutation caught: the stale-stage check is real"
cp /tmp/ns.bak bin/nightshift.sh
bin/test-harness.sh | tail -1
```

Expected: `mutation caught: the stale-stage check is real`, then `ALL HARNESS TESTS PASSED`.

- [ ] **Step 9: Commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add bin/nightshift.sh lib/common.sh scripts/sendmail.jac bin/test-harness.sh
git commit -m "Report WHY a night died, and stop reporting a stale stage on a re-run

Every fatal path in the gate exits EX_BUG=70 and the digest reported only the
stage name, so 'ERROR S4' is shared by 13 distinct ns_die sites in lib/verify.sh
alone -- almost no information in the operator's only unattended channel.
FATAL_REASON becomes a first-class summary field: it heads the digest body and
is truncated into the subject line. The Plan 1 stopgap that appended it into
warnings.txt is deleted rather than kept alongside.

ERROR_STAGE was cleared nowhere while FATAL_REASON was cleared in ns_run, so a
GREEN same-night re-run after a red one still mailed 'ERROR S4'. One line. The
harness now drives the real clearing statement rather than grepping for it, and
mutation confirms the check fails when ERROR_STAGE is dropped from it."
```

---

### Task 3: Poll for merged PRs, and tell "nothing merged" apart from "did not ask"

Spec section 10. A webhook needs repo admin on `jaseci-labs/jac` and the token has `{admin:false, push:false, pull:true}`, so detection is polling. The whole task is one `gh` call plus the guards that make its result trustworthy.

**Files:**
- Create: `scripts/merges.jac`
- Create: `lib/reactive.sh` (poll only; the pass lands in Task 4)
- Modify: `bin/nightshift.sh` (source it, add the S1.5 stage)
- Modify: `bin/test-harness.sh:13` (register `merges` in the jac test sweep)

**Interfaces:**
- Produces: `jac run scripts/merges.jac since <state.json>` — the ISO date to poll from: `last_merge_poll` if set, else yesterday.
- Produces: `jac run scripts/merges.jac count <merges.json>` — the number of merged PRs. **Exits nonzero if the file is absent, empty, or not a JSON array**; prints `0` for a genuinely empty array.
- Produces: `jac run scripts/merges.jac files <merges.json>` — the sorted, deduped union of changed paths, one per line.
- Produces: `jac run scripts/merges.jac prs <merges.json>` — one `number<TAB>title<TAB>author<TAB>nfiles` line per PR, for the digest.
- Produces: `reactive_poll()` in `lib/reactive.sh` — writes `$LOG_DIR/merges.json` and `$LOG_DIR/reactive-files.txt`, advances `last_merge_poll` **only on success**, returns 0 when the poll is trustworthy (including an empty one) and 1 when it is not.
- Consumed by: Task 4's four-lens pass, Task 5's summary.

- [ ] **Step 1: Verify `gh pr list --json files` is actually supported**

The whole design assumes one call returns both the PR list and its files. Confirm before building on it, and note the fallback if it does not.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
gh pr list --repo jaseci-labs/jac --state merged --limit 2 \
   --json number,title,author,files | head -c 600; echo
```

Expected: a JSON array whose objects each carry `number`, `title`, `author.login`, and a `files` array of `{path, additions, deletions}`.

If `files` is rejected as an unsupported field for `pr list`, the fallback is one `gh pr view <n> --json files` per PR number, driven from bash and merged by `merges.jac files`. Record which branch you took in a comment at the top of `lib/reactive.sh`; do not leave it ambiguous.

- [ ] **Step 2: Write `scripts/merges.jac` with its tests and no implementation**

```jac
"""Merged-PR poll data (design spec section 10). bash runs `gh`; Jac owns the parsing.

Merge detection is POLLING, not a webhook: a webhook needs repo admin on jaseci-labs/jac and the
token has {admin:false, push:false, pull:true}.

argv:
  since <state.json>       print the ISO date to poll from (last_merge_poll, else yesterday)
  count <merges.json>      print the PR count; EXIT NONZERO if the file is not a JSON array
  files <merges.json>      print the sorted union of changed paths, one per line
  prs   <merges.json>      print number<TAB>title<TAB>author<TAB>nfiles, one per PR
"""
import sys;
import json;
import datetime;
import from nslib { eprint, as_dict, as_list, state_read }

"""Default window is ONE DAY, not "since the harness started". A missed night (07-28 to 07-30
happened) leaves last_merge_poll stale by exactly the number of nights missed, and the >= date
search then catches all of them up on the next successful run -- which is the desired behavior
and needs no separate backfill path."""
def poll_since(state_path: str) -> str {
    state: dict = state_read(state_path);
    recorded: any = state.get("last_merge_poll", "");
    if recorded is not None and str(recorded) != "" {
        return str(recorded);
    }
    return str(datetime.date.today() - datetime.timedelta(days=1));
}

"""Load and VALIDATE. An empty file is not an empty list: `gh` can exit 0 having written nothing
(killed mid-write, rate-limited, auth expired mid-call), and an empty file word-splits to zero
iterations in bash exactly like a genuinely quiet day. Raising here is what lets lib/reactive.sh
tell "no merges" apart from "failed to ask" -- the defect class this whole harness keeps hitting."""
def load_merges(path: str) -> list[dict] {
    with open(path, "r") as f {
        text: str = f.read();
    }
    if not text.strip() {
        raise ValueError("merges file is EMPTY: gh exited 0 but wrote nothing — "
                         + "that is 'did not ask', not 'nothing merged'");
    }
    parsed: any = json.loads(text);
    if not isinstance(parsed, list) {
        raise ValueError("merges file is not a JSON array: " + str(type(parsed)));
    }
    return [as_dict(p) for p in parsed];
}

def changed_files(prs: list[dict]) -> list[str] {
    seen: set[str] = set();
    for pr in prs {
        for f in as_list(pr.get("files", [])) {
            path: str = str(as_dict(f).get("path", ""));
            if path {
                seen.add(path);
            }
        }
    }
    return sorted(seen);
}

def pr_rows(prs: list[dict]) -> list[str] {
    rows: list[str] = [];
    for pr in prs {
        author: str = str(as_dict(pr.get("author", {})).get("login", "?"));
        rows.append(str(pr.get("number", "?")) + "\t" + str(pr.get("title", "")) + "\t"
                    + author + "\t" + str(len(as_list(pr.get("files", [])))));
    }
    return rows;
}

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "since" and len(args) == 3 {
        print(poll_since(args[2]));
    } elif cmd == "count" and len(args) == 3 {
        print(len(load_merges(args[2])));
    } elif cmd == "files" and len(args) == 3 {
        for p in changed_files(load_merges(args[2])) {
            print(p);
        }
    } elif cmd == "prs" and len(args) == 3 {
        for r in pr_rows(load_merges(args[2])) {
            print(r);
        }
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run merges.jac since <state.json>");
        eprint("       jac run merges.jac count|files|prs <merges.json>");
    }
}

test "an empty or non-array merges file is an ERROR, never an empty result" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    empty: str = d + "/empty.json";
    with open(empty, "w") as f {
        f.write("");
    }
    raised: bool = False;
    try {
        load_merges(empty);
    } except ValueError {
        raised = True;
    }
    assert raised;                                  # NOT `== []`
    notarray: str = d + "/obj.json";
    with open(notarray, "w") as f {
        f.write("{\"message\": \"Bad credentials\"}");
    }
    raised2: bool = False;
    try {
        load_merges(notarray);
    } except ValueError {
        raised2 = True;
    }
    assert raised2;
    # ...and a real quiet day parses cleanly to zero
    quiet: str = d + "/quiet.json";
    with open(quiet, "w") as f {
        f.write("[]");
    }
    assert load_merges(quiet) == [];
    assert changed_files(load_merges(quiet)) == [];
}

test "changed_files is the deduped union across PRs, sorted" {
    prs: list[dict] = [
        {"number": 1, "title": "a", "author": {"login": "x"},
         "files": [{"path": "jac/jaclang/cli/a.jac"}, {"path": "jac/jaclang/cli/b.jac"}]},
        {"number": 2, "title": "b", "author": {"login": "nightshift"},
         "files": [{"path": "jac/jaclang/cli/b.jac"}, {"path": "jac/jaclang/scale/c.jac"}]},
    ];
    assert changed_files(prs) == ["jac/jaclang/cli/a.jac", "jac/jaclang/cli/b.jac",
                                  "jac/jaclang/scale/c.jac"];
    # ALL authors, nightshift's own merged PRs included (spec section 10)
    rows: list[str] = pr_rows(prs);
    assert rows[1].startswith("2\tb\tnightshift\t2");
    assert len(rows) == 2;
}

test "poll_since falls back to yesterday and honours a recorded date" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    fresh: str = d + "/state.json";
    with open(fresh, "w") as f {
        f.write("{}");
    }
    yesterday: str = str(datetime.date.today() - datetime.timedelta(days=1));
    assert poll_since(fresh) == yesterday;
    recorded: str = d + "/state2.json";
    with open(recorded, "w") as f {
        f.write("{\"last_merge_poll\": \"2026-07-27\"}");
    }
    # a missed night must widen the window, not reset it: 07-28..07-30 all get caught up
    assert poll_since(recorded) == "2026-07-27";
}
```

- [ ] **Step 3: Run the tests and register the script**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/merges.jac
```

Expected: PASS, three tests. Then add `merges` to the sweep list at `bin/test-harness.sh:13`.

- [ ] **Step 4: Create `lib/reactive.sh` with the poll**

```bash
# shellcheck shell=bash
# lib/reactive.sh — S1.5 merge poll + S3a reactive pass (design spec section 10).
#
# Merge detection is POLLING, not a webhook: a webhook needs repo admin on jaseci-labs/jac and
# the token has {admin:false, push:false, pull:true} (spec section 2).
#
# `gh pr list --json files` returns the changed-file set inline, verified 2026-07-30 (Task 3
# Step 1). If that ever stops being true, the fallback is one `gh pr view <n> --json files` per
# number; do not silently degrade to "no files".

# Ask which PRs merged upstream since the last SUCCESSFUL poll. Writes $LOG_DIR/merges.json and
# $LOG_DIR/reactive-files.txt. Returns 0 when the answer is trustworthy -- INCLUDING a genuinely
# empty one -- and 1 when it is not.
reactive_poll() {
    local since rc=0 n
    since="$(ns_jac merges since "$STATE")" || {
        ns_fail "S1.5 merge poll" "could not read last_merge_poll from $STATE"
        return 1
    }

    # NOT `$(gh …)` inside a conditional: the exit status must be captured on its own, because
    # `gh` exits 0 having written NOTHING under several failure modes (killed mid-write, rate
    # limit, token expiry mid-call) and an empty file iterates zero times in bash exactly like a
    # quiet day. `--limit 200`: at ~10 merges/day upstream a missed week still fits, and a
    # truncated list would silently narrow the audit scope rather than fail.
    "$NS_PATHS_GH" pr list --repo "$NS_REPO_UPSTREAM" --state merged \
        --search "merged:>=$since" --limit 200 \
        --json number,title,author,files \
        > "$LOG_DIR/merges.json" 2> "$LOG_DIR/merges-err.txt" || rc=$?
    if [ "$rc" -ne 0 ]; then
        ns_fail "S1.5 merge poll" "gh exited $rc — cannot tell 'no merges' from 'did not ask'; reactive pass skipped ($(tail -1 "$LOG_DIR/merges-err.txt" 2>/dev/null || echo "no stderr"))"
        rm -f "$LOG_DIR/merges.json"
        return 1
    fi

    # THE POSITIVE ASSERTION. `count` refuses an empty or non-array file, so reaching the next
    # line proves gh really answered. A quiet day prints 0 here and is a SUCCESS.
    if ! n="$(ns_jac merges count "$LOG_DIR/merges.json")"; then
        ns_fail "S1.5 merge poll" "gh exited 0 but wrote no parseable JSON array — treating as 'did not ask'"
        rm -f "$LOG_DIR/merges.json"
        return 1
    fi

    ns_jac merges files "$LOG_DIR/merges.json" > "$LOG_DIR/reactive-files.txt"
    ns_log S1.5 "$n PR(s) merged upstream since $since, $(wc -l < "$LOG_DIR/reactive-files.txt" | tr -d ' ') changed file(s)"

    # Advanced ONLY on a trustworthy poll: a failed poll must not lose a day of merges.
    # ponytail: the window is date-granular, so re-running the same night re-audits the same PRs.
    #           Harmless -- findings already carry ledger fingerprints and the selector suppresses
    #           drafted/buried ones. Upgrade path if it ever stops being harmless: record the max
    #           PR number alongside the date and filter on it.
    ns_jac ledger state-set last_merge_poll "$NS_DATE" "$STATE"
    return 0
}
```

- [ ] **Step 5: Wire the S1.5 stage**

In `bin/nightshift.sh`, source the new file next to the others:

```bash
. "$NS_ROOT/lib/reactive.sh"
```

and add the stage in `ns_run_inner`, between S1 and S2 (the poll is read-only and cheap, so it runs before tier-1 and its result is available to everything after):

```bash
    ns_stage S0 preflight_main
    ns_stage S1 sync_main
    ns_stage S1.5 reactive_poll        # read-only gh poll; the PASS itself is S3a, inside tier2_main
    ns_stage S2 tier1_main
```

`ns_stage` runs the function with `>> "$LOG_DIR/$id.log"`, so this creates `logs/<date>/S1.5.log`. That is fine and wanted.

- [ ] **Step 6: Run the poll for real**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
NS_ROOT="$PWD" bash -c '. lib/common.sh; ns_load_config; ns_load_env; . lib/reactive.sh
  LOG_DIR="/tmp/ns-reactive"; mkdir -p "$LOG_DIR"; STATE=/tmp/ns-reactive/state.json
  echo "{}" > "$STATE"; NS_DATE="$(date +%F)"
  reactive_poll; echo "rc=$?"'
head -5 /tmp/ns-reactive/reactive-files.txt; cat /tmp/ns-reactive/state.json
```

Expected: `rc=0`, a plausible file list (or none, on a quiet day), and `last_merge_poll` set to today.

- [ ] **Step 7: Prove the "did not ask" path fails, and add harness section 13**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
# gh that exits 0 and writes nothing — the exact failure this guard exists for
T2="$(mktemp -d)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$T2/gh"; chmod +x "$T2/gh"
NS_ROOT="$PWD" bash -c '. lib/common.sh; ns_load_config; . lib/reactive.sh
  LOG_DIR="'"$T2"'"; STATE="'"$T2"'/state.json"; echo "{}" > "$STATE"; NS_DATE=2026-01-02
  NS_PATHS_GH="'"$T2"'/gh"; reactive_poll; echo "rc=$?"'
grep -q last_merge_poll "$T2/state.json" && echo "BUG: a failed poll advanced the watermark" \
                                         || echo "correct: watermark not advanced on a bad poll"
```

Expected: `rc=1` and `correct: watermark not advanced on a bad poll`.

Then append to `bin/test-harness.sh`:

```bash
echo "== 13. merge poll: 'nothing merged' must be distinguishable from 'failed to ask' =="
# `gh` exits 0 having written nothing under several failure modes, and an empty file word-splits
# to zero iterations exactly like a quiet day -- the harness's recurring defect class, now in a
# new stage. Driven against the REAL reactive_poll with a stubbed gh.
P="$T/poll"; mkdir -p "$P"
poll_probe() {          # poll_probe <gh-stdout> -> prints "rc=<n> watermark=<yes|no>"
    printf '#!/usr/bin/env bash\nprintf %%s %s\nexit 0\n' "$(printf '%q' "$1")" > "$P/gh"
    chmod +x "$P/gh"; echo '{}' > "$P/state.json"; rm -f "$P/merges.json"
    local rc=0
    ( . "$NS_ROOT/lib/common.sh"; ns_bootstrap_jac; . "$NS_ROOT/lib/reactive.sh"
      LOG_DIR="$P"; STATE="$P/state.json"; NS_DATE=2026-01-02; NS_PATHS_GH="$P/gh"
      NS_REPO_UPSTREAM=jaseci-labs/jac; reactive_poll ) >/dev/null 2>&1 || rc=$?
    if grep -q last_merge_poll "$P/state.json" 2>/dev/null; then
        echo "rc=$rc watermark=yes"
    else
        echo "rc=$rc watermark=no"
    fi
}
case "$(poll_probe '')" in
    "rc=1 watermark=no") : ;;
    *) fail "an EMPTY gh response was accepted as a quiet day: $(poll_probe '') -- 'did not ask' is being scored as 'nothing merged'" ;;
esac
case "$(poll_probe '{"message":"Bad credentials"}')" in
    "rc=1 watermark=no") : ;;
    *) fail "a non-array gh response was accepted as a merge list" ;;
esac
case "$(poll_probe '[]')" in
    "rc=0 watermark=yes") : ;;
    *) fail "a genuinely quiet day was reported as a poll FAILURE -- it must succeed with zero merges" ;;
esac
case "$(poll_probe '[{"number":1,"title":"t","author":{"login":"a"},"files":[{"path":"jac/jaclang/cli/a.jac"}]}]')" in
    "rc=0 watermark=yes") : ;;
    *) fail "a real merge list was rejected" ;;
esac
grep -q 'jac/jaclang/cli/a.jac' "$P/reactive-files.txt" \
    || fail "reactive_poll did not write the changed-file union"
echo "merge poll distinguishes quiet, empty, malformed and real"
```

- [ ] **Step 8: Run the harness and commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add scripts/merges.jac lib/reactive.sh bin/nightshift.sh bin/test-harness.sh
git commit -m "Poll upstream for merged PRs, refusing to guess when gh does not answer

Merge detection is polling: a webhook needs repo admin on jaseci-labs/jac and
the token has {admin:false, push:false, pull:true}. One \`gh pr list --state
merged --search merged:>=<watermark> --json number,title,author,files\` per
night; the union of changed files becomes the reactive audit scope.

The guard is the point. gh exits 0 having written nothing under several failure
modes, and an empty file word-splits to zero iterations in bash exactly like a
genuinely quiet day -- the same 'did not run scored as passed' shape that
produced seven bugs in the gate. merges.jac RAISES on an empty or non-array
file, so reaching the next line proves gh really answered, and the
last_merge_poll watermark advances only on a trustworthy poll so a failed one
cannot lose a day of merges. Four harness cases: empty, malformed, quiet, real."
```

---

### Task 4: The reactive pass — four lenses over the merged file set

Spec section 10. All four task lenses run over the union of files that merged upstream today, before the cycle task, so an active repo day gets same-night cleanup. Nightshift's own merged PRs are included.

**This is the expensive part of the plan and it must earn its cost.** Four lenses is four LLM sessions a night. The whole justification is that the scope is a handful of files rather than an 87k-LOC shard, so:

- **A quiet day costs nothing.** Zero merged files means zero sessions, zero `audit-*.json`, zero `ns_fail` rows, and exactly one log line. The guard is the first thing in the function.
- **A busy day is bounded.** The lenses run at the same concurrency as the shard fan-out and stop scheduling when the clock cannot afford another one.
- **A suspiciously large file set is a signal, not a workload.** If a day's merges touch more files than an audit session can meaningfully read, the pass logs it and audits the largest-signal subset rather than pretending. `ponytail:` ceiling with the upgrade path stated inline.

**Files:**
- Modify: `lib/tier2.sh` (`tier2_audit_shard` takes an explicit scope; `tier2_select`/`tier2_apply` take a phase)
- Modify: `lib/reactive.sh` (add `reactive_main`)
- Modify: `bin/test-harness.sh` (section 14)

**Interfaces:**
- Changed: `tier2_audit_shard <name> <scope> <task>` — was `tier2_audit_shard <shard>` looking its own scope up. The reactive pass and the shard fan-out are now the same function with different scope strings, which is why there is no second audit driver.
- Changed: `tier2_select <phase>` / `tier2_apply <phase>` — `phase` is `cycle` or `reactive`, used as a filename infix (`selection-<phase>.json`) and a branch-slug prefix. Nothing else about them changes.
- Produces: `reactive_main()` — the whole S3a pass. Returns 0 always; a failed lens costs its own findings, never the night.
- Produces: `$LOG_DIR/findings-reactive-<task>.json` per lens, and `$LOG_DIR/reactive-summary.tsv` (`task<TAB>findings`) for the digest.
- Consumed by: `tier2_main` (this task), Task 5's summary.

- [ ] **Step 1: Give `tier2_audit_shard` an explicit scope**

In `lib/tier2.sh`, change the head of `tier2_audit_shard`:

```bash
# Phase A — audit, physically read-only (dontAsk + no Edit/Write in the allow-list).
# ONE SCOPE per session. Called two ways, deliberately by the SAME function:
#   * the shard fan-out passes a shard name and `shards scope` output (365k LOC, spec 5)
#   * the reactive pass passes "reactive-<task>" and an explicit merged-file list (spec 10)
# Scope arrives as an ARGUMENT rather than being looked up here, because those are the only two
# things that differ between the callers, and a second copy of the retry / session-limit /
# corrective-re-prompt logic is the last thing this file needs.
# Writes $LOG_DIR/findings-<name>.json on success. Never returns nonzero for a single failure --
# a dead scope must not kill the tier.
tier2_audit_shard() {
    local name=$1 scope=$2 task=$3 prompt attempt
    prompt="$(render_prompt "$NS_ROOT/prompts/audit-$task.md" \
        "shard=$name" "scope=$scope" \
        "protect_globs=$NS_PROTECT_GLOBS" "ponytail_mode=$NS_AGENT_PONYTAIL_MODE")"
```

Then replace every remaining `$shard` in the body with `$name`. The call site in `tier2_audit_all` becomes:

```bash
        ns_jobs_wait "$conc"
        tier2_audit_shard "$shard" "$(ns_jac shards scope "$shard" "$CONFIG")" "$task" &
```

where `$task` is Plan 2's cycle task for tonight.

- [ ] **Step 2: Phase-tag select and apply**

In `tier2_select`, take a phase and use it in the filenames:

```bash
tier2_select() {
    local phase=$1
    ns_jac selector select "$CONFIG" "$LEDGER" "$STATE" "$(ns_remaining_min)" "$REPO" \
        < "$LOG_DIR/findings-$phase.json" > "$LOG_DIR/selection-$phase.json"
```

and in `tier2_apply`, prefix the branch slug so a reactive theme and a cycle theme touching the same file cannot collide on a branch name:

```bash
tier2_apply() {
    local phase=$1 slug branch theme_file prompt remaining attempt got_report limit_hit
    ...
    ns_jac selector split "$LOG_DIR/selection-$phase.json" "$LOG_DIR" | while IFS= read -r slug; do
        theme_file="$LOG_DIR/theme-$slug.json"
        branch="nightshift/$NS_DATE/$phase-$slug"
```

Update `tier2_audit_all` to write `$LOG_DIR/findings-cycle.json` instead of `findings.json`, and `tier2_main`'s calls to `tier2_select cycle` / `tier2_apply cycle`.

- [ ] **Step 3: Write `reactive_main`**

Append to `lib/reactive.sh`:

```bash
# S3a — all four task lenses over the files that merged upstream today (design spec section 10).
# Runs BEFORE the cycle task so fresh merges are cleaned the same night. Priority order for a
# night is: PR inventory (S1.6) > this > carry-over > tonight's cycle task.
#
# COST, stated plainly because four LLM sessions a night is the most expensive thing this plan
# adds: the justification is that the scope is a handful of files, not an 87k-LOC shard. The
# moment that stops being true the justification is gone, so both ends are guarded --
# zero merged files costs zero sessions, and a huge merge day is truncated rather than pursued.
reactive_main() {
    local scope n_files conc task task_list rc=0

    # A quiet day must cost NOTHING: no session, no audit-*.json, no ns_fail row, one log line.
    # `-s`, not `-f`: reactive_poll writes an empty file for a real but file-less merge day.
    if [ ! -s "$LOG_DIR/reactive-files.txt" ]; then
        ns_log S3a "no upstream merges to clean tonight — reactive pass skipped (0 sessions)"
        return 0
    fi
    n_files="$(wc -l < "$LOG_DIR/reactive-files.txt" | tr -d ' ')"

    # ponytail: CEILING. An audit session cannot usefully read an unbounded file list, and a
    #           200-file merge day is a release, not a janitorial opportunity. Above the cap the
    #           pass audits the first files_per_theme*4 paths (sorted, so it is deterministic and
    #           reproducible) and SAYS SO in the digest, rather than silently truncating or
    #           silently spending four max-turn sessions on a list it cannot hold.
    #           Upgrade path: shard the merged file set the way the repo is sharded, reusing
    #           tier2_audit_all's fan-out with per-chunk scopes. Not built: it has never fired.
    local cap=$(( NS_BUDGETS_FILES_PER_THEME * 4 ))
    if [ "$n_files" -gt "$cap" ]; then
        ns_warn "reactive pass: $n_files merged files exceeds the $cap-file ceiling — auditing the first $cap"
        scope="$(head -"$cap" "$LOG_DIR/reactive-files.txt" | tr '\n' ' ')"
    else
        scope="$(tr '\n' ' ' < "$LOG_DIR/reactive-files.txt")"
    fi

    # Same materialize-and-check discipline as tier2_audit_all: `for x in $(reader)` does not fire
    # set -e, so a broken reader would run ZERO lenses and look exactly like a quiet day -- which
    # is the one thing this whole task is built to distinguish.
    task_list="$(ns_jac tasks list "$CONFIG")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$task_list" ]; then
        ns_fail "S3a reactive" "could not read the task list from $CONFIG (rc=$rc) — reactive pass skipped"
        return 0
    fi

    conc="${NS_SHARDS_CONCURRENCY:-2}"
    ns_log S3a "reactive pass over $n_files merged file(s), $(printf '%s' "$task_list" | wc -w | tr -d ' ') lenses"
    for task in $task_list; do
        if [ "$(ns_remaining_min)" -lt $(( NS_BUDGETS_AUDIT_TIMEOUT_MIN + NS_BUDGETS_APPLY_TIMEOUT_MIN )) ]; then
            ns_warn "clock too short to schedule more reactive lenses — stopping at $task"
            break
        fi
        ns_jobs_wait "$conc"
        tier2_audit_shard "reactive-$task" "$scope" "$task" &
    done
    wait

    # Collect. Space-joined string, not a bash array: under set -u bash 3.2 aborts on ${#arr[@]}
    # and "${arr[@]}" when the array is EMPTY, and "every lens failed" is exactly the case this
    # has to survive.
    local found="" n_found=0
    : > "$LOG_DIR/reactive-summary.tsv"
    for task in $task_list; do
        if [ -s "$LOG_DIR/findings-reactive-$task.json" ]; then
            found="$found $LOG_DIR/findings-reactive-$task.json"
            n_found=$(( n_found + 1 ))
            printf '%s\t%s\n' "$task" \
                "$(ns_jac parse_result len < "$LOG_DIR/findings-reactive-$task.json" || echo 0)" \
                >> "$LOG_DIR/reactive-summary.tsv"
        else
            printf '%s\tFAILED\n' "$task" >> "$LOG_DIR/reactive-summary.tsv"
        fi
    done
    if [ "$n_found" -eq 0 ]; then
        ns_fail "S3a reactive" "every lens failed or produced nothing over $n_files merged files"
        return 0
    fi

    # shellcheck disable=SC2086  # deliberate word-split into one arg per lens findings file
    if ! ns_jac parse_result merge $found > "$LOG_DIR/findings-reactive.json"; then
        ns_fail "S3a reactive" "merge of $n_found lens findings failed — reactive pass contributes nothing"
        rm -f "$LOG_DIR/findings-reactive.json"
        return 0
    fi
    ns_log S3a "merged $n_found lens result(s) into $(ns_jac parse_result len < "$LOG_DIR/findings-reactive.json" || echo 0) findings"
    tier2_select reactive
    tier2_apply reactive
    return 0
}
```

- [ ] **Step 4: Call it from `tier2_main`, before the cycle task**

```bash
tier2_main() {
    local remaining; remaining="$(ns_remaining_min)"
    if [ "$remaining" -lt $(( NS_BUDGETS_AUDIT_TIMEOUT_MIN + NS_BUDGETS_APPLY_TIMEOUT_MIN )) ]; then
        ns_warn "no clock left for the agentic tier (${remaining}m remaining) — skipping S3"
        return 0
    fi

    # S3a BEFORE S3b: fresh upstream merges are cleaned the same night they land (spec section
    # 10), and the clock is what gives them priority -- they simply spend it first. A quiet day
    # returns immediately having spent nothing.
    reactive_main

    tier2_audit_all || return 0        # no usable findings skips the cycle task; tier-1 still ships
    tier2_select cycle
    tier2_apply cycle
    dataset_record_night
}
```

- [ ] **Step 5: Prove the quiet day costs nothing**

The single most important behavioural property of this task, and the easiest one to lose.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
Q="$(mktemp -d)"; mkdir -p "$Q"
printf '#!/usr/bin/env bash\necho "CLAUDE WAS CALLED" >> /tmp/ns-quiet-violation.log\n' > "$Q/claude"
chmod +x "$Q/claude"; rm -f /tmp/ns-quiet-violation.log
: > "$Q/reactive-files.txt"                 # a poll that found nothing
NS_ROOT="$PWD" bash -c '. lib/common.sh; ns_load_config; . lib/tier2.sh; . lib/reactive.sh
  LOG_DIR="'"$Q"'"; NS_PATHS_CLAUDE="'"$Q"'/claude"; date +%s > "$LOG_DIR/start_epoch"
  reactive_main; echo "rc=$?"'
ls "$Q" | grep -c 'audit-\|findings-' || echo "0 audit artifacts"
[ -f /tmp/ns-quiet-violation.log ] && echo "BUG: a quiet day started a session" || echo "quiet day: 0 sessions"
[ -f "$Q/failed.tsv" ] && echo "BUG: a quiet day wrote a failure row" || echo "quiet day: 0 failure rows"
```

Expected: `rc=0`, `0 audit artifacts`, `quiet day: 0 sessions`, `quiet day: 0 failure rows`, and exactly one `[S3a]` line in the output.

- [ ] **Step 6: Prove the busy day fans out at the right concurrency**

Same stub technique as Plan 1 Task 3 Step 12, so no Opus tokens are spent:

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
B="$(mktemp -d)"; cat > "$B/claude" <<'EOF'
#!/usr/bin/env bash
echo "$(date +%s) START $$" >> /tmp/ns-reactive-conc.log
sleep 8
echo '{"result":"```json\n[]\n```"}'
echo "$(date +%s) END $$" >> /tmp/ns-reactive-conc.log
EOF
chmod +x "$B/claude"; rm -f /tmp/ns-reactive-conc.log
printf 'jac/jaclang/cli/a.jac\njac/jaclang/cli/b.jac\n' > "$B/reactive-files.txt"
NS_ROOT="$PWD" bash -c '. lib/common.sh; ns_load_config; . lib/tier2.sh; . lib/reactive.sh
  LOG_DIR="'"$B"'"; NS_PATHS_CLAUDE="'"$B"'/claude"; date +%s > "$LOG_DIR/start_epoch"
  reactive_main' || true
awk '/START/{n++; if(n>max)max=n} /END/{n--} END{print "peak concurrency:", max+0}' /tmp/ns-reactive-conc.log
wc -l < "$B/reactive-summary.tsv"
```

Expected: `peak concurrency: 2` and `4` summary rows (one per lens). A peak of 4 means `ns_jobs_wait` is not being reached — check that the loop is not inside a subshell created by a pipe, since `jobs -rp` cannot see children across one.

- [ ] **Step 7: Add harness section 14**

```bash
echo "== 14. reactive pass: a quiet day spends nothing, and never looks like a failure =="
# Four LLM sessions a night is the most expensive thing in Plan 4, justified ONLY by the scope
# being a handful of merged files. The guard that keeps a quiet day free is one `-s` test, and
# losing it would be invisible except on the bill. Driven with a claude stub that records any
# invocation; nothing here can reach a real session even if the guard is broken.
Q="$T/quiet"; mkdir -p "$Q"
printf '#!/usr/bin/env bash\ntouch "%s/CLAUDE_WAS_CALLED"\n' "$Q" > "$Q/claude"; chmod +x "$Q/claude"
: > "$Q/reactive-files.txt"
(
    . "$NS_ROOT/lib/common.sh"; ns_load_config; . "$NS_ROOT/lib/tier2.sh"; . "$NS_ROOT/lib/reactive.sh"
    LOG_DIR="$Q"; NS_PATHS_CLAUDE="$Q/claude"; date +%s > "$Q/start_epoch"; reactive_main
) > "$Q/out.txt" 2>&1 || fail "reactive_main returned nonzero on a quiet day -- it must never fail the night"
[ -e "$Q/CLAUDE_WAS_CALLED" ] && fail "a quiet day started an audit session; the reactive pass is not free"
[ -e "$Q/failed.tsv" ] && fail "a quiet day wrote a failure row; 'nothing merged' is not a failure"
case "$(ls "$Q" | grep -c '^findings-\|^audit-' || true)" in
    0) : ;;
    *) fail "a quiet day left audit artifacts behind: $(ls "$Q" | grep '^findings-\|^audit-' | tr '\n' ' ')" ;;
esac
# ...and it must still SAY something, or a skipped pass is indistinguishable from a missing one
grep -q 'S3a' "$Q/out.txt" || fail "a quiet day logged nothing at all; a skipped pass must be visible"
echo "quiet day: 0 sessions, 0 failure rows, 0 artifacts, 1 log line"
```

- [ ] **Step 8: Run the harness and commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add lib/tier2.sh lib/reactive.sh bin/test-harness.sh
git commit -m "Run all four lenses over the day's merged files, before the cycle task

Spec section 10. The union of files from upstream PRs merged since the last
successful poll becomes an audit scope, and all four task lenses run over it --
cheap only because the scope is a handful of files rather than an 87k-LOC shard.
All authors, nightshift's own merged PRs included. Runs before the cycle task so
an active repo day gets same-night cleanup; the clock is what gives it priority,
since it simply spends it first.

No second audit driver: tier2_audit_shard now takes its scope as an argument, so
the shard fan-out and the reactive pass are the same function with different
scope strings and one copy of the retry / session-limit / corrective-re-prompt
logic. tier2_select and tier2_apply take a phase, so a reactive theme and a
cycle theme touching the same file cannot collide on a branch name.

Both ends of the cost are guarded and both are tested: zero merged files means
zero sessions, zero artifacts, zero failure rows and one log line, and a merge
day above 4x files_per_theme is truncated with a warning rather than pursued."
```

---

### Task 5: Assemble the v2 summary

Everything the digest reports now exists on disk. This task turns it into one JSON document; Task 6 renders it. Splitting them is what makes both testable — the assembly has fixtures and no formatting, the rendering has formatting and no I/O.

**Files:**
- Modify: `scripts/sendmail.jac` (`summarize`, helpers, tests)

**Interfaces:**
- Produces: `summarize(...)` gaining `clock`, `tasks`, `reactive`, `prs`, `inventory`, `deferred`. Existing keys are unchanged, so `plain_body` keeps working through this task.
- Produces: `read_tsv(path) -> list[list[str]]` and `read_jsonl(path) -> list[dict]` in `sendmail.jac` — both return `[]` for a missing file.
- Consumed by: Task 6.

- [ ] **Step 1: Write the failing test**

```jac
test "summarize renders a COMPLETE skeleton from an empty log dir" {
    # The digest must render on the worst night there is -- one where the stage that writes its
    # inputs never ran. Every section is present and empty, never absent: an absent key is a
    # KeyError in html_body, i.e. the digest failing exactly when it matters most.
    import tempfile;
    empty: str = tempfile.mkdtemp();
    cfg: dict = {"repo": {"fork": "me/jaseci"}, "budgets": {"wallclock_min": 480}};
    s: dict = summarize(empty, tempfile.mkdtemp(), "2026-07-30", cfg);
    for key in ["date", "verdict", "branches", "failed", "tasks", "reactive", "prs",
                "inventory", "deferred", "clock", "warnings", "fatal_reason", "error_stage"] {
        assert key in s;
    }
    assert as_list(s["tasks"]) == [];
    assert as_dict(s["clock"])["window_min"] == 480;
    assert as_dict(s["reactive"])["files"] == 0;
}

test "summarize folds the reactive tally, the PR rows and the inventory" {
    import tempfile;
    log_dir: str = tempfile.mkdtemp();
    with open(os.path.join(log_dir, "reactive-summary.tsv"), "w") as f {
        f.write("dead-code\t3\nabstraction\t0\nmaintenance\tFAILED\ncoverage\t1\n");
    }
    with open(os.path.join(log_dir, "reactive-files.txt"), "w") as f {
        f.write("jac/jaclang/cli/a.jac\njac/jaclang/scale/b.jac\n");
    }
    with open(os.path.join(log_dir, "prs.jsonl"), "w") as f {
        f.write("{\"number\": 7301, \"title\": \"remove dead pipe\", \"task\": \"dead-code\","
                + " \"url\": \"https://github.com/jaseci-labs/jac/pull/7301\","
                + " \"mirror\": \"green\", \"ci\": \"pending\", \"attempts\": 0}\n");
    }
    with open(os.path.join(log_dir, "pr-inventory.jsonl"), "w") as f {
        f.write("{\"number\": 7288, \"action\": \"rebased\", \"note\": \"\"}\n");
        f.write("{\"number\": 7290, \"action\": \"conflicted\", \"note\": \"jac/jaclang/cli/x.jac\"}\n");
    }
    cfg: dict = {"repo": {"fork": "me/jaseci"}, "budgets": {"wallclock_min": 480}};
    s: dict = summarize(log_dir, tempfile.mkdtemp(), "2026-07-30", cfg);
    react: dict = as_dict(s["reactive"]);
    assert react["files"] == 2;
    assert as_dict(react["lenses"])["dead-code"] == "3";
    # a FAILED lens is preserved verbatim, NOT collapsed to 0 -- "found nothing" and "did not run"
    # are the two things this whole plan refuses to conflate
    assert as_dict(react["lenses"])["maintenance"] == "FAILED";
    assert as_int(as_dict(as_list(s["prs"])[0])["number"]) == 7301;
    assert len(as_list(s["inventory"])) == 2;
    assert as_dict(as_list(s["inventory"])[1])["action"] == "conflicted";
}
```

- [ ] **Step 2: Run it, expect failure**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/sendmail.jac
```

Expected: FAIL — `tasks` / `reactive` / `prs` are not in the summary.

- [ ] **Step 3: Implement the readers and the new sections**

Add next to `read_lines` in `scripts/sendmail.jac`:

```jac
"""Both readers return [] for a missing file ON PURPOSE. The digest is the one thing that must
render when the stage that writes its input never ran, so absence is normal input here, not an
error. Unparseable LINES are skipped individually for the same reason a bad report-*.json is
(read_json_files above): one truncated write must not cost the whole digest."""
def read_jsonl(path: str) -> list[dict] {
    out: list[dict] = [];
    for line in read_lines(path) {
        try {
            out.append(parse_obj(line));
        } except Exception {
            eprint("sendmail: skipping unparseable jsonl line in " + path);
        }
    }
    return out;
}

def read_tsv(path: str) -> list[list[str]] {
    return [line.split("\t") for line in read_lines(path)];
}

"""Per-task rollup, derived entirely from files S3 already writes -- no new writer anywhere in
the pipeline. findings-*.json are the audit outputs (one per shard and one per reactive lens),
selection-*.json record what was packed. ponytail: a derivation, not a schema."""
def task_sections(log_dir: str) -> list[dict] {
    sections: list[dict] = [];
    for path in glob_paths(log_dir, "selection-*.json"):
        phase: str = os.path.basename(path)[len("selection-"):-len(".json")];
        sel: dict = {};
        with open(path, "r") as f {
            text: str = f.read();
        }
        if text.strip() {
            try {
                sel = parse_obj(text);
            } except Exception {
                eprint("sendmail: unparseable " + path);
            }
        }
        themes: list = as_list(sel.get("themes", []));
        sections.append({
            "phase": phase,
            "scopes": [os.path.basename(p)[len("findings-"):-len(".json")]
                       for p in glob_paths(log_dir, "findings-*.json")],
            "selected": len(themes),
            "deferred": len(as_list(sel.get("dropped", []))),
            "themes": [as_dict(t) for t in themes],
        });
    return sections;
}
```

Then in `summarize`, before the return:

```jac
    lenses: dict = {};
    for row in read_tsv(os.path.join(log_dir, "reactive-summary.tsv")) {
        if len(row) >= 2 {
            lenses[row[0]] = row[1];
        }
    }
    window: int = as_int(as_dict(cfg.get("budgets", {})).get("wallclock_min", 0));
```

and extend the returned dict:

```jac
        "clock": {"window_min": window, "consumed_min": runtime,
                  "remaining_min": window - runtime},
        "tasks": task_sections(log_dir),
        "reactive": {
            "files": len(read_lines(os.path.join(log_dir, "reactive-files.txt"))),
            "lenses": lenses,
        },
        "prs": read_jsonl(os.path.join(log_dir, "prs.jsonl")),
        "inventory": read_jsonl(os.path.join(log_dir, "pr-inventory.jsonl")),
        "deferred": [d for d in read_jsonl(os.path.join(log_dir, "deferred.jsonl"))],
```

`deferred.jsonl` does not exist yet. `tier2_select` already upserts deferred findings into the ledger; make it tee them so the digest does not have to re-scan the ledger. In `lib/tier2.sh`'s `tier2_select`, inside the `dropped` loop:

```bash
            over-theme-budget|over-night-budget|no-clock-left)
                printf '{"fingerprint":"%s","file":"%s","reason":"%s","phase":"%s"}\n' "$fp" "$file" "$reason" "$phase" \
                    >> "$LOG_DIR/deferred.jsonl"
                printf '{"fingerprint":"%s","file":"%s","rule":"unknown","summary":"deferred by selector","status":"deferred"}\n' "$fp" "$file" \
                    | ns_jac ledger upsert "$LEDGER" >/dev/null ;;
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/sendmail.jac
```

Expected: PASS, all tests.

- [ ] **Step 5: Run `summarize` against a real past night**

Fixtures prove the shape; a real night proves the conventions.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
jac run scripts/sendmail.jac summarize logs/2026-07-27 work/drafts/drafts 2026-07-27 config/nightshift.toml \
  | jac run scripts/parse_result.jac field date
jac run scripts/sendmail.jac summarize logs/2026-07-27 work/drafts/drafts 2026-07-27 config/nightshift.toml \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print({k: (len(v) if isinstance(v,(list,dict)) else v) for k,v in d.items() if k in ("tasks","prs","inventory","deferred","reactive","clock","branches","failed")})'
```

Expected: a complete dict with no exception. The `python3 -c` here is a throwaway shell probe, not a file — the no-Python-files rule is about what lives in the repo.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add scripts/sendmail.jac lib/tier2.sh
git commit -m "Assemble the v2 run summary: tasks, reactive tally, PRs, inventory, deferred

Splits assembly from rendering so both are testable: this half has fixtures and
no formatting, Task 6's half has formatting and no I/O.

Every section is DERIVED from files the pipeline already writes -- selection-*,
findings-*, reactive-summary.tsv, and Plan 3's prs.jsonl / pr-inventory.jsonl --
so nothing new has to be maintained in lockstep. Every reader returns [] for a
missing file, because the digest has to render on exactly the night where the
stage that writes its input never ran; a test asserts the complete skeleton
comes back from an empty log dir, since an absent key is a KeyError in the
renderer, i.e. the digest failing precisely when it matters most.

A FAILED reactive lens is carried through verbatim rather than collapsed to 0."
```

---

### Task 6: The digest — `multipart/alternative`, HTML plus plain text

Only now, on a transport with a proven receipt and a summary with real content.

`scripts/sendmail.jac` already builds a `MIMEMultipart("alternative")` with a text part and an HTML part that is the text part in `<pre>`. This task replaces the `<pre>` with a real document and extends the text part to match. It does not add a templating dependency, and it does not grow a renderer abstraction: there is one output format and `email.mime` is stdlib.

**Files:**
- Modify: `scripts/sendmail.jac` (`esc`, `html_body`, `plain_body`, `build_message`, tests)

**Interfaces:**
- Produces: `esc(s: any) -> str` — HTML-escapes any value.
- Produces: `html_body(summary: dict) -> str` — the full HTML document.
- Changed: `build_message` attaches `plain_body` as `text/plain` and `html_body` as `text/html`, in that order (RFC 2046: the last part is the most-preferred alternative).
- Consumed by: `lib/email.sh`, unchanged.

- [ ] **Step 1: Write the failing tests**

```jac
test "the html digest carries every section and escapes agent-authored text" {
    summary: dict = {
        "date": "2026-07-30",
        "verdict": "2 branch(es) ready · 1 failed",
        "clock": {"window_min": 480, "consumed_min": 312, "remaining_min": 168},
        "error_stage": "S4", "fatal_reason": "mirror job 'compiler' collected 0 items",
        "branches": [{"theme": "dead render path", "branch": "nightshift/2026-07-30/cycle-dead",
                      "files": 3, "added": 4, "removed": 212, "tests": "green", "risk": "low",
                      "url": "https://github.com/x", "draft_text": "# refactor: kill dead code"}],
        "tasks": [{"phase": "reactive", "scopes": ["reactive-dead-code"], "selected": 1,
                   "deferred": 2,
                   "themes": [{"name": "dead render path",
                               "summary": "<script>alert(1)</script> & a real finding"}]}],
        "reactive": {"files": 6, "lenses": {"dead-code": "3", "maintenance": "FAILED"}},
        "prs": [{"number": 7301, "title": "remove dead pipe <b>", "task": "dead-code",
                 "url": "https://github.com/jaseci-labs/jac/pull/7301",
                 "mirror": "green", "ci": "pending", "attempts": 0}],
        "inventory": [{"number": 7288, "action": "conflicted", "note": "jac/jaclang/cli/x.jac"}],
        "deferred": [{"fingerprint": "abc", "file": "jac/jaclang/scale/z.jac",
                      "reason": "over-night-budget", "phase": "cycle"}],
        "failed": [{"what": "theme y", "reason": "tests red"}],
        "suspected_bugs": [], "warnings": [], "runtime_min": 312, "turns": 61, "cost_usd": 0,
    };
    html: str = html_body(summary);
    # the fatal reason is the FIRST thing an operator should see
    assert html.index("mirror job") < html.index("7301");
    # every section from spec 14
    for needle in ["312", "reactive-dead-code", "7301", "pending", "7288", "conflicted",
                   "over-night-budget", "tests red", "+4", "-212"] {
        assert needle in html;
    }
    # ESCAPED. Finding summaries are agent-authored text going into an HTML document.
    assert "<script>alert(1)</script>" not in html;
    assert "&lt;script&gt;" in html;
    assert "remove dead pipe &lt;b&gt;" in html;
    # ...but the harness's own markup survives
    assert "<table" in html and "</html>" in html;
}

test "the plain-text part is a real fallback, not a stub" {
    summary: dict = {
        "date": "2026-07-30", "verdict": "1 ready",
        "clock": {"window_min": 480, "consumed_min": 42, "remaining_min": 438},
        "branches": [], "tasks": [], "failed": [], "suspected_bugs": [], "warnings": [],
        "reactive": {"files": 6, "lenses": {"dead-code": "3"}},
        "prs": [{"number": 7301, "title": "t", "task": "dead-code", "url": "u",
                 "mirror": "green", "ci": "pending", "attempts": 0}],
        "inventory": [], "deferred": [], "runtime_min": 42, "turns": 5, "cost_usd": 0,
        "error_stage": None, "fatal_reason": None,
    };
    text: str = plain_body(summary);
    # a reader on a text-only client must get the same FACTS, not a "view in HTML" apology
    assert "7301" in text and "pending" in text;
    assert "6" in text;                       # the reactive file count
    assert "<" not in text;                   # no markup leaked into the text part
}

test "build_message is multipart/alternative, text first then html" {
    summary: dict = {"date": "2026-07-30", "verdict": "v", "branches": [], "failed": [],
                     "tasks": [], "reactive": {"files": 0, "lenses": {}}, "prs": [],
                     "inventory": [], "deferred": [], "suspected_bugs": [], "warnings": [],
                     "clock": {"window_min": 480, "consumed_min": 1, "remaining_min": 479},
                     "runtime_min": 1, "turns": 0, "cost_usd": 0,
                     "error_stage": None, "fatal_reason": None};
    os.environ["SMTP_USER"] = "probe@example.com";
    msg: any = build_message(summary, {"email": {"to": "d@e.f"}});
    parts: list = msg.get_payload();
    assert msg.get_content_subtype() == "alternative";
    # RFC 2046: the LAST alternative is the most preferred, so html must come second
    assert parts[0].get_content_type() == "text/plain";
    assert parts[1].get_content_type() == "text/html";
    assert msg["From"] == "probe@example.com";
}
```

- [ ] **Step 2: Run them, expect failure**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/sendmail.jac
```

Expected: FAIL — `html_body` is not defined.

- [ ] **Step 3: Implement `esc` and `html_body`**

```jac
import from html { escape as html_escape }
```

```jac
"""Everything interpolated into the digest that did not come from this file is agent-authored or
upstream-authored text -- finding summaries, PR titles, fatal reasons, file paths. It goes into
an HTML document that a human opens in a mail client. Escape it once, here, and never build a
string with raw interpolation anywhere in html_body."""
def esc(v: any) -> str {
    return html_escape(str(v), quote=True);
}

"""The digest (design spec section 14). Section order is triage order: what went wrong, then what
shipped, then what is in flight, then what was left.

ponytail: this is string concatenation in Jac, not a template engine and not a "renderer"
          abstraction. There is exactly ONE output format and email.mime is stdlib. A second
          format (a Slack blocks payload was floated) would justify splitting the section
          builders out; one does not.
Inline styles, not a <style> block: Gmail strips or rewrites <style> in some clients and every
mail-client CSS guide says the same thing. Nothing here needs more than borders and a monospace
font, so this is the cheap correct choice rather than a compromise."""
def html_body(summary: dict) -> str {
    clock: dict = as_dict(summary.get("clock", {}));
    mono: str = "font-family:ui-monospace,Menlo,monospace;font-size:13px";
    td: str = "border:1px solid #ddd;padding:4px 8px";
    out: list[str] = [
        "<html><body style=\"" + mono + ";color:#222\">",
        "<h2 style=\"margin:0 0 4px\">Nightshift " + esc(summary.get("date", "?")) + "</h2>",
        "<p style=\"margin:0 0 12px\">" + esc(summary.get("verdict", "")) + "<br>"
        + "clock: " + esc(clock.get("consumed_min", "?")) + " of "
        + esc(clock.get("window_min", "?")) + " min consumed ("
        + esc(clock.get("remaining_min", "?")) + " left) · turns "
        + esc(summary.get("turns", "?")) + " · $" + esc(summary.get("cost_usd", 0)) + "</p>",
    ];

    # 1. WHY the night died, first, in red. 13 ns_die sites share one stage name.
    fatal: any = summary.get("fatal_reason");
    if fatal is not None and str(fatal) != "" {
        out.append("<p style=\"background:#fee;border-left:4px solid #c00;padding:8px\">"
                   + "<b>FATAL (" + esc(summary.get("error_stage", "?")) + ")</b><br>"
                   + esc(fatal) + "</p>");
    }

    # 2. per-task: what was audited, what was found, selected, deferred, with summaries INLINE
    for section in as_list(summary.get("tasks", [])) {
        s: dict = as_dict(section);
        out.append("<h3>" + esc(s.get("phase", "?")) + " — " + esc(s.get("selected", 0))
                   + " selected, " + esc(s.get("deferred", 0)) + " deferred</h3>");
        out.append("<p>audited: " + esc(", ".join([str(x) for x in as_list(s.get("scopes", []))]))
                   + "</p><ul>");
        for theme in as_list(s.get("themes", [])) {
            t: dict = as_dict(theme);
            out.append("<li><b>" + esc(t.get("name", "?")) + "</b> — "
                       + esc(t.get("summary", "")) + "</li>");
        }
        out.append("</ul>");
    }

    # 3. reactive pass. A FAILED lens must read differently from a lens that found nothing.
    react: dict = as_dict(summary.get("reactive", {}));
    out.append("<h3>Reactive pass — " + esc(react.get("files", 0)) + " merged file(s)</h3><ul>");
    for (lens, n) in as_dict(react.get("lenses", {})).items() {
        out.append("<li>" + esc(lens) + ": " + esc(n) + "</li>");
    }
    out.append("</ul>");

    # 4. PR table. Diffstats inline so triage needs no clicks (spec 14).
    out.append("<h3>Pull requests</h3><table style=\"border-collapse:collapse\">"
               + "<tr><th style=\"" + td + "\">#</th><th style=\"" + td + "\">title</th>"
               + "<th style=\"" + td + "\">task</th><th style=\"" + td + "\">mirror</th>"
               + "<th style=\"" + td + "\">CI</th><th style=\"" + td + "\">attempts</th></tr>");
    for pr in as_list(summary.get("prs", [])) {
        p: dict = as_dict(pr);
        out.append("<tr><td style=\"" + td + "\"><a href=\"" + esc(p.get("url", "")) + "\">"
                   + esc(p.get("number", "?")) + "</a></td>"
                   + "<td style=\"" + td + "\">" + esc(p.get("title", "")) + "</td>"
                   + "<td style=\"" + td + "\">" + esc(p.get("task", "")) + "</td>"
                   + "<td style=\"" + td + "\">" + esc(p.get("mirror", "?")) + "</td>"
                   + "<td style=\"" + td + "\">" + esc(p.get("ci", "?")) + "</td>"
                   + "<td style=\"" + td + "\">" + esc(p.get("attempts", 0)) + "</td></tr>");
    }
    out.append("</table>");

    # 5. branches shipped tonight, with their diffstats
    out.append("<h3>Branches</h3><ul>");
    for b in as_list(summary.get("branches", [])) {
        c: dict = as_dict(b);
        out.append("<li><b>" + esc(c.get("theme", "?")) + "</b> — "
                   + esc(c.get("files", "?")) + " file(s), <b>+" + esc(c.get("added", 0))
                   + " -" + esc(c.get("removed", 0)) + "</b>, tests: " + esc(c.get("tests", "?"))
                   + ", risk: " + esc(c.get("risk", "?"))
                   + "<br><a href=\"" + esc(c.get("url", "")) + "\">"
                   + esc(c.get("branch", "?")) + "</a></li>");
    }
    out.append("</ul>");

    # 6. PR inventory (S1.6): rebased / updated / conflicted
    out.append("<h3>PR inventory</h3><ul>");
    for item in as_list(summary.get("inventory", [])) {
        i: dict = as_dict(item);
        out.append("<li>#" + esc(i.get("number", "?")) + " — <b>" + esc(i.get("action", "?"))
                   + "</b> " + esc(i.get("note", "")) + "</li>");
    }
    out.append("</ul>");

    # 7. failures and deferred work
    out.append("<h3>Failures</h3><ul>");
    for item in as_list(summary.get("failed", [])) {
        d: dict = as_dict(item);
        out.append("<li>" + esc(d.get("what", "?")) + ": " + esc(d.get("reason", "")) + "</li>");
    }
    out.append("</ul><h3>Deferred to a future night</h3><ul>");
    for item in as_list(summary.get("deferred", [])) {
        d2: dict = as_dict(item);
        out.append("<li>" + esc(d2.get("file", "?")) + " — " + esc(d2.get("reason", ""))
                   + " (" + esc(d2.get("phase", "?")) + ")</li>");
    }
    out.append("</ul>");

    for w in as_list(summary.get("warnings", [])) {
        out.append("<p style=\"color:#a60\">WARNING: " + esc(w) + "</p>");
    }

    # 8. full drafts last: the longest content, and the part a reader scrolls to deliberately
    for b in as_list(summary.get("branches", [])) {
        c2: dict = as_dict(b);
        if c2.get("draft_text", "") {
            out.append("<h3>draft: " + esc(c2.get("branch", "?")) + "</h3><pre style=\""
                       + td + ";white-space:pre-wrap\">" + esc(c2["draft_text"]) + "</pre>");
        }
    }
    out.append("</body></html>");
    return "\n".join(out);
}
```

- [ ] **Step 4: Extend `plain_body` so the fallback carries the same facts**

The text part is not a courtesy. Add after the branch cards, before the drafts:

```jac
    react2: dict = as_dict(summary.get("reactive", {}));
    lines.append("REACTIVE: " + str(react2.get("files", 0)) + " merged file(s)");
    for (lens, n) in as_dict(react2.get("lenses", {})).items() {
        lines.append("  " + str(lens) + ": " + str(n));
    }
    lines.append("");
    prs: list = as_list(summary.get("prs", []));
    if prs {
        lines.append("PULL REQUESTS:");
        for pr in prs {
            p2: dict = as_dict(pr);
            lines.append("  #" + str(p2.get("number", "?")) + " " + str(p2.get("title", ""))
                         + " [" + str(p2.get("task", "")) + "] mirror=" + str(p2.get("mirror", "?"))
                         + " ci=" + str(p2.get("ci", "?")) + " attempts=" + str(p2.get("attempts", 0)));
            lines.append("    " + str(p2.get("url", "")));
        }
        lines.append("");
    }
    inv: list = as_list(summary.get("inventory", []));
    if inv {
        lines.append("PR INVENTORY:");
        for item in inv {
            i2: dict = as_dict(item);
            lines.append("  #" + str(i2.get("number", "?")) + " " + str(i2.get("action", "?"))
                         + " " + str(i2.get("note", "")));
        }
        lines.append("");
    }
    deferred: list = as_list(summary.get("deferred", []));
    if deferred {
        lines.append("DEFERRED TO A FUTURE NIGHT:");
        for item in deferred {
            d3: dict = as_dict(item);
            lines.append("  " + str(d3.get("file", "?")) + " — " + str(d3.get("reason", "")));
        }
        lines.append("");
    }
```

Also add the clock line to the runtime footer:

```jac
    clock2: dict = as_dict(summary.get("clock", {}));
    lines.append("clock: " + str(clock2.get("consumed_min", "?")) + " of "
                 + str(clock2.get("window_min", "?")) + " min · turns: "
                 + str(summary.get("turns", "?")) + " · cost: $" + str(summary.get("cost_usd", "0")));
```

- [ ] **Step 5: Swap the HTML part in `build_message`**

```jac
    text: str = plain_body(summary);
    # text FIRST, html SECOND: RFC 2046 says the last alternative is the most preferred, so a
    # client that understands both shows the html and a text-only client falls back cleanly.
    msg.attach(MIMEText(text, "plain"));
    msg.attach(MIMEText(html_body(summary), "html"));
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && rm -rf .jac && jac test scripts/sendmail.jac
```

Expected: PASS, all tests.

- [ ] **Step 7: Mutation-test the escaping**

The escaping guard protects the one place where agent-authored text reaches a rendered document. Prove it fails when removed.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
cp scripts/sendmail.jac /tmp/sm.bak
perl -0pi -e 's/return html_escape\(str\(v\), quote=True\);/return str(v);/' scripts/sendmail.jac
rm -rf .jac && jac test scripts/sendmail.jac > /dev/null 2>&1 \
  && echo "BUG: the escaping test does not actually check escaping" \
  || echo "mutation caught: escaping is real"
cp /tmp/sm.bak scripts/sendmail.jac && rm -rf .jac && jac test scripts/sendmail.jac | tail -2
```

Expected: `mutation caught: escaping is real`, then PASS.

- [ ] **Step 8: Look at it, in a real mail client**

Rendering is the one thing a test cannot judge.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
jac run scripts/sendmail.jac summarize logs/2026-07-27 work/drafts/drafts 2026-07-27 config/nightshift.toml \
  > /tmp/ns-summary.json
jac run scripts/sendmail.jac render config/nightshift.toml < /tmp/ns-summary.json > /tmp/ns-digest.eml
wc -l /tmp/ns-digest.eml
# and one real send of the real digest
printf '%s' "$(cat /tmp/ns-summary.json)" | jac run scripts/sendmail.jac send config/nightshift.toml
```

Expected: a receipt on stdout, and a readable digest in the inbox with a working PR table. Check on a phone as well as a desktop client — the table is the only thing here that can overflow.

- [ ] **Step 9: Run the harness and commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/test-harness.sh
git add scripts/sendmail.jac
git commit -m "Render the digest as multipart/alternative HTML with a real text fallback

Spec section 14, and deliberately the LAST formatting task rather than the
first: the transport got a server receipt in Task 1 and the summary got real
content in Task 5, so this is polish on something that works instead of polish
on nothing.

Sections in triage order: the fatal reason first (13 ns_die sites share one
stage name), then per-task audited/found/selected/deferred with finding
summaries inline, the reactive tally, a PR table with mirror and CI status,
branches with diffstats inline so triage needs no clicks, the S1.6 inventory,
failures, deferred work, and the full drafts last. The text part carries the
same facts rather than an apology.

Everything interpolated that this file did not author -- finding summaries, PR
titles, fatal reasons -- goes through one esc(); mutation confirms the test
fails when it is removed. No templating dependency (email.mime is stdlib) and no
renderer abstraction for one output format."
```

---

### Task 7: Prove the digest fires on every path

A digest that only sends when the night succeeded is worse than none, because then silence means both "everything is fine" and "the harness is dead". `ns_on_exit` already calls `email_main` unconditionally with `|| true`, and the trap is armed for `EXIT TERM INT` — so this task does not change behaviour, it makes the behaviour *checked*, because it is one careless refactor away from being lost and nothing would notice for weeks.

**Files:**
- Modify: `bin/test-harness.sh` (section 15)
- Modify: `lib/email.sh` (only if Step 2 finds a real gap)

**Interfaces:** none new. This task is entirely tests.

- [ ] **Step 1: Establish that `email_main` cannot abort the trap**

`email_main` runs inside the EXIT trap of a `set -euo pipefail` script. If it can return nonzero or die, it changes the exit code the night reports and can suppress `ns_lock_release`. Check it by driving it at its worst.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
NS_ROOT="$PWD" bash -c 'set -euo pipefail
  . lib/common.sh; ns_load_config; . lib/email.sh
  LOG_DIR="/nonexistent/definitely-not-here"; NS_DATE=2026-01-02
  osascript() { return 0; }
  email_main; echo "email_main rc=$?"' 2>&1 | tail -3
```

Expected: `email_main rc=0`. A nonzero here means the trap can be aborted by its own last step; fix `email_main` before continuing (the fix is the same `case`-not-`&&` discipline used everywhere else in this plan).

- [ ] **Step 2: Add harness section 15**

```bash
echo "== 15. the digest must fire on EVERY exit path, and never abort the trap =="
# A digest that only sends on success is worse than none: silence would then mean both "fine"
# and "dead". ns_on_exit calls email_main unconditionally today -- this section is what keeps it
# that way through the next refactor, because losing it is invisible for weeks.
grep -q "trap 'ns_on_exit' EXIT TERM INT" bin/nightshift.sh \
    || fail "the exit trap no longer covers TERM -- the 8h watchdog kills with TERM, so the ceiling path would send no digest at all"
# email_main must be called from ns_on_exit OUTSIDE any conditional. Extract the trap function and
# assert the call is not nested: a `if [ "$code" -eq 0 ]` around it is the exact regression here.
trap_fn="$(sed -n '/^ns_on_exit() {/,/^}/p' bin/nightshift.sh)"
case "$trap_fn" in
    "") fail "could not extract ns_on_exit from bin/nightshift.sh -- section 15 would be vacuous" ;;
esac
case "$(printf '%s\n' "$trap_fn" | grep -c 'email_main')" in
    1) : ;;
    *) fail "ns_on_exit calls email_main $(printf '%s\n' "$trap_fn" | grep -c 'email_main') times; it must be exactly once, unconditionally" ;;
esac
printf '%s\n' "$trap_fn" | grep -q '^    email_main' \
    || fail "email_main is indented deeper than ns_on_exit's top level -- it is inside a conditional, so some exit paths send no digest"
printf '%s\n' "$trap_fn" | grep -q 'email_main .*|| true' \
    || fail "ns_on_exit's email_main call lost its '|| true'; under set -e a failing digest would abort the trap and skip ns_lock_release"

# Behavioural: email_main must return 0 even when EVERYTHING under it is broken.
(
    set -euo pipefail
    . "$NS_ROOT/lib/common.sh"; ns_bootstrap_jac; . "$NS_ROOT/lib/email.sh"
    LOG_DIR="/nonexistent/definitely-not-here"; NS_DATE=2026-01-02
    osascript() { return 0; }
    email_main
) > /dev/null 2>&1 || fail "email_main returned nonzero with an unusable LOG_DIR; it runs inside the EXIT trap and must never abort it"

# ...and the NS_DRY_RUN seam must render without touching a socket. Run it with the credentials
# deliberately UNSET: a dry-run that tried to send would fail on the live credential check.
D="$T/dryrun"; mkdir -p "$D"
(
    . "$NS_ROOT/lib/common.sh"; ns_load_config; . "$NS_ROOT/lib/email.sh"
    LOG_DIR="$D"; NS_DATE=2026-01-02; NS_DRY_RUN=1
    unset SMTP_USER SMTP_PASS
    email_main
) > "$D/out.txt" 2>&1 || fail "email_main failed in dry-run with no credentials; the NS_DRY_RUN seam is not holding"
[ -e "$D/SMTP_RECEIPT" ] && fail "a DRY-RUN produced an SMTP receipt -- it opened a real socket"
[ -f "$D/run-summary.json" ] || fail "email_main did not persist run-summary.json in dry-run"
echo "digest fires unconditionally, cannot abort the trap, and stays offline in dry-run"
```

- [ ] **Step 3: Mutation-test the section**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
cp bin/nightshift.sh /tmp/ns2.bak
# MUTATION A: only mail on failure
perl -0pi -e 's{^    email_main >> "\$LOG_DIR/S6\.log" 2>&1 \|\| true}{    if [ "\$code" -ne 0 ]; then email_main >> "\$LOG_DIR/S6.log" 2>&1 || true; fi}m' bin/nightshift.sh
bin/test-harness.sh >/dev/null 2>&1 && echo "BUG: a success-only digest passed section 15" \
                                    || echo "mutation caught: conditional digest rejected"
cp /tmp/ns2.bak bin/nightshift.sh
# MUTATION B: drop TERM from the trap (the 8h ceiling path)
perl -0pi -e "s/trap 'ns_on_exit' EXIT TERM INT/trap 'ns_on_exit' EXIT INT/" bin/nightshift.sh
bin/test-harness.sh >/dev/null 2>&1 && echo "BUG: a TERM-blind trap passed section 15" \
                                    || echo "mutation caught: TERM coverage required"
cp /tmp/ns2.bak bin/nightshift.sh
bin/test-harness.sh | tail -1
```

Expected: `mutation caught` twice, then `ALL HARNESS TESTS PASSED`.

- [ ] **Step 4: One full dry-run rehearsal**

The last thing before this plan is done: the whole night, end to end, with pushes stubbed and the digest rendered rather than sent.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift && bin/nightshift.sh dry-run; echo "exit=$?"
ls logs/$(date +%F)/ | grep -E 'merges.json|reactive-files.txt|reactive-summary.tsv|run-summary.json'
grep -c '<table' logs/$(date +%F)/S6.log
```

Expected: the S1.5 poll ran, the reactive pass either ran or logged a quiet day, and `run-summary.json` plus a rendered HTML digest exist. `exit=0`.

If the reactive pass ran, confirm its priority: `logs/<date>/S3a` log lines must all precede the first cycle-task audit line.

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
grep -nE '\[S3a\]|audit\[compiler' logs/$(date +%F)/run.log | head -12
```

- [ ] **Step 5: Commit**

```bash
cd /Volumes/ExtremePro/JaseciLabs/NightShift
git add bin/test-harness.sh lib/email.sh
git commit -m "Assert the digest fires on every exit path and cannot abort the trap

Behaviour unchanged; the behaviour is now checked. A digest that only sends on
success is worse than none, because silence then means both 'fine' and 'dead' --
and the change that would cause it (an \`if [ \"\$code\" -ne 0 ]\` around
email_main, or dropping TERM from the trap so the 8h ceiling path sends nothing)
is one careless refactor away and invisible for weeks.

Section 15 extracts ns_on_exit and asserts the call is unconditional, at top
level, and still wrapped in '|| true' so a failing digest cannot skip
ns_lock_release under set -e. Behavioural checks cover email_main with an
unusable LOG_DIR (must return 0) and dry-run with the credentials unset (must
render, must not open a socket, must still persist run-summary.json). Both
mutations -- success-only digest, TERM-blind trap -- are confirmed to fail it."
```

---

## Deliberately not built

Each of these was considered and cut. The condition that would justify building it is stated, so the next person does not have to re-derive the trade.

**A GitHub webhook for merge detection.** Needs repo admin on `jaseci-labs/jac`; the token has `{admin:false, push:false, pull:true}`. Polling once a night is exactly as timely as a nightly harness needs, and it survives a missed night for free by widening its own window. Build it if the harness ever becomes continuous rather than nightly, *and* admin is granted.

**PR-number-level merge deduplication.** The poll watermark is a date, so re-running a night re-audits that day's merges. Harmless today: findings carry ledger fingerprints and the selector suppresses `drafted`/`buried` ones, so the cost of an overlap is one cheap audit session. Build the max-PR-number watermark when a same-night re-run becomes routine rather than exceptional.

**Sharding the reactive file set.** Above `files_per_theme * 4` merged files the pass audits the first N and says so in the digest. Sharding it would reuse `tier2_audit_all`'s fan-out with per-chunk scopes and is maybe fifteen lines — but the ceiling has never fired, and a release-sized merge day is not a janitorial opportunity anyway. Build it the first time the digest reports the truncation warning twice in a week.

**Per-recipient or per-section digest configuration.** One recipient, one format, one section order. A `[email].sections` list would be config for a value that has never changed. Build it if a second human ever subscribes and wants a different view — not before.

**A second output format (Slack, a dashboard).** `html_body` is a function that returns a string, not a "renderer" behind an interface, precisely because there is one format. A second format is the event that justifies extracting the section builders; until then the abstraction would have exactly one implementation.

**Rich per-check CI detail in the PR table.** The table shows one `ci` status per PR, from Plan 3's `prs.jsonl`. Per-check rows (which of the 16 jobs is red, and whether it is red on `main` too) are already computed by Plan 3's `cigate.jac` baseline diff; surfacing all of them would make the table unreadable on a phone. Add a per-check expansion under a PR row when the CI repair loop starts failing often enough that "which check" is the first question rather than the second.

**Retrying a failed send.** `email_last_ditch` writes `$LOG_DIR/EMAIL_FAILED` and fires a macOS notification, and the receipt now makes "failed" unambiguous. A retry loop inside the EXIT trap is a place to hang, which is the failure mode the 30s timeout exists to prevent. If sends start failing intermittently on a host that is otherwise online, the right fix is a single retry *with* the timeout, not a loop without one.

**Storing the digest anywhere but the inbox.** `run-summary.json` is already on disk per night and the drafts branch already publishes the drafts. An archive of rendered digests would duplicate both. Build it if the mailbox ever becomes the only copy — it is not.
