# 010 — Session lifecycle and branching

## Goal

Make Pi session persistence visible and intentional. Existing samples create
sessions and sample 001 reports their token usage, but this lesson teaches the
user how to name, continue, select, reopen, fork, and deliberately avoid saving
a conversation.

The sample should leave the learner with two complementary views:

- the user-facing CLI workflow (`--name`, `-c`, `-r`, `--session`, `--fork`,
  and `--no-session`); and
- a privacy-preserving metadata view of the local JSONL files that proves what
  each command changed without dumping prompts or responses.

This is a CLI lesson. Do not introduce the SDK session APIs or an extension.

## Version and verified Pi behavior

Design and verify against Pi coding-agent `0.80.6`. Its installed help, session
documentation, type declarations, and session-manager implementation establish
the following behavior:

- Sessions are version-3 JSONL files. The first line is a `session` header with
  `id`, `timestamp`, `cwd`, and optional `parentSession`; later entries form an
  append-only tree through `id` and `parentId`.
- `--name` / `-n` appends a `session_info` entry. The latest `session_info.name`
  is the display name; naming an existing session does not rewrite its header.
- `-c` / `--continue` opens the most recently modified session for the current
  working directory. If none exists, it creates a new session.
- `-r` / `--resume` opens the interactive session picker. The picker supports
  search, named-only filtering, renaming, and deletion.
- `--session <path|id>` opens a saved file. A non-path value is matched against
  an exact session ID first and then an ID prefix, searching the current project
  before other projects.
- `--fork <path|id>` creates a new session file, gives it a new header and ID,
  records the source file in `parentSession`, and copies all non-header source
  entries before appending new work. It does not modify the source file.
- `--fork` cannot be combined with `--session`, `--continue`, `--resume`, or
  `--no-session`.
- `--no-session` uses an in-memory session. Names, messages, and model changes
  may exist for that process, but no session JSONL is persisted.
- A newly allocated persisted session is not necessarily visible on disk
  immediately: Pi flushes it after an assistant message exists. Verification
  must use successful turns rather than assuming startup alone creates a file.

The sample README must begin its setup checks with `pi --version` and state
that these details are version-sensitive.

## What the learner should obtain

- A practical distinction between “most recent” (`-c`), interactive selection
  (`-r`), exact identity (`--session`), and disposable work (`--no-session`).
- The ability to set a stable display name and recover the full ID from a local
  metadata listing.
- A safe fork workflow for testing a conflicting plan without changing the
  original conversation.
- Evidence that a fork is a second file with copied history, not a pointer-only
  branch and not an in-place mutation.
- An understanding that session files are local conversation records, not safe
  logs to publish by default.

## Intended sample layout

Create exactly this implementation layout:

```text
samples/010-session-lifecycle/
├── README.md
├── list-sessions.ps1
├── verify.ps1
├── models.json       -> ../models.json
├── settings.json     -> ../settings.json
├── prepare.ps1       -> ../prepare.ps1
└── prepare.sh        -> ../prepare.sh
```

The walkthrough stores its disposable lab sessions under
`./sessions/lifecycle-lab/`. `verify.ps1` uses a unique child directory below
`./sessions/verification/` and removes only that directory in a `finally`
block. The repository-level `.gitignore` already ignores `sessions/`; do not
add or commit fixture session files.

The four standard symlinks are required. No custom `models.json`, extension,
prompt template, or skill is needed.

## Conversation used by the walkthrough

Use a harmless planning conversation with two conspicuous, non-secret markers:

- original-session codeword: `ORBIT-41`;
- fork-only replacement: `COMET-73`.

The first turn asks Pi to remember that a fictional release checklist uses
`ORBIT-41` and to reply with `BASE: ORBIT-41`. The continue turn asks for the
remembered value without repeating it and expects `CONTINUED: ORBIT-41`. The
fork turn explicitly replaces it with `COMET-73` for an alternative plan and
expects `FORK: COMET-73`.

Use `--no-tools`, `--no-extensions`, `--no-skills`,
`--no-prompt-templates`, and `--no-context-files` for every scripted model
turn. The lesson needs conversation state only; allowing tools would add noise
and could persist tool arguments/results in the JSONL.

Model prose is not byte-for-byte deterministic. Automated checks may require
the short marker to appear in the assistant response, but must derive lifecycle
proof from the files: IDs, entry counts, parent relationships, hashes, and file
sets.

## `list-sessions.ps1` design

### Purpose and parameters

Create a small read-only PowerShell helper that lists only sessions belonging
to this sample and never prints message content.

Use an advanced script with:

- `-SessionsDirectory`, default
  `$PSScriptRoot/sessions/lifecycle-lab`;
- `-Format Table|Json`, default `Table`.

The verifier can point the helper at its unique verification directory and use
JSON output for assertions. A missing directory or an empty directory is not
an error: table mode prints a short “no sessions” message and JSON mode emits
`[]`.

### Parsing and filtering

For every `*.jsonl` below the selected directory, in stable pathname order:

1. Parse each non-empty line independently with `ConvertFrom-Json -Depth 30`.
2. Require the first parsed record to be a versioned `session` header with a
   non-empty `id`, timestamp, and `cwd`.
3. Resolve `header.cwd` and include the file only when it equals
   `$PSScriptRoot`. This prevents a custom shared session directory from leaking
   another project's metadata.
4. Read the latest `session_info` entry for the display name.
5. Count total entries, `message` entries, user turns, assistant turns, and tool
   result turns. Do not extract `message.content`, tool arguments, tool output,
   compaction summaries, or custom-entry data.
6. Treat a non-empty `parentSession` as fork metadata. Derive a parent session
   ID from the parent filename when possible, but never display the absolute
   parent path.
7. Use the header timestamp as creation time and filesystem
   `LastWriteTimeUtc` as modification time. Sort newest modification first,
   then by ID for stable ties.

Malformed files should produce a warning containing only the relative filename
and a short reason; never echo the invalid JSON line. Skip the malformed file
rather than returning partly trusted metadata.

### Output contract

Both formats expose only these fields:

```text
Name
Id
CreatedUtc
ModifiedUtc
Entries
Messages
UserTurns
AssistantTurns
ToolResultTurns
IsFork
ParentId
RelativeFile
```

`RelativeFile` is relative to `SessionsDirectory`, so neither table nor JSON
mode reveals the user's home directory. An absent name or parent ID is rendered
as an empty value. IDs and names are intentionally visible because they are the
metadata the learner needs for `--session` and `-r`; the README must still note
that even names and timestamps can reveal sensitive project information.

The helper is deliberately narrower than sample 001's `session-stats.ps1`:
sample 001 aggregates usage and cost, while this helper explains lifecycle and
parentage. Do not copy the large statistics implementation.

## CLI walkthrough

All commands start in `samples/010-session-lifecycle` after:

```powershell
. ./prepare.ps1
pi --version
$sessionDir = Join-Path $PWD 'sessions/lifecycle-lab'
$model = "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
```

The README should explain that `--session-dir` is used here to make the lab
isolated and reproducible. It does not change the session header's `cwd`, which
must remain the sample directory.

### 1. Start and name the original

Run one successful print-mode turn with:

```powershell
pi --session-dir $sessionDir --model $model --no-tools `
  --no-extensions --no-skills --no-prompt-templates --no-context-files `
  --name 'lifecycle-original' -p `
  'Remember this fictional release-checklist codeword: ORBIT-41. Reply exactly: BASE: ORBIT-41'
```

Then run `pwsh ./list-sessions.ps1`. There should be one named session. Capture
its full ID without parsing the table:

```powershell
$sessions = pwsh ./list-sessions.ps1 -Format Json | ConvertFrom-Json
$originalId = $sessions[0].Id
```

The README should point out the header plus the later `session_info` entry, but
must not tell the learner to print the whole JSONL.

### 2. Continue the most recent session

Take a before snapshot from the helper, run `-c` with the same
`--session-dir`, model, and resource-disabling flags, then list again:

```powershell
pi --session-dir $sessionDir --model $model --no-tools `
  --no-extensions --no-skills --no-prompt-templates --no-context-files `
  -c -p 'What fictional codeword did I ask you to remember? Reply exactly: CONTINUED: <codeword>'
```

The file count and session ID must stay the same while message and entry counts
increase. The response should contain `ORBIT-41`. Explain that `-c` is a
convenience based on modification time, not a durable alias for the named task.

### 3. Reopen by exact identity

Use the full ID from the helper, not an abbreviated prefix:

```powershell
pi --session-dir $sessionDir --model $model --no-tools `
  --no-extensions --no-skills --no-prompt-templates --no-context-files `
  --session $originalId -p `
  'Reply exactly: REOPENED: ORBIT-41'
```

Verify that the same file and header ID gained another turn. Mention that ID
prefixes are convenient for humans but can become ambiguous; scripts should
use a full ID or a resolved path.

### 4. Find it interactively

Run:

```powershell
pi --session-dir $sessionDir -r
```

Search for `lifecycle-original`, select it, run `/session` to view Pi's own
session information, then `/quit`. This step is manual because `-r` is a TUI
picker. Do not attempt to automate terminal keystrokes in `verify.ps1`.

### 5. Fork an alternative

Hash the original file before the fork. Then create a named fork from its full
ID:

```powershell
pi --session-dir $sessionDir --model $model --no-tools `
  --no-extensions --no-skills --no-prompt-templates --no-context-files `
  --fork $originalId --name 'lifecycle-alternative' -p `
  'For this alternative plan only, replace the fictional codeword with COMET-73. Reply exactly: FORK: COMET-73'
```

Afterward there must be two files. The original hash is unchanged. The new
header has a different ID and `parentSession` pointing to the original file;
its copied non-header history is followed by the fork name and new turn. The
fork response contains `COMET-73`, while the original contains no new
`COMET-73` entry.

Explain the difference between three branching choices without implementing
extra exercises:

| Choice | File behavior | Best fit |
| --- | --- | --- |
| `/tree` | Adds another branch in the same JSONL tree | Alternatives that belong together |
| `/fork` or `--fork` | Creates a new file from earlier/source history | Independent investigation with provenance |
| `/clone` | Copies the current active branch to a new file | Duplicate the current state before continuing |

### 6. Run ephemerally

Snapshot every lab session pathname and SHA-256 hash, then run:

```powershell
pi --session-dir $sessionDir --model $model --no-tools `
  --no-extensions --no-skills --no-prompt-templates --no-context-files `
  --no-session -p 'Reply exactly: EPHEMERAL'
```

The response is visible, but the pathname-and-hash snapshot must be identical
afterward. This proves both that no new file appeared and that an existing file
was not changed.

## `verify.ps1` design

The verifier uses real model calls and a private, uniquely named directory such
as `sessions/verification/<guid>`. It must never reuse or delete
`sessions/lifecycle-lab`.

Before running, require `pi`, `AZURE_PI_TEST_DEPLOYMENT`,
`AZURE_PI_TEST_API_KEY`, and `PI_CODING_AGENT_DIR`; confirm that the latter
resolves to `$PSScriptRoot`. Use strict mode, fail on any non-zero Pi exit code,
and always remove only the unique verification directory in `finally`.

To make identities unambiguous, generate legal unique IDs and pass them through
Pi 0.80.6's `--session-id` in the verifier only: one for the original and one
for the fork. The teaching walkthrough still discovers IDs through the helper.

The verifier should independently parse the JSONL instead of trusting only the
helper. For every file it examines, validate:

- first record is a version-3 session header with the expected ID and sample
  `cwd`;
- every later record has `id`, `parentId`, `timestamp`, and a known parent
  unless it is a root entry;
- the latest `session_info.name` matches the expected display name;
- required user and assistant turns exist and assistant stop reasons are not
  `error` or `aborted`;
- no API key value occurs in serialized session text.

Capture Pi stdout only for marker assertions; do not print it on success. On
failure, report the phase and session ID, but avoid dumping full session lines
or prompts.

## Deterministic verification matrix

| Phase | Command surface | File-level assertion | Conversation assertion | Automated? |
| --- | --- | --- | --- | --- |
| Named start | `--name`, `--session-id`, `-p` | Exactly one file; expected header ID; latest name is `lifecycle-original` | Successful assistant turn contains `ORBIT-41` | Yes |
| Continue | `-c` | Same pathname and ID; entry/message counts increase; no second file | Response contains remembered `ORBIT-41` | Yes |
| Exact reopen | `--session <full-id>` | Same pathname grows; no new file | Successful response contains `REOPENED` | Yes |
| Resume picker | `-r`, `/session` | Selected ID matches named session | User observes retained history | Manual |
| Fork | `--fork`, `--name`, `--session-id` | Second file; new ID; `parentSession` resolves to original; copied source history; original SHA-256 unchanged | Fork response contains `COMET-73`; original has no fork-only entries | Yes |
| Ephemeral | `--no-session` | Full pathname-and-hash map unchanged | Response contains `EPHEMERAL` | Yes |
| Metadata privacy | `list-sessions.ps1` table and JSON | Reports both expected IDs/counts/parentage | Output contains neither codeword, prompt text, API key, absolute cwd, nor absolute parent path | Yes |
| Missing continue target | `-c` in a fresh unique directory | Creates the first session after a successful turn | Documented as an edge case, not an error | Yes |

For fork-prefix verification, compare the fork's copied non-header entries with
the source entries as they existed at the hash snapshot. They must match in
order before the fork-specific `session_info` and messages begin. Do not compare
headers: the fork intentionally has a new ID, timestamp, `cwd`, and
`parentSession`.

## Privacy behavior to teach

The README needs a prominent privacy section with these concrete points:

- JSONL can contain user prompts, assistant text and thinking, tool calls and
  arguments, tool results, command output, compaction/branch summaries, custom
  extension data, timestamps, provider/model names, token usage, and the
  original absolute working directory.
- A fork duplicates source history. Deleting the original does not erase the
  fork, an exported copy, a backup, or a shared artifact.
- The `parentSession` header is an absolute local path and may expose usernames
  or directory names. `list-sessions.ps1` intentionally reduces it to a parent
  ID.
- Pi session files are local JSONL, not encrypted vaults. Do not put secrets in
  prompts merely because `sessions/` is git-ignored.
- `--no-session` prevents Pi session persistence for that run, but it cannot
  promise that the provider, terminal, shell history, OS, or surrounding CI
  system keeps no records.
- `/export`, `/import`, `/share`, manual copies, and picker deletion have wider
  data-lifecycle consequences. The interactive picker may use the system
  `trash` command when available; do not present deletion as guaranteed secure
  erasure.
- Never commit `sessions/`. Before sharing a session, inspect and redact a copy
  rather than opening the live JSONL in a command that echoes all content to a
  transcript.

The metadata helper reduces accidental disclosure; it does not make the
underlying sessions non-sensitive.

## Edge cases and expected handling

- `-c` in an empty session directory starts a new session. The README must not
  say it always resumes an existing one.
- “Most recent” means most recently modified, so another successful turn can
  change what `-c` selects. Prefer `--session <full-id>` in automation.
- An initial provider failure may leave no session file because persistence is
  flushed only after an assistant message exists. Report the model failure
  before asserting file counts.
- `--name ''` is rejected; names are trimmed and embedded newlines are
  normalized. A later name entry supersedes an earlier one.
- Partial IDs are searched locally first and then globally. Avoid them in
  scripts, especially as the session collection grows.
- Opening a session from another project can change or prompt about project
  context; this lesson filters by header `cwd` and does not exercise
  cross-project resume.
- A direct fork copies the source's current full entry set. In-file `/tree`
  branches and compactions can make “history” more complex than a linear list;
  this sample begins with a simple linear source.
- `--fork` flag conflicts must be shown in a short note, not executed against
  the model.
- A malformed or legacy session is skipped by the helper with a content-free
  warning. The sample does not migrate or repair files.

## Acceptance criteria

The sample is complete only when all of the following are proven:

- The exact implementation files and four valid shared symlinks exist.
- `list-sessions.ps1` supports table and JSON output, filters by sample `cwd`,
  reports the documented metadata, and never emits conversation content or
  absolute source/parent paths.
- The named start creates one valid version-3 JSONL with the expected
  `session_info` name.
- `-c` and `--session <full-id>` append to that same session rather than create
  another file.
- The manual `-r` walkthrough is documented and works in a real terminal.
- `--fork` creates a distinct named file with copied history and correct
  `parentSession`, while a before/after SHA-256 proves the original was not
  changed by the fork operation.
- The fork contains the alternative marker and the original does not gain it.
- A `--no-session` run leaves both the session pathname set and all existing
  hashes unchanged.
- The verifier covers the “`-c` with no existing session” edge case.
- `pwsh ./verify.ps1` passes with real Azure credentials and Pi 0.80.6, cleans
  only its unique verification directory, and prints no prompt/response body or
  API key on success.
- The README uses a teacher-to-student progression, documents privacy limits,
  and distinguishes `/tree`, fork, and clone without expanding into SDK code.
- The implementation is actually run before completion, `git diff --check`
  passes, and no session, credential, export, or generated verification artifact
  is tracked.

## Boundaries

- Do not implement SDK session APIs, an extension, a TUI driver, session
  migration, redaction software, encryption, or secure deletion.
- Do not automate `-r`; it is intentionally the manual picker exercise.
- Do not reuse, inspect, modify, or remove sessions from other samples or the
  user's default `~/.pi/agent` directory.
- Do not expose prompts in the metadata helper merely to make verification
  easier.
- Keep the planning conversation harmless, tool-free, and short.
