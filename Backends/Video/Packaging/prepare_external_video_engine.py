#!/usr/bin/env python3
"""Prepare an explicit, weight-free H3/LTX development engine; never install it."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tarfile

sys.dont_write_bytecode = True
AUDIO = Path(__file__).resolve().parents[2] / "Audio/Packaging"
sys.path.insert(0, str(AUDIO))
import prepare_engine as core
import package_audio_app as signing


def command(argv):
    result = subprocess.run([str(x) for x in argv], stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=60, check=False)
    if result.returncode:
        raise core.PackagingError(f"{argv[0]} failed: {result.stderr[-2000:]}")
    return result.stdout


def copy_file(source, destination):
    source = Path(source)
    if source.is_symlink() or not source.is_file():
        raise core.PackagingError(f"Expected regular source: {source}")
    before = source.stat()
    digest = core._sha256(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if os.path.lexists(destination):
        raise core.PackagingError(f"Refusing overwrite: {destination}")
    shutil.copy2(source, destination)
    after = source.stat()
    if (before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
        after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns
    ) or digest != core._sha256(destination):
        raise core.PackagingError(f"Source changed while copying: {source}")


def relocate_tools(staging):
    """Close only explicit Mach-O dependency edges, never scan a host directory."""
    libraries = staging / "native/libs"
    libraries.mkdir()
    origins = {}
    queue = [p for p in staging.rglob("*") if p.is_file() and signing._is_mach_o(p)]
    seen = set()
    while queue:
        target = queue.pop()
        if target in seen:
            continue
        seen.add(target)
        dependencies = [line.strip().split(" (compatibility", 1)[0]
                        for line in command(["/usr/bin/otool", "-L", target]).splitlines()
                        if line.startswith("\t")]
        # otool -L lists a dylib's own LC_ID_DYLIB before its dependencies.
        # Wheel build prefixes (for example /DLC/PIL) are not host files to copy.
        identities = {line.strip() for line in command(["/usr/bin/otool", "-D", target]).splitlines()
                      if line.strip() and not line.rstrip().endswith(":")}
        if identities:
            command(["/usr/bin/install_name_tool", "-id", "@loader_path/" + target.name, target])
        for dependency in dependencies:
            if dependency in identities:
                continue
            if dependency.startswith("@rpath/") and (target.parent / dependency[len("@rpath/"):]).is_file():
                # MLX's sibling jaccl library otherwise relies on its importing
                # extension's inherited rpath. Make this bundled edge explicit.
                command(["/usr/bin/install_name_tool", "-change", dependency,
                         "@loader_path/" + dependency[len("@rpath/"):], target])
                continue
            if dependency.startswith(("/System/Library/", "/usr/lib/", "@")):
                continue
            if not dependency.startswith("/opt/homebrew/"):
                raise core.PackagingError(f"Unapproved external library: {dependency}")
            source = Path(dependency).resolve(strict=True)
            destination = libraries / source.name
            previous = origins.get(source.name)
            digest = core._sha256(source)
            if previous and previous[1] != digest:
                raise core.PackagingError(f"Library basename collision: {source.name}")
            if not previous:
                copy_file(source, destination)
                origins[source.name] = (str(source), digest)
                queue.append(destination)
            relative = os.path.relpath(destination, target.parent)
            command(["/usr/bin/install_name_tool", "-change", dependency,
                     "@loader_path/" + relative, target])
        if target.parent == libraries:
            command(["/usr/bin/install_name_tool", "-id", "@loader_path/" + target.name, target])
        load_commands = command(["/usr/bin/otool", "-l", target]).splitlines()
        rpaths = {load_commands[i + 2].strip().split("path ", 1)[1].split(" (offset", 1)[0]
                  for i, line in enumerate(load_commands[:-2]) if line.strip() == "cmd LC_RPATH"}
        for rpath in rpaths:
            # Build-machine search roots are not runtime resources. Remove them
            # only from this new copy; the closure check below must still pass.
            if rpath.startswith("/") and not rpath.startswith(("/System/Library/", "/usr/lib/")):
                command(["/usr/bin/install_name_tool", "-delete_rpath", rpath, target])
    return [{"name": name, "sourceSHA256": item[1]} for name, item in sorted(origins.items())]



def verify_relocated_dependencies(staging):
    """Resolve declared load edges in this bundle, without loading model code."""
    def expand(value, loader):
        # Native programs and Python extensions have different entry executables.
        # Shared native/libs must not assume any caller's executable directory.
        if "@executable_path" in value:
            if staging / "python" in loader.parents:
                executable = staging / "python/bin/python3"
            elif loader.parent == staging / "native" and loader.name in ("h3", "ffmpeg", "ffprobe"):
                executable = loader
            else:
                raise core.PackagingError(f"Ambiguous executable-relative dependency: {loader.name}: {value}")
            value = value.replace("@executable_path", str(executable.parent))
        value = value.replace("@loader_path", str(loader.parent))
        return Path(value).resolve()
    def rpaths(target):
        lines = command(["/usr/bin/otool", "-l", target]).splitlines()
        return [lines[i + 2].strip().split("path ", 1)[1].split(" (offset", 1)[0]
                for i, line in enumerate(lines[:-2]) if line.strip() == "cmd LC_RPATH"]
    def contained(path):
        return path == staging or staging in path.parents
    unresolved = []
    for target in staging.rglob("*"):
        if not target.is_file() or not signing._is_mach_o(target):
            continue
        roots = [expand(value, target) for value in rpaths(target)]
        for root in roots:
            if not contained(root) and not str(root).startswith(("/usr/lib/", "/System/Library/")):
                raise core.PackagingError(f"Runtime search path escapes prepared bundle: {target.name}: {root}")
        ids = {line.strip() for line in command(["/usr/bin/otool", "-D", target]).splitlines()
               if line.strip() and not line.rstrip().endswith(":")}
        edges = [line.strip().split(" (compatibility", 1)[0]
                 for line in command(["/usr/bin/otool", "-L", target]).splitlines() if line.startswith("\t")]
        for edge in edges:
            if edge in ids or edge.startswith(("/System/Library/", "/usr/lib/")):
                continue
            candidates = [root / edge[len("@rpath/"):] for root in roots] if edge.startswith("@rpath/") else [expand(edge, target)]
            if not any(contained(item.resolve()) and item.is_file() for item in candidates):
                unresolved.append(f"{target.relative_to(staging)}: {edge}")
    if unresolved:
        raise core.PackagingError("Unresolved prepared dependencies: " + "; ".join(unresolved[:50]))


def verify_ltx_source(archive, site, video):
    if core._sha256(archive) != "99a789280172bfc51c4e4b455e29f55c8b467ac2305131bcf9fe5750a3b03d0e":
        raise core.PackagingError("Pinned LTX source archive differs")
    expected, before = {}, {}
    for name in ("ltx-reject-token-truncation.json", "ltx25-gemma4-streaming.json"):
        patches = json.loads((video / "Adapters/Patches" / name).read_text())
        for entry in patches["files"]:
            relative = entry["path"].split("/src/", 1)[1]
            if relative in expected:
                raise core.PackagingError("Overlapping LTX patches require an explicit ordered migration")
            expected[relative], before[relative] = entry["after_sha256"], entry["before_sha256"]
    checked = set()
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle.getmembers():
            if not member.isfile():
                continue
            path = "/".join(Path(member.name).parts[1:])
            if not path.startswith(("packages/ltx-core-mlx/src/", "packages/ltx-pipelines-mlx/src/")):
                continue
            relative = path.split("/src/", 1)[1]
            if any(part in ("..", ".") for part in Path(relative).parts):
                raise core.PackagingError("Unsafe LTX source archive name")
            source = bundle.extractfile(member)
            original_digest = hashlib.sha256(source.read()).hexdigest()
            if relative in before and before[relative] != original_digest:
                raise core.PackagingError(f"LTX patch baseline differs from pinned archive: {relative}")
            digest = expected.get(relative) or original_digest
            if digest != core._sha256(site / relative):
                raise core.PackagingError(f"Installed LTX differs from pinned source/patch: {relative}")
            checked.add(relative)
    if not set(expected).issubset(checked) or len(checked) < 50:
        raise core.PackagingError("Incomplete installed LTX source verification")
    actual = {str(p.relative_to(site)) for name in ("ltx_core_mlx", "ltx_pipelines_mlx")
              for p in (site / name).rglob("*") if p.is_file() and "__pycache__" not in p.parts}
    if actual != checked:
        raise core.PackagingError("LTX source file set differs from pinned archive: " +
                                  repr(sorted(actual.symmetric_difference(checked))[:20]))
    return len(checked)

def prepare(args):
    python = core._absolute_directory(args.python_root, "standalone Python")
    site = core._absolute_directory(args.site_packages, "fixed LTX environment")
    h3 = core._absolute_directory(args.h3_source, "fixed H3 source/build")
    video = Path(__file__).resolve().parents[1]
    ffmpeg = Path(args.ffmpeg).resolve(strict=True)
    ffprobe = Path(args.ffprobe).resolve(strict=True)
    output = core._absolute_output(args.output)
    core._reject_overlap(output, [python, site, h3, video, ffmpeg.parent, ffprobe.parent])
    for root in [site, video / "Adapters"]:
        core._validate_tree(root, "input", skip=True)
    for name, version in {"mlx": "0.32.2", "ltx_core_mlx": "0.15.12",
                          "ltx_pipelines_mlx": "0.15.12", "transformers": "5.3.0"}.items():
        if not (site / f"{name}-{version}.dist-info/METADATA").is_file():
            raise core.PackagingError(f"Missing pinned distribution {name} {version}")
    ltx_checked = verify_ltx_source(Path(args.ltx_source_archive), site, video)
    archive = Path(args.h3_source_archive)
    if core._sha256(archive) != "ce6365e2c309a34d58e075261fbdcba3f64b588b802d0cf2f667f7d312efef18":
        raise core.PackagingError("Pinned H3 source archive differs")
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle.getmembers():
            if not member.isfile():
                continue
            parts = Path(member.name).parts[1:]
            if not parts or any(part in ("..", ".") for part in parts):
                raise core.PackagingError("Unsafe source archive name")
            source = h3.joinpath(*parts)
            item = bundle.extractfile(member)
            if item is None or hashlib.sha256(item.read()).hexdigest() != core._sha256(source):
                raise core.PackagingError(f"H3 source differs from archive: {source.name}")
    # We preserve the source/patch identity; these checks do not certify numerical parity.
    if core._sha256(h3 / "h3_shaders.metal") != "95d665ecad0a19b6864708272b4e0a30d41ea445ecc8a74b8f75dd6de323ddd3":
        raise core.PackagingError("H3 shader differs")
    staging = Path(tempfile.mkdtemp(prefix=".d-external-video-", dir=output.parent))
    try:
        copy_file(python / "bin/python3.12", staging / "python/bin/python3")
        core._copy_tree(python / "lib/python3.12", staging / "python/lib/python3.12", exclude_site_packages=True)
        for name in ["libtcl9.0.dylib", "libtcl9tk9.0.dylib"]:
            copy_file(python / "lib" / name, staging / "python/lib" / name)
        target_site = staging / "python/lib/python3.12/site-packages"
        core._copy_tree(site, target_site)
        # Bind provenance to the actual shipped copy, not a prior input snapshot.
        ltx_checked = verify_ltx_source(Path(args.ltx_source_archive), target_site, video)
        for record in target_site.rglob("direct_url.json"):
            record.unlink()  # Only installation provenance in this new copy, never a source file.
        core._copy_tree(video / "Adapters", staging / "provider")
        copy_file(video.parent / "Audio/Python/d_audio_access.py", staging / "provider/d_audio_access.py")
        core._copy_tree(video / "Adapters/Resources", staging / "model-manifests")
        for name, source in [("h3", h3 / "h3"), ("h3_shaders.metal", h3 / "h3_shaders.metal"),
                             ("ffmpeg", ffmpeg), ("ffprobe", ffprobe)]:
            copy_file(source, staging / "native" / name)
        copy_file(h3 / "LICENSE", staging / "Licenses/h3-MIT.txt")
        for name in ["LICENSE.md", "COPYING.GPLv2", "COPYING.GPLv3", "COPYING.LGPLv2.1", "COPYING.LGPLv3"]:
            copy_file(ffmpeg.parent.parent / name, staging / "Licenses" / ("ffmpeg-" + name))
        libraries = relocate_tools(staging)
        verify_relocated_dependencies(staging)
        (staging / "runtime-origin.json").write_text(json.dumps({
            "schemaVersion": 1, "h3Commit": "8974cc055ea9c02fcd14cc27dfda3e1027c05153",
            "ltxCommit": "1724ca673d59f023a8a95efee06e5d36d61c2765",
            "ltxSourceFilesVerified": ltx_checked,
            "ltxPatches": ["ltx-reject-token-truncation.json", "ltx25-gemma4-streaming.json"],
            "nativeLibraries": libraries, "weightsBundled": False,
            "distributionReview": "development-only; not a release clearance",
        }, indent=2) + "\n")
        core._validate_tree(staging, "prepared engine", skip=False)
        manifest = core._manifest(staging)
        manifest.update(kind="d-external-video-engine", providerScript="provider/app_video_driver.py",
                        vendorDirectory="native")
        (staging / "engine.json").write_text(json.dumps(manifest, indent=2) + "\n")
        # install_name_tool invalidates existing native signatures. Sign only this
        # newly prepared copy with the already approved development identity.
        # Xcode later copies the verified engine and signs the enclosing App normally.
        signing._sign_engine(staging, args.identity, args.team)
        core._publish_exclusive(staging, output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)  # This invocation's unpublished private staging only.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ["python-root", "site-packages", "h3-source", "h3-source-archive", "ltx-source-archive", "ffmpeg", "ffprobe", "output", "identity", "team"]:
        parser.add_argument("--" + option, required=True)
    try:
        prepare(parser.parse_args())
    except (OSError, ValueError, subprocess.SubprocessError, core.PackagingError) as error:
        print(str(error), file=sys.stderr)
        return 2
    print("Prepared and development-signed external video engine; model and App acceptance remain separate.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
