<#
.SYNOPSIS
    Shared helpers for New-TestVM.ps1 and Invoke-VMTest.ps1. Dot-source it; don't run it.

.DESCRIPTION
    Finds VBoxManage, runs it with exit-code checks, reads VM state, and runs
    commands in the guest as the built-in Administrator through guestcontrol.
    Guest passwords are passed with --passwordfile (a temp file the caller deletes),
    never on the command line.
#>

$VBoxManage = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
if (-not (Test-Path -LiteralPath $VBoxManage)) {
    throw "VBoxManage not found at $VBoxManage. Install VirtualBox first (run Set-HostForVirtualBox.ps1 elevated, then restart)."
}

# Runs VBoxManage and returns its stdout lines. Throws on a non-zero exit code unless
# -AllowFailure is given, in which case the caller must check $LASTEXITCODE itself.
function Invoke-VBox {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    # Local to this function: keeps VBoxManage's stderr (progress, errors) from
    # turning into a terminating error; the exit code is checked instead.
    $ErrorActionPreference = 'Continue'
    $out = @(& $VBoxManage --nologo @Arguments)
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        $shown = ($Arguments | ForEach-Object { $_ -replace '(?i)^(--[a-z-]*password)=.*$', '$1=***' }) -join ' '
        $detail = if ($out.Count) { "`n" + ($out -join "`n") } else { '' }
        throw "VBoxManage $shown failed with exit code $LASTEXITCODE.$detail"
    }
    return $out
}

# Returns the help text of a VBoxManage command, e.g. 'guestcontrol'. Help is used only
# to detect which options this VirtualBox version supports, so its exit code is ignored.
function Get-VBoxHelp([string]$Command) {
    $text = (Invoke-VBox -Arguments @('help', $Command) -AllowFailure) -join "`n"
    if (-not $text.Trim()) {
        $text = (Invoke-VBox -Arguments @($Command, '--help') -AllowFailure) -join "`n"
    }
    return $text
}

# Parses 'showvminfo --machinereadable' into a hashtable. VirtualBox 7 escapes '\' and
# '"' in values; older versions don't, so only unescape when doubled backslashes appear.
function Get-VMInfo([string]$VM) {
    $info = @{}
    foreach ($line in (Invoke-VBox -Arguments @('showvminfo', $VM, '--machinereadable'))) {
        if ($line -match '^"?(?<k>[^"=]+)"?=(?<v>.*)$') {
            $v = $Matches['v']
            if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2) }
            if ($v.Contains('\\') -or $v.Contains('\"')) { $v = [regex]::Replace($v, '\\(.)', '$1') }
            $info[$Matches['k']] = $v
        }
    }
    return $info
}

function Test-VMExists([string]$VM) {
    foreach ($line in (Invoke-VBox -Arguments @('list', 'vms'))) {
        if ($line -match '^"(?<n>.*)" \{[0-9a-fA-F-]+\}$' -and $Matches['n'] -eq $VM) { return $true }
    }
    return $false
}

function Get-VMState([string]$VM) { (Get-VMInfo $VM)['VMState'] }

function Wait-VMState([string]$VM, [string[]]$States, [int]$TimeoutMinutes) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        $state = Get-VMState $VM
        if ($States -contains $state) { return $state }
        if ((Get-Date) -gt $deadline) {
            throw "VM '$VM' did not reach state $($States -join '/') within $TimeoutMinutes min (now '$state')."
        }
        Start-Sleep -Seconds 5
    }
}

# Writes a secret to a new temp file (UTF-8, no BOM, no newline) for --passwordfile
# style options. The caller deletes it in a finally block.
function New-SecretFile([string]$Secret) {
    $path = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($path, $Secret, (New-Object Text.UTF8Encoding $false))
    return $path
}

function Read-VMSecrets([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Secrets file $Path not found. It is created by New-TestVM.ps1."
    }
    $s = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($name in 'StudentUser', 'StudentPassword', 'AdminUser', 'AdminPassword') {
        if (-not ($s.PSObject.Properties.Name -contains $name) -or -not $s.$name) {
            throw "Secrets file $Path is missing '$name'."
        }
    }
    return $s
}

# Checks once per session that this VirtualBox uses the expected guestcontrol syntax:
# 'guestcontrol <vm> run ...', --passwordfile, and (optionally) waitrunlevel.
$script:GuestControlHelp = $null
function Get-GuestControlSupport {
    if ($null -eq $script:GuestControlHelp) {
        $help = Get-VBoxHelp 'guestcontrol'
        if ($help -notmatch '--passwordfile') {
            throw "This VBoxManage's guestcontrol help doesn't mention --passwordfile; refusing to pass passwords on the command line."
        }
        if ($help -notmatch 'guestcontrol\s+<[^>]+>\s+run') {
            Write-Warning "Couldn't confirm 'guestcontrol <vm> run' argument order from the help text; continuing with it anyway."
        }
        $script:GuestControlHelp = [pscustomobject]@{ WaitRunLevel = ($help -match 'waitrunlevel') }
    }
    return $script:GuestControlHelp
}

# Runs a program in the guest and waits for it. Returns VBoxManage's stdout (the guest
# program's stdout). VBoxManage's exit code is left in $LASTEXITCODE.
function Invoke-Guest {
    param(
        [Parameter(Mandatory)][string]$VM,
        [Parameter(Mandatory)][string]$PasswordFile,
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$UserName = 'Administrator',
        [int]$TimeoutSeconds = 120,
        [switch]$AllowFailure
    )
    [void](Get-GuestControlSupport)
    $a = @('guestcontrol', $VM, 'run', "--username=$UserName", "--passwordfile=$PasswordFile",
           '--wait-stdout', '--wait-stderr', "--timeout=$($TimeoutSeconds * 1000)", '--', $Exe) + $Arguments
    Invoke-VBox -Arguments $a -AllowFailure:$AllowFailure
}

# Runs a PowerShell script in the guest. -EncodedCommand avoids every quoting layer
# between this host, VBoxManage and the guest.
function Invoke-GuestPowerShell {
    param(
        [Parameter(Mandatory)][string]$VM,
        [Parameter(Mandatory)][string]$PasswordFile,
        [Parameter(Mandatory)][string]$Script,
        [string]$UserName = 'Administrator',
        [int]$TimeoutSeconds = 300,
        [switch]$AllowFailure
    )
    $full = "`$ProgressPreference = 'SilentlyContinue'`n$Script"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
    Invoke-Guest -VM $VM -PasswordFile $PasswordFile -UserName $UserName -TimeoutSeconds $TimeoutSeconds -AllowFailure:$AllowFailure `
        -Exe 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
        -Arguments @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
}

# Waits for the guest desktop (guestcontrol waitrunlevel, if supported), then until a
# program can be started as Administrator. Returns the output of 'whoami /groups'.
function Wait-GuestReady {
    param(
        [Parameter(Mandatory)][string]$VM,
        [Parameter(Mandatory)][string]$PasswordFile,
        [int]$TimeoutMinutes = 20
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    if ((Get-GuestControlSupport).WaitRunLevel) {
        Write-Host "Waiting for the guest desktop (up to $TimeoutMinutes min) ..."
        [void](Invoke-VBox -Arguments @('guestcontrol', $VM, 'waitrunlevel', "--timeout=$($TimeoutMinutes * 60000)", 'desktop') -AllowFailure)
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "waitrunlevel desktop returned exit code $LASTEXITCODE (e.g. nobody logged in); falling back to polling."
        }
    } else {
        Write-Warning "This VBoxManage has no 'guestcontrol waitrunlevel'; polling instead."
    }
    Write-Host 'Waiting until commands can run in the guest as Administrator (errors while it boots are expected) ...'
    while ($true) {
        $out = Invoke-Guest -VM $VM -PasswordFile $PasswordFile -Exe 'C:\Windows\System32\whoami.exe' -Arguments @('/groups') -TimeoutSeconds 60 -AllowFailure
        if ($LASTEXITCODE -eq 0) { return $out }
        if ((Get-Date) -gt $deadline) {
            throw "Couldn't run commands in guest '$VM' as Administrator within $TimeoutMinutes min (last exit code $LASTEXITCODE)."
        }
        Start-Sleep -Seconds 15
    }
}
