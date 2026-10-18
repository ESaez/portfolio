"""Test helpers: synthetic fixtures (made once per test run) and pixel read-back."""

from __future__ import annotations

import colorsys
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
SKILL_DIR = TESTS_DIR.parent
SCRIPTS = SKILL_DIR / "scripts"
sys.path.insert(0, str(SCRIPTS))

from _common import ffmpeg_bin, probe, video_stream, duration_of  # noqa: E402

FIXTURE_DIR = Path(os.environ.get("INSTA360_FIXTURE_DIR", TESTS_DIR / ".fixtures"))
FIXTURE_PARAMS = {"size": "960x480", "fps": 15.0, "seconds": 8.0, "drift": 22.5}
PYTHON = sys.executable


def have_ffmpeg() -> bool:
    try:
        ffmpeg_bin()
        ffmpeg_bin("ffprobe")
        return True
    except Exception:
        return False


needs_ffmpeg = unittest.skipUnless(have_ffmpeg(), "ffmpeg is not installed")


def fixtures() -> dict:
    """Paths of the synthetic footage, generating it on first use."""
    stamp = FIXTURE_DIR / "params.json"
    if stamp.exists() and json.loads(stamp.read_text()) == FIXTURE_PARAMS and (FIXTURE_DIR / "equi.mp4").exists():
        return _fixture_paths()
    FIXTURE_DIR.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [PYTHON, str(SCRIPTS / "make_test_footage.py"), str(FIXTURE_DIR), "--size", FIXTURE_PARAMS["size"],
         "--fps", str(FIXTURE_PARAMS["fps"]), "--seconds", str(FIXTURE_PARAMS["seconds"]),
         "--drift", str(FIXTURE_PARAMS["drift"])],
        check=True, capture_output=True, text=True)
    stamp.write_text(json.dumps(FIXTURE_PARAMS))
    return _fixture_paths()


def _fixture_paths() -> dict:
    return {
        "equi": FIXTURE_DIR / "equi.mp4",
        "flat": FIXTURE_DIR / "flat.mp4",
        "photo": FIXTURE_DIR / "photo.png",
        "music": FIXTURE_DIR / "music.wav",
        "drift": FIXTURE_PARAMS["drift"],
        "fps": FIXTURE_PARAMS["fps"],
        "seconds": FIXTURE_PARAMS["seconds"],
    }


def run_script(name: str, *args: str, cwd: Path | None = None, check: bool = True) -> dict:
    """Run one of the skill's scripts and parse its JSON output."""
    proc = subprocess.run([PYTHON, str(SCRIPTS / name), *args], capture_output=True, text=True, cwd=cwd)
    if check and proc.returncode != 0:
        raise AssertionError(f"{name} failed ({proc.returncode}):\nstdout: {proc.stdout[-3000:]}\nstderr: {proc.stderr[-3000:]}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        raise AssertionError(f"{name} printed no JSON:\nstdout: {proc.stdout[-2000:]}\nstderr: {proc.stderr[-2000:]}")


BLOCK = 4  # pixels; averaging a small block smooths compression noise


def rgb_at(video: Path, seconds: float, x_frac: float = 0.5, y_frac: float = 0.5) -> tuple[float, float, float]:
    """Average of a BLOCK×BLOCK square at a fractional position of the frame at `seconds`, as 0–1 RGB."""
    out = subprocess.run(
        [ffmpeg_bin(), "-v", "error", "-ss", f"{seconds:.4f}", "-i", str(video), "-frames:v", "1",
         "-vf", f"crop={BLOCK}:{BLOCK}:floor(iw*{x_frac})-{BLOCK // 2}:floor(ih*{y_frac})-{BLOCK // 2}",
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        capture_output=True, check=True).stdout
    count = BLOCK * BLOCK
    if len(out) < count * 3:
        raise AssertionError(f"no frame at {seconds}s in {video}")
    pixels = [out[i:i + 3] for i in range(0, count * 3, 3)]
    return tuple(sum(p[k] for p in pixels) / count / 255 for k in range(3))  # type: ignore[return-value]


def hsv_at(video: Path, seconds: float, x_frac: float = 0.5, y_frac: float = 0.5) -> tuple[float, float, float]:
    return colorsys.rgb_to_hsv(*rgb_at(video, seconds, x_frac, y_frac))


def expected_hue(yaw: float, absolute_seconds: float, drift: float = FIXTURE_PARAMS["drift"]) -> float:
    """Hue the test pattern shows in direction `yaw` at absolute source time `absolute_seconds`."""
    return ((yaw + 180) / 360 + drift * absolute_seconds / 360) % 1.0


def expected_value(pitch: float) -> float:
    return 0.45 + 0.55 * (pitch + 90) / 180


def hue_to_yaw(hue: float, absolute_seconds: float, drift: float = FIXTURE_PARAMS["drift"]) -> float:
    """Inverse of expected_hue, wrapped into [-180, 180)."""
    yaw = hue * 360 - 180 - drift * absolute_seconds
    return (yaw + 180) % 360 - 180


def value_to_pitch(value: float) -> float:
    return (value - 0.45) / 0.55 * 180 - 90


def angle_delta(a: float, b: float) -> float:
    """Smallest difference between two angles in degrees."""
    return abs((a - b + 180) % 360 - 180)


def dims(video: Path) -> tuple[int, int]:
    stream = video_stream(probe(video)) or {}
    return int(stream.get("width", 0)), int(stream.get("height", 0))


def duration(path: Path) -> float:
    return duration_of(probe(path))
