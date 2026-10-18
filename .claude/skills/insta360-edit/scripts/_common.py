"""Shared helpers for the insta360-edit scripts: running ffmpeg, probing, JSON output.

Every script prints exactly one JSON object on stdout (so Claude can read it) and keeps
human-readable progress on stderr. Scripts never modify their inputs.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
FFMPEG_SKILL_DIR = Path(os.environ.get("FFMPEG_SKILL_DIR", Path.home() / ".claude" / "skills" / "ffmpeg-skill"))


class ToolError(Exception):
    """A failure that should be reported as JSON and end the script."""

    def __init__(self, message: str, kind: str = "error", **details):
        super().__init__(message)
        self.kind = kind
        self.details = details


# Homebrew's plain `ffmpeg` formula has no drawtext (no freetype); `ffmpeg-full` has it but is
# keg-only, so it never appears on PATH. Prefer it when it is installed.
FFMPEG_FULL_DIRS = ("/opt/homebrew/opt/ffmpeg-full/bin", "/usr/local/opt/ffmpeg-full/bin")


def ffmpeg_bin(name: str = "ffmpeg") -> str:
    """Path of ffmpeg/ffprobe: $FFMPEG / $FFPROBE override, else Homebrew's ffmpeg-full, else PATH."""
    override = os.environ.get(name.upper())
    if override:
        return override
    for directory in FFMPEG_FULL_DIRS:
        candidate = Path(directory) / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    found = shutil.which(name)
    if not found:
        raise ToolError(f"{name} is not installed or not on PATH (brew install ffmpeg-full)", kind="missing_tool",
                        tool=name)
    return found


def run(cmd: list[str], *, capture: bool = True, check: bool = True, cwd: str | Path | None = None,
        timeout: float | None = None, env: dict | None = None) -> subprocess.CompletedProcess:
    """Run a command with arguments passed as a list (never through a shell)."""
    if os.environ.get("INSTA360_VERBOSE"):
        log(" ".join(_quote(part) for part in cmd[:12]) + (" …" if len(cmd) > 12 else ""))
    started = time.monotonic()
    proc = subprocess.run(cmd, capture_output=capture, text=True, cwd=cwd, timeout=timeout, env=env)
    elapsed = time.monotonic() - started
    if check and proc.returncode != 0:
        tail = (proc.stderr or "")[-2000:]
        raise ToolError(f"{Path(cmd[0]).name} failed (exit {proc.returncode}) after {elapsed:.1f}s:\n{tail}",
                        kind="command_failed", command=cmd, exit_code=proc.returncode)
    return proc


def _quote(part: str) -> str:
    return f"'{part}'" if " " in part or ";" in part else part


def probe(path: str | Path) -> dict:
    """ffprobe's JSON for a file: format plus streams."""
    proc = run([ffmpeg_bin("ffprobe"), "-v", "error", "-print_format", "json", "-show_format", "-show_streams",
                str(path)])
    return json.loads(proc.stdout or "{}")


def video_stream(info: dict) -> dict | None:
    for stream in info.get("streams", []):
        if stream.get("codec_type") == "video" and stream.get("disposition", {}).get("attached_pic") != 1:
            return stream
    return None


def audio_stream(info: dict) -> dict | None:
    for stream in info.get("streams", []):
        if stream.get("codec_type") == "audio":
            return stream
    return None


def duration_of(info: dict) -> float:
    fmt = info.get("format", {})
    try:
        return float(fmt.get("duration"))
    except (TypeError, ValueError):
        stream = video_stream(info) or audio_stream(info) or {}
        try:
            return float(stream.get("duration"))
        except (TypeError, ValueError):
            return 0.0


def frame_rate(stream: dict, default: float = 30.0) -> float:
    for key in ("avg_frame_rate", "r_frame_rate"):
        value = stream.get(key, "")
        if "/" in value:
            num, den = value.split("/", 1)
            try:
                if float(den) > 0 and float(num) > 0:
                    return float(num) / float(den)
            except ValueError:
                pass
    return default


def parse_time(text: str | float | int) -> float:
    """Seconds from '12.5', '1:05', '0:01:05.2' or a number."""
    if isinstance(text, (int, float)):
        return float(text)
    parts = str(text).strip().split(":")
    if not all(parts):
        raise ToolError(f"bad time: {text!r}", kind="bad_argument")
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + float(part)
    return seconds


def even(value: float) -> int:
    """Nearest even integer ≥ 2 (video sizes must be even)."""
    return max(2, int(round(value / 2)) * 2)


def log(message: str) -> None:
    """Progress for a human watching the terminal; stdout is reserved for the JSON result."""
    print(message, file=sys.stderr, flush=True)


def emit(payload: dict) -> None:
    print(json.dumps(payload, indent=2, sort_keys=False), flush=True)


def main_wrapper(main) -> int:
    """Run `main()`; turn ToolError into a JSON error object and exit code 1."""
    try:
        result = main()
        if isinstance(result, dict):
            emit(result)
            return 0 if result.get("ok", True) else 1
        return int(result or 0)
    except ToolError as error:
        emit({"ok": False, "kind": error.kind, "error": str(error), **error.details})
        return 1
    except KeyboardInterrupt:
        emit({"ok": False, "kind": "interrupted", "error": "interrupted"})
        return 130
