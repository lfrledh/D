"""Small fixed source fixtures for the package-only ACE loader patch."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Packaging"))
import prepare_ace_engine as packaging


class ACEPackagingPatchTests(unittest.TestCase):
    def test_four_official_calls_are_patched_only_in_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = root / "original"
            staged = root / "staged"
            first, second = (path for path, _ in packaging.SOURCE_PATCHES)
            sources = {
                first: b"AutoModel.from_pretrained(\n                    dtype=self.dtype,\n)\n",
                second: (b"AutoencoderOobleck.from_pretrained(vae_checkpoint_path)\n"
                         b"AutoTokenizer.from_pretrained(text_encoder_path)\n"
                         b"AutoModel.from_pretrained(text_encoder_path)\n"),
            }
            manifest = {"sourceFiles": []}
            bases = []
            for relative, raw in sources.items():
                for directory in (original, staged):
                    path = directory / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(raw)
                digest = hashlib.sha256(raw).hexdigest()
                bases.append((relative, digest))
                manifest["sourceFiles"].append({"path": relative, "size": len(raw), "sha256": digest})
            with (mock.patch.object(packaging, "SOURCE_PATCHES", tuple(bases)),
                  mock.patch.object(packaging, "validate_manifest")):
                deployed = packaging.patch_source_copy(staged, manifest)
            for relative, raw in sources.items():
                self.assertEqual((original / relative).read_bytes(), raw)
                self.assertEqual((staged / relative).read_text().count("local_files_only=True"),
                                 1 if relative == first else 3)
                item = next(item for item in deployed["sourceFiles"] if item["path"] == relative)
                self.assertEqual(item["sha256"], hashlib.sha256((staged / relative).read_bytes()).hexdigest())
            self.assertEqual(len(deployed["sourcePatches"]), 2)
            self.assertNotIn("sourcePatches", manifest)

    def test_fragment_drift_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first, second = (path for path, _ in packaging.SOURCE_PATCHES)
            sources = {first: b"dtype=self.dtype,\n", second: b"changed loader"}
            entries = []
            for relative, raw in sources.items():
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(raw)
                entries.append({"path": relative, "size": len(raw),
                                "sha256": hashlib.sha256(raw).hexdigest()})
            bases = tuple((item["path"], item["sha256"]) for item in entries)
            with (mock.patch.object(packaging, "SOURCE_PATCHES", bases),
                  mock.patch.object(packaging, "validate_manifest")):
                with self.assertRaises(packaging.core.PackagingError):
                    packaging.patch_source_copy(root, {"sourceFiles": entries})


if __name__ == "__main__":
    unittest.main()
