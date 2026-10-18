#!/usr/bin/env python3
"""Quick end-to-end check used by install.sh: synthetic 360 footage in, a reframed frame out.

Verifies that this machine's ffmpeg really reprojects the sphere the way the skill expects:
a flat view aimed at yaw +90° must show the colour of the +90° column of the test pattern.
"""

from __future__ import annotations

import colorsys
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import FFMPEG_SKILL_DIR, ToolError, ffmpeg_bin, main_wrapper, run  # noqa: E402

SCRIPTS = Path(__file__).resolve().parent


def centre_hsv(video: Path, seconds: float) -> tuple[float, float, float]:
    out = subprocess.run(
        [ffmpeg_bin(), "-v", "error", "-ss", str(seconds), "-i", str(video), "-frames:v", "1",
         "-vf", "crop=2:2:iw/2-1:ih/2-1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        capture_output=True, check=True).stdout
    pixels = [out[i:i + 3] for i in range(0, 12, 3)]
    r, g, b = (sum(p[k] for p in pixels) / 4 / 255 for k in range(3))
    return colorsys.rgb_to_hsv(r, g, b)


def main() -> dict:
    checks: dict[str, str] = {}
    if not (FFMPEG_SKILL_DIR / "scripts" / "sphere.py").exists():
        raise ToolError(f"ffmpeg-skill is not installed at {FFMPEG_SKILL_DIR}", kind="missing_tool")
    checks["ffmpeg-skill"] = str(FFMPEG_SKILL_DIR)

    with tempfile.TemporaryDirectory(prefix="insta360-selftest.") as tmp:
        work = Path(tmp)
        run([sys.executable, str(SCRIPTS / "make_test_footage.py"), str(work), "--only", "equi",
             "--size", "480x240", "--fps", "10", "--seconds", "2", "--drift", "0"])
        src = work / "equi.mp4"
        view = work / "view.mp4"
        # Static view straight at yaw +90°, pitch 0: the centre must be the hue of x = 0.75 W.
        run([ffmpeg_bin(), "-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", str(src),
             "-vf", "v360=input=e:output=flat:yaw=90:pitch=0:d_fov=90:w=320:h=180:interp=lanczos,format=yuv420p",
             "-frames:v", "5", "-c:v", "libx264", "-crf", "10", str(view)])
        hue, sat, value = centre_hsv(view, 0.2)
        expected_hue = (90 + 180) / 360
        error_deg = abs(((hue - expected_hue + 0.5) % 1.0) - 0.5) * 360
        if error_deg > 6:
            raise ToolError(f"v360 aimed at yaw 90 showed hue {hue:.3f} (expected {expected_hue:.3f}, off by {error_deg:.1f}°)",
                            kind="selftest_failed")
        checks["v360 reframe"] = f"ok (yaw error {error_deg:.1f}°, value {value:.2f})"

    return {"ok": True, "checks": checks}


if __name__ == "__main__":
    sys.exit(main_wrapper(main))
