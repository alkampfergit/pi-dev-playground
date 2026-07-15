# 014 — Session trees, fork, clone, and compaction

This lesson moves inside one Pi JSONL session. You will make two fictional
approaches, move between their leaves with `/tree`, preserve the abandoned path
with a branch summary, then compare that in-file operation with `/clone` and
`/fork`. Finally, you will compact the active path and reload it from disk.

The lesson targets Pi coding-agent **0.80.6**. The session file is sensitive:
the inspector below reports structure only and deliberately never prints
conversation content, summaries, custom payloads, credentials, or paths.

## Setup

Use PowerShell 7. Run the preparation script from this directory and dot-source
it so the Azure variables and sample-local Pi configuration remain in the
current shell:

```powershell
cd samples/014-tree-and-compaction
. ./prepare.ps1
pi --version
```

In bash, use `source ./prepare.sh`, then run the walkthrough commands through
`pwsh`. The sample expects the `AZURE_PI_TEST_*` variables described in the
repository root `AGENTS.md`; no credential is stored in this directory.

## Why this sample owns `settings.json`

Most samples symlink `settings.json` to the shared defaults. This one is the
intentional exception: its real `settings.json` keeps the shared Azure model
defaults but sets `compaction.keepRecentTokens` to `1` and retains the normal
`compaction.reserveTokens` value of `16384`. That laboratory value makes a very
short turn compactable and demonstrates a split-turn boundary without a long,
expensive conversation.

Do not copy this retention setting into normal work. It is deliberately too
aggressive for a useful everyday context budget. `models.json`, `prepare.ps1`,
and `prepare.sh` remain the standard shared symlinks.

## 1. Create the common conversation

Start Pi with a disposable lab directory and a descriptive session name. The
sample's verifier uses the same isolation flags, but the interactive lesson
keeps extensions enabled so `/summary-audit` is available.

```powershell
$sessionDir = Join-Path $PWD 'sessions/tree-lab'
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
$model = "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
pi --session-dir $sessionDir --model $model --name 'tree-lab' --no-tools `
  --no-skills --no-prompt-templates --no-context-files
```

At the Pi prompt, submit:

```text
Remember this fictional code: HARBOR-17. Reply exactly: HARBOR-17.
```

Then submit:

```text
Develop fictional APPROACH-A. Reply exactly: APPROACH-A.
```

Inspect the structure without exposing the conversation:

```text
/session
```

From another PowerShell prompt in the sample directory, inspect the current
session file with the safe helper. Pi prints the session path interactively;
copy that one path into the command when prompted by your own workflow, or use
the verifier for fully automated discovery.

```powershell
pwsh ./inspect-tree.ps1 -SessionFile '<one session JSONL path>'
pwsh ./inspect-tree.ps1 -SessionFile '<one session JSONL path>' -Format Json
```

At this point the tree is linear.

## 2. Make and visit the B alternative

Run `/tree`. Select the `APPROACH-A` user message. Choose branch
summarization, and optionally focus the summary on decisions and constraints.
Pi moves the leaf to that user message's parent and puts the selected text back
in the editor. Edit it to this fictional alternative and submit it:

```text
Develop fictional APPROACH-B. Reply exactly: APPROACH-B.
```

The A entries remain in the JSONL file. The B path now contains a
`branch_summary` at the destination position. Run `/tree` again and visit both
leaves. Also perform one navigation with no summary. A summary is a choice for
carrying abandoned context; it is not required to create a new branch.

The sample extension records only safe event metadata in memory. Try:

```text
/summary-audit status
/summary-audit checkpoint
```

Then inspect the same session in table and JSON form. The JSON projection shows
short IDs, parent relationships, child counts, active-path flags, and aggregate
summary/compaction metadata. It does not show the summary text.

## 3. Compare `/clone` and `/fork`

With the desired B leaf active, run:

```text
/clone
```

Pi replaces the runtime with a new related session file. The clone has a new
session ID and a `parentSession` header, and contains only the source's active
root-to-leaf path. Continue it with a fictional clone-only marker to see that
the original does not change.

Reopen the original session, move to the A path, and run `/fork`. Select the A
user message. Pi creates a related file ending immediately before that selected
user entry and returns the selected text to the editor. Edit it and continue
with a fictional fork-only marker.

The distinction is the cut boundary:

| Operation | File | Context boundary |
| --- | --- | --- |
| `/tree` | same append-only JSONL tree | selected path, optionally with a branch summary |
| `/clone` | new related file | current root-to-leaf path |
| `/fork` | new related file | root-to-parent of a selected user message |

Sample 010's startup `pi --fork <path-or-id>` is a separate lesson. It copies a
source file at process startup, including its stored history; this sample uses
only the interactive/RPC session replacement operations above.

## 4. Compact and reload

Reopen the original B branch and run:

```text
/compact Keep fictional codes and the selected approach.
```

The tiny laboratory retention setting makes this short conversation eligible.
The file gains a `compaction` entry; earlier JSONL entries are not deleted.
Restart Pi on the same session and ask it to recall `HARBOR-17` and the selected
approach. The rebuilt context comes from the compaction summary plus the
retained suffix, while the older file history remains available on disk.

Compaction and branch summarization both reduce the active model context, but
they do different jobs: branch summarization is attached during a tree move to
preserve an abandoned branch's useful context, while compaction summarizes the
current path before a kept boundary.

## Automated verification

The verifier first creates parser-only JSONL fixtures, runs both inspector
formats, checks malformed-input failures, and scans output for denylisted
content. This path needs no model or credentials:

```powershell
. ./prepare.ps1
pwsh ./verify.ps1 -ModelFreeOnly
```

When the required Azure variables are available, run the complete bounded
verification:

```powershell
pwsh ./verify.ps1
```

It starts Pi in RPC mode with tools, skills, prompt templates, and context files
disabled; keeps the sample extension auto-discovered; uses deterministic
fixture summaries; and disposes of a unique `sessions/verification/` directory
in `finally`. It checks tree relationships, summarized and plain navigation,
compaction plus disk reload, clone/fork cut boundaries, source immutability,
event ordering, and privacy-safe output. Success is one concise count-only
`PASS` line. No generated session or diagnostic artifact is meant to remain.

`summary-audit.ts` is intentionally normal in interactive mode. Deterministic
summary text is enabled only in the verifier child process by
`PI_SUMMARY_AUDIT_FIXTURE=1`; the extension never reads or persists prompts,
responses, summaries, tool data, or environment values.
