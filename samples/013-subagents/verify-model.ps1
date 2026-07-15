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
        throw "Missing $name. From this sample directory, first run '. ./prepare.ps1'. This check uses one parent and one child model call and may incur network/provider cost."
    }
}
foreach ($command in @('node', 'pwsh', 'pi')) {
    if ($null -eq (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command '$command' was not found." }
}

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

$saved = @('PI_CODING_AGENT_DIR') | ForEach-Object { Save-EnvironmentVariable $_ }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("pi-sample-013-" + [guid]::NewGuid())
$eventsPath = Join-Path $temporary 'events.jsonl'
$stderrPath = Join-Path $temporary 'parent.stderr.txt'
New-Item -ItemType Directory -Path $temporary | Out-Null
$process = $null
try {
    $env:PI_CODING_AGENT_DIR = $PSScriptRoot
    Push-Location $PSScriptRoot
    $prompt = 'Use delegate exactly once with the tasks form and one scout task. The scout child cwd is already the root of the fixed fixture tiny-repository, so do not look for a nested fixtures/tiny-repository directory. Ask it to find the literal WAREHOUSE_REGION=eu-west and report the exact child-relative path src/inventory.ts. Do not use any other tool or delegate mode.'
    $arguments = @('--no-extensions', '-e', './extensions/subagents.ts', '--no-builtin-tools', '--tools', 'delegate', '--model', "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT", '--mode', 'json', '--no-session', '--no-approve', '--print', $prompt)
    & pi @arguments 1> $eventsPath 2> $stderrPath
    $exitCode = $LASTEXITCODE
    $stderr = Get-Content -LiteralPath $stderrPath -Raw
    Assert-True ($exitCode -eq 0) "Pi exited ${exitCode}: $stderr"
    $events = @((Get-Content -LiteralPath $eventsPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -Depth 100 })
    $starts = @($events | Where-Object { $_.type -eq 'tool_execution_start' -and $_.toolName -eq 'delegate' })
    Assert-True ($starts.Count -eq 1) "parent called delegate $($starts.Count) times"
    $ends = @($events | Where-Object { $_.type -eq 'tool_execution_end' -and $_.toolName -eq 'delegate' })
    Assert-True ($ends.Count -eq 1) 'delegate tool result event was absent'
    Assert-True (-not [bool]$ends[0].isError) 'delegate tool result was an error'
    $details = $ends[0].result.details
    Assert-True ($details.mode -eq 'parallel' -and @($details.results).Count -eq 1 -and $details.results[0].agent -eq 'scout') 'child details did not identify one scout'
    Assert-True ([int]$details.results[0].exitCode -eq 0 -and @('stop', 'length') -contains [string]$details.results[0].stopReason) 'child did not finish successfully'
    $childText = [string]$details.results[0].text
    Assert-True ($childText -match 'WAREHOUSE_REGION' -and $childText -match 'src/inventory\.ts') "bounded scout result missed required evidence: $childText"
    Write-Host 'PASS: one real parent delegate call completed one real scout child with the required evidence.'
}
finally {
    Pop-Location
    if ($null -ne $process -and -not $process.HasExited) { $process.Kill() }
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($item in $saved) { Restore-EnvironmentVariable $item }
}
