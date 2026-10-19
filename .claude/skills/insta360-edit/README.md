# insta360-edit

A Claude Code skill that edits Insta360 360° footage, ordinary videos and photos into
finished **9:16 and 16:9** videos: a keyframed virtual camera inside the sphere (pans, tilts,
zooms, reveals), automatic subject following with Apple Vision, cross-fades, ducked music and
loudness normalization. Built on [ffmpeg](https://ffmpeg.org) and
[ffmpeg-skill](https://www.npmjs.com/package/ffmpeg-skill) (pinned, checksum-verified).

## Install (macOS, once)

```sh
./install.sh
```

What it does, idempotently and without sudo:

1. Finds an ffmpeg with `v360`, `sendcmd`, `drawtext`, `loudnorm` and libx264. Homebrew's
   plain `ffmpeg` has no drawtext, so it installs `ffmpeg-full` (keg-only; the scripts find it).
2. Downloads ffmpeg-skill 2.10.4 from the npm registry, verifies its sha512, extracts it to
   `~/.claude/skills/ffmpeg-skill`.
3. Copies this folder to `~/.claude/skills/insta360-edit` (`--link` symlinks it for development).
4. Creates `~/.claude/skills/insta360-edit/.venv` with PyObjC's Vision and Quartz bindings
   for the tracker (`--no-vision` skips it).
5. Runs ffmpeg-skill's `doctor` and a self-test on synthetic footage.

Requirements: macOS 13+ on Apple Silicon or Intel, Homebrew, Python 3.9+ (3.10+ for the
tracker; Homebrew's `python@3.12` is fine). Linux works for everything except subject tracking.

## Use

```sh
cd ~/Movies/lisbon-trip        # the folder with the Insta360 exports, phone clips, photos, music
claude
> Edit this footage into a 9:16 and a 16:9 video with music.mp3; follow me in the beach clip.
```

Claude follows `SKILL.md`: it lists the media, scouts the 360 clips, proposes the shots in
plain words, shows previews, and after approval writes `deliver/<name>_9x16_1080x1920.mp4`
and `deliver/<name>_16x9_1920x1080.mp4`. Originals are never touched.

Insta360 exports must be **360 (equirectangular) MP4** from Insta360 Studio, 5.7K, with
FlowState and horizon lock on; see `references/insta360-export.md`.

## The scripts

| Script | Job |
|---|---|
| `mediainfo.py` | probe a folder: 360 / video / photo / audio, durations, frame rates, shooting order |
| `scout.py` | yaw/pitch-gridded frames, four flat views, contact sheets and an exposure map (sun, clean horizon) of a 360 clip |
| `reframe360.py` | keyframed virtual camera → flat 16:9 / 9:16 / 1:1 / 4:5 clip; preview mode with overlay |
| `track360.py` | Apple Vision person / face / animal detection on four flat views → smoothed follow keyframes |
| `render_project.py` | `project.json` → cached intermediates → join → music duck → loudness → masters |
| `make_test_footage.py` | synthetic sphere whose hue encodes yaw and brightness encodes pitch (tests) |
| `selftest.py` | the installer's end check |

How the reframer works: a pan is a horizontal scroll of the equirectangular image (exact and
free), tilt, roll and zoom are `v360` commands sent per frame through `sendcmd` with
smooth-step easing; one `fov` number gives both aspects the same subject size through the
diagonal field of view.

## Tests

```sh
python3 -m unittest discover -s tests -v
```

Runs on synthetic footage; needs ffmpeg and ffmpeg-skill. CI runs it on Ubuntu (apt ffmpeg)
and macOS (Homebrew ffmpeg-full, with the Vision smoke test) in
`.github/workflows/insta360-edit.yml`.

## Layout

```
SKILL.md                 what Claude does
install.sh               installer
scripts/                 the tools above (+ _common.py)
references/              Insta360 export settings, project.json schema, camera moves, free music, Mac session prompt
tests/                   unittest suite
```
