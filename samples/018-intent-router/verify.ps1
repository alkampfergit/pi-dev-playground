[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$oldAgentDir = $env:PI_CODING_AGENT_DIR
$oldOffline = $env:PI_OFFLINE
try {
    foreach ($link in @('models.json', 'settings.json', 'prepare.ps1', 'prepare.sh')) {
        $item = Get-Item -LiteralPath (Join-Path $here $link) -Force
        if (-not $item.LinkType -or [string]$item.Target -ne "../$link") { throw "$link must point to ../$link." }
    }
    & node --experimental-strip-types (Join-Path $here 'tests/router.test.ts')
    if ($LASTEXITCODE -ne 0) { throw 'router policy tests failed' }

    $env:PI_CODING_AGENT_DIR = $here
    $env:PI_OFFLINE = '1'
    $models = & pi --offline --list-models 'intent/auto' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $models -notmatch '(?m)^intent\s+auto\b') { throw "Pi did not register intent/auto. Output: $models" }
    Write-Host 'PASS: policy tests and Pi 1.6 virtual model discovery; no credentials, classifier weights, or provider calls used.'
} finally {
    $env:PI_CODING_AGENT_DIR = $oldAgentDir
    $env:PI_OFFLINE = $oldOffline
}
