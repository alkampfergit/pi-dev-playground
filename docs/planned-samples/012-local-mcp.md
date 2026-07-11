# 012 — Local MCP integration through a Pi extension

## Goal

Introduce Model Context Protocol integration with one deterministic local stdio
server and a deliberately small Pi extension that acts as the MCP client.

Pi 0.80.6 intentionally has **no built-in MCP client or MCP configuration
file**. Its installed README says, "No MCP" and recommends building an
extension when MCP is the desired boundary; `docs/usage.md` likewise lists MCP
among the workflows intentionally left to extensions. This sample must teach
that fact directly. It must not imply that adding an `mcpServers` JSON property
will make Pi discover a server.

The completed flow is:

```text
user request
    ↓
Pi model sees mcp_sample_catalog (a Pi extension tool)
    ↓
extensions/mcp-catalog.ts (MCP client and Pi↔MCP adapter)
    ↓ stdio JSON-RPC, child process owned by the extension
mcp-server/catalog-server.ts
    ↓
mcp-server/catalog.json (committed, deterministic, read-only data)
```

This is an advanced sample because it adds a protocol boundary and a child
process, not because it adds a remote service. There is no HTTP listener,
external API, browser, credential, or network request at runtime.

## What the learner should obtain

- A precise distinction between the Pi tool offered to the model and the MCP
  tool implemented by another process.
- A working example of `Client` plus `StdioClientTransport` in a Pi extension,
  and `McpServer` plus `StdioServerTransport` in the child process.
- An understanding that stdio transport means the **client spawns and owns**
  the server; the learner does not start a second terminal or choose a port.
- A safe one-tool mapping from an MCP input schema and result into Pi's
  TypeBox-based tool definition and `AgentToolResult` shape.
- Lifecycle habits: connect on `session_start`, validate capabilities, retain
  one client per session, handle aborts/timeouts, and close idempotently on
  `session_shutdown`.
- Deterministic, model-free tests for the MCP contract and Pi extension startup,
  followed by a separate real-model test that proves a tool call occurred.
- Operational awareness that an MCP server is executable code with the local
  process's permissions; stdio is a transport, not a sandbox.

## Learning sequence

1. Read the committed catalog fixture and the server's single read-only tool.
2. Run a direct SDK verifier that starts the server, lists its capabilities,
   calls the tool with known and unknown IDs, and closes the child.
3. Read the extension adapter and identify the remote MCP name versus the local
   Pi tool name.
4. Run an offline Pi RPC smoke test to prove that Pi loads the adapter and
   completes its session lifecycle without making a model request; the direct
   SDK verifier separately proves the server handshake and capability contract.
5. Run Pi with a real configured model in JSON mode and assert an actual
   `mcp_sample_catalog` execution event.
6. Stop the connection in an interactive session, observe a clear unavailable
   diagnostic, confirm unrelated Pi tools still work, and restart it.

## Exact sample layout

Create this structure under `samples/012-local-mcp/`:

```text
012-local-mcp/
├── README.md
├── package.json
├── package-lock.json
├── verify.ps1
├── verify-model.ps1
├── models.json -> ../models.json
├── settings.json -> ../settings.json
├── prepare.ps1 -> ../prepare.ps1
├── prepare.sh -> ../prepare.sh
├── extensions/
│   └── mcp-catalog.ts
├── mcp-server/
│   ├── catalog-server.ts
│   └── catalog.json
└── verify/
    └── verify-mcp.ts
```

The extension belongs under the sample's `extensions/` directory because
`prepare.ps1` and `prepare.sh` set `PI_CODING_AGENT_DIR` to this sample. Pi then
auto-discovers `<config-dir>/extensions/*.ts`. The real-model verifier should
still load the same file explicitly with `--no-extensions -e` to exclude any
other extension and make the test inventory reproducible.

Commit `package-lock.json`; do not commit `node_modules/`. Resolve all server,
fixture, and verification paths relative to the current source file or
`$PSScriptRoot`, never relative to the caller's current directory.

## Exact dependencies

Use this `package.json` shape:

```json
{
  "name": "pi-sample-012-local-mcp",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "verify:mcp": "tsx ./verify/verify-mcp.ts"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "1.29.0",
    "zod": "4.4.3"
  },
  "devDependencies": {
    "tsx": "4.23.0"
  }
}
```

These are the current versions selected for the implementation design. Pin
exact versions and preserve the generated lockfile so future package releases
do not silently change protocol behavior. The MCP SDK supports Node 18 or
newer. `zod` defines the server's input schema; `tsx` executes the two committed
TypeScript programs without introducing a compile-output directory.

The Pi extension may import `ExtensionAPI` from
`@earendil-works/pi-coding-agent` and `Type` from `typebox` without adding them
to this package: Pi provides those core modules to loaded extensions. The child
server and direct verifier must import only dependencies declared above.

Use the stable SDK v1 import paths:

```ts
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
```

Do not mix the SDK v2 prerelease package/import layout into this sample.

## Deterministic catalog fixture

`mcp-server/catalog.json` is the server's only data source. Keep it small—five
records for completed samples 001 through 005—and give every record exactly
these fields:

```json
{
  "id": "003",
  "title": "Wire Log, auto-discovered",
  "lesson": "Load a config-directory extension automatically and toggle it at runtime.",
  "path": "samples/003-wire-log-global"
}
```

The exact titles and paths must agree with `wiki/samples.md`; concise lesson
text can be written specifically for the fixture. Sort records by three-digit
ID. The server reads and validates this committed file once during startup and
does not scan the repository, call Git, or rewrite the catalog. A fixed fixture
makes failures attributable to the protocol bridge rather than repository
discovery logic.

## Local stdio server design

Implement `mcp-server/catalog-server.ts` with `McpServer` and
`StdioServerTransport`. Register exactly one tool:

| Property | Required value |
| --- | --- |
| MCP tool name | `sample_catalog_lookup` |
| Input | `{ sampleId: string }`, exactly three decimal digits |
| Side effects | None |
| Data source | In-memory validated contents of `catalog.json` |
| Success | Text content plus the matching record as `structuredContent` |
| Missing ID | `isError: true` with a concise message and available IDs |

The registration metadata must include a useful title and description plus
these annotations:

```ts
annotations: {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
}
```

Use a Zod string schema with a `^\d{3}$` constraint and a description. Let the
SDK validate malformed shapes; handle a well-formed but unknown ID in the tool
handler. On success, return a stable text rendering that mentions ID, title,
lesson, and path, along with structured data suitable for the extension's
`details` field.

Resolve `catalog.json` from `import.meta.url`, not `process.cwd()`. Connect once:

```ts
const transport = new StdioServerTransport();
await server.connect(transport);
```

Standard output is reserved exclusively for MCP JSON-RPC frames. All optional
diagnostics and top-level errors must use stderr (`console.error`). Never print
a greeting, readiness line, catalog contents, or debug log with `console.log`,
because one ordinary stdout line corrupts the protocol stream.

The server should terminate naturally when its stdin closes. Add concise
top-level error handling that writes to stderr and sets a nonzero exit code; do
not add an HTTP fallback, daemon mode, PID file, or signal-management framework.

## Pi extension and MCP client design

Implement `extensions/mcp-catalog.ts` as the only bridge. It owns these names:

- remote MCP tool: `sample_catalog_lookup`;
- model-visible Pi tool: `mcp_sample_catalog`;
- extension command: `/mcp-catalog status|stop|restart`.

The names are intentionally different. This lets the README point to the
mapping layer where protocol schemas, results, failures, and security policy
are translated.

### Starting the server portably

Resolve the `tsx` CLI with Node's module resolver rather than constructing a
platform-specific `node_modules/.bin/tsx` path. For example, use
`createRequire(import.meta.url).resolve("tsx/cli")`. Start the transport with:

- `command: process.execPath` (the current Node executable);
- `args: [resolvedTsxCli, resolvedCatalogServer]`;
- `cwd`: the sample root;
- `stderr: "pipe"`.

An optional `PI_MCP_SERVER_ENTRY` environment variable may override only the
server entry path. Its sole purpose is the deterministic broken-server smoke
test. Document it as a diagnostic/test seam, not normal configuration.

Attach the stderr listener before `client.connect(transport)`, retain only a
small bounded ring buffer of recent lines, and show those lines through the
status command when connection fails. Do not inherit child stderr into Pi's
interactive terminal and do not write a log file by default.

### Session lifecycle

Keep session-scoped state in the extension closure:

- `client` and `transport` references;
- a single in-flight connection promise to prevent duplicate children;
- status: `starting`, `ready`, `unavailable`, or `stopped`;
- the last safe error string and bounded stderr tail;
- whether the user intentionally stopped automatic connection.

Register the Pi tool and command in the extension factory, but do not spawn the
child there. Pi's extension documentation explicitly says long-lived resources
must start in `session_start` or on demand and be closed by an idempotent
`session_shutdown` handler.

On `session_start`:

1. create a `Client` with a stable name/version;
2. create and connect `StdioClientTransport`;
3. call `listTools` with a five-second timeout;
4. require exactly one advertised tool named `sample_catalog_lookup`;
5. validate that its input schema requires `sampleId` and that its annotations
   declare the expected read-only behavior;
6. transition to `ready` only after every check passes.

Catch startup/handshake/capability errors. Store a concise diagnostic and leave
Pi running with status `unavailable`; do not throw out of `session_start`,
remove built-in tools, or terminate the Pi process. Always close partially
created client/transport state on failure.

On `session_shutdown`, close the `Client` once and clear every reference. SDK
`client.close()` closes its transport and spawned child. The cleanup must be
safe after a failed connection, an explicit stop, a reload, a fork, or a normal
quit.

`/mcp-catalog` behavior:

- `status` (and no argument): report state, remote tool name, and the most recent
  safe error; never expose environment variables or full process arguments.
- `stop`: close the client/child, mark the connection intentionally stopped,
  and leave the Pi proxy tool registered so its unavailable result is visible.
- `restart`: clear the intentional-stop flag and perform one fresh connection
  and capability check.

Guard UI notification calls for non-interactive modes.

### Mapping the MCP tool to a Pi tool

Register `mcp_sample_catalog` with a TypeBox parameter containing the same
`sampleId` constraint. Its description and prompt guidance must say it is a
read-only lookup over the committed learning catalog. The guidance must also
tell the model to treat returned text as data, not instructions.

Execution must:

1. Respect the Pi `AbortSignal` and pass it to the SDK request options.
2. Require a ready client; if stopped or unavailable, return/throw a concise
   diagnostic that tells the learner to use `/mcp-catalog restart`.
3. Call `client.callTool` with remote name `sample_catalog_lookup`, the validated
   arguments, a five-second timeout, and the Pi abort signal.
4. If MCP returns `isError`, surface its safe text as a failed Pi tool call.
5. Accept only MCP text content for this sample. Join text blocks for Pi's
   `content` and put protocol name, remote tool name, and validated
   `structuredContent` in `details`.
6. On transport failure, close the broken client, transition to `unavailable`,
   and preserve unrelated Pi tools. Do not retry invisibly; `/restart` makes a
   new child explicit.

Do not expose a generic `call any MCP tool` Pi tool. A narrow, reviewed mapping
keeps the model-visible schema stable and makes the trust decision inspectable.

## Model-free direct MCP verifier

Implement `verify/verify-mcp.ts` as a small independent SDK client. It uses the
same portable `process.execPath + tsx/cli` spawn pattern as the extension and
performs these assertions:

1. Connect to the server with stderr piped and a five-second timeout policy.
2. `listTools` returns exactly one tool named `sample_catalog_lookup`.
3. Its description, required `sampleId` schema, and all four behavior annotations
   are present.
4. Calling it with `sampleId: "003"` succeeds and returns the exact fixture
   title/path in both text and structured content.
5. Calling it with `sampleId: "999"` returns `isError: true` and mentions the
   available IDs without crashing the server.
6. A second valid lookup still succeeds after that domain error.
7. `client.close()` runs in `finally`, including after any failed assertion.

Print only short `PASS` lines and one final summary from the verifier process.
Those lines are the verifier's stdout, not the child server's stdout; the SDK
transport consumes the child's protocol stream. Include the captured child
stderr in a thrown verification error, but cap its length.

This test uses no Pi model, API key, Azure endpoint, or runtime network access.

## PowerShell-first deterministic verification

Implement `verify.ps1` as the main acceptance script. It must work from any
current directory and use `$PSScriptRoot` for every path.

1. Enable strict mode and stop on errors.
2. Require `node`, `npm`, `pwsh`, and `pi`; print their versions.
3. Run `npm ci` in the sample directory. This installation step may access the
   npm registry when the cache is cold; all subsequent protocol tests are local.
4. Run `npm run verify:mcp`, capture its exit code immediately, and require all
   direct contract checks to pass.
5. Save and later restore `PI_CODING_AGENT_DIR`, `PI_OFFLINE`, and
   `PI_MCP_SERVER_ENTRY` exactly, including whether each variable was absent.
6. Set `PI_CODING_AGENT_DIR` to the sample, set `PI_OFFLINE=1`, and clear the
   server override.
7. Start Pi explicitly with `--no-extensions -e
   ./extensions/mcp-catalog.ts --mode rpc --no-session --offline` and pipe one
   `get_commands` request. Run it from the sample directory.
8. Assert exit code zero and an RPC command entry named `mcp-catalog` from the
   expected extension path. This proves that Pi loaded the adapter and completed
   its session lifecycle without a provider call. The direct SDK verifier is
   the authoritative model-free proof of the server handshake and capability
   contract; the real-model verifier below proves the complete Pi proxy path.
9. Repeat the RPC smoke with `PI_MCP_SERVER_ENTRY` set to a known nonexistent
   `.ts` file. Assert Pi still starts, returns the `mcp-catalog` command, exits
   cleanly on EOF, and emits no provider events. This proves MCP unavailability
   does not take down Pi.
10. Restore the environment and location in `finally`.

RPC input must be LF-terminated JSONL:

```json
{"id":"commands","type":"get_commands"}
```

Parse stdout as JSON lines and select the correlated response. Capture stderr
separately so server diagnostics cannot corrupt RPC parsing. Use process helpers
that retain the exit code from the command they execute.

The deterministic verifier must not source `.env`, send a prompt, create a Pi
session, or require the Azure variables. It may assert that no unexpected log,
session, or catalog mutation occurred. It should not attempt broad process
killing; closing the client and reaching RPC EOF are the lifecycle under test.

## Real-model verification

Implement `verify-model.ps1` separately so the deterministic test remains
credential-free. It must:

1. Require `AZURE_PI_TEST_ENDPOINT`, `AZURE_PI_TEST_DEPLOYMENT`, and
   `AZURE_PI_TEST_API_KEY` with clear missing-variable messages.
2. Source the shared preparation flow or otherwise preserve the exact
   `AZURE_PI_TEST_*` model configuration specified by the repository.
3. Run Pi from the sample directory with only the explicit extension and its
   proxy tool enabled:

```powershell
pi --no-extensions -e ./extensions/mcp-catalog.ts `
  --no-builtin-tools --tools mcp_sample_catalog `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" `
  --mode json --no-session `
  -p 'You must call mcp_sample_catalog for sample 003. Return its title and path.'
```

4. Parse JSONL rather than trusting prose output alone.
5. Require at least one `tool_execution_start` and successful
   `tool_execution_end` whose `toolName` is `mcp_sample_catalog`.
6. Require the final assistant text to contain the fixture's exact title and
   path.
7. Fail with the captured event stream location or a concise diagnostic if the
   model did not call the tool, the tool result was an error, or the final answer
   ignored the result.

Always use `--no-session`. Store any temporary JSONL below a uniquely allocated
system temp directory and remove it in `finally`; do not write verification
output into the source sample.

## Optional interactive lifecycle exercise

After both verifiers pass, the README should teach this interactive sequence:

1. `. ./prepare.ps1`, `npm ci`, then start Pi normally in the sample.
2. Run `/mcp-catalog status`; expect `ready`.
3. Ask Pi to look up sample 004 with `mcp_sample_catalog`.
4. Run `/mcp-catalog stop`, then `/mcp-catalog status`; expect `stopped`.
5. Ask Pi to read `catalog.json` with the built-in `read` tool to demonstrate
   that an unavailable MCP child did not disable unrelated tools.
6. Ask for the MCP lookup while stopped and inspect the understandable tool
   error.
7. Run `/mcp-catalog restart`, verify `ready`, and repeat the lookup.
8. Quit Pi; the extension closes the child automatically.

Make clear that with stdio the extension starts and stops the server. There is
no separate `Start-Process`, port readiness loop, or orphan server for the
learner to manage.

## Failure handling requirements

| Failure | Required behavior |
| --- | --- |
| Missing `node_modules` | README and verifier say to run `npm ci`; no opaque module-not-found lesson |
| Invalid fixture JSON/schema | Server writes concise stderr error and exits nonzero |
| Child executable/entry missing | Extension becomes `unavailable`; Pi continues |
| MCP handshake timeout | Close partial client/transport; retain bounded diagnostic |
| Expected MCP tool absent or annotations wrong | Reject connection as incompatible; do not proxy an unreviewed capability |
| Unknown sample ID | MCP result has `isError: true`; server stays alive |
| Pi request aborted | Pass abort signal through `callTool`; do not turn it into a retry |
| MCP call timeout or child exit | Mark unavailable and close broken connection |
| `/mcp-catalog stop` repeated | Idempotent success; no stale client reference |
| `/mcp-catalog restart` repeated/concurrent | One in-flight connection promise; at most one child |
| Pi reload/new/fork/quit | `session_shutdown` closes old child before new session state starts |
| Child diagnostics | stderr only, bounded and sanitized before display |

Never include environment values, credentials, the complete inherited
environment, or arbitrary child output in a model-visible tool error.

## Security boundary

The README and source comments must explain:

- The MCP server is a normal local child process with the same user permissions
  as Pi. Stdio avoids a listening network port but grants no filesystem,
  process, credential, or network isolation.
- The Pi extension is also executable code with full Pi-process permissions.
  It chooses the executable, arguments, working directory, environment, tool
  allowlist, and result mapping; every part needs review.
- MCP annotations such as `readOnlyHint` are capability metadata and scheduling
  hints, not enforcement. The server implementation is what makes this tool
  read-only.
- A generic pass-through of every server-advertised tool would expand the
  model's authority silently. This sample requires one name/schema/annotation
  match and exposes one explicit Pi proxy.
- Tool output can contain prompt injection. Even though this fixture is
  committed and deterministic, the model guidance treats MCP text as data, not
  instructions. Apply stronger skepticism to remote or mutable servers.
- Do not forward the entire host environment to an untrusted child by default.
  This sample needs no credentials. Production integrations should construct a
  minimal environment and use OS-level isolation when appropriate.
- Pin and inspect npm dependencies and the lockfile. `npm ci` can run package
  lifecycle behavior and network activity; execute untrusted dependency
  installation in an appropriate container or VM.
- `PI_OFFLINE=1` disables Pi startup network operations. It does not constrain
  extension code, MCP server code, npm, or the model provider call in the
  separate real-model test.

## Verification matrix

| Layer | Check | Evidence | Network/model |
| --- | --- | --- | --- |
| Dependencies | `npm ci` from committed lock | Exit 0, exact locked tree | npm may use network/cache; no model |
| Server discovery | Direct client `listTools` | One expected name/schema/annotations | Local only; no model |
| Server success | Call ID `003` | Exact text and structured fixture record | Local only; no model |
| Server domain error | Call ID `999` | `isError: true`, process remains usable | Local only; no model |
| Server lifecycle | Direct client `finally` close | Verifier exits without orphan/manual kill | Local only; no model |
| Pi adapter startup | RPC `get_commands` | Exit 0; `/mcp-catalog` from expected file | Pi offline; no model |
| Pi degraded startup | Missing server entry RPC run | Pi still exits 0 and command remains available | Pi offline; no model |
| Pi proxy execution | JSON-mode Azure run | Successful `mcp_sample_catalog` tool events | Local MCP plus real model |
| Answer grounding | Same JSON-mode run | Exact fixture title/path in final answer | Local MCP plus real model |
| Interactive stop | `/mcp-catalog stop` then lookup | Clear unavailable diagnostic | No server call succeeds |
| Isolation of failure | Built-in `read` after stop | Read still succeeds | MCP unavailable |
| Restart | `/mcp-catalog restart` | Status ready; lookup works again | Local child only |
| Shutdown | Quit/reload/new/fork | Owned client closes idempotently | No broad process cleanup |

## Acceptance criteria

The sample is complete only when all of the following are proven:

- The exact file tree and four required symlinks exist, and the README uses a
  teacher-to-student tone.
- `package.json` pins MCP SDK 1.29.0, Zod 4.4.3, and tsx 4.23.0; the committed
  lockfile agrees and `npm ci` succeeds on the supported Node version.
- The fixture has five valid, sorted, deterministic records matching the real
  completed sample titles and paths.
- The stdio server advertises only `sample_catalog_lookup`, with the exact
  input schema and read-only annotations, and never writes diagnostics to
  stdout.
- The direct verifier proves list, successful lookup, domain error, continued
  use after error, and cleanup without credentials or a model.
- The extension starts no process in its factory, performs one connection and
  capability validation per session, maps only the reviewed tool, passes abort
  and timeout controls, and closes idempotently on every shutdown path.
- MCP startup failure leaves Pi operational and exposes a concise status/error
  instead of crashing or disabling unrelated tools.
- `verify.ps1` passes its direct protocol, healthy Pi RPC, and broken-server Pi
  RPC checks from any current directory, and restores all changed environment
  variables in `finally`.
- `verify-model.ps1` proves through JSON events—not inference from final
  prose—that the configured model invoked `mcp_sample_catalog` successfully and
  grounded its answer in the exact fixture record.
- The optional interactive stop/status/restart exercise has been run and the
  built-in `read` tool still works while MCP is stopped.
- No server process, session, temporary JSONL, PID file, log, catalog mutation,
  or credential remains after verification.
- The implementation handoff records Pi 0.80.6, Node/npm versions, direct
  verifier output, offline RPC results, and real-model verification result.

## Boundaries

Do not add HTTP/SSE/Streamable HTTP transport, OAuth, remote MCP servers,
resources, prompts, sampling, elicitation, notifications, multiple servers,
dynamic pass-through tools, subagents, custom TUI components, containers, or a
general MCP configuration system. Do not publish the sample as a Pi package.

The durable lesson is the smallest honest MCP integration: Pi does not provide
one built in, an extension can own a reviewed stdio client, the child provides
one deterministic read-only capability, and each boundary is tested
independently.

## Implementation references

- Pi 0.80.6 installed `README.md` (Philosophy: **No MCP**).
- Pi 0.80.6 installed `docs/usage.md` (MCP intentionally omitted; extensions
  are the customization mechanism).
- Pi 0.80.6 installed `docs/extensions.md` (dynamic tool registration,
  long-lived resource startup, and `session_shutdown`).
- [MCP TypeScript SDK v1 documentation](https://github.com/modelcontextprotocol/typescript-sdk/tree/v1.x/docs)
- [MCP TypeScript SDK repository](https://github.com/modelcontextprotocol/typescript-sdk)
- [Sample 004 — Pi custom tools](../../samples/004-tools/README.md)
