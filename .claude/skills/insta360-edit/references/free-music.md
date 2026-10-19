# Free music for the edit

The user usually has no track of their own. Find one that is free to use, download it next
to the project, and credit it. Pick the music **after** scouting the footage, so the mood
matches what the film shows.

## Sources with a clear licence

| Source | Licence | Attribution | Notes |
|---|---|---|---|
| Kevin MacLeod, incompetech.com (Music → Royalty-Free) | CC BY 4.0 | required | 2000+ tracks, searchable by mood/feel; the track page has the direct MP3 download and the exact credit line |
| Scott Buckley, scottbuckley.com.au/library | CC BY 4.0 | required | cinematic, emotional, orchestral/ambient; each track page has a download link and the credit line |
| Free Music Archive, freemusicarchive.org | per track (CC0, CC BY, BY-SA, BY-NC, BY-ND…) | depends | filter by licence; for a film the user may post anywhere avoid NC and ND; download button on the track page |
| Pixabay Music, pixabay.com/music | Pixabay Content Licence | not required (appreciated) | large, moody, no account for downloads; cannot be redistributed as a standalone track |
| YouTube Audio Library | YouTube licence | some tracks require credit | needs a Google login, so only if the user downloads it themselves |

Avoid anything whose page does not state a licence, "no copyright" uploads on video sites,
and tracks marked NC/ND unless the user confirms the film is private and will not be edited
further. Never use a track that needs a paid licence.

## Picking the track

1. Mood from the scouted footage: wide landscapes and slow pans → calm cinematic ambient,
   piano or strings, 60–90 BPM; people walking, laughing, a city → warm acoustic or light
   indie, 90–120 BPM; a dramatic place (cliffs, storms, mountains) → orchestral build.
2. Length ≥ the film's length is best (looping is possible, `music.loop`, but a track that
   ends with the film is nicer; `fade_out` 2–3 s).
3. Two candidates: download both, mix each into a preview (`--quality preview`), let the
   user choose by ear. Instrumental only unless the user asks for vocals.

## Download and verify

```
mkdir -p edit-work/music
curl -L -o "edit-work/music/<Artist> - <Title>.mp3" "<direct URL from the track page>"
python3 $SKILL/scripts/mediainfo.py edit-work/music            # type audio, duration, codec
```

If `curl` gets an HTML page instead of audio (`mediainfo.py` says ffprobe could not read it),
the site wants the download started from the page: open the track page for the user, or use
the Fetch/Browser tool to find the real link. Pages that need a login: ask the user to download
the file into the folder.

## Credit

Write `deliver/CREDITS.txt` (and tell the user to paste it into the video description):

```
Music: "<Title>" by <Artist> (<source URL>)
Licensed under Creative Commons: By Attribution 4.0 — https://creativecommons.org/licenses/by/4.0/
```

For Pixabay or CC0 tracks the credit is optional, but still write the file so the source is
on record. Keep the licence text that was on the download page in `edit-work/music/` too.
