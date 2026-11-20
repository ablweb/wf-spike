#!/bin/bash
# SubagentStop hook: Claude Code runs it on the host when a subagent finishes, and this is where the pipeline starts. Agents
# have file tools only (no shell, no git, no credential): everything git and forge happens here. The role is the agent_type
# Claude Code reports, the task number N comes from the operator's prompt ("Task #N"), the agent's answer from its last message.
#   implement  formats the changed files (ci.format, jailed) and commits the worktree's changes on agent/t<N> -> rebase onto the forge's main -> the architecture
#              model (ci.model, jailed, when the change touches class B; what it writes joins the commit) -> the jailed quick check (ci.fast of
#              .claude/wf.json, e.g. make ci-fast; with ci.components, the formatter and the quick check of each component whose folder the
#              change touches, in that folder) -> push ->
#              PR (first round) with the merge scheduled -> wait for CI (at most 4 minutes, while the agent's context is still
#              cached). Whatever is wrong, a red CI included, goes back to the developer as feedback (exit 2); after 5 rounds the
#              hook gives up. A PR that needs a review gets a review packet: .claude/wf/review/t<N>.md, the forge's diff and the
#              worktree that holds the branch. The operator is told the next step. The operator's policy decides who is asked: the task's
#              labels review:agent (bot-review) and review:operator (operator) make the hook request that review from the forge, which then
#              holds the merge until the reviewer has reviewed; a task without them merges as soon as CI is green.
#   review     posts the verdict of its last message on the PR of task N, bound to the head of the packet; an approval first
#              brings a PR that fell behind main up to date (a new head would dismiss the approval, so the order matters).
# The forge merges by itself (scheduled right after each push) once CI is green and the review, if any, approves: the one merge
# mechanism; the hook only keeps an unapproved PR up to date with main while it waits. The hook's own state (strikes, packet heads) is in the per-user state folder
# (lib.sh), outside the project and out of the agents' reach.
set -uo pipefail
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")"); FORGE=$HERE/forge
. "$HERE/lib.sh"; ST=$STATE/hook; MAX=5
WAIT=240       # seconds, whole hook: it ends before the agent's 5-minute cache does (the loop below stops TAIL earlier, for its last round)
TAIL=45   # seconds: the slowest round of the loop
in=$(cat); field() { jq -r --arg k "$1" '.[$k] // ""' <<<"$in"; }
type=$(field agent_type); cwd=$(field cwd); id=$(field agent_id); tr=$(field agent_transcript_path); last=$(field last_assistant_message)
# tell MESSAGE: the pipeline's word to the operator. An agent hands back with SubagentHandback, which ends its run before this hook starts, so
# nothing can be passed through the agent: the message goes to the user's screen and into the state folder (the note of the task), where the
# operator asks for it (wf/status.sh PROJECT_DIR --wait N), and it is posted to the notification URL when one is set (notify in lib.sh). The note says "running" while the hook works.
tell() {
  [ -z "${note:-}" ] || printf '%s\n' "$1" >"$note"
  notify "[$(wfcfg .app)] $1"
  jq -nc --arg m "[pipeline] $1" '{systemMessage: $m}'
  exit 0; }
# The agent's role is mapped to a pipeline stage in .claude/wf.json (agents.roles): implement (ship the files it changed), review (post
# its verdict), report (ship nothing: its final message is for the operator). A role may narrow its zone with `classes`. An agent
# that is no role is none of the pipeline's business.
stage=$(jq -r --arg t "$type" '.agents.roles[$t] // empty | if type == "object" then .stage else . end' "$HERE/../wf.json" 2>/dev/null)
zone=$(jq -r --arg t "$type" '(.agents.roles // {})[$t] // empty | objects | (.classes // []) | join(",")' "$HERE/../wf.json" 2>/dev/null)
case $stage in implement|review) ;; *) exit 0;; esac   # (report: nothing to do)
[[ $id =~ ^[A-Za-z0-9_-]+$ ]] || tell "pipeline not started: Claude Code gave no agent_id"
mkdir -p "$ST"
n=$(jq -rs 'map(select(.type == "user"))[0].message.content | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join(" ")) end' "$tr" 2>/dev/null |
  grep -oiEm1 'task #[0-9]+' | tr -dc 0-9)
[ -n "$n" ] || tell "pipeline not started: the $type's prompt names no task ('Task #N')"
top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || tell "pipeline not started: $cwd is not a git checkout"
export FORGE_WORK=${top%%/.claude/worktrees/*}
key=${FORGE_APP:-$(wfcfg .app)}; key=${key//\//_}-t$n; strikes=$ST/strikes-$id; packet=$FORGE_WORK/.claude/wf/review/t$n.md
note=$ST/note-$key; printf 'running since %s\n' "$(date +%H:%M:%S)" >"$note"
trap '[ -z "${detached:-}" ] && [ "$(cut -c1-7 "$note" 2>/dev/null)" = running ] && echo "the hook ended without a word for the operator (nothing to ship, or it failed)" >"$note"; rm -f "$BODY"' EXIT
strike() { # MESSAGE: back to the agent (it continues); after MAX rounds the hook gives up
  local k=$(( $(cat "$strikes" 2>/dev/null || echo 0) + 1 )); echo "$k" >"$strikes"
  [ "$k" -le "$MAX" ] || { rm -f "$strikes"; tell "pipeline stopped after $MAX rounds with the $type of task $n: $1"; }
  printf 'the %s of task %s was sent back (round %s of %s): %s\n' "$type" "$n" "$k" "$MAX" "${1%%$'\n'*}" >"$note"
  echo "$1" >&2; exit 2; }
done_() { rm -f "$strikes"; tell "$1"; }
tool_input() { # NAME: the input of the agent's last call of that tool, from its transcript
  jq -rcs --arg n "$1" '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and .name == $n)] | last | .input // empty' "$tr" 2>/dev/null; }
[ -n "$last" ] || last=$(tool_input SubagentHandback | jq -r '.message // empty' 2>/dev/null)   # the final message of an agent that hands back with SubagentHandback is the call's message
head_of() { "$FORGE" review pr-show "$1" | sed -n '1s/.* head=\([0-9a-f]*\)$/\1/p'; }
merged() { local o; o=$("$FORGE" dev pr-show "$1") && [[ ${o%%$'\n'*} == *" merged=true "* ]]; }   # (no `| head -1`: under pipefail its SIGPIPE to the forge tool made this always false)
needs_review() { # PR: a changed file is in a class with an approver (.claude/wf.json)
  local cls; cls=$(jq -r '.risk | to_entries[] | select(.value.approver) | .key' "$HERE/../wf.json" | tr '\n' '|')
  "$FORGE" review pr-show "$1" | grep '^files:' | grep -qE " (${cls%|}):"; }
changed() { git status --porcelain -z --untracked-files=all --no-renames | while IFS= read -r -d '' e; do printf '%s\n' "${e:3}"; done; }
ci_rows() { # one line per CI unit (ci.components of .claude/wf.json; a project without them has one, named ci, at the root): name, path, format, fast, separated by \x1f
  jq -r '.ci as $c | ($c.components // [{name: "ci", path: "."}])[] | [.name, .path, (.format // $c.format // ""), (.fast // $c.fast // "make ci-fast")] | join("\u001f")' "$HERE/../wf.json"; }
under() { # PATH: stdin's files that are in the folder PATH, relative to it (all of them for "."); a component's files
  local f; while IFS= read -r f; do if [ "$1" = . ]; then printf '%s\n' "$f"; elif [ "${f#"$1"/}" != "$f" ]; then printf '%s\n' "${f#"$1"/}"; fi; done; }

reapply() { # main moved and the branch conflicts with it: put the change on main's files, conflict markers included, for the developer
  local base; base=$(git merge-base HEAD refs/wf/main) && git diff --binary "$base" HEAD >"$ST/$key.patch" || tell "pipeline stopped: cannot rebase agent/t$n"
  git reset -q --hard refs/wf/main && { git apply --3way "$ST/$key.patch" >/dev/null 2>&1; git reset -q; }
  strike "main moved and your change conflicts with it. Your files now hold main's version with your change applied, and conflict markers (<<<<<<< ======= >>>>>>>) where both changed: $(git diff --name-only | tr '\n' ' ')
Resolve the markers, keeping both intents, and finish again."
}

pack() { # PR: the review packet the reviewer reads; the head its verdict binds to stays in the state folder
  local head d; head=$(head_of "$1"); d=$("$FORGE" review pr-diff "$1") || return 1
  mkdir -p "${packet%/*}" && echo "$head" >"$ST/$key.head"
  printf '# Review of task #%s\n\nPR #%s at %s, branch agent/t%s. The branch files are in %s/\n\n~~~~~diff\n%s\n~~~~~\n' \
    "$n" "$1" "$head" "$n" "${top#"$FORGE_WORK"/}" "$d" >"$packet"
}

implement() {
  local b=agent/t$n cur out rc pr s ups log bad subj fast ci review labels rv_agent rv_op msg
  case $top in */.claude/worktrees/*) ;; *) tell "pipeline not started: the developer did not work in a worktree ($top)";; esac
  cd "$top" || exit 0
  cur=$(git symbolic-ref --short HEAD 2>/dev/null) || tell "pipeline not started: detached HEAD in $top"
  if [ -n "$(changed)" ]; then
    bad=$(changed | python3 "$HERE/paths.py" outside ${zone:+--zone "$zone"} | tr '\n' ' ')
    [ -z "$bad" ] || tell "pipeline not started: the developer of task $n changed files outside its zone: $bad"
    bad=$(changed | while IFS= read -r f; do [ -f "$f" ] && grep -qE '^(<<<<<<<|>>>>>>>)( |$)' "$f" && printf '%s ' "$f"; done)
    [ -z "$bad" ] || strike "Conflict markers are left in: $bad. Resolve them and finish again."
    subj=$(printf '%s\n' "$last" | sed -e 's/^[[:space:]>*#`-]*//' -e 's/[[:space:]`*]*$//' | grep -m1 . | cut -c1-72)   # the first line of the final message
    while IFS=$'\x1f' read -r _ path fmt _; do   # the project's formatter (ci.format of .claude/wf.json, or its component's) on the files the developer changed in that folder, jailed: style never reaches the check
      [ -n "$fmt" ] || continue
      mapfile -t files < <(changed | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done | under "$path")
      [ ${#files[@]} -eq 0 ] || "$HERE/jail.sh" "$top" sh -c "cd '$path' && $fmt" fmt "${files[@]}" >/dev/null 2>&1 </dev/null || true   # a failing formatter is the quick check's to report
    done < <(ci_rows)
    if [ "$cur" != "$b" ]; then
      git show-ref -q --verify "refs/heads/$b" && tell "pipeline not started: branch $b already exists (is another developer on task $n?)"
      git switch -q -c "$b" || tell "pipeline not started: cannot create $b in $top"
    fi
    git add -A && git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=bot-dev \
      -c "user.email=bot-dev@$EMAIL_DOMAIN" commit -q -m "${subj:-task $n}" ||
      tell "pipeline stopped: commit failed in $top"
  elif [ "$cur" != "$b" ]; then exit 0   # nothing changed, nothing to ship
  elif [ -f "$ST/$key.head" ] && [ "$(git rev-parse HEAD)" = "$(cat "$ST/$key.head")" ]; then   # resumed after a review, no new change: do not ask for the same review again
    strike "Nothing changed since the review of task $n (the PR is still at ${cur:+$(git rev-parse --short HEAD)}). Address the reviewer's comments as the operator gave them to you: change the files, then finish again. If you were given no comments, say so in your final message."
  fi
  out=$("$FORGE" dev sync 2>&1); rc=$?   # a branch cut from an older main would be blocked at the merge
  [ $rc = 3 ] && reapply; [ $rc = 0 ] || tell "pipeline stopped (task $n): $out"
  # the architecture model (ci.model), after the rebase so that it is made from the files main will hold: it runs jailed when the task changed class B files;
  # it may write class A files only (docs/), which are amended into the developer's commit. A failing command leaves the model as it was.
  model=$(wfcfg '.ci.model // empty'); cls=$(git diff --name-only "$(git merge-base HEAD refs/wf/main)" HEAD | python3 "$HERE/paths.py" classify)
  if [ -n "$model" ] && grep -q '^B ' <<<"$cls"; then
    "$HERE/jail.sh" "$top" sh -c "$model" >/dev/null 2>&1 || true
    bad=$(changed | python3 "$HERE/paths.py" outside | tr '\n' ' ')
    if [ -n "$bad" ]; then git checkout -q -- . && git clean -fdq; tell "pipeline stopped (task $n): ci.model wrote outside the agents' zone: $bad(change it with wf/apply.sh)"; fi
    if [ -n "$(changed)" ]; then
      git add -A && git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=bot-dev -c "user.email=bot-dev@$EMAIL_DOMAIN" commit -q --amend --no-edit || tell "pipeline stopped: commit failed in $top"
    fi
  fi
  # hooks run outside any sandbox and the quick check runs code the agent wrote: jail it (read-only root, no network, no home)
  # (with components, the quick check of each one whose folder the change touches; a change outside every component has nothing to check here, the CI runs them all)
  touched=$(git diff --name-only "$(git merge-base HEAD refs/wf/main)" HEAD)
  while IFS=$'\x1f' read -r name path _ fast; do
    [ -n "$(under "$path" <<<"$touched")" ] || continue
    out=$("$HERE/jail.sh" "$top" sh -c "cd '$path' && $fast" 2>&1 </dev/null) || strike "$fast is failing$([ "$name" = ci ] || echo " (component $name)"), fix the files and finish again:
$(tail -n 30 <<<"$out")"
  done < <(ci_rows)
  labels=$("$FORGE" dev task-labels "$n") || tell "pipeline stopped (task $n): cannot read the task's labels"   # review:agent, review:operator: the operator's policy asks for a review
  rv_agent=; rv_op=; grep -qx 'review:agent' <<<"$labels" && rv_agent=1; grep -qx 'review:operator' <<<"$labels" && rv_op=1
  out=$("$FORGE" dev push --force-with-lease 2>&1) || tell "pipeline stopped (task $n): push refused: $out"
  pr=$("$FORGE" dev pr-of) || tell "pipeline stopped (task $n): cannot look up the PR"
  if [ -z "$pr" ]; then
    out=$("$FORGE" dev pr-open "$(git log -1 --format=%s)" "$n" 2>&1) || tell "pipeline stopped (task $n): PR not opened: $out"
    pr=$(sed -n 's/^PR #\([0-9]*\) .*/\1/p' <<<"$out")
    "$FORGE" dev task-status "$n" in-review >/dev/null 2>&1
  fi
  if [ -n "$rv_agent" ]; then "$FORGE" dev review-request "$pr" bot-review >/dev/null 2>&1 || tell "pipeline stopped (task $n): cannot ask bot-review for the review of PR #$pr"; fi   # the forge holds the merge until it reviews
  if [ -n "$rv_op" ]; then "$FORGE" dev review-request "$pr" operator >/dev/null 2>&1 || tell "pipeline stopped (task $n): cannot ask the operator for the review of PR #$pr"; fi
  "$FORGE" dev automerge "$pr" >/dev/null 2>&1   # right after the push, while CI is pending: from now on the forge merges by itself
  # Wait for CI, but hand the developer back before its cached context expires (5 minutes after its last request), so that
  # feedback reaches it warm: WAIT seconds from the start of this hook. A PR without approval that falls behind main (another PR
  # merged) is brought up to date and its merge scheduled again, up to 3 times: the forge never merges an outdated branch.
  ups=0; s=pending; review=; needs_review "$pr" && review=1; [ -z "$rv_agent" ] || review=1
  while [ "$SECONDS" -lt $((WAIT - TAIL)) ]; do
    s=$("$FORGE" dev ci-wait "$pr" 20 | sed -n 's/^ci: \([a-z]*\) .*/\1/p')
    if [ "$("$FORGE" dev pr-behind "$pr")" = behind ] && [ "$ups" -lt 3 ]; then
      "$FORGE" dev update-branch "$pr" >/dev/null 2>&1 && "$FORGE" dev automerge "$pr" >/dev/null 2>&1; ups=$((ups + 1)); continue
    fi
    case $s in
      success)   # a PR that needs a review is the reviewer's now (its approval updates the branch first); one that needs none is
        # watched until it is merged, so that it is updated if another merge leaves it behind main
        [ -n "$review$rv_op" ] && break; merged "$pr" && break; sleep 5;;
      failure|error)   # a run cancelled by a newer one (an update of the PR) reports failure for a moment: believe it only if it stays
        sleep 15; s=$("$FORGE" dev ci-wait "$pr" 1 | sed -n 's/^ci: \([a-z]*\) .*/\1/p'); case $s in failure|error) break;; esac;;
    esac
  done
  case $s in
    failure|error)
      log=$("$FORGE" dev ci-log "$pr" 2>&1 | tail -n 40)
      # a job that could not even fetch its actions is a network problem of the environment: tell the operator, do not send the agent after it
      grep -qiE 'could not resolve host|dns server refused|could not fetch remote' <<<"$log" && tell "PR #$pr: CI failed on the network (the runner could not fetch its actions), not on the code: re-run the CI"
      strike "CI is red on PR #$pr. Log:
$log
Fix the files and finish again.";;
  esac
  ci="CI green"; [ "$s" = success ] || ci="CI still running (if it turns red: .claude/hooks/forge dev ci-log $pr, and give the log to the same developer)"
  if [ -n "$review" ]; then
    pack "$pr" || tell "PR #$pr (task $n): $ci, but the review packet could not be written"
    model=$(jq -rs '[.[] | select(.type == "assistant") | .message.model // empty] | last // empty' "$tr" 2>/dev/null)   # the reviewer runs on the model the developer ran on
    if WF_REVIEW_MODEL=$model "$HERE/review-run.sh" start "$n"; then   # the independent reviewer (review-run.sh) runs on its own and gives the word when it is done: the note stays "running"
      detached=1; printf 'running: the pipeline started the reviewer of task %s at %s (PR #%s, %s)\n' "$n" "$(date +%H:%M:%S)" "$pr" "$ci" >"$note"
      jq -nc --arg m "[pipeline] PR #$pr (task $n): $ci; the pipeline started the reviewer. Its word: wf/status.sh $FORGE_WORK --wait $n" '{systemMessage: $m}'; exit 0
    fi
    msg="PR #$pr (task $n): $ci; it needs a review. Next: start the reviewer with 'Review task #$n.'"
    [ -z "$rv_op" ] || msg+=" It also waits for the operator's review: read the diff (.claude/hooks/forge review pr-diff $pr), then approve it with wf/approve.sh $FORGE_WORK $pr."
    done_ "$msg"
  fi
  [ -z "$rv_op" ] || done_ "PR #$pr (task $n): $ci; it waits for the operator's review (the task is marked high risk). Next: read the diff (.claude/hooks/forge review pr-diff $pr), then approve it with wf/approve.sh $FORGE_WORK $pr, or send your comments to the same developer."
  merged "$pr" && done_ "PR #$pr (task $n): CI green, merged"
  done_ "PR #$pr (task $n): $ci; no review needed, the forge merges it by itself"
}

review() {
  local v body sha pr head out
  [ -n "$last" ] || last=$(jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] | last // ""' "$tr" 2>/dev/null)
  v=$(printf '%s\n' "$last" | grep -m1 . | sed -n 's/^[[:space:]*`]*verdict:[[:space:]]*\([a-z-]*\).*/\1/p')
  body=$(printf '%s\n' "$last" | awk 'f; NF && !f {f = 1}')   # everything after the verdict line
  body=$(FW=$FORGE_WORK python3 -c 'import os, re, sys; fw = os.environ["FW"]; t = sys.stdin.read(); t = re.sub(re.escape(fw) + r"/\.claude/worktrees/[\w-]+/", "", t); sys.stdout.write(t.replace(fw + "/", ""))' <<<"$body")   # paths in a review are relative to the project root
  [[ $v == approve || $v == request-changes ]] || strike "Your final message must start with 'verdict: approve' or 'verdict: request-changes', then your comments."
  [ "$v" = approve ] || [ -n "${body//[[:space:]]/}" ] || strike "request-changes needs your comments after the verdict line."
  [ -f "$ST/$key.head" ] || tell "review of task $n not posted: there is no review packet (the developer's pipeline has not finished)"
  sha=$(cat "$ST/$key.head")
  pr=$("$FORGE" review pr-of "agent/t$n") && [ -n "$pr" ] || tell "review of task $n not posted: agent/t$n has no open PR"
  head=$(head_of "$pr")
  [ "$head" = "$sha" ] || strike "PR #$pr moved on since your packet (head ${head:0:7}, you read ${sha:0:7}): read .claude/wf/review/t$n.md again and give your verdict again."
  if [ "$v" = approve ]; then
    out=$("$FORGE" dev update-branch "$pr" 2>&1) || tell "review of task $n not posted: $out"
    if [ "$out" = updated ]; then   # main moved while the PR waited: the new head carries the approval, the merge is scheduled again
      sha=$(head_of "$pr"); "$FORGE" dev automerge "$pr" >/dev/null 2>&1
    fi
  fi
  out=$("$FORGE" review "$v" "$pr" "$sha" - <<<"$body" 2>&1) || tell "review of task $n not posted: $out"
  if [ "$v" = approve ]; then
    rm -f "$ST/$key.head" "$packet"
    "$FORGE" review pr-show "$pr" | grep -q 'operator:REQUEST_REVIEW' && done_ "PR #$pr (task $n): $out. It still waits for the operator's review: read the diff (.claude/hooks/forge review pr-diff $pr), then approve it with wf/approve.sh $FORGE_WORK $pr."
    for _ in 1 2 3 4 5 6 7 8 9 10; do merged "$pr" && break; sleep 3; done   # the forge merges within seconds when CI is green: report it when it has, so a task that builds on this one starts after
    merged "$pr" && done_ "PR #$pr (task $n): $out. Merged."
    done_ "PR #$pr (task $n): $out. The forge merges it when CI is green."
  fi
  # the developer has no way to the forge, so the comments travel in the message: the operator hands them over as they are
  nextrv="then start a new reviewer with 'Review task #$n.'"; [[ $id == pipeline-* ]] && nextrv="the pipeline starts the next review itself"
  done_ "PR #$pr (task $n): $out. Next: send the comments below, as they are, to the same developer (SendMessage); $nextrv.
Reviewer's comments:
${body:0:3000}"
}

"$stage"
