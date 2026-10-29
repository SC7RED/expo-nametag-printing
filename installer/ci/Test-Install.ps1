<#
.SYNOPSIS
    CI checks: silently installs and uninstalls the app, and checks what's there afterwards.
    Used by .github\workflows\installer.yml. It installs software, so it refuses to run outside
    CI unless you pass -IKnowThisInstallsSoftware.

    -Mode Msi         msiexec /i /qn with no settings file: app, label and both shortcuts are
                      installed, and there's no .env. Then msiexec /x removes it all.
    -Mode MsiWithEnv  The same, with ENVSOURCEDIR set to a folder holding a dummy ExpoNametag.env:
                      it's copied into the install folder as .env and removed on uninstall.
    -Mode Bundle      ExpoNametagSetup.exe /quiet with a dummy ExpoNametag.env next to it (this
                      downloads and installs DYMO Label Software 8.7.4), then /uninstall. Also
                      checks that it refuses to install without the settings file (exit code 2).
#>
param(
    [Parameter(Mandatory)][ValidateSet('Msi', 'MsiWithEnv', 'Bundle')][string]$Mode,
    [string]$LogDir = (Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }) 'install-logs'),
    [switch]$IKnowThisInstallsSoftware
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:CI -ne 'true' -and -not $IKnowThisInstallsSoftware) {
    throw 'This installs software. It is meant for CI; pass -IKnowThisInstallsSoftware to run it anyway.'
}
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this as administrator.'
}

$RepoDir    = Split-Path (Split-Path $PSScriptRoot)
$MsiPath    = Join-Path $RepoDir 'dist\ExpoNametag.msi'
$BundlePath = Join-Path $RepoDir 'dist\ExpoNametagSetup.exe'
$InstallDir = Join-Path ${env:ProgramFiles(x86)} 'Expo Nametag Printing'
$Shortcuts  = @(
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Expo Nametag Printing.lnk'),
    (Join-Path $env:PUBLIC 'Desktop\Expo Nametag Printing.lnk')
)
$Msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$script:LastLog = $null

# Prints PASS, or prints FAIL plus the end of the last installer log and stops.
function Assert-That($Condition, [string]$Name) {
    if ($Condition) { Write-Host "PASS  $Name"; return }
    Write-Host "FAIL  $Name" -ForegroundColor Red
    if ($script:LastLog -and (Test-Path -LiteralPath $script:LastLog)) {
        Write-Host "--- last 40 lines of $script:LastLog ---"
        Get-Content -LiteralPath $script:LastLog -Tail 40
    }
    exit 1
}

# Runs an installer, waits up to 25 minutes and returns its exit code.
function Invoke-Installer([string]$FilePath, [string]$Arguments, [string]$Log) {
    $script:LastLog = $Log
    Write-Host "> $FilePath $Arguments"
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru
    $null = $process.Handle   # Windows PowerShell 5.1 loses ExitCode without this
    if (-not $process.WaitForExit(25 * 60 * 1000)) {
        $process.Kill()
        Assert-That $false "$(Split-Path $FilePath -Leaf) finished within 25 minutes"
    }
    return $process.ExitCode
}

# Writes a dummy ExpoNametag.env (never real values: this runs in public CI) and returns its text.
function New-DummySettings([string]$Folder) {
    $text = "PROXY_URL=`"https://example.invalid`"`r`n" +
            "PROXY_TOKEN=`"ci-dummy-$([guid]::NewGuid())`"`r`n" +
            "SWAPCARD_YEAR_ID=`"ci-year`"`r`n" +
            "SWAPCARD_MAJOR_ID=`"ci-major`"`r`n"
    New-Item -ItemType Directory -Force -Path $Folder | Out-Null
    [IO.File]::WriteAllText((Join-Path $Folder 'ExpoNametag.env'), $text)
    return $text
}

function Assert-Installed([string]$ExpectedSettings) {
    Assert-That (Test-Path -LiteralPath (Join-Path $InstallDir 'ExpoNametag.exe')) 'ExpoNametag.exe installed'
    Assert-That (Test-Path -LiteralPath (Join-Path $InstallDir '_internal\src\label\student_badge_v3.label')) 'label file installed'
    foreach ($shortcut in $Shortcuts) { Assert-That (Test-Path -LiteralPath $shortcut) "shortcut exists: $shortcut" }

    $envFile = Join-Path $InstallDir '.env'
    if ($ExpectedSettings) {
        Assert-That ((Test-Path -LiteralPath $envFile) -and ([IO.File]::ReadAllText($envFile) -ceq $ExpectedSettings)) `
            'ExpoNametag.env copied into the install folder as .env'
    } else {
        Assert-That (-not (Test-Path -LiteralPath $envFile)) 'no .env (no settings file given)'
    }
}

function Assert-Removed {
    Assert-That (-not (Test-Path -LiteralPath $InstallDir)) 'install folder removed'
    foreach ($shortcut in $Shortcuts) { Assert-That (-not (Test-Path -LiteralPath $shortcut)) "shortcut removed: $shortcut" }
}

# For information only: what DYMO and its prerequisites left in Settings > Apps.
function Show-DymoEntries([string]$When) {
    Write-Host "Apps entries $When matching DYMO, Bonjour or Visual C++ 2010/2013:"
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match 'DYMO|Bonjour|Visual C\+\+ 201[03]' } |
        ForEach-Object { Write-Host "  $($_.DisplayName)" }
}

function Test-Msi([string]$SettingsFolder) {
    $expected = $null
    $property = ''
    if ($SettingsFolder) {
        $expected = New-DummySettings $SettingsFolder
        # Unquoted, with a trailing backslash, like the bundle passes it (a quoted "...\" would
        # escape the closing quote). So the folder path must not contain spaces.
        Assert-That ($SettingsFolder -notmatch ' ') "settings folder has no spaces: $SettingsFolder"
        $property = " ENVSOURCEDIR=$SettingsFolder\"
    }

    $log = Join-Path $LogDir "$Mode-install.log"
    $code = Invoke-Installer $Msiexec "/i `"$MsiPath`" /qn /l*v `"$log`"$property" $log
    Assert-That ($code -eq 0) "msiexec /i exit code 0 (got $code)"
    Assert-Installed $expected

    $log = Join-Path $LogDir "$Mode-uninstall.log"
    $code = Invoke-Installer $Msiexec "/x `"$MsiPath`" /qn /l*v `"$log`"" $log
    Assert-That ($code -eq 0) "msiexec /x exit code 0 (got $code)"
    Assert-Removed
}

function Test-Bundle {
    # The DYMO driver install needs the Print Spooler, which hosted runners may have stopped.
    $spooler = Get-Service -Name Spooler
    if ($spooler.StartType -eq 'Disabled') { Set-Service -Name Spooler -StartupType Manual }
    if ($spooler.Status -ne 'Running') { Start-Service -Name Spooler }

    $folder = Join-Path $env:TEMP "expo-bundle-$(Get-Random)"
    $expected = New-DummySettings $folder
    Copy-Item -LiteralPath $BundlePath -Destination $folder
    $setup = Join-Path $folder 'ExpoNametagSetup.exe'

    $log = Join-Path $LogDir 'Bundle-install.log'
    $code = Invoke-Installer $setup "/quiet /norestart /log `"$log`"" $log
    Assert-That ($code -in 0, 3010) "bundle install exit code 0 or 3010 (got $code)"
    Assert-Installed $expected
    Show-DymoEntries 'after install'
    $dymoClsid = 'Registry::HKEY_CLASSES_ROOT\Dymo.DymoAddIn\CLSID'
    Assert-That (Test-Path -LiteralPath $dymoClsid) 'DYMO Label Software installed (Dymo.DymoAddIn registered)'

    $log = Join-Path $LogDir 'Bundle-uninstall.log'
    $code = Invoke-Installer $setup "/uninstall /quiet /norestart /log `"$log`"" $log
    Assert-That ($code -in 0, 3010) "bundle uninstall exit code 0 or 3010 (got $code)"
    Assert-Removed
    Show-DymoEntries 'after uninstall'

    # A first install without ExpoNametag.env next to the exe must refuse (exit code 2).
    Remove-Item -LiteralPath (Join-Path $folder 'ExpoNametag.env')
    $log = Join-Path $LogDir 'Bundle-nosettings.log'
    $code = Invoke-Installer $setup "/quiet /norestart /log `"$log`"" $log
    Assert-That ($code -eq 2) "bundle without ExpoNametag.env exits with 2 (got $code)"
    Assert-That (-not (Test-Path -LiteralPath $InstallDir)) 'nothing installed without the settings file'
}

Assert-That (-not (Test-Path -LiteralPath $InstallDir)) 'app not installed before the test'
switch ($Mode) {
    'Msi'        { Assert-That (Test-Path -LiteralPath $MsiPath) "found $MsiPath"; Test-Msi $null }
    'MsiWithEnv' { Assert-That (Test-Path -LiteralPath $MsiPath) "found $MsiPath"; Test-Msi (Join-Path $env:TEMP "expo-settings-$(Get-Random)") }
    'Bundle'     { Assert-That (Test-Path -LiteralPath $BundlePath) "found $BundlePath"; Test-Bundle }
}
Write-Host "All $Mode checks passed."
