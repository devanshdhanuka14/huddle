# Huddle — instructions for Claude Code

Huddle is a multiplayer, crash-proof workspace for AI agent runs.
Full design: docs/build-plan.md. Read the relevant section before any task.

YOUR ROLE in this repo:
- Scaffolding: create folders, empty files, project setup (go.mod, uv project, Vite app)
  exactly as instructed.
- Frontend (web/): build the UI to match the REST and WebSocket contract in
  docs/build-plan.md (Section 8). The sync module (web/src/sync/) and the reducer
  (web/src/state/) must follow the plan exactly and have Vitest tests.
- Mechanical tasks only when explicitly asked.

RULES:
- Do NOT modify anything in server/, worker/, proto/ or deploy/ unless the task
  explicitly says so. Devansh writes those files himself from the build chats.
- Never change an API, event type or protocol message. If the frontend needs a
  change, stop and describe it instead.
- After each task, list every file you created or changed.