<#
.SYNOPSIS
    Run the explicit Azure-backed live verification for sample 015.

The deterministic verifier is verify.ps1. This command is intentionally
nonzero when credentials are absent so "not verified" cannot look like PASS.
#>

[CmdletBinding()]
param([int] $TimeoutSeconds = 180)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($name in @('AZURE_PI_TEST_DEPLOYMENT', 'AZURE_PI_TEST_API_KEY')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        Write-Error "NOT VERIFIED: '$name' is absent. Source ./prepare.ps1 in samples/015-rpc-controller first."
        exit 2
    }
}
if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('PI_CODING_AGENT_DIR'))) {
    Write-Error 'NOT VERIFIED: PI_CODING_AGENT_DIR is empty. Source ./prepare.ps1 in this sample first.'
    exit 2
}

try {
    & (Join-Path $PSScriptRoot 'demo.ps1') -TimeoutSeconds $TimeoutSeconds
    if ($LASTEXITCODE -ne 0) { throw "demo.ps1 exited $LASTEXITCODE" }
    Write-Host 'PASS: live verification completed.'
} catch {
    Write-Error "LIVE VERIFICATION FAILED (provider/auth/quota or local protocol): $($_.Exception.Message)"
    exit 1
}
