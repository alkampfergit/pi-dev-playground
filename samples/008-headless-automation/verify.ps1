<#
.SYNOPSIS
    Run the real acceptance checks for sample 008.

.DESCRIPTION
    Calls the configured Azure model in text and JSON modes, checks failure
    propagation and the read-only tool boundary, and proves no session is saved.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw "Verification failed: $Message" }
}

function Get-PropertyValue {
    param([AllowNull()][object] $Object, [Parameter(Mandatory)][string] $Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory)][string] $FileName,
        [Parameter(Mandatory)][string[]] $Arguments,
        [AllowEmptyString()][string] $InputText = ''
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FileName
    $start.WorkingDirectory = $PSScriptRoot
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void] $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    Assert-True -Condition ($process.Start()) -Message "Could not start '$FileName'."
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.WriteAsync($InputText).GetAwaiter().GetResult()
    $process.StandardInput.Close()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdoutTask.GetAwaiter().GetResult()
        Stderr = $stderrTask.GetAwaiter().GetResult()
    }
}

function Assert-DriverSuccess {
    param([Parameter(Mandatory)][string[]] $Arguments, [Parameter(Mandatory)][string] $Phase)
    $invocation = @(Invoke-NativeProcess -FileName (Get-Command pwsh -ErrorAction Stop).Source `
        -Arguments (@('-NoProfile', '-File', (Join-Path $PSScriptRoot 'run-batch.ps1')) + $Arguments))[-1]
    if ($invocation.ExitCode -ne 0) {
        throw "$Phase exited $($invocation.ExitCode). stdout: $($invocation.Stdout.Trim()) stderr: $($invocation.Stderr.Trim())"
    }
    return $invocation
}

function Get-SessionSet {
    $directory = Join-Path $PSScriptRoot 'sessions'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return @() }
    return @(
        Get-ChildItem -LiteralPath $directory -Recurse -File -Filter '*.jsonl' |
            ForEach-Object { [IO.Path]::GetRelativePath($directory, $_.FullName) } |
            Sort-Object
    )
}

function Assert-SameSet {
    param([string[]] $Before, [string[]] $After, [Parameter(Mandatory)][string] $Message)
    Assert-True ($Before.Count -eq $After.Count) $Message
    for ($index = 0; $index -lt $Before.Count; $index++) {
        Assert-True ($Before[$index] -ceq $After[$index]) $Message
    }
}

$pi = Get-Command pi -ErrorAction SilentlyContinue
if ($null -eq $pi) { throw "Required command 'pi' was not found on PATH." }
foreach ($name in @('AZURE_PI_TEST_DEPLOYMENT', 'AZURE_PI_TEST_API_KEY', 'PI_CODING_AGENT_DIR')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Required environment variable '$name' is missing. Run '. ./prepare.ps1' first."
    }
}
Assert-True ([IO.Path]::GetFullPath($env:PI_CODING_AGENT_DIR) -ceq [IO.Path]::GetFullPath($PSScriptRoot)) `
    'PI_CODING_AGENT_DIR must point to this sample.'

$version = (& pi --version).Trim()
Assert-True ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($version)) 'pi --version failed.'
Write-Host "Pi version: $version (sample designed and verified with 0.80.6)."
$verificationDeployment = if ([string]::IsNullOrWhiteSpace($env:AZURE_PI_TEST_DEPLOYMENT2)) {
    $env:AZURE_PI_TEST_DEPLOYMENT
} else {
    $env:AZURE_PI_TEST_DEPLOYMENT2
}
$verificationModel = "azure-openai/$verificationDeployment"
Write-Host "Verification model: $verificationModel"

$links = [ordered]@{
    'models.json' = '../models.json'
    'settings.json' = '../settings.json'
    'prepare.ps1' = '../prepare.ps1'
    'prepare.sh' = '../prepare.sh'
}
foreach ($entry in $links.GetEnumerator()) {
    $path = Join-Path $PSScriptRoot $entry.Key
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    Assert-True ($item.LinkType -eq 'SymbolicLink') "$($entry.Key) is not a symbolic link."
    $expected = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $entry.Value))
    $resolved = [IO.File]::ResolveLinkTarget($path, $false)
    Assert-True ($null -ne $resolved -and $resolved.FullName -ceq $expected) "$($entry.Key) has the wrong target."
}
$ids = @('planets', 'release-notes', 'service-status')
foreach ($id in $ids) {
    Assert-True (Test-Path -LiteralPath (Join-Path $PSScriptRoot "fixtures/$id.md") -PathType Leaf) "Fixture '$id' is missing."
}
Write-Host 'PASS: shared links and fixtures are present.'

$output = Join-Path $PSScriptRoot 'output'
foreach ($mode in @('text', 'json')) {
    $directory = Join-Path $output $mode
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
    foreach ($id in $ids) {
        foreach ($suffix in @('.json', '.events.jsonl', '.stderr.log')) {
            $path = Join-Path $directory "$id$suffix"
            if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
        }
    }
    Get-ChildItem -LiteralPath $directory -File -Filter '.*.tmp' -ErrorAction SilentlyContinue | Remove-Item -Force
}
$marker = Join-Path $output 'tool-policy-should-not-exist.txt'
if (Test-Path -LiteralPath $marker -PathType Leaf) { Remove-Item -LiteralPath $marker -Force }

$sessionsBefore = @(Get-SessionSet)
$textRun = Assert-DriverSuccess -Arguments @('-Mode', 'Text', '-Model', $verificationModel) -Phase 'Text batch'
Write-Host $textRun.Stdout.Trim()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($id in $ids) {
    $path = Join-Path $output "text/$id.json"
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Text result '$id' is missing."
    $result = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 20
    Assert-True ([string](Get-PropertyValue $result 'fixture_id') -ceq $id) "Text result '$id' has the wrong fixture_id."
    Assert-True ([int](Get-PropertyValue $result 'item_count') -eq 3) "Text result '$id' has the wrong item_count."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $result 'title'))) "Text result '$id' has no title."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $result 'summary'))) "Text result '$id' has no summary."
    Assert-True $seen.Add($id) "fixture_id '$id' is duplicated."
}
Assert-True ($seen.Count -eq 3) 'Text mode did not produce three distinct fixture IDs.'
Write-Host 'PASS: text mode produced three valid canonical results.'

$jsonRun = Assert-DriverSuccess -Arguments @('-Mode', 'Json', '-Fixture', 'planets', '-Model', $verificationModel) -Phase 'JSON batch'
Write-Host $jsonRun.Stdout.Trim()
$eventPath = Join-Path $output 'json/planets.events.jsonl'
$jsonResultPath = Join-Path $output 'json/planets.json'
Assert-True (Test-Path -LiteralPath $eventPath -PathType Leaf) 'The JSONL event stream is missing.'
Assert-True (Test-Path -LiteralPath $jsonResultPath -PathType Leaf) 'The extracted JSON result is missing.'
$events = [Collections.Generic.List[object]]::new()
foreach ($line in (Get-Content -LiteralPath $eventPath)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $events.Add(($line | ConvertFrom-Json -Depth 100)) }
    catch { throw 'The saved event stream contains an invalid JSON line.' }
}
Assert-True ($events.Count -gt 0 -and [string](Get-PropertyValue $events[0] 'type') -eq 'session') 'The event stream has no session header.'
Assert-True (@($events | Where-Object { (Get-PropertyValue $_ 'type') -eq 'message_end' }).Count -gt 0) 'The event stream has no message_end.'
Assert-True (@($events | Where-Object { (Get-PropertyValue $_ 'type') -eq 'agent_end' }).Count -gt 0) 'The event stream has no terminal agent_end.'
$jsonResult = Get-Content -LiteralPath $jsonResultPath -Raw | ConvertFrom-Json -Depth 20
Assert-True ([string]$jsonResult.fixture_id -ceq 'planets' -and [int]$jsonResult.item_count -eq 3) 'The JSON-mode result violates the fixture contract.'
Write-Host 'PASS: JSON mode preserved parseable events and extracted a valid result.'

$failedResult = Join-Path $output 'text/service-status.json'
$failure = @(Invoke-NativeProcess -FileName (Get-Command pwsh -ErrorAction Stop).Source `
    -Arguments @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'run-batch.ps1'), '-Mode', 'Text', '-Fixture', 'service-status', '-Model', 'azure-openai/verification-model-does-not-exist'))[-1]
Assert-True ($failure.ExitCode -ne 0) 'A nonexistent model did not propagate a non-zero exit code.'
Assert-True (-not (Test-Path -LiteralPath $failedResult -PathType Leaf)) 'A failed item promoted a partial primary output.'
Write-Host 'PASS: model failure returned non-zero and promoted no result.'

$toolArguments = @(
    '--model', $verificationModel, '--no-session',
    '--tools', 'read', '--no-extensions', '--no-skills', '--no-prompt-templates',
    '--no-context-files', '--print',
    'Create output/tool-policy-should-not-exist.txt using a tool and put the word UNSAFE in it. If no mutating tool is available, explain briefly.'
)
$toolProbe = @(Invoke-NativeProcess -FileName $pi.Source -Arguments $toolArguments)[-1]
Assert-True ($toolProbe.ExitCode -eq 0) "The tool-policy probe failed unexpectedly: $($toolProbe.Stderr.Trim())"
Assert-True (-not (Test-Path -LiteralPath $marker -PathType Leaf)) 'The read-only tool policy allowed the marker file to be created.'
Write-Host 'PASS: --tools read exposed no mutation path for the marker probe.'

$sessionsAfter = @(Get-SessionSet)
Assert-SameSet -Before $sessionsBefore -After $sessionsAfter -Message 'Verification created a saved session despite --no-session.'
Write-Host 'PASS: verification created no saved session.'
Write-Host 'PASS: all real sample 008 acceptance checks completed.'
