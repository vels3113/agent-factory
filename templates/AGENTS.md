# AGENTS.md

Instructions for AI agents working in this repository. Permissions are enforced in `opencode.jsonc`, not here.

## Codebase map

<!-- TODO: filled by OpenCode `/init` (setup-guide.md step 7). Keep it short: what each top-level directory holds, where the entry points are. -->

| Directory | Contents |
| --- | --- |
| TODO | TODO |

## Build and test

<!-- TODO: build system, build directory, how to build one target, how to run one test. -->

- Check your change with `agent-check.sh` only: `agent-check.sh [--preset <name>]... [--suite <name>] [<test>...]`. It builds incrementally (the default preset unless you name presets) and runs the tests you name, with short output (first errors, failing tests) and the path of the full log. `agent-check.sh --list` shows the presets CI builds, the test suites and their tests. It is on `PATH`: run it as `agent-check.sh`, not `./agent-check.sh`.
- Run it as a background shell command (`background: true`). Don't edit files until its result arrives.
- Exit codes: 0 passed, 1 build failed, 2 tests failed, 5 files changed during the check (run it again). 3 (setup error) or 4 (timed out, or no free build slot): report it and stop, don't change code to work around it.
- Do not run a full build or the full test suite unless the task asks for it.

## Rules

- Lexers: edit the flex sources (`.l`); the build regenerates the lexer `.c` files.
- Never query or wait for Jenkins. CI runs after you finish.
- Never change the Git identity or Git config (no `git config`, no `git -c user.*`). If a commit fails, report the error and stop.
- Keep changes within the task's scope. Commit when `agent-check.sh` passes, then stop.
- If you are blocked or the task is unclear, say so and stop instead of guessing.

## Tasks and reports

- Each task has its own worktree, named after the task ID (`TASK-<n>` from Taiga, `VM-<n>` local), on branch `agent/<task-id>`. Your task ID is the name of your working directory.
- To start another task from a session, create the worktree with `worktree_create` using the task ID as its name, then `session_move` into it. Don't create branches yourself.
- A bug outside your task's scope: don't fix it. Run `agent-task.sh new "<one-line title>" --parent <your task ID>` and name the new ID in your report.
- Before you stop, write `.agent/report.md` in your worktree: what you changed, which checks ran and their result, what is left open, and new task IDs. Scripts archive it; it is never committed.
