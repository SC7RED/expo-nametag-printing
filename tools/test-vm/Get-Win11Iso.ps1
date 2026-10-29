<#
.SYNOPSIS
    Downloads the official Windows 11 x64 ISO (multi-edition) from Microsoft, using Fido.

.DESCRIPTION
    Fido (https://github.com/pbatard/Fido) asks Microsoft's own download API for a
    time-limited ISO link. This script:
      1. downloads Fido.ps1 from a pinned release tag into its own folder
         (<StateDir>\fido-<tag>\) and checks its SHA-256,
      2. runs it with -GetUrl to get the link,
      3. downloads the ISO with curl.exe (resumable; rerun to resume),
      4. prints the ISO's SHA-256 and, with -ExpectedSha256, fails on a mismatch.
    If the ISO already exists and matches -ExpectedSha256 (or the hash recorded after
    the last complete download), the download is skipped. No admin rights needed.

    Use -Ed List or -Lang List to print the exact names Fido accepts.
    Fido's "English" is English (United States).

.EXAMPLE
    .\Get-Win11Iso.ps1

.EXAMPLE
    .\Get-Win11Iso.ps1 -Lang List
#>
[CmdletBinding()]
param(
    # Holds iso\ and fido-<tag>\.
    [string]$StateDir = (Join-Path $env:USERPROFILE 'VMs'),
    # Fido edition name. 'List' shows the choices.
    [string]$Ed = 'Windows 11 Home/Pro/Edu',
    # Fido language name. 'List' shows the choices. 'English' = English (United States).
    [string]$Lang = 'English',
    [string]$FidoTag = 'v1.71',
    # SHA-256 of Fido.ps1 at $FidoTag as served by raw.githubusercontent.com.
    # Pass the new hash when you change -FidoTag, or '' to skip the check.
    [string]$FidoSha256 = '6481E40D3CF100C79B281942D0D1C7F6D111397BE296FEC867A56CBE368EBDF9',
    # Defaults to <StateDir>\iso\Win11_x64.iso.
    [string]$OutFile,
    # Optional: fail unless the ISO has this SHA-256.
    [string]$ExpectedSha256
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $OutFile) { $OutFile = Join-Path $StateDir 'iso\Win11_x64.iso' }
$hashFile = "$OutFile.sha256"   # written only after a complete, verified download
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path -LiteralPath $curl)) { throw "curl.exe not found at $curl." }
if ($ExpectedSha256) { $ExpectedSha256 = $ExpectedSha256.Trim().ToUpperInvariant() }
$listMode = ($Ed -eq 'List') -or ($Lang -eq 'List')

function Get-Sha256([string]$Path) {
    Write-Host "Computing SHA-256 of $Path ..."
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# Runs a native program without letting its stderr (e.g. curl's progress meter)
# become a terminating error under $ErrorActionPreference = 'Stop'.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments
}

# --- 1. Skip if a complete ISO is already here --------------------------------------
if (-not $listMode -and (Test-Path -LiteralPath $OutFile)) {
    $recorded = $null
    if (Test-Path -LiteralPath $hashFile) {
        $recorded = ((Get-Content -LiteralPath $hashFile -TotalCount 1) -split '\s+')[0].ToUpperInvariant()
    }
    $want = if ($ExpectedSha256) { $ExpectedSha256 } else { $recorded }
    if ($want) {
        $hash = Get-Sha256 $OutFile
        if ($hash -eq $want) {
            Write-Host "ISO already downloaded and its hash matches; skipping the download."
            Write-Host "File:    $OutFile"
            Write-Host ("Size:    {0:N0} bytes" -f (Get-Item -LiteralPath $OutFile).Length)
            Write-Host "SHA-256: $hash"
            return
        }
        if (-not $ExpectedSha256) {
            throw "$OutFile no longer matches the hash recorded after its download ($recorded). Delete it and $hashFile, then rerun."
        }
        Write-Host "Existing file does not match -ExpectedSha256; treating it as a partial download and resuming."
    }
}

# --- 2. Get Fido at the pinned tag into its own folder ------------------------------
$fidoDir = Join-Path $StateDir "fido-$FidoTag"
$fido = Join-Path $fidoDir 'Fido.ps1'
if (Test-Path -LiteralPath $fidoDir) {
    $other = @(Get-ChildItem -LiteralPath $fidoDir -Force | Where-Object { $_.Name -ne 'Fido.ps1' })
    if ($other.Count -gt 0) {
        throw "$fidoDir should contain only Fido.ps1 but also has: $(($other | ForEach-Object Name) -join ', ')."
    }
} else {
    New-Item -ItemType Directory -Path $fidoDir | Out-Null
}
$fidoOk = (Test-Path -LiteralPath $fido) -and
          ((-not $FidoSha256) -or ((Get-FileHash -LiteralPath $fido -Algorithm SHA256).Hash -eq $FidoSha256))
if (-not $fidoOk) {
    $fidoUrl = "https://raw.githubusercontent.com/pbatard/Fido/refs/tags/$FidoTag/Fido.ps1"
    Write-Host "Downloading $fidoUrl"
    Invoke-Native $curl @('-L', '--fail', '-sS', '--retry', '3', '-o', $fido, $fidoUrl)
    if ($LASTEXITCODE -ne 0) { throw "Downloading Fido.ps1 failed (curl exit code $LASTEXITCODE)." }
}
$fidoHash = (Get-FileHash -LiteralPath $fido -Algorithm SHA256).Hash
if ($FidoSha256 -and $fidoHash -ne $FidoSha256) {
    Remove-Item -LiteralPath $fido
    throw "Fido.ps1 SHA-256 is $fidoHash, expected $FidoSha256. Deleted it. Review the new version before updating -FidoSha256."
}
if (-not $FidoSha256) { Write-Warning "Fido.ps1 hash not checked (SHA-256 $fidoHash)." }

# --- 3. Ask Fido for the download link -------------------------------------------------
# Run it in a child process: Fido is not StrictMode-safe and calls 'exit'.
# Names are anchored so 'English' does not also match 'English (United Kingdom)'.
$edArg = if ($Ed -eq 'List') { 'List' } else { '^' + [regex]::Escape($Ed) + '$' }
$langArg = if ($Lang -eq 'List') { 'List' } else { '^' + $Lang + '$' }   # Fido escapes ( ) itself
$fidoArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fido,
              '-Win', '11', '-Rel', 'Latest', '-Ed', $edArg, '-Lang', $langArg,
              '-Arch', 'x64', '-PlatformArch', 'x64')
if (-not $listMode) { $fidoArgs += '-GetUrl' }
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

Push-Location $fidoDir   # Fido writes nothing in -GetUrl/List mode, but keep it in its folder
try {
    if ($listMode) {
        Invoke-Native $powershell $fidoArgs
        return
    }
    Write-Host "Asking Microsoft for a Windows 11 x64 ISO link ($Ed, $Lang) ..."
    $fidoOut = @(Invoke-Native $powershell $fidoArgs)
    $fidoExit = $LASTEXITCODE
} finally {
    Pop-Location
}
$url = $fidoOut | Where-Object { "$_" -match '^https://' } | Select-Object -Last 1
if ($fidoExit -ne 0 -or -not $url) {
    $fidoOut | ForEach-Object { Write-Host "  Fido: $_" }
    throw ("Fido did not return a download link (exit code $fidoExit); its output is above. " +
           "If it mentions a ban or message code 715-123130, Microsoft refused the scripted request " +
           "(common on VPNs). Try again later off the VPN, or download the ISO in a browser from " +
           "https://www.microsoft.com/software-download/windows11 and save it as $OutFile.")
}
$url = "$url".Trim()
Write-Host "Got a link for $(([uri]$url).Segments[-1]) (valid for about 24 hours)."

# --- 4. Download (resumable) and verify ---------------------------------------------
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
Invoke-Native $curl @('-L', '--fail', '--retry', '3', '-C', '-', '-o', $OutFile, $url)
if ($LASTEXITCODE -ne 0) { throw "ISO download failed (curl exit code $LASTEXITCODE). Rerun to resume." }

$hash = Get-Sha256 $OutFile
if ($ExpectedSha256 -and $hash -ne $ExpectedSha256) {
    throw "SHA-256 mismatch for ${OutFile}: got $hash, expected $ExpectedSha256. Delete the file and rerun if it is corrupt."
}
Set-Content -LiteralPath $hashFile -Value "$hash  $(Split-Path -Leaf $OutFile)" -Encoding Ascii
Write-Host ''
Write-Host "File:    $OutFile"
Write-Host ("Size:    {0:N0} bytes" -f (Get-Item -LiteralPath $OutFile).Length)
Write-Host "SHA-256: $hash"
if (-not $ExpectedSha256) {
    Write-Host 'Compare it with the SHA-256 list on https://www.microsoft.com/software-download/windows11 (shown after you pick a language).'
}
