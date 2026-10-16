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
        self.assertEqual(len(census._WAVE19_CLIENT_IMPORTS), 943)
        self.assertEqual(sum(map(len, census._WAVE19_CLIENT_IMPORTS.values())), 5098)
        # Approved27 non-import identities: both referenced-owner states use
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
                for owner, old_root, new_root in census._WAVE19_OWNERS:
                    recipe = root / (new_root if moved else old_root) / 'dub.json'
                    recipe.parent.mkdir(parents=True, exist_ok=True)
                    recipe.write_text(json.dumps({'name': owner if moved else 'vibe3d-' + owner}))
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
                    relative = 'packages/interactive-tools/tests/source/tests/unit/prepared_tool_transition_test.d'
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

    def test_current_captured_client_import_projection(self):
        import hashlib
        import sys
        with patch.object(sys, 'path', [str(Path(__file__).resolve().parents[1] / 'tools/dspans'), *sys.path]):
            import census_contracts as census
        actual = Path(__file__).resolve().parents[1]
        source = actual / 'tools/dspans/census_contracts.py'
        tree = ast.parse(source.read_text())
        names = ('_WAVE19_OWNERS', '_WAVE19_COORDINATES', '_WAVE19_CLIENT_IMPORTS',
                 '_WAVE19_COORDINATE_PRIOR_IMPORTS', '_WAVE19_IDENTITIES', '_WAVE19_IDENTITY_PIN')
        namespace = {'_source_validity': [], 'dspans_client': census.dspans_client}
        for node in tree.body:
            if (isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
                    and node.targets[0].id in names):
                namespace[node.targets[0].id] = ast.literal_eval(node.value)
        functions = ('_wave19_moved', '_wave19_original', '_wave19_coordinate',
                     '_wave19_identity_intact', '_wave19_import_original')
        nodes = [node for node in tree.body
                 if isinstance(node, ast.FunctionDef) and node.name in functions]
        self.assertEqual({node.name for node in nodes}, set(functions))
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), 'exec'), namespace)
        clients = namespace['_WAVE19_CLIENT_IMPORTS']
        self.assertEqual(len(clients), 943)
        self.assertEqual(sum(map(len, clients.values())), 5098)
        inverse = namespace['_wave19_import_original']
        hashes = []
        for relative in sorted(clients):
            with self.subTest(path=relative):
                logical = inverse(actual / relative, (actual / relative).read_text(), actual)
                hashes.append((relative, hashlib.sha256(logical.encode()).hexdigest()))
        # Independently reconstructed immutable90 bodies plus five explicitly
        # reviewed D1 body deltas and three finite D2 reader/control transforms.
        # Expected construction never reads candidate client source for hashes.
        digest = hashlib.sha256(json.dumps(hashes, separators=(',', ':')).encode()).hexdigest()
        self.assertEqual(digest, '3dad8e2d2b297d5fba38d1507547f67d5629a87a558c50cf8dc50aba9eaa105f',
                         'Wave19 all943 current logical client bodies')
        # Newly owned sources retain their prior-D1 imported spelling only
        # while the D2 owner itself remains at the old coordinate. Exercise the
        # actual read_source_text old-coordinate branch for every37 source/84
        # imports, with independently frozen90 full-body hashes.
        prior = namespace['_WAVE19_COORDINATE_PRIOR_IMPORTS']
        self.assertEqual(len(prior), 37)
        self.assertEqual(sum(map(len, prior.values())), 84)
        self.assertFalse(set(prior) & set(clients))
        d2_owners = ('camera-model', 'image-codec', 'input-events', 'mesh-edit-log', 'mesh-topology', 'render-model', 'mesh', 'document-model', 'mesh-edit-replay', 'mesh-ops', 'mesh-preview', 'mesh-snapshot', 'pipe-contracts')
        owned_hashes = []
        with tempfile.TemporaryDirectory(prefix='boundary-prior-client-') as directory:
            root = Path(directory)
            for owner, old_root, new_root in census._WAVE19_OWNERS:
                moved = owner not in d2_owners
                recipe = root / (new_root if moved else old_root) / 'dub.json'
                recipe.parent.mkdir(parents=True, exist_ok=True)
                recipe.write_text(json.dumps({'name': owner if moved else 'vibe3d-' + owner}))
            for owner, old, new, spans in census._WAVE19_COORDINATES:
                moved = owner not in d2_owners
                offset, current, original = spans[0]
                physical = root / (new if moved else old)
                physical.parent.mkdir(parents=True, exist_ok=True)
                physical.write_text(' ' * (offset - 7) + 'module '
                                    + (current if moved else original) + ';\n')
            for relative in sorted(prior):
                owner, old, new, spans = next(row for row in census._WAVE19_COORDINATES
                                             if row[1] == relative)
                logical = namespace['_wave19_original']((actual / new).read_text(), spans)
                # Reapply only the captured prior-D1 imports to an original
                # body; D2 referenced owners remain old in this fixture.
                current = logical
                for offset, chosen, original, referenced_owner in reversed(prior[relative]):
                    self.assertNotIn(referenced_owner, d2_owners)
                    self.assertEqual(current[offset:offset + len(original)], original)
                    current = current[:offset] + chosen + current[offset + len(original):]
                (root / relative).write_text(current)
                projected = census.read_source_text(root / relative, root=root)
                owned_hashes.append((relative, hashlib.sha256(projected.encode()).hexdigest()))
        owned_digest = hashlib.sha256(json.dumps(owned_hashes, separators=(',', ':')).encode()).hexdigest()
        self.assertEqual(owned_digest, 'f38ab2d9fccfbcc20a8fb4f5593da678517c03bec2a0968e4cca23f7346dfa67',
                         'Wave19 all37 old-coordinate prior-import original90 bodies')
        relative = 'tests/unit/mesh_test.d'
        text = (actual / relative).read_text()
        for corrected, stale in ((44323, 44292), (223235, 223204)):
            rows = clients[relative]
            self.assertEqual(sum(row[0] == corrected for row in rows), 1)
            malformed = dict(clients)
            malformed[relative] = tuple((stale, *row[1:]) if row[0] == corrected else row
                                        for row in rows)
            with self.subTest(stale=stale), patch.dict(namespace, _WAVE19_CLIENT_IMPORTS=malformed):
                with self.assertRaisesRegex(ValueError, 'Wave19 declaration/import coordinate'):
                    inverse(actual / relative, text, actual)

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
 'pipe-contracts')
        enabled = {'tests.unit.fixtures',
 'tests.unit.mesh_by_value_gate',
 'vibe3d.documents.image_codec.tests.unit.image_codec_population_test',
 'vibe3d.documents.image_codec.tests.unit.io.image_decode_source_cells_test',
 'vibe3d.documents.image_codec.tests.unit.io.image_decode_test',
 'vibe3d.documents.model.tests.unit.document_test',
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
 'vibe3d.platform.input.eventlog',
 'vibe3d.platform.input.tests.unit.binding_resolve_test',
 'vibe3d.platform.input.tests.unit.eventlog_parser_test',
 'vibe3d.platform.input.tests.unit.eventlog_test',
 'vibe3d.platform.input.tests.unit.input_events_population_test',
 'vibe3d.platform.input.tests.unit.sdl_error_test',
 'vibe3d.platform.input.tests.unit.tool_input_test',
 'vibe3d.platform.input.tool_input',
 'vibe3d.render.model.render_model_population_test',
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
 'vibe3d.viewport.camera.tests.unit.view_test'}
        self.assertEqual(len(enabled), 89)
        self.assertEqual(support.compiler_module('../../../../tests/unit/fixtures.d'),
                         'tests.unit.fixtures')
        self.assertEqual(support.compiler_module('../../../../tests/unit/mesh_by_value_gate.d'),
                         'tests.unit.mesh_by_value_gate')
        modules = {support.compiler_module(path) for owner in owners
                   for field in ('sources', 'testSources', 'testHelpers', 'transitionalSources')
                   for path in support.SPECS[owner].get(field, []) if path.endswith('.d')}
        self.assertEqual(modules & support.ENABLED_MODULES, enabled,
                         'D1+D2 independently frozen enabled module identity')
        output = ''.join('PKG-MODULE name=' + name + ' unittest='
                         + str(int(name in enabled)) + '\n' for name in sorted(modules))
        output += '89 modules passed unittests\n'
        output += 'MeshSnapshotFixtures: adjacency restore and keep-selection cells passed\n'
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
            for name in ('render-model','vibe3d:render-model','vibe3d-render-backends'):
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
                    ('vibe3d-render-backends',{'name':'vibe3d-render-backends'},
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
            self.assertNotIn('source/app.d',namespace['members'],'metadata never grants desktop source')
            app_namespace=dict(support.__dict__,project=actual,owner='app')
            exec(compile(ast.Module(body=archive_setup,type_ignores=[]),support.__file__,'exec'),app_namespace)
            self.assertEqual(app_namespace['members'],[],'app retains the full-tree archive sentinel')
            self.assertEqual(app_namespace['metadata'],[],'app needs no selected-owner metadata supplement')
            archive_guard=next(n for n in execute.body if isinstance(n,ast.If)
                               and any(isinstance(a,ast.Constant) and isinstance(a.value,str)
                                       and 'root recipe metadata identity' in a.value for a in ast.walk(n)))
            archive_check=compile(ast.Module(body=[archive_guard],type_ignores=[]),support.__file__,'exec')
            isolated=root/'isolated';isolated.mkdir()
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
                    self.assertEqual(set(affected), {'vibe3d-cli','vibe3d-document-io',support.SPECS['image-codec']['name'],'d-stb-image'})
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
