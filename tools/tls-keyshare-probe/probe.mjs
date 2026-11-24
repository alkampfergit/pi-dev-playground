#!/usr/bin/env node

import dns from "node:dns/promises";
import tls from "node:tls";
import { performance } from "node:perf_hooks";

const GROUPS = [
  { name: "node-default" },
  { name: "classical", curves: "X25519" },
  { name: "hybrid-first", curves: "X25519MLKEM768:X25519" },
];

function usage() {
  console.error("Usage: node probe.mjs --host HOST [--count 20] [--port 443] [--timeout-ms 5000] [--delay-ms 0] [--family 4|6] [--ip ADDRESS]");
  process.exit(2);
}

function optionsFromArgs(args) {
  const options = { count: 20, port: 443, timeoutMs: 5000, delayMs: 0, family: 4 };
  const names = new Map([
    ["--host", "host"], ["--ip", "ip"], ["--count", "count"],
    ["--port", "port"], ["--timeout-ms", "timeoutMs"], ["--delay-ms", "delayMs"],
    ["--family", "family"],
  ]);
  for (let i = 0; i < args.length; i += 2) {
    const key = names.get(args[i]);
    if (!key || i + 1 >= args.length) usage();
    options[key] = args[i + 1];
  }
  if (!options.host || /[:/\s]/.test(options.host)) usage();
  for (const key of ["count", "port", "timeoutMs", "delayMs"]) {
    const value = Number(options[key]);
    if (!Number.isSafeInteger(value) || value < (key === "delayMs" ? 0 : 1)) usage();
    options[key] = value;
  }
  options.family = Number(options.family);
  if (options.family !== 4 && options.family !== 6) usage();
  return options;
}

function handshake(host, ip, port, timeoutMs, group, attempt) {
  return new Promise((resolve) => {
    const started = performance.now();
    let finished = false;
    let connected = false;
    const socket = tls.connect({
      host: ip,
      port,
      servername: host,
      ALPNProtocols: ["http/1.1"],
      rejectUnauthorized: true,
      ...(group.curves ? {
        minVersion: "TLSv1.3",
        maxVersion: "TLSv1.3",
        ecdhCurve: group.curves,
      } : {}),
    });
    const finish = (ok, error) => {
      if (finished) return;
      finished = true;
      const result = {
        attempt,
        host,
        ip,
        group: group.name,
        curves: group.curves || "Node default",
        ok,
        tcpConnected: connected,
        latencyMs: Math.round(performance.now() - started),
        ...(ok ? { protocol: socket.getProtocol(), alpn: socket.alpnProtocol || null } : {
          errorCode: error?.code || "TLS_ERROR",
          error: String(error?.message || "TLS handshake failed").replace(/\s+/g, " ").slice(0, 180),
        }),
      };
      socket.destroy();
      resolve(result);
    };
    socket.once("connect", () => { connected = true; });
    socket.once("secureConnect", () => finish(true));
    socket.once("error", (error) => finish(false, error));
    socket.setTimeout(timeoutMs, () => {
      const error = new Error(`Timed out after ${timeoutMs} ms`);
      error.code = "ETIMEDOUT";
      finish(false, error);
    });
  });
}

const options = optionsFromArgs(process.argv.slice(2));
let addresses;
try {
  addresses = options.ip ? [{ address: options.ip }] : await dns.lookup(options.host, { all: true, family: options.family });
} catch (error) {
  console.error(`DNS lookup failed: ${error.message}`);
  process.exit(1);
}
if (addresses.length === 0) {
  console.error("DNS lookup returned no addresses");
  process.exit(1);
}

console.log(`Host: ${options.host}:${options.port}`);
console.log(`Resolved IPs: ${addresses.map((item) => item.address).join(", ")}`);
console.log(`Sets: ${options.count}; timeout: ${options.timeoutMs} ms`);
console.log("Each set uses the same IP. The forced groups use TLS 1.3; no HTTP request or credentials are sent.\n");

const results = [];
for (let attempt = 1; attempt <= options.count; attempt++) {
  const ip = addresses[(attempt - 1) % addresses.length].address;
  const order = attempt % 2 === 1 ? GROUPS : [...GROUPS].reverse();
  for (const group of order) {
    const result = await handshake(options.host, ip, options.port, options.timeoutMs, group, attempt);
    results.push(result);
    console.log(`${String(attempt).padStart(2)}/${options.count} ${ip} ${group.name.padEnd(12)} ${result.ok ? "OK  " : "FAIL"} ${String(result.latencyMs).padStart(5)} ms tcp=${result.tcpConnected ? "yes" : "no"}${result.ok ? ` ${result.protocol}` : ` ${result.errorCode}: ${result.error}`}`);
  }
  if (attempt < options.count && options.delayMs > 0) {
    await new Promise((resolve) => setTimeout(resolve, options.delayMs));
  }
}

console.log("\nSummary:");
for (const group of GROUPS) {
  const rows = results.filter((result) => result.group === group.name);
  const success = rows.filter((result) => result.ok).length;
  const errors = Object.entries(rows.filter((result) => !result.ok).reduce((counts, result) => {
    counts[result.errorCode] = (counts[result.errorCode] || 0) + 1;
    return counts;
  }, {})).map(([code, count]) => `${code}=${count}`).join(", ");
  console.log(`${group.name}: ${success}/${rows.length} successful${errors ? `; ${errors}` : ""}`);
}
if (results.some((result) => !result.ok)) process.exitCode = 1;
