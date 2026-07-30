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
import io;
import json;
import time;
import smtplib;
import from contextlib { redirect_stderr }
import from pathlib { Path }
import from email.mime.text { MIMEText }
import from email.mime.multipart { MIMEMultipart }
import from nslib { eprint, read_stdin, parse_obj, as_dict, as_list, as_int, load_config_toml, today }
import from render_draft { split_draft }

"""Subject grammar (TPRD S6): Nightshift <date> · <n> ready · −<loc> LOC · <m> failed[ · DISABLED| ERROR S<k>]."""
def subject(summary: dict) -> str {
    branches: list = as_list(summary.get("branches", []));
    added: int = sum([as_int(as_dict(b).get("added", 0)) for b in branches]);
    removed: int = sum([as_int(as_dict(b).get("removed", 0)) for b in branches]);
    failed: int = len(as_list(summary.get("failed", [])));
    s: str = "Nightshift " + str(summary["date"]) + " · " + str(len(branches)) + " ready";
    s += " · +" + str(added) + " -" + str(removed) + " · " + str(failed) + " failed";
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
        "files:   " + str(b.get("files", "?")) + "   lines: +" + str(b.get("added", 0)) + " -" + str(b.get("removed", 0)),
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
    # From is the AUTHENTICATED user, never config: Gmail rewrites any other value to exactly
    # this, so a [email].from knob could only ever be right by accident or wrong by drift.
    # ponytail: deletion over addition -- the knob is gone from config/nightshift.toml.
    msg["From"] = str(os.environ.get("SMTP_USER", "nightshift"));
    msg["To"] = str(email_cfg["to"]);
    text: str = plain_body(summary);
    msg.attach(MIMEText(text, "plain"));
    msg.attach(MIMEText("<pre>" + text.replace("&", "&amp;").replace("<", "&lt;") + "</pre>", "html"));
    return msg;
}

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

"""smtplib prints each sent line through repr(), so the trailing CRLF arrives as the four
LITERAL characters \\r\\n rather than a newline. Stripping it is what makes `AUTH LOGIN\\r\\n`
scrub to `AUTH LOGIN ***` instead of `AUTH LOGIN\\R\\N ***`."""
def smtp_payload(send_line: str) -> str {
    payload: str = send_line.strip()[5:].strip().lstrip("b").strip("'\"").lower();
    if payload.endswith("\\r\\n") {
        payload = payload[:-4];
    }
    return payload.strip();
}

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
        payload: str = smtp_payload(stripped);
        words: list[str] = payload.split(" ");
        verb: str = words[0].strip();
        if verb == "auth" {
            # keep the mechanism name, drop its argument: "AUTH PLAIN <secret>" -> "AUTH PLAIN ***"
            out.append("send: 'AUTH " + words[1].upper() + " ***'" if len(words) > 1
                       else "send: 'AUTH ***'");
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
        if stripped.startswith("send:") and smtp_payload(stripped) == "data" {
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

"""Connect, authenticate, transmit, and RETURN THE RECEIPT. Raises on anything else.

set_debuglevel is called after the constructor has already connected, so the TCP/TLS handshake
itself is not in the transcript -- that failure mode raises with a perfectly clear errno of its
own (see the 07-15 traceback) and adding a bare SMTP_SSL()+connect() dance to capture it would
buy nothing. Everything from EHLO onwards, which is where the ambiguous failures live, IS
captured -- INCLUDING on the raising path, which is the only path anyone will ever want to read
it on: the except arm emits what was captured before re-raising, so `see smtp-debug.txt` in
lib/email.sh's failure message points at a protocol transcript and not at a bare traceback."""
def smtp_send(msg: any, host: str, port: int, user: str, password: str) -> tuple[str, str] {
    buf: any = io.StringIO();
    try {
        with redirect_stderr(buf) {
            with smtplib.SMTP_SSL(host, port, timeout=SMTP_TIMEOUT_SEC) as server {
                smtp: any = server;
                smtp.set_debuglevel(1);
                smtp.login(user, password);
                refused: dict = as_dict(smtp.send_message(msg));
                if refused {
                    raise ValueError("SMTP refused recipients: " + str(sorted(refused.keys())));
                }
            }
        }
    } except Exception {
        eprint(scrub_smtp_debug(str(buf.getvalue())));
        raise;
    }
    transcript: str = scrub_smtp_debug(str(buf.getvalue()));
    receipt: str = receipt_from_debug(transcript);
    if not receipt {
        eprint(transcript);
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

"""Skips files that fail to parse (e.g. an empty report-*.json left by a died apply session) --
the digest is the one thing meant to always send, even on a bad night; one bad file must not
crash the whole summary."""
def read_json_files(directory: str, pattern: str) -> list[dict] {
    out: list[dict] = [];
    for path in glob_paths(directory, pattern) {
        with open(path, "r") as f {
            text: str = f.read();
        }
        if not text.strip() {
            continue;
        }
        try {
            out.append(parse_obj(text));
        } except Exception {
            eprint("sendmail: skipping unparseable " + path);
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
        added: int = as_int(loc.get("added", 0));
        removed: int = as_int(loc.get("removed", 0));
        branches.append({
            "theme": meta.get("title", os.path.basename(path)),
            "branch": meta.get("branch", "?"),
            "files": meta.get("files", 0),
            "added": added, "removed": removed,
            "loc_delta": added - removed,
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

with entry {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "summarize" and len(args) == 6 {
        print(json.dumps(summarize(args[2], args[3], args[4], load_config_toml(args[5]))));
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
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run sendmail.jac summarize <log_dir> <drafts_dir> <date> <config.toml>");
        eprint("       jac run sendmail.jac send|render <config.toml>   (run-summary JSON on stdin)");
        eprint("       jac run sendmail.jac doctor <config.toml>        (one live probe send)");
        sys.exit(2);
    }
}

test "subject grammar covers ready/added/removed/failed and error suffix" {
    summary: dict = {
        "date": "2026-07-10",
        "branches": [{"added": 20, "removed": 300}, {"added": 8, "removed": 112}],
        "failed": [{"what": "theme x", "reason": "tests red"}],
        "error_stage": None,
    };
    assert subject(summary) == "Nightshift 2026-07-10 · 2 ready · +28 -412 · 1 failed";
    summary["error_stage"] = "S4";
    assert subject(summary).endswith("· ERROR S4");
}

test "summarize assembles branches, failures and bugs from disk conventions" {
    import tempfile;
    log_dir: str = tempfile.mkdtemp();
    drafts_dir: str = tempfile.mkdtemp();
    draft: str = "---\nbranch: \"nightshift/2026-07-10/dead-code\"\npackage: \"jac\"\ndate: \"2026-07-10\"\ntitle: \"refactor(jac): x\"\nrisk: \"low\"\ntests: \"green\"\nrelease_note: \"r.md\"\nfiles: 2\nloc: {\"added\": 40, \"removed\": 100}\n---\n\n# refactor(jac): x\n";
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
    assert as_dict(as_list(summary["branches"])[0])["added"] == 40;
    assert as_dict(as_list(summary["branches"])[0])["removed"] == 100;
    assert as_dict(as_list(summary["failed"])[0])["reason"] == "tests red";
    assert len(as_list(summary["suspected_bugs"])) == 1;
    assert summary["turns"] == 41;
    assert subject(summary) == "Nightshift 2026-07-10 · 1 ready · +40 -100 · 1 failed";
}

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
    # The `data` line is present because scrubbing must not destroy the receipt: the transcript
    # written to $LOG_DIR/smtp-debug.txt is the scrubbed one, and lib/email.sh reads the receipt
    # out of the SAME text it stores. (The plan's fixture omitted it, so its own last assertion
    # could never have held.)
    raw: str = "send: 'AUTH PLAIN AGZha2UAc3VwZXJzZWNyZXQ=\\r\\n'\n"
        + "send: 'AUTH LOGIN\\r\\n'\n"
        + "reply: retcode (334); Msg: b'VXNlcm5hbWU6'\n"
        + "send: 'c3VwZXJzZWNyZXQ=\\r\\n'\n"
        + "send: 'ehlo [127.0.0.1]\\r\\n'\n"
        + "send: 'data\\r\\n'\n"
        + "reply: retcode (354); Msg: b'Go ahead'\n"
        + "reply: retcode (250); Msg: b'2.0.0 OK  1753900000 a1sm42 - gsmtp'\n";
    scrubbed: str = scrub_smtp_debug(raw);
    assert "c3VwZXJzZWNyZXQ=" not in scrubbed;
    assert "AGZha2UAc3VwZXJzZWNyZXQ=" not in scrubbed;
    assert "AUTH PLAIN ***" in scrubbed;
    assert "AUTH LOGIN ***" in scrubbed;
    assert "send: ***" in scrubbed;
    # the diagnosable parts survive: verbs, reply codes, and the receipt itself
    assert "ehlo [127.0.0.1]" in scrubbed;
    assert "retcode (334)" in scrubbed;
    assert receipt_from_debug(scrubbed) == "2.0.0 OK  1753900000 a1sm42 - gsmtp";
}

test "the message body itself is scrubbed, receipt survives" {
    # smtplib debuglevel 1 prints the whole DATA payload as `send:` lines too. None of it is a
    # known verb, so all of it collapses to `send: ***` -- the transcript is a PROTOCOL log, not
    # a copy of the mail.
    raw: str = "send: 'data\\r\\n'\n"
        + "reply: retcode (354); Msg: b'Go ahead'\n"
        + "send: 'Subject: Nightshift 2026-07-30\\r\\nsecret-body-text\\r\\n.\\r\\n'\n"
        + "reply: retcode (250); Msg: b'2.0.0 OK  1 q1 - gsmtp'\n";
    scrubbed: str = scrub_smtp_debug(raw);
    assert "secret-body-text" not in scrubbed;
    assert receipt_from_debug(scrubbed) == "2.0.0 OK  1 q1 - gsmtp";
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
