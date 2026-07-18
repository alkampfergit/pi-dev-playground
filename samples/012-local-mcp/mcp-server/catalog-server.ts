// This is a deliberately small, local MCP server. It reads a committed JSON
// fixture and exposes exactly one read-only lookup tool over stdin/stdout.
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

// The fixture is untyped JSON. This is the narrow TypeScript shape the server
// promises to return after runtime validation succeeds.
type CatalogRecord = { id: string; title: string; lesson: string; path: string };

// Validate static input at the trust boundary. Even a committed fixture can be
// edited incorrectly, and failing on startup is safer than advertising a tool
// whose responses have an unexpected shape.
function validateCatalog(value: unknown): CatalogRecord[] {
  if (!Array.isArray(value) || value.length !== 5) throw new Error("catalog must contain five records");
  const records = value.map((item, index) => {
    if (!item || typeof item !== "object") throw new Error(`catalog record ${index} is not an object`);
    const record = item as Record<string, unknown>;
    // Requiring the exact field set rejects both typos and undocumented fields.
    const keys = Object.keys(record).sort().join(",");
    if (keys !== "id,lesson,path,title") throw new Error(`catalog record ${index} has unexpected fields`);
    for (const key of ["id", "title", "lesson", "path"] as const) {
      if (typeof record[key] !== "string" || record[key].length === 0) throw new Error(`catalog record ${index} has invalid ${key}`);
    }
    // The public tool schema and the stored data use the same three-digit ID.
    if (!/^\d{3}$/.test(record.id as string)) throw new Error(`catalog record ${index} has invalid id`);
    return record as CatalogRecord;
  });
  // Sorting and uniqueness make the fixture deterministic and make available
  // IDs stable in the not-found response below.
  if (records.some((record, index) => index > 0 && records[index - 1].id >= record.id)) {
    throw new Error("catalog IDs must be unique and sorted");
  }
  return records;
}

async function main(): Promise<void> {
  // Derive the fixture location from this module, not the process working
  // directory. The client is therefore free to choose its own `cwd`.
  const fixtureUrl = new URL("./catalog.json", import.meta.url);
  const fixture = JSON.parse(await readFile(fileURLToPath(fixtureUrl), "utf8"));
  const catalog = validateCatalog(fixture);
  // Compute once because this fixed catalog never changes while the server runs.
  const availableIds = catalog.map((record) => record.id).join(", ");

  // The name/version identify this server during MCP initialization.
  const server = new McpServer({ name: "pi-sample-catalog", version: "0.1.0" });
  // `registerTool` makes this capability visible to a connected MCP client.
  // Zod validates incoming arguments and is converted to MCP's JSON Schema.
  server.registerTool(
    "sample_catalog_lookup",
    {
      title: "Sample catalog lookup",
      description: "Look up one completed Pi learning sample by its three-digit ID.",
      inputSchema: {
        sampleId: z.string().regex(/^\d{3}$/, "sampleId must be exactly three decimal digits").describe("Three-digit sample ID, for example 003"),
      },
      annotations: {
        // These are metadata hints for clients. They describe this particular
        // tool; they do not themselves enforce a sandbox or permission system.
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async ({ sampleId }) => {
      // Lookup is entirely in memory: no network, filesystem writes, or model
      // invocation occurs after startup.
      const record = catalog.find((candidate) => candidate.id === sampleId);
      if (!record) {
        // An absent ID is an expected domain error, represented with `isError`
        // so callers can distinguish it from a transport/server failure.
        return {
          isError: true,
          content: [{ type: "text" as const, text: `Sample ${sampleId} was not found. Available IDs: ${availableIds}.` }],
        };
      }
      // Return both a readable text block and structured fields. The extension
      // independently validates structuredContent before exposing it to Pi.
      const text = `Sample ${record.id}: ${record.title}\nLesson: ${record.lesson}\nPath: ${record.path}`;
      return { content: [{ type: "text" as const, text }], structuredContent: { ...record } };
    },
  );

  // Stdio is ideal for this local child-process relationship: stdout carries
  // JSON-RPC, stdin receives it, and no network listener is opened.
  await server.connect(new StdioServerTransport());
}

// Top-level error handling keeps protocol stdout clean: diagnostics go only to
// stderr, which the extension captures as a bounded troubleshooting tail.
main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`catalog MCP server failed: ${message}`);
  process.exitCode = 1;
});
