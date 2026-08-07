"""Nightshift training-data capture: turns every real night's artifacts into JSONL rows meant
for later fine-tuning a jac-focused model. Append-only, one file per signal type so records can
be joined at training time rather than mutated in place:

  audit_findings.jsonl  one row per RAW finding an audit surfaced, whether or not it shipped
                        (status: applied | dropped_ledger | dropped_protected |
                                 over-theme-budget | over-night-budget | no-clock-left |
                                 not_selected). Captures the model's own judgment (confidence,
                                 risk, score) alongside what actually happened to the finding, and
                                 the `task` / `complexity` / `theme_hint` it was found under --
                                 without which the dataset cannot say which KIND of audit wastes
                                 money, or which branch a finding turned into.
  refactors.jsonl       one row PER FILE in a shipped branch: full before/after content, unified
                        diff, the finding that drove it (null for tier1 autofix), the agent's own
                        summary/risk, real added/removed line counts, the verify-gate outcome, and
                        the SESSION that produced it (model, attempt, turns, cost).
                        This is the core (buggy-jac -> clean-jac) pair data.
                        `shipped: false` rows are the other half: an apply session that read the
                        code and correctly REFUSED, carrying the concrete reason it refused. Those
                        used to be deleted with the log dir every morning; five of the eleven apply
                        sessions on 2026-07-31 were exactly that.
  sessions.jsonl        one row per LLM SESSION, which nothing else records. Cost and turns per
                        (phase, kind, task, complexity, model, attempt) is what makes "which task
                        type wastes the most money" and "are we getting better" answerable from the
                        dataset alone rather than from a forensic pass over a log dir that gets
                        purged. `wasted` and `outcome` are separate fields on purpose: "found
                        nothing" and "did not run" are the two things this repo refuses to conflate.
  nights.jsonl          one row per night whose audit ran AND parsed, including zero-finding
                        nights (real negative signal: "here's real jac-byllm code, nothing worth
                        flagging"). Failed/unparseable audits record no findings. Idempotent per
                        (date, package).
  human_reviews.jsonl   one row per promote/discard decision -- the highest-quality supervision
                        signal, joined to refactors.jsonl by branch name at read time. Empty until
                        `nightshift.sh promote` is actually used.

DRY RUNS ARE RECORDED, flagged (`dry_run: true`), and that is a correction rather than a relaxation.
Only `git push` and `gh pr create` are stubbed under NS_DRY_RUN: the audits, the apply sessions, the
commits, the branches and the whole S4 gate are real, and so is the bill. On 2026-07-31 that policy
discarded 112 findings, 27 sessions, 6 shipped branches and $76.55 of genuine training data on a
technicality. The ONE field a dry run makes untrue is the fork URL -- the branch was never pushed --
so that field is written as null, and nothing else is withheld. `dataset_record_review` keeps its
guard, because it is the only recorder reached from an INTERACTIVE command (promote/discard).

argv:
  record-audit    <log_dir> <dataset_dir> <date> <package> <config.toml> <dry_run:true|false>
  record-refactor <base_ref> <branch_ref> <repo_dir> <dataset_dir> <log_dir> <date> <package>
                  <theme_file_or_dash> <report_file> <added> <removed> <verify_line> <url_or_empty>
                  <dry_run:true|false>
  record-review   <branch> <dataset_dir> <accepted:true|false> <reason>
"""
import sys;
import os;
import json;
import glob;
import subprocess;
import from nslib {
    eprint, parse_obj, parse_list, as_dict, as_list, as_int, as_float, fingerprint, score_of,
    append_row, load_config_toml
}
import from parse_result { terminal_status, night_spend }
import from sendmail { scope_outcomes }

def git_show(repo_dir: str, ref: str, path: str) -> str {
    r = subprocess.run(["git", "-C", repo_dir, "show", ref + ":" + path],
        capture_output=True, text=True);
    return r.stdout if r.returncode == 0 else "";
}

def git_diff(repo_dir: str, base_ref: str, branch_ref: str, path: str) -> str {
    r = subprocess.run(["git", "-C", repo_dir, "diff", base_ref, branch_ref, "--", path],
        capture_output=True, text=True);
    return r.stdout;
}

"""Total readers. Every input here is an artifact some earlier stage may have failed to write, and
a capture pass that raises on one missing file records NOTHING for the whole night -- which is the
failure this phase exists to stop. Absence returns the empty shape, never an exception."""
def read_text(path: str) -> str {
    if not os.path.exists(path) {
        return "";
    }
    with open(path, "r") as f {
        return str(f.read());
    }
}

def read_obj(path: str) -> dict {
    text: str = read_text(path);
    if not text.strip() {
        return {};
    }
    try {
        return parse_obj(text);
    } except Exception {
        return {};
    }
}

"""A findings array, or None. The distinction is the point: `[]` is "this scope looked and the code
is clean" and None is "this scope produced nothing readable", and collapsing the second into the
first is this project's dominant defect class."""
def read_findings(path: str) -> list | None {
    text: str = read_text(path);
    if not text.strip() {
        return None;
    }
    try {
        return parse_list(text);
    } except Exception {
        return None;
    }
}

"""Already captured? The append-only guard, generalized over the three files that need one.

`record-audit` is re-runnable (a same-night re-entry, and dataset_backfill sweeps every log dir on
disk), so every writer below has to be idempotent on its own key or a backfill silently doubles the
dataset. The keys differ -- nights and sessions are per (date, package), a decline is per
(date, theme_slug) -- so the guard is a predicate over key/value pairs rather than three scans."""
def already_has(path: str, keys: dict) -> bool {
    if not os.path.exists(path) {
        return False;
    }
    with open(path, "r") as f {
        for line in f {
            stripped: str = line.strip();
            if not stripped {
                continue;
            }
            row: dict = {};
            try {
                row = parse_obj(stripped);
            } except Exception {
                continue;
            }
            hit: bool = True;
            for (k, v) in keys.items() {
                if str(row.get(k)) != str(v) {
                    hit = False;
                }
            }
            if hit {
                return True;
            }
        }
    }
    return False;
}

"""ATTEMPT NUMBERS, read off the night's own run.log, because no envelope can answer this:
`audit-<name>.json` and `apply-<slug>.json` are OVERWRITTEN in place by their own retry, so attempt
1 leaves no file behind. What survives is lib/tier2.sh's own log line -- `apply <slug> attempt <n>
on <model>` and `audit[<name>] attempt <n> ...` -- and the highest n logged for a name is the
attempt the surviving envelope belongs to. No run.log, or a name that never retried, is attempt 1."""
def attempts_from_log(lines: list[str]) -> dict[str, int] {
    out: dict[str, int] = {};
    for raw in lines {
        line: str = str(raw);
        if " attempt " not in line {
            continue;
        }
        name: str = "";
        if " apply " in line {
            name = line.split(" apply ", 1)[1].split(" attempt ", 1)[0].strip();
        } elif " audit[" in line {
            name = line.split(" audit[", 1)[1].split("]", 1)[0].strip();
        }
        if not name {
            continue;
        }
        num: str = line.split(" attempt ", 1)[1].strip().split(" ")[0];
        if not num.isdigit() {
            continue;
        }
        n: int = int(num);
        if n > as_int(out.get(name, 0)) {
            out[name] = n;
        }
    }
    return out;
}

"""Tonight's CYCLE task, off the same run.log line lib/tier2.sh writes when it resolves it. The
reactive lenses name their own task (they are `reactive-<task>`); a shard audit does not, because
the whole fan-out runs the one task the cycle advanced to. dataset_backfill already greps run.log
for the night's package, so this is the established source, not a new one."""
def cycle_task(lines: list[str]) -> str {
    for raw in lines {
        line: str = str(raw);
        if "tonight's task: " in line {
            return line.split("tonight's task: ", 1)[1].strip().split(" ")[0];
        }
    }
    return "";
}

"""Which model actually served the session, from the envelope's own per-model usage table rather
than from the `--model` flag the harness passed or the alias it logged. `sonnet` in run.log and
`claude-sonnet-...` in modelUsage are the same decision recorded at two different fidelities; this
is the one the bill was computed against."""
def envelope_model(env: dict) -> str | None {
    usage: any = env.get("modelUsage");
    if isinstance(usage, dict) {
        names: list[str] = sorted([str(k) for k in usage.keys()]);
        if names {
            return names[0];
        }
    }
    return None;
}

"""ONE ROW PER LLM SESSION, derived from the envelopes the night already wrote.

The envelope families are `audit-<scope>.json`, `audit-repair-<scope>.json` (the single-turn
corrective re-prompt) and `apply-<slug>.json`. `meta-*.json` is deliberately NOT walked: it is a
byte-twin projection of the first two, and the repair sessions have no meta file at all -- which is
the $0.28 of 2026-07-31 that every meta-glob roll-up in this repo used to lose.

`outcome` is parse_result.terminal_status, unchanged and unwrapped: that classifier is total by
construction and already returns the exact taxonomy (completed / unfinished:max_turns /
unfinished:no-result / unfinished:no-envelope). `scope_failed` is sendmail.scope_outcomes, likewise
reused whole: it fuses the findings count, failed.tsv and the session's own is_error with "any
source saying failed WINS", and it is the only thing on this night that correctly calls all three
dead reactive lenses dead -- including the two whose refusal had been laundered into `[]`.

`wasted` and `outcome` are SEPARATE FIELDS and must stay separate. A session that completed and
found nothing is not the same event as a session that died at the turn cap, even though both
produced zero findings and both cost real money."""
def session_rows(log_dir: str, date_s: str, package: str, dry_run: bool, caps: dict) -> list[dict] {
    outcomes: dict[str, dict] = scope_outcomes(log_dir);
    lines: list[str] = read_text(os.path.join(log_dir, "run.log")).splitlines();
    attempts: dict[str, int] = attempts_from_log(lines);
    night_task: str = cycle_task(lines);

    paths: list[str] = sorted(glob.glob(os.path.join(log_dir, "audit-*.json")));
    paths += sorted(glob.glob(os.path.join(log_dir, "apply-*.json")));
    rows: list[dict] = [];
    for path in paths {
        base: str = os.path.basename(path)[:-len(".json")];
        kind: str = "";
        name: str = "";
        if base.startswith("audit-repair-") {
            kind = "audit-repair";
            name = base[len("audit-repair-"):];
        } elif base.startswith("audit-") {
            kind = "audit";
            name = base[len("audit-"):];
        } elif base.startswith("apply-") {
            kind = "apply";
            name = base[len("apply-"):];
        } else {
            continue;
        }

        text: str = read_text(path);
        env: dict = {};
        try {
            env = parse_obj(text);
        } except Exception {
            env = {};
        }

        task: str = "";
        complexity: any = None;
        phase: str = "cycle";
        # -1 is "no readable answer", kept as an int here only because Jac narrows a
        # None-or-int local the first time it is assigned; it becomes a real null in the row below.
        # The distinction is load-bearing: 0 findings and no findings file are different events.
        n_out: int = -1;
        scope_failed: any = None;
        skipped_reasons: list[str] = [];
        theme_slug: any = None;

        if kind == "apply" {
            theme: dict = read_obj(os.path.join(log_dir, "theme-" + name + ".json"));
            task = str(theme.get("task", ""));
            complexity = theme.get("complexity");
            theme_slug = name;
            # The reactive marker sits AFTER the task in the branch slug (lib/tier2.sh builds
            # `<task>-reactive-<hint>`, and RECONCILIATION B2 forbids putting it in front, because
            # ns_task_of_branch resolves the task by PREFIX). So the phase is exactly that infix.
            marker: str = (task + "-reactive-") if task else "-reactive-";
            if name.startswith(marker) or ("-reactive-" in name and not task) {
                phase = "reactive";
            }
            rpt: dict = read_obj(os.path.join(log_dir, "report-" + name + ".json"));
            if rpt {
                n_out = len(as_list(rpt.get("files", [])));
                for s in as_list(rpt.get("skipped", [])) {
                    skipped_reasons.append(str(as_dict(s).get("reason", "")));
                }
            }
        } else {
            if name.startswith("reactive-") {
                phase = "reactive";
                task = name[len("reactive-"):];
            } else {
                task = night_task;
            }
            # audit-repair-<name>.json OVERWRITES findings-<name>.json with the REPAIR session's own
            # salvaged output (lib/tier2.sh's corrective re-prompt), and it only ever exists after a
            # session that COMPLETED but emitted bad JSON (is_error=false, has .result, parse failed)
            # -- a died session gets no repair. So when this "audit" row's own session completed and
            # a repair file is present, the shared findings file holds the REPAIR's output, not this
            # session's; crediting it here would hand the original attempt findings it never
            # produced. Only the "audit-repair" row, which is that session, may read that file.
            got: list | None = None;
            if kind == "audit" and not bool(env.get("is_error", False)) and os.path.exists(
                    os.path.join(log_dir, "audit-repair-" + name + ".json")) {
                got = None;
            } else {
                got = read_findings(os.path.join(log_dir, "findings-" + name + ".json"));
            }
            if got is not None {
                n_out = len(got);
            }
            scope_failed = bool(as_dict(outcomes.get(name, {})).get("failed", False));
        }

        # WASTED: this session's money bought no downstream artifact. For an audit that means no
        # finding survived it (or the scope is one scope_outcomes calls dead); for an apply it means
        # no file changed. Deliberately true for a correct refusal too -- a refusal is valuable
        # training data, which is why it gets a refactors.jsonl row, and it is still money spent
        # that shipped nothing.
        wasted: bool = False;
        if kind == "apply" {
            wasted = n_out < 1;
        } else {
            wasted = bool(scope_failed) or n_out < 1;
        }

        rows.append({
            "date": date_s, "package": package, "dry_run": dry_run,
            "phase": phase, "kind": kind, "name": name,
            "task": task, "complexity": complexity, "theme_slug": theme_slug,
            "attempt": as_int(attempts.get(name, 1)),
            "model": envelope_model(env),
            "session_id": env.get("session_id"),
            "total_cost_usd": env.get("total_cost_usd"),
            "num_turns": env.get("num_turns"),
            "duration_ms": env.get("duration_ms"),
            "is_error": env.get("is_error"),
            "terminal_reason": env.get("terminal_reason", env.get("subtype")),
            "max_turns_configured": caps.get(kind),
            "outcome": terminal_status(text),
            "scope_failed": scope_failed,
            "findings_out": None if n_out < 0 else n_out,
            "wasted": wasted,
            "skipped_reasons": skipped_reasons,
        });
    }
    return rows;
}

"""The apply sessions that read the code and CORRECTLY REFUSED -- `shipped: false` refactor rows.

"deleting `scalar_layout` would break `test_abi_lib.jac`, which is outside this theme's file list"
is a better training signal than most of what ships, and until now it was deleted with the log dir
every morning: only green branches ever reached refactors.jsonl (lib/ship.sh), and a theme that made
no commit is recorded nowhere but as one line in failed.tsv.

A decline is `report-<slug>.json exists AND <slug> is not in queue.tsv`. queue.tsv is what
ns_queue_branch appends when an apply produced a branch, so it separates "refused" from "shipped"
using a file that S3 has already written by the time this runs -- green.tsv would not, because S4
has not run yet, and a theme that is merely awaiting its gate is not a decline. If queue.tsv is
absent altogether the two cannot be told apart, so nothing is recorded and the caller is told."""
def decline_rows(log_dir: str, date_s: str, package: str, dry_run: bool,
                 sessions: list[dict]) -> list[dict] {
    queue_path: str = os.path.join(log_dir, "queue.tsv");
    if not os.path.exists(queue_path) {
        eprint("dataset: no queue.tsv in " + log_dir
               + " — cannot tell a refused theme from a queued one, so no decline rows");
        return [];
    }
    queued: set[str] = set();
    for line in read_text(queue_path).splitlines() {
        stripped: str = str(line).strip();
        if stripped {
            queued.add(os.path.basename(stripped.split("\t")[0]));
        }
    }
    by_slug: dict[str, dict] = {};
    for s in sessions {
        srow: dict = as_dict(s);
        if str(srow.get("kind")) == "apply" {
            by_slug[str(srow.get("name"))] = srow;
        }
    }

    rows: list[dict] = [];
    for path in sorted(glob.glob(os.path.join(log_dir, "report-*.json"))) {
        slug: str = os.path.basename(path)[len("report-"):-len(".json")];
        if slug in queued {
            continue;
        }
        rpt: dict = read_obj(path);
        if not rpt {
            continue;               # 0-byte leftover of a failed redirect, not a considered refusal
        }
        theme: dict = read_obj(os.path.join(log_dir, "theme-" + slug + ".json"));
        theme_findings: list = as_list(theme.get("findings", []));
        sess: dict = as_dict(by_slug.get(slug, {}));
        rows.append({
            "date": date_s, "package": package, "shipped": False, "dry_run": dry_run,
            # No branch, no file, no diff: that is the fact being recorded. Present as explicit
            # nulls so a reader joining these to the shipped rows gets the same key set either way.
            "branch": None, "file": None, "before": None, "after": None, "diff": None, "url": None,
            "finding": as_dict(theme_findings[0]) if theme_findings else None,
            "agent_summary": rpt.get("summary", ""), "risk": rpt.get("risk", "?"),
            "loc_added": 0, "loc_removed": 0,
            "verify": "not gated — the apply session declined to change anything",
            "suspected_bugs": as_list(rpt.get("suspected_bugs", [])),
            "skipped": as_list(rpt.get("skipped", [])),
            "theme_slug": slug, "complexity": theme.get("complexity"), "task": theme.get("task"),
            "session_id": sess.get("session_id"), "total_cost_usd": sess.get("total_cost_usd"),
            "num_turns": sess.get("num_turns"), "model": sess.get("model"),
            "attempt": sess.get("attempt"),
        });
    }
    return rows;
}

"""The per-session turn caps in force, so a row can say whether a session that stopped at N turns
was ALLOWED more. Read from the config passed in, which for a live night is the night's own config
and for a replay/backfill is today's -- a backfilled row therefore stamps today's cap, not the cap
that night ran under. Unknown stays null rather than guessing a number."""
def turn_caps(config_path: str) -> dict {
    budgets: dict = {};
    try {
        budgets = as_dict(load_config_toml(config_path).get("budgets", {}));
    } except Exception {
        return {"audit": None, "audit-repair": 1, "apply": None};
    }
    return {
        "audit": budgets.get("audit_max_turns"),
        # lib/tier2.sh's corrective re-prompt is hardcoded `--max-turns 1`; it is not a config knob.
        "audit-repair": 1,
        "apply": budgets.get("max_turns"),
    };
}

"""What one PHASE selected, keyed for the join back onto its own findings.

Both phases have exactly this shape on disk -- `findings<sfx>.json` and `selection<sfx>.json`, where
the suffix is "" for the cycle phase and "-reactive" for the reactive one (lib/tier2.sh's
ns_phase_suffix). The cycle phase prefers `findings-all.json`, which is fresh findings MERGED with
the carry-over the selector actually packed; findings.json alone is the 95 of 112 that were new
tonight, and recording only those loses every carried finding at the moment it finally ships.

Fingerprints are recomputed from (file, rule) so the join survives fingerprint-formula changes; the
dropped list only started carrying "rule" later, hence the file-level fallback."""
def phase_selection(log_dir: str, sfx: str) -> dict {
    selected_fps: set[str] = set();
    dropped_by_fp: dict[str, str] = {};
    dropped_by_file: dict[str, str] = {};
    n_themes: int = 0;
    n_dropped: int = 0;
    selection: dict = read_obj(os.path.join(log_dir, "selection" + sfx + ".json"));
    themes: list = as_list(selection.get("themes", []));
    n_themes = len(themes);
    for t in themes {
        for f in as_list(as_dict(t).get("findings", [])) {
            sel: dict = as_dict(f);
            selected_fps.add(fingerprint(str(sel.get("file", "")), str(sel.get("rule", ""))));
        }
    }
    dropped: list = as_list(selection.get("dropped", []));
    n_dropped = len(dropped);
    for d in dropped {
        dd: dict = as_dict(d);
        if "rule" in dd {
            dropped_by_fp[fingerprint(str(dd.get("file", "")), str(dd.get("rule", "")))] = str(dd.get("reason", ""));
        } else {
            dropped_by_file[str(dd.get("file", ""))] = str(dd.get("reason", ""));
        }
    }
    # `selected` leaves as a LIST, not a set: it crosses an `any`-typed dict boundary and Jac cannot
    # narrow a set back out of one (E1001), while as_list is the narrowing the caller already has.
    return {"selected": sorted(selected_fps), "by_fp": dropped_by_fp, "by_file": dropped_by_file,
            "themes": n_themes, "dropped": n_dropped};
}

"""Every raw finding an audit surfaced tonight, in BOTH phases, cross-referenced against that
phase's selection to record what actually happened to it.

THE REACTIVE PHASE USED TO BE INVISIBLE HERE. This read `findings.json` and `selection.json` and
nothing else, so `findings-reactive.json` / `selection-reactive.json` -- the pass that produced
THREE OF THE SIX shipped branches on 2026-07-31 -- contributed not one row. The phase is now a
field, and a night is the union of its phases.

Idempotent per (date, package): a same-day re-run, and dataset_backfill's sweep over every log dir
still on disk, must not double the dataset.

A phase whose findings file is absent or unparseable is a FAILED audit, not a clean night, and
contributes nothing -- but the OTHER phase can still be recorded, and the sessions and declines are
recorded either way, because what a failed night spent is the fact least safe to drop."""
def record_audit(log_dir: str, dataset_dir: str, date_s: str, package: str,
                 config_path: str, dry_run: bool) -> int {
    os.makedirs(dataset_dir, exist_ok=True);
    nights_path: str = os.path.join(dataset_dir, "nights.jsonl");
    key: dict = {"date": date_s, "package": package};
    if already_has(nights_path, key) {
        eprint("dataset: " + date_s + "/" + package + " already recorded — skipping");
        return 0;
    }

    # SESSIONS AND DECLINES FIRST, and unconditionally: they describe what the night SPENT and what
    # its apply sessions REFUSED, neither of which stops being true because an audit came back
    # malformed. Guarded on their own files so a re-run cannot double them either.
    caps: dict = turn_caps(config_path);
    sessions: list[dict] = session_rows(log_dir, date_s, package, dry_run, caps);
    sessions_path: str = os.path.join(dataset_dir, "sessions.jsonl");
    if already_has(sessions_path, key) {
        eprint("dataset: sessions for " + date_s + "/" + package + " already recorded — skipping");
    } else {
        for srow in sessions {
            append_row(sessions_path, srow);
        }
    }
    refactors_path: str = os.path.join(dataset_dir, "refactors.jsonl");
    n_declined: int = 0;
    for drow in decline_rows(log_dir, date_s, package, dry_run, sessions) {
        if not already_has(refactors_path, {"date": date_s, "theme_slug": drow["theme_slug"],
                                            "shipped": False}) {
            append_row(refactors_path, drow);
            n_declined += 1;
        }
    }

    audit_out: str = os.path.join(dataset_dir, "audit_findings.jsonl");
    n_total: int = 0;
    n_carry: int = 0;
    n_themes: int = 0;
    n_dropped: int = 0;
    phases_seen: list[str] = [];
    for (phase, sfx) in [("cycle", ""), ("reactive", "-reactive")] {
        # findings-all.json is the cycle phase's REAL input: tonight's findings merged with the
        # carry-over the selector packed ahead of them. It exists only when that merge ran.
        source: str = os.path.join(log_dir, "findings" + sfx + ".json");
        if phase == "cycle" and os.path.exists(os.path.join(log_dir, "findings-all.json")) {
            source = os.path.join(log_dir, "findings-all.json");
        }
        if not os.path.exists(source) {
            continue;
        }
        findings: list | None = read_findings(source);
        if findings is None {
            eprint("dataset: " + source + " unparseable — failed " + phase
                   + " audit, no findings recorded for that phase");
            continue;
        }
        phases_seen.append(phase);
        sel_info: dict = phase_selection(log_dir, sfx);
        selected_fps: set[str] = set([str(x) for x in as_list(sel_info["selected"])]);
        dropped_by_fp: dict = as_dict(sel_info["by_fp"]);
        dropped_by_file: dict = as_dict(sel_info["by_file"]);
        n_themes += as_int(sel_info["themes"]);
        n_dropped += as_int(sel_info["dropped"]);

        for f in findings {
            fd: dict = as_dict(f);
            fp: str = fingerprint(str(fd.get("file", "")), str(fd.get("rule", "")));
            status: str = "not_selected";
            if fp in selected_fps {
                status = "applied";
            } elif fp in dropped_by_fp {
                status = str(dropped_by_fp[fp]);
            } elif str(fd.get("file", "")) in dropped_by_file {
                status = str(dropped_by_file[str(fd.get("file", ""))]);
            }
            carried: bool = bool(fd.get("carry", False));
            if carried {
                n_carry += 1;
            }
            append_row(audit_out, {
                "date": date_s, "package": package, "phase": phase,
                "file": fd.get("file", ""),
                "rule": fd.get("rule", ""), "summary": fd.get("summary", ""),
                "snippet": fd.get("snippet", ""), "confidence": fd.get("confidence"),
                "risk": fd.get("risk"), "score": score_of(fd),
                "est_loc_saved": fd.get("est_loc_saved"), "fingerprint": fp, "status": status,
                # THE THREE FIELDS THIS ROW USED TO DROP. `task` is the most waste-relevant field
                # there is -- without it the dataset cannot say which audit lens produced findings
                # worth applying. `complexity` is what routes the apply model. `theme_hint` is the
                # join key back to the branch the finding turned into.
                "task": fd.get("task"), "complexity": fd.get("complexity"),
                "theme_hint": fd.get("theme_hint"), "carry": carried,
            });
            n_total += 1;
        }
    }
    if not phases_seen {
        eprint("dataset: no phase of " + date_s + " produced a readable findings file — "
               + "no nights row (a failed audit is not a clean night)");
        return 0;
    }

    # THE NIGHT'S BILL, off the session ledger rather than a `meta-*.json` glob. The glob missed
    # every repair session -- they charge the ledger (lib/tier2.sh's ns_spend_add after the
    # corrective re-prompt) but write no meta file -- which is $0.28 of 2026-07-31.
    spend: dict = night_spend(log_dir);
    append_row(nights_path, {
        "date": date_s, "package": package, "dry_run": dry_run,
        "phases": phases_seen,
        "findings_count": n_total,
        # SPLIT OUT because they answer different questions: how much did tonight's audit find, and
        # how much of what it packed was inherited from a night that could not afford it.
        "findings_carryover": n_carry,
        "findings_fresh": n_total - n_carry,
        # `themes_selected` used to be `len(selected_fps)`, a count of FINDINGS: it emitted 9 for a
        # night that selected 6 themes. A theme is what becomes a branch, so it is what is counted.
        "themes_selected": n_themes,
        "themes_deferred": n_dropped,
        "declines": n_declined,
        # TWO NUMBERS, because they can legitimately disagree. `sessions` is the authoritative count
        # from whichever source paid for the night; `session_rows` is how many of them left an
        # envelope to describe. A retry overwrites its predecessor's envelope in place, so a night
        # where those differ is a night that spent money no per-session row can account for.
        "sessions": spend["sessions"], "session_rows": len(sessions),
        "cost_usd": spend["cost_usd"], "turns": spend["turns"],
        "cost_source": spend["source"],
    });
    return n_total;
}

"""One row per file actually changed in a shipped branch: full before/after content (via `git
show` at the merge-base and at the branch tip -- robust to files that were created or deleted),
the unified diff, and the finding + verify outcome that justified shipping it.

Plus WHAT IT COST. These rows used to carry no effort data at all -- no session, no model, no turns,
no cost -- so the dataset could say a refactor shipped but not whether it took a $0.28 five-turn
Sonnet session or a $2.13 fifty-eight-turn Opus one. `log_dir` is what supplies it (the apply
envelope and its theme sit there under the branch's own slug); a branch with no apply session --
every v1 tier-1 row, and any branch a backfill recovers without its logs -- leaves those fields
null, which is the truth about it.

`url` arrives EMPTY for a dry run and is stored as null. That is the single field a dry run makes
untrue -- the branch was real, the commits were real, the gate was real, but nothing was pushed, so
`https://github.com/<fork>/tree/<branch>` points at nothing. Recording it as a string would put a
dead link in training data; withholding the whole row (what this used to do) threw the night away."""
def record_refactor(base_ref: str, branch_ref: str, repo_dir: str, dataset_dir: str, log_dir: str,
                     date_s: str, package: str, theme_file: str, report_file: str, added: int,
                     removed: int, verify_line: str, url: str, dry_run: bool) -> int {
    os.makedirs(dataset_dir, exist_ok=True);
    rpt: dict = parse_obj(open(report_file, "r").read());

    slug: str = os.path.basename(branch_ref.removeprefix("origin/"));
    finding: dict | None = None;
    theme: dict = {};
    if theme_file != "-" and os.path.exists(theme_file) {
        theme = parse_obj(open(theme_file, "r").read());
        theme_findings: list = as_list(theme.get("findings", []));
        if theme_findings {
            finding = as_dict(theme_findings[0]);
        }
    }
    env: dict = read_obj(os.path.join(log_dir, "apply-" + slug + ".json"));
    attempts: dict[str, int] = attempts_from_log(
        read_text(os.path.join(log_dir, "run.log")).splitlines());

    files: list[str] = [str(x) for x in as_list(rpt.get("files", []))];
    out_path: str = os.path.join(dataset_dir, "refactors.jsonl");
    n: int = 0;
    for path in files {
        append_row(out_path, {
            # branch_ref may arrive as origin/<branch> (backfill) or bare (live) -- store bare
            "date": date_s, "package": package, "branch": branch_ref.removeprefix("origin/"), "file": path,
            "shipped": True, "dry_run": dry_run,
            "before": git_show(repo_dir, base_ref, path),
            "after": git_show(repo_dir, branch_ref, path),
            "diff": git_diff(repo_dir, base_ref, branch_ref, path),
            "finding": finding,
            "agent_summary": rpt.get("summary", ""), "risk": rpt.get("risk", "?"),
            "loc_added": added, "loc_removed": removed, "verify": verify_line,
            "url": url if url else None,
            "suspected_bugs": as_list(rpt.get("suspected_bugs", [])),
            "skipped": as_list(rpt.get("skipped", [])),
            "theme_slug": slug, "task": theme.get("task"), "complexity": theme.get("complexity"),
            "session_id": env.get("session_id"), "total_cost_usd": env.get("total_cost_usd"),
            "num_turns": env.get("num_turns"), "model": envelope_model(env),
            "attempt": as_int(attempts.get(slug, 1)),
        });
        n += 1;
    }
    return n;
}

"""The highest-quality supervision signal: a human actually accepted (promoted to a real PR) or
rejected (discarded) this branch. Joined to refactors.jsonl by branch name at training time."""
def record_review(branch: str, dataset_dir: str, accepted: bool, reason: str) -> int {
    os.makedirs(dataset_dir, exist_ok=True);
    append_row(os.path.join(dataset_dir, "human_reviews.jsonl"),
        {"branch": branch, "accepted": accepted, "reason": reason});
    return 1;
}

with entry:__main__ {
    args: list[str] = sys.argv;
    cmd: str = args[1] if len(args) > 1 else "";
    if cmd == "record-audit" and len(args) == 8 {
        print(record_audit(args[2], args[3], args[4], args[5], args[6], args[7].lower() == "true"));
    } elif cmd == "record-refactor" and len(args) == 16 {
        n: int = record_refactor(args[2], args[3], args[4], args[5], args[6], args[7], args[8],
            args[9], args[10], as_int(args[11]), as_int(args[12]), args[13], args[14],
            args[15].lower() == "true");
        print(n);
    } elif cmd == "record-review" and len(args) == 6 {
        print(record_review(args[2], args[3], args[4].lower() == "true", args[5]));
    } elif cmd != "" and cmd != "test" {
        eprint("usage: jac run dataset.jac record-audit <log_dir> <dataset_dir> <date> <package>");
        eprint("                <config.toml> <dry_run>");
        eprint("       jac run dataset.jac record-refactor <base_ref> <branch_ref> <repo_dir>");
        eprint("                <dataset_dir> <log_dir> <date> <package> <theme_or_dash> <report_file>");
        eprint("                <added> <removed> <verify_line> <url_or_empty> <dry_run>");
        eprint("       jac run dataset.jac record-review <branch> <dataset_dir> <accepted> <reason>");
        sys.exit(2);
    }
}

"""A log dir shaped like a real night, small enough to assert on: two phases, a carry-over finding,
one shipped theme, one theme the agent refused, one dead reactive lens, and a session ledger with a
row no envelope can account for. Every filename here is one lib/tier2.sh actually writes."""
def _fixture_night(d: str) {
    fp_a: str = fingerprint("a.jac", "dup");
    fp_b: str = fingerprint("b.jac", "dead");
    # findings.json is the FRESH audit; findings-all.json is what the selector actually consumed --
    # fresh plus the carry-over merged ahead of it. Recording findings.json loses the carried one.
    fresh: list = [
        {"file": "a.jac", "rule": "dup", "snippet": "snip a", "summary": "s1", "confidence": 4,
         "risk": 2, "est_loc_saved": 10, "task": "abstraction", "complexity": "judgement",
         "theme_hint": "dupe-helpers"},
        {"file": "b.jac", "rule": "dead", "snippet": "snip b", "summary": "s2", "confidence": 3,
         "risk": 3, "est_loc_saved": 6, "task": "abstraction", "complexity": "mechanical",
         "theme_hint": "dead-b"},
    ];
    carried: dict = {"file": "c.jac", "rule": "simplify", "snippet": "s", "summary": "s3",
        "confidence": 2, "risk": 1, "est_loc_saved": 4, "task": "dead-code",
        "complexity": "trivial", "theme_hint": "old-thing", "carry": True};
    with open(d + "/findings.json", "w") as f {
        f.write(json.dumps(fresh));
    }
    with open(d + "/findings-all.json", "w") as f {
        f.write(json.dumps([carried] + fresh));
    }
    with open(d + "/selection.json", "w") as f {
        f.write(json.dumps({
            # ONE theme carrying TWO findings: the old code counted findings and called them themes.
            "themes": [{"slug": "abstraction-dupe-helpers", "findings": [
                {"file": "a.jac", "rule": "dup"}, {"file": "c.jac", "rule": "simplify"}]}],
            "dropped": [
                {"fingerprint": fp_b, "file": "b.jac", "rule": "dead", "reason": "over-night-budget"},
            ],
        }));
    }
    # The reactive phase: its own findings file, its own selection, its own applied theme.
    with open(d + "/findings-reactive.json", "w") as f {
        f.write(json.dumps([
            {"file": "r.jac", "rule": "dead-code", "snippet": "r", "summary": "s4", "confidence": 5,
             "risk": 1, "est_loc_saved": 8, "task": "dead-code", "complexity": "mechanical",
             "theme_hint": "unused-thing"},
        ]));
    }
    with open(d + "/selection-reactive.json", "w") as f {
        f.write(json.dumps({"themes": [{"slug": "dead-code-unused-thing",
            "findings": [{"file": "r.jac", "rule": "dead-code"}]}], "dropped": []}));
    }
    # per-scope findings files, which is what scope_outcomes reads
    with open(d + "/findings-cli.json", "w") as f {
        f.write(json.dumps(fresh));
    }
    with open(d + "/findings-reactive-dead-code.json", "w") as f {
        f.write(json.dumps([{"file": "r.jac", "rule": "dead-code"}]));
    }
    with open(d + "/findings-reactive-coverage.json", "w") as f {
        f.write("[]");           # the LAUNDERED placeholder: it looks like a clean zero
    }
    with open(d + "/audit-cli.json", "w") as f {
        f.write(json.dumps({"is_error": False, "result": "ok", "num_turns": 40, "duration_ms": 1000,
            "total_cost_usd": 4.0, "session_id": "s-audit-cli", "terminal_reason": "completed",
            "modelUsage": {"claude-opus-5": {}}}));
    }
    with open(d + "/audit-reactive-dead-code.json", "w") as f {
        f.write(json.dumps({"is_error": False, "result": "ok", "num_turns": 12, "duration_ms": 900,
            "total_cost_usd": 2.0, "session_id": "s-audit-react", "terminal_reason": "completed",
            "modelUsage": {"claude-opus-5": {}}}));
    }
    # THE DEAD LENS: died at the turn cap, and its `[]` was salvaged onto disk above.
    with open(d + "/audit-reactive-coverage.json", "w") as f {
        f.write(json.dumps({"is_error": True, "num_turns": 46, "duration_ms": 800,
            "total_cost_usd": 7.89, "session_id": "s-audit-dead", "subtype": "error_max_turns",
            "modelUsage": {"claude-opus-5": {}}}));
    }
    with open(d + "/audit-repair-reactive-coverage.json", "w") as f {
        f.write(json.dumps({"is_error": False, "result": "[]", "num_turns": 1, "duration_ms": 90,
            "total_cost_usd": 0.25, "session_id": "s-repair", "terminal_reason": "completed",
            "modelUsage": {"claude-opus-5": {}}}));
    }
    # The BYTE-TWIN meta projections lib/tier2.sh writes beside each audit envelope. scope_outcomes
    # reads is_error off THESE, and the cost roll-up has to dedupe them away against the originals.
    with open(d + "/meta-audit-cli.json", "w") as f {
        f.write(json.dumps({"num_turns": 40, "total_cost_usd": 4.0, "session_id": "s-audit-cli",
            "is_error": False}));
    }
    with open(d + "/meta-audit-reactive-dead-code.json", "w") as f {
        f.write(json.dumps({"num_turns": 12, "total_cost_usd": 2.0, "session_id": "s-audit-react",
            "is_error": False}));
    }
    with open(d + "/meta-audit-reactive-coverage.json", "w") as f {
        f.write(json.dumps({"num_turns": 46, "total_cost_usd": 7.89, "session_id": "s-audit-dead",
            "is_error": True}));
    }
    # one apply that SHIPPED and one that REFUSED
    with open(d + "/apply-abstraction-dupe-helpers.json", "w") as f {
        f.write(json.dumps({"is_error": False, "result": "ok", "num_turns": 58, "duration_ms": 5000,
            "total_cost_usd": 2.13, "session_id": "s-apply-ship", "terminal_reason": "completed",
            "modelUsage": {"claude-opus-5": {}}}));
    }
    with open(d + "/apply-dead-code-reactive-unused-thing.json", "w") as f {
        f.write(json.dumps({"is_error": False, "result": "ok", "num_turns": 5, "duration_ms": 400,
            "total_cost_usd": 0.28, "session_id": "s-apply-refuse", "terminal_reason": "completed",
            "modelUsage": {"claude-sonnet-4-5": {}}}));
    }
    with open(d + "/report-abstraction-dupe-helpers.json", "w") as f {
        f.write(json.dumps({"summary": "merged the helpers", "risk": "low", "files": ["a.jac"],
            "skipped": [], "suspected_bugs": []}));
    }
    with open(d + "/report-dead-code-reactive-unused-thing.json", "w") as f {
        f.write(json.dumps({"summary": "No edits made.", "risk": "low", "files": [],
            "skipped": [{"file": "r.jac", "reason": "deleting scalar_layout would break test_abi_lib.jac"}],
            "suspected_bugs": []}));
    }
    with open(d + "/theme-abstraction-dupe-helpers.json", "w") as f {
        f.write(json.dumps({"slug": "abstraction-dupe-helpers", "task": "abstraction",
            "complexity": "judgement", "findings": [{"file": "a.jac", "rule": "dup"}]}));
    }
    with open(d + "/theme-dead-code-reactive-unused-thing.json", "w") as f {
        f.write(json.dumps({"slug": "dead-code-reactive-unused-thing", "task": "dead-code",
            "complexity": "mechanical", "findings": [{"file": "r.jac", "rule": "dead-code"}]}));
    }
    # queue.tsv holds only the theme that produced a branch -- the refusal is absent, which is what
    # separates "declined" from "waiting for the S4 gate" at the moment this runs.
    with open(d + "/queue.tsv", "w") as f {
        f.write("nightshift/2026-01-01/abstraction-dupe-helpers\t-\t-\n");
    }
    with open(d + "/failed.tsv", "w") as f {
        f.write("theme dead-code-reactive-unused-thing\tagent made no committed changes\n");
    }
    with open(d + "/run.log", "w") as f {
        f.write("20:43:54 [S3] tonight's task: abstraction (scoring=loc_saved, ponytail=full)\n"
                + "21:00:42 [S3] apply abstraction-dupe-helpers attempt 1 on opus (task=abstraction, complexity=judgement)\n"
                + "21:02:21 [S3] apply abstraction-dupe-helpers attempt 2 on opus (task=abstraction, complexity=judgement)\n"
                + "21:03:20 [S3] audit[reactive-coverage] attempt 1 failed to parse even after corrective re-prompt\n");
    }
    # The ledger: three real sessions plus one whose envelope its own retry overwrote.
    with open(d + "/spend.txt", "w") as f {
        f.write("s-audit-cli\t4.0\ns-audit-react\t2.0\ns-audit-dead\t7.89\ns-repair\t0.25\n"
                + "s-apply-ship\t2.13\ns-apply-refuse\t0.28\ns-overwritten\t3.0\n");
    }
}

def _cfg(path: str) {
    with open(path, "w") as f {
        f.write("[budgets]\naudit_max_turns = 130\nmax_turns = 80\n");
    }
}

def _rows(path: str) -> list[dict] {
    with open(path, "r") as f {
        return [as_dict(json.loads(line)) for line in f.read().splitlines()];
    }
}

test "record_audit records BOTH phases, counts themes not findings, and bills off the ledger" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    ds: str = tempfile.mkdtemp();
    cfg: str = d + "/nightshift.toml";
    _fixture_night(d);
    _cfg(cfg);

    n: int = record_audit(d, ds, "2026-01-01", "repo", cfg, True);
    # 3 cycle findings (2 fresh + 1 carried) + 1 reactive. The reactive phase used to contribute 0.
    assert n == 4;
    rows: list[dict] = _rows(ds + "/audit_findings.jsonl");
    assert len([r for r in rows if r["phase"] == "cycle"]) == 3;
    assert len([r for r in rows if r["phase"] == "reactive"]) == 1;
    # the carried finding is present AND joined to the theme that finally packed it
    carried: list[dict] = [r for r in rows if r["file"] == "c.jac"];
    assert len(carried) == 1 and carried[0]["status"] == "applied" and carried[0]["carry"];
    dropped: list[dict] = [r for r in rows if r["file"] == "b.jac"];
    assert dropped[0]["status"] == "over-night-budget";
    # the three fields the row used to drop
    assert carried[0]["task"] == "dead-code" and carried[0]["complexity"] == "trivial";
    assert carried[0]["theme_hint"] == "old-thing";

    night: dict = _rows(ds + "/nights.jsonl")[0];
    assert night["dry_run"];
    assert night["findings_count"] == 4 and night["findings_carryover"] == 1;
    assert night["findings_fresh"] == 3;
    # 2 themes (1 cycle + 1 reactive), NOT the 3 findings they hold between them.
    assert night["themes_selected"] == 2;
    assert night["phases"] == ["cycle", "reactive"];
    assert night["declines"] == 1;
    # 7 on the ledger, 6 with an envelope: the 7th is the attempt whose retry overwrote its file.
    assert night["sessions"] == 7 and night["session_rows"] == 6;
    # off spend.txt: includes the repair session (no meta file) AND the overwritten attempt
    # (no envelope at all). A meta-*.json glob sees neither and reports 16.30.
    assert night["cost_source"] == "spend.txt";
    assert abs(as_float(night["cost_usd"]) - 19.55) < 0.0001;

    # idempotent across every file it writes
    assert record_audit(d, ds, "2026-01-01", "repo", cfg, True) == 0;
    assert len(_rows(ds + "/nights.jsonl")) == 1;
    assert len(_rows(ds + "/audit_findings.jsonl")) == 4;
    assert len(_rows(ds + "/sessions.jsonl")) == 6;
    assert len(_rows(ds + "/refactors.jsonl")) == 1;
}

test "sessions.jsonl gives every session a row, and never calls a dead lens a clean zero" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    ds: str = tempfile.mkdtemp();
    cfg: str = d + "/nightshift.toml";
    _fixture_night(d);
    _cfg(cfg);
    record_audit(d, ds, "2026-01-01", "repo", cfg, True);

    rows: list[dict] = _rows(ds + "/sessions.jsonl");
    # 3 audits + 1 repair + 2 applies. The repair is the one no meta-*.json glob can see.
    assert len(rows) == 6;
    by_name: dict[str, dict] = {};
    for r in rows {
        by_name[str(r["kind"]) + ":" + str(r["name"])] = r;
    }
    assert sorted(by_name.keys()) == [
        "apply:abstraction-dupe-helpers", "apply:dead-code-reactive-unused-thing",
        "audit-repair:reactive-coverage", "audit:cli", "audit:reactive-coverage",
        "audit:reactive-dead-code"];

    # THE DEAD LENS. Its findings file says `[]`, its meta says is_error -- and any source saying
    # failed WINS. A row that reported findings_out 0 with scope_failed false would be the exact
    # 2026-07-31 defect ("did not run" scoring as "found nothing") reproduced in the dataset.
    dead: dict = by_name["audit:reactive-coverage"];
    assert dead["outcome"] == "unfinished:error_max_turns";
    assert dead["scope_failed"] and dead["wasted"];
    assert dead["findings_out"] == 0;         # what it wrote, recorded verbatim, next to the verdict
    assert as_float(dead["total_cost_usd"]) == 7.89;
    assert dead["phase"] == "reactive" and dead["task"] == "coverage";
    assert dead["max_turns_configured"] == 130;

    live: dict = by_name["audit:reactive-dead-code"];
    assert live["outcome"] == "completed" and not live["scope_failed"] and not live["wasted"];

    # a shard audit inherits the night's task from run.log; a lens names its own
    assert by_name["audit:cli"]["task"] == "abstraction";
    assert by_name["audit:cli"]["phase"] == "cycle";

    # the repair session is a session: it has an id, a cost, and a cap of 1 turn
    rep: dict = by_name["audit-repair:reactive-coverage"];
    assert rep["kind"] == "audit-repair" and rep["max_turns_configured"] == 1;
    assert as_float(rep["total_cost_usd"]) == 0.25;

    # applies: attempt comes off run.log (the envelope was overwritten), model off the envelope
    ship: dict = by_name["apply:abstraction-dupe-helpers"];
    assert ship["attempt"] == 2 and ship["model"] == "claude-opus-5";
    assert ship["complexity"] == "judgement" and ship["phase"] == "cycle";
    assert ship["findings_out"] == 1 and not ship["wasted"];
    refuse: dict = by_name["apply:dead-code-reactive-unused-thing"];
    assert refuse["phase"] == "reactive" and refuse["model"] == "claude-sonnet-4-5";
    assert refuse["wasted"] and refuse["attempt"] == 1;
    assert "test_abi_lib.jac" in str(as_list(refuse["skipped_reasons"])[0]);
}

test "a malformed-then-repaired audit does not also credit the ORIGINAL session with the repair's findings" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    # findings-cli.json is what the REPAIR session wrote (3 real findings), overwriting whatever
    # the original attempt left behind -- there is no separate file for the original's own output,
    # because it never parsed.
    with open(d + "/findings-cli.json", "w") as f {
        f.write(json.dumps([
            {"file": "a.jac", "rule": "dead-code"}, {"file": "b.jac", "rule": "dead-code"},
            {"file": "c.jac", "rule": "dead-code"},
        ]));
    }
    with open(d + "/audit-cli.json", "w") as f {
        f.write(json.dumps({"is_error": False, "result": "not fenced json", "num_turns": 10,
            "total_cost_usd": 1.0, "session_id": "s-orig", "terminal_reason": "completed",
            "modelUsage": {"claude-opus-5": {}}}));
    }
    with open(d + "/audit-repair-cli.json", "w") as f {
        f.write(json.dumps({"is_error": False, "result": "ok", "num_turns": 1,
            "total_cost_usd": 0.1, "session_id": "s-repair", "terminal_reason": "completed",
            "modelUsage": {"claude-opus-5": {}}}));
    }
    caps: dict = {"audit": None, "audit-repair": 1, "apply": None};
    rows: list[dict] = session_rows(d, "2026-01-01", "repo", False, caps);
    by_kind: dict[str, dict] = {};
    for r in rows {
        by_kind[str(r["kind"])] = r;
    }
    # THE ORIGINAL ATTEMPT: its own output never parsed, so it gets no findings, not the repair's 3.
    orig: dict = by_kind["audit"];
    assert orig["findings_out"] is None and orig["wasted"];
    # THE REPAIR: this is the session that actually produced the 3 findings.
    repair: dict = by_kind["audit-repair"];
    assert repair["findings_out"] == 3 and not repair["wasted"];
}

test "an apply session that REFUSED lands as a shipped:false row with its real reason" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    ds: str = tempfile.mkdtemp();
    cfg: str = d + "/nightshift.toml";
    _fixture_night(d);
    _cfg(cfg);
    record_audit(d, ds, "2026-01-01", "repo", cfg, True);

    rows: list[dict] = _rows(ds + "/refactors.jsonl");
    assert len(rows) == 1;
    row: dict = rows[0];
    assert row["shipped"] == False;
    assert row["theme_slug"] == "dead-code-reactive-unused-thing";
    assert row["branch"] is None and row["url"] is None and row["file"] is None;
    assert "would break test_abi_lib.jac" in str(as_dict(as_list(row["skipped"])[0])["reason"]);
    # the session that refused, so a decline can be costed like anything else
    assert row["session_id"] == "s-apply-refuse" and as_float(row["total_cost_usd"]) == 0.28;
    assert row["model"] == "claude-sonnet-4-5" and row["complexity"] == "mechanical";

    # The theme that DID produce a branch is not a decline: it is in queue.tsv, awaiting S4.
    # Without that distinction every gated theme would be recorded as a refusal.
    assert len([r for r in rows if r["theme_slug"] == "abstraction-dupe-helpers"]) == 0;
}

test "a night whose audits all failed still records what it spent, but no nights row" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    ds: str = tempfile.mkdtemp();
    cfg: str = d + "/nightshift.toml";
    _cfg(cfg);
    # A 0-byte findings.json is the marker of a failed audit, not of a clean night.
    with open(d + "/findings.json", "w") as f {
        f.write("");
    }
    with open(d + "/audit-cli.json", "w") as f {
        f.write(json.dumps({"is_error": True, "num_turns": 46, "total_cost_usd": 9.5,
            "session_id": "s-dead", "subtype": "error_max_turns"}));
    }
    assert record_audit(d, ds, "2026-01-02", "repo", cfg, False) == 0;
    assert not os.path.exists(ds + "/nights.jsonl");
    # ...but $9.50 of it is on the record, which is the whole point: a failed night is the one
    # least able to afford disappearing from the cost data.
    srows: list[dict] = _rows(ds + "/sessions.jsonl");
    assert len(srows) == 1 and srows[0]["wasted"] and srows[0]["outcome"] == "unfinished:error_max_turns";
    assert srows[0]["dry_run"] == False;
}

test "record_refactor carries the session that produced it, and nulls a dry run's fork URL" {
    import tempfile;
    import subprocess as sp;
    repo: str = tempfile.mkdtemp();
    sp.run(["git", "init", "-q", repo]);
    sp.run(["git", "-C", repo, "config", "user.email", "t@t.com"]);
    sp.run(["git", "-C", repo, "config", "user.name", "t"]);
    with open(repo + "/x.jac", "w") as f {
        f.write("def old() -> int { return 1; }\n");
    }
    sp.run(["git", "-C", repo, "add", "-A"]);
    sp.run(["git", "-C", repo, "commit", "-q", "-m", "base"]);
    base_ref: str = sp.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip();
    # a local branch literally named origin/feat: exercises the origin/-prefix stripping the
    # backfill path needs while keeping every git call resolvable
    sp.run(["git", "-C", repo, "checkout", "-q", "-b", "origin/feat"]);
    with open(repo + "/x.jac", "w") as f {
        f.write("def new() -> int { return 1; }\n");
    }
    sp.run(["git", "-C", repo, "commit", "-q", "-am", "clean"]);

    ds: str = tempfile.mkdtemp();
    log_dir: str = tempfile.mkdtemp();
    with open(log_dir + "/report.json", "w") as f {
        f.write(json.dumps({"summary": "renamed", "risk": "low", "files": ["x.jac"]}));
    }
    with open(log_dir + "/theme-feat.json", "w") as f {
        f.write(json.dumps({"task": "abstraction", "complexity": "judgement", "findings": []}));
    }
    with open(log_dir + "/apply-feat.json", "w") as f {
        f.write(json.dumps({"num_turns": 24, "total_cost_usd": 0.71, "session_id": "s-feat",
            "modelUsage": {"claude-sonnet-4-5": {}}}));
    }
    with open(log_dir + "/run.log", "w") as f {
        f.write("21:00 [S3] apply feat attempt 2 on opus (task=abstraction, complexity=judgement)\n");
    }
    n: int = record_refactor(base_ref, "origin/feat", repo, ds, log_dir, "2026-01-01", "jac",
        log_dir + "/theme-feat.json", log_dir + "/report.json", 1, 1, "jac check ok", "", True);
    assert n == 1;
    row: dict = _rows(ds + "/refactors.jsonl")[0];
    assert "def old" in row["before"] and "def new" in row["after"];
    assert row["file"] == "x.jac" and row["agent_summary"] == "renamed";
    assert row["branch"] == "feat" and row["shipped"] and row["dry_run"];
    # THE ONE FIELD A DRY RUN MAKES UNTRUE. Nothing was pushed, so there is no tree/<branch> to
    # link; every other field on this row describes work that really happened.
    assert row["url"] is None;
    assert row["session_id"] == "s-feat" and as_float(row["total_cost_usd"]) == 0.71;
    assert row["model"] == "claude-sonnet-4-5" and row["attempt"] == 2;
    assert row["complexity"] == "judgement" and row["task"] == "abstraction";

    # ...and a REAL night keeps its URL, or the assertion above is satisfied by always writing null.
    ds2: str = tempfile.mkdtemp();
    record_refactor(base_ref, "origin/feat", repo, ds2, log_dir, "2026-01-01", "jac",
        log_dir + "/theme-feat.json", log_dir + "/report.json", 1, 1, "ok",
        "https://github.com/me/jac/tree/feat", False);
    live: dict = _rows(ds2 + "/refactors.jsonl")[0];
    assert live["url"] == "https://github.com/me/jac/tree/feat" and not live["dry_run"];
}
