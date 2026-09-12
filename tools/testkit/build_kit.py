#!/usr/bin/env python3
"""Assemble a new offline kit from explicit, already prepared inputs; never downloads/signs."""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess


ROOT = Path(__file__).resolve().parent
BUNDLES = ('DMLXIntegration_DMLXBackend.bundle', 'mlx-swift_Cmlx.bundle',
           'swift-crypto_Crypto.bundle', 'swift-transformers_Hub.bundle')


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def safe_path(root, relative):
    for ancestor in (root, *root.parents):
        if ancestor.is_symlink():
            raise ValueError('Symlink root/ancestor refused: ' + str(ancestor))
    p = PurePosixPath(relative)
    if p.is_absolute() or not p.parts or any(x in ('', '.', '..') for x in p.parts):
        raise ValueError('Unsafe relative path: ' + relative)
    out = root
    for component in p.parts:
        out /= component
        if out.is_symlink():
            raise ValueError('Symlink refused: ' + str(out))
    return out


def regular(path):
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError('Expected ordinary file: ' + str(path))


def copy_file(source, target):
    regular(source)
    if target.exists() or target.is_symlink():
        raise ValueError('Refusing overwrite: ' + str(target))
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['/bin/cp', '-c', str(source), str(target)], check=True)
    if digest(source) != digest(target):
        raise ValueError('Copy digest differs: ' + str(target))


def copy_tree(source, target):
    if source.is_symlink() or not source.is_dir():
        raise ValueError('Expected ordinary directory: ' + str(source))
    target.mkdir(parents=True, exist_ok=False)
    for current, dirs, files in os.walk(source, followlinks=False):
        current = Path(current)
        for name in dirs + files:
            if (current / name).is_symlink():
                raise ValueError('Symlink in input tree: ' + str(current / name))
        for name in files:
            if name in ('.DS_Store',) or name.endswith(('.pyc', '.pyo')):
                continue
            copy_file(current / name, target / (current / name).relative_to(source))


def verify_model_file(path, entry):
    regular(path)
    size = entry['size']
    if path.stat().st_size != size:
        raise ValueError('Model size mismatch: ' + str(path))
    algorithm = entry.get('algorithm', 'sha256')
    expected = entry.get('checksum', entry.get('sha256'))
    if algorithm == 'git-blob-sha1':
        h = hashlib.sha1(('blob ' + str(size) + '\0').encode('ascii'))
    elif algorithm == 'sha256':
        h = hashlib.sha256()
    else:
        raise ValueError('Unknown digest algorithm')
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            h.update(block)
    if h.hexdigest() != expected:
        raise ValueError('Model digest mismatch: ' + str(path))


def build(args):
    # Compare all inputs in the same coordinate system before creating anything.
    if not all(path.is_absolute() for path in (args.cli_products, args.engine, args.models_root, args.output)):
        raise ValueError('All input and output paths must be absolute physical paths')
    output = args.output.absolute()
    inputs = [args.cli_products, args.engine, args.models_root, ROOT]
    for path in inputs + [output.parent]:
        if path.is_symlink() or not path.is_dir() or path.resolve() != path.absolute():
            raise ValueError('Inputs and output parent must be existing physical directories: ' + str(path))
    if output.exists() or output.is_symlink():
        raise ValueError('Output already exists; choose a new kit directory')
    for path in inputs:
        if path == output or path in output.parents or output in path.parents:
            raise ValueError('Output must not overlap input paths')
    if not re.fullmatch(r'[0-9a-f]{40}', args.source_sha):
        raise ValueError('Full source SHA is required')
    output.mkdir()
    # A failed preparation remains explicitly incomplete, with no launch entry.
    (output / 'PREPARATION-INCOMPLETE.txt').write_text('Preparation has not completed. Do not run this kit.\n')
    for folder in ('Bin', 'Runtime', 'Tools', 'Models', 'Results', 'Licenses'):
        (output / folder).mkdir()
    copy_file(args.cli_products / 'd-infer', output / 'Bin/d-infer')
    for bundle in BUNDLES:
        copy_tree(args.cli_products / bundle, output / 'Bin' / bundle)
    copy_tree(args.engine, output / 'Runtime/AudioEngine.dengine')
    copy_file(ROOT / 'd_testkit.py', output / 'Tools/d_testkit.py')
    for folder in ('Inputs', 'Manifests', 'Profiles'):
        copy_tree(ROOT / folder, output / folder)
    copy_file(ROOT / 'README.zh-CN.md', output / 'README.zh-CN.md')
    catalog = json.loads((output / 'Manifests/catalog.json').read_text())
    models = {}
    for model_id, info in catalog['models'].items():
        manifest = json.loads(safe_path(output, info['manifest']).read_text())
        destination = safe_path(output, info['directory'])
        source = args.models_root / Path(info['directory']).name
        print('Verify/copy model:', model_id, flush=True)
        for entry in manifest['files']:
            relative = entry.get('name', entry.get('path'))
            src = safe_path(source, relative)
            verify_model_file(src, entry)
            dst = safe_path(destination, relative)
            copy_file(src, dst)
            verify_model_file(dst, entry)
        models[model_id] = dict(revision=manifest['revision'], bytes=sum(f['size'] for f in manifest['files']))
    kit = dict(schemaVersion=1, kitID='D-PORTABLE-KIT-01-' + args.source_sha[:12],
               sourceSHA=args.source_sha, buildConfiguration=args.configuration,
               cli='Bin/d-infer', engine='Runtime/AudioEngine.dengine',
               catalog='Manifests/catalog.json', profiles='Profiles/profiles.json',
               minimumMacOS='26.2', audioLicenseAcknowledged=True)
    (output / 'kit.json').write_text(json.dumps(kit, ensure_ascii=False, indent=2) + '\n')
    licenses = '''This is a private D validation kit for the author who confirmed applicable model rights.
It is not permission to redistribute the included models. No credentials or signing keys are included.
Model identities and exact file manifests are in Manifests/.
Audio source license: Runtime/AudioEngine.dengine/vendor/LICENSE
Python/dependency licenses and distribution metadata are retained within the embedded engine.
SA3 model use remains subject to Stability AI and applicable Gemma terms; no click here accepts them.
Do not share the kit or run it for another party without verifying their applicable rights.
Generated result bundles exclude model weights and are a separate export.
'''
    (output / 'Licenses/READ-ME.txt').write_text(licenses)
    launcher = '''#!/bin/bash
set -uo pipefail
KIT_ROOT="$(cd -- "$(dirname -- "$0")" && pwd -P)"
if [[ -e "$KIT_ROOT/PREPARATION-INCOMPLETE.txt" ]]; then
  echo "Test kit preparation is incomplete. Please read README.zh-CN.md."
  read -r -p "Press Enter to close." _
  exit 2
fi
export PYTHONDONTWRITEBYTECODE=1
"$KIT_ROOT/Runtime/AudioEngine.dengine/python/bin/python3" -I -B "$KIT_ROOT/Tools/d_testkit.py" menu --kit "$KIT_ROOT"
STATUS=$?
read -r -p "Press Enter to close this window." _
exit "$STATUS"
'''
    # Last artifact installed; preparation marker is removed only after all copies verified.
    (output / 'Start.command').write_text(launcher)
    (output / 'Start.command').chmod(0o755)
    (output / 'Bin/d-infer').chmod(0o755)
    files = []
    for path in sorted(output.rglob('*')):
        if not path.is_file() or 'Models' in path.relative_to(output).parts:
            continue
        rel = path.relative_to(output).as_posix()
        if rel == 'PREPARATION-INCOMPLETE.txt':
            continue
        files.append(dict(path=rel, sizeBytes=path.stat().st_size, sha256=digest(path)))
    (output / 'kit-files.json').write_text(json.dumps(dict(schemaVersion=1, files=files), indent=2) + '\n')
    (output / 'PREPARATION-INCOMPLETE.txt').unlink()
    print(json.dumps(dict(output=str(output), sourceSHA=args.source_sha, models=models), indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ('cli-products', 'engine', 'models-root', 'output'):
        parser.add_argument('--' + flag, type=Path, required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--configuration', choices=('Debug', 'Release'), default='Release')
    build(parser.parse_args())


if __name__ == '__main__':
    main()
