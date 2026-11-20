# The Forgejo host: how the forge tool (forge, next to it) does its verbs on a Forgejo forge. forge sources the host file of the project
# (forge.host of .claude/wf.json, default forgejo) after lib.sh. A host file defines h_<role>_<verb> (the verb's dashes as underscores) for every
# verb that is not plain git (push, sync and fetch-main stay in forge), and uses what forge and lib.sh give: APP, TASKS, U (the role's account),
# num, die, say, clone, branch, api, api_raw, BODY. The verbs of the operator role answer in one JSON shape on every host:
#   pr-json N      {number, state, merged, head_sha, head_ref, title, merged_by, merged_at}      pr-list open|merged   an array of them
#   reviews N      [{user, state}], state APPROVED | REQUEST_CHANGES | COMMENT | REQUEST_REVIEW (asked, not answered)
#   task-json N    {number, title, body}     task-list   [{number, title, labels: [names]}]     ci-state SHA   none | pending | success | failure | error

PRJ='{number, state, merged, head_sha: .head.sha, head_ref: .head.ref, title, merged_by: .merged_by.login, merged_at}'

pr_of() { # [BRANCH]: number of the open PR of that branch (default: the checked out one), empty if none
  local b=${1:-}; [ -n "$b" ] || b=$(branch) || exit 2; [[ $b =~ ^[A-Za-z0-9._/-]+$ ]] || die "odd branch name"
  api "$U" GET "/repos/$APP/pulls?state=open&limit=50" | jq -r --arg b "$b" '[.[] | select(.head.ref == $b)] | first | .number // empty'; }
head_of() { api "$U" GET "/repos/$APP/pulls/$1" | jq -r .head.sha; }
ci_state() { api "$U" GET "/repos/$APP/commits/$1/status" | jq -r 'if (.statuses | length) == 0 then "none" else .state end'; }
pr_show() { local pr sha; num "${1:-}"; pr=$(api "$U" GET "/repos/$APP/pulls/$1") || exit 1; sha=$(jq -r .head.sha <<<"$pr")
  jq -r '"PR #\(.number) \(.state) merged=\(.merged) head=\(.head.sha)\n\(.title)"' <<<"$pr"
  api "$U" GET "/repos/$APP/commits/$sha/status" | jq -r '"ci: " + (if (.statuses | length) == 0 then "none" else .state end) + " [" + ([.statuses[] | "\(.context)=\(.status)"] | join(", ")) + "]"'
  api "$U" GET "/repos/$APP/pulls/$1/files?limit=100" | jq -r '.[].filename' | python3 "$WF_LIB/paths.py" classify |
    awk '{c[$1]=c[$1] " " $2} END {printf "files:"; for (k in c) printf " %s:%s", k, c[k]; print ""}'
  api "$U" GET "/repos/$APP/pulls/$1/reviews" | jq -r '"reviews: " + ([.[] | "\(.user.login):\(.state)@\(.commit_id[0:7])"] | join(" "))'; }
ci_log() { local sha run j; num "${1:-}"; sha=$(head_of "$1") || exit 1
  run=$(api "$U" GET "/repos/$APP/actions/runs?limit=50" | jq -r --arg s "$sha" '[.workflow_runs[] | select(.commit_sha == $s and .event == "pull_request")] | max_by(.id) | .id // empty') || exit 1
  [ -n "$run" ] || die "no CI run for ${sha:0:7} yet"
  # the jobs that did not pass; the job `ci` of a project with components only totals the others, so it is shown when it is the only one
  for j in $(api "$U" GET "/repos/$APP/actions/runs/$run/jobs" | jq -r '(map(select(.status != "success" and .status != "skipped")) | (map(select(.name != "ci")) as $c | if ($c | length) > 0 then $c else . end)) as $f | (if ($f | length) > 0 then $f else . end) | .[] | "\(.id):\(.name)"'); do
    [ "${j#*:}" = ci ] || echo "== job ${j#*:}"
    [ "$(api_raw "$U" GET "/repos/$APP/actions/jobs/${j%%:*}/logs")" = 200 ] && sed 's/^[0-9T:.Z-]* //' "$BODY" | tail -n 80; done; }
review() { # EVENT N SHA [-]: the body from stdin with "-"
  local cur b=; num "$2"; [[ ${3:-} =~ ^[0-9a-f]{40}$ ]] || die "give the full head SHA that you reviewed"
  [ "${4:-}" != - ] || b=$(cat)
  cur=$(api "$U" GET "/repos/$APP/pulls/$2" | jq -r 'select(.state == "open") | .head.sha') || exit 1
  [ "$cur" = "$3" ] || die "PR #$2 is not open at $3 (head is ${cur:-closed}): review the new head first"
  api "$U" POST "/repos/$APP/pulls/$2/reviews" "$(jq -nc --arg e "$1" --arg c "$3" --arg b "$b" '{event: $e, commit_id: $c, body: $b}')" |
    jq -r '"review \(.state) on #'"$2"' at \(.commit_id[0:7])"'; }

h_dev_pr_show() { pr_show "$@"; }
h_review_pr_show() { pr_show "$@"; }
h_dev_pr_of() { pr_of "${1:-}"; }
h_review_pr_of() { pr_of "${1:-}"; }
h_dev_ci_log() { ci_log "${1:-}"; }
h_review_pr_diff() { num "${1:-}"; [ "$(api_raw "$U" GET "/repos/$APP/pulls/$1.diff")" = 200 ] && cat "$BODY" || die "no such PR"; }
h_review_approve() { review APPROVED "${1:-}" "${2:-}" "${3:-}"; }
h_review_request_changes() { [ "${3:-}" = - ] || die "request-changes needs its comments on stdin (-)"; review REQUEST_CHANGES "${1:-}" "${2:-}" -; }

h_dev_update_branch() {   # prints updated or current; the merge commit is made by the forge as bot-dev
  local code; num "${1:-}"; code=$(api_raw "$U" POST "/repos/$APP/pulls/$1/update?style=merge")
  if [ "${code:0:1}" = 2 ]; then echo updated
  elif grep -qi 'up to date\|already' "$BODY" 2>/dev/null; then echo current
  else die "update of PR #$1 answered $code: $(jq -r '.message // empty' "$BODY" 2>/dev/null | cut -c1-160)"; fi; }
h_dev_pr_behind() {   # current | behind | behind-approved, for a PR on the forge (only an unapproved PR may be updated: a new head dismisses approvals)
  local pr; num "${1:-}"; pr=$(api "$U" GET "/repos/$APP/pulls/$1") || exit 1
  [ "$(jq -r .state <<<"$pr")" = open ] || { echo current; exit 0; }
  [ "$(jq -r .merge_base <<<"$pr")" = "$(api "$U" GET "/repos/$APP/branches/main" | jq -r .commit.id)" ] && { echo current; exit 0; }
  if api "$U" GET "/repos/$APP/pulls/$1/reviews" | jq -e 'any(.[]; .state == "APPROVED" and (.dismissed | not) and (.stale | not))' >/dev/null; then echo behind-approved; else echo behind; fi; }
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
h_dev_review_request() {   # a reviewer that already has a pending request is not asked twice; one that has reviewed (the head moved) is asked again
  local code; num "${1:-}"; case ${2:-} in bot-review|operator) ;; *) die "the reviewer is bot-review or operator";; esac
  if api "$U" GET "/repos/$APP/pulls/$1/reviews" | jq -e --arg u "$2" 'any(.[]; .user.login == $u and .state == "REQUEST_REVIEW")' >/dev/null; then echo "review of $2 already requested"
  else code=$(api_raw "$U" POST "/repos/$APP/pulls/$1/requested_reviewers" "$(jq -nc --arg u "$2" '{reviewers: [$u]}')")
    [ "${code:0:1}" = 2 ] && echo "review requested from $2" || die "review request of $2 answered $code: $(jq -r '.message // empty' "$BODY" 2>/dev/null | cut -c1-160)"; fi; }
h_dev_task_status() {
  local keep; num "${1:-}"; case ${2:-} in todo|in-review) ;; *) die "status must be todo|in-review";; esac
  keep=$(api "$U" GET "/repos/$TASKS/issues/$1" | jq -c --arg s "status:$2" '[.labels[].name | select(startswith("status:") | not)] + [$s]') || exit 1
  api "$U" PUT "/repos/$TASKS/issues/$1/labels" "$(jq -nc --argjson l "$keep" '{labels: $l}')" | jq -r '"#'"$1"' labels: " + ([.[].name] | join(", "))'; }
h_dev_automerge() {   # a PR the forge is still checking (right after a push or an update) answers 405 "try again later": retry; 409 = already scheduled
  local code msg; num "${1:-}"
  for _ in 1 2 3 4 5 6 7 8; do
    code=$(api_raw bot-merge POST "/repos/$APP/pulls/$1/merge" '{"Do":"squash","merge_when_checks_succeed":true,"delete_branch_after_merge":true}')
    [ "$code" = 405 ] && grep -qi 'try again later' "$BODY" 2>/dev/null || break; sleep 2
  done
  msg=$(jq -r '.message // empty' "$BODY" 2>/dev/null | cut -c1-160)
  echo "merge of PR #$1 scheduled: HTTP $code $msg"; [ "${code:0:1}" = 2 ] || { [ "$code" = 409 ] && grep -qi 'already scheduled' <<<"$msg"; }; }

# the operator's verbs (the scripts of wf/ use them): JSON in the shape the header names
h_operator_pr_json() { num "${1:-}"; api "$U" GET "/repos/$APP/pulls/$1" | jq -c "$PRJ"; }
h_operator_pr_list() {   # open | merged (the three latest)
  local n
  case ${1:-} in
    open) api "$U" GET "/repos/$APP/pulls?state=open&limit=50" | jq -c "[.[] | $PRJ]";;
    merged) for n in $(api "$U" GET "/repos/$APP/pulls?state=closed&limit=10" | jq -r '[.[] | select(.merged) | .number] | .[0:3][]'); do h_operator_pr_json "$n"; done | jq -sc .;;
    *) die "pr-list open|merged";; esac; }
h_operator_pr_create() { [ $# = 3 ] || die "pr-create BRANCH TITLE BODY"
  api "$U" POST "/repos/$APP/pulls" "$(jq -nc --arg h "$1" --arg t "$2" --arg b "$3" '{head: $h, base: "main", title: $t, body: $b}')" | jq -r .number; }
h_operator_ci_state() { ci_state "${1:-}"; }
h_operator_reviews() { num "${1:-}"; api "$U" GET "/repos/$APP/pulls/$1/reviews" | jq -c '[.[] | {user: .user.login, state}]'; }
h_operator_approve() { review APPROVED "${1:-}" "${2:-}" "${3:-}"; }
h_operator_unrequest() { num "${1:-}"; local n=$1; shift   # N LOGIN...: withdraws the pending review requests
  api "$U" DELETE "/repos/$APP/pulls/$n/requested_reviewers" "$(jq -nc '{reviewers: $ARGS.positional}' --args "$@")" >/dev/null; }
h_operator_comment() { num "${1:-}"; api "$U" POST "/repos/$APP/issues/$1/comments" "$(jq -nc --arg b "${2:-}" '{body: $b}')" >/dev/null; }
h_operator_merge() {   # N [--force]: the squash merge now; --force passes the rules the operator may pass (class C). A PR still being checked answers 405 "try again later": retry
  local n=${1:-} code body='{"Do":"squash","delete_branch_after_merge":true}'; num "$n"
  [ "${2:-}" != --force ] || body='{"Do":"squash","force_merge":true,"delete_branch_after_merge":true}'
  for _ in 1 2 3 4 5 6 7 8; do
    code=$(api_raw "$U" POST "/repos/$APP/pulls/$n/merge" "$body"); [ "$code" = 405 ] && grep -qi 'try again later' "$BODY" 2>/dev/null || break; sleep 2
  done
  [ "$code" = 200 ] || { say "merge of PR #$n answered $code: $(jq -r '.message // empty' "$BODY")"; return 1; }; }
h_operator_task_json() { num "${1:-}"; api "$U" GET "/repos/$TASKS/issues/$1" | jq -c '{number, title, body}'; }
h_operator_task_list() { api "$U" GET "/repos/$TASKS/issues?state=open&type=issues&limit=50" | jq -c '[.[] | {number, title, labels: [.labels[].name]}]'; }
h_operator_task_new() {   # TITLE BODY LABEL...: a label the tasks repository lacks (made before the policy existed) is created
  local labels ids nm id title=${1:?title} body=${2-}; shift 2
  labels=$(api "$U" GET "/repos/$TASKS/labels?limit=50") || return 1
  ids=$(for nm in "$@"; do
    id=$(jq -r --arg n "$nm" '[.[] | select(.name == $n) | .id] | first // empty' <<<"$labels")
    [ -n "$id" ] || id=$(api "$U" POST "/repos/$TASKS/labels" "$(jq -nc --arg n "$nm" '{name: $n, color: "5319e7"}')" | jq -r .id); echo "$id"
  done | jq -sc .)
  jq -nc --arg t "$title" --arg b "$body" --argjson l "$ids" '{title: $t, body: $b, labels: $l}' | api "$U" POST "/repos/$TASKS/issues" - | jq -c '{number, title, body}'; }
h_operator_protect_files() {   # PATTERNS: the forge refuses a merge that touches these files, except the operator's force-merge
  local code; code=$(api_raw "$U" PATCH "/repos/$APP/branch_protections/main" "$(jq -nc --arg f "${1:-}" '{protected_file_patterns: $f}')")
  [ "${code:0:1}" = 2 ] || { say "protection of $APP answered $code: $(head -c 200 "$BODY")"; return 1; }; }
