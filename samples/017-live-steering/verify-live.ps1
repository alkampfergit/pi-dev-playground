[CmdletBinding()]
param([int]$TimeoutSeconds=180, [string]$Model='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
foreach($name in @('AZURE_PI_TEST_ENDPOINT','AZURE_PI_TEST_DEPLOYMENT','AZURE_PI_TEST_API_KEY')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { Write-Error "NOT VERIFIED: $name is absent. Source ./prepare.ps1 first."; exit 2 }
}
try {
    $arguments=@{ TimeoutSeconds=$TimeoutSeconds; VerifyAbort=$true }
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $arguments.Model=$Model }
    & (Join-Path $PSScriptRoot 'run-scenario.ps1') @arguments
    Write-Host 'PASS: real-model delivery, context isolation, and abort queue contracts verified.'
} catch { Write-Error "LIVE VERIFICATION FAILED (Pi 0.80.6 contract or provider boundary): $($_.Exception.Message)"; exit 1 }
