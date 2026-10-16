#!/usr/bin/env python3
"""Controls for the retained DUB grants and exact CORE runtime witness."""
import ast
import copy
import os
import shlex
import json
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import ci.preflight as preflight
import check_standalone_boundary as boundary
import check_package_support_boundary as support
import check_thinlto as thinlto


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

    def test_current_thinlto_math_recipe(self):
        actual = Path(__file__).resolve().parents[1]
        expected = json.loads((actual / 'libraries/util/math/dub.json').read_text())['buildTypes']
        with tempfile.TemporaryDirectory(prefix='boundary-thinlto-recipe-') as directory:
            evidence = Path(directory)
            # Reach the first DUB invocation after the actual probe recipes exist.
            with patch.object(thinlto.subprocess, 'run', side_effect=RuntimeError('probe recipe witness')):
                with self.assertRaisesRegex(RuntimeError, 'probe recipe witness'):
                    thinlto.probe(actual, 'ldc2', evidence)
            helper = json.loads((evidence / 'probe/helper/dub.json').read_text())
            self.assertEqual(helper['targetType'], 'staticLibrary')
            self.assertEqual(helper['buildTypes'], expected, 'probe copies current math build types')

    def test_thinlto_qualified_target_flags(self):
        for platform in ('linux', 'osx', 'windows'):
            flags = thinlto.FLAGS['dflags-ldc'] + thinlto.FLAGS[f'dflags-{platform}-ldc']
            description = {'platform': [platform], 'targets': [
                {'rootPackage': name, 'buildSettings': {'dflags': list(flags)}}
                for name in ('vibe3d', 'vibe3d-owner', 'vibe3d:math')]}
            self.assertEqual(thinlto.check_description(description), 3,
                             'ThinLTO covers root, retained owners and qualified math')
            for flag in flags:
                with self.subTest(platform=platform, flag=flag):
                    changed = copy.deepcopy(description)
                    changed['targets'][2]['buildSettings']['dflags'].remove(flag)
                    with self.assertRaisesRegex(RuntimeError, 'vibe3d:math: missing ' + re.escape(flag)):
                        thinlto.check_description(changed)

    def test_current_math_consumer_description(self):
        actual = Path(__file__).resolve().parents[1]
        result = subprocess.run(['dub', 'describe', ':spatial', '--root=' + str(actual),
            '--config=modeling-noai', '--compiler=dmd', '--nodeps', '--skip-registry=all', '--quiet'],
            cwd=actual, text=True, capture_output=True, check=True)
        description = json.loads(result.stdout)
        support.validate_description(description, actual, 'spatial', 'modeling-noai')
        changed = copy.deepcopy(description)
        next(p for p in changed['packages'] if p['name'] == 'vibe3d:math')['name'] = 'vibe3d-math'
        with self.assertRaisesRegex(support.BoundaryError, 'resolved internal package population: spatial'):
            support.validate_description(changed, actual, 'spatial', 'modeling-noai')

    def test_selected_coordinate_declarations(self):
        import sys
        actual = Path(__file__).resolve().parents[1]
        with patch.object(sys, 'path', [str(actual / 'tools/dspans'), *sys.path]):
            import census_contracts as census
        # Exercise the production reader at each frozen real coordinate in both
        # selected states. No shim or guessed declaration supplies the identity.
        with tempfile.TemporaryDirectory(prefix='boundary-coordinate-') as directory:
            root = Path(directory)
            for owner, old, new, spans in census._WAVE19_COORDINATES:
                old_root, new_root = next(row[1:] for row in census._WAVE19_OWNERS
                                          if row[0] == owner)
                for moved in (False, True):
                    recipe = root / (new_root if moved else old_root) / 'dub.json'
                    recipe.parent.mkdir(parents=True, exist_ok=True)
                    recipe.write_text(json.dumps({'name': owner if moved else 'vibe3d-' + owner}))
                    physical = root / (new if moved else old)
                    physical.parent.mkdir(parents=True, exist_ok=True)
                    offset, current, original = spans[0]
                    name = current if moved else original
                    declaration = 'module ' + name + ';'
                    prefix = ' ' * (offset - 7)
                    good = prefix + declaration + '\n'
                    expected = (physical, spans if moved else ())
                    physical.write_text(good)
                    self.assertEqual(census._wave19_coordinate(root / old, root), expected)
                    decoys = ('// ' + declaration + '\n/* module wrong; */\n'
                              '/+ outer /+ module wrong; +/ ' + declaration + ' +/\n'
                              'enum a = "' + declaration + '";\n'
                              'enum b = `' + declaration + '`;\n'
                              'enum c = q{ module wrong; };\n'
                              '// module wrong . name;\n'
                              '/+ module wrong/*gap*/.name; +/\n'
                              'enum d = "module wrong . name;";\n'
                              'enum e = q{ module wrong/*gap*/.name; };\n'
                              'enum moduleимя = 0;\n'
                              'enum f = "module имя . name;";\n')
                    physical.write_text(good + decoys)
                    self.assertEqual(census._wave19_coordinate(root / old, root), expected,
                                     'comments and string declarations are not code: ' + old)
                    for label, changed in (
                            ('different duplicate', good + 'module wrong;\n'),
                            ('matching duplicate', good + declaration + '\n'),
                            ('spaced wrong duplicate', good + 'module wrong . name;\n'),
                            ('comment wrong duplicate', good + 'module wrong/*gap*/.name;\n'),
                            ('unicode duplicate', good + 'module имя . name;\n'),
                            ('spaced matching duplicate', good + 'module ' + name.replace('.', ' . ') + ';\n'),
                            ('comment matching duplicate', good + 'module ' + name.replace('.', '/*gap*/.') + ';\n'),
                            ('decoys without code', prefix + decoys),
                            ('wrong identity', prefix + 'module wrong;\n'),
                            ('comment identity', '//' + prefix[2:] + declaration + '\n'),
                            ('string identity', '"' + prefix[1:] + declaration + '";\n'),
                            ('comment at frozen position', '//' + prefix[2:] + declaration
                             + '\n' + declaration + '\n')):
                        with self.subTest(path=old, moved=moved, case=label):
                            physical.write_text(changed)
                            with self.assertRaisesRegex(ValueError, 'Wave19 real declaration identity: '):
                                census._wave19_coordinate(root / old, root)
                    physical.unlink()
                    recipe.unlink()

    def test_current_support_runtime_identities(self):
        # Independently frozen D1 enabled cells plus the unchanged math pilot.
        owners = ('math', 'edit-contracts', 'interaction-data', 'json-number', 'log', 'mesh-contracts', 'parallel', 'plane-bytes', 'profiling', 'screen-buckets', 'spatial', 'param-schema', 'mesh-change')
        enabled = {
            'vibe3d.editing.contracts.tests.unit.seltype_test',
            'vibe3d.editing.interaction.data.tests.unit.ai.advisor_test',
            'vibe3d.editing.interaction.data.tests.unit.ai.debug_trace_test',
            'vibe3d.editing.interaction.data.tests.unit.ai.interaction_test',
            'vibe3d.editing.params.argstring',
            'vibe3d.editing.params.tests.unit.argstring_test',
            'vibe3d.editing.params.tests.unit.param_cast_overflow_test',
            'vibe3d.editing.params.tests.unit.params_test',
            'vibe3d.mesh.change.mesh_dirty',
            'vibe3d.mesh.contracts.mesh_corner_maps',
            'vibe3d.mesh.contracts.tests.unit.mesh_plane_types_test',
            'vibe3d.util.json_number.tests.unit.json_num_test',
            'vibe3d.util.log.log',
            'vibe3d.util.math.math_geometry',
            'vibe3d.util.math.math_quaternion',
            'vibe3d.util.math.tests.unit.math_test',
            'vibe3d.util.plane_bytes.plane_bytes',
            'vibe3d.util.screen_buckets.screen_buckets',
            'vibe3d.util.spatial.spatial',
            'vibe3d.util.spatial.tests.unit.spatial_test',
            'vibe3d.util.spatial.trackball',
        }
        self.assertEqual(len(enabled), 21)
        modules = {support.compiler_module(path) for owner in owners
                   for field in ('sources', 'testSources', 'testHelpers', 'transitionalSources')
                   for path in support.SPECS[owner].get(field, []) if path.endswith('.d')}
        self.assertEqual(modules & support.ENABLED_MODULES, enabled,
                         'D1 independently frozen enabled module identity')
        output = ''.join('PKG-MODULE name=' + name + ' unittest='
                         + str(int(name in enabled)) + '\n' for name in sorted(modules))
        output += '21 modules passed unittests\n'
        for owner in owners:
            with self.subTest(owner=owner):
                support.validate_runtime(output, owner)

    def test_current_support_raw_tree(self):
        actual = Path(__file__).resolve().parents[1]
        self.assertEqual(len(support.SPECS), 55)
        for owner in support.SPECS:
            with self.subTest(owner=owner):
                support.check_raw_tree(actual, owner)

    def test_current_app_renderer_description(self):
        actual = Path(__file__).resolve().parents[1]
        result = subprocess.run(['dub', 'describe', '--root=' + str(actual),
            '--config=with-render', '--compiler=dmd', '--nodeps', '--skip-registry=all', '--quiet'],
            cwd=actual, text=True, capture_output=True, check=True)
        description = json.loads(result.stdout)
        support.renderer_description(description, actual, 'app', 'with-render')
        changed = copy.deepcopy(description)
        app = next(p for p in changed['packages'] if p['name'] == 'vibe3d')
        app['files'].append({'path': 'source/unauthorized.d', 'role': 'source'})
        with self.assertRaisesRegex(support.BoundaryError, 'exact physical owner inputs: vibe3d'):
            support.renderer_description(changed, actual, 'app', 'with-render')

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
                with self.assertRaisesRegex(RuntimeError,
                        'required executable failed: /resolved/dmd exit=2\nconcrete stdout\nconcrete stderr'):
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
                target = next(t for t in description['targets'] if t['rootPackage'] == support.SPECS['math']['name'])
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
