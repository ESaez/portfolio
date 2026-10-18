"""reframe360.py: keyframe maths without ffmpeg, and real renders checked pixel by pixel."""

import json
import math
import tempfile
import unittest
from pathlib import Path

from helpers import (angle_delta, dims, duration, fixtures, hsv_at, hue_to_yaw, needs_ffmpeg, run_script,
                     value_to_pitch)

import reframe360 as rf  # noqa: E402  (tests/helpers.py puts scripts/ on sys.path)


def kf(t, yaw=0.0, pitch=0.0, fov=90.0, roll=0.0, ease="smooth"):
    return {"t": t, "yaw": yaw, "pitch": pitch, "fov": fov, "roll": roll, "ease": ease}


def smoothstep(u):
    u = min(max(u, 0.0), 1.0)
    return u * u * (3 - 2 * u)


class KeyframeMathTests(unittest.TestCase):
    def test_shortest_arc(self):
        self.assertEqual(rf.shortest_delta(150, -150), 60)
        self.assertEqual(rf.shortest_delta(-150, 150), -60)
        self.assertEqual(rf.shortest_delta(10, 20), 10)
        self.assertEqual(rf.unwrap([150, -150, -90]), [150, 210, 270])

    def test_normalize_sorts_fills_and_validates(self):
        frames = rf.normalize_keyframes([{"t": 4, "yaw": 190}, {"t": 0}])
        self.assertEqual([f["t"] for f in frames], [0, 4])
        self.assertEqual(frames[1]["yaw"], -170)
        self.assertEqual(frames[0]["fov"], 90)
        self.assertEqual(frames[0]["ease"], "smooth")
        with self.assertRaises(rf.ToolError):
            rf.normalize_keyframes([{"t": 0, "pitch": 95}])
        with self.assertRaises(rf.ToolError):
            rf.normalize_keyframes([{"t": 0, "fov": 10}])
        with self.assertRaises(rf.ToolError):
            rf.normalize_keyframes([{"t": -1}])
        with self.assertRaises(rf.ToolError):
            rf.normalize_keyframes([{"t": 0, "ease": "bounce"}])

    def test_diagonal_fov(self):
        d = rf.diagonal_fov(90, 1920, 1080)
        self.assertAlmostEqual(d, 97.83, places=1)
        h, v = rf.horizontal_vertical_fov(d, 1920, 1080)
        self.assertAlmostEqual(h, 90, places=2)
        self.assertAlmostEqual(v, 58.7, places=1)
        # portrait keeps the same diagonal: the 16:9 camera turned sideways
        self.assertAlmostEqual(rf.diagonal_fov(90, 1080, 1920), d, places=6)
        h9, v9 = rf.horizontal_vertical_fov(d, 1080, 1920)
        self.assertAlmostEqual(h9, v, places=2)
        self.assertAlmostEqual(v9, h, places=2)
        # portrait zoom tightens it
        self.assertLess(rf.diagonal_fov(90, 1080, 1920, portrait_zoom=1.2), d)
        self.assertAlmostEqual(rf.diagonal_fov(90, 1920, 1080, portrait_zoom=1.2), d)

    def test_classification(self):
        self.assertEqual(rf.classify([kf(0, 30)]), "static")
        self.assertEqual(rf.classify([kf(0, 30), kf(4, 30)]), "static")
        self.assertEqual(rf.classify([kf(0, 0), kf(4, 90)]), "pan")
        self.assertEqual(rf.classify([kf(0, 0), kf(4, 90, pitch=-10)]), "full")
        self.assertEqual(rf.classify([kf(0, 0, fov=90), kf(4, 0, fov=70)]), "full")

    def test_scroll_expression_wraps_and_eases(self):
        frames = rf.normalize_keyframes([kf(0, 150), kf(4, -150)])
        expr = rf.scroll_x_expression(frames)
        self.assertIn("lerp(150,210,", expr)          # shortest path goes through 180
        self.assertIn("st(0,clip((t-0)/4,0,1))*ld(0)*(3-2*ld(0))", expr)
        self.assertTrue(expr.startswith("(in_w/2)*mod(mod("))
        linear = rf.scroll_x_expression(rf.normalize_keyframes([kf(0, 0, ease="linear"), kf(2, 90)]))
        self.assertIn("lerp(0,90,clip((t-0)/2,0,1))", linear)
        hold = rf.scroll_x_expression(rf.normalize_keyframes([kf(0, 0, ease="hold"), kf(2, 90)]))
        self.assertIn("if(lt(t,2),0,90)", hold)

    def test_sendcmd_file(self):
        frames = rf.normalize_keyframes([kf(0, 0, pitch=0, fov=90), kf(3, 60, pitch=-30, fov=70), kf(5, 60, pitch=-30, fov=70)])
        d = [rf.diagonal_fov(f["fov"], 1920, 1080) for f in frames]
        text = rf.sendcmd_lines(frames, "v360@cam", d, animate_yaw=False)
        lines = text.strip().splitlines()
        d0, d1 = rf.fmt(d[0]), rf.fmt(d[1])
        self.assertEqual(lines[0], f"0 [enter] v360@cam reset_rot 1, [enter] v360@cam pitch 0, [enter] v360@cam roll 0, "
                                   f"[enter] v360@cam d_fov {d0};")
        self.assertEqual(lines[1], "0.000000-3.000000 [expr] v360@cam pitch 'lerp(0,-30,TI*TI*(3-2*TI))', "
                                   f"[expr] v360@cam d_fov 'lerp({d0},{d1},TI*TI*(3-2*TI))';")
        self.assertEqual(lines[2], f"3.000000 [enter] v360@cam pitch -30, [enter] v360@cam d_fov {d1};")
        self.assertEqual(len(lines), 3)                 # the static 3→5 s segment emits nothing
        self.assertNotIn("yaw", text)                   # yaw goes through the scroll, never sendcmd
        with_yaw = rf.sendcmd_lines(frames, "v360@cam", d, animate_yaw=True)
        self.assertIn("[expr] v360@cam yaw 'mod(mod(lerp(180,240,TI*TI*(3-2*TI)),360)+360,360)-180'", with_yaw)

    def test_zero_length_segments_become_cuts(self):
        frames = rf.normalize_keyframes([kf(0, 0), kf(2, 90), kf(2, -90), kf(4, -90)])
        self.assertEqual(len(rf.segments(frames)), 2)
        expr = rf.scroll_x_expression(frames)
        self.assertNotIn("/0,", expr)
        text = rf.sendcmd_lines(rf.normalize_keyframes([kf(0, pitch=0), kf(2, pitch=20), kf(2, pitch=-40)]), "v360@cam",
                                [97.83] * 3, animate_yaw=False)
        self.assertNotIn("2.000000-2.000000", text)

    def test_output_spec_parsing(self):
        self.assertEqual(rf.parse_output("16:9=a.mp4")[:2], (1920, 1080))
        self.assertEqual(rf.parse_output("9:16=b.mp4")[:2], (1080, 1920))
        self.assertEqual(rf.parse_output("640x360=c.mp4")[:2], (640, 360))
        with self.assertRaises(rf.ToolError):
            rf.parse_output("641x360=c.mp4")
        with self.assertRaises(rf.ToolError):
            rf.parse_output("c.mp4")

    def test_failed_command_detection(self):
        log = "x\n[Parsed_sendcmd_0] Command reply for command #0: ret:Success res:\n" \
              "[Parsed_sendcmd_0] Command reply for command #0: ret:Undefined error: 0 res:\n" \
              "[Parsed_sendcmd_0] Command reply for command #1: ret:Numerical result out of range res:\n" \
              "[Parsed_sendcmd_0] Command reply for command #1: ret:Result too large res:\n"
        self.assertEqual(len(rf.check_command_replies(log)), 2)
        self.assertEqual(rf.count_successful_replies(log), 2)


@needs_ffmpeg
class RenderTests(unittest.TestCase):
    """Renders on the synthetic sphere; the centre pixel's hue/value must match the camera."""

    @classmethod
    def setUpClass(cls):
        cls.fx = fixtures()
        cls.tmp = tempfile.TemporaryDirectory(prefix="reframe-tests.")
        cls.out = Path(cls.tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def reframe(self, name, keyframes, *extra, in_point="0", duration="6", sizes=("320x180",)):
        kf_path = self.out / f"{name}.json"
        kf_path.write_text(json.dumps({"keyframes": keyframes}))
        outputs = []
        for size in sizes:
            outputs += ["--output", f"{size}={self.out / f'{name}_{size}.mp4'}"]
        result = run_script("reframe360.py", str(self.fx["equi"]), "--in", in_point, "--duration", duration,
                            "--keyframes", str(kf_path), "--no-hw", *outputs, *extra)
        self.assertTrue(result["ok"], result)
        return result

    # Hue (yaw) survives compression well; brightness (pitch) is noisier, hence the wider tolerance.
    def check_direction(self, video, t_rel, yaw, pitch, in_point=0.0, yaw_tol=6, pitch_tol=12):
        hue, sat, value = hsv_at(video, t_rel)
        self.assertGreater(sat, 0.8, f"{video} at {t_rel}s is not a saturated test colour")
        got_yaw = hue_to_yaw(hue, in_point + t_rel)
        self.assertLess(angle_delta(got_yaw, yaw), yaw_tol, f"{video} at {t_rel}s: yaw {got_yaw:.1f}, expected {yaw:.1f}")
        got_pitch = value_to_pitch(value)
        self.assertLess(abs(got_pitch - pitch), pitch_tol, f"{video} at {t_rel}s: pitch {got_pitch:.1f}, expected {pitch:.1f}")

    def test_static_shot_sign_convention(self):
        result = self.reframe("static", [kf(0, 90, pitch=30)], duration="1")
        self.assertEqual(result["kind"], "static")
        video = Path(result["outputs"][0]["path"])
        self.assertEqual(dims(video), (320, 180))
        self.check_direction(video, 0.3, 90, 30)       # +yaw = right of centre, +pitch = up

    def test_pan_follows_eased_keyframes(self):
        result = self.reframe("pan", [kf(0, 0), kf(4, 120)], duration="6")
        self.assertEqual(result["kind"], "pan")
        video = Path(result["outputs"][0]["path"])
        for t in (0.2, 1.0, 2.0, 3.0, 3.8, 5.5):
            self.check_direction(video, t, 120 * smoothstep(t / 4), 0)

    def test_pan_wraps_the_short_way(self):
        result = self.reframe("wrap", [kf(0, 150), kf(4, -150)], duration="5")
        video = Path(result["outputs"][0]["path"])
        self.check_direction(video, 2.0, 180, 0)        # half-way through the short arc, not at 0
        self.check_direction(video, 4.5, -150, 0)

    def test_tilt_and_zoom_through_sendcmd(self):
        result = self.reframe("tilt", [kf(0, 30, pitch=0, fov=90), kf(3, 30, pitch=-40, fov=70)], duration="4")
        self.assertEqual(result["kind"], "full")
        out = result["outputs"][0]
        self.assertGreater(out["commands_ok"], 10)
        video = Path(out["path"])
        for t in (0.2, 1.5, 2.8, 3.6):
            self.check_direction(video, t, 30, -40 * smoothstep(t / 3))

    def test_pan_and_tilt_together_match_static_v360(self):
        """A moving camera that ends at yaw 90 / pitch -30 must show what a static v360 shows there."""
        moving = self.reframe("moving", [kf(0, 0, pitch=0), kf(2, 90, pitch=-30), kf(4, 90, pitch=-30)], duration="4")
        static = self.reframe("static2", [kf(0, 90, pitch=-30)], duration="4")
        for frac in (0.5, 0.8):
            for t in (3.0, 3.5):
                hue_a, _, val_a = hsv_at(Path(moving["outputs"][0]["path"]), t, x_frac=frac)
                hue_b, _, val_b = hsv_at(Path(static["outputs"][0]["path"]), t, x_frac=frac)
                self.assertLess(angle_delta(hue_a * 360, hue_b * 360), 4)
                self.assertLess(abs(val_a - val_b), 0.05)

    def test_in_point_offsets_the_source_time(self):
        """With --in 2 the camera timeline restarts at 0 but the source content is 2 s later."""
        result = self.reframe("offset", [kf(0, 0), kf(2, 60)], in_point="2", duration="3")
        video = Path(result["outputs"][0]["path"])
        self.check_direction(video, 0.2, 60 * smoothstep(0.1), 0, in_point=2.0)
        self.check_direction(video, 2.5, 60, 0, in_point=2.0)
        self.assertAlmostEqual(duration(video), 3.0, delta=0.15)

    def test_both_aspects_and_v360_pan_mode(self):
        result = self.reframe("aspects", [kf(0, -60), kf(3, 60)], duration="4", sizes=("320x180", "180x320"))
        paths = [Path(o["path"]) for o in result["outputs"]]
        self.assertEqual(dims(paths[0]), (320, 180))
        self.assertEqual(dims(paths[1]), (180, 320))
        for video in paths:
            self.check_direction(video, 3.5, 60, 0)
        alt = self.reframe("v360pan", [kf(0, -60), kf(3, 60)], "--pan", "v360", duration="4")
        self.assertIn("cmds", alt["outputs"][0])
        self.check_direction(Path(alt["outputs"][0]["path"]), 1.5, 0, 0)
        self.check_direction(Path(alt["outputs"][0]["path"]), 3.5, 60, 0)

    def test_preview_mode_writes_overlay_and_sheet(self):
        result = self.reframe("preview", [kf(0, 0), kf(3, 90, pitch=-20)], "--preview", "0.5", duration="4",
                              sizes=("640x360",))
        out = result["outputs"][0]
        video = Path(out["path"])
        self.assertEqual(dims(video), (320, 180))
        self.assertTrue(out["sheets"] and Path(out["sheets"][0]).exists())

    def test_dry_run_renders_nothing(self):
        result = self.reframe("dry", [kf(0, 0), kf(3, 90, pitch=-20)], "--dry-run", duration="4")
        self.assertTrue(result["dry_run"])
        self.assertFalse(Path(result["outputs"][0]["path"]).exists())
        self.assertIn("sendcmd=f=", result["outputs"][0]["graph"])
        self.assertIn("v360@cam", result["outputs"][0]["cmds"])


if __name__ == "__main__":
    unittest.main()
