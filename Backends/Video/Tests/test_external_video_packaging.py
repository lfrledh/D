"""CPU fixtures for the copied-source and native dependency boundaries."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock

PATH = Path(__file__).resolve().parents[1] / "Packaging/prepare_external_video_engine.py"
spec = importlib.util.spec_from_file_location("external_packaging", PATH)
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class ExternalPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ["TMPDIR"], prefix="packaging-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def sources(self):
        site = self.root / "site"
        video = self.root / "video"
        patch = video / "Adapters/Patches/ltx-reject-token-truncation.json"
        patch.parent.mkdir(parents=True)
        patch.write_text(json.dumps({"files": []}))
        (patch.parent / "ltx25-gemma4-streaming.json").write_text(json.dumps({"files": []}))
        archive = self.root / "fixture.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            for number in range(50):
                package = "ltx_core_mlx" if number < 25 else "ltx_pipelines_mlx"
                folder = "ltx-core-mlx" if number < 25 else "ltx-pipelines-mlx"
                name = f"{package}/part{number}.py"
                data = f"VALUE = {number}\n".encode()
                path = site / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                info = tarfile.TarInfo(f"fixture/packages/{folder}/src/{name}")
                info.size = len(data)
                bundle.addfile(info, io.BytesIO(data))
        real_hash = packaging.core._sha256
        def digest(path):
            if Path(path) == archive:
                return "99a789280172bfc51c4e4b455e29f55c8b467ac2305131bcf9fe5750a3b03d0e"
            return real_hash(path)
        self.enterContext(mock.patch.object(packaging.core, "_sha256", side_effect=digest))
        return archive, site, video

    def test_exact_source_set_and_changed_copied_bytes(self):
        archive, site, video = self.sources()
        self.assertEqual(packaging.verify_ltx_source(archive, site, video), 50)
        (site / "ltx_core_mlx/part0.py").write_text("CHANGED = True")
        with self.assertRaisesRegex(packaging.core.PackagingError, "differs from pinned"):
            packaging.verify_ltx_source(archive, site, video)

    def test_extra_importable_directory_cannot_shadow_verified_module(self):
        archive, site, video = self.sources()
        shadow = site / "ltx_pipelines_mlx/cli/__init__.py"
        shadow.parent.mkdir()
        shadow.write_text("raise RuntimeError('shadow')")
        with self.assertRaisesRegex(packaging.core.PackagingError, "file set differs"):
            packaging.verify_ltx_source(archive, site, video)

    def test_patched_source_must_match_both_pinned_before_and_installed_after(self):
        archive, site, video = self.sources()
        original = (site / "ltx_core_mlx/part0.py").read_bytes()
        replacement = b"VALUE = 51\n"
        entry = {"path": "packages/ltx-core-mlx/src/ltx_core_mlx/part0.py",
                 "before_sha256": hashlib.sha256(original).hexdigest(),
                 "after_sha256": hashlib.sha256(replacement).hexdigest()}
        record = video / "Adapters/Patches/ltx25-gemma4-streaming.json"
        record.write_text(json.dumps({"files": [entry]}))
        with self.assertRaisesRegex(packaging.core.PackagingError, "differs from pinned"):
            packaging.verify_ltx_source(archive, site, video)
        (site / "ltx_core_mlx/part0.py").write_bytes(replacement)
        self.assertEqual(packaging.verify_ltx_source(archive, site, video), 50)
        entry["before_sha256"] = "0" * 64
        record.write_text(json.dumps({"files": [entry]}))
        with self.assertRaisesRegex(packaging.core.PackagingError, "baseline differs"):
            packaging.verify_ltx_source(archive, site, video)

    def test_ffmpeg_source_materials_require_exact_source_recipe_and_tools(self):
        folder = packaging.Path(packaging.__file__).resolve().parent / 'Licenses'
        record = json.loads((folder / 'ffmpeg-9.0.1-SOURCE.json').read_text())
        archive = self.root / 'source.tar.xz'; archive.write_bytes(b'source')
        ffmpeg = self.root / 'ffmpeg'; ffprobe = self.root / 'ffprobe'
        for name, path in [('ffmpeg',ffmpeg),('ffprobe',ffprobe)]:
            path.write_bytes(b'x' * record['inputTools'][name]['byteCount'])
        real = packaging.core._sha256
        hashes = {archive: record['sourceSHA256'], ffmpeg: record['inputTools']['ffmpeg']['sha256'], ffprobe: record['inputTools']['ffprobe']['sha256']}
        staging = self.root / 'staging'
        (staging / 'native').mkdir(parents=True)
        for name, path in [('ffmpeg',ffmpeg),('ffprobe',ffprobe)]:
            target=staging / 'native' / name; target.write_bytes(path.read_bytes()); hashes[target]=hashes[path]
        with mock.patch.object(packaging.core, '_sha256', side_effect=lambda p: hashes.get(Path(p), None) or real(p)):
            packaging.install_ffmpeg_source_materials(staging, ffmpeg, ffprobe, archive)
            self.assertEqual(json.loads((staging / 'Licenses/ffmpeg-9.0.1-SOURCE.json').read_text()), record)
            notice = folder / record['buildRecipe']['license']['path']
            self.assertEqual((staging / 'Licenses' / notice.name).read_bytes(), notice.read_bytes())
            hashes[notice] = '0' * 64
            with self.assertRaisesRegex(packaging.core.PackagingError, 'recipe license'):
                packaging.install_ffmpeg_source_materials(staging, ffmpeg, ffprobe, archive)
            del hashes[notice]
            hashes[staging / 'native/ffprobe'] = '0' * 64
            with self.assertRaisesRegex(packaging.core.PackagingError, 'tool identity'):
                packaging.install_ffmpeg_source_materials(staging, ffmpeg, ffprobe, archive)
            hashes[ffmpeg] = '0' * 64
            with self.assertRaisesRegex(packaging.core.PackagingError, 'tool identity'):
                packaging.install_ffmpeg_source_materials(self.root / 'bad', ffmpeg, ffprobe, archive)
            with self.assertRaisesRegex(packaging.core.PackagingError, 'source archive'):
                packaging.install_ffmpeg_source_materials(self.root / 'missing', ffmpeg, ffprobe, None)

    def test_native_executable_path_is_not_python_bin(self):
        native = self.root / "native/ffmpeg"
        native.parent.mkdir()
        native.write_bytes(b"fixture")
        wrong = self.root / "python/bin/libs/dependency.dylib"
        wrong.parent.mkdir(parents=True)
        wrong.write_bytes(b"fixture")
        def command(argv):
            return "\t@executable_path/libs/dependency.dylib (compatibility version 1.0.0)\n" if argv[1] == "-L" else ""
        with mock.patch.object(packaging.signing, "_is_mach_o", side_effect=lambda p: p == native), \
             mock.patch.object(packaging, "command", side_effect=command):
            with self.assertRaisesRegex(packaging.core.PackagingError, "Unresolved"):
                packaging.verify_relocated_dependencies(self.root)
            right = self.root / "native/libs/dependency.dylib"
            right.parent.mkdir()
            right.write_bytes(b"fixture")
            packaging.verify_relocated_dependencies(self.root)


if __name__ == "__main__":
    unittest.main()
