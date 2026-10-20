# Codex GitHub review artifacts

What `chatgpt-codex-connector[bot]` leaves on a PR, as observed. This is the reference
`pr-state.sh` is built against; when Codex changes shape, update this file and the oracle
together. Last verified 2026-10-20 (outta-ai/website#237, #240; a throwaway probe PR).

## The summary comment (since ~2026-10-15)

One top-level issue comment per PR, created when the first review starts and **edited in
place** afterwards. Use `updated_at`; `created_at` is the first review's start.

```
<!-- codex-pull-request-review-summary -->
<!-- codex-review-state:v1 {"code_review":{...},"security_review":{...}} -->
<!-- codex-security-review:v1 {"blockingSeverityThreshold":"P0","headSha":"…","mergeGateEnabled":false,"pullRequestNumber":N,"repository":"o/r","status":"…"} -->
## Codex Review Summary
| Review | Status | Commit | Review trigger |
| 📝 **Code Review** | 🔄 **Running** since <relative-time …> | `abc1234` | PR opened |
| 🔒 **Security Review** | ✅ **Completed** <relative-time …> | `abc1234` | Manual request |
<details> boilerplate naming "@codex review" and "@codex security review" </details>
```

`codex-review-state:v1` entries each have `commit_sha`, `status`, `has_any_findings`,
`has_unresolved_findings`. Observed lifecycle on a PR with 3 code findings:

| step | code_review | security_review | reactions |
|---|---|---|---|
| reviews start | `running`, findings `null`/`null` | `running`, `null`/`null` | 👀 added (~8 s later) |
| code done | `completed`, `true`/`true` | `running` | 👀 |
| all done | `completed`, `true`/`true` | `completed`, `false`/`false` | 👀 removed, **no 👍** |

A clean pass ends `completed` + `false`/`false` on both, then a 👍 (#237: summary edit
14:58:05, 👍 14:58:08).

- Statuses seen: `running`, `completed`. Anything else is unknown — surface it, don't guess.
- The two reviews track different shas: security often ran once on the PR-open sha while
  code review follows HEAD. Never require `security_review.commit_sha == HEAD`.
- Trigger column values: `PR opened`, `Manual request`, `New commits`, `Draft marked ready`.
- `codex-security-review:v1`'s `status` tracks the security review alone (coder/xum).

## Pitfalls (community-reported)

- **Completed without a review.** After a "reached your Codex usage limits" reply, Codex
  flipped the row to Completed and 👍'd with no review, inline comment or verdict behind it
  (sachiniyer/agent-factory#4052, merged unreviewed). The oracle refuses the summary-clean
  signal when a limit reply is newer than HEAD.
- **Null commit.** A code review that completes after a failed attempt shows the commit as
  `—` and `commit_sha: null`, findings `null` (coder/xum). Only an exact HEAD sha converges.
- **Not a verdict, not feedback.** The comment matches naive `/Codex Review/` and
  "security review" regexes and contains "@codex review" in prose (sachiniyer#3951). Exclude
  it from phrase matching and triage; it is status only.
- **Notification noise.** GitHub notifies on creation (review start), not on edits
  (completion) — openai/codex#42478. Poll; don't wait on a notification.

## Other artifacts

- **Review object** (findings only): body opens `<!-- codex-review-receipt:v1 -->`, then
  `### 💡 Codex Review`, "Here are some automated review suggestions…", `**Reviewed
  commit:** \`sha10\``, `<details>` footer. Findings live in inline threads, so the body is
  boilerplate — strip HTML comments, the header, the reviewed-commit line and `<details>`.
- **Inline findings**: first line `**<sub><sub>![P1 Badge](…/badge/P1-orange…)</sub></sub>
  Title**`. Code findings end with `<!-- codex-code-review-finding:v1 -->`; security
  findings start with `<!-- codex-security-review-finding:v1 -->` (coder/xum).
- **Clean receipt** (issue comment, manual triggers; auto reviews on #238/#239 left none): `<!-- codex-review-receipt:v1 -->`
  + "Codex Review: Didn't find any major issues. …" + `**Reviewed commit:**`.
- **Usage limit** (issue comment): "You have reached your Codex usage limits for code
  reviews." Security-review limit wording mentions "security review".
- **Failure** (issue comment): "Codex Review: Something went wrong. Try again later by
  commenting "@codex review". …" — reviewer-unavailable evidence, not a review.
- **Reactions** on the PR (issue reactions endpoint): 👀 while any review runs, 👍 once all
  reviews finish with no findings.

## Sources

- https://github.com/sachiniyer/agent-factory/issues/4052
- https://github.com/sachiniyer/agent-factory/issues/3951
- https://github.com/coder/xum/blob/main/scripts/lib/codex_comments.jq, https://github.com/coder/xum/pull/6828
- https://github.com/openai/codex/issues/42478
