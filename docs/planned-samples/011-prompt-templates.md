# 011 — Prompt templates as reusable entry points

## Outcome

Teach prompt templates as small, named task starters. The learner will create
one no-argument template and one parameterized template, invoke both from the
TUI and print mode, inspect the exact expanded prompt, and explain why neither
template belongs in `AGENTS.md`, a skill, or an extension command.

The finished sample should answer this practical question:

> I repeat the same kind of request, but I still want to choose the task and
> its arguments each time. Where should that reusable text live?

For this sample, the answer is a Markdown file under `prompts/` whose filename
becomes a slash command.

## Files to implement

Create a standalone sample with this exact shape:

```text
samples/011-prompt-templates/
├── README.md
├── AGENTS.md
├── exercise/
│   ├── calculator.ts
│   └── change-request.md
├── prompts/
│   ├── plan-next.md
│   └── review-file.md
├── skills/
│   └── checklist/
│       └── SKILL.md
├── verify.ps1
├── models.json   -> ../models.json
├── settings.json -> ../settings.json
├── prepare.ps1   -> ../prepare.ps1
└── prepare.sh    -> ../prepare.sh
```

The exercise files are tiny, read-only inputs. `calculator.ts` should contain
one obvious boundary bug, and `change-request.md` should request one small
change to that calculator. They make the two templates useful without turning
the sample into a generic prompt library.

The four shared files must be real symlinks with exactly the targets above.
Do not add a package, npm dependencies, an extension of this sample's own, a
template compiler, or generated prompt copies.

`PI_CODING_AGENT_DIR` matters here just as it did for extensions in sample 003.
After sourcing `prepare.ps1` or `prepare.sh`, Pi's config directory is this
sample, so its user/config prompt location is:

```text
<PI_CODING_AGENT_DIR>/prompts/*.md
    = samples/011-prompt-templates/prompts/*.md
```

No `--prompt-template` flag or `.pi/prompts/` directory is required for the
normal lesson. Mention that `.pi/prompts/` is Pi's trusted project-local
location in an ordinary project, while this course uses a per-sample config
directory to keep every lesson isolated.

## Exact content contracts

### `AGENTS.md`

Keep the always-on project policy short and visibly independent of the
templates:

- the sample is read-only: do not create, edit, or delete files;
- analyze only the files under `exercise/` unless the user asks otherwise; and
- include the marker `PROJECT-CONTEXT-011` once in every answer.

The marker gives verification an observable signal that project context still
applies after template expansion. It must not prescribe the plan/review shape;
that task-specific framing belongs in the templates.

### `prompts/plan-next.md`

This is the no-argument template. Use exactly the supported Pi frontmatter
field `description`; omit `argument-hint` because the command takes no input.
Its implementation should be equivalent to:

```markdown
---
description: Plan the small change described by this sample
---
TEMPLATE-MARKER: PLAN-NEXT

Read exercise/change-request.md and the relevant code under exercise/.
Produce a short implementation plan with exactly these headings:

## Goal
## Files to change
## Verification

Do not modify files.
```

The filename exposes `/plan-next`. Any arguments supplied accidentally are
ignored because the body contains no placeholders; the README must call that
out rather than implying Pi validates arity.

### `prompts/review-file.md`

This template demonstrates one required-looking positional argument and one
optional argument with a default:

```markdown
---
description: Review one local file with a chosen focus
argument-hint: "<path> [focus]"
---
TEMPLATE-MARKER: REVIEW-FILE

Review the local file at `$1`.
Focus on: `${2:-correctness and edge cases}`.

Return exactly these sections:

## Findings
## Suggested checks

Do not modify files. If the path is empty or cannot be read, say so clearly.
```

The filename exposes `/review-file`. The canonical exercise invocations are:

```text
/review-file exercise/calculator.ts
/review-file exercise/calculator.ts "integer boundary behavior"
```

Quotes group a multiword focus into `$2` and are removed during substitution.
The first command uses the default focus. The second produces
`integer boundary behavior` without quotes in the expanded prompt.

`argument-hint` only changes autocomplete display. It does not enforce a
required argument, so `/review-file` expands `$1` to an empty string and must
lead to the template's clear missing-path response.

### `skills/checklist/SKILL.md`

Add a minimal skill solely to demonstrate composition. Its valid YAML
frontmatter should use:

```yaml
name: checklist
description: Turn an existing plan or review into a short verification checklist when the user explicitly asks for one.
```

The body should require the marker `SKILL-MARKER: CHECKLIST`, three to five
checkbox items, and no file changes. It must not repeat either template or
contain scripts. The interactive flow invokes it as `/skill:checklist` after a
template turn, showing that the skill is a reusable procedure applied on a
later turn while `AGENTS.md` remains active.

### Exercise fixtures

Keep both fixtures under roughly 20 lines:

- `change-request.md` asks to make a calculator division operation reject a
  zero divisor and name a verification case;
- `calculator.ts` contains a tiny `divide(a, b)` implementation with an
  intentionally incorrect zero check, such as testing `b < 0` instead of
  `b === 0`.

The learner is asked only to plan and review. `AGENTS.md` and both templates
must say not to implement the fix.

## Pi 0.80.6 template behavior to teach

### Discovery and frontmatter

- Pi scans `prompts/*.md` non-recursively.
- The filename without the lowercase `.md` suffix is the command name;
  `review-file.md` becomes `/review-file`.
- `description` controls autocomplete text. Without it, Pi uses the first
  non-empty body line, truncated for display.
- `argument-hint` is optional display metadata. Use angle brackets and square
  brackets by convention, but neither form validates arguments.
- YAML frontmatter is removed before the body is sent to the model.
- Subdirectories and uppercase `.MD` files are not discovered by the default
  directory scan. A nested directory must be loaded explicitly through
  settings, a package manifest, or `--prompt-template`.

### Arguments

Document the complete supported substitution set, but use only `$1` and
`${2:-default}` in the learning templates:

| Syntax | Meaning |
| --- | --- |
| `$1`, `$2`, ... | one positional argument; missing values become empty text |
| `$@` or `$ARGUMENTS` | all parsed arguments joined with spaces |
| `${1:-default}` | positional value, or the default when missing/empty |
| `${@:N}` | all arguments starting at 1-indexed position N |
| `${@:N:L}` | L arguments starting at position N |

Pi 0.80.6 groups text inside matching single or double quotes. It does not
implement a full shell parser: quotes are removed, backslash escaping is not a
documented feature, and an unmatched quote is not reported as an error. Teach
the safe, portable convention of double-quoting a whole multiword argument.

Substitution is one pass over the template body. An argument containing the
literal characters `$1` or `$@` is inserted as data and is not expanded again.
Extra arguments are not automatically appended; a template must reference
`$@`, `$ARGUMENTS`, or a slice to retain them.

### Expansion and precedence

A template expands only when the submitted message starts exactly with
`/name` and the name matches a loaded template. The expanded Markdown becomes
the user prompt; the model does not receive the slash invocation itself.

For Pi 0.80.6, teach this relevant order:

1. a matching extension command is executed first;
2. extension `input` handlers may handle or transform remaining input;
3. `/skill:name` is expanded to skill content; and
4. a matching prompt template is expanded and sent to the agent.

Therefore an extension command with the same invocation name wins over a
template. Skills normally use the namespaced `/skill:name` form, so
`/skill:checklist` and `/review-file` coexist naturally. Built-in commands are
also application commands rather than prompt text. Avoid collisions by using
descriptive template filenames; this sample must not deliberately create one.

## Comparison the README must include

| Mechanism | Loaded or invoked when | Best use | Not the right place for |
| --- | --- | --- | --- |
| `AGENTS.md` | automatically included as project context | durable project rules and conventions | a task the user may not want every turn |
| `SKILL.md` | advertised to the model and explicitly invokable as `/skill:name` | a reusable procedure, possibly with scripts/references | a one-line task shortcut with only variable text |
| Prompt template | explicitly invoked as `/filename [args]` | repeatable task framing that expands to a user prompt | secrets, enforcement, deterministic computation |
| Extension command | code registered with `pi.registerCommand()` | UI, state changes, tools, or deterministic program logic | static Markdown that only needs substitution |

Also state that templates are plain text, not permission controls. They cannot
guarantee model behavior, keep a secret, validate a path, or run deterministic
code. Use an extension/tool/script for those needs.

## README teaching flow

### 1. Prepare and discover the templates

PowerShell first:

```powershell
Set-Location samples/011-prompt-templates
. ./prepare.ps1
pi --no-extensions `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
```

Bash equivalent:

```bash
cd samples/011-prompt-templates
source ./prepare.sh
pi --no-extensions \
  --model "azure-openai/$AZURE_PI_TEST_DEPLOYMENT"
```

Type `/` and verify that autocomplete lists `/plan-next` with its description
and `/review-file <path> [focus]` with its argument hint. `/skill:checklist`
should also appear. If a template is edited while Pi is open, use `/reload`.

`--no-extensions` keeps unrelated extension commands out of the first view;
it does not disable templates, skills, or `AGENTS.md`.

### 2. Invoke the no-argument template

Enter `/plan-next`. Verify the answer contains the three requested headings,
the `PLAN-NEXT` task marker or otherwise visibly follows that framing, and the
always-on `PROJECT-CONTEXT-011` marker. Confirm no file changed.

Then invoke `/plan-next ignored text` and explain that the extra words do not
reach the model because this template has no argument placeholder.

### 3. Invoke the parameterized template

Run both canonical `/review-file` invocations. The first should focus on the
default `correctness and edge cases`; the second should use the quoted custom
focus as a single `$2` value. Run `/review-file` with no path once to prove the
autocomplete hint is not validation.

### 4. Compose with a skill and optional extension command

After a review response, enter:

```text
/skill:checklist Turn the previous review into verification checks.
```

The response should include the skill marker and project marker. This shows a
new user turn can select a skill without removing the project rules or changing
what the earlier template did.

For an optional command-composition demonstration, restart with sample 003's
wire logger loaded explicitly:

```powershell
pi -e ../003-wire-log-global/extensions/wire-log.ts `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
```

The autocomplete list should contain `/wire-log`, `/plan-next`,
`/review-file`, and `/skill:checklist`. Do not copy that extension into this
sample.

### 5. Use the same template in print/JSON mode

Slash-template expansion is performed by the session prompt path, not only by
the TUI editor. Demonstrate it directly:

PowerShell:

```powershell
pi --no-session --no-extensions --tools read `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" `
  -p '/review-file exercise/calculator.ts "integer boundary behavior"'
```

Bash:

```bash
pi --no-session --no-extensions --tools read \
  --model "azure-openai/$AZURE_PI_TEST_DEPLOYMENT" \
  -p '/review-file exercise/calculator.ts "integer boundary behavior"'
```

Use single quotes around the complete invocation in both shells so `$1`-style
syntax remains a template concern, not shell interpolation.

### 6. Isolate discovery from explicit loading

Show the difference between disabling discovery and explicitly loading one
file:

```powershell
pi --no-session --no-extensions --no-skills --no-prompt-templates `
  --prompt-template ./prompts/review-file.md `
  --tools read `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" `
  -p '/review-file exercise/calculator.ts'
```

`--no-prompt-templates` removes automatically discovered templates;
`--prompt-template` adds the named file for this run. `/review-file` expands,
while `/plan-next` is not loaded.

## Deterministic verification

`verify.ps1` should verify resource loading and expansion rather than judging
the model's prose. It must:

1. require the prepared Azure variables and fail with a helpful message if
   they are missing;
2. create a temporary directory under the platform temp directory, not inside
   the sample;
3. run Pi with `--mode json`, `--no-session`, `--no-extensions`, and
   `--tools read` for `/plan-next` and the quoted `/review-file` invocation;
4. capture JSON Lines output separately for both runs;
5. parse JSON rather than searching arbitrary assistant text;
6. locate the emitted user message content and assert that frontmatter and the
   slash invocation are absent while template markers, substituted path,
   custom focus, and `PROJECT-CONTEXT-011`-driven behavior are observable;
7. assert the exercise files' hashes are unchanged; and
8. remove temporary output in `finally`, returning nonzero on any failed
   assertion.

Because provider output is nondeterministic, the strongest deterministic
assertion is the expanded user message recorded in JSON events/session data.
The project marker is an integration observation in the assistant response,
not proof of expansion. If Pi's JSON event stream in 0.80.6 does not expose the
user message clearly enough, the implementer may instead use a temporary
session file and parse its user-message entry, but must still inspect structured
JSON and clean it up.

Run it after preparation:

```powershell
./verify.ps1
```

The implementer must also perform one interactive autocomplete check because a
headless assertion cannot prove how descriptions and argument hints render.

## Verification matrix

| Case | Invocation | Expected evidence |
| --- | --- | --- |
| Auto-discovery | source prepare, start Pi, type `/` | both templates appear without `--prompt-template` |
| Metadata | inspect autocomplete | descriptions appear; review hint is `<path> [focus]`; plan has no hint |
| No-arg expansion | `/plan-next` | expanded user message has marker and fixed exercise path, no frontmatter |
| Ignored extra args | `/plan-next ignored text` | expanded prompt is identical to `/plan-next` |
| Default argument | `/review-file exercise/calculator.ts` | expanded prompt contains default focus |
| Quoted argument | `/review-file exercise/calculator.ts "integer boundary behavior"` | `$2` becomes the full phrase without quotes |
| Missing required-looking argument | `/review-file` | expansion occurs with empty path; no validation error from Pi |
| Project composition | invoke either template | `AGENTS.md` read-only rule remains effective and project marker appears |
| Skill composition | `/skill:checklist ...` after review | skill and project markers appear; templates remain available |
| Extension coexistence | load sample 003 extension | wire-log, template, and skill commands all appear |
| Print expansion | `-p '/review-file ...'` | same expanded task works without TUI |
| Explicit-only load | disable discovery, load review file | review expands; plan remains an ordinary unmatched slash message |
| Non-recursive boundary | place no nested fixture in final sample; document behavior | README correctly states nested templates are not auto-discovered |
| Read-only invariant | hash fixtures before/after checks | hashes match; no generated sample-local files remain |

Do not treat a plausible assistant answer as proof that a template expanded.
Verification must inspect the structured expanded user message or an equivalent
authoritative session entry.

## Acceptance criteria

- [ ] `samples/011-prompt-templates` contains the exact files and four shared
      symlinks described above.
- [ ] Both `.md` files are auto-discovered from the sample config's `prompts/`
      directory on Pi 0.80.6.
- [ ] `/plan-next` has `description` frontmatter, no argument hint, no
      placeholders, and a stable task marker.
- [ ] `/review-file` has `description`, the exact `<path> [focus]` hint, `$1`,
      a `${2:-...}` default, and a stable task marker.
- [ ] The README explains that hints do not validate, missing positions become
      empty, quotes group arguments, substitution is one-pass, and unused
      arguments disappear.
- [ ] The README accurately explains config/user versus trusted project prompt
      locations and non-recursive discovery.
- [ ] The comparison among `AGENTS.md`, skills, templates, and extension
      commands is present and includes invocation/precedence behavior.
- [ ] Interactive checks prove autocomplete descriptions/hints and successful
      use of both templates.
- [ ] Print mode proves template expansion is not TUI-only.
- [ ] The checklist skill composes in the same session without replacing
      project instructions.
- [ ] `verify.ps1` inspects structured expansion evidence, protects fixture
      hashes, cleans temporary data, and exits nonzero on failure.
- [ ] The sample remains read-only during verification and contains no secrets,
      policies masquerading as enforcement, or deterministic logic in prompts.
- [ ] The implemented sample is added to `docs/cli-samples.md` and
      `wiki/samples.md`, session learnings are recorded, and
      `git diff --check` passes.

## Primary references for implementation

- Pi 0.80.6 local documentation:
  `@earendil-works/pi-coding-agent/docs/prompt-templates.md`.
- Pi 0.80.6 local implementation:
  `dist/core/prompt-templates.js` and the prompt expansion path in
  `dist/core/agent-session.js`.
- [Sample 005 — project context and skills](../../samples/005-context-and-skills/README.md)
- [Sample 003 — optional extension-command coexistence](../../samples/003-wire-log-global/README.md)

