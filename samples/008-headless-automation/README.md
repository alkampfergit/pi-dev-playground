# 008 — Pi as a Unix tool: headless automation

Pi does not have to own the terminal. In this sample, PowerShell treats it as
a native child process with a small, explicit contract:

- command-line arguments carry the extraction instruction;
- stdin carries fixture data;
- stdout carries either the final value or a JSONL event stream;
- stderr carries diagnostics; and
- the exit code says whether the turn succeeded.

The result is a batch driver that is useful in the same places as any other
command-line program: local scripts, CI steps, and the boundary before a larger
SDK integration.

This sample was designed and verified with Pi coding-agent `0.80.6`. CLI flags,
event shapes, and exit behavior are version-sensitive, so begin by checking the
version you are actually running.

## 1. Prepare the sample

Open PowerShell in this directory and source the shared preparation script:

```powershell
cd samples/008-headless-automation
. ./prepare.ps1
pi --version
"azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
```

Sourcing matters: it loads the `AZURE_PI_TEST_*` variables from the repository
`.env` and sets `PI_CODING_AGENT_DIR` in your current shell. The driver refuses
to run if that directory points at a different sample.

## 2. See the process boundary directly

Before using the driver, pipe one fixture into Pi:

```powershell
Get-Content -Raw ./fixtures/planets.md |
  pi --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" `
    --no-session --tools read -p `
    'Extract the fixture as JSON using the documented sample schema.'
```

Here the quoted argument describes the operation, while the file content
arrives independently on stdin. Pi trims the piped text and merges it into the
initial prompt. The direct command is intentionally small; the driver adds
strict validation, diagnostic separation, atomic output, and batch status.
An exit-0 response that fails event or summary validation receives one bounded
retry; process failures fail immediately, and a second invalid response fails
the item. The retry never weakens the contract checks.

## 3. Run the text batch

```powershell
pwsh ./run-batch.ps1
Get-Content ./output/text/planets.json
Get-Content ./output/text/release-notes.json
Get-Content ./output/text/service-status.json
```

The driver processes fixture basenames in ordinal order. Every call is
independent (`--no-session`) and exposes only Pi's `read` tool. It also disables
extensions, skills, prompt templates, and context files so this exercise has a
fixed capability surface.

Text stdout is the model's summary sentence and may vary in wording. The driver
parses the committed fixture itself for the stable ID, title, and exact count of
three bullets, then wraps those deterministic fields and the non-empty summary
into canonical JSON before atomically promoting `output/text/<fixture>.json`.

Choose individual fixtures when developing a script:

```powershell
pwsh ./run-batch.ps1 -Fixture planets,service-status
```

The default is fail-fast. Use `-ContinueOnError` when you want every selected
item attempted; the final process exit is still non-zero if any item failed.

## 4. Consume JSON events

```powershell
pwsh ./run-batch.ps1 -Mode Json -Fixture planets
Get-Content ./output/json/planets.events.jsonl | ForEach-Object {
  $_ | ConvertFrom-Json | Select-Object type
}
Get-Content ./output/json/planets.json
```

Each non-empty stdout line is a complete JSON object, not one fragment of a
large JSON array. The first line is a `session` header. Lifecycle records then
include `agent_start`; the last assistant `message_end` contains the result and
its `stopReason`; and a successful turn emits `agent_end`. Pi 0.80.6 may then
emit an `agent_settled` bookkeeping record, so consumers should not assume
`agent_end` is literally the last line.

The driver parses every line, rejects an error or aborted assistant turn, and
wraps the assistant summary into the same canonical result as text mode. It preserves the original
stream beside that result so a program can consume progress, tool, usage, and
lifecycle information. A zero child exit code alone is not treated as proof of
a valid JSON-mode turn.

If Pi writes diagnostics, the driver saves them separately as
`<fixture>.stderr.log` and mentions the path. It never mixes stderr into a JSON
or JSONL primary output. Generated files live under the ignored `output/`
directory.

## 5. Verify the real boundary

The verifier requires the configured Azure deployment and makes real model
calls:

```powershell
pwsh ./verify.ps1
```

It checks the Pi version and shared links, runs all three fixtures in text mode,
runs `planets` in JSON mode, parses the produced files, and then deliberately
selects a nonexistent model. That failure must return non-zero without
promoting a partial result. Finally, it asks Pi to create a marker while only
`read` is allowed and proves the marker does not exist. Session-file snapshots
prove the entire verification remained ephemeral.

When `AZURE_PI_TEST_DEPLOYMENT2` is configured, the verifier uses that model for
its successful calls; otherwise it uses `AZURE_PI_TEST_DEPLOYMENT`. The batch
driver itself remains configurable with `-Model` and defaults to the primary.

The fixture metadata and required fields are deterministic; the model's summary
sentence is not. The verifier therefore checks structure and stable facts
instead of comparing generated prose byte for byte. Having the script produce
the JSON envelope also avoids making automation correctness depend on whether a
particular model chooses to add prose around requested JSON.

## Capability boundary

`--tools read` is a Pi capability allowlist. It removes `bash`, `edit`, and
`write` from the model's available tools, which is the safety property tested
here. It is not an operating-system sandbox. Use public, non-sensitive inputs
and apply OS/container isolation separately when your threat model requires it.

## Integration ladder

| Interface | stdin meaning | stdout meaning | Use it for |
| --- | --- | --- | --- |
| `-p` / text | Initial prompt data | Final assistant text | Simple scripts and CI steps |
| `--mode json` | Initial prompt data | JSONL event stream | Progress, tool, usage, and lifecycle consumers |
| `--mode rpc` | JSONL commands | JSONL responses/events | A long-lived controller or custom UI |

RPC is only the next conceptual rung here. Its stdin is reserved for commands,
so do not pipe a fixture to it as if it were print mode. The SDK notebooks are
the natural next stop when the process needs richer state or direct APIs.

JSON-mode events are also not saved session JSONL. Interactive `/export` and
`/import` work with session data, while `pi --export <session> [html]` renders a
saved session. This sample uses `--no-session`; session export and branching
belong to sample 010.
