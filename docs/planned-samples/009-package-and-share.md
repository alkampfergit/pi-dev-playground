# 009 — Package and share: bundle an extension and a skill

## Goal

Create a small, installable Pi package from lessons already learned. This is a
capstone for reusable distribution, not a new extension framework: the learner
will package a simplified version of sample 003's wire logger and sample 005's
haiku skill, install that package into an isolated Pi configuration, prove that
both resources are discovered, then remove it cleanly.

The sample must make one important distinction visible: a local-path install
does **not** copy the package. Pi records a reference to the existing directory
in `settings.json`, and loads resources from that directory using the package
manifest. Editing the source package therefore changes what a later Pi process
loads.

## What the learner should obtain

- An understanding that extensions, skills, prompt templates, and themes can be
  bundled as a Pi package instead of copied between configuration folders.
- A concrete `package.json` containing the `pi` manifest and the
  `pi-package` keyword.
- A deliberately small local package containing one useful extension command
  and one skill, based on concepts already taught in samples 003 and 005.
- The ability to install from an absolute local path, inspect the resulting
  settings entry with `pi list`, and remove the same source again.
- A repeatable way to inspect resource discovery without invoking a model: use
  RPC mode's `get_commands` request and assert the command inventory.
- A clear security habit: installing into a temporary configuration protects
  the learner's normal Pi settings, but it does not sandbox package code.

## Learning sequence

1. Inspect the package directory and its manifest before running it.
2. Point `PI_CODING_AGENT_DIR` at a new temporary directory.
3. Install the package by absolute path and inspect the generated
   `settings.json` and `pi list` output.
4. Start Pi in RPC mode, request `get_commands`, and prove that `/wire-log` and
   `/skill:haiku` came from the package.
5. Remove the same absolute path, list packages again, and start a fresh RPC
   process to prove that both resources disappeared.
6. Restore the caller's environment and delete only the temporary verification
   directory, even when an assertion fails.

This order separates three ideas that are easy to conflate: package
registration in settings, resource discovery at Pi startup, and removal from
settings.

## Exact sample layout

Create the following files under `samples/009-package-and-share/`:

```text
009-package-and-share/
├── README.md
├── verify.ps1
├── models.json -> ../models.json
├── settings.json -> ../settings.json
├── prepare.ps1 -> ../prepare.ps1
├── prepare.sh -> ../prepare.sh
└── package/
    ├── package.json
    ├── extensions/
    │   └── wire-log.ts
    └── skills/
        └── haiku/
            └── SKILL.md
```

The four symlinks are present because every course sample has the same normal
preparation workflow. `verify.ps1`, however, must temporarily replace
`PI_CODING_AGENT_DIR` with its own scratch directory; it must never install into
the linked course `settings.json` or the user's default `~/.pi/agent` settings.

Keep `package/` as a visibly separate package root. The outer sample README and
verification script teach the exercise; only the contents of `package/` are
the distributable unit.

## Package manifest

Use this manifest in `package/package.json`:

```json
{
  "name": "pi-course-observability-kit",
  "version": "0.1.0",
  "private": true,
  "description": "A local Pi course package with wire logging and a haiku skill.",
  "keywords": ["pi-package"],
  "license": "MIT",
  "peerDependencies": {
    "@earendil-works/pi-coding-agent": "*"
  },
  "pi": {
    "extensions": ["./extensions/wire-log.ts"],
    "skills": ["./skills/haiku"]
  }
}
```

Why each non-obvious field is present:

- `keywords: ["pi-package"]` is the documented discoverability marker.
- `private: true` makes the sample's local-only intent explicit and prevents an
  accidental npm publication. Publishing is not part of this lesson.
- The explicit `pi` manifest teaches the portable package contract even though
  these conventional directory names could also be auto-discovered.
- Manifest paths are relative to `package/`, and arrays can later be expanded
  with more entries or glob patterns.
- Pi supplies its core packages to extensions. Since the extension imports the
  `ExtensionAPI` type, declare `@earendil-works/pi-coding-agent` as a `"*"`
  peer dependency and do not bundle it.

Do not add install scripts, runtime dependencies, prompt templates, themes, or
bundled packages. Those features belong in later exercises. The README may
show the full four-resource manifest shape as a reference, but the runnable
package should declare only the two resources it actually contains.

## Packaged resources

### `extensions/wire-log.ts`

Reuse the focused behavior from sample 003 rather than inventing another
extension API lesson:

- Register `/wire-log` with `on`, `off`, and `status` arguments; a bare command
  toggles the state.
- Default to off unless `PI_WIRE_LOG` is set.
- Listen to `before_provider_request` and `after_provider_response` only while
  enabled.
- Create its output directory lazily and guard UI calls so loading is safe in
  RPC and print modes.
- Write under `PI_CODING_AGENT_DIR/dump` so the verification run cannot write
  into the source package or the user's normal config directory.

The implementation may be copied and lightly renamed from sample 003, but the
sample README must say that packaging changes the distribution mechanism, not
the extension's runtime design. The extension must not perform any write merely
because Pi loads it; the deterministic verifier only checks discovery.

### `skills/haiku/SKILL.md`

Reuse the minimal three-line haiku procedure from sample 005, but remove its
sample-specific greeting dependency. The package skill must stand on its own:

- frontmatter name: `haiku`;
- a precise description that makes the activation condition clear;
- exactly three poetic lines when applied;
- no title, explanation, or Markdown decoration.

Pi exposes the discovered skill as `/skill:haiku`. The verifier must assert
that command name; it does not need to call a model to judge generated poetry.

## README requirements

Write `samples/009-package-and-share/README.md` in a teacher-to-student tone and
cover all of the following:

- Explain package root versus sample root.
- Walk through `package.json` before giving the install command.
- State that local paths are referenced in place, not copied.
- Give the normal preparation commands for consistency, but warn that manually
  running `pi install` after preparation would modify this sample's linked
  shared settings. Recommend `./verify.ps1` for the safe exercise.
- Show the equivalent manual flow using a deliberately created temporary
  `PI_CODING_AGENT_DIR`, an absolute package path, and a `try/finally` cleanup.
- Explain why a new Pi process is required after install and after remove:
  resource discovery happens at startup.
- Describe `get_commands` as the model-free assertion mechanism and distinguish
  it from invoking the skill.
- Mention npm and Git sources only as follow-on possibilities. Do not provide a
  publishing workflow.
- Include a trust checklist and the limitations of configuration isolation.

## PowerShell verification design

Implement `verify.ps1` as the canonical automated proof. It must work when run
from any current directory and must not require Azure credentials, a model
response, network access, or interactive input.

### Setup and isolation

1. Enable strict failure behavior (`Set-StrictMode -Version Latest` and
   `$ErrorActionPreference = "Stop"`).
2. Resolve the sample directory from `$PSScriptRoot`, then resolve
   `package/` to one absolute canonical path. Use that exact string for both
   `install` and `remove`.
3. Check that `pi` exists and print the detected `pi --version`. The design was
   validated against Pi 0.80.6; fail clearly if the CLI is unavailable.
4. Save whether `PI_CODING_AGENT_DIR` and `PI_OFFLINE` existed and their prior
   values, so absence can be restored as absence rather than as an empty value.
5. Allocate a uniquely named directory below
   `[System.IO.Path]::GetTempPath()` (include the process ID and a GUID), create
   an `agent/` config directory and a separate empty `work/` directory, and
   place a sentinel file in the temporary root.
6. Set `PI_CODING_AGENT_DIR` to the temporary `agent/` directory and
   `PI_OFFLINE=1`, then `Push-Location` into `work/`. Running from the empty
   directory prevents unrelated ancestor project skills or `.pi` resources
   from polluting the command inventory.

Use user-scope package commands inside this deliberately disposable config:

```powershell
pi install $packagePath --no-approve
pi list --no-approve
pi remove $packagePath --no-approve
```

Do not use `-l`: that flag targets `.pi/settings.json` relative to the working
project and introduces project trust. Here, "user scope" means the temporary
directory selected by `PI_CODING_AGENT_DIR`, not the learner's real home
configuration.

### Process and exit-code handling

Wrap every Pi invocation in a helper that captures stdout/stderr and checks
`$LASTEXITCODE` immediately. A failed command must throw with the command name,
exit code, and captured output. Do not let a successful later command overwrite
the exit code from the command being asserted.

Expected install evidence:

- `pi install` exits zero and reports `Installed <absolute-path>`.
- `<temp>/agent/settings.json` exists.
- Its parsed `packages` array contains the absolute package source.
- `pi list` exits zero, contains a `User packages:` section and the exact
  package path, and does not classify it as a project package.
- No copy is expected below `agent/npm/` or `agent/git/`; local packages remain
  at their source path.

### Model-free resource discovery assertion

Start a fresh Pi process and send one newline-terminated RPC request on stdin:

```json
{"id":"sample-009-commands","type":"get_commands"}
```

Conceptually, the PowerShell pipeline is:

```powershell
$request = '{"id":"sample-009-commands","type":"get_commands"}'
$lines = $request | pi --mode rpc --no-session --offline --no-approve
```

Parse stdout one JSON object per line, select the response whose `id` is
`sample-009-commands`, and assert `success` is true. Do not assert the entire
command list because Pi installations may expose unrelated user-level
resources. Instead assert these two entries independently:

| Command | Required source | Required package path |
| --- | --- | --- |
| `wire-log` | `extension` | ends in `package/extensions/wire-log.ts` |
| `skill:haiku` | `skill` | ends in `package/skills/haiku/SKILL.md` |

Pi 0.80.6 may expose the resource path directly as `path` or within
`sourceInfo.path`; normalize either representation before comparing canonical
paths. Matching name, source type, and source file prevents an unrelated
command with the same name from creating a false pass.

This RPC request performs no LLM turn. `--no-session` avoids session artifacts,
`--offline` suppresses startup network operations, and EOF after the single
request lets the child process exit.

### Removal and negative assertion

Run `pi remove` with the same absolute path used for installation. Then assert:

- removal exits zero and reports `Removed <absolute-path>`;
- the parsed `settings.json` no longer contains that package source (an empty
  `packages` array is acceptable);
- `pi list` prints `No packages installed.` in the isolated config;
- a **new** RPC process returns neither the package's `wire-log` entry nor its
  `skill:haiku` entry when matched by package source path.

The second process matters: removing a settings entry does not unload resources
from a Pi process that has already started.

### Failure cleanup

Use a top-level `try/finally`. The `finally` block must:

1. Attempt `pi remove $packagePath --no-approve` only if installation was
   recorded and removal did not already succeed; cleanup failure should be
   reported but must not hide the original assertion failure.
2. `Pop-Location` if the script pushed it.
3. Restore both environment variables exactly, removing them when they were
   originally absent.
4. Delete only the generated temporary root, and only after checking both that
   it is below the system temp directory and that its sentinel file exists.

Never recursively remove the package source, the sample directory, the active
repository, the user's default Pi directory, or a path supplied by the caller.
Print the temporary path before work begins so a failed cleanup can be inspected
manually.

## Verification matrix

| Stage | Action | Authoritative assertion | Must not happen |
| --- | --- | --- | --- |
| Prerequisite | `pi --version` | CLI exists; version is printed | Silent fallback to another command |
| Isolation | Set temporary config and work dirs | Both resolve below the allocated temp root | Touch shared `samples/settings.json` or `~/.pi/agent` |
| Install | `pi install <absolute-path>` | Exit 0; settings contains source | Copy local package to npm/git cache |
| List | `pi list` | User package entry contains exact source | Project-scope entry |
| Discover extension | RPC `get_commands` | `wire-log`, source `extension`, expected file | Provider/model request or dump file creation |
| Discover skill | Same RPC response | `skill:haiku`, source `skill`, expected `SKILL.md` | Model-based poetry assertion |
| Remove | `pi remove <same-path>` | Exit 0; source absent from settings | Removal of package source directory |
| List after removal | `pi list` | `No packages installed.` | Stale configured package |
| Rediscover | Fresh RPC `get_commands` | Neither expected package resource remains | Reuse of the pre-removal Pi process |
| Cleanup | `finally` | Environment restored; scratch root removed | Broad or caller-controlled recursive deletion |

## Manual exploratory run

After the deterministic verifier passes, the README may offer an optional
interactive exercise. It must still use a disposable config directory. Start
Pi, confirm `/wire-log status` is available, ask for a sea haiku using
`/skill:haiku`, and optionally enable wire logging for one request. This is the
only part that needs a configured model. It supplements the verifier; it is not
the acceptance gate.

If the learner enables wire logging, point out that logs can contain prompts,
file contents, headers, or provider payloads and must be treated as sensitive.

## Security and trust notes

The sample must make these statements explicit:

- Pi packages run with the permissions of the Pi process. Extensions are
  arbitrary TypeScript/JavaScript code and can execute as soon as resources are
  loaded.
- Skills are instructions supplied to the model. They can direct tool use and
  can reference executable scripts; they are not inert documentation.
- `PI_CODING_AGENT_DIR` isolates settings, sessions, and package-managed cache
  locations. It is **not** an operating-system sandbox and does not limit
  filesystem, process, credential, or network access for loaded code.
- Project trust controls whether project resources are loaded; it is an input
  loading decision, not a runtime permission boundary. This verifier avoids
  project scope and works from an empty directory to keep the lesson focused.
- Review `package.json`, extension source, skills, scripts, install hooks, and
  transitive dependencies before installing a third-party package. Prefer
  pinned npm versions or Git refs when reproducibility matters.
- A local-path package is live source. Review it again after it changes, since
  the settings entry continues to reference the same directory.
- Real isolation for untrusted packages requires a container, VM, micro-VM, or
  another OS-level policy boundary with minimal mounted files and credentials.

This package intentionally contains no dependencies, lifecycle scripts, network
access, or writes at load time, so every capability is easy to inspect.

## Acceptance criteria

The sample is complete only when all of the following are true:

- `samples/009-package-and-share/` contains its README, PowerShell verifier,
  four required shared symlinks, and the exact package structure described
  above.
- `package.json` parses as JSON, includes `pi-package`, declares only the
  packaged extension and skill, and identifies Pi core as a peer dependency.
- The extension loads under Pi 0.80.6, registers `/wire-log`, remains inert
  while off, and creates no dump merely during discovery.
- The skill has valid frontmatter and appears as `/skill:haiku`.
- `verify.ps1` can be launched from outside the sample directory and exits zero
  after proving install, list, both resource discoveries, remove, negative
  rediscovery, and cleanup.
- A forced mid-verification failure still restores the caller's environment and
  does not modify or delete the package source, shared course settings, or the
  user's normal Pi configuration.
- The README teaches both the successful flow and the security boundary in
  plain language, and clearly labels interactive model usage as optional.
- The sample has been run, not merely inspected; its successful verifier output
  is recorded in the implementation handoff.

## Boundaries

Do not publish to npm, push to Git, add a registry token, exercise package
updates, bundle another Pi package, or add themes and prompt templates. Do not
turn the verifier into a general test framework. The durable lesson is package
shape, local-path registration, discovery, removal, and trust.

## Implementation references

- Pi 0.80.6 installed documentation: `docs/packages.md`, `docs/rpc.md`, and
  `docs/security.md` in `@earendil-works/pi-coding-agent`.
- [Current Pi package documentation](https://pi.dev/docs/latest/packages)
- [Sample 003 — auto-discovered wire log](../../samples/003-wire-log-global/README.md)
- [Sample 005 — project context and skills](../../samples/005-context-and-skills/README.md)
