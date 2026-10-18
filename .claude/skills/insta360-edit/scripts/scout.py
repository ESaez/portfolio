#!/usr/bin/env python3
"""Scout frames of a 360 video so Claude can pick camera directions.

  scout.py SRC --outdir DIR [--every 5 | --times 0,3.5,8] [--in 0 --to 30] [--views] [--thumbs] [--width 1600]

Writes, per sample time:
  grid_<t>.png   the whole sphere (equirectangular) with a 30° yaw/pitch grid and labels.
                 Reading it: yaw = x / width * 360 - 180 (0 at the centre, + to the right),
                 pitch = 90 - y / height * 180 (horizon in the middle, + up). One cell is 30°.
  views_<t>.png  (--views) four flat 100° views looking at yaw -90, 0, 90, 180.
and with --thumbs, contact sheets of the whole clip (one frame every --every seconds).
index.json lists everything. Nothing is modified.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import ToolError, duration_of, ffmpeg_bin, log, main_wrapper, parse_time, probe, run, video_stream  # noqa: E402

MAX_SAMPLES = 40
MAX_THUMBS = 100
VIEW_YAWS = (-90, 0, 90, 180)


def has_filter(name: str) -> bool:
    proc = run([ffmpeg_bin(), "-hide_banner", "-filters"], check=False)
    return any(line.split()[1:2] == [name] for line in proc.stdout.splitlines())


def label(text: str, x: str, y: str, size: int) -> str:
    text = text.replace("\\", "\\\\").replace("'", "\\'").replace(":", "\\:")
    return (f"drawtext=text='{text}':x={x}:y={y}:fontsize={size}:fontcolor=white:"
            f"box=1:boxcolor=black@0.55:boxborderw=3")


def grid_graph(width: int, seconds: float, with_text: bool) -> str:
    height = width // 2
    size = max(12, width // 70)
    chain = [f"[0:v]scale={width}:{height}:flags=area",
             "drawgrid=w=iw/12:h=ih/6:t=1:c=white@0.45",
             "drawbox=x=iw/2-1:y=0:w=2:h=ih:c=yellow@0.9:t=fill",
             "drawbox=x=0:y=ih/2-1:w=iw:h=2:c=yellow@0.9:t=fill"]
    if with_text:
        for index in range(12):
            yaw = -180 + 30 * index
            chain.append(label(f"{yaw:+d}" if yaw else "0", f"w*{index}/12+4", "h/2+4", size))
        for pitch in (60, 30, -30, -60):
            chain.append(label(f"{pitch:+d}", "w/2+4", f"h*{(90 - pitch) / 180:.4f}-{size + 8}", size))
        chain.append(label(f"t={seconds:.2f}s", "10", "10", size + 4))
    return ",".join(chain) + "[out]"


def views_graph(seconds: float, with_text: bool, view_w: int = 400, view_h: int = 300) -> str:
    parts = ["[0:v]split=4[a][b][c][d]"]
    outs = []
    for tag, yaw in zip("abcd", VIEW_YAWS):
        chain = f"[{tag}]v360=input=e:output=flat:yaw={yaw}:pitch=0:d_fov=100:w={view_w}:h={view_h}:interp=line"
        if with_text:
            chain += "," + label(f"yaw {yaw:+d}", "8", "8", 20)
        parts.append(f"{chain}[v{tag}]")
        outs.append(f"[v{tag}]")
    parts.append("".join(outs) + "hstack=inputs=4" + ("," + label(f"t={seconds:.2f}s", "w-tw-10", "8", 20) if with_text else "") + "[out]")
    return ";".join(parts)


def extract(src: Path, seconds: float, graph: str, out: Path, work: Path) -> None:
    (work / f"{out.stem}.graph.txt").write_text(graph + "\n")   # for debugging only
    run([ffmpeg_bin(), "-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-ss", f"{seconds:.3f}", "-i", str(src.resolve()),
         "-frames:v", "1", "-filter_complex", graph, "-map", "[out]", str(out.resolve())], cwd=work)


def thumb_graph(seconds: float, with_text: bool) -> str:
    chain = "[0:v]scale=320:-2"
    if with_text:
        chain += "," + label(f"{seconds:.1f}s", "6", "6", 16)
    return chain + "[out]"


def png_size(path: Path) -> tuple[int, int]:
    stream = video_stream(probe(path)) or {}
    return int(stream.get("width", 0)), int(stream.get("height", 0))


def main() -> dict:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("src")
    parser.add_argument("--outdir", required=True)
    parser.add_argument("--every", type=float, default=5.0, help="seconds between samples (default 5)")
    parser.add_argument("--times", help="comma-separated sample times instead of --every")
    parser.add_argument("--in", dest="in_point", default="0")
    parser.add_argument("--to")
    parser.add_argument("--views", action="store_true", help="also write four flat views per sample")
    parser.add_argument("--thumbs", action="store_true", help="also write contact sheets of the whole clip")
    parser.add_argument("--width", type=int, default=1600, help="grid image width (default 1600)")
    args = parser.parse_args()

    src = Path(args.src).expanduser()
    if not src.exists():
        raise ToolError(f"no such file: {src}", kind="bad_argument")
    info = probe(src)
    stream = video_stream(info)
    if not stream:
        raise ToolError(f"{src} has no video stream", kind="bad_input")
    total = duration_of(info)
    start = parse_time(args.in_point)
    end = min(parse_time(args.to), total) if args.to else total
    if end <= start:
        raise ToolError("--to must be after --in", kind="bad_argument")

    warnings = []
    if args.times:
        times = sorted(set(round(parse_time(t), 3) for t in args.times.split(",") if t.strip()))
    else:
        step = max(args.every, 0.5)
        times = []
        t = start
        while t < end - 0.05:
            times.append(round(t, 3))
            t += step
        if len(times) > MAX_SAMPLES:
            keep = len(times) / MAX_SAMPLES
            times = [times[int(i * keep)] for i in range(MAX_SAMPLES)]
            warnings.append(f"clip is long; kept {MAX_SAMPLES} samples (use --times for specific moments)")
    times = [t for t in times if start <= t < end] or [start]

    outdir = Path(args.outdir).expanduser()
    outdir.mkdir(parents=True, exist_ok=True)
    work = outdir / ".work"
    work.mkdir(exist_ok=True)
    with_text = has_filter("drawtext")
    if not with_text:
        warnings.append("ffmpeg has no drawtext filter: grid images have no labels (brew install ffmpeg-full)")

    width = max(400, args.width // 2 * 2)
    index = []
    for seconds in times:
        tag = f"{seconds:07.2f}".replace(".", "_")
        grid = outdir / f"grid_{tag}.png"
        extract(src, seconds, grid_graph(width, seconds, with_text), grid, work)
        w, h = png_size(grid)
        index.append({"kind": "grid", "t": seconds, "file": str(grid), "width": w, "height": h})
        if args.views:
            views = outdir / f"views_{tag}.png"
            extract(src, seconds, views_graph(seconds, with_text), views, work)
            w, h = png_size(views)
            index.append({"kind": "views", "t": seconds, "file": str(views), "width": w, "height": h, "yaws": list(VIEW_YAWS)})
        log(f"scouted t={seconds:.2f}s")

    if args.thumbs:
        # One quick seek per thumbnail (decoding a whole 5.7K file just to drop frames is slow),
        # then the thumbnails are tiled into contact sheets of 20.
        step = max(args.every, 1.0)
        for old in list(outdir.glob("sheet_*.png")) + list(work.glob("thumb_*.png")):
            old.unlink()
        thumb_times = []
        t = start
        while t < end - 0.05 and len(thumb_times) < MAX_THUMBS:
            thumb_times.append(round(t, 3))
            t += step
        for number, seconds in enumerate(thumb_times):
            extract(src, seconds, thumb_graph(seconds, with_text), work / f"thumb_{number:03d}.png", work)
        run([ffmpeg_bin(), "-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-framerate", "1",
             "-i", str((work / "thumb_%03d.png").resolve()), "-vf", "tile=5x4:padding=4:margin=4",
             "-fps_mode", "passthrough", str((outdir / "sheet_%02d.png").resolve())])
        for sheet in sorted(outdir.glob("sheet_*.png")):
            w, h = png_size(sheet)
            index.append({"kind": "sheet", "file": str(sheet), "width": w, "height": h, "seconds_per_frame": step,
                          "first_t": thumb_times[0] if thumb_times else start})

    (outdir / "index.json").write_text(json.dumps(index, indent=2))
    return {"ok": True, "src": str(src), "duration": round(total, 3), "samples": times, "labels": with_text,
            "reading": "yaw = x/width*360-180 (+right), pitch = 90-y/height*180 (+up); one cell = 30°",
            "index": str(outdir / "index.json"), "items": index, "warnings": warnings}


if __name__ == "__main__":
    sys.exit(main_wrapper(main))
