<#
.SYNOPSIS
    Builds the 32-bit PyInstaller onedir app into dist\ExpoNametag.

.DESCRIPTION
    1. Creates (or reuses) a venv at build\venv32 from Python 3.13 32-bit.
    2. Installs the pinned packages from installer\requirements-build.txt.
    3. Runs PyInstaller on installer\ExpoNametag.spec.
    4. Copies the license texts of everything bundled into dist\ExpoNametag\licenses\.
    5. Copies THIRD-PARTY-NOTICES.txt into the output and checks the result.

    Needs no admin rights. If Python 3.13 32-bit is missing, install it per-user:
        py install 3.13-32
    Exits with code 1 on any failure.

.PARAMETER Clean
    Delete build\venv32, build\pyinstaller and dist\ExpoNametag before building.

.PARAMETER PythonExe
    Python 3.13 32-bit python.exe to create the venv from, instead of looking it up with
    'py' (CI passes the one actions/setup-python installed). It is still checked to be 3.13 32-bit.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File installer\build-app.ps1 -Clean
#>
param(
    [switch]$Clean,
    [string]$PythonExe
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PythonTag  = '3.13-32'
$PythonId   = '3.13-32 32'   # what Get-PythonId prints for Python 3.13, 32-bit
$PipVersion = '26.2.2'
$X86Machine = 0x14C          # PE header machine type for 32-bit x86

$RepoDir     = Split-Path -Parent $PSScriptRoot
$VenvDir     = Join-Path $RepoDir 'build\venv32'
$WorkDir     = Join-Path $RepoDir 'build\pyinstaller'
$DistDir     = Join-Path $RepoDir 'dist'
$AppDir      = Join-Path $DistDir 'ExpoNametag'
$LicensesDir = Join-Path $AppDir 'licenses'
$SpecFile    = Join-Path $PSScriptRoot 'ExpoNametag.spec'
$ReqFile     = Join-Path $PSScriptRoot 'requirements-build.txt'
$Notices     = Join-Path $PSScriptRoot 'THIRD-PARTY-NOTICES.txt'
$VenvPython  = Join-Path $VenvDir 'Scripts\python.exe'
$PyInstaller = Join-Path $VenvDir 'Scripts\pyinstaller.exe'

# Packages whose code ends up in dist\ExpoNametag. The build fails if one of them
# yields no license file. pyinstaller covers the bootloader, pyinstaller-hooks-contrib
# the run-time hooks it embeds.
$LicensedPackages = @('FreeSimpleGUI', 'pywin32', 'requests', 'python-dotenv', 'urllib3', 'idna',
                      'charset-normalizer', 'certifi', 'pyinstaller', 'pyinstaller-hooks-contrib')

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

function Get-NativeOutput {
    # Runs a program quietly and returns its first line of output, or $null if it fails.
    param([string]$FilePath, [string[]]$ArgumentList)
    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue)) { return $null }
    $ErrorActionPreference = 'Continue'   # local to this function
    $out = @(& $FilePath @ArgumentList 2>$null)
    if ($LASTEXITCODE -ne 0 -or $out.Count -eq 0) { return $null }
    return ([string]$out[0]).Trim()
}

function Get-PythonId([string]$Python) {
    # Prints e.g. "3.13-32 32": sys.winver plus pointer size in bits.
    return Get-NativeOutput $Python @('-c', "import struct, sys; print(sys.winver, struct.calcsize('P') * 8)")
}

function Get-BasePython {
    if ($PythonExe) {
        if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) { throw "-PythonExe not found: $PythonExe" }
        $exe = $PythonExe
    } else {
        if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
            throw "The 'py' launcher was not found. Install the Python Install Manager, then run: py install $PythonTag"
        }
        # 'py list' (Python Install Manager) finds an installed runtime without offering
        # to download one. The older py.exe launcher has no 'list', so fall back to -V:.
        $exe = Get-NativeOutput py @('list', '--one', '--format=exe', $PythonTag)
        if (-not $exe) { $exe = Get-NativeOutput py @("-V:$PythonTag", '-c', 'import sys; print(sys.executable)') }
        if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
            throw "Python $PythonTag was not found. Install it per-user (no admin needed) with: py install $PythonTag"
        }
    }
    $id = Get-PythonId $exe
    if ($id -ne $PythonId) { throw "$exe reports '$id', expected '$PythonId' (Python 3.13, 32-bit)." }
    return $exe
}

function Get-PeMachine([string]$Path) {
    # Returns the PE header's machine field: 0x14C = x86, 0x8664 = x64.
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "$Path has no MZ header" }
        $stream.Position = 0x3C
        $stream.Position = $reader.ReadInt32()
        if ($reader.ReadUInt32() -ne 0x4550) { throw "$Path has no PE signature" }
        return [int]$reader.ReadUInt16()
    } finally {
        $stream.Dispose()
    }
}

function Get-NormalizedName([string]$Name) { return ($Name -replace '[-_.]+', '-').ToLowerInvariant() }

function Get-InstalledDists {
    # Maps normalized package name -> its .dist-info folder, name, version and METADATA header lines.
    $dists = @{}
    $sitePackages = Join-Path $VenvDir 'Lib\site-packages'
    foreach ($dir in Get-ChildItem -LiteralPath $sitePackages -Directory -Filter '*.dist-info') {
        $metadata = Join-Path $dir.FullName 'METADATA'
        if (-not (Test-Path -LiteralPath $metadata)) { continue }
        $header = ([System.IO.File]::ReadAllText($metadata) -split '\r?\n\r?\n', 2)[0]
        $lines = @($header -split '\r?\n')
        $name = Get-MetadataField $lines 'Name'
        $dists[(Get-NormalizedName $name)] = [pscustomobject]@{
            Name = $name; Version = (Get-MetadataField $lines 'Version'); Dir = $dir.FullName; Headers = $lines
        }
    }
    return $dists
}

function Get-MetadataField([string[]]$Headers, [string]$Field) {
    # Returns a METADATA header's value. Continuation lines (indented) are joined with
    # newlines and lose the indent the metadata format adds (up to 8 spaces).
    $value = $null
    foreach ($line in $Headers) {
        if ($null -ne $value) {
            if ($line -match '^\s') { $value += "`n" + ($line -replace '^ {1,8}', ''); continue }
            break
        }
        if ($line.StartsWith("${Field}: ")) { $value = $line.Substring($Field.Length + 2) }
    }
    return $value
}

function Copy-LicenseFile([string]$Source, [string]$Name) {
    $target = Join-Path $LicensesDir $Name
    if (Test-Path -LiteralPath $target) { throw "Two license files would both be named $Name" }
    Copy-Item -LiteralPath $Source -Destination $target
    Write-Host "    +   licenses\$Name"
}

function Copy-PackageLicenses($Dist) {
    # Copies every License-File the package declares and returns how many files it wrote.
    $count = 0
    foreach ($line in $Dist.Headers) {
        if (-not $line.StartsWith('License-File: ')) { continue }
        $entry = $line.Substring('License-File: '.Length).Trim()
        # Metadata 2.4+ keeps license files in .dist-info\licenses\; older wheels in .dist-info\.
        $source = $null
        foreach ($candidate in @((Join-Path $Dist.Dir "licenses\$entry"), (Join-Path $Dist.Dir $entry))) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $source = $candidate; break }
        }
        if (-not $source) { throw "$($Dist.Name) declares License-File '$entry', but it is not in $($Dist.Dir)" }
        Copy-LicenseFile $source ('{0}-{1}-{2}' -f $Dist.Name, $Dist.Version, ($entry -replace '[\\/]', '-'))
        $count++
    }
    # A full license text kept only in the License: field (FreeSimpleGUI's LGPL-3.0 text).
    $text = Get-MetadataField $Dist.Headers 'License'
    if ($text -and $text.Contains("`n")) {
        $name = '{0}-{1}-METADATA-License.txt' -f $Dist.Name, $Dist.Version
        [System.IO.File]::WriteAllText((Join-Path $LicensesDir $name), $text + "`n", (New-Object System.Text.UTF8Encoding $false))
        Write-Host "    +   licenses\$name"
        $count++
    }
    return $count
}

try {
    if ($Clean) {
        foreach ($dir in @($VenvDir, $WorkDir, $AppDir)) {
            if (Test-Path -LiteralPath $dir) {
                Write-Step "Removing $dir"
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    }

    # 1. 32-bit venv
    if ((Test-Path -LiteralPath $VenvPython) -and ((Get-PythonId $VenvPython) -eq $PythonId)) {
        Write-Step "Reusing venv $VenvDir"
    } else {
        if (Test-Path -LiteralPath $VenvDir) {
            Write-Step "Replacing unusable venv $VenvDir"
            Remove-Item -LiteralPath $VenvDir -Recurse -Force
        }
        $basePython = Get-BasePython
        Write-Step "Creating venv $VenvDir from $basePython"
        Invoke-Native $basePython @('-m', 'venv', $VenvDir)
    }

    # 2. Pinned packages
    $pipNow = Get-NativeOutput $VenvPython @('-c', 'import pip; print(pip.__version__)')
    if ($pipNow -ne $PipVersion) {
        Write-Step "Installing pip $PipVersion (venv has $pipNow)"
        Invoke-Native $VenvPython @('-m', 'pip', 'install', '--disable-pip-version-check',
            '--require-virtualenv', "pip==$PipVersion")
    }
    Write-Step "Installing $ReqFile"
    Invoke-Native $VenvPython @('-m', 'pip', 'install', '--disable-pip-version-check',
        '--require-virtualenv', '--only-binary=:all:', '-r', $ReqFile)

    # 3. PyInstaller
    Write-Step "Running PyInstaller on $SpecFile"
    Invoke-Native $PyInstaller @('--noconfirm', '--clean', '--distpath', $DistDir,
        '--workpath', $WorkDir, $SpecFile)

    # 4. License texts, named <package>-<version>-<original file name>
    Write-Step "Copying license texts to $LicensesDir"
    if (Test-Path -LiteralPath $LicensesDir) { Remove-Item -LiteralPath $LicensesDir -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $LicensesDir

    $dists = Get-InstalledDists
    foreach ($package in $LicensedPackages) {
        $dist = $dists[(Get-NormalizedName $package)]
        if (-not $dist) { throw "$package is not installed in $VenvDir" }
        if ((Copy-PackageLicenses $dist) -eq 0) { throw "$($dist.Name) $($dist.Version) has no license files" }
    }

    # CPython's LICENSE.txt also holds the texts for the Tcl/Tk, OpenSSL, libffi, bzip2
    # and Microsoft runtime code it ships. Its docs page license.html adds the code built
    # into CPython itself (libmpdec in _decimal.pyd, zlib, ...). Tk's license.terms too.
    $basePrefix = Get-NativeOutput $VenvPython @('-c', 'import sys; print(sys.base_prefix)')
    $pythonVersion = Get-NativeOutput $VenvPython @('-c', 'import platform; print(platform.python_version())')
    foreach ($relative in @('LICENSE.txt', 'Doc\html\license.html')) {
        $source = Join-Path $basePrefix $relative
        if (-not (Test-Path -LiteralPath $source)) { throw "CPython license file not found: $source" }
        Copy-LicenseFile $source "CPython-$pythonVersion-$(Split-Path -Leaf $relative)"
    }

    $tclVersion = Get-NativeOutput $VenvPython @('-c', "import tkinter; print(tkinter.Tcl().eval('info patchlevel'))")
    if (-not $tclVersion) { throw 'Could not read the Tcl version from the venv Python' }
    $tclLibVersion = ($tclVersion -split '\.')[0..1] -join '.'
    foreach ($lib in @('Tcl', 'Tk')) {
        $terms = Join-Path $basePrefix "tcl\$($lib.ToLowerInvariant())$tclLibVersion\license.terms"
        if (Test-Path -LiteralPath $terms) { Copy-LicenseFile $terms "$lib-$tclVersion-license.terms" }
    }

    # LGPL-3.0 (FreeSimpleGUI) must be accompanied by the GPL-3.0 it builds on. No package
    # ships that text, so the repo keeps the canonical copy from gnu.org (674 lines).
    $gplText = Join-Path $PSScriptRoot 'licenses\GPL-3.0.txt'
    if (-not (Test-Path -LiteralPath $gplText)) { throw "GPL-3.0 text not found: $gplText" }
    $gplLines = [System.IO.File]::ReadAllLines($gplText)
    if ($gplLines.Count -ne 674 -or $gplLines[0].Trim() -ne 'GNU GENERAL PUBLIC LICENSE' -or
        $gplLines[1].Trim() -ne 'Version 3, 29 June 2007') {
        throw "$gplText is not the canonical GPL-3.0 text from https://www.gnu.org/licenses/gpl-3.0.txt"
    }
    Copy-LicenseFile $gplText 'GPL-3.0.txt'

    # 5. Notices, then checks
    Write-Step "Copying $Notices"
    Copy-Item -LiteralPath $Notices -Destination $AppDir -Force

    Write-Step "Checking $AppDir"
    $problems = New-Object System.Collections.Generic.List[string]

    foreach ($name in @('ExpoNametag.exe')) {
        $exe = Join-Path $AppDir $name
        if (-not (Test-Path -LiteralPath $exe)) { $problems.Add("Missing $exe"); continue }
        $machine = Get-PeMachine $exe
        if ($machine -eq $X86Machine) {
            Write-Host "    OK  $name is 32-bit x86 (PE machine 0x14C)"
        } else {
            $problems.Add(('{0} is not 32-bit x86 (PE machine 0x{1:X})' -f $exe, $machine))
        }
    }

    $requiredFiles = @(
        '_internal\src\label\student_badge_v3.label',
        '_internal\FreeSimpleGUI\__init__.py',   # LGPL: shipped as replaceable source
        'THIRD-PARTY-NOTICES.txt'
    )
    foreach ($relative in $requiredFiles) {
        if (Test-Path -LiteralPath (Join-Path $AppDir $relative)) {
            Write-Host "    OK  $relative"
        } else {
            $problems.Add("Missing $(Join-Path $AppDir $relative)")
        }
    }

    # Every licenses\ file the notices name must exist (catches a version bump the notices missed).
    $noticesText = [System.IO.File]::ReadAllText($Notices)
    $named = @([regex]::Matches($noticesText, 'licenses\\[A-Za-z0-9._*-]+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    $missing = @($named | Where-Object { -not (Test-Path -Path (Join-Path $AppDir $_)) })
    foreach ($relative in $missing) { $problems.Add("THIRD-PARTY-NOTICES.txt names $relative, which is not in the build") }
    if ($missing.Count -eq 0) {
        $licenseCount = @(Get-ChildItem -LiteralPath $LicensesDir -File).Count
        Write-Host "    OK  licenses\ has $licenseCount files; all $($named.Count) named in the notices exist"
    }

    $secrets = @(Get-ChildItem -LiteralPath $AppDir -Recurse -Force | Where-Object { $_.Name -like '*.env' })
    if ($secrets.Count -eq 0) {
        Write-Host '    OK  no .env or *.env files'
    } else {
        foreach ($item in $secrets) { $problems.Add("Secret file in build output: $($item.FullName)") }
    }

    if ($problems.Count -gt 0) {
        throw ("Build output check failed:`n  " + ($problems -join "`n  "))
    }

    $bytes = (Get-ChildItem -LiteralPath $AppDir -Recurse -Force -File | Measure-Object -Property Length -Sum).Sum
    Write-Step ('Build OK: {0} ({1:N1} MB)' -f $AppDir, ($bytes / 1MB))
    exit 0
} catch {
    Write-Host "BUILD FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
