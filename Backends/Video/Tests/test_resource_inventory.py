"""CPU-only identity and header checks with synthetic resources."""
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parents[1] / 'Adapters'))
from resource_inventory import ResourceError, verify_inventory


def tensor_file(entries):
    offset = 0
    header = {}
    payload = bytearray()
    for entry in entries:
        name, dtype, value = entry[:3]
        shape = entry[3] if len(entry) == 4 else [1]
        width = {'BF16': 2, 'F32': 4, 'I8': 1}[dtype] * math.prod(shape)
        header[name] = {'dtype': dtype, 'shape': shape, 'data_offsets': [offset, offset + width]}
        payload.extend(bytes([value]) * width)
        offset += width
    raw = json.dumps(header).encode()
    return struct.pack('<Q', len(raw)) + raw + payload


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def entry(self, name, data, *, algorithm='sha256', policy='not_tensor'):
        (self.root / name).write_bytes(data)
        digest = (hashlib.sha256(data).hexdigest() if algorithm == 'sha256' else
                  hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest())
        return {'name': name, 'size': len(data), 'hash': {'algorithm': algorithm, 'digest': digest},
                'tensor_policy': policy}

    def verify(self, entries):
        return verify_inventory(self.root, {'schema_version': 1, 'profile': 'synthetic', 'files': entries})

    def test_git_blob_prefix_and_observed_sha256(self):
        data = b'{"fixed":true}'
        entry = self.entry('config.json', data, algorithm='git-blob-sha1')
        result = self.verify([entry])['verified_files'][0]
        self.assertEqual(result['source_hash']['digest'], entry['hash']['digest'])
        self.assertEqual(result['sha256'], hashlib.sha256(data).hexdigest())
        entry['hash']['digest'] = hashlib.sha1(data).hexdigest()  # Wrong: omits blob size prefix.
        with self.assertRaisesRegex(ResourceError, 'Hash mismatch'):
            self.verify([entry])

    def test_same_length_wrong_hash_and_full_profile_quantization(self):
        entry = self.entry('transformer-dev.safetensors', tensor_file([('x', 'BF16', 1)]),
                           policy='floating_only')
        (self.root / entry['name']).write_bytes(tensor_file([('x', 'BF16', 2)]))
        with self.assertRaisesRegex(ResourceError, 'Hash mismatch'):
            self.verify([entry])
        packed = tensor_file([('x.scales', 'F32', 1)])
        entry = self.entry('transformer-dev.safetensors', packed, policy='floating_only')
        with self.assertRaisesRegex(ResourceError, 'quantized'):
            self.verify([entry])

    def test_legacy_sha256_entry_remains_valid(self):
        data = b'legacy 2.3 resource'
        (self.root / 'config.json').write_bytes(data)
        entry = {'name': 'config.json', 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                 'tensor_policy': 'not_tensor'}
        self.assertEqual(self.verify([entry])['verified_files'][0]['sha256'], entry['sha256'])

    def test_fixed_25_manifest_excludes_equal_size_distilled_weights(self):
        path = Path(__file__).parents[1] / 'Adapters/Resources/ltx25-bf16.json'
        inventory = json.loads(path.read_text())
        files = {entry['name']: entry for entry in inventory['files']}
        self.assertEqual(len(files), 19)
        self.assertNotIn('transformer-distilled.safetensors', files)
        self.assertNotIn('vae_encoder_av.safetensors', files)
        dev = files['transformer-dev.safetensors']
        self.assertEqual(dev['size'], 37_985_738_816)  # Distilled has the same size upstream.
        self.assertEqual(dev['hash'], {'algorithm': 'sha256', 'digest':
            'aa94922199890d72f57f7f214d1b5ce4ca1e6203cd3eb1fdac6208f88026a5cd'})
        self.assertEqual(files['embedded_config.json']['hash']['algorithm'], 'git-blob-sha1')


if __name__ == '__main__':
    unittest.main()
