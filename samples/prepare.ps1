<#
.SYNOPSIS
    Configure the current PowerShell session for the Pi sample you are in.

.DESCRIPTION
    Run this from INSIDE a sample directory, dot-sourced so the environment
    changes stay in your shell:

        cd samples/001-helloworld
        . ./prepare.ps1

    It does three things:
      1. Imports the shared Env.psm1 helper from the parent samples/ directory.
      2. Loads the nearest .env files (walking up to the filesystem root) so the
         AZURE_PI_TEST_* variables are available.
      3. Sets PI_CODING_AGENT_DIR to this directory, so Pi discovers the
         sample's models.json / settings.json and creates bin/, sessions/, and
         any dump/ folders here.

    The leading '. ' (dot-source) is required. Running `pwsh -File ./prepare.ps1`
    would use a child process, and its environment changes would not be carried
    back into your shell.
#>

$sampleDirectory = (Get-Location).Path
Import-Module (Join-Path $sampleDirectory '..' 'Env.psm1') -Force
$loaded = Import-DotEnv -StartDirectory $sampleDirectory
$env:PI_CODING_AGENT_DIR = $sampleDirectory

Write-Host "Pi configured for sample: $sampleDirectory"
if ($loaded) {
    Write-Host ("Loaded .env: " + ($loaded -join ', '))
} else {
    Write-Host "No .env found while walking up from this directory."
}
