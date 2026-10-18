"""The synthetic footage must encode direction the way the other tests assume."""

import unittest

from helpers import (angle_delta, dims, duration, expected_hue, fixtures, hsv_at, hue_to_yaw, needs_ffmpeg,
                     value_to_pitch)


@needs_ffmpeg
class FootageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fx = fixtures()

    def test_sizes_and_durations(self):
        self.assertEqual(dims(self.fx["equi"]), (960, 480))
        self.assertEqual(dims(self.fx["flat"]), (1280, 720))
        self.assertAlmostEqual(duration(self.fx["equi"]), self.fx["seconds"], delta=0.2)
        self.assertAlmostEqual(duration(self.fx["flat"]), self.fx["seconds"], delta=0.2)
        self.assertGreaterEqual(duration(self.fx["music"]), 20)
        self.assertTrue(self.fx["photo"].exists())

    def test_hue_encodes_yaw_and_drifts_with_time(self):
        for seconds in (0.1, 2.0, 5.0):
            hue, sat, _ = hsv_at(self.fx["equi"], seconds)  # centre column = yaw 0
            self.assertGreater(sat, 0.9)
            self.assertLess(angle_delta(hue_to_yaw(hue, seconds), 0), 3, f"at {seconds}s")
        hue, _, _ = hsv_at(self.fx["equi"], 0.1, x_frac=0.75)  # column of yaw +90
        self.assertLess(angle_delta(hue_to_yaw(hue, 0.1), 90), 3)
        self.assertLess(abs(hue - expected_hue(90, 0.1)) * 360 % 360, 3)

    def test_value_encodes_pitch(self):
        _, _, top = hsv_at(self.fx["equi"], 0.1, y_frac=0.05)      # pitch +81
        _, _, mid = hsv_at(self.fx["equi"], 0.1, y_frac=0.5)       # pitch 0
        _, _, low = hsv_at(self.fx["equi"], 0.1, y_frac=0.95)      # pitch -81
        self.assertLess(abs(value_to_pitch(top) - 81), 8)
        self.assertLess(abs(value_to_pitch(mid) - 0), 8)
        self.assertLess(abs(value_to_pitch(low) + 81), 8)


if __name__ == "__main__":
    unittest.main()
