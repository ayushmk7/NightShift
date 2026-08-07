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

"""One symbol declaration line, as the audit prompts require the snippet to be: `def foo(...)`,
`impl Owner.method {`, `obj Thing {`, `enum E {`. Group 2 is the method name when the snippet is an
`impl Owner.method` -- that name, not the owner, is what the deletion removes."""
glob DECL_RE: str = "^\\s*(?:impl|def|can|obj|class|node|edge|walker|enum|glob|let|has)\\s+([A-Za-z_]\\w*)(?:\\.([A-Za-z_]\\w*))?";

"""Either `import <dotted.path>;` or `import from <dotted.path> { a, b as c }`. The brace list is
matched across newlines on purpose: jac/tests/compiler/test_abi_lib.jac opens its brace on the
import line and lists the names below it, and a line-anchored parse misses exactly those."""
glob IMPORT_RE: str = "import\\s+(?:from\\s+)?([\\w.]+)\\s*(?:\\{([^}]*)\\})?";

"""The symbols a dead-code theme intends to DELETE, read off each finding's own verbatim snippet."""
def deleted_symbols(picked: list[dict]) -> set[str] {
    out: set[str] = set();
    for f in picked {
        for line in str(f.get("snippet", "")).splitlines() {
            m = re.match(DECL_RE, line);
            if m is None {
                continue;
            }
            method: any = m.group(2);
            out.add(str(method) if method is not None else str(m.group(1)));
        }
    }
    return out;
}

"""True iff this file reaches one of `symbols` THROUGH an import of one of this theme's own modules.

Two conditions, and the conjunction is the whole point:
  1. an import statement here names one of the theme's file stems -- as a dotted segment
     (`import from jaclang.project.config { ... }`) or as a braced member
     (`import from jaclang.cli.commands { execution as exec_cmds }`, where the module IS the member);
  2. and that import binds a name which either IS a deleted symbol, or is a receiver `X` for which
     `X.<symbol>` appears in the file.

Condition 2 alone is a word-grep and over-matches catastrophically on ordinary method names --
see blocking_test_files. Condition 1 alone matches any test that touches the same module."""
def references_theme_symbol(repo_dir: str, rel: str, stems: set[str], symbols: set[str]) -> bool {
    try {
        with open(repo_dir + "/" + rel, "r") as f {
            content: str = f.read();
        }
    } except Exception {
        return False;
    }
    for m in re.finditer(IMPORT_RE, content) {
        raw: any = m.group(2);
        origs: list[str] = [];
        bounds: list[str] = [];
        for part in (str(raw) if raw is not None else "").split(",") {
            bits: list[str] = part.split();
            if not bits {
                continue;
            }
            origs.append(str(bits[0]));
            bounds.append(str(bits[2]) if len(bits) >= 3 and bits[1] == "as" else str(bits[0]));
        }
        reaches: bool = False;
        for seg in str(m.group(1)).split(".") {
            if seg in stems {
                reaches = True;
            }
        }
        for o in origs {
            if o in stems {
                reaches = True;
            }
        }
        if not reaches {
            continue;
        }
        for i in range(len(bounds)) {
            if origs[i] in symbols or bounds[i] in symbols {
                return True;
            }
            for s in symbols {
                if re.search("\\b" + re.escape(bounds[i]) + "\\." + re.escape(s) + "\\b", content) is not None {
                    return True;
                }
            }
        }
    }
    return False;
}

"""Protected test files that make this dead-code theme IMPOSSIBLE to apply, not merely awkward.

WHAT THIS PREVENTS, measured: five of the eleven apply sessions on 2026-07-31 -- 25 minutes and
~$0.45 each, plus a ~20-minute S4 mirror they never reached -- ended in "no changes made". Every one
of the five reports names the same blocker: the symbol the finding asks to delete is still imported
by a file under **/tests/**, the theme may neither edit nor delete that file, so there is no legal
diff. Verbatim from report-dead-code-test-only-abi-helper.json: "Removing `scalar_layout` from
abi.jac without also removing/editing that test would break its import ... which the harness would
reject wholesale". The selector can see this before spending anything: it is one grep.

WHY NOT THE OBVIOUS VERSION -- reusing vestigial_test_files' own grep and treating its discarded
non-vestigial matches as blockers. Because that grep is by FILE STEM, matched as a regex anywhere in
any .jac file under jac/. Counted against the real 2026-07-31 themes, the number of protected files
it matches per theme is 2, 17, 36, 46, 66, 122, 125, 135, 206 and 280. Treating those as blockers
drops all eleven dead-code themes -- INCLUDING ALL SIX THAT SHIPPED. The stem grep answers "does any
test mention a word that appears in this theme's filenames", which is not the question.

WHY NOT A PLAIN SYMBOL WORD-GREP either: it is right for `_tool_site_dirs` and `scalar_layout` and
wrong for `clear` and `is_empty` (dead-code-unused-registry-methods, which SHIPPED) -- `.clear()` is
on every dict in the repo. The import binding is what ties the reference to this theme's module.

The conjunction gets all eleven right: the five that could not ship are blocked, the six that
shipped are not. bin/test-harness.sh section 31 pins both directions over the real artifacts.

DO NOT "FIX" THIS BY WIDENING THE THEME INSTEAD (night-analysis.md:303-308 proposes adding the test
file to the theme's `files`). It cannot work and it costs more than doing nothing:
check_scope.jac:90 rejects any changed path matching a protected glob unless the TASK carries
`protect_unless`, and only [tasks.coverage] does; the `vestigial_deletions` bypass in the same file
accepts a whole-file delete only (`status != "D"` is a violation), and every one of these five needs
a partial edit -- each blocking test file also covers live APIs the theme keeps. So the widened
theme burns a 25-minute apply session AND a ~20-minute mirror and is then discarded at the S4 gate.
Strictly worse than today's no-op, which is why the drop is terminal here instead."""
def blocking_test_files(repo_dir: str, theme_files: list[str], symbols: set[str],
                        protect_globs: list[str]) -> list[str] {
    stems: set[str] = set([file_stem(f) for f in theme_files]);
    if not symbols or not stems or not os.path.isdir(repo_dir + "/jac") {
        return [];
    }
    # -w, so `clear` never matches `clear_cache`; the symbols are [A-Za-z_]\w* by construction, so
    # the alternation needs no escaping.
    found = subprocess.run(
        ["grep", "-rlwE", "|".join(sorted(symbols)), repo_dir + "/jac", "--include=*.jac"],
        capture_output=True, text=True);
    out: list[str] = [];
    for line in found.stdout.splitlines() {
        rel: str = line[len(repo_dir) + 1:] if line.startswith(repo_dir + "/") else line;
        if is_protected(rel, protect_globs) and references_theme_symbol(repo_dir, rel, stems, symbols) {
            out.append(rel);
        }
    }
    return sorted(out);
}

def slugify(hint: str) -> str {
    slug: str = re.sub("[^a-z0-9]+", "-", hint.lower()).strip("-");
    return slug if slug else "misc";
}

"""The directory a finding's file lives in, with the repo's invariant prefix removed so the slug
that comes out of it is readable in a branch name."""
def theme_dir(file: str) -> str {
    parts: list[str] = file.rsplit("/", 1);
    d: str = parts[0] if len(parts) == 2 else "";
    for prefix in ["jac/jaclang/", "jac/"] {
        if d.startswith(prefix) {
            return d[len(prefix):];
        }
    }
    return d if d else "root";
}

"""WHAT DECIDES WHICH FINDINGS SHARE AN APPLY SESSION: the task, and the DIRECTORY the finding's
file sits in. Not theme_hint.

theme_hint is a free-text slug each audit session invents per finding, and on 2026-07-31 it invented
a nearly-unique one every time: 112 findings became 105 groups, 99 of them singletons, 3 with two
findings and 1 with three. The selector then packed 105 themes, kept themes_per_night of them, and
deferred 103 findings as `over-night-budget` while the night had used 56 of its 480 minutes. Every
one of those 103 was already paid for -- $38.36 of shard audit and $28.72 of reactive lens -- and
converting that spend into shipped PRs is what this key is for.

RAISING themes_per_night DOES NOT FIX IT, which is why that lever was pulled and this one is still
needed: the carry queue is 99 THEMES, so at any per-night ceiling the backlog diverges. The only
thing that closes the gap is more findings per theme.

WHY THE DIRECTORY AND NOT THE FILE: grouping by file gives 102 groups for those same 112 findings
(92 singletons) -- it barely moves. The directory gives 51, with the largest holding 12. It is also
the natural review unit: one PR touching one directory is one reviewer's context, and TechnicalPRD
step S3-B-4 already specifies "group by theme_hint, then directory".

The key stays TASK-QUALIFIED. Two tasks legitimately produce findings in the same directory, and
merging them would give one branch two tasks -- and therefore an ambiguous set of write permissions
at the S4 gate -- as well as breaking lib/common.sh ns_task_of_branch, which recovers the task from
the branch name by PREFIX and is the one channel the agent cannot reach."""
def group_key(f: dict) -> str {
    return slugify(str(f["task"]) + "-" + theme_dir(str(f["file"])));
}

"""Which already-applied branch a theme must be stacked on, given every file slot the night has
already claimed (`<branch>\\tab<file>` rows, in the order the branches were applied).

Returns the LAST claiming branch, not the first. `claims` is append-ordered, so the last entry is
the tip of whatever chain already owns these files -- basing on an earlier link would fork the
stack and reintroduce the conflict stacking exists to remove. Returns "" for no overlap, which
lib/common.sh's ns_base_of_branch reads as $NS_REPO_DEFAULT_BRANCH: the pre-stacking behaviour, and
what the overwhelming majority of themes get, since one night's cycle themes are disjoint by
construction (group_key is task + DIRECTORY, and a file sits in exactly one directory).

The overlap this really exists for is the REACTIVE pass, which runs all four task lenses over the
same merged file set and therefore produces up to four themes claiming identical files.

Rows that do not split into exactly two fields are SKIPPED, not fatal: this reads a file the
orchestrator appends to while branches are being applied, and a torn final line must not take the
night down. A skipped row can only lose a stack edge, never invent one."""
def stack_base(files: list[str], claims: list[str]) -> str {
    want: set[str] = set(files);
    winner: str = "";
    for line in claims {
        parts: list[str] = line.split("\t");
        if len(parts) != 2 {
            continue;
        }
        if parts[1] in want {
            winner = parts[0];
        }
    }
    return winner;
}

"""A packed theme projected back into the carry-over stream: its findings, carry-flagged, in the
EXACT shape select() puts in selection.json's `carryover` field.

Exists because select()'s carryover only knows about findings that never got packed. A theme that
WAS packed and selected and then deferred at APPLY time -- by the clock guard or the night cost
ceiling in lib/tier2.sh's tier2_apply -- used to leave a failed.tsv row and nothing else: no
in_theme ledger row (that is written only after a session succeeds), and no entry in
state/carryover.json (written by tier2_select, before apply runs). Its findings were simply gone
from the system's memory, which is this project's "did not run scored as passed" defect wearing an
apply guard's clothes -- the money brake landed 2026-08-04 and would have started silently
deleting themes the moment it fired.

`carry` is what makes them pack FIRST tomorrow (pack_themes sorts on it), and it is the only field
added -- the findings already carry fingerprint and score, stamped by select() before they were
ever packed, so a reader cannot tell one of these from a selection-time carry-over entry.

EMPTY IS AN ERROR, not an empty list. pack_themes only ever builds a theme from a non-empty
bucket, so a theme with no findings is malformed; returning [] would let the caller merge nothing
and log success, which is the exact silent-vanishing this function exists to stop."""
def carry_findings(theme: dict) -> list[dict] {
    out: list[dict] = [];
    for f in as_list(theme["findings"]) {
        item: dict = as_dict(f);
        item["carry"] = True;
        out.append(item);
    }
    if not out {
        raise ValueError("theme " + str(theme.get("slug", "?")) + " carries no findings to defer");
    }
    return out;
}

"""The human-facing theme name (the digest's only use of it): the group key with its task prefix
removed, so a theme reads as `compiler-type-system` rather than repeating the task."""
def group_name(key: str, task: str) -> str {
    prefix: str = slugify(task) + "-";
    return key[len(prefix):] if key.startswith(prefix) else key;
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
impl file wasn't in the theme's scope, rather than risk exactly that. Returns the candidate sibling
PATHS THAT ACTUALLY EXIST under repo_dir.

THE EXISTENCE CHECK IS NOT DEFENSIVE TIDYING, and the docstring this replaces was wrong on the
evidence. It claimed a wrong guess was "harmless" because "only findings' own files ever drive an
edit". Measured over the real 2026-07-31 selection (logs/2026-07-31/selection.json plus
selection-reactive.json): 14 of the 36 file slots across the 11 themes -- 39% -- were guessed
sibling paths that do not exist in the repo. Two costs, both real that night:

* Each one occupies a files_per_theme slot that a real file could have used. dead-code-
  unused-registry-methods spent 3 of its 6 slots on paths that are not there.
* The apply session pays to discover it. Three of the five sessions that shipped nothing spent part
  of their turn budget confirming non-existence and then said so in their report -- verbatim from
  report-dead-code-test-only-abi-helper.json: "I also confirmed the other two files listed in the
  theme, targets/abi.impl.jac and targets/impl/abi.impl.jac, do not exist in the repo".

repo_dir is passed rather than looked up because pack_themes already has it (vestigial_test_files
needs it), so this adds no new argument to the caller chain. When repo_dir is not a directory --
the unit tests' "/nonexistent-repo" -- nothing exists and no sibling is added, which is the honest
answer rather than a special case."""
def impl_siblings(file: str, repo_dir: str) -> list[str] {
    candidates: list[str] = [];
    if file.endswith(".impl.jac") {
        base: str = file[:-len(".impl.jac")];
        parts: list[str] = base.rsplit("/", 1);
        if len(parts) == 2 and parts[0].endswith("/impl") {
            candidates = [parts[0][:-len("/impl")] + "/" + parts[1] + ".jac"];
        } else {
            candidates = [base + ".jac"];
        }
    } elif file.endswith(".jac") {
        base2: str = file[:-len(".jac")];
        parts2: list[str] = base2.rsplit("/", 1);
        if len(parts2) == 2 {
            candidates = [base2 + ".impl.jac", parts2[0] + "/impl/" + parts2[1] + ".impl.jac"];
        } else {
            candidates = [base2 + ".impl.jac"];
        }
    }
    return [c for c in candidates if os.path.exists(repo_dir + "/" + c)];
}

"""Eligibility (TPRD S3-B step 2). Returns a drop reason, or None when the finding is in play.

repo_dir is here for `file-gone`, and that check is the finding's OWN file, which nothing used to
look at. impl_siblings has existence-checked its GUESSES since the 36-slot measurement below it,
but a guess is not the only path that can be wrong: the audit reads a clone, the clone is refreshed
before the next night, and upstream renames files between the two. Measured on the 2026-07-31
replay -- jac/jaclang/runtimelib/planner.jac was audited, upstream renamed it to query_planner.jac,
and the finding still packed a theme naming a path that is not on disk. The apply session pays a
model call, a branch and a 25-minute timeout to discover the file is gone and report "no changes
made", which is this project's "did not run scored as passed" defect at the file level.

TERMINAL, and deliberately so: select() carries only over-night-budget and no-clock-left, and
nothing about tomorrow puts a deleted path back. The finding does not need carrying -- the file is
gone, so the next audit over the refreshed clone either re-finds the issue at its new path (a new
fingerprint, since fingerprint() is keyed on the file) or does not find it at all. Carrying the
dead path instead would re-drop it for the same reason every night, forever.

STANDS DOWN when there is no tree to check against -- the unit tests' "/nonexistent-repo", a clone
that failed -- exactly as vestigial_test_files and blocking_test_files do, and on the same guard.
Dropping every finding because the clone is missing would silently ship nothing and report a clean
night, which is a far more expensive failure than the one this catches."""
def drop_reason(f: dict, ledger: dict[str, dict], globs: list[str], repo_dir: str) -> str | None {
    fp: str = str(f["fingerprint"]);
    if is_protected(str(f["file"]), globs) {
        return "protected-path";
    }
    if os.path.isdir(repo_dir + "/jac") and not os.path.exists(repo_dir + "/" + str(f["file"])) {
        return "file-gone";
    }
    if fp in ledger {
        status: str = str(ledger[fp]["status"]);
        # `in_theme` is the SAME-NIGHT case and is what dedupes reactive against cycle: the
        # reactive pass applies before the cycle phase selects, so by the time these findings are
        # scored a reactive branch may already exist for them. Without this the cycle phase pays a
        # second apply session to redo work that is already queued, and ships a second branch for
        # it. (Stacking keeps those two branches from conflicting; this keeps the second from being
        # bought at all. They solve different halves of the same overlap.)
        if status in ["shipped", "rejected", "drafted", "in_theme"] {
            return "ledger-" + status;
        }
        if status == "failed_verify" and int(ledger[fp].get("attempts", 0)) >= 2 {
            return "failed-verify-twice";
        }
    }
    return None;
}

"""Greedy pack (TPRD S3-B steps 3-4): group by (task, directory) -- see group_key -- budget
files/LOC per theme, SPILL an overflowing group into further themes rather than discarding the
overflow, and keep at most themes_per_night themes -- carried work first, then by total score."""
def pack_themes(eligible: list[dict], cfg: dict, repo_dir: str,
                 protect_globs: list[str]) -> (list[dict], list[dict]) {
    budgets: dict = as_dict(cfg["budgets"]);
    files_cap: int = int(budgets["files_per_theme"]);
    loc_cap: int = int(budgets["loc_per_theme"]);
    groups: dict[str, list[dict]] = {};
    for f in eligible {
        key: str = group_key(f);
        if key not in groups {
            groups[key] = [];
        }
        groups[key].append(f);
    }
    themes: list[dict] = [];
    dropped: list[dict] = [];
    for (key, group) in sorted(groups.items()) {
        group.sort(key=lambda f: dict -> tuple { return (-score_of(f), str(f["fingerprint"])); });
        task: str = str(group[0]["task"]);
        # SPILL, DO NOT DROP. The old loop `continue`d past any finding that did not fit the first
        # theme, tagging it `over-theme-budget` -- a reason select() deliberately does not carry, so
        # it was gone for good. That was survivable only because grouping by theme_hint made every
        # group tiny (105 groups for 112 findings on 2026-07-31, zero over-theme-budget rows: the
        # budgets bounded NOTHING). A directory-sized group overflows routinely -- the largest that
        # night held 12 findings -- so keeping the old `continue` would convert this change into a
        # machine for silently deleting real findings. A full bucket starts the next one instead.
        buckets: list[list[dict]] = [];
        bucket_files: list[list[str]] = [];
        cur: list[dict] = [];
        files: list[str] = [];
        est_loc: int = 0;
        for f in group {
            file: str = str(f["file"]);
            new_file: int = 0 if file in files else 1;
            # The file the coverage agent intends to WRITE also needs a slot, and must be counted
            # in the SAME overflow check as `file` -- otherwise a finding that exactly fills the
            # last file slot with `file` gets `test_file` appended right after with no gate at all.
            test_file: str = str(f["test_file"]) if "test_file" in f else "";
            new_test: int = 1 if test_file and test_file != file and test_file not in files else 0;
            if cur and (len(files) + new_file + new_test > files_cap or est_loc + budget_of(f) > loc_cap) {
                buckets.append(cur);
                bucket_files.append(files);
                cur = []; files = []; est_loc = 0; new_file = 1;
                new_test = 1 if test_file and test_file != file else 0;
            }
            # ...but a finding that does not fit an EMPTY theme does not fit any theme, ever. That
            # is the only case `over-theme-budget` now describes, and it is exactly the case the
            # carry-over exclusion in select() was written for: carrying it would re-drop it for the
            # same reason every night, forever, while the file grew.
            if len(files) + new_file + new_test > files_cap or est_loc + budget_of(f) > loc_cap {
                dropped.append({"fingerprint": f["fingerprint"], "file": file, "rule": f["rule"], "reason": "over-theme-budget"});
                continue;
            }
            if new_file == 1 {
                files.append(file);
            }
            # The file the coverage agent intends to WRITE. Without it in the allow-list the theme
            # has no legal write target and the S4 gate discards the whole branch after a
            # 25-minute session. Not budgeted as a file slot: it is the point of the theme.
            if new_test == 1 {
                files.append(test_file);
            }
            cur.append(f);
            est_loc += budget_of(f);
        }
        if cur {
            buckets.append(cur);
            bucket_files.append(files);
        }
        for idx in range(len(buckets)) {
            bucket: list[dict] = buckets[idx];
            bfiles: list[str] = bucket_files[idx];
            # Task-QUALIFIED slug, and the task must stay recoverable from the branch name alone
            # (lib/common.sh ns_task_of_branch resolves it BY PREFIX), which is the one place the
            # agent cannot reach. `-2`, `-3` ... disambiguate a group that spilled; without it two
            # themes would race for one branch name and one would overwrite the other's theme file.
            slug: str = key if idx == 0 else key + "-" + str(idx + 1);

            # BLOCKED-BY-PROTECTED-TEST, decided PER FINDING rather than per theme. Since the group
            # key is a whole directory, one un-applyable deletion would otherwise take every other
            # finding in that directory down with it -- turning a $2.27/night saving into a way to
            # lose good work. Only the blocked findings are dropped; whatever is left still ships.
            #
            # Restricted to the dead-code TASK with an all-dead-code rule set, the same two
            # conditions that gate the vestigial sweep below, and for the mirror-image reason: only
            # a DELETION can be blocked by a test that imports the symbol. An abstraction or
            # maintenance finding rewrites a body and leaves every import still resolving.
            picked: list[dict] = bucket;
            if task == "dead-code" and all([str(f["rule"]) == "dead-code" for f in bucket]) {
                picked = [];
                for f in bucket {
                    if blocking_test_files(repo_dir, bfiles, deleted_symbols([f]), protect_globs) {
                        # TERMINAL, like protected-path and the ledger reasons: nothing about
                        # tomorrow night makes this applicable, so carrying it would buy the same
                        # drop every night forever. The reason string is what reaches the digest
                        # (lib/tier2.sh tees it to deferred.jsonl), and that is the whole value -- a
                        # human unblocks it by editing the test, and cannot do that if the harness
                        # spends 25 minutes discovering it and then says nothing.
                        dropped.append({"fingerprint": f["fingerprint"], "file": f["file"],
                                        "rule": f["rule"], "reason": "blocked-by-protected-test"});
                    } else {
                        picked.append(f);
                    }
                }
            }
            if not picked {
                continue;
            }
            # The file list is rebuilt from what SURVIVED, so a dropped finding does not leave its
            # file occupying a slot (and does not widen the S4 gate's write permission for a file
            # nothing in the theme touches any more).
            tfiles: list[str] = [];
            for f in picked {
                if str(f["file"]) not in tfiles {
                    tfiles.append(str(f["file"]));
                }
                # The file the coverage agent intends to WRITE. Without it in the allow-list the
                # theme has no legal write target and the S4 gate discards the whole branch after a
                # 25-minute session. Not budgeted as a file slot: it is the point of the theme.
                if "test_file" in f and str(f["test_file"]) not in tfiles {
                    tfiles.append(str(f["test_file"]));
                }
            }
            # Pull each finding's file's decl/impl sibling into scope too, budget allowing --
            # a doomed-from-the-start partial edit (declaration without its impl) is worse than
            # one fewer file slot for something else. Only siblings that EXIST (see impl_siblings).
            for f2 in list(tfiles) {
                for sib in impl_siblings(f2, repo_dir) {
                    if sib not in tfiles and len(tfiles) < files_cap {
                        tfiles.append(sib);
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
                vestigial = vestigial_test_files(repo_dir, tfiles, protect_globs);
            }
            themes.append({
                "name": group_name(key, task), "slug": slug, "task": task,
                "complexity": theme_complexity(picked),
                "fragment_kind": str(task_table(cfg, task)["fragment"]),
                "carry": any([bool(f.get("carry", False)) for f in picked]),
                "files": tfiles, "vestigial_deletions": vestigial,
                "findings": picked, "est_loc": sum([budget_of(f) for f in picked]),
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
        reason: str | None = drop_reason(f, ledger, globs, repo_dir);
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
    # Every file slot every selected theme claims, `slug<TAB>file`, one per line. Exists so a reader
    # can check the selection's file list WITHOUT bash parsing JSON (global constraint) and without
    # one `jac run` per theme -- bin/test-harness.sh section 32 asserts that no theme names a path
    # that is not on disk, over four selections, and the per-theme form cost the harness ~7 minutes
    # of interpreter startup.
    } elif args[1] == "slots" and len(args) == 3 if len(args) > 1 else False {
        with open(args[2], "r") as f {
            selection3: dict = parse_obj(f.read());
        }
        for t2 in as_list(selection3["themes"]) {
            theme2: dict = as_dict(t2);
            for path in as_list(theme2["files"]) {
                print(str(theme2["slug"]) + "\t" + str(path));
            }
        }
    # One deferred-at-apply theme, projected back into the carry-over stream as a findings ARRAY --
    # the same shape `parse_result merge` consumes and `parse_result field carryover` emits, so
    # lib/tier2.sh can append it to state/carryover.json with the reader it already uses. See
    # carry_findings; a theme with no findings exits nonzero rather than emitting `[]`.
    } elif args[1] == "carryover" and len(args) == 3 if len(args) > 1 else False {
        with open(args[2], "r") as f {
            theme5: dict = parse_obj(f.read());
        }
        print(json.dumps(carry_findings(theme5)));
    # Which already-applied branch this theme must be stacked on, or nothing for "cut from main".
    } elif args[1] == "stack-base" and len(args) == 4 if len(args) > 1 else False {
        with open(args[2], "r") as f {
            theme3: dict = parse_obj(f.read());
        }
        # Absent claims file = the first theme of the night has nothing to stack on. NOT an error,
        # and specifically not one that should abort: lib/tier2.sh reads this on stdout and would
        # otherwise take an empty result as "no base" anyway -- but via a nonzero rc under errexit,
        # which kills the apply loop before a single theme runs.
        claims: list[str] = [];
        if os.path.exists(args[3]) {
            with open(args[3], "r") as f3 {
                claims = f3.read().splitlines();
            }
        }
        print(stack_base([str(p) for p in as_list(theme3["files"])], claims));
    # The claims a single applied theme contributes: `<branch>\tab<file>`, the exact shape
    # stack-base consumes. Sibling of `slots`, which does the same for a whole selection; this one
    # is per-theme because lib/tier2.sh appends as each branch is queued, not in one batch.
    } elif args[1] == "claims" and len(args) == 4 if len(args) > 1 else False {
        with open(args[2], "r") as f {
            theme4: dict = parse_obj(f.read());
        }
        for path2 in as_list(theme4["files"]) {
            print(args[3] + "\t" + str(path2));
        }
    } elif len(args) > 1 and args[1] != "test" {
        eprint("usage: ... findings.json | jac run selector.jac select <config.toml> <ledger.jsonl> <state.json> <remaining_min> <repo_dir>");
        eprint("       jac run selector.jac split <selection.json> <outdir>");
        eprint("       jac run selector.jac dropped <selection.json>");
        eprint("       jac run selector.jac slots <selection.json>");
        eprint("       jac run selector.jac carryover <theme.json>");
        eprint("       jac run selector.jac stack-base <theme.json> <claims.tsv>");
        eprint("       jac run selector.jac claims <theme.json> <branch>");
        # NONZERO. The sibling arm in check_scope.jac carries the full reasoning (RECONCILIATION
        # B8); the short version is that lib/tier2.sh reads `selector select` on STDOUT, so a
        # usage arm exiting 0 turns any future arity drift into an empty selection -- "no themes
        # tonight" -- and the night reports success having shipped nothing.
        sys.exit(2);
    }
}

"""Two [tasks.*] tables, appended to every inline test config. select() now reads
[tasks.<task>].fragment for every finding it packs, so a config without them is not a valid
selector input any more."""
glob TEST_TASKS: str = "[tasks.dead-code]\nponytail=\"full\"\nscoring=\"loc_saved\"\nfragment=\"refactor\"\n[tasks.abstraction]\nponytail=\"full\"\nscoring=\"loc_saved\"\nfragment=\"refactor\"\n[tasks.coverage]\nponytail=\"lite\"\nscoring=\"risk_weighted\"\nfragment=\"\"\n";


test "packing groups by DIRECTORY and spills an over-budget group into a second theme" {
    import tempfile;
    body: str = "[budgets]\nthemes_per_night = 9\nfiles_per_theme = 2\nloc_per_theme = 100\napply_timeout_min = 25\n[protect]\nglobs = [\"**/tests/**\"]\n" + TEST_TASKS;
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
        # THREE DIFFERENT theme_hints in ONE directory. Under the old (task, theme_hint) key these
        # were three singleton themes; they are now one group that spills at files_per_theme = 2.
        mk("pkg/a.jac", "dead code", 40, "dead-code", "dead-code"),
        mk("pkg/b.jac", "unused import", 40, "dead-code", "dead-code"),
        mk("pkg/c.jac", "orphan helper", 40, "dead-code", "dead-code"),
        mk("pkg/tests/f.jac", "dead code", 40, "dead-code", "dead-code"),   # protected
        mk("pkg/d.jac", "dup", 30, "abstraction", "duplication"),
    ];
    result: dict = select(findings, cfg_path, "/nonexistent-ledger", "/nonexistent-state", 999, "/nonexistent-repo");
    themes: list[dict] = [as_dict(t) for t in as_list(result["themes"])];
    slugs: list[str] = sorted([str(t["slug"]) for t in themes]);
    assert slugs == ["abstraction-pkg", "dead-code-pkg", "dead-code-pkg-2"];
    reasons: list[str] = [str(d["reason"]) for d in as_list(result["dropped"])];
    assert "protected-path" in reasons;
    # THE REGRESSION THIS GUARDS: the old loop `continue`d past the third finding as
    # over-theme-budget, a reason select() does not carry, so it was lost outright. Group by
    # directory without spilling and this repo starts deleting real findings for free.
    assert "over-theme-budget" not in reasons;
    packed: int = sum([len(as_list(t["findings"])) for t in themes]);
    assert packed == 4;                                  # a, b, c and d -- everything not protected
    for t in themes {
        assert len(as_list(t["files"])) <= 2;
        assert int(t["est_loc"]) <= 100;
    }
}

test "a finding too big for an EMPTY theme is over-theme-budget, and is still not carried" {
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
    # ...and it is now the ONLY case that reason describes: a finding that merely did not fit
    # ALONGSIDE another one starts a new theme instead of being dropped.
    fits: list[dict] = [{"file": "p/a.jac", "rule": "dead-code", "snippet": "s", "summary": "x",
        "task": "dead-code", "est_loc_saved": 40, "confidence": 5, "risk": 1,
        "theme_hint": "one", "complexity": "trivial"},
        {"file": "p/b.jac", "rule": "dead-code", "snippet": "s", "summary": "x",
        "task": "dead-code", "est_loc_saved": 40, "confidence": 5, "risk": 1,
        "theme_hint": "two", "complexity": "trivial"}];
    r2: dict = select(fits, cfg_path, "/nonexistent", "/nonexistent", 999, "/nonexistent-repo");
    assert [str(d["reason"]) for d in as_list(r2["dropped"])] == [];
    assert len(as_list(r2["themes"])) == 2;
}

test "themes are task-scoped: the same directory from two tasks never merges into one theme" {
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
    assert slugs == ["coverage-p", "dead-code-p"];
    for t in as_list(result["themes"]) {
        theme: dict = as_dict(t);
        assert str(theme["name"]) == "p";               # the task prefix is not repeated
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
    # One directory per finding: the group key is (task, directory) now, so two findings in one
    # directory would be ONE theme and this test would be asserting nothing.
    def mk(hint: str, loc: int) -> dict {
        return {"file": "p/" + hint + "/x.jac", "rule": "dead-code", "snippet": "s", "summary": "x",
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
    assert str(as_dict(themes2[0])["slug"]) == "dead-code-p-small";
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
    carried: dict = {"file": "p/old/x.jac", "rule": "dead-code", "snippet": "s", "summary": "x",
                     "task": "dead-code", "est_loc_saved": 5, "confidence": 1, "risk": 5,
                     "theme_hint": "old", "complexity": "trivial", "carry": True};
    tonight: dict = {"file": "p/new/x.jac", "rule": "dead-code", "snippet": "s", "summary": "x",
                     "task": "dead-code", "est_loc_saved": 400, "confidence": 5, "risk": 1,
                     "theme_hint": "new", "complexity": "trivial"};
    # 60 min remaining, default verify_estimate 30 -> 55 per theme -> exactly one theme fits
    result: dict = select([carried, tonight], cfg_path, "/nonexistent", "/nonexistent", 60,
                          "/nonexistent-repo");
    themes: list = as_list(result["themes"]);
    assert len(themes) == 1;
    assert str(as_dict(themes[0])["slug"]) == "dead-code-p-old";
    assert any([str(d["reason"]) == "no-clock-left" for d in as_list(result["dropped"])]);
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

test "impl_siblings pairs decl<->impl BOTH ways, and returns only paths that exist" {
    import tempfile;
    import os as _os;
    repo: str = tempfile.mkdtemp();
    _os.makedirs(repo + "/gw/impl");
    _os.makedirs(repo + "/cli/commands/impl");
    for p in ["gw/embedded_gateway.jac", "gw/impl/embedded_gateway.impl.jac",
              "cli/commands/impl/mcp.impl.jac", "cli/commands/mcp.jac", "plain.jac",
              "plain.impl.jac"] {
        with open(repo + "/" + p, "w") as f {
            f.write("x\n");
        }
    }
    # the impl/ subdirectory form is found...
    assert impl_siblings("gw/embedded_gateway.jac", repo) == ["gw/impl/embedded_gateway.impl.jac"];
    # ...and the same-directory form is NOT invented when it is not on disk. 14 of the 36 file slots
    # in the real 2026-07-31 selection were exactly this: a guess that does not exist, occupying a
    # files_per_theme slot and costing the apply session turns to disprove.
    assert "gw/embedded_gateway.impl.jac" not in impl_siblings("gw/embedded_gateway.jac", repo);
    assert impl_siblings("cli/commands/impl/mcp.impl.jac", repo) == ["cli/commands/mcp.jac"];
    assert impl_siblings("plain.jac", repo) == ["plain.impl.jac"];
    assert impl_siblings("no_extension", repo) == [];
    # a repo that is not there yields nothing rather than a fabricated pair
    assert impl_siblings("gw/embedded_gateway.jac", "/nonexistent-repo") == [];
    # ...and the same-directory form IS returned when it really is on disk, or the assertion above
    # is satisfied by a function that lost the same-directory case entirely.
    with open(repo + "/gw/other.jac", "w") as f {
        f.write("x\n");
    }
    with open(repo + "/gw/other.impl.jac", "w") as f {
        f.write("x\n");
    }
    assert impl_siblings("gw/other.jac", repo) == ["gw/other.impl.jac"];
}

test "file-gone: a finding whose OWN file upstream renamed away is dropped at selection" {
    import tempfile;
    import os as _os;
    repo: str = tempfile.mkdtemp();
    _os.makedirs(repo + "/jac/jaclang/runtimelib");
    # The real 2026-07-31 shape: the audit found planner.jac, upstream renamed it to
    # query_planner.jac before the clone was refreshed, and only the new name is on disk.
    with open(repo + "/jac/jaclang/runtimelib/query_planner.jac", "w") as f {
        f.write("x\n");
    }
    body: str = "[budgets]\nthemes_per_night = 4\nfiles_per_theme = 5\nloc_per_theme = 500\napply_timeout_min = 25\n[protect]\nglobs = []\n" + TEST_TASKS;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    mk = lambda path: str -> dict {
        return {"file": path, "rule": "dead-code", "snippet": "s", "summary": "x",
                "task": "dead-code", "est_loc_saved": 20, "confidence": 5, "risk": 1,
                "theme_hint": "rt", "complexity": "trivial"};
    };
    gone: dict = select([mk("jac/jaclang/runtimelib/planner.jac")], cfg_path,
                        "/nonexistent-ledger", "/nonexistent-state", 999, repo);
    assert as_list(gone["themes"]) == [];
    assert [str(d["reason"]) for d in as_list(gone["dropped"])] == ["file-gone"];
    # TERMINAL, like protected-path and blocked-by-protected-test: the path is gone, so carrying it
    # would re-drop it for the same reason every night while the real code lives elsewhere.
    assert as_list(gone["carryover"]) == [];

    # THE FALSE-POSITIVE ARM, the one that matters: a rule that drops everything satisfies the three
    # assertions above and costs the harness its entire output. The file that IS on disk still packs.
    live: dict = select([mk("jac/jaclang/runtimelib/query_planner.jac")], cfg_path,
                        "/nonexistent-ledger", "/nonexistent-state", 999, repo);
    assert len(as_list(live["themes"])) == 1;
    assert as_list(live["dropped"]) == [];

    # ...and with NO tree to check against the rule stands down rather than dropping the night's
    # whole selection, the same way vestigial_test_files and blocking_test_files do.
    blind: dict = select([mk("jac/jaclang/runtimelib/planner.jac")], cfg_path,
                         "/nonexistent-ledger", "/nonexistent-state", 999, "/nonexistent-repo");
    assert len(as_list(blind["themes"])) == 1;
}

test "packing pulls a finding's EXISTING impl sibling into theme scope" {
    import tempfile;
    import os as _os;
    repo: str = tempfile.mkdtemp();
    _os.makedirs(repo + "/gw");
    for p in ["gw/gateway.jac", "gw/gateway.impl.jac"] {
        with open(repo + "/" + p, "w") as f {
            f.write("x\n");
        }
    }
    body: str = "[budgets]\nthemes_per_night = 1\nfiles_per_theme = 3\nloc_per_theme = 100\napply_timeout_min = 25\n[protect]\nglobs = []\n" + TEST_TASKS;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    findings: list[dict] = [{"file": "gw/gateway.jac", "rule": "dead-code", "snippet": "s",
        "summary": "x", "task": "dead-code", "est_loc_saved": 40, "confidence": 4, "risk": 2,
        "theme_hint": "gw", "complexity": "trivial"}];
    result: dict = select(findings, cfg_path, "/nonexistent-ledger", "/nonexistent-state", 999, repo);
    themes: list[dict] = as_list(result["themes"]);
    assert len(themes) == 1;
    files: list[str] = [str(f) for f in as_list(as_dict(themes[0])["files"])];
    assert "gw/gateway.jac" in files;
    assert "gw/gateway.impl.jac" in files;
    # ...and the impl/ guess, which is not on disk, never entered the list
    assert "gw/impl/gateway.impl.jac" not in files;
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

test "deleted_symbols reads the deleted name off the snippet, method name over owner" {
    assert deleted_symbols([{"snippet": "def _tool_site_dirs(use_global: bool) -> list {"}])
        == {"_tool_site_dirs"};
    # an `impl Owner.method` deletes the METHOD; the owner survives
    assert deleted_symbols([{"snippet": "impl CommandRegistry.has_command(name: str) -> bool {"}])
        == {"has_command"};
    assert deleted_symbols([{"snippet": "obj Thing {\n    has x: int;\n}"}]) == {"Thing", "x"};
    # prose with no declaration line yields nothing, and nothing is never a blocker
    assert deleted_symbols([{"snippet": "    return name in self.commands;"}]) == set();
    assert deleted_symbols([{}]) == set();
}

test "blocked-by-protected-test: a deletion a protected test imports is dropped at SELECTION" {
    import tempfile;
    import os as _os;
    repo: str = tempfile.mkdtemp();
    _os.makedirs(repo + "/jac/pkg/tests");
    with open(repo + "/jac/pkg/abi.jac", "w") as f {
        f.write("def scalar_layout(x: int) -> int {\n    return x;\n}\n");
    }
    # THE BLOCKER SHAPE, copied from jac/tests/compiler/test_abi_lib.jac: the deleted symbol is
    # named in a braced import from the theme's own module, and the brace list spans lines.
    with open(repo + "/jac/pkg/tests/test_abi.jac", "w") as f {
        f.write("import from jaclang.pkg.abi {\n    scalar_layout\n}\n"
                + "import from jaclang.pkg.other { keep }\n"
                + "test \"scalar\" {\n    assert scalar_layout(1) == 1;\n}\n");
    }
    body: str = "[budgets]\nthemes_per_night = 4\nfiles_per_theme = 5\nloc_per_theme = 500\napply_timeout_min = 25\n[protect]\nglobs = [\"**/tests/**\"]\n" + TEST_TASKS;
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    dead: list[dict] = [{"file": "jac/pkg/abi.jac", "rule": "dead-code",
        "snippet": "def scalar_layout(x: int) -> int {", "summary": "x", "task": "dead-code",
        "est_loc_saved": 20, "confidence": 5, "risk": 1, "theme_hint": "abi",
        "complexity": "trivial"}];
    result: dict = select(dead, cfg_path, "/nonexistent-ledger", "/nonexistent-state", 999, repo);
    assert as_list(result["themes"]) == [];
    assert [str(d["reason"]) for d in as_list(result["dropped"])] == ["blocked-by-protected-test"];
    # TERMINAL, like protected-path: nothing about tomorrow makes it applicable, so it is not
    # carried and does not come back to be re-dropped every night.
    assert as_list(result["carryover"]) == [];
    assert blocking_test_files(repo, ["jac/pkg/abi.jac"], {"scalar_layout"}, ["**/tests/**"])
        == ["jac/pkg/tests/test_abi.jac"];

    # THE FALSE-POSITIVE ARM, without which the assertion above is satisfied by a rule that blocks
    # everything -- which is precisely what reusing vestigial_test_files' stem grep would do.
    # `keep` is a symbol of a DIFFERENT module the same test file imports.
    assert blocking_test_files(repo, ["jac/pkg/abi.jac"], {"keep"}, ["**/tests/**"]) == [];
    # ...a symbol nothing references at all is not a blocker
    assert blocking_test_files(repo, ["jac/pkg/abi.jac"], {"never_mentioned"}, ["**/tests/**"]) == [];
    # ...and neither is a bare word-match with no import binding it to this theme's module. This is
    # the `clear` / `is_empty` case that a plain symbol grep gets wrong: the word is in the file,
    # but it arrives through nothing this theme deletes.
    with open(repo + "/jac/pkg/tests/test_other.jac", "w") as f {
        f.write("import from jaclang.pkg.unrelated { thing }\n"
                + "test \"t\" {\n    thing.scalar_layout();\n}\n");
    }
    assert blocking_test_files(repo, ["jac/pkg/abi.jac"], {"scalar_layout"}, ["**/tests/**"])
        == ["jac/pkg/tests/test_abi.jac"];
    # a receiver bound to the theme's module IS a blocker, though -- the
    # `import from jaclang.cli.commands { execution as exec_cmds }` /
    # `exec_cmds._tool_site_dirs(...)` shape from report-dead-code-reactive-superseded-tool-resolver
    with open(repo + "/jac/pkg/tests/test_alias.jac", "w") as f {
        f.write("import from jaclang.pkg { abi as abi_mod }\n"
                + "test \"t\" {\n    abi_mod.scalar_layout(1);\n}\n");
    }
    assert blocking_test_files(repo, ["jac/pkg/abi.jac"], {"scalar_layout"}, ["**/tests/**"])
        == ["jac/pkg/tests/test_abi.jac", "jac/pkg/tests/test_alias.jac"];
    # an UNPROTECTED caller is not a blocker: the theme can edit it
    _os.makedirs(repo + "/jac/pkg/prod");
    with open(repo + "/jac/pkg/prod/user.jac", "w") as f {
        f.write("import from jaclang.pkg.abi { scalar_layout }\n");
    }
    assert "jac/pkg/prod/user.jac"
        not in blocking_test_files(repo, ["jac/pkg/abi.jac"], {"scalar_layout"}, ["**/tests/**"]);
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
    # `snippet: "s"` carries no declaration line, so deleted_symbols is empty and the blocker check
    # is a no-op here -- this test is about the vestigial sweep, and the two must not interfere.
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
        {"file": "big/a.jac", "rule": "dead-code", "snippet": "a", "summary": "x",
         "task": "dead-code", "est_loc_saved": 100, "confidence": 5, "risk": 1,
         "theme_hint": "big", "complexity": "trivial"},
        {"file": "small/b.jac", "rule": "simplify", "snippet": "b", "summary": "x",
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

    # THE APPLY-TIME HALF OF THE SAME MECHANISM. The theme that DID fit the clock at selection can
    # still be deferred by tier2_apply's clock or cost guard, and until 2026-08-04 that left it
    # nowhere: no ledger row, nothing in state/carryover.json. Projected here, it must be
    # INDISTINGUISHABLE from the selection-time entry above -- same keys, same carry flag -- because
    # tomorrow night reads both through the one reader.
    kept: dict = as_dict(as_list(result["themes"])[0]);
    deferred_at_apply: list[dict] = carry_findings(kept);
    assert len(deferred_at_apply) == 1;
    assert deferred_at_apply[0]["carry"] == True;
    assert sorted(deferred_at_apply[0].keys())
        == sorted(as_dict(as_list(result["carryover"])[0]).keys());
    # ...and it is the finding, not the theme: the fingerprint is what tomorrow's dedupe and
    # re-discovery key on, so an entry without it would silently never come back.
    assert str(deferred_at_apply[0]["fingerprint"])
        == fingerprint("big/a.jac", "dead-code");
    # A theme with nothing in it is a BUG, and must not project as a quiet empty list -- that is
    # the vanishing this whole path exists to stop, one layer down.
    raised: bool = False;
    try {
        carry_findings({"slug": "empty-theme", "findings": []});
    } except ValueError {
        raised = True;
    }
    assert raised;
}

test "the slots reader names every file of every selected theme, and nothing else" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    sel: str = d + "/sel.json";
    with open(sel, "w") as f {
        f.write(json.dumps({"themes": [
            {"slug": "dead-code-cli", "files": ["a.jac", "a.impl.jac"]},
            {"slug": "dead-code-cli-2", "files": ["b.jac"]}],
            "dropped": [{"file": "never.jac"}], "carryover": []}));
    }
    with open(sel, "r") as f2 {
        s: dict = parse_obj(f2.read());
    }
    rows: list[str] = [];
    for t in as_list(s["themes"]) {
        theme: dict = as_dict(t);
        for path in as_list(theme["files"]) {
            rows.append(str(theme["slug"]) + "\t" + str(path));
        }
    }
    assert rows == ["dead-code-cli\ta.jac", "dead-code-cli\ta.impl.jac", "dead-code-cli-2\tb.jac"];
    # a DROPPED finding's file is not a slot: the S4 gate reads this list as write permission
    assert "never.jac" not in "\n".join(rows);
}

test "stack_base picks the LAST claimant, and no overlap means main" {
    claims: list[str] = [
        "nightshift/d/dead-code-cli\tjac/jaclang/cli/a.jac",
        "nightshift/d/dead-code-cli\tjac/jaclang/cli/b.jac",
        "nightshift/d/abstraction-cli\tjac/jaclang/cli/a.jac",
    ];
    # the reactive case this feature exists for: a third lens hitting the same file must land on
    # the TIP of the chain (abstraction-cli), not on the branch that claimed it first
    assert stack_base(["jac/jaclang/cli/a.jac"], claims) == "nightshift/d/abstraction-cli";
    # overlap with an EARLIER-only claimant still bases on that one
    assert stack_base(["jac/jaclang/cli/b.jac"], claims) == "nightshift/d/dead-code-cli";
    # disjoint -> "" -> ns_base_of_branch resolves it to main, i.e. today's behaviour
    assert stack_base(["jac/jaclang/scale/z.jac"], claims) == "";
    assert stack_base([], claims) == "";
    assert stack_base(["jac/jaclang/cli/a.jac"], []) == "";
    # a torn final row loses an edge, never invents one and never raises
    assert stack_base(["jac/jaclang/cli/a.jac"], ["nightshift/d/x"]) == "";
    assert stack_base(["jac/jaclang/cli/a.jac"], ["", "a\tb\tc"]) == "";
}
