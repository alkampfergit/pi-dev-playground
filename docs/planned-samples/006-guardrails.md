# 006 — Guardrails: intercept and gate tool calls

## Outcome

Build a small, auto-discovered Pi extension that decides whether each
`bash`, `write`, or `edit` call may execute. By the end of the sample, the
learner can distinguish three different outcomes:

1. a normal call is allowed immediately;
2. a write to a protected path is always blocked with a useful reason; and
3. a recognizable destructive shell command asks for confirmation in the TUI
   but fails closed when no dialog-capable UI exists.

This is the direct sequel to sample 004. `--tools` and
`pi.setActiveTools()` decide which capabilities the model can see;
`tool_call` runs after the model has selected an active tool and decides whether
that particular invocation may proceed.

## Learner-facing scenario

The extension represents a deliberately small project policy:

- ordinary writes, such as `output/allowed.txt`, are allowed;
- `write` and `edit` cannot target `.env` files, `.git`, or `node_modules`;
- a recursive forced removal, such as `rm -rf output/temporary`, requires an
  explicit human decision;
- when Pi runs with `-p` or `--mode json`, that same removal is blocked because
  no confirmation dialog is available; and
- `/guard on`, `/guard off`, and `/guard status` make the policy boundary
  observable during an interactive lesson.

The README must make the consequence of the last command explicit: turning the
sample guard off intentionally restores normal Pi behavior. The toggle is an
educational session control, not an administrative authorization system.

## Files to implement

Create this standalone sample:

```text
samples/006-guardrails/
├── README.md
├── extensions/
│   └── guardrails.ts
├── models.json  -> ../models.json
├── settings.json -> ../settings.json
├── prepare.ps1  -> ../prepare.ps1
└── prepare.sh   -> ../prepare.sh
```

Do not add a package, build step, install script, copied model registry, or a
second extension. Pi 0.80.6 loads TypeScript through jiti. The four links must
be real symlinks with exactly the targets shown above, following samples
003–005. Generated `output/`, `sessions/`, `bin/`, `auth.json`, and wire-log
`dump/` content must remain untracked.

After implementation, replace this planning brief with the teacher-to-student
`samples/006-guardrails/README.md`, then update `docs/cli-samples.md` and
`wiki/samples.md` through the repository's normal sample-learning workflow.

## Extension design

### API surface

`extensions/guardrails.ts` must import `ExtensionAPI` and
`isToolCallEventType` from `@earendil-works/pi-coding-agent` and export one
default extension factory. Use `isToolCallEventType()` to narrow the built-in
inputs instead of casts:

- `bash` input: `{ command: string; timeout?: number }`;
- `write` input: `{ path: string; content: string }`; and
- `edit` input: `{ path: string; edits: ... }`.

Register one `pi.on("tool_call", ...)` handler and one `guard` command. The
hook must return `undefined` to allow execution and
`{ block: true, reason: "..." }` to deny it. Do not mutate `event.input` in
this sample: argument rewriting is supported by Pi, but is a different lesson.

The reason is important. Pi converts a blocked invocation into an error tool
result and sends it back through the conversation, so the model can explain the
denial or select a safer next action. A notification is only supplementary UI;
it must not be the sole explanation.

### In-memory state and `/guard`

Keep one factory-local boolean named `enabled`, initially `true`. It is shared
by the command and tool hook and resets to `true` on restart or `/reload`; do
not persist it in settings or session entries.

Register `/guard` with the exact accepted arguments `on`, `off`, and `status`
and completion entries for those values:

- `/guard on` sets `enabled = true`;
- `/guard off` sets `enabled = false`;
- `/guard status` reports the current state without changing it; and
- missing or unknown arguments show usage and leave state unchanged.

The response should name both the state and its scope, for example,
`guardrails ON (this session)`. Use `ctx.ui.notify()` in the command handler;
slash commands are exercised from the TUI in this sample. The tool handler
must immediately return `undefined` while disabled, before inspecting a call.

### Protected-path policy (`write` and `edit`)

Protect these path components:

- any file component equal to `.env` or beginning with `.env.` (for example
  `.env.local`);
- a directory component equal to `node_modules`; and
- a directory component equal to `.git`.

The check must not be a raw substring check: `notes/node_modules-guide.md` and
`.gitignore` are allowed. Resolve the tool's path against `ctx.cwd`, normalize
`.` and `..`, split it into platform-native components, and compare components.
Use Node's `path` utilities so both `/` and Windows drive-rooted paths behave
consistently. Component comparisons should be case-insensitive for a
conservative cross-platform lesson.

Both relative and absolute spellings of the same protected target must reach
the same decision. At minimum, cover these cases in comments or small pure
helpers inside the extension:

| Input path | Decision | Reason |
| --- | --- | --- |
| `output/allowed.txt` | allow | no protected component |
| `.env` | block | protected environment file |
| `./.env.local` | block | protected environment file |
| `node_modules/demo.txt` | block | protected dependency directory |
| `src/../.git/config` | block | normalized path enters `.git` |
| `.gitignore` | allow | filename is not the `.git` directory |
| `notes/node_modules-guide.md` | allow | substring is not a component |

Path denial is unconditional while the guard is on. Do not offer a confirmation
dialog for it. Return a short actionable reason containing the requested path,
such as `Guardrails blocked write to protected path ".env"`. If `ctx.hasUI` is
true, also show a warning notification; guard the notification so print and
JSON runs stay UI-independent.

### Review-required shell policy (`bash`)

Keep shell inspection intentionally narrow. Recognize the common recursive
forced remove forms `rm -rf`, `rm -fr`, compact option variants containing
both `r` and `f`, and the corresponding `--recursive` plus `--force` form.
Avoid the overly broad `command.includes("rm -rf")`, but do not attempt to
write a complete shell parser.

When such a call is found and the guard is on:

- if `ctx.hasUI` is `true`, call `ctx.ui.confirm()` with a clear title, the
  exact command, and a question that defaults conceptually to denial; allow
  only when it resolves to `true`;
- if the learner declines or closes the dialog, return a block result whose
  reason says that the user denied the command; and
- if `ctx.hasUI` is `false`, do not call any UI method. Return a block result
  explaining that destructive commands are denied because confirmation is not
  available in `ctx.mode`.

Pi 0.80.6 reports `ctx.hasUI === true` in TUI and RPC modes and `false` in
print and JSON modes. Use `hasUI`, rather than guessing from environment
variables. Mention RPC only as an API mode whose client must answer UI requests;
the sample's hands-on confirmation exercise is the TUI.

### Intentionally unsupported cases

The README must be candid about the policy's limits:

- the path rules inspect only Pi's built-in `write` and `edit` calls; a shell
  command, custom tool, extension, or unrelated local process may write those
  paths by another route;
- the shell rule recognizes a teaching-sized set of command spellings and is
  not a shell grammar, command allowlist, or malware detector;
- lexical normalization does not resolve symlink targets or eliminate
  time-of-check/time-of-use races;
- `/guard off` bypasses this extension for the current in-memory instance; and
- an extension runs in Pi's process and is not operating-system isolation.

Do not expand the implementation into a general permission framework, shell
parser, filesystem sandbox, audit database, or policy configuration language.

## README teaching flow

The implemented README should use this sequence.

### 1. Explain capability selection versus call authorization

Start with a small comparison:

| Mechanism | Question answered |
| --- | --- |
| `--tools` / `setActiveTools()` from sample 004 | Can the model see and choose this tool? |
| `tool_call` handler in this sample | May this specific invocation run now? |

Explain that the hook runs after the model emits a valid tool call but before
the underlying tool executes.

### 2. Prepare and start interactively

All executable commands should be PowerShell first, with a bash equivalent for
shell preparation and multiline launch commands.

PowerShell:

```powershell
Set-Location samples/006-guardrails
. ./prepare.ps1
pi --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
```

Bash:

```bash
cd samples/006-guardrails
source ./prepare.sh
pi --model "azure-openai/$AZURE_PI_TEST_DEPLOYMENT"
```

No `-e` flag is needed: `prepare` sets `PI_CODING_AGENT_DIR` to this sample and
Pi discovers `extensions/guardrails.ts`. Tell the learner to use `/reload`
after editing the extension.

### 3. Exercise all three decisions

Use explicit prompts that request the named tool and exact path/command:

```text
Use the write tool to create output/allowed.txt containing "allowed".
Use the write tool to replace .env with TEST_VALUE=changed. Do not use bash.
Use bash to run exactly: rm -rf output/allowed.txt
```

The first succeeds. The second returns a protected-path error and must not
touch `.env`. The third opens a confirmation dialog; first decline it and
verify the file remains, then repeat and approve it to demonstrate that a gate
can allow a reviewed call. Because a model can react to a denied call, the
README should tell learners to inspect the actual tool result rather than
assuming the final prose alone proves which action ran.

Then demonstrate `/guard status`, `/guard off`, and `/guard on` with a harmless
blocked target created only for the lesson. Never recommend turning the guard
off before a real destructive command or a real credential-file modification.

### 4. Demonstrate fail-closed print mode

Recreate a disposable marker, then run a one-shot prompt with only `bash`
active and `--no-session`:

PowerShell:

```powershell
New-Item -ItemType Directory -Force output | Out-Null
Set-Content -Path output/keep-me.txt -Value 'keep'
pi --no-session --tools bash `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" `
  -p 'Use bash to run exactly: rm -rf output/keep-me.txt. Do not use another command.'
Test-Path output/keep-me.txt
```

Bash:

```bash
mkdir -p output
printf 'keep\n' > output/keep-me.txt
pi --no-session --tools bash \
  --model "azure-openai/$AZURE_PI_TEST_DEPLOYMENT" \
  -p 'Use bash to run exactly: rm -rf output/keep-me.txt. Do not use another command.'
test -f output/keep-me.txt && echo 'marker preserved'
```

The marker must remain. Explain that `-p` makes `ctx.mode` equal to `print` and
`ctx.hasUI` false, so the extension never waits for input and denies the
review-required call.

### 5. Observe blocked feedback with sample 003

Load sample 003's logger explicitly while retaining sample 006's auto-loaded
guard. In the TUI, enable logging and decline the removal:

PowerShell:

```powershell
pi -e ../003-wire-log-global/extensions/wire-log.ts `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
```

Bash:

```bash
pi -e ../003-wire-log-global/extensions/wire-log.ts \
  --model "azure-openai/$AZURE_PI_TEST_DEPLOYMENT"
```

Inside Pi, run `/wire-log on`, issue the destructive-command prompt, decline
it, and let the model finish its next turn. Inspect the latest `dump/` request
and locate the guard's reason in a `toolResult` entry. This proves that the
block is model-visible conversation feedback. Include both inspection idioms:

```powershell
Get-ChildItem -Recurse dump -Filter '*request.json' |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 2 |
  Select-String -Pattern 'Guardrails|denied|confirmation'
```

```bash
rg -n 'Guardrails|denied|confirmation' dump
```

Do not copy the wire logger into sample 006; loading it ad hoc reinforces the
difference between this sample's policy and sample 003's observability tool.

## Verification matrix

The implementer must run as much of this matrix as the configured Azure model
allows and record the observed result in the README or handoff. Tests that
change files must use only disposable sample-local targets.

| Case | Mode and setup | Expected evidence |
| --- | --- | --- |
| Auto-discovery | source `prepare`, start `pi`, run `/guard status` | reports ON without `-e` |
| Normal write | TUI, `write output/allowed.txt` | file exists with requested content |
| Protected `.env` write | TUI, force `write`, no bash | tool result contains reason; `.env` absent/unchanged |
| Protected `.env.local` spelling | TUI or print, `write ./.env.local` | normalized path is blocked |
| Protected dependency path | TUI or print, `write node_modules/guard-test.txt` | file does not exist |
| False-positive check | TUI, `write output/node_modules-guide.md` | write succeeds |
| Edit protection | create a disposable `.env.test` outside Pi, request `edit` | original content remains |
| Destructive command denied | TUI, request exact `rm -rf`, choose No | marker remains and reason says user denied it |
| Destructive command approved | TUI, repeat, choose Yes | command executes and disposable marker is removed |
| Print fail-closed | `-p --tools bash --no-session` | no prompt hangs; marker remains; reason mentions unavailable confirmation |
| Toggle scope | `/guard off`, harmless policy probe, `/guard on` | off bypasses; on resumes; restart resets ON |
| Model feedback | sample 003 logger enabled | next provider request contains error `toolResult` with block reason |
| Cross-platform path logic | test `./`, `..`, and absolute spellings | equivalent targets receive equivalent decisions |

Model-driven CLI prompts are integration checks, not perfectly deterministic
unit tests. Verification must confirm the requested tool actually appeared in
the transcript or wire log before treating file absence as proof of a block.
If the model refuses to call a dangerous tool, rephrase the prompt or inspect
the extension through an interactive run; do not claim success from refusal.

## Acceptance criteria

Sample 006 is complete only when all of the following are true:

- [ ] `samples/006-guardrails` contains a teacher-to-student README, one
      auto-discovered extension, and the four required shared symlinks.
- [ ] The extension loads on Pi 0.80.6 after sourcing either preparation
      script and does not require `-e`.
- [ ] It uses `isToolCallEventType` for typed `bash`, `write`, and `edit`
      inspection.
- [ ] Protected path matching is component-aware, normalizes relative and
      absolute inputs, and avoids the documented `.gitignore` and
      `node_modules-guide.md` false positives.
- [ ] Protected `write` and `edit` calls always return
      `{ block: true, reason }` while enabled and never open a dialog.
- [ ] Recognized recursive forced removal asks for confirmation when
      `ctx.hasUI` is true; denial blocks it and approval permits it.
- [ ] The same shell call fails closed without calling UI methods when
      `ctx.hasUI` is false, including a verified `-p` run.
- [ ] `/guard on|off|status` works, invalid input is non-destructive, state is
      session-local, and startup/reload defaults to ON.
- [ ] A normal `output/` write succeeds while the guard is enabled.
- [ ] A blocked result is observed as model-visible feedback, preferably with
      sample 003's wire log.
- [ ] Verification uses only disposable files and confirms actual tool calls,
      not just final model prose.
- [ ] The README clearly states that this extension is not a security boundary
      and documents the bash, custom-tool, symlink, and toggle bypasses.
- [ ] The sample catalog/course references are updated and `git diff --check`
      passes.

## Primary references for implementation

- Pi 0.80.6 local documentation:
  `@earendil-works/pi-coding-agent/docs/extensions.md`, especially Tool Events
  and `ExtensionContext`.
- Pi 0.80.6 local examples:
  `examples/extensions/protected-paths.ts` and
  `examples/extensions/permission-gate.ts`.
- [Sample 003 — auto-discovered wire log](../../samples/003-wire-log-global/README.md)
- [Sample 004 — extend and manage tools](../../samples/004-tools/README.md)

