---
name: address-pr-comments
description: Triage GitHub PR review feedback, fix what's actionable, commit, reply with the fix commit SHA, and resolve threads where possible. Trigger when the user asks to "address PR comments", "fix PR feedback", "respond to review", "check comments on PR and address them", or names a PR with verbs like "address" / "respond" / "reply".
---

# Address PR review comments

Triage a PR's review feedback, fix what's actionable, reply on each thread/review with the fix commit, and resolve threads where possible. Follow the steps in order.

## 0. Ask the state oracle first

`pr-state.sh` (next to this file) is the **single source of truth** for "what should I do
with this PR right now". It paginates every endpoint, normalizes the bot login across
REST/GraphQL, and returns one decision. Don't re-derive any of it by hand.

```bash
STATE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/address-pr-comments/pr-state.sh"
"$STATE" <owner/repo> <n>          # one JSON object; .action is the decision
```

`.action` is one of:

| action | meaning | what you do |
|---|---|---|
| `address` | failing CI, **actionable** threads (reviewer spoke last), unanswered review body, or an unanswered human CHANGES_REQUESTED | steps 2–7 |
| `conflict` | branch conflicts with base | resolve the conflict first |
| `trigger_review` | HEAD needs a review pass and nobody is on it (also fires as a **nudge** when a reviewed HEAD sat quiet 30 min with no 👍) | step 8 |
| `converged` | bot summary "code review completed, no findings" **on HEAD's sha**, or 👍 / human GitHub approval / bot "no major issues" reply **newer than HEAD**; CI finished, nothing open | label the PR (step 9) — then stop |
| `no_reviewer` | ≥2 aged requests on a PR the bot never touched (engagement is per-author/per-install), or ≥3 unanswered requests on the current HEAD (reviewer went dark) | stop; tell the user this PR has no working reviewer |
| `wait` | review in flight / already asked / HEAD too fresh / 👍'd but CI still running | do nothing |
| `closed` | PR merged or closed | stop |
| `error` | see `.error` | report it; do not guess |

Thread arithmetic — the distinction that matters: `unresolved` is every open thread;
`actionable` is the subset where the **reviewer side spoke last** (the bot, or a human who
isn't the PR author/operator); `answered_open` is the rest — threads where the author side
replied last ("leaving this open for a human", a rebuttal, a deferral). Only `actionable`
drives `address`. **Never resolve or re-reply to an `answered_open` thread** — an open
thread with an author-side reply is how deliberate deferrals are recorded.
The other fields (`unanswered_by_bot`, `ci_failing`, `ci_pending`,
`mergeable`, `head_reviewed`, `eyes_active`, `thumbs_fresh`, `thumbs_by`, `converged_by`,
`human_approved`, `human_changes_requested`, `review_body_pending`, `bot_seen`,
`trigger_count`, `triggers_head`, `code_review` — the summary comment's `{status, sha,
findings}`, `null` on PRs that predate it) are the evidence behind the decision — quote them in
your report instead of re-querying.

`--ignore "<substr>"` (repeatable) additionally drops threads whose path or first comment
contains the substring, for muting by topic. Empty/whitespace phrases are rejected (they
would match everything). Since `answered_open` threads are already non-actionable, you
rarely need it.

## 1. Identify the PR

Default to the open PR for the current branch:

```bash
gh pr view --json number,headRefName,baseRefName,url,headRepositoryOwner,headRepository
```

If the user named a PR (`#233` or a URL), use that. The repo owner/name pair from `gh pr view` is canonical even when `origin` points at a mirror.

## 2. Fetch all three sources of feedback

Comments live in three different places. **Always fetch all three** — missing one (especially the review-body channel) is the most common failure mode.

**A. Line-attached review threads** — have `isResolved`, can be replied to and resolved.
`pr-state.sh` already told you *how many* are open; this query gets their *content* so you
can fix them. **It must paginate** — a bare `reviewThreads(first: 100)` silently truncates
past 100 threads and you'd confidently report "all addressed" with real findings open:

```bash
gh api graphql --paginate -f query='
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved path line
          comments(first: 50) {
            nodes { databaseId author { login } body createdAt }
          }
        }
      }
    }
  }
}' -F owner=<owner> -F repo=<repo> -F number=<n> \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved == false)
        | [.id, (.path + ":" + ((.line // 0)|tostring)), .comments.nodes[0].author.login] | @tsv'
```

Notes:
- `gh api graphql --paginate` requires the query to declare `$endCursor` and select `pageInfo { hasNextPage endCursor }` — gh injects the cursor and walks every page. **Do NOT** pass `after: "null"` yourself (the literal string `"null"` is an invalid cursor and errors page 1); omit `-F endCursor=...` and let `--paginate` start from the first page.
- gh's own `--jq` runs per page, so it sidesteps the "control characters must be escaped" error you hit when re-parsing concatenated pages with an external `jq`.
- **Bot logins differ by API**: REST returns `chatgpt-codex-connector[bot]`, GraphQL returns `chatgpt-codex-connector` (no suffix). Never compare the two spellings directly — strip the suffix (`rtrimstr("[bot]")`) on both sides, as `pr-state.sh` does.
- A thread whose **last** comment is the bot (no reply after it) is unaddressed, even on an *earlier* commit. `pr-state.sh` reports this as `unanswered_by_bot`; add `last: comments(last:1){ nodes{ author{login} } }` above if you want it per-thread.
- `comments(first: 50)` truncates a long thread: the reply you're looking for may be comment 51. Use `last: comments(last:1)` for "who spoke last", not the first-50 list.

**B. Free-form review bodies** — entire reviews where the feedback is in the review's `body` itself, not as a line-attached comment. **These do not appear in `reviewThreads`.** Codex sometimes posts this way, especially when its target is a region rather than a single line. Know the shape: every Codex review body carries the same fixed boilerplate ("### 💡 Codex Review … `<details>` footer") regardless of finding count — body *length* means nothing — and a clean pass creates **no review object at all** (a 👍, a "Didn't find any major issues" issue comment on manual trigger, and the summary comment flipping to completed with `has_any_findings: false`). Bodies now open with `<!-- codex-review-receipt:v1 -->`; the oracle strips HTML comments too. Every Codex artifact's exact shape, lifecycle and known pitfalls are in [`codex-artifacts.md`](codex-artifacts.md) — check it first when the bot's output looks unfamiliar, and update it with the oracle when Codex changes format. The oracle strips the template and only sets `review_body_pending` when real prose remains, so trust its flag; when reading bodies yourself, strip the header and footer first:

```bash
gh api repos/<owner>/<repo>/pulls/<n>/reviews \
  --jq '.[] | select(.body != "") | {id, user: .user.login, state, body, submitted_at}'
```

Skip empty bodies and your own past replies.

**C. Issue-level PR comments** — top-level comments on the PR conversation:

```bash
gh api repos/<owner>/<repo>/issues/<n>/comments \
  --jq '.[] | {id, user: .user.login, body, created_at}'
```

Most are bot summaries (Socket, CI, dependency audits) — skip unless they raise an actionable issue. Codex's own `<!-- codex-pull-request-review-summary -->` comment (one per PR, edited in place, a status table plus a `<!-- codex-review-state:v1 {json} -->` line) and its `<!-- codex-review-receipt:v1 -->` replies are status, never feedback: findings still arrive as review threads.

**D. CI / check-run status** — a **failing required check is actionable feedback**, just like a review comment. `pr-state.sh` gives you `ci_failing`/`ci_pending`; fetch the rows when you need to know *which* check:

```bash
gh pr checks <n> --repo <owner/repo> --json bucket,name,state,link
```

**`gh pr checks` lies through its exit code**: `8` when checks are pending, `1` when a check
failed *or* when the PR has no checks at all. Never branch on `$?` — read the JSON. Bare
`gh pr checks <n>` in a `set -e` context aborts your script on a perfectly normal pending run.

Classify by state:
- **`fail` / `failure` / `error`** → **actionable**. Open the failing job's log (`gh run view --job <jobId> --log-failed`), diagnose the real cause (a failing test, a coverage-gate drop like `--cov-fail-under`, a lint/type error, a build break), and fix it in this round like any other feedback. Don't merely re-run.
- **`cancel` / `cancelled`** → **actionable, terminal**. The oracle counts it as failing (a canceled required check is not green). Find out why it was canceled (superseded run? manual cancel? timeout?): if superseded by a newer run, wait for that run; otherwise re-run it (`gh run rerun <runId>`) and treat a second cancellation as a failure to diagnose.
- **`pending` / `queued` / `running` (in_progress)** → acceptable (in progress); not actionable, just note it.
- **`pass` / `skipping` / `neutral`** → fine.

CI must be in a **running or success** state before you consider a round done — never leave a `fail` check unaddressed.

## 3. Triage

Sort every piece of feedback into exactly one bucket. **The bucket decides what step 6 does
with the thread — carry it forward explicitly:**

- **Fix** — the requested change is right (or right enough). Fix it → step 6 replies with
  the SHA **and resolves**.
- **Explain / defer** — the finding is real but deliberately out of scope (design boundary,
  V2 work, tracked elsewhere) or the premise is wrong. Reply with the reasoning → step 6
  replies **and leaves the thread open** for a human to close. An open thread with an
  author-side reply is a recorded decision, not unfinished work; the oracle counts it as
  `answered_open`, not actionable.
- **Informational** — Socket dependency reports, CI status, automated summaries. Skip.
- **Already-addressed** — thread already has a reply from you (or a collaborator) and the
  cited code reflects the fix on the latest commit. Skip; don't re-reply.

Group fixes by review round (often a single Codex review = one round) so you can land one commit per round.

## 4. Apply the fix

- Read the cited file lines first — comments often quote stale line numbers from earlier commits.
- Make the surgical change. Don't expand scope past what the comment asks for.
- If multiple comments share a root cause, fix the cause once and reference all of them in the commit body and replies.
- Verify with the project's checks before committing — `lint`, `check-types`, `build`, etc. as available.

## 5. Commit

One commit per round. Conventional commit format. Reference the PR in the body, not the title (titles stay short). Use the project's co-author footer if it has one. Push — **and verify the push landed before citing the SHA anywhere**:

```bash
git push && [ "$(git rev-parse HEAD)" = "$(gh pr view <n> --repo <owner/repo> --json headRefOid --jq .headRefOid)" ]
```

A rejected push followed by step 6 replies means every reply cites a commit that doesn't exist on the remote, and threads get resolved with no visible fix.

## 6. Reply and resolve

Cite the fix commit's short SHA (7 chars) in every reply. Keep replies one to two sentences — what changed, where.

**Two modes, keyed off the step-3 bucket — resolving is NOT the default:**

- **Fix** → reply with the SHA, then resolve (mutation below, both ops).
- **Explain / defer** → reply only. **Drop the `resolveReviewThread` call entirely** —
  a reply that says "leaving this open" must never be paired with a resolve; the reply
  text and the action have to agree. The reply-only mutation:

```bash
gh api graphql -f query='mutation($t:ID!,$b:String!){
  addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t, body:$b}){comment{id}}
}' -F t="$THREAD_ID" -F b="$BODY"
```

**For fixed line-attached threads** — reply, then resolve. Batch all threads in a single GraphQL mutation with aliases when possible:

```bash
gh api graphql -f query='
mutation {
  reply1: addPullRequestReviewThreadReply(input: {
    pullRequestReviewThreadId: "<threadId>"
    body: "Fixed in <sha>: <one-sentence summary of the change>."
  }) { comment { id } }
  resolve1: resolveReviewThread(input: { threadId: "<threadId>" }) {
    thread { isResolved }
  }
  # ...repeat with reply2/resolve2/... aliases for additional threads
}'
```

**Never interpolate a reply body straight into that single-quoted string.** One apostrophe
in your summary ends the shell quote; a `"` or a newline breaks the GraphQL string. Pass
bodies as variables instead:

```bash
gh api graphql -f query='mutation($t:ID!,$b:String!){
  addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t, body:$b}){comment{id}}
  resolveReviewThread(input:{threadId:$t}){thread{isResolved}}
}' -F t="$THREAD_ID" -F b="$BODY"
```

**Batched aliases fail partially.** If one alias errors (thread already resolved, a fork PR
where you lack write access, a thread on a deleted file), GraphQL returns the successful
data *plus* an `errors` array and `gh` exits non-zero — so a naive retry double-replies on
the threads that already succeeded. Either batch and then parse `.errors[].path` to see
exactly which aliases failed, or do one thread per call and let each failure stand alone.
On a fork PR without write access, `resolveReviewThread` will fail every time: reply and
say the thread is left for a maintainer to resolve.

**For free-form review-body comments** — there's no resolvable thread. Post a top-level PR comment that links the original review URL and the fix commit:

```bash
gh api repos/<owner>/<repo>/issues/<n>/comments \
  -f body="Re: [<reviewer> review on <sha>](https://github.com/<owner>/<repo>/pull/<n>#pullrequestreview-<reviewId>) — *<comment title>*

Fixed in <sha>: <summary>."
```

The review permalink format is `#pullrequestreview-<reviewId>`. The `<reviewId>` is the numeric `id` from `pulls/<n>/reviews`.

## 7. Verify

Re-run the oracle: `"$STATE" <owner/repo> <n>`. The round is done when `.action` is no
longer `address` — i.e. `actionable` is 0, `ci_failing` is 0, and `review_body_pending`
is false.

**"Every thread resolved" is the wrong bar.** Explain/defer replies deliberately leave
threads open — the oracle counts those as `answered_open`, not actionable, so they don't
block the round and need no `--ignore`. Report back to the user:
- What you fixed (commit SHA + comment titles + any CI failure resolved).
- What you answered and left open for a human (`answered_open`), with one-line reasons.
- CI state (running or success).
- What you skipped and why (informational, already-addressed, ambiguous).

## 8. (Re)trigger a Codex review of the pushed fix

Codex auto-reviews on PR-open, in some repos on every push, and often converts a round of
"Fixed in …" replies straight into a 👍 **without any new review** — so an explicit
`@codex review` is a fallback, not the norm, and every redundant one mints a full
re-review that can mint new findings. After you push the fix commit, make sure the
**current HEAD** eventually gets reviewed — but let the oracle decide when asking is
actually needed.

**Do not hand-roll the gates.** Re-run the oracle after pushing and post only on
`trigger_review`:

```bash
"$STATE" <owner/repo> <n> | jq -r .action
```

- `trigger_review` → post exactly once: `gh pr comment <n> --repo <owner/repo> --body '@codex review'`
- anything else → post nothing, and say which action you got.

`trigger_review` already means all of: HEAD is genuinely unreviewed (or reviewed but quiet
past 30 min with no 👍 — the nudge), no live 👀, HEAD is older than the 900s grace window,
and no unanswered request is outstanding.

Two facts the oracle encodes that hand-rolled checks get wrong:

- **`git rev-parse HEAD` is not the PR's head.** It's your local checkout — wrong after a
  failed push, in a different worktree, or when someone else pushed. The oracle uses
  `.head.sha` from the API.
- **The summary comment's `code_review.status: running` means a review is running** — the
  oracle checks it before 👀, TTL'd off the comment's last edit by `--eyes-ttl`. Any other
  status besides `completed` is not interpreted; read `code_review.status` and report it.
- **An active 👀 reliably means a review is running — never trigger over one.** It's
  transient (swapped for the 👍/review on completion), so a 👀 that abnormally outlives
  its review (an errored bot run, a stray human 👀) would block forever; active = newer
  than the last completed review AND younger than `--eyes-ttl` (default 1h).

**Never post the trigger inline right after a push** — HEAD needs to settle, and Codex
often picks it up on its own. Either re-run the oracle at the *start* of the next round,
or block on it (this is also how the loop waits — see `loop-pr-comments`):

```bash
"$STATE" <owner/repo> <n> --wait --timeout 1800   # returns when actionable, or after 30 min
```

## 9. Label a converged PR

Whenever the oracle returns `converged`, mark it on the PR so it's visible without
re-running anything. Idempotent — `--add-label` on a PR that already has it is a no-op,
and the `||true` covers the label already existing:

```bash
gh label create review-converged --repo <owner/repo> \
  --color 0e8a16 --description 'Review loop converged; no open actionable feedback' || true
gh pr edit <n> --repo <owner/repo> --add-label review-converged
```

If the PR later goes back to `address` (new findings, a red check), drop it again —
`gh pr edit <n> --repo <owner/repo> --remove-label review-converged 2>/dev/null || true`
(it errors when the label doesn't exist in the repo) — so the label always
reflects the oracle's current answer rather than a moment in the past.

**Hide outdated `## Review loop summary` comments.** The summary that `loop-pr-comments`
posts is a convergence claim, like the label. Whenever you drop the label, also hide every
visible summary as **Outdated** (`loop-pr-comments` runs the same snippet right before it
posts a new summary, so only the current one stays visible). Rerunning is a no-op;
`viewerCanMinimize` skips comments you can't hide (fork PRs) instead of failing:

```bash
gh api graphql --paginate -f query='
query($owner:String!,$repo:String!,$number:Int!,$endCursor:String){
  repository(owner:$owner,name:$repo){ pullRequest(number:$number){
    comments(first:100, after:$endCursor){
      pageInfo{ hasNextPage endCursor }
      nodes{ id isMinimized viewerCanMinimize body } } } } }' \
  -F owner=<owner> -F repo=<repo> -F number=<n> \
  --jq '.data.repository.pullRequest.comments.nodes[]
        | select(.viewerCanMinimize and (.isMinimized|not)
                 and (.body|startswith("## Review loop summary"))) | .id' |
while read -r id; do
  gh api graphql -F id="$id" -f query='mutation($id:ID!){
    minimizeComment(input:{subjectId:$id, classifier:OUTDATED}){ minimizedComment{ isMinimized } }
  }' >/dev/null
done
```

Hidden comments still come back from REST `issues/<n>/comments` with the same body, so
the oracle's handling of loop comments is unchanged. Only hide summaries: judge, reset and
`## Known limitations` comments are state the oracle and the judge read back.

## Common pitfalls

- **Re-deriving state by hand instead of asking `pr-state.sh`.** Hand-rolled copies drift and answer differently on the same PR. One oracle, one answer.
- **`reviewThreads(first: 100)` silently truncates.** On a long-running PR, unresolved threads pile up past 100 and a non-paginated query drops them — you then report "all addressed" with real P2s open. `--paginate` it; same for `pulls/<n>/reviews`, `issues/<n>/comments`, and `issues/<n>/reactions`. `[…] | last` on a paginated fetch returns the last item **of page 1** — a stale review — so stream with `--jq` and `tail -n1` instead.
- **Assuming you're in the right checkout.** Before committing anything, confirm the branch matches the PR (`gh pr view <n> --json headRefName`) and the tree is clean. After a resume, a compaction, or in a worktree, "the current branch" is not a safe assumption — you can land a fix on the wrong branch and report success.
- **Free-form review comments don't appear in `reviewThreads`.** If you only check threads, you'll miss them and confidently report "no new comments." Always fetch `pulls/<n>/reviews` too.
- **Codex review boilerplate.** Strip the `### 💡 Codex Review` header and the `<details>About Codex in GitHub</details>` footer when extracting the actual feedback.
- **Stale line numbers.** Comment line numbers reference the commit they were left on. After more commits, re-read the current file before editing.
- **Don't auto-resolve someone else's open question — or your own deferral.** If the comment asks for clarification, has a 👎 from a human reviewer, or your reply is an explain/defer ("leaving this open", "out of scope", a rebuttal), reply but leave the thread open — the reply text and the resolve action must never contradict.
- **Don't `git revert` to undo your own work-in-progress commits.** Make a new commit. Reverts pollute the PR's history.
- **Resolve only after replying.** If you resolve first, the reply still posts but the thread re-opens in some UIs. Reply, then resolve, in that order (one mutation does both).
