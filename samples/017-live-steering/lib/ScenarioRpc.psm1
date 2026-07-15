Set-StrictMode -Version Latest

if (-not ('Sample017LinePump' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public sealed class Sample017LinePump : IDisposable {
  public readonly Process Process;
  public readonly ConcurrentQueue<string> Out = new();
  public readonly ConcurrentQueue<string> Err = new();
  public readonly AutoResetEvent Wake = new(false);
  private readonly Task stdout;
  private readonly Task stderr;
  public Sample017LinePump(string file, string cwd, string[] args) {
    var si = new ProcessStartInfo(file) { WorkingDirectory=cwd, UseShellExecute=false,
      RedirectStandardInput=true, RedirectStandardOutput=true, RedirectStandardError=true };
    foreach (var arg in args) si.ArgumentList.Add(arg);
    Process = new Process { StartInfo=si };
    if (!Process.Start()) throw new InvalidOperationException("could not start Pi");
    stdout = Task.Run(async () => { string line; while ((line=await Process.StandardOutput.ReadLineAsync()) != null) { Out.Enqueue(line); Wake.Set(); } Wake.Set(); });
    stderr = Task.Run(async () => { string line; while ((line=await Process.StandardError.ReadLineAsync()) != null) { Err.Enqueue(line); Wake.Set(); } Wake.Set(); });
  }
  public void Dispose() { try { Process.Dispose(); } catch {} try { Wake.Dispose(); } catch {} }
}
'@
}

function Start-ScenarioRpc {
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$WorkingDirectory = $PSScriptRoot)
    $pump = [Sample017LinePump]::new((Get-Command pi -ErrorAction Stop).Source, (Resolve-Path $WorkingDirectory).Path, $Arguments)
    [pscustomobject]@{ Pump=$pump; Events=[Collections.Generic.List[object]]::new(); Responses=@{}; Stderr=[Collections.Generic.Queue[string]]::new(); NextId=0; Closed=$false }
}

function Protect-ScenarioText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $safe = $Text
    foreach ($name in @('AZURE_PI_TEST_ENDPOINT','AZURE_PI_TEST_API_KEY')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $safe = $safe -replace [regex]::Escape($value), '[redacted]'
        }
    }
    $safe = $safe -replace '(?i)(authorization|api[-_]?key|x-api-key|bearer)\s*[:=]?\s*\S+', '$1 [redacted]'
    $safe = $safe -replace '(?i)(https?://)[^\s"''<>]+', '$1[redacted-endpoint]'
    return $safe.Substring(0, [Math]::Min(300, $safe.Length))
}

function Receive-ScenarioRpc {
    param([Parameter(Mandatory)]$Client)
    $line = $null
    while ($Client.Pump.Err.TryDequeue([ref]$line)) {
        $Client.Stderr.Enqueue((Protect-ScenarioText ([string]$line)))
        while ($Client.Stderr.Count -gt 20) { [void]$Client.Stderr.Dequeue() }
    }
    while ($Client.Pump.Out.TryDequeue([ref]$line)) {
        try { $record = $line | ConvertFrom-Json -Depth 100 -ErrorAction Stop } catch { throw 'Pi emitted malformed RPC JSON.' }
        $recordType = $record.PSObject.Properties['type']?.Value
        $recordId = $record.PSObject.Properties['id']?.Value
        if ($recordType -eq 'response' -and $recordId) { $Client.Responses[[string]$recordId] = $record }
        else {
            if ($Client.Events.Count -ge 512) { $Client.Events.RemoveAt(0) }
            [void]$Client.Events.Add($record)
        }
    }
}

function Send-ScenarioRpc {
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][hashtable]$Request, [double]$TimeoutSeconds=10)
    $Client.NextId++
    $id = "sample017-$($Client.NextId)-$([guid]::NewGuid().ToString('N'))"
    $Request.id = $id
    $json = $Request | ConvertTo-Json -Compress -Depth 100
    $Client.Pump.Process.StandardInput.WriteLine($json)
    $Client.Pump.Process.StandardInput.Flush()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Receive-ScenarioRpc $Client
        if ($Client.Responses.ContainsKey($id)) {
            $response = $Client.Responses[$id]; $Client.Responses.Remove($id)
            if (-not $response.success) { throw "RPC '$($Request.type)' was rejected." }
            return $response
        }
        if ($Client.Pump.Process.HasExited) { throw "Pi exited before '$($Request.type)' responded." }
        [void]$Client.Pump.Wake.WaitOne(50)
    }
    throw "Timed out waiting for RPC '$($Request.type)'."
}

function Wait-ScenarioEvent {
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][scriptblock]$Predicate, [double]$TimeoutSeconds=30)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Receive-ScenarioRpc $Client
        for ($i=0; $i -lt $Client.Events.Count; $i++) {
            $candidate = $Client.Events[$i]
            if (& $Predicate $candidate) { $Client.Events.RemoveAt($i); return $candidate }
        }
        if ($Client.Pump.Process.HasExited) { throw 'Pi exited before the expected event.' }
        [void]$Client.Pump.Wake.WaitOne(50)
    }
    throw 'Timed out waiting for the expected event.'
}

function Stop-ScenarioRpc {
    param([Parameter(Mandatory)]$Client, [double]$TimeoutSeconds=5)
    if ($Client.Closed) { return }
    $Client.Closed=$true
    try { $Client.Pump.Process.StandardInput.Close() } catch {}
    if (-not $Client.Pump.Process.WaitForExit([int]($TimeoutSeconds*1000))) {
        try { $Client.Pump.Process.Kill($true) } catch {}
        [void]$Client.Pump.Process.WaitForExit(1000)
    }
    Receive-ScenarioRpc $Client
    $code=$Client.Pump.Process.ExitCode
    $Client.Pump.Dispose()
    if ($code -ne 0) { throw "Pi exited $code. stderr: $(@($Client.Stderr) -join ' | ')" }
}

Export-ModuleMember -Function Start-ScenarioRpc,Receive-ScenarioRpc,Send-ScenarioRpc,Wait-ScenarioEvent,Stop-ScenarioRpc
