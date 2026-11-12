"""Fixed static notice identity and copying; does not execute a WASI model."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("chat_packaging", Path(__file__).parents[1] / "package_runtime.py")
PACKAGING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGING)


class StaticNotices(unittest.TestCase):
    def test_fixed_notices_match_their_declared_bytes(self):
        root = Path(__file__).parents[1] / "Licenses"
        manifest = json.loads((root / "SOURCES.json").read_text())
        self.assertEqual(len(manifest["files"]), 11)
        for entry in manifest["files"]:
            self.assertEqual(PACKAGING.digest(root / entry["file"]), entry["sha256"])

    def test_changed_module_or_notice_cannot_publish(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "tools/chat-python/Licenses"
            source.mkdir(parents=True)
            module = root / "python.wasm"
            module.write_bytes(b"fixed module fixture")
            notice = source / "notice.txt"
            notice.write_bytes(b"exact upstream notice fixture")
            manifest = {"pythonModuleSHA256": PACKAGING.digest(module), "wasiLibcCommit": "fixture",
                        "llvmCommit": "fixture", "files": [{"file": notice.name, "sha256": PACKAGING.digest(notice)}]}
            (source / "SOURCES.json").write_text(json.dumps(manifest))
            with patch.object(PACKAGING, "ROOT", root):
                PACKAGING.copy_static_notices(root / "good", module)
                self.assertEqual((root / "good/notice.txt").read_bytes(), notice.read_bytes())
                notice.write_bytes(b"changed")
                with self.assertRaises(ValueError):
                    PACKAGING.copy_static_notices(root / "bad-notice", module)
                self.assertFalse((root / "bad-notice").exists())
                module.write_bytes(b"different fixed build")
                with self.assertRaises(ValueError):
                    PACKAGING.copy_static_notices(root / "bad-module", module)
                self.assertFalse((root / "bad-module").exists())


if __name__ == "__main__":
    unittest.main()
