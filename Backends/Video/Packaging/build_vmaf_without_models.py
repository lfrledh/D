#!/usr/bin/env python3
"""Build the fixed libvmaf dependency without its compiled third-party models.

No downloads, system installs, FFmpeg feature changes or model execution. Source
and build tools are supplied by the caller; the output directory must be new.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Audio/Packaging"))
import package_audio_app as commands

SOURCE = 'https://github.com/Netflix/vmaf/archive/refs/tags/v3.2.0.tar.gz'
SOURCE_SHA = 'a28f93f3b4fa65601be324587072e32a6a704a304ba7b1aec9b70b3f709bc1dc'
LICENSE_SHA = 'a6fdb51d02b9dfe198e55534bb8047fe6d756eda117f4ff83de98f92c1952710'
FLAGS = ['--buildtype=release', '--default-library=shared', '-Dbuilt_in_models=false',
         '-Denable_tests=false', '-Denable_docs=false', '-Denable_tools=false']

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def run(argv, env=None):
    argv = [str(v) for v in argv]
    if env is not None:
        argv = ['/usr/bin/env', *[key+'='+env[key] for key in ('CC', 'CXX', 'MACOSX_DEPLOYMENT_TARGET', 'PATH')], *argv]
    result = commands._run_command(argv, timeout=900)
    if result.returncode: raise RuntimeError(result.stdout + result.stderr)
    return result.stdout + result.stderr

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['source-archive', 'meson', 'ninja', 'output']:
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists() or not args.output.parent.is_dir(): raise ValueError('output must be new with an existing parent')
    if args.source_archive.is_symlink() or sha(args.source_archive) != SOURCE_SHA: raise ValueError('source archive differs')
    args.output.mkdir()
    env = dict(os.environ, CC='/usr/bin/clang', CXX='/usr/bin/clang++', MACOSX_DEPLOYMENT_TARGET='26.0')
    env['PATH'] = str(args.ninja.resolve().parent) + ':' + env.get('PATH', '/usr/bin:/bin')
    # Failed/cancelled builds retain their owned scratch for evidence and recovery.
    root = Path(tempfile.mkdtemp(prefix='vmaf-fixed-build-', dir=args.output.parent))
    try:
        with tarfile.open(args.source_archive) as archive:
            members = archive.getmembers()
            if len(members) > 20000 or sum(m.size for m in members) > 100_000_000: raise ValueError('source exceeds bounds')
            for member in members:
                if Path(member.name).is_absolute() or '..' in Path(member.name).parts or not (member.isfile() or member.isdir()):
                    raise ValueError('unsafe source member')
            archive.extractall(root)
        source = root/'vmaf-3.2.0'
        if sha(source/'LICENSE') != LICENSE_SHA: raise ValueError('source license differs')
        versions = {'meson': run([args.meson, '--version']).strip(), 'ninja': run([args.ninja, '--version']).strip()}
        build = root/'build'
        log = run([args.meson, 'setup', build, source/'libvmaf', *FLAGS], env)
        log += run([args.meson, 'compile', '-C', build, '-j', '4'], env)
        binary = args.output/'libvmaf.3.dylib'
        shutil.copy2(build/'src/libvmaf.3.dylib', binary)
        run(['/usr/bin/install_name_tool', '-id', '@loader_path/libvmaf.3.dylib', binary])
        symbols = run(['/usr/bin/nm', '-gjU', binary]).splitlines()
        if '_vmaf_model_load' not in symbols or '_vmaf_model_load_from_path' not in symbols: raise ValueError('public model API missing')
        if b'svm_type nu_svr' in binary.read_bytes(): raise ValueError('embedded model remains')
        dependencies = run(['/usr/bin/otool', '-L', binary])
        for line in dependencies.splitlines()[1:]:
            if not line.strip().startswith(('@loader_path/libvmaf.3.dylib', '/usr/lib/', '/System/Library/')): raise ValueError('non-system dependency')
        if run(['/usr/bin/lipo', '-archs', binary]).strip() != 'arm64': raise ValueError('expected current fixed arm64 runtime')
        shutil.copy2(source/'LICENSE', args.output/'LICENSE')
        (args.output/'build.log').write_text(log)
        (args.output/'PROVENANCE.json').write_text(json.dumps({
            'version':'3.2.0', 'sourceURL':SOURCE, 'sourceSHA256':SOURCE_SHA, 'builtInModels':False,
            'flags':FLAGS, 'tools':versions, 'deploymentTarget':'26.0', 'librarySHA256':sha(binary),
            'licenseSHA256':LICENSE_SHA, 'exportedSymbols':symbols,
            'scope':'Fixed FFmpeg dependency; named built-in VMAF scoring is unavailable; external model API retained. D does not invoke VMAF scoring.'
        }, indent=2)+'\n')
    except BaseException:
        print('Retained build scratch: ' + str(root), file=sys.stderr)
        raise
    shutil.rmtree(root)  # Only after every owned command has completed and drained.
    print(args.output)
if __name__ == '__main__': main()
