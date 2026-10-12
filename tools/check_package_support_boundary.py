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
                   'lower': ['common', 'edit-contracts', 'interaction-query', 'math', 'mesh'],
                   'name': 'vibe3d-alignment-ops',
                   'ordinaryDigest': '65aefee8ae33de6dfe49596b4f58f4272e7a745135c6e91372f34d3579ed8ee3',
                   'root': 'packages/alignment-ops',
                   'sources': ['source/tools/alignment/align_kernels.d'],
                   'testDigest': '0a32e0ed3d6d2f445c1998580d9e273d49611abfbb87353df058e75624680ae8',
                   'testImports': ['source', '../source'],
                   'testLower': ['common', 'edit-contracts', 'interaction-query', 'math', 'mesh', 'pipe-runtime'],
                   'testSources': ['../source/tools/alignment/align_kernels.d',
                                   'source/tests/unit/alignment_ops_population_test.d',
                                   'source/tests/unit/tools/alignment/align_kernels_test.d']},
 'common': {'external': {'d-stb-image': {'repository': 'git+https://github.com/shulc/D-StbImage.git',
                                         'version': 'a66f6917718ea128076a2c5660e37f362a785144'}},
            'lower': ['document-model',
                      'edit-contracts',
                      'json-number',
                      'log',
                      'math',
                      'mesh',
                      'mesh-change',
                      'mesh-edit-log',
                      'mesh-edit-replay',
                      'mesh-ops',
                      'mesh-preview',
                      'mesh-snapshot',
                      'param-schema',
                      'pipe-contracts',
                      'pipe-runtime',
                      'profiling',
                      'spatial'],
            'name': 'vibe3d-common',
            'ordinaryDigest': 'ef60eb7798dc1047930ea81599427ec6c77da99b9d24cd64fbff2ca4b70773b6',
            'root': 'packages/common',
            'sources': ['source/app_version.d',
                        'source/command.d',
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
                        'source/http_json.d',
                        'source/io/file_model.d',
                        'source/io/image_decode.d',
                        'source/io/image_path.d',
                        'source/io/native.d',
                        'source/layer_params.d',
                        'source/morph_target.d',
                        'source/pilot_command_registration.d',
                        'source/record_observer_hub.d',
                        'source/session_owner.d',
                        'source/standalone_application.d',
                        'source/tool_activation_ownership.d',
                        'source/view.d'],
            'testDigest': '4cad80b0b20695e259a48c067fd8d8d972b038f3fe83103ca79105bf7afae535',
            'testImports': ['source', '../source'],
            'testLower': ['document-model',
                          'edit-contracts',
                          'json-number',
                          'log',
                          'math',
                          'mesh',
                          'mesh-change',
                          'mesh-edit-log',
                          'mesh-edit-replay',
                          'mesh-ops',
                          'mesh-preview',
                          'mesh-snapshot',
                          'param-schema',
                          'pipe-contracts',
                          'pipe-runtime',
                          'profiling',
                          'spatial'],
            'testSources': ['../source/app_version.d',
                            '../source/command.d',
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
                            '../source/http_json.d',
                            '../source/io/file_model.d',
                            '../source/io/image_decode.d',
                            '../source/io/image_path.d',
                            '../source/io/native.d',
                            '../source/layer_params.d',
                            '../source/morph_target.d',
                            '../source/pilot_command_registration.d',
                            '../source/record_observer_hub.d',
                            '../source/session_owner.d',
                            '../source/standalone_application.d',
                            '../source/tool_activation_ownership.d',
                            '../source/view.d',
                            'source/tests/common_execution_roster_test.d',
                            'source/tests/unit/io/native_test.d']},
 'creation-ops': {'external': {},
                  'lower': ['common',
                            'edit-contracts',
                            'interaction-query',
                            'math',
                            'mesh',
                            'pipe-contracts',
                            'spatial'],
                  'name': 'vibe3d-creation-ops',
                  'ordinaryDigest': '8d1858652b335c8301bc206d6ff2a7854dc18fcc8332058ccd638164503d63ac',
                  'root': 'packages/creation-ops',
                  'sources': ['source/tools/create/pen_geometry.d'],
                  'testDigest': 'ba2c59135b60ddaf3c7dbea13e0cdc9519ea32d5a36063720898e3fb726f7362',
                  'testImports': ['source', '../source'],
                  'testLower': ['common',
                                'edit-contracts',
                                'interaction-query',
                                'math',
                                'mesh',
                                'pipe-contracts',
                                'spatial'],
                  'testSources': ['../source/tools/create/pen_geometry.d',
                                  'source/tests/unit/tools/create/pen_geometry_population_test.d',
                                  'source/tests/unit/tools/create/pen_geometry_test.d']},
 'display-policy': {'external': {},
                    'lower': ['common', 'math', 'mesh'],
                    'name': 'vibe3d-display-policy',
                    'ordinaryDigest': '3d2b02df38e0fc9f358ab74df75f2ed78b980725ed669a1d19ae9c8e1208131f',
                    'root': 'packages/display-policy',
                    'sources': ['source/camera_stamp.d',
                                'source/display_state.d',
                                'source/light_rig.d',
                                'source/vertex_normals.d',
                                'source/viewport_overlay_mode.d',
                                'source/viewport_probe_sampling.d',
                                'source/viewport_scheme.d',
                                'source/weightmap_view.d'],
                    'testDigest': 'df14d3063a82b8435f3536619f959f34e4e70554f6a62643afe41bf8a62d9999',
                    'testImports': ['source', '../source'],
                    'testLower': ['common', 'math', 'mesh'],
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
                                    'source/tests/unit/weightmap_state_test.d']},
 'document-model': {'external': {},
                    'lower': ['edit-contracts', 'mesh', 'mesh-change', 'profiling', 'spatial'],
                    'name': 'vibe3d-document-model',
                    'ordinaryDigest': 'bd30de0e29fa575408f2a6fde7f9e1a8d4d811b8e9ece7b8a581c2611ecc9a20',
                    'root': 'packages/document-model',
                    'sources': ['source/document.d',
                                'source/document_selection.d',
                                'source/edit_target_contract.d',
                                'source/image_data.d',
                                'source/item_kinds.d'],
                    'testDigest': '59cec528d96ddb6d1828b19e84094afa78b7f8d0db2768368fc05ff02e46ad17',
                    'testImports': ['source', '../source'],
                    'testLower': ['edit-contracts',
                                  'math',
                                  'mesh',
                                  'mesh-change',
                                  'mesh-edit-log',
                                  'profiling',
                                  'spatial'],
                    'testSources': ['../source/document.d',
                                    '../source/document_selection.d',
                                    '../source/edit_target_contract.d',
                                    '../source/image_data.d',
                                    '../source/item_kinds.d',
                                    'source/tests/unit/document_test.d']},
 'edit-contracts': {'external': {},
                    'lower': [],
                    'name': 'vibe3d-edit-contracts',
                    'ordinaryDigest': 'c49d9f6086fd47366eef4b33ff573f7f0eef4bd86763a3f657b5ca4a26151a87',
                    'root': 'packages/edit-contracts',
                    'sources': ['source/editmode.d',
                                'source/prepared_tool_effect.d',
                                'source/seltype.d',
                                'source/tool_policy_values.d'],
                    'testDigest': '21c5c4f96b7608645514e3dc970ff4506b8b1da27c81e75062ef152966991cf4',
                    'testImports': ['../source', 'source'],
                    'testLower': [],
                    'testSources': ['../source/editmode.d',
                                    '../source/prepared_tool_effect.d',
                                    '../source/seltype.d',
                                    'source/tests/unit/seltype_test.d',
                                    '../source/tool_policy_values.d']},
 'input-events': {'external': {'bindbc-sdl': '~>1.5.2',
                               'dyaml': {'repository': 'git+https://github.com/shulc/D-YAML.git',
                                         'version': '22e4724474795eefb64ee9742f980b49bb34f6ef'}},
                  'lower': ['common', 'log'],
                  'name': 'vibe3d-input-events',
                  'ordinaryDigest': 'ced3a13c2642c02dc59a1ea8900cf768d2c97f8743d2bb58a23cde0a8a769124',
                  'root': 'packages/input-events',
                  'sources': ['source/eventlog.d',
                              'source/held_gesture_buttons.d',
                              'source/input_context.d',
                              'source/input_zones.d',
                              'source/shortcuts.d',
                              'source/tool_input.d'],
                  'testDigest': '30b946d585a5cfffeb591cfe165fccccc5a3ae16ad320e017668b3713d5b0891',
                  'testImports': ['source', '../source'],
                  'testLower': ['common', 'log'],
                  'testSources': ['../source/eventlog.d',
                                  '../source/held_gesture_buttons.d',
                                  '../source/input_context.d',
                                  '../source/input_zones.d',
                                  '../source/shortcuts.d',
                                  '../source/tool_input.d',
                                  'source/tests/unit/binding_resolve_test.d',
                                  'source/tests/unit/eventlog_parser_test.d',
                                  'source/tests/unit/eventlog_test.d',
                                  'source/tests/unit/input_events_population_test.d',
                                  'source/tests/unit/tool_input_test.d']},
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
                       'ordinaryDigest': '251f35a7cdb6623a2c488cd68f5a544ec3bb2fe69198a9e42c033f13d9c01a76',
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
                       'testDigest': '46f300524e3052607873fbb16df3facdf9d9f31a4e2f42c36421ef893f59bce4',
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
 'interchange': {'external': {'lwo2-writer': {'repository': 'git+https://github.com/shulc/D-Lwo2Writer.git',
                                              'version': '6d35b70a2a23c16c5b6cc19ea3e2d05a99eb0061'}},
                 'lower': ['document-model', 'log', 'math', 'mesh'],
                 'name': 'vibe3d-interchange',
                 'ordinaryDigest': 'd90177ee97660a714c4048186ae53afcb7e5c517d2af0442556792e48f82042f',
                 'root': 'packages/interchange',
                 'sources': ['source/io/assimp_runtime.d',
                             'source/io/assimp_wire.d',
                             'source/io/formats.d',
                             'source/io/lwo_export.d',
                             'source/io/lwo_import.d',
                             'source/io/scene_export.d',
                             'source/io/scene_import.d',
                             'source/io/scene_ir.d'],
                 'testDigest': '637b4d8018094a1b076d43d4aab78d05d6f89d113bb87050ba3588a320c20432',
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
                 'name': 'vibe3d-json-number',
                 'ordinaryDigest': 'c5ff9e0fe970aff983e42638a6cb72c62ecab521b9caf5773e4a3400aad4b82a',
                 'root': 'util/json-number',
                 'sources': ['source/json_num.d'],
                 'testDigest': '24e5061172b08445a0b94937238aa512be5dd1ab384a242e912d2dd0c9090bf6',
                 'testImports': ['../source', 'source'],
                 'testLower': [],
                 'testSources': ['../source/json_num.d', 'source/tests/unit/json_num_test.d']},
 'log': {'external': {},
         'lower': [],
         'name': 'vibe3d-log',
         'ordinaryDigest': '2d352891dd58c5f5efe18610f647008a9f356811e1b97078489f0c5ec960b735',
         'root': 'util/log',
         'sources': ['source/log.d'],
         'testDigest': '81dae094ca7474e27c0bccbad47754259761fde3029121d55141ef8e19a8e356',
         'testImports': ['../source', 'source'],
         'testLower': [],
         'testSources': ['../source/log.d']},
 'math': {'external': {},
          'lower': [],
          'name': 'vibe3d-math',
          'ordinaryDigest': 'eb6d40d7138fcdd9e50ce3c0d809c17f44f753faf31231ad82f01b4476c09d1b',
          'root': 'util/math',
          'sources': ['source/math.d',
                      'source/math_geometry.d',
                      'source/math_matrix.d',
                      'source/math_quaternion.d',
                      'source/math_vector.d'],
          'testDigest': '53b3aa196c4af14606d780de14f34b0e22ecc651077c4998a93f7b9467a24e74',
          'testImports': ['../source', 'source'],
          'testLower': [],
          'testSources': ['../source/math.d',
                          '../source/math_geometry.d',
                          '../source/math_matrix.d',
                          '../source/math_quaternion.d',
                          '../source/math_vector.d',
                          'source/tests/unit/math_test.d']},
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
          'name': 'vibe3d-mesh',
          'ordinaryDigest': 'a8fd838bb804fb2e0cafef3fe3172f08834c9104abd93bd707aad9385c382789',
          'root': 'packages/mesh',
          'sources': ['source/mesh.d', 'source/mesh_morph.d', 'source/mesh_planes.d', 'source/mesh_selsets.d'],
          'testDigest': '67252b91f780af88b4c11960c4e1cc48c9523e179dd0848bc492deee1fb38a3f',
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
          'testSources': ['../source/mesh.d',
                          '../source/mesh_morph.d',
                          '../source/mesh_planes.d',
                          '../source/mesh_selsets.d',
                          'source/tests/unit/mesh_key_test.d',
                          'source/tests/unit/mesh_map_kind_test.d',
                          'source/tests/unit/mesh_selsets_test.d',
                          'source/tests/unit/mesh_topology_integration_test.d']},
 'mesh-change': {'external': {},
                 'lower': ['edit-contracts', 'mesh-contracts'],
                 'name': 'vibe3d-mesh-change',
                 'ordinaryDigest': '4de9f567a59278dc63d7cd0672f75f481314c4d0e39d633f0a92ce4e96104009',
                 'root': 'packages/mesh-change',
                 'sources': ['source/change_bus.d', 'source/mesh_dirty.d'],
                 'testDigest': 'c1d1a2d5af57e807ef0d0ce685f8ffad86d7671352e06d4e71187e705865f219',
                 'testImports': ['../source', 'source'],
                 'testLower': ['edit-contracts', 'mesh-contracts'],
                 'testSources': ['../source/change_bus.d', '../source/mesh_dirty.d']},
 'mesh-contracts': {'external': {},
                    'lower': [],
                    'name': 'vibe3d-mesh-contracts',
                    'ordinaryDigest': '38b8daa41b755f8d2eca217b737c66dfcec19ab9961059c37bcdac64987eda11',
                    'root': 'packages/mesh-contracts',
                    'sources': ['source/mesh_corner_maps.d',
                                'source/mesh_plane_types.d',
                                'source/mesh_scope.d',
                                'source/mesh_types.d'],
                    'testDigest': 'a6a6c45498e1835afe12593be468230a61e5a291d8bc1fcfb2e8fe56f97bba36',
                    'testImports': ['../source', 'source'],
                    'testLower': [],
                    'testSources': ['../source/mesh_corner_maps.d',
                                    '../source/mesh_plane_types.d',
                                    '../source/mesh_scope.d',
                                    '../source/mesh_types.d',
                                    'source/tests/unit/mesh_plane_types_test.d']},
 'mesh-edit-log': {'external': {},
                   'lower': ['math', 'mesh-change', 'mesh-contracts', 'plane-bytes'],
                   'name': 'vibe3d-mesh-edit-log',
                   'ordinaryDigest': 'e0cadefca788a315ad5f6916d7ce05c96ac0f0a0643296fcf79951240dbefddd',
                   'root': 'packages/mesh-edit-log',
                   'sources': ['source/mesh_edit_delta.d'],
                   'testDigest': '0fe42e66bcbc6f721c5f411495cd79766fb1c45f34ceb652a1703cdab490c00f',
                   'testImports': ['../source', 'source'],
                   'testLower': ['math', 'mesh-change', 'mesh-contracts', 'plane-bytes'],
                   'testSources': ['../source/mesh_edit_delta.d', 'source/mesh_edit_log_protocol_test.d']},
 'mesh-edit-replay': {'external': {},
                      'lower': ['math', 'mesh', 'mesh-change', 'mesh-contracts', 'mesh-edit-log'],
                      'name': 'vibe3d-mesh-edit-replay',
                      'ordinaryDigest': '9119c346b4e1af5fdcef1ad77c93e2f5008e613221242b8992b5465e5e2f4486',
                      'root': 'packages/mesh-edit-replay',
                      'sources': ['source/mesh_edit_replay.d'],
                      'testDigest': '5babb83a01ccb7dc0a0d0bfea7f6f6170274b1f85b6852ae0d2739e47b75b6c9',
                      'testImports': ['../source', 'source'],
                      'testLower': ['math', 'mesh', 'mesh-change', 'mesh-contracts', 'mesh-edit-log'],
                      'testSources': ['../source/mesh_edit_replay.d',
                                      'source/mesh_edit_replay_roundtrip_test.d',
                                      'source/tests/unit/mesh_edit_delta_test.d',
                                      'source/tests/unit/mesh_selsets_replay_test.d']},
 'mesh-ops': {'external': {},
              'lower': ['log', 'math', 'mesh', 'mesh-contracts', 'mesh-topology', 'spatial'],
              'name': 'vibe3d-mesh-ops',
              'ordinaryDigest': '70c00b615b1c042b5c0c8abecfd1ca8365aa92a285aba3b122d01a431db24d51',
              'root': 'packages/mesh-ops',
              'sources': ['source/mesh_edge_slice.d',
                          'source/mesh_ops/bevel_curves.d',
                          'source/mesh_ops/bevel_fin.d',
                          'source/mesh_ops/bevel_vertex.d',
                          'source/mesh_ops/box_geom.d',
                          'source/mesh_ops/bridge.d',
                          'source/mesh_ops/bridge_patch.d',
                          'source/mesh_ops/cleanup.d',
                          'source/mesh_ops/connected_mask.d',
                          'source/mesh_ops/cut.d',
                          'source/mesh_ops/decimate.d',
                          'source/mesh_ops/edge_bevel.d',
                          'source/mesh_ops/extrude.d',
                          'source/mesh_ops/face_alignment.d',
                          'source/mesh_ops/face_merge.d',
                          'source/mesh_ops/loop_slice.d',
                          'source/mesh_ops/poly_bevel.d',
                          'source/mesh_ops/revolve.d',
                          'source/mesh_ops/select_loop.d',
                          'source/mesh_ops/thicken.d',
                          'source/mesh_ops/triangulate.d'],
              'testDigest': '34a4770080ed14a1e4c894cacb0a020620cbc50945a453933ffcedcaa0a97f23',
              'testImports': ['../source', 'source', '../../..'],
              'testLower': ['log',
                            'math',
                            'mesh',
                            'mesh-contracts',
                            'mesh-edit-replay',
                            'mesh-snapshot',
                            'mesh-topology',
                            'spatial'],
              'testSources': ['../source/mesh_edge_slice.d',
                              '../source/mesh_ops/bevel_curves.d',
                              '../source/mesh_ops/bevel_fin.d',
                              '../source/mesh_ops/bevel_vertex.d',
                              '../source/mesh_ops/box_geom.d',
                              '../source/mesh_ops/bridge.d',
                              '../source/mesh_ops/bridge_patch.d',
                              '../source/mesh_ops/cleanup.d',
                              '../source/mesh_ops/connected_mask.d',
                              '../source/mesh_ops/cut.d',
                              '../source/mesh_ops/decimate.d',
                              '../source/mesh_ops/edge_bevel.d',
                              '../source/mesh_ops/extrude.d',
                              '../source/mesh_ops/face_alignment.d',
                              '../source/mesh_ops/face_merge.d',
                              '../source/mesh_ops/loop_slice.d',
                              '../source/mesh_ops/poly_bevel.d',
                              '../source/mesh_ops/revolve.d',
                              '../source/mesh_ops/select_loop.d',
                              '../source/mesh_ops/thicken.d',
                              'source/tests/unit/mesh_ops/bevel_fin_test.d',
                              'source/tests/unit/mesh_ops/bevel_vertex_test.d',
                              'source/tests/unit/mesh_ops/box_geom_corner_provenance_test.d',
                              'source/tests/unit/mesh_ops/bridge_test.d',
                              'source/tests/unit/mesh_ops/cleanup_test.d',
                              'source/tests/unit/mesh_ops/connected_mask_test.d',
                              'source/tests/unit/mesh_ops/extrude_test.d',
                              'source/tests/unit/mesh_ops/loop_slice_test.d',
                              'source/tests/unit/mesh_ops/poly_bevel_test.d',
                              'source/tests/unit/mesh_ops/revolve_seam_test.d',
                              'source/tests/unit/mesh_ops/revolve_test.d',
                              'source/tests/unit/mesh_ops/select_loop_test.d',
                              'source/tests/unit/mesh_ops/vertex_pos_grid_test.d',
                              'source/tests/unit/mesh_ops/seam_differential.d',
                              'source/tests/unit/mesh_ops/edge_fixture.d',
                              'source/tests/unit/mesh_edge_slice_test.d',
                              'source/tests/unit/mesh_edge_slice_gate_test.d',
                              'source/tests/unit/mesh_ops/face_alignment_test.d',
                              'source/tests/unit/mesh_ops/face_merge_test.d',
                              '../../../tests/unit/mesh_by_value_gate.d',
                              '../source/mesh_ops/triangulate.d',
                              'source/tests/unit/mesh_ops/triangulate_test.d',
                              '../../../tests/unit/fixtures.d']},
 'mesh-preview': {'external': {},
                  'lower': ['math', 'mesh', 'mesh-contracts'],
                  'name': 'vibe3d-mesh-preview',
                  'ordinaryDigest': '6344d87b96cdd028fa5e7cef2a54870a8bb08d429d1d6a0b9a34d5fc4880eb9e',
                  'root': 'packages/mesh-preview',
                  'sources': ['source/active_mesh_resolver.d', 'source/morph_preview.d'],
                  'testDigest': 'c22618544c1f0c2fcd9d709b68ace696301bc231e1ca607e90d80e8da52c72ad',
                  'testImports': ['../source', 'source'],
                  'testLower': ['math', 'mesh', 'mesh-contracts'],
                  'testSources': ['../source/active_mesh_resolver.d',
                                  '../source/morph_preview.d',
                                  'source/tests/unit/morph_routing_law_test.d']},
 'mesh-snapshot': {'external': {},
                   'lower': ['math', 'mesh', 'mesh-change', 'plane-bytes', 'profiling'],
                   'name': 'vibe3d-mesh-snapshot',
                   'ordinaryDigest': '5180311ca580c201b4649e0186918434225cda7272f8e1be974636084bd112ca',
                   'root': 'packages/mesh-snapshot',
                   'sources': ['source/snapshot.d'],
                   'testDigest': '43f3644760e94e327d1b8720790bf0c86c888f73fb3c9869f11e81839fdfc305',
                   'testImports': ['../source', 'source'],
                   'testLower': ['math', 'mesh', 'mesh-change', 'plane-bytes', 'profiling'],
                   'testSources': ['../source/snapshot.d',
                                   'source/tests/unit/mesh_map_kind_snapshot_test.d',
                                   'source/tests/unit/mesh_selsets_snapshot_test.d',
                                   'source/tests/unit/mesh_wire_snapshot_test.d',
                                   'source/tests/unit/snapshot_test.d']},
 'mesh-topology': {'external': {},
                   'lower': ['log'],
                   'name': 'vibe3d-mesh-topology',
                   'ordinaryDigest': '55521c0009da78a7d0c32e1cdb2961a35c184dfdd423f128766c67aa811cd0e9',
                   'root': 'packages/mesh-topology',
                   'sources': ['source/mesh_topo.d'],
                   'testDigest': 'db4f3024e9a852157cb77f8404677d488efb358b68355259a8037bc547618f39',
                   'testImports': ['../source', 'source'],
                   'testLower': ['log'],
                   'testSources': ['../source/mesh_topo.d']},
 'parallel': {'external': {},
              'lower': [],
              'name': 'vibe3d-parallel',
              'ordinaryDigest': 'ce1ae4055f6d38f6041dc6a4cf82efac7833e07f6263a36895da079eefe706ba',
              'root': 'util/parallel',
              'sources': ['source/tsan_annotate.d'],
              'testDigest': 'f0c446f91e5d7c4bf7638a94ecd8e937f15d03958d39ecede9eaa92f17210e93',
              'testImports': ['../source', 'source'],
              'testLower': [],
              'testSources': ['../source/tsan_annotate.d']},
 'param-schema': {'external': {},
                  'lower': ['math'],
                  'name': 'vibe3d-param-schema',
                  'ordinaryDigest': 'aaf52380bf6bd3749be846f991a4c4ec566a37e15404fe0884b0bbbb2dfd808d',
                  'root': 'packages/param-schema',
                  'sources': ['source/argstring.d', 'source/params.d'],
                  'testDigest': 'acc294d1a4b08243835a26662ff70d8c1951b96b5fc4129fd2f0081d88dac9dd',
                  'testImports': ['source', '../source'],
                  'testLower': ['math'],
                  'testSources': ['../source/argstring.d',
                                  '../source/params.d',
                                  'source/tests/unit/argstring_test.d',
                                  'source/tests/unit/param_cast_overflow_test.d',
                                  'source/tests/unit/params_test.d']},
 'pipe-contracts': {'external': {},
                    'lower': ['edit-contracts', 'math', 'mesh', 'spatial'],
                    'name': 'vibe3d-pipe-contracts',
                    'ordinaryDigest': '0ab9c7dc84dbe191078eef9818dfda61d1e486f3dcc46a9cfb5cc20ab41c6682',
                    'root': 'packages/pipe-contracts',
                    'sources': ['source/operator.d', 'source/toolpipe/packets.d'],
                    'testDigest': '255037c083299e09d6c2825cbeae24ef616320ab5daf71006f846d659380ed10',
                    'testImports': ['../source', 'source'],
                    'testLower': ['edit-contracts', 'math', 'mesh', 'spatial'],
                    'testSources': ['../source/operator.d',
                                    '../source/toolpipe/packets.d',
                                    'source/tests/unit/operator_test.d',
                                    'source/tests/unit/toolpipe/packets_test.d']},
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
                     'ordinaryDigest': 'a1fb4c13591738f2f6ab0c256546e4581b7abe72795aa5a342630db0ed9a72d7',
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
                     'testDigest': '91cfc49b35777e7f2d8e9507cc6b91b1d1e20bfcb5ae4c6420fd765e6821cad3',
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
                  'ordinaryDigest': '55c08d5c93ea29597f41748ef6244546919fa301a71a0fecbf7de5f9fa7bf25c',
                  'root': 'packages/pipe-runtime',
                  'sources': ['source/falloff.d',
                              'source/toolpipe/pipeline.d',
                              'source/toolpipe/stage.d',
                              'source/toolpipe/subject.d'],
                  'testDigest': 'b0ff546de1d52c5881aab17631a3253e2e079875de1190ba716a8920be1bdec8',
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
                 'name': 'vibe3d-plane-bytes',
                 'ordinaryDigest': '626d4bfd2849d69c132d6ca8ece912319274492e02a62b303562e9117fe881c1',
                 'root': 'util/plane-bytes',
                 'sources': ['source/plane_bytes.d'],
                 'testDigest': '58645395c0ab60e04092979d34f05fce94310a8516024e91fcfd420b3a02d451',
                 'testImports': ['../source', 'source'],
                 'testLower': [],
                 'testSources': ['../source/plane_bytes.d']},
 'profiling': {'external': {},
               'lower': [],
               'name': 'vibe3d-profiling',
               'ordinaryDigest': '634d00d2275bf6a288b1fb493dc64c671846cc38e5818384db45ca86d95f3212',
               'root': 'packages/profiling',
               'sources': ['source/perf_probe.d'],
               'testDigest': '1a540038f336056162523530a5ddbd457cc53ea37c8fd39410374bfbc228acaa',
               'testImports': ['../source', 'source'],
               'testLower': [],
               'testSources': ['../source/perf_probe.d']},
 'screen-buckets': {'external': {},
                    'lower': [],
                    'name': 'vibe3d-screen-buckets',
                    'ordinaryDigest': 'c56e92c1ce6a1a8abfe918893ec3fda02279ba4a8bde1ba67eafa41ef7ad4502',
                    'root': 'util/screen-buckets',
                    'sources': ['source/screen_buckets.d'],
                    'testDigest': 'be22937dac362e8937df9ca8b70aea60a99cc732413fe3ecfa1fb408ea808e7e',
                    'testImports': ['../source', 'source'],
                    'testLower': [],
                    'testSources': ['../source/screen_buckets.d']},
 'spatial': {'external': {},
             'lower': ['math'],
             'name': 'vibe3d-spatial',
             'ordinaryDigest': '598bfe820ed2bb7c21bdadeba4a4a8a1f8ac221ccee61b8e79f6e1ad71524839',
             'root': 'packages/spatial',
             'sources': ['source/item_xform.d',
                         'source/spatial.d',
                         'source/symmetry_plane.d',
                         'source/trackball.d',
                         'source/workplane_basis.d'],
             'testDigest': '7d173abafeec7c2d6ae71cc8d8bb48d420e6e6b7f7564badde647c0dccdbd37b',
             'testImports': ['../source', 'source'],
             'testLower': ['math'],
             'testSources': ['../source/item_xform.d',
                             '../source/spatial.d',
                             '../source/symmetry_plane.d',
                             '../source/trackball.d',
                             '../source/workplane_basis.d',
                             'source/tests/unit/spatial_test.d']},
 'subpatch-preview': {'external': {'bindbc-opengl': '~>1.1.1',
                                   'd-opensubdiv': {'repository': 'git+https://github.com/shulc/D-OpenSubdiv.git',
                                                    'version': 'e74bb683d869d31ddcb279b2f05bfaebd53065ee'}},
                      'lower': ['common',
                                'display-policy',
                                'interaction-query',
                                'log',
                                'math',
                                'mesh',
                                'mesh-change',
                                'profiling',
                                'viewport-gpu'],
                      'name': 'vibe3d-subpatch-preview',
                      'ordinaryDigest': 'ee97f27e620de574461da3df68c6a800c05c684ba548a6cca7303f953c5c26e4',
                      'root': 'packages/subpatch-preview',
                      'sources': ['source/subpatch_factories.d',
                                  'source/subpatch_osd.d',
                                  'source/subpatch_preview.d',
                                  'source/subpatch_worker.d',
                                  'source/subpatch_worker_web.d'],
                      'testDigest': '7f6e84d490c8a02bbb26ac103e05d29731004c5067398c7b2361a9e63bc47952',
                      'testImports': ['source', '../source'],
                      'testLower': ['common',
                                    'display-policy',
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
                'lower': ['common', 'mesh', 'mesh-snapshot'],
                'name': 'vibe3d-tool-state',
                'ordinaryDigest': '0f7b592ba3c83e9c32e8a9dc4374e33ac8fe57409937709cb9f071246fdf63be',
                'root': 'packages/tool-state',
                'sources': ['source/tools/common/session_mesh_key.d', 'source/tools/edit/preview_rebuild.d'],
                'testDigest': '0e82bf2f97170a2d123f44698b0f7543fc525dab51782f2bc19126123fc74c9a',
                'testImports': ['source', '../source'],
                'testLower': ['common', 'math', 'mesh', 'mesh-edit-log', 'mesh-snapshot'],
                'testSources': ['../source/tools/common/session_mesh_key.d',
                                '../source/tools/edit/preview_rebuild.d',
                                'source/tests/unit/session_mesh_key_stamp_as_test.d',
                                'source/tests/unit/tool_state_population_test.d',
                                'source/tests/unit/tools/common/session_mesh_key_test.d',
                                'source/tests/unit/tools/edit/preview_rebuild_test.d']},
 'transform-ops': {'external': {},
                   'lower': ['common',
                             'document-model',
                             'interaction-query',
                             'math',
                             'mesh',
                             'mesh-edit-log',
                             'pipe-contracts',
                             'pipe-runtime',
                             'profiling',
                             'spatial'],
                   'name': 'vibe3d-transform-ops',
                   'ordinaryDigest': '6299599f2c044cf1cd8e867ef2292307f1dc16d1f55e0b9a4274c222460a9410',
                   'root': 'packages/transform-ops',
                   'sources': ['source/tools/transform/arcball.d',
                               'source/tools/transform/cluster_values.d',
                               'source/tools/transform/item_xform_kernels.d',
                               'source/tools/transform/morph_route.d',
                               'source/tools/transform/relocate_plane.d',
                               'source/tools/transform/scale_input.d',
                               'source/tools/transform/xform_kernels.d'],
                   'testDigest': '33593e6ab67b32271885423003416ec4d7220d42e5935453720157dbd5261d4b',
                   'testImports': ['source', '../source'],
                   'testLower': ['common',
                                 'document-model',
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
                  'lower': ['common', 'display-policy', 'math', 'mesh', 'mesh-change', 'profiling', 'spatial'],
                  'name': 'vibe3d-viewport-gpu',
                  'ordinaryDigest': '023ee41be3dc6f720d2952e6b895d8459a7c5dc3c4872bb6b14d6e5a6ae7bd5b',
                  'root': 'packages/viewport-gpu',
                  'sources': ['source/gl_thread_guard.d',
                              'source/gpu_pass_timer.d',
                              'source/gpu_select.d',
                              'source/mesh_gpu.d',
                              'source/shader.d',
                              'source/viewport_env.d'],
                  'testDigest': 'ac610e9310aa2c1477c6277a87267bb4e5d97a0b98f1aa6aafde0d0f24282b37',
                  'testImports': ['source', '../source'],
                  'testLower': ['common',
                                'display-policy',
                                'edit-contracts',
                                'log',
                                'math',
                                'mesh',
                                'mesh-change',
                                'mesh-edit-log',
                                'mesh-edit-replay',
                                'mesh-snapshot',
                                'profiling',
                                'spatial'],
                  'testSources': ['../source/gl_thread_guard.d',
                                  '../source/gpu_pass_timer.d',
                                  '../source/gpu_select.d',
                                  '../source/mesh_gpu.d',
                                  '../source/shader.d',
                                  '../source/viewport_env.d',
                                  'source/tests/unit/viewport_env_test.d',
                                  'source/tests/unit/viewport_gpu_population_test.d']}}
CONFIGS = ('modeling', 'modeling-noai', 'with-render', 'web', 'root-tests')
HOOKS = ('preGenerateCommands', 'postGenerateCommands', 'preBuildCommands',
         'postBuildCommands', 'preRunCommands', 'postRunCommands')
FIXTURES = {'input-events': ('config/shortcuts.yaml', '99c14eaa556d365f42ead60e30db9aa926723b0ee0a9b1ae4f823542a10fbff8'),
            'viewport-gpu': ('assets/icon/png/vibe3d_16.png', '2efe412bb268afa882bbde043473c4e3990302ef76899938914b3e525ce7817e'),
            'mesh-preview': ('tests/fixtures/morph_routing_laws.json', '9067efdbbeac2c37f72f365648e49ecf9fea1ded0d0dcf3bb4c65ecdcd06356c'),
            'pipe-runtime': ('tests/fixtures/falloff_selection_bake.json', '336f6524a11ecd585a525522467c3db1d2dca251da69ffb73cbeaad592d63404')}

# Existing external predicates extend only to declared query/interchange owners.
REVISIONS = dict(legacy_REVISIONS, **{
    'd-bvh': ('e1a8f41501f94a28dbac99efbea850ed098fa728', 'git+https://github.com/shulc/D-BVH.git'),
    'lwo2-writer': ('6d35b70a2a23c16c5b6cc19ea3e2d05a99eb0061', 'git+https://github.com/shulc/D-Lwo2Writer.git'),
    'bindbc-assimp6': ('3b7c87431b12418a32e70cb065fc63fd6cc98b13', 'git+https://github.com/shulc/D-BindBC-Assimp.git'),
})
EXTERNAL_DEPS = dict(legacy_EXTERNAL_DEPS, **{'d-bvh': (), 'lwo2-writer': (),
    'bindbc-assimp6': ('bindbc-common', 'bindbc-loader')})
ARCHIVES = dict(legacy_ARCHIVES, **{'d-bvh': 'libd-bvh.a',
    'lwo2-writer': 'lib/liblwo2-writer.a', 'bindbc-assimp6': 'lib/libbindbc-assimp6.a'})

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
    if 'd-bvh' in names:
        libs.update(('dbvh_c', 'stdc++', 'm'))
        lflags.add('-L'+str(roots['d-bvh']/'build'))
    if 'bindbc-assimp6' in names:
        libs.update(('stdc++', 'm'))
        lflags.update(str(roots['bindbc-assimp6']/p) for p in
                      ('lib/libassimp.a', 'lib/libzlibstatic.a'))
    return libs, lflags

def validate_external(package, web=False):
    name=package['name'];path=Path(package['path']).resolve()
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

def production_files(project, owner):
    spec = SPECS[owner]
    return sorted((project/spec['root']/p).resolve() for p in spec['sources'])

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
    for lower in closure(owner, True): files += production_files(project, lower)
    require(len(files)==len(set(files)), 'support explicit source ownership overlaps: '+owner)
    return sorted(files)

def check_raw_tree(project, owner):
    for selected in closure(owner)|closure(owner,True)|{owner}:
        spec=SPECS[selected]; root=project/spec['root']
        for tests in (False,True):
            path=root/('tests/dub.json' if tests else 'dub.json')
            require(path.is_file(),'support selected descriptor missing: '+selected)
            raw=json.loads(path.read_text())
            require(canonical_digest(raw)==spec['testDigest' if tests else 'ordinaryDigest'],
                    'support descriptor contract: '+selected+(' tests' if tests else ' production'))
        found=sorted(p.resolve() for p in (root/'source').rglob('*.d'))
        require(found==production_files(project,selected),'support production source identity: '+selected)
        require(all(p.is_file() for p in test_files(project,selected)), 'support missing compiler root: '+selected)
        test_root=root/'tests'
        expected_carriers=sorted((test_root/p).resolve() for p in spec['testSources'] if p.startswith('source/'))
        # C custody: cross-common cut is present for root only, never ops algorithm.
        if selected=='mesh-ops':expected_carriers=sorted(expected_carriers+[(test_root/'source/tests/unit/mesh_ops/cut_test.d').resolve()])
        require(sorted(p.resolve() for p in (test_root/'source').rglob('*.d'))==expected_carriers,
                'support public carrier identity: '+selected)
    if owner in FIXTURES:
        path,sha=FIXTURES[owner]
        require(hashlib.sha256((project/path).read_bytes()).hexdigest()==sha,'support fixture identity: '+owner)

def validate_description(description, project, owner, config, tests=False, harness=None, compiler="dmd"):
    root_name=SPECS[owner]['name']+('-tests' if tests else '')
    require(description['rootPackage']==root_name,'support resolved root package: '+owner)
    active_list=[p for p in description['packages'] if p.get('active')]
    active={p['name']:p for p in active_list}
    require(len(active)==len(active_list),'support resolved package population duplicate')
    expected={SPECS[x]['name'] for x in closure(owner,tests)}|{root_name}
    internal={n for n in active if n.startswith('vibe3d-')}
    require(internal==expected,'support resolved internal package population: '+owner)
    external=set()
    for name in internal:
        selected=name.removeprefix('vibe3d-').removesuffix('-tests')
        path=project/SPECS[selected]['root']/('tests' if name.endswith('-tests') else '')
        raw, cfg=raw_config(path,active[name]['configuration'])
        external.update(k for k in set(raw.get('dependencies',{}))|set(cfg.get('dependencies',{})) if not k.startswith('vibe3d-'))
    require(set(active)-internal==external_closure(external,config=='web'), 'support resolved external package population: '+owner)
    for name in set(active)-internal:validate_external(active[name],config=='web')
    for name in internal:
        is_test=name.endswith('-tests'); selected=name.removeprefix('vibe3d-').removesuffix('-tests')
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
        require(package['targetType']==('executable' if is_test else 'sourceLibrary' if tests or config=='root-tests' else 'staticLibrary'),
                'support resolved compiler owner: '+name)
        files=sorted((path/f['path']).resolve() for f in package['files'] if f['role']=='source')
        own_files=sorted((path/p).resolve() for p in spec['testSources']) if is_test else production_files(project,selected)
        if is_test and harness is not None: own_files.append(harness.resolve());own_files.sort()
        require(files==own_files,'support resolved sourceFiles: '+name)
        expected_flags = ['--singleobj'] if (selected == 'mesh-ops' and not is_test and
            config_grants['name'] in ('modeling', 'modeling-noai', 'with-render', 'web') and
            Path(compiler).name in ('ldc', 'ldc2')) else []
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
    expected_targets=set() if config=='root-tests' else {n for n,p in active.items() if p['targetType']!='sourceLibrary'}
    require(set(targets)==expected_targets,'support resolved target population: '+owner)
    for name,target in targets.items():
        if not name.startswith('vibe3d-'):continue
        settings=target['buildSettings']
        selected=name.removeprefix('vibe3d-').removesuffix('-tests')
        expected_sources=test_files(project,selected) if name.endswith('-tests') else production_files(project,selected)
        if name.endswith('-tests') and harness is not None:expected_sources.append(harness.resolve())
        actual=[Path(p).resolve() for p in settings.get('sourceFiles',[])]
        require(sorted(actual)==sorted(expected_sources) and len(actual)==len(set(actual)),
                'support target compiler source identity: '+name)
        require(not any(x=='-i' or x.startswith(('-i=','--include-imports')) for x in settings.get('dflags',[])),
                'support target include-import flags: '+name)
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
        archives={str(roots[n]/(ARCHIVES[n] if n in ARCHIVES else 'lib'+n+'.a')) for n in seen-{name}
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

def compiler_commands(output, compiler_cwd=None):
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


def validate_actual_compiler(commands, project, owner, description, home, harness):
    own=str(production_files(project,owner)[0]);compiles=[c for c in commands if own in c['sourceInputs']]
    require(len(compiles)==1,'support actual compiler source identity: '+owner)
    command=compiles[0];sources=command['sourceInputs']
    generated=[p for p in sources if Path(p).name=='dub_test_root.d' and Path(p).is_relative_to(home/'cache'/(SPECS[owner]['name']+'-tests')/'~master'/'code')]
    expected=[str(p) for p in test_files(project,owner)]+[str(harness.resolve())]+generated
    require(len(generated)==1 and len(sources)==len(set(sources)) and sorted(sources)==sorted(expected),
            'support actual compiler source identity: '+owner)
    require(not any(x=='-i' or x.startswith(('-i=','--include-imports')) for x in command['argv']),
            'support actual compiler include-import flags: '+owner)
    for c in commands:
        require(not any('libvibe3d-' in Path(p).name for p in c['archiveInputs']),
                'support actual overlapping internal D archives: '+owner)
    links=[c for c in commands if any(p in c['objectInputs'] for p in command['outputs'])]
    require(len(links)==1,'support actual compiler D archive inputs: '+owner)
    linked=links[0]
    active={p['name']:p for p in description['packages'] if p.get('active')}
    static={n:ARCHIVES[n] for n,p in active.items() if not n.startswith('vibe3d-') and p['targetType'] in ('staticLibrary','library')}
    archives=linked['archiveInputs']
    require(len(archives)==len(static) and all(sum(Path(a).is_relative_to(home/'cache'/n) and Path(a).name==Path(filename).name for a in archives)==1 for n,filename in static.items()),
            'support actual compiler D archive inputs: '+owner)
    return {'compile':command,'link':linked,'generatedMain':generated[0],'staticOwners':sorted(static)}

def compiler_module(relative):
    if relative=='../../../tests/unit/mesh_by_value_gate.d':return 'tests.unit.mesh_by_value_gate'
    if relative=='../../../tests/unit/fixtures.d':return 'tests.unit.fixtures'
    return relative.removeprefix('../source/').removeprefix('source/').removesuffix('.d').replace('/','.')

# The frozen pre-compile identity is translated from the accepted root cell map.
# It is independent of the runtime roster observed below.
ENABLED_MODULES = frozenset(['argstring',
 'command',
 'command_history',
 'command_registry',
 'commands.mesh.session_edit',
 'commands.select.element',
 'eventlog',
 'gl_thread_guard',
 'io.image_decode',
 'io.lwo_import',
 'io.native',
 'io.scene_import',
 'io.scene_ir',
 'log',
 'math_geometry',
 'math_quaternion',
 'mesh',
 'mesh_corner_maps',
 'mesh_dirty',
 'mesh_edit_delta',
 'mesh_edit_log_protocol_test',
 'mesh_edit_replay',
 'mesh_edit_replay_roundtrip_test',
 'mesh_gpu',
 'mesh_ops.extrude',
 'mesh_ops.loop_slice',
 'mesh_ops.poly_bevel',
 'mesh_ops.triangulate',
 'mesh_planes',
 'mesh_topo',
 'plane_bytes',
 'record_observer_hub',
 'screen_buckets',
 'snap',
 'spatial',
 'symmetry',
 'tests.common_execution_roster_test',
 'tests.unit.alignment_ops_population_test',
 'tests.unit.argstring_test',
 'tests.unit.assimp_wire_test',
 'tests.unit.binding_resolve_test',
 'tests.unit.camera_stamp_test',
 'tests.unit.constraint_regression_test',
 'tests.unit.constraint_test',
 'tests.unit.display_policy_population_test',
 'tests.unit.document_test',
 'tests.unit.eventlog_parser_test',
 'tests.unit.eventlog_test',
 'tests.unit.falloff_screen_default_test',
 'tests.unit.falloff_selection_bake_test',
 'tests.unit.falloff_test',
 'tests.unit.fixtures',
 'tests.unit.input_events_population_test',
 'tests.unit.io.lwo_export_ptag_census_test',
 'tests.unit.io.lwo_export_test',
 'tests.unit.io.lwo_import_test',
 'tests.unit.io.native_test',
 'tests.unit.json_num_test',
 'tests.unit.math_test',
 'tests.unit.mesh_by_value_gate',
 'tests.unit.mesh_edge_slice_test',
 'tests.unit.mesh_edit_delta_test',
 'tests.unit.mesh_key_test',
 'tests.unit.mesh_map_kind_snapshot_test',
 'tests.unit.mesh_map_kind_test',
 'tests.unit.mesh_ops.bevel_fin_test',
 'tests.unit.mesh_ops.bevel_vertex_test',
 'tests.unit.mesh_ops.box_geom_corner_provenance_test',
 'tests.unit.mesh_ops.bridge_test',
 'tests.unit.mesh_ops.cleanup_test',
 'tests.unit.mesh_ops.connected_mask_test',
 'tests.unit.mesh_ops.extrude_test',
 'tests.unit.mesh_ops.face_alignment_test',
 'tests.unit.mesh_ops.face_merge_test',
 'tests.unit.mesh_ops.loop_slice_test',
 'tests.unit.mesh_ops.poly_bevel_test',
 'tests.unit.mesh_ops.revolve_seam_test',
 'tests.unit.mesh_ops.revolve_test',
 'tests.unit.mesh_ops.seam_differential',
 'tests.unit.mesh_ops.select_loop_test',
 'tests.unit.mesh_ops.triangulate_test',
 'tests.unit.mesh_ops.vertex_pos_grid_test',
 'tests.unit.mesh_plane_types_test',
 'tests.unit.mesh_selsets_replay_test',
 'tests.unit.mesh_selsets_snapshot_test',
 'tests.unit.mesh_selsets_test',
 'tests.unit.mesh_topology_integration_test',
 'tests.unit.mesh_wire_snapshot_test',
 'tests.unit.morph_routing_law_test',
 'tests.unit.operator_test',
 'tests.unit.ortho_relocate_prior_test',
 'tests.unit.param_cast_overflow_test',
 'tests.unit.params_test',
 'tests.unit.path_test',
 'tests.unit.seltype_test',
 'tests.unit.session_mesh_key_stamp_as_test',
 'tests.unit.snap_election_corpus_test',
 'tests.unit.snap_regression_test',
 'tests.unit.snap_test',
 'tests.unit.snapshot_test',
 'tests.unit.spatial_test',
 'tests.unit.subpatch_key_fold_test',
 'tests.unit.subpatch_level_policy_test',
 'tests.unit.subpatch_osd_test',
 'tests.unit.subpatch_preview_population_test',
 'tests.unit.symmetry_regression_test',
 'tests.unit.tool_input_test',
 'tests.unit.tool_state_population_test',
 'tests.unit.toolpipe.obbox_regression_test',
 'tests.unit.toolpipe.obbox_test',
 'tests.unit.toolpipe.packets_test',
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
 'tests.unit.tools.common.session_mesh_key_test',
 'tests.unit.tools.create.pen_geometry_population_test',
 'tests.unit.tools.create.pen_geometry_test',
 'tests.unit.tools.edit.preview_rebuild_test',
 'tests.unit.tools.transform.arcball_regression_test',
 'tests.unit.tools.transform.arcball_test',
 'tests.unit.tools.transform.item_xform_kernels_test',
 'tests.unit.tools.transform.item_xform_regression_test',
 'tests.unit.tools.transform.morph_route_test',
 'tests.unit.tools.transform.scale_input_test',
 'tests.unit.tools.transform.transform_ops_population_test',
 'tests.unit.tools.transform.xform_kernels_test',
 'tests.unit.vertex_normals_test',
 'tests.unit.viewgrid_regression_test',
 'tests.unit.viewgrid_test',
 'tests.unit.viewport_env_test',
 'tests.unit.viewport_gpu_population_test',
 'tests.unit.viewport_scheme_test',
 'tests.unit.weightmap_state_test',
 'tests.unit.workplane_fit_test',
 'tool_input',
 'toolpipe.stages.actcenter',
 'toolpipe.stages.axis',
 'toolpipe.stages.constrain',
 'toolpipe.stages.falloff',
 'toolpipe.stages.snap',
 'tools.alignment.align_kernels',
 'tools.common.session_mesh_key',
 'tools.transform.relocate_plane_test',
 'trackball',
 'view'])

def validate_runtime(output, owner):
    totals=re.findall(r'^(\d+) modules passed unittests$',output,re.M)
    require(len(totals)==1 and int(totals[0])>0,'NO-VERDICT: support nonzero druntime total')
    roster=re.findall(r'^PKG-MODULE name=(\S+) unittest=([01])$',output,re.M)
    require(roster and len(roster)==len(set(n for n,_ in roster)),'NO-VERDICT: support runtime roster identity')
    # Every explicit own/lower production input and every public carrier occurs
    # once; private/public enabled identities keep their original guards.
    own={compiler_module(p) for p in SPECS[owner]['testSources']}
    for selected in closure(owner,True)|{owner}:
        modules={compiler_module(p) for p in SPECS[selected]['sources']}
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


def stage_dependencies(active, archive, evidence, env):
    home = evidence / 'dub-home'
    home.mkdir()
    env['DUB_HOME'] = str(home)
    receipts = {}
    for name, package in active.items():
        if name.startswith('vibe3d-'):
            continue
        original = Path(package['path']).resolve()
        staged = (home / 'packages' / name / REVISIONS[name][0] / name
                  if name in REVISIONS else archive / 'dependencies' / name)
        # Fresh D archives and native outputs must be built in this copy.
        shutil.copytree(original, staged, ignore=shutil.ignore_patterns('.git', '.dub', 'build', 'out', '*.a', '*.o', '*.obj', '*.lib'))
        files = {str(p.relative_to(staged)): legacy_digest(p) for p in sorted(staged.rglob('*')) if p.is_file()}
        legacy_require(files and 'dub.json' in files, 'PREPARATION-REFUSED: dependency source missing: ' + name)
        for relative, sha in files.items():
            legacy_require(legacy_digest(original / relative) == sha, 'PREPARATION-REFUSED: dependency staging changed: ' + name)
        if name in REVISIONS:
            revision = legacy_native_revision(original)
            legacy_require(revision == REVISIONS[name][0], 'PREPARATION-REFUSED: native source revision: ' + name)
            (staged / '.boundary-revision').write_text(revision + '\n')
        legacy_run(['git', 'init', '-q', str(staged)], archive, env, evidence, 'initialize-' + name)
        legacy_run(['dub', 'add-local', str(staged), package['version']], archive, env, evidence, 'register-' + name)
        receipts[name] = {'original': str(original), 'staged': str(staged), 'version': package['version'], 'files': files}
    (evidence / 'dependency-sources.json').write_text(json.dumps(receipts, indent=2))
    return receipts

def run(command,cwd,env,evidence,name):
    result=subprocess.run(command,cwd=cwd,env=env,text=True,capture_output=True)
    (evidence/(name+'.stdout.log')).write_text(result.stdout);(evidence/(name+'.stderr.log')).write_text(result.stderr)
    (evidence/(name+'.command.json')).write_text(json.dumps({'argv':command,'cwd':str(cwd),'exit':result.returncode},indent=2))
    require(result.returncode==0,'support command failed: '+name+': '+next((s for s in (result.stdout+result.stderr).splitlines() if 'Error:' in s or 'AssertError@' in s),'see logs'))
    return result

def describe(project,owner,config,compiler,env,evidence,tests=False,recipe=None,harness=None):
    root=project/SPECS[owner]['root']/('tests' if tests else '')
    command=['dub','describe','--root='+str(root),'--config='+config,'--compiler='+compiler,'--quiet']
    if recipe:command+=['--recipe='+str(recipe)]
    name=config+('-tests' if tests else '')+('-receipt' if recipe else '')
    result=run(command,project,env,evidence,name);description=json.loads(result.stdout)
    validate_description(description,project,owner,config,tests,harness,compiler)
    (evidence/(name+'.json')).write_text(json.dumps(description,indent=2))
    return description

def execute(project,owner,compiler,env,evidence):
    require(not subprocess.check_output(['git','status','--porcelain'],cwd=project,text=True).strip(),
            'PREPARATION-REFUSED: execute requires a clean committed worktree')
    sha=subprocess.check_output(['git','rev-parse','HEAD'],cwd=project,text=True).strip()
    archive=evidence/'archive';require(not archive.exists(),'PREPARATION-REFUSED: archive exists');archive.mkdir()
    members=[SPECS[n]['root'] for n in closure(owner)|closure(owner,True)|{owner}]
    # Exact read-only support carrier accepted in C; no desktop production root.
    if 'mesh-ops' in closure(owner)|closure(owner,True)|{owner}:
        members += ['tests/unit/mesh_by_value_gate.d', 'tests/unit/fixtures.d']
    if owner in FIXTURES:members.append(FIXTURES[owner][0])
    import tarfile
    tar=evidence/'committed.tar'
    with tar.open('wb') as stream:subprocess.run(['git','archive',sha,'--']+members,cwd=project,stdout=stream,check=True)
    with tarfile.open(tar) as stream:stream.extractall(archive,filter='data')
    require(not (archive/'source').exists() and not (archive/'dub.json').exists(),'PREPARATION-REFUSED: desktop production root')
    check_raw_tree(archive,owner)
    root=archive/SPECS[owner]['root'];
    # DUB owns external native dependencies; all internal source roots are the isolated archive.
    original=describe(project,owner,'modeling-noai',compiler,env,evidence)
    active={p['name']:p for p in original['packages'] if p.get('active')}
    dependencies=stage_dependencies(active,archive,evidence,env)
    production=describe(archive,owner,'modeling-noai',compiler,env,evidence)
    for package in production['packages']:
        if package.get('active') and not package['name'].startswith('vibe3d-'):
            require(Path(package['path']).resolve()==Path(dependencies[package['name']]['staged']).resolve(),
                    'PREPARATION-REFUSED: canonical dependency cache selected: '+package['name'])
    legacy_validate_staged_fixture(legacy_fixture_receipt(archive,owner,FIXTURES),legacy_fixture_receipt(project,owner,FIXTURES),owner,archive,FIXTURES)
    built=run(['dub','build','--root='+str(root),'--config=modeling-noai','--compiler='+compiler,'--force','--verbose'],archive,env,evidence,'production-build')
    require((root/('lib'+SPECS[owner]['name']+'.a')).is_file(),'NO-VERDICT: ordinary static archive missing')
    harness=root/'tests/boundary_roster.d'
    receipt_source='module boundary_roster; import std.stdio : writeln; import std.file : getcwd,read; import std.digest.sha : sha256Of; import std.digest : toHexString; import std.string : toLower; shared static this() { writeln("PKG-CWD path=",getcwd()); foreach(info; ModuleInfo) if(info !is null) writeln("PKG-MODULE name=",info.name," unittest=",info.unitTest !is null ? 1:0);'
    if owner in FIXTURES:receipt_source += legacy_fixture_observer_statement(archive,owner,FIXTURES)
    harness.write_text(receipt_source+' }\n')
    raw=json.loads((root/'tests/dub.json').read_text());raw['sourceFiles'].append('boundary_roster.d');recipe=root/'tests/dub.boundary.json';recipe.write_text(json.dumps(raw))
    config=json.loads((root/'tests/dub.json').read_text())['configurations'][0]['name']
    description=describe(archive,owner,config,compiler,env,evidence,True,recipe,harness)
    tested=run(['dub','test','--root='+str(root/'tests'),'--recipe='+str(recipe),'--config='+config,'--compiler='+compiler,'--force','--verbose'],archive,env,evidence,'algorithm-run')
    output=tested.stdout+tested.stderr
    expected_cwd=archive if owner in ('input-events', 'mesh-preview', 'document-model', 'param-schema', 'pipe-runtime', 'pipe-evaluation') else root/'tests'
    require(re.findall(r'^PKG-CWD path=(.+)$',output,re.M)==[str(expected_cwd)],'support algorithm actual working directory: '+owner)
    if owner in FIXTURES:
        require(re.findall(r'^PKG-FIXTURE sha256=(.+)$',output,re.M)==[FIXTURES[owner][1]],'support algorithm actual fixture hash: '+owner)
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
    (evidence/'actual-input-hashes.json').write_text(json.dumps(input_hashes,indent=2))
    (evidence/'actual-compiler-argv.json').write_text(json.dumps(commands,indent=2));(evidence/'witness.json').write_text(json.dumps({'sha':sha,'actualOwnership':actual,'runtime':runtime},indent=2))
    print('PKG-EXECUTE package='+owner+' sha='+sha+' modules='+str(runtime['modules']))

def self_test():
    # The accepted 794 historical fixture controls stay available to the root
    # gate; D does not repeat that catalog. Their flat-common control domain is
    # separate from the final production manifests below.
    legacy_self_test()

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--package',choices=tuple(SPECS));parser.add_argument('--root',default=str(Path(__file__).resolve().parents[1]));parser.add_argument('--compiler',default='dmd');parser.add_argument('--evidence-dir')
    modes=parser.add_mutually_exclusive_group(required=True);modes.add_argument('--self-test',action='store_true');modes.add_argument('--check',action='store_true');modes.add_argument('--execute',action='store_true');args=parser.parse_args(argv)
    if args.self_test:self_test()
    else:
        require(not args.execute or args.package is not None,'execute requires selected package')
        project=Path(args.root).resolve();compiler=shutil.which(args.compiler);require(compiler is not None,'compiler not found')
        if 'ldc' in Path(compiler).name:require(Path(compiler).resolve()==Path.home()/'.local/dlang/ldc2-1.42.0-linux-x86_64/bin/ldc2','support checker requires project LDC compiler')
        env=os.environ.copy()
        for key in ('DISPLAY','WAYLAND_DISPLAY','SDL_VIDEODRIVER','DFLAGS'):env.pop(key,None)
        for owner in (args.package,) if args.package else SPECS:
            check_raw_tree(project,owner)
            if args.execute:
                require(args.evidence_dir is not None,'execute requires evidence directory');evidence=Path(args.evidence_dir);require(evidence.is_absolute() and not evidence.resolve().is_relative_to(project),'evidence must be absolute outside worktree');evidence.mkdir(parents=True,exist_ok=True);execute(project,owner,compiler,env,evidence)
            else:
                with tempfile.TemporaryDirectory(prefix='support-describe-') as tmp:
                    configs=CONFIGS if args.package else ('modeling-noai',)
                    for config in configs:describe(project,owner,config,compiler,env,Path(tmp))
                    config=json.loads((project/SPECS[owner]['root']/'tests/dub.json').read_text())['configurations'][0]['name']
                    describe(project,owner,config,compiler,env,Path(tmp),True)
            print('PKG-CHECK package='+owner)
    print('PKG-BOUNDARY-VERDICT=GREEN');return 0

if __name__=='__main__':
    try:sys.exit(main())
    except (BoundaryError,OSError,ValueError,KeyError,subprocess.SubprocessError) as error:
        print('PKG-BOUNDARY-VERDICT=RED Error: '+str(error),file=sys.stderr);sys.exit(1)
