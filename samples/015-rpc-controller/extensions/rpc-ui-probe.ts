import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * A model-free command that deliberately exercises the RPC UI sub-protocol.
 * It never reads or writes a file, invokes a process, or calls a model.
 */
export default function rpcUiProbe(pi: ExtensionAPI): void {
  pi.registerCommand("rpc-ui-probe", {
    description: "Exercise the sample RPC client's fail-closed UI policy",
    handler: async (_args, ctx) => {
      ctx.ui.notify("rpc-ui-probe started", "info");
      ctx.ui.setStatus("rpc-ui-probe", "running");
      const confirmed = await ctx.ui.confirm("Sample confirmation", "The sample must deny this.");
      const selected = await ctx.ui.select("Sample selection", ["first", "second"]);
      const input = await ctx.ui.input("Sample input", "placeholder");
      const edited = await ctx.ui.editor("Sample editor", "prefill");
      ctx.ui.notify(
        `rpc-ui-probe result: confirmed=${confirmed === true}; selected=${selected !== undefined}; input=${input !== undefined}; editor=${edited !== undefined}`,
        "info",
      );
      ctx.ui.setStatus("rpc-ui-probe", "complete");
    },
  });
}
