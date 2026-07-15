[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([Parameter(Mandatory)][bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw "Verification failed: $Message" }
}

foreach ($command in @('node', 'pwsh', 'pi')) {
    if ($null -eq (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command '$command' was not found." }
}
Write-Host "node: $(& node --version)"
Write-Host "pwsh: $(& pwsh --version)"
Write-Host "pi: $(& pi --version)"

function Save-EnvironmentVariable {
    param([Parameter(Mandatory)][string] $Name)
    $all = [Environment]::GetEnvironmentVariables('Process')
    [pscustomobject]@{ Name = $Name; Present = $all.Contains($Name); Value = [Environment]::GetEnvironmentVariable($Name, 'Process') }
}

function Restore-EnvironmentVariable {
    param([Parameter(Mandatory)][object] $Saved)
    if ($Saved.Present) { [Environment]::SetEnvironmentVariable($Saved.Name, $Saved.Value, 'Process') }
    else { [Environment]::SetEnvironmentVariable($Saved.Name, $null, 'Process') }
}

$saved = @('PI_CODING_AGENT_DIR', 'PI_OFFLINE', 'PI_SUBAGENT_TEST_CHILD', 'PI_SUBAGENT_TEST_LOG', 'PI_SUBAGENT_VERIFY', 'AZURE_PI_TEST_DEPLOYMENT') | ForEach-Object { Save-EnvironmentVariable $_ }
$originalLocation = Get-Location
$process = $null
try {
    Set-Location $PSScriptRoot
    $env:PI_CODING_AGENT_DIR = $PSScriptRoot
    $env:PI_OFFLINE = '1'
    $env:PI_SUBAGENT_VERIFY = '1'
    $env:AZURE_PI_TEST_DEPLOYMENT = 'offline-test-deployment'

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command pi).Source
    $start.WorkingDirectory = $PSScriptRoot
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('--no-extensions', '-e', './extensions/subagents.ts', '-e', './verification/verify-subagents.ts', '--mode', 'rpc', '--no-session', '--offline')) {
        [void] $start.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    Assert-True $process.Start() 'Pi RPC process did not start'
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Close()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    Assert-True ($process.ExitCode -eq 0) "Pi verifier exited $($process.ExitCode): $stderr"

    $events = @(@($stdout, $stderr) -join "`n" -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -Depth 100 })
    $verify = @($events | Where-Object { $_.type -eq 'verification_result' })
    if ($verify.Count -ne 1) { throw "Verification failed: model-free result was absent; stdout: $stdout; stderr: $stderr" }
    if (-not [bool]$verify[0].success) {
        $reason = if ($null -ne $verify[0].PSObject.Properties['error']) { [string]$verify[0].error } else { 'unknown verifier failure' }
        throw "Verification failed: model-free matrix failed: $reason"
    }
    $providerEvents = @($events | Where-Object { [string]$_.type -match '^(agent|turn|message|tool_execution)_' })
    Assert-True ($providerEvents.Count -eq 0) 'offline RPC emitted provider/agent events'
    Write-Host 'PASS: offline RPC loaded exactly the production extension plus the verifier, with no provider events.'
    Write-Host 'PASS: discovery, argument policy, JSONL parsing, bounded parallelism, chain handoff, cancellation, and fixture immutability passed.'
}
finally {
    if ($null -ne $process -and -not $process.HasExited) { $process.Kill() }
    Set-Location $originalLocation
    foreach ($item in $saved) { Restore-EnvironmentVariable $item }
}
