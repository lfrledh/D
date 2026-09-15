from __future__ import annotations

import math
import os
from pathlib import Path
import sys
import unittest
import warnings

import numpy as np


PYTHON_DIR = Path(__file__).resolve().parents[1]
if str(PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(PYTHON_DIR))

import d_singing_qixuan as qixuan


class QixuanNumericTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_root = Path(os.environ["D_TEST_TEMP_DIR"])
        self.source_filter = np.zeros((128, 1025), dtype=np.float64)
        self.source_filter[:, :128] = np.eye(128, dtype=np.float64)
        self.target_filter = self.source_filter.copy()

    def _exact_solver(self, matrix, target, *, m, maxiter):
        self.assertIs(matrix, self.source_filter)
        self.assertEqual(m, 10)
        self.assertEqual(maxiter, 200)
        result = np.zeros((1025, target.shape[1]), dtype=np.float64)
        result[:128] = target
        return result

    def test_projection_uses_amplitude_epsilon_and_bounded_blocks(self) -> None:
        log_mel = np.full((128, 33), math.log(2.0), dtype=np.float32)
        checkpoints = 0

        def checkpoint() -> None:
            nonlocal checkpoints
            checkpoints += 1

        mapped, residual = qixuan.project_log_mel(
            log_mel,
            checkpoint=checkpoint,
            source_filter=self.source_filter,
            target_filter=self.target_filter,
            solver=self._exact_solver,
        )
        expected = math.log(math.sqrt(4.0 + 1e-9))
        self.assertEqual(mapped.shape, (128, 33))
        self.assertEqual(mapped.dtype, np.float32)
        np.testing.assert_allclose(mapped, expected, rtol=0, atol=2e-7)
        self.assertEqual(residual, 0.0)
        self.assertEqual(checkpoints, 4)  # before and after each 32-frame NNLS block

    def test_projection_residual_is_global_and_rejects_above_budget(self) -> None:
        def zero_solver(_matrix, target, *, m, maxiter):
            return np.zeros((1025, target.shape[1]), dtype=np.float64)

        with self.assertRaisesRegex(qixuan.QixuanRuntimeError, "relative residual"):
            qixuan.project_log_mel(
                np.zeros((128, 2), dtype=np.float32),
                checkpoint=lambda: None,
                source_filter=self.source_filter,
                target_filter=self.target_filter,
                solver=zero_solver,
            )

    def test_projection_rejects_warning_bad_shape_negative_and_nonfinite(self) -> None:
        def warning_solver(_matrix, target, *, m, maxiter):
            warnings.warn("fixture convergence warning", RuntimeWarning)
            return np.zeros((1025, target.shape[1]), dtype=np.float64)

        with self.assertRaisesRegex(qixuan.QixuanRuntimeError, "NNLS emitted a warning"):
            qixuan.project_log_mel(
                np.zeros((128, 1), dtype=np.float32), checkpoint=lambda: None,
                source_filter=self.source_filter, target_filter=self.target_filter,
                solver=warning_solver,
            )
        invalid_values = [
            np.zeros((127, 1), dtype=np.float32),
            np.zeros((128, 0), dtype=np.float32),
            np.full((128, 1), np.nan, dtype=np.float32),
        ]
        for value in invalid_values:
            with self.subTest(shape=value.shape):
                with self.assertRaises(qixuan.QixuanRuntimeError):
                    qixuan.project_log_mel(
                        value, checkpoint=lambda: None,
                        source_filter=self.source_filter, target_filter=self.target_filter,
                        solver=self._exact_solver,
                    )

    def test_projection_zeros_unsupported_frequency_bins_before_residual(self) -> None:
        observed = None

        def solver(_matrix, target, *, m, maxiter):
            nonlocal observed
            observed = np.ones((1025, target.shape[1]), dtype=np.float64) * 9.0
            observed[:128] = target
            return observed

        mapped, residual = qixuan.project_log_mel(
            np.zeros((128, 1), dtype=np.float32), checkpoint=lambda: None,
            source_filter=self.source_filter, target_filter=self.target_filter, solver=solver,
        )
        self.assertEqual(residual, 0.0)
        self.assertTrue(np.all(observed[128:] == 0.0))
        self.assertTrue(np.isfinite(mapped).all())

    def test_pitch_to_note_arrays_uses_nearest_previous_and_first_for_leading_rest(self) -> None:
        class Alignment:
            note_midi = (None, None, 60, None, 64, None)

        midi, rests, first = qixuan.QixuanEngine._note_arrays(Alignment())
        np.testing.assert_array_equal(midi, [[60, 60, 60, 60, 64, 64]])
        np.testing.assert_array_equal(rests, [[True, True, False, True, False, True]])
        self.assertEqual(first.shape, ())
        self.assertEqual(first.dtype, np.float32)


if __name__ == "__main__":
    unittest.main()
