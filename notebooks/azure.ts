// azure.ts — shared Azure OpenAI provider setup for the pi.dev notebooks.
//
// Every notebook from 02 onward needs the same ~40 lines of Azure registration
// that notebook 01 spelled out cell-by-cell. This module extracts that into one
// call so each notebook can stay focused on the *new* pi feature it teaches.
//
// It reads three environment variables (loaded by `loadEnvUp()` from `env.ts`,
// which each notebook still calls in its first cell). They are named
// `AZURE_PI_TEST_*` to avoid clashing with any pre-existing `AZURE_OPENAI_*`
// vars in your `.env` files:
//
//   AZURE_PI_TEST_ENDPOINT     # e.g. https://<resource>.services.ai.azure.com
//   AZURE_PI_TEST_API_KEY
//   AZURE_PI_TEST_DEPLOYMENT   # deployment name(s), comma/space-separated
//
// Usage from a notebook cell (after `await loadEnvUp()`):
//   import { registerAzure } from "playground/azure";
//   const { models, model, modelId } = registerAzure();
//   const response = await models.completeSimple(model, context);

import {
  createModels,
  createProvider,
  envApiKeyAuth,
  type Model,
  type MutableModels,
} from "@earendil-works/pi-ai";
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy";

/** The provider id every notebook uses to look models up. */
export const AZURE_PROVIDER_ID = "azure-openai";

export interface AzureSetup {
  /** The Models collection with Azure OpenAI registered. */
  models: MutableModels;
  /** The first deployment, resolved and ready to pass to `completeSimple`. */
  model: Model<"openai-completions">;
  /** The id (= Azure deployment name) of `model`. */
  modelId: string;
  /** All deployment names parsed from `AZURE_PI_TEST_DEPLOYMENT`. */
  deployments: string[];
  /** The normalized OpenAI-compatible base URL (`<origin>/openai/v1`). */
  baseUrl: string;
}

export interface RegisterAzureOptions {
  /**
   * An existing Models collection to register the provider on. If omitted, a
   * fresh empty collection is created via `createModels()`.
   */
  models?: MutableModels;
  /**
   * Deployment name(s) to register, overriding `AZURE_PI_TEST_DEPLOYMENT`.
   * Pass e.g. `[Deno.env.get("AZURE_PI_TEST_DEPLOYMENT2")!]` to target a
   * different Azure deployment (like a coding-capable model).
   */
  deployments?: string[];
  /**
   * Per-model capability overrides merged into every registered deployment.
   * Handy when a notebook needs, say, `reasoning: true` or a different
   * `contextWindow`/`maxTokens` than the defaults below.
   */
  modelOverrides?: Partial<Model<"openai-completions">>;
  /** Print a one-line summary of what was registered. Defaults to true. */
  log?: boolean;
}

/**
 * Register Azure OpenAI from the `AZURE_PI_TEST_*` env vars and return the
 * Models collection plus the first deployment resolved and ready to use.
 *
 * We target Azure's OpenAI-compatible `/openai/v1` surface (derived from the
 * endpoint's host), which needs no `api-version` query param and authenticates
 * with the key via Bearer / `api-key` header. The `/models` Model-Inference
 * route requires `api-version`, which pi-ai's OpenAI client can't inject — so we
 * deliberately avoid it.
 *
 * Throws a descriptive error if any of the three env vars is missing — run the
 * notebook's `loadEnvUp()` cell first.
 */
export function registerAzure(options: RegisterAzureOptions = {}): AzureSetup {
  const { models = createModels(), modelOverrides, log = true } = options;

  const rawEndpoint = Deno.env.get("AZURE_PI_TEST_ENDPOINT");
  const azureApiKey = Deno.env.get("AZURE_PI_TEST_API_KEY");
  const deployments = (options.deployments ??
    (Deno.env.get("AZURE_PI_TEST_DEPLOYMENT") ?? "").split(/[,\s]+/))
    .map((s) => s.trim())
    .filter(Boolean);

  if (!rawEndpoint || !azureApiKey || deployments.length === 0) {
    throw new Error(
      "Missing Azure config. Set AZURE_PI_TEST_ENDPOINT, AZURE_PI_TEST_API_KEY, " +
        "and AZURE_PI_TEST_DEPLOYMENT (or pass options.deployments) in a .env, " +
        "then re-run the loadEnvUp() cell.",
    );
  }

  // Normalize any endpoint form (root, /models, /openai/v1, trailing slash) to
  // the clean OpenAI-compatible v1 base: `<origin>/openai/v1`.
  const baseUrl = `${new URL(rawEndpoint).origin}/openai/v1`;

  const azureModels: Model<"openai-completions">[] = deployments.map((id) => ({
    id, // sent as the `model` field; must match your Azure deployment name
    name: `${id} (Azure OpenAI)`,
    api: "openai-completions",
    provider: AZURE_PROVIDER_ID,
    baseUrl,
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, // unknown; not tracked here
    contextWindow: 256_000, // INPUT context window (cohere-command-a is large: ~256K)
    maxTokens: 8_192, // MAX OUTPUT tokens — sent as the request cap
    // Bearer (from envApiKeyAuth) authenticates the /openai/v1 surface; the
    // `api-key` header is a harmless fallback for api-key-style routes.
    headers: { "api-key": azureApiKey },
    ...modelOverrides,
  }));

  models.setProvider(
    createProvider({
      id: AZURE_PROVIDER_ID,
      name: "Azure OpenAI",
      baseUrl,
      auth: { apiKey: envApiKeyAuth("Azure OpenAI key", ["AZURE_PI_TEST_API_KEY"]) },
      models: azureModels,
      api: openAICompletionsApi(),
    }),
  );

  const modelId = deployments[0];
  const model = models.getModel(AZURE_PROVIDER_ID, modelId) as
    | Model<"openai-completions">
    | undefined;
  if (!model) throw new Error(`Model ${AZURE_PROVIDER_ID}/${modelId} not found after registration.`);

  if (log) {
    console.log(`Azure OpenAI registered → base ${baseUrl}`);
    console.log(`  deployments: ${deployments.join(", ")} (using "${modelId}")`);
  }

  return { models, model, modelId, deployments, baseUrl };
}
