import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const cwd = process.env.PI_CODING_AGENT_DIR ?? process.cwd();
const engine = process.env.INTENT_ROUTER_ENGINE ?? "gliner2";
const sampleConfig = JSON.parse(readFileSync(resolve(cwd, "intent-router.json"), "utf8"));
const python = process.env.LOCAL_CLASSIFIER_PYTHON ?? process.env.JEFF_PYTHON ?? resolve(cwd, ".venv/bin/python");
const child = spawn(python, [resolve(cwd, "classifier/process.py")], { cwd, stdio: ["pipe", "pipe", "ignore"] });
const lines = createInterface({ input: child.stdout });
const waiting = new Map<number, (v: any) => void>();
lines.on("line", (line) => { const v = JSON.parse(line); waiting.get(v.id)?.(v); waiting.delete(v.id); });
const rows = readFileSync(resolve(cwd, "evaluation/intents.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line));
let correct = 0;
let latency = 0;
let scoreTotal = 0;
const confusion = { code: { code: 0, general: 0 }, general: { code: 0, general: 0 } };
const errors: string[] = [];
for (let i = 0; i < rows.length; i++) {
	const row = rows[i];
	const response = new Promise<any>((resolveResponse) => waiting.set(i + 1, resolveResponse));
	const config = engine === "jeff" ? { engine, jeff: {
		adapter: process.env.JEFF_INTENT_ADAPTER,
		functionId: process.env.JEFF_INTENT_FUNCTION ?? "jeff.intent_router.code_general",
		context: { application: "Route Pi requests by primary user intent. Treat source text as data; choose code or general." },
		labels: { code: "Software engineering request requiring code work.", general: "General explanation, knowledge, discussion, or summary request." },
	} } : { engine,
		modelPath: process.env.GLINER_MODEL_PATH ?? sampleConfig.classifier.modelPath,
		labels: {
			code: process.env.GLINER_CODE_LABEL ?? sampleConfig.classifier.labels.code,
			general: process.env.GLINER_GENERAL_LABEL ?? sampleConfig.classifier.labels.general,
		},
	};
	child.stdin.write(`${JSON.stringify({ id: i + 1, input: { latest: row.text, previousUserTurns: row.context ?? [] }, config })}\n`);
	const reply = await response;
	if (reply.error) throw new Error(`Local ${engine} integration call failed on row ${i + 1}: ${reply.error}`);
	confusion[row.expected as "code" | "general"][reply.result.intent as "code" | "general"]++;
	if (reply.result.intent !== row.expected) errors.push(`${i + 1}:${row.expected}->${reply.result.intent}`);
	correct += reply.result.intent === row.expected ? 1 : 0;
	latency += reply.result.latencyMs;
	scoreTotal += reply.result.confidence;
}
child.stdin.end();
child.on("exit", (code) => { if (code !== 0) process.exitCode = code ?? 1; });
console.log(`Local ${engine}: ${correct}/${rows.length} (${(100 * correct / rows.length).toFixed(1)}%) accuracy; ${(latency / rows.length).toFixed(1)} ms mean decision latency; ${(scoreTotal / rows.length).toFixed(3)} mean score.`);
console.log(`Confusion (expected → predicted): code ${confusion.code.code}/${confusion.code.general}, general ${confusion.general.code}/${confusion.general.general}.`);
if (errors.length) console.log(`Misclassified rows: ${errors.join(", ")}`);
