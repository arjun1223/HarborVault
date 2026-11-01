"""Publish a verified app bundle atomically; never reads vault storage."""
from pathlib import Path
import ctypes
import os
import shutil
import subprocess
import sys

source, target = (Path(value).absolute() for value in sys.argv[1:3])
if source == target:
    raise ValueError("Build staging path and destination must differ")
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(source)], check=True)
target.parent.mkdir(parents=True, exist_ok=True)
if target.exists():
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    swap = library.renameatx_np
    swap.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    swap.restype = ctypes.c_int
    if swap(-2, os.fsencode(source), -2, os.fsencode(target), 2) != 0:
        error = ctypes.get_errno()
        raise OSError(error, "Could not atomically publish the app")
    shutil.rmtree(source)
else:
    source.rename(target)
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(target)], check=True)
print("Updated:", target)

