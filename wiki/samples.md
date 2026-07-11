# Samples

This page briefly describes the command-line Pi samples. Each sample has a
local `README.md` with complete setup and usage instructions.

## 001 — Hello World

An interactive first step with the Pi coding agent. From inside the sample
directory, PowerShell loads the repository `.env` values through
`samples/Env.psm1`, points Pi at the sample `models.json`, and starts `pi`.
The model picker exposes the Azure AI Foundry deployments `cohere-command-a`
and `Kimi-K2.5`. The prompt asks Pi to use its built-in `write` tool to create a
short cat fable in `fable.md`.

The same sample also demonstrates direct non-interactive execution with
`pi --model ... -p '<prompt>'`, including explicit model selection. See the
[sample README](../samples/001-helloworld/README.md) for the commands. Its
`session-stats.ps1` tool also produces Markdown tables of token and cost totals
by session, model, and session/model combination; it defaults to the sample's
own `sessions/` directory.

The shared `models.json`, `settings.json`, `prepare.ps1`, and `prepare.sh` now
live at the `samples/` root and are symlinked into each sample. This keeps the
model registry and shell initialization consistent across samples.

## 002 — Wire Log

A ~40-line extension that teaches Pi's extension hooks. `wire-log.ts` subscribes
to `before_provider_request` and `after_provider_response` and writes the exact
JSON request Pi sends to the provider — plus the response status and headers —
to a `dump/` folder that sits next to Pi's own `bin/` and `sessions/` folders.
It is loaded ad-hoc for a single session with `pi --extension ./wire-log.ts`,
never installed permanently. Use it to see model, messages, tools, temperature,
and cache markers exactly as they go over the wire. See the
[sample README](../samples/002-wire-log/README.md).
