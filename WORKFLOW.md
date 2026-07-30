# Nightshift — Workflow

End-to-end map of the harness, current as of the v2 foundations work (2026-07-30): whole-repo
sharded audit, and an S4 gate that runs a local replica of the CI jobs a fork PR cannot reach.
Stages `S0–S6` run nightly and unattended; `S7` is the human morning loop.
Current design: `docs/superpowers/specs/2026-07-30-nightshift-4task-design.md`; open items:
`docs/superpowers/specs/2026-07-30-nightshift-followups.md`. `docs/PRD.md` and `docs/TechnicalPRD.md`
are pre-restructure and superseded for S3 onward (they carry banners saying so).

## 1. Nightly pipeline (S0 → S6)

```mermaid
flowchart TD
    LA["launchd 02:00 · user domain"] --> CAF["caffeinate -i · nightshift.sh run"]
    CAF --> CEIL["gtimeout 180m · hard wall-clock ceiling"]
    CEIL --> S0

    subgraph S0["S0 · Preflight"]
        direction TB
        LOCK["mkdir lock · check ~/.nightshift/DISABLE"]
        GATE0{"disabled or lock held?"}
        DEPS["resolve jac/claude/gh/git paths · gh auth · network probe"]
        NET{"online and gh authed?"}
        PONG{"claude -p pong ok?"}
        DRIFT["compare jac version vs state · warn on drift"]
        LOCK --> GATE0
        GATE0 -->|"yes"| EXIT
        GATE0 -->|"no"| DEPS --> NET
        NET -->|"no · exit 43"| EXIT
        NET -->|"yes"| PONG
        PONG -->|"no · exit 42"| EXIT
        PONG -->|"yes"| DRIFT
    end
    DRIFT --> S1

    subgraph S1["S1 · Sync"]
        direction TB
        SYNC["gh repo sync fork from upstream main"]
        CONF{"main diverged?"}
        WT["worktrees · work/repo on branches · work/drafts on orphan"]
        PRUNE["prune shipped/rejected branches older than 14d"]
        PULL["pull ledger.jsonl from drafts branch"]
        SYNC --> CONF
        CONF -->|"yes · exit 44"| EXIT
        CONF -->|"no"| WT --> PRUNE --> PULL
    end
    PULL --> S3

    %% S2 (tier-1 deterministic autofix) was RETIRED 2026-07-30. A byllm-only formatting PR was
    %% noise and a repo-wide one unmergeable (~259 pre-existing violations on main), and upstream
    %% only checks formatting repo-wide on push. Themes now format their own edits; [jobs.fmt]
    %% gates that diff-scoped, exactly as CI does on a PR.

    subgraph S3["S3 · Tier 2 · agentic clean"]
        direction TB
        ROT["shards list · 8 LOC-balanced shards of the whole repo · concurrency 2"]
        AUDIT["per shard · claude -p AUDIT · read-only · dontAsk · ponytail-audit scoped to the shard"]
        PJSON{"parse_result merge · any shard produced valid findings JSON?"}
        SEL["select.jac · drop ledger-known / protected / twice-failed · score loc*conf/risk · pack <=6 themes <=10 files <=600 LOC · fit clock"]
        APPLY["per theme · fresh branch + fresh claude -p APPLY · acceptEdits · scoped tools · NO push/gh/network · validate_jac before commit"]
        RJSON{"report JSON ok and diff non-empty?"}
        FRAG["orchestrator writes release-note fragment · dir mapped jac to jaclang etc · ledger upsert-theme · queue.tsv"]
        ROT --> AUDIT --> PJSON
        PJSON -->|"no · exit 50 · nothing ships tonight"| S4
        PJSON -->|"yes"| SEL --> APPLY --> RJSON
        RJSON -->|"no"| DROP3["delete branch · ledger failed_verify"]
        RJSON -->|"yes"| FRAG
    end
    FRAG --> S4
    DROP3 --> S4

    subgraph S4["S4 · Verify gate · fail-closed · per queued branch"]
        direction TB
        SCOPE{"scope contained? · diff subset of theme files + fragment · no protected"}
        CHK{"jac check baseline-diff ok? · new errors vs main only"}
        FAST{"CI mirror fast jobs ok? · fmt · check · jir · ~3s"}
        TST{"mirrored CI suites per gated suite · baseline-diff · one retry each"}
        PC{"pre-commit ok? · fold self-mutation"}
        CTRB{"CI mirror contribution ok? · AI co-author · no .py · bun lockstep · docs · fragment"}
        DISCARD["delete branch · ledger failed_verify++ · failed.tsv"]
        GREEN["green.tsv · record tests line · tune verify_estimate"]
        SCOPE -->|"no · possible injection"| DISCARD
        SCOPE -->|"yes"| CHK
        CHK -->|"no"| DISCARD
        CHK -->|"yes"| FAST
        FAST -->|"red · seconds, not 40min"| DISCARD
        FAST -->|"green"| TST
        TST -->|"red x2"| DISCARD
        TST -->|"green"| PC
        PC -->|"red"| DISCARD
        PC -->|"green"| CTRB
        CTRB -->|"red"| DISCARD
        CTRB -->|"green"| GREEN
    end
    GREEN --> S5

    subgraph S5["S5 · Ship to fork"]
        direction TB
        PUSH["git push fork · nightshift/branch · explicit refspec · never force"]
        DRAFT["render_draft · drafts/DATE--slug.md · ledger drafted"]
        PUB["commit + push drafts branch and ledger"]
        PUSH --> DRAFT --> PUB
    end
    PUB --> S6

    EXIT["EXIT trap · fires on any exit path"] --> S6
    DISCARD -.->|"all failed · exit 51"| EXIT

    subgraph S6["S6 · Email digest · always"]
        direction TB
        SUMM["sendmail summarize · assemble run summary from log dir + drafts"]
        DRY{"dry-run?"}
        SEND{"smtp SSL send ok?"}
        RENDER["print message · no send"]
        BAN["EMAIL_FAILED marker + osascript banner"]
        OK["digest delivered"]
        SUMM --> DRY
        DRY -->|"yes"| RENDER
        DRY -->|"no"| SEND
        SEND -->|"yes"| OK
        SEND -->|"no"| BAN
    end

    %% data stores
    LEDGER[("ledger.jsonl · fingerprint to status")]
    STATE[("state.json · verify_estimate · last_jac_version")]
    DRAFTSB[("nightshift/drafts orphan branch · drafts/*.md")]
    PULL -.->|read| LEDGER
    SEL -.->|read| LEDGER
    FRAG -.->|write| LEDGER
    DISCARD -.->|write| LEDGER
    GREEN -.->|tune| STATE
    DRAFT -.->|write| LEDGER
    PUB -.->|push| DRAFTSB
```

## 2. Morning human loop (S7)

The only path to upstream. Drafts are the queue: a draft file existing means the PR is not yet opened.

```mermaid
flowchart TD
    START["morning · review digest email"] --> PICK{"per branch"}
    PICK -->|"promote"| P1["re-sync main · rebase branch on fresh main"]
    P1 --> RB{"rebase clean?"}
    RB -->|"no"| DEMO["ledger failed_verify · no PR"]
    RB -->|"yes"| REGATE{"re-run S4 gate green?"}
    REGATE -->|"no"| DEMO
    REGATE -->|"yes"| PR["gh pr create --body-file · default target upstream"]
    PR --> REN["rename fragment 0000 to PR-number · push · PR self-updates"]
    REN --> SHIP["ledger shipped + pr_url · delete draft · push drafts branch"]

    PICK -->|"discard"| DIS["delete remote branch + draft · ledger rejected with reason"]

    SHIP --> DONE["PR open upstream"]
    DIS --> BURIED["finding never resurfaces"]
    DEMO --> RETRY["retries on a future night against fresher main"]
```

## 3. Finding lifecycle

Every finding is remembered across nights so work is never re-litigated.

```mermaid
stateDiagram-v2
    [*] --> new: audit surfaces it
    new --> in_theme: selected + applied
    new --> deferred: did not fit budget/clock
    deferred --> in_theme: eligible on a later night
    in_theme --> drafted: S4 green then S5
    in_theme --> failed_verify: S4 red
    failed_verify --> in_theme: first failure · retry later
    failed_verify --> rejected: second failure · auto
    drafted --> shipped: human promote
    drafted --> rejected: human discard
    shipped --> [*]
    rejected --> [*]
```

## 4. Component and data map

bash sequences processes; Jac owns every data and logic transformation. No Python files.

```mermaid
flowchart LR
    subgraph ENTRY["bin"]
        NS["nightshift.sh · run / dry-run / promote / discard / status / baseline / mirror"]
        TH["test-harness.sh"]
    end
    subgraph LIB["lib · bash stages"]
        CM["common.sh"]
        PF["preflight.sh"]
        SY["sync.sh"]
        T2["tier2.sh"]
        VF["verify.sh"]
        SH["ship.sh"]
        EM["email.sh"]
        PR2["promote.sh"]
        CMR["cimirror.sh · runs config/ci-mirror.toml jobs"]
    end
    subgraph JAC["scripts · Jac helpers"]
        NL["nslib.jac · shared · fingerprint · globs · fragment map"]
        CF["config.jac · toml to env"]
        LG["ledger.jac"]
        CS["check_scope.jac"]
        PRz["parse_result.jac"]
        SE["selector.jac"]
        RD["render_draft.jac"]
        SM["sendmail.jac"]
    end
    subgraph EXT["external"]
        JB["jac binary · check / test / fmt / mcp"]
        CC["claude -p · ponytail + jac skills + jac mcp"]
        GH["gh · fork sync + PR"]
        SMTP["smtplib SSL"]
    end

    NS --> CM & PF & SY & T1 & T2 & VF & SH & EM & PR2 & CMR
    PF --> CF & LG
    SY --> LG & GH
    T1 --> JB & RD & CMR
    T2 --> CC & PRz & SE & LG & RD
    VF --> JB & CS & LG & CMR
    CMR --> JB
    SH --> RD & LG & GH
    EM --> SM & RD
    PR2 --> GH & LG & RD & CS & JB
    NL -.->|imported by| LG & CS & PRz & SE & RD & SM & CF
    SM --> SMTP
    TH --> JAC
```
