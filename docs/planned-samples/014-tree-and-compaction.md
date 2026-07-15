# 014 — Session trees, fork, clone, and compaction

## Goal

Continue sample 010 from file-level session lifecycle into Pi's in-file
conversation tree and context-reduction mechanisms. The learner should build
two alternatives inside one JSONL session, navigate between them, preserve the
abandoned branch through a summary, clone or fork at the appropriate boundary,
and compact older context.

This is not a second session-picker lesson. Sample 010 remains the source for
`--session`, `--fork`, continuation, naming, and ephemeral runs. Sample 014
focuses on the structure and model context of one branching conversation.

The implementation target is Pi `0.80.6`. The installed package
`@earendil-works/pi-coding-agent` documentation and emitted TypeScript types are
authoritative for implementation.

## Concepts to distinguish

| Operation | Persistence result | Context result | Teaching purpose |
| --- | --- | --- | --- |
| `/tree` | Moves the leaf inside the same append-only JSONL tree | Rebuilds context from the selected path; may attach a branch summary | Explore alternatives that belong together |
| `/fork` | Creates a related session file ending immediately before a selected user message and puts that message back in the editor | Contains the selected root-to-parent path | Separate an investigation while retaining provenance |
| `/clone` | Creates a related session file containing the root-to-current-leaf path | Starts with the same active context as the source | Duplicate the present state before continuing |
| `/compact [instructions]` | Appends a `compaction` entry; it does not delete or rewrite older JSONL entries | Replaces older active-path context with a summary and retains a recent suffix | Reduce model context without destroying persisted history |

`/fork` and `/clone` both use Pi's session-replacement lifecycle and both set
the new header's `parentSession` to the source file. Their difference is the
cut position, not whether provenance exists. Sample 010's startup
`pi --fork <path|id>` copies an entire source file, including abandoned
branches; that CLI behavior may be mentioned for contrast but is not repeated
in this sample's automated lesson.

Branch summarization and compaction are also related but different:

- Branch summarization runs during `/tree` navigation. It summarizes entries
  on the path being abandoned back to the common ancestor and attaches a
  `branch_summary` at the destination position.
- Compaction runs on the current active path. It summarizes context before a
  cut point and retains messages beginning at `firstKeptEntryId`.
- Neither mechanism removes the historical entries already in the JSONL file.
- A session may therefore contain abandoned branches and pre-compaction
  history that are absent from the messages currently sent to the model.

## Intended layout

```text
samples/014-tree-and-compaction/
├── README.md
├── inspect-tree.ps1
├── verify.ps1
├── auth.json
├── models.json       -> ../models.json
├── settings.json     # sample-owned; see Configuration exception
├── prepare.ps1       -> ../prepare.ps1
├── prepare.sh        -> ../prepare.sh
├── sessions/
│   └── .gitkeep
└── extensions/
    └── summary-audit.ts
```

`verify.ps1` owns its small JSONL RPC client; do not add a general framework or
duplicate the controller intended for sample 015. It should start Pi, correlate
responses by request `id`, drain asynchronous events, impose bounded timeouts,
and always terminate the child in `finally`.

### Configuration exception

This sample needs a real `settings.json`, not the usual symlink. Copy the shared
provider/model/theme defaults and add a deliberately tiny
`compaction.keepRecentTokens` value (for example `1`) while retaining a normal
`reserveTokens`. The small value makes a short, inexpensive teaching
conversation compactable and makes the fixture's latest turn split at a valid
assistant boundary. The README must call this out as a laboratory setting,
warn learners not to copy it into normal work, and explain why this is the
explicit exception to the shared-settings convention.

Keep `models.json`, `prepare.ps1`, and `prepare.sh` as the standard root
symlinks. `auth.json` is the same empty `{}` file used by existing samples;
credentials still come only from `AZURE_PI_TEST_*` environment variables.

## Exact learner flow (interactive and manual)

The README should use a teacher-to-student walkthrough and stable fictional
markers, never real project or personal data.

1. From the sample directory, source `./prepare.ps1` and start interactive Pi
   with a dedicated `./sessions/tree-lab` directory and a descriptive name.
2. Submit a common fictional request containing `HARBOR-17`, then develop
   `APPROACH-A`. Use `/session` and `pwsh ./inspect-tree.ps1` to observe that the
   session is initially linear.
3. Run `/tree`, select the `APPROACH-A` user message, choose branch
   summarization, and optionally focus it on decisions and constraints. Pi
   returns the selected user text to the editor; edit it to `APPROACH-B` and
   submit it. This creates a new path while the A path remains in the file.
4. Run `/tree` again to visit the A and B leaves. Demonstrate one no-summary
   navigation as well, so the learner sees that summarization is a choice and
   not a prerequisite for branching.
5. Run `/summary-audit status` and the inspector in both table and JSON forms.
   Observe a branch point, two leaves, the active path, and a
   `branch_summary` whose content is intentionally not displayed.
6. With the desired leaf active, run `/clone`. Inspect the new session: it has a
   new session ID, `parentSession` provenance, and only the selected root-to-leaf
   path. Continue it with a clone-only fictional marker.
7. Reopen the original, run `/fork`, select a prior user message, edit the text,
   and continue. Contrast its before-selected-message cut with clone's
   at-current-leaf cut. Do not re-teach startup `--fork` from sample 010.
8. Reopen the original chosen branch and run `/compact Keep fictional codes and
   the selected approach.` The sample-owned retention value makes this possible
   with a short conversation.
9. Inspect the appended compaction metadata. Restart Pi on that session and ask
   for the retained fictional facts to make the rebuilt summary-plus-suffix
   context visible. Generated wording is illustrative; structural verification
   remains the proof.

The manual path uses Pi's normal model-generated summaries. It must not require
the deterministic fixture mode described below.

## Pi 0.80.6 automation surface

Use only contracts present in the installed `0.80.6` types:

| Need | Feasible surface |
| --- | --- |
| Submit the minimal live turns | RPC `prompt`; wait for `agent_end`/idle and correlate command responses |
| Discover user entry IDs | RPC `get_fork_messages` or privacy-internal parsing in the verifier |
| Inspect append-order entries and active leaf | RPC `get_entries` returns `{ entries, leafId }` |
| Inspect nested children | RPC `get_tree` returns `{ tree, leafId }` |
| Navigate the in-file tree | No native RPC command exists in 0.80.6; invoke the extension command `/summary-audit navigate ...`, which calls command-context `ctx.navigateTree(...)` |
| Compact manually | RPC `compact` with optional `customInstructions` |
| Fork before a selected user message | RPC `fork { entryId }`; response includes `{ text, cancelled }` and the process switches to the new session |
| Clone the current leaf | RPC `clone`; response includes `{ cancelled }` and the process switches to the new session |
| Confirm the replacement session | RPC `get_state`, then inspect the new header and entries |
| Confirm rebuilt model messages | RPC `get_messages`; use only for internal assertions and never echo its content |

`get_entries` and `get_tree` return full entry content. They are safe only inside
the verifier. Human-facing output must pass through `inspect-tree.ps1`'s
allowlisted projection. Do not serialize raw RPC responses on success or include
them in thrown errors.

Extension slash commands sent as RPC `prompt` commands execute immediately.
The verifier command is therefore:

```text
/summary-audit navigate <entry-id> summary
/summary-audit navigate <entry-id> plain
/summary-audit checkpoint
```

The command validates an exact 8-hex-character entry ID and a fixed mode. It
calls `await ctx.navigateTree(entryId, { summarize: mode === "summary" })` and
throws on cancellation. It never accepts summary text, paths, or arbitrary JSON
from command arguments. `/summary-audit checkpoint` persists the current safe
audit records as one `custom` entry so the verifier can assert event order even
after a runtime replacement. `/summary-audit status` displays only counters and
short IDs in interactive mode.

## Privacy-safe inspector contract

`inspect-tree.ps1` accepts:

```text
-SessionFile <path>             # one explicit file
-SessionsDirectory <directory> # optional discovery root
-Format Table|Json             # Table by default
```

The path is an input, never an output field. The script parses every non-empty
JSONL line, validates a versioned session header, unique entry IDs, known
parents that occur earlier in append order, and exactly one logical root for a
non-empty session. Malformed files fail with a fixed safe reason plus only the
input file's basename.

JSON output is an object (or array when a directory is supplied) with this
allowlisted schema:

```json
{
  "SchemaVersion": 1,
  "Session": {
    "Id": "session UUID",
    "ParentSessionId": "UUID extracted from the parent filename or empty",
    "Version": 3,
    "EntryCount": 12,
    "RootCount": 1,
    "LeafCount": 2,
    "BranchPointCount": 1,
    "ActiveLeafIdPrefix": "a1b2c3",
    "ActivePathIdPrefixes": ["101abc", "202def", "a1b2c3"]
  },
  "Entries": [
    {
      "Sequence": 0,
      "IdPrefix": "101abc",
      "ParentIdPrefix": "",
      "Timestamp": "ISO-8601 timestamp",
      "Type": "message",
      "ChildCount": 1,
      "OnActivePath": true
    }
  ],
  "BranchSummaries": [
    {
      "IdPrefix": "303fed",
      "ParentIdPrefix": "202def",
      "FromIdPrefix": "909aaa",
      "FromExtension": true
    }
  ],
  "Compactions": [
    {
      "IdPrefix": "404bee",
      "ParentIdPrefix": "303fed",
      "FirstKeptEntryIdPrefix": "505ccc",
      "TokensBefore": 42,
      "FromExtension": true
    }
  ]
}
```

Pi entry IDs are eight hexadecimal characters in 0.80.6; expose the first six
characters and detect the unlikely case of a prefix collision. A collision is
a fixed safe error, not a reason to reveal more ID characters. Resolve the
active leaf as the last append-order entry, matching `SessionManager` reload
behavior, and walk its parent chain for `OnActivePath`.

The table view is a projection of the same parsed object, not a separate
parser. It may show sequence, short ID, short parent, type, children, and active
status, followed by aggregate counts. Both output modes must omit:

- user and assistant content, thinking, tool calls, arguments, and results;
- `summary`, `content`, `details`, and arbitrary `data` payloads;
- session names, custom-entry payloads, absolute paths, and source filenames;
- environment values, model credentials, and serialized parse exceptions.

The verifier captures both output forms and searches for every fictional marker,
the API key, the sample's absolute path, the temporary directory, and full raw
summary strings. None may occur.

## `summary-audit.ts` design

The extension has two modes:

- **Observe mode (default):** record safe event metadata in memory and let Pi
  generate summaries normally. This is the learner-facing behavior.
- **Fixture mode:** enabled only when `PI_SUMMARY_AUDIT_FIXTURE=1` is set by
  `verify.ps1`. Return deterministic summaries so structural assertions do not
  depend on generated prose or add summarization model calls.

The extension must not read prompts or serialize entries. Its in-memory record
is a monotonically increasing `sequence` plus an event name and the minimal
fields listed below. `/summary-audit checkpoint` may persist these already-safe
records with `pi.appendEntry("summary-audit-checkpoint", { schemaVersion: 1,
records })`; plain custom entries do not enter model context. On `session_start`,
the live counter starts fresh. Do not silently rebuild memory from abandoned
checkpoint entries.

### Exact event contracts

For `session_before_tree`, 0.80.6 supplies:

- `preparation.targetId`, `oldLeafId`, `commonAncestorId`;
- `preparation.entriesToSummarize` (record count only);
- `preparation.userWantsSummary`, `customInstructions`,
  `replaceInstructions`, and `label` (record booleans/presence only);
- `signal` (record `signal.aborted`; never retain the signal).

The handler may return `{ cancel: true }`, instruction/label overrides, or a
custom `{ summary: { summary, details } }`. This sample does not cancel normal
navigation. In fixture mode, and only when `userWantsSummary` is true, return:

```typescript
{
  summary: {
    summary: "SUMMARY-AUDIT BRANCH V1",
    details: { schemaVersion: 1, fixture: "branch" }
  }
}
```

For `session_tree`, record `newLeafId`, `oldLeafId`, whether `summaryEntry`
exists, its ID and `fromId` when present, and `fromExtension`. A summarized
fixture navigation must produce adjacent audit records
`session_before_tree -> session_tree`, with `fromExtension === true` and a
persisted `branch_summary.fromHook === true`.

There is a version-specific trap here: although the 0.80.6 documentation calls
`BranchSummaryEntry.fromId` the entry navigated from, the installed
`SessionManager.branchWithSummary()` writes the destination attachment ID (or
`"root"`) into that field. The verifier must assert the behavior of the
installed implementation: `fromId` is the branch summary's destination parent,
while the actual abandoned position is preserved by the audit record's
`session_before_tree.preparation.oldLeafId` and the following
`session_tree.oldLeafId`. Do not claim that stored `fromId` identifies the
abandoned leaf.

For `session_before_compact`, 0.80.6 supplies:

- `preparation.firstKeptEntryId`, `tokensBefore`, `isSplitTurn`;
- counts for `messagesToSummarize` and `turnPrefixMessages`;
- whether `previousSummary` exists;
- `branchEntries` (record count only), `customInstructions` (presence only),
  `reason`, `willRetry`, and `signal`.

The exact 0.80.6 `reason` union is `"manual" | "threshold" | "overflow"`;
`willRetry` is true only for overflow recovery. Fixture mode returns a valid
`CompactionResult` using the preparation's boundary and token count:

```typescript
{
  compaction: {
    summary: "SUMMARY-AUDIT COMPACTION V1",
    firstKeptEntryId: event.preparation.firstKeptEntryId,
    tokensBefore: event.preparation.tokensBefore,
    details: { schemaVersion: 1, fixture: "compaction" }
  }
}
```

For `session_compact`, record the compaction entry's ID,
`firstKeptEntryId`, `tokensBefore`, `fromExtension`, `reason`, and `willRetry`.
A fixture manual compaction must produce
`session_before_compact -> session_compact`, reason `manual`, retry false, and a
persisted `compaction.fromHook === true`.

Although all four fields exist in 0.80.6, normalize version-sensitive values at
the record boundary: unknown future reasons become `"unknown"`, and absent
optional booleans become false. Do not use this normalization to weaken the
0.80.6 assertions.

The extension must honor abort signals by checking `signal.aborted` before
returning a fixture summary. It should not start its own asynchronous model
request, write a sidecar log, or call UI methods unless `ctx.hasUI` is true.

## Exact automated verification flow

`pwsh ./verify.ps1` uses a unique directory under `sessions/verification/`,
sets fixture mode only in the child environment, and deletes the directory in
`finally`. It verifies the installed `pi` is `0.80.6`, required
`AZURE_PI_TEST_*` values exist, and `PI_CODING_AGENT_DIR` resolves to this
sample.

### Phase 1 — deterministic parser fixtures (no model)

Create minimal temporary version-3 JSONL fixtures containing synthetic IDs and
timestamps:

1. a linear tree;
2. a two-leaf tree with a branch-summary entry;
3. a compacted active path with older retained file history;
4. malformed JSON, duplicate IDs, an unknown parent, and a short-ID collision.

Run both inspector formats. Assert exact counts, active-path flags, summary and
compaction metadata, and fixed safe failures. Seed forbidden prompt, summary,
tool, custom-data, absolute-path, and credential-like markers in fields the
inspector must ignore and prove none are emitted.

These are parser contract tests only. They must not be presented as proof that
Pi produced a real tree.

### Phase 2 — smallest live-model tree

Start one RPC Pi process with the Azure model, the unique session directory,
no tools, no skills, no prompt templates, and no context files. Keep extensions
enabled so the sample-local audit extension auto-loads. Disable auto-compaction
through RPC to prevent a threshold race.

1. Prompt for a short exact reply to the fictional common marker `HARBOR-17`.
2. Prompt once for `APPROACH-A` and wait until the turn settles.
3. Call `get_entries`. Identify the A user entry by content internally, and
   capture the current leaf and source-file SHA-256.
4. Invoke `/summary-audit navigate <A-user-id> summary`. Then prompt an edited
   `APPROACH-B` alternative and wait for completion.
5. Call `get_tree` and `get_entries`. Assert one root, a genuine branch point,
   at least two leaves, the complete A path still exists, the B path is active,
   and exactly one `branch_summary` is on the B path with fixture marker,
   `fromHook: true`, and a `fromId` equal to its destination attachment parent.
   Assert the abandoned A leaf through the paired audit event instead.
6. Invoke `/summary-audit navigate <A-assistant-id> plain`. Assert the leaf
   moved without appending another `branch_summary`. Navigate back to the B leaf
   plainly so compaction tests the chosen path.
7. Checkpoint audit state. Assert the stored safe record sequence contains both
   before/after tree pairs in order and accurately distinguishes summarized
   from plain navigation.

Exact assistant prose is never asserted. Only successful stop reasons, stable
user markers, entry relationships, and extension fixture markers matter. Use a
bounded retry only for an exact assistant-marker miss, never for structural or
process failures.

### Phase 3 — manual compaction and reload

1. Send RPC `compact` with fixed custom instructions. The sample retention
   setting must yield a real `CompactionPreparation`; failure with "Nothing to
   compact" is a test failure, not a skip.
2. Assert the RPC result boundary and token count match the appended
   `compaction`; `firstKeptEntryId` exists on the active path and precedes the
   compaction; `tokensBefore > 0`; fixture marker and `fromHook: true` exist.
   With the documented retention value, also assert the before event reports a
   split turn with at least one `turnPrefixMessages` item. This exercises the
   edge without a large context or a second summarization model call.
3. Assert the source JSONL still contains entries before the kept boundary.
4. Use `get_messages` internally and assert one `compactionSummary` plus the
   retained suffix, while an older summarized marker is absent as an ordinary
   user/assistant message.
5. Checkpoint and assert the exact adjacent audit pair with reason `manual` and
   `willRetry: false`.
6. Shut down and reopen the same session in a fresh RPC process. Repeat the
   context assertions to prove rebuilding from disk, not merely in-memory
   mutation.

Threshold and overflow compaction are documented through their event values
but are not forced: manufacturing a model context overflow is slow, costly, and
provider-dependent.

### Phase 4 — clone and fork boundaries

Use fresh RPC processes reopened on the original source so session replacement
does not make the test order-dependent.

1. **Clone:** select the B leaf, capture the source hash, issue RPC `clone`, and
   capture the new `get_state`. Assert a different session ID/file, a header
   `parentSession` resolving to the source, an unchanged source hash, and a
   copied root-to-B-leaf path only. The abandoned A-only entries must be absent.
   Append a clone-only marker and prove it never enters the source.
2. **Fork:** reopen the source, choose the A user entry from
   `get_fork_messages`, capture the source hash, and issue RPC `fork`. Assert the
   returned `text` is the selected user text, the new file ends at that user's
   parent (the selected user entry itself is absent), provenance and new session
   ID are correct, and source bytes are unchanged. Submit edited fork-only text
   and prove it never enters the source or clone.

Check copied entry objects structurally rather than assuming copied lines have
new IDs: Pi preserves entry IDs for the extracted path and writes a new header
with a new session UUID. Ignore timestamps only where Pi legitimately creates
new header/label entries.

### Phase 5 — output privacy and cleanup

Run `inspect-tree.ps1` over every genuine session in table and JSON forms.
Assert expected aggregate structure, then scan the output for all conversation
markers, fixture summary text, API key, absolute paths, and custom checkpoint
fields. On success print one concise PASS line containing counts only. Always
close stdin, wait with a bound, kill the child tree if necessary, restore any
environment values changed by the verifier, and remove temporary sessions.

## Deterministic assertions

The verifier must prove, rather than infer, these invariants:

- every non-header entry has a unique ID and either a known parent or null root;
- moving the leaf never removes or rewrites an earlier entry;
- a second child (possibly the `branch_summary`) exists at the shared branch
  point and both alternatives remain reachable;
- summarized navigation appends a branch summary at the destination position;
- plain navigation appends no branch summary;
- the active path obtained by parent traversal agrees with RPC `leafId`;
- compaction appends after a valid kept boundary and leaves pre-boundary JSONL
  history present but absent from rebuilt ordinary messages;
- clone copies exactly the active path at its invocation point;
- fork copies exactly through the selected user's parent and returns the
  selected text for editing;
- clone/fork headers have new IDs and correct `parentSession`, while source
  hashes remain unchanged;
- before/after extension events are ordered and their persisted entry
  `fromHook` values agree with `fromExtension`;
- human-facing metadata contains none of the denylisted content.

## Edge cases to teach

- Selecting a user message in `/tree` moves the leaf to its parent and returns
  the message text for editing; selecting an assistant or other non-user entry
  moves the leaf to that entry.
- Selecting the root user message resets the leaf to null before resubmission.
- Navigating to the current leaf is a no-op and does not emit a tree event pair.
- A branch summary is attached at the destination position, not appended to the
  abandoned leaf. In installed 0.80.6, its stored `fromId` also names that
  destination attachment position; use the tree events' `oldLeafId` to identify
  the abandoned position.
- Tool results cannot be selected as compaction cut points; they stay with the
  assistant tool call that precedes them.
- When the retained suffix begins inside one turn, preparation reports
  `isSplitTurn` and puts the earlier part in `turnPrefixMessages`. The
  laboratory retention value intentionally demonstrates this with a small
  fixture; normal defaults require a genuinely large turn.
- Repeated compactions incorporate earlier summary context and may begin from
  the prior kept boundary.
- A session file can retain abandoned branches even though the model sees only
  the selected path.
- Forking, cloning, and compaction are not redaction. All can leave or duplicate
  sensitive conversation data on disk.
- Clone/fork replace the active runtime; extension in-memory state therefore
  restarts unless deliberately checkpointed in the session.
- Extension callbacks can cancel navigation or compaction. Cancellation and
  abort signaling are documented, while this focused sample's fixture handlers
  do not expose a cancellation exercise.
- RPC `get_entries`, `get_tree`, `get_messages`, and `get_fork_messages` expose
  conversation content and must not be treated as privacy-safe reporting APIs.

## Non-goals

- Reimplementing or terminal-driving Pi's interactive tree picker.
- Forcing threshold auto-compaction or context overflow.
- Building the reusable RPC controller taught in sample 015.
- Editing JSONL by hand in the learner flow or treating every stored field as a
  permanently stable public database API.
- Repeating sample 010's full session picker, startup `--fork`, continuation,
  and ephemeral-run lessons.
- Evaluating the literary quality of generated summaries.
- Redacting or securely deleting historical session content.

## Acceptance criteria

- The README accurately distinguishes `/tree`, `/fork`, `/clone`, `/compact`,
  branch summarization, and sample 010's startup `--fork`.
- The documented manual exercise creates and visits A and B branches through
  Pi's actual `/tree` picker and demonstrates normal model summarization.
- A real session contains at least two leaves, preserves both alternatives, and
  has separate `branch_summary` and `compaction` entries.
- `summary-audit.ts` implements all four 0.80.6 session event contracts, an
  observe-only default, verifier-only deterministic summaries, safe status and
  checkpoint commands, and guarded UI access.
- The inspector has one parser for table/JSON output, validates tree integrity,
  implements the allowlisted schema, and never emits conversation, summary,
  custom payload, credential, filename, or absolute-path content.
- `pwsh ./verify.ps1` passes parser fixtures, the minimal live-model tree, plain
  and summarized navigation, compaction plus disk reload, clone, fork, event
  ordering, source immutability, and privacy assertions.
- Verification uses a unique disposable session directory, bounded RPC waits,
  child cleanup, environment restoration, and one concise count-only PASS line.
- `settings.json` is intentionally a real file, preserves shared model defaults,
  and clearly documents its laboratory-only retention value.
- The standard `models.json`, `prepare.ps1`, and `prepare.sh` symlinks are
  present; `auth.json` contains no credentials.
- The sample is actually run after implementation, `git diff --check` passes,
  and no generated session, secret, or diagnostic artifact remains tracked.

## Implementation references for Pi 0.80.6

- Installed `docs/sessions.md`: `/tree`, `/fork`, `/clone`, and selection
  behavior.
- Installed `docs/compaction.md`: cut points, branch summaries, and extension
  hooks.
- Installed `docs/session-format.md`: version-3 entry schema and context
  reconstruction.
- Installed `docs/rpc.md` and `dist/modes/rpc/rpc-types.d.ts`: RPC commands,
  especially `get_entries`, `get_tree`, `compact`, `fork`, and `clone`.
- Installed `dist/core/session-manager.d.ts`: append-only tree, active branch,
  context builders, and path extraction.
- Installed `dist/core/extensions/types.d.ts`: exact session event and command
  context contracts.

Public documentation:

- [Pi sessions](https://pi.dev/docs/latest/sessions)
- [Pi compaction and branch summarization](https://pi.dev/docs/latest/compaction)
- [Pi session format](https://pi.dev/docs/latest/session-format)
- [Pi RPC mode](https://pi.dev/docs/latest/rpc)
