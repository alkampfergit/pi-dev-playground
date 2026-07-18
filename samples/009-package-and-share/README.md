# 009 — Package and share

This sample turns two resources you have already met into one installable Pi
package. It bundles a simplified version of sample 003's `/wire-log` extension
and sample 005's `haiku` skill, then proves that Pi can install, discover, and
remove both without calling a model.

Packaging changes the distribution mechanism, not the extension's runtime
design. The logger still starts disabled, creates `dump/` lazily, and records
only provider requests and responses while enabled.

## The Pi functionality this sample explains

Pi packages are a way to distribute a small, named collection of Pi resources
as one unit. A package is an ordinary directory (or an npm or Git source) with
a `package.json` manifest. Its `pi` section tells Pi which extension files,
skills, prompts, and themes it contributes.

When you run `pi install <source>`, Pi records that package source in the
active configuration's `settings.json`. It does not merge the extension into
your configuration or turn the skill into a copy owned by Pi. Each new Pi
process reads the installed package list, reads the manifest, and discovers the
declared resources. In this sample that discovery makes two things available:

- `/wire-log`, an extension command that can record provider traffic when you
  enable it;
- `/skill:haiku`, a skill whose instructions Pi can apply when you invoke it.

`pi remove <source>` removes the package reference. A Pi process that starts
afterwards no longer discovers either resource. This install → startup
discovery → removal cycle is the underlying functionality that the verifier
tests. The package is only a distribution and discovery mechanism; extensions
remain executable code and skills remain instruction files.

## Two roots with different jobs

The outer `009-package-and-share/` directory is the **sample root**. Its README,
preparation links, and verifier teach the exercise. The inner `package/`
directory is the **package root** and is the only directory another Pi setup
would install:

```text
009-package-and-share/
├── README.md
├── verify.ps1
└── package/
    ├── package.json
    ├── extensions/wire-log.ts
    └── skills/haiku/SKILL.md
```

Inspect `package/package.json` first. Its important fields are:

- `keywords: ["pi-package"]`, the documented package marker;
- `private: true`, which prevents accidental npm publication;
- a `"*"` peer dependency on Pi, because Pi supplies the API imported by the
  extension;
- `pi.extensions` and `pi.skills`, whose paths are relative to the package
  root and explicitly declare the resources Pi should load.

A complete manifest can also have `prompts` and `themes` arrays. They are
omitted here because this package contains neither. Keeping the manifest honest
is more instructive than advertising resources that do not exist.

## Run the safe proof

From any directory, run:

```powershell
pwsh -File ./samples/009-package-and-share/verify.ps1
```

Or, after changing into this sample:

```powershell
./verify.ps1
```

The verifier needs `pi` on `PATH`, but it does not need Azure credentials,
network access, interactive input, or a model response. It:

1. creates a uniquely named temporary Pi config and empty working directory;
2. installs the absolute `package/` path at user scope in that temporary config;
3. checks `settings.json` and `pi list`;
4. starts a fresh RPC process and sends `{"type":"get_commands"}`;
5. asserts `/wire-log` and `/skill:haiku` have the expected type and source file;
6. removes the same absolute path and checks both commands disappear in another
   fresh RPC process;
7. restores the caller's environment and removes only its sentinel-protected
   temporary directory.

`get_commands` reports what Pi discovered; it does not invoke a command or send
a prompt. That makes it an exact, model-free package test. The second RPC
process after removal is essential because Pi discovers resources at startup:
editing settings does not unload code from an already-running process.

## What a local install means

`pi install /absolute/path/to/package` records a reference to that source in the
selected `settings.json`. Pi 0.80.6 serializes the reference relative to the
settings file when possible, even though the install and list output resolve it
to the original absolute path. It does **not** copy the package. Later Pi
processes load files from the original directory, so edits there affect the
next process. The verifier resolves the stored reference canonically and checks
that no local-package copy appeared in the config's `npm/` or `git/` cache.

This also explains why removal needs the same canonical absolute source string
used for installation.

## Normal preparation versus package installation

Like every course sample, this directory has the shared preparation links:

```powershell
cd samples/009-package-and-share
. ./prepare.ps1
```

```bash
cd samples/009-package-and-share
source ./prepare.sh
```

Preparation makes the sample a normal Pi configuration by setting
`PI_CODING_AGENT_DIR` to this directory. However, its `settings.json` is a
symlink to the course-wide shared settings. Manually running `pi install` after
preparation would therefore change that shared file. Use `./verify.ps1` for the
safe lesson; it overrides the variable with a disposable configuration.

## Equivalent manual flow

If you want to see the mechanics yourself, create the isolation deliberately.
Run this from the sample directory in PowerShell:

```powershell
$oldAgentDir = $env:PI_CODING_AGENT_DIR
$hadAgentDir = Test-Path Env:PI_CODING_AGENT_DIR
$oldOffline = $env:PI_OFFLINE
$hadOffline = Test-Path Env:PI_OFFLINE
$scratch = Join-Path ([IO.Path]::GetTempPath()) "pi-package-demo-$([guid]::NewGuid())"
$package = (Resolve-Path ./package).Path

try {
    $agent = New-Item -ItemType Directory -Path (Join-Path $scratch agent)
    $work = New-Item -ItemType Directory -Path (Join-Path $scratch work)
    $env:PI_CODING_AGENT_DIR = $agent.FullName
    $env:PI_OFFLINE = "1"
    Push-Location $work.FullName

    pi install $package --no-approve
    pi list --no-approve
    '{"id":"commands","type":"get_commands"}' |
        pi --mode rpc --no-session --offline --no-approve
    pi remove $package --no-approve
    pi list --no-approve
}
finally {
    if ((Get-Location).Path -eq $work.FullName) { Pop-Location }
    if ($hadAgentDir) { $env:PI_CODING_AGENT_DIR = $oldAgentDir }
    else { Remove-Item Env:PI_CODING_AGENT_DIR -ErrorAction SilentlyContinue }
    if ($hadOffline) { $env:PI_OFFLINE = $oldOffline }
    else { Remove-Item Env:PI_OFFLINE -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
```

The automated verifier adds stricter exit-code assertions and sentinel-based
cleanup; prefer it when you want a repeatable pass/fail result.

## Equivalent manual Bash flow (no script)

The following is the same experiment expressed entirely as Bash commands. Paste
it into a Bash terminal from the sample directory; it creates an isolated Pi
configuration, so it does not change the shared `samples/settings.json`. It
uses no helper or verifier script.

```bash
cd samples/009-package-and-share

set -euo pipefail
start_dir="$(pwd -P)"
package_dir="$(cd package && pwd -P)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/pi-package-demo.XXXXXX")"
agent_dir="$scratch/agent"
work_dir="$scratch/work"

# Preserve the terminal's variables and remove only this temporary directory.
had_agent_dir=0
had_offline=0
if [ "${PI_CODING_AGENT_DIR+x}" = x ]; then
  had_agent_dir=1
  old_agent_dir="$PI_CODING_AGENT_DIR"
fi
if [ "${PI_OFFLINE+x}" = x ]; then
  had_offline=1
  old_offline="$PI_OFFLINE"
fi
cleanup() {
  cd "$start_dir"
  if [ "$had_agent_dir" -eq 1 ]; then export PI_CODING_AGENT_DIR="$old_agent_dir"; else unset PI_CODING_AGENT_DIR; fi
  if [ "$had_offline" -eq 1 ]; then export PI_OFFLINE="$old_offline"; else unset PI_OFFLINE; fi
  rm -rf "$scratch"
}
trap cleanup EXIT

mkdir -p "$agent_dir" "$work_dir"
export PI_CODING_AGENT_DIR="$agent_dir"
export PI_OFFLINE=1
cd "$work_dir"

# Install the local package, then inspect the resources discovered at startup.
pi install "$package_dir" --no-approve
pi list --no-approve
printf '%s\n' '{"id":"commands","type":"get_commands"}' |
  pi --mode rpc --no-session --offline --no-approve

# Start a new Pi process after removal: wire-log and skill:haiku are gone.
pi remove "$package_dir" --no-approve
pi list --no-approve
printf '%s\n' '{"id":"commands-after-remove","type":"get_commands"}' |
  pi --mode rpc --no-session --offline --no-approve
```

In the first RPC response, look for commands named `wire-log` (source
`extension`) and `skill:haiku` (source `skill`). In the second response they
are absent. The `trap` restores your environment and deletes the disposable
directory as soon as the pasted sequence finishes or fails.

## Optional interactive exploration

After the verifier passes, repeat the disposable-config setup, install the
package, and start `pi`. Try `/wire-log status`, then ask for a sea haiku with
`/skill:haiku`. Enabling `/wire-log on` for one real request requires a working
model configuration and creates logs under the temporary config's `dump/`.

## Trust checklist

Before installing any package:

- inspect its `package.json` and every declared resource;
- check install scripts and runtime dependencies;
- confirm whether the source is a mutable local directory, npm package, or Git
  repository;
- install only code you trust to run with your user permissions;
- use a disposable config first when exploring an unfamiliar package.

Configuration isolation protects your normal Pi settings and makes cleanup
easy. It is **not a sandbox**: installed extensions are executable code and can
access anything the Pi process can access. npm and Git sources are useful next
steps for sharing, but publishing and remote installation are outside this
sample.
