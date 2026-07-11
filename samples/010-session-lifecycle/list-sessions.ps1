<#
.SYNOPSIS
    List privacy-preserving metadata for this sample's Pi sessions.

.DESCRIPTION
    Recursively reads version-3 Pi JSONL session files whose header cwd is
    this sample directory. Conversation content is never included in output.
#>

[CmdletBinding()]
param(
    [string] $SessionsDirectory = (Join-Path $PSScriptRoot 'sessions/lifecycle-lab'),

    [ValidateSet('Table', 'Json')]
    [string] $Format = 'Table'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
    param(
        [AllowNull()][object] $Object,
        [Parameter(Mandatory)][string] $Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)][string] $BasePath,
        [Parameter(Mandatory)][string] $Path
    )

    return [IO.Path]::GetRelativePath($BasePath, $Path)
}

function Get-ParentIdFromPath {
    param([AllowNull()][object] $ParentSession)

    if ([string]::IsNullOrWhiteSpace([string] $ParentSession)) { return '' }
    $filename = [IO.Path]::GetFileNameWithoutExtension([string] $ParentSession)
    $uuidPattern = '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})'
    $match = [regex]::Match($filename, $uuidPattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

$columns = @(
    'Name', 'Id', 'CreatedUtc', 'ModifiedUtc', 'Entries', 'Messages',
    'UserTurns', 'AssistantTurns', 'ToolResultTurns', 'IsFork', 'ParentId',
    'RelativeFile'
)
$results = [System.Collections.Generic.List[object]]::new()

if (Test-Path -LiteralPath $SessionsDirectory -PathType Container) {
    $root = (Resolve-Path -LiteralPath $SessionsDirectory).Path
    $sampleRoot = [IO.Path]::GetFullPath($PSScriptRoot)
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.jsonl' | Sort-Object FullName)

    foreach ($file in $files) {
        $relativeFile = Get-RelativePath -BasePath $root -Path $file.FullName
        try {
            $records = [System.Collections.Generic.List[object]]::new()
            foreach ($line in Get-Content -LiteralPath $file.FullName) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $records.Add(($line | ConvertFrom-Json -Depth 30))
                }
                catch {
                    throw 'contains invalid JSON'
                }
            }

            if ($records.Count -eq 0) { throw 'is empty' }
            $header = $records[0]
            if ((Get-PropertyValue $header 'type') -ne 'session' -or
                [int](Get-PropertyValue $header 'version') -lt 1 -or
                [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $header 'id')) -or
                [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $header 'timestamp')) -or
                [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $header 'cwd'))) {
                throw 'does not have a valid versioned session header'
            }

            $headerCwd = [IO.Path]::GetFullPath([string](Get-PropertyValue $header 'cwd'))
            if (-not [string]::Equals($headerCwd, $sampleRoot, [StringComparison]::Ordinal)) {
                continue
            }

            try {
                $created = [DateTimeOffset]::Parse(
                    [string](Get-PropertyValue $header 'timestamp'),
                    [Globalization.CultureInfo]::InvariantCulture
                ).UtcDateTime
            }
            catch {
                throw 'has an invalid header timestamp'
            }

            $name = ''
            $messages = 0
            $userTurns = 0
            $assistantTurns = 0
            $toolResultTurns = 0
            foreach ($record in $records) {
                $type = [string](Get-PropertyValue $record 'type')
                if ($type -eq 'session_info') {
                    $candidateName = Get-PropertyValue $record 'name'
                    if ($null -ne $candidateName) { $name = [string] $candidateName }
                }
                if ($type -ne 'message') { continue }

                $messages++
                $role = [string](Get-PropertyValue (Get-PropertyValue $record 'message') 'role')
                switch ($role) {
                    'user' { $userTurns++ }
                    'assistant' { $assistantTurns++ }
                    'toolResult' { $toolResultTurns++ }
                }
            }

            $parentSession = Get-PropertyValue $header 'parentSession'
            $hasParent = -not [string]::IsNullOrWhiteSpace([string] $parentSession)
            $results.Add([pscustomobject][ordered]@{
                Name = $name
                Id = [string](Get-PropertyValue $header 'id')
                CreatedUtc = $created.ToString('o')
                ModifiedUtc = $file.LastWriteTimeUtc.ToString('o')
                Entries = $records.Count
                Messages = $messages
                UserTurns = $userTurns
                AssistantTurns = $assistantTurns
                ToolResultTurns = $toolResultTurns
                IsFork = $hasParent
                ParentId = Get-ParentIdFromPath $parentSession
                RelativeFile = $relativeFile
            })
        }
        catch {
            $safeReasons = @(
                'contains invalid JSON',
                'is empty',
                'does not have a valid versioned session header',
                'has an invalid header timestamp'
            )
            $reason = if ($safeReasons -contains $_.Exception.Message) {
                $_.Exception.Message
            }
            else {
                'could not be read safely'
            }
            Write-Warning "Skipping '$relativeFile': $reason."
        }
    }
}

$ordered = @($results | Sort-Object @{ Expression = 'ModifiedUtc'; Descending = $true }, Id)
if ($Format -eq 'Json') {
    Write-Output (ConvertTo-Json -InputObject $ordered -Depth 5)
    return
}

if ($ordered.Count -eq 0) {
    Write-Host 'No sessions found for this sample.'
    return
}

$ordered | Select-Object $columns | Format-Table -AutoSize
