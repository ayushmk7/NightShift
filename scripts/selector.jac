"""S3-B selector (TechnicalPRD 7 S3-B): merge audit findings with the ledger,
drop the ineligible, score, and greedy-pack into budgeted themes.

argv:  select <config.toml> <ledger.jsonl> <state.json> <remaining_min> <repo_dir>
           stdin: validated findings array → stdout: {"themes": [...], "dropped": [...]}
       split <selection.json> <outdir>     write theme-<slug>.json per theme; print slugs
       dropped <selection.json>            print `fingerprint<TAB>file<TAB>reason` lines
Deterministic: same inputs → same packing (unit-testable, TPRD 14).
"""
import sys;
import os;
import json;
import re;
import subprocess;
import from nslib {
    eprint, read_stdin, parse_list, parse_obj, fingerprint, load_ledger, state_read,
    state_write, load_config_toml, load_globs, is_protected, as_dict, as_list, as_float,
    score_of
}

"""Non-project imports a test file may keep and still be "100% about this theme's dead code" --
stdlib, test frameworks, and common third-party libs. Deliberately short: anything NOT in here is
treated as a real project dependency and disqualifies the file (fail closed).

CROSS-REFERENCE, and the reason "deliberately short" is load-bearing rather than stylistic:
WIDENING THIS SET CAN BREAK THE TEST GATE, in a file nothing here points at. testgate.jac's
COLLECTION_FLOOR (0.75) tolerates a vestigial-test sweep shrinking a suite's collection, and its
whole safety margin is measured against WHICH byllm test files this allowlist currently
disqualifies. Seven of byllm's ten test-bearing files are permanently ineligible today purely
because they import io / shutil / uuid / ast / contextlib / contextvars / jaclang / fixtures /
enum_with_semstr -- none of which is in this set. Adding those (a small, benign-looking change)
makes test_byllm.jac eligible, and test_byllm.jac alone is 100 of byllm's 219 collected items
(46%) -- far past any floor above 0.55. The result would be a legitimate theme reding twice and
being auto-rejected as failed_verify. The full arithmetic lives in testgate.jac's COLLECTION_FLOOR
docstring; read it before extending this list."""
def import_allowlist() -> set[str] {
    return {
        "os", "sys", "re", "json", "time", "types", "pathlib", "tempfile", "threading",
        "unittest", "pytest", "typing", "dataclasses", "concurrent", "futures", "testclient",
        "fastapi", "collections", "itertools", "functools", "asyncio", "logging", "datetime",
    };
}

def file_stem(path: str) -> str {
    base: str = path.rsplit("/", 1)[-1];
    for suffix in [".impl.jac", ".jac"] {
        if base.endswith(suffix) {
            return base[:-len(suffix)];
        }
    }
    return base;
}

"""True iff every `import from <dotted.module> {...}` / bare `import <dotted.module>;` line in
this test file resolves (by its dotted path's last segment) to either a file already in this
theme's own scope, or the small non-project allowlist above. ANY other project import means the
file also covers something NOT being deleted here, so it must stay protected -- this is the
independent, orchestrator-side check; the agent's own claim is never trusted for this."""
def is_vestigial(repo_dir: str, test_rel_path: str, allowed_stems: set[str]) -> bool {
    try {
        with open(repo_dir + "/" + test_rel_path, "r") as f {
            content: str = f.read();
        }
    } except Exception {
        return False;
    }
    allowlist: set[str] = import_allowlist();
    # Requires at least one import that actually matches a theme stem -- a file with ZERO
    # matching AND zero disqualifying imports (e.g. the word only appears in an unrelated string
    # literal, never a real import) must not vacuously pass just because nothing disqualified it.
    matched: bool = False;
    for line in content.splitlines() {
        m = re.match("^\\s*import(?:\\s+from)?\\s+([\\w.]+)", line);
        if m is None {
            continue;
        }
        stem: str = str(m.group(1)).rsplit(".", 1)[-1];
        if stem in allowed_stems {
            matched = True;
        } elif stem not in allowlist {
            return False;
        }
    }
    return matched;
}

"""Test files that would become entirely vestigial if this theme's files were deleted --
grep-discovered by the theme's own file stems (so it never misses a match on naming), then
independently verified file-by-file via is_vestigial. Only ever searches already-protected paths
(is_protected), so this can only ever EXPAND what a theme may delete, never narrow normal
protection."""
def vestigial_test_files(repo_dir: str, theme_files: list[str], protect_globs: list[str]) -> list[str] {
    stems: set[str] = set([file_stem(f) for f in theme_files]);
    if not stems or not os.path.isdir(repo_dir + "/jac") {
        return [];
    }
    found = subprocess.run(
        ["grep", "-rlE", "|".join(sorted(stems)), repo_dir + "/jac", "--include=*.jac"],
        capture_output=True, text=True);
    out: list[str] = [];
    for line in found.stdout.splitlines() {
        rel: str = line[len(repo_dir) + 1:] if line.startswith(repo_dir + "/") else line;
        if is_protected(rel, protect_globs) and is_vestigial(repo_dir, rel, stems) {
            out.append(rel);
        }
    }
    return sorted(out);
}

def slugify(hint: str) -> str {
    slug: str = re.sub("[^a-z0-9]+", "-", hint.lower()).strip("-");
    return slug if slug else "misc";
}

"""[tasks.<task>] as a narrowed dict. Every level goes through as_dict: a raw
cfg["tasks"][task]["fragment"] fails `jac check` with E1001."""
def task_table(cfg: dict, task: str) -> dict {
    tasks: dict = as_dict(cfg["tasks"]);
    if task not in tasks {
        raise ValueError("finding names an unknown task: " + task);
    }
    return as_dict(tasks[task]);
}

"""What this finding costs against [budgets].loc_per_theme. A coverage finding budgets the lines
it ADDS; every other task budgets the lines it removes. Read off the finding, which already
carries exactly one of the two (parse_result.validate_finding deletes the other)."""
def budget_of(f: dict) -> int {
    return int(f["est_loc_added"]) if "est_loc_added" in f else int(f["est_loc_saved"]);
}

"""A theme is as expensive as its hardest finding: one judgement finding makes the whole apply
session judgement work, because it is one session over all of them."""
def theme_complexity(picked: list[dict]) -> str {
    levels: list[str] = [str(f.get("complexity", "judgement")) for f in picked];
    if "judgement" in levels {
        return "judgement";
    }
    if "mechanical" in levels {
        return "mechanical";
    }
    return "trivial";
}

"""jac's decl/impl split (X.jac <-> X.impl.jac, either same directory or an `impl/` subdirectory)
is a tightly-coupled pair: editing one without the other desyncs signatures from bodies and breaks
compilation. Confirmed live: an apply session correctly refused to touch a declaration file whose
impl file wasn't in the theme's scope, rather than risk exactly that. Returns candidate sibling
PATHS (no filesystem check -- pure string manipulation); harmless if a guess doesn't exist, since
only findings' own files ever actually drive an edit. Deliberately not repo-aware: unlike
vestigial_test_files below (which independently verifies before ever touching a protected path),
guessing a sibling wrong here has zero blast radius, so no verification is needed."""
def impl_siblings(file: str) -> list[str] {
    if file.endswith(".impl.jac") {
        base: str = file[:-len(".impl.jac")];
        parts: list[str] = base.rsplit("/", 1);
        if len(parts) == 2 and parts[0].endswith("/impl") {
            return [parts[0][:-len("/impl")] + "/" + parts[1] + ".jac"];
        }
        return [base + ".jac"];
    }
    if file.endswith(".jac") {
        base: str = file[:-len(".jac")];
        parts: list[str] = base.rsplit("/", 1);
        if len(parts) == 2 {
            return [base + ".impl.jac", parts[0] + "/impl/" + parts[1] + ".impl.jac"];
        }
        return [base + ".impl.jac"];
    }
    return [];
}

"""Eligibility (TPRD S3-B step 2). Returns a drop reason, or None when the finding is in play."""
def drop_reason(f: dict, ledger: dict[str, dict], globs: list[str]) -> str | None {
    fp: str = str(f["fingerprint"]);
    if is_protected(str(f["file"]), globs) {
        return "protected-path";
    }
    if fp in ledger {
        status: str = str(ledger[fp]["status"]);
        if status in ["shipped", "rejected", "drafted"] {
            return "ledger-" + status;
        }
        if status == "failed_verify" and int(ledger[fp].get("attempts", 0)) >= 2 {
            return "failed-verify-twice";
        }
    }
    return None;
}

"""Greedy pack (TPRD S3-B steps 3-4): group by (task, theme_hint), budget files/LOC per theme,
keep at most themes_per_night themes -- carried work first, then by total score."""
def pack_themes(eligible: list[dict], cfg: dict, repo_dir: str,
                 protect_globs: list[str]) -> (list[dict], list[dict]) {
    budgets: dict = as_dict(cfg["budgets"]);
    groups: dict[str, list[dict]] = {};
    for f in eligible {
        # Task-QUALIFIED slug. Two tasks legitimately produce the same theme_hint ("cli"), and
        # merging them would give one branch two tasks -- and therefore an ambiguous set of write
        # permissions at the S4 gate. It also makes the task recoverable from the branch name
        # alone (lib/common.sh ns_task_of_branch), which is the one place the agent cannot reach.
        slug: str = slugify(str(f["task"]) + "-" + str(f["theme_hint"]));
        if slug not in groups {
            groups[slug] = [];
        }
        groups[slug].append(f);
    }
    themes: list[dict] = [];
    dropped: list[dict] = [];
    for (slug, group) in groups.items() {
        group.sort(key=lambda f: dict -> tuple { return (-score_of(f), str(f["fingerprint"])); });
        task: str = str(group[0]["task"]);
        files: list[str] = [];
        picked: list[dict] = [];
        est_loc: int = 0;
        for f in group {
            file: str = str(f["file"]);
            new_file: int = 0 if file in files else 1;
            if len(files) + new_file > int(budgets["files_per_theme"])
               or est_loc + budget_of(f) > int(budgets["loc_per_theme"]) {
                dropped.append({"fingerprint": f["fingerprint"], "file": file, "rule": f["rule"], "reason": "over-theme-budget"});
                continue;
            }
            if new_file == 1 {
                files.append(file);
            }
            # The file the coverage agent intends to WRITE. Without it in the allow-list the theme
            # has no legal write target and the S4 gate discards the whole branch after a
            # 25-minute session. Not budgeted as a file slot: it is the point of the theme.
            if "test_file" in f and str(f["test_file"]) not in files {
                files.append(str(f["test_file"]));
            }
            picked.append(f);
            est_loc += budget_of(f);
        }
        if picked {
            # Pull each finding's file's decl/impl sibling into scope too, budget allowing --
            # a doomed-from-the-start partial edit (declaration without its impl) is worse than
            # one fewer file slot for something else.
            for f in list(files) {
                for sib in impl_siblings(f) {
                    if sib not in files and len(files) < int(budgets["files_per_theme"]) {
                        files.append(sib);
                    }
                }
            }
            vestigial: list[str] = [];
            # Vestigial test deletion belongs to the dead-code TASK only, and still only when every
            # finding in the theme is a dead-code rule. Both conditions, not one: the rule vocabulary
            # is a single union across tasks now, so the task check alone would let an abstraction-
            # flavoured finding inside a dead-code theme widen what gets deleted, and the rule check
            # alone would let an abstraction theme carrying a dead-code rule unlock the sweep.
            if task == "dead-code" and all([str(f["rule"]) == "dead-code" for f in picked]) {
                vestigial = vestigial_test_files(repo_dir, files, protect_globs);
            }
            themes.append({
                "name": str(picked[0]["theme_hint"]), "slug": slug, "task": task,
                "complexity": theme_complexity(picked),
                "fragment_kind": str(task_table(cfg, task)["fragment"]),
                "carry": any([bool(f.get("carry", False)) for f in picked]),
                "files": files, "vestigial_deletions": vestigial,
                "findings": picked, "est_loc": est_loc,
                "score": sum([score_of(f) for f in picked]),
            });
        }
    }
    # CARRIED THEMES FIRST, unconditionally -- ahead of tonight's own task, however well tonight's
    # scores (design spec 4). Work resumes across nights while the cycle still advances. fit_clock
    # sheds from the END, so this ordering also decides what survives a short night.
    themes.sort(key=lambda t: dict -> tuple {
        return (0 if t.get("carry", False) else 1, -as_float(t["score"]), str(t["slug"]));
    });
    for t in themes[int(budgets["themes_per_night"]):] {
        for f in as_list(t["findings"]) {
            dropped.append({"fingerprint": f["fingerprint"], "file": f["file"], "rule": as_dict(f)["rule"], "reason": "over-night-budget"});
        }
    }
    return (themes[:int(budgets["themes_per_night"])], dropped);
}

"""Time projection (TPRD S3-B step 5): each theme costs apply_timeout + verify_estimate;
shed the lowest-scored themes until the projection fits the remaining clock."""
def fit_clock(themes: list[dict], dropped: list[dict], budgets: dict,
              verify_estimate: int, remaining_min: int) -> (list[dict], list[dict]) {
    per_theme: int = int(budgets["apply_timeout_min"]) + verify_estimate;
    while themes and len(themes) * per_theme > remaining_min {
        shed: dict = themes.pop();
        for f in as_list(shed["findings"]) {
            dropped.append({"fingerprint": f["fingerprint"], "file": f["file"], "rule": as_dict(f)["rule"], "reason": "no-clock-left"});
        }
    }
    return (themes, dropped);
}

def select(findings: list[dict], config_path: str, ledger_path: str,
           state_path: str, remaining_min: int, repo_dir: str) -> dict {
    cfg: dict = load_config_toml(config_path);
    budgets: dict = as_dict(cfg["budgets"]);
    globs: list[str] = load_globs(config_path);
    ledger: dict[str, dict] = load_ledger(ledger_path);
    verify_estimate: int = int(state_read(state_path).get("verify_estimate_min", 30));

    eligible: list[dict] = [];
    dropped: list[dict] = [];
    for f in findings {
        f["fingerprint"] = fingerprint(str(f["file"]), str(f["rule"]));
        f["score"] = score_of(f);
        reason: str | None = drop_reason(f, ledger, globs);
        if reason is None {
            eligible.append(f);
        } else {
            dropped.append({"fingerprint": f["fingerprint"], "file": f["file"], "rule": f["rule"], "reason": reason});
        }
    }
    (themes, dropped2) = pack_themes(eligible, cfg, repo_dir, globs);
    (themes2, dropped3) = fit_clock(themes, dropped2, budgets, verify_estimate, remaining_min);
    all_dropped: list[dict] = dropped + dropped3;

    # Carry-over (design spec 4). Only the two "it fitted a theme but not the night" reasons are
    # carried. over-theme-budget is deliberately excluded: such a finding is too big for ANY theme,
    # so carrying it would re-drop it for the same reason every night, forever, while the file grew.
    # protected-path and the ledger reasons are terminal by definition.
    index: dict[str, dict] = {};
    for f in findings {
        index[str(f["fingerprint"])] = f;
    }
    carryover: list[dict] = [];
    for d in all_dropped {
        if str(d["reason"]) in ["over-night-budget", "no-clock-left"] {
            item: dict = as_dict(index.get(str(d["fingerprint"]), {}));
            if item {
                item["carry"] = True;
                carryover.append(item);
            }
        }
    }
    return {"themes": themes2, "dropped": all_dropped, "carryover": carryover};
}

with entry {
    args: list[str] = sys.argv;
    if len(args) == 7 and args[1] == "select" {
        raw: list = parse_list(read_stdin());
        findings: list[dict] = [f for f in raw if isinstance(f, dict)];
        print(json.dumps(select(findings, args[2], args[3], args[4], int(args[5]), args[6])));
    } elif args[1] == "split" and len(args) == 4 if len(args) > 1 else False {
        with open(args[2], "r") as f {
            selection: dict = parse_obj(f.read());
        }
        for t in as_list(selection["themes"]) {
            theme: dict = as_dict(t);
            out_path: str = args[3] + "/theme-" + str(theme["slug"]) + ".json";
            with open(out_path, "w") as f2 {
                f2.write(json.dumps(theme) + "\n");
            }
            print(theme["slug"]);
        }
    } elif args[1] == "dropped" and len(args) == 3 if len(args) > 1 else False {
        with open(args[2], "r") as f {
            selection2: dict = parse_obj(f.read());
        }
        for d in as_list(selection2["dropped"]) {
            item: dict = as_dict(d);
            print(str(item["fingerprint"]) + "\t" + str(item["file"]) + "\t" + str(item["reason"]));
        }
    } elif len(args) > 1 and args[1] != "test" {
        eprint("usage: ... findings.json | jac run selector.jac select <config.toml> <ledger.jsonl> <state.json> <remaining_min> <repo_dir>");
        eprint("       jac run selector.jac split <selection.json> <outdir>");
        eprint("       jac run selector.jac dropped <selection.json>");
    }
}

"""Two [tasks.*] tables, appended to every inline test config. select() now reads
[tasks.<task>].fragment for every finding it packs, so a config without them is not a valid
selector input any more."""
glob TEST_TASKS: str = "[tasks.dead-code]\nponytail=\"full\"\nscoring=\"loc_saved\"\nfragment=\"refactor\"\n[tasks.abstraction]\nponytail=\"full\"\nscoring=\"loc_saved\"\nfragment=\"refactor\"\n[tasks.coverage]\nponytail=\"lite\"\nscoring=\"risk_weighted\"\nfragment=\"\"\n";

test "packing respects caps, drops ledger-known and protected findings" {
    import tempfile;
    body: str = "[budgets]\nthemes_per_night = 2\nfiles_per_theme = 2\nloc_per_theme = 100\napply_timeout_min = 25\n[protect]\nglobs = [\"**/tests/**\"]\n" + TEST_TASKS;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    def mk(file: str, hint: str, loc: int, task: str, rule: str) -> dict {
        return {"file": file, "rule": rule, "snippet": "s " + file, "summary": "x", "task": task,
                "est_loc_saved": loc, "confidence": 4, "risk": 2, "theme_hint": hint,
                "complexity": "trivial"};
    }
    findings: list[dict] = [
        mk("pkg/a.jac", "dead code", 40, "dead-code", "dead-code"),
        mk("pkg/b.jac", "dead code", 40, "dead-code", "dead-code"),
        mk("pkg/c.jac", "dead code", 40, "dead-code", "dead-code"),   # third file: over files_per_theme=2
        mk("pkg/tests/f.jac", "dead code", 40, "dead-code", "dead-code"),   # protected
        mk("pkg/d.jac", "dup", 30, "abstraction", "duplication"),
    ];
    result: dict = select(findings, cfg_path, "/nonexistent-ledger", "/nonexistent-state", 999, "/nonexistent-repo");
    assert len(as_list(result["themes"])) == 2;
    reasons: list[str] = [str(d["reason"]) for d in as_list(result["dropped"])];
    assert "protected-path" in reasons;
    assert "over-theme-budget" in reasons;
}

test "themes are task-scoped: same theme_hint from two tasks never merges into one theme" {
    import tempfile;
    body: str = "[budgets]\nthemes_per_night = 4\nfiles_per_theme = 5\nloc_per_theme = 500\napply_timeout_min = 25\n[protect]\nglobs = []\n" + TEST_TASKS;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    findings: list[dict] = [
        {"file": "p/a.jac", "rule": "dead-code", "snippet": "s", "summary": "x", "task": "dead-code",
         "est_loc_saved": 40, "confidence": 4, "risk": 2, "theme_hint": "cli", "complexity": "trivial"},
        {"file": "p/b.jac", "rule": "missing-test", "snippet": "s", "summary": "x", "task": "coverage",
         "gap_severity": 40, "est_loc_added": 60, "test_file": "jac/tests/test_b.jac",
         "confidence": 4, "risk": 2, "theme_hint": "cli", "complexity": "judgement"},
    ];
    result: dict = select(findings, cfg_path, "/nonexistent", "/nonexistent", 999, "/nonexistent-repo");
    slugs: list[str] = sorted([str(as_dict(t)["slug"]) for t in as_list(result["themes"])]);
    assert slugs == ["coverage-cli", "dead-code-cli"];
    for t in as_list(result["themes"]) {
        theme: dict = as_dict(t);
        if str(theme["task"]) == "coverage" {
            assert str(theme["fragment_kind"]) == "";
            assert str(theme["complexity"]) == "judgement";
            # the intended test file is pulled into scope; without it the theme cannot write at all
            assert "jac/tests/test_b.jac" in [str(f) for f in as_list(theme["files"])];
            assert int(theme["est_loc"]) == 60;          # budgets est_loc_added, not gap_severity
        } else {
            assert str(theme["fragment_kind"]) == "refactor";
            assert int(theme["est_loc"]) == 40;
            assert str(theme["complexity"]) == "trivial";
        }
    }
}

test "carry-over: deferred findings are emitted, and pack FIRST the next night" {
    import tempfile;
    body: str = "[budgets]\nthemes_per_night = 1\nfiles_per_theme = 5\nloc_per_theme = 500\napply_timeout_min = 25\n[protect]\nglobs = []\n" + TEST_TASKS;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    def mk(hint: str, loc: int) -> dict {
        return {"file": "p/" + hint + ".jac", "rule": "dead-code", "snippet": "s", "summary": "x",
                "task": "dead-code", "est_loc_saved": loc, "confidence": 5, "risk": 1,
                "theme_hint": hint, "complexity": "trivial"};
    }
    # themes_per_night = 1, so the smaller theme is dropped over-night-budget and carried
    night1: dict = select([mk("big", 200), mk("small", 10)], cfg_path,
                          "/nonexistent", "/nonexistent", 999, "/nonexistent-repo");
    carried: list[dict] = [as_dict(c) for c in as_list(night1["carryover"])];
    assert len(carried) == 1;
    assert str(carried[0]["theme_hint"]) == "small";
    assert carried[0]["carry"] == True;

    # night 2: the carried finding is packed FIRST even though tonight's finding scores higher
    night2: dict = select(carried + [mk("huge", 500)], cfg_path,
                          "/nonexistent", "/nonexistent", 999, "/nonexistent-repo");
    themes2: list = as_list(night2["themes"]);
    assert str(as_dict(themes2[0])["slug"]) == "dead-code-small";
    assert as_dict(themes2[0])["carry"] == True;
    # ...and the ordering is only meaningful because the un-carried one really does score higher:
    # without this, a sort that ignored `carry` entirely could still pass by accident.
    assert as_float(as_dict(themes2[0])["score"]) < as_float(score_of(mk("huge", 500)));
}

test "carried work survives a short night: fit_clock sheds tonight's theme, not yesterday's" {
    # The reason pack_themes sorts carry-first rather than just prepending: fit_clock sheds from
    # the END, so the ordering is what decides who survives a clock squeeze, not just who is listed
    # first in a report nobody reads.
    import tempfile;
    body: str = "[budgets]\nthemes_per_night = 3\nfiles_per_theme = 5\nloc_per_theme = 500\napply_timeout_min = 25\n[protect]\nglobs = []\n" + TEST_TASKS;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    carried: dict = {"file": "p/old.jac", "rule": "dead-code", "snippet": "s", "summary": "x",
                     "task": "dead-code", "est_loc_saved": 5, "confidence": 1, "risk": 5,
                     "theme_hint": "old", "complexity": "trivial", "carry": True};
    tonight: dict = {"file": "p/new.jac", "rule": "dead-code", "snippet": "s", "summary": "x",
                     "task": "dead-code", "est_loc_saved": 400, "confidence": 5, "risk": 1,
                     "theme_hint": "new", "complexity": "trivial"};
    # 60 min remaining, default verify_estimate 30 -> 55 per theme -> exactly one theme fits
    result: dict = select([carried, tonight], cfg_path, "/nonexistent", "/nonexistent", 60,
                          "/nonexistent-repo");
    themes: list = as_list(result["themes"]);
    assert len(themes) == 1;
    assert str(as_dict(themes[0])["slug"]) == "dead-code-old";
    assert any([str(d["reason"]) == "no-clock-left" for d in as_list(result["dropped"])]);
}

test "over-theme-budget findings are NOT carried: they never fit, and would carry forever" {
    import tempfile;
    body: str = "[budgets]\nthemes_per_night = 4\nfiles_per_theme = 5\nloc_per_theme = 50\napply_timeout_min = 25\n[protect]\nglobs = []\n" + TEST_TASKS;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    too_big: list[dict] = [{"file": "p/a.jac", "rule": "dead-code", "snippet": "s", "summary": "x",
        "task": "dead-code", "est_loc_saved": 900, "confidence": 5, "risk": 1,
        "theme_hint": "whale", "complexity": "trivial"}];
    result: dict = select(too_big, cfg_path, "/nonexistent", "/nonexistent", 999, "/nonexistent-repo");
    assert [str(d["reason"]) for d in as_list(result["dropped"])] == ["over-theme-budget"];
    assert as_list(result["carryover"]) == [];
}

test "a finding naming an undeclared task is fatal, not silently packed" {
    import tempfile;
    body: str = "[budgets]\nthemes_per_night = 4\nfiles_per_theme = 5\nloc_per_theme = 500\napply_timeout_min = 25\n[protect]\nglobs = []\n" + TEST_TASKS;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    bogus: list[dict] = [{"file": "p/a.jac", "rule": "dead-code", "snippet": "s", "summary": "x",
        "task": "coverage-but-evil", "est_loc_saved": 10, "confidence": 5, "risk": 1,
        "theme_hint": "t", "complexity": "trivial"}];
    raised: bool = False;
    try {
        select(bogus, cfg_path, "/nonexistent", "/nonexistent", 999, "/nonexistent-repo");
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "impl_siblings covers same-dir and impl/ subdirectory decl<->impl pairing" {
    assert "jac/jaclang/scale/gw/embedded_gateway.impl.jac" in impl_siblings("jac/jaclang/scale/gw/embedded_gateway.jac");
    assert "jac/jaclang/scale/gw/impl/embedded_gateway.impl.jac" in impl_siblings("jac/jaclang/scale/gw/embedded_gateway.jac");
    assert impl_siblings("jac/jaclang/cli/commands/impl/mcp.impl.jac") == ["jac/jaclang/cli/commands/mcp.jac"];
    assert impl_siblings("plain.jac") == ["plain.impl.jac"];
    assert impl_siblings("no_extension") == [];
}

test "packing pulls a finding's impl sibling into theme scope" {
    import tempfile;
    body: str = "[budgets]\nthemes_per_night = 1\nfiles_per_theme = 3\nloc_per_theme = 100\napply_timeout_min = 25\n[protect]\nglobs = []\n" + TEST_TASKS;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    findings: list[dict] = [{"file": "gw/gateway.jac", "rule": "dead-code", "snippet": "s",
        "summary": "x", "task": "dead-code", "est_loc_saved": 40, "confidence": 4, "risk": 2,
        "theme_hint": "gw", "complexity": "trivial"}];
    result: dict = select(findings, cfg_path, "/nonexistent-ledger", "/nonexistent-state", 999, "/nonexistent-repo");
    themes: list[dict] = as_list(result["themes"]);
    assert len(themes) == 1;
    files: list[str] = [str(f) for f in as_list(as_dict(themes[0])["files"])];
    assert "gw/gateway.jac" in files;
    assert "gw/gateway.impl.jac" in files;
}

test "is_vestigial: pure test of the theme's own files passes, any other project import fails closed" {
    import tempfile;
    repo: str = tempfile.mkdtemp();
    import os as _os;
    _os.makedirs(repo + "/jac/pkg/tests");
    with open(repo + "/jac/pkg/tests/test_only.jac", "w") as f {
        f.write("import os;\nimport from jaclang.pkg.gateway { Gateway }\nimport from jaclang.pkg.transport { Transport }\n");
    }
    with open(repo + "/jac/pkg/tests/test_and_other.jac", "w") as f {
        f.write("import from jaclang.pkg.gateway { Gateway }\nimport from jaclang.pkg.unrelated_service { Service }\n");
    }
    stems: set[str] = {"gateway", "transport"};
    assert is_vestigial(repo, "jac/pkg/tests/test_only.jac", stems) == True;
    assert is_vestigial(repo, "jac/pkg/tests/test_and_other.jac", stems) == False;
}

test "vestigial_test_files discovers the pure candidate, skips the mixed one, ignores non-dead-code themes" {
    import tempfile;
    import os as _os;
    repo: str = tempfile.mkdtemp();
    _os.makedirs(repo + "/jac/pkg/tests");
    with open(repo + "/jac/pkg/gateway.jac", "w") as f {
        f.write("obj Gateway {}\n");
    }
    with open(repo + "/jac/pkg/tests/test_only.jac", "w") as f {
        f.write("import from jaclang.pkg.gateway { Gateway }\n");
    }
    with open(repo + "/jac/pkg/tests/test_and_other.jac", "w") as f {
        f.write("import from jaclang.pkg.gateway { Gateway }\nimport from jaclang.pkg.unrelated { X }\n");
    }
    found: list[str] = vestigial_test_files(repo, ["jac/pkg/gateway.jac"], ["**/tests/**"]);
    assert found == ["jac/pkg/tests/test_only.jac"];

    body: str = "[budgets]\nthemes_per_night = 1\nfiles_per_theme = 5\nloc_per_theme = 100\napply_timeout_min = 25\n[protect]\nglobs = [\"**/tests/**\"]\n" + TEST_TASKS;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    dead: list[dict] = [{"file": "jac/pkg/gateway.jac", "rule": "dead-code", "snippet": "s",
        "summary": "x", "task": "dead-code", "est_loc_saved": 10, "confidence": 5, "risk": 1,
        "theme_hint": "gw", "complexity": "trivial"}];
    result: dict = select(dead, cfg_path, "/nonexistent-ledger", "/nonexistent-state", 999, repo);
    theme: dict = as_dict(as_list(result["themes"])[0]);
    assert as_list(theme["vestigial_deletions"]) == ["jac/pkg/tests/test_only.jac"];

    # a duplication (non-dead-code) finding must never get vestigial deletions, even same file
    dup: list[dict] = [{"file": "jac/pkg/gateway.jac", "rule": "duplication", "snippet": "s2",
        "summary": "x", "task": "abstraction", "est_loc_saved": 10, "confidence": 5, "risk": 1,
        "theme_hint": "gw2", "complexity": "trivial"}];
    result2: dict = select(dup, cfg_path, "/nonexistent-ledger", "/nonexistent-state", 999, repo);
    theme2: dict = as_dict(as_list(result2["themes"])[0]);
    assert as_list(theme2["vestigial_deletions"]) == [];

    # BOTH conditions, not one. The rule vocabulary is a single union across tasks now, so a
    # dead-code RULE arriving on a non-dead-code TASK must not unlock the sweep either -- and a
    # dead-code task with a non-dead-code rule mixed in must not widen what gets deleted.
    wrong_task: list[dict] = [{"file": "jac/pkg/gateway.jac", "rule": "dead-code", "snippet": "s3",
        "summary": "x", "task": "abstraction", "est_loc_saved": 10, "confidence": 5, "risk": 1,
        "theme_hint": "gw3", "complexity": "trivial"}];
    result3: dict = select(wrong_task, cfg_path, "/nonexistent-ledger", "/nonexistent-state", 999, repo);
    assert as_list(as_dict(as_list(result3["themes"])[0])["vestigial_deletions"]) == [];
    mixed: list[dict] = [
        {"file": "jac/pkg/gateway.jac", "rule": "dead-code", "snippet": "s4", "summary": "x",
         "task": "dead-code", "est_loc_saved": 10, "confidence": 5, "risk": 1,
         "theme_hint": "gw4", "complexity": "trivial"},
        {"file": "jac/pkg/gateway.jac", "rule": "simplify", "snippet": "s5", "summary": "x",
         "task": "dead-code", "est_loc_saved": 10, "confidence": 5, "risk": 1,
         "theme_hint": "gw4", "complexity": "trivial"},
    ];
    result4: dict = select(mixed, cfg_path, "/nonexistent-ledger", "/nonexistent-state", 999, repo);
    assert as_list(as_dict(as_list(result4["themes"])[0])["vestigial_deletions"]) == [];
}

test "clock shedding removes lowest-scored theme" {
    import tempfile;
    body: str = "[budgets]\nthemes_per_night = 3\nfiles_per_theme = 10\nloc_per_theme = 300\napply_timeout_min = 25\n[protect]\nglobs = []\n" + TEST_TASKS;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    findings: list[dict] = [
        {"file": "p/a.jac", "rule": "dead-code", "snippet": "a", "summary": "x",
         "task": "dead-code", "est_loc_saved": 100, "confidence": 5, "risk": 1,
         "theme_hint": "big", "complexity": "trivial"},
        {"file": "p/b.jac", "rule": "simplify", "snippet": "b", "summary": "x",
         "task": "abstraction", "est_loc_saved": 5, "confidence": 2, "risk": 3,
         "theme_hint": "small", "complexity": "trivial"},
    ];
    # remaining 60 min, default verify_estimate 30 → per-theme 55 → only 1 theme fits
    result: dict = select(findings, cfg_path, "/nonexistent", "/nonexistent", 60, "/nonexistent-repo");
    assert len(as_list(result["themes"])) == 1;
    assert as_list(result["themes"])[0]["slug"] == "dead-code-big";
    assert any([str(d["reason"]) == "no-clock-left" for d in as_list(result["dropped"])]);
    # the shed theme is carried, so a short night defers work rather than losing it
    assert [str(as_dict(c)["theme_hint"]) for c in as_list(result["carryover"])] == ["small"];
}
