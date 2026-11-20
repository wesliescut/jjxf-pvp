# -*- mode: python ; coding: utf-8 -*-

from pathlib import Path

root = Path(SPECPATH)
a = Analysis(
    [str(root / 'outputs' / 'dual_room_internet_gui.py')],
    pathex=[str(root / 'outputs')],
    binaries=[],
    datas=[(str(root / 'outputs' / 'runtime_multiplayer'), 'runtime_multiplayer'),
           (str(root / 'outputs' / 'assets' / 'launcher'), 'assets/launcher')],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name='JJXF_PVP_Original_Combat',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)






































