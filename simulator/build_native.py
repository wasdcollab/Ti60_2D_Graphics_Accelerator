# build_native.py -- build the C++ simulation kernel in place.
#
#   python build_native.py
#
# Produces _socvm.cp313-win_amd64.pyd next to this file.  rv32i_soc_vm.py picks
# it up automatically on the next run; delete the .pyd to fall back to the pure
# Python kernel (which still runs under PyPy if you want a middle tier).
#
# Requirements: MSVC (VS 2022 Community is installed on this machine) and
# pybind11.  A MinGW build would NOT work -- a CPython extension must match the
# interpreter's CRT and object layout.

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main():
    rc = subprocess.call([sys.executable, "setup.py", "build_ext", "--inplace"],
                         cwd=str(HERE))
    if rc != 0:
        print("[FAIL] build failed (rc=%d)" % rc, file=sys.stderr)
        return rc
    pyd = next(HERE.glob("_socvm*.pyd"), None)
    if pyd is None:
        print("[FAIL] build reported success but no .pyd appeared", file=sys.stderr)
        return 1
    print("[OK] %s  (%.0f KB)" % (pyd.name, pyd.stat().st_size / 1024.0))
    print("     run_sim_native.bat will use it from now on.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
