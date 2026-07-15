import { spawn } from "node:child_process";
import { promises as fs, lstatSync, readFileSync as readTextFileSync, readdirSync, realpathSync } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export const MAX_ITEMS = 4;
export const MAX_CONCURRENCY = 2;
export const MAX_TASK_CHARS = 4_000;
export const MAX_PREVIOUS_UTF8_BYTES = 16 * 1024;
export const MAX_RESULT_UTF8_BYTES = 32 * 1024;
export const MAX_STDERR_UTF8_BYTES = 4 * 1024;
export const MAX_JSON_LINE_UTF8_BYTES = 1024 * 1024;
export const MAX_STDOUT_UTF8_BYTES = 2 * 1024 * 1024;
export const CHILD_TIMEOUT_MS = 60_000;
export const KILL_GRACE_MS = 2_000;

const ALLOWED_TOOLS = ["read", "grep", "find", "ls"] as const;
const ALLOWED_AGENTS = ["reviewer", "scout"] as const;
const SAMPLE_ROOT = realpathSync(fileURLToPath(new URL("..", import.meta.url)));
const AGENTS_ROOT = path.join(SAMPLE_ROOT, "agents");
const FIXTURE_ROOT = realpathSync(path.join(SAMPLE_ROOT, "fixtures", "tiny-repository"));
const MODELS_FILE = path.join(SAMPLE_ROOT, "models.json");
const FAKE_CHILD = path.join(SAMPLE_ROOT, "verification", "fake-child.mjs");

export interface AgentDefinition {
	name: string;
	description: string;
	model: string;
	tools: string[];
	systemPrompt: string;
	filePath: string;
}

export interface ChildResult {
	index: number;
	agent: "scout" | "reviewer";
	status: "succeeded" | "failed" | "aborted" | "timed-out";
	taskPreview: string;
	text: string;
	stopReason?: string;
	exitCode: number | null;
	signal?: string;
	usage: {
		input: number;
		output: number;
		cacheRead: number;
		cacheWrite: number;
		totalTokens: number;
	};
	stderrTail?: string;
	error?: string;
}

export interface DelegationDetails {
	mode: "parallel" | "chain";
	results: ChildResult[];
}

export interface DelegationResult {
	text: string;
	details: DelegationDetails;
	isError?: boolean;
}

type Task = { agent: string; task: string };
type Request = { tasks?: Task[]; chain?: Task[] };
type LaunchMode = "production" | "fake";

export function parseAgentDefinition(content: string, filePath: string): AgentDefinition {
	const normalized = content.replace(/\r\n?/g, "\n");
	if (!normalized.startsWith("---\n")) throw new Error(`Agent definition '${path.basename(filePath)}' is missing YAML frontmatter.`);
	const close = normalized.indexOf("\n---\n", 4);
	if (close < 0) throw new Error(`Agent definition '${path.basename(filePath)}' has unterminated YAML frontmatter.`);
	const header = normalized.slice(4, close);
	const body = normalized.slice(close + 5).trim();
	if (!body) throw new Error(`Agent definition '${path.basename(filePath)}' has an empty system prompt.`);

	const values: Record<string, string> = {};
	for (const line of header.split("\n")) {
		const match = /^(\w+):[ \t]*(.*)$/.exec(line);
		if (!match) throw new Error(`Agent definition '${path.basename(filePath)}' has an invalid frontmatter line.`);
		const [, key, value] = match;
		if (key in values) throw new Error(`Agent definition '${path.basename(filePath)}' repeats '${key}'.`);
		values[key] = value;
	}
	const expected = new Set(["name", "description", "model", "tools"]);
	for (const key of Object.keys(values)) if (!expected.has(key)) throw new Error(`Agent definition '${path.basename(filePath)}' has unknown key '${key}'.`);
	for (const key of expected) if (!(key in values) || !values[key].trim()) throw new Error(`Agent definition '${path.basename(filePath)}' is missing '${key}'.`);

	const stem = path.basename(filePath, ".md");
	if (!/^[a-z][a-z0-9-]{0,31}$/.test(values.name) || values.name !== stem) {
		throw new Error(`Agent definition '${path.basename(filePath)}' has a name that does not match its filename.`);
	}
	if (values.description.includes("\n") || values.description.length > 160) throw new Error(`Agent definition '${path.basename(filePath)}' has an invalid description.`);
	if (!/^[^/\s]+\/[^/\s]+$/.test(values.model) || /\$\{(?!AZURE_PI_TEST_DEPLOYMENT\})/.test(values.model)) {
		throw new Error(`Agent definition '${path.basename(filePath)}' has an invalid model.`);
	}
	const tools = values.tools.split(",").map((tool) => tool.trim()).filter(Boolean);
	if (tools.length === 0 || new Set(tools).size !== tools.length || tools.some((tool) => !(ALLOWED_TOOLS as readonly string[]).includes(tool))) {
		throw new Error(`Agent definition '${path.basename(filePath)}' contains a disallowed tool.`);
	}
	return { name: values.name, description: values.description, model: values.model, tools, systemPrompt: body, filePath };
}

export function discoverAgents(): AgentDefinition[] {
	let entries;
	try { entries = requireDirEntries(AGENTS_ROOT); } catch (error) { throw new Error(`Cannot discover agents: ${error instanceof Error ? error.message : "read failed"}`); }
	const files: string[] = [];
	for (const entry of entries) {
		const filePath = path.join(AGENTS_ROOT, entry);
		const stat = lstatSync(filePath);
		if (stat.isSymbolicLink()) throw new Error(`Agent discovery rejects symbolic link '${entry}'.`);
		if (stat.isDirectory()) throw new Error(`Agent discovery rejects subdirectory '${entry}'.`);
		if (stat.isFile() && entry.endsWith(".md")) files.push(filePath);
	}
	files.sort((a, b) => path.basename(a).localeCompare(path.basename(b), "en"));
	const agents = files.map((filePath) => parseAgentDefinition(readFileSync(filePath), filePath));
	const names = new Set<string>();
	for (const agent of agents) {
		if (names.has(agent.name)) throw new Error(`Agent discovery found duplicate name '${agent.name}'.`);
		names.add(agent.name);
	}
	return agents;
}

function requireDirEntries(dir: string): string[] {
	return readdirSync(dir);
}

function readFileSync(filePath: string): string {
	return readTextFileSync(filePath, "utf8");
}

function safePrefix(input: string, maxBytes: number): string {
	const bytes = Buffer.from(input, "utf8");
	if (bytes.byteLength <= maxBytes) return input;
	const markerFor = (omitted: number) => `\n\n[${omitted} UTF-8 bytes omitted.]`;
	let prefixLimit = maxBytes - Buffer.byteLength(markerFor(bytes.byteLength), "utf8");
	if (prefixLimit < 0) prefixLimit = 0;
	let prefix = utf8Prefix(bytes, prefixLimit);
	let omitted = bytes.byteLength - Buffer.byteLength(prefix, "utf8");
	let marker = markerFor(omitted);
	while (Buffer.byteLength(prefix + marker, "utf8") > maxBytes && prefix.length > 0) {
		prefix = Array.from(prefix).slice(0, -1).join("");
		omitted = bytes.byteLength - Buffer.byteLength(prefix, "utf8");
		marker = markerFor(omitted);
	}
	return prefix + marker;
}

function utf8Prefix(bytes: Buffer, maxBytes: number): string {
	let end = Math.max(0, Math.min(maxBytes, bytes.byteLength));
	while (end > 0 && (bytes[end] & 0xc0) === 0x80) end--;
	return bytes.subarray(0, end).toString("utf8");
}

function safeTail(input: string, maxBytes: number): string {
	const bytes = Buffer.from(input, "utf8");
	if (bytes.byteLength <= maxBytes) return input;
	const marker = (omitted: number) => `[${omitted} UTF-8 bytes omitted from stderr tail.]\n`;
	let kept = utf8Suffix(bytes, Math.max(0, maxBytes - Buffer.byteLength(marker(bytes.byteLength), "utf8")));
	let omitted = bytes.byteLength - Buffer.byteLength(kept, "utf8");
	let output = marker(omitted) + kept;
	while (Buffer.byteLength(output, "utf8") > maxBytes && kept.length > 0) {
		kept = Array.from(kept).slice(1).join("");
		omitted = bytes.byteLength - Buffer.byteLength(kept, "utf8");
		output = marker(omitted) + kept;
	}
	return output;
}

function utf8Suffix(bytes: Buffer, maxBytes: number): string {
	let start = Math.max(0, bytes.byteLength - maxBytes);
	while (start < bytes.byteLength && (bytes[start] & 0xc0) === 0x80) start++;
	return bytes.subarray(start).toString("utf8");
}

function resolveModel(model: string): string {
	if (/\$\{(?!AZURE_PI_TEST_DEPLOYMENT\})/.test(model)) throw new Error("Agent model contains an unsupported environment token.");
	const deployment = process.env.AZURE_PI_TEST_DEPLOYMENT;
	if (model.includes("${AZURE_PI_TEST_DEPLOYMENT}") && !deployment?.trim()) throw new Error("AZURE_PI_TEST_DEPLOYMENT is unset or empty.");
	return model.replace("${AZURE_PI_TEST_DEPLOYMENT}", deployment ?? "");
}

function taskPreview(task: string): string { return safePrefix(task.replace(/\s+/g, " ").trim(), 120); }

function validateRequest(request: Request, agents: AgentDefinition[]): { mode: "parallel" | "chain"; tasks: Task[] } {
	const hasTasks = Object.prototype.hasOwnProperty.call(request, "tasks");
	const hasChain = Object.prototype.hasOwnProperty.call(request, "chain");
	if (hasTasks === hasChain) throw new Error("Invalid delegate request: provide exactly one of tasks or chain.");
	const list = hasTasks ? request.tasks : request.chain;
	if (!Array.isArray(list) || list.length < 1 || list.length > MAX_ITEMS) throw new Error(`Invalid delegate request: task count must be 1-${MAX_ITEMS}.`);
	const allowed = agents.map((agent) => agent.name).sort().join(", ") || "none";
	for (const item of list) {
		if (!item || typeof item !== "object" || typeof item.agent !== "string" || typeof item.task !== "string") throw new Error(`Invalid delegate request. Allowed agents: ${allowed}.`);
		if (item.task.trim().length === 0 || item.task.length > MAX_TASK_CHARS) throw new Error(`Invalid delegate request: task text is blank or exceeds ${MAX_TASK_CHARS} characters.`);
		if (!agents.some((agent) => agent.name === item.agent)) throw new Error(`Unknown agent. Allowed agents: ${allowed}.`);
	}
	if (hasTasks) {
		if (list.some((item) => item.agent !== "scout")) throw new Error("Invalid parallel delegation: only scout is allowed. Allowed agents: reviewer, scout.");
		return { mode: "parallel", tasks: list };
	}
	if (list.length !== 2 || list[0].agent !== "scout" || list[1].agent !== "reviewer") throw new Error("Invalid chain delegation: required roles are scout then reviewer.");
	if (list[0].task.includes("{previous}")) throw new Error("Invalid chain delegation: scout task must not contain {previous}.");
	if ((list[1].task.match(/\{previous\}/g) ?? []).length !== 1) throw new Error("Invalid chain delegation: reviewer task must contain exactly one {previous}.");
	return { mode: "chain", tasks: list };
}

function baseResult(index: number, agent: string, task: string, status: ChildResult["status"] = "aborted"): ChildResult {
	return { index, agent: agent as ChildResult["agent"], status, taskPreview: taskPreview(task), text: "", exitCode: null, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0 } };
}

function redact(value: string): string {
	let result = value;
	for (const secret of [process.env.AZURE_PI_TEST_API_KEY, process.env.AZURE_PI_TEST_ENDPOINT]) {
		if (secret) result = result.split(secret).join("<redacted>");
	}
	return result;
}

function errorResult(result: ChildResult, error: string, stderr: string): ChildResult {
	result.status = result.status === "aborted" || result.status === "timed-out" ? result.status : "failed";
	result.error = error;
	if (stderr) result.stderrTail = safeTail(redact(stderr), MAX_STDERR_UTF8_BYTES);
	return result;
}

function invocation(args: string[], mode: LaunchMode): { command: string; args: string[] } {
	if (mode === "fake") return { command: process.execPath, args: [FAKE_CHILD, ...args] };
	const currentScript = process.argv[1];
	if (currentScript && !currentScript.startsWith("/$bunfs/root/") && lstatSync(currentScript, { throwIfNoEntry: false })?.isFile()) return { command: process.execPath, args: [currentScript, ...args] };
	const executable = path.basename(process.execPath).toLowerCase();
	if (!/^(node|bun)(\.exe)?$/.test(executable)) return { command: process.execPath, args };
	return { command: "pi", args };
}

function buildChildArgs(agent: AgentDefinition, task: string): string[] {
	return ["--mode", "json", "--print", "--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files", "--no-approve", "--model", resolveModel(agent.model), "--tools", agent.tools.join(","), "--system-prompt", agent.systemPrompt, `Task: ${task}`];
}

function tempPathIsSafe(filePath: string): boolean {
	const tempRoot = path.resolve(os.tmpdir());
	const absolute = path.resolve(filePath);
	const relative = path.relative(tempRoot, absolute);
	return !path.isAbsolute(relative) && relative !== ".." && !relative.startsWith(`..${path.sep}`) && relative.split(path.sep).some((part) => part.startsWith("pi-sample-013-"));
}

async function createChildConfig(): Promise<string> {
	const config = await fs.mkdtemp(path.join(os.tmpdir(), "pi-sample-013-child-"));
	await fs.chmod(config, 0o700);
	await fs.copyFile(MODELS_FILE, path.join(config, "models.json"));
	await fs.writeFile(path.join(config, "settings.json"), JSON.stringify({ defaultProjectTrust: "never" }), { mode: 0o600 });
	await fs.writeFile(path.join(config, "auth.json"), "{}\n", { mode: 0o600 });
	await fs.mkdir(path.join(config, "sessions"), { mode: 0o700 });
	return config;
}

function allowedEnvironment(mode: LaunchMode, logPath?: string): NodeJS.ProcessEnv {
	const names = ["PATH", "HOME", "USERPROFILE", "TMPDIR", "TMP", "TEMP", "SystemRoot", "ComSpec", "AZURE_PI_TEST_ENDPOINT", "AZURE_PI_TEST_DEPLOYMENT", "AZURE_PI_TEST_API_KEY", "AZURE_PI_TEST_DEPLOYMENT2", "PI_OFFLINE"];
	const env: NodeJS.ProcessEnv = {};
	for (const name of names) if (process.env[name] !== undefined) env[name] = process.env[name];
	if (mode === "fake") { env.PI_SUBAGENT_TEST_CHILD = "1"; env.PI_SUBAGENT_TEST_LOG = logPath; }
	return env;
}

function parseEventLine(line: string, state: ParserState): void {
	if (!line.trim()) return;
	let event: any;
	try { event = JSON.parse(line); } catch { throw new Error("malformed JSONL"); }
	if (!event || typeof event !== "object" || typeof event.type !== "string") throw new Error("malformed JSONL");
	if (event.type === "agent_end") state.agentEnd = true;
	if (event.type !== "message_end" || event.message?.role !== "assistant") return;
	const message = event.message;
	const parts = Array.isArray(message.content) ? message.content.filter((part: any) => part?.type === "text" && typeof part.text === "string").map((part: any) => part.text) : [];
	state.finalText = parts.join("");
	state.stopReason = typeof message.stopReason === "string" ? message.stopReason : undefined;
	const usage = message.usage ?? {};
	state.usage.input += numberValue(usage.input);
	state.usage.output += numberValue(usage.output);
	state.usage.cacheRead += numberValue(usage.cacheRead);
	state.usage.cacheWrite += numberValue(usage.cacheWrite);
	state.usage.totalTokens += numberValue(usage.totalTokens) || numberValue(usage.input) + numberValue(usage.output);
}

function numberValue(value: unknown): number { return typeof value === "number" && Number.isFinite(value) ? value : 0; }

interface ParserState {
	buffer: Buffer;
	stdoutBytes: number;
	agentEnd: boolean;
	finalText: string;
	stopReason?: string;
	usage: ChildResult["usage"];
	parserError?: string;
}

async function runChild(index: number, agent: AgentDefinition, task: string, signal: AbortSignal, mode: LaunchMode, logPath?: string): Promise<ChildResult> {
	const result = baseResult(index, agent.name, task, "failed");
	if (signal.aborted) { result.status = "aborted"; result.error = "aborted"; return result; }
	let config: string | undefined;
	let stderr = "";
	let abortKind: "aborted" | "timed-out" | undefined;
	try {
		resolveModel(agent.model);
		config = await createChildConfig();
		const args = buildChildArgs(agent, task);
		const childEnv = allowedEnvironment(mode, logPath);
		childEnv.PI_CODING_AGENT_DIR = config;
		childEnv.PI_CODING_AGENT_SESSION_DIR = path.join(config, "sessions");
		const start = invocation(args, mode);
		const parser: ParserState = { buffer: Buffer.alloc(0), stdoutBytes: 0, agentEnd: false, finalText: "", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0 } };
		const exit = await new Promise<{ code: number | null; signal?: string; spawnError?: string }>((resolve) => {
			let settled = false;
			let closed = false;
			let timer: NodeJS.Timeout | undefined;
			let killTimer: NodeJS.Timeout | undefined;
			let child: ReturnType<typeof spawn>;
			const finish = (value: { code: number | null; signal?: string; spawnError?: string }) => { if (settled) return; settled = true; if (timer) clearTimeout(timer); if (killTimer) clearTimeout(killTimer); signal.removeEventListener("abort", onAbort); resolve(value); };
			const terminate = (kind: "aborted" | "timed-out") => {
				if (closed) return;
				abortKind = abortKind ?? kind;
				try { child.kill("SIGTERM"); } catch { /* close will report the result */ }
				killTimer = setTimeout(() => { if (!closed) { try { child.kill("SIGKILL"); } catch { /* already gone */ } } }, KILL_GRACE_MS);
			};
			const onAbort = () => terminate("aborted");
			try {
				child = spawn(start.command, start.args, { cwd: FIXTURE_ROOT, env: childEnv, shell: false, stdio: ["ignore", "pipe", "pipe"] });
			} catch (error) { finish({ code: null, spawnError: error instanceof Error ? error.message : "spawn failed" }); return; }
			const consume = (data: Buffer) => {
				if (parser.parserError) return;
				parser.stdoutBytes += data.byteLength;
				if (parser.stdoutBytes > MAX_STDOUT_UTF8_BYTES) { parser.parserError = "stdout exceeded limit"; terminate("timed-out"); return; }
				parser.buffer = Buffer.concat([parser.buffer, data]);
				let newline = parser.buffer.indexOf(0x0a);
				while (newline >= 0) {
					const line = parser.buffer.subarray(0, newline).toString("utf8").replace(/\r$/, "");
					if (Buffer.byteLength(line, "utf8") > MAX_JSON_LINE_UTF8_BYTES) { parser.parserError = "JSON line exceeded limit"; terminate("timed-out"); return; }
					try { parseEventLine(line, parser); } catch (error) { parser.parserError = error instanceof Error ? error.message : "malformed JSONL"; terminate("timed-out"); return; }
					parser.buffer = parser.buffer.subarray(newline + 1); newline = parser.buffer.indexOf(0x0a);
				}
				if (parser.buffer.byteLength > MAX_JSON_LINE_UTF8_BYTES) { parser.parserError = "JSON line exceeded limit"; terminate("timed-out"); }
			};
			child.stdout.on("data", consume);
			child.stdout.on("error", () => { parser.parserError = "stdout stream error"; terminate("timed-out"); });
			child.stderr.on("data", (data: Buffer) => { stderr += data.toString("utf8"); if (Buffer.byteLength(stderr, "utf8") > MAX_STDERR_UTF8_BYTES * 2) stderr = safeTail(stderr, MAX_STDERR_UTF8_BYTES * 2); });
			child.on("error", (error) => finish({ code: null, spawnError: error.message }));
			child.on("close", (code, closeSignal) => { closed = true; if (parser.buffer.byteLength > 0 && !parser.parserError) { if (parser.buffer.byteLength > MAX_JSON_LINE_UTF8_BYTES) parser.parserError = "JSON line exceeded limit"; else { try { parseEventLine(parser.buffer.toString("utf8").replace(/\r$/, ""), parser); } catch (error) { parser.parserError = error instanceof Error ? error.message : "malformed JSONL"; } } } finish({ code, signal: closeSignal ?? undefined }); });
			if (signal.aborted) terminate("aborted"); else signal.addEventListener("abort", onAbort, { once: true });
			timer = setTimeout(() => terminate("timed-out"), CHILD_TIMEOUT_MS);
		});
		result.exitCode = exit.code;
		if (exit.signal) result.signal = exit.signal;
		result.usage = parser.usage;
		result.stopReason = parser.stopReason;
		result.text = safePrefix(parser.finalText, MAX_RESULT_UTF8_BYTES);
		if (abortKind === "aborted") { result.status = "aborted"; result.error = "aborted"; }
		else if (abortKind === "timed-out") { result.status = "timed-out"; result.error = parser.parserError ?? "timed out"; }
		else if (exit.spawnError) errorResult(result, "spawn failed", exit.spawnError);
		else if (parser.parserError) errorResult(result, parser.parserError, stderr);
		else if (exit.code !== 0) errorResult(result, "nonzero exit", stderr);
		else if (!parser.agentEnd) errorResult(result, "no agent_end event", stderr);
		else if (!parser.finalText) errorResult(result, "no assistant message_end", stderr);
		else if (["error", "aborted", "toolUse"].includes(parser.stopReason ?? "")) errorResult(result, `stop reason ${parser.stopReason}`, stderr);
		else result.status = "succeeded";
		return result;
	} catch (error) {
		return errorResult(result, redact(error instanceof Error ? error.message : "child failed"), stderr);
	} finally {
		if (config) await fs.rm(config, { recursive: true, force: true }).catch(() => undefined);
	}
}

function resultText(result: ChildResult): string {
	if (result.status === "succeeded") return result.text || "(no output)";
	return [result.error ?? "child failed", result.stderrTail].filter(Boolean).join("\n");
}

function formatResults(mode: "parallel" | "chain", results: ChildResult[]): string {
	if (mode === "parallel") {
		const succeeded = results.filter((result) => result.status === "succeeded").length;
		return `Parallel delegation: ${succeeded}/${results.length} succeeded\n\n${results.map((result, index) => `--- task ${index + 1} | ${result.agent} | ${result.status} ---\n${resultText(result)}`).join("\n\n")}`;
	}
	const failed = results.findIndex((result) => result.status !== "succeeded");
	const prefix = failed >= 0 ? `Chain stopped at step ${failed + 1} (${results[failed].agent})` : "Chain delegation complete";
	return `${prefix}\n\n${results.map((result, index) => `--- step ${index + 1} | ${result.agent} | ${result.status} ---\n${resultText(result)}`).join("\n\n")}`;
}

export async function delegateTasks(request: Request, signal: AbortSignal, onUpdate?: (text: string) => void, mode: LaunchMode = process.env.PI_SUBAGENT_TEST_CHILD === "1" ? "fake" : "production"): Promise<DelegationResult> {
	const agents = discoverAgents();
	const validated = validateRequest(request, agents);
	let logPath: string | undefined;
	if (mode === "fake") {
		logPath = process.env.PI_SUBAGENT_TEST_LOG;
		if (!logPath || !path.isAbsolute(logPath) || !tempPathIsSafe(logPath)) throw new Error("Fake child log path must be an absolute pi-sample-013 temporary path.");
	}
	const byName = new Map(agents.map((agent) => [agent.name, agent]));
	const results: ChildResult[] = new Array(validated.tasks.length);
	if (validated.mode === "parallel") {
		let next = 0;
		const worker = async () => {
			while (true) {
				if (signal.aborted) return;
				const index = next++;
				if (index >= validated.tasks.length) return;
				if (signal.aborted) { results[index] = baseResult(index, validated.tasks[index].agent, validated.tasks[index].task); results[index].error = "aborted"; return; }
				results[index] = await runChild(index, byName.get(validated.tasks[index].agent)!, validated.tasks[index].task, signal, mode, logPath);
				onUpdate?.(`Parallel delegates: ${results.filter(Boolean).length}/${validated.tasks.length} finished`);
			}
		};
		await Promise.all(Array.from({ length: Math.min(MAX_CONCURRENCY, validated.tasks.length) }, () => worker()));
		for (let index = 0; index < validated.tasks.length; index++) if (!results[index]) { results[index] = baseResult(index, validated.tasks[index].agent, validated.tasks[index].task); results[index].error = "aborted"; }
	} else {
		for (let index = 0; index < validated.tasks.length; index++) {
			if (signal.aborted) { results[index] = baseResult(index, validated.tasks[index].agent, validated.tasks[index].task); results[index].error = "aborted"; break; }
			const task = validated.tasks[index];
			let expanded = task.task;
			if (index === 1) {
				const previous = safePrefix(results[0].text, MAX_PREVIOUS_UTF8_BYTES);
				expanded = task.task.replace("{previous}", `<scout-report>\n${previous}\n</scout-report>`);
				if (expanded.length > MAX_TASK_CHARS + MAX_PREVIOUS_UTF8_BYTES) { results[index] = baseResult(index, task.agent, expanded, "failed"); results[index].error = "expanded chain task exceeds bound"; break; }
			}
			results[index] = await runChild(index, byName.get(task.agent)!, expanded, signal, mode, logPath);
			if (results[index].status !== "succeeded") break;
		}
		for (let index = 0; index < results.length; index++) if (!results[index]) { results[index] = baseResult(index, validated.tasks[index].agent, validated.tasks[index].task); results[index].error = "not started"; }
	}
	return { text: formatResults(validated.mode, results), details: { mode: validated.mode, results }, isError: results.some((result) => result.status !== "succeeded") };
}

const Task = Type.Object({ agent: Type.String({ minLength: 1, maxLength: 32 }), task: Type.String({ minLength: 1, maxLength: MAX_TASK_CHARS }) }, { additionalProperties: false });
const DelegateParams = Type.Union([
	Type.Object({ tasks: Type.Array(Task, { minItems: 1, maxItems: MAX_ITEMS }) }, { additionalProperties: false }),
	Type.Object({ chain: Type.Array(Task, { minItems: 1, maxItems: MAX_ITEMS }) }, { additionalProperties: false }),
]);

export default function (pi: ExtensionAPI) {
	// Startup discovery is intentionally eager: malformed trusted policy is not silently skipped.
	discoverAgents();
	pi.registerTool({
		name: "delegate",
		label: "Delegate",
		description: "Delegate 1-4 bounded scout tasks in parallel, or run the exact scout then reviewer chain using the literal {previous} handoff token.",
		parameters: DelegateParams,
		async execute(_toolCallId, params, signal, onUpdate) {
			try {
				const result = await delegateTasks(params as Request, signal, (text) => onUpdate?.({ content: [{ type: "text", text }], details: {} }));
				return { content: [{ type: "text", text: result.text }], details: result.details, isError: result.isError };
			} catch (error) {
				return { content: [{ type: "text", text: error instanceof Error ? error.message : "Delegation rejected." }], details: { mode: "parallel", results: [] }, isError: true };
			}
		},
	});
}
