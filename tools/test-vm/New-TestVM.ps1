<#
.SYNOPSIS
    Creates the Windows 11 Home test VM in VirtualBox 7.2, installs it unattended,
    and takes a powered-off snapshot named "clean".

.DESCRIPTION
    Run as a normal user after Set-HostForVirtualBox.ps1 + restart, and after
    Get-Win11Iso.ps1. Takes one to three hours (VirtualBox runs in its slower NEM
    mode on this host), mostly unattended.

    Passwords for 'student' and the built-in 'Administrator' are generated once and
    saved to <StateDir>\<VMName>.secrets.json (outside the repo). guestcontrol gets
    them through --passwordfile with a temp file, so they don't show in process lists.
    VirtualBox itself keeps a plain-text copy in the VM folder's unattended files.

.EXAMPLE
    .\New-TestVM.ps1

.EXAMPLE
    .\New-TestVM.ps1 -BaseFolder D:\VMs -SkipUpdatePause
#>
[CmdletBinding()]
param(
    [string]$VMName = 'Win11Home-Expo',
    [string]$StateDir = (Join-Path $env:USERPROFILE 'VMs'),
    # Defaults to <StateDir>\iso\Win11_x64.iso.
    [string]$IsoPath,
    # Where VirtualBox puts the VM folder. Empty = VirtualBox's default machine folder.
    [string]$BaseFolder,
    # Image index in install.wim. 0 = detect "Windows 11 Home" automatically.
    [int]$ImageIndex = 0,
    # Microsoft's generic Windows 11 Home install key. It installs but does not activate.
    [string]$ProductKey = 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7',
    [int]$DiskSizeMB = 65536,
    # Memory Integrity keeps the Windows hypervisor on, so VirtualBox runs in its slower
    # NEM (Hyper-V) mode, where Windows 11 guests have been reported to hang. Hence the
    # long default wait for Guest Additions.
    [int]$InstallTimeoutMinutes = 180,
    # Don't wait for Enter after the Windows Update hint.
    [switch]$SkipUpdatePause,
    # Delete an existing VM with the same name first (asks for confirmation).
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'VBoxCommon.ps1')

if (-not $IsoPath) { $IsoPath = Join-Path $StateDir 'iso\Win11_x64.iso' }
if (-not (Test-Path -LiteralPath $IsoPath)) { throw "ISO not found at $IsoPath. Run Get-Win11Iso.ps1 first." }
$IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$distDir = Join-Path $repoRoot 'dist'
$secretsPath = Join-Path $StateDir "$VMName.secrets.json"
$studentUser = 'student'

function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }

# Random password from an unambiguous alphabet (no 0/O, 1/l/I) so it can be typed
# into the VM by hand; contains upper, lower and digit.
function New-RandomPassword([int]$Length = 20) {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        do {
            $bytes = New-Object byte[] $Length
            $rng.GetBytes($bytes)
            $pw = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
        } until ($pw -cmatch '[A-Z]' -and $pw -cmatch '[a-z]' -and $pw -match '[0-9]')
        return $pw
    } finally {
        $rng.Dispose()
    }
}

# --- Pre-flight -----------------------------------------------------------------------
Write-Host "VirtualBox: $((Invoke-VBox -Arguments @('--version')) -join '')"
if ((Get-CimInstance Win32_ComputerSystem).HypervisorPresent) {
    Write-Host 'The Windows hypervisor is on (Memory Integrity), so VirtualBox will use its slower NEM mode (turtle icon in the VM status bar).'
}

if (Test-VMExists $VMName) {
    if (-not $Force) { throw "VM '$VMName' already exists. Use -Force to delete and recreate it." }
    $answer = Read-Host "Type the VM name ($VMName) to DELETE it and all its disks and snapshots"
    if ($answer -ne $VMName) { throw 'Cancelled.' }
    if ((Get-VMState $VMName) -notin @('poweroff', 'aborted', 'saved')) {
        Invoke-VBox -Arguments @('controlvm', $VMName, 'poweroff') | Out-Null
        [void](Wait-VMState $VMName @('poweroff', 'aborted') 5)
    }
    Invoke-VBox -Arguments @('unregistervm', $VMName, '--delete') | Out-Null
    Write-Host "Deleted VM '$VMName'."
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
if (Test-Path -LiteralPath $secretsPath) {
    $secrets = Read-VMSecrets $secretsPath
    Write-Host "Reusing passwords from $secretsPath"
} else {
    $secrets = [pscustomobject]@{
        VMName          = $VMName
        StudentUser     = $studentUser
        StudentPassword = New-RandomPassword
        AdminUser       = 'Administrator'
        AdminPassword   = New-RandomPassword
        Created         = (Get-Date).ToString('s')
    }
    $secrets | ConvertTo-Json | Set-Content -LiteralPath $secretsPath -Encoding UTF8
    Write-Host "Saved new passwords to $secretsPath"
}

$tempFiles = New-Object System.Collections.Generic.List[string]
try {
    $adminPwFile = New-SecretFile $secrets.AdminPassword
    $tempFiles.Add($adminPwFile)

    # --- Create and configure the VM ------------------------------------------------
    Write-Step "Creating VM '$VMName'"
    $create = @('createvm', '--name', $VMName, '--ostype', 'Windows11_64', '--register')
    if ($BaseFolder) { $create += "--basefolder=$BaseFolder" }
    Invoke-VBox -Arguments $create | Out-Null

    # 4 vCPUs on purpose: 2 vCPUs hang Windows 11 24H2+ guests on VirtualBox 7.2.x.
    Invoke-VBox -Arguments @('modifyvm', $VMName, '--firmware=efi', '--tpm-type=2.0', '--cpus=4', '--memory=8192',
        '--vram=128', '--graphicscontroller=vboxsvga', '--accelerate-3d=off', '--ioapic=on', '--nic1=nat',
        '--nic-type1=82540EM', '--usb-xhci=on', '--mouse=usbtablet', '--audio-enabled=off') | Out-Null

    Invoke-VBox -Arguments @('storagectl', $VMName, '--name', 'SATA', '--add', 'sata', '--controller', 'IntelAhci',
        '--portcount', '4', '--bootable', 'on') | Out-Null

    $cfgFile = (Get-VMInfo $VMName)['CfgFile']
    $vmDir = Split-Path -Parent $cfgFile
    $vdi = Join-Path $vmDir "$VMName.vdi"
    Invoke-VBox -Arguments @('createmedium', 'disk', "--filename=$vdi", "--size=$DiskSizeMB", '--format=VDI') | Out-Null
    Invoke-VBox -Arguments @('storageattach', $VMName, '--storagectl', 'SATA', '--port', '0', '--device', '0',
        '--type', 'hdd', '--medium', $vdi) | Out-Null

    # Secure Boot keys (the VM must be powered off).
    foreach ($nv in @(@('inituefivarstore'), @('enrollmssignatures'), @('enrollorclpk'), @('secureboot', '--enable'))) {
        Invoke-VBox -Arguments (@('modifynvram', $VMName) + $nv) | Out-Null
    }

    # --- Pick the Windows 11 Home image -----------------------------------------------
    if ($ImageIndex -le 0) {
        Write-Step 'Detecting images on the ISO'
        $det = Invoke-VBox -Arguments @('unattended', 'detect', "--iso=$IsoPath", '--machine-readable') -AllowFailure
        if ($LASTEXITCODE -ne 0) { $det = Invoke-VBox -Arguments @('unattended', 'detect', "--iso=$IsoPath") }
        $idx = @{}; $names = @{}; $images = @()
        foreach ($line in $det) {
            if ($line -match '^ImageIndex(\d+)="?(\d+)"?$') { $idx[$Matches[1]] = [int]$Matches[2] }
            elseif ($line -match '^ImageIndex(\d+)="(.+)"$') {   # VirtualBox 7.2: ImageIndexN="<name>"
                $images += [pscustomobject]@{ Index = [int]$Matches[1]; Name = $Matches[2] }
            }
            elseif ($line -match '^ImageName(\d+)="(.*)"$') { $names[$Matches[1]] = $Matches[2] }
            elseif ($line -match '^\s*Image #\s*(\d+)\s*=\s*(.+?)\s*$') {   # human-readable format
                $images += [pscustomobject]@{ Index = [int]$Matches[1]; Name = $Matches[2] }
            }
        }
        foreach ($k in $names.Keys) {
            $i = if ($idx.ContainsKey($k)) { $idx[$k] } else { [int]$k + 1 }
            $images += [pscustomobject]@{ Index = $i; Name = $names[$k] }
        }
        # VirtualBox may append details such as "(10.0.26300 / x64 / en-US)"; compare
        # the name without trailing (...), {...} or [...] groups.
        $homeImages = @($images | Where-Object {
            ($_.Name -replace '(\s*[\(\{\[][^\)\}\]]*[\)\}\]])+\s*$', '').Trim() -eq 'Windows 11 Home'
        } | Sort-Object Index)
        if ($homeImages.Count -eq 0) {
            $list = if ($images.Count) { ($images | Sort-Object Index | ForEach-Object { "  $($_.Index): $($_.Name)" }) -join "`n" } else { $det -join "`n" }
            throw "No image named exactly 'Windows 11 Home' on $IsoPath. Detected:`n$list`nPass -ImageIndex to choose one."
        }
        $ImageIndex = $homeImages[0].Index
        Write-Host "Using image $ImageIndex ($($homeImages[0].Name))."
    }

    # --- Unattended install --------------------------------------------------------------
    Write-Step 'Starting the unattended install'
    $ua = @('unattended', 'install', $VMName, "--iso=$IsoPath", "--image-index=$ImageIndex", "--key=$ProductKey",
            "--user=$($secrets.StudentUser)", '--full-user-name=Expo Student')
    $uaHelp = Get-VBoxHelp 'unattended'
    if ($uaHelp -match '--user-password-file' -and $uaHelp -match '--admin-password-file') {
        $userPwFile = New-SecretFile $secrets.StudentPassword
        $tempFiles.Add($userPwFile)
        $ua += @("--user-password-file=$userPwFile", "--admin-password-file=$adminPwFile")
    } else {
        Write-Warning 'This VBoxManage has no --*-password-file options; passing the passwords as arguments.'
        $ua += @("--user-password=$($secrets.StudentPassword)", "--admin-password=$($secrets.AdminPassword)")
    }
    $ua += @('--locale=en_US', '--country=US', '--hostname=expo-test.local', '--install-additions',
             '--post-install-command=net user Administrator /active:yes', '--start-vm=gui')
    Invoke-VBox -Arguments $ua | Out-Null

    Write-Host "Windows is installing in the VM window. Waiting up to $InstallTimeoutMinutes min for Guest Additions ..."
    $deadline = (Get-Date).AddMinutes($InstallTimeoutMinutes)
    $started = Get-Date
    $nextNote = $started
    while ($true) {
        $prop = Invoke-VBox -Arguments @('guestproperty', 'get', $VMName, '/VirtualBox/GuestAdd/Version') -AllowFailure
        if ($LASTEXITCODE -eq 0) {
            $value = @($prop | Where-Object { $_ -match '^Value:\s*(\S.*)$' } | ForEach-Object { $Matches[1] })
            if ($value.Count) { Write-Host "Guest Additions $($value[0]) are running."; break }
        } else {
            Write-Warning "guestproperty get returned exit code $LASTEXITCODE; retrying."
        }
        $state = Get-VMState $VMName
        if ($state -in @('poweroff', 'aborted')) { throw "The VM stopped during the install (state '$state'). Check the VM window/logs." }
        if ((Get-Date) -gt $deadline) { throw "Guest Additions didn't report a version within $InstallTimeoutMinutes min." }
        if ((Get-Date) -ge $nextNote) {
            Write-Host ("  still installing ... {0:N0} min elapsed" -f ((Get-Date) - $started).TotalMinutes)
            $nextNote = (Get-Date).AddMinutes(5)
        }
        Start-Sleep -Seconds 30
    }

    # The post-install step may still be enabling Administrator; this waits for it.
    [void](Wait-GuestReady -VM $VMName -PasswordFile $adminPwFile -TimeoutMinutes 30)

    # --- Reboot once and check Administrator gets a full (elevated) token -------------
    Write-Step 'Rebooting the guest'
    $bootQuery = '(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")'
    $bootBefore = (@(Invoke-GuestPowerShell -VM $VMName -PasswordFile $adminPwFile -Script $bootQuery) | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if (-not $bootBefore) { throw "Couldn't read the guest's last boot time." }
    Invoke-Guest -VM $VMName -PasswordFile $adminPwFile -Exe 'C:\Windows\System32\shutdown.exe' -Arguments @('/r', '/t', '5') | Out-Null
    Write-Host 'Waiting for the guest to come back (errors while it reboots are expected) ...'
    $deadline = (Get-Date).AddMinutes(20)
    Start-Sleep -Seconds 30
    while ($true) {
        $bootNow = (@(Invoke-GuestPowerShell -VM $VMName -PasswordFile $adminPwFile -Script $bootQuery -TimeoutSeconds 60 -AllowFailure) | Where-Object { $_.Trim() } | Select-Object -Last 1)
        if ($LASTEXITCODE -eq 0 -and $bootNow -and $bootNow -ne $bootBefore) { break }
        if ((Get-Date) -gt $deadline) { throw 'The guest did not come back from the reboot within 20 min.' }
        Start-Sleep -Seconds 15
    }
    $groups = Wait-GuestReady -VM $VMName -PasswordFile $adminPwFile -TimeoutMinutes 20
    if (($groups -join "`n") -notmatch 'High Mandatory Level') {
        throw "Administrator's token is not High Mandatory Level, so installs via guestcontrol would hit UAC. whoami /groups:`n$($groups -join "`n")"
    }
    Write-Host 'OK: guestcontrol runs as Administrator at High Mandatory Level.'

    # --- Optional Windows Update ---------------------------------------------------------
    Write-Step 'Windows Update (optional)'
    Write-Host "Optional: in the VM, log in as '$($secrets.StudentUser)' if needed (password in $secretsPath),"
    Write-Host 'run Settings > Windows Update until it is current (reboot as asked), then click'
    Write-Host '"Pause updates" so updates don''t change things between tests. Leave the VM running.'
    if (-not $SkipUpdatePause) { [void](Read-Host 'Press Enter when you are done (or right away to skip)') }

    # --- Shut down, clean up media, share dist\, snapshot -------------------------------
    Write-Step 'Shutting down the guest'
    [void](Wait-GuestReady -VM $VMName -PasswordFile $adminPwFile -TimeoutMinutes 20)
    Invoke-Guest -VM $VMName -PasswordFile $adminPwFile -Exe 'C:\Windows\System32\shutdown.exe' -Arguments @('/s', '/t', '5') | Out-Null
    [void](Wait-VMState $VMName @('poweroff') 30)

    Write-Step 'Emptying DVD drives'
    $info = Get-VMInfo $VMName
    $controllers = @($info.Keys | Where-Object { $_ -match '^storagecontrollername\d+$' } | ForEach-Object { $info[$_] })
    foreach ($key in @($info.Keys)) {
        foreach ($ctl in $controllers) {
            if ($key -notmatch ('^' + [regex]::Escape($ctl) + '-(\d+)-(\d+)$')) { continue }
            $port = $Matches[1]; $device = $Matches[2]
            if ($info[$key] -match '\.(iso|viso)$') {
                Write-Host "  $ctl port $port device ${device}: $($info[$key])"
                Invoke-VBox -Arguments @('storageattach', $VMName, '--storagectl', $ctl, '--port', $port,
                    '--device', $device, '--type', 'dvddrive', '--medium', 'emptydrive') | Out-Null
            }
        }
    }

    Write-Step "Sharing $distDir read-only as 'build'"
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    Invoke-VBox -Arguments @('sharedfolder', 'add', $VMName, '--name=build', "--hostpath=$distDir", '--readonly', '--automount') | Out-Null

    Write-Step "Taking snapshot 'clean'"
    $desc = "Fresh Windows 11 Home (image $ImageIndex), Guest Additions, Administrator enabled, DVDs empty, powered off. Created $(Get-Date -Format s)."
    Invoke-VBox -Arguments @('snapshot', $VMName, 'take', 'clean', '--description', $desc) | Out-Null

    Write-Host ''
    Write-Host "Done. VM '$VMName' has a powered-off snapshot 'clean'. Next: build dist\ExpoNametagSetup.exe, then run Invoke-VMTest.ps1." -ForegroundColor Green
} finally {
    foreach ($f in $tempFiles) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}
