import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/**
 * wire-log — dump the exact provider requests and responses to disk.
 *
 * Pi has no built-in "show me the raw request" command, but two extension
 * hooks expose everything that actually goes over the wire:
 *
 *   - `before_provider_request` fires AFTER the provider-specific payload is
 *     built and RIGHT BEFORE the HTTP request is sent. `event.payload` is the
 *     literal JSON body (model, messages, tools, temperature, cache markers).
 *     This is the only accurate view of the request: it reflects payload-level
 *     changes that `ctx.getSystemPrompt()` does not.
 *
 *   - `after_provider_response` fires once the HTTP response is received and
 *     BEFORE the stream body is consumed, exposing status code and headers.
 *
 * Instead of just printing to the console, this extension writes one JSON file
 * per event into a `dump/` folder that sits next to Pi's own `bin/` and
 * `sessions/` folders inside PI_CODING_AGENT_DIR. Each distinct Pi session gets
 * its own subfolder inside `dump/`, named after the session id, so traffic from
 * different sessions never gets mixed together.
 */
export default function (pi: ExtensionAPI) {
  // bin/ and sessions/ are created under PI_CODING_AGENT_DIR, so dump/ lives
  // there too. Fall back to the current working directory if it is unset.
  const baseDir = process.env.PI_CODING_AGENT_DIR ?? process.cwd();
  const dumpDir = join(baseDir, "dump");
  mkdirSync(dumpDir, { recursive: true });

  // One counter per session so request N and its response N share the same
  // number and each session's folder starts at 0001.
  const counters = new Map<string, number>();

  const write = (kind: "request" | "response", data: unknown, ctx: any) => {
    // The session id uniquely identifies the current session; it is always
    // present. Sanitize it since it becomes a folder name.
    const rawId = ctx?.sessionManager?.getSessionId?.() ?? "no-session";
    const sessionId = String(rawId).replace(/[^A-Za-z0-9._-]/g, "_");
    const sessionDir = join(dumpDir, sessionId);
    mkdirSync(sessionDir, { recursive: true });

    const current = counters.get(sessionId) ?? 0;
    const seq = kind === "request" ? current + 1 : current;
    if (kind === "request") counters.set(sessionId, seq);

    const index = String(seq).padStart(4, "0");
    // Colons are illegal in file names on Windows, so flatten the timestamp.
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    const file = join(sessionDir, `${index}-${stamp}-${kind}.json`);
    writeFileSync(file, safeStringify(data), "utf8");
    // A one-line breadcrumb in the footer; the full body is on disk. The UI is
    // absent in print mode (-p), so guard the call.
    ctx?.ui?.setStatus?.("wire-log", `dumped ${kind} #${index}`);
  };

  pi.on("before_provider_request", (event, ctx) => {
    write("request", event.payload ?? event, ctx);
    // Returning undefined leaves the payload unchanged.
  });

  pi.on("after_provider_response", (event, ctx) => {
    write("response", event, ctx);
  });
}

/**
 * JSON.stringify that survives circular references and normalizes the values
 * a raw HTTP event can carry (Headers, Map, Set) into plain objects.
 */
function safeStringify(value: unknown): string {
  const seen = new WeakSet<object>();
  return JSON.stringify(
    value,
    (_key, val) => {
      if (val instanceof Headers) return Object.fromEntries(val.entries());
      if (val instanceof Map) return Object.fromEntries(val.entries());
      if (val instanceof Set) return Array.from(val);
      if (typeof val === "object" && val !== null) {
        if (seen.has(val)) return "[Circular]";
        seen.add(val);
      }
      return val;
    },
    2,
  );
}
