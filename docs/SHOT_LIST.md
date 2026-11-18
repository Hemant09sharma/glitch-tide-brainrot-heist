# SHOT LIST — GLITCH TIDE v1.1 (Workstream A)
# Photographable compositions for eventual Studio capture.
#
# These are CAPTURE INSTRUCTIONS, not screenshots. No screenshot,
# recording, or image in this repo was produced by this workstream —
# there is no Studio here. Grok Build (or whoever runs Studio) should
# set the listed zone + mood, stage the listed subjects, and capture
# each shot as described. "Mood" means LightingService.SetMood(name);
# if LightingService is not registered yet, reproduce the mood by hand
# from the values in src/server/Services/LightingService.luau.
#
# How to set a mood in Studio (once registered):
#   require(ServerScriptService.Services.LightingService).SetMood("Hub")
# How to reach a dimension in Studio (once registered):
#   walk into the hub portal, or
#   require(...DimensionsService).TeleportToDimension(player, "abyssal")
#   — note TeleportToDimension validates portal proximity, so for a
#   staged shot use the portal, or move the character to the portal
#   first. Do NOT teleport by setting CFrame by hand for a "gameplay"
#   shot and then claim the portal worked.

## Shot 1 — Rift Market + Memeverse overview
- **Zone:** RiftMarket / MemeversePlaza (camera above the market, looking south toward the plaza).
- **Mood / time:** `Market` (ClockTime 15.5, warm). If LightingService is absent, set ClockTime 15.5 by hand.
- **Camera:** High wide angle from above the conveyor's east end (~x 40, y 35, z -90), looking down the belt toward the plaza and the portal ring. The belt, both gates, the four market stalls, the market arch, the plaza tower and the main portal ring must all read in one frame.
- **What must be visible:** the conveyor belt with Brainrots riding it (spawn 3–4 via ConveyorService), the market stalls + arch, the plaza tower + beacon, the main portal ring, at least 2 players (one at the belt buying, one walking to the plaza).
- **Why:** the "this is a living market town" establishing shot; also proves the v1.1 market architecture (stalls/arch/lanterns) in frame.

## Shot 2 — Base with multiple Brainrots
- **Zone:** BaseDistrict, any claimed plot (plot 1 at (120, 0, 0) photographs cleanest against the plaza).
- **Mood / time:** `Hub` (ClockTime 14, neutral daylight).
- **Camera:** Low three-quarter angle from the plot gate, ~15 studs out, slightly above eye level, looking in across the pedestals toward the owner sign.
- **What must be visible:** at least 4 placed Brainrots on pedestals (different rarities — use the owner's collection), the plot totem in its plot colour, the owner sign showing the player's name, the upgrade station, the gate. The neighbouring plot's totem should be visible at the frame edge to show plots are distinguishable.
- **Why:** proves the core loop's payoff (a lived-in base) and the v1.1 per-plot identity (totem + pillar colours).

## Shot 3 — Tide survival moment
- **Zone:** TideChannel, at the escape platforms / safe shelters (z = 75, x = 0 platform photographs best).
- **Mood / time:** `TideActive` (dark storm) — or `TideWarning` (orange) if the shot is staged during the warning phase. Start a real tide: TideService.ForceStart("Standard") and shoot during Active.
- **Camera:** Low angle from south of the channel (~x 0, y 8, z 110), looking north across the water at the escape platform, with the wave wall mid-sweep if possible.
- **What must be visible:** the glowing channel + wave wall, at least 2 players on the escape platform (one mid-jump from the ramp), a safe shelter with its roof + sign in the background, the sirens, the tide-gauge tower. One player outside a safe zone taking the tide hit is ideal but must be a real tide hit, not staged damage.
- **Why:** the signature event; proves the channel dressing (buoys, piers, gauge tower) and the survival gameplay in one frame. Do NOT fake the wave — if the wave wall is not visible, say so in the caption.

## Shot 4 — Boss battle / mutation transformation
- **Zone:** ChaosArena (boss) or MutationLab (transformation) — two framings, one shot slot; take both if time allows, otherwise the boss.
- **Mood / time:** `Boss` (dark red) for the arena; `Market` is wrong here — use `Boss`.
- **Camera (boss):** Wide angle from the arena's south edge (~x 75, y 12, z 85), looking north across the platform at THE ALGORITHM, with the four corner pillars and the champion's dais framing the shot.
- **What must be visible (boss):** the boss model mid-fight, at least 2 players attacking (Q ability effects visible), the arena pillars + braziers, the reward chest. Health state is shown via WaveUpdate, not BossUpdate (BossUpdate is never fired — see audit §4a).
- **Camera (mutation):** Close angle at the MutationLab fusion chamber (~x -67, y 4, z 55), chamber centred, lab machine + pipes + vats in the background.
- **What must be visible (mutation):** a Brainrot on the preview pad, the fusion chamber glowing, the lab coils. The "transformation" is the mutation being applied via the Shop Mutations tab — capture the before/after as two frames, not one faked frame.
- **Why:** the two spectacle moments. The boss shot also exercises the v1.1 arena architecture (pillars/braziers/dais).
