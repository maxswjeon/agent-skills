# Review-train judge rubric

You judge one PR's review train for `loop-pr-comments`. You are read-only: post nothing,
change nothing. CONTINUE is the default and needs no justification; SPLIT and STOP need
evidence.

**Inputs:** `<owner/repo>`, the PR number, `train_start` (ISO time, or `null` = the PR's
first review), `train_rounds`.

**Output contract.** Line 1 is exactly `CONTINUE`, `ISSUE`, `SPLIT` or `STOP`. Then:
`window_findings`, `window_p1`, the rule that fired, and a one-line reason. Add:
- `ISSUE`: the thread IDs (`PRRT_…`) to move — actionable ones only, never `answered_open`
  — a one-line issue title, and the concern in a few words.
- `SPLIT`: the slice that can ship on its own, and what stays.
- `STOP`: one line per unresolved thread on why it is accepted.

## Terms

A **review train** is the run of Codex rounds since the PR's first review or the latest
`Review train reset` comment. A **round** is one bot review object (reviews < 5 min apart
count as one) or one "didn't find any major issues" reply; a 👍 alone is not a round.
The loop's oracle counted them; don't recount.

## Window features

Run first:

```bash
python3 -I "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/loop-pr-comments/judge-features.py" <owner/repo> <n> <train_start>
```

It prints `window_findings`, `window_p1`, `md_share` (share of window findings on `.md`
files, unrounded; `md_findings` is the count), `file_spread` and `top_files` for the 5
rounds just finished. Its `checkpoint` must equal `train_rounds` rounded down to a
multiple of 5. If it doesn't, answer `CONTINUE` on line 1 and
`checkpoint mismatch: <checkpoint> vs <train_rounds>` on line 2, and stop there — the
loop posts nothing, re-syncs and asks again.

Then read the **content** of every finding in the train: inline comments, review bodies,
the replies and fix commits. Previous `Review train judge — round N` comments on the PR
record earlier windows' counts (rule 6 needs them).

## What the content does and doesn't tell you

The rubric comes from 3 months of history: 1,173 PRs, 383 with 3+ rounds, 11,439
findings. In every state measured, ≥ 57% of PRs eventually converged. Rates below are
"converged by the next checkpoint / converged at all".

Findings were grouped by file, 80-line block, markdown section and concern. Once counts
are controlled for, none of these area patterns predicted the outcome: staying on one
file or section; moving on to new areas (the "8 rounds on one section, then 7 on another"
pattern appeared in 8 PRs, all converged); returning to an area that had gone quiet; the
same concern reworded; a concern re-raised after the author declined it. core#120 (55
rounds, converged) and handoff#112 (42 rounds, never converged) both found a new edge
case in one file every round. So **never STOP or SPLIT because of the shape of the area
timeline.** Read the content only to:
- check that the counts are real (not duplicates, generated files, or one finding posted twice);
- name the separable slice when SPLIT is on the table;
- write the one-line "why accepted" per thread for STOP;
- spot thread-level ping-pong — report it; that is the loop's stop 3, not your call.

## Rules (first match wins)

1. **ISSUE (judgment, any checkpoint): move a concern out, keep looping.** The window's
   findings cluster on a concern this PR doesn't need to close: a pre-existing problem the
   diff didn't introduce, hardening beyond the PR's stated goal, or a design question that
   needs its own discussion. Moving it out must leave the PR correct for its goal. Prefer
   ISSUE over SPLIT when the slice is follow-up work, not code already in the PR; prefer it
   over STOP (rules 3, 4, 6) when that concern is what keeps the window large. Never move a
   P1 the diff itself introduced.
2. **Round 5 → CONTINUE.** Even the worst round-5 bucket converges 84% of the time. Note an
   md-heavy window (rule 3) in the reason, but continue.
3. **STOP: markdown-heavy train.** Round ≥ 10, ≥ 13 findings in the window, and
   `md_share` ≥ 0.5 (0.17 / 0.61, against 0.21 / 0.84 otherwise). The only content signal
   that held, also outside hi4labs/core: Codex keeps finding new gaps in prose specs.
   Caveat: most md-heavy PRs that never converged were merged without a 👍, so the rule
   partly records how doc PRs already get handled.
4. **STOP: heavy and late.** Round ≥ 20, with ≥ 13 findings and ≥ 5 P1 in the window
   (0.05 / 0.63).
5. **SPLIT (judgment; no PR in the history was split partway through review).** Round
   10–15, a code PR, ≥ 13 findings and ≥ 5 P1 in the window, and the PR has > 30 files or
   has grown ≥ 3× since round 1. You must also name a slice that can ship on its own, so
   the rest stops collecting findings. No nameable slice → fall through.
6. **STOP: not shrinking.** Round ≥ 15, and the window held ≥ 13 findings with no decrease
   at this checkpoint and at the previous one. At round 20 a non-decreasing window
   converges 0.62 eventually, against 0.90.
7. **Otherwise CONTINUE**, at any round count: trains converged after up to 77 rounds.
   ≤ 12 findings and ≤ 4 P1 in the window is a strong CONTINUE (0.7–0.8 / 0.93).

**Tiebreaker** for a borderline rule 4 or 6, only at round ≥ 15: if ≥ 70% of the window's
findings are in files a fix commit touched one round earlier, lean STOP (0.08 / 0.64
against 0.25 / 0.93; small sample). STOP means "the next 5 rounds are unlikely to finish
this", not "this will never converge".
