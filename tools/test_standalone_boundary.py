#!/usr/bin/env python3
"""Discriminating controls for the standalone input/edge/population checker."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import check_standalone_boundary as boundary


class BoundaryControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='boundary-settings-')
        cls.project = Path(cls.temporary.name)
        actual = Path(__file__).resolve().parents[1]
        for relative in ('tools/cli/dub.json', 'tests/core/dub.json', 'packages/common/dub.json'):
            path = cls.project / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(actual / relative, path)
        for path in (actual / 'packages/common/source').rglob('*.d'):
            target = cls.project / path.relative_to(actual)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(path.read_bytes())
        cls.descriptions = {}
        for relative in ('tests/core', 'tools/cli'):
            result = subprocess.run(['dub', 'describe', '--root=' + str(actual / relative),
                '--compiler=dmd', '--quiet'], text=True, capture_output=True, check=True)
            cls.descriptions[relative] = json.loads(result.stdout.replace(str(actual), str(cls.project)))

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def settings(self):
        return self.project / 'tests/core', copy.deepcopy(self.descriptions['tests/core'])

    def reject_settings(self, description, message):
        with self.assertRaisesRegex(boundary.BoundaryError, message):
            boundary.validate_settings(description, self.project / 'tests/core')

    def test_independent_settings(self):
        root, description = self.settings()
        settings, sources = boundary.validate_settings(description, root)
        self.assertEqual(len(sources), 5)
        self.assertEqual(settings['dflags'], ['-i'])
        for mutate, message in [
            (lambda d: d.update(targets=[]), 'target population'),
            (lambda d: d.update(rootPackage='vibe3d'), 'root package'),
            (lambda d: d['packages'][0]['dependencies'].append('vibe3d'), 'resolved dependencies'),
            (lambda d: d['packages'].pop(), 'package population'),
            (lambda d: d['targets'][0]['buildSettings'].update(sourceFiles=[]), 'explicit roots'),
            (lambda d: d['targets'][0]['buildSettings']['importPaths'].append(str(self.project / 'source')),
                'resolved import roots'),
            (lambda d: d['targets'][0]['buildSettings']['libs'].append('calculation'), 'computational/native'),
            (lambda d: d['targets'][0]['buildSettings'].update(dflags=[]), 'compiler flags'),
        ]:
            changed = copy.deepcopy(description)
            mutate(changed)
            self.reject_settings(changed, message)
        for field in ('preBuildCommands', 'postBuildCommands', 'preGenerateCommands',
                      'postGenerateCommands', 'preRunCommands', 'postRunCommands'):
            changed = copy.deepcopy(description)
            changed['packages'][0][field] = ['echo unsafe']
            self.reject_settings(changed, 'build hook')

    def test_common_descriptor_grants(self):
        root, description = self.settings()
        path = self.project / 'packages/common/dub.json'
        original = path.read_text()
        try:
            for key, value in [('importPaths', ['../../source']), ('dflags', ['-I../../source']),
                               ('sourceFiles', ['../../source/registry.d']),
                               ('preBuildCommands', ['echo unsafe']),
                               ('libs-linux', ['calculation'])]:
                changed = json.loads(original)
                changed[key] = value
                path.write_text(json.dumps(changed))
                self.reject_settings(description, 'forbidden explicit descriptor setting')
            changed = json.loads(original)
            changed['dependencies']['vibe3d'] = {'path': '../..'}
            path.write_text(json.dumps(changed))
            self.reject_settings(description, 'exact pinned revision')
        finally:
            path.write_text(original)

    def test_all_resolved_input_fields(self):
        for field in ('sourceFiles', 'injectSourceFiles', 'linkerFiles', 'libs', 'lflags',
                      'frameworks', 'extraDependencyFiles', 'copyFiles', 'dflags'):
            root, description = self.settings()
            if field == 'sourceFiles':
                continue
            description['targets'][0]['buildSettings'][field] = ['libSDL2.a']
            self.reject_settings(description, 'forbidden resolved input')
        for text in ['/any/libSDL2.a', '-lGL', '-L-lSDL2', '/any/d_imgui/libcimgui.a',
                     '/x/bindbc/opengl/package.d', '/x/source/ui/panel.d', '/x/source/shader.d',
                     '/x/nfde/bin/libnfde.a', 'X11', 'wayland-client']:
            with self.assertRaises(boundary.BoundaryError, msg=text):
                boundary.check_input(text)
        boundary.check_input('/std/core/sys/posix/pthread.d')

    def test_cli_resolved_settings(self):
        root = self.project / 'tools/cli'
        description = copy.deepcopy(self.descriptions['tools/cli'])
        _, roots, native = boundary.validate_cli_settings(description, root)
        self.assertEqual(roots, [root / 'source/main.d'])
        self.assertEqual(len(native), 3)
        for mutate, message in [
            (lambda d: d['packages'][0]['dependencies'].append('vibe3d'), 'resolved dependencies'),
            (lambda d: d['targets'][0]['buildSettings']['libs'].append('SDL2'), 'forbidden resolved'),
            (lambda d: d['targets'][0]['buildSettings']['linkerFiles'].append('/x/libSDL2.a'), 'forbidden resolved'),
            (lambda d: d['targets'][0]['buildSettings']['libs'].append('calculation'), 'computational/native'),
            (lambda d: d['targets'][0]['buildSettings']['sourceFiles'].append('/x/extra.d'), 'explicit roots')]:
            changed = copy.deepcopy(description)
            mutate(changed)
            with self.assertRaisesRegex(boundary.BoundaryError, message):
                boundary.validate_cli_settings(changed, root)
        with self.assertRaisesRegex(boundary.BoundaryError, 'unexpected resolved native archive'):
            boundary.check_input('/x/other.a', native_inputs=native)

    def compiler_fixture(self):
        files = {str(Path('/fixture/lower' + str(i) + '.d')) for i in range(20)}
        modules = {name: '/fixture/' + name.replace('.', '/') + '.d' for name in boundary.KNOWN_MODULES}
        # These two requirements have independent fixtures, so deleting their
        # metadata entries cannot also delete the negative controls.
        for name in ('command_invocation', 'pilot_command_registration'):
            modules[name] = '/fixture/' + name + '.d'
        files.update(modules.values())
        roots = [Path('/fixture/root.d')]
        files.add(str(roots[0]))
        return modules, files, roots

    def test_compiler_population_and_ownership(self):
        modules, files, roots = self.compiler_fixture()
        boundary.validate_compiler(modules, files, roots)
        for changed_files, changed_modules, changed_roots, message in [
            (set(), modules, roots, 'below 20'),
            (files, {}, roots, 'Mesh/Document'),
            (files, modules, [Path('/absent.d')], 'explicit source roots'),
            (files | {'/outside/source/shader.d'}, modules, roots, 'file owner'),
        ]:
            with self.assertRaisesRegex(boundary.BoundaryError, message):
                boundary.validate_compiler(changed_modules, changed_files, changed_roots)
        for name in ('command_invocation', 'pilot_command_registration'):
            without = dict(modules)
            del without[name]
            with self.assertRaisesRegex(boundary.BoundaryError, 'Mesh/Document'):
                boundary.validate_compiler(without, files, roots)
        for module in ['shader', 'tool', 'registry', 'ui.panel', 'bindbc.sdl', 'http_server']:
            with self.assertRaisesRegex(boundary.BoundaryError, 'compiler module'):
                boundary.validate_compiler(dict(modules, **{module: '/outside/renamed.d'}), files, roots)

    def test_runtime_registry_ownership(self):
        modules, files, roots = self.compiler_fixture()
        runtime = str((Path(shutil.which('dmd')).resolve().parents[2]
                       / 'src/druntime/import/core/gc/registry.d').resolve())
        self.assertTrue(Path(runtime).is_file())
        actual = dict(modules, **{'core.gc.registry': runtime})
        boundary.validate_compiler(actual, files | {runtime}, roots, {runtime})
        for changed_modules, changed_files, runtime_inputs, message in [
            (dict(modules, registry=runtime), files | {runtime}, {runtime}, 'compiler module'),
            (dict(modules, registry='/fixture/renamed.d'), files, {runtime}, 'compiler module'),
            (dict(modules, **{'core.gc.registry': '/fixture/core/gc/registry.d'}),
             files | {'/fixture/core/gc/registry.d'}, {runtime}, 'file owner'),
            (modules, files | {runtime}, {runtime}, 'file owner'),
            (actual, files | {runtime}, set(), 'file owner'),
        ]:
            with self.assertRaisesRegex(boundary.BoundaryError, message):
                boundary.validate_compiler(changed_modules, changed_files, roots, runtime_inputs)
        compiler = str(Path(shutil.which('dmd')).resolve())
        def preamble(flags, binary=compiler):
            return ('predefs DigitalMars\nbinary ' + binary + '\nversion v2\n'
                    'config compiler.conf\nDFLAGS ' + flags + '\nparse fixture\n')
        flags = '-I' + str(Path(runtime).parents[2])
        defaults = preamble(flags)
        self.assertEqual(boundary.runtime_registry_inputs(defaults, compiler), {runtime})
        self.assertEqual(boundary.runtime_registry_inputs(defaults + defaults, compiler), {runtime})
        self.assertEqual(boundary.runtime_registry_inputs('', compiler), set())
        self.assertEqual(boundary.runtime_registry_inputs('DFLAGS ' + flags + '\n', compiler), set())
        self.assertEqual(boundary.runtime_registry_inputs(preamble('-X' + str(Path(runtime).parents[2])), compiler), set())
        self.assertEqual(boundary.runtime_registry_inputs(preamble('-I/fixture/absent'), compiler), set())
        with self.assertRaisesRegex(boundary.BoundaryError, 'different compiler'):
            boundary.runtime_registry_inputs(preamble(flags, '/fixture/other-dmd'), compiler)
        with tempfile.TemporaryDirectory(prefix='runtime-owner-') as temporary:
            spoof = Path(temporary) / 'core/gc/registry.d'
            spoof.parent.mkdir(parents=True)
            spoof.write_text('module core.gc.registry;')
            forged = '-I' + temporary
            grant = boundary.runtime_registry_inputs(defaults + 'DFLAGS ' + forged + '\n', compiler)
            self.assertEqual(grant, {runtime})
            with self.assertRaisesRegex(boundary.BoundaryError, 'file owner'):
                boundary.validate_compiler(dict(modules, **{'core.gc.registry': str(spoof)}),
                                           files | {str(spoof)}, roots, grant)
            with self.assertRaisesRegex(boundary.BoundaryError, 'conflicting compiler defaults'):
                boundary.runtime_registry_inputs(defaults + preamble(forged), compiler)
            with self.assertRaisesRegex(boundary.BoundaryError, 'conflicting compiler defaults'):
                boundary.runtime_registry_inputs(defaults + preamble(flags, '/fixture/other-dmd'), compiler)
        for owners in (set(), {'synthetic'}, {'core.gc.registry', 'synthetic'}):
            with self.assertRaisesRegex(boundary.BoundaryError, 'file owner'):
                boundary.check_input(runtime, owners, {runtime})

    def test_runtime_population(self):
        good = '11 modules passed unittests\n' + ''.join('CORE-CELL passed=' + name + '\n' for name in boundary.CORE_CELLS)
        self.assertEqual(boundary.validate_runtime(good), 11)
        for output in [good.replace('CORE-CELL passed=mesh-cube\n', ''),
                       good + 'CORE-CELL passed=mesh-cube\n',
                       good.replace('mesh-cube', 'unknown'),
                       good.replace('11 modules', '0 modules'),
                       good.replace('11 modules passed unittests\n', ''),
                       good + '11 modules passed unittests\n']:
            with self.assertRaises(boundary.BoundaryError):
                boundary.validate_runtime(output)

    def test_actual_compiler_and_link_invocations(self):
        compile_ = {'argv': ['-c', '-i', 'root.d', '-of=root.o']}
        link = {'argv': ['root.o', '-of=binary']}
        boundary.validate_invocations([compile_], False)
        boundary.validate_invocations([{'argv': ['-c', '-i', 'root.d', '-ofroot.o']}, link], False)
        boundary.validate_invocations([{'argv': compile_['argv'] + ['-unittest']}, link], True)
        for rows, with_tests in [([compile_, link], True),
                                  ([{'argv': compile_['argv'] + ['-unittest']}], False),
                                  ([compile_, {'argv': ['foreign.o']}], False),
                                  ([], False), ([compile_, compile_], False),
                                  ([compile_], True), ([{'argv': compile_['argv'] + ['-unittest']}], True),
                                  ([compile_, {'argv': ['root.o', '-L-lSDL2']}], False)]:
            with self.assertRaises(boundary.BoundaryError):
                boundary.validate_invocations(rows, with_tests)
        boundary.validate_link_output('cc root.o -lphobos2 -lpthread -lm\n', {'root.o'})
        for output in ['cc root.o -lSDL2\n', '/usr/bin/gcc -lcalculation\n', 'cc /external/plain.o\n', 'cc /external/libplain.a\n']:
            with self.assertRaises(boundary.BoundaryError):
                boundary.validate_link_output(output)

    def test_template_attributed_compiler_endpoints(self):
        deps = ('std.traits (/external/std/traits.d) : private : shader (/project/source/shader.d):member\n'
                'root (/project/root.d) : public : mesh (/project/packages/common/source/mesh.d):Mesh\n')
        modules, files = boundary.compiler_inputs(deps, 'import static_helper (helper.d)\n', Path('/project'))
        self.assertEqual(set(modules), {'std.traits', 'shader', 'root', 'mesh', 'static_helper'})
        self.assertEqual(len(files), 5)
        self.assertIn('/project/source/shader.d', files)

    def test_empty_root_describe_warning_is_not_json(self):
        with tempfile.TemporaryDirectory(prefix='boundary-empty-') as temporary:
            root = Path(temporary)
            (root / 'dub.json').write_text(json.dumps({
                'name': 'vibe3d-core-tests', 'targetType': 'executable',
                'sourcePaths': [], 'sourceFiles': [], 'configurations': [{'name': 'core'}],
            }))
            result = boundary.run(['dub', 'describe', '--root=' + str(root),
                '--config=core', '--compiler=dmd', '--quiet'], root, os.environ.copy(),
                root, 'describe', merge_stderr=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('no source files', result.stderr)
            description = json.loads(result.stdout)
            with self.assertRaisesRegex(boundary.BoundaryError, 'package population'):
                boundary.validate_settings(description, root)
            self.assertEqual((root / 'describe.stderr.log').read_text(), result.stderr)
            with self.assertRaisesRegex(boundary.BoundaryError, 'package population'):
                boundary.main(['--root', str(root), '--config', 'core', '--compiler', 'dmd'])

    def test_actual_explicit_root_population(self):
        root = Path('/fixture')
        compile_ = {'cwd': str(root), 'argv': ['-c', '-i', 'root.d', '-of=root.o']}
        sources = [root / 'root.d']
        boundary.validate_invocations([compile_], False, sources)
        for argv, with_tests in [(['-c', '-i', 'other.d', '-of=other.o'], False),
                                  (compile_['argv'] + ['other.d'], False),
                                  (compile_['argv'] + ['foreign.c'], False),
                                  (compile_['argv'] + ['-unittest'], True),
                                  (compile_['argv'] + ['-unittest', 'dub_test_root.d', 'other.d'], True)]:
            rows = [{'cwd': str(root), 'argv': argv}, {'argv': ['root.o']}]
            with self.assertRaisesRegex(boundary.BoundaryError, 'source.root|source roots'):
                boundary.validate_invocations(rows, with_tests, sources)
        rows = [{'cwd': str(root), 'argv': compile_['argv'] + ['-unittest', 'dub_test_root.d']},
                {'argv': ['root.o']}]
        boundary.validate_invocations(rows, True, sources)

    def test_verbose_only_file_input(self):
        modules, files = boundary.compiler_inputs('', 'file payload (payload.txt)\n', Path('/fixture'))
        self.assertEqual(files, {'/fixture/payload.txt'})
        self.assertEqual(modules, {})

    def test_actual_dmd_edge_forms_and_string_import(self):
        compiler = shutil.which('dmd')
        self.assertIsNotNone(compiler)
        with tempfile.TemporaryDirectory(prefix='boundary-parser-') as temporary:
            root = Path(temporary)
            (root / 'main.d').write_text('module main; public import helper : symbol;\n'
                'static import extra;\nvoid local() { import nested; }\n'
                'version(unittest) { import only_test; }\n'
                'enum content = import("payload.txt");\n')
            for name in ('helper', 'extra', 'nested', 'only_test'):
                (root / (name + '.d')).write_text('module ' + name + '; int symbol;\n')
            (root / 'payload.txt').write_text('fixture')
            for with_tests in (False, True):
                command = [compiler, '-c', '-i', '-v', '-J' + str(root), '-I' + str(root),
                           '-deps=' + str(root / 'deps'), '-of=' + str(root / 'probe.o'), str(root / 'main.d')]
                if with_tests:
                    command += ['-unittest']
                built = subprocess.run(command, cwd=root, text=True, capture_output=True)
                self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
                modules, files = boundary.compiler_inputs((root / 'deps').read_text(), built.stdout, root)
                self.assertTrue({'helper', 'extra', 'nested'} <= set(modules))
                self.assertEqual('only_test' in modules, with_tests)
                self.assertIn(str(root / 'payload.txt'), files)


if __name__ == '__main__':
    unittest.main()
