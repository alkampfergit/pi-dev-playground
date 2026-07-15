<#
.SYNOPSIS
    Deterministic strict-LF protocol peer used by sample 015 verification.

This is intentionally a peer, not a second implementation of PiRpc.psm1. It
accepts JSONL commands, emits JSONL responses/events, and keeps diagnostics on
stderr. The controller still owns framing, correlation, routing, and policy.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$inputStream = [Console]::OpenStandardInput()
$outputStream = [Console]::OpenStandardOutput()
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$pending = [Collections.Generic.List[object]]::new()
$keepAlive = $false
$child = $null

function Read-StrictFrame {
    $bytes = [Collections.Generic.List[byte]]::new()
    while ($true) {
        $value = $inputStream.ReadByte()
        if ($value -lt 0) {
            if ($bytes.Count -eq 0) { return $null }
            throw 'fake peer received an unterminated input frame'
        }
        if ($value -eq 10) { break }
        [void]$bytes.Add([byte]$value)
    }
    if ($bytes.Count -gt 0 -and $bytes[$bytes.Count - 1] -eq 13) { $bytes.RemoveAt($bytes.Count - 1) }
    return $utf8.GetString($bytes.ToArray())
}

function Write-Bytes {
    param([Parameter(Mandatory)][byte[]] $Bytes, [int[]] $SplitAt)
    if ($null -eq $SplitAt -or $SplitAt.Count -eq 0) {
        $outputStream.Write($Bytes, 0, $Bytes.Length)
        $outputStream.Flush()
        return
    }
    $start = 0
    foreach ($end in ($SplitAt + $Bytes.Length)) {
        $count = $end - $start
        if ($count -gt 0) { $outputStream.Write($Bytes, $start, $count); $outputStream.Flush() }
        $start = $end
    }
}

function Write-Frame {
    param(
        [AllowNull()][object] $Value,
        [int[]] $SplitAt,
        [AllowEmptyString()][string] $RawJson
    )
    $json = if ($PSBoundParameters.ContainsKey('RawJson')) { $RawJson } else { $Value | ConvertTo-Json -Compress -Depth 100 }
    $bytes = $utf8.GetBytes($json + "`n")
    Write-Bytes -Bytes $bytes -SplitAt $SplitAt
}

function Write-Diagnostic {
    param([Parameter(Mandatory)][string] $Text)
    [Console]::Error.WriteLine($Text)
}

function Send-Response {
    param([Parameter(Mandatory)][object] $Request, [bool] $Success = $true, [AllowNull()][object] $Data, [string] $Error)
    $response = [ordered]@{
        id = [string]$Request.id
        type = 'response'
        command = [string]$Request.type
        success = $Success
    }
    if ($PSBoundParameters.ContainsKey('Data')) { $response.data = $Data }
    if ($PSBoundParameters.ContainsKey('Error')) { $response.error = $Error }
    Write-Frame -Value $response
}

function Send-ReversePair {
    param([Parameter(Mandatory)][object[]] $Requests)
    Write-Frame -Value ([ordered]@{
        type = 'message_update'
        assistantMessageEvent = [ordered]@{ type = 'text_delta'; delta = "caf`u{00E9} / U+2028=`u{2028} / U+2029=`u{2029} / CR=`r" }
    })
    Write-Frame -Value ([ordered]@{ type = 'queue_update'; count = 1; reason = 'fake-interleave' })
    Write-Frame -Value ([ordered]@{ type = 'extension_ui_request'; id = 'fake-notify-1'; method = 'notify'; message = '{"looks":"like json"}' })
    Send-Response -Request $Requests[1]
    Send-Response -Request $Requests[0]
}

while ($true) {
    $line = Read-StrictFrame
    if ($null -eq $line) {
        if ($keepAlive) {
            Start-Sleep -Milliseconds 100
            continue
        }
        break
    }
    $request = $line | ConvertFrom-Json -Depth 100
    $scenario = [string]$request.scenario
    switch ($scenario) {
        'reverse' {
            [void]$pending.Add($request)
            if ($pending.Count -eq 2) {
                Send-ReversePair -Requests @($pending)
                $pending.Clear()
            }
        }
        'split' {
            Write-Diagnostic '{"type":"response","id":"stderr-only","api-key":"secret-not-for-output"}'
            $probe = [ordered]@{ type = 'message_update'; assistantMessageEvent = [ordered]@{ type = 'text_delta'; delta = "split-`u{00E9}-frame`rvalue`u{2028}tail`u{2029}" } }
            $probeJson = $probe | ConvertTo-Json -Compress -Depth 100
            $probeBytes = $utf8.GetBytes($probeJson + "`n")
            $accent = [Array]::IndexOf($probeBytes, [byte]0xC3)
            if ($accent -lt 1) { $accent = [Math]::Max(1, [int]($probeBytes.Length / 2)) }
            Write-Bytes -Bytes $probeBytes -SplitAt @($accent + 1)
            Send-Response -Request $request
        }
        'timeout' {
            Write-Diagnostic 'timeout scenario: {"type":"response","id":"omitted"}'
        }
        'malformed' {
            Write-Frame -RawJson '{"type":broken-json'
        }
        'overflow' {
            for ($index = 0; $index -lt 8; $index++) {
                Write-Frame -Value ([ordered]@{ type = 'overflow_event'; index = $index })
            }
            Send-Response -Request $request
        }
        'forced_cleanup' {
            $keepAlive = $true
            $child = Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 600') -PassThru
            Write-Frame -Value ([ordered]@{ type = 'child_spawned'; pid = $child.Id })
            Send-Response -Request $request
        }
        default {
            if ([string]$request.type -eq 'unknown_for_sample_015') {
                Send-Response -Request $request -Success:$false -Error 'Unknown command: unknown_for_sample_015'
            } else {
                Send-Response -Request $request
            }
        }
    }
}

try { $inputStream.Dispose(); $outputStream.Dispose() } catch { }
