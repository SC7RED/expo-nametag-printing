# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec for the Expo nametag app: 32-bit, onedir, console.
# Build it with installer\build-app.ps1, which picks the 32-bit Python and the
# dist/work folders. Output: dist\ExpoNametag\ holding ExpoNametag.exe plus _internal\.
import os

REPO_DIR = os.path.abspath(os.path.join(SPECPATH, '..'))
SRC_DIR = os.path.join(REPO_DIR, 'src')
MAIN_SCRIPT = os.path.join(SRC_DIR, 'main.py')
LABEL_FILE = os.path.join(SRC_DIR, 'label', 'student_badge_v3.label')


def without_env_files(toc):
    """Drop any file named .env or *.env, so settings never end up in the build."""
    kept = []
    for entry in toc:
        if any(os.path.basename(path).lower().endswith('.env') for path in entry[:2] if path):
            print(f'NOTE: excluding settings file from the build: {entry[1]}')
            continue
        kept.append(entry)
    return kept


a = Analysis(
    [MAIN_SCRIPT],
    pathex=[SRC_DIR],
    binaries=[],
    datas=[(LABEL_FILE, 'src/label')],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    # urllib3 tries `from backports import zstd` (guarded by `except ImportError`).
    # Because setuptools is in the build venv, PyInstaller maps `backports` to
    # setuptools' vendored copy and would bundle all of setuptools, which the app
    # never uses. Excluding setuptools leaves `backports` missing, as it is at runtime.
    excludes=['setuptools'],
    noarchive=False,
    optimize=0,
    # FreeSimpleGUI is LGPL-3.0: ship it as plain .py files so it can be replaced.
    module_collection_mode={'FreeSimpleGUI': 'py'},
)
a.datas = without_env_files(a.datas)

exe = EXE(
    PYZ(a.pure),
    a.scripts,
    [],
    exclude_binaries=True,
    name='ExpoNametag',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    # Console app on purpose: the console window is the staff's only feedback.
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='ExpoNametag',
)
