<#
.SYNOPSIS
    Run model-free acceptance checks for sample 015.

.DESCRIPTION
    Exercises the controller against a deterministic JSONL peer and then
    starts the installed Pi CLI in its offline RPC profile. No provider request
    is made. The script can be launched from any directory.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw "Verification failed: $Message" }
}

function Save-ProcessEnvironment {
    param([Parameter(Mandatory)][string] $Name)
    $all = [Environment]::GetEnvironmentVariables('Process')
    [pscustomobject]@{
        Name = $Name
        Present = $all.Contains($Name)
        Value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    }
}

function Restore-ProcessEnvironment {
    param([Parameter(Mandatory)][object] $Saved)
    if ($Saved.Present) { [Environment]::SetEnvironmentVariable($Saved.Name, $Saved.Value, 'Process') }
    else { [Environment]::SetEnvironmentVariable($Saved.Name, $null, 'Process') }
}

function Get-ConfigCopy {
    param([Parameter(Mandatory)][string] $Directory)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'models.json') -Destination (Join-Path $Directory 'models.json')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'settings.json') -Destination (Join-Path $Directory 'settings.json')
}

function Start-Fake {
    param(
        [Parameter(Mandatory)][string] $Scenario,
        [int] $MaxEventCount = 512
    )
    $client = Start-PiRpc -ExecutablePath (Get-Command pwsh -ErrorAction Stop).Source `
        -ArgumentList @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'fixtures/fake-rpc-server.ps1')) `
        -WorkingDirectory $PSScriptRoot -MaxEventCount $MaxEventCount
    [void]$script:StartedPids.Add($client.Process.Id)
    return $client
}

function Send-Fake {
    param([Parameter(Mandatory)][object] $Client, [Parameter(Mandatory)][string] $Scenario, [string] $Type = 'probe')
    return Send-PiRpcRequest -Client $Client -Request ([ordered]@{ type = $Type; scenario = $Scenario })
}

function Stop-Checked {
    param([AllowNull()][object] $Client, [double] $TimeoutSeconds = 5)
    if ($null -ne $Client) { Stop-PiRpc -Client $Client -TimeoutSeconds $TimeoutSeconds }
}

function Assert-PidExited {
    param([Parameter(Mandatory)][int] $ProcessId, [int] $WaitMilliseconds = 1500)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $WaitMilliseconds) {
        if ($null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return }
        [Threading.Thread]::Sleep(25)
    }
    Assert-True ($null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) "PID $ProcessId is still alive."
}

function Invoke-FakeChecks {
    $client = $null
    try {
        $client = Start-Fake -Scenario 'reverse'
        $first = Send-Fake -Client $client -Scenario 'reverse' -Type 'probe_one'
        $second = Send-Fake -Client $client -Scenario 'reverse' -Type 'probe_two'
        $responseTwo = Wait-PiRpcResponse -Client $client -Id $second -TimeoutSeconds 3
        $responseOne = Wait-PiRpcResponse -Client $client -Id $first -TimeoutSeconds 3
        Assert-True ([string]$responseTwo.id -eq $second -and [string]$responseTwo.command -eq 'probe_two') 'reverse response two was not correlated.'
        Assert-True ([string]$responseOne.id -eq $first -and [string]$responseOne.command -eq 'probe_one') 'reverse response one was not correlated.'
        $event1 = Wait-PiRpcEvent -Client $client -Type @('message_update') -TimeoutSeconds 2
        $event2 = Wait-PiRpcEvent -Client $client -Type @('queue_update') -TimeoutSeconds 2
        $event3 = Wait-PiRpcEvent -Client $client -Type @('extension_ui_request') -TimeoutSeconds 2
        Assert-True ([string]$event1.type -eq 'message_update') 'message event order was not preserved.'
        Assert-True ([string]$event2.type -eq 'queue_update') 'queue event order was not preserved.'
        Assert-True ([string]$event3.method -eq 'notify') 'observational UI event was not retained.'
        Write-Host 'PASS: fake transport correlated reverse responses and preserved events.'
    } finally { Stop-Checked $client }

    $client = $null
    try {
        $client = Start-Fake -Scenario 'split'
        $id = Send-Fake -Client $client -Scenario 'split' -Type 'split_probe'
        $response = Wait-PiRpcResponse -Client $client -Id $id -TimeoutSeconds 3
        $event = Wait-PiRpcEvent -Client $client -Type @('message_update') -NestedType @('text_delta') -TimeoutSeconds 3
        $delta = [string]$event.assistantMessageEvent.delta
        Assert-True ($delta.Contains('é', [StringComparison]::Ordinal)) 'partial UTF-8 character was corrupted.'
        Assert-True ($delta.Contains([string][char]0x2028, [StringComparison]::Ordinal) -and $delta.Contains([string][char]0x2029, [StringComparison]::Ordinal)) 'Unicode separators were not preserved.'
        Assert-True ($delta.Contains("`r", [StringComparison]::Ordinal)) 'escaped bare CR content was not preserved.'
        $stderr = @($client.StderrTail.ToArray()) -join "`n"
        Assert-True (-not $stderr.Contains('secret-not-for-output', [StringComparison]::Ordinal)) "stderr secret was not sanitized: $stderr"
        Assert-True ($stderr.Contains('[redacted]', [StringComparison]::Ordinal)) "sanitized stderr metadata was not retained: $stderr"
        Write-Host 'PASS: fake transport handled split UTF-8/LF frames and isolated sanitized stderr.'
    } finally { Stop-Checked $client }

    $client = $null
    try {
        $client = Start-Fake -Scenario 'overflow' -MaxEventCount 3
        $id = Send-Fake -Client $client -Scenario 'overflow' -Type 'overflow_probe'
        [void](Wait-PiRpcResponse -Client $client -Id $id -TimeoutSeconds 3)
        $events = @(
            Wait-PiRpcEvent -Client $client -TimeoutSeconds 2
            Wait-PiRpcEvent -Client $client -TimeoutSeconds 2
            Wait-PiRpcEvent -Client $client -TimeoutSeconds 2
        )
        Assert-True ($client.EventOverflowCount -eq 5) 'event overflow accounting is incorrect.'
        Assert-True ((@($events | ForEach-Object { [int]$_.index }) -join ',') -eq '5,6,7') 'bounded FIFO retained the wrong event suffix.'
        Write-Host 'PASS: fake event buffer is bounded, FIFO, and reports overflow.'
    } finally { Stop-Checked $client }

    $client = $null
    try {
        $client = Start-Fake -Scenario 'timeout'
        $id = Send-Fake -Client $client -Scenario 'timeout' -Type 'timeout_probe'
        $timedOut = $false
        try { [void](Wait-PiRpcResponse -Client $client -Id $id -TimeoutSeconds 0.15) }
        catch { $timedOut = $_.Exception.Message.Contains('Timed out', [StringComparison]::Ordinal) }
        Assert-True $timedOut 'intentional response timeout did not fault clearly.'
        Write-Host 'PASS: response timeout uses a bounded monotonic wait.'
    } finally { Stop-Checked $client }

    $client = $null
    try {
        $client = Start-Fake -Scenario 'malformed'
        $id = Send-Fake -Client $client -Scenario 'malformed' -Type 'malformed_probe'
        $faulted = $false
        try { [void](Wait-PiRpcResponse -Client $client -Id $id -TimeoutSeconds 2) }
        catch { $faulted = $_.Exception.Message.Contains('malformed stdout', [StringComparison]::Ordinal) }
        Assert-True $faulted 'malformed stdout did not fault the transport.'
        Write-Host 'PASS: malformed stdout is a protocol fault, not a guessed event.'
    } finally { Stop-Checked $client }

    $client = $null
    try {
        $client = Start-Fake -Scenario 'forced_cleanup'
        $id = Send-Fake -Client $client -Scenario 'forced_cleanup' -Type 'forced_probe'
        [void](Wait-PiRpcResponse -Client $client -Id $id -TimeoutSeconds 3)
        $childEvent = Wait-PiRpcEvent -Client $client -Type @('child_spawned') -TimeoutSeconds 3
        $childPid = [int]$childEvent.pid
        Stop-PiRpc -Client $client -TimeoutSeconds 0.2
        Stop-PiRpc -Client $client -TimeoutSeconds 0.2
        Assert-True $client.CleanupForced 'forced cleanup scenario did not exercise the bounded fallback.'
        Assert-PidExited -ProcessId $childPid
        Write-Host 'PASS: stdin EOF was attempted, then Kill(true) cleaned the fixture process tree.'
    } finally { Stop-Checked $client }
}

function Invoke-NativeMalformedPi {
    param([Parameter(Mandatory)][string] $PiPath, [Parameter(Mandatory)][string[]] $Arguments, [Parameter(Mandatory)][string] $WorkingDirectory)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $PiPath
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    Assert-True $process.Start() 'raw Pi parse probe did not start.'
    [void]$script:StartedPids.Add($process.Id)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $bad = [Text.UTF8Encoding]::new($false).GetBytes('{"type":broken-json' + "`n")
    $process.StandardInput.BaseStream.Write($bad, 0, $bad.Length)
    $process.StandardInput.Close()
    Assert-True $process.WaitForExit(5000) 'raw Pi parse probe did not shut down.'
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Invoke-OfflinePiChecks {
    param([Parameter(Mandatory)][string] $ConfigDirectory, [Parameter(Mandatory)][string] $PiPath)
    $profile = @('--mode', 'rpc', '--no-session', '--offline', '--no-approve', '--no-tools', '--no-skills', '--no-prompt-templates', '--no-extensions')
    $client = $null
    try {
        $client = Start-PiRpc -ExecutablePath $PiPath -ArgumentList $profile -WorkingDirectory $PSScriptRoot
        [void]$script:StartedPids.Add($client.Process.Id)
        $stateId = Send-PiRpcRequest -Client $client -Request @{ type = 'get_state' }
        $modelsId = Send-PiRpcRequest -Client $client -Request @{ type = 'get_available_models' }
        $commandsId = Send-PiRpcRequest -Client $client -Request @{ type = 'get_commands' }
        $commandsResponse = Wait-PiRpcResponse -Client $client -Id $commandsId -TimeoutSeconds 5
        $modelsResponse = Wait-PiRpcResponse -Client $client -Id $modelsId -TimeoutSeconds 5
        $stateResponse = Wait-PiRpcResponse -Client $client -Id $stateId -TimeoutSeconds 5
        foreach ($response in @($stateResponse, $modelsResponse, $commandsResponse)) {
            Assert-True ($response.success -eq $true -and [string]$response.id) 'offline discovery response was not successful/correlated.'
        }
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$stateResponse.data.sessionId)) 'get_state has no sessionId.'
        Assert-True ($null -ne $stateResponse.data.isStreaming -and $null -ne $stateResponse.data.pendingMessageCount) 'get_state has no streaming/queue fields.'
        Assert-True ($modelsResponse.data.models -is [Collections.IEnumerable]) 'get_available_models did not return an array.'
        Assert-True ($commandsResponse.data.commands -is [Collections.IEnumerable]) 'get_commands did not return an array.'
        Assert-True ($client.EventQueue.Count -eq 0) 'discovery commands emitted agent/message events.'
        $unknownId = Send-PiRpcRequest -Client $client -Request @{ type = 'unknown_for_sample_015' }
        $unknown = Wait-PiRpcResponse -Client $client -Id $unknownId -TimeoutSeconds 5
        Assert-True ($unknown.success -eq $false -and ([string]$unknown.error).Contains('Unknown command', [StringComparison]::Ordinal)) 'unknown command rejection was not inspectable.'
        Write-Host 'PASS: offline Pi discovery and command rejection matched the 0.80.6 contract.'
    } finally { Stop-Checked $client }

    $raw = Invoke-NativeMalformedPi -PiPath $PiPath -Arguments $profile -WorkingDirectory $PSScriptRoot
    Assert-True ($raw.ExitCode -eq 0) "raw malformed-frame Pi exited $($raw.ExitCode): $($raw.Stderr.Trim())"
    $parseResponses = @($raw.Stdout -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 100 } | Where-Object { $_.type -eq 'response' -and $_.command -eq 'parse' -and $_.success -eq $false })
    Assert-True ($parseResponses.Count -eq 1) 'malformed raw input did not produce one uncorrelated parse failure.'
    Write-Host 'PASS: raw malformed input produced Pi command=parse failure and normal EOF exit.'
}

function Invoke-UiProbe {
    param([Parameter(Mandatory)][string] $PiPath)
    $profile = @('--mode', 'rpc', '--no-session', '--offline', '--no-approve', '--no-tools', '--no-skills', '--no-prompt-templates', '--no-extensions', '-e', './extensions/rpc-ui-probe.ts')
    $client = $null
    try {
        $client = Start-PiRpc -ExecutablePath $PiPath -ArgumentList $profile -WorkingDirectory $PSScriptRoot
        [void]$script:StartedPids.Add($client.Process.Id)
        $id = Send-PiRpcRequest -Client $client -Request @{ type = 'prompt'; message = '/rpc-ui-probe' }
        [void](Wait-PiRpcResponse -Client $client -Id $id -TimeoutSeconds 5)
        $sawResult = $false
        $sawConfirm = $false
        for ($index = 0; $index -lt 12 -and -not $sawResult; $index++) {
            $event = Wait-PiRpcEvent -Client $client -Type @('extension_ui_request') -TimeoutSeconds 5
            $method = [string]$event.method
            if ($method -eq 'confirm') { $sawConfirm = $true }
            if ($method -eq 'notify' -and ([string]$event.message).Contains('rpc-ui-probe result:', [StringComparison]::Ordinal)) {
                $sawResult = $true
                $result = [string]$event.message
                Assert-True ($result.Contains('confirmed=false', [StringComparison]::Ordinal)) 'confirm was not denied.'
                Assert-True ($result.Contains('selected=false', [StringComparison]::Ordinal) -and $result.Contains('input=false', [StringComparison]::Ordinal) -and $result.Contains('editor=false', [StringComparison]::Ordinal)) 'a blocking UI request was not cancelled.'
            }
        }
        Assert-True ($sawConfirm -and $sawResult) 'UI probe did not observe the fail-closed policy.'
        Write-Host 'PASS: explicit UI probe denied confirmation and cancelled all blocking dialogs.'
    } finally { Stop-Checked $client }
}

$required = @('pwsh', 'pi')
foreach ($name in $required) { Assert-True ($null -ne (Get-Command $name -ErrorAction SilentlyContinue)) "Required command '$name' was not found." }
$pi = (Get-Command pi -ErrorAction Stop).Source
$version = (& $pi --version).Trim()
Assert-True ($LASTEXITCODE -eq 0 -and $version -eq '0.80.6') "Expected installed Pi 0.80.6, found '$version'."
Write-Host "Pi version: $version (validated target)."

$links = [ordered]@{ 'models.json' = '../models.json'; 'settings.json' = '../settings.json'; 'prepare.ps1' = '../prepare.ps1'; 'prepare.sh' = '../prepare.sh' }
foreach ($entry in $links.GetEnumerator()) {
    $path = Join-Path $PSScriptRoot $entry.Key
    $item = Get-Item -LiteralPath $path -Force
    Assert-True ($item.LinkType -eq 'SymbolicLink') "$($entry.Key) is not a symbolic link."
    $expected = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $entry.Value))
    $resolved = [IO.File]::ResolveLinkTarget($path, $false)
    Assert-True ($null -ne $resolved -and $resolved.FullName -ceq $expected) "$($entry.Key) points somewhere unexpected."
}
Assert-True ((Get-Command Start-PiRpc -Module PiRpc -ErrorAction SilentlyContinue) -eq $null) 'module name probe unexpectedly loaded PiRpc.'

$modulePath = Join-Path $PSScriptRoot 'PiRpc.psm1'
Import-Module $modulePath -Force
$exports = @(Get-Command -Module PiRpc | Select-Object -ExpandProperty Name | Sort-Object)
Assert-True (($exports -join ',') -eq 'Send-PiRpcRequest,Start-PiRpc,Stop-PiRpc,Wait-PiRpcEvent,Wait-PiRpcResponse') 'PiRpc.psm1 does not export exactly five functions.'

$savedEnvironment = @('PI_CODING_AGENT_DIR', 'AZURE_PI_TEST_API_KEY') | ForEach-Object { Save-ProcessEnvironment $_ }
$originalLocation = Get-Location
$runtime = Join-Path ([IO.Path]::GetTempPath()) ('pi-sample-015-' + [guid]::NewGuid().ToString('N'))
$script:StartedPids = [Collections.Generic.List[int]]::new()
New-Item -Path $runtime -ItemType Directory -Force | Out-Null
try {
    Push-Location $PSScriptRoot
    Get-ConfigCopy -Directory $runtime
    $env:PI_CODING_AGENT_DIR = $runtime
    if ([string]::IsNullOrWhiteSpace($env:AZURE_PI_TEST_API_KEY)) { $env:AZURE_PI_TEST_API_KEY = 'offline-placeholder-not-a-secret' }
    Invoke-FakeChecks
    Invoke-OfflinePiChecks -ConfigDirectory $runtime -PiPath $pi
    Invoke-UiProbe -PiPath $pi
    Write-Host 'PASS: sample 015 model-free verification completed.'
} finally {
    Pop-Location
    foreach ($saved in $savedEnvironment) { Restore-ProcessEnvironment $saved }
    foreach ($startedProcessId in $script:StartedPids) { Assert-PidExited -ProcessId $startedProcessId -WaitMilliseconds 3000 }
    if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force }
}
