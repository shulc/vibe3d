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
    def settings(self):
        root = Path('/fixture/tests/core')
        description = {
            'rootPackage': 'vibe3d-core-tests',
            'targets': [{'buildSettings': {
                'sourceFiles': ['/fixture/tests/unit/' + name for name in boundary.CORE_ROOTS],
                'dflags': ['-i'], 'importPaths': ['/fixture/source', '/fixture'],
            }}],
            'packages': [{'active': True, 'dependencies': []}],
        }
        return root, description

    def reject_settings(self, description, message):
        with self.assertRaisesRegex(boundary.BoundaryError, message):
            boundary.validate_settings(description, Path('/fixture/tests/core'))

    def test_independent_settings(self):
        root, description = self.settings()
        settings, sources = boundary.validate_settings(description, root)
        self.assertEqual(len(sources), 3)
        self.assertEqual(settings['dflags'], ['-i'])
        cases = [
            ('targets', [], 'target population'),
            ('rootPackage', 'vibe3d', 'root package'),
            ('packages', [{'active': True, 'dependencies': ['vibe3d']}], 'no package dependencies'),
            ('packages', [{'active': True}, {'active': True}], 'no package dependencies'),
        ]
        for field, value, error in cases:
            changed = copy.deepcopy(description)
            changed[field] = value
            self.reject_settings(changed, error)
        for field in ('preBuildCommands', 'postBuildCommands', 'preGenerateCommands',
                      'postGenerateCommands', 'preRunCommands', 'postRunCommands'):
            changed = copy.deepcopy(description)
            changed['packages'][0][field] = ['echo unsafe']
            self.reject_settings(changed, 'build hook')
        for field in ('libs', 'linkerFiles', 'lflags', 'frameworks'):
            changed = copy.deepcopy(description)
            changed['targets'][0]['buildSettings'][field] = ['calculation']
            self.reject_settings(changed, 'computational/native')
        for source, message in [([], 'root population'),
                                (['/fixture/source/' + name for name in boundary.CORE_ROOTS], 'existing tests/unit')]:
            changed = copy.deepcopy(description)
            changed['targets'][0]['buildSettings']['sourceFiles'] = source
            self.reject_settings(changed, message)
        for flag in ['-L/path/libplain.a', '-L/path/plain.o', '/path/plain.o', '-L-lcalculation']:
            changed = copy.deepcopy(description)
            changed['targets'][0]['buildSettings']['dflags'] = ['-i', flag]
            self.reject_settings(changed, 'native archive|dflags link input')
        for field, values in [('dflags', ['-i', '../../source/camera_stamp.d']),
                              ('injectSourceFiles', ['../../source/camera_stamp.d'])]:
            changed = copy.deepcopy(description)
            changed['targets'][0]['buildSettings'][field] = values
            self.reject_settings(changed, 'additional.*source roots')
        changed = copy.deepcopy(description)
        changed['targets'][0]['buildSettings']['dflags'] = []
        self.reject_settings(changed, 'import closure')

    def test_all_resolved_input_fields(self):
        for field in ('sourceFiles', 'injectSourceFiles', 'linkerFiles', 'libs', 'lflags',
                      'frameworks', 'extraDependencyFiles', 'copyFiles', 'dflags'):
            root, description = self.settings()
            # source roots also have their exact identity guard.
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

    def compiler_fixture(self):
        files = {str(Path('/fixture/lower' + str(i) + '.d')) for i in range(20)}
        modules = {name: '/fixture/' + name.replace('.', '/') + '.d' for name in boundary.KNOWN_MODULES}
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
        for module in ['shader', 'tool', 'registry', 'ui.panel', 'bindbc.sdl', 'http_server']:
            with self.assertRaisesRegex(boundary.BoundaryError, 'compiler module'):
                boundary.validate_compiler(dict(modules, **{module: '/outside/renamed.d'}), files, roots)

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
                'root (/project/root.d) : public : mesh (/project/source/mesh.d):Mesh\n')
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
            with self.assertRaisesRegex(boundary.BoundaryError, 'target population'):
                boundary.validate_settings(description, root)
            self.assertEqual((root / 'describe.stderr.log').read_text(), result.stderr)
            with self.assertRaisesRegex(boundary.BoundaryError, 'target population'):
                boundary.main(['--root', str(root), '--config', 'core', '--compiler', 'dmd'])

    def test_actual_explicit_root_population(self):
        root = Path('/fixture')
        compile_ = {'cwd': str(root), 'argv': ['-c', '-i', 'root.d', '-of=root.o']}
        sources = [root / 'root.d']
        boundary.validate_invocations([compile_], False, sources)
        for argv, with_tests in [(['-c', '-i', 'other.d'], False),
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
