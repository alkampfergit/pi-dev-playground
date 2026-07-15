[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string] $SessionFile,

    [Parameter(Mandatory, ParameterSetName = 'Directory')]
    [string] $SessionsDirectory,

    [ValidateSet('Table', 'Json')]
    [string] $Format = 'Table'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail-Safe {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Reason)
    $name = [IO.Path]::GetFileName($Path)
    throw "Inspector failed for ${name}: $Reason"
}

function Short-Id {
    param([AllowNull()][object] $Id)
    if ($null -eq $Id -or [string]::IsNullOrEmpty([string] $Id) -or [string]$Id -eq 'root') { return '' }
    return ([string]$Id).Substring(0, 6).ToLowerInvariant()
}

function Timestamp-Text {
    param([Parameter(Mandatory)][object] $Value, [Parameter(Mandatory)][string] $Path)
    try { return ([DateTimeOffset]::Parse([string]$Value)).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    catch { Fail-Safe $Path 'invalid entry timestamp' }
}

function Require-Property {
    param([Parameter(Mandatory)][object] $Object, [Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Path)
    if (-not ($Object.PSObject.Properties.Name -contains $Name)) { Fail-Safe $Path 'missing required field' }
}

function Read-Projection {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail-Safe $Path 'file not found' }
    try { $rawLines = @(Get-Content -LiteralPath $Path -ErrorAction Stop) }
    catch { Fail-Safe $Path 'file could not be read' }
    $objects = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $rawLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $objects.Add(($line | ConvertFrom-Json -Depth 100 -ErrorAction Stop)) }
        catch { Fail-Safe $Path 'malformed JSON' }
    }
    if ($objects.Count -lt 1) { Fail-Safe $Path 'missing session header' }

    $header = $objects[0]
    Require-Property $header 'type' $Path
    Require-Property $header 'version' $Path
    Require-Property $header 'id' $Path
    Require-Property $header 'timestamp' $Path
    if ([string]$header.type -ne 'session' -or [int]$header.version -ne 3) { Fail-Safe $Path 'unsupported session header' }
    $headerGuid = [guid]::Empty
    if (-not [guid]::TryParse([string]$header.id, [ref]$headerGuid)) { Fail-Safe $Path 'invalid session header' }
    try { [DateTimeOffset]::Parse([string]$header.timestamp) | Out-Null } catch { Fail-Safe $Path 'invalid session header' }

    $entries = [System.Collections.Generic.List[object]]::new()
    for ($i = 1; $i -lt $objects.Count; $i++) { $entries.Add($objects[$i]) }
    $byId = @{}
    $prefixOwners = @{}
    $roots = 0
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $entry = $entries[$i]
        foreach ($field in @('type', 'id', 'parentId', 'timestamp')) { Require-Property $entry $field $Path }
        $id = [string]$entry.id
        if ($id -notmatch '^[0-9a-fA-F]{8}$') { Fail-Safe $Path 'invalid entry id' }
        if ($byId.ContainsKey($id)) { Fail-Safe $Path 'duplicate entry id' }
        $prefix = $id.Substring(0, 6).ToLowerInvariant()
        if ($prefixOwners.ContainsKey($prefix) -and $prefixOwners[$prefix] -ne $id) { Fail-Safe $Path 'short-id collision' }
        $prefixOwners[$prefix] = $id
        try { [DateTimeOffset]::Parse([string]$entry.timestamp) | Out-Null } catch { Fail-Safe $Path 'invalid entry timestamp' }
        $parent = $entry.parentId
        if ($null -eq $parent -or [string]::IsNullOrEmpty([string]$parent)) {
            $roots++
        } elseif (-not $byId.ContainsKey([string]$parent)) {
            Fail-Safe $Path 'unknown parent id'
        }
        $byId[$id] = $entry
    }
    if ($entries.Count -gt 0 -and $roots -ne 1) { Fail-Safe $Path 'invalid root count' }

    $children = @{}
    foreach ($entry in $entries) { $children[[string]$entry.id] = 0 }
    foreach ($entry in $entries) {
        if ($null -ne $entry.parentId -and -not [string]::IsNullOrEmpty([string]$entry.parentId)) { $children[[string]$entry.parentId]++ }
    }
    $activeLeaf = if ($entries.Count -gt 0) { [string]$entries[$entries.Count - 1].id } else { '' }
    $activeIds = @{}
    $cursor = $activeLeaf
    while (-not [string]::IsNullOrEmpty($cursor)) {
        if (-not $byId.ContainsKey($cursor)) { Fail-Safe $Path 'broken active path' }
        if ($activeIds.ContainsKey($cursor)) { Fail-Safe $Path 'cyclic parent chain' }
        $activeIds[$cursor] = $true
        $parent = $byId[$cursor].parentId
        $cursor = if ($null -eq $parent) { '' } else { [string]$parent }
    }

    $branchSummaries = @()
    $compactions = @()
    foreach ($entry in $entries) {
        $type = [string]$entry.type
        if ($type -eq 'branch_summary') {
            Require-Property $entry 'fromId' $Path
            $fromId = [string]$entry.fromId
            if ($fromId -ne 'root' -and -not $byId.ContainsKey($fromId)) { Fail-Safe $Path 'unknown branch-summary source' }
            $branchSummaries += [pscustomobject]@{
                IdPrefix = Short-Id $entry.id
                ParentIdPrefix = Short-Id $entry.parentId
                FromIdPrefix = Short-Id $fromId
                FromExtension = ($entry.PSObject.Properties.Name -contains 'fromHook' -and $entry.fromHook -eq $true)
            }
        } elseif ($type -eq 'compaction') {
            foreach ($field in @('firstKeptEntryId', 'tokensBefore')) { Require-Property $entry $field $Path }
            $kept = [string]$entry.firstKeptEntryId
            if (-not $byId.ContainsKey($kept)) { Fail-Safe $Path 'unknown compaction boundary' }
            $tokens = 0L
            try { $tokens = [int64]$entry.tokensBefore } catch { Fail-Safe $Path 'invalid compaction metadata' }
            $compactions += [pscustomobject]@{
                IdPrefix = Short-Id $entry.id
                ParentIdPrefix = Short-Id $entry.parentId
                FirstKeptEntryIdPrefix = Short-Id $kept
                TokensBefore = $tokens
                FromExtension = ($entry.PSObject.Properties.Name -contains 'fromHook' -and $entry.fromHook -eq $true)
            }
        }
    }

    $entryProjection = @()
    foreach ($i in 0..($entries.Count - 1)) {
        if ($entries.Count -eq 0) { break }
        $entry = $entries[$i]
        $entryProjection += [pscustomobject]@{
            Sequence = $i
            IdPrefix = Short-Id $entry.id
            ParentIdPrefix = Short-Id $entry.parentId
            Timestamp = Timestamp-Text $entry.timestamp $Path
            Type = [string]$entry.type
            ChildCount = [int]$children[[string]$entry.id]
            OnActivePath = $activeIds.ContainsKey([string]$entry.id)
        }
    }
    $parentSessionId = ''
    if ($header.PSObject.Properties.Name -contains 'parentSession' -and -not [string]::IsNullOrWhiteSpace([string]$header.parentSession)) {
        $parentName = [IO.Path]::GetFileName([string]$header.parentSession)
        $guidMatch = [regex]::Match($parentName, '(?<id>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
        if ($guidMatch.Success) { $parentSessionId = $guidMatch.Groups['id'].Value }
    }
    $session = [pscustomobject]@{
        Id = [string]$header.id
        ParentSessionId = $parentSessionId
        Version = [int]$header.version
        EntryCount = $entries.Count
        RootCount = $roots
        LeafCount = @($children.Values | Where-Object { $_ -eq 0 }).Count
        BranchPointCount = @($children.Values | Where-Object { $_ -gt 1 }).Count
        ActiveLeafIdPrefix = Short-Id $activeLeaf
        ActivePathIdPrefixes = @($entries | Where-Object { $activeIds.ContainsKey([string]$_.id) } | ForEach-Object { Short-Id $_.id })
    }
    return [pscustomobject]@{
        SchemaVersion = 1
        Session = $session
        Entries = @($entryProjection)
        BranchSummaries = @($branchSummaries)
        Compactions = @($compactions)
    }
}

function Write-Table {
    param([Parameter(Mandatory)][object] $Projection)
    $s = $Projection.Session
    Write-Output 'SchemaVersion: 1'
    Write-Output ("Session: id={0} parent={1} version={2} entries={3} roots={4} leaves={5} branchPoints={6} activeLeaf={7}" -f $s.Id, $s.ParentSessionId, $s.Version, $s.EntryCount, $s.RootCount, $s.LeafCount, $s.BranchPointCount, $s.ActiveLeafIdPrefix)
    Write-Output 'Sequence Id     Parent  Type              Children Active'
    foreach ($entry in @($Projection.Entries)) {
        Write-Output ("{0,8} {1,-6} {2,-7} {3,-17} {4,8} {5}" -f $entry.Sequence, $entry.IdPrefix, $entry.ParentIdPrefix, $entry.Type, $entry.ChildCount, $entry.OnActivePath)
    }
    Write-Output ("BranchSummaries={0} Compactions={1}" -f @($Projection.BranchSummaries).Count, @($Projection.Compactions).Count)
}

try {
    $paths = @()
    $directoryInput = $PSCmdlet.ParameterSetName -eq 'Directory'
    if ($directoryInput) {
        if (-not (Test-Path -LiteralPath $SessionsDirectory -PathType Container)) { Fail-Safe $SessionsDirectory 'directory not found' }
        $paths = @(Get-ChildItem -LiteralPath $SessionsDirectory -Filter '*.jsonl' -File -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName })
        if ($paths.Count -eq 0) { Fail-Safe $SessionsDirectory 'no session files found' }
    } else { $paths = @($SessionFile) }
    $projections = @($paths | ForEach-Object { Read-Projection $_ })
    if ($Format -eq 'Json') {
        if ($directoryInput) { $projections | ConvertTo-Json -Depth 20 -Compress }
        else { $projections[0] | ConvertTo-Json -Depth 20 -Compress }
    } else {
        foreach ($projection in $projections) { Write-Table $projection }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
