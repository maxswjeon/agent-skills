# agent-skills

Sangwan Jeon's own agent skills (the `SKILL.md` format Claude Code loads from `~/.claude/skills`).

| Skill | What it does |
|---|---|
| [address-pr-comments](address-pr-comments/) | One round of PR review: triage feedback and failing checks, fix, reply with the fix commit, resolve. `pr-state.sh` is the review-state oracle, `pr-ops.sh` does the mechanical steps, `gh-rl.sh` handles GitHub rate limits. |
| [loop-pr-comments](loop-pr-comments/) | Repeats address-pr-comments until Codex or a human approves, with a judge agent every 5 review rounds. Needs address-pr-comments. |
| [cleanup-worktree](cleanup-worktree/) | Removes git worktrees and branches already merged into the integration branch, squash merges included. |

## Install

Clone into your skills directory, or symlink the skills you want:

```bash
git clone https://github.com/maxswjeon/agent-skills ~/.claude/skills
```

The PR skills need bash 4.4+, GNU date, `jq`, `envsubst` (gettext) and an authenticated `gh`. Their scripts have `--self-test`.

## Adding a skill

`.gitignore` is an allow-list: add a `!/<skill>/` line for each new skill directory.
