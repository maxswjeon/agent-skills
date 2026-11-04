#!/usr/bin/env bash
# pr-ops.sh — the deterministic half of address-pr-comments / loop-pr-comments.
#
# The model keeps every judgment (triage, fixes, reply wording, judge verdicts, report
# prose). Everything mechanical lives here: paginated queries, comment stripping, quoting,
# label bookkeeping, and the comment formats pr-state.sh parses back. State is always read
# through pr-state.sh (the oracle); this script never re-derives a decision, it only maps
# the oracle's answer to side effects (`sync`).
#
# Invariants worth knowing before editing:
#   - `sync` gate order: waived > converged > closed > error > judge_due (--loop) > action.
#     A waived PR gets no side effects at all. Convergence outranks a due judge.
#   - review-converged and the visible "## Review loop summary" follow the oracle: converged
#     adds the label; address/conflict/trigger_review on a labelled PR hides the summaries,
#     then drops the label — and keeps the label if hiding failed, so the next sync retries.
#   - `reply` resolves only when the reply (or, for a resolve-only item, the thread's last
#     comment) cites "Fixed in <sha>" for a commit on the PR head — the regex pr-report.sh
#     uses for its Fixed list. Reply and resolve are separate calls reported separately
#     (`replied`, `resolved`), so a retry never double-posts.
#   - judge/reset bodies must open with "> **" — pr-state.sh keys on that prefix.
#   - Rate limits (gh-rl.sh): REST wherever it is exact (PR, labels, comments, issues);
#     GraphQL only for threads, resolve and minimize, with a REST fallback for thread
#     reads and replies. Foreground commands fail within ~90s naming the reset; `sync` turns
#     that into next=rate_limited. A rate-limited write fails fast (GH_RL_NO_WAIT) so its
#     result line always prints before the tool timeout.
# Requires bash 4.4+, jq 1.6+, gh. --self-test asserts the pure parts.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/gh-rl.sh"
# One wall-clock deadline for all rate-limit sleeping in this command (and the oracle it
# runs): ~90s keeps a foreground command inside the Bash tool's 120s timeout.
export GH_RL_DEADLINE=${GH_RL_DEADLINE:-$(( $(date +%s) + 90 ))}
STATE="$HERE/pr-state.sh"
SUMMARY_H='## Review loop summary'
WAIVE_H='## Known limitations (review waived)'
FIXED_RE='(?<![Nn]ot )[Ff]ixed in[^0-9a-f]{0,4}([0-9a-f]{6,40})'

usage() { cat "$HERE/pr-ops-usage.txt"; }

die() { jq -nc --arg e "$1" '{ok:false,error:$e}'; exit 1; }
need_pr() {
  [[ ${1:-} == */* && ${2:-} =~ ^[0-9]+$ ]] || die "need <owner/repo> <pr>, got: ${1:-} ${2:-}"
  REPO=$1 PR=$2 OWNER=${1%%/*} NAME=${1##*/}
}
parse_flags() {
  IGN=() IGN_RAW=() LOOP=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --ignore) [ -n "${2:-}" ] && [ -n "${2//[[:space:]]/}" ] || die "empty --ignore phrase would mute every thread"
                IGN+=(--ignore "$2"); IGN_RAW+=("$2"); shift ;;
      --loop) LOOP=1 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
}
me() { ME=$(ghx user --jq '.login|ascii_downcase' 2>/dev/null) || ME=''; }
post_comment() { # body → {ok,url}; REST
  local out; out=$(ghx -X POST "repos/$REPO/issues/$PR/comments" -f body="$1" --jq '{ok:true,url:.html_url}' 2>&1) \
    || die "comment: ${out:0:300}"
  echo "$out"
}

# ------------------------------------------------------------------ pure parts
# sync's decision: oracle JSON in, {next, ops} out. $labels = current PR labels, $loop = bool.
PLAN='
def has($l): $labels | index($l) != null;
.action as $a
| (if (.waived and ($a != "error")) then "waive"
   elif $a == "converged" then "report"
   elif $a == "closed" then "stop"
   elif $a == "error" then (if ((.error // "") | test("rate limit"; "i")) then "rate_limited" else "error" end)
   elif $loop and .judge_due then "judge"
   elif $a == "no_reviewer" then "blocked"
   elif $a == "address" or $a == "conflict" then $a
   else "wait" end) as $next
| {next: $next,
   ops: (if $next == "waive" or $a == "error" then []
         elif $a == "converged" then
           (if has("review-converged") then [] else ["label:review-converged"] end)
           + [("review-blocked","review-waived") | select(has(.)) | "unlabel:" + .]
         else
           (if ($a == "address" or $a == "conflict" or $a == "trigger_review") and has("review-converged")
            then ["hide", "unlabel:review-converged"] else [] end)
           + (if $a == "trigger_review" and $next == "wait" then ["trigger"] else [] end)
         end)}'

# Thread / review-body cleanup: drop HTML comments and Codex boilerplate, keep severity.
CLEAN='
def clean: (. // "") | gsub("<!--[\\s\\S]*?-->"; "")
  | gsub("\\*\\*<sub><sub>!\\[(?<s>P[0-3]) Badge\\]\\([^)]*\\)</sub></sub>\\s*"; "[\(.s)] **")
  | gsub("\\s*Useful\\? React with 👍 / 👎\\.?"; "") | gsub("^\\s+|\\s+$"; "");
def strip_review: (. // "") | gsub("<details>[\\s\\S]*</details>"; "") | gsub("<!--[\\s\\S]*?-->"; "")
  | gsub("### 💡 Codex[^\n]*Review"; "")
  | gsub("Here are some automated[^\n]*review suggestions for this pull request."; "")
  | gsub("\\*\\*Reviewed commit:\\*\\*[^\n]*"; "") | gsub("^\\s+|\\s+$"; "");
def who: ascii_downcase | rtrimstr("[bot]");
def authorside: . == $author or ($me != "" and . == $me);
def loopmarker: (.body // "") | ascii_downcase
  | test("^(## |> \\*\\*)(review (loop summary|train reset|train judge)|known limitations)");
def trigger: (.body // "") | ascii_downcase | test("^\\s*@(chatgpt-codex-connector|codex)\\s+review\\b");'

fmt_judge() { # round VERDICT findings p1 reason [issue concern]
  local r=$1 v=${2^^} w=$3 p=$4 reason=${5//$'\n'/ } k=${6:-} c=${7:-}
  [[ $r =~ ^[0-9]+$ && $w =~ ^[0-9]+$ && $p =~ ^[0-9]+$ ]] || die "round, findings and p1 must be integers"
  [ -n "$reason" ] || die "judge needs a reason"
  case $v in
    CONTINUE|SPLIT|STOP) ;;
    ISSUE) [[ $k =~ ^[0-9]+$ ]] && [ -n "$c" ] || die "ISSUE needs <issue#> <concern>" ;;
    *) die "verdict must be CONTINUE, ISSUE, SPLIT or STOP" ;;
  esac
  local b="> **Review train judge — round $r: $v** — $w findings, $p P1 in window; $reason"
  [ "$v" = ISSUE ] && b+="; issue #$k: ${c//$'\n'/ }"
  printf '%s' "$b"
}
fixed_sha() { jq -Rrs --arg re "$FIXED_RE" '[scan($re)] | last | .[0] // empty' <<<"$1"; }

# ------------------------------------------------------------------ commands
cmd_resolve() {
  local v
  [[ ${1:-} =~ ^https?:// ]] && ! [[ $1 =~ ^https://github\.com/ ]] && die "only github.com PRs are supported: $1"
  if [[ ${1:-} =~ ^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then   # REST: no GraphQL needed
    v=$(ghx "repos/${BASH_REMATCH[1]}/pulls/${BASH_REMATCH[2]}" --jq '{number, url: .html_url,
          headRefName: .head.ref, baseRefName: .base.ref,
          state: (if .merged_at then "MERGED" else (.state | ascii_upcase) end)}' 2>&1) || die "pulls: ${v:0:300}"
  else
    v=$(gh pr view ${1:+"$1"} --json number,url,headRefName,baseRefName,state 2>&1) \
      || die "gh pr view: ${v:0:300}$([ "$(rl_kind "$v")" != none ] && echo ' — pass the PR URL to resolve over REST')"
  fi
  local br='' clean=false
  if git rev-parse --git-dir >/dev/null 2>&1; then
    br=$(git rev-parse --abbrev-ref HEAD)
    [ -z "$(git status --porcelain)" ] && clean=true
  fi
  # The base repo comes from the URL: headRepository is the fork on a fork PR.
  jq -c --arg br "$br" --argjson clean "$clean" '
    (.url | capture("https?://[^/]+/(?<r>[^/]+/[^/]+)/pull/").r) as $repo
    | {repo: $repo, pr: .number, url, state, head_ref: .headRefName, base_ref: .baseRefName,
       branch: $br, clean: $clean, checkout_ok: ($br == .headRefName and $clean)}' <<<"$v" \
    || die "could not parse the PR: ${v:0:200}"
  [[ $(jq -r .url <<<"$v") == https://github.com/* ]] || die "only github.com PRs are supported: $(jq -r .url <<<"$v")"
}

cmd_feedback() {
  need_pr "${1:-}" "${2:-}"; shift 2; parse_flags "$@"; me
  local pr author head cm rv ig
  pr=$(ghx "repos/$REPO/pulls/$PR" 2>&1) || die "pulls: ${pr:0:300}"
  author=$(jq -r '.user.login|ascii_downcase|rtrimstr("[bot]")' <<<"$pr"); head=$(jq -r .head.sha <<<"$pr")
  ig=$(printf '%s\n' "${IGN_RAW[@]}" | jq -Rsc 'split("\n") | map(select(length > 0) | ascii_downcase)')
  threads_read "$REPO" "$PR" 30 || die "threads: ${THREADS_JSON:0:300}"
  cm=$(ghx --paginate "repos/$REPO/issues/$PR/comments" --jq \
    '.[] | {id, user: .user.login, bot: (.user.login | test("\\[bot\\]$")), at: .created_at, url: .html_url, body}' 2>&1) \
    || die "comments: ${cm:0:300}"
  rv=$(ghx --paginate "repos/$REPO/pulls/$PR/reviews" --jq \
    '.[] | {id, user: .user.login, state, at: (.submitted_at // ""), url: .html_url, body}' 2>&1) \
    || die "reviews: ${rv:0:300}"
  ci_checks "$REPO" "$PR" "$head" || die "checks: ${CI_JSON:0:300}"
  local fails='[]' row job tail
  while IFS= read -r row; do
    job=$(jq -r '(.link // "") | capture("/job/(?<j>[0-9]+)").j // empty' <<<"$row")
    tail=''
    [ -n "$job" ] && tail=$(gh run view --job "$job" --repo "$REPO" --log-failed 2>/dev/null \
      | cut -f3- | sed -E 's/^[0-9]{4}-[0-9-]+T[0-9:.]+Z ?//' | tail -n 40 | cut -c1-300)
    fails=$(jq -c --argjson r "$row" --arg t "$tail" '. + [$r + {log_tail: $t}]' <<<"$fails")
  done < <(jq -c '.[] | select(.bucket == "fail" or .bucket == "cancel")' <<<"$CI_JSON")

  jq -nc --arg author "$author" --arg me "$ME" --arg head "$head" --argjson ig "$ig" \
    --argjson fails "$fails" --arg ts "$THREADS_SRC" --arg cs "$CI_SRC" \
    --slurpfile th <(printf '%s\n' "$THREADS_JSON") \
    --slurpfile cm <(printf '%s\n' "$cm") --slurpfile rv <(printf '%s\n' "$rv") "$CLEAN"'
    # Author-side answer clock: the newest non-marker, non-trigger comment by the author/operator.
    ([$cm[] | select((.bot | not) and (.user | who | authorside) and (loopmarker | not) and (trigger | not)) | .at]
     | max // "") as $last
    | {head: $head[0:7], sources: {threads: $ts, ci: $cs},
       threads: [$th[] | select(.resolved | not)
         | select((.last_by // "") | who | authorside | not)
         | select(((.path // "") + " " + (.comments[0].body // "")) | ascii_downcase
                  | . as $h | any($ig[]; inside($h)) | not)
         | {id, root, url, path, line, outdated, thumbs_down, count,
            comments: [.comments[] | {by: ((.by // "") | who), body: (.body | clean)}]}],
       # Bot bodies are template unless > 50 chars survive stripping; a human CHANGES_REQUESTED
       # always shows (the oracle keeps saying address until it is answered).
       review_bodies: [$rv[] | select((.user | who | authorside) | not) | select(.at > $last)
         | .body = (.body | strip_review)
         | select(.state == "CHANGES_REQUESTED"
                  or ((.body | gsub("\\s"; "") | length) > (if (.user | test("\\[bot\\]$")) then 50 else 0 end)))
         | {id, user, state, url, body}],
       comments: [$cm[] | select((.bot | not) and ((.user | who | authorside) | not) and (trigger | not))
         | select(.at > $last) | {id, user, url, body}],
       failing_checks: $fails}' || die "feedback: could not assemble the output"
}

reply_post() { # <thread> <root> <body> → rc; ERR on failure. GraphQL; REST via the root comment when limited.
  local out root=$2
  if [ -n "$1" ]; then
    out=$(GH_RL_NO_WAIT=1 ghx graphql -f t="$1" -f b="$3" -f query='mutation($t:ID!,$b:String!){
      addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t, body:$b}){ comment{ id } } }' 2>&1 >/dev/null) && return 0
    [ "$(rl_kind "$out")" = none ] && { ERR=${out:0:300}; return 1; }
    [ -n "$root" ] || root=$(awk -F'\t' -v t="$1" '$1 == t {print $2}' "$(tcache_file "$REPO" "$PR")" 2>/dev/null)
  fi
  [ -n "$root" ] || { ERR="GraphQL is rate-limited and $1 has no known root comment; re-send with \"root\" from feedback"; return 1; }
  out=$(ghx -X POST "repos/$REPO/pulls/$PR/comments/$root/replies" -f body="$3" 2>&1 >/dev/null) || { ERR=${out:0:300}; return 1; }
}
resolve_thread() { # <thread> → rc; ERR on failure. GraphQL only: REST cannot resolve.
  local out
  out=$(GH_RL_NO_WAIT=1 ghx graphql -f t="$1" -f query='mutation($t:ID!){ resolveReviewThread(input:{threadId:$t}){ thread{ isResolved } } }' 2>&1 >/dev/null) \
    || { ERR=${out:0:300}; return 1; }
}

cmd_reply() {
  need_pr "${1:-}" "${2:-}"
  local head i=0 failed=0 line t r root b res sha src err st rep resd g
  me
  head=$(ghx "repos/$REPO/pulls/$PR" --jq .head.sha 2>&1) || die "pulls: ${head:0:300}"
  declare -A onpr=()
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "${line//[[:space:]]/}" ] || continue
    i=$((i+1)); err='' rep=false resd=false
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$line"; then
      err="not a JSON object"
    else
      t=$(jq -r '.thread // empty' <<<"$line"); r=$(jq -r '.review // empty' <<<"$line")
      root=$(jq -r '.root // empty' <<<"$line"); b=$(jq -r '.body // empty' <<<"$line")
      res=$(jq -r '.resolve == true' <<<"$line")
      if [ -n "$root" ] && ! [[ $root =~ ^[0-9]+$ ]]; then err='"root" must be a number'
      elif [ -z "$t" ] && [ -z "$root" ] && ! [[ $r =~ ^[0-9]+$ ]]; then err='item needs "thread", "root" or a numeric "review"'
      elif [ "$res" = true ] && [ -z "$t" ]; then err='resolve needs "thread"'
      elif [ -z "$b" ] && [ "$res" != true ]; then err='item needs a non-empty body'
      fi
      if [ -z "$err" ] && [ "$res" = true ]; then
        # Resolving needs GraphQL: check the budget before posting anything, so a re-send is safe.
        g=$(rl_status | cut -f4)
        [ "${g:-1}" -gt 0 ] 2>/dev/null || err="GraphQL rate limit exhausted$(rl_until graphql); nothing posted — re-send after the reset"
        src=$b
        if [ -z "$err" ] && [ -z "$b" ]; then   # resolve-only: our own last comment must cite the fix
          src=$(ghx graphql -f t="$t" -f query='query($t:ID!){ node(id:$t){ ... on PullRequestReviewThread{
                  comments(last:1){ nodes{ author{ login } body } } } } }' \
                --jq '.data.node.comments.nodes[0] | ((.author.login // "") | ascii_downcase) + "\t" + (.body // "")' 2>&1) \
            || err="could not read the thread: ${src:0:200}"
          if [ -z "$err" ]; then
            if [ -z "$ME" ]; then err="could not read your login, so the thread's last comment can't be checked; try again"
            elif [ "${src%%$'\t'*}" != "$ME" ]; then err="resolve-only needs your own 'Fixed in <sha>' reply as the thread's last comment"; fi
            src=${src#*$'\t'}
          fi
        fi
        if [ -z "$err" ]; then
          sha=$(fixed_sha "$src")
          [ -n "$sha" ] || err="resolve needs 'Fixed in <sha>' (in the body, or as the thread's last comment); explain/defer replies stay open"
        fi
        if [ -z "$err" ] && [ -z "${onpr[$sha]+x}" ]; then
          st=$(ghx "repos/$REPO/compare/$sha...$head" --jq .status 2>&1)
          case $st in
            ahead|identical) onpr[$sha]=1 ;;
            behind|diverged|*"HTTP 404"*) onpr[$sha]=0 ;;   # 404: GitHub has never seen it
            *) err="could not verify $sha against the PR head: ${st:0:200}" ;;
          esac
        fi
        [ -z "$err" ] && [ "${onpr[$sha]}" = 0 ] && err="cited $sha is not on the PR head (${head:0:7}) — push first"
      fi
      if [ -z "$err" ] && [ -n "$b" ]; then
        if [ -n "$t" ] || [ -n "$root" ]; then reply_post "$t" "$root" "$b" && rep=true || err=$ERR
        else
          ERR=$(ghx -X POST "repos/$REPO/issues/$PR/comments" \
                  -f body="Re: [review](https://github.com/$REPO/pull/$PR#pullrequestreview-$r)"$'\n\n'"$b" 2>&1 >/dev/null) \
            && rep=true || err=${ERR:0:300}
        fi
      fi
      if [ -z "$err" ] && [ "$res" = true ]; then
        resolve_thread "$t" && resd=true || err="resolve failed: $ERR"
      fi
    fi
    [ -n "$err" ] && failed=$((failed+1))
    jq -nc --argjson i "$i" --argjson rep "$rep" --argjson res "$resd" --arg e "$err" \
      '{item: $i, ok: ($e == ""), replied: $rep, resolved: $res} + (if $e == "" then {} else {error: $e} end)'
  done
  [ "$failed" = 0 ]
}

cmd_push() {
  need_pr "${1:-}" "${2:-}"
  local out l r
  out=$(git push 2>&1) || die "push failed: ${out: -300}"
  l=$(git rev-parse HEAD)
  for _ in 1 2 3 4 5; do   # the PR's head ref lags the push by a moment
    r=$(ghx "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null)
    [ "$l" = "$r" ] && { jq -nc --arg s "${l:0:7}" '{ok:true, sha:$s}'; return; }
    sleep 2
  done
  die "pushed, but the PR head is ${r:0:7} and local HEAD is ${l:0:7} — wrong branch or remote?"
}

hide_summaries() { # minimize every visible "## Review loop summary" as OUTDATED; rc 1 if any fails
  local ids id rc=0
  ids=$(ghx graphql --paginate -f query='
    query($owner:String!,$repo:String!,$number:Int!,$endCursor:String){
      repository(owner:$owner,name:$repo){ pullRequest(number:$number){
        comments(first:100, after:$endCursor){ pageInfo{ hasNextPage endCursor }
          nodes{ id isMinimized viewerCanMinimize body } } } } }' \
    -F owner="$OWNER" -F repo="$NAME" -F number="$PR" \
    --jq '.data.repository.pullRequest.comments.nodes[]
          | select(.viewerCanMinimize and (.isMinimized | not) and (.body | startswith("## Review loop summary"))) | .id' 2>&1) \
    || { ERR=${ids:0:300}; return 1; }
  for id in $ids; do
    ghx graphql -f id="$id" -f query='mutation($id:ID!){
      minimizeComment(input:{subjectId:$id, classifier:OUTDATED}){ minimizedComment{ isMinimized } } }' \
      >/dev/null 2>&1 || rc=1
  done
  return $rc
}

label_add() { # name color description; REST
  gh label create "$1" --repo "$REPO" --color "$2" --description "$3" --force >/dev/null 2>&1 || true
  ghx -X POST "repos/$REPO/issues/$PR/labels" -f "labels[]=$1" >/dev/null 2>&1
}
label_rm() { # 404 = not on the PR any more, which is the goal
  local out; out=$(ghx -X DELETE "repos/$REPO/issues/$PR/labels/$(jq -rn --arg l "$1" '$l | @uri')" 2>&1) && return 0
  [[ $out == *"HTTP 404"* ]]
}

cmd_sync() {
  need_pr "${1:-}" "${2:-}"; shift 2; parse_flags "$@"
  local st labels plan op hide_ok=1 done=() out next
  st=$(bash "$STATE" "$REPO" "$PR" "${IGN[@]}")
  jq -e .action >/dev/null 2>&1 <<<"$st" || st=$(jq -nc --arg e "oracle: ${st:0:300}" '{action:"error", error:$e}')
  labels='[]'
  if [ "$(jq -r .action <<<"$st")" != error ]; then
    labels=$(ghx "repos/$REPO/issues/$PR/labels" --jq '[.[].name]' 2>&1) \
      || { st=$(jq -c --arg e "labels: ${labels:0:300}" '. + {oracle_action: .action, action: "error", error: $e}' <<<"$st"); labels='[]'; }
  fi
  plan=$(jq -c --argjson labels "$labels" --argjson loop "$([ "$LOOP" = 1 ] && echo true || echo false)" "$PLAN" <<<"$st")
  for op in $(jq -r '.ops[]' <<<"$plan"); do
    [ -n "${PR_OPS_DRY_RUN:-}" ] && { done+=("$op:dry-run"); continue; }   # testing: plan only
    case "$op" in
      trigger) ghx -X POST "repos/$REPO/issues/$PR/comments" -f body='@codex review' >/dev/null 2>&1 ;;
      hide) hide_summaries || hide_ok=0 ;;
      label:review-converged) label_add review-converged 0e8a16 'Review loop converged; no open actionable feedback' ;;
      unlabel:review-converged) [ "$hide_ok" = 1 ] && label_rm review-converged ;;   # keep it until the summary is hidden
      unlabel:*) label_rm "${op#unlabel:}" ;;
    esac && done+=("$op") || done+=("$op:failed")
  done
  out=$(jq -c --argjson p "$plan" --argjson did "$(printf '%s\n' "${done[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    '{next: $p.next, did: $did} + .' <<<"$st")
  echo "$out"
  next=$(jq -r .next <<<"$out"); [ "$next" != error ] && [ "$next" != rate_limited ]
}

cmd_block() {
  need_pr "${1:-}" "${2:-}"
  label_add review-blocked d73a4a 'Review loop blocked by Codex or devbox problems' || die "could not add review-blocked"
  jq -nc '{ok:true}'
}
cmd_unblock() { need_pr "${1:-}" "${2:-}"; label_rm review-blocked || die "could not remove review-blocked"; jq -nc '{ok:true}'; }

cmd_reset() {
  need_pr "${1:-}" "${2:-}"; [ -n "${3:-}" ] || die "reset needs <what the user asked for>"
  post_comment "> **Review train reset** — ${3//$'\n'/ }"
}

cmd_judge() {
  need_pr "${1:-}" "${2:-}"; shift 2
  [ $# -ge 5 ] || die "judge <repo> <n> <train_rounds> <VERDICT> <findings> <p1> <reason> [<issue#> <concern>]"
  local b; b=$(fmt_judge "$@") || { echo "$b"; exit 1; }
  post_comment "$b"
}

cmd_issue() {
  need_pr "${1:-}" "${2:-}"
  local r=${3:-} title=${4:-} file=${5:-}
  [[ $r =~ ^[0-9]+$ ]] && [ -n "$title" ] && [ -f "$file" ] \
    || die "issue <repo> <n> <train_rounds> <title> <body-file> [<thread-id>…]"
  shift 5; me; [ -n "$ME" ] || die "could not read the operator's login"
  local first="Follow-up from #$PR (review train round $r)" list k tmp t failed=()
  # Dedupe on the REST issue list, not the search index (it lags new issues): a crash between
  # create and the judge comment must not open a second issue.
  list=$(ghx "repos/$REPO/issues?state=all&creator=$ME&sort=created&direction=desc&per_page=100" 2>&1) \
    || die "issue list: ${list:0:300}"
  k=$(jq -r --arg f "$first" '[.[] | select(.pull_request == null and ((.body // "") | startswith($f)))][0].number // empty' <<<"$list")
  if [ -z "$k" ]; then
    tmp=$(mktemp) && { printf '%s\n\n' "$first"; cat "$file"; } >"$tmp"
    k=$(ghx -X POST "repos/$REPO/issues" -f title="$title" -F body=@"$tmp" --jq .number 2>&1); local rc=$?
    rm -f "$tmp"; [ "$rc" = 0 ] && [[ $k =~ ^[0-9]+$ ]] || die "issue create: ${k:0:300}"
  fi
  # Reply only, never resolve: the thread becomes answered_open and stops counting.
  for t in "$@"; do reply_post "$t" "" "Tracked in #$k — out of scope for this PR." || failed+=("$t"); done
  # Re-run with only failed_threads: the issue is found again, the others aren't re-replied.
  jq -nc --argjson k "$k" --args '{ok:($ARGS.positional | length == 0), issue:$k, failed_threads:$ARGS.positional}' "${failed[@]}"
  [ ${#failed[@]} = 0 ]
}

cmd_post_summary() {
  need_pr "${1:-}" "${2:-}"; local f=${3:-}
  [ -f "$f" ] || die "post-summary <repo> <n> <file> [--ignore P]…: no such file: $f"
  shift 3; parse_flags "$@"
  [ "$(head -n1 "$f")" = "$SUMMARY_H" ] || die "first line must be exactly '$SUMMARY_H'"
  grep -q '<FILL\|SOURCE MATERIAL' "$f" && die "unfilled <FILL> slot or SOURCE MATERIAL block left in $f"
  hide_summaries || die "could not hide the earlier summaries: ${ERR:-}"
  local url; url=$(ghx -X POST "repos/$REPO/issues/$PR/comments" -F body=@"$f" --jq .html_url 2>&1) || die "post: ${url:0:300}"
  # Re-run the oracle: feedback that raced the convergence snapshot must be caught.
  local s; s=$(cmd_sync "$REPO" "$PR" --loop "${IGN[@]}")
  jq -c --arg u "$url" '{posted: $u, sync: .}' <<<"$s"
}

cmd_waive() {
  need_pr "${1:-}" "${2:-}"; local f=${3:-}; me
  [ -f "$f" ] || die "no such file: $f"
  [ "$(head -n1 "$f")" = "$WAIVE_H" ] || die "first line must be exactly '$WAIVE_H'"
  [ -n "$ME" ] || die "could not read the operator's login"
  local list id out how
  list=$(ghx --paginate "repos/$REPO/issues/$PR/comments" --jq '.[] | {id, u: (.user.login | ascii_downcase), b: (.body // "")[0:60]}' 2>&1) \
    || die "comments: ${list:0:300}"
  id=$(jq -rs --arg me "$ME" --arg h "$WAIVE_H" '[.[] | select(.u == $me and (.b | startswith($h)))] | last | .id // empty' <<<"$list")
  if [ -n "$id" ]; then
    out=$(ghx -X PATCH "repos/$REPO/issues/comments/$id" -F body=@"$f" --jq .html_url 2>&1) || die "update: ${out:0:300}"; how=updated
  else
    out=$(ghx -X POST "repos/$REPO/issues/$PR/comments" -F body=@"$f" --jq .html_url 2>&1) || die "post: ${out:0:300}"; how=created
  fi
  label_add review-waived fbca04 'Codex review loop waived; see Known limitations comment' || die "could not add review-waived"
  local probs=()   # the summary goes before the label, as in sync; a rerun retries both
  if hide_summaries; then label_rm review-converged || probs+=("could not remove review-converged")
  else probs+=("could not hide the convergence summary: ${ERR:-}"); fi
  label_rm review-blocked || probs+=("could not remove review-blocked")
  jq -nc --arg u "$out" --arg h "$how" --args '{ok: ($ARGS.positional | length == 0), comment:$h, url:$u}
    + (if ($ARGS.positional | length) > 0 then {problems: $ARGS.positional} else {} end)' "${probs[@]}"
  [ ${#probs[@]} = 0 ]
}

cmd_settle() {
  need_pr "${1:-}" "${2:-}"
  local st end=$(( $(date +%s) + 4800 ))   # ~80 min, wall clock
  export GH_RL_DEADLINE=$end                # background: rate limits may be slept out, not past it
  while [ "$(date +%s)" -lt "$end" ]; do
    st=$(bash "$STATE" "$REPO" "$PR")
    # Settled: CI finished, HEAD got a review or a converging signal, nothing in flight.
    jq -e '.action != "error" and .ci_pending == 0 and (.head_reviewed or ((.converged_by // "") != ""))
           and (.eyes_active | not) and ((.code_review.status // "") != "running")' >/dev/null 2>&1 <<<"$st" \
      && { jq -c '{settled: true} + .' <<<"$st"; return; }
    rl_interval 150 7 2
    [ $(( $(date +%s) + RL_INTERVAL )) -gt "$end" ] && break
    sleep "$RL_INTERVAL"
  done
  jq -c '{settled: false} + .' <<<"$st"
}

# ------------------------------------------------------------------ self-test
self_test() {
  local rc=0
  p() { # p <want-next> <want-ops csv> <label> <oracle-json> [labels-json] [loop]
    local got; got=$(jq -c --argjson labels "${5:-[]}" --argjson loop "${6:-false}" "$PLAN" <<<"$4" \
      | jq -r '.next + " " + (.ops | join(","))')
    if [ "$got" = "$1 $2" ]; then echo "ok   $3"; else echo "FAIL $3: got '$got', want '$1 $2'"; rc=1; fi
  }
  p waive   ""                                     "waived: no side effects at all"         '{"action":"address","waived":true,"judge_due":true}' '["review-converged"]' true
  p report  "label:review-converged"               "converged: add the label"               '{"action":"converged","waived":false,"judge_due":false}'
  p report  "unlabel:review-blocked"               "converged: drop blocked, keep label"    '{"action":"converged","waived":false,"judge_due":false}' '["review-converged","review-blocked"]'
  p report  "label:review-converged"               "converged outranks a due judge"         '{"action":"converged","waived":false,"judge_due":true}' '[]' true
  p address "hide,unlabel:review-converged"        "regression: hide summary, drop label"   '{"action":"address","waived":false,"judge_due":false}' '["review-converged"]'
  p address ""                                     "address on an unlabelled PR: nothing"   '{"action":"address","waived":false,"judge_due":false}'
  p judge   ""                                     "loop + judge due: hold the trigger"     '{"action":"trigger_review","waived":false,"judge_due":true}' '[]' true
  p wait    "trigger"                              "no --loop: judge_due is ignored"        '{"action":"trigger_review","waived":false,"judge_due":true}'
  p wait    "hide,unlabel:review-converged,trigger" "new HEAD on a converged PR"            '{"action":"trigger_review","waived":false,"judge_due":false}' '["review-converged"]'
  p wait    ""                                     "wait: nothing"                          '{"action":"wait","waived":false,"judge_due":false}'
  p blocked ""                                     "no_reviewer -> blocked"                 '{"action":"no_reviewer","waived":false,"judge_due":false}'
  p stop    ""                                     "closed -> stop"                         '{"action":"closed","waived":false,"judge_due":false}'
  p error   ""                                     "error, even on a waived PR"             '{"action":"error","waived":true}'
  p rate_limited ""                                "rate-limit error -> rate_limited"       '{"action":"error","error":"threads: rate limited (graphql, primary) until 2026-11-03T18:00:00Z"}'
  p error   ""                                     "label-read error keeps no ops"          '{"action":"error","oracle_action":"converged","error":"labels: HTTP 502"}' '[]' true
  p conflict ""                                    "conflict"                               '{"action":"conflict","waived":false,"judge_due":false}'

  # The oracle's marker parsing (mirror of pr-state.sh's `marker` jq) must read our formats back.
  mk() { jq -Rr '
    def marker: ascii_downcase | if test("^(## |> \\*\\*)") then sub("^(## |> \\*\\*)"; "") else "" end;
    marker | [ (if startswith("review train reset") then "reset" elif startswith("review train judge") then "judge" else "-" end),
               ((capture("^review train judge . round (?<n>[0-9]+)").n) // "0"),
               ((capture("^review train judge . round [0-9]+: (?<v>[a-z]+)").v) // "-") ] | join(" ")'; }
  e() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; rc=1; fi; }
  e "judge marker round+verdict"   "$(fmt_judge 10 continue 7 1 'shrinking' | mk)"           "judge 10 continue"
  e "ISSUE marker + issue suffix"  "$(fmt_judge 15 ISSUE 13 2 'one concern' 42 'retries' | mk)" "judge 15 issue"
  e "ISSUE suffix text"            "$(fmt_judge 15 ISSUE 13 2 'x' 42 'retries' | grep -o 'issue #42: retries$')" "issue #42: retries"
  e "reset marker"                 "$(printf '> **Review train reset** — add SSO' | mk)"      "reset 0 -"
  e "bad verdict rejected"         "$( (fmt_judge 5 MAYBE 1 0 x) | jq -r .ok)"                 "false"
  e "ISSUE without issue rejected" "$( (fmt_judge 5 ISSUE 1 0 x) | jq -r .ok)"                 "false"

  e "Fixed in \`sha\` parsed"       "$(fixed_sha 'Fixed in `b166d0d3`. Redacted.')" "b166d0d3"
  e "'Not fixed in' ignored"       "$(fixed_sha 'Not fixed in abc1234; leaving open')" ""
  e "last Fixed in wins"           "$(fixed_sha 'Fixed in 1111111, then fixed in 2222222')" "2222222"
  e "multi-line body"              "$(fixed_sha $'Thanks.\n\nFixed in abcdef1: moved it.')" "abcdef1"

  local body='**<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>  Redact tokens**

Text.

Useful? React with 👍 / 👎.

<!-- codex-code-review-finding:v1 -->'
  e "codex finding cleaned" "$(jq -nr --arg b "$body" --arg author x --arg me y "$CLEAN"' $b | clean')" "[P1] **Redact tokens**

Text."
  return $rc
}

case "${1:-}" in
  resolve|feedback|reply|push|sync|block|unblock|reset|judge|issue|waive|settle)
    c=$1; shift; "cmd_$c" "$@" ;;
  post-summary) shift; cmd_post_summary "$@" ;;
  --self-test) self_test ;;
  -h|--help|'') usage ;;
  *) usage >&2; exit 1 ;;
esac
