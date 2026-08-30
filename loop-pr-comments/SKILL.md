---
name: loop-pr-comments
description: Repeatedly run address-pr-comments on a PR until the review bot (Codex) or a human gives it a 👍 thumbs-up reaction, then stop. Self-paces between iterations and only touches NEW actionable feedback each round. Trigger when the user asks to "keep addressing PR comments until approved", "loop address-pr-comments", "babysit PR review until thumbs-up", "auto-address review feedback until the author approves", or names a PR with a convergence/until condition.
---

# Loop address-pr-comments until 👍

Run `/address-pr-comments` against a target PR on a self-paced loop. Each iteration
addresses only **new** actionable feedback. The loop converges when the review bot or a
human leaves a 👍 **newer than the current HEAD**, a human approves the PR, or the bot
replies "no major issues". One background process drives it — no Monitor, no
ScheduleWakeup, no cron:

```bash
STATE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/address-pr-comments/pr-state.sh"
"$STATE" <owner/repo> <n> --wait --timeout 1800 --ignore "<phrase>" …
```

Run it with `run_in_background: true`. It polls every 5s and exits the moment there is
something to do, re-invoking you with the decision on stdout — one wake channel, and the
wake carries the state that caused it. The 30-minute `--timeout` is a heartbeat, not a
deadline (see Waiting). `pr-state.sh --self-test` asserts its decision table.

**The one rule that breaks naive loops:** reactions are per-PR and never expire, so "is
there a 👍?" answers yes forever after the first one — a loop that stops on that converges
at iteration 0 having read nothing. The oracle only converges on signals **newer than
HEAD's commit date**, with CI finished, no conflict, and nothing actionable; `converged_by`
says which signal fired. A `+1` from a non-review bot (Socket, dependabot) never counts.
Don't re-derive any of this with your own jq — every hand-rolled copy has drifted.

## Arguments

```
loop-pr-comments [<pr-number | pr-url>] [--leave-open "<phrase>, <phrase>, …"] [--interval <seconds>]
```

- **PR** — number or URL. Default: the open PR for the current branch.
- **`--leave-open`** — comma-separated substrings for threads the bot keeps re-raising
  that must never be touched. Split on commas, **trim whitespace, drop empty fragments**
  (the oracle rejects empty phrases — one would mute every thread), pass each as its own
  `--ignore "<phrase>"` (matches path or first comment, case-insensitively). Usually
  unnecessary: author-answered open threads are already non-actionable (`answered_open`).
  A too-broad phrase silently mutes real findings — echo back `ignored_open` on the first
  iteration so a bad phrase surfaces immediately.
- **`--interval <N>`** — poll cadence in seconds, passed through. Default 5.

There is **no iteration cap** — see Stopping.

## Each iteration (in order)

1. **Resolve the PR:** the arg, else `gh pr view --json number,headRepositoryOwner,headRepository,url`
   (canonical even if `origin` is a mirror).
1b. **Confirm the checkout** before any iteration that could commit:
   `git status --short --branch` must match the PR's `headRefName` and the tree must be
   clean — after a wake-up, a compaction, or in a worktree this is not a safe assumption.
   If they disagree, stop and tell the user.
2. **Ask the oracle:** `"$STATE" <owner/repo> <n> --ignore …` and branch on `.action`:
   - `converged` / `closed` / `no_reviewer` / `error` → **stop** (see Stopping).
   - `conflict` → step 4. `address` → step 5. `trigger_review` → post the trigger, wait.
   - `wait` → launch the watcher, end the turn.
   The ordering is baked in: `address` and `conflict` outrank `converged`, so a 👍 landing
   alongside new findings or a red check does not stop the loop.
3. **CI is part of the answer** (`ci_failing`, `ci_pending`): a failing or canceled check
   is feedback; step 5's pass diagnoses the cause from the job log and fixes it. Fetch
   rows with `gh pr checks <n> --repo <owner/repo> --json bucket,name,state,link`.
4. **Resolve conflicts** when `.action` is `conflict` (`UNKNOWN` means GitHub is still
   computing — re-run the oracle once before concluding anything):
   ```bash
   git fetch origin <baseRefName>
   git merge origin/<baseRefName>      # no rebase/force-push on a shared PR branch
   # resolve keeping BOTH sides' intent, run project checks, then:
   git add -A && git commit --no-edit && git push
   ```
   Escalate semantic/non-obvious conflicts to the user instead of guessing; never discard
   the other side's work wholesale. Re-run the oracle to confirm `mergeable` flipped back.
5. **Address new feedback only.** Invoke `/address-pr-comments` via the Skill tool:
   > "PR #<n>. Only address NEW actionable review feedback this iteration, INCLUDING any
   > failing CI check. Do NOT reply to, resolve, or modify any thread matching these
   > deliberately-left-open topics: `<leave-open phrases>`."
6. **Never touch leave-open threads** — pass the phrases as `--ignore` to the oracle
   *and* restate them in the sub-skill prompt. Two guards; prose alone is unverifiable.
7. **Nothing actionable this round is fine** — the loop is waiting for a converging
   signal. Launch the watcher and end the turn; do not invent work.

## The `@codex review` trigger

Codex auto-reviews on PR-open (in some repos on every push) and often answers a round of
fix replies with a 👍 without any new review — the explicit trigger is a fallback, and
every redundant one mints a re-review that can mint new findings. **The oracle owns the
decision**: post when, and only when, `.action` is `trigger_review`, as exactly the bare
command (a request is only counted when the comment opens with it):

```bash
gh pr comment <n> --repo <owner/repo> --body '@codex review'
```

`trigger_review` already encodes: HEAD genuinely unreviewed (by the API's `head.sha`, not
your checkout) or reviewed-but-quiet 30 min with no 👍 (the nudge); no live 👀 — an active
👀 is a **reliable** in-flight marker (it's swapped for the 👍 on completion, which is why
settled PRs show none) and only expires via `--eyes-ttl` (1h) when one abnormally outlives
its review; HEAD older than the 900s grace (observed bot latency 6–40 min); and no
unanswered request outstanding (re-posts after `--retrigger-after`, 30 min). Convergence
is decided by reaction freshness, never `reviewed == head` — the 👍 is a reaction, not a
review object.

## Waiting

The last action of every iteration that ends in `wait` is to launch the watcher in the
background (`run_in_background: true`) and end the turn:

```bash
"$STATE" <owner/repo> <n> --wait --timeout 1800 --ignore "<phrase>" …
```

**Timeouts, kills and wait-wakes re-queue.** Reviews can take hours; a timeout is a
heartbeat, not a failure. On a wake with `{"action":"timeout"}` (exit 10), `"killed"`
(exit 143 — the harness SIGTERMs background shells; not a state change and not your
cue to fall back to manual polling), or any wake whose action is still `wait` (the
watcher also exits when observable state moves while non-actionable):

1. Run one foreground snapshot.
2. Anything other than `wait` → handle as a normal iteration.
3. Still `wait` → relaunch the watcher, end the turn. **Re-queues are not iterations.**

Re-queueing cannot spin forever — the oracle's own escalations transition every wait
state: a quiet reviewed HEAD gets nudged after 30 min, an unanswered request re-posts
after 30 min, a stale 👀 expires after 1 h, a bot "usage limit" reply holds the trigger
for `--limit-ttl` (1 h) then re-asks, and dead requests become `no_reviewer` (2 on a
never-engaged PR, 3 unanswered on one HEAD). If the same `wait` reason survives ~4 hours
of re-queues, something external is wrong — report it instead of re-queueing again.

If the session dies mid-wait the watcher self-terminates within 30 minutes and touches
nothing — that bound is why the timeout is 30 min with explicit re-queues, not one
multi-hour watcher. Don't use CronCreate (it outlives the session). **One watcher at a
time**: check the task list before launching; assume one loop per PR — the check is
advisory, not an atomic lease, so never run two sessions against the same PR.

## Stopping

**1. Converged** — don't run another address pass. TaskStop the watcher, apply the
`review-converged` label (address-pr-comments step 9), then produce the **convergence
report** (below) — the loop's real deliverable. If the post-report oracle re-run comes
back `address`, remove the label again and keep looping; the label tracks the oracle's
current answer, not the first time it said `converged`.

**2. No progress** — two consecutive **address passes** with the same `actionable` count
and the same HEAD: stop and say so. Trigger-only rounds are excluded (the oracle's
`no_reviewer` thresholds bound those); timeout re-queues and wait-wakes don't count
either. **Survive compaction:** record `{head, actionable, iteration count, findings
answered}` in your running notes each round — these stops compare across rounds.

**3. Ping-pong** — a thread you answered is reopened, or the same finding returns after a
fix: stop and ask the user. Two agents disagreeing about code is not resolved by looping.

**4. `error` / `closed` / `no_reviewer`** — report and stop; never improvise a fallback
query. `no_reviewer` means the bot never engaged (2 dead requests) or went dark mid-loop
(3 unanswered on this HEAD) — looping cannot summon a reviewer.

**There is deliberately NO iteration cap.** Healthy PRs routinely converge after 10–25
review rounds — a cap punishes size, not pathology; stops 2–4 detect pathology.

In every case: TaskStop the watcher and say which stop fired — "no progress: two rounds
at 3 actionable on the same HEAD" is useful; silently stopping is not.

## Convergence report

Build it from the **PR record, not session memory** (compaction eats earlier rounds; the
PR remembers). The data layer is deterministic — don't hand-roll the queries:

```bash
"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/loop-pr-comments/pr-report.sh" <owner/repo> <n> [--bot <login>] [--ignore "<phrase>"]…
```

It fills every mechanical section — Journey numbers, Fixed (resolved threads with their
"Fixed in `<sha>`" replies), Left over (author-answered open threads, rationale quoted;
pass the loop's `--ignore` phrases so muted threads render there too) — plus a fenced
`SOURCE MATERIAL` block (PR body, resolved-without-SHA threads, unanswered threads). Your
job is exactly two `<FILL>` slots: **Goal** and **Decisions**. Then delete the SOURCE
MATERIAL block, post the result as **one top-level PR comment**, and repeat it to the
user. Metrics are thread-derived — CI-only or review-body-only fixes have no thread;
carry those in prose. **After posting, re-run the oracle once**: feedback that raced the
convergence snapshot must be caught (the oracle deliberately ignores the report comment
itself when deciding whether feedback was answered).

The final shape — keep the `## Review loop summary` heading verbatim, the oracle keys on
it:

```markdown
## Review loop summary

**Goal** — <1–3 sentences from the PR title/body: what this PR set out to do.>

**Journey** — <N> review rounds, <M> findings (<x> P1, <y> P2), <k> fix commits;
converged by <converged_by> at <timestamp>.

**Fixed**
- <finding title> → `<fix sha>`

**Decisions (major drifts from the initial plan)**
- <course change forced during review — design pivot, scope cut/addition, approach
  reversal — anchored to a thread or commit>

**Left over (answered, deliberately left open)**
- <thread topic> — <one-line rationale quoted from the reply; left for a human to close>
- <plus ignored_open topics, findings tracked elsewhere (#issue), pending follow-ups>
```

Rules: **Decisions** lists ONLY major drifts, each anchored to the thread or commit that
forced it; routine fix-what-the-bot-said rounds are not decisions, and "none — landed as
planned" is valid. Every `answered_open` thread MUST appear under **Left over** (each is
a recorded choice awaiting a human), as must every `ignored_open` topic. Every Fixed line
cites the SHA from the actual thread reply. Nothing invented — quote the thread instead
of guessing.

## Common mistakes

| Mistake | Fix |
|---------|-----|
| **Stopping on a stale 👍** — converging at iteration 0 on a thumbs-up from rounds ago | Signals must be newer than HEAD's commit date. The oracle enforces this; never check reactions yourself. |
| **Re-deriving state with your own jq** | Every hand-rolled copy has drifted and produced a different answer on the same PR. One oracle, one answer. |
| Resolving a thread while replying "leaving this open" | Reply text and resolve action must agree: explain/defer replies go reply-only. |
| Treating every unresolved thread as actionable | `answered_open` threads are recorded decisions, not pending work — don't re-litigate them. |
| Counting timeout re-queues or trigger-only rounds toward stops | Only address passes count for no-progress; re-queues are heartbeats. |
| Capping iterations at a fixed N | Healthy PRs run 10–25 rounds; a cap kills big-but-progressing loops. Pathology is stops 2–4's job. |
| Stopping on a 👍 while CI is red or still running | Convergence requires CI finished green and no conflict — the oracle orders this. |
| Running another address pass right after convergence | `converged` stops immediately; the report is the only remaining work. |
| Two wake sources with no lock | One background watcher, one exit, one wake. Never add Monitor/ScheduleWakeup/cron beside it. |
| Prose-mention triggers | Post the bare `@codex review` command only; requests are counted only when a comment opens with it. |
