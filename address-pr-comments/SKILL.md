---
name: address-pr-comments
description: Use when the user asks to address, fix, respond to, or reply to GitHub PR review feedback or a failing PR check — "address PR comments", "fix PR feedback", "respond to review", "check comments on PR #233 and address them".
---

# Address PR review comments

One round: fix what's actionable on a PR, reply on every item with the fix commit, resolve
what was fixed. `pr-ops.sh` does every mechanical step and reads state through the oracle
`pr-state.sh`; you triage, fix and write the replies. Never hand-roll gh/GraphQL queries
for this — every hand-rolled copy has drifted from the oracle.

`$OPS` below means `bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/address-pr-comments/pr-ops.sh"`.
`$GH` means `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/address-pr-comments/bin/gh"`: gh
itself, with the call logged (see Call log). Use it for any gh command you run yourself.
Shell variables don't survive between Bash calls: write it out (or set it) in each call.
`$OPS --help` lists every command.

## The round

1. **Where.** `$OPS resolve [<pr-url>]` → `repo`, `pr`, `url`, `head_ref`, `base_ref`,
   `checkout_ok`. Pass the URL once you have it (it resolves over REST). If `checkout_ok`
   is false (wrong branch or dirty tree), stop and tell the user before changing anything.
2. **Whether.** `$OPS sync <repo> <n>` and branch on `.next`:

   | `.next` | do |
   |---|---|
   | `address` | steps 3–8 |
   | `conflict` | resolve the conflict (below), then sync again |
   | `wait` | stop and report `.reason`: a review is in flight, requested, or HEAD is too fresh. If one was due, sync posted `@codex review` (`.did` has `trigger`; `trigger:failed` → sync again). |
   | `report` | converged; sync labelled it `review-converged`. Stop. |
   | `rate_limited` | stop and report the reset time in `.error` |
   | `waive` / `blocked` / `stop` / `error` | stop and report: review waived / no working reviewer / PR closed / `.error` |

3. **Read.** `$OPS feedback <repo> <n>` → `threads` (only actionable ones: the reviewer
   side spoke last; each with `id`, `root`, `url`, `thumbs_down`), `review_bodies`,
   `comments` (humans, unanswered), `failing_checks` (with `log_tail`).
4. **Triage** every item into one bucket — the bucket decides the reply:
   - **Fix**: the request is right, or right enough → `Fixed in <sha>: …`, resolved.
   - **Explain / defer**: real but out of scope, or the premise is wrong; or the thread asks
     you a question, or has `thumbs_down` from a human → reply with the reason, leave it
     open. An open thread whose last word is the author side is a recorded decision
     (`answered_open`), not pending work: never re-reply to or resolve one.
   - **Skip**: informational bot output, or already answered.

   A failing or canceled check is a Fix item: find the cause in `log_tail` and fix it, don't
   just re-run. Canceled because a newer run superseded it → wait for that run; otherwise
   `$GH run rerun <runId>`, and a second cancel is a failure to diagnose.
5. **Fix.** Read the cited code at HEAD (comment line numbers are from older commits). Make
   the surgical change — nothing beyond what was asked. A shared root cause gets one fix,
   and the commit body and every reply name all the threads it closes. Run the project's
   checks (lint, types, tests, build).
6. **Commit and push.** One conventional commit per round, PR referenced in the body, the
   project's co-author footer if it has one. Then `$OPS push <repo> <n>` → `sha`. It fails
   when the PR head isn't your commit; fix that before any reply cites the SHA.
7. **Reply.** One JSON line per item into a scratchpad file, then
   `$OPS reply <repo> <n> < file`:
   ```
   {"thread":"PRRT_…","root":123,"body":"Fixed in abc1234: <what changed, where>.","resolve":true}
   {"thread":"PRRT_…","root":124,"body":"<why this stays open>."}
   {"review":123456,"body":"Fixed in abc1234: <what changed>."}
   ```
   One or two sentences each; copy `id` and `root` from `feedback`. `resolve` is refused
   unless the body cites `Fixed in <sha>` for a commit on the PR head. Each result line has
   `replied` and `resolved`: re-send only items with `replied: false`; for
   `replied: true, resolved: false`, send `{"thread":"PRRT_…","resolve":true}` (resolve
   only). On a fork PR without write access, resolving fails: say a maintainer has to
   resolve.
8. **Close.** `$OPS sync <repo> <n>` again; the round is done when `.next` isn't `address`.
   Never post `@codex review` yourself — `sync` posts it exactly when the oracle says
   `trigger_review`. Report: what you fixed (SHA, titles, CI failures), what you answered
   and left open (one-line reasons), CI state, what you skipped and why.

## Conflicts

```bash
git fetch origin <base_ref> && git merge origin/<base_ref>   # never rebase or force-push a shared PR branch
# resolve keeping BOTH sides' intent, run the checks, then:
git add -A && git commit --no-edit && $OPS push <repo> <n>
```

Escalate semantic or non-obvious conflicts to the user; never discard the other side
wholesale. `mergeable: UNKNOWN` means GitHub is still computing: sync once more first.

## Rate limits

The scripts back off on their own and prefer REST where it is exact. When GraphQL is
exhausted, thread reads fall back to REST (`sources.threads: "rest"`); there, a thread
with `id: null` wasn't seen before, so it may already be resolved — reply with
`{"root":N,"body":…}` and never resolve it. A foreground command that would have to wait
more than ~90 s fails instead and names the reset time.

The oracle's REST reads are conditional GETs over `${XDG_CACHE_HOME:-~/.cache}/pr-review/http`:
what hasn't changed since any earlier read, in any process, comes back as a free 304. The
watcher probes the same URLs, so a quiet PR costs nothing, and when something moves it
re-reads only that: threads only if review comments moved, CI only if checks or HEAD did.
Resolve/unresolve clicks are invisible to REST and show at the 5-minute full snapshot.

## Call log

Every GitHub request these scripts (and `$GH`) make lands in SQLite at
`${XDG_STATE_HOME:-~/.local/state}/pr-review/gh-calls.sqlite` (`PR_REVIEW_LOG_DB` overrides,
`PR_REVIEW_LOG=0` disables): rate limit remaining, expected and actual cost, whether it was
a free 304, the calling script and function, and the query text with its variables as rows.
Mutations keep only method, path and operation name. Query the `calls` view; the columns
are explained in `gh-log.sql`. Logging failures go to `<db>.errors` and never fail the call.

## Notes

- `sync` adds `review-converged` on convergence. On a regression (`address`, `conflict`,
  or an unreviewed new HEAD) it hides every `## Review loop summary` comment as Outdated,
  then drops the label; if hiding fails, the label stays so the next sync retries.
- `--ignore "<phrase>"` on `sync` and `feedback` mutes threads whose path or first comment
  contains it. Rarely needed: answered threads are already non-actionable.
- Bot output that looks unfamiliar (summary comment, receipts, limit replies): read
  `codex-artifacts.md` beside this file before guessing.
- Don't `git revert` your own work in progress; make a new commit.
