# project.json

The input of `scripts/render_project.py`. Paths are relative to the file (absolute paths work
too). Unknown keys are ignored. Everything but `clips` has a default.

```json
{
  "name": "Lisbon",
  "fps": 30,
  "portrait_zoom": 1.0,
  "clips": [
    {"src": "VID_20250914_101500_00_001.mp4", "type": "360", "in": 12.5, "to": 20,
     "keyframes": [{"t": 0, "yaw": 0, "pitch": -5, "fov": 100},
                   {"t": 2, "yaw": 0, "pitch": -5, "fov": 100, "ease": "hold"},
                   {"t": 6, "yaw": 110, "pitch": -10, "fov": 80}]},
    {"src": "VID_20250914_101500_00_001.mp4", "type": "360", "in": 30, "to": 38,
     "follow": {"target": "person-largest", "hint": "t=2,yaw=40,pitch=0"}},
    {"src": "IMG_2231.MOV", "type": "video", "in": 0, "to": 6.2, "anchor": {"x": 0.5, "y": 0.35}},
    {"src": "IMG_2240.jpg", "type": "photo", "duration": 4, "kenburns": {"zoom": "in", "amount": 1.25, "pan": "left"}}
  ],
  "transitions": {"type": "fade", "duration": 0.5},
  "music": {"src": "track.mp3", "gain_db": -16, "duck": true, "fade_out": 2, "loop": true},
  "output": {"aspects": ["9:16", "16:9"], "quality": "master", "uhd": false, "dir": "deliver", "lufs": -14}
}
```

## Top level

| Key | Default | Meaning |
|---|---|---|
| `name` | folder name | base of the delivered file names (`Lisbon_9x16_1080x1920.mp4`) |
| `fps` | 30 | output frame rate; every clip is conformed to it |
| `portrait_zoom` | 1.0 | tightens 9:16 (and 4:5) renders of 360 shots; 1.2 ≈ 20 % closer |
| `clips` | required | in playback order |
| `transitions` | `{"type": "fade", "duration": 0.5}` | between every pair of clips; `type` is any ffmpeg-skill join transition (`fade`, `dissolve`, `wipeleft`, `wiperight`, `slideleft`, `circleopen`, …) or `none` for cuts |
| `music` | none | see below |
| `output` | see below | |

## Clips

Common: `src` (required), `type` (`360` / `video` / `photo`, auto-detected when missing:
image extensions are photos, spherical metadata or 2:1 ≥ 1024 px wide is 360, else video).

**360 and video**: `in` (default 0) and `to` or `duration` (default: to the end), in seconds
or `mm:ss(.fff)`. The clip's own audio is kept.

**360** needs one of:

- `keyframes`: list of `{t, yaw, pitch, roll, fov, ease}`; `t` is seconds from `in`. Missing
  fields default to 0 / fov 90 / ease `smooth` (`linear`, `hold` = stay until the next
  keyframe). Yaw moves the short way round. Limits: pitch ±90, fov 30–120. One keyframe =
  static shot.
- `follow`: `{"target": "person-largest" | "person-central" | "animal" | "saliency" | "hint",
  "hint": "t=2,yaw=40,pitch=0", "subject_height": 0.22, "fov_min": 60, "fov_max": 110,
  "deadband": 4, "max_slew": 30, "rate": 5}`; runs `track360.py` (macOS + Apple Vision) and
  caches the resulting keyframes in `edit-work/tracking/`. If both are given, `keyframes` win.
- optional `pan`: `"scroll"` (default; pans as an exact scroll of the sphere) or `"v360"`.

**video**: `anchor` `{"x": 0..1, "y": 0..1}` is the point kept in frame when the clip is
cropped to the canvas (default centre; `y: 0.3` keeps heads in a 9:16 crop of a landscape
clip). `fit: "pad"` letterboxes instead of cropping.

**photo**: `duration` (default 4), `kenburns` `{"zoom": "in" | "out", "amount": 1.25, "pan":
"left" | "right" | "up" | "down"}`. Photos are silent.

## Music

| Key | Default | Meaning |
|---|---|---|
| `src` | required | any audio or video file |
| `gain_db` | −16 | music level relative to full scale |
| `duck` | true | lower the music 12 dB (`duck_amount_db`) while the clips' own audio is loud, `duck_release_ms` 600 |
| `loop` | true | repeat if shorter than the edit |
| `fade_out` | 2 | seconds at the end |
| `fade_in` | 0 | seconds at the start |

## Output

| Key | Default | Meaning |
|---|---|---|
| `aspects` | `["9:16", "16:9"]` | also `1:1` (1080²) and `4:5` (1080×1350) |
| `quality` | `master` | `preview` renders at half size, fast, with the camera overlay on 360 shots, named `*_preview.mp4` |
| `uhd` | false | 16:9 at 3840×2160 and 9:16 at 2160×3840 |
| `dir` | `deliver` | relative to the project file |
| `lufs` | −14 | integrated loudness target (true peak is always −1 dBTP) |

## CLI

```
render_project.py project.json [--aspect 9:16 ...] [--quality master|preview] [--force] [--dry-run] [--work DIR]
```

`--dry-run` plans and reports the expected duration of each aspect. `--work` defaults to
`edit-work` next to the project file; intermediates live in `clips/<aspect>/`, `join/`,
`mix/`, `loud/`, `tracking/`, each with a `.json` sidecar holding the cache key. `--force`
re-renders everything. The report lists, per aspect, every clip (`cached`, `path`, `shot`
kind), `final`, `duration_s`, `loudness_lufs`, `size_mb`, `video`, and a `warning` if the
duration is off by more than 0.35 s from the plan.
