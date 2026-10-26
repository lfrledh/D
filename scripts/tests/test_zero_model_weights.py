from pathlib import Path
import gzip, hashlib, importlib.util, io, json, tempfile, unittest, zipfile

SPEC = importlib.util.spec_from_file_location('zero', Path(__file__).resolve().parents[1] / 'check-zero-model-weights.py')
zero = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(zero)

class ZeroModelWeightsTests(unittest.TestCase):
    def scan(self, name, data, known=None):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
            return zero.scan(Path(folder), {} if known is None else known)
    def zipped(self, name, data):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_DEFLATED) as z: z.writestr(name, data)
        return buffer.getvalue()
    def test_models_have_no_test_or_size_exemption(self):
        for name in ['model.onnx', 'tests/tiny.ONNX', 'weights.pth.tar', 'M.mlmodelc/coremldata']:
            with self.subTest(name=name), self.assertRaises(zero.WeightError): self.scan(name, b'x')
    def test_renamed_model_containers_and_nested_models(self):
        onnx = b'\x9a\x06\x00\x08\x08\x3a\x00\x42\x00' # ModelProto framing, deliberately tiny
        header = json.dumps({'x': {'dtype': 'F32','shape':[1],'data_offsets':[0,4]}}).encode()
        tensor = len(header).to_bytes(8,'little') + header + b'\0'*4
        for data in [onnx, tensor, b'GGUFany']:
            with self.assertRaises(zero.WeightError): self.scan('renamed.data', data)
        for name in ['model.data','M.mlmodelc/data','test/model.ONNX','archive/data.pkl']:
            with self.assertRaises(zero.WeightError): self.scan('bundle.zip', self.zipped(name, onnx))
    def test_unknown_or_bad_archive_is_not_silently_accepted(self):
        for name, data in [('a.zip', b'bad'), ('a.7z', b'bad'), ('a.zst', b'bad'), ('unknown.bin', b'abc')]:
            with self.subTest(name=name), self.assertRaises(zero.WeightError): self.scan(name, data)
    def test_exact_nonmodel_hash_does_not_allow_changed_bytes_or_weights(self):
        raw = b'reviewed parser table'; known={hashlib.sha256(raw).hexdigest():'parser grammar'}
        self.assertEqual(self.scan('table.bin', raw, known)['files'], 1)
        with self.assertRaises(zero.WeightError): self.scan('table.bin', raw+b'x', known)
        with self.assertRaises(zero.WeightError): self.scan('model.onnx', raw, known)
    def test_known_archive_still_checks_every_member(self):
        raw=self.zipped('test/model.onnx', b'x'); known={hashlib.sha256(raw).hexdigest():'invalid classification'}
        with self.assertRaises(zero.WeightError): self.scan('archive.zip', raw, known)
    def test_finite_expansion(self):
        from unittest.mock import patch
        for data in [self.zipped('text.txt', b'x'*65), gzip.compress(b'x'*65)]:
            with patch.object(zero, 'MAX_EXPANDED',64), self.assertRaises(zero.WeightError): self.scan('a.zip' if data[:2]==b'PK' else 'a.gz',data)
    def test_renamed_and_bom_tokenizer_is_not_code(self):
        raw = json.dumps({'model': {'type': 'Unigram', 'vocab': [['word', -1.5]]}}).encode()
        for prefix in [b'', b'\xef\xbb\xbf', b' ' * 600]:
            with self.assertRaises(zero.WeightError): self.scan('renamed.txt', prefix + raw)
        static = json.dumps({'model': {'type': 'WordLevel', 'vocab': {'off': 0, 'on': 1}}}).encode()
        with self.assertRaises(zero.WeightError): self.scan('static-map.json', static)
        self.scan('static-map.json', static, {hashlib.sha256(static).hexdigest(): 'Explicit hand-written on/off map, no training'})
    def test_directory_members_consume_budget(self):
        from unittest.mock import patch
        data=io.BytesIO()
        with zipfile.ZipFile(data, 'w') as z:
            for i in range(4): z.writestr(str(i)+'/', '')
        with patch.object(zero, 'MAX_MEMBERS',3), self.assertRaises(zero.WeightError): self.scan('a.zip',data.getvalue())
    def test_code_and_documentation_remain(self):
        self.assertEqual(self.scan('provider.py', b'print("model.onnx")')['files'],1)
    def test_embedded_svm_in_native_code_and_archives_is_not_exempt(self):
        raw = b'\xcf\xfa\xed\xfe' + b'\0' * 600 + b'svm_type nu_svr\\nkernel_type rbf\\ntotal_sv 1\\nrho 0.2\\nSV\\n0.5 1:0.3\\n'
        with self.assertRaises(zero.WeightError): self.scan('libquality.dylib', raw)
        for ending in [b'\n', b'\r\n', b'\\r\\n']:
            record = raw[604:].replace(b'\\n', ending).replace(b'total_sv 1', b'total_sv\t1').replace(b'svm_type ', b'svm_type\t')
            with self.assertRaises(zero.WeightError): self.scan('model.json', json.dumps({'model_dict': {'model': record.decode()}}).encode())
        with self.assertRaises(zero.WeightError): self.scan('runtime.zip', self.zipped('renamed.data', raw))
        self.scan('libquality.dylib', b'\xcf\xfa\xed\xfe' + b'vmaf_model_load svm_type total_sv SV')

if __name__ == '__main__': unittest.main()
