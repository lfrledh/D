"""Pinned LTX 2.3 resource admission, independent of UI and GPU libraries.

Full and quantized development configurations are distinct identities. Resource
identity is not a claim of numerical parity or a successful model execution.
"""
from pathlib import Path
import json
import stat

from resource_inventory import ResourceError, verify_inventory

FULL_PROFILE = 'ltx-2.3-dev-bf16-full-v1'
TEST_PROFILE = 'ltx-2.3-dev-q8-gemma3-q4-test-v1'
_PROFILES = {
    FULL_PROFILE: ('ltx23-bf16', 'gemma3-bf16', {'diffusion': 'BF16', 'text': 'BF16', 'distilled': False}),
    TEST_PROFILE: ('ltx23-q8-test', 'gemma3-q4-test', {'diffusion': '8-bit MLX group quantization', 'text': '4-bit MLX group quantization', 'distilled': False}),
}


def _inventory(name):
    # Bundled code-owned metadata; never select a manifest from the weight folder.
    path = Path(__file__).parent / 'Resources' / (name + '.json')
    return json.loads(path.read_bytes())


def _closed_pack(root, inventory):
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
    return verify_inventory(root, inventory)


def admit_ltx23(profile, *, model, text_encoder):
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
    model_verified = _closed_pack(model_root, model_inventory)
    text_verified = _closed_pack(text_root, text_inventory)
    return {
        'profile': profile, 'component_precision': dict(precision),
        'model': {'repository': model_inventory['repository'], 'revision': model_inventory['revision'], 'verification': model_verified},
        'text_encoder': {'repository': text_inventory['repository'], 'revision': text_inventory['revision'], 'verification': text_verified},
        'inference_verified': False,
        'tokenizer_limit': 1024,
        'streaming_scope': 'all transformer blocks; text encoder and VAE are separate stages, not streamed by this switch',
    }
