import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

type CatalogRecord = { id: string; title: string; lesson: string; path: string };

function validateCatalog(value: unknown): CatalogRecord[] {
  if (!Array.isArray(value) || value.length !== 5) throw new Error("catalog must contain five records");
  const records = value.map((item, index) => {
    if (!item || typeof item !== "object") throw new Error(`catalog record ${index} is not an object`);
    const record = item as Record<string, unknown>;
    const keys = Object.keys(record).sort().join(",");
    if (keys !== "id,lesson,path,title") throw new Error(`catalog record ${index} has unexpected fields`);
    for (const key of ["id", "title", "lesson", "path"] as const) {
      if (typeof record[key] !== "string" || record[key].length === 0) throw new Error(`catalog record ${index} has invalid ${key}`);
    }
    if (!/^\d{3}$/.test(record.id as string)) throw new Error(`catalog record ${index} has invalid id`);
    return record as CatalogRecord;
  });
  if (records.some((record, index) => index > 0 && records[index - 1].id >= record.id)) {
    throw new Error("catalog IDs must be unique and sorted");
  }
  return records;
}

async function main(): Promise<void> {
  const fixtureUrl = new URL("./catalog.json", import.meta.url);
  const fixture = JSON.parse(await readFile(fileURLToPath(fixtureUrl), "utf8"));
  const catalog = validateCatalog(fixture);
  const availableIds = catalog.map((record) => record.id).join(", ");

  const server = new McpServer({ name: "pi-sample-catalog", version: "0.1.0" });
  server.registerTool(
    "sample_catalog_lookup",
    {
      title: "Sample catalog lookup",
      description: "Look up one completed Pi learning sample by its three-digit ID.",
      inputSchema: {
        sampleId: z.string().regex(/^\d{3}$/, "sampleId must be exactly three decimal digits").describe("Three-digit sample ID, for example 003"),
      },
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async ({ sampleId }) => {
      const record = catalog.find((candidate) => candidate.id === sampleId);
      if (!record) {
        return {
          isError: true,
          content: [{ type: "text" as const, text: `Sample ${sampleId} was not found. Available IDs: ${availableIds}.` }],
        };
      }
      const text = `Sample ${record.id}: ${record.title}\nLesson: ${record.lesson}\nPath: ${record.path}`;
      return { content: [{ type: "text" as const, text }], structuredContent: { ...record } };
    },
  );

  await server.connect(new StdioServerTransport());
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`catalog MCP server failed: ${message}`);
  process.exitCode = 1;
});
