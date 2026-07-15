import type {
	AgentToolResult,
	ExtensionAPI,
	ExtensionContext,
	ToolRenderContext,
	ToolRenderResultOptions,
} from "@earendil-works/pi-coding-agent";
import { Key, Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";

const STATUS_KEY = "sample-016-dashboard";
const WIDGET_KEY = "sample-016-dashboard";
const ENTRY_TYPE = "dashboard-checkpoint";
const COMMAND_NAME = "dashboard";
const TOOL_NAME = "dashboard_checkpoint";
const TOOL_LABEL = "Dashboard checkpoint";
const SHORTCUT = "ctrl+shift+d";
const CHECKPOINT_CHOICES = ["manual", "review", "done"];
const MAX_LABEL_LENGTH = 40;

const DashboardCheckpointParameters = Type.Object({
	label: Type.String({ minLength: 1, maxLength: 40 }),
});

type DashboardLifecycle = "idle" | "agent-running" | "turn-running" | "tool-running" | "settling";

interface DashboardState {
	visible: boolean;
	model: string;
	thinkingLevel: string;
	activeToolCount: number;
	lifecycle: DashboardLifecycle;
	latestCompletedTool: string;
	runningToolIds: Set<string>;
	turnIndex?: number;
}

interface CheckpointData {
	label: string;
	model: string;
	thinkingLevel: string;
	activeToolCount: number;
	lifecycle: DashboardLifecycle;
	latestCompletedTool: string;
	createdAt: string;
}

interface CheckpointDetails {
	checkpoint: CheckpointData;
}

const LIFECYCLES: readonly DashboardLifecycle[] = [
	"idle",
	"agent-running",
	"turn-running",
	"tool-running",
	"settling",
];

const CONTROL_CHARACTERS = /[\p{Cc}\p{Cf}\u2028\u2029]/gu;

function removeControlCharacters(value: string): string {
	return value.replace(CONTROL_CHARACTERS, "");
}

function safeText(value: unknown, fallback = "none"): string {
	if (typeof value !== "string") return fallback;
	const cleaned = removeControlCharacters(value);
	return cleaned || fallback;
}

function normalizeLabel(value: unknown): string | undefined {
	if (typeof value !== "string") return undefined;
	const cleaned = value
		.replace(CONTROL_CHARACTERS, (character) => (/\s/u.test(character) ? " " : ""))
		.replace(/\s+/gu, " ")
		.trim();
	if (!cleaned) return undefined;
	return cleaned.slice(0, MAX_LABEL_LENGTH).trim() || undefined;
}

function modelName(model: { provider: string; id: string } | undefined): string {
	return model ? `${safeText(model.provider)}/${safeText(model.id)}` : "none";
}

function newState(ctx: ExtensionContext, pi: ExtensionAPI): DashboardState {
	return {
		visible: true,
		model: modelName(ctx.model),
		thinkingLevel: safeText(pi.getThinkingLevel()),
		activeToolCount: pi.getActiveTools().length,
		lifecycle: "idle",
		latestCompletedTool: "none",
		runningToolIds: new Set<string>(),
	};
}

function isLifecycle(value: unknown): value is DashboardLifecycle {
	return typeof value === "string" && LIFECYCLES.includes(value as DashboardLifecycle);
}

function isValidCheckpoint(value: unknown): value is CheckpointData {
	if (!value || typeof value !== "object") return false;
	const data = value as Partial<CheckpointData>;
	return (
		typeof data.label === "string" &&
		data.label.length > 0 &&
		data.label.length <= MAX_LABEL_LENGTH &&
		data.label === removeControlCharacters(data.label) &&
		typeof data.model === "string" &&
		data.model === removeControlCharacters(data.model) &&
		typeof data.thinkingLevel === "string" &&
		data.thinkingLevel === removeControlCharacters(data.thinkingLevel) &&
		typeof data.activeToolCount === "number" &&
		Number.isInteger(data.activeToolCount) &&
		data.activeToolCount >= 0 &&
		isLifecycle(data.lifecycle) &&
		typeof data.latestCompletedTool === "string" &&
		data.latestCompletedTool === removeControlCharacters(data.latestCompletedTool) &&
		typeof data.createdAt === "string" &&
		data.createdAt === removeControlCharacters(data.createdAt) &&
		!Number.isNaN(Date.parse(data.createdAt))
	);
}

function snapshot(ctx: ExtensionContext, state: DashboardState, pi: ExtensionAPI): CheckpointData {
	state.model = modelName(ctx.model);
	state.thinkingLevel = safeText(pi.getThinkingLevel());
	state.activeToolCount = pi.getActiveTools().length;

	return Object.freeze({
		label: "",
		model: safeText(state.model),
		thinkingLevel: safeText(state.thinkingLevel),
		activeToolCount: state.activeToolCount,
		lifecycle: state.lifecycle,
		latestCompletedTool: safeText(state.latestCompletedTool),
		createdAt: new Date().toISOString(),
	});
}

function snapshotWithLabel(ctx: ExtensionContext, state: DashboardState, pi: ExtensionAPI, label: string): CheckpointData {
	const checkpoint = snapshot(ctx, state, pi);
	return Object.freeze({ ...checkpoint, label });
}

function widgetLines(state: DashboardState): string[] {
	return [
		"Activity dashboard",
		`model: ${safeText(state.model)}`,
		`thinking: ${safeText(state.thinkingLevel)} · tools: ${Math.max(0, state.activeToolCount)}`,
		`state: ${state.lifecycle} · last: ${safeText(state.latestCompletedTool)}`,
	];
}

function oneLineSnapshot(state: DashboardState, toolIsActive: boolean): string {
	const visibility = state.visible ? "visible" : "hidden";
	return `dashboard ${visibility} · model ${safeText(state.model)} · thinking ${safeText(state.thinkingLevel)} · state ${state.lifecycle} · tools ${Math.max(0, state.activeToolCount)} · last ${safeText(state.latestCompletedTool)} · checkpoint-tool: ${toolIsActive ? "active" : "inactive"}`;
}

function renderStatus(state: DashboardState, ctx: ExtensionContext): string {
	const marker = state.lifecycle === "idle" ? ctx.ui.theme.fg("dim", state.lifecycle) : ctx.ui.theme.fg("accent", state.lifecycle);
	return `dashboard · ${marker} · tools ${Math.max(0, state.activeToolCount)}`;
}

function clearDashboard(ctx: ExtensionContext): void {
	if (!ctx.hasUI) return;
	ctx.ui.setStatus(STATUS_KEY, undefined);
	ctx.ui.setWidget(WIDGET_KEY, undefined);
}

function refresh(ctx: ExtensionContext, state: DashboardState): void {
	if (!ctx.hasUI) return;
	if (!state.visible) {
		clearDashboard(ctx);
		return;
	}

	ctx.ui.setStatus(STATUS_KEY, renderStatus(state, ctx));
	if (ctx.mode === "tui") {
		ctx.ui.setWidget(
			WIDGET_KEY,
			(_tui, theme) => new Text(widgetLines(state).map((line, index) => (index === 0 ? theme.fg("accent", line) : theme.fg("dim", line))).join("\n"), 0, 0),
		);
	} else if (ctx.mode === "rpc") {
		ctx.ui.setWidget(WIDGET_KEY, widgetLines(state));
	}
}

function notify(ctx: ExtensionContext, message: string, type: "info" | "warning" | "error"): void {
	const safeMessage = removeControlCharacters(message);
	if (ctx.hasUI) ctx.ui.notify(safeMessage, type);
	else console.error(safeMessage);
}

function appendCheckpoint(
	ctx: ExtensionContext,
	state: DashboardState,
	pi: ExtensionAPI,
	rawLabel: unknown,
): { checkpoint?: CheckpointData; error?: string } {
	const label = normalizeLabel(rawLabel);
	if (!label) return { error: "Checkpoint label must contain at least one non-whitespace character." };

	const checkpoint = snapshotWithLabel(ctx, state, pi, label);
	pi.appendEntry<CheckpointData>(ENTRY_TYPE, checkpoint);
	return { checkpoint };
}

function toggleDashboard(ctx: ExtensionContext, state: DashboardState): void {
	state.visible = !state.visible;
	refresh(ctx, state);
	notify(ctx, `Activity dashboard ${state.visible ? "shown" : "hidden"}.`, "info");
}

function commandUsage(): string {
	return "Usage: /dashboard [status|on|off|toggle|checkpoint [label]]";
}

function getLabelArgument(trimmed: string): string | undefined {
	const match = /^checkpoint(?:\s+([\s\S]*))?$/iu.exec(trimmed);
	return match?.[1];
}

async function chooseCheckpointLabel(ctx: ExtensionContext): Promise<string | undefined> {
	if (!ctx.hasUI) {
		console.error("/dashboard checkpoint: using deterministic manual fallback (no UI in this mode).");
		return "manual";
	}

	const choice = await ctx.ui.select("Checkpoint label", [...CHECKPOINT_CHOICES], { timeout: 5000 });
	return CHECKPOINT_CHOICES.includes(choice ?? "") ? choice : undefined;
}

function checkpointResultMessage(result: { checkpoint?: CheckpointData; error?: string }): string {
	return result.checkpoint
		? `Dashboard checkpoint recorded: ${result.checkpoint.label}`
		: result.error ?? "Dashboard checkpoint failed.";
}

async function handleDashboardCommand(args: string, ctx: ExtensionContext, state: DashboardState, pi: ExtensionAPI): Promise<void> {
	const trimmed = args.trim();
	if (!trimmed || trimmed.toLowerCase() === "status") {
		state.model = state.model || "none";
		state.thinkingLevel = state.thinkingLevel || "none";
		notify(ctx, oneLineSnapshot(state, pi.getActiveTools().includes(TOOL_NAME)), "info");
		return;
	}

	if (trimmed === "on") {
		state.visible = true;
		refresh(ctx, state);
		notify(ctx, "Activity dashboard shown.", "info");
		return;
	}

	if (trimmed === "off") {
		state.visible = false;
		refresh(ctx, state);
		notify(ctx, "Activity dashboard hidden.", "info");
		return;
	}

	if (trimmed === "toggle") {
		toggleDashboard(ctx, state);
		return;
	}

	if (/^checkpoint(?:\s|$)/iu.test(trimmed)) {
		const labelArgument = getLabelArgument(trimmed);
		const label = labelArgument === undefined ? await chooseCheckpointLabel(ctx) : labelArgument;
		if (label === undefined) {
			notify(ctx, "Dashboard checkpoint cancelled; no entry was recorded.", "info");
			return;
		}

		const result = appendCheckpoint(ctx, state, pi, label);
		if (result.error) {
			notify(ctx, result.error, "error");
			return;
		}
		notify(ctx, checkpointResultMessage(result), "info");
		return;
	}

	notify(ctx, commandUsage(), "warning");
}

function textComponent(context: ToolRenderContext<any, any>): Text {
	return context.lastComponent instanceof Text ? context.lastComponent : new Text("", 0, 0);
}

function safeResultText(result: AgentToolResult<CheckpointDetails>): string {
	const content = result.content.find((item) => item.type === "text");
	return content?.type === "text" ? safeText(content.text, "Dashboard checkpoint failed.") : "Dashboard checkpoint failed.";
}

function renderCheckpointMetadata(checkpoint: CheckpointData, theme: any): string {
	return [
		`model: ${safeText(checkpoint.model)}`,
		`thinking: ${safeText(checkpoint.thinkingLevel)}`,
		`active tools: ${checkpoint.activeToolCount}`,
		`lifecycle: ${checkpoint.lifecycle}`,
		`latest completed tool: ${safeText(checkpoint.latestCompletedTool)}`,
		`created: ${safeText(checkpoint.createdAt)}`,
	].map((line) => theme.fg("dim", line)).join("\n");
}

function renderEntry(entry: { data?: unknown }, expanded: boolean, theme: any): Text {
	if (!isValidCheckpoint(entry.data)) {
		return new Text(theme.fg("warning", "[dashboard checkpoint] invalid entry"), 0, 0);
	}

	const heading = `${theme.fg("success", "[dashboard checkpoint]")} ${theme.fg("accent", entry.data.label)}`;
	return new Text(expanded ? `${heading}\n${renderCheckpointMetadata(entry.data, theme)}` : heading, 0, 0);
}

export default function activityDashboard(pi: ExtensionAPI): void {
	let state: DashboardState = {
		visible: true,
		model: "none",
		thinkingLevel: "none",
		activeToolCount: 0,
		lifecycle: "idle",
		latestCompletedTool: "none",
		runningToolIds: new Set<string>(),
	};

	pi.registerEntryRenderer<CheckpointData>(ENTRY_TYPE, (entry, { expanded }, theme) => renderEntry(entry, expanded, theme));

	pi.registerTool({
		name: TOOL_NAME,
		label: TOOL_LABEL,
		description: "Record a safe, display-only activity checkpoint for the current session.",
		parameters: DashboardCheckpointParameters,
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			if (signal?.aborted) {
				return {
					isError: true,
					content: [{ type: "text", text: "Dashboard checkpoint cancelled." }],
				};
			}

			const result = appendCheckpoint(ctx, state, pi, params.label);
			if (result.error) {
				return { isError: true, content: [{ type: "text", text: result.error }] };
			}
			return {
				content: [{ type: "text", text: `Dashboard checkpoint recorded: ${result.checkpoint!.label}` }],
				details: { checkpoint: result.checkpoint! },
			};
		},
		renderCall(args, theme, context) {
			const text = textComponent(context);
			const label = normalizeLabel(args?.label) ?? "…";
			text.setText(`${theme.fg("toolTitle", theme.bold(`${TOOL_LABEL} `))}${theme.fg("accent", label)}`);
			return text;
		},
		renderResult(result, { expanded, isPartial }, theme, context) {
			const text = textComponent(context);
			if (isPartial) {
				text.setText(theme.fg("warning", "recording checkpoint…"));
				return text;
			}

			if (result.isError) {
				text.setText(theme.fg("error", safeResultText(result)));
				return text;
			}

			const checkpoint = (result.details as CheckpointDetails | undefined)?.checkpoint;
			if (!isValidCheckpoint(checkpoint)) {
				text.setText(safeResultText(result));
				return text;
			}

			const heading = `${theme.fg("success", "✓ checkpoint recorded:")} ${theme.fg("accent", checkpoint.label)}`;
			text.setText(expanded ? `${heading}\n${renderCheckpointMetadata(checkpoint, theme)}` : heading);
			return text;
		},
	});

	pi.registerCommand(COMMAND_NAME, {
		description: "Show, hide, inspect, or checkpoint the activity dashboard",
		handler: async (args, ctx) => handleDashboardCommand(args, ctx, state, pi),
	});

	pi.registerShortcut(Key.ctrlShift("d"), {
		description: "Toggle activity dashboard",
		handler: async (ctx) => toggleDashboard(ctx, state),
	});

	pi.on("session_start", async (_event, ctx) => {
		state = newState(ctx, pi);
		refresh(ctx, state);
	});

	pi.on("model_select", async (event, ctx) => {
		state.model = modelName(event.model);
		refresh(ctx, state);
	});

	pi.on("thinking_level_select", async (event, ctx) => {
		state.thinkingLevel = safeText(event.level);
		refresh(ctx, state);
	});

	pi.on("agent_start", async (_event, ctx) => {
		state.lifecycle = "agent-running";
		refresh(ctx, state);
	});

	pi.on("turn_start", async (event, ctx) => {
		state.turnIndex = event.turnIndex;
		state.lifecycle = "turn-running";
		refresh(ctx, state);
	});

	pi.on("tool_execution_start", async (event, ctx) => {
		state.runningToolIds.add(event.toolCallId);
		state.lifecycle = "tool-running";
		refresh(ctx, state);
	});

	pi.on("tool_execution_end", async (event, ctx) => {
		const wasRunning = state.runningToolIds.delete(event.toolCallId);
		if (!wasRunning) return;
		state.latestCompletedTool = `${safeText(event.toolName)}${event.isError ? " (error)" : ""}`;
		state.lifecycle = state.runningToolIds.size > 0 ? "tool-running" : "turn-running";
		refresh(ctx, state);
	});

	pi.on("turn_end", async (_event, ctx) => {
		state.turnIndex = undefined;
		state.lifecycle = "settling";
		refresh(ctx, state);
	});

	pi.on("agent_settled", async (_event, ctx) => {
		state.runningToolIds.clear();
		state.lifecycle = "idle";
		refresh(ctx, state);
	});

	pi.on("session_shutdown", async (_event, ctx) => {
		state.runningToolIds.clear();
		clearDashboard(ctx);
	});
}
