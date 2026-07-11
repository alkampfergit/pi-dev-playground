# 012 — Local MCP integration through a Pi extension

This sample teaches the smallest honest MCP integration for Pi: one local,
read-only server, one reviewed tool, and one Pi extension that owns the child
process and maps that remote capability into a model-visible Pi tool.

Pi 0.80.6 has no built-in MCP client and does not read an `mcpServers`
configuration property. That omission is intentional. When you want an MCP
boundary, an extension must implement it. Here is the complete path you will
build and inspect:

```text
user → Pi tool mcp_sample_catalog → extensions/mcp-catalog.ts
     → stdio MCP tool sample_catalog_lookup → catalog-server.ts → catalog.json
```

Notice the two tool names. `mcp_sample_catalog` is the stable Pi tool shown to
the model. `sample_catalog_lookup` belongs to another process. The adapter is
where the schema, result, failure behavior, and trust policy cross that
boundary.

## What you will learn

By completing the exercises you will see how to:

- implement `McpServer` with `StdioServerTransport` and a Zod input schema;
- connect with `Client` and `StdioClientTransport` from a Pi extension;
- start a session-scoped child, validate its advertised capability, and close
  it on every shutdown path;
- expose one narrow TypeBox Pi tool instead of forwarding an MCP server's whole
  inventory;
- pass Pi cancellation and a five-second timeout into the MCP request;
- test the MCP contract without a model, then separately prove the model called
  the proxy using Pi's JSON event stream.

Everything after dependency installation runs locally except the deliberately
separate real-model verification. There is no HTTP listener, port, browser,
remote API, or MCP credential.

## Read the pieces in order

Start with [`mcp-server/catalog.json`](mcp-server/catalog.json). It is a fixed,
sorted snapshot of completed samples 001–005. The server reads and validates it
once; it never scans the repository or modifies the file.

Next read [`mcp-server/catalog-server.ts`](mcp-server/catalog-server.ts). It
advertises exactly one tool, `sample_catalog_lookup`. A known three-digit ID
returns stable text plus structured data. An unknown ID returns `isError: true`
and the available IDs, while the server remains usable.

Finally read [`extensions/mcp-catalog.ts`](extensions/mcp-catalog.ts). The
factory registers the command and proxy tool but starts nothing. On
`session_start` it spawns the server through the current Node executable and
the locally installed `tsx` CLI, checks the name, input, and read-only
annotations, and only then becomes ready. On `session_shutdown`, its idempotent
cleanup closes the client, transport, and owned child.

With stdio, the client owns the server. Do not open another terminal, start a
daemon, choose a port, or run `Start-Process`.

## Prepare the sample

PowerShell is the primary course shell:

```powershell
cd samples/012-local-mcp
. ./prepare.ps1
npm ci
```

The equivalent bash preparation is:

```bash
cd samples/012-local-mcp
source ./prepare.sh
npm ci
```

Preparation sets `PI_CODING_AGENT_DIR` to this directory, so Pi auto-discovers
`extensions/mcp-catalog.ts`. `npm ci` uses the committed lockfile and may use
the npm registry when the cache is cold. If Pi reports that it cannot resolve
the MCP SDK or `tsx`, run `npm ci` here before starting Pi.

## Verify without credentials or a model

Run the main acceptance script from this directory or any other directory:

```powershell
pwsh ./samples/012-local-mcp/verify.ps1
```

From inside the sample the shorter form is:

```powershell
./verify.ps1
```

It prints tool versions, performs a clean `npm ci`, and runs three checks:

1. A direct SDK client lists the one MCP tool, checks its schema and
   annotations, looks up `003`, exercises the `999` domain error, and proves a
   second lookup still works.
2. Pi runs offline in RPC mode, loads only this extension, returns the
   `/mcp-catalog` command, and closes the session lifecycle at input EOF.
3. The same RPC test points `PI_MCP_SERVER_ENTRY` at a known missing file and
   proves an unavailable child does not take Pi down.

`PI_MCP_SERVER_ENTRY` is only a diagnostic test seam. Normal use must leave it
unset. The model-free verifier never sources `.env`, sends a prompt, creates a
session, or calls Azure.

You can also run only the direct protocol check:

```powershell
npm run verify:mcp
```

## Prove the model used the proxy

After `. ./prepare.ps1`, run:

```powershell
./verify-model.ps1
```

This separate check requires `AZURE_PI_TEST_ENDPOINT`,
`AZURE_PI_TEST_DEPLOYMENT`, and `AZURE_PI_TEST_API_KEY`. It starts Pi with no
built-in tools and only `mcp_sample_catalog`, requests sample 003, then parses
JSONL events. Passing requires both a successful `tool_execution_start` /
`tool_execution_end` pair for the exact proxy name and final assistant text
containing `Wire Log, auto-discovered` and
`samples/003-wire-log-global`. It always uses `--no-session` and removes its
temporary event stream.

## Interactive lifecycle exercise

Start Pi normally after preparation and installation:

```powershell
pi
```

Then work through this sequence:

1. Run `/mcp-catalog status`; it should report `ready` and the remote tool name.
2. Ask: `Use mcp_sample_catalog to look up sample 004.`
3. Run `/mcp-catalog stop`, then `/mcp-catalog status`; expect `stopped`.
4. Ask Pi to read `mcp-server/catalog.json` with its built-in `read` tool. This
   demonstrates that stopping MCP did not disable unrelated tools.
5. Ask for another MCP lookup. The registered proxy remains visible and gives
   an understandable diagnostic telling you to restart it.
6. Run `/mcp-catalog restart`, confirm `ready`, and repeat the lookup.
7. Quit Pi. The extension closes the child; there is no orphan to manage.

The command is idempotent: repeated `stop` is safe, and concurrent restarts
share one connection attempt.

## Trust boundary

Stdio is a transport, not a sandbox. The server is ordinary executable code
with the same user permissions as Pi. Avoiding a listening port does not remove
its filesystem, process, credential, or network authority. The extension also
runs inside Pi and chooses the executable, arguments, working directory,
environment, allowlist, and result mapping; review all of those choices.

The MCP `readOnlyHint` annotation is metadata, not enforcement. This tool is
actually read-only because its implementation only reads the committed fixture
and exposes no mutation path. A generic proxy for every advertised MCP tool
would silently broaden what the model can do, so this sample checks exactly one
name, schema, and annotation set and exposes exactly one Pi tool.

Tool output may contain prompt injection. The extension tells the model to
treat returned text as data rather than instructions. That rule matters even
for this deterministic fixture and matters much more for remote or mutable
servers.

The SDK's default stdio environment is intentionally narrower than forwarding
the complete host environment; this server needs no secrets. Production MCP
children should receive a minimal environment and appropriate OS isolation.
Pin and inspect dependencies and their lockfile as this sample does. Remember
that `npm ci` itself can execute package lifecycle code and use the network.

Finally, `PI_OFFLINE=1` disables Pi's startup network operations. It does not
sandbox extensions or MCP programs, constrain `npm`, or replace the explicit
Azure provider call made by `verify-model.ps1`.

## Files worth changing during experiments

- Add a sixth fixture record and update the direct verifier to understand why
  deterministic contracts should change together.
- Temporarily change the advertised MCP tool name and observe capability
  validation leave Pi operational but mark the connection unavailable.
- Add a `console.log` to the server, observe that stdout corrupts JSON-RPC, then
  replace it with `console.error`. Server stdout belongs exclusively to MCP
  frames.

Keep experiments narrow. This lesson intentionally omits remote MCP servers,
HTTP transports, OAuth, resources, prompts, multiple servers, and dynamic
pass-through tools.
