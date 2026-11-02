"""Bounded native-library provenance checks shared by preparation and reuse.

The caller already owns hashing/copying. This module only compares those facts;
it does not discover host libraries, change licenses, or rebuild dependencies.
"""
import re


def _index(rows, label):
    if not isinstance(rows, list) or len(rows) > 512:
        raise ValueError(label + ' list is invalid or exceeds its limit')
    result = {}
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError(label + ' identity is invalid')
        name, digest = row.get('name'), row.get('sourceSHA256')
        if (not isinstance(name, str) or not name or '/' in name or '\\' in name
                or name in {'.', '..'} or not isinstance(digest, str)
                or re.fullmatch('[0-9a-f]{64}', digest) is None):
            raise ValueError(label + ' identity is invalid')
        if name in result:
            raise ValueError('duplicate ' + label + ' identity: ' + name)
        result[name] = row
    return result


def validate_native_libraries(libraries, records, ffmpeg, *, files=None, replacement=None, origin=None):
    """Require exact registered origins, including FFmpeg's own shared libraries.

    ``files`` is the already verified path -> digest inventory, when inspecting a
    prepared engine. VMAF is the sole supported, explicitly recorded replacement.
    """
    observed = _index(libraries, 'native library')
    if not isinstance(records, list) or len(records) > 128:
        raise ValueError('native notice registry is invalid')
    if not isinstance(ffmpeg, dict) or ffmpeg.get('component') != 'FFmpeg':
        raise ValueError('FFmpeg source registration is invalid')
    own = _index(ffmpeg.get('inputLibraries'), 'FFmpeg library')
    if not own:
        raise ValueError('FFmpeg library registration is empty')
    external = _index([row for record in records for row in record['binaries']], 'registered library')
    if own.keys() & external.keys():
        raise ValueError('duplicate FFmpeg/external library registration')
    registered = {**own, **external}
    missing = sorted(observed.keys() - registered.keys())
    if missing:
        raise ValueError('native notice is not registered: ' + ', '.join(missing))
    if files is not None:
        if (not isinstance(origin, dict)
                or origin.get('ffmpegSource') != 'Licenses/ffmpeg-9.0.1-SOURCE.json'
                or origin.get('ffmpegSourceArchiveSHA256') != ffmpeg.get('sourceSHA256')):
            raise ValueError('FFmpeg recorded source identity differs')
        for item in [ffmpeg['buildRecipe'], ffmpeg['buildRecipe']['license']] + ffmpeg['notices']:
            path = item['path']
            if (not isinstance(path, str) or path.startswith('/') or '..' in path.split('/')
                    or files.get('Licenses/' + path) != item['sha256']):
                raise ValueError('FFmpeg source notice identity differs')
        actual = {path.removeprefix('native/libs/') for path in files if path.startswith('native/libs/')}
        if actual != observed.keys():
            raise ValueError('native library inventory differs from recorded origins')
    for name, row in observed.items():
        expected = registered[name]['sourceSHA256']
        replaced = 'sourceBuild' in row or 'replacedSourceSHA256' in row
        if replaced:
            source = next((record for record in records if any(item['name'] == name for item in record['binaries'])), None)
            if (name != 'libvmaf.3.dylib' or row.get('sourceBuild') != 'Licenses/libvmaf-no-models.json'
                    or row.get('replacedSourceSHA256') != expected or not isinstance(replacement, dict)
                    or row['sourceSHA256'] != replacement.get('librarySHA256') or source is None
                    or source.get('upstreamRecipe') != [replacement.get('sourceURL'), replacement.get('sourceSHA256')]
                    or source.get('component') != 'libvmaf/' + str(replacement.get('version'))
                    or replacement.get('builtInModels') is not False
                    or '-Dbuilt_in_models=false' not in replacement.get('flags', [])
                    or replacement.get('licenseSHA256') not in [notice['sha256'] for notice in source['notices']]):
                raise ValueError('native VMAF replacement source identity differs')
            if files is not None:
                signed = origin.get('vmafNoModels')
                fields = ['version', 'sourceURL', 'sourceSHA256', 'librarySHA256',
                          'builtInModels', 'flags', 'licenseSHA256']
                if not isinstance(signed, dict) or any(signed.get(key) != replacement.get(key) for key in fields):
                    raise ValueError('native VMAF replacement records differ')
                if files.get('native/libs/' + name) != signed.get('signedSHA256'):
                    raise ValueError('native VMAF signed identity differs')
        elif row['sourceSHA256'] != expected:
            raise ValueError('native notice source identity differs: ' + name)
    if files is not None:
        for record in records:
            if not any(row['name'] in observed for row in record['binaries']):
                continue
            for notice in record['notices']:
                path = notice['path']
                if (not isinstance(path, str) or path.startswith('/') or '..' in path.split('/')
                        or files.get('Licenses/native/' + path) != notice['sha256']):
                    raise ValueError('native notice file identity differs')
