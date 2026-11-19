<#
.SYNOPSIS
    Shared helpers for build-app.ps1 and build-installer.ps1. Dot-source it; don't run it.
#>

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

function Invoke-Native {
    # Runs a program, shows its output, and throws if it exits nonzero.
    # stderr is shown as plain text, because pip and PyInstaller log progress there.
    param([string]$FilePath, [string[]]$ArgumentList)
    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue)) { throw "Not found: $FilePath" }
    $ErrorActionPreference = 'Continue'   # local to this function
    & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" } | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$FilePath $($ArgumentList -join ' ') exited with code $LASTEXITCODE" }
}

function Get-NativeLines {
    # Runs a program quietly and returns its output lines, or an empty array if it fails.
    param([string]$FilePath, [string[]]$ArgumentList)
    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue)) { return @() }
    $ErrorActionPreference = 'Continue'   # local to this function
    $out = @(& $FilePath @ArgumentList 2>$null)
    if ($LASTEXITCODE -ne 0) { return @() }
    return $out
}

function Get-NativeOutput {
    # Like Get-NativeLines, but returns only the first line (trimmed), or $null.
    param([string]$FilePath, [string[]]$ArgumentList)
    $lines = @(Get-NativeLines $FilePath $ArgumentList)
    if ($lines.Count -eq 0) { return $null }
    return ([string]$lines[0]).Trim()
}
