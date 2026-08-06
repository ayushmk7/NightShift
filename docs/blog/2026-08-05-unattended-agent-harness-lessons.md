# What I Learned Building an Unattended Agent Harness

*Part 1 of 2. Part 2 is the war story: [Inside NightShift](2026-08-05-nightshift-deep-dive.md).*

A few weeks ago I gave Claude Code a repository, a clock, and no one watching. Every night at
23:00 it wakes up, audits a ~365k-line codebase, picks a handful of findings worth a session,
gives each one its own branch and its own fresh agent, runs the result through a local replica of
the project's CI, and leaves draft PRs open by morning. I never sit at the keyboard while it runs.
That project is [NightShift](2026-08-05-nightshift-deep-dive.md), and it taught me more about
running agents unsupervised than about the codebase it audits.

The lesson that actually matters isn't "agents can code while you sleep" — that part is table
stakes now. It's what changes once nobody is at the keyboard to notice something went wrong. A
supervised agent session fails loud: you see the weird diff, the confused loop, the tool error, and
you stop it. An unsupervised one fails silent unless you built the silence out on purpose. Here's
what that meant in practice.

**Every stage has to be safe when it's wrong.** Not "unlikely to be wrong" — safe *when* it is,
because over enough nights it will be. NightShift's version of this is structural: the harness
never has the permission to merge or mark a PR ready for review. Not a policy, a missing code path
— `ns_gh_write` refuses `pr ready` and `pr merge` outright. Whatever a session decides, however
confident the diff looks, the worst outcome is a draft PR nobody asked for. That's a cheap failure
mode, and cheap failure modes are the only kind you can afford to have every night.

**Budgets need two independent enforcers, not one.** I originally gated cost only on the audit
fan-out side, on the assumption that if the discovery phase stayed in budget, the apply phase
would too. It didn't — apply sessions spawned unchecked past the ceiling and kept going after the
brake fired, once running up $109.73 across 37 sessions with 16 applies happening *after* the
budget had already tripped. A wall-clock ceiling and a dollar ceiling watching the same process
from different angles catch different failures; one checking the other's homework doesn't.

**State that survives across nights needs to survive *correctly*, or it lies to you quietly.**
NightShift keeps a ledger of findings across nights — this is worth doing, unaudited work
shouldn't have to be rediscovered from scratch — but a local cache file was getting silently
overwritten by a stale copy from the previous sync every single night, reverting a manual repair
that had already shipped. Nothing crashed. It just quietly forgot a fix for a day. If a harness
remembers anything between runs, that memory needs the same suspicion you'd give any other input,
not the built-in trust of "it's just our own state file."

**A night that dies partway through should not lose more than the work it was already going to
lose.** Early on, a single bad write in the bookkeeping path could take down the entire pipeline
after the actual work — the expensive part — had already finished. The fix wasn't "make the write
never fail," it was reordering so the fatal thing happens first and the thing that's merely
convenient to have happens after, non-fatally. Losing a ledger row costs one duplicate audit
later. Losing the queue costs the whole night's spend for nothing.

**Reactive work and scheduled work compete for the same clock, and one will starve the other if
you let it.** NightShift runs a reactive sweep over whatever merged upstream that day *and* a
scheduled sweep over the rest of the repo, and both want the same session budget. Capping them
against each other, not against a fixed number each, is what keeps a busy upstream day from
crowding out the slow structural cleanup work that never has an urgent reason to run.

None of this is exotic. It's the same discipline you'd want from any system that runs when you're
not looking — a cron job, a deploy pipeline, a monitoring rollup. Agents don't change the
discipline; they just make the cost of skipping it land somewhere less familiar, at 3am, in a PR
you didn't review being opened on a codebase you do care about.

Part 2 has the specific night this went wrong, what broke, and what "safe when wrong" looked like
in the fix: [Inside NightShift: the night a bug killed the first live run](2026-08-05-nightshift-deep-dive.md).
