# 015 — Pi as a long-lived RPC service

## Status and compatibility target

Planned. Implement against the installed `pi` CLI and verify the protocol
contracts below against Pi **0.80.6** before considering the sample complete.
The public RPC documentation, the installed `dist/modes/rpc/rpc-types.d.ts`,
`rpc-mode.js`, and `jsonl.d.ts` are the authoritative implementation sources.

This sample must remain useful when Pi advances. The README should name 0.80.6
as the validated version, print the learner's installed `pi --version`, and
explain failures as possible protocol drift instead of silently accepting a
different response shape.

## Goal

Build a small PowerShell controller for `pi --mode rpc`. Earlier samples use
RPC as a narrow verification technique; this sample teaches it as a persistent,
bidirectional integration boundary.

The controller keeps one Pi process alive, sends newline-delimited JSON
commands, correlates responses, consumes asynchronous events, handles extension
UI requests without granting authority, and shuts the process down cleanly. It
is the next rung after sample 008's text and JSON batch modes.

## Learning outcomes

After completing the sample, the learner should be able to explain and prove:

- RPC is JSONL over a child process's standard streams, not network JSON-RPC;
- a successful command response acknowledges acceptance, not completion of an
  agent run;
- request responses and asynchronous events can arrive in either order and
  must be routed independently;
- `agent_end` closes one low-level run, while `agent_settled` means no retry,
  compaction retry, steering continuation, or queued follow-up remains;
- an RPC client is the UI in RPC mode and therefore owns an explicit policy for
  extension UI requests;
- closing stdin is normal shutdown, with process-tree termination only as a
  bounded fallback.

## Integration ladder

| Mode | Lifetime | Input | Output | Best fit |
| --- | --- | --- | --- | --- |
| `-p` | One turn | Prompt/stdin | Final text | Shell automation |
| `--mode json` | One run | Initial prompt | JSONL event stream | Observability and batch integration |
| `--mode rpc` | Many commands | JSONL commands | Responses plus async events | Controllers and custom clients |

`--mode json` and `--mode rpc` share agent event shapes, but only RPC reserves
stdin for commands and keeps a bidirectional process alive.

## Intended layout

```text
samples/015-rpc-controller/
├── README.md
├── PiRpc.psm1
├── demo.ps1
├── demo-persistent.ps1
├── verify.ps1
├── verify-live.ps1
├── auth.json                    # ignored runtime state, never a symlink
├── models.json                  -> ../models.json
├── settings.json                -> ../settings.json
├── prepare.ps1                  -> ../prepare.ps1
├── prepare.sh                   -> ../prepare.sh
├── extensions/
│   └── rpc-ui-probe.ts
└── fixtures/
    └── fake-rpc-server.ps1
```

The four shared symlinks are mandatory. `auth.json` is optional ignored runtime
state created by Pi; do not commit credentials or add a symlink for it.

`PiRpc.psm1` is sample-specific because its implementation is the lesson. Do
not move it to a shared `samples/` module merely so sample 017 can consume it by
relative path. Promote it only after a second implemented sample needs a stable
shared contract and both samples can be changed together.

`verify.ps1` is model-free and is the default acceptance command.
`verify-live.ps1` performs the explicit Azure-backed integration scenario so a
developer can distinguish deterministic protocol failures from credentials,
quota, or provider failures.

## Pi 0.80.6 protocol facts used by the sample

### Framing

- Each stdin command is one UTF-8 JSON object terminated by byte `0x0A` (LF).
- Each stdout response, event, or extension UI request is one UTF-8 JSON object
  terminated by LF.
- A trailing CR before LF may be stripped for compatibility, but bare CR,
  U+2028, and U+2029 are valid payload content and are not record separators.
- Standard error is diagnostics only. It must never enter the stdout JSON
  parser.
- Every ordinary command may include a string `id`. Its response repeats that
  ID. Agent events do not carry request IDs.

Do not implement the reader with `ReadLine()`, `OutputDataReceived`, or a
regular expression split. Their line semantics are broader than Pi's strict
LF framing and they make partial UTF-8 chunks difficult to test. `PiRpc.psm1`
should define a small C# transport helper with `Add-Type` that:

1. reads stdout and stderr `BaseStream` asynchronously in byte chunks;
2. uses a stateful UTF-8 `Decoder` so a multibyte character can span reads;
3. buffers decoded characters until literal `\n`;
4. removes one final `\r` from a framed record;
5. publishes stdout records and stderr records into separate thread-safe
   queues and signals a shared wake event;
6. publishes an explicit EOF or reader-fault marker when a stream ends.

The C# helper owns transport reads only. JSON parsing, routing, policy, timeout
messages, and the public teaching API remain visible in PowerShell.

### Response and event semantics

All commands in this sample carry generated IDs. A normal response has:

```json
{"id":"rpc-7","type":"response","command":"get_state","success":true,"data":{}}
```

A command-level rejection uses the same correlation path:

```json
{"id":"rpc-8","type":"response","command":"unknown_for_sample_015","success":false,"error":"Unknown command: unknown_for_sample_015"}
```

`prompt`, `steer`, and `follow_up` responses acknowledge that Pi accepted or
queued the instruction. They do not contain the eventual assistant result.
Post-acceptance failures appear in messages/events and do not produce a second
response for the ID.

The demo and verifier use only this small command subset:

| Request | Stable assertion |
| --- | --- |
| `get_state` | `data.sessionId` exists; state exposes `isStreaming` and queue count |
| `get_available_models` | `data.models` is an array; selected provider/model is present in a prepared live run |
| `get_commands` | `data.commands` is an array; offline probe command is discoverable when explicitly loaded |
| `prompt` | one correlated success response, followed independently by agent events |
| `steer` | success only when sent during an active run; delivery is observed through later events/messages |
| `follow_up` | success queues work; `queue_update` and final settlement demonstrate lifecycle |
| `get_last_assistant_text` | `data.text` is null or a string; used instead of reconstructing a canonical final message from deltas |
| `get_session_stats` | structural token/message/session fields exist; exact token counts and cost are not asserted |
| `abort` | correlated success; aborted assistant update/message and eventual settled state are observed |

Text streaming is read from `message_update.assistantMessageEvent` records
whose nested type is `text_delta`. Chunk boundaries are provider-dependent;
concatenate deltas for display, but use `get_last_assistant_text` for the final
canonical text.

The controller waits for `agent_settled`. It must not treat the first
`agent_end`, `message_end`, or a prompt response as terminal. A follow-up can
cause another run after an `agent_end`; automatic retry or overflow compaction
can do the same.

## `PiRpc.psm1` public contract

Export exactly these five functions:

- `Start-PiRpc`
- `Send-PiRpcRequest`
- `Wait-PiRpcResponse`
- `Wait-PiRpcEvent`
- `Stop-PiRpc`

All other functions, types, and state are private to the module. The module may
return an opaque controller object, but the README must tell learners not to
reach into its process or queue fields.

### `Start-PiRpc`

```powershell
Start-PiRpc
    [-ExecutablePath <string>]
    [-ArgumentList <string[]>]
    [-WorkingDirectory <string>]
    [-MaxEventCount <int>]
    [-MaxStderrLineCount <int>]
    [-UiPolicy <string>]
```

Contract:

- Default `ExecutablePath` is `(Get-Command pi -ErrorAction Stop).Source`.
- Default arguments are only `--mode`, `rpc`; callers supply every other Pi
  policy argument explicitly.
- `ArgumentList` is appended with `ProcessStartInfo.ArgumentList`, never joined
  into one shell command. `UseShellExecute` is false; stdin, stdout, and stderr
  are all redirected; no shell or `Invoke-Expression` is involved.
- `WorkingDirectory` is canonicalized and must exist.
- The teaching defaults are `MaxEventCount = 512`,
  `MaxStderrLineCount = 40`, and `UiPolicy = 'DenyDialogs'`.
- The process environment is inherited. The module does not load `.env`; the
  learner must source `prepare.ps1` or `prepare.sh` first.
- The returned object owns the child, strict-LF readers, response map, event
  buffer, safe diagnostics, monotonic ID counter, cancellation state, and a
  single write lock.
- Startup returns only after the process has started and readers are attached.
  It does not assume Pi emits a greeting. A failed start disposes partial state.
- A test seam permits launching `pwsh -NoProfile -File
  ./fixtures/fake-rpc-server.ps1` with the same transport. There is no separate
  fake client implementation.

The sample supports one caller thread and one Pi process. It does not promise
safe concurrent calls from multiple PowerShell runspaces, although the
transport queues and stdin write are protected against background-reader races.

### `Send-PiRpcRequest`

```powershell
$id = Send-PiRpcRequest -Client $client -Request <hashtable-or-psobject>
```

Contract:

- Require a non-empty `type` property.
- Copy the caller's object before adding an ID; do not mutate learner data.
- Generate a unique monotonic ID such as `rpc-000007-<process-guid>` when no ID
  is supplied. Reject an empty, non-string, already-pending, or previously-used
  ID. IDs are never recycled during one process lifetime.
- Register the ID as pending before writing, serialize with
  `ConvertTo-Json -Compress -Depth 100`, write one record plus literal LF using
  UTF-8 without a BOM, and flush stdin.
- Return the request ID immediately. The function never waits for the response.
- Reject `extension_ui_response`; those frames are generated only by the
  internal UI policy handler.
- Reject sends after stdin closure, process exit, reader failure, or stop.
- If serialization or writing fails, remove the pending registration, mark the
  transport fault, and throw a sanitized error.

This separation is intentional: the demo sends more than one request before
waiting, proving that output order is not request order.

### Routing pump

Both wait functions call one private `Receive-PiRpcOutput` pump before sleeping
and whenever the transport wake event fires. For each complete stdout record:

1. parse with `ConvertFrom-Json -Depth 100`;
2. fail the transport on blank or malformed stdout (stdout is protocol-owned);
3. route `type = 'response'` by exact ID into a response map;
4. handle `type = 'extension_ui_request'` immediately according to the UI
   policy, then also enqueue an observational copy as an event;
5. enqueue all other objects as asynchronous events.

A response with no ID, an unknown ID, or a second response for a completed ID
is a protocol violation. Record it and fault waits instead of guessing which
request it belongs to. A response's `command` need not be trusted for
correlation, but `Wait-PiRpcResponse` verifies it matches the original request
type and faults if it does not.

The bounded event buffer is FIFO. When it reaches `MaxEventCount`, discard the
oldest event, increment an overflow counter, and retain safe metadata about the
dropped type. Wait errors report the overflow. Responses are never dropped due
to event pressure. Completed response entries are removed when returned, while
used IDs remain in a bounded-independent `HashSet` for the lifetime of the
client.

Store only the most recent bounded diagnostic metadata: event type, nested
delta type, response ID/command/success, queue size, EOF/fault state, and
sanitized stderr lines. Do not echo prompts, model output, tool arguments,
tool results, environment variables, or full RPC objects in timeout messages.
Redact common `api-key`, `authorization`, `Bearer`, and URI query-value forms
and truncate each retained stderr line before it can appear in an exception.

### `Wait-PiRpcResponse`

```powershell
$response = Wait-PiRpcResponse -Client $client -Id $id [-TimeoutSeconds 10]
```

Contract:

- Require an ID returned by `Send-PiRpcRequest`.
- Use a monotonic deadline (`Stopwatch`), not repeated full timeout sleeps.
- Return the full correlated response object, including `success = false`.
  Protocol errors are data and must be inspectable; the caller decides whether
  to throw for a command rejection.
- Remove the response and pending request when returned.
- Throw on timeout, stdout parse/framing fault, impossible correlation, or
  process exit before the response. Include safe recent metadata and sanitized
  stderr tail, never request/message content.
- Do not consume or reorder asynchronous events while routing them.

The default timeout is 10 seconds for local state commands. Live scripts pass a
larger explicit timeout for model work.

### `Wait-PiRpcEvent`

```powershell
$event = Wait-PiRpcEvent -Client $client -Type <string[]>
    [-NestedType <string[]>] [-TimeoutSeconds 30]
```

Contract:

- Return and remove the earliest queued event matching `Type`.
- When `NestedType` is supplied for `message_update`, match
  `assistantMessageEvent.type` as well.
- Preserve unmatched events in their original order so a caller can wait for a
  response, then consume events that arrived before it.
- An omitted/empty `Type` means the next event of any type.
- Use the same monotonic deadline and transport-fault rules as response waits.
- Never return a `type = 'response'` object.

`demo.ps1` drains `message_update/text_delta` for display but keeps waiting for
`agent_settled`. If it needs to observe several event classes in order, it asks
for the next event and branches on its type rather than polling `get_state` in a
tight loop.

### `Stop-PiRpc`

```powershell
Stop-PiRpc -Client $client [-TimeoutSeconds 5]
```

Contract:

- Be idempotent and safe from `finally`, even after startup or reader failure.
- Under the write lock, close redirected stdin exactly once. In Pi 0.80.6,
  stdin EOF calls runtime disposal and exits normally.
- Continue draining stdout and stderr while waiting for exit so shutdown cannot
  deadlock on a full pipe.
- Wait up to the caller's timeout. If Pi remains alive, call
  `Kill($true)` to terminate its process tree, wait again with a short bound,
  and record that forced cleanup occurred.
- Dispose readers, wake handles, streams, and `Process` after exit.
- Throw only after cleanup when the child cannot be terminated. A nonzero exit
  or forced kill is returned/reported as cleanup diagnostics rather than
  masking an earlier exception in the caller's `finally` block.

Every script uses:

```powershell
$client = $null
try {
    $client = Start-PiRpc ...
    # scenario
}
finally {
    if ($null -ne $client) { Stop-PiRpc -Client $client }
}
```

## Extension UI policy: fail closed

Pi 0.80.6 binds extensions with `ctx.mode === 'rpc'` and `ctx.hasUI === true`
because the RPC client can answer dialogs. That does not mean a terminal UI is
present. Blocking methods emit an `extension_ui_request` and wait for a matching
stdin response; fire-and-forget methods emit the same outer type but expect no
response.

`UiPolicy = 'DenyDialogs'` is the only policy implemented in this introductory
client:

| `method` | Controller behavior |
| --- | --- |
| `confirm` | Immediately send matching `extension_ui_response` with `confirmed: false` |
| `select`, `input`, `editor` | Immediately send matching response with `cancelled: true` |
| `notify` | Retain bounded safe notification metadata and enqueue the request; send no response |
| `setStatus` | Update a bounded in-memory status map and enqueue; send no response |
| `setWidget`, `setTitle`, `set_editor_text` | Record method/id as ignored and enqueue; send no response |
| unknown method | Send `cancelled: true`, record a protocol warning, and never infer approval |

UI responses use the exact extension request ID and do not enter the ordinary
pending-request table because Pi sends no response to them. The policy runs in
the routing pump before returning another event; otherwise a blocked extension
command can deadlock the controller.

The controller must never choose the first select option, return placeholder
input, or confirm `true` to keep a scenario moving. A future interactive policy
belongs in a different sample.

`extensions/rpc-ui-probe.ts` exists only for model-free verification. Register
`/rpc-ui-probe` and sequentially call `notify`, `setStatus`, `confirm`, `select`,
`input`, and `editor`, recording only the returned booleans/presence flags in
the command's final notification. It must perform no model call and no file or
shell operation. Load it explicitly in verification with `--no-extensions -e
./extensions/rpc-ui-probe.ts`; do not let unrelated project/user extensions
affect the inventory.

## Process launch profiles

### Offline verification profile

From the sample directory after setting `PI_CODING_AGENT_DIR` to the sample,
launch Pi with these exact arguments:

```text
--mode rpc
--no-session
--offline
--no-approve
--no-tools
--no-skills
--no-prompt-templates
--no-extensions
```

Append `-e ./extensions/rpc-ui-probe.ts` only for the UI-policy test. These
commands do not call the model. `--no-approve` excludes project-local resources;
the explicit `-e` path remains loadable and auditable.

### Live demo profile

Require the prepared variables `AZURE_PI_TEST_DEPLOYMENT` and
`AZURE_PI_TEST_API_KEY`. Resolve the model as
`azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT` and launch:

```text
--mode rpc
--no-session
--offline
--no-approve
--no-tools
--no-extensions
--no-skills
--no-prompt-templates
--model azure-openai/<deployment>
```

`--offline` disables Pi startup network operations, not the explicit model API
request. `--no-tools` is the demo's explicit least-authority tool policy. The
README should point out that a production client can replace it with a narrow
`--tools` allowlist.

Do not pass secrets on the command line. They remain in the inherited prepared
environment and must not be printed by scripts.

### Persistent optional profile

`demo-persistent.ps1` uses a unique temporary `--session-dir` and a generated
`--name`, never the learner's normal session store. It demonstrates
`set_session_name`, `get_entries`, `get_tree`, `get_session_stats`, and `clone`
or `fork` only after a live message exists. Compaction is documented but should
be optional because it incurs another model request and overlaps sample 014.
The script removes its temporary session directory in `finally` unless
`-KeepSession` is explicitly supplied.

## Default `demo.ps1` flow

Use `[CmdletBinding()]` with a `-TimeoutSeconds` parameter (default 120) and
strict mode. The script should:

1. Validate `pwsh`, `pi`, the two required Azure variables, shared symlinks,
   and `pi --version`. Never print the key.
2. Start the live ephemeral profile and keep the controller inside `try/finally`.
3. Send `get_state` and `get_available_models` before waiting for either; wait
   in reverse request order to make correlation visible. Assert both responses
   succeed and print only selected model/session metadata.
4. Send a prompt requesting a deliberately long, marker-based answer with no
   tools. Wait for its successful command response and then consume events.
5. After `agent_start` and while `get_state.data.isStreaming` is true, send one
   `steer` message containing a stable steering marker. As soon as that response
   is accepted, send one `follow_up` containing a different stable marker.
6. Display text deltas as they arrive, observe `queue_update`, count
   `agent_end`, and keep processing until `agent_settled`.
7. Request `get_last_assistant_text` and `get_session_stats`. Print the final
   assistant text and structural statistics. Explain that the final text can
   belong to the follow-up; the event log proves the earlier continuation.
8. Send a second prompt that explicitly asks for a long answer. After the first
   `text_delta`, send `abort`, observe its correlated success, an aborted/error
   assistant event or message stop reason, and final `agent_settled`.
9. Close stdin through `Stop-PiRpc` and report whether shutdown was graceful.

Providers can finish a response before a controller steers it. The script must
check active state and, if the race is lost, fail with a clear instruction to
rerun rather than falsely claiming delivery. It must not use arbitrary sleeps,
send an unbounded prompt, enable shell tools to slow the model, or retry
billable calls silently. Sample 017 owns a deterministic checkpoint lesson.

The stable markers are assertions over reassembled messages, not exact prose or
delta boundaries. The verifier may require that the steer/follow-up user
messages appear in message order and that at least two low-level agent runs
precede the one terminal settlement; it must not assume an exact number of
assistant deltas or tool-free internal turns.

## Deterministic model-free verification

`pwsh ./verify.ps1` must make no provider request and must run from any current
directory. It saves/restores every environment variable it changes and creates
all writable state beneath a unique temporary directory.

### Layer A: fake transport server

`fixtures/fake-rpc-server.ps1` is a deterministic protocol peer, not a mock Pi
API. It reads strict LF JSONL from stdin, writes protocol records only to stdout,
and diagnostic noise only to stderr. Its fixed commands support these tests:

- accept two correlated requests and return their responses in reverse order;
- interleave `message_update`, `queue_update`, and UI requests between those
  responses;
- split one JSON frame across multiple byte writes;
- split a non-ASCII UTF-8 character across byte writes;
- include U+2028/U+2029 and bare CR inside a JSON string without creating extra
  frames;
- emit JSON-looking text on stderr and prove it never reaches the parser;
- omit one requested response so `Wait-PiRpcResponse` times out;
- emit one malformed stdout record so the transport faults closed;
- remain alive after stdin EOF only in a named forced-cleanup case.

The fixture receives scenario names as ordinary commands so one executable can
serve all cases. It contains no wall-clock race assertions: handshakes cause the
next frame, while short timeouts are used only for the intentional timeout
case. Verification asserts response correlation, preserved unmatched event
order, Unicode/framing fidelity, bounded event overflow accounting, sanitized
stderr diagnostics, EOF cleanup, idempotent stop, and process-tree fallback.

The verifier records every started PID and in `finally` proves each has exited.
For the forced-cleanup scenario, also start one fixture-owned child and prove
`Kill($true)` removes the complete tree.

### Layer B: real Pi, offline

Start fresh Pi processes with the offline profile and assert:

1. pipelined `get_state`, `get_available_models`, and `get_commands` each return
   exactly one successful response with the correct ID and command;
2. no `agent_*`, `turn_*`, `message_*`, or `tool_execution_*` event occurs for
   discovery-only commands;
3. `unknown_for_sample_015` returns one correlated `success: false` response
   whose error identifies an unknown command;
4. a deliberately malformed input frame returns an uncorrelated
   `command: "parse"` failure when tested through a raw fixture helper (the
   public sender refuses malformed JSON by construction);
5. closing stdin causes Pi to exit zero inside the shutdown timeout;
6. with only `rpc-ui-probe.ts` explicitly loaded, `/rpc-ui-probe` executes
   immediately without a model, all blocking UI calls resolve denied/cancelled,
   notifications/status are observed, and no confirmation is true;
7. every started Pi PID has exited before the temporary directory is removed.

Do not test discovery against whatever happens to be installed in the user's
default agent directory. Set `PI_CODING_AGENT_DIR` explicitly and use the
sample's shared registry with a temporary placeholder key only where model
enumeration requires a non-empty configured credential. Restore the original
environment in `finally`.

## Live verification

`pwsh ./verify-live.ps1` runs the smallest real-model scenario needed to prove
behavior the fake cannot establish:

- the explicit Azure model accepts a prompt and emits streaming lifecycle
  events;
- a steer is acknowledged while `isStreaming` is true;
- a follow-up is queued and appears after the active work's continuation point;
- `queue_update` reflects pending work when emitted by the installed version;
- the first `agent_end` is not treated as completion;
- one `agent_settled` is observed only after queued work finishes;
- the later prompt is aborted and reaches a settled idle state;
- reassembled/final messages contain stable steer and follow-up markers without
  asserting exact text or chunk boundaries;
- `Stop-PiRpc` leaves no Pi process.

The live verifier skips with a clear message and nonzero "not verified" result
when required prepared credentials are absent; it must not print PASS. Provider
authentication, quota, or rate-limit errors are reported separately from local
protocol failures. Each model wait uses an explicit upper bound, and cleanup
runs for every failure path.

## README teaching sequence

The README should use a teacher-to-student tone and keep code excerpts short:

1. source the sample's `prepare.ps1` or `prepare.sh` and explain why sourcing is
   required;
2. run `pwsh ./verify.ps1` first to establish the local transport contract;
3. inspect the five exported module functions and trace one request ID through
   the router;
4. run `pwsh ./demo.ps1` and label response acknowledgements separately from
   agent lifecycle events;
5. optionally run `pwsh ./verify-live.ps1` and
   `pwsh ./demo-persistent.ps1`;
6. experiment by waiting for correlated responses in a different order and by
   replacing `--no-tools` with a read-only allowlist;
7. end with production gaps: authentication boundary, richer UI policy,
   protocol versioning, reconnection, persistence, telemetry, and multiple
   clients.

Include compact diagrams for both routing and lifecycle:

```text
stdin request ──► Pi
                 ├──► response(id) ──► response map
                 ├──► agent event ───► bounded event buffer
                 └──► UI request ────► deny/cancel response + event buffer
stderr ──────────────────────────────► bounded sanitized diagnostic tail
```

```text
prompt response (accepted)
  → agent_start
  → ... first agent_end
  → queued steer/follow-up continuation(s)
  → ... later agent_end
  → agent_settled (controller may now call the run complete)
```

## Cleanup and privacy rules

- Every process start is paired with `Stop-PiRpc` in `finally`.
- Every temporary directory is unique and removed in `finally` unless an
  explicit keep switch exists.
- Scripts restore current directory and changed process environment exactly,
  including absence versus empty value.
- No script logs API keys, inherited environment dumps, full prompts, full tool
  arguments/results, raw stderr without redaction, or persisted session text.
- Diagnostic exceptions contain IDs, command/event types, counts, exit state,
  and bounded sanitized stderr only.
- `auth.json`, sessions, dumps, and generated output remain ignored.
- Verification never kills processes by executable name; it terminates only
  PIDs/process trees it started.

## Edge cases to teach

- Responses can arrive after events and in a different order from requests.
- A prompt response can succeed even when the accepted run later fails.
- Events have no request ID; lifecycle belongs to the session, not one command.
- Event consumers that wait selectively must preserve unmatched events.
- Event buffers need a visible overflow policy; silently losing settlement is
  unsafe.
- UTF-8 characters and JSON strings can cross arbitrary OS pipe chunks.
- Extension dialog requests can block Pi until the client answers or their
  extension timeout expires.
- Closing stdin while a run is active asks Pi to dispose; forced termination is
  still required as a bounded fallback.
- A process exit before a response is a transport failure even if exit code is
  zero.

## Non-goals

- A graphical interface, terminal UI, web server, or network transport.
- Supporting multiple concurrent Pi processes or multiple caller runspaces.
- Recreating every RPC command as a PowerShell cmdlet.
- Automatic reconnect, replay, durable message queues, or session recovery.
- Auto-approving extension dialogs.
- Hiding the protocol behind a production-grade generic JSON-RPC library.
- Replacing sample 014's tree/compaction lesson or sample 017's deterministic
  steering checkpoint.

## Acceptance criteria

- The directory contains all intended scripts, the four required shared
  symlinks, the fake server, UI probe, and an instructive README.
- `PiRpc.psm1` exports exactly the five documented functions and launches
  processes through `ProcessStartInfo.ArgumentList`.
- Strict LF/UTF-8 framing survives partial bytes, U+2028/U+2029, embedded bare
  CR, and interleaved stderr.
- Two outstanding requests are correlated by ID even when responses arrive in
  reverse order with events between them.
- Failed commands remain inspectable responses; malformed stdout, duplicate or
  unknown response IDs, EOF, and timeouts fault clearly and safely.
- The event queue is bounded, preserves unmatched ordering, and reports
  overflow; responses are never discarded as event pressure.
- The real offline Pi checks cover state, available models, commands,
  unknown-command failure, parse failure, and normal EOF shutdown without a
  provider request.
- The UI probe proves confirm is false and select/input/editor are cancelled;
  no unknown dialog is auto-approved.
- `pwsh ./verify.ps1` exits zero from any working directory and leaves no fake,
  child, or Pi process.
- `pwsh ./verify-live.ps1` observes prompt streaming, steer, follow-up,
  session-level `agent_settled`, and abort with stable marker/order assertions,
  then leaves no Pi process.
- `demo.ps1` uses the prepared Azure variables, an explicit model, `--no-tools`,
  bounded waits, and cleanup in `finally` without exposing secrets.
- `git diff --check` passes and the sample has been run according to the
  repository rule before implementation is marked complete.

## References

- [Pi RPC mode](https://pi.dev/docs/latest/rpc)
- [Pi JSON mode](https://pi.dev/docs/latest/json)
- [Pi CLI usage](https://pi.dev/docs/latest/usage)
- Installed Pi 0.80.6 `dist/modes/rpc/rpc-types.d.ts`
- Installed Pi 0.80.6 `dist/modes/rpc/rpc-mode.js`
- Installed Pi 0.80.6 `dist/modes/rpc/jsonl.d.ts`
