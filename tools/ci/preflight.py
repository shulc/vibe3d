#!/usr/bin/env python3
"""Task 20263020: refuse missing CI prerequisites before expensive builds."""
from pathlib import Path
import shutil
import subprocess
import sys

PINNED_LDC = Path.home() / '.local/dlang/ldc2-1.42.0-linux-x86_64/bin/ldc2'
TOOLS = {'dmd': '--version', 'dub': '--version', 'python3': '--version',
         'Xvfb': '-help', 'xvfb-run': '--help', 'xdotool': '--version',
         'ss': '-V', 'ldd': '--version'}


def main():
    for name, flag in [*TOOLS.items(), (str(PINNED_LDC), '--version')]:
        path = shutil.which(name)
        if path is None:
            raise RuntimeError(f'required executable missing or not executable: {name}')
        result = subprocess.run([path, flag], text=True, capture_output=True, timeout=10)
        output = (result.stdout + '\n' + result.stderr).strip()
        if result.returncode:
            raise RuntimeError(f'required executable failed: {path} exit={result.returncode}\n{output}')
        if name == str(PINNED_LDC) and 'LDC - the LLVM D compiler (1.42.0)' not in output:
            raise RuntimeError(f'pinned LDC identity mismatch: {path}\n{output}')
        print(f'CI-PREREQUISITE {name} path={path} version={output.splitlines()[0]}', flush=True)
    print('CI-PREFLIGHT=GREEN', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f'CI-PREFLIGHT=RED {error}', file=sys.stderr)
        sys.exit(1)
