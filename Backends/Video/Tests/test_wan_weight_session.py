"""CPU fixtures for the schema-v2 Wan streaming weight session.

The fixtures use only tiny synthetic safetensors under D_TEST_TEMP_DIR.  They
never locate or read the real model; Lead owns execution of this test module.
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

import d_video_wan_weights as weights
from d_video_wan_weights import (
    StreamingWeights,
    WeightLoadCancelled,
    WeightSessionPoisonedError,
)


class _TinyBlock(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.modulation = torch.nn.Parameter(torch.empty(2, device="meta"))
        self.norm1 = torch.nn.Linear(2, 2, bias=False, device="meta")
        self.proj = torch.nn.Linear(2, 2, bias=False, device="meta")

    def forward(self, value):
        return (
            value.float()
            + self.modulation.float().sum()
            + self.norm1.weight.float().sum()
            + self.proj.weight.float().sum()
        )


class _TinyModel(torch.nn.Module):
    def __init__(self, block_count=3):
        super().__init__()
        self.time_embedding = torch.nn.Linear(2, 2, bias=False, device="meta")
        self.shared_proj = torch.nn.Linear(2, 2, bias=False, device="meta")
        self.blocks = torch.nn.ModuleList([_TinyBlock() for _ in range(block_count)])
        self.head = torch.nn.Linear(2, 2, bias=False, device="meta")
        self.mode = "normal"
        self.fail_head = False

    def forward(self, value):
        value = (
            value.float()
            + self.time_embedding.weight.float().sum()
            + self.shared_proj.weight.float().sum()
        )
        if self.mode == "omit":
            sequence = (self.blocks[0], self.blocks[2])
        elif self.mode == "duplicate":
            sequence = (self.blocks[0], self.blocks[0], *self.blocks[1:])
        else:
            sequence = self.blocks
        for block in sequence:
            value = block(value)
        if self.fail_head:
            raise LookupError("head failed")
        return value + self.head.weight.float().sum()


def _identity(path: Path) -> dict[str, int]:
    value = os.stat(path, follow_symlinks=False)
    return {
        "device": value.st_dev,
        "inode": value.st_ino,
        "size": value.st_size,
        "mtimeNS": value.st_mtime_ns,
    }


def _target_dtype(name: str) -> str:
    if name.startswith(("time_embedding.", "time_projection.", "head.")):
        return "float32"
    if name.endswith(".modulation") or any(
        part.startswith("norm") for part in name.split(".")
    ):
        return "float32"
    return "bfloat16"


class WanWeightSessionTests(unittest.TestCase):
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
            prefix="wan-weight-session-", dir=str(self.fixture_root)
        )
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve(strict=True)

    def _fixture(self, replacements=None, block_count=3):
        replacements = dict(replacements or {})
        model = _TinyModel(block_count)
        values = {}
        shard_values = {"part-a.safetensors": {}, "part-b.safetensors": {}}
        shared = []
        blocks = {str(index): [] for index in range(block_count)}
        sequence = 1
        for position, (name, parameter) in enumerate(
            model.named_parameters(recurse=True)
        ):
            value = torch.arange(
                sequence, sequence + parameter.numel(), dtype=torch.float32
            ).reshape(parameter.shape)
            sequence += parameter.numel() + 3
            value = replacements.get(name, value)
            values[name] = value
            shard = "part-a.safetensors" if position % 2 == 0 else "part-b.safetensors"
            shard_values[shard][name] = value
            record = {
                "name": name,
                "shard": shard,
                "shape": list(parameter.shape),
                "sourceDtype": "float32",
                "targetDtype": _target_dtype(name),
            }
            if name.startswith("blocks."):
                blocks[name.split(".")[1]].append(record)
            else:
                shared.append(record)
        for shard, tensors in shard_values.items():
            save_file(tensors, self.root / shard)
        manifest = {
            "schemaVersion": 2,
            "blocks": blocks,
            "shared": shared,
            "shards": {
                shard: _identity(self.root / shard) for shard in sorted(shard_values)
            },
        }
        return model, manifest, values

    def _assert_all_meta(self, model):
        for parameter in model.parameters():
            self.assertEqual(parameter.device.type, "meta")

    def _assert_shared_resident(self, model):
        for name, parameter in model.named_parameters():
            expected = "meta" if name.startswith("blocks.") else "cpu"
            self.assertEqual(parameter.device.type, expected, name)

    def _expected_output(self, input_value, values):
        result = input_value.float().clone()
        for name, value in values.items():
            dtype = torch.float32 if _target_dtype(name) == "float32" else torch.bfloat16
            result = result + value.to(dtype=dtype).float().sum()
        return result

    def test_constructor_is_metadata_only_and_freezes_manifest(self):
        model, manifest, _ = self._fixture()
        with mock.patch.object(
            weights, "safe_open", side_effect=AssertionError("unexpected tensor read")
        ) as opened:
            owner = StreamingWeights(model, self.root, manifest, device="cpu")
        opened.assert_not_called()
        manifest["shared"][0]["shape"][0] = 99
        manifest["blocks"]["0"][0]["name"] = "changed"
        with owner.session():
            self._assert_shared_resident(model)
        self._assert_all_meta(model)

    def test_session_and_cross_shard_resident_lease_restore_exactly(self):
        model, manifest, values = self._fixture()
        owner = StreamingWeights(model, self.root, manifest, device="cpu")
        with owner.session() as returned:
            self.assertIs(returned, model)
            self._assert_shared_resident(model)
            for index in (0, 1, 2, 0):
                with owner.resident(index) as block:
                    for relative, parameter in block.named_parameters():
                        name = f"blocks.{index}.{relative}"
                        dtype = (
                            torch.float32
                            if _target_dtype(name) == "float32"
                            else torch.bfloat16
                        )
                        self.assertEqual(parameter.dtype, dtype)
                        torch.testing.assert_close(
                            parameter.detach(), values[name].to(dtype=dtype), rtol=0, atol=0
                        )
                self._assert_shared_resident(model)
        self._assert_all_meta(model)
        statistics = dict(owner.statistics)
        self.assertEqual(statistics["sessions"], 1)
        self.assertEqual(statistics["leases"], 4)
        self.assertGreater(statistics["logicalBytes"], 0)

    def test_forward_streams_in_order_restores_compact_wrapper_and_is_exact(self):
        model, manifest, values = self._fixture()
        saved = model.blocks[1].forward

        def compact_wrapper(*args, **kwargs):
            return saved(*args, **kwargs)

        model.blocks[1].forward = compact_wrapper
        events = []

        def checkpoint(event):
            events.append(dict(event))
            with self.assertRaises(TypeError):
                event["changed"] = 1

        owner = StreamingWeights(
            model, self.root, manifest, device="cpu", checkpoint=checkpoint
        )
        input_value = torch.tensor([0.25])
        with owner.session():
            actual = owner.forward(input_value)
            torch.testing.assert_close(
                actual, self._expected_output(input_value, values), rtol=0, atol=0
            )
            self._assert_shared_resident(model)
        self.assertIs(model.blocks[1].__dict__["forward"], compact_wrapper)
        self.assertNotIn("forward", model.blocks[0].__dict__)
        self.assertNotIn("forward", model.blocks[2].__dict__)
        forward_events = [event for event in events if event["stage"] == "before_forward"]
        self.assertEqual([event["block"] for event in forward_events], [0, 1, 2])
        self.assertTrue(
            {
                "before_load",
                "after_read",
                "before_install",
                "after_install",
                "ready",
                "before_release",
                "released",
            }.issubset({event["stage"] for event in events})
        )
        self.assertTrue(
            all(
                all(isinstance(value, (str, int, float)) for value in event.values())
                for event in events
            )
        )

    def test_checkpoint_cancellation_cleans_shared_and_block_then_retries(self):
        cases = (
            ("shared", "after_read"),
            ("shared", "ready"),
            ("block", "after_install"),
            ("block", "before_release"),
            ("block", "released"),
        )
        for group, stage in cases:
            with self.subTest(group=group, stage=stage):
                model, manifest, _ = self._fixture()
                state = {"cancelled": False}

                def checkpoint(event):
                    if (
                        event["group"] == group
                        and event["stage"] == stage
                        and not state["cancelled"]
                    ):
                        state["cancelled"] = True
                        raise WeightLoadCancelled(f"{group}-{stage}")

                owner = StreamingWeights(
                    model, self.root, manifest, device="cpu", checkpoint=checkpoint
                )
                if group == "shared":
                    with self.assertRaisesRegex(WeightLoadCancelled, stage):
                        with owner.session():
                            pass
                    self._assert_all_meta(model)
                    with owner.session():
                        pass
                else:
                    with owner.session():
                        with self.assertRaisesRegex(WeightLoadCancelled, stage):
                            with owner.resident(1):
                                pass
                        self._assert_shared_resident(model)
                        with owner.resident(1):
                            pass
                self._assert_all_meta(model)

    def test_cross_shard_block_cancellation_restores_and_retries(self):
        model, manifest, _ = self._fixture()
        block_records = manifest["blocks"]["1"]
        first_shard = block_records[0]["shard"]
        cancelled_name = next(
            record["name"] for record in block_records if record["shard"] != first_shard
        )
        state = {"cancelled": False}

        def checkpoint(event):
            if (
                event["stage"] == "after_read"
                and event.get("name") == cancelled_name
                and not state["cancelled"]
            ):
                state["cancelled"] = True
                raise WeightLoadCancelled("cross-shard cancellation")

        owner = StreamingWeights(
            model, self.root, manifest, device="cpu", checkpoint=checkpoint
        )
        with owner.session():
            with self.assertRaisesRegex(WeightLoadCancelled, "cross-shard"):
                with owner.resident(1):
                    pass
            self._assert_shared_resident(model)
            with owner.resident(1):
                pass
        self._assert_all_meta(model)

    def test_forward_body_and_head_failures_cleanup_and_allow_retry(self):
        model, manifest, _ = self._fixture()
        original = model.blocks[1].forward
        calls = {"failed": False}

        def fail_once(*args, **kwargs):
            if not calls["failed"]:
                calls["failed"] = True
                raise LookupError("body failed")
            return original(*args, **kwargs)

        model.blocks[1].forward = fail_once
        owner = StreamingWeights(model, self.root, manifest, device="cpu")
        with owner.session():
            with self.assertRaisesRegex(LookupError, "body failed"):
                owner.forward(torch.zeros(1))
            self._assert_shared_resident(model)
            owner.forward(torch.zeros(1))
            model.fail_head = True
            with self.assertRaisesRegex(LookupError, "head failed"):
                owner.forward(torch.zeros(1))
            self._assert_shared_resident(model)
            model.fail_head = False
            owner.forward(torch.zeros(1))
        self.assertIs(model.blocks[1].__dict__["forward"], fail_once)
        self._assert_all_meta(model)

    def test_omitted_and_duplicate_block_order_are_rejected_without_residue(self):
        for mode in ("omit", "duplicate"):
            with self.subTest(mode=mode):
                model, manifest, _ = self._fixture()
                model.mode = mode
                owner = StreamingWeights(model, self.root, manifest, device="cpu")
                with owner.session():
                    with self.assertRaisesRegex(RuntimeError, "block"):
                        owner.forward(torch.zeros(1))
                    self._assert_shared_resident(model)
                    self.assertTrue(
                        all("forward" not in block.__dict__ for block in model.blocks)
                    )
                    model.mode = "normal"
                    owner.forward(torch.zeros(1))

    def test_partial_install_failure_restores_and_allows_retry(self):
        model, manifest, _ = self._fixture()
        owner = StreamingWeights(model, self.root, manifest, device="cpu")
        original = owner._install
        calls = {"count": 0}

        def failing_install(*args, **kwargs):
            calls["count"] += 1
            if calls["count"] == 2:
                raise RuntimeError("install failed")
            return original(*args, **kwargs)

        with mock.patch.object(owner, "_install", side_effect=failing_install):
            with self.assertRaisesRegex(RuntimeError, "install failed"):
                with owner.session():
                    pass
        self._assert_all_meta(model)
        with owner.session():
            pass

    def test_synchronization_failure_poisons_but_close_releases_owner(self):
        model, manifest, _ = self._fixture()
        owner = StreamingWeights(model, self.root, manifest, device="cpu")
        with mock.patch.object(
            owner, "_synchronize", side_effect=(RuntimeError("sync failed"), None)
        ):
            with self.assertRaisesRegex(RuntimeError, "sync failed"):
                with owner.session():
                    pass
        self._assert_all_meta(model)
        with self.assertRaises(WeightSessionPoisonedError):
            with owner.session():
                pass
        owner.close()
        replacement = StreamingWeights(model, self.root, manifest, device="cpu")
        replacement.close()

    def test_close_reentry_active_lease_and_double_owner_are_rejected(self):
        model, manifest, _ = self._fixture()
        owner = StreamingWeights(model, self.root, manifest, device="cpu")
        with self.assertRaisesRegex(RuntimeError, "already has"):
            StreamingWeights(model, self.root, manifest, device="cpu")
        with owner.session():
            with self.assertRaises(RuntimeError):
                with owner.session():
                    pass
            with self.assertRaises(RuntimeError):
                owner.close()
            with owner.resident(0):
                with self.assertRaises(RuntimeError):
                    with owner.resident(1):
                        pass
                with self.assertRaises(RuntimeError):
                    owner.forward(torch.zeros(1))
        owner.close()
        owner.close()
        with self.assertRaises(RuntimeError):
            with owner.session():
                pass

    def test_manifest_schema_coverage_precision_and_names_are_strict(self):
        mutations = {
            "boolean schema": lambda value: value.update(schemaVersion=True),
            "extra field": lambda value: value.update(extra=1),
            "missing block": lambda value: value["blocks"].pop("2"),
            "shared block": lambda value: value["shared"][0].update(
                name=value["blocks"]["0"][0]["name"]
            ),
            "unknown name": lambda value: value["shared"][0].update(name="unknown.weight"),
            "path shard": lambda value: value["shared"][0].update(shard="../part-a.safetensors"),
            "wrong shape": lambda value: value["blocks"]["0"][0].update(shape=[99]),
            "wrong source": lambda value: value["blocks"]["0"][0].update(
                sourceDtype="bfloat16"
            ),
            "wrong target": lambda value: value["blocks"]["0"][0].update(
                targetDtype="bfloat16"
                if value["blocks"]["0"][0]["targetDtype"] == "float32"
                else "float32"
            ),
            "missing parameter": lambda value: value["blocks"]["1"].pop(),
            "duplicate": lambda value: value["blocks"]["2"].append(
                copy.deepcopy(value["blocks"]["2"][0])
            ),
        }
        for label, mutation in mutations.items():
            with self.subTest(label=label):
                model, manifest, _ = self._fixture()
                mutation(manifest)
                with self.assertRaises((TypeError, ValueError)):
                    StreamingWeights(model, self.root, manifest, device="cpu")

    def test_source_dtype_shape_finite_and_missing_tensor_fail_explicitly(self):
        name = "blocks.0.modulation"
        cases = {
            "dtype": torch.ones(2, dtype=torch.bfloat16),
            "shape": torch.ones(3, dtype=torch.float32),
            "finite": torch.tensor([1.0, float("nan")], dtype=torch.float32),
        }
        for label, replacement in cases.items():
            with self.subTest(label=label):
                model, manifest, _ = self._fixture({name: replacement})
                owner = StreamingWeights(model, self.root, manifest, device="cpu")
                with owner.session():
                    with self.assertRaisesRegex(ValueError, name):
                        with owner.resident(0):
                            pass
                    self._assert_shared_resident(model)

        model, manifest, _ = self._fixture()
        shard = manifest["blocks"]["0"][0]["shard"]
        tensor_name = manifest["blocks"]["0"][0]["name"]
        kept = {}
        for record in manifest["shared"] + sum(manifest["blocks"].values(), []):
            if record["shard"] == shard and record["name"] != tensor_name:
                kept[record["name"]] = torch.ones(record["shape"], dtype=torch.float32)
        save_file(kept, self.root / shard)
        manifest["shards"][shard] = _identity(self.root / shard)
        owner = StreamingWeights(model, self.root, manifest, device="cpu")
        with self.assertRaisesRegex(ValueError, "missing"):
            with owner.session():
                with owner.resident(0):
                    pass

    def test_shard_identity_change_poisons_and_protects_input(self):
        model, manifest, _ = self._fixture()
        owner = StreamingWeights(model, self.root, manifest, device="cpu")
        changed = self.root / "part-a.safetensors"
        stat_value = changed.stat()
        os.utime(changed, ns=(stat_value.st_atime_ns, stat_value.st_mtime_ns + 1))
        with self.assertRaisesRegex(RuntimeError, "identity differs"):
            with owner.session():
                pass
        self._assert_all_meta(model)
        with self.assertRaises(WeightSessionPoisonedError):
            with owner.session():
                pass

    def test_resident_parameters_are_weakly_released(self):
        model, manifest, _ = self._fixture()
        owner = StreamingWeights(model, self.root, manifest, device="cpu")
        with owner.session():
            with owner.resident(1) as block:
                reference = weakref.ref(block.proj.weight)
            gc.collect()
            self.assertIsNone(reference())
            self._assert_shared_resident(model)
        self._assert_all_meta(model)

    def test_constructor_rejects_nonmeta_aliases_implicit_devices_and_bad_roots(self):
        model, manifest, _ = self._fixture()
        model.blocks[0].proj.weight = torch.nn.Parameter(torch.ones(2, 2))
        with self.assertRaisesRegex(ValueError, "must be meta"):
            StreamingWeights(model, self.root, manifest, device="cpu")

        for device in (None, "cuda", torch.device("cpu")):
            with self.subTest(device=device):
                model, manifest, _ = self._fixture()
                with self.assertRaises(ValueError):
                    StreamingWeights(model, self.root, manifest, device=device)

        model, manifest, _ = self._fixture()
        model.alias = model.shared_proj
        with self.assertRaisesRegex(ValueError, "aliased"):
            StreamingWeights(model, self.root, manifest, device="cpu")
        model, manifest, _ = self._fixture()
        with self.assertRaises(ValueError):
            StreamingWeights(model, Path("relative"), manifest, device="cpu")


if __name__ == "__main__":
    unittest.main()
