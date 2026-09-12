"""CPU process fixtures for the fixed export-only engine; no model imports."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tokenize
import unittest

TARGET = Path(__file__).resolve().parents[1] / 'Packaging/prepare_mrt2_engine.py'
VERSIONS = {'mlx':'0.31.1', 'mlx_metal':'0.31.1', 'numpy':'2.3.5', 'sentencepiece':'0.2.2', 'ai_edge_litert':'2.2.0'}

class MRT2PackagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ['D_TEST_TEMP_DIR'])
        self.root = Path(self.tmp.name)
        self.python = self.root/'python'
        (self.python/'bin').mkdir(parents=True)
        (self.python/'bin/python3.12').write_text('fixture')
        (self.python/'bin/python3.12').chmod(0o755)
        (self.python/'lib/python3.12/encodings').mkdir(parents=True)
        (self.python/'lib/python3.12/encodings/__init__.py').write_text('')
        (self.python/'lib/python3.12/LICENSE.txt').write_text('fixture PSF')
        self.site = self.root/'site'; self.site.mkdir()
        for name, version in VERSIONS.items():
            metadata = self.site/f'{name}-{version}.dist-info';metadata.mkdir()
            (metadata/'METADATA').write_text(f'Name: {name}\nVersion: {version}\n')
            (metadata/'LICENSE').write_text('fixture license')
            (metadata/'direct_url.json').write_text('{"url":"file:///private/developer/path"}')
            (metadata/'RECORD').write_text('private installation path')
            if name != 'mlx_metal':
                (self.site/name).mkdir();(self.site/name/'__init__.py').write_text('# fixture')
        self.provider = self.root/'provider';self.provider.mkdir()
        for name in ('d_audio_mrt2_backend.py','d_audio_mrt2_contract.py','d_mrt2_export.py','d_audio_access.py','d_audio_contract.py'):
            (self.provider/name).write_text('# fixture')
        self.vendor = self.root/'vendor';self.vendor.mkdir();(self.vendor/'LICENSE').write_text('Apache fixture')
        self.models = self.root/'models';self.models.mkdir();(self.models/'mrt2-small.json').write_text('{}')
    def tearDown(self): self.tmp.cleanup()
    def run_cli(self, target):
        args=[sys.executable,'-B',str(TARGET)]
        for key, value in [('python-root',self.python),('site-packages',self.site),('provider-directory',self.provider),('vendor-directory',self.vendor),('model-manifests',self.models),('output',target)]: args += ['--'+key,str(value)]
        return subprocess.run(args,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'),capture_output=True,text=True,timeout=20)
    def snapshot(self):
        return {str(p.relative_to(self.root)): hashlib.sha256(p.read_bytes()).hexdigest() for base in [self.python,self.site,self.provider,self.vendor,self.models] for p in base.rglob('*') if p.is_file()}
    def test_memory_compile(self):
        with tokenize.open(TARGET) as f: compile(f.read(),str(TARGET),'exec',dont_inherit=True)
    def test_layout_versions_privacy_and_input_preservation(self):
        before=self.snapshot(); out=self.root/'引擎 空格 🎹';r=self.run_cli(out);self.assertEqual(r.returncode,0,r.stderr)
        manifest=json.loads((out/'engine.json').read_text());self.assertEqual(manifest['kind'],'d-mrt2-music-engine');self.assertEqual(manifest['providerScript'],'provider/d_audio_mrt2_backend.py')
        self.assertEqual(before,self.snapshot()); paths={f['path'] for f in manifest['files']}
        self.assertTrue(all(not p.endswith(('direct_url.json','RECORD')) for p in paths));self.assertEqual(len(paths),len(manifest['files']))
        for item in manifest['files']:
            raw=(out/item['path']).read_bytes();self.assertEqual(hashlib.sha256(raw).hexdigest(),item['sha256']);self.assertEqual(len(raw),item['sizeBytes'])
        for name,version in VERSIONS.items(): self.assertIn(f'python/lib/python3.12/site-packages/{name}-{version}.dist-info/LICENSE',paths)
    def test_unrelated_training_and_path_hooks_not_copied(self):
        (self.site/'jax').mkdir();(self.site/'jax/marker').write_text('do not ship')
        (self.site/'editable.pth').write_text('/private/path')
        out=self.root/'closure';r=self.run_cli(out);self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse((out/'python/lib/python3.12/site-packages/jax').exists());self.assertFalse((out/'python/lib/python3.12/site-packages/editable.pth').exists())
    def test_wrong_metadata_refused(self):
        (self.site/'mlx-0.31.1.dist-info/METADATA').write_text('Name: mlx\nVersion: 0.32.2\n')
        out=self.root/'wrong-version';r=self.run_cli(out);self.assertEqual(r.returncode,2);self.assertFalse(out.exists())
    def test_missing_provider_refused(self):
        (self.provider/'d_mrt2_export.py').unlink();out=self.root/'missing';self.assertEqual(self.run_cli(out).returncode,2);self.assertFalse(out.exists())
    def test_selected_symlink_refused(self):
        (self.site/'mlx/link').symlink_to(self.vendor/'LICENSE');out=self.root/'link';self.assertEqual(self.run_cli(out).returncode,2);self.assertFalse(out.exists())
    def test_existing_and_dangling_outputs_preserved(self):
        out=self.root/'existing';out.mkdir();(out/'saved').write_bytes(b'keep');self.assertEqual(self.run_cli(out).returncode,2);self.assertEqual((out/'saved').read_bytes(),b'keep')
        link=self.root/'dangling';link.symlink_to(self.root/'missing');self.assertEqual(self.run_cli(link).returncode,2);self.assertTrue(link.is_symlink())
    def test_input_overlap_rejected(self):
        before=self.snapshot();self.assertEqual(self.run_cli(self.site/'output').returncode,2);self.assertEqual(before,self.snapshot())

if __name__ == '__main__': unittest.main()
