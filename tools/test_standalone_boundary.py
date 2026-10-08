#!/usr/bin/env python3
"""Discriminating controls for the standalone input/edge/population checker."""
import copy
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
                'sourceFiles': ['/fixture/tests/unit/application_core_mesh_test.d'],
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
        self.assertEqual(len(sources), 1)
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
                                (['/fixture/source/application_core_mesh_test.d'], 'existing tests/unit')]:
            changed = copy.deepcopy(description)
            changed['targets'][0]['buildSettings']['sourceFiles'] = source
            self.reject_settings(changed, message)
        for flag in ['-L/path/libplain.a', '-L/path/plain.o', '/path/plain.o', '-L-lcalculation']:
            changed = copy.deepcopy(description)
            changed['targets'][0]['buildSettings']['dflags'] = ['-i', flag]
            self.reject_settings(changed, 'native archive|dflags link input')
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
        modules = {'mesh': '/fixture/mesh.d', 'document': '/fixture/document.d'}
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
        good = '11 modules passed unittests\nCORE-CELL passed=mesh-cube\nCORE-CELL passed=document-primary\n'
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
        for rows, with_tests in [([], False), ([compile_, compile_], False),
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
