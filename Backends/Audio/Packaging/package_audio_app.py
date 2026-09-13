#!/usr/bin/env python3
"""Package both fixed audio engines into a copied, re-signed D application."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
from typing import Any

import prepare_engine
import prepare_mrt2_engine


PackagingError = prepare_engine.PackagingError
CODESIGN = "/usr/bin/codesign"
COMMAND_TIMEOUT_SECONDS = 30
ENGINE_DIRECTORIES = ("AudioEngine.dengine", "MRT2MusicEngine.dengine")
MACH_O_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def _run_command(argv: list[str], timeout: int = COMMAND_TIMEOUT_SECONDS) -> subprocess.CompletedProcess[str]:
    """Run one fixed command and reap its process group on timeout."""
    process = subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = process.communicate()
        raise PackagingError(f"command timed out after {timeout}s: {argv[0]}") from error
    return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)


def _command(argv: list[str], stage: str) -> subprocess.CompletedProcess[str]:
    try:
        result = _run_command(argv)
    except (OSError, UnicodeError, PackagingError) as error:
        raise PackagingError(f"{stage}: {error}") from error
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        if len(detail) > 500:
            detail = detail[:500] + "…"
        suffix = f": {detail}" if detail else ""
        raise PackagingError(f"{stage}: command exited {result.returncode}{suffix}")
    return result


def _signature_metadata(app: Path, stage: str, *, require_identifier: bool = True) -> tuple[str, str]:
    result = _command([CODESIGN, "-d", "--verbose=4", str(app)], stage)
    text = result.stdout + "\n" + result.stderr
    identifier_match = re.search(r"(?m)^Identifier=(.+)$", text)
    team_match = re.search(r"(?m)^TeamIdentifier=(.+)$", text)
    identifier = identifier_match.group(1).strip() if identifier_match else ""
    team = team_match.group(1).strip() if team_match else ""
    if require_identifier and not identifier:
        raise PackagingError(f"{stage}: signing identifier is missing")
    if not team or team.lower() in {"not set", "adhoc", "ad-hoc"}:
        raise PackagingError(f"{stage}: non-ad-hoc TeamIdentifier is missing")
    return identifier, team


def _plist_from_codesign(result: subprocess.CompletedProcess[str], stage: str) -> tuple[dict[str, Any], bytes]:
    text = result.stdout + "\n" + result.stderr
    starts = [position for marker in ("<?xml", "<plist") if (position := text.find(marker)) >= 0]
    end = text.rfind("</plist>")
    if not starts or end < 0:
        raise PackagingError(f"{stage}: entitlement plist is missing")
    raw = text[min(starts):end + len("</plist>")].encode("utf-8")
    try:
        value = plistlib.loads(raw)
    except (plistlib.InvalidFileException, ValueError, TypeError, OverflowError) as error:
        raise PackagingError(f"{stage}: entitlement plist is malformed") from error
    if not isinstance(value, dict):
        raise PackagingError(f"{stage}: entitlements are not a dictionary")
    return value, raw


def _entitlements(app: Path, stage: str) -> tuple[dict[str, Any], bytes]:
    result = _command([CODESIGN, "-d", "--entitlements", ":-", str(app)], stage)
    return _plist_from_codesign(result, stage)


def _checked_directory(value: str, label: str) -> Path:
    return prepare_engine._absolute_directory(value, label)


def _checked_regular(path: Path, label: str) -> None:
    try:
        info = path.lstat()
    except OSError as error:
        raise PackagingError(f"{label} is missing or unreadable: {path}") from error
    if not stat.S_ISREG(info.st_mode):
        raise PackagingError(f"{label} must be a regular file: {path}")


def _inside(root: Path, candidate: Path) -> bool:
    try:
        candidate.relative_to(root)
        return True
    except ValueError:
        return False


def _validate_app_tree(app: Path) -> None:
    resolved_root = app.resolve(strict=True)
    for current, directories, files in os.walk(app, followlinks=False):
        current_path = Path(current)
        for name in directories + files:
            path = current_path / name
            try:
                info = path.lstat()
            except OSError as error:
                raise PackagingError(f"app tree is unreadable: {path}") from error
            if stat.S_ISLNK(info.st_mode):
                try:
                    target_text = os.readlink(path)
                    if os.path.isabs(target_text):
                        raise PackagingError(f"app contains absolute symbolic link: {path}")
                    lexical_target = Path(os.path.normpath(os.path.join(path.parent, target_text)))
                    if not _inside(app, lexical_target):
                        raise PackagingError(f"app symbolic link escapes its root: {path}")
                    resolved = path.resolve(strict=True)
                except (OSError, RuntimeError) as error:
                    raise PackagingError(f"app contains invalid symbolic link: {path}") from error
                if not _inside(resolved_root, resolved):
                    raise PackagingError(f"app symbolic link escapes its root: {path}")
            elif not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise PackagingError(f"app contains special file: {path}")


def _read_app_identity(app: Path) -> tuple[str, dict[str, Any], bytes]:
    contents = app / "Contents"
    resources = contents / "Resources"
    if contents.is_symlink() or not contents.is_dir() or resources.is_symlink() or not resources.is_dir():
        raise PackagingError("input app must contain regular Contents and Contents/Resources directories")
    plist_path = contents / "Info.plist"
    _checked_regular(plist_path, "Info.plist")
    try:
        plist_data = plist_path.read_bytes()
        info = plistlib.loads(plist_data)
    except (OSError, plistlib.InvalidFileException, ValueError, TypeError, OverflowError) as error:
        raise PackagingError("input app Info.plist is malformed") from error
    if not isinstance(info, dict):
        raise PackagingError("input app Info.plist must be a dictionary")
    identifier = info.get("CFBundleIdentifier")
    if not isinstance(identifier, str) or not identifier.strip():
        raise PackagingError("input app CFBundleIdentifier is missing")
    return identifier, info, plist_data


def _repository_inputs() -> tuple[Path, Path, Path, Path]:
    root = Path(__file__).resolve().parents[3]
    return (
        root / "Backends/Audio/Python",
        root / "Vendor/stable-audio3-mlx",
        root / "Backends/Audio/MRT2Vendor",
        root / "Backends/Audio/Models",
    )


def _prepare_engines(resources: Path, python_root: Path, sa3_site: Path, mrt2_site: Path) -> None:
    provider, sa3_vendor, mrt2_vendor, models = _repository_inputs()
    common = dict(
        python_root=str(python_root),
        provider_directory=str(provider),
        model_manifests=str(models),
    )
    try:
        prepare_engine.prepare(argparse.Namespace(
            **common,
            site_packages=str(sa3_site),
            vendor_directory=str(sa3_vendor),
            output=str(resources / ENGINE_DIRECTORIES[0]),
        ))
    except Exception as error:
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        raise PackagingError(f"prepare AudioEngine.dengine: {error}") from error
    try:
        prepare_mrt2_engine.prepare(argparse.Namespace(
            **common,
            site_packages=str(mrt2_site),
            vendor_directory=str(mrt2_vendor),
            output=str(resources / ENGINE_DIRECTORIES[1]),
        ))
    except Exception as error:
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        raise PackagingError(f"prepare MRT2MusicEngine.dengine: {error}") from error


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _is_mach_o(path: Path) -> bool:
    with path.open("rb") as handle:
        return handle.read(4) in MACH_O_MAGICS


def _manifest_files(engine: Path) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    manifest_path = engine / "engine.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PackagingError(f"engine manifest is unreadable: {manifest_path}") from error
    if not isinstance(manifest, dict) or not isinstance(manifest.get("files"), list):
        raise PackagingError(f"engine manifest has invalid structure: {manifest_path}")
    expected = prepare_engine._manifest(engine)["files"]
    if manifest["files"] != expected:
        raise PackagingError(f"engine manifest failed pre-sign verification: {manifest_path}")
    by_path: dict[str, dict[str, Any]] = {}
    for item in manifest["files"]:
        if not isinstance(item, dict) or not isinstance(item.get("path"), str) or item["path"] in by_path:
            raise PackagingError(f"engine manifest contains an invalid file entry: {manifest_path}")
        by_path[item["path"]] = item
    return manifest, by_path


def _sign_engine(engine: Path, identity: str, team: str) -> int:
    manifest, declarations = _manifest_files(engine)
    native: list[tuple[str, Path]] = []
    for relative in sorted(declarations):
        path = engine / relative
        _checked_regular(path, f"engine file {relative}")
        try:
            if _is_mach_o(path):
                native.append((relative, path))
        except OSError as error:
            raise PackagingError(f"cannot inspect engine file magic: {relative}") from error
    for relative, path in native:
        _command([
            CODESIGN, "--force", "--sign", identity,
            "--options", "runtime", "--timestamp=none", str(path),
        ], f"sign engine native file {relative}")
        _command([CODESIGN, "--verify", "--strict", str(path)], f"verify engine native file {relative}")
        _identifier, signed_team = _signature_metadata(path, f"read engine native signature {relative}", require_identifier=False)
        if signed_team != team:
            raise PackagingError(f"engine native TeamIdentifier changed: {relative}")
        info = path.stat()
        declarations[relative].update(
            sizeBytes=info.st_size,
            sha256=_sha256(path),
            executable=bool(info.st_mode & 0o111),
        )
    if native:
        manifest_path = engine / "engine.json"
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
            encoding="utf-8",
        )
    expected_after = prepare_engine._manifest(engine)["files"]
    if manifest["files"] != expected_after:
        raise PackagingError(f"engine manifest failed post-sign verification: {engine / 'engine.json'}")
    return len(native)


def package(args: argparse.Namespace) -> dict[str, Any]:
    app = _checked_directory(args.app, "app")
    if app.suffix != ".app":
        raise PackagingError("app must be an absolute .app directory")
    python_root = _checked_directory(args.python_root, "python-root")
    sa3_site = _checked_directory(args.sa3_site_packages, "sa3-site-packages")
    mrt2_site = _checked_directory(args.mrt2_site_packages, "mrt2-site-packages")
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", args.identity):
        raise PackagingError("identity must be an existing 40-character certificate fingerprint")
    output = prepare_engine._absolute_output(args.output)
    if output.suffix != ".app":
        raise PackagingError("output must be an absolute .app path")
    provider, sa3_vendor, mrt2_vendor, models = _repository_inputs()
    roots = [app, python_root, sa3_site, mrt2_site, provider, sa3_vendor, mrt2_vendor, models]
    prepare_engine._reject_overlap(output, roots)

    _validate_app_tree(app)
    bundle_identifier, _info, _plist_data = _read_app_identity(app)
    resources = app / "Contents/Resources"
    if any(os.path.lexists(resources / name) for name in ENGINE_DIRECTORIES):
        raise PackagingError("input app already contains a bundled audio engine")

    _command([CODESIGN, "--verify", "--strict", str(app)], "verify input app signature")
    signed_identifier, team = _signature_metadata(app, "read input app signature")
    if signed_identifier != bundle_identifier:
        raise PackagingError("input signature identifier differs from CFBundleIdentifier")
    entitlements, _raw_entitlements = _entitlements(app, "read input app entitlements")
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        raise PackagingError("input app must have com.apple.security.app-sandbox=true")

    holder: Path | None = None
    copied_app: Path | None = None
    try:
        holder = Path(tempfile.mkdtemp(prefix=".d-audio-app-", dir=output.parent))
        copied_app = holder / output.name
        shutil.copytree(app, copied_app, symlinks=True, copy_function=shutil.copy2)
        _validate_app_tree(copied_app)
        copied_resources = copied_app / "Contents/Resources"
        _prepare_engines(copied_resources, python_root, sa3_site, mrt2_site)

        native_count = 0
        for name in ENGINE_DIRECTORIES:
            native_count += _sign_engine(copied_resources / name, args.identity, team)

        entitlement_file = holder / "input-entitlements.plist"
        entitlement_file.write_bytes(plistlib.dumps(entitlements, fmt=plistlib.FMT_XML, sort_keys=False))
        _command([
            CODESIGN, "--force", "--sign", args.identity,
            "--options", "runtime", "--timestamp=none",
            "--entitlements", str(entitlement_file), str(copied_app),
        ], "sign output app")
        entitlement_file.unlink()

        _command([CODESIGN, "--verify", "--deep", "--strict", str(copied_app)], "verify output app signature")
        final_bundle_identifier, _final_info, _final_plist = _read_app_identity(copied_app)
        final_identifier, final_team = _signature_metadata(copied_app, "read output app signature")
        final_entitlements, _final_raw = _entitlements(copied_app, "read output app entitlements")
        if final_bundle_identifier != bundle_identifier or final_identifier != bundle_identifier:
            raise PackagingError("output bundle or signing identifier changed")
        if final_team != team:
            raise PackagingError("output TeamIdentifier changed")
        if final_entitlements != entitlements:
            raise PackagingError("output entitlements changed")
        for name in ENGINE_DIRECTORIES:
            _manifest_files(copied_resources / name)

        prepare_engine._publish_exclusive(copied_app, output)
        copied_app = None
        return {
            "status": "packaged",
            "output": str(output),
            "bundleIdentifier": bundle_identifier,
            "teamIdentifier": team,
            "engines": list(ENGINE_DIRECTORIES),
            "signedNativeFiles": native_count,
            "runtimeVerification": "not-run",
        }
    except (OSError, shutil.Error, UnicodeError) as error:
        raise PackagingError(f"package output app: {error}") from error
    finally:
        if holder is not None and holder.exists():
            shutil.rmtree(holder)


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--python-root", required=True)
    parser.add_argument("--sa3-site-packages", required=True)
    parser.add_argument("--mrt2-site-packages", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        report = package(parse_arguments(sys.argv[1:] if argv is None else argv))
    except (PackagingError, OSError, shutil.Error, UnicodeError) as error:
        prepare_engine._safe_message(sys.stderr, f"package_audio_app: {error}")
        return 2
    if not prepare_engine._safe_message(sys.stdout, json.dumps(report, ensure_ascii=False, sort_keys=True)):
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
