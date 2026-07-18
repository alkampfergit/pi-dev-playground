#!/usr/bin/env bash
# List privacy-preserving metadata for this sample's Pi sessions.
# Conversation content is read only to count records; it is never printed.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
sessions_directory="$script_dir/sessions/lifecycle-lab"
format="table"

usage() {
  cat <<'EOF'
Usage: ./list-sessions.sh [--sessions-directory <directory>] [--format table|json]

List privacy-preserving metadata for Pi session JSONL files created by this
sample. Conversation text, tool data, and absolute paths are never printed.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -s|--sessions-directory)
      [ "$#" -ge 2 ] || { echo "Missing value for $1." >&2; exit 2; }
      sessions_directory="$2"
      shift 2
      ;;
    -f|--format)
      [ "$#" -ge 2 ] || { echo "Missing value for $1." >&2; exit 2; }
      format="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$format" in
  table|json) ;;
  *) echo "Format must be 'table' or 'json'." >&2; exit 2 ;;
esac

command -v node >/dev/null 2>&1 || {
  echo "The 'node' command is required to inspect Pi JSONL session metadata." >&2
  exit 127
}

# Node gives this Bash helper reliable JSON parsing and Unicode-safe timestamps.
node - "$sessions_directory" "$script_dir" "$format" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [sessionsDirectory, sampleRoot, format] = process.argv.slice(2);
const columns = [
  "Name", "Id", "CreatedUtc", "ModifiedUtc", "Entries", "Messages",
  "UserTurns", "AssistantTurns", "ToolResultTurns", "IsFork", "ParentId",
  "RelativeFile",
];

function warn(relativeFile, reason) {
  process.stderr.write(`WARNING: Skipping '${relativeFile}': ${reason}.\n`);
}

function filesBelow(directory) {
  const result = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) result.push(...filesBelow(entryPath));
    else if (entry.isFile() && entry.name.endsWith(".jsonl")) result.push(entryPath);
  }
  return result.sort();
}

function parentId(parentSession) {
  if (typeof parentSession !== "string" || !parentSession.trim()) return "";
  const match = path.basename(parentSession, path.extname(parentSession)).match(
    /([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})/i,
  );
  return match ? match[1] : "";
}

function safeReason(error) {
  return [
    "contains invalid JSON",
    "is empty",
    "does not have a valid versioned session header",
    "has an invalid header timestamp",
  ].includes(error.message) ? error.message : "could not be read safely";
}

const results = [];
if (fs.existsSync(sessionsDirectory) && fs.statSync(sessionsDirectory).isDirectory()) {
  const root = path.resolve(sessionsDirectory);
  const resolvedSampleRoot = path.resolve(sampleRoot);
  for (const file of filesBelow(root)) {
    const relativeFile = path.relative(root, file);
    try {
      const records = fs.readFileSync(file, "utf8").split(/\r?\n/)
        .filter((line) => line.trim())
        .map((line) => {
          try { return JSON.parse(line); }
          catch { throw new Error("contains invalid JSON"); }
        });
      if (!records.length) throw new Error("is empty");

      const header = records[0];
      if (!header || header.type !== "session" || !Number.isInteger(header.version) ||
          header.version < 1 || typeof header.id !== "string" || !header.id ||
          typeof header.timestamp !== "string" || !header.timestamp ||
          typeof header.cwd !== "string" || !header.cwd) {
        throw new Error("does not have a valid versioned session header");
      }
      if (path.resolve(header.cwd) !== resolvedSampleRoot) continue;

      const created = new Date(header.timestamp);
      if (Number.isNaN(created.valueOf())) throw new Error("has an invalid header timestamp");

      let name = "";
      let messages = 0;
      let userTurns = 0;
      let assistantTurns = 0;
      let toolResultTurns = 0;
      for (const record of records) {
        if (record.type === "session_info" && record.name !== undefined && record.name !== null) {
          name = String(record.name);
        }
        if (record.type !== "message") continue;
        messages += 1;
        switch (record.message?.role) {
          case "user": userTurns += 1; break;
          case "assistant": assistantTurns += 1; break;
          case "toolResult": toolResultTurns += 1; break;
        }
      }
      const stat = fs.statSync(file);
      const isFork = typeof header.parentSession === "string" && !!header.parentSession.trim();
      results.push({
        Name: name,
        Id: header.id,
        CreatedUtc: created.toISOString(),
        ModifiedUtc: stat.mtime.toISOString(),
        Entries: records.length,
        Messages: messages,
        UserTurns: userTurns,
        AssistantTurns: assistantTurns,
        ToolResultTurns: toolResultTurns,
        IsFork: isFork,
        ParentId: parentId(header.parentSession),
        RelativeFile: relativeFile,
      });
    } catch (error) {
      warn(relativeFile, safeReason(error));
    }
  }
}

results.sort((left, right) => right.ModifiedUtc.localeCompare(left.ModifiedUtc) || left.Id.localeCompare(right.Id));
if (format === "json") {
  process.stdout.write(`${JSON.stringify(results, null, 2)}\n`);
  process.exit(0);
}
if (!results.length) {
  console.log("No sessions found for this sample.");
  process.exit(0);
}

const widths = Object.fromEntries(columns.map((column) => [
  column,
  Math.max(column.length, ...results.map((result) => String(result[column]).length)),
]));
const row = (record) => columns.map((column) => String(record[column]).padEnd(widths[column])).join("  ");
console.log(row(Object.fromEntries(columns.map((column) => [column, column]))));
console.log(columns.map((column) => "-".repeat(widths[column])).join("  "));
for (const result of results) console.log(row(result));
NODE
