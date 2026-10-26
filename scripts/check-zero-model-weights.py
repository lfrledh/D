#!/usr/bin/env python3
"""Read-only distribution gate. Model payloads have no size/test exceptions.

Ambiguous data is admitted only by exact reviewed non-model bytes. Archives are
inspected without extraction/execution; an unknown or over-budget archive fails.
"""
from __future__ import annotations
import argparse
import gzip
import bz2
import lzma
import hashlib
import io
import json
import re
from pathlib import Path
import stat
import struct
import tarfile
import zipfile

class WeightError(ValueError): pass
WEIGHTS = {'.onnx', '.safetensors', '.gguf', '.ggml', '.ckpt', '.pt', '.pth.tar',
           '.h5', '.hdf5', '.tflite', '.mlmodel', '.caffemodel', '.weights'}
AMBIGUOUS = {'.bin', '.model', '.pb', '.pkl', '.pickle', '.npy', '.npz', '.pth', '.dat'}
MAX_MEMBER = 512 * 1024 * 1024
MAX_EXPANDED = 2 * 1024 * 1024 * 1024
MAX_DEPTH = 6
MAX_MEMBERS = 100_000


def onnx_container(raw: bytes) -> bool:
    """Read protobuf field framing only, never load a model or deserialize code."""
    def varint(offset):
        value = 0
        for shift in range(0, 70, 7):
            if offset >= len(raw): raise ValueError()
            byte = raw[offset]; offset += 1; value |= (byte & 127) << shift
            if byte < 128: return value, offset
        raise ValueError()
    fields = set(); offset = 0
    try:
        while offset < len(raw):
            tag, offset = varint(offset); field, wire = tag >> 3, tag & 7
            if field == 0: return False
            fields.add((field, wire))
            if wire == 0: _, offset = varint(offset)
            elif wire in (1, 5): offset += 8 if wire == 1 else 4
            elif wire == 2:
                count, offset = varint(offset); offset += count
            else: return False
            if offset > len(raw): return False
        # ModelProto: ir_version + graph + opset_import. Graph tensors need not
        # be interpreted to reject the complete model container, even renamed.
        return {(1, 0), (7, 2), (8, 2)} <= fields
    except ValueError:
        return False


def checked_nonmodel() -> dict[str, str]:
    rows = json.loads(Path(__file__).with_name('non-model-resource-data.json').read_text())
    return {r['sha256']: r['purpose'] for r in rows}


def scan(root: Path, known: dict[str, str] | None = None) -> dict:
    known = checked_nonmodel() if known is None else known
    report = {'files': 0, 'archiveMembers': 0, 'expandedBytes': 0, 'classifiedData': []}
    def inspect(name: str, size: int, head: bytes, load, depth: int = 0, inherited: str | None = None):
        if depth > MAX_DEPTH: raise WeightError(f'archive nesting limit: {name}')
        suffix = Path(name).suffix.lower()
        # VMAF stores complete trained LIBSVM records in ordinary JSON and,
        # optionally, compiled libraries. Test bytes, not the filename/container.
        if size <= MAX_MEMBER:
            for match in re.finditer(rb'svm_type(?:[ \t]|\\+t)+(?:nu_svr|epsilon_svr|c_svc|nu_svc|one_class)', load()):
                block = load()[match.start():match.start() + 16 * 1024 * 1024].split(b'\0')[0]
                block = re.sub(rb'\\+r\\+n|\\+n|\r\n', b'\n', block)
                block = re.sub(rb'\\+t', b'\t', block)
                if re.search(rb'\ntotal_sv[ \t]+[1-9][0-9]*[ \t]*\n', block) and re.search(rb'\nSV[ \t]*\n[-+0-9.]', block):
                    raise WeightError(f'embedded trained SVM parameters forbidden: {name}')
        if any(p.lower().endswith(('.mlmodelc', '.mlpackage')) for p in name.replace('!', '/').split('/')):
            raise WeightError(f'compiled model container forbidden: {name}')
        if name.lower().endswith(tuple(WEIGHTS)) or head[:4] in (b'GGUF', b'ggml', b'ggmf', b'ggjt', b'TFL3') or head[4:8] == b'TFL3':
            raise WeightError(f'model payload forbidden: {name}')
        if suffix in {'.7z', '.rar', '.zst', '.zstd', '.br'} or head.startswith((b'7z\xbc\xaf\x27\x1c', b'Rar!', b'\x28\xb5\x2f\xfd')):
            raise WeightError(f'unsupported archive must be inspected before distribution: {name}')
        # Protobuf permits arbitrary field order and unknown extension fields.
        # Framing rejects ordinary text/Mach-O quickly; do not guess the first tag.
        if size <= MAX_MEMBER and onnx_container(load()):
            raise WeightError(f'ONNX model container forbidden: {name}')
        # Safetensors are recognizable even when their extension was changed.
        if len(head) >= 8:
            length = int.from_bytes(head[:8], 'little')
            if 2 <= length <= min(size - 8, 4 * 1024 * 1024) and head[8:9] == b'{':
                if size > MAX_MEMBER: raise WeightError(f'possible tensor container exceeds inspection limit: {name}')
                raw = load()
                try: header = json.loads(raw[8:8 + length])
                except (ValueError, UnicodeError): header = None
                if isinstance(header, dict) and any(isinstance(v, dict) and {'dtype','shape','data_offsets'} <= v.keys() for v in header.values()):
                    raise WeightError(f'safetensors payload forbidden: {name}')
        if size <= MAX_MEMBER:
            try:
                decoded = json.loads(load())
                model = decoded.get('model') if isinstance(decoded, dict) else None
            except (ValueError, UnicodeError): model = None
            if isinstance(model, dict) and model.get('type') in {'Unigram', 'BPE', 'WordPiece'} and model.get('vocab'):
                raise WeightError(f'learned tokenizer parameters forbidden: {name}')
            if isinstance(model, dict) and model.get('type') == 'WordLevel' and model.get('vocab'):
                if hashlib.sha256(load()).hexdigest() not in known:
                    raise WeightError(f'token vocabulary needs exact non-model provenance: {name}')
        raw = None
        classification = inherited
        archive = head.startswith((b'PK\x03\x04', b'\x1f\x8b', b'BZh', b'\xfd7zXZ')) or head[257:262] == b'ustar' or suffix in {'.zip','.whl','.tar','.tgz','.gz','.bz2','.xz','.npz'}
        if not archive and len(head) == 512 and head.strip(b'\0'):
            try: tarfile.TarInfo.frombuf(head, 'utf-8', 'surrogateescape'); archive = True
            except (tarfile.HeaderError, ValueError): pass
        if suffix in AMBIGUOUS:
            if size > MAX_MEMBER: raise WeightError(f'unclassified data exceeds inspection limit: {name}')
            raw = load()
            classification = known.get(hashlib.sha256(raw).hexdigest(), inherited)
            if not classification: raise WeightError(f'unclassified possible model data: {name}')
            report['classifiedData'].append({'path': name, 'purpose': classification})
        if not archive: return
        if size > MAX_MEMBER: raise WeightError(f'archive exceeds inspection limit: {name}')
        raw = raw if raw is not None else load()
        classification = known.get(hashlib.sha256(raw).hexdigest(), classification)
        def reserve_member():
            report['archiveMembers'] += 1
            if report['archiveMembers'] > MAX_MEMBERS: raise WeightError(f'archive member limit: {name}')
        def member(member_name: str, data: bytes):
            report['expandedBytes'] += len(data)
            if len(data) > MAX_MEMBER or report['expandedBytes'] > MAX_EXPANDED or report['archiveMembers'] > MAX_MEMBERS:
                raise WeightError(f'archive expansion limit: {name}')
            inspect(name + '!' + member_name, len(data), data[:512], lambda: data, depth + 1, classification)
        def remaining():
            return min(MAX_MEMBER, MAX_EXPANDED - report['expandedBytes'])
        try:
            if raw.startswith(b'PK'):
                with zipfile.ZipFile(io.BytesIO(raw)) as z:
                    for item in z.infolist():
                        reserve_member()
                        if item.is_dir():
                            inspect(name + '!' + item.filename.rstrip('/'), 0, b'', lambda: b'', depth + 1)
                            continue
                        if item.flag_bits & 1 or item.file_size > remaining(): raise WeightError(f'uninspectable archive member: {name}!{item.filename}')
                        # PyTorch serialization is model-capable executable pickle,
                        # never admitted by a data-file classification.
                        if item.filename.endswith('/data.pkl') or item.filename == 'data.pkl':
                            raise WeightError(f'checkpoint archive forbidden: {name}')
                        member(item.filename, z.read(item))
            elif raw.startswith(b'\x1f\x8b'):
                reserve_member()
                with gzip.GzipFile(fileobj=io.BytesIO(raw)) as z: data = z.read(remaining() + 1)
                member(Path(name).stem + ('.tar' if suffix == '.tgz' else ''), data)
            elif raw.startswith((b'BZh', b'\xfd7zXZ')):
                reserve_member()
                opener = bz2.BZ2File if raw.startswith(b'BZh') else lzma.LZMAFile
                with opener(io.BytesIO(raw)) as z: data = z.read(remaining() + 1)
                member(Path(name).stem, data)
            else:
                with tarfile.open(fileobj=io.BytesIO(raw), mode='r:') as t:
                    for item in t:
                        reserve_member()
                        if item.isdir():
                            inspect(name + '!' + item.name.rstrip('/'), 0, b'', lambda: b'', depth + 1)
                            continue
                        if not item.isfile() or item.size > remaining(): raise WeightError(f'uninspectable tar member: {name}!{item.name}')
                        handle = t.extractfile(item)
                        if handle is None: raise WeightError(f'unreadable tar member: {name}!{item.name}')
                        member(item.name, handle.read(MAX_MEMBER + 1))
        except (OSError, ValueError, EOFError, zipfile.BadZipFile, tarfile.TarError) as error:
            if isinstance(error, WeightError): raise
            raise WeightError(f'cannot inspect archive {name}: {error}') from error
    root = root.resolve(strict=True)
    if not root.is_dir(): raise WeightError('scan target must be a directory')
    for path in sorted(root.rglob('*')):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            # App/framework symlinks are allowed only within the scanned product.
            try: path.resolve(strict=True).relative_to(root)
            except (ValueError, OSError): raise WeightError(f'external or broken resource link: {path.relative_to(root)}')
            continue
        if path.is_dir():
            if path.suffix.lower() in {'.mlpackage', '.mlmodelc'}: raise WeightError(f'compiled model directory forbidden: {path.relative_to(root)}')
            continue
        if not stat.S_ISREG(info.st_mode): raise WeightError(f'non-regular resource: {path.relative_to(root)}')
        report['files'] += 1
        with path.open('rb') as f: head = f.read(512)
        inspect(str(path.relative_to(root)), info.st_size, head, path.read_bytes)
    return report

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('root', type=Path)
    args = parser.parse_args()
    try: print(json.dumps({'status': 'zero-model-weights', **scan(args.root)}, ensure_ascii=False))
    except (OSError, WeightError) as error: parser.exit(2, f'error: {error}\n')
