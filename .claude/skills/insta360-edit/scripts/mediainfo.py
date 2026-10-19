#!/usr/bin/env python3
"""List and classify media files: 360 video, flat video, photo, audio, or Insta360 raw files.

  mediainfo.py FOLDER_OR_FILE [...] [--recursive] [--json-only] [--sort time|name]

A video counts as 360 when ffprobe reports spherical metadata (what Insta360 Studio writes on
its equirectangular exports) or when its frame is 2:1 and at least 1024 px wide. Rotated phone
videos report their display size (after the rotation flag), so portrait clips show as portrait.
Every item has `created` (the file's creation_time metadata when it has one, else its
modification time, UTC) and the list is in shooting order unless --sort name. Nothing is modified.
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import ToolError, audio_stream, duration_of, frame_rate, log, main_wrapper, probe, video_stream  # noqa: E402

VIDEO_EXT = {".mp4", ".mov", ".m4v", ".mkv", ".avi", ".webm", ".mts", ".m2ts", ".3gp"}
PHOTO_EXT = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".tif", ".tiff", ".webp", ".dng"}
AUDIO_EXT = {".mp3", ".wav", ".m4a", ".aac", ".flac", ".aif", ".aiff", ".ogg"}
INSTA360_RAW_EXT = {".insv", ".insp"}
MIN_360_WIDTH = 1024


def classify_video(stream: dict) -> tuple[str, str]:
    """('360' | 'video', reason)"""
    for side in stream.get("side_data_list", []) or []:
        if str(side.get("side_data_type", "")).lower().startswith("spherical"):
            projection = side.get("projection", "?")
            return "360", f"spherical metadata ({projection})"
    width, height = int(stream.get("width", 0)), int(stream.get("height", 0))
    if height and width == 2 * height and width >= MIN_360_WIDTH:
        return "360", f"2:1 frame {width}x{height}"
    return "video", f"{width}x{height}"


def rotation_of(stream: dict) -> int:
    for side in stream.get("side_data_list", []) or []:
        if "rotation" in side:
            try:
                return int(round(float(side["rotation"]))) % 360
            except (TypeError, ValueError):
                pass
    tags = stream.get("tags", {}) or {}
    try:
        return int(round(float(tags.get("rotate", 0)))) % 360
    except (TypeError, ValueError):
        return 0


def iso_utc(moment: datetime) -> str:
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def created_at(info: dict | None, path: Path) -> tuple[str, str]:
    """(ISO 8601 UTC, where it came from): creation_time metadata if present, else the file's mtime."""
    tags = ((info or {}).get("format") or {}).get("tags") or {}
    for key in ("creation_time", "com.apple.quicktime.creationdate", "date", "DateTimeOriginal"):
        value = tags.get(key)
        if not value:
            continue
        text = str(value).strip().replace("Z", "+00:00")
        try:
            return iso_utc(datetime.fromisoformat(text)), f"metadata {key}"
        except ValueError:
            try:
                return iso_utc(datetime.strptime(text[:19], "%Y:%m:%d %H:%M:%S")), f"metadata {key}"
            except ValueError:
                continue
    return iso_utc(datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)), "file mtime"


def describe(path: Path) -> dict:
    item = {"path": str(path), "name": path.name, "size_mb": round(path.stat().st_size / 1e6, 1)}
    item["created"], item["created_from"] = created_at(None, path)
    ext = path.suffix.lower()
    if ext in INSTA360_RAW_EXT:
        item.update(type="insta360-raw", reason="raw Insta360 file: export it from Insta360 Studio as a 360 MP4/JPG first")
        return item
    if ext in AUDIO_EXT:
        item["type"] = "audio"
    elif ext in PHOTO_EXT:
        item["type"] = "photo"
    elif ext in VIDEO_EXT:
        item["type"] = "video"
    else:
        item.update(type="other", reason=f"unknown extension {ext}")
        return item
    try:
        info = probe(path)
    except ToolError as error:
        item.update(reason=f"ffprobe could not read it: {str(error).splitlines()[-1][:120]}")
        return item
    stream = video_stream(info)
    audio = audio_stream(info)
    item["created"], item["created_from"] = created_at(info, path)
    item["duration_s"] = round(duration_of(info), 3)
    if audio:
        item["audio"] = {"codec": audio.get("codec_name"), "channels": audio.get("channels"),
                         "sample_rate": audio.get("sample_rate")}
    if stream and item["type"] != "audio":
        width, height = int(stream.get("width", 0)), int(stream.get("height", 0))
        rotation = rotation_of(stream)
        if rotation in (90, 270):
            width, height = height, width
        item.update(width=width, height=height, codec=stream.get("codec_name"), rotation=rotation)
        if item["type"] == "video":
            item["type"], item["reason"] = classify_video(stream)
            item["fps"] = round(frame_rate(stream), 3)
            item["has_audio"] = audio is not None
        else:
            item["reason"] = f"{width}x{height}"
    return item


def collect(paths: list[str], recursive: bool) -> list[Path]:
    files: list[Path] = []
    for raw in paths:
        path = Path(raw).expanduser()
        if path.is_dir():
            iterator = path.rglob("*") if recursive else path.iterdir()
            files += sorted(p for p in iterator if p.is_file() and not p.name.startswith("."))
        elif path.exists():
            files.append(path)
        else:
            raise ToolError(f"no such file or folder: {path}", kind="bad_argument")
    return files


def main() -> dict:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="+")
    parser.add_argument("--recursive", action="store_true")
    parser.add_argument("--json-only", action="store_true", help="no table on stderr")
    parser.add_argument("--sort", choices=["time", "name"], default="time",
                        help="shooting order (default) or file name order")
    args = parser.parse_args()

    items = [describe(path) for path in collect(args.paths, args.recursive)]
    items = [i for i in items if i["type"] != "other"]
    if args.sort == "time":
        items.sort(key=lambda i: (i["created"], i["name"]))
    if not args.json_only:
        for item in items:
            size = f"{item.get('width', '')}x{item.get('height', '')}" if item.get("width") else ""
            dur = f"{item['duration_s']:.1f}s" if item.get("duration_s") else ""
            log(f"{item['created'][:16]} {item['type']:<13} {item['name']:<40} {size:<10} {dur:<8} {item.get('reason', '')}")
    summary: dict = {}
    for item in items:
        summary[item["type"]] = summary.get(item["type"], 0) + 1
    summary["order"] = [item["name"] for item in items]
    return {"ok": True, "items": items, "summary": summary, "sorted_by": args.sort}


if __name__ == "__main__":
    sys.exit(main_wrapper(main))
