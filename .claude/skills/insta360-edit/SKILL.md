---
name: insta360-edit
description: Professional edits from Insta360 360° footage (equirectangular MP4 exports), normal videos and photos into 9:16 and 16:9 masters. Use when the user mentions Insta360, 360 video, reframing, equirectangular, 9:16 / 16:9, vertical video, Reels, Shorts, TikTok, or wants a montage with music from a folder of clips and photos. Scouts the sphere, proposes camera moves, follows people with Apple Vision, previews, then renders with cross-fades, ducked music and loudness normalization.
---

# insta360-edit

You are the editor. The user has a folder of Insta360 exports (360° equirectangular MP4),
ordinary videos and photos, maybe a music file, and wants finished 9:16 and 16:9 videos.
You scout the 360 footage, decide where the virtual camera looks and how it moves, show the
user a preview, then render. The scripts do the pixel work; you do the taste.

`$SKILL` below is the folder containing this file (normally `~/.claude/skills/insta360-edit`).
All scripts print one JSON document on stdout and log progress on stderr. A failure is
`{"ok": false, "kind": "...", "error": "..."}` with exit code 1; read `error`, fix, retry.
Scripts find ffmpeg by themselves (Homebrew's keg-only `ffmpeg-full` included). When you call
an ffmpeg-skill tool directly, prefix it with `PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"`.

## Rules

1. **Never modify, move or rename the user's files.** Everything you write goes to
   `./edit-work/` (intermediates, previews, scout frames) and `./deliver/` (finished videos).
2. **Preview before any long render.** Masters of a few minutes of 5.7K footage take a while;
   announce what you are about to render and how long it may take, and wait for approval
   unless the user already said "just render it".
3. **Say what you plan in plain words** ("0–4 s: the beach, panning right until you appear,
   then it follows you"), not as keyframe numbers. Keep the numbers in `project.json`.
4. **One shot list, two aspects.** The same camera moves render the 16:9 and 9:16 masters;
   do not design separate edits unless the user asks.
5. **`.insv` / `.insp` files cannot be read.** Ask for an Insta360 Studio export
   (see `references/insta360-export.md`) and continue with the other material meanwhile.
6. Work incrementally: the renderer caches every intermediate, so changing one shot costs one
   shot. Do not clear `edit-work/` unless asked.

## Workflow

### 1. Ingest

```
python3 $SKILL/scripts/mediainfo.py . --recursive
```

Prints a table (stderr) and JSON: for each file its type (`360`, `video`, `photo`, `audio`,
`insta360-raw`), duration, size, frame rate, audio. A video is `360` when it carries
spherical metadata or is exactly 2:1 and at least 1024 px wide. Summarize this for the user
and confirm which files belong in the edit and in what order (default: chronological by file
name, music underneath everything).

### 2. Scout each 360 clip

```
python3 $SKILL/scripts/scout.py CLIP.mp4 --outdir edit-work/scout/CLIP --every 5 --views --thumbs
```

Writes, per sample time `<t>`, `grid_<t>.png`: the whole sphere with a 30° grid and labels,
plus `views_<t>.png` (four flat views looking at yaw −90, 0, 90, 180) and contact sheets
`sheet_NN.png` of the whole clip. Read the grids with the Read tool. Convention, also printed
in `index.json`:

- **yaw** = x / width × 360 − 180 → 0 is the image centre (where the camera's front lens
  pointed), +90 is to the right, −90 to the left, ±180 behind.
- **pitch** = 90 − y / height × 180 → 0 is the horizon, +30 looks up, −30 looks down.
- One grid cell is 30°. The view strip shows what a 100° flat camera sees in each direction.

For a long clip, sample more often around interesting moments (`--times 12,15,18`) and use
`--in/--to` to limit the range. Decide for each clip: the in/out points (ffprobe-style
seconds or `mm:ss`), and a **shot**: either keyframes or a follow (step 3).

### 3. Design the shots

Keyframe fields: `t` (seconds from the clip's in-point), `yaw`, `pitch`, `roll` (degrees),
`fov` (horizontal field of view of the 16:9 master, 30–120, default 90), `ease`
(`smooth` default, `linear`, `hold`). Values not given keep their defaults; a single keyframe
is a static shot. Yaw always travels the short way round; to go the long way add a keyframe
in between. Named moves and good values are in `references/camera-moves.md`. Rules of thumb:

- Establishing shot: fov 100–110, pitch −5…−10, hold 2–3 s, then a slow pan (≤ 20°/s).
- A subject: fov 70–85, framed slightly above centre (pitch −5 if standing on the ground near
  the camera, which sits on a selfie stick above eye level).
- Never cut from a moving camera into a moving camera in the same direction twice in a row;
  alternate pans with holds. Don't exceed 45°/s or 15° of fov change per second.
- Tiny-planet intro: pitch −90, fov 120, then tilt up to the horizon over 3 s.

For a person (or pet) to follow, use the tracker:

```
python3 $SKILL/scripts/track360.py CLIP.mp4 --in 30 --to 38 -o edit-work/shots/CLIP_30.json \
    --target person-largest            # or person-central | animal | hint --hint "t=3,yaw=40,pitch=0"
```

It needs Apple Vision (macOS; `--probe-vision` tells you). It returns keyframes every 0.5 s
with linear easing, a deadband so small movements don't nudge the camera, a speed limit, and
an fov that follows the subject's size. `tracking.coverage` says what fraction of the segment
had the target; below 0.6, prefer hand keyframes or a shorter segment. `{"kind": "no_target"}`
means nobody was found: scout again and use keyframes.

### 4. Preview

```
python3 $SKILL/scripts/reframe360.py CLIP.mp4 --in 12.5 --to 20 --keyframes edit-work/shots/CLIP_12.json \
    --output 16:9=edit-work/preview/CLIP_12.mp4 --preview 0.5
```

`--preview 0.5` renders at half size, fast, with a burned-in time/yaw/pitch/fov overlay, and
writes `CLIP_12_sheet_01.png` (one frame per second). Look at the sheet: is the subject where
you wanted, is the horizon level, does the move land on time? Adjust and repeat. For a quick
check of the whole edit, render the project in preview quality (step 5 with `--quality preview`).

Show the user the preview files and describe the shot list. Ask for changes. Only then render.

### 5. Render

Write `edit-work/project.json` (schema and example in `references/project-schema.md`):
clips in order (each a 360 shot with keyframes or `follow`, a flat video with an `anchor`, or a
photo with `kenburns`), transitions, music, outputs. Then:

```
python3 $SKILL/scripts/render_project.py edit-work/project.json --dry-run   # plan and durations
python3 $SKILL/scripts/render_project.py edit-work/project.json             # both masters
python3 $SKILL/scripts/render_project.py edit-work/project.json --aspect 9:16 --quality preview
```

Per aspect it renders every clip at the canvas, joins them with cross-fades (ffmpeg-skill
`join.py`), mixes the music underneath with ducking (`audio.py`), normalizes to −14 LUFS
(`loudness.py`), and writes `deliver/<name>_9x16_1080x1920.mp4` and
`deliver/<name>_16x9_1920x1080.mp4` (H.264 High, AAC 256 kb/s, faststart). The JSON report has
per-aspect duration, loudness, sizes and any `warning`. Check the report, then look at a
one-frame-per-second sheet of each master before telling the user it's done:

```
ffmpeg -v error -i deliver/NAME_16x9_1920x1080.mp4 -vf "fps=1,scale=-2:180,tile=10x6" -frames:v 1 edit-work/check_16x9.png
```

### 6. Deliver

Tell the user the two file paths, the duration, that loudness is −14 LUFS (fine for every
platform), and offer the obvious follow-ups: a different music, re-timing a shot, captions
(ffmpeg-skill `caption.py`), a colour look (`color.py` / `look.py`), platform exports
(`export.py --preset reels|youtube`).

## Defaults you should use unless told otherwise

| Setting | Default | Notes |
|---|---|---|
| Masters | 1080×1920 and 1920×1080, H.264 CRF 12 intermediates / CRF 18 join | `"uhd": true` gives 3840×2160 for 16:9 when the 360 source is 5.7K and the flat clips are 4K |
| Frame rate | the 360 source's (usually 30) | set `fps` in project.json |
| Transition | `fade`, 0.5 s | `dissolve`, `wipeleft`, … or `none` for cuts |
| Music | −16 dB, ducked 12 dB under the clips' own sound, loops, 2 s fade-out | `"duck": false` if the clips have no speech |
| Loudness | −14 LUFS, −1 dBTP | `output.lufs` |
| Portrait framing | same diagonal as the 16:9 shot (`portrait_zoom` 1.0) | 1.15–1.25 for a tighter 9:16 when subjects look small |
| Photo | 4 s, slow zoom in 1.2×, no pan | `kenburns` |

## Troubleshooting

- `missing_tool` / "ffmpeg-skill is missing": run `$SKILL/install.sh` again.
- "v360 … is not in this ffmpeg" or "drawtext": Homebrew's plain `ffmpeg` lacks drawtext;
  the installer uses `ffmpeg-full`. Run `install.sh` or `brew install ffmpeg-full`.
- A `sendcmd` command failed (`commands_ok: false`): a keyframe is out of range; pitch is
  ±90, fov 30–120.
- Tracker says Vision is unavailable: it needs macOS and the `.venv` the installer makes
  (`install.sh` without `--no-vision`). Fall back to hand keyframes.
- Renders are slow: use `--quality preview` while iterating; 5.7K decoding dominates, pans
  are free, tilts and zooms re-solve the projection per frame.
- Clip looks soft in 9:16: it is a 1080-pixel-wide crop of a 5.7K sphere; narrow the fov
  (bigger subject, fewer source pixels stretched) or set `portrait_zoom`.
