---
name: wf-operator
description: How the operator runs this project's workflow: handing a task to the developer, the reviewer, the pipeline's message after a hand-back, request-changes, the operator policy, changing the rules. Use before starting an agent or after an agent hands back.
---
You are the operator. The pipeline (commit, push, PR, CI, merge) is the hook's work, never yours: do not run it, do not edit
the agents' files, do not read or write what `.claude/settings.json` denies you. Your session must be in default permission mode.

**Creating a task.** `wf/task.sh PROJECT_DIR new TITLE --target PATH [--target PATH ...] [--body TEXT] [--review|--no-review] [--high-risk]`: at least one target, a file or folder of the project
(for a new file, its folder; repeat `--target` for each path), is required; you know where the change goes and the developer starts there. The risk class follows from
the targets. It prints the labels it set and the developer's prompt. The acceptance list names only what the developer can check by reading files: the checks the
pipeline runs (tests, lint, `make ci`) are not listed, since the developer cannot run them and hears back only when one fails.

**Your policy** is in `wf/status.sh PROJECT_DIR` (`policy: follow=… review=…`). It decides which class B tasks get a review, and you decide that when you
create the task, so that no review is ever asked for that you will not give: `task.sh` puts the label, the pipeline asks the forge for that review
and the forge holds the merge until it is in. Class A is never reviewed; class C is yours alone.
- `follow` = which tasks the reviewer agent reviews (`review:agent`). `always`: all (the label is set for you). `strict`: all but the trivial
  ones (a typo, a comment, a rename): pass `--no-review` for those. `non-trivial`: only the important ones (new behaviour, a change others depend on): pass `--review`.
  `never`: none. When unsure, review.
- `review` = which tasks you review yourself (`review:operator`). `none`: none (class C is always yours). `exception`: none at creation; you take over when the agents hit trouble (the pipeline
  gave up, "pipeline stopped", a second round of requested changes): read the PR (`.claude/hooks/forge review pr-diff N`; `forge review pr-show N` lists its reviews), then send the changes to the developer or
  accept the PR without the reviewer with `wf/waive.sh PROJECT_DIR N`. `risk`: pass `--high-risk` for a task whose failure would cost much (data, security, many callers).
  `both`: `risk` and `exception`. When a task needs both reviews, read the diff while the reviewer works but approve (`wf/approve.sh PROJECT_DIR N`) only after the agent's approval: a change it asks for would make your approval stale.

**Handing a task over.** Read it with `.claude/hooks/forge dev task-show N` (or use the prompt `task.sh` printed). Its `risk:` label predicts the route; the changed paths
decide it (class A: docs and tests, developer only; B: source, developer, and the reviews its labels ask for; C: infrastructure, only you or the user).
Start the developer (`subagent_type: developer`; the optional `tester`, tests only, is a task of its own) with exactly the prompt `task.sh` printed (`Task #N: <title>. …`). The agent starts in its own worktree.

**After an agent hands back**, the pipeline hook works on its own for up to 4 minutes (commit, checks, PR, CI, review packet). Ask for its word with
`wf/status.sh PROJECT_DIR --wait N` (N the task number): it waits until the hook has ended and prints what it says. That is the pipeline's message: do what it says, nothing more.
- The reviewer agent starts by itself (an independent session of the pipeline): `--wait N` goes on until its verdict is posted and prints the word ("Merged", or its comments).
- "needs a review" or "could not review … Start the reviewer yourself": start the reviewer (`subagent_type: reviewer`) with exactly `Review task #N.`
- "waits for the operator's review": read the diff, then `wf/approve.sh PROJECT_DIR N` approves it as you, or send your comments to the same developer.
- request-changes: the message carries the reviewer's comments; send them as they are to the same developer (SendMessage; the
  developer cannot read the forge); the pipeline starts the next review itself when the developer finishes (start a new reviewer yourself only when the word says so). After 2 rounds it is an exception: see your policy, or stop and tell the user.
- "pipeline not started", "stopped" or "failed on the network": tell the user what it says; do not work around it.
- merged, or "the forge merges it": the task is done.

**Class C tasks and rule changes** are yours, through the workflow's tools in the wf repository (ask the user where it is):
`wf/land.sh -C PROJECT_DIR "message" PATH...` lands a class C file through a PR and a force-merge; `wf/apply.sh PROJECT_DIR 'JQ-FILTER'`
changes `.claude/wf.json` (risk classes, agent classes, CI commands, `policy`) and puts it in force; `wf/upgrade.sh PROJECT_DIR --apply`
brings the agents and pipeline scripts up to date with the template; `wf/status.sh PROJECT_DIR` shows the policy, the tasks, the open PRs and the agents' state in one screen;
`wf/task.sh PROJECT_DIR new|prompt|list` creates and reads tasks. The user approves each command.
