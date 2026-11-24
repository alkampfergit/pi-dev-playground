# 018 — Intelligent model routing with Pi and local GLiNER2.5

This sample lets you select the virtual Pi model `intent/auto`. A TypeScript
extension asks a local classifier whether a new user request is software work
or a general request, then routes Pi to one of two configured physical models.
The default classifier is **GLiNER2.5**
([`fastino/gliner2.5-base-v1`](https://huggingface.co/fastino/gliner2.5-base-v1)). It performs inference on this
machine; after setup, routing works with Hugging Face offline mode enabled.

Pi's native virtual-model API dispatches to the destination. This sample does
not proxy LLM traffic. Pi retains responsibility for provider authentication,
streaming, tools, history, and the normal agent loop.

## What you will learn

- Register and select a native Pi virtual model.
- Resolve models across providers using Pi's model registry.
- Keep tool continuations and retries on their current physical model.
- Pass bounded, user-only conversation context to a local classifier.
- Separate routing policy tests from real model evaluation.
- Explain why model selection is harness customization rather than prompt
  engineering.

## Architecture

```text
Pi selects intent/auto
        |
        v
Intent router extension ---- JSONL ----> persistent local GLiNER2 Python process
        |                                             |
        +------- configured physical model <----------+

Pi performs every destination-provider request and runs the normal agent loop.
```

The classifier sees the latest user request plus at most three preceding user
turns. It excludes tool results and system messages, and bounds input to 6,000
characters. Model files, Python packages, and Hugging Face cache are kept under
this sample and ignored by Git. The selected destination model still receives
the conversation needed to answer; local classification does not prevent that
provider from receiving context.

## Prerequisites

- macOS with Pi **1.6.0**, Node 22 or later, and `uv`.
- Python 3.12 (the setup script asks `uv` to install/manage it in the sample
  environment if needed).
- Two physical models registered in Pi with their providers configured.
- Allow about 3 GB for GLiNER2.5 weights, Python dependencies, and the download
  cache.
- Network access for the one-time package and model download.

The sample pins the official `gliner2[local]==2.2.0` package and model revision
`07d99c0ba5d15cb3b24e0a236fa99bdd4ef87a5c`, then uses its `AutoExtractor`
classification schema. The model is
Apache-2.0 licensed. It is
not Jeff inference and does not call a hosted classification service.

## Prepare Pi

In a macOS terminal (zsh or bash):

```bash
cd samples/018-intent-router
source ./prepare.sh
pi --version
```

The shared PowerShell preparation script remains available too:

```powershell
cd samples/018-intent-router
. ./prepare.ps1
pi --version
```

Preparation loads the repository `.env`, sets `PI_CODING_AGENT_DIR` to this
sample, and shares the repository's models and settings. The example
`intent-router.json` uses the shared registry's Azure OpenAI models
`cohere-command-a` and `Kimi-K2.5`. Replace these provider/model IDs in JSON to
use any two configured physical models; no extension source edits are needed.
Pi handles the model credentials.

## Install the local classifier

From the sample directory, run:

```bash
./setup-local-classifier.sh
```

The script creates `.venv/` with Python 3.12, installs GLiNER2's local inference
extra, and downloads `fastino/gliner2.5-base-v1` once. It packages all model
and tokenizer assets under `models/gliner2.5-base-v1/`. Python
packages, Hugging Face cache, the environment, and weights stay inside this
sample and are gitignored. You can inspect or remove these local assets without
changing shared machine configuration.

Subsequent inference loads only the packaged local model with
`local_files_only=True` and Hugging Face offline mode. The model is initialized
once per Pi process and reused. Its score is a model score, not a calibrated
probability; `classifier.confidenceThreshold` is a configurable cutoff. Review
the evaluation output before tuning it. First use includes model load time.

## Load and select `intent/auto`

The sample auto-discovers `extensions/intent-router.ts` because preparation
sets Pi's config directory to this sample:

```bash
pi --model intent/auto
```

For one-off loading without sourcing preparation:

```bash
export PI_CODING_AGENT_DIR="$PWD"
pi --extension ./extensions/intent-router.ts --model intent/auto
```

Inside Pi, use:

```text
/router status
/router stats
/router config
```

The first user request displays the chosen intent, GLiNER2.5 score, selected
physical model, measured decision time, and reason. Tool continuations do not
produce repeated notices. The config command omits credentials and prompt text.

Retries preserve the failed physical model by default. Set
`routing.failoverOnProviderError` to `true` to opt into switching to the other
configured destination after a recognized transient provider failure.

## Run the demonstration

Start one Pi session with `pi --model intent/auto`, then try:

```text
What is the difference between OAuth and OIDC?
Write a C# function that validates JWTs and add unit tests.
Now add cancellation token support.
Explain why you implemented it that way.
/router stats
```

The second and third prompts exercise software-work routing and sticky tool
continuations. The final prompt uses bounded conversation context. See
[DEMO.md](DEMO.md) for a five-minute presentation script.

## Tests and local evaluation

The model-free router tests and Pi model discovery check do not need GLiNER2,
provider credentials, or a live provider call:

```bash
./verify.sh
```

`verify.ps1` is also kept for the repository's PowerShell sample workflow.

After setup, evaluate the real local GLiNER2.5 classifier against the 20 labeled
examples:

```bash
node --experimental-strip-types ./tests/integration.test.ts
```

It reports measured accuracy, confusion counts, scores, and mean decision
latency. The latest Mac run produced 19/20 (95%) accuracy at 555.7 ms mean
decision latency. The small dataset is a teaching smoke test, not a production
benchmark. Improve the held-out examples and
measure the model before treating route quality as established. To evaluate an
installed task-specific Jeff adapter instead, set `INTENT_ROUTER_ENGINE=jeff`,
`JEFF_INTENT_ADAPTER`, and optionally `JEFF_PYTHON`; Jeff runs only through its
local Python SDK, and is never silently substituted for GLiNER.

## Troubleshooting

- **No local model:** run `./setup-local-classifier.sh`; check that
  `models/gliner2.5-base-v1` contains the local checkpoint files.
- **Python import error:** use the sample environment at `.venv/bin/python`,
  then rerun setup.
- **Timeout or low score:** check first-load time, the configured timeout, and
  evaluation results; adjust the threshold based on measured behavior.
- **Configured destination unavailable:** check its exact provider and ID in
  `pi --list-models` and verify that provider credentials are configured.
- **Different Pi API:** compare the code with installed `docs/virtual-models.md`
  and the extension types. This sample was implemented against Pi 1.6.0.

## Security and limits

- The GLiNER2 process is local and receives no provider credentials. Its inference
  code is forced offline after setup.
- Configuration contains model identifiers and policy settings, never API keys.
- Only the configured coding or general physical model can be selected.
- Prompts and classifier exceptions are not logged; only user turns enter the
  bounded classifier context. Repository/tool text cannot change router policy.
- Local classification does not prevent the chosen remote model provider from
  receiving the context needed to answer.
- GLiNER2's score is not calibrated confidence. Router unit tests verify policy
  behavior; only the opt-in integration command measures the real model.
- An optional Jeff backend is provided for a separately installed, task-specific
  local adapter. The default sample does not claim Jeff classification accuracy.
