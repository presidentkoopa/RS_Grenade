# RS_Grenade — lane close-out

Written 2026-09-04. Read this before touching the grenade again.

## What it is

A universal VR grenade. Slot 9, one `Weapon` class. Select it and it is in your
hand; hold that hand's fire to open the pin window; bring it to your face and
hold to pull the pin with your teeth; swing your arm and release fire to throw.

Everything lives in `E:\DOOMWork\RS_Grenade`, builds with `build.ps1`, ships as
`RS_Grenade.pk3`.

## Load order no longer matters

It used to require loading after `RS_VR_Unified.pk3`, and that broke the whole
game three separate times across three folder layouts — `RS_Grenade` sorts before
`RS_VR_Unified`, so any loader listing a directory alphabetically gets it wrong
by default, and a ZScript error is fatal AND global.

It is now standalone. Palm position comes from `pmo.AttackPos` / `pmo.OffhandPos`
(native, `actor.zs:390,412`) and the throw is measured in-file. No reference to
`RS_Reach`, `RS_Throw`, `RS_Held` or `RS_GrabPolicy` remains. **Do not
reintroduce one** without accepting that constraint knowingly.

## ENGINE CHANGES — NOT LOCAL TO THIS LANE

Four edits went into `E:\DOOMWork\UZDXREMA`. All four are in the tree and were
swept into a commit by another lane. Anyone reading the engine should know they
came from here.

**1. `src/QzDoom/qzdoom_common.cpp` — `VR_HapticEvent` implemented.**
It was an empty function body. Every built-in haptic in the game calls it —
weapon fire, bullets, fireballs, slime, pickups, doors, health stations, ~20 call
sites — each computing an intensity from its `ext_haptic_level_*` cvar and handing
it to nothing. That is why those nine settings did nothing.

**2. `vk_openxrdevice.cpp` — `TearDown()` no longer calls `StopHaptics()`.**
This is why haptics never fired *at all*, including mod ones. `TearDown` is not a
shutdown hook: `hw_entrypoint.cpp:278` calls it at the end of every rendered
frame. `StopHaptics` cancels and then zeroes `xrHapticDuration`/`xrHapticIntensity`
unconditionally — the whole pump's state. Every pulse was erased in the frame it
was requested. It now calls `ProcessHaptics()` instead.

**3. `vk_openxrdevice.cpp` — `kMaxPulseMs` 10 → 50.**
The per-issue window is deliberately short because the pump re-issues each frame,
but 10ms is shorter than a frame (11.1ms at 90Hz), so every pulse had a dead gap
even once (2) was fixed.

**4. `model.h` + `models.cpp` — new MODELDEF `PivotOffset x y z`.**
The point a model turns about, in its own space. `Offset` cannot express this: it
is applied AFTER the rotations, so it moves a model without moving what it spins
around — a mesh authored off-centre orbits its origin instead of rotating in
place, and no `Offset` value shrinks that orbit. `PivotOffset` is subtracted
before them (`v' = R * (v - p)`). Zero by default; present on both the world and
HUD paths; also readable live as `<prefix>_piv_x/_y/_z`.

The ordering in `ObjectToWorldMatrix` is load-bearing and commented as such — it
is written *after* the rotate calls precisely because `VSMatrix` post-multiplies.
Move it above them and it silently becomes a second `Offset`.

**The hands want this too.** `hand_left.iqm`'s origin runs -22.35 to +10.60 on its
long axis, nowhere near the palm — which is the same class of problem, and the
reason the world hands needed offsets found by hand in a headset.

## Traps this lane paid for

- **`CVar.FindCVar` cannot see `user`-scope cvars.** It returns null without
  erroring, so every read falls through to its hardcoded fallback and the entire
  menu drives nothing, silently. Use `CVar.GetCVar(name, player)`.
- **A CVARINFO default never applies where the value is already in the ini.** So a
  corrected default reaches everyone *except* the person hitting the bug. There is
  a one-shot migration keyed on `rsvg_cfgver` for exactly this — bump `CFG_VERSION`
  when a default changes for a reason a player should not have to know about.
- **`SetStateLabel` does not return, and does not stop `Tick` next frame.** Treating
  it as a return gave 35 explosions a second. Latch before the state change.
- **A `Weapon` with no `Fire` state will not compile**, even if unreachable.
- **`MODELDEF FrameIndex` sets only the model index it names** and leaves the others
  at whatever the previous line left them, then pushes a copy. Two independent
  frame groups therefore draw BOTH meshes at once. The fix is to park the unwanted
  index at `-1` first and let the carry-over work for you — see the frame table
  comment in `MODELDEF.txt`.
- **Sounds under `sounds/` are looked up by BARE filename**, path and extension
  stripped (`filesystem.cpp:134` for the namespace, `:157` for the short name). A
  full path does not match.
- **`autoexec.cfg` had a stale `vr_haptic_debug 0`** that quietly clobbered the
  tracer every launch, which made an empty log read as evidence. Removed.
- **ModelSwapper token-matches weapon tags.** A tag containing "grenade" binds
  Brutal Doom's nade model *and its throw animation*. The tag here is "Frag".

## Known limits

- **The two-handed pin pull is off by default** (`rsvg_offhand_pin`). Two hands and
  a small object at arm's length has no reach value that is both reliable to hit
  and tight enough not to misfire.
- **The thrown grenade tumbles about its own pivot now**, but nothing simulates
  rolling — `p_physics.cpp` still has no public add-body call, so a grenade cannot
  be handed to the solver. Doom bounce plus explicit settle-and-drag is what it
  has. `P_PhysicsAdoptBody(AActor*)` remains unbuilt and is the honest next step
  if rolling matters.
- **`RS_Reach.Centre` refines the palm to the `HANDPALM_joint` bone**; this uses the
  raw controller position. For a grenade drawn at its own tuned offset that is the
  right anchor, but it is a difference.

## State at close

Working tree is dirty and uncommitted: `CVARINFO.txt`, `MENUDEF.txt`,
`MODELDEF.txt`, `zscript/rs_vrgrenade.zs`, plus untracked
`models/grenade/nade_red.png`. Last commit is `5fbaa73`.

The red skin flash and the full options menu are in that uncommitted set and had
not been confirmed in a headset when the lane closed.
