---
name: loop-pr-comments
description: Repeatedly run address-pr-comments on a PR until the review bot (Codex) or a human gives it a 👍 thumbs-up reaction, then stop. Every 5 review rounds a separate judge agent reads the review train's content and rules CONTINUE, ISSUE (move a concern to an issue and keep looping), SPLIT, or STOP (waive); Codex/devbox blockers get a red review-blocked label. Self-paces between iterations and only touches NEW actionable feedback each round. Trigger when the user asks to "keep addressing PR comments until approved", "loop address-pr-comments", "babysit PR review until thumbs-up", "auto-address review feedback until the author approves", or names a PR with a convergence/until condition.
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
2. **Ask the oracle:** `"$STATE" <owner/repo> <n> --ignore …`. Check these gates in order,
   before branching on `.action`:
   1. **`waived: true`** (the label, or a posted STOP verdict): never post a trigger. If the
      waive is incomplete, finish what's missing, then stop. Check each step's result on the
      PR rather than redoing it:
      - the `## Known limitations (review waived)` comment (create it, or update it with
        threads that arrived since);
      - the label;
      - the report.
      A dirty tree here is an interrupted waive fix. Don't guess: stop and tell the user (step
      1b still applies). Resume only when the user
      explicitly asks: remove `review-waived` first, then post a `Review train reset`.
   2. **`converged` / `closed`**: stop. Convergence outranks a due judge, because there is
      nothing left to judge.
   3. **`judge_due: true`**: run the judge now (see Review-train judge) and act on its
      verdict before any address pass, trigger or watcher.

   Then branch on `.action`:
   - `no_reviewer` / `error` → **stop** (see Stopping).
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
   > deliberately-left-open topics: `<leave-open phrases>`. A finding on a concern already
   > moved to an issue (see the `issue #<k>` judge comments) gets the reply `Tracked in
   > #<k>` and nothing else. Skip your step 8: don't post `@codex review`; the loop owns the
   > trigger."
6. **Never touch leave-open threads** — pass the phrases as `--ignore` to the oracle
   *and* restate them in the sub-skill prompt. Two guards; prose alone is unverifiable.
7. **After an address pass, go back to step 2.** The fresh snapshot decides the trigger,
   and the judge gate runs again first.
8. **Nothing actionable this round is fine** — the loop is waiting for a converging
   signal. Launch the watcher and end the turn; do not invent work.

## Review-train judge (every 5 rounds)

A **review train** is the run of Codex rounds since the train started: the PR's first
review, or the latest `Review train reset` comment. A **round** is one bot review object
(reviews < 5 min apart count as one) or one "didn't find any major issues" reply; a 👍
alone is not a round. The oracle counts them. Don't count them yourself:

- `train_start`: the latest reset (`null` means the PR's first review).
- `train_rounds`: the rounds in this train.
- `last_judged_round`: the newest `Review train judge — round N` comment in this train.
- `judge_due`: `train_rounds` has crossed a multiple of 5 that hasn't been judged yet.

Every judge run is recorded on the PR as a one-line top-level comment,
`> **Review train judge — round <train_rounds>: <VERDICT>** — <W> findings, <P> P1 in window; <reason>`
(for `ISSUE`, append `; issue #<k>: <concern>`). That
comment is the checkpoint: it survives compaction and new sessions, and the oracle never
reads it as an answer to feedback. Start the body with `> **` exactly: the oracle keys on
that prefix (and on `## ` from older PRs), never on a plain quote.

**Reset on a new feature request.** When the user asks for new scope on this PR (a feature,
not a fix of a finding), post a one-line `> **Review train reset** — <what the user asked for>`
top-level comment before implementing it. The count restarts from that comment, and the
oracle never reads it as an answer to feedback.

**Spawn the judge** as a separate read-only agent (`subagent_type: "general-purpose"`). Not
a critic: critics are tuned to reject, and this judge leans toward CONTINUE. Wait for its
result before doing anything else; never judge your own train in the loop's context. Give it
the PR, `train_start`, `train_rounds`, and this rubric verbatim. It reads the **content** of
every finding in the train (inline comments, review bodies, the replies and fix commits),
not just counts. Its output contract: the first line is exactly `CONTINUE`, `ISSUE`, `SPLIT`
or `STOP`, followed by the evidence for it. For `ISSUE` it also lists the threads to move and
a one-line issue title.

**Window features.** The judge starts by running the feature script for the latest
checkpoint:

```bash
python3 -I "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/loop-pr-comments/judge-features.py" <owner/repo> <n> <train_start>
```

It prints `window_findings`, `window_p1`, `md_share` (the share of window findings on `.md`
files, unrounded; `md_findings` is the count), `file_spread` and `top_files` for the 5
rounds just finished. Its `checkpoint` must equal the oracle's `train_rounds` rounded down
to a multiple of 5; if not, re-run both before judging. Pass `train_start`
from the oracle; `null` means the PR's first review.

The judge's rubric comes from 3 months of history: 1,173 PRs, 383 with 3+ rounds, and
11,439 findings. In every state measured, ≥ 57% of PRs eventually converged. So
**CONTINUE is the default and needs no justification; SPLIT and STOP need evidence.**
Rates below are "converged by the next checkpoint / converged at all".

**What the content does and doesn't tell you.** Findings were grouped by file, by 80-line
block, by markdown section, and by concern. Once counts are controlled for, none of the
area patterns predicted the outcome:
- staying on one file or section,
- moving on to new areas (the "8 rounds on one section, then 7 on another" pattern
  appeared in 8 PRs, and all 8 converged),
- coming back to an area that had gone quiet,
- the same concern reworded,
- a concern re-raised after the author declined it.

Converged and unconverged long trains look alike. core#120 (55 rounds, converged) and
handoff#112 (42 rounds, never converged) both found a new edge case in one file every
round. So **never STOP or SPLIT because of the shape of the area timeline.** The judge
reads the content for four other reasons:
- to check that the counts are real (not duplicates, generated files, or one finding
  posted twice),
- to name the separable slice when SPLIT is on the table,
- to write the one-line "why accepted" for each thread if the verdict is STOP,
- to spot thread-level ping-pong, which is stop 3, not the judge's call.

**Rules (first match wins):**

1. **ISSUE (judgment, any checkpoint): move a concern out, keep looping.** The window's
   findings cluster on a concern that this PR doesn't need to close. Examples: a
   pre-existing problem the diff didn't introduce, hardening beyond the PR's stated goal,
   or a design question that needs its own discussion. Moving it out must leave the PR correct for its goal. Prefer
   ISSUE over SPLIT when the slice is follow-up work, not code already in the PR. Prefer it
   over STOP (rules 3, 4 and 6) when that concern is what keeps the window large.
   Never move a P1 the diff itself introduced. List only actionable threads, never ones
   already `answered_open`.
2. **Round 5 → CONTINUE.** Even the worst round-5 bucket converges 84% of the time. Note an
   md-heavy window (rule 3) in the reason, but continue.
3. **STOP: markdown-heavy train.** Round ≥ 10, ≥ 13 findings in the window, and
   `md_share` ≥ 0.5 (0.17 / 0.61, against 0.21 / 0.84 otherwise). This is the only content
   signal that held, and it also holds outside hi4labs/core. Codex keeps finding new gaps
   in prose specs. Caveat: most of the md-heavy PRs that never converged were merged
   without a 👍, so the rule partly records how doc PRs already get handled.
4. **STOP: heavy and late.** Round ≥ 20, with ≥ 13 findings and ≥ 5 P1 in the window
   (0.05 / 0.63).
5. **SPLIT (judgment; no PR in the history was split partway through review).** Round 10–15,
   a code PR, ≥ 13 findings and ≥ 5 P1 in the window, and the PR has > 30 files or has
   grown ≥ 3× since round 1. You must also name a slice that can ship on its own, so the
   rest stops collecting findings. With no nameable slice, fall through.
6. **STOP: not shrinking.** Round ≥ 15, and the window held ≥ 13 findings with no decrease
   at this checkpoint and at the previous one (the previous judge comment's reason records
   that window's count). At round 20 a non-decreasing window converges 0.62 eventually,
   against 0.90.
7. **Otherwise CONTINUE.** That includes any round count: trains converged after up to
   77 rounds. ≤ 12 findings and ≤ 4 P1 in the window is a strong CONTINUE (0.7–0.8 / 0.93).

Tiebreaker for a borderline rule 4 or 6, only at round ≥ 15: if ≥ 70% of the window's
findings are in files a fix commit touched one round earlier, lean STOP (0.08 / 0.64
against 0.25 / 0.93; small sample). STOP means "the next 5 rounds are unlikely to finish
this", not "this will never converge".

Every judge comment's reason includes `window_findings` and `window_p1`, so rule 6 can read
the previous checkpoint from the PR record.

**Acting on the verdict:**
Post the `Review train judge — round N: …` comment before acting on the verdict, with
one exception: for `ISSUE`, create the issue first, so the comment can carry its number.
Posting a `STOP` comment makes the oracle report `waived: true` at once, so a crash halfway
through the waive can't resume reviewing. Step 2's waive gate finishes the remaining steps.
- `CONTINUE` → relaunch the watcher.
- `ISSUE` → open one issue in the PR's repo:
  - title: the judge's title;
  - body: starts with `Follow-up from #<n> (review train round <R>)`, then each moved thread
    as a link with its severity and the finding in one line.

  That first line identifies the checkpoint, so search for it first: a crash after the
  create but before the judge comment must not open a second issue.

  ```bash
  gh issue list --repo <owner/repo> --state all --search '"Follow-up from #<n> (review train round <R>)" in:body' --json number
  gh issue create --repo <owner/repo> --title "<title>" --body-file <file>   # only if none found
  ```
  Then reply on each moved thread with `Tracked in #<issue> — out of scope for this PR.`
  Reply only: don't resolve. The thread becomes `answered_open`, so the oracle stops
  counting it. A reply lost to a crash heals itself: the thread stays actionable, and the
  next address pass answers it with the issue link (step 5's prompt). Later findings on the same concern get the same reply, not a new issue. List
  the issue under **Left over** in the convergence report. Then relaunch the watcher.
- `SPLIT` → TaskStop the watcher and report the proposed split to the user: which areas or
  commits move out, and what stays. Wait for their decision. Never split, force-push, or
  open PRs on your own.
- `STOP` → waive the review (below).

## Waiving the review (judge says STOP)

1. **Stop the loop:** TaskStop the `pr-state.sh` watcher and never post `@codex review`
   again on this PR.
2. **Land any fix in progress:** run the project's checks locally, then commit (signed) and
   push. A fix that can't pass them is never pushed: stash it and say so in the report.
   Then let CI and any automatic Codex review of that push settle. Never post a trigger.
   Run this in the background (`run_in_background: true`; it waits up to 40 min, the
   observed bot latency):
   ```bash
   timeout 2400 gh pr checks <n> --repo <owner/repo> --watch >/dev/null 2>&1
   for _ in $(seq 16); do
     "$STATE" <owner/repo> <n> | jq -e '.head_reviewed and (.eyes_active|not)' >/dev/null && break
     sleep 150
   done
   ```
   If it doesn't settle, post anyway. Note `review of <sha> pending` in the comment and the
   report. The waive gate (step 2) adds any later threads to the comment the next time the
   loop runs on this PR.
3. **Post one top-level PR comment** after the push, titled
   `## Known limitations (review waived)`: each unresolved thread as a link, its severity
   (the P1/P2 badge in the thread's first comment), and one line on why it is accepted. Put
   the judge's verdict in one sentence above the list. Take the threads from
   `pr-report.sh <owner/repo> <n> --unresolved [--ignore …]`: one JSON line per unresolved
   thread with `url`, `sev`, `t`, `state` and the last `reply`. Don't write a new query.
4. **Label it.** `--remove-label` fails the whole command when the label doesn't exist in
   the repo, so removes go in their own call:
   ```bash
   gh label create review-waived --repo <owner/repo> --color fbca04 \
     --description 'Codex review loop waived; see Known limitations comment' || true
   gh pr edit <n> --repo <owner/repo> --add-label review-waived
   for l in review-converged review-blocked; do
     gh pr edit <n> --repo <owner/repo> --remove-label "$l" 2>/dev/null || true
   done
   ```
5. **Report to the user:** the final head SHA, the CI state, and every unresolved **P1**
   they need to decide on before merging. **Never resolve threads or merge on your own.**

## Blocked: `review-blocked`

A loop that can't continue for reasons outside the code is **blocked**, not stopped. Mark it
on the PR in red so it reads differently from a waive or a convergence:

```bash
gh label create review-blocked --repo <owner/repo> --color d73a4a --force \
  --description 'Review loop blocked by Codex or devbox problems'   # --force keeps it red
gh pr edit <n> --repo <owner/repo> --add-label review-blocked
```

Remove it as soon as the loop moves again. A PR that converges or is waived must not keep
it. Use its own call, because `--remove-label` errors when the label doesn't exist in the
repo:
`gh pr edit <n> --repo <owner/repo> --remove-label review-blocked 2>/dev/null || true`.

| Category | Signature (literal, seen in past loops) | Response |
|---|---|---|
| Codex | bot reply `You have reached your Codex usage limits for code reviews` (the oracle's usage-limit `wait`) | Label and keep the watcher. The oracle re-asks after `--limit-ttl`; unlabel when a review lands. |
| Codex | `no_reviewer`, or the same `wait` reason surviving ~4 h of re-queues | Label, stop, report. |
| devbox, signing | `agent refused operation?`, `communication with agent failed?`, `Couldn't get agent socket?`, `fatal: failed to write commit object` | Retry once through `find-git-sign-socket`. If it still fails, label, stop, report. Never commit unsigned. |
| devbox, push | `Permission denied (publickey).`, `Load key "…": error in libcrypto`, `failed to push some refs`, `[remote rejected]` | Label, stop, report. |
| devbox, CI | `The job was not started because recent account payments have failed or your spending limit needs to be increased` | Label, stop, report (the user fixes billing and reruns). |
| devbox, GitHub API | oracle `error` with `API rate limit` / `RATE_LIMIT` | Wait for the reset and retry once. If it persists, label, stop, report. |
| agent | `API Error: 400 You have reached your specified workspace API usage limits` | Can't act. If the label can still be posted, post it. |

Security-review usage-limit replies (`…usage limits for security reviews`, `…has reached its
Codex usage limits`) do **not** block: code review still runs and PRs converge with them
present. List them under Left over instead.

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
`review-converged` label (address-pr-comments step 9), remove `review-blocked` and
`review-waived` (one `--remove-label … 2>/dev/null || true` call each), then produce the **convergence
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
Ping-pong on one specific thread outranks the judge: ask the user, don't waive. A concern
moved to an issue doesn't count, whether it comes back reopened or as a new thread: reply
with the issue link. The judge
never overrides a ruling the user already gave.

**4. `error` / `closed` / `no_reviewer`** — report and stop; never improvise a fallback
query. `no_reviewer` means the bot never engaged (2 dead requests) or went dark mid-loop
(3 unanswered on this HEAD) — looping cannot summon a reviewer. `no_reviewer` and
persistent errors are **blocked**: apply `review-blocked` (above).

**5. Judge verdict** — `STOP` waives the review; `SPLIT` pauses for the user (above).
`CONTINUE` and `ISSUE` are not stops: the loop goes on.

**6. Blocked** — a Codex or devbox blocker from the table above: label `review-blocked`
and report. Never call it a stop: the user needs to know they can unblock it.

**There is deliberately NO iteration cap.** Healthy PRs routinely converge after 10–25
review rounds (p90 12, max 77). A cap punishes size, not pathology. Stops 2–3 and the
judge detect pathology, and the judge decides from content, not count.

In every case (except a Codex usage-limit block, which keeps its watcher): TaskStop the
watcher and say which stop fired — "no progress: two rounds
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
| Capping iterations at a fixed N | Healthy PRs run 10–25 rounds; a cap kills big-but-progressing loops. Pathology is the job of stops 2–3 and the judge. |
| Counting train rounds or checkpoints yourself | Use the oracle's `train_rounds` / `judge_due`; the PR's judge comments are the checkpoint record. |
| Re-looping a waived PR in a new session | `waived: true` stops the loop unless the user explicitly asks to resume. |
| Splitting or waiving over a concern the PR doesn't need to close | `ISSUE` moves it to a tracked issue and keeps the loop going. It is cheaper than a split and keeps the review. |
| Stopping because the train stays in one area, or moves between areas | Measured: area shape didn't predict the outcome once counts were controlled for. Only the counts, P1s and markdown share decide; content explains the verdict and names a split. |
| Judging your own train in the loop's context | Spawn the separate judge agent every 5 rounds; the loop's own context is biased toward whatever it just fixed. |
| Not resetting the count on a user feature request | Post `> **Review train reset** — …` before building new scope, so new-feature rounds don't count against the old train. |
| Calling a blocked loop "stopped" | Codex quota, signing, push and billing failures get the red `review-blocked` label, not a waive. |
| Resolving threads or merging after a waive | The waive only documents what's left; the user decides on every unresolved P1 and merges. |
| Stopping on a 👍 while CI is red or still running | Convergence requires CI finished green and no conflict — the oracle orders this. |
| Running another address pass right after convergence | `converged` stops immediately; the report is the only remaining work. |
| Two wake sources with no lock | One background watcher, one exit, one wake. Never add Monitor/ScheduleWakeup/cron beside it. |
| Prose-mention triggers | Post the bare `@codex review` command only; requests are counted only when a comment opens with it. |
