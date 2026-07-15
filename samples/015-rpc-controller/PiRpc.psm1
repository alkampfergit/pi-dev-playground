Set-StrictMode -Version Latest

# The transport type deliberately knows nothing about Pi commands. It only turns
# arbitrary byte chunks into strict LF-framed records and keeps stdout/stderr
# separate. Routing and policy stay in PowerShell so the lesson remains visible.
if (-not ('PiSample015.StrictLfTransport' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace PiSample015 {
    public sealed class StrictLfRecord {
        public string Stream { get; }
        public string Kind { get; }
        public string Line { get; }
        public string Error { get; }

        public StrictLfRecord(string stream, string kind, string line, string error) {
            Stream = stream;
            Kind = kind;
            Line = line;
            Error = error;
        }
    }

    public sealed class StrictLfTransport : IDisposable {
        private readonly ConcurrentQueue<StrictLfRecord> stdout = new ConcurrentQueue<StrictLfRecord>();
        private readonly ConcurrentQueue<StrictLfRecord> stderr = new ConcurrentQueue<StrictLfRecord>();
        private readonly AutoResetEvent wake = new AutoResetEvent(false);
        private readonly Stream stdoutStream;
        private readonly Stream stderrStream;
        private readonly Task[] readers;
        private int disposed;

        public AutoResetEvent WakeEvent { get { return wake; } }

        public StrictLfTransport(Stream stdoutStream, Stream stderrStream) {
            this.stdoutStream = stdoutStream;
            this.stderrStream = stderrStream;
            readers = new[] {
                Task.Run(() => ReadStream(stdoutStream, stdout, "stdout")),
                Task.Run(() => ReadStream(stderrStream, stderr, "stderr")),
            };
        }

        private void Publish(ConcurrentQueue<StrictLfRecord> queue, StrictLfRecord record) {
            queue.Enqueue(record);
            wake.Set();
        }

        private async Task ReadStream(Stream stream, ConcurrentQueue<StrictLfRecord> queue, string streamName) {
            var encoding = new UTF8Encoding(false, true);
            var decoder = encoding.GetDecoder();
            var bytes = new byte[4096];
            var chars = new char[4096];
            var line = new StringBuilder();
            try {
                while (true) {
                    int count = await stream.ReadAsync(bytes, 0, bytes.Length).ConfigureAwait(false);
                    if (count == 0) break;
                    int charCount = decoder.GetChars(bytes, 0, count, chars, 0, false);
                    for (int index = 0; index < charCount; index++) {
                        char value = chars[index];
                        if (value == '\n') {
                            string framed = line.ToString();
                            if (framed.EndsWith("\r", StringComparison.Ordinal)) {
                                framed = framed.Substring(0, framed.Length - 1);
                            }
                            Publish(queue, new StrictLfRecord(streamName, "record", framed, null));
                            line.Clear();
                        } else {
                            line.Append(value);
                        }
                    }
                }
                // Flush the decoder so an incomplete UTF-8 sequence is a fault.
                decoder.GetChars(Array.Empty<byte>(), 0, 0, chars, 0, true);
                Publish(queue, new StrictLfRecord(streamName, "eof", null, null));
            } catch (Exception error) {
                Publish(queue, new StrictLfRecord(streamName, "fault", null, error.GetType().Name + ": " + error.Message));
                Publish(queue, new StrictLfRecord(streamName, "eof", null, null));
            }
        }

        public bool TryDequeueStdout(out StrictLfRecord record) { return stdout.TryDequeue(out record); }
        public bool TryDequeueStderr(out StrictLfRecord record) { return stderr.TryDequeue(out record); }

        public void Dispose() {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            try { stdoutStream.Dispose(); } catch { }
            try { stderrStream.Dispose(); } catch { }
            try { Task.WaitAll(readers, 1000); } catch { }
            wake.Dispose();
        }
    }
}
'@ -Language CSharp
}

function Get-RpcProperty {
    param(
        [AllowNull()][object] $Object,
        [Parameter(Mandatory)][string] $Name
    )
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-RpcProperty {
    param([AllowNull()][object] $Object, [Parameter(Mandatory)][string] $Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Assert-RpcTrue {
    param([bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw $Message }
}

function ConvertTo-RpcCopy {
    param([Parameter(Mandatory)][object] $Request)
    $copy = [ordered]@{}
    if ($Request -is [Collections.IDictionary]) {
        foreach ($key in $Request.Keys) { $copy[[string]$key] = $Request[$key] }
    } else {
        foreach ($property in $Request.PSObject.Properties) {
            if ($property.MemberType -match 'Property') { $copy[$property.Name] = $property.Value }
        }
    }
    return $copy
}

function Get-RpcSafeText {
    param([AllowNull()][object] $Value, [int] $Maximum = 300)
    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    $text = $text -replace '[\r\n]+', ' '
    $text = $text -replace '(?i)((?:api[-_]?key|authorization)\s*["'']?\s*[:=]\s*["'']?)[^"''\s,;]+', '$1[redacted]'
    $text = $text -replace '(?i)Bearer\s+[^\s,;]+', 'Bearer [redacted]'
    $text = $text -replace '(?i)(https?://[^\s?]+\?[^\s]*?(?:key|token|sig|secret|api[-_]?key)=[^&\s]+)', '$1[redacted]'
    if ($text.Length -gt $Maximum) { return $text.Substring(0, $Maximum) + '…' }
    return $text
}

function Add-RpcStderr {
    param([Parameter(Mandatory)][object] $Client, [AllowNull()][string] $Line)
    if ($null -eq $Line) { return }
    $safe = Get-RpcSafeText -Value $Line
    $Client.StderrTail.Enqueue($safe)
    $discard = ''
    while ($Client.StderrTail.Count -gt $Client.MaxStderrLineCount) {
        [void]$Client.StderrTail.TryDequeue([ref]$discard)
    }
}

function Set-RpcFault {
    param([Parameter(Mandatory)][object] $Client, [Parameter(Mandatory)][string] $Message)
    if ([string]::IsNullOrWhiteSpace([string]$Client.TransportFault)) {
        $Client.TransportFault = Get-RpcSafeText -Value $Message -Maximum 500
    }
}

function Get-RpcDiagnosticSummary {
    param([Parameter(Mandatory)][object] $Client)
    $stderr = @($Client.StderrTail.ToArray()) -join ' | '
    $parts = [Collections.Generic.List[string]]::new()
    if ($Client.LastEventType) { [void]$parts.Add("event=$($Client.LastEventType)") }
    if ($Client.LastNestedType) { [void]$parts.Add("nested=$($Client.LastNestedType)") }
    if ($Client.LastResponseId) { [void]$parts.Add("response=$($Client.LastResponseId)/$($Client.LastResponseCommand)/$($Client.LastResponseSuccess)") }
    [void]$parts.Add("events=$($Client.EventQueue.Count)")
    [void]$parts.Add("overflow=$($Client.EventOverflowCount)")
    [void]$parts.Add("stdout-eof=$($Client.StdoutEof)")
    [void]$parts.Add("process-exited=$($Client.ProcessExited)")
    if ($Client.TransportFault) { [void]$parts.Add("fault=$($Client.TransportFault)") }
    if ($stderr) { [void]$parts.Add("stderr=$stderr") }
    return ($parts -join '; ')
}

function New-RpcWaitError {
    param(
        [Parameter(Mandatory)][object] $Client,
        [Parameter(Mandatory)][string] $Message
    )
    return "$Message ($((Get-RpcDiagnosticSummary -Client $Client)))"
}

function Add-RpcEvent {
    param([Parameter(Mandatory)][object] $Client, [Parameter(Mandatory)][object] $Event)
    if ($Client.EventQueue.Count -ge $Client.MaxEventCount) {
        $dropped = $Client.EventQueue[0]
        $Client.EventQueue.RemoveAt(0)
        $Client.EventOverflowCount++
        $Client.LastDroppedEventType = [string](Get-RpcProperty $dropped 'type')
    }
    [void]$Client.EventQueue.Add($Event)
    $Client.LastEventType = [string](Get-RpcProperty $Event 'type')
    if ((Get-RpcProperty $Event 'type') -eq 'message_update') {
        $Client.LastNestedType = [string](Get-RpcProperty (Get-RpcProperty $Event 'assistantMessageEvent') 'type')
    }
}

function Write-RpcFrame {
    param(
        [Parameter(Mandatory)][object] $Client,
        [Parameter(Mandatory)][object] $Object,
        [switch] $InternalUiResponse
    )
    $json = $Object | ConvertTo-Json -Compress -Depth 100
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    [Threading.Monitor]::Enter($Client.WriteLock)
    try {
        if ($Client.InputClosed -or $Client.Stopped) { throw 'stdin is closed' }
        [void]$Client.Process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        [void]$Client.Process.StandardInput.BaseStream.WriteByte(10)
        $Client.Process.StandardInput.BaseStream.Flush()
    } catch {
        Set-RpcFault -Client $Client -Message "stdin write failed: $($_.Exception.Message)"
        throw (Get-RpcSafeText -Value "Pi RPC stdin write failed: $($_.Exception.Message)" -Maximum 500)
    } finally {
        [Threading.Monitor]::Exit($Client.WriteLock)
    }
}

function Send-RpcUiResponse {
    param([Parameter(Mandatory)][object] $Client, [Parameter(Mandatory)][object] $Request)
    $method = [string](Get-RpcProperty $Request 'method')
    $id = [string](Get-RpcProperty $Request 'id')
    if ($method -eq 'confirm') {
        Write-RpcFrame -Client $Client -Object ([ordered]@{ type = 'extension_ui_response'; id = $id; confirmed = $false }) -InternalUiResponse
    } elseif ($method -in @('select', 'input', 'editor')) {
        Write-RpcFrame -Client $Client -Object ([ordered]@{ type = 'extension_ui_response'; id = $id; cancelled = $true }) -InternalUiResponse
    } elseif ($method -notin @('notify', 'setStatus', 'setWidget', 'setTitle', 'set_editor_text')) {
        $Client.UiWarnings++
        Write-RpcFrame -Client $Client -Object ([ordered]@{ type = 'extension_ui_response'; id = $id; cancelled = $true }) -InternalUiResponse
    }
}

function Handle-RpcUiRequest {
    param([Parameter(Mandatory)][object] $Client, [Parameter(Mandatory)][object] $Request)
    $method = [string](Get-RpcProperty $Request 'method')
    $id = [string](Get-RpcProperty $Request 'id')
    if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($method)) {
        Set-RpcFault -Client $Client -Message 'extension_ui_request lacked a non-empty id or method'
        return
    }
    if ($method -eq 'setStatus') {
        $Client.UiStatus[[string](Get-RpcProperty $Request 'statusKey')] = Get-RpcSafeText (Get-RpcProperty $Request 'statusText') 120
    } elseif ($method -eq 'notify') {
        $Client.UiNotifications++
    } elseif ($method -notin @('confirm', 'select', 'input', 'editor', 'setWidget', 'setTitle', 'set_editor_text')) {
        $Client.UiWarnings++
    }
    if ($Client.UiPolicy -eq 'DenyDialogs') {
        Send-RpcUiResponse -Client $Client -Request $Request
    }
}

function Receive-PiRpcOutput {
    param([Parameter(Mandatory)][object] $Client)
    $record = $null
    while ($Client.Transport.TryDequeueStderr([ref]$record)) {
        if ($record.Kind -eq 'record') { Add-RpcStderr -Client $Client -Line $record.Line }
        elseif ($record.Kind -eq 'fault') { Set-RpcFault -Client $Client -Message "stderr reader fault: $($record.Error)" }
        elseif ($record.Kind -eq 'eof') { $Client.StderrEof = $true }
    }
    while ($Client.Transport.TryDequeueStdout([ref]$record)) {
        if ($record.Kind -eq 'eof') { $Client.StdoutEof = $true; continue }
        if ($record.Kind -eq 'fault') { Set-RpcFault -Client $Client -Message "stdout reader fault: $($record.Error)"; continue }
        if ([string]::IsNullOrWhiteSpace($record.Line)) {
            Set-RpcFault -Client $Client -Message 'blank stdout record is not valid RPC JSON'
            continue
        }
        try { $parsed = $record.Line | ConvertFrom-Json -Depth 100 }
        catch {
            Set-RpcFault -Client $Client -Message "malformed stdout JSON: $($_.Exception.Message)"
            continue
        }
        $type = Get-RpcProperty $parsed 'type'
        if ($type -isnot [string] -or [string]::IsNullOrWhiteSpace($type)) {
            Set-RpcFault -Client $Client -Message 'stdout object has no non-empty type'
            continue
        }
        $Client.LastEventType = [string]$type
        if ($type -eq 'response') {
            $idValue = Get-RpcProperty $parsed 'id'
            if ($idValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$idValue)) {
                Set-RpcFault -Client $Client -Message 'response has no non-empty string id'
                continue
            }
            $id = [string]$idValue
            if (-not $Client.Pending.ContainsKey($id)) {
                if ($Client.Responses.ContainsKey($id) -or $Client.UsedIds.Contains($id)) {
                    Set-RpcFault -Client $Client -Message "duplicate response id '$id'"
                } else {
                    Set-RpcFault -Client $Client -Message "unknown response id '$id'"
                }
                continue
            }
            if ($Client.Responses.ContainsKey($id)) {
                Set-RpcFault -Client $Client -Message "duplicate response id '$id'"
                continue
            }
            $Client.Responses[$id] = $parsed
            $Client.LastResponseId = $id
            $Client.LastResponseCommand = [string](Get-RpcProperty $parsed 'command')
            $Client.LastResponseSuccess = [string](Get-RpcProperty $parsed 'success')
        } elseif ($type -eq 'extension_ui_request') {
            Handle-RpcUiRequest -Client $Client -Request $parsed
            Add-RpcEvent -Client $Client -Event $parsed
        } else {
            Add-RpcEvent -Client $Client -Event $parsed
        }
    }
    try { $Client.ProcessExited = $Client.Process.HasExited } catch { $Client.ProcessExited = $true }
}

function Get-RpcWaitMilliseconds {
    param([Parameter(Mandatory)][Diagnostics.Stopwatch] $Clock, [Parameter(Mandatory)][double] $TimeoutSeconds)
    $remaining = ($TimeoutSeconds * 1000.0) - $Clock.Elapsed.TotalMilliseconds
    if ($remaining -le 0) { return 0 }
    return [Math]::Max(1, [Math]::Min([int]::MaxValue, [int][Math]::Ceiling($remaining)))
}

function Test-RpcEventMatch {
    param(
        [Parameter(Mandatory)][object] $Event,
        [string[]] $Type,
        [string[]] $NestedType
    )
    $eventType = [string](Get-RpcProperty $Event 'type')
    $typeMatches = ($null -eq $Type -or $Type.Count -eq 0 -or $Type -contains $eventType)
    if (-not $typeMatches) { return $false }
    if ($null -eq $NestedType -or $NestedType.Count -eq 0) { return $true }
    if ($eventType -ne 'message_update') { return $false }
    $nested = [string](Get-RpcProperty (Get-RpcProperty $Event 'assistantMessageEvent') 'type')
    return $NestedType -contains $nested
}

function Start-PiRpc {
    [CmdletBinding()]
    param(
        [string] $ExecutablePath,
        [string[]] $ArgumentList,
        [string] $WorkingDirectory,
        [int] $MaxEventCount = 512,
        [int] $MaxStderrLineCount = 40,
        [ValidateSet('DenyDialogs')][string] $UiPolicy = 'DenyDialogs'
    )
    Assert-RpcTrue ($MaxEventCount -gt 0) 'MaxEventCount must be positive.'
    Assert-RpcTrue ($MaxStderrLineCount -gt 0) 'MaxStderrLineCount must be positive.'
    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) { $ExecutablePath = (Get-Command pi -ErrorAction Stop).Source }
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory = (Get-Location).Path }
    $working = (Resolve-Path -LiteralPath $WorkingDirectory -ErrorAction Stop).Path
    Assert-RpcTrue (Test-Path -LiteralPath $working -PathType Container) "Working directory does not exist: $WorkingDirectory"
    $arguments = if ($null -eq $ArgumentList) { @('--mode', 'rpc') } else { @($ArgumentList) }
    $process = [Diagnostics.Process]::new()
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $ExecutablePath
    $start.WorkingDirectory = $working
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $arguments) { [void]$start.ArgumentList.Add([string]$argument) }
    $process.StartInfo = $start
    try {
        Assert-RpcTrue $process.Start() "Could not start '$ExecutablePath'."
        $transport = [PiSample015.StrictLfTransport]::new($process.StandardOutput.BaseStream, $process.StandardError.BaseStream)
        return [pscustomobject][ordered]@{
            Process = $process
            Transport = $transport
            WriteLock = [object]::new()
            Responses = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
            Pending = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            RequestTypes = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            UsedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            EventQueue = [Collections.Generic.List[object]]::new()
            StderrTail = [Collections.Generic.Queue[string]]::new()
            UiStatus = @{}
            MaxEventCount = $MaxEventCount
            MaxStderrLineCount = $MaxStderrLineCount
            UiPolicy = $UiPolicy
            NextId = 0
            ProcessGuid = [guid]::NewGuid().ToString('N')
            InputClosed = $false
            Stopped = $false
            StdoutEof = $false
            StderrEof = $false
            ProcessExited = $false
            TransportFault = $null
            EventOverflowCount = 0
            LastDroppedEventType = $null
            LastEventType = $null
            LastNestedType = $null
            LastResponseId = $null
            LastResponseCommand = $null
            LastResponseSuccess = $null
            UiNotifications = 0
            UiWarnings = 0
            CleanupForced = $false
            ExitCode = $null
        }
    } catch {
        try { if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit(1000) } } catch { }
        try { $process.Dispose() } catch { }
        throw
    }
}

function Send-PiRpcRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Client,
        [Parameter(Mandatory)][object] $Request
    )
    if ($Client.Stopped -or $Client.InputClosed -or $Client.TransportFault) { throw (New-RpcWaitError -Client $Client -Message 'Cannot send RPC request after transport shutdown') }
    $copy = ConvertTo-RpcCopy -Request $Request
    $type = Get-RpcProperty $copy 'type'
    Assert-RpcTrue ($type -is [string] -and -not [string]::IsNullOrWhiteSpace($type)) 'RPC request requires a non-empty string type.'
    Assert-RpcTrue ($type -ne 'extension_ui_response') 'extension_ui_response is reserved for the internal UI policy handler.'
    $requestedId = Get-RpcProperty $copy 'id'
    if (Test-RpcProperty $copy 'id') {
        Assert-RpcTrue ($requestedId -is [string] -and -not [string]::IsNullOrWhiteSpace($requestedId)) 'RPC id must be a non-empty string.'
        $id = [string]$requestedId
    } else {
        $Client.NextId++
        $id = ('rpc-{0:D6}-{1}' -f $Client.NextId, $Client.ProcessGuid)
    }
    Assert-RpcTrue (-not $Client.UsedIds.Contains($id)) "RPC id '$id' was already used."
    Assert-RpcTrue (-not $Client.Pending.ContainsKey($id)) "RPC id '$id' is already pending."
    $copy['id'] = $id
    [void]$Client.UsedIds.Add($id)
    $Client.Pending[$id] = [string]$type
    $Client.RequestTypes[$id] = [string]$type
    try {
        Write-RpcFrame -Client $Client -Object $copy
    } catch {
        [void]$Client.Pending.Remove($id)
        throw
    }
    return $id
}

function Wait-PiRpcResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Client,
        [Parameter(Mandatory)][string] $Id,
        [double] $TimeoutSeconds = 10
    )
    Assert-RpcTrue (-not [string]::IsNullOrWhiteSpace($Id)) 'Response ID must not be empty.'
    Assert-RpcTrue ($Client.Pending.ContainsKey($Id) -or $Client.Responses.ContainsKey($Id)) "RPC id '$Id' is not pending."
    Assert-RpcTrue ($TimeoutSeconds -ge 0) 'TimeoutSeconds must not be negative.'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        Receive-PiRpcOutput -Client $Client
        if ($Client.Responses.ContainsKey($Id)) {
            $response = $Client.Responses[$Id]
            $expected = $Client.RequestTypes[$Id]
            $actual = [string](Get-RpcProperty $response 'command')
            if ($actual -ne $expected) {
                Set-RpcFault -Client $Client -Message "response command '$actual' did not match request '$expected'"
                throw (New-RpcWaitError -Client $Client -Message "RPC response for '$Id' had the wrong command")
            }
            [void]$Client.Responses.Remove($Id)
            [void]$Client.Pending.Remove($Id)
            [void]$Client.RequestTypes.Remove($Id)
            return $response
        }
        if ($Client.TransportFault) { throw (New-RpcWaitError -Client $Client -Message "RPC response '$Id' failed") }
        if ($Client.ProcessExited -or $Client.StdoutEof) {
            Set-RpcFault -Client $Client -Message "process ended before response '$Id'"
            throw (New-RpcWaitError -Client $Client -Message "RPC response '$Id' was not received")
        }
        $milliseconds = Get-RpcWaitMilliseconds -Clock $clock -TimeoutSeconds $TimeoutSeconds
        if ($milliseconds -le 0) { throw (New-RpcWaitError -Client $Client -Message "Timed out waiting for RPC response '$Id'") }
        [void]$Client.Transport.WakeEvent.WaitOne($milliseconds)
    }
}

function Wait-PiRpcEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Client,
        [string[]] $Type,
        [string[]] $NestedType,
        [double] $TimeoutSeconds = 30
    )
    Assert-RpcTrue ($TimeoutSeconds -ge 0) 'TimeoutSeconds must not be negative.'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        Receive-PiRpcOutput -Client $Client
        for ($index = 0; $index -lt $Client.EventQueue.Count; $index++) {
            $candidate = $Client.EventQueue[$index]
            if (Test-RpcEventMatch -Event $candidate -Type $Type -NestedType $NestedType) {
                $Client.EventQueue.RemoveAt($index)
                return $candidate
            }
        }
        if ($Client.TransportFault) { throw (New-RpcWaitError -Client $Client -Message 'RPC event wait failed') }
        if ($Client.ProcessExited -or $Client.StdoutEof) {
            throw (New-RpcWaitError -Client $Client -Message 'Process ended before the requested RPC event')
        }
        $milliseconds = Get-RpcWaitMilliseconds -Clock $clock -TimeoutSeconds $TimeoutSeconds
        if ($milliseconds -le 0) { throw (New-RpcWaitError -Client $Client -Message 'Timed out waiting for RPC event') }
        [void]$Client.Transport.WakeEvent.WaitOne($milliseconds)
    }
}

function Stop-PiRpc {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Client,
        [double] $TimeoutSeconds = 5
    )
    if ($null -eq $Client -or $Client.Stopped) { return }
    Assert-RpcTrue ($TimeoutSeconds -ge 0) 'TimeoutSeconds must not be negative.'
    $Client.Stopped = $true
    $process = $Client.Process
    try {
        [Threading.Monitor]::Enter($Client.WriteLock)
        try {
            if (-not $Client.InputClosed) {
                try { $process.StandardInput.Close() } catch { }
                $Client.InputClosed = $true
            }
        } finally { [Threading.Monitor]::Exit($Client.WriteLock) }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try { $Client.ProcessExited = $process.HasExited } catch { $Client.ProcessExited = $true }
        if (-not $Client.ProcessExited) {
            $milliseconds = Get-RpcWaitMilliseconds -Clock $clock -TimeoutSeconds $TimeoutSeconds
            if ($milliseconds -gt 0) { [void]$process.WaitForExit($milliseconds) }
            try { $Client.ProcessExited = $process.HasExited } catch { $Client.ProcessExited = $true }
        }
        if ($Client.ProcessExited) {
            try { $Client.ExitCode = $process.ExitCode } catch { $Client.ExitCode = $null }
        }
        if (-not $Client.ProcessExited) {
            $Client.CleanupForced = $true
            try { $process.Kill($true) } catch { throw "Could not terminate Pi RPC process tree: $($_.Exception.Message)" }
            try { [void]$process.WaitForExit(1000) } catch { }
            try { $Client.ProcessExited = $process.HasExited } catch { $Client.ProcessExited = $true }
            if ($Client.ProcessExited) {
                try { $Client.ExitCode = $process.ExitCode } catch { $Client.ExitCode = $null }
            }
        }
    } finally {
        try { Receive-PiRpcOutput -Client $Client } catch { }
        try { $Client.Transport.Dispose() } catch { }
        try { $process.Dispose() } catch { }
    }
    if (-not $Client.ProcessExited) { throw 'Pi RPC process could not be terminated after forced cleanup.' }
}

Export-ModuleMember -Function Start-PiRpc, Send-PiRpcRequest, Wait-PiRpcResponse, Wait-PiRpcEvent, Stop-PiRpc
