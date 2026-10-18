#!/usr/bin/env python3
"""Render a project.json into finished 9:16 and 16:9 videos.

  render_project.py project.json [--aspect 9:16] [--quality master|preview] [--force] [--dry-run] [--work DIR]

project.json (paths are relative to the file; see references/project-schema.md):

  {"name": "Lisbon", "fps": 30, "portrait_zoom": 1.0,
   "clips": [
     {"src": "VID_360.mp4", "type": "360", "in": 12.5, "to": 20,
      "keyframes": [{"t": 0, "yaw": 0, "pitch": 0, "fov": 90}, {"t": 4, "yaw": 120, "pitch": -20, "fov": 80}]},
     {"src": "VID_360.mp4", "type": "360", "in": 30, "to": 38, "follow": {"target": "person-largest"}},
     {"src": "IMG_1.MOV", "type": "video", "in": 0, "to": 6.2, "anchor": {"x": 0.5, "y": 0.35}},
     {"src": "photo.jpg", "type": "photo", "duration": 4, "kenburns": {"zoom": "in", "amount": 1.25, "pan": "left"}}],
   "transitions": {"type": "fade", "duration": 0.5},
   "music": {"src": "track.mp3", "gain_db": -16, "duck": true, "fade_out": 2, "loop": true},
   "output": {"aspects": ["9:16", "16:9"], "quality": "master", "uhd": false, "dir": "deliver"}}

For each aspect: every clip becomes an intermediate at the canvas size (360 → reframe360.py,
with track360.py first for "follow" clips; flat video → crop with an anchor; photo → Ken Burns
through ffmpeg-skill's insert.py), the clips are joined with cross-fades (join.py), music is
mixed underneath with ducking (audio.py), loudness is normalized to -14 LUFS (loudness.py),
and the file is written to the deliver folder. Intermediates are cached by a hash of everything
that produced them, so changing one shot re-renders one clip plus the join. Nothing in the
source folder is modified.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import (FFMPEG_SKILL_DIR, ToolError, audio_stream, duration_of, even, ffmpeg_bin, log, main_wrapper,  # noqa: E402
                     parse_time, probe, run, video_stream)

SCRIPTS = Path(__file__).resolve().parent
CANVAS = {"9:16": (1080, 1920), "16:9": (1920, 1080), "1:1": (1080, 1080), "4:5": (1080, 1350)}
UHD = {"16:9": (3840, 2160), "9:16": (2160, 3840)}
MIN_360_WIDTH = 1024
CLIP_CRF = 12


# --- project ------------------------------------------------------------------------------------

def load_project(path: Path) -> dict:
    try:
        project = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ToolError(f"can't read {path}: {error}", kind="bad_argument")
    if not isinstance(project.get("clips"), list) or not project["clips"]:
        raise ToolError("project.json needs a non-empty \"clips\" list", kind="bad_argument")
    project.setdefault("name", path.parent.name or "edit")
    project.setdefault("fps", 30)
    project.setdefault("portrait_zoom", 1.0)
    project.setdefault("transitions", {"type": "fade", "duration": 0.5})
    project.setdefault("output", {})
    project["output"].setdefault("aspects", ["9:16", "16:9"])
    project["output"].setdefault("quality", "master")
    project["output"].setdefault("uhd", False)
    project["output"].setdefault("dir", "deliver")
    base = path.parent
    for index, clip in enumerate(project["clips"]):
        if "src" not in clip:
            raise ToolError(f"clip {index} has no src", kind="bad_argument")
        clip["_src"] = (base / clip["src"]).expanduser().resolve()
        if not clip["_src"].exists():
            raise ToolError(f"clip {index}: no such file {clip['_src']}", kind="bad_argument")
        clip["_index"] = index
    music = project.get("music")
    if music and music.get("src"):
        music["_src"] = (base / music["src"]).expanduser().resolve()
        if not music["_src"].exists():
            raise ToolError(f"music file not found: {music['_src']}", kind="bad_argument")
    return project


def detect_type(clip: dict) -> str:
    if clip.get("type") in ("360", "video", "photo"):
        return clip["type"]
    ext = clip["_src"].suffix.lower()
    if ext in (".jpg", ".jpeg", ".png", ".heic", ".heif", ".tif", ".tiff", ".webp"):
        return "photo"
    info = probe(clip["_src"])
    stream = video_stream(info) or {}
    for side in stream.get("side_data_list", []) or []:
        if str(side.get("side_data_type", "")).lower().startswith("spherical"):
            return "360"
    width, height = int(stream.get("width", 0)), int(stream.get("height", 0))
    return "360" if height and width == 2 * height and width >= MIN_360_WIDTH else "video"


def clip_span(clip: dict) -> tuple[float, float]:
    """(in, duration) of a clip."""
    if clip["_type"] == "photo":
        return 0.0, float(clip.get("duration", 4.0))
    start = parse_time(clip.get("in", 0))
    if "to" in clip:
        end = parse_time(clip["to"])
    elif "duration" in clip:
        end = start + parse_time(clip["duration"])
    else:
        end = duration_of(probe(clip["_src"]))
    if end <= start:
        raise ToolError(f"clip {clip['_index']}: 'to' must be after 'in'", kind="bad_argument")
    return start, end - start


def canvas_for(aspect: str, project: dict) -> tuple[int, int]:
    if aspect not in CANVAS:
        raise ToolError(f"unknown aspect {aspect!r}; use one of {', '.join(CANVAS)}", kind="bad_argument")
    width, height = UHD[aspect] if project["output"].get("uhd") and aspect in UHD else CANVAS[aspect]
    if project["output"]["quality"] == "preview":
        width, height = even(width / 2), even(height / 2)
    return width, height


# --- cache ------------------------------------------------------------------------------------------

def file_stamp(path: Path) -> dict:
    stat = path.stat()
    return {"path": str(path), "size": stat.st_size, "mtime": int(stat.st_mtime)}


def script_stamp(name: str) -> str:
    return hashlib.sha256((SCRIPTS / name).read_bytes()).hexdigest()[:12]


def cache_key(payload: dict) -> str:
    return hashlib.sha256(json.dumps(payload, sort_keys=True, default=str).encode()).hexdigest()[:12]


def cached(path: Path, key: str) -> bool:
    sidecar = path.with_suffix(path.suffix + ".json")
    if not (path.exists() and path.stat().st_size > 0 and sidecar.exists()):
        return False
    try:
        return json.loads(sidecar.read_text()).get("key") == key
    except (OSError, json.JSONDecodeError):
        return False


def mark(path: Path, key: str, extra: dict | None = None) -> None:
    path.with_suffix(path.suffix + ".json").write_text(json.dumps({"key": key, **(extra or {})}, indent=1))


# --- steps -----------------------------------------------------------------------------------------

def tool(name: str) -> Path:
    path = FFMPEG_SKILL_DIR / "scripts" / name
    if not path.exists():
        raise ToolError(f"ffmpeg-skill is missing ({path}); run install.sh", kind="missing_tool")
    return path


def tool_env() -> dict:
    """ffmpeg-skill finds ffmpeg on PATH; Homebrew's ffmpeg-full is keg-only, so put ours first."""
    env = dict(os.environ)
    ffmpeg_dir = str(Path(ffmpeg_bin()).resolve().parent)
    env["PATH"] = ffmpeg_dir + os.pathsep + env.get("PATH", "")
    return env


def run_tool(cmd: list[str], what: str) -> dict:
    """Run one of the Python tools and return its JSON report (ffmpeg-skill tools get --json)."""
    if Path(cmd[1]).resolve().parent == (FFMPEG_SKILL_DIR / "scripts").resolve() and "--json" not in cmd:
        cmd = cmd + ["--json"]
    proc = run(cmd, check=False, env=tool_env())
    text = proc.stdout.strip()
    report: dict = {}
    if text:
        try:
            report = json.loads(text[text.index("{"):]) if "{" in text else {}
        except (ValueError, json.JSONDecodeError):
            report = {}
    if proc.returncode != 0 or report.get("status") == "failed" or report.get("ok") is False:
        detail = report.get("error") or report.get("message") or (proc.stderr or proc.stdout)[-1200:]
        raise ToolError(f"{what} failed: {detail}", kind="step_failed", step=what, exit_code=proc.returncode)
    return report


def render_clip(clip: dict, aspect: str, width: int, height: int, project: dict, work: Path, force: bool,
                dry_run: bool) -> dict:
    kind = clip["_type"]
    start, length = clip_span(clip)
    fps = float(project["fps"])
    preview = project["output"]["quality"] == "preview"
    base = f"c{clip['_index']:02d}_{clip['_src'].stem}"
    params = {k: v for k, v in clip.items() if not k.startswith("_")}
    payload = {"step": "clip", "kind": kind, "params": params, "src": file_stamp(clip["_src"]), "canvas": [width, height],
               "fps": fps, "preview": preview, "portrait_zoom": project["portrait_zoom"], "crf": CLIP_CRF,
               "script": script_stamp("render_project.py") + script_stamp("reframe360.py")}
    key = cache_key(payload)
    out = work / "clips" / aspect / f"{base}_{key}.mp4"
    report = {"index": clip["_index"], "type": kind, "src": str(clip["_src"]), "in": start, "duration": round(length, 3),
              "path": str(out), "cached": False}
    if not force and cached(out, key):
        report["cached"] = True
        return report
    if dry_run:
        return report
    out.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()

    if kind == "360":
        keyframes = clip.get("keyframes")
        if clip.get("follow") and not keyframes:
            keyframes = follow_keyframes(clip, start, length, work, force)
            report["follow"] = True
        if not keyframes:
            keyframes = [{"t": 0, "yaw": 0, "pitch": 0, "fov": 90}]
        kf_file = out.with_suffix(".keyframes.json")
        kf_file.write_text(json.dumps({"keyframes": keyframes}, indent=1))
        cmd = [sys.executable, str(SCRIPTS / "reframe360.py"), str(clip["_src"]), "--in", f"{start:.6f}",
               "--duration", f"{length:.6f}", "--keyframes", str(kf_file), "--output", f"{width}x{height}={out}",
               "--fps", f"{fps:g}", "--portrait-zoom", str(project["portrait_zoom"]), "--work", str(out.parent / ".reframe")]
        if clip.get("pan") in ("scroll", "v360"):
            cmd += ["--pan", clip["pan"]]
        if preview:
            cmd += ["--preview", "1.0", "--interp", "line"]
        result = run_tool(cmd, f"reframe clip {clip['_index']}")
        report["shot"] = result.get("kind")
        report["keyframes"] = len(keyframes)
    elif kind == "photo":
        burns = clip.get("kenburns") or {}
        cmd = [sys.executable, str(tool("insert.py")), str(clip["_src"]), "--duration", f"{length:g}", "--width", str(width),
               "--height", str(height), "--fps", f"{fps:g}", "-o", str(out)]
        if burns.get("zoom") in ("in", "out"):
            cmd += ["--zoom", burns["zoom"], "--zoom-amount", str(burns.get("amount", 1.25))]
            if burns.get("pan") in ("left", "right", "up", "down"):
                cmd += ["--pan", burns["pan"]]
        if preview:
            cmd += ["--preset", "ultrafast"]
        run_tool(cmd, f"photo clip {clip['_index']}")
    else:
        render_flat_video(clip, start, length, width, height, fps, out, preview)
    report["elapsed_s"] = round(time.monotonic() - started, 1)
    mark(out, key, {"clip": clip["_index"], "type": kind})
    return report


def render_flat_video(clip: dict, start: float, length: float, width: int, height: int, fps: float, out: Path,
                      preview: bool) -> None:
    """Trim a normal video and fill the canvas: crop around an anchor (default) or pad."""
    anchor = clip.get("anchor") or {}
    x = min(max(float(anchor.get("x", 0.5)), 0.0), 1.0)
    y = min(max(float(anchor.get("y", 0.5)), 0.0), 1.0)
    if clip.get("fit") == "pad":
        vf = (f"scale={width}:{height}:force_original_aspect_ratio=decrease,"
              f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=black")
    else:
        vf = (f"scale={width}:{height}:force_original_aspect_ratio=increase,"
              f"crop={width}:{height}:(iw-ow)*{x:.4f}:(ih-oh)*{y:.4f}")
    vf += f",fps={fps:g},format=yuv420p"
    cmd = [ffmpeg_bin(), "-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-ss", f"{start:.6f}", "-t", f"{length:.6f}",
           "-i", str(clip["_src"]), "-vf", vf, "-map", "0:v:0", "-map", "0:a?", "-c:v", "libx264",
           "-crf", "28" if preview else str(CLIP_CRF), "-preset", "ultrafast" if preview else "medium",
           "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-movflags", "+faststart", str(out)]
    run(cmd)


def follow_keyframes(clip: dict, start: float, length: float, work: Path, force: bool) -> list[dict]:
    follow = clip["follow"]
    payload = {"step": "track", "src": file_stamp(clip["_src"]), "in": start, "duration": length, "follow": follow,
               "script": script_stamp("track360.py")}
    key = cache_key(payload)
    out = work / "tracking" / f"c{clip['_index']:02d}_{key}.json"
    if not force and out.exists():
        return json.loads(out.read_text())["keyframes"]
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, str(SCRIPTS / "track360.py"), str(clip["_src"]), "--in", f"{start:.6f}", "--duration",
           f"{length:.6f}", "-o", str(out), "--target", str(follow.get("target", "person-largest"))]
    if follow.get("hint"):
        cmd += ["--hint", str(follow["hint"])]
    for option in ("subject_height", "fov_min", "fov_max", "deadband", "max_slew", "rate"):
        if option in follow:
            cmd += [f"--{option.replace('_', '-')}", str(follow[option])]
    result = run_tool(cmd, f"track clip {clip['_index']}")
    return result["keyframes"]


def join_clips(paths: list[Path], transitions: dict, width: int, height: int, fps: float, out: Path, preview: bool) -> dict:
    listing = out.with_suffix(".list.txt")
    listing.write_text("\n".join(str(p.resolve()) for p in paths) + "\n")
    cmd = [sys.executable, str(tool("join.py")), "--list", str(listing), "--transition", str(transitions.get("type", "fade")),
           "--duration", str(float(transitions.get("duration", 0.5))), "--width", str(width), "--height", str(height),
           "--fps", f"{fps:g}", "--fit", "pad", "--on-silent", "warn", "-o", str(out)]
    if preview:
        cmd += ["--preset", "ultrafast"]
    return run_tool(cmd, "join")


def mix_music(video: Path, music: dict, out: Path) -> dict:
    cmd = [sys.executable, str(tool("audio.py")), str(video), "--music", str(music["_src"]), "--music-volume",
           str(float(music.get("gain_db", -16))), "--bitrate", "256k", "-o", str(out)]
    if music.get("duck", True):
        cmd += ["--duck", "--duck-amount", str(float(music.get("duck_amount_db", 12))), "--duck-release",
                str(float(music.get("duck_release_ms", 600)))]
    if music.get("loop", True):
        cmd.append("--music-loop")
    if float(music.get("fade_out", 2)) > 0:
        cmd += ["--music-fade-out", str(float(music.get("fade_out", 2)))]
    if float(music.get("fade_in", 0)) > 0:
        cmd += ["--fade-in", str(float(music.get("fade_in", 0)))]
    return run_tool(cmd, "music mix")


def normalize_loudness(video: Path, out: Path, lufs: float) -> dict:
    return run_tool([sys.executable, str(tool("loudness.py")), str(video), "-I", str(lufs), "--tp", "-1",
                     "--audio-bitrate", "256k", "-o", str(out)], "loudness")


def measure_loudness(video: Path) -> float | None:
    proc = run([sys.executable, str(tool("loudness.py")), str(video), "--measure-only", "--json"], check=False,
               env=tool_env())
    try:
        text = proc.stdout.strip()
        data = json.loads(text[text.index("{"):])
        value = data.get("measured", data).get("input_i")
        return float(value) if value not in (None, "-inf") else None
    except (ValueError, AttributeError, json.JSONDecodeError):
        return None


# --- main ---------------------------------------------------------------------------------------------

def render_aspect(aspect: str, project: dict, project_dir: Path, work: Path, force: bool, dry_run: bool) -> dict:
    width, height = canvas_for(aspect, project)
    fps = float(project["fps"])
    preview = project["output"]["quality"] == "preview"
    log(f"— {aspect}: {width}x{height} @ {fps:g} fps ({'preview' if preview else 'master'})")
    clips = [render_clip(clip, aspect, width, height, project, work, force, dry_run) for clip in project["clips"]]
    transitions = project["transitions"]
    overlap = 0.0 if transitions.get("type", "fade") == "none" else float(transitions.get("duration", 0.5))
    expected = sum(c["duration"] for c in clips) - max(len(clips) - 1, 0) * overlap
    report = {"aspect": aspect, "canvas": f"{width}x{height}", "clips": clips, "expected_duration_s": round(expected, 2)}
    if dry_run:
        return report

    aspect_tag = aspect.replace(":", "x")
    join_key = cache_key({"step": "join", "clips": [c["path"] for c in clips], "transitions": transitions,
                          "canvas": [width, height], "fps": fps, "preview": preview,
                          "clip_keys": [Path(c["path"]).stem for c in clips]})
    joined = work / "join" / f"{aspect_tag}_{join_key}.mp4"
    if force or not cached(joined, join_key):
        joined.parent.mkdir(parents=True, exist_ok=True)
        if len(clips) == 1:
            shutil.copyfile(clips[0]["path"], joined)
        else:
            join_clips([Path(c["path"]) for c in clips], transitions, width, height, fps, joined, preview)
        mark(joined, join_key)
    report["joined"] = str(joined)

    current = joined
    music = project.get("music")
    if music and music.get("_src"):
        mix_key = cache_key({"step": "mix", "input": joined.stem, "music": file_stamp(music["_src"]),
                             "params": {k: v for k, v in music.items() if not k.startswith("_")}})
        mixed = work / "mix" / f"{aspect_tag}_{mix_key}.mp4"
        if force or not cached(mixed, mix_key):
            mixed.parent.mkdir(parents=True, exist_ok=True)
            mix_music(current, music, mixed)
            mark(mixed, mix_key)
        current = mixed
        report["mixed"] = str(mixed)

    lufs = float(project["output"].get("lufs", -14))
    loud_key = cache_key({"step": "loudness", "input": current.stem, "lufs": lufs})
    loud = work / "loud" / f"{aspect_tag}_{loud_key}.mp4"
    if force or not cached(loud, loud_key):
        loud.parent.mkdir(parents=True, exist_ok=True)
        normalize_loudness(current, loud, lufs)
        mark(loud, loud_key)

    deliver = (project_dir / project["output"]["dir"]).resolve()
    deliver.mkdir(parents=True, exist_ok=True)
    suffix = "_preview" if preview else ""
    final = deliver / f"{safe_name(project['name'])}_{aspect_tag}_{width}x{height}{suffix}.mp4"
    run([ffmpeg_bin(), "-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", str(loud), "-c", "copy",
         "-movflags", "+faststart", "-metadata", f"title={project['name']}", str(final)])
    info = probe(final)
    actual = duration_of(info)
    stream = video_stream(info) or {}
    report.update(final=str(final), duration_s=round(actual, 2), size_mb=round(final.stat().st_size / 1e6, 1),
                  video=f"{stream.get('width')}x{stream.get('height')} {stream.get('codec_name')} {stream.get('profile', '')}".strip(),
                  has_audio=audio_stream(info) is not None, loudness_lufs=measure_loudness(final))
    if abs(actual - expected) > 0.35:
        report["warning"] = f"duration {actual:.2f}s differs from the expected {expected:.2f}s"
    return report


def safe_name(name: str) -> str:
    return "".join(c if c.isalnum() or c in "-_" else "_" for c in name.strip()) or "edit"


def main() -> dict:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("project")
    parser.add_argument("--aspect", action="append", help="render only this aspect (repeatable)")
    parser.add_argument("--quality", choices=["master", "preview"])
    parser.add_argument("--force", action="store_true", help="ignore cached intermediates")
    parser.add_argument("--dry-run", action="store_true", help="plan only")
    parser.add_argument("--work", help="work folder (default: edit-work next to project.json)")
    args = parser.parse_args()

    project_path = Path(args.project).expanduser().resolve()
    project = load_project(project_path)
    if args.quality:
        project["output"]["quality"] = args.quality
    for clip in project["clips"]:
        clip["_type"] = detect_type(clip)
    work = Path(args.work).expanduser().resolve() if args.work else project_path.parent / "edit-work"
    work.mkdir(parents=True, exist_ok=True)
    aspects = args.aspect or project["output"]["aspects"]
    started = time.monotonic()
    results = [render_aspect(aspect, project, project_path.parent, work, args.force, args.dry_run) for aspect in aspects]
    return {"ok": True, "project": str(project_path), "name": project["name"], "quality": project["output"]["quality"],
            "dry_run": args.dry_run, "aspects": results, "elapsed_s": round(time.monotonic() - started, 1)}


if __name__ == "__main__":
    sys.exit(main_wrapper(main))
