import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'Adapters'))
import ltx_admission as m
from test_resource_inventory import tensor_file

class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.model, self.encoder = self.root/'model', self.root/'text'
        for p in (self.model, self.encoder):p.mkdir()
        self.inventories = {}
        for name,root in [('ltx23-bf16', self.model), ('gemma3-bf16', self.encoder)]:
            data=b'pinned plain resource'; (root/'config.json').write_bytes(data)
            self.inventories[name]={'schema_version':1,'profile':name,'repository':'fixture/'+name,'revision':'a'*40,'files':[{'name':'config.json','size':len(data),'sha256':hashlib.sha256(data).hexdigest(),'tensor_policy':'not_tensor'}]}
        self.lookup=patch.object(m,'_inventory',side_effect=lambda n:self.inventories[n]);self.lookup.start();self.addCleanup(self.lookup.stop)

    def admit(self, **kw):
        return m.admit_ltx23(kw.get('profile',m.FULL_PROFILE),model=kw.get('model',self.model),text_encoder=kw.get('text_encoder',self.encoder))

    def test_exact_roots_without_changes(self):
        before={str(p):p.read_bytes() for root in [self.model,self.encoder] for p in root.iterdir()}
        result=self.admit();self.assertFalse(result['inference_verified']);self.assertEqual(result['component_precision']['text'],'BF16')
        for p,data in before.items():self.assertEqual(Path(p).read_bytes(),data)

    def test_unlisted_gemma4_and_partial_pack_are_refused(self):
        for name in ['text_encoder.safetensors','text_encoder_config.json','.transformer.partial']:
            with self.subTest(name=name):
                p=self.model/name;p.write_text('untrusted')
                try:
                    with self.assertRaises(m.ResourceError):self.admit()
                    self.assertEqual(p.read_text(),'untrusted')
                finally:p.unlink() # only this test-owned fixture

    def test_missing_and_wrong_profile_do_not_fall_back(self):
        with self.assertRaises(m.ResourceError):self.admit(profile='ltx-2.5-dev-bf16-full-v1')
        (self.model/'config.json').unlink()
        with self.assertRaises(m.ResourceError):self.admit()

    def test_alias_overlap_and_extra_symlink_refused(self):
        with self.assertRaises(m.ResourceError):self.admit(text_encoder=self.model)
        alias=self.root/'alias';alias.symlink_to(self.model)
        with self.assertRaises(m.ResourceError):self.admit(model=alias)
        (self.model/'.provenance.json').symlink_to(self.encoder/'config.json')
        with self.assertRaises(m.ResourceError):self.admit()

    def test_full_and_quantized_inventory_identities_are_distinct(self):
        self.lookup.stop()
        self.assertNotEqual(m._inventory('ltx23-bf16')['revision'],m._inventory('ltx23-q8-test')['revision'])
        self.assertNotEqual(m._inventory('gemma3-bf16')['revision'],m._inventory('gemma3-q4-test')['revision'])
        for name in ['ltx23-bf16','gemma3-bf16']:
            self.assertNotIn('quantized_explicit',{e['tensor_policy'] for e in m._inventory(name)['files']})
        for name in ['ltx23-q8-test','gemma3-q4-test']:
            self.assertIn('quantized_explicit',{e['tensor_policy'] for e in m._inventory(name)['files']})


class LTX25SyntheticAdmissionTests(unittest.TestCase):
    """Injected test inventory only; these bytes are not upstream model files."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        config = {'transformer': {'num_layers': 48, 'ff_bias': False, 'audio_ff_bias': False,
                                  'use_keyframes_abs_pos_embedding': True}}
        text = {'model_type': 'gemma4_unified', 'text_config': {
            'model_type': 'gemma4_unified_text', 'num_hidden_layers': 2,
            'layer_types': ['sliding_attention', 'full_attention'],
            'hidden_size': 8, 'num_attention_heads': 2, 'head_dim': 4,
            'global_head_dim': 4, 'num_key_value_heads': 1,
            'num_global_key_value_heads': 1, 'intermediate_size': 16,
            'vocab_size': 32, 'sliding_window': 8, 'pad_token_id': 0,
            'rms_norm_eps': 1e-6,
            'rope_parameters': {'sliding_attention': {'rope_type': 'default', 'rope_theta': 10000.0},
                                'full_attention': {'rope_type': 'proportional', 'rope_theta': 10000.0,
                                                   'partial_rotary_factor': 0.5}}}}
        entries = []
        for name, data, policy in [
            ('embedded_config.json', json.dumps(config).encode(), 'not_tensor'),
            ('text_encoder_config.json', json.dumps(text).encode(), 'not_tensor'),
            ('tokenizer.json', b'{}', 'not_tensor'),
            ('vae_decoder_conv.safetensors', tensor_file([('vae.x', 'F32', 1)]), 'floating_only'),
            ('text_encoder.safetensors', tensor_file([('text.x', 'BF16', 1)]), 'floating_only'),
            ('transformer-dev.safetensors', tensor_file(
                [(f'transformer.transformer_blocks.{i}.ff.proj_in.weight', 'BF16', 1)
                 for i in range(48)] +
                [('transformer.keyframes_abs_pos_embedding', 'BF16', 1)]), 'ltx25_transformer')]:
            (self.root/name).write_bytes(data)
            entries.append({'name': name, 'size': len(data),
                            'hash': {'algorithm': 'sha256', 'digest': hashlib.sha256(data).hexdigest()},
                            'tensor_policy': policy})
        self.inventory = {'schema_version': 1, 'profile': m.LTX25_PROFILE,
                          'repository': 'synthetic/test-only', 'revision': 'a'*40, 'files': entries}
        self.lookup = patch.object(m, '_inventory', return_value=self.inventory)
        self.lookup.start(); self.addCleanup(self.lookup.stop)

    def admit(self):
        return m.admit_ltx25(m.LTX25_PROFILE, model=self.root)

    def replace_file(self, name, data):
        entry = next(e for e in self.inventory['files'] if e['name'] == name)
        (self.root/name).write_bytes(data)
        entry['size'] = len(data)
        entry['hash']['digest'] = hashlib.sha256(data).hexdigest()

    def audio_bias_fixture(self, *, missing_field=False):
        config = json.loads((self.root/'embedded_config.json').read_bytes())
        if missing_field:
            del config['transformer']['audio_ff_bias']
        else:
            config['transformer']['audio_ff_bias'] = True
        self.replace_file('embedded_config.json', json.dumps(config).encode())
        tensors = [(f'transformer.transformer_blocks.{i}.ff.proj_in.weight', 'BF16', 1)
                   for i in range(48)]
        tensors += [(f'transformer.transformer_blocks.{i}.audio_ff.{projection}.bias', 'BF16', 1)
                    for i in range(48) for projection in ('proj_in', 'proj_out')]
        tensors.append(('transformer.keyframes_abs_pos_embedding', 'BF16', 1))
        self.replace_file('transformer-dev.safetensors', tensor_file(tensors))

    def test_synthetic_complete_and_no_external_encoder(self):
        result = self.admit()
        self.assertFalse(result['inference_verified'])
        self.assertEqual(result['configuration']['video_decoder'], 'experimental-diffusion')
        self.assertEqual(result['component_precision']['diffusion_core'], 'BF16')
        with self.assertRaises(m.ResourceError):
            m.admit_ltx25(m.LTX25_PROFILE, model=self.root, text_encoder=self.root)

    def test_missing_gemma_or_conv_selector_fails_before_compute(self):
        for name in ('text_encoder_config.json', 'text_encoder.safetensors',
                     'vae_decoder_conv.safetensors'):
            with self.subTest(name=name):
                file = self.root/name
                with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as held_dir:
                    held = Path(held_dir)/name
                    file.rename(held)
                    try:
                        with self.assertRaisesRegex(m.ResourceError, 'Required pack files are missing: ' + name):
                            self.admit()
                    finally:
                        held.rename(file)

    def test_audio_ff_bias_upstream_default_and_explicit_true(self):
        for missing_field in (True, False):
            with self.subTest(missing_field=missing_field):
                self.audio_bias_fixture(missing_field=missing_field)
                self.assertTrue(self.admit()['configuration']['audio_ff_bias'])

    def test_audio_ff_bias_tensors_must_match_selected_variant(self):
        self.audio_bias_fixture(missing_field=True)
        path = self.root/'transformer-dev.safetensors'
        data = tensor_file(
            [(f'transformer.transformer_blocks.{i}.ff.proj_in.weight', 'BF16', 1)
             for i in range(48)] + [('transformer.keyframes_abs_pos_embedding', 'BF16', 1)])
        self.replace_file(path.name, data)
        with self.assertRaisesRegex(m.ResourceError, 'audio feed-forward bias tensors are missing'):
            self.admit()
        self.audio_bias_fixture()
        config = json.loads((self.root/'embedded_config.json').read_bytes())
        config['transformer']['audio_ff_bias'] = False
        self.replace_file('embedded_config.json', json.dumps(config).encode())
        with self.assertRaisesRegex(m.ResourceError, 'audio feed-forward bias disagrees'):
            self.admit()

    def test_unexpected_quantization_and_malformed_config(self):
        extra = self.root/'quantize_config.json'
        extra.write_text('{}')
        with self.assertRaises(m.ResourceError): self.admit()
        extra.unlink()
        config = next(e for e in self.inventory['files'] if e['name'] == 'embedded_config.json')
        data = b'{"transformer":{}}'
        (self.root/config['name']).write_bytes(data)
        config['size'] = len(data)
        config['hash']['digest'] = hashlib.sha256(data).hexdigest()
        with self.assertRaisesRegex(m.ResourceError, 'transformer config'):
            self.admit()

    def test_core_floating_alone_is_not_bf16(self):
        entry = next(e for e in self.inventory['files'] if e['name'] == 'transformer-dev.safetensors')
        data = tensor_file(
            [(f'transformer.transformer_blocks.{i}.ff.proj_in.weight', 'F32' if i == 0 else 'BF16', 1)
             for i in range(48)] + [('transformer.keyframes_abs_pos_embedding', 'BF16', 1)])
        (self.root/entry['name']).write_bytes(data)
        entry['size'] = len(data)
        entry['hash']['digest'] = hashlib.sha256(data).hexdigest()
        with self.assertRaisesRegex(m.ResourceError, 'core transformer must be BF16'):
            self.admit()

    def test_original_f32_modulation_is_preserved_and_not_a_blanket_float_exception(self):
        # Shapes and names from the pinned original 2.5 header, not a dtype cast.
        base = [(f'transformer.transformer_blocks.{i}.ff.proj_in.weight', 'BF16', 1)
                for i in range(48)] + [('transformer.keyframes_abs_pos_embedding', 'BF16', 1)]
        tables = [
            ('transformer.audio_scale_shift_table', 'F32', 0, [2, 2048]),
            ('transformer.scale_shift_table', 'F32', 0, [2, 4096]),
            ('transformer.transformer_blocks.0.audio_prompt_scale_shift_table', 'F32', 0, [2, 2048]),
            ('transformer.transformer_blocks.0.audio_scale_shift_table', 'F32', 0, [9, 2048]),
            ('transformer.transformer_blocks.0.prompt_scale_shift_table', 'F32', 0, [2, 4096]),
            ('transformer.transformer_blocks.0.scale_shift_table', 'F32', 0, [9, 4096]),
            ('transformer.transformer_blocks.0.scale_shift_table_a2v_ca_audio', 'F32', 0, [5, 2048]),
            ('transformer.transformer_blocks.0.scale_shift_table_a2v_ca_video', 'F32', 0, [5, 4096]),
        ]
        original = tensor_file(base + tables)
        self.replace_file('transformer-dev.safetensors', original)
        self.admit()
        self.assertEqual((self.root/'transformer-dev.safetensors').read_bytes(), original)
        for name, dtype, value, shape in tables:
            for replacement in [(name, 'BF16', value, shape), (name, dtype, value, [1])]:
                with self.subTest(name=name, replacement=replacement):
                    changed = [replacement if entry[0] == name else entry for entry in tables]
                    self.replace_file('transformer-dev.safetensors', tensor_file(base + changed))
                    with self.assertRaisesRegex(m.ResourceError, 'modulation table'):
                        self.admit()
        self.replace_file('transformer-dev.safetensors', tensor_file(base + tables + [
            ('transformer.transformer_blocks.0.unrecognized_scale_shift_table', 'F32', 0, [2, 4096])]))
        with self.assertRaisesRegex(m.ResourceError, 'core transformer must be BF16'):
            self.admit()

if __name__=='__main__':unittest.main()
