<#
.SYNOPSIS
    Run model-free checks for the two-model handoff extension.

.DESCRIPTION
    Uses Pi's RPC mode with the two model IDs already present in the shared
    models.json. It does not contact Azure. A temporary fake non-empty key lets
    Pi exercise model selection locally; the process environment is restored.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([Parameter(Mandatory)][bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw "Verification failed: $Message" }
}

function Save-EnvironmentVariable {
    param([Parameter(Mandatory)][string] $Name)
    $variables = [Environment]::GetEnvironmentVariables('Process')
    [pscustomobject]@{ Name = $Name; Present = $variables.Contains($Name); Value = [Environment]::GetEnvironmentVariable($Name, 'Process') }
}

function Restore-EnvironmentVariable {
    param([Parameter(Mandatory)][object] $Saved)
    if ($Saved.Present) { [Environment]::SetEnvironmentVariable($Saved.Name, $Saved.Value, 'Process') }
    else { [Environment]::SetEnvironmentVariable($Saved.Name, $null, 'Process') }
}

function Invoke-HandoffRpc {
    param(
        [Parameter(Mandatory)][string] $Primary,
        [AllowEmptyString()][string] $Secondary,
        [Parameter(Mandatory)][string[]] $Messages
    )

    $env:AZURE_PI_TEST_DEPLOYMENT = $Primary
    $env:AZURE_PI_TEST_DEPLOYMENT2 = $Secondary
    $env:AZURE_PI_TEST_API_KEY = 'verification-placeholder-not-a-real-key'
    $env:PI_CODING_AGENT_DIR = $PSScriptRoot

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command pi -ErrorAction Stop).Source
    $start.WorkingDirectory = $PSScriptRoot
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('--mode', 'rpc', '--no-session', '--offline', '--approve', '--model', "azure-openai/$Primary")) {
        [void] $start.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    Assert-True $process.Start() 'Pi RPC process did not start.'
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $index = 0
    foreach ($message in $Messages) {
        $index++
        $request = @{ id = "request-$index"; type = 'prompt'; message = $message } | ConvertTo-Json -Compress
        $process.StandardInput.WriteLine($request)
    }
    $process.StandardInput.WriteLine('{"id":"state","type":"get_state"}')
    $process.StandardInput.WriteLine('{"id":"commands","type":"get_commands"}')
    $process.StandardInput.Close()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    Assert-True ($process.ExitCode -eq 0) "Pi RPC exited $($process.ExitCode): $stderr"

    $events = @()
    foreach ($line in ($stdout -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $events += ($line | ConvertFrom-Json -Depth 100) }
    }
    foreach ($id in 1..$Messages.Count) {
        Assert-True (@($events | Where-Object { $_.type -eq 'response' -and $_.id -eq "request-$id" -and $_.success }).Count -eq 1) "RPC command request-$id failed."
    }
    $commandResponse = @($events | Where-Object { $_.type -eq 'response' -and $_.id -eq 'commands' -and $_.success })
    Assert-True ($commandResponse.Count -eq 1) 'get_commands response was absent.'
    Assert-True (@($commandResponse[0].data.commands | Where-Object { $_.name -eq 'handoff' -and $_.source -eq 'extension' }).Count -eq 1) 'handoff was not auto-discovered exactly once.'
    $state = @($events | Where-Object { $_.type -eq 'response' -and $_.id -eq 'state' -and $_.success })
    Assert-True ($state.Count -eq 1) 'get_state response was absent.'
    [pscustomobject]@{
        Events = $events
        Notifications = @($events | Where-Object { $_.type -eq 'extension_ui_request' -and $_.method -eq 'notify' })
        Model = $state[0].data.model
    }
}

if ($null -eq (Get-Command pi -ErrorAction SilentlyContinue)) { throw "Required command 'pi' was not found." }
$models = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'models.json') -Raw | ConvertFrom-Json -Depth 100).providers.'azure-openai'.models
Assert-True (@($models).Count -ge 2) 'The shared registry needs two model entries for the model-free verifier.'
$primary = [string] $models[0].id
$secondary = [string] $models[1].id
Assert-True ($primary -ne $secondary) 'The first two shared models must have distinct IDs.'

$saved = @('AZURE_PI_TEST_DEPLOYMENT', 'AZURE_PI_TEST_DEPLOYMENT2', 'AZURE_PI_TEST_API_KEY', 'PI_CODING_AGENT_DIR', 'PI_OFFLINE') | ForEach-Object { Save-EnvironmentVariable $_ }
try {
    $success = Invoke-HandoffRpc -Primary $primary -Secondary $secondary -Messages @('/handoff status', '/handoff secondary', '/handoff', '/handoff other')
    Assert-True ($success.Model.id -eq $primary) 'Explicit switch and bare toggle did not end back on primary.'
    $messages = @($success.Notifications | ForEach-Object { [string] $_.message })
    Assert-True (@($messages | Where-Object { $_ -eq "azure-openai/$primary -> azure-openai/$secondary" }).Count -eq 1) 'Primary-to-secondary transition notification was absent.'
    Assert-True (@($messages | Where-Object { $_ -eq "azure-openai/$secondary -> azure-openai/$primary" }).Count -eq 1) 'Secondary-to-primary transition notification was absent.'
    Assert-True (@($messages | Where-Object { $_ -eq 'Usage: /handoff [status|primary|secondary]' }).Count -eq 1) 'Invalid-argument usage notification was absent.'
    Write-Host 'PASS: discovery, status, explicit switch, bare toggle, and invalid argument.'

    $missing = Invoke-HandoffRpc -Primary $primary -Secondary '' -Messages @('/handoff status', '/handoff secondary')
    Assert-True ($missing.Model.id -eq $primary) 'Missing-secondary test changed the active model.'
    $messages = @($missing.Notifications | ForEach-Object { [string] $_.message })
    Assert-True (@($messages | Where-Object { $_ -match 'secondary: not configured' }).Count -eq 1) 'Missing-secondary status was absent.'
    Assert-True (@($messages | Where-Object { $_ -eq 'Set AZURE_PI_TEST_DEPLOYMENT2 in .env, source prepare again, then restart Pi.' }).Count -eq 1) 'Missing-secondary remediation was absent.'
    Write-Host 'PASS: missing secondary remains a no-op with actionable feedback.'

    $unknown = Invoke-HandoffRpc -Primary $primary -Secondary 'known-missing-model-id' -Messages @('/handoff secondary')
    Assert-True ($unknown.Model.id -eq $primary) 'Unknown-model test changed the active model.'
    Assert-True (@($unknown.Notifications | Where-Object { $_.message -match '^Model azure-openai/known-missing-model-id was not found in models.json' }).Count -eq 1) 'Unknown-model lookup feedback was absent.'

    $same = Invoke-HandoffRpc -Primary $primary -Secondary $primary -Messages @('/handoff secondary')
    Assert-True ($same.Model.id -eq $primary) 'Same-ID test changed the active model.'
    Assert-True (@($same.Notifications | Where-Object { $_.message -eq 'Two distinct deployment IDs are required for a handoff.' }).Count -eq 1) 'Same-ID feedback was absent.'
    Write-Host 'PASS: unknown and duplicate IDs remain no-ops.'
}
finally {
    foreach ($item in $saved) { Restore-EnvironmentVariable $item }
}

Write-Host 'PASS: all model-free sample 007 checks completed; no Azure request was made.'
