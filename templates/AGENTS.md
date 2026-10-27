# AGENTS.md

Instructions for AI agents working in this repository. Permissions are enforced in `opencode.jsonc`, not here.

## Codebase map

<!-- TODO: filled by OpenCode `/init` (setup-guide.md step 7). Keep it short: what each top-level directory holds, where the entry points are. -->

| Directory | Contents |
| --- | --- |
| TODO | TODO |

## Build and test

<!-- TODO: build system, build directory, how to build one target, how to run one test. -->

- Run builds and tests as background shell commands (`background: true`): foreground commands stop after 2 minutes. Don't edit files until the result arrives. The result shows the end of the output and the path of the full output.
- A prebuild of your worktree starts with the session. Your first build or test command stops it if it is still running and builds incrementally from there.
- Do not run a full build or the full test suite unless the task asks for it.

## Rules

- Lexers: edit the flex sources (`.l`); the build regenerates the lexer `.c` files.
- Never query or wait for Jenkins. CI runs after you finish.
- Never change the Git identity or Git config (no `git config`, no `git -c user.*`). If a commit fails, report the error and stop.
- Search only inside your worktree; never search `~`, `/` or other checkouts.
- For a question that needs more than about five files read (where is X handled, how does Y flow), ask the `explore` subagent and work from its answer.
- Before you change code, say how you will check the fix (reproduce the problem first); afterwards, show that same check passing.
- Keep changes within the task's scope. Commit when the build and the tests for your change pass, then stop.
- Stop any server or other background process you started before you finish, and name it in your report.
- If you are blocked or the task is unclear, say so and stop instead of guessing.

## Tasks and reports

- Each task has its own worktree, named after the task ID (`TASK-<n>` from Taiga, `VM-<n>` local), on branch `agent/<task-id>`. Your task ID is the name of your working directory.
- To start another task from a session, create the worktree with `worktree_create` using the task ID as its name, then `session_move` into it. Don't create branches yourself.
- A bug outside your task's scope: don't fix it. Run `agent-task.sh new "<one-line title>" --parent <your task ID>` and name the new ID in your report.
- Before you stop, write `.agent/report.md` in your worktree: what you changed, which checks ran and their result, what is left open, and new task IDs. Scripts archive it; it is never committed.
