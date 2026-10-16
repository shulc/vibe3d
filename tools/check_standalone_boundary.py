#!/usr/bin/env python3
"""Exact standalone DUB descriptors and ordinary fresh package execution.

Task 20261840, application_layers_wave2_plan_2026-10-09.md, Slice 2B.
Desktop sources are unavailable to the headless owners and their independent consumers.
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
    'packages/command-runtime': '7e3f393e50c787470e615c0fa5fb51f8f55f75ba06d6ed27c20e462879a344ea',
    'packages/application-core': 'a2a24d838625b785aef49ede8386e999b39f73d1236e367b828771e4ce81801a',
    'tests/core': '3790a284610cea9738c1ebb2d3984b039ec69a66ac6c17e43bfb5cf10e6d3bb6',
    'tools/cli': '82365b33a1aa67624cb8e51e903bedb128ec8287a8674cbc5f65cec4167f9f20',
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


def validate_package_settings(description, root, compiler="dmd"):
    import check_package_support_boundary as support
    project=root.parents[1]
    manifest=json.loads((root/'dub.json').read_text()); owner=manifest['name']
    require(owner in ('vibe3d-command-runtime','vibe3d-application-core','vibe3d-core-tests','vibe3d-cli'), 'unexpected root package')
    for path in {project/'packages/command-runtime',project/'packages/application-core',root}:
        raw=json.loads((path/'dub.json').read_text())
        grants={k:v for k,v in raw.items() if k not in ('description','license','toolchainRequirements')}
        digest=hashlib.sha256(json.dumps(grants,sort_keys=True,separators=(',',':')).encode()).hexdigest()
        relative=path.relative_to(project).as_posix()
        require(digest==DESCRIPTORS[relative], 'raw descriptor changed: '+relative)
    require(description['rootPackage']==owner, 'unexpected root package')
    active_list=[p for p in description['packages'] if p.get('active')];active={p['name']:p for p in active_list}
    expected={owner}
    for dependency in manifest.get('dependencies', {}):
        expected|={support.SPECS[x]['name'] for x in support.closure(support.internal_owner(dependency))}
    if owner in ('vibe3d-command-runtime','vibe3d-application-core'):
        expected|={support.SPECS[x]['name'] for x in support.closure(support.internal_owner(owner))}
    if 'vibe3d-document-io' in expected: expected.add('d-stb-image')
    require(len(active_list)==len(expected) and set(active)==expected,'resolved package population changed')
    image=Path(active['d-stb-image']['path']).resolve() if 'd-stb-image' in active else None
    if image is not None:
        require(image.parts[-2:]==(STB_REVISION,'d-stb-image'),'resolved image revision changed')
    roots=([root/'source/main.d'] if owner=='vibe3d-cli' else [(root/name).resolve() for name in manifest['sourceFiles']] if owner=='vibe3d-core-tests' else sorted((root/'source').rglob('*.d')))
    if owner=='vibe3d-core-tests':
        require(tuple(path.name for path in roots)==CORE_ROOTS, 'CORE mapped five root identities changed')
    targets={t['rootPackage']:t for t in description['targets']}
    expected_targets={n for n,p in active.items() if p['targetType']!='sourceLibrary'}
    require(len(description['targets'])==len(expected_targets) and set(targets)==expected_targets,'resolved target population changed')
    for name,package in active.items():
        if name=='d-stb-image':path=image;deps=[]
        else:
            selected=support.internal_owner(name) if name!=owner else None
            path=root if name==owner else project/support.SPECS[selected]['root']
            raw=json.loads((path/'dub.json').read_text());deps=list(raw.get('dependencies',{}))
        require(Path(package['path']).resolve()==path.resolve(),'resolved package path changed: '+name)
        require(sorted(package.get('dependencies',[]))==sorted(deps),'resolved dependencies changed: '+name)
        for field in HOOKS:
            require(package.get(field,[])==(IMAGE_BUILD if name=='d-stb-image' and field=='preBuildCommands' else []),'resolved package hook changed: '+name+':'+field)
    for name,target in targets.items():
        settings=target['buildSettings']
        internal={name};seen=set()
        def visit(n):
            if n in seen:return
            seen.add(n)
            for dep in active[n].get('dependencies',[]):visit(dep)
        visit(name)
        internal|={n for n in seen if active[n]['targetType']=='sourceLibrary'}
        expected_sources=[]
        for n in internal:
            if n=='d-stb-image':expected_sources.append(image/'source/stb_image/c.d')
            elif n==owner:expected_sources+=roots
            else:expected_sources+=support.production_files(project,support.internal_owner(n))
        actual=[Path(p).resolve() for p in settings.get('sourceFiles',[])]
        require(sorted(actual)==sorted(Path(p).resolve() for p in expected_sources) and len(actual)==len(set(actual)),'resolved sourceFiles changed: '+name)
        imports={str((Path(active[n]['path'])/p).resolve()) for n in seen for p in active[n].get('importPaths',[])}
        actual_imports=[str(Path(p).resolve()) for p in settings.get('importPaths',[])]
        require(set(actual_imports)==imports and len(actual_imports)==len(imports),'resolved importPaths changed: '+name)
        archives={str(Path(active[n]['path'])/(support.archive_name(support.internal_owner(n)) if support.is_internal(n) else 'lib'+n+'.a')) for n in seen-{name} if active[n]['targetType'] in ('staticLibrary','library')}
        require(set(settings.get('linkerFiles',[]))==archives and len(settings.get('linkerFiles',[]))==len(archives),'resolved setting changed: '+name+':linkerFiles')
        expected_flags = ['--singleobj'] if (
            active[name]['configuration'] in ('modeling', 'modeling-noai', 'with-render', 'web') and
            'vibe3d-mesh-ops' in seen and
            active['vibe3d-mesh-ops']['configuration'] in ('modeling', 'modeling-noai', 'with-render', 'web') and
            Path(compiler).name in ('ldc', 'ldc2')) else []
        for field,value in {'dflags':expected_flags, 'libs':['stb_image_c','m'] if 'd-stb-image' in seen else [],'lflags':['-L'+str(image/'build')] if 'd-stb-image' in seen else []}.items():
            actual=settings.get(field,[])
            if field=='lflags':
                actual=['-L'+str(Path(flag[2:]).resolve()) if flag.startswith('-L') and flag[2:] else flag for flag in actual]
                value=['-L'+str(Path(flag[2:]).resolve()) for flag in value]
            require(actual==value,'resolved setting changed: '+name+':'+field)
        for field in HOOKS+('injectSourceFiles','frameworks','extraDependencyFiles','copyFiles','stringImportPaths','cImportPaths'):
            expected=IMAGE_BUILD if name=='d-stb-image' and field=='preBuildCommands' else []
            require(settings.get(field,[])==expected,'resolved setting changed: '+name+':'+field)
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
    require(owner != 'vibe3d-core-tests' or args.unittest,
            'CORE executable construction requires --unittest; ordinary library evidence uses explicit support-owner recipes')
    config = args.config or ('core' if owner == 'vibe3d-core-tests' else 'application' if owner == 'vibe3d-cli' else 'modeling-noai')
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
    roots = validate_package_settings(description, root, compiler)
    # CORE constructs its mapped five roots directly. Library evidence belongs
    # to the explicit support-owner recipes, without an ordinary redirect.
    build_root = root
    build_config = config
    command = ['dub', 'test' if args.unittest else 'build', '--root=' + str(build_root),
               '--config=' + build_config, '--compiler=' + compiler, '--force', '--verbose']
    result = run(command, root, env, evidence, 'build-run')
    output = result.stdout + result.stderr
    require(result.returncode == 0, 'DUB build/runtime failed: ' +
            next((line for line in output.splitlines() if 'Error:' in line or 'AssertError@' in line), 'see build-run logs'))
    total = validate_runtime(output) if args.unittest else None
    import check_package_support_boundary as support
    try:commands=support.compiler_commands(output,build_root)
    except support.BoundaryError as error:raise BoundaryError(str(error))
    actual_inputs={}
    for invocation in commands:
        for path in invocation['sourceInputs']:
            actual_inputs[path]=hashlib.sha256(Path(path).read_bytes()).hexdigest()
    if args.unittest:
        selected=[c for c in commands if str(roots[0]) in c['sourceInputs']]
        require(len(selected)==1, 'CORE actual compiler owner exactly once')
        compiled=selected[0]
        generated=[p for p in compiled['sourceInputs'] if Path(p).name=='dub_test_root.d']
        target=next(t for t in description['targets'] if t['rootPackage']==owner)
        expected_sources=[str(Path(p).resolve()) for p in target['buildSettings']['sourceFiles']]+generated
        require(len(generated)==1 and sorted(compiled['sourceInputs'])==sorted(expected_sources) and len(compiled['sourceInputs'])==len(set(compiled['sourceInputs'])),
                'CORE actual compiler source identity')
        require(any(x in ('-unittest','--unittest') for x in compiled['argv']), 'CORE uniform unittest source emission')
        require(not any(x=='-i' or x.startswith(('-i=','--include-imports','-include-imports')) for x in compiled['argv']), 'CORE actual include-import refusal')
        require(not any('libvibe3d-' in Path(a).name for c in commands for a in c['archiveInputs']), 'CORE actual overlapping internal archives')
    (evidence/'actual-compiler-argv.json').write_text(json.dumps(commands,indent=2)+'\n')
    (evidence/'actual-input-hashes.json').write_text(json.dumps(actual_inputs,indent=2)+'\n')

    binary = build_root / ('vibe3d-core-tests-test-' + config if args.unittest else
                           'lib'+owner+'.a' if owner in ('vibe3d-command-runtime','vibe3d-application-core') else owner)
    require(binary.is_file(), 'fresh DUB output missing: ' + str(binary))
    revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root, text=True, capture_output=True)
    sha = revision.stdout.strip() if revision.returncode == 0 else 'uncommitted-copy'
    witness = {'mode': mode, 'sha': sha, 'compiler': compiler, 'resolvedCompiler': str(Path(compiler).resolve()), 'sources': list(map(str, roots)),
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
