"""track360.py: geometry, association and smoothing (pure Python), plus Vision on macOS."""

import json
import math
import random
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from helpers import PYTHON, SCRIPTS, run_script

import track360 as tk  # noqa: E402


class GeometryTests(unittest.TestCase):
    def test_tile_centre_and_edges(self):
        self.assertEqual(tk.tile_point_to_direction(0.5, 0.5, 0, 100), (0.0, 0.0))
        yaw, pitch = tk.tile_point_to_direction(0.5, 0.5, 90, 100)
        self.assertAlmostEqual(yaw, 90, places=6)
        yaw, _ = tk.tile_point_to_direction(1.0, 0.5, 0, 100)          # right edge of a 100° view
        self.assertAlmostEqual(yaw, 50, places=6)
        yaw, _ = tk.tile_point_to_direction(0.0, 0.5, 180, 100)        # left edge of the back view wraps
        self.assertAlmostEqual(yaw, 130, places=6)
        _, pitch = tk.tile_point_to_direction(0.5, 0.0, 0, 100)        # top edge looks up
        self.assertAlmostEqual(pitch, 50, places=6)
        _, pitch = tk.tile_point_to_direction(0.5, 1.0, -90, 100)
        self.assertAlmostEqual(pitch, -50, places=6)

    def test_angular_sizes(self):
        self.assertAlmostEqual(tk.angular_height(1.0, 100), 100, places=6)
        self.assertLess(tk.angular_height(0.2, 100), 30)
        self.assertAlmostEqual(tk.angular_distance((0, 0), (90, 0)), 90, places=6)
        self.assertAlmostEqual(tk.angular_distance((179, 0), (-179, 0)), 2, places=6)
        self.assertAlmostEqual(tk.angular_distance((0, 0), (0, 45)), 45, places=6)

    def test_fov_from_subject_size(self):
        self.assertEqual(tk.fov_for_subject(5, 0.22, 60, 110), 60)           # small subject → tightest allowed
        self.assertEqual(tk.fov_for_subject(60, 0.22, 60, 110), 110)         # huge subject → widest allowed
        mid = tk.fov_for_subject(10, 0.22, 60, 110)                          # 10° tall at 22 % → ~73° view
        self.assertTrue(70 < mid < 76, mid)


class TrackingTests(unittest.TestCase):
    @staticmethod
    def walking_person(rate=5.0, seconds=8.0, start_yaw=0.0, end_yaw=120.0, jitter=3.0, gaps=((3.0, 3.4), (6.0, 6.4)),
                       seed=1):
        """Detections of one person walking across the sphere, as the four views would see them."""
        rng = random.Random(seed)
        detections = []
        n = int(seconds * rate)
        for k in range(n + 1):
            t = k / rate
            if any(a <= t < b for a, b in gaps):
                continue
            yaw = start_yaw + (end_yaw - start_yaw) * k / n + rng.uniform(-jitter, jitter)
            pitch = -5 + rng.uniform(-jitter, jitter)
            # which views see this direction (100° views, 10° overlap on each side)?
            for tile, tile_yaw in enumerate(tk.TILE_YAWS):
                rel = tk.wrap180(yaw - tile_yaw)
                if abs(rel) < 48 and abs(pitch) < 48:
                    half = math.tan(math.radians(50))
                    u = (math.tan(math.radians(rel)) / half + 1) / 2
                    v = (-math.tan(math.radians(pitch)) / half + 1) / 2
                    detections.append({"t": round(t, 3), "tile": tile, "kind": "human", "u": u, "v": v,
                                       "w": 0.12, "h": 0.25, "conf": 0.9})
        return detections

    def test_merges_overlapping_views_and_builds_one_track(self):
        directions = tk.to_directions(self.walking_person(), 100)
        tracks = tk.build_tracks(directions)
        people = [tr for tr in tracks if tr["kind"] == "person"]
        self.assertEqual(len(people), 1, [(tr["start"], tr["end"], len(tr["points"])) for tr in tracks])
        track = people[0]
        self.assertAlmostEqual(track["start"], 0.0)
        self.assertAlmostEqual(track["end"], 8.0)
        # one point per sample time even where two views saw the person
        times = [p["t"] for p in track["points"]]
        self.assertEqual(len(times), len(set(times)))

    def test_target_choice(self):
        near = {"kind": "person", "points": [{"t": 0, "yaw": 10, "pitch": 0, "alpha": 20, "conf": 1}],
                "start": 0, "end": 4, "presence_s": 4, "mean_alpha": 20, "mean_yaw": 10, "score": 80}
        far = {"kind": "person", "points": [{"t": 0, "yaw": 150, "pitch": 0, "alpha": 30, "conf": 1}],
               "start": 0, "end": 4, "presence_s": 4, "mean_alpha": 30, "mean_yaw": 150, "score": 120}
        dog = {"kind": "animal", "points": [{"t": 0, "yaw": -60, "pitch": 0, "alpha": 10, "conf": 1}],
               "start": 0, "end": 4, "presence_s": 4, "mean_alpha": 10, "mean_yaw": -60, "score": 40}
        self.assertIs(tk.choose_target([near, far, dog], "person-largest", None), far)
        self.assertIs(tk.choose_target([near, far, dog], "person-central", None), near)
        self.assertIs(tk.choose_target([near, far, dog], "animal", None), dog)
        self.assertIs(tk.choose_target([near, far, dog], "hint", {"t": 0, "yaw": 140}), far)
        self.assertIsNone(tk.choose_target([], "person-largest", None))

    def test_camera_is_smooth_and_follows(self):
        directions = tk.to_directions(self.walking_person(), 100)
        track = tk.choose_target(tk.build_tracks(directions), "person-largest", None)
        samples = tk.sample_path(track, 8.0, 5.0)
        path = tk.camera_path(samples, 5.0, deadband=4, max_slew=30, sigma_s=0.6, subject_height=0.22,
                              fov_min=60, fov_max=110)
        yaws = [p["yaw"] for p in path]
        self.assertLess(abs(yaws[0] - 0), 8)
        self.assertLess(abs(yaws[-1] - 120), 10)
        steps = [b - a for a, b in zip(yaws, yaws[1:])]
        self.assertTrue(all(s >= -0.01 for s in steps), "camera never pans backwards against a steady walk")
        self.assertLessEqual(max(steps), 30 / 5 + 1e-6, "slew limit respected")
        self.assertTrue(all(abs(p["pitch"]) < 20 for p in path))
        self.assertTrue(all(p["fov"] % 5 == 0 and 60 <= p["fov"] <= 110 for p in path))
        frames = tk.keyframes_from_path(path, 0.5, 8.0)
        self.assertEqual(frames[0]["t"], 0.0)
        self.assertEqual(frames[-1]["t"], 8.0)
        self.assertEqual(len(frames), 17)
        self.assertTrue(all(f["ease"] == "linear" for f in frames))

    def test_jitter_inside_deadband_does_not_move_the_camera(self):
        rate = 5.0
        targets = [50 + (1.5 if k % 2 else -1.5) for k in range(40)]
        camera = tk.lazy_follow(targets, rate, deadband=4, max_slew=30)
        self.assertEqual(len(set(round(c, 6) for c in camera)), 1)

    def test_wrap_around_path_is_continuous(self):
        directions = tk.to_directions(self.walking_person(start_yaw=150, end_yaw=210, jitter=1.0, gaps=()), 100)
        track = tk.choose_target(tk.build_tracks(directions), "person-largest", None)
        samples = tk.sample_path(track, 8.0, 5.0)
        path = tk.camera_path(samples, 5.0, deadband=4, max_slew=30, sigma_s=0.6, subject_height=0.22,
                              fov_min=60, fov_max=110)
        steps = [b["yaw"] - a["yaw"] for a, b in zip(path, path[1:])]
        self.assertLess(max(abs(s) for s in steps), 7)               # no 360° jump at the seam
        self.assertLess(abs(tk.wrap180(path[-1]["yaw"] - (-150))), 10)

    def test_cli_from_detections(self):
        with tempfile.TemporaryDirectory() as tmp:
            det = Path(tmp) / "det.json"
            det.write_text(json.dumps({"duration": 8.0, "tile_fov": 100, "detections": self.walking_person()}))
            out = Path(tmp) / "shot.json"
            result = run_script("track360.py", "--from-detections", str(det), "-o", str(out))
            self.assertTrue(result["ok"], result)
            self.assertGreater(result["tracking"]["coverage"], 0.85)
            shot = json.loads(out.read_text())
            self.assertEqual(shot["keyframes"], result["keyframes"])
            self.assertEqual(shot["tracking"]["target"]["kind"], "person")
            empty = Path(tmp) / "empty.json"
            empty.write_text(json.dumps({"duration": 4.0, "detections": []}))
            proc = subprocess.run([PYTHON, str(SCRIPTS / "track360.py"), "--from-detections", str(empty)],
                                  capture_output=True, text=True)
            self.assertEqual(proc.returncode, 1)
            self.assertEqual(json.loads(proc.stdout)["kind"], "no_target")


@unittest.skipUnless(sys.platform == "darwin", "Apple Vision only exists on macOS")
class VisionSmokeTests(unittest.TestCase):
    def test_vision_runs_on_a_blank_frame(self):
        """Exercises PyObjC + Vision through the venv the installer made (skipped if it isn't there)."""
        venv = Path.home() / ".claude" / "skills" / "insta360-edit" / ".venv" / "bin" / "python"
        if not venv.exists():
            self.skipTest("no tracker venv installed")
        proc = subprocess.run([str(venv), str(SCRIPTS / "track360.py"), "--probe-vision"], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        result = json.loads(proc.stdout)
        self.assertTrue(result["vision"], result)
        self.assertEqual(result["blank_frame_detections"], 0)


if __name__ == "__main__":
    unittest.main()
