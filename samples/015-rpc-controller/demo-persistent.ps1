<#
.SYNOPSIS
    Optionally combine live RPC work with a unique persistent session.

The temporary session directory is removed unless -KeepSession is supplied.
This is a small bridge to session commands; tree and compaction remain owned by
the neighboring lessons.
#>

[CmdletBinding()]
param(
    [int] $TimeoutSeconds = 120,
    [switch] $KeepSession
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw "Persistent demo assertion failed: $Message" }
}

function Send-Request {
    param([Parameter(Mandatory)][object] $Client, [Parameter(Mandatory)][hashtable] $Request)
    return Send-PiRpcRequest -Client $Client -Request $Request
}

function Wait-Success {
    param([Parameter(Mandatory)][object] $Client, [Parameter(Mandatory)][string] $Id, [Parameter(Mandatory)][string] $Command, [int] $Seconds)
    $response = Wait-PiRpcResponse -Client $Client -Id $Id -TimeoutSeconds $Seconds
    Assert-True ([string]$response.command -eq $Command -and $response.success -eq $true) "RPC command '$Command' failed."
    return $response
}

foreach ($name in @('AZURE_PI_TEST_DEPLOYMENT', 'AZURE_PI_TEST_API_KEY')) {
    Assert-True (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) "Missing '$name'. Source ./prepare.ps1 first."
}
Assert-True ([IO.Path]::GetFullPath($env:PI_CODING_AGENT_DIR) -ceq [IO.Path]::GetFullPath($PSScriptRoot)) 'Source ./prepare.ps1 from this sample first.'
Import-Module (Join-Path $PSScriptRoot 'PiRpc.psm1') -Force

$sessionDirectory = Join-Path ([IO.Path]::GetTempPath()) ('pi-sample-015-session-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $sessionDirectory -ItemType Directory -Force | Out-Null
$name = 'rpc-015-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$model = "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
$arguments = @('--mode', 'rpc', '--session-dir', $sessionDirectory, '--name', $name, '--model', $model, '--offline', '--no-approve', '--no-tools', '--no-extensions', '--no-skills', '--no-prompt-templates')
$client = $null
try {
    $client = Start-PiRpc -ExecutablePath (Get-Command pi -ErrorAction Stop).Source -ArgumentList $arguments -WorkingDirectory $PSScriptRoot
    $promptId = Send-Request $client @{ type = 'prompt'; message = 'Reply with the stable marker RPC015-PERSISTENT-MARKER and one short sentence. Do not use tools.' }
    [void](Wait-Success $client $promptId 'prompt' 30)
    do {
        $event = Wait-PiRpcEvent -Client $client -TimeoutSeconds $TimeoutSeconds
    } while ([string]$event.type -ne 'agent_settled')

    $renameId = Send-Request $client @{ type = 'set_session_name'; name = $name }
    [void](Wait-Success $client $renameId 'set_session_name' 15)
    $entriesId = Send-Request $client @{ type = 'get_entries' }
    $treeId = Send-Request $client @{ type = 'get_tree' }
    $statsId = Send-Request $client @{ type = 'get_session_stats' }
    $entries = Wait-Success $client $entriesId 'get_entries' 15
    $tree = Wait-Success $client $treeId 'get_tree' 15
    $stats = Wait-Success $client $statsId 'get_session_stats' 15
    Assert-True (@($entries.data.entries).Count -gt 0) 'get_entries returned no live session entries.'
    Assert-True ($null -ne $tree.data.tree -and $null -ne $stats.data) 'tree or stats response was structurally empty.'
    Write-Host "Persistent session '$name': entries=$(@($entries.data.entries).Count), treeNodes=$(@($tree.data.tree).Count)."

    $cloneId = Send-Request $client @{ type = 'clone' }
    $clone = Wait-Success $client $cloneId 'clone' 30
    Assert-True ($clone.data.cancelled -eq $false) 'clone was cancelled unexpectedly.'
    Write-Host 'PASS: persistent RPC session name, entries, tree, stats, and clone were observed after live work.'
} finally {
    if ($null -ne $client) { Stop-PiRpc -Client $client -TimeoutSeconds 5 }
    if (-not $KeepSession -and (Test-Path -LiteralPath $sessionDirectory)) {
        Remove-Item -LiteralPath $sessionDirectory -Recurse -Force
    } else {
        Write-Host "Kept session directory: $sessionDirectory"
    }
}
