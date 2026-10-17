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
            config = ('modeling-noai' if relative in ('libraries/editing/commands/runtime', 'libraries/runtime/application-core') else 'core' if relative == 'tests/core' else 'application')
            result = subprocess.run(boundary.describe_arguments(actual / relative, config, 'dmd'),
                text=True, capture_output=True, check=True)
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
        # Check every coordinate in both states. The generic lexical refusal
        # cases run once per owner: repeating them for every source row adds no
        # distinct reader branch. Root/CLI/stationary roles are exercised below.
        with tempfile.TemporaryDirectory(prefix='boundary-coordinate-') as directory:
            root = Path(directory)
            checked_owners = set()
            for owner, old, new, spans in census._WAVE19_COORDINATES:
                if owner in ("desktop", "desktop-tests", "cli"):
                    continue
                old_root, new_root = next(row[1:] for row in census._WAVE19_OWNERS
                                          if row[0] == owner)
                for moved in (False, True):
                    recipe = root / (new_root if moved else old_root) / 'dub.json'
                    recipe.parent.mkdir(parents=True, exist_ok=True)
                    value = {'name': owner if moved else 'vibe3d-' + owner}
                    if owner == 'cli' and moved:
                        value.update(targetName='vibe3d-cli', targetPath='../..',
                                     mainSourceFile='source/vibe3d/apps/cli/main.d')
                    recipe.write_text(json.dumps(value))
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
                    if owner in checked_owners:
                        physical.unlink()
                        recipe.unlink()
                        continue
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
                            ('same-width wrong identity', prefix + 'module ' + 'x' * len(name) + ';\n'),
                            ('identity suffix', prefix + 'module ' + name + 'Suffix;\n'),
                            ('missing terminator', prefix + 'module ' + name + '\n'),
                            ('wrong keyword at frozen position', prefix + 'import ' + name + ';\nmodule wrong;\n'),
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
                checked_owners.add(owner)
        # The distinct root/CLI/stationary roles use the actual final selected
        # inputs. The same strict scanner must refuse their own raw duplicate.
        for role in ('desktop', 'cli', 'desktop-tests'):
            row = next(row for row in census._WAVE19_COORDINATES if row[0] == role)
            owner, old, new, spans = row
            physical, selected = census._wave19_coordinate(actual / old, actual)
            self.assertEqual((physical, selected), (actual / new, spans))
            read = Path.read_text
            raw = read(physical)
            def changed(path, *args, **kwargs):
                return raw + '\nmodule wrong;\n' if path == physical else read(path, *args, **kwargs)
            with self.subTest(selected_role=role), patch.object(Path, 'read_text', changed):
                with self.assertRaisesRegex(ValueError, 'Wave19 real declaration identity:'):
                    census._wave19_coordinate(actual / old, actual)
        # Four desktop stages reach the actual coordinate/target callers. The
        # six peers select rows, not the unrelated desktop or containing owner.
        with tempfile.TemporaryDirectory(prefix='boundary-final-roles-') as directory:
            root = Path(directory)
            rows = [row for row in census._WAVE19_COORDINATES if row[0] == 'desktop']
            self.assertEqual(len(rows), 79)
            peers = sum(census._WAVE19_APP_PEER_GROUPS, [])
            def put(relative, raw):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(raw)
            def desktop(stage):
                selected = set(peers[:stage]) if stage != 79 else {row[2] for row in rows}
                recipe = dict(name='vibe3d', sourcePaths=['apps/desktop/source' if stage == 79 else 'source'],
                    mainSourceFile='apps/desktop/source/vibe3d/apps/desktop/app.d' if stage == 79 else 'source/app.d',
                    sourceFiles=[] if stage == 79 else peers[:stage],
                    importPaths=['apps/desktop/source'] if stage else [])
                put('dub.json', json.dumps(recipe))
                for owner, old, new, spans in rows:
                    for relative in (old, new):
                        (root / relative).unlink(missing_ok=True)
                    offset, current, original = spans[0]
                    moved = new in selected
                    put(new if moved else old, ' ' * (offset - 7) + 'module '
                        + (current if moved else original) + ';\n')
                return recipe, selected
            target = next(row for row in rows if row[2] == peers[0])
            unrelated = next(row for row in rows if row[2] not in peers)
            for stage in (0, 3, 6, 79):
                recipe, selected = desktop(stage)
                for row in (target, unrelated):
                    moved = row[2] in selected
                    self.assertEqual(census._wave19_coordinate(root / row[1], root),
                        (root / (row[2] if moved else row[1]), row[3] if moved else ()),
                        'desktop selected row caller stage=' + str(stage))
                    self.assertEqual(census._wave19_target_moved(root, row[1]), moved,
                        'exact referenced desktop row, independent of other selected peers')
                # ID394 follows the early6 viewport definition, while the
                # containing desktop root is still old at that stage.
                identity = next(row for row in census._WAVE19_IDENTITIES if row[0] == 'ID394')
                viewport = next(row for row in rows if row[1] == identity[3])
                moved = viewport[2] in selected
                anchor, at, before, after = identity[4:8]
                raw = anchor[:at] + (after if moved else before) + anchor[at + len(before):] + '\n'
                census._wave19_identity_intact(root / identity[1], raw, root)
                wrong = anchor[:at] + (before if moved else after) + anchor[at + len(before):] + '\n'
                with self.assertRaisesRegex(ValueError, 'Wave19 raw approved identity anchor: ID394'):
                    census._wave19_identity_intact(root / identity[1], wrong, root)
                changes = [
                    ('name', 'other', 'root application identity'),
                    ('sourcePaths', ['source', 'apps/desktop/source'], 'desktop selected root coordinates'),
                    ('mainSourceFile', 'other.d', 'desktop selected root coordinates'),
                    ('sourceFiles', [peers[0], peers[0]], 'duplicate root explicit source'),
                    ('sourceFiles', ['outside.d'], 'unauthorized root explicit'),
                    ('sourceFiles', peers[:1], 'duplicate final desktop source ownership' if stage == 79
                     else 'incomplete coupled desktop peer stage')]
                if stage:
                    changes.append(('importPaths', ['source'], 'duplicate final desktop source ownership'
                                    if stage == 79 else 'selected desktop peer import root'))
                if stage != 79:
                    changes.extend(('sourceFiles', peers[3:6] if index == 3 else
                                    [peers[3] if position == index else peers[position] for position in range(3)],
                                    'incomplete coupled desktop peer stage') for index in range(4))
                for field, value, reason in changes:
                    changed = dict(recipe, **{field: value})
                    put('dub.json', json.dumps(changed))
                    with self.subTest(stage=stage, field=field, value=value):
                        with self.assertRaisesRegex(ValueError, 'Wave19 ' + reason):
                            census._wave19_coordinate(root / target[1], root)
                    put('dub.json', json.dumps(recipe))
                physical = root / (target[2] if target[2] in selected else target[1])
                saved = physical.read_text()
                physical.unlink()
                with self.assertRaisesRegex(ValueError, 'Wave19 real source identity:'):
                    census._wave19_target_moved(root, target[1])
                physical.write_text(saved)
                other = root / (target[1] if target[2] in selected else target[2])
                put(other.relative_to(root), saved)
                with self.assertRaisesRegex(ValueError, 'Wave19 real source identity:'):
                    census._wave19_target_moved(root, target[1])
                other.unlink()
                physical.write_text(saved + 'module wrong;\n')
                with self.assertRaisesRegex(ValueError, 'Wave19 real declaration identity:'):
                    census._wave19_target_moved(root, target[1])
                physical.write_text(saved)
                # This production import-operand caller must select the named
                # module, rather than the containing desktop state.
                for row in (target, unrelated):
                    # spans[0] is (offset,current,original).
                    spelling = row[3][0][1] if row[2] in selected else row[3][0][2]
                    text = 'import ' + spelling + ';'
                    self.assertEqual(census._wave19_special_operand_moved(root, text, 7,
                        row[3][0][1], row[3][0][2], 'desktop'), row[2] in selected)
                with self.assertRaisesRegex(ValueError, 'Wave19 exact special-role client target'):
                    census._wave19_special_operand_moved(root, 'import absent;', 7, 'absent', 'absent', 'desktop')
            # Frozen-table malformed populations still reach the actual caller.
            saved_rows = census._WAVE19_COORDINATES
            other = next(row for row in rows if row[1] not in (target[1], unrelated[1]))
            for label, replacement in (
                    ('missing79', tuple(row for row in saved_rows if row != other)),
                    ('duplicate-old79', tuple((row[0], unrelated[1], row[2], row[3]) if row == other else row for row in saved_rows)),
                    ('duplicate-new79', tuple((row[0], row[1], unrelated[2], row[3]) if row == other else row for row in saved_rows))):
                with self.subTest(desktop_table=label), patch.object(census, '_WAVE19_COORDINATES', replacement):
                    with self.assertRaisesRegex(ValueError, 'Wave19 desktop frozen79 coordinate population'):
                        census._wave19_coordinate(root / target[1], root)
            groups = census._WAVE19_APP_PEER_GROUPS
            for replacement in (groups[:1], [groups[0][1:], groups[1]], [groups[0], [groups[0][0], *groups[1][1:]]]):
                with patch.object(census, '_WAVE19_APP_PEER_GROUPS', replacement):
                    with self.assertRaisesRegex(ValueError, 'Wave19 desktop six coupled-peer population'):
                        census._wave19_coordinate(root / target[1], root)
            with self.assertRaisesRegex(ValueError, 'Wave19 exact referenced target coordinate'):
                census._wave19_target_moved(root, 'source/absent.d')
            # Stationary host peers follow their own library recipe even when
            # the desktop has the opposite selected state.
            host = next(row for row in census._WAVE19_COORDINATES if row[0] == 'desktop-tests')
            owner = census._WAVE19_HOST_PEER_OWNERS[host[1]]
            old_root, new_root = next(row[1:] for row in census._WAVE19_OWNERS if row[0] == owner)
            for moved in (False, True):
                desktop(0 if moved else 79)
                for relative in (old_root, new_root):
                    (root / relative / 'dub.json').unlink(missing_ok=True)
                put((new_root if moved else old_root) + '/dub.json', json.dumps(dict(name=owner if moved else 'vibe3d-' + owner)))
                offset, current, original = host[3][0]
                put(host[1], ' ' * (offset - 7) + 'module ' + (current if moved else original) + ';\n')
                self.assertEqual(census._wave19_target_moved(root, host[1]), moved,
                                 'stationary host selects its referenced library, independent of desktop')
                put(host[1], ' ' * (offset - 7) + 'module ' + (original if moved else current) + ';\n')
                with self.assertRaisesRegex(ValueError, 'Wave19 real declaration identity:'):
                    census._wave19_target_moved(root, host[1])
            cli = next(row for row in census._WAVE19_COORDINATES if row[0] == 'cli')
            cli_recipe = dict(name='cli', targetName='vibe3d-cli', targetPath='../..', mainSourceFile='source/vibe3d/apps/cli/main.d')
            put('apps/cli/dub.json', json.dumps(cli_recipe))
            offset, current, original = cli[3][0]
            put(cli[2], ' ' * (offset - 7) + 'module ' + current + ';\n')
            self.assertTrue(census._wave19_target_moved(root, cli[1]), 'CLI actual target positive')
            for field in ('targetName', 'targetPath', 'mainSourceFile'):
                put('apps/cli/dub.json', json.dumps(dict(cli_recipe, **{field: 'wrong'})))
                with self.subTest(cli_field=field), self.assertRaisesRegex(ValueError, 'Wave19 CLI output/source root identity'):
                    census._wave19_target_moved(root, cli[1])
                put('apps/cli/dub.json', json.dumps(cli_recipe))
        # The actual read chain validates a raw locator before applying syntax
        # or historical inverses. A legitimate full source is the control.
        locator = next(row for row in census._WAVE19_LOCATORS if row[0] == 'L05-oblique-root-fixture')
        ident, relative, owner, original, current = locator
        coordinate = next(row for row in census._WAVE19_COORDINATES if row[1] == relative)
        old_root, new_root = next(row[1:] for row in census._WAVE19_OWNERS if row[0] == owner)
        with tempfile.TemporaryDirectory(prefix='boundary-locator-caller-') as directory:
            root = Path(directory)
            recipe = root / new_root / 'dub.json'
            recipe.parent.mkdir(parents=True, exist_ok=True)
            recipe.write_text(json.dumps(dict(name=owner)))
            physical = root / coordinate[2]
            physical.parent.mkdir(parents=True, exist_ok=True)
            good = (actual / coordinate[2]).read_text()
            physical.write_text(good)
            self.assertIn(original, census.read_source_text(root / relative, root=root),
                          'locator caller reaches complete original inverse')
            for label, raw in (
                    ('missing', good.replace(current, '0')),
                    ('malformed', good.replace(current, current.replace('kFixtureName', 'wrongFixture'))),
                    ('duplicate', good + '\n' + current + '\n'),
                    ('comment', good.replace(current, '/*' + current + '*/')),
                    ('string', good.replace(current, '`' + current + '`')),
                    ('wrong-state', good.replace(current, original))):
                physical.write_text(raw)
                with self.subTest(locator_case=label), self.assertRaisesRegex(ValueError, 'Wave19 raw whole locator: L05'):
                    census.read_source_text(root / relative, root=root)
            physical.write_text(good)
        # L02 is the sole original __FILE__ locator arm. Keep the owner old
        # and call the real reader so this also covers its no-inversion path.
        locator = next(row for row in census._WAVE19_LOCATORS if row[0] == 'L02-pen-owner-fixture')
        ident, relative, owner, original, current = locator
        coordinate = next(row for row in census._WAVE19_COORDINATES if row[1] == relative)
        old_root, new_root = next(row[1:] for row in census._WAVE19_OWNERS if row[0] == owner)
        old_source = census.read_source_text(actual / relative, root=actual)
        self.assertIn(original, old_source)
        with tempfile.TemporaryDirectory(prefix='boundary-old-locator-caller-') as directory:
            root = Path(directory)
            recipe = root / old_root / 'dub.json'
            recipe.parent.mkdir(parents=True, exist_ok=True)
            recipe.write_text(json.dumps(dict(name='vibe3d-' + owner)))
            physical = root / relative
            physical.parent.mkdir(parents=True, exist_ok=True)
            physical.write_text(old_source)
            self.assertEqual(census.read_source_text(physical, root=root), old_source,
                             'old __FILE__ locator actual caller preserves unmoved complete body')
            for label, changed in (
                    ('old macro in comment', old_source.replace(original, '/*' + original + '*/')),
                    ('wrong current state', old_source.replace(original, current))):
                physical.write_text(changed)
                with self.subTest(old_locator=label), self.assertRaisesRegex(ValueError, 'Wave19 raw whole locator: L02'):
                    census.read_source_text(physical, root=root)
            physical.write_text(old_source)
        self.assertEqual(len(census._WAVE19_CLIENT_IMPORTS), 390)
        self.assertEqual(sum(map(len, census._WAVE19_CLIENT_IMPORTS.values())), 3359)
        # Approved454 non-import identities: both referenced-owner states use
        # the real production raw guard with the ordinary native lexer.
        def identity_fixture(relative, moved, *, literal_context=True):
            parts = []
            seen = set()
            for row in census._WAVE19_IDENTITIES:
                ident, path, owner, target, original, offset, old, new, literal = row
                if path != relative or original in seen:
                    continue
                seen.add(original)
                line = original
                group = [member for member in census._WAVE19_IDENTITIES
                         if member[1] == path and member[4] == original]
                if moved:
                    for member in sorted(group, key=lambda member: member[5], reverse=True):
                        at, before, after = member[5:8]
                        line = line[:at] + after + line[at + len(before):]
                parts.append(('enum payload' + str(len(parts)) + ' = q{\n' + line + '\n};\n')
                             if literal and literal_context else line + '\n')
            return ''.join(parts)
        with tempfile.TemporaryDirectory(prefix='boundary-identity-') as directory:
            root = Path(directory)
            for moved in (False, True):
                (root / 'dub.json').write_text(json.dumps(dict(name='vibe3d',
                    sourcePaths=['apps/desktop/source' if moved else 'source'],
                    mainSourceFile='apps/desktop/source/vibe3d/apps/desktop/app.d' if moved else 'source/app.d',
                    sourceFiles=[], importPaths=['apps/desktop/source'] if moved else [])))
                for owner, old_root, new_root in census._WAVE19_OWNERS:
                    recipe = root / (new_root if moved else old_root) / 'dub.json'
                    recipe.parent.mkdir(parents=True, exist_ok=True)
                    value = {'name': owner if moved else 'vibe3d-' + owner}
                    if owner == 'cli' and moved:
                        value.update(targetName='vibe3d-cli', targetPath='../..',
                                     mainSourceFile='source/vibe3d/apps/cli/main.d')
                    recipe.write_text(json.dumps(value))
                for owner, old, new, spans in census._WAVE19_COORDINATES:
                    offset, current, original = spans[0]
                    physical = root / (new if moved else old)
                    physical.parent.mkdir(parents=True, exist_ok=True)
                    physical.write_text(' ' * (offset - 7) + 'module '
                                        + (current if moved else original) + ';\n')
                for relative in sorted({row[1] for row in census._WAVE19_IDENTITIES}):
                    good = identity_fixture(relative, moved)
                    census._wave19_identity_intact(root / relative, good, root)
                    for label, changed in (
                            ('wrong state', identity_fixture(relative, not moved)),
                            ('duplicate', good + good),
                            ('comment decoy', '/*\n' + good + '\n*/\n')):
                        with self.subTest(identity=relative, moved=moved, case=label):
                            with self.assertRaisesRegex(ValueError, 'Wave19 raw approved identity'):
                                census._wave19_identity_intact(root / relative, changed, root)
                if moved:
                    code_path = 'tests/unit/mesh_thicken_surface_test.d'
                    code = identity_fixture(code_path, True)
                    for label, changed in (
                            ('complete anchor prefix', 'X' + code),
                            ('complete anchor suffix', code.rstrip('\n') + ' X\n'),
                            ('code operand in string', 'enum payload = q{\n' + code + '\n};\n')):
                        with self.subTest(raw_guard=label):
                            with self.assertRaisesRegex(ValueError, 'Wave19 raw approved identity (anchor|lexical kind):'):
                                census._wave19_identity_intact(root / code_path, changed, root)
                    payload = 'tests/unit/version_gate_census_ai3d_remesh_test.d'
                    with self.assertRaisesRegex(ValueError, 'Wave19 raw approved identity lexical kind:'):
                        census._wave19_identity_intact(root / payload,
                            identity_fixture(payload, True, literal_context=False), root)
                    identity = next(row for row in census._WAVE19_IDENTITIES if row[0] == 'ID006')
                    referenced = next(row for row in census._WAVE19_COORDINATES if row[1] == identity[3])
                    target = root / referenced[2]
                    saved = target.read_text()
                    target.write_text('module wrong;\n')
                    with self.assertRaisesRegex(ValueError, 'Wave19 real declaration identity:'):
                        census._wave19_identity_intact(root / identity[1],
                            identity_fixture(identity[1], True), root)
                    target.write_text(saved)
                    # Complete current bodies reach the real caller seams. The
                    # appended duplicate leaves every syntax inverse offset intact.
                    selected = next(row for row in census._WAVE19_COORDINATES
                                    if row[1] == 'packages/camera-model/tests/source/tests/unit/camera_model_population_test.d')
                    _, logical, physical, spans = selected
                    raw = (actual / physical).read_text()
                    target = root / physical
                    target.write_text(raw)
                    expected = census._wave19_original(raw, spans)
                    self.assertEqual(census.read_source_text(root / logical, root=root), expected)
                    duplicate = raw + '\n' + identity_fixture(logical, True)
                    target.write_text(duplicate)
                    with self.assertRaisesRegex(ValueError, 'Wave19 raw approved identity anchor:'):
                        census.read_source_text(root / logical, root=root)
                    target.write_text(raw)
                    relative = 'tests/unit/mesh_thicken_surface_test.d'
                    raw = (actual / relative).read_text()
                    expected = census._wave19_import_original(actual / relative, raw, actual)
                    self.assertEqual(census._wave19_import_original(root / relative, raw, root), expected)
                    duplicate = raw + '\n' + identity_fixture(relative, True)
                    with self.assertRaisesRegex(ValueError, 'Wave19 raw approved identity anchor:'):
                        census._wave19_import_original(root / relative, duplicate, root)
                for owner, old_root, new_root in census._WAVE19_OWNERS:
                    (root / (new_root if moved else old_root) / 'dub.json').unlink()
                for owner, old, new, spans in census._WAVE19_COORDINATES:
                    (root / (new if moved else old)).unlink()
        identity_rows = census._WAVE19_IDENTITIES
        for label, malformed in (('missing', identity_rows[:-1]),
                                 ('duplicate', identity_rows[:-1] + identity_rows[:1])):
            with self.subTest(identity_population=label), patch.object(census, '_WAVE19_IDENTITIES', malformed):
                with self.assertRaisesRegex(ValueError, 'Wave19 frozen approved identity population'):
                    census._wave19_identity_intact(actual / 'tests/unit/identity-control.d', '', actual)
        control_path = actual / 'tests/unit/wave19-coordinate-control.d'
        self.assertNotIn(control_path.relative_to(actual).as_posix(), census._WAVE19_CLIENT_IMPORTS)
        self.assertEqual(census._wave19_import_original(control_path, '', actual), '')
        extra_client = dict(census._WAVE19_CLIENT_IMPORTS)
        extra_client['tests/unit/wave19-coordinate-extra.d'] = ()
        extra_span = dict(census._WAVE19_CLIENT_IMPORTS)
        first_client = next(iter(extra_span))
        extra_span[first_client] += extra_span[first_client][:1]
        for label, malformed in (('client population', extra_client), ('span population', extra_span)):
            with self.subTest(case=label), patch.object(census, '_WAVE19_CLIENT_IMPORTS', malformed):
                with self.assertRaisesRegex(ValueError, 'Wave19 frozen client/import coordinate population'):
                    census._wave19_import_original(control_path, '', actual)
        prior = census._WAVE19_COORDINATE_PRIOR_IMPORTS
        extra_prior = dict(prior)
        extra_prior['tests/unit/wave19-prior-extra.d'] = ()
        extra_prior_span = dict(prior)
        first_prior = next(iter(prior))
        extra_prior_span[first_prior] += extra_prior_span[first_prior][:1]
        overlapping_prior = dict(prior)
        overlapping_prior[next(iter(census._WAVE19_CLIENT_IMPORTS))] = overlapping_prior.pop(first_prior)
        for label, malformed in (('prior population', extra_prior),
                                 ('prior spans', extra_prior_span),
                                 ('prior custody overlap', overlapping_prior)):
            with self.subTest(case=label), patch.object(census, '_WAVE19_COORDINATE_PRIOR_IMPORTS', malformed):
                with self.assertRaisesRegex(ValueError, 'Wave19 old-coordinate prior import population'):
                    census._wave19_import_original(control_path, '', actual)

    def test_client_import_projection_coordinates(self):
        import sys
        actual = Path(__file__).resolve().parents[1]
        with patch.object(sys, 'path', [str(actual / 'tools/dspans'), *sys.path]):
            import census_contracts as census
        # Check the inverse on a bounded import fixture. Wave19's historical
        # full-body hashes also froze unrelated host-test code and refused later
        # reader fixes; they are migration receipts, not a library boundary.
        original = 'import math;\nimport app;\n'
        rows = ((original.index('math'), 'vibe3d.util.math.math', 'math', 'math'),
                (original.index('app'), 'vibe3d.apps.desktop.app', 'app', 'desktop'))
        current = original
        for offset, selected, previous, owner in reversed(rows):
            current = current[:offset] + selected + current[offset + len(previous):]
        relative = 'tests/unit/wave19-import-coordinate-control.d'
        clients = dict(census._WAVE19_CLIENT_IMPORTS)
        replaced = next(path for path, imports in clients.items() if len(imports) == len(rows))
        del clients[replaced]
        clients[relative] = rows
        path = actual / relative
        with patch.object(census, '_WAVE19_CLIENT_IMPORTS', clients):
            self.assertEqual(census._wave19_import_original(path, current, actual), original)
            with self.assertRaisesRegex(ValueError, 'Wave19 declaration/import coordinate'):
                census._wave19_import_original(path, current.replace('vibe3d.util.math.math',
                    'vibe3d.util.math.nope'), actual)
            with self.assertRaisesRegex(ValueError, 'Wave19 exact special-role client target'):
                census._wave19_import_original(path, current.replace('vibe3d.apps.desktop.app',
                    'vibe3d.apps.desktop.absent'), actual)
        # A stale numerical offset must still refuse; no permissive operand
        # search replaces the exact captured-coordinate check.
        clients[relative] = ((rows[0][0] - 1, *rows[0][1:]), rows[1])
        with patch.object(census, '_WAVE19_CLIENT_IMPORTS', clients):
            with self.assertRaisesRegex(ValueError, 'Wave19 declaration/import coordinate'):
                census._wave19_import_original(path, current, actual)

    def test_current_support_runtime_identities(self):
        # Independently frozen D1+D2 enabled cells plus the unchanged math pilot.
        owners = ('math',
 'edit-contracts',
 'interaction-data',
 'json-number',
 'log',
 'mesh-contracts',
 'parallel',
 'param-schema',
 'plane-bytes',
 'profiling',
 'screen-buckets',
 'spatial',
 'mesh-change',
 'camera-model',
 'image-codec',
 'input-events',
 'mesh-edit-log',
 'mesh-topology',
 'render-model',
 'mesh',
 'document-model',
 'mesh-edit-replay',
 'mesh-ops',
 'mesh-preview',
 'mesh-snapshot',
 'pipe-contracts',
 'display-policy',
 'document-channels',
 'interaction-query',
 'interchange',
 'pipe-runtime',
 'remesh-runtime',
 'render-backends',
 'selection-model',
 'tool-state',
 'document-io',
 'pipe-evaluation',
 'viewport-gpu',
 'ai-advisor',
 'ai3d-runtime',
 'alignment-ops',
 'creation-ops',
 'scene-query',
 'subpatch-preview',
 'transform-ops',
 'command-runtime',
 'application-core',
 'editor-commands',
 'interactive-tools',
 'forms-model',
 'http-runtime',
 'platform-file',
 'viewport-host',
 'document-actions',
 'editor-ui')
        enabled = {'tests.unit.fixtures',
 'tests.unit.mesh_by_value_gate',
 'vibe3d.documents.channels.tests.unit.document_channels_population_test',
 'vibe3d.documents.channels.tests.unit.layer_params_test',
 'vibe3d.documents.image_codec.tests.unit.image_codec_population_test',
 'vibe3d.documents.image_codec.tests.unit.io.image_decode_source_cells_test',
 'vibe3d.documents.image_codec.tests.unit.io.image_decode_test',
 'vibe3d.documents.interchange.io.lwo_import',
 'vibe3d.documents.interchange.io.scene_import',
 'vibe3d.documents.interchange.io.scene_ir',
 'vibe3d.documents.interchange.tests.unit.assimp_wire_test',
 'vibe3d.documents.interchange.tests.unit.io.lwo_export_ptag_census_test',
 'vibe3d.documents.interchange.tests.unit.io.lwo_export_test',
 'vibe3d.documents.interchange.tests.unit.io.lwo_import_test',
 'vibe3d.documents.io.io.native',
 'vibe3d.documents.io.tests.unit.document_io_population_test',
 'vibe3d.documents.io.tests.unit.io.image_path_test',
 'vibe3d.documents.io.tests.unit.io.native_source_cells_test',
 'vibe3d.documents.io.tests.unit.io.native_test',
 'vibe3d.documents.model.tests.unit.document_test',
 'vibe3d.editing.commands.editor.commands.mesh.edge_crease',
 'vibe3d.editing.commands.editor.tests.unit.commands.layer.xform_edit_source_public_test',
 'vibe3d.editing.commands.editor.tests.unit.commands.mesh.edge_crease_source_public_test',
 'vibe3d.editing.commands.editor.tests.unit.commands.mesh.remove_source_public_test',
 'vibe3d.editing.commands.editor.tests.unit.commands.mesh.symmetrize_source_public_test',
 'vibe3d.editing.commands.editor.tests.unit.commands.mesh.vertex_set_source_public_test',
 'vibe3d.editing.commands.editor.tests.unit.commands.select.boundary_source_public_test',
 'vibe3d.editing.commands.editor.tests.unit.commands.select.by_stat_source_public_test',
 'vibe3d.editing.commands.editor.tests.unit.commands.select.by_tag_source_public_test',
 'vibe3d.editing.commands.editor.tests.unit.commands.select.type_from_source_public_test',
 'vibe3d.editing.commands.editor.tests.unit.editor_commands_population_test',
 'vibe3d.editing.commands.runtime.command_history',
 'vibe3d.editing.commands.runtime.command_registry',
 'vibe3d.editing.commands.runtime.tests.unit.base_revert_flag_test',
 'vibe3d.editing.commands.runtime.tests.unit.command_apply_anchor_test',
 'vibe3d.editing.commands.runtime.tests.unit.command_bindargs_test',
 'vibe3d.editing.commands.runtime.tests.unit.command_history_source_public_test',
 'vibe3d.editing.commands.runtime.tests.unit.command_registry_test',
 'vibe3d.editing.commands.runtime.tests.unit.command_runtime_population_test',
 'vibe3d.editing.commands.runtime.tests.unit.command_source_public_test',
 'vibe3d.editing.commands.runtime.tests.unit.commands.mesh.session_edit_source_public_test',
 'vibe3d.editing.commands.runtime.tests.unit.commands.select.element_source_public_test',
 'vibe3d.editing.commands.runtime.tests.unit.record_observer_hub_source_public_test',
 'vibe3d.editing.commands.runtime.tests.unit.session_edit_payload_test',
 'vibe3d.editing.contracts.tests.unit.seltype_test',
 'vibe3d.editing.interaction.data.tests.unit.ai.advisor_test',
 'vibe3d.editing.interaction.data.tests.unit.ai.debug_trace_test',
 'vibe3d.editing.interaction.data.tests.unit.ai.interaction_test',
 'vibe3d.editing.params.argstring',
 'vibe3d.editing.params.tests.unit.argstring_test',
 'vibe3d.editing.params.tests.unit.param_cast_overflow_test',
 'vibe3d.editing.params.tests.unit.params_test',
 'vibe3d.editing.pipeline.contracts.tests.unit.operator_test',
 'vibe3d.editing.pipeline.contracts.tests.unit.toolpipe.packets_test',
 'vibe3d.editing.pipeline.evaluation.tests.unit.falloff_screen_default_test',
 'vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.obbox_regression_test',
 'vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.obbox_test',
 'vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.pipeline_order_test',
 'vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.prepared_stage_regression_test',
 'vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.snap_stage_regression_test',
 'vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.stages.actcenter_test',
 'vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.stages.axis_test',
 'vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.stages.falloff_test',
 'vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.stages.snap_test',
 'vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.stages.symmetry_test',
 'vibe3d.editing.pipeline.evaluation.tests.unit.toolpipe.stages.workplane_test',
 'vibe3d.editing.pipeline.evaluation.toolpipe.stages.actcenter',
 'vibe3d.editing.pipeline.evaluation.toolpipe.stages.axis',
 'vibe3d.editing.pipeline.evaluation.toolpipe.stages.constrain',
 'vibe3d.editing.pipeline.evaluation.toolpipe.stages.falloff',
 'vibe3d.editing.pipeline.evaluation.toolpipe.stages.snap',
 'vibe3d.editing.pipeline.runtime.tests.unit.falloff_selection_bake_test',
 'vibe3d.editing.pipeline.runtime.tests.unit.falloff_test',
 'vibe3d.editing.pipeline.runtime.tests.unit.toolpipe.pipeline_registration_test',
 'vibe3d.editing.pipeline.runtime.tests.unit.toolpipe.required_packets_witness_test',
 'vibe3d.editing.pipeline.runtime.tests.unit.toolpipe.view_only_subject_pin_test',
 'vibe3d.editing.selection.model.tests.unit.selection_model_population_test',
 'vibe3d.editing.selection.model.tests.unit.selection_product_source_public_test',
 'vibe3d.editing.selection.model.tests.unit.selection_projection_algorithm_cells_test',
 'vibe3d.editing.selection.query.snap',
 'vibe3d.editing.selection.query.symmetry',
 'vibe3d.editing.selection.query.tests.unit.constraint_regression_test',
 'vibe3d.editing.selection.query.tests.unit.constraint_test',
 'vibe3d.editing.selection.query.tests.unit.path_test',
 'vibe3d.editing.selection.query.tests.unit.snap_election_corpus_test',
 'vibe3d.editing.selection.query.tests.unit.snap_regression_test',
 'vibe3d.editing.selection.query.tests.unit.snap_test',
 'vibe3d.editing.selection.query.tests.unit.symmetry_regression_test',
 'vibe3d.editing.selection.query.tests.unit.viewgrid_regression_test',
 'vibe3d.editing.selection.query.tests.unit.viewgrid_test',
 'vibe3d.editing.selection.query.tests.unit.workplane_fit_test',
 'vibe3d.editing.selection.scene_query.bvh_pick',
 'vibe3d.editing.selection.scene_query.tests.unit.bvh_pick_test',
 'vibe3d.editing.selection.scene_query.tests.unit.scene_query_population_test',
 'vibe3d.editing.tools.alignment.tests.unit.alignment_ops_population_test',
 'vibe3d.editing.tools.alignment.tests.unit.tools.alignment.align_kernels_test',
 'vibe3d.editing.tools.alignment.tools.alignment.align_kernels',
 'vibe3d.editing.tools.creation.tests.unit.tools.create.pen_geometry_population_test',
 'vibe3d.editing.tools.creation.tests.unit.tools.create.pen_geometry_test',
 'vibe3d.editing.tools.interactive.drag',
 'vibe3d.editing.tools.interactive.drag_identity',
 'vibe3d.editing.tools.interactive.drag_source_cells',
 'vibe3d.editing.tools.interactive.edit_session',
 'vibe3d.editing.tools.interactive.falloff_rmb_discipline_test',
 'vibe3d.editing.tools.interactive.handles.arbiter_source_cells',
 'vibe3d.editing.tools.interactive.handles.gizmo_metrics',
 'vibe3d.editing.tools.interactive.handles.gl_util',
 'vibe3d.editing.tools.interactive.handles.gl_util_source_cells',
 'vibe3d.editing.tools.interactive.handles.shapes',
 'vibe3d.editing.tools.interactive.overlay_space_source_cells',
 'vibe3d.editing.tools.interactive.prepared_bridge_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_command_wrapper_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_edge_bevel_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_edge_extend_deactivate_source_cells',
 'vibe3d.editing.tools.interactive.prepared_edge_extend_tool_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_edge_extrude_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_edge_slice_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_edge_slice_deactivate_source_cells',
 'vibe3d.editing.tools.interactive.prepared_inherited_noop_source_cells',
 'vibe3d.editing.tools.interactive.prepared_loop_slice_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_loop_slice_deactivate_source_cells',
 'vibe3d.editing.tools.interactive.prepared_mirror_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_move_update_source_cells',
 'vibe3d.editing.tools.interactive.prepared_pipe_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_poly_bevel_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_poly_extrude_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_poly_inset_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_private_state',
 'vibe3d.editing.tools.interactive.prepared_private_state_source_cells',
 'vibe3d.editing.tools.interactive.prepared_radial_array_transition_source_cells',
 'vibe3d.editing.tools.interactive.prepared_radial_sweep_transition_source_cells',
 'vibe3d.editing.tools.interactive.prepared_record_context',
 'vibe3d.editing.tools.interactive.prepared_record_context_source_cells',
 'vibe3d.editing.tools.interactive.prepared_rotate_update_source_cells',
 'vibe3d.editing.tools.interactive.prepared_scale_update_source_cells',
 'vibe3d.editing.tools.interactive.prepared_selection_profile_source_cells',
 'vibe3d.editing.tools.interactive.prepared_slice_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_slice_deactivate_source_cells',
 'vibe3d.editing.tools.interactive.prepared_smooth_shift_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_stroke_extrude_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_tack_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_topology_pen_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_topology_pen_deactivate_source_cells',
 'vibe3d.editing.tools.interactive.prepared_topology_pen_update_source_cells',
 'vibe3d.editing.tools.interactive.prepared_transform_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_transform_product_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_vertex_bevel_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_vertex_extrude_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_vertex_merge_activation_source_cells',
 'vibe3d.editing.tools.interactive.prepared_xfrm_activation_session_source_cells',
 'vibe3d.editing.tools.interactive.registry',
 'vibe3d.editing.tools.interactive.registry_source_cells',
 'vibe3d.editing.tools.interactive.snap_render',
 'vibe3d.editing.tools.interactive.snap_render_source_cells',
 'vibe3d.editing.tools.interactive.snap_render_source_helpers',
 'vibe3d.editing.tools.interactive.tests.unit.close_reason_table_test',
 'vibe3d.editing.tools.interactive.tests.unit.command_history_test',
 'vibe3d.editing.tools.interactive.tests.unit.command_wrapper_result_test',
 'vibe3d.editing.tools.interactive.tests.unit.commands.mesh.edge_slide_result_builder_test',
 'vibe3d.editing.tools.interactive.tests.unit.commands.mesh.jitter_result_builder_test',
 'vibe3d.editing.tools.interactive.tests.unit.constraint_surface_at_test',
 'vibe3d.editing.tools.interactive.tests.unit.deform_magnet_test',
 'vibe3d.editing.tools.interactive.tests.unit.drag_gain_oblique_test',
 'vibe3d.editing.tools.interactive.tests.unit.edge_slice_locate_base_test',
 'vibe3d.editing.tools.interactive.tests.unit.edit_session_test',
 'vibe3d.editing.tools.interactive.tests.unit.gesture_carrier_interface_test',
 'vibe3d.editing.tools.interactive.tests.unit.gesture_record_belt_test',
 'vibe3d.editing.tools.interactive.tests.unit.handles.gl_util_test',
 'vibe3d.editing.tools.interactive.tests.unit.mesh_ops.bridge_frozen_kernel_test',
 'vibe3d.editing.tools.interactive.tests.unit.model_preview_test',
 'vibe3d.editing.tools.interactive.tests.unit.overlay_space_test',
 'vibe3d.editing.tools.interactive.tests.unit.quad_overlay_eligibility_test',
 'vibe3d.editing.tools.interactive.tests.unit.shared_hover_record_test',
 'vibe3d.editing.tools.interactive.tests.unit.tool_gesture_runopen_test',
 'vibe3d.editing.tools.interactive.tests.unit.tool_single_operation_equivalence_test',
 'vibe3d.editing.tools.interactive.tests.unit.toolpipe.local_component_frame_test',
 'vibe3d.editing.tools.interactive.tests.unit.tools.alignment.mirror_test',
 'vibe3d.editing.tools.interactive.tests.unit.tools.create.arc_test',
 'vibe3d.editing.tools.interactive.tests.unit.tools.create.box_test',
 'vibe3d.editing.tools.interactive.tests.unit.tools.create.create_common_test',
 'vibe3d.editing.tools.interactive.tests.unit.tools.create.tube_test',
 'vibe3d.editing.tools.interactive.tests.unit.tools.edit.preview_topology_churn_test',
 'vibe3d.editing.tools.interactive.tests.unit.tools.edit.smooth_relax_test',
 'vibe3d.editing.tools.interactive.tests.unit.tools.edit.tack_test',
 'vibe3d.editing.tools.interactive.tests.unit.tools.slice.edge_slice_tool_test',
 'vibe3d.editing.tools.interactive.tests.unit.tools.slice.loop_slice_tool_test',
 'vibe3d.editing.tools.interactive.tests.unit.tools.slice.slice_tool_test',
 'vibe3d.editing.tools.interactive.tests.unit.tools.transform.rotate_test',
 'vibe3d.editing.tools.interactive.tests.unit.tools.transform.transform_test',
 'vibe3d.editing.tools.interactive.tests.unit.topology_step_mixin_test',
 'vibe3d.editing.tools.interactive.tests.unit.wrapper_shift_apply_inheritance_test',
 'vibe3d.editing.tools.interactive.tool',
 'vibe3d.editing.tools.interactive.tool_disarm_source_cells',
 'vibe3d.editing.tools.interactive.tool_presets_source_cells',
 'vibe3d.editing.tools.interactive.tools.alignment.mirror',
 'vibe3d.editing.tools.interactive.tools.common.command_wrapper',
 'vibe3d.editing.tools.interactive.tools.create.arc',
 'vibe3d.editing.tools.interactive.tools.create.box',
 'vibe3d.editing.tools.interactive.tools.create.create_common_source_cells',
 'vibe3d.editing.tools.interactive.tools.create.pen',
 'vibe3d.editing.tools.interactive.tools.create.sphere',
 'vibe3d.editing.tools.interactive.tools.edit.bridge_tool',
 'vibe3d.editing.tools.interactive.tools.edit.bridge_tool_source_cells',
 'vibe3d.editing.tools.interactive.tools.edit.edge_extend_source_cells',
 'vibe3d.editing.tools.interactive.tools.edit.edge_extrude',
 'vibe3d.editing.tools.interactive.tools.edit.poly_bevel',
 'vibe3d.editing.tools.interactive.tools.edit.poly_extrude',
 'vibe3d.editing.tools.interactive.tools.edit.tack',
 'vibe3d.editing.tools.interactive.tools.edit.topology_pen.move_protocol_test',
 'vibe3d.editing.tools.interactive.tools.edit.topology_pen.press_compatibility_test',
 'vibe3d.editing.tools.interactive.tools.slice.slice_tool',
 'vibe3d.editing.tools.interactive.tools.transform.rotate',
 'vibe3d.editing.tools.interactive.tools.transform.transform',
 'vibe3d.editing.tools.interactive.tools.transform.xfrm_transform',
 'vibe3d.editing.tools.interactive.unit.bevel_cold_arm_param_image_test',
 'vibe3d.editing.tools.interactive.unit.prepared_param_update_test',
 'vibe3d.editing.tools.interactive.unit.prepared_tool_transition_test',
 'vibe3d.editing.tools.state.tests.unit.session_mesh_key_stamp_as_test',
 'vibe3d.editing.tools.state.tests.unit.tool_state_population_test',
 'vibe3d.editing.tools.state.tests.unit.tools.common.session_mesh_key_test',
 'vibe3d.editing.tools.state.tests.unit.tools.edit.preview_rebuild_test',
 'vibe3d.editing.tools.state.tools.common.session_mesh_key',
 'vibe3d.editing.tools.transform.tests.unit.ortho_relocate_prior_test',
 'vibe3d.editing.tools.transform.tests.unit.tools.transform.arcball_regression_test',
 'vibe3d.editing.tools.transform.tests.unit.tools.transform.arcball_test',
 'vibe3d.editing.tools.transform.tests.unit.tools.transform.item_xform_kernels_test',
 'vibe3d.editing.tools.transform.tests.unit.tools.transform.item_xform_regression_test',
 'vibe3d.editing.tools.transform.tests.unit.tools.transform.morph_route_test',
 'vibe3d.editing.tools.transform.tests.unit.tools.transform.scale_input_test',
 'vibe3d.editing.tools.transform.tests.unit.tools.transform.transform_ops_population_test',
 'vibe3d.editing.tools.transform.tests.unit.tools.transform.xform_kernels_test',
 'vibe3d.editing.tools.transform.tools.transform.relocate_plane_test',
 'vibe3d.mesh.change.mesh_dirty',
 'vibe3d.mesh.contracts.mesh_corner_maps',
 'vibe3d.mesh.contracts.tests.unit.mesh_plane_types_test',
 'vibe3d.mesh.core.mesh',
 'vibe3d.mesh.core.mesh_planes',
 'vibe3d.mesh.core.tests.unit.mesh_key_test',
 'vibe3d.mesh.core.tests.unit.mesh_map_kind_test',
 'vibe3d.mesh.core.tests.unit.mesh_selsets_test',
 'vibe3d.mesh.core.tests.unit.mesh_topology_integration_test',
 'vibe3d.mesh.edit_log.mesh_edit_delta',
 'vibe3d.mesh.edit_log.mesh_edit_log_protocol_test',
 'vibe3d.mesh.edit_replay.mesh_edit_replay',
 'vibe3d.mesh.edit_replay.mesh_edit_replay_roundtrip_test',
 'vibe3d.mesh.edit_replay.tests.unit.mesh_edit_delta_test',
 'vibe3d.mesh.edit_replay.tests.unit.mesh_selsets_replay_test',
 'vibe3d.mesh.ops.mesh_ops.extrude',
 'vibe3d.mesh.ops.mesh_ops.loop_slice',
 'vibe3d.mesh.ops.mesh_ops.poly_bevel',
 'vibe3d.mesh.ops.mesh_ops.triangulate',
 'vibe3d.mesh.ops.tests.unit.mesh_analysis_test',
 'vibe3d.mesh.ops.tests.unit.mesh_edge_slice_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.bevel_fin_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.bevel_vertex_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.box_geom_corner_provenance_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.bridge_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.cleanup_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.connected_mask_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.cut_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.extrude_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.face_alignment_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.face_merge_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.loop_slice_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.poly_bevel_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.revolve_seam_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.revolve_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.seam_differential',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.select_loop_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.triangulate_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.vertex_pos_grid_test',
 'vibe3d.mesh.ops.tests.unit.mesh_wire_analysis_test',
 'vibe3d.mesh.ops.tests.unit.uv_island_test',
 'vibe3d.mesh.ops.tests.unit.uv_project_test',
 'vibe3d.mesh.ops.tests.unit.uv_relax_test',
 'vibe3d.mesh.ops.tests.unit.uv_transform_test',
 'vibe3d.mesh.ops.tests.unit.uv_unwrap_test',
 'vibe3d.mesh.ops.tests.unit.uv_weld_test',
 'vibe3d.mesh.preview.tests.unit.morph_routing_law_test',
 'vibe3d.mesh.snapshot.tests.unit.mesh_map_kind_snapshot_test',
 'vibe3d.mesh.snapshot.tests.unit.mesh_selsets_snapshot_test',
 'vibe3d.mesh.snapshot.tests.unit.mesh_wire_snapshot_test',
 'vibe3d.mesh.snapshot.tests.unit.snapshot_test',
 'vibe3d.mesh.topology.mesh_topo',
 'vibe3d.platform.file.io.file_dialog',
 'vibe3d.platform.input.eventlog',
 'vibe3d.platform.input.tests.unit.binding_resolve_test',
 'vibe3d.platform.input.tests.unit.eventlog_parser_test',
 'vibe3d.platform.input.tests.unit.eventlog_test',
 'vibe3d.platform.input.tests.unit.input_events_population_test',
 'vibe3d.platform.input.tests.unit.sdl_error_test',
 'vibe3d.platform.input.tests.unit.tool_input_test',
 'vibe3d.platform.input.tool_input',
 'vibe3d.render.backends.render_backends_population_test',
 'vibe3d.render.model.render_model_population_test',
 'vibe3d.runtime.ai3d.ai3d.worker_manager',
 'vibe3d.runtime.ai3d.tests.unit.ai3d.event_queue_source_public_test',
 'vibe3d.runtime.ai3d.tests.unit.ai3d.event_queue_test',
 'vibe3d.runtime.ai3d.tests.unit.ai3d.job_controller_test',
 'vibe3d.runtime.ai3d.tests.unit.ai3d.scene_validator_test',
 'vibe3d.runtime.ai3d.tests.unit.ai3d.stage_artifact_test',
 'vibe3d.runtime.ai3d.tests.unit.ai3d.worker_manager_source_public_test',
 'vibe3d.runtime.ai3d.tests.unit.ai3d.worker_manager_test',
 'vibe3d.runtime.ai_advisor.tests.unit.ai.analysis_test',
 'vibe3d.runtime.ai_advisor.tests.unit.ai.element_candidates_test',
 'vibe3d.runtime.ai_advisor.tests.unit.ai.exploration_source_public_test',
 'vibe3d.runtime.ai_advisor.tests.unit.ai.exploration_test',
 'vibe3d.runtime.ai_advisor.tests.unit.ai.interaction_log_test',
 'vibe3d.runtime.ai_advisor.tests.unit.ai.interaction_log_writer_test',
 'vibe3d.runtime.ai_advisor.tests.unit.ai.mode_candidates_test',
 'vibe3d.runtime.ai_advisor.tests.unit.ai.model_adapter_test',
 'vibe3d.runtime.ai_advisor.tests.unit.ai.ranker_schema_test',
 'vibe3d.runtime.ai_advisor.tests.unit.ai.support_loop_candidates_test',
 'vibe3d.runtime.ai_advisor.tests.unit.ai.training_dataset_test',
 'vibe3d.runtime.application_core.tests.unit.application_core_population_test',
 'vibe3d.runtime.application_core.tests.unit.command_invocation_test',
 'vibe3d.runtime.application_core.tests.unit.standalone_application_test',
 'vibe3d.runtime.document_actions.commands.image.commands',
 'vibe3d.runtime.document_actions.commands.layer.commands',
 'vibe3d.runtime.document_actions.tests.unit.commands.image.commands_test',
 'vibe3d.runtime.document_actions.tests.unit.commands.layer.add_injection_range_test',
 'vibe3d.runtime.document_actions.tests.unit.commands.layer.commands_source_public_test',
 'vibe3d.runtime.http.http_server',
 'vibe3d.runtime.remesh.remesh.region_stitch',
 'vibe3d.runtime.remesh.remesh.remesh_job',
 'vibe3d.runtime.remesh.tests.unit.remesh.remesh_job_source_public_test',
 'vibe3d.ui.editor.tests.unit.ui.channel_rows_test',
 'vibe3d.ui.editor.tests.unit.ui.command_notice_test',
 'vibe3d.ui.editor.tests.unit.ui.stat_rows_test',
 'vibe3d.ui.editor.ui.availability_source_test',
 'vibe3d.ui.editor.ui.image_rows',
 'vibe3d.ui.editor.ui.item_click_source_test',
 'vibe3d.ui.editor.ui.item_rows',
 'vibe3d.ui.editor.ui.viewport_render',
 'vibe3d.ui.forms.forms_source_test',
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
 'vibe3d.viewport.camera.tests.unit.camera_model_population_test',
 'vibe3d.viewport.camera.tests.unit.view_source_cells_test',
 'vibe3d.viewport.camera.tests.unit.view_test',
 'vibe3d.viewport.display_policy.tests.unit.camera_stamp_test',
 'vibe3d.viewport.display_policy.tests.unit.display_policy_population_test',
 'vibe3d.viewport.display_policy.tests.unit.retopology_display_model_test',
 'vibe3d.viewport.display_policy.tests.unit.retopology_dot_cull_test',
 'vibe3d.viewport.display_policy.tests.unit.retopology_line_shade_algorithm_cells_test',
 'vibe3d.viewport.display_policy.tests.unit.retopology_order_algorithm_cells_test',
 'vibe3d.viewport.display_policy.tests.unit.select_visibility_test',
 'vibe3d.viewport.display_policy.tests.unit.vertex_normals_test',
 'vibe3d.viewport.display_policy.tests.unit.viewport_scheme_test',
 'vibe3d.viewport.display_policy.tests.unit.weightmap_state_test',
 'vibe3d.viewport.gpu.gl_thread_guard',
 'vibe3d.viewport.gpu.mesh_gpu',
 'vibe3d.viewport.gpu.tests.unit.viewport_env_test',
 'vibe3d.viewport.gpu.tests.unit.viewport_gpu_population_test',
 'vibe3d.viewport.host.bg_gpu_cache',
 'vibe3d.viewport.host.image_plane_source_cells',
 'vibe3d.viewport.host.tests.unit.camera_intrinsics_test',
 'vibe3d.viewport.host.tests.unit.dirty_key_camera_stamp_test',
 'vibe3d.viewport.host.tests.unit.dirty_key_tool_preview_test',
 'vibe3d.viewport.host.tests.unit.dirty_key_weightmap_test',
 'vibe3d.viewport.host.tests.unit.image_cache_test',
 'vibe3d.viewport.host.tests.unit.image_plane_test',
 'vibe3d.viewport.host.tests.unit.viewport_plane_turn_test',
 'vibe3d.viewport.host.tests.unit.viewport_test',
 'vibe3d.viewport.subpatch.tests.unit.subpatch_key_fold_test',
 'vibe3d.viewport.subpatch.tests.unit.subpatch_level_policy_test',
 'vibe3d.viewport.subpatch.tests.unit.subpatch_osd_test',
 'vibe3d.viewport.subpatch.tests.unit.subpatch_preview_population_test'}
        self.assertEqual(len(enabled), 376)
        modules = {support.compiler_module(path) for owner in owners
                   for field in ('sources', 'testSources', 'testHelpers', 'transitionalSources')
                   for path in support.SPECS[owner].get(field, []) if path.endswith('.d')}
        root_only = {'vibe3d.mesh.ops.tests.unit.mesh_ops.cut_test',
                     'vibe3d.ui.editor.ui.viewport_render'}
        self.assertEqual(root_only & modules, set(),
                         'isolated support excludes approved cut carrier and desktop viewport peer')
        isolated_enabled = enabled - root_only
        self.assertEqual(len(isolated_enabled), 374)
        self.assertEqual(modules & support.ENABLED_MODULES, isolated_enabled,
                         'final isolated support identities, independent global376 retained')
        self.assertEqual(support.compiler_module('../../../../tests/unit/fixtures.d'),
                         'tests.unit.fixtures')
        self.assertEqual(support.compiler_module('../../../../tests/unit/mesh_by_value_gate.d'),
                         'tests.unit.mesh_by_value_gate')
        self.assertEqual(support.compiler_module('../../../../../tests/unit/fixtures.d'),
                         'tests.unit.fixtures')
        self.assertEqual(support.compiler_module('../../../../../tests/unit/mesh_by_value_gate.d'),
                         'tests.unit.mesh_by_value_gate')
        self.assertEqual(support.compiler_module('../../../tests/unit/fixtures.d'),
                         'tests.unit.fixtures')
        self.assertEqual(support.compiler_module('../../../tests/unit/mesh_by_value_gate.d'),
                         'tests.unit.mesh_by_value_gate')
        self.assertNotEqual(support.compiler_module('../../../../tests/unit/fixtures_extra.d'),
                            'tests.unit.fixtures', 'neighboring helper cannot acquire the retained declaration')
        output = ''.join('PKG-MODULE name=' + name + ' unittest='
                         + str(int(name in isolated_enabled)) + '\n' for name in sorted(modules))
        output += '374 modules passed unittests\n'
        output += 'MeshSnapshotFixtures: adjacency restore and keep-selection cells passed\n'
        for owner in owners:
            with self.subTest(owner=owner):
                support.validate_runtime(output, owner)

    def test_current_support_raw_tree(self):
        actual = Path(__file__).resolve().parents[1]
        self.assertEqual(len(support.SPECS), 55)
        # Execute the existing archive-input and staged-validator statements,
        # including lower algorithm owners, without constructing a new runner.
        execute = next(node for node in ast.parse(Path(support.__file__).read_text()).body
                       if isinstance(node, ast.FunctionDef) and node.name == 'execute')
        member = next(node for node in execute.body if isinstance(node, ast.AugAssign)
                      and isinstance(node.target, ast.Name) and node.target.id == 'members'
                      and 'PACKAGE_FIXTURES' in ast.unparse(node))
        validation = next(node for node in execute.body if isinstance(node, ast.For)
                          and isinstance(node.target, ast.Name) and node.target.id == 'selected')
        desktop_guard = next(node for node in execute.body if isinstance(node, ast.Expr)
                             and any(isinstance(item, ast.Constant) and item.value ==
                                     'PREPARATION-REFUSED: desktop production root'
                                     for item in ast.walk(node)))
        desktop_check = compile(ast.Module(body=[desktop_guard], type_ignores=[]),
                                support.__file__, 'exec')
        with tempfile.TemporaryDirectory(prefix='boundary-desktop-exclusion-') as directory:
            archive = Path(directory)
            namespace = dict(support.__dict__, archive=archive)
            exec(desktop_check, namespace)
            desktop = archive / 'apps/desktop/source'
            desktop.mkdir(parents=True)
            with self.assertRaisesRegex(support.BoundaryError, 'desktop production root'):
                exec(desktop_check, namespace)
            desktop.rmdir()
            exec(desktop_check, namespace)
        expected_owners = {
            'alignment-ops': {'alignment-ops'}, 'creation-ops': {'creation-ops'},
            'viewport-gpu': {'viewport-gpu'}, 'selection-model': {'viewport-gpu'},
            'editor-ui': {'alignment-ops', 'creation-ops', 'viewport-gpu', 'interactive-tools', 'ai3d-runtime'},
        }
        for owner, selected in expected_owners.items():
            with self.subTest(archive_resources=owner), tempfile.TemporaryDirectory() as directory:
                staged = Path(directory)
                namespace = dict(support.__dict__, owner=owner, members=[], archive=staged, project=actual)
                exec(compile(ast.Module(body=[member], type_ignores=[]), support.__file__, 'exec'), namespace)
                expected = [path for selected_owner in sorted(selected)
                            for path, _ in support.PACKAGE_FIXTURES[selected_owner]]
                self.assertEqual(namespace['members'], expected, 'algorithm closure archive resource membership')
                for path in expected:
                    target = staged / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(actual / path, target)
                validator = compile(ast.Module(body=[validation], type_ignores=[]), support.__file__, 'exec')
                exec(validator, namespace)
                missing = staged / expected[0]
                saved = missing.read_bytes()
                missing.unlink()
                with self.assertRaises(support.BoundaryError, msg='algorithm closure missing staged resource refusal'):
                    exec(validator, namespace)
                missing.write_bytes(saved)
                missing.write_bytes(saved + b'bad')
                with self.assertRaises(support.BoundaryError, msg='algorithm closure staged resource hash refusal'):
                    exec(validator, namespace)
        for owner in support.SPECS:
            with self.subTest(owner=owner):
                support.check_raw_tree(actual, owner)

        order_blocks = [node for node in execute.body if isinstance(node, ast.If)
                        and any(isinstance(item, ast.Constant) and item.value ==
                                'support editor-ui ImportC D-before-C order'
                                for item in ast.walk(node))]
        self.assertEqual(len(order_blocks), 1, 'editor-ui production order block')
        order_block = order_blocks[0]
        self.assertEqual(ast.dump(order_block.test), ast.dump(ast.parse("owner=='editor-ui'", mode='eval').body),
                         'editor-ui production order owner')
        order_index = execute.body.index(order_block)
        before, after = execute.body[order_index - 1], execute.body[order_index + 1]
        self.assertTrue(isinstance(before, ast.Assign) and len(before.targets) == 1
                        and isinstance(before.targets[0], ast.Name) and before.targets[0].id == 'built'
                        and isinstance(before.value, ast.Call) and isinstance(before.value.func, ast.Name)
                        and before.value.func.id == 'run' and before.value.args
                        and isinstance(before.value.args[-1], ast.Constant)
                        and before.value.args[-1].value == 'production-build'
                        and isinstance(after, ast.Expr) and isinstance(after.value, ast.Call)
                        and isinstance(after.value.func, ast.Name) and after.value.func.id == 'require'
                        and len(after.value.args) == 2 and isinstance(after.value.args[1], ast.Constant)
                        and after.value.args[1].value == 'NO-VERDICT: ordinary static archive missing',
                        'editor-ui production order moment')
        order_check = compile(ast.Module(body=[order_block], type_ignores=[]), support.__file__, 'exec')
        editor_root = (actual / support.SPECS['editor-ui']['root']).resolve()
        anchor = str((editor_root / 'source/vibe3d/ui/editor/args_dialog.d').resolve())
        native = str((editor_root / 'source/vibe3d/ui/editor/imgui_flag_abi.c').resolve())
        expected = [str(path) for path in support.production_files(actual, 'editor-ui')]
        self.assertEqual(len(expected), 41, 'editor-ui production fixture population')
        self.assertEqual(len(set(expected)), 41, 'editor-ui production fixture unique')
        self.assertEqual(expected.count(anchor), 1, 'editor-ui production fixture anchor')
        self.assertEqual(expected.count(native), 1, 'editor-ui production fixture native')
        self.assertEqual(sum(path.endswith('.d') for path in expected), 40,
                         'editor-ui production fixture D population')
        positive = expected.copy()
        d_positions = [index for index, path in enumerate(positive) if path.endswith('.d')]
        left, right = d_positions[-2:]
        positive[left], positive[right] = positive[right], positive[left]
        self.assertNotEqual(positive, sorted(positive), 'editor-ui production fixture nonlexical')
        self.assertLess(positive.index(anchor), positive.index(native))
        positive_argv = ['dmd', '-lib'] + positive + ['-of=boundary-editor.a']
        unrelated = '[cwd=' + str(actual) + '] ' + shlex.join(['dmd', '-c', str(actual / 'unrelated.d')]) + '\n'
        receipt_names = ('production-editor-ui-actual-compiler-argv.json',
                         'production-editor-ui-actual-response-inputs.json')

        def order_log(sources):
            return '[cwd=' + str(actual) + '] ' + shlex.join(
                ['dmd', '-lib'] + sources + ['-of=boundary-editor.a']) + '\n'

        def run_order(log, evidence, owner='editor-ui'):
            namespace = dict(support.__dict__, owner=owner, archive=actual, root=editor_root,
                             built=subprocess.CompletedProcess([], 0, log, ''), evidence=evidence)
            exec(order_check, namespace)

        def positive_order():
            with tempfile.TemporaryDirectory(prefix='boundary-editor-order-positive-') as directory:
                evidence = Path(directory)
                try:
                    run_order(order_log(positive) + unrelated, evidence)
                except support.BoundaryError as error:
                    self.fail('editor-ui selected command positive: ' + str(error))
                self.assertTrue(all((evidence / name).is_file() for name in receipt_names),
                                'editor-ui production receipt files')
                commands = json.loads((evidence / receipt_names[0]).read_text())
                self.assertEqual(len(commands), 2, 'editor-ui production raw receipt')
                selected = [command for command in commands if anchor in command['sourceInputs']]
                self.assertEqual(len(selected), 1, 'editor-ui selected command positive')
                self.assertEqual(selected[0]['sourceInputs'], positive, 'editor-ui production raw receipt')
                self.assertEqual(selected[0]['argv'], positive_argv, 'editor-ui production raw receipt')
                self.assertEqual(json.loads((evidence / receipt_names[1]).read_text()), {},
                                 'editor-ui production response receipt')

        def refused_order(log, message, label):
            with tempfile.TemporaryDirectory(prefix='boundary-editor-order-negative-') as directory:
                evidence = Path(directory)
                with self.assertRaises(support.BoundaryError, msg=label) as refusal:
                    run_order(log, evidence)
                self.assertEqual(str(refusal.exception), message, label)
                self.assertFalse(any((evidence / name).exists() for name in receipt_names),
                                 'editor-ui negative has no success receipts')

        positive_order()
        population = 'support editor-ui production compiler population'
        refused_order(order_log(positive) + order_log(positive), population,
                      'editor-ui production population two')
        refused_order(unrelated + order_log([path for path in positive if path != anchor]), population,
                      'editor-ui production population zero')
        positive_order()
        other_d = next(path for path in positive if path.endswith('.d') and path != anchor)
        identity = 'support editor-ui production compiler source identity'
        for sources, label in (
                (positive + [str(actual / 'extra.d')], 'extra'),
                ([path for path in positive if path != native], 'native absent'),
                (positive + [native], 'native duplicate'),
                (positive + [anchor], 'anchor duplicate'),
                ([path for path in positive if path != other_d], 'D absent'),
                (positive + [other_d], 'D duplicate')):
            refused_order(order_log(sources), identity, 'editor-ui production identity ' + label)
        reversed_order = positive.copy()
        anchor_index, native_index = reversed_order.index(anchor), reversed_order.index(native)
        reversed_order[anchor_index], reversed_order[native_index] = reversed_order[native_index], reversed_order[anchor_index]
        self.assertEqual(sorted(reversed_order), expected, 'editor-ui reversal full membership')
        refused_order(order_log(reversed_order), 'support editor-ui ImportC D-before-C order',
                      'editor-ui raw-order reversal')
        positive_order()
        with tempfile.TemporaryDirectory(prefix='boundary-editor-order-bypass-') as directory:
            evidence = Path(directory)
            run_order('unparseable compiler log', evidence, owner='render-model')
            self.assertFalse(any((evidence / name).exists() for name in receipt_names),
                             'editor-ui noneditor skip receipts')

    def test_current_app_renderer_description(self):
        actual = Path(__file__).resolve().parents[1]
        result = subprocess.run(['dub', 'describe', '--root=' + str(actual),
            '--config=with-render', '--compiler=dmd', '--nodeps', '--skip-registry=all', '--quiet'],
            cwd=actual, text=True, capture_output=True, check=True)
        description = json.loads(result.stdout)
        support.renderer_description(description, actual, 'app', 'with-render')
        result = subprocess.run(['dub', 'describe', '--root=' + str(actual / 'libraries/render/model'),
            '--config=with-render', '--compiler=dmd', '--nodeps', '--skip-registry=all', '--quiet'],
            cwd=actual, text=True, capture_output=True, check=True)
        direct = json.loads(result.stdout)
        self.assertEqual(direct['rootPackage'], 'render-model')
        self.assertEqual(support.SPECS['render-model']['name'], 'vibe3d:render-model')
        support.renderer_description(direct, actual, 'render-model', 'with-render')
        changed = copy.deepcopy(direct)
        changed['rootPackage'] = 'vibe3d:render-model'
        with self.assertRaisesRegex(support.BoundaryError, 'renderer resolved root identity'):
            support.renderer_description(changed, actual, 'render-model', 'with-render')
        changed = copy.deepcopy(description)
        changed['rootPackage'] = 'render-model'
        with self.assertRaisesRegex(support.BoundaryError, 'renderer resolved root identity'):
            support.renderer_description(changed, actual, 'app', 'with-render')
        self.assertFalse(support.is_internal('render-model'))
        self.assertTrue(support.is_internal('render-model', 'render-model'))
        self.assertEqual(support.internal_owner('render-model', 'render-model'), 'render-model')
        with tempfile.TemporaryDirectory(prefix='boundary-renderer-outside-') as directory:
            outside=Path(directory)/'render-model'
            shutil.copytree(actual/'libraries/render/model',outside,
                            ignore=shutil.ignore_patterns('.dub','*.a'))
            changed=copy.deepcopy(direct)
            next(p for p in changed['packages'] if p['name']=='render-model')['path']=str(outside)
            with self.assertRaisesRegex(support.BoundaryError, 'renderer internal owner path'):
                support.renderer_description(changed,actual,'render-model','with-render')
        with self.assertRaisesRegex(support.BoundaryError, 'unknown internal identity: render-model'):
            support.internal_owner('render-model')
        self.assertFalse(support.is_internal('render-model', 'camera-model'))
        with self.assertRaisesRegex(support.BoundaryError, 'unknown internal identity: render-model'):
            support.internal_owner('render-model', 'camera-model')
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
            (root/'dub.json').write_text(json.dumps(raw))
            source=ast.parse(Path(support.__file__).read_text())
            function=next(n for n in source.body if isinstance(n,ast.FunctionDef)
                          and n.name=='renderer_compile_target')
            selected_name=next(n for n in function.body if isinstance(n,ast.Assign)
                               and any(isinstance(t,ast.Name) and t.id=='selected_name' for t in n.targets))
            recipe_write=next(n for n in function.body if isinstance(n,ast.Expr)
                              and isinstance(n.value,ast.Call) and isinstance(n.value.func,ast.Attribute)
                              and isinstance(n.value.func.value,ast.Name) and n.value.func.value.id=='recipe')
            selected_target=next(n for n in function.body if isinstance(n,ast.Assign)
                                 and any(isinstance(t,ast.Name) and t.id=='own_target' for t in n.targets))
            recipe_producer=compile(ast.Module(body=[selected_name,recipe_write],
                                               type_ignores=[]),support.__file__,'exec')
            target_check=compile(ast.Module(body=[selected_target],type_ignores=[]),support.__file__,'exec')
            for parent_name,probe_name in (('vibe3d:math','vibe3d-math'),('math','math'),('render-model','render-model'),
                    ('vibe3d-render-backends','vibe3d-render-backends'),
                    ('vibe3d-math-tests','vibe3d-math-tests'),('boundary:external','boundary:external')):
                recipe=root/'selected.recipe.json';parent_target={'rootPackage':parent_name}
                probe_target={'rootPackage':probe_name,'buildSettings':{'versions':['WithRender']}}
                namespace=dict(support.__dict__,target=parent_target,recipe=recipe,
                               package={'targetType':'staticLibrary'},construction={'name':'with-render',
                                   'sourceFiles':[str(root/'entry.d')],
                                   'versions':['WithRender','WithAI','Have_vibe3d_math']},
                               build='debug',own_description={'targets':[probe_target]})
                exec(recipe_producer,namespace)
                self.assertEqual(json.loads(recipe.read_text())['name'],probe_name,
                                 'synthetic standalone recipe retains its independently expected probe identity')
                try:
                    exec(target_check,namespace)
                except StopIteration:
                    self.fail('standalone selector must accept the independently expected probe target identity')
                self.assertIs(namespace['own_target'],probe_target)
                self.assertEqual(parent_target,{'rootPackage':parent_name},
                                 'selected context retains the qualified parent target identity')
                if parent_name=='vibe3d:math':
                    described=subprocess.run(['dub','describe','--root='+str(root),'--config=with-render',
                        '--compiler=dmd','--build=debug','--nodeps','--skip-registry=all','--quiet',
                        '--recipe='+str(recipe)],cwd=root,env=env,text=True,capture_output=True,check=True)
                    self.assertEqual([(t['rootPackage'],t['buildSettings'].get('versions',[]))
                                      for t in json.loads(described.stdout)['targets']],
                                     [('vibe3d-math',['WithRender','WithAI','Have_vibe3d_math'])],
                                     'synthetic probe preserves the exact selected parent automatic version identity')
                    namespace['own_description']={'targets':[parent_target]}
                    with self.assertRaises(StopIteration):
                        exec(target_check,namespace)
            expected=next(n for n in function.body if isinstance(n,ast.Assign)
                          and any(isinstance(t,ast.Name) and t.id=='expected_links' for t in n.targets))
            guard=next(n for n in function.body if isinstance(n,ast.Expr)
                       and isinstance(n.value,ast.Call) and n.value.args
                       and any(isinstance(a,ast.Constant) and isinstance(a.value,str)
                               and 'formatted ordered native link flags' in a.value
                               for a in ast.walk(n)))
            check=compile(ast.Module(body=[expected,guard],type_ignores=[]),support.__file__,'exec')
            with_render=next(n for n in function.body if isinstance(n,ast.If)
                             and any(isinstance(a,ast.Constant) and isinstance(a.value,str)
                                     and 'required active WithRender' in a.value for a in ast.walk(n)))
            role_check=compile(ast.Module(body=[with_render],type_ignores=[]),support.__file__,'exec')
            for name in ('render-model','vibe3d:render-model','render-backends','vibe3d:render-backends'):
                namespace=dict(support.__dict__,target={'rootPackage':name},label='fixture-role',
                               settings={'versions':['WithRender']})
                exec(role_check,namespace)
                namespace['settings']={'versions':[]}
                with self.assertRaisesRegex(support.BoundaryError, 'required active WithRender: fixture-role'):
                    exec(role_check,namespace)
            exec(role_check,dict(support.__dict__,target={'rootPackage':'boundary-external'},
                                 label='fixture-external',settings={'versions':[]}))
            binary=next(n for n in function.body if isinstance(n,ast.Assign)
                        and any(isinstance(t,ast.Name) and t.id=='binary' for t in n.targets))
            archive_check=compile(ast.Expression(binary.value),support.__file__,'eval')
            for name,recipe,archive in (
                    ('render-model',{'name':'render-model','targetName':'vibe3d-render-model'},
                     'libvibe3d-render-model.a'),
                    ('render-backends',{'name':'render-backends','targetName':'vibe3d-render-backends'},
                     'libvibe3d-render-backends.a')):
                self.assertEqual(eval(archive_check,dict(support.__dict__,root=root,raw=recipe,
                                     target={'rootPackage':name},package={'targetType':'staticLibrary'})),
                                 root/archive,'renderer retains the original owner archive identity')
            functions={n.name:n for n in source.body if isinstance(n,ast.FunctionDef)}
            execute=functions['execute_renderer']
            archive_setup=[n for n in execute.body if isinstance(n,ast.Assign)
                           and any(isinstance(t,ast.Name) and t.id in ('members','metadata') for t in n.targets)]
            archive_setup+= [n for n in execute.body if isinstance(n,ast.AugAssign)
                            and isinstance(n.target,ast.Name) and n.target.id=='members']
            actual=Path(__file__).resolve().parents[1]
            namespace=dict(support.__dict__,project=actual,owner='render-model')
            exec(compile(ast.Module(body=archive_setup,type_ignores=[]),support.__file__,'exec'),namespace)
            self.assertEqual({p for p in namespace['members'] if (actual/p).is_dir()},
                             {'libraries/render/model','libraries/util/math'},
                             'renderer archive retains its exact two selected source roots')
            self.assertIn('dub.json',namespace['members'],'parent path dependency retains the real root recipe')
            self.assertIn('libraries/viewport/camera/dub.json',namespace['members'],
                          'root registration retains unselected real descriptor metadata')
            self.assertNotIn('apps/desktop/source/vibe3d/apps/desktop/app.d',namespace['members'],'metadata never grants desktop source')
            self.assertIn('apps/cli/dub.json',namespace['members'],'root registration retains the current CLI descriptor')
            self.assertNotIn('tools/cli/dub.json',namespace['members'],'retired CLI descriptor is absent')
            app_namespace=dict(support.__dict__,project=actual,owner='app')
            exec(compile(ast.Module(body=archive_setup,type_ignores=[]),support.__file__,'exec'),app_namespace)
            self.assertEqual(app_namespace['members'],[],'app retains the full-tree archive sentinel')
            self.assertEqual(app_namespace['metadata'],[],'app needs no selected-owner metadata supplement')
            archive_guard=next(n for n in execute.body if isinstance(n,ast.If)
                               and any(isinstance(a,ast.Constant) and isinstance(a.value,str)
                                       and 'root recipe metadata identity' in a.value for a in ast.walk(n)))
            archive_check=compile(ast.Module(body=[archive_guard],type_ignores=[]),support.__file__,'exec')
            isolated=root/'isolated';isolated.mkdir()
            desktop_guard=next(n for n in execute.body if isinstance(n,ast.If)
                               and any(isinstance(item,ast.Constant) and item.value ==
                                       'support renderer isolated archive contains desktop'
                                       for item in ast.walk(n)))
            desktop_check=compile(ast.Module(body=[desktop_guard],type_ignores=[]),
                                  support.__file__,'exec')
            guard_namespace=dict(support.__dict__,owner='render-model',archive=isolated)
            exec(desktop_check,guard_namespace)
            desktop=isolated/'apps/desktop/source';desktop.mkdir(parents=True)
            with self.assertRaisesRegex(support.BoundaryError, 'isolated archive contains desktop'):
                exec(desktop_check,guard_namespace)
            exec(desktop_check,dict(guard_namespace,owner='app'))
            desktop.rmdir()
            exec(desktop_check,guard_namespace)
            original=(actual/'dub.json').read_bytes();(isolated/'dub.json').write_bytes(original)
            namespace['archive']=isolated
            exec(archive_check,namespace)
            app_namespace=dict(namespace,owner='app',metadata=[])
            exec(archive_check,app_namespace)
            (isolated/'dub.json').write_bytes(b'{}\n')
            with self.assertRaisesRegex(support.BoundaryError, 'root recipe metadata identity'):
                exec(archive_check,namespace)
            (isolated/'dub.json').write_bytes(original)
            namespace['metadata']=[p for p in namespace['metadata'] if p!='dub.json']
            with self.assertRaisesRegex(support.BoundaryError, 'root recipe metadata identity'):
                exec(archive_check,namespace)
            direct_owner=next(n for n in execute.body if isinstance(n,ast.Assign)
                             and any(isinstance(t,ast.Name) and t.id=='direct_owner' for t in n.targets))
            selected=next(n for n in execute.body if isinstance(n,ast.If)
                          and any(isinstance(a,ast.Constant) and isinstance(a.value,str)
                                  and 'unexpected native/external dependency' in a.value for a in ast.walk(n)))
            direct_check=compile(ast.Module(body=[direct_owner],type_ignores=[]),support.__file__,'exec')
            namespace=dict(support.__dict__,owner='app')
            exec(direct_check,namespace)
            self.assertIsNone(namespace['direct_owner'],'app retains the global internal-identity scope')
            active_check=compile(ast.Module(body=[direct_owner]+selected.body,type_ignores=[]),
                                 support.__file__,'exec')
            active={'render-model':{},'vibe3d:render-model':{}}
            namespace=dict(support.__dict__,owner='render-model',active=active)
            exec(active_check,namespace)
            namespace['active']=dict(active,**{'boundary-external':{}})
            with self.assertRaisesRegex(support.BoundaryError, 'render-model unexpected native/external dependency'):
                exec(active_check,namespace)
            staging=next(n for n in execute.body if isinstance(n,ast.Assign)
                         and any(isinstance(t,ast.Name) and t.id=='dependencies' for t in n.targets))
            native=next(n for n in functions['renderer_native_receipt'].body if isinstance(n,ast.Assign)
                        and any(isinstance(t,ast.Name) and t.id=='external' for t in n.targets))
            namespace.update(active=dict(active,**{'vibe3d':{},'boundary-external':{}}))
            for expression in (staging.value.args[0],native.value):
                self.assertEqual(eval(compile(ast.Expression(expression),support.__file__,'eval'),namespace),
                                 {'boundary-external':{}},'selected renderer is internal in each native filter')
                namespace['direct_owner']=None
                self.assertEqual(eval(compile(ast.Expression(expression),support.__file__,'eval'),namespace),
                                 {'render-model':{},'boundary-external':{}},
                                 'global native filters retain an unselected local identity as external')
                namespace['direct_owner']='render-model'
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
        roles = (
            ('libraries/editing/commands/runtime', 'vibe3d:command-runtime', 'modeling-noai'),
            ('libraries/runtime/application-core', 'vibe3d:application-core', 'modeling-noai'),
            ('tests/core', 'vibe3d-core-tests', 'core'),
            ('apps/cli', 'vibe3d:cli', 'application'))
        for relative, owner, config in roles:
            root = self.project / relative
            self.assertEqual(boundary.descriptor_context(root), (self.project, relative, owner),
                             'standalone exact physical role and selected root ID')
            self.assertEqual(boundary.describe_arguments(root, config, 'dmd'),
                ['dub', 'describe'] + ([] if relative == 'tests/core' else [owner])
                + ['--root=' + str(root if relative == 'tests/core' else self.project),
                   '--config=' + config, '--compiler=dmd', '--quiet'],
                'standalone role selects project root or independent CORE root')
        for relative in ('packages/command-runtime', 'packages/application-core', 'tools/cli',
                         'libraries/editing/runtime', 'tests/core/source', 'apps/cli/source'):
            with self.subTest(wrong_coordinate=relative), self.assertRaisesRegex(
                    boundary.BoundaryError, 'unexpected root package coordinate'):
                boundary.descriptor_context(self.project / relative)
        roots = boundary.validate_package_settings(self.descriptions['tests/core'], self.project / 'tests/core')
        self.assertEqual(tuple(path.name for path in roots), boundary.CORE_ROOTS,
                         'independent CORE retains its five mapped root identities')
        cli_roots = boundary.validate_package_settings(self.descriptions['apps/cli'], self.project / 'apps/cli')
        self.assertEqual(cli_roots, [self.project / 'apps/cli/source/vibe3d/apps/cli/main.d'],
                         'CLI source belongs to its actual deep application role')
        # Mock only process/receipt boundaries: main itself must select the
        # role, actual validator, command cwd, and fresh output coordinate.
        with tempfile.TemporaryDirectory(prefix='boundary-main-role-') as directory:
            evidence = Path(directory)
            calls = []
            original = self.descriptions['apps/cli']
            def run(command, cwd, env, destination, label):
                calls.append((command, cwd, label))
                return subprocess.CompletedProcess(command, 0,
                    json.dumps(original) if label == 'describe' else '', '')
            binary = self.project / 'vibe3d-cli'
            binary.write_bytes(b'CLI role output witness\n')
            try:
                with patch.object(boundary, 'run', side_effect=run), patch.object(boundary.shutil, 'which', return_value='/compiler/dmd'), \
                     patch.object(support, 'compiler_commands', return_value=[]), \
                     patch.object(boundary.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'fixture-revision\n', '')):
                    boundary.main(['--root=' + str(self.project / 'apps/cli'), '--evidence-dir=' + str(evidence)])
                    self.assertEqual(calls, [
                        (['dub', 'describe', 'vibe3d:cli', '--root=' + str(self.project), '--config=application', '--compiler=/compiler/dmd', '--quiet'], self.project, 'describe'),
                        (['dub', 'build', 'vibe3d:cli', '--root=' + str(self.project), '--config=application', '--compiler=/compiler/dmd', '--force', '--verbose'], self.project, 'build-run')],
                        'CLI main uses root subpackage selection and project cwd')
                    witness = json.loads((evidence / 'witness.json').read_text())
                    self.assertEqual(witness['sources'], list(map(str, cli_roots)))
                    binary.unlink()
                    wrong = self.project / 'apps/cli/vibe3d-cli'
                    wrong.write_bytes(b'wrong staging witness\n')
                    try:
                        with self.assertRaisesRegex(boundary.BoundaryError,
                                'fresh DUB output missing: ' + re.escape(str(self.project / 'apps/cli/../../vibe3d-cli'))):
                            boundary.main(['--root=' + str(self.project / 'apps/cli'), '--evidence-dir=' + str(evidence)])
                    finally:
                        wrong.unlink()
            finally:
                binary.unlink(missing_ok=True)
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
                    self.assertEqual(set(affected), {'vibe3d:cli',support.SPECS['document-io']['name'],support.SPECS['image-codec']['name'],'d-stb-image'})
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
        for relative in ('libraries/editing/commands/runtime', 'libraries/runtime/application-core'):
            root = self.project / relative
            path = root / 'source/additional_model.d'
            original = self.descriptions[relative]
            owner = boundary.descriptor_context(root)[2]
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
        for relative, config in (('libraries/editing/commands/runtime', 'modeling-noai'), ('libraries/runtime/application-core', 'modeling-noai'), ('tests/core', 'core')):
            result = subprocess.run(boundary.describe_arguments(actual / relative, config, compiler),
                text=True, capture_output=True)
            self.assertEqual(result.returncode, 0,
                'LDC dub describe failed: ' + repr(result.args) + '\nstdout:\n' + result.stdout
                + '\nstderr:\n' + result.stderr)
            description = json.loads(result.stdout.replace(str(actual), str(self.project)))
            root = self.project / relative
            boundary.validate_package_settings(description, root, compiler)
            if relative != 'tests/core':
                owner = boundary.descriptor_context(root)[2]
                for name in (owner, support.SPECS['mesh-ops']['name']):
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
                for name in (owner, support.SPECS['mesh-ops']['name']):
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
