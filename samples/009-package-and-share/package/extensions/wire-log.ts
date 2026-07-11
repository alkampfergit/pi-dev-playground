import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/**
 * A packaged version of sample 003's wire logger. Packaging changes how Pi
 * discovers the extension; it does not change the extension's runtime design.
 */
export default function (pi: ExtensionAPI) {
  let enabled = !!process.env.PI_WIRE_LOG;
  const baseDir = process.env.PI_CODING_AGENT_DIR ?? process.cwd();
  const dumpDir = join(baseDir, "dump");
  const counters = new Map<string, number>();

  const write = (kind: "request" | "response", data: unknown, ctx: any) => {
    // Create output only for an enabled provider event, never during discovery.
    mkdirSync(dumpDir, { recursive: true });
    const rawId = ctx?.sessionManager?.getSessionId?.() ?? "no-session";
    const sessionId = String(rawId).replace(/[^A-Za-z0-9._-]/g, "_");
    const sessionDir = join(dumpDir, sessionId);
    mkdirSync(sessionDir, { recursive: true });

    const current = counters.get(sessionId) ?? 0;
    const sequence = kind === "request" ? current + 1 : current;
    if (kind === "request") counters.set(sessionId, sequence);

    const index = String(sequence).padStart(4, "0");
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    const file = join(sessionDir, `${index}-${stamp}-${kind}.json`);
    writeFileSync(file, safeStringify(data), "utf8");
    ctx?.ui?.setStatus?.("wire-log", `dumped ${kind} #${index}`);
  };

  pi.registerCommand("wire-log", {
    description: "Toggle raw provider request/response logging (on|off|status)",
    getArgumentCompletions: (prefix: string) =>
      ["on", "off", "status"]
        .filter((value) => value.startsWith(prefix))
        .map((value) => ({ value, label: value })),
    handler: async (args: string, ctx: any) => {
      const command = args.trim().toLowerCase();
      if (command === "on") enabled = true;
      else if (command === "off") enabled = false;
      else if (command === "") enabled = !enabled;

      ctx?.ui?.notify?.(
        `wire-log ${enabled ? "ON" : "OFF"} → ${dumpDir}`,
        enabled ? "success" : "info",
      );
    },
  });

  pi.on("before_provider_request", (event, ctx) => {
    if (enabled) write("request", event.payload ?? event, ctx);
  });

  pi.on("after_provider_response", (event, ctx) => {
    if (enabled) write("response", event, ctx);
  });
}

function safeStringify(value: unknown): string {
  const seen = new WeakSet<object>();
  return JSON.stringify(
    value,
    (_key, item) => {
      if (item instanceof Headers) return Object.fromEntries(item.entries());
      if (item instanceof Map) return Object.fromEntries(item.entries());
      if (item instanceof Set) return Array.from(item);
      if (typeof item === "object" && item !== null) {
        if (seen.has(item)) return "[Circular]";
        seen.add(item);
      }
      return item;
    },
    2,
  );
}
