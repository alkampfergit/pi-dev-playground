# Pi CLI Samples Course

Use these runnable samples to learn Pi from the terminal. This page gives the
learning order; each sample README contains the exact commands and configuration.

## Shared sample setup

The shared [model registry](../samples/models.json),
[settings](../samples/settings.json), and preparation scripts
([PowerShell](../samples/prepare.ps1) and [Bash](../samples/prepare.sh)) live in
the `samples/` root. Each sample links to them, so every sample uses the same
initialization and model configuration without copying those files.

From inside a sample, dot-source `. ./prepare.ps1` in PowerShell or run
`source ./prepare.sh` in Bash. The scripts load the nearest `.env` values and
set `PI_CODING_AGENT_DIR` to the current sample directory.

## 1. Hello World

Start with [001 — Hello World](../samples/001-helloworld/README.md). It teaches
how to load the shared Azure AI Foundry environment, point Pi at the local model
registry, choose `cohere-command-a` or `Kimi-K2.5` in `/model`, and ask Pi to
write a Markdown file. It also demonstrates direct print mode with
`pi --model ... -p ...`.

After a few runs, use the real [session statistics tool](../samples/001-helloworld/session-stats.ps1)
to inspect Pi's JSONL usage records. The generated report separates tokens and
costs by session, model, and session/model combination.

## 2. Wire Log Extension

Continue with [002 — Wire Log](../samples/002-wire-log/README.md). It loads the
real [wire-log extension](../samples/002-wire-log/wire-log.ts) for one Pi
session and records the provider request body plus response metadata. Use it to
observe what Pi actually sends to the model without permanently installing an
extension.

## Next

Move to the [notebooks](../notebooks/) for the SDK learning path: basic calls,
streaming, tools, structured output, providers, and coding-agent APIs.
