This is a project to study pi.dev agents. The purpose is creating
multiple samples that allows to understand the potentiality of the
instrument and the various usage mode.

# layout

- notebooks: that folder contains notebook in typescript that will explore basic usage of PI as SDK
- samples: we have in this folder direct examples on how to use pi as a command-line agent. Each sample should contain a `README.md` that explains its purpose and how to run it.
  Samples should use PowerShell (`pwsh`) for executable scripts and commands.
  Shared PowerShell helpers belong in modules at the root of `samples/`.

  Model configuration is centralized: `samples/models.json` and
  `samples/settings.json` live at the `samples/` root, and every sample keeps a
  symlink to each of them (`./models.json -> ../models.json`,
  `./settings.json -> ../settings.json`) so all samples share one model
  registry — unless a sample explicitly needs its own config, in which case it
  replaces the symlink with a real file and its `README.md` says so.

  Each sample also symlinks the two shared preparation scripts from the
  `samples/` root: `prepare.ps1` (PowerShell) and `prepare.sh` (bash). Both do
  the same thing — walk up from the current directory to find and load the
  `.env` variables, then set `PI_CODING_AGENT_DIR` to the current directory.
  The intended workflow is: `cd` into a sample directory in either shell,
  source the matching script (`. ./prepare.ps1` in PowerShell,
  `source ./prepare.sh` in bash — they must be sourced so the environment
  changes persist), and then run `pi` already configured for that sample.
  `prepare.ps1` reuses `samples/Env.psm1`; `prepare.sh` is its self-contained
  bash equivalent. New samples should add these four symlinks (`models.json`,
  `settings.json`, `prepare.ps1`, `prepare.sh`).
- docs: course material for learning Pi. Keep it current and point to the real
  samples and notebooks instead of duplicating their code. The CLI course is
  `docs/cli-samples.md`.
- wiki/samples.md: brief catalog of the samples and what each one teaches.
- wiki/session-memory.md: durable learnings from completed sessions; read it
  when continuing the sample-learning work.
- .codex/skills/record-sample-learning: local skill for recording completed
  sample learnings and keeping the course documentation current.

Azure configuration is stored in a `.env` file with these exact variable names:

```text
AZURE_PI_TEST_ENDPOINT=<Azure OpenAI endpoint>
AZURE_PI_TEST_DEPLOYMENT=<Azure deployment name>
AZURE_PI_TEST_API_KEY=<API key for the deployment>
AZURE_PI_TEST_DEPLOYMENT2=<optional second deployment name>
```

Samples must use these `AZURE_PI_TEST_*` names. Sourcing a sample's
`prepare.ps1` / `prepare.sh` loads them, and the shared `samples/models.json`
registers an OpenAI-compatible provider whose key is read from
`AZURE_PI_TEST_API_KEY`. `AZURE_PI_TEST_DEPLOYMENT` and
`AZURE_PI_TEST_DEPLOYMENT2` are passed directly as model IDs.

See the [sample catalog](wiki/samples.md) for a brief explanation of each
sample and the [session memory](wiki/session-memory.md) for durable context.

# rules

- Always try to run the sample before considering completed
- Do not overengineer the sample, keep it simple and focused on the purpose of the sample
- Add enought documentation to be instructive, the purpose is creating somethign that a developer uses to learn how to use pi.dev agents, it should have a teacher to student tone
