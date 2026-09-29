"""CPU execution of actual pinned tokenizer methods with tensor/tokenizer doubles.

This checks the narrow upstream overflow patch, not tokenizer/model parity.
D_LTX_TOKEN_GUARD_SOURCE must name an explicitly prepared upstream source tree.
"""
import ast
import os
from pathlib import Path
from types import SimpleNamespace
import unittest


@unittest.skipUnless(os.environ.get('D_LTX_TOKEN_GUARD_SOURCE'), 'explicit pinned source tree required')
class TokenGuardTests(unittest.TestCase):
    def methods(self):
        root = Path(os.environ['D_LTX_TOKEN_GUARD_SOURCE'])
        for filename in ('base_encoder.py', 'gemma4_encoder.py'):
            path = root / 'packages/ltx-core-mlx/src/ltx_core_mlx/text_encoders/gemma/encoders' / filename
            tree = ast.parse(path.read_text(), filename=str(path))
            method = next(n for cls in tree.body if isinstance(cls, ast.ClassDef)
                          for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == 'tokenize')
            # Compile only the inspected upstream method, never import GPU packages.
            method.decorator_list = []
            module = ast.Module(body=[method], type_ignores=[])
            ast.fix_missing_locations(module)
            ns = {'mx': SimpleNamespace(array=lambda x: x), 'TOKENIZER_MAX_LENGTH': 1024}
            exec(compile(module, str(path), 'exec', dont_inherit=True), ns)
            yield filename, ns['tokenize']

    def test_overflow_is_rejected_not_silently_truncated(self):
        for name, method in self.methods():
            with self.subTest(engine=name):
                tokenizer = SimpleNamespace(encode=lambda text: [1, 2, 3, 4, 5], pad_token_id=0)
                with self.assertRaisesRegex(ValueError, '5.*4'):
                    method(SimpleNamespace(_tokenizer=tokenizer), 'oversized', 4)

    def test_valid_padding_and_upstream_normalization_unchanged(self):
        for name, method in self.methods():
            with self.subTest(engine=name):
                seen = []
                def encode(text):
                    seen.append(text)
                    return [42, 43]
                tokenizer = SimpleNamespace(encode=encode, pad_token_id=7)
                result = method(SimpleNamespace(_tokenizer=tokenizer), '  中文 🧑🏽‍🎨  ', 4)
                self.assertEqual(result, ([[7, 7, 42, 43]], [[0, 0, 1, 1]]))
                self.assertEqual(seen, ['中文 🧑🏽‍🎨'])

    def test_exact_budget_is_not_changed(self):
        for name, method in self.methods():
            with self.subTest(engine=name):
                tokenizer = SimpleNamespace(encode=lambda text: [8, 9, 10, 11], pad_token_id=0)
                self.assertEqual(method(SimpleNamespace(_tokenizer=tokenizer), 'exact', 4),
                                 ([[8, 9, 10, 11]], [[1, 1, 1, 1]]))

if __name__ == '__main__':
    unittest.main()
