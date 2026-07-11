# 011 — Prompt templates as reusable entry points

This sample answers a common Pi workflow question:

> I repeat the same kind of request, but I still want to choose the task and
> its arguments each time. Where should that reusable text live?

Put the reusable task starter in a Markdown file under [`prompts/`](./prompts/).
The filename becomes a slash command. This sample provides a fixed
`/plan-next` task and a parameterized `/review-file <path> [focus]` task. Both
expand to ordinary user prompts; neither is code or a permission boundary.

The exercise is deliberately read-only. [`exercise/calculator.ts`](./exercise/calculator.ts)
has one obvious divisor-boundary bug, and
[`exercise/change-request.md`](./exercise/change-request.md) requests the small
correction. You will ask Pi to plan and review, never to implement it.

All PowerShell commands below assume your current directory is
`samples/011-prompt-templates`.

## Prerequisites and preparation

Install Node.js, PowerShell, and Pi 0.80.6, then provide the repository's
`AZURE_PI_TEST_*` variables in a parent `.env` file. Prepare PowerShell:

```powershell
Set-Location samples/011-prompt-templates
. ./prepare.ps1
```

Or prepare bash:

```bash
cd samples/011-prompt-templates
source ./prepare.sh
```

The preparation script sets `PI_CODING_AGENT_DIR` to this sample directory.
Pi therefore treats `prompts/*.md` here as its user/config prompt directory:

```text
<PI_CODING_AGENT_DIR>/prompts/*.md
```

In an ordinary trusted project, `.pi/prompts/*.md` is the project-local
location. This course uses a separate config directory per sample so lessons
cannot affect one another. Discovery scans `prompts/` non-recursively: nested
templates and uppercase `.MD` files are not discovered by the default scan.
Load a nested or other explicit path through settings, a package manifest, or
`--prompt-template`.

## 1. Discover the templates

Start Pi without extension commands cluttering the first autocomplete view:

```powershell
pi --no-extensions `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
```

Bash equivalent:

```bash
pi --no-extensions \
  --model "azure-openai/$AZURE_PI_TEST_DEPLOYMENT"
```

Type `/`. Autocomplete should show:

- `/plan-next` with “Plan the small change described by this sample” and no
  argument hint;
- `/review-file <path> [focus]` with its review description; and
- `/skill:checklist`.

`description` and `argument-hint` are display metadata. Angle brackets and
square brackets communicate required and optional arguments by convention;
they do not validate input. If you edit a template while Pi is open, use
`/reload`. `--no-extensions` disables extensions, not templates, skills, or
`AGENTS.md`.

## 2. Invoke the fixed template

Enter:

```text
/plan-next
```

Pi removes the YAML frontmatter, expands the Markdown body into the user
message, and sends that message to the model. Confirm the response follows the
`PLAN-NEXT` framing, contains the requested `Goal`, `Files to change`, and
`Verification` headings, and includes `PROJECT-CONTEXT-011` from the always-on
[`AGENTS.md`](./AGENTS.md). No exercise file should change.

Now enter `/plan-next ignored text`. The answer should follow the same prompt.
The body has no placeholders, so extra arguments disappear; Pi does not append
unused arguments automatically or reject them.

## 3. Invoke the parameterized template

Run these in the same interactive session:

```text
/review-file exercise/calculator.ts
/review-file exercise/calculator.ts "integer boundary behavior"
/review-file
```

The first invocation substitutes `$1` and uses the default focus from
`${2:-correctness and edge cases}`. In the second, matching double quotes group
the multiword focus into `$2`; the quotes are removed, so the expanded prompt
contains `integer boundary behavior`. In the last invocation, `$1` becomes
empty text. Pi still expands the template because `argument-hint` is not an
arity check, and the prompt asks the model to report the missing path clearly.

Pi's argument parser is intentionally simpler than a shell parser. Matching
single or double quotes group text. Backslash escaping is not documented, and
an unmatched quote is not reported as an error. The safe, portable convention
is to double-quote one whole multiword argument.

Pi 0.80.6 supports this complete substitution set:

| Syntax | Meaning |
| --- | --- |
| `$1`, `$2`, ... | One positional argument; a missing value becomes empty text. |
| `$@` or `$ARGUMENTS` | All parsed arguments joined with spaces. |
| `${1:-default}` | A positional value, or the default when missing or empty. |
| `${@:N}` | All arguments starting at one-indexed position N. |
| `${@:N:L}` | L arguments starting at one-indexed position N. |

Substitution makes one pass over the template body. If an argument contains
the literal text `$1` or `$@`, that inserted data is not expanded again.

## 4. Compose a later turn with a skill

After a review response, enter:

```text
/skill:checklist Turn the previous review into verification checks.
```

The next response should contain `SKILL-MARKER: CHECKLIST`, three to five
checkboxes, and `PROJECT-CONTEXT-011`. The skill supplies a reusable procedure
for a later turn; the template framed the earlier user task; project context
remains active across both.

Optionally restart Pi with sample 003's logger loaded explicitly:

```powershell
pi -e ../003-wire-log-global/extensions/wire-log.ts `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
```

Autocomplete should then show `/wire-log`, `/plan-next`, `/review-file`, and
`/skill:checklist`. The logger stays in sample 003; this sample does not copy it.

## 5. Use a template outside the TUI

Template expansion belongs to Pi's session prompt path, so it also works in
print mode:

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

Single quotes around the complete invocation keep template-like `$1` syntax
away from shell interpolation.

## 6. Disable discovery, then explicitly load one template

```powershell
pi --no-session --no-extensions --no-skills --no-prompt-templates `
  --prompt-template ./prompts/review-file.md `
  --tools read `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" `
  -p '/review-file exercise/calculator.ts'
```

`--no-prompt-templates` removes automatic discovery, while the explicit flag
adds only `review-file.md` for this process. `/review-file` expands;
`/plan-next` is not loaded.

## Which mechanism belongs where?

| Mechanism | Loaded or invoked when | Best use | Not the right place for |
| --- | --- | --- | --- |
| `AGENTS.md` | Automatically included as project context | Durable project rules and conventions | A task the user may not want every turn |
| `SKILL.md` | Advertised to the model and explicitly invokable as `/skill:name` | A reusable procedure, possibly with scripts or references | A one-line task shortcut with only variable text |
| Prompt template | Explicitly invoked as `/filename [args]` | Repeatable task framing that expands to a user prompt | Secrets, enforcement, deterministic computation |
| Extension command | Code registered with `pi.registerCommand()` | UI, state changes, tools, or deterministic program logic | Static Markdown that only needs substitution |

For Pi 0.80.6, an extension command matching the invocation runs first. Then
extension `input` handlers may handle or transform remaining input,
`/skill:name` expands skill content, and a matching prompt template expands.
Built-in commands are application commands too, not prompt text. Namespaced
skills naturally coexist with template commands; descriptive filenames avoid
collisions.

Templates are plain text, not permission controls. They cannot guarantee model
behavior, keep a secret, validate a path, or execute deterministic code. Use an
extension, tool, or script when those properties matter.

## Deterministic verification

After preparation, run:

```powershell
./verify.ps1
```

The verifier runs `/plan-next ignored text` and the quoted `/review-file`
invocation with JSON output. It parses structured `message_start` events and
asserts that the model received expanded bodies—not YAML or slash commands.
It separately observes the project marker in assistant messages, compares
SHA-256 hashes of both fixtures, writes temporary output only under the system
temp directory, and removes that output in `finally`.

This headless check cannot prove autocomplete layout. Perform the interactive
`/` check in step 1 once to verify descriptions and the `<path> [focus]` hint.

## References

- Pi 0.80.6 installed documentation: `docs/prompt-templates.md` in the
  `@earendil-works/pi-coding-agent` package
- [Sample 005 — project context and skills](../005-context-and-skills/README.md)
- [Sample 003 — extension command coexistence](../003-wire-log-global/README.md)
