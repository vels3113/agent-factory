# AGENTS.md

Instructions for AI agents working in this repository. Permissions are enforced in `opencode.jsonc`, not here.

## Codebase map

<!-- TODO: filled by OpenCode `/init` (setup-guide.md step 7). Keep it short: what each top-level directory holds, where the entry points are. -->

| Directory | Contents |
| --- | --- |
| TODO | TODO |

## Build and test

<!-- TODO: build system, build directory, how to build one target, how to run one test. -->

- Check your change with `agent-check.sh` only. It builds the affected target and runs targeted tests with short output.
- Do not run a full build or the full test suite unless the task asks for it.

## Rules

- Lexers: edit the flex sources (`.l`). Never edit the generated lexer `.c` files; the build regenerates them.
- Never edit build output or generated files.
- Never push, and never query or wait for Jenkins. CI runs after you finish.
- Keep changes within the task's scope. Commit when `agent-check.sh` passes, then stop.
- If you are blocked or the task is unclear, say so and stop instead of guessing.
