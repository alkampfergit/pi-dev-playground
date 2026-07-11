# Session Memory

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
