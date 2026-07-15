# 016 — A small custom TUI extension

This lesson adds a compact activity dashboard to Pi 0.80.6. It is a
presentation exercise, not a replacement terminal application: the extension
does not change prompts, models, thinking levels, active tools, authorization,
or agent messages.

The extension is deliberately one file:

```text
extensions/activity-dashboard.ts
```

It teaches five small ideas together:

- `ctx.ui.setStatus()` replaces one keyed footer status in place;
- `ctx.ui.setWidget()` replaces one keyed widget in place;
- `/dashboard` and `Ctrl+Shift+D` share the same visibility state;
- `pi.appendEntry()` plus `pi.registerEntryRenderer()` records display-only
  checkpoint history safely;
- `dashboard_checkpoint` supplies compact and expanded `renderCall` and
  `renderResult` views.

## Prepare

PowerShell is the primary course shell. From the repository root:

```powershell
cd samples/016-custom-tui
. ./prepare.ps1
```

The bash equivalent is:

```bash
cd samples/016-custom-tui
source ./prepare.sh
```

Sourcing a preparation script changes `PI_CODING_AGENT_DIR` to this sample.
That is why Pi auto-discovers the sample-local
`extensions/activity-dashboard.ts`. The four configuration and preparation
links point to the shared files at `samples/`.

## Verify offline first

The deterministic verifier does not source `.env`, use Azure, contact a
provider, create a session, or ask a model to call the tool:

```powershell
pwsh ./samples/016-custom-tui/verify.ps1
```

It loads only this extension and runs Pi in RPC, print, and JSON modes. The RPC
part checks the command registration, startup UI requests, keyed replacement
and clearing, custom-entry persistence, the absence of a custom entry from
messages, tool activation, and clean shutdown. It also checks the exact shared
checkpoint operation by invoking `/dashboard checkpoint verify`; this proves
the command/tool contract without pretending that a model selected the tool.

The print-mode check runs `/dashboard checkpoint` without a label. Because
print and JSON modes have no UI, it must choose the deterministic `manual`
fallback, report that choice on stderr, and never wait for input or corrupt
stdout. JSON stdout is parsed as JSONL. Static checks supplement these real Pi
lifecycle checks for symlinks, registrations, renderers, and forbidden
network/process imports.

## Understand the state

The extension owns one session-scoped state object. `session_start` resets it;
checkpoint history is not used to restore dashboard visibility or live
lifecycle. The event flow is intentionally small:

| Event | Visible state change |
| --- | --- |
| `model_select` / `thinking_level_select` | refresh the model or thinking line |
| `agent_start` / `turn_start` | show agent-running or turn-running |
| `tool_execution_start` | add the tool-call ID and show tool-running |
| `tool_execution_end` | remove the ID and remember the completed tool |
| `turn_end` / `agent_settled` | show settling, then idle |

Tool IDs matter: two parallel calls keep the dashboard in `tool-running` until
both have ended. A duplicate or late end event is harmless. The extension does
not subscribe to token-level message or tool-update events, so repeated
`refresh()` calls replace the same two keyed UI elements instead of adding
transcript rows.

The widget has exactly four short lines. In TUI mode it is a `Text` component
factory colored with the supplied theme. In RPC mode it is the same plain
four-line snapshot as a string array: RPC has UI protocol support, but cannot
render a local component factory. JSON and print modes make no UI calls.

## Exercise the command and shortcut

After preparation, start Pi offline:

```powershell
pi --offline
```

Try these commands:

```text
/dashboard status
/dashboard off
/dashboard on
/dashboard toggle
/dashboard checkpoint review
/dashboard checkpoint
/hotkeys
```

The label-less checkpoint uses a TUI selection with `manual`, `review`, and
`done`. In RPC it is a client-mediated selection request with a five-second
timeout. With no UI it uses `manual` deterministically. Invalid commands and
extra arguments only produce a warning. Checkpoint failures are errors; other
successful command outcomes are informational.

Pi resolves shortcut conflicts after extensions load. `registerShortcut()` does
not report a success value, so the extension never claims that it detected a
conflict. Use `/hotkeys` and Pi's startup diagnostics as the authority. The
permanent fallback is `/dashboard toggle`.

## Entry versus message versus tool result

`appendEntry("dashboard-checkpoint", snapshot)` writes a custom entry to the
session JSONL. A registered entry renderer displays it in the transcript, but
custom entries are omitted from `buildContextEntries()` and LLM messages. The
renderer shows `[dashboard checkpoint] <label>` when collapsed and safe,
stable metadata when expanded. Malformed historic data becomes a warning line
instead of throwing.

`sendMessage()` is different: it creates a custom message that can enter LLM
context. That boundary belongs in sample 017 and is not used here.

The `dashboard_checkpoint` tool result is different again: it is a normal,
model-visible tool-result message. Its structured `details.checkpoint` and the
display-only entry share the same snapshot object. The tool does no filesystem,
process, credential, or network work. It validates and normalizes the label,
checks cancellation before appending, and returns the exact success text:

```text
Dashboard checkpoint recorded: <label>
```

Tool calls and results use Pi's default tool shell. Collapsed rendering stays
compact; expanded rendering adds only model, thinking, active-tool count,
lifecycle, latest completed tool, and ISO timestamp. Prompts, arguments,
result bodies, paths, API metadata, and secrets are never rendered.

## Manual visual checklist

The verifier cannot judge terminal pixels or synthesize keyboard input. In a
terminal at least 50 columns wide, work through this short exercise:

1. Confirm the footer status and four-line dashboard at startup. Resize
   narrower and confirm normal TUI wrapping.
2. Run `/hotkeys` and confirm `ctrl+shift+d` is listed, or use the documented
   `/dashboard toggle` fallback if Pi reports a conflict.
3. Toggle off with the shortcut and on with `/dashboard on`; both keyed
   elements should disappear and reappear together.
4. Run `/dashboard checkpoint`, choose `review`, and compare collapsed and
   expanded entry rendering.
5. Ask the model to call `dashboard_checkpoint` with `manual-check`; inspect
   its compact and expanded tool rendering and the in-place latest-tool line.
6. Change thinking level and, when configured, model; confirm both lines update
   without a dashboard transcript row.
7. Run `/reload`; confirm one fresh dashboard, no duplicate widget, and
   historic checkpoints still rendered as display-only entries.
8. Run `/quit`; confirm clean shutdown with no repaint or stale component.

Do not put secrets or sensitive prompts in screenshots. The model-dependent
step is an optional integration exercise, not an automated gate.

## Small experiments

Change one theme color or the widget placement and rerun the verifier. Keep the
state session-scoped and do not turn this lesson into a custom footer, editor,
animation, polling loop, RPC client, or authorization layer.

