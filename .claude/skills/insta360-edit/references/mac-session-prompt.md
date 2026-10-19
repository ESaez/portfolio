# Running an edit on the Mac

The cloud session that developed this skill cannot see the Mac's files or run ffmpeg on
them. The edit runs in a Claude session on the Mac:

1. Claude Desktop app → new session **on this computer** → choose the folder with the
   footage (for example `~/Desktop/videos`). Or, in Terminal: `cd ~/Desktop/videos && claude`.
2. Paste the prompt below and answer its questions (it previews before rendering).

## Prompt

```
Set up and use the insta360-edit skill, then edit the media in this folder.

Setup: if ~/portfolio does not exist, run
  git clone https://github.com/ESaez/portfolio.git ~/portfolio
then
  cd ~/portfolio && git fetch origin && git checkout claude/gallant-dijkstra-kxec8g && git pull
and run ./.claude/skills/insta360-edit/install.sh (it installs ffmpeg-full through Homebrew if
needed, ffmpeg-skill, and Apple Vision support, and ends with a self-test). Then read
~/.claude/skills/insta360-edit/SKILL.md and follow it exactly, working in this folder.

Brief: a professional 2–3 minute video in both 9:16 and 16:9. Focus on the scenery and on the
two people who appear in the photos here (look at the photos first to learn how they look,
then find and follow them in the 360 clips). Prefer frames and directions where the
environment is clearly visible with little glare: use scout's exposure map and keep the sun
out of frame. Find free music that matches the footage (see references/free-music.md) and
credit it in deliver/CREDITS.txt. Do not modify my original files. Show me the shot list in
plain words and the previews, and wait for my OK before rendering the masters.
```

## What happens next

- `mediainfo.py` lists the folder in shooting order; the session confirms the material.
- `scout.py` writes gridded frames and the exposure map to `edit-work/scout/`; the session
  proposes shots and shows previews in `edit-work/preview/`.
- After the OK, `render_project.py` writes `deliver/<name>_9x16_1080x1920.mp4` and
  `deliver/<name>_16x9_1920x1080.mp4` plus `deliver/CREDITS.txt`. Masters take roughly
  real-time to 2× real-time per minute of 5.7K footage on Apple Silicon.
