# 017 — Live steering, follow-ups, and extension messages

This sample answers a deceptively important question: **when does a message
actually reach an agent?** Acceptance by a command is not delivery, and
delivery is not settlement. Pi exposes each milestone separately.

Validated with Pi **0.80.6**. Print your installed version before starting:

```powershell
pi --version
```

If a verifier reports a different event or response shape on another version,
treat it as possible API drift. Review the installed `docs/extensions.md`,
`docs/rpc.md`, and extension type definitions before weakening an assertion.

## What you will learn

| Instruction path | Pi representation | Delivery rule |
| --- | --- | --- |
| RPC `steer` | ordinary user message | after the current assistant turn and tools, before the next model call |
| RPC `follow_up` | ordinary user message | after tools and steering are exhausted |
| `sendMessage(..., { deliverAs: "steer" })` | custom message, converted to user-role LLM context | steering boundary |
| `sendMessage(..., { deliverAs: "followUp" })` | custom message, converted to user-role LLM context | follow-up boundary |
| `sendMessage(..., { deliverAs: "nextTurn" })` | custom message | waits for a new external prompt |
| `sendUserMessage()` | ordinary user message; `input.source` is `extension` | starts a turn when idle |
| `appendEntry()` | custom session entry only | persists but never enters model context |

Notice the spelling difference: RPC uses `follow_up`; extension delivery uses
camel-case `"followUp"`.

## Prepare and verify

From this directory, source the shared preparation script so the variables
remain in your current shell:

```powershell
. ./prepare.ps1
pwsh ./verify.ps1
pwsh ./verify-live.ps1
```

To select a particular prepared Azure deployment explicitly, pass its Pi model
ID, for example `pwsh ./verify-live.ps1 -Model azure-openai/gpt-5.6-luna`.
The default remains `azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT` so the sample
follows the repository's shared model registry.

The default verifier is intentionally model-free: it sets `PI_OFFLINE=1`, does
not source `.env`, validates symlinks, tests the dependency-free state machine,
loads only this extension, checks `/guide`, and proves a note is an entry rather
than an agent message. `verify-live.ps1` is a separate, strict Azure boundary;
missing credentials, quota failures, and transport failures are failures, not
skips.

To watch the sanitized teaching timeline without the native abort probe:

```powershell
pwsh ./run-scenario.ps1
```

Neither script prints prompts, guidance, notes, assistant prose, queue arrays,
API keys, or the Azure endpoint.

## Explore `/guide`

The extension registers exactly these forms:

```text
/guide steer <text>
/guide follow-up <text>
/guide ask <text>
/guide note <text>
/guide next-turn <text>
/guide release <checkpoint-id>
/guide status
```

`steer`, `follow-up`, and `next-turn` require an active run. `ask` requires an
idle session, ensuring that its call to `sendUserMessage()` cannot accidentally
omit the streaming delivery option. Text is trimmed, limited to 1,024 UTF-8
bytes, hashed, and tracked by an opaque ID. Status and errors never echo it.

The `guidance_checkpoint` tool is the observable boundary. Its promise remains
pending until `/guide release` names the exact active checkpoint or Pi aborts
the supplied signal. There is no timer in the tool and no timing sleep in the
scenario: `tool_execution_start` proves the agent is really blocked.

## Read the implementation

- `extensions/live-guidance.ts` owns Pi APIs, schemas, commands, and events.
- `lib/guidance-state.ts` owns bounded transitions and checkpoint cleanup and
  has no package dependency.
- `lib/ScenarioRpc.psm1` is a deliberately narrow JSONL process wrapper, not a
  reusable RPC SDK; sample 015 owns that larger lesson.
- `run-scenario.ps1` proves event partial orders rather than exact prose or a
  fixed number of turns.

`agent_end` closes one low-level run. `agent_settled` is stronger: no retry,
compaction retry, or queued continuation remains. Similarly, RPC success only
acknowledges queue acceptance. The custom `message_start` carrying the opaque
ID is delivery evidence.

## Abort and pending queues

The final live probe starts a disposable process, holds its tool, queues one
native steer and one native follow-up, and verifies two pending messages. In
the installed Pi 0.80.6 runtime, the reproducible transition is **2 pending
messages -> abort -> 0 pending messages**: `AgentSession.abort()` does not
directly call `clearQueue()`, but the aborted underlying run consumes its queued
work during settlement. This corrects the earlier 2 -> 2 prediction in the
planning brief; the sample treats installed runtime evidence as authoritative
and checks both `queue_update` and `get_state`. The probe still discards its
process so a future runtime cannot accidentally consume stale guidance.

Steering can materially change an in-progress answer. In audited workflows,
record delivery class, opaque ID, digest, and timestamps. That metadata is
useful evidence, but it cannot reproduce stochastic model output.

## Edge cases worth trying

- Empty or whitespace payloads and a 1,025-byte UTF-8 payload.
- `/guide steer` while idle and `/guide ask` while active.
- A wrong, repeated, or late checkpoint release.
- A second checkpoint while one is held.
- Aborting or exiting while the checkpoint promise is pending.
- Reusing identical text: opaque IDs, not text, correlate delivery.

Generated sessions are disabled with `--no-session`. `auth.json` is runtime
state and must never contain committed credentials.
