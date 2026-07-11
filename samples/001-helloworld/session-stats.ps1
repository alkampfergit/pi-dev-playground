<##
.SYNOPSIS
    Summarize token and cost usage from Pi JSONL session files.

.DESCRIPTION
    Recursively reads Pi session files and writes three Markdown tables:
    totals by session, totals by model, and totals by session/model.
##>

[CmdletBinding()]
param(
    [string] $SessionsDirectory,
    [string] $OutputPath = (Join-Path $PSScriptRoot 'session-stats.md')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture

function Get-Value {
    param([AllowNull()][object] $Object, [Parameter(Mandatory)][string] $Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-LongValue {
    param([AllowNull()][object] $Object, [Parameter(Mandatory)][string] $Name)
    $value = Get-Value $Object $Name
    if ($null -eq $value) { return [long] 0 }
    try { return [long] $value } catch { return [long] 0 }
}

function Get-DecimalValue {
    param([AllowNull()][object] $Object, [Parameter(Mandatory)][string] $Name)
    $value = Get-Value $Object $Name
    if ($null -eq $value) { return [decimal] 0 }
    try { return [decimal] $value } catch { return [decimal] 0 }
}

function Get-Label {
    param([AllowNull()][object] $Value, [Parameter(Mandatory)][string] $Fallback)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string] $Value)) {
        return $Fallback
    }
    return [string] $Value
}

function New-Stats {
    param([string] $Session = '', [string] $File = '', [string] $Provider = '', [string] $Model = '')
    [pscustomobject]@{
        Session = $Session; File = $File; Provider = $Provider; Model = $Model
        Providers = [System.Collections.Generic.HashSet[string]]::new()
        Models = [System.Collections.Generic.HashSet[string]]::new()
        Sessions = [System.Collections.Generic.HashSet[string]]::new()
        Messages = [long] 0; Input = [long] 0; Output = [long] 0
        CacheRead = [long] 0; CacheWrite = [long] 0; TotalTokens = [long] 0
        CostInput = [decimal] 0; CostOutput = [decimal] 0
        CostCacheRead = [decimal] 0; CostCacheWrite = [decimal] 0; CostTotal = [decimal] 0
    }
}

function Add-Stats {
    param([Parameter(Mandatory)][object] $Stats, [Parameter(Mandatory)][object] $Usage)
    $cost = Get-Value $Usage 'cost'
    $Stats.Messages += 1
    $Stats.Input += Get-LongValue $Usage 'input'
    $Stats.Output += Get-LongValue $Usage 'output'
    $Stats.CacheRead += Get-LongValue $Usage 'cacheRead'
    $Stats.CacheWrite += Get-LongValue $Usage 'cacheWrite'
    $Stats.TotalTokens += Get-LongValue $Usage 'totalTokens'
    $Stats.CostInput += Get-DecimalValue $cost 'input'
    $Stats.CostOutput += Get-DecimalValue $cost 'output'
    $Stats.CostCacheRead += Get-DecimalValue $cost 'cacheRead'
    $Stats.CostCacheWrite += Get-DecimalValue $cost 'cacheWrite'
    $Stats.CostTotal += Get-DecimalValue $cost 'total'
}

function Format-Count { param([long] $Value) $Value.ToString('N0', $Invariant) }
function Format-Cost { param([decimal] $Value) $Value.ToString('0.000000', $Invariant) }
function Escape-Cell {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return '' }
    return ([string] $Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}
function Relative-Path {
    param([string] $Base, [string] $Path)
    try { return [IO.Path]::GetRelativePath($Base, $Path) } catch { return $Path }
}
function Add-Header {
    param([System.Collections.Generic.List[string]] $Lines, [string[]] $Columns)
    $Lines.Add("| $($Columns -join ' | ') |")
    $Lines.Add("| $((@($Columns | ForEach-Object { '---' })) -join ' | ') |")
}

if ([string]::IsNullOrWhiteSpace($SessionsDirectory)) {
    $localSessionsDirectory = Join-Path $PSScriptRoot 'sessions'
    if (Test-Path -LiteralPath $localSessionsDirectory -PathType Container) {
        $SessionsDirectory = $localSessionsDirectory
    }
    else {
        $SessionsDirectory = Join-Path $HOME '.pi/agent/sessions'
    }
}

if (-not (Test-Path -LiteralPath $SessionsDirectory -PathType Container)) {
    throw "Sessions directory does not exist: $SessionsDirectory"
}

$root = (Resolve-Path -LiteralPath $SessionsDirectory).Path
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.jsonl' | Sort-Object FullName)
if ($files.Count -eq 0) { throw "No JSONL session files found below: $root" }

$bySession = [ordered]@{}
$byModel = [ordered]@{}
$bySessionModel = [ordered]@{}
$invalidLines = 0
$usageMessages = 0

foreach ($file in $files) {
    $sessionId = $file.BaseName
    $session = New-Stats -Session $sessionId -File (Relative-Path $root $file.FullName)
    $bySession[$sessionId] = $session

    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json -Depth 20 } catch { $invalidLines++; continue }
        if ((Get-Value $record 'type') -ne 'message') { continue }
        $message = Get-Value $record 'message'
        if ((Get-Value $message 'role') -ne 'assistant') { continue }
        $usage = Get-Value $message 'usage'
        if ($null -eq $usage) { continue }

        $usageMessages++
        $provider = Get-Label (Get-Value $message 'provider') '(unknown provider)'
        $model = Get-Label (Get-Value $message 'model') '(unknown model)'
        Add-Stats $session $usage
        [void] $session.Providers.Add($provider)
        [void] $session.Models.Add($model)

        $modelKey = "$provider`n$model"
        if (-not $byModel.Contains($modelKey)) { $byModel[$modelKey] = New-Stats -Provider $provider -Model $model }
        $modelStats = $byModel[$modelKey]
        Add-Stats $modelStats $usage
        [void] $modelStats.Sessions.Add($sessionId)

        $sessionModelKey = "$sessionId`n$provider`n$model"
        if (-not $bySessionModel.Contains($sessionModelKey)) {
            $bySessionModel[$sessionModelKey] = New-Stats -Session $sessionId -Provider $provider -Model $model
        }
        Add-Stats $bySessionModel[$sessionModelKey] $usage
    }
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Pi Session Statistics'); $lines.Add('')
$lines.Add("- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')")
$lines.Add(('- Source: `' + $root + '`'))
$lines.Add("- Session files: $(Format-Count ($files.Count))")
$lines.Add("- Assistant messages with usage: $(Format-Count ($usageMessages))")
if ($invalidLines -gt 0) { $lines.Add("- Invalid JSONL lines skipped: $(Format-Count ($invalidLines))") }
$lines.Add(''); $lines.Add('Only assistant messages containing `message.usage` are included.'); $lines.Add('')

$lines.Add('## Totals by session'); $lines.Add('')
Add-Header $lines @('Session', 'File', 'Assistant messages', 'Providers', 'Models', 'Input', 'Output', 'Cache read', 'Cache write', 'Total tokens', 'Cost input', 'Cost output', 'Cost cache read', 'Cost cache write', 'Cost total')
foreach ($s in @($bySession.Values | Sort-Object Session)) {
    $providers = ($s.Providers | Sort-Object) -join ', '; $models = ($s.Models | Sort-Object) -join ', '
    $lines.Add("| $(Escape-Cell $s.Session) | $(Escape-Cell $s.File) | $(Format-Count ($s.Messages)) | $(Escape-Cell $providers) | $(Escape-Cell $models) | $(Format-Count ($s.Input)) | $(Format-Count ($s.Output)) | $(Format-Count ($s.CacheRead)) | $(Format-Count ($s.CacheWrite)) | $(Format-Count ($s.TotalTokens)) | $(Format-Cost ($s.CostInput)) | $(Format-Cost ($s.CostOutput)) | $(Format-Cost ($s.CostCacheRead)) | $(Format-Cost ($s.CostCacheWrite)) | $(Format-Cost ($s.CostTotal)) |")
}
$lines.Add(''); $lines.Add('## Totals by model'); $lines.Add('')
Add-Header $lines @('Provider', 'Model', 'Sessions', 'Assistant messages', 'Input', 'Output', 'Cache read', 'Cache write', 'Total tokens', 'Cost input', 'Cost output', 'Cost cache read', 'Cost cache write', 'Cost total')
foreach ($s in @($byModel.Values | Sort-Object Provider, Model)) {
    $lines.Add("| $(Escape-Cell $s.Provider) | $(Escape-Cell $s.Model) | $(Format-Count ($s.Sessions.Count)) | $(Format-Count ($s.Messages)) | $(Format-Count ($s.Input)) | $(Format-Count ($s.Output)) | $(Format-Count ($s.CacheRead)) | $(Format-Count ($s.CacheWrite)) | $(Format-Count ($s.TotalTokens)) | $(Format-Cost ($s.CostInput)) | $(Format-Cost ($s.CostOutput)) | $(Format-Cost ($s.CostCacheRead)) | $(Format-Cost ($s.CostCacheWrite)) | $(Format-Cost ($s.CostTotal)) |")
}
$lines.Add(''); $lines.Add('## Totals by session and model'); $lines.Add('')
Add-Header $lines @('Session', 'Provider', 'Model', 'Assistant messages', 'Input', 'Output', 'Cache read', 'Cache write', 'Total tokens', 'Cost input', 'Cost output', 'Cost cache read', 'Cost cache write', 'Cost total')
foreach ($s in @($bySessionModel.Values | Sort-Object Session, Provider, Model)) {
    $lines.Add("| $(Escape-Cell $s.Session) | $(Escape-Cell $s.Provider) | $(Escape-Cell $s.Model) | $(Format-Count ($s.Messages)) | $(Format-Count ($s.Input)) | $(Format-Count ($s.Output)) | $(Format-Count ($s.CacheRead)) | $(Format-Count ($s.CacheWrite)) | $(Format-Count ($s.TotalTokens)) | $(Format-Cost ($s.CostInput)) | $(Format-Cost ($s.CostOutput)) | $(Format-Cost ($s.CostCacheRead)) | $(Format-Cost ($s.CostCacheWrite)) | $(Format-Cost ($s.CostTotal)) |")
}

$output = [IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Path $output -Parent
if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
$lines -join [Environment]::NewLine | Set-Content -LiteralPath $output -Encoding utf8
Write-Host "Wrote session statistics to $output"
