#!/usr/bin/env bash
# pr-state.sh — deterministic PR review-state oracle + watcher.
#
#   pr-state.sh <owner/repo> <pr>            snapshot: print state JSON, exit
#   pr-state.sh <owner/repo> <pr> --wait     block until state is actionable, then exit
#
# Options:
#   --wait                  poll until action != wait (or the state fingerprint moves)
#   --interval N            poll seconds (default 5; a snapshot itself takes a few seconds
#                           of API calls, so effective cadence is snapshot time + 5s)
#   --timeout N             give up waiting after N seconds (default 1800 = 30 min; the
#                           caller re-checks and re-queues while the wait is legitimate —
#                           some reviews take hours)
#   --bot LOGIN             review bot, case-insensitive, [bot] suffix optional
#                           (default chatgpt-codex-connector)
#   --ignore SUBSTR         thread to never count as actionable; repeatable (loop's
#                           --leave-open); empty/whitespace-only phrases are rejected —
#                           contains("") matches every thread
#   --grace N               don't ask for a review until HEAD is N seconds old (default 900;
#                           observed bot latency is 6–40 min, 180s just double-queued reviews)
#   --retrigger-after N     re-post the review request if unanswered this long; also the
#                           quiet window before nudging a reviewed-but-un-👍'd HEAD (default 1800)
#   --eyes-ttl N            a 👀 older than this no longer blocks the trigger (default 3600;
#                           a stray 👀 otherwise livelocks the loop forever)
#   --limit-ttl N           after the bot replies "reached your Codex usage limits", hold
#                           (wait) this long before asking again (default 3600). Limit and
#                           error replies count as the bot being present, so they never
#                           trip the bot-never-engaged no_reviewer stop; three unanswered
#                           requests on one HEAD still stop the loop if limits persist.
#   --self-test             run the decision-table asserts and exit
#
# Always prints one JSON object on stdout, on every exit path. `.action` is the decision:
#   address | conflict | trigger_review | converged | no_reviewer | wait | closed | timeout
#   | killed | error
# Exit: 0 actionable, 10 timeout, 1 usage/API error, 128+n killed by signal n.
#
# Thread classification (empirically derived):
#   unresolved + last speaker is the reviewer side (bot, or a human who is not the PR
#   author/operator) = actionable. unresolved + last speaker is the author side = the
#   deliberate "answered, left open for a human" convention — reported as answered_open,
#   never actionable. Codex review bodies are always ~621 chars of boilerplate; findings
#   live in inline comments, so the body counts only after stripping the known template.
#   A clean pass is a 👍 reaction or a "Didn't find any major issues" comment — there is
#   no such thing as a clean review object.
#
# Requires bash 4+ and GNU date (Linux). Not portable to stock macOS bash/BSD date.
#
# Known limitations (deliberate):
#   - HEAD age uses the commit's committer date, not push time: pushing a pre-built commit
#     ages it instantly past --grace and can make an old 👍 look fresh. Rare; accepted.
#   - `gh pr checks` failures (auth loss, no checks configured) read as "no checks";
#     CI gating then rests on the review channels alone. A converging signal with CI
#     stuck pending waits forever here — the loop's ~4h same-reason escalation is the cap.
#   - Review-body scanning covers the bot's LAST review only; an earlier substantive body
#     on the same HEAD, or a human's body-only COMMENTED review, is not oracle-visible
#     (the address skill's step 2B still reads all bodies during a round).
#   - Reviewer-side top-level issue comments never drive `address` (they no longer clear
#     feedback either); they get triaged when a round runs for another reason.
#   - The author-side answer clock counts issue comments only: a human CR answered solely
#     via inline thread replies stays `address` until the loop's no-progress stop ends it.
#   - Concurrency: one loop per PR is assumed. The task-list check in the loop skill is
#     advisory, not an atomic lease — don't run two sessions against the same PR.

set -uo pipefail

BOT=chatgpt-codex-connector
INTERVAL=5 TIMEOUT=1800 GRACE=900 RETRIGGER=1800 EYES_TTL=3600 LIMIT_TTL=3600 WAIT=0
IGNORE=()
REPO='' PRNUM=''

die() { jq -nc --arg e "$1" '{action:"error",error:$e}'; exit 1; }
# All timing flags feed $((…)) and sleep — validate as bounded base-10 integers so a
# crafted value can't execute inside bash arithmetic, a leading zero can't become octal,
# and a typo can't hot-poll GitHub. Callers assign via $((10#$2)).
num() { [[ ${1:-} =~ ^[0-9]{1,9}$ ]] || die "expected an integer (1-9 digits), got: ${1:-<missing>}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --wait) WAIT=1 ;;
    --interval) num "${2:-}"; INTERVAL=$((10#$2)); [ "$INTERVAL" -ge 1 ] || die "interval must be >= 1"; shift ;;
    --timeout) num "${2:-}"; TIMEOUT=$((10#$2)); shift ;;
    --bot) [ -n "${2:-}" ] || die "missing --bot value"; BOT=${2,,}; BOT=${BOT%\[bot\]}; shift ;;
    --ignore) [ -n "${2:-}" ] && [ -n "${2//[[:space:]]/}" ] || die "empty --ignore phrase would mute every thread"
              IGNORE+=("$2"); shift ;;
    --grace) num "${2:-}"; GRACE=$((10#$2)); shift ;;
    --retrigger-after) num "${2:-}"; RETRIGGER=$((10#$2)); shift ;;
    --eyes-ttl) num "${2:-}"; EYES_TTL=$((10#$2)); shift ;;
    --limit-ttl) num "${2:-}"; LIMIT_TTL=$((10#$2)); shift ;;
    --self-test) SELFTEST=1 ;;
    -*) die "unknown option: $1" ;;
    *) if [ -z "$REPO" ]; then REPO=$1; elif [ -z "$PRNUM" ]; then PRNUM=$1; else die "extra arg: $1"; fi ;;
  esac
  shift
done

# ---------------------------------------------------------------- decision
# Pure function over the globals below, so --self-test can drive it directly.
#   PR_OPEN HEAD_SHA HEAD_AT REVIEWED_SHA REVIEWED_AT EYES_AT THUMBS_AT THUMBS_BY CLEAN_AT
#   APPROVED_AT HUMAN_CR_AT LAST_REPLY_AT TRIGGER_AT TRIGGER_COUNT BOT_SEEN
#   ACTIONABLE BODY_PENDING CI_FAIL CI_PENDING MERGEABLE NOW
decide() {
  EYES_ACTIVE=0
  [ "$EYES_AT" -gt 0 ] && [ "$EYES_AT" -gt "$REVIEWED_AT" ] && [ $((NOW - EYES_AT)) -lt "$EYES_TTL" ] && EYES_ACTIVE=1
  # A 👍 older than HEAD approved an older commit — it does not converge this HEAD.
  THUMBS_FRESH=0; [ "$THUMBS_AT" -gt "$HEAD_AT" ] && THUMBS_FRESH=1
  CONVERGED_BY=''
  if   [ "$THUMBS_FRESH" = 1 ];           then CONVERGED_BY="fresh 👍 (${THUMBS_BY:-bot})"
  elif [ "$CLEAN_AT" -gt "$HEAD_AT" ];    then CONVERGED_BY="bot replied: no major issues"
  elif [ "$APPROVED_AT" -gt "$HEAD_AT" ]; then CONVERGED_BY="human approval"
  fi
  TRIGGER_PENDING=0
  [ "$TRIGGER_AT" -gt "$REVIEWED_AT" ] && [ "$TRIGGER_AT" -ge "$HEAD_AT" ] && TRIGGER_PENDING=1
  local quiet=$REVIEWED_AT; [ "$LAST_REPLY_AT" -gt "$quiet" ] && quiet=$LAST_REPLY_AT
  # A request only counts as "dead" once it has had its full answer window.
  local trigger_stale=0
  [ "$TRIGGER_AT" -gt 0 ] && [ $((NOW - TRIGGER_AT)) -ge "$RETRIGGER" ] && trigger_stale=1

  if [ "$PR_OPEN" != 1 ];              then ACTION=closed;   REASON="PR is not open"
  elif [ "$MERGEABLE" = CONFLICTING ]; then ACTION=conflict; REASON="branch conflicts with base"
  elif [ "$CI_FAIL" -gt 0 ];           then ACTION=address;  REASON="$CI_FAIL failing/canceled check(s)"
  elif [ "$ACTIONABLE" -gt 0 ];        then ACTION=address;  REASON="$ACTIONABLE open thread(s) await a fix or reply"
  elif [ "$BODY_PENDING" = 1 ];        then ACTION=address;  REASON="review body carries unanswered feedback"
  elif [ "$HUMAN_CR_AT" -gt 0 ] && [ "$HUMAN_CR_AT" -gt "$LAST_REPLY_AT" ]; then
       ACTION=address; REASON="a human requested changes and nobody has answered"
  elif [ -n "$CONVERGED_BY" ] && [ "$CI_PENDING" -gt 0 ]; then
       ACTION=wait; REASON="$CONVERGED_BY, but $CI_PENDING check(s) still running"
  elif [ -n "$CONVERGED_BY" ] && [ "$MERGEABLE" = UNKNOWN ]; then
       ACTION=wait; REASON="$CONVERGED_BY, but mergeability still computing"
  elif [ -n "$CONVERGED_BY" ];         then ACTION=converged; REASON="$CONVERGED_BY newer than HEAD, CI done, nothing open"
  elif [ "$LIMIT_AT" -gt "$TRIGGER_AT" ] && [ "$LIMIT_AT" -gt "$REVIEWED_AT" ] && [ $((NOW - LIMIT_AT)) -lt "$LIMIT_TTL" ]; then
       ACTION=wait; REASON="bot hit its usage limit $((NOW - LIMIT_AT))s ago — holding ${LIMIT_TTL}s before asking again"
  # An active 👀 is a RELIABLE in-flight marker — it outranks the no_reviewer stops: a
  # reviewer that finally starts after 3 aged requests must not be declared absent.
  elif [ "$EYES_ACTIVE" = 1 ];         then ACTION=wait; REASON="👀 newer than last review — review in flight"
  elif [ "$BOT_SEEN" = 0 ] && [ "$TRIGGER_COUNT" -ge 2 ] && [ "$trigger_stale" = 1 ]; then
       ACTION=no_reviewer; REASON="$TRIGGER_COUNT review requests and the bot has never touched this PR"
  elif [ "$TRIGGER_PENDING" = 1 ] && [ "$TRIGGERS_HEAD" -ge 3 ] && [ "$trigger_stale" = 1 ]; then
       ACTION=no_reviewer; REASON="reviewer unresponsive: $TRIGGERS_HEAD requests on this HEAD unanswered"
  elif [ "$TRIGGER_PENDING" = 1 ] && [ $((NOW - TRIGGER_AT)) -lt "$RETRIGGER" ]; then
       ACTION=wait; REASON="review requested $((NOW - TRIGGER_AT))s ago, unanswered"
  elif [ "$REVIEWED_SHA" = "$HEAD_SHA" ] && [ $((NOW - quiet)) -lt "$RETRIGGER" ]; then
       ACTION=wait; REASON="HEAD reviewed, nothing open; waiting for the bot's 👍"
  elif [ $((NOW - HEAD_AT)) -lt "$GRACE" ]; then ACTION=wait; REASON="HEAD is $((NOW - HEAD_AT))s old, grace ${GRACE}s"
  else ACTION=trigger_review; REASON="HEAD needs a review pass and nobody is on it"
  fi
}

if [ -n "${SELFTEST:-}" ]; then
  t() { # t <expected> <label> — globals already set by caller
    decide
    if [ "$ACTION" = "$1" ]; then echo "ok   $2"; else echo "FAIL $2: got $ACTION ($REASON), want $1"; RC=1; fi
  }
  RC=0; GRACE=900 RETRIGGER=1800 EYES_TTL=3600 LIMIT_TTL=3600   # asserts assume the defaults
  NOW=1000000; PR_OPEN=1 MERGEABLE=MERGEABLE CI_FAIL=0 CI_PENDING=0
  ACTIONABLE=0 BODY_PENDING=0 HUMAN_CR_AT=0 LAST_REPLY_AT=0
  HEAD_SHA=aaa HEAD_AT=$((NOW-1200)) REVIEWED_SHA='' REVIEWED_AT=0
  EYES_AT=0 THUMBS_AT=0 THUMBS_BY='' CLEAN_AT=0 APPROVED_AT=0 LIMIT_AT=0
  TRIGGER_AT=0 TRIGGER_COUNT=0 TRIGGERS_HEAD=0 BOT_SEEN=1
  t trigger_review "fresh PR, no review, no eyes -> trigger"
  EYES_AT=$((NOW-60));                t wait "eyes with no review yet (fresh-PR auto-review) -> wait"
  REVIEWED_SHA=old REVIEWED_AT=$((NOW-30)); t trigger_review "eyes OLDER than last review is stale -> trigger"
  EYES_AT=$((NOW-10));                t wait "eyes NEWER than last review -> in flight"
  EYES_AT=$((NOW-4000)); REVIEWED_AT=$((NOW-5000))
                                      t trigger_review "eyes past --eyes-ttl no longer blocks -> trigger"
  EYES_AT=0; REVIEWED_AT=$((NOW-3000)); TRIGGER_AT=$((NOW-60)); TRIGGER_COUNT=1
                                      t wait "trigger already posted for this HEAD -> wait"
  HEAD_AT=$((NOW-4000)); REVIEWED_AT=$((NOW-3900)); TRIGGER_AT=$((NOW-2000))
                                      t trigger_review "trigger unanswered past --retrigger-after -> re-post"
  TRIGGER_AT=0 TRIGGER_COUNT=0; REVIEWED_AT=$((NOW-30)); HEAD_AT=$((NOW-300))
                                      t wait "HEAD younger than grace -> wait"
  HEAD_AT=$((NOW-1200)); REVIEWED_SHA=aaa REVIEWED_AT=$((NOW-600))
                                      t wait "HEAD reviewed, quiet window fresh -> wait for 👍"
  REVIEWED_AT=$((NOW-2500));          t trigger_review "reviewed HEAD quiet past --retrigger-after -> nudge"
  REVIEWED_AT=$((NOW-600)); THUMBS_AT=$((NOW-1500))
                                      t wait "👍 OLDER than HEAD is stale -> does not converge"
  THUMBS_AT=$((NOW-100)); THUMBS_BY=bot; t converged "👍 newer than HEAD -> converged"
  CI_PENDING=1;                       t wait "👍 but CI still running -> wait, not converged"
  CI_PENDING=0 CI_FAIL=1;             t address "failing CI outranks a 👍"
  CI_FAIL=0; ACTIONABLE=2;            t address "actionable threads outrank a 👍"
  ACTIONABLE=0; BODY_PENDING=1;       t address "unanswered review body outranks a 👍"
  BODY_PENDING=0; HUMAN_CR_AT=$((NOW-50)); t address "human CHANGES_REQUESTED unanswered -> address"
  LAST_REPLY_AT=$((NOW-40));          t converged "human CR answered, 👍 fresh -> converged"
  THUMBS_AT=0 THUMBS_BY='' HUMAN_CR_AT=0 LAST_REPLY_AT=0
  APPROVED_AT=$((NOW-100));           t converged "human GitHub approval newer than HEAD -> converged"
  APPROVED_AT=0; CLEAN_AT=$((NOW-100)); t converged "bot 'no major issues' comment -> converged"
  MERGEABLE=UNKNOWN;                  t wait "converging signal while mergeability UNKNOWN -> wait, not converged"
  MERGEABLE=MERGEABLE CLEAN_AT=0
  BOT_SEEN=0 TRIGGER_COUNT=2 TRIGGERS_HEAD=2 TRIGGER_AT=$((NOW-2000)) REVIEWED_SHA='' REVIEWED_AT=0
                                      t no_reviewer "2 STALE triggers, bot never engaged -> no_reviewer"
  TRIGGER_AT=$((NOW-60));             t wait "2nd trigger still fresh -> wait, not no_reviewer"
  BOT_SEEN=1 TRIGGER_COUNT=3 TRIGGERS_HEAD=3 TRIGGER_AT=$((NOW-2000))
  HEAD_AT=$((NOW-9000)) REVIEWED_SHA=old REVIEWED_AT=$((NOW-8000))
                                      t no_reviewer "3 unanswered requests on this HEAD -> reviewer unresponsive"
  EYES_AT=$((NOW-60));                t wait "fresh 👀 outranks the unresponsive stop -> review in flight"
  EYES_AT=0
  TRIGGERS_HEAD=1 TRIGGER_COUNT=1 TRIGGER_AT=$((NOW-2000)) LIMIT_AT=$((NOW-300))
                                      t wait "bot replied 'usage limit' after the request -> hold, don't re-ask"
  LIMIT_AT=$((NOW-4000)) TRIGGER_AT=$((NOW-5000))
                                      t trigger_review "usage-limit hold expired -> ask again"
  TRIGGERS_HEAD=0 TRIGGER_COUNT=0 TRIGGER_AT=0 LIMIT_AT=0 HEAD_AT=$((NOW-1200)) REVIEWED_SHA='' REVIEWED_AT=0
  MERGEABLE=CONFLICTING;              t conflict "conflict outranks everything but a closed PR"
  PR_OPEN=0;                          t closed "closed PR -> stop"
  exit $RC
fi

# ---------------------------------------------------------------- snapshot
[ -n "$REPO" ] && [ -n "$PRNUM" ] || die "usage: pr-state.sh <owner/repo> <pr> [--wait]"
[[ $REPO == */* ]] || die "repo must be owner/name, got: $REPO"
[[ $PRNUM =~ ^[0-9]+$ ]] || die "pr must be a number, got: $PRNUM"
[[ $BOT =~ ^[A-Za-z0-9._-]+$ ]] || die "bad --bot: $BOT"
OWNER=${REPO%%/*}; NAME=${REPO##*/}

# --------------------------------------------------------------- wait audit
# Background watchers get reaped without a word: the harness only records
# "[killed]" in the task file, and no exit code survives. So --wait journals its
# own lifecycle. SIGKILL cannot be trapped -- a `start` line with no matching
# `exit` line IS the SIGKILL record (harness reap or OOM); a `signal` line names
# a catchable killer. Override the path with $PR_STATE_LOG.
if [ "$WAIT" = 1 ]; then
  WLOG=${PR_STATE_LOG:-$HOME/.pr-state-wait.log}
  wlog() { printf '%s %-6s pid=%-7d ppid=%-7d %s#%s %s\n' \
    "$(date -Is)" "$1" "$$" "$PPID" "$REPO" "$PRNUM" "${2-}" >>"$WLOG" 2>/dev/null || :; }
  trap 'wlog exit "rc=$? reparented=$([ "$PPID" = 1 ] && echo yes || echo no)"' EXIT
  # A killed watcher used to leave an empty task file and the caller guessing.
  # Say so on stdout instead, so the wake carries its own reason.
  wdie() {
    wlog signal "SIG$1"
    [ "${EMITTED:-0}" = 1 ] || jq -nc --arg repo "$REPO" --argjson pr "$PRNUM" --arg s "$1" \
      '{repo:$repo, pr:$pr, action:"killed", reason:"SIG\($s) — watcher terminated externally, not a state change"}'
    exit "$2"
  }
  trap 'wdie HUP  129' HUP
  trap 'wdie INT  130' INT
  trap 'wdie TERM 143' TERM
  wlog start "timeout=${TIMEOUT}s parent=$(tr '\0\n' '  ' </proc/$PPID/cmdline 2>/dev/null | cut -c1-50)"
fi

command -v jq >/dev/null || die "jq not found"
IGNORE_JSON=$( [ ${#IGNORE[@]} -eq 0 ] && echo '[]' || printf '%s\n' "${IGNORE[@]}" | jq -Rc 'ascii_downcase' | jq -sc . )

epoch() { [ -n "${1:-}" ] && [ "$1" != null ] && date -d "$1" +%s 2>/dev/null || echo 0; }

# api <args...> — echoes combined output; caller checks rc and uses the output as ERRMSG.
# (Do NOT bump failure counters in here: every call site is a $(…) subshell.)
# `timeout 120` bounds a hung gh call so --wait can honor its deadline.
api() { timeout 120 gh api "$@" 2>&1; }

# The operator account counts as the author side when classifying who spoke last.
ME=$(gh api user --jq '.login' 2>/dev/null | tr '[:upper:]' '[:lower:]') || ME=''

snapshot() {
  ERRMSG=''; local pr reviews reactions comments threads checks cdate
  pr=$(api "repos/$REPO/pulls/$PRNUM") || { ERRMSG="pulls/$PRNUM: ${pr:0:200}"; return 1; }
  PR_OPEN=$(jq -r 'if .state=="open" then 1 else 0 end' <<<"$pr")
  HEAD_SHA=$(jq -r .head.sha <<<"$pr")
  AUTHOR=$(jq -r '.user.login|ascii_downcase|rtrimstr("[bot]")' <<<"$pr")
  case "$(jq -r .mergeable_state <<<"$pr")" in
    dirty) MERGEABLE=CONFLICTING ;; unknown) MERGEABLE=UNKNOWN ;; *) MERGEABLE=MERGEABLE ;;
  esac
  cdate=$(api "repos/$REPO/commits/$HEAD_SHA" --jq '.commit.committer.date') \
    || { ERRMSG="commits/${HEAD_SHA:0:7}: ${cdate:0:200}"; return 1; }
  HEAD_AT=$(epoch "$cdate")
  # HEAD_AT=0 would make every historical 👍 "fresh" -> false converged. Never proceed on it.
  [ "$HEAD_AT" -gt 0 ] || { ERRMSG="unparsable committer date: ${cdate:0:100}"; return 1; }

  # ALL reviews (paginated). Bot rows drive REVIEWED_*; non-bot rows drive human
  # approval/CR. Body length is measured AFTER stripping the known Codex template —
  # the raw body is ~621 chars of boilerplate whether there are 0 or 19 findings.
  reviews=$(api --paginate "repos/$REPO/pulls/$PRNUM/reviews" --jq \
    '.[] | [ (.user.login|ascii_downcase|rtrimstr("[bot]")),
             (.user.login|test("\\[bot\\]$")|tostring),
             .state, (.commit_id // ""), (.submitted_at // ""),
             ( (.body // "")
               | gsub("<details>[\\s\\S]*</details>"; "")
               | gsub("### 💡 Codex[^\n]*Review"; "")
               | gsub("Here are some automated[^\n]*review suggestions for this pull request."; "")
               | gsub("\\*\\*Reviewed commit:\\*\\*[^\n]*"; "")
               | gsub("\\s"; "") | length ) ] | @tsv') \
    || { ERRMSG="reviews: ${reviews:0:200}"; return 1; }
  local bot_rows last
  bot_rows=$(awk -F'\t' -v b="$BOT" '$1==b' <<<"$reviews")
  last=$(tail -n1 <<<"$bot_rows")
  REVIEWED_SHA=$(cut -f4 <<<"$last"); REVIEWED_AT=$(epoch "$(cut -f5 <<<"$last")")
  local head_body=0
  [ -n "$last" ] && [ "$REVIEWED_SHA" = "$HEAD_SHA" ] && [ "$(cut -f6 <<<"$last")" -gt 50 ] 2>/dev/null && head_body=1
  BOT_REVIEWS=$(grep -c . <<<"$bot_rows")
  # Human review state reduces PER REVIEWER to their latest approve/CR (a dismissed CR
  # reads as DISMISSED and drops out). Any reviewer whose latest state is
  # CHANGES_REQUESTED blocks; approvals converge only when no CR is outstanding —
  # Bob's approve must not clear Alice's open request.
  local human_states
  human_states=$(awk -F'\t' '$2=="false" && ($3=="APPROVED" || $3=="CHANGES_REQUESTED"){s[$1]=$3; t[$1]=$5}
                             END{for (l in s) print s[l] "\t" t[l]}' <<<"$reviews")
  HUMAN_CR_AT=$(epoch "$(awk -F'\t' '$1=="CHANGES_REQUESTED"{print $2}' <<<"$human_states" | sort | tail -n1)")
  APPROVED_AT=0
  [ "$HUMAN_CR_AT" -eq 0 ] && APPROVED_AT=$(epoch "$(awk -F'\t' '$1=="APPROVED"{print $2}' <<<"$human_states" | sort | tail -n1)")

  reactions=$(api --paginate "repos/$REPO/issues/$PRNUM/reactions" --jq \
    '.[] | [.content, (.user.login|ascii_downcase|rtrimstr("[bot]")), (.user.login|test("\\[bot\\]$")|tostring), .created_at] | @tsv') \
    || { ERRMSG="reactions: ${reactions:0:200}"; return 1; }
  # 👀 from anyone (a human looking is also a reason not to summon the bot) — but TTL'd in decide().
  EYES_AT=$(epoch "$(awk -F'\t' '$1=="eyes"{print $4}' <<<"$reactions" | sort | tail -n1)")
  # 👍 that converges: the review bot, or any non-bot account. Other [bot]s are noise.
  local tb; tb=$(awk -F'\t' -v b="$BOT" '$1=="+1" && ($2==b || $3=="false"){print $4"\t"$2}' <<<"$reactions" | sort | tail -n1)
  THUMBS_AT=$(epoch "${tb%%$'\t'*}"); THUMBS_BY=${tb#*$'\t'}
  local bot_reactions; bot_reactions=$(awk -F'\t' -v b="$BOT" '$2==b' <<<"$reactions" | grep -c .)

  # Issue comments. A trigger is a NON-bot comment that IS the command (anchored) — a
  # prose mention of "@codex review" (reports, quotes, the bot's own boilerplate) is not
  # a trigger. The clean "no major issues" reply is the bot's converge signal on manual
  # triggers. LAST_REPLY_AT is the AUTHOR side answering feedback — a reviewer's comment
  # or a trigger must never count as an answer.
  local bot_re=${BOT//./\\.}
  comments=$(api --paginate "repos/$REPO/issues/$PRNUM/comments" --jq \
    '.[] | [ ((.body // "")|ascii_downcase|test("^\\s*@('"$bot_re"'|codex)\\s+review\\b")|tostring),
             (.user.login|test("\\[bot\\]$")|tostring),
             (.user.login|ascii_downcase|rtrimstr("[bot]")),
             .created_at,
             ((.body // "")|ascii_downcase|test("codex review: didn.t find any major issues")|tostring),
             ((.body // "")|ascii_downcase|test("reached your codex usage limits")|tostring),
             ((.body // "")|ascii_downcase|test("codex review: something went wrong")|tostring),
             ((.body // "")|ascii_downcase|startswith("## review loop summary")|tostring) ] | @tsv') \
    || { ERRMSG="comments: ${comments:0:200}"; return 1; }
  TRIGGER_AT=$(epoch "$(awk -F'\t' '$1=="true" && $2=="false"{print $4}' <<<"$comments" | sort | tail -n1)")
  TRIGGER_COUNT=$(awk -F'\t' '$1=="true" && $2=="false"' <<<"$comments" | grep -c .)
  # Unanswered requests on this HEAD: a completed review answers every request before it,
  # so only triggers newer than both HEAD and the last review count toward no_reviewer.
  TRIGGERS_HEAD=0
  while IFS=$'\t' read -r trig isbot _login at _rest; do
    [ "$trig" = true ] && [ "$isbot" = false ] || continue
    local at_e; at_e=$(epoch "$at")
    [ "$at_e" -ge "$HEAD_AT" ] && [ "$at_e" -gt "$REVIEWED_AT" ] && TRIGGERS_HEAD=$((TRIGGERS_HEAD+1))
  done <<<"$comments"
  # The author-side answer clock excludes the loop's own convergence report ($8) — that
  # comment must never "answer" a human CR or review body that raced the convergence.
  LAST_REPLY_AT=$(epoch "$(awk -F'\t' -v a="$AUTHOR" -v m="$ME" \
    '$1!="true" && $2=="false" && $8!="true" && ($3==a || (m!="" && $3==m)){print $4}' <<<"$comments" | sort | tail -n1)")
  CLEAN_AT=$(epoch "$(awk -F'\t' -v b="$BOT" '$2=="true" && $3==b && $5=="true"{print $4}' <<<"$comments" | sort | tail -n1)")
  # "reached your Codex usage limits" — the bot answered the request with "no quota".
  LIMIT_AT=$(epoch "$(awk -F'\t' -v b="$BOT" '$2=="true" && $3==b && $6=="true"{print $4}' <<<"$comments" | sort | tail -n1)")
  # Limit/error replies prove the bot is installed and talking — they must count as seen.
  local bot_replies; bot_replies=$(awk -F'\t' -v b="$BOT" '$2=="true" && $3==b && ($6=="true" || $7=="true")' <<<"$comments" | grep -c .)
  BODY_PENDING=0
  [ "$head_body" = 1 ] && [ "$LAST_REPLY_AT" -le "$REVIEWED_AT" ] && BODY_PENDING=1

  threads=$(api graphql --paginate -f query='
    query($owner:String!,$repo:String!,$number:Int!,$endCursor:String){
      repository(owner:$owner,name:$repo){ pullRequest(number:$number){
        reviewThreads(first:100, after:$endCursor){
          pageInfo{ hasNextPage endCursor }
          nodes{ isResolved path
                 first: comments(first:1){ nodes{ body } }
                 last:  comments(last:1){ nodes{ author{ login } } } }
        }}}}' -F owner="$OWNER" -F repo="$NAME" -F number="$PRNUM" --jq '
      '"$IGNORE_JSON"' as $ig
      | .data.repository.pullRequest.reviewThreads.nodes[]
      | (((.path // "") + " " + (.first.nodes[0].body // "")) | ascii_downcase) as $hay
      | [ (.isResolved|tostring),
          ((.last.nodes[0].author.login // "")|ascii_downcase|rtrimstr("[bot]")),
          (any($ig[]; inside($hay))|tostring) ] | @tsv') \
    || { ERRMSG="threads: ${threads:0:200}"; return 1; }
  THREADS=$(grep -c . <<<"$threads")
  local open; open=$(awk -F'\t' '$1=="false" && $3=="false"' <<<"$threads")
  UNRESOLVED=$(grep -c . <<<"$open")
  # Author-side last word = deliberately open ("leaving this open for a human") — not actionable.
  ANSWERED_OPEN=$(awk -F'\t' -v a="$AUTHOR" -v m="$ME" '$2==a || (m!="" && $2==m)' <<<"$open" | grep -c .)
  ACTIONABLE=$((UNRESOLVED - ANSWERED_OPEN))
  UNANSWERED=$(awk -F'\t' -v b="$BOT" '$2==b' <<<"$open" | grep -c .)
  IGNORED=$(awk -F'\t' '$1=="false" && $3=="true"' <<<"$threads" | grep -c .)

  # gh pr checks exits 8 on pending and 1 on failing/none — read the JSON, not the code.
  checks=$(gh pr checks "$PRNUM" --repo "$REPO" --json bucket 2>/dev/null)
  jq -e . >/dev/null 2>&1 <<<"$checks" || checks='[]'
  # "cancel" is a terminal non-green bucket — a canceled required check must not converge.
  CI_FAIL=$(jq '[.[]|select(.bucket=="fail" or .bucket=="cancel")]|length' <<<"$checks")
  CI_PENDING=$(jq '[.[]|select(.bucket=="pending")]|length' <<<"$checks")

  BOT_SEEN=0
  { [ "$BOT_REVIEWS" -gt 0 ] || [ "$bot_reactions" -gt 0 ] || [ "$CLEAN_AT" -gt 0 ] || [ "$bot_replies" -gt 0 ]; } && BOT_SEEN=1

  NOW=$(date +%s)
  decide
  return 0
}

emit() {
  EMITTED=1
  jq -nc \
    --arg repo "$REPO" --argjson pr "$PRNUM" --arg action "$ACTION" --arg reason "$REASON" \
    --arg head "$HEAD_SHA" --arg reviewed "$REVIEWED_SHA" --arg mergeable "$MERGEABLE" \
    --arg thumbs_by "${THUMBS_BY:-}" --arg converged_by "${CONVERGED_BY:-}" \
    --argjson head_age $((NOW - HEAD_AT)) \
    --argjson unresolved "$UNRESOLVED" --argjson actionable "$ACTIONABLE" \
    --argjson answered_open "$ANSWERED_OPEN" --argjson unanswered "$UNANSWERED" \
    --argjson ignored "$IGNORED" --argjson threads "$THREADS" \
    --argjson body_pending "$BODY_PENDING" \
    --argjson ci_fail "$CI_FAIL" --argjson ci_pending "$CI_PENDING" \
    --argjson eyes_active "$EYES_ACTIVE" --argjson thumbs_fresh "$THUMBS_FRESH" \
    --argjson approved_at "$APPROVED_AT" --argjson human_cr_at "$HUMAN_CR_AT" \
    --argjson trigger_pending "$TRIGGER_PENDING" --argjson trigger_count "$TRIGGER_COUNT" \
    --argjson triggers_head "$TRIGGERS_HEAD" --argjson bot_seen "$BOT_SEEN" \
    '{repo:$repo, pr:$pr, action:$action, reason:$reason,
      head:$head, head_reviewed:($reviewed==$head), reviewed:$reviewed, head_age_s:$head_age,
      unresolved:$unresolved, actionable:$actionable, answered_open:$answered_open,
      unanswered_by_bot:$unanswered, ignored_open:$ignored, threads_total:$threads,
      review_body_pending:($body_pending==1), ci_failing:$ci_fail, ci_pending:$ci_pending,
      mergeable:$mergeable, eyes_active:($eyes_active==1),
      thumbs_fresh:($thumbs_fresh==1), thumbs_by:$thumbs_by, converged_by:$converged_by,
      human_approved:($approved_at>0), human_changes_requested:($human_cr_at>0),
      trigger_pending:($trigger_pending==1), trigger_count:$trigger_count,
      triggers_head:$triggers_head, bot_seen:($bot_seen==1)}'
}

deadline=$(( $(date +%s) + TIMEOUT ))
prev='' FAILS=0
while :; do
  if snapshot; then
    FAILS=0
    [ "$WAIT" = 0 ] && { emit; exit 0; }
    fp="$ACTION|$HEAD_SHA|$REVIEWED_SHA|$ACTIONABLE|$CI_FAIL|$MERGEABLE|$THUMBS_AT|$APPROVED_AT|$CLEAN_AT|$LIMIT_AT"
    if [ "$ACTION" != wait ]; then emit; exit 0; fi
    if [ -n "$prev" ] && [ "$fp" != "$prev" ]; then emit; exit 0; fi
    prev=$fp
  else
    FAILS=$((FAILS+1))
    [ "$WAIT" = 0 ] && die "$ERRMSG"
    [ "$FAILS" -ge 3 ] && die "3 consecutive API failures: $ERRMSG"
  fi
  left=$(( deadline - $(date +%s) ))
  [ "$left" -le 0 ] && {
    jq -nc --arg repo "$REPO" --argjson pr "$PRNUM" --argjson t "$TIMEOUT" \
      '{repo:$repo, pr:$pr, action:"timeout", reason:"no change in \($t)s"}'; exit 10; }
  # never sleep past the deadline — --timeout is a wall-clock bound
  if [ "$left" -lt "$INTERVAL" ]; then sleep "$left"; else sleep "$INTERVAL"; fi
done
