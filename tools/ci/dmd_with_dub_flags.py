#!/usr/bin/env python3
"""Run dmd with the shell-quoted flags emitted by ``dub describe --data``."""

import shlex
import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 2:
        raise SystemExit("usage: dmd_with_dub_flags.py FLAGS [DMD_ARGUMENT ...]")
    flags = shlex.split(sys.argv[1])
    if not flags or any(not flag.startswith("-") for flag in flags):
        raise SystemExit("dub describe returned malformed D compiler flags")
    return subprocess.call(["dmd", *flags, *sys.argv[2:]])


if __name__ == "__main__":
    sys.exit(main())
