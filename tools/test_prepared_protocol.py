#!/usr/bin/env python3
"""Explicit tests of the boundary scanner; not part of the application suite."""
from pathlib import Path
import json
import tempfile
import unittest

import check_prepared_protocol as p


class ProtocolTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='vibe3d-protocol-check-')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.module = p.INTERACTIVE + '.tools.fixture'
        self.write('dub.json', json.dumps({'sourcePaths': ['source']}))
        self.write('source/app.d', f'''module {p.APP};
void armPreparedTool() {{ prepareArm(); commitPreparedArm(); }}
''')
        self.write('source/transition.d', f'''module {p.TRANSITION};
void prepareArm() {{
    client.prepareDoorParamChanged();
    client.prepareDoorParamChanged();
}}
bool commitPreparedArm() {{ return true; }}
''')
        self.write('source/tool.d', f'''module {self.module};
class Demo {{ void update() {{}} }}
struct PreparedFixtureToken {{}}
''')
        self.write(p.TOKEN_TEST, f'private enum string[] kTokenModules = ["{self.module}"];')
        self.write(p.TYPE_TEST, f'static assert(checkWriter!("{self.module}", "Demo", "update", "void()"));')

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def append(self, name, text):
        path = self.root / name
        path.write_text(path.read_text() + '\n' + text)

    def failures(self):
        return p.check(self.root)[0]

    def test_complete_current_contract(self):
        self.assertEqual(p.check(self.root), ([], 1, 1, 1))

    def test_comments_strings_and_test_code_cannot_add_callers_or_tokens(self):
        self.append('source/tool.d', '''
// prepareArm(); struct PreparedCommentToken {}
enum q = q{ commitPreparedArm(); struct PreparedStringToken {} };
/+ nested /+ prepareDrop(); +/ new PreparedRecordContext(null); +/
unittest { prepareArm(); struct PreparedTestToken {} }
version(unittest) { void f() { commitPreparedArm(); } struct PreparedVersionToken {} }
''')
        self.assertEqual(self.failures(), [])

    def test_source_coordinates_and_function_implementation_are_free(self):
        app = self.root / 'source/app.d'
        app.write_text('\n// additional documentation\n' + app.read_text().replace('prepareArm();', 'int harmless = 2 + 3; prepareArm();'))
        self.assertEqual(self.failures(), [])

    def test_extra_publisher_call_is_refused(self):
        self.append('source/tool.d', 'void escape() { prepareArm(); }')
        self.assertTrue(any('publication bypass' in e for e in self.failures()))

    def test_same_caller_name_in_wrong_module_is_refused(self):
        self.append('source/tool.d', 'void armPreparedTool() { commitPreparedArm(); }')
        self.assertTrue(any('publication bypass' in e for e in self.failures()))

    def test_missing_real_publisher_call_is_refused(self):
        self.write('source/app.d', f'module {p.APP}; void armPreparedTool() {{ prepareArm(); /* commitPreparedArm(); */ }}')
        self.assertTrue(any('publication caller set' in e for e in self.failures()))

    def test_unused_drop_publisher_is_refused(self):
        self.append('source/transition.d', 'void prepareDrop() {}')
        self.assertTrue(any('unapproved prepared publisher' in e for e in self.failures()))

    def test_parameter_door_cannot_escape(self):
        self.append('source/tool.d', 'void armed() { client.prepareDoorParamChanged(); }')
        self.assertTrue(any('parameter door outside' in e for e in self.failures()))

    def test_production_context_constructor_cannot_escape(self):
        self.append('source/tool.d', 'void escape() { auto c = new PreparedRecordContext(null); }')
        self.assertTrue(any('construction outside' in e for e in self.failures()))

    def test_resource_owner_cannot_be_bypassed(self):
        self.append('source/tool.d', 'void escape() { gpu.beginPreparedUpload(); }')
        self.assertTrue(any('resource owner bypass' in e for e in self.failures()))

    def test_legacy_hook_cannot_enter_prepared_producer(self):
        self.write('source/tool.d', f'module {self.module}; struct PreparedFixtureToken {{}} class Demo {{ void update() {{ prepareUpdate(); }} }}')
        self.assertTrue(any('legacy hook entered' in e for e in self.failures()))

    def test_new_writer_requires_compiler_contract(self):
        self.append('source/tool.d', 'class Added { void onParamChanged(string name) {} }')
        self.assertTrue(any('writer declaration census' in e for e in self.failures()))

    def test_new_token_module_requires_reflection_coverage(self):
        self.write('source/added.d', 'module added; struct ValidatedAddedToken {}')
        self.assertTrue(any('token module census' in e for e in self.failures()))

    def test_new_overload_is_not_hidden_by_the_existing_method_name(self):
        self.write('source/tool.d', f'module {self.module}; struct PreparedFixtureToken {{}} class Demo {{ void update() {{}} void update(int n) {{}} }}')
        self.assertTrue(any('writer declaration census' in e for e in self.failures()))

    def test_deleted_token_module_is_not_silently_excused(self):
        path = self.root / 'source/tool.d'
        path.write_text(path.read_text().replace('struct PreparedFixtureToken {}', ''))
        self.assertTrue(any('token module census' in e for e in self.failures()))

    def test_retired_compile_fail_directory_cannot_rot_green(self):
        self.write('tests/compile_fail/unused.d', 'static assert(false);')
        self.assertTrue(any('retired compile-fail' in e for e in self.failures()))

    def test_duplicate_roster_is_refused(self):
        self.write(p.TOKEN_TEST, f'private enum string[] kTokenModules = ["{self.module}", "{self.module}"];')
        with self.assertRaisesRegex(ValueError, 'duplicate row'):
            p.check(self.root)

    def test_invalid_lexical_input_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'lexer refused'):
            p.inspect_source('fixture', 'module fixture; enum s = "unterminated')


if __name__ == '__main__':
    unittest.main()
