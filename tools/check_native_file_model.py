#!/usr/bin/env python3
"""Compile the production native codec closure without desktop build inputs."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from check_standalone_boundary import (BoundaryError, runtime_registry_inputs, validate_inputs,
                                       compiler_inputs, require)


def check(root, evidence):
    env = os.environ.copy()
    for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'SDL_VIDEODRIVER', 'DFLAGS'):
        env.pop(name, None)
    compiler = shutil.which('dmd')
    require(compiler is not None, 'native production compiler missing')
    described = subprocess.run(['dub', 'describe', '--config=modeling', '--compiler=dmd', '--quiet'],
                               cwd=root, env=env, text=True, capture_output=True)
    require(described.returncode == 0, 'native production import-path resolution failed')
    settings = json.loads(described.stdout)['targets'][0]['buildSettings']
    deps = evidence / 'compiler.deps'
    deps.unlink(missing_ok=True)
    command = [compiler, '-c', '-i', '-v', '-deps=' + str(deps),
               '-of=' + str(evidence / 'native.o')]
    command += ['-I' + p for p in settings['importPaths']]
    command += [str(root / 'packages/common/source/io/native.d')]
    compiled = subprocess.run(command, cwd=root, env=env, text=True, capture_output=True)
    output = compiled.stdout + compiled.stderr
    (evidence / 'compiler.log').write_text(output)
    (evidence / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    modules, files = compiler_inputs(deps.read_text() if deps.is_file() else '', output, root)
    (evidence / 'compiler-inputs.json').write_text(json.dumps(
        {'modules': modules, 'files': sorted(files)}, indent=2) + '\n')
    validate(modules, files, compiled.returncode, deps.is_file(), runtime_registry_inputs(output, compiler))
    print('NATIVE-BOUNDARY mode=production files=' + str(len(files)))
    print('NATIVE-BOUNDARY-VERDICT=GREEN')


def validate(modules, files, status, has_deps, runtime_registry=()):
    validate_inputs(modules, files, runtime_registry)
    for module, filename in modules.items():
        require(module not in {
            'io.file_dialog', 'io.file_dialog_browser', 'io.browser_pick_resume'},
            'native production forbidden compiler module: ' + module + ' (' + filename + ')')
    require(status == 0 and has_deps, 'native production compile failed (see compiler.log)')
    require(len(files) >= 20 and {'io.native', 'io.image_path', 'io.file_model',
                                  'stb_image.c', 'mesh', 'document'} <= modules.keys(),
            'native production compiler population/owners missing')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument('--evidence-dir')
    args = parser.parse_args()
    root = Path(args.root).resolve()
    if args.evidence_dir:
        evidence = Path(args.evidence_dir).resolve()
        evidence.mkdir(parents=True, exist_ok=True)
        check(root, evidence)
    else:
        with tempfile.TemporaryDirectory(prefix='native-file-model-') as temporary:
            check(root, Path(temporary))


if __name__ == '__main__':
    try:
        main()
    except (BoundaryError, OSError, ValueError, KeyError) as error:
        print('NATIVE-BOUNDARY-VERDICT=RED Error: ' + str(error), file=sys.stderr)
        sys.exit(1)
