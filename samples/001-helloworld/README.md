# 001 — Hello World

This is the first interactive Pi coding-agent sample. From this directory you
load the repository's Azure AI Foundry environment, start Pi, choose the
configured model, and ask Pi to write a cat fable to `fable.md` with its built-in
`write` tool.

All commands below assume that your current PowerShell directory is:

```text
samples/001-helloworld
```

## Prerequisites

- Node.js and npm
- PowerShell (`pwsh`)
- An Azure AI Foundry OpenAI-compatible deployment
- A `.env` file in this directory or one of its parent directories containing:

```text
AZURE_PI_TEST_ENDPOINT=<Azure AI Foundry endpoint>
AZURE_PI_TEST_DEPLOYMENT=<deployment name>
AZURE_PI_TEST_API_KEY=<API key>
AZURE_PI_TEST_DEPLOYMENT2=<second deployment name, Kimi-K2.5>
```

## 1. Install Pi

```powershell
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
pi --version
```

## 2. Load the environment in the current session

From inside this directory, source the shared preparation script. It loads the
nearest `.env` files and sets `PI_CODING_AGENT_DIR` to this directory so Pi
uses the sample's (symlinked) `models.json` when it discovers models.

PowerShell:

```powershell
. ./prepare.ps1
```

bash:

```bash
source ./prepare.sh
```

The leading `. ` / `source` matters: the script must be sourced so its
environment changes stay in your shell. Running it as a child process
(`pwsh -File ./prepare.ps1` or `bash ./prepare.sh`) would not carry the
variables back into your session.

`prepare.ps1` reuses the shared `../Env.psm1` helper; `prepare.sh` is its
self-contained bash equivalent. Both `prepare.ps1`/`prepare.sh` and
`models.json`/`settings.json` are symlinks to the shared files at the
`samples/` root.

Check the values if needed:

```powershell
$env:AZURE_PI_TEST_ENDPOINT
$env:AZURE_PI_TEST_DEPLOYMENT
$env:AZURE_PI_TEST_API_KEY
$env:AZURE_PI_TEST_DEPLOYMENT2
```

Verify that Pi can see the configured model:

```powershell
pi --list-models
```

The output should include the `azure-openai` provider and both deployments:
`cohere-command-a` and `Kimi-K2.5`.

## 3. Run Pi interactively

Start Pi from this directory:

```powershell
pi
```

Open the model picker:

```text
/model
```

Choose either `cohere-command-a` or `Kimi-K2.5`, then send this prompt:

```text
Write a short, warm fable about a cat — around 500 words, with a gentle moral
at the end. Save it to fable.md as nicely formatted Markdown with a title
heading. Then show me the file.
```

Pi creates `fable.md` in the current directory. To verify it:

```powershell
Get-Content fable.md
```

You can continue the conversation, for example:

```text
Make the moral subtler, and add a one-line Italian translation of the title.
```

## 4. Run Pi directly with a prompt

You can skip the interactive UI while still selecting the model explicitly.
`--model` takes the provider and model ID; here the model ID comes from the
`AZURE_PI_TEST_DEPLOYMENT` environment variable:

```powershell
pi --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" `
  --tools write,read `
  -p 'Write a short, warm fable about a cat. Save it to fable.md as Markdown with a title and a gentle moral. Then show me the file.'
```

`-p` is Pi's print/non-interactive mode. The `--tools write,read` option gives
the agent the tools needed to create and read the file. To use the second
deployment instead:

```powershell
pi --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT2" `
  --tools write,read `
  -p 'Write a short, warm fable about a cat. Save it to fable.md as Markdown with a title and a gentle moral. Then show me the file.'
```

## 5. Summarize session usage

After using Pi, generate a Markdown cost report from the JSONL sessions stored
in this sample's `./sessions` directory:

```powershell
pwsh ./session-stats.ps1
```

This writes `session-stats.md` in the current sample directory. The report has
three tables:

- totals for each session;
- totals grouped by provider and model;
- totals grouped by session, provider, and model.

To analyze a different sessions directory or choose another output path:

```powershell
pwsh ./session-stats.ps1 `
  -SessionsDirectory (Join-Path $HOME '.pi/agent/sessions') `
  -OutputPath './session-stats.md'
```

When no `-SessionsDirectory` is supplied, the tool prefers `./sessions` and
falls back to `~/.pi/agent/sessions` if the local directory does not exist.

Only assistant messages containing a `usage` object are included. Token types
are reported separately as input, output, cache read, cache write, and total
tokens. The cost columns contain the matching input, output, cache read, cache
write, and total values recorded by Pi.

## `models.json`

The committed [`models.json`](./models.json) registers both current Azure AI
Foundry deployments as an OpenAI-compatible provider. Its API key is read from
`AZURE_PI_TEST_API_KEY`; no key is stored in the file. The two model IDs mirror
`AZURE_PI_TEST_DEPLOYMENT` and `AZURE_PI_TEST_DEPLOYMENT2`.

If either deployment or `AZURE_PI_TEST_ENDPOINT` changes, update the matching
model `id` or `baseUrl` in `models.json` before running Pi.

## References

- [Pi coding-agent README](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md)
- [Pi custom models documentation](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/models.md)
