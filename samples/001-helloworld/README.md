# 001 — Hello World

This sample is the smallest end-to-end Pi coding-agent example. You configure
an Azure AI Foundry deployment, ask Pi for a short cat fable, and let Pi's built-in
`write` tool save the result as `fable.md`.

There is no application code in this sample: only the Pi CLI, PowerShell
environment variables, and a natural-language prompt.

## Prerequisites

- Node.js and npm
- An Azure OpenAI deployment of an OpenAI model
- The deployment name and API key for that Azure resource

## 1. Install Pi

```powershell
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
pi --version
```

## 2. Configure Azure OpenAI

Set these variables in the PowerShell session that will run Pi:

```powershell
$env:AZURE_PI_TEST_API_KEY = '<your-foundry-key>'
$env:AZURE_PI_TEST_ENDPOINT = 'https://<your-resource>.ai.azure.com'
$env:AZURE_PI_TEST_DEPLOYMENT = '<your-deployment-name>'
```

The sample reads the exact `AZURE_PI_TEST_*` names used by this repository. It
registers a temporary OpenAI-compatible Pi provider and passes
`AZURE_PI_TEST_DEPLOYMENT` directly as the model ID. This is important for
Foundry deployments such as `cohere-command-a`, which are not built-in GPT
model aliases.

Keep credentials in your PowerShell environment or in a private `.env` file.
The shared [`samples/Env.psm1`](../Env.psm1) module scans from the sample
directory up through its parent directories, loading `.env` files from the root
down so the nearest file wins. Variables already set in PowerShell are kept.
Never commit real keys to this repository.

### Load `.env` into the current PowerShell session

`Env.psm1` is a module, so import it and call `Import-DotEnv` from the
PowerShell session where you want the variables to remain available:

```powershell
Import-Module ./samples/Env.psm1 -Force
$sampleDirectory = (Resolve-Path ./samples/001-helloworld).Path
Import-DotEnv -StartDirectory $sampleDirectory
$env:PI_CODING_AGENT_DIR = $sampleDirectory
```

Afterward, the variables are available in the current session:

```powershell
$env:AZURE_PI_TEST_ENDPOINT
$env:AZURE_PI_TEST_DEPLOYMENT
$env:AZURE_PI_TEST_API_KEY
```

Run these commands directly in your existing `pwsh` window. Running
`pwsh -File ...` would start a child process, so its environment changes would
not be carried back into the parent session. `PI_CODING_AGENT_DIR` tells Pi to
load the sample's [`models.json`](./models.json), which registers the Azure
Foundry deployment for `/model`.

Verify discovery before opening the interactive UI:

```powershell
pi --list-models
```

The output should include `azure-openai` and the deployment from
`AZURE_PI_TEST_DEPLOYMENT`.

## 3. Run Pi interactively

From this directory, start Pi:

```powershell
Set-Location samples/001-helloworld
pi
```

Open the model picker:

```text
/model
```

Choose the model backed by `AZURE_PI_TEST_DEPLOYMENT`, then send this prompt:

```text
Write a short, warm fable about a cat — around 500 words, with a gentle moral
at the end. Save it to fable.md as nicely formatted Markdown with a title
heading. Then show me the file.
```

Pi will generate the story, call its `write` tool, and create `fable.md` in the
current directory. You can continue the conversation, for example:

```text
Make the moral subtler, and add a one-line Italian translation of the title.
```

Verify the file yourself:

```powershell
Get-Content fable.md
```

## 4. Run it in one command

The included script performs the task non-interactively:

```powershell
pwsh ./hello.ps1
```

The script creates a temporary provider configuration from
`AZURE_PI_TEST_DEPLOYMENT`, selects `azure-openai/<AZURE_PI_TEST_DEPLOYMENT>`,
runs Pi in `-p` mode, restricts the agent to the `write` and `read` tools, and
removes the temporary configuration when Pi exits. For interactive use, the
committed `models.json` is loaded through `PI_CODING_AGENT_DIR` as shown above.

## Non-OpenAI Foundry models

This sample includes a custom OpenAI-compatible provider because the configured
Foundry deployment is `cohere-command-a`, rather than a built-in GPT model.

## References

- [Pi coding-agent README](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md)
- [Pi provider configuration](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/providers.md)
