---
name: loop-pr-comments
description: Use when the user wants a PR's review feedback addressed repeatedly until the reviewer (Codex or a human) approves — "keep addressing PR comments until approved", "loop address-pr-comments", "babysit PR review until thumbs-up", or a PR named with an until/convergence condition.
---

# Loop address-pr-comments until converged

Run address-pr-comments rounds on one PR until the oracle says it converged, then post a
convergence report. One background watcher wakes you; every 5 review rounds a separate
judge agent rules on whether to go on.

With `D="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"`: `$OPS` means
`bash "$D/address-pr-comments/pr-ops.sh"` (`--help` lists every command) and `$WATCH` means
`bash "$D/address-pr-comments/pr-state.sh"` (the oracle; `--wait` makes it the watcher).
Any gh command you run yourself goes through `"$D/address-pr-comments/bin/gh"`, so the
call log stays complete (address-pr-comments, Call log).
Shell variables don't survive between Bash calls: write them out (or set them) in each call.

**Never decide state yourself.** Reactions never expire, so "is there a 👍?" stays true
forever after the first one. Only the oracle's rules (a signal newer than HEAD, CI done,
nothing open) are trustworthy, and `sync` applies them. No queries of your own.

## Arguments

`loop-pr-comments [<pr|url>] [--leave-open "<phrase>, …"] [--interval <s>]`

- `--leave-open`: split on commas, trim, drop empty pieces. Pass each as
  `--ignore "<phrase>"` to every `sync`, `feedback`, `post-summary`, `pr-report.sh` and
  watcher call, and restate them in each round's constraints. Echo `ignored_open` back on
  the first iteration: a too-broad phrase silently mutes real findings.
- `--interval`: the watcher's base poll seconds (default 5).

There is no iteration cap. Healthy PRs take 10–25 rounds (max seen 77); the stops and the
judge catch pathology.

## Each iteration

1. `$OPS resolve <pr-url>` (a PR number or nothing only the first time). `checkout_ok`
   false → stop and tell the user. Recheck after every wake or compaction.
2. `$OPS sync <repo> <n> --loop [--ignore …]` and branch on `.next`:

   | `.next` | do |
   |---|---|
   | `waive` | review waived (label or a STOP verdict): run Waiving steps 2–4 — the comment updates in place, so late threads get added — then stop. A dirty tree here is an interrupted fix: stop and ask. Resume only if the user asks: remove `review-waived`, then `$OPS reset`. |
   | `report` | converged → Stopping 1. Convergence outranks a due judge: nothing is left to judge. |
   | `judge` | run the judge (below) before anything else |
   | `address`, `conflict` | one address round (step 3), then back to step 2 |
   | `wait` | `sync` already posted any due `@codex review` (`trigger:failed` in `.did` → sync again). Launch the watcher, end the turn. |
   | `rate_limited` | launch the watcher and end the turn: it waits out the limit, polling slower as the budget drains |
   | `blocked`, `error`, `stop` | Stopping 4 |

3. **Address round.** If address-pr-comments' steps aren't in your context (first round,
   or after compaction), invoke it with the Skill tool; otherwise follow them directly.
   This round's constraints: skip its steps 1–2 and 8 (loop step 2 does them) and run
   every `sync` with `--loop`; only NEW actionable feedback, including failing CI; never
   reply to or resolve threads matching the leave-open phrases; a finding on a concern
   already moved to an issue (judge comments name `issue #<k>`) gets the reply
   `Tracked in #<k>` and nothing else. Record `{head, actionable, round, findings
   answered}` in your notes — Stopping 2 compares across rounds and must survive
   compaction.

Nothing actionable is fine: launch the watcher and end the turn. Don't invent work.

## Waiting

```bash
$WATCH <repo> <n> --wait --timeout 1800 [--interval N] [--ignore …]   # run_in_background: true
```

It exits when there's something to do or the state moved, and its stdout is the oracle
JSON. Polls are cached conditional reads, free while the PR is quiet; a change re-reads only what moved (plus a full snapshot every 5 min); its interval stretches
as the shared GitHub budget drains, and it waits out rate limits instead of failing. On a `timeout` (exit 10), `killed` (exit 143) or `wait`
wake, go to step 2; still `wait` → relaunch. These re-queues are not iterations. One
watcher at a time (check your background tasks first); never add Monitor, ScheduleWakeup
or cron beside it. The same `wait` reason for ~4 h means something external is wrong:
report it.

## Review-train judge (every 5 rounds)

Spawn a separate read-only `general-purpose` agent (not a critic) and wait for it. Never
judge in the loop's own context. Prompt: the repo and PR, `train_start` and `train_rounds`
from the sync JSON, and "Read `<D>/loop-pr-comments/judge-rubric.md` and follow it" with
`<D>` written out as an absolute path. Line 1 of its answer is the verdict. If line 2 says
`checkpoint mismatch`, post nothing: sync again and re-spawn the judge; a second mismatch
in a row goes to the user instead.

The judge comment is the checkpoint the oracle reads back, so post it only through
`$OPS judge`, with `<train_rounds>` as the round — it writes the exact format the oracle
parses:

- **CONTINUE**: `$OPS judge <repo> <n> <train_rounds> CONTINUE <window_findings> <window_p1> "<reason>"`,
  then back to step 2 (the next sync posts the trigger it held for the judge).
- **ISSUE**: first `$OPS issue <repo> <n> <train_rounds> "<title>" <body-file> <thread-id>…`.
  The body file lists each moved thread as its `url` (from `feedback`), severity and the
  finding in one line; the command prepends the `Follow-up from #<n>` line, reuses an
  issue it already opened for this round, and replies `Tracked in #k` on each thread
  without resolving. `failed_threads` → re-run `issue` with just those IDs (it finds the
  same issue). Then `$OPS judge … ISSUE … "<reason>" <k> "<concern>"`, and back to step 2.
- **SPLIT**: post the judge comment, TaskStop the watcher, and report the proposed split
  (what moves out, what stays). Wait for the user; never split, force-push or open PRs
  yourself.
- **STOP**: post the judge comment (the oracle reports `waived` from then on), then waive.

**New scope resets the train.** When the user asks for a new feature on this PR (not a fix
of a finding), run `$OPS reset <repo> <n> "<what they asked for>"` before building it.

## Waiving

1. TaskStop the watcher. Never post `@codex review` on this PR again.
2. Land any fix in progress: checks pass → signed commit → `$OPS push`. A fix that can't
   pass is stashed and named in the report. Then run `$OPS settle <repo> <n>` in the
   background (CI plus a review of HEAD, ≤ ~80 min) and wait for its result.
3. `bash "$D/loop-pr-comments/pr-report.sh" <repo> <n> --unresolved [--ignore …]` gives one
   JSON line per unresolved thread. Write `## Known limitations (review waived)`, the
   verdict in one sentence (plus `review of <sha> pending` if `settled` was false), then
   each thread as a link, its severity, and one line on why it's accepted.
   `$OPS waive <repo> <n> <file>` creates or updates that comment and sets the labels.
4. Report the head SHA, CI state, and every unresolved P1 the user must decide on. Never
   resolve threads or merge.

## Blocked

Blocked is not stopped: the cause is outside the code. `$OPS block <repo> <n>` adds the
red `review-blocked` label; `$OPS unblock` removes it as soon as the loop moves again.

| Signature | Response |
|---|---|
| bot reply `You have reached your Codex usage limits for code reviews` (an oracle `wait`) | block, keep the watcher; unblock when a review lands |
| `.next` `blocked` (no_reviewer), or one `wait` reason for ~4 h | block, stop, report |
| `agent refused operation?`, `communication with agent failed?`, `Couldn't get agent socket?`, `failed to write commit object` | retry once through `find-git-sign-socket`, then block and stop. Never commit unsigned. |
| `Permission denied (publickey).`, `error in libcrypto`, `failed to push some refs`, `[remote rejected]` | block, stop, report |
| CI: `recent account payments have failed or your spending limit needs to be increased` | block, stop, report (the user fixes billing) |
| `rate_limited` that outlives its reset time | block, stop, report |
| `API Error: 400 … workspace API usage limits` | can't act; block if you still can |

Security-review limit replies (`…usage limits for security reviews`, `…has reached its
Codex usage limits`) don't block; list them under Left over.

## Stopping

1. **Converged.** TaskStop the watcher, write the report (below) to a scratchpad file, and
   `$OPS post-summary <repo> <n> <file> [--ignore …]`. It hides older summaries, posts,
   and re-syncs. `.sync.next` still `report` → done. Otherwise handle `.sync` like step 2
   (on `address`/`conflict` it has already withdrawn the label and summary).
2. **No progress.** Two consecutive address rounds with the same `actionable` on the same
   HEAD. Re-queues and trigger-only rounds don't count.
3. **Ping-pong.** A thread you answered is reopened, or a fixed finding comes back → ask
   the user. This outranks the judge. A concern moved to an issue doesn't count: reply
   with the issue link. The judge never overrides a ruling the user already gave.
4. **Blocked, error or closed.** Report; block on `blocked` and on persistent errors.
   Never improvise a fallback query.
5. **Judge.** STOP waives; SPLIT pauses for the user.

Every stop except a usage-limit block: TaskStop the watcher and name the stop and its
evidence ("no progress: two rounds at 3 actionable on abc1234").

## Convergence report

`bash "$D/loop-pr-comments/pr-report.sh" <repo> <n> [--ignore …]` prints the
`## Review loop summary` with Journey, Fixed and Left over filled from the PR record, plus
a SOURCE MATERIAL block. Fill its two `<FILL>` slots, delete the block, post it
(Stopping 1), and repeat it to the user.

- **Goal**: 1–3 sentences from the PR title and body.
- **Decisions**: only major drifts (design pivot, scope cut or addition, approach
  reversal), each anchored to the thread or commit that forced it. Routine fixes aren't
  decisions; "none — landed as planned" is valid.
- The counts are thread-derived: describe CI-only and review-body-only fixes in prose
  after the Journey line. **Left over** also takes issues opened by the judge, pending
  follow-ups, and security-review limit replies.

Quote the threads; never invent.
