#!/usr/bin/env python3
"""Witness independent DUB inputs and DMD's complete active import closure.

Task 20261720, application_layers_wave1_plan_2026-10-08.md CORE-TEST-TARGET.
Available files under an import search directory are not compilation inputs:
DUB lists them as importFiles; DMD -deps/-v identifies the files actually read.
Both compiler edge endpoints count, including template-attributed std edges.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

CORE_ROOTS = ('application_core_command_test.d', 'application_core_mesh_test.d',
              'command_invocation_test.d', 'command_registry_test.d', 'standalone_application_test.d')
CORE_CELLS = ('document-primary', 'invocation-order', 'invocation-outcomes', 'invocation-tweak',
              'mesh-cube', 'model-delivery', 'no-edit-target', 'pilot-live',
              'registry-authority', 'selected-triangle-refusal', 'session-carrier', 'standalone-no-target',
              'standalone-owner', 'triple-roundtrip')
KNOWN_MODULES = ('mesh', 'document', 'command', 'command_executor', 'command_history',
                 'commands.mesh.triple', 'commands.mesh.session_edit', 'command_registry',
                 'command_invocation', 'pilot_command_registration')
# Ownership bans apply equally to project modules, external files and link inputs.
BANNED_MODULES = {
    'tool', 'editor_app', 'app', 'registry', 'display_sync', 'shader',
    'mesh_gpu', 'gpu_select', 'subpatch_preview', 'subpatch_osd',
    'subpatch_osd_gpu', 'subpatch_osd_cpu', 'subpatch_factories',
    'subpatch_backend', 'http_server', 'http_providers', 'http_transport',
    'http_command_adapter', 'ut_runner', 'module_gate_lock_test',
}
BANNED_PREFIXES = ('ui.', 'handles.', 'tools.', 'bindbc.sdl', 'bindbc.opengl',
                   'imgui', 'nfde', 'tests.unit.http_', 'tests.unit.ut_runner')
BANNED_INPUT = re.compile(
    r'(?:^|[/_.\s=-])(?:sdl(?:2)?|opengl|gl|glx|egl|imgui|cimgui|nfde|nfd|x11|xcb|'
    r'wayland(?:-client)?|osd(?:cpu|gpu|c)?|opensubdiv|d-imgui|bindbc-sdl|bindbc-opengl)'
    r'(?:$|[/_.\s=-])', re.I)
EDGE = re.compile(r'([^\s():]+) \(([^)]+)\)')
IMPORT_FILE = re.compile(r'^import\s+(\S+)\s+\((.*)\)$', re.M)
FILE_IMPORT = re.compile(r'^file\s+.*?\((.*)\)$', re.M)


class BoundaryError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise BoundaryError(message)


def banned_module(module):
    return module in BANNED_MODULES or module.startswith(BANNED_PREFIXES)


def check_input(value, owners=(), runtime_registry=(), native_inputs=()):
    # Archive filenames use libSDL2.a rather than a module separator.
    normalized = re.sub(r'(^|/)(?:lib)(?=[A-Za-z])', r'\1', str(value))
    normalized = re.sub(r'(^|\s)(?:-L)?-l', r'\1', normalized)
    require(not BANNED_INPUT.search(normalized), 'forbidden resolved input: ' + str(value))
    require(not str(value).endswith('.a') or str(value).removeprefix('-L').removeprefix('-of').removeprefix('=') in native_inputs,
            'unexpected resolved native archive: ' + str(value) + ' PLAN-FINDING')
    basename = Path(str(value)).stem
    runtime_owner = (set(owners) == {'core.gc.registry'}
                     and str(Path(str(value)).resolve()) in runtime_registry)
    require(basename not in BANNED_MODULES or runtime_owner,
            'forbidden file owner: ' + str(value))
    components = Path(str(value)).parts
    require('ui' not in components and 'handles' not in components,
            'forbidden file owner: ' + str(value))


def compiler_inputs(deps, verbose, cwd):
    modules = {}
    files = set()
    for module, name in EDGE.findall(deps) + IMPORT_FILE.findall(verbose):
        name = str((cwd / name).resolve())
        modules[module] = name
        files.add(name)
    for name in FILE_IMPORT.findall(verbose):
        files.add(str((cwd / name).resolve()))
    return modules, files


def runtime_registry_inputs(verbose, compiler):
    # Only the selected compiler's initial defaults preamble grants runtime
    # ownership. Later pragma/runtime output and explicit -I paths cannot.
    preambles = re.findall(
        r'^predefs[^\n]*\nbinary[ \t]+([^\n]+)\nversion[^\n]*\n'
        r'config[^\n]*\nDFLAGS[ \t]+([^\n]*)\nparse[ \t]+', verbose, re.M)
    if not preambles:
        return set()
    binary, defaults = preambles[0]
    require(Path(binary.strip()).resolve() == Path(compiler).resolve(),
            'runtime defaults belong to a different compiler')
    for binary, repeated in preambles[1:]:
        require(Path(binary.strip()).resolve() == Path(compiler).resolve()
                and shlex.split(repeated) == shlex.split(defaults),
                'conflicting compiler defaults preamble')
    return {str((Path(flag[2:]) / 'core/gc/registry.d').resolve())
            for flag in shlex.split(defaults)
            if flag.startswith('-I') and (Path(flag[2:]) / 'core/gc/registry.d').is_file()}


def validate_inputs(modules, files, runtime_registry=()):
    for module, filename in modules.items():
        require(not banned_module(module), 'forbidden compiler module: ' + module + ' (' + filename + ')')
    for filename in files:
        owners = {module for module, path in modules.items() if path == filename}
        check_input(filename, owners, runtime_registry)


def validate_compiler(modules, files, roots, runtime_registry=()):
    validate_inputs(modules, files, runtime_registry)
    require(len(files) >= 20, 'compiler file population below 20')
    require(set(KNOWN_MODULES) <= set(modules), 'missing production Mesh/Document/Command compiler roots')
    require(set(map(str, roots)) <= files, 'explicit source roots missing from compiler file-set')


def validate_runtime(output):
    actual = re.findall(r'^CORE-CELL passed=(\S+)$', output, re.M)
    require(sorted(actual) == list(CORE_CELLS),
            'named-cell population: expected ' + repr(CORE_CELLS) + ', got ' + repr(actual))
    totals = re.findall(r'^(\d+) modules passed unittests$', output, re.M)
    require(len(totals) == 1 and int(totals[0]) > 0,
            'NO-VERDICT: missing nonzero druntime module total')
    return int(totals[0])


def validate_settings(description, root):
    settings, sources, _ = validate_package_settings(description, root, False)
    return settings, sources


def validate_invocations(invocations, with_tests, sources=None, native_inputs=()):
    compiled = [row for row in invocations if '-c' in row['argv'] and '-lib' not in row['argv']
                and any(p.startswith('-of') for p in row['argv'])]
    require(len(compiled) == 1, 'fresh independent compilation population must equal one')
    require(('-unittest' in compiled[0]['argv']) == with_tests,
            'production/unittest compiler flags disagree with requested closure')
    if sources is not None:
        compile_ = compiled[0]
        actual = {(Path(compile_['cwd']) / p).resolve() for p in compile_['argv']
                  if not p.startswith('-') and p.endswith(('.d', '.di', '.c', '.cpp'))}
        explicit = set(sources)
        extra = actual - explicit
        require((len(extra) == 1 and next(iter(extra)).name == 'dub_test_root.d')
                if with_tests else not extra,
                'actual compiler source-root population differs from explicit roots plus DUB main')
    outputs = {p[3:].removeprefix('=') for row in invocations for p in row['argv'] if p.startswith('-of')}
    for row in invocations:
        for argument in row['argv']:
            check_input(argument, native_inputs=native_inputs)
            if argument.endswith('.o') and not argument.startswith('-of'):
                require(argument in outputs, 'unexpected actual native object input: ' + argument)
    if with_tests:
        require(any(any(p.endswith('.o') for p in row['argv']) and '-c' not in row['argv']
                    for row in invocations), 'fresh DUB test link invocation missing')


def validate_link_output(output, object_outputs=(), native_inputs=()):
    for line in output.splitlines():
        if not re.match(r'^(?:[^ ]*/)?(?:cc|gcc|clang|c\+\+) ', line):
            continue
        for token in shlex.split(line):
            check_input(token, native_inputs=native_inputs)
            if token.endswith('.o'):
                require(token in object_outputs, 'unexpected linked native object: ' + token)
            if token.startswith('-l'):
                require(token[2:] in ({'phobos2', 'druntime', 'pthread', 'm', 'rt', 'dl', 'c', 'gcc', 'gcc_s'}
                         | ({'stb_image_c'} if native_inputs else set())),
                        'unexpected linked computational/native library: ' + token + ' PLAN-FINDING')



STB_REVISION = 'a66f6917718ea128076a2c5660e37f362a785144'


def validate_cli_settings(description, root):
    return validate_package_settings(description, root, True)


def validate_package_settings(description, root, cli):
    owner = 'vibe3d-cli' if cli else 'vibe3d-core-tests'
    require(description['rootPackage'] == owner, 'unexpected independent root package')
    active = {p['name']: p for p in description['packages'] if p.get('active')}
    require(set(active) == {owner, 'vibe3d-common', 'd-stb-image'},
            'independent package population must be consumer plus common plus pinned image')
    require(active[owner].get('dependencies') == ['vibe3d-common']
            and active['vibe3d-common'].get('dependencies') == ['d-stb-image']
            and not active['d-stb-image'].get('dependencies'),
            'independent resolved dependencies must be consumer -> common -> pinned image')
    common = (root.parents[1] / 'packages/common').resolve()
    require(Path(active[owner]['path']).resolve() == root
            and Path(active['vibe3d-common']['path']).resolve() == common,
            'resolved local package paths changed')
    manifest = json.loads((root / 'dub.json').read_text())
    shared = json.loads((common / 'dub.json').read_text())
    require(manifest.get('dependencies') == {'vibe3d-common': {'path': '../../packages/common'}},
            'consumer local common dependency changed')
    require(manifest.get('sourcePaths') == (['source'] if cli else [])
            and manifest.get('importPaths') == []
            and manifest.get('dflags') == ([] if cli else ['-i'])
            and manifest.get('subConfigurations') == {'vibe3d-common': 'modeling-noai'},
            'consumer source/import roots or flags changed')
    require(manifest.get('sourceFiles', []) == ([] if cli else ['../unit/' + n for n in CORE_ROOTS]),
            'explicit test-root population changed')
    require(shared.get('name') == 'vibe3d-common' and shared.get('targetType') == 'staticLibrary'
            and shared.get('sourcePaths') == ['source'], 'common source root or target changed')
    require(shared.get('dependencies') == {'d-stb-image': {
        'version': STB_REVISION, 'repository': 'git+https://github.com/shulc/D-StbImage.git'}},
        'common image dependency must retain exact pinned revision')
    hooks = ('preGenerateCommands', 'postGenerateCommands', 'preBuildCommands',
             'postBuildCommands', 'preRunCommands', 'postRunCommands')
    empty = ('importPaths', 'sourceFiles', 'injectSourceFiles', 'linkerFiles', 'libs', 'lflags',
             'frameworks', 'extraDependencyFiles', 'copyFiles', 'dflags', 'stringImportPaths')
    for descriptor, fields in ((shared, empty + hooks), (manifest, hooks + empty[2:8] + ('stringImportPaths',))):
        for key, value in descriptor.items():
            if key.split('-')[0] in fields:
                require(not value, 'forbidden explicit descriptor setting: ' + key)
    require(shared.get('configurations') == [
        {'name': 'modeling', 'versions': ['WithAI']},
        {'name': 'modeling-noai', 'versions': []},
        {'name': 'with-render', 'versions': ['WithRender', 'WithAI']},
        {'name': 'web', 'versions': ['web']}], 'common configuration versions changed')
    for config in manifest.get('configurations', []):
        require(set(config) == {'name'}, 'consumer configuration injects settings')
    image = Path(active['d-stb-image']['path']).resolve()
    require(STB_REVISION in image.parts, 'resolved image package revision differs from pinned dependency')
    native = {str(common / 'libvibe3d-common.a'), str(image / 'libd-stb-image.a'),
              str(image / 'build/libstb_image_c.a')}
    targets = description['targets']
    require(len(targets) == 3 and {t['rootPackage'] for t in targets} == set(active),
            'independent target population must equal three')
    settings = next(t['buildSettings'] for t in targets if t['rootPackage'] == owner)
    sources = [Path(p).resolve() for p in settings.get('sourceFiles', [])]
    require(sources == ([root / 'source/main.d'] if cli else
                        [(root.parent / 'unit' / name).resolve() for name in CORE_ROOTS]),
            'explicit roots must be actual CLI main or existing tests/unit modules')
    inventory = sorted(p.resolve() for p in (common / 'source').rglob('*.d'))
    require(len(inventory) >= 71, 'common production source population below 71')
    for target in targets:
        package = target['rootPackage']
        current = target['buildSettings']
        require(sorted(Path(p).resolve() for p in current.get('sourceFiles', [])) ==
                (inventory if package == 'vibe3d-common' else
                 [image / 'source/stb_image/c.d'] if package == 'd-stb-image' else sorted(sources)),
                'resolved production source inventory changed: ' + package)
        expected_imports = ([common / 'source', image / 'source'] if package != 'd-stb-image'
                            else [image / 'source'])
        require([Path(p).resolve() for p in current.get('importPaths', [])] == expected_imports,
                'resolved import roots grant unavailable source: ' + package)
        for key in ('sourceFiles', 'injectSourceFiles', 'linkerFiles', 'libs', 'lflags',
                    'frameworks', 'extraDependencyFiles', 'copyFiles', 'dflags'):
            for value in current.get(key, []):
                check_input(value, native_inputs=native)
        require(not current.get('injectSourceFiles') and not current.get('frameworks')
                and not current.get('extraDependencyFiles') and not current.get('copyFiles')
                and not current.get('stringImportPaths'), 'unexpected independent injected/native inputs')
        require(set(current.get('libs', [])) == {'stb_image_c', 'm'}
                and current.get('lflags', []) == ['-L' + str(image / 'build')],
                'unexpected independent computational/native link input: PLAN-FINDING')
        require(current.get('linkerFiles', []) ==
                ([str(common / 'libvibe3d-common.a'), str(image / 'libd-stb-image.a')] if package == owner
                 else [str(image / 'libd-stb-image.a')] if package == 'vibe3d-common' else []),
                'unexpected independent archive input')
        require(current.get('dflags', []) == (['-i'] if package == owner and not cli else []),
                'unexpected independent compiler flags')
    for package in (owner, 'vibe3d-common'):
        for field in hooks:
            require(not active[package].get(field), 'forbidden inherited build hook: ' + field)
    require(active['d-stb-image'].get('preBuildCommands') == [
        'cmake -B $PACKAGE_DIR/build -DCMAKE_GENERATOR=Ninja -DCMAKE_BUILD_TYPE=Release $PACKAGE_DIR',
        'cmake --build $PACKAGE_DIR/build --config Release'], 'pinned image build recipe changed')
    return settings, sources, native


def produced_image_archive(invocations, description):
    package = next(p for p in description['packages'] if p['name'] == 'd-stb-image')
    image = Path(package['path']).resolve()
    library = [row for row in invocations if '-lib' in row['argv']
               and any('source/stb_image/c.d' in p for p in row['argv'])]
    require(len(library) == 1, 'fresh pinned image archive compilation population must equal one')
    row = library[0]
    roots = {(Path(row['cwd']) / p).resolve() for p in row['argv']
             if not p.startswith('-') and p.endswith(('.d', '.di', '.c', '.cpp'))}
    require(roots == {image / 'source/stb_image/c.d'}, 'image archive has unexpected compiler roots')
    outputs = [p[3:].removeprefix('=') for p in row['argv'] if p.startswith('-of')]
    require(len(outputs) == 1, 'pinned image archive output population changed')
    output = Path(outputs[0]).resolve()
    cache = image.parents[3] / 'cache/d-stb-image/~master/build'
    require(output.is_relative_to(cache) and output.name == 'libd-stb-image.a',
            'image archive output is outside its actual DUB cache owner')
    require(output.is_file(), 'fresh pinned image archive output missing')
    return str(output)



def run(command, cwd, env, evidence, name, merge_stderr=True):
    result = subprocess.run(command, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT if merge_stderr else subprocess.PIPE)
    (evidence / (name + '.log')).write_text(result.stdout)
    if not merge_stderr:
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
    cli = (root / 'dub.json').is_file() and json.loads((root / 'dub.json').read_text()).get('name') == 'vibe3d-cli'
    require(not cli or not args.unittest, 'CLI acceptance is production-only; native private unittests remain desktop-only')
    config = args.config or ('application' if cli else 'core')
    mode = 'unittest' if args.unittest else 'production'
    evidence = Path(args.evidence_dir).resolve() if args.evidence_dir else root / '.boundary' / mode
    evidence.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for variable in ('DISPLAY', 'WAYLAND_DISPLAY', 'SDL_VIDEODRIVER', 'DFLAGS'):
        env.pop(variable, None)
    compiler = shutil.which(args.compiler)
    require(compiler is not None, 'compiler not found: ' + args.compiler)
    compiler = str(Path(compiler).resolve())
    describe_cmd = ['dub', 'describe', '--root=' + str(root), '--config=' + config,
                    '--compiler=' + compiler, '--quiet']
    described = run(describe_cmd, root, env, evidence, 'describe', merge_stderr=False)
    require(described.returncode == 0, 'DUB describe failed (see describe.log)')
    description = json.loads(described.stdout)
    (evidence / 'describe.json').write_text(json.dumps(description, indent=2) + '\n')
    native_inputs = set()
    if cli:
        settings, sources, native_inputs = validate_cli_settings(description, root)
    else:
        settings, sources, native_inputs = validate_package_settings(description, root, False)
    deps = evidence / 'compiler.deps'
    deps.unlink(missing_ok=True)
    commands = evidence / 'compiler-commands.jsonl'
    commands.write_text('')
    with tempfile.TemporaryDirectory(prefix='boundary-dmd-') as temporary:
        wrapper = Path(temporary) / 'dmd'
        wrapper.write_text('#!/usr/bin/env python3\nimport os,json,sys,shlex\nfrom pathlib import Path\n'
            'args=[]\n'
            'for token in sys.argv[1:]:\n'
            ' args.extend(shlex.split(Path(token[1:]).read_text()) if token.startswith("@") else [token])\n'
            'if "-c" in args or "-lib" in args: args += ["-deps=' + str(deps) + '","-v"]\n'
            'elif any(a.endswith(".o") for a in args): args += ["-v"]\n'
            'with open(' + repr(str(commands)) + ',"a") as out:\n'
            ' out.write(json.dumps({"cwd":os.getcwd(),"argv":args})+"\\n")\n'
            'os.execv(' + repr(compiler) + ',[' + repr(compiler) + ']+args)\n')
        wrapper.chmod(0o755)
        if args.unittest or cli:
            command = ['dub', 'test' if args.unittest else 'build', '--root=' + str(root), '--config=' + config,
                       '--compiler=' + str(wrapper), '--force', '-v']
        else:
            command = [str(wrapper), '-c', '-debug', '-g', '-w', '-i',
                       '-of=' + str(evidence / 'production.o')]
            command += ['-I' + p for p in settings.get('importPaths', [])]
            command += ['-J' + p for p in settings.get('stringImportPaths', [])]
            command += ['-version=' + p for p in settings.get('versions', [])]
            command += ['-debug=' + p for p in settings.get('debugVersions', [])]
            command += settings.get('dflags', []) + list(map(str, sources))
        result = run(command, root, env, evidence, 'build-run')
    require(result.returncode == 0, 'compiler/build/runtime failed: ' +
            next((line for line in result.stdout.splitlines() if 'Error:' in line
                  or 'AssertError@' in line), 'see build-run.log'))
    invocations = [json.loads(line) for line in commands.read_text().splitlines()]
    if cli or args.unittest:
        native_inputs.add(produced_image_archive(invocations, description))
        for row in invocations:
            if '-lib' in row['argv'] and any('/packages/common/source/' in p for p in row['argv']):
                native_inputs.update(str(Path(p[3:].removeprefix('=' )).resolve())
                                     for p in row['argv'] if p.startswith('-of'))
    object_outputs = {p[3:].removeprefix('=') for row in invocations if '-c' in row['argv']
                      for p in row['argv'] if p.startswith('-of')}
    modules, files = compiler_inputs(deps.read_text() if deps.is_file() else '', result.stdout, root)
    (evidence / 'compiler-inputs.json').write_text(json.dumps(
        {'modules': modules, 'files': sorted(files)}, indent=2) + '\n')
    validate_compiler(modules, files, sources, runtime_registry_inputs(result.stdout, compiler))
    require(deps.is_file(), 'NO-VERDICT: compiler did not emit dependencies')
    if cli:
        require({'standalone_application', 'io.native', 'io.file_model', 'stb_image.c'} <= set(modules),
                'missing standalone/native/compiler known roots')
    validate_link_output(result.stdout, object_outputs, native_inputs)
    require(result.returncode == 0, 'compiler/build/runtime failed (see build-run.log)')
    validate_invocations(invocations, args.unittest, sources, native_inputs)
    binary_hash = None
    total = None
    if args.unittest or cli:
        if args.unittest:
            total = validate_runtime(result.stdout)
        binary = root / ('vibe3d-cli' if cli else 'vibe3d-core-tests-test-' + config)
        require(binary.is_file(), 'fresh linked test binary missing')
        binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
        dynamic = run(['ldd', str(binary)], root, env, evidence, 'ldd')
        require(dynamic.returncode == 0, 'ldd failed')
        for line in dynamic.stdout.splitlines():
            check_input(line)
    revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    sha = revision.stdout.strip() if revision.returncode == 0 else 'uncommitted-copy'
    source_digest = hashlib.sha256()
    for filename in sorted(files):
        source_digest.update(filename.encode())
        source_digest.update(Path(filename).read_bytes())
    witness = {'mode': mode, 'sha': sha, 'compiler': compiler, 'fileCount': len(files),
               'nativeInputs': sorted(native_inputs),
               'binarySha256': binary_hash, 'sourceInputSha256': source_digest.hexdigest(),
               'druntimeModules': total,
               'namedCells': list(CORE_CELLS) if args.unittest else [],
               'command': command, 'describeCommand': describe_cmd}
    (evidence / 'witness.json').write_text(json.dumps(witness, indent=2) + '\n')
    print('BOUNDARY mode=' + mode + ' files=' + str(len(files)) + ' sha=' + sha
          + (' modules=' + str(total) + ' cells=' + str(len(CORE_CELLS)) + ' binary-sha256=' + binary_hash if args.unittest else (' binary-sha256=' + binary_hash if cli else '')))
    print('BOUNDARY-VERDICT=GREEN')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (BoundaryError, OSError, ValueError, KeyError) as error:
        print('BOUNDARY-VERDICT=RED Error: ' + str(error), file=sys.stderr)
        sys.exit(1)
