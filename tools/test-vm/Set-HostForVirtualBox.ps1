#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prepares this Windows 11 host for the test VM: enables Windows Hypervisor Platform
    and installs VirtualBox 7.2.22. Run elevated, then Restart.

.DESCRIPTION
    Memory Integrity stays ON, so the Windows hypervisor keeps running. VirtualBox then
    runs on top of it through the Windows Hypervisor Platform API (its "NEM" backend).
    That is slower than VirtualBox's own engine ("turtle" mode): expect a slow guest.
    To confirm NEM mode, the VM's log (VBox.log) contains "NEM" and the VM window's
    status bar shows a turtle icon. If the guest hangs or is unusable, the fallback is
    VMware Workstation Pro, which also runs on Windows Hypervisor Platform (manual
    download from Broadcom).

    This script does not touch Memory Integrity, bcdedit, VirtualMachinePlatform or WSL.

    Before changing anything it saves the HypervisorPlatform feature state to
    <StateDir>\host-state-before.json (an existing file is kept, so rerunning never
    overwrites the original state). -Revert disables HypervisorPlatform only if it was
    disabled before; VirtualBox stays installed.

.EXAMPLE
    .\Set-HostForVirtualBox.ps1

.EXAMPLE
    .\Set-HostForVirtualBox.ps1 -Revert
#>
[CmdletBinding()]
param(
    # Undo the feature change recorded in host-state-before.json.
    [switch]$Revert,
    [string]$StateDir = (Join-Path $env:USERPROFILE 'VMs'),
    [string]$VirtualBoxVersion = '7.2.22'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$feature = 'HypervisorPlatform'
$statePath = Join-Path $StateDir 'host-state-before.json'
$vboxManage = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
$uninstallHint = 'winget uninstall --id Oracle.VirtualBox --exact'

function Get-FeatureState { [string](Get-WindowsOptionalFeature -Online -FeatureName $feature).State }

function Write-RestartNote {
    Write-Host ''
    Write-Host 'A full RESTART is needed (Start > Power > Restart, not Shut down).' -ForegroundColor Yellow
    Write-Host "Check afterwards:  (Get-WindowsOptionalFeature -Online -FeatureName $feature).State"
}

if ($Revert) {
    if (-not (Test-Path -LiteralPath $statePath)) { throw "No saved state at $statePath; nothing to revert." }
    $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Write-Host "Saved $feature state: $($saved.HypervisorPlatform)   Current: $(Get-FeatureState)"
    if ([string]$saved.HypervisorPlatform -like 'Disable*') {
        $r = Disable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart
        Write-Host "Disabled $feature."
        if ($r.RestartNeeded) { Write-RestartNote }
    } else {
        Write-Host "$feature was already enabled before; leaving it on."
    }
    Move-Item -LiteralPath $statePath -Destination (Join-Path $StateDir ("host-state-before.reverted-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date)))
    Write-Host "VirtualBox stays installed. To remove it:  $uninstallHint"
    return
}

# --- Save the current state (once) ---------------------------------------------------
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
if (Test-Path -LiteralPath $statePath) {
    Write-Host "Keeping the existing saved state in $statePath."
} else {
    [pscustomobject]@{
        Saved               = (Get-Date).ToString('s')
        HypervisorPlatform  = Get-FeatureState
        VirtualBoxInstalled = (Test-Path -LiteralPath $vboxManage)
    } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    Write-Host "Saved the current state to $statePath."
}

# --- Enable Windows Hypervisor Platform -----------------------------------------------
$restartNeeded = $false
$state = Get-FeatureState
if ($state -eq 'Enabled') {
    Write-Host "$feature is already enabled."
} else {
    Write-Host "Enabling $feature (currently $state) ..."
    $r = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
    $restartNeeded = [bool]$r.RestartNeeded
}

# --- Install VirtualBox -------------------------------------------------------------------
if (Test-Path -LiteralPath $vboxManage) {
    $installed = (& $vboxManage --version) -join ''
    if ($LASTEXITCODE -ne 0) { throw "VBoxManage --version failed with exit code $LASTEXITCODE." }
    Write-Host "VirtualBox is already installed ($installed)."
    if ($installed -notlike "$VirtualBoxVersion*") { Write-Warning "Expected VirtualBox $VirtualBoxVersion; the scripts were written for it." }
} else {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { throw 'winget not found. Install "App Installer" from the Microsoft Store.' }
    Write-Host "Installing VirtualBox $VirtualBoxVersion with winget (a driver prompt may appear; allow it) ..."
    & winget.exe install --id Oracle.VirtualBox --exact --version $VirtualBoxVersion --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget install failed with exit code $LASTEXITCODE." }
    $restartNeeded = $true   # VirtualBox installs kernel drivers
}

Write-Host ''
Write-Host 'VirtualBox will run in NEM ("turtle") mode because Memory Integrity keeps the Windows'
Write-Host 'hypervisor on. Expect a slow guest. Check: the VM log contains "NEM" and the status'
Write-Host 'bar shows a turtle. If the guest hangs, use VMware Workstation Pro (Broadcom download) instead.'
if ($restartNeeded -or $state -ne 'Enabled') { Write-RestartNote }
