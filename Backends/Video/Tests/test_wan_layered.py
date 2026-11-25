"""Small mixed-dtype resident/layered parity; not real-model quality evidence."""
import gc
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import weakref

ENABLED = os.environ.get("D_WAN_LAYERED_NUMERICS") == "1"
if ENABLED:
    import mlx.core as mx
    from mlx.utils import tree_flatten
    BASE = Path(__file__).resolve().parents[1]
    sys.path[:0] = [str(BASE / "Python"), str(BASE / "Vendor")]
    from d_video_model import PreparedModel
    from d_video_prepare import identity
    from wan21.text_encoder import T5Encoder, T5SelfAttentionBlock
    from wan21.wan_2 import WanModel
    from wan21.config import WanModelConfig
    from wan21.transformer import WanAttentionBlock


@unittest.skipUnless(ENABLED, "explicit MLX numerical environment required")
class WanLayeredTests(unittest.TestCase):
    def prepare(self, root, role, model):
        owner = object.__new__(PreparedModel)  # Tiny fixture; not a 1261-tensor installation claim.
        owner.root = root
        owner.rows = {role: []}
        owner._verified = {}
        for key, array in tree_flatten(model.parameters()):
            if key == "freqs":
                continue
            name = key
            if role == "text":
                name = name.replace(".ffn.gate_proj.", ".ffn.gate.0.")
            else:
                name = name.replace("patch_embedding_proj.", "patch_embedding.")
                for kind in ("text", "time"):
                    name = name.replace(kind + "_embedding_0.", kind + "_embedding.0.")
                    name = name.replace(kind + "_embedding_1.", kind + "_embedding.2.")
                name = name.replace("time_projection.", "time_projection.1.")
                name = name.replace(".ffn.fc1.", ".ffn.0.").replace(".ffn.fc2.", ".ffn.2.")
            full = role == "diffusion" and (name.startswith(("time_embedding.", "time_projection.", "head.")) or name.endswith(".modulation") or any(p.startswith("norm") for p in name.split(".")))
            value = array.astype(mx.float32 if full else mx.bfloat16)
            mx.eval(value)
            model.load_weights([(key, value)], strict=False)
            path = root / f"{len(owner.rows[role]):04d}.safetensors"
            mx.save_safetensors(str(path), {name: value})
            owner.rows[role].append(dict(role=role, name=name, path=path.name, size=path.stat().st_size,
                shape=list(value.shape), dtype="F32" if full else "BF16", sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        owner.manifest_path = root / "D-VIDEO-PREPARED.json"
        owner.manifest_path.write_text(json.dumps(owner.rows))
        owner.manifest_identity = identity(owner.manifest_path)
        return owner

    def test_text_and_diffusion_keep_all_blocks_masks_and_mixed_dtypes(self):
        with tempfile.TemporaryDirectory(dir=os.environ["TMPDIR"]) as folder:
            root = Path(folder)
            for role in ("text", "diffusion"):
                part = root / role; part.mkdir()
                if role == "text":
                    factory = lambda: T5Encoder(64, 32, 32, 64, 4, 3, 8, False)
                    block = lambda: T5SelfAttentionBlock(32, 32, 64, 4, 8, False)
                    tokens = mx.array([[0, 0, 3, 12, 1]])
                    mask = mx.array([[0, 0, 1, 1, 1]])
                    run = lambda model: model(tokens, mask=mask)
                else:
                    config = WanModelConfig(dim=32, ffn_dim=64, num_heads=4, num_layers=3,
                        freq_dim=16, text_dim=32, text_len=5)
                    factory = lambda: WanModel(config)
                    block = lambda: WanAttentionBlock(dim=32, ffn_dim=64, num_heads=4,
                        window_size=config.window_size, qk_norm=True, cross_attn_norm=True, eps=config.eps)
                    latent = mx.arange(16 * 2 * 4 * 4).reshape(16, 2, 4, 4).astype(mx.float32) / 1000
                    context = [mx.ones((3, 32), dtype=mx.bfloat16)]
                    run = lambda model: model([latent], mx.array([500.0]), context, 8)[0]
                resident = factory()
                owner = self.prepare(part, role, resident)
                expected = run(resident); mx.eval(expected)
                streamed = owner.layered(role, factory(), block)
                rng = [mx.array(v) for v in mx.random.state]; mx.eval(rng)
                actual = run(streamed); mx.eval(actual)
                self.assertEqual(actual.dtype, expected.dtype)
                self.assertTrue(mx.array_equal(actual, expected).item(), role)
                self.assertTrue(mx.all(mx.isfinite(actual)).item())
                for before, after in zip(rng, mx.random.state):
                    self.assertTrue(mx.array_equal(before, after).item())
                self.assertFalse(any(k.startswith("blocks.") for k, _ in tree_flatten(streamed.parameters())))
                owner.verify_loaded()
                # Same-length replacement with restored mtime is not accepted.
                path = part / owner.rows[role][-1]["path"]; saved = path.stat()
                data = bytearray(path.read_bytes()); data[-1] ^= 1; path.write_bytes(data)
                os.utime(path, ns=(saved.st_atime_ns, saved.st_mtime_ns))
                with self.assertRaisesRegex(ValueError, "changed"):
                    run(streamed)
                del resident, streamed, actual, expected
                gc.collect(); mx.clear_cache()

    def test_cancel_boundary_releases_block(self):
        with tempfile.TemporaryDirectory(dir=os.environ["TMPDIR"]) as folder:
            factory = lambda: T5Encoder(64, 32, 32, 64, 4, 3, 8, False)
            owner = self.prepare(Path(folder), "text", factory())
            # Exercise cancellation after a block's values have materialized,
            # not only before its entry. The traceback is not retained.
            armed = [False]
            refs = []
            def block():
                value = T5SelfAttentionBlock(32, 32, 64, 4, 8, False)
                refs.append(weakref.ref(value))
                return value
            def checkpoint(index, count):
                if armed[0] and index == 1 and count == 3:
                    raise InterruptedError("fixture cancellation after first block eval")
            streamed = owner.layered("text", factory(), block, checkpoint)
            armed[0] = True
            with self.assertRaises(InterruptedError):
                streamed(mx.array([[1, 2]]))
            gc.collect(); mx.clear_cache()
            self.assertEqual(len(refs), 1)
            self.assertIsNone(refs[0]())
            self.assertFalse(any(k.startswith("blocks.") for k, _ in tree_flatten(streamed.parameters())))



if __name__ == "__main__":
    unittest.main()
