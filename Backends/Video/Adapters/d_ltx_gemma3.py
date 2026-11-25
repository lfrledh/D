"""Same Gemma3 text computation, with one original-dtype layer resident.

The caller has admitted the fixed D inventory. Header-derived locations are
necessary: both pinned repositories contain a stale shard index (the Q4 index
even names the pre-quantization five-shard layout). Never rewrite those files.
No image tower or language head is consumed by the existing LTX text encoder.
"""
from __future__ import annotations

import json
import struct
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
from mlx_lm.models.gemma3 import ModelArgs as GemmaArgs
from mlx_lm.models.gemma3_text import ModelArgs, TransformerBlock
from mlx_lm.utils import load_config, load_tokenizer
from ltx_core_mlx.text_encoders.gemma.encoders.base_encoder import GemmaLanguageModel


class Gemma3Shards:
    """Bounded metadata only; no evaluated weight array survives a read."""

    def __init__(self, directory: Path):
        self.directory = directory
        self.locations: dict[str, str] = {}
        self.identities = {}
        self.headers = {}
        for path in sorted(directory.glob("model*.safetensors")):
            if path.is_symlink() or not path.is_file():
                raise ValueError("Gemma3 shard is not a regular file")
            self.identities[path.name] = self.identity(path)
            with path.open("rb") as source:
                count = struct.unpack("<Q", source.read(8))[0]
                if not 0 < count <= 16 * 1024 * 1024:
                    raise ValueError("Gemma3 header exceeds the bounded metadata size")
                header = json.loads(source.read(count))
            for key, tensor in header.items():
                if key == "__metadata__":
                    continue
                if key in self.locations:
                    raise ValueError("Duplicate Gemma3 tensor across shards: " + key)
                self.locations[key] = path.name
                self.headers[key] = tensor
        if not self.locations:
            raise ValueError("Gemma3 has no weight shards")
        index = json.loads((directory / "model.safetensors.index.json").read_bytes())["weight_map"]
        # The published index may name old shard locations, but its logical
        # tensors must still exist. Packed scales/biases and the tied head are
        # additional header entries in the pinned packs.
        if not set(index).issubset(self.locations):
            raise ValueError("Gemma3 index names missing tensors")

    @staticmethod
    def identity(path):
        value = path.stat(follow_symlinks=False)
        return (value.st_dev, value.st_ino, value.st_mode, value.st_size,
                value.st_mtime_ns, value.st_ctime_ns)

    def verify(self):
        for filename, identity in self.identities.items():
            if self.identity(self.directory / filename) != identity:
                raise ValueError("Gemma3 shard changed during evaluation")

    def read(self, prefix: str) -> dict:
        keys = [key for key in self.locations if key.startswith(prefix)]
        if not keys:
            raise ValueError("Missing Gemma3 tensor group: " + prefix)
        result = {}
        for filename in sorted({self.locations[key] for key in keys}):
            path = self.directory / filename
            if self.identity(path) != self.identities[filename]:
                raise ValueError("Gemma3 shard changed after admission")
            mapped = mx.load(str(path))
            for key in keys:
                if self.locations[key] == filename:
                    result[key[len(prefix):]] = mapped[key]
            # Drop every unselected lazy array BEFORE evaluation. Keeping the
            # whole dictionary would retain previously evaluated layers.
            mapped.clear()
            if self.identity(path) != self.identities[filename]:
                raise ValueError("Gemma3 shard changed while reading")
        return result


class StreamingGemma3LanguageModel(GemmaLanguageModel):
    """Uses pinned mlx-lm blocks and the resident LTX mask/scaling semantics."""

    def load(self, model_path=None):
        directory = Path(model_path or self._model_path)
        if not directory.is_absolute() or not directory.is_dir():
            raise ValueError("Gemma3 streaming requires an admitted local directory")
        config = load_config(directory)
        args = GemmaArgs.from_dict(config)
        self._args = ModelArgs.from_dict(args.text_config)
        self._quantization = config.get("quantization")
        self._shards = Gemma3Shards(directory)
        prefix = "language_model.model.layers."
        layers = {int(key[len(prefix):].split(".", 1)[0]) for key in self._shards.locations
                  if key.startswith(prefix)}
        if layers != set(range(self._args.num_hidden_layers)):
            raise ValueError("Gemma3 does not contain every configured text layer")
        self._tokenizer = load_tokenizer(directory, eos_token_ids=config.get("eos_token_id"))
        self._model_path = str(directory)
        self._closed = False

    def _quantize(self, module, weights, prefix):
        quantization = self._quantization
        if quantization is not None:
            def predicate(path, child):
                if prefix + path in quantization:
                    return quantization[prefix + path]
                return hasattr(child, "to_quantized") and path + ".scales" in weights
            nn.quantize(module, group_size=quantization["group_size"], bits=quantization["bits"],
                        mode=quantization.get("mode", "affine"), class_predicate=predicate)

    def get_all_hidden_states(self, token_ids, attention_mask=None):
        if self._closed:
            raise RuntimeError("Gemma3 streaming encoder is closed")
        self._ensure_metal_headroom()
        # Module constructors initialize placeholders. Their random draws must
        # not alter the caller's subsequent diffusion random stream.
        random_state = list(mx.random.state)
        mx.eval(random_state)
        holder = block = None
        try:
            holder = nn.Module()
            holder.embed_tokens = nn.Embedding(self._args.vocab_size, self._args.hidden_size)
            weights = self._shards.read("language_model.model.embed_tokens.")
            named = {"embed_tokens." + key: value for key, value in weights.items()}
            self._quantize(holder, named, "language_model.model.")
            holder.load_weights(list(named.items()), strict=True)
            weights.clear(); named.clear()
            h = holder.embed_tokens(token_ids)
            h = h * mx.array(h.shape[-1] ** 0.5, dtype=mx.bfloat16).astype(h.dtype)
            mx.eval(h)
            self._shards.verify()
            holder = None
            mx.clear_cache()
            states = [h]
            length = token_ids.shape[1]
            causal = mx.triu(mx.full((length, length), -1e9, dtype=mx.bfloat16), k=1)
            if attention_mask is not None:
                padding = (1 - attention_mask[:, None, None, :].astype(mx.bfloat16)) * -1e9
                mask = causal[None, None, :, :] + padding
            else:
                mask = causal[None, None, :, :]
            for index in range(self._args.num_hidden_layers):
                prefix = f"language_model.model.layers.{index}."
                block = TransformerBlock(self._args, index)
                weights = self._shards.read(prefix)
                self._quantize(block, weights, prefix)
                block.load_weights(list(weights.items()), strict=True)
                weights.clear()
                h = block(h, mask=mask, cache=None)
                if isinstance(h, tuple):
                    h = h[0]
                mx.eval(h)
                self._shards.verify()
                states.append(h)
                block = None
                mx.clear_cache()
            # Same 49 values as the resident encoder; no final norm is applied
            # here because the pinned Gemma3 LTX wrapper does not apply it.
            return states
        finally:
            holder = block = None
            mx.random.state = random_state
            mx.clear_cache()

    def close(self):
        self._closed = True
        self._model = None
        self._shards = None
        mx.clear_cache()
