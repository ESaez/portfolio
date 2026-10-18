# Camera moves for 360 shots

Keyframes are `{t, yaw, pitch, roll, fov, ease}`; `t` counts from the clip's in-point.
`fov` is the horizontal field of view of the 16:9 master (30–120). The 9:16 render uses the
same diagonal, so the subject is the same size; `portrait_zoom` tightens it.

Yaw: 0 = front lens, +right, −left, ±180 behind. Pitch: 0 = horizon, + up, − down.
Easing `smooth` (default) accelerates and decelerates; `linear` is constant speed (what the
tracker emits); `hold` keeps the value until the next keyframe (a cut inside the sphere).

Speeds that read well: pans ≤ 20°/s for scenery, ≤ 45°/s when following action; tilts
≤ 15°/s; fov changes ≤ 10°/s. Finish a move with a hold of at least 1 s before the cut.

| Move | Keyframes | Use |
|---|---|---|
| **Hold** | `[{"yaw": 30, "pitch": -5, "fov": 90}]` | the default; one keyframe |
| **Establishing pan** | `[{"t":0,"yaw":-40,"pitch":-8,"fov":105,"ease":"hold"}, {"t":1.5,"yaw":-40,"pitch":-8,"fov":105}, {"t":7,"yaw":50,"pitch":-8,"fov":105}]` | wide, slow, 1.5 s still start |
| **Reveal** | `[{"t":0,"yaw":0,"pitch":-80,"fov":110}, {"t":3,"yaw":0,"pitch":-5,"fov":95}]` | from the ground up to the view |
| **Tiny planet intro** | `[{"t":0,"yaw":0,"pitch":-90,"fov":120}, {"t":1,"yaw":0,"pitch":-90,"fov":120}, {"t":4,"yaw":0,"pitch":-5,"fov":100}]` | the classic opener |
| **Push-in** | `[{"t":0,"yaw":20,"pitch":0,"fov":100}, {"t":4,"yaw":20,"pitch":0,"fov":65}]` | draws attention to a subject |
| **Pull-out** | `[{"t":0,"yaw":20,"pitch":-5,"fov":60}, {"t":4,"yaw":20,"pitch":-5,"fov":110}]` | ends a scene |
| **Orbit** | `[{"t":0,"yaw":0,"fov":90}, {"t":4,"yaw":120,"fov":90}, {"t":8,"yaw":240,"fov":90}, {"t":12,"yaw":360,"fov":90}]` | full turn; intermediate keyframes force the long way |
| **Look up** | `[{"t":0,"pitch":0,"fov":90}, {"t":3,"pitch":45,"fov":100}]` | trees, buildings, sky |
| **Whip to** | `[{"t":0,"yaw":-60,"fov":90}, {"t":2,"yaw":-60,"fov":90,"ease":"hold"}, {"t":2.3,"yaw":90,"fov":90}]` | fast cut-like move, 0.3 s |
| **Dutch tilt** | `[{"t":0,"roll":0,"fov":85}, {"t":4,"roll":-8,"fov":85}]` | use sparingly |
| **Follow** | `"follow": {"target": "person-largest"}` | tracker; see SKILL.md step 3 |

Putting a shot together: hold → move → hold. Example, an 8 s beach clip where the user walks
in from the right at 3 s:

```json
[{"t": 0, "yaw": -20, "pitch": -8, "fov": 105},
 {"t": 2, "yaw": -20, "pitch": -8, "fov": 105},
 {"t": 5, "yaw": 55, "pitch": -5, "fov": 80},
 {"t": 8, "yaw": 55, "pitch": -5, "fov": 80}]
```

Horizon: Insta360 Studio's horizon lock keeps the equirectangular horizon at pitch 0, so
`roll` stays 0 unless you want a dutch angle. If the export was made without horizon lock, a
tilted horizon can be levelled with a constant `roll` (check a scout grid: the horizon should
run along the centre line).
