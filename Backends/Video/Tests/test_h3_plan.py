"""CPU-only checks for H3 CLI planning; no model packages or inference."""

import importlib.util
import os
from pathlib import Path
import re
import tempfile
import unittest


PLAN_FILE = Path(__file__).resolve().parents[1] / "Adapters" / "h3_plan.py"
SPEC = importlib.util.spec_from_file_location("h3_plan", PLAN_FILE)
h3_plan = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(h3_plan)
TEMP_ROOT = Path(os.environ["TMPDIR"])


def request():
    return {
        "schema_version": 1,
        "profile": h3_plan.PROFILE,
        "prompt": "-雨后街道 ' ; $(touch impossible) 🎞️",
        "negative_prompt": "",
        "width": 512,
        "height": 512,
        "frames": 22,
        "fps": 24,
        "steps": 20,
        "seed": 42,
        "stream_weights": False,
    }


class H3PlanChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=TEMP_ROOT)
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.engine = root / "h3 engine ; $(noop)"
        self.engine.write_text("fixture only")
        self.engine.chmod(0o700)
        self.model = root / "模型 pack"
        self.model.mkdir()
        (self.model / "sentinel").write_text("unchanged")
        self.output = root / "输出 ; $(noop).mp4"

    def plan(self, value=None, **paths):
        arguments = {"engine": str(self.engine), "model": str(self.model),
                     "output": str(self.output)}
        arguments.update(paths)
        return h3_plan.build_plan(request() if value is None else value, **arguments)

    def test_exact_full_precision_arguments_and_pure_planning(self):
        before = sorted(path.name for path in self.model.iterdir())
        value = request()
        saved = value.copy()
        result = self.plan(value)
        self.assertEqual(value, saved)
        self.assertEqual(sorted(result), ["argv", "environment", "provenance"])
        argv = result["argv"]
        self.assertEqual(argv[0], str(self.engine))
        self.assertEqual(argv[1:4], [f"--model-dir={self.model}",
                                      f"--prompt={value['prompt']}",
                                      f"--output={self.output}"])
        self.assertEqual(result["environment"], {"H3_DIT_F32_FINAL": "1"})
        self.assertTrue({"--layers=50", "--reuse=1", "--core-reuse=1",
                         "--use-reference-rope", "--use-slower-bf16-mlp",
                         "--use-slower-bf16-qkv",
                         "--use-slower-bf16-attention-output"} <= set(argv))
        self.assertTrue({"--width=512", "--height=512", "--frames=22",
                         "--steps=20", "--seed=42"} <= set(argv))
        self.assertFalse(any(option.startswith(("--render-", "--token-reduction",
                           "--use-int8-row-fc2", "--show", "--seconds")) for option in argv))
        self.assertEqual(before, sorted(path.name for path in self.model.iterdir()))
        self.assertEqual((self.model / "sentinel").read_text(), "unchanged")
        self.assertFalse(os.path.lexists(self.output))
        self.assertFalse(result["provenance"]["resource_and_precision_verified"])
        self.assertFalse(result["provenance"]["execution_performed"])
        self.assertEqual(result["provenance"]["request"], saved)

    def test_streaming_changes_only_loading_strategy(self):
        resident = self.plan()
        streamed_request = request()
        streamed_request["stream_weights"] = True
        streamed = self.plan(streamed_request)
        self.assertEqual(streamed["argv"][:-1], resident["argv"])
        self.assertEqual(streamed["argv"][-1], "--ssd-streaming")
        self.assertEqual(streamed["environment"], resident["environment"])
        self.assertEqual(streamed["provenance"]["weight_loading"], "ssd-streaming")
        self.assertEqual(resident["provenance"]["weight_loading"], "resident")
        self.assertFalse(os.path.lexists(self.output))

    def test_exact_schema_and_types(self):
        for key, bad in [
            ("schema_version", True), ("schema_version", 2), ("profile", "wan"),
            ("prompt", "  "), ("prompt", 4), ("prompt", "hi\0there"),
            ("negative_prompt", " "), ("negative_prompt", None),
            ("width", True), ("height", 512.0), ("frames", 22.0),
            ("fps", True), ("fps", 30), ("steps", float("nan")),
            ("seed", True), ("seed", 1.0), ("stream_weights", 1),
        ]:
            with self.subTest(key=key, bad=bad):
                changed = request()
                changed[key] = bad
                with self.assertRaises(ValueError):
                    self.plan(changed)
        for changed in [dict(request(), download=True),
                        {key: value for key, value in request().items() if key != "seed"}]:
            with self.assertRaises(ValueError):
                self.plan(changed)
        with self.assertRaises(ValueError):
            self.plan([])

    def test_bounds_reject_adjustment_and_overflow(self):
        for key, bad in [
            ("width", 31), ("width", 513), ("height", 33),
            ("frames", 5), ("frames", 23), ("frames", 363),
            ("steps", 1), ("steps", 1001), ("seed", -1), ("seed", 2**64),
        ]:
            with self.subTest(key=key, bad=bad):
                changed = request()
                changed[key] = bad
                with self.assertRaises(ValueError):
                    self.plan(changed)
        changed = request()
        changed.update(width=768, height=1376)
        with self.assertRaises(ValueError):
            self.plan(changed)
        changed.update(width=1344, height=768, frames=362, steps=1000,
                       seed=2**64 - 1)
        result = self.plan(changed)
        self.assertIn("--frames=362", result["argv"])
        self.assertIn(f"--seed={2**64 - 1}", result["argv"])

    def test_local_path_types_and_non_overwrite(self):
        for name, bad in [
            ("engine", "h3"), ("engine", str(self.model)),
            ("model", "owner/model"), ("model", str(self.engine)),
            ("output", "relative.mp4"), ("output", str(self.model / "missing" / "x.mp4")),
            ("engine", str(self.output)),
        ]:
            with self.subTest(name=name, bad=bad), self.assertRaises(ValueError):
                self.plan(**{name: bad})
        with self.assertRaises(ValueError):
            self.plan(text_encoder=str(self.model))
        self.output.write_text("existing")
        with self.assertRaises(ValueError):
            self.plan()
        self.output.unlink()
        self.output.symlink_to(self.model / "missing-checkpoint")
        with self.assertRaises(ValueError):
            self.plan()

    def test_upstream_cli_and_streaming_source(self):
        source_name = os.environ.get("D_VIDEO_UPSTREAM_SOURCE")
        if not source_name:
            self.skipTest("D_VIDEO_UPSTREAM_SOURCE is not set; fixed upstream cross-check skipped")
        source = Path(source_name)
        main = (source / "main.c").read_text()
        h3 = (source / "h3.c").read_text()
        dit = (source / "h3_dit.c").read_text()
        header = (source / "h3.h").read_text()
        host_header = (source / "h3_host.h").read_text()
        host = (source / "h3_host.c").read_text()
        self.assertIn("getopt_long", main)
        for name in ("model-dir", "prompt", "output", "width", "height", "frames",
                     "steps", "seed", "layers", "reuse", "core-reuse",
                     "use-reference-rope", "use-slower-bf16-mlp",
                     "use-slower-bf16-qkv", "use-slower-bf16-attention-output",
                     "ssd-streaming"):
            with self.subTest(option=name):
                self.assertRegex(main, r'\{"' + re.escape(name) + r'",\s*(?:required_argument|no_argument)')
        self.assertIn("case OPT_SSD_STREAMING: params.ssd_streaming = 1", main)
        for mapping in ("params.dit_layers = parse_int(optarg, \"layers\")",
                        "params.denoise_reuse = parse_int(optarg, \"reuse\")",
                        "params.core_reuse = parse_int(optarg, \"core reuse\")",
                        "params.use_reference_rope = 1",
                        "params.use_slower_bf16_mlp = 1",
                        "params.use_slower_bf16_qkv = 1",
                        "params.use_slower_bf16_attention_output = 1"):
            self.assertIn(mapping, main)
        self.assertIn("#define H3_DEFAULT_DIT_LAYERS 50", header)
        for definition in ("#define H3_CANVAS_MULTIPLE 32",
                           "#define H3_MAX_PIXELS (768 * 1344)",
                           "#define H3_FPS 24"):
            self.assertIn(definition, host_header)
        self.assertIn("int remainder = (value - 5) % 17", host)
        self.assertIn("h3_align_frame_count(params->frames) > 362", h3)
        self.assertIn("params->steps < 2 || params->steps > H3_MAX_STEPS", h3)
        self.assertIn("params->ssd_streaming && params->use_int8_row_fc2", h3)
        self.assertIn('getenv("H3_DIT_F32_FINAL") == NULL', dit)
        self.assertIn("if (dit->ssd_streaming)", dit)
        self.assertIn("prepare_stream_layer(dit, index", dit)
        for guard in ("!dit->ssd_streaming && !use_slower_bf16_qkv",
                      "!use_slower_bf16_mlp &&", "!use_slower_bf16_attention_output &&"):
            self.assertIn(guard, dit)


if __name__ == "__main__":
    unittest.main(verbosity=2)
