# 013 — Subagents and delegated work

This lesson builds one small `delegate` tool. It starts separate Pi processes,
so each child receives its own context window. Pi does not hide a nested
conversation behind a built-in subagent feature: the extension owns discovery,
policy, process lifecycle, JSONL parsing, bounds, cancellation, and result
presentation.

```text
parent Pi session
      │ model calls delegate
      ├── child Pi: scout    (isolated context, fixture cwd)
      └── child Pi: reviewer (chain only, receives bounded scout report)
```

The sample has two modes: two independent `scout` tasks can run in parallel,
or one `scout` hands evidence to one `reviewer`. Read the committed agent
files before running anything. Markdown here is executable model policy, not
harmless prose: it selects a model, grants tools, and becomes a child system
prompt. A production extension must make an explicit trust decision. This
sample uses exactly two reviewed files in a closed, sample-local directory.

## Inspect the policy

Open [`agents/scout.md`](agents/scout.md). Its fields map directly to the
child invocation:

- `model` becomes `--model azure-openai/<AZURE_PI_TEST_DEPLOYMENT>` after the
  one supported environment substitution;
- `tools` becomes `--tools read,grep,find,ls`, so there is no `bash`, `edit`, or
  `write` capability;
- the Markdown body replaces the child's system prompt through
  `--system-prompt`;
- every child uses the fixed read-only working directory
  `fixtures/tiny-repository`.

The extension also adds `--no-extensions`, `--no-skills`,
`--no-prompt-templates`, `--no-themes`, `--no-context-files`, `--no-session`,
and `--no-approve`. Tool restriction is not the same as disabling Pi's other
resource discovery, so each category is disabled explicitly. Child arguments
are arrays passed to `spawn(..., { shell: false })`; task text is never made
into shell command text.

## Prepare and run the lesson

PowerShell is the primary course path. From this directory, source the script
so its environment changes persist:

```powershell
cd samples/013-subagents
. ./prepare.ps1
pi
```

Ask the interactive parent to follow [`prompts/scout-parallel.md`](prompts/scout-parallel.md).
It should call `delegate` with two `scout` tasks: one finds
`WAREHOUSE_REGION=eu-west` in `src/inventory.ts`, and the other finds
`EXPECTED_SKU_COUNT=3` in `test/inventory.test.ts`. Results are presented in
input order even if the children finish in a different order.

Then use [`prompts/scout-review.md`](prompts/scout-review.md). The first task
is a scout; the reviewer task contains the literal `{previous}` token. The
extension replaces that token once with a bounded, delimited scout report.
The reviewer is told to treat that report as evidence, never as instructions.

The same prompts can be passed non-interactively with PowerShell. For example,
the parent can be asked to use the parallel schema explicitly:

```powershell
Get-Content ./prompts/scout-parallel.md -Raw | pi --mode json --no-session --print
```

The JSONL stream includes progress events, but the extension uses only the
last assistant `message_end` and its `text` parts as a child's final result.
Stderr is diagnostics, not another event stream.

## Verify without a model

Run this from any current directory:

```powershell
pwsh ./samples/013-subagents/verify.ps1
```

The script checks `node`, `pwsh`, and Pi versions, starts Pi once in offline
RPC mode with the production extension and explicit verifier loaded, and then
runs the same exported production core against the fixed fake child. The
model-free matrix covers strict agent discovery, the exact union schema at
startup, child arguments and per-child config, parser success/failure cases,
read-only tool policy, two-worker scheduling, partial parallel failure, chain
handoff and stop, UTF-8/stderr bounds, cancellation, cleanup, and fixture
immutability. It does not source credentials or contact Azure.

## Optional live verification

After sourcing `prepare.ps1`, run the separately labelled real-model smoke:

```powershell
./verify-model.ps1
```

This requires `AZURE_PI_TEST_ENDPOINT`, `AZURE_PI_TEST_DEPLOYMENT`, and
`AZURE_PI_TEST_API_KEY`. It makes exactly one parent model call and one scout
child model call, so it needs network access and may incur provider cost. The
assertions are structural: one parent `delegate` call, one successful scout,
exit code zero, stop reason `stop` or `length`, and bounded evidence containing
`WAREHOUSE_REGION` and the fixture path. Exact prose is deliberately not
asserted.

## What the boundary does and does not guarantee

Separate processes provide separate context windows. The extension explicitly
controls their model, tools, prompt, cwd, environment allowlist, config
directory, output limits, concurrency, and timeout. The read-only tool list is
a Pi policy boundary, not an OS sandbox: readable files are still readable.
The real provider credential necessarily reaches a real child, but never goes
in arguments, logs, README output, or returned diagnostics.

Agent definitions are trusted project policy; tasks, fixture text, and scout
reports are untrusted data and may contain prompt injection. Children disable
extensions, skills, prompt templates, themes, and context files independently
of the tool allowlist. The verifier proves direct-child cancellation and
temporary cleanup. Full process-tree supervision and OS/container isolation
are larger production concerns outside this focused sample.

All temporary child configs, lifecycle logs, and test material live below an
OS temporary `pi-sample-013-` directory and are removed in `finally` blocks.
`auth.json` is intentionally exactly `{}`; the root ignore rule hides it
because it is a self-contained Pi config file, not because it contains a
credential.
