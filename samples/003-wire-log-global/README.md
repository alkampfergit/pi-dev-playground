# 003 — Wire Log, auto-discovered (no `-e` flag)

Sample [002](../002-wire-log/README.md) loaded the wire-log extension **by hand**
with `pi --extension ./wire-log.ts`: it was active for exactly one run and
always dumping. That is perfect for a one-off look, but you have to remember the
flag every time, and it is always on.

This sample takes that same extension and lets pi **discover it automatically**.
The file lives in this sample's [`extensions/`](./extensions/) folder, so every
`pi` session you start here loads it with no flag. Because an always-loaded
logger would litter the project and slow every turn, it now defaults to **OFF**
and exposes a `/wire-log` command that turns it on and off **without restarting
pi**.

All commands below assume your current directory is:

```text
samples/003-wire-log-global
```

## Where pi looks for extensions — and the trap I hit

pi auto-discovers extensions from a fixed location relative to its **config
directory**:

| Location | Scope |
| --- | --- |
| `<config-dir>/extensions/*.ts` | loaded for every session using that config dir |
| `.pi/extensions/*.ts` | project-local (loaded after the project is trusted) |

The config directory defaults to `~/.pi/agent`, so the documented "global"
extension path is `~/.pi/agent/extensions/`. **But `PI_CODING_AGENT_DIR`
overrides the whole config directory** (see `pi` docs: *"Override config
directory; default is `~/.pi/agent`"*).

Every sample in this course sets `PI_CODING_AGENT_DIR` to its own folder — that
is exactly how `prepare.sh` / `prepare.ps1` make pi pick up the sample's
`models.json`, and where `bin/`, `sessions/`, and `dump/` get created. That same
override moves the extension search path:

```text
PI_CODING_AGENT_DIR = samples/003-wire-log-global
        ↓
config dir          = samples/003-wire-log-global
extensions found in = samples/003-wire-log-global/extensions/    ← not ~/.pi/agent/extensions/
```

So if you copy the extension into `~/.pi/agent/extensions/` and then
`source ./prepare.sh` before starting pi, **pi never loads it** — it is looking
in `<sample>/extensions/` instead. (That is the bug we ran into with the old
install script: the file was in `~/.pi/agent/extensions/`, but the sourced
`prepare` script had already repointed the config dir at the sample.) I verified
this with a probe extension that writes a file on `session_start`: with `prepare`
sourced, only the copy under `<sample>/extensions/` fired.

The fix is simply to put the extension where pi will actually look: this
sample's own `extensions/` folder. No install step, no `-e` flag.

> **Want it truly machine-wide (every project, not just this sample)?** Put it
> in `~/.pi/agent/extensions/` **and start pi with the default config dir** —
> i.e. do *not* source a `prepare` script that sets `PI_CODING_AGENT_DIR`. The
> two ideas don't mix: a per-sample config dir and a machine-wide extensions
> folder are mutually exclusive, because "global extensions" always resolve
> relative to whatever config dir is active.

## How the runtime toggle works

The whole design rests on **one in-memory flag** that the command handler and
the event hooks all close over:

```ts
let enabled = !!process.env.PI_WIRE_LOG;   // startup gate, still flippable

pi.registerCommand("wire-log", {
  handler: async (args, ctx) => {
    const cmd = args.trim().toLowerCase();
    if (cmd === "on") enabled = true;
    else if (cmd === "off") enabled = false;
    else if (cmd === "") enabled = !enabled; // bare /wire-log toggles
    ctx.ui.notify(`wire-log ${enabled ? "ON" : "OFF"}`, enabled ? "success" : "info");
  },
});

pi.on("before_provider_request", (event, ctx) => {
  if (!enabled) return;                      // hooks read the same variable
  write("request", event.payload ?? event, ctx);
});
```

Because the handler and the hooks share the `enabled` closure, a toggle takes
effect on the **very next provider request** — no `/reload` needed. Two details
that matter now that the extension loads on its own:

- **Seeded from the env var, but not gated by it.** `PI_WIRE_LOG=1 pi ...` still
  starts with logging on (handy for `-p` print-mode runs where there is no UI to
  type a command). Everywhere else it starts off.
- **Inert while off.** The `dump/` folder is created lazily inside the write
  path, so an idle extension never leaves a folder behind.

The flag is **per-session and ephemeral**: it resets to the `PI_WIRE_LOG`
default on every `/reload` or restart, which is exactly what you want for a debug
switch.

`getArgumentCompletions` gives you Tab-completion for `on` / `off` / `status`.
`/wire-log` is safe to register — built-in commands always take precedence over
extension commands, and if two extensions ever claim the same name pi keeps both
and adds numeric suffixes (`/wire-log:1`, `/wire-log:2`).

## Run it

Load the environment (which also sets `PI_CODING_AGENT_DIR` to this sample, so
pi finds both `models.json` and `extensions/wire-log.ts`), then start pi.

PowerShell:

```powershell
. ./prepare.ps1
pi
```

Bash:

```bash
source ./prepare.sh
pi
```

No `--extension` flag: the extension is discovered automatically. Confirm it
loaded by typing `/wire-log status` — you should see the current state in a
toast. If you edit `extensions/wire-log.ts`, run `/reload` to pick up the change
without restarting.

Then, inside the session:

```text
/wire-log on        # start capturing to dump/
/wire-log off       # stop
/wire-log           # toggle (bare command)
/wire-log status    # just report the current state
```

Turn it on, ask Pi to do something, and inspect the newest session folder under
`dump/` — one JSON file per event, request `N` and response `N` sharing the same
`NNNN` index (same layout as sample 002; see
[002's README](../002-wire-log/README.md) for how to read them). Watch it fill
live from another terminal with:

```bash
ls -lt dump/*/           # newest files first
```

For a single print-mode capture with no UI, use the env-var seed instead of the
command:

```bash
PI_WIRE_LOG=1 pi --model "azure-openai/$AZURE_PI_TEST_DEPLOYMENT" \
  --tools write,read \
  -p 'Write a two-line haiku about the sea and save it to haiku.md.'
```

## Notes

- `dump/`, `bin/`, `sessions/`, and `auth.json` are git-ignored; the payloads
  contain your prompts and file contents, so treat them as a log. The
  `extensions/` folder **is** tracked — that is the sample.
- `notify` writes to the footer/toast area, not stderr. In the interactive TUI
  `console.error` fights with the screen rendering, so the toggle reports its
  state through `ctx.ui.notify` instead.
- Opening `wire-log.ts` in an editor may show "Cannot find module" and implicit
  `any` warnings. That is expected: this folder has no `node_modules` or
  `tsconfig.json`, and pi transpiles the extension itself at load time via jiti.

## References

- [Pi extensions documentation](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)
- [Extension locations](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md#extension-locations)
- [`PI_CODING_AGENT_DIR` and other environment variables](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/usage.md#environment-variables)
- [Sample 002 — Wire Log](../002-wire-log/README.md)
