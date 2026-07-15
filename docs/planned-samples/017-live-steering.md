# 017 — Live steering, follow-ups, and extension messages

## Status and compatibility target

Planned. Implement and verify this sample against Pi **0.80.6**. The installed
`docs/extensions.md`, `docs/rpc.md`, `dist/core/extensions/types.d.ts`,
`dist/core/agent-session.d.ts`, and `dist/core/agent-session.js` are the
authoritative sources for the contracts below. The README must print the
learner's `pi --version`, name 0.80.6 as the validated version, and describe a
shape mismatch as possible API drift rather than silently weakening a check.

This is a delivery-semantics lesson, not another general RPC controller. It
follows sample 015, but its scenario client should contain only the request,
event, and bounded-process helpers needed by this sample.

## Goal

Show exactly how an instruction enters an idle or active Pi session. The
learner should be able to distinguish:

- steering that joins the current run before the next model call;
- a follow-up that waits until the agent would otherwise stop;
- an ordinary user message injected by an extension;
- a custom extension message that becomes user-role LLM context; and
- a custom session entry that persists but never becomes model context.

The sample uses one deliberately blocking extension tool as an observable
checkpoint. The controller waits for events and releases that checkpoint; it
never sleeps in the hope that a provider is still streaming.

## Learning outcomes

After completing the sample, the learner should be able to explain and prove:

- acceptance, queueing, delivery, and settlement are different milestones;
- a steering message is delivered only after the current assistant turn and
  its tool calls finish, before the next model call;
- a follow-up is delivered only after there are no tool calls or steering
  messages left;
- `agent_end` closes one low-level run, while `agent_settled` means Pi has no
  automatic retry, compaction retry, or queued continuation left;
- extension commands execute immediately during streaming and may therefore
  enqueue guidance or release a checkpoint safely;
- `sendMessage()` creates a custom message which is converted to a user-role
  LLM message, whereas `appendEntry()` creates no agent message at all;
- `sendUserMessage()` passes through the `input` event with source
  `"extension"` and creates a normal user message; and
- aborting an RPC run is not the same operation as clearing its pending queue.

## Pi 0.80.6 delivery contracts

### Extension APIs

The installed extension types expose these signatures (the public extension
facade returns `void`, so delivery must be observed through events):

```typescript
pi.sendMessage(message, {
  triggerTurn?: boolean,
  deliverAs?: "steer" | "followUp" | "nextTurn",
});

pi.sendUserMessage(content, {
  deliverAs?: "steer" | "followUp",
});

pi.appendEntry(customType, data);
```

Their precise behavior is:

| Call and state | Pi 0.80.6 behavior | Delivery evidence |
| --- | --- | --- |
| `sendMessage(..., { deliverAs: "steer" })` while streaming | Queues a custom message; default delivery when `deliverAs` is omitted during streaming | `message_start` / `message_end` with `role: "custom"`, matching `customType` and opaque ID |
| `sendMessage(..., { deliverAs: "followUp" })` while streaming | Waits until the agent has no tool calls or steering messages | Matching custom-message events occur after steering work and before settlement |
| `sendMessage(..., { deliverAs: "nextTurn" })` | Holds the custom message for the next user prompt; it neither interrupts nor starts a turn | No message event before the next prompt, then a matching custom message in that prompt's run |
| `sendMessage(..., { triggerTurn: true })` while idle | Appends the custom message and starts a model turn; `triggerTurn` applies to steer/follow-up modes only | Agent lifecycle plus matching custom-message events |
| `sendMessage(...)` while idle without `triggerTurn` | Appends the custom message to state/session but starts no turn | Matching message events and no `agent_start` |
| `sendUserMessage(text)` while idle | Sends a standard user message and always starts a turn | `input` has `source: "extension"`; later `message_start` has `role: "user"` |
| `sendUserMessage(text, { deliverAs })` while streaming | Requires `"steer"` or `"followUp"`; omitting it throws asynchronously through extension error reporting | Input event records the selected `streamingBehavior`, then a normal user message is delivered |
| `appendEntry(type, data)` | Appends a `custom` session entry, emits `entry_appended`, and adds nothing to agent/LLM messages | `get_entries` contains it; `get_messages` and a real `context` event do not |

`sendMessage()` custom messages have `role: "custom"` inside Pi, but
`convertToLlm()` maps them to user-role messages. The `display` flag controls
transcript rendering; it does not exclude content from the model. Conversely,
an `appendEntry()` entry can have a renderer but never participates in model
context.

`nextTurn` is included in the contract test and README comparison table even
though it is not one of the four primary `/guide` actions. It is easy to
confuse with `followUp`: `nextTurn` waits for an external next prompt, whereas
`followUp` automatically continues the current session-level run.

### RPC APIs

RPC uses snake case for `follow_up`, while extension delivery uses camel case
`"followUp"`:

```json
{"id":"s1","type":"steer","message":"guidance"}
{"id":"f1","type":"follow_up","message":"later work"}
```

Both responses acknowledge queue acceptance, not delivery or completion.
Native RPC `steer` and `follow_up` create normal user messages, expand skills
and prompt templates, and reject queued extension commands. To invoke
`/guide ...` while streaming, send a `prompt` command; Pi detects the extension
command and executes it immediately.

The native queues default to `one-at-a-time`. Their `queue_update` events expose
the pending text arrays, and `get_state.data.pendingMessageCount` reports their
combined size. Custom messages queued with `sendMessage()` use the same agent
delivery machinery but do not appear in AgentSession's native text arrays;
their authoritative delivery signal is the matching custom `message_start`,
not `queue_update`.

`abort` calls `AgentSession.abort()`, which aborts retry/current agent work and
waits for idle. In 0.80.6 it does **not** call `clearQueue()` directly. Runtime
verification nevertheless shows the active aborted loop consuming its queued
guidance while settling: two pending messages become zero. The abort probe must
therefore observe both queue updates and `get_state`, rather than infer the
result from the abort implementation or acknowledgement alone, and must
terminate that disposable RPC process instead of sending another prompt that
could consume stale guidance. Do not teach that abort implicitly cancels
queued instructions.

## Intended layout

```text
samples/017-live-steering/
├── README.md
├── run-scenario.ps1
├── verify.ps1
├── verify-live.ps1
├── auth.json                    # ignored runtime state, never a symlink
├── models.json                  -> ../models.json
├── settings.json                -> ../settings.json
├── prepare.ps1                  -> ../prepare.ps1
├── prepare.sh                   -> ../prepare.sh
├── extensions/
│   └── live-guidance.ts
├── lib/
│   └── guidance-state.ts
└── tests/
    └── guidance-state.test.ts
```

The four shared symlinks are mandatory. Do not commit credentials or generated
sessions. `lib/guidance-state.ts` must be dependency-free so the model-free
test can import it directly with the repository's Node runtime. The extension
owns Pi types and TypeBox schemas; the state module owns only bounded counters,
opaque IDs, hashes, and checkpoint transitions.

`run-scenario.ps1` is a narrow JSONL scenario driver. If sample 015 has already
promoted a stable RPC helper to a shared module at the `samples/` root, import
that module. Otherwise implement only a local process wrapper with correlated
requests, event filtering, LF-delimited JSON, deadlines, stderr capture, and
idempotent cleanup. Do not copy sample 015's full controller or reach into its
sample directory.

## Extension design

### `/guide` command grammar

Register one `guide` command and parse these exact subcommands:

```text
/guide steer <text>
/guide follow-up <text>
/guide ask <text>
/guide note <text>
/guide next-turn <text>        # comparison/contract exercise
/guide release <checkpoint-id> # deterministic scenario control
/guide status
```

Rules common to text-bearing actions:

- trim outer whitespace and reject an empty payload;
- accept at most 1,024 UTF-8 bytes, not merely 1,024 UTF-16 code units;
- maintain at most eight outstanding guidance items and one held checkpoint;
- generate an opaque item ID and SHA-256 digest; never use text itself as a
  map key or diagnostic label;
- never interpret the text as a shell command, extension command, template, or
  file path; and
- return safe UI/RPC feedback containing class, opaque ID, and state only.

Action semantics:

- `steer` requires `ctx.isIdle() === false` and calls `pi.sendMessage()` with
  `customType: "sample017-guidance"`, `display: true`, opaque details, and
  `deliverAs: "steer"`.
- `follow-up` also requires an active run and uses `deliverAs: "followUp"`.
- `ask` requires idle state and calls `pi.sendUserMessage(text)` with no
  streaming option. Keeping this command idle-only makes its ordinary-user
  behavior unambiguous; the live scenario exercises streaming user messages
  separately through native RPC.
- `note` calls `pi.appendEntry("sample017-note", data)`. Its persisted data may
  contain the note because persistence is the requested behavior, but status,
  console output, counters, and thrown errors must contain only ID, byte count,
  and digest prefix.
- `next-turn` requires an active run and calls `sendMessage()` with
  `deliverAs: "nextTurn"`; status identifies it as waiting for an external
  prompt, never as a follow-up.
- `release` accepts only the exact active checkpoint ID, resolves it once, and
  returns a safe error for an unknown, completed, cancelled, or repeated ID.
- `status` reports idle/active, held checkpoint ID, counts by state and class,
  whether `guidance_checkpoint` is active, and no full guidance/note content.
  In RPC mode its notification is structural evidence that the command and
  tool policy were bound; expose a boolean, not the complete active-tool list.

The extension observes `message_start` to move a queued custom item to
`delivered`, matching its opaque ID in `details`. It observes ordinary user
messages and the `input` event to distinguish `source: "extension"`, `"rpc"`,
and interactive input. It increments `settled` only from `agent_settled`, not
from `agent_end`. Unknown messages are ignored rather than guessed.

Restore only durable note/audit metadata needed for the lesson on
`session_start`. Guidance queues and held Promise resolvers are process memory
and must not be reconstructed after reload. `session_shutdown` cancels the held
checkpoint, removes its abort listener, and clears sensitive in-memory text.

### Deterministic `guidance_checkpoint` tool

Register one tool with this narrow schema:

```typescript
{
  checkpointId: Type.String({ minLength: 8, maxLength: 80 })
}
```

The model is instructed to call it before producing prose. `execute()`:

1. validates the ID and rejects a second concurrently held checkpoint;
2. registers a pending resolver in `guidance-state.ts`;
3. emits normal `tool_execution_start` through Pi by remaining inside tool
   execution;
4. waits for either `/guide release <id>` or the supplied `AbortSignal`;
5. removes listeners/resolvers in `finally`; and
6. returns fixed text such as `checkpoint released` with opaque details, or a
   cancelled/error result without echoing guidance.

There is no timer inside the tool. The scenario driver's overall event waits
have deadlines so a bad model call or crashed process fails rather than hangs,
but deadlines are safety bounds, not race coordination. A model that fails to
call the only enabled tool may be retried in a fresh process at most twice;
never add a sleep or loosen the expected tool name to make it pass.

## Deterministic live RPC scenario

`verify-live.ps1` requires the prepared Azure variables and starts Pi with:

- `--mode rpc`, `--no-session`, and an explicit Azure model;
- `--no-extensions -e ./extensions/live-guidance.ts` so source identity is
  deterministic;
- `--no-builtin-tools --tools guidance_checkpoint`; and
- disabled unrelated skills/templates if the installed CLI exposes those
  switches.

Use random opaque markers for correlation, but never print them. Assert event
shape and ordering, not exact assistant prose.

### Phase A — extension message classes

1. Send a prompt that names the random checkpoint ID and requires the model to
   call `guidance_checkpoint` before any prose.
2. Wait for `tool_execution_start` with the exact tool name and ID. This event,
   not elapsed time, proves the turn is active and blocked.
3. Send `prompt` requests containing `/guide steer <marker>` and
   `/guide follow-up <marker>`. Correlated prompt responses prove the extension
   commands executed; they do not yet prove delivery.
4. Send `/guide next-turn <marker>` and prove no matching message is delivered
   in the current run.
5. Send `/guide release <checkpoint-id>` and wait for the matching successful
   `tool_execution_end`.
6. Observe the steer custom message before the next model call, then the
   follow-up custom message only after the agent has exhausted tool/steering
   work. Match `customType` and opaque details, not visible prose.
7. Wait for `agent_settled`; assert it follows the final custom-message
   delivery and final `agent_end`.
8. Send an ordinary prompt. Prove the held `nextTurn` custom message is
   delivered in this new run, then wait for settlement.

Do not require a fixed number of `turn_start` or `agent_end` events: provider
tool-call shape and whether a pre-finish follow-up remains inside one low-level
run are implementation details. Require only the partial-order invariants
above.

### Phase B — note isolation and `sendUserMessage`

1. While idle, invoke `/guide note <note-marker>` through RPC `prompt`.
2. Invoke `/guide ask <ask-marker>` the same way. The command calls
   `sendUserMessage()`, which starts a real turn.
3. The extension's next `context` handler scans the actual `event.messages`
   for the note marker, records only its digest plus `present: false` in a
   `sample017-context-audit` entry, and clears the raw comparison value.
4. Wait for `agent_settled`, then call `get_entries` and `get_messages`.
5. Prove exactly one `sample017-note` entry persists, the audit says absent,
   no agent message contains the note marker, and one standard user message
   contains the ask marker. Also prove the input observation for that ask used
   source `extension`.

This places the note before a real provider call. Merely appending it after all
model work and then checking `get_messages` would be weak evidence.

### Phase C — native RPC queue and abort probe

Run this phase in a fresh disposable Pi process so stale queued work cannot
contaminate Phase A or B:

1. enter a held checkpoint as above;
2. send native RPC `steer` and `follow_up` messages;
3. require their correlated success responses, `queue_update` evidence, and
   `get_state.data.pendingMessageCount === 2` while the tool is held;
4. send `abort`, wait for its response and eventual `agent_settled`;
5. wait for settlement, then query state and assert the verified transition
   from two pending messages to zero for Pi 0.80.6;
6. close stdin and require clean bounded process exit without issuing another
   prompt.

The verifier may hash queue text before comparing it, but must not print the
raw arrays on success or failure. If a future Pi version deliberately changes
abort/queue semantics, fail with a compatibility message and update this brief
and README after reviewing the new contract.

## Verification layers

### `pwsh ./verify.ps1` — model-free default

This is the default acceptance command and requires no Azure credentials. It
must:

1. print Node, PowerShell, and Pi versions;
2. validate the four shared symlinks and expected source paths;
3. run `tests/guidance-state.test.ts` and prove legal transitions for queued,
   delivered, settled, cancelled, duplicate release, capacity, UTF-8 byte
   limits, abort, and shutdown cleanup;
4. start Pi offline in RPC mode with only the explicit extension, call
   `get_commands`, and prove `/guide` comes from the expected file;
5. call `/guide status` and prove its safe RPC notification reports
   `guidance_checkpoint` active under the explicit one-tool allowlist;
6. exercise empty/oversized input, idle steer/follow-up, note,
   and invalid release without a provider call;
7. call `get_entries` and `get_messages` to prove an offline note is a custom
   entry and not an agent message;
8. run a small fake-API contract around injected extension actions if needed
   to assert the exact `sendMessage`, `sendUserMessage`, and `appendEntry`
   arguments without a model; and
9. close stdin, require exit code zero, restore the caller's environment, and
   prove no owned child remains.

Offline verification must set `PI_OFFLINE=1`, use `--no-session`, never source
`.env`, and never send an ordinary prompt that could reach a provider.

### `pwsh ./verify-live.ps1` — real model boundary

Run Phases A–C with explicit per-event and whole-process deadlines. Require
correlated command responses, exact tool identity, message roles/types,
partial-order invariants, note isolation in a real `context` event, settled
lifecycle, and bounded cleanup. Retry only the initial checkpoint-selection
prompt, at most twice in fresh processes. Provider authentication, quota,
transport, or malformed-event failures are never converted into skips.

### `pwsh ./run-scenario.ps1` — teaching output

Run Phases A and B and print a sanitized timeline such as:

```text
checkpoint active -> steer queued -> follow-up queued -> released
steer delivered -> follow-up delivered -> agent settled
note persisted -> context audit absent -> user message delivered -> settled
```

Show event types, delivery classes, opaque IDs, queue counts, and elapsed
durations only. Do not print prompts, guidance, notes, assistant text, provider
payloads, API keys, complete session entries, or stderr unless a redacted
failure summary is required.

## Privacy, safety, and cleanup

- Treat guidance, notes, prompts, message events, `queue_update` arrays, and
  session files as sensitive conversation data.
- Keep complete text only as long as required for delivery/audit. Status and
  diagnostic records retain opaque ID, delivery class, byte length, digest,
  timestamps, and state; they never retain full content.
- Redact the four `AZURE_PI_TEST_*` variables and common authorization/header
  patterns from exceptions and captured stderr. Do not print the endpoint.
- Use `ProcessStartInfo.ArgumentList`; never join learner input into a shell
  command or use `Invoke-Expression`.
- Bound queue count, checkpoint count, event buffer, text bytes, wait time, and
  stderr retained in memory.
- Every `AbortSignal` listener and Promise resolver is removed in `finally`.
- RPC cleanup closes stdin first, waits for normal exit, then terminates the
  owned process tree only as a bounded fallback. It must never kill unrelated
  `pi`, Node, or PowerShell processes.
- Temporary files use a unique directory below the system temp root, a
  sentinel, and guarded deletion. Successful verification leaves no sessions,
  transcripts, markers, or generated credentials in the repository.
- Steering can materially change an in-progress answer. The README should
  recommend recording delivery metadata when reproducibility or auditability
  matters, while warning that metadata alone does not reproduce model output.

## Edge cases the implementation must teach

- Empty, whitespace-only, oversized UTF-8, unknown, and malformed subcommands.
- `steer` or `follow-up` requested while idle.
- `ask` requested while active, avoiding the invalid streaming call without a
  delivery mode.
- Two checkpoints requested concurrently; unknown, repeated, late, and
  mismatched releases.
- Abort or shutdown while the checkpoint is held.
- A command response arrives before or after the events caused by the command.
- `agent_end` occurs while Pi still has session-level continuation work.
- `nextTurn` remains invisible until an external next prompt.
- Duplicate marker text does not confuse delivery tracking because opaque IDs
  are authoritative.
- Notes survive as entries across `get_entries`/context rebuild but never
  become custom or user agent messages.
- Native RPC queue events contain raw text and must be handled as sensitive.
- Provider finishes or refuses the requested tool call; the verifier fails or
  uses its bounded fresh-process retry, never a timing sleep.
- RPC EOF, malformed stdout, nonzero exit, and deadline expiry all trigger
  scoped cleanup and sanitized errors.

## Non-goals

- Background jobs, cross-session messaging, or multiple users.
- Subagent communication; sample 013 owns that lesson.
- A reusable full RPC SDK; sample 015 owns framing and controller design.
- A custom dashboard or elaborate renderer; sample 016 owns TUI composition.
- Persisting or replaying queued guidance across extension reloads.
- Proving exact assistant prose or deterministic model reasoning.

## Acceptance criteria

- The implementation and README name Pi 0.80.6 and use the exact camel-case
  extension versus snake-case RPC terminology.
- `/guide steer`, `follow-up`, `ask`, `note`, `next-turn`, `release`, and
  `status` enforce the state, byte, count, and privacy rules above.
- The `guidance_checkpoint` tool holds and releases through events/signals with
  no coordination sleeps and no leaked resolver.
- Custom steer and follow-up delivery are proven by matching custom-message
  events in the required partial order, not by command return alone.
- `nextTurn` is absent before the next external prompt and present afterward.
- `sendUserMessage()` produces an extension-source input and ordinary user
  message; `sendMessage()` produces a custom message that enters LLM context.
- A note is present as exactly one custom entry, absent from `get_messages`,
  and reported absent by a real provider-bound `context` audit.
- `agent_settled` occurs only after all expected Phase A/B continuation work.
- The native RPC abort probe demonstrates and documents Pi 0.80.6's remaining
  queue rather than claiming abort cleared it.
- `pwsh ./verify.ps1` passes without credentials or a model call.
- After preparation, `pwsh ./verify-live.ps1` runs the Azure-backed scenario
  and passes structural assertions.
- Both verifiers restore environment/location, bound waits, close owned
  processes, leave no generated repository files, and do not print full prompt
  or guidance text.

## References

- [Pi extension message APIs](https://pi.dev/docs/latest/extensions)
- [Pi RPC steering and follow-ups](https://pi.dev/docs/latest/rpc)
- [Pi SDK AgentSession](https://pi.dev/docs/latest/sdk)
- Installed Pi 0.80.6 `docs/extensions.md` and `docs/rpc.md`
- Installed Pi 0.80.6 `dist/core/extensions/types.d.ts` and
  `dist/core/agent-session.{d.ts,js}`
