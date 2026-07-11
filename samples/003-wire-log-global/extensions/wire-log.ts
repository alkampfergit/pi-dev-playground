import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/**
 * wire-log — dump the exact provider requests and responses to disk, with a
 * runtime `/wire-log` command to turn the dumping on and off.
 *
 * This is the sample 002 wire-log adapted to be AUTO-DISCOVERED instead of
 * loaded by hand. Sample 002 loaded the extension ad-hoc with
 * `pi -e ./wire-log.ts`, so it was active for exactly one run and always
 * dumping. Here the file lives in this sample's `extensions/` folder, which is
 * `<config-dir>/extensions/` — pi's auto-discovery location — because
 * `prepare.sh`/`prepare.ps1` point `PI_CODING_AGENT_DIR` at this sample. So pi
 * loads it automatically for every session started here, with no `-e` flag, and
 * hot-reloads it on `/reload`. That changes two requirements:
 *
 *   1. It must default to OFF. An always-loaded logger that always writes would
 *      litter the project with a `dump/` folder and slow every turn.
 *   2. You must be able to flip it mid-session, without restarting pi.
 *
 * Both fall out of one in-memory flag:
 *
 *   - `enabled` is seeded from the `PI_WIRE_LOG` env var (so a startup gate like
 *     `PI_WIRE_LOG=1 pi ...` still works) but is otherwise flippable at runtime.
 *   - The `/wire-log on|off|status` command handler and the two provider hooks
 *     all close over the SAME `enabled` variable, so a toggle takes effect on
 *     the very next request — no `/reload`.
 *
 * While disabled the extension is completely inert: it registers a command and
 * two no-op listeners, but creates no folders and writes nothing. A machine-wide
 * install therefore never touches a project until you type `/wire-log on`.
 *
 * The flag is per-session and ephemeral: it resets to the `PI_WIRE_LOG` default
 * on every `/reload` or restart, which is what you want for a debug switch.
 */
export default function (pi: ExtensionAPI) {
  // Seeded from the env var so a startup gate still works, but flippable at
  // runtime. State lives only for this session.
  let enabled = !!process.env.PI_WIRE_LOG;

  // bin/ and sessions/ are created under PI_CODING_AGENT_DIR, so dump/ lives
  // there too. In this sample prepare.sh sets it to the sample directory; fall
  // back to the current working directory if it is somehow unset.
  const baseDir = process.env.PI_CODING_AGENT_DIR ?? process.cwd();
  const dumpDir = join(baseDir, "dump");

  // One counter per session so request N and its response N share the same
  // number and each session's folder starts at 0001.
  const counters = new Map<string, number>();

  const write = (kind: "request" | "response", data: unknown, ctx: any) => {
    // Created lazily, only once we actually have something to write, so a
    // disabled extension never leaves a dump/ folder behind.
    mkdirSync(dumpDir, { recursive: true });

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

  // /wire-log on | off | status  (bare /wire-log toggles). The handler and the
  // hooks below share the `enabled` closure, so this is instant — no reload.
  pi.registerCommand("wire-log", {
    description: "Toggle raw provider request/response logging (on|off|status)",
    getArgumentCompletions: (prefix: string) =>
      ["on", "off", "status"]
        .filter((v) => v.startsWith(prefix))
        .map((v) => ({ value: v, label: v })),
    handler: async (args: string, ctx: any) => {
      const cmd = args.trim().toLowerCase();
      if (cmd === "on") enabled = true;
      else if (cmd === "off") enabled = false;
      else if (cmd === "") enabled = !enabled; // bare /wire-log toggles
      // "status" (or anything else) just reports the current state below.
      ctx.ui.notify(
        `wire-log ${enabled ? "ON" : "OFF"} → ${dumpDir}`,
        enabled ? "success" : "info",
      );
    },
  });

  pi.on("before_provider_request", (event, ctx) => {
    if (!enabled) return; // Returning undefined leaves the payload unchanged.
    write("request", event.payload ?? event, ctx);
  });

  pi.on("after_provider_response", (event, ctx) => {
    if (!enabled) return;
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
