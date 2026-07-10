"""S3-B selector (TechnicalPRD 7 S3-B): merge audit findings with the ledger,
drop the ineligible, score, and greedy-pack into budgeted themes.

argv:  select <package> <config.toml> <ledger.jsonl> <state.json> <remaining_min>
           stdin: validated findings array → stdout: {"themes": [...], "dropped": [...]}
       split <selection.json> <outdir>     write theme-<slug>.json per theme; print slugs
       dropped <selection.json>            print `fingerprint<TAB>file<TAB>reason` lines
       rotate <config.toml> <state.json>   print tonight's package; advance the rotation
Deterministic: same inputs → same packing (unit-testable, TPRD 14).
"""
import sys;
import json;
import re;
import from nslib {
    eprint, read_stdin, parse_list, parse_obj, fingerprint, load_ledger, state_read,
    state_write, load_config_toml, load_globs, is_protected, as_dict, as_list, as_float
}

def slugify(hint: str) -> str {
    slug: str = re.sub("[^a-z0-9]+", "-", hint.lower()).strip("-");
    return slug if slug else "misc";
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
def pack_themes(eligible: list[dict], budgets: dict, package: str) -> (list[dict], list[dict]) {
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
            themes.append({
                "name": str(picked[0]["theme_hint"]), "slug": slug, "package": package,
                "files": files, "findings": picked, "est_loc": est_loc,
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
           state_path: str, remaining_min: int) -> dict {
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
    (themes, dropped2) = pack_themes(eligible, budgets, package);
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
    if len(args) == 7 and args[1] == "select" {
        raw: list = parse_list(read_stdin());
        findings: list[dict] = [f for f in raw if isinstance(f, dict)];
        print(json.dumps(select(findings, args[2], args[3], args[4], args[5], int(args[6]))));
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
        eprint("usage: ... findings.json | jac run selector.jac select <package> <config.toml> <ledger.jsonl> <state.json> <remaining_min>");
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
    result: dict = select(findings, "pkg", cfg_path, "/nonexistent-ledger", "/nonexistent-state", 999);
    assert len(as_list(result["themes"])) == 2;
    reasons: list[str] = [str(d["reason"]) for d in as_list(result["dropped"])];
    assert "protected-path" in reasons;
    assert "over-theme-budget" in reasons;
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
    result: dict = select(findings, "p", cfg_path, "/nonexistent", "/nonexistent", 60);
    assert len(as_list(result["themes"])) == 1;
    assert as_list(result["themes"])[0]["slug"] == "big";
    assert any([str(d["reason"]) == "no-clock-left" for d in as_list(result["dropped"])]);
}
