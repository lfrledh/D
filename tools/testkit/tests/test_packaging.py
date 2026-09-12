import importlib.util
from pathlib import Path
import hashlib
import os
import tempfile
import unittest
from types import SimpleNamespace

SPEC = importlib.util.spec_from_file_location('kit_builder', Path(__file__).resolve().parents[1] / 'build_kit.py')
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class PackagingProtectionTests(unittest.TestCase):
    def setUp(self):
        root = os.environ.get('D_TEST_TEMP_DIR')
        if not root:
            raise RuntimeError('D_TEST_TEMP_DIR is required')
        self.temp = tempfile.TemporaryDirectory(dir=root)
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_path_cannot_escape_or_follow_root_symlink(self):
        with self.assertRaises(ValueError):
            BUILDER.safe_path(self.root, '../outside')
        with self.assertRaises(ValueError):
            BUILDER.safe_path(self.root, '/tmp/outside')
        other = self.root / 'real'
        other.mkdir()
        link = self.root / 'link'
        link.symlink_to(other)
        with self.assertRaises(ValueError):
            BUILDER.safe_path(link, 'input')

    def test_copy_preserves_existing_destination(self):
        src = self.root / 'src'
        dst = self.root / 'dst'
        src.write_bytes(b'new')
        dst.write_bytes(b'previous')
        with self.assertRaises(ValueError):
            BUILDER.copy_file(src, dst)
        self.assertEqual(dst.read_bytes(), b'previous')

    def test_content_hash_and_git_blob_header_are_checked(self):
        src = self.root / 'model'
        src.write_bytes(b'abc')
        good = dict(size=3, algorithm='git-blob-sha1', checksum=hashlib.sha1(b'blob 3\0abc').hexdigest())
        BUILDER.verify_model_file(src, good)
        src.write_bytes(b'abd')
        with self.assertRaises(ValueError):
            BUILDER.verify_model_file(src, good)

    def test_symlink_file_refused(self):
        src = self.root / 'src'
        src.write_bytes(b'x')
        link = self.root / 'link'
        link.symlink_to(src)
        with self.assertRaises(ValueError):
            BUILDER.copy_file(link, self.root / 'dst')

    def test_relative_input_cannot_hide_overlapping_output(self):
        for name in ('engine', 'products', 'models'):
            (self.root / name).mkdir()
        args = SimpleNamespace(engine=Path('engine'), cli_products=Path('products'),
                               models_root=Path('models'), output=Path('engine/kit'),
                               source_sha='a' * 40, configuration='Release')
        previous = Path.cwd()
        try:
            os.chdir(self.root)
            with self.assertRaises(ValueError):
                BUILDER.build(args)
        finally:
            os.chdir(previous)
        self.assertFalse((self.root / 'engine/kit').exists())
        self.assertEqual(list((self.root / 'engine').iterdir()), [])


if __name__ == '__main__':
    unittest.main()
