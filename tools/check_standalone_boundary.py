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
              'command_invocation_test.d', 'command_registry_test.d')
CORE_CELLS = ('document-primary', 'invocation-order', 'invocation-outcomes', 'invocation-tweak',
              'mesh-cube', 'model-delivery', 'no-edit-target', 'pilot-live',
              'registry-authority', 'selected-triangle-refusal', 'session-carrier', 'triple-roundtrip')
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


def check_input(value):
    # Archive filenames use libSDL2.a rather than a module separator.
    normalized = re.sub(r'(^|/)(?:lib)(?=[A-Za-z])', r'\1', str(value))
    normalized = re.sub(r'(^|\s)(?:-L)?-l', r'\1', normalized)
    require(not BANNED_INPUT.search(normalized), 'forbidden resolved input: ' + str(value))
    require(not str(value).endswith('.a'),
            'unexpected resolved native archive: ' + str(value) + ' PLAN-FINDING')
    basename = Path(str(value)).stem
    require(basename not in BANNED_MODULES, 'forbidden file owner: ' + str(value))
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


def validate_compiler(modules, files, roots):
    for module, filename in modules.items():
        require(not banned_module(module), 'forbidden compiler module: ' + module + ' (' + filename + ')')
    for filename in files:
        check_input(filename)
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
    targets = description['targets']
    require(len(targets) == 1, 'independent target population must equal one')
    settings = targets[0]['buildSettings']
    sources = [Path(p).resolve() for p in settings.get('sourceFiles', [])]
    require(sorted(p.name for p in sources) == sorted(CORE_ROOTS),
            'explicit test-root population changed: ' + repr([p.name for p in sources]))
    require(sources == [(root.parent / 'unit' / name).resolve() for name in CORE_ROOTS],
            'explicit test roots must be existing tests/unit modules')
    require(description['rootPackage'] == 'vibe3d-core-tests', 'unexpected independent root package')
    active = [p for p in description['packages'] if p.get('active')]
    require(len(active) == 1 and not active[0].get('dependencies'),
            'core target must have no package dependencies')
    for package in active:
        for field in ('preGenerateCommands', 'postGenerateCommands', 'preBuildCommands',
                      'postBuildCommands', 'preRunCommands', 'postRunCommands'):
            require(not package.get(field), 'forbidden inherited build hook: ' + field)
    for key in ('sourceFiles', 'injectSourceFiles', 'linkerFiles', 'libs', 'lflags',
                'frameworks', 'extraDependencyFiles', 'copyFiles', 'dflags'):
        for value in settings.get(key, []):
            check_input(value)
    # No native libraries are needed by this Mesh/Document stage. Treat a new
    # computational link input as a finding rather than copying desktop flags.
    require(not settings.get('libs') and not settings.get('linkerFiles')
            and not settings.get('lflags') and not settings.get('frameworks'),
            'unexpected core computational/native link input: PLAN-FINDING')
    require(not any(p.startswith(('-L', '-l', '-Xcc', '-Xlinker')) or p.endswith('.o')
                    for p in settings.get('dflags', [])),
            'unexpected core dflags link input: PLAN-FINDING')
    require(not settings.get('injectSourceFiles'), 'additional injected core source roots')
    require(all(p.startswith('-') for p in settings.get('dflags', [])),
            'additional positional core source roots in dflags')
    require('-i' in settings.get('dflags', []), 'independent build must compile import closure with -i')
    return settings, sources


def validate_invocations(invocations, with_tests, sources=None):
    compiled = [row for row in invocations if '-c' in row['argv'] and '-i' in row['argv']]
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
    outputs = {p[3:].removeprefix('=') for row in compiled for p in row['argv'] if p.startswith('-of')}
    for row in invocations:
        for argument in row['argv']:
            check_input(argument)
            if argument.endswith('.o') and not argument.startswith('-of'):
                require(argument in outputs, 'unexpected actual native object input: ' + argument)
    if with_tests:
        require(any(any(p.endswith('.o') for p in row['argv']) and '-c' not in row['argv']
                    for row in invocations), 'fresh DUB test link invocation missing')


def validate_link_output(output, object_outputs=()):
    for line in output.splitlines():
        if not re.match(r'^(?:[^ ]*/)?(?:cc|gcc|clang|c\+\+) ', line):
            continue
        for token in shlex.split(line):
            check_input(token)
            if token.endswith('.o'):
                require(token in object_outputs, 'unexpected linked native object: ' + token)
            if token.startswith('-l'):
                require(token[2:] in {'phobos2', 'druntime', 'pthread', 'm', 'rt', 'dl', 'c', 'gcc', 'gcc_s'},
                        'unexpected linked computational/native library: ' + token + ' PLAN-FINDING')


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
    parser.add_argument('--config', default='core')
    parser.add_argument('--compiler', default='dmd')
    parser.add_argument('--unittest', action='store_true')
    parser.add_argument('--evidence-dir')
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    mode = 'unittest' if args.unittest else 'production'
    evidence = Path(args.evidence_dir).resolve() if args.evidence_dir else root / '.boundary' / mode
    evidence.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for variable in ('DISPLAY', 'WAYLAND_DISPLAY', 'SDL_VIDEODRIVER', 'DFLAGS'):
        env.pop(variable, None)
    compiler = shutil.which(args.compiler)
    require(compiler is not None, 'compiler not found: ' + args.compiler)
    compiler = str(Path(compiler).resolve())
    describe_cmd = ['dub', 'describe', '--root=' + str(root), '--config=' + args.config,
                    '--compiler=' + compiler, '--quiet']
    described = run(describe_cmd, root, env, evidence, 'describe', merge_stderr=False)
    require(described.returncode == 0, 'DUB describe failed (see describe.log)')
    description = json.loads(described.stdout)
    (evidence / 'describe.json').write_text(json.dumps(description, indent=2) + '\n')
    settings, sources = validate_settings(description, root)
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
            'if "-c" in args and "-i" in args: args += ["-deps=' + str(deps) + '","-v"]\n'
            'elif any(a.endswith(".o") for a in args): args += ["-v"]\n'
            'with open(' + repr(str(commands)) + ',"a") as out:\n'
            ' out.write(json.dumps({"cwd":os.getcwd(),"argv":args})+"\\n")\n'
            'os.execv(' + repr(compiler) + ',[' + repr(compiler) + ']+args)\n')
        wrapper.chmod(0o755)
        if args.unittest:
            command = ['dub', 'test', '--root=' + str(root), '--config=' + args.config,
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
    invocations = [json.loads(line) for line in commands.read_text().splitlines()]
    object_outputs = {p[3:].removeprefix('=') for row in invocations if '-c' in row['argv']
                      for p in row['argv'] if p.startswith('-of')}
    modules, files = compiler_inputs(deps.read_text() if deps.is_file() else '', result.stdout, root)
    (evidence / 'compiler-inputs.json').write_text(json.dumps(
        {'modules': modules, 'files': sorted(files)}, indent=2) + '\n')
    validate_compiler(modules, files, sources)
    require(deps.is_file(), 'NO-VERDICT: compiler did not emit dependencies')
    validate_link_output(result.stdout, object_outputs)
    require(result.returncode == 0, 'compiler/build/runtime failed (see build-run.log)')
    validate_invocations(invocations, args.unittest, sources)
    binary_hash = None
    total = None
    if args.unittest:
        total = validate_runtime(result.stdout)
        binary = root / ('vibe3d-core-tests-test-' + args.config)
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
               'binarySha256': binary_hash, 'sourceInputSha256': source_digest.hexdigest(),
               'druntimeModules': total,
               'namedCells': list(CORE_CELLS) if args.unittest else [],
               'command': command, 'describeCommand': describe_cmd}
    (evidence / 'witness.json').write_text(json.dumps(witness, indent=2) + '\n')
    print('BOUNDARY mode=' + mode + ' files=' + str(len(files)) + ' sha=' + sha
          + (' modules=' + str(total) + ' cells=' + str(len(CORE_CELLS)) + ' binary-sha256=' + binary_hash if args.unittest else ''))
    print('BOUNDARY-VERDICT=GREEN')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (BoundaryError, OSError, ValueError, KeyError) as error:
        print('BOUNDARY-VERDICT=RED Error: ' + str(error), file=sys.stderr)
        sys.exit(1)
