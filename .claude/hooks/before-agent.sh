#!/bin/bash
# PreToolUse hook on the Agent tool, in the operator's session: before a subagent's worktree is cut, the forge's main goes into the
# project checkout (forge dev fetch-main). Claude Code cuts the worktree from origin/main and was seen not to fetch it first, so a
# task that builds on a merged one (the forge merges by itself, after the hook has ended) would start on stale code.
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
export FORGE_WORK=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
out=$("$HERE/forge" dev fetch-main 2>&1) || echo "{\"systemMessage\": \"[pipeline] the forge's main could not be brought into the checkout, the new worktree may be stale: ${out//\"/\'}\"}"
exit 0
