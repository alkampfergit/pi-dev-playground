# 005 — Project instructions and two simple skills

This sample separates two lightweight ways to guide Pi:

- [`AGENTS.md`](./AGENTS.md) is always-on project context. It tells Pi that the
  user is **Gian Maria Ricci**, to greet him before the first response of each
  session, and not to modify files.
- [`skills/haiku/SKILL.md`](./skills/haiku/SKILL.md) is a tiny, reusable
  procedure. It tells Pi how to answer a request for a haiku.
- [`skills/encrypt/SKILL.md`](./skills/encrypt/SKILL.md) explains how to run the
  bash and PowerShell ROT13 scripts kept in its `scripts/` subdirectory.

The skill is intentionally simple so the behavior is easy to see. It has no
scripts, dependencies, or tools.

All commands assume your current PowerShell directory is:

```text
samples/005-context-and-skills
```

## Prerequisites and preparation

Use the same prerequisites as the earlier samples: Node.js, npm, PowerShell,
Pi, and the repository `.env` containing the `AZURE_PI_TEST_*` variables.

Load the sample environment into the current PowerShell session:

```powershell
. ./prepare.ps1
```

Or in bash:

```bash
source ./prepare.sh
```

## 1. Use the skill interactively

`--skill` explicitly loads this one local skill. `--no-skills` prevents any
other discovered skills from changing the demonstration. Start Pi, then type a
request at the prompt:

```powershell
pi --no-extensions --no-skills --skill ./skills/haiku `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
```

At the Pi prompt, enter:

```text
Write a haiku about the sea.
```

Observe two things in the first answer: it starts with `Hello Gian Maria Ricci!`
because `AGENTS.md` is project context, then it contains exactly three poetic
lines because Pi loaded the matching `haiku` skill. A later haiku request in
the same session should follow the skill but not greet again.

## 2. Use the same skill with `-p`

`-p` runs one prompt and exits. The same explicit skill path works unchanged:

```powershell
pi --no-extensions --no-skills --skill ./skills/haiku `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" `
  -p 'Write a haiku about Rome.'
```

Because this is a new session, the output again begins with the greeting. This
is useful for scripts and automation: use the same project instructions and
the same skill without opening the interactive UI.

## 3. Use a skill that runs a shell command

The second skill is still intentionally small, but it gives Pi a concrete bash
or PowerShell command to run. ROT13 is an educational reversible substitution,
**not encryption**.

Use the bash version in print mode:

```powershell
pi --no-extensions --no-skills --skill ./skills/encrypt --tools read,bash `
  --model "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" `
  -p 'Use the encrypt skill and its bash script to encode Hello, Gian Maria!'
```

The skill explains how to invoke the PowerShell script. In an interactive
session, start Pi with the same flags, then ask: `Use the encrypt skill and its
PowerShell script to encode Hello, Gian Maria!` The model can run the
appropriate command through Pi's `bash` tool; `pwsh` is available from that
shell when PowerShell is installed.

Run either command again on the encoded text to decode it. ROT13 is its own
inverse.

## What each file contributes

| File | Loaded when | Purpose |
| --- | --- | --- |
| `AGENTS.md` | Pi starts in this directory or a child directory | Persistent project rules, including the greeting. |
| `skills/haiku/SKILL.md` | Explicitly selected with `--skill ./skills/haiku` | A focused workflow only relevant to haiku requests. |
| `skills/encrypt/SKILL.md` | Explicitly selected with `--skill ./skills/encrypt` | Usage instructions for the bash and PowerShell scripts in `skills/encrypt/scripts/`. |

Try running the print command once with `--no-context-files`: the greeting and
read-only project rule disappear, while the explicit skill still remains. This
is the clearest way to see that an `AGENTS.md` file and a skill have different
jobs.

## References

- [Pi context files](https://pi.dev/docs/latest/usage)
- [Pi skills](https://pi.dev/docs/latest/skills)
