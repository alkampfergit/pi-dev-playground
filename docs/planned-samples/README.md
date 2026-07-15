# Planned Pi CLI samples

These detailed design briefs cover the CLI course after [005 — Project
instructions and two simple
skills](../../samples/005-context-and-skills/README.md). Briefs 006–012 guided
the runnable implementations; briefs 013–017 guided the second advanced track.
The sample READMEs are the source of truth for commands and current behavior;
these files preserve scope, implementation decisions, edge cases, verification
matrices, and acceptance criteria.

## Recommended order

1. [006 — Guardrails: intercept and gate tool calls](006-guardrails.md)
2. [007 — Two models: providers and mid-session handoff](007-two-models.md)
3. [008 — Pi as a Unix tool: headless automation](008-headless-automation.md)
4. [009 — Package and share](009-package-and-share.md)
5. [010 — Session lifecycle and branching](010-session-lifecycle.md)
6. [011 — Prompt templates as reusable entry points](011-prompt-templates.md)
7. [012 — Local MCP integration](012-local-mcp.md)

Samples 006–009 are the core continuation: shape the agent, operate it, then
distribute it. Samples 010–012 form the first advanced workflow track.

The second advanced track explores orchestration, long-lived integration, and
interactive extension behavior:

1. [013 — Subagents and delegated work](013-subagents.md)
2. [014 — Session trees, fork, clone, and compaction](014-tree-and-compaction.md)
3. [015 — Pi as a long-lived RPC service](015-rpc-controller.md)
4. [016 — A small custom TUI extension](016-custom-tui.md)
5. [017 — Live steering, follow-ups, and extension messages](017-live-steering.md)

Samples 013–015 are the recommended continuation. Samples 016–017 are optional
advanced UI and interaction lessons. All should remain small, standalone
samples rather than one large showcase application.

## Runnable implementations

- [006](../../samples/006-guardrails/README.md)
- [007](../../samples/007-two-models/README.md)
- [008](../../samples/008-headless-automation/README.md)
- [009](../../samples/009-package-and-share/README.md)
- [010](../../samples/010-session-lifecycle/README.md)
- [011](../../samples/011-prompt-templates/README.md)
- [012](../../samples/012-local-mcp/README.md)
- [013](../../samples/013-subagents/README.md)
- [014](../../samples/014-tree-and-compaction/README.md)
- [015](../../samples/015-rpc-controller/README.md)
- [016](../../samples/016-custom-tui/README.md)
- [017](../../samples/017-live-steering/README.md)

## Why completed design briefs remain here

Do not delete briefs after implementation. Their runnable sample
READMEs are the source of truth for commands and current behavior, while these
briefs preserve the original scope, security decisions, edge cases,
verification matrix, and acceptance criteria. When implementation diverges,
add a short note or update the affected brief; do not clear its contents.

Briefs 013–017 are now implemented. They remain here because the detailed
security decisions, edge cases, verification matrices, and acceptance criteria
are useful companions to the shorter runnable READMEs.
