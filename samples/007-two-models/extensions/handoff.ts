import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PROVIDER = "azure-openai";
const USAGE = "Usage: /handoff [status|primary|secondary]";

function deployment(name: "AZURE_PI_TEST_DEPLOYMENT" | "AZURE_PI_TEST_DEPLOYMENT2"): string {
  return (process.env[name] ?? "").trim();
}

export default function handoffExtension(pi: ExtensionAPI) {
  pi.registerCommand("handoff", {
    description: "Show or switch between the configured primary and secondary Azure deployments",
    getArgumentCompletions: (prefix: string) => {
      const normalized = prefix.trim().toLowerCase();
      const matches = ["status", "primary", "secondary"]
        .filter((value) => value.startsWith(normalized))
        .map((value) => ({ value, label: value }));
      return matches.length > 0 ? matches : null;
    },
    handler: async (args, ctx) => {
      const command = args.trim().toLowerCase();
      const primaryId = deployment("AZURE_PI_TEST_DEPLOYMENT");
      const secondaryId = deployment("AZURE_PI_TEST_DEPLOYMENT2");
      const current = ctx.model;

      if (command === "status") {
        ctx.ui.notify(
          [
            `current: ${current ? `${current.provider}/${current.id}` : "none"}`,
            `primary: ${primaryId ? `${PROVIDER}/${primaryId}` : "not configured"}`,
            `secondary: ${secondaryId ? `${PROVIDER}/${secondaryId}` : "not configured"}`,
          ].join("\n"),
          "info",
        );
        return;
      }

      if (command !== "" && command !== "primary" && command !== "secondary") {
        ctx.ui.notify(USAGE, "error");
        return;
      }

      let destination: "primary" | "secondary";
      if (command === "primary" || command === "secondary") {
        destination = command;
      } else if (current?.provider === PROVIDER && current.id === primaryId && primaryId) {
        destination = "secondary";
      } else if (current?.provider === PROVIDER && current.id === secondaryId && secondaryId) {
        destination = "primary";
      } else {
        ctx.ui.notify(
          "The current model is not one of the configured deployments. Use /handoff primary or /handoff secondary.",
          "error",
        );
        return;
      }

      const targetId = destination === "primary" ? primaryId : secondaryId;
      if (!targetId) {
        if (destination === "primary") {
          ctx.ui.notify(
            "The primary deployment is not configured. Set AZURE_PI_TEST_DEPLOYMENT in .env, source prepare again, then restart Pi.",
            "error",
          );
        } else {
          ctx.ui.notify(
            "Set AZURE_PI_TEST_DEPLOYMENT2 in .env, source prepare again, then restart Pi.",
            "error",
          );
        }
        return;
      }

      if (primaryId && secondaryId && primaryId === secondaryId) {
        ctx.ui.notify("Two distinct deployment IDs are required for a handoff.", "error");
        return;
      }

      const targetModel = ctx.modelRegistry.find(PROVIDER, targetId);
      if (!targetModel) {
        ctx.ui.notify(
          `Model ${PROVIDER}/${targetId} was not found in models.json. Align the shared registry and .env, then run /reload or restart Pi.`,
          "error",
        );
        return;
      }

      if (current?.provider === PROVIDER && current.id === targetId) {
        ctx.ui.notify(`Already using ${PROVIDER}/${targetId}`, "success");
        return;
      }

      const source = current ? `${current.provider}/${current.id}` : "none";
      const changed = await pi.setModel(targetModel);
      if (!changed) {
        ctx.ui.notify(
          `Authentication is unavailable for ${PROVIDER}/${targetId}. Check AZURE_PI_TEST_API_KEY; the model was not changed.`,
          "error",
        );
        return;
      }

      ctx.ui.notify(`${source} -> ${PROVIDER}/${targetId}`, "success");
    },
  });
}
