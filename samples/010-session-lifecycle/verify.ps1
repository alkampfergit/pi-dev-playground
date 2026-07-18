<#
.SYNOPSIS
    Verify Pi's persisted, continued, reopened, forked, and ephemeral sessions.

.DESCRIPTION
    Makes real model calls in a unique sessions/verification child directory,
    validates the JSONL independently, checks the metadata helper, and removes
    only that unique directory in a finally block.
#>

[CmdletBinding()]
param()

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

function Assert-True {
    param(
        [bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )

    if (-not $Condition) { throw $Message }
}

function Get-SessionFiles {
    param([Parameter(Mandatory)][string] $Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Filter '*.jsonl' | Sort-Object FullName)
}

function Read-ValidatedSession {
    param(
        [Parameter(Mandatory)][IO.FileInfo] $File,
        [AllowEmptyString()][string] $ExpectedId = ''
    )

    $rawLines = @(
        Get-Content -LiteralPath $File.FullName |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    Assert-True ($rawLines.Count -gt 0) "Session file is empty."

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $rawLines) {
        try { $entries.Add(($line | ConvertFrom-Json -Depth 100)) }
        catch { throw 'Session file contains invalid JSON.' }
    }

    $header = $entries[0]
    Assert-True ((Get-PropertyValue $header 'type') -eq 'session') 'First record is not a session header.'
    Assert-True ([int](Get-PropertyValue $header 'version') -eq 3) 'Session header version is not 3.'
    $headerId = [string](Get-PropertyValue $header 'id')
    Assert-True (-not [string]::IsNullOrWhiteSpace($headerId)) 'Session header has no ID.'
    if (-not [string]::IsNullOrWhiteSpace($ExpectedId)) {
        Assert-True ($headerId -eq $ExpectedId) 'Session header ID does not match the expected ID.'
    }
    $headerCwd = [IO.Path]::GetFullPath([string](Get-PropertyValue $header 'cwd'))
    Assert-True ($headerCwd -eq [IO.Path]::GetFullPath($PSScriptRoot)) 'Session cwd is not the sample directory.'
    $headerTimestamp = [string](Get-PropertyValue $header 'timestamp')
    Assert-True (-not [string]::IsNullOrWhiteSpace($headerTimestamp)) 'Session header has no timestamp.'
    try { [void][DateTimeOffset]::Parse($headerTimestamp) }
    catch { throw 'Session header timestamp is invalid.' }

    $knownIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $rootEntries = 0
    for ($index = 1; $index -lt $entries.Count; $index++) {
        $entry = $entries[$index]
        $idProperty = $entry.PSObject.Properties['id']
        $parentProperty = $entry.PSObject.Properties['parentId']
        $timestampProperty = $entry.PSObject.Properties['timestamp']
        Assert-True ($null -ne $idProperty -and -not [string]::IsNullOrWhiteSpace([string] $idProperty.Value)) 'An entry has no ID.'
        Assert-True ($null -ne $parentProperty) 'An entry has no parentId property.'
        Assert-True ($null -ne $timestampProperty -and -not [string]::IsNullOrWhiteSpace([string] $timestampProperty.Value)) 'An entry has no timestamp.'
        try { [void][DateTimeOffset]::Parse([string] $timestampProperty.Value) }
        catch { throw 'An entry timestamp is invalid.' }

        $entryId = [string] $idProperty.Value
        Assert-True ($knownIds.Add($entryId)) 'An entry ID is duplicated.'
        $parentId = [string] $parentProperty.Value
        if ([string]::IsNullOrWhiteSpace($parentId)) {
            $rootEntries++
        }
        else {
            Assert-True ($knownIds.Contains($parentId)) 'An entry references an unknown or later parent.'
        }
    }
    Assert-True ($rootEntries -le 1) 'The append tree contains more than one root entry.'

    return [pscustomobject]@{
        File = $File
        Header = $header
        Entries = $entries
        RawLines = $rawLines
        RawText = ($rawLines -join "`n")
    }
}

function Get-LatestName {
    param([Parameter(Mandatory)][object] $Session)

    $name = ''
    foreach ($entry in $Session.Entries) {
        if ((Get-PropertyValue $entry 'type') -eq 'session_info') {
            $candidate = Get-PropertyValue $entry 'name'
            if ($null -ne $candidate) { $name = [string] $candidate }
        }
    }
    return $name
}

function Get-MessageCount {
    param([Parameter(Mandatory)][object] $Session)
    return @($Session.Entries | Where-Object { (Get-PropertyValue $_ 'type') -eq 'message' }).Count
}

function Assert-SuccessfulAssistantMarker {
    param(
        [Parameter(Mandatory)][object] $Session,
        [Parameter(Mandatory)][string] $Marker
    )

    $found = $false
    foreach ($entry in $Session.Entries) {
        if ((Get-PropertyValue $entry 'type') -ne 'message') { continue }
        $message = Get-PropertyValue $entry 'message'
        if ((Get-PropertyValue $message 'role') -ne 'assistant') { continue }
        $stopReason = [string](Get-PropertyValue $message 'stopReason')
        Assert-True ($stopReason -ne 'error' -and $stopReason -ne 'aborted') 'An assistant turn ended with an error or abort.'
        $serialized = $entry | ConvertTo-Json -Compress -Depth 100
        if ($serialized.Contains($Marker, [StringComparison]::Ordinal)) { $found = $true }
    }
    Assert-True $found "No successful assistant turn contains the expected marker."
}

function Assert-UserMarker {
    param(
        [Parameter(Mandatory)][object] $Session,
        [Parameter(Mandatory)][string] $Marker
    )

    $found = $false
    foreach ($entry in $Session.Entries) {
        if ((Get-PropertyValue $entry 'type') -ne 'message') { continue }
        $message = Get-PropertyValue $entry 'message'
        if ((Get-PropertyValue $message 'role') -ne 'user') { continue }
        if (($entry | ConvertTo-Json -Compress -Depth 100).Contains($Marker, [StringComparison]::Ordinal)) {
            $found = $true
        }
    }
    Assert-True $found 'The expected user turn is absent.'
}

function Get-FileSnapshot {
    param([Parameter(Mandatory)][string] $Directory)

    $snapshot = [ordered]@{}
    foreach ($file in Get-SessionFiles $Directory) {
        $relative = [IO.Path]::GetRelativePath($Directory, $file.FullName)
        $snapshot[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $snapshot
}

function Assert-SnapshotsEqual {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Before,
        [Parameter(Mandatory)][Collections.IDictionary] $After,
        [Parameter(Mandatory)][string] $Message
    )

    Assert-True ($Before.Count -eq $After.Count) $Message
    foreach ($key in $Before.Keys) {
        Assert-True ($After.Contains($key) -and $After[$key] -eq $Before[$key]) $Message
    }
}

function Invoke-PiTurn {
    param(
        [Parameter(Mandatory)][string] $Phase,
        [Parameter(Mandatory)][string] $SessionId,
        [Parameter(Mandatory)][string[]] $SessionArguments,
        [Parameter(Mandatory)][string] $Prompt,
        [Parameter(Mandatory)][string] $ExpectedOutputMarker
    )

    $arguments = @(
        '--session-dir', $script:VerificationDirectory,
        '--model', $script:Model,
        '--no-tools', '--no-extensions', '--no-skills',
        '--no-prompt-templates', '--no-context-files'
    ) + $SessionArguments + @('-p', $Prompt)

    $output = (& pi @arguments 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Pi failed during '$Phase' for session '$SessionId' (exit $LASTEXITCODE)."
    }
    Assert-True ($output.Contains($ExpectedOutputMarker, [StringComparison]::Ordinal)) "Pi output missed the expected marker during '$Phase' for session '$SessionId'."
}

$requiredEnvironment = @('AZURE_PI_TEST_DEPLOYMENT', 'AZURE_PI_TEST_API_KEY', 'PI_CODING_AGENT_DIR')
if ($null -eq (Get-Command pi -ErrorAction SilentlyContinue)) { throw "Required command 'pi' was not found." }
if ($null -eq (Get-Command bash -ErrorAction SilentlyContinue)) { throw "Required command 'bash' was not found." }
foreach ($name in $requiredEnvironment) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Required environment variable '$name' is missing. Source ./prepare.ps1 first."
    }
}

$configuredDirectory = [IO.Path]::GetFullPath($env:PI_CODING_AGENT_DIR)
$sampleDirectory = [IO.Path]::GetFullPath($PSScriptRoot)
Assert-True ($configuredDirectory -eq $sampleDirectory) 'PI_CODING_AGENT_DIR must resolve to this sample directory.'

$script:Model = "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT"
$verificationRoot = Join-Path $PSScriptRoot 'sessions/verification'
$script:VerificationDirectory = Join-Path $verificationRoot ([guid]::NewGuid().ToString())
$originalId = [guid]::NewGuid().ToString()
$forkId = [guid]::NewGuid().ToString()
$apiKey = $env:AZURE_PI_TEST_API_KEY

New-Item -Path $script:VerificationDirectory -ItemType Directory -Force | Out-Null
try {
    Invoke-PiTurn -Phase 'named start' -SessionId $originalId `
        -SessionArguments @('--session-id', $originalId, '--name', 'lifecycle-original') `
        -Prompt 'Remember this fictional release-checklist codeword: ORBIT-41. Reply exactly: BASE: ORBIT-41' `
        -ExpectedOutputMarker 'BASE: ORBIT-41'

    $files = @(Get-SessionFiles $script:VerificationDirectory)
    Assert-True ($files.Count -eq 1) 'Named start did not create exactly one session file.'
    $originalPath = $files[0].FullName
    $original = Read-ValidatedSession -File $files[0] -ExpectedId $originalId
    Assert-True ((Get-LatestName $original) -eq 'lifecycle-original') 'Original session name is incorrect.'
    Assert-UserMarker $original 'ORBIT-41'
    Assert-SuccessfulAssistantMarker $original 'ORBIT-41'
    Assert-True (-not $original.RawText.Contains($apiKey, [StringComparison]::Ordinal)) 'API key found in original session text.'

    $entryCountBeforeContinue = $original.Entries.Count
    $messageCountBeforeContinue = Get-MessageCount $original
    Invoke-PiTurn -Phase 'continue' -SessionId $originalId `
        -SessionArguments @('-c') `
        -Prompt 'What fictional codeword did I ask you to remember? Reply exactly: CONTINUED: <codeword>' `
        -ExpectedOutputMarker 'CONTINUED: ORBIT-41'

    $files = @(Get-SessionFiles $script:VerificationDirectory)
    Assert-True ($files.Count -eq 1 -and $files[0].FullName -eq $originalPath) 'Continue created or selected a different file.'
    $original = Read-ValidatedSession -File $files[0] -ExpectedId $originalId
    Assert-True ($original.Entries.Count -gt $entryCountBeforeContinue) 'Continue did not increase the entry count.'
    Assert-True ((Get-MessageCount $original) -gt $messageCountBeforeContinue) 'Continue did not increase the message count.'
    Assert-SuccessfulAssistantMarker $original 'CONTINUED: ORBIT-41'

    $entryCountBeforeReopen = $original.Entries.Count
    Invoke-PiTurn -Phase 'exact reopen' -SessionId $originalId `
        -SessionArguments @('--session', $originalId) `
        -Prompt 'Reply exactly: REOPENED: ORBIT-41' `
        -ExpectedOutputMarker 'REOPENED: ORBIT-41'

    $files = @(Get-SessionFiles $script:VerificationDirectory)
    Assert-True ($files.Count -eq 1 -and $files[0].FullName -eq $originalPath) 'Exact reopen created or selected a different file.'
    $original = Read-ValidatedSession -File $files[0] -ExpectedId $originalId
    Assert-True ($original.Entries.Count -gt $entryCountBeforeReopen) 'Exact reopen did not increase the entry count.'
    Assert-SuccessfulAssistantMarker $original 'REOPENED: ORBIT-41'
    Assert-True (-not $original.RawText.Contains($apiKey, [StringComparison]::Ordinal)) 'API key found in reopened session text.'

    $sourceLinesBeforeFork = @($original.RawLines | Select-Object -Skip 1)
    $originalHashBeforeFork = (Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash
    Invoke-PiTurn -Phase 'fork' -SessionId $forkId `
        -SessionArguments @('--fork', $originalId, '--session-id', $forkId, '--name', 'lifecycle-alternative') `
        -Prompt 'For this alternative plan only, replace the fictional codeword with COMET-73. Reply exactly: FORK: COMET-73' `
        -ExpectedOutputMarker 'FORK: COMET-73'

    Assert-True (((Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash) -eq $originalHashBeforeFork) 'Fork modified the original file.'
    $files = @(Get-SessionFiles $script:VerificationDirectory)
    Assert-True ($files.Count -eq 2) 'Fork did not produce exactly two session files.'
    $forkFile = $files | Where-Object { $_.FullName -ne $originalPath }
    Assert-True ($null -ne $forkFile -and @($forkFile).Count -eq 1) 'Could not identify the fork file.'
    $fork = Read-ValidatedSession -File $forkFile -ExpectedId $forkId
    Assert-True ((Get-LatestName $fork) -eq 'lifecycle-alternative') 'Fork session name is incorrect.'
    Assert-True ([IO.Path]::GetFullPath([string](Get-PropertyValue $fork.Header 'parentSession')) -eq [IO.Path]::GetFullPath($originalPath)) 'Fork parentSession does not resolve to the original file.'
    Assert-True ($forkId -ne $originalId) 'Fork reused the original session ID.'
    Assert-True ($fork.RawLines.Count -gt ($sourceLinesBeforeFork.Count + 1)) 'Fork has no entries after copied history.'
    for ($index = 0; $index -lt $sourceLinesBeforeFork.Count; $index++) {
        Assert-True ($fork.RawLines[$index + 1] -eq $sourceLinesBeforeFork[$index]) 'Fork copied-history prefix differs from the source history.'
    }
    Assert-SuccessfulAssistantMarker $fork 'COMET-73'
    Assert-True (-not $fork.RawText.Contains($apiKey, [StringComparison]::Ordinal)) 'API key found in fork session text.'
    $originalAfterFork = Read-ValidatedSession -File (Get-Item -LiteralPath $originalPath) -ExpectedId $originalId
    Assert-True (-not $originalAfterFork.RawText.Contains('COMET-73', [StringComparison]::Ordinal)) 'Fork-only marker appeared in the original session.'

    $snapshotBeforeEphemeral = Get-FileSnapshot $script:VerificationDirectory
    Invoke-PiTurn -Phase 'ephemeral' -SessionId '(ephemeral)' `
        -SessionArguments @('--no-session') `
        -Prompt 'Reply exactly: EPHEMERAL' `
        -ExpectedOutputMarker 'EPHEMERAL'
    $snapshotAfterEphemeral = Get-FileSnapshot $script:VerificationDirectory
    Assert-SnapshotsEqual $snapshotBeforeEphemeral $snapshotAfterEphemeral 'Ephemeral run changed the persisted file set or a session hash.'

    $jsonOutput = (& pwsh (Join-Path $PSScriptRoot 'list-sessions.ps1') -SessionsDirectory $script:VerificationDirectory -Format Json 2>&1 | Out-String)
    Assert-True ($LASTEXITCODE -eq 0) 'Metadata helper failed in JSON mode.'
    $metadata = @($jsonOutput | ConvertFrom-Json -Depth 20)
    Assert-True ($metadata.Count -eq 2) 'Metadata helper did not return the two expected sessions.'
    Assert-True (@($metadata | Where-Object { $_.Id -eq $originalId -and $_.Name -eq 'lifecycle-original' -and -not $_.IsFork }).Count -eq 1) 'Original metadata is incorrect.'
    Assert-True (@($metadata | Where-Object { $_.Id -eq $forkId -and $_.Name -eq 'lifecycle-alternative' -and $_.IsFork -and $_.ParentId -eq $originalId }).Count -eq 1) 'Fork metadata is incorrect.'

    $bashJsonOutput = (& bash (Join-Path $PSScriptRoot 'list-sessions.sh') --sessions-directory $script:VerificationDirectory --format json 2>&1 | Out-String)
    Assert-True ($LASTEXITCODE -eq 0) 'Bash metadata helper failed in JSON mode.'
    $bashMetadata = @($bashJsonOutput | ConvertFrom-Json -Depth 20)
    Assert-True ($bashMetadata.Count -eq 2) 'Bash metadata helper did not return the two expected sessions.'
    Assert-True (@($bashMetadata | Where-Object { $_.Id -eq $originalId -and $_.Name -eq 'lifecycle-original' -and -not $_.IsFork }).Count -eq 1) 'Bash original metadata is incorrect.'
    Assert-True (@($bashMetadata | Where-Object { $_.Id -eq $forkId -and $_.Name -eq 'lifecycle-alternative' -and $_.IsFork -and $_.ParentId -eq $originalId }).Count -eq 1) 'Bash fork metadata is incorrect.'

    $tableOutput = (& pwsh (Join-Path $PSScriptRoot 'list-sessions.ps1') -SessionsDirectory $script:VerificationDirectory -Format Table 2>&1 | Out-String)
    Assert-True ($LASTEXITCODE -eq 0) 'Metadata helper failed in table mode.'
    $bashTableOutput = (& bash (Join-Path $PSScriptRoot 'list-sessions.sh') --sessions-directory $script:VerificationDirectory --format table 2>&1 | Out-String)
    Assert-True ($LASTEXITCODE -eq 0) 'Bash metadata helper failed in table mode.'
    foreach ($forbidden in @('ORBIT-41', 'COMET-73', $apiKey, $sampleDirectory, $originalPath)) {
        Assert-True (-not $jsonOutput.Contains($forbidden, [StringComparison]::Ordinal)) 'JSON metadata output exposed forbidden content or an absolute path.'
        Assert-True (-not $tableOutput.Contains($forbidden, [StringComparison]::Ordinal)) 'Table metadata output exposed forbidden content or an absolute path.'
        Assert-True (-not $bashJsonOutput.Contains($forbidden, [StringComparison]::Ordinal)) 'Bash JSON metadata output exposed forbidden content or an absolute path.'
        Assert-True (-not $bashTableOutput.Contains($forbidden, [StringComparison]::Ordinal)) 'Bash table metadata output exposed forbidden content or an absolute path.'
    }

    $freshDirectory = Join-Path $script:VerificationDirectory 'empty-continue'
    New-Item -Path $freshDirectory -ItemType Directory -Force | Out-Null
    $savedVerificationDirectory = $script:VerificationDirectory
    $script:VerificationDirectory = $freshDirectory
    try {
        Invoke-PiTurn -Phase 'continue with no target' -SessionId '(new)' `
            -SessionArguments @('-c', '--name', 'lifecycle-empty-continue') `
            -Prompt 'Reply exactly: FRESH-CONTINUE' `
            -ExpectedOutputMarker 'FRESH-CONTINUE'
    }
    finally {
        $script:VerificationDirectory = $savedVerificationDirectory
    }
    $freshFiles = @(Get-SessionFiles $freshDirectory)
    Assert-True ($freshFiles.Count -eq 1) 'Continue in an empty directory did not create exactly one session.'
    $fresh = Read-ValidatedSession -File $freshFiles[0]
    Assert-SuccessfulAssistantMarker $fresh 'FRESH-CONTINUE'
    Assert-True (-not $fresh.RawText.Contains($apiKey, [StringComparison]::Ordinal)) 'API key found in fresh continue session text.'

    Write-Host 'PASS: named start, continue, exact reopen, fork, ephemeral mode, PowerShell and Bash metadata privacy, and empty-directory continue.'
}
finally {
    if (Test-Path -LiteralPath $script:VerificationDirectory) {
        Remove-Item -LiteralPath $script:VerificationDirectory -Recurse -Force
    }
}
