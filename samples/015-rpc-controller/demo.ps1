<#
.SYNOPSIS
    Demonstrate one persistent live Pi RPC controller.

.DESCRIPTION
    Uses the prepared Azure deployment for one prompt/steer/follow-up run and
    one abort run. Responses are acceptance acknowledgements; agent events are
    the lifecycle. The controller always closes stdin in finally.
#>

[CmdletBinding()]
param([int] $TimeoutSeconds = 120)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw "Demo assertion failed: $Message" }
}

function Get-Value {
    param([AllowNull()][object] $Object, [Parameter(Mandatory)][string] $Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Assert-SharedLinks {
    $links = [ordered]@{ 'models.json' = '../models.json'; 'settings.json' = '../settings.json'; 'prepare.ps1' = '../prepare.ps1'; 'prepare.sh' = '../prepare.sh' }
    foreach ($entry in $links.GetEnumerator()) {
        $path = Join-Path $PSScriptRoot $entry.Key
        $item = Get-Item -LiteralPath $path -Force
        Assert-True ($item.LinkType -eq 'SymbolicLink') "$($entry.Key) is not a shared symbolic link."
    }
}

function Send-Request {
    param([Parameter(Mandatory)][object] $Client, [Parameter(Mandatory)][hashtable] $Request)
    return Send-PiRpcRequest -Client $Client -Request $Request
}

function Wait-Success {
    param([Parameter(Mandatory)][object] $Client, [Parameter(Mandatory)][string] $Id, [Parameter(Mandatory)][string] $Command, [int] $Seconds)
    $response = Wait-PiRpcResponse -Client $Client -Id $Id -TimeoutSeconds $Seconds
    Assert-True ([string]$response.command -eq $Command) "response command was not '$Command'."
    Assert-True ($response.success -eq $true) "Pi rejected '$Command': $([string](Get-Value $response 'error'))"
    return $response
}

function Convert-EventToSafeJson {
    param([Parameter(Mandatory)][object] $Event)
    return $Event | ConvertTo-Json -Compress -Depth 100
}

function Get-MessageMarkers {
    param([Parameter(Mandatory)][object[]] $Events)
    $joined = ($Events | ForEach-Object { Convert-EventToSafeJson $_ }) -join "`n"
    return $joined
}

Assert-True ($TimeoutSeconds -ge 30) 'TimeoutSeconds must be at least 30 seconds.'
Assert-True ($null -ne (Get-Command pwsh -ErrorAction SilentlyContinue)) "Required command 'pwsh' was not found."
$pi = Get-Command pi -ErrorAction Stop
Assert-SharedLinks
foreach ($name in @('AZURE_PI_TEST_DEPLOYMENT', 'AZURE_PI_TEST_API_KEY')) {
    Assert-True (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) "Missing '$name'. Source ./prepare.ps1 first."
}
Assert-True (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('PI_CODING_AGENT_DIR'))) 'PI_CODING_AGENT_DIR is empty. Source ./prepare.ps1 from this directory.'
Assert-True ([IO.Path]::GetFullPath($env:PI_CODING_AGENT_DIR) -ceq [IO.Path]::GetFullPath($PSScriptRoot)) 'PI_CODING_AGENT_DIR must point to this sample; source ./prepare.ps1 here.'
$version = (& $pi.Source --version).Trim()
Write-Host "Pi version: $version (sample validated with 0.80.6)."
if ($version -ne '0.80.6') { Write-Warning 'The sample may need protocol adjustments for this installed Pi version.' }
$model = "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
Write-Host "Model: $model"

Import-Module (Join-Path $PSScriptRoot 'PiRpc.psm1') -Force
$arguments = @('--mode', 'rpc', '--no-session', '--offline', '--no-approve', '--no-tools', '--no-extensions', '--no-skills', '--no-prompt-templates', '--model', $model)
$client = $null
$events = [Collections.Generic.List[object]]::new()
$agentEndCount = 0
$sawQueueUpdate = $false
$sawFirstTextDelta = $false
$sawAbortStop = $false
try {
    $client = Start-PiRpc -ExecutablePath $pi.Source -ArgumentList $arguments -WorkingDirectory $PSScriptRoot

    # Pipeline discovery requests before waiting makes response order visibly
    # independent of request order, even before model work begins.
    $stateId = Send-Request $client @{ type = 'get_state' }
    $modelsId = Send-Request $client @{ type = 'get_available_models' }
    $models = Wait-Success $client $modelsId 'get_available_models' 15
    $state = Wait-Success $client $stateId 'get_state' 15
    Write-Host "Session: $([string]$state.data.sessionId); configured models: $(@($models.data.models).Count)"

    $promptMarker = 'RPC015-RUN-MARKER'
    $steerMarker = 'RPC015-STEER-MARKER'
    $followMarker = 'RPC015-FOLLOW-MARKER'
    $prompt = "Answer with a deliberately long numbered explanation of JSONL process integration. Include the exact marker $promptMarker once. Do not use tools. Keep each item short so the controller has time to steer."
    $promptId = Send-Request $client @{ type = 'prompt'; message = $prompt }
    $promptResponse = Wait-Success $client $promptId 'prompt' 30
    Write-Host 'prompt response: accepted; this is not completion.'

    $sawAgentStart = $false
    while (-not $sawAgentStart) {
        $event = Wait-PiRpcEvent -Client $client -TimeoutSeconds $TimeoutSeconds
        [void]$events.Add($event)
        if ([string]$event.type -eq 'agent_start') { $sawAgentStart = $true }
        if ([string]$event.type -eq 'message_update' -and [string]$event.assistantMessageEvent.type -eq 'text_delta') {
            $sawFirstTextDelta = $true
            Write-Host -NoNewline ([string]$event.assistantMessageEvent.delta)
        }
    }
    $stateId = Send-Request $client @{ type = 'get_state' }
    $activeState = Wait-Success $client $stateId 'get_state' 15
    Assert-True ($activeState.data.isStreaming -eq $true) 'The first run finished before steer could be sent; rerun with a longer prompt.'
    $steerId = Send-Request $client @{ type = 'steer'; message = "Continue, then include $steerMarker as its own line." }
    [void](Wait-Success $client $steerId 'steer' 30)
    Write-Host "`nsteer response: accepted while isStreaming=true."
    $followId = Send-Request $client @{ type = 'follow_up'; message = "After the continuation, add one final line containing $followMarker." }
    [void](Wait-Success $client $followId 'follow_up' 30)
    Write-Host 'follow_up response: queued; watch queue_update and agent_settled.'

    while ($true) {
        $event = Wait-PiRpcEvent -Client $client -TimeoutSeconds $TimeoutSeconds
        [void]$events.Add($event)
        $type = [string]$event.type
        if ($type -eq 'message_update' -and [string]$event.assistantMessageEvent.type -eq 'text_delta') {
            $sawFirstTextDelta = $true
            Write-Host -NoNewline ([string]$event.assistantMessageEvent.delta)
        } elseif ($type -eq 'queue_update') {
            $sawQueueUpdate = $true
            Write-Host "`nqueue_update observed."
        } elseif ($type -eq 'agent_end') {
            $agentEndCount++
            Write-Host "`nagent_end observed (#$agentEndCount); not treating it as settled."
        } elseif ($type -eq 'agent_settled') {
            Write-Host "`nagent_settled observed."
            break
        }
    }
    Assert-True ($agentEndCount -ge 1) 'No low-level agent_end event was observed.'
    $markerLog = Get-MessageMarkers -Events $events
    Assert-True ($markerLog.Contains($steerMarker, [StringComparison]::Ordinal) -and $markerLog.Contains($followMarker, [StringComparison]::Ordinal)) 'Steer/follow-up markers were not present in the reassembled event log.'

    $lastId = Send-Request $client @{ type = 'get_last_assistant_text' }
    $last = Wait-Success $client $lastId 'get_last_assistant_text' 15
    $statsId = Send-Request $client @{ type = 'get_session_stats' }
    $stats = Wait-Success $client $statsId 'get_session_stats' 15
    Assert-True ($null -eq $last.data.text -or $last.data.text -is [string]) 'get_last_assistant_text returned an unexpected shape.'
    Write-Host "Final assistant text: $([string]$last.data.text)"
    Write-Host "Session stats: $($stats.data | ConvertTo-Json -Compress -Depth 10)"
    Write-Host "The final text may belong to the follow-up; event log runs=$agentEndCount, queue_update=$sawQueueUpdate."

    $sawFirstTextDelta = $false
    $abortPromptId = Send-Request $client @{ type = 'prompt'; message = 'Give a very long numbered answer about bounded queues. Include marker RPC015-ABORT-RUN and do not use tools.' }
    [void](Wait-Success $client $abortPromptId 'prompt' 30)
    while (-not $sawFirstTextDelta) {
        $event = Wait-PiRpcEvent -Client $client -TimeoutSeconds $TimeoutSeconds
        [void]$events.Add($event)
        if ([string]$event.type -eq 'message_update' -and [string]$event.assistantMessageEvent.type -eq 'text_delta') {
            $sawFirstTextDelta = $true
            Write-Host "`nsecond prompt produced its first text delta."
        }
    }
    $abortId = Send-Request $client @{ type = 'abort' }
    [void](Wait-Success $client $abortId 'abort' 30)
    Write-Host 'abort response: accepted; waiting for aborted run to settle.'
    while ($true) {
        $event = Wait-PiRpcEvent -Client $client -TimeoutSeconds $TimeoutSeconds
        [void]$events.Add($event)
        $serialized = Convert-EventToSafeJson -Event $event
        if ($serialized.Contains('"aborted"', [StringComparison]::Ordinal) -or $serialized.Contains('"stopReason":"error"', [StringComparison]::Ordinal)) { $sawAbortStop = $true }
        if ([string]$event.type -eq 'agent_settled') { break }
    }
    Assert-True $sawAbortStop 'Abort did not expose an aborted/error assistant event or message stop reason.'
    $finalStateId = Send-Request $client @{ type = 'get_state' }
    $finalState = Wait-Success $client $finalStateId 'get_state' 15
    Assert-True ($finalState.data.isStreaming -eq $false -and [int]$finalState.data.pendingMessageCount -eq 0) 'settled state still reports active or queued work.'
    Write-Host 'PASS: live RPC lifecycle, steer, follow-up, settlement, and abort were observed.'
} catch {
    throw
} finally {
    if ($null -ne $client) {
        Stop-PiRpc -Client $client -TimeoutSeconds 5
        if ($client.CleanupForced) { Write-Warning 'Shutdown required forced cleanup; inspect protocol drift or a stuck extension.' }
        else { Write-Host "Shutdown: graceful stdin EOF (exit code $($client.ExitCode))." }
    }
}
