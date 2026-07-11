# 009 — Package and share

This sample turns two resources you have already met into one installable Pi
package. It bundles a simplified version of sample 003's `/wire-log` extension
and sample 005's `haiku` skill, then proves that Pi can install, discover, and
remove both without calling a model.

Packaging changes the distribution mechanism, not the extension's runtime
design. The logger still starts disabled, creates `dump/` lazily, and records
only provider requests and responses while enabled.

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
