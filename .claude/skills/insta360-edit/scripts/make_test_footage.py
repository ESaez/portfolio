#!/usr/bin/env python3
"""Generate synthetic footage for tests and the installer's self-test.

The 360 clip is an equirectangular video whose colour encodes direction, so a reframed
frame can be checked numerically:

  hue   = yaw        a column at x has hue x/W, i.e. yaw = hue*360 - 180 (cyan = 0°, red = ±180°)
  value = pitch      the top row (pitch +90°) has value 1.0, the bottom row 0.45
  drift             the hue rotates by DRIFT degrees per second, so the absolute time of a
                    frame can be checked too (expected hue = (yaw+180 + DRIFT*t)/360 mod 1)

Audio on the 360 clip is a 440 Hz tone that is on for one second and off for one second,
standing in for speech when testing music ducking.

  make_test_footage.py OUTDIR [--size 960x480] [--fps 15] [--seconds 8] [--drift 22.5] [--only equi]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import ffmpeg_bin, main_wrapper, probe, run, video_stream  # noqa: E402

DEFAULT_DRIFT = 22.5  # degrees of hue per second = a full turn every 16 s


def hue_to_rgb_expressions(hue_expr: str, value_expr: str) -> dict[str, str]:
    """geq expressions turning an HSV colour (S = 1) into RGB, for ffmpeg's `geq` filter."""
    sector = f"mod(({hue_expr})/60,6)"
    return {
        "r": f"255*({value_expr})*clip(abs({sector}-3)-1,0,1)",
        "g": f"255*({value_expr})*clip(2-abs({sector}-2),0,1)",
        "b": f"255*({value_expr})*clip(2-abs({sector}-4),0,1)",
    }


def equirect_filter(drift: float) -> str:
    hue = f"mod(X/W*360+{drift}*T,360)"
    value = "0.45+0.55*(1-Y/H)"
    rgb = hue_to_rgb_expressions(hue, value)
    return f"geq=r='{rgb['r']}':g='{rgb['g']}':b='{rgb['b']}'"


def make_equirect(out: Path, width: int, height: int, fps: float, seconds: float, drift: float) -> None:
    run([
        ffmpeg_bin(), "-hide_banner", "-nostdin", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", f"color=c=black:s={width}x{height}:r={fps}:d={seconds}",
        "-f", "lavfi", "-i", f"aevalsrc=0.3*sin(440*2*PI*t)*gt(mod(t\\,2)\\,1):s=48000:d={seconds}",
        "-filter_complex", f"[0:v]{equirect_filter(drift)},format=yuv420p[v]",
        "-map", "[v]", "-map", "1:a", "-c:v", "libx264", "-crf", "8", "-preset", "veryfast",
        "-c:a", "aac", "-b:a", "128k", "-shortest", str(out),
    ])


def make_flat(out: Path, seconds: float, fps: float) -> None:
    run([
        ffmpeg_bin(), "-hide_banner", "-nostdin", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", f"testsrc2=s=1280x720:r={fps}:d={seconds}",
        "-f", "lavfi", "-i", f"sine=frequency=660:sample_rate=48000:duration={seconds}",
        "-filter_complex", "[1:a]volume=-18dB[a]", "-map", "0:v", "-map", "[a]",
        "-c:v", "libx264", "-crf", "20", "-preset", "veryfast", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "128k", "-shortest", str(out),
    ])


def make_photo(out: Path) -> None:
    run([
        ffmpeg_bin(), "-hide_banner", "-nostdin", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc2=s=1600x1200:r=1:d=1", "-frames:v", "1", str(out),
    ])


def make_music(out: Path, seconds: float) -> None:
    run([
        ffmpeg_bin(), "-hide_banner", "-nostdin", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", f"sine=frequency=220:sample_rate=48000:duration={seconds}",
        "-af", "volume=-20dB", "-c:a", "pcm_s16le", str(out),
    ])


def main() -> dict:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("outdir")
    parser.add_argument("--size", default="960x480", help="equirect size WxH, 2:1 (default 960x480)")
    parser.add_argument("--fps", type=float, default=15.0)
    parser.add_argument("--seconds", type=float, default=8.0)
    parser.add_argument("--drift", type=float, default=DEFAULT_DRIFT, help="hue drift in degrees per second (0 = static)")
    parser.add_argument("--only", choices=["equi", "flat", "photo", "music"], action="append",
                        help="generate only these (default: all)")
    args = parser.parse_args()

    width, height = (int(v) for v in args.size.lower().split("x"))
    if width != 2 * height or width % 2 or height % 2:
        raise SystemExit("--size must be an even 2:1 size, e.g. 960x480")
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    wanted = set(args.only or ["equi", "flat", "photo", "music"])

    files: dict[str, str] = {}
    if "equi" in wanted:
        path = outdir / "equi.mp4"
        make_equirect(path, width, height, args.fps, args.seconds, args.drift)
        files["equi"] = str(path)
    if "flat" in wanted:
        path = outdir / "flat.mp4"
        make_flat(path, args.seconds, args.fps)
        files["flat"] = str(path)
    if "photo" in wanted:
        path = outdir / "photo.png"
        make_photo(path)
        files["photo"] = str(path)
    if "music" in wanted:
        path = outdir / "music.wav"
        make_music(path, max(args.seconds * 3, 20))
        files["music"] = str(path)

    report = {"ok": True, "files": files, "drift_deg_per_s": args.drift, "fps": args.fps, "seconds": args.seconds}
    if "equi" in files:
        stream = video_stream(probe(files["equi"])) or {}
        report["equi_size"] = f"{stream.get('width')}x{stream.get('height')}"
    return report


if __name__ == "__main__":
    sys.exit(main_wrapper(main))
