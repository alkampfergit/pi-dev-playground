import assert from "node:assert/strict";
import { routeRequest, type Classifier, type RouterConfig } from "../lib/router.ts";

const config: RouterConfig = {
	models: { coding: { provider: "code-provider", id: "coder" }, general: { provider: "general-provider", id: "helper" } },
	classifier: { confidenceThreshold: 0.8, timeoutMs: 25 },
	routing: { fallback: "coding", stickyContinuations: true, includeConversationContext: true },
	observability: { enabled: false, logPromptContents: false },
};
const resolver = (model: { provider: string; id: string }) => model.provider === "missing" ? undefined : model;
const classifier = (intent: "code" | "general" = "code", confidence = 0.94): Classifier => ({
	classify: async () => ({ intent, confidence, latencyMs: 4.2 }),
});
const request = (overrides: Partial<Parameters<typeof routeRequest>[0]> = {}) => ({
	reason: "user" as const, thinkingLevel: "medium", messages: [{ role: "user", content: "Write a C# JWT validator." }], ...overrides,
});

assert.equal((await routeRequest(request(), config, classifier("code"), resolver)).model.id, "coder");
assert.equal((await routeRequest(request(), config, classifier("general"), resolver)).model.id, "helper");
assert.equal((await routeRequest(request({ reason: "continuation", previous: { model: config.models.general, thinkingLevel: "high" }, state: { intent: "general" } }), config, classifier("code"), resolver)).model.id, "helper");
assert.equal((await routeRequest(request({ reason: "retry", failed: { model: config.models.general, thinkingLevel: "low" } }), config, classifier("code"), resolver)).model.id, "helper");
assert.equal((await routeRequest(request({ reason: "direct", previous: { model: config.models.general } }), config, classifier("code"), resolver)).model.id, "helper");
let unexpectedClassification = 0;
const shouldNotClassify: Classifier = { classify: async () => { unexpectedClassification++; throw new Error("must not classify"); } };
assert.equal((await routeRequest(request({ reason: "continuation", state: { model: "general-provider/helper", intent: "general" } }), config, shouldNotClassify, resolver)).model.id, "helper");
assert.equal(unexpectedClassification, 0);
const failoverConfig = { ...config, routing: { ...config.routing, failoverOnProviderError: true } };
assert.equal((await routeRequest(request({ reason: "retry", failed: { model: config.models.general, message: { errorMessage: "HTTP 429 rate limit exceeded" } } }), failoverConfig, shouldNotClassify, resolver)).model.id, "coder");
assert.equal((await routeRequest(request({ reason: "retry", failed: { model: config.models.general, message: { errorMessage: "context length exceeded" } } }), failoverConfig, shouldNotClassify, resolver)).model.id, "helper");
assert.equal((await routeRequest(request({ reason: "retry", failed: { model: config.models.coding, message: { errorMessage: "temporarily unavailable" } } }), failoverConfig, shouldNotClassify, resolver)).model.id, "helper");

const fail = { classify: async () => { throw new Error("offline"); } };
assert.equal((await routeRequest(request(), config, fail, resolver)).model.id, "coder");
const low = { classify: async () => ({ intent: "general" as const, confidence: 0.2, latencyMs: 3 }) };
assert.equal((await routeRequest(request(), config, low, resolver)).decision.fallback, true);
const invalid = { classify: async () => ({ intent: "arbitrary" as "code", confidence: 0.9, latencyMs: 1 }) };
assert.equal((await routeRequest(request(), config, invalid, resolver)).model.id, "coder");
const slow = { classify: () => new Promise<never>(() => {}) };
assert.equal((await routeRequest(request(), config, slow, resolver)).decision.fallback, true);
await assert.rejects(routeRequest(request({ signal: AbortSignal.abort() }), config, classifier(), resolver), /aborted/i);
await assert.rejects(routeRequest(request(), { ...config, models: { ...config.models, coding: { provider: "missing", id: "x" } } }, classifier(), resolver), /unavailable/i);
await assert.rejects(routeRequest(request(), { ...config, models: { ...config.models, coding: { provider: "intent", id: "auto" } } }, classifier(), (model) => model.provider === "intent" ? undefined : model), /unavailable/i);

const contextAware = { classify: async (input: { latest: string; previousUserTurns: string[]; lastIntent?: string }) => {
	assert.match(input.latest, /Now add error handling/);
	assert.match(input.previousUserTurns[0], /JWT middleware/);
	assert.equal(input.lastIntent, "code");
	return { intent: "code" as const, confidence: 0.88, latencyMs: 1 };
} };
await routeRequest(request({ messages: [{ role: "user", content: "Implement a JWT middleware." }, { role: "assistant", content: "Working." }, { role: "user", content: "Now add error handling." }], state: { intent: "code" } }), config, contextAware, resolver);
console.log("PASS: router policy, fallback, continuity, bounds, and validation");
