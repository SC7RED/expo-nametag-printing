# Engineering Expo Student Nametag Printing

A small Windows app for the Engineering Expo check-in tables. A volunteer scans a student's
Swapcard badge code (or types their VT PID), the app looks the student up, and a DYMO printer
prints their name tag. There's also a manual mode for typing a student's details in by hand.

```
laptop app  ──>  Cloudflare Worker  ──>  Swapcard (student data)
    │            (holds the API key)
    └──>  DYMO Label Software  ──>  DYMO LabelWriter 450 printer
```

## Setting up a laptop (volunteers)

You need two files from the IT chair: `ExpoNametagSetup.exe` and `ExpoNametag.env`.

1. Put both files in the **same folder** on the laptop itself (Desktop, Downloads or a USB stick;
   not a network drive or an online-only OneDrive folder).
2. Double-click `ExpoNametagSetup.exe` and click **Yes** when Windows asks. Nothing else appears.
   It installs DYMO Label Software and the app; this takes a few minutes.
3. Plug in the printer and open **Expo Nametag Printing** from the desktop.

To remove everything afterwards: **Settings → Apps → Expo Nametag Printing → Uninstall**.

Supported printers: the DYMO **LabelWriter 450** family (450, 450 Turbo). The 550 family does
not work with DYMO Label Software 8, and the 450 Duo has Windows 11 driver problems.

## Each year (IT chair)

1. Update the lookup service and make a new `ExpoNametag.env`: see [proxy/README.md](proxy/README.md).
2. Change `CURRENT_YEAR` in [src/config.py](src/config.py) (it's in the window title).
3. Build a new installer (below) and hand out `dist\ExpoNametagSetup.exe` with the `.env` file.

The Cloudflare account belongs to the shared IT committee email, so passing that login to
the next chair is the whole handover.

## Building the installer

One-time setup on a Windows PC (no admin needed):
- Python 3.13, **32-bit** (DYMO's software is 32-bit): `py install 3.13-32`
- .NET SDK 8 or later: `winget install Microsoft.DotNet.SDK.10`

Then, from the repo folder:

```powershell
.\installer\build-app.ps1 -Clean     # the app, as dist\ExpoNametag\ (no Python needed on laptops)
.\installer\build-installer.ps1      # dist\ExpoNametag.msi and dist\ExpoNametagSetup.exe
```

## Running from source (developers)

```powershell
py -V:3.13-32 -m pip install -r requirements.txt
copy env.example .env                # then fill it in
py -V:3.13-32 src\main.py
```

Tests (no packages or printer needed): `python -m unittest discover -s tests -v`

## What's where

| Path | What it is |
|---|---|
| [src/main.py](src/main.py) | The app: window, lookups, printing |
| [src/config.py](src/config.py), [src/query.py](src/query.py) | Settings and the calls to the lookup service |
| [src/label/student_badge_v3.label](src/label/student_badge_v3.label) | The badge design |
| [proxy/](proxy/) | The Cloudflare Worker that holds the Swapcard key |
| [installer/](installer/) | Build scripts, the WiX installer and the PyInstaller spec |
| [tests/](tests/) | Automated tests (fake network, printer and window) |
| [tools/test-vm/](tools/test-vm/) | Scripts for a Windows 11 test VM |
| [.github/workflows/installer.yml](.github/workflows/installer.yml) | Builds and test-installs on every push |

## Known limits

- The installer isn't code-signed, so a downloaded copy shows a SmartScreen warning
  ("More info → Run anyway"), and laptops with Smart App Control turned on block it.
  Copying it from a USB stick avoids the SmartScreen warning.
