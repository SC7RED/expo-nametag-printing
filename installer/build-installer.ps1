<#
.SYNOPSIS
    Builds the app MSI and the silent Burn bundle from the PyInstaller output.

.DESCRIPTION
    1. Makes sure the 'wix' dotnet global tool is WiX 5.0.2 (MS-RL, no EULA) and that
       WixToolset.Util.wixext 5.0.2 is in the per-user extension cache.
    2. Builds the silent bootstrapper application (installer\wix\SilentBA).
    3. Builds and validates $OutDir\ExpoNametag.msi from $AppDir.
    4. Builds $OutDir\ExpoNametagSetup.exe, which chains DYMO Label Software 8.7.4 and the MSI.

    The bundle is not called Setup.exe: WiX refuses that exact name (error WIX0388) because
    Windows applies compatibility shims to it that can load planted DLLs from its folder.

    Needs no admin rights and installs nothing on this machine except per-user dotnet/WiX tools.
    Intermediate files go to build\wix. Exits with code 1 on any failure.

.PARAMETER AppDir
    PyInstaller onedir output. Default: dist\ExpoNametag

.PARAMETER Version
    Version for the MSI and the bundle (major.minor.build). Default: 1.0.0

.PARAMETER OutDir
    Where ExpoNametag.msi and ExpoNametagSetup.exe are written. Default: dist

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File installer\build-installer.ps1 -Version 1.0.1
#>
param(
    [string]$AppDir,
    [string]$Version = '1.0.0',
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$WixVersion    = '5.0.2'
$WixExtensions = @('WixToolset.Util.wixext')
$MsiName       = 'ExpoNametag.msi'
$BundleName    = 'ExpoNametagSetup.exe'

$RepoDir    = Split-Path -Parent $PSScriptRoot
$WixSrcDir  = Join-Path $PSScriptRoot 'wix'
$NuGetConfig = Join-Path $WixSrcDir 'nuget.config'
$BAProject  = Join-Path $WixSrcDir 'SilentBA\SilentBA.csproj'
$IntDir     = Join-Path $RepoDir 'build\wix'
$Wix        = Join-Path $env:USERPROFILE '.dotnet\tools\wix.exe'
if (-not $AppDir) { $AppDir = Join-Path $RepoDir 'dist\ExpoNametag' }
if (-not $OutDir) { $OutDir = Join-Path $RepoDir 'dist' }

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

function Invoke-Native {
    # Runs a program, shows its output, and throws if it exits nonzero.
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

try {
    # 0. Inputs
    $AppDir = (Resolve-Path -LiteralPath $AppDir).Path
    foreach ($name in @('ExpoNametag.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $AppDir $name))) { throw "Missing $(Join-Path $AppDir $name)" }
    }
    # The MSI harvests everything in $AppDir, so refuse to package anything that looks like a secret.
    $secrets = @(Get-ChildItem -LiteralPath $AppDir -Recurse -Force -File |
        Where-Object { $_.Name -like '*.env' -or $_.Name -like '.env*' })
    if ($secrets.Count -gt 0) {
        throw ("Secret files in ${AppDir}:`n  " + (($secrets | ForEach-Object { $_.FullName }) -join "`n  "))
    }
    New-Item -ItemType Directory -Force -Path $OutDir, $IntDir | Out-Null
    $OutDir = (Resolve-Path -LiteralPath $OutDir).Path

    # 1. WiX tool and extensions (per user)
    $toolLine = Get-NativeLines dotnet @('tool', 'list', '--global') | Where-Object { $_ -match '^wix\s' }
    $toolVersion = if ($toolLine) { ($toolLine -split '\s+')[1] } else { $null }
    if ($toolVersion -ne $WixVersion) {
        if ($toolVersion) {
            Write-Step "Replacing wix $toolVersion with $WixVersion (dotnet global tool)"
            Invoke-Native dotnet @('tool', 'uninstall', '--global', 'wix')
        } else {
            Write-Step "Installing wix $WixVersion (dotnet global tool)"
        }
        Invoke-Native dotnet @('tool', 'install', '--global', 'wix', '--version', $WixVersion, '--configfile', $NuGetConfig)
    }
    $wixReported = (Get-NativeLines $Wix @('--version') | Select-Object -First 1)
    if (-not $wixReported -or -not "$wixReported".StartsWith("$WixVersion+")) {
        throw "$Wix reports '$wixReported', expected $WixVersion"
    }
    Write-Step "Using WiX $wixReported"

    $cached = Get-NativeLines $Wix @('extension', 'list', '--global')
    Push-Location $WixSrcDir   # so NuGet picks up installer\wix\nuget.config
    try {
        foreach ($ext in $WixExtensions) {
            if ($cached -match "^$([regex]::Escape($ext))\s+$([regex]::Escape($WixVersion))\s*$") { continue }
            Write-Step "Adding $ext/$WixVersion to the WiX extension cache"
            Invoke-Native $Wix @('extension', 'add', '--global', "$ext/$WixVersion")
        }
    } finally {
        Pop-Location
    }

    # 2. Silent bootstrapper application
    $BADir = Join-Path $IntDir 'SilentBA\out'
    Write-Step "Building $BAProject"
    Invoke-Native dotnet @('build', $BAProject, '--configuration', 'Release', '--output', $BADir, '--nologo')

    # 3. App MSI
    $msi = Join-Path $OutDir $MsiName
    $msiPdb = Join-Path $IntDir 'msi\ExpoNametag.wixpdb'
    Write-Step "Building $msi from $AppDir"
    Invoke-Native $Wix @('build', (Join-Path $WixSrcDir 'Package.wxs'), '-arch', 'x86',
        '-d', "AppDir=$AppDir", '-d', "Version=$Version",
        '-intermediatefolder', (Join-Path $IntDir 'msi'), '-pdb', $msiPdb, '-o', $msi)

    # ICE43/ICE57 are false positives for non-advertised shortcuts in a per-machine package, and ICE61
    # is expected with AllowSameVersionUpgrades (see Package.wxs).
    Write-Step "Validating $msi"
    Invoke-Native $Wix @('msi', 'validate', '-sice', 'ICE43', '-sice', 'ICE57', '-sice', 'ICE61', '-pdb', $msiPdb,
        '-intermediateFolder', (Join-Path $IntDir 'validate'), $msi)

    # 4. Bundle
    $bundle = Join-Path $OutDir $BundleName
    Write-Step "Building $bundle"
    $extArgs = @($WixExtensions | ForEach-Object { '-ext'; "$_/$WixVersion" })
    Invoke-Native $Wix (@('build', (Join-Path $WixSrcDir 'Bundle.wxs')) + $extArgs + @(
        '-d', "BADir=$BADir", '-d', "MsiPath=$msi", '-d', "Version=$Version",
        '-intermediatefolder', (Join-Path $IntDir 'bundle'),
        '-pdb', (Join-Path $IntDir 'bundle\ExpoNametagSetup.wixpdb'), '-o', $bundle))

    foreach ($file in @($msi, $bundle)) {
        Write-Host ('    {0} ({1:N1} MB)' -f $file, ((Get-Item -LiteralPath $file).Length / 1MB))
    }
    Write-Step 'Build OK'
    exit 0
} catch {
    Write-Host "BUILD FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
