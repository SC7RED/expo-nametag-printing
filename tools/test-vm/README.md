# Test VM for the silent installer

Scripts to build a throwaway Windows 11 Home VM in VirtualBox 7.2.22 and run
`dist\ExpoNametagSetup.exe /quiet` in it from a clean snapshot. They're for the developer's
PC only, not the Expo laptops.

| Script | Run as | What it does |
|---|---|---|
| `Set-HostForVirtualBox.ps1` | Administrator | Enables Windows Hypervisor Platform and installs VirtualBox 7.2.22 (winget). `-Revert` undoes the feature change. |
| `Get-Win11Iso.ps1` | normal user | Downloads the official Windows 11 x64 ISO from Microsoft through [Fido](https://github.com/pbatard/Fido) (pinned tag, hash-checked). |
| `New-TestVM.ps1` | normal user | Creates the VM, installs Windows 11 Home unattended, and takes the powered-off snapshot `clean`. |
| `Invoke-VMTest.ps1` | normal user | Restores `clean`, copies in `ExpoNametagSetup.exe` and `.env`, runs a silent install (and, with `-Uninstall`, a silent uninstall), checks the result, and copies the logs back to `dist\vm-logs\`. |
| `VBoxCommon.ps1` | (dot-sourced) | Shared helpers. |

The scripts are unsigned. Run them with
`powershell -ExecutionPolicy Bypass -File .\<script>.ps1`, which affects only that process.

## Prerequisites

- **Disk space:** about 80 GB free. The ISO is about 9 GB, the VM disk grows up to 64 GB,
  and snapshots add more. If C: is short, use `-StateDir D:\VMs` (ISO and secrets) and
  `New-TestVM.ps1 -BaseFolder D:\VMs` (the VM itself).
- Run `Set-HostForVirtualBox.ps1` from an elevated PowerShell, then **Restart**
  (not Shut down).

## Order

1. `Set-HostForVirtualBox.ps1` (elevated), then Restart.
2. `Get-Win11Iso.ps1`. It saves to `%USERPROFILE%\VMs\iso\Win11_x64.iso` and prints the SHA-256.
   `-Ed List` and `-Lang List` show the exact names Fido accepts.
3. `New-TestVM.ps1`. This takes one to three hours, mostly unattended. It pauses once so you
   can run Windows Update and then **Pause updates** in the guest (`-SkipUpdatePause` skips
   the pause).
4. Build `dist\ExpoNametagSetup.exe` (it is not named `Setup.exe` because Windows applies
   compatibility shims to files with that name). Put a laptop settings file at
   `dist\ExpoNametag.env` (see `proxy\README.md`). Both are git-ignored.
5. `Invoke-VMTest.ps1 -Uninstall`. It exits 0 only if every check passed.
   - `-AttachPrinter` passes the USB DYMO printer through to the VM (it leaves this PC while the VM runs).
   - `-CopyOnly` just copies the files in, so you can double-click the setup in the VM and
     see exactly what a student sees (only the UAC prompt should appear).
   - `-NoSettings` runs without `ExpoNametag.env`; the setup must refuse with exit code 2.
   - `-ForceDymoDownload` makes the bundle download DYMO's installer (see below).
   - `-Headless` runs with no VM window.

Generated passwords for `student` and `Administrator` are saved in
`%USERPROFILE%\VMs\Win11Home-Expo.secrets.json`, never in the repo.

## What `Invoke-VMTest.ps1` checks

- **Install:** exit code 0 or 3010; `ExpoNametag.exe` is in
  `C:\Program Files (x86)\Expo Nametag Printing`; `ExpoNametag.env` was copied in as `.env`
  (same content); both shortcuts exist; `Dymo.DymoAddIn` is registered. It also prints DYMO's
  drivers (`pnputil /enum-drivers`, including the signer) and the Settings > Apps entries.
- **Uninstall:** the folder, both shortcuts and DYMO are gone. It then lists what's left in
  Settings > Apps from DYMO's prerequisites (Bonjour, Visual C++ 2010/2013, Office runtime).
- Installer logs are copied to `dist\vm-logs\<time>\`. The VM is left running afterwards.

**DYMO's installer:**
- If `%USERPROFILE%\VMs\dymo\DLS8Setup8.7.4.exe` exists, the script checks its SHA-256 and
  copies it next to the bundle. The bundle then uses it instead of downloading 171 MB.
- `-ForceDymoDownload` skips the local copy so you can test the real download. The guest
  then needs internet access.
- The Burn log's `Acquiring package` line shows which source was used.

## VirtualBox runs in NEM ("turtle") mode

Memory Integrity stays on, which keeps the Windows hypervisor running. VirtualBox then
has to run on top of it through Windows Hypervisor Platform (its NEM backend). That is
slower than its own engine, so the guest may be slow, and Windows 11 guests have been
reported to hang. The scripts use long timeouts because of this.

- **To confirm NEM mode:** the VM's `VBox.log` (Machine > Show Log) contains `NEM`, and the VM
  window's status bar shows a turtle icon.
- **If the VM hangs or is unusable:** use VMware Workstation Pro, which also runs on Windows
  Hypervisor Platform. It's a manual download from Broadcom, and these scripts don't
  cover it.

## Reverting the host

- `Set-HostForVirtualBox.ps1 -Revert` (elevated), then Restart. This disables Windows
  Hypervisor Platform, but only if it was off before.
- VirtualBox stays installed. To remove it, run `winget uninstall --id Oracle.VirtualBox --exact`.
- To delete the VM, run `VBoxManage unregistervm Win11Home-Expo --delete`, then delete
  `%USERPROFILE%\VMs` if you no longer need the ISO.

## Notes

- **Memory Integrity can't be tested in the VM.** The VM can't run VBS or Memory Integrity,
  so check that the DYMO driver works with Memory Integrity on a real laptop.
- **SmartScreen:** files copied in with `guestcontrol` aren't marked as downloaded, so no
  SmartScreen warning appears. A downloaded copy opened from Explorer would show one.
- **Keep the `clean` snapshot powered off.** Every test starts from a cold boot, and
  `New-TestVM.ps1` takes it that way.
- **Paused updates expire** (after up to 5 weeks of guest time). After that, rebuild the VM or
  update and retake the snapshot.
- **Plain-text passwords:** VirtualBox keeps a copy of the guest passwords in its
  unattended-install files in the VM folder. That's fine for this throwaway VM, but don't
  reuse the passwords.
