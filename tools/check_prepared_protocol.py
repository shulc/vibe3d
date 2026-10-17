#!/usr/bin/env python3
"""Prepared protocol: source population and forbidden entry paths only.

Types/signatures are asserted by prepared_protocol_types_test.d; state, ordering
and refusal behavior belong to D tests. Tool self-tests run separately with
python3 tools/test_prepared_protocol.py (task 20263060).
"""
from __future__ import annotations

import ast
from collections import Counter
from pathlib import Path
import json
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / 'dspans'))
import dspans_client as d  # noqa: E402

INTERACTIVE = 'vibe3d.editing.tools.interactive'
TRANSITION = INTERACTIVE + '.prepared_tool_transition'
APP = 'vibe3d.apps.desktop.app'
TOKEN_TEST = ('libraries/editing/tools/interactive/tests/source/vibe3d/editing/'
              'tools/interactive/unit/prepared_tool_transition_test.d')
TYPE_TEST = 'tests/unit/prepared_protocol_types_test.d'
PUBLISHERS = {'prepareArm', 'commitPreparedArm', 'prepareDrop',
              'commitPreparedDrop', 'producePreparedEffects', 'installLegacyPreparedEffects'}
HOOKS = {'activate', 'deactivate', 'update', 'onParamChanged', 'params'}
OWNER_CALLS = {
    'prepareRecordBatch': {'vibe3d.editing.commands.runtime.command_history'},
    'beginPreparedMesh': {'vibe3d.documents.model.document'},
    'beginPreparedDestroy': {'vibe3d.viewport.gpu.mesh_gpu', INTERACTIVE + '.handles.shapes'},
    'beginPreparedUpload': {'vibe3d.viewport.gpu.mesh_gpu'},
    'prepareCreateUpload': {'vibe3d.viewport.gpu.mesh_gpu',
                            INTERACTIVE + '.prepared_record_context',
                            INTERACTIVE + '.tools.alignment.radial_sweep_tool',
                            INTERACTIVE + '.tools.alignment.mirror',
                            INTERACTIVE + '.tools.edit.bridge_tool'},
}
TOKEN = re.compile(r'^(?:Prepared|Validated)\w*Token$')
CALL = re.compile(r'\b(' + '|'.join(sorted(PUBLISHERS | OWNER_CALLS.keys() | {'prepareDoorParamChanged'})) + r')\s*\(')


def source_files(root):
    """Production sources from the root recipe and its local subpackages."""
    recipes, files, seen = [root / 'dub.json'], set(), set()
    while recipes:
        recipe = recipes.pop()
        if recipe in seen:
            continue
        seen.add(recipe)
        data = json.loads(recipe.read_text())
        base = recipe.parent
        for sub in data.get('subPackages', []):
            if isinstance(sub, str):
                recipes.append(base / sub / 'dub.json')
        for relative in data.get('sourcePaths', ['source']):
            files.update((base / relative).rglob('*.d'))
        for relative in data.get('sourceFiles', []):
            path = base / relative
            if path.suffix == '.d':
                files.add(path)
    if not files:
        raise ValueError('no production D sources in local recipes')
    return sorted(files)


def blank(text, ranges):
    chars = list(text)
    for start, end in ranges:
        chars[start:end] = ['\n' if c == '\n' else ' ' for c in text[start:end]]
    return ''.join(chars)


def source_view(text):
    spans = d.spans(text, parse=True)
    if spans.lex_errors:
        raise ValueError('D lexer refused source: ' + str(spans.lex_errors))
    if spans.parse_errors:
        raise ValueError('D parser refused source: ' + str(spans.parse_errors))
    tests = [u['span'] for u in spans.unittests]
    tests += [(v['span'][0], v['trueBody'][1]) for v in spans.version_unittests if v['trueBody']]
    code = blank(text, spans.comments + spans.strings + tests)
    return code, spans


def string_rows(text, name):
    """Literal D string roster; comments cannot contribute rows."""
    spans = d.spans(text)
    visible = blank(text, spans.comments)
    match = re.search(r'\b' + re.escape(name) + r'\s*=\s*(\[.*?\])\s*;', visible, re.S)
    if not match:
        raise ValueError('missing string roster: ' + name)
    rows = ast.literal_eval(match[1])
    if not isinstance(rows, list) or not all(isinstance(row, str) for row in rows):
        raise ValueError('invalid string roster: ' + name)
    if len(set(rows)) != len(rows):
        raise ValueError('duplicate row in ' + name)
    return rows


def containing_function(functions, offset):
    enclosing = [f for f in functions if f['body'] and f['body'][0] < offset < f['body'][1]]
    return min(enclosing, key=lambda f: f['body'][1] - f['body'][0]) if enclosing else None


def declared_here(functions, name, offset):
    return any(f['name'] == name and f['declStart'] <= offset <
               (f['body'][0] if f['body'] else f['span'][1]) for f in functions)


def inspect_source(module, text):
    """No body hashes or source coordinates form part of an accepted identity."""
    code, spans = source_view(text)
    bad, tokens, writers, calls = [], set(), Counter(), []
    for aggregate in spans.aggregates:
        start = aggregate['declStart']
        if (aggregate['kind'] == 'struct' and aggregate['parent'] is None
                and TOKEN.fullmatch(aggregate['name']) and aggregate['body']
                and code[start:aggregate['body'][0]].strip()):
            tokens.add((module, aggregate['name']))
    for fn in spans.functions:
        if (module == TRANSITION and fn['name'] in PUBLISHERS - {'prepareArm', 'commitPreparedArm'}
                and code[fn['declStart']:fn['span'][1]].strip()):
            bad.append('unapproved prepared publisher: ' + fn['name'])
        if fn['body'] and code[fn['declStart']:fn['body'][0]].strip() and fn['aggregate'] and fn['name'] in HOOKS and (module == INTERACTIVE + '.tool' or module.startswith(INTERACTIVE + '.tools.')):
            writers[(module, fn['aggregate'], fn['name'])] += 1
    for call in CALL.finditer(code):
        symbol = call[1]
        if declared_here(spans.functions, symbol, call.start()):
            if symbol in PUBLISHERS and module != TRANSITION:
                bad.append('publisher declaration outside transition module: ' + symbol)
            continue
        fn = containing_function(spans.functions, call.start())
        caller = fn['name'] if fn else '<module>'
        calls.append((module, caller, symbol))
        if symbol in OWNER_CALLS:
            if module not in OWNER_CALLS[symbol]:
                bad.append('prepared resource owner bypass: ' + caller + ' -> ' + symbol)
        elif symbol == 'prepareDoorParamChanged':
            if (module, caller) != (TRANSITION, 'prepareArm'):
                bad.append('parameter door outside fresh-candidate preparation: ' + caller)
        elif (module, caller, symbol) not in ((APP, 'armPreparedTool', 'prepareArm'),
                                             (APP, 'armPreparedTool', 'commitPreparedArm')):
            bad.append('prepared publication bypass: ' + caller + ' -> ' + symbol)
    if re.search(r'\bnew\s+PreparedRecordContext\b', code) and module not in (TRANSITION, INTERACTIVE + '.prepared_record_context'):
        bad.append('production PreparedRecordContext construction outside transaction owner')
    for fn in spans.functions:
        if (module, fn['aggregate'], fn['name']) not in writers or not fn['body'] or fn['name'] == 'params':
            continue
        body = code[fn['body'][0]:fn['body'][1]]
        if re.search(r'\b(?:prepareActivate|prepareDeactivate|prepareParamChanged|prepareUpdate)\s*\(', body):
            bad.append('legacy hook entered prepared producer: ' + fn['aggregate'] + '.' + fn['name'])
    return bad, tokens, writers, calls


def check(root):
    bad, tokens, writers, calls, modules = [], set(), Counter(), [], set()
    if any((root / 'tests/compile_fail').glob('*.d')):
        bad.append('retired compile-fail fixtures have no compiler caller; use a D static assert')
    for path in source_files(root):
        text = path.read_text()
        # Avoid parsing unrelated geometry/math/IO bodies.
        if not (CALL.search(text) or re.search(r'Prepared\w*Token|Validated\w*Token|PreparedRecordContext|module\s+' + re.escape(INTERACTIVE) + r'\.(?:tools\.|tool\s*;)', text)):
            continue
        code = blank(text, d.spans(text).comments + d.spans(text).strings)
        head = re.search(r'\bmodule\s+([\w.]+)\s*;', code)
        if not head:
            raise ValueError('missing module declaration: ' + str(path))
        module = head[1]
        if module in modules:
            bad.append('duplicate production module: ' + module)
        modules.add(module)
        errors, found_tokens, found_writers, found_calls = inspect_source(module, text)
        bad += [str(path.relative_to(root)) + ': ' + error for error in errors]
        tokens.update(found_tokens)
        writers.update(found_writers)
        calls.extend(found_calls)
    listed = string_rows((root / TOKEN_TEST).read_text(), 'kTokenModules')
    actual = {module for module, _ in tokens}
    if not actual or set(listed) != actual:
        bad.append('token module census: missing=' + repr(sorted(actual-set(listed))) + ' surplus=' + repr(sorted(set(listed)-actual)))
    type_text = (root / TYPE_TEST).read_text()
    type_text = blank(type_text, d.spans(type_text).comments)
    expected_writers = Counter(re.findall(r'checkWriter!\("([\w.]+)", "(\w+)", "(\w+)", "[^"]+"\)', type_text))
    if not expected_writers or writers != expected_writers:
        bad.append('writer declaration census: missing=' + repr(sorted((writers-expected_writers).items())) + ' surplus=' + repr(sorted((expected_writers-writers).items())))
    public_calls = Counter(row for row in calls if row[2] in PUBLISHERS)
    expected_calls = Counter({(APP, 'armPreparedTool', 'prepareArm'): 1,
                              (APP, 'armPreparedTool', 'commitPreparedArm'): 1})
    if public_calls != expected_calls:
        bad.append('publication caller set changed: ' + repr(public_calls))
    param_calls = Counter(row for row in calls if row[2] == 'prepareDoorParamChanged')
    if param_calls != Counter({(TRANSITION, 'prepareArm', 'prepareDoorParamChanged'): 2}):
        bad.append('fresh-candidate parameter caller set changed: ' + repr(param_calls))
    return bad, len(tokens), len(actual), sum(writers.values())


def main():
    root = Path(__file__).resolve().parents[1]
    try:
        bad, tokens, modules, writers = check(root)
    except (OSError, ValueError, SyntaxError) as error:
        print('prepared protocol census: ' + str(error), file=sys.stderr)
        return 2
    if bad:
        print('prepared protocol census:\n  ' + '\n  '.join(bad), file=sys.stderr)
        return 2
    print(f'prepared protocol census PASS ({tokens} tokens, {modules} modules, {writers} writer declarations; entry paths checked)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
