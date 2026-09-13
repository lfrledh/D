"""CPU-only request/file contract checks; no model import or inference."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(os.environ["D_VIDEO_PYTHON"])
sys.path.insert(0, str(ROOT))
from d_video_run import validate_request, tokenize_conditions, clean_text, validate_chunk_shape, PROFILE, REVISION
from d_video_model import PreparedModel, mapped_name, read_json, read_snapshot


def request():
    return {"schemaVersion": 1, "runID": "cfe9876a-3e85-4de9-95fa-fa7b8f0e0bc6",
            "profile": PROFILE, "revision": REVISION, "prompt": "雨后的街道 🎞️ é", "negativePrompt": "",
            "width": 832, "height": 480, "frameCount": 17, "fpsNumerator": 16, "fpsDenominator": 1,
            "steps": 50, "guidanceScale": 6, "shift": 8, "seed": 42, "memoryLimitBytes": 14 * 1024**3}


class RunnerContract(unittest.TestCase):
    def test_explicit_values_and_scaling(self):
        r = request(); r.update(width=1920, height=1088, frameCount=81, fpsNumerator=30000,
                                fpsDenominator=1001, seed=2**32-1, memoryLimitBytes=96 * 1024**3)
        self.assertEqual(validate_request(r.copy()), r)

    def test_strict_schema_types_and_model(self):
        for key, bad in [("schemaVersion", True), ("width", True), ("frameCount", 17.0),
                         ("guidanceScale", True), ("shift", float("nan")), ("seed", 2**32),
                         ("seed", -1), ("profile", "wan22"), ("revision", "latest"), ("runID", "../x")]:
            with self.subTest(key=key, bad=bad):
                r = request(); r[key] = bad
                with self.assertRaises((ValueError, TypeError)): validate_request(r)
        r = request(); r["download"] = True
        with self.assertRaises(ValueError): validate_request(r)

    def test_no_implicit_geometry_or_length_adjustment(self):
        for field, value in [("width", 831), ("height", 481), ("frameCount", 18),
                             ("frameCount", 0), ("width", 16400), ("fpsDenominator", 2**31),
                             ("steps", 0), ("memoryLimitBytes", 0)]:
            r = request(); r[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError): validate_request(r)

    def test_cleaning_is_explicit_and_unicode_preserved(self):
        self.assertEqual(clean_text("  白猫 &amp;amp; 雨\n  🎞️ "), "白猫 & 雨 🎞️")

    def test_json_and_paths_are_data_only(self):
        with tempfile.TemporaryDirectory(dir=os.environ["D_TEST_TEMP_DIR"]) as temporary:
            root = Path(temporary); path = root / "记录 🎞️.json"
            for value in ('{"a":1,"a":2}', '{"x":NaN}'):
                path.write_text(value)
                with self.assertRaises(ValueError): read_json(path)
            path.write_text(json.dumps(request(), ensure_ascii=False)); saved = path.read_bytes()
            self.assertEqual(read_json(path), request()); self.assertEqual(path.read_bytes(), saved)
            link = root / "link"; link.symlink_to(path)
            with self.assertRaises(ValueError): read_json(link)
            with self.assertRaises(ValueError): read_json(path, maximum=1)

    def test_incomplete_and_boolean_preparation_rejected(self):
        with tempfile.TemporaryDirectory(dir=os.environ["D_TEST_TEMP_DIR"]) as temporary:
            root = Path(temporary); path = root / "D-VIDEO-PREPARED.json"
            for version, complete in [(True, True), (1, False), (1, True)]:
                path.write_text(json.dumps({"schemaVersion": version, "complete": complete,
                    "revision": REVISION, "repository": "Wan-AI/Wan2.1-T2V-1.3B",
                    "preparation": "original-names-tensor-shards-v1", "tensors": []}))
                with self.assertRaises(ValueError): PreparedModel(root)

    def test_mapping_preserves_original_semantics(self):
        self.assertEqual(mapped_name("diffusion", "blocks.29.ffn.2.weight"), "blocks.29.ffn.fc2.weight")
        self.assertEqual(mapped_name("diffusion", "time_embedding.2.bias"), "time_embedding_1.bias")
        self.assertEqual(mapped_name("diffusion", "blocks.0.self_attn.norm_q.weight"), "blocks.0.self_attn.norm_q.weight")
        self.assertEqual(mapped_name("text", "blocks.23.ffn.gate.0.weight"), "blocks.23.ffn.gate_proj.weight")

    def test_snapshot_digest_is_of_parsed_bytes(self):
        import hashlib
        with tempfile.TemporaryDirectory(dir=os.environ["D_TEST_TEMP_DIR"]) as temporary:
            path = Path(temporary) / "request.json"; data = json.dumps(request()).encode()
            path.write_bytes(data); value, sha, snapshot = read_snapshot(path)
            path.write_text('{"replaced":true}')
            self.assertEqual(value, request()); self.assertEqual(sha, hashlib.sha256(data).hexdigest())
            self.assertNotEqual(sha, hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual(snapshot[2], len(data))

    def test_decoded_dimensions_not_only_area(self):
        r = request()
        validate_chunk_shape((1, 3, 1, 480, 832), r, 0)
        validate_chunk_shape((1, 3, 4, 480, 832), r, 13)
        for shape, delivered in [((1, 3, 1, 832, 480), 0), ((3, 1, 480, 832), 0),
                                 ((2, 3, 1, 480, 832), 0), ((1, 3, 0, 480, 832), 0),
                                 ((1, 3, 4, 480, 832), 14)]:
            with self.subTest(shape=shape), self.assertRaises(ValueError): validate_chunk_shape(shape, r, delivered)

    def test_precision_label_cannot_lie(self):
        with tempfile.TemporaryDirectory(dir=os.environ["D_TEST_TEMP_DIR"]) as temporary:
            root = Path(temporary); path = root / "D-VIDEO-PREPARED.json"
            m = {"schemaVersion": 1, "complete": True, "revision": REVISION,
                 "repository": "Wan-AI/Wan2.1-T2V-1.3B", "preparation": "original-names-tensor-shards-v1"}
            for value in (None, "F32", {"text": "Q8", "vae": "F32"}):
                m["precision"] = value; path.write_text(json.dumps(m))
                with self.assertRaisesRegex(ValueError, "precision description"): PreparedModel(root)

    def test_local_tokenizer_boundaries(self):
        directory = Path(os.environ["D_VIDEO_TOKENIZER"])
        conditions = tokenize_conditions(directory, request())
        self.assertEqual(len(conditions), 2)
        self.assertTrue(all(c[0]["input_ids"].shape == (1, 512) and 0 < c[1] <= 512 for c in conditions))
        too_long = request(); too_long["prompt"] = "cat " * 1024
        with self.assertRaisesRegex(ValueError, "no truncation"): tokenize_conditions(directory, too_long)
        too_long = request(); too_long["negativePrompt"] = "cat " * 1024
        with self.assertRaisesRegex(ValueError, "no truncation"): tokenize_conditions(directory, too_long)


if __name__ == "__main__":
    unittest.main(verbosity=2)
