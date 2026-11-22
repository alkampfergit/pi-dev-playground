[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$env:UV_CACHE_DIR = Join-Path $here '.uv-cache'
$env:HF_HOME = Join-Path $here '.hf-home'
$env:HF_HUB_CACHE = Join-Path $env:HF_HOME 'hub'

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    throw 'Install uv first: https://docs.astral.sh/uv/getting-started/installation/'
}

uv venv --python 3.12 (Join-Path $here '.venv')
if ($LASTEXITCODE -ne 0) { throw 'Could not create the sample-local Python 3.12 environment.' }
$python = if ($IsWindows) { Join-Path $here '.venv/Scripts/python.exe' } else { Join-Path $here '.venv/bin/python' }
uv pip install --python $python 'gliner==0.2.30' 'datasets>=3,<5'
if ($LASTEXITCODE -ne 0) { throw 'Could not install GLiNER into the sample-local environment.' }
& $python (Join-Path $here 'gliner/download_model.py')
if ($LASTEXITCODE -ne 0) { throw 'Could not download and package the local GLiNER model.' }
Write-Host "Ready. Local classifier Python: $python"
