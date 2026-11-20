# Third-Party Notices — GLITCH TIDE: BRAINROT HEIST: THE MEMEVERSE

Version 1.0.0 — 2026-11-18.

## Reused components

**No third-party code, assets, or libraries are reused in this project.**

No open-source libraries, no third-party Luau modules, no Wally / pesde
packages, no copied code snippets, no third-party models, images, audio,
or fonts are bundled in this project. All Luau code, character designs,
and documentation are original works created for this project.

## Tools and platform (not bundled, not included)

- **Roblox engine services** (DataStoreService, Players,
  ReplicatedStorage, ServerScriptService, StarterPlayer, StarterGui,
  Workspace, RunService, UserInputService, Teams, and related services)
  are the platform the game runs on. They are not part of this project
  and are not redistributed with it.
- **Rojo 7.7** is used only as a build / live-sync tool
  (`rojo serve`, `rojo build`). It is not bundled into the game and no
  Rojo code ships in the place file.

## Character names — original roster

The 18 character names in `src/shared/Characters.luau` (Wobble Waffleton,
Turbo Turnip, Bloop Bloomington, Crumb Comet, Noodle Nebula, Toast Ghost,
Disco Dumpling, Captain Picklebyte, Moon Mochi, Giga Gumball, Miso
Mothership, Puddle Professor, Springy Spaghetti, Zap Zucchini, Cosmic
Cupcake, Glitchy Goose, Caramel Crab, The Wobble King) are original names
created for this project. No Italian Brainrot meme character names,
designs, audio, images, or models are used anywhere in the project, and
no character model is a copy of an existing meme character — every model
is assembled in code from primitive parts and props.

## Summary

| Component | Source | Licence | Version | Modifications |
|---|---|---|---|---|
| (none) | — | — | — | — |

No third-party component is listed above because none is reused.
If a third-party component is added later, it must be recorded here
with its URL, licence, version, and modifications before release.

## make.fun kit file (bundled for the competition entry)

- **`vendor/makefun-roblox.ts`** — make.fun's Roblox place library, copied
  byte-for-byte and unmodified from the official `roblox-brainrot-01` kit
  (`starter/vendor/makefun-roblox.ts`, SHA-256
  `0add43584f2037edee560834c3d04c05c092071eb0007856e8ff199eb5c6f550`).
  The kit's starter is published under the MIT License
  (`SPDX-License-Identifier: MIT`, "Copyright (c) 2026 the make.fun team").
  It is used only by `main.ts` to write `dossier.json`; it is not part of the
  game place.
- **`main.ts`** is adapted from the kit starter's `main.ts` (MIT, make.fun team).
