import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest

SCRIPT = Path(__file__).parents[1] / "Adapters/resource_inventory.py"
spec = importlib.util.spec_from_file_location("video_resource_inventory", SCRIPT)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ResourceInventoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def tensor(self, name="weight", dtype="BF16", shape=None, offsets=None, payload=b"\x00\x00"):
        header = json.dumps({name: {"dtype": dtype, "shape": shape if shape is not None else [1],
                                    "data_offsets": offsets if offsets is not None else [0, len(payload)]}}).encode()
        return struct.pack("<Q", len(header)) + header + payload

    def inventory(self, data, name="weights.safetensors", policy="floating_only"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return {"schema_version": 1, "profile": "test-explicit-full", "files": [
            {"name": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "tensor_policy": policy}]}

    def test_identity_and_header_without_modification(self):
        data = self.tensor()
        inventory = self.inventory(data, "模型 空格/weights.safetensors")
        path = self.root / inventory["files"][0]["name"]
        before = path.stat()
        result = m.verify_inventory(self.root, inventory)
        after = path.stat()
        self.assertEqual(result["verified_files"][0]["tensor_header"], {"tensors": 1, "dtypes": {"BF16": 1}})
        self.assertFalse(result["inference_verified"])
        self.assertEqual((before.st_mtime_ns, before.st_size), (after.st_mtime_ns, after.st_size))
        self.assertEqual(path.read_bytes(), data)

    def test_changed_content_or_size_is_rejected(self):
        inventory = self.inventory(self.tensor())
        path = self.root / "weights.safetensors"
        data = path.read_bytes()
        for changed in (data[:-1], data[:-1] + b"x"):
            path.write_bytes(changed)
            with self.assertRaises(m.ResourceError):
                m.verify_inventory(self.root, inventory)

    def test_quantization_is_explicit_and_never_full(self):
        for data in (self.tensor(dtype="U32", payload=b"\0" * 4), self.tensor(name="proj.scales")):
            inventory = self.inventory(data)
            with self.assertRaises(m.ResourceError):
                m.verify_inventory(self.root, inventory)
            inventory["files"][0]["tensor_policy"] = "quantized_explicit"
            self.assertEqual(len(m.verify_inventory(self.root, inventory)["verified_files"]), 1)

    def test_tensor_range_and_type_corruption_is_rejected(self):
        for data in (b"abc", struct.pack("<Q", 2**63), self.tensor(shape=[True]),
                     self.tensor(offsets=[1, 3]), self.tensor(shape=[2]), self.tensor(dtype="NONSENSE")):
            with self.subTest(data=data[:16]):
                with self.assertRaises((m.ResourceError, ValueError)):
                    m.verify_inventory(self.root, self.inventory(data))

    def test_duplicate_json_and_unaccounted_payload_are_rejected(self):
        header = b'{"x":{},"x":{}}'
        cases = [struct.pack("<Q", len(header)) + header, self.tensor() + b"extra"]
        for data in cases:
            with self.assertRaises(m.ResourceError):
                m.verify_inventory(self.root, self.inventory(data))

    def test_paths_cannot_escape_or_follow_links(self):
        data = self.tensor()
        inventory = self.inventory(data)
        entry = inventory["files"][0]
        for name in ("../weights.safetensors", "/weights.safetensors", "a//b", "./b", "a\\b"):
            with self.subTest(name=name), self.assertRaises(m.ResourceError):
                m.verify_inventory(self.root, {**inventory, "files": [{**entry, "name": name}]})
        (self.root / "alias").symlink_to(self.root, target_is_directory=True)
        (self.root / "link.safetensors").symlink_to(self.root / "weights.safetensors")
        for name in ("alias/weights.safetensors", "link.safetensors"):
            with self.assertRaises((m.ResourceError, OSError)):
                m.verify_inventory(self.root, {**inventory, "files": [{**entry, "name": name}]})

    def test_missing_empty_or_malformed_inventory_is_not_pass(self):
        inventory = self.inventory(self.tensor())
        for patch in ({"schema_version": True}, {"schema_version": 2}, {"files": []}, {"profile": ""}):
            with self.assertRaises(m.ResourceError):
                m.verify_inventory(self.root, {**inventory, **patch})
        entry = inventory["files"][0]
        for patch in ({"size": True}, {"sha256": "unknown"}, {"tensor_policy": "auto"}, {"name": "missing"}):
            with self.assertRaises((m.ResourceError, OSError)):
                m.verify_inventory(self.root, {**inventory, "files": [{**entry, **patch}]})
        with self.assertRaises(m.ResourceError):
            m.verify_inventory(self.root, {**inventory, "files": [entry, entry]})


if __name__ == "__main__":
    unittest.main()
