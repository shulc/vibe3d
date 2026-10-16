#!/usr/bin/env python3
"""Controls for the retained DUB grants and exact CORE runtime witness."""
import ast
import copy
import os
import shlex
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import ci.preflight as preflight
import check_standalone_boundary as boundary
import check_package_support_boundary as support


class BoundaryControls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='boundary-settings-')
        cls.project = Path(cls.temporary.name)
        actual = Path(__file__).resolve().parents[1]
        cls.descriptions = {}
        for relative in boundary.DESCRIPTORS:
            target = cls.project / relative / 'dub.json'
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(actual / relative / 'dub.json', target)
            result = subprocess.run(['dub', 'describe', '--root=' + str(actual / relative),
                '--config=' + ('modeling-noai' if relative in ('packages/command-runtime', 'packages/application-core') else 'core'
                               if relative == 'tests/core' else 'application'),
                '--compiler=dmd', '--quiet'], text=True, capture_output=True, check=True)
            cls.descriptions[relative] = json.loads(result.stdout.replace(str(actual), str(cls.project)))
        for spec in support.SPECS.values():
            target=cls.project/spec['root']/'dub.json'
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(actual/spec['root']/'dub.json',target)
        core = json.loads((actual/'tests/core/dub.json').read_text())
        source_paths = [p for spec in support.SPECS.values() for p in (actual/spec['root']/'source').rglob('*.d')]
        source_paths += [(actual/'tests/core'/p).resolve() for p in core['sourceFiles']]
        for path in source_paths:
            target = cls.project / path.relative_to(actual)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_renderer_native_formatter(self):
        # Real DUB is the independent formatter; only recipe/pkg-config data
        # belong to this fixture. Execute the production expectation and guard.
        with tempfile.TemporaryDirectory(prefix='boundary-native-format-') as directory:
            root=Path(directory);pc=root/'pkgconfig';pc.mkdir()
            (root/'entry.d').write_text('module entry; void main() {}\n')
            env=os.environ.copy();env.pop('DFLAGS',None)
            env.update(PKG_CONFIG_LIBDIR=str(pc),PKG_CONFIG_PATH=str(pc))
            for name in ('boundary_pkg_b','libboundary_prefix_d'):
                (pc/(name+'.pc')).write_text('prefix='+str(root)+'\nlibdir=${prefix}/lib\n'
                    'Name: '+name+'\nDescription: boundary fixture\nVersion: 1\n'
                    'Libs: -L${libdir} -l'+name+' -lm\n')
            raw={'name':'boundary-native-format','targetType':'executable','sourcePaths':[],
                 'importPaths':[],'sourceFiles':['entry.d'],'lflags':['-rpath=first','-Lsearch','-Lsearch',
                     '--start-group',str(root/'native.a'),'--end-group','-Lsearch','',
                     '-L'+str(root/'lib')],
                 'libs':['boundary_absent_a','boundary_pkg_b','boundary_absent_c','boundary_prefix_d']}
            source=ast.parse(Path(support.__file__).read_text())
            function=next(n for n in source.body if isinstance(n,ast.FunctionDef)
                          and n.name=='renderer_compile_target')
            expected=next(n for n in function.body if isinstance(n,ast.Assign)
                          and any(isinstance(t,ast.Name) and t.id=='expected_links' for t in n.targets))
            guard=next(n for n in function.body if isinstance(n,ast.Expr)
                       and isinstance(n.value,ast.Call) and n.value.args
                       and any(isinstance(a,ast.Constant) and isinstance(a.value,str)
                               and 'formatted ordered native link flags' in a.value
                               for a in ast.walk(n)))
            check=compile(ast.Module(body=[expected,guard],type_ignores=[]),support.__file__,'exec')
            for target_type in ('executable','staticLibrary'):
                raw['targetType']=target_type;(root/'dub.json').write_text(json.dumps(raw))
                command=['dub','describe','--root='+str(root),'--compiler=dmd',
                         '--build=debug','--nodeps','--skip-registry=all','--quiet']
                described=subprocess.run(command,cwd=root,env=env,text=True,capture_output=True,check=True)
                settings=json.loads(described.stdout)['targets'][0]['buildSettings']
                formatted=subprocess.run(command+['--data=lflags,libs'],cwd=root,env=env,
                                         text=True,capture_output=True,check=True)
                actual=shlex.split(formatted.stdout)
                def verify(links):
                    namespace=dict(support.__dict__,settings=settings,package={'targetType':target_type},
                                   root=root,env=env,evidence=root,label='fixture',links=links)
                    exec(check,namespace)
                verify(actual)
                self.assertEqual(actual.count('-L-Lsearch'),2,
                                 'formatter must retain nonadjacent repeated native flags')
                self.assertEqual(actual.count('-L-L'+str(root/'lib')),
                                 2,
                                 'formatter must retain duplicates across lflags/libs boundary')
                changes=[actual[1:],actual+['-L-lunexpected'],actual+['-L-o=/tmp/unexpected'],
                         [actual[1],actual[0]]+actual[2:]]
                duplicate=list(actual);duplicate.remove('-L-Lsearch');changes.append(duplicate)
                for changed in changes:
                    with self.subTest(target_type=target_type,changed=changed):
                        with self.assertRaisesRegex(support.BoundaryError,
                                                    'formatted ordered native link flags: fixture'):
                            verify(changed)
                verify(actual)

    def test_renderer_native_formatter_empty_comma(self):
        # Real pkg-config data exercises both DUB comma conversions independently.
        with tempfile.TemporaryDirectory(prefix='boundary-native-empty-') as directory:
            root=Path(directory);pc=root/'pkgconfig';pc.mkdir()
            (root/'entry.d').write_text('module entry; void main() {}\n')
            env=os.environ.copy();env.pop('DFLAGS',None)
            env.update(PKG_CONFIG_LIBDIR=str(pc),PKG_CONFIG_PATH=str(pc))
            source=ast.parse(Path(support.__file__).read_text())
            function=next(n for n in source.body if isinstance(n,ast.FunctionDef)
                          and n.name=='renderer_compile_target')
            expected=next(n for n in function.body if isinstance(n,ast.Assign)
                          and any(isinstance(t,ast.Name) and t.id=='expected_links' for t in n.targets))
            guard=next(n for n in function.body if isinstance(n,ast.Expr)
                       and isinstance(n.value,ast.Call) and n.value.args
                       and any(isinstance(a,ast.Constant) and isinstance(a.value,str)
                               and 'formatted ordered native link flags' in a.value
                               for a in ast.walk(n)))
            check=compile(ast.Module(body=[expected,guard],type_ignores=[]),support.__file__,'exec')
            for label,operand,nonempty in (
                    ('empty-wl','-Wl,--as-needed,,--as-needed,',
                     ['-L--as-needed','-L--as-needed']),
                    ('empty-L-l','-L-lboundary_first,,--as-needed,-lboundary_first,',
                     ['-L-lboundary_first','-L--as-needed','-L-lboundary_first'])):
                with self.subTest(comma_branch=label):
                    (pc/'boundary_empty.pc').write_text('Name: boundary_empty\n'
                        'Description: comma fixture\nVersion: 1\nLibs: '+operand+'\n')
                    raw={'name':'boundary-native-empty','targetType':'executable','sourcePaths':[],
                         'importPaths':[],'sourceFiles':['entry.d'],'libs':['boundary_empty']}
                    (root/'dub.json').write_text(json.dumps(raw))
                    command=['dub','describe','--root='+str(root),'--compiler=dmd',
                             '--build=debug','--nodeps','--skip-registry=all','--quiet']
                    described=subprocess.run(command,cwd=root,env=env,text=True,capture_output=True,check=True)
                    settings=json.loads(described.stdout)['targets'][0]['buildSettings']
                    formatted=subprocess.run(command+['--data=lflags,libs'],cwd=root,env=env,
                                             text=True,capture_output=True,check=True)
                    actual=shlex.split(formatted.stdout)
                    self.assertEqual(actual,nonempty,'real DUB retains ordered nonempty comma operands')
                    namespace=dict(support.__dict__,settings=settings,root=root,env=env,
                                   evidence=root,label='fixture-'+label,links=actual)
                    exec(check,namespace)

    def test_raw_descriptor_grants(self):
        for relative, description in self.descriptions.items():
            root = self.project / relative
            boundary.validate_package_settings(description, root)
            path = root / 'dub.json'
            original = path.read_text()
            try:
                for key, value in [('importPaths', ['../../source']),
                                   ('sourcePaths', ['../../source']),
                                   ('dflags', ['-I../../source']),
                                   ('libs-linux', ['calculation']),
                                   ('preBuildCommands', ['echo changed']),
                                   ('dependencies', {'vibe3d': {'path': '../..'}}),
                                   ('configurations', [{'name': 'widened', 'importPaths': ['../../source']}])]:
                    changed = json.loads(original)
                    changed[key] = value
                    path.write_text(json.dumps(changed))
                    with self.assertRaisesRegex(boundary.BoundaryError, 'raw descriptor changed: ' + relative):
                        boundary.validate_package_settings(description, root)
            finally:
                path.write_text(original)

    def test_resolved_grants_and_populations(self):
        for relative, original in self.descriptions.items():
            root = self.project / relative
            def reject(change, message):
                description = copy.deepcopy(original)
                change(description)
                with self.assertRaisesRegex(boundary.BoundaryError, message):
                    boundary.validate_package_settings(description, root)
            for change, message in [
                (lambda d: d.update(rootPackage='vibe3d'), 'root package'),
                (lambda d: d['packages'].pop(), 'package population'),
                (lambda d: d['packages'].append(copy.deepcopy(d['packages'][0])), 'package population'),
                (lambda d: d['packages'][0]['dependencies'].append('vibe3d'), 'dependencies'),
                (lambda d: d['packages'][0].update(path='/outside'), 'package path'),
                (lambda d: d['targets'].pop(), 'target population'),
                (lambda d: d['targets'].append(copy.deepcopy(d['targets'][0])), 'target population'),
            ]:
                reject(change, message)
            if any(p['name']=='d-stb-image' for p in original['packages']):
                reject(lambda d: next(p for p in d['packages'] if p['name']=='d-stb-image').update(path='/outside/image'), 'image revision')
                image=next(p for p in original['packages'] if p['name']=='d-stb-image')
                alias=self.project/'image-alias'
                alias.symlink_to(Path(image['path']).resolve(), target_is_directory=True)
                try:
                    affected=[t['rootPackage'] for t in original['targets'] if t['buildSettings'].get('lflags')]
                    self.assertEqual(set(affected), {'vibe3d-cli','vibe3d-document-io','vibe3d-image-codec','d-stb-image'})
                    canonical=copy.deepcopy(original)
                    for target in canonical['targets']:
                        if target['rootPackage'] in affected:
                            target['buildSettings']['lflags']=['-L'+str((Path(image['path'])/'build').resolve())]
                    for name in affected:
                        with self.subTest(target=name):
                            for path in (alias/'build', (Path(image['path'])/'build').resolve()):
                                changed=copy.deepcopy(canonical)
                                next(t for t in changed['targets'] if t['rootPackage']==name)['buildSettings']['lflags']=['-L'+str(path)]
                                boundary.validate_package_settings(changed, root)
                            for flags in ([], ['-L'], ['-I'+str(alias/'build')], ['-L/outside'],
                                          ['-L'+str(alias/'missing')], ['-L'+str(alias/'build')]*2):
                                reject(lambda d: next(t for t in d['targets'] if t['rootPackage']==name)['buildSettings'].update(lflags=flags),
                                       'resolved setting changed: '+name+':lflags')
                finally:
                    alias.unlink()
            for index in range(len(original['targets'])):
                for field in ('sourceFiles', 'importPaths', 'dflags', 'libs', 'lflags', 'linkerFiles',
                              'injectSourceFiles', 'frameworks', 'extraDependencyFiles', 'copyFiles',
                              'stringImportPaths', 'cImportPaths') + boundary.HOOKS:
                    reject(lambda d: d['targets'][index]['buildSettings'].setdefault(field, []).append('/outside'),
                           'resolved ' + field if field in ('sourceFiles', 'importPaths') else 'resolved setting')
            for index in range(len(original['packages'])):
                for field in boundary.HOOKS:
                    reject(lambda d: d['packages'][index].setdefault(field, []).append('echo changed'), 'package hook')

    def test_owner_source_inventory_is_live(self):
        for relative in ('packages/command-runtime', 'packages/application-core'):
            root = self.project / relative
            path = root / 'source/additional_model.d'
            original = self.descriptions[relative]
            owner = json.loads((root / 'dub.json').read_text())['name']
            path.write_text('module additional_model;')
            try:
                with self.assertRaisesRegex(boundary.BoundaryError, 'resolved sourceFiles'):
                    boundary.validate_package_settings(original, root)
                changed = copy.deepcopy(original)
                next(t for t in changed['targets'] if t['rootPackage']==owner)['buildSettings']['sourceFiles'].append(str(path))
                boundary.validate_package_settings(changed, root)
            finally:
                path.unlink()

    def test_ci_prerequisite_refusals(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/ci.yaml').read_text()
        invocation = workflow.index('      run: python3 tools/ci/preflight.py')
        self.assertLess(workflow.index('>> "$GITHUB_PATH"'), invocation)
        self.assertLess(invocation, workflow.index("    - name: 'Build'"))
        def resolved(name):
            return '/resolved/' + name
        good = subprocess.CompletedProcess([], 0, 'LDC - the LLVM D compiler (1.42.0)\n', '')
        with patch.object(preflight.shutil, 'which', side_effect=resolved), patch.object(preflight.subprocess, 'run', return_value=good):
            with patch.object(preflight.shutil, 'which', side_effect=lambda name: None if name == 'xdotool' else resolved(name)):
                with self.assertRaisesRegex(RuntimeError, 'missing or not executable: xdotool'):
                    preflight.main()
            with patch.object(preflight.shutil, 'which', side_effect=lambda name: None if name == str(preflight.PINNED_LDC) else resolved(name)):
                with self.assertRaisesRegex(RuntimeError, 'missing or not executable: .*ldc2'):
                    preflight.main()
            wrong = subprocess.CompletedProcess([], 0, 'wrong compiler', '')
            with patch.object(preflight.subprocess, 'run', return_value=wrong):
                with self.assertRaisesRegex(RuntimeError, 'pinned LDC identity mismatch'):
                    preflight.main()
            bad = subprocess.CompletedProcess([], 2, 'concrete stdout', 'concrete stderr')
            with patch.object(preflight.subprocess, 'run', return_value=bad):
                with self.assertRaisesRegex(RuntimeError, 'concrete stdout\nconcrete stderr'):
                    preflight.main()

    def test_ldc_describe_failure_details(self):
        bad = subprocess.CompletedProcess(['dub', 'describe'], 2, 'describe stdout', 'compiler unavailable stderr')
        with patch.object(subprocess, 'run', return_value=bad):
            with self.assertRaises(AssertionError) as failure:
                self.test_ldc_mesh_ops_archive_flag_scope()
            self.assertIn('describe stdout', str(failure.exception))
            self.assertIn('compiler unavailable stderr', str(failure.exception))

    def test_ldc_mesh_ops_archive_flag_scope(self):
        compiler = str(Path.home() / '.local/dlang/ldc2-1.42.0-linux-x86_64/bin/ldc2')
        actual = Path(__file__).resolve().parents[1]
        for relative, config in (('packages/command-runtime', 'modeling-noai'), ('packages/application-core', 'modeling-noai'), ('tests/core', 'core')):
            result = subprocess.run(['dub', 'describe', '--root=' + str(actual / relative),
                '--config=' + config, '--compiler=' + compiler, '--quiet'],
                text=True, capture_output=True)
            self.assertEqual(result.returncode, 0,
                'LDC dub describe failed: ' + repr(result.args) + '\nstdout:\n' + result.stdout
                + '\nstderr:\n' + result.stderr)
            description = json.loads(result.stdout.replace(str(actual), str(self.project)))
            root = self.project / relative
            boundary.validate_package_settings(description, root, compiler)
            if relative != 'tests/core':
                owner = json.loads((root / 'dub.json').read_text())['name']
                for name in (owner, 'vibe3d-mesh-ops'):
                    changed = copy.deepcopy(description)
                    target = next(t for t in changed['targets'] if t['rootPackage'] == name)
                    self.assertEqual(target['buildSettings']['dflags'], ['--singleobj'])
                    target['buildSettings']['dflags'] = []
                    with self.assertRaisesRegex(boundary.BoundaryError, 'resolved setting changed: ' + name + ':dflags'):
                        boundary.validate_package_settings(changed, root, compiler)
                    target['buildSettings']['dflags'] = ['--singleobj', '--singleobj']
                    with self.assertRaisesRegex(boundary.BoundaryError, 'resolved setting changed: ' + name + ':dflags'):
                        boundary.validate_package_settings(changed, root, compiler)
                with self.assertRaisesRegex(boundary.BoundaryError, 'resolved setting changed: ' + owner + ':dflags'):
                    boundary.validate_package_settings(description, root, 'dmd')
                for name in (owner, 'vibe3d-mesh-ops'):
                    changed = copy.deepcopy(description)
                    next(p for p in changed['packages'] if p['name'] == name)['configuration'] = 'isolated-tests'
                    with self.assertRaisesRegex(boundary.BoundaryError, 'resolved setting changed: ' + owner + ':dflags'):
                        boundary.validate_package_settings(changed, root, compiler)
                target = next(t for t in description['targets'] if t['rootPackage'] == 'vibe3d-math')
            else:
                target = next(t for t in description['targets'] if t['rootPackage'] == 'vibe3d-core-tests')
            target['buildSettings']['dflags'] = ['--singleobj']
            with self.assertRaisesRegex(boundary.BoundaryError, 'resolved setting changed: ' + target['rootPackage'] + ':dflags'):
                boundary.validate_package_settings(description, root, compiler)

    def test_actual_ldc_alias_argv_and_unknown_leaf(self):
        # DUB's actual unprefixed alias shape uses the invocation cwd; keep
        # printed argv rather than rewriting it to the symlink destination.
        cwd = self.project / 'tests/core'
        output = '/compiler/ldc -c ../source/mesh.d -ofcore.o\n/compiler/ldc core.o native.a -ofcore-tests\n'
        commands = support.compiler_commands(output, cwd)
        self.assertEqual(len(commands), 2)
        self.assertEqual(commands[0]['argv'][0], '/compiler/ldc')
        self.assertEqual(commands[0]['cwd'], str(cwd.resolve()))
        self.assertEqual(commands[0]['sourceInputs'], [str((cwd/'../source/mesh.d').resolve())])
        self.assertEqual(commands[1]['archiveInputs'], [str((cwd/'native.a').resolve())])
        self.assertEqual(commands[1]['objectInputs'], [str((cwd/'core.o').resolve())])
        with self.assertRaisesRegex(support.BoundaryError, 'actual compiler argv/cwd missing'):
            support.compiler_commands(output.replace('/compiler/ldc ', '/compiler/ldc3 '), cwd)

    def test_runtime_population(self):
        good = '25 modules passed unittests\n' + ''.join('CORE-CELL passed=' + name + '\n' for name in boundary.CORE_CELLS)
        self.assertEqual(boundary.validate_runtime(good), 25)
        for output in [good.replace('CORE-CELL passed=mesh-cube\n', ''),
                       good + 'CORE-CELL passed=mesh-cube\n',
                       good.replace('mesh-cube', 'unknown'),
                       good.replace('25 modules', '0 modules'),
                       good.replace('25 modules passed unittests\n', ''),
                       good + '25 modules passed unittests\n']:
            with self.assertRaises(boundary.BoundaryError):
                boundary.validate_runtime(output)


if __name__ == '__main__':
    unittest.main()
