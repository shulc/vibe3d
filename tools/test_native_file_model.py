#!/usr/bin/env python3
"""Negative fixtures for the native production boundary's resolved inputs."""
import unittest
from check_native_file_model import validate
from check_standalone_boundary import BoundaryError


class NativeInputs(unittest.TestCase):
    def setUp(self):
        self.modules = {name: '/fixture/' + name.replace('.', '/') + '.d' for name in
                        ('io.native', 'io.image_path', 'io.file_model', 'stb_image.c', 'mesh', 'document')}

        self.files = set(self.modules.values()) | {'/fixture/value' + str(n) + '.d' for n in range(20)}

    def test_normal_inputs(self):
        validate(self.modules, self.files, 0, True)

    def test_module_owners(self):
        for name in ('registry', 'tool', 'ui.synthetic', 'io.file_dialog',
                     'io.file_dialog_browser', 'io.browser_pick_resume'):
            with self.subTest(name=name), self.assertRaisesRegex(BoundaryError, 'forbidden compiler module'):
                validate(dict(self.modules, **{name: '/fixture/' + name + '.d'}), self.files, 0, True)

    def test_file_and_string_inputs(self):
        for name in ('/fixture/nfde/input.d', '/fixture/ui/imgui.txt', '/fixture/libnfde.a',
                     '/fixture/libsynthetic.a'):
            with self.subTest(name=name), self.assertRaisesRegex(BoundaryError, 'forbidden.*input|native archive'):
                validate(self.modules, self.files | {name}, 0, True)

    def test_compile_status_and_dependency_output(self):
        for status, has_deps in ((1, True), (0, False)):
            with self.subTest(status=status), self.assertRaisesRegex(BoundaryError, 'compile failed'):
                validate(self.modules, self.files, status, has_deps)

    def test_population_and_production_owners(self):
        with self.assertRaisesRegex(BoundaryError, 'population/owners missing'):
            validate(self.modules, set(self.modules.values()), 0, True)
        for name in ('io.native', 'io.image_path', 'io.file_model', 'stb_image.c', 'mesh', 'document'):
            with self.subTest(name=name), self.assertRaisesRegex(BoundaryError, 'population/owners missing'):
                validate({key: value for key, value in self.modules.items() if key != name}, self.files, 0, True)


if __name__ == '__main__':
    unittest.main()
