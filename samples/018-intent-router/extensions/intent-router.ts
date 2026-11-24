import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { ModelThinkingLevel } from "@earendil-works/pi-ai";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { LocalClassifierProcess } from "../lib/classifier-client.ts";
import { routeRequest, type RouterConfig, type RouteRequest, type RouteResult, type RouterState } from "../lib/router.ts";

const PROVIDER = "intent";
const VIRTUAL_ID = "auto";
interface Config extends RouterConfig {
	classifier: RouterConfig["classifier"] & { engine: "gliner2" | "jeff"; modelPath?: string; labels?: { code: string; general: string } };
	jeff: { adapter: string; functionId: string; context?: Record<string, unknown>; labels?: Record<string, string> };
}
interface RawConfig extends Omit<Config, "models"> {
	models: Record<"coding" | "general", { provider: string; model: string }>;
}

function loadConfig(sampleDir: string): Config {
	const path = resolve(sampleDir, "intent-router.json");
	const config = JSON.parse(readFileSync(path, "utf8")) as RawConfig;
	if (!config.models?.coding?.provider || !config.models.coding.model || !config.models?.general?.provider || !config.models.general.model) throw new Error("intent-router.json must configure coding and general models.");
	if (!Number.isFinite(config.classifier?.timeoutMs) || config.classifier.timeoutMs < 1 || !Number.isFinite(config.classifier?.confidenceThreshold) || config.classifier.confidenceThreshold < 0 || config.classifier.confidenceThreshold > 1) throw new Error("Invalid classifier timeout or confidence threshold.");
	if (!(config.routing?.fallback === "coding" || config.routing?.fallback === "general")) throw new Error("routing.fallback must be coding or general.");
	if (config.classifier.engine !== "gliner2" && config.classifier.engine !== "jeff") throw new Error("classifier.engine must be gliner2 or jeff.");
	if (config.classifier.engine === "gliner2" && (!config.classifier.modelPath || !config.classifier.labels?.code || !config.classifier.labels?.general)) throw new Error("GLiNER2 requires a local modelPath and code/general labels.");
	if (config.classifier.engine === "jeff" && (!config.jeff?.adapter || !config.jeff?.functionId)) throw new Error("Configure a local Jeff adapter and functionId.");
	return { ...config, models: {
		coding: { provider: config.models.coding.provider, id: config.models.coding.model },
		general: { provider: config.models.general.provider, id: config.models.general.model },
	} };
}

export default function intentRouter(pi: ExtensionAPI): void {
	const sampleDir = process.env.PI_CODING_AGENT_DIR ?? process.cwd();
	const config = loadConfig(sampleDir);
	const classifier = new LocalClassifierProcess(sampleDir, { ...config.classifier, jeff: config.jeff });
	let latest: RouterState | undefined;
	let totals = { requests: 0, fallbacks: 0, latencyMs: 0 };

	pi.registerVirtualModel<RouterState>({
		provider: PROVIDER, id: VIRTUAL_ID, name: "Intent Auto", thinkingLevels: ["off", "low", "medium", "high"],
		route: async (request, ctx) => {
			const adapted: RouteRequest = { ...request, messages: request.messages };
			const resolveModel = (reference: { provider: string; id: string }) => {
				const available = ctx.modelRegistry.getAvailable().find((candidate) => candidate.provider === reference.provider && candidate.id === reference.id && candidate.api !== "pi-virtual");
				return available ? { provider: available.provider, id: available.id } : undefined;
			};
			const result: RouteResult = await routeRequest(adapted, config, classifier, resolveModel);
			latest = result.state ?? latest;
			if (request.reason === "user") {
				totals.requests++;
				totals.latencyMs += result.decision.latencyMs;
				if (result.decision.fallback) totals.fallbacks++;
					const scoreLabel = config.classifier.engine === "gliner2" ? "Score" : "Confidence";
					if (config.observability.enabled && ctx.hasUI) ctx.ui.notify(`[Intent Router]\nIntent: ${result.decision.intent.toUpperCase()}${result.decision.confidence === undefined ? "" : `\n${scoreLabel}: ${Math.round(result.decision.confidence * 100)}%`}\nSelected: ${result.model.provider}/${result.model.id}\nDecision time: ${result.decision.latencyMs.toFixed(1)} ms\nReason: ${result.decision.reason}`, "info");
			}
			const model = ctx.modelRegistry.find(result.model.provider, result.model.id);
			if (!model || model.api === "pi-virtual" || !ctx.modelRegistry.getAvailable().some((candidate) => candidate.provider === result.model.provider && candidate.id === result.model.id && candidate.api !== "pi-virtual")) throw new Error(`Configured physical model is unavailable: ${result.model.provider}/${result.model.id}`);
			return { model, thinkingLevel: result.thinkingLevel as ModelThinkingLevel, state: result.state };
		},
	});

	pi.registerCommand("router", {
		description: "Show intent router status, stats, or sanitized configuration",
		handler: async (args, ctx) => {
			const action = args.trim() || "status";
			if (action === "status") {
				ctx.ui.notify(JSON.stringify({ action, latest: latest ? { intent: latest.intent, model: latest.model, confidence: latest.confidence, latencyMs: latest.latencyMs, reason: latest.reason } : null }), "info");
			} else if (action === "stats") {
				ctx.ui.notify(JSON.stringify({ action, ...totals, meanLatencyMs: totals.requests ? totals.latencyMs / totals.requests : 0 }), "info");
			} else if (action === "config") {
					ctx.ui.notify(JSON.stringify({ action, models: config.models, classifier: config.classifier, routing: config.routing, observability: { enabled: config.observability.enabled, logPromptContents: false }, jeff: config.classifier.engine === "jeff" ? { adapter: config.jeff.adapter, functionId: config.jeff.functionId } : undefined }), "info");
			} else ctx.ui.notify("Use /router status, /router stats, or /router config.", "warning");
		},
	});
	pi.on("session_shutdown", () => classifier.close());
}
