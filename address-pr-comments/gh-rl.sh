# shellcheck shell=bash disable=SC2034  # sourced; its globals are read by the sourcing script
# gh-rl.sh — rate-limit-aware GitHub access. Sourced (not run) by pr-state.sh, pr-ops.sh
# and pr-report.sh. `bash gh-rl.sh --self-test` asserts the pure parts.
#
# Why: one watcher polling every ~8s spent ~3000 REST + ~550 GraphQL points an hour (of
# 5000 each), so two loops plus everyday `gh` use exhausted a bucket. Four defences:
#   1. ghx: `gh api` with backoff, same stdout/stderr as gh api. Primary limit (bucket
#      empty) → sleep to that bucket's reset; secondary limit (too fast) → 60s, 120s, …
#      with jitter. All sleeping in a process shares one wall-clock deadline,
#      GH_RL_DEADLINE (epoch seconds; default now + GH_RL_MAX_WAIT, 75s). Foreground
#      commands set ~90s because the Bash tool times out at 120s; watchers set their own
#      deadline. GH_RL_NO_WAIT=1 fails at once — for GraphQL calls with a REST fallback,
#      and for writes whose caller must report before the tool timeout.
#   2. rl_interval: a watcher's poll interval spreads the budget left above a reserve
#      (PR_REVIEW_RESERVE_PCT, default 20% of the limit, kept for the agent's own writes)
#      over the time to reset; at the reserve it waits for the reset. /rate_limit is free.
#   3. etag_changed: conditional GETs. A 304 costs no rate limit, so a watcher can ask
#      "did anything move?" for free and skip the snapshot when nothing did.
#   4. GraphQL → REST fallback where REST can answer: CI (ci_rest stands in for
#      `gh pr checks`) and review threads (threads_rest). REST has no resolution state;
#      it comes from a per-PR cache refreshed by every GraphQL thread read, trusted only
#      while the thread's comment count is unchanged. A bare "Unresolve" click is still
#      invisible to REST, so pr-state.sh confirms a REST-derived `converged` over GraphQL
#      and reports `wait` when it can't.
# PR_REVIEW_FORCE_REST=1 forces the REST paths (testing).

for _v in GH_RL_MAX_WAIT GH_RL_DEADLINE PR_REVIEW_RESERVE_PCT; do   # they reach $((…))
  [ -z "${!_v:-}" ] || [[ ${!_v} =~ ^(0|[1-9][0-9]{0,9})$ ]] \
    || { jq -nc --arg e "$_v must be an integer" '{ok:false, action:"error", error:$e}'; exit 1; }
done
GH_RL_MAX_WAIT=${GH_RL_MAX_WAIT:-75}

# rl_kind <gh stderr> → primary | secondary | none. Stderr only: stdout can hold page text.
rl_kind() {
  local m=${1,,}
  if [[ $m == *"secondary rate limit"* || $m == *"abuse"* || $m == *"too quickly"* ]]; then echo secondary
  elif [[ $m == *"rate limit"* ]]; then echo primary
  elif [[ $m == *"http 429"* ]]; then echo secondary
  else echo none; fi
}

# rl_until <bucket> → " until <ISO reset>" (empty if unknown) — for error messages
rl_until() {
  local s i r; s=$(rl_status) || return 0
  case $1 in core) i=2 ;; graphql) i=5 ;; *) i=8 ;; esac
  r=$(cut -f"$i" <<<"$s"); [[ $r =~ ^[0-9]+$ ]] && printf ' until %s' "$(date -u -d "@$r" +%FT%TZ)"
}

# rl_status → "core_rem core_reset core_limit gql_rem gql_reset gql_limit search_rem search_reset"
rl_status() {
  timeout 30 gh api rate_limit --jq '.resources | [.core.remaining, .core.reset, .core.limit,
    .graphql.remaining, .graphql.reset, .graphql.limit, .search.remaining, .search.reset] | @tsv' 2>/dev/null
}

ghx() {
  local out err rc kind res=core delay=60 quick=1 w now rem reset ef a s end
  for a in "$@"; do   # the bucket follows the endpoint, never a -f value that mentions one
    [ "$a" = graphql ] && res=graphql
    [[ $a == search/* ]] && res=search
  done
  end=${GH_RL_DEADLINE:-$(( $(date +%s) + GH_RL_MAX_WAIT ))}
  ef=$(mktemp) || { echo "ghx: mktemp failed" >&2; return 1; }
  while :; do
    out=$(timeout 120 gh api "$@" 2>"$ef"); rc=$?
    err=$(<"$ef")
    kind=none; [ "$rc" != 0 ] && kind=$(rl_kind "$err")
    if [ "$kind" = none ] || [ -n "${GH_RL_NO_WAIT:-}" ]; then
      rm -f "$ef"
      [ -n "$out" ] && printf '%s\n' "$out"
      [ "$kind" != none ] && err="rate limited ($res, $kind)$(rl_until "$res"): $err"
      [ -n "$err" ] && printf '%s\n' "$err" >&2
      return "$rc"
    fi
    now=$(date +%s)
    if [ "$kind" = primary ]; then
      s=$(rl_status)
      case $res in
        core) read -r rem reset _ <<<"$s" ;;
        graphql) read -r _ _ _ rem reset _ <<<"$s" ;;
        search) read -r _ _ _ _ _ _ rem reset <<<"$s" ;;
      esac
      if [ -z "${reset:-}" ]; then   # /rate_limit unreadable: back off like a secondary limit
        w=$(( delay + RANDOM % 10 )); delay=$(( delay * 2 ))
      else w=$(( reset - now + 2 )); fi
      # Budget left yet still limited (the reset just passed, or a costly query): retry
      # quickly once, then treat it like a secondary limit.
      if [ "${rem:-0}" -gt 0 ] 2>/dev/null; then
        if [ "$quick" = 1 ]; then w=1 quick=0; else w=$(( delay + RANDOM % 10 )) delay=$(( delay * 2 )); fi
      fi
      [ "$w" -lt 1 ] && w=1
    else
      w=$(( delay + RANDOM % 10 )); delay=$(( delay * 2 ))
    fi
    if [ $(( now + w )) -gt "$end" ]; then
      rm -f "$ef"
      # The reset time leads the message: callers truncate errors from the front.
      printf 'rate limited (%s, %s) until %s: %s\n' "$res" "$kind" \
        "$(date -u -d "@$(( now + w ))" +%FT%TZ)" "$err" >&2
      return "$rc"
    fi
    sleep "$w"
  done
}

# rl_calc <base> <now> <pct> <rem reset limit cost>… → seconds (pure; see rl_interval)
rl_calc() {
  local i=$1 now=$2 pct=$3 rem rst lim cost left avail t; shift 3
  while [ $# -ge 4 ]; do
    rem=$1 rst=$2 lim=$3 cost=$4; shift 4
    [ "$cost" -gt 0 ] || continue
    left=$(( rst - now )); [ "$left" -lt 1 ] && left=1
    avail=$(( rem - lim * pct / 100 ))
    if [ "$avail" -lt "$cost" ]; then t=$(( left + 2 ))          # at the reserve: wait out the reset
    else t=$(( (left * cost + avail - 1) / avail )); fi            # spread the rest over the window
    [ "$t" -gt "$i" ] && i=$t
  done
  echo "$i"
}

# rl_interval <base> <core_cost> <gql_cost> → sets RL_INTERVAL (seconds) and GQL_LOW. Call it
# directly, not in $(…): the globals are the point. GQL_LOW=1 when the GraphQL bucket is at
# its reserve: snapshots then read threads and CI over REST (+4 core each, 0 GraphQL) and
# leave GraphQL to the writes that have no REST equivalent (resolve, minimize).
rl_interval() {
  local s cr crs cl gr grs gl pct=${PR_REVIEW_RESERVE_PCT:-20}
  RL_INTERVAL=$1 GQL_LOW=0
  s=$(rl_status) || return 0
  read -r cr crs cl gr grs gl _ <<<"$s"
  [ -n "${gl:-}" ] || return 0
  if [ "$gr" -le $(( gl * pct / 100 )) ]; then
    GQL_LOW=1
    RL_INTERVAL=$(rl_calc "$1" "$(date +%s)" "$pct" "$cr" "$crs" "$cl" $(( $2 + 4 )))
  else
    RL_INTERVAL=$(rl_calc "$1" "$(date +%s)" "$pct" "$cr" "$crs" "$cl" "$2" "$gr" "$grs" "$gl" "$3")
  fi
}

rest_preferred() { [ "${GQL_LOW:-0}" = 1 ] || [ "${PR_REVIEW_FORCE_REST:-}" = 1 ]; }

# etag_changed <path> → 0 if the resource changed since the ETag recorded in ETAGS (or is
# seen for the first time, or the request failed), 1 on 304 Not Modified. Records the new
# ETag. Call directly, not in $(…). A 304 costs no rate limit; gh exits 1 on it, so the
# status line decides, not the exit code.
declare -gA ETAGS=()
etag_changed() {
  local h st et args=(-i --silent)
  [ -n "${ETAGS[$1]:-}" ] && args+=(-H "If-None-Match: ${ETAGS[$1]}")
  h=$(timeout 30 gh api "${args[@]}" "$1" 2>/dev/null)
  st=$(head -n1 <<<"$h" | awk '{print $2}')
  [ "$st" = 304 ] && return 1
  et=$(grep -i '^etag:' <<<"$h" | head -n1 | cut -d' ' -f2- | tr -d '\r')
  if [ "$st" = 200 ] && [ -n "$et" ]; then ETAGS[$1]=$et; else unset 'ETAGS[$1]'; fi
  return 0
}

# ---------------------------------------------------------------- CI
CI_BUCKET='if .status != "completed" then "pending"
  elif .conclusion == "success" then "pass"
  elif .conclusion == "neutral" or .conclusion == "skipped" then "skipping"
  elif .conclusion == "cancelled" then "cancel"
  elif .conclusion == "stale" then "pending"
  else "fail" end'
STATUS_BUCKET='if .state == "success" then "pass" elif .state == "pending" then "pending" else "fail" end'

# ci_rest <repo> <sha> → [{name, bucket, link}], the same rows `gh pr checks` shows.
# Matched empirically against gh on 14 PRs (worker#195 forced the rules): GraphQL's
# statusCheckRollup drops Actions runs from events other than push / pull_request* /
# merge_group (Dependabot "dynamic", workflow_dispatch) and keeps the newest run per
# name + workflow + event. Non-Actions apps (Socket, Vercel) have no workflow run.
ci_rest() {
  local runs wf st
  runs=$(ghx --paginate "repos/$1/commits/$2/check-runs?per_page=100" --jq '.check_runs[]
    | {name, suite: .check_suite.id, app: .app.slug, at: (.started_at // ""), link: .html_url,
       bucket: ('"$CI_BUCKET"')}' 2>&1) || { echo "$runs"; return 1; }
  wf=$(ghx --paginate "repos/$1/actions/runs?head_sha=$2&per_page=100" \
    --jq '.workflow_runs[] | {suite: .check_suite_id, wf: .name, event}' 2>&1) || { echo "$wf"; return 1; }
  st=$(ghx --paginate "repos/$1/commits/$2/status?per_page=100" \
    --jq ".statuses[] | {name: .context, bucket: ($STATUS_BUCKET), link: .target_url}" 2>&1) || { echo "$st"; return 1; }
  jq -nc --slurpfile r <(printf '%s\n' "$runs") --slurpfile w <(printf '%s\n' "$wf") \
         --slurpfile s <(printf '%s\n' "$st") '
    ($w | map({key: (.suite | tostring), value: .}) | from_entries) as $wm
    | [ $r[] | . as $c | ($wm[$c.suite | tostring]) as $run
        | select($c.app != "github-actions" or ($run != null and
            ($run.event | test("^(push|pull_request|pull_request_target|pull_request_review|merge_group)$"))))
        | . + {key: [$c.name, ($run.wf // ""), ($run.event // "")]} ]
    | group_by(.key) | map(max_by(.at) | {name, bucket, link})
    | . + $s'
}

# ci_checks <repo> <pr> <head-sha> → sets CI_JSON ([{name, bucket, link}]) and CI_SRC
# (graphql|rest); returns 1 with the error in CI_JSON. Call directly, not in $(…).
# Any non-rate-limit gh failure ("no checks reported") reads as no checks, as it always has.
ci_checks() {
  local ef err
  CI_SRC=graphql
  if ! rest_preferred; then
    ef=$(mktemp) || { CI_JSON="mktemp failed"; return 1; }
    CI_JSON=$(timeout 120 gh pr checks "$2" --repo "$1" --json bucket,name,link 2>"$ef"); err=$(<"$ef"); rm -f "$ef"
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$CI_JSON" && return 0
    [ "$(rl_kind "$err")" = none ] && { CI_JSON='[]'; return 0; }
  fi
  CI_SRC=rest; CI_JSON=$(ci_rest "$1" "$3")
}

# ---------------------------------------------------------------- review threads
# Per-PR cache: "thread_id \t root_comment_id \t isResolved \t comment_count" per thread.
tcache_file() { echo "${XDG_CACHE_HOME:-$HOME/.cache}/pr-review/${1//\//_}_$2.tsv"; }
tcache_put() { # <repo> <pr>, lines on stdin
  local f; f=$(tcache_file "$1" "$2")
  mkdir -p "${f%/*}" && cat >"$f.$$" && mv -f "$f.$$" "$f"
}

# Thread shape shared by both paths (comments: the first, then the newest n):
#   {id, root, url, resolved, outdated, path, line, thumbs_down, count, comments: [{by, body}], last_by}
# threads_rest <repo> <pr> <n>: id (GraphQL node id) and resolved come from the cache —
# null / false when the thread isn't cached, and resolved only while the count is unchanged
# (a reply after the cached read may have reopened it).
threads_rest() {
  local cm f
  cm=$(ghx --paginate "repos/$1/pulls/$2/comments?per_page=100" --jq '.[] | {root: (.in_reply_to_id // .id),
        by: .user.login, at: .created_at, path, line: (.line // .original_line), body, url: .html_url,
        down: (.reactions["-1"] // 0)}' 2>&1) || { echo "$cm"; return 1; }
  f=$(tcache_file "$1" "$2"); [ -f "$f" ] || f=/dev/null
  printf '%s\n' "$cm" | jq -c -s --rawfile cache "$f" --argjson n "$3" '
    ($cache | split("\n") | map(split("\t") | select(length == 4)
      | {key: .[1], value: {id: .[0], resolved: (.[2] == "true"), count: (.[3] | tonumber? // -1)}})
      | from_entries) as $c
    | group_by(.root) | .[] | sort_by(.at) | (.[0].root | tostring) as $r | length as $len
    | {id: ($c[$r].id // null), root: .[0].root, url: .[0].url,
       resolved: (($c[$r].resolved // false) and ($c[$r].count == $len)),
       outdated: null, path: (.[0].path // ""), line: .[0].line, thumbs_down: .[0].down, count: $len,
       comments: ([.[0]] + .[([1, $len - $n] | max):] | map({by, body})), last_by: .[-1].by}'
}

# threads_read <repo> <pr> <n> → sets THREADS_JSON (one thread per line) and THREADS_SRC
# (graphql|rest); returns 1 with the error in THREADS_JSON. Call directly, not in $(…).
threads_read() {
  local out ef err rc
  THREADS_SRC=graphql
  if ! rest_preferred; then
    ef=$(mktemp) || { THREADS_JSON="mktemp failed"; return 1; }
    out=$(GH_RL_NO_WAIT=1 ghx graphql --paginate -f query='
      query($owner:String!,$repo:String!,$number:Int!,$n:Int!,$endCursor:String){
        repository(owner:$owner,name:$repo){ pullRequest(number:$number){
          reviewThreads(first:50, after:$endCursor){ pageInfo{ hasNextPage endCursor }
            nodes{ id isResolved isOutdated path line originalLine
              head: comments(first:1){ nodes{ databaseId url author{ login } body
                                              reactions(content:THUMBS_DOWN){ totalCount } } }
              tail: comments(last:$n){ totalCount nodes{ databaseId author{ login } body } } } } } } }' \
      -F owner="${1%%/*}" -F repo="${1##*/}" -F number="$2" -F n="$3" \
      --jq '.data.repository.pullRequest.reviewThreads.nodes[] | (.head.nodes[0] // {}) as $h
        | {id, root: $h.databaseId, url: ($h.url // null), resolved: .isResolved, outdated: .isOutdated,
           path: (.path // ""), line: (.line // .originalLine), thumbs_down: ($h.reactions.totalCount // 0),
           count: .tail.totalCount,
           comments: ([$h] + [.tail.nodes[] | select(.databaseId != $h.databaseId)]
                      | map({by: (.author.login // ""), body: (.body // "")})),
           last_by: (.tail.nodes[-1].author.login // "")}' 2>"$ef"); rc=$?
    err=$(<"$ef"); rm -f "$ef"
    if [ "$rc" = 0 ]; then
      THREADS_JSON=$out
      jq -r '[.id, (.root | tostring), (.resolved | tostring), (.count | tostring)] | @tsv' <<<"$out" \
        | tcache_put "$1" "$2" || true
      return 0
    fi
    [ "$(rl_kind "$err")" = none ] && { THREADS_JSON=$err; return 1; }
  fi
  THREADS_SRC=rest
  THREADS_JSON=$(threads_rest "$1" "$2" "$3")
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --self-test ]; then
  rc=0
  e() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; rc=1; fi; }
  e "primary (REST)"     "$(rl_kind 'gh: API rate limit exceeded for user ID 1. (HTTP 403)')" primary
  e "primary (GraphQL)"  "$(rl_kind 'GraphQL: API rate limit already exceeded for user ID 1.')" primary
  e "secondary"          "$(rl_kind 'You have exceeded a secondary rate limit. (HTTP 403)')" secondary
  e "429 is secondary"   "$(rl_kind 'gh: Too Many Requests (HTTP 429)')" secondary
  e "other errors"       "$(rl_kind 'gh: Not Found (HTTP 404)')" none
  # rl_calc base now pct  rem reset limit cost …   (now=0; reserve 20% of 5000 = 1000)
  e "full budget: ~base"                "$(rl_calc 5 0 20  4900 3600 5000 8)" 8   # 3600*8/3900 → 8
  e "half budget: slower"               "$(rl_calc 5 0 20  2000 3600 5000 8)" 29
  e "near reserve: much slower"         "$(rl_calc 5 0 20  1100 3600 5000 8)" 288
  e "at reserve: wait for the reset"    "$(rl_calc 5 0 20  1000 1200 5000 8)" 1202
  e "the scarcer bucket decides"        "$(rl_calc 5 0 20  4900 3600 5000 8  1500 600 5000 1)" 8
  e "graphql at reserve decides"        "$(rl_calc 5 0 20  4900 3600 5000 8   900 600 5000 1)" 602
  e "cost 0 is ignored"                 "$(rl_calc 5 0 20  4900 3600 5000 8     0 600 5000 0)" 8
  e "base floor"                        "$(rl_calc 30 0 20 4900 3600 5000 8)" 30
  b() { jq -nr --argjson r "$1" "\$r | $CI_BUCKET"; }
  e "in_progress → pending"  "$(b '{"status":"in_progress","conclusion":null}')" pending
  e "success → pass"         "$(b '{"status":"completed","conclusion":"success"}')" pass
  e "skipped → skipping"     "$(b '{"status":"completed","conclusion":"skipped"}')" skipping
  e "cancelled → cancel"     "$(b '{"status":"completed","conclusion":"cancelled"}')" cancel
  e "timed_out → fail"       "$(b '{"status":"completed","conclusion":"timed_out"}')" fail
  e "action_required → fail" "$(b '{"status":"completed","conclusion":"action_required"}')" fail
  # threads_rest's resolution rule, offline: a cached resolved=true counts only at the same count
  trs() { printf '%s\n' "$2" | jq -c -s --rawfile cache <(printf '%s' "$1") --argjson n 1 '
    ($cache | split("\n") | map(split("\t") | select(length == 4)
      | {key: .[1], value: {resolved: (.[2] == "true"), count: (.[3] | tonumber? // -1)}}) | from_entries) as $c
    | group_by(.root) | .[] | (.[0].root | tostring) as $r | length as $len
    | (($c[$r].resolved // false) and ($c[$r].count == $len))' ; }
  c1='{"root":7,"at":"1"}'; c2='{"root":7,"at":"2"}'
  e "cached resolved, same count → resolved"   "$(trs $'T\t7\ttrue\t2' "$c1"$'\n'"$c2")" true
  e "a reply since the cache → unresolved"      "$(trs $'T\t7\ttrue\t1' "$c1"$'\n'"$c2")" false
  e "uncached → unresolved"                     "$(trs '' "$c1")" false
  e "old 3-column cache → unresolved"           "$(trs $'T\t7\ttrue' "$c1")" false

  # ghx against a fake gh (offline): what gets retried, how often, and for how long.
  td=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/testdata
  fk=$(mktemp -d); trap 'rm -rf "$fk"' EXIT
  cp "$td/fake-gh" "$fk/gh" && chmod +x "$fk/gh"; export FAKE_LOG="$fk/log"; PATH="$fk:$PATH"
  calls() { grep -c . "$FAKE_LOG"; }; now=$(date +%s)
  : >"$FAKE_LOG"; export FAKE_MODE=page502
  GH_RL_MAX_WAIT=6 ghx --paginate repos/o/r/issues/1/comments >/dev/null 2>&1
  e "ghx: a 502 whose page text says 'rate limit' is not retried" "$(calls)" 1
  : >"$FAKE_LOG"; export FAKE_MODE=primary FAKE_RL="5	$((now+3))	5000	5000	$((now+3))	5000	30	$((now+3))"
  err=$(GH_RL_MAX_WAIT=6 ghx repos/o/r/pulls/1 2>&1 >/dev/null)
  e "ghx: limited with budget left → one quick retry, then gives up" "$(calls)" 2
  e "ghx: the reset time leads the error" "${err:0:22}" "rate limited (core, pr"
  : >"$FAKE_LOG"; export FAKE_RL="0	$((now+300))	5000	5000	$((now+300))	5000	30	$((now+300))"
  t0=$(date +%s); GH_RL_DEADLINE=$((now+5)) ghx repos/o/r/pulls/1 >/dev/null 2>&1
  e "ghx: reset past the deadline → fails at once" "$(( $(date +%s) - t0 <= 2 ))" 1
  err=$(GH_RL_MAX_WAIT=0 ghx -X POST repos/o/r/issues/1/comments -f body="mentions graphql here" 2>&1 >/dev/null)
  e "ghx: the bucket follows the endpoint, not a -f value" "${err:0:18}" "rate limited (core"
  exit $rc
fi
