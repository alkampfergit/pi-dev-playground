// This verifier is intentionally independent of Pi. It launches the same MCP
// server directly and checks the protocol contract that the Pi extension relies
// on, giving a fast, deterministic test with no model-provider dependency.
import { strict as assert } from "node:assert";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

// Resolve the locally installed TypeScript runner from ESM, then launch Node
// with that runner and the server entry point just as the extension does.
const require = createRequire(import.meta.url);
const tsxCli = require.resolve("tsx/cli");
const serverEntry = fileURLToPath(new URL("../mcp-server/catalog-server.ts", import.meta.url));
const sampleRoot = fileURLToPath(new URL("..", import.meta.url));
const stderrLines: string[] = [];
// Client metadata is sent during MCP initialization and helps identify this
// process in server-side diagnostics.
const client = new Client({ name: "pi-sample-012-verifier", version: "0.1.0" });
const transport = new StdioClientTransport({ command: process.execPath, args: [tsxCli, serverEntry], cwd: sampleRoot, stderr: "pipe" });
// stdout is reserved for MCP JSON-RPC. Keep a short stderr tail only so a test
// failure can report useful child-process diagnostics without unbounded output.
transport.stderr?.on("data", (chunk) => {
  for (const line of String(chunk).split(/\r?\n/).filter(Boolean)) {
    stderrLines.push(line);
    if (stderrLines.length > 20) stderrLines.shift();
  }
});

// MCP content can contain multiple block types. This verifier examines text
// blocks only, because the small sample server contract returns text responses.
function textOf(result: { content?: unknown }): string {
  return Array.isArray(result.content)
    ? result.content.filter((item): item is { type: "text"; text: string } => !!item && typeof item === "object" && (item as any).type === "text" && typeof (item as any).text === "string").map((item) => item.text).join("\n")
    : "";
}

try {
  // Connecting starts the stdio child and completes the MCP initialization
  // handshake before discovery or calls are attempted.
  await client.connect(transport);
  const listed = await client.listTools({}, { timeout: 5_000 });
  // Lock down the advertised surface: one reviewed tool, one schema, and the
  // four annotations that describe a local read-only catalog lookup.
  assert.equal(listed.tools.length, 1);
  const tool = listed.tools[0];
  assert.equal(tool.name, "sample_catalog_lookup");
  assert.match(tool.description ?? "", /completed Pi learning sample/i);
  assert.deepEqual(tool.inputSchema.required, ["sampleId"]);
  assert.equal((tool.inputSchema.properties as any).sampleId.pattern, "^\\d{3}$");
  assert.deepEqual(tool.annotations, { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false });
  assert.equal(tool.title, "Sample catalog lookup");
  console.log("PASS: advertised one reviewed read-only tool.");

  // A known record must provide both exact human-readable content and the
  // structured fields consumed by the Pi extension.
  const found = await client.callTool({ name: tool.name, arguments: { sampleId: "003" } }, undefined, { timeout: 5_000 });
  assert.notEqual(found.isError, true);
  assert.match(textOf(found), /Wire Log, auto-discovered/);
  assert.match(textOf(found), /samples\/003-wire-log-global/);
  assert.equal((found.structuredContent as any).title, "Wire Log, auto-discovered");
  assert.equal((found.structuredContent as any).path, "samples/003-wire-log-global");
  console.log("PASS: ID 003 returned exact text and structured data.");

  // A missing but well-formed ID is a domain error, not a crashed connection.
  const missing = await client.callTool({ name: tool.name, arguments: { sampleId: "999" } }, undefined, { timeout: 5_000 });
  assert.equal(missing.isError, true);
  assert.match(textOf(missing), /001, 002, 003, 004, 005/);
  console.log("PASS: unknown ID returned a domain error.");

  // Make another valid request after the domain error to prove the child stays
  // connected and usable rather than treating the lookup failure as fatal.
  const second = await client.callTool({ name: tool.name, arguments: { sampleId: "004" } }, undefined, { timeout: 5_000 });
  assert.notEqual(second.isError, true);
  assert.match(textOf(second), /Extend and manage tools/);
  console.log("PASS: server remained usable after the domain error.");
  console.log("PASS: all direct MCP contract checks completed.");
} catch (error) {
  // Add the captured child stderr to the assertion failure; this is especially
  // useful if TypeScript could not start or the server rejected its fixture.
  const tail = stderrLines.join("\n").slice(-2_000);
  throw new Error(`${error instanceof Error ? error.message : String(error)}${tail ? `\nChild stderr:\n${tail}` : ""}`);
} finally {
  // Always close the client so the stdio transport and its child process exit,
  // including when an assertion above fails.
  await client.close().catch(() => undefined);
}
