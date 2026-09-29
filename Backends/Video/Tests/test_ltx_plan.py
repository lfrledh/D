"""CPU-only tests for the offline LTX CLI plan; no upstream imports."""

from __future__ import annotations

import ast
import importlib.util
import math
import os
from pathlib import Path
import tempfile
import unittest


_PLAN_FILE = Path(__file__).resolve().parents[1] / "Adapters" / "ltx_plan.py"
_TMP_ROOT = Path(
    "/Volumes/CodexProjects/Codex/D-Development/AgentTrials/"
    "D-VIDEO-MODELS-01/run-20260929T173017Z/LTX/tmp"
)
_spec = importlib.util.spec_from_file_location("d_video_ltx_plan", _PLAN_FILE)
assert _spec is not None and _spec.loader is not None
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)
build_plan = _module.build_plan


def _request(profile="ltx-2.3-dev-bf16-full-v1", *, stream=False):
    return {
        "schema_version": 1,
        "profile": profile,
        "prompt": "--夜景 '$(touch danger)'",
        "negative_prompt": "-模糊; $HOME",
        "width": 704,
        "height": 480,
        "frames": 97,
        "fps": 24.0,
        "steps": 30,
        "seed": 2**32 - 1,
        "stream_weights": stream,
        "cfg_scale": 3.0,
        "stg_scale": 1.0,
    }


class LTXPlanTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.TemporaryDirectory(dir=_TMP_ROOT)
        self.addCleanup(self.sandbox.cleanup)
        self.root = Path(self.sandbox.name)
        self.engine = self.root / "引擎 $runner"
        self.engine.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.engine.chmod(0o700)
        self.model = self.root / "模型 pack"
        self.model.mkdir()
        self.encoder = self.root / "Gemma 3 encoder"
        self.encoder.mkdir()
        self.output = self.root / "结果 $(touch nope).mp4"

    def plan(self, request=None, *, profile=None, **overrides):
        if request is None:
            request = _request(profile or "ltx-2.3-dev-bf16-full-v1")
        arguments = {
            "engine": self.engine,
            "model": self.model,
            "output": self.output,
            "text_encoder": self.encoder,
        }
        arguments.update(overrides)
        return build_plan(request, **arguments)

    def test_full_23_plan_is_literal_local_and_does_not_write_output(self):
        request = _request()
        original = dict(request)
        result = self.plan(request)
        self.assertEqual(set(result), {"argv", "environment", "provenance"})
        self.assertEqual(request, original)
        argv = result["argv"]
        self.assertEqual(argv[:3], [str(self.engine), "generate", "--one-stage"])
        self.assertIn("--dev-transformer=transformer-dev.safetensors", argv)
        self.assertIn("--video-decoder=conv", argv)
        self.assertIn(f"--model={self.model}", argv)
        self.assertIn(f"--gemma={self.encoder}", argv)
        self.assertIn(f"--output={self.output}", argv)
        self.assertIn(f"--prompt={request['prompt']}", argv)
        self.assertIn(f"--negative-prompt={request['negative_prompt']}", argv)
        for key in ("width", "height", "frames", "steps", "seed", "cfg_scale", "stg_scale"):
            self.assertIn(f"--{key.replace('_', '-')}={request[key]}", argv)
        self.assertIn("--frame-rate=24.0", argv)
        self.assertNotIn("--low-ram", argv)
        self.assertFalse(os.path.lexists(self.output))
        self.assertFalse((self.root / "danger").exists())
        self.assertFalse((self.root / "nope").exists())
        self.assertEqual(result["environment"]["HF_HUB_OFFLINE"], "1")
        self.assertFalse(result["provenance"]["resources_and_precision_verified"])
        self.assertTrue(result["provenance"]["plan_only"])
        self.assertEqual(result["provenance"]["video_decoder"], "conv")

    def test_streaming_only_changes_loading_switch_and_provenance(self):
        eager = self.plan(_request(stream=False))
        streamed = self.plan(_request(stream=True))
        self.assertEqual(streamed["argv"], eager["argv"] + ["--low-ram"])
        self.assertEqual(streamed["environment"], eager["environment"])
        self.assertEqual(streamed["provenance"]["weight_loading"], "transformer-block-streaming")
        self.assertEqual(eager["provenance"]["weight_loading"], "eager")
        self.assertEqual(streamed["provenance"]["request"]["seed"], 2**32 - 1)
        (self.model / "text_encoder.safetensors").write_bytes(b"fixture")
        (self.model / "text_encoder_config.json").write_text("{}", encoding="utf-8")
        profile = "ltx-2.5-dev-bf16-full-v1"
        eager_25 = self.plan(_request(profile, stream=False), text_encoder=None)
        streamed_25 = self.plan(_request(profile, stream=True), text_encoder=None)
        self.assertEqual(streamed_25["argv"], eager_25["argv"] + ["--low-ram"])
        self.assertEqual(streamed_25["provenance"]["video_decoder"], "diffusion")

    def test_empty_negative_prompt_and_finite_scales_are_not_rewritten(self):
        request = _request()
        request["negative_prompt"] = ""
        request["fps"] = 23.976
        request["cfg_scale"] = 0.0
        request["stg_scale"] = -0.5
        argv = self.plan(request)["argv"]
        for argument in (
            "--negative-prompt=", "--frame-rate=23.976", "--cfg-scale=0.0", "--stg-scale=-0.5"
        ):
            self.assertIn(argument, argv)

    def test_25_requires_pack_local_gemma4_evidence(self):
        request = _request("ltx-2.5-dev-bf16-full-v1")
        with self.assertRaisesRegex(ValueError, "text_encoder.safetensors"):
            self.plan(request, text_encoder=None)
        (self.model / "text_encoder.safetensors").write_bytes(b"fixture")
        with self.assertRaisesRegex(ValueError, "text_encoder_config.json"):
            self.plan(request, text_encoder=None)
        (self.model / "text_encoder_config.json").write_text("{}", encoding="utf-8")
        result = self.plan(request, text_encoder=None)
        self.assertIn(f"--gemma={self.model}", result["argv"])
        self.assertIn("--video-decoder=diffusion", result["argv"])
        self.assertEqual(result["provenance"]["text_encoder_source"], "pack-local-gemma4")
        self.assertEqual(result["provenance"]["video_decoder"], "diffusion")
        with self.assertRaisesRegex(ValueError, "text_encoder must be None"):
            self.plan(request)

    def test_23_requires_explicit_local_encoder(self):
        with self.assertRaisesRegex(ValueError, "requires an explicit"):
            self.plan(text_encoder=None)
        with self.assertRaisesRegex(ValueError, "absolute local path"):
            self.plan(text_encoder="org/gemma")

    def test_rejects_unknown_missing_and_wrong_request_shapes(self):
        with self.assertRaisesRegex(ValueError, "request must be a dict"):
            self.plan(request=[])
        for key, value in (
            ("schema_version", True),
            ("schema_version", 2),
            ("profile", "ltx-2.3-distilled"),
            ("prompt", ""),
            ("prompt", "safe\x00unsafe"),
            ("negative_prompt", None),
            ("negative_prompt", "safe\x00unsafe"),
            ("stream_weights", 1),
        ):
            with self.subTest(key=key, value=value):
                request = _request()
                request[key] = value
                with self.assertRaises(ValueError):
                    self.plan(request)
        for mutation in (lambda d: d.pop("fps"), lambda d: d.update(extra=True)):
            request = _request()
            mutation(request)
            with self.assertRaisesRegex(ValueError, "request fields differ"):
                self.plan(request)

    def test_rejects_invalid_numerics_without_adjustment(self):
        invalid = {
            "width": [True, 705, 0, 704.0],
            "height": [False, 481, -32],
            "frames": [True, 0, 98, 97.0],
            "fps": [True, 0, -1, math.inf, math.nan],
            "steps": [True, 0, 2.0],
            "seed": [True, -1, 1.0, 2**32],
            "cfg_scale": [True, math.inf, math.nan],
            "stg_scale": [False, math.inf, math.nan],
        }
        for key, values in invalid.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    request = _request()
                    request[key] = value
                    with self.assertRaises(ValueError):
                        self.plan(request)

    def test_paths_are_absolute_local_and_output_is_unused(self):
        for name, value in (
            ("engine", "runner"),
            ("engine", self.model),
            ("model", "org/ltx"),
            ("model", self.engine),
            ("output", "video.mp4"),
            ("output", str(self.root / "invalid\x00video.mp4")),
            ("output", self.root / "missing" / "video.mp4"),
            ("text_encoder", self.engine),
        ):
            with self.subTest(name=name, value=value):
                with self.assertRaises(ValueError):
                    self.plan(**{name: value})
        self.output.write_bytes(b"existing work")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.plan()
        self.output.unlink()
        self.output.symlink_to(self.root / "missing target")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.plan()


class UpstreamSourceCrossCheck(unittest.TestCase):
    def test_pinned_cli_and_streaming_wiring(self):
        source = os.environ.get("D_VIDEO_UPSTREAM_SOURCE")
        if not source:
            self.skipTest("D_VIDEO_UPSTREAM_SOURCE not provided; fixed upstream source cross-check skipped")
        upstream = Path(source)
        cli_file = upstream / "packages/ltx-pipelines-mlx/src/ltx_pipelines_mlx/cli.py"
        base_file = upstream / "packages/ltx-pipelines-mlx/src/ltx_pipelines_mlx/_base.py"
        blocks_file = upstream / "packages/ltx-pipelines-mlx/src/ltx_pipelines_mlx/utils/blocks.py"
        selector_file = (
            upstream / "packages/ltx-core-mlx/src/ltx_core_mlx/text_encoders/gemma/"
            "encoders/encoder_configurator.py"
        )
        cli = ast.parse(cli_file.read_text(encoding="utf-8"))
        base = ast.parse(base_file.read_text(encoding="utf-8"))
        blocks = ast.parse(blocks_file.read_text(encoding="utf-8"))
        selector = ast.parse(selector_file.read_text(encoding="utf-8"))

        option_strings = {
            arg.value
            for node in ast.walk(cli)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr == "add_argument"
            for arg in node.args
            if isinstance(arg, ast.Constant) and isinstance(arg.value, str)
        }
        self.assertTrue(
            {
                "--one-stage", "--dev-transformer", "--model", "--gemma", "--output",
                "--prompt", "--negative-prompt", "--width", "--height", "--frames",
                "--frame-rate", "--steps", "--seed", "--cfg-scale", "--stg-scale", "--low-ram",
                "--video-decoder",
            }.issubset(option_strings)
        )
        decoder_arg = next(
            node for node in ast.walk(cli)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr == "add_argument"
            and any(isinstance(arg, ast.Constant) and arg.value == "--video-decoder" for arg in node.args)
        )
        decoder_options = {keyword.arg: ast.unparse(keyword.value) for keyword in decoder_arg.keywords}
        self.assertEqual(decoder_options["choices"], "VIDEO_DECODER_CHOICES")
        self.assertEqual(decoder_options["default"], "'conv'")
        decoder_values = next(
            ast.literal_eval(node.value) for node in blocks.body
            if isinstance(node, ast.Assign)
            and any(isinstance(target, ast.Name) and target.id == "VIDEO_DECODER_CHOICES" for target in node.targets)
        )
        self.assertEqual(decoder_values, ("conv", "diffusion"))
        generate = next(
            node for node in cli.body if isinstance(node, ast.FunctionDef) and node.name == "_cmd_generate"
        )
        constructors = [
            node for node in ast.walk(generate)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "TI2VidOneStagePipeline"
        ]
        self.assertEqual(len(constructors), 1)
        kwargs = {keyword.arg: ast.unparse(keyword.value) for keyword in constructors[0].keywords}
        self.assertEqual(kwargs["model_dir"], "args.model")
        self.assertEqual(kwargs["gemma_model_id"], "args.gemma")
        self.assertEqual(kwargs["dev_transformer"], "args.dev_transformer")
        self.assertEqual(kwargs["low_ram_streaming"], "getattr(args, 'low_ram', False)")
        one_stage = next(
            node for node in ast.walk(generate)
            if isinstance(node, ast.If) and ast.unparse(node.test) == "args.one_stage"
        )
        one_stage_source = ast.unparse(one_stage)
        self.assertIn("pipe.video_decoder = args.video_decoder", one_stage_source)
        for mapping in (
            "num_steps'] = args.steps",
            "cfg_scale'] = args.cfg_scale",
            "stg_scale'] = args.stg_scale",
            "negative_prompt'] = args.negative_prompt",
            "frame_rate=args.frame_rate",
            "num_frames=_resolve_num_frames_arg(args)",
        ):
            self.assertIn(mapping, one_stage_source)

        loader = next(
            node for node in ast.walk(base)
            if isinstance(node, ast.FunctionDef) and node.name == "_load_transformer_with_optional_streaming"
        )
        self.assertTrue(
            any(
                keyword.arg == "low_ram_streaming"
                and ast.unparse(keyword.value) == "self.low_ram_streaming"
                for call in ast.walk(loader) if isinstance(call, ast.Call)
                for keyword in call.keywords
            )
        )
        select = next(
            node for node in selector.body
            if isinstance(node, ast.FunctionDef) and node.name == "select_text_encoder"
        )
        returned = {
            node.value.value for node in ast.walk(select)
            if isinstance(node, ast.Return) and isinstance(node.value, ast.Constant)
        }
        self.assertEqual(returned, {"gemma3", "gemma4"})


if __name__ == "__main__":
    unittest.main()
