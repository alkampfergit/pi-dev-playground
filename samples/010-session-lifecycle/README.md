# 010 — Session lifecycle and branching

This sample makes Pi's local session lifecycle visible. You will create and
name a conversation, continue the most recently modified session, reopen it by
its exact ID, find it in the interactive picker, fork it into an independent
file, and run one disposable turn that creates no session record.

The commands and JSONL details below are version-sensitive. Begin by checking
the installed version:

```powershell
pi --version
```

This sample was designed and verified with Pi coding-agent **0.80.6**.

## What you will learn

By the end, you will know when to use each session entry point:

- `-c` continues the most recently modified session for the current project;
- `-r` opens the interactive session picker;
- `--session <full-id>` reopens one exact conversation;
- `--fork <full-id>` copies existing history into a new, related file; and
- `--no-session` keeps the current Pi conversation in memory only.

You will use `list-sessions.ps1` or `list-sessions.sh` to inspect only safe
lifecycle metadata. Both helpers never print prompts, assistant responses,
tool data, or absolute paths.

## Prerequisites and setup

You need Node.js, Pi coding-agent 0.80.6, PowerShell 7 (`pwsh`), and the Azure
variables described in the repository's root `AGENTS.md`. From this directory:

```powershell
. ./prepare.ps1
pi --version
$sessionDir = Join-Path $PWD 'sessions/lifecycle-lab'
$model = "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
New-Item -Path $sessionDir -ItemType Directory -Force | Out-Null
```

The preparation script must be sourced so its environment changes remain in
your shell. A Bash-only setup is:

```bash
source ./prepare.sh
pi --version
session_dir="$PWD/sessions/lifecycle-lab"
model="azure-openai/$AZURE_PI_TEST_DEPLOYMENT"
mkdir -p "$session_dir"
```

`--session-dir` isolates this lab from your other Pi sessions and makes the
exercise reproducible. It changes where Pi stores and searches for JSONL files;
it does not change the session header's `cwd`, which remains this sample
directory. Start with an empty `sessions/lifecycle-lab` directory if you want
the file counts below to match exactly. Do not reuse or delete another sample's
sessions.

Every scripted turn disables tools, extensions, skills, prompt templates, and
context files. The lesson needs only conversation state, and this keeps the
stored history small and predictable.

## 1. Start and name the original session

```powershell
pi --session-dir $sessionDir --model $model --no-tools `
  --no-extensions --no-skills --no-prompt-templates --no-context-files `
  --name 'lifecycle-original' -p `
  'Remember this fictional release-checklist codeword: ORBIT-41. Reply exactly: BASE: ORBIT-41'
```

After a successful assistant response, inspect the metadata:

```powershell
pwsh ./list-sessions.ps1
$sessions = pwsh ./list-sessions.ps1 -Format Json | ConvertFrom-Json
$originalId = $sessions[0].Id
$originalId
```

The equivalent Bash inspection commands are:

```bash
./list-sessions.sh
original_id="$(./list-sessions.sh --format json | node -e '
  let input = "";
  process.stdin.on("data", chunk => input += chunk);
  process.stdin.on("end", () => console.log(JSON.parse(input)[0].Id));
')"
printf '%s\n' "$original_id"
```

There should be one session named `lifecycle-original`. Pi's version-3 JSONL
starts with a `session` header, while `--name` appends a later `session_info`
entry. Naming does not rewrite the header. The helper gives you the latest name
and full ID without exposing the conversation.

A newly allocated persistent session may not appear on disk until Pi has a
successful assistant message to flush. If the provider fails, solve that
failure before interpreting a missing file as a lifecycle problem.

## 2. Continue the most recent session

Take a metadata snapshot, continue, and compare it with the result:

```powershell
$before = pwsh ./list-sessions.ps1 -Format Json | ConvertFrom-Json

pi --session-dir $sessionDir --model $model --no-tools `
  --no-extensions --no-skills --no-prompt-templates --no-context-files `
  -c -p 'What fictional codeword did I ask you to remember? Reply exactly: CONTINUED: <codeword>'

$after = pwsh ./list-sessions.ps1 -Format Json | ConvertFrom-Json
$before | Format-Table Id, Entries, Messages
$after  | Format-Table Id, Entries, Messages
```

The response should contain `CONTINUED: ORBIT-41`. The pathname and ID remain
the same, while entry and message counts grow. `-c` is based on modification
time, not a durable alias for a named task. A successful turn in another
session can change which file is “most recent.” In an empty session directory,
`-c` creates the first session instead of failing.

## 3. Reopen by exact identity

Use the full ID you obtained from the helper:

```powershell
pi --session-dir $sessionDir --model $model --no-tools `
  --no-extensions --no-skills --no-prompt-templates --no-context-files `
  --session $originalId -p `
  'Reply exactly: REOPENED: ORBIT-41'

pwsh ./list-sessions.ps1
```

The same file grows again. Pi accepts an ID prefix and searches the current
project before other projects, but prefixes can become ambiguous as your
session collection grows. Scripts should use a full ID or a resolved path.

## 4. Find the named session interactively

```powershell
pi --session-dir $sessionDir -r
```

Search for `lifecycle-original`, select it, enter `/session` to view Pi's own
session information, and finish with `/quit`. The picker also supports a
named-only filter, renaming, and deletion. This is intentionally a manual TUI
exercise; `verify.ps1` does not send synthetic terminal keystrokes.

Remember that picker deletion is a convenience operation, not guaranteed
secure erasure. Pi may use the system `trash` command when it is available.

## 5. Fork an alternative plan

First locate and hash the original file without displaying its content:

```powershell
$original = (pwsh ./list-sessions.ps1 -Format Json | ConvertFrom-Json) |
  Where-Object Id -eq $originalId
$originalPath = Join-Path $sessionDir $original.RelativeFile
$originalHash = (Get-FileHash $originalPath -Algorithm SHA256).Hash
```

Now create and name an independent alternative:

```powershell
pi --session-dir $sessionDir --model $model --no-tools `
  --no-extensions --no-skills --no-prompt-templates --no-context-files `
  --fork $originalId --name 'lifecycle-alternative' -p `
  'For this alternative plan only, replace the fictional codeword with COMET-73. Reply exactly: FORK: COMET-73'

pwsh ./list-sessions.ps1
$originalHash -eq (Get-FileHash $originalPath -Algorithm SHA256).Hash
```

You should now see two files. The alternative has a different ID, is marked as
a fork, and shows the original ID as its parent. The final comparison should be
`True`: forking did not modify the source file.

The new header contains `parentSession`, which points to the original file. All
non-header source entries are copied before the fork's name and new turn are
appended. The fork therefore contains the earlier `ORBIT-41` history followed
by its `COMET-73` alternative; the original does not gain that new turn. A fork
is a duplicated history with provenance, not a pointer-only branch.

Pi offers three related branching choices:

| Choice | File behavior | Best fit |
| --- | --- | --- |
| `/tree` | Adds another branch in the same JSONL tree | Alternatives that belong together |
| `/fork` or `--fork` | Creates a new file from earlier or source history | Independent investigation with provenance |
| `/clone` | Copies the current active branch to a new file | Duplicate the current state before continuing |

`--fork` cannot be combined with `--session`, `--continue`, `--resume`, or
`--no-session`.

## 6. Run without persisting a session

Take a pathname-and-hash snapshot, run ephemerally, and compare snapshots:

```powershell
function Get-LabSnapshot {
  Get-ChildItem $sessionDir -Recurse -File -Filter '*.jsonl' |
    Sort-Object FullName |
    ForEach-Object {
      [pscustomobject]@{
        File = [IO.Path]::GetRelativePath($sessionDir, $_.FullName)
        Hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
      }
    }
}

$ephemeralBefore = @(Get-LabSnapshot | ConvertTo-Json -Compress)

pi --session-dir $sessionDir --model $model --no-tools `
  --no-extensions --no-skills --no-prompt-templates --no-context-files `
  --no-session -p 'Reply exactly: EPHEMERAL'

$ephemeralAfter = @(Get-LabSnapshot | ConvertTo-Json -Compress)
Compare-Object $ephemeralBefore $ephemeralAfter
```

You see `EPHEMERAL`, but `Compare-Object` should print nothing: no new file was
created and no existing file changed. `--no-session` prevents Pi's session
persistence for this process. It says nothing about provider retention,
terminal output, shell history, operating-system logging, or CI logs.

## Automated verification

The verifier uses real model calls. It creates a GUID-named child below
`sessions/verification`, validates each JSONL independently, exercises the
empty-directory `-c` edge case, and removes only that unique directory in a
`finally` block. It never touches `sessions/lifecycle-lab`.

```powershell
. ./prepare.ps1
pwsh ./verify.ps1
```

A successful run prints one short `PASS` line. Model prompts and responses are
captured for marker assertions but are not printed on success.

## Privacy: session files are sensitive

Pi JSONL can contain user prompts, assistant text and thinking, tool calls and
arguments, tool results, command output, compaction and branch summaries,
custom extension data, timestamps, provider and model names, token usage, and
the original absolute working directory.

- A fork duplicates source history. Deleting the original does not erase its
  fork, an export, a backup, or a shared copy.
- `parentSession` is an absolute local path and can reveal usernames and folder
  names. The helper intentionally reduces it to a parent ID.
- Session JSONL is a local record, not an encrypted vault. Never place secrets
  in prompts merely because `sessions/` is ignored by Git.
- `/export`, `/import`, `/share`, manual copies, and picker deletion have wider
  data-lifecycle consequences. Inspect and redact a copy before sharing it.
- Names and timestamps can themselves reveal project information, even though
  the helper omits conversation text and absolute paths.

Never commit `sessions/`. The repository-level `.gitignore` already excludes
it. Avoid commands that print the live JSONL into a terminal transcript.

## Edge cases worth remembering

- A later `session_info` name supersedes an earlier one. Empty names are
  rejected; whitespace is trimmed and embedded newlines are normalized.
- A direct fork copies the source's current full entry set. Sessions containing
  in-file branches or compactions can have a more complex history than this
  sample's deliberately linear conversation.
- Opening a session from another project may change or prompt about project
  context. The helper filters records by the header `cwd`, and this lesson does
  not exercise cross-project resume.
- A malformed or legacy file is skipped with a content-free warning. The helper
  does not migrate or repair sessions.

## Files in this sample

- `list-sessions.ps1` and `list-sessions.sh` report the same lifecycle
  metadata in table or JSON format.
- `verify.ps1` performs the real-model acceptance checks.
- `models.json`, `settings.json`, `prepare.ps1`, and `prepare.sh` are symlinks
  to the shared files at the `samples` root.

## References

- [Pi session documentation](https://pi.dev/docs/latest/sessions)
- [Pi session format](https://pi.dev/docs/latest/session-format)
- [Pi CLI usage](https://pi.dev/docs/latest/usage)
