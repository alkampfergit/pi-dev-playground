[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([Parameter(Mandatory)][bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw "Model verification failed: $Message" }
}

foreach ($name in @('AZURE_PI_TEST_ENDPOINT', 'AZURE_PI_TEST_DEPLOYMENT', 'AZURE_PI_TEST_API_KEY')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Missing $name. From this sample directory, first run '. ./prepare.ps1'."
    }
}
foreach ($command in @('node', 'npm', 'pi')) {
    if ($null -eq (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command '$command' was not found." }
}

$sampleDirectory = $PSScriptRoot
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("pi-sample-012-" + [guid]::NewGuid())
$jsonPath = Join-Path $temporaryDirectory 'events.jsonl'
$stderrPath = Join-Path $temporaryDirectory 'pi.stderr.txt'
$oldConfig = [Environment]::GetEnvironmentVariable('PI_CODING_AGENT_DIR', 'Process')
$hadConfig = [Environment]::GetEnvironmentVariables('Process').Contains('PI_CODING_AGENT_DIR')
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

try {
    $env:PI_CODING_AGENT_DIR = $sampleDirectory
    Push-Location $sampleDirectory
    & npm ci
    if ($LASTEXITCODE -ne 0) { throw "npm ci failed with exit $LASTEXITCODE" }
    $arguments = @(
        '--no-extensions', '-e', './extensions/mcp-catalog.ts',
        '--no-builtin-tools', '--tools', 'mcp_sample_catalog',
        '--model', "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT",
        '--mode', 'json', '--no-session',
        '-p', 'You must call mcp_sample_catalog for sample 003. Return its title and path.'
    )
    & pi @arguments 1> $jsonPath 2> $stderrPath
    $piExit = $LASTEXITCODE
    if ($piExit -ne 0) {
        $details = Get-Content -LiteralPath $stderrPath -Raw
        throw "Pi exited $piExit. Event stream: $jsonPath. $details"
    }

    $events = @()
    foreach ($line in Get-Content -LiteralPath $jsonPath) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $events += ($line | ConvertFrom-Json -Depth 100) }
    }
    $starts = @($events | Where-Object { $_.type -eq 'tool_execution_start' -and $_.toolName -eq 'mcp_sample_catalog' })
    $ends = @($events | Where-Object { $_.type -eq 'tool_execution_end' -and $_.toolName -eq 'mcp_sample_catalog' -and $_.isError -eq $false })
    Assert-True ($starts.Count -ge 1) "no mcp_sample_catalog tool_execution_start event; stream: $jsonPath"
    Assert-True ($ends.Count -ge 1) "no successful mcp_sample_catalog tool_execution_end event; stream: $jsonPath"

    $assistantText = @(
        foreach ($event in $events) {
            if ($event.type -ne 'message_end' -or $event.message.role -ne 'assistant') { continue }
            foreach ($content in @($event.message.content)) { if ($content.type -eq 'text') { $content.text } }
        }
    ) -join "`n"
    Assert-True ($assistantText.Contains('Wire Log, auto-discovered')) 'final assistant text missed the exact fixture title'
    Assert-True ($assistantText.Contains('samples/003-wire-log-global')) 'final assistant text missed the exact fixture path'
    Write-Host 'PASS: JSON events prove mcp_sample_catalog executed successfully.'
    Write-Host 'PASS: final answer is grounded in the exact fixture title and path.'
}
finally {
    Pop-Location
    if ($hadConfig) { [Environment]::SetEnvironmentVariable('PI_CODING_AGENT_DIR', $oldConfig, 'Process') }
    else { [Environment]::SetEnvironmentVariable('PI_CODING_AGENT_DIR', $null, 'Process') }
    if (Test-Path -LiteralPath $temporaryDirectory) { Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force }
}
