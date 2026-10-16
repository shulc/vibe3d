#!/usr/bin/env python3
"""Check production ThinLTO recipes, then build an archive/exception DUB probe.

The probe copies build types from the desktop and math owners. Its second
description changes only the root owner's LTO flag and must change the archive cache
artifact, so a warm non-LTO archive cannot pass as a ThinLTO build.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile


FLAGS = {
    'dflags-ldc': ['-flto=thin'],
    'dflags-linux-ldc': ['-L-plugin-opt=O3'],
    'dflags-osx-ldc': ['-L-mllvm', '-L-O3'],
    'dflags-windows-ldc': ['--link-internally', '-L/opt:lldlto=3'],
}
BUILDS = ('perf', 'release-thinlto', 'debug-thinlto')


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def check_recipes(root):
    recipe = json.loads((root / 'dub.json').read_text())
    # DUB Project.addBuildTypeSettings applies the ROOT build type to every
    # target, including archives; dependency-local buildTypes do not override it.
    for build in BUILDS:
        spec = recipe.get('buildTypes', {}).get(build, {})
        for key, values in FLAGS.items():
            require(spec.get(key) == values, f'dub.json {build}: missing ThinLTO flags {key}')
    for build, spec in recipe['buildTypes'].items():
        if build not in BUILDS:
            require('-flto=thin' not in spec.get('dflags-ldc', []),
                    f'unexpected ThinLTO in {build}')
    return 1


def check_link(log, platform, native_args=None):
    if platform == 'linux':
        # GCC verbose output exposes the actual linker order, including LDC's
        # generated O0. The explicit production O3 must be the final selection.
        lines = [line for line in log.splitlines()
                 if '-plugin-opt=thinlto' in line and '-plugin-opt=O' in line]
        require(lines, 'no actual ThinLTO linker invocation')
        levels = re.findall(r'-plugin-opt=O([0-3])', lines[-1])
        require(levels[-1:] == ['3'], 'final ThinLTO optimization is not O3')
    else:
        # LDC -v prints the actual native linker, including internal LLD.
        lines = log.splitlines()
        if platform == 'windows':
            # DUB drops LDC -v at the separate link, and internal LLD has no
            # external command to trace. Its reproducer records actual arguments.
            require(native_args is not None, 'no native LLD response captured')
            options = re.findall(r'(?im)^[-/]opt:([^\r\n]*)', native_args)
            levels = [value for option in options for value in
                      re.findall(r'(?:^|,)lldlto=([0-3])(?=,|$)', option.strip(), re.I)]
            require(levels[-1:] == ['3'], 'final ThinLTO optimization is not O3')
        else:
            require(any(re.search(r'\s-mllvm\s', line) and re.search(r'\s-O3(?:\s|$)', line)
                        for line in lines), 'no native ThinLTO O3 invocation')


def check_description(description):
    platform = next(p for p in ('linux', 'osx', 'windows') if p in description['platform'])
    targets = [target for target in description['targets']
               if target['rootPackage'] == 'vibe3d' or target['rootPackage'].startswith('vibe3d-')]
    require(len(targets) >= 2, 'no first-party archive population')
    for target in targets:
        flags = target['buildSettings']['dflags']
        for flag in FLAGS['dflags-ldc'] + FLAGS[f'dflags-{platform}-ldc']:
            require(flag in flags, f"{target['rootPackage']}: missing {flag}")
    return len(targets)


def probe(root, compiler, evidence):
    platform = 'windows' if sys.platform == 'win32' else 'osx' if sys.platform == 'darwin' else 'linux'
    app = evidence / 'probe'
    lib = app / 'helper'
    (app / 'source').mkdir(parents=True)
    (lib / 'source').mkdir(parents=True)
    app_types = json.loads((root / 'dub.json').read_text())['buildTypes']
    lib_types = json.loads((root / 'util/math/dub.json').read_text())['buildTypes']
    recipes = [dict(name='thinlto-probe', dependencies={'thinlto-helper': {'path': 'helper'}},
                    buildTypes=app_types),
               dict(name='thinlto-helper', targetType='staticLibrary', buildTypes=lib_types)]
    # Diagnostics only; the production optimization flags remain unmodified.
    for spec in app_types.values():
        spec.setdefault('dflags-ldc', []).extend(['-v', '-Xcc=-v'])
        if platform == 'windows':
            spec['dflags-ldc'].append('-L/reproduce:' + (evidence / 'native-link.tar').as_posix())
    for directory, recipe in zip((app, lib), recipes):
        (directory / 'dub.json').write_text(json.dumps(recipe))
    (lib / 'source/helper.d').write_text(
        'module helper; int add(int x) { if(x < 0) throw new Exception("archive exception"); return x+1; }\n')
    (app / 'source/app.d').write_text(
        'import helper, std.stdio; void main() { if(add(40)!=41) throw new Error("wrong result"); '
        'try { add(-1); } catch(Exception e) { writeln(e.msg); return; } throw new Error("missing exception"); }\n')
    env = dict(os.environ, DUB_HOME=str(evidence / 'dubhome'))
    env.pop('DFLAGS', None)

    def run(command, name):
        result = subprocess.run(command, cwd=app, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (evidence / (name + '.log')).write_text(result.stdout)
        require(result.returncode == 0, f'{name} failed: {evidence / (name + ".log")}')
        return result.stdout

    def describe(build, name):
        output = run(['dub', 'describe', '--build=' + build, '--compiler=' + compiler], name)
        return json.loads(output[output.index('{'):])

    for build in BUILDS:
        description = describe(build, build + '-describe')
        for target in description['targets']:
            require('-flto=thin' in target['buildSettings']['dflags'],
                    'archive target missed root ThinLTO flags')
        require(len(description['targets']) == 2, 'probe archive population changed')
        reproducer = evidence / 'native-link.tar'
        if platform == 'windows':
            reproducer.unlink(missing_ok=True)
        log = run(['dub', 'build', '--build=' + build, '--compiler=' + compiler, '-v'], build + '-build')
        native_args = None
        if platform == 'windows':
            with tarfile.open(reproducer) as archive:
                responses = [m for m in archive.getmembers() if m.name.endswith('/response.txt')]
                require(len(responses) == 1, 'expected one native LLD response')
                native_args = archive.extractfile(responses[0]).read().decode('utf-8')
            (evidence / (build + '-native-link.rsp')).write_text(native_args)
            reproducer.unlink()
        check_link(log, platform, native_args)
        binary = app / ('thinlto-probe.exe' if platform == 'windows' else 'thinlto-probe')
        require(run([str(binary)], build + '-run').strip() == 'archive exception',
                'archive exception failed to unwind')
    before = describe('perf', 'cache-before')
    app_types['perf']['dflags-ldc'].remove('-flto=thin')
    (app / 'dub.json').write_text(json.dumps(recipes[0]))
    after = describe('perf', 'cache-after')
    def artifact(description):
        return next(t['cacheArtifactPath'] for t in description['targets']
                    if t['rootPackage'] == 'thinlto-helper')
    require(artifact(before) != artifact(after), 'archive LTO flag did not change the DUB cache key')
    # Exercise the link oracle against the exact captured invocation as well.
    if platform == 'linux':
        log = (evidence / 'perf-build.log').read_text()
        try:
            check_link(log.replace('-plugin-opt=O3', '-plugin-opt=O0'), platform)
        except RuntimeError:
            pass
        else:
            raise RuntimeError('O3 removal escaped the link check')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--compiler', default='ldc2')
    parser.add_argument('--evidence-dir', type=Path)
    parser.add_argument('--description', type=Path, help='also audit an actual desktop dub describe JSON')
    parser.add_argument('--recipes-only', action='store_true')
    args = parser.parse_args()
    owners = check_recipes(args.root.resolve())
    if args.description:
        text = args.description.read_text()
        owners = check_description(json.loads(text[text.index('{'):]))
    if not args.recipes_only:
        evidence = args.evidence_dir or Path(tempfile.mkdtemp(prefix='thinlto-check-'))
        evidence.mkdir(parents=True, exist_ok=True)
        probe(args.root.resolve(), args.compiler, evidence.resolve())
        print('ThinLTO probe logs: ' + str(evidence))
    print(f'THINLTO-CHECK=GREEN owners={owners}')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print('THINLTO-CHECK=RED ' + str(error), file=sys.stderr)
        sys.exit(1)
