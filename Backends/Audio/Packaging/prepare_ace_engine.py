#!/usr/bin/env python3
"""Prepare a fixed, weight-free ACE XL SFT development engine in a new directory."""
from __future__ import annotations
import argparse
import hashlib
import json
import shutil
import sys
import tempfile
from pathlib import Path
sys.dont_write_bytecode = True
import prepare_engine as core
import package_audio_app as signing
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Video/Packaging'))
from prepare_external_video_engine import copy_file, relocate_tools, verify_relocated_dependencies, command
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Python'))
from d_audio_ace_contract import SOURCE_PATCHES, validate_manifest

SOURCE_REVISION = 'ca1e85fe9430179831e6bc6be790c332190a3866'
PROVIDERS = ('d_audio_ace_backend.py', 'd_audio_ace_contract.py', 'd_ace_offline_runtime.py', 'd_ace_ssd.py',
             'd_audio_access.py', 'd_audio_contract.py', 'd_audio_mrt2_contract.py')
FIXED_DISTRIBUTIONS = {'torch': '2.10.0', 'torchaudio': '2.10.0', 'transformers': '4.57.6',
    'diffusers': '0.37.1', 'mlx': '0.30.6', 'numpy': '2.3.5', 'soundfile': '0.13.1',
    'safetensors': '0.7.0', 'accelerate': '1.12.0', 'vector_quantize_pytorch': '1.27.20'}
PATCH_RULES = {
    SOURCE_PATCHES[0][0]: (
        ('                    dtype=self.dtype,\n',
         '                    dtype=self.dtype,\n                    local_files_only=True,\n'),
    ),
    SOURCE_PATCHES[1][0]: (
        ('AutoencoderOobleck.from_pretrained(vae_checkpoint_path)',
         'AutoencoderOobleck.from_pretrained(vae_checkpoint_path, local_files_only=True)'),
        ('AutoTokenizer.from_pretrained(text_encoder_path)',
         'AutoTokenizer.from_pretrained(text_encoder_path, local_files_only=True)'),
        ('AutoModel.from_pretrained(text_encoder_path)',
         'AutoModel.from_pretrained(text_encoder_path, local_files_only=True)'),
    ),
}


def patch_source_copy(staging_vendor: Path, manifest: dict) -> dict:
    """Patch only the new package copy, then inventory its actual bytes."""
    patched = json.loads(json.dumps(manifest))
    descriptors = []
    inventory = {item['path']: item for item in patched['sourceFiles']}
    for relative, base_sha in SOURCE_PATCHES:
        item = inventory.get(relative)
        if item is None or item['sha256'] != base_sha:
            raise core.PackagingError('ACE fixed patch base source differs: ' + relative)
        target = staging_vendor / relative
        raw = target.read_bytes()
        if hashlib.sha256(raw).hexdigest() != base_sha:
            raise core.PackagingError('ACE fixed patch input digest differs: ' + relative)
        source = raw.decode('utf-8')
        for before, after in PATCH_RULES[relative]:
            if source.count(before) != 1:
                raise core.PackagingError('ACE fixed patch fragment drift: ' + relative)
            source = source.replace(before, after, 1)
        result = source.encode('utf-8')
        target.write_bytes(result)
        item.update(size=len(result), sha256=hashlib.sha256(result).hexdigest())
        descriptors.append({'path': relative, 'baseSHA256': base_sha,
                            'patchedSHA256': item['sha256']})
    patched['sourcePatches'] = descriptors
    validate_manifest(patched)
    return patched


def checked_manifest(path: Path, vendor: Path) -> dict:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 2 * 1024 * 1024:
        raise core.PackagingError('ACE fixed manifest must be a small regular file')
    value = json.loads(path.read_text(encoding='utf-8'))
    if value.get('sourceRevision') != SOURCE_REVISION or value.get('profile') != 'ace-step-1.5-xl-sft-mlx-f32-v1':
        raise core.PackagingError('ACE manifest profile/source mismatch')
    entries = value.get('sourceFiles', [])
    if not entries or len(entries) > 4096:
        raise core.PackagingError('ACE source inventory absent or too large')
    seen = set()
    for item in entries:
        relative = item['path']; parts = relative.split('/')
        if relative in seen or any(p in ('', '.', '..') for p in parts) or '\0' in relative:
            raise core.PackagingError('Unsafe or duplicate ACE source path')
        if not (relative.startswith('acestep/') or relative == 'LICENSE'):
            raise core.PackagingError('Only fixed ACE runtime source and its license are shipped')
        seen.add(relative)
        file = vendor / relative
        core._reject_symlink_ancestors(file.parent, 'ACE source parent')
        if file.is_symlink() or not file.is_file() or file.stat().st_size != item['size'] or core._sha256(file) != item['sha256']:
            raise core.PackagingError('ACE pinned source differs: ' + relative)
    if not {'LICENSE', 'acestep/handler.py'} <= seen:
        raise core.PackagingError('ACE handler/license absent')
    return value


def prepare(args):
    python = core._absolute_directory(args.python_root, 'standalone Python')
    site = core._absolute_directory(args.site_packages, 'ACE site-packages')
    vendor = core._absolute_directory(args.vendor_directory, 'fixed ACE source')
    provider = Path(__file__).resolve().parents[1] / 'Python'
    manifest_path = Path(args.model_manifest)
    if not manifest_path.is_absolute():
        raise core.PackagingError('Manifest must be absolute')
    core._reject_symlink_ancestors(manifest_path.parent, 'manifest parent')
    output = core._absolute_output(args.output)
    core._reject_overlap(output, [python, site, vendor, provider, manifest_path])
    manifest = checked_manifest(manifest_path, vendor)
    core._validate_tree(site, 'ACE site-packages', skip=True)
    core._validate_tree(python / 'lib/python3.12', 'Python stdlib', skip=True)
    from email.parser import Parser
    for name, version in FIXED_DISTRIBUTIONS.items():
        metadata = site / f'{name}-{version}.dist-info/METADATA'
        if not metadata.is_file():
            raise core.PackagingError('Missing pinned runtime dependency: ' + name)
        parsed = Parser().parsestr(metadata.read_text())
        if parsed.get('Version') != version or parsed.get('Name', '').lower().replace('-', '_') != name:
            raise core.PackagingError('Dependency identity mismatch: ' + name)
    staging = Path(tempfile.mkdtemp(prefix='.d-ace-engine-', dir=output.parent))
    try:
        copy_file(python / 'bin/python3.12', staging / 'python/bin/python3')
        core._copy_tree(python / 'lib/python3.12', staging / 'python/lib/python3.12', exclude_site_packages=True)
        for name in ('libtcl9.0.dylib', 'libtcl9tk9.0.dylib'):
            copy_file(python / 'lib' / name, staging / 'python/lib' / name)
        target_site = staging / 'python/lib/python3.12/site-packages'
        core._copy_tree(site, target_site)
        # Only copied installation records are removed; source environment remains unchanged.
        for directory in target_site.glob('*.dist-info'):
            for name in ('direct_url.json', 'RECORD', 'INSTALLER', 'REQUESTED'):
                record = directory / name
                if record.is_file(): record.unlink()
        for item in manifest['sourceFiles']:
            copy_file(vendor / item['path'], staging / 'vendor' / item['path'])
        deployed_manifest = patch_source_copy(staging / 'vendor', manifest)
        for name in PROVIDERS:
            copy_file(provider / name, staging / 'provider' / name)
        deployed_path = staging / 'model-manifests/ace-xl-sft.json'
        deployed_path.parent.mkdir(parents=True)
        deployed_path.write_text(json.dumps(deployed_manifest, indent=2) + '\n')
        (staging / 'native').mkdir()
        libraries = relocate_tools(staging)
        # torchaudio wheels rely on torch having already loaded sibling dylibs.
        # Bind those observed edges explicitly inside this new bundle.
        audio_lib = target_site / 'torchaudio/lib'
        for binary in audio_lib.iterdir():
            if not binary.is_file() or not signing._is_mach_o(binary): continue
            edges = [line.strip().split(' (compatibility', 1)[0]
                     for line in command(['/usr/bin/otool', '-L', binary]).splitlines() if line.startswith('\t')]
            for edge in edges:
                if not edge.startswith('@rpath/'): continue
                name = edge[len('@rpath/'):]
                if name not in ('libtorch.dylib', 'libtorch_cpu.dylib', 'libtorch_python.dylib', 'libc10.dylib'): continue
                if not (target_site / 'torch/lib' / name).is_file():
                    raise core.PackagingError('Missing bundled torch edge: ' + name)
                command(['/usr/bin/install_name_tool', '-change', edge,
                         '@loader_path/../../torch/lib/' + name, binary])
        verify_relocated_dependencies(staging)
        (staging / 'runtime-origin.json').write_text(json.dumps({
            'schemaVersion': 1, 'sourceRevision': SOURCE_REVISION,
            'profile': manifest['profile'], 'weightsBundled': False,
            'sourcePatches': deployed_manifest['sourcePatches'],
            'nativeLibraries': libraries, 'fixedDependencies': FIXED_DISTRIBUTIONS,
            'status': 'development candidate; real inference and distribution not certified',
        }, indent=2) + '\n')
        core._validate_tree(staging, 'prepared ACE engine')
        inventory = core._manifest(staging)
        inventory.update(kind='d-ace-music-engine', providerScript='provider/d_audio_ace_backend.py')
        files = inventory['files']
        if len(files) > 40_000 or sum(f['sizeBytes'] for f in files) > 1024**3 or any(f['sizeBytes'] > 512 * 1024**2 for f in files):
            raise core.PackagingError('Prepared ACE deployment exceeds bounded inventory budget')
        text = json.dumps(inventory, indent=2) + '\n'
        if len(text.encode()) > 16 * 1024**2:
            raise core.PackagingError('Prepared ACE manifest exceeds 16 MiB')
        (staging / 'engine.json').write_text(text)
        signing._sign_engine(staging, args.identity, args.team)
        core._publish_exclusive(staging, output)
    finally:
        if staging.exists(): shutil.rmtree(staging)  # This invocation's unpublished copy only.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('python-root', 'site-packages', 'vendor-directory', 'model-manifest', 'output', 'identity', 'team'):
        parser.add_argument('--' + name, required=True)
    try:
        prepare(parser.parse_args())
    except (core.PackagingError, OSError, ValueError, KeyError, TypeError) as error:
        core._safe_message(sys.stderr, 'prepare_ace_engine: ' + str(error))
        return 2
    return 0
if __name__ == '__main__':
    raise SystemExit(main())
