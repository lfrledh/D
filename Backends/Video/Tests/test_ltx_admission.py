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

if __name__=='__main__':unittest.main()
