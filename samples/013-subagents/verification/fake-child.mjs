import { appendFile, mkdir, stat } from "node:fs/promises";
import process from "node:process";

const logPath = process.env.PI_SUBAGENT_TEST_LOG;
if (process.env.PI_SUBAGENT_TEST_CHILD !== "1" || !logPath || !logPath.startsWith(process.env.TMPDIR || "/tmp")) process.exit(91);

const args = process.argv.slice(2);
const taskArgument = [...args].reverse().find((value) => value.startsWith("Task: ")) || "Task: ";
const task = taskArgument.slice(6);
const markerMatch = task.match(/(FAKE_[A-Z]+(?::[^\s]+)?|EXPECT_PREVIOUS:[^\s]+)/);
const marker = markerMatch?.[1] || "none";
const timestamp = () => ({ monotonic: Number(process.hrtime.bigint()), wall: new Date().toISOString() });
const write = async (event, extra = {}) => {
  await appendFile(logPath, JSON.stringify({ pid: process.pid, event, marker, ...extra, ...timestamp() }) + "\n");
};

await mkdir(logPath.slice(0, logPath.lastIndexOf("/")), { recursive: true });
const configDir = process.env.PI_CODING_AGENT_DIR;
const sessionDir = process.env.PI_CODING_AGENT_SESSION_DIR;
let configModes = {};
for (const name of ["models.json", "settings.json", "auth.json"]) {
  try { configModes[name] = (await stat(`${configDir}/${name}`)).mode & 0o777; } catch { configModes[name] = null; }
}
await write("start", { cwd: process.cwd(), configDirPath: configDir, sessionDirPath: sessionDir, configModes, args });

const emitSuccess = async (text, stopReason = "stop") => {
  process.stdout.write(JSON.stringify({ type: "message_update", message: { role: "assistant", content: [{ type: "text", text: "progress" }] } }) + "\n");
  process.stdout.write(JSON.stringify({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text }], stopReason, usage: { input: 11, output: 7, cacheRead: 2, cacheWrite: 1, totalTokens: 21 } } }) + "\n");
  process.stdout.write(JSON.stringify({ type: "agent_end", messages: [] }) + "\n");
  await write("end", { stopReason });
};

const delayMatch = task.match(/^FAKE_DELAY:(\d+):(.*)$/s);
if (task.startsWith("FAKE_WAIT")) {
  const keepAlive = setInterval(() => {}, 1000);
  const terminate = async () => { clearInterval(keepAlive); await write("terminated"); process.exit(143); };
  process.once("SIGTERM", terminate);
  process.once("SIGINT", terminate);
  await new Promise(() => {});
} else if (task.startsWith("FAKE_MALFORMED")) {
  process.stdout.write("not-json\n");
  process.exit(0);
} else if (task.startsWith("FAKE_NO_FINAL")) {
  process.stdout.write(JSON.stringify({ type: "agent_end", messages: [] }) + "\n");
  await write("end", { stopReason: "none" });
} else if (task.startsWith("FAKE_ERROR")) {
  process.stdout.write(JSON.stringify({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "fake provider error" }], stopReason: "error" } }) + "\n");
  process.stdout.write(JSON.stringify({ type: "agent_end", messages: [] }) + "\n");
  await write("end", { stopReason: "error" });
} else if (task.startsWith("FAKE_EXIT")) {
  process.stderr.write("fake child diagnostic\n");
  process.exit(7);
} else if (task.startsWith("FAKE_STDERR")) {
  process.stderr.write("é".repeat(5000));
  await write("end", { stopReason: "nonzero" });
  process.exit(7);
} else if (task.startsWith("FAKE_SUCCESS:MULTIBYTE")) {
  await emitSuccess("🙂".repeat(20000));
} else if (delayMatch) {
  await new Promise((resolve) => setTimeout(resolve, Number(delayMatch[1])));
  await emitSuccess(delayMatch[2]);
} else if (task.startsWith("EXPECT_PREVIOUS:")) {
  const token = task.slice("EXPECT_PREVIOUS:".length).split(/\s/)[0];
  if (!task.includes(token)) process.exit(8);
  await emitSuccess(`REVIEWED ${token}`);
} else if (task.startsWith("FAKE_SUCCESS:")) {
  await emitSuccess(task.slice("FAKE_SUCCESS:".length));
} else {
  await emitSuccess("fake success");
}
