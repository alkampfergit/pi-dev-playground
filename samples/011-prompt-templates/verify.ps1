[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $Message
    )

    if (-not $Condition) {
        throw "Verification failed: $Message"
    }
}

function Read-JsonLines {
    param([Parameter(Mandatory)] [string] $Path)

    $events = @()
    foreach ($line in Get-Content -LiteralPath $Path) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $events += ($line | ConvertFrom-Json -Depth 100)
        }
    }
    return $events
}

function Get-MessageText {
    param(
        [Parameter(Mandatory)] [object[]] $Events,
        [Parameter(Mandatory)] [string] $Role
    )

    $parts = foreach ($event in $Events) {
        if ($event.type -notin @('message_start', 'message_end')) { continue }
        if ($event.message.role -ne $Role) { continue }
        foreach ($content in @($event.message.content)) {
            if ($content.type -eq 'text') { $content.text }
        }
    }
    return ($parts -join "`n")
}

function Invoke-TemplateCheck {
    param(
        [Parameter(Mandatory)] [string] $Invocation,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [string] $ErrorPath
    )

    $arguments = @(
        '--mode', 'json',
        '--no-session',
        '--no-extensions',
        '--tools', 'read',
        '--model', "azure-openai/$env:AZURE_PI_TEST_DEPLOYMENT",
        $Invocation
    )

    & pi @arguments 1> $OutputPath 2> $ErrorPath
    if ($LASTEXITCODE -ne 0) {
        $details = Get-Content -LiteralPath $ErrorPath -Raw
        throw "Pi failed for '$Invocation' (exit $LASTEXITCODE): $details"
    }

    return @(Read-JsonLines -Path $OutputPath)
}

$requiredVariables = @(
    'AZURE_PI_TEST_ENDPOINT',
    'AZURE_PI_TEST_DEPLOYMENT',
    'AZURE_PI_TEST_API_KEY'
)

foreach ($name in $requiredVariables) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Missing $name. From this sample directory, run '. ./prepare.ps1' before './verify.ps1'."
    }
}

$sampleDirectory = $PSScriptRoot
if ((Get-Location).Path -ne $sampleDirectory) {
    throw "Run the verifier from $sampleDirectory so Pi loads this sample's context and templates."
}

$fixtures = @(
    (Join-Path $sampleDirectory 'exercise/calculator.ts'),
    (Join-Path $sampleDirectory 'exercise/change-request.md')
)
$hashesBefore = @{}
foreach ($fixture in $fixtures) {
    $hashesBefore[$fixture] = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash
}

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("pi-sample-011-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

try {
    $planEvents = Invoke-TemplateCheck `
        -Invocation '/plan-next ignored text' `
        -OutputPath (Join-Path $temporaryDirectory 'plan.jsonl') `
        -ErrorPath (Join-Path $temporaryDirectory 'plan.stderr.txt')
    $reviewEvents = Invoke-TemplateCheck `
        -Invocation '/review-file exercise/calculator.ts "integer boundary behavior"' `
        -OutputPath (Join-Path $temporaryDirectory 'review.jsonl') `
        -ErrorPath (Join-Path $temporaryDirectory 'review.stderr.txt')

    $planUser = Get-MessageText -Events $planEvents -Role 'user'
    $reviewUser = Get-MessageText -Events $reviewEvents -Role 'user'
    $planAssistant = Get-MessageText -Events $planEvents -Role 'assistant'
    $reviewAssistant = Get-MessageText -Events $reviewEvents -Role 'assistant'

    Assert-True ($planUser.Contains('TEMPLATE-MARKER: PLAN-NEXT')) 'plan marker was not present in the expanded user message'
    Assert-True ($planUser.Contains('exercise/change-request.md')) 'plan fixture path was not present after expansion'
    Assert-True (-not $planUser.Contains('/plan-next')) 'the plan slash invocation reached the model'
    Assert-True (-not $planUser.Contains('ignored text')) 'unused plan arguments did not disappear'
    Assert-True (-not $planUser.Contains('description:')) 'plan frontmatter reached the model'
    Assert-True (-not $planUser.Contains('---')) 'plan frontmatter delimiters reached the model'

    Assert-True ($reviewUser.Contains('TEMPLATE-MARKER: REVIEW-FILE')) 'review marker was not present in the expanded user message'
    Assert-True ($reviewUser.Contains('exercise/calculator.ts')) 'the review path was not substituted'
    Assert-True ($reviewUser.Contains('Focus on: `integer boundary behavior`.')) 'the quoted focus was not grouped and substituted as one argument'
    Assert-True (-not $reviewUser.Contains('/review-file')) 'the review slash invocation reached the model'
    Assert-True (-not $reviewUser.Contains('argument-hint:')) 'review frontmatter reached the model'
    Assert-True (-not $reviewUser.Contains('${2:-')) 'the default placeholder remained after expansion'

    Assert-True ($planAssistant.Contains('PROJECT-CONTEXT-011')) 'project context marker was absent from the plan response'
    Assert-True ($reviewAssistant.Contains('PROJECT-CONTEXT-011')) 'project context marker was absent from the review response'

    foreach ($fixture in $fixtures) {
        $hashAfter = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash
        Assert-True ($hashAfter -eq $hashesBefore[$fixture]) "fixture changed: $fixture"
    }

    Write-Host 'PASS: prompt templates expanded into structured user messages.'
    Write-Host 'PASS: quoted arguments and unused arguments behaved as documented.'
    Write-Host 'PASS: project context was observed and exercise fixture hashes are unchanged.'
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}
