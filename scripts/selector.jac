"""S3-B selector (TechnicalPRD 7 S3-B): merge audit findings with the ledger,
drop the ineligible, score, and greedy-pack into budgeted themes.

argv:  select <package> <config.toml> <ledger.jsonl> <state.json> <remaining_min> <repo_dir>
           stdin: validated findings array → stdout: {"themes": [...], "dropped": [...]}
       split <selection.json> <outdir>     write theme-<slug>.json per theme; print slugs
       dropped <selection.json>            print `fingerprint<TAB>file<TAB>reason` lines
       rotate <config.toml> <state.json>   print tonight's package; advance the rotation
Deterministic: same inputs → same packing (unit-testable, TPRD 14).
"""
import sys;
import os;
import json;
import re;
import subprocess;
import from nslib {
    eprint, read_stdin, parse_list, parse_obj, fingerprint, load_ledger, state_read,
    state_write, load_config_toml, load_globs, is_protected, as_dict, as_list, as_float
}

"""Non-project imports a test file may keep and still be "100% about this theme's dead code" --
stdlib, test frameworks, and common third-party libs. Deliberately short: anything NOT in here is
treated as a real project dependency and disqualifies the file (fail closed)."""
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

def score_of(f: dict) -> float {
    return float(int(f["est_loc_saved"]) * int(f["confidence"])) / float(int(f["risk"]));
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

"""Greedy pack (TPRD S3-B steps 3-4): group by theme_hint, budget files/LOC per theme,
keep at most themes_per_night themes ordered by total score."""
def pack_themes(eligible: list[dict], budgets: dict, package: str, repo_dir: str,
                 protect_globs: list[str]) -> (list[dict], list[dict]) {
    groups: dict[str, list[dict]] = {};
    for f in eligible {
        slug: str = slugify(str(f["theme_hint"]));
        if slug not in groups {
            groups[slug] = [];
        }
        groups[slug].append(f);
    }
    themes: list[dict] = [];
    dropped: list[dict] = [];
    for (slug, group) in groups.items() {
        group.sort(key=lambda f: dict -> tuple { return (-score_of(f), str(f["fingerprint"])); });
        files: list[str] = [];
        picked: list[dict] = [];
        est_loc: int = 0;
        for f in group {
            file: str = str(f["file"]);
            new_file: int = 0 if file in files else 1;
            if len(files) + new_file > int(budgets["files_per_theme"])
               or est_loc + int(f["est_loc_saved"]) > int(budgets["loc_per_theme"]) {
                dropped.append({"fingerprint": f["fingerprint"], "file": file, "reason": "over-theme-budget"});
                continue;
            }
            if new_file == 1 {
                files.append(file);
            }
            picked.append(f);
            est_loc += int(f["est_loc_saved"]);
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
            # Only for pure dead-code themes (a duplication/simplify finding doesn't delete a
            # symbol outright, so "vestigial" doesn't apply): pull in any test file that becomes
            # entirely about this theme's now-deleted files, independently verified, never
            # trusted to the agent's own future claim.
            vestigial: list[str] = [];
            if all([str(f["rule"]) == "dead-code" for f in picked]) {
                vestigial = vestigial_test_files(repo_dir, files, protect_globs);
            }
            themes.append({
                "name": str(picked[0]["theme_hint"]), "slug": slug, "package": package,
                "files": files, "vestigial_deletions": vestigial,
                "findings": picked, "est_loc": est_loc,
                "score": sum([score_of(f) for f in picked]),
            });
        }
    }
    themes.sort(key=lambda t: dict -> tuple { return (-as_float(t["score"]), str(t["slug"])); });
    for t in themes[int(budgets["themes_per_night"]):] {
        for f in as_list(t["findings"]) {
            dropped.append({"fingerprint": f["fingerprint"], "file": f["file"], "reason": "over-night-budget"});
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
            dropped.append({"fingerprint": f["fingerprint"], "file": f["file"], "reason": "no-clock-left"});
        }
    }
    return (themes, dropped);
}

def select(findings: list[dict], package: str, config_path: str, ledger_path: str,
           state_path: str, remaining_min: int, repo_dir: str) -> dict {
    cfg: dict = load_config_toml(config_path);
    budgets: dict = as_dict(cfg["budgets"]);
    globs: list[str] = load_globs(config_path);
    ledger: dict[str, dict] = load_ledger(ledger_path);
    verify_estimate: int = int(state_read(state_path).get("verify_estimate_min", 30));

    eligible: list[dict] = [];
    dropped: list[dict] = [];
    for f in findings {
        f["fingerprint"] = fingerprint(str(f["file"]), str(f["rule"]), str(f["snippet"]));
        f["score"] = score_of(f);
        reason: str | None = drop_reason(f, ledger, globs);
        if reason is None {
            eligible.append(f);
        } else {
            dropped.append({"fingerprint": f["fingerprint"], "file": f["file"], "reason": reason});
        }
    }
    (themes, dropped2) = pack_themes(eligible, budgets, package, repo_dir, globs);
    (themes2, dropped3) = fit_clock(themes, dropped2, budgets, verify_estimate, remaining_min);
    return {"themes": themes2, "dropped": dropped + dropped3};
}

"""Round-robin package rotation (TPRD S3): print tonight's package, persist the next one."""
def rotate(config_path: str, state_path: str) -> str {
    packages: list[str] = [str(pkg) for pkg in as_list(as_dict(load_config_toml(config_path)["rotation"])["packages"])];
    state: dict = state_read(state_path);
    current: str = str(state.get("next_package", packages[0]));
    if current not in packages {
        current = packages[0];
    }
    state["next_package"] = packages[(packages.index(current) + 1) % len(packages)];
    state_write(state_path, state);
    return current;
}

with entry {
    args: list[str] = sys.argv;
    if len(args) == 8 and args[1] == "select" {
        raw: list = parse_list(read_stdin());
        findings: list[dict] = [f for f in raw if isinstance(f, dict)];
        print(json.dumps(select(findings, args[2], args[3], args[4], args[5], int(args[6]), args[7])));
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
    } elif args[1] == "rotate" and len(args) == 4 if len(args) > 1 else False {
        print(rotate(args[2], args[3]));
    } elif len(args) > 1 and args[1] != "test" {
        eprint("usage: ... findings.json | jac run selector.jac select <package> <config.toml> <ledger.jsonl> <state.json> <remaining_min> <repo_dir>");
        eprint("       jac run selector.jac split <selection.json> <outdir>");
        eprint("       jac run selector.jac dropped <selection.json>");
        eprint("       jac run selector.jac rotate <config.toml> <state.json>");
    }
}

test "packing respects caps, drops ledger-known and protected findings" {
    import tempfile;
    body: str = "[budgets]\nthemes_per_night = 2\nfiles_per_theme = 2\nloc_per_theme = 100\napply_timeout_min = 25\n[protect]\nglobs = [\"**/tests/**\"]\n";
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    def mk(file: str, hint: str, loc: int) -> dict {
        return {"file": file, "rule": "dead-code", "snippet": "s " + file, "summary": "x",
                "est_loc_saved": loc, "confidence": 4, "risk": 2, "theme_hint": hint};
    }
    findings: list[dict] = [
        mk("pkg/a.jac", "dead code", 40),
        mk("pkg/b.jac", "dead code", 40),
        mk("pkg/c.jac", "dead code", 40),          # third file: over files_per_theme=2
        mk("pkg/tests/f.jac", "dead code", 40),    # protected
        mk("pkg/d.jac", "dup", 30),
    ];
    result: dict = select(findings, "pkg", cfg_path, "/nonexistent-ledger", "/nonexistent-state", 999, "/nonexistent-repo");
    assert len(as_list(result["themes"])) == 2;
    reasons: list[str] = [str(d["reason"]) for d in as_list(result["dropped"])];
    assert "protected-path" in reasons;
    assert "over-theme-budget" in reasons;
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
    body: str = "[budgets]\nthemes_per_night = 1\nfiles_per_theme = 3\nloc_per_theme = 100\napply_timeout_min = 25\n[protect]\nglobs = []\n";
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    findings: list[dict] = [{"file": "gw/gateway.jac", "rule": "dead-code", "snippet": "s",
        "summary": "x", "est_loc_saved": 40, "confidence": 4, "risk": 2, "theme_hint": "gw"}];
    result: dict = select(findings, "pkg", cfg_path, "/nonexistent-ledger", "/nonexistent-state", 999, "/nonexistent-repo");
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

    body: str = "[budgets]\nthemes_per_night = 1\nfiles_per_theme = 5\nloc_per_theme = 100\napply_timeout_min = 25\n[protect]\nglobs = [\"**/tests/**\"]\n";
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    dead: list[dict] = [{"file": "jac/pkg/gateway.jac", "rule": "dead-code", "snippet": "s",
        "summary": "x", "est_loc_saved": 10, "confidence": 5, "risk": 1, "theme_hint": "gw"}];
    result: dict = select(dead, "pkg", cfg_path, "/nonexistent-ledger", "/nonexistent-state", 999, repo);
    theme: dict = as_dict(as_list(result["themes"])[0]);
    assert as_list(theme["vestigial_deletions"]) == ["jac/pkg/tests/test_only.jac"];

    # a duplication (non-dead-code) finding must never get vestigial deletions, even same file
    dup: list[dict] = [{"file": "jac/pkg/gateway.jac", "rule": "duplication", "snippet": "s2",
        "summary": "x", "est_loc_saved": 10, "confidence": 5, "risk": 1, "theme_hint": "gw2"}];
    result2: dict = select(dup, "pkg", cfg_path, "/nonexistent-ledger", "/nonexistent-state", 999, repo);
    theme2: dict = as_dict(as_list(result2["themes"])[0]);
    assert as_list(theme2["vestigial_deletions"]) == [];
}

test "clock shedding removes lowest-scored theme" {
    import tempfile;
    body: str = "[budgets]\nthemes_per_night = 3\nfiles_per_theme = 10\nloc_per_theme = 300\napply_timeout_min = 25\n[protect]\nglobs = []\n";
    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as tf {
        cfg_path: str = tf.name;
        tf.write(body);
    }
    findings: list[dict] = [
        {"file": "p/a.jac", "rule": "dead-code", "snippet": "a", "summary": "x",
         "est_loc_saved": 100, "confidence": 5, "risk": 1, "theme_hint": "big"},
        {"file": "p/b.jac", "rule": "simplify", "snippet": "b", "summary": "x",
         "est_loc_saved": 5, "confidence": 2, "risk": 3, "theme_hint": "small"},
    ];
    # remaining 60 min, default verify_estimate 30 → per-theme 55 → only 1 theme fits
    result: dict = select(findings, "p", cfg_path, "/nonexistent", "/nonexistent", 60, "/nonexistent-repo");
    assert len(as_list(result["themes"])) == 1;
    assert as_list(result["themes"])[0]["slug"] == "big";
    assert any([str(d["reason"]) == "no-clock-left" for d in as_list(result["dropped"])]);
}
