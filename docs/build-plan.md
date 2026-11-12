# Huddle — Build Plan

Working name. Final plan from the planning chat (Oct–Nov 2026). Decisions here change only by flagging and discussing them; record any change in STATUS.md.

---

## 1. Product spec

### What it is
A multiplayer, crash-proof workspace for long-running AI agent runs. One person starts an agent on a multi-step task ("compare 3 laptops under ₹80k for coding"). Others open the same link and watch each step live. Editors can send instructions mid-run ("only 16 GB RAM"), which the agent folds in at the next step. If a worker or server dies, the run resumes from its last saved step. Any run can be replayed step by step or forked from a completed step. The AI is the worker; the engineering is the system around it: an append-only event log, crash recovery, live sync to many viewers, and one agreed order for instructions from different people.

### Users and access
- **Owner:** creates the run (needs an invite code); has all editor rights.
- **Editor:** sends instructions, pauses, resumes, cancels, forks.
- **Viewer:** watches live and replays.
- Run creation requires an invite code, because LLM and search quotas are shared. Share links let people watch or steer existing runs only.
- Each run gets three random tokens at creation (owner, editor, viewer), stored as SHA-256 hashes.
- Display names are self-declared (typed once, kept in the browser) and never shown as verified identity.

### What a step is
One agent turn: the worker receives a context built from the log, makes **one** LLM call, runs at most **2** read-only tool calls the model asked for, and returns one result. Tool results are seen by the agent in the **next** step. Instructions only take effect between steps.

### Core flows
1. **Start:** owner enters a goal; the run is created, steps start, the URL is shareable immediately.
2. **Share:** copy the viewer or editor link.
3. **Watch:** live step timeline, current step status ("step 4 running on worker-2, attempt 1"), who's watching.
4. **Steer:** an editor sends an instruction; it shows as *queued*, then *applied at step N*.
5. **Pause / resume / cancel.**
6. **Survive a crash:** kill a worker → "worker lost, retrying (attempt 2)" → the run continues. Kill a server → clients reconnect and catch up with no gaps.
7. **Replay:** scrub through any run step by step; no LLM calls.
8. **Fork:** from any completed step, branch into a variant with a new instruction; the parent is untouched.
9. **Reconnect:** close the laptop, reopen; the timeline fills in what was missed, in order.

### Scope
- **MVP (weeks 1–6):** flows 1–7 and 9; real LLM plus `web_search` and `fetch_page`; step, tool and token caps; 2 server instances behind Caddy with Redis (pub/sub fan-out, presence, rate limits); correctness tests for every invariant; structured logs and `/metrics`; deployed (or tunnel fallback), README, 2-minute demo video. Fork (flow 8) is built in week 6 if weeks 1–5 are done, otherwise it is the first V2 item. The schema supports fork from week 1.
- **V2 (weeks 7–10):** fork if it slipped, Google sign-in, Grafana dashboards, load tests, polish.
- **V3 (optional):** LLM-written summaries of old history, token-by-token streaming, approvals plus side-effecting tools, managed cloud services migration.
- **Non-goals:** our own agent framework, LangChain/LangGraph, Kafka, Kubernetes, a separate workflow engine, CRDT text editing, tools with side effects, billing, mobile app, organisations/teams, rich-text co-editing, run templates, notifications, token streaming in the MVP.

---

## 2. Run and step lifecycles

### Vocabulary
- **Run:** one agent task. Runs one step at a time; step N+1 is created when step N completes.
- **Step:** one agent turn (see above).
- **Attempt:** one try at a step (max 3).
- **Lease:** a worker's time-limited right to run one attempt.
- **Event:** an immutable record of something that happened.
- **seq:** the event's position in its run's history: 1, 2, 3… with no gaps.

### Run lifecycle
States: `running`, `paused`, and the terminal states `completed`, `failed`, `cancelled`.

```
          create
            │
            ▼
       ┌─────────┐   pause    ┌────────┐
       │ running │ ─────────► │ paused │
       │         │ ◄───────── │        │
       └─────────┘   resume   └────────┘
            │                      │
            └──────────┬───────────┘
                       ▼
    completed  ·  failed  ·  cancelled
    (terminal: no way back; fork to continue)
```

| From → To | Trigger | Same transaction also does |
|---|---|---|
| (new) → running | `POST /runs` or a fork | `run_created`; step 1 (or the next step for a fork) created as `pending` |
| running → paused | Editor pauses | `run_paused`. The in-flight attempt finishes; no new leases |
| paused → running | Editor resumes | `run_resumed` |
| running/paused → cancelled | Editor cancels | `run_cancelled`; the pending or leased step becomes `cancelled`; late results rejected |
| running/paused → completed | A step completes with a final answer, or the step limit is reached | `run_completed {reason}` |
| running/paused → failed | Attempts exhausted, non-retryable error, or budget exceeded | `run_failed {reason}` |

- **Pause is a gate on leasing.** Nothing is interrupted. A paused run can still reach `completed` or `failed` because its in-flight attempt finishes. The UI shows "Paused · step 4 finishing", derived from a leased step on a paused run.
- **Cancel is immediate in the log.** No new leases are granted; the worker is told `CANCELLED` at its next heartbeat and aborts the LLM request; any late result is rejected (`STALE`). The provider may still finish and bill the request; the token reservation (Section 5) covers that cost. Covered by test C10.
- **Step limit:** the context builder tells the agent "this is your last step; give your final answer", so reaching `max_steps` normally ends as `completed {reason: step_limit}`.
- **Terminal is terminal.** Instructions on a finished run get `409` with the hint "fork from an earlier step".
- **Failed runs continue via fork** from the last completed step. No separate "retry run" transition. If fork feels wrong in the UI, a **Retry** button can be added as a UI layer that creates the fork and moves everyone to the new run; the data model stays the same.

### Step lifecycle
States: `pending`, `leased`, and the terminal states `completed`, `failed`, `cancelled`.

```
              lease (attempt +1)          report success
  pending ───────────────────► leased ─────────────────► completed
     ▲                            │
     │  failed or lease expired,  │
     └──── attempts left ─────────┤
                                  │  last attempt failed
                                  └──────────────────────► failed
                                                     (run fails too)

  pending or leased ── run cancelled ──► cancelled
```

| From → To | Trigger | Rule |
|---|---|---|
| (new) → pending | Run created, or previous step completed (same transaction) | `attempt = 0`, `available_at = now()` |
| pending → leased | Worker calls `LeaseStep` | Only if the run is `running`, `available_at ≤ now()`, the token reservation fits the caps, and the LLM rate-limit bucket has a token. `attempt += 1`. Writes `step_attempt_started` |
| leased → leased | Heartbeat | Extends the lease only if `status = leased` and the attempt matches. **No event.** Replies `OK`, `CANCELLED` or `LOST` |
| leased → completed | `CompleteStep(step, attempt)` | Only from the current lease holder. Writes `step_completed`, settles spend, creates the next step — one transaction |
| leased → pending | Retryable failure, or lease expired (reaper) | Only if `attempt < 3`. `available_at = now() + backoff`. Writes `step_attempt_failed` |
| leased → failed | Non-retryable error, or last attempt failed | Also writes `run_failed` |
| pending/leased → cancelled | Run cancelled | |

- **Fencing token = attempt number.** A lease is identified by `(step_id, attempt)`. `attempt` increments atomically on every new lease. Only the current lease holder may change a step.
- **Late completions are always rejected**, even if nobody re-leased the step yet. One invariant: only the current lease holder can change a step.
- **Duplicate vs stale:** the same attempt reporting again after success → `ALREADY_ACCEPTED`, no new events. An older attempt → `STALE`, result discarded.
- All lease times use the database clock (`now()`), never app-server clocks.

---

## 3. Event model

### Envelope
`run_id, seq, type, schema_version, actor {kind: user|worker|system, id, name}, payload (JSON), created_at`
- `created_at` is for display only; ordering always uses `seq`.
- `schema_version` lets old runs replay after payload formats change.
- Every payload is capped at 32 KB.

### Event types

| Type | Written by | Payload |
|---|---|---|
| `run_created` | API (create or fork) | goal, limits `{max_steps, max_tool_calls, max_tokens}`, model, `prompt_version`, `created_by`, `parent {run_id, fork_seq}` or null |
| `instruction_received` | API | `action_id` (client UUID), author `{name, role}`, text |
| `run_paused` / `run_resumed` | API | `action_id`, by |
| `run_cancelled` | API | `action_id`, by, `abandoned_step {no, attempt}` or null |
| `step_attempt_started` | Scheduler, at lease | `step_no`, attempt, `worker_id`, `context_through_seq`, `context_hash`, `lease_expires_at` |
| `step_attempt_failed` | Worker report or reaper | `step_no`, attempt, `error_class`, message, retryable, `retry_at` or null, usage or null |
| `step_completed` | `CompleteStep` | `step_no`, attempt, `applied_instruction_ids`, `one_line_summary`, `reasoning_summary`, `notes`, tool calls `[{name, args, status, result_excerpt, truncated, bytes_total}]`, `output_text`, `is_final`, usage `{input_tokens, output_tokens, est_cost}`, `latency_ms` |
| `run_completed` | Same transaction as the final step | reason (`final_answer` or `step_limit`), `final_step_no` |
| `run_failed` | Same transaction as the terminal failure | reason (`retries_exhausted`, `non_retryable`, `budget_exceeded`), `step_no`, message |

`error_class` values: `timeout`, `rate_limited`, `provider_error`, `malformed_output`, `context_too_long`, `auth_error`, `lease_expired`, `worker_error`.

**Not events:** heartbeats, presence, token streams, and anything on a parent run when it is forked. Rule of thumb: an event exists when a person would need to know about it later.

### Ordering rules
1. **One gap-free counter per run:** every append runs `UPDATE runs SET last_seq = last_seq + 1 … RETURNING last_seq` in the same transaction that inserts the event. A rolled-back transaction leaves no gap. (A Postgres sequence would leave permanent gaps on rollback, and clients would wait forever for them.)
2. Events are only appended, never updated or deleted, always in the same transaction as the state change they describe. A database trigger rejects `UPDATE`/`DELETE` on `events`.
3. Clients and the context builder order by `seq` only.
4. An event is visible (API, WebSocket, Redis) only after its transaction commits.
5. Lock order is always the run row, then the step row. The lease query uses `FOR UPDATE OF steps, runs SKIP LOCKED`; SKIP LOCKED never waits, so it can never take part in a deadlock.

The run-row lock is what serialises appends: two transactions appending to the same run take turns, and whoever locks first gets the lower seq. That is the authoritative order.

### Idempotency rules
1. Every user command carries a client-generated `action_id` (instructions, pause, resume, cancel, fork); run creation carries `client_request_id`. A partial unique index on `(run_id, payload->>'action_id')` guarantees a retry returns the original result instead of creating a second event.
2. Worker completions are identified by `(step_id, attempt)`: accepted, `ALREADY_ACCEPTED`, or `STALE`.
3. Every state change is a conditional write (compare-and-set): `UPDATE … WHERE status = 'leased' AND attempt = $n`, then check rows affected. One row → write the event. Zero rows → someone else won; do nothing. This is how two reapers race safely.

### Instruction semantics
- **Order:** the seq order of `instruction_received` events. Concurrent sends from two editors (even through different server instances) are ordered by who locks the run row first. Every viewer sees the same order because every viewer renders by seq.
- **Effect boundary:** each attempt records `context_through_seq` (`runs.last_seq` at lease time). Instructions at or below it are in that attempt's context; later ones wait for the next attempt. An instruction never interrupts an in-flight LLM call.
- **Retries re-capture the cutoff,** so a retried attempt includes instructions that arrived while the previous attempt was failing. Determinism holds because each attempt's cutoff is recorded.
- **UI:** *queued* when sent; *applied at step N* when that step's `step_completed` lists its id.
- **While paused:** accepted; applied at the first step after resume.
- **Finished runs:** `409` with hint "fork from an earlier step".
- **Conflicts:** not resolved by the system. The agent receives all instructions in seq order with authors, under a fixed rule: on conflict, the later instruction wins.
- **Limits:** 1,000 characters per instruction, 25 per run, Redis rate limit per share token.
- **Forks:** inherit parent events up to `fork_seq`, including not-yet-applied instructions (applied by the child's first step). The parent's later instructions never reach the child.

---

## 4. Database schema

| Table | Key columns | Keys and indexes |
|---|---|---|
| **runs** | `id` (UUIDv7), `status`, `goal`, `limits`, `model`, `prompt_version`, `parent_run_id`, `fork_seq`, `lineage_depth`, `last_seq`, `invite_code_id`, `client_request_id`, `created_at`, `updated_at` | PK `id`; unique `client_request_id`; index `parent_run_id`; partial index on `status` for `running`/`paused` |
| **events** | `run_id`, `seq`, `type`, `schema_version`, `actor`, `payload`, `created_at` | PK `(run_id, seq)`; partial unique `(run_id, payload->>'action_id')` where present; trigger rejects UPDATE/DELETE |
| **steps** | `id`, `run_id`, `step_no`, `status`, `attempt`, `max_attempts`, `lease_owner`, `lease_expires_at`, `available_at`, `completed_attempt`, `context_through_seq`, `created_at`, `updated_at` | Unique `(run_id, step_no)`; partial index `available_at` WHERE status='pending' (job queue); partial index `lease_expires_at` WHERE status='leased' (reaper) |
| **spend** | `run_id`, `invite_code_id`, `step_id`, `attempt`, `reserved_tokens`, `input_tokens`, `output_tokens`, `settled_at`, `created_at` | Unique `(step_id, attempt)`; index `run_id`; index `(invite_code_id, created_at)`. Cost of a row = actual tokens if settled, else the reservation |
| **access_tokens** | `run_id`, `role`, `token_hash`, `created_at`, `revoked_at` | Unique `token_hash` |
| **invite_codes** | `code_hash`, `label`, `daily_token_cap`, `created_at`, `disabled_at` | Unique `code_hash`. Each invite code is a "user" for the per-user cap. Created with an admin command (`make invite LABEL=… CAP=…`), which prints the code once |

**Source of truth:** Postgres holds all of it — `events` (history), `runs`/`steps` (current state, always changed in the same transaction as their events), `spend` (money), access tables. `runs.last_seq` must always equal the highest event seq for the run (invariant I1). Redis state (presence, rate buckets, pub/sub messages) is ephemeral and rebuildable. The browser's state is always computed from events.

**Migrations:** numbered goose SQL files with up/down; never edit an applied migration; run as a one-shot job, never at app startup; applied to an empty database in every CI run; add-first, remove-later so the previous code version keeps working during a deploy.

---

## 5. Execution guarantees, retries and spend

### The guarantee
**At-least-once execution, exactly-once commit:** a step's result is committed exactly once, even though its LLM call may run more than once. Duplicate calls only cost quota because every MVP tool is read-only. Never claim exactly-once LLM calls.

### Timings (configurable)

| Setting | Value |
|---|---|
| Lease length | 60 s (15 s in the demo config) |
| Heartbeat interval | 15 s |
| Single LLM request timeout | 45 s |
| Hard limit per attempt | 3 min (after this the server stops renewing the lease; the next heartbeat gets `LOST`) |
| Reaper interval | Every 5 s on each server instance |
| Max attempts per step | 3 |
| Delay before attempt 2 / 3 | 2 s / 15 s, ±20% jitter |

### Crash cases

| # | What happens | System behaviour | Cost |
|---|---|---|---|
| 1 | Worker dies before the LLM call | Lease expires, reaper requeues, next attempt runs | ≤ 60 s delay |
| 2 | Worker dies during the LLM call | Same as 1 | Provider may bill the abandoned call |
| 3 | Worker dies after the LLM replied, before reporting | Same as 1; attempt 2 calls the LLM again | Duplicate call |
| 4 | Server commits the result, reply to worker is lost | Worker retries `CompleteStep` with the same attempt → `ALREADY_ACCEPTED` | None |
| 5 | Server crashes mid-transaction | Rollback; worker's retry hits the other instance and is accepted | None |
| 6 | Lease expires while the worker still runs | Reaper requeues; worker's next heartbeat gets `LOST` and aborts; a direct report gets `STALE` | Duplicate call |
| 7 | Stale worker reports late | `STALE`, nothing written | None |
| 8 | Duplicate completion (same attempt) | `ALREADY_ACCEPTED`, nothing written | None |
| 9 | Run cancelled during an attempt | Heartbeat `CANCELLED`, worker aborts; late report `STALE` | Provider may bill |
| 10 | Postgres down | Lease/complete calls fail; workers retry `CompleteStep` up to 30 s; after recovery, expired leases are requeued; first commit wins, loser gets `STALE` | Possible duplicate |

| Mechanism | Protects against |
|---|---|
| Transaction | Half-written changes (5) |
| Fencing token (attempt) | Zombie and stale workers (6, 7, 9) |
| Idempotency (same attempt → ACK) | Lost replies and retries (4, 8) |
| Lease + reaper + retry | Dead workers (1–3) |

### Two retry layers
- **Inside the lease (worker):** quick retries of one LLM request — network error, 5xx, 429 with Retry-After ≤ 10 s → up to 2 retries (1 s, 3 s + jitter, honouring Retry-After). Malformed JSON → 1 repair retry with the error message.
- **Scheduler (new attempt):** worker crash, lease expiry, long Retry-After, in-lease retries used up → step back to `pending`, `available_at = max(backoff, Retry-After)`, attempt +1, up to 3.
- **Non-retryable:** `context_too_long` (a context-builder bug), `auth_error` → step fails, run fails.
- A failed run is continued by forking from its last completed step.
- The scheduler's Redis LLM token bucket refuses leases when the request rate is used up, preventing most 429s; the worker still handles the rest.

### Caps and reservation
Caps are measured in **tokens** (the real free-tier constraint). The UI also shows an estimated dollar figure from a configured price table, labelled as an estimate.

| Cap | Default |
|---|---|
| Steps per run | 12 |
| Tool calls per step / per run | 2 / 20 |
| Tokens per run | 150k |
| Tokens per invite code per day | 1M |
| Tool calls per day (global) | 30 (Tavily free tier is 1,000 credits/month) |
| Global tokens per day | Set below the provider's daily limit |

**Reservation:** in the lease transaction, reserve the worst case for one attempt (max input + max output tokens). If it would exceed any cap, refuse the lease and fail the run with `budget_exceeded`. On completion, settle the row with the provider's real usage. If the attempt dies or is cancelled, the reservation stays as the charge. A cap can never be exceeded, even by costs we never learn about. One `spend` row per `(step, attempt)`, so retried reports can't charge twice.

---

## 6. Context builder

- **Go builds the context** (it has the database and decides what the agent sees) as a provider-neutral `StepContext`. **Python only renders it** into the provider's message format with a fixed template. Both halves are pure functions.
- **Agent output (structured JSON, validated with pydantic):**
  ```json
  { "one_line_summary": "...", "reasoning_summary": "...",
    "notes": "...", "tool_calls": [{"name": "web_search", "args": {}}],
    "final_answer": null }
  ```
  A step either acts (tool calls) or finishes (final answer). `notes` is the agent's own running scratchpad (≤ 1,500 chars), carried forward as task state at no extra LLM cost.

### Contents, in priority order

| # | Section | Limit |
|---|---|---|
| 1 | Fixed rules (versioned by `prompt_version`): agent role; tool results are data, not instructions; later instruction wins on conflict; output format | Fixed |
| 2 | Goal | ≤ 2,000 chars |
| 3 | All instructions in seq order, with author and applied/new status | ≤ 25 × 1,000 chars |
| 4 | Latest `notes` | ≤ 1,500 chars |
| 5 | Older steps, one line each (`one_line_summary`) | ≤ 200 chars each |
| 6 | Last 3 steps in full, with tool-result excerpts | Excerpts ≤ 1,500 chars each |
| 7 | Budget line: steps left, tool calls left; on the last step "give your final answer now" | Fixed |

- **Size limit:** about 8,000 input tokens (estimated as characters ÷ 4 with a safety margin; approximate).
- **Trimming order when over the limit:** drop the oldest one-liners; then shrink the recent window 3 → 2 → 1; then shorten tool excerpts. Sections 1–4 and 7 are never trimmed.
- **After a crash:** rebuilt from events up to the attempt's `context_through_seq` (plus lineage events for forks) with the same `prompt_version` → byte-identical. Go records `context_hash` in `step_attempt_started`; test C13 checks it.
- The LLM's answer is not deterministic and is never claimed to be.
- No RAG. LLM-written summaries of old history are V3.

---

## 7. Tool safety

- **`web_search(query)`:** Tavily, ≤ 5 results (title, URL, snippet), query ≤ 200 chars. Free tier: 1,000 credits/month (basic search = 1 credit); ask Tavily about student access.
- **`fetch_page(url)`:** plain HTTP GET; `http`/`https` only; 10 s timeout; ≤ 1 MB downloaded; text/HTML only; main text extracted (scripts, styles, menus stripped); stored excerpt ≤ 3,000 chars.
- **Tool results are data, never instructions:** wrapped in labelled "untrusted content" markers; the fixed rules say the only instruction sources are the goal and editors' instructions. This reduces prompt injection; it does not eliminate it. The real protection is read-only tools.
- **SSRF guard:** before connecting, resolve the hostname once and refuse private/internal addresses (`localhost`, `10.x`, `172.16–31.x`, `192.168.x`, link-local `169.254.x` including cloud metadata, container names); connect to that exact resolved address; re-check every redirect.
- **A tool failure is a result, not a step failure:** "search timed out" is passed to the agent in the next step.

---

## 8. APIs

### 8.1 REST (`/api/v1`)
Errors: `{"error": {"code": "...", "message": "...", "details": {...}}}`. Auth: `Authorization: Bearer <token>`; run creation uses an invite code.

| Endpoint | Who | Request | Responses |
|---|---|---|---|
| `POST /runs` | Invite-code holder | `client_request_id, goal, limits?` | `201 {run, links}` · `200` same result for a repeated `client_request_id` · `429` |
| `GET /runs/{id}` | viewer+ | | `200` status, `last_seq`, step count, parent `{run_id, fork_seq}`, child forks, usage totals |
| `GET /runs/{id}/events` | viewer+ | `?after=N&limit=500` | `200 {events, next_after, has_more}` |
| `GET /runs/{id}/inherited` | viewer+ | `?cursor=` | `200` ancestors' events, each up to its fork point |
| `POST /runs/{id}/instructions` | editor+ | `action_id, text, author_name` | `201 {seq}` · `200 {seq}` duplicate · `409 {code: run_finished, hint: fork}` · `409 {code: instruction_limit}` (25 per run) · `403` viewer · `429` |
| `GET /ws` (WebSocket upgrade) | viewer+ | Run and token sent in `hello` | See 8.2 |
| `POST /runs/{id}/pause` · `/resume` · `/cancel` | editor+ | `action_id` | `200 {status, seq}`; already in that state → `200` with `seq: null`, no event; cancelling a finished run → `409` |
| `POST /runs/{id}/forks` | editor+ | `action_id, from_step_no, instruction?` | `201 {run, links}` · `409` step not completed or lineage too deep |
| `GET /healthz` · `/readyz` · `/metrics` | Internal | | |

All user actions go over REST (status codes, idempotency, retries). The WebSocket is push-only.

**Share links:** `https://…/r/{run_id}#k={token}`. The fragment is never sent to the server, so tokens stay out of logs. The frontend sends the token as a Bearer header on REST and inside `hello` on the WebSocket.

**Rate limits (Redis token buckets):** instructions 5/min per token (burst 3) · run creation 10/day per invite code · forks 5/hour per token · WebSocket connects 20/min per IP.

### 8.2 WebSocket protocol
One connection per run per browser tab.

| Direction | Message | When |
|---|---|---|
| Browser → server | `hello {token, run_id, display_name, client_id}` | First message |
| Browser → server | `ping {}` | Every 10 s (refreshes presence, keeps load balancers from closing idle connections) |
| Server → browser | `welcome {role, latest_seq, presence}` | After `hello` is accepted |
| Server → browser | `event {…envelope…}` | Every committed event |
| Server → browser | `heartbeat {latest_seq}` | Every 5 s; `latest_seq` read from Postgres |
| Server → browser | `presence {members}` | On join/leave and every 10 s |

Close codes: `4001` bad token (no retry) · `4004` run not found · `4008` client too slow · `1012` server restarting. All except `4001` → the browser reconnects.

"Step running" status is derived from `step_attempt_started`; there is no separate message.

**Backpressure:** each tab has a bounded send queue of 256 messages. If it fills, the server closes with `4008`; the browser reconnects and catches up from Postgres.

**Gap-free reconnect (browser keeps `rendered_seq` and a buffer):**
1. Open the WebSocket and send `hello`; the server registers the tab in its hub (subscribing to Redis) before replying `welcome`. Live events start arriving and are buffered.
2. Fetch `GET /events?after=rendered_seq` (paged until `has_more = false`).
3. Merge: drop `seq ≤ rendered_seq`, render in seq order.

Subscribe first, then fetch: every event is then in at least one of the two streams, and seq dedup removes the overlap.

Steady state, per incoming event:
- `seq ≤ rendered_seq` → drop.
- `seq == rendered_seq + 1` → render, then drain buffered events in order.
- `seq > rendered_seq + 1` → buffer, wait 300 ms (normal cross-instance reordering); if the gap remains, fetch `?after=rendered_seq`.
- Heartbeat with `latest_seq > rendered_seq` → fetch (catches a lost last event).
- On disconnect: reconnect with backoff (0.5 s, 1 s, 2 s… up to 10 s, plus jitter) and repeat steps 1–3.

### 8.3 gRPC contract (Go server ↔ Python worker)
Workers pull work; the server never pushes it.

```proto
service StepQueue {
  rpc LeaseStep(LeaseRequest)       returns (LeaseResponse);
  rpc Heartbeat(HeartbeatRequest)   returns (HeartbeatResponse);
  rpc CompleteStep(CompleteRequest) returns (CompleteResponse);
  rpc FailStep(FailRequest)         returns (FailResponse);
}
```

| RPC | Request | Response |
|---|---|---|
| `LeaseStep` | `worker_id` | **Lease** (`step_id, run_id, step_no, attempt, lease_expires_at`, `StepContext`, limits) or **NoWork** (`retry_after_ms`, 500–2,000 ms with jitter) |
| `Heartbeat` | `step_id, attempt, worker_id` | `OK` (new expiry), `CANCELLED`, `LOST` |
| `CompleteStep` | `step_id, attempt, worker_id`, `StepResult`, usage | `ACCEPTED`, `ALREADY_ACCEPTED`, `STALE` |
| `FailStep` | `step_id, attempt, error_class, message, retryable, retry_after_ms`, usage if known | `ACCEPTED`, `STALE` |

- The server validates every result (size caps, schema, tool-call counts); an invalid result counts as a failed attempt (`worker_error`).
- Every call has a 5 s deadline. On `UNAVAILABLE`, the worker retries `CompleteStep`/`FailStep` for up to 30 s (safe because the attempt number is the same).
- Each worker runs one step at a time. `LeaseStep` answers immediately.
- `run_id`, `step_id`, `attempt` travel as gRPC metadata for log correlation.
- gRPC stays internal, never exposed publicly. Workers get both server addresses from an env var (`SERVER_GRPC_ADDRS`) and switch to the other instance on `UNAVAILABLE`.

---

## 9. Live delivery and Redis

Redis is ephemeral only. Postgres stays the source of truth for events, run/step state, scheduling and spend. Losing Redis messages never causes permanent event loss.

### Pub/sub fan-out
- Channel per run: `run:{run_id}`. Each Go instance holds one subscriber connection; subscribes when its first local viewer of a run joins, unsubscribes when the last leaves.
- Publish path: commit the event, then `PUBLISH` the full event (≤ 32 KB). No retry, no outbox; the repair path covers loss.
- Every instance, including the writer, delivers through Redis (one code path).
- Each instance's hub tracks `last_broadcast_seq` per run and drops duplicates.

### Repair path: `catchUp(run, afterSeq)`
One function that reads from Postgres and broadcasts with dedup. Four triggers:

| Trigger | What happens |
|---|---|
| Client sees a seq gap | Waits 300 ms, then fetches `GET /runs/{id}/events?after=N` |
| Heartbeat every 5 s | Each instance reads `runs.last_seq` from Postgres for its active runs and sends `latest_seq` |
| Redis subscriber reconnects | Instance runs `catchUp` for every subscribed run from `last_broadcast_seq` |
| Redis is down | Instance polls Postgres every 1 s for runs with local viewers (~1 s latency instead of failure) |

Invariant: a viewer renders exactly the committed events, in seq order, with no gaps. Redis loss costs latency (≤ ~5 s), never data.

### Presence
- Key `presence:{run_id}`: a sorted set; each member is a connection, its score is its expiry time.
- Each browser `ping` (every 10 s) sets the score to now + 30 s; the key itself has a 60 s expiry.
- Live members = score in the future; stale ones pruned in the same call. A crashed server's connections expire within 30 s with no cleanup code.
- Join/leave are also published on the run channel for instant updates.
- If Redis is down: presence shows "unavailable".

### Rate limiting
Token bucket in a Lua script (atomic in Redis; uses Redis's own clock). Two jobs:
- **API abuse protection** (limits in 8.1).
- **LLM throughput gate at the scheduler:** a lease is granted only if the global LLM bucket has a token; otherwise `NoWork {retry_after_ms}`. Python never talks to Redis.
- If Redis is down: conservative per-instance in-process limits.

### What Redis does not do
Spend caps (Postgres, in the step transaction) · leases or locks (fencing in Postgres; a Redis lock can't protect the database write) · caching events · Streams (Postgres `events` is the durable log; a second log would mean dual writes) · persistence (off; everything is rebuildable). Every key has a TTL; `maxmemory 64mb`, evicting only keys with a TTL.

### Redis Pub/Sub vs Postgres LISTEN/NOTIFY (why Redis, and what it costs)

| | LISTEN/NOTIFY | Redis Pub/Sub |
|---|---|---|
| Tied to commit | Yes — delivered only if the transaction commits, even if the writer then crashes | No — publish is a separate call after commit; a crash between them loses the message |
| Ordering | Commit order (= seq order) | Per publishing connection only; two instances can interleave |
| Payload | < 8,000 bytes | Effectively unlimited |
| Stuck consumer | The ~8 GB queue can fill and make NOTIFY transactions fail at commit | Slow subscriber disconnected; writes unaffected |
| Load | On the database primary; serialises committing transactions under heavy writes | Off the database; scales further with sharded pub/sub |
| Teaches | Transaction semantics, commit-time side effects | Broker decoupling, at-most-once delivery, the dual-write gap, backpressure, client dedup/reorder |

Choosing Redis means gap repair is mandatory (the commit-then-publish crash window). Both are fire-and-forget; neither stores messages.

---

## 10. Replay and fork

### Replay
- Re-renders stored events; no LLM calls, no workers, no writes.
- The frontend has one pure reducer, `apply(state, event) → new state`. Live view applies events as they arrive; replay applies events 1…k for slider position k. A running run can be scrubbed back while it continues, with "jump to live".

| Reproduced exactly | Not reproducible |
|---|---|
| Every step, tool call (stored excerpts), output, instruction, timing, retry and failure | The LLM's answer if run again |
| The exact context each attempt saw (rebuilt from events ≤ `context_through_seq` + `prompt_version`, checked against `context_hash`) | Full web pages (only excerpts stored; the web changes) |
| Which instruction was applied at which step | Who was watching (presence is never logged) |

### Fork
1. Fork from a completed step; `fork_seq` = seq of that step's `step_completed`.
2. The parent is the run that contains that event (forking an inherited step points at the original run, keeping chains short).
3. Lineage depth ≤ 5; deeper → `409`.
4. One transaction: create the child run (parent, `fork_seq`), write `run_created`, optional `instruction_received`, next step `pending`, tokens. The parent is never written to or locked (its events are immutable).
5. Child context = lineage events (each ancestor up to its fork point) + the child's own events. Pending instructions at the fork point carry over; the parent's later instructions never reach the child.
6. Budget: fresh per-run budget; daily caps shared with, and charged to, the parent run's owner.
7. Forking a running run is allowed; parent and child continue independently.
8. Inherited history has its own endpoint (`/inherited`): it never changes, so the browser fetches it once and caches it. Gap detection runs on the child's own seq only. The child's token can read ancestors only up to their fork points.
9. UI: inherited steps greyed out ("from R1"); the parent lists its forks via a read query; a failed run shows "Continue from step N".

---

## 11. Failure modes

### Worker
| Failure | Expected behaviour | Test |
|---|---|---|
| Crashes before/during/after the LLM call | Lease expires (≤ 60 s), reaper requeues, next attempt succeeds; after-reply crash → mock counts 2 calls | C1 |
| Freezes past its lease | Heartbeat `LOST` or report `STALE`; nothing written | C3 |
| Sends an invalid result | Failed attempt (`worker_error`), retried | C14 |
| All workers down | Steps wait as `pending`; UI "waiting for a worker"; resumes when a worker returns | C2 |

### Server
| Failure | Expected behaviour | Test |
|---|---|---|
| One instance hard-killed mid-run | Viewers reconnect via Caddy to the other; workers retry against it; its reaper picks up expired leases | C2 |
| Crash mid-transaction | Rollback; worker's retry accepted | C4 |
| Crash between commit and publish | Gap repaired via next event or heartbeat (≤ 5 s) | C8 |
| Graceful restart | Close `1012`, browsers reconnect, nothing lost | C2 |
| Both instances down | Workers retry 30 s then drop the result; leases expire when a server returns; steps rerun | C2 |

### Postgres
| Failure | Expected behaviour | Test |
|---|---|---|
| Restart/unavailable | API `503`, workers retry, heartbeats pause; after recovery all invariants hold, expired leases requeued | C5 |
| Cancel races a completion | Lock order prevents deadlock; exactly one wins | C11 |
| Pool exhausted | Brief wait then `503`; nothing corrupted | Load test |

### Redis
| Failure | Expected behaviour | Test |
|---|---|---|
| Down | 1 s Postgres polling; presence "unavailable"; local rate-limit fallback | C7 |
| Restarts empty | Presence rebuilds ≤ 30 s; buckets reset; spend unchanged | C7 |
| Subscriber connection drops | Catch-up from Postgres on reconnect | C8 |
| Publish lost | Repaired by next event or heartbeat | C8 |
| Cross-instance reordering | Browser buffers, renders in seq order | C8 |

### LLM provider
| Failure | Expected behaviour | Test |
|---|---|---|
| Timeout / 5xx | In-lease retries, then a new attempt | C9 |
| 429, short Retry-After | In-lease retry honouring Retry-After | C9 |
| 429, long Retry-After | New attempt with `available_at` ≥ Retry-After | C9 |
| Outage longer than all retries | Step fails → run `retries_exhausted`; continue via fork | C9 |
| Malformed JSON | One repair retry in the lease | C9 |
| Auth error / context too long | Fail immediately, no retries | C9 |
| Bills a cancelled call | Reservation stays as the charge; caps hold | C10 |

### Tools
| Failure | Expected behaviour | Test |
|---|---|---|
| Tavily down / out of credits | Error passed to the agent as a tool result; step continues | C15 |
| `fetch_page` to private/internal address | Blocked before connecting, redirects included | C15 |
| Huge page | Stops at 1 MB; excerpt ≤ 3,000 chars | C15 |

### Viewer connection
| Failure | Expected behaviour | Test |
|---|---|---|
| Network drop | Reconnect with backoff, catch up, no gaps | C6 |
| Slow client | `4008`, reconnect, catch up | C6 |
| Laptop asleep for hours | Paged catch-up on wake | C6 |
| Bad token | `4001`, no retry | C16 |

---

## 12. Tests

### Levels
| Level | What runs | Examples |
|---|---|---|
| Unit | Pure functions, no database | Context builder, trimming, the browser reducer, backoff |
| Integration | Go server code against real Postgres and Redis in containers (testcontainers) | Leases, stale/duplicate completions, reaper races, instruction ordering, Lua scripts |
| System / chaos | Full stack (2 servers, 2 workers, Postgres, Redis, Caddy); containers killed on purpose | Worker crash, server crash, Redis outage, reconnect storms |

### Test tools we build
1. **Mock LLM provider:** scripted responses from a fixture file; can return 429, 500, timeout, malformed JSON, slow replies on demand; counts calls. Also the fake worker's brain in weeks 1–2.
2. **Fault switches:** test-only hooks enabled by an env var (skip publish for seq N, crash worker after LLM reply, delay `CompleteStep` by 70 s…). The server refuses to start in production mode with any switch on.
3. **Invariant checker** (reads the database after any test) **and probe viewer** (headless WebSocket client recording what it would display). Every system test ends by running both.

### Invariants
| # | Invariant |
|---|---|
| I1 | Each run's events have seqs 1…`last_seq`, no gaps, no duplicates |
| I2 | Each step has at most one `step_completed` |
| I3 | A `step_completed` event's attempt equals the step's final attempt |
| I4 | A finished run has exactly one terminal event, and none after it |
| I5 | `runs.status` matches what the event log implies |
| I6 | Step N+1 exists only if step N completed |
| I7 | No `step_attempt_started` while the run is paused or cancelled |
| I8 | At most one spend row per (step, attempt); totals never exceed any cap |
| I9 | Each `action_id` appears at most once per run |
| I10 | The probe viewer displayed exactly the database's events: same seqs, same order, nothing missing, nothing twice |

### Correctness tests
| ID | Test | Action | Invariants |
|---|---|---|---|
| C1 | Worker crash | Kill the worker before, during, after the LLM call | Run completes; I1, I2, I8 |
| C2 | Server restart | Hard-kill server-1 mid-run with 3 viewers and 2 workers; restart later | Run completes; viewers reconnect; I1, I10 |
| C3 | Stale lease rejected | Delay worker A past its lease; B completes attempt 2; A reports attempt 1 | A gets `STALE`; I2, I3 |
| C4 | Duplicate completion | Report the same (step, attempt) twice, including after a forced rollback | `ALREADY_ACCEPTED`, no new events, one charge; I2, I8 |
| C5 | Postgres restart | Restart Postgres mid-step | All invariants; run completes |
| C6 | Reconnect without gaps | Probe drops its connection 20 times at random, and once for 10 min | I10 |
| C7 | Redis outage | Stop Redis 60 s mid-run; restart empty | Polling keeps live view; I10; presence back ≤ 30 s; spend unchanged |
| C8 | Lost/reordered publish | Skip publish for seq N; force N+1 before N | Every viewer shows N within 5 s, in order; I10 |
| C9 | LLM retries | Mock returns each error class | Each class follows its documented path; retry counts match; I1–I4 |
| C10 | Cancellation | (a) cancel while leased, worker reports; (b) lease attempt after cancel; (c) heartbeat after cancel | (a) `STALE`, no events after `run_cancelled` (I4); (b) no lease (I7); (c) `CANCELLED`, worker aborts, reservation charged (I8) |
| C11 | Concurrent instructions and controls | 2 editors × 50 instructions in parallel through both instances, with random same-`action_id` retries; cancel racing a completion | 100 unique events (I9); same order for every viewer (I10); one winner; no deadlock |
| C12 | Reaper race | Both instances' reapers fire on the same expired lease | Exactly one `step_attempt_failed` |
| C13 | Context determinism | Build context, simulate crash, rebuild | Byte-identical; `context_hash` matches |
| C14 | Budget reservation | Run near its token cap; worker dies mid-call | Next lease refused; run `budget_exceeded`; totals never exceed the cap (I8) |
| C15 | Tool safety | `fetch_page` to `localhost`, `10.x`, `169.254.169.254`, a container name, a redirect to private; 5 MB page; Tavily down | Private targets blocked; size caps; tool errors become results |
| C16 | Fork isolation and access | Fork a running run; keep instructing the parent; read history with the child's token | Parent never written; later parent instructions never reach the child; child token can't read past the fork point |

### Load tests (measure; claim nothing unmeasured; record hardware)
1. Fan-out latency (commit → shown, p50/p95/p99) for 10, 100, 500 viewers on one run and many runs at once (probes on the same machine as the server).
2. WebSocket connections per instance before latency degrades; memory per connection.
3. Reconnect storm: kill one instance with N viewers; time to full catch-up; extra Postgres load.
4. Scheduler throughput: steps/sec with the zero-delay mock and W workers; lease latency; Postgres CPU; row-lock wait time.
5. Hot-run instruction rate: max instructions/sec on one run and p95 latency.
6. Redis-down cost: Postgres query rate from 1 s polling vs number of active runs.
7. Gap repairs and heartbeat-triggered fetches per minute (should be near zero).

---

## 13. Libraries and tools

### Go server
| Need | Choice | Why |
|---|---|---|
| HTTP routing | Standard library `net/http` | Handles methods and path params since Go 1.22; no framework hiding how Go HTTP works |
| Postgres | pgx v5 (`pgxpool`) | Standard high-performance driver; transactions, row locks, SKIP LOCKED |
| Queries | sqlc | Plain SQL files → type-safe Go functions; SQL stays visible |
| Migrations | goose | Numbered SQL files with up/down, run as a one-shot job |
| Redis | go-redis v9 | Official client; pub/sub, reconnects, Lua scripts |
| WebSockets | coder/websocket | Small, maintained, context-aware |
| gRPC | grpc-go + protobuf, buf for generation | buf lints `.proto` and generates Go and Python code from one config |
| Logging | `log/slog` | Structured JSON logs, standard library |
| Metrics | prometheus/client_golang | `/metrics` in Prometheus format |
| UUIDs | google/uuid | UUIDv7 (time-sortable, index-friendly) |
| Tests | testing + testify + testcontainers-go | Real Postgres/Redis per test package |
| Lint | golangci-lint | Many Go checkers in one pass |

### Python worker
| Need | Choice | Why |
|---|---|---|
| Project | uv | Fast package/project manager with a lockfile |
| Concurrency | asyncio | Cancelling the task aborts the in-flight LLM request on `CANCELLED`/`LOST` |
| gRPC | grpcio (async API) | Official; works with asyncio |
| LLM | openai SDK (`AsyncOpenAI`) pointed at Gemini's OpenAI-compatible endpoint | One client; Groq is a config change |
| Output schema | pydantic v2 | Request structured output and validate replies in one place |
| HTTP for tools | httpx | Timeouts and streaming (enforces 1 MB cap); Tavily called with plain httpx |
| Page-to-text | trafilatura | Extracts main text, drops menus/footers |
| Logging | structlog | JSON logs with Go's field names |
| Metrics | prometheus_client | `/metrics` |
| Tests / lint | pytest, ruff | |

SSRF guard: ~40 lines of our own code with Python's `ipaddress` module.

### Frontend (Claude Code)
| Need | Choice | Why |
|---|---|---|
| Base | Vite + React + TypeScript + Tailwind | Type-checked event envelope and messages |
| State | Pure `apply(state, event)` reducer + `useReducer` | Same function for live, replay, reconnect |
| Live sync | Own module in `web/src/sync/` | Subscribe-then-fetch, dedup, reorder, backoff; tested in isolation |
| Routing | react-router | Run pages, share links |
| Tests | Vitest | Reducer and sync module |
| Lint | ESLint + `tsc` | |

### Infrastructure
| Need | Choice | Why |
|---|---|---|
| Local stack | Docker Compose | |
| Edge proxy | Caddy | Spreads traffic over 2 instances, proxies WebSockets, automatic HTTPS when deployed |
| Postgres | Postgres 17 image | Standard features only; re-check managed support at deploy |
| Redis | Redis 7.4 image | Core commands only; managed Redis/Valkey swap later |
| Probe viewer, invariant checker | Small Go programs in the repo | |
| Load testing | k6 | Scripts REST and WebSocket traffic |

### LLM and search providers ($0)
- **Gemini free tier** via the OpenAI-compatible endpoint (free input/output tokens; free-tier content is used to improve Google's products; actual rate limits are shown in Google AI Studio — check on week 3, day 1). The compatibility layer is beta, so week 3 starts with a spike to confirm structured output works.
- The exact Gemini model is chosen in the week 3 spike.
- **Groq free tier** as a config fallback. Groq's free tier caps tokens per minute (8K for its larger models when checked in Oct 2026), so the Groq config also lowers the context budget.
- **Tavily** free tier (1,000 credits/month).

---

## 14. Repo, local setup, CI/CD, logging and metrics

### Repo structure
```
huddle/
├── CLAUDE.md                         # instructions for Claude Code
├── proto/huddle/v1/stepqueue.proto   # the gRPC contract
├── server/                           # Go module
│   ├── cmd/
│   │   ├── server/      # REST + WS + gRPC + scheduler + reaper
│   │   ├── admin/       # admin commands (create invite codes)
│   │   ├── probe/       # probe viewer (tests)
│   │   └── invariants/  # invariant checker (tests)
│   ├── internal/
│   │   ├── api/  ws/  fanout/  scheduler/  store/  events/
│   │   ├── contextbuilder/  spend/  ratelimit/  presence/
│   │   └── config/  faults/
│   ├── queries/         # .sql files sqlc reads
│   └── migrations/      # goose files
├── worker/              # Python (uv project)
│   ├── huddle_worker/
│   │   ├── main.py  loop.py  rpc.py  render.py  schemas.py
│   │   ├── providers/   # openai_compat.py, mock.py
│   │   └── tools/       # web_search.py, fetch_page.py, ssrf.py
│   └── tests/
├── web/                 # Vite + React + TS (src/sync, src/state, src/components, src/pages)
├── deploy/  compose.yaml  Caddyfile  .env.example
├── loadtest/            # k6 scripts
├── scripts/chaos/
├── docs/build-plan.md   # copy of this plan
├── .github/workflows/
└── Makefile
```

### Local setup (MacBook Air M3, 8 GB)
- Install via Homebrew: Go, uv, Node, buf, sqlc, goose, k6, Docker Desktop (Apple Silicon). The week 1 chat walks through each.
- **Daily development:** only Postgres and Redis run in Docker (Docker Desktop limited to 3–4 GB). Go server with `go run`, Python worker with `uv run`, directly on the Mac.
- **Chaos tests and demo recording:** full Compose stack (`postgres`, `redis`, `migrate`, `server-1`, `server-2`, `worker-1`, `worker-2`, `caddy`), other apps closed.
- Local images are arm64 natively; CI also builds amd64.
- **Serving the frontend:** in the full stack, Caddy serves the built frontend (`web/dist`) and proxies `/api/*` (REST and WebSocket) to the two server instances, so everything is one origin and no CORS setup is needed. In daily dev, the Vite dev server proxies `/api/*` to the local Go server.
- Secrets only in `.env` (git-ignored); `.env.example` lists every variable with placeholders.

| Command | What it does |
|---|---|
| `make dev-deps` | Starts Postgres + Redis in Docker |
| `make up-mock` / `make up` | Full stack with the mock / real provider |
| `make web` | Vite dev server |
| `make gen` | Regenerates sqlc and gRPC code |
| `make invite LABEL=… CAP=…` | Creates an invite code and prints it once |
| `make test` / `make test-int` / `make chaos` / `make load` | Unit / integration / chaos / k6 |

### Portability rules (hosting not decided)
- All config from environment variables; no cloud SDKs in app code.
- Multi-arch images (amd64 + arm64).
- Stateless app containers; state only in Postgres and Redis, reached by URL.
- Standard Postgres 16+ and core Redis 7 commands only.
- Migrations as a one-shot job.
- `/healthz`, `/readyz`, graceful shutdown on stop signals (stop accepting work, close WebSockets with `1012`, exit within a grace period).
- TLS at the edge; the app speaks plain HTTP and trusts the forwarded client-IP header only from a configured proxy.
- WebSocket keepalive (10 s ping) for load-balancer idle timeouts.
- gRPC internal only.
- Lease times from the database clock.

**Hosting decision at week 6:** compare AWS (possible credits via a senior), Oracle Always Free (needs a Visa/Mastercard credit card for verification; ARM 2 OCPU / 12 GB; capacity errors and idle reclamation possible), and other options, on current eligibility, credits, compatibility and cost. Fallback: run the stack on the Mac and expose it with a Cloudflare Quick Tunnel (no account, temporary URL); the demo video is then the permanent artifact.

### CI/CD (GitHub Actions)
| Workflow | When | Runs |
|---|---|---|
| ci | Every push and pull request | Lint (Go, Python, web), `buf lint`, generated-code-is-current check, unit tests, integration tests |
| images | Push to `main` | buildx amd64 + arm64 images → GHCR, tagged with the git SHA |
| chaos | Manual trigger and before release tags | Full stack + C1–C16 + invariant checker |

Deployment (wired once hosting is chosen): pull images for a SHA → run `migrate` → restart `server-1`, wait for `/readyz`, restart `server-2` → restart workers. Two instances plus auto-reconnect = no-downtime deploys.

### Logging
JSON to stdout from every service, same fields everywhere: `ts, level, service, instance_id, run_id, step_id, attempt, worker_id, request_id, seq`. `run_id`/`step_id`/`attempt` travel Go → Python via gRPC metadata. Never logged: share tokens, API keys, invite codes (tokens appear only as the first 8 chars of their hash).

### Metrics (`/metrics` on each service; Grafana in V2)
| Area | Metrics |
|---|---|
| HTTP | Request duration by route and status |
| WebSocket | Open connections, messages sent, `4008` disconnects |
| Events | Appended, by type |
| Scheduler | Leases granted, "no work" replies, reaper expirations, completion results (accepted/already/stale), attempt duration |
| Live sync | Gap repairs by trigger, Redis publish failures, mode (normal/polling) |
| Limits and spend | Rate-limit rejections by bucket, tokens reserved vs charged |
| Worker | LLM request duration, LLM errors by class, tokens in/out, tool calls by tool and status, tool duration, cancellations |

Health signals: stale completions (rare), gap repairs (near zero), reserved vs charged tokens (a large gap = many crashed/cancelled attempts).

---

## 15. Learning plan

All teaching happens inside the build chats; no external reading. Each week's chat starts with a lesson: small programs run on the Mac (`go run`), explained line by line, then the same concepts shown in the real code, then a quick exercise (predict the output / change one line / run it). Each week ends with an explain-back (5 interview-style questions) and one small change Devansh makes himself.

| Week | Lesson topics |
|---|---|
| 1 | Docker basics (images, containers, ports, volumes, Compose) · Go basics (packages, modules, types, structs, methods, interfaces, errors as values, slices, maps, JSON, HTTP handlers) · Postgres from Go (connections, transactions, reading sqlc-generated code) · migrations |
| 2 | Go concurrency (goroutines, channels, `select`, `context`, mutexes) · gRPC and protobuf · Python asyncio tasks and cancellation · row locks and `SKIP LOCKED` in practice |
| 3 | Error wrapping, table-driven tests, interfaces as test doubles · LLM structured output, retries and backoff · how SSRF works (DNS, private IP ranges) |
| 4 | WebSockets, goroutine per connection, bounded channels as queues, read/write locks, the race detector · Redis from zero (data types, pub/sub, sorted sets, atomic Lua scripts) · reverse proxies and load balancing (Caddy) |
| 5 | Enough React/TypeScript to read the sync module and reducer · signals, graceful shutdown, health checks |
| 6 | Prometheus metrics · Docker images and multi-arch builds · CI/CD · comparing cloud hosting |

Distributed-systems theory (leases, fencing, idempotency, at-least-once delivery) is taught directly with diagrams and worked examples.

**Must know deeply for interviews:** event log vs current state, transactions, gap-free seq and why not a sequence, leases, heartbeats, attempt as fencing token, compare-and-set, idempotency (duplicate vs stale), `SKIP LOCKED` job queue, at-least-once execution / exactly-once commit, the 10 crash cases, two retry layers, reservation-based caps, context determinism, prompt injection vs read-only tools, SSRF, REST for commands vs WebSocket for push, subscribe-then-fetch, dedup/reorder by seq, backpressure, state as a fold over events, Redis Pub/Sub vs LISTEN/NOTIFY, testing invariants, what load tests measure.

**Learn while coding:** SQL index syntax, lock-ordering code, `schema_version` handling, payload trimming, jitter formulas, close codes, paging cursors, hub map locking, proto field numbers, deadlines, container setup in tests, fault-switch plumbing, mock fixtures, k6 scripting.

---

## 16. Week-by-week plan

| Week | Build | New this week | Done when |
|---|---|---|---|
| **1. Event log** | Claude Code scaffolds the repo; Compose for Postgres + Redis; all migrations; sqlc; event-append helper with the seq counter; append-only trigger; invite codes (with the `make invite` admin command); hashed tokens; `POST /runs`, `GET /runs/{id}`, paged event reads; instructions with `action_id`; pause/resume/cancel (state only); JSON logs; CI workflow | Docker, Go basics, pgx, sqlc, goose, slog, GitHub Actions | Walkthrough creates a run and posts instructions; concurrent-append test shows gap-free seqs; retried instruction stored once; explain-back passed |
| **2. Scheduler + fake worker** | Proto + buf; `StepQueue` (lease with SKIP LOCKED, heartbeat, complete ACCEPTED/ALREADY_ACCEPTED/STALE, fail); reaper; backoff; context builder v1 with `context_hash`; spend reservations; Python async worker with mock provider and cancellation; 2 workers | Goroutines, context, gRPC, buf, asyncio, testcontainers | Mock run completes 5 steps; killing a worker mid-step still completes it; C1, C3, C4, C10, C12, C13, C14 pass; invariant checker clean |
| **3. Real LLM + tools** | Day-1 spike on Gemini's compatible endpoint + check real limits in AI Studio; provider, pydantic schema, two-layer retries, repair retry, Groq fallback; `web_search`; `fetch_page` with SSRF guard and caps; step/tool/token caps; local LLM rate gate | openai SDK, pydantic, httpx, trafilatura, Tavily | Real laptop-comparison run completes with sources; C9, C15 pass; usage inside free limits |
| **4. Live delivery + Redis** | WebSocket hub (hello/welcome/event/heartbeat/presence, send queues, `4008`); Redis pub/sub fan-out; `catchUp` with 4 triggers; polling fallback; sorted-set presence; Lua token bucket (API + LLM gate); server-2 + Caddy; probe viewer | coder/websocket, go-redis, Lua, Caddy, `go test -race` | 3 probe viewers survive killing server-1 and stopping Redis with I10 holding; C2, C6, C7, C8, full C11 pass |
| **5. Frontend + replay** (Claude Code) | Sync module with Vitest first; reducer; run page (timeline, instruction box queued/applied, controls, presence, retry and "waiting for worker" indicators); create-run page; share links; replay slider; `/readyz` and graceful shutdown | Vite, React, TypeScript, Vitest, `signal.NotifyContext` | Two browsers steer one real run; worker kill visible in UI; replay works; sync tests pass |
| **6. Fork + ship** | Fork and inherited-history endpoints + UI; `/metrics` everywhere; chaos workflow green; multi-arch images; hosting decision and deployment (or tunnel fallback); README; demo video | prometheus client, buildx, GHCR | Public URL (or tunnel), video, README, C1–C16 green |
| **7. V2** | Fork if it slipped · Google sign-in | OAuth | Signed-in users create runs without an invite code |
| **8. V2** | k6 load tests (Section 12) · Prometheus + Grafana in Compose | k6, Grafana | Measured results in the README, with hardware |
| **9. V2** | Buffer: fix what load tests revealed, plus anything pulled forward | | No open correctness issues |
| **10. V2** | Final README and video, design-decisions write-up, interview Q&A rehearsal | | Devansh explains every C-test and trade-off without notes |

**Cut order if college load hits:** fork → V2; replay slider → plain step list; presence → viewer count. **Never cut:** the engine, crash recovery, gap-free live view, instructions, deployment, demo.

### Risks and fallbacks
| Risk | Fallback |
|---|---|
| Gemini's compatible endpoint mishandles structured output | Swap the provider module to Google's native Python SDK or to Groq (one module changes) |
| Free-tier limits too low for demos | Mock provider for chaos demos; Groq fallback; fewer max steps; record off-peak |
| No eligible free hosting | Mac + Cloudflare Quick Tunnel; video is the permanent artifact |
| Understanding falls behind the code | A week isn't done until its explain-back passes; slow down |
| Concurrency bugs in hub/fan-out | `go test -race` in CI; one owner per shared map; probe viewer as ground truth |
| Flaky chaos tests | Wait for conditions with timeouts, not fixed sleeps; assert invariants, not timings |
| Tavily credits run out | Global daily tool cap; mock tools in tests; ask about student access |
| 8 GB RAM struggles | Postgres + Redis only in Docker for daily dev; full stack only for chaos and demo |
| Exams, SIH, hackathons | The cut order above |

---

## 17. Demo script (2 minutes)

Lease set to 15 s via config for the demo; the video says so on screen.

| Time | Show |
|---|---|
| 0:00–0:10 | Two browser windows (two people) side by side plus a terminal. "Two people steering one AI agent, and it survives crashes." |
| 0:10–0:40 | Step 3 "running on worker-1". `docker kill worker-1`. Both windows: "worker lost, retrying (attempt 2)", then worker-2 finishes the step. |
| 0:40–1:00 | `docker kill server-1`. Both windows: "reconnecting… caught up". No step missing. |
| 1:00–1:25 | Second person types "only 16 GB RAM": *queued* in both windows, then *applied at step 4*. |
| 1:25–1:45 | Replay back to step 3 and show the `lease_expired` attempt. If fork is built: fork from step 2 with "budget ₹60k". |
| 1:45–2:00 | Architecture diagram, "16 correctness tests including chaos", repo link. |

---

## 18. README outline

1. Pitch line plus the demo video
2. What it does (3 bullets)
3. Architecture diagram and components
4. Core guarantees: exactly-once commit with at-least-once execution; gap-free live view; one agreed instruction order
5. How it works: event log and seq; leases and fencing; live delivery and reconnect; the context builder
6. Failure modes and how they're tested (invariants, C-tests, chaos)
7. Load test results (measured, with hardware)
8. Design decisions and trade-offs: Redis vs LISTEN/NOTIFY, attempt as fencing token, counter-based seq, no token streaming, fork vs retry
9. Run it locally (`make up-mock`)
10. Limitations, stated honestly: duplicate LLM calls after crashes; prompt injection mitigated, not solved; free-tier limits; Gemini's free tier uses submitted content
11. Tech stack

---

## 19. Working setup

### Claude.ai project
- **Project instructions:** the build-chat brief (already pasted).
- **Project files:** `huddle-build-plan.md` (this file; changes only when a decision changes) and `STATUS.md` (current progress; replaced at the end of every build chat).
- **No code in project files** (it changes daily). When a chat needs a file, Devansh pastes it.
- **Memory:** builds up automatically; project decisions live in STATUS.md, not memory.

### Who does what
| | Build chat | Claude Code | Devansh |
|---|---|---|---|
| Teaching | All lessons, explanations, explain-backs | — | Learn, ask, answer |
| Backend code (Go, Python, SQL, proto, Compose, Caddyfile, Makefile, CI) | Writes it, file by file, with exact paths | Only for truly necessary mechanical multi-file tasks | Pastes, runs, reports output |
| Repo structure | Says what's needed and gives the Claude Code prompt | Creates folders, empty files, project setup | Runs Claude Code |
| Frontend | Specifies the contract; explains the sync module and reducer | Writes all of it | Reviews, runs, tests |
| Debugging | Reads errors, fixes them | | Pastes errors and outputs |

### Weekly routine
1. New chat in the project per week ("Week N, part 2" if long).
2. First message: "Starting Week N. STATUS.md is current. I have about X hours this week. Start with the lesson."
3. The chat runs: lesson → code file by file → run and verify → tests → explain-back → writes the new STATUS.md.
4. Devansh: pastes code, runs commands, commits with the given message, replaces STATUS.md in the project files.

### CLAUDE.md (repo root; created in week 1)
```
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
```
