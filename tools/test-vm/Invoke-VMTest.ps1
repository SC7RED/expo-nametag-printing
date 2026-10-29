<#
.SYNOPSIS
    One install test in the Windows 11 test VM. It restores the "clean" snapshot, starts the VM,
    copies ExpoNametagSetup.exe and ExpoNametag.env into C:\Users\Public\Downloads, runs the
    installer silently and checks the result. -Uninstall then uninstalls and checks that
    everything is gone. Installer logs are copied to dist\vm-logs\<time>\.

    The VM is left running afterwards so you can look around (or print a test badge).

.EXAMPLE
    .\Invoke-VMTest.ps1 -Uninstall          # install, check, uninstall, check
.EXAMPLE
    .\Invoke-VMTest.ps1 -AttachPrinter      # install, and pass the USB DYMO printer through to the VM
.EXAMPLE
    .\Invoke-VMTest.ps1 -CopyOnly           # just copy the files in; then double-click the setup yourself
                                            # in the VM to see what a student sees (only UAC should appear)
.EXAMPLE
    .\Invoke-VMTest.ps1 -NoSettings         # without ExpoNametag.env the installer must refuse (exit code 2)
#>
[CmdletBinding()]
param(
    [string]$VMName = 'Win11Home-Expo',
    [string]$StateDir = (Join-Path $env:USERPROFILE 'VMs'),
    # Defaults to dist\ExpoNametag.env. Must be named ExpoNametag.env, like on the laptops.
    [string]$SettingsFile,
    [switch]$NoSettings,
    [switch]$Uninstall,
    [switch]$CopyOnly,
    [switch]$AttachPrinter,
    # Test DYMO's real download instead of copying the saved installer in.
    [switch]$ForceDymoDownload,
    [switch]$Headless
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'VBoxCommon.ps1')

$repo       = Split-Path (Split-Path $PSScriptRoot)
$setup      = Join-Path $repo 'dist\ExpoNametagSetup.exe'
$dymo       = Join-Path $StateDir 'dymo\DLS8Setup8.7.4.exe'
$dymoSha256 = '409D79F053BA0C803CE83B71E8245992CD63708FA27017F48A5063826F1BEA4D'
$guestDir   = 'C:\Users\Public\Downloads'
$logDir     = Join-Path $repo ('dist\vm-logs\{0:yyyyMMdd-HHmmss}' -f (Get-Date))
if (-not $SettingsFile) { $SettingsFile = Join-Path $repo 'dist\ExpoNametag.env' }

# --- What goes into the guest -------------------------------------------------------------
$files = @($setup)
if (-not $NoSettings) {
    if ((Split-Path -Leaf $SettingsFile) -ne 'ExpoNametag.env') { throw '-SettingsFile must be named ExpoNametag.env.' }
    $files += $SettingsFile
}
if (-not $ForceDymoDownload -and (Test-Path -LiteralPath $dymo)) {
    if ((Get-FileHash -LiteralPath $dymo -Algorithm SHA256).Hash -ne $dymoSha256) { throw "$dymo has the wrong SHA-256." }
    $files += $dymo   # the bundle uses it instead of downloading 171 MB
}
foreach ($f in $files) { if (-not (Test-Path -LiteralPath $f)) { throw "Missing $f" } }

# Runs the setup exe in the guest as Administrator and returns its exit code.
function Invoke-SetupInGuest([string]$Arguments) {
    $script = "`$p = Start-Process -FilePath '$guestDir\ExpoNametagSetup.exe' -ArgumentList '$Arguments' -Wait -PassThru; 'EXITCODE=' + `$p.ExitCode"
    $out = Invoke-GuestPowerShell -VM $VMName -PasswordFile $pw -Script $script -TimeoutSeconds 1800
    $line = @($out | Where-Object { $_ -match '^EXITCODE=-?\d+$' }) | Select-Object -Last 1
    if (-not $line) { throw "Couldn't read the setup exit code. Output:`n$($out -join "`n")" }
    return [int]($line -replace '^EXITCODE=', '')
}

# Runs checks inside the guest; each prints a "PASS  ..." or "FAIL  ..." line, other lines are info.
function Invoke-GuestChecks([string]$Checks) {
    $prelude = @'
$dir = 'C:\Program Files (x86)\Expo Nametag Printing'
$shortcuts = 'C:\Users\Public\Desktop\Expo Nametag Printing.lnk',
             'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Expo Nametag Printing.lnk'
function Check($ok, $name) { if ($ok) { "PASS  $name" } else { "FAIL  $name" } }
function Get-AppsEntries {
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and
                       $_.DisplayName -match 'Expo Nametag|DYMO|Bonjour|Visual C\+\+ 201[03]|Tools for Office' } |
        ForEach-Object { "  $($_.DisplayName)" }
}
$dymoCom = Test-Path 'Registry::HKEY_CLASSES_ROOT\Dymo.DymoAddIn\CLSID'
'@
    $out = Invoke-GuestPowerShell -VM $VMName -PasswordFile $pw -Script ($prelude + "`n" + $Checks)
    $out | ForEach-Object { Write-Host $_ }
    $script:failures += @($out | Where-Object { $_ -like 'FAIL*' }).Count
}

# Right after a power-off, VirtualBox can keep the VM locked for a few seconds, so this retries.
function Invoke-VBoxWhenUnlocked([string[]]$Arguments) {
    foreach ($try in 1..10) {
        Invoke-VBox -Arguments $Arguments -AllowFailure | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 3
    }
    throw "VBoxManage $($Arguments -join ' ') kept failing."
}

function Copy-GuestLogs([string]$Into) {
    New-Item -ItemType Directory -Force -Path $Into | Out-Null
    $logs = Invoke-GuestPowerShell -VM $VMName -PasswordFile $pw -Script "Get-ChildItem '$guestDir' -Filter *.log | ForEach-Object FullName"
    foreach ($log in @($logs | Where-Object { $_ -like '*.log' })) {
        Invoke-VBox -Arguments @('guestcontrol', $VMName, 'copyfrom', '--username=Administrator', "--passwordfile=$pw",
                                 "--target-directory=$Into\", $log) | Out-Null
    }
    Write-Host "Logs copied to $Into"
}

$secrets = Read-VMSecrets (Join-Path $StateDir "$VMName.secrets.json")
$pw = New-SecretFile $secrets.AdminPassword
$script:failures = 0
try {
    Write-Host '== Restoring the "clean" snapshot'
    if ((Get-VMState $VMName) -notin 'poweroff', 'aborted', 'saved') {
        Invoke-VBox -Arguments @('controlvm', $VMName, 'poweroff') -AllowFailure | Out-Null
        [void](Wait-VMState $VMName @('poweroff', 'aborted') 2)
    }
    Invoke-VBoxWhenUnlocked @('snapshot', $VMName, 'restore', 'clean')
    if ($AttachPrinter) {
        # DYMO's USB vendor ID is 0922. While the VM runs, the printer belongs to the VM, not this PC.
        Invoke-VBoxWhenUnlocked @('usbfilter', 'add', '0', '--target', $VMName, '--name', 'DYMO', '--vendorid', '0922')
    }
    Invoke-VBoxWhenUnlocked @('startvm', $VMName, '--type', $(if ($Headless) { 'headless' } else { 'gui' }))
    Wait-GuestReady -VM $VMName -PasswordFile $pw | Out-Null

    Write-Host "== Copying $($files.Count) file(s) to $guestDir"
    # The trailing \ tells VirtualBox 7.2 the target is a folder.
    Invoke-VBox -Arguments (@('guestcontrol', $VMName, 'copyto', '--username=Administrator', "--passwordfile=$pw",
                              "--target-directory=$guestDir\") + $files) | Out-Null
    if ($CopyOnly) {
        Write-Host "Done. In the VM, open $guestDir and double-click ExpoNametagSetup.exe." -ForegroundColor Yellow
        return
    }

    Write-Host '== Installing (silent)'
    $code = Invoke-SetupInGuest "/quiet /norestart /log $guestDir\install.log"
    Write-Host "Exit code: $code"
    if ($NoSettings) {
        if ($code -ne 2) { Write-Host "FAIL  expected exit code 2 without ExpoNametag.env"; $script:failures++ } else { Write-Host 'PASS  exit code 2 without ExpoNametag.env' }
        Invoke-GuestChecks "Check (-not (Test-Path `$dir)) 'nothing installed'"
    } else {
        if ($code -notin 0, 3010) { Write-Host 'FAIL  install exit code 0 or 3010'; $script:failures++ } else { Write-Host 'PASS  install exit code' }
        $hash = (Get-FileHash -LiteralPath $SettingsFile -Algorithm SHA256).Hash
        Invoke-GuestChecks @"
Check (Test-Path "`$dir\ExpoNametag.exe") 'ExpoNametag.exe installed'
Check ((Test-Path "`$dir\.env") -and (Get-FileHash "`$dir\.env").Hash -eq '$hash') 'ExpoNametag.env copied in as .env'
foreach (`$s in `$shortcuts) { Check (Test-Path `$s) "shortcut `$s" }
Check (-not (Get-Process 'DLS8Setup*' -ErrorAction SilentlyContinue)) 'DYMO setup finished (not still running in the background)'
Check `$dymoCom 'DYMO COM object (Dymo.DymoAddIn) registered'
'DYMO drivers:'; pnputil /enum-drivers | Select-String -Context 0,6 'dymo' | ForEach-Object { `$_.ToString() }
'Apps entries:'; Get-AppsEntries
"@
    }
    Copy-GuestLogs (Join-Path $logDir 'install')

    if ($Uninstall -and -not $NoSettings) {
        Write-Host '== Uninstalling (silent)'
        $code = Invoke-SetupInGuest "/uninstall /quiet /norestart /log $guestDir\uninstall.log"
        Write-Host "Exit code: $code"
        if ($code -notin 0, 3010) { Write-Host 'FAIL  uninstall exit code 0 or 3010'; $script:failures++ } else { Write-Host 'PASS  uninstall exit code' }
        Invoke-GuestChecks @"
Check (-not (Test-Path `$dir)) 'install folder removed'
foreach (`$s in `$shortcuts) { Check (-not (Test-Path `$s)) "shortcut removed: `$s" }
Check (-not `$dymoCom) 'DYMO removed'
'Apps entries left (DYMO''s prerequisites may stay):'; Get-AppsEntries
"@
        Copy-GuestLogs (Join-Path $logDir 'uninstall')
    }
} finally {
    Remove-Item -LiteralPath $pw -Force -ErrorAction SilentlyContinue
}

if ($script:failures) { Write-Host "$script:failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
