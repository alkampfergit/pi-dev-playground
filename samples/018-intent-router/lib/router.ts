import { buildClassificationInput } from "./context.ts";

export type Intent = "code" | "general";
export type Fallback = "coding" | "general";
export interface ClassificationResult { intent: Intent; confidence: number; latencyMs: number; }
export interface Classifier { classify(input: ReturnType<typeof buildClassificationInput>, options?: { signal?: AbortSignal }): Promise<ClassificationResult>; }
export interface ModelRef { provider: string; id: string; }
export interface RouterConfig {
	models: Record<"coding" | "general", ModelRef>;
	classifier: { confidenceThreshold: number; timeoutMs: number };
	routing: { fallback: Fallback; stickyContinuations: boolean; includeConversationContext: boolean; failoverOnProviderError?: boolean };
	observability: { enabled: boolean; logPromptContents: false };
}
export interface RouteRequest {
	reason: "user" | "continuation" | "retry" | "direct";
	thinkingLevel: string;
	previous?: { model: ModelRef; thinkingLevel?: string };
	failed?: { model: ModelRef; thinkingLevel?: string; message?: { errorMessage?: string } };
	state?: RouterState;
	messages: readonly { role?: string; content?: unknown }[];
	signal?: AbortSignal;
}
export interface RouterState { intent?: Intent; model?: string; confidence?: number; latencyMs?: number; reason?: string; }
export interface RouteResult { model: ModelRef; thinkingLevel: string; state?: RouterState; decision: { intent: Intent; confidence?: number; latencyMs: number; reason: string; fallback: boolean }; }
export type ModelResolver = (model: ModelRef) => ModelRef | undefined;

export async function routeRequest(
	request: RouteRequest,
	config: RouterConfig,
	classifier: Classifier,
	resolve: ModelResolver,
): Promise<RouteResult> {
	const sticky = request.reason === "retry" ? request.failed ?? request.previous : request.previous;
	if (request.reason === "direct") {
		const target = sticky?.model ?? config.models[config.routing.fallback];
		return { model: requireModel(target, resolve), thinkingLevel: sticky?.thinkingLevel ?? request.thinkingLevel,
			decision: { intent: request.state?.intent ?? config.routing.fallback, latencyMs: 0, reason: "Direct request", fallback: false } };
	}
	if (request.reason === "continuation" || request.reason === "retry") {
		const providerFailure = request.failed?.message?.errorMessage ?? "";
		const allowFailover = request.reason === "retry" && config.routing.failoverOnProviderError &&
			/(429|rate.?limit|overload|temporar(?:y|ily) unavailable)/i.test(providerFailure);
		if (allowFailover && request.failed) {
			const failedRole = sameModel(request.failed.model, config.models.coding) ? "coding" : "general";
			const failoverRole = failedRole === "coding" ? "general" : "coding";
			const failover = config.models[failoverRole];
			if (!sameModel(failover, request.failed.model)) {
				return { model: requireModel(failover, resolve), thinkingLevel: request.thinkingLevel, state: request.state,
					decision: { intent: failoverRole === "coding" ? "code" : "general", latencyMs: 0, reason: "Configured provider failover", fallback: false } };
			}
		}
		const stateModel = request.state?.model;
		const separator = stateModel?.indexOf("/") ?? -1;
		const remembered = separator > 0 ? { provider: stateModel!.slice(0, separator), id: stateModel!.slice(separator + 1) } : undefined;
		const target = sticky?.model ?? (config.routing.stickyContinuations ? remembered : undefined) ?? config.models[config.routing.fallback];
		return { model: requireModel(target, resolve), thinkingLevel: sticky?.thinkingLevel ?? request.thinkingLevel,
			state: request.state, decision: { intent: request.state?.intent ?? config.routing.fallback, latencyMs: 0, reason: request.reason, fallback: false } };
	}
	if (request.signal?.aborted) throw new Error("Routing request was aborted.");

	const input = buildClassificationInput(request.messages, request.state?.intent, config.routing.includeConversationContext);
	let result: ClassificationResult;
	let fallback = false;
	const classifierStarted = performance.now();
	try {
		result = await classifyWithTimeout(classifier, input, config.classifier.timeoutMs, request.signal);
		if (!isClassificationResult(result)) throw new Error("Jeff returned an invalid classification.");
		if (result.confidence < config.classifier.confidenceThreshold) throw new Error("Jeff classification was below the confidence threshold.");
	} catch (error) {
		if (request.signal?.aborted) throw new Error("Routing request was aborted.");
		result = { intent: config.routing.fallback === "coding" ? "code" : "general", confidence: 0, latencyMs: performance.now() - classifierStarted };
		fallback = true;
	}
	const model = requireModel(config.models[result.intent === "code" ? "coding" : "general"], resolve);
	return { model, thinkingLevel: request.thinkingLevel,
		state: { intent: result.intent, model: `${model.provider}/${model.id}`, confidence: result.confidence, latencyMs: result.latencyMs,
			reason: fallback ? "Classifier fallback" : "New user request" },
		decision: { intent: result.intent, confidence: result.confidence, latencyMs: result.latencyMs, reason: fallback ? "Classifier fallback" : "New user request", fallback } };
}

function requireModel(model: ModelRef, resolve: ModelResolver): ModelRef {
	const found = resolve(model);
	if (!found) throw new Error(`Configured physical model is unavailable: ${model.provider}/${model.id}`);
	if (found.provider !== model.provider || found.id !== model.id) throw new Error("Model resolver returned an unexpected model.");
	return found;
}
function sameModel(left: ModelRef, right: ModelRef): boolean { return left.provider === right.provider && left.id === right.id; }
function isClassificationResult(value: ClassificationResult): boolean {
	return !!value && (value.intent === "code" || value.intent === "general") && Number.isFinite(value.confidence) &&
		value.confidence >= 0 && value.confidence <= 1 && Number.isFinite(value.latencyMs) && value.latencyMs >= 0;
}
async function classifyWithTimeout(classifier: Classifier, input: ReturnType<typeof buildClassificationInput>, timeoutMs: number, parentSignal?: AbortSignal): Promise<ClassificationResult> {
	const controller = new AbortController();
	let timedOut = false;
	const abort = () => controller.abort();
	parentSignal?.addEventListener("abort", abort, { once: true });
	const timer = setTimeout(() => { timedOut = true; controller.abort(); }, timeoutMs);
	try {
		return await Promise.race([
			classifier.classify(input, { signal: controller.signal }),
			new Promise<never>((_, reject) => controller.signal.addEventListener("abort", () => reject(new Error(timedOut ? "Classifier timed out." : "Classifier request aborted.")), { once: true })),
		]);
	} finally {
		clearTimeout(timer);
		parentSignal?.removeEventListener("abort", abort);
	}
}
