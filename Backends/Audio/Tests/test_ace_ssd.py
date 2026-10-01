"""Small exact-precision controls against the pinned official MLX decoder.

Run with ACE_TEST_VENDOR set to the fixed offline vendor; no production weights.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Python"))
from d_ace_ssd import (CONVERTER, PreparedDecoder, decoder_groups, make_decoder,
                       mapped_tensor, prepare_decoder)


@unittest.skipUnless(os.environ.get("ACE_TEST_VENDOR"), "fixed official vendor required")
class ACEStreamTests(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, os.environ["ACE_TEST_VENDOR"])
        import mlx.core as mx
        from mlx.utils import tree_flatten
        from safetensors.numpy import save_file
        import numpy as np
        from acestep.models.mlx.dit_model import MLXDiTDecoder
        mx.set_default_device(mx.cpu)
        mx.random.seed(917)
        self.config = SimpleNamespace(hidden_size=16, intermediate_size=32,
            num_hidden_layers=2, num_attention_heads=2, num_key_value_heads=1,
            head_dim=8, rms_norm_eps=1e-6, attention_bias=False, in_channels=6,
            audio_acoustic_hidden_dim=2, patch_size=2, sliding_window=3,
            layer_types=["sliding_attention", "full_attention"], rope_theta=10000,
            max_position_embeddings=32, encoder_hidden_size=12)
        self.model = MLXDiTDecoder.from_config(self.config)
        mx.eval(self.model.parameters())
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.checkpoint = self.root / "checkpoint"
        self.checkpoint.mkdir()
        arrays = {}
        for key, value in tree_flatten(self.model.parameters()):
            array = np.array(value)
            if key.startswith("proj_in."):
                key = key.replace("proj_in.", "proj_in.1.")
                if key.endswith("weight"): array = array.swapaxes(1, 2)
            elif key.startswith("proj_out."):
                key = key.replace("proj_out.", "proj_out.1.")
                if key.endswith("weight"): array = array.transpose(2, 0, 1)
            arrays["decoder." + key] = np.ascontiguousarray(array)
        save_file(arrays, str(self.checkpoint / "weights.safetensors"))
        (self.checkpoint / "model.safetensors.index.json").write_text(json.dumps({"weight_map": {key: "weights.safetensors" for key in arrays}}))
        (self.checkpoint / "config.json").write_text(json.dumps(vars(self.config)))
        self.source = [{"path": p.name, "size": p.stat().st_size,
                        "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                       for p in sorted(self.checkpoint.iterdir())]
        self.path = prepare_decoder(self.checkpoint, self.root / "cache", self.source,
                                    lambda: False, lambda *_: None, verify_sources=lambda: None)

    def prepared(self, cancelled=lambda: False):
        return PreparedDecoder(self.path, {"converter": CONVERTER, "files": self.source}, cancelled)

    def test_official_decoder_cache_condition_change_and_rng_are_preserved(self):
        import mlx.core as mx
        import numpy as np
        from acestep.models.mlx.dit_model import MLXCrossAttentionCache
        calls = []
        stream = make_decoder(self.config, self.prepared(), lambda *p: calls.append(p), lambda: calls.append("release"))
        x = mx.random.normal((2, 7, 2)); context = mx.random.normal((2, 7, 4))
        condition = mx.random.normal((2, 3, 12)); mx.eval(x, context, condition)
        for changed in (False, True):
            old_cache, new_cache = MLXCrossAttentionCache(), MLXCrossAttentionCache()
            cond = condition + (1 if changed else 0)
            for step in range(3):
                args = (x, mx.array([.9 - step * .2] * 2), mx.array([0.] * 2), cond, context)
                expected, _ = self.model(*args, cache=old_cache)
                mx.eval(expected)
                saved = list(mx.random.state); mx.eval(saved)
                actual, _ = stream(*args, cache=new_cache)
                mx.eval(actual)
                self.assertTrue(np.array_equal(np.array(expected), np.array(actual)))
                for a, b in zip(saved, mx.random.state):
                    self.assertTrue(np.array_equal(np.array(a), np.array(b)))
                for i in range(2):
                    self.assertTrue(new_cache.is_updated(i))
                    for a, b in zip(old_cache.get(i), new_cache.get(i)):
                        self.assertTrue(np.array_equal(np.array(a), np.array(b)))
        expected, _ = self.model(*args, cache=None, use_cache=False)
        actual, _ = stream(*args, cache=None, use_cache=False)
        mx.eval(expected, actual)
        self.assertTrue(np.array_equal(np.array(expected), np.array(actual)))
        self.assertEqual(calls.count("release"), 1)
        self.assertEqual(len([p for p in calls if isinstance(p, tuple)]), 14)
        self.assertTrue(all(not hasattr(layer, "parameters") for layer in stream.layers))

    def test_preparation_reuses_verified_cache_and_rejects_corruption(self):
        stamp = (self.path / "manifest.json").stat().st_mtime_ns
        again = prepare_decoder(self.checkpoint, self.root / "cache", self.source, lambda: False, lambda *_: self.fail("unexpected conversion"), verify_sources=lambda: None)
        self.assertEqual(again, self.path)
        self.assertEqual(stamp, (again / "manifest.json").stat().st_mtime_ns)
        with (again / "layer-000.safetensors").open("r+b") as f:
            f.seek(-1, 2); f.write(b"X")
        with self.assertRaisesRegex(Exception, "changed"):
            self.prepared()

    def test_cancel_before_load_and_mutation_after_verification(self):
        cancel = [False]
        resources = self.prepared(lambda: cancel[0])
        cancel[0] = True
        with self.assertRaises(InterruptedError): resources.load("layer-000.safetensors")
        cancel[0] = False
        p = self.path / "layer-000.safetensors"
        p.touch()
        with self.assertRaisesRegex(Exception, "changed before load"):
            resources.load(p.name)

    def test_cancel_mid_preparation_publishes_nothing(self):
        cancel = [False]
        cache = self.root / "cancelled-cache"
        with self.assertRaises(InterruptedError):
            prepare_decoder(self.checkpoint, cache, self.source, lambda: cancel[0],
                            lambda *_: cancel.__setitem__(0, True), verify_sources=lambda: None)
        self.assertFalse(any(p.is_dir() for p in cache.iterdir()))

    def test_source_change_at_publish_does_not_leave_reusable_cache(self):
        calls = [0]
        cache = self.root / "source-mutation-cache"
        def verify():
            calls[0] += 1
            if calls[0] > 1: raise RuntimeError("source baseline changed")
        with self.assertRaisesRegex(RuntimeError, "baseline"):
            prepare_decoder(self.checkpoint, cache, self.source, lambda: False,
                            lambda *_: None, verify_sources=verify)
        self.assertFalse(any(p.is_dir() for p in cache.iterdir()))

    def test_no_missing_layers_or_precision_reduction(self):
        import numpy as np
        with self.assertRaises(Exception): decoder_groups({"decoder.layers.0.weight": "x"}, 2)
        with self.assertRaises(Exception): mapped_tensor("decoder.x", np.ones((2,), dtype=np.float16))
        cfg = copy.deepcopy(self.config); cfg.num_hidden_layers = 1
        with self.assertRaisesRegex(Exception, "complete"):
            make_decoder(cfg, self.prepared(), lambda *_: None, lambda: None)


if __name__ == "__main__":
    unittest.main()
