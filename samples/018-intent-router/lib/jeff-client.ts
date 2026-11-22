import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { createInterface } from "node:readline";
import type { Classifier, ClassificationInput, ClassificationResult } from "./router.ts";

interface JeffConfig {
	engine: "gliner" | "jeff";
	modelPath?: string;
	labels?: { code: string; general: string };
	confidenceThreshold: number;
	timeoutMs: number;
	jeff: { adapter: string; functionId: string; context?: Record<string, unknown>; labels?: Record<string, string> };
}
interface Pending { resolve(value: ClassificationResult): void; reject(error: Error): void; }

/** One JSONL child per extension lifetime; Jeff's local model is initialized once and reused. */
export class JeffLocalClassifier implements Classifier {
	private child?: ChildProcessWithoutNullStreams;
	private nextId = 1;
	private readonly pending = new Map<number, Pending>();
	private startError?: Error;

	constructor(private readonly sampleDir: string, private readonly config: JeffConfig) {}

	classify(input: ClassificationInput, options: { signal?: AbortSignal } = {}): Promise<ClassificationResult> {
		if (options.signal?.aborted) return Promise.reject(new Error("Request aborted."));
		this.ensureStarted();
		const id = this.nextId++;
		return new Promise((resolve, reject) => {
			const abort = () => { this.pending.delete(id); reject(new Error("Request aborted.")); };
			options.signal?.addEventListener("abort", abort, { once: true });
			this.pending.set(id, { resolve: (value) => { options.signal?.removeEventListener("abort", abort); resolve(value); }, reject: (error) => { options.signal?.removeEventListener("abort", abort); reject(error); } });
			this.child!.stdin.write(`${JSON.stringify({ id, input, config: this.config })}\n`, (error) => {
				if (error) { const entry = this.pending.get(id); this.pending.delete(id); entry?.reject(new Error("Could not send request to local Jeff.")); }
			});
		});
	}

	close(): void {
		const child = this.child;
		this.child = undefined;
		if (child) {
			child.stdin.end();
			const forceStop = setTimeout(() => child.kill(), 3_000);
			forceStop.unref();
			child.once("exit", () => clearTimeout(forceStop));
		}
		for (const pending of this.pending.values()) pending.reject(new Error("Local Jeff process stopped."));
		this.pending.clear();
	}

	private ensureStarted(): void {
		if (this.child) return;
		if (this.startError) throw this.startError;
			const venvPython = process.platform === "win32" ? `${this.sampleDir}/.venv/Scripts/python.exe` : `${this.sampleDir}/.venv/bin/python`;
			const python = process.env.LOCAL_CLASSIFIER_PYTHON ?? process.env.JEFF_PYTHON ?? (existsSync(venvPython) ? venvPython : "python3");
		const script = `${this.sampleDir}/jeff/classifier.py`;
		const env: NodeJS.ProcessEnv = { PATH: process.env.PATH, HOME: process.env.HOME, TMPDIR: process.env.TMPDIR, LANG: process.env.LANG };
		const child = spawn(python, [script], { cwd: this.sampleDir, env, stdio: ["pipe", "pipe", "pipe"] });
		this.child = child;
		const lines = createInterface({ input: child.stdout });
		lines.on("line", (line) => {
			let message: { id?: number; result?: ClassificationResult; error?: string };
			try { message = JSON.parse(line) as typeof message; } catch { return; }
			if (typeof message.id !== "number") return;
			const pending = this.pending.get(message.id);
			if (!pending) return;
			this.pending.delete(message.id);
			if (message.error) pending.reject(new Error("Local Jeff returned an error."));
			else if (message.result) pending.resolve(message.result);
			else pending.reject(new Error("Local Jeff returned an invalid response."));
		});
		child.stderr.on("data", () => { /* Jeff diagnostics can contain input; never forward them. */ });
		child.on("error", () => { this.startError = new Error("Could not start the configured local Jeff Python runtime."); this.failPending(this.startError); });
		child.on("exit", () => { if (this.child === child) this.child = undefined; this.failPending(new Error("Local Jeff process exited.")); });
	}

	private failPending(error: Error): void {
		for (const pending of this.pending.values()) pending.reject(error);
		this.pending.clear();
	}
}
