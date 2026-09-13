"""Preparation tests use synthetic CPU tensors, never downloaded model weights."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import torch
from safetensors.torch import load_file, save_file

SCRIPT = Path(__file__).resolve().parents[1] / "Python/d_video_prepare.py"
spec = importlib.util.spec_from_file_location("d_video_prepare", SCRIPT)
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class _UnsafePayload:
    def __init__(self, path):
        self.path = str(path)

    def __reduce__(self):
        return os.mkdir, (self.path,)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        root = Path(os.environ["D_TEST_TEMP_DIR"])
        self.temporary = tempfile.TemporaryDirectory(prefix="video-prepare-", dir=root)
        self.root = Path(self.temporary.name)
        self.source = self.root / "原始 权重 🎞️"
        self.source.mkdir()
        torch.set_num_threads(2)
        self.values = {"text": {"token_embedding.weight": torch.tensor([[1.125]], dtype=torch.bfloat16)},
                       "diffusion": {"blocks.0.self_attn.q.weight": torch.tensor([[1.234567]], dtype=torch.float32),
                                     "time_embedding.0.weight": torch.tensor([[1.234567]], dtype=torch.float32),
                                     "head.head.weight": torch.tensor([[1.234567]], dtype=torch.float32),
                                     "blocks.0.modulation": torch.tensor([[1.234567]], dtype=torch.float32),
                                     "blocks.0.self_attn.norm_q.weight": torch.tensor([[1.234567]], dtype=torch.float32)},
                       "vae": {"decoder.conv1.weight": torch.tensor([[[[[0.1234567]]]]], dtype=torch.float32)}}
        self.old_files = prepare.FILES
        files = {}
        for role, values in self.values.items():
            name, _, _, dtype = self.old_files[role]
            path = self.source / name
            if role == "diffusion":
                save_file(values, path)
            else:
                torch.save(values, path)
            files[role] = name, prepare.digest(path), path.stat().st_size, dtype
        prepare.FILES = files  # Explicit test fixture: production registry is unchanged on disk.
        self.originals = {p.name: prepare.digest(p) for p in self.source.iterdir()}

    def tearDown(self):
        prepare.FILES = self.old_files
        self.temporary.cleanup()

    def assertOriginalsUnchanged(self):
        self.assertEqual({p.name: prepare.digest(p) for p in self.source.iterdir()}, self.originals)

    def testExactShardsAndMixedPrecisionWithoutOriginalModification(self):
        destination = self.root / "转换结果 🎬"
        record = prepare.prepare(self.source, destination)
        self.assertTrue(record["complete"])
        self.assertEqual(len(record["tensors"]), 7)
        self.assertEqual(json.loads((destination / "D-VIDEO-PREPARED.json").read_text()), record)
        for item in record["tensors"]:
            value = load_file(destination / item["path"])[item["name"]]
            original = self.values[item["role"]][item["name"]]
            expected_dtype = torch.bfloat16 if item["role"] == "text" or item["name"] == "blocks.0.self_attn.q.weight" else torch.float32
            self.assertEqual(value.dtype, expected_dtype)
            self.assertTrue(torch.equal(value, original.to(expected_dtype)))
            self.assertEqual(prepare.digest(destination / item["path"]), item["sha256"])
        self.assertOriginalsUnchanged()

    def testExistingDestinationAndSymlinksDoNotOverwrite(self):
        destination = self.root / "existing"
        destination.mkdir()
        sentinel = destination / "work.txt"
        sentinel.write_text("keep")
        with self.assertRaises(FileExistsError):
            prepare.prepare(self.source, destination)
        link = self.root / "source-link"
        link.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(ValueError):
            prepare.prepare(link, self.root / "unused")
        self.assertFalse((self.root / "unused").exists())
        self.assertEqual(sentinel.read_text(), "keep")
        self.assertOriginalsUnchanged()

    def testCorruptSourceIsRejectedBeforeCreatingDestination(self):
        name, expected, size, dtype = prepare.FILES["vae"]
        prepare.FILES["vae"] = name, "0" * 64, size, dtype
        with self.assertRaisesRegex(ValueError, "mismatch"):
            prepare.prepare(self.source, self.root / "not-created")
        self.assertFalse((self.root / "not-created").exists())
        self.assertOriginalsUnchanged()

    def testNonfiniteWeightsNeverCreateCompleteManifest(self):
        name, _, _, dtype = prepare.FILES["text"]
        path = self.source / name
        torch.save({"token_embedding.weight": torch.tensor([[float("nan")]])}, path)
        prepare.FILES["text"] = name, prepare.digest(path), path.stat().st_size, dtype
        with self.assertRaisesRegex(ValueError, "Nonfinite"):
            prepare.prepare(self.source, self.root / "incomplete")
        self.assertFalse((self.root / "incomplete/D-VIDEO-PREPARED.json").exists())

    def testFiniteFloat32OverflowToBFloat16IsRejected(self):
        name, _, _, dtype = prepare.FILES["diffusion"]
        path = self.source / name
        save_file({"blocks.0.self_attn.q.weight": torch.tensor([[torch.finfo(torch.float32).max]])}, path)
        prepare.FILES["diffusion"] = name, prepare.digest(path), path.stat().st_size, dtype
        with self.assertRaisesRegex(ValueError, "[Nn]onfinite"):
            prepare.prepare(self.source, self.root / "overflow")
        self.assertFalse((self.root / "overflow/D-VIDEO-PREPARED.json").exists())

    def testManifestSyncFailureDoesNotLeaveSuccessMarker(self):
        destination = self.root / "D-VIDEO-PREPARED.json"
        with mock.patch.object(prepare.os, "fsync", side_effect=OSError("controlled fsync failure")):
            with self.assertRaises(OSError):
                prepare.exclusive_json(destination, {"complete": True})
        self.assertFalse(destination.exists())

    def testRestrictedCheckpointLoadingDoesNotExecutePayload(self):
        name, _, _, dtype = prepare.FILES["text"]
        path = self.source / name
        sentinel = self.root / "must-not-be-created"
        torch.save({"payload": _UnsafePayload(sentinel)}, path)
        prepare.FILES["text"] = name, prepare.digest(path), path.stat().st_size, dtype
        with self.assertRaises(prepare.pickle.UnpicklingError):
            prepare.prepare(self.source, self.root / "rejected-checkpoint")
        self.assertFalse(sentinel.exists())
        self.assertFalse((self.root / "rejected-checkpoint/D-VIDEO-PREPARED.json").exists())

    def testDestinationInsideOriginalsAndRelativePathsAreRejected(self):
        for src, dest in [(self.source, self.source / "nested"),
                          (self.source, self.root.parent), (Path("relative"), self.root / "new")]:
            with self.assertRaises((ValueError, FileExistsError)):
                prepare.prepare(src, dest)
        self.assertOriginalsUnchanged()


if __name__ == "__main__":
    unittest.main()
