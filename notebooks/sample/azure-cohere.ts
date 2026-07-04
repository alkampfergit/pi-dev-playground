// Standalone probe: figure out which Azure host/path actually serves the
// deployment. Reuses the same env-loading routine as the notebook.
//
// Run from the repo:  deno run --allow-all notebooks/sample/azure-cohere.ts
import { loadEnvUp } from "playground/env";

await loadEnvUp({ log: false });

const rawEndpoint = Deno.env.get("AZURE_PI_TEST_ENDPOINT");
const apiKey = Deno.env.get("AZURE_PI_TEST_API_KEY");
const deployment = (Deno.env.get("AZURE_PI_TEST_DEPLOYMENT") ?? "").split(/[,\s]+/).filter(Boolean)[0];

if (!rawEndpoint || !apiKey || !deployment) {
  console.error("Missing AZURE_PI_TEST_ENDPOINT / _API_KEY / _DEPLOYMENT");
  Deno.exit(1);
}

const host = new URL(rawEndpoint).hostname;                 // e.g. alkampferaiok-resource.openai.azure.com
const resource = host.split(".")[0];                        // e.g. alkampferaiok-resource
console.log(`endpoint host : ${host}`);
console.log(`resource      : ${resource}`);
console.log(`deployment    : ${deployment}`);
console.log(`key length    : ${apiKey.length}\n`);

// Candidate base URLs + how the deployment/model is addressed.
type Candidate = { label: string; url: string; auth: "bearer" | "api-key" };
const candidates: Candidate[] = [
  { label: "openai.azure.com  /openai/v1     (Bearer)", url: `https://${resource}.openai.azure.com/openai/v1/chat/completions`, auth: "bearer" },
  { label: "services.ai...    /openai/v1     (Bearer)", url: `https://${resource}.services.ai.azure.com/openai/v1/chat/completions`, auth: "bearer" },
  { label: "services.ai...    /models        (Bearer, api-version)", url: `https://${resource}.services.ai.azure.com/models/chat/completions?api-version=2024-05-01-preview`, auth: "bearer" },
  { label: "openai.azure.com  /deployments   (api-key, api-version)", url: `https://${resource}.openai.azure.com/openai/deployments/${deployment}/chat/completions?api-version=2024-10-21`, auth: "api-key" },
];

const body = JSON.stringify({
  model: deployment,
  messages: [{ role: "user", content: "Say hello in one short sentence." }],
  max_tokens: 20,
});

for (const c of candidates) {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (c.auth === "bearer") headers["Authorization"] = `Bearer ${apiKey}`;
  else headers["api-key"] = apiKey;
  try {
    const r = await fetch(c.url, { method: "POST", headers, body });
    const text = await r.text();
    const ok = r.status === 200 ? "✅" : "❌";
    console.log(`${ok} [${r.status}] ${c.label}`);
    console.log(`     ${c.url}`);
    console.log(`     ${text.replace(/\s+/g, " ").slice(0, 200)}\n`);
  } catch (e) {
    console.log(`💥 [ERR] ${c.label}`);
    console.log(`     ${c.url}`);
    console.log(`     ${String(e).replace(/\s+/g, " ").slice(0, 200)}\n`);
  }
}
