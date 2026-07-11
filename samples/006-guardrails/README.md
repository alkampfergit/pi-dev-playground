# 006 — Guardrails: intercept and gate tool calls

Sample 004 controlled which tools the model could see. This sample leaves the
tools available and decides whether one particular call may execute:

| Mechanism | Question answered |
| --- | --- |
| `--tools` / `pi.setActiveTools()` from sample 004 | Can the model see and choose this tool? |
| A `tool_call` handler in this sample | May this specific invocation run now? |

Pi fires `tool_call` after the model emits a valid tool call and before the
underlying tool executes. The auto-discovered extension implements a small
project policy with three visible outcomes:

1. ordinary calls run immediately;
2. `write` and `edit` calls targeting `.env`, `.env.*`, `.git`, or
   `node_modules` are always blocked; and
3. recursive forced `rm` commands require confirmation in the TUI and fail
   closed when a confirmation UI is unavailable.

A block includes a reason. Pi turns it into an error tool result, so the model
can explain the denial or choose a safer action. A notification alone would
not provide that model-visible feedback.

## What is in this sample?

`extensions/guardrails.ts` exports one Pi extension. It registers one
`tool_call` handler and one `/guard` command. The guard is on when the extension
loads, and its state lives only in memory:

| Command | Effect |
| --- | --- |
| `/guard status` | Report `guardrails ON/OFF (this session)` without changing it. |
| `/guard off` | Bypass this extension for the current loaded instance. |
| `/guard on` | Resume checks for the current loaded instance. |

Missing or unknown arguments show the usage and do not change the state.
Restarting Pi or running `/reload` loads a fresh instance with the guard on.
Turning it off intentionally restores normal Pi behavior; it is a teaching
switch, not an administrative authorization mechanism.

The usual `models.json`, `settings.json`, `prepare.ps1`, and `prepare.sh` files
are symlinks to shared files in `samples/`.

## Prerequisites

- Node.js, npm, PowerShell (`pwsh`), and Pi 0.80.6 installed.
- An Azure AI Foundry OpenAI-compatible deployment.
- A `.env` file in this directory or a parent containing the
  `AZURE_PI_TEST_*` variables described in the [root instructions](../../AGENTS.md).

## 1. Prepare and start Pi interactively

In PowerShell:

```powershell
Set-Location samples/006-guardrails
. ./prepare.ps1
pi --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
```

In bash:

```bash
cd samples/006-guardrails
source ./prepare.sh
pi --model "azure-openai/$AZURE_PI_TEST_DEPLOYMENT"
```

Preparation sets `PI_CODING_AGENT_DIR` to this sample, so Pi automatically
discovers `extensions/guardrails.ts`. No `-e` flag is needed. After changing
the extension, use `/reload`; remember that reload also resets the guard to on.

Run `/guard status` first. Seeing `guardrails ON (this session)` proves that
the command was auto-loaded.

## 2. Exercise all three decisions

Enter these prompts one at a time:

```text
Use the write tool to create output/allowed.txt containing "allowed".
Use the write tool to replace .env with TEST_VALUE=changed. Do not use bash.
Use bash to run exactly: rm -rf output/allowed.txt
```

The normal write succeeds. The `.env` call produces a protected-path tool
error and does not modify `.env`. The removal opens a confirmation dialog:

1. choose **No** and verify `output/allowed.txt` remains;
2. repeat the prompt, choose **Yes**, and verify the disposable file is gone.

The model may react to a denied tool result. Inspect the actual tool call and
its result in the transcript; final prose alone does not prove whether the
requested action ran.

The shell check recognizes `rm -rf`, `rm -fr`, compact short-option variants
containing both `r` and `f`, and `rm --recursive --force`. It is deliberately
small enough to read, not a full shell parser.

## 3. Observe the session-local toggle safely

Use a disposable protected-looking path rather than a real credential file:

```text
/guard status
/guard off
Use the write tool to create output/.env.lesson containing "guard is off". Do not use bash.
/guard on
Use the write tool to create output/.env.lesson-blocked containing "guard is on". Do not use bash.
```

The first write bypasses this extension while it is off. The second is blocked
after it is turned on again. Never turn the guard off to experiment with a real
destructive command or a real credentials file.

## 4. Demonstrate fail-closed print mode

Recreate a disposable marker, then give Pi only the `bash` tool. In PowerShell:

```powershell
New-Item -ItemType Directory -Force output | Out-Null
Set-Content -Path output/keep-me.txt -Value 'keep'
pi --no-session --tools bash `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" `
  -p 'Use bash to run exactly: rm -rf output/keep-me.txt. Do not use another command.'
Test-Path output/keep-me.txt
```

The bash equivalent is:

```bash
mkdir -p output
printf 'keep\n' > output/keep-me.txt
pi --no-session --tools bash \
  --model "azure-openai/$AZURE_PI_TEST_DEPLOYMENT" \
  -p 'Use bash to run exactly: rm -rf output/keep-me.txt. Do not use another command.'
test -f output/keep-me.txt && echo 'marker preserved'
```

The marker remains. With `-p`, `ctx.mode` is `print` and `ctx.hasUI` is false.
The extension never waits for input: it returns a block result explaining that
confirmation is unavailable. JSON mode behaves the same way. RPC reports a UI
because an RPC client can answer Pi's UI requests; the interactive exercise in
this sample uses the TUI.

## 5. See the block travel back to the model

Sample 003 can log the provider exchange while this sample keeps its
auto-loaded guard. Start Pi with the logger as an additional, ad-hoc extension.

PowerShell:

```powershell
pi -e ../003-wire-log-global/extensions/wire-log.ts `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
```

Bash:

```bash
pi -e ../003-wire-log-global/extensions/wire-log.ts \
  --model "azure-openai/$AZURE_PI_TEST_DEPLOYMENT"
```

Inside Pi, run `/wire-log on`, request the exact `rm -rf` command, decline it,
and let the model finish its next turn. Then inspect recent requests:

```powershell
Get-ChildItem -Recurse dump -Filter '*request.json' |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 2 |
  Select-String -Pattern 'Guardrails|denied|confirmation'
```

```bash
rg -n 'Guardrails|denied|confirmation' dump
```

The next provider request contains an error `toolResult` with the extension's
reason. The wire logger is not copied here: sample 003 remains an observability
tool, while this extension is policy.

## How protected paths are matched

The handler resolves a requested path against `ctx.cwd`, normalizes `.` and
`..`, splits it into path components, and compares components without case
sensitivity. Windows drive-rooted absolute inputs are normalized with Node's
Windows path utilities even when the source is inspected elsewhere.

| Input path | Decision | Why |
| --- | --- | --- |
| `output/allowed.txt` | allow | No protected component. |
| `.env` | block | Protected environment file. |
| `./.env.local` | block | Protected environment file after normalization. |
| `node_modules/demo.txt` | block | Protected dependency-directory component. |
| `src/../.git/config` | block | Normalization enters `.git`. |
| `.gitignore` | allow | The filename is not the `.git` directory. |
| `notes/node_modules-guide.md` | allow | A substring is not a complete component. |

Relative and absolute spellings of the same local target therefore receive
the same decision. Path denials never offer an approval dialog.

## Understand the boundary

This extension demonstrates interception; it is **not a security boundary**:

- Path rules inspect only Pi's built-in `write` and `edit` calls. Bash, a
  custom tool, another extension, or an unrelated process can write by another
  route.
- Shell matching covers a teaching-sized set of spellings. It is not a shell
  grammar, command allowlist, or malware detector.
- Lexical path normalization does not resolve symlink targets and cannot
  eliminate time-of-check/time-of-use races.
- `/guard off` bypasses this extension for the current in-memory instance.
- Extensions run inside Pi's process; they do not provide operating-system
  isolation.

Use operating-system/container isolation and narrowly scoped credentials when
you need an enforceable boundary.

## Verification checklist

Use disposable sample-local files and inspect actual tool calls/results:

- `/guard status` works without `-e` and reports on after restart or reload.
- A normal `write output/allowed.txt` succeeds.
- `.env`, `./.env.local`, `node_modules/...`, and normalized `.git` writes are
  blocked; `.gitignore` and `output/node_modules-guide.md` are allowed.
- Editing a disposable `.env.test` is blocked and its original content remains.
- Declining the TUI removal preserves a marker; approving removes it.
- The print-mode command above finishes without a prompt and preserves its
  marker.
- `/guard off` bypasses a harmless probe, and `/guard on` resumes checks.
- The sample 003 wire log shows the reason in the following model request.

Model-driven prompts are integration checks, not deterministic unit tests. A
missing file is proof only if the transcript shows that the requested tool call
actually occurred and was blocked.

## References

- [Pi extension documentation](https://pi.dev/docs/latest/extensions)
- [Sample 003 — auto-discovered wire log](../003-wire-log-global/README.md)
- [Sample 004 — extend and manage tools](../004-tools/README.md)
