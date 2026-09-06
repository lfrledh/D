"""Offline tests for the portable downloader; no model, GPU, or network access."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("downloader", Path(__file__).with_name("download_model.py"))
downloader = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(downloader)


class Response(io.BytesIO):
    def __init__(self, data, begin=0, end=None, size=None, status=206, url="https://cdn.hf.co/data"):
        super().__init__(data)
        end = len(data) - 1 if end is None else end
        size = len(data) if size is None else size
        self.status = status
        self.url = url
        self.headers = {"Content-Range": f"bytes {begin}-{end}/{size}"}


class DownloaderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        # macOS exposes its standard temporary directory through the /var symlink.
        self.root = Path(self.temporary.name).resolve()
        self.destination = self.root / "model"
        self.data = b"0123456789"
        self.entry = {"path": "weights/model.safetensors", "size": len(self.data),
                      "sha256": hashlib.sha256(self.data).hexdigest()}
        self.manifest = {"schemaVersion": 1, "repository": "owner/model", "revision": "a" * 40,
                         "files": [self.entry]}
        self.manifest_path = self.root / "manifest.json"
        self.stdout = contextlib.redirect_stdout(io.StringIO())
        self.stdout.__enter__()
        self.addCleanup(self.stdout.__exit__, None, None, None)

    def write_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest))
        return downloader.read_manifest(self.manifest_path)

    def materialize(self, data=None):
        target = self.destination / self.entry["path"]
        target.parent.mkdir(parents=True)
        target.write_bytes(self.data if data is None else data)
        return target

    def test_manifest_accepts_valid_pinned_inventory(self):
        self.assertEqual(self.write_manifest(), self.manifest)

    def test_manifest_rejects_unsafe_paths(self):
        for name in ("", "/tmp/x", "../x", "a/../x", "a//x", "a/./x", "x\\y", ".", "a/", ".d-model-download/x", "a\nx"):
            with self.subTest(name=name):
                self.entry["path"] = name
                with self.assertRaises(ValueError):
                    self.write_manifest()

    def test_manifest_rejects_mutable_revision_or_bad_digest_size(self):
        for key, value in (("revision", "main"), ("schemaVersion", True)):
            original = self.manifest[key]
            self.manifest[key] = value
            with self.assertRaises(ValueError):
                self.write_manifest()
            self.manifest[key] = original
        for key, value in (("size", 0), ("size", True), ("sha256", "z" * 64)):
            original = self.entry[key]
            self.entry[key] = value
            with self.assertRaises(ValueError):
                self.write_manifest()
            self.entry[key] = original

    def test_manifest_rejects_duplicate_or_parent_collision(self):
        for path in (self.entry["path"], "weights"):
            self.manifest["files"] = [self.entry, dict(self.entry, path=path)]
            with self.assertRaises(ValueError):
                self.write_manifest()

    def test_verify_only_is_offline_and_creates_no_state(self):
        self.materialize()
        before = sorted(p.relative_to(self.root).as_posix() for p in self.root.rglob("*"))
        with patch.object(downloader.urllib.request, "build_opener", side_effect=AssertionError("network")):
            downloader.run(self.manifest, self.destination, verify_only=True)
        after = sorted(p.relative_to(self.root).as_posix() for p in self.root.rglob("*"))
        self.assertEqual(before, after)

    def test_verify_only_missing_file_fails_without_creating_destination(self):
        with self.assertRaises(FileNotFoundError):
            downloader.run(self.manifest, self.destination, verify_only=True)
        self.assertFalse(self.destination.exists())

    def test_verify_rejects_wrong_size_and_digest(self):
        target = self.materialize(b"short")
        with self.assertRaises(ValueError):
            downloader.verify_file(target, self.entry)
        target.write_bytes(b"XXXXXXXXXX")
        with self.assertRaises(ValueError):
            downloader.verify_file(target, self.entry)

    def test_symlink_ancestor_or_dangling_entry_rejected(self):
        self.destination.symlink_to(self.root / "missing", target_is_directory=True)
        with self.assertRaises(ValueError):
            downloader.run(self.manifest, self.destination)
        self.destination.unlink()
        self.destination.mkdir()
        (self.destination / "unexpected-link").symlink_to(self.root / "absent")
        with self.assertRaises(ValueError):
            downloader.inspect_destination(self.destination, self.manifest)

    def test_unlisted_safetensors_rejected_before_network(self):
        self.materialize()
        (self.destination / "extra.SAFETENSORS").write_bytes(b"extra")
        with self.assertRaises(ValueError):
            downloader.run(self.manifest, self.destination)

    def test_unlisted_tokenizer_or_config_inputs_rejected(self):
        self.materialize()
        for name in ("extra.json", "vocab.txt", "tokenizer.model"):
            with self.subTest(name=name):
                extra = self.destination / name
                extra.write_bytes(b"extra")
                with self.assertRaises(ValueError):
                    downloader.run(self.manifest, self.destination, verify_only=True)
                extra.unlink()

    def test_unrecognized_state_file_rejected(self):
        self.materialize()
        state = self.destination / downloader.STATE
        state.mkdir()
        (state / "unlisted.json").write_text("{}")
        with self.assertRaises(ValueError):
            downloader.run(self.manifest, self.destination, verify_only=True)

    def test_exact_range_status_total_encoding_and_https_required(self):
        variants = [Response(self.data, status=200), Response(self.data, size=11),
                    Response(self.data, begin=1), Response(self.data, url="http://cdn.hf.co/data")]
        encoded = Response(self.data)
        encoded.headers["Content-Encoding"] = "gzip"
        variants.append(encoded)
        wrong_length = Response(self.data)
        wrong_length.headers["Content-Length"] = "9"
        variants.append(wrong_length)
        for response in variants:
            with self.subTest(response=response.headers):
                with self.assertRaises(ValueError):
                    downloader.content_range(response, 0, 9, 10)

    def test_resume_requests_only_remaining_exact_bytes(self):
        directory = self.root / "segments"
        directory.mkdir()
        (directory / "0-9.part").write_bytes(self.data[:4])
        with patch.object(downloader.urllib.request, "build_opener") as build:
            opener = build.return_value
            opener.open.return_value = Response(self.data[4:], begin=4, end=9, size=10)
            count = downloader.download_segment(self.manifest, self.entry, directory, 0, 9)
            request = opener.open.call_args.args[0]
            self.assertEqual(request.get_header("Range"), "bytes=4-9")
            self.assertIn(self.manifest["revision"], request.full_url)
        self.assertEqual(count, 6)
        self.assertEqual((directory / "0-9.range").read_bytes(), self.data)

    def test_complete_segment_reused_without_network(self):
        directory = self.root / "segments"
        directory.mkdir()
        (directory / "0-9.range").write_bytes(self.data)
        with patch.object(downloader.urllib.request, "build_opener", side_effect=AssertionError("network")):
            self.assertEqual(downloader.download_segment(self.manifest, self.entry, directory, 0, 9), 0)

    def test_incomplete_response_resumes_saved_prefix(self):
        directory = self.root / "segments"
        directory.mkdir()
        with patch.object(downloader.urllib.request, "build_opener") as build, patch.object(downloader.time, "sleep"):
            opener = build.return_value
            opener.open.side_effect = [Response(self.data[:3], end=9, size=10),
                                       Response(self.data[3:], begin=3, end=9, size=10)]
            self.assertEqual(downloader.download_segment(self.manifest, self.entry, directory, 0, 9), 10)
            self.assertEqual(opener.open.call_args_list[1].args[0].get_header("Range"), "bytes=3-9")
        self.assertEqual((directory / "0-9.range").read_bytes(), self.data)

    def test_excess_response_fails_before_publication(self):
        directory = self.root / "segments"
        directory.mkdir()
        with patch.object(downloader.urllib.request, "build_opener") as build:
            build.return_value.open.return_value = Response(self.data + b"x", end=9, size=10)
            with self.assertRaises(ValueError):
                downloader.download_segment(self.manifest, self.entry, directory, 0, 9)
        self.assertFalse((directory / "0-9.range").exists())

    def test_full_digest_required_before_atomic_publication(self):
        directory = self.root / "segments"
        directory.mkdir()
        (directory / "0-9.range").write_bytes(b"XXXXXXXXXX")
        with self.assertRaises(ValueError):
            downloader.assemble(self.destination, self.entry, directory, [(0, 9)])
        self.assertFalse((self.destination / self.entry["path"]).exists())
        self.assertTrue((directory / "0-9.range").exists())

    def test_segmented_download_publishes_exact_file(self):
        def respond(request, timeout):
            start, end = map(int, request.get_header("Range").removeprefix("bytes=").split("-"))
            return Response(self.data[start:end + 1], start, end, len(self.data))
        with patch.object(downloader, "SEGMENT", 4), patch.object(downloader.urllib.request, "build_opener") as build:
            build.return_value.open.side_effect = respond
            downloader.run(self.manifest, self.destination, connections=4)
        self.assertEqual((self.destination / self.entry["path"]).read_bytes(), self.data)
        self.assertFalse(list((self.destination / downloader.STATE).rglob("*.part")))

    def test_same_digest_different_paths_have_independent_state(self):
        self.manifest["files"].append(dict(self.entry, path="other/model.safetensors"))
        with patch.object(downloader.urllib.request, "build_opener") as build:
            build.return_value.open.side_effect = lambda *a, **k: Response(self.data)
            downloader.run(self.manifest, self.destination)
        for entry in self.manifest["files"]:
            self.assertEqual((self.destination / entry["path"]).read_bytes(), self.data)

    def test_keyboard_interrupt_cancels_all_queued_jobs_and_signals_running_jobs(self):
        submitted = []
        events = []
        class Executor:
            def __init__(self, max_workers):
                self.max_workers = max_workers
                self.shutdown_args = None

            def submit(self, function, *args):
                future = downloader.concurrent.futures.Future()
                submitted.append(future)
                events.append(args[-1])
                return future

            def shutdown(self, **kwargs):
                self.shutdown_args = kwargs

        executor = Executor(4)
        with patch.object(downloader, "SEGMENT", 1), patch.object(
                downloader.concurrent.futures, "ThreadPoolExecutor", return_value=executor), patch.object(
                downloader.concurrent.futures, "wait", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                downloader.run(self.manifest, self.destination)
        self.assertEqual(len(submitted), 10)
        self.assertTrue(all(future.cancelled() for future in submitted))
        self.assertTrue(all(event.is_set() for event in events))
        self.assertEqual(executor.shutdown_args, {"wait": True, "cancel_futures": True})

    def test_running_transfer_observes_cancel_at_read_boundary(self):
        directory = self.root / "segments"
        directory.mkdir()
        cancel = threading.Event()
        class CancellingResponse(Response):
            def read(self, count):
                data = super().read(count)
                cancel.set()
                return data
        with patch.object(downloader.urllib.request, "build_opener") as build:
            build.return_value.open.return_value = CancellingResponse(self.data)
            with self.assertRaises(downloader.concurrent.futures.CancelledError):
                downloader.download_segment(self.manifest, self.entry, directory, 0, 9, cancel)
        self.assertFalse((directory / "0-9.range").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
