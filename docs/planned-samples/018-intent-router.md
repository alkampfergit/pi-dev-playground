# 018 — Route requests with a Pi virtual model and local classification

## Shipped implementation update — 2026-11-22

The runnable sample now defaults to local GLiNER2.5
(`fastino/gliner2.5-base-v1`) through the official GLiNER2 single-label
classification schema. The Python process is created from the sample's own
`.venv`, and `setup-local-classifier.sh` keeps downloaded weights and caches in
gitignored sample directories. This Mac-first workflow follows the user's
request for a local classifier and shell setup.

The original GLiNER multitask classification wrapper was tested and rejected:
the installed package returned extracted text spans instead of the requested
intent labels. GLiNER2.5 returned a typed class and score on the installed Mac.
The latest real sample evaluation measured 19/20 (95%) accuracy and 555.7 ms mean
decision latency on the small labeled set; this is educational evidence, not
production quality. Jeff remains an
optional backend for a task-specific local adapter, and Jeff accuracy is not
claimed or included in the GLiNER2.5 result. The design below preserves the
original Jeff-oriented scope and failure requirements; the sample README is
the source of truth for the shipped default and commands.

## Status and compatibility target

Implement for the installed Pi **1.6.0** API on Node **26.11.1**. The installed
`docs/virtual-models.md` and `dist/core/virtual-models.d.ts` are authoritative;
verify signatures before adjusting implementation for a later Pi release.
Jeff references must resolve to `firelex/jeff`, not the separate Jev service or
other projects named Jeff.

## Goal

Demonstrate harness-level model selection: Pi exposes `intent/auto`, an extension
classifies each new user turn using a persistent local Jeff process, then returns
one of two explicitly configured physical catalog models. Pi continues to own
provider auth, streaming, tool calls, retries, and session history. No proxy is
created for destination models.

## Important Jeff constraint

Jeff's local engine and decision SDK are real, but decision adapters are trained
for specific task menus. The open specialist router supports its documented
specialist set and a `base` general-purpose fallback; its labels must not be
reused to pretend that an arbitrary code-versus-general classifier has been
validated. Jeff can accept caller-supplied labels, but this input flexibility
does not prove that an adapter trained for a different domain is accurate on
coding-versus-general intent. The sample therefore defines a Jeff function/adapter contract and
ships labeled examples plus a training/evaluation procedure. Normal routing uses
local inference from that task-specific adapter. Mock classification is limited
to tests. A trained adapter and its weights are not bundled, so Jeff's classifier
accuracy remains unverified until a learner installs the resulting adapter and
runs the opt-in integration evaluation. Before that, real route requests take
the configured fallback after the local function reports that it is unavailable.

Jeff publishes the `jeff-sdk` npm package, but the shipped sample has not
validated the SDK's local Node integration. Its optional Jeff mode uses the
supported Python local SDK in one persistent child process,
with JSON-lines IPC and no network endpoint. Only the classifier child receives
the bounded prompt/context; no provider key is passed. Jeff local runtime setup
requires uv and supported hardware. Adapter training requires an NVIDIA GPU per
current Jeff guidance, so the provided training recipe may need a GPU host.

## Learning outcomes

- Resolve cross-provider models through Pi's model registry and let Pi validate
  their authentication.
- Use `registerVirtualModel()` and `route(request, ctx)` to distinguish new
  user turns, tool continuations, retries, and direct requests.
- Persist small branch-local routing state, preserve the chosen model through
  tool calls and retries, and classify bounded conversation context.
- Keep the local classifier process warm, validate Jeff's typed decision,
  enforce timeout/cancellation/fallback, and keep prompt data out of logs.
- Separate deterministic router-policy tests from measured Jeff accuracy.
- Explain why orchestration policy belongs to the harness and is not prompt
  engineering.

## Architecture and policy

```text
Pi virtual model -> extension policy -> local Jeff process
                                   -> configured code/general model
Pi retains all provider requests, credentials, tools, and session history.
```

The route handler resolves only the exact configured `{ provider, model }`
pairs. `continuation` returns `previous`; `retry` returns `failed` unless the
opt-in provider policy sees a transient 429, rate-limit, overload, or temporary
unavailable error, in which case it tries the other configured destination.
`direct` never recursively classifies.
For a new user request, compact context contains the latest prompt, up to three
prior user turns, and the last known task class. It excludes tool output and
system instructions. Jeff abstentions, low confidence, timeouts, process errors,
invalid outputs, and request aborts have distinct outcomes; only classifier
failures use the configured deterministic fallback. Missing target models are
hard errors.

Only user-authored messages in `request.messages` are candidates for context.
Retrieved code, tool results, and prompt instructions never configure the router.
The same bounded user text is visible to the selected destination provider as
part of the normal Pi conversation; local classification does not prevent that
provider from receiving it.

## Intended layout

```text
samples/018-intent-router/
├── README.md
├── DEMO.md
├── examples/intent-router.example.json
├── extensions/intent-router.ts
├── lib/{router,context,classifier-client}.ts
├── classifier/process.py
├── evaluation/intents.jsonl
├── tests/{router.test,integration.test}.ts
├── setup-local-classifier.sh, verify.sh
└── models.json, settings.json, prepare.ps1, prepare.sh -> shared files
```

The Python child is started once and reused. It loads a local Jeff decision
function from configuration; it never uses `Jeff.remote`, an API key, or a
hosted service. Training examples and held-out evaluation examples must be
separated by source/family to avoid leakage. Report real accuracy only when the
opt-in evaluation runs against the trained local adapter.

## Commands and observability

`/router status`, `/router stats`, and `/router config` expose only sanitized
model IDs, last intent/confidence/latency, counts, and sanitized settings.
They never include raw prompt text, auth values, or whole environment dumps.
Normal user turns show one concise indicator; continuations do not repeat it.

The demo uses one Pi session to show a general question, a coding task, a
multi-tool coding turn, a context-dependent follow-up, and routing statistics.
It compares the routing decision made by the harness with model-generated
content to establish the harness-engineering distinction.

## Verification

- Unit-test routing policy with an injected mock classifier and registry.
- Cover the required route examples, context continuation, state persistence,
  retry/continuation/direct, timeout, cancellation, abstention, invalid results,
  unknown models, and unsupported virtual targets.
- Test Jeff IPC process reuse and parsing without model weights.
- Opt-in integration evaluation calls the real configured local Jeff function
  over a small held-out labeled set and reports measured accuracy and latency.
- Load the extension in Pi offline/RPC mode and prove `intent/auto` registers.
- Run the sample's standard verifier and `git diff --check`.

## Acceptance notes

Do not claim the Jeff acceptance items pass unless the local task adapter is
installed and the integration evaluation ran. The sample must still deliver a
complete native Pi router, reproducible model-free verification, a real local
inference adapter seam, data/training instructions, security boundaries, and a
presentation script.
