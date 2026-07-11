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

## 3. Wire Log, auto-discovered

Then move to [003 — Wire Log, auto-discovered](../samples/003-wire-log-global/README.md).
It takes the same [wire-log extension](../samples/003-wire-log-global/extensions/wire-log.ts)
and drops it into the sample's `extensions/` folder so pi loads it automatically
— no `--extension` flag. The key lesson is that pi's auto-discovery path is
`<config-dir>/extensions/`, and because the sample's `prepare` scripts point
`PI_CODING_AGENT_DIR` at the sample, that path is the sample's own `extensions/`
folder — not `~/.pi/agent/extensions/`. Because an always-loaded logger must stay
out of the way, it defaults to off and adds a `/wire-log on|off|status` command
that flips an in-memory flag the hooks read, teaching how `pi.registerCommand()`
wires a runtime toggle with no restart.

## 4. Extend and manage tools

Next, use [004 — Extend and manage tools](../samples/004-tools/README.md). It
offers two real tools registered with `pi.registerTool()`: a structured
DuckDuckGo Instant Answer lookup and an HTML web-results search. The extensions
introduce
`pi.setActiveTools()`, showing how an interactive session can immediately
remove built-ins such as `bash`, `edit`, and `write`. It also covers the CLI
equivalents: `--tools` for an allowlist and `--exclude-tools` for a denylist.

## 5. Project instructions and two simple skills

Continue with [005 — Project instructions and one simple skill](../samples/005-context-and-skills/README.md).
It contrasts automatic `AGENTS.md` context with an explicitly selected
`SKILL.md`: the project instructions greet Gian Maria Ricci in the first
response, while a haiku skill supplies a focused response procedure and a
`encrypt` skill invokes bash and PowerShell ROT13 scripts. Run it once interactively and
once with `-p` to see that the same skill works in both modes.

## Next

Move to the [notebooks](../notebooks/) for the SDK learning path: basic calls,
streaming, tools, structured output, providers, and coding-agent APIs.
