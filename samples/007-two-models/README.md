# 007 — Two models: providers and mid-session handoff

This sample teaches one focused idea: changing models does not require changing
conversations. You will begin one Pi session on a **primary** Azure deployment,
switch that same session to a **secondary** deployment, and inspect the evidence
that the next request uses the new model while retaining the earlier messages.

The words primary and secondary describe only their role in this exercise. They
do not imply that either deployment is cheaper, faster, or more capable.

## What you will learn

By the end, you will be able to:

- inspect configured models and choose one with `--model`;
- change models interactively with Pi's built-in `/model` picker;
- implement the same operation with `ctx.modelRegistry.find()` and
  `pi.setModel()` in an extension command;
- distinguish deployment-name environment variables from the provider and
  model definitions in `models.json`;
- prove that a handoff changed the provider request without creating a new
  session or discarding its conversation history.

## Prerequisites

You need Pi 0.80.6, PowerShell 7, two Azure deployments registered under the
shared `azure-openai` provider, and a repository `.env` containing:

```text
AZURE_PI_TEST_ENDPOINT=<Azure OpenAI endpoint>
AZURE_PI_TEST_DEPLOYMENT=<primary deployment ID>
AZURE_PI_TEST_API_KEY=<API key>
AZURE_PI_TEST_DEPLOYMENT2=<secondary deployment ID, optional>
```

`AZURE_PI_TEST_DEPLOYMENT2` is optional so the sample remains usable with one
deployment. The full handoff exercise requires two distinct IDs. Never put a
real endpoint, deployment ID, or credential in this sample.

The environment variables name deployments and provide authentication. The
actual provider/model metadata is centralized in `../models.json`, reached here
through the `models.json` symlink. Each non-empty deployment ID must match a
model `id` in that shared file.

## Prepare

From PowerShell, enter the sample and dot-source the preparation script:

```powershell
cd samples/007-two-models
. ./prepare.ps1
```

Dot-sourcing matters: it keeps the loaded variables and
`PI_CODING_AGENT_DIR` in your current shell. In bash, use:

```bash
cd samples/007-two-models
source ./prepare.sh
```

Preparation points Pi's complete configuration directory at this sample. Pi
therefore reads its symlinked configuration and auto-discovers
`extensions/handoff.ts`; the walkthrough does not need `-e`.

## Preflight

Check the non-secret deployment names and list Pi's models. Do not print the API
key.

```powershell
if ([string]::IsNullOrWhiteSpace($env:AZURE_PI_TEST_DEPLOYMENT)) {
    throw 'AZURE_PI_TEST_DEPLOYMENT is required.'
}

if ([string]::IsNullOrWhiteSpace($env:AZURE_PI_TEST_DEPLOYMENT2)) {
    Write-Warning 'The secondary handoff exercise will be skipped.'
}

$env:AZURE_PI_TEST_DEPLOYMENT
$env:AZURE_PI_TEST_DEPLOYMENT2
pi --list-models
```

Confirm each non-empty ID appears under `azure-openai`. Discovery proves only
that Pi read the configuration; the live turns later prove that Azure answers.

You can run the model-free contract checks at any time:

```powershell
./verify.ps1
```

The verifier uses Pi RPC mode and a temporary placeholder key to exercise
extension discovery, status, explicit switching, bare toggling, invalid input,
missing-secondary, unknown-ID, and duplicate-ID behavior. It never contacts
Azure and restores the process environment when it finishes.

## Exercise 1: use Pi's built-in model picker

Start explicitly on primary so this lesson does not depend on the shared
default model:

```powershell
pi --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
```

In Pi:

1. Send `Remember that the project codename is Lantern.`
2. Enter `/model` and choose the secondary deployment.
3. Ask `What project codename did I give you?`

The picker/footer should show the secondary ID, and the answer should remember
Lantern. That is a useful observation, but model output alone is not proof. The
wire request and session record below are the authoritative evidence.

## Exercise 2: use `/handoff`

Start another session on primary, then enter these lines one at a time:

```text
/handoff status
Remember that the project codename is Lantern.
/handoff secondary
What project codename did I give you?
/handoff
/handoff status
```

`/handoff secondary` reports the primary-to-secondary transition. The next
prompt—not the command itself—is sent to secondary. Bare `/handoff` toggles
back to primary. These UI notifications do not become conversation messages,
and none of these commands opens a new session.

The deterministic forms are `/handoff primary` and `/handoff secondary`.
`/handoff status` shows current, primary, and secondary models. Tab completion
offers all three arguments.

## Prove the provider request changed

Reuse sample 003's wire logger ad hoc; do not copy it into this sample:

```powershell
$env:PI_WIRE_LOG = '1'
try {
    pi -e ../003-wire-log-global/extensions/wire-log.ts `
      --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
}
finally {
    Remove-Item Env:PI_WIRE_LOG -ErrorAction SilentlyContinue
}
```

Inside Pi, send `Remember that the project codename is Lantern.`, enter
`/handoff secondary`, and then ask for the codename. The logger writes beneath
this sample's `dump/` because `PI_CODING_AGENT_DIR` still points here.

Inspect the newest two request files without printing request headers:

```powershell
$folder = Get-ChildItem ./dump -Directory |
  Sort-Object LastWriteTime |
  Select-Object -Last 1

$requests = Get-ChildItem $folder.FullName -Filter '*-request.json' |
  Sort-Object Name |
  Select-Object -Last 2

$first = Get-Content $requests[0].FullName -Raw | ConvertFrom-Json -Depth 100
$second = Get-Content $requests[1].FullName -Raw | ConvertFrom-Json -Depth 100

$first.model
$second.model
$second.messages | Select-Object role
```

Request 1 must name primary. Request 2 must name secondary and contain messages
representing the first user turn and assistant response. That combination proves
both the model change and conversation continuity. Generated dumps are ignored
by Git; remove them when finished.

## Prove the session stayed the same

Locate the newest JSONL session and inspect its model-change records:

```powershell
$session = Get-ChildItem ./sessions -Recurse -Filter *.jsonl |
  Sort-Object LastWriteTime |
  Select-Object -Last 1

Select-String -Path $session.FullName -Pattern '"type":"model_change"'
```

At least one entry must name provider `azure-openai` and the target deployment
ID. The turns and `model_change` must appear in this one file. Pi appends the
change, updates its saved default provider/model, adjusts thinking level for the
target, and emits `model_select`; the extension does not duplicate that state.

## Failure experiments

Every failure is a no-op: check `/handoff status` before and after to confirm the
active model did not change. Use a fresh shell for temporary environment changes
or restore the original values afterward.

- Missing secondary: unset `AZURE_PI_TEST_DEPLOYMENT2`, restart Pi, and try
  `/handoff status` and `/handoff secondary`. Status says `not configured`, the
  command tells you to set the variable, source preparation again, and restart;
  primary remains usable.
- Missing primary: `/handoff primary` gives the corresponding remediation.
- Unknown ID: temporarily set secondary to an ID absent from `models.json`,
  restart, and try the handoff. The message tells you to align `.env` and the
  shared registry, then `/reload` or restart.
- Equal IDs: set both deployment variables to the same ID and restart. A switch
  reports that two distinct deployment IDs are required.
- Missing authentication: if `pi.setModel()` cannot authenticate the target,
  the command mentions `AZURE_PI_TEST_API_KEY` and reports no success. Do not
  expose or overwrite a working key just to manufacture this failure.
- Unknown argument: `/handoff other` prints the usage and changes nothing.
- Unconfigured current model: bare `/handoff` refuses to guess; use an explicit
  `/handoff primary` or `/handoff secondary`.

After a temporary change, source `prepare.ps1` again **and restart Pi**. The
extension reads environment variables from the Pi process, so an already-running
process cannot see changes made in its parent shell.

## APIs used

| Pi 0.80.6 API | Role here |
| --- | --- |
| `pi.registerCommand()` | Registers `/handoff` and argument completion. |
| `ctx.model` | Identifies the model active when the command begins. |
| `ctx.modelRegistry.find(provider, id)` | Resolves an environment-provided ID from the configured registry. |
| `pi.setModel(model)` | Switches the running session; returns `false` when authentication is unavailable. |
| `ctx.ui.notify()` | Reports status and errors without adding LLM context. |

See the installed Pi 0.80.6 documentation in
`@earendil-works/pi-coding-agent/docs/extensions.md`, `models.md`, and
`session-format.md`. In particular, the extension docs cover command
registration, completions, model registry access, and `pi.setModel()`; the model
docs explain `models.json`; and the session-format docs define `model_change`.

## Next experiment

Once this distinction is clear, read about `pi.registerProvider()` and try a
separate local OpenAI-compatible provider. That is deliberately outside this
sample: one provider and two deployments keep the lesson centered on
same-session model selection.
