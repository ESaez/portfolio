"""mediainfo.py classification and scout.py images."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from helpers import angle_delta, fixtures, hsv_at, hue_to_yaw, needs_ffmpeg, run_script, sun_fixture

import mediainfo  # noqa: E402
import scout  # noqa: E402
from _common import ffmpeg_bin  # noqa: E402


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

    def test_shooting_order(self):
        fx = fixtures()
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            older, newer = folder / "b_photo.png", folder / "a_music.wav"
            shutil.copyfile(fx["photo"], older)
            shutil.copyfile(fx["music"], newer)
            os.utime(older, (1_600_000_000, 1_600_000_000))     # 2020-09-13T12:26:40Z
            os.utime(newer, (1_700_000_000, 1_700_000_000))     # 2023-11-14T22:13:20Z
            tagged = folder / "c_clip.mp4"                      # creation_time metadata beats the mtime
            subprocess.run([ffmpeg_bin(), "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=64x64:r=10:d=0.3",
                            "-metadata", "creation_time=2021-05-06T07:08:09Z", "-pix_fmt", "yuv420p", str(tagged)],
                           check=True)
            result = run_script("mediainfo.py", tmp, "--json-only")
            self.assertEqual(result["summary"]["order"], ["b_photo.png", "c_clip.mp4", "a_music.wav"])
            by_name = {item["name"]: item for item in result["items"]}
            self.assertEqual(by_name["b_photo.png"]["created"], "2020-09-13T12:26:40Z")
            self.assertEqual(by_name["b_photo.png"]["created_from"], "file mtime")
            self.assertEqual(by_name["c_clip.mp4"]["created"], "2021-05-06T07:08:09Z")
            self.assertTrue(by_name["c_clip.mp4"]["created_from"].startswith("metadata"), by_name["c_clip.mp4"])
            named = run_script("mediainfo.py", tmp, "--json-only", "--sort", "name")
            self.assertEqual(named["summary"]["order"], ["a_music.wav", "b_photo.png", "c_clip.mp4"])

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


class ExposureMathTests(unittest.TestCase):
    def test_cell_centres(self):
        self.assertEqual(scout.cell_centre(0, 0), (-165, 75))
        self.assertEqual(scout.cell_centre(6, 3), (15, -15))
        self.assertEqual(scout.cell_centre(11, 5), (165, -75))

    def test_cells_sun_and_clean_ranges(self):
        w, h = scout.SAMPLE_W, scout.SAMPLE_H
        bw, bh = w // scout.CELL_COLS, h // scout.CELL_ROWS
        frame = bytearray([120] * (w * h))                     # usable mid-grey everywhere
        for j in range(bh):                                    # blow out col 8 (yaw 60..90), row 2 (pitch 30..0)
            for i in range(bw):
                frame[(2 * bh + j) * w + 8 * bw + i] = 255
        for row in scout.HORIZON_ROWS:                         # and make col 0's horizon band black
            for j in range(bh):
                for i in range(bw):
                    frame[(row * bh + j) * w + i] = 10
        cells = scout.luma_cells(bytes(frame))
        self.assertEqual(cells[2][8], {"clipped": 1.0, "mean": 255.0})
        self.assertEqual(cells[0][0], {"clipped": 0.0, "mean": 120.0})
        result = scout.analyse_cells(cells)
        self.assertEqual(result["sun"], {"yaw": 75, "pitch": 15, "clipped": 1.0})
        self.assertEqual(result["clean_yaw_ranges"], [[-150, 60], [90, 180]])
        self.assertIn("sun at yaw +75 pitch +15", result["note"])
        flat = scout.analyse_cells(scout.luma_cells(bytes([120] * (w * h))))
        self.assertIsNone(flat["sun"])
        self.assertEqual(flat["clean_yaw_ranges"], [[-180, 180]])
        self.assertIn("no blown-out direction", flat["note"])


@needs_ffmpeg
class ExposureRenderTests(unittest.TestCase):
    def test_synthetic_sun_is_found(self):
        src = sun_fixture()
        with tempfile.TemporaryDirectory() as tmp:
            result = run_script("scout.py", str(src), "--outdir", tmp, "--times", "0.5", "--width", "480")
            self.assertEqual(len(result["exposure"]), 1)
            sample = result["exposure"][0]
            self.assertEqual((sample["sun"]["yaw"], sample["sun"]["pitch"]), (75, 15), sample)
            self.assertGreater(sample["sun"]["clipped"], 0.2)
            item = [i for i in result["items"] if i["kind"] == "exposure"][0]
            self.assertLess(item["cells"][3][2]["clipped"], 0.01)          # yaw -105, pitch -15: the far side

            def clean(yaw):
                return any(a <= yaw < b for a, b in sample["clean_yaw_ranges"])
            self.assertFalse(clean(75))
            self.assertTrue(clean(-105), sample)
            index = json.loads((Path(tmp) / "index.json").read_text())
            self.assertEqual(sum(i["kind"] == "exposure" for i in index), 1)
        with tempfile.TemporaryDirectory() as tmp:
            result = run_script("scout.py", str(src), "--outdir", tmp, "--times", "0.5", "--width", "480", "--no-exposure")
            self.assertEqual(result["exposure"], [])
            self.assertFalse(any(i["kind"] == "exposure" for i in result["items"]))


if __name__ == "__main__":
    unittest.main()
