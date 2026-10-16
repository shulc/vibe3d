#!/usr/bin/env python3
"""Finite Wave7 support-owner contracts; DUB/compiler own import resolution.

Task 20262180, application_layers_wave7_plan_2026-10-10.md §7A. Inactive
owners are not inferred from the tree. A selected missing owner is a refusal.
Execution archives HEAD, isolates dependency/native builds and retains receipts.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys
import tarfile
import tempfile


class BoundaryError(RuntimeError):
    pass


def legacy_require(condition, message):
    if not condition:
        raise BoundaryError(message)


legacy_SPECS = {
    'input-events': {
        'sources': ('eventlog', 'held_gesture_buttons', 'tool_input', 'input_zones', 'input_context', 'shortcuts'),
        'carriers': ('eventlog_test', 'eventlog_parser_test', 'binding_resolve_test', 'tool_input_test'),
        'private': ('eventlog', 'tool_input'), 'lower': ('common',),
        'external': ('bindbc-sdl', 'dyaml'), 'versions': ('SDL_2020',),
    },
    'display-policy': {
        'sources': ('camera_stamp', 'display_state', 'viewport_scheme', 'viewport_overlay_mode',
                    'viewport_probe_sampling', 'weightmap_view', 'light_rig', 'vertex_normals'),
        'carriers': ('camera_stamp_test', 'viewport_scheme_test', 'vertex_normals_test', 'weightmap_state_test'),
        'private': (), 'lower': ('common',), 'external': (), 'versions': (),
    },
    'viewport-gpu': {
        'sources': ('gl_thread_guard', 'gpu_pass_timer', 'mesh_gpu', 'shader', 'viewport_env', 'gpu_select'),
        'carriers': ('viewport_env_test',), 'private': ('gl_thread_guard', 'mesh_gpu'),
        'lower': ('common', 'display-policy'), 'external': ('bindbc-opengl',), 'versions': ('GL_33',),
    },
    'subpatch-preview': {
        'sources': ('subpatch_preview', 'subpatch_osd', 'subpatch_worker', 'subpatch_worker_web', 'subpatch_factories'),
        'carriers': ('subpatch_osd_test', 'subpatch_level_policy_test', 'subpatch_key_fold_test'),
        'private': (), 'lower': ('common', 'display-policy', 'viewport-gpu'),
        'external': ('d-opensubdiv', 'bindbc-opengl'), 'versions': ('GL_33',),
    },
}
legacy_CONFIGS = ('modeling', 'modeling-noai', 'with-render', 'web', 'root-tests')
legacy_REVISIONS = {
    'd-stb-image': ('a66f6917718ea128076a2c5660e37f362a785144', 'git+https://github.com/shulc/D-StbImage.git'),
    'dyaml': ('22e4724474795eefb64ee9742f980b49bb34f6ef', 'git+https://github.com/shulc/D-YAML.git'),
    'd-opensubdiv': ('e74bb683d869d31ddcb279b2f05bfaebd53065ee', 'git+https://github.com/shulc/D-OpenSubdiv.git'),
}
legacy_BINDINGS = {'bindbc-sdl': '~>1.5.2', 'bindbc-opengl': '~>1.1.1'}
legacy_EXTERNAL_DEPS = {'d-stb-image': (), 'dyaml': (), 'd-opensubdiv': (),
                 'bindbc-sdl': ('bindbc-common', 'bindbc-loader'),
                 'bindbc-opengl': ('bindbc-loader',), 'bindbc-common': (), 'bindbc-loader': ()}
legacy_ARCHIVES = {'d-stb-image': 'libd-stb-image.a', 'dyaml': 'libdyaml.a',
            'd-opensubdiv': 'libd-opensubdiv.a', 'bindbc-sdl': 'lib/libBindBC_SDL.a',
            'bindbc-opengl': 'lib/libBindBC_OpenGL.a', 'bindbc-common': 'lib/libBindBC_Common.a',
            'bindbc-loader': 'lib/libBindBC_Loader.a'}
legacy_FIXTURES = {
    'input-events': ('config/shortcuts.yaml', '99c14eaa556d365f42ead60e30db9aa926723b0ee0a9b1ae4f823542a10fbff8'),
    'viewport-gpu': ('assets/icon/png/vibe3d_16.png', '2efe412bb268afa882bbde043473c4e3990302ef76899938914b3e525ce7817e'),
}
legacy_HOOKS = ('preGenerateCommands', 'postGenerateCommands', 'preBuildCommands',
         'postBuildCommands', 'preRunCommands', 'postRunCommands')
legacy_META = ('description', 'license', 'authors', 'copyright')
# Compiler instrumentation and the common identity are frozen from the approved
# existing descriptor shape, not read from a future descriptor as expectations.
legacy_BUILD_TYPES = {'profile-fp': {'buildOptions': ['debugMode', 'debugInfo', 'optimize'],
                'dflags-dmd': ['-gs'],
                'dflags-ldc': ['--frame-pointer=all']},
 'perf': {'buildOptions': ['releaseMode', 'optimize', 'inline'], 'versions': ['PerfProbe']},
 'perf-count': {'buildOptions': ['debugMode', 'debugInfo'], 'versions': ['PerfProbe']},
 'perf-unit': {'buildOptions': ['debugMode', 'debugInfo', 'unittests'], 'versions': ['PerfProbe']},
 'check': {'buildOptions': ['debugMode', 'debugInfo'],
           'dflags-ldc': ['--boundscheck=on', '--checkaction=C', '--frame-pointer=all'],
           'versions': ['SanitizerSelfTest']},
 'check-unit': {'buildOptions': ['debugMode', 'debugInfo', 'unittests'],
                'dflags-ldc': ['--boundscheck=on', '--frame-pointer=all'],
                'versions': ['SanitizerSelfTest']},
 'check-release': {'buildOptions': ['releaseMode', 'optimize', 'inline', 'debugInfo'],
                   'dflags-ldc': ['--boundscheck=on', '--frame-pointer=all'],
                   'versions': ['SanitizerSelfTest']},
 'sanitize': {'buildOptions': ['debugMode', 'debugInfo'],
              'dflags-ldc': ['--fsanitize=address',
                             '--fsanitize-address-use-after-return=never',
                             '--checkaction=C',
                             '--frame-pointer=all'],
              'versions': ['SanitizerSelfTest']},
 'sanitize-unit': {'buildOptions': ['debugMode', 'debugInfo', 'unittests'],
                   'dflags-ldc': ['--fsanitize=address',
                                  '--fsanitize-address-use-after-return=never',
                                  '--frame-pointer=all'],
                   'versions': ['SanitizerSelfTest']},
 'tsan': {'buildOptions': ['debugMode', 'debugInfo'],
          'dflags-ldc': ['--fsanitize=thread', '--enable-asserts=false', '--frame-pointer=all'],
          'versions': ['SanitizerSelfTest', 'SanitizerThreadPreinit']}}
legacy_COMMON_SOURCES = ('active_mesh_resolver.d',
 'app_version.d',
 'argstring.d',
 'change_bus.d',
 'command.d',
 'command_args.d',
 'command_executor.d',
 'command_history.d',
 'command_invocation.d',
 'command_registry.d',
 'command_tool_policy.d',
 'commands/history/redo.d',
 'commands/history/undo.d',
 'commands/mesh/gesture_payload.d',
 'commands/mesh/mesh_edit_payload.d',
 'commands/mesh/select.d',
 'commands/mesh/selection_undo.d',
 'commands/mesh/session_edit.d',
 'commands/mesh/triple.d',
 'commands/mesh/vertex_edit.d',
 'commands/select/drop.d',
 'commands/select/element.d',
 'commands/select/invert.d',
 'document.d',
 'document_selection.d',
 'edit_target_contract.d',
 'editmode.d',
 'falloff.d',
 'history_lifecycle_contract.d',
 'http_json.d',
 'image_data.d',
 'io/file_model.d',
 'io/image_decode.d',
 'io/image_path.d',
 'io/native.d',
 'item_kinds.d',
 'item_xform.d',
 'json_num.d',
 'layer_params.d',
 'log.d',
 'math.d',
 'mesh.d',
 'mesh_bbox.d',
 'mesh_corner_maps.d',
 'mesh_dirty.d',
 'mesh_edge_slice.d',
 'mesh_edit_delta.d',
 'mesh_morph.d',
 'mesh_planes.d',
 'mesh_selsets.d',
 'mesh_topo.d',
 'mesh_visibility.d',
 'morph_target.d',
 'operator.d',
 'params.d',
 'perf_probe.d',
 'pilot_command_registration.d',
 'plane_bytes.d',
 'prepared_tool_effect.d',
 'record_observer_hub.d',
 'screen_buckets.d',
 'seltype.d',
 'session_owner.d',
 'snapshot.d',
 'standalone_application.d',
 'symmetry_plane.d',
 'tool_activation_ownership.d',
 'tool_policy_values.d',
 'toolpipe/packets.d',
 'toolpipe/pipeline.d',
 'toolpipe/stage.d',
 'toolpipe/subject.d',
 'trackball.d',
 'tsan_annotate.d',
 'view.d',
 'workplane_basis.d')
legacy_COMMON_DESCRIPTOR = 'ec9c1fd1034b8eef88456b6e15ec13d66e2c73d1f99890e518a1030cace480c5'


def legacy_digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def legacy_canonical_digest(raw):
    return hashlib.sha256(json.dumps(raw, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def legacy_production_files(project, owner):
    names = legacy_COMMON_SOURCES if owner == 'common' else tuple(x + '.d' for x in legacy_SPECS[owner]['sources'])
    return sorted((project / 'packages' / owner / 'source' / x).resolve() for x in names)


def legacy_carrier_names(owner):
    return tuple(sorted(legacy_SPECS[owner]['carriers'] + (owner.replace('-', '_') + '_population_test',)))


def legacy_test_files(project, owner):
    paths = legacy_production_files(project, owner)
    paths += [(project / 'packages' / owner / 'tests/source/tests/unit' / (x + '.d')).resolve()
              for x in legacy_carrier_names(owner)]
    if owner in ('viewport-gpu', 'subpatch-preview'):
        for lower in legacy_SPECS[owner]['lower']:
            paths += legacy_production_files(project, lower)
    return sorted(paths)


def legacy_external_grant(name):
    if name in legacy_REVISIONS:
        revision, repository = legacy_REVISIONS[name]
        return {'version': revision, 'repository': repository}
    return legacy_BINDINGS[name]


def legacy_expected_descriptor(owner, tests=False):
    spec = legacy_SPECS[owner]
    raw = {'name': 'vibe3d-' + owner + ('-tests' if tests else ''),
           'targetType': 'executable' if tests else 'staticLibrary',
           'sourcePaths': ['../source'] if tests else ['source'],
           'toolchainRequirements': {'dmd': '>=2.111.0', 'ldc': '>=1.41.0'},
           'buildTypes': copy.deepcopy(legacy_BUILD_TYPES),
           'dependencies': {'vibe3d-' + x: {'path': ('../../' if tests else '../') + x}
                            for x in spec['lower']}}
    raw['dependencies'].update({x: legacy_external_grant(x) for x in spec['external']})
    if spec['versions']:
        raw['versions'] = list(spec['versions'])
    if owner == 'viewport-gpu':
        raw['stringImportPaths'] = ['../assets/shading', '../../../assets/icon'] if tests else ['assets/shading']
    if tests:
        raw.update(importPaths=['source', '../source'],
                   configurations=[{'name': 'algorithm'}],
                   sourceFiles=['source/tests/unit/' + x + '.d' for x in legacy_carrier_names(owner)],
                   subConfigurations={'vibe3d-' + x: 'modeling-noai' for x in spec['lower']})
        if owner == 'input-events':
            raw['workingDirectory'] = '../../../'
        if owner in ('viewport-gpu', 'subpatch-preview'):
            raw['subConfigurations'] = {'vibe3d-' + x: 'isolated-tests' for x in spec['lower']}
            for lower in spec['lower']:
                names = legacy_COMMON_SOURCES if lower == 'common' else tuple(x + '.d' for x in legacy_SPECS[lower]['sources'])
                raw['sourceFiles'] += ['../../' + lower + '/source/' + x for x in names]
    else:
        raw['configurations'] = []
        for config in legacy_CONFIGS + (('isolated-tests',) if owner in ('display-policy', 'viewport-gpu') else ()):
            versions = {'modeling': ['WithAI'], 'modeling-noai': [], 'with-render': ['WithRender', 'WithAI'],
                        'web': ['web'], 'root-tests': ['WithAI'], 'isolated-tests': []}[config]
            cell = {'name': config, 'versions': versions,
                    'subConfigurations': {'vibe3d-' + x: config
                                          for x in spec['lower']}}
            if config == 'web' and owner == 'input-events':
                cell['subConfigurations']['bindbc-sdl'] = 'static'
            if config in ('root-tests', 'isolated-tests'):
                cell['targetType'] = 'sourceLibrary'
            raw['configurations'].append(cell)
    return raw


def legacy_normalize_descriptor(raw):
    raw = copy.deepcopy(raw)
    for key in list(raw):
        if key in legacy_META or key.startswith('_comment'):
            del raw[key]
    # DUB's implicit source import root and an explicit identical root grant
    # have the same capability; nothing else is normalized away.
    if raw.get('importPaths') == ['source'] and raw.get('targetType') == 'staticLibrary':
        del raw['importPaths']
    for key in ('sourceFiles', 'versions', 'stringImportPaths'):
        if key in raw:
            raw[key] = sorted(raw[key])
    for config in raw.get('configurations', []):
        config['versions'] = sorted(config.get('versions', []))
    raw['configurations'] = sorted(raw.get('configurations', []), key=lambda c: c['name'])
    return raw


def legacy_validate_raw(raw, owner, tests=False):
    expected = legacy_expected_descriptor(owner, tests)
    grants = raw.get('importPaths', []) + raw.get('sourcePaths', [])
    for cell in raw.get('configurations', []):
        grants += cell.get('importPaths', []) + cell.get('sourcePaths', [])
    permitted = {'source', '../source'} if tests else {'source'}
    legacy_require(all(x in permitted for x in grants), 'support package desktop import grant: ' + owner)
    legacy_require(raw.get('targetType') == expected['targetType'], 'support package ordinary static target: ' + owner)
    legacy_require(legacy_normalize_descriptor(raw) == legacy_normalize_descriptor(expected),
            'support package descriptor contract: ' + owner + (' tests' if tests else ' production'))


def legacy_validate_sources(project, owner):
    root = project / 'packages' / owner
    legacy_require(sorted(p.resolve() for p in (root / 'source').rglob('*.d')) == legacy_production_files(project, owner),
            'support package production source identity: ' + owner)
    legacy_require(sorted(p.resolve() for p in (root / 'tests/source').rglob('*.d')) ==
            sorted((root / 'tests/source/tests/unit' / (x + '.d')).resolve() for x in legacy_carrier_names(owner)),
            'support package public carrier identity: ' + owner)
    legacy_require(all(p.is_file() for p in legacy_production_files(project, owner)),
            'support package missing production source: ' + owner)
    legacy_require(all(p.is_file() for p in legacy_test_files(project, owner)),
            'support package missing compiler root: ' + owner)


def legacy_fixture_receipt(project, owner, fixtures=legacy_FIXTURES):
    if owner not in fixtures:
        return {}
    relative, sha = fixtures[owner]
    path = project / relative
    legacy_require(path.is_file() and legacy_digest(path) == sha, 'PREPARATION-REFUSED: support test fixture: ' + relative)
    return {'path': relative, 'sha256': sha, 'cwd': str(project.resolve())}


def legacy_check_raw_tree(project, owner):
    for selected in legacy_SPECS[owner]['lower'] + (owner,):
        descriptor = project / 'packages' / selected / 'dub.json'
        legacy_require(descriptor.is_file(), 'support package selected descriptor missing: ' + selected)
        raw = json.loads(descriptor.read_text())
        if selected == 'common':
            grants = {k: v for k, v in raw.items() if k not in ('description', 'license', 'toolchainRequirements')}
            legacy_require(legacy_canonical_digest(grants) == legacy_COMMON_DESCRIPTOR, 'support common descriptor contract')
            legacy_require(sorted(p.resolve() for p in (descriptor.parent / 'source').rglob('*.d')) ==
                    legacy_production_files(project, 'common'), 'support common source identity')
        else:
            legacy_validate_raw(raw, selected)
            legacy_validate_sources(project, selected)
    test_descriptor = project / 'packages' / owner / 'tests/dub.json'
    legacy_require(test_descriptor.is_file(), 'support package selected test descriptor missing: ' + owner)
    legacy_validate_raw(json.loads(test_descriptor.read_text()), owner, True)
    return legacy_fixture_receipt(project, owner)


def legacy_external_closure(names, web=False):
    result = set(names)
    for name in tuple(result):
        result.update(legacy_EXTERNAL_DEPS[name])
    if web and 'bindbc-sdl' in result and 'bindbc-opengl' not in result:
        result.discard('bindbc-loader')
    return result


def legacy_native_revision(path):
    # Committed archives have no upstream Git history. The export writes this
    # provenance only after checking the original HEAD and copied source hashes.
    provenance = path / '.boundary-revision'
    if provenance.is_file():
        return provenance.read_text().strip()
    result = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=path, text=True, capture_output=True)
    legacy_require(result.returncode == 0, 'PREPARATION-REFUSED: native repository revision unavailable: ' + str(path))
    return result.stdout.strip()


def legacy_native_grants(names, roots, web=False):
    libs, lflags = set(), set()
    if 'd-stb-image' in names:
        libs.update(('stb_image_c', 'm'))
        lflags.add('-L' + str(roots['d-stb-image'] / 'build'))
    if 'd-opensubdiv' in names:
        libs.update(('osdc', 'osdCPU', 'osdGPU', 'GL', 'stdc++', 'm'))
        lflags.update(('-L' + str(roots['d-opensubdiv'] / 'build'),
                       '-L' + str(roots['d-opensubdiv'] / 'build/extern/OpenSubdiv/opensubdiv')))
    if 'bindbc-loader' in names:
        libs.add('dl')
    return libs, lflags


def legacy_validate_description(description, project, owner, config, tests=False, harness=None):
    spec = legacy_SPECS[owner]
    root_name = 'vibe3d-' + owner + ('-tests' if tests else '')
    legacy_require(description['rootPackage'] == root_name, 'support resolved root package: ' + owner)
    active_list = [p for p in description['packages'] if p.get('active')]
    active = {p['name']: p for p in active_list}
    internal = set(spec['lower']) | (set() if tests else {owner})
    ext = {'d-stb-image'} | set(spec['external'])
    for selected in internal - {'common'}:
        ext.update(legacy_SPECS[selected]['external'])
    ext = legacy_external_closure(ext, config == 'web')
    expected = {'vibe3d-' + x for x in internal} | ext | {root_name}
    legacy_require(len(active_list) == len(expected) and set(active) == expected,
            'support resolved active package population: ' + owner)
    roots = {}
    for name, package in active.items():
        path = Path(package['path']).resolve()
        roots[name] = path
        if name.startswith('vibe3d-'):
            selected = name.removeprefix('vibe3d-').removesuffix('-tests')
            expected_path = project / 'packages' / selected / ('tests' if name.endswith('-tests') else '')
            legacy_require(path == expected_path.resolve(), 'support resolved owner path: ' + name)
            settings = legacy_expected_descriptor(selected, True) if name.endswith('-tests') else None
            if selected == 'common':
                deps = ['d-stb-image']
            else:
                deps = ['vibe3d-' + x for x in legacy_SPECS[selected]['lower']] + list(legacy_SPECS[selected]['external'])
            legacy_require(sorted(package.get('dependencies', [])) == sorted(deps), 'support resolved dependency DAG: ' + name)
            source_lower = tests and owner in ('viewport-gpu', 'subpatch-preview') and selected in spec['lower']
            target = ('executable' if name.endswith('-tests') else 'sourceLibrary'
                      if config == 'root-tests' or source_lower
                      else 'staticLibrary')
            expected_config = ('algorithm' if name.endswith('-tests') else 'isolated-tests'
                               if source_lower
                               else 'modeling-noai' if tests else config)
            legacy_require(package['targetType'] == target, 'support resolved compiler owner: ' + name)
            legacy_require(package['configuration'] == expected_config, 'support resolved configuration: ' + name)
            legacy_require(all(not package.get(k) for k in legacy_HOOKS), 'support resolved owner hook: ' + name)
            files = sorted((path / f['path']).resolve() for f in package['files'] if f['role'] == 'source')
            expected_files = legacy_test_files(project, owner) if name.endswith('-tests') else legacy_production_files(project, selected)
            if harness is not None and name.endswith('-tests'):
                expected_files += [harness.resolve()]
            legacy_require(files == sorted(expected_files), 'support resolved sourceFiles: ' + name)
            expected_versions = list(settings.get('versions', [])) if settings else list(legacy_SPECS[selected]['versions']) if selected != 'common' else []
            if not name.endswith('-tests'):
                effective = 'modeling-noai' if tests else config
                expected_versions += {'modeling': ['WithAI'], 'with-render': ['WithRender', 'WithAI'],
                                      'web': ['web'], 'root-tests': ['WithAI']}.get(effective, [])
            legacy_require(sorted(package.get('versions', [])) == sorted(expected_versions), 'support resolved versions: ' + name)
            expected_imports = [path / 'source', path / '../source'] if settings else [path / 'source']
            legacy_require(sorted((path / p).resolve() for p in package.get('importPaths', [])) == sorted(p.resolve() for p in expected_imports),
                    'support resolved importPaths: ' + name)
            expected_strings = settings.get('stringImportPaths', []) if settings else ['assets/shading'] if selected == 'viewport-gpu' else []
            legacy_require(sorted((path / p).resolve() for p in package.get('stringImportPaths', [])) ==
                    sorted((path / p).resolve() for p in expected_strings), 'support resolved stringImportPaths: ' + name)
            for field in ('lflags', 'libs', 'frameworks', 'injectSourceFiles', 'copyFiles', 'extraDependencyFiles'):
                legacy_require(not package.get(field), 'support resolved owner link grant: ' + name + ':' + field)
            legacy_require(package.get('dflags', []) == [], 'support resolved owner dflags: ' + name)
        else:
            expected_native_type = 'library' if name == 'dyaml' else 'staticLibrary'
            legacy_require(package['targetType'] == expected_native_type, 'support resolved native archive target: ' + name)
            expected_hooks = []
            if name == 'd-stb-image':
                expected_hooks = ['cmake -B $PACKAGE_DIR/build -DCMAKE_GENERATOR=Ninja -DCMAKE_BUILD_TYPE=Release $PACKAGE_DIR',
                                  'cmake --build $PACKAGE_DIR/build --config Release']
            elif name == 'd-opensubdiv':
                expected_hooks = ['cd \"$PACKAGE_DIR\" && git submodule update --init --recursive --quiet',
                                  'cmake -S \"$PACKAGE_DIR\" -B \"$PACKAGE_DIR/build\" -DCMAKE_BUILD_TYPE=Release',
                                  'cmake --build \"$PACKAGE_DIR/build\" -j --target osdc']
            for field in legacy_HOOKS:
                legacy_require(package.get(field, []) == (expected_hooks if field == 'preBuildCommands' else []),
                        'support resolved native hook: ' + name + ':' + field)
            legacy_require(sorted((path / p).resolve() for p in package.get('importPaths', [])) == [path / 'source'],
                    'support resolved native importPaths: ' + name)
            legacy_require(not package.get('stringImportPaths'), 'support resolved native stringImportPaths: ' + name)
            if name in legacy_REVISIONS:
                legacy_require(legacy_native_revision(path) == legacy_REVISIONS[name][0], 'support resolved repository revision: ' + name)
            else:
                prefix = {'bindbc-sdl': '1.5.', 'bindbc-opengl': '1.1.', 'bindbc-common': '1.', 'bindbc-loader': '1.'}[name]
                legacy_require(package['version'].startswith(prefix), 'support resolved binding version: ' + name)
            deps = list(legacy_EXTERNAL_DEPS[name])
            if config == 'web' and name == 'bindbc-sdl':
                deps.remove('bindbc-loader')
            legacy_require(sorted(package.get('dependencies', [])) == sorted(deps), 'support resolved external DAG: ' + name)
    # Resolve target grants from the fixed direct dependency DAG. No D parser:
    # source resolution and conditional imports belong to the actual compiler.
    targets = {t['rootPackage']: t for t in description['targets']}
    expected_targets = set() if config == 'root-tests' else {n for n, p in active.items() if p['targetType'] != 'sourceLibrary'}
    legacy_require(len(description['targets']) == len(expected_targets) and set(targets) == expected_targets,
            'support resolved target population: ' + owner)
    for name, target in targets.items():
        if not name.startswith('vibe3d-'):
            continue
        seen = set()
        def visit(n):
            if n in seen:
                return
            seen.add(n)
            for dep in active[n].get('dependencies', []):
                visit(dep)
        visit(name)
        settings = target['buildSettings']
        imports = {str((roots[n] / p).resolve()) for n in seen for p in active[n].get('importPaths', [])}
        strings = {str((roots[n] / p).resolve()) for n in seen for p in active[n].get('stringImportPaths', [])}
        for field, expected_paths in (('importPaths', imports), ('stringImportPaths', strings)):
            actual_paths = [str(Path(p).resolve()) for p in settings.get(field, [])]
            legacy_require(len(actual_paths) == len(expected_paths) and set(actual_paths) == expected_paths,
                    'support target ' + field + ': ' + name)
        source_owners = {name} | {n for n in seen if active[n]['targetType'] == 'sourceLibrary'}
        expected_sources = {str((roots[n] / f['path']).resolve()) for n in source_owners
                            for f in active[n]['files'] if f['role'] == 'source'}
        legacy_require(len(settings.get('sourceFiles', [])) == len(expected_sources) and
                {str(Path(p).resolve()) for p in settings.get('sourceFiles', [])} == expected_sources,
                'support target compiler source identity: ' + name)
        archives = {str(roots[n] / (legacy_ARCHIVES[n] if n in legacy_ARCHIVES else 'lib' + n + '.a'))
                    for n in seen - {name} if active[n]['targetType'] in ('staticLibrary', 'library')}
        legacy_require(set(settings.get('linkerFiles', [])) == archives and len(settings.get('linkerFiles', [])) == len(archives),
                'support target D archive inputs: ' + name)
        libs, lflags = legacy_native_grants(seen, roots, config == 'web')
        for field, expected_values in (('libs', libs), ('lflags', lflags)):
            legacy_require(set(settings.get(field, [])) == expected_values and
                    (field == 'lflags' or len(settings.get(field, [])) == len(expected_values)),
                    'support target native link inputs: ' + name + ':' + field)
        for field in legacy_HOOKS + ('injectSourceFiles', 'copyFiles', 'extraDependencyFiles', 'cImportPaths'):
            legacy_require(not settings.get(field), 'support target extra grant: ' + name + ':' + field)

    return active


# Amendment 20262230: frozen from the pre-compile root roster / COMMON_SOURCES
# intersection, independently of the candidate's measured enabled modules.
legacy_COMMON_UNITTESTS = ('argstring', 'command', 'command_history', 'command_registry',
                    'commands.mesh.session_edit', 'commands.select.element',
                    'io.image_decode', 'io.native', 'json_num', 'log', 'math', 'mesh',
                    'mesh_corner_maps', 'mesh_dirty', 'mesh_edit_delta', 'mesh_planes',
                    'mesh_topo', 'plane_bytes', 'record_observer_hub', 'screen_buckets',
                    'toolpipe.pipeline', 'trackball', 'view')


def legacy_validate_runtime(output, owner):
    totals = re.findall(r'^(\d+) modules passed unittests$', output, re.M)
    legacy_require(len(totals) == 1 and int(totals[0]) > 0, 'NO-VERDICT: support nonzero druntime total')
    roster = re.findall(r'^PKG-MODULE name=(\S+) unittest=([01])$', output, re.M)
    legacy_require(roster and len(roster) == len(set(n for n, _ in roster)), 'NO-VERDICT: support runtime roster identity')
    for module in legacy_SPECS[owner]['sources']:
        legacy_require(sum(name == module for name, _ in roster) == 1, 'support runtime production owner exactly once: ' + module)
    expected = ['tests.unit.' + x for x in legacy_carrier_names(owner)] + list(legacy_SPECS[owner]['private'])
    for module in expected:
        legacy_require(roster.count((module, '1')) == 1, 'support runtime unittest owner exactly once: ' + module)
    if owner in ('viewport-gpu', 'subpatch-preview'):
        for lower in legacy_SPECS[owner]['lower']:
            modules = (tuple(x.removesuffix('.d').replace('/', '.') for x in legacy_COMMON_SOURCES)
                       if lower == 'common' else legacy_SPECS[lower]['sources'])
            for module in modules:
                legacy_require(sum(name == module for name, _ in roster) == 1,
                        'support runtime lower production owner exactly once: ' + module)
            enabled = sorted(name for name, flag in roster if name in modules and flag == '1')
            expected_lower = legacy_COMMON_UNITTESTS if lower == 'common' else legacy_SPECS[lower]['private']
            legacy_require(enabled == sorted(expected_lower), 'support runtime lower enabled identity: ' + lower)
    legacy_require(sum(flag == '1' for _, flag in roster) == int(totals[0]), 'support runtime executed roster total')
    return {'modules': int(totals[0]), 'roster': roster}


def legacy_run(command, cwd, env, evidence, name):
    result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True)
    (evidence / (name + '.stdout.log')).write_text(result.stdout)
    (evidence / (name + '.stderr.log')).write_text(result.stderr)
    (evidence / (name + '.command.json')).write_text(json.dumps({'argv': command, 'cwd': str(cwd), 'exit': result.returncode}, indent=2))
    legacy_require(result.returncode == 0, 'support command failed: ' + name + ': ' +
            next((x for x in (result.stdout + result.stderr).splitlines() if 'Error:' in x or 'AssertError@' in x), 'see original logs'))
    return result


def legacy_describe(project, owner, config, compiler, env, evidence, tests=False, recipe=None, harness=None):
    root = project / 'packages' / owner / ('tests' if tests else '')
    name = ('algorithm' if tests else config) + ('-receipt' if recipe else '')
    command = ['dub', 'describe', '--root=' + str(root), '--config=' + config,
               '--compiler=' + compiler, '--quiet']
    if recipe:
        command += ['--recipe=' + str(recipe)]
    result = legacy_run(command, project, env, evidence, name)
    description = json.loads(result.stdout)
    legacy_validate_description(description, project, owner, config, tests, harness)
    (evidence / (name + '.json')).write_text(json.dumps(description, indent=2))
    return description


def legacy_validate_staged_fixture(fixture, original, owner, archive, fixtures=legacy_FIXTURES):
    expected = original
    if owner in fixtures:
        expected = dict(original, cwd=str(archive.resolve()))
    legacy_require(fixture == expected, 'PREPARATION-REFUSED: fixture staging differs')


def legacy_stage_archive(project, owner, evidence):
    legacy_require(not (evidence / 'archive').exists(), 'PREPARATION-REFUSED: archive directory already exists')
    legacy_require(subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=normal'], cwd=project, text=True).strip() == '',
            'PREPARATION-REFUSED: execute requires a clean committed worktree')
    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=project, text=True).strip()
    archive = evidence / 'archive'
    archive.mkdir()
    members = ['packages/' + x for x in legacy_SPECS[owner]['lower'] + (owner,)]
    if owner in legacy_FIXTURES:
        members.append(legacy_FIXTURES[owner][0])
    tar = evidence / 'committed.tar'
    with tar.open('wb') as stream:
        subprocess.run(['git', 'archive', '--format=tar', sha, '--'] + members, cwd=project, stdout=stream, check=True)
    with tarfile.open(tar) as stream:
        stream.extractall(archive, filter='data')
    for lower in legacy_SPECS[owner]['lower']:
        shutil.rmtree(archive / 'packages' / lower / 'tests', ignore_errors=True)
    legacy_require(not (archive / 'source').exists() and not (archive / 'tests/unit').exists() and not (archive / 'dub.json').exists(),
            'PREPARATION-REFUSED: archive includes desktop roots/descriptor')
    fixture = legacy_fixture_receipt(archive, owner)
    legacy_validate_staged_fixture(fixture, legacy_fixture_receipt(project, owner), owner, archive)
    return archive, sha


def legacy_stage_dependencies(active, archive, evidence, env):
    home = evidence / 'dub-home'
    home.mkdir()
    env['DUB_HOME'] = str(home)
    receipts = {}
    for name, package in active.items():
        if name.startswith('vibe3d-'):
            continue
        original = Path(package['path']).resolve()
        staged = (home / 'packages' / name / legacy_REVISIONS[name][0] / name
                  if name in legacy_REVISIONS else archive / 'dependencies' / name)
        # Fresh D archives and native outputs must be built in this copy.
        shutil.copytree(original, staged, ignore=shutil.ignore_patterns('.git', '.dub', 'build', 'out', '*.a', '*.o', '*.obj', '*.lib'))
        files = {str(p.relative_to(staged)): legacy_digest(p) for p in sorted(staged.rglob('*')) if p.is_file()}
        legacy_require(files and 'dub.json' in files, 'PREPARATION-REFUSED: dependency source missing: ' + name)
        for relative, sha in files.items():
            legacy_require(legacy_digest(original / relative) == sha, 'PREPARATION-REFUSED: dependency staging changed: ' + name)
        if name in legacy_REVISIONS:
            revision = legacy_native_revision(original)
            legacy_require(revision == legacy_REVISIONS[name][0], 'PREPARATION-REFUSED: native source revision: ' + name)
            (staged / '.boundary-revision').write_text(revision + '\n')
        legacy_run(['git', 'init', '-q', str(staged)], archive, env, evidence, 'initialize-' + name)
        legacy_run(['dub', 'add-local', str(staged), package['version']], archive, env, evidence, 'register-' + name)
        receipts[name] = {'original': str(original), 'staged': str(staged), 'version': package['version'], 'files': files}
    (evidence / 'dependency-sources.json').write_text(json.dumps(receipts, indent=2))
    return receipts


def legacy_compiler_commands(output, compiler_cwd=None):
    """Read DUB's verbose compiler argv, including its actual working directory."""
    commands = []
    for line in output.splitlines():
        match = re.match(r'^\[cwd=(.+?)\] (.+)$', line)
        if match:
            cwd, command = Path(match[1]).resolve(), match[2]
            cwd_evidence = 'compiler log prefix'
        elif compiler_cwd is not None and re.match(r'^(?:\S*/)?(?:dmd|ldc2)\s', line):
            # DUB emits the prefix for DMD but not every supported compiler.
            # build keeps its invocation cwd; test compiles in its target root.
            cwd, command = compiler_cwd.resolve(), line
            cwd_evidence = 'DUB build cwd / test target directory'
        else:
            continue
        argv = shlex.split(command)
        if not argv or Path(argv[0]).name not in ('dmd', 'ldc2'):
            continue
        def expand(arguments, depth=0):
            legacy_require(depth < 8, 'support compiler response recursion')
            expanded = []
            for arg in arguments:
                if arg.startswith('@'):
                    expanded += expand(shlex.split((cwd / arg[1:]).read_text()), depth + 1)
                else:
                    expanded.append(arg)
            return expanded
        argv = expand(argv)
        inputs = [str((cwd / arg).resolve()) for arg in argv[1:] if not arg.startswith('-')]
        outputs = [str((cwd / arg.removeprefix('-of').lstrip('=')).resolve())
                   for arg in argv[1:] if arg.startswith('-of')]
        commands.append({'cwd': str(cwd), 'cwdEvidence': cwd_evidence, 'argv': argv,
                         'sourceInputs': [p for p in inputs if p.endswith('.d')],
                         'archiveInputs': [p for p in inputs if p.endswith('.a')],
                         'objectInputs': [p for p in inputs if p.endswith(('.o', '.obj'))],
                         'outputs': outputs})
    legacy_require(commands, 'NO-VERDICT: support actual compiler argv/cwd missing')
    return commands


def legacy_validate_actual_compiler(commands, project, owner, description, home, harness):
    # Task 20262190 / amendment 20262200: explicit sources own emission; the
    # resolved graph separately admits STATIC dependencies. Judge actual argv.
    own = str(legacy_production_files(project, owner)[0])
    compiles = [c for c in commands if own in c['sourceInputs']]
    legacy_require(len(compiles) == 1, 'support actual compiler source identity: ' + owner)
    compiled = compiles[0]
    legacy_require(not any(arg == '-i' or arg.startswith('-i=') or
                    arg in ('--include-imports', '-include-imports') or
                    arg.startswith(('--include-imports=', '-include-imports='))
                    for arg in compiled['argv']),
            'support actual compiler include-import flags: ' + owner)
    name = 'vibe3d-' + owner + '-tests'
    sources = compiled['sourceInputs']
    generated = [p for p in sources if Path(p).name == 'dub_test_root.d' and
                 Path(p).is_relative_to(home / 'cache' / name / '~master' / 'code')]
    expected = [str(p) for p in legacy_test_files(project, owner)] + [str(harness.resolve())] + generated
    legacy_require(len(generated) == 1 and sorted(sources) == sorted(expected),
            'support actual compiler source identity: ' + owner)
    links = [c for c in commands if any(p in c['objectInputs'] for p in compiled['outputs'])]
    legacy_require(len(links) == 1, 'support actual compiler D archive inputs: ' + owner)
    linked = links[0]
    active = {p['name']: p for p in description['packages'] if p.get('active')}
    static = {n: legacy_ARCHIVES[n] if n in legacy_ARCHIVES else 'lib' + n + '.a'
              for n, p in active.items() if n != name and p['targetType'] in ('staticLibrary', 'library')}
    archives = linked['archiveInputs']
    legacy_require(len(archives) == len(static) and all(
        sum(Path(a).is_relative_to(home / 'cache' / n) and
            Path(a).name == Path(filename).name for a in archives) == 1
        for n, filename in static.items()), 'support actual compiler D archive inputs: ' + owner)
    return {'compile': compiled, 'link': linked, 'staticOwners': sorted(static)}


def legacy_fixture_observer_statement(archive, owner, fixtures=legacy_FIXTURES):
    legacy_require(archive.is_absolute(), 'PREPARATION-REFUSED: fixture observer archive path')
    relative, _ = fixtures[owner]
    return ' writeln("PKG-FIXTURE sha256=", sha256Of(read(' + json.dumps(str(archive / relative)) + ')).toHexString.toLower);'


def legacy_validate_algorithm_cwd(output, archive, owner):
    expected = archive if owner == 'input-events' else archive / 'packages' / owner / 'tests'
    legacy_require(re.findall(r'^PKG-CWD path=(.+)$', output, re.M) == [str(expected)],
            'support algorithm actual working directory: ' + owner)


def legacy_native_archive_input(search_paths, library):
    inputs = sorted({(directory / ('lib' + library + '.a')).resolve()
                     for directory in search_paths if (directory / ('lib' + library + '.a')).is_file()})
    legacy_require(len(inputs) == 1, 'support actual native archive input: ' + library)
    return inputs[0]


def legacy_execute(project, owner, compiler, env, evidence):
    legacy_check_raw_tree(project, owner)
    description = legacy_describe(project, owner, 'modeling-noai', compiler, env, evidence)
    archive, sha = legacy_stage_archive(project, owner, evidence)
    active = {p['name']: p for p in description['packages'] if p.get('active')}
    dependencies = legacy_stage_dependencies(active, archive, evidence, env)
    production = legacy_describe(archive, owner, 'modeling-noai', compiler, env, evidence)
    # Require actual resolved external paths in the owned copy, before a hook
    # or compiler can write into a canonical dependency cache.
    for package in production['packages']:
        if package.get('active') and not package['name'].startswith('vibe3d-'):
            legacy_require(Path(package['path']).resolve() == Path(dependencies[package['name']]['staged']).resolve(),
                    'PREPARATION-REFUSED: canonical dependency cache selected: ' + package['name'])
    root = archive / 'packages' / owner
    command = ['dub', 'build', '--root=' + str(root), '--config=modeling-noai', '--compiler=' + compiler, '--force', '--verbose']
    built = legacy_run(command, archive, env, evidence, 'production-build')
    binary = root / ('libvibe3d-' + owner + '.a')
    legacy_require(binary.is_file(), 'NO-VERDICT: support ordinary static archive missing')
    legacy_describe(archive, owner, 'algorithm', compiler, env, evidence, True)
    # A receipt-only static constructor observes real ModuleInfo without
    # replacing druntime's tester or importing any judged carrier.
    harness = root / 'tests/boundary_roster.d'
    receipt_source = 'module boundary_roster;\nimport std.stdio : writeln;\nimport std.file : getcwd, read;\nimport std.digest.sha : sha256Of;\nimport std.digest : toHexString;\nimport std.string : toLower;\nshared static this() { writeln("PKG-CWD path=", getcwd()); foreach (info; ModuleInfo) if (info !is null) writeln("PKG-MODULE name=", info.name, " unittest=", info.unitTest !is null ? 1 : 0);'
    if owner in legacy_FIXTURES:
        receipt_source += legacy_fixture_observer_statement(archive, owner)
    harness.write_text(receipt_source + ' }\n')
    raw = json.loads((root / 'tests/dub.json').read_text())
    raw['sourceFiles'].append('boundary_roster.d')
    recipe = root / 'tests/dub.boundary.json'
    recipe.write_text(json.dumps(raw, indent=2))
    algorithm = legacy_describe(archive, owner, 'algorithm', compiler, env, evidence, True, recipe, harness)
    tested = legacy_run(['dub', 'test', '--root=' + str(root / 'tests'), '--recipe=' + str(recipe), '--config=algorithm',
                  '--compiler=' + compiler, '--force', '--verbose'], archive, env, evidence, 'algorithm-run')
    runtime_output = tested.stdout + tested.stderr
    legacy_validate_algorithm_cwd(runtime_output, archive, owner)
    if owner in legacy_FIXTURES:
        legacy_require(re.findall(r'^PKG-FIXTURE sha256=(.+)$', runtime_output, re.M) == [legacy_FIXTURES[owner][1]],
                'support algorithm actual fixture hash: ' + owner)
    runtime = legacy_validate_runtime(runtime_output, owner)
    compiler_lines = [x for x in (built.stdout + built.stderr + tested.stdout + tested.stderr).splitlines()
                      if re.search(r'(?:^|\s)(?:\S*/)?(?:dmd|ldc2)\s', x)]
    legacy_require(compiler_lines, 'NO-VERDICT: support fresh compiler argv missing')
    actual = legacy_compiler_commands(tested.stdout + tested.stderr, root / 'tests')
    ownership = legacy_validate_actual_compiler(actual, archive, owner, algorithm, Path(env['DUB_HOME']), harness)
    (evidence / 'actual-compiler-argv.json').write_text(json.dumps(actual, indent=2))
    (evidence / 'actual-ownership.json').write_text(json.dumps(ownership, indent=2))
    # Both owned roots contain actual inputs; a glob over archive alone misses
    # pinned repository dependencies and the DUB build cache.
    input_hashes = {}
    for result, compiler_cwd in ((built, archive), (tested, root / 'tests')):
        for command in legacy_compiler_commands(result.stdout + result.stderr, compiler_cwd):
            for path in command['sourceInputs'] + command['archiveInputs'] + command['objectInputs']:
                selected = Path(path)
                legacy_require(selected.is_relative_to(archive) or selected.is_relative_to(Path(env['DUB_HOME'])),
                        'support actual input outside owned roots: ' + path)
                input_hashes[path] = legacy_digest(selected)
    link = ownership['link']
    search_paths = [(Path(link['cwd']) / arg.removeprefix('-L-L')).resolve()
                    for arg in link['argv'] if arg.startswith('-L-L')]
    for library in ('stb_image_c', 'osdc', 'osdCPU', 'osdGPU'):
        if '-L-l' + library not in link['argv']:
            continue
        native_input = legacy_native_archive_input(search_paths, library)
        input_hashes[str(native_input)] = legacy_digest(native_input)
    native = {str(p): legacy_digest(p) for owned in (archive, Path(env['DUB_HOME']))
              for p in owned.rglob('*.a')}
    (evidence / 'actual-input-hashes.json').write_text(json.dumps(input_hashes, indent=2))
    witness = {'sha': sha, 'compiler': compiler, 'archive': str(archive), 'archiveSha256': legacy_digest(evidence / 'committed.tar'),
               'productionArchiveSha256': legacy_digest(binary), 'compilerArgv': compiler_lines,
               'productionSources': [str(p) for p in legacy_production_files(archive, owner)],
               'testCompilerSources': [str(p) for p in legacy_test_files(archive, owner)] + [str(harness)],
               'fixture': legacy_fixture_receipt(archive, owner), 'archiveInputs': native,
               'actualOwnership': ownership, 'actualInputHashes': input_hashes, 'runtime': runtime}
    (evidence / 'witness.json').write_text(json.dumps(witness, indent=2))
    print('PKG-EXECUTE package=' + owner + ' sha=' + sha + ' modules=' + str(runtime['modules']))


def legacy_description_control(project, owner, tests=False, config='modeling-noai'):
    """Explicit finite DUB-shaped control; no DUB/source parser is simulated."""
    spec = legacy_SPECS[owner]
    selected = spec['lower'] + (() if tests else (owner,))
    external = {'d-stb-image'} | set(spec['external'])
    for name in selected:
        if name != 'common':
            external.update(legacy_SPECS[name]['external'])
    external = legacy_external_closure(external, config == 'web')
    root_name = 'vibe3d-' + owner + ('-tests' if tests else '')
    packages = []
    for name in selected + ((owner + '-tests',) if tests else ()):
        is_test = name.endswith('-tests')
        name = name.removesuffix('-tests')
        path = project / 'packages' / name / ('tests' if is_test else '')
        deps = ['d-stb-image'] if name == 'common' else ['vibe3d-' + x for x in legacy_SPECS[name]['lower']] + list(legacy_SPECS[name]['external'])
        versions = [] if name == 'common' else list(legacy_SPECS[name]['versions'])
        if not is_test and not tests:
            versions += {'modeling': ['WithAI'], 'with-render': ['WithRender', 'WithAI'], 'web': ['web'], 'root-tests': ['WithAI']}.get(config, [])
        strings = []
        if name == 'viewport-gpu':
            strings = ['../assets/shading', '../../../assets/icon'] if is_test else ['assets/shading']
        files = legacy_test_files(project, owner) if is_test else legacy_production_files(project, name)
        actual_config = ('algorithm' if is_test else 'isolated-tests'
                         if tests and owner in ('viewport-gpu', 'subpatch-preview') and name in spec['lower']
                         else 'modeling-noai' if tests else config)
        packages.append({'name': 'vibe3d-' + name + ('-tests' if is_test else ''), 'active': True, 'path': str(path),
                         'configuration': actual_config, 'targetType': 'executable' if is_test else 'sourceLibrary' if actual_config in ('root-tests', 'isolated-tests') else 'staticLibrary',
                         'dependencies': deps, 'versions': versions, 'importPaths': ['source', '../source'] if is_test else ['source'],
                         'stringImportPaths': strings, 'dflags': [],
                         'files': [{'role': 'source', 'path': str(p)} for p in files]})
    for name in sorted(external):
        deps = list(legacy_EXTERNAL_DEPS[name])
        if config == 'web' and name == 'bindbc-sdl':
            deps.remove('bindbc-loader')
        version = legacy_REVISIONS[name][0] if name in legacy_REVISIONS else {'bindbc-sdl': '1.5.2', 'bindbc-opengl': '1.1.1', 'bindbc-common': '1.0.5', 'bindbc-loader': '1.1.5'}[name]
        packages.append({'name': name, 'path': str(project / 'dependencies' / name), 'active': True, 'version': version,
                         'targetType': 'library' if name == 'dyaml' else 'staticLibrary', 'dependencies': deps, 'importPaths': ['source'], 'files': []})

    for package in packages:
        name = package['name']
        if name == 'd-stb-image':
            package['preBuildCommands'] = ['cmake -B $PACKAGE_DIR/build -DCMAKE_GENERATOR=Ninja -DCMAKE_BUILD_TYPE=Release $PACKAGE_DIR', 'cmake --build $PACKAGE_DIR/build --config Release']
        elif name == 'd-opensubdiv':
            package['preBuildCommands'] = ['cd "$PACKAGE_DIR" && git submodule update --init --recursive --quiet', 'cmake -S "$PACKAGE_DIR" -B "$PACKAGE_DIR/build" -DCMAKE_BUILD_TYPE=Release', 'cmake --build "$PACKAGE_DIR/build" -j --target osdc']
    for name in external & legacy_REVISIONS.keys():
        path = project / 'dependencies' / name
        path.mkdir(parents=True, exist_ok=True)
        (path / '.boundary-revision').write_text(legacy_REVISIONS[name][0] + '\n')
    active = {p['name']: p for p in packages}
    targets = []
    for name, package in active.items():
        if config == 'root-tests' or package['targetType'] == 'sourceLibrary':
            continue
        seen = set()
        def visit(n):
            if n in seen:
                return
            seen.add(n)
            for dep in active[n]['dependencies']:
                visit(dep)
        visit(name)
        imports = sorted({str((Path(active[n]['path']) / p).resolve()) for n in seen for p in active[n].get('importPaths', [])})
        strings = sorted({str((Path(active[n]['path']) / p).resolve()) for n in seen for p in active[n].get('stringImportPaths', [])})
        source_owners = {name} | {n for n in seen if active[n]['targetType'] == 'sourceLibrary'}
        sources = sorted({str((Path(active[n]['path']) / f['path']).resolve()) for n in source_owners for f in active[n]['files'] if f['role'] == 'source'})
        archives = sorted(str(Path(active[n]['path']) / (legacy_ARCHIVES[n] if n in legacy_ARCHIVES else 'lib' + n + '.a')) for n in seen - {name} if active[n]['targetType'] in ('staticLibrary', 'library'))
        libs, lflags = legacy_native_grants(seen, {n: Path(p['path']) for n, p in active.items()}, config == 'web')
        targets.append({'rootPackage': name, 'buildSettings': {'sourceFiles': sources, 'importPaths': imports, 'stringImportPaths': strings, 'linkerFiles': archives, 'libs': sorted(libs), 'lflags': sorted(lflags)}})
    return {'rootPackage': root_name, 'packages': packages, 'targets': targets}


def legacy_self_test():
    cells = []
    def red(name, operation, message):
        try:
            operation()
        except BoundaryError as error:
            legacy_require(message in str(error), 'self-control wrong refusal: ' + name + ': ' + str(error))
            cells.append(name)
        else:
            raise BoundaryError('self-control accepted invalid contract: ' + name)
    for owner in legacy_SPECS:
        for tests in (False, True):
            valid = legacy_expected_descriptor(owner, tests)
            legacy_validate_raw(valid, owner, tests)
            for field, value in [('importPaths', ['../../../source' if tests else '../../source']),
                                 ('sourcePaths', ['../../../source' if tests else '../../source'])]:
                broken = copy.deepcopy(valid); broken[field] = value
                red(owner + '-' + str(tests) + '-' + field, lambda: legacy_validate_raw(broken, owner, tests), 'desktop import grant')
            broken = copy.deepcopy(valid); broken['targetType'] = 'sourceLibrary'
            red(owner + '-' + str(tests) + '-static', lambda: legacy_validate_raw(broken, owner, tests), 'ordinary static target')
            for field in ('dependencies', 'sourceFiles', 'versions', 'stringImportPaths', 'buildTypes', 'toolchainRequirements', 'dflags') + legacy_HOOKS:
                broken = copy.deepcopy(valid)
                broken[field] = {'foreign': 'x'} if field in ('dependencies', 'buildTypes', 'toolchainRequirements') else ['-i'] if tests and field == 'dflags' else ['foreign']
                red(owner + '-' + str(tests) + '-' + field, lambda: legacy_validate_raw(broken, owner, tests), 'descriptor contract')
            if not tests:
                root_tests = next(c for c in valid['configurations'] if c['name'] == 'root-tests')
                legacy_require(root_tests['targetType'] == 'sourceLibrary', 'root-tests positive control')
                broken = copy.deepcopy(valid)
                next(c for c in broken['configurations'] if c['name'] == 'root-tests')['targetType'] = 'staticLibrary'
                red(owner + '-root-test-exception', lambda: legacy_validate_raw(broken, owner), 'descriptor contract')
            legacy_validate_raw(valid, owner, tests)
        expected = ['tests.unit.' + x for x in legacy_carrier_names(owner)] + list(legacy_SPECS[owner]['private'])
        other = set(legacy_SPECS[owner]['sources']) - set(legacy_SPECS[owner]['private'])
        lower_roster = ''
        if owner in ('viewport-gpu', 'subpatch-preview'):
            for lower in legacy_SPECS[owner]['lower']:
                modules = (tuple(x.removesuffix('.d').replace('/', '.') for x in legacy_COMMON_SOURCES)
                           if lower == 'common' else legacy_SPECS[lower]['sources'])
                enabled = legacy_COMMON_UNITTESTS if lower == 'common' else legacy_SPECS[lower]['private']
                lower_roster += ''.join('PKG-MODULE name=' + x + ' unittest=' + str(int(x in enabled)) + '\n' for x in modules)
        output = (''.join('PKG-MODULE name=' + x + ' unittest=1\n' for x in expected) +
                  ''.join('PKG-MODULE name=' + x + ' unittest=0\n' for x in sorted(other)) +
                  lower_roster + str(len(expected) + lower_roster.count('unittest=1')) + ' modules passed unittests\n')
        legacy_validate_runtime(output, owner)
        if owner in ('viewport-gpu', 'subpatch-preview'):
            for module in legacy_COMMON_UNITTESTS:
                broken = output.replace('PKG-MODULE name=' + module + ' unittest=1\n',
                                        'PKG-MODULE name=' + module + ' unittest=0\n')
                red(owner + '-lower-enabled-' + module, lambda: legacy_validate_runtime(broken, owner), 'lower enabled identity: common')
            for lower in legacy_SPECS[owner]['lower']:
                module = legacy_COMMON_SOURCES[0].removesuffix('.d') if lower == 'common' else legacy_SPECS[lower]['sources'][0]
                broken = re.sub(r'^PKG-MODULE name=' + re.escape(module) + r' unittest=[01]\n', '', output, flags=re.M)
                red(owner + '-lower-source-' + lower, lambda: legacy_validate_runtime(broken, owner), 'lower production owner exactly once')
        for module in legacy_SPECS[owner]['sources']:
            broken = re.sub(r'^PKG-MODULE name=' + re.escape(module) + r' unittest=[01]\n', '', output, flags=re.M)
            red(owner + '-runtime-source-' + module, lambda: legacy_validate_runtime(broken, owner), 'production owner exactly once')
        for module in expected:
            if module in legacy_SPECS[owner]['private']:
                continue
            broken = output.replace('PKG-MODULE name=' + module + ' unittest=1\n', '')
            red(owner + '-runtime-' + module, lambda: legacy_validate_runtime(broken, owner), 'unittest owner exactly once')
        red(owner + '-runtime-total', lambda: legacy_validate_runtime(output.replace(' modules passed unittests', ' missing total'), owner), 'nonzero druntime total')
        red(owner + '-runtime-duplicate', lambda: legacy_validate_runtime(output + 'PKG-MODULE name=' + expected[0] + ' unittest=1\n', owner), 'roster identity')
        legacy_validate_runtime(output, owner)
    with tempfile.TemporaryDirectory(prefix='support-checker-') as tmp:
        project = Path(tmp)
        for owner in legacy_SPECS:
            for tests, config in ((False, 'modeling-noai'), (True, 'algorithm')):
                valid = legacy_description_control(project, owner, tests, config)
                legacy_validate_description(valid, project, owner, config, tests)
                target = next(t for t in valid['targets'] if t['rootPackage'] == valid['rootPackage'])
                broken = copy.deepcopy(valid)
                repeated = next(t for t in broken['targets'] if t['rootPackage'] == broken['rootPackage'])
                repeated['buildSettings']['lflags'] += target['buildSettings']['lflags']
                legacy_validate_description(broken, project, owner, config, tests)
                cells.append(owner + '-' + config + '-native-known-directory-duplicate-positive')
                repeated['buildSettings']['lflags'].append('-L' + str(project / 'foreign'))
                red(owner + '-' + config + '-native-foreign-directory', lambda: legacy_validate_description(broken, project, owner, config, tests), 'native link inputs')
                legacy_validate_description(valid, project, owner, config, tests)
                for label, field, value in [('deps', 'dependencies', ['editor']), ('versions', 'versions', ['foreign']),
                                           ('hook', 'preBuildCommands', ['foreign']), ('config', 'configuration', 'foreign'),
                                           ('imports', 'importPaths', ['../../../source']), ('strings', 'stringImportPaths', ['../../../source']),
                                           ('source', 'files', []), ('target', 'targetType', 'dynamicLibrary'), ('flags', 'dflags', ['-i=editor']),
                                           ('libs', 'libs', ['desktop']), ('link', 'lflags', ['desktop.a']), ('inject', 'injectSourceFiles', ['desktop.d'])]:
                    broken = copy.deepcopy(valid)
                    judged = next(p for p in broken['packages'] if p['name'] == broken['rootPackage'])
                    judged[field] = value
                    red(owner + '-resolved-' + config + '-' + label, lambda: legacy_validate_description(broken, project, owner, config, tests), 'support resolved')
                for field in ('sourceFiles', 'importPaths', 'stringImportPaths', 'linkerFiles', 'libs', 'lflags', 'injectSourceFiles'):
                    if not valid['targets']:
                        continue
                    broken = copy.deepcopy(valid)
                    judged = next(t for t in broken['targets'] if t['rootPackage'] == broken['rootPackage'])
                    judged['buildSettings'][field] = ['desktop']
                    red(owner + '-target-' + field, lambda: legacy_validate_description(broken, project, owner, config, tests), 'support target')
                broken = copy.deepcopy(valid)
                next(p for p in broken['packages'] if p['name'] == 'd-stb-image')['targetType'] = 'sourceLibrary'
                red(owner + '-external-static', lambda: legacy_validate_description(broken, project, owner, config, tests), 'native archive target')
                for native in sorted({p['name'] for p in valid['packages']} & legacy_REVISIONS.keys()):
                    marker = project / 'dependencies' / native / '.boundary-revision'
                    marker.write_text('0' * 40 + '\n')
                    red(owner + '-source-revision-' + native, lambda: legacy_validate_description(valid, project, owner, config, tests), 'repository revision')
                    marker.write_text(legacy_REVISIONS[native][0] + '\n')
                broken = copy.deepcopy(valid); broken['packages'].append(copy.deepcopy(broken['packages'][0]))
                red(owner + '-active-duplicate', lambda: legacy_validate_description(broken, project, owner, config, tests), 'active package population')
                if tests and owner in ('viewport-gpu', 'subpatch-preview'):
                    for lower in legacy_SPECS[owner]['lower']:
                        broken = copy.deepcopy(valid)
                        judged = next(p for p in broken['packages'] if p['name'] == 'vibe3d-' + lower)
                        judged['targetType'] = 'staticLibrary'
                        red(owner + '-isolated-' + lower + '-static', lambda: legacy_validate_description(broken, project, owner, config, tests), 'compiler owner: vibe3d-' + lower)
                legacy_validate_description(valid, project, owner, config, tests)

            # The same finite four-owner contract exercises actual compile/link
            # ownership independently of raw and resolved descriptor pins.
            valid = legacy_description_control(project, owner, True, 'algorithm')
            home = project / 'dub-home'
            name = 'vibe3d-' + owner + '-tests'
            harness = project / 'packages' / owner / 'tests/boundary_roster.d'
            generated = home / 'cache' / name / '~master/code/control/dub_test_root.d'
            sources = [str(p) for p in legacy_test_files(project, owner)] + [str(harness), str(generated)]
            obj = home / 'cache' / name / '~master/build/control/test.o'
            static = [p['name'] for p in valid['packages'] if p['targetType'] in ('staticLibrary', 'library')]
            archives = [str(home / 'cache' / n / 'control' / Path(legacy_ARCHIVES[n] if n in legacy_ARCHIVES else 'lib' + n + '.a').name)
                        for n in static]
            lines = '[cwd=' + str(project) + '] dmd -unittest ' + shlex.join(sources) + ' -c -of=' + str(obj) + '\n'
            lines += '[cwd=' + str(project) + '] dmd ' + shlex.join([str(obj)] + archives) + ' -of=test\n'
            actual = legacy_compiler_commands(lines)
            legacy_validate_actual_compiler(actual, project, owner, valid, home, harness)
            unprefixed = lines.replace('[cwd=' + str(project) + '] ', '')
            legacy_validate_actual_compiler(legacy_compiler_commands(unprefixed, project), project, owner, valid, home, harness)
            for flag in ('-i', '-i=editor', '--include-imports', '--include-imports=editor'):
                broken = copy.deepcopy(actual); broken[0]['argv'].append(flag)
                red(owner + '-actual-flags-' + flag, lambda: legacy_validate_actual_compiler(broken, project, owner, valid, home, harness),
                    'support actual compiler include-import flags: ' + owner)
            for label, extra in [('static-source', str(legacy_production_files(project, 'common')[0])),
                                 ('duplicate-source', sources[0])]:
                broken = copy.deepcopy(actual); broken[0]['sourceInputs'].append(extra)
                red(owner + '-actual-' + label, lambda: legacy_validate_actual_compiler(broken, project, owner, valid, home, harness),
                    'support actual compiler source identity: ' + owner)
            for source in sources:
                broken = copy.deepcopy(actual); broken[0]['sourceInputs'].remove(source)
                red(owner + '-actual-omit-' + source, lambda: legacy_validate_actual_compiler(broken, project, owner, valid, home, harness),
                    'support actual compiler source identity: ' + owner)
            broken = copy.deepcopy(actual); broken[0]['sourceInputs'].append(str(generated))
            red(owner + '-actual-duplicate-main', lambda: legacy_validate_actual_compiler(broken, project, owner, valid, home, harness),
                'support actual compiler source identity: ' + owner)
            broken = copy.deepcopy(actual); broken.append(copy.deepcopy(actual[0]))
            red(owner + '-actual-duplicate-compile', lambda: legacy_validate_actual_compiler(broken, project, owner, valid, home, harness),
                'support actual compiler source identity: ' + owner)
            for label, broken in [('missing', actual[:1]), ('duplicate', actual + [actual[1]])]:
                red(owner + '-actual-' + label + '-link', lambda: legacy_validate_actual_compiler(broken, project, owner, valid, home, harness),
                    'support actual compiler D archive inputs: ' + owner)
            for archive in archives:
                broken = copy.deepcopy(actual); broken[1]['archiveInputs'].remove(archive)
                red(owner + '-actual-omit-' + archive, lambda: legacy_validate_actual_compiler(broken, project, owner, valid, home, harness),
                    'support actual compiler D archive inputs: ' + owner)
                for replacement in (str(Path(archive).with_name('foreign.a')),
                                    str(home / 'cache/foreign' / Path(archive).name)):
                    broken = copy.deepcopy(actual)
                    broken[1]['archiveInputs'][archives.index(archive)] = replacement
                    red(owner + '-actual-archive-identity-' + archive, lambda: legacy_validate_actual_compiler(broken, project, owner, valid, home, harness),
                        'support actual compiler D archive inputs: ' + owner)
            for extra in (archives[0], str(home / 'cache' / ('vibe3d-' + owner) / 'control/own.a')):
                broken = copy.deepcopy(actual); broken[1]['archiveInputs'].append(extra)
                red(owner + '-actual-extra-archive', lambda: legacy_validate_actual_compiler(broken, project, owner, valid, home, harness),
                    'support actual compiler D archive inputs: ' + owner)
            if owner in ('viewport-gpu', 'subpatch-preview'):
                for lower in legacy_SPECS[owner]['lower']:
                    broken = copy.deepcopy(actual)
                    broken[1]['archiveInputs'].append(str(home / 'cache' / ('vibe3d-' + lower) / 'control' / ('libvibe3d-' + lower + '.a')))
                    red(owner + '-actual-lower-' + lower + '-archive', lambda: legacy_validate_actual_compiler(broken, project, owner, valid, home, harness),
                        'support actual compiler D archive inputs: ' + owner)
            legacy_validate_actual_compiler(actual, project, owner, valid, home, harness)

        native = project / 'native'
        native.mkdir()
        (native / 'libstb_image_c.a').write_bytes(b'owned control')
        legacy_require(legacy_native_archive_input([native, native / '.'], 'stb_image_c') == (native / 'libstb_image_c.a').resolve(),
                'native repeated resolved candidate positive')
        cells.append('native-repeated-resolved-candidate-positive')
        foreign = project / 'foreign-native'; foreign.mkdir()
        (foreign / 'libstb_image_c.a').write_bytes(b'distinct control')
        red('native-distinct-candidates', lambda: legacy_native_archive_input([native, foreign], 'stb_image_c'), 'support actual native archive input: stb_image_c')
        legacy_native_archive_input([native, native], 'stb_image_c')
        for owner in legacy_SPECS:
            red(owner + '-missing', lambda: legacy_check_raw_tree(project, owner), 'selected descriptor missing')
            root = project / 'packages' / owner
            for path in legacy_production_files(project, owner) + legacy_test_files(project, owner):
                path.parent.mkdir(parents=True, exist_ok=True); path.write_text('module probe;\n')
            legacy_validate_sources(project, owner)
            extra = root / 'source/foreign.d'; extra.write_text('module foreign;\n')
            red(owner + '-extra-source', lambda: legacy_validate_sources(project, owner), 'production source identity')
            extra.unlink()
            extra = root / 'tests/source/foreign.d'; extra.write_text('module foreign;\n')
            red(owner + '-extra-carrier', lambda: legacy_validate_sources(project, owner), 'public carrier identity')
            extra.unlink(); legacy_validate_sources(project, owner)
        # Task 20262210: exercise the real committed archive path for each
        # frozen no-fixture owner; neither may invent a cwd-only fixture.
        for owner in ('display-policy', 'subpatch-preview'):
            with tempfile.TemporaryDirectory(prefix='support-no-fixture-') as source_tmp:
                source = Path(source_tmp)
                for selected in legacy_SPECS[owner]['lower'] + (owner,):
                    path = source / 'packages' / selected / 'source/probe.d'
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('module probe;\n')
                subprocess.run(['git', 'init', '-q', str(source)], check=True)
                subprocess.run(['git', 'add', 'packages'], cwd=source, check=True)
                subprocess.run(['git', '-c', 'user.name=Boundary control', '-c',
                                'user.email=boundary@localhost', 'commit', '-qm',
                                'Create finite archive control'], cwd=source, check=True)
                evidence = project / (owner + '-no-fixture')
                evidence.mkdir()
                archive, _ = legacy_stage_archive(source, owner, evidence)
                legacy_require(legacy_fixture_receipt(archive, owner) == {},
                        'support no-fixture archive receipt: ' + owner)
                cells.append(owner + '-no-fixture-archive')
                red(owner + '-unspecified-fixture',
                    lambda: legacy_validate_staged_fixture({'cwd': str(archive)}, {}, owner, archive),
                    'PREPARATION-REFUSED: fixture staging differs')
        archive = project / 'runtime-archive'
        for owner, relative in (('input-events', ''),
                                ('display-policy', 'packages/display-policy/tests'),
                                ('viewport-gpu', 'packages/viewport-gpu/tests'),
                                ('subpatch-preview', 'packages/subpatch-preview/tests')):
            valid = 'PKG-CWD path=' + str(archive / relative) + '\n'
            legacy_validate_algorithm_cwd(valid, archive, owner)
            cells.append(owner + '-runtime-cwd-positive')
            wrong = archive / 'packages/input-events/tests' if owner == 'input-events' else archive
            red(owner + '-runtime-cwd-wrong',
                lambda: legacy_validate_algorithm_cwd('PKG-CWD path=' + str(wrong) + '\n', archive, owner),
                'support algorithm actual working directory: ' + owner)
            legacy_validate_algorithm_cwd(valid, archive, owner)
        for owner, relative in (('input-events', 'config/shortcuts.yaml'),
                                ('viewport-gpu', 'assets/icon/png/vibe3d_16.png')):
            archive = project / (owner + '-observer-archive')
            statement = legacy_fixture_observer_statement(archive, owner)
            legacy_require('read(' + json.dumps(str(archive / relative)) + ')' in statement,
                    'support exact owned fixture observer path: ' + owner)
            cells.append(owner + '-fixture-observer-positive')
            red(owner + '-fixture-observer-relative',
                lambda: legacy_fixture_observer_statement(Path('relative-archive'), owner),
                'PREPARATION-REFUSED: fixture observer archive path')
        for owner in ('input-events', 'viewport-gpu'):
            relative, sha = legacy_FIXTURES[owner]
            original = {'path': relative, 'sha256': sha, 'cwd': str(project)}
            archive = project / (owner + '-fixture-archive')
            valid = {'path': relative, 'sha256': sha, 'cwd': str(archive.resolve())}
            legacy_validate_staged_fixture(valid, original, owner, archive)
            for field, value in (('path', 'foreign'), ('sha256', '0' * 64),
                                 ('cwd', str(project))):
                broken = dict(valid); broken[field] = value
                red(owner + '-staged-fixture-' + field,
                    lambda: legacy_validate_staged_fixture(broken, original, owner, archive),
                    'PREPARATION-REFUSED: fixture staging differs')
            legacy_validate_staged_fixture(valid, original, owner, archive)
        for owner, (relative, _) in legacy_FIXTURES.items():
            red(owner + '-fixture-missing', lambda: legacy_fixture_receipt(project, owner), 'PREPARATION-REFUSED')
            path = project / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('changed fixture')
            red(owner + '-fixture-changed', lambda: legacy_fixture_receipt(project, owner), 'PREPARATION-REFUSED')
    print('PKG-SELF-CONTROLS passed=' + str(len(cells)))



# Wave8 composition adapters. Legacy controls above retain their frozen fixture domain.
class BoundaryError(RuntimeError):
    pass

def require(condition, message):
    if not condition:
        raise BoundaryError(message)

# Wave8 fixed ownership manifest; exact flags/hooks remain under descriptor pins.
# Wave10: finite BASE ownership with approved source/carrier/descriptor map.
# Wave10: finite BASE ownership with approved source/carrier/descriptor map.
# Wave10: finite BASE ownership with approved source/carrier/descriptor map.
SPECS = {'alignment-ops': {'external': {},
                   'lower': ['edit-contracts', 'interaction-query', 'math', 'mesh'],
                   'name': 'vibe3d-alignment-ops',
                   'ordinaryDigest': '3963b1faaf6e281fff60ae281450314fcd38b499a00c9e44ecfe14d4f839f765',
                   'root': 'packages/alignment-ops',
                   'sources': ['source/tools/alignment/align_kernels.d'],
                   'testDigest': 'c2e1a3b61c3df4876c5d4c3c674d18a328bb47cb4519d0e98f2ee5c8d475b91a',
                   'testImports': ['source', '../source'],
                   'testLower': ['edit-contracts', 'interaction-query', 'math', 'mesh', 'pipe-runtime'],
                   'testSources': ['../source/tools/alignment/align_kernels.d',
                                   'source/tests/unit/alignment_ops_population_test.d',
                                   'source/tests/unit/tools/alignment/align_kernels_test.d']},
 'application-core': {'external': {},
                      'lower': ['camera-model',
                                'command-runtime',
                                'document-model',
                                'edit-contracts',
                                'json-number',
                                'mesh',
                                'mesh-change',
                                'mesh-preview',
                                'spatial'],
                      'name': 'vibe3d-application-core',
                      'ordinaryDigest': 'aad69d5aad8f65efc4b4a840161f9ccd02c42c2c52b94e899f9a311e987a983f',
                      'root': 'packages/application-core',
                      'sources': ['source/app_version.d',
                                  'source/http_json.d',
                                  'source/io/doc_state.d',
                                  'source/live_registration_roles.d',
                                  'source/morph_target.d',
                                  'source/pilot_command_registration.d',
                                  'source/session_owner.d',
                                  'source/standalone_application.d'],
                      'testDigest': 'ef459f06e0e3c975e5cf9c79e2946dd5bc921ef9bd7d8979537cb9cd4aec30c8',
                      'testImports': ['source', '../source'],
                      'testLower': ['camera-model',
                                    'command-runtime',
                                    'document-model',
                                    'edit-contracts',
                                    'json-number',
                                    'math',
                                    'mesh',
                                    'mesh-change',
                                    'mesh-edit-log',
                                    'mesh-edit-replay',
                                    'mesh-preview',
                                    'mesh-snapshot',
                                    'param-schema',
                                    'pipe-contracts',
                                    'pipe-runtime',
                                    'spatial'],
                      'testSources': ['../source/app_version.d',
                                      '../source/http_json.d',
                                      '../source/io/doc_state.d',
                                      '../source/live_registration_roles.d',
                                      '../source/morph_target.d',
                                      '../source/pilot_command_registration.d',
                                      '../source/session_owner.d',
                                      '../source/standalone_application.d',
                                      'source/tests/unit/application_core_population_test.d',
                                      'source/tests/unit/command_invocation_test.d',
                                      'source/tests/unit/standalone_application_test.d']},
 'camera-model': {'external': {},
                  'lower': ['json-number', 'math', 'spatial'],
                  'name': 'vibe3d:camera-model',
                  'ordinaryDigest': '228eda514ff1bc6ca2af4ac511c0c802bb5d554544a20c664586b925a5dd25a9',
                  'root': 'libraries/viewport/camera',
                  'sources': ['source/vibe3d/viewport/camera/view.d'],
                  'testDigest': '9eadac90211420d107b93e12d98b5973a30f55989e2bb7334faaf67e75405997',
                  'testImports': ['source', '../source'],
                  'testLower': ['json-number', 'math', 'spatial'],
                  'testSources': ['../source/vibe3d/viewport/camera/view.d',
 'source/vibe3d/viewport/camera/tests/unit/camera_model_population_test.d',
 'source/vibe3d/viewport/camera/tests/unit/view_source_cells_test.d',
 'source/vibe3d/viewport/camera/tests/unit/view_test.d'], 'targetName': 'vibe3d-camera-model', 'testName': 'vibe3d-camera-model-tests'},
 'command-runtime': {'external': {},
                     'lower': ['camera-model',
                               'document-model',
                               'edit-contracts',
                               'math',
                               'mesh',
                               'mesh-change',
                               'mesh-edit-log',
                               'mesh-edit-replay',
                               'mesh-ops',
                               'mesh-snapshot',
                               'param-schema',
                               'pipe-contracts',
                               'pipe-runtime',
                               'profiling',
                               'spatial'],
                     'name': 'vibe3d-command-runtime',
                     'ordinaryDigest': 'aff5ab9f4c6df157e4f25b451b9426cc97ba239bdba454c9f4a596600cd67fee',
                     'root': 'packages/command-runtime',
                     'sources': ['source/command.d',
                                 'source/command_args.d',
                                 'source/command_executor.d',
                                 'source/command_history.d',
                                 'source/command_invocation.d',
                                 'source/command_registry.d',
                                 'source/command_tool_policy.d',
                                 'source/commands/history/redo.d',
                                 'source/commands/history/undo.d',
                                 'source/commands/mesh/gesture_payload.d',
                                 'source/commands/mesh/mesh_edit_payload.d',
                                 'source/commands/mesh/select.d',
                                 'source/commands/mesh/selection_undo.d',
                                 'source/commands/mesh/session_edit.d',
                                 'source/commands/mesh/triple.d',
                                 'source/commands/mesh/vertex_edit.d',
                                 'source/commands/select/drop.d',
                                 'source/commands/select/element.d',
                                 'source/commands/select/invert.d',
                                 'source/history_lifecycle_contract.d',
                                 'source/record_observer_hub.d',
                                 'source/tool_activation_ownership.d'],
                     'testDigest': '72ecca5d3e11e9a42f597c3ed6baf167719d230c8f957779dec38d2a5c28d919',
                     'testImports': ['source', '../source'],
                     'testLower': ['camera-model',
                                   'document-model',
                                   'edit-contracts',
                                   'math',
                                   'mesh',
                                   'mesh-change',
                                   'mesh-edit-log',
                                   'mesh-edit-replay',
                                   'mesh-ops',
                                   'mesh-snapshot',
                                   'param-schema',
                                   'pipe-contracts',
                                   'pipe-runtime',
                                   'profiling',
                                   'spatial'],
                     'testSources': ['../source/command.d',
                                     '../source/command_args.d',
                                     '../source/command_executor.d',
                                     '../source/command_history.d',
                                     '../source/command_invocation.d',
                                     '../source/command_registry.d',
                                     '../source/command_tool_policy.d',
                                     '../source/commands/history/redo.d',
                                     '../source/commands/history/undo.d',
                                     '../source/commands/mesh/gesture_payload.d',
                                     '../source/commands/mesh/mesh_edit_payload.d',
                                     '../source/commands/mesh/select.d',
                                     '../source/commands/mesh/selection_undo.d',
                                     '../source/commands/mesh/session_edit.d',
                                     '../source/commands/mesh/triple.d',
                                     '../source/commands/mesh/vertex_edit.d',
                                     '../source/commands/select/drop.d',
                                     '../source/commands/select/element.d',
                                     '../source/commands/select/invert.d',
                                     '../source/history_lifecycle_contract.d',
                                     '../source/record_observer_hub.d',
                                     '../source/tool_activation_ownership.d',
                                     'source/tests/unit/base_revert_flag_test.d',
                                     'source/tests/unit/command_apply_anchor_test.d',
                                     'source/tests/unit/command_bindargs_test.d',
                                     'source/tests/unit/command_history_source_public_test.d',
                                     'source/tests/unit/command_registry_test.d',
                                     'source/tests/unit/command_source_public_test.d',
                                     'source/tests/unit/commands/mesh/session_edit_source_public_test.d',
                                     'source/tests/unit/commands/select/element_source_public_test.d',
                                     'source/tests/unit/record_observer_hub_source_public_test.d',
                                     'source/tests/unit/session_edit_payload_test.d',
                                     'source/tests/unit/command_runtime_population_test.d']},
 'creation-ops': {'external': {},
                  'lower': ['edit-contracts',
                            'interaction-query',
                            'math',
                            'mesh',
                            'pipe-contracts',
                            'spatial'],
                  'name': 'vibe3d-creation-ops',
                  'ordinaryDigest': '1249c23585fc39f48c3395adf164f9e1a643299b75b2f5d9e0cd308cf3ba603c',
                  'root': 'packages/creation-ops',
                  'sources': ['source/tools/create/pen_geometry.d'],
                  'testDigest': 'bca9d47b47b4cbeedde813b55aabfe9850c0bfe6bdffe0b31eb27d2ff64de3a7',
                  'testImports': ['source', '../source'],
                  'testLower': ['edit-contracts',
                                'interaction-query',
                                'math',
                                'mesh',
                                'pipe-contracts',
                                'spatial'],
                  'testSources': ['../source/tools/create/pen_geometry.d',
                                  'source/tests/unit/tools/create/pen_geometry_population_test.d',
                                  'source/tests/unit/tools/create/pen_geometry_test.d']},
 'display-policy': {'external': {},
                    'lower': ['document-model', 'math', 'mesh', 'mesh-change'],
                    'name': 'vibe3d-display-policy',
                    'ordinaryDigest': '7eab2420108de2b92aa6f644ad94c8ee87cb785049455c9966557697aab4ce67',
                    'root': 'packages/display-policy',
                    'sources': ['source/camera_stamp.d',
                                'source/display_state.d',
                                'source/light_rig.d',
                                'source/retopology_dot_cull.d',
                                'source/retopology_line_shade.d',
                                'source/retopology_order.d',
                                'source/select_visibility.d',
                                'source/vertex_normals.d',
                                'source/viewport_overlay_mode.d',
                                'source/viewport_probe_sampling.d',
                                'source/viewport_scheme.d',
                                'source/weightmap_view.d'],
                    'testDigest': 'cda8f1dc74a5b3cb1ff1d347eb6513b466c473ae56a8708a1e045f2d469ced62',
                    'testImports': ['source', '../source'],
                    'testLower': ['document-model', 'math', 'mesh', 'mesh-change'],
                    'testSources': ['../source/camera_stamp.d',
                                    '../source/display_state.d',
                                    '../source/light_rig.d',
                                    '../source/vertex_normals.d',
                                    '../source/viewport_overlay_mode.d',
                                    '../source/viewport_probe_sampling.d',
                                    '../source/viewport_scheme.d',
                                    '../source/weightmap_view.d',
                                    'source/tests/unit/camera_stamp_test.d',
                                    'source/tests/unit/display_policy_population_test.d',
                                    'source/tests/unit/vertex_normals_test.d',
                                    'source/tests/unit/viewport_scheme_test.d',
                                    'source/tests/unit/weightmap_state_test.d',
                                    '../source/retopology_dot_cull.d',
                                    '../source/retopology_line_shade.d',
                                    '../source/retopology_order.d',
                                    '../source/select_visibility.d',
                                    'source/tests/unit/retopology_display_model_test.d',
                                    'source/tests/unit/retopology_dot_cull_test.d',
                                    'source/tests/unit/retopology_line_shade_algorithm_cells_test.d',
                                    'source/tests/unit/retopology_order_algorithm_cells_test.d',
                                    'source/tests/unit/select_visibility_test.d']},
 'document-channels': {'external': {},
                       'lower': ['document-model', 'edit-contracts', 'param-schema'],
                       'name': 'vibe3d-document-channels',
                       'ordinaryDigest': '5c4feab4be725e46c532e68995ce7ec25d4eda4900eb23b74fd3724c1636d57b',
                       'root': 'packages/document-channels',
                       'sources': ['source/layer_params.d'],
                       'testDigest': '2aadcf0805c3a4bede5fbddcd75f7daee354b5b83eb81da3ba84eed695661614',
                       'testImports': ['source', '../source'],
                       'testLower': ['document-model', 'edit-contracts', 'math', 'mesh', 'param-schema'],
                       'testSources': ['../source/layer_params.d',
                                       'source/tests/unit/document_channels_population_test.d',
                                       'source/tests/unit/layer_params_test.d']},
 'document-io': {'external': {},
                 'lower': ['document-channels',
                           'document-model',
                           'edit-contracts',
                           'image-codec',
                           'log',
                           'math',
                           'mesh',
                           'param-schema',
                           'spatial'],
                 'name': 'vibe3d-document-io',
                 'ordinaryDigest': 'a98fe33293c6487839f676c4986662c0ce3968df8b80df2a89146d13d88d9b21',
                 'root': 'packages/document-io',
                 'sources': ['source/io/file_model.d', 'source/io/image_path.d', 'source/io/native.d'],
                 'testDigest': 'e6684c2bede8d7b3b2f83781db70d0b61448bcbe7818c79edbe1c95bad50a1f7',
                 'testImports': ['source', '../source'],
                 'testLower': ['document-channels',
                               'document-model',
                               'edit-contracts',
                               'image-codec',
                               'log',
                               'math',
                               'mesh',
                               'param-schema',
                               'spatial'],
                 'testSources': ['../source/io/file_model.d',
                                 '../source/io/image_path.d',
                                 '../source/io/native.d',
                                 'source/tests/unit/document_io_population_test.d',
                                 'source/tests/unit/io/image_path_test.d',
                                 'source/tests/unit/io/native_source_cells_test.d',
                                 'source/tests/unit/io/native_test.d']},
 'document-model': {'external': {},
                    'lower': ['edit-contracts', 'mesh', 'mesh-change', 'profiling', 'spatial'],
                    'name': 'vibe3d:document-model',
                    'ordinaryDigest': 'e4ea330a272ba8734d5ce79ff70b9c7e66e32143f4e74eb0dbfafede40bbcfd2',
                    'root': 'libraries/documents/model',
                    'sources': ['source/vibe3d/documents/model/document.d',
 'source/vibe3d/documents/model/document_selection.d',
 'source/vibe3d/documents/model/edit_target_contract.d',
 'source/vibe3d/documents/model/image_data.d',
 'source/vibe3d/documents/model/item_kinds.d'],
                    'testDigest': '77817144abc2343f41c4c0c06ff7306dfa31bc3d39430232a963d3f1a73809a8',
                    'testImports': ['source', '../source'],
                    'testLower': ['edit-contracts',
                                  'math',
                                  'mesh',
                                  'mesh-change',
                                  'mesh-edit-log',
                                  'profiling',
                                  'spatial'],
                    'testSources': ['../source/vibe3d/documents/model/document.d',
 '../source/vibe3d/documents/model/document_selection.d',
 '../source/vibe3d/documents/model/edit_target_contract.d',
 '../source/vibe3d/documents/model/image_data.d',
 '../source/vibe3d/documents/model/item_kinds.d',
 'source/vibe3d/documents/model/tests/unit/document_test.d'], 'targetName': 'vibe3d-document-model', 'testName': 'vibe3d-document-model-tests', 'transitionalSources': ['source/vibe3d/documents/model/package.d']},
 'edit-contracts': {'external': {},
                    'lower': [],
                    'name': 'vibe3d:edit-contracts',
                    'ordinaryDigest': '41bc111fb877ed5cc8487469ff02b19257cab0c9f430dd29e93e3adc9ffb0601',
                    'root': 'libraries/editing/contracts',
                    'sources': ['source/vibe3d/editing/contracts/editmode.d', 'source/vibe3d/editing/contracts/prepared_tool_effect.d', 'source/vibe3d/editing/contracts/seltype.d', 'source/vibe3d/editing/contracts/tool_policy_values.d'],
                    'testDigest': '53008887b5ecc5be592b131994f16c9bb852889a9816fc254ca631a524b051d7',
                    'testImports': ['../source', 'source'],
                    'testLower': [],
                    'testSources': ['../source/vibe3d/editing/contracts/editmode.d', '../source/vibe3d/editing/contracts/prepared_tool_effect.d', '../source/vibe3d/editing/contracts/seltype.d', 'source/vibe3d/editing/contracts/tests/unit/seltype_test.d', '../source/vibe3d/editing/contracts/tool_policy_values.d'], 'targetName': 'vibe3d-edit-contracts', 'testName': 'vibe3d-edit-contracts-tests'},
 'editor-commands': {'external': {},
                     'lower': ['alignment-ops',
                               'camera-model',
                               'command-runtime',
                               'display-policy',
                               'document-model',
                               'edit-contracts',
                               'interaction-query',
                               'math',
                               'mesh',
                               'mesh-change',
                               'mesh-edit-log',
                               'mesh-edit-replay',
                               'mesh-ops',
                               'mesh-snapshot',
                               'param-schema',
                               'pipe-contracts',
                               'pipe-evaluation',
                               'pipe-runtime',
                               'scene-query',
                               'selection-model',
                               'spatial',
                               'subpatch-preview',
                               'viewport-gpu'],
                     'name': 'vibe3d-editor-commands',
                     'ordinaryDigest': '6cab93f8be434032a553ad07f3374d3eb6f3b7eadb35313c3b1f460c400b1a4c',
                     'root': 'packages/editor-commands',
                     'sources': ['source/commands/history/clear.d',
                                 'source/commands/history/save_as_script.d',
                                 'source/commands/history/show.d',
                                 'source/commands/layer/xform_edit.d',
                                 'source/commands/macros/record.d',
                                 'source/commands/macros/save_recorded.d',
                                 'source/commands/mesh/add_point.d',
                                 'source/commands/mesh/array_.d',
                                 'source/commands/mesh/axis_slice.d',
                                 'source/commands/mesh/bevel.d',
                                 'source/commands/mesh/bridge.d',
                                 'source/commands/mesh/cleanup.d',
                                 'source/commands/mesh/clone_.d',
                                 'source/commands/mesh/collapse.d',
                                 'source/commands/mesh/copy_.d',
                                 'source/commands/mesh/cut_.d',
                                 'source/commands/mesh/delete_.d',
                                 'source/commands/mesh/detriangulate.d',
                                 'source/commands/mesh/duplicate_.d',
                                 'source/commands/mesh/edge_crease.d',
                                 'source/commands/mesh/edge_extend.d',
                                 'source/commands/mesh/edge_extrude.d',
                                 'source/commands/mesh/edge_join.d',
                                 'source/commands/mesh/edge_slice.d',
                                 'source/commands/mesh/edge_slide.d',
                                 'source/commands/mesh/face_extrude.d',
                                 'source/commands/mesh/fix_orientation.d',
                                 'source/commands/mesh/flip.d',
                                 'source/commands/mesh/hide.d',
                                 'source/commands/mesh/jitter.d',
                                 'source/commands/mesh/linear_align.d',
                                 'source/commands/mesh/loop_slice.d',
                                 'source/commands/mesh/make_polygon.d',
                                 'source/commands/mesh/map_edit_undo.d',
                                 'source/commands/mesh/merge.d',
                                 'source/commands/mesh/mirror_.d',
                                 'source/commands/mesh/morph_edit.d',
                                 'source/commands/mesh/move_vertex.d',
                                 'source/commands/mesh/paste_.d',
                                 'source/commands/mesh/poly_inset.d',
                                 'source/commands/mesh/polygon_align.d',
                                 'source/commands/mesh/position_undo.d',
                                 'source/commands/mesh/quadruple.d',
                                 'source/commands/mesh/quantize.d',
                                 'source/commands/mesh/radial_align.d',
                                 'source/commands/mesh/radial_array_.d',
                                 'source/commands/mesh/reduce.d',
                                 'source/commands/mesh/remove_.d',
                                 'source/commands/mesh/screen_slice.d',
                                 'source/commands/mesh/selection_edit.d',
                                 'source/commands/mesh/set_material.d',
                                 'source/commands/mesh/set_part.d',
                                 'source/commands/mesh/smooth_shift.d',
                                 'source/commands/mesh/spikey.d',
                                 'source/commands/mesh/spin_edge.d',
                                 'source/commands/mesh/split_edge.d',
                                 'source/commands/mesh/split_face.d',
                                 'source/commands/mesh/stroke_extrude.d',
                                 'source/commands/mesh/subdivide.d',
                                 'source/commands/mesh/subdivide_faceted.d',
                                 'source/commands/mesh/subpatch_toggle.d',
                                 'source/commands/mesh/surface_attr.d',
                                 'source/commands/mesh/sweep.d',
                                 'source/commands/mesh/symmetrize.d',
                                 'source/commands/mesh/thicken.d',
                                 'source/commands/mesh/transform.d',
                                 'source/commands/mesh/unify.d',
                                 'source/commands/mesh/uv_map_util.d',
                                 'source/commands/mesh/uv_pack.d',
                                 'source/commands/mesh/uv_project.d',
                                 'source/commands/mesh/uv_relax.d',
                                 'source/commands/mesh/uv_transform.d',
                                 'source/commands/mesh/uv_unwrap.d',
                                 'source/commands/mesh/vert_join.d',
                                 'source/commands/mesh/vert_merge.d',
                                 'source/commands/mesh/vertex_bevel.d',
                                 'source/commands/mesh/vertex_center.d',
                                 'source/commands/mesh/vertex_extrude.d',
                                 'source/commands/mesh/vertex_new.d',
                                 'source/commands/mesh/vertex_position_result.d',
                                 'source/commands/mesh/vertex_set.d',
                                 'source/commands/mesh/vertex_split.d',
                                 'source/commands/mesh/weightmap.d',
                                 'source/commands/mesh/weld_vertex_pair.d',
                                 'source/commands/select/between.d',
                                 'source/commands/select/boundary.d',
                                 'source/commands/select/by_stat.d',
                                 'source/commands/select/by_tag.d',
                                 'source/commands/select/connect.d',
                                 'source/commands/select/contract.d',
                                 'source/commands/select/convert.d',
                                 'source/commands/select/expand.d',
                                 'source/commands/select/fill.d',
                                 'source/commands/select/less.d',
                                 'source/commands/select/loop.d',
                                 'source/commands/select/more.d',
                                 'source/commands/select/ring.d',
                                 'source/commands/select/sets.d',
                                 'source/commands/select/type_from.d',
                                 'source/macro_recorder.d',
                                 'source/step_trace.d'],
                     'testDigest': '18b1a4e6c098ee5085bc7c4a70c2076f159fbc39ae5f8beda16baa24d19a4da5',
                     'testImports': ['../source', 'source'],
                     'testLower': ['alignment-ops',
                                   'camera-model',
                                   'command-runtime',
                                   'display-policy',
                                   'document-model',
                                   'edit-contracts',
                                   'interaction-query',
                                   'math',
                                   'mesh',
                                   'mesh-change',
                                   'mesh-edit-log',
                                   'mesh-edit-replay',
                                   'mesh-ops',
                                   'mesh-snapshot',
                                   'param-schema',
                                   'pipe-contracts',
                                   'pipe-evaluation',
                                   'pipe-runtime',
                                   'scene-query',
                                   'selection-model',
                                   'spatial',
                                   'subpatch-preview',
                                   'viewport-gpu'],
                     'testSources': ['../source/commands/history/clear.d',
                                     '../source/commands/history/save_as_script.d',
                                     '../source/commands/history/show.d',
                                     '../source/commands/layer/xform_edit.d',
                                     '../source/commands/macros/record.d',
                                     '../source/commands/macros/save_recorded.d',
                                     '../source/commands/mesh/add_point.d',
                                     '../source/commands/mesh/array_.d',
                                     '../source/commands/mesh/axis_slice.d',
                                     '../source/commands/mesh/bevel.d',
                                     '../source/commands/mesh/bridge.d',
                                     '../source/commands/mesh/cleanup.d',
                                     '../source/commands/mesh/clone_.d',
                                     '../source/commands/mesh/collapse.d',
                                     '../source/commands/mesh/copy_.d',
                                     '../source/commands/mesh/cut_.d',
                                     '../source/commands/mesh/delete_.d',
                                     '../source/commands/mesh/detriangulate.d',
                                     '../source/commands/mesh/duplicate_.d',
                                     '../source/commands/mesh/edge_crease.d',
                                     '../source/commands/mesh/edge_extend.d',
                                     '../source/commands/mesh/edge_extrude.d',
                                     '../source/commands/mesh/edge_join.d',
                                     '../source/commands/mesh/edge_slice.d',
                                     '../source/commands/mesh/edge_slide.d',
                                     '../source/commands/mesh/face_extrude.d',
                                     '../source/commands/mesh/fix_orientation.d',
                                     '../source/commands/mesh/flip.d',
                                     '../source/commands/mesh/hide.d',
                                     '../source/commands/mesh/jitter.d',
                                     '../source/commands/mesh/linear_align.d',
                                     '../source/commands/mesh/loop_slice.d',
                                     '../source/commands/mesh/make_polygon.d',
                                     '../source/commands/mesh/map_edit_undo.d',
                                     '../source/commands/mesh/merge.d',
                                     '../source/commands/mesh/mirror_.d',
                                     '../source/commands/mesh/morph_edit.d',
                                     '../source/commands/mesh/move_vertex.d',
                                     '../source/commands/mesh/paste_.d',
                                     '../source/commands/mesh/poly_inset.d',
                                     '../source/commands/mesh/polygon_align.d',
                                     '../source/commands/mesh/position_undo.d',
                                     '../source/commands/mesh/quadruple.d',
                                     '../source/commands/mesh/quantize.d',
                                     '../source/commands/mesh/radial_align.d',
                                     '../source/commands/mesh/radial_array_.d',
                                     '../source/commands/mesh/reduce.d',
                                     '../source/commands/mesh/remove_.d',
                                     '../source/commands/mesh/screen_slice.d',
                                     '../source/commands/mesh/selection_edit.d',
                                     '../source/commands/mesh/set_material.d',
                                     '../source/commands/mesh/set_part.d',
                                     '../source/commands/mesh/smooth_shift.d',
                                     '../source/commands/mesh/spikey.d',
                                     '../source/commands/mesh/spin_edge.d',
                                     '../source/commands/mesh/split_edge.d',
                                     '../source/commands/mesh/split_face.d',
                                     '../source/commands/mesh/stroke_extrude.d',
                                     '../source/commands/mesh/subdivide.d',
                                     '../source/commands/mesh/subdivide_faceted.d',
                                     '../source/commands/mesh/subpatch_toggle.d',
                                     '../source/commands/mesh/surface_attr.d',
                                     '../source/commands/mesh/sweep.d',
                                     '../source/commands/mesh/symmetrize.d',
                                     '../source/commands/mesh/thicken.d',
                                     '../source/commands/mesh/transform.d',
                                     '../source/commands/mesh/unify.d',
                                     '../source/commands/mesh/uv_map_util.d',
                                     '../source/commands/mesh/uv_pack.d',
                                     '../source/commands/mesh/uv_project.d',
                                     '../source/commands/mesh/uv_relax.d',
                                     '../source/commands/mesh/uv_transform.d',
                                     '../source/commands/mesh/uv_unwrap.d',
                                     '../source/commands/mesh/vert_join.d',
                                     '../source/commands/mesh/vert_merge.d',
                                     '../source/commands/mesh/vertex_bevel.d',
                                     '../source/commands/mesh/vertex_center.d',
                                     '../source/commands/mesh/vertex_extrude.d',
                                     '../source/commands/mesh/vertex_new.d',
                                     '../source/commands/mesh/vertex_position_result.d',
                                     '../source/commands/mesh/vertex_set.d',
                                     '../source/commands/mesh/vertex_split.d',
                                     '../source/commands/mesh/weightmap.d',
                                     '../source/commands/mesh/weld_vertex_pair.d',
                                     '../source/commands/select/between.d',
                                     '../source/commands/select/boundary.d',
                                     '../source/commands/select/by_stat.d',
                                     '../source/commands/select/by_tag.d',
                                     '../source/commands/select/connect.d',
                                     '../source/commands/select/contract.d',
                                     '../source/commands/select/convert.d',
                                     '../source/commands/select/expand.d',
                                     '../source/commands/select/fill.d',
                                     '../source/commands/select/less.d',
                                     '../source/commands/select/loop.d',
                                     '../source/commands/select/more.d',
                                     '../source/commands/select/ring.d',
                                     '../source/commands/select/sets.d',
                                     '../source/commands/select/type_from.d',
                                     '../source/macro_recorder.d',
                                     '../source/step_trace.d',
                                     'source/tests/unit/commands/layer/xform_edit_source_public_test.d',
                                     'source/tests/unit/commands/mesh/edge_crease_source_public_test.d',
                                     'source/tests/unit/commands/mesh/remove_source_public_test.d',
                                     'source/tests/unit/commands/mesh/symmetrize_source_public_test.d',
                                     'source/tests/unit/commands/mesh/vertex_set_source_public_test.d',
                                     'source/tests/unit/commands/select/boundary_source_public_test.d',
                                     'source/tests/unit/commands/select/by_stat_source_public_test.d',
                                     'source/tests/unit/commands/select/by_tag_source_public_test.d',
                                     'source/tests/unit/commands/select/type_from_source_public_test.d',
                                     'source/tests/unit/editor_commands_population_test.d']},
 'image-codec': {'external': {'d-stb-image': {'repository': 'git+https://github.com/shulc/D-StbImage.git',
                                              'version': 'a66f6917718ea128076a2c5660e37f362a785144'}},
                 'lower': ['log'],
                 'name': 'vibe3d:image-codec',
                 'ordinaryDigest': '4e4de67dbdc28aa3a23a18e7d72e7aa65bec17a1c85c5de9fa9ef18742631114',
                 'root': 'libraries/documents/image-codec',
                 'sources': ['source/vibe3d/documents/image_codec/io/image_decode.d'],
                 'testDigest': 'b4fa430a77a16e76ad08ce07de1d5788a9b5eefe70454c5d492b8860e16b1d77',
                 'testImports': ['source', '../source'],
                 'testLower': ['log'],
                 'testSources': ['../source/vibe3d/documents/image_codec/io/image_decode.d',
 'source/vibe3d/documents/image_codec/tests/unit/image_codec_population_test.d',
 'source/vibe3d/documents/image_codec/tests/unit/io/image_decode_source_cells_test.d',
 'source/vibe3d/documents/image_codec/tests/unit/io/image_decode_test.d'], 'targetName': 'vibe3d-image-codec', 'testName': 'vibe3d-image-codec-tests'},
 'input-events': {'external': {'bindbc-sdl': '~>1.5.2',
              'dyaml': {'repository': 'git+https://github.com/shulc/D-YAML.git',
                        'version': '22e4724474795eefb64ee9742f980b49bb34f6ef'}},
 'lower': ['log'],
 'name': 'vibe3d:input-events',
 'ordinaryDigest': '8a4e972bc643eba8cccd01f104925df194919f630108634a49da25f842313838',
 'root': 'libraries/platform/input',
 'sources': ['source/vibe3d/platform/input/eventlog.d',
 'source/vibe3d/platform/input/held_gesture_buttons.d',
 'source/vibe3d/platform/input/input_context.d',
 'source/vibe3d/platform/input/input_zones.d',
 'source/vibe3d/platform/input/sdl_error.d',
 'source/vibe3d/platform/input/shortcuts.d',
 'source/vibe3d/platform/input/tool_input.d'],
 'testDigest': '70dfefa1f6605ad33b343e13cb7b97f8ee013b098daa0dd8a89a85013231470a',
 'testImports': ['source', '../source'],
 'testLower': ['log'],
 'testSources': ['../source/vibe3d/platform/input/eventlog.d',
 '../source/vibe3d/platform/input/held_gesture_buttons.d',
 '../source/vibe3d/platform/input/input_context.d',
 '../source/vibe3d/platform/input/input_zones.d',
 '../source/vibe3d/platform/input/sdl_error.d',
 '../source/vibe3d/platform/input/shortcuts.d',
 '../source/vibe3d/platform/input/tool_input.d',
 'source/vibe3d/platform/input/tests/unit/binding_resolve_test.d',
 'source/vibe3d/platform/input/tests/unit/eventlog_parser_test.d',
 'source/vibe3d/platform/input/tests/unit/eventlog_test.d',
 'source/vibe3d/platform/input/tests/unit/input_events_population_test.d',
 'source/vibe3d/platform/input/tests/unit/sdl_error_test.d',
 'source/vibe3d/platform/input/tests/unit/tool_input_test.d'], 'targetName': 'vibe3d-input-events', 'testName': 'vibe3d-input-events-tests'},
 'interaction-data': {'external': {},
                      'lower': [],
                      'name': 'vibe3d:interaction-data',
                      'ordinaryDigest': '4ce2e19a51f0324fea321556176c945b3194844df79bd0a12138691c396bdaf1',
                      'root': 'libraries/editing/interaction/data',
                      'sources': ['source/vibe3d/editing/interaction/data/ai/advisor.d', 'source/vibe3d/editing/interaction/data/ai/debug_trace.d', 'source/vibe3d/editing/interaction/data/ai/interaction.d'],
                      'testDigest': '401d1499bdeab32f673737a1a4bd081f1d19b0fedb206231ae6fee0f4e6160a1',
                      'testImports': ['source', '../source'],
                      'testLower': [],
                      'testSources': ['../source/vibe3d/editing/interaction/data/ai/advisor.d', '../source/vibe3d/editing/interaction/data/ai/debug_trace.d', '../source/vibe3d/editing/interaction/data/ai/interaction.d', 'source/vibe3d/editing/interaction/data/tests/unit/ai/advisor_test.d', 'source/vibe3d/editing/interaction/data/tests/unit/ai/debug_trace_test.d', 'source/vibe3d/editing/interaction/data/tests/unit/ai/interaction_test.d'], 'targetName': 'vibe3d-interaction-data', 'testName': 'vibe3d-interaction-data-tests'},
 'interaction-query': {'external': {'d-bvh': {'repository': 'git+https://github.com/shulc/D-BVH.git',
                                              'version': 'e1a8f41501f94a28dbac99efbea850ed098fa728'}},
                       'lower': ['edit-contracts',
                                 'math',
                                 'mesh',
                                 'mesh-change',
                                 'mesh-preview',
                                 'pipe-contracts',
                                 'profiling',
                                 'screen-buckets',
                                 'spatial'],
                       'name': 'vibe3d-interaction-query',
                       'ordinaryDigest': '3ef8791611a6b7027a38e9cb0cc402a74a8e8231c4b17e0f167d5ca071ccc7e1',
                       'root': 'packages/interaction-query',
                       'sources': ['source/constraint.d',
                                   'source/hover_state.d',
                                   'source/mesh_bbox.d',
                                   'source/mesh_visibility.d',
                                   'source/path.d',
                                   'source/snap.d',
                                   'source/snap_election.d',
                                   'source/surface_pick.d',
                                   'source/symmetry.d',
                                   'source/toolpipe/guide.d',
                                   'source/viewgrid.d',
                                   'source/workplane_fit.d'],
                       'testDigest': '0971a1438929a485135959c1bd535557ad13eed2e540808ae8c40824a424b18d',
                       'testImports': ['source', '../source'],
                       'testLower': ['edit-contracts',
                                     'math',
                                     'mesh',
                                     'mesh-change',
                                     'mesh-preview',
                                     'pipe-contracts',
                                     'profiling',
                                     'screen-buckets',
                                     'spatial'],
                       'testSources': ['../source/constraint.d',
                                       '../source/hover_state.d',
                                       '../source/mesh_bbox.d',
                                       '../source/mesh_visibility.d',
                                       '../source/path.d',
                                       '../source/snap.d',
                                       '../source/snap_election.d',
                                       '../source/surface_pick.d',
                                       '../source/symmetry.d',
                                       '../source/toolpipe/guide.d',
                                       '../source/viewgrid.d',
                                       '../source/workplane_fit.d',
                                       'source/tests/unit/constraint_regression_test.d',
                                       'source/tests/unit/constraint_test.d',
                                       'source/tests/unit/path_test.d',
                                       'source/tests/unit/snap_election_corpus_test.d',
                                       'source/tests/unit/snap_regression_test.d',
                                       'source/tests/unit/snap_test.d',
                                       'source/tests/unit/symmetry_regression_test.d',
                                       'source/tests/unit/viewgrid_regression_test.d',
                                       'source/tests/unit/viewgrid_test.d',
                                       'source/tests/unit/workplane_fit_test.d']},
 'interactive-tools': {'external': {'bindbc-opengl': '~>1.1.1',
                                    'bindbc-sdl': '~>1.5.2',
                                    'd_imgui': {'repository': 'git+https://github.com/shulc/D-ImGui.git',
                                                'version': 'd535ba78c7d01aca3c9d45ca94ea8e55455ffb7f'},
                                    'dyaml': {'repository': 'git+https://github.com/shulc/D-YAML.git',
                                              'version': '22e4724474795eefb64ee9742f980b49bb34f6ef'}},
                       'lower': ['alignment-ops',
                                 'application-core',
                                 'camera-model',
                                 'command-runtime',
                                 'creation-ops',
                                 'display-policy',
                                 'document-model',
                                 'edit-contracts',
                                 'editor-commands',
                                 'input-events',
                                 'interaction-data',
                                 'interaction-query',
                                 'log',
                                 'math',
                                 'mesh',
                                 'mesh-change',
                                 'mesh-edit-log',
                                 'mesh-ops',
                                 'mesh-snapshot',
                                 'mesh-topology',
                                 'param-schema',
                                 'pipe-contracts',
                                 'pipe-evaluation',
                                 'pipe-runtime',
                                 'profiling',
                                 'scene-query',
                                 'selection-model',
                                 'spatial',
                                 'tool-state',
                                 'transform-ops',
                                 'viewport-gpu'],
                       'name': 'vibe3d-interactive-tools',
                       'ordinaryDigest': '1cfe8362ae2f3c5fe8a40a4e00ab9814bd5a8d3312fbddbb1c6721401a8a37b9',
                       'root': 'packages/interactive-tools',
                       'sources': ['source/commands/mesh/smooth.d',
                                   'source/commands/tool/attr.d',
                                   'source/commands/tool/begin_session.d',
                                   'source/commands/tool/bridge_headless.d',
                                   'source/commands/tool/do_apply.d',
                                   'source/commands/tool/headless.d',
                                   'source/commands/tool/host.d',
                                   'source/commands/tool/lifecycle.d',
                                   'source/commands/tool/panel_edit.d',
                                   'source/commands/tool/pipe.d',
                                   'source/commands/tool/reset.d',
                                   'source/commands/tool/set.d',
                                   'source/coord_rounding.d',
                                   'source/deform_magnet.d',
                                   'source/drag.d',
                                   'source/edit_session.d',
                                   'source/evaluated_move_weld.d',
                                   'source/falloff_handles.d',
                                   'source/falloff_render.d',
                                   'source/gizmo.d',
                                   'source/handler.d',
                                   'source/handles/arbiter.d',
                                   'source/handles/gizmo_metrics.d',
                                   'source/handles/gl_util.d',
                                   'source/handles/shapes.d',
                                   'source/model_preview.d',
                                   'source/overlay_space.d',
                                   'source/params_widgets.d',
                                   'source/pipe_gizmo_host.d',
                                   'source/prepared_box_param.d',
                                   'source/prepared_bridge_activation.d',
                                   'source/prepared_command_wrapper_activation.d',
                                   'source/prepared_edge_bevel_activation.d',
                                   'source/prepared_edge_extend_deactivate.d',
                                   'source/prepared_edge_extend_tool_activation.d',
                                   'source/prepared_edge_extrude_activation.d',
                                   'source/prepared_edge_slice_activation.d',
                                   'source/prepared_edge_slice_deactivate.d',
                                   'source/prepared_inherited_noop.d',
                                   'source/prepared_loop_slice_activation.d',
                                   'source/prepared_loop_slice_deactivate.d',
                                   'source/prepared_mirror_activation.d',
                                   'source/prepared_move_update.d',
                                   'source/prepared_param_update.d',
                                   'source/prepared_pipe_activation.d',
                                   'source/prepared_poly_bevel_activation.d',
                                   'source/prepared_poly_extrude_activation.d',
                                   'source/prepared_poly_inset_activation.d',
                                   'source/prepared_private_state.d',
                                   'source/prepared_radial_array_transition.d',
                                   'source/prepared_radial_sweep_transition.d',
                                   'source/prepared_record_context.d',
                                   'source/prepared_rotate_update.d',
                                   'source/prepared_scale_update.d',
                                   'source/prepared_selection_profile.d',
                                   'source/prepared_selection_profile_image.d',
                                   'source/prepared_slice_activation.d',
                                   'source/prepared_slice_deactivate.d',
                                   'source/prepared_smooth_shift_activation.d',
                                   'source/prepared_stroke_extrude_activation.d',
                                   'source/prepared_tack_activation.d',
                                   'source/prepared_tool_transition.d',
                                   'source/prepared_topology_pen_activation.d',
                                   'source/prepared_topology_pen_deactivate.d',
                                   'source/prepared_topology_pen_update.d',
                                   'source/prepared_transform_activation.d',
                                   'source/prepared_transform_product_activation.d',
                                   'source/prepared_vertex_bevel_activation.d',
                                   'source/prepared_vertex_extrude_activation.d',
                                   'source/prepared_vertex_merge_activation.d',
                                   'source/prepared_xfrm_activation_session.d',
                                   'source/prepared_xfrm_refire_state.d',
                                   'source/prepared_xfrm_replay.d',
                                   'source/prepared_xfrm_slot_poll.d',
                                   'source/prepared_xfrm_update_boundary.d',
                                   'source/prepared_xfrm_update_edit_close.d',
                                   'source/prepared_xfrm_update_tail.d',
                                   'source/property_panel.d',
                                   'source/registry.d',
                                   'source/snap_render.d',
                                   'source/tool.d',
                                   'source/tool_attr_bounds.d',
                                   'source/tool_disarm.d',
                                   'source/tool_presets.d',
                                   'source/tools/alignment/array_tool.d',
                                   'source/tools/alignment/clone_tool.d',
                                   'source/tools/alignment/linear_align_tool.d',
                                   'source/tools/alignment/mirror.d',
                                   'source/tools/alignment/radial_align_tool.d',
                                   'source/tools/alignment/radial_array_tool.d',
                                   'source/tools/alignment/radial_sweep_tool.d',
                                   'source/tools/common/command_wrapper.d',
                                   'source/tools/create/arc.d',
                                   'source/tools/create/box.d',
                                   'source/tools/create/capsule.d',
                                   'source/tools/create/cone.d',
                                   'source/tools/create/create_common.d',
                                   'source/tools/create/cylinder.d',
                                   'source/tools/create/pen.d',
                                   'source/tools/create/primitive_create_tool.d',
                                   'source/tools/create/sphere.d',
                                   'source/tools/create/torus.d',
                                   'source/tools/create/tube.d',
                                   'source/tools/create/vertex_place.d',
                                   'source/tools/deform/bend.d',
                                   'source/tools/deform/magnet.d',
                                   'source/tools/deform/push.d',
                                   'source/tools/deform/smooth_shift_tool.d',
                                   'source/tools/deform/stroke_extrude_tool.d',
                                   'source/tools/edit/bridge_tool.d',
                                   'source/tools/edit/edge_bevel.d',
                                   'source/tools/edit/edge_extend.d',
                                   'source/tools/edit/edge_extrude.d',
                                   'source/tools/edit/haul_axis_latch.d',
                                   'source/tools/edit/poly_bevel.d',
                                   'source/tools/edit/poly_extrude.d',
                                   'source/tools/edit/poly_inset_tool.d',
                                   'source/tools/edit/reduce.d',
                                   'source/tools/edit/smooth_relax.d',
                                   'source/tools/edit/tack.d',
                                   'source/tools/edit/topology_pen/defs.d',
                                   'source/tools/edit/topology_pen/json.d',
                                   'source/tools/edit/topology_pen/package.d',
                                   'source/tools/edit/topology_pen/render.d',
                                   'source/tools/edit/topology_pen/snap_guide.d',
                                   'source/tools/edit/topology_pen/tool.d',
                                   'source/tools/edit/vert_merge_tool.d',
                                   'source/tools/edit/vertex_bevel_tool.d',
                                   'source/tools/edit/vertex_extrude_tool.d',
                                   'source/tools/slice/edge_slice_tool.d',
                                   'source/tools/slice/edge_slide.d',
                                   'source/tools/slice/loop_slice_tool.d',
                                   'source/tools/slice/slice_tool.d',
                                   'source/tools/topology_step.d',
                                   'source/tools/transform/move.d',
                                   'source/tools/transform/rotate.d',
                                   'source/tools/transform/scale.d',
                                   'source/tools/transform/transform.d',
                                   'source/tools/transform/xfrm_apply.d',
                                   'source/tools/transform/xfrm_handles.d',
                                   'source/tools/transform/xfrm_item.d',
                                   'source/tools/transform/xfrm_transform.d',
                                   'source/value_drag.d'],
                       'testDigest': 'a947d378a04adce5950bba83e3286e495c36717332d6baf02d927aa17dfe86f6',
                       'testHelpers': ['tests/source/drag_source_helpers.d',
                                       'tests/source/snap_render_source_helpers.d'],
                       'testImports': ['source', '../source'],
                       'testLower': ['alignment-ops',
                                     'application-core',
                                     'camera-model',
                                     'command-runtime',
                                     'creation-ops',
                                     'display-policy',
                                     'document-model',
                                     'edit-contracts',
                                     'editor-commands',
                                     'input-events',
                                     'interaction-data',
                                     'interaction-query',
                                     'log',
                                     'math',
                                     'mesh',
                                     'mesh-change',
                                     'mesh-edit-log',
                                     'mesh-edit-replay',
                                     'mesh-ops',
                                     'mesh-snapshot',
                                     'mesh-topology',
                                     'param-schema',
                                     'pipe-contracts',
                                     'pipe-evaluation',
                                     'pipe-runtime',
                                     'profiling',
                                     'scene-query',
                                     'selection-model',
                                     'spatial',
                                     'subpatch-preview',
                                     'tool-state',
                                     'transform-ops',
                                     'viewport-gpu'],
                       'testSources': ['../../../tests/unit/fixtures.d',
                                       '../../../tests/unit/mesh_by_value_gate.d',
                                       '../source/commands/mesh/smooth.d',
                                       '../source/commands/tool/attr.d',
                                       '../source/commands/tool/begin_session.d',
                                       '../source/commands/tool/bridge_headless.d',
                                       '../source/commands/tool/do_apply.d',
                                       '../source/commands/tool/headless.d',
                                       '../source/commands/tool/host.d',
                                       '../source/commands/tool/lifecycle.d',
                                       '../source/commands/tool/panel_edit.d',
                                       '../source/commands/tool/pipe.d',
                                       '../source/commands/tool/reset.d',
                                       '../source/commands/tool/set.d',
                                       '../source/coord_rounding.d',
                                       '../source/deform_magnet.d',
                                       '../source/drag.d',
                                       '../source/edit_session.d',
                                       '../source/evaluated_move_weld.d',
                                       '../source/falloff_handles.d',
                                       '../source/falloff_render.d',
                                       '../source/gizmo.d',
                                       '../source/handler.d',
                                       '../source/handles/arbiter.d',
                                       '../source/handles/gizmo_metrics.d',
                                       '../source/handles/gl_util.d',
                                       '../source/handles/shapes.d',
                                       '../source/model_preview.d',
                                       '../source/overlay_space.d',
                                       '../source/params_widgets.d',
                                       '../source/pipe_gizmo_host.d',
                                       '../source/prepared_box_param.d',
                                       '../source/prepared_bridge_activation.d',
                                       '../source/prepared_command_wrapper_activation.d',
                                       '../source/prepared_edge_bevel_activation.d',
                                       '../source/prepared_edge_extend_deactivate.d',
                                       '../source/prepared_edge_extend_tool_activation.d',
                                       '../source/prepared_edge_extrude_activation.d',
                                       '../source/prepared_edge_slice_activation.d',
                                       '../source/prepared_edge_slice_deactivate.d',
                                       '../source/prepared_inherited_noop.d',
                                       '../source/prepared_loop_slice_activation.d',
                                       '../source/prepared_loop_slice_deactivate.d',
                                       '../source/prepared_mirror_activation.d',
                                       '../source/prepared_move_update.d',
                                       '../source/prepared_param_update.d',
                                       '../source/prepared_pipe_activation.d',
                                       '../source/prepared_poly_bevel_activation.d',
                                       '../source/prepared_poly_extrude_activation.d',
                                       '../source/prepared_poly_inset_activation.d',
                                       '../source/prepared_private_state.d',
                                       '../source/prepared_radial_array_transition.d',
                                       '../source/prepared_radial_sweep_transition.d',
                                       '../source/prepared_record_context.d',
                                       '../source/prepared_rotate_update.d',
                                       '../source/prepared_scale_update.d',
                                       '../source/prepared_selection_profile.d',
                                       '../source/prepared_selection_profile_image.d',
                                       '../source/prepared_slice_activation.d',
                                       '../source/prepared_slice_deactivate.d',
                                       '../source/prepared_smooth_shift_activation.d',
                                       '../source/prepared_stroke_extrude_activation.d',
                                       '../source/prepared_tack_activation.d',
                                       '../source/prepared_tool_transition.d',
                                       '../source/prepared_topology_pen_activation.d',
                                       '../source/prepared_topology_pen_deactivate.d',
                                       '../source/prepared_topology_pen_update.d',
                                       '../source/prepared_transform_activation.d',
                                       '../source/prepared_transform_product_activation.d',
                                       '../source/prepared_vertex_bevel_activation.d',
                                       '../source/prepared_vertex_extrude_activation.d',
                                       '../source/prepared_vertex_merge_activation.d',
                                       '../source/prepared_xfrm_activation_session.d',
                                       '../source/prepared_xfrm_refire_state.d',
                                       '../source/prepared_xfrm_replay.d',
                                       '../source/prepared_xfrm_slot_poll.d',
                                       '../source/prepared_xfrm_update_boundary.d',
                                       '../source/prepared_xfrm_update_edit_close.d',
                                       '../source/prepared_xfrm_update_tail.d',
                                       '../source/property_panel.d',
                                       '../source/registry.d',
                                       '../source/snap_render.d',
                                       '../source/tool.d',
                                       '../source/tool_attr_bounds.d',
                                       '../source/tool_disarm.d',
                                       '../source/tool_presets.d',
                                       '../source/tools/alignment/array_tool.d',
                                       '../source/tools/alignment/clone_tool.d',
                                       '../source/tools/alignment/linear_align_tool.d',
                                       '../source/tools/alignment/mirror.d',
                                       '../source/tools/alignment/radial_align_tool.d',
                                       '../source/tools/alignment/radial_array_tool.d',
                                       '../source/tools/alignment/radial_sweep_tool.d',
                                       '../source/tools/common/command_wrapper.d',
                                       '../source/tools/create/arc.d',
                                       '../source/tools/create/box.d',
                                       '../source/tools/create/capsule.d',
                                       '../source/tools/create/cone.d',
                                       '../source/tools/create/create_common.d',
                                       '../source/tools/create/cylinder.d',
                                       '../source/tools/create/pen.d',
                                       '../source/tools/create/primitive_create_tool.d',
                                       '../source/tools/create/sphere.d',
                                       '../source/tools/create/torus.d',
                                       '../source/tools/create/tube.d',
                                       '../source/tools/create/vertex_place.d',
                                       '../source/tools/deform/bend.d',
                                       '../source/tools/deform/magnet.d',
                                       '../source/tools/deform/push.d',
                                       '../source/tools/deform/smooth_shift_tool.d',
                                       '../source/tools/deform/stroke_extrude_tool.d',
                                       '../source/tools/edit/bridge_tool.d',
                                       '../source/tools/edit/edge_bevel.d',
                                       '../source/tools/edit/edge_extend.d',
                                       '../source/tools/edit/edge_extrude.d',
                                       '../source/tools/edit/haul_axis_latch.d',
                                       '../source/tools/edit/poly_bevel.d',
                                       '../source/tools/edit/poly_extrude.d',
                                       '../source/tools/edit/poly_inset_tool.d',
                                       '../source/tools/edit/reduce.d',
                                       '../source/tools/edit/smooth_relax.d',
                                       '../source/tools/edit/tack.d',
                                       '../source/tools/edit/topology_pen/defs.d',
                                       '../source/tools/edit/topology_pen/json.d',
                                       '../source/tools/edit/topology_pen/package.d',
                                       '../source/tools/edit/topology_pen/render.d',
                                       '../source/tools/edit/topology_pen/snap_guide.d',
                                       '../source/tools/edit/topology_pen/tool.d',
                                       '../source/tools/edit/vert_merge_tool.d',
                                       '../source/tools/edit/vertex_bevel_tool.d',
                                       '../source/tools/edit/vertex_extrude_tool.d',
                                       '../source/tools/slice/edge_slice_tool.d',
                                       '../source/tools/slice/edge_slide.d',
                                       '../source/tools/slice/loop_slice_tool.d',
                                       '../source/tools/slice/slice_tool.d',
                                       '../source/tools/topology_step.d',
                                       '../source/tools/transform/move.d',
                                       '../source/tools/transform/rotate.d',
                                       '../source/tools/transform/scale.d',
                                       '../source/tools/transform/transform.d',
                                       '../source/tools/transform/xfrm_apply.d',
                                       '../source/tools/transform/xfrm_handles.d',
                                       '../source/tools/transform/xfrm_item.d',
                                       '../source/tools/transform/xfrm_transform.d',
                                       '../source/value_drag.d',
                                       'source/drag_identity.d',
                                       'source/drag_source_cells.d',
                                       'source/drag_source_helpers.d',
                                       'source/handles/arbiter_source_cells.d',
                                       'source/handles/gl_util_source_cells.d',
                                       'source/overlay_space_source_cells.d',
                                       'source/prepared_bridge_activation_source_cells.d',
                                       'source/prepared_command_wrapper_activation_source_cells.d',
                                       'source/prepared_edge_bevel_activation_source_cells.d',
                                       'source/prepared_edge_extend_deactivate_source_cells.d',
                                       'source/prepared_edge_extend_tool_activation_source_cells.d',
                                       'source/prepared_edge_extrude_activation_source_cells.d',
                                       'source/prepared_edge_slice_activation_source_cells.d',
                                       'source/prepared_edge_slice_deactivate_source_cells.d',
                                       'source/prepared_inherited_noop_source_cells.d',
                                       'source/prepared_loop_slice_activation_source_cells.d',
                                       'source/prepared_loop_slice_deactivate_source_cells.d',
                                       'source/prepared_mirror_activation_source_cells.d',
                                       'source/prepared_move_update_source_cells.d',
                                       'source/prepared_pipe_activation_source_cells.d',
                                       'source/prepared_poly_bevel_activation_source_cells.d',
                                       'source/prepared_poly_extrude_activation_source_cells.d',
                                       'source/prepared_poly_inset_activation_source_cells.d',
                                       'source/prepared_private_state_source_cells.d',
                                       'source/prepared_radial_array_transition_source_cells.d',
                                       'source/prepared_radial_sweep_transition_source_cells.d',
                                       'source/prepared_record_context_source_cells.d',
                                       'source/prepared_rotate_update_source_cells.d',
                                       'source/prepared_scale_update_source_cells.d',
                                       'source/prepared_selection_profile_source_cells.d',
                                       'source/prepared_slice_activation_source_cells.d',
                                       'source/prepared_slice_deactivate_source_cells.d',
                                       'source/prepared_smooth_shift_activation_source_cells.d',
                                       'source/prepared_stroke_extrude_activation_source_cells.d',
                                       'source/prepared_tack_activation_source_cells.d',
                                       'source/prepared_topology_pen_activation_source_cells.d',
                                       'source/prepared_topology_pen_deactivate_source_cells.d',
                                       'source/prepared_topology_pen_update_source_cells.d',
                                       'source/prepared_transform_activation_source_cells.d',
                                       'source/prepared_transform_product_activation_source_cells.d',
                                       'source/prepared_vertex_bevel_activation_source_cells.d',
                                       'source/prepared_vertex_extrude_activation_source_cells.d',
                                       'source/prepared_vertex_merge_activation_source_cells.d',
                                       'source/prepared_xfrm_activation_session_source_cells.d',
                                       'source/registry_source_cells.d',
                                       'source/snap_render_source_cells.d',
                                       'source/snap_render_source_helpers.d',
                                       'source/tests/unit/bevel_cold_arm_param_image_test.d',
                                       'source/tests/unit/close_reason_table_test.d',
                                       'source/tests/unit/command_history_test.d',
                                       'source/tests/unit/command_wrapper_result_test.d',
                                       'source/tests/unit/commands/mesh/edge_slide_result_builder_test.d',
                                       'source/tests/unit/commands/mesh/jitter_result_builder_test.d',
                                       'source/tests/unit/constraint_surface_at_test.d',
                                       'source/tests/unit/deform_magnet_test.d',
                                       'source/tests/unit/drag_gain_oblique_test.d',
                                       'source/tests/unit/edge_slice_locate_base_test.d',
                                       'source/tests/unit/edit_session_test.d',
                                       'source/tests/unit/falloff_rmb_discipline_test.d',
                                       'source/tests/unit/gesture_carrier_interface_test.d',
                                       'source/tests/unit/gesture_record_belt_test.d',
                                       'source/tests/unit/handles/gl_util_test.d',
                                       'source/tests/unit/handles/shapes_test.d',
                                       'source/tests/unit/mesh_ops/bridge_frozen_kernel_test.d',
                                       'source/tests/unit/model_preview_test.d',
                                       'source/tests/unit/overlay_space_test.d',
                                       'source/tests/unit/prepared_param_update_test.d',
                                       'source/tests/unit/prepared_tool_transition_test.d',
                                       'source/tests/unit/quad_overlay_eligibility_test.d',
                                       'source/tests/unit/shared_hover_record_test.d',
                                       'source/tests/unit/tool_gesture_runopen_test.d',
                                       'source/tests/unit/tool_single_operation_equivalence_test.d',
                                       'source/tests/unit/toolpipe/local_component_frame_test.d',
                                       'source/tests/unit/tools/alignment/mirror_test.d',
                                       'source/tests/unit/tools/alignment/radial_sweep_tool_test.d',
                                       'source/tests/unit/tools/create/arc_test.d',
                                       'source/tests/unit/tools/create/box_test.d',
                                       'source/tests/unit/tools/create/create_common_test.d',
                                       'source/tests/unit/tools/create/tube_test.d',
                                       'source/tests/unit/tools/edit/preview_topology_churn_test.d',
                                       'source/tests/unit/tools/edit/smooth_relax_test.d',
                                       'source/tests/unit/tools/edit/tack_test.d',
                                       'source/tests/unit/tools/edit/topology_pen/move_protocol_test.d',
                                       'source/tests/unit/tools/edit/topology_pen/press_compatibility_test.d',
                                       'source/tests/unit/tools/slice/edge_slice_tool_test.d',
                                       'source/tests/unit/tools/slice/loop_slice_tool_test.d',
                                       'source/tests/unit/tools/slice/slice_tool_test.d',
                                       'source/tests/unit/tools/transform/move_test.d',
                                       'source/tests/unit/tools/transform/rotate_test.d',
                                       'source/tests/unit/tools/transform/scale_test.d',
                                       'source/tests/unit/tools/transform/transform_test.d',
                                       'source/tests/unit/topology_step_mixin_test.d',
                                       'source/tests/unit/wrapper_shift_apply_inheritance_test.d',
                                       'source/tool_disarm_source_cells.d',
                                       'source/tool_presets_source_cells.d',
                                       'source/tools/create/create_common_source_cells.d',
                                       'source/tools/edit/bridge_tool_source_cells.d',
                                       'source/tools/edit/edge_extend_source_cells.d']},
 'interchange': {'external': {'lwo2-writer': {'repository': 'git+https://github.com/shulc/D-Lwo2Writer.git',
                                              'version': '6d35b70a2a23c16c5b6cc19ea3e2d05a99eb0061'}},
                 'lower': ['document-model', 'log', 'math', 'mesh'],
                 'name': 'vibe3d-interchange',
                 'ordinaryDigest': '4ccb70ce4b0fca3e2f94c8097699a74252def8685a7e379a747525b55cd7c8ec',
                 'root': 'packages/interchange',
                 'sources': ['source/io/assimp_runtime.d',
                             'source/io/assimp_wire.d',
                             'source/io/formats.d',
                             'source/io/lwo_export.d',
                             'source/io/lwo_import.d',
                             'source/io/scene_export.d',
                             'source/io/scene_import.d',
                             'source/io/scene_ir.d'],
                 'testDigest': 'e37812eb0e379f2e10cbc3e80bcc365bd5dea281255bf872e33e853f14595752',
                 'testImports': ['source', '../source'],
                 'testLower': ['document-model', 'log', 'math', 'mesh'],
                 'testSources': ['../source/io/assimp_runtime.d',
                                 '../source/io/assimp_wire.d',
                                 '../source/io/formats.d',
                                 '../source/io/lwo_export.d',
                                 '../source/io/lwo_import.d',
                                 '../source/io/scene_export.d',
                                 '../source/io/scene_import.d',
                                 '../source/io/scene_ir.d',
                                 'source/tests/unit/assimp_wire_test.d',
                                 'source/tests/unit/io/lwo_export_ptag_census_test.d',
                                 'source/tests/unit/io/lwo_export_test.d',
                                 'source/tests/unit/io/lwo_import_test.d',
                                 'source/tests/unit/io/lwo_ptag_fixture.d']},
 'json-number': {'external': {},
                 'lower': [],
                 'name': 'vibe3d:json-number',
                 'ordinaryDigest': 'cbf91cb895c34153325024ace4bfd7302204b4da83ab48fda534631b5307c7ec',
                 'root': 'libraries/util/json-number',
                 'sources': ['source/vibe3d/util/json_number/json_num.d'],
                 'testDigest': 'dcdaf7f586db626d3e1bf916936a64cb3ce9ccabfb3cb776c4bae4f18b7cdb92',
                 'testImports': ['../source', 'source'],
                 'testLower': [],
                 'testSources': ['../source/vibe3d/util/json_number/json_num.d', 'source/vibe3d/util/json_number/tests/unit/json_num_test.d'], 'targetName': 'vibe3d-json-number', 'testName': 'vibe3d-json-number-tests'},
 'log': {'external': {},
         'lower': [],
         'name': 'vibe3d:log',
         'ordinaryDigest': 'aaa77f8bb0c44e63976ead72769bc079aa8bb253cebb784bfe277cd66499bee4',
         'root': 'libraries/util/log',
         'sources': ['source/vibe3d/util/log/log.d'],
         'testDigest': 'd9e9c2b35594ecbff0cbb8cb869c41a31a15aeffea95002c918d632695e921f1',
         'testImports': ['../source', 'source'],
         'testLower': [],
         'testSources': ['../source/vibe3d/util/log/log.d'], 'targetName': 'vibe3d-log', 'testName': 'vibe3d-log-tests'},
 'math': {'external': {},
          'lower': [],
          'name': 'vibe3d:math',
          'testName': 'vibe3d-math-tests',
          'targetName': 'vibe3d-math',
          'ordinaryDigest': 'd83d7a57f0e5ed1d092fea67c4149bbf4df5f12802af9e8a466c1612b9e2f1ea',
          'root': 'libraries/util/math',
          'transitionalSources': ['source/math.d', 'source/math_geometry.d', 'source/math_matrix.d', 'source/math_quaternion.d', 'source/math_vector.d', 'source/vibe3d/util/math/package.d'],
          'sources': ['source/vibe3d/util/math/math.d',
                      'source/vibe3d/util/math/math_geometry.d',
                      'source/vibe3d/util/math/math_matrix.d',
                      'source/vibe3d/util/math/math_quaternion.d',
                      'source/vibe3d/util/math/math_vector.d'],
          'testDigest': '899af459f6a9f6a1491e1558e1a925d7f26f837c0e4d6549efa79909b05014df',
          'testImports': ['../source', 'source'],
          'testLower': [],
          'testSources': ['../source/vibe3d/util/math/math.d',
                          '../source/vibe3d/util/math/math_geometry.d',
                          '../source/vibe3d/util/math/math_matrix.d',
                          '../source/vibe3d/util/math/math_quaternion.d',
                          '../source/vibe3d/util/math/math_vector.d',
                          'source/vibe3d/util/math/tests/unit/math_test.d']},
 'mesh': {'external': {},
          'lower': ['edit-contracts',
                    'math',
                    'mesh-change',
                    'mesh-contracts',
                    'mesh-edit-log',
                    'mesh-topology',
                    'parallel',
                    'profiling',
                    'spatial'],
          'name': 'vibe3d:mesh',
          'ordinaryDigest': 'e9e670307c4935956aead7589a8d661fbf64480dd2efb826261c8693ca31e163',
          'root': 'libraries/mesh/core',
          'sources': ['source/vibe3d/mesh/core/mesh.d',
 'source/vibe3d/mesh/core/mesh_morph.d',
 'source/vibe3d/mesh/core/mesh_planes.d',
 'source/vibe3d/mesh/core/mesh_selsets.d'],
          'testDigest': 'e0b921e1dae0a2291bec87da238cf63df96467fcd1439011c00f518b1eea3950',
          'testImports': ['../source', 'source'],
          'testLower': ['edit-contracts',
                        'math',
                        'mesh-change',
                        'mesh-contracts',
                        'mesh-edit-log',
                        'mesh-topology',
                        'parallel',
                        'profiling',
                        'spatial'],
          'testSources': ['../source/vibe3d/mesh/core/mesh.d',
 '../source/vibe3d/mesh/core/mesh_morph.d',
 '../source/vibe3d/mesh/core/mesh_planes.d',
 '../source/vibe3d/mesh/core/mesh_selsets.d',
 'source/vibe3d/mesh/core/tests/unit/mesh_key_test.d',
 'source/vibe3d/mesh/core/tests/unit/mesh_map_kind_test.d',
 'source/vibe3d/mesh/core/tests/unit/mesh_selsets_test.d',
 'source/vibe3d/mesh/core/tests/unit/mesh_topology_integration_test.d'], 'targetName': 'vibe3d-mesh', 'testName': 'vibe3d-mesh-tests', 'transitionalSources': ['source/vibe3d/mesh/core/package.d']},
 'mesh-change': {'external': {},
                 'lower': ['edit-contracts', 'mesh-contracts'],
                 'name': 'vibe3d:mesh-change',
                 'ordinaryDigest': 'be462747eb38dcb7ce688c9dff65d82acf4adcb14fc2a5b29d34b14cfaae2516',
                 'root': 'libraries/mesh/change',
                 'sources': ['source/vibe3d/mesh/change/change_bus.d', 'source/vibe3d/mesh/change/mesh_dirty.d'],
                 'testDigest': '7b5bb866235320a4eefca32209a82a9e29903595b237d106833040af6153e973',
                 'testImports': ['../source', 'source'],
                 'testLower': ['edit-contracts', 'mesh-contracts'],
                 'testSources': ['../source/vibe3d/mesh/change/change_bus.d', '../source/vibe3d/mesh/change/mesh_dirty.d'], 'targetName': 'vibe3d-mesh-change', 'testName': 'vibe3d-mesh-change-tests'},
 'mesh-contracts': {'external': {},
                    'lower': [],
                    'name': 'vibe3d:mesh-contracts',
                    'ordinaryDigest': '05cc52a431c9b5175d9f95494714a3a9fe69c6ad48e566fc78b8d63baf082c57',
                    'root': 'libraries/mesh/contracts',
                    'sources': ['source/vibe3d/mesh/contracts/mesh_corner_maps.d', 'source/vibe3d/mesh/contracts/mesh_plane_types.d', 'source/vibe3d/mesh/contracts/mesh_scope.d', 'source/vibe3d/mesh/contracts/mesh_types.d'],
                    'testDigest': '8ded9406613eafcde5dd4a3e345b45aaaad1b0aeeeb046ef43f9564aebd950d8',
                    'testImports': ['../source', 'source'],
                    'testLower': [],
                    'testSources': ['../source/vibe3d/mesh/contracts/mesh_corner_maps.d', '../source/vibe3d/mesh/contracts/mesh_plane_types.d', '../source/vibe3d/mesh/contracts/mesh_scope.d', '../source/vibe3d/mesh/contracts/mesh_types.d', 'source/vibe3d/mesh/contracts/tests/unit/mesh_plane_types_test.d'], 'targetName': 'vibe3d-mesh-contracts', 'testName': 'vibe3d-mesh-contracts-tests'},
 'mesh-edit-log': {'external': {},
                   'lower': ['math', 'mesh-change', 'mesh-contracts', 'plane-bytes'],
                   'name': 'vibe3d:mesh-edit-log',
                   'ordinaryDigest': '6108d844585f395d76817e03104474c5e0329e4b47e0bac3d8d72f21aa9b4240',
                   'root': 'libraries/mesh/edit-log',
                   'sources': ['source/vibe3d/mesh/edit_log/mesh_edit_delta.d'],
                   'testDigest': '0679e119c382b73673c8bc485e51001bb4fba5d97196039d11e6356ebd7e0ab2',
                   'testImports': ['../source', 'source'],
                   'testLower': ['math', 'mesh-change', 'mesh-contracts', 'plane-bytes'],
                   'testSources': ['../source/vibe3d/mesh/edit_log/mesh_edit_delta.d',
 'source/vibe3d/mesh/edit_log/mesh_edit_log_protocol_test.d'], 'targetName': 'vibe3d-mesh-edit-log', 'testName': 'vibe3d-mesh-edit-log-tests'},
 'mesh-edit-replay': {'external': {},
                      'lower': ['math', 'mesh', 'mesh-change', 'mesh-contracts', 'mesh-edit-log'],
                      'name': 'vibe3d:mesh-edit-replay',
                      'ordinaryDigest': 'a57323741f0b6486f6bcd30af5f41a7640171f754f93a8b359fc1773a9e17059',
                      'root': 'libraries/mesh/edit-replay',
                      'sources': ['source/vibe3d/mesh/edit_replay/mesh_edit_replay.d'],
                      'testDigest': '8afe9416fe5f88e767dc53e8e8e4593d58db756428eeb8d29a361f93fab012b1',
                      'testImports': ['../source', 'source'],
                      'testLower': ['math', 'mesh', 'mesh-change', 'mesh-contracts', 'mesh-edit-log'],
                      'testSources': ['../source/vibe3d/mesh/edit_replay/mesh_edit_replay.d',
 'source/vibe3d/mesh/edit_replay/mesh_edit_replay_roundtrip_test.d',
 'source/vibe3d/mesh/edit_replay/tests/unit/mesh_edit_delta_test.d',
 'source/vibe3d/mesh/edit_replay/tests/unit/mesh_selsets_replay_test.d'], 'targetName': 'vibe3d-mesh-edit-replay', 'testName': 'vibe3d-mesh-edit-replay-tests'},
 'mesh-ops': {'external': {},
              'lower': ['log', 'math', 'mesh', 'mesh-contracts', 'mesh-topology', 'spatial'],
              'name': 'vibe3d:mesh-ops',
              'ordinaryDigest': '88a7185688eae97ab3f14e40e275fa0109087088fc2bf6a87a233f37737542c6',
              'root': 'libraries/mesh/ops',
              'sources': ['source/vibe3d/mesh/ops/geometry_clipboard.d',
 'source/vibe3d/mesh/ops/mesh_analysis.d',
 'source/vibe3d/mesh/ops/mesh_edge_slice.d',
 'source/vibe3d/mesh/ops/mesh_ops/bevel_curves.d',
 'source/vibe3d/mesh/ops/mesh_ops/bevel_fin.d',
 'source/vibe3d/mesh/ops/mesh_ops/bevel_vertex.d',
 'source/vibe3d/mesh/ops/mesh_ops/box_geom.d',
 'source/vibe3d/mesh/ops/mesh_ops/bridge.d',
 'source/vibe3d/mesh/ops/mesh_ops/bridge_patch.d',
 'source/vibe3d/mesh/ops/mesh_ops/cleanup.d',
 'source/vibe3d/mesh/ops/mesh_ops/connected_mask.d',
 'source/vibe3d/mesh/ops/mesh_ops/cut.d',
 'source/vibe3d/mesh/ops/mesh_ops/decimate.d',
 'source/vibe3d/mesh/ops/mesh_ops/edge_bevel.d',
 'source/vibe3d/mesh/ops/mesh_ops/extrude.d',
 'source/vibe3d/mesh/ops/mesh_ops/face_alignment.d',
 'source/vibe3d/mesh/ops/mesh_ops/face_merge.d',
 'source/vibe3d/mesh/ops/mesh_ops/loop_slice.d',
 'source/vibe3d/mesh/ops/mesh_ops/poly_bevel.d',
 'source/vibe3d/mesh/ops/mesh_ops/revolve.d',
 'source/vibe3d/mesh/ops/mesh_ops/select_loop.d',
 'source/vibe3d/mesh/ops/mesh_ops/thicken.d',
 'source/vibe3d/mesh/ops/mesh_ops/triangulate.d',
 'source/vibe3d/mesh/ops/mesh_stats.d',
 'source/vibe3d/mesh/ops/uv_island.d',
 'source/vibe3d/mesh/ops/uv_project.d',
 'source/vibe3d/mesh/ops/uv_relax.d',
 'source/vibe3d/mesh/ops/uv_transform.d',
 'source/vibe3d/mesh/ops/uv_unwrap.d',
 'source/vibe3d/mesh/ops/uv_weld.d'],
              'testDigest': '9df73fd7bbecc470188cd424c3e00cc2527f14834ee0497834442937a95dbe57',
              'testImports': ['../source', 'source', '../../../..'],
              'testLower': ['log',
                            'math',
                            'mesh',
                            'mesh-contracts',
                            'mesh-edit-replay',
                            'mesh-snapshot',
                            'mesh-topology',
                            'spatial'],
              'testSources': ['../source/vibe3d/mesh/ops/mesh_edge_slice.d',
 '../source/vibe3d/mesh/ops/mesh_ops/bevel_curves.d',
 '../source/vibe3d/mesh/ops/mesh_ops/bevel_fin.d',
 '../source/vibe3d/mesh/ops/mesh_ops/bevel_vertex.d',
 '../source/vibe3d/mesh/ops/mesh_ops/box_geom.d',
 '../source/vibe3d/mesh/ops/mesh_ops/bridge.d',
 '../source/vibe3d/mesh/ops/mesh_ops/bridge_patch.d',
 '../source/vibe3d/mesh/ops/mesh_ops/cleanup.d',
 '../source/vibe3d/mesh/ops/mesh_ops/connected_mask.d',
 '../source/vibe3d/mesh/ops/mesh_ops/cut.d',
 '../source/vibe3d/mesh/ops/mesh_ops/decimate.d',
 '../source/vibe3d/mesh/ops/mesh_ops/edge_bevel.d',
 '../source/vibe3d/mesh/ops/mesh_ops/extrude.d',
 '../source/vibe3d/mesh/ops/mesh_ops/face_alignment.d',
 '../source/vibe3d/mesh/ops/mesh_ops/face_merge.d',
 '../source/vibe3d/mesh/ops/mesh_ops/loop_slice.d',
 '../source/vibe3d/mesh/ops/mesh_ops/poly_bevel.d',
 '../source/vibe3d/mesh/ops/mesh_ops/revolve.d',
 '../source/vibe3d/mesh/ops/mesh_ops/select_loop.d',
 '../source/vibe3d/mesh/ops/mesh_ops/thicken.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/bevel_fin_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/bevel_vertex_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/box_geom_corner_provenance_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/bridge_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/cleanup_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/connected_mask_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/extrude_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/loop_slice_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/poly_bevel_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/revolve_seam_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/revolve_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/select_loop_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/vertex_pos_grid_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/seam_differential.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/edge_fixture.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_edge_slice_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_edge_slice_gate_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/face_alignment_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/face_merge_test.d',
 '../../../../tests/unit/mesh_by_value_gate.d',
 '../source/vibe3d/mesh/ops/mesh_ops/triangulate.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_ops/triangulate_test.d',
 '../../../../tests/unit/fixtures.d',
 '../source/vibe3d/mesh/ops/geometry_clipboard.d',
 '../source/vibe3d/mesh/ops/mesh_analysis.d',
 '../source/vibe3d/mesh/ops/mesh_stats.d',
 '../source/vibe3d/mesh/ops/uv_island.d',
 '../source/vibe3d/mesh/ops/uv_project.d',
 '../source/vibe3d/mesh/ops/uv_relax.d',
 '../source/vibe3d/mesh/ops/uv_transform.d',
 '../source/vibe3d/mesh/ops/uv_unwrap.d',
 '../source/vibe3d/mesh/ops/uv_weld.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_analysis_test.d',
 'source/vibe3d/mesh/ops/tests/unit/mesh_wire_analysis_test.d',
 'source/vibe3d/mesh/ops/tests/unit/uv_island_test.d',
 'source/vibe3d/mesh/ops/tests/unit/uv_project_test.d',
 'source/vibe3d/mesh/ops/tests/unit/uv_relax_test.d',
 'source/vibe3d/mesh/ops/tests/unit/uv_transform_test.d',
 'source/vibe3d/mesh/ops/tests/unit/uv_unwrap_test.d',
 'source/vibe3d/mesh/ops/tests/unit/uv_weld_test.d'], 'targetName': 'vibe3d-mesh-ops', 'testName': 'vibe3d-mesh-ops-tests'},
 'mesh-preview': {'external': {},
                  'lower': ['math', 'mesh', 'mesh-contracts'],
                  'name': 'vibe3d:mesh-preview',
                  'ordinaryDigest': '3a1f16c5f4a8f9e6d431909ae3b7b82bff1aaa3af0cfb1622f356946a405225c',
                  'root': 'libraries/mesh/preview',
                  'sources': ['source/vibe3d/mesh/preview/active_mesh_resolver.d', 'source/vibe3d/mesh/preview/morph_preview.d'],
                  'testDigest': '380e6294baeaefeb58d14a01cac155605d9ec5580f60b452a8cb1f921c5ba1a1',
                  'testImports': ['../source', 'source'],
                  'testLower': ['math', 'mesh', 'mesh-contracts'],
                  'testSources': ['../source/vibe3d/mesh/preview/active_mesh_resolver.d',
 '../source/vibe3d/mesh/preview/morph_preview.d',
 'source/vibe3d/mesh/preview/tests/unit/morph_routing_law_test.d'], 'targetName': 'vibe3d-mesh-preview', 'testName': 'vibe3d-mesh-preview-tests'},
 'mesh-snapshot': {'external': {},
                   'lower': ['math', 'mesh', 'mesh-change', 'plane-bytes', 'profiling'],
                   'name': 'vibe3d:mesh-snapshot',
                   'ordinaryDigest': '1bf34a7767e2acb2579e9c2768bf63c81052aa45c777b2d3008dd873119d5c26',
                   'root': 'libraries/mesh/snapshot',
                   'sources': ['source/vibe3d/mesh/snapshot/snapshot.d'],
                   'testDigest': '40854db03c6ba2e53ac315cee81a7f6634ac86824b9ee6a7707509c6aeb719c9',
                   'testImports': ['../source', 'source'],
                   'testLower': ['math', 'mesh', 'mesh-change', 'plane-bytes', 'profiling'],
                   'testSources': ['../source/vibe3d/mesh/snapshot/snapshot.d',
 'source/vibe3d/mesh/snapshot/tests/unit/mesh_map_kind_snapshot_test.d',
 'source/vibe3d/mesh/snapshot/tests/unit/mesh_selsets_snapshot_test.d',
 'source/vibe3d/mesh/snapshot/tests/unit/mesh_wire_snapshot_test.d',
 'source/vibe3d/mesh/snapshot/tests/unit/snapshot_test.d'], 'targetName': 'vibe3d-mesh-snapshot', 'testName': 'vibe3d-mesh-snapshot-tests'},
 'mesh-topology': {'external': {},
                   'lower': ['log'],
                   'name': 'vibe3d:mesh-topology',
                   'ordinaryDigest': 'd4eb2f5fe7fb97289d5ef049d7f8e9876c53bc1a2de37fffa225300297600c0e',
                   'root': 'libraries/mesh/topology',
                   'sources': ['source/vibe3d/mesh/topology/mesh_topo.d'],
                   'testDigest': 'e58e6bcd8d6c8f116667d583bbb6f53e8703d20b47f3b3c53eec1c545be80b93',
                   'testImports': ['../source', 'source'],
                   'testLower': ['log'],
                   'testSources': ['../source/vibe3d/mesh/topology/mesh_topo.d'], 'targetName': 'vibe3d-mesh-topology', 'testName': 'vibe3d-mesh-topology-tests'},
 'parallel': {'external': {},
              'lower': [],
              'name': 'vibe3d:parallel',
              'ordinaryDigest': 'e7603e92368a66746a8d4902339618c7bd47f6e2d4b116c3d3afecc547840200',
              'root': 'libraries/util/parallel',
              'sources': ['source/vibe3d/util/parallel/tsan_annotate.d'],
              'testDigest': '89c70158debd1ccf45b6fe9f7086237100bfa76388f40ffc71705e89f6d8c5da',
              'testImports': ['../source', 'source'],
              'testLower': [],
              'testSources': ['../source/vibe3d/util/parallel/tsan_annotate.d'], 'targetName': 'vibe3d-parallel', 'testName': 'vibe3d-parallel-tests'},
 'param-schema': {'external': {},
                  'lower': ['math'],
                  'name': 'vibe3d:param-schema',
                  'ordinaryDigest': '21f3e84e68fe40f5936d2d4b8dc6af11ae2b4017598eec6ddfc4a01f0c78aef9',
                  'root': 'libraries/editing/params',
                  'sources': ['source/vibe3d/editing/params/argstring.d', 'source/vibe3d/editing/params/params.d'],
                  'testDigest': 'a661835af8ea2f1f2dbd069942d429cd2062169228ff86cb829e92f921a448d3',
                  'testImports': ['source', '../source'],
                  'testLower': ['math'],
                  'testSources': ['../source/vibe3d/editing/params/argstring.d', '../source/vibe3d/editing/params/params.d', 'source/vibe3d/editing/params/tests/unit/argstring_test.d', 'source/vibe3d/editing/params/tests/unit/param_cast_overflow_test.d', 'source/vibe3d/editing/params/tests/unit/params_test.d'], 'targetName': 'vibe3d-param-schema', 'testName': 'vibe3d-param-schema-tests'},
 'pipe-contracts': {'external': {},
                    'lower': ['edit-contracts', 'math', 'mesh', 'spatial'],
                    'name': 'vibe3d:pipe-contracts',
                    'ordinaryDigest': 'be41243dbdd1df915b910bd16b49a3b352a4e778d40dc7699d40f3ede3eb7fac',
                    'root': 'libraries/editing/pipeline/contracts',
                    'sources': ['source/vibe3d/editing/pipeline/contracts/operator.d',
 'source/vibe3d/editing/pipeline/contracts/toolpipe/packets.d'],
                    'testDigest': '8ee94cdec814de6021a27dc2072af7f21a45bd88ccd232b8ccf7f79b0ba6888e',
                    'testImports': ['../source', 'source'],
                    'testLower': ['edit-contracts', 'math', 'mesh', 'spatial'],
                    'testSources': ['../source/vibe3d/editing/pipeline/contracts/operator.d',
 '../source/vibe3d/editing/pipeline/contracts/toolpipe/packets.d',
 'source/vibe3d/editing/pipeline/contracts/tests/unit/operator_test.d',
 'source/vibe3d/editing/pipeline/contracts/tests/unit/toolpipe/packets_test.d'], 'targetName': 'vibe3d-pipe-contracts', 'testName': 'vibe3d-pipe-contracts-tests'},
 'pipe-evaluation': {'external': {},
                     'lower': ['document-model',
                               'edit-contracts',
                               'interaction-query',
                               'math',
                               'mesh',
                               'mesh-change',
                               'mesh-edit-log',
                               'mesh-preview',
                               'param-schema',
                               'pipe-contracts',
                               'pipe-runtime',
                               'profiling',
                               'spatial'],
                     'name': 'vibe3d-pipe-evaluation',
                     'ordinaryDigest': '83e13429a5dbad9648adc2ed4de1a57c257d012568698d6951b8e6e1b521bc94',
                     'root': 'packages/pipe-evaluation',
                     'sources': ['source/toolpipe/attr_cache.d',
                                 'source/toolpipe/obbox.d',
                                 'source/toolpipe/package.d',
                                 'source/toolpipe/stages/actcenter.d',
                                 'source/toolpipe/stages/axis.d',
                                 'source/toolpipe/stages/constrain.d',
                                 'source/toolpipe/stages/falloff.d',
                                 'source/toolpipe/stages/path.d',
                                 'source/toolpipe/stages/snap.d',
                                 'source/toolpipe/stages/symmetry.d',
                                 'source/toolpipe/stages/workplane.d',
                                 'source/toolpipe/state_paths.d'],
                     'testDigest': '1f433e8a2a7e9eb5269ff9ad149b28ca10c387fb11de2d2bed518d1bd7d0d262',
                     'testImports': ['source', '../source'],
                     'testLower': ['document-model',
                                   'edit-contracts',
                                   'interaction-query',
                                   'math',
                                   'mesh',
                                   'mesh-change',
                                   'mesh-edit-log',
                                   'mesh-preview',
                                   'param-schema',
                                   'pipe-contracts',
                                   'pipe-runtime',
                                   'profiling',
                                   'spatial'],
                     'testSources': ['../source/toolpipe/attr_cache.d',
                                     '../source/toolpipe/obbox.d',
                                     '../source/toolpipe/package.d',
                                     '../source/toolpipe/stages/actcenter.d',
                                     '../source/toolpipe/stages/axis.d',
                                     '../source/toolpipe/stages/constrain.d',
                                     '../source/toolpipe/stages/falloff.d',
                                     '../source/toolpipe/stages/path.d',
                                     '../source/toolpipe/stages/snap.d',
                                     '../source/toolpipe/stages/symmetry.d',
                                     '../source/toolpipe/stages/workplane.d',
                                     '../source/toolpipe/state_paths.d',
                                     'source/tests/unit/toolpipe/obbox_regression_test.d',
                                     'source/tests/unit/toolpipe/obbox_test.d',
                                     'source/tests/unit/toolpipe/pipeline_order_test.d',
                                     'source/tests/unit/toolpipe/prepared_stage_regression_test.d',
                                     'source/tests/unit/toolpipe/snap_stage_regression_test.d',
                                     'source/tests/unit/toolpipe/stages/actcenter_test.d',
                                     'source/tests/unit/toolpipe/stages/axis_test.d',
                                     'source/tests/unit/toolpipe/stages/falloff_test.d',
                                     'source/tests/unit/toolpipe/stages/snap_test.d',
                                     'source/tests/unit/toolpipe/stages/symmetry_test.d',
                                     'source/tests/unit/toolpipe/stages/workplane_test.d',
                                     'source/tests/unit/falloff_screen_default_test.d']},
 'pipe-runtime': {'external': {},
                  'lower': ['edit-contracts',
                            'log',
                            'math',
                            'mesh',
                            'mesh-preview',
                            'param-schema',
                            'pipe-contracts',
                            'profiling',
                            'spatial'],
                  'name': 'vibe3d-pipe-runtime',
                  'ordinaryDigest': 'a2c1e38994448cf4ac1b88562191a0040d05b4139269566585c8f95993929f18',
                  'root': 'packages/pipe-runtime',
                  'sources': ['source/falloff.d',
                              'source/toolpipe/pipeline.d',
                              'source/toolpipe/stage.d',
                              'source/toolpipe/subject.d'],
                  'testDigest': '3631c49a83b1be74c091de3ef7b53dcb23177d2171c0094225427e451f9c2f6e',
                  'testImports': ['source', '../source'],
                  'testLower': ['edit-contracts',
                                'log',
                                'math',
                                'mesh',
                                'mesh-preview',
                                'param-schema',
                                'pipe-contracts',
                                'profiling',
                                'spatial'],
                  'testSources': ['../source/falloff.d',
                                  '../source/toolpipe/pipeline.d',
                                  '../source/toolpipe/stage.d',
                                  '../source/toolpipe/subject.d',
                                  'source/tests/unit/falloff_selection_bake_test.d',
                                  'source/tests/unit/falloff_test.d',
                                  'source/tests/unit/toolpipe/pipeline_registration_test.d',
                                  'source/tests/unit/toolpipe/required_packets_witness_test.d',
                                  'source/tests/unit/toolpipe/stage_test.d',
                                  'source/tests/unit/toolpipe/view_only_subject_pin_test.d']},
 'plane-bytes': {'external': {},
                 'lower': [],
                 'name': 'vibe3d:plane-bytes',
                 'ordinaryDigest': '8b20a9ed86164c9f865ce2ff33daec9a69715bce865d588786e1dea2ed194805',
                 'root': 'libraries/util/plane-bytes',
                 'sources': ['source/vibe3d/util/plane_bytes/plane_bytes.d'],
                 'testDigest': 'e0a40fdd9d6b0f3d3b6a04c1ab257b310e0597c50f0f731a9e775698907d2e96',
                 'testImports': ['../source', 'source'],
                 'testLower': [],
                 'testSources': ['../source/vibe3d/util/plane_bytes/plane_bytes.d'], 'targetName': 'vibe3d-plane-bytes', 'testName': 'vibe3d-plane-bytes-tests'},
 'profiling': {'external': {},
               'lower': [],
               'name': 'vibe3d:profiling',
               'ordinaryDigest': 'd80e3d034a21ded57663f2572b70304b93ffcd327cd83734dc1865eea97504bf',
               'root': 'libraries/util/profiling',
               'sources': ['source/vibe3d/util/profiling/perf_probe.d'],
               'testDigest': '8627098f7d0be065d64d02088e0bffd4419b4153b1650a72b1806b9717c00a7f',
               'testImports': ['../source', 'source'],
               'testLower': [],
               'testSources': ['../source/vibe3d/util/profiling/perf_probe.d'], 'targetName': 'vibe3d-profiling', 'testName': 'vibe3d-profiling-tests'},
 'scene-query': {'external': {'d-bvh': {'repository': 'git+https://github.com/shulc/D-BVH.git',
                                        'version': 'e1a8f41501f94a28dbac99efbea850ed098fa728'}},
                 'lower': ['edit-contracts',
                           'interaction-query',
                           'math',
                           'mesh',
                           'mesh-preview',
                           'pipe-contracts',
                           'pipe-evaluation',
                           'pipe-runtime',
                           'profiling',
                           'spatial',
                           'viewport-gpu'],
                 'name': 'vibe3d-scene-query',
                 'ordinaryDigest': '34797e3bf16de70589f27f01d0ee55e124c50b2fd431bb17a703d8a8591fccc4',
                 'root': 'packages/scene-query',
                 'sources': ['source/bvh_pick.d', 'source/symmetry_pick.d'],
                 'testDigest': '71364ea8b4ee237cf80eb6601e525013de6535d2f5ed2cbcff434d5ba9e35067',
                 'testImports': ['../source', 'source'],
                 'testLower': ['edit-contracts',
                               'interaction-query',
                               'math',
                               'mesh',
                               'mesh-preview',
                               'pipe-contracts',
                               'pipe-evaluation',
                               'pipe-runtime',
                               'profiling',
                               'spatial',
                               'viewport-gpu'],
                 'testSources': ['../source/bvh_pick.d',
                                 '../source/symmetry_pick.d',
                                 'source/tests/unit/bvh_pick_test.d',
                                 'source/tests/unit/scene_query_population_test.d']},
 'screen-buckets': {'external': {},
                    'lower': [],
                    'name': 'vibe3d:screen-buckets',
                    'ordinaryDigest': 'd103579c49c858b28b5e76f268b4f3bdf5d1816a48a4576e5d9a75f6ffdd8b6d',
                    'root': 'libraries/util/screen-buckets',
                    'sources': ['source/vibe3d/util/screen_buckets/screen_buckets.d'],
                    'testDigest': '5cc4734c9449b5f88ca31e5d8dcac5d152c299e6da9b9d4a4fcf8451e7d94831',
                    'testImports': ['../source', 'source'],
                    'testLower': [],
                    'testSources': ['../source/vibe3d/util/screen_buckets/screen_buckets.d'], 'targetName': 'vibe3d-screen-buckets', 'testName': 'vibe3d-screen-buckets-tests'},
 'selection-model': {'external': {},
                     'lower': ['document-model', 'edit-contracts', 'mesh'],
                     'name': 'vibe3d-selection-model',
                     'ordinaryDigest': '37b8d3cabfe2cef31b273c7d19c86222ea8da75904c0911e9e6cfe1c5fb6bd86',
                     'root': 'packages/selection-model',
                     'sources': ['source/selection_product.d', 'source/selection_projection.d'],
                     'testDigest': 'e6e2719a8ee9e902ed071f5c973a19e0567736711e46abf55c0c17f4cd6663d1',
                     'testImports': ['../source', 'source'],
                     'testLower': ['document-model', 'edit-contracts', 'math', 'mesh', 'subpatch-preview'],
                     'testSources': ['../source/selection_product.d',
                                     '../source/selection_projection.d',
                                     'source/tests/unit/selection_product_source_public_test.d',
                                     'source/tests/unit/selection_projection_algorithm_cells_test.d',
                                     'source/tests/unit/selection_model_population_test.d']},
 'spatial': {'external': {},
             'lower': ['math'],
             'name': 'vibe3d:spatial',
             'ordinaryDigest': '9786ad51706bf809de9589c7a82947309325192700146f6095c0562081e2efb5',
             'root': 'libraries/util/spatial',
             'sources': ['source/vibe3d/util/spatial/item_xform.d', 'source/vibe3d/util/spatial/spatial.d', 'source/vibe3d/util/spatial/symmetry_plane.d', 'source/vibe3d/util/spatial/trackball.d', 'source/vibe3d/util/spatial/workplane_basis.d'],
             'testDigest': '41929af48d48d3967a60b31b3428ab0acd847aee6aa58ff7f566b5ec7d6a8295',
             'testImports': ['../source', 'source'],
             'testLower': ['math'],
             'testSources': ['../source/vibe3d/util/spatial/item_xform.d', '../source/vibe3d/util/spatial/spatial.d', '../source/vibe3d/util/spatial/symmetry_plane.d', '../source/vibe3d/util/spatial/trackball.d', '../source/vibe3d/util/spatial/workplane_basis.d', 'source/vibe3d/util/spatial/tests/unit/spatial_test.d'], 'targetName': 'vibe3d-spatial', 'testName': 'vibe3d-spatial-tests'},
 'subpatch-preview': {'external': {'bindbc-opengl': '~>1.1.1',
                                   'd-opensubdiv': {'repository': 'git+https://github.com/shulc/D-OpenSubdiv.git',
                                                    'version': 'e74bb683d869d31ddcb279b2f05bfaebd53065ee'}},
                      'lower': ['display-policy',
                                'interaction-query',
                                'log',
                                'math',
                                'mesh',
                                'mesh-change',
                                'profiling',
                                'viewport-gpu'],
                      'name': 'vibe3d-subpatch-preview',
                      'ordinaryDigest': '7a8594a84b64d7e61d4fee9b2a9c41eee9625f6332af71ab8a760577a70e1778',
                      'root': 'packages/subpatch-preview',
                      'sources': ['source/subpatch_factories.d',
                                  'source/subpatch_osd.d',
                                  'source/subpatch_preview.d',
                                  'source/subpatch_worker.d',
                                  'source/subpatch_worker_web.d'],
                      'testDigest': '562fc625e1afcdda2872b835122b62a68fc680d2e841d28218d19ce4c56d7c48',
                      'testImports': ['source', '../source'],
                      'testLower': ['display-policy',
                                    'edit-contracts',
                                    'interaction-query',
                                    'log',
                                    'math',
                                    'mesh',
                                    'mesh-change',
                                    'mesh-edit-log',
                                    'mesh-edit-replay',
                                    'mesh-snapshot',
                                    'profiling',
                                    'spatial',
                                    'viewport-gpu'],
                      'testSources': ['../source/subpatch_factories.d',
                                      '../source/subpatch_osd.d',
                                      '../source/subpatch_preview.d',
                                      '../source/subpatch_worker.d',
                                      '../source/subpatch_worker_web.d',
                                      'source/tests/unit/subpatch_key_fold_test.d',
                                      'source/tests/unit/subpatch_level_policy_test.d',
                                      'source/tests/unit/subpatch_osd_test.d',
                                      'source/tests/unit/subpatch_preview_population_test.d']},
 'tool-state': {'external': {},
                'lower': ['mesh', 'mesh-snapshot'],
                'name': 'vibe3d-tool-state',
                'ordinaryDigest': '98d62e4e85aeb6b375a7b59aa2fe41f8061d2fb1d0c88fe2aa35a4a4f238f087',
                'root': 'packages/tool-state',
                'sources': ['source/tools/common/session_mesh_key.d', 'source/tools/edit/preview_rebuild.d'],
                'testDigest': '94854e7e585e4b3569071c240914f3c6c8c48dad570b64d7961807e5c9710850',
                'testImports': ['source', '../source'],
                'testLower': ['math', 'mesh', 'mesh-edit-log', 'mesh-snapshot'],
                'testSources': ['../source/tools/common/session_mesh_key.d',
                                '../source/tools/edit/preview_rebuild.d',
                                'source/tests/unit/session_mesh_key_stamp_as_test.d',
                                'source/tests/unit/tool_state_population_test.d',
                                'source/tests/unit/tools/common/session_mesh_key_test.d',
                                'source/tests/unit/tools/edit/preview_rebuild_test.d']},
 'transform-ops': {'external': {},
                   'lower': ['document-model',
                             'interaction-query',
                             'math',
                             'mesh',
                             'mesh-edit-log',
                             'pipe-contracts',
                             'pipe-runtime',
                             'profiling',
                             'spatial'],
                   'name': 'vibe3d-transform-ops',
                   'ordinaryDigest': '8a4b6174e82a64b20a6ec75f658ccaff29fdba0b0d48217306b5b81f0123f06c',
                   'root': 'packages/transform-ops',
                   'sources': ['source/tools/transform/arcball.d',
                               'source/tools/transform/cluster_values.d',
                               'source/tools/transform/item_xform_kernels.d',
                               'source/tools/transform/morph_route.d',
                               'source/tools/transform/relocate_plane.d',
                               'source/tools/transform/scale_input.d',
                               'source/tools/transform/xform_kernels.d'],
                   'testDigest': 'e0582f0cfaea269a0c6c460ea6e3baf6d2070d905669bc690cc031212a1c2fb0',
                   'testImports': ['source', '../source'],
                   'testLower': ['document-model',
                                 'interaction-query',
                                 'math',
                                 'mesh',
                                 'mesh-edit-log',
                                 'pipe-contracts',
                                 'pipe-runtime',
                                 'profiling',
                                 'spatial'],
                   'testSources': ['../source/tools/transform/arcball.d',
                                   '../source/tools/transform/cluster_values.d',
                                   '../source/tools/transform/item_xform_kernels.d',
                                   '../source/tools/transform/morph_route.d',
                                   '../source/tools/transform/relocate_plane.d',
                                   '../source/tools/transform/scale_input.d',
                                   '../source/tools/transform/xform_kernels.d',
                                   'source/tests/unit/ortho_relocate_prior_test.d',
                                   'source/tests/unit/tools/transform/arcball_regression_test.d',
                                   'source/tests/unit/tools/transform/arcball_test.d',
                                   'source/tests/unit/tools/transform/item_xform_kernels_test.d',
                                   'source/tests/unit/tools/transform/item_xform_regression_test.d',
                                   'source/tests/unit/tools/transform/morph_route_test.d',
                                   'source/tests/unit/tools/transform/scale_input_test.d',
                                   'source/tests/unit/tools/transform/transform_ops_population_test.d',
                                   'source/tests/unit/tools/transform/xform_kernels_test.d',
                                   'source/tools/transform/relocate_plane_test.d']},
 'viewport-gpu': {'external': {'bindbc-opengl': '~>1.1.1'},
                  'lower': ['camera-model',
                            'display-policy',
                            'image-codec',
                            'math',
                            'mesh',
                            'mesh-change',
                            'mesh-preview',
                            'profiling',
                            'spatial'],
                  'name': 'vibe3d-viewport-gpu',
                  'ordinaryDigest': '6eeb3e3fc185ea4b1758f348de3d71bbe16697e7075d28912431702f1943f58d',
                  'root': 'packages/viewport-gpu',
                  'sources': ['source/display_sync.d',
                              'source/gl_thread_guard.d',
                              'source/gpu_pass_timer.d',
                              'source/gpu_select.d',
                              'source/mesh_gpu.d',
                              'source/shader.d',
                              'source/viewport_env.d'],
                  'testDigest': '5a6048378cbff9e8bf123fa2e12ceb9bc948cc02e00c420268a176dea1f1d2e1',
                  'testImports': ['source', '../source'],
                  'testLower': ['camera-model',
                                'display-policy',
                                'edit-contracts',
                                'image-codec',
                                'log',
                                'math',
                                'mesh',
                                'mesh-change',
                                'mesh-edit-log',
                                'mesh-edit-replay',
                                'mesh-preview',
                                'mesh-snapshot',
                                'profiling',
                                'spatial'],
                  'testSources': ['../source/display_sync.d',
                                  '../source/gl_thread_guard.d',
                                  '../source/gpu_pass_timer.d',
                                  '../source/gpu_select.d',
                                  '../source/mesh_gpu.d',
                                  '../source/shader.d',
                                  '../source/viewport_env.d',
                                  'source/tests/unit/viewport_env_test.d',
                                  'source/tests/unit/viewport_gpu_population_test.d']},
 'viewport-host': {'external': {'bindbc-opengl': '~>1.1.1'},
                   'lower': ['application-core',
                             'camera-model',
                             'display-policy',
                             'document-io',
                             'document-model',
                             'image-codec',
                             'log',
                             'math',
                             'mesh',
                             'mesh-change',
                             'pipe-contracts',
                             'spatial',
                             'viewport-gpu'],
                   'name': 'vibe3d-viewport-host',
                   'ordinaryDigest': '53d43a6f015ba03b9d0275f6385358c3bbc66f4d39b714c169f664ff6827f7f7',
                   'root': 'packages/viewport-host',
                   'sources': ['source/bg_gpu_cache.d',
                               'source/image_cache.d',
                               'source/image_plane.d',
                               'source/viewport.d',
                               'source/viewport_composite.d'],
                   'testDigest': '2301762daba589967c40841ffe781050cb5bbf1f03d5bf1453d817080e4640e4',
                   'testHelpers': ['tests/source/image_plane_source_cells.d'],
                   'testImports': ['source', '../source'],
                   'testLower': ['application-core',
                                 'camera-model',
                                 'display-policy',
                                 'document-io',
                                 'document-model',
                                 'image-codec',
                                 'interactive-tools',
                                 'log',
                                 'math',
                                 'mesh',
                                 'mesh-change',
                                 'pipe-contracts',
                                 'pipe-evaluation',
                                 'spatial',
                                 'viewport-gpu'],
                   'testSources': ['../source/bg_gpu_cache.d',
                                   '../source/image_cache.d',
                                   '../source/image_plane.d',
                                   '../source/viewport.d',
                                   '../source/viewport_composite.d',
                                   'source/image_plane_source_cells.d',
                                   'source/tests/unit/camera_intrinsics_test.d',
                                   'source/tests/unit/dirty_key_camera_stamp_test.d',
                                   'source/tests/unit/dirty_key_tool_preview_test.d',
                                   'source/tests/unit/dirty_key_weightmap_test.d',
                                   'source/tests/unit/image_cache_test.d',
                                   'source/tests/unit/image_plane_test.d',
                                   'source/tests/unit/viewport_plane_turn_test.d',
                                   'source/tests/unit/viewport_test.d']}}

# Task 20262890: independent approved owner inputs, separate from legacy controls.
SPECS.update({'ai-advisor': {'external': {},
                'lower': ['interaction-data', 'math', 'mesh', 'mesh-ops', 'pipe-evaluation'],
                'name': 'vibe3d-ai-advisor',
                'ordinaryDigest': '5e3dff450174a60c915b986796403c6c3ab93ce550177118c4cd030a5276b413',
                'root': 'packages/ai-advisor',
                'sources': ['source/ai/analysis.d',
                            'source/ai/copilot_gate.d',
                            'source/ai/element_candidates.d',
                            'source/ai/exploration.d',
                            'source/ai/interaction_log.d',
                            'source/ai/interaction_log_writer.d',
                            'source/ai/mode_candidates.d',
                            'source/ai/model_adapter.d',
                            'source/ai/offline_evaluator.d',
                            'source/ai/onnx_backend.d',
                            'source/ai/ranker_schema.d',
                            'source/ai/state.d',
                            'source/ai/support_loop_candidates.d',
                            'source/ai/synthetic_dataset.d',
                            'source/ai/training_dataset.d'],
                'testDigest': '8da2a80a2d60f4456a2fab6170756d131ce0eec6b44edeb4a5be1b711e1683ef',
                'testImports': ['source', '../source'],
                'testLower': ['interaction-data', 'math', 'mesh', 'mesh-ops', 'pipe-evaluation'],
                'testSources': ['../source/ai/analysis.d',
                                '../source/ai/copilot_gate.d',
                                '../source/ai/element_candidates.d',
                                '../source/ai/exploration.d',
                                '../source/ai/interaction_log.d',
                                '../source/ai/interaction_log_writer.d',
                                '../source/ai/mode_candidates.d',
                                '../source/ai/model_adapter.d',
                                '../source/ai/offline_evaluator.d',
                                '../source/ai/onnx_backend.d',
                                '../source/ai/ranker_schema.d',
                                '../source/ai/state.d',
                                '../source/ai/support_loop_candidates.d',
                                '../source/ai/synthetic_dataset.d',
                                '../source/ai/training_dataset.d',
                                'source/tests/unit/ai/analysis_test.d',
                                'source/tests/unit/ai/element_candidates_test.d',
                                'source/tests/unit/ai/exploration_source_public_test.d',
                                'source/tests/unit/ai/exploration_test.d',
                                'source/tests/unit/ai/interaction_log_test.d',
                                'source/tests/unit/ai/interaction_log_writer_test.d',
                                'source/tests/unit/ai/mode_candidates_test.d',
                                'source/tests/unit/ai/model_adapter_test.d',
                                'source/tests/unit/ai/ranker_schema_test.d',
                                'source/tests/unit/ai/support_loop_candidates_test.d',
                                'source/tests/unit/ai/training_dataset_test.d']},
 'ai3d-runtime': {'external': {},
                  'lower': ['interchange', 'log'],
                  'name': 'vibe3d-ai3d-runtime',
                  'ordinaryDigest': '1a39143dfc39788b06c4eb498abe145cdb57795a3fe7462d51567323b8b12d0b',
                  'root': 'packages/ai3d-runtime',
                  'sources': ['source/ai3d/event_queue.d',
                              'source/ai3d/job_controller.d',
                              'source/ai3d/job_events.d',
                              'source/ai3d/scene_validator.d',
                              'source/ai3d/stage_artifact.d',
                              'source/ai3d/worker_manager.d'],
                  'testDigest': '9f5724ebf55a2dd02a89a0ccbec764b0767b44121e88a07a5266b7c7ab448061',
                  'testImports': ['source', '../source'],
                  'testLower': ['interchange', 'log'],
                  'testSources': ['../source/ai3d/event_queue.d',
                                  '../source/ai3d/job_controller.d',
                                  '../source/ai3d/job_events.d',
                                  '../source/ai3d/scene_validator.d',
                                  '../source/ai3d/stage_artifact.d',
                                  '../source/ai3d/worker_manager.d',
                                  'source/tests/unit/ai3d/event_queue_source_public_test.d',
                                  'source/tests/unit/ai3d/event_queue_test.d',
                                  'source/tests/unit/ai3d/job_controller_test.d',
                                  'source/tests/unit/ai3d/scene_validator_test.d',
                                  'source/tests/unit/ai3d/stage_artifact_test.d',
                                  'source/tests/unit/ai3d/worker_manager_source_public_test.d',
                                  'source/tests/unit/ai3d/worker_manager_test.d']},
 'document-actions': {'external': {},
                      'lower': ['application-core',
                                'camera-model',
                                'command-runtime',
                                'document-channels',
                                'document-io',
                                'document-model',
                                'edit-contracts',
                                'interactive-tools',
                                'interchange',
                                'log',
                                'math',
                                'mesh',
                                'mesh-change',
                                'mesh-ops',
                                'mesh-snapshot',
                                'param-schema',
                                'pipe-runtime',
                                'platform-file',
                                'subpatch-preview',
                                'viewport-host'],
                      'name': 'vibe3d-document-actions',
                      'ordinaryDigest': 'd6765a3be5fccb2d8d7a3f534c1b9740f83bcb48f5cb527b4ca52f83034b7527',
                      'root': 'packages/document-actions',
                      'sources': ['source/commands/file/quit.d',
                                  'source/commands/image/commands.d',
                                  'source/commands/image_plane/commands.d',
                                  'source/commands/layer/commands.d',
                                  'source/commands/scene/load_mesh.d',
                                  'source/commands/scene/reset.d'],
                      'testDigest': 'b48164de363ce09acedfd182ca2345d6ac0d75547c5333dc8fb376b2111a67ad',
                      'testImports': ['source', '../source'],
                      'testLower': ['application-core',
                                    'camera-model',
                                    'command-runtime',
                                    'document-channels',
                                    'document-io',
                                    'document-model',
                                    'edit-contracts',
                                    'interactive-tools',
                                    'interchange',
                                    'log',
                                    'math',
                                    'mesh',
                                    'mesh-change',
                                    'mesh-ops',
                                    'mesh-snapshot',
                                    'param-schema',
                                    'pipe-runtime',
                                    'platform-file',
                                    'subpatch-preview',
                                    'viewport-host'],
                      'testSources': ['../source/commands/file/quit.d',
                                      '../source/commands/image/commands.d',
                                      '../source/commands/image_plane/commands.d',
                                      '../source/commands/layer/commands.d',
                                      '../source/commands/scene/load_mesh.d',
                                      '../source/commands/scene/reset.d',
                                      'source/tests/unit/commands/image/commands_test.d',
                                      'source/tests/unit/commands/layer/add_injection_range_test.d',
                                      'source/tests/unit/commands/layer/commands_source_public_test.d']},
 'http-runtime': {'external': {},
                  'lower': ['application-core',
                            'edit-contracts',
                            'input-events',
                            'interaction-query',
                            'log',
                            'mesh',
                            'mesh-change',
                            'param-schema',
                            'pipe-evaluation',
                            'profiling'],
                  'name': 'vibe3d-http-runtime',
                  'ordinaryDigest': '05d427da4f1979b8ef677453ea7e4b27824cbc80a7b69d005fec6aed34d35cfd',
                  'root': 'packages/http-runtime',
                  'sources': ['source/http_server.d',
                              'source/http_transport.d',
                              'source/playback_controller.d'],
                  'testDigest': '52def889ae0a2a0d6b89cf72aa5a2722ef106c0d21bae572719cef62b91c5b1f',
                  'testImports': ['source', '../source'],
                  'testLower': ['application-core',
                                'edit-contracts',
                                'input-events',
                                'interaction-query',
                                'log',
                                'mesh',
                                'mesh-change',
                                'param-schema',
                                'pipe-evaluation',
                                'profiling'],
                  'testSources': ['../source/http_server.d',
                                  '../source/http_transport.d',
                                  '../source/playback_controller.d']},
 'platform-file': {'external': {},
                   'lower': ['application-core',
                             'command-runtime',
                             'document-io',
                             'edit-contracts',
                             'interchange',
                             'mesh'],
                   'name': 'vibe3d-platform-file',
                   'ordinaryDigest': '3b1563b1ff7b84bd1377c71042486a8c271a911114dd1766bfd807a4acc9157f',
                   'root': 'packages/platform-file',
                   'sources': ['source/io/browser_pick_resume.d',
                               'source/io/file_dialog.d',
                               'source/io/file_dialog_browser.d',
                               'source/ui/discard_guard.d'],
                   'testDigest': '9889c504b781c8ccc850724bea3425ce09ab37e81163a51c8b92929f8ae69f2d',
                   'testImports': ['source', '../source'],
                   'testLower': ['application-core',
                                 'command-runtime',
                                 'document-io',
                                 'edit-contracts',
                                 'interchange',
                                 'mesh'],
                   'testSources': ['../source/io/browser_pick_resume.d',
                                   '../source/io/file_dialog.d',
                                   '../source/io/file_dialog_browser.d',
                                   '../source/ui/discard_guard.d']},
 'remesh-runtime': {'external': {},
                    'lower': ['math', 'mesh', 'mesh-change'],
                    'name': 'vibe3d-remesh-runtime',
                    'ordinaryDigest': 'df823f26c00fb39de44ae637b3f4103b6ae137db043340b263765c90733e7bbe',
                    'root': 'packages/remesh-runtime',
                    'sources': ['source/remesh/region_stitch.d', 'source/remesh/remesh_job.d'],
                    'testDigest': '5a46e133b9f5c87ef6cca1a38ba797af66f348687a33f956a581b3e285fbab28',
                    'testImports': ['source', '../source'],
                    'testLower': ['math', 'mesh', 'mesh-change'],
                    'testSources': ['../source/remesh/region_stitch.d',
                                    '../source/remesh/remesh_job.d',
                                    'source/tests/unit/remesh/remesh_job_source_public_test.d',
                                    'source/tests/unit/remesh/remesh_job_test.d']}})
SPECS['interactive-tools']['sources'] = sorted(SPECS['interactive-tools']['sources'] + ['source/commands/falloff.d'])
SPECS['interactive-tools']['testSources'] = sorted(SPECS['interactive-tools']['testSources'] + ['../source/commands/falloff.d'])
SPECS['interactive-tools']['testDigest'] = 'a947d378a04adce5950bba83e3286e495c36717332d6baf02d927aa17dfe86f6'
CONFIGS = ('modeling', 'modeling-noai', 'with-render', 'web', 'root-tests', 'isolated-tests')
FORBIDDEN_IMPORTS = {'interactive-tools': ('editor_app', 'viewport'),
                     'viewport-host': ('tool', 'editor_app'),
                     'interaction-data': ('mesh', 'command')}

HOOKS = ('preGenerateCommands', 'postGenerateCommands', 'preBuildCommands',
         'postBuildCommands', 'preRunCommands', 'postRunCommands')
FIXTURES = {'input-events': ('config/shortcuts.yaml', '99c14eaa556d365f42ead60e30db9aa926723b0ee0a9b1ae4f823542a10fbff8'),
            'display-policy': ('tests/fixtures/retopology_display.json', '7d5d2aba420e1e6927ebd72b9a29bd47503e6958c5413e54de2f6aeb0c78f808'),
            'viewport-gpu': ('assets/icon/png/vibe3d_16.png', '2efe412bb268afa882bbde043473c4e3990302ef76899938914b3e525ce7817e'),
            'mesh-preview': ('tests/fixtures/morph_routing_laws.json', '9067efdbbeac2c37f72f365648e49ecf9fea1ded0d0dcf3bb4c65ecdcd06356c'),
            'pipe-runtime': ('tests/fixtures/falloff_selection_bake.json', '336f6524a11ecd585a525522467c3db1d2dca251da69ffb73cbeaad592d63404')}

# Wave15: six immutable algorithm fixture inputs, staged individually.
PACKAGE_FIXTURES = {'interactive-tools': [('tests/fixtures/change_publish_on_accepted_noop.json', 'd69fde079c31778954e4014b221e28e3ccf02af2a30c0b821e9f45a5a6fe6813'), ('tests/fixtures/topology_pen_session_rig.v3d', '53afa0fadeeb99ab164e8ee8b5e116b9fd9631f3e139ecd1fb09033847683311'), ('tests/fixtures/bridge_auto_connection/frozen.json', '6394cd619a5ce2e4ed2a3aa7dc84198f8470197608c1676381102e8c4c9e3a68'), ('tests/fixtures/bridge_auto_connection/ours_smooth_expected.json', '84ceb9b56f861a43c94861a1ffeb6b7195ef7ff6da97aeb3f2bfef2cd77a08cd'), ('tests/fixtures/local_component_frame/captured.json', '9c95c8bc9836c575106872cdfc87eb76ab26770bb11b6bb4fc74d5dd312450a9'), ('tests/fixtures/drag_gain_oblique.json', '58a777c21a273dc1f75a4e3e1a8a7efaf2a114934d546b7a1abc78eb42275c43')], 'ai3d-runtime': [('tools/ai3d_worker/install_linux.sh', '6ab2d60a820c2b46f2d0f94199cdecb73004092e3b3a151aa17901975db09713'), ('tools/ai3d_worker/install_windows.ps1', 'a13dc1a3faabf9629bb1db22a50f392722aadbbd8dd4741ba13978d456b7541f'), ('tools/ai3d_worker/vibe3d_ai3d_worker/__init__.py', '16057b6f5a8e952a614a9aa43f9afef13b764c678faed3afec924ff42a2b6ac5'), ('tools/ai3d_worker/vibe3d_ai3d_worker/__main__.py', '2065c1f723883a5304abc8926e22e9c0ef9ccb83a94f29b702f579aa8b46b708'), ('tools/ai3d_worker/vibe3d_ai3d_worker/protocol.py', 'f6086b79d1a532ab82b28b1df18a80e065ec3b5093ab37159a39e0f5fc7bc696'), ('tools/ai3d_worker/vibe3d_ai3d_worker/server.py', '34912bf03ebe97fce0c5f5d1501b7cf673b5f45faf959af3bcdeda29021a06d4')]}

# Existing external predicates retain exact changed native owner inputs.
NFDE_DESCRIPTOR_DIGEST = 'baefc968f7db59f16b6d78f26104eca31f6b36d4be5a3cf074a4cefeaca9561d'
ONNX_DESCRIPTOR_DIGEST = 'b14033af05e4a00bb23fdaf69a8f224f5950fba8b9c16e8a3ddb401492ff2ac3'
REVISIONS = dict(legacy_REVISIONS, **{
    'd-onnxruntime': ('3603828c1f5a6cd36817492252e1efb9c81e7ca4', 'git+https://github.com/shulc/D-OnnxRuntime.git'),
    'd_imgui': ('d535ba78c7d01aca3c9d45ca94ea8e55455ffb7f', 'git+https://github.com/shulc/D-ImGui.git'),
    'd-bvh': ('e1a8f41501f94a28dbac99efbea850ed098fa728', 'git+https://github.com/shulc/D-BVH.git'),
    'lwo2-writer': ('6d35b70a2a23c16c5b6cc19ea3e2d05a99eb0061', 'git+https://github.com/shulc/D-Lwo2Writer.git'),
    'bindbc-assimp6': ('3b7c87431b12418a32e70cb065fc63fd6cc98b13', 'git+https://github.com/shulc/D-BindBC-Assimp.git'),
})
EXTERNAL_DEPS = dict(legacy_EXTERNAL_DEPS, **{'nfde': (), 'd-onnxruntime': (), 'd_imgui': ('bindbc-sdl',), 'd-bvh': (), 'lwo2-writer': (),
    'bindbc-assimp6': ('bindbc-common', 'bindbc-loader')})
ARCHIVES = dict(legacy_ARCHIVES, **{'nfde': 'bin/libnfde.a', 'd-onnxruntime': 'libd-onnxruntime.a', 'd_imgui': 'libd_imgui_stub.a', 'd-bvh': 'libd-bvh.a',
    'lwo2-writer': 'lib/liblwo2-writer.a', 'bindbc-assimp6': 'lib/libbindbc-assimp6.a'})

SPECS.update({'render-model': {'name': 'vibe3d:render-model',
                  'root': 'libraries/render/model',
                  'ordinaryDigest': '1bd153c107308b8da5e0db3f003f85b7df379e2910c4ea51dc87e71dc97e2941',
                  'testDigest': 'd92d0d4115a15ce61849628d7bb2903737e1a5087e566f0e3d2308a3ec9c13c9',
                  'sources': ['source/vibe3d/render/model/render/backend.d', 'source/vibe3d/render/model/render/scene.d'],
                  'testSources': ['../source/vibe3d/render/model/render/backend.d',
 '../source/vibe3d/render/model/render/scene.d',
 'source/vibe3d/render/model/render_model_population_test.d'],
                  'testImports': ['source', '../source'],
                  'lower': ['math'],
                  'testLower': ['math'],
                  'external': {},
                  'ordinaryConfig': 'with-render', 'targetName': 'vibe3d-render-model', 'testName': 'vibe3d-render-model-tests'},
 'render-backends': {'name': 'vibe3d-render-backends',
                     'root': 'packages/render-backends',
                     'ordinaryDigest': '834b207df14abdc67e969f518886a42b34bf631a1d1e8d772f72e97606d11ec2',
                     'testDigest': '044c976e0841a6ecfd6b1ea9351549a7a2f331439664f07eb839c3c00827b200',
                     'sources': ['source/render/backend_bridge.d',
                                 'source/render/cycles_backend.d',
                                 'source/render/render_diff.d',
                                 'source/render/rpr_backend.d'],
                     'testSources': ['../source/render/backend_bridge.d',
                                     '../source/render/cycles_backend.d',
                                     '../source/render/render_diff.d',
                                     '../source/render/rpr_backend.d',
                                     'source/render_backends_population_test.d'],
                     'testImports': ['source', '../source'],
                     'lower': ['input-events', 'log', 'math', 'render-model'],
                     'testLower': ['input-events', 'log', 'math', 'render-model'],
                     'external': {'bindbc-sdl': '~>1.5.2',
                                  'bindbc-opengl': '~>1.1.1',
                                  'd-cycles': {'version': 'a69f99794fab25b4902e0523052e5c4b6bef0941',
                                               'repository': 'git+https://github.com/shulc/D-Cycles.git'},
                                  'bindbc-rpr': {'version': 'd1a0a786c307207df3d50db809490c7030bd5927',
                                                 'repository': 'git+https://github.com/shulc/D-RadeonProRender.git'}},
                     'ordinaryConfig': 'with-render'},
 'forms-model': {'name': 'vibe3d-forms-model',
                 'root': 'packages/forms-model',
                 'ordinaryDigest': '05ee48341bc8a74c340e03ab7650c3b45eb7076492d62ee1c79129c6155d0958',
                 'testDigest': 'acbbbc627a920e0ab6ff7960b76d40459c141837c817c61224c743cb8619b544',
                 'sources': ['source/forms.d'],
                 'testSources': ['../source/forms.d', 'source/forms_source_test.d'],
                 'testImports': ['source', '../source'],
                 'lower': ['command-runtime', 'param-schema'],
                 'testLower': ['command-runtime', 'param-schema'],
                 'external': {'dyaml': {'version': '22e4724474795eefb64ee9742f980b49bb34f6ef',
                                        'repository': 'git+https://github.com/shulc/D-YAML.git'}},
                 'ordinaryConfig': 'modeling-noai'},
 'editor-ui': {'name': 'vibe3d-editor-ui',
               'root': 'packages/editor-ui',
               'ordinaryDigest': 'ee93317661739e890e017526a151bdb2305153cf9b5df6cb18a94ee1999c3749',
               'testDigest': 'bd0d0fff001ac30778a3a513dea886494bbc0ac346e4f0e9e81f2c14240d732f',
               'sources': ['source/args_dialog.d',
                           'source/buttonset.d',
                           'source/copilot_overlay.d',
                           'source/copilot_panel.d',
                           'source/forms_render.d',
                           'source/imgui_event_gate.d',
                           'source/imgui_flag_abi.c',
                           'source/imgui_flag_boundary.d',
                           'source/imgui_style.d',
                           'source/pie_geometry.d',
                           'source/pie_menus.d',
                           'source/pie_state.d',
                           'source/popup_state.d',
                           'source/ui/action_menu.d',
                           'source/ui/availability.d',
                           'source/ui/button_face.d',
                           'source/ui/channel_rows.d',
                           'source/ui/channels_panel.d',
                           'source/ui/command_notice.d',
                           'source/ui/dock_drag.d',
                           'source/ui/guard_modal_state.d',
                           'source/ui/history_panel.d',
                           'source/ui/image_list_panel.d',
                           'source/ui/image_rows.d',
                           'source/ui/imgui_window_class.d',
                           'source/ui/item_glyphs.d',
                           'source/ui/item_rename.d',
                           'source/ui/item_rows.d',
                           'source/ui/layer_list_panel.d',
                           'source/ui/mode_popup.d',
                           'source/ui/panel_chrome.d',
                           'source/ui/panel_host_roles.d',
                           'source/ui/panels.d',
                           'source/ui/pie_record.d',
                           'source/ui/pie_render.d',
                           'source/ui/remesh_modal_state.d',
                           'source/ui/retained_item.d',
                           'source/ui/stat_record.d',
                           'source/ui/stat_rows.d',
                           'source/ui/tool_properties_panel.d',
                           'source/ui/viewport_props_role.d'],
               'testSources': ['../source/args_dialog.d',
                               '../source/buttonset.d',
                               '../source/copilot_overlay.d',
                               '../source/copilot_panel.d',
                               '../source/forms_render.d',
                               '../source/imgui_event_gate.d',
                               '../source/imgui_flag_abi.c',
                               '../source/imgui_flag_boundary.d',
                               '../source/imgui_style.d',
                               '../source/pie_geometry.d',
                               '../source/pie_menus.d',
                               '../source/pie_state.d',
                               '../source/popup_state.d',
                               '../source/ui/action_menu.d',
                               '../source/ui/availability.d',
                               '../source/ui/button_face.d',
                               '../source/ui/channel_rows.d',
                               '../source/ui/channels_panel.d',
                               '../source/ui/command_notice.d',
                               '../source/ui/dock_drag.d',
                               '../source/ui/guard_modal_state.d',
                               '../source/ui/history_panel.d',
                               '../source/ui/image_list_panel.d',
                               '../source/ui/image_rows.d',
                               '../source/ui/imgui_window_class.d',
                               '../source/ui/item_glyphs.d',
                               '../source/ui/item_rename.d',
                               '../source/ui/item_rows.d',
                               '../source/ui/layer_list_panel.d',
                               '../source/ui/mode_popup.d',
                               '../source/ui/panel_chrome.d',
                               '../source/ui/panel_host_roles.d',
                               '../source/ui/panels.d',
                               '../source/ui/pie_record.d',
                               '../source/ui/pie_render.d',
                               '../source/ui/remesh_modal_state.d',
                               '../source/ui/retained_item.d',
                               '../source/ui/stat_record.d',
                               '../source/ui/stat_rows.d',
                               '../source/ui/tool_properties_panel.d',
                               '../source/ui/viewport_props_role.d',
                               'source/tests/unit/ui/channel_rows_test.d',
                               'source/tests/unit/ui/command_notice_test.d',
                               'source/tests/unit/ui/stat_rows_test.d',
                               'source/ui/availability_source_test.d',
                               'source/ui/item_click_source_test.d'],
               'testImports': ['source', '../source'],
               'lower': ['forms-model',
                         'ai-advisor',
                         'ai3d-runtime',
                         'application-core',
                         'camera-model',
                         'command-runtime',
                         'display-policy',
                         'document-actions',
                         'document-channels',
                         'document-io',
                         'document-model',
                         'edit-contracts',
                         'editor-commands',
                         'input-events',
                         'interactive-tools',
                         'interchange',
                         'mesh',
                         'mesh-ops',
                         'param-schema',
                         'pipe-evaluation',
                         'pipe-runtime',
                         'profiling',
                         'remesh-runtime',
                         'viewport-gpu',
                         'viewport-host',
                         'log',
                         'math',
                         'spatial',
                         'interaction-data',
                         'interaction-query',
                         'mesh-snapshot',
                         'pipe-contracts',
                         'scene-query'],
               'testLower': ['forms-model',
                             'ai-advisor',
                             'ai3d-runtime',
                             'application-core',
                             'camera-model',
                             'command-runtime',
                             'display-policy',
                             'document-actions',
                             'document-channels',
                             'document-io',
                             'document-model',
                             'edit-contracts',
                             'editor-commands',
                             'input-events',
                             'interactive-tools',
                             'interchange',
                             'mesh',
                             'mesh-ops',
                             'param-schema',
                             'pipe-evaluation',
                             'pipe-runtime',
                             'profiling',
                             'remesh-runtime',
                             'viewport-gpu',
                             'viewport-host',
                             'log',
                             'math',
                             'spatial',
                             'interaction-data',
                             'interaction-query',
                             'mesh-snapshot',
                             'pipe-contracts',
                             'scene-query'],
               'external': {'d_imgui': {'version': 'd535ba78c7d01aca3c9d45ca94ea8e55455ffb7f',
                                        'repository': 'git+https://github.com/shulc/D-ImGui.git'},
                            'dyaml': {'version': '22e4724474795eefb64ee9742f980b49bb34f6ef',
                                      'repository': 'git+https://github.com/shulc/D-YAML.git'},
                            'bindbc-sdl': '~>1.5.2',
                            'bindbc-opengl': '~>1.1.1'},
               'ordinaryConfig': 'modeling-noai'}})

RENDER_NATIVE = {'d-cycles': {'sha256': '603531d3a3e5b251dad84fba77657046c2e14aeaa84eac7c27e34d4109e77513'},
 'bindbc-rpr': {'sha256': 'a3f0d0bf6d97b72353ae560b0837bddae6c8970afe52f079d6469bc3477a2d8f'}}
RENDER_SOURCE_PINS = {'d-cycles': {'dub.json': '603531d3a3e5b251dad84fba77657046c2e14aeaa84eac7c27e34d4109e77513',
              'CMakeLists.txt': '3dc8d34b2f9cf1c88a45e0f6bba1d3fa3ea93b414eaa0d49badb526d4320fe37',
              'tools/build_cycles_libs.sh': '632b8e90a81cd056d9dc80dd9dbfa75244104ea31f28a7f70b5c1c94e3894000',
              'source/cycles/c.d': 'f35a4fd4a236384393ac5fb699d6246e95149ce29169669439e5e133f3bcb51c',
              'csrc/cyclesc.h': '76d9e04bbd0bc143ae6451082aae5a7a5ced935480006cba93a8f95eb50fa0f3',
              'csrc/cyclesc_internal.h': 'c41bed903dbe70ca40a46231355bf243af8f905da27438d2a7435b1d983209ee'},
 'bindbc-rpr': {'dub.json': 'a3f0d0bf6d97b72353ae560b0837bddae6c8970afe52f079d6469bc3477a2d8f',
                'source/bindbc/rpr/config.d': '7cff18bfa0e5fcbd71b50a2d9141397f56256d758ec33b0508f7f4f20d2d65a0'}}

APP_SOURCES = ['source/ai3d_command_registration.d',
 'source/ai_command_registration.d',
 'source/app.d',
 'source/application_command_binding.d',
 'source/commands/actr.d',
 'source/commands/ai/toggle.d',
 'source/commands/ai3d/generate.d',
 'source/commands/ai3d/generate_open.d',
 'source/commands/ai3d/generate_test_hooks.d',
 'source/commands/ai3d/import_result.d',
 'source/commands/constrain/toggle.d',
 'source/commands/copilot/analyze.d',
 'source/commands/copilot/cycle_finding.d',
 'source/commands/copilot/select_finding.d',
 'source/commands/file/load.d',
 'source/commands/file/save.d',
 'source/commands/mesh/magnet.d',
 'source/commands/mesh/morph.d',
 'source/commands/mesh/remesh.d',
 'source/commands/path/define.d',
 'source/commands/prefs/coord_rounding.d',
 'source/commands/prefs/trackball.d',
 'source/commands/snap/mode.d',
 'source/commands/snap/toggle.d',
 'source/commands/snap/toggle_type.d',
 'source/commands/symmetry/toggle.d',
 'source/commands/test_undo_flags.d',
 'source/commands/ui/about.d',
 'source/commands/ui/channels.d',
 'source/commands/ui/copilot_panel.d',
 'source/commands/ui/image_list.d',
 'source/commands/ui/layer_list.d',
 'source/commands/ui/layout_reset.d',
 'source/commands/ui/pie.d',
 'source/commands/ui/statistics.d',
 'source/commands/ui/tool_properties.d',
 'source/commands/ui/viewport_props.d',
 'source/commands/viewport/command_base.d',
 'source/commands/viewport/display.d',
 'source/commands/viewport/fit.d',
 'source/commands/viewport/fit_selected.d',
 'source/commands/viewport/grid_steps.d',
 'source/commands/viewport/independence.d',
 'source/commands/viewport/layout_preset.d',
 'source/commands/viewport/master.d',
 'source/commands/viewport/view_preset.d',
 'source/commands/workplane.d',
 'source/copilot_command_registration.d',
 'source/create_tool_registration.d',
 'source/edit_tool_registration.d',
 'source/editor_app.d',
 'source/file_io_registration.d',
 'source/frame_runner.d',
 'source/frame_stall.d',
 'source/guarded_action_controller.d',
 'source/history_macro_registration.d',
 'source/http_command_adapter.d',
 'source/http_providers.d',
 'source/input_frame_state.d',
 'source/input_router.d',
 'source/item_command_registration.d',
 'source/item_pick.d',
 'source/layout_reset_action.d',
 'source/mesh_command_registration.d',
 'source/pipe_command_registration.d',
 'source/prefs.d',
 'source/registration.d',
 'source/render/render_mvp.d',
 'source/scene_file_lifecycle_registration.d',
 'source/scene_reset_effects.d',
 'source/selection_command_registration.d',
 'source/selftest_fault.d',
 'source/tool_lifecycle_registration.d',
 'source/transform_tool_registration.d',
 'source/tsan_preinit.d',
 'source/ui/viewport_render.d',
 'source/view_settings_registration.d',
 'source/viewport_command_registration.d',
 'source/web_gl_loader.d']
REVISIONS.update({'d-cycles': ('a69f99794fab25b4902e0523052e5c4b6bef0941', 'git+https://github.com/shulc/D-Cycles.git'), 'bindbc-rpr': ('d1a0a786c307207df3d50db809490c7030bd5927', 'git+https://github.com/shulc/D-RadeonProRender.git')})
EXTERNAL_DEPS.update({'d-cycles': (), 'bindbc-rpr': ('bindbc-common', 'bindbc-loader')})
ARCHIVES.update({'d-cycles': 'libd-cycles.a', 'bindbc-rpr': 'lib/libbindbc-rpr.a'})

def raw_config(path, configuration):
    raw = json.loads((path/'dub.json').read_text())
    config = next(c for c in raw['configurations'] if c['name'] == configuration)
    return raw, config

def external_closure(names, web=False):
    result = set(names)
    for name in tuple(result): result.update(EXTERNAL_DEPS[name])
    if web and 'bindbc-sdl' in result and 'bindbc-opengl' not in result:
        result.discard('bindbc-loader')
    return result

def native_grants(names, roots, web=False):
    libs, lflags = legacy_native_grants(names, roots, web)
    if 'd_imgui' in names:
        lflags.update((str(roots['d_imgui']/'lib/libcimgui_docking.a'),
                       '-lstdc++', '-L'+str(roots['d_imgui']/'lib'), '-lSDL2'))
    if 'd-bvh' in names:
        libs.update(('dbvh_c', 'stdc++', 'm'))
        lflags.add('-L'+str(roots['d-bvh']/'build'))
    if 'bindbc-assimp6' in names:
        libs.update(('stdc++', 'm'))
        lflags.update(str(roots['bindbc-assimp6']/p) for p in
                      ('lib/libassimp.a', 'lib/libzlibstatic.a'))
    if 'nfde' in names:
        require(not web, 'support web native chooser dependency')
        libs.update(('dbus-1', 'wayland-client', 'm'))
        lflags.add(str(roots['nfde']/'nativefiledialog-extended/out/src/libnfd.a'))
    if 'd-onnxruntime' in names:
        libs.update(('onnxrt', 'onnxruntime', 'stdc++'))
        lflags.update(('-L'+str(roots['d-onnxruntime']/'build'),
            '-L'+str(roots['d-onnxruntime']/'build/onnxruntime/sdk/lib'),
            '-rpath=$ORIGIN', '-rpath=$ORIGIN/lib',
            '-rpath='+str(roots['d-onnxruntime']/'build/onnxruntime/sdk/lib')))
    for name in set(names) & set(RENDER_NATIVE):
        raw = json.loads((roots[name]/'dub.json').read_text())
        libs.update(raw.get('libs-linux', raw.get('libs', [])))
        lflags.update(value.replace('$$ORIGIN', '$ORIGIN').replace('$PACKAGE_DIR', str(roots[name]))
                      for value in raw.get('lflags-linux', raw.get('lflags', [])))
    return libs, lflags

def validate_external(package, web=False):
    name=package['name'];path=Path(package['path']).resolve()
    if name in RENDER_NATIVE:
        raw = json.loads((path/'dub.json').read_text())
        require(legacy_digest(path/'dub.json') == RENDER_NATIVE[name]['sha256'],
                'PREPARATION-REFUSED: renderer native recipe identity: '+name)
        require(legacy_native_revision(path) == REVISIONS[name][0],
                'PREPARATION-REFUSED: renderer native source revision: '+name)
        require(package['targetType'] == raw['targetType'], 'support renderer native target: '+name)
        require(package.get('dependencies', []) == list(raw.get('dependencies', {})),
                'support renderer native dependency DAG: '+name)
        require(package.get('versions', []) == [] and
                (name != 'bindbc-rpr' or package['configuration'] == 'dynamic'),
                'PREPARATION-REFUSED: renderer requires dynamic RPR')
        for field in HOOKS:
            require(package.get(field, []) == raw.get(field+'-linux', raw.get(field, [])),
                    'support renderer retained native hook array: '+name+':'+field)
        require(package.get('importPaths', []) == ['source'], 'support renderer native imports: '+name)
        return
    if name in ('nfde', 'd-onnxruntime'):
        raw=json.loads((path/'dub.json').read_text())
        require(canonical_digest(raw)==(NFDE_DESCRIPTOR_DIGEST if name=='nfde' else ONNX_DESCRIPTOR_DIGEST),
                'support native descriptor identity: '+name)
        require(package['targetType']=='staticLibrary' and not package.get('dependencies', []),
                'support native archive/dependency identity: '+name)
        require(sorted((path/p).resolve() for p in package.get('importPaths', []))==[path/'source'],
                'support native importPaths: '+name)
        expected_hooks=raw['preBuildCommands-linux'] if name=='nfde' else raw['preBuildCommands-posix']
        for field in HOOKS:
            require(package.get(field, [])==(expected_hooks if field=='preBuildCommands' else []),
                    'support native hook: '+name+':'+field)
        require(not package.get('stringImportPaths', []), 'support native stringImportPaths: '+name)
        if name=='nfde':require(not web, 'support web native chooser dependency')
        else:require(legacy_native_revision(path)==REVISIONS[name][0], 'support native repository revision: '+name)
        return
    require(package['targetType']==('library' if name in ('dyaml','lwo2-writer','bindbc-assimp6') else 'staticLibrary'),
            'support resolved native archive target: '+name)
    expected_hooks=[]
    if name=='d-stb-image':
        expected_hooks=['cmake -B $PACKAGE_DIR/build -DCMAKE_GENERATOR=Ninja -DCMAKE_BUILD_TYPE=Release $PACKAGE_DIR',
                        'cmake --build $PACKAGE_DIR/build --config Release']
    elif name=='d-opensubdiv':
        expected_hooks=['cd "$PACKAGE_DIR" && git submodule update --init --recursive --quiet',
                        'cmake -S "$PACKAGE_DIR" -B "$PACKAGE_DIR/build" -DCMAKE_BUILD_TYPE=Release',
                        'cmake --build "$PACKAGE_DIR/build" -j --target osdc']
    elif name=='d-bvh':
        expected_hooks=['cd "$PACKAGE_DIR" && git submodule update --init --quiet',
                        'cmake -S "$PACKAGE_DIR" -B "$PACKAGE_DIR/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF',
                        'cmake --build "$PACKAGE_DIR/build" -j --target dbvh_c']
    elif name=='d_imgui':
        expected_hooks = ['cd "$PACKAGE_DIR" && git submodule sync --quiet extern/cimgui && git submodule update --init --recursive --quiet extern/cimgui', 'cd "$PACKAGE_DIR" && test -f lib/libcimgui_docking.a || bash tools/build_imgui_libs.sh']
    elif name=='bindbc-assimp6':
        expected_hooks=['cd "$PACKAGE_DIR" && git submodule update --init --recursive --quiet extern/assimp',
                        'cd "$PACKAGE_DIR" && test -f lib/libassimp.a || bash tools/build_assimp_min.sh --static']
    for field in HOOKS:
        require(package.get(field,[])==(expected_hooks if field=='preBuildCommands' else []),
                'support resolved native hook: '+name+':'+field)
    require(sorted((path/p).resolve() for p in package.get('importPaths',[]))==[path/'source'],
            'support resolved native importPaths: '+name)
    require(package.get('stringImportPaths',[])==(['tests/fixtures'] if name=='lwo2-writer' else []),
            'support resolved native stringImportPaths: '+name)
    if name in REVISIONS:
        require(legacy_native_revision(path)==REVISIONS[name][0], 'support resolved repository revision: '+name)
    else:
        prefix={'bindbc-sdl':'1.5.','bindbc-opengl':'1.1.','bindbc-common':'1.','bindbc-loader':'1.'}[name]
        require(package['version'].startswith(prefix), 'support resolved binding version: '+name)
    deps=set(EXTERNAL_DEPS[name])
    if web and name=='bindbc-sdl':deps.discard('bindbc-loader')
    require(sorted(package.get('dependencies',[]))==sorted(deps), 'support resolved external DAG: '+name)


def canonical_digest(raw):
    grants = {k:v for k,v in raw.items() if k not in
              ('description','license','authors','copyright') and not k.startswith('_comment')}
    return hashlib.sha256(json.dumps(grants,sort_keys=True,separators=(',',':')).encode()).hexdigest()

def internal_owner(name, direct_owner=None):
    if direct_owner is not None and name==SPECS[direct_owner]['name'].split(':')[-1]:
        return direct_owner
    for owner, spec in SPECS.items():
        if name in (spec['name'], test_name(owner)):
            return owner
    raise BoundaryError('support unknown internal identity: '+name)


def is_internal(name, direct_owner=None):
    return ((direct_owner is not None and name==SPECS[direct_owner]['name'].split(':')[-1])
            or any(name in (spec['name'], test_name(owner)) for owner, spec in SPECS.items()))


def test_name(owner):
    return SPECS[owner].get('testName', SPECS[owner]['name']+'-tests')


def archive_name(owner):
    return 'lib'+SPECS[owner].get('targetName', SPECS[owner]['name'])+'.a'


def ordinary_arguments(project, owner):
    return [':'+owner, '--root='+str(project)] if SPECS[owner]['name']=='vibe3d:'+owner else ['--root='+str(project/SPECS[owner]['root'])]


def production_files(project, owner):
    spec = SPECS[owner]
    return sorted((project/spec['root']/p).resolve() for p in spec['sources'] + spec.get('transitionalSources', []))

def test_helper_files(project, owner):
    return [(project/SPECS[owner]['root']/p).resolve()
            for p in SPECS[owner].get('testHelpers', ())]

def closure(owner, tests=False):
    seen = set()
    def visit(name):
        if name in seen: return
        seen.add(name)
        for lower in SPECS[name]['lower']: visit(lower)
    for name in SPECS[owner]['testLower'] if tests else (owner,): visit(name)
    return seen

def test_files(project, owner):
    own = project/SPECS[owner]['root']/'tests'
    files = [(own/p).resolve() for p in SPECS[owner]['testSources']]
    for lower in closure(owner, True):
        files += production_files(project, lower) + test_helper_files(project, lower)
    require(len(files)==len(set(files)), 'support explicit source ownership overlaps: '+owner)
    return sorted(files)

MATH_TRANSITIONAL = {'source/math.d': 'module math;\n\npublic import vibe3d.util.math.math;\n',
 'source/math_geometry.d': 'module math_geometry;\n\npublic import vibe3d.util.math.math_geometry;\n',
 'source/math_matrix.d': 'module math_matrix;\n\npublic import vibe3d.util.math.math_matrix;\n',
 'source/math_quaternion.d': 'module math_quaternion;\n'
                             '\n'
                             'public import vibe3d.util.math.math_quaternion;\n',
 'source/math_vector.d': 'module math_vector;\n\npublic import vibe3d.util.math.math_vector;\n',
 'source/vibe3d/util/math/package.d': 'module vibe3d.util.math;\n'
                                      '\n'
                                      'public import vibe3d.util.math.math_vector :\n'
                                      '    Vec3,\n'
                                      '    Vec4,\n'
                                      '    vec3Lerp,\n'
                                      '    normalize,\n'
                                      '    cross,\n'
                                      '    dot,\n'
                                      '    rotateAboutAxis,\n'
                                      '    rotateAboutPivot,\n'
                                      '    scaleAlongBasis,\n'
                                      '    safeNormalize;\n'
                                      '\n'
                                      'public import vibe3d.util.math.math_matrix :\n'
                                      '    identityMatrix,\n'
                                      '    translationMatrix,\n'
                                      '    pivotRotationMatrix,\n'
                                      '    pivotScaleMatrix,\n'
                                      '    pivotScaleMatrixBasis,\n'
                                      '    matrixFromEulerZYX,\n'
                                      '    eulerZYXFromMatrix,\n'
                                      '    applyAffine,\n'
                                      '    transformPoint,\n'
                                      '    matrixMirrorsWinding,\n'
                                      '    normalMatrix,\n'
                                      '    frameMatrix,\n'
                                      '    frameMatrixInverse,\n'
                                      '    matMul4,\n'
                                      '    wrapAboutPivot,\n'
                                      '    wrapAboutPivotStable,\n'
                                      '    modelMatrix,\n'
                                      '    mulMV,\n'
                                      '    lookAt,\n'
                                      '    perspectiveMatrix,\n'
                                      '    orthographicMatrix;\n'
                                      '\n'
                                      'public import vibe3d.util.math.math_quaternion :\n'
                                      '    Quat,\n'
                                      '    slerp,\n'
                                      '    quatFromMatrix,\n'
                                      '    matrixFromQuat;\n'
                                      '\n'
                                      'public import vibe3d.util.math.math_geometry :\n'
                                      '    faceNormalFirst3,\n'
                                      '    pointInPolygon2D,\n'
                                      '    frontFacingLocal,\n'
                                      '    ringStartCornerSign,\n'
                                      '    closestOnSegment2D,\n'
                                      '    closestOnSegment2DSquared,\n'
                                      '    rayPlaneIntersect,\n'
                                      '    closestOnSegmentToRay,\n'
                                      '    perpendicularFrame,\n'
                                      '    rayTriangleIntersect,\n'
                                      '    closestPointOnTriangle2D,\n'
                                      '    triangulatePolygonEarClip,\n'
                                      '    planeFromLineAndWorkplane,\n'
                                      '    planeForSlice,\n'
                                      '    snapAngleToMultiple,\n'
                                      '    snapLineEndpointToAngle,\n'
                                      '    closestPointOnSegmentToRay,\n'
                                      '    closestPointOnLineToRay,\n'
                                      '    offsetInPlane,\n'
                                      '    offsetMeetDir,\n'
                                      '    offsetMeet,\n'
                                      '    bevelMiterPoint,\n'
                                      '    bevelArcPoints;\n'}


D2_SELECTIVE_FACADES = {'mesh': {'source/vibe3d/mesh/core/package.d': 'module vibe3d.mesh.core;\n'
                                               'public import vibe3d.mesh.core.mesh : Mesh, '
                                               'FaceList;\n'},
 'document-model': {'source/vibe3d/documents/model/package.d': 'module vibe3d.documents.model;\n'
                                                               'public import '
                                                               'vibe3d.documents.model.document : '
                                                               'Document, Layer, MIN_ITEM_SCALE_MAG, '
                                                               'MAX_ITEM_SCALE_MAG, ItemXform, '
                                                               'sanitizeItemXform, ItemKind, '
                                                               'ItemKindInfo, kindInfo, kindFromToken, '
                                                               'tokenOf, ImageData, ImagePlaneData;\n'}}

def check_raw_tree(project, owner):
    for selected in closure(owner)|closure(owner,True)|{owner}:
        spec=SPECS[selected]; root=project/spec['root']
        if selected=='math':
            for path, expected in MATH_TRANSITIONAL.items():
                require((root/path).is_file() and (root/path).read_text()==expected, 'support math transitional source custody: '+path)
        for path, expected in D2_SELECTIVE_FACADES.get(selected, {}).items():
            require((root/path).is_file() and (root/path).read_text()==expected,
                    'support selective facade source custody: '+selected+': '+path)
        for tests in (False,True):
            path=root/('tests/dub.json' if tests else 'dub.json')
            require(path.is_file(),'support selected descriptor missing: '+selected)
            raw=json.loads(path.read_text())
            require(canonical_digest(raw)==spec['testDigest' if tests else 'ordinaryDigest'],
                    'support descriptor contract: '+selected+(' tests' if tests else ' production'))
        found=sorted(p.resolve() for p in (root/'source').rglob('*.d'))
        require(found==[p for p in production_files(project,selected) if p.suffix=='.d'],'support production source identity: '+selected)
        test_root=root/'tests'
        expected_carriers=sorted((test_root/p).resolve() for p in spec['testSources'] if p.startswith('source/'))
        # C custody: cross-common cut is present for root only, never ops algorithm.
        if selected=='mesh-ops':expected_carriers=sorted(expected_carriers+[(test_root/'source/vibe3d/mesh/ops/tests/unit/mesh_ops/cut_test.d').resolve()])
        require(sorted(p.resolve() for p in (test_root/'source').rglob('*.d'))==expected_carriers,
                'support public carrier identity: '+selected)
    # Only the selected algorithm suite owns testLower; subordinate isolated-tests
    # packages contribute production source, not their separate algorithm suites.
    require(all(p.is_file() for p in test_files(project,owner)), 'support missing compiler root: '+owner)
    if owner in FIXTURES:
        path,sha=FIXTURES[owner]
        require(hashlib.sha256((project/path).read_bytes()).hexdigest()==sha,'support fixture identity: '+owner)
    for path, sha in PACKAGE_FIXTURES.get(owner, ()):
        require(hashlib.sha256((project/path).read_bytes()).hexdigest()==sha,
                'support fixture identity: '+owner+':'+path)

def validate_description(description, project, owner, config, tests=False, harness=None, compiler="dmd"):
    root_name=test_name(owner) if tests else SPECS[owner]['name']
    require(description['rootPackage']==root_name,'support resolved root package: '+owner)
    active_list=[p for p in description['packages'] if p.get('active')]
    active={p['name']:p for p in active_list}
    require(len(active)==len(active_list),'support resolved package population duplicate')
    expected={SPECS[x]['name'] for x in closure(owner,tests)}|{root_name}
    internal={n for n in active if is_internal(n)}
    require(internal==expected,'support resolved internal package population: '+owner)
    external=set()
    for name in internal:
        selected=internal_owner(name)
        path=project/SPECS[selected]['root']/('tests' if name.endswith('-tests') else '')
        raw, cfg=raw_config(path,active[name]['configuration'])
        external.update(k for k in set(raw.get('dependencies',{}))|set(cfg.get('dependencies',{})) if not is_internal(k))
    require(set(active)-internal==external_closure(external,config=='web'), 'support resolved external package population: '+owner)
    for name in set(active)-internal:
        if name=='nfde':require(Path(active[name]['path']).resolve()==(project/'third_party/nfde').resolve(),
                'support committed native chooser path')
        validate_external(active[name],config=='web')
    for name in internal:
        is_test=name.endswith('-tests'); selected=internal_owner(name)
        spec=SPECS[selected];path=(project/spec['root']/('tests' if is_test else '')).resolve()
        package=active[name]
        require(Path(package['path']).resolve()==path,'support resolved owner path: '+name)
        raw=json.loads((path/'dub.json').read_text())
        config_grants=next(c for c in raw['configurations'] if c['name']==package['configuration'])
        declared=set(raw.get('dependencies',{}))|set(config_grants.get('dependencies',{}))
        require(sorted(package.get('dependencies',[]))==sorted(declared),
                'support resolved dependency DAG: '+name)
        effective=config if is_test or not tests else ('snapshot-fixtures' if owner=='mesh-snapshot' and selected=='mesh' else 'isolated-tests')
        require(package['configuration']==effective,'support resolved configuration: '+name)
        require(package['targetType']==('executable' if is_test else 'sourceLibrary' if tests or config in ('root-tests','isolated-tests') else 'staticLibrary'),
                'support resolved compiler owner: '+name)
        files=sorted((path/f['path']).resolve() for f in package['files'] if f['role']=='source')
        own_files=sorted((path/p).resolve() for p in spec['testSources']) if is_test else production_files(project,selected)
        if selected=='ai3d-runtime' and not is_test and config=='web':
            excluded=set(config_grants['excludedSourceFiles'])
            own_files=[p for p in own_files if str(p.relative_to(path)) not in excluded]
        if not is_test and package['configuration'] in ('root-tests', 'isolated-tests'):
            own_files += test_helper_files(project, selected);own_files.sort()
        if is_test and harness is not None: own_files.append(harness.resolve());own_files.sort()
        require(files==own_files,'support resolved sourceFiles: '+name)
        expected_flags = ['--singleobj'] if (selected == 'mesh-ops' and not is_test and
            config_grants['name'] in ('modeling', 'modeling-noai', 'with-render', 'web') and
            Path(compiler).name in ('ldc', 'ldc2')) else []
        if selected in ('interactive-tools', 'editor-ui'):
            # Package descriptions retain the recipe variable; target settings expand it.
            expected_flags = ['-P-I$D_IMGUI_PACKAGE_DIR/extern/cimgui']
        require(package.get('dflags', []) == expected_flags, 'support resolved include-import flags: '+name)
        require(all(not package.get(k) for k in HOOKS),'support resolved owner hook: '+name)
        versions=raw.get('versions',[])+config_grants.get('versions',[])
        require(sorted(package.get('versions',[]))==sorted(set(versions)), 'support resolved versions: '+name)
        for field in ('importPaths','stringImportPaths'):
            expected_paths=raw.get(field, ['source'] if field=='importPaths' else [])+config_grants.get(field,[])
            require(sorted((path/p).resolve() for p in package.get(field,[]))==sorted((path/p).resolve() for p in expected_paths),
                    'support resolved '+field+': '+name)
        for field in ('lflags','libs','frameworks','injectSourceFiles','copyFiles','extraDependencyFiles'):
            require(not package.get(field), 'support resolved owner link grant: '+name+':'+field)
    targets={t['rootPackage']:t for t in description['targets']}
    require(len(targets)==len(description['targets']),'support resolved target population duplicate')
    expected_targets=set() if config in ('root-tests','isolated-tests') else {n for n,p in active.items() if p['targetType']!='sourceLibrary'}
    require(set(targets)==expected_targets,'support resolved target population: '+owner)
    for name,target in targets.items():
        if not is_internal(name):continue
        settings=target['buildSettings']
        selected=internal_owner(name)
        expected_sources=test_files(project,selected) if name.endswith('-tests') else production_files(project,selected)
        if selected=='ai3d-runtime' and not name.endswith('-tests') and config=='web':
            excluded={'source/ai3d/job_controller.d','source/ai3d/stage_artifact.d','source/ai3d/worker_manager.d'}
            expected_sources=[p for p in expected_sources if str(p.relative_to(project/SPECS[selected]['root'])) not in excluded]
        if not name.endswith('-tests') and config in ('root-tests', 'isolated-tests'):
            expected_sources += test_helper_files(project, selected)
        if name.endswith('-tests') and harness is not None:expected_sources.append(harness.resolve())
        actual=[Path(p).resolve() for p in settings.get('sourceFiles',[])]
        require(sorted(actual)==sorted(expected_sources) and len(actual)==len(set(actual)),
                'support target compiler source identity: '+name)
        require(not any(x=='-i' or x.startswith(('-i=','--include-imports')) for x in settings.get('dflags',[])),
                'support target include-import flags: '+name)
        if selected in ('interactive-tools', 'editor-ui'):
            expected_flags = ['-P-I'+str(Path(active['d_imgui']['path']).resolve()/'extern/cimgui')]
            # Task 20262872: inherited target flags may repeat declared capabilities;
            # retain the raw vector/order (composition custody: ldc_inherited_target_flags_source_fix;
            # doc/library_layout_wave15_ldc_target_flag_source_correction_2026-10-14.md).
            if (Path(compiler).name in ('ldc', 'ldc2') and
                'mesh-ops' in closure(selected, name.endswith('-tests')) and
                active[SPECS['mesh-ops']['name']]['configuration'] in
                    ('modeling', 'modeling-noai', 'with-render', 'web')):
                expected_flags.append('--singleobj')
            flags = settings.get('dflags', [])
            require(all(flag in expected_flags for flag in flags) and
                    all(flag in flags for flag in expected_flags),
                    'support target C include path: '+name)
        if selected == 'mesh-ops' and not name.endswith('-tests'):
            expected_flags = ['--singleobj'] if (config in ('modeling', 'modeling-noai', 'with-render', 'web') and
                Path(compiler).name in ('ldc', 'ldc2')) else []
            require(settings.get('dflags', []) == expected_flags, 'support target archive flags: '+name)
        if tests:require(not any('libvibe3d-' in Path(p).name for p in settings.get('linkerFiles',[])),
                         'support target overlapping internal D archives: '+name)
        seen=set()
        def visit(n):
            if n in seen:return
            seen.add(n)
            for dep in active[n].get('dependencies',[]):visit(dep)
        visit(name)
        roots={n:Path(active[n]['path']).resolve() for n in seen}
        for field in ('importPaths','stringImportPaths'):
            expected_paths={str((roots[n]/p).resolve()) for n in seen for p in active[n].get(field,[])}
            actual_paths=[str(Path(p).resolve()) for p in settings.get(field,[])]
            require(len(actual_paths)==len(expected_paths) and set(actual_paths)==expected_paths,
                    'support target '+field+': '+name)
        archives={str(roots[n]/(ARCHIVES[n] if n in ARCHIVES else archive_name(internal_owner(n)))) for n in seen-{name}
                  if active[n]['targetType'] in ('staticLibrary','library')}
        require(set(settings.get('linkerFiles',[]))==archives and len(settings.get('linkerFiles',[]))==len(archives),
                'support target D archive inputs: '+name)
        libs,lflags=native_grants(seen,roots,config=='web')
        for field,expected_values in (('libs',libs),('lflags',lflags)):
            require(set(settings.get(field,[]))==expected_values and (field=='lflags' or len(settings.get(field,[]))==len(expected_values)),
                    'support target native link inputs: '+name+':'+field)
        for field in HOOKS+('injectSourceFiles','copyFiles','extraDependencyFiles','cImportPaths'):
            require(not settings.get(field), 'support target extra grant: '+name+':'+field)

    return active

def compiler_commands(output, compiler_cwd=None, response_inputs=None):
    """Read DUB's verbose compiler argv, including its actual working directory."""
    commands = []
    for line in output.splitlines():
        match = re.match(r'^\[cwd=(.+?)\] (.+)$', line)
        if match:
            cwd, command = Path(match[1]).resolve(), match[2]
            cwd_evidence = 'compiler log prefix'
        elif compiler_cwd is not None and re.match(r'^(?:\S*/)?(?:dmd|ldc2|ldc)\s', line):
            # DUB emits the prefix for DMD but not every supported compiler.
            # build keeps its invocation cwd; test compiles in its target root.
            cwd, command = compiler_cwd.resolve(), line
            cwd_evidence = 'DUB build cwd / test target directory'
        else:
            continue
        argv = shlex.split(command)
        if not argv or Path(argv[0]).name not in ('dmd', 'ldc2', 'ldc'):
            continue
        def expand(arguments, depth=0):
            legacy_require(depth < 8, 'support compiler response recursion')
            expanded = []
            for arg in arguments:
                if arg.startswith('@'):
                    path=(cwd/arg[1:]).resolve()
                    if response_inputs is not None:response_inputs[str(path)]=legacy_digest(path)
                    expanded += expand(shlex.split(path.read_text()), depth + 1)
                else:
                    expanded.append(arg)
            return expanded
        argv = expand(argv)
        inputs = [str((cwd / arg).resolve()) for arg in argv[1:] if not arg.startswith('-')]
        outputs = [str((cwd / arg.removeprefix('-of').lstrip('=')).resolve())
                   for arg in argv[1:] if arg.startswith('-of')]
        commands.append({'cwd': str(cwd), 'cwdEvidence': cwd_evidence, 'argv': argv,
                         'sourceInputs': [p for p in inputs if p.endswith(('.d', '.c'))],
                         'archiveInputs': [p for p in inputs if p.endswith('.a')],
                         'objectInputs': [p for p in inputs if p.endswith(('.o', '.obj'))],
                         'outputs': outputs})
    legacy_require(commands, 'NO-VERDICT: support actual compiler argv/cwd missing')
    return commands


def validate_actual_compiler(commands, project, owner, description, home, harness, renderer=False):
    own=str((project/SPECS[owner]['root']/SPECS[owner]['sources'][0]).resolve());compiles=[c for c in commands if own in c['sourceInputs']]
    require(len(compiles)==1,'support actual compiler source identity: '+owner)
    command=compiles[0];sources=command['sourceInputs']
    generated=[p for p in sources if Path(p).name=='dub_test_root.d' and Path(p).is_relative_to(home/'cache'/test_name(owner)/'~master'/'code')]
    expected=[str(p) for p in test_files(project,owner)]+[str(harness.resolve())]+generated
    require(len(generated)==1 and len(sources)==len(set(sources)) and sorted(sources)==sorted(expected),
            'support actual compiler source identity: '+owner)
    require(not any(x=='-i' or x.startswith(('-i=','--include-imports')) for x in command['argv']),
            'support actual compiler include-import flags: '+owner)
    active={p['name']:p for p in description['packages'] if p.get('active')}
    if owner in ('interactive-tools', 'editor-ui'):
        expected_flags = ['-P-I'+str(Path(active['d_imgui']['path']).resolve()/'extern/cimgui')]
        flags = [x for x in command['argv'] if x.startswith('-P-I')]
        require(all(flag in expected_flags for flag in flags) and
                all(flag in flags for flag in expected_flags),
                'support actual compiler C include path: '+owner)
    for c in commands:
        require(not any('libvibe3d-' in Path(p).name for p in c['archiveInputs']),
                'support actual overlapping internal D archives: '+owner)
    links=[c for c in commands if any(p in c['objectInputs'] for p in command['outputs'])]
    require(len(links)==1,'support actual compiler D archive inputs: '+owner)
    linked=links[0]
    static={n:ARCHIVES[n] for n,p in active.items() if not is_internal(n) and p['targetType'] in ('staticLibrary','library')}
    archives=linked['archiveInputs']
    if renderer:
        target=next(t for t in description['targets'] if t['rootPackage']==description['rootPackage'])
        require(archives==[str(Path(p).resolve()) for p in target['buildSettings'].get('linkerFiles',[])],
                'support renderer actual ordered D archive inputs: '+owner)
    else:
        require(len(archives)==len(static) and all(sum((Path(a).is_relative_to(home/'cache'/n)
                or (n=='nfde' and Path(a)==Path(active[n]['path']).resolve()/filename))
                and Path(a).name==Path(filename).name for a in archives)==1 for n,filename in static.items()),
                'support actual compiler D archive inputs: '+owner)
    return {'compile':command,'link':linked,'generatedMain':generated[0],'staticOwners':sorted(static)}

def compiler_module(relative):
    nominal = {'../source/commands/mesh/array_.d': 'commands.mesh.array_',
     '../source/commands/mesh/copy_.d': 'commands.mesh.copy_',
     '../source/commands/mesh/cut_.d': 'commands.mesh.cut_',
     '../source/commands/mesh/delete_.d': 'commands.mesh.delete_',
     '../source/commands/mesh/duplicate_.d': 'commands.mesh.duplicate_',
     '../source/commands/mesh/mirror_.d': 'commands.mesh.mirror_',
     '../source/commands/mesh/paste_.d': 'commands.mesh.paste_',
     '../source/commands/mesh/radial_array_.d': 'commands.mesh.radial_array_',
     '../source/commands/mesh/remove_.d': 'commands.mesh.remove_'}
    nominal['source/tests/unit/ui/stat_rows_test.d'] = 'tests.unit.ui.stat_rows_test'
    nominal.update({'../../../../tests/unit/fixtures.d': 'tests.unit.fixtures',
                    '../../../../tests/unit/mesh_by_value_gate.d': 'tests.unit.mesh_by_value_gate'})
    nominal.update({'../../../tests/unit/fixtures.d': 'tests.unit.fixtures', '../../../tests/unit/mesh_by_value_gate.d': 'tests.unit.mesh_by_value_gate', 'source/tests/unit/bevel_cold_arm_param_image_test.d': 'unit.bevel_cold_arm_param_image_test', 'source/tests/unit/falloff_rmb_discipline_test.d': 'falloff_rmb_discipline_test', 'source/tests/unit/prepared_param_update_test.d': 'unit.prepared_param_update_test', 'source/tests/unit/prepared_tool_transition_test.d': 'unit.prepared_tool_transition_test', 'source/tests/unit/tools/edit/topology_pen/move_protocol_test.d': 'tools.edit.topology_pen.move_protocol_test', 'source/tests/unit/tools/edit/topology_pen/press_compatibility_test.d': 'tools.edit.topology_pen.press_compatibility_test'})
    if relative in nominal: return nominal[relative]
    if relative=='../../../tests/unit/mesh_by_value_gate.d':return 'tests.unit.mesh_by_value_gate'
    if relative=='../../../tests/unit/fixtures.d':return 'tests.unit.fixtures'
    module = relative.removeprefix('tests/source/').removeprefix('../source/').removeprefix('source/').removesuffix('.d').replace('/','.')
    return module.removesuffix('.package') if relative.endswith('/package.d') else module

# The frozen pre-compile identity is translated from the accepted root cell map.
# It is independent of the runtime roster observed below.
ENABLED_MODULES = frozenset(['vibe3d.platform.input.tests.unit.sdl_error_test',
 'ai3d.worker_manager',
 'vibe3d.editing.params.argstring',
 'bg_gpu_cache',
 'bvh_pick',
 'command_history',
 'command_registry',
 'commands.image.commands',
 'commands.layer.commands',
 'commands.mesh.edge_crease',
 'drag',
 'drag_identity',
 'drag_source_cells',
 'edit_session',
 'vibe3d.platform.input.eventlog',
 'falloff_rmb_discipline_test',
 'gl_thread_guard',
 'handles.arbiter_source_cells',
 'handles.gizmo_metrics',
 'handles.gl_util',
 'handles.gl_util_source_cells',
 'handles.shapes',
 'http_server',
 'image_plane_source_cells',
 'io.file_dialog',
 'io.lwo_import',
 'io.native',
 'io.scene_import',
 'io.scene_ir',
 'vibe3d.util.log.log',
 'vibe3d.util.math.math_geometry',
 'vibe3d.util.math.math_quaternion',
 'vibe3d.mesh.core.mesh',
 'vibe3d.mesh.contracts.mesh_corner_maps',
 'vibe3d.mesh.change.mesh_dirty',
 'vibe3d.mesh.edit_log.mesh_edit_delta',
 'vibe3d.mesh.edit_log.mesh_edit_log_protocol_test',
 'vibe3d.mesh.edit_replay.mesh_edit_replay',
 'vibe3d.mesh.edit_replay.mesh_edit_replay_roundtrip_test',
 'mesh_gpu',
 'vibe3d.mesh.ops.mesh_ops.extrude',
 'vibe3d.mesh.ops.mesh_ops.loop_slice',
 'vibe3d.mesh.ops.mesh_ops.poly_bevel',
 'vibe3d.mesh.ops.mesh_ops.triangulate',
 'vibe3d.mesh.core.mesh_planes',
 'vibe3d.mesh.topology.mesh_topo',
 'overlay_space_source_cells',
 'vibe3d.util.plane_bytes.plane_bytes',
 'prepared_bridge_activation_source_cells',
 'prepared_command_wrapper_activation_source_cells',
 'prepared_edge_bevel_activation_source_cells',
 'prepared_edge_extend_deactivate_source_cells',
 'prepared_edge_extend_tool_activation_source_cells',
 'prepared_edge_extrude_activation_source_cells',
 'prepared_edge_slice_activation_source_cells',
 'prepared_edge_slice_deactivate_source_cells',
 'prepared_inherited_noop_source_cells',
 'prepared_loop_slice_activation_source_cells',
 'prepared_loop_slice_deactivate_source_cells',
 'prepared_mirror_activation_source_cells',
 'prepared_move_update_source_cells',
 'prepared_pipe_activation_source_cells',
 'prepared_poly_bevel_activation_source_cells',
 'prepared_poly_extrude_activation_source_cells',
 'prepared_poly_inset_activation_source_cells',
 'prepared_private_state',
 'prepared_private_state_source_cells',
 'prepared_radial_array_transition_source_cells',
 'prepared_radial_sweep_transition_source_cells',
 'prepared_record_context',
 'prepared_record_context_source_cells',
 'prepared_rotate_update_source_cells',
 'prepared_scale_update_source_cells',
 'prepared_selection_profile_source_cells',
 'prepared_slice_activation_source_cells',
 'prepared_slice_deactivate_source_cells',
 'prepared_smooth_shift_activation_source_cells',
 'prepared_stroke_extrude_activation_source_cells',
 'prepared_tack_activation_source_cells',
 'prepared_topology_pen_activation_source_cells',
 'prepared_topology_pen_deactivate_source_cells',
 'prepared_topology_pen_update_source_cells',
 'prepared_transform_activation_source_cells',
 'prepared_transform_product_activation_source_cells',
 'prepared_vertex_bevel_activation_source_cells',
 'prepared_vertex_extrude_activation_source_cells',
 'prepared_vertex_merge_activation_source_cells',
 'prepared_xfrm_activation_session_source_cells',
 'registry',
 'registry_source_cells',
 'remesh.region_stitch',
 'remesh.remesh_job',
 'vibe3d.util.screen_buckets.screen_buckets',
 'snap',
 'snap_render',
 'snap_render_source_cells',
 'snap_render_source_helpers',
 'vibe3d.util.spatial.spatial',
 'symmetry',
 'vibe3d.editing.interaction.data.tests.unit.ai.advisor_test',
 'tests.unit.ai.analysis_test',
 'vibe3d.editing.interaction.data.tests.unit.ai.debug_trace_test',
 'tests.unit.ai.element_candidates_test',
 'tests.unit.ai.exploration_source_public_test',
 'tests.unit.ai.exploration_test',
 'tests.unit.ai.interaction_log_test',
 'tests.unit.ai.interaction_log_writer_test',
 'vibe3d.editing.interaction.data.tests.unit.ai.interaction_test',
 'tests.unit.ai.mode_candidates_test',
 'tests.unit.ai.model_adapter_test',
 'tests.unit.ai.ranker_schema_test',
 'tests.unit.ai.support_loop_candidates_test',
 'tests.unit.ai.training_dataset_test',
 'tests.unit.ai3d.event_queue_source_public_test',
 'tests.unit.ai3d.event_queue_test',
 'tests.unit.ai3d.job_controller_test',
 'tests.unit.ai3d.scene_validator_test',
 'tests.unit.ai3d.stage_artifact_test',
 'tests.unit.ai3d.worker_manager_source_public_test',
 'tests.unit.ai3d.worker_manager_test',
 'tests.unit.alignment_ops_population_test',
 'tests.unit.application_core_population_test',
 'vibe3d.editing.params.tests.unit.argstring_test',
 'tests.unit.assimp_wire_test',
 'tests.unit.base_revert_flag_test',
 'vibe3d.platform.input.tests.unit.binding_resolve_test',
 'tests.unit.bvh_pick_test',
 'tests.unit.camera_intrinsics_test',
 'vibe3d.viewport.camera.tests.unit.camera_model_population_test',
 'tests.unit.camera_stamp_test',
 'tests.unit.close_reason_table_test',
 'tests.unit.command_apply_anchor_test',
 'tests.unit.command_bindargs_test',
 'tests.unit.command_history_source_public_test',
 'tests.unit.command_history_test',
 'tests.unit.command_invocation_test',
 'tests.unit.command_registry_test',
 'tests.unit.command_runtime_population_test',
 'tests.unit.command_source_public_test',
 'tests.unit.command_wrapper_result_test',
 'tests.unit.commands.image.commands_test',
 'tests.unit.commands.layer.add_injection_range_test',
 'tests.unit.commands.layer.commands_source_public_test',
 'tests.unit.commands.layer.xform_edit_source_public_test',
 'tests.unit.commands.mesh.edge_crease_source_public_test',
 'tests.unit.commands.mesh.edge_slide_result_builder_test',
 'tests.unit.commands.mesh.jitter_result_builder_test',
 'tests.unit.commands.mesh.remove_source_public_test',
 'tests.unit.commands.mesh.session_edit_source_public_test',
 'tests.unit.commands.mesh.symmetrize_source_public_test',
 'tests.unit.commands.mesh.vertex_set_source_public_test',
 'tests.unit.commands.select.boundary_source_public_test',
 'tests.unit.commands.select.by_stat_source_public_test',
 'tests.unit.commands.select.by_tag_source_public_test',
 'tests.unit.commands.select.element_source_public_test',
 'tests.unit.commands.select.type_from_source_public_test',
 'tests.unit.constraint_regression_test',
 'tests.unit.constraint_surface_at_test',
 'tests.unit.constraint_test',
 'tests.unit.deform_magnet_test',
 'tests.unit.dirty_key_camera_stamp_test',
 'tests.unit.dirty_key_tool_preview_test',
 'tests.unit.dirty_key_weightmap_test',
 'tests.unit.display_policy_population_test',
 'tests.unit.document_channels_population_test',
 'tests.unit.document_io_population_test',
 'vibe3d.documents.model.tests.unit.document_test',
 'tests.unit.drag_gain_oblique_test',
 'tests.unit.edge_slice_locate_base_test',
 'tests.unit.edit_session_test',
 'tests.unit.editor_commands_population_test',
 'vibe3d.platform.input.tests.unit.eventlog_parser_test',
 'vibe3d.platform.input.tests.unit.eventlog_test',
 'tests.unit.falloff_screen_default_test',
 'tests.unit.falloff_selection_bake_test',
 'tests.unit.falloff_test',
 'tests.unit.fixtures',
 'tests.unit.gesture_carrier_interface_test',
 'tests.unit.gesture_record_belt_test',
 'tests.unit.handles.gl_util_test',
 'tests.unit.image_cache_test',
 'vibe3d.documents.image_codec.tests.unit.image_codec_population_test',
 'tests.unit.image_plane_test',
 'vibe3d.platform.input.tests.unit.input_events_population_test',
 'vibe3d.documents.image_codec.tests.unit.io.image_decode_source_cells_test',
 'vibe3d.documents.image_codec.tests.unit.io.image_decode_test',
 'tests.unit.io.image_path_test',
 'tests.unit.io.lwo_export_ptag_census_test',
 'tests.unit.io.lwo_export_test',
 'tests.unit.io.lwo_import_test',
 'tests.unit.io.native_source_cells_test',
 'tests.unit.io.native_test',
 'vibe3d.util.json_number.tests.unit.json_num_test',
 'tests.unit.layer_params_test',
 'vibe3d.util.math.tests.unit.math_test',
 'vibe3d.mesh.ops.tests.unit.mesh_analysis_test',
 'tests.unit.mesh_by_value_gate',
 'vibe3d.mesh.ops.tests.unit.mesh_edge_slice_test',
 'vibe3d.mesh.edit_replay.tests.unit.mesh_edit_delta_test',
 'vibe3d.mesh.core.tests.unit.mesh_key_test',
 'vibe3d.mesh.snapshot.tests.unit.mesh_map_kind_snapshot_test',
 'vibe3d.mesh.core.tests.unit.mesh_map_kind_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.bevel_fin_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.bevel_vertex_test',
 'vibe3d.mesh.ops.tests.unit.mesh_ops.box_geom_corner_provenance_test',
 'tests.unit.mesh_ops.bridge_frozen_kernel_test',
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
 'vibe3d.mesh.contracts.tests.unit.mesh_plane_types_test',
 'vibe3d.mesh.edit_replay.tests.unit.mesh_selsets_replay_test',
 'vibe3d.mesh.snapshot.tests.unit.mesh_selsets_snapshot_test',
 'vibe3d.mesh.core.tests.unit.mesh_selsets_test',
 'vibe3d.mesh.core.tests.unit.mesh_topology_integration_test',
 'vibe3d.mesh.ops.tests.unit.mesh_wire_analysis_test',
 'vibe3d.mesh.snapshot.tests.unit.mesh_wire_snapshot_test',
 'tests.unit.model_preview_test',
 'vibe3d.mesh.preview.tests.unit.morph_routing_law_test',
 'vibe3d.editing.pipeline.contracts.tests.unit.operator_test',
 'tests.unit.ortho_relocate_prior_test',
 'tests.unit.overlay_space_test',
 'vibe3d.editing.params.tests.unit.param_cast_overflow_test',
 'vibe3d.editing.params.tests.unit.params_test',
 'tests.unit.path_test',
 'tests.unit.quad_overlay_eligibility_test',
 'tests.unit.record_observer_hub_source_public_test',
 'tests.unit.remesh.remesh_job_source_public_test',
 'tests.unit.retopology_display_model_test',
 'tests.unit.retopology_dot_cull_test',
 'tests.unit.retopology_line_shade_algorithm_cells_test',
 'tests.unit.retopology_order_algorithm_cells_test',
 'tests.unit.scene_query_population_test',
 'tests.unit.select_visibility_test',
 'tests.unit.selection_model_population_test',
 'tests.unit.selection_product_source_public_test',
 'tests.unit.selection_projection_algorithm_cells_test',
 'vibe3d.editing.contracts.tests.unit.seltype_test',
 'tests.unit.session_edit_payload_test',
 'tests.unit.session_mesh_key_stamp_as_test',
 'tests.unit.shared_hover_record_test',
 'tests.unit.snap_election_corpus_test',
 'tests.unit.snap_regression_test',
 'tests.unit.snap_test',
 'vibe3d.mesh.snapshot.tests.unit.snapshot_test',
 'vibe3d.util.spatial.tests.unit.spatial_test',
 'tests.unit.standalone_application_test',
 'tests.unit.subpatch_key_fold_test',
 'tests.unit.subpatch_level_policy_test',
 'tests.unit.subpatch_osd_test',
 'tests.unit.subpatch_preview_population_test',
 'tests.unit.symmetry_regression_test',
 'tests.unit.tool_gesture_runopen_test',
 'vibe3d.platform.input.tests.unit.tool_input_test',
 'tests.unit.tool_single_operation_equivalence_test',
 'tests.unit.tool_state_population_test',
 'tests.unit.toolpipe.local_component_frame_test',
 'tests.unit.toolpipe.obbox_regression_test',
 'tests.unit.toolpipe.obbox_test',
 'vibe3d.editing.pipeline.contracts.tests.unit.toolpipe.packets_test',
 'tests.unit.toolpipe.pipeline_order_test',
 'tests.unit.toolpipe.pipeline_registration_test',
 'tests.unit.toolpipe.prepared_stage_regression_test',
 'tests.unit.toolpipe.required_packets_witness_test',
 'tests.unit.toolpipe.snap_stage_regression_test',
 'tests.unit.toolpipe.stages.actcenter_test',
 'tests.unit.toolpipe.stages.axis_test',
 'tests.unit.toolpipe.stages.falloff_test',
 'tests.unit.toolpipe.stages.snap_test',
 'tests.unit.toolpipe.stages.symmetry_test',
 'tests.unit.toolpipe.stages.workplane_test',
 'tests.unit.toolpipe.view_only_subject_pin_test',
 'tests.unit.tools.alignment.align_kernels_test',
 'tests.unit.tools.alignment.mirror_test',
 'tests.unit.tools.common.session_mesh_key_test',
 'tests.unit.tools.create.arc_test',
 'tests.unit.tools.create.box_test',
 'tests.unit.tools.create.create_common_test',
 'tests.unit.tools.create.pen_geometry_population_test',
 'tests.unit.tools.create.pen_geometry_test',
 'tests.unit.tools.create.tube_test',
 'tests.unit.tools.edit.preview_rebuild_test',
 'tests.unit.tools.edit.preview_topology_churn_test',
 'tests.unit.tools.edit.smooth_relax_test',
 'tests.unit.tools.edit.tack_test',
 'tests.unit.tools.slice.edge_slice_tool_test',
 'tests.unit.tools.slice.loop_slice_tool_test',
 'tests.unit.tools.slice.slice_tool_test',
 'tests.unit.tools.transform.arcball_regression_test',
 'tests.unit.tools.transform.arcball_test',
 'tests.unit.tools.transform.item_xform_kernels_test',
 'tests.unit.tools.transform.item_xform_regression_test',
 'tests.unit.tools.transform.morph_route_test',
 'tests.unit.tools.transform.rotate_test',
 'tests.unit.tools.transform.scale_input_test',
 'tests.unit.tools.transform.transform_ops_population_test',
 'tests.unit.tools.transform.transform_test',
 'tests.unit.tools.transform.xform_kernels_test',
 'tests.unit.topology_step_mixin_test',
 'vibe3d.mesh.ops.tests.unit.uv_island_test',
 'vibe3d.mesh.ops.tests.unit.uv_project_test',
 'vibe3d.mesh.ops.tests.unit.uv_relax_test',
 'vibe3d.mesh.ops.tests.unit.uv_transform_test',
 'vibe3d.mesh.ops.tests.unit.uv_unwrap_test',
 'vibe3d.mesh.ops.tests.unit.uv_weld_test',
 'tests.unit.vertex_normals_test',
 'vibe3d.viewport.camera.tests.unit.view_source_cells_test',
 'vibe3d.viewport.camera.tests.unit.view_test',
 'tests.unit.viewgrid_regression_test',
 'tests.unit.viewgrid_test',
 'tests.unit.viewport_env_test',
 'tests.unit.viewport_gpu_population_test',
 'tests.unit.viewport_plane_turn_test',
 'tests.unit.viewport_scheme_test',
 'tests.unit.viewport_test',
 'tests.unit.weightmap_state_test',
 'tests.unit.workplane_fit_test',
 'tests.unit.wrapper_shift_apply_inheritance_test',
 'tool',
 'tool_disarm_source_cells',
 'vibe3d.platform.input.tool_input',
 'tool_presets_source_cells',
 'toolpipe.stages.actcenter',
 'toolpipe.stages.axis',
 'toolpipe.stages.constrain',
 'toolpipe.stages.falloff',
 'toolpipe.stages.snap',
 'tools.alignment.align_kernels',
 'tools.alignment.mirror',
 'tools.common.command_wrapper',
 'tools.common.session_mesh_key',
 'tools.create.arc',
 'tools.create.box',
 'tools.create.create_common_source_cells',
 'tools.create.pen',
 'tools.create.sphere',
 'tools.edit.bridge_tool',
 'tools.edit.bridge_tool_source_cells',
 'tools.edit.edge_extend_source_cells',
 'tools.edit.edge_extrude',
 'tools.edit.poly_bevel',
 'tools.edit.poly_extrude',
 'tools.edit.tack',
 'tools.edit.topology_pen.move_protocol_test',
 'tools.edit.topology_pen.press_compatibility_test',
 'tools.slice.slice_tool',
 'tools.transform.relocate_plane_test',
 'tools.transform.rotate',
 'tools.transform.transform',
 'tools.transform.xfrm_transform',
 'vibe3d.util.spatial.trackball',
 'ui.viewport_render',
 'unit.bevel_cold_arm_param_image_test',
 'unit.prepared_param_update_test',
 'unit.prepared_tool_transition_test'])

ENABLED_MODULES = ENABLED_MODULES | frozenset(['forms_source_test', 'render_backends_population_test', 'vibe3d.render.model.render_model_population_test', 'tests.unit.ui.channel_rows_test', 'tests.unit.ui.command_notice_test', 'tests.unit.ui.stat_rows_test', 'ui.availability_source_test', 'ui.image_rows', 'ui.item_click_source_test', 'ui.item_rows'])

def validate_runtime(output, owner):
    totals=re.findall(r'^(\d+) modules passed unittests$',output,re.M)
    require(len(totals)==1 and int(totals[0])>0,'NO-VERDICT: support nonzero druntime total')
    roster=re.findall(r'^PKG-MODULE name=(\S+) unittest=([01])$',output,re.M)
    require(roster and len(roster)==len(set(n for n,_ in roster)),'NO-VERDICT: support runtime roster identity')
    # Every explicit own/lower production input and every public carrier occurs
    # once; private/public enabled identities keep their original guards.
    own={compiler_module(p) for p in SPECS[owner]['testSources'] if p.endswith('.d')}
    for selected in closure(owner,True)|{owner}:
        modules={compiler_module(p) for p in SPECS[selected]['sources'] + SPECS[selected].get('testHelpers', []) + (SPECS[selected].get('transitionalSources', []) if selected!=owner else []) if p.endswith('.d')}
        if selected==owner:modules |= own
        for module in modules:
            require(sum(name==module for name,_ in roster)==1,
                    'support runtime production/carrier owner exactly once: '+module)
        enabled={name for name,flag in roster if name in modules and flag=='1'}
        require(enabled==modules&ENABLED_MODULES, 'support runtime enabled identity: '+selected)
    require(sum(f=='1' for _,f in roster)==int(totals[0]),'support runtime executed roster total')
    if owner=='mesh-snapshot':
        require(output.count('MeshSnapshotFixtures: adjacency restore and keep-selection cells passed')==1,
                'support mapped private snapshot cell execution')
    return {'modules':int(totals[0]),'roster':roster}


def stage_dependencies(active, archive, evidence, env, renderer=False):
    home = evidence / 'dub-home'
    home.mkdir()
    env['DUB_HOME'] = str(home)
    receipts = {}
    for name, package in active.items():
        if is_internal(name):
            continue
        original = Path(package['path']).resolve()
        staged = (archive/'third_party/nfde' if name=='nfde' else
                  home / 'packages' / name / REVISIONS[name][0] / name
                  if name in REVISIONS else archive / 'dependencies' / name)
        # The local chooser source is already in the exact committed archive.
        # Fresh native outputs are built only in that owned copy.
        if name=='nfde':require(staged.is_dir(), 'PREPARATION-REFUSED: committed native chooser source missing')
        else:
            # Task20262890: the pinned Assimp hook declares root build-min as
            # generated native output; keep its CMake cache out of Source custody
            # (doc/library_layout_wave16_composition_source_custody_2026-10-14.md).
            shutil.copytree(original, staged, ignore=lambda directory, names: shutil.ignore_patterns(
                '.git', '.dub', 'build', 'out', '*.a', '*.o', '*.obj', '*.lib',
                *(('*.so*', '*.dylib*', '*.dll', 'build_cycles') if renderer else ()),
                *(('build-min',) if name=='bindbc-assimp6' and Path(directory)==original else ()))(directory, names))
        native_files = {}
        if renderer:
            receipt=json.loads((evidence/'native-input-receipt.json').read_text())
            items=receipt['packages'][name]['artifacts']
            relatives={item['relative'] for item in items}
            for item in items:
                relative=Path(item['relative']);source=original/relative;target=staged/relative
                require(not relative.is_absolute() and '..' not in relative.parts
                        and source.is_file() and legacy_digest(source)==item['sha256'],
                        'PREPARATION-REFUSED: renderer native artifact staging identity: '+name)
                target.parent.mkdir(parents=True,exist_ok=True)
                if target.is_symlink() or target.exists():target.unlink()
                if source.is_symlink():
                    link=os.readlink(source)
                    require(item.get('symlink')==link and not Path(link).is_absolute()
                            and os.path.normpath(str(relative.parent/link)) in relatives,
                            'PREPARATION-REFUSED: renderer native symlink closure: '+name)
                    target.symlink_to(link)
                else:
                    require(item.get('symlink') is None, 'PREPARATION-REFUSED: renderer native symlink identity: '+name)
                    shutil.copy2(source,target)
                native_files[str(relative)]={'original':str(source),'sha256':item['sha256'],
                    'symlink':os.readlink(source) if source.is_symlink() else None}
        files = {str(p.relative_to(staged)): legacy_digest(p) for p in sorted(staged.rglob('*')) if p.is_file()}
        legacy_require(files and 'dub.json' in files, 'PREPARATION-REFUSED: dependency source missing: ' + name)
        for relative, sha in files.items():
            legacy_require(legacy_digest(original / relative) == sha, 'PREPARATION-REFUSED: dependency staging changed: ' + name)
        if name in REVISIONS:
            revision = legacy_native_revision(original)
            legacy_require(revision == REVISIONS[name][0], 'PREPARATION-REFUSED: native source revision: ' + name)
            (staged / '.boundary-revision').write_text(revision + '\n')
        if name in ('bindbc-assimp6', 'd_imgui') and not renderer:
            # The unchanged native hook names its existing submodule explicitly.
            # Preserve independent local metadata so it observes the frozen gitlink.
            metadata = original / '.git'
            require(metadata.is_dir() and not (metadata / 'objects/info/alternates').exists(),
                    'PREPARATION-REFUSED: Assimp independent Git metadata')
            shutil.copytree(metadata, staged / '.git')
            children = [Path('extern/assimp')] if name == 'bindbc-assimp6' else [Path('extern/cimgui'), Path('extern/cimgui/imgui')]
            for child in children:
                (staged / child / '.git').write_bytes((original / child / '.git').read_bytes())
            git_provenance = {}
            for suffix in (Path('.'), *children):
                def git_value(root, args):
                    return subprocess.check_output(['git', '-C', str(root / suffix)] + args, text=True).strip()
                source_head = git_value(original, ['rev-parse', 'HEAD'])
                source_tree = git_value(original, ['rev-parse', 'HEAD^{tree}'])
                require(git_value(staged, ['rev-parse', 'HEAD']) == source_head and
                        git_value(staged, ['rev-parse', 'HEAD^{tree}']) == source_tree,
                        'PREPARATION-REFUSED: Assimp staged Git identity')
                gitdir = Path(git_value(staged, ['rev-parse', '--absolute-git-dir'])).resolve()
                require(gitdir.is_relative_to(staged.resolve()),
                        'PREPARATION-REFUSED: Assimp foreign Git metadata')
                git_provenance[str(suffix)] = {'head': source_head, 'tree': source_tree, 'gitdir': str(gitdir)}
            gitlinks = {}
            for child in children:
                parent = child.parent if child == Path('extern/cimgui/imgui') else Path('.')
                relative = str(child.relative_to(parent))
                gitlink = subprocess.check_output(['git', '-C', str(original/parent), 'ls-files', '--stage', relative], text=True)
                require(gitlink == subprocess.check_output(['git', '-C', str(staged/parent), 'ls-files', '--stage', relative], text=True),
                        'PREPARATION-REFUSED: native staged gitlink: '+name+':'+str(child))
                gitlinks[str(child)] = gitlink.strip()
            if name == 'bindbc-assimp6':
                git_provenance['gitlink'] = gitlinks['extern/assimp']
            else:
                git_provenance['gitlinks'] = gitlinks
            (evidence / ('assimp-git-provenance.json' if name == 'bindbc-assimp6' else 'imgui-git-provenance.json')).write_text(json.dumps(git_provenance, indent=2))
        else:
            if renderer:run(['git','init','-q',str(staged)],archive,env,evidence,'initialize-'+name,renderer_kind='initialize')
            else:legacy_run(['git', 'init', '-q', str(staged)], archive, env, evidence, 'initialize-' + name)
        if renderer:run(['dub','add-local',str(staged),package['version']],archive,env,evidence,'register-'+name,renderer_kind='register')
        else:legacy_run(['dub', 'add-local', str(staged), package['version']], archive, env, evidence, 'register-' + name)
        receipts[name] = {'original': str(original), 'staged': str(staged), 'version': package['version'], 'files': files}
        if renderer:receipts[name]['nativeArtifacts']=native_files
    (evidence / 'dependency-sources.json').write_text(json.dumps(receipts, indent=2))
    return receipts

def run(command,cwd,env,evidence,name,renderer_kind=None):
    if renderer_kind is not None:
        tool = Path(command[0]).name
        allowed = ((renderer_kind == 'describe' and tool == 'dub' and len(command) > 1 and command[1] == 'describe')
            or (renderer_kind == 'register' and tool == 'dub' and len(command) == 4 and command[1] == 'add-local')
            or (renderer_kind == 'initialize' and tool == 'git' and len(command) == 4 and command[1:3] == ['init','-q'])
            or (renderer_kind in ('archive', 'compile', 'link') and tool in ('dmd', 'ldc2', 'ldc'))
            or (renderer_kind == 'algorithm-run' and len(command) == 1
                and Path(command[0]).is_absolute() and Path(command[0]).resolve().is_relative_to((evidence/'archive').resolve())))
        require(allowed, 'PREPARATION-REFUSED: renderer construction invocation: '+str(renderer_kind)+':'+tool)
    record={'argv':command,'cwd':str(cwd)}
    if renderer_kind is not None:record.update(environment=env,rendererKind=renderer_kind)
    (evidence/(name+'.command.json')).write_text(json.dumps(record,indent=2))
    result=subprocess.run(command,cwd=cwd,env=env,text=True,capture_output=True)
    (evidence/(name+'.stdout.log')).write_text(result.stdout)
    (evidence/(name+'.stderr.log')).write_text(result.stderr)
    record['exit']=result.returncode
    (evidence/(name+'.command.json')).write_text(json.dumps(record,indent=2))
    if renderer_kind in ('archive','compile','link'):
        command_log='[cwd='+str(cwd)+'] '+shlex.join(command)+'\n'+result.stdout+result.stderr
        (evidence/(name+'.compiler.log')).write_text(command_log)
        compiler_commands(command_log,cwd)

    require(result.returncode==0,'support command failed: '+name+': '+next((s for s in (result.stdout+result.stderr).splitlines() if 'Error:' in s or 'AssertError@' in s),'see logs'))
    return result

def describe(project,owner,config,compiler,env,evidence,tests=False,recipe=None,harness=None):
    root=project/SPECS[owner]['root']/('tests' if tests else '')
    command=['dub','describe']+(['--root='+str(root)] if tests else ordinary_arguments(project,owner))+['--config='+config,'--compiler='+compiler,'--quiet']
    if recipe:command+=['--recipe='+str(recipe)]
    name=config+('-tests' if tests else '')+('-receipt' if recipe else '')
    result=run(command,project,env,evidence,name);description=json.loads(result.stdout)
    validate_description(description,project,owner,config,tests,harness,compiler)
    (evidence/(name+'.json')).write_text(json.dumps(description,indent=2))
    return description

def renderer_native_receipt(project, compiler, evidence, active, direct_owner=None):
    import platform
    path=evidence/'native-input-receipt.json'
    require(path.is_file(), 'PREPARATION-REFUSED: renderer native-input-receipt.json missing')
    receipt=json.loads(path.read_text())
    require(receipt['schema']=='vibe3d-render-native-input-v1' and receipt['producer']
            and receipt['construction']['exit']==0 and receipt['construction']['argv']
            and isinstance(receipt['construction']['environment'],dict),
            'PREPARATION-REFUSED: successful original native construction provenance')
    require(platform.system()=='Linux' and receipt['host']['arch']==platform.machine() and receipt['host']['system']==platform.system(),
            'PREPARATION-REFUSED: renderer native target/host')
    # Wave17: entry binds compiler/target identity; direct D construction and the
    # algorithm run below witness their own ABI scope. Loader/session/PBO/callback
    # acceptance stays later; no future compatibility boolean admits phase0
    # (doc/library_layout_wave17_native_provision_admission_2026-10-15.md).
    require(receipt['abi']['dCompilerSha256']==legacy_digest(Path(compiler))
            and receipt['abi']['dTarget'] and receipt['abi']['nativeTarget']==receipt['abi']['dTarget'],
            'PREPARATION-REFUSED: renderer native compiler/target identity')
    require(receipt['mode']['configuration']=='Release' and receipt['mode']['WITH_CYCLES'] is True
            and receipt['mode']['rpr']=='dynamic' and receipt['mode']['backendConfiguration'],
            'PREPARATION-REFUSED: renderer native Release/WITH_CYCLES/RPR mode')
    require(isinstance(receipt['abi']['dCompilerConfigInputs'],list)
            and isinstance(receipt['abi']['dCompilerConfigAbsent'],list),
            'PREPARATION-REFUSED: renderer D compiler configuration provenance')
    for item in receipt['abi']['dCompilerConfigInputs']:
        require(Path(item['path']).is_file() and legacy_digest(Path(item['path']))==item['sha256'],
                'PREPARATION-REFUSED: renderer D compiler configuration identity')
    for path in receipt['abi']['dCompilerConfigAbsent']:
        require(not Path(path).exists(), 'PREPARATION-REFUSED: renderer D compiler configuration absence')
    external={name:p for name,p in active.items() if not is_internal(name,direct_owner) and name!='vibe3d'}
    require(set(receipt['packages'])==set(external), 'PREPARATION-REFUSED: renderer native dependency receipt population')
    for name, package in external.items():
        record=receipt['packages'][name];root=Path(package['path']).resolve()
        native=name in {'d-cycles','bindbc-rpr','nfde','d_imgui','d-stb-image','d-opensubdiv','d-bvh','bindbc-assimp6','d-onnxruntime'}
        origin=record.get('origin','source-built')
        prebuilt=origin=='prebuilt-distribution'
        require(origin=='source-built' or (prebuilt and name=='bindbc-rpr'
                and package['configuration']=='dynamic'),
                'PREPARATION-REFUSED: renderer native origin variant: '+name)
        require(record['tree'] and isinstance(record['gitlinks'],dict) and record['inputs']
                and (not native or (record['headers'] and record['nativeCompiler']['identity'] and record['linker']['identity']))
                and isinstance(record['generatedConfigurations'],list),
                'PREPARATION-REFUSED: renderer complete native used-input provenance: '+name)
        if name in REVISIONS:
            require(record['revision']==REVISIONS[name][0], 'PREPARATION-REFUSED: renderer recorded source revision: '+name)
        require(record['recipeSha256']==legacy_digest(root/'dub.json'), 'PREPARATION-REFUSED: renderer recorded recipe: '+name)
        for relative,digest in RENDER_SOURCE_PINS.get(name,{}).items():
            require((root/relative).is_file() and legacy_digest(root/relative)==digest,
                    'PREPARATION-REFUSED: renderer frozen Source/header pin: '+name+':'+relative)
        # Wave17 phase0 admission: only the pinned dynamic SDK has vendor
        # distribution provenance; source-built tools/construction stay mandatory
        # (doc/library_layout_wave17_native_provision_admission_2026-10-15.md).
        if prebuilt:
            require(record['construction']=={'status':'prebuilt-distribution', 'originalBuild':'undisclosed by vendor'}
                    and all(record[tool]=={'identity':'undisclosed by vendor'} for tool in ('nativeCompiler','linker')),
                    'PREPARATION-REFUSED: renderer prebuilt historical provenance')
            distribution=record['distribution']
            sdk_relative='extern/RadeonProRenderSDK';sdk=root/sdk_relative
            revision='e8353e0588f07a836321823c6ef81f338ff28bc2'
            subtree='RadeonProRender/binUbuntu20';tree='a52ae4faa76e4ad90491b66da6b838e4761875bb'
            require(distribution['publisher']=='GPUOpen-LibrariesAndSDKs'
                    and distribution['repository']=='https://github.com/GPUOpen-LibrariesAndSDKs/RadeonProRenderSDK.git'
                    and distribution['revision']==revision and distribution['tree']==tree
                    and record['gitlinks'].get(sdk_relative)==revision and (root/'.git').exists()
                    and subprocess.check_output(['git','ls-tree','HEAD','--',sdk_relative],cwd=root,text=True).strip()
                        =='160000 commit '+revision+'\t'+sdk_relative
                    and subprocess.check_output(['git','rev-parse','HEAD'],cwd=sdk,text=True).strip()==revision
                    and subprocess.check_output(['git','rev-parse',revision+':'+subtree],cwd=sdk,text=True).strip()==tree,
                    'PREPARATION-REFUSED: renderer pinned prebuilt distribution origin')
            rows=subprocess.check_output(['git','ls-tree','-rl',revision,'--',subtree],cwd=sdk,text=True).splitlines()
            members={}
            inputs={str(Path(item['path'])):item['sha256'] for item in record['inputs']}
            require(len(rows)==9, 'PREPARATION-REFUSED: renderer prebuilt distribution population')
            for row in rows:
                metadata,relative=row.split('\t');mode,kind,blob,size=metadata.split()
                source=sdk/relative
                require(mode=='100644' and kind=='blob' and relative not in members
                        and Path(relative).parent==Path(subtree) and source.is_file() and not source.is_symlink()
                        and not source.stat().st_mode & 0o111 and source.stat().st_size==int(size)
                        and subprocess.check_output(['git','hash-object','--no-filters','--',str(source)],cwd=sdk,text=True).strip()==blob
                        and inputs.get(str(source))==legacy_digest(source),
                        'PREPARATION-REFUSED: renderer prebuilt distribution member: '+relative)
                members[relative]=blob
            required={subtree+'/libRadeonProRender64.so':'0793cb86649c2e4dfa961a9d758ae6a8d19bdaa0',
                      subtree+'/libNorthstar64.so':'aadc3da73e01e2b8d75a21c3bf01ae2f617aacf4'}
            artifacts={str(root/item['relative']):item for item in record['artifacts']}
            require(all(members.get(relative)==blob and str(sdk/relative) in artifacts for relative,blob in required.items())
                    and len(artifacts)==len(record['artifacts']),
                    'PREPARATION-REFUSED: renderer required prebuilt artifacts')
            runtime=distribution['runtimeClosure']
            paths={item['path']:item for item in runtime}
            require(len(paths)==len(runtime) and all(str(sdk/relative) in paths for relative in required),
                    'PREPARATION-REFUSED: renderer prebuilt runtime closure population')
            for source_path,item in paths.items():
                source=Path(source_path)
                require(source.is_absolute() and source_path==os.path.normpath(source_path)
                        and source.is_file() and inputs.get(source_path)==item['sha256']
                        and legacy_digest(source)==item['sha256'] and item['target']==receipt['abi']['nativeTarget']
                        and item['elf']['class']=='ELF64' and item['elf']['machine']=='Advanced Micro Devices X86-64'
                        and (item['elf']['osabi']=='UNIX - System V'
                            or (not source.is_relative_to(sdk) and item['elf']['osabi']=='UNIX - GNU'
                                and any(system['path']==source_path and system['sha256']==item['sha256']
                                        for system in receipt.get('systemInputs',[]))))
                        and item['elf']['soname']
                        and isinstance(item['elf']['needed'],list) and isinstance(item['dependencies'],dict)
                        and set(item['elf']['needed'])==set(item['dependencies']),
                        'PREPARATION-REFUSED: renderer prebuilt runtime input/target: '+source_path)
                witness=item['elfEvidence'];witness_path=Path(witness['path'])
                require(witness_path.is_file() and legacy_digest(witness_path)==witness['sha256'],
                        'PREPARATION-REFUSED: renderer prebuilt ELF evidence identity: '+source_path)
                observed=json.loads(witness_path.read_text())
                require(observed['exit']==0 and observed['sourceSha256']==item['sha256']
                        and len(observed['argv'])==4 and Path(observed['argv'][0]).name=='readelf'
                        and observed['argv'][1:]==['-h','-d',source_path]
                        and all(re.search(r'^\s*'+label+r':\s*'+re.escape(item['elf'][key])+r'\s*$',observed['stdout'],re.M)
                                for label,key in (('Class','class'),('Machine','machine'),('OS/ABI','osabi')))
                        and re.findall(r'\(SONAME\).*?\[([^]\n]+)\]',observed['stdout'])==[item['elf']['soname']]
                        and re.findall(r'\(NEEDED\).*?\[([^]\n]+)\]',observed['stdout'])==item['elf']['needed'],
                        'PREPARATION-REFUSED: renderer prebuilt observed ELF closure: '+source_path)
                require((not source.is_symlink() and item.get('symlink') is None)
                        or (source.is_symlink() and item.get('symlink')==os.readlink(source)
                            and (not source.is_relative_to(sdk) or not Path(item['symlink']).is_absolute())
                            and os.path.normpath(str(source.parent/item['symlink'])) in paths),
                        'PREPARATION-REFUSED: renderer prebuilt runtime symlink closure: '+source_path)
                for dependency,target in item['dependencies'].items():
                    require(target in paths and paths[target]['elf']['soname']==dependency,
                            'PREPARATION-REFUSED: renderer prebuilt runtime dependency closure: '+dependency)
                if source.is_relative_to(sdk):
                    require(str(source.relative_to(sdk)) in members and source_path in artifacts,
                            'PREPARATION-REFUSED: renderer foreign/unstaged prebuilt SDK dependency')
            reached=set();pending=[str(sdk/relative) for relative in required]
            while pending:
                selected=pending.pop()
                if selected in reached:continue
                reached.add(selected);item=paths[selected];pending.extend(item['dependencies'].values())
                if item.get('symlink'):pending.append(os.path.normpath(str(Path(selected).parent/item['symlink'])))
            require(reached==set(paths)
                    and set(artifacts)=={p for p in paths if Path(p).is_relative_to(sdk)},
                    'PREPARATION-REFUSED: renderer exact consumed prebuilt SDK closure')
        if native and not prebuilt:
            require(record['construction']['exit']==0 and record['construction']['argv']
                    and isinstance(record['construction']['environment'],dict),
                    'PREPARATION-REFUSED: renderer original native package construction: '+name)
            for tool in ('nativeCompiler','linker'):
                identity=record[tool]
                require(identity['target']==receipt['abi']['nativeTarget'] and identity['identity']
                        and Path(identity['path']).is_file() and legacy_digest(Path(identity['path']))==identity['sha256'],
                        'PREPARATION-REFUSED: renderer original native tool/target identity: '+name+':'+tool)
        if (root/'.git').exists():
            require(record['tree']==subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=root,text=True).strip(),
                    'PREPARATION-REFUSED: renderer source tree identity: '+name)
            for relative,revision in record['gitlinks'].items():
                require(subprocess.check_output(['git','rev-parse','HEAD'],cwd=root/relative,text=True).strip()==revision,
                        'PREPARATION-REFUSED: renderer native gitlink identity: '+name+':'+relative)

        for group in ('inputs','headers','generatedConfigurations'):
            for item in record[group]:
                source=Path(item['path'])
                require(source.is_file() and legacy_digest(source)==item['sha256'],
                        'PREPARATION-REFUSED: renderer used native '+group+': '+str(source))
        for item in record['artifacts']:
            relative=Path(item['relative']);source=root/relative
            require(not relative.is_absolute() and '..' not in relative.parts and source.is_file()
                    and legacy_digest(source)==item['sha256'], 'PREPARATION-REFUSED: renderer native artifact identity: '+name)
        require(record['artifacts'] or not native,
                'PREPARATION-REFUSED: renderer native artifacts missing: '+name)
    require('BindRPR_Static' not in {v for package in active.values() for v in package.get('versions',[])},
            'PREPARATION-REFUSED: renderer static RPR mode')
    return receipt


def renderer_description(description, project, owner, config, tests=False, harness=None):
    active_list=[p for p in description['packages'] if p.get('active')]
    active={p['name']:p for p in active_list}
    require(len(active)==len(active_list), 'support renderer active package identity')
    direct_owner=owner if owner!='app' and not tests else None
    root_name='vibe3d' if owner=='app' else (test_name(owner) if tests else SPECS[owner]['name'].split(':')[-1])
    require(description['rootPackage']==root_name, 'support renderer resolved root identity')
    for name, package in active.items():
        path=Path(package['path']).resolve()
        require(path.is_relative_to(project) or not is_internal(name,direct_owner), 'support renderer internal owner path')
        if is_internal(name,direct_owner) or name==root_name:
            if owner=='app' and name==root_name:
                expected=[(project/p).resolve() for p in APP_SOURCES]
            else:
                selected=internal_owner(name,direct_owner)
                spec=SPECS[selected]
                own=spec['testSources'] if name.endswith('-tests') else spec['sources']+spec.get('transitionalSources', [])
                expected=[(path/p).resolve() for p in own]
                if not name.endswith('-tests') and package['configuration'] in ('root-tests','isolated-tests'):
                    expected+=test_helper_files(project,selected)
                if name.endswith('-tests') and harness is not None:
                    expected.append(harness.resolve())
                    generated=Path(json.loads((path/'dub.boundary.json').read_text())['mainSourceFile'])
                    require(generated.name=='dub_test_root.d' and generated.read_bytes()==b'module dub_test_root;\nvoid main() {}\n', 'support renderer generated main identity')
                    expected.append(generated.resolve())
            actual=[(path/f['path']).resolve() for f in package['files'] if f['role']=='source']
            require(sorted(actual)==sorted(expected) and len(actual)==len(set(actual)), 'support renderer exact physical owner inputs: '+name)
            raw,cfg=raw_config(path,package['configuration'])
            declared=set(raw.get('dependencies',{}))|set(cfg.get('dependencies',{}))
            require(set(package.get('dependencies',[]))==declared, 'support renderer direct dependency DAG: '+name)
            require(not any(package.get(field) for field in HOOKS), 'support renderer internal hook: '+name)
        else:validate_external(package)
    required={'render-model':['source/vibe3d/render/model/render/backend.d','source/vibe3d/render/model/render/scene.d'],
              'render-backends':['source/render/backend_bridge.d','source/render/cycles_backend.d','source/render/render_diff.d','source/render/rpr_backend.d']}
    for selected in ('render-model','render-backends') if owner in ('render-backends','app') else ('render-model',):
        package=active[root_name] if selected==owner else active[SPECS[selected]['name']]
        require('WithRender' in package.get('versions',[]), 'support renderer active WithRender: '+selected)
        actual=[(Path(package['path'])/f['path']).resolve() for f in package['files'] if f['role']=='source']
        for relative in required[selected]:
            require(actual.count((project/SPECS[selected]['root']/relative).resolve())==1,
                    'support renderer independent member: '+selected+':'+relative)
    targets={t['rootPackage']:t for t in description['targets']}
    require(len(targets)==len(description['targets']) and set(targets)=={n for n,p in active.items() if p['targetType']!='sourceLibrary'},
            'support renderer exact target population')
    for name,target in targets.items():
        seen=set()
        def visit(n):
            if n in seen:return
            seen.add(n)
            for dep in active[n].get('dependencies',[]):visit(dep)
        visit(name)
        inputs=[]
        for n in {name}|{n for n in seen if active[n]['targetType']=='sourceLibrary'}:
            package=active[n];path=Path(package['path'])
            inputs.extend(str((path/f['path']).resolve()) for f in package['files'] if f['role']=='source')
        actual=[str(Path(p).resolve()) for p in target['buildSettings']['sourceFiles']]
        require(sorted(actual)==sorted(inputs) and len(actual)==len(set(actual)), 'support renderer merged target source identity: '+name)
        expected_archives=[]
        for n in seen-{name}:
            if active[n]['targetType'] not in ('library','staticLibrary'):continue
            expected_archives.append(str((Path(active[n]['path'])/(ARCHIVES[n] if n in ARCHIVES else archive_name(internal_owner(n)))).resolve()))
        require(sorted(target['buildSettings'].get('linkerFiles',[]))==sorted(expected_archives), 'support renderer exact D archive inputs: '+name)
        roots={n:Path(active[n]['path']).resolve() for n in seen}
        libs,lflags=native_grants(seen,roots)
        settings=target['buildSettings']
        require(set(settings.get('libs',[]))==libs and set(settings.get('lflags',[]))==lflags,
                'support renderer resolved native link settings: '+name)
        for native in seen & set(RENDER_NATIVE):
            raw=json.loads((roots[native]/'dub.json').read_text())
            expected=[value.replace('$$ORIGIN','$ORIGIN').replace('$PACKAGE_DIR',str(roots[native]))
                      for value in raw.get('lflags-linux',raw.get('lflags',[]))]
            actual=settings.get('lflags',[])
            require(expected and any(actual[i:i+len(expected)]==expected
                                     for i in range(len(actual)-len(expected)+1)),
                    'support renderer ordered retained native flags: '+name+':'+native)

    return active


def renderer_describe(project,owner,config,compiler,env,evidence,tests=False,recipe=None,harness=None,data=None):
    root=project if owner=='app' else project/SPECS[owner]['root']/('tests' if tests else '')
    build='unittest' if tests else 'debug'
    command=['dub','describe','--root='+str(root),'--config='+config,'--compiler='+compiler,
             '--build='+build,'--nodeps','--skip-registry=all','--quiet']
    if recipe is not None:command+=['--recipe='+str(recipe)]
    if data is not None:command+=['--data='+data]
    name=('app' if owner=='app' else owner)+('-tests' if tests else '')+('-data-'+data.replace(',','-') if data else '-description')
    result=run(command,project,env,evidence,name,renderer_kind='describe')
    if data is not None:return shlex.split(result.stdout)
    description=json.loads(result.stdout)
    renderer_description(description,project,owner,config,tests,harness)
    (evidence/(name+'.json')).write_text(json.dumps(description,indent=2))
    return description


def renderer_expected_links(settings, root, env, evidence, label):
    # Task20262930: match DUB1.41 resolveLibs/BuildSettings.addDFlags, retaining
    # raw operands separately (doc/library_layout_wave17_plan_2026-10-14.md).
    libraries=list(settings.get('libs',[]))
    native=[];queries=[]
    def query(arguments):
        command=['pkg-config']+arguments
        result=subprocess.run(command,cwd=root,env=env,text=True,capture_output=True)
        queries.append({'argv':command,'exit':result.returncode,
                        'stdout':result.stdout,'stderr':result.stderr})
        return result
    def partition(values, prefix):
        # std.algorithm.partition's default dynamic-array Hoare partition.
        values=list(values);lo=0;hi=len(values)-1
        while lo<=hi:
            while lo<=hi and query(['--exists',prefix+values[lo]]).returncode!=0:lo+=1
            if lo>hi:break
            while lo<hi and query(['--exists',prefix+values[hi]]).returncode==0:hi-=1
            if lo==hi:break
            values[lo],values[hi]=values[hi],values[lo];lo+=1;hi-=1
        return values[:lo],values[lo:]
    # describe's libs formatter forces TargetType.none even for static targets.
    if libraries:
        libraries,modules=partition(libraries,'')
        libraries,prefixed=partition(libraries,'lib')
        modules+=['lib'+name for name in prefixed]
        if modules:
            result=query(['--libs']+modules)
            require(result.returncode==0, 'PREPARATION-REFUSED: renderer pkg-config native flags: '+label)
            for value in result.stdout.split():
                if value.startswith('-L-L'):native.append(value[2:])
                elif value.startswith(('-defaultlib','-L-defaultlib')):
                    continue # resolveLibs adds these to dflags, not native operands.
                elif value.startswith('-pthread'):native.append('-lpthread')
                elif value.startswith('-L-l'):native+=value[2:].split(',')
                elif value.startswith('-Wl,'):native+=value[4:].split(',')
                else:native.append(value)
        native+=['-l'+library for library in libraries]
    # describe formats lflags and libs separately: addDFlags uniquifies only
    # adjacent raw lflags. The libs result and the field boundary retain repeats.
    expected=[]
    for value in settings.get('lflags',[]):
        if value and (not expected or expected[-1]!=value):expected.append(value)
    expected+=[value for value in native if value]
    (evidence/(label+'-native-format-expectation.json')).write_text(json.dumps({
        'rawLflags':settings.get('lflags',[]),'rawLibs':settings.get('libs',[]),
        'cwd':str(root),'environment':env,
        'pkgConfigQueries':queries,'expectedNativeOperands':expected},indent=2))
    return expected


def renderer_compile_target(description, target, compiler, env, evidence, label, tests=False):
    settings=target['buildSettings'];sources=[str(Path(p).resolve()) for p in settings['sourceFiles']]
    require(sources and len(sources)==len(set(sources)), 'support renderer nonempty unique source vector: '+label)
    active={p['name']:p for p in description['packages'] if p.get('active')}
    package=active[target['rootPackage']];root=Path(package['path']).resolve()
    # Format the resolved target from the selected root graph, including inherited
    # settings; a standalone dependency description is a different build context.
    fields=('sourceFiles','dflags','versions','debugVersions','importPaths','stringImportPaths',
            'lflags','libs','options','requirements')
    context_root=Path(active[description['rootPackage']]['path']).resolve()
    configuration=description['configuration'];build=description['buildType']
    # Resolved strings are literals: DUB expands recipe variables once more.
    construction={field:[value.replace('$','$$') for value in settings.get(field,[])]
                  for field in fields if field not in ('options','requirements')}
    construction.update(name=configuration,buildOptions=settings.get('options',[]),
                        buildRequirements=settings.get('requirements',[]))
    recipe=evidence/(label+'-selected-target.recipe.json')
    recipe.write_text(json.dumps({'name':target['rootPackage'],'targetType':package['targetType'],
        'sourcePaths':[],'importPaths':[], 'configurations':[construction],
        'buildTypes':{build:{}}},indent=2))
    (evidence/(label+'-selected-context.json')).write_text(json.dumps({
        'root':str(context_root),'configuration':configuration,'compiler':compiler,'buildType':build,
        'target':target,'recipe':str(recipe)},indent=2))
    command=['dub','describe','--root='+str(context_root),'--config='+configuration,'--compiler='+compiler,
             '--build='+build,'--nodeps','--skip-registry=all','--quiet','--recipe='+str(recipe)]
    own_description=json.loads(run(command,root,env,evidence,label+'-selected-target',renderer_kind='describe').stdout)
    own_target=next(t for t in own_description['targets'] if t['rootPackage']==target['rootPackage'])
    for field in fields:
        actual=own_target['buildSettings'].get(field,[]);expected=settings.get(field,[])
        if field in ('importPaths','stringImportPaths'):
            actual=[(root/p).resolve() for p in actual];expected=[(root/p).resolve() for p in expected]
        require(actual==expected,
                'PREPARATION-REFUSED: renderer per-target configuration changed: '+label+':'+field)
    flags=shlex.split(run(command+['--data=options,dflags,versions,debug-versions,import-paths,string-import-paths'],root,env,evidence,label+'-compile-flags',renderer_kind='describe').stdout)
    links=shlex.split(run(command+['--data=lflags,libs'],root,env,evidence,label+'-link-flags',renderer_kind='describe').stdout)
    response_inputs={}
    flags=compiler_commands('[cwd='+str(root)+'] '+shlex.join([compiler]+flags),root,response_inputs)[0]['argv'][1:]
    links=compiler_commands('[cwd='+str(root)+'] '+shlex.join([compiler]+links),root,response_inputs)[0]['argv'][1:]
    (evidence/(label+'-response-inputs.json')).write_text(json.dumps(response_inputs,indent=2))
    require(flags and settings.get('importPaths'), 'support renderer required flag vectors: '+label)
    if target['rootPackage'] in (SPECS['render-model']['name'],SPECS['render-model']['name'].split(':')[-1],
                                 SPECS['render-backends']['name'],SPECS['render-backends']['name'].split(':')[-1],
                                 test_name('render-model'),test_name('render-backends'),'vibe3d'):
        require('WithRender' in settings.get('versions',[]), 'support renderer required active WithRender: '+label)
    require(not any(a in ('-i','-c','-lib','-run','-o-') or a.startswith(('-of','-od','-op','--output','--include-imports','-i=','-I=')) for a in flags),
            'support renderer ambient action/output/include-import flags: '+label)
    for key,prefixes in [('importPaths',('-I',)),('stringImportPaths',('-J',)),
                         ('versions',('-version=','-d-version=','--d-version=')),
                         ('debugVersions',('-debug=','-d-debug=','--d-debug='))]:
        values=[a[len(prefix):] for a in flags for prefix in prefixes if a.startswith(prefix)]
        expected=list(settings.get(key,[]))
        if key in ('importPaths','stringImportPaths'):
            values=[(root/p).resolve() for p in values];expected=[(root/p).resolve() for p in expected]
        require(values==expected, 'support renderer formatted '+key+': '+label)
    expected_links=renderer_expected_links(settings,root,env,evidence,label)
    require([value[2:].removeprefix('=') for value in links if value.startswith('-L')]==expected_links,
            'support renderer formatted ordered native link flags: '+label)
    receipt=json.loads((evidence/'native-input-receipt.json').read_text()) if (evidence/'native-input-receipt.json').is_file() else {}
    # Task20262930: declared operand identity includes aliases (doc/library_layout_wave17_plan_2026-10-14.md).
    admitted={str(Path(item['path'])):item['sha256'] for item in receipt.get('systemInputs',[])}
    dependency_receipt=json.loads((evidence/'dependency-sources.json').read_text())
    for dep,record in dependency_receipt.items():
        for relative,item in record['nativeArtifacts'].items():admitted[str(Path(record['staged'])/relative)]=item['sha256']
    for value in expected_links:
        if Path(value).is_absolute():
            require(value in admitted and legacy_digest(Path(value))==admitted[value],
                    'PREPARATION-REFUSED: renderer native link input not admitted: '+value)
    for library in settings.get('libs',[]):
        rows=[item for item in receipt.get('systemInputs',[]) if item.get('library')==library]
        require(len(rows)==1 and legacy_digest(Path(rows[0]['path']))==rows[0]['sha256'],
                'PREPARATION-REFUSED: renderer resolved system library: '+library)
    require(all(flag in flags for flag in settings.get('dflags',[])), 'support renderer formatted D flags: '+label)
    input_paths=set(sources)
    for field in ('importPaths','stringImportPaths'):
        for directory in settings.get(field,[]):
            base=Path(directory)
            if base.is_dir():input_paths.update(str(p.resolve()) for p in base.rglob('*') if p.is_file())
    inputs={p:{'size':Path(p).stat().st_size,'mtime_ns':Path(p).stat().st_mtime_ns,'sha256':legacy_digest(Path(p))} for p in sorted(input_paths)}
    (evidence/(label+'-precompile-inputs.json')).write_text(json.dumps(inputs,indent=2))
    raw=json.loads((root/'dub.json').read_text())
    binary=(root/(ARCHIVES[target['rootPackage']] if target['rootPackage'] in ARCHIVES else 'lib'+raw.get('targetName',raw['name'])+'.a')) if package['targetType'] in ('staticLibrary','library') else root/raw.get('targetPath','.')/raw.get('targetName',raw['name'])
    binary=binary.resolve()
    binary.parent.mkdir(parents=True,exist_ok=True)
    if package['targetType'] in ('staticLibrary','library'):
        single=['-singleobj'] if Path(compiler).name in ('ldc','ldc2') else []
        run([compiler]+flags+single+['-lib','-of='+str(binary)]+sources,root,env,evidence,label+'-archive',renderer_kind='archive')
    else:
        obj=evidence/(label+'.o')
        single=['-singleobj'] if Path(compiler).name in ('ldc','ldc2') else []
        run([compiler]+flags+single+['-c','-of='+str(obj)]+sources,root,env,evidence,label+'-compile',renderer_kind='compile')
        archives=list(settings.get('linkerFiles',[]))
        require(all(Path(a).is_file() for a in archives), 'PREPARATION-REFUSED: renderer D archive dependency missing')
        require(not tests or not any('libvibe3d-' in Path(a).name for a in archives), 'support renderer algorithm overlapping internal D archives')
        run([compiler,'-of='+str(binary),str(obj)]+archives+links,root,env,evidence,label+'-link',renderer_kind='link')
    require(binary.is_file(), 'NO-VERDICT: renderer direct output missing: '+label)
    (evidence/(label+'-output.json')).write_text(json.dumps({'path':str(binary),'sha256':legacy_digest(binary)},indent=2))
    return binary


def archive_metadata(project, owners):
    members=[SPECS[n]['root'] for n in owners]
    # DUB loads declared recipes before selecting configurations. Preserve their
    # exact metadata closure without adding the unselected package source trees.
    metadata=set()
    selected_recipes={(project/member/suffix).resolve() for member in members for suffix in ('dub.json','tests/dub.json')}
    def recipe(path):
        path=path.resolve();relative=str(path.relative_to(project))
        if relative in metadata:return
        metadata.add(relative)
        def fields(value):
            if isinstance(value,dict):
                for key,items in value.items():
                    field=key.split('-',1)[0]
                    if field=='dependencies':
                        for dependency in items.values():
                            if isinstance(dependency,dict) and 'path' in dependency:
                                recipe(path.parent/dependency['path']/'dub.json')
                    elif field=='subPackages':
                        for package in items:
                            if isinstance(package,str):recipe(path.parent/package/'dub.json')
                            else:fields(package)
                    elif field=='sourceFiles' and path in selected_recipes:
                        metadata.update(str((path.parent/source).resolve().relative_to(project)) for source in items)
                    else:fields(items)
            elif isinstance(value,list):
                for item in value:fields(item)
        fields(json.loads(path.read_text()))
    if any(SPECS[name]['name']=='vibe3d:'+name for name in owners):
        recipe(project/'dub.json')
    for member in tuple(members):
        recipe(project/member/'dub.json')
        recipe(project/member/'tests/dub.json')
    return sorted(metadata)


def execute_renderer(project,owner,compiler,env,evidence):
    require(not subprocess.check_output(['git','status','--porcelain'],cwd=project,text=True).strip(),
            'PREPARATION-REFUSED: renderer execute requires clean committed worktree')
    env=env.copy();env.pop('DFLAGS',None)
    sha=subprocess.check_output(['git','rev-parse','HEAD'],cwd=project,text=True).strip()
    (evidence/'direct-route.json').write_text(json.dumps({'owner':owner,'compiler':compiler,'sha':sha},indent=2))
    original=renderer_describe(project,owner,'with-render',compiler,env,evidence)
    descriptions=[original]
    if owner!='app':descriptions.append(renderer_describe(project,owner,'algorithm',compiler,env,evidence,True))
    active={p['name']:p for d in descriptions for p in d['packages'] if p.get('active')}
    receipt={}
    direct_owner=owner if owner!='app' else None
    if owner=='render-model':
        require(not any(not is_internal(n,direct_owner) for n in active), 'PREPARATION-REFUSED: render-model unexpected native/external dependency')
    else:receipt=renderer_native_receipt(project,compiler,evidence,active,direct_owner)
    archive=evidence/'archive';require(not archive.exists(),'PREPARATION-REFUSED: renderer archive exists');archive.mkdir()
    import tarfile
    members=[] if owner=='app' else [SPECS[n]['root'] for n in closure(owner)|closure(owner,True)|{owner}]
    metadata=[] if owner=='app' else archive_metadata(project,closure(owner)|closure(owner,True)|{owner})
    members+=metadata
    tar=evidence/'committed.tar'
    with tar.open('wb') as stream:subprocess.run(['git','archive',sha]+(['--']+members if members else []),cwd=project,stdout=stream,check=True)
    with tarfile.open(tar) as stream:stream.extractall(archive,filter='data')
    if owner!='app':require(not (archive/'source').exists(), 'support renderer isolated archive contains desktop')
    if owner!='app':require(not (archive/'dub.json').exists() or ((archive/'dub.json').read_bytes()==(project/'dub.json').read_bytes() and 'dub.json' in metadata), 'PREPARATION-REFUSED: root recipe metadata identity')
    dependencies=stage_dependencies({n:p for n,p in active.items() if not is_internal(n,direct_owner) and n!='vibe3d'},archive,evidence,env,renderer=True)
    shared=[];plugins=[]
    for name,record in dependencies.items():
        for relative,item in record['nativeArtifacts'].items():
            native=Path(record['staged'])/relative
            if '.so' in native.name:shared.append(str(native.parent))
            if name=='bindbc-rpr' and 'binUbuntu20' in Path(relative).parts:
                bundle=archive/'rpr';bundle.mkdir(exist_ok=True)
                target=bundle/native.name
                require(not target.exists() and not target.is_symlink(), 'PREPARATION-REFUSED: renderer duplicate RPR runtime artifact')
                if native.is_symlink():target.symlink_to(os.readlink(native))
                else:shutil.copy2(native,target)
                if native.name=='libNorthstar64.so':plugins.append(str(target))
                shared.insert(0,str(bundle))
    if 'bindbc-rpr' in dependencies:
        require(len(plugins)==1, 'PREPARATION-REFUSED: renderer Northstar plugin closure missing/duplicate')
        env['VIBE3D_RPR_PLUGIN_PATH']=plugins[0]
    env['LD_LIBRARY_PATH']=':'.join(dict.fromkeys(shared))
    (evidence/'runtime-environment.json').write_text(json.dumps({'LD_LIBRARY_PATH':env['LD_LIBRARY_PATH'],
        'VIBE3D_RPR_PLUGIN_PATH':env.get('VIBE3D_RPR_PLUGIN_PATH'),'loaderExecution':'UNEXECUTED until exact retained executable run and loaded-path receipt'},indent=2))
    description=renderer_describe(archive,owner,'with-render',compiler,env,evidence)
    for package in description['packages']:
        if package.get('active') and package['name'] in dependencies:
            require(Path(package['path']).resolve()==Path(dependencies[package['name']]['staged']).resolve(),
                    'PREPARATION-REFUSED: renderer canonical dependency selected')
    targets={t['rootPackage']:t for t in description['targets']};packages={p['name']:p for p in description['packages'] if p.get('active')}
    built=set();outputs={}
    def construct(name):
        if name in built:return
        package=packages[name]
        for dependency in package.get('dependencies',[]):construct(dependency)
        if name in targets:outputs[name]=renderer_compile_target(description,targets[name],compiler,env,evidence,name)
        built.add(name)
    construct(description['rootPackage'])
    actual_inputs={}
    for path in evidence.glob('*-precompile-inputs.json'):
        actual_inputs.update(json.loads(path.read_text()))
    for record in dependencies.values():
        for relative,item in record['nativeArtifacts'].items():
            actual_inputs[str(Path(record['staged'])/relative)]=item
    for item in receipt.get('systemInputs',[]):
        require(Path(item['path']).is_file() and legacy_digest(Path(item['path']))==item['sha256'],
                'PREPARATION-REFUSED: renderer recorded system input identity')
        actual_inputs[item['path']]=item
    (evidence/'actual-input-hashes.json').write_text(json.dumps(actual_inputs,indent=2))
    if owner=='app':
        app=outputs[description['rootPackage']]
        (evidence/'witness.json').write_text(json.dumps({'sha':sha,'app':str(app),'sha256':legacy_digest(app),
            'runtime':'UNEXECUTED; retained app and admitted dependency layout require focused loader/lifecycle/readback receipt',
            'nativeInputReceiptSha256':(legacy_digest(evidence/'native-input-receipt.json') if (evidence/'native-input-receipt.json').is_file() else None)},indent=2))
        print('PKG-APP-CONSTRUCTED sha='+sha+' executable='+str(app));return
    root=archive/SPECS[owner]['root'];home=Path(env['DUB_HOME'])
    harness=root/'tests/boundary_roster.d'
    harness.write_text('module boundary_roster; import std.stdio : writeln; import std.file : getcwd; shared static this() { writeln("PKG-CWD path=",getcwd()); foreach(info; ModuleInfo) if(info !is null) writeln("PKG-MODULE name=",info.name," unittest=",info.unitTest !is null ? 1:0); }\n')
    generated=home/'cache'/test_name(owner)/'~master/code/dub_test_root.d';generated.parent.mkdir(parents=True,exist_ok=True)
    generated.write_text('module dub_test_root;\nvoid main() {}\n')
    raw=json.loads((root/'tests/dub.json').read_text());raw['sourceFiles']+=['boundary_roster.d',str(generated)];raw['mainSourceFile']=str(generated)
    recipe=root/'tests/dub.boundary.json';recipe.write_text(json.dumps(raw,indent=2))
    (evidence/'generated-inputs.json').write_text(json.dumps({str(path):legacy_digest(path) for path in (generated,harness,recipe)},indent=2))
    description=renderer_describe(archive,owner,'algorithm',compiler,env,evidence,True,recipe,harness)
    target=next(t for t in description['targets'] if t['rootPackage']==description['rootPackage'])
    binary=renderer_compile_target(description,target,compiler,env,evidence,owner+'-algorithm',True)
    tested=run([str(binary)],root/'tests',env,evidence,'algorithm-run',renderer_kind='algorithm-run')
    logs=''.join(path.read_text() for path in sorted(evidence.glob(owner+'-algorithm-*.compiler.log')))
    commands=compiler_commands(logs,root/'tests')
    actual=validate_actual_compiler(commands,archive,owner,description,home,harness,renderer=True)
    require(re.findall(r'^PKG-CWD path=(.+)$',tested.stdout+tested.stderr,re.M)==[str(root/'tests')],
            'support renderer algorithm actual working directory')
    runtime=validate_runtime(tested.stdout+tested.stderr,owner)
    (evidence/'actual-compiler-argv.json').write_text(json.dumps(commands,indent=2))
    actual_inputs.update(json.loads((evidence/(owner+'-algorithm-precompile-inputs.json')).read_text()))
    (evidence/'actual-input-hashes.json').write_text(json.dumps(actual_inputs,indent=2))
    (evidence/'witness.json').write_text(json.dumps({'sha':sha,'runtime':runtime,'algorithm':str(binary),
        'algorithmSha256':legacy_digest(binary),'actualOwnership':actual,'nativeInputReceiptSha256':(legacy_digest(evidence/'native-input-receipt.json') if (evidence/'native-input-receipt.json').is_file() else None)},indent=2))
    print('PKG-EXECUTE package='+owner+' sha='+sha+' modules='+str(runtime['modules']))

def execute(project,owner,compiler,env,evidence):
    if owner in ('render-model','render-backends','app'):
        return execute_renderer(project,owner,compiler,env,evidence)
    require(not subprocess.check_output(['git','status','--porcelain'],cwd=project,text=True).strip(),
            'PREPARATION-REFUSED: execute requires a clean committed worktree')
    sha=subprocess.check_output(['git','rev-parse','HEAD'],cwd=project,text=True).strip()
    archive=evidence/'archive';require(not archive.exists(),'PREPARATION-REFUSED: archive exists');archive.mkdir()
    members=[SPECS[n]['root'] for n in closure(owner)|closure(owner,True)|{owner}]
    metadata=archive_metadata(project,closure(owner)|closure(owner,True)|{owner})
    members+=metadata
    # Exact read-only support carrier accepted in C; no desktop production root.
    if 'mesh-ops' in closure(owner)|closure(owner,True)|{owner}:
        members += ['tests/unit/mesh_by_value_gate.d', 'tests/unit/fixtures.d']
    if owner in FIXTURES:members.append(FIXTURES[owner][0])
    if 'platform-file' in closure(owner)|closure(owner,True)|{owner}:members.append('third_party/nfde')
    members += [path for path, _ in PACKAGE_FIXTURES.get(owner, ())]
    import tarfile
    tar=evidence/'committed.tar'
    with tar.open('wb') as stream:subprocess.run(['git','archive',sha,'--']+members,cwd=project,stdout=stream,check=True)
    with tarfile.open(tar) as stream:stream.extractall(archive,filter='data')
    require(not (archive/'source').exists(), 'PREPARATION-REFUSED: desktop production root')
    require(not (archive/'dub.json').exists() or ((archive/'dub.json').read_bytes()==(project/'dub.json').read_bytes() and 'dub.json' in metadata), 'PREPARATION-REFUSED: root recipe metadata identity')
    check_raw_tree(archive,owner)
    root=archive/SPECS[owner]['root'];
    # DUB owns external native dependencies; all internal source roots are the isolated archive.
    ordinary_config=SPECS[owner].get('ordinaryConfig','modeling-noai')
    original=describe(project,owner,ordinary_config,compiler,env,evidence)
    config=json.loads((root/'tests/dub.json').read_text())['configurations'][0]['name']
    selected=describe(project,owner,config,compiler,env,evidence,True)
    active={}
    for description in (original,selected):
        for package in description['packages']:
            name=package['name']
            if not package.get('active') or is_internal(name):continue
            if name in active:
                require(Path(package['path']).resolve()==Path(active[name]['path']).resolve(),
                        'PREPARATION-REFUSED: dependency source path conflict: '+name)
                require(package['version']==active[name]['version'],
                        'PREPARATION-REFUSED: dependency version conflict: '+name)
            active[name]=package
    dependencies=stage_dependencies(active,archive,evidence,env)
    def require_staged_dependencies(description):
        for package in description['packages']:
            if package.get('active') and not is_internal(package['name']):
                require(Path(package['path']).resolve()==Path(dependencies[package['name']]['staged']).resolve(),
                        'PREPARATION-REFUSED: canonical dependency cache selected: '+package['name'])
    production=describe(archive,owner,ordinary_config,compiler,env,evidence)
    require_staged_dependencies(production)
    require_staged_dependencies(describe(archive,owner,config,compiler,env,evidence,True))
    legacy_validate_staged_fixture(legacy_fixture_receipt(archive,owner,FIXTURES),legacy_fixture_receipt(project,owner,FIXTURES),owner,archive,FIXTURES)
    for fixture in PACKAGE_FIXTURES.get(owner, ()):
        frozen = {owner: fixture}
        legacy_validate_staged_fixture(legacy_fixture_receipt(archive,owner,frozen),
            legacy_fixture_receipt(project,owner,frozen),owner,archive,frozen)
    built=run(['dub','build']+ordinary_arguments(archive,owner)+['--config='+ordinary_config,'--compiler='+compiler,'--force','--verbose'],archive,env,evidence,'production-build')
    require((root/archive_name(owner)).is_file(),'NO-VERDICT: ordinary static archive missing')
    harness=root/'tests/boundary_roster.d'
    receipt_source='module boundary_roster; import std.stdio : writeln; import std.file : getcwd,read; import std.digest.sha : sha256Of; import std.digest : toHexString; import std.string : toLower; shared static this() { writeln("PKG-CWD path=",getcwd()); foreach(info; ModuleInfo) if(info !is null) writeln("PKG-MODULE name=",info.name," unittest=",info.unitTest !is null ? 1:0);'
    if owner in FIXTURES:receipt_source += legacy_fixture_observer_statement(archive,owner,FIXTURES)
    for path, _ in PACKAGE_FIXTURES.get(owner, ()):
        receipt_source += ' writeln("PKG-W15-FIXTURE path='+path+' sha256=", sha256Of(read('+json.dumps(str(archive/path))+')).toHexString.toLower);'
    harness.write_text(receipt_source+' }\n')
    raw=json.loads((root/'tests/dub.json').read_text());raw['sourceFiles'].append('boundary_roster.d');recipe=root/'tests/dub.boundary.json';recipe.write_text(json.dumps(raw))
    description=describe(archive,owner,config,compiler,env,evidence,True,recipe,harness)
    require_staged_dependencies(description)
    tested=run(['dub','test','--root='+str(root/'tests'),'--recipe='+str(recipe),'--config='+config,'--compiler='+compiler,'--force','--verbose'],archive,env,evidence,'algorithm-run')
    output=tested.stdout+tested.stderr
    expected_cwd=archive if owner in ('input-events', 'mesh-preview', 'document-model', 'param-schema', 'pipe-runtime', 'pipe-evaluation', 'interactive-tools', 'ai3d-runtime') else root/'tests'
    require(re.findall(r'^PKG-CWD path=(.+)$',output,re.M)==[str(expected_cwd)],'support algorithm actual working directory: '+owner)
    if owner in FIXTURES:
        require(re.findall(r'^PKG-FIXTURE sha256=(.+)$',output,re.M)==[FIXTURES[owner][1]],'support algorithm actual fixture hash: '+owner)
    if owner in PACKAGE_FIXTURES:
        require(re.findall(r'^PKG-W15-FIXTURE path=(\S+) sha256=(\S+)$',output,re.M)==PACKAGE_FIXTURES[owner],
                'support algorithm actual fixture identity: '+owner)
    runtime=validate_runtime(output,owner);commands=compiler_commands(output,root/'tests')
    actual=validate_actual_compiler(commands,archive,owner,description,Path(env['DUB_HOME']),harness)
    input_hashes={}
    for result,cwd in ((built,archive),(tested,root/'tests')):
        for command in compiler_commands(result.stdout+result.stderr,cwd):
            for path in command['sourceInputs']+command['archiveInputs']+command['objectInputs']:
                selected=Path(path)
                require(selected.is_relative_to(archive) or selected.is_relative_to(Path(env['DUB_HOME'])), 'support actual input outside owned roots: '+path)
                input_hashes[path]=legacy_digest(selected)
    link=actual['link']
    search_paths=[(Path(link['cwd'])/arg.removeprefix('-L-L')).resolve() for arg in link['argv'] if arg.startswith('-L-L')]
    for library in ('stb_image_c','osdc','osdCPU','osdGPU','dbvh_c'):
        if '-L-l'+library in link['argv']:
            selected=legacy_native_archive_input(search_paths,library);input_hashes[str(selected)]=legacy_digest(selected)
    if 'nfde' in dependencies:
        selected=(Path(dependencies['nfde']['staged'])/'nativefiledialog-extended/out/src/libnfd.a').resolve()
        require([arg for arg in link['argv'] if arg.startswith('-L') and arg.endswith('/libnfd.a')]==['-L'+str(selected)],
                'support actual native archive input: libnfd.a')
        input_hashes[str(selected)]=legacy_digest(selected)
    if 'd_imgui' in dependencies:
        selected=(Path(dependencies['d_imgui']['staged'])/'lib/libcimgui_docking.a').resolve()
        flags=[arg for arg in link['argv'] if arg.startswith('-L') and arg.endswith('/libcimgui_docking.a')]
        require(bool(flags) and all(arg=='-L'+str(selected) for arg in flags),'support actual native archive input: libcimgui_docking.a')
        input_hashes[str(selected)]=legacy_digest(selected)
    (evidence/'actual-input-hashes.json').write_text(json.dumps(input_hashes,indent=2))
    (evidence/'actual-compiler-argv.json').write_text(json.dumps(commands,indent=2));(evidence/'witness.json').write_text(json.dumps({'sha':sha,'actualOwnership':actual,'runtime':runtime},indent=2))
    print('PKG-EXECUTE package='+owner+' sha='+sha+' modules='+str(runtime['modules']))

def self_test():
    # The accepted 794 historical fixture controls stay available to the root
    # gate; D does not repeat that catalog. Their flat-common control domain is
    # separate from the final production manifests below.
    legacy_self_test()

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--package',choices=tuple(SPECS)+('app',));parser.add_argument('--root',default=str(Path(__file__).resolve().parents[1]));parser.add_argument('--compiler',default='dmd');parser.add_argument('--evidence-dir')
    modes=parser.add_mutually_exclusive_group(required=True);modes.add_argument('--self-test',action='store_true');modes.add_argument('--check',action='store_true');modes.add_argument('--execute',action='store_true');args=parser.parse_args(argv)
    if args.self_test:self_test()
    else:
        require(not args.execute or args.package is not None,'execute requires selected package')
        project=Path(args.root).resolve();compiler=shutil.which(args.compiler);require(compiler is not None,'compiler not found')
        if 'ldc' in Path(compiler).name:require(Path(compiler).resolve()==Path.home()/'.local/dlang/ldc2-1.42.0-linux-x86_64/bin/ldc2','support checker requires project LDC compiler')
        env=os.environ.copy()
        for key in ('DISPLAY','WAYLAND_DISPLAY','SDL_VIDEODRIVER','DFLAGS'):env.pop(key,None)
        for owner in (args.package,) if args.package else SPECS:
            if owner=='app':require(args.execute,'support app selects renderer execute only')
            else:check_raw_tree(project,owner)
            if args.execute:
                require(args.evidence_dir is not None,'execute requires evidence directory');evidence=Path(args.evidence_dir);require(evidence.is_absolute() and not evidence.resolve().is_relative_to(project),'evidence must be absolute outside worktree');evidence.mkdir(parents=True,exist_ok=True);execute(project,owner,compiler,env,evidence)
            else:
                with tempfile.TemporaryDirectory(prefix='support-describe-') as tmp:
                    configs=CONFIGS if args.package else ('modeling-noai',)
                    for config in configs:describe(project,owner,config,compiler,env,Path(tmp))
                    config=json.loads((project/SPECS[owner]['root']/'tests/dub.json').read_text())['configurations'][0]['name']
                    describe(project,owner,config,compiler,env,Path(tmp),True)
            if owner=='app':
                print('PKG-APP-VERDICT=CONSTRUCTION-ONLY');return 0
            print('PKG-CHECK package='+owner)
    print('PKG-BOUNDARY-VERDICT=GREEN');return 0

if __name__=='__main__':
    try:sys.exit(main())
    except (BoundaryError,OSError,ValueError,KeyError,subprocess.SubprocessError) as error:
        print('PKG-BOUNDARY-VERDICT=RED Error: '+str(error),file=sys.stderr);sys.exit(1)
