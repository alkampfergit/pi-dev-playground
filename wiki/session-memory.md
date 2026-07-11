# Session Memory

## 2026-07-11 — Sample 004 (extend and manage tools)

- User preferences: teach two independently selectable, no-key DuckDuckGo
  extensions instead of one blended search implementation: a structured Instant
  Answer lookup and a fuller web-results lookup. Keep them as separate `.ts`
  files so the learner can choose with `pi -e`.
- Verified facts:
  - Pi 0.80.6 starts with `read`, `bash`, `edit`, and `write` enabled. The CLI
    supports `--tools` as an allowlist, `--exclude-tools` as a denylist,
    `--no-tools`, and `--no-builtin-tools`.
  - An extension adds a model-callable tool with `pi.registerTool()`. In a live
    run, both [`duckduckgo-instant-answer.ts`](../samples/004-tools/duckduckgo-instant-answer.ts)
    and [`duckduckgo-web-search.ts`](../samples/004-tools/duckduckgo-web-search.ts)
    loaded individually and were called successfully by the Azure model.
  - `pi.getActiveTools()` and `pi.setActiveTools()` are action methods: calling
    `getActiveTools()` while the extension module is loading fails with
    “Extension runtime not initialized.” Capture an initial list in
    `session_start`, then use it from commands such as `/tools-restore`.
- Decisions and conventions: both variants register unique tool names
  (`duckduckgo_instant_answer` and `duckduckgo_search`) and the same temporary
  `/tools-show`, `/tools-readonly`, and `/tools-restore` commands. Do not load
  both files together: their command names collide, and the sample is designed
  to compare one implementation at a time.
- Pitfalls and fixes: the DuckDuckGo Instant Answer API is structured but does
  not provide normal web-result pages. The HTML alternative returns titles,
  URLs, and snippets without a key, but its markup can change or rate limiting
  can occur. Bing Search APIs were retired on 2025-08-11; they are not a
  current no-key option.
- Course/docs impact: [sample 004 README](../samples/004-tools/README.md),
  [CLI course](../docs/cli-samples.md), and [sample catalog](samples.md) now
  describe the two extensions and session-level tool filtering.
- Next useful step: use sample 004 interactively, run `/tools-readonly`, and
  confirm that a request to write a file cannot call `write` until
  `/tools-restore` is entered.

## 2026-07-11 — Sample 003 (wire-log auto-discovered + runtime toggle)

- User preferences: prefer an **auto-discovered** extension (dropped in the
  sample's own `extensions/` folder, loaded with no `-e` flag) over both the
  ad-hoc `pi -e ./file.ts` of 002 and a machine-wide install. Explicitly removed
  the `plugin.sh`/`plugin.ps1` install scripts in favor of just placing the file.
- Verified facts:
  - `PI_CODING_AGENT_DIR` overrides pi's **entire config directory** (default
    `~/.pi/agent`). Pi auto-discovers extensions at `<config-dir>/extensions/*.ts`.
    So with a sample's `prepare` sourced (which sets `PI_CODING_AGENT_DIR` to the
    sample), the discovery path is `<sample>/extensions/`, **not**
    `~/.pi/agent/extensions/`. Proven with a `session_start` probe placed in both
    locations: only the copy under the active config dir fired. Confirmed loading
    with a print-mode run (no `-e`) that produced `dump/<session>/00NN-*.json`
    request/response pairs across a multi-turn tool loop.
  - Runtime toggle API: `pi.registerCommand(name, { description,
    getArgumentCompletions:(prefix)=>[{value,label}], handler:(args, ctx)=>… })`.
    `args` is the raw string tail after the command; `getArgumentCompletions`
    gives Tab-completion. Built-ins take precedence over extension command names;
    duplicate names get numeric suffixes (`/name:1`).
- Decisions and conventions: the toggle rests on **one in-memory `enabled`
  closure** shared by the command handler and the `before_provider_request` /
  `after_provider_response` hooks, so a flip takes effect on the next request
  with no `/reload`. Flag is seeded from `PI_WIRE_LOG`, per-session, resets on
  `/reload` or restart. Default OFF; hooks early-return and the `dump/` folder is
  created lazily, so an idle auto-loaded extension is fully inert (no folders,
  no writes). `/reload` hot-reloads edits to the file. Report state via
  `ctx.ui.notify(msg, "success"|"info")` — `console.error` fights the TUI.
- Pitfalls and fixes:
  - The bug this session: `plugin.sh install` copied the extension to
    `~/.pi/agent/extensions/`, but sourcing the sample's `prepare` first
    repointed the config dir at the sample, so pi never loaded it. Fix: put the
    extension in `<sample>/extensions/`. A per-sample config dir and a
    machine-wide `~/.pi/agent/extensions/` are **mutually exclusive** — a truly
    global extension needs the default config dir (do not source a `prepare`
    that sets `PI_CODING_AGENT_DIR`).
  - Pi's built-in `read` tool is file-only and errors `EISDIR` on a directory
    path; use `ls`/`find` for directories. Unrelated to wire-log.
- Course/docs impact: reframed `docs/cli-samples.md` §3 and `wiki/samples.md`
  §003 from "machine-wide plugin" to "auto-discovered"; removed the plugin
  scripts. Sample dir is still `samples/003-wire-log-global/`; the extension now
  lives at `samples/003-wire-log-global/extensions/wire-log.ts`.
- Next useful step: sample `004-tools` (registerTool + setActiveTools) is already
  scaffolded and staged.

## 2026-07-11 — CLI sample conventions

- User preferences: use PowerShell (`pwsh`); run sample commands from inside
  the sample directory; keep the first sample purely interactive.
- Verified facts: Azure configuration uses `AZURE_PI_TEST_ENDPOINT`,
  `AZURE_PI_TEST_DEPLOYMENT`, `AZURE_PI_TEST_API_KEY`, and optional
  `AZURE_PI_TEST_DEPLOYMENT2`; Pi discovers custom models through `models.json`.
- Decisions and conventions: shared `.env` loading belongs in
  `samples/Env.psm1`; `001-helloworld/models.json` exposes `cohere-command-a`
  and `Kimi-K2.5`; direct prompts use `pi --model ... -p ...`.
- Pitfalls and fixes: Pi does not discover a temporary or sample-local config
  unless `PI_CODING_AGENT_DIR` points to the sample directory. The sample README
  must explain how to load the environment in the current PowerShell session.
- Session usage: Pi writes local sessions below
  `PI_CODING_AGENT_DIR/sessions`. The 001 statistics tool therefore prefers the
  sample `sessions/` directory and accepts `-SessionsDirectory` for a global or
  different session root. Azure models can report real token usage with zero
  cost when their `models.json` price metadata is zero.
- Course/docs impact: keep `docs/` as a concise learning path that links to real
  samples and notebooks instead of copying their implementation. The CLI course
  lives in `docs/cli-samples.md`.
- Next useful step: keep future sample summaries in `wiki/samples.md` and put
  detailed session learnings here.

## 2026-07-11 — Sample 002 (wire-log extension) + shared config

- User preferences: extensions are loaded ad-hoc for a session with
  `pi --extension ./file.ts` (short `-e`), never installed permanently; add
  `--no-extensions` before `-e` to run only that extension. Keep the sample tiny.
- Decisions and conventions: shared `models.json` and `settings.json` moved to
  the `samples/` root and are symlinked (relative `../`) into each sample folder,
  so every sample shares one model registry. `PI_CODING_AGENT_DIR` still points
  at the sample directory. Also centralized: `samples/prepare.ps1` and
  `samples/prepare.sh` (symlinked into each sample). The workflow is `cd` into a
  sample, then `. ./prepare.ps1` (PowerShell) or `source ./prepare.sh` (bash) —
  both load the nearest `.env` and set `PI_CODING_AGENT_DIR` to the current dir.
  They MUST be sourced, not executed. `prepare.ps1` reuses `Env.psm1`;
  `prepare.sh` is a self-contained bash parser (comments/blank/`export ` prefix/
  quote-stripping; nearest `.env` wins by skipping already-set vars, matching
  Env.psm1). New samples add four symlinks: models/settings/prepare.ps1/prepare.sh.
  AGENTS.md documents all of this.
- Verified facts (from installed pkg + a live run against Azure `cohere-command-a`):
  - `before_provider_request` gives `event.payload` (the literal request body:
    model, messages, tools, temperature, cache markers); `after_provider_response`
    gives `{ type, status, headers }`. Both handlers receive `ctx`.
  - `ctx.sessionManager` is a `ReadonlySessionManager` with `getSessionId()`
    (always present) and `getSessionFile()` (`string | undefined`). Sample 002
    uses `getSessionId()` to name a per-session subfolder under `dump/`.
  - Pi creates `bin/`, `sessions/`, and (via the extension) `dump/` all under
    `PI_CODING_AGENT_DIR`. `dump/` is git-ignored alongside `bin`/`sessions/`.
    Extension `.ts` runs under Node (fs, path, process, Date all available); Pi
    transpiles it at load time, so no local `node_modules`/`tsconfig` is needed
    (editor will show unresolved-import warnings — expected).
- Pitfalls and fixes: UI is absent in print mode (`-p`), so guard
  `ctx.ui?.setStatus?.(...)`. `Headers` don't JSON-serialize directly — use a
  `safeStringify` replacer that flattens `Headers`/`Map`/`Set` and breaks cycles.
  Flatten `:`/`.` out of ISO timestamps in file names for Windows.
