# Engineering Expo Nametag Printing

A Windows app for the Expo check in tables. Scan a student's Swapcard badge (or type their VT PID) and a DYMO printer prints their name tag.

## What you need

* A Windows 10 or 11 laptop
* A DYMO **LabelWriter 450** or **450 Turbo** printer
* Two files that go together:
  * `ExpoNametagSetup.exe`: the installer (see [Getting the installer](#getting-the-installer))
  * `ExpoNametag.env`: the settings file for this year (see [proxy/README.md](proxy/README.md))

## Installing on a laptop

1. Put `ExpoNametagSetup.exe` and `ExpoNametag.env` in the **same folder** on the laptop, like the Desktop or a USB stick.
2. Double click `ExpoNametagSetup.exe` and click **Yes** when Windows asks. A small window shows the progress and closes by itself in a few minutes.
3. Plug in the printer. If it was already plugged in, unplug it and plug it back in.
4. Open **Expo Nametag Printing** from the desktop.

If Windows shows a blue "Windows protected your PC" box, click **More info**, then **Run anyway**. Copying the files from a USB stick usually avoids this.

To remove it later: **Settings > Apps > Expo Nametag Printing > Uninstall**.

## Getting the installer

**Option 1: Download it from GitHub (easiest)**

1. Go to the repo's **Actions** tab and click the newest run with a green check.
2. Scroll down to **Artifacts** and download the zip. `ExpoNametagSetup.exe` is inside.

GitHub deletes these after 7 days. If none are left, push any change to rerun it, or build it yourself.

**Option 2: Build it yourself**

On a Windows PC, install these once:

```powershell
py install 3.13-32
winget install Microsoft.DotNet.SDK.10
```

Then download this repo (**Code > Download ZIP**, then unzip it), open PowerShell in that folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File installer\build-app.ps1 -Clean
powershell -ExecutionPolicy Bypass -File installer\build-installer.ps1
```

The installer will be at `dist\ExpoNametagSetup.exe`.

## Every year

1. Update the Cloudflare lookup service and make a new `ExpoNametag.env`. Steps are in [proxy/README.md](proxy/README.md).
2. Change `CURRENT_YEAR` in [src/config.py](src/config.py).
3. Get a new installer (above) and install it on each laptop.

The Cloudflare account uses the shared IT committee email, so the only handoff is passing that login to the next chair.

Having problems? See [troubleshooting-guide.md](troubleshooting-guide.md).
