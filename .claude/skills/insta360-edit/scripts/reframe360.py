#!/usr/bin/env python3
"""Reframe an equirectangular 360° video into a flat video with a keyframed virtual camera.

  reframe360.py SRC --in 12.5 --to 20 --keyframes shot.json --output 16:9=c03_16x9.mp4 --output 9:16=c03_9x16.mp4
  reframe360.py SRC --kf '[{"t":0,"yaw":0,"pitch":0,"fov":90},{"t":4,"yaw":120,"pitch":-20,"fov":80}]' --output 1920x1080=out.mp4
  reframe360.py SRC ... --preview 0.5          # fast, small, with a time/yaw/pitch/fov overlay and a contact sheet
  reframe360.py SRC ... --dry-run              # print the filter graph and command file, render nothing

Keyframes (times are seconds from the clip's in-point; values hold before the first and after
the last; "ease" is how to move towards the NEXT keyframe: smooth (default), linear or hold):

  {"keyframes": [{"t": 0, "yaw": 0, "pitch": 0, "roll": 0, "fov": 90, "ease": "smooth"}, ...]}

Conventions: yaw +right/−left in degrees [-180, 180] (0 = the centre of the equirect frame),
pitch +up [-90, 90], roll clockwise [-180, 180], fov = horizontal field of view of the 16:9
version [30, 120]; every other output size keeps the same diagonal field of view, so the subject
has the same size on screen (portrait can be tightened with --portrait-zoom).

How it renders (verified on ffmpeg 6.1):
  * a static shot is one `v360` filter;
  * pans (yaw changes) are a horizontal scroll of the sphere, exact and free: `hstack` two copies
    and `crop` with an x expression evaluated every frame (`t`), then `v360` with yaw 0;
  * tilt, roll and zoom changes are sent to `v360` as `sendcmd` commands, only in the segments
    where they change; `reset_rot=1` makes those commands absolute.
  `sendcmd` ignores failed commands silently, so ffmpeg runs at verbose log level and every
  "Command reply" line is checked.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import (ToolError, duration_of, even, ffmpeg_bin, frame_rate, log, main_wrapper, parse_time, probe,  # noqa: E402
                     run, video_stream)

ASPECT_SIZES = {"16:9": (1920, 1080), "9:16": (1080, 1920), "1:1": (1080, 1080), "4:5": (1080, 1350),
                "4:3": (1440, 1080), "3:4": (1080, 1440)}
LIMITS = {"yaw": (-180.0, 180.0), "pitch": (-90.0, 90.0), "roll": (-180.0, 180.0), "fov": (30.0, 120.0)}
EASES = ("smooth", "linear", "hold")
MIN_SEGMENT = 0.002          # seconds; shorter gaps between keyframes are hard cuts
INTERMEDIATE_CRF = 12
PREVIEW_CRF = 28


# --- keyframes ---------------------------------------------------------------------------------

def load_keyframes(text_or_path: str) -> list[dict]:
    """Keyframes from a JSON file path or an inline JSON string."""
    raw = text_or_path.strip()
    if not raw.startswith(("[", "{")):
        try:
            raw = Path(text_or_path).read_text()
        except OSError as error:
            raise ToolError(f"can't read keyframes: {error}", kind="bad_argument")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ToolError(f"keyframes are not valid JSON: {error}", kind="bad_argument")
    if isinstance(data, dict):
        data = data.get("keyframes", data)
    if not isinstance(data, list) or not data:
        raise ToolError("keyframes must be a non-empty list", kind="bad_argument")
    return normalize_keyframes(data)


def normalize_keyframes(frames: list[dict]) -> list[dict]:
    """Fill defaults, validate ranges, sort by time."""
    out = []
    for index, frame in enumerate(frames):
        if not isinstance(frame, dict):
            raise ToolError(f"keyframe {index} must be an object", kind="bad_argument")
        try:
            item = {
                "t": float(frame.get("t", 0.0)),
                "yaw": float(frame.get("yaw", 0.0)),
                "pitch": float(frame.get("pitch", 0.0)),
                "roll": float(frame.get("roll", 0.0)),
                "fov": float(frame.get("fov", 90.0)),
                "ease": str(frame.get("ease", "smooth")).lower(),
            }
        except (TypeError, ValueError) as error:
            raise ToolError(f"keyframe {index}: {error}", kind="bad_argument")
        if item["t"] < 0:
            raise ToolError(f"keyframe {index}: t must be ≥ 0", kind="bad_argument")
        if item["ease"] not in EASES:
            raise ToolError(f"keyframe {index}: ease must be one of {', '.join(EASES)}", kind="bad_argument")
        item["yaw"] = wrap180(item["yaw"])
        item["roll"] = wrap180(item["roll"])
        for key in ("pitch", "fov"):
            low, high = LIMITS[key]
            if not low <= item[key] <= high:
                raise ToolError(f"keyframe {index}: {key} {item[key]} is outside {low}..{high}", kind="bad_argument")
        out.append(item)
    out.sort(key=lambda k: k["t"])
    return out


def wrap180(angle: float) -> float:
    """Angle wrapped into [-180, 180)."""
    return (angle + 180.0) % 360.0 - 180.0


def shortest_delta(a: float, b: float) -> float:
    """Signed shortest rotation from angle a to angle b."""
    return (b - a + 180.0) % 360.0 - 180.0


def unwrap(values: list[float]) -> list[float]:
    """Make consecutive angles continuous by always taking the shortest arc."""
    out = [values[0]]
    for value in values[1:]:
        out.append(out[-1] + shortest_delta(out[-1], value))
    return out


def segments(frames: list[dict]) -> list[tuple[dict, dict]]:
    """Consecutive keyframe pairs; pairs closer than MIN_SEGMENT collapse into a hard cut."""
    return [(a, b) for a, b in zip(frames, frames[1:]) if b["t"] - a["t"] >= MIN_SEGMENT]


# --- field of view ------------------------------------------------------------------------------

def diagonal_fov(fov_h_16x9: float, width: int, height: int, portrait_zoom: float = 1.0) -> float:
    """The diagonal FOV that gives the 16:9 horizontal FOV `fov_h_16x9` and, for every other
    size, the same diagonal (the portrait version is the landscape camera turned sideways)."""
    r = 9.0 / 16.0
    diagonal = 2.0 * math.degrees(math.atan(math.tan(math.radians(fov_h_16x9) / 2.0) * math.sqrt(1.0 + r * r)))
    if height > width and portrait_zoom != 1.0:
        diagonal = 2.0 * math.degrees(math.atan(math.tan(math.radians(diagonal) / 2.0) / portrait_zoom))
    return diagonal


def horizontal_vertical_fov(d_fov: float, width: int, height: int) -> tuple[float, float]:
    """What v360 derives from a diagonal FOV for a WxH flat output."""
    diag = math.hypot(width, height)
    t = math.tan(math.radians(d_fov) / 2.0)
    return (2.0 * math.degrees(math.atan(t * width / diag)), 2.0 * math.degrees(math.atan(t * height / diag)))


# --- expressions ------------------------------------------------------------------------------

def fmt(value: float) -> str:
    text = f"{value:.4f}".rstrip("0").rstrip(".")
    return text if text not in ("", "-0") else "0"


def eased_progress(ease: str, progress: str) -> str:
    """ffmpeg expression for the eased 0..1 progress, given a 0..1 progress expression."""
    if ease == "linear":
        return progress
    # smoothstep, using st/ld so the progress expression is evaluated once
    return f"st(0,{progress})*ld(0)*(3-2*ld(0))"


def piecewise(frames: list[dict], key: str, values: list[float] | None = None) -> str:
    """Expression in `t` giving the eased value of `key` (or the given unwrapped values)."""
    values = values if values is not None else [frame[key] for frame in frames]
    segs = segments(frames)
    if not segs:
        return fmt(values[-1])
    pieces = []
    for a, b in segs:
        ia, ib = frames.index(a), frames.index(b)
        va, vb = values[ia], values[ib]
        if va == vb or a["ease"] == "hold":
            expr = fmt(va)
        else:
            progress = f"clip((t-{fmt(a['t'])})/{fmt(b['t'] - a['t'])},0,1)"
            expr = f"lerp({fmt(va)},{fmt(vb)},{eased_progress(a['ease'], progress)})"
        pieces.append((b["t"], expr))
    expression = fmt(values[-1])
    for end_t, expr in reversed(pieces):
        expression = f"if(lt(t,{fmt(end_t)}),{expr},{expression})"
    return expression


def scroll_x_expression(frames: list[dict]) -> str:
    """crop x for the hstacked sphere: the equirect column that must become the centre."""
    yaw = piecewise(frames, "yaw", unwrap([f["yaw"] for f in frames]))
    return f"(in_w/2)*mod(mod({yaw},360)+360,360)/360"


def sendcmd_lines(frames: list[dict], target: str, d_fovs: list[float], animate_yaw: bool) -> str:
    """The sendcmd file: absolute commands for the parameters v360 animates."""
    params = {"pitch": [f["pitch"] for f in frames], "roll": [f["roll"] for f in frames], "d_fov": d_fovs}
    if animate_yaw:
        params["yaw"] = unwrap([f["yaw"] for f in frames])
    first = [f"[enter] {target} reset_rot 1"] + [f"[enter] {target} {name} {fmt(cmd_value(name, values[0]))}"
                                                for name, values in params.items()]
    lines = ["0 " + ", ".join(first) + ";"]
    for a, b in segments(frames):
        ia, ib = frames.index(a), frames.index(b)
        moving = []
        for name, values in params.items():
            va, vb = values[ia], values[ib]
            if va == vb or a["ease"] == "hold":
                continue
            ease = "TI" if a["ease"] == "linear" else "TI*TI*(3-2*TI)"
            expr = f"lerp({fmt(va)},{fmt(vb)},{ease})"
            if name == "yaw":
                expr = f"mod(mod({expr},360)+360,360)-180"
                expr = expr.replace(f"lerp({fmt(va)},{fmt(vb)},", f"lerp({fmt(va + 180)},{fmt(vb + 180)},")
            moving.append(f"[expr] {target} {name} '{expr}'")
        if moving:
            lines.append(f"{a['t']:.6f}-{b['t']:.6f} " + ", ".join(moving) + ";")
        snaps = [f"[enter] {target} {name} {fmt(cmd_value(name, values[ib]))}"
                 for name, values in params.items() if values[ia] != values[ib]]
        if snaps:
            lines.append(f"{b['t']:.6f} " + ", ".join(snaps) + ";")
    return "\n".join(lines) + "\n"


def cmd_value(name: str, value: float) -> float:
    return wrap180(value) if name == "yaw" else value


# --- shot classification and graph -------------------------------------------------------------

def classify(frames: list[dict]) -> str:
    """static | pan | full"""
    if len(frames) == 1 or all(all(f[k] == frames[0][k] for k in ("yaw", "pitch", "roll", "fov")) for f in frames):
        return "static"
    if all(all(f[k] == frames[0][k] for k in ("pitch", "roll", "fov")) for f in frames):
        return "pan"
    return "full"


def build_graph(frames: list[dict], width: int, height: int, *, portrait_zoom: float, interp: str,
                pan_mode: str, fps: float | None, preview: bool, cmd_file: str | None) -> tuple[str, str]:
    """Returns (filter graph, kind). The graph reads [0:v] and writes [v]."""
    kind = classify(frames)
    d_fovs = [diagonal_fov(f["fov"], width, height, portrait_zoom) for f in frames]
    first = frames[0]
    tail = f",fps={fmt(fps)}" if fps else ""
    if preview:
        tail += "," + hud_filter(frames, d_fovs, height)
    tail += ",format=yuv420p[v]"

    v360_common = f"input=e:output=flat:w={width}:h={height}:interp={interp}"
    if kind == "static":
        graph = (f"[0:v]v360={v360_common}:yaw={fmt(first['yaw'])}:pitch={fmt(first['pitch'])}:"
                 f"roll={fmt(first['roll'])}:d_fov={fmt(d_fovs[0])}{tail}")
        return graph, kind

    if pan_mode == "scroll":
        scroll = (f"[0:v]split[a][b];[a][b]hstack=inputs=2,"
                  f"crop=w=iw/2:h=ih:y=0:exact=1:x='{scroll_x_expression(frames)}',")
        yaw_opt = "yaw=0"
    else:
        scroll = "[0:v]"
        yaw_opt = f"yaw={fmt(first['yaw'])}"

    if kind == "pan" and pan_mode == "scroll":
        graph = (f"{scroll}v360={v360_common}:{yaw_opt}:pitch={fmt(first['pitch'])}:roll={fmt(first['roll'])}:"
                 f"d_fov={fmt(d_fovs[0])}:reset_rot=1{tail}")
        return graph, kind

    if not cmd_file:
        raise ToolError("internal: this shot needs a sendcmd file", kind="internal")
    graph = (f"{scroll}sendcmd=f={cmd_file},v360@cam={v360_common}:{yaw_opt}:pitch={fmt(first['pitch'])}:"
             f"roll={fmt(first['roll'])}:d_fov={fmt(d_fovs[0])}:reset_rot=1{tail}")
    return graph, kind


def hud_filter(frames: list[dict], d_fovs: list[float], height: int) -> str:
    """drawtext overlay with the live camera values (preview only)."""
    yaw = piecewise(frames, "yaw", unwrap([f["yaw"] for f in frames]))
    yaw = f"mod(mod({yaw},360)+360,360)-180"
    pitch = piecewise(frames, "pitch")
    fovs = piecewise(frames, "fov")
    text = (f"%{{pts\\:hms}}  yaw %{{eif\\:{yaw}\\:d}}  pitch %{{eif\\:{pitch}\\:d}}  fov %{{eif\\:{fovs}\\:d}}")
    size = max(14, height // 24)
    return (f"drawtext=fontsize={size}:fontcolor=white:box=1:boxcolor=black@0.55:boxborderw=6:x=12:y=12:"
            f"text='{text}'")


# --- rendering ----------------------------------------------------------------------------------

def parse_output(spec: str) -> tuple[int, int, Path]:
    """'16:9=path' or '1920x1080=path' → (w, h, path)."""
    if "=" not in spec:
        raise ToolError(f"--output needs SIZE=PATH, got {spec!r}", kind="bad_argument")
    size, path = spec.split("=", 1)
    size = size.strip().lower()
    if size in ASPECT_SIZES:
        width, height = ASPECT_SIZES[size]
    else:
        match = re.fullmatch(r"(\d+)x(\d+)", size)
        if not match:
            raise ToolError(f"unknown size {size!r}; use WxH or one of {', '.join(ASPECT_SIZES)}", kind="bad_argument")
        width, height = int(match.group(1)), int(match.group(2))
    if width % 2 or height % 2 or width < 16 or height < 16:
        raise ToolError(f"size {width}x{height} must be even and at least 16x16", kind="bad_argument")
    return width, height, Path(path.strip()).expanduser()


def check_command_replies(stderr: str) -> list[str]:
    """Lines of failed sendcmd commands (ffmpeg only reports them at verbose level)."""
    return [line.strip() for line in stderr.splitlines() if "Command reply" in line and "ret:Success" not in line]


def render(src: Path, in_point: float, duration: float, frames: list[dict], width: int, height: int, out: Path,
           *, portrait_zoom: float, interp: str, pan_mode: str, fps: float | None, preview: float | None,
           hwaccel: bool, work: Path, dry_run: bool) -> dict:
    is_preview = preview is not None
    if is_preview:
        width, height = even(width * preview), even(height * preview)
        interp = "line"
    tag = f"{out.stem}_{width}x{height}"
    work.mkdir(parents=True, exist_ok=True)
    cmd_name = f"{tag}.cmds.txt"
    graph, kind = build_graph(frames, width, height, portrait_zoom=portrait_zoom, interp=interp, pan_mode=pan_mode,
                              fps=fps, preview=is_preview, cmd_file=cmd_name)
    uses_sendcmd = "sendcmd=" in graph
    d_fovs = [diagonal_fov(f["fov"], width, height, portrait_zoom) for f in frames]
    if uses_sendcmd:
        (work / cmd_name).write_text(sendcmd_lines(frames, "v360@cam", d_fovs, animate_yaw=(pan_mode != "scroll")))
    graph_name = f"{tag}.graph.txt"
    (work / graph_name).write_text(graph + "\n")

    video_args = (["-c:v", "libx264", "-crf", str(PREVIEW_CRF), "-preset", "ultrafast"] if is_preview
                  else ["-c:v", "libx264", "-crf", str(INTERMEDIATE_CRF), "-preset", "medium"])
    audio_args = ["-c:a", "aac", "-b:a", "96k" if is_preview else "256k", "-ar", "48000"]
    cmd = [ffmpeg_bin(), "-hide_banner", "-nostdin", "-y", "-loglevel", "verbose" if uses_sendcmd else "error"]
    if hwaccel and platform.system() == "Darwin":
        cmd += ["-hwaccel", "videotoolbox"]
    cmd += ["-ss", f"{in_point:.6f}", "-t", f"{duration:.6f}", "-i", str(src.resolve()),
            "-filter_complex_script", graph_name, "-map", "[v]", "-map", "0:a?",
            *video_args, "-pix_fmt", "yuv420p", *audio_args, "-movflags", "+faststart", str(out.resolve())]
    result = {"size": f"{width}x{height}", "path": str(out), "kind": kind, "d_fov": [round(d, 2) for d in d_fovs],
              "fov_h_v": [tuple(round(v, 1) for v in horizontal_vertical_fov(d, width, height)) for d in d_fovs],
              "graph": graph, "command": cmd}
    if uses_sendcmd:
        result["cmds"] = (work / cmd_name).read_text()
    if dry_run:
        return result

    out.parent.mkdir(parents=True, exist_ok=True)
    log(f"rendering {kind} shot → {out.name} ({width}x{height}, {duration:.2f}s)")
    started = time.monotonic()
    proc = run(cmd, cwd=work)
    result["elapsed_s"] = round(time.monotonic() - started, 2)
    if uses_sendcmd:
        failed = check_command_replies(proc.stderr)
        if failed:
            raise ToolError(f"{len(failed)} camera commands were rejected by ffmpeg, e.g. {failed[0]}",
                            kind="command_rejected", failed=failed[:5])
        result["commands_ok"] = proc.stderr.count("ret:Success")
    info = probe(out)
    result["duration_s"] = round(duration_of(info), 3)
    if is_preview:
        sheet = out.with_name(f"{out.stem}_sheet_%02d.png")
        run([ffmpeg_bin(), "-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", str(out),
             "-vf", "fps=1,scale=-2:180,tile=6x5:padding=2:margin=2", "-fps_mode", "passthrough", str(sheet)])
        result["sheets"] = sorted(str(p) for p in out.parent.glob(f"{out.stem}_sheet_*.png"))
    return result


def main() -> dict:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("src", help="equirectangular 360 video")
    parser.add_argument("--in", dest="in_point", default="0", help="clip start in the source (seconds or mm:ss)")
    parser.add_argument("--to", help="clip end in the source (default: end of file)")
    parser.add_argument("--duration", help="clip length instead of --to")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--keyframes", help="JSON file with the keyframes")
    group.add_argument("--kf", help="inline JSON keyframes")
    parser.add_argument("--output", action="append", required=True, metavar="SIZE=PATH",
                        help="e.g. 16:9=c01_16x9.mp4 or 1080x1920=c01_9x16.mp4 (repeatable)")
    parser.add_argument("--fps", type=float, help="force this frame rate (default: keep the source's)")
    parser.add_argument("--interp", default="lanczos", choices=["near", "line", "cubic", "lanczos", "spline16", "gauss", "mitchell"])
    parser.add_argument("--portrait-zoom", type=float, default=1.0, help="tighten portrait outputs, e.g. 1.2 (default 1.0)")
    parser.add_argument("--pan", default="scroll", choices=["scroll", "v360"], help="how pans are rendered (default scroll)")
    parser.add_argument("--preview", type=float, metavar="FACTOR", help="fast preview scaled by FACTOR with a camera overlay")
    parser.add_argument("--hw", dest="hwaccel", action="store_true", default=platform.system() == "Darwin",
                        help="use VideoToolbox decoding on macOS (default on macOS)")
    parser.add_argument("--no-hw", dest="hwaccel", action="store_false")
    parser.add_argument("--work", help="folder for the graph/command files (default: next to the first output)")
    parser.add_argument("--dry-run", action="store_true", help="print graphs and command files; render nothing")
    args = parser.parse_args()

    src = Path(args.src).expanduser()
    if not src.exists():
        raise ToolError(f"no such file: {src}", kind="bad_argument")
    if args.portrait_zoom < 1.0 or args.portrait_zoom > 2.0:
        raise ToolError("--portrait-zoom must be between 1.0 and 2.0", kind="bad_argument")
    frames = load_keyframes(args.keyframes if args.keyframes else args.kf)
    outputs = [parse_output(spec) for spec in args.output]

    info = probe(src)
    stream = video_stream(info)
    if not stream:
        raise ToolError(f"{src} has no video stream", kind="bad_input")
    source_duration = duration_of(info)
    in_point = parse_time(args.in_point)
    if args.to and args.duration:
        raise ToolError("use --to or --duration, not both", kind="bad_argument")
    end = parse_time(args.to) if args.to else (in_point + parse_time(args.duration) if args.duration else source_duration)
    if end <= in_point:
        raise ToolError(f"--to ({end}) must be after --in ({in_point})", kind="bad_argument")
    if source_duration and in_point >= source_duration:
        raise ToolError(f"--in {in_point} is past the end of the file ({source_duration:.2f}s)", kind="bad_argument")
    duration = min(end, source_duration or end) - in_point
    warnings = []
    if frames[-1]["t"] > duration + 0.01:
        warnings.append(f"last keyframe at {frames[-1]['t']}s is after the clip end ({duration:.2f}s); it will be cut")
    if int(stream.get("width", 0)) != 2 * int(stream.get("height", 0)):
        warnings.append("source is not 2:1; is it really an equirectangular 360 video?")

    work = Path(args.work) if args.work else outputs[0][2].parent / ".reframe"
    results = []
    for width, height, out in outputs:
        results.append(render(src, in_point, duration, frames, width, height, out, portrait_zoom=args.portrait_zoom,
                              interp=args.interp, pan_mode=args.pan, fps=args.fps, preview=args.preview,
                              hwaccel=args.hwaccel, work=work, dry_run=args.dry_run))
    return {"ok": True, "src": str(src), "in": in_point, "duration": round(duration, 3),
            "source_fps": round(frame_rate(stream), 3), "kind": classify(frames), "keyframes": frames,
            "outputs": results, "warnings": warnings, "dry_run": args.dry_run}


if __name__ == "__main__":
    sys.exit(main_wrapper(main))
