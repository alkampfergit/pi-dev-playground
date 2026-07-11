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
    return [pscustomobject]@{ Name = $Name; Present = $variables.Contains($Name); Value = [Environment]::GetEnvironmentVariable($Name, 'Process') }
}

function Restore-EnvironmentVariable {
    param([Parameter(Mandatory)][object] $Saved)
    if ($Saved.Present) { [Environment]::SetEnvironmentVariable($Saved.Name, $Saved.Value, 'Process') }
    else { [Environment]::SetEnvironmentVariable($Saved.Name, $null, 'Process') }
}

function Invoke-PiRpcSmoke {
    param([AllowNull()][string] $ServerEntry)

    if ($null -eq $ServerEntry) { [Environment]::SetEnvironmentVariable('PI_MCP_SERVER_ENTRY', $null, 'Process') }
    else { [Environment]::SetEnvironmentVariable('PI_MCP_SERVER_ENTRY', $ServerEntry, 'Process') }

    $piPath = (Get-Command pi -ErrorAction Stop).Source
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $piPath
    $start.WorkingDirectory = $PSScriptRoot
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('--no-extensions', '-e', './extensions/mcp-catalog.ts', '--mode', 'rpc', '--no-session', '--offline')) {
        [void] $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    Assert-True $process.Start() 'Pi RPC process did not start'
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
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
    $response = @($events | Where-Object { $_.type -eq 'response' -and $_.id -eq 'commands' -and $_.command -eq 'get_commands' })
    Assert-True ($response.Count -eq 1 -and $response[0].success) 'correlated get_commands response was absent or unsuccessful'
    $command = @($response[0].data.commands | Where-Object { $_.name -eq 'mcp-catalog' -and $_.source -eq 'extension' })
    Assert-True ($command.Count -eq 1) 'mcp-catalog command was not registered exactly once'
    $expectedPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'extensions/mcp-catalog.ts'))
    Assert-True ([IO.Path]::GetFullPath([string]$command[0].sourceInfo.path) -eq $expectedPath) 'mcp-catalog command came from an unexpected extension path'
    Assert-True (@($events | Where-Object { $_.type -match '^(agent|turn|message|tool_execution)_' }).Count -eq 0) 'RPC command discovery emitted provider/agent events'
}

$requiredCommands = @('node', 'npm', 'pwsh', 'pi')
foreach ($command in $requiredCommands) {
    if ($null -eq (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command '$command' was not found." }
}
Write-Host "node: $(& node --version)"
Write-Host "npm: $(& npm --version)"
Write-Host "pwsh: $(& pwsh --version)"
Write-Host "pi: $(& pi --version)"

$savedEnvironment = @('PI_CODING_AGENT_DIR', 'PI_OFFLINE', 'PI_MCP_SERVER_ENTRY') | ForEach-Object { Save-EnvironmentVariable $_ }
$originalLocation = Get-Location
try {
    Push-Location $PSScriptRoot
    & npm ci
    if ($LASTEXITCODE -ne 0) { throw "npm ci failed with exit $LASTEXITCODE" }
    & npm run verify:mcp
    $mcpExit = $LASTEXITCODE
    Assert-True ($mcpExit -eq 0) "direct MCP verifier exited $mcpExit"

    $env:PI_CODING_AGENT_DIR = $PSScriptRoot
    $env:PI_OFFLINE = '1'
    Invoke-PiRpcSmoke -ServerEntry $null
    Write-Host 'PASS: Pi loaded the adapter and completed an offline RPC lifecycle.'

    $missingServer = Join-Path $PSScriptRoot 'mcp-server/known-missing-server.ts'
    Assert-True (-not (Test-Path -LiteralPath $missingServer)) 'broken-server seam unexpectedly exists'
    Invoke-PiRpcSmoke -ServerEntry $missingServer
    Write-Host 'PASS: Pi remained operational when the MCP child was unavailable.'
}
finally {
    Pop-Location
    foreach ($saved in $savedEnvironment) { Restore-EnvironmentVariable $saved }
}
