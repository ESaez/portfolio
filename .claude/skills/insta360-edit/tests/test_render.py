"""render_project.py: project loading, caching, and the full pipeline on synthetic footage."""

import json
import shutil
import tempfile
import unittest
from pathlib import Path

from helpers import PYTHON, SCRIPTS, dims, duration, fixtures, needs_ffmpeg, run_script

import render_project as rp  # noqa: E402

from _common import FFMPEG_SKILL_DIR, audio_stream, probe  # noqa: E402

have_ffmpeg_skill = (FFMPEG_SKILL_DIR / "scripts" / "join.py").exists()
needs_ffmpeg_skill = unittest.skipUnless(have_ffmpeg_skill, f"ffmpeg-skill is not installed at {FFMPEG_SKILL_DIR}")


def write_project(folder: Path, fx: dict, **overrides) -> Path:
    """A four-clip project: a moving 360 shot, a flat clip, a photo, a static 360 shot (8.0 s with fades)."""
    project = {
        "name": "Test Edit",
        "fps": 15,
        "clips": [
            {"src": str(fx["equi"]), "type": "360", "in": 0, "to": 3,
             "keyframes": [{"t": 0, "yaw": 0, "pitch": 0, "fov": 90}, {"t": 3, "yaw": 90, "pitch": -20, "fov": 80}]},
            {"src": str(fx["flat"]), "in": 1, "to": 3, "anchor": {"x": 0.5, "y": 0.3}},
            {"src": str(fx["photo"]), "duration": 2, "kenburns": {"zoom": "in", "amount": 1.2, "pan": "left"}},
            {"src": str(fx["equi"]), "type": "360", "in": 4, "duration": 2.5, "keyframes": [{"yaw": -90}]},
        ],
        "transitions": {"type": "fade", "duration": 0.5},
        "music": {"src": str(fx["music"]), "gain_db": -16, "duck": True, "fade_out": 1.5, "loop": True},
        "output": {"aspects": ["9:16", "16:9"], "quality": "master", "dir": "deliver"},
    }
    project.update(overrides)
    path = folder / "project.json"
    path.write_text(json.dumps(project, indent=1))
    return path


class ProjectTests(unittest.TestCase):
    def test_canvas_sizes(self):
        master = {"output": {"quality": "master", "uhd": False}}
        self.assertEqual(rp.canvas_for("9:16", master), (1080, 1920))
        self.assertEqual(rp.canvas_for("16:9", master), (1920, 1080))
        self.assertEqual(rp.canvas_for("1:1", master), (1080, 1080))
        self.assertEqual(rp.canvas_for("16:9", {"output": {"quality": "master", "uhd": True}}), (3840, 2160))
        self.assertEqual(rp.canvas_for("9:16", {"output": {"quality": "preview", "uhd": False}}), (540, 960))
        with self.assertRaises(rp.ToolError):
            rp.canvas_for("2:1", master)

    def test_cache_key_is_stable_and_sensitive(self):
        a = rp.cache_key({"step": "clip", "params": {"in": 1, "to": 3}, "canvas": [1080, 1920]})
        b = rp.cache_key({"canvas": [1080, 1920], "params": {"to": 3, "in": 1}, "step": "clip"})
        c = rp.cache_key({"step": "clip", "params": {"in": 1, "to": 3.5}, "canvas": [1080, 1920]})
        self.assertEqual(a, b)
        self.assertNotEqual(a, c)
        self.assertEqual(len(a), 12)

    def test_safe_name(self):
        self.assertEqual(rp.safe_name("Lisbon trip / day 2"), "Lisbon_trip___day_2")
        self.assertEqual(rp.safe_name("  "), "edit")

    def test_load_project_validates(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "project.json"
            path.write_text(json.dumps({"clips": []}))
            with self.assertRaises(rp.ToolError):
                rp.load_project(path)
            path.write_text(json.dumps({"clips": [{"src": "missing.mp4"}]}))
            with self.assertRaises(rp.ToolError):
                rp.load_project(path)
            path.write_text("{not json")
            with self.assertRaises(rp.ToolError):
                rp.load_project(path)

    @needs_ffmpeg
    def test_type_detection_and_spans(self):
        fx = fixtures()
        with tempfile.TemporaryDirectory() as tmp:
            path = write_project(Path(tmp), fx)
            project = rp.load_project(path)
            for clip in project["clips"]:
                clip["_type"] = rp.detect_type(clip)
            types = [c["_type"] for c in project["clips"]]
            self.assertEqual(types, ["360", "video", "photo", "360"])
            spans = [rp.clip_span(c) for c in project["clips"]]
            self.assertEqual(spans, [(0.0, 3.0), (1.0, 2.0), (0.0, 2.0), (4.0, 2.5)])


@needs_ffmpeg
@needs_ffmpeg_skill
class RenderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fx = fixtures()
        cls.tmp = Path(tempfile.mkdtemp(prefix="insta360-render-"))
        cls.project = write_project(cls.tmp, cls.fx)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_dry_run_plans_without_writing(self):
        work = self.tmp / "dry-work"
        result = run_script("render_project.py", str(self.project), "--dry-run", "--work", str(work))
        self.assertTrue(result["ok"] and result["dry_run"])
        self.assertEqual([a["aspect"] for a in result["aspects"]], ["9:16", "16:9"])
        for aspect in result["aspects"]:
            self.assertEqual(len(aspect["clips"]), 4)
            self.assertAlmostEqual(aspect["expected_duration_s"], 8.0, places=2)
            self.assertNotIn("final", aspect)
        self.assertFalse((self.tmp / "deliver").exists())
        self.assertEqual([p for p in work.rglob("*.mp4")], [])

    def test_masters_then_cached_rerun_then_preview(self):
        work = self.tmp / "work"
        result = run_script("render_project.py", str(self.project), "--work", str(work))
        self.assertTrue(result["ok"], result)
        self.assertEqual(len(result["aspects"]), 2)
        for aspect, (w, h) in zip(result["aspects"], [(1080, 1920), (1920, 1080)]):
            final = Path(aspect["final"])
            self.assertTrue(final.exists(), aspect)
            self.assertEqual(final.parent, (self.tmp / "deliver").resolve())   # macOS: /var is /private/var
            self.assertEqual(final.name, f"Test_Edit_{aspect['aspect'].replace(':', 'x')}_{w}x{h}.mp4")
            self.assertEqual(dims(final), (w, h))
            self.assertAlmostEqual(duration(final), 8.0, delta=0.35, msg=aspect)
            self.assertAlmostEqual(aspect["duration_s"], duration(final), delta=0.05)
            self.assertIsNotNone(audio_stream(probe(final)))
            self.assertNotIn("warning", aspect)
            self.assertIsNotNone(aspect["loudness_lufs"], aspect)
            self.assertAlmostEqual(aspect["loudness_lufs"], -14.0, delta=1.5, msg=aspect)
            self.assertEqual([c["cached"] for c in aspect["clips"]], [False] * 4)
            self.assertEqual([c["type"] for c in aspect["clips"]], ["360", "video", "photo", "360"])
            self.assertEqual(aspect["clips"][0]["shot"], "full")      # pan + tilt + zoom
            self.assertEqual(aspect["clips"][3]["shot"], "static")
            for clip in aspect["clips"]:
                self.assertTrue(Path(clip["path"]).exists())
                self.assertTrue(Path(clip["path"] + ".json").exists())

        # the same project again: every clip comes from the cache and the masters are rewritten
        again = run_script("render_project.py", str(self.project), "--work", str(work))
        for aspect in again["aspects"]:
            self.assertEqual([c["cached"] for c in aspect["clips"]], [True] * 4, aspect)
            self.assertTrue(Path(aspect["final"]).exists())
        self.assertLess(again["elapsed_s"], result["elapsed_s"])

        # change one shot: only that clip re-renders
        data = json.loads(self.project.read_text())
        data["clips"][3]["keyframes"] = [{"yaw": 45}]
        self.project.write_text(json.dumps(data))
        changed = run_script("render_project.py", str(self.project), "--aspect", "9:16", "--work", str(work))
        self.assertEqual([c["cached"] for c in changed["aspects"][0]["clips"]], [True, True, True, False])

        # a half-size preview of one aspect
        preview = run_script("render_project.py", str(self.project), "--aspect", "16:9", "--quality", "preview",
                             "--work", str(work))
        aspect = preview["aspects"][0]
        final = Path(aspect["final"])
        self.assertEqual(final.name, "Test_Edit_16x9_960x540_preview.mp4")
        self.assertEqual(dims(final), (960, 540))
        self.assertAlmostEqual(duration(final), 8.0, delta=0.35)

    def test_no_music_and_cut_transitions(self):
        folder = self.tmp / "cuts"
        folder.mkdir()
        project = write_project(folder, self.fx, music=None, transitions={"type": "none"},
                                output={"aspects": ["1:1"], "quality": "preview", "dir": "out"})
        result = run_script("render_project.py", str(project), "--work", str(folder / "work"))
        aspect = result["aspects"][0]
        self.assertEqual(aspect["canvas"], "540x540")
        self.assertAlmostEqual(aspect["expected_duration_s"], 9.5, places=2)
        final = Path(aspect["final"])
        self.assertEqual(final.parent, (folder / "out").resolve())
        self.assertEqual(dims(final), (540, 540))
        self.assertAlmostEqual(duration(final), 9.5, delta=0.35, msg=aspect)
        self.assertNotIn("mixed", aspect)
        self.assertIsNotNone(audio_stream(probe(final)))


if __name__ == "__main__":
    unittest.main()
