"""CPU-only ACCESS1 fixtures using synthetic bookmarks and CoreFoundation fakes."""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import sys
import tempfile
import tokenize
import unittest
from unittest import mock


PYTHON_DIR = Path(__file__).resolve().parents[1] / "Python"
sys.path.insert(0, str(PYTHON_DIR))

import d_audio_access as access


TASK_TMP = Path(os.environ["D_TEST_TEMP_DIR"])
RUN_ID = "12345678-1234-4234-9234-123456789abc"


class FakeAdapter:
    def __init__(self, outcomes):
        self.outcomes = list(outcomes)
        self.events = []
        self.index = 0

    def resolve(self, bookmark):
        outcome = self.outcomes[self.index]
        index = self.index
        self.index += 1
        self.events.append(("resolve", index))
        if outcome.get("resolve_error"):
            raise RuntimeError("private resolver detail")
        return f"url-{index}", outcome["path"]

    def start(self, url):
        index = int(url.split("-")[1])
        self.events.append(("start", index))
        if self.outcomes[index].get("start_error"):
            raise RuntimeError("private start detail")
        return self.outcomes[index].get("start", True)

    def stop(self, url):
        index = int(url.split("-")[1])
        self.events.append(("stop", index))
        if self.outcomes[index].get("stop_error"):
            raise RuntimeError("private stop detail")

    def release_url(self, url):
        if url is None:
            raise AssertionError("release received NULL")
        index = int(url.split("-")[1])
        self.events.append(("release", index))
        if self.outcomes[index].get("release_error"):
            raise RuntimeError("private release detail")


class FakeFunction:
    def __init__(self, implementation):
        self.implementation = implementation
        self.argtypes = None
        self.restype = None

    def __call__(self, *args):
        return self.implementation(*args)


class FakeCFLibrary:
    def __init__(self, *, data=10, url=20, error=0, stale=False, path="/tmp/grant"):
        self.data = data
        self.url = url
        self.error = error
        self.stale = stale
        self.path = path
        self.released = []
        self.options = None
        self.started = []
        self.stopped = []
        self.CFDataCreate = FakeFunction(self._data_create)
        self.CFURLCreateByResolvingBookmarkData = FakeFunction(self._resolve)
        self.CFURLGetFileSystemRepresentation = FakeFunction(self._path)
        self.CFURLStartAccessingSecurityScopedResource = FakeFunction(self._start)
        self.CFURLStopAccessingSecurityScopedResource = FakeFunction(self._stop)
        self.CFRelease = FakeFunction(self._release)

    def _data_create(self, _allocator, _payload, _length):
        return self.data

    def _resolve(self, _allocator, _data, options, _relative, _properties, stale, error):
        self.options = options
        stale._obj.value = int(self.stale)
        error._obj.value = self.error
        return self.url

    def _path(self, _url, _resolve_base, buffer, size):
        encoded = self.path.encode("utf-8") + b"\0"
        if len(encoded) > size:
            return 0
        for index, byte in enumerate(encoded):
            buffer[index] = byte
        return 1

    def _start(self, url):
        self.started.append(url)
        return 1

    def _stop(self, url):
        self.stopped.append(url)

    def _release(self, reference):
        if not reference:
            raise AssertionError("CFRelease received NULL")
        self.released.append(reference)


class AudioAccessTests(unittest.TestCase):
    def setUp(self):
        if not TASK_TMP.is_dir():
            self.fail("D_TEST_TEMP_DIR must name an existing authorized directory")
        self.temporary = tempfile.TemporaryDirectory(dir=TASK_TMP)
        self.root = Path(self.temporary.name)
        self.first = self.root / "model 音楽"
        self.second = self.root / "run output"
        self.first.mkdir()
        self.second.mkdir()
        self.manifest = self.root / "access.json"

    def tearDown(self):
        self.temporary.cleanup()

    def manifest_value(self, paths=None):
        if paths is None:
            paths = [self.first, self.second]
        return {
            "schemaVersion": 1,
            "runID": RUN_ID,
            "grants": [
                {
                    "path": str(path),
                    "bookmark": base64.b64encode(f"capability-{index}".encode()).decode(),
                }
                for index, path in enumerate(paths)
            ],
        }

    def write_manifest(self, value=None, *, raw=None, mode=0o600):
        if raw is None:
            raw = json.dumps(value if value is not None else self.manifest_value()).encode("utf-8")
        self.manifest.write_bytes(raw)
        self.manifest.chmod(mode)
        return self.manifest

    def acquire(self, fake, *, paths=None, run_id=RUN_ID, manifest=None):
        paths = [self.first, self.second] if paths is None else paths
        manifest = self.manifest if manifest is None else manifest
        return mock.patch.object(access, "_make_cf_adapter", return_value=fake), access.acquire_file_access(
            manifest, run_id=run_id, allowed_paths=paths
        )

    def assert_manifest_rejected(self, *, value=None, raw=None, paths=None, run_id=RUN_ID):
        self.write_manifest(value, raw=raw)
        with mock.patch.object(access, "_make_cf_adapter") as factory:
            with self.assertRaises(access.AudioAccessError) as raised:
                with access.acquire_file_access(
                    self.manifest,
                    run_id=run_id,
                    allowed_paths=[self.first, self.second] if paths is None else paths,
                ):
                    self.fail("invalid manifest entered its body")
        factory.assert_not_called()
        return str(raised.exception)

    def test_syntax_is_compiled_in_memory_without_importing_target(self):
        target = PYTHON_DIR / "d_audio_access.py"
        with tokenize.open(target) as handle:
            source = handle.read()
        compile(source, str(target), "exec", dont_inherit=True)

    def test_two_grants_enter_and_exit_in_reverse_order_without_directory_writes(self):
        self.write_manifest()
        before = (list(self.first.iterdir()), list(self.second.iterdir()))
        fake = FakeAdapter([
            {"path": str(self.first), "start": True},
            {"path": str(self.second), "start": True},
        ])
        patcher, context = self.acquire(fake)
        with patcher, context:
            self.assertEqual(fake.events, [
                ("resolve", 0), ("start", 0), ("resolve", 1), ("start", 1)
            ])
        self.assertEqual(fake.events[-4:], [
            ("stop", 1), ("release", 1), ("stop", 0), ("release", 0)
        ])
        self.assertEqual(before, (list(self.first.iterdir()), list(self.second.iterdir())))

    def test_body_exception_is_preserved_and_all_access_is_balanced(self):
        self.write_manifest()
        fake = FakeAdapter([
            {"path": str(self.first)}, {"path": str(self.second)}
        ])
        marker = RuntimeError("user body marker")
        patcher, context = self.acquire(fake)
        with self.assertRaises(RuntimeError) as raised:
            with patcher, context:
                raise marker
        self.assertIs(raised.exception, marker)
        self.assertEqual(fake.events[-4:], [
            ("stop", 1), ("release", 1), ("stop", 0), ("release", 0)
        ])

    def test_cleanup_failures_do_not_skip_references_or_replace_body_exception(self):
        self.write_manifest()
        fake = FakeAdapter([
            {"path": str(self.first), "stop_error": True},
            {"path": str(self.second), "release_error": True},
        ])
        marker = RuntimeError("user body marker")
        with mock.patch.object(access, "_make_cf_adapter", return_value=fake):
            with self.assertRaises(RuntimeError) as raised:
                with access.acquire_file_access(
                    self.manifest, run_id=RUN_ID, allowed_paths=[self.first, self.second]
                ):
                    raise marker
        self.assertIs(raised.exception, marker)
        self.assertEqual(fake.events[-4:], [
            ("stop", 1), ("release", 1), ("stop", 0), ("release", 0)
        ])

        fake = FakeAdapter([
            {"path": str(self.first), "stop_error": True},
            {"path": str(self.second), "release_error": True},
        ])
        with mock.patch.object(access, "_make_cf_adapter", return_value=fake):
            with self.assertRaisesRegex(access.AudioAccessError, "cleanup"):
                with access.acquire_file_access(
                    self.manifest, run_id=RUN_ID, allowed_paths=[self.first, self.second]
                ):
                    pass
        self.assertEqual(fake.events[-4:], [
            ("stop", 1), ("release", 1), ("stop", 0), ("release", 0)
        ])

    def test_false_start_is_accepted_only_when_exact_directory_is_readable(self):
        value = self.manifest_value([self.first])
        self.write_manifest(value)
        fake = FakeAdapter([{"path": str(self.first), "start": False}])
        with mock.patch.object(access, "_make_cf_adapter", return_value=fake):
            with access.acquire_file_access(self.manifest, run_id=RUN_ID, allowed_paths=[self.first]):
                pass
        self.assertEqual(fake.events, [("resolve", 0), ("start", 0), ("release", 0)])

        missing = self.root / "missing"
        self.write_manifest(self.manifest_value([missing]))
        fake = FakeAdapter([{"path": str(missing), "start": False}])
        with mock.patch.object(access, "_make_cf_adapter", return_value=fake):
            with self.assertRaisesRegex(access.AudioAccessError, "not readable"):
                with access.acquire_file_access(self.manifest, run_id=RUN_ID, allowed_paths=[missing]):
                    pass
        self.assertEqual(fake.events, [("resolve", 0), ("start", 0), ("release", 0)])

    def test_second_grant_failures_clean_current_and_first_grant(self):
        cases = [
            ("resolve", {"path": str(self.second), "resolve_error": True},
             [("resolve", 0), ("start", 0), ("resolve", 1), ("stop", 0), ("release", 0)]),
            ("path", {"path": str(self.first)},
             [("resolve", 1), ("release", 1), ("stop", 0), ("release", 0)]),
            ("start", {"path": str(self.second), "start_error": True},
             [("resolve", 1), ("start", 1), ("release", 1), ("stop", 0), ("release", 0)]),
        ]
        for label, second, suffix in cases:
            with self.subTest(label=label):
                self.write_manifest()
                fake = FakeAdapter([{"path": str(self.first)}, second])
                with mock.patch.object(access, "_make_cf_adapter", return_value=fake):
                    with self.assertRaises(access.AudioAccessError) as raised:
                        with access.acquire_file_access(
                            self.manifest, run_id=RUN_ID, allowed_paths=[self.first, self.second]
                        ):
                            pass
                self.assertEqual(fake.events[-len(suffix):], suffix)
                self.assertNotIn("private", str(raised.exception))

        missing = self.root / "unreadable"
        self.write_manifest(self.manifest_value([self.first, missing]))
        fake = FakeAdapter([{"path": str(self.first)}, {"path": str(missing)}])
        with mock.patch.object(access, "_make_cf_adapter", return_value=fake):
            with self.assertRaises(access.AudioAccessError):
                with access.acquire_file_access(
                    self.manifest, run_id=RUN_ID, allowed_paths=[self.first, missing]
                ):
                    pass
        self.assertEqual(fake.events[-4:], [
            ("stop", 1), ("release", 1), ("stop", 0), ("release", 0)
        ])

    def test_json_schema_version_run_and_grant_shape_are_strict(self):
        raw_cases = [
            b"[]",
            b'{"schemaVersion":1,"schemaVersion":1,"runID":"x","grants":[]}',
            b'{"schemaVersion":NaN,"runID":"x","grants":[]}',
            b"\xff",
            b"{",
        ]
        for raw in raw_cases:
            with self.subTest(raw=raw):
                self.assert_manifest_rejected(raw=raw)

        mutations = []
        value = self.manifest_value()
        mutations.append({**value, "schemaVersion": True})
        mutations.append({**value, "schemaVersion": 1.0})
        mutations.append({**value, "unknown": 1})
        mutations.append({**value, "runID": "not-a-uuid"})
        mutations.append({**value, "runID": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"})
        mutations.append({**value, "grants": []})
        mutations.append({**value, "grants": value["grants"] * 3})
        mutations.append({**value, "grants": [1]})
        mutations.append({**value, "grants": [{**value["grants"][0], "extra": 1}]})
        for index, mutation in enumerate(mutations):
            with self.subTest(mutation=index):
                self.assert_manifest_rejected(value=mutation)

    def test_path_allowlist_and_unicode_rules_are_strict(self):
        value = self.manifest_value()
        duplicate = {**value, "grants": [value["grants"][0], value["grants"][0]]}
        self.assert_manifest_rejected(value=duplicate)
        self.assert_manifest_rejected(value=value, paths=[self.first])
        self.assert_manifest_rejected(value=value, paths=[self.first, self.first])
        for invalid in ("relative", "/", "/tmp/../escape", "/tmp//double", "file:///tmp/x", "/tmp/x\x00y"):
            changed = self.manifest_value()
            changed["grants"][0]["path"] = invalid
            with self.subTest(invalid=invalid):
                self.assert_manifest_rejected(value=changed)

        self.write_manifest(value)
        fake = FakeAdapter([{"path": str(self.first)}, {"path": str(self.second)}])
        with mock.patch.object(access, "_make_cf_adapter", return_value=fake):
            with access.acquire_file_access(
                self.manifest, run_id=RUN_ID.upper(), allowed_paths=[self.second, self.first]
            ):
                pass

    def test_bookmark_base64_size_and_secret_redaction(self):
        value = self.manifest_value()
        secrets = ("", "not base64!", base64.b64encode(b"x" * (16 * 1024 + 1)).decode())
        for secret in secrets:
            changed = json.loads(json.dumps(value))
            changed["grants"][0]["bookmark"] = secret
            with self.subTest(size=len(secret)):
                message = self.assert_manifest_rejected(value=changed)
                if secret:
                    self.assertNotIn(secret, message)
        changed = json.loads(json.dumps(value))
        changed["grants"][0]["bookmark"] = 7
        self.assert_manifest_rejected(value=changed)

    def test_manifest_file_is_bounded_regular_0600_and_symlink_free(self):
        self.write_manifest(mode=0o644)
        with self.assertRaisesRegex(access.AudioAccessError, "0600"):
            with access.acquire_file_access(
                self.manifest, run_id=RUN_ID, allowed_paths=[self.first, self.second]
            ):
                pass

        self.write_manifest(raw=b" " * (64 * 1024 + 1))
        with self.assertRaisesRegex(access.AudioAccessError, "exceeds"):
            with access.acquire_file_access(
                self.manifest, run_id=RUN_ID, allowed_paths=[self.first, self.second]
            ):
                pass

        target = self.root / "target.json"
        target.write_text("{}", encoding="utf-8")
        target.chmod(0o600)
        self.manifest.unlink()
        self.manifest.symlink_to(target)
        with self.assertRaisesRegex(access.AudioAccessError, "symbolic link"):
            with access.acquire_file_access(
                self.manifest, run_id=RUN_ID, allowed_paths=[self.first, self.second]
            ):
                pass

        linked_parent = self.root / "linked-parent"
        linked_parent.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(access.AudioAccessError, "symbolic link"):
            with access.acquire_file_access(
                linked_parent / "target.json", run_id=RUN_ID,
                allowed_paths=[self.first, self.second]
            ):
                pass

        fifo = self.root / "manifest-fifo"
        os.mkfifo(fifo, 0o600)
        with self.assertRaisesRegex(access.AudioAccessError, "regular"):
            with access.acquire_file_access(
                fifo, run_id=RUN_ID, allowed_paths=[self.first, self.second]
            ):
                pass

    def test_manifest_identity_change_is_rejected(self):
        self.write_manifest()
        original = access._file_identity
        count = 0

        def changed(info):
            nonlocal count
            count += 1
            identity = original(info)
            return (*identity[:-1], identity[-1] + 1) if count == 4 else identity

        with mock.patch.object(access, "_file_identity", side_effect=changed):
            with self.assertRaisesRegex(access.AudioAccessError, "changed"):
                with access.acquire_file_access(
                    self.manifest, run_id=RUN_ID, allowed_paths=[self.first, self.second]
                ):
                    pass

    def test_manifest_leaf_identity_is_checked_against_open_descriptor(self):
        self.write_manifest()
        original = access._file_identity
        identities = []

        def changed(info):
            identity = original(info)
            identities.append(identity)
            if len(identities) == 2:
                return (*identity[:-1], identity[-1] + 1)
            return identity

        with mock.patch.object(access, "_file_identity", side_effect=changed):
            with self.assertRaisesRegex(access.AudioAccessError, "changed"):
                with access.acquire_file_access(
                    self.manifest, run_id=RUN_ID, allowed_paths=[self.first, self.second]
                ):
                    pass

    def test_manifest_ancestors_need_search_but_not_read_directory_access(self):
        expected = self.write_manifest().read_bytes()
        real_open = os.open
        expected_search = os.O_SEARCH | os.O_NOFOLLOW | os.O_CLOEXEC
        traversal_flags = []

        def search_only(path, flags, *args, **kwargs):
            if flags & getattr(os, "O_NONBLOCK", 0):
                return real_open(path, flags, *args, **kwargs)
            if flags != expected_search:
                raise PermissionError("controlled read-directory denial")
            traversal_flags.append(flags)
            return real_open(path, flags, *args, **kwargs)

        with mock.patch.object(access.os, "open", side_effect=search_only):
            self.assertEqual(access._read_manifest(self.manifest), expected)
        self.assertEqual(len(traversal_flags), len(self.manifest.parts) - 1)
        for flags in traversal_flags:
            self.assertEqual(flags, expected_search)

    def test_core_foundation_bindings_release_data_error_url_and_use_fixed_options(self):
        library = FakeCFLibrary(error=0)
        adapter = access._CoreFoundationAdapter(library)
        url, path = adapter.resolve(b"synthetic")
        self.assertEqual((url, path), (20, "/tmp/grant"))
        self.assertEqual(library.options, access._RESOLUTION_OPTIONS)
        self.assertEqual(library.released, [10])
        self.assertTrue(adapter.start(url))
        adapter.stop(url)
        adapter.release_url(url)
        self.assertEqual(library.stopped, [20])
        self.assertEqual(library.released, [10, 20])
        for name in (
            "CFDataCreate", "CFURLCreateByResolvingBookmarkData",
            "CFURLGetFileSystemRepresentation",
            "CFURLStartAccessingSecurityScopedResource",
            "CFURLStopAccessingSecurityScopedResource", "CFRelease",
        ):
            function = getattr(library, name)
            self.assertIsNotNone(function.argtypes)
            self.assertIsNotNone(function.restype) if name not in (
                "CFURLStopAccessingSecurityScopedResource", "CFRelease"
            ) else self.assertIsNone(function.restype)

    def test_core_foundation_failure_boundaries_release_every_nonnull_reference(self):
        cases = [
            ("data", FakeCFLibrary(data=0), []),
            ("url", FakeCFLibrary(url=0, error=30), [10, 30]),
            ("error-and-url", FakeCFLibrary(url=20, error=30), [10, 30, 20]),
            ("stale", FakeCFLibrary(stale=True, error=0), [10, 20]),
            ("path", FakeCFLibrary(path=""), [10, 20]),
        ]
        for label, library, released in cases:
            with self.subTest(label=label):
                adapter = access._CoreFoundationAdapter(library)
                with self.assertRaises(access.AudioAccessError):
                    adapter.resolve(b"synthetic")
                self.assertEqual(library.released, released)

    def test_non_darwin_factory_is_unsupported_without_loading_a_framework(self):
        with mock.patch.object(access.sys, "platform", "linux"), mock.patch.object(
            access.ctypes, "CDLL"
        ) as loader:
            with self.assertRaisesRegex(access.AudioAccessError, "unsupported"):
                access._make_cf_adapter()
        loader.assert_not_called()


if __name__ == "__main__":
    unittest.main()
