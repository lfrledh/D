"""CPU-only closure and source-structure checks for the pinned LTX-2.5 patch.

Set D_LTX_STREAMING_BASELINE to the unpacked pinned site-packages directory.
The test applies the repository patch to copies; it never imports MLX or
executes the patched source. Real numeric parity and memory behavior require
the separate Lead-owned model run.
"""

import ast
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tokenize
import unittest


REPO = Path(__file__).resolve().parents[3]
PATCH = REPO / "Backends/Video/Adapters/Patches/ltx25-gemma4-streaming.patch"
MANIFEST = PATCH.with_suffix(".json")
BASELINE = os.environ.get("D_LTX_STREAMING_BASELINE")


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _tree(path: Path) -> ast.Module:
    with tokenize.open(path) as source:
        text = source.read()
    compile(text, str(path), "exec", dont_inherit=True)
    return ast.parse(text, filename=str(path))


def _class(tree: ast.Module, name: str) -> ast.ClassDef:
    return next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == name)


def _method(cls: ast.ClassDef, name: str) -> ast.FunctionDef:
    return next(node for node in cls.body if isinstance(node, ast.FunctionDef) and node.name == name)


def _calls(node: ast.AST) -> list[str]:
    return [ast.unparse(item.func) for item in ast.walk(node) if isinstance(item, ast.Call)]


@unittest.skipUnless(BASELINE, "set D_LTX_STREAMING_BASELINE to the pinned site-packages tree")
class LTX25Gemma4StreamingPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        cls.temp = tempfile.TemporaryDirectory(dir=os.environ.get("D_LTX_STREAMING_TMP"))
        cls.root = Path(cls.temp.name)
        assert len(cls.manifest["files"]) == 3
        for entry in cls.manifest["files"]:
            relative = Path(entry["path"])
            source = Path(BASELINE) / str(relative).split("/src/", 1)[1]
            target = cls.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            assert _sha256(target) == entry["before_sha256"], relative
        result = subprocess.run(
            ["patch", "-p1", "--batch", "--forward", "-i", str(PATCH), "-d", str(cls.root)],
            capture_output=True, text=True, check=False,
        )
        if result.returncode:
            raise AssertionError(f"Patch failed ({result.returncode}): {result.stdout} {result.stderr}")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def source(self, suffix: str) -> ast.Module:
        path = next(self.root / entry["path"] for entry in self.manifest["files"]
                    if entry["path"].endswith(suffix))
        return _tree(path)

    def test_fixed_source_closure_and_syntax(self) -> None:
        self.assertEqual(self.manifest["commit"], "1724ca673d59f023a8a95efee06e5d36d61c2765")
        self.assertEqual(self.manifest["license"], "MIT")
        self.assertEqual(len(self.manifest["files"]), 3)
        for entry in self.manifest["files"]:
            with self.subTest(path=entry["path"]):
                path = self.root / entry["path"]
                self.assertEqual(_sha256(path), entry["after_sha256"])
                _tree(path)

    def test_opt_in_routes_only_existing_low_ram_flag(self) -> None:
        tree = self.source("ltx_pipelines_mlx/_base.py")
        class_nodes = [node for node in tree.body if isinstance(node, ast.ClassDef)]
        prompt_calls = [node for cls in class_nodes for node in ast.walk(cls)
                        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                        and node.func.id == "_PromptEncoderBlock"]
        self.assertEqual(len(prompt_calls), 1)
        keywords = {kw.arg: ast.unparse(kw.value) for kw in prompt_calls[0].keywords}
        self.assertEqual(keywords["low_ram_streaming"], "self.low_ram_streaming")

    def test_streams_configured_layers_with_original_decoder(self) -> None:
        cls = _class(self.source("ltx_core_mlx/text_encoders/gemma/gemma4.py"), "StreamingGemma4TextModel")
        init, forward, close = (_method(cls, name) for name in ("__init__", "__call__", "close"))
        init_calls = _calls(init)
        self.assertIn("Gemma4DecoderLayer", init_calls)
        self.assertIn("BlockStreamer", init_calls)
        self.assertIn("mx.eval", init_calls)
        self.assertNotIn("apply_quantization", init_calls)
        loops = [node for node in ast.walk(forward) if isinstance(node, ast.For)]
        self.assertEqual(len(loops), 1)
        self.assertEqual(ast.unparse(loops[0].iter), "range(self.config.num_hidden_layers)")
        body_calls = _calls(loops[0])
        self.assertIn("self._streamer.bind", body_calls)
        self.assertIn("mx.eval", body_calls)
        self.assertIn("hidden_states_list.append", body_calls)
        self.assertLess(body_calls.index("mx.eval"), body_calls.index("hidden_states_list.append"))
        self.assertIn("streamer.close", _calls(close))
        self.assertIn("mx.clear_cache", _calls(close))
        self.assertNotIn("astype", _calls(forward))

    def test_tower_drains_before_projection_and_failure_closes(self) -> None:
        cls = _class(self.source("ltx_pipelines_mlx/utils/blocks.py"), "PromptEncoder")
        helper = _method(cls, "_encode_gemma4_streaming")
        statements = helper.body
        phases = [node for node in statements if isinstance(node, ast.Try)]
        self.assertEqual(len(phases), 2)
        tower_phase, projection_phase = phases
        self.assertIn("_materialize", _calls(tower_phase))
        self.assertIn("tower.close", _calls(ast.Module(body=tower_phase.finalbody, type_ignores=[])))
        self.assertIn("self._load_feature_extractor", _calls(projection_phase))
        self.assertIn("_materialize", _calls(projection_phase))
        self.assertEqual(ast.unparse(projection_phase.finalbody[0]), "self._feature_extractor = None")
        encode = _method(cls, "encode")
        handlers = [node for node in ast.walk(encode) if isinstance(node, ast.ExceptHandler)]
        self.assertEqual(len(handlers), 1)
        self.assertEqual(ast.unparse(handlers[0].type), "BaseException")
        self.assertIn("self.free", _calls(handlers[0]))
        load = _method(cls, "load")
        text = ast.unparse(load)
        self.assertLess(text.index("encoder.load_tokenizer(self.model_dir)"),
                        text.index("self._text_encoder = encoder"))
        single = _method(cls, "__call__")
        self.assertIn("self.encode", _calls(single))


if __name__ == "__main__":
    unittest.main()
