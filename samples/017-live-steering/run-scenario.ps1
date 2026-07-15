[CmdletBinding()]
param([int]$TimeoutSeconds=180, [switch]$VerifyAbort, [string]$Model='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$here=$PSScriptRoot
Import-Module (Join-Path $here 'lib/ScenarioRpc.psm1') -Force

function New-LiveClient {
    $resolvedModel = if ([string]::IsNullOrWhiteSpace($Model)) { "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT" } else { $Model }
    $arguments=@('--mode','rpc','--no-session','--model',$resolvedModel,'--no-extensions','-e','./extensions/live-guidance.ts','--no-builtin-tools','--tools','guidance_checkpoint','--no-skills','--no-prompt-templates','--no-context-files','--no-themes')
    Start-ScenarioRpc -Arguments $arguments -WorkingDirectory $here
}
function Get-Field($object,[string]$name) {
    if ($null -eq $object) { return $null }
    $property = $object.PSObject.Properties[$name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
function Invoke-Guide($client,[string]$text) {
    $action = ($text -split '\s+', 3)[1]
    [void](Send-ScenarioRpc $client @{type='prompt';message=$text} 15)
    $event = Wait-ScenarioEvent $client { param($e)
        (Get-Field $e 'type') -eq 'extension_ui_request' -and
        (Get-Field $e 'method') -eq 'notify' -and
        (Get-Field $e 'message') -like "*`"action`":`"$action`"*"
    } 15
    $message = Get-Field $event 'message'
    if ($message -isnot [string]) { throw 'Guide notification had an unexpected shape.' }
    return ($message | ConvertFrom-Json -Depth 20)
}
function Wait-ToolStart($client,[string]$id) {
    Wait-ScenarioEvent $client { param($e)
        (Get-Field $e 'type') -eq 'tool_execution_start' -and
        (Get-Field $e 'toolName') -eq 'guidance_checkpoint' -and
        (Get-Field (Get-Field $e 'args') 'checkpointId') -eq $id
    } $TimeoutSeconds
}
function Wait-Custom($client,[string]$class,[string]$id) {
    try {
        $event=Wait-ScenarioEvent $client { param($e)
            (Get-Field $e 'type') -eq 'message_start' -and
            (Get-Field (Get-Field $e 'message') 'role') -eq 'custom' -and
            (Get-Field (Get-Field $e 'message') 'customType') -eq 'sample017-guidance' -and
            (Get-Field (Get-Field (Get-Field $e 'message') 'details') 'class') -eq $class
        } $TimeoutSeconds
        $observedId=Get-Field (Get-Field (Get-Field $event 'message') 'details') 'id'
        if ($observedId -ne $id) { throw "custom delivery ID did not match the queued opaque ID for $class." }
        return $event
    } catch {
        Receive-ScenarioRpc $client
        $observed=@($client.Events | Where-Object {
            (Get-Field $_ 'type') -eq 'message_start' -and
            (Get-Field (Get-Field $_ 'message') 'customType') -eq 'sample017-guidance' -and
            (Get-Field (Get-Field (Get-Field $_ 'message') 'details') 'class') -eq $class
        } | ForEach-Object { Get-Field (Get-Field (Get-Field $_ 'message') 'details') 'id' })
        if ($observed.Count -gt 0) { throw "Timed out waiting for $class custom delivery with expected opaque ID; observed $($observed -join ',')." }
        throw
    }
}
function Assert-NoBufferedCustom($client,[string]$class) {
    Receive-ScenarioRpc $client
    if (@($client.Events | Where-Object {
        (Get-Field $_ 'type') -eq 'message_start' -and (Get-Field (Get-Field $_ 'message') 'customType') -eq 'sample017-guidance' -and
        (Get-Field (Get-Field (Get-Field $_ 'message') 'details') 'class') -eq $class
    }).Count -ne 0) { throw "$class was delivered too early." }
}
function Remove-BufferedEvents($client,[string]$type) {
    for ($i=$client.Events.Count-1; $i -ge 0; $i--) {
        if ((Get-Field $client.Events[$i] 'type') -eq $type) { $client.Events.RemoveAt($i) }
    }
}

$client=$null
try {
    if ([string]::IsNullOrWhiteSpace($env:AZURE_PI_TEST_DEPLOYMENT) -or [string]::IsNullOrWhiteSpace($env:AZURE_PI_TEST_API_KEY)) { throw 'Prepared Azure deployment/key variables are required.' }
    $client=New-LiveClient
    $checkpoint="cp-$([guid]::NewGuid().ToString('N'))"
    $steer="s-$([guid]::NewGuid().ToString('N'))"
    $follow="f-$([guid]::NewGuid().ToString('N'))"
    $next="n-$([guid]::NewGuid().ToString('N'))"
    [void](Send-ScenarioRpc $client @{type='prompt';message="Call guidance_checkpoint now with checkpointId $checkpoint before producing any prose. After it is released, obey the queued steering and follow-up messages, then answer in exactly one short sentence."} 15)
    [void](Wait-ToolStart $client $checkpoint)
    Write-Host 'checkpoint active'
    $steerNotice=Invoke-Guide $client "/guide steer $steer"
    $followNotice=Invoke-Guide $client "/guide follow-up $follow"
    $nextNotice=Invoke-Guide $client "/guide next-turn $next"
    foreach ($notice in @($steerNotice,$followNotice,$nextNotice)) {
        if ((Get-Field $notice 'state') -ne 'queued' -or [string]::IsNullOrWhiteSpace([string](Get-Field $notice 'id'))) { throw 'Guide queue notification had an unexpected shape.' }
    }
    Assert-NoBufferedCustom $client 'next-turn'
    Write-Host 'steer queued -> follow-up queued -> next-turn held'
    [void](Invoke-Guide $client "/guide release $checkpoint")
    [void](Wait-ScenarioEvent $client { param($e)
        (Get-Field $e 'type') -eq 'tool_execution_end' -and
        (Get-Field $e 'toolName') -eq 'guidance_checkpoint' -and
        -not (Get-Field $e 'isError')
    } $TimeoutSeconds)
    [void](Wait-Custom $client 'steer' (Get-Field $steerNotice 'id'))
    Write-Host 'released -> steer delivered'
    [void](Wait-Custom $client 'follow-up' (Get-Field $followNotice 'id'))
    [void](Wait-ScenarioEvent $client { param($e) (Get-Field $e 'type') -eq 'agent_end' } $TimeoutSeconds)
    [void](Wait-ScenarioEvent $client { param($e) (Get-Field $e 'type') -eq 'agent_settled' } $TimeoutSeconds)
    Assert-NoBufferedCustom $client 'next-turn'
    Write-Host 'follow-up delivered -> agent settled'

    [void](Send-ScenarioRpc $client @{type='prompt';message='Respond briefly without calling a tool.'} 15)
    [void](Wait-Custom $client 'next-turn' (Get-Field $nextNotice 'id'))
    [void](Wait-ScenarioEvent $client { param($e) (Get-Field $e 'type') -eq 'agent_settled' } $TimeoutSeconds)
    Write-Host 'external prompt -> next-turn delivered -> settled'

    $note="note-$([guid]::NewGuid().ToString('N'))"
    $ask="ask-$([guid]::NewGuid().ToString('N'))"
    [void](Invoke-Guide $client "/guide note $note")
    [void](Invoke-Guide $client "/guide ask $ask")
    [void](Wait-ScenarioEvent $client { param($e) (Get-Field $e 'type') -eq 'agent_settled' } $TimeoutSeconds)
    $statusData=Invoke-Guide $client '/guide status'
    if ((Get-Field (Get-Field $statusData 'lastInput') 'source') -ne 'extension') { throw 'sendUserMessage input source was not extension.' }
    $entries=(Send-ScenarioRpc $client @{type='get_entries'} 15).data.entries
    $messages=(Send-ScenarioRpc $client @{type='get_messages'} 15).data.messages
    $notes=@($entries | Where-Object { (Get-Field $_ 'type') -eq 'custom' -and (Get-Field $_ 'customType') -eq 'sample017-note' -and (Get-Field (Get-Field $_ 'data') 'text') -eq $note })
    if ($notes.Count -ne 1) { throw 'note persistence proof failed.' }
    $noteId=Get-Field (Get-Field $notes[0] 'data') 'id'
    $audits=@($entries | Where-Object { (Get-Field $_ 'type') -eq 'custom' -and (Get-Field $_ 'customType') -eq 'sample017-context-audit' -and (Get-Field (Get-Field $_ 'data') 'id') -eq $noteId })
    if ($audits.Count -ne 1 -or (Get-Field (Get-Field $audits[0] 'data') 'present')) { throw 'note context-isolation proof failed.' }
    $messageJson=$messages | ConvertTo-Json -Compress -Depth 100
    if ($messageJson -like "*$note*" -or $messageJson -notlike "*$ask*") { throw 'note leaked or ordinary ask message was absent.' }
    Write-Host 'note persisted -> context audit absent -> extension user message delivered -> settled'
    Stop-ScenarioRpc $client; $client=$null

    if ($VerifyAbort) {
        $client=New-LiveClient
        $checkpoint="cp-$([guid]::NewGuid().ToString('N'))"
        [void](Send-ScenarioRpc $client @{type='prompt';message="Call guidance_checkpoint with checkpointId $checkpoint before prose."} 15)
        [void](Wait-ToolStart $client $checkpoint)
        Remove-BufferedEvents $client 'queue_update'
        [void](Send-ScenarioRpc $client @{type='steer';message="native-s-$([guid]::NewGuid().ToString('N'))"} 15)
        $queueOne=Wait-ScenarioEvent $client { param($e)
            (Get-Field $e 'type') -eq 'queue_update' -and
            @((Get-Field $e 'steering')).Count + @((Get-Field $e 'followUp')).Count -eq 1
        } 15
        if (@((Get-Field $queueOne 'steering')).Count + @((Get-Field $queueOne 'followUp')).Count -ne 1) { throw 'first native queue update did not report one pending item.' }
        [void](Send-ScenarioRpc $client @{type='follow_up';message="native-f-$([guid]::NewGuid().ToString('N'))"} 15)
        $queueTwo=Wait-ScenarioEvent $client { param($e)
            (Get-Field $e 'type') -eq 'queue_update' -and
            @((Get-Field $e 'steering')).Count + @((Get-Field $e 'followUp')).Count -eq 2
        } 15
        if (@((Get-Field $queueTwo 'steering')).Count + @((Get-Field $queueTwo 'followUp')).Count -ne 2) { throw 'second native queue update did not report two pending items.' }
        $state=(Send-ScenarioRpc $client @{type='get_state'} 15).data
        if ($state.pendingMessageCount -ne 2) { throw "Pi 0.80.6 queue shape drift: expected 2 pending before abort, got $($state.pendingMessageCount)." }
        [void](Send-ScenarioRpc $client @{type='abort'} $TimeoutSeconds)
        [void](Wait-ScenarioEvent $client { param($e) (Get-Field $e 'type') -eq 'agent_settled' } $TimeoutSeconds)
        [void](Wait-ScenarioEvent $client { param($e)
            (Get-Field $e 'type') -eq 'queue_update' -and
            @((Get-Field $e 'steering')).Count + @((Get-Field $e 'followUp')).Count -eq 0
        } 15)
        $after=(Send-ScenarioRpc $client @{type='get_state'} 15).data
        if ($after.pendingMessageCount -ne 0) { throw "Pi 0.80.6 abort/queue contract drift: expected 0 pending after an active run aborted, got $($after.pendingMessageCount)." }
        Write-Host 'native queues: 2 pending -> abort active run -> 0 pending'
        Stop-ScenarioRpc $client; $client=$null
    }
} finally { if ($client) { try { Stop-ScenarioRpc $client } catch { Write-Warning $_ } } }
