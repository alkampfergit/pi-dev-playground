# 007 — Two models: providers and mid-session handoff

## Goal

Teach that model choice belongs to the running Pi session, not to a new
conversation. The learner starts one conversation on the deployment named by
`AZURE_PI_TEST_DEPLOYMENT`, moves the same session to
`AZURE_PI_TEST_DEPLOYMENT2`, and verifies that the next provider request uses
the new model while retaining the earlier messages.

This is a model-selection lesson, not a benchmark. The two deployments are
called **primary** and **secondary** throughout the sample; the documentation
must not claim that either is cheaper, faster, or more capable unless the
learner knows that from their own Azure configuration.

## Learning outcomes

After completing the sample, the learner should be able to:

- list the models available to Pi and choose one at startup with `--model`;
- use Pi's built-in `/model` picker to change the model interactively;
- explain that a model switch appends a `model_change` entry to the current
  JSONL session instead of creating a replacement session;
- find a configured model with `ctx.modelRegistry.find(provider, modelId)` and
  switch to it with `pi.setModel(model)` from an extension command;
- distinguish an environment variable that names a deployment from the model
  definition and provider authentication in `models.json`;
- verify from provider request payloads that the model changed while the
  conversation history remained available.

## Repository and configuration constraints

The sample must use the existing Azure provider named `azure-openai` and the
four established environment variables:

```text
AZURE_PI_TEST_ENDPOINT
AZURE_PI_TEST_DEPLOYMENT
AZURE_PI_TEST_API_KEY
AZURE_PI_TEST_DEPLOYMENT2   # optional
```

Do not commit deployment IDs, endpoints, or credentials to the sample. The
extension reads the two deployment IDs from `process.env` at command time. The
provider definition and model metadata remain in the shared
`samples/models.json`; therefore this sample uses the standard symlink rather
than a private model registry. The configured IDs in `samples/models.json`
must match the values supplied by the learner's `.env`.

`AZURE_PI_TEST_DEPLOYMENT2` is deliberately optional. Its absence disables
only the secondary handoff demonstration. Pi must still start, the primary
model must remain usable, `/handoff status` must explain what is missing, and
no command may change the current model accidentally.

An additional provider is out of the executable scope. The README may include
a short “next experiment” note about `pi.registerProvider()`, but the sample
must not require a local server, another API key, or another provider to pass.

## Exact files to implement

Create this layout:

```text
samples/007-two-models/
├── README.md
├── extensions/
│   └── handoff.ts
├── models.json   -> ../models.json
├── settings.json -> ../settings.json
├── prepare.ps1   -> ../prepare.ps1
└── prepare.sh    -> ../prepare.sh
```

### `README.md`

Turn this brief into a teacher-to-student walkthrough. It must contain:

1. prerequisites and the exact `.env` variable names;
2. PowerShell-first preparation with `. ./prepare.ps1`, plus the equivalent
   `source ./prepare.sh` command for bash;
3. a preflight section that checks both variables and runs `pi --list-models`;
4. a manual exercise using the built-in `/model` picker;
5. an extension exercise using `/handoff`;
6. wire-log and session-file verification;
7. the missing-secondary and other failure cases listed below;
8. a short explanation of the APIs used, with references to Pi 0.80.6
   extension and model documentation.

Use PowerShell for executable examples. Do not print the API key during
preflight. A suitable non-secret check is:

```powershell
$env:AZURE_PI_TEST_DEPLOYMENT
$env:AZURE_PI_TEST_DEPLOYMENT2
pi --list-models
```

Start the exercise explicitly on the primary model so it does not depend on
the shared `settings.json` default:

```powershell
pi --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
```

Because `PI_CODING_AGENT_DIR` points at this sample and the extension is under
`extensions/`, Pi auto-discovers it; the normal walkthrough must not need
`-e ./extensions/handoff.ts`.

### `extensions/handoff.ts`

Export the standard Pi extension factory and register one command named
`handoff`. Keep the implementation dependency-free and small enough to read in
one sitting.

The command surface is:

```text
/handoff status
/handoff primary
/handoff secondary
/handoff
```

Semantics:

- `status` reports the current `provider/model`, the configured primary ID,
  and either the configured secondary ID or `not configured`.
- `primary` deterministically selects `AZURE_PI_TEST_DEPLOYMENT`.
- `secondary` deterministically selects `AZURE_PI_TEST_DEPLOYMENT2`.
- a bare `/handoff` toggles primary to secondary or secondary to primary. If
  the current model is neither configured deployment, it refuses to guess and
  instructs the learner to use `/handoff primary` or `/handoff secondary`.
- any other argument prints `Usage: /handoff [status|primary|secondary]` as an
  error and makes no change.

Provide argument completions for `status`, `primary`, and `secondary` through
`getArgumentCompletions`.

The implementation sequence for a model-changing command is exact:

1. normalize the argument with `trim().toLowerCase()`;
2. read the relevant deployment ID from `process.env` and trim it;
3. validate configuration before looking up or changing a model;
4. resolve the target with
   `ctx.modelRegistry.find("azure-openai", targetId)`;
5. capture a displayable source from `ctx.model` before the change;
6. call `await pi.setModel(targetModel)`;
7. check the returned boolean and notify the learner of success or failure;
8. on success, report the explicit transition
   `azure-openai/<source> -> azure-openai/<target>`.

Use `ctx.ui.notify(message, "info" | "success" | "error")` for all command
feedback. Do not send command status into the LLM conversation, do not send a
new user message automatically, and do not create a new session. The learner
must type the next prompt; that makes it clear that the switch applies to the
next provider request.

The implementation uses these Pi 0.80.6 APIs:

| API | Purpose in this sample |
| --- | --- |
| `pi.registerCommand()` | Registers `/handoff` and its completions. |
| `ctx.model` | Identifies the model active when the command begins. |
| `ctx.modelRegistry.find(provider, id)` | Resolves an environment-provided deployment ID to a configured Pi model. |
| `pi.setModel(model)` | Changes the running session model; returns `false` if no authentication is configured. |
| `ctx.ui.notify()` | Reports status, success, and actionable errors without adding model context. |

Pi's underlying session operation records the successful switch as a
`model_change`, updates the saved default provider/model, re-clamps the
thinking level for the target model, and emits `model_select`. The sample need
not add its own `model_select` listener or persist duplicate extension state.

## Required failure behavior

Every failure is a no-op: the model active before the command remains active.

| Condition | Required behavior |
| --- | --- |
| `AZURE_PI_TEST_DEPLOYMENT` is unset/blank | `/handoff primary`, bare toggle when it needs primary, and primary details in `status` report that the primary deployment is not configured. |
| `AZURE_PI_TEST_DEPLOYMENT2` is unset/blank | `/handoff secondary` and a bare toggle from primary report: set `AZURE_PI_TEST_DEPLOYMENT2` in `.env`, source `prepare` again, then restart Pi. `/handoff status` shows `secondary: not configured`. |
| Primary and secondary IDs are equal | A request to switch between them reports that two distinct deployment IDs are required and does not call `pi.setModel()`. |
| Environment ID is not present in `models.json` | Report `Model azure-openai/<id> was not found in models.json`; tell the learner to align the shared registry and `.env`, then run `/reload` or restart Pi. |
| Target model has no configured authentication | If `pi.setModel()` returns `false`, report that authentication is unavailable and mention `AZURE_PI_TEST_API_KEY`; retain the source model. |
| Target is already current | Report `Already using azure-openai/<id>` as informational success; do not present it as a handoff. |
| Current model is undefined | `status` displays `current: none`; explicit `primary` or `secondary` may still select a valid target. Bare `/handoff` refuses to guess. |
| Unknown command argument | Show usage as an error; do not change state. |

Do not catch and hide unexpected exceptions. If a defensive `try/catch` is
used around `pi.setModel`, notify with the exception message and preserve the
same no-op expectation; never claim that the switch succeeded unless
`pi.setModel()` returned `true`.

## Walkthrough to document

### 1. Prepare and preflight

```powershell
cd samples/007-two-models
. ./prepare.ps1

if ([string]::IsNullOrWhiteSpace($env:AZURE_PI_TEST_DEPLOYMENT)) {
    throw 'AZURE_PI_TEST_DEPLOYMENT is required.'
}

if ([string]::IsNullOrWhiteSpace($env:AZURE_PI_TEST_DEPLOYMENT2)) {
    Write-Warning 'The secondary handoff exercise will be skipped.'
}

pi --list-models
```

The README must tell the learner to confirm that each non-empty deployment ID
appears under provider `azure-openai`. Listing a model proves discovery, not
that the Azure deployment will answer successfully; the live turns provide
that proof.

### 2. Observe the built-in picker

Start Pi on the primary model, send a short prompt that establishes a memorable
fact (for example, `Remember that the project codename is Lantern.`), run
`/model`, choose the secondary deployment, and ask for the codename. The second
answer demonstrates retained conversation context.

The README must be explicit that this is a practical observation, not absolute
proof from model output alone. The provider request and JSONL checks below are
the authoritative verification.

### 3. Use `/handoff`

In a session started on primary, run:

```text
/handoff status
/handoff secondary
What project codename did I give you?
/handoff
/handoff status
```

The first switch should report primary to secondary; the bare toggle should
then return to primary. No command should erase earlier messages or open a new
session.

### 4. Verify provider requests with sample 003's wire logger

Reuse the already implemented logger ad hoc rather than copying it. From this
sample directory in PowerShell:

```powershell
$env:PI_WIRE_LOG = '1'
pi -e ../003-wire-log-global/extensions/wire-log.ts `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
Remove-Item Env:PI_WIRE_LOG
```

Inside Pi, send one prompt, run `/handoff secondary`, then send another. The
wire logger writes beneath this sample's `dump/` because
`PI_CODING_AGENT_DIR` still names `samples/007-two-models`.

Inspect the two request files in the newest session folder. Acceptance requires
that:

- request 1 contains the primary deployment in its `model` field;
- request 2 contains the secondary deployment in its `model` field;
- request 2 contains messages representing both the first user turn and its
  assistant response, demonstrating continuity.

Clear `PI_WIRE_LOG` after the run so later Pi sessions do not log unexpectedly.

### 5. Verify the session record

Locate the newest JSONL file below this sample's `sessions/` directory and
search it from PowerShell:

```powershell
$session = Get-ChildItem ./sessions -Recurse -Filter *.jsonl |
  Sort-Object LastWriteTime |
  Select-Object -Last 1

Select-String -Path $session.FullName -Pattern '"type":"model_change"'
```

At least one matching entry must contain provider `azure-openai` and the target
deployment ID. Both turns and the model-change entry must be in the same JSONL
file.

## Verification matrix

| Scenario | Setup and action | Evidence required |
| --- | --- | --- |
| Discovery | Both deployment variables set; run `pi --list-models`. | Both IDs appear under `azure-openai`. |
| Manual switch | Start primary, establish a codename, use `/model`, then ask for it. | Footer/picker shows secondary and the next response retains the codename. |
| Explicit extension switch | Start primary; `/handoff secondary`; send next prompt. | Success notification names primary and secondary; next wire request uses secondary. |
| Bare toggle | While on secondary, run bare `/handoff`. | Success notification names secondary and primary; status reports primary. |
| Conversation continuity | Capture the request before and after the handoff. | Second request has the new model ID and includes earlier conversation messages. |
| Session persistence | Inspect the JSONL after a successful switch. | One session file contains both turns and a matching `model_change` entry. |
| Missing optional deployment | Launch with `AZURE_PI_TEST_DEPLOYMENT2` unset; run status and secondary handoff. | Extension loads; status says not configured; handoff gives remediation; primary still answers. |
| Unknown model ID | Set secondary to an ID absent from shared `models.json`; restart; request secondary. | Actionable lookup error; current model does not change. |
| Same IDs | Set both deployment variables to the same ID; restart; attempt toggle. | Distinct-ID error; no misleading success message and no model change. |
| Authentication unavailable | Run in a controlled shell where the target provider has no usable key, if feasible. | `pi.setModel()` failure is reported; no success notification. This may be documented rather than exercised against the learner's working Azure setup. |
| Invalid command | Run `/handoff other`. | Usage error; current model remains unchanged. |

When temporarily changing environment variables for a negative test, use a new
shell or restore the original values afterward. Never edit or expose the real
API key to manufacture a failure.

## Acceptance criteria

The implementation is complete only when all of the following are true:

- `samples/007-two-models` contains the exact layout above and all four shared
  files are symlinks to the `samples/` root;
- `README.md` is runnable from the sample directory, uses PowerShell for
  executable commands, and explains both the built-in `/model` route and the
  `/handoff` route;
- Pi 0.80.6 auto-discovers `extensions/handoff.ts` after preparation without an
  explicit extension flag;
- `/handoff status`, `primary`, `secondary`, bare toggle, completions, and
  invalid arguments behave as specified;
- a missing `AZURE_PI_TEST_DEPLOYMENT2` leaves the sample usable and produces
  the exact actionable failure behavior above;
- successful switching uses `ctx.modelRegistry.find()` and
  `await pi.setModel()` rather than mutating settings or session files;
- live primary and secondary turns have been attempted when both Azure
  deployments are available;
- wire payloads prove that the next request changes model and retains prior
  messages;
- the session JSONL contains the corresponding `model_change` in the same
  conversation;
- no credential, endpoint, generated session, wire dump, or test output is
  committed;
- `git diff --check` passes and the documentation/catalog links are updated
  when the plan becomes a runnable sample.

If the optional second deployment is unavailable, implementation may still be
structurally verified and the missing-variable behavior must be run, but the
sample must not be declared fully runtime-verified until a real two-deployment
handoff has been attempted.

## Boundaries

- Do not implement cost-based routing, automatic task classification, model
  ranking, benchmarking, retries, or fallback inference.
- Do not automatically switch back after one answer; this sample teaches a
  visible session-level selection that remains active until the learner changes
  it again.
- Do not create a new conversation or summarize context. Here, “handoff” means
  changing the model that receives the next turn in the same session.
- Do not duplicate sample 003's wire logger or add a second provider solely to
  make the sample look more advanced.
- Do not modify `samples/models.json` merely to satisfy a negative test. The
  registry is shared by every sample.
