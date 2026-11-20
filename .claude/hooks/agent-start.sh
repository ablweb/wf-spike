#!/bin/bash
# SubagentStart hook (matcher: the roles of .claude/wf.json): tells the agent its environment in a few lines, as context before its
# first prompt. What it says depends on the pipeline stage the agent's role serves (agents.roles of .claude/wf.json: implement,
# review, report), not on its name; the tools are read from the agent's own file (.claude/agents/<name>.md, `tools:`), so the list
# is never written twice. It names no folder: what an agent may read or change is the system's business, not part of what it is told.
in=$(cat); type=$(jq -r '.agent_type // ""' <<<"$in")
f=${CLAUDE_PROJECT_DIR:-.}/.claude/agents/$type.md
[ -f "$f" ] || exit 0
stage=$(jq -r --arg t "$type" '.agents.roles[$t] // empty | if type == "object" then .stage else . end' "${CLAUDE_PROJECT_DIR:-.}/.claude/wf.json" 2>/dev/null)
tools=$(sed -n '1,/^---$/{s/^tools:[[:space:]]*//p}' "$f" | sed -n 1p)
case $stage in
  implement)
    role="You work in your own git worktree of the project and change its files. The pipeline does the rest: when you finish it commits your files, runs the project's quick check and CI, and sends you the log only if one fails; checklist items such as \`make ci\` is green are its to verify, not yours. The project's build and CI files are not part of your view. The task names its target files: start there."
    fin="Your final message is exactly one line, under 72 characters: the commit message. Nothing else is read.";;
  review)
    role="You review one pull request. The pipeline wrote its review packet at .claude/wf/review/t<N>.md (N is the task number of your prompt): the PR's diff as the forge has it, and the worktree that holds the branch's files (read them by path when you need the surrounding code)."
    fin="Your final message is the verdict: \`verdict: approve\` alone, or \`verdict: request-changes\` and one \`- <file>: <change>\` line per change that must be made before the merge (at most 8, file names relative to the project root). Nothing else is read.";;
  report)
    role="Nothing you do is committed or posted. Your final message goes to the operator as it is."
    fin="";;
  *) exit 0;;
esac
msg="Environment."; [ -z "$tools" ] || msg+=" Your tools: $tools."
case ",${tools// /}," in *,Bash,*) ;; *) msg+=" You have no shell, git or network, so you cannot run tests or the build: reason from the files.";; esac
jq -nc --arg m "$msg $role $fin" '{hookSpecificOutput: {hookEventName: "SubagentStart", additionalContext: $m}}'
