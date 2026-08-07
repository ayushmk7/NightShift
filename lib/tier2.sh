# shellcheck shell=bash
# lib/tier2.sh — S3 (TechnicalPRD 7-S3): audit (read-only) → select (pure) → apply (one branch per theme).

# {placeholder} substitution in prompt templates — bash-native, no envsubst dependency
render_prompt() {
    local template=$1; shift
    local text; text="$(cat "$template")"
    local kv key val
    for kv in "$@"; do
        key="${kv%%=*}"; val="${kv#*=}"
        text="${text//\{$key\}/$val}"
    done
    printf '%s' "$text"
}

# Which model executes one apply attempt (design spec 13).
#
# Attempt 1 routes on the theme's complexity: trivial/mechanical go to the cheap model, judgement
# to the expensive one. Every later attempt is $NS_AGENT_MODEL, unconditionally -- ESCALATION IS
# ONE-WAY. A judgement theme that failed on Opus is never retried on Sonnet in the hope of a
# different answer, and a Sonnet theme that failed gets exactly one Opus attempt.
#
# `case`, not `[ ] && ...`: a trailing && list returns nonzero when its test fails, and this
# function is called in a command substitution inside an errexit caller.
ns_attempt_model() {   # ns_attempt_model <attempt> <complexity>
    case "$1" in
        1)
            case "$2" in
                trivial|mechanical) printf '%s\n' "$NS_AGENT_MODEL_SIMPLE" ;;
                *)                  printf '%s\n' "$NS_AGENT_MODEL" ;;
            esac
            ;;
        *) printf '%s\n' "$NS_AGENT_MODEL" ;;
    esac
}

# `tasks next` ADVANCES the cycle as it reads (see scripts/tasks.jac): a night that dies later must
# not make every following night repeat the same task. Resolved once here, before the fan-out, so
# the backgrounded shards all inherit the same NS_TASK_* values.
#
# The `eval` is BARE on purpose -- no `export`, no `set -a`. These stay orchestrator-local shell
# variables and are never inherited by a claude session. Same property ns_load_config relies on.
tier2_resolve_task() {
    local task rc=0 env_lines
    task="$(ns_jac tasks next "$CONFIG" "$STATE")" || rc=$?
    case "$rc$task" in
        0?*) : ;;
        *) ns_die "$EX_BUG" "could not resolve tonight's task from $CONFIG (rc=$rc, task='$task'). Refusing to guess: the task decides the audit prompt, the finding schema, and -- through the branch name -- the write permissions the S4 gate applies." ;;
    esac
    env_lines="$(ns_jac tasks env "$task" "$CONFIG")" || rc=$?
    case "$rc$env_lines" in
        0?*) : ;;
        *) ns_die "$EX_BUG" "[tasks.$task] did not yield a usable NS_TASK_* env (rc=$rc)" ;;
    esac
    eval "$env_lines"
    ns_log S3 "tonight's task: $NS_TASK_NAME (scoring=$NS_TASK_SCORING, ponytail=$NS_TASK_PONYTAIL, fragment='$NS_TASK_FRAGMENT')"
}

tier2_main() {
    local remaining; remaining="$(ns_remaining_min)"
    if [ "$remaining" -lt $(( NS_BUDGETS_AUDIT_TIMEOUT_MIN + NS_BUDGETS_APPLY_TIMEOUT_MIN )) ]; then
        ns_warn "no clock left for the agentic tier (${remaining}m remaining) — skipping S3"
        return 0
    fi

    tier2_resolve_task

    # Coverage evidence, once for the night, before the fan-out. Only the coverage audit reads it.
    if [ "$NS_TASK_NAME" = coverage ]; then
        if ns_jac covmap rank "$REPO" "$NS_PATHS_JAC_REPO" > "$LOG_DIR/covmap.json"; then
            ns_log S3 "covmap: $(ns_jac parse_result len < "$LOG_DIR/covmap.json" || echo 0) untested public archetypes"
        else
            # No evidence means the audit would be guessing, and an empty evidence block reads to
            # the model exactly like "everything is tested". Skip tonight's fresh coverage audit;
            # carried-over themes below still run, because they need no audit at all.
            # The file is REMOVED, not left truncated: covmap.jac's own check=True already refuses
            # to emit `[]` on failure, and tier2_audit_shard's `[ ! -s ]` test is what turns that
            # into a skipped audit rather than an audit against nothing.
            ns_fail "audit[coverage]" "covmap failed — no evidence, so no fresh coverage audit tonight"
            rm -f "$LOG_DIR/covmap.json"
        fi
    fi

    # S3a BEFORE S3b: fresh upstream merges are cleaned the same night they land (design spec
    # section 10), and the clock is what gives them priority -- they simply spend it first. A quiet
    # day returns immediately having spent nothing. Placed after tier2_resolve_task so a night that
    # dies inside the reactive pass still advanced the cycle, and after the covmap block so a
    # coverage night does not build the same evidence twice.
    reactive_main

    # tier2_audit_all's failure no longer returns: with carry-over, a night with zero fresh
    # findings still has yesterday's deferred themes to apply.
    tier2_audit_all || ns_log S3 "no fresh findings tonight — carry-over only"
    tier2_select cycle
    tier2_apply cycle
    dataset_record_night               # after select+apply: selection.json + every meta-*.json exist
}

# Phase A — audit, physically read-only (dontAsk + no Edit/Write in the allow-list).
#
# ONE SCOPE per session. Called two ways, deliberately by the SAME function:
#   * the shard fan-out passes a shard name and `shards scope` output (365k LOC, design spec 5)
#   * the reactive pass passes "reactive-<task>" and the merged-file list (design spec 10)
# Scope arrives as an ARGUMENT rather than being looked up here, because that plus the task are the
# only things that differ between the callers, and a second copy of the retry / session-limit /
# corrective-re-prompt logic is the last thing this file needs.
#
# Writes $LOG_DIR/findings-<name>.json on success. Never returns nonzero for a single
# failure -- a dead scope must not kill the tier, the way a dead package used to.
tier2_audit_shard() {   # tier2_audit_shard <name> <scope> <task>
    local name=$1 scope=$2 task=$3 prompt attempt evidence="" task_env rc=0
    local session_status="" unfinished=0 prev_output=""

    # The TASK's own knobs, resolved here rather than read from the ambient NS_TASK_* that
    # tier2_resolve_task left behind: the shard fan-out runs tonight's one task, but the reactive
    # pass runs all four in parallel, and a shared NS_TASK_PONYTAIL would render three of the four
    # prompts at the wrong mode. The eval is BARE (no export, no `set -a`) for the same reason
    # tier2_resolve_task's is -- these stay orchestrator-local and never reach a claude session --
    # and it is safe in this shell because both callers invoke this function with `&`.
    #
    # `sweep` is the reactive SWEEP pseudo-task -- three lenses in one session -- and has no
    # [tasks.sweep] table on purpose: adding one would insert it into the nightly cycle rotation,
    # which reads [tasks.*] in file order. It borrows dead-code's knobs, the strictest of the three
    # it covers, and the same value parse_result clamps an unrecognised label to.
    local env_task="$task"
    case "$task" in sweep) env_task="dead-code" ;; esac
    task_env="$(ns_jac tasks env "$env_task" "$CONFIG")" || rc=$?
    case "$rc$task_env" in
        0?*) : ;;
        *)  ns_fail "audit[$name]" "[tasks.$env_task] did not yield a usable NS_TASK_* env (rc=$rc)"
            return 1 ;;
    esac
    eval "$task_env"

    # A coverage audit with no evidence is a coverage audit that guesses, and `{coverage_evidence}`
    # rendered empty reads to the model as "nothing here is untested". tier2_main removes the file
    # when covmap fails, so absence here is unambiguous.
    if [ "$task" = coverage ] && [ ! -s "$LOG_DIR/covmap.json" ]; then
        ns_log S3 "audit[$name] skipped: coverage lens with no covmap evidence"
        return 1
    fi

    # The evidence filter follows the SCOPE, not the task: a shard filters by its declared paths, a
    # reactive lens by the exact files that merged. Keyed on the name because that is the one thing
    # the two callers already differ in by construction (the reactive lenses are named
    # reactive-<task>), which keeps the argv at three.
    if [ "$task" = coverage ]; then
        case "$name" in
            reactive-*) evidence="$(ns_jac covmap paths "$LOG_DIR/covmap.json" "$LOG_DIR/reactive-files.txt" 40)" ;;
            *)          evidence="$(ns_jac covmap top "$LOG_DIR/covmap.json" "$name" "$CONFIG" 40)" ;;
        esac
    fi
    # {coverage_evidence} only appears in prompts/audit-coverage.md, and only the coverage task
    # fills it. For the other three it substitutes to the empty string, which is correct: their
    # prompts do not carry the placeholder at all (bin/test-harness.sh section 11 pins that).
    prompt="$(render_prompt "$NS_ROOT/prompts/audit-$task.md" \
        "shard=$name" "scope=$scope" "coverage_evidence=$evidence" \
        "protect_globs=$NS_PROTECT_GLOBS" "ponytail_mode=$NS_TASK_PONYTAIL")"

    # The audit is the expensive model by DEFAULT: it is judgement work, and a bad finding costs a
    # whole 25-minute apply session downstream (design spec 13).
    #
    # THE A/B. [shards].sonnet_shards names the shards audited on the cheap model instead. It exists
    # because "is Opus worth 1.67x Sonnet for the audit" is a question no amount of staring at the
    # existing data can answer -- all 12 audits on 2026-07-31 ran Opus, so there is no comparison in
    # it. sessions.jsonl already records `model`, `total_cost_usd` and `findings_out` per session, so
    # naming two shards here makes the next few nights answer it as a query:
    #
    #   findings per dollar, by model, over shards that ran both
    #
    # NAMED, NOT SAMPLED. A random half would be cheaper to write and useless to read: the shards
    # differ enormously in size and character (compiler-passes vs periphery), so a model difference
    # and a shard difference would be inseparable. Fixed names mean the SAME shard is measured on the
    # same model night after night, and the comparison is against that shard's own Opus history.
    # It is also the reason this is not `Math.random`-shaped: a reproducible night is worth more
    # than an unbiased sample here.
    #
    # Reactive lenses are deliberately NOT eligible -- they are the expensive caller and the one
    # whose findings feed same-night applies, so an experiment there costs more and risks more.
    local audit_model="$NS_AGENT_MODEL"
    case "$name" in
        reactive-*) : ;;
        # config.jac renders a TOML array as its JSON text (`["periphery", "scale"]`), so the
        # membership test matches the QUOTED name. That is not a shortcut around parsing -- it is
        # what makes it exact: bare-substring matching would let a future shard named `cli-extra`
        # be caught by an entry for `cli`.
        *)  case "${NS_SHARDS_SONNET_SHARDS:-}" in
                *"\"$name\""*)
                    audit_model="$NS_AGENT_MODEL_SIMPLE"
                    ns_log S3 "audit[$name] on $audit_model (A/B: [shards].sonnet_shards) — compare findings/\$ against this shard's Opus nights in sessions.jsonl" ;;
            esac ;;
    esac

    # THE PER-SESSION MONEY CAP, SPLIT BY CALLER. Both callers of this function pass through the one
    # `--max-budget-usd` below, and their per-turn costs differ 2.2x (2026-07-31: reactive $0.139/turn
    # over 207 turns, cycle shards $0.0638/turn over 601). A single number therefore cannot bound both:
    # set for the shards it lets four reactive lenses bill $48 of a $50 night before the fan-out is
    # scheduled at all; set for the lenses it truncates shard audits that were going to succeed.
    # Keyed on the NAME prefix, the same thing the coverage-evidence filter above keys on and the one
    # attribute the two callers already differ in by construction (reactive_main passes
    # "reactive-<task>"), so the argv stays at three.
    #
    # `case`, not `[ "$x" = y ] && z`: this is the last statement before the loop and an `&&` that
    # takes the false branch returns 1, which under this file's `set -e` discipline would abort the
    # audit before it ran -- and a session that never ran writes a 0-byte envelope that reads as
    # "killed by the timebox". A `case` returns 0 on every arm.
    local audit_budget
    case "$name" in
        reactive-*) audit_budget="$NS_BUDGETS_REACTIVE_AUDIT_MAX_BUDGET_USD" ;;
        *)          audit_budget="$NS_BUDGETS_AUDIT_MAX_BUDGET_USD" ;;
    esac

    # Up to 2 attempts: a transient API error (e.g. "Connection closed mid-response") shouldn't
    # burn this scope. Each attempt is time-boxed; the parse decides success.
    # </dev/null on every claude call is load-bearing: the driver loop feeds stdin, and without
    # it one session EATS the remaining scope list (the same bug that cost 5 of 6 themes in
    # tier2_apply — see the comment there).
    for attempt in 1 2; do
        # dev jac first on PATH so the agent's Bash(jac *) and the jac MCP server hit the repo binary.
        (cd "$REPO" && export PATH="$(dirname "$NS_PATHS_JAC_REPO"):$PATH" \
            && ns_timebox "$NS_BUDGETS_AUDIT_TIMEOUT_MIN" "$NS_PATHS_CLAUDE" -p "$prompt" \
            --model "$audit_model" \
            --permission-mode dontAsk \
            --allowedTools "Read,Grep,Glob,Bash(jac code *),Bash(jac check *),Bash(jac guide *),mcp__jac__*" \
            --max-turns "$NS_BUDGETS_AUDIT_MAX_TURNS" \
            --max-budget-usd "$audit_budget" --output-format json) \
            > "$LOG_DIR/audit-$name.json" < /dev/null || true

        # Every session's own reported cost goes on the night's ledger, before any parse can fail:
        # a session that produced nothing usable still spent the money, and the four reactive lenses
        # that cost $28.72 for five findings are exactly the ones a "record it if it worked"
        # accumulator would have missed.
        ns_spend_add "$LOG_DIR/audit-$name.json"

        # 0-byte envelope = the timebox killed the session before it printed anything; a longer
        # audit_timeout_min (not a re-prompt) is the lever for that failure mode.
        if [ ! -s "$LOG_DIR/audit-$name.json" ]; then
            unfinished=1; session_status="unfinished:no-output"
            ns_log S3 "audit[$name] attempt $attempt DID NOT FINISH (no output — killed at ${NS_BUDGETS_AUDIT_TIMEOUT_MIN}m?)"
            continue
        fi

        ns_jac parse_result meta < "$LOG_DIR/audit-$name.json" > "$LOG_DIR/meta-audit-$name.json" || true

        if ns_jac parse_result findings "$task" "$NS_TASK_SCORING" < "$LOG_DIR/audit-$name.json" \
                > "$LOG_DIR/findings-$name.json" 2> "$LOG_DIR/parse-err-audit-$name.txt"; then
            unfinished=0
            ns_log S3 "audit[$name]: $(ns_jac parse_result len < "$LOG_DIR/findings-$name.json" || echo 0) findings"
            return 0
        fi

        # Hard account limit: leave a marker so the DRIVER can drop to serial / stop scheduling.
        if grep -q "hit your session limit" "$LOG_DIR/audit-$name.json"; then
            touch "$LOG_DIR/.session-limit"
            ns_fail "audit[$name]" "Claude session limit hit"
            rm -f "$LOG_DIR/findings-$name.json"
            return 1
        fi

        # "DID NOT FINISH" and "finished but emitted bad JSON" are OPPOSITE failures, and the
        # corrective re-prompt below repairs only the second. A session killed at the turn cap or
        # the timebox has NO output to correct: the 1-turn re-prompt gets an empty "Previous
        # output" block, answers `[]`, and an expensive truncated audit is filed as a clean audit
        # that found nothing. Observed 2026-07-31 — three reactive lenses at num_turns=46 against a
        # cap of 45, each logged "salvaged via corrective re-prompt — 0 findings", $18.96 spent to
        # record three empty results. That is this project's dominant defect class, "did not run"
        # scoring as "passed", and the classifier is in Jac (parse_result status, total by
        # construction) so no failure of it can land here as "completed".
        session_status="$(ns_jac parse_result status < "$LOG_DIR/audit-$name.json" 2>/dev/null || echo unfinished:unreadable)"
        case "$session_status" in
            unfinished:*)
                unfinished=1
                ns_log S3 "audit[$name] attempt $attempt DID NOT FINISH (${session_status#unfinished:}) — no output to correct; this scope FAILED, it did not find zero"
                rm -f "$LOG_DIR/findings-$name.json"   # 0-byte leftover of the redirect above
                continue ;;
        esac
        unfinished=0

        # SECOND, INDEPENDENT GUARD on the same defect, because the two failures overlap by
        # construction rather than by coincidence. The re-prompt builds its `Previous output:` block
        # from `parse_result field result`, and that field is EMPTY exactly when the parse error was
        # "envelope has no .result field" — so the one case that most needs repairing is the one
        # case the repair session is handed nothing to repair. It then does the only thing it can:
        # it refuses in prose and illustrates the refusal with an empty array. From
        # logs/2026-07-31/audit-repair-reactive-abstraction.json, verbatim:
        #   "No prior audit in context. 'Previous output' block empty — findings gone ...
        #    ```json\n[]\n```\n That empty array is placeholder, not result."
        # The fence was parsed. The refusal became "0 findings". reactive-maintenance escaped only
        # because its refusal happened to omit the fence — luck, not a guard.
        # So: NEVER spend a repair session that can only fabricate. Computed ONCE, into a variable,
        # so the thing that is checked is byte-for-byte the thing that is sent.
        prev_output="$(ns_jac parse_result field result < "$LOG_DIR/audit-$name.json" 2>/dev/null || true)"
        case "$prev_output" in
            "") unfinished=1
                session_status="unfinished:empty-result"
                ns_log S3 "audit[$name] attempt $attempt left NO output to correct — refusing the repair session, which could only invent one; this scope FAILED, it did not find zero"
                rm -f "$LOG_DIR/findings-$name.json"
                continue ;;
        esac

        # Live envelope from a session that RAN TO COMPLETION and left real output, bad JSON: one
        # cheap single-turn corrective re-prompt before burning the attempt — two whole nights died
        # to malformed audit output with no salvage.
        ns_timebox 3 "$NS_PATHS_CLAUDE" -p "Your audit output failed validation: $(cat "$LOG_DIR/parse-err-audit-$name.txt")
Previous output:
$prev_output
Re-emit ONLY the corrected \`\`\`json fenced findings array — same schema, no prose." \
            --model "$audit_model" --max-turns 1 --output-format json \
            > "$LOG_DIR/audit-repair-$name.json" < /dev/null || true
        ns_spend_add "$LOG_DIR/audit-repair-$name.json"
        if ns_jac parse_result findings "$task" "$NS_TASK_SCORING" < "$LOG_DIR/audit-repair-$name.json" > "$LOG_DIR/findings-$name.json"; then
            ns_log S3 "audit[$name] salvaged malformed JSON from a COMPLETED session — $(ns_jac parse_result len < "$LOG_DIR/findings-$name.json" || echo 0) findings"
            return 0
        fi
        ns_log S3 "audit[$name] attempt $attempt completed but its output stayed malformed even after corrective re-prompt"
    done
    # The two outcomes are reported with different words, because "the session never finished" is a
    # turn/timeout/budget cap to raise and "the output was malformed" is a prompt to fix.
    case "$unfinished" in
        1) ns_fail "audit[$name]" "session never finished (${session_status#unfinished:}) after retry — this scope contributes nothing, and its truncated output was NOT converted into an empty result" ;;
        *) ns_fail "audit[$name]" "malformed audit output after retry — this scope contributes nothing" ;;
    esac
    rm -f "$LOG_DIR/findings-$name.json"
    return 1
}

# Fan out audit shards, <concurrency> at a time, then merge into one findings array.
# A session limit collapses the fan-out to serial rather than aborting the tier: the old
# behavior lost every remaining shard to one limit signal.
tier2_audit_all() {
    local shard conc merged spent
    conc="${NS_SHARDS_CONCURRENCY:-2}"
    rm -f "$LOG_DIR/.session-limit"

    # The shard list is MATERIALIZED and both its exit status and its emptiness checked, rather
    # than iterated straight out of `for shard in $(ns_jac shards list "$CONFIG")`. `set -e` does
    # not fire on `for x in $(false)`, so a malformed [shards] table -- or any jac error in the
    # reader -- made both loops below iterate ZERO times: no session was ever started, n_found
    # stayed 0, and the night logged "every shard failed or produced nothing" while tier2_main
    # returned 0. The entire agentic tier silently no-ops and the message blames the audit rather
    # than the config. This is byte-for-byte the discarded-reader bug lib/cimirror.sh:119-144 and
    # lib/verify.sh:407-420 both already document fixing; it survived here.
    # Read ONCE and reused by the collect loop below, so the two cannot disagree either.
    local shard_list shard_rc=0 n_total
    shard_list="$(ns_jac shards list "$CONFIG")" || shard_rc=$?
    if [ "$shard_rc" -ne 0 ] || [ -z "$shard_list" ]; then
        ns_die "$EX_BUG" "could not read the shard list from $CONFIG (rc=$shard_rc, $(printf '%s' "$shard_list" | wc -w | tr -d ' ') names). An empty list iterates zero times and is indistinguishable from 'every shard failed', which is what this used to be reported as."
    fi
    n_total="$(printf '%s\n' "$shard_list" | wc -w | tr -d ' ')"

    # `for` over the materialized list, NOT a pipe: a piped `while` loop would run in a subshell
    # whose `jobs -rp` cannot see the sessions, and ns_jobs_wait would never throttle anything.
    # Concurrent shards each fork their own `ns_jac` calls, which SHARE one .jac/data/anchor_store.db;
    # jac can print "database is locked" on stderr under that contention (exit status and stdout stay
    # correct). That stderr lands in parse-err-audit-$shard.txt, which the corrective re-prompt below
    # pastes verbatim — so a lock warning can show up inside a re-prompt. Cosmetic, not a failure.
    for shard in $shard_list; do
        # log the collapse ONCE, not once per remaining shard
        if [ -f "$LOG_DIR/.session-limit" ] && [ "$conc" != 1 ]; then
            ns_log S3 "session limit seen — dropping to serial for the remaining shards"
            conc=1
        fi
        # WHAT THIS ACTUALLY RESERVES, stated honestly because the obvious reading is wrong: it
        # stops SCHEDULING once fewer than AUDIT+APPLY minutes remain, which is NOT the same as
        # guaranteeing tier2_apply an APPLY window. The shards already in flight when the guard
        # last passed still run to their own AUDIT_TIMEOUT, and the unconditional `wait` after the
        # loop drains them -- so up to another full AUDIT_TIMEOUT can elapse after the last
        # scheduling decision. Worst case the apply phase starts with roughly APPLY - AUDIT
        # minutes, not APPLY. Reserving 2*AUDIT+APPLY (65m of a 180m night at today's budgets)
        # would make the reservation real, at the cost of ending the fan-out much earlier; not
        # done, because tier2_apply already re-checks the clock per theme
        # (APPLY_TIMEOUT + 20 below) and defers themes to a future night rather than truncating
        # one mid-session. So the failure mode this under-reservation causes is "fewer themes
        # tonight", not a corrupted branch.
        if [ "$(ns_remaining_min)" -lt $(( NS_BUDGETS_AUDIT_TIMEOUT_MIN + NS_BUDGETS_APPLY_TIMEOUT_MIN )) ]; then
            ns_warn "clock too short to schedule more audit shards — stopping the fan-out at $shard (in-flight shards still drain below)"
            break
        fi
        # THE MONEY BRAKE, sitting beside the clock brake because it is the same kind of guard: the
        # clock never stopped this fan-out on 2026-07-31 (97 minutes of 480) and the bill was the
        # thing that ran away. Same under-reservation caveat as the clock guard above -- the shards
        # already in flight still finish and still spend -- so the real ceiling is
        # night_budget_usd + up to <concurrency> audit sessions.
        if ! spent="$(ns_spend_check)"; then
            ns_warn "NIGHT COST CEILING reached ($spent USD) — stopping the audit fan-out at $shard; no further audit sessions will be scheduled tonight"
            break
        fi
        ns_jobs_wait "$conc"
        # Scope and task are passed EXPLICITLY: the same function drives the reactive pass with a
        # merged-file list and one of the other three tasks, and nothing may be inferred from
        # ambient NS_TASK_* state that only one of the two callers sets up.
        tier2_audit_shard "$shard" "$(ns_jac shards scope "$shard" "$CONFIG")" "$NS_TASK_NAME" &
    done
    wait

    # Collect the shards that produced findings. NOT a bash array: under `set -u` (which
    # bin/nightshift.sh sets) bash 3.2 aborts on ${#arr[@]} and "${arr[@]}" when the array is
    # EMPTY -- and "every shard failed" is exactly the case this branch has to survive.
    # ponytail: a space-joined string is fine because $NS_ROOT (and so $LOG_DIR) contains no space --
    # a property of the install path, not of the shard names. If the harness is ever installed under a
    # path with a space, the word-split below hands `merge` broken paths and the guard on it fires.
    local found="" n_found=0
    for shard in $shard_list; do
        if [ -s "$LOG_DIR/findings-$shard.json" ]; then
            found="$found $LOG_DIR/findings-$shard.json"
            n_found=$(( n_found + 1 ))
        fi
    done
    if [ "$n_found" -eq 0 ]; then
        ns_fail "audit" "every shard failed or produced nothing — agentic tier skipped tonight"
        return 1
    fi
    # Guarded: the redirect has already TRUNCATED findings.json by the time merge can fail, and an
    # unguarded failure here would leave 0 bytes, fail tier2_select, and abort the whole night under
    # errexit -- taking S4/S5 and the reactive pass's already-queued branches with it. Skip the
    # tier instead.
    # shellcheck disable=SC2086  # deliberate word-split into one arg per shard findings file
    if ! ns_jac parse_result merge $found > "$LOG_DIR/findings.json"; then
        ns_fail "audit" "merge of $n_found shard findings failed — agentic tier skipped tonight"
        rm -f "$LOG_DIR/findings.json"
        return 1
    fi
    merged="$(ns_jac parse_result len < "$LOG_DIR/findings.json" || echo 0)"
    ns_log S3 "merged $n_found/$n_total shards into $merged findings"
    return 0
}

# Phase B — select (pure function in selector.jac; deterministic, unit-tested)
#
# `phase` is `cycle` or `reactive`. It is a FILENAME INFIX and nothing else, and it is empty for
# the cycle phase on purpose:
#
#   RECONCILIATION B6 -- findings.json and selection.json must keep those exact names. lib/dataset.sh
#   line 18 and scripts/dataset.jac lines 70/88 hardcode them, so a `-cycle` suffix would make
#   dataset_record_night return 0 having recorded nothing. This repo already fixed that exact bug
#   once, in ffdf856/e0db4a3. The reactive artifacts are NEW files (findings-reactive.json,
#   selection-reactive.json) and collide with nothing.
ns_phase_suffix() {   # ns_phase_suffix <phase>  -- "" for cycle, "-<phase>" otherwise
    case "$1" in
        cycle) printf '%s' "" ;;
        *)     printf -- '-%s' "$1" ;;
    esac
}

tier2_select() {
    local phase=$1 sfx carry="$NS_ROOT/state/carryover.json" input
    sfx="$(ns_phase_suffix "$phase")"
    input="$LOG_DIR/findings$sfx.json"

    # Carried themes are packed FIRST the next night (selector.jac sorts on the carry flag), and
    # merging them AHEAD of tonight's findings also makes the carried copy win the (file, rule)
    # dedupe in parse_result merge -- so a re-discovered finding keeps its carry flag.
    #
    # RECONCILIATION B7 -- carry-over belongs to the CYCLE phase ONLY. The reactive pass runs first;
    # if it also consumed the carry-over it would pack yesterday's deferrals into the reactive
    # phase (spec section 4 says reactive OUTRANKS carry-over, not that it absorbs it) and then
    # overwrite carryover.json with its own deferrals -- spending yesterday's carry-over twice in
    # one night and losing it.
    if [ "$phase" = cycle ] && [ -s "$carry" ]; then
        # "$input", not a second hardcoded findings.json: the two are the same file in the cycle
        # phase, and writing the name twice means a phase guard that is deleted looks harmless
        # (the merge would just fail on a missing file) instead of doing the damage B7 describes.
        if ns_jac parse_result merge "$carry" "$input" > "$LOG_DIR/findings-all.json"; then
            input="$LOG_DIR/findings-all.json"
            ns_log S3 "carry-over: $(ns_jac parse_result len < "$carry" || echo 0) deferred finding(s) packed ahead of tonight's task"
        else
            ns_fail "carry-over" "could not merge $carry — proceeding with tonight's findings only"
        fi
    fi
    # An absent/empty input is the normal shape of a night whose audit produced nothing AND which
    # has no carry-over. `return 0`, not a die: S4/S5 still have work if an earlier stage queued a
    # branch, and dataset_record_night is what reports the empty night.
    [ -s "$input" ] || { ns_log S3 "nothing to select for the $phase phase"; return 0; }

    ns_jac selector select "$CONFIG" "$LEDGER" "$STATE" "$(ns_remaining_min)" "$REPO" \
        < "$input" > "$LOG_DIR/selection$sfx.json"

    # Tonight's own deferrals become tomorrow's carry-over. Written to a temp file and moved, so a
    # failure here leaves YESTERDAY's carry-over intact rather than truncating it to nothing --
    # the redirect would otherwise have emptied the file before the reader could fail.
    #
    # Cycle phase only, per B7 above. A reactive deferral is still remembered -- the `dropped` loop
    # below upserts it into the ledger as `deferred`, and the next audit that re-finds it keeps its
    # fingerprint -- it simply does not get to displace the cycle phase's carry-over file, which is
    # the one thing tomorrow night reads first.
    if [ "$phase" = cycle ]; then
        if ns_jac parse_result field carryover < "$LOG_DIR/selection.json" > "$carry.tmp"; then
            mv "$carry.tmp" "$carry"
            ns_log S3 "carry-over for the next night: $(ns_jac parse_result len < "$carry" || echo 0) finding(s)"
        else
            rm -f "$carry.tmp"
            ns_fail "carry-over" "could not extract tonight's carryover set — yesterday's file left untouched"
        fi
    fi

    # findings the selector shed for budget/clock reasons are remembered as deferred (TPRD 9), and
    # teed to $LOG_DIR/deferred.jsonl so the digest can list them without re-scanning the ledger.
    local fp file reason drow
    ns_jac selector dropped "$LOG_DIR/selection$sfx.json" | while IFS=$'\t' read -r fp file reason; do
        case "$reason" in
            over-theme-budget|over-night-budget|no-clock-left)
                # Projected by Jac, never composed here (same rule ship_pr_row and inventory_row
                # follow), and never fatal: losing a digest row must not also lose the ledger row
                # that is the actual system of record for a deferral.
                if drow="$(ns_jac cigate deferred "fingerprint=$fp" "file=$file" "reason=$reason" "phase=$phase" 2>&1)"; then
                    printf '%s\n' "$drow" >> "$LOG_DIR/deferred.jsonl"
                else
                    ns_warn "could not project a deferred.jsonl row for $file ($reason): $drow — the digest will not list it"
                fi
                printf '{"fingerprint":"%s","file":"%s","rule":"unknown","summary":"deferred by selector","status":"deferred"}\n' "$fp" "$file" \
                    | ns_jac ledger upsert "$LEDGER" >/dev/null ;;
        esac
    done
}

# A theme deferred BEFORE its apply session started, rejoined to the one carry-over stream.
#
# THE HOLE THIS CLOSES. tier2_select writes state/carryover.json from selection.json's `carryover`
# field, and that field only ever describes findings the selector could not PACK -- over-night-budget
# and no-clock-left. A theme that was packed, selected, and then turned away at the door by one of
# tier2_apply's guards fell outside all three of the places this system remembers work:
#   * no `in_theme` ledger row  — ns_jac ledger upsert-theme runs only after a session succeeds,
#   * nothing in carryover.json — tier2_select wrote it before the apply loop ever ran,
#   * only an ns_fail row       — which the digest reports and nothing ever reads back.
# So its findings were not re-discovered and not retried; they were gone. Harmless-looking while the
# only apply guard was the clock (which fires at the tail of a night, on themes the next audit would
# re-find anyway); not harmless at all from 2026-08-04, when the night cost ceiling started deferring
# themes from the FRONT of the loop -- on 2026-08-03's numbers that is most of the selection.
#
# THE SAME MECHANISM, not a parallel one: same file, same carry-flagged finding shape (see
# selector.jac carry_findings), and therefore the same read at the top of tier2_select tomorrow.
#
# APPENDED, never overwritten -- `parse_result merge` over the existing file, oldest first, so the
# carried copy still wins the (file, rule) dedupe. That is also why this is safe in BOTH phases
# despite RECONCILIATION B7: B7 forbids the reactive pass DISPLACING the cycle phase's carry-over
# file, and a merge cannot displace anything. A reactive theme deferred here is simply offered to
# tier2_select cycle later the same night, and re-carried by it if it does not fit there either.
#
# NEVER FATAL, and loud when it fails: this runs inside the apply loop under errexit, and losing a
# carry-over row must not also lose the themes behind it in the queue.
tier2_defer_theme() {   # tier2_defer_theme <theme.json> <label> <why>
    local theme_file=$1 label=$2 why=$3 carry="$NS_ROOT/state/carryover.json"
    ns_fail "theme $label" "$why"
    [ -s "$carry" ] || printf '[]\n' > "$carry"
    if ns_jac selector carryover "$theme_file" > "$carry.defer" \
        && ns_jac parse_result merge "$carry" "$carry.defer" > "$carry.tmp"; then
        mv "$carry.tmp" "$carry"
        ns_log S3 "theme $label carried to the next night ($(ns_jac parse_result len < "$carry" || echo 0) finding(s) now deferred)"
    else
        rm -f "$carry.tmp"
        ns_fail "theme $label" "deferred, but its findings could not be added to $carry — they will not be retried unless a future audit re-finds them"
    fi
    rm -f "$carry.defer"
}

# Phase C — apply: fresh branch + fresh headless session per theme
tier2_apply() {
    local phase=$1 sfx slug bslug branch theme_file prompt remaining attempt got_report limit_hit
    local theme_task theme_cx attempt_model spent
    sfx="$(ns_phase_suffix "$phase")"
    # tier2_select writes no selection$sfx.json when there was nothing to select (see its own
    # `[ -s "$input" ] || return 0` guard) -- e.g. every audit shard found nothing and there was no
    # carry-over. `selector split` on a missing file raises in Jac and exits nonzero printing
    # nothing, and under this file's errexit that would abort the whole night instead of the quiet
    # no-op the rest of this phase already treats as normal.
    [ -s "$LOG_DIR/selection$sfx.json" ] || { ns_log S3 "nothing to apply for the $phase phase"; return 0; }
    ns_jac selector split "$LOG_DIR/selection$sfx.json" "$LOG_DIR" | while IFS= read -r slug; do
        theme_file="$LOG_DIR/theme-$slug.json"

        remaining="$(ns_remaining_min)"
        if [ "$remaining" -lt $(( NS_BUDGETS_APPLY_TIMEOUT_MIN + 20 )) ]; then
            tier2_defer_theme "$theme_file" "$slug" "no clock left — deferred to a future night"
            continue
        fi

        # THE MONEY BRAKE, sitting beside the clock brake because it is the same kind of guard and
        # defers to the same place. It was DELIBERATELY absent until 2026-08-04, on the arithmetic
        # of 2026-07-31: eleven applies were $9.19 of $76.55, audits were 88% of the bill, and
        # gating the applies would have thrown away work the night had already paid to find.
        # 2026-08-03 killed that premise. The fan-out stopped itself at $54.78 of 50.00 at 00:19:30
        # and the night still finished at $109.73, because sixteen more apply sessions were spawned
        # between 00:26 and 01:56 with nothing checking, and the applies were $60.25 of that bill --
        # 55%, not 12%. A ceiling that governs one of the two spending paths is not a ceiling.
        # FAILS CLOSED: ns_spend_check (lib/common.sh) returns nonzero for an unreadable, malformed
        # or unsummable ledger as well as for a spent one, and both stop the theme. A cost brake
        # that cannot be evaluated must not read as "budget left" -- see the same note there.
        # The honest residual, stated as the fan-out guard states its own: the check is per THEME,
        # so a theme that passes it and then retries can straddle the ceiling by one more session,
        # bounded by [budgets].max_budget_usd. It cannot run a theme that starts over the line.
        if ! spent="$(ns_spend_check)"; then
            tier2_defer_theme "$theme_file" "$slug" \
                "NIGHT COST CEILING reached ($spent USD) — no apply session started; deferred to a future night"
            continue
        fi

        # The theme's OWN task, not tonight's: a carry-over night packs themes from an earlier
        # task alongside tonight's, and each needs its own rules block. The value is
        # harness-written (parse_result stamps it from argv, never from the finding), so reading
        # it back here is not trusting the agent. The security-critical read -- which write
        # permissions the S4 gate applies -- comes from the BRANCH NAME instead (Task 6).
        theme_task="$(ns_jac parse_result field task < "$theme_file")"
        case "$theme_task" in
            "") ns_die "$EX_BUG" "theme $slug carries no task; refusing to pick an apply-rules block for it" ;;
        esac
        [ -f "$NS_ROOT/prompts/apply-rules-$theme_task.md" ] \
            || ns_die "$EX_BUG" "no prompts/apply-rules-$theme_task.md for theme $slug"

        # THE BRANCH SLUG. selector.jac builds `<task>-<theme-hint>`; a reactive theme becomes
        # `<task>-reactive-<theme-hint>`, so the two phases cannot collide on a branch name even
        # when they land on the same file with the same hint.
        #
        # RECONCILIATION B2 -- the marker goes AFTER the task, never in front of it. lib/common.sh's
        # ns_task_of_branch resolves the task from the slug BY PREFIX, and that resolution is the
        # sole input to check_scope's protect_unless. A `reactive-` prefix would make every reactive
        # branch fail S4 unresolved, and `reactive-coverage-*` would never receive the `tests/**`
        # write exemption that is the only reason a coverage branch can write anything at all.
        #
        # The theme file is MOVED to match, because $LOG_DIR/theme-<branch-basename>.json is where
        # ns_theme_for_branch looks and where lib/ship.sh copies from -- a branch whose theme file
        # is named after the pre-rename slug re-gates with no theme, which ns_theme_for_branch
        # (correctly) treats as fatal rather than as "skip scope containment".
        case "$phase" in
            cycle) bslug="$slug" ;;
            *)     bslug="$theme_task-$phase-${slug#"$theme_task"-}"
                   mv "$theme_file" "$LOG_DIR/theme-$bslug.json"
                   theme_file="$LOG_DIR/theme-$bslug.json" ;;
        esac
        branch="nightshift/$NS_DATE/$bslug"
        # ...and that task's OWN knobs, re-evaluated per theme. A carried theme belongs to an
        # earlier night's task and keeps its own ponytail mode: rendering it at TONIGHT's
        # NS_TASK_PONYTAIL is how a carried coverage theme would silently be told to YAGNI away the
        # test it exists to write. The eval is bare for the same reason tier2_resolve_task's is.
        eval "$(ns_jac tasks env "$theme_task" "$CONFIG")"
        # Complexity decides attempt 1's model. Empty (an old theme file from before Task 2) falls
        # through ns_attempt_model's `*)` arm to the EXPENSIVE model, which is the safe direction.
        theme_cx="$(ns_jac parse_result field complexity < "$theme_file")"
        prompt="$(render_prompt "$NS_ROOT/prompts/apply.md" \
            "theme=$(cat "$theme_file")" "ponytail_mode=$NS_TASK_PONYTAIL" \
            "task_apply_rules=$(cat "$NS_ROOT/prompts/apply-rules-$theme_task.md")")"

        # Up to 2 attempts, each on a FRESH branch: a transient API error mid-session (same class
        # tier2_audit already retries) shouldn't burn the whole theme for the night.
        # checkout -f everywhere: a session killed mid-edit leaves uncommitted changes that would
        # otherwise ride along into the next theme's branch and be committed as if that theme had
        # made them. (The original rationale named tier-1's autofix as what would sweep them up;
        # tier-1 was retired 2026-07-30 and the discard is now the only thing standing between a
        # killed session and a mislabelled diff, which makes the -f more load-bearing, not less.)
        # THE BASE. Cut from main unless another theme applied EARLIER TONIGHT already claimed one
        # of this theme's files, in which case cut from that branch instead -- see ns_base_of_branch
        # (lib/common.sh) for why stacks exist and why the base is not a theme key.
        #
        # Recorded BEFORE the first attempt and never recomputed between attempts: attempt 2 must
        # land on the same base as attempt 1, or a retry would silently change what the S4 gate
        # treats as this branch's own diff. `claims.tsv` is appended only after a branch is queued,
        # so a theme that failed both attempts claims nothing and no later theme stacks on a branch
        # that does not exist.
        local base
        if ns_stacking_on; then
            base="$(ns_jac selector stack-base "$theme_file" "$LOG_DIR/claims.tsv")" || base=""
        else
            base=""
        fi
        [ -n "$base" ] || base="$NS_REPO_DEFAULT_BRANCH"
        ns_stack_record "$branch" "$base"
        case "$base" in
            "$NS_REPO_DEFAULT_BRANCH") : ;;
            *) ns_log S3 "theme $bslug shares a file with $base — stacking on it rather than on $NS_REPO_DEFAULT_BRANCH" ;;
        esac

        got_report=0
        limit_hit=0
        for attempt in 1 2; do
            attempt_model="$(ns_attempt_model "$attempt" "$theme_cx")"
            ns_log S3 "apply $bslug attempt $attempt on $attempt_model (task=$theme_task, complexity=$theme_cx, base=$base)"
            cd "$REPO"
            git checkout -f "$NS_REPO_DEFAULT_BRANCH" 2>/dev/null || true
            git branch -D "$branch" 2>/dev/null || true
            git checkout -B "$branch" "$base"

            # </dev/null is load-bearing: claude reads stdin, and stdin here is the slug pipe
            # from `selector split` — without it the first session EATS the remaining themes
            # (observed live: 6 themes selected, 1 attempted, 5 silently never ran).
            (cd "$REPO" && export PATH="$(dirname "$NS_PATHS_JAC_REPO"):$PATH" \
                && ns_timebox "$NS_BUDGETS_APPLY_TIMEOUT_MIN" "$NS_PATHS_CLAUDE" -p "$prompt" \
                --model "$attempt_model" \
                --permission-mode acceptEdits \
                --allowedTools "Read,Edit,Grep,Glob,Bash(jac fmt *),Bash(jac check *),Bash(jac code *),Bash(jac test *),Bash(git diff *),Bash(git status *),Bash(git log *),Bash(git add *),Bash(git rm *),Bash(git commit *),mcp__jac__*" \
                --max-turns "$NS_BUDGETS_MAX_TURNS" --max-budget-usd "$NS_BUDGETS_MAX_BUDGET_USD" \
                --output-format json) > "$LOG_DIR/apply-$bslug.json" < /dev/null || true

            # Apply spend is ACCUMULATED here, which is what makes the per-theme brake at the top of
            # this loop see its own cost and not just the audits' — see [budgets].night_budget_usd.
            ns_spend_add "$LOG_DIR/apply-$bslug.json"

            ns_jac parse_result meta < "$LOG_DIR/apply-$bslug.json" > "$LOG_DIR/meta-apply-$bslug.json" || true

            if ns_jac parse_result report < "$LOG_DIR/apply-$bslug.json" > "$LOG_DIR/report-$bslug.json"; then
                got_report=1
                break
            fi
            # A hard account limit fails every retry and every later theme until it resets —
            # observed: "You've hit your session limit · resets 7am". Stop burning the night.
            if grep -q "hit your session limit" "$LOG_DIR/apply-$bslug.json"; then
                limit_hit=1
                ns_log S3 "Claude session limit hit — retrying is pointless until it resets"
                break
            fi
            ns_log S3 "apply $bslug attempt $attempt failed to parse (transient API error?) — $([ "$attempt" = 1 ] && echo retrying || echo giving up)"
        done

        if [ "$got_report" -ne 1 ]; then
            ns_fail "theme $bslug" "apply session died or returned malformed report after retry — branch discarded"
            rm -f "$LOG_DIR/report-$bslug.json"    # empty/invalid leftover from the failed redirect — sendmail's digest globs report-*.json
            git checkout -f "$NS_REPO_DEFAULT_BRANCH"; git branch -D "$branch" || true
            if [ "$limit_hit" = 1 ]; then
                ns_fail "agentic tier" "session limit — remaining themes deferred to a future night"
                break
            fi
            continue
        fi

        # ...against its BASE, not against main. On a stacked branch the parent's diff is present in
        # the working tree by construction, so a main-relative check would read a branch on which
        # the agent did nothing at all as one that made changes, ship the parent's work a second
        # time under this theme's name, and hand the S4 scope gate a diff of files this theme never
        # declared. Empty-against-base is the only thing that means "the agent did nothing".
        if git diff --quiet "$base...HEAD" 2>/dev/null; then
            ns_fail "theme $bslug" "agent made no committed changes on top of $base — branch discarded"
            git checkout -f "$NS_REPO_DEFAULT_BRANCH"; git branch -D "$branch" || true
            continue
        fi

        # The ORCHESTRATOR writes the release-note fragment — the agent has no Write tool (TPRD S3-C).
        # Path derives from the theme's own files (via the report the agent returned): only
        # jac/jaclang/** needs a fragment at all, and a theme can now span shards, so there is
        # no package name left to put in the path or the commit subject.
        # The KIND comes from the theme, which selector.jac copied from [tasks.<task>].fragment:
        # "" (coverage) means no fragment at all, "auto" (maintenance) means the agent picks and
        # render_draft validates. Passing it is what removes the last of the three sites that
        # hardcoded `refactor` while the S4 gate already honoured the theme's kind.
        local frag_kind fragment
        frag_kind="$(ns_jac parse_result field fragment_kind < "$theme_file")"
        fragment="$(ns_jac render_draft frag "$LOG_DIR/report-$bslug.json" "$frag_kind")"
        if [ -n "$fragment" ]; then
            mkdir -p "$(dirname "$REPO/$fragment")"
            # `fragment`, not `field`: normalizes into bullet form (nslib.normalize_fragment_body)
            # so an agent's plain-English release_note_md can't reach a commit unbulleted and
            # fail CI's content-format check (ci.yml contribution-checks, check-release-notes.sh
            # ~line 176) while the local gate (fragcheck.jac) would have passed it.
            ns_jac parse_result fragment release_note_md < "$LOG_DIR/report-$bslug.json" > "$REPO/$fragment"
            git add "$fragment"
            git commit -m "docs: release note fragment (nightshift)"
        else
            ns_log S3 "theme $bslug touches no jac/jaclang/ path — no fragment required"
        fi

        # QUEUE FIRST, BOOKKEEPING SECOND, AND THE BOOKKEEPING CANNOT KILL THE NIGHT.
        #
        # On 2026-08-02 these were the other way round and the ledger call was fatal. upsert_theme
        # raised KeyError on a coverage finding's schema, tier2_apply is under errexit, and S3 died
        # holding two finished apply sessions -- $17.42 of work, two committed branches -- that S4
        # never gated and S5 never shipped. The schema bug is fixed in scripts/ledger.jac, but the
        # SHAPE is the real defect: a bookkeeping write was standing between finished work and the
        # gate that ships it, and any future failure in it would do the same thing again.
        #
        # ns_queue_branch is what makes the work reachable, so it goes first and stays fatal. The
        # ledger row is how tomorrow avoids re-buying this finding: losing it costs one duplicate
        # audit, which is strictly cheaper than losing the night. Loud, never silent -- a missing
        # row means the dedup in scripts/selector.jac will not fire for these fingerprints.
        ns_queue_branch "$branch" "$theme_file" "$LOG_DIR/report-$bslug.json"
        ns_jac ledger upsert-theme "$theme_file" "$branch" "$LEDGER" >/dev/null \
            || ns_fail "theme $bslug" "ledger upsert-theme failed — the branch is queued and will still be gated and shipped, but its findings carry no in_theme row, so a later phase or night may re-buy them"
        # Claim this theme's file slots for the rest of the night, AFTER the branch is queued and
        # therefore known to exist. The slots come from the theme, not from `git diff`: the theme
        # is the set of files this branch was PERMITTED to touch (it is what check_scope gates
        # against), and a later theme overlapping a permitted-but-untouched file still has to stack
        # -- otherwise it starts from main, the parent later edits that file, and the two conflict
        # exactly as they would have without any of this.
        if ns_stacking_on; then
            ns_jac selector claims "$theme_file" "$branch" >> "$LOG_DIR/claims.tsv"
        fi
        git checkout -f "$NS_REPO_DEFAULT_BRANCH"
    done
}
