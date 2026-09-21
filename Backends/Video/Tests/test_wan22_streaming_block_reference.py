"""CPU fixtures for the bounded Wan2.2 streaming block reference.

The tests intentionally require D_TEST_TEMP_DIR.  They never discover or read
the real Wan model, and unittest remains the test runner.
"""

from __future__ import annotations

import copy
import gc
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import weakref

from safetensors.torch import save_file
import torch

import wan22_streaming_block_reference as streaming
from wan22_streaming_block_reference import (
    BlockLoadCancelled,
    BlockLoader,
    BlockLoaderPoisonedError,
)


class _TinyBlock(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.modulation = torch.nn.Parameter(torch.empty(2, device="meta"))
        self.norm1 = torch.nn.Linear(2, 2, bias=False, device="meta")
        self.proj = torch.nn.Linear(2, 2, bias=False, device="meta")


class _TinyModel(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.blocks = torch.nn.ModuleList([_TinyBlock() for _ in range(30)])


def _identity(path: Path) -> dict[str, int]:
    value = os.stat(path, follow_symlinks=False)
    return {
        "device": value.st_dev,
        "inode": value.st_ino,
        "size": value.st_size,
        "mtimeNS": value.st_mtime_ns,
    }


def _target_dtype(name: str) -> str:
    if name.endswith(".modulation") or any(
        part.startswith("norm") for part in name.split(".")
    ):
        return "float32"
    return "bfloat16"


class StreamingBlockReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        configured = os.environ.get("D_TEST_TEMP_DIR")
        if not configured:
            raise RuntimeError("D_TEST_TEMP_DIR is required for streaming fixtures")
        root = Path(configured).expanduser().resolve(strict=True)
        if not root.is_dir():
            raise RuntimeError("D_TEST_TEMP_DIR must be an existing directory")
        cls.fixture_root = root

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(
            prefix="wan22-streaming-", dir=str(self.fixture_root)
        )
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve(strict=True)

    def _make_fixture(self, replacements=None):
        replacements = dict(replacements or {})
        model = _TinyModel()
        values: dict[str, torch.Tensor] = {}
        shards: dict[str, dict[str, torch.Tensor]] = {
            "part-a.safetensors": {},
            "part-b.safetensors": {},
        }
        records: dict[str, list[dict]] = {"0": [], "14": [], "29": []}
        sequence = 1
        for block_index in (0, 14, 29):
            for relative_name, parameter in model.blocks[
                block_index
            ].named_parameters(recurse=True):
                name = f"blocks.{block_index}.{relative_name}"
                value = torch.arange(
                    sequence,
                    sequence + parameter.numel(),
                    dtype=torch.float32,
                ).reshape(parameter.shape)
                sequence += parameter.numel() + 3
                value = replacements.get(name, value)
                values[name] = value
                shard = (
                    "part-a.safetensors"
                    if block_index == 0
                    or (block_index == 14 and relative_name != "proj.weight")
                    else "part-b.safetensors"
                )
                shards[shard][name] = value
                records[str(block_index)].append(
                    {
                        "name": name,
                        "shard": shard,
                        "shape": list(parameter.shape),
                        "sourceDtype": "float32",
                        "targetDtype": _target_dtype(name),
                    }
                )
        for shard, tensors in shards.items():
            save_file(tensors, self.root / shard)
        manifest = {
            "schemaVersion": 1,
            "blocks": records,
            "shards": {
                shard: _identity(self.root / shard) for shard in sorted(shards)
            },
        }
        return model, manifest, values

    def _assert_all_blocks_meta(self, model):
        for block in model.blocks:
            for parameter in block.parameters():
                self.assertEqual(parameter.device.type, "meta")

    def _assert_block_values(self, block_index, block, values):
        for relative_name, parameter in block.named_parameters(recurse=True):
            name = f"blocks.{block_index}.{relative_name}"
            expected_dtype = (
                torch.float32 if _target_dtype(name) == "float32" else torch.bfloat16
            )
            self.assertEqual(parameter.device.type, "cpu")
            self.assertEqual(parameter.dtype, expected_dtype)
            torch.testing.assert_close(
                parameter.detach(), values[name].to(dtype=expected_dtype), rtol=0, atol=0
            )

    def test_constructor_is_metadata_only_and_freezes_manifest(self):
        model, manifest, _ = self._make_fixture()
        with mock.patch.object(
            streaming, "safe_open", side_effect=AssertionError("unexpected read")
        ) as opened:
            loader = BlockLoader(model, self.root, manifest, device="cpu")
        opened.assert_not_called()
        manifest["blocks"]["0"][0]["shape"][0] = 99
        with loader.resident(0):
            pass
        self._assert_all_blocks_meta(model)

    def test_normal_and_cross_shard_leases_are_exact_and_restore_meta(self):
        model, manifest, values = self._make_fixture()
        loader = BlockLoader(model, self.root, manifest, device="cpu")
        for block_index in (0, 14, 29, 0):
            with loader.resident(block_index) as block:
                self._assert_block_values(block_index, block, values)
                for other_index, other in enumerate(model.blocks):
                    if other_index != block_index:
                        self.assertTrue(
                            all(parameter.device.type == "meta" for parameter in other.parameters())
                        )
                resident_reference = weakref.ref(block.proj.weight)
            gc.collect()
            self.assertIsNone(resident_reference())
            self._assert_all_blocks_meta(model)
        statistics = dict(loader.statistics)
        self.assertEqual(statistics["leases"], 4)
        self.assertEqual(statistics["tensorsRead"], 12)
        self.assertGreater(statistics["logicalBytes"], 0)
        self.assertGreaterEqual(statistics["readSeconds"], 0.0)

    def test_checkpoint_events_are_read_only_scalar_mappings(self):
        model, manifest, _ = self._make_fixture()
        events = []
        mutation_failures = []

        def checkpoint(event):
            events.append(dict(event))
            try:
                event["changed"] = True
            except TypeError as error:
                mutation_failures.append(error)

        loader = BlockLoader(
            model, self.root, manifest, device="cpu", checkpoint=checkpoint
        )
        with loader.resident(14):
            pass
        stages = [event["stage"] for event in events]
        self.assertEqual(stages[0], "before_load")
        self.assertEqual(stages[-2:], ["before_release", "released"])
        self.assertEqual(stages.count("after_read"), 3)
        self.assertEqual(stages.count("before_install"), 3)
        self.assertEqual(stages.count("after_install"), 3)
        self.assertEqual(stages.count("ready"), 1)
        self.assertEqual(len(mutation_failures), len(events))
        for event in events:
            self.assertTrue(
                all(isinstance(value, (str, int, float)) for value in event.values())
            )
        after_reads = [event for event in events if event["stage"] == "after_read"]
        self.assertTrue(all(event["logicalBytes"] > 0 for event in after_reads))
        self.assertTrue(all(event["readSeconds"] >= 0 for event in after_reads))

    def test_every_checkpoint_can_cancel_and_cleanup_allows_retry(self):
        stages = (
            "before_load",
            "after_read",
            "before_install",
            "after_install",
            "ready",
            "before_release",
            "released",
        )
        for cancelled_stage in stages:
            with self.subTest(stage=cancelled_stage):
                model, manifest, _ = self._make_fixture()
                state = {"cancelled": False}

                def checkpoint(event):
                    if event["stage"] == cancelled_stage and not state["cancelled"]:
                        state["cancelled"] = True
                        raise BlockLoadCancelled(cancelled_stage)

                loader = BlockLoader(
                    model,
                    self.root,
                    manifest,
                    device="cpu",
                    checkpoint=checkpoint,
                )
                with self.assertRaisesRegex(BlockLoadCancelled, cancelled_stage):
                    with loader.resident(0):
                        pass
                self._assert_all_blocks_meta(model)
                with loader.resident(0):
                    pass
                self._assert_all_blocks_meta(model)

    def test_nested_reentry_close_and_boolean_indices_are_rejected(self):
        model, manifest, _ = self._make_fixture()
        loader = BlockLoader(model, self.root, manifest, device="cpu")
        for invalid in (True, False, 1, 30, "0", None):
            with self.subTest(index=invalid):
                with self.assertRaises(ValueError):
                    loader.resident(invalid)
        context = loader.resident(0)
        with context:
            with self.assertRaises(RuntimeError):
                loader.close()
            with self.assertRaises(RuntimeError):
                with loader.resident(14):
                    pass
        with self.assertRaises(RuntimeError):
            context.__enter__()
        loader.close()
        loader.close()
        with self.assertRaises(RuntimeError):
            with loader.resident(0):
                pass

    def test_block14_cross_shard_cancellation_restores_and_retries(self):
        model, manifest, _ = self._make_fixture()
        state = {"cancelled": False}

        def checkpoint(event):
            if (
                event["stage"] == "after_read"
                and event.get("name") == "blocks.14.proj.weight"
                and not state["cancelled"]
            ):
                state["cancelled"] = True
                raise BlockLoadCancelled("block14 cross-shard cancellation")

        loader = BlockLoader(
            model, self.root, manifest, device="cpu", checkpoint=checkpoint
        )
        with self.assertRaisesRegex(BlockLoadCancelled, "cross-shard"):
            with loader.resident(14):
                pass
        self._assert_all_blocks_meta(model)
        with loader.resident(14):
            pass
        self._assert_all_blocks_meta(model)

    def test_block_body_and_install_exceptions_restore_meta(self):
        model, manifest, _ = self._make_fixture()
        loader = BlockLoader(model, self.root, manifest, device="cpu")
        with self.assertRaisesRegex(LookupError, "block failed"):
            with loader.resident(0):
                raise LookupError("block failed")
        self._assert_all_blocks_meta(model)

        original_install = loader._install
        calls = {"count": 0}

        def failing_install(*args, **kwargs):
            calls["count"] += 1
            if calls["count"] == 2:
                raise RuntimeError("install failed")
            return original_install(*args, **kwargs)

        with mock.patch.object(loader, "_install", side_effect=failing_install):
            with self.assertRaisesRegex(RuntimeError, "install failed"):
                with loader.resident(14):
                    pass
        self._assert_all_blocks_meta(model)
        with loader.resident(14):
            pass

    def test_release_error_does_not_replace_block_error(self):
        model, manifest, _ = self._make_fixture()

        def checkpoint(event):
            if event["stage"] == "before_release":
                raise RuntimeError("release callback failed")

        loader = BlockLoader(
            model, self.root, manifest, device="cpu", checkpoint=checkpoint
        )
        with self.assertRaisesRegex(LookupError, "body is primary") as caught:
            with loader.resident(0):
                raise LookupError("body is primary")
        self.assertTrue(
            any("release callback failed" in note for note in caught.exception.__notes__)
        )
        self._assert_all_blocks_meta(model)

    def test_manifest_schema_names_shapes_and_precision_are_strict(self):
        mutations = {
            "boolean schema": lambda value: value.update(schemaVersion=True),
            "missing block": lambda value: value["blocks"].pop("29"),
            "wrong prefix": lambda value: value["blocks"]["0"][0].update(
                name="blocks.1.modulation"
            ),
            "path shard": lambda value: value["blocks"]["0"][0].update(
                shard="../part-a.safetensors"
            ),
            "wrong shape": lambda value: value["blocks"]["0"][0].update(shape=[3]),
            "wrong source": lambda value: value["blocks"]["0"][0].update(
                sourceDtype="bfloat16"
            ),
            "wrong target": lambda value: value["blocks"]["0"][0].update(
                targetDtype="bfloat16"
            ),
            "missing parameter": lambda value: value["blocks"]["14"].pop(),
            "duplicate parameter": lambda value: value["blocks"]["29"].append(
                copy.deepcopy(value["blocks"]["29"][0])
            ),
            "unused shard": lambda value: value["shards"].update(
                {"unused.safetensors": copy.deepcopy(value["shards"]["part-a.safetensors"])}
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                model, manifest, _ = self._make_fixture()
                mutate(manifest)
                with self.assertRaises((TypeError, ValueError)):
                    BlockLoader(model, self.root, manifest, device="cpu")

    def test_constructor_rejects_nonmeta_blocks_and_implicit_devices(self):
        model, manifest, _ = self._make_fixture()
        model.blocks[1].proj.weight = torch.nn.Parameter(torch.ones(2, 2))
        with self.assertRaisesRegex(ValueError, "must remain meta"):
            BlockLoader(model, self.root, manifest, device="cpu")
        model, manifest, _ = self._make_fixture()
        for device in (None, "cuda", torch.device("cpu")):
            with self.subTest(device=device):
                with self.assertRaises(ValueError):
                    BlockLoader(model, self.root, manifest, device=device)

    def test_source_dtype_shape_finite_and_missing_tensor_errors_are_explicit(self):
        cases = {
            "dtype": torch.ones(2, dtype=torch.bfloat16),
            "shape": torch.ones(3, dtype=torch.float32),
            "finite": torch.tensor([1.0, float("nan")], dtype=torch.float32),
        }
        name = "blocks.0.modulation"
        for label, replacement in cases.items():
            with self.subTest(label=label):
                model, manifest, _ = self._make_fixture({name: replacement})
                loader = BlockLoader(model, self.root, manifest, device="cpu")
                with self.assertRaisesRegex(ValueError, name):
                    with loader.resident(0):
                        pass
                self._assert_all_blocks_meta(model)

        model, manifest, values = self._make_fixture()
        shard = self.root / "part-a.safetensors"
        save_file(
            {key: value for key, value in values.items() if key != name and key in {
                row["name"]
                for block in manifest["blocks"].values()
                for row in block
                if row["shard"] == "part-a.safetensors"
            }},
            shard,
        )
        manifest["shards"]["part-a.safetensors"] = _identity(shard)
        loader = BlockLoader(model, self.root, manifest, device="cpu")
        with self.assertRaisesRegex(ValueError, "missing"):
            with loader.resident(0):
                pass

    def test_identity_change_and_symbolic_link_poison_the_loader(self):
        model, manifest, _ = self._make_fixture()
        loader = BlockLoader(model, self.root, manifest, device="cpu")
        changed = self.root / "part-a.safetensors"
        changed.write_bytes(changed.read_bytes() + b"changed")
        with self.assertRaisesRegex(RuntimeError, "identity"):
            with loader.resident(0):
                pass
        self._assert_all_blocks_meta(model)
        with self.assertRaises(BlockLoaderPoisonedError):
            with loader.resident(0):
                pass

        model, manifest, _ = self._make_fixture()
        original = self.root / "part-a.safetensors"
        target = self.root / "saved-part-a.safetensors"
        original.rename(target)
        original.symlink_to(target.name)
        loader = BlockLoader(model, self.root, manifest, device="cpu")
        with self.assertRaisesRegex(RuntimeError, "ordinary file"):
            with loader.resident(0):
                pass
        with self.assertRaises(BlockLoaderPoisonedError):
            with loader.resident(0):
                pass

    def test_identity_change_while_resident_cleans_then_poisons(self):
        model, manifest, _ = self._make_fixture()
        loader = BlockLoader(model, self.root, manifest, device="cpu")
        with self.assertRaisesRegex(RuntimeError, "identity"):
            with loader.resident(0):
                path = self.root / "part-a.safetensors"
                path.write_bytes(path.read_bytes() + b"changed")
        self._assert_all_blocks_meta(model)
        with self.assertRaises(BlockLoaderPoisonedError):
            with loader.resident(0):
                pass

    def test_cleanup_synchronization_failure_restores_meta_and_poisons(self):
        model, manifest, _ = self._make_fixture()
        loader = BlockLoader(model, self.root, manifest, device="cpu")
        context = loader.resident(0)
        context.__enter__()
        with mock.patch.object(
            loader, "_synchronize", side_effect=RuntimeError("sync failed")
        ):
            with self.assertRaisesRegex(RuntimeError, "sync failed"):
                context.__exit__(None, None, None)
        self._assert_all_blocks_meta(model)
        with self.assertRaises(BlockLoaderPoisonedError):
            with loader.resident(0):
                pass

    def test_model_root_and_shard_identity_types_are_strict(self):
        model, manifest, _ = self._make_fixture()
        with self.assertRaises(ValueError):
            BlockLoader(model, Path("relative"), manifest, device="cpu")
        for field, invalid in (
            ("device", True),
            ("inode", 0),
            ("size", -1),
            ("mtimeNS", -1),
        ):
            with self.subTest(field=field):
                changed = copy.deepcopy(manifest)
                changed["shards"]["part-a.safetensors"][field] = invalid
                with self.assertRaises(ValueError):
                    BlockLoader(model, self.root, changed, device="cpu")


if __name__ == "__main__":
    unittest.main()
