import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { createHash } from "node:crypto";
import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { discoverAgents, delegateTasks, MAX_RESULT_UTF8_BYTES } from "../extensions/subagents.ts";

const sampleRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const fixtureRoot = path.join(sampleRoot, "fixtures", "tiny-repository");
const tempRoot = os.tmpdir();

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function readLog(logPath: string): any[] {
  if (!existsSync(logPath)) return [];
  return readFileSync(logPath, "utf8").trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
}

function fixtureHash(): string {
  const hash = createHash("sha256");
  const visit = (directory: string) => {
    for (const name of readdirSync(directory).sort()) {
      const file = path.join(directory, name);
      const stat = lstatSync(file);
      if (stat.isDirectory()) visit(file);
      else hash.update(path.relative(fixtureRoot, file)).update("\0").update(readFileSync(file));
    }
  };
  visit(fixtureRoot);
  return hash.digest("hex");
}

async function withFake<T>(callback: (logPath: string) => Promise<T>): Promise<T> {
  const directory = path.join(tempRoot, `pi-sample-013-${cryptoRandom()}`);
  const logPath = path.join(directory, "lifecycle.jsonl");
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const saved = {
    child: process.env.PI_SUBAGENT_TEST_CHILD,
    log: process.env.PI_SUBAGENT_TEST_LOG,
    deployment: process.env.AZURE_PI_TEST_DEPLOYMENT,
  };
  process.env.PI_SUBAGENT_TEST_CHILD = "1";
  process.env.PI_SUBAGENT_TEST_LOG = logPath;
  process.env.AZURE_PI_TEST_DEPLOYMENT = "offline-test-deployment";
  try { return await callback(logPath); }
  finally {
    if (saved.child === undefined) delete process.env.PI_SUBAGENT_TEST_CHILD; else process.env.PI_SUBAGENT_TEST_CHILD = saved.child;
    if (saved.log === undefined) delete process.env.PI_SUBAGENT_TEST_LOG; else process.env.PI_SUBAGENT_TEST_LOG = saved.log;
    if (saved.deployment === undefined) delete process.env.AZURE_PI_TEST_DEPLOYMENT; else process.env.AZURE_PI_TEST_DEPLOYMENT = saved.deployment;
    rmSync(directory, { recursive: true, force: true });
  }
}

function cryptoRandom(): string { return Math.random().toString(36).slice(2) + Date.now().toString(36); }

async function runMatrix(): Promise<void> {
  const before = fixtureHash();
  const agents = discoverAgents();
  assert(agents.map((agent) => agent.name).join(",") === "reviewer,scout", "discovery order or names are wrong");
  assert(agents.every((agent) => agent.tools.join(",") === "read,grep,find,ls"), "agent tool policy is wrong");

  await withFake(async (logPath) => {
    let invalidError = "";
    try { await delegateTasks({ tasks: [{ agent: "scout", task: "FAKE_SUCCESS:bad" }], chain: [{ agent: "scout", task: "bad" }] } as any, new AbortController().signal, undefined, "fake"); }
    catch (error) { invalidError = error instanceof Error ? error.message : ""; }
    assert(invalidError.includes("exactly one"), "mixed shape was accepted");
    assert(readLog(logPath).length === 0, "mixed shape spawned a child");
    let unknownError = "";
    try { await delegateTasks({ tasks: [{ agent: "intruder", task: "FAKE_SUCCESS:bad" }] }, new AbortController().signal, undefined, "fake"); }
    catch (error) { unknownError = error instanceof Error ? error.message : ""; }
    assert(unknownError.includes("Allowed agents: reviewer, scout"), "unknown agent error was unstable");
    assert(readLog(logPath).length === 0, "unknown agent spawned a child");
  });

  await withFake(async (logPath) => {
    const success = await delegateTasks({ tasks: [{ agent: "scout", task: "FAKE_SUCCESS:last assistant" }] }, new AbortController().signal, undefined, "fake");
    const result = success.details.results[0];
    assert(!success.isError && result.status === "succeeded" && result.text === "last assistant", "success parser failed");
    assert(result.stopReason === "stop" && result.exitCode === 0 && result.usage.totalTokens === 21, "success details were not captured");
    const record = readLog(logPath).find((entry) => entry.event === "start");
    assert(record && record.args.includes("--no-extensions") && record.args.includes("--no-skills") && record.args.includes("--no-prompt-templates") && record.args.includes("--no-themes") && record.args.includes("--no-context-files") && record.args.includes("--no-approve"), "child discovery policy was not explicit");
    assert(record.args.includes("--tools") && record.args[record.args.indexOf("--tools") + 1] === "read,grep,find,ls", "child tool allowlist was not explicit");
    assert(record.configModes["auth.json"] === 0o600 && record.configModes["settings.json"] === 0o600, "child config permissions were not bounded");
    const malformed = await delegateTasks({ tasks: [{ agent: "scout", task: "FAKE_MALFORMED" }] }, new AbortController().signal, undefined, "fake");
    assert(malformed.details.results[0].error === "malformed JSONL", "malformed JSONL category missing");
    const noFinal = await delegateTasks({ tasks: [{ agent: "scout", task: "FAKE_NO_FINAL" }] }, new AbortController().signal, undefined, "fake");
    assert(noFinal.details.results[0].error === "no assistant message_end", "no-final category missing");
    const providerError = await delegateTasks({ tasks: [{ agent: "scout", task: "FAKE_ERROR" }] }, new AbortController().signal, undefined, "fake");
    assert(providerError.details.results[0].error === "stop reason error", "stop-reason category missing");
    const nonzero = await delegateTasks({ tasks: [{ agent: "scout", task: "FAKE_EXIT" }] }, new AbortController().signal, undefined, "fake");
    assert(nonzero.details.results[0].error === "nonzero exit", "nonzero category missing");
    const bounded = await delegateTasks({ tasks: [{ agent: "scout", task: "FAKE_SUCCESS:MULTIBYTE" }] }, new AbortController().signal, undefined, "fake");
    assert(Buffer.byteLength(bounded.details.results[0].text) <= MAX_RESULT_UTF8_BYTES && bounded.details.results[0].text.includes("bytes omitted"), "multibyte result was not bounded");
    const stderr = await delegateTasks({ tasks: [{ agent: "scout", task: "FAKE_STDERR" }] }, new AbortController().signal, undefined, "fake");
    assert(Buffer.byteLength(stderr.details.results[0].stderrTail ?? "") <= 4096 && stderr.details.results[0].stderrTail?.includes("bytes omitted"), "stderr was not tail-bounded");
  });

  await withFake(async (logPath) => {
    const parallel = await delegateTasks({ tasks: [1, 2, 3, 4].map((n) => ({ agent: "scout", task: `FAKE_DELAY:${50 + (5 - n) * 10}:ORDER${n}` })) }, new AbortController().signal, undefined, "fake");
    assert(parallel.details.results.map((result) => result.text).join(",") === "ORDER1,ORDER2,ORDER3,ORDER4", "parallel results lost input order");
    const records = readLog(logPath);
    const starts = records.filter((record) => record.event === "start");
    const ends = records.filter((record) => record.event === "end");
    let current = 0;
    let maximum = 0;
    for (const point of [...starts.map((record) => [record.monotonic, 1]), ...ends.map((record) => [record.monotonic, -1])].sort((a, b) => Number(a[0]) - Number(b[0]))) {
      current += Number(point[1]);
      maximum = Math.max(maximum, current);
    }
    assert(maximum <= 2 && starts.length === 4 && ends.length === 4, "parallel concurrency bound failed");
    const partial = await delegateTasks({ tasks: [{ agent: "scout", task: "FAKE_SUCCESS:kept sibling" }, { agent: "scout", task: "FAKE_ERROR" }] }, new AbortController().signal, undefined, "fake");
    assert(partial.isError && partial.details.results.length === 2 && partial.details.results[0].text === "kept sibling", "parallel partial failure erased sibling evidence");
  });

  await withFake(async (logPath) => {
    const chain = await delegateTasks({ chain: [{ agent: "scout", task: "FAKE_SUCCESS:SCOUT_TOKEN_013" }, { agent: "reviewer", task: "EXPECT_PREVIOUS:SCOUT_TOKEN_013 {previous}" }] }, new AbortController().signal, undefined, "fake");
    assert(!chain.isError && chain.details.results.length === 2 && chain.details.results[1].text.includes("SCOUT_TOKEN_013"), "chain handoff failed");
    const failing = await delegateTasks({ chain: [{ agent: "scout", task: "FAKE_ERROR" }, { agent: "reviewer", task: "EXPECT_PREVIOUS:never {previous}" }] }, new AbortController().signal, undefined, "fake");
    assert(failing.isError && readLog(logPath).filter((entry) => entry.event === "start").length === 3, "failed scout launched reviewer");
  });

  await withFake(async (logPath) => {
    const controller = new AbortController();
    const pending = delegateTasks({ tasks: [1, 2, 3, 4].map((n) => ({ agent: "scout", task: `FAKE_WAIT:WAIT${n}` })) }, controller.signal, undefined, "fake");
    const deadline = Date.now() + 5000;
    while (readLog(logPath).filter((entry) => entry.event === "start").length < 2 && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
    assert(readLog(logPath).filter((entry) => entry.event === "start").length === 2, "cancellation did not reach two running children");
    controller.abort();
    const cancelled = await pending;
    const records = readLog(logPath);
    assert(cancelled.details.results.filter((result) => result.status === "aborted").length === 4, `cancellation statuses were not stable: ${cancelled.details.results.map((result) => `${result.status}/${result.error ?? "none"}`).join(",")}`);
    assert(records.filter((entry) => entry.event === "start").length === 2 && records.filter((entry) => entry.event === "terminated").length === 2, `queued or running children survived cancellation: ${records.map((entry) => `${entry.marker}/${entry.event}`).join(",")}`);
    for (const record of records.filter((entry) => entry.event === "start")) assert(!existsSync(record.configDirPath), "child config directory was not removed");
  });

  assert(before === fixtureHash(), "fixture changed during model-free verification");
}

export default async function (pi: ExtensionAPI) {
  const run = async () => {
    try {
      await runMatrix();
      process.stdout.write(JSON.stringify({ type: "verification_result", success: true }) + "\n");
    } catch (error) {
      process.stdout.write(JSON.stringify({ type: "verification_result", success: false, error: error instanceof Error ? error.message : "verification failed" }) + "\n");
      process.exitCode = 1;
    }
  };
  pi.registerCommand("verify-subagents", {
    description: "Run the model-free sample 013 verifier",
    handler: run,
  });
  if (process.env.PI_SUBAGENT_VERIFY === "1") await run();
}
