#!/usr/bin/env bash
# pr-report.sh — deterministic data layer for the loop-pr-comments convergence report.
#
#   pr-report.sh <owner/repo> <pr> [--bot LOGIN] [--ignore SUBSTR]... [--unresolved]
#
# --unresolved prints one JSON object per unresolved thread instead of the report:
# {url, sev, t, path, state: answered_open|muted_open|unanswered, reply} — the waive comment's source.
#
# Journey/Fixed metrics are THREAD-derived: a CI-only fix or a review-body-only fix has
# no thread and will not appear in the counts — carry those in Goal/Decisions prose.
# --ignore mirrors the oracle's matching (path or first comment, case-insensitive);
# matched open threads render under Left over as "muted by --leave-open".
#
# Prints the "## Review loop summary" markdown with every mechanical section already
# filled — Journey numbers, the Fixed list (resolved threads with a "Fixed in <sha>"
# reply), and Left over (unresolved threads whose last word is the author side) — plus a
# fenced SOURCE MATERIAL block for the two judgment sections. The model fills the two
# <FILL> slots (Goal, Decisions), deletes the source block, and posts. This script never
# writes to GitHub; read-only gh calls only.
#
# Bucketing rules (mirror pr-state.sh):
#   fixed          resolved thread with an author-side reply citing a commit SHA
#   resolved_other resolved thread without a SHA reply (silent resolve, rebuttal, …)
#   answered_open  unresolved, author-side last comment  -> Left over
#   unanswered     unresolved, reviewer-side last comment -> should be none at convergence

set -uo pipefail

BOT=chatgpt-codex-connector
REPO='' PRNUM=''
IGNORE=()
die() { echo "pr-report.sh: $1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --bot) [ -n "${2:-}" ] || die "missing --bot value"; BOT=${2,,}; BOT=${BOT%\[bot\]}; shift ;;
    --unresolved) UNRESOLVED=1 ;;
    --ignore) [ -n "${2:-}" ] && [ -n "${2//[[:space:]]/}" ] || die "empty --ignore phrase"
              IGNORE+=("$2"); shift ;;
    -*) die "unknown option: $1" ;;
    *) if [ -z "$REPO" ]; then REPO=$1; elif [ -z "$PRNUM" ]; then PRNUM=$1; else die "extra arg: $1"; fi ;;
  esac
  shift
done
[ -n "$REPO" ] && [ -n "$PRNUM" ] || die "usage: pr-report.sh <owner/repo> <pr> [--bot LOGIN]"
[[ $REPO == */* ]] || die "repo must be owner/name"
[[ $PRNUM =~ ^[0-9]+$ ]] || die "pr must be a number"
[[ $BOT =~ ^[A-Za-z0-9._-]+$ ]] || die "bad --bot"
OWNER=${REPO%%/*}; NAME=${REPO##*/}
command -v jq >/dev/null || die "jq not found"
# gh api with rate-limit backoff (ghx); lives beside the oracle in address-pr-comments.
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../address-pr-comments/gh-rl.sh"

IGNORE_JSON=$( [ ${#IGNORE[@]} -eq 0 ] && echo '[]' || printf '%s\n' "${IGNORE[@]}" | jq -Rc 'ascii_downcase' | jq -sc . )

pr=$(ghx "repos/$REPO/pulls/$PRNUM" 2>&1) || die "pulls/$PRNUM: ${pr:0:200}"
TITLE=$(jq -r .title <<<"$pr")
BODY=$(jq -r '.body // ""' <<<"$pr")
AUTHOR=$(jq -r '.user.login|ascii_downcase|rtrimstr("[bot]")' <<<"$pr")
MERGED_AT=$(jq -r '.merged_at // ""' <<<"$pr")
URL=$(jq -r .html_url <<<"$pr")
HEAD_SHA=$(jq -r '.head.sha // ""' <<<"$pr")
# HEAD's commit date, so a 👍 older than it can be labelled. The ORACLE owns the
# freshness rule; this only stops the report asserting convergence on a signal the
# oracle would reject. Non-fatal: an empty date skips the check rather than dying.
HEAD_DATE=''
[ -n "$HEAD_SHA" ] && HEAD_DATE=$(ghx "repos/$REPO/commits/$HEAD_SHA" --cache 24h \
  --jq '.commit.committer.date // ""' 2>/dev/null) || true
ME=$(ghx user --cache 24h --jq '.login' 2>/dev/null | tr '[:upper:]' '[:lower:]') || ME=''

# reviews: bot round count + latest non-bot approval
reviews=$(ghx --paginate "repos/$REPO/pulls/$PRNUM/reviews" --jq \
  '.[] | [(.user.login|ascii_downcase|rtrimstr("[bot]")), (.user.login|test("\\[bot\\]$")|tostring), .state, (.submitted_at // "")] | @tsv' 2>&1) \
  || die "reviews: ${reviews:0:200}"
ROUNDS=$(awk -F'\t' -v b="$BOT" '$1==b' <<<"$reviews" | grep -c .)
APPROVAL=$(awk -F'\t' '$2=="false" && $3=="APPROVED"{print $4"\t"$1}' <<<"$reviews" | sort | tail -n1)

# reactions: freshest converging 👍 (review bot, or any non-bot)
reactions=$(ghx --paginate "repos/$REPO/issues/$PRNUM/reactions" --jq \
  '.[] | [.content, (.user.login|ascii_downcase|rtrimstr("[bot]")), (.user.login|test("\\[bot\\]$")|tostring), .created_at] | @tsv' 2>&1) \
  || die "reactions: ${reactions:0:200}"
THUMB=$(awk -F'\t' -v b="$BOT" '$1=="+1" && ($2==b || $3=="false"){print $4"\t"$2}' <<<"$reactions" | sort | tail -n1)

# the bot's clean "no major issues" issue comment is a converging signal too
CLEAN=$(ghx --paginate "repos/$REPO/issues/$PRNUM/comments" --jq \
  '.[] | select(.user.login|ascii_downcase|rtrimstr("[bot]") == "'"$BOT"'")
       | select(.body|ascii_downcase|test("codex review: didn.t find any major issues"))
       | .created_at' 2>/dev/null | sort | tail -n1)
# the bot's sticky summary comment: code review completed, no findings, on HEAD's sha
SUMMARY=$(ghx --paginate "repos/$REPO/issues/$PRNUM/comments" --jq \
  '.[] | select(.user.login|ascii_downcase|rtrimstr("[bot]") == "'"$BOT"'")
       | (.body // "" | capture("<!-- codex-review-state:v1 (?<j>\\{.*?\\}) -->").j | fromjson.code_review) as $c
       | select($c.status=="completed" and $c.has_any_findings==false and $c.commit_sha=="'"$HEAD_SHA"'")
       | .updated_at' 2>/dev/null | sort | tail -n1)

# freshest of the three signals wins (ISO timestamps sort lexicographically);
# the report labels the freshest signal — the ORACLE owns actual convergence.
best=''; CONVERGED_BY=''
for cand in "T:${THUMB%%$'\t'*}" "A:${APPROVAL%%$'\t'*}" "C:$CLEAN" "S:$SUMMARY"; do
  [ "${cand#*:}" \> "${best#*:}" ] && best=$cand
done
case "$best" in
  T:?*) THUMB_AT=${THUMB%%$'\t'*}
        CONVERGED_BY="👍 from ${THUMB#*$'\t'} at $THUMB_AT"
        # A 👍 older than HEAD is the first entry in the skill's own Common Mistakes
        # table. Say so rather than reporting it as a convergence.
        [ -n "$HEAD_DATE" ] && [ "$THUMB_AT" \< "$HEAD_DATE" ] &&
          CONVERGED_BY="$CONVERGED_BY — STALE, predates HEAD ($HEAD_DATE); the oracle does NOT converge on this"
        ;;
  A:?*) CONVERGED_BY="GitHub approval from ${APPROVAL#*$'\t'} at ${APPROVAL%%$'\t'*}" ;;
  C:?*) CONVERGED_BY="bot replied 'no major issues' at $CLEAN" ;;
  S:?*) CONVERGED_BY="bot summary: code review clean on HEAD ${HEAD_SHA:0:7} at $SUMMARY" ;;
esac
if [ -z "$CONVERGED_BY" ]; then
  [ -n "$MERGED_AT" ] && CONVERGED_BY="no reaction/approval — merged at $MERGED_AT" \
                      || CONVERGED_BY="no converging signal yet"
fi

# threads: one compact JSON object per thread. `last:1` is fetched separately so the
# last-speaker classification survives threads longer than the first-50 comment page.
threads=$(ghx graphql --paginate -f query='
  query($owner:String!,$repo:String!,$number:Int!,$endCursor:String){
    repository(owner:$owner,name:$repo){ pullRequest(number:$number){
      reviewThreads(first:50, after:$endCursor){
        pageInfo{ hasNextPage endCursor }
        nodes{ isResolved path
               comments(first:50){ nodes{ author{ login } body url } }
               last: comments(last:1){ nodes{ author{ login } body } } }
      }}}}' -F owner="$OWNER" -F repo="$NAME" -F number="$PRNUM" --jq '
    .data.repository.pullRequest.reviewThreads.nodes[]
    | {resolved: .isResolved, path: (.path // ""),
       c: [.comments.nodes[] | {a: ((.author.login // "")|ascii_downcase|rtrimstr("[bot]")), b: (.body // ""), u: (.url // "")}],
       l: (.last.nodes[0] // {} | {a: ((.author.login // "")|ascii_downcase|rtrimstr("[bot]")), b: (.body // "")})}' 2>&1) \
  || die "threads: ${threads:0:200}"

# Everything below is pure jq over the collected threads.
D=$(mktemp) || die "mktemp failed"
trap 'rm -f "$D"' EXIT
jq -sc --arg bot "$BOT" --arg author "$AUTHOR" --arg me "$ME" '
  '"$IGNORE_JSON"' as $ig
  | def authorside($a): $a == $author or ($me != "" and $a == $me);
  def title:
    (.c[0].b // "")
    | gsub("</?su[bp]>"; "") | gsub("!\\[[^\\]]*\\]\\([^)]*\\)"; "") | gsub("\\*"; "")
    | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))
    | (.[0] // "(no comment)") | .[0:90];
  def sev: (.c[0].b // "") | if test("P0 Badge") then "P0" elif test("P1 Badge") then "P1" elif test("P2 Badge") then "P2" elif test("P3 Badge") then "P3" else "-" end;
  def sha: [ (.c + [.l])[] | select(authorside(.a)) | .b | scan("(?<![Nn]ot )[Ff]ixed in[^0-9a-f]{0,4}([0-9a-f]{6,40})") ]
           | flatten | (last // null) | if . == null then null else .[0:7] end;
  def lastreply: (.l.b // "") | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))
                 | (.[0] // "") | .[0:160];
  map({resolved, path, t: title, sev: sev, sha: sha, last_a: (.l.a // ""), reply: lastreply, url: (.c[0].u // ""),
       muted: ((((.path // "") + " " + (.c[0].b // "")) | ascii_downcase) as $hay | any($ig[]; inside($hay)))})
  | {findings: length,
     p1: (map(select(.sev == "P1")) | length),
     p2: (map(select(.sev == "P2")) | length),
     p3: (map(select(.sev == "P3")) | length),
     fixed: (map(select(.resolved and .sha != null)) | map({t, sha})),
     commits: ([ .[] | select(.resolved and .sha != null) | .sha ] | unique | length),
     resolved_other: (map(select(.resolved and .sha == null)) | map({t, path, reply})),
     answered_open: (map(select((.resolved | not) and (.muted | not) and (.last_a as $a | $a == $author or ($me != "" and $a == $me)))) | map({t, path, reply, url, sev})),
     muted_open: (map(select((.resolved | not) and .muted)) | map({t, path, reply, url, sev})),
     unanswered: (map(select((.resolved | not) and (.muted | not) and ((.last_a as $a | $a == $author or ($me != "" and $a == $me)) | not))) | map({t, path, reply, url, sev}))}
' <<<"$threads" > "$D" || die "thread digest failed"

FINDINGS=$(jq .findings "$D"); P1=$(jq .p1 "$D"); P2=$(jq .p2 "$D"); P3=$(jq .p3 "$D")
COMMITS=$(jq .commits "$D")
if [ "${UNRESOLVED:-0}" = 1 ]; then
  jq -c '(.answered_open[] | .state="answered_open"), (.muted_open[] | .state="muted_open"),
         (.unanswered[] | .state="unanswered")' "$D"
  exit 0
fi
SEVSTR="$P1 P1, $P2 P2"; [ "$P3" -gt 0 ] && SEVSTR="$SEVSTR, $P3 P3"

cat <<EOF
## Review loop summary

**Goal** — <FILL: 1–3 sentences on what this PR set out to do; source: title + body below>

**Journey** — $ROUNDS review rounds, $FINDINGS findings ($SEVSTR), $COMMITS fix commits;
converged by $CONVERGED_BY.

**Fixed**
EOF
jq -r '.fixed[] | "- \(.t) → `\(.sha)`"' "$D"
jq -re '.fixed | length == 0' "$D" >/dev/null && echo "- none"

cat <<'EOF'

**Decisions (major drifts from the initial plan)**
- <FILL: only MAJOR course changes forced during review — design pivots, scope
  cuts/additions, approach reversals — each anchored to a thread or commit.
  "none — landed as planned" is valid. Source material below.>

**Left over (answered, deliberately left open)**
EOF
jq -r '.answered_open[] | "- \(.t) — \"\(.reply)\" (`\(.path)`)"' "$D"
jq -r '.muted_open[] | "- \(.t) — muted by --leave-open (`\(.path)`)"' "$D"
jq -re '(.answered_open|length) + (.muted_open|length) == 0' "$D" >/dev/null && echo "- none"

cat <<EOF

<!-- ══ SOURCE MATERIAL — for filling the FILL slots. DELETE this block before posting. ══
PR: $URL
Title: $TITLE

Body:
$BODY

Resolved WITHOUT a fix SHA (rebuttals, silent resolves — judge whether any is a Decision):
EOF
jq -r 'if (.resolved_other | length) == 0 then "- none" else .resolved_other[] | "- \(.t) — \"\(.reply)\" (`\(.path)`)" end' "$D"
echo ""
echo "Unresolved threads with the REVIEWER side last (should be none at convergence):"
jq -r 'if (.unanswered | length) == 0 then "- none" else .unanswered[] | "- \(.t) (`\(.path)`)" end' "$D"
echo "══ END SOURCE MATERIAL ══ -->"
