[CmdletBinding()]
param([int]$TimeoutSeconds=20)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$here=$PSScriptRoot
$oldOffline=$env:PI_OFFLINE
$oldAgentDir=$env:PI_CODING_AGENT_DIR
$oldLocation=(Get-Location).Path
$client=$null
$ownedPid=$null
try {
    Write-Host "Node: $(node --version)"
    Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
    Write-Host "Pi: $(pi --version) (validated: 0.80.6)"
    $expectedFiles=@(
        'README.md','run-scenario.ps1','verify.ps1','verify-live.ps1',
        'models.json','settings.json','prepare.ps1','prepare.sh',
        'extensions/live-guidance.ts','lib/ScenarioRpc.psm1','lib/guidance-state.ts',
        'tests/guidance-state.test.ts'
    )
    foreach ($relative in $expectedFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $here $relative))) { throw "missing expected sample path: $relative" }
    }
    foreach ($link in @('models.json','settings.json','prepare.ps1','prepare.sh')) {
        $item=Get-Item -LiteralPath (Join-Path $here $link) -Force
        if (-not $item.LinkType) { throw "$link must be a symlink." }
        $expected="../$link"
        if ([string]$item.Target -ne $expected) { throw "$link target '$($item.Target)' is not '$expected'." }
    }
    $auth=Get-Item -LiteralPath (Join-Path $here 'auth.json') -Force -ErrorAction SilentlyContinue
    if ($auth -and $auth.LinkType) { throw 'auth.json is runtime state and must not be a symlink.' }
    $actualFiles=@(Get-ChildItem -LiteralPath $here -Recurse -File -Force | ForEach-Object {
        $relative=$_.FullName.Substring($here.Length+1).Replace('\','/')
        if ($relative -ne 'auth.json') { $relative }
    })
    $unexpected=@($actualFiles | Where-Object { $_ -notin $expectedFiles })
    if ($unexpected.Count) { throw "unexpected generated sample file: $($unexpected[0])" }
    & node --experimental-strip-types (Join-Path $here 'tests/guidance-state.test.ts')
    if ($LASTEXITCODE -ne 0) { throw 'model-free state tests failed' }

    $env:PI_OFFLINE='1'; $env:PI_CODING_AGENT_DIR=$here
    Import-Module (Join-Path $here 'lib/ScenarioRpc.psm1') -Force
    $args=@('--mode','rpc','--no-session','--offline','--no-extensions','-e','./extensions/live-guidance.ts','--no-builtin-tools','--tools','guidance_checkpoint','--no-skills','--no-prompt-templates','--no-context-files','--no-themes')
    $client=Start-ScenarioRpc -Arguments $args -WorkingDirectory $here
    $ownedPid=$client.Pump.Process.Id
    $commands=Send-ScenarioRpc $client @{type='get_commands'} $TimeoutSeconds
    $guide=@($commands.data.commands | Where-Object name -eq 'guide')
    $expectedExtension=(Resolve-Path (Join-Path $here 'extensions/live-guidance.ts')).Path
    if ($guide.Count -ne 1 -or $guide[0].source -ne 'extension' -or $guide[0].sourceInfo.path -ne $expectedExtension) { throw '/guide was not registered from the expected extension file.' }

    [void](Send-ScenarioRpc $client @{type='prompt';message='/guide status'} $TimeoutSeconds)
    $status=Wait-ScenarioEvent $client { param($e) $e.type -eq 'extension_ui_request' -and $e.method -eq 'notify' -and $e.message -like '*"action":"status"*' } $TimeoutSeconds
    $payload=$status.message | ConvertFrom-Json
    if (-not $payload.guidanceCheckpointActive -or $payload.run -ne 'idle') { throw 'status did not prove the one-tool idle policy.' }

    foreach ($command in @('/guide steer x','/guide follow-up x','/guide release unknown1','/guide ask   ',('/guide note '+('é'*513)))) {
        [void](Send-ScenarioRpc $client @{type='prompt';message=$command} $TimeoutSeconds)
    }
    $rejected=0
    while ($rejected -lt 5) {
        $event=Wait-ScenarioEvent $client { param($e) $e.type -eq 'extension_ui_request' -and $e.method -eq 'notify' -and $e.message -like '*"state":"rejected"*' } $TimeoutSeconds
        $rejected++
    }

    $noteMarker="offline-$([guid]::NewGuid().ToString('N'))"
    [void](Send-ScenarioRpc $client @{type='prompt';message="/guide note $noteMarker"} $TimeoutSeconds)
    $entries=Send-ScenarioRpc $client @{type='get_entries'} $TimeoutSeconds
    $messages=Send-ScenarioRpc $client @{type='get_messages'} $TimeoutSeconds
    $notes=@($entries.data.entries | Where-Object { $_.type -eq 'custom' -and $_.customType -eq 'sample017-note' })
    if ($notes.Count -ne 1) { throw 'offline note was not persisted exactly once.' }
    if (($messages | ConvertTo-Json -Depth 100) -like "*$noteMarker*") { throw 'offline note leaked into agent messages.' }
    Stop-ScenarioRpc $client; $client=$null
    if ($ownedPid -and (Get-Process -Id $ownedPid -ErrorAction SilentlyContinue)) { throw 'owned Pi process remained after verification.' }
    Write-Host 'PASS: sample 017 model-free verification completed without credentials or model calls.'
} finally {
    if ($client) { try { Stop-ScenarioRpc $client } catch { Write-Warning $_ } }
    $env:PI_OFFLINE=$oldOffline; $env:PI_CODING_AGENT_DIR=$oldAgentDir
    if ((Get-Location).Path -ne $oldLocation) { Set-Location $oldLocation }
}
