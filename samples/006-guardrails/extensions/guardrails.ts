import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import * as path from "node:path";

type ProtectedKind = "environment file" | "dependency directory" | "Git metadata";

/**
 * Resolve a requested tool path lexically before checking complete path
 * components. Windows absolute paths use win32 explicitly so a drive-rooted
 * input is interpreted consistently even while this lesson is inspected on a
 * Unix host. Other paths use the current platform, just as Pi's file tools do.
 *
 * Examples covered by this helper and protectedKind():
 *   output/allowed.txt            -> allowed
 *   .env and ./.env.local         -> environment file
 *   node_modules/demo.txt         -> dependency directory
 *   src/../.git/config            -> Git metadata
 *   .gitignore                    -> allowed
 *   notes/node_modules-guide.md   -> allowed
 */
function normalizedComponents(requestedPath: string, cwd: string): string[] {
  const useWindowsPath = path.win32.isAbsolute(requestedPath);
  const implementation = useWindowsPath ? path.win32 : path;
  const normalized = useWindowsPath
    ? path.win32.normalize(requestedPath)
    : path.resolve(cwd, requestedPath);

  return normalized
    .split(implementation.sep)
    .filter(Boolean)
    .map((component) => component.toLowerCase());
}

function protectedKind(requestedPath: string, cwd: string): ProtectedKind | undefined {
  for (const component of normalizedComponents(requestedPath, cwd)) {
    if (component === ".env" || component.startsWith(".env.")) {
      return "environment file";
    }
    if (component === "node_modules") return "dependency directory";
    if (component === ".git") return "Git metadata";
  }
  return undefined;
}

/**
 * Split enough shell syntax to recognize a command at the beginning of a
 * pipeline/list segment. This is deliberately not a complete shell parser.
 */
function shellTokens(command: string): string[] {
  const tokens: string[] = [];
  let current = "";
  let quote: "'" | '"' | undefined;

  const flush = () => {
    if (current) tokens.push(current);
    current = "";
  };

  for (let index = 0; index < command.length; index += 1) {
    const character = command[index];

    if (quote) {
      if (character === quote) quote = undefined;
      else current += character;
      continue;
    }

    if (character === "'" || character === '"') {
      quote = character;
    } else if (/\s/.test(character)) {
      flush();
      if (character === "\n") tokens.push(";");
    } else if (character === ";" || character === "&" || character === "|") {
      flush();
      while (command[index + 1] === character) index += 1;
      tokens.push(character);
    } else {
      current += character;
    }
  }

  flush();
  return tokens;
}

function isRecursiveForcedRemove(command: string): boolean {
  const tokens = shellTokens(command);
  let segmentStart = true;

  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index];
    if (token === ";" || token === "&" || token === "|") {
      segmentStart = true;
      continue;
    }

    if (!segmentStart || token !== "rm") {
      segmentStart = false;
      continue;
    }

    let recursive = false;
    let forced = false;
    for (index += 1; index < tokens.length; index += 1) {
      const option = tokens[index];
      if (option === ";" || option === "&" || option === "|") {
        segmentStart = true;
        break;
      }
      if (option === "--") continue;
      if (option === "--recursive") recursive = true;
      else if (option === "--force") forced = true;
      else if (/^-[^-]+$/.test(option)) {
        const flags = option.slice(1).toLowerCase();
        recursive ||= flags.includes("r");
        forced ||= flags.includes("f");
      }
    }

    if (recursive && forced) return true;
  }

  return false;
}

export default function guardrails(pi: ExtensionAPI) {
  // This state belongs only to this loaded extension instance. Restarting Pi or
  // using /reload creates a new instance and therefore turns the guard back on.
  let enabled = true;

  pi.registerCommand("guard", {
    description: "Control the sample guardrails (on|off|status)",
    getArgumentCompletions: (prefix: string) => {
      const matches = ["on", "off", "status"]
        .filter((value) => value.startsWith(prefix.toLowerCase()))
        .map((value) => ({ value, label: value }));
      return matches.length > 0 ? matches : null;
    },
    handler: async (args, ctx) => {
      const action = args.trim().toLowerCase();

      if (action === "on") enabled = true;
      else if (action === "off") enabled = false;
      else if (action !== "status") {
        ctx.ui.notify("Usage: /guard on|off|status (state unchanged)", "warning");
        return;
      }

      ctx.ui.notify(`guardrails ${enabled ? "ON" : "OFF"} (this session)`, "info");
    },
  });

  pi.on("tool_call", async (event, ctx) => {
    if (!enabled) return undefined;

    if (isToolCallEventType("write", event) || isToolCallEventType("edit", event)) {
      const requestedPath = event.input.path;
      const kind = protectedKind(requestedPath, ctx.cwd);
      if (!kind) return undefined;

      const reason = `Guardrails blocked ${event.toolName} to protected path "${requestedPath}" (${kind})`;
      if (ctx.hasUI) ctx.ui.notify(reason, "warning");
      return { block: true, reason };
    }

    if (isToolCallEventType("bash", event) && isRecursiveForcedRemove(event.input.command)) {
      const command = event.input.command;
      if (!ctx.hasUI) {
        return {
          block: true,
          reason: `Guardrails denied destructive command because confirmation is unavailable in ${ctx.mode} mode: ${command}`,
        };
      }

      const approved = await ctx.ui.confirm(
        "Review destructive command",
        `Command:\n${command}\n\nAllow this command? Choose No to deny it.`,
      );
      if (!approved) {
        return {
          block: true,
          reason: `Guardrails blocked destructive command because the user denied it: ${command}`,
        };
      }
    }

    return undefined;
  });
}
