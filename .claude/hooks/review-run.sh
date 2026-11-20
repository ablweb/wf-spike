#!/bin/bash
# The independent reviewer. A reviewer subagent belongs to the operator's session; this one belongs to the pipeline: when a PR needs the
# reviewer agent the pipeline hook calls `review-run.sh start N`, which runs `run N` in the background (own session, so the hook ends
# at once). `run` starts a headless Claude Code session with the review role's agent file, the same tools and the same environment
# text (agent-start.sh) a subagent gets, lets it read the review packet, and feeds its final message to the pipeline hook as the
# reviewer's SubagentStop: the verdict, the head check, the review, the merge wait and the word to the operator are the review stage
# of agent-done.sh, unchanged. It runs on the model the developer ran on (WF_REVIEW_MODEL, from the developer's transcript). Nothing but the project's own settings governs it (--setting-sources project, no MCP server, dontAsk).
#   start N   exit 1 when this project asks the operator to start the reviewer (agents.roles.<role>.start: operator) or there is no claude binary
#   run N     the background part
set -uo pipefail
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")"); . "$HERE/lib.sh"
mode=${1:-}; n=${2:-}; [[ $n =~ ^[0-9]+$ ]] || exit 2
role=$(jq -r '.agents.roles // {} | to_entries[] | select((.value | if type == "object" then .stage else . end) == "review") | .key' "$HERE/../wf.json" | head -n1)
claude=${WF_CLAUDE:-${CLAUDE_CODE_EXECPATH:-$(command -v claude)}}
case $mode in
  start)
    [ -n "$role" ] && [ -x "${claude:-}" ] || exit 1
    [ "$(jq -r --arg r "$role" '.agents.roles[$r] | if type == "object" then .start // "pipeline" else "pipeline" end' "$HERE/../wf.json")" = pipeline ] || exit 1
    setsid -f "$HERE/review-run.sh" run "$n" </dev/null >/dev/null 2>&1; exit 0;;
  run) ;;
  *) exit 2;;
esac

cd "${FORGE_WORK:?}" || exit 1
ST=$STATE/hook; mkdir -p "$ST"; app=$(wfcfg .app); key=${FORGE_APP:-$app}; key=${key//\//_}-t$n; note=$ST/note-$key
exec 9>"$ST/review-$key.lock"; flock -n 9 || exit 0   # one reviewer per task at a time
word() { printf '%s\n' "$1" >"$note"; notify "[$app] $1"; exit 0; }
fail() { word "the pipeline's reviewer of task $n could not review: $1. Start the reviewer yourself with 'Review task #$n.'"; }

tools=$(sed -n '1,/^---$/{s/^tools:[[:space:]]*//p}' ".claude/agents/$role.md" | sed -n 1p | tr -d ' ')
ctx=$(jq -nc --arg t "$role" '{agent_type: $t}' | "$HERE/agent-start.sh" | jq -r '.hookSpecificOutput.additionalContext // empty')
out=$(timeout 240 "$claude" -p "Review task #$n." --agent "$role" ${WF_REVIEW_MODEL:+--model "$WF_REVIEW_MODEL"} --tools "$tools" --permission-mode dontAsk --setting-sources project --strict-mcp-config \
  --append-system-prompt "$ctx" --output-format json --no-session-persistence </dev/null 2>"$ST/review-$key.err") || fail "its session ended with an error ($(tail -n 1 "$ST/review-$key.err" | cut -c1-120))"
jq -c '{ts: now | floor, models: (.modelUsage // {} | keys), requests: .num_turns, input: .usage.input_tokens, output: .usage.output_tokens, cache_read: .usage.cache_read_input_tokens,
  cw5: (.usage.cache_creation.ephemeral_5m_input_tokens // 0), cw1h: (.usage.cache_creation.ephemeral_1h_input_tokens // 0)}' <<<"$out" >>"$ST/review-$key.usage" 2>/dev/null   # what it cost, for the benchmark (bench.sh collect)
result=$(jq -r 'if .is_error then empty else .result // empty end' <<<"$out" 2>/dev/null)
[ -n "$result" ] || fail "its session gave no answer"
# a session's final text may carry its reasoning before the verdict (a subagent hands in only the verdict): from the last verdict line on
v=$(awk '/^[[:space:]*`>-]*verdict:[[:space:]]*(approve|request-changes)/ {buf = ""; f = 1} f {buf = buf $0 "\n"} END {printf "%s", buf}' <<<"$result"); [ -z "$v" ] || result=$v

# the review stage of the pipeline hook, as the SubagentStop of a reviewer that is not a subagent
tr=$ST/.tr-pipeline-$key.jsonl; id=pipeline-t$n; rm -f "$ST/strikes-$id"
jq -nc --arg p "Review task #$n." '{type: "user", message: {role: "user", content: $p}}' >"$tr"
jq -nc --arg t "$role" --arg c "$FORGE_WORK" --arg i "$id" --arg tr "$tr" --arg l "$result" \
  '{hook_event_name: "SubagentStop", agent_type: $t, cwd: $c, agent_id: $i, agent_transcript_path: $tr, last_assistant_message: $l}' |
  "$HERE/agent-done.sh" >/dev/null 2>"$ST/review-$key.err"; rc=$?
rm -f "$tr" "$ST/strikes-$id"
[ $rc != 2 ] || fail "its answer was refused ($(head -n 1 "$ST/review-$key.err" | cut -c1-120)); it said: $(tr '\n' ' ' <<<"${result:0:200}")"
