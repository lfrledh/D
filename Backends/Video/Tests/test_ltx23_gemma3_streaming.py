"""MLX numerical/lifecycle tests; run explicitly in the fixed LTX environment.

Small original-dtype and packed-Q4 tensors test every hidden state, not real
model quality. The separate full-width stage run uses admitted model files.
"""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ENABLED = os.environ.get("D_LTX_GEMMA3_NUMERICS") == "1"
if ENABLED:
    import mlx.core as mx
    import mlx.nn as nn
    from mlx.utils import tree_flatten
    from mlx_lm.models.gemma3 import Model, ModelArgs
    from ltx_core_mlx.text_encoders.gemma.encoders.base_encoder import GemmaLanguageModel
    
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Adapters"))
    from d_ltx_gemma3 import StreamingGemma3LanguageModel


@unittest.skipUnless(ENABLED, "explicit fixed MLX environment required")

class Gemma3StreamingTests(unittest.TestCase):
    def compare(self, quantized):
        with tempfile.TemporaryDirectory(dir=os.environ["TMPDIR"]) as directory:
            root = Path(directory)
            config = {"model_type": "gemma3", "vocab_size": 64, "text_config": {
                "model_type": "gemma3_text", "hidden_size": 64, "num_hidden_layers": 48,
                "intermediate_size": 128, "num_attention_heads": 2, "num_key_value_heads": 1,
                "head_dim": 32, "query_pre_attn_scalar": 32, "sliding_window": 8,
                "sliding_window_pattern": 6}}
            mx.random.seed(91)
            resident = Model(ModelArgs.from_dict(config))
            resident.set_dtype(mx.bfloat16)
            if quantized:
                config["quantization"] = {"bits": 4, "group_size": 64}
                nn.quantize(resident, bits=4, group_size=64)
            weights = dict(tree_flatten(resident.parameters()))
            mx.eval(weights)
            names = sorted(weights)
            index = {}
            for number in range(2):
                filename = f"model-{number}.safetensors"
                selected = {name: weights[name] for name in names[number::2]}
                mx.save_safetensors(str(root / filename), selected)
                index.update({name: filename for name in selected})
            (root / "config.json").write_text(json.dumps(config))
            (root / "model.safetensors.index.json").write_text(json.dumps({"weight_map": index}))
            tokens = mx.array([[0, 0, 3, 7, 11, 5, 2, 13, 8, 6, 9, 4, 2, 10, 12, 1]])
            mask = mx.array([[0, 0] + [1] * 14])
            encoder = GemmaLanguageModel()
            encoder._model = resident
            expected = encoder.get_all_hidden_states(tokens, mask)
            mx.eval(expected)
            streaming = StreamingGemma3LanguageModel()
            with patch("d_ltx_gemma3.load_tokenizer", return_value=object()):
                streaming.load(root)
            random_before = [mx.array(value) for value in mx.random.state]
            actual = streaming.get_all_hidden_states(tokens, mask)
            self.assertEqual(len(actual), 49)
            for number, (a, b) in enumerate(zip(expected, actual)):
                self.assertEqual(a.dtype, b.dtype, number)
                self.assertTrue(mx.array_equal(a, b).item(), (quantized, number))
            for a, b in zip(random_before, mx.random.state):
                self.assertTrue(mx.array_equal(a, b).item())
            # Materialized states remain valid after the encoder releases files.
            streaming.close()
            self.assertIsNone(streaming._shards)
            self.assertTrue(mx.array_equal(actual[-1], expected[-1]).item())
            with self.assertRaisesRegex(RuntimeError, "closed"):
                streaming.get_all_hidden_states(tokens, mask)
            # Changed files fail before their tensors can enter computation.
            with patch("d_ltx_gemma3.load_tokenizer", return_value=object()):
                streaming.load(root)
            path = root / "model-0.safetensors"
            original_stat = path.stat()
            with path.open("r+b") as target:
                target.seek(-1, os.SEEK_END)
                old = target.read(1)
                target.seek(-1, os.SEEK_END)
                target.write(bytes([old[0] ^ 1]))
            os.utime(path, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
            with self.assertRaisesRegex(ValueError, "changed"):
                streaming.get_all_hidden_states(tokens, mask)
            streaming.close()

    def test_bf16_every_state_matches_and_closes(self):
        self.compare(False)

    def test_q4_packed_weights_every_state_matches_and_closes(self):
        self.compare(True)


if __name__ == "__main__":
    unittest.main()
