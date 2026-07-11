Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Pi {
    param(
        [Parameter(Mandatory)]
        [string] $Label,

        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [AllowNull()]
        [string] $InputText
    )

    if ($PSBoundParameters.ContainsKey("InputText")) {
        $output = $InputText | & pi @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    }
    else {
        $output = & pi @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    }
    $exitCode = $LASTEXITCODE
    $text = $output -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw "$Label failed with exit code $exitCode.`n$text"
    }
    return $text
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Get-PackageSources {
    param([string] $SettingsPath)
    $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
    if ($null -eq $settings.packages) { return @() }
    $settingsDirectory = Split-Path -Parent $SettingsPath
    return @($settings.packages | ForEach-Object {
        $source = if ($_ -is [string]) { [string] $_ }
            elseif ($null -ne $_.source) { [string] $_.source }
            else { $null }
        if ($source) {
            # Pi 0.80.6 serializes an absolute local install as a path relative
            # to settings.json. Resolve it before comparing source identity.
            if ([System.IO.Path]::IsPathRooted($source)) {
                [System.IO.Path]::GetFullPath($source)
            }
            else {
                [System.IO.Path]::GetFullPath((Join-Path $settingsDirectory $source))
            }
        }
    })
}

function Get-Commands {
    $requestId = "sample-009-commands"
    $request = @{ id = $requestId; type = "get_commands" } | ConvertTo-Json -Compress
    $output = Invoke-Pi -Label "RPC get_commands" -Arguments @(
        "--mode", "rpc", "--no-session", "--offline", "--no-approve"
    ) -InputText $request

    $objects = @($output -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
    } | Where-Object { $null -ne $_ })
    $response = @($objects | Where-Object { $_.id -eq $requestId }) | Select-Object -First 1
    Assert-True ($null -ne $response) "RPC output did not contain response id '$requestId'. Output: $output"
    Assert-True ([bool] $response.success) "RPC get_commands reported failure. Output: $output"
    return @($response.data.commands)
}

function Get-CommandPath {
    param($Command)
    if ($Command.PSObject.Properties.Name -contains "path" -and $Command.path) {
        return [string] $Command.path
    }
    if ($Command.PSObject.Properties.Name -contains "sourceInfo" -and
        $null -ne $Command.sourceInfo -and
        $Command.sourceInfo.PSObject.Properties.Name -contains "path") {
        return [string] $Command.sourceInfo.path
    }
    return $null
}

function Find-PackageCommand {
    param(
        [object[]] $Commands,
        [string] $Name,
        [string] $Source,
        [string] $ExpectedPath
    )
    $expectedCanonical = [System.IO.Path]::GetFullPath($ExpectedPath)
    return @($Commands | Where-Object {
        $candidatePath = Get-CommandPath $_
        if (-not $candidatePath) { return $false }
        $candidateCanonical = [System.IO.Path]::GetFullPath($candidatePath)
        $_.name -eq $Name -and $_.source -eq $Source -and $candidateCanonical -eq $expectedCanonical
    }) | Select-Object -First 1
}

$sampleDir = [System.IO.Path]::GetFullPath($PSScriptRoot)
$packagePath = [System.IO.Path]::GetFullPath((Join-Path $sampleDir "package"))
$wireLogPath = Join-Path $packagePath "extensions/wire-log.ts"
$haikuPath = Join-Path $packagePath "skills/haiku/SKILL.md"

if (-not (Get-Command pi -ErrorAction SilentlyContinue)) {
    throw "The 'pi' CLI was not found on PATH. Install Pi before running this verifier."
}
$version = Invoke-Pi -Label "pi --version" -Arguments @("--version")
Write-Host "Pi version: $version (sample design validated with 0.80.6)"

$hadAgentDir = Test-Path Env:PI_CODING_AGENT_DIR
$oldAgentDir = $env:PI_CODING_AGENT_DIR
$hadOffline = Test-Path Env:PI_OFFLINE
$oldOffline = $env:PI_OFFLINE
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempBase "pi-sample-009-$PID-$([guid]::NewGuid().ToString('N'))"
$agentDir = Join-Path $tempRoot "agent"
$workDir = Join-Path $tempRoot "work"
$sentinel = Join-Path $tempRoot ".sample-009-sentinel"
$installed = $false
$removed = $false
$pushed = $false

Write-Host "Temporary verification root: $tempRoot"

try {
    New-Item -ItemType Directory -Path $agentDir, $workDir -Force | Out-Null
    New-Item -ItemType File -Path $sentinel -Force | Out-Null
    $env:PI_CODING_AGENT_DIR = $agentDir
    $env:PI_OFFLINE = "1"
    Push-Location $workDir
    $pushed = $true

    $installOutput = Invoke-Pi -Label "pi install" -Arguments @(
        "install", $packagePath, "--no-approve"
    )
    $installed = $true
    Assert-True ($installOutput -match [regex]::Escape("Installed $packagePath")) "install output did not report the absolute package path."

    $settingsPath = Join-Path $agentDir "settings.json"
    Assert-True (Test-Path -LiteralPath $settingsPath) "temporary settings.json was not created."
    $sources = @(Get-PackageSources $settingsPath)
    Assert-True ($sources -ccontains $packagePath) "settings packages do not contain the exact package path."

    $listOutput = Invoke-Pi -Label "pi list" -Arguments @("list", "--no-approve")
    Assert-True ($listOutput -match "User packages:") "pi list has no User packages section."
    Assert-True ($listOutput.Contains($packagePath)) "pi list does not contain the exact package path."
    Assert-True ($listOutput -notmatch "Project packages:") "package was unexpectedly classified as project-local."
    Assert-True (-not (Test-Path (Join-Path $agentDir "npm"))) "local package was unexpectedly copied to agent/npm."
    Assert-True (-not (Test-Path (Join-Path $agentDir "git"))) "local package was unexpectedly copied to agent/git."

    $commands = @(Get-Commands)
    Assert-True ($null -ne (Find-PackageCommand $commands "wire-log" "extension" $wireLogPath)) "packaged wire-log command was not discovered with the expected source and path."
    Assert-True ($null -ne (Find-PackageCommand $commands "skill:haiku" "skill" $haikuPath)) "packaged haiku skill was not discovered with the expected source and path."
    Assert-True (-not (Test-Path (Join-Path $agentDir "dump"))) "wire-log created dump output merely by being discovered."

    $removeOutput = Invoke-Pi -Label "pi remove" -Arguments @(
        "remove", $packagePath, "--no-approve"
    )
    $removed = $true
    Assert-True ($removeOutput -match [regex]::Escape("Removed $packagePath")) "remove output did not report the absolute package path."
    $sourcesAfter = @(Get-PackageSources $settingsPath)
    Assert-True ($sourcesAfter -cnotcontains $packagePath) "settings still contain the package after removal."

    $listAfter = Invoke-Pi -Label "pi list after removal" -Arguments @("list", "--no-approve")
    Assert-True ($listAfter -match "No packages installed\.") "pi list did not report that no packages are installed."

    $commandsAfter = @(Get-Commands)
    Assert-True ($null -eq (Find-PackageCommand $commandsAfter "wire-log" "extension" $wireLogPath)) "wire-log remains discoverable from the removed package."
    Assert-True ($null -eq (Find-PackageCommand $commandsAfter "skill:haiku" "skill" $haikuPath)) "haiku remains discoverable from the removed package."

    Write-Host "PASS: install, list, model-free discovery, remove, and fresh-process negative discovery all succeeded."
}
finally {
    if ($installed -and -not $removed) {
        try {
            $cleanupOutput = Invoke-Pi -Label "cleanup pi remove" -Arguments @(
                "remove", $packagePath, "--no-approve"
            )
            Write-Warning "Verifier cleanup removed the package after an earlier failure: $cleanupOutput"
        }
        catch {
            Write-Warning "Verifier cleanup could not remove the package registration: $($_.Exception.Message)"
        }
    }
    if ($pushed) { Pop-Location }
    if ($hadAgentDir) { $env:PI_CODING_AGENT_DIR = $oldAgentDir } else { Remove-Item Env:PI_CODING_AGENT_DIR -ErrorAction SilentlyContinue }
    if ($hadOffline) { $env:PI_OFFLINE = $oldOffline } else { Remove-Item Env:PI_OFFLINE -ErrorAction SilentlyContinue }

    $canonicalTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    $relativeToTemp = [System.IO.Path]::GetRelativePath($tempBase, $canonicalTempRoot)
    $isBelowTemp = -not [System.IO.Path]::IsPathRooted($relativeToTemp) -and
        $relativeToTemp -ne "." -and
        -not $relativeToTemp.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)")
    if ($isBelowTemp -and (Test-Path -LiteralPath $sentinel)) {
        Remove-Item -LiteralPath $canonicalTempRoot -Recurse -Force
    }
    elseif (Test-Path -LiteralPath $canonicalTempRoot) {
        Write-Warning "Refusing to delete unverified temporary path: $canonicalTempRoot"
    }
}
