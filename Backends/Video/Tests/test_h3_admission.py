"""Simulated tiny resources; production inventory is never caller supplied."""
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / "Adapters"))
import h3_admission as m
from resource_inventory import ResourceError, verify_inventory


def tiny_tensor(dtype="BF16"):
    size = 4 if dtype == "F32" else 2
    header = json.dumps({"weight": {"dtype": dtype, "shape": [1],
                                    "data_offsets": [0, size]}}).encode()
    return struct.pack("<Q", len(header)) + header + b"\0" * size


class H3AdmissionTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(dir=os.environ["TMPDIR"])
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / "H3 model 原件"
        (self.root / "FL2VA/transformer").mkdir(parents=True)
        self.resource = self.root / "FL2VA/transformer/model.safetensors"
        self.resource.write_bytes(tiny_tensor())
        self.config = self.root / "FL2VA/transformer/config.json"
        self.config.write_bytes(b'{}')
        self.inventory = {
            "schema_version": 1, "profile": m.PROFILE,
            "repository": m.REPOSITORY, "revision": m.REVISION,
            "files": [
                self.row("FL2VA/transformer/model.safetensors", "floating_only"),
                self.row("FL2VA/transformer/config.json", "not_tensor"),
            ],
        }
        lookup = patch.object(m, "_inventory", return_value=self.inventory)
        lookup.start()
        self.addCleanup(lookup.stop)

    def row(self, name, policy):
        data = (self.root / name).read_bytes()
        return {"name": name, "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(), "tensor_policy": policy}

    def test_pinned_code_owned_inventory_and_ordinary_downloader_files(self):
        for name in (".download.lock", ".provenance.json"):
            (self.root / name).write_bytes(b"ordinary downloader marker")
        before = self.resource.read_bytes()
        admission = m.admit_h3_fl2va(self.root)
        self.assertEqual(admission["layers"], 50)
        self.assertFalse(admission["inference_verified"])
        self.assertEqual(admission["verification"]["verified_files"][0]["tensor_header"]["dtypes"], {"BF16": 1})
        self.assertEqual(self.resource.read_bytes(), before)

    def test_missing_corrupt_extra_nested_and_symlinks_are_rejected(self):
        cases = ("missing", "corrupt", "extra-root", "extra-nested", "symlink-file", "symlink-directory")
        for case in cases:
            with self.subTest(case=case):
                with tempfile.TemporaryDirectory(dir=os.environ["TMPDIR"]) as temp:
                    root = Path(temp) / "model"
                    (root / "FL2VA/transformer").mkdir(parents=True)
                    (root / "FL2VA/transformer/model.safetensors").write_bytes(self.resource.read_bytes())
                    (root / "FL2VA/transformer/config.json").write_bytes(self.config.read_bytes())
                    tensor = root / "FL2VA/transformer/model.safetensors"
                    if case == "missing": tensor.unlink()
                    if case == "corrupt": tensor.write_bytes(tiny_tensor("F32"))
                    if case == "extra-root": (root / "other.safetensors").write_bytes(b"x")
                    if case == "extra-nested": (root / "FL2VA/transformer/alternate.json").write_bytes(b"x")
                    if case == "symlink-file":
                        (root / ".provenance.json").symlink_to(self.config)
                    if case == "symlink-directory":
                        (root / "Ref2VA").symlink_to(root / "FL2VA", target_is_directory=True)
                    with self.assertRaises((ResourceError, OSError)):
                        m.admit_h3_fl2va(root)
        alias = self.root.parent / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ResourceError): m.admit_h3_fl2va(alias)
        outer = self.root.parent / "alias-parent"
        outer.symlink_to(self.root.parent, target_is_directory=True)
        with self.assertRaises(ResourceError): m.admit_h3_fl2va(outer / self.root.name)

    def test_cancel_during_inventory_hash_and_reject_nonfloat_header(self):
        active = False
        calls = 0

        def cancelled():
            nonlocal calls
            if active:
                calls += 1
                return calls >= 3
            return False

        def verifying(root, inventory, *, cancelled):
            nonlocal active
            active = True
            return verify_inventory(root, inventory, cancelled=cancelled)

        with patch.object(m, "verify_inventory", side_effect=verifying):
            with self.assertRaises(InterruptedError): m.admit_h3_fl2va(self.root, cancelled=cancelled)
        self.assertGreaterEqual(calls, 3)
        self.resource.write_bytes(tiny_tensor("U16"))
        self.inventory["files"][0] = self.row("FL2VA/transformer/model.safetensors", "floating_only")
        with self.assertRaises(ResourceError): m.admit_h3_fl2va(self.root)

    def test_pinned_production_inventory_identity_and_no_quantized_entries(self):
        inventory = json.loads((Path(m.__file__).parent / "Resources/h3-fl2va-bf16.json").read_bytes())
        self.assertEqual((inventory["repository"], inventory["revision"]), (m.REPOSITORY, m.REVISION))
        self.assertEqual(len(inventory["files"]), 38)
        self.assertTrue(all(row["tensor_policy"] != "quantized_explicit" for row in inventory["files"]))
        self.assertIn("FL2VA/video_vae/config.json", {row["name"] for row in inventory["files"]})


if __name__ == "__main__":
    unittest.main()
