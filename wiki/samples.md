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

## 003 — Wire Log, auto-discovered

Takes the sample 002 extension and lets pi discover it automatically instead of
loading it ad-hoc with `-e`. The file lives in the sample's `extensions/` folder,
which is pi's auto-discovery path `<config-dir>/extensions/`: because the sample's
`prepare` scripts point `PI_CODING_AGENT_DIR` at the sample, that folder — not
`~/.pi/agent/extensions/` — is where pi looks. (Copying it into
`~/.pi/agent/extensions/` while `prepare` is sourced silently fails to load, since
the config dir has been repointed.) Since an always-loaded logger should stay
quiet, it defaults to off and registers a `/wire-log on|off|status` command via
`pi.registerCommand()`. The command handler and the provider hooks share one
in-memory `enabled` flag, so toggling logging takes effect on the next request
with no `/reload`, and the extension creates nothing while off. See the
[sample README](../samples/003-wire-log-global/README.md).

## 004 — Extend and manage tools

Provides two small Pi extensions: a structured `duckduckgo_instant_answer`
lookup and a fuller `duckduckgo_search` that returns no-key DuckDuckGo HTML
results. It then teaches two kinds of per-session tool
control: CLI allow/deny lists (`--tools` and `--exclude-tools`) and runtime
changes from an extension using `pi.setActiveTools()`. Its interactive commands
make it easy to see `bash`, `edit`, and `write` disappear and return without
changing the global Pi setup. See the
[sample README](../samples/004-tools/README.md).

## 005 — Project instructions and two simple skills

Contrasts always-on project context with an explicit skill. The sample-local
`AGENTS.md` identifies Gian Maria Ricci, requires a first-response greeting,
and keeps the exercise read-only. Its tiny `haiku` skill works in both the
interactive UI and one-shot `-p` mode, while `encrypt` shows a skill that
invokes bash and PowerShell scripts. See the
[sample README](../samples/005-context-and-skills/README.md).
