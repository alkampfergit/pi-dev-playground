<#
.SYNOPSIS
    Finds and imports .env files from a directory and its parents.

.DESCRIPTION
    Import-DotEnv walks from StartDirectory to the filesystem root. .env files
    are imported from the root down to StartDirectory, so a nearer .env
    overrides a value from a parent .env. Variables already present in the
    process environment are preserved unless -Force is supplied.
#>

Set-StrictMode -Version Latest

function ConvertFrom-DotEnvLine {
    param(
        [Parameter(Mandatory)]
        [string] $Line
    )

    $trimmed = $Line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
        return
    }

    if ($trimmed -notmatch '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
        return
    }

    $name = $Matches[1]
    $value = $Matches[2].Trim()

    if ($value.Length -ge 2) {
        $first = $value[0]
        $last = $value[$value.Length - 1]
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $value = $value.Substring(1, $value.Length - 2)
            if ($first -eq '"') {
                $value = $value -replace '\\n', "`n" -replace '\\r', "`r" -replace '\\"', '"' -replace '\\\\', '\\'
            }
        }
    }

    [pscustomobject]@{
        Name  = $name
        Value = $value
    }
}

function Get-DotEnvFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $StartDirectory
    )

    $current = (Resolve-Path -LiteralPath $StartDirectory -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $current -PathType Container)) {
        throw "Start directory does not exist: $StartDirectory"
    }

    $files = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        $candidate = Join-Path -Path $current -ChildPath '.env'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $files.Add((Resolve-Path -LiteralPath $candidate).Path)
        }

        $parent = Split-Path -Path $current -Parent
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) {
            break
        }
        $current = $parent
    }

    # The walk collects nearest-first; import root-first so nearest wins.
    $files.Reverse()
    return $files.ToArray()
}

function Import-DotEnv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $StartDirectory,

        [switch] $Force
    )

    $files = @(Get-DotEnvFiles -StartDirectory $StartDirectory)
    $initialEnvironment = @{}
    Get-ChildItem Env: | ForEach-Object {
        $initialEnvironment[$_.Name] = $true
    }

    foreach ($file in $files) {
        foreach ($line in Get-Content -LiteralPath $file) {
            $entry = ConvertFrom-DotEnvLine -Line $line
            if ($null -eq $entry) {
                continue
            }

            if ($Force -or -not $initialEnvironment.ContainsKey($entry.Name)) {
                [Environment]::SetEnvironmentVariable($entry.Name, $entry.Value, 'Process')
            }
        }
    }

    return $files
}

Export-ModuleMember -Function Get-DotEnvFiles, Import-DotEnv
