[CmdletBinding()]
param(
    [switch] $ModelFreeOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([Parameter(Mandatory)][bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw "Verification failed: $Message" }
}

function Invoke-Inspector {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $script = Join-Path $PSScriptRoot 'inspect-tree.ps1'
    $output = @(& pwsh -NoProfile -File $script @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = $output -join [Environment]::NewLine
    if ($exitCode -ne 0) { throw 'Inspector verification command failed.' }
    return $text
}

function Invoke-InspectorFailure {
    param([Parameter(Mandatory)][string[]] $Arguments, [Parameter(Mandatory)][string] $ExpectedReason, [Parameter(Mandatory)][string] $ExpectedName)
    $script = Join-Path $PSScriptRoot 'inspect-tree.ps1'
    $output = @(& pwsh -NoProfile -File $script @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = $output -join [Environment]::NewLine
    Assert-True ($exitCode -ne 0) 'malformed inspector input unexpectedly succeeded'
    Assert-True ($text -match [regex]::Escape($ExpectedReason)) 'inspector failure reason was not fixed and safe'
    Assert-True ($text -match [regex]::Escape($ExpectedName)) 'inspector failure did not identify only the input basename'
    Assert-True (-not ($text -match [regex]::Escape($PSScriptRoot))) 'inspector failure exposed the sample path'
}

function New-Header {
    param([Parameter(Mandatory)][string] $Id, [string] $ParentSession)
    $header = [ordered]@{ type = 'session'; version = 3; id = $Id; timestamp = '2026-07-11T10:00:00.000Z'; cwd = $PSScriptRoot }
    if ($ParentSession) { $header.parentSession = $ParentSession }
    return [pscustomobject]$header
}

function New-MessageEntry {
    param([Parameter(Mandatory)][string] $Id, [AllowNull()][string] $ParentId, [Parameter(Mandatory)][string] $Role, [Parameter(Mandatory)][string] $Text)
    $message = if ($Role -eq 'user') {
        [ordered]@{ role = 'user'; content = $Text; timestamp = 1760000000000 }
    } else {
        [ordered]@{ role = 'assistant'; content = @([ordered]@{ type = 'text'; text = $Text }); provider = 'fixture'; model = 'fixture'; stopReason = 'stop'; usage = [ordered]@{ input = 1; output = 1; totalTokens = 2 }; timestamp = 1760000000001 }
    }
    return [pscustomobject][ordered]@{ type = 'message'; id = $Id; parentId = $ParentId; timestamp = '2026-07-11T10:00:01.000Z'; message = [pscustomobject]$message }
}

function New-JsonlEntry {
    param([Parameter(Mandatory)][object] $Entry)
    return ($Entry | ConvertTo-Json -Depth 30 -Compress)
}

function Write-JsonlFixture {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][object[]] $Entries)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Entries) { $lines.Add((New-JsonlEntry $entry)) }
    [IO.File]::WriteAllText($Path, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

function Assert-OutputPrivate {
    param([Parameter(Mandatory)][string] $Text, [Parameter(Mandatory)][string[]] $Forbidden)
    foreach ($value in $Forbidden) {
        if ([string]::IsNullOrEmpty($value)) { continue }
        Assert-True (-not ($Text -match [regex]::Escape($value))) 'privacy-safe inspector output contained a denylisted value'
    }
}

function Get-RpcText {
    param([AllowNull()][object] $Message)
    if ($null -eq $Message -or -not ($Message.PSObject.Properties.Name -contains 'content')) { return '' }
    if ($Message.content -is [string]) { return [string]$Message.content }
    return ((@($Message.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { [string]$_.text }) -join '')
}

function Get-MessageEntries {
    param([Parameter(Mandatory)][object] $Entries)
    return @($Entries | Where-Object { $_.type -eq 'message' })
}

function Get-EntryByText {
    param([Parameter(Mandatory)][object] $Entries, [Parameter(Mandatory)][string] $Marker, [Parameter(Mandatory)][string] $Role)
    $matches = @(Get-MessageEntries $Entries | Where-Object { $_.message.role -eq $Role -and (Get-RpcText $_.message).Contains($Marker) })
    Assert-True ($matches.Count -eq 1) "expected one $Role entry for a fictional marker"
    return $matches[0]
}

function Get-EntryPath {
    param([Parameter(Mandatory)][object[]] $Entries, [Parameter(Mandatory)][string] $LeafId)
    $byId = @{}
    foreach ($entry in $Entries) { $byId[[string]$entry.id] = $entry }
    $path = [System.Collections.Generic.List[object]]::new()
    $cursor = $LeafId
    while ($cursor) {
        Assert-True $byId.ContainsKey($cursor) 'RPC active leaf parent chain contained an unknown entry'
        $path.Insert(0, $byId[$cursor])
        $cursor = if ($null -eq $byId[$cursor].parentId) { '' } else { [string]$byId[$cursor].parentId }
    }
    return @($path)
}

function New-RpcClient {
    param([Parameter(Mandatory)][string] $SessionDirectory, [AllowNull()][string] $SessionFile)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command pi -ErrorAction Stop).Source
    $start.WorkingDirectory = $PSScriptRoot
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $arguments = @('--mode', 'rpc', '--approve', '--model', "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT", '--no-tools', '--no-skills', '--no-prompt-templates', '--no-context-files')
    if ($SessionFile) { $arguments += @('--session', $SessionFile) }
    else { $arguments += @('--session-dir', $SessionDirectory) }
    foreach ($argument in $arguments) { [void]$start.ArgumentList.Add($argument) }
    $start.Environment['PI_CODING_AGENT_DIR'] = $PSScriptRoot
    $start.Environment['PI_SUMMARY_AUDIT_FIXTURE'] = '1'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    Assert-True $process.Start() 'Pi RPC process did not start'
    $stderrTask = $process.StandardError.ReadToEndAsync()
    return [pscustomobject]@{
        Process = $process
        NextId = 0
        Events = [System.Collections.Generic.List[object]]::new()
        StderrTask = $stderrTask
    }
}

function Read-RpcObject {
    param([Parameter(Mandatory)][object] $Client, [Parameter(Mandatory)][int] $TimeoutMilliseconds)
    $task = $Client.Process.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($TimeoutMilliseconds)) { throw 'RPC timed out while waiting for Pi output.' }
    $line = $task.Result
    if ($null -eq $line) { throw 'Pi RPC closed stdout before completing the request.' }
    try { return ($line | ConvertFrom-Json -Depth 100 -ErrorAction Stop) }
    catch { throw 'Pi RPC emitted invalid JSON.' }
}

function Send-Rpc {
    param([Parameter(Mandatory)][object] $Client, [Parameter(Mandatory)][hashtable] $Command)
    $id = "r$($Client.NextId)"
    $Client.NextId++
    $Command.id = $id
    $json = $Command | ConvertTo-Json -Depth 100 -Compress
    $Client.Process.StandardInput.WriteLine($json)
    $Client.Process.StandardInput.Flush()
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $remaining = 120000 - [int]$deadline.ElapsedMilliseconds
        if ($remaining -le 0) { throw "RPC timed out waiting for $($Command.type)." }
        $object = Read-RpcObject $Client ([Math]::Min($remaining, 5000))
        if ($object.type -eq 'response' -and $object.id -eq $id) {
            if (-not $object.success) { throw "RPC command $($Command.type) failed." }
            return $object
        }
        if ($object.type -eq 'extension_ui_request') {
            if ($object.method -in @('notify', 'setStatus', 'setWidget', 'setTitle', 'set_editor_text')) { continue }
            throw 'Unexpected interactive extension UI request in headless verifier.'
        }
        [void]$Client.Events.Add($object)
    }
}

function Wait-AgentEnd {
    param([Parameter(Mandatory)][object] $Client)
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $remaining = 180000 - [int]$deadline.ElapsedMilliseconds
        if ($remaining -le 0) { throw 'RPC timed out waiting for agent_end.' }
        $object = Read-RpcObject $Client ([Math]::Min($remaining, 5000))
        if ($object.type -eq 'agent_end') { [void]$Client.Events.Add($object); return }
        if ($object.type -eq 'agent_error') { throw 'Pi reported an agent error.' }
        if ($object.type -eq 'extension_ui_request' -and $object.method -in @('notify', 'setStatus', 'setWidget', 'setTitle', 'set_editor_text')) { continue }
        if ($object.type -eq 'extension_ui_request') { throw 'Unexpected interactive extension UI request in headless verifier.' }
        [void]$Client.Events.Add($object)
    }
}

function Invoke-Prompt {
    param([Parameter(Mandatory)][object] $Client, [Parameter(Mandatory)][string] $Message)
    $response = Send-Rpc $Client @{ type = 'prompt'; message = $Message }
    Assert-True $response.success 'prompt was not accepted by Pi'
    Wait-AgentEnd $Client
    $state = Send-Rpc $Client @{ type = 'get_state' }
    Assert-True (-not $state.data.isStreaming) 'agent remained streaming after agent_end'
    return $state
}

function Get-RpcEntries {
    param([Parameter(Mandatory)][object] $Client)
    return (Send-Rpc $Client @{ type = 'get_entries' }).data
}

function Get-RpcTree {
    param([Parameter(Mandatory)][object] $Client)
    return (Send-Rpc $Client @{ type = 'get_tree' }).data
}

function Get-RpcMessages {
    param([Parameter(Mandatory)][object] $Client)
    return (Send-Rpc $Client @{ type = 'get_messages' }).data.messages
}

function Close-RpcClient {
    param([AllowNull()][object] $Client)
    if ($null -eq $Client) { return }
    try { $Client.Process.StandardInput.Close() } catch {}
    try {
        if (-not $Client.Process.WaitForExit(5000)) {
            try { $Client.Process.Kill($true) } catch { try { $Client.Process.Kill() } catch {} }
            [void]$Client.Process.WaitForExit(5000)
        }
    } catch {}
}

function Read-SessionObjects {
    param([Parameter(Mandatory)][string] $Path)
    return @(Get-Content -LiteralPath $Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -Depth 100 })
}

function Get-CheckpointRecords {
    param([Parameter(Mandatory)][string] $Path)
    $objects = @(Read-SessionObjects $Path | Where-Object { $_.type -eq 'custom' -and $_.customType -eq 'summary-audit-checkpoint' })
    Assert-True ($objects.Count -gt 0) 'summary-audit checkpoint was not persisted'
    return @($objects[-1].data.records)
}

function Assert-EventOrder {
    param([Parameter(Mandatory)][object[]] $Records)
    for ($i = 1; $i -lt $Records.Count; $i++) { Assert-True ([int]$Records[$i].sequence -eq ([int]$Records[$i - 1].sequence + 1)) 'audit record sequence was not monotonic' }
    $pairs = @()
    for ($i = 0; $i -lt ($Records.Count - 1); $i++) {
        if ($Records[$i].event -eq 'session_before_tree' -and $Records[$i + 1].event -eq 'session_tree') { $pairs += ,@($Records[$i], $Records[$i + 1]) }
    }
    Assert-True ($pairs.Count -ge 3) 'audit records did not contain the summarized and plain tree transitions'
    Assert-True ($pairs[0][1].fromExtension -eq $true -and $pairs[0][1].hasSummaryEntry -eq $true) 'summarized tree transition was not marked as extension-produced'
    Assert-True (@($pairs | Where-Object { $_[1].hasSummaryEntry -eq $false }).Count -ge 2) 'plain tree navigation unexpectedly appended a summary'
}

function Invoke-ParserFixtures {
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("pi-014-fixtures-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    try {
        $linear = Join-Path $fixtureRoot 'linear.jsonl'
        $branch = Join-Path $fixtureRoot 'branch.jsonl'
        $compacted = Join-Path $fixtureRoot 'compacted.jsonl'
        Write-JsonlFixture $linear @(
            (New-Header '11111111-1111-4111-8111-111111111111'),
            (New-MessageEntry '10000101' $null 'user' 'FORBIDDEN-PROMPT LINEAR'),
            (New-MessageEntry '10000202' '10000101' 'assistant' 'FORBIDDEN-ASSISTANT LINEAR')
        )
        Write-JsonlFixture $branch @(
            (New-Header '22222222-2222-4222-8222-222222222222'),
            (New-MessageEntry '20000101' $null 'user' 'FORBIDDEN-PROMPT BRANCH'),
            (New-MessageEntry '20000202' '20000101' 'assistant' 'common'),
            (New-MessageEntry '20000303' '20000202' 'user' 'APPROACH-A FORBIDDEN-TOOL'),
            (New-MessageEntry '20000404' '20000303' 'assistant' 'FORBIDDEN-SUMMARY RAW A'),
            ([pscustomobject][ordered]@{ type = 'branch_summary'; id = '20000505'; parentId = '20000202'; timestamp = '2026-07-11T10:00:05.000Z'; fromId = '20000202'; summary = 'FORBIDDEN-SUMMARY'; fromHook = $true; details = [ordered]@{ data = 'FORBIDDEN-CUSTOM' } }),
            (New-MessageEntry '20000606' '20000505' 'user' 'B'),
            (New-MessageEntry '20000707' '20000606' 'assistant' 'B answer')
        )
        Write-JsonlFixture $compacted @(
            (New-Header '33333333-3333-4333-8333-333333333333'),
            (New-MessageEntry '30000101' $null 'user' 'OLD FORBIDDEN-PROMPT'),
            (New-MessageEntry '30000202' '30000101' 'assistant' 'OLD FORBIDDEN-TOOL'),
            (New-MessageEntry '30000303' '30000202' 'user' 'RETAINED-USER'),
            (New-MessageEntry '30000404' '30000303' 'assistant' 'RETAINED-ASSISTANT'),
            ([pscustomobject][ordered]@{ type = 'compaction'; id = '30000505'; parentId = '30000404'; timestamp = '2026-07-11T10:00:05.000Z'; summary = 'FORBIDDEN-SUMMARY'; firstKeptEntryId = '30000303'; tokensBefore = 42; fromHook = $true; details = [ordered]@{ arbitrary = 'FORBIDDEN-CUSTOM' } })
        )
        $validDirectory = Join-Path $fixtureRoot 'valid'
        New-Item -ItemType Directory -Path $validDirectory -Force | Out-Null
        Copy-Item $linear (Join-Path $validDirectory 'linear.jsonl')
        Copy-Item $branch (Join-Path $validDirectory 'branch.jsonl')
        Copy-Item $compacted (Join-Path $validDirectory 'compacted.jsonl')

        $forbidden = @('FORBIDDEN-PROMPT', 'FORBIDDEN-ASSISTANT', 'FORBIDDEN-TOOL', 'FORBIDDEN-SUMMARY', 'FORBIDDEN-CUSTOM', 'OLD', $PSScriptRoot, $fixtureRoot)
        foreach ($path in @($linear, $branch, $compacted)) {
            foreach ($format in @('Table', 'Json')) {
                $args = @('-SessionFile', $path, '-Format', $format)
                $text = Invoke-Inspector $args
                Assert-OutputPrivate $text $forbidden
                if ($format -eq 'Json') {
                    $projection = $text | ConvertFrom-Json -Depth 20
                    Assert-True ($projection.SchemaVersion -eq 1) 'fixture schema version mismatch'
                    if ($path -eq $linear) { Assert-True ($projection.Session.EntryCount -eq 2 -and $projection.Session.LeafCount -eq 1 -and $projection.Session.BranchPointCount -eq 0) 'linear fixture counts were wrong' }
                    if ($path -eq $branch) { Assert-True ($projection.Session.EntryCount -eq 7 -and $projection.Session.LeafCount -eq 2 -and $projection.Session.BranchPointCount -eq 1 -and @($projection.BranchSummaries).Count -eq 1) 'branch fixture counts were wrong' }
                    if ($path -eq $compacted) { Assert-True ($projection.Session.EntryCount -eq 5 -and @($projection.Compactions).Count -eq 1 -and $projection.Compactions[0].TokensBefore -eq 42) 'compaction fixture metadata was wrong' }
                }
            }
        }
        foreach ($format in @('Table', 'Json')) {
            $directoryText = Invoke-Inspector @('-SessionsDirectory', $validDirectory, '-Format', $format)
            Assert-OutputPrivate $directoryText $forbidden
            if ($format -eq 'Json') { Assert-True (@($directoryText | ConvertFrom-Json -Depth 20).Count -eq 3) 'directory inspector did not return all fixtures' }
        }

        $malformed = Join-Path $fixtureRoot 'malformed.jsonl'
        [IO.File]::WriteAllText($malformed, "{not-json`n", [Text.UTF8Encoding]::new($false))
        Invoke-InspectorFailure @('-SessionFile', $malformed, '-Format', 'Json') 'malformed JSON' 'malformed.jsonl'
        $duplicate = Join-Path $fixtureRoot 'duplicate.jsonl'
        Write-JsonlFixture $duplicate @((New-Header '44444444-4444-4444-8444-444444444444'), (New-MessageEntry '40000001' $null 'user' 'x'), (New-MessageEntry '40000001' '40000001' 'assistant' 'x'))
        Invoke-InspectorFailure @('-SessionFile', $duplicate, '-Format', 'Table') 'duplicate entry id' 'duplicate.jsonl'
        $unknown = Join-Path $fixtureRoot 'unknown-parent.jsonl'
        Write-JsonlFixture $unknown @((New-Header '55555555-5555-4555-8555-555555555555'), (New-MessageEntry '50000001' '50000002' 'user' 'x'))
        Invoke-InspectorFailure @('-SessionFile', $unknown, '-Format', 'Json') 'unknown parent id' 'unknown-parent.jsonl'
        $collision = Join-Path $fixtureRoot 'short-collision.jsonl'
        Write-JsonlFixture $collision @((New-Header '66666666-6666-4666-8666-666666666666'), (New-MessageEntry '60000001' $null 'user' 'x'), (New-MessageEntry '60000002' '60000001' 'assistant' 'x'))
        Invoke-InspectorFailure @('-SessionFile', $collision, '-Format', 'Table') 'short-id collision' 'short-collision.jsonl'
        return [pscustomobject]@{ Files = 7; ValidEntries = 14 }
    } finally {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-LiveVerification {
    param([Parameter(Mandatory)][string] $VerificationDirectory)
    $client = $null
    $reload = $null
    $clone = $null
    $fork = $null
    $originalPath = $null
    $clonePath = $null
    $forkPath = $null
    try {
        New-Item -ItemType Directory -Path $VerificationDirectory -Force | Out-Null
        $client = New-RpcClient $VerificationDirectory $null
        $null = Send-Rpc $client @{ type = 'set_auto_compaction'; enabled = $false }
        Invoke-Prompt $client 'Remember fictional code HARBOR-17. Reply exactly: HARBOR-17.' | Out-Null
        Invoke-Prompt $client 'Develop fictional APPROACH-A. Reply exactly: APPROACH-A.' | Out-Null
        $beforeA = Get-RpcEntries $client
        $aUser = Get-EntryByText $beforeA.entries 'APPROACH-A' 'user'
        $aAssistant = Get-EntryByText $beforeA.entries 'APPROACH-A' 'assistant'
        $sourceState = Send-Rpc $client @{ type = 'get_state' }
        $originalPath = [string]$sourceState.data.sessionFile
        Assert-True (Test-Path -LiteralPath $originalPath) 'original session file was not persisted'
        $originalHash = (Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash
        $null = Send-Rpc $client @{ type = 'prompt'; message = "/summary-audit navigate $($aUser.id) summary" }
        Invoke-Prompt $client 'Continue with fictional APPROACH-B. Reply exactly: APPROACH-B.' | Out-Null
        $afterB = Get-RpcEntries $client
        $tree = Get-RpcTree $client
        Assert-True (@($tree.tree).Count -eq 1) 'live session did not have exactly one logical tree root'
        $bUser = Get-EntryByText $afterB.entries 'APPROACH-B' 'user'
        $bAssistant = Get-EntryByText $afterB.entries 'APPROACH-B' 'assistant'
        $branchSummary = @($afterB.entries | Where-Object { $_.type -eq 'branch_summary' })
        Assert-True ($branchSummary.Count -eq 1 -and $branchSummary[0].fromHook -eq $true -and $branchSummary[0].summary -eq 'SUMMARY-AUDIT BRANCH V1') 'fixture tree did not persist one extension branch summary'
        Assert-True ($branchSummary[0].details.schemaVersion -eq 1 -and $branchSummary[0].details.fixture -eq 'branch') 'branch summary fixture details were not persisted'
        Assert-True ($branchSummary[0].parentId -eq $branchSummary[0].fromId) 'branch summary was not attached at its destination position'
        Assert-True ((@($afterB.entries | Where-Object { $_.parentId -eq $aUser.id }).Count) -ge 1) 'abandoned A path was not preserved'
        Assert-True ((Get-EntryPath $afterB.entries $afterB.leafId).id -contains $bAssistant.id) 'B path was not active'
        $null = Send-Rpc $client @{ type = 'prompt'; message = "/summary-audit navigate $($aAssistant.id) plain" }
        $null = Send-Rpc $client @{ type = 'prompt'; message = "/summary-audit navigate $($bAssistant.id) plain" }
        $null = Send-Rpc $client @{ type = 'prompt'; message = '/summary-audit checkpoint' }
        $recordsBeforeCompact = Get-CheckpointRecords $originalPath
        Assert-EventOrder $recordsBeforeCompact
        $compactResponse = Send-Rpc $client @{ type = 'compact'; customInstructions = 'Keep fictional codes and the selected approach.' }
        $compactData = $compactResponse.data
        $compactedEntries = Get-RpcEntries $client
        $compactionEntry = @($compactedEntries.entries | Where-Object { $_.type -eq 'compaction' })[-1]
        Assert-True ($compactionEntry.fromHook -eq $true -and $compactionEntry.summary -eq 'SUMMARY-AUDIT COMPACTION V1' -and $compactionEntry.details.schemaVersion -eq 1 -and $compactionEntry.details.fixture -eq 'compaction' -and $compactData.firstKeptEntryId -eq $compactionEntry.firstKeptEntryId -and $compactData.tokensBefore -eq $compactionEntry.tokensBefore -and $compactData.tokensBefore -gt 0) 'fixture compaction boundary did not match its RPC result'
        $null = Send-Rpc $client @{ type = 'prompt'; message = '/summary-audit checkpoint' }
        $compactionAudit = Get-CheckpointRecords $originalPath
        $beforeRecords = @($compactionAudit | Where-Object { $_.event -eq 'session_before_compact' })
        $afterRecords = @($compactionAudit | Where-Object { $_.event -eq 'session_compact' })
        Assert-True ($beforeRecords.Count -ge 1 -and $afterRecords.Count -ge 1) 'compaction audit records were not persisted'
        $beforeLast = $beforeRecords[-1]
        $afterLast = $afterRecords[-1]
        Assert-True ($beforeLast.isSplitTurn -eq $true -and $beforeLast.turnPrefixMessages -ge 1 -and $beforeLast.reason -eq 'manual' -and $beforeLast.willRetry -eq $false) 'compaction did not exercise the split-turn preparation contract'
        Assert-True ($afterLast.fromExtension -eq $true -and $afterLast.reason -eq 'manual' -and $afterLast.willRetry -eq $false) 'compaction after-event contract was wrong'
        $sourceObjects = Read-SessionObjects $originalPath
        Assert-True (@($sourceObjects | Where-Object { $_.id -eq $compactionEntry.firstKeptEntryId }).Count -eq 1) 'compaction kept boundary was not persisted'
        $compactionSequence = -1
        for ($sourceIndex = 0; $sourceIndex -lt $sourceObjects.Count; $sourceIndex++) {
            if ($sourceObjects[$sourceIndex].id -eq $compactionEntry.id) { $compactionSequence = $sourceIndex; break }
        }
        Assert-True ($compactionSequence -gt 0) 'compaction did not retain older JSONL history before its boundary'
        $messages = Get-RpcMessages $client
        Assert-True (@($messages | Where-Object { $_.role -eq 'compactionSummary' }).Count -eq 1) 'rebuilt context did not contain one compaction summary'
        Assert-True (@($messages | Where-Object { $_.role -in @('user', 'assistant') -and (Get-RpcText $_).Contains('HARBOR-17') }).Count -eq 0) 'older marker remained as an ordinary rebuilt message'
        Close-RpcClient $client; $client = $null

        $reload = New-RpcClient $VerificationDirectory $originalPath
        $reloadMessages = Get-RpcMessages $reload
        Assert-True (@($reloadMessages | Where-Object { $_.role -eq 'compactionSummary' }).Count -eq 1) 'fresh reload lost the compaction summary'
        Assert-True (@($reloadMessages | Where-Object { $_.role -in @('user', 'assistant') -and (Get-RpcText $_).Contains('HARBOR-17') }).Count -eq 0) 'fresh reload rebuilt an older summarized marker as an ordinary message'
        Close-RpcClient $reload
        $reload = $null

        $clone = New-RpcClient $VerificationDirectory $originalPath
        $sourceHashBeforeClone = (Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash
        $sourceBeforeClone = Get-RpcEntries $clone
        $sourceActivePathIds = @(Get-EntryPath $sourceBeforeClone.entries $sourceBeforeClone.leafId | ForEach-Object { [string]$_.id })
        $cloneResponse = Send-Rpc $clone @{ type = 'clone' }
        Assert-True ($cloneResponse.data.cancelled -eq $false) 'clone was cancelled'
        $cloneState = Send-Rpc $clone @{ type = 'get_state' }
        $clonePath = [string]$cloneState.data.sessionFile
        Assert-True ($clonePath -and $clonePath -ne $originalPath -and (Test-Path -LiteralPath $clonePath)) 'clone did not replace the session with a new file'
        Assert-True ((Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash -eq $sourceHashBeforeClone) 'clone modified the source file'
        $cloneHeader = (Read-SessionObjects $clonePath)[0]
        Assert-True ([string]$cloneHeader.parentSession -eq $originalPath) 'clone provenance did not name the source session'
        $cloneEntries = Get-RpcEntries $clone
        $clonePathIds = @($cloneEntries.entries | ForEach-Object { [string]$_.id })
        Assert-True (($clonePathIds -join ',') -eq ($sourceActivePathIds -join ',')) 'clone did not copy exactly the active source path'
        Assert-True (@($cloneEntries.entries | Where-Object { $_.type -eq 'message' -and (Get-RpcText $_.message).Contains('APPROACH-A') }).Count -eq 0) 'clone copied an abandoned A-only entry'
        Invoke-Prompt $clone 'Record fictional CLONE-ONLY-29 in this clone. Reply exactly: CLONE-ONLY-29.' | Out-Null
        Assert-True (-not ((Get-Content -LiteralPath $originalPath -Raw).Contains('CLONE-ONLY-29'))) 'clone-only marker leaked into the source'
        Close-RpcClient $clone; $clone = $null

        $fork = New-RpcClient $VerificationDirectory $originalPath
        $null = Send-Rpc $fork @{ type = 'prompt'; message = "/summary-audit navigate $($aAssistant.id) plain" }
        $forkBefore = Get-RpcEntries $fork
        $forkChoices = (Send-Rpc $fork @{ type = 'get_fork_messages' }).data.messages
        $forkChoice = @($forkChoices | Where-Object { $_.entryId -eq $aUser.id })
        Assert-True ($forkChoice.Count -eq 1) 'A user message was not available from the active fork branch'
        $sourceHashBeforeFork = (Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash
        $forkResponse = Send-Rpc $fork @{ type = 'fork'; entryId = $aUser.id }
        Assert-True ($forkResponse.data.cancelled -eq $false -and ([string]$forkResponse.data.text).Contains('APPROACH-A')) 'fork did not return the selected user text'
        $forkState = Send-Rpc $fork @{ type = 'get_state' }
        $forkPath = [string]$forkState.data.sessionFile
        Assert-True ($forkPath -and $forkPath -ne $originalPath -and (Test-Path -LiteralPath $forkPath)) 'fork did not replace the session with a new file'
        Assert-True ((Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash -eq $sourceHashBeforeFork) 'fork modified the source file'
        $forkHeader = (Read-SessionObjects $forkPath)[0]
        Assert-True ([string]$forkHeader.parentSession -eq $originalPath) 'fork provenance did not name the source session'
        $forkForkEntries = Get-RpcEntries $fork
        $expectedForkPath = @(Get-EntryPath $forkBefore.entries $aUser.id | Where-Object { $_.id -ne $aUser.id } | ForEach-Object { [string]$_.id })
        $actualForkPath = @($forkForkEntries.entries | ForEach-Object { [string]$_.id })
        Assert-True (($actualForkPath -join ',') -eq ($expectedForkPath -join ',')) 'fork did not cut exactly before the selected user message'
        Assert-True (@($forkForkEntries.entries | Where-Object { $_.id -eq $aUser.id }).Count -eq 0) 'fork retained the selected user entry instead of cutting before it'
        Invoke-Prompt $fork 'Record fictional FORK-ONLY-38 in this fork. Reply exactly: FORK-ONLY-38.' | Out-Null
        Assert-True (-not ((Get-Content -LiteralPath $originalPath -Raw).Contains('FORK-ONLY-38'))) 'fork-only marker leaked into the source'
        Close-RpcClient $fork; $fork = $null

        $outputs = [System.Collections.Generic.List[string]]::new()
        foreach ($format in @('Table', 'Json')) { $outputs.Add((Invoke-Inspector @('-SessionsDirectory', $VerificationDirectory, '-Format', $format))) }
        $deny = @('HARBOR-17', 'APPROACH-A', 'APPROACH-B', 'CLONE-ONLY-29', 'FORK-ONLY-38', 'SUMMARY-AUDIT BRANCH V1', 'SUMMARY-AUDIT COMPACTION V1', $env:AZURE_PI_TEST_API_KEY, $PSScriptRoot, $VerificationDirectory, 'summary-audit-checkpoint')
        foreach ($output in $outputs) { Assert-OutputPrivate $output $deny }
        return [pscustomobject]@{ Sessions = 3; Entries = (Invoke-Inspector @('-SessionsDirectory', $VerificationDirectory, '-Format', 'Json') | ConvertFrom-Json -Depth 20 | ForEach-Object { $_.Session.EntryCount } | Measure-Object -Sum).Sum }
    } finally {
        Close-RpcClient $client
        Close-RpcClient $reload
        Close-RpcClient $clone
        Close-RpcClient $fork
    }
}

$requiredCommands = @('node', 'pwsh', 'pi')
foreach ($command in $requiredCommands) { Assert-True ($null -ne (Get-Command $command -ErrorAction SilentlyContinue)) "required command '$command' was not found" }
$piVersion = (& pi --version | Out-String).Trim()
Assert-True ($piVersion -eq '0.80.6') 'this sample requires Pi 0.80.6'
$expectedDirectory = [IO.Path]::GetFullPath($PSScriptRoot)
Assert-True ([IO.Path]::GetFullPath($env:PI_CODING_AGENT_DIR) -eq $expectedDirectory) 'source ./prepare.ps1 before running this verifier'
$savedFixture = [Environment]::GetEnvironmentVariable('PI_SUMMARY_AUDIT_FIXTURE', 'Process')
$verificationDirectory = Join-Path $PSScriptRoot ('sessions/verification/' + [guid]::NewGuid().ToString('N'))
$fixtureResult = $null
$liveResult = $null
try {
    $fixtureResult = Invoke-ParserFixtures
    if ($ModelFreeOnly) {
        Write-Host ("PASS: model-free parser and privacy checks (files={0}, entries={1})." -f $fixtureResult.Files, $fixtureResult.ValidEntries)
        exit 0
    }
    foreach ($name in @('AZURE_PI_TEST_ENDPOINT', 'AZURE_PI_TEST_DEPLOYMENT', 'AZURE_PI_TEST_API_KEY')) {
        Assert-True (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) "required environment variable $name is missing"
    }
    $env:PI_SUMMARY_AUDIT_FIXTURE = '1'
    $liveResult = Invoke-LiveVerification $verificationDirectory
    Write-Host ("PASS: tree, branch summary, compaction, reload, clone, fork, and privacy checks (sessions={0}, entries={1})." -f $liveResult.Sessions, $liveResult.Entries)
}
finally {
    if ($null -eq $savedFixture) { Remove-Item Env:PI_SUMMARY_AUDIT_FIXTURE -ErrorAction SilentlyContinue }
    else { $env:PI_SUMMARY_AUDIT_FIXTURE = $savedFixture }
    Remove-Item -LiteralPath $verificationDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
