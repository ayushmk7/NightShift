"""S6 email digest (TechnicalPRD 7-S6). Always sent — the trap in nightshift.sh calls this
on every exit path; silence is itself a failure mode (PRD 11).

argv:  summarize <log_dir> <drafts_dir> <date> <config.toml>
                              assemble the run-summary JSON (TPRD 8.4) from the night's
                              artifacts (drafts, failed.tsv, report-*.json, meta-*.json,
                              warnings.txt, start_epoch, DISABLED, ERROR_STAGE, FATAL_REASON,
                              selection*.json, findings-*.json, reactive-summary.tsv,
                              reactive-files.txt, prs.jsonl, pr-inventory.jsonl,
                              deferred.jsonl) → stdout
       send <config.toml>     stdin: run-summary JSON; build + send the digest
       render <config.toml>   same, but print the RFC-2822 message instead of sending (dry-run)
env:   SMTP_USER, SMTP_PASS (from ~/.nightshift.env; never exported to agent sessions)
"""
import sys;
import os;
import io;
import html;
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
        reason: any = summary.get("fatal_reason");
        if reason is not None and str(reason) != "" {
            # truncated to keep the subject scannable; plain_body and the HTML carry it in full
            s += ": " + str(reason)[:80];
        }
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

"""Everything interpolated into the digest that did not come from this file is agent-authored or
upstream-authored text -- finding summaries, PR titles, fatal reasons, file paths. It goes into an
HTML document that a human opens in a mail client. Escape it once, here, and never build a string
with raw interpolation anywhere in html_body."""
def esc(v: any) -> str {
    return html.escape(str(v), quote=True);
}

"""What an EMPTY section is allowed to say. RECONCILIATION B3: prs.jsonl and pr-inventory.jsonl
both exist now, so "the stage ran and had nothing to report" and "the stage never wrote its file"
are different facts -- and an empty table that renders identically for both is exactly the "did not
run scored as passed" shape, in the one channel where nobody would ever notice it.

An artifacts map with the key MISSING (an old run-summary.json, or a summarize that stopped
recording it) is reported as unknown rather than silently as "none": the whole point is that an
un-evidenced claim is not made."""
def empty_note(summary: dict, key: str, artifact: str) -> str {
    if as_list(summary.get(key, [])) {
        return "";
    }
    arts: dict = as_dict(summary.get("artifacts", {}));
    if artifact not in arts {
        return "(nothing recorded — " + artifact + " presence unknown)";
    }
    if arts[artifact] {
        return "(none)";
    }
    return "(NOT WRITTEN TONIGHT — the stage that writes " + artifact + " did not run)";
}

"""Body order per TPRD S6: verdict → branch cards → full inline drafts → suspected bugs →
skipped/failed → runtime/cost → warnings."""
def plain_body(summary: dict) -> str {
    lines: list[str] = [str(summary.get("verdict", "(no verdict)")), ""];
    # WHY the night died leads the body: on a fatal night it is the only line that matters, and
    # the operator reads this on a phone. ERROR_STAGE says WHERE, ns_die's text says WHY.
    fatal: any = summary.get("fatal_reason");
    if fatal is not None and str(fatal) != "" {
        lines += ["FATAL (" + str(summary.get("error_stage", "?")) + "): " + str(fatal), ""];
    }
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
    # The text part is not a courtesy: a reader on a text-only client gets the same FACTS, not a
    # "view this in HTML" apology.
    react2: dict = as_dict(summary.get("reactive", {}));
    lines.append("REACTIVE: " + str(react2.get("files", 0)) + " merged file(s)");
    for (lens, n) in as_dict(react2.get("lenses", {})).items() {
        lines.append("  " + str(lens) + ": " + str(n));
    }
    for row in as_list(react2.get("merged_prs", [])) {
        cols: list = as_list(row);
        if len(cols) >= 4 {
            lines.append("  merged #" + str(cols[0]) + " " + str(cols[1]) + " (" + str(cols[2])
                         + ", " + str(cols[3]) + " file(s))");
        }
    }
    lines.append("");
    lines.append("PULL REQUESTS " + empty_note(summary, "prs", "prs.jsonl"));
    for pr in as_list(summary.get("prs", [])) {
        p2: dict = as_dict(pr);
        lines.append("  #" + str(p2.get("number", "?")) + " " + str(p2.get("title", ""))
                     + " [" + str(p2.get("task", "")) + "] mirror=" + str(p2.get("mirror", "?"))
                     + " ci=" + str(p2.get("ci", "?")) + " attempts=" + str(p2.get("attempts", 0)));
        lines.append("    " + str(p2.get("url", "")));
    }
    lines.append("");
    lines.append("PR INVENTORY " + empty_note(summary, "inventory", "pr-inventory.jsonl"));
    for item in as_list(summary.get("inventory", [])) {
        i2: dict = as_dict(item);
        lines.append("  #" + str(i2.get("number", "?")) + " " + str(i2.get("action", "?"))
                     + " " + str(i2.get("note", "")));
    }
    lines.append("");
    lines.append("DEFERRED TO A FUTURE NIGHT " + empty_note(summary, "deferred", "deferred.jsonl"));
    for item2 in as_list(summary.get("deferred", [])) {
        d3: dict = as_dict(item2);
        lines.append("  " + str(d3.get("file", "?")) + " — " + str(d3.get("reason", ""))
                     + " (" + str(d3.get("phase", "?")) + ")");
    }
    lines.append("");
    clock2: dict = as_dict(summary.get("clock", {}));
    lines.append("clock: " + str(clock2.get("consumed_min", "?")) + " of "
                 + str(clock2.get("window_min", "?")) + " min");
    lines.append("runtime: " + str(summary.get("runtime_min", "?")) + " min · turns: "
                 + str(summary.get("turns", "?")) + " · cost: $" + str(summary.get("cost_usd", "0")));
    for w in as_list(summary.get("warnings", [])) {
        lines.append("WARNING: " + str(w));
    }
    return "\n".join(lines) + "\n";
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

    # 2. per-phase: what was audited, what was found, selected, deferred, with summaries INLINE
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
    # No presence note here: `files` already carries it. 0 merged files IS the quiet day, and the
    # tsv is legitimately absent then -- the poll's own failure, which is the case that must not
    # look quiet, arrives as a failed.tsv row and is rendered under Failures below.
    out.append("<h3>Reactive pass — " + esc(react.get("files", 0)) + " merged file(s)</h3><ul>");
    for (lens, n) in as_dict(react.get("lenses", {})).items() {
        out.append("<li>" + esc(lens) + ": " + esc(n) + "</li>");
    }
    out.append("</ul><p>merged upstream tonight:</p><ul>");
    for row2 in as_list(react.get("merged_prs", [])) {
        cols2: list = as_list(row2);
        if len(cols2) >= 4 {
            out.append("<li>#" + esc(cols2[0]) + " " + esc(cols2[1]) + " — " + esc(cols2[2])
                       + ", " + esc(cols2[3]) + " file(s)</li>");
        }
    }
    out.append("</ul>");

    # 4. PR table. Diffstats inline so triage needs no clicks (design spec 14).
    out.append("<h3>Pull requests " + esc(empty_note(summary, "prs", "prs.jsonl"))
               + "</h3><table style=\"border-collapse:collapse\">"
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
    out.append("<h3>PR inventory " + esc(empty_note(summary, "inventory", "pr-inventory.jsonl"))
               + "</h3><ul>");
    for item in as_list(summary.get("inventory", [])) {
        i: dict = as_dict(item);
        out.append("<li>#" + esc(i.get("number", "?")) + " — <b>" + esc(i.get("action", "?"))
                   + "</b> " + esc(i.get("note", "")) + "</li>");
    }
    out.append("</ul>");

    # 7. failures and deferred work
    out.append("<h3>Failures</h3><ul>");
    for item3 in as_list(summary.get("failed", [])) {
        d: dict = as_dict(item3);
        out.append("<li>" + esc(d.get("what", "?")) + ": " + esc(d.get("reason", "")) + "</li>");
    }
    out.append("</ul><h3>Deferred to a future night "
               + esc(empty_note(summary, "deferred", "deferred.jsonl")) + "</h3><ul>");
    for item4 in as_list(summary.get("deferred", [])) {
        d2: dict = as_dict(item4);
        out.append("<li>" + esc(d2.get("file", "?")) + " — " + esc(d2.get("reason", ""))
                   + " (" + esc(d2.get("phase", "?")) + ")</li>");
    }
    out.append("</ul>");

    for w in as_list(summary.get("warnings", [])) {
        out.append("<p style=\"color:#a60\">WARNING: " + esc(w) + "</p>");
    }

    # 8. full drafts last: the longest content, and the part a reader scrolls to deliberately
    for b2 in as_list(summary.get("branches", [])) {
        c2: dict = as_dict(b2);
        if c2.get("draft_text", "") {
            out.append("<h3>draft: " + esc(c2.get("branch", "?")) + "</h3><pre style=\""
                       + td + ";white-space:pre-wrap\">" + esc(c2["draft_text"]) + "</pre>");
        }
    }
    out.append("</body></html>");
    return "\n".join(out);
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
    # text FIRST, html SECOND: RFC 2046 says the last alternative is the most preferred, so a
    # client that understands both shows the html and a text-only client falls back cleanly.
    msg.attach(MIMEText(text, "plain"));
    msg.attach(MIMEText(html_body(summary), "html"));
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

"""Both readers return [] for a missing file ON PURPOSE. The digest is the one thing that must
render when the stage that writes its input never ran, so absence is normal input here, not an
error. Unparseable LINES are skipped individually for the same reason a bad report-*.json is
(read_json_files above): one truncated write must not cost the whole digest.

What absence must NOT do is vanish. RECONCILIATION B3: prs.jsonl and pr-inventory.jsonl both exist
now (Plan 3 shipped them), and a reader that quietly returns [] renders an empty PR table every
night, forever, with no error -- "did not run scored as passed" in the one unattended channel this
project has. So `summarize` records which artifacts were PRESENT alongside their rows, and the
renderer prints "not written tonight" rather than an empty section."""
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

"""Per-phase rollup, derived entirely from files S3 already writes -- no new writer anywhere in the
pipeline. findings-*.json are the audit outputs (one per shard, one per reactive lens);
selection*.json record what was packed.

The phase comes from the FILENAME here and only here, and only because RECONCILIATION B6 fixes
those filenames: `selection.json` is the cycle phase (that literal name is what lib/dataset.sh and
scripts/dataset.jac read) and `selection-<phase>.json` is everything else. ponytail: a derivation,
not a schema."""
def task_sections(log_dir: str) -> list[dict] {
    sections: list[dict] = [];
    for path in glob_paths(log_dir, "selection*.json") {
        base: str = os.path.basename(path);
        phase: str = "cycle";
        if base != "selection.json" {
            phase = base[len("selection-"):-len(".json")];
        }
        sel: dict = {};
        with open(path, "r") as f {
            text: str = str(f.read());
        }
        if text.strip() {
            try {
                sel = parse_obj(text);
            } except Exception {
                eprint("sendmail: unparseable " + path);
            }
        }
        # The audit scopes that fed THIS phase. findings-all.json and findings-reactive.json are
        # merged outputs, not scopes, and listing them would report the merge as a shard.
        scopes: list[str] = [];
        for p in glob_paths(log_dir, "findings-*.json") {
            nm: str = os.path.basename(p)[len("findings-"):-len(".json")];
            if nm == "all" or nm == "reactive" {
                continue;
            }
            if nm.startswith("reactive-") == (phase == "reactive") {
                scopes.append(nm);
            }
        }
        themes: list = as_list(sel.get("themes", []));
        sections.append({
            "phase": phase,
            "scopes": scopes,
            "selected": len(themes),
            "deferred": len(as_list(sel.get("dropped", []))),
            "themes": [as_dict(t) for t in themes],
        });
    }
    return sections;
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
    fatal_lines: list[str] = read_lines(os.path.join(log_dir, "FATAL_REASON"));

    # A FAILED lens is carried through VERBATIM, never collapsed to 0: "found nothing" and "did not
    # run" are the two things this plan refuses to conflate, and the tsv already spells the
    # difference (lib/reactive.sh writes `FAILED` and `skipped (no coverage evidence)`).
    lenses: dict = {};
    for row in read_tsv(os.path.join(log_dir, "reactive-summary.tsv")) {
        if len(row) >= 2 {
            lenses[row[0]] = row[1];
        }
    }
    window: int = as_int(as_dict(cfg.get("budgets", {})).get("wallclock_min", 0));

    # RECONCILIATION B3. Which artifacts were actually on disk, so the renderer can say "S5 never
    # wrote this" instead of drawing an empty table that reads as "nothing to report".
    artifacts: dict = {};
    for name in ["prs.jsonl", "pr-inventory.jsonl", "reactive-summary.tsv", "deferred.jsonl"] {
        artifacts[name] = os.path.exists(os.path.join(log_dir, name));
    }
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
        # WHY the night died, not just where. ns_die (lib/common.sh) writes the message it was
        # called with; ERROR_STAGE alone is shared by 13 ns_die sites in lib/verify.sh.
        "fatal_reason": " ".join(fatal_lines) if fatal_lines else None,
        "clock": {"window_min": window, "consumed_min": runtime,
                  "remaining_min": window - runtime},
        "tasks": task_sections(log_dir),
        "reactive": {
            "files": len(read_lines(os.path.join(log_dir, "reactive-files.txt"))),
            "lenses": lenses,
            # number<TAB>title<TAB>author<TAB>nfiles, straight from `merges prs` (lib/reactive.sh).
            # WHICH PRs merged is the fact the reactive section is otherwise missing, and it costs
            # one already-existing reader.
            "merged_prs": read_tsv(os.path.join(log_dir, "reactive-prs.tsv")),
        },
        "prs": read_jsonl(os.path.join(log_dir, "prs.jsonl")),
        "inventory": read_jsonl(os.path.join(log_dir, "pr-inventory.jsonl")),
        "deferred": read_jsonl(os.path.join(log_dir, "deferred.jsonl")),
        "artifacts": artifacts,
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

test "summarize renders a COMPLETE skeleton from an empty log dir" {
    # The digest must render on the worst night there is -- one where the stage that writes its
    # inputs never ran. Every section is present and empty, never absent: an absent key is a
    # KeyError in html_body, i.e. the digest failing exactly when it matters most.
    import tempfile;
    empty: str = tempfile.mkdtemp();
    cfg: dict = {"repo": {"fork": "me/jaseci"}, "budgets": {"wallclock_min": 480}};
    s: dict = summarize(empty, tempfile.mkdtemp(), "2026-07-30", cfg);
    for key in ["date", "verdict", "branches", "failed", "tasks", "reactive", "prs",
                "inventory", "deferred", "clock", "warnings", "fatal_reason", "error_stage",
                "artifacts"] {
        assert key in s;
    }
    assert as_list(s["tasks"]) == [];
    assert as_dict(s["clock"])["window_min"] == 480;
    assert as_dict(s["reactive"])["files"] == 0;
    # RECONCILIATION B3: an empty list must not be the ONLY thing an absent artifact produces.
    # prs.jsonl and pr-inventory.jsonl both exist today, so "no rows" and "the writer never ran"
    # are different facts and the renderer needs both.
    for name in ["prs.jsonl", "pr-inventory.jsonl"] {
        assert as_dict(s["artifacts"])[name] == False;
    }
}

test "summarize folds the reactive tally, the PR rows and the inventory" {
    import tempfile;
    log_dir: str = tempfile.mkdtemp();
    with open(os.path.join(log_dir, "reactive-summary.tsv"), "w") as f {
        f.write("dead-code\t3\nabstraction\t0\nmaintenance\tFAILED\ncoverage\tskipped (no coverage evidence)\n");
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
        f.write("{\"number\": 7288, \"branch\": \"nightshift/2026-07-29/dead-code-cli\","
                + " \"action\": \"rebased\", \"note\": \"\"}\n");
        f.write("{\"number\": 7290, \"branch\": \"nightshift/2026-07-28/coverage-scale\","
                + " \"action\": \"conflicted\", \"note\": \"jac/jaclang/cli/x.jac\"}\n");
        f.write("not json at all\n");
    }
    with open(os.path.join(log_dir, "deferred.jsonl"), "w") as f {
        f.write("{\"fingerprint\": \"ab\", \"file\": \"jac/jaclang/scale/z.jac\","
                + " \"reason\": \"over-night-budget\", \"phase\": \"cycle\"}\n");
    }
    cfg: dict = {"repo": {"fork": "me/jaseci"}, "budgets": {"wallclock_min": 480}};
    s: dict = summarize(log_dir, tempfile.mkdtemp(), "2026-07-30", cfg);
    react: dict = as_dict(s["reactive"]);
    assert react["files"] == 2;
    assert as_dict(react["lenses"])["dead-code"] == "3";
    # a FAILED lens is preserved verbatim, NOT collapsed to 0 -- "found nothing" and "did not run"
    # are the two things this whole plan refuses to conflate, and "skipped" is a third
    assert as_dict(react["lenses"])["maintenance"] == "FAILED";
    assert as_dict(react["lenses"])["coverage"] == "skipped (no coverage evidence)";
    assert as_int(as_dict(as_list(s["prs"])[0])["number"]) == 7301;
    # the unparseable third line is skipped, the two good ones survive: one truncated write must
    # not cost the whole digest
    assert len(as_list(s["inventory"])) == 2;
    assert as_dict(as_list(s["inventory"])[1])["action"] == "conflicted";
    # Plan 3's extra `branch` key is harmless to a .get()-based reader (RECONCILIATION B3)
    assert as_dict(as_list(s["inventory"])[0])["branch"] == "nightshift/2026-07-29/dead-code-cli";
    assert as_dict(as_list(s["deferred"])[0])["reason"] == "over-night-budget";
    for name in ["prs.jsonl", "pr-inventory.jsonl", "reactive-summary.tsv", "deferred.jsonl"] {
        assert as_dict(s["artifacts"])[name] == True;
    }
}

test "task_sections separates the two phases and never reports a merge as a scope" {
    # RECONCILIATION B6: the cycle phase keeps the literal names findings.json / selection.json, so
    # the phase is derived from `selection.json` vs `selection-<phase>.json` -- and findings-all /
    # findings-reactive are MERGED outputs that must not be listed as audit scopes.
    import tempfile;
    d: str = tempfile.mkdtemp();
    with open(os.path.join(d, "selection.json"), "w") as f {
        f.write("{\"themes\": [{\"name\": \"cli\", \"summary\": \"s\"}], \"dropped\": [1, 2]}");
    }
    with open(os.path.join(d, "selection-reactive.json"), "w") as f {
        f.write("{\"themes\": [], \"dropped\": []}");
    }
    for nm in ["findings-cli.json", "findings-scale.json", "findings-reactive-dead-code.json",
               "findings-all.json", "findings-reactive.json"] {
        with open(os.path.join(d, nm), "w") as f {
            f.write("[]");
        }
    }
    sections: list[dict] = task_sections(d);
    assert len(sections) == 2;
    by_phase: dict = {};
    for s in sections {
        by_phase[str(s["phase"])] = s;
    }
    cyc: dict = as_dict(by_phase["cycle"]);
    assert sorted([str(x) for x in as_list(cyc["scopes"])]) == ["cli", "scale"];
    assert cyc["selected"] == 1 and cyc["deferred"] == 2;
    rea: dict = as_dict(by_phase["reactive"]);
    assert [str(x) for x in as_list(rea["scopes"])] == ["reactive-dead-code"];
    assert rea["selected"] == 0;
}

test "the html digest carries every section and escapes agent-authored text" {
    summary: dict = {
        "date": "2026-07-30",
        "verdict": "2 branch(es) ready · 1 failed",
        "clock": {"window_min": 480, "consumed_min": 312, "remaining_min": 168},
        "error_stage": "S4", "fatal_reason": "mirror job 'compiler' collected 0 items",
        "branches": [{"theme": "dead render path", "branch": "nightshift/2026-07-30/dead-code-x",
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
        "artifacts": {"prs.jsonl": True, "pr-inventory.jsonl": True, "deferred.jsonl": True,
                      "reactive-summary.tsv": True},
        "suspected_bugs": [], "warnings": [], "runtime_min": 312, "turns": 61, "cost_usd": 0,
    };
    doc: str = html_body(summary);
    # the fatal reason is the FIRST thing an operator should see
    assert doc.index("mirror job") < doc.index("7301");
    # every section from design spec 14
    for needle in ["312", "reactive-dead-code", "7301", "pending", "7288", "conflicted",
                   "over-night-budget", "tests red", "+4", "-212"] {
        assert needle in doc;
    }
    # ESCAPED. Finding summaries are agent-authored text going into an HTML document.
    assert "<script>alert(1)</script>" not in doc;
    assert "&lt;script&gt;" in doc;
    assert "remove dead pipe &lt;b&gt;" in doc;
    # ...but the harness's own markup survives
    assert "<table" in doc and "</html>" in doc;
}

test "an ABSENT PR artifact reads differently from an empty one" {
    # RECONCILIATION B3. prs.jsonl and pr-inventory.jsonl exist now, so an empty table that renders
    # identically whether S5 wrote nothing or never ran is the project's own defect class landing
    # in the one channel nobody watches.
    ran: dict = {"date": "d", "verdict": "v", "branches": [], "failed": [], "tasks": [],
                 "reactive": {"files": 0, "lenses": {}}, "prs": [], "inventory": [],
                 "deferred": [], "suspected_bugs": [], "warnings": [], "runtime_min": 0,
                 "turns": 0, "cost_usd": 0, "error_stage": None, "fatal_reason": None,
                 "clock": {"window_min": 480, "consumed_min": 0, "remaining_min": 480},
                 "artifacts": {"prs.jsonl": True, "pr-inventory.jsonl": True,
                               "deferred.jsonl": True, "reactive-summary.tsv": True}};
    assert "(none)" in html_body(ran);
    assert "NOT WRITTEN TONIGHT" not in html_body(ran);
    assert "(none)" in plain_body(ran);

    never: dict = dict(ran);
    never["artifacts"] = {"prs.jsonl": False, "pr-inventory.jsonl": False,
                          "deferred.jsonl": False, "reactive-summary.tsv": False};
    assert "NOT WRITTEN TONIGHT" in html_body(never);
    assert "prs.jsonl" in html_body(never);
    assert "NOT WRITTEN TONIGHT" in plain_body(never);

    # ...and a summary with no artifacts map at all says so rather than claiming "none"
    unknown: dict = dict(ran);
    unknown["artifacts"] = {};
    assert "presence unknown" in html_body(unknown);
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
        "artifacts": {"prs.jsonl": True, "pr-inventory.jsonl": True, "deferred.jsonl": True,
                      "reactive-summary.tsv": True},
    };
    text: str = plain_body(summary);
    # a reader on a text-only client must get the same FACTS, not a "view in HTML" apology
    assert "7301" in text and "pending" in text;
    assert "6" in text;                       # the reactive file count
    assert "clock: 42 of 480 min" in text;
    assert "<" not in text;                   # no markup leaked into the text part
}

test "build_message is multipart/alternative, text first then html" {
    summary: dict = {"date": "2026-07-30", "verdict": "v", "branches": [], "failed": [],
                     "tasks": [], "reactive": {"files": 0, "lenses": {}}, "prs": [],
                     "inventory": [], "deferred": [], "suspected_bugs": [], "warnings": [],
                     "clock": {"window_min": 480, "consumed_min": 1, "remaining_min": 479},
                     "artifacts": {"prs.jsonl": True, "pr-inventory.jsonl": True,
                                   "deferred.jsonl": True, "reactive-summary.tsv": True},
                     "runtime_min": 1, "turns": 0, "cost_usd": 0,
                     "error_stage": None, "fatal_reason": None};
    os.environ["SMTP_USER"] = "probe@example.com";
    msg: any = build_message(summary, {"email": {"to": "d@e.f"}});
    parts: list = as_list(msg.get_payload());
    assert msg.get_content_subtype() == "alternative";
    # RFC 2046: the LAST alternative is the most preferred, so html must come second
    assert parts[0].get_content_type() == "text/plain";
    assert parts[1].get_content_type() == "text/html";
    assert msg["From"] == "probe@example.com";
}

test "the reactive section names WHICH PRs merged, escaped" {
    # `merges prs` output is upstream-authored: PR titles come from other people's branches and go
    # straight into an HTML document. A malformed row (fewer than four columns) is dropped rather
    # than rendered half-way.
    import tempfile;
    d: str = tempfile.mkdtemp();
    with open(os.path.join(d, "reactive-prs.tsv"), "w") as f {
        f.write("7805\tci: fix the <b>glibc</b> floor\tmarsninja\t1\n");
        f.write("7806\ttruncated row\n");
    }
    with open(os.path.join(d, "reactive-files.txt"), "w") as f {
        f.write("jac/jaclang/cli/a.jac\n");
    }
    cfg: dict = {"repo": {"fork": "me/jaseci"}, "budgets": {"wallclock_min": 480}};
    s: dict = summarize(d, tempfile.mkdtemp(), "2026-07-30", cfg);
    rows: list = as_list(as_dict(s["reactive"])["merged_prs"]);
    assert len(rows) == 2;
    doc: str = html_body(s);
    assert "#7805" in doc;
    assert "marsninja" in doc;
    assert "<b>glibc</b>" not in doc and "&lt;b&gt;glibc&lt;/b&gt;" in doc;
    assert "7806" not in doc;                 # the truncated row is dropped, not half-rendered
    assert "#7805" in plain_body(s);
}
