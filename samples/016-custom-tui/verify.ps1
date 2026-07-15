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
    return [pscustomobject]@{
        Name = $Name
        Present = $variables.Contains($Name)
        Value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    }
}

function Restore-EnvironmentVariable {
    param([Parameter(Mandatory)][object] $Saved)
    if ($Saved.Present) { [Environment]::SetEnvironmentVariable($Saved.Name, $Saved.Value, 'Process') }
    else { [Environment]::SetEnvironmentVariable($Saved.Name, $null, 'Process') }
}

function Get-JsonLines {
    param([Parameter(Mandatory)][string] $Text)
    $items = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            try { $items += ($line | ConvertFrom-Json -Depth 100) }
            catch { throw "Pi emitted malformed JSONL: $line" }
        }
    }
    return $items
}

function Invoke-Pi {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $InputLines,
        [int] $TimeoutMilliseconds = 10000
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command pi -ErrorAction Stop).Source
    $start.WorkingDirectory = $PSScriptRoot
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void] $start.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    Assert-True $process.Start() 'Pi process did not start'

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    foreach ($line in $InputLines) { $process.StandardInput.WriteLine($line) }
    $process.StandardInput.Close()

    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
        try { $process.Kill($true) } catch { $process.Kill() }
        throw "Pi did not exit within ${TimeoutMilliseconds}ms."
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Get-Response {
    param([Parameter(Mandatory)][object[]] $Events, [Parameter(Mandatory)][string] $Id, [Parameter(Mandatory)][string] $Command)
    $responses = @($Events | Where-Object { $_.type -eq 'response' -and $_.id -eq $Id -and $_.command -eq $Command })
    Assert-True ($responses.Count -eq 1) "missing correlated response for $Command ($Id)"
    Assert-True ([bool]$responses[0].success) "response for $Command ($Id) was unsuccessful"
    return $responses[0]
}

function Assert-NoOperationalEvents {
    param([Parameter(Mandatory)][object[]] $Events, [Parameter(Mandatory)][string] $Message)
    $bad = @($Events | Where-Object { $_.type -match '^(provider|agent|turn|message|tool_execution)_' })
    Assert-True ($bad.Count -eq 0) $Message
}

function Invoke-RpcVerification {
    $input = @(
        '{"id":"commands","type":"get_commands"}',
        '{"id":"status","type":"prompt","message":"/dashboard status"}',
        '{"id":"off","type":"prompt","message":"/dashboard off"}',
        '{"id":"on","type":"prompt","message":"/dashboard on"}',
        '{"id":"checkpoint","type":"prompt","message":"/dashboard checkpoint verify"}',
        '{"id":"entries","type":"get_entries"}',
        '{"id":"messages","type":"get_messages"}'
    )
    $run = Invoke-Pi -Arguments @(
        '--no-extensions', '-e', './extensions/activity-dashboard.ts', '--mode', 'rpc',
        '--no-builtin-tools', '--tools', 'dashboard_checkpoint', '--offline', '--no-session'
    ) -InputLines $input -TimeoutMilliseconds 10000

    Assert-True ($run.ExitCode -eq 0) "RPC Pi exited $($run.ExitCode): $($run.Stderr)"
    Assert-True ($run.Stderr -notmatch '(?i)(extension load error|unhandled rejection)') 'RPC stderr contains an extension load error or unhandled rejection'
    $events = @(Get-JsonLines $run.Stdout)

    $commandsResponse = Get-Response $events 'commands' 'get_commands'
    $commands = @($commandsResponse.data.commands | Where-Object { $_.name -eq 'dashboard' -and $_.source -eq 'extension' })
    Assert-True ($commands.Count -eq 1) 'dashboard command was not registered exactly once'
    $expectedPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'extensions/activity-dashboard.ts'))
    Assert-True ([IO.Path]::GetFullPath([string]$commands[0].sourceInfo.path) -eq $expectedPath) 'dashboard command came from an unexpected extension path'

    $startupStatus = @($events | Where-Object { $_.type -eq 'extension_ui_request' -and $_.method -eq 'setStatus' -and $_.statusKey -eq 'sample-016-dashboard' })
    $startupWidget = @($events | Where-Object { $_.type -eq 'extension_ui_request' -and $_.method -eq 'setWidget' -and $_.widgetKey -eq 'sample-016-dashboard' -and $_.PSObject.Properties['widgetLines'] -and $_.widgetLines.Count -eq 4 })
    Assert-True ($startupStatus.Count -ge 1) 'RPC startup did not emit the keyed dashboard status'
    Assert-True ($startupWidget.Count -ge 1) 'RPC startup did not emit a four-line dashboard widget'

    $statusResponse = Get-Response $events 'status' 'prompt'
    $offResponse = Get-Response $events 'off' 'prompt'
    $onResponse = Get-Response $events 'on' 'prompt'
    $checkpointResponse = Get-Response $events 'checkpoint' 'prompt'
    [void]$statusResponse; [void]$offResponse; [void]$onResponse; [void]$checkpointResponse
    Assert-NoOperationalEvents $events 'RPC command prompts emitted provider/agent/turn/message/tool events'

    $notifies = @($events | Where-Object { $_.type -eq 'extension_ui_request' -and $_.method -eq 'notify' })
    Assert-True ($notifies.Count -ge 2) 'RPC commands did not emit concise notifications'
    Assert-True ((@($notifies | Where-Object { $_.message -match 'checkpoint-tool: active' })).Count -eq 1) 'status did not report checkpoint-tool: active'
    Assert-True ((@($notifies | Where-Object { $_.message -eq 'Dashboard checkpoint recorded: verify' })).Count -eq 1) 'checkpoint success notification was absent'

    $clears = @($events | Where-Object { $_.type -eq 'extension_ui_request' -and $_.method -eq 'setStatus' -and $_.statusKey -eq 'sample-016-dashboard' -and (-not $_.PSObject.Properties['statusText'] -or $null -eq $_.statusText) })
    $widgetClears = @($events | Where-Object { $_.type -eq 'extension_ui_request' -and $_.method -eq 'setWidget' -and $_.widgetKey -eq 'sample-016-dashboard' -and (-not $_.PSObject.Properties['widgetLines'] -or $null -eq $_.widgetLines) })
    Assert-True ($clears.Count -ge 2) 'status clear was not emitted for off and shutdown'
    Assert-True ($widgetClears.Count -ge 2) 'widget clear was not emitted for off and shutdown'
    $replacements = @($events | Where-Object { $_.type -eq 'extension_ui_request' -and $_.method -eq 'setWidget' -and $_.widgetKey -eq 'sample-016-dashboard' -and $_.PSObject.Properties['widgetLines'] -and $_.widgetLines.Count -eq 4 })
    Assert-True ($replacements.Count -ge 2) 'widget replacement was not emitted for startup and on'

    $entriesResponse = Get-Response $events 'entries' 'get_entries'
    $entries = @($entriesResponse.data.entries | Where-Object { $_.type -eq 'custom' -and $_.customType -eq 'dashboard-checkpoint' })
    Assert-True ($entries.Count -eq 1) 'get_entries did not return exactly one dashboard checkpoint entry'
    $checkpoint = $entries[0].data
    Assert-True ($checkpoint.label -eq 'verify') 'checkpoint entry label was not verify'
    Assert-True ([int64]$checkpoint.activeToolCount -ge 0 -and ($checkpoint.activeToolCount -is [int] -or $checkpoint.activeToolCount -is [long])) 'checkpoint tool count was not a non-negative integer'
    Assert-True (@('idle','agent-running','turn-running','tool-running','settling') -contains [string]$checkpoint.lifecycle) 'checkpoint lifecycle was invalid'
    foreach ($field in @('label','model','thinkingLevel','latestCompletedTool','createdAt')) {
        Assert-True (-not ([string]$checkpoint.$field -match '[\x00-\x1F\x7F-\x9F]')) "checkpoint field $field contained a control character"
    }
    $timestampValid = $true
    try { [void][DateTimeOffset]::Parse([string]$checkpoint.createdAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    catch { $timestampValid = $false }
    Assert-True $timestampValid 'checkpoint timestamp was not parseable ISO text'

    $messagesResponse = Get-Response $events 'messages' 'get_messages'
    Assert-True (@($messagesResponse.data.messages).Count -eq 0) 'display-only checkpoint entry appeared in model messages'
    Write-Host 'PASS: offline RPC lifecycle, keyed UI, command, tool activation, and entry boundary.'
}

function Invoke-HeadlessVerification {
    $printRun = Invoke-Pi -Arguments @(
        '--no-extensions', '-e', './extensions/activity-dashboard.ts', '--no-builtin-tools',
        '--tools', 'dashboard_checkpoint', '--offline', '--no-session', '-p', '/dashboard checkpoint'
    ) -InputLines @() -TimeoutMilliseconds 5000
    Assert-True ($printRun.ExitCode -eq 0) "print command exited $($printRun.ExitCode): $($printRun.Stderr)"
    Assert-True ($printRun.Stdout -notmatch '(?i)(provider|api key|credential|extension_ui_request)') 'print stdout contained provider/UI noise'
    Assert-True ($printRun.Stderr -match 'deterministic manual fallback') 'print mode did not report the deterministic manual fallback on stderr'
    Assert-True ($printRun.Stderr -match 'Dashboard checkpoint recorded: manual') 'print mode did not record the manual checkpoint'
    Write-Host 'PASS: print mode stayed headless, deterministic, and stdout-safe.'

    $jsonRun = Invoke-Pi -Arguments @(
        '--no-extensions', '-e', './extensions/activity-dashboard.ts', '--no-builtin-tools',
        '--tools', 'dashboard_checkpoint', '--offline', '--no-session', '--mode', 'json', '--approve', '/dashboard status'
    ) -InputLines @() -TimeoutMilliseconds 5000
    Assert-True ($jsonRun.ExitCode -eq 0) "JSON command exited $($jsonRun.ExitCode): $($jsonRun.Stderr)"
    $jsonEvents = @(Get-JsonLines $jsonRun.Stdout)
    Assert-NoOperationalEvents $jsonEvents 'JSON status emitted provider/agent/turn/message/tool events'
    Assert-True (@($jsonEvents | Where-Object { $_.type -eq 'extension_ui_request' }).Count -eq 0) 'JSON mode emitted extension UI requests'
    Write-Host 'PASS: JSON mode stayed parseable and made no UI request.'
}

function Invoke-StaticVerification {
    $extension = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'extensions/activity-dashboard.ts')
    foreach ($requiredLink in @('models.json','settings.json','prepare.ps1','prepare.sh')) {
        $link = Get-Item -LiteralPath (Join-Path $PSScriptRoot $requiredLink)
        Assert-True ($link.LinkType -eq 'SymbolicLink') "$requiredLink is not a symbolic link"
        $resolvedLink = [IO.Path]::GetFullPath((Join-Path (Split-Path $link.FullName) $link.Target))
        $resolvedShared = (Resolve-Path -LiteralPath (Join-Path (Split-Path $PSScriptRoot) $requiredLink)).Path
        Assert-True ($resolvedLink -eq $resolvedShared) "$requiredLink does not resolve to the shared file"
    }
    foreach ($needle in @(
        'sample-016-dashboard','dashboard-checkpoint','registerCommand(COMMAND_NAME',
        'registerShortcut(Key.ctrlShift("d")','registerTool({','name: TOOL_NAME',
        'renderCall(args','renderResult(result','registerEntryRenderer<CheckpointData>'
    )) { Assert-True ($extension.Contains($needle)) "extension missed static contract marker: $needle" }
    Assert-True ($extension -notmatch '(?m)^\s*import\s+.*(?:node:|child_process|undici|fetch)') 'extension imports a network or child-process capability'
    Write-Host 'PASS: static layout and focused-extension checks.'
}

$requiredCommands = @('pwsh','pi')
foreach ($command in $requiredCommands) {
    if ($null -eq (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command '$command' was not found." }
}
Write-Host "pwsh: $(& pwsh --version)"
Write-Host "pi: $(& pi --version)"

$savedEnvironment = @('PI_CODING_AGENT_DIR','PI_OFFLINE') | ForEach-Object { Save-EnvironmentVariable $_ }
$originalLocation = Get-Location
$temporaryConfig = Join-Path ([IO.Path]::GetTempPath()) ("pi-016-custom-tui-" + [Guid]::NewGuid().ToString('N'))
try {
    Set-Location $PSScriptRoot
    [void](New-Item -ItemType Directory -Path $temporaryConfig -Force)
    $env:PI_CODING_AGENT_DIR = $temporaryConfig
    $env:PI_OFFLINE = '1'
    Invoke-StaticVerification
    Invoke-RpcVerification
    Invoke-HeadlessVerification
}
finally {
    Set-Location $originalLocation
    foreach ($saved in $savedEnvironment) { Restore-EnvironmentVariable $saved }
    if (Test-Path -LiteralPath $temporaryConfig) { Remove-Item -LiteralPath $temporaryConfig -Recurse -Force }
}

Write-Host 'PASS: sample 016 verification completed.'
