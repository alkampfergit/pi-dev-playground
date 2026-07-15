import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { createHash, randomUUID } from "node:crypto";
import { GuidanceState, validateText, type GuidanceClass } from "../lib/guidance-state.ts";

const GUIDANCE_TYPE = "sample017-guidance";
const NOTE_TYPE = "sample017-note";
const AUDIT_TYPE = "sample017-context-audit";
const TOOL = "guidance_checkpoint";
const state = new GuidanceState();
let pendingNoteAudit: { text: string; id: string; digest: string } | undefined;
let lastInput = { source: "none", streamingBehavior: "none" };

const digest = (text: string) => createHash("sha256").update(text, "utf8").digest("hex");
const opaqueId = (prefix: string) => `${prefix}-${randomUUID()}`;
const safeError = (_error: unknown) => "request rejected";
const hasText = (value: unknown, needle: string): boolean => {
	if (typeof value === "string") return value.includes(needle);
	if (Array.isArray(value)) return value.some((entry) => hasText(entry, needle));
	if (value && typeof value === "object") return Object.values(value).some((entry) => hasText(entry, needle));
	return false;
};

function notify(ctx: ExtensionContext, payload: Record<string, unknown>, kind: "info" | "warning" | "error" = "info"): void {
	ctx.ui.notify(JSON.stringify({ sample: "017", ...payload }), kind);
}

function enqueue(pi: ExtensionAPI, ctx: ExtensionContext, klass: GuidanceClass, raw: string): void {
	if (ctx.isIdle()) throw new Error(`${klass} requires an active run`);
	const checked = validateText(raw);
	const id = opaqueId("guide");
	const sha256 = digest(checked.text);
	state.add({ id, class: klass, bytes: checked.bytes, digest: sha256 });
	pi.sendMessage({
		customType: GUIDANCE_TYPE,
		content: checked.text,
		display: true,
		details: { id, class: klass, bytes: checked.bytes, digest: sha256 },
	}, { deliverAs: klass === "follow-up" ? "followUp" : klass === "next-turn" ? "nextTurn" : "steer" });
	notify(ctx, { action: klass, id, state: "queued", bytes: checked.bytes, digest: sha256.slice(0, 12) });
}

export default function liveGuidance(pi: ExtensionAPI): void {
	pi.registerTool({
		name: TOOL,
		label: "Guidance checkpoint",
		description: "Hold the current turn until the controller releases this opaque checkpoint ID.",
		promptSnippet: "Call guidance_checkpoint before producing prose when the user supplies a checkpoint ID.",
		promptGuidelines: ["When a prompt supplies a checkpoint ID, call guidance_checkpoint with that exact ID before producing prose."],
		parameters: Type.Object({ checkpointId: Type.String({ minLength: 8, maxLength: 80 }) }),
		async execute(_toolCallId, params, signal) {
			let abortHandler: (() => void) | undefined;
			try {
				const outcome = await new Promise<"released" | "cancelled">((resolve, reject) => {
					abortHandler = () => {
						state.cancelCheckpoint();
						resolve("cancelled");
					};
					try {
						state.hold({ id: params.checkpointId, release: () => resolve("released"), cancel: () => resolve("cancelled") });
					} catch (error) { reject(error); return; }
					if (signal.aborted) abortHandler(); else signal.addEventListener("abort", abortHandler, { once: true });
				});
				return { content: [{ type: "text" as const, text: outcome === "released" ? "checkpoint released" : "checkpoint cancelled" }], details: { checkpointId: params.checkpointId, state: outcome }, isError: outcome !== "released" };
			} finally {
				if (abortHandler) signal.removeEventListener("abort", abortHandler);
				if (state.held?.id === params.checkpointId) state.cancelCheckpoint();
			}
		},
	});

	pi.registerCommand("guide", {
		description: "Queue guidance, persist a note, release a checkpoint, or inspect safe status",
		handler: async (raw, ctx) => {
			const match = raw.trim().match(/^(\S+)(?:\s+([\s\S]*))?$/u);
			const action = match?.[1] ?? "";
			const payload = match?.[2] ?? "";
			try {
				switch (action) {
					case "steer": enqueue(pi, ctx, "steer", payload); break;
					case "follow-up": enqueue(pi, ctx, "follow-up", payload); break;
					case "next-turn": enqueue(pi, ctx, "next-turn", payload); break;
					case "ask": {
						if (!ctx.isIdle()) throw new Error("ask requires an idle session");
						const checked = validateText(payload);
						const id = opaqueId("ask");
						pi.sendUserMessage(checked.text);
						notify(ctx, { action, id, state: "accepted", bytes: checked.bytes, digest: digest(checked.text).slice(0, 12) });
						break;
					}
					case "note": {
						const checked = validateText(payload);
						const id = opaqueId("note");
						const sha256 = digest(checked.text);
						pi.appendEntry(NOTE_TYPE, { id, text: checked.text, bytes: checked.bytes, digest: sha256, createdAt: new Date().toISOString() });
						pendingNoteAudit = { text: checked.text, id, digest: sha256 };
						notify(ctx, { action, id, state: "persisted", bytes: checked.bytes, digest: sha256.slice(0, 12) });
						break;
					}
					case "release": {
						const checked = validateText(payload);
						if (!state.releaseCheckpoint(checked.text)) throw new Error("checkpoint is unknown or no longer active");
						notify(ctx, { action, id: checked.text, state: "released" });
						break;
					}
					case "status": {
						if (payload.trim()) throw new Error("status accepts no payload");
						notify(ctx, { action, run: ctx.isIdle() ? "idle" : "active", heldCheckpointId: state.held?.id ?? null, counts: state.counts(), settled: state.settledEvents, guidanceCheckpointActive: pi.getActiveTools().includes(TOOL), lastInput });
						break;
					}
					default: throw new Error("expected steer, follow-up, ask, note, next-turn, release, or status");
				}
			} catch (error) {
				notify(ctx, { action: action || "invalid", state: "rejected", reason: safeError(error) }, "error");
			}
		},
	});

	pi.on("message_start", async (event) => {
		const message = event.message as { role?: string; customType?: string; details?: { id?: string } };
		if (message.role === "custom" && message.customType === GUIDANCE_TYPE && typeof message.details?.id === "string") state.deliver(message.details.id);
	});
	pi.on("input", async (event) => {
		lastInput = { source: event.source, streamingBehavior: event.streamingBehavior ?? "none" };
		return { action: "continue" };
	});
	pi.on("context", async (event) => {
		if (!pendingNoteAudit) return;
		const audit = pendingNoteAudit;
		pendingNoteAudit = undefined;
		pi.appendEntry(AUDIT_TYPE, { id: audit.id, digest: audit.digest, present: hasText(event.messages, audit.text), createdAt: new Date().toISOString() });
	});
	pi.on("agent_settled", async () => { state.settle(); });
	pi.on("session_shutdown", async () => {
		state.cancelAll();
		pendingNoteAudit = undefined;
	});
}
