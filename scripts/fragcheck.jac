"""Release-note fragment gate: a Jac reimplementation of the rules from
work/repo/scripts/check-release-notes.sh that config/ci-mirror.toml's [jobs.contribution] needs.

WHY THIS EXISTS INSTEAD OF SHELLING OUT TO THE REAL SCRIPT: that script (lines 12-14) declares
`declare -A FOLDER_TO_FRAGMENTS=(...)`, a bash 4+ associative array. The only bash available on
this harness's dev host, on both `/bin/bash` and whatever `/usr/bin/env bash` resolves to, is
3.2.57. Under 3.2, `declare -A` is silently rejected (invalid option) and bash then mis-parses the
parenthesized initializer as an INDEXED-array subscript, evaluating `["jac/jaclang/"]`
arithmetically -- which references the unset variable `jac` under `set -u` and crashes
("line 12: jac: unbound variable") before the script's own logic ever runs. That is a hard,
unconditional, universal failure -- strictly worse than the silent no-op it used to be (a missing
`CI=true`), because it now blocks instead of rubber-stamping. Patching work/repo's script is out
of scope (it is upstream-tracked, not ours to edit), so this file is a DELIBERATE, DISCLOSED
EQUIVALENT of the rule in ci.yml's "Check Release Notes Updated" step (ci.yml:502-512) -- not the
literal script, and CI itself remains the authority on the real thing.

Two rules mirrored, both transcribed directly from check-release-notes.sh:

1. Presence (lines 122-144, the folder_changed / fragment_added loop over the one entry in
   FOLDER_TO_FRAGMENTS): if any changed path is under jac/jaclang/ (and is not itself a test file
   -- check-release-notes.sh:131's `[[ "$file" != */tests/* ]]`), the change range must also
   contain a valid release-note fragment matching FRAGMENT_REGEX below. jac-mcp/, jac/tests/,
   docs/, etc. need no fragment. The kind alternation in FRAGMENT_REGEX is built FROM
   nslib.VALID_FRAGMENT_KINDS (imported, not re-typed) -- nslib.fragment_path is the one other
   place that encodes "jac/jaclang/ -> jaclang", and this file's docstring used to (falsely) claim
   the same for the kind list without actually importing it; fixed by importing it for real.
2. Content format (lines 170-178's "Validate content format" block): a changed fragment that
   exists on disk must have every line either blank, or starting with `-` (a bullet) and not a
   `- #### heading` in disguise. CI's exact check is
   `grep -qE '^[^[:space:]-]|^-[[:space:]]+#{1,6}[[:space:]]' "$file"` (matches => malformed);
   reimplemented per-line below since Python's `re` has no POSIX `[:space:]` bracket class.

Deliberately NOT reimplemented (out of scope for this gate -- see check-release-notes.sh for the
real logic if a future task needs them): the "PR number must match" check (lines 87-120;
meaningless before a PR exists -- nslib.fragment_path already emits a 0000. placeholder for
exactly this reason), and the "release notes .md directly edited" check (lines 43-74).
"""
import sys;
import os;
import re;
import from nslib { eprint, read_stdin, VALID_FRAGMENT_KINDS }

glob FRAGMENT_REGEX: str = "release_notes/unreleased/[^/]+/([0-9]+)\\.(" + "|".join(VALID_FRAGMENT_KINDS) + ")\\.md$";

"""Mirrors check-release-notes.sh:131 exactly: under jac/jaclang/, but not a test file."""
def is_gated_change(path: str) -> bool {
    return path.startswith("jac/jaclang/") and "/tests/" not in path;
}

"""A path only counts as "the fragment" if its kind is one of nslib.VALID_FRAGMENT_KINDS -- a
typo'd kind (e.g. `.typo.md`) does not match the regex, so it can never silently satisfy the gate."""
def is_valid_fragment(path: str) -> bool {
    return re.search(FRAGMENT_REGEX, path) is not None;
}

"""Mirrors check-release-notes.sh's malformed-content regex
`^[^[:space:]-]|^-[[:space:]]+#{1,6}[[:space:]]`, checked per-line (Python `re` has no POSIX
`[:space:]` bracket class, so this is `\\s`-equivalent, not `-P`/PCRE-dependent). True if ANY line
is a bare paragraph/heading (does not start with whitespace or `-`) or a heading disguised as a
bullet (`- #### ...`)."""
def is_malformed_line(line: str) -> bool {
    if re.match("^[^\\s-]", line) {
        return True;
    }
    if re.match("^-\\s+#{1,6}\\s", line) {
        return True;
    }
    return False;
}

def is_malformed_fragment(path: str) -> bool {
    with open(path, "r") as f {
        text: str = f.read();
    }
    for line in text.splitlines() {
        if is_malformed_line(line) {
            return True;
        }
    }
    return False;
}

"""Returns "" when satisfied, or a message describing the violation."""
def check_fragments(paths: list[str]) -> str {
    folder_changed: bool = False;
    fragment_added: bool = False;
    malformed: list[str] = [];
    for p in paths {
        if is_gated_change(p) {
            folder_changed = True;
        }
        if is_valid_fragment(p) {
            fragment_added = True;
            # Mirrors check-release-notes.sh's `[ -f "$file" ]` guard: a deleted fragment (no
            # longer on disk) has no content to validate and is not "this change's" fragment.
            if os.path.exists(p) and is_malformed_fragment(p) {
                malformed.append(p);
            }
        }
    }
    if malformed {
        return "malformed fragment(s), must be bullet points starting with '- ' (no headings or plain paragraphs): " + ", ".join(malformed);
    }
    if folder_changed and not fragment_added {
        return "jac/jaclang/ -> release_notes/unreleased/jaclang/<PR#>.<" + "|".join(VALID_FRAGMENT_KINDS) + ">.md";
    }
    return "";
}

with entry {
    args: list[str] = sys.argv;
    if len(args) == 2 and args[1] == "check" {
        paths: list[str] = [line.strip() for line in read_stdin().splitlines() if line.strip()];
        missing: str = check_fragments(paths);
        if missing {
            eprint("ERROR: release note fragment not added for: " + missing);
            sys.exit(1);
        }
    } elif len(args) > 1 and args[1] != "test" {
        eprint("usage: git diff --name-only \"$NS_REPO_DEFAULT_BRANCH...HEAD\" | jac run fragcheck.jac check");
    }
}

test "jac/jaclang/ change with a matching fragment passes" {
    ok: str = check_fragments(["jac/jaclang/compiler/x.jac", "release_notes/unreleased/jaclang/1234.bugfix.md"]);
    assert ok == "";
}

test "jac/jaclang/ change without a fragment fails, naming the expected dir" {
    msg: str = check_fragments(["jac/jaclang/compiler/x.jac"]);
    assert msg != "";
    assert "release_notes/unreleased/jaclang/" in msg;
}

test "jac-mcp-only change needs no fragment" {
    assert check_fragments(["jac-mcp/server.jac"]) == "";
}

test "a fragment naming an invalid kind does not satisfy the gate" {
    msg: str = check_fragments(["jac/jaclang/compiler/x.jac", "release_notes/unreleased/jaclang/1234.typo.md"]);
    assert msg != "";
}

test "jac/jaclang/ test-file-only change needs no fragment, like the shell script's */tests/* exclusion" {
    assert check_fragments(["jac/jaclang/compiler/tests/test_x.jac"]) == "";
}

test "docs-only change needs no fragment" {
    assert check_fragments(["docs/guide/intro.md"]) == "";
}

test "fragment content: a bullet point passes, a bare word fails, a disguised heading fails" {
    import tempfile;
    d: str = tempfile.mkdtemp();
    good: str = d + "/good.md";
    bad_word: str = d + "/bad_word.md";
    bad_heading: str = d + "/bad_heading.md";
    with open(good, "w") as f {
        f.write("- **Fix: Desktop create/install bootstrap**: description of the change.\n");
    }
    with open(bad_word, "w") as f {
        f.write("Removed dead plugin config.\n");
    }
    with open(bad_heading, "w") as f {
        f.write("- #### Heading disguised as a bullet\n");
    }
    assert not is_malformed_fragment(good);
    assert is_malformed_fragment(bad_word);
    assert is_malformed_fragment(bad_heading);
}

test "check_fragments rejects a malformed fragment even though its path/kind matched" {
    import tempfile;
    import os as _os;
    d: str = tempfile.mkdtemp();
    _os.makedirs(d + "/release_notes/unreleased/jaclang", exist_ok=True);
    frag: str = d + "/release_notes/unreleased/jaclang/1234.bugfix.md";
    with open(frag, "w") as f {
        f.write("Bare paragraph, not a bullet point.\n");
    }
    msg: str = check_fragments(["jac/jaclang/compiler/x.jac", frag]);
    assert msg != "";
    assert "malformed" in msg;
}
