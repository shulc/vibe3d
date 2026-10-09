#!/usr/bin/env python3
"""Exact standalone DUB descriptors and ordinary fresh package execution.

Task 20261840, application_layers_wave2_plan_2026-10-09.md, Slice 2B.
Desktop sources are unavailable to common and its independent consumers.
The package compiler owns import resolution; this witness pins the grants.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

CORE_ROOTS = ('application_core_command_test.d', 'application_core_mesh_test.d',
              'command_invocation_test.d', 'command_registry_test.d', 'standalone_application_test.d')
CORE_CELLS = ('document-primary', 'invocation-order', 'invocation-outcomes', 'invocation-tweak',
              'mesh-cube', 'model-delivery', 'no-edit-target', 'pilot-live',
              'registry-authority', 'selected-triangle-refusal', 'session-carrier', 'standalone-no-target',
              'standalone-owner', 'standalone-select-drop', 'standalone-select-element',
              'standalone-select-invert', 'triple-roundtrip')

STB_REVISION = 'a66f6917718ea128076a2c5660e37f362a785144'
# Canonical JSON pins include configuration/build-type grants and platform keys.
DESCRIPTORS = {
    'packages/common': 'e3c1ae54eec1d85a372c3e2a5b36657b2804bb69ea44b497bca06ca27e2962d5',
    'tests/core': 'a8d2d7591ab2b00f361bafbf387b4b4f444150dffa43e9412482f781de9d07ba',
    'tools/cli': 'b72bee94493992f892354a6d6d0b01c2162b1875cb515231f4aaed51c6ef296f',
}
HOOKS = ('preGenerateCommands', 'postGenerateCommands', 'preBuildCommands',
         'postBuildCommands', 'preRunCommands', 'postRunCommands')
IMAGE_BUILD = ['cmake -B $PACKAGE_DIR/build -DCMAKE_GENERATOR=Ninja -DCMAKE_BUILD_TYPE=Release $PACKAGE_DIR',
               'cmake --build $PACKAGE_DIR/build --config Release']


class BoundaryError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise BoundaryError(message)


def validate_package_settings(description, root):
    project = root.parents[1]
    common = project / 'packages/common'
    manifest = json.loads((root / 'dub.json').read_text())
    owner = manifest['name']
    require(owner in ('vibe3d-common', 'vibe3d-core-tests', 'vibe3d-cli'), 'unexpected root package')
    for path in {common, root}:
        raw = json.loads((path / 'dub.json').read_text())
        grants = {k: v for k, v in raw.items() if k not in ('description', 'license', 'toolchainRequirements')}
        digest = hashlib.sha256(json.dumps(grants, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        relative = path.relative_to(project).as_posix()
        require(digest == DESCRIPTORS[relative], 'raw descriptor changed: ' + relative)
    require(description['rootPackage'] == owner, 'unexpected resolved root package')
    active = [p for p in description['packages'] if p.get('active')]
    packages = {p['name']: p for p in active}
    expected = {owner, 'vibe3d-common', 'd-stb-image'}
    require(len(active) == len(expected) and set(packages) == expected, 'resolved package population changed')
    image = Path(packages['d-stb-image']['path']).resolve()
    require(image.parts[-2:] == (STB_REVISION, 'd-stb-image'), 'resolved image revision changed')
    inventory = sorted(p.resolve() for p in (common / 'source').rglob('*.d'))
    roots = ([root / 'source/main.d'] if owner == 'vibe3d-cli' else
             [(project / 'tests/unit' / name).resolve() for name in CORE_ROOTS]
             if owner == 'vibe3d-core-tests' else inventory)
    targets = description['targets']
    require(len(targets) == len(expected) and {t['rootPackage'] for t in targets} == expected,
            'resolved target population changed')
    for name, package in packages.items():
        path = image if name == 'd-stb-image' else common if name == 'vibe3d-common' else root
        require(Path(package['path']).resolve() == path, 'resolved package path changed: ' + name)
        dependencies = [] if name == 'd-stb-image' else ['d-stb-image'] if name == 'vibe3d-common' else ['vibe3d-common']
        require(package.get('dependencies', []) == dependencies, 'resolved dependencies changed: ' + name)
        for field in HOOKS:
            require(package.get(field, []) == (IMAGE_BUILD if name == 'd-stb-image' and field == 'preBuildCommands' else []),
                    'resolved package hook changed: ' + name + ':' + field)
    for target in targets:
        name, settings = target['rootPackage'], target['buildSettings']
        sources = [image / 'source/stb_image/c.d'] if name == 'd-stb-image' else inventory if name == 'vibe3d-common' else roots
        imports = [image / 'source'] if name == 'd-stb-image' else [common / 'source', image / 'source']
        for field, paths in (('sourceFiles', sources), ('importPaths', imports)):
            require(sorted(Path(p).resolve() for p in settings.get(field, [])) == sorted(paths),
                    'resolved ' + field + ' changed: ' + name)
        archives = ([] if name == 'd-stb-image' else [image / 'libd-stb-image.a']
                    if name == 'vibe3d-common' else [common / 'libvibe3d-common.a', image / 'libd-stb-image.a'])
        pinned = {'linkerFiles': list(map(str, archives)), 'libs': ['stb_image_c', 'm'],
                  'lflags': ['-L' + str(image / 'build')],
                  'dflags': ['-i'] if name == 'vibe3d-core-tests' else []}
        for field in ('injectSourceFiles', 'frameworks', 'extraDependencyFiles', 'copyFiles',
                      'stringImportPaths', 'cImportPaths') + HOOKS:
            pinned[field] = IMAGE_BUILD if name == 'd-stb-image' and field == 'preBuildCommands' else []
        for field, value in pinned.items():
            require(settings.get(field, []) == value, 'resolved setting changed: ' + name + ':' + field)
    return roots


def validate_runtime(output):
    actual = re.findall(r'^CORE-CELL passed=(\S+)$', output, re.M)
    require(sorted(actual) == list(CORE_CELLS),
            'named-cell population: expected ' + repr(CORE_CELLS) + ', got ' + repr(actual))
    totals = re.findall(r'^(\d+) modules passed unittests$', output, re.M)
    require(len(totals) == 1 and int(totals[0]) > 0,
            'NO-VERDICT: missing nonzero druntime module total')
    return int(totals[0])


def run(command, root, env, evidence, name):
    result = subprocess.run(command, cwd=root, env=env, text=True, capture_output=True)
    (evidence / (name + '.log')).write_text(result.stdout)
    (evidence / (name + '.stderr.log')).write_text(result.stderr)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True)
    parser.add_argument('--config')
    parser.add_argument('--compiler', default='dmd')
    parser.add_argument('--unittest', action='store_true')
    parser.add_argument('--evidence-dir')
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    owner = json.loads((root / 'dub.json').read_text())['name']
    require(not args.unittest or owner == 'vibe3d-core-tests', 'only CORE has independent unittest acceptance')
    config = args.config or ('modeling-noai' if owner == 'vibe3d-common' else 'core' if owner == 'vibe3d-core-tests' else 'application')
    mode = 'unittest' if args.unittest else 'production'
    evidence = Path(args.evidence_dir).resolve() if args.evidence_dir else root / '.boundary' / mode
    evidence.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for variable in ('DISPLAY', 'WAYLAND_DISPLAY', 'SDL_VIDEODRIVER', 'DFLAGS'):
        env.pop(variable, None)
    compiler = shutil.which(args.compiler)
    require(compiler is not None, 'compiler not found: ' + args.compiler)
    describe = ['dub', 'describe', '--root=' + str(root), '--config=' + config, '--compiler=' + compiler, '--quiet']
    described = run(describe, root, env, evidence, 'describe')
    require(described.returncode == 0, 'DUB describe failed (see describe.stderr.log)')
    description = json.loads(described.stdout)
    (evidence / 'describe.json').write_text(json.dumps(description, indent=2) + '\n')
    roots = validate_package_settings(description, root)
    # CORE's five unittest roots have no production main. Production acceptance
    # compiles all common sources through their actual static-library target.
    build_root = root.parents[1] / 'packages/common' if owner == 'vibe3d-core-tests' and not args.unittest else root
    build_config = 'modeling-noai' if build_root != root else config
    command = ['dub', 'test' if args.unittest else 'build', '--root=' + str(build_root),
               '--config=' + build_config, '--compiler=' + compiler, '--force']
    result = run(command, root, env, evidence, 'build-run')
    output = result.stdout + result.stderr
    require(result.returncode == 0, 'DUB build/runtime failed: ' +
            next((line for line in output.splitlines() if 'Error:' in line or 'AssertError@' in line), 'see build-run logs'))
    total = validate_runtime(output) if args.unittest else None
    binary = build_root / ('vibe3d-core-tests-test-' + config if args.unittest else
                           'libvibe3d-common.a' if build_root.name == 'common' else owner)
    require(binary.is_file(), 'fresh DUB output missing: ' + str(binary))
    revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root, text=True, capture_output=True)
    sha = revision.stdout.strip() if revision.returncode == 0 else 'uncommitted-copy'
    witness = {'mode': mode, 'sha': sha, 'compiler': compiler, 'sources': list(map(str, roots)),
               'outputSha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'druntimeModules': total,
               'namedCells': list(CORE_CELLS) if args.unittest else [], 'command': command, 'describeCommand': describe}
    (evidence / 'witness.json').write_text(json.dumps(witness, indent=2) + '\n')
    print('BOUNDARY package=' + owner + ' mode=' + mode + ' described-roots=' + str(len(roots)) + ' sha=' + sha
          + (' modules=' + str(total) + ' cells=' + str(len(CORE_CELLS)) if args.unittest else ''))
    print('BOUNDARY-VERDICT=GREEN')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (BoundaryError, OSError, ValueError, KeyError) as error:
        print('BOUNDARY-VERDICT=RED Error: ' + str(error), file=sys.stderr)
        sys.exit(1)
