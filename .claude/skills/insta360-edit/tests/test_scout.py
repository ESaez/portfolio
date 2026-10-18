"""mediainfo.py classification and scout.py images."""

import json
import tempfile
import unittest
from pathlib import Path

from helpers import angle_delta, fixtures, hsv_at, hue_to_yaw, needs_ffmpeg, run_script

import mediainfo  # noqa: E402


class ClassifyTests(unittest.TestCase):
    def test_spherical_metadata_wins(self):
        stream = {"width": 1920, "height": 1080,
                  "side_data_list": [{"side_data_type": "Spherical Mapping", "projection": "equirectangular"}]}
        self.assertEqual(mediainfo.classify_video(stream)[0], "360")

    def test_two_to_one_frames_are_360(self):
        self.assertEqual(mediainfo.classify_video({"width": 5760, "height": 2880})[0], "360")
        self.assertEqual(mediainfo.classify_video({"width": 960, "height": 480})[0], "video")   # too small
        self.assertEqual(mediainfo.classify_video({"width": 1920, "height": 1080})[0], "video")

    def test_rotation(self):
        self.assertEqual(mediainfo.rotation_of({"side_data_list": [{"side_data_type": "Display Matrix", "rotation": -90}]}), 270)
        self.assertEqual(mediainfo.rotation_of({"tags": {"rotate": "90"}}), 90)
        self.assertEqual(mediainfo.rotation_of({}), 0)


@needs_ffmpeg
class MediaInfoTests(unittest.TestCase):
    def test_lists_a_folder(self):
        fx = fixtures()
        result = run_script("mediainfo.py", str(fx["equi"].parent), "--json-only")
        by_name = {item["name"]: item for item in result["items"]}
        self.assertEqual(by_name["equi.mp4"]["type"], "video")        # 960 wide: below the 360 threshold
        self.assertEqual(by_name["equi.mp4"]["width"], 960)
        self.assertEqual(by_name["flat.mp4"]["type"], "video")
        self.assertTrue(by_name["flat.mp4"]["has_audio"])
        self.assertEqual(by_name["photo.png"]["type"], "photo")
        self.assertEqual(by_name["photo.png"]["width"], 1600)
        self.assertEqual(by_name["music.wav"]["type"], "audio")
        self.assertNotIn("params.json", by_name)
        self.assertEqual(result["summary"]["video"], 2)

    def test_insta360_raw_is_flagged(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw = Path(tmp) / "VID_20260101.insv"
            raw.write_bytes(b"\0" * 10)
            result = run_script("mediainfo.py", str(raw), "--json-only")
            self.assertEqual(result["items"][0]["type"], "insta360-raw")
            self.assertIn("Insta360 Studio", result["items"][0]["reason"])


@needs_ffmpeg
class ScoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fx = fixtures()
        cls.tmp = tempfile.TemporaryDirectory(prefix="scout-tests.")
        cls.out = Path(cls.tmp.name)
        cls.result = run_script("scout.py", str(cls.fx["equi"]), "--outdir", str(cls.out), "--every", "4",
                                "--views", "--thumbs", "--width", "800")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_grid_images(self):
        grids = [i for i in self.result["items"] if i["kind"] == "grid"]
        self.assertEqual([g["t"] for g in grids], [0.0, 4.0])
        for grid in grids:
            self.assertTrue(Path(grid["file"]).exists())
            self.assertEqual((grid["width"], grid["height"]), (800, 400))
        # the picture under the grid is still the sphere: the +90° column keeps its hue
        hue, _, _ = hsv_at(Path(grids[0]["file"]), 0, x_frac=0.75, y_frac=0.3)
        self.assertLess(angle_delta(hue_to_yaw(hue, 0.0), 90), 8)

    def test_views_strip(self):
        views = [i for i in self.result["items"] if i["kind"] == "views"]
        self.assertEqual(len(views), 2)
        self.assertEqual((views[0]["width"], views[0]["height"]), (1600, 300))
        # second tile looks at yaw 0, third at yaw +90
        for tile, yaw in ((1, 0), (2, 90)):
            hue, _, _ = hsv_at(Path(views[0]["file"]), 0, x_frac=(tile + 0.5) / 4, y_frac=0.6)
            self.assertLess(angle_delta(hue_to_yaw(hue, 0.0), yaw), 8)

    def test_sheets_and_index(self):
        sheets = [i for i in self.result["items"] if i["kind"] == "sheet"]
        self.assertGreaterEqual(len(sheets), 1)
        self.assertTrue(Path(sheets[0]["file"]).exists())
        index = json.loads((self.out / "index.json").read_text())
        self.assertEqual(len(index), len(self.result["items"]))
        self.assertIn("yaw = x/width*360-180", self.result["reading"])


if __name__ == "__main__":
    unittest.main()
