# 016 — A small custom TUI extension

## Goal

Teach Pi 0.80.6's interactive presentation surface without turning the sample
into a terminal application. The extension adds one compact activity dashboard
and one deterministic checkpoint tool. It observes existing session state; it
does not change prompts, models, thinking levels, active tools, or authorization.

The finished sample must make five concepts visible:

1. a keyed footer status with `ctx.ui.setStatus()`;
2. a keyed widget updated in place with `ctx.ui.setWidget()`;
3. a slash command and an extension shortcut that operate the same state;
4. display-only session data through `pi.appendEntry()` and
   `pi.registerEntryRenderer()`;
5. compact and expanded custom tool rendering through `renderCall` and
   `renderResult`.

This is a UI lesson, not a state-management framework. Keep all implementation
in one extension file and keep the state session-scoped.

## Version and source assumptions

Design and verify against the installed `pi 0.80.6` distribution and imports
from `@earendil-works/pi-coding-agent`, `@earendil-works/pi-tui`, and `typebox`.
The brief uses these 0.80.6 facts:

- `ctx.mode` is `"tui" | "rpc" | "json" | "print"`.
- `ctx.hasUI` is true in TUI and RPC, false in JSON and print modes.
- RPC supports dialogs through request/response frames and supports string-array
  widgets as fire-and-forget requests. It cannot render component factories.
- `setStatus(key, undefined)` and `setWidget(key, undefined)` clear keyed UI.
- `registerShortcut()` returns `void`; conflict resolution happens later in Pi.
- custom entries persist in the session but are excluded from model context.
- defined tool renderers must return a TUI `Component`; omitted renderer slots
  get Pi's fallback renderer.

Do not silently generalize the sample to a different Pi package or version. If
the installed package changes, compare its extension types and examples before
updating this plan.

## Intended layout

```text
samples/016-custom-tui/
├── README.md
├── verify.ps1
├── models.json       -> ../models.json
├── settings.json     -> ../settings.json
├── prepare.ps1       -> ../prepare.ps1
├── prepare.sh        -> ../prepare.sh
└── extensions/
    └── activity-dashboard.ts
```

The four root files are symlinks to the shared sample configuration and
preparation scripts, following the repository convention. The sample needs no
`package.json`: Pi's extension loader supplies the installed SDK packages.

## Exact extension contract

`extensions/activity-dashboard.ts` exports one default factory:

```ts
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function activityDashboard(pi: ExtensionAPI): void {
  // registrations and session-scoped closure state
}
```

Use these stable identifiers so the verifier can make structural assertions:

| Purpose | Identifier |
|---|---|
| Footer status key | `sample-016-dashboard` |
| Widget key | `sample-016-dashboard` |
| Entry custom type | `dashboard-checkpoint` |
| Slash command | `dashboard` |
| Tool name | `dashboard_checkpoint` |
| Tool label | `Dashboard checkpoint` |
| Shortcut | `ctrl+shift+d` |

The TypeBox tool schema is exactly one required label:

```ts
Type.Object({
  label: Type.String({ minLength: 1, maxLength: 40 }),
})
```

Trim the label and reject an empty post-trim value as a model-visible error.
Normalize embedded whitespace to single spaces and cap the stored/rendered label
at 40 characters. The tool performs no filesystem, process, credential, or
network operation and ignores neither cancellation nor errors: if its incoming
`AbortSignal` is already aborted, return an error result and append no entry.

`execute()` returns an `AgentToolResult<CheckpointDetails>`:

```ts
interface CheckpointDetails {
  checkpoint: CheckpointData;
}

interface CheckpointData {
  label: string;
  model: string;
  thinkingLevel: string;
  activeToolCount: number;
  lifecycle: DashboardLifecycle;
  latestCompletedTool: string;
  createdAt: string; // ISO-8601
}
```

Successful text is exactly `Dashboard checkpoint recorded: <label>`. The
structured `details.checkpoint` and the appended custom entry contain the same
snapshot object. An error has `isError: true`, one text content item, and no
entry. A successful tool result is deliberately model-visible; that is the
only path by which dashboard snapshot data enters model context.

## Session state and invariants

Keep one closure-owned `DashboardState`:

```ts
type DashboardLifecycle =
  | "idle"
  | "agent-running"
  | "turn-running"
  | "tool-running"
  | "settling";

interface DashboardState {
  visible: boolean;
  model: string;
  thinkingLevel: string;
  activeToolCount: number;
  lifecycle: DashboardLifecycle;
  latestCompletedTool: string;
  runningToolIds: Set<string>;
  turnIndex?: number;
}
```

Initialize a fresh state at every `session_start`: visible, model from
`ctx.model` (format `<provider>/<id>`, or `none`), thinking from
`pi.getThinkingLevel()`, active capability count from
`pi.getActiveTools().length`, lifecycle `idle`, latest completed tool `none`,
and an empty running-tool set. Do not restore dashboard visibility or live
lifecycle from custom entries. Checkpoint entries are history, not dashboard
configuration.

All rendering goes through two helpers:

- `snapshot(ctx)` refreshes model, thinking level, and active-tool count before
  creating immutable `CheckpointData`.
- `refresh(ctx)` updates or clears the same status/widget keys. It never appends
  a transcript entry.

Calling `refresh()` repeatedly with the same key is the central lesson: state
changes replace the footer/widget instead of generating transcript spam.

## Event-to-state contract

Register only the events that directly support the dashboard:

| Event | State transition | UI consequence |
|---|---|---|
| `session_start` | reset the complete state described above | render initial dashboard |
| `model_select` | use `event.model.provider/event.model.id` | refresh model line |
| `thinking_level_select` | use `event.level` | refresh thinking line |
| `agent_start` | lifecycle `agent-running` | refresh |
| `turn_start` | save `event.turnIndex`; lifecycle `turn-running` | refresh |
| `tool_execution_start` | add `toolCallId`; lifecycle `tool-running` | refresh |
| `tool_execution_end` | remove `toolCallId`; set latest to tool name plus ` (error)` when `isError`; lifecycle remains `tool-running` while another ID is pending, otherwise `turn-running` | refresh |
| `turn_end` | clear turn index; lifecycle `settling` | refresh |
| `agent_settled` | clear running IDs; lifecycle `idle` | refresh |
| `session_shutdown` | clear running IDs and both UI keys | no stale component |

Parallel tool calls are why state tracks IDs rather than one Boolean. A late or
duplicate end event must be harmless. Do not subscribe to `message_update` or
`tool_execution_update`; token-level refreshes add churn without teaching a new
concept. `agent_end` is also unnecessary because `turn_end` and
`agent_settled` provide the two useful presentation states.

When the dashboard is hidden, state continues to update so showing it again is
immediately accurate. `session_shutdown` cleanup is explicit even though Pi
also owns cleanup of extension UI on runtime replacement.

## Widget and footer presentation

The status is one short themed string, for example:

```text
dashboard · idle · tools 8
```

Use `theme.fg("accent", ...)` for a running marker and
`theme.fg("dim", ...)` while idle. The widget shows exactly four short lines:

```text
Activity dashboard
model: azure-openai/chat
thinking: low · tools: 8
state: idle · last: read
```

Do not include cwd, absolute paths, prompts, arguments, tool results, API
metadata, token contents, or session file names. Sanitize dynamic fields by
removing control characters before rendering. Keep each label fixed and let
the TUI `Text` component wrap naturally; do not truncate using terminal escape
sequences or assume a width.

In TUI mode, `setWidget()` uses a component factory returning a `Text` component
whose content is colored with the supplied theme. In RPC mode, use the same
plain four-line snapshot as a string array because RPC ignores component
factories. This intentional branch teaches the difference between a local TUI
component and a client-rendered RPC widget. JSON and print modes never call
either UI setter.

Turning the dashboard off clears both keys with `undefined`; turning it on
reuses the current state. Do not replace Pi's editor, footer, header, working
indicator, or tool-expansion setting.

## `/dashboard` command

Register one command with the description `Show, hide, inspect, or checkpoint
the activity dashboard`. Parse trimmed whitespace and support:

| Invocation | Behavior |
|---|---|
| `/dashboard` or `/dashboard status` | report visible/hidden plus the same safe one-line snapshot |
| `/dashboard on` | set visible and refresh |
| `/dashboard off` | clear both keyed UI elements |
| `/dashboard toggle` | toggle using the same helper as the shortcut |
| `/dashboard checkpoint <label>` | record a checkpoint through the shared checkpoint helper |
| `/dashboard checkpoint` | TUI: select `manual`, `review`, or `done`; RPC: emit the same selection request with a five-second timeout; JSON/print: deterministically use `manual` |

Unknown subcommands and extra arguments return a concise usage diagnostic and
must not mutate state. Notifications are `info` for status/success, `warning`
for invalid use, and `error` only for a failed checkpoint.

In TUI and RPC, report command outcomes with `ctx.ui.notify()`. RPC clients may
render or ignore the resulting fire-and-forget request. In JSON and print mode,
write the same concise diagnostic to stderr, never stdout; structured JSON stdout
must remain parseable. A headless command must never call a dialog and must
never wait for input.

The command's checkpoint path exists so the deterministic verifier can exercise
entry persistence without asking a model to choose the tool. It must call the
same validation, snapshot, and append helper as `dashboard_checkpoint`; do not
duplicate a second checkpoint implementation. The README must be candid that
this proves the shared contract, while a model-driven tool call remains an
optional integration exercise.

## Shortcut behavior and conflicts

Register `ctrl+shift+d` with description `Toggle activity dashboard`; its
handler invokes exactly the command's toggle helper. The shortcut is intended
for TUI use, but registration itself is mode-independent.

Pi 0.80.6 does not expose a pre-registration conflict query and
`registerShortcut()` returns no success value. Pi resolves shortcuts after
loading resources:

- some reserved built-in conflicts are skipped;
- overridable built-in conflicts produce a diagnostic and use the extension;
- duplicate extension shortcuts produce a diagnostic and the later extension
  wins.

Therefore the extension must not claim it detected successful registration.
`ctrl+shift+d` is unassigned in the shipped 0.80.6 defaults, `/hotkeys` is the
manual authority for the effective binding, and Pi's startup diagnostics expose
a conflict. `/dashboard toggle` is the permanent documented fallback.

## Checkpoint entry renderer

Register `dashboard-checkpoint` before any checkpoint can be appended. The
renderer signature is:

```ts
pi.registerEntryRenderer<CheckpointData>(
  "dashboard-checkpoint",
  (entry, { expanded }, theme) => Component | undefined,
);
```

Return a `Text` component. The collapsed form is one line:

```text
[dashboard checkpoint] review
```

The expanded form adds safe, stable fields on separate lines: model, thinking,
active tool count, lifecycle, latest completed tool, and ISO timestamp. It does
not render raw JSON, paths, prompts, tool arguments, or result bodies. Treat
malformed historic entry data defensively: render `[dashboard checkpoint]
invalid entry` instead of throwing. Use theme `accent` for the label, `success`
for a valid marker, `warning` for invalid data, and `dim` for expanded metadata.

The README must contrast the APIs precisely:

- `appendEntry` creates a `CustomEntry` in session JSONL and is omitted from
  `buildContextEntries()`/LLM messages;
- `sendMessage` creates a custom message that can enter LLM context and belongs
  in sample 017;
- a tool result is a normal model-visible tool-result message even when the
  tool also appends a display-only entry.

## Tool renderers

Use Pi's default tool shell. Both renderers return `Text` components with zero
padding.

`renderCall(args, theme, context)` shows the tool title and sanitized label. It
may reuse `context.lastComponent` when it is a `Text`, update it with `setText`,
and return it. It must not assume arguments are complete while streaming.

`renderResult(result, { expanded, isPartial }, theme, context)` handles four
states:

1. partial: `recording checkpoint…` in warning/dim color;
2. error: the first safe text content item in error color;
3. collapsed success: `✓ checkpoint recorded: <label>`;
4. expanded success: the collapsed line plus model, thinking, tool count,
   lifecycle, latest completed tool, and timestamp from validated details.

If details are absent or malformed, render the successful text fallback and do
not throw. Read arguments from `context.args`; no cross-render state is needed.
Do not use `renderShell: "self"`, animation, background invalidation, or raw
ANSI strings.

## Mode contract

| Mode | `hasUI` | Dashboard behavior | Dialog behavior |
|---|---:|---|---|
| TUI | true | themed component widget and footer | local selection dialog |
| RPC | true | string-array `setWidget` and `setStatus` UI requests | client-mediated request/response with five-second timeout |
| JSON | false | no UI calls; command/tool/entry contracts still work | deterministic `manual` fallback |
| Print | false | no UI calls; command/tool/entry contracts still work | deterministic `manual` fallback |

Do not treat `hasUI` as synonymous with a local terminal: it is true in RPC.
Use `ctx.mode === "tui"` for component factories. Fire-and-forget RPC UI
requests do not prove a client displayed anything. A real RPC host is free to
ignore them.

No code path may wait indefinitely. The optional selection has a five-second
timeout in RPC and uses no dialog at all when `hasUI` is false. Session startup
contains no dialog.

## Automated verification design

`verify.ps1` is model-free, offline, and independent of `.env`. It prints
versions for `pwsh` and `pi`, saves/restores `PI_CODING_AGENT_DIR` and
`PI_OFFLINE`, and always runs Pi with:

```text
--no-extensions -e ./extensions/activity-dashboard.ts
--no-builtin-tools --tools dashboard_checkpoint
--offline --no-session
```

Use `System.Diagnostics.Process` with redirected stdin/stdout/stderr and an
explicit timeout/kill path. Do not use synthetic TUI keystrokes or judge colored
terminal screenshots.

### RPC structural run

Start `pi --mode rpc`, then send correlated requests in this order:

1. `get_commands`;
2. prompt `/dashboard status`;
3. prompt `/dashboard off`;
4. prompt `/dashboard on`;
5. prompt `/dashboard checkpoint verify`;
6. `get_entries`;
7. `get_messages`;
8. close stdin and require clean exit.

Parse every non-empty stdout line as JSON and assert:

- exactly one extension command named `dashboard` exists and its
  `sourceInfo.path` resolves to the expected extension file;
- startup emits `setStatus` and a four-line string-array `setWidget` request
  using the exact key;
- off emits clear requests for both exact keys, and on emits replacements;
- each prompt command has a successful correlated response and emits no
  provider, agent, turn, message, or tool-execution event;
- status emits a concise `notify` request rather than raw stdout;
- checkpoint emits a success notification and `get_entries` returns exactly
  one `type: "custom"`, `customType: "dashboard-checkpoint"` entry with label
  `verify`, a non-negative integer tool count, allowed lifecycle, sanitized
  fields, and a parseable ISO timestamp;
- `get_messages` is empty, proving the command-appended custom entry did not
  become model context;
- shutdown emits clear requests for both keys and the process exits zero;
- stderr contains no extension load error or unhandled rejection.

The RPC checkpoint exercises the exact shared operation used by the registered
tool; it does not pretend that a model invoked the tool.

### Tool registration check

Because RPC 0.80.6 has no direct `get_tools` or `call_tool` request, make the
registered command's status notification include `checkpoint-tool: active` or
`checkpoint-tool: inactive`, derived from
`pi.getActiveTools().includes("dashboard_checkpoint")`. With the explicit tool
allowlist above, assert it reports active. This proves Pi loaded and activated
the tool without requiring a provider call. The verifier must not infer tool
registration merely by grepping source code.

An optional, separately documented `verify-model.ps1` would be justified only
if the course wants to prove an actual LLM-chosen `dashboard_checkpoint` call.
It is not required for this UI sample and must not weaken or replace the offline
structural verifier.

### Headless non-blocking run

Run print mode with `/dashboard checkpoint` and no credentials. Require exit
zero within a short timeout, no stdout corruption, a stderr diagnostic naming
the deterministic `manual` fallback, and no provider error. This proves the
label-less command did not open a dialog or contact a model.

Run JSON mode with `/dashboard status`, parse all stdout as JSONL, and require
clean exit with no `extension_ui_request`, provider, agent, turn, message, or
tool event. This catches accidental `hasUI` assumptions and stdout logging.

### Static contract checks

Keep these few source checks because renderers cannot be exercised through
headless RPC without manufacturing a TUI:

- the four required symlinks resolve to the shared files;
- the extension contains registrations for the exact command, shortcut, entry
  type, and tool name;
- `renderCall` and `renderResult` are present;
- no network or child-process import appears.

Static checks supplement the real Pi lifecycle; they are not the primary
verification.

## Manual TUI checklist

After `. ./prepare.ps1`, start `pi --offline` in a terminal at least 50 columns
wide and perform this short visual exercise:

1. Confirm one footer status and one four-line dashboard appear at startup;
   resize narrower and confirm content wraps without corrupting the editor.
2. Run `/hotkeys`; confirm `ctrl+shift+d` is listed as `Toggle activity
   dashboard`, or record Pi's conflict diagnostic and use `/dashboard toggle`.
3. Toggle off with the shortcut and on with the command; both the widget and
   footer must disappear/reappear together.
4. Run `/dashboard checkpoint`, choose `review`, and confirm one custom entry
   appears. Toggle tool expansion and compare its collapsed/expanded content.
5. Ask the model to call `dashboard_checkpoint` with label `manual-check`.
   Confirm the tool call/result have concise collapsed rendering and safe
   expanded metadata; confirm the latest-tool line updates in place.
6. Switch thinking level and, when two configured models are available, switch
   model. Confirm both lines update without a new dashboard transcript row.
7. Run `/reload`; confirm there is one fresh dashboard, no duplicate widget,
   and the historic checkpoint entries remain display-only.
8. Run `/quit`; confirm there is no repaint, error, or stale component during
   shutdown.

The model-dependent steps are observational exercises, not automated gates.
Never paste secrets or sensitive prompts into screenshots.

## Edge cases

- No selected model: render `model: none`; never use a non-null assertion.
- Model/provider identifiers or labels contain control characters: strip them
  before status, widget, entry, tool result, or renderer output.
- Empty/whitespace/overlong label: reject or normalize according to the shared
  validator; never append a partial entry.
- Multiple concurrent tools: keep `tool-running` until the ID set is empty;
  completion order determines `latestCompletedTool`.
- Tool failure: include ` (error)` in the latest field but remain operational.
- Dashboard hidden during events: update state only; showing later renders the
  latest snapshot.
- Duplicate or unknown tool-end ID: deleting from the set is idempotent.
- Reload/session replacement: old shutdown clears UI, new `session_start`
  creates a fresh closure state, old captured contexts are never reused.
- Invalid historic custom entry: renderer returns a warning component instead
  of throwing.
- RPC host ignores UI requests: agent operation still completes; dashboard
  presentation is the client's responsibility.
- RPC client does not answer label selection: the timeout resolves and the
  command records no entry unless a valid choice exists.
- Shortcut conflict: Pi reports/resolves it; slash command stays usable.
- ANSI or wide Unicode fields: sanitized plain content remains safe, while TUI
  owns width-aware wrapping.
- Print/JSON invocation: stderr may carry a diagnostic, stdout remains valid for
  its mode, and no dialog is requested.

## README teaching sequence

The runnable README should use a teacher-to-student progression:

1. show the compact dashboard and explain keyed replacement;
2. read the event table and predict state changes;
3. run the offline verifier and interpret RPC UI requests as protocol, not
   screenshots;
4. perform the manual TUI checklist;
5. inspect the entry and tool result boundary;
6. experiment by changing placement or one theme color, not by adding a custom
   footer/editor.

State explicitly that sourcing `prepare.ps1`/`prepare.sh` changes
`PI_CODING_AGENT_DIR`, so Pi auto-discovers the sample-local
`extensions/activity-dashboard.ts`.

## Non-goals

- Replacing Pi's editor, header, footer, or full transcript.
- Pixel-perfect or cross-terminal screenshot testing.
- Synthetic keyboard input in automation.
- Animation, timers other than the bounded dialog timeout, polling, or network
  metrics.
- Persisting dashboard visibility or live lifecycle state.
- Showing prompts, arguments, output bodies, paths, session files, or secrets.
- Changing models, thinking levels, tool activation, or agent messages.
- Combining UI state with guardrail authorization.
- Building a general renderer test harness or RPC UI client.

## Acceptance criteria

- The sample has the exact file layout and four shared symlinks.
- Pi 0.80.6 loads the one extension successfully in TUI, RPC, JSON, and print
  modes.
- One keyed footer and one keyed widget reflect the specified event state and
  update without transcript spam.
- `/dashboard` implements every documented subcommand and shares helpers with
  the shortcut and checkpoint tool.
- `ctrl+shift+d` appears in `/hotkeys` when conflict-free, and the README
  accurately explains Pi-managed conflicts and the command fallback.
- `dashboard_checkpoint` has the exact schema, deterministic side effects,
  structured result, cancellation behavior, and collapsed/expanded renderers.
- `dashboard-checkpoint` entries render safely, survive reload when sessions are
  enabled, and are absent from model messages/context.
- TUI and RPC use their correct widget forms; JSON and print make no UI request
  and never block.
- Shutdown and reload clear both keyed UI elements and leave no duplicate or
  stale component.
- `verify.ps1` passes from outside the sample directory without `.env`, network,
  credentials, a model response, or synthetic keystrokes.
- Every item in the manual visual checklist has been exercised before the
  sample is considered complete.

## References

- Installed Pi 0.80.6 `docs/extensions.md`, especially ExtensionContext,
  custom rendering, custom UI, and custom entry sections.
- Installed Pi 0.80.6 `docs/tui.md` and `docs/keybindings.md`.
- Installed Pi 0.80.6 `docs/rpc.md`, Extension UI Protocol.
- Installed examples `status-line.ts`, `widget-placement.ts`,
  `entry-renderer.ts`, and `rpc-demo.ts`.
- [Pi extension custom UI](https://pi.dev/docs/latest/extensions#custom-ui)
- [Pi TUI components](https://pi.dev/docs/latest/tui)
