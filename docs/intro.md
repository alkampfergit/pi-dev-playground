Start with the **SDK**, **Extensions**, and **Packages** docs. Those three pages are the best entry point if you want to build your own harness around Pi in the style of OpenClaw, because Pi’s docs say the SDK is for embedding Pi in other applications, while extensions and packages are the mechanism for adding custom behavior and distributing it. [pi](https://pi.dev/docs/latest/extensions)

## Core docs
- [SDK](https://pi.dev/docs/latest/sdk) — programmatic access to Pi’s agent capabilities for embedding in Node.js apps and building custom interfaces. [pi](https://pi.dev/docs/latest/sdk)
- [Extensions](https://pi.dev/docs/latest/extensions) — how TypeScript extensions hook into Pi behavior, tools, lifecycle, and prompt construction. [pi](https://pi.dev/docs/latest/extensions)
- [Pi Packages](https://pi.dev/docs/latest/packages) — how to bundle extensions, skills, prompts, and themes into reusable packages. [pi](https://pi.dev/docs/latest/packages)

## Good next pages
- [Docs home](https://pi.dev/docs/latest) — this is the top-level overview, and it explicitly calls out programmatic usage through SDK, RPC mode, JSON event stream mode, and TUI components. [pi](https://pi.dev/docs/latest)
- [Using Pi](https://pi.dev/docs/latest/usage) — useful to understand the runtime model, loaded context, extensions, and interaction flow before embedding it. [pi](https://pi.dev/docs/latest/usage)
- [Prompt Templates](https://pi.dev/docs/latest/prompt-templates) — helpful if your harness needs reusable task entrypoints or workflow-specific prompts. [pi](https://pi.dev/docs/latest/prompt-templates)

## OpenClaw-specific clue
OpenClaw’s own Pi integration page appears to document a Pi-heavy development workflow, including Pi-focused tests like `pi-embedded-*`, `pi-tools*`, and related agent integration tests. That makes it a useful companion reference for how a real app structures Pi embedding and validation around a production harness. [docs.openclaw](https://docs.openclaw.ai/pi-dev)

## Template and examples
- [pi-extension-template](https://pi.dev/packages/pi-extension-template) — best starting point for building your own extension/package layout. [pi](https://pi.dev/packages/pi-extension-template)
- The template page also points to additional docs such as `docs/typescript.md`, `docs/examples.md`, and a release checklist after creating a repo from the template. [pi](https://pi.dev/packages/pi-extension-template)

## Suggested order
1. Read [SDK](https://pi.dev/docs/latest/sdk) first to understand the embedding model. [pi](https://pi.dev/docs/latest/sdk)
2. Read [Extensions](https://pi.dev/docs/latest/extensions) next to see how to inject custom tools and lifecycle behavior. [pi](https://pi.dev/docs/latest/extensions)
3. Read [Pi Packages](https://pi.dev/docs/latest/packages) so you know how to organize and ship your harness add-ons. [pi](https://pi.dev/docs/latest/packages)
4. Then use [pi-extension-template](https://pi.dev/packages/pi-extension-template) as your scaffold. [pi](https://pi.dev/packages/pi-extension-template)

If you want, I can turn this into a concrete reading path for a TypeScript developer: “build a minimal OpenClaw-style harness in 90 minutes.”