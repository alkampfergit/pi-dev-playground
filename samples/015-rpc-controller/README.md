# 015 — Pi as a long-lived RPC service

This sample teaches you to keep one `pi --mode rpc` process alive and control
it from PowerShell. The boundary is JSONL over a child process's stdin,
stdout, and stderr; it is not network JSON-RPC.

The implementation was validated with Pi `0.80.6`. Start by checking your
installed version:

```powershell
pi --version
```

If a newer Pi changes a response or event shape, treat that as protocol drift
and inspect the current RPC documentation before relaxing an assertion.

## 1. Prepare the sample

Run this from the sample directory and source the preparation script. The dot
is important: sourcing keeps `PI_CODING_AGENT_DIR` and the prepared
`AZURE_PI_TEST_*` variables in your current shell.

```powershell
cd samples/015-rpc-controller
. ./prepare.ps1
```

In bash, use `source ./prepare.sh`. Do not put an API key in a script or on a
command line. The shared `models.json` reads `AZURE_PI_TEST_API_KEY` from the
inherited environment.

## 2. Establish the local contract first

```powershell
pwsh ./verify.ps1
```

This is model-free. It runs a deterministic fake protocol peer, then Pi in
the offline profile. It checks strict LF framing, partial UTF-8, response
correlation, event ordering and overflow, stderr separation/redaction,
malformed frames, unknown commands, normal EOF shutdown, the explicit UI
probe, and process-tree cleanup. It creates temporary configuration outside
the sample and restores its environment in `finally`.

## 3. Trace the controller

`PiRpc.psm1` exports exactly five functions:

```powershell
Start-PiRpc; Send-PiRpcRequest; Wait-PiRpcResponse
Wait-PiRpcEvent; Stop-PiRpc
```

The controller copies your request, assigns a monotonic ID, registers it
before writing one UTF-8 JSON record plus LF, and returns immediately. Its
router places responses in an ID map and asynchronous records in a bounded
FIFO. A response acknowledges acceptance; it is not the assistant result.

```text
stdin request ──► Pi
                 ├──► response(id) ──► response map
                 ├──► agent event ───► bounded event buffer
                 └──► UI request ────► deny/cancel response + event buffer
stderr ──────────────────────────────► bounded sanitized diagnostic tail
```

The C# helper inside the module owns only byte transport. It uses a stateful
UTF-8 decoder, splits on literal LF, strips one CR immediately before LF, and
publishes stdout and stderr records separately. JSON parsing, routing, timeouts
and policy remain visible PowerShell.

## 4. Run the live lifecycle demo

With the sample prepared and the two required Azure variables available:

```powershell
pwsh ./demo.ps1
```

The demo uses an explicit model and `--no-tools`. It pipelines discovery
requests, sends a long prompt, steers while `isStreaming` is true, queues a
follow-up, displays text deltas, and waits for `agent_settled`:

```text
prompt response (accepted)
  → agent_start
  → ... first agent_end
  → queued steer/follow-up continuation(s)
  → ... later agent_end
  → agent_settled (controller may now call the run complete)
```

It then uses `get_last_assistant_text` and `get_session_stats`, starts a second
long prompt, aborts after its first text delta, and waits for the aborted run
to settle. Providers can finish too quickly to steer; the demo reports that
race and asks you to rerun instead of claiming delivery.

The explicit live command is:

```powershell
pwsh ./verify-live.ps1
```

Missing credentials produce a nonzero `NOT VERIFIED` result, never `PASS`.
Provider authentication, quota, and rate-limit errors are reported separately
from local protocol failures.

## 5. Extension UI is a policy boundary

Run the model-free probe yourself by reading the verifier's explicit `-e
./extensions/rpc-ui-probe.ts` launch. In RPC mode the client is the UI, so this
sample chooses the fail-closed `DenyDialogs` policy:

- `confirm` receives `confirmed: false`;
- `select`, `input`, and `editor` receive `cancelled: true`;
- notifications and status changes are observed but do not block; and
- unknown methods are cancelled, never approved.

The controller answers blocking UI requests inside the routing pump, before it
returns another event. Otherwise an extension waiting for a dialog could
deadlock the client. `rpc-ui-probe.ts` performs no model, file, or shell work.

## 6. Optional persistent session

After preparing the sample, try the isolated session exercise:

```powershell
pwsh ./demo-persistent.ps1
pwsh ./demo-persistent.ps1 -KeepSession
```

It uses a generated session directory and name, then demonstrates
`set_session_name`, `get_entries`, `get_tree`, `get_session_stats`, and
`clone` only after a live message exists. The temporary directory is removed
unless `-KeepSession` is supplied. Session tree navigation and compaction are
covered by the neighboring session lesson.

## Experiments and production gaps

Wait for the two discovery responses in the opposite order, or replace
`--no-tools` with a narrow read-only allowlist in a private experiment. The
controller intentionally supports one caller thread and one child process.
Production work would still need an authentication boundary, a richer
interactive UI policy, protocol versioning, reconnection/replay, persistence,
telemetry, and an explicit multi-client ownership model.

The process is shut down by closing stdin. `Stop-PiRpc` continues draining the
redirected pipes, waits for the requested bound, and uses `Kill($true)` only as
a bounded fallback. Every sample script pairs startup with `Stop-PiRpc` in
`finally`; learners should use the public functions rather than reaching into
the opaque controller object's process or queues.
