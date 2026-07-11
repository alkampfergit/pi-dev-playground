# 002 — Wire Log (a debugging extension)

In sample 001 you ran Pi and trusted it to talk to Azure for you. In this
sample you get to **watch it talk**: a tiny extension writes the exact JSON
request Pi sends to the provider — and the HTTP response metadata it gets
back — to disk, so you can inspect model, messages, tools, temperature, and
cache markers exactly as they go over the wire.

Pi has no built-in "show me the raw request" command, but it exposes the
serialized payload through two extension hooks. That is all we need — the whole
extension is about 40 lines.

All commands below assume that your current PowerShell directory is:

```text
samples/002-wire-log
```

## How it works

Pi's extension system lets you subscribe to lifecycle events. Two of them see
the raw provider traffic:

| Hook                       | Fires                                                        | What you can read       |
| -------------------------- | ----------------------------------------------------------- | ----------------------- |
| `before_provider_request`  | after the provider-specific payload is built, just before the HTTP request is sent | `event.payload` — the literal request body |
| `after_provider_response`  | once the HTTP response is received, before the stream is consumed                  | status code and headers |

`before_provider_request` is the *only* accurate view of the request: it
reflects payload-level changes that `ctx.getSystemPrompt()` does not, and
later-loaded extensions can still mutate the payload after your handler runs.

The extension lives in [`wire-log.ts`](./wire-log.ts). Rather than just printing
to the console, it writes one JSON file per event into a `dump/` folder that
sits **next to Pi's own `bin/` and `sessions/` folders** inside
`PI_CODING_AGENT_DIR`. Inside `dump/`, **each distinct Pi session gets its own
subfolder** named after the session id, so traffic from separate runs never gets
mixed together:

```text
samples/002-wire-log/
├── bin/            # created by Pi
├── sessions/       # created by Pi
└── dump/           # created by wire-log.ts
    └── 019f506b-bfd1-756b-9d95-cdc7a6098f8c/   # one per session id
        ├── 0001-2026-07-11T09-30-00-000Z-request.json
        ├── 0001-2026-07-11T09-30-02-000Z-response.json
        └── ...
```

The session id comes from `ctx.sessionManager.getSessionId()`. Within a session,
request `N` and its response share the same `NNNN` index, so pairs are easy to
line up, and each session's folder starts fresh at `0001`.

## Prerequisites

Same as sample 001:

- Node.js and npm, PowerShell (`pwsh`), and Pi installed
  (`npm install -g --ignore-scripts @earendil-works/pi-coding-agent`)
- An Azure AI Foundry OpenAI-compatible deployment
- A `.env` file (in this directory or a parent) with the `AZURE_PI_TEST_*`
  variables described in the [root AGENTS.md](../../AGENTS.md)

This sample reuses the shared `models.json` and `settings.json` from the
`samples/` root — both are symlinked into this folder, so the model registry is
identical to sample 001 (`cohere-command-a` and `Kimi-K2.5`).

## 1. Load the environment in the current session

From inside this directory, source the shared preparation script — PowerShell:

```powershell
. ./prepare.ps1
```

or bash:

```bash
source ./prepare.sh
```

It loads the nearest `.env` files and sets `PI_CODING_AGENT_DIR` to this
directory, which does two things: it makes Pi discover the symlinked
`models.json`, and it is where `bin/`, `sessions/`, and our `dump/` folder are
created. The script must be *sourced* (the leading `. ` / `source`) so its
environment changes stay in your shell. `prepare.ps1`, `prepare.sh`,
`models.json`, and `settings.json` are all symlinks to the shared files at the
`samples/` root.

## 2. Run Pi with the extension loaded for this session only

The `--extension` (short: `-e`) flag loads an extension file ad-hoc, without
installing it permanently:

```powershell
pi --extension ./wire-log.ts `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" `
  --tools write,read `
  -p 'Write a two-line haiku about the sea and save it to haiku.md.'
```

While Pi runs, `wire-log.ts` creates `dump/` and fills it with request/response
files. To load *only* this extension and ignore any others you may have
installed globally, add `--no-extensions` before `-e`:

```powershell
pi --no-extensions -e ./wire-log.ts `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" `
  --tools write,read `
  -p 'Write a two-line haiku about the sea and save it to haiku.md.'
```

You can also load it in the interactive UI:

```powershell
pi --extension ./wire-log.ts
```

## 3. Inspect the dump

```powershell
# Each subfolder is one session; list the most recent one:
$latest = Get-ChildItem dump -Directory | Sort-Object LastWriteTime | Select-Object -Last 1
Get-ChildItem $latest.FullName | Sort-Object Name
Get-Content (Get-ChildItem "$($latest.FullName)/*-request.json" | Select-Object -First 1) -Raw
```

The first request file shows the full body Pi sent: the `model`, the `messages`
array (system prompt + your prompt), the `tools` you enabled, and provider
options such as `temperature`. The matching response file shows the HTTP status
and headers the provider returned.

Try enabling more tools or asking a follow-up question, then diff two request
files to see how the `messages` array grows turn over turn — that is Pi's
conversation state, exactly as the provider sees it.

## Notes

- `dump/` is git-ignored (like `bin/` and `sessions/`); the payloads can contain
  your prompts and file contents, so treat them as you would a log.
- Returning `undefined` from `before_provider_request` leaves the payload
  unchanged. The same hook can *modify* the request — e.g.
  `return { ...event.payload, temperature: 0 }` — which is how observability and
  routing extensions work.
- Opening `wire-log.ts` in an editor may show "Cannot find module" and implicit
  `any` warnings. That is expected: this folder has no `node_modules` or
  `tsconfig.json`, and Pi transpiles the extension itself at load time. If you
  want editor type-checking, install the package locally
  (`npm install @earendil-works/pi-coding-agent`) — it is not required to run
  the sample.

## References

- [Pi extensions documentation](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)
- [Pi coding-agent README](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md)
