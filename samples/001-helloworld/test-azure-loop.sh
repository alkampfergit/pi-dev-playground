#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PI_CODING_AGENT_DIR="$SCRIPT_DIR"

if [[ -z "${AZURE_PI_TEST_API_KEY:-}" ]]; then
    echo "Load the sample environment first: source ./prepare.sh" >&2
    echo "Required: AZURE_PI_TEST_API_KEY" >&2
    exit 2
fi

if ! command -v pi >/dev/null 2>&1; then
    echo "The Pi CLI was not found on PATH." >&2
    exit 2
fi

REQUESTS="${PI_AZURE_LOOP_REQUESTS:-20}"
INTERVAL_SECONDS="${PI_AZURE_LOOP_INTERVAL_SECONDS:-1}"
DEFAULT_MODEL="$(node -e 'const c=require(process.argv[1]); console.log(c.providers["azure-openai"].models[0].id)' "$SCRIPT_DIR/models.json")"
MODEL_ID="${PI_AZURE_LOOP_MODEL:-$DEFAULT_MODEL}"
if ! node -e 'const c=require(process.argv[1]); process.exit(c.providers["azure-openai"].models.some(m => m.id === process.argv[2]) ? 0 : 1)' "$SCRIPT_DIR/models.json" "$MODEL_ID"; then
    echo "Model $MODEL_ID is not registered in this sample's models.json." >&2
    exit 2
fi
MODEL="azure-openai/$MODEL_ID"
PROMPT="${PI_AZURE_LOOP_PROMPT:-Rispondi solo OK.}"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pi-azure-loop.XXXXXX")"
FAILED=0
RESET_TOTAL=0

if ! [[ "$REQUESTS" =~ ^[1-9][0-9]*$ ]]; then
    echo "PI_AZURE_LOOP_REQUESTS must be a positive integer." >&2
    exit 2
fi

echo "Testing Pi's own Azure provider client"
echo "Model: $MODEL"
echo "Requests: $REQUESTS"
echo "Logs: $LOG_DIR"
echo "Context files, skills, extensions, and MCP are disabled for this run."
echo

for ((i = 1; i <= REQUESTS; i++)); do
    EVENTS="$LOG_DIR/request-$i.events.jsonl"
    TRACE="$LOG_DIR/request-$i.stderr.log"
    STARTED_AT="$(date +%s)"

    if NODE_DEBUG=net,tls pi \
        --no-context-files \
        --no-skills \
        --no-extensions \
        --no-mcp \
        --no-session \
        --mode json \
        --model "$MODEL" \
        -p "$PROMPT" \
        >"$EVENTS" 2>"$TRACE"; then
        RESULT=0
    else
        RESULT=$?
    fi

    # Pi can exit 0 even when every assistant message ended with an error.
    if EVENT_STATUS="$(node -e '
        const fs = require("node:fs");
        let finalReason;
        let finalError;
        let errors = 0;
        for (const line of fs.readFileSync(process.argv[1], "utf8").split("\n")) {
            if (!line.trim()) continue;
            try {
                const event = JSON.parse(line);
                if (event.type !== "message_end" || event.message?.role !== "assistant") continue;
                finalReason = event.message.stopReason;
                finalError = event.message.errorMessage;
                if (finalReason === "error") errors++;
            } catch { /* stderr contains the detail if JSON output was interrupted. */ }
        }
        const detail = finalError ? `, detail=${String(finalError).replace(/\s+/g, " ").slice(0, 200)}` : "";
        console.log(`final=${finalReason ?? "missing"}, error messages=${errors}${detail}`);
        if (!finalReason || finalReason === "error" || finalReason === "aborted") process.exitCode = 1;
    ' "$EVENTS")"; then
        EVENT_RESULT=0
    else
        EVENT_RESULT=$?
    fi

    if [[ "$RESULT" -ne 0 || "$EVENT_RESULT" -ne 0 ]]; then
        FAILED=$((FAILED + 1))
    fi

    ELAPSED=$(( $(date +%s) - STARTED_AT ))
    RESET_COUNT="$( { grep -h -o 'ECONNRESET' "$EVENTS" "$TRACE" || true; } | wc -l | tr -d ' ' )"
    RESET_TOTAL=$((RESET_TOTAL + RESET_COUNT))

    if [[ "$RESULT" -eq 0 && "$EVENT_RESULT" -eq 0 ]]; then
        printf '[%d/%d] OK (%ss, %s, ECONNRESET logged: %s)\n' "$i" "$REQUESTS" "$ELAPSED" "$EVENT_STATUS" "$RESET_COUNT"
    else
        printf '[%d/%d] FAIL (Pi exit %d, %s, %ss, ECONNRESET logged: %s)\n' "$i" "$REQUESTS" "$RESULT" "$EVENT_STATUS" "$ELAPSED" "$RESET_COUNT"
        grep -E 'ECONNRESET|Connection error|Error:' "$TRACE" | tail -n 5 || true
    fi

    if [[ "$i" -lt "$REQUESTS" ]]; then
        sleep "$INTERVAL_SECONDS"
    fi
done

echo
printf 'Result: %d succeeded, %d failed; ECONNRESET occurrences logged: %d\n' \
    "$((REQUESTS - FAILED))" "$FAILED" "$RESET_TOTAL"
echo "Full Pi JSON events and Node TLS traces are in: $LOG_DIR"

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi
