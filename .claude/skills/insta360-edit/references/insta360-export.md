# Exporting from Insta360 Studio for this skill

The camera's own `.insv` (video) and `.insp` (photo) files are two fisheye images in a
container ffmpeg cannot read. Export once from Insta360 Studio (free, macOS) and keep the
originals.

## Video (X3, X4, X5, ONE X2, ONE RS 1-inch 360)

1. Open the clip in Insta360 Studio and keep it in **360 mode** (not "Reframe": a reframed
   export is already flat and the skill can't move the camera inside it).
2. Stabilization: **FlowState** on, **Horizon lock** on (keeps the horizon at pitch 0 so
   the virtual camera never needs roll). Direction lock off.
3. Export → **360 video**:
   - Format **MP4**, codec **H.264** (H.265 also works; H.264 decodes faster on the Mac).
   - Resolution: the maximum the clip has (**5.7K = 5760×2880**, 4K = 3840×1920). Never below
     4K: a 9:16 master is a ~90° slice of the sphere, so 5.7K gives ~1440 source pixels for a
     1080-wide frame.
   - Frame rate: as recorded (30 is normal; 60 only if the clip was shot at 60).
   - Bitrate: the highest preset.
   - Keep audio.
4. The result is an equirectangular 2:1 MP4 with spherical metadata; `mediainfo.py` lists it
   as `360`.

Batch: select several clips → Export, same settings. Each export takes roughly real-time to
2× real-time on Apple Silicon.

## Photos

Export `.insp` as **360 photo** (JPEG, equirectangular, 2:1). `mediainfo.py` classifies it as
a photo; to use it as a 360 shot (e.g. a tiny-planet opener) convert it to a short clip first:

```
ffmpeg -loop 1 -framerate 30 -t 5 -i PHOTO.jpg -c:v libx264 -crf 12 -pix_fmt yuv420p -r 30 edit-work/PHOTO_360.mp4
```

then treat `edit-work/PHOTO_360.mp4` as a `360` clip with `type: "360"`.

## Normal videos and photos

iPhone and camera files need no preparation. HEIC photos and HEVC videos are read directly
by ffmpeg. Vertical phone videos in a 16:9 master are padded, landscape clips in 9:16 are
cropped around the `anchor` you set in `project.json`.
