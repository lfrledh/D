"""Pinned LTX 2.3 resource admission, independent of UI and GPU libraries.

Full and quantized development configurations are distinct identities. Resource
identity is not a claim of numerical parity or a successful model execution.
"""
from pathlib import Path
import json
import math
import os
import stat

from resource_inventory import ResourceError, _open_regular, _unique, verify_inventory

FULL_PROFILE = 'ltx-2.3-dev-bf16-full-v1'
TEST_PROFILE = 'ltx-2.3-dev-q8-gemma3-q4-test-v1'
LTX25_PROFILE = 'ltx-2.5-dev-bf16-full-v1'
_PROFILES = {
    FULL_PROFILE: ('ltx23-bf16', 'gemma3-bf16', {'diffusion': 'BF16', 'text': 'BF16', 'distilled': False}),
    TEST_PROFILE: ('ltx23-q8-test', 'gemma3-q4-test', {'diffusion': '8-bit MLX group quantization', 'text': '4-bit MLX group quantization', 'distilled': False}),
}


def _inventory(name):
    # Bundled code-owned metadata; never select a manifest from the weight folder.
    path = Path(__file__).parent / 'Resources' / (name + '.json')
    return json.loads(path.read_bytes())


def _closed_pack(root, inventory, *, cancelled=lambda: False):
    root = Path(root)
    if not root.is_absolute() or not stat.S_ISDIR(root.lstat().st_mode):
        raise ResourceError('Pack must be an explicit physical directory, not a symlink')
    expected = {entry['name'] for entry in inventory['files']}
    allowed = expected | {'.provenance.json', '.download.lock'}
    seen = set()
    for entry in root.iterdir():
        if entry.name not in allowed or not stat.S_ISREG(entry.lstat().st_mode):
            raise ResourceError('Unexpected or incomplete pack entry: ' + entry.name)
        seen.add(entry.name)
    if not expected <= seen:
        raise ResourceError('Required pack files are missing: ' + ', '.join(sorted(expected - seen)))
    # Prevents extra text_encoder.safetensors/config from redirecting 2.3 to Gemma4.
    return verify_inventory(root, inventory, cancelled=cancelled)


def admit_ltx23(profile, *, model, text_encoder, cancelled=lambda: False):
    if profile not in _PROFILES:
        raise ResourceError('No approved local resource inventory for this LTX profile')
    model_name, text_name, precision = _PROFILES[profile]
    model_inventory, text_inventory = _inventory(model_name), _inventory(text_name)
    model_root, text_root = Path(model), Path(text_encoder)
    if not model_root.is_absolute() or not text_root.is_absolute():
        raise ResourceError('Resource roots must be absolute')
    # No output or temporary data belongs in either read-only installed pack.
    if model_root.resolve() == text_root.resolve():
        raise ResourceError('Separate model and encoder packs are required for LTX 2.3')
    model_verified = _closed_pack(model_root, model_inventory, cancelled=cancelled)
    text_verified = _closed_pack(text_root, text_inventory, cancelled=cancelled)
    return {
        'profile': profile, 'component_precision': dict(precision),
        'model': {'repository': model_inventory['repository'], 'revision': model_inventory['revision'], 'verification': model_verified},
        'text_encoder': {'repository': text_inventory['repository'], 'revision': text_inventory['revision'], 'verification': text_verified},
        'inference_verified': False,
        'tokenizer_limit': 1024,
        'streaming_scope': 'all transformer blocks; text encoder and VAE are separate stages, not streamed by this switch',
    }


def _verified_json(root, inventory, name):
    entry = next(row for row in inventory['files'] if row['name'] == name)
    if entry['size'] > 64 * 1024:
        raise ResourceError('Configuration exceeds the bounded parser size: ' + name)
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        with _open_regular(root_fd, name) as file:
            raw = file.read(64 * 1024 + 1)
            if len(raw) != entry['size']:
                raise ResourceError('Configuration changed after verification: ' + name)
    finally:
        os.close(root_fd)
    import hashlib
    identity = entry['hash']
    if identity['algorithm'] == 'git-blob-sha1':
        digest = hashlib.sha1(f"blob {len(raw)}\0".encode('ascii') + raw).hexdigest()
    else:
        digest = hashlib.sha256(raw).hexdigest()
    if digest != identity['digest']:
        raise ResourceError('Configuration changed after verification: ' + name)
    try:
        value = json.loads(raw, object_pairs_hook=_unique)
    except (UnicodeDecodeError, ValueError) as error:
        raise ResourceError('Malformed configuration: ' + name) from error
    if type(value) is not dict:
        raise ResourceError('Configuration must be a JSON object: ' + name)
    return value


def _ltx25_config(root, inventory):
    def positive_finite(value):
        if type(value) not in (int, float):
            return False
        try:
            return math.isfinite(value) and value > 0
        except (OverflowError, ValueError):
            return False

    embedded = _verified_json(root, inventory, 'embedded_config.json')
    transformer = embedded.get('transformer')
    if type(transformer) is not dict or (type(transformer.get('num_layers')) is not int or
            transformer['num_layers'] != 48 or transformer.get('ff_bias') is not False or
            transformer.get('audio_ff_bias') is not False or
            transformer.get('use_keyframes_abs_pos_embedding') is not True or
            transformer.get('share_ff', False) is not False):
        raise ResourceError('LTX 2.5 transformer config must declare 48 blocks, keyframes embedding and no FF bias')
    text = _verified_json(root, inventory, 'text_encoder_config.json')
    tower = text.get('text_config')
    if (text.get('model_type') != 'gemma4_unified' or type(tower) is not dict or
            tower.get('model_type') != 'gemma4_unified_text' or
            type(tower.get('num_kv_shared_layers', 0)) is not int or
            tower.get('num_kv_shared_layers', 0) != 0 or
            tower.get('use_bidirectional_attention', 'vision') == 'all'):
        raise ResourceError('LTX 2.5 requires supported pack-local Gemma4 text configuration')
    layer_count = tower.get('num_hidden_layers')
    layer_types = tower.get('layer_types')
    numeric = ('hidden_size', 'num_attention_heads', 'head_dim', 'global_head_dim',
               'num_key_value_heads', 'num_global_key_value_heads', 'intermediate_size',
               'vocab_size', 'sliding_window')
    if (type(layer_count) is not int or not 1 <= layer_count <= 128 or
            type(layer_types) is not list or len(layer_types) != layer_count or
            any(type(item) is not str or item not in {'sliding_attention', 'full_attention'}
                for item in layer_types) or
            any(type(tower.get(key)) is not int or tower[key] <= 0 for key in numeric) or
            type(tower.get('pad_token_id')) is not int or tower['pad_token_id'] < 0 or
            tower['pad_token_id'] >= tower['vocab_size'] or
            type(tower.get('attention_k_eq_v', False)) is not bool):
        raise ResourceError('Unsupported Gemma4 layer or shape configuration')
    rope = tower.get('rope_parameters')
    if (type(rope) is not dict or
            type(rope.get('sliding_attention')) is not dict or
            rope['sliding_attention'].get('rope_type') != 'default' or
            type(rope.get('full_attention')) is not dict or
            rope['full_attention'].get('rope_type') != 'proportional' or
            any(not positive_finite(value)
                for value in (tower.get('rms_norm_eps'),
                              rope['sliding_attention'].get('rope_theta'),
                              rope['full_attention'].get('rope_theta'))) or
            not positive_finite(rope['full_attention'].get('partial_rotary_factor')) or
            not 0 < rope['full_attention']['partial_rotary_factor'] <= 1):
        raise ResourceError('Unsupported Gemma4 rotary configuration')
    return {'transformer_blocks': 48, 'text_encoder': 'pack-local-gemma4',
            'text_layers': layer_count, 'video_decoder': 'experimental-diffusion'}


def admit_ltx25(profile, *, model, text_encoder=None, cancelled=lambda: False):
    if profile != LTX25_PROFILE or text_encoder is not None:
        raise ResourceError('LTX 2.5 requires its fixed pack-local Gemma4, without an external encoder')
    inventory = _inventory('ltx25-bf16')
    verified = _closed_pack(model, inventory, cancelled=cancelled)
    configuration = _ltx25_config(model, inventory)
    return {
        'profile': profile, 'component_precision': {
            'diffusion_core': 'BF16', 'other_tensors': 'floating only; per-file header dtypes recorded',
            'distilled': False},
        'model': {'repository': inventory['repository'], 'revision': inventory['revision'],
                  'verification': verified},
        'configuration': configuration, 'inference_verified': False,
        'tokenizer_limit': 1024,
        'streaming_scope': 'all transformer blocks; Gemma4 and VAE are separate stages',
    }
