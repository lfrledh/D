"""Opt-in exact SA3 small stored-weight stage comparisons, not full generation."""
import gc
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

BASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BASE / 'Python'))
import d_audio_sa3 as adapter

@unittest.skipUnless(os.environ.get('D_SA3_LAYERED_NUMERICS') == '1', 'explicit real-model MLX environment')
class SA3LayeredTests(unittest.TestCase):
    def test_replacement_with_restored_mtime_is_rejected(self):
        import numpy as np
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as folder:
            path = Path(folder) / 'weights.npz'
            np.savez(path, weight=np.ones((8,), dtype=np.float16))
            owner = adapter._SA3LayerWeights(path, lambda: False)
            before = path.stat()
            np.savez(path, weight=np.zeros((8,), dtype=np.float16))
            self.assertEqual(before.st_size, path.stat().st_size)
            os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
            with self.assertRaisesRegex(adapter.ContractError, 'changed'):
                owner.read(lambda _: True)

    def test_cancel_between_conditioning_and_block_and_after_block_eval(self):
        import mlx.core as mx
        root = Path(os.environ['D_SA3_MODEL']) / 'MLX'
        vendor = BASE.parents[1] / 'Vendor/stable-audio3-mlx'
        loader = adapter._VerifiedVendorLoader(vendor, adapter.verify_vendor(vendor)); loader.start()
        try:
            dit = loader.import_module('models.defs.dit_mlx')
            for after_block in (False, True):
                stopped = False
                model = adapter._layered_dit(root/'dit_sm-music_f16.npz', dit, 16, lambda: stopped)
                block = model.transformer.layers[0]
                condition = block.to_local_embed(mx.ones((2,16,257), dtype=mx.float16)/100)
                self.assertIsNotNone(block._loaded)
                original = dit.TransformerBlock.__call__
                def evaluated(instance, *args):
                    nonlocal stopped
                    value = original(instance, *args); mx.eval(value)
                    stopped = True
                    return value
                if not after_block:
                    stopped = True
                with mock.patch.object(dit.TransformerBlock, '__call__', evaluated):
                    with self.assertRaises(adapter.CancelledError):
                        block(mx.ones((2,16,1024), dtype=mx.float16)/100,
                              mx.ones((2,257,1024), dtype=mx.float16)/100,
                              mx.ones((2,6144), dtype=mx.float16)/100,
                              condition)
                self.assertIsNone(block._loaded)
                del model, block, condition
                gc.collect(); mx.clear_cache()
        finally:
            loader.close(); gc.collect(); mx.clear_cache()

    def test_original_text_and_dit_stages(self):
        import mlx.core as mx
        import numpy as np
        root = Path(os.environ['D_SA3_MODEL']) / 'MLX'
        vendor = BASE.parents[1] / 'Vendor/stable-audio3-mlx'
        checked = adapter.verify_vendor(vendor)
        loader = adapter._VerifiedVendorLoader(vendor, checked); loader.start()
        try:
            t5 = loader.import_module('models.defs.t5gemma_mlx')
            dit = loader.import_module('models.defs.dit_mlx')
            def text(layered):
                model = (adapter._layered_text(root/'t5gemma_f16.npz', t5, lambda: False) if layered
                         else t5.T5Gemma.from_npz(str(root/'t5gemma_f16.npz')))
                rng = list(mx.random.state); mx.eval(rng)
                result, mask = model.encode(['Soft piano by the lake.', ''], max_len=256)
                mx.eval(result, mask)
                for before, after in zip(rng, mx.random.state):
                    self.assertTrue(mx.array_equal(before, after).item())
                return str(result.dtype), np.array(result), np.array(mask)
            normal = text(False); gc.collect(); mx.clear_cache()
            layered = text(True); gc.collect(); mx.clear_cache()
            self.assertEqual(normal[0], layered[0]); np.testing.assert_array_equal(normal[1], layered[1])
            np.testing.assert_array_equal(normal[2], layered[2])
            def diffusion(layered):
                model = (adapter._layered_dit(root/'dit_sm-music_f16.npz', dit, 16, lambda: False) if layered
                         else dit.load_dit(str(root/'dit_sm-music_f16.npz'), T_lat=16, dtype=mx.float16))
                x = mx.arange(2*256*16).reshape(2,256,16).astype(mx.float16)/10000
                cross = mx.ones((2,257,768), dtype=mx.float16)/10
                local = mx.ones((2,16,257), dtype=mx.float16)/100
                rng = list(mx.random.state); mx.eval(rng)
                result = model(x, mx.array([0.5,0.5], dtype=mx.float16), cross,
                    mx.ones((2,768),dtype=mx.float16)/10, local_add_cond=local)
                mx.eval(result)
                for before, after in zip(rng, mx.random.state):
                    self.assertTrue(mx.array_equal(before, after).item())
                return str(result.dtype), np.array(result)
            normal = diffusion(False); gc.collect(); mx.clear_cache()
            layered = diffusion(True); gc.collect(); mx.clear_cache()
            self.assertEqual(normal[0], layered[0]); np.testing.assert_array_equal(normal[1], layered[1])
            self.assertTrue(np.isfinite(layered[1]).all())
        finally:
            loader.close(); gc.collect(); mx.clear_cache()

if __name__ == '__main__': unittest.main()
