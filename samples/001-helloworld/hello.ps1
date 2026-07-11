<#
001 - Hello World

The simplest possible pi.dev sample: ask the Pi coding agent to write a short
story about a cat into fable.md, running non-interactively against Azure AI
Foundry.
#>

[CmdletBinding()]
param(
    [switch] $Interactive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sampleDirectory = $PSScriptRoot
Set-Location -LiteralPath $sampleDirectory

$samplesDirectory = Split-Path -Path $sampleDirectory -Parent
$environmentModule = Join-Path -Path $samplesDirectory -ChildPath 'Env.psm1'
Import-Module -Name $environmentModule -Force

$envFiles = @(Import-DotEnv -StartDirectory $sampleDirectory)
foreach ($envFile in $envFiles) {
    Write-Host "🔑 loaded environment from $envFile"
}

if ([string]::IsNullOrWhiteSpace($env:AZURE_PI_TEST_API_KEY)) {
    throw 'AZURE_PI_TEST_API_KEY is not set. See README.md.'
}
if ([string]::IsNullOrWhiteSpace($env:AZURE_PI_TEST_ENDPOINT)) {
    throw 'AZURE_PI_TEST_ENDPOINT is not set. See README.md.'
}
if ([string]::IsNullOrWhiteSpace($env:AZURE_PI_TEST_DEPLOYMENT)) {
    throw 'AZURE_PI_TEST_DEPLOYMENT is not set. See README.md.'
}

# The configured deployment is a non-OpenAI Foundry model. Register it as a
# temporary OpenAI-compatible provider, using the deployment variable directly
# as the model id sent to Azure.
try {
    $endpointUri = [Uri] $env:AZURE_PI_TEST_ENDPOINT
    $baseUrl = "$($endpointUri.GetLeftPart([System.UriPartial]::Authority))/openai/v1"
}
catch {
    throw "AZURE_PI_TEST_ENDPOINT is not a valid URL: $($env:AZURE_PI_TEST_ENDPOINT)"
}

$providerId = 'azure-openai'
$modelId = $env:AZURE_PI_TEST_DEPLOYMENT
$piConfigDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "pi-hello-$([Guid]::NewGuid().ToString('N'))"
New-Item -Path $piConfigDirectory -ItemType Directory -Force | Out-Null

$modelsConfig = [ordered]@{
    providers = [ordered]@{
        $providerId = [ordered]@{
            baseUrl = $baseUrl
            api = 'openai-completions'
            apiKey = '$AZURE_PI_TEST_API_KEY'
            headers = [ordered]@{
                'api-key' = '$AZURE_PI_TEST_API_KEY'
            }
            compat = [ordered]@{
                supportsDeveloperRole = $false
                supportsReasoningEffort = $false
            }
            models = @(
                [ordered]@{
                    id = $modelId
                    name = "$modelId (Azure Foundry)"
                    reasoning = $false
                    input = @('text')
                    contextWindow = 256000
                    maxTokens = 8192
                    cost = [ordered]@{
                        input = 0
                        output = 0
                        cacheRead = 0
                        cacheWrite = 0
                    }
                }
            )
        }
    }
}
$modelsPath = Join-Path -Path $piConfigDirectory -ChildPath 'models.json'
$modelsConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $modelsPath -Encoding utf8

$piCommand = Get-Command -Name 'pi' -ErrorAction SilentlyContinue
$piExecutable = $null
$piArguments = [System.Collections.Generic.List[string]]::new()

if ($null -ne $piCommand) {
    $piExecutable = $piCommand.Source
}
else {
    $localCli = Join-Path -Path $samplesDirectory -ChildPath '../notebooks/node_modules/@earendil-works/pi-coding-agent/dist/cli.js'
    if (Test-Path -LiteralPath $localCli -PathType Leaf) {
        $piExecutable = 'node'
        $piArguments.Add((Resolve-Path -LiteralPath $localCli).Path)
    }
    else {
        $piExecutable = 'npx'
        $piArguments.Add('--yes')
        $piArguments.Add('@earendil-works/pi-coding-agent')
    }
}

$piArguments.Add('--model')
$piArguments.Add("$providerId/$modelId")
if (-not $Interactive) {
    $piArguments.Add('-p')
    $piArguments.Add('--tools')
    $piArguments.Add('write,read')
    $piArguments.Add('Write a short, warm fable about a cat — around 500 words, with a gentle moral at the end. Save it to fable.md as nicely formatted Markdown with a title heading. Then show me the file.')
}

$previousAgentDirectory = [Environment]::GetEnvironmentVariable('PI_CODING_AGENT_DIR', 'Process')
$env:PI_CODING_AGENT_DIR = $piConfigDirectory
try {
    if ($Interactive) {
        Write-Host "🐱 starting pi with model $providerId/$modelId ..."
    }
    else {
        Write-Host "🐱 asking pi ($providerId/$modelId) to write fable.md ..."
    }

    & $piExecutable @piArguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Pi exited with status $exitCode."
    }

    if ($Interactive) {
        return
    }

    $fablePath = Join-Path -Path $sampleDirectory -ChildPath 'fable.md'
    if (-not (Test-Path -LiteralPath $fablePath -PathType Leaf)) {
        throw 'fable.md was not created. Check the Pi output above.'
    }

    Write-Host "✅ fable.md created:"
    Get-Content -LiteralPath $fablePath
}
finally {
    if ($null -eq $previousAgentDirectory) {
        Remove-Item -Path Env:PI_CODING_AGENT_DIR -ErrorAction SilentlyContinue
    }
    else {
        $env:PI_CODING_AGENT_DIR = $previousAgentDirectory
    }
    Remove-Item -LiteralPath $piConfigDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
