# The GitHub host: how the forge tool (forge, next to it) does its verbs on github.com (forge.host "github" in .claude/wf.json). The contract and the
# JSON answers of the operator's verbs are those of host-forgejo.sh. The accounts are the operator (a fine-grained token of the user's own account)
# and two GitHub Apps, wf-dev (pushes, PRs, auto-merge, tasks) and wf-review (the check wf/review); their credentials live in $STATE/github/ (written
# by wf/github-setup.sh): operator.token, <dev|review>.app (APP_ID, INST_ID) and <dev|review>.pem. An installation token lasts an hour and is kept in
# <role>.tok until two minutes before it ends. No bot-merge: GitHub's auto-merge merges.
# GitHub has no "hold the merge until the requested reviewer reviews". The hold is a required check, `wf/review`, made by the wf-review App only (the
# ruleset pins the check to that App): in progress while a review is pending, success when none is, failure after request-changes. Its summary is the
# JSON {pending, approved, changes} (logins bot-review, operator), which is what `reviews` and `pr-show` report as REQUEST_REVIEW and APPROVED. A check
# belongs to one commit, so a new head gets its own (rv_ensure carries the pending reviews over from the commit before).

GH_API=https://api.github.com GH=$STATE/github
hdr() { printf '%s/%s.hdr' "$GH" "$1"; }   # the header git_as sends (basic, as GitHub wants it for git over https), apart from Forgejo's
gh_role() { case $1 in bot-dev|bot-merge) echo dev;; bot-review) echo review;; operator) echo operator;; *) die "no GitHub account for $1";; esac; }
b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt() { local now h p s; now=$(date +%s)   # APP_ID KEYFILE: what an App proves itself with, for eight minutes
  h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64u); p=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 480)) "$1" | b64u)
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$2" | b64u); printf '%s.%s.%s' "$h" "$p" "$s"; }
gh_token() { # ROLE: the token to use, minted when the kept one ends in less than two minutes
  local r=$1 f=$GH/$1.tok exp resp tmp APP_ID INST_ID
  [ "$r" != operator ] || { cat "$GH/operator.token" 2>/dev/null || die "no operator token ($GH/operator.token)"; return; }
  if [ -f "$f" ] && read -r exp <"$f" && [ "$exp" -gt $(( $(date +%s) + 120 )) ]; then sed -n 2p "$f"; return; fi
  . "$GH/$r.app" 2>/dev/null || die "no credentials for the $r App ($GH/$r.app)"
  resp=$(curl -4 -sS --connect-timeout 8 --max-time 30 -X POST -K <(printf 'header = "Authorization: Bearer %s"\n' "$(jwt "$APP_ID" "$GH/$r.pem")") \
    -H 'Accept: application/vnd.github+json' "$GH_API/app/installations/$INST_ID/access_tokens") || die "cannot reach GitHub"
  [ -n "$(jq -r '.token // empty' <<<"$resp")" ] || die "the $r App got no installation token: $(jq -r '.message // empty' <<<"$resp")"
  tmp=$(mktemp "$GH/.tok.XXXXXX") && { date -d "$(jq -r .expires_at <<<"$resp")" +%s; jq -r .token <<<"$resp"; } >"$tmp" && mv "$tmp" "$f"; jq -r .token <<<"$resp"; }
host_init() { # forge calls it once the role is known: the header of git over https for the role's account
  local t; mkdir -p "$GH" 2>/dev/null; t=$(gh_token "$(gh_role "$U")") || exit 1
  printf 'Authorization: basic %s\n' "$(printf 'x-access-token:%s' "$t" | base64 -w0)" >"$(hdr "$U")"; }
# api_raw USER METHOD PATH [JSON|-]: as lib.sh's, for the GitHub API (GH_ACCEPT changes the media type; api.github.com is reached over IPv4: some
# networks time out on IPv6, and a GET is tried three times)
api_raw() {
  local user=$1 method=$2 path=$3 data=${4:-} tok a n=1 c=000; tok=$(gh_token "$(gh_role "$user")") || { echo 000; return; }
  a=(-4 -sS --connect-timeout 8 --max-time 40 -o "$BODY" -w '%{http_code}' -X "$method" -H "Accept: ${GH_ACCEPT:-application/vnd.github+json}" -H 'X-GitHub-Api-Version: 2022-11-28')
  if [ "$data" = "-" ]; then a+=(-H 'Content-Type: application/json' --data-binary @-); n=1
  elif [ -n "$data" ]; then a+=(-H 'Content-Type: application/json' -d "$data"); fi
  [ "$method" != GET ] || n=3
  for r in 1 2 3 4; do   # (GitHub answers 403 or 429 "rate limit" when requests come too fast: wait and ask again, up to three times)
    for _ in $(seq $n); do c=$(curl "${a[@]}" -K <(printf 'header = "Authorization: Bearer %s"\n' "$tok") "$GH_API$path" 2>/dev/null) || c=000; [ "$c" != 000 ] && break; done
    { [ "$c" = 403 ] || [ "$c" = 429 ]; } && [ "$data" != "-" ] && [ "$r" -lt 4 ] && grep -qi 'rate limit' "$BODY" 2>/dev/null && { say "forge: GitHub rate limit ($method $path): waiting $((r * 20)) s"; sleep $((r * 20)); continue; }
    break; done; echo "$c"; }

PRJ='{number, state, merged: (.merged // (.merged_at != null)), head_sha: .head.sha, head_ref: .head.ref, title, merged_by: .merged_by.login, merged_at}'

# ---- the check wf/review (see the header). A read that fails is an error, never "no check": a writer that took it for none would start from nothing and
# lift the hold. rv_ensure and rv_write leave the head's state in RV_NOW, so that nothing depends on reading back what was just written (the lists of
# check runs lag behind a write; a reader that still misses it is waited for in rv_write).
RV_NOW=
rv_state() { # SHA: {id, status, pending, approved, changes} of the latest wf/review check of the commit; nothing when it has none, failure when GitHub cannot be read
  local r; r=$(api bot-review GET "/repos/$APP/commits/$1/check-runs?check_name=wf%2Freview&per_page=30") || return 1
  jq -c '[.check_runs[]] | max_by(.id) // empty | ((.output.summary // "{}") | (fromjson? // {})) as $s |
    {id, status, pending: ($s.pending // []), approved: ($s.approved // []), changes: ($s.changes // [])}' <<<"$r"; }
rv_write() { # SHA PENDING APPROVED CHANGES CURRENT: the check of the commit, made or moved on (CURRENT is its state now, empty when it has none)
  local sha=$1 p=$2 a=$3 c=$4 cur=${5:-} st con= title d r id
  if [ "$(jq length <<<"$c")" -gt 0 ]; then st=completed con=failure title="changes requested"
  elif [ "$(jq length <<<"$p")" -gt 0 ]; then st=in_progress title="waiting for: $(jq -r 'join(", ")' <<<"$p")"
  else st=completed con=success title="no review pending"; fi
  d=$(jq -nc --arg t "$title" --arg s "$(jq -nc --argjson p "$p" --argjson a "$a" --argjson c "$c" '{pending: $p, approved: $a, changes: $c}')" --arg st "$st" --arg con "$con" \
    '{status: $st, output: {title: $t, summary: $s}} + (if $con != "" then {conclusion: $con} else {} end)')
  id=$(jq -r '.id // empty' <<<"$cur")
  if [ -n "$id" ] && [ "$(jq -r .status <<<"$cur")" != completed ]; then r=$(api bot-review PATCH "/repos/$APP/check-runs/$id" "$d") || return 1
  else r=$(api bot-review POST "/repos/$APP/check-runs" "$(jq -c --arg n wf/review --arg h "$sha" '. + {name: $n, head_sha: $h}' <<<"$d")") || return 1; fi
  RV_NOW=$(jq -nc --argjson i "$(jq .id <<<"$r")" --arg st "$st" --argjson p "$p" --argjson a "$a" --argjson c "$c" '{id: $i, status: $st, pending: $p, approved: $a, changes: $c}')
  for _ in $(seq 40); do [ "$(rv_state "$sha" | jq -c '[.pending, .approved, .changes]')" = "[$p,$a,$c]" ] && return 0; sleep 1.5; done
  say "forge: the review check of ${sha:0:7} was written but is not readable yet (a minute); going on with what was written"; return 0; }
rv_peek() { # PR: RV_HEAD is the head, RV_NOW its check, or the state a check would start with (no id) when it has none: the pending reviews of the commit before
  local cur sha p='[]'; RV_HEAD=$(head_of "$1") || exit 1; cur=$(rv_state "$RV_HEAD") || exit 1
  [ -z "$cur" ] || { RV_NOW=$cur; return 0; }
  for sha in $(api "$U" GET "/repos/$APP/pulls/$1/commits?per_page=100" | jq -r '[.[].sha] | reverse | .[]' | head -12); do
    [ "$sha" != "$RV_HEAD" ] || continue; cur=$(rv_state "$sha") || exit 1; [ -n "$cur" ] || continue
    [ "$(jq '.changes | length' <<<"$cur")" != 0 ] || p=$(jq -c .pending <<<"$cur"); break; done
  RV_NOW=$(jq -nc --argjson p "$p" '{pending: $p, approved: [], changes: []}'); }
rv_ensure() { # PR: the head has its check (a new head, after a push or an update of the branch, starts one). Never a second one is written for the commit when a
  # review is about to be asked: two runs of one name made within seconds can tie, and the one that succeeded may count (seen: a held PR merged)
  rv_peek "$1"; [ -z "$(jq -r '.id // empty' <<<"$RV_NOW")" ] || return 0
  rv_write "$RV_HEAD" "$(jq -c .pending <<<"$RV_NOW")" '[]' '[]' || exit 1; }
rv_move() { # PR HEAD_SHA WHO KIND: WHO answers (approved | changes) or is asked (pending) or is released (drop) on the head's check, which is made now when it has none
  local cur; rv_peek "$1"; cur=$RV_NOW; [ "$2" = "$RV_HEAD" ] || die "PR #$1 moved on: its head is ${RV_HEAD:0:7}, not ${2:0:7}"
  rv_write "$2" "$(jq -c --arg w "$3" --arg k "$4" '(.pending - [$w]) + (if $k == "pending" then [$w] else [] end) | unique' <<<"$cur")" \
    "$(jq -c --arg w "$3" --arg k "$4" '(.approved - [$w]) + (if $k == "approved" then [$w] else [] end) | unique' <<<"$cur")" \
    "$(jq -c --arg w "$3" --arg k "$4" '(.changes - [$w]) + (if $k == "changes" then [$w] else [] end) | unique' <<<"$cur")" "$cur"; }

pr_of() { # [BRANCH]: number of the open PR of that branch (default: the checked out one), empty if none
  local b=${1:-}; [ -n "$b" ] || b=$(branch) || exit 2; [[ $b =~ ^[A-Za-z0-9._/-]+$ ]] || die "odd branch name"
  api "$U" GET "/repos/$APP/pulls?state=open&head=${APP%%/*}:$b&per_page=50" | jq -r --arg b "$b" '[.[] | select(.head.ref == $b)] | first | .number // empty'; }
head_of() { api "$U" GET "/repos/$APP/pulls/$1" | jq -r .head.sha; }
ci_state() { # the check `ci` (the job the ruleset requires; with components it totals the others)
  api "$U" GET "/repos/$APP/commits/$1/check-runs?check_name=ci&per_page=30" | jq -r '[.check_runs[]] | if length == 0 then "none" else
    (max_by(.id) | if .status != "completed" then "pending" elif .conclusion == "success" then "success" else "failure" end) end'; }
pr_show() { local pr sha; num "${1:-}"; pr=$(api "$U" GET "/repos/$APP/pulls/$1") || exit 1; sha=$(jq -r .head.sha <<<"$pr")
  jq -r '"PR #\(.number) \(.state) merged=\(.merged) head=\(.head.sha)\n\(.title)"' <<<"$pr"
  echo "ci: $(ci_state "$sha") [$(api "$U" GET "/repos/$APP/commits/$sha/check-runs?per_page=50" | jq -r '[.check_runs[] | select(.name != "wf/review") | "\(.name)=\(.conclusion // .status)"] | join(", ")')]"
  api "$U" GET "/repos/$APP/pulls/$1/files?per_page=100" | jq -r '.[].filename' | python3 "$WF_LIB/paths.py" classify |
    awk '{c[$1]=c[$1] " " $2} END {printf "files:"; for (k in c) printf " %s:%s", k, c[k]; print ""}'
  echo "reviews: $(rv_state "$sha" | jq -r --arg s "${sha:0:7}" '[(.pending[] | "\(.):REQUEST_REVIEW@\($s)"), (.approved[] | "\(.):APPROVED@\($s)"), (.changes[] | "\(.):REQUEST_CHANGES@\($s)")] | join(" ")')"; }
ci_log() { local sha run j; num "${1:-}"; sha=$(head_of "$1") || exit 1
  run=$(api "$U" GET "/repos/$APP/actions/runs?head_sha=$sha&event=pull_request&per_page=30" | jq -r '[.workflow_runs[]] | max_by(.id) | .id // empty') || exit 1
  [ -n "$run" ] || die "no CI run for ${sha:0:7} yet"
  # the jobs that did not pass; the job `ci` of a project with components only totals the others, so it is shown when it is the only one
  for j in $(api "$U" GET "/repos/$APP/actions/runs/$run/jobs?per_page=100" | jq -r '.jobs | (map(select(.conclusion != "success" and .conclusion != "skipped" and .status == "completed")) | (map(select(.name != "ci")) as $c | if ($c | length) > 0 then $c else . end)) | .[] | "\(.id):\(.name)"'); do
    [ "${j#*:}" = ci ] || echo "== job ${j#*:}"
    for _ in 1 2 3; do [ "$(curl -4 -sSL --connect-timeout 8 --max-time 40 -o "$BODY" -w '%{http_code}' -K <(printf 'header = "Authorization: Bearer %s"\n' "$(gh_token "$(gh_role "$U")")") "$GH_API/repos/$APP/actions/jobs/${j%%:*}/logs" 2>/dev/null)" = 200 ] && { sed 's/^[0-9T:.Z-]* //' "$BODY" | tail -n 80; break; }; done; done; }   # (the download is tried three times: this network times out now and then)
verdict() { # EVENT N SHA [-]: the reviewer's answer: the head is checked, the check moves, the comments are kept on the PR
  local ev=$1 who=$2 n=$3 sha=$4 b= cur kind; num "$n"; [[ ${sha:-} =~ ^[0-9a-f]{40}$ ]] || die "give the full head SHA that you reviewed"
  [ "${5:-}" != - ] || b=$(cat)
  cur=$(api "$U" GET "/repos/$APP/pulls/$n" | jq -r 'select(.state == "open") | .head.sha') || exit 1
  [ "$cur" = "$sha" ] || die "PR #$n is not open at $sha (head is ${cur:-closed}): review the new head first"
  case $ev in APPROVED) kind=approved;; *) kind=changes;; esac
  rv_move "$n" "$sha" "$who" "$kind" || exit 1
  [ "$who" != operator ] || api operator POST "/repos/$APP/pulls/$n/reviews" "$(jq -nc --arg c "$sha" --arg b "${b:-Approved by the operator.}" '{event: "APPROVE", commit_id: $c, body: $b}')" >/dev/null || exit 1
  if [ "$who" != operator ] && [ -n "$b" ]; then   # the comments stay on the PR; a comment review never blocks the merge (the check does)
    api bot-review POST "/repos/$APP/pulls/$n/reviews" "$(jq -nc --arg c "$sha" --arg b "$ev by $who: $b" '{event: "COMMENT", commit_id: $c, body: $b}')" >/dev/null || true; fi
  echo "review $ev on #$n at ${sha:0:7}"; }

h_dev_pr_show() { pr_show "$@"; }
h_review_pr_show() { pr_show "$@"; }
h_dev_pr_of() { pr_of "${1:-}"; }
h_review_pr_of() { pr_of "${1:-}"; }
h_dev_ci_log() { ci_log "${1:-}"; }
h_review_pr_diff() { num "${1:-}"; [ "$(GH_ACCEPT=application/vnd.github.diff api_raw "$U" GET "/repos/$APP/pulls/$1")" = 200 ] && cat "$BODY" || die "no such PR"; }
h_review_approve() { verdict APPROVED bot-review "${1:-}" "${2:-}" "${3:-}"; }
h_review_request_changes() { [ "${3:-}" = - ] || die "request-changes needs its comments on stdin (-)"; verdict REQUEST_CHANGES bot-review "${1:-}" "${2:-}" -; }

h_dev_update_branch() {   # prints updated or current; the update is made by GitHub a moment after it says 202: wait for the new head
  local code before i; num "${1:-}"; before=$(head_of "$1") || exit 1
  code=$(api_raw "$U" PUT "/repos/$APP/pulls/$1/update-branch" '{}')
  if [ "${code:0:1}" = 2 ]; then
    for i in $(seq 20); do [ "$(head_of "$1")" != "$before" ] && break; sleep 2; done; echo updated
  elif grep -qi 'no new commits' "$BODY" 2>/dev/null; then echo current
  else die "update of PR #$1 answered $code: $(jq -r '.message // empty' "$BODY" 2>/dev/null | cut -c1-160)"; fi; }
h_dev_pr_behind() {   # current | behind | behind-approved (a PR with an approval is left alone: a new head would ask for the review again)
  local pr cur; num "${1:-}"; pr=$(api "$U" GET "/repos/$APP/pulls/$1") || exit 1
  [ "$(jq -r .state <<<"$pr")" = open ] || { echo current; exit 0; }
  [ "$(api "$U" GET "/repos/$APP/compare/main...$(jq -r .head.sha <<<"$pr")" | jq -r .behind_by)" -gt 0 ] || { echo current; exit 0; }
  cur=$(rv_state "$(jq -r .head.sha <<<"$pr")"); [ -n "$cur" ] || cur='{"approved": []}'
  if [ "$(jq '.approved | length' <<<"$cur")" -gt 0 ]; then echo behind-approved; else echo behind; fi; }
h_dev_pr_open() {
  local b; clone >/dev/null || exit 2; b=$(branch) || exit 2; [ -n "${1:-}" ] || die "give a title"; num "${2:-}"
  api "$U" POST "/repos/$APP/pulls" "$(jq -nc --arg h "$b" --arg t "$1" --arg d "$(printf 'Closes %s#%s' "$TASKS" "$2")" '{head: $h, base: "main", title: $t, body: $d}')" | jq -r '"PR #\(.number) \(.html_url)"'; }
h_dev_ci_wait() {
  local t=${2:-600} sha s; num "${1:-}"; [[ $t =~ ^[0-9]+$ ]] || die "seconds must be a number"; sha=$(head_of "$1") || exit 1
  while :; do s=$(ci_state "$sha") || exit 1; case $s in success|failure|error) break;; esac
    [ "$t" -gt 0 ] || { s=timeout; break; }; sleep 5; t=$((t - 5)); done
  echo "ci: $s at ${sha:0:7}"; }
h_dev_task_show() { num "${1:-}"; api "$U" GET "/repos/$TASKS/issues/$1" | jq -r '"#\(.number) \(.state) [\([.labels[].name] | join(", "))] \(.title)\n\n\(.body)"'; }
h_dev_task_labels() { local code; num "${1:-}"; code=$(api_raw "$U" GET "/repos/$TASKS/issues/$1")
  case $code in 404) ;; 2*) jq -r '.labels[].name' "$BODY";; *) die "task $1 answered $code";; esac; }
h_dev_review_request() {   # a reviewer that already has a pending request is not asked twice; one that has answered (the head moved) is asked again
  num "${1:-}"; case ${2:-} in bot-review|operator) ;; *) die "the reviewer is bot-review or operator";; esac
  rv_peek "$1"
  if jq -e --arg u "$2" '.pending | index($u) != null' <<<"$RV_NOW" >/dev/null; then echo "review of $2 already requested"
  else rv_move "$1" "$(head_of "$1")" "$2" pending || exit 1; echo "review requested from $2"; fi; }
h_dev_task_status() {
  local keep; num "${1:-}"; case ${2:-} in todo|in-review) ;; *) die "status must be todo|in-review";; esac
  keep=$(api "$U" GET "/repos/$TASKS/issues/$1" | jq -c --arg s "status:$2" '[.labels[].name | select(startswith("status:") | not)] + [$s]') || exit 1
  api "$U" PUT "/repos/$TASKS/issues/$1/labels" "$(jq -nc --argjson l "$keep" '{labels: $l}')" | jq -r '"#'"$1"' labels: " + ([.[].name] | join(", "))'; }
h_dev_automerge() {   # the head gets its review check, then GitHub merges by itself when the ruleset is met; a PR that already meets it is merged now
  local n=${1:-} node code msg; num "$n"; rv_ensure "$n" || exit 1
  node=$(api "$U" GET "/repos/$APP/pulls/$n" | jq -r .node_id) || exit 1
  code=$(api_raw "$U" POST /graphql "$(jq -nc --arg i "$node" '{query: "mutation($id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: SQUASH}) { pullRequest { number } } }", variables: {id: $i}}')")
  msg=$(jq -r '.errors[0].message // empty' "$BODY" 2>/dev/null | cut -c1-160)
  if [ "${code:0:1}" = 2 ] && [ -z "$msg" ]; then echo "merge of PR #$n scheduled: HTTP $code"; return 0; fi
  if grep -qi 'clean status' <<<"$msg"; then code=$(api_raw "$U" PUT "/repos/$APP/pulls/$n/merge" '{"merge_method": "squash"}'); msg=$(jq -r '.message // empty' "$BODY" | cut -c1-160)
    echo "merge of PR #$n done now: HTTP $code $msg"; [ "$code" = 200 ]; return; fi
  echo "merge of PR #$n scheduled: HTTP $code $msg"; grep -qi 'already' <<<"$msg"; }

# the operator's verbs
h_operator_pr_json() { num "${1:-}"; api "$U" GET "/repos/$APP/pulls/$1" | jq -c "$PRJ"; }
h_operator_pr_list() {   # open | merged (the three latest)
  local n
  case ${1:-} in
    open) api "$U" GET "/repos/$APP/pulls?state=open&per_page=50" | jq -c "[.[] | $PRJ]";;
    merged) for n in $(api "$U" GET "/repos/$APP/pulls?state=closed&per_page=30" | jq -r '[.[] | select(.merged_at != null) | .number] | .[0:3][]'); do h_operator_pr_json "$n"; done | jq -sc .;;
    *) die "pr-list open|merged";; esac; }
h_operator_pr_create() { [ $# = 3 ] || die "pr-create BRANCH TITLE BODY"
  api "$U" POST "/repos/$APP/pulls" "$(jq -nc --arg h "$1" --arg t "$2" --arg b "$3" '{head: $h, base: "main", title: $t, body: $b}')" | jq -r .number; }
h_operator_ci_state() { ci_state "${1:-}"; }
h_operator_reviews() { num "${1:-}"; rv_state "$(head_of "$1")" | jq -c '[(.pending[] | {user: ., state: "REQUEST_REVIEW"}), (.approved[] | {user: ., state: "APPROVED"}), (.changes[] | {user: ., state: "REQUEST_CHANGES"})]' | grep . || echo '[]'; }
h_operator_approve() { verdict APPROVED operator "${1:-}" "${2:-}" "${3:-}"; }
h_operator_unrequest() { num "${1:-}"; local n=$1 w; shift   # N LOGIN...: withdraws the pending review requests
  for w in "$@"; do rv_move "$n" "$(head_of "$n")" "$w" drop || exit 1; done; }
h_operator_comment() { num "${1:-}"; api "$U" POST "/repos/$APP/issues/$1/comments" "$(jq -nc --arg b "${2:-}" '{body: $b}')" >/dev/null; }
h_operator_merge() {   # N [--force]: the squash merge now, as the dev App (the rules apply); --force as the operator, who is on the ruleset's bypass list (class C)
  local n=${1:-} code as=bot-dev; num "$n"; [ "${2:-}" != --force ] || as=operator
  for _ in 1 2 3 4 5; do
    code=$(api_raw "$as" PUT "/repos/$APP/pulls/$n/merge" '{"merge_method": "squash"}'); [ "$code" = 405 ] && grep -qi 'modified\|try' "$BODY" 2>/dev/null || break; sleep 3
  done
  [ "$code" = 200 ] || { say "merge of PR #$n answered $code: $(jq -r '.message // empty' "$BODY")"; return 1; }; }
h_operator_task_json() { num "${1:-}"; api "$U" GET "/repos/$TASKS/issues/$1" | jq -c '{number, title, body}'; }
h_operator_task_list() { api "$U" GET "/repos/$TASKS/issues?state=open&per_page=50" | jq -c '[.[] | select(.pull_request | not) | {number, title, labels: [.labels[].name]}]'; }
h_operator_task_new() {   # TITLE BODY LABEL...: a label the tasks repository lacks (made before the policy existed) is created
  local labels nm title=${1:?title} body=${2-}; shift 2
  labels=$(api "$U" GET "/repos/$TASKS/labels?per_page=100") || return 1
  for nm in "$@"; do jq -e --arg n "$nm" 'any(.[]; .name == $n)' <<<"$labels" >/dev/null ||
    api "$U" POST "/repos/$TASKS/labels" "$(jq -nc --arg n "$nm" '{name: $n, color: "5319e7"}')" >/dev/null || return 1; done
  jq -nc --arg t "$title" --arg b "$body" '{title: $t, body: $b, labels: $ARGS.positional}' --args "$@" | api "$U" POST "/repos/$TASKS/issues" - | jq -c '{number, title, body}'; }
h_operator_protect_files() { :; }   # the class C files are held by CODEOWNERS and the ruleset's code owner review: nothing to set per project
