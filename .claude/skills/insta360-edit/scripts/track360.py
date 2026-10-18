#!/usr/bin/env python3
"""Follow a person (or animal, or the most salient thing) through a 360 clip and write camera keyframes.

  track360.py SRC --in 30 --to 38 -o shot.json [--target person-largest|person-central|animal|saliency|hint]
              [--hint "t=3,yaw=40,pitch=0"] [--rate 5] [--subject-height 0.22] [--fov-min 60 --fov-max 110]
              [--kf-every 0.5] [--deadband 4] [--max-slew 30] [--detections-out det.json]
  track360.py --from-detections det.json --duration 8 -o shot.json        # tracking only (no ffmpeg/Vision)
  track360.py --probe-vision                                             # is Apple Vision usable here?

Detection (macOS only) uses Apple's Vision framework through PyObjC: ffmpeg renders four flat
100° views of the sphere (yaw -90, 0, 90, 180) a few times per second, Vision finds people,
faces and animals in them, and the boxes are mapped back to yaw/pitch on the sphere. Nothing
is downloaded; the models ship with macOS.

Tracking turns those detections into a camera path a human operator would be happy with:
detections are merged across overlapping views, grouped into tracks, one target is chosen,
its path is smoothed, and a "lazy follower" camera moves only when the subject has drifted
more than a deadband and never faster than a slew limit. The field of view follows the
subject's size. The result is ordinary keyframes for reframe360.py, which you can still edit.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import SKILL_DIR, ToolError, duration_of, ffmpeg_bin, log, main_wrapper, parse_time, probe, video_stream  # noqa: E402

TILE_YAWS = (-90.0, 0.0, 90.0, 180.0)
PERSON_KINDS = ("human", "face")


# --- geometry -----------------------------------------------------------------------------------

def tile_point_to_direction(u: float, v: float, tile_yaw: float, tile_fov: float) -> tuple[float, float]:
    """A point (u, v in 0..1, origin top-left) of a flat view looking at `tile_yaw` → (yaw, pitch)."""
    half = math.tan(math.radians(tile_fov) / 2.0)
    x = (2.0 * u - 1.0) * half
    y = (2.0 * v - 1.0) * half          # down is positive, like v360's output
    z = 1.0
    norm = math.sqrt(x * x + y * y + z * z)
    x, y, z = x / norm, y / norm, z / norm
    c, s = math.cos(math.radians(tile_yaw)), math.sin(math.radians(tile_yaw))
    dx = x * c + z * s
    dz = -x * s + z * c
    yaw = math.degrees(math.atan2(dx, dz))
    pitch = -math.degrees(math.asin(max(-1.0, min(1.0, y))))
    return wrap180(yaw), pitch


def angular_height(box_height: float, tile_fov: float) -> float:
    """Degrees of the sphere a box of normalized height `box_height` spans (near the tile centre)."""
    return 2.0 * math.degrees(math.atan(box_height * math.tan(math.radians(tile_fov) / 2.0)))


def angular_distance(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Great-circle distance in degrees between two (yaw, pitch) directions."""
    def vec(d):
        yaw, pitch = math.radians(d[0]), math.radians(d[1])
        return (math.cos(pitch) * math.sin(yaw), math.sin(pitch), math.cos(pitch) * math.cos(yaw))
    va, vb = vec(a), vec(b)
    dot = max(-1.0, min(1.0, sum(p * q for p, q in zip(va, vb))))
    return math.degrees(math.acos(dot))


def wrap180(angle: float) -> float:
    return (angle + 180.0) % 360.0 - 180.0


def fov_for_subject(alpha: float, subject_height: float, fov_min: float, fov_max: float) -> float:
    """Horizontal 16:9 FOV that makes a subject of angular height `alpha` span `subject_height` of the frame."""
    v16 = max(alpha, 1.0) / max(subject_height, 0.05)
    v16 = min(v16, 150.0)
    fov = 2.0 * math.degrees(math.atan(math.tan(math.radians(v16) / 2.0) * 16.0 / 9.0))
    return min(max(fov, fov_min), fov_max)


# --- detections → tracks → target --------------------------------------------------------------

def to_directions(detections: list[dict], tile_fov: float) -> list[dict]:
    """Adds yaw/pitch/alpha to raw tile detections ({t, tile, kind, u, v, w, h, conf})."""
    out = []
    for det in detections:
        tile_yaw = TILE_YAWS[int(det["tile"])] if "tile" in det else float(det.get("tile_yaw", 0.0))
        yaw, pitch = tile_point_to_direction(float(det["u"]), float(det["v"]), tile_yaw, tile_fov)
        item = dict(det)
        item.update(yaw=yaw, pitch=pitch, alpha=angular_height(float(det["h"]), tile_fov))
        out.append(item)
    return out


def merge_frame(dets: list[dict], radius: float = 8.0) -> list[dict]:
    """Merge detections of the same thing seen in two overlapping views (keep the most confident)."""
    kept: list[dict] = []
    for det in sorted(dets, key=lambda d: -float(d.get("conf", 1.0))):
        if any(angular_distance((det["yaw"], det["pitch"]), (k["yaw"], k["pitch"])) < radius and
               (k["kind"] == det["kind"] or {k["kind"], det["kind"]} <= set(PERSON_KINDS)) for k in kept):
            continue
        kept.append(det)
    return kept


def build_tracks(directions: list[dict], *, gate_deg_per_s: float = 25.0, gate_floor: float = 6.0,
                 max_gap_s: float = 1.0) -> list[dict]:
    """Greedy nearest-angle association into tracks: [{kind, points: [{t, yaw, pitch, alpha, conf}]}]."""
    by_time: dict[float, list[dict]] = {}
    for det in directions:
        by_time.setdefault(round(float(det["t"]), 4), []).append(det)
    tracks: list[dict] = []
    for t in sorted(by_time):
        frame = merge_frame(by_time[t])
        open_tracks = [tr for tr in tracks if t - tr["points"][-1]["t"] <= max_gap_s]
        used = set()
        for det in sorted(frame, key=lambda d: -float(d.get("conf", 1.0))):
            best, best_dist = None, None
            for tr in open_tracks:
                if id(tr) in used or tr["kind"] != track_kind(det["kind"]):
                    continue
                last = tr["points"][-1]
                gate = gate_floor + gate_deg_per_s * (t - last["t"])
                dist = angular_distance((det["yaw"], det["pitch"]), (last["yaw"], last["pitch"]))
                if dist <= gate and (best_dist is None or dist < best_dist):
                    best, best_dist = tr, dist
            point = {"t": t, "yaw": det["yaw"], "pitch": det["pitch"], "alpha": det["alpha"],
                     "conf": float(det.get("conf", 1.0))}
            if best is None:
                tracks.append({"kind": track_kind(det["kind"]), "points": [point]})
            else:
                best["points"].append(point)
                used.add(id(best))
    for tr in tracks:
        pts = tr["points"]
        tr["start"], tr["end"] = pts[0]["t"], pts[-1]["t"]
        tr["presence_s"] = pts[-1]["t"] - pts[0]["t"]
        tr["mean_alpha"] = sum(p["alpha"] for p in pts) / len(pts)
        tr["mean_yaw"] = mean_angle([p["yaw"] for p in pts])
        tr["score"] = (tr["presence_s"] + 0.2) * tr["mean_alpha"] * sum(p["conf"] for p in pts) / len(pts)
    return tracks


def track_kind(kind: str) -> str:
    return "person" if kind in PERSON_KINDS else kind


def mean_angle(angles: list[float]) -> float:
    x = sum(math.cos(math.radians(a)) for a in angles)
    y = sum(math.sin(math.radians(a)) for a in angles)
    return wrap180(math.degrees(math.atan2(y, x)))


def choose_target(tracks: list[dict], target: str, hint: dict | None, min_presence: float = 1.0) -> dict | None:
    people = [tr for tr in tracks if tr["kind"] == "person" and tr["presence_s"] >= min_presence]
    animals = [tr for tr in tracks if tr["kind"] == "animal" and tr["presence_s"] >= min_presence]
    salient = [tr for tr in tracks if tr["kind"] == "saliency"]
    if target == "hint" and hint:
        candidates = people or animals or salient
        if not candidates:
            return None
        return min(candidates, key=lambda tr: hint_distance(tr, hint))
    if target == "person-central" and people:
        return min(people, key=lambda tr: abs(tr["mean_yaw"]))
    if target == "animal" and animals:
        return max(animals, key=lambda tr: tr["score"])
    if target in ("person-largest", "person-central", "animal") and people:
        return max(people, key=lambda tr: tr["score"])
    if animals:
        return max(animals, key=lambda tr: tr["score"])
    if salient:
        return max(salient, key=lambda tr: tr["score"])
    return None


def hint_distance(track: dict, hint: dict) -> float:
    t = float(hint.get("t", track["start"]))
    nearest = min(track["points"], key=lambda p: abs(p["t"] - t))
    penalty = abs(nearest["t"] - t) * 10.0
    return angular_distance((nearest["yaw"], nearest["pitch"]), (float(hint.get("yaw", 0.0)), float(hint.get("pitch", 0.0)))) + penalty


# --- path → camera → keyframes -------------------------------------------------------------------

def sample_path(track: dict, duration: float, rate: float, headroom: float = 0.25) -> list[dict]:
    """The target's aim point at a fixed rate; gaps hold the last known point; missing is flagged."""
    pts = track["points"]
    samples = []
    index = 0
    last = None
    n = int(round(duration * rate)) + 1
    for k in range(n):
        t = k / rate
        while index < len(pts) and pts[index]["t"] <= t + 1e-6:
            last = pts[index]
            index += 1
        if last is None:
            first = pts[0]
            samples.append({"t": t, "yaw": first["yaw"], "pitch": first["pitch"] + headroom * first["alpha"],
                            "alpha": first["alpha"], "seen": False})
        else:
            samples.append({"t": t, "yaw": last["yaw"], "pitch": last["pitch"] + headroom * last["alpha"],
                            "alpha": last["alpha"], "seen": (t - last["t"]) <= (1.0 / rate + 1e-6)})
    return samples


def gaussian_smooth(values: list[float], rate: float, sigma_s: float) -> list[float]:
    radius = max(1, int(round(3 * sigma_s * rate)))
    weights = [math.exp(-0.5 * (k / (sigma_s * rate)) ** 2) for k in range(-radius, radius + 1)]
    out = []
    for i in range(len(values)):
        acc = wsum = 0.0
        for k, w in zip(range(-radius, radius + 1), weights):
            j = min(max(i + k, 0), len(values) - 1)
            acc += w * values[j]
            wsum += w
        out.append(acc / wsum)
    return out


def unwrap_series(yaws: list[float]) -> list[float]:
    out = [yaws[0]]
    for yaw in yaws[1:]:
        out.append(out[-1] + wrap180(yaw - out[-1]))
    return out


def lazy_follow(targets: list[float], rate: float, deadband: float, max_slew: float) -> list[float]:
    """Camera that stays still inside a deadband around the target and moves at most max_slew °/s."""
    camera = [targets[0]]
    step = max_slew / rate
    for target in targets[1:]:
        current = camera[-1]
        error = target - current
        if abs(error) > deadband:
            wanted = target - math.copysign(deadband * 0.5, error)   # settle just inside the band
            move = max(-step, min(step, wanted - current))
            current += move
        camera.append(current)
    return camera


def ema(values: list[float], rate: float, tau_s: float) -> list[float]:
    alpha = 1.0 - math.exp(-1.0 / (tau_s * rate))
    out = [values[0]]
    for value in values[1:]:
        out.append(out[-1] + alpha * (value - out[-1]))
    return out


def camera_path(samples: list[dict], rate: float, *, deadband: float, max_slew: float, sigma_s: float,
                subject_height: float, fov_min: float, fov_max: float) -> list[dict]:
    yaw_u = unwrap_series([s["yaw"] for s in samples])
    yaw_s = gaussian_smooth(yaw_u, rate, sigma_s)
    pitch_s = gaussian_smooth([s["pitch"] for s in samples], rate, sigma_s)
    cam_yaw = lazy_follow(yaw_s, rate, deadband, max_slew)
    cam_pitch = lazy_follow(pitch_s, rate, deadband, max_slew)
    cam_pitch = [max(-80.0, min(80.0, p)) for p in cam_pitch]
    fovs = [fov_for_subject(s["alpha"], subject_height, fov_min, fov_max) for s in samples]
    fov_s = ema(fovs, rate, 1.5)
    return [{"t": s["t"], "yaw": y, "pitch": p, "fov": 5.0 * round(f / 5.0)}
            for s, y, p, f in zip(samples, cam_yaw, cam_pitch, fov_s)]


def keyframes_from_path(path: list[dict], every: float, duration: float) -> list[dict]:
    frames = []
    next_t = 0.0
    for point in path:
        if point["t"] + 1e-6 >= next_t:
            frames.append({"t": round(point["t"], 3), "yaw": round(wrap180(point["yaw"]), 2),
                           "pitch": round(point["pitch"], 2), "fov": point["fov"], "ease": "linear"})
            next_t += every
    last = path[-1]
    if not frames or frames[-1]["t"] < duration - 1e-6:
        frames.append({"t": round(min(last["t"], duration), 3), "yaw": round(wrap180(last["yaw"]), 2),
                       "pitch": round(last["pitch"], 2), "fov": last["fov"], "ease": "linear"})
    return frames


# --- Apple Vision detection (macOS) ---------------------------------------------------------------

def vision_available() -> tuple[bool, str]:
    if sys.platform != "darwin":
        return False, "Apple Vision needs macOS"
    try:
        import Quartz  # noqa: F401
        import Vision  # noqa: F401
        return True, "ok"
    except ImportError as error:
        return False, f"PyObjC's Vision wrappers are missing ({error}); run install.sh"


def reexec_in_venv_if_needed() -> None:
    """Hand over to the skill's venv (which has PyObjC) when the current Python lacks it."""
    if sys.platform != "darwin" or os.environ.get("INSTA360_NO_REEXEC"):
        return
    try:
        import Vision  # noqa: F401
        return
    except ImportError:
        pass
    for base in (Path(__file__).resolve().parent.parent, Path.home() / ".claude" / "skills" / "insta360-edit"):
        venv_python = base / ".venv" / "bin" / "python"
        if venv_python.exists() and Path(sys.executable).resolve() != venv_python.resolve():
            os.environ["INSTA360_NO_REEXEC"] = "1"
            os.execv(str(venv_python), [str(venv_python), *sys.argv])


class VisionDetector:
    def __init__(self, want_saliency: bool = True):
        import Quartz
        import Vision
        self.Quartz, self.Vision = Quartz, Vision
        self.want_saliency = want_saliency
        self.colorspace = Quartz.CGColorSpaceCreateDeviceRGB()

    def cgimage(self, rgb: bytes, width: int, height: int):
        Q = self.Quartz
        provider = Q.CGDataProviderCreateWithData(None, rgb, len(rgb), None)
        return Q.CGImageCreate(width, height, 8, 24, width * 3, self.colorspace,
                               Q.kCGBitmapByteOrderDefault | Q.kCGImageAlphaNone, provider, None, False,
                               Q.kCGRenderingIntentDefault)

    def detect(self, rgb: bytes, width: int, height: int) -> list[dict]:
        V = self.Vision
        image = self.cgimage(rgb, width, height)
        human = V.VNDetectHumanRectanglesRequest.alloc().init()
        if hasattr(human, "setUpperBodyOnly_"):
            human.setUpperBodyOnly_(True)
        requests = [("human", human), ("face", V.VNDetectFaceRectanglesRequest.alloc().init()),
                    ("animal", V.VNRecognizeAnimalsRequest.alloc().init())]
        if self.want_saliency:
            requests.append(("saliency", V.VNGenerateAttentionBasedSaliencyImageRequest.alloc().init()))
        handler = V.VNImageRequestHandler.alloc().initWithCGImage_options_(image, None)
        ok, error = handler.performRequests_error_([r for _, r in requests], None)
        if not ok:
            raise ToolError(f"Vision failed: {error}", kind="vision_failed")
        found = []
        for kind, request in requests:
            results = request.results() or []
            if kind == "saliency":
                observations = []
                for result in results:
                    observations += list(result.salientObjects() or [])
                results = observations
            for observation in results:
                box = observation.boundingBox()
                conf = float(observation.confidence()) if hasattr(observation, "confidence") else 1.0
                x, y = float(box.origin.x), float(box.origin.y)
                w, h = float(box.size.width), float(box.size.height)
                found.append({"kind": kind, "u": x + w / 2.0, "v": 1.0 - (y + h / 2.0), "w": w, "h": h,
                              "conf": conf})
        return found


def render_and_detect(src: Path, in_point: float, duration: float, rate: float, tile_size: int, tile_fov: float,
                      hwaccel: bool, detector: VisionDetector) -> list[dict]:
    """Streams flat views out of ffmpeg and runs Vision on each one."""
    views = []
    for tag, yaw in zip("abcd", TILE_YAWS):
        views.append(f"[{tag}]v360=input=e:output=flat:yaw={yaw:g}:pitch=0:h_fov={tile_fov:g}:v_fov={tile_fov:g}:"
                     f"w={tile_size}:h={tile_size}:interp=line[v{tag}]")
    graph = (f"[0:v]fps={rate:g},split=4[a][b][c][d];" + ";".join(views) +
             ";[va][vb][vc][vd]vstack=inputs=4,format=rgb24[o]")
    cmd = [ffmpeg_bin(), "-hide_banner", "-nostdin", "-loglevel", "error"]
    if hwaccel and sys.platform == "darwin":
        cmd += ["-hwaccel", "videotoolbox"]
    cmd += ["-ss", f"{in_point:.6f}", "-t", f"{duration:.6f}", "-i", str(src.resolve()), "-filter_complex", graph,
            "-map", "[o]", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    tile_bytes = tile_size * tile_size * 3
    frame_bytes = tile_bytes * len(TILE_YAWS)
    detections = []
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    frame_index = 0
    try:
        while True:
            data = proc.stdout.read(frame_bytes)
            if len(data) < frame_bytes:
                break
            t = frame_index / rate
            for tile in range(len(TILE_YAWS)):
                chunk = data[tile * tile_bytes:(tile + 1) * tile_bytes]
                for det in detector.detect(chunk, tile_size, tile_size):
                    det.update(t=round(t, 4), tile=tile)
                    detections.append(det)
            frame_index += 1
            if frame_index % int(rate * 5) == 0:
                log(f"tracked {t:.0f}s, {len(detections)} detections so far")
    finally:
        stderr = proc.stderr.read().decode(errors="replace")
        proc.wait()
    if proc.returncode != 0:
        raise ToolError(f"ffmpeg failed while rendering views: {stderr[-800:]}", kind="command_failed")
    return detections


def parse_hint(text: str | None) -> dict | None:
    if not text:
        return None
    hint = {}
    for part in text.split(","):
        if "=" in part:
            key, value = part.split("=", 1)
            hint[key.strip()] = float(value)
    return hint


# --- main ---------------------------------------------------------------------------------------

def main() -> dict:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("src", nargs="?", help="equirectangular 360 video")
    parser.add_argument("--in", dest="in_point", default="0")
    parser.add_argument("--to")
    parser.add_argument("--duration")
    parser.add_argument("-o", "--output", help="shot.json with the keyframes (default: stdout only)")
    parser.add_argument("--target", default="person-largest",
                        choices=["person-largest", "person-central", "animal", "saliency", "hint"])
    parser.add_argument("--hint", help='e.g. "t=3,yaw=40,pitch=0": the thing near this direction at this time')
    parser.add_argument("--rate", type=float, default=5.0, help="detections per second (default 5)")
    parser.add_argument("--tile-size", type=int, default=640)
    parser.add_argument("--tile-fov", type=float, default=100.0)
    parser.add_argument("--subject-height", type=float, default=0.22, help="target subject height as a fraction of the 16:9 frame")
    parser.add_argument("--fov-min", type=float, default=60.0)
    parser.add_argument("--fov-max", type=float, default=110.0)
    parser.add_argument("--kf-every", type=float, default=0.5)
    parser.add_argument("--deadband", type=float, default=4.0, help="degrees the subject may drift before the camera moves")
    parser.add_argument("--max-slew", type=float, default=30.0, help="max camera speed in degrees per second")
    parser.add_argument("--smooth", type=float, default=0.6, help="Gaussian smoothing of the subject path, seconds")
    parser.add_argument("--no-saliency", action="store_true")
    parser.add_argument("--detections-out", help="save the raw detections as JSON")
    parser.add_argument("--from-detections", help="skip detection; track this JSON (from --detections-out or tests)")
    parser.add_argument("--hw", dest="hwaccel", action="store_true", default=sys.platform == "darwin")
    parser.add_argument("--no-hw", dest="hwaccel", action="store_false")
    parser.add_argument("--probe-vision", action="store_true", help="report whether Apple Vision is usable and exit")
    args = parser.parse_args()

    if args.probe_vision:
        reexec_in_venv_if_needed()
        ok, why = vision_available()
        result = {"ok": ok, "vision": ok, "python": sys.executable, "why": why}
        if ok:
            detector = VisionDetector(want_saliency=True)
            blank = bytes(64 * 64 * 3)
            result["blank_frame_detections"] = len(detector.detect(blank, 64, 64))
        return result

    duration = None
    detections: list[dict]
    if args.from_detections:
        payload = json.loads(Path(args.from_detections).read_text())
        detections = payload["detections"] if isinstance(payload, dict) else payload
        tile_fov = float(payload.get("tile_fov", args.tile_fov)) if isinstance(payload, dict) else args.tile_fov
        if args.duration:
            duration = parse_time(args.duration)
        elif isinstance(payload, dict) and "duration" in payload:
            duration = float(payload["duration"])
        else:
            duration = max((float(d["t"]) for d in detections), default=0.0)
        in_point = 0.0
    else:
        if not args.src:
            raise ToolError("give a source video, or --from-detections", kind="bad_argument")
        reexec_in_venv_if_needed()
        ok, why = vision_available()
        if not ok:
            raise ToolError(why, kind="missing_tool", tool="vision")
        src = Path(args.src).expanduser()
        info = probe(src)
        if not video_stream(info):
            raise ToolError(f"{src} has no video stream", kind="bad_input")
        total = duration_of(info)
        in_point = parse_time(args.in_point)
        end = parse_time(args.to) if args.to else (in_point + parse_time(args.duration) if args.duration else total)
        duration = min(end, total) - in_point
        if duration <= 0:
            raise ToolError("--to must be after --in", kind="bad_argument")
        tile_fov = args.tile_fov
        detector = VisionDetector(want_saliency=not args.no_saliency)
        detections = render_and_detect(src, in_point, duration, args.rate, args.tile_size, tile_fov, args.hwaccel, detector)
        if args.detections_out:
            Path(args.detections_out).write_text(json.dumps(
                {"src": str(src), "in": in_point, "duration": duration, "rate": args.rate, "tile_fov": tile_fov,
                 "tile_yaws": list(TILE_YAWS), "detections": detections}, indent=1))

    directions = to_directions(detections, tile_fov)
    tracks = build_tracks(directions)
    target = choose_target(tracks, args.target, parse_hint(args.hint))
    summary_tracks = [{"kind": tr["kind"], "start": round(tr["start"], 2), "end": round(tr["end"], 2),
                       "mean_yaw": round(tr["mean_yaw"], 1), "mean_alpha": round(tr["mean_alpha"], 1),
                       "points": len(tr["points"])} for tr in sorted(tracks, key=lambda tr: -tr["score"])[:8]]
    if target is None:
        return {"ok": False, "kind": "no_target", "error": "nothing to follow was detected",
                "detections": len(detections), "tracks": summary_tracks}

    samples = sample_path(target, duration, args.rate)
    path = camera_path(samples, args.rate, deadband=args.deadband, max_slew=args.max_slew, sigma_s=args.smooth,
                       subject_height=args.subject_height, fov_min=args.fov_min, fov_max=args.fov_max)
    frames = keyframes_from_path(path, args.kf_every, duration)
    coverage = sum(1 for s in samples if s["seen"]) / max(len(samples), 1)
    shot = {"keyframes": frames,
            "tracking": {"target": {"kind": target["kind"], "start": round(target["start"], 2),
                                    "end": round(target["end"], 2), "mean_yaw": round(target["mean_yaw"], 1)},
                         "coverage": round(coverage, 3), "detections": len(detections), "tracks": summary_tracks,
                         "in": in_point, "duration": round(duration, 3)}}
    if args.output:
        Path(args.output).write_text(json.dumps(shot, indent=1))
    return {"ok": True, "output": args.output, **shot}


if __name__ == "__main__":
    sys.exit(main_wrapper(main))
