# SUBMISSION CHECKLIST — GLITCH TIDE (make.fun `roblox-brainrot-01`)

Built 2026-11-20 (~17:10–17:30 IST) on Grok Bot's cloud box from the **official kit** downloaded from
`https://make.fun/c/roblox-brainrot-01/kit` (`roblox-brainrot-01-kit.tar.gz`, kit.json `bundle_sha256`
`0ca08c49f7bc9d313dea81a29e37b3c56acaca0bdc2e198e4021c14eee80cdf5`; `makefun check` reported "verified 21 files").
Requirements below are taken from that kit's `RULES.txt`, `starter/`, `kit.json` and the competition API
(`/api/competitions/roblox-brainrot-01`). Deadline: **2026-11-20 14:30 UTC = 20:00 IST**.

Status key: DONE · BLOCKED (needs a person/account) · N/A

| # | Requirement (source) | Status | Evidence / who must act |
|---|---|---|---|
| 1 | `main.ts` at repo root, Node 22, copies game.rbxl/src/screenshots/PLAY.json to /output, writes dossier.json with `buildDossier` (RULES "The task") | DONE | Based on kit starter main.ts; same copy filter + caps; adds a preflight that names missing inputs. `check` → `entrypoint: pass` |
| 2 | `vendor/makefun-roblox.ts` = kit copy, unchanged | DONE | SHA-256 `0add4358…c6f550` = kit.json entry |
| 3 | Root `LICENSE` with OSI SPDX id (gate `license_osi`) | DONE | `SPDX-License-Identifier: MIT` added above the existing MIT text. `check` → pass |
| 4 | `game.rbxl` binary place (≤32 MiB), not .rbxlx (gate `place_file`) | DONE | Fresh R5 Rojo 7.7.1 build, 676,532 B, SHA `1bf97d32…369f66`, built twice identical |
| 5 | Every script as `.luau` under `src/`; src matches place, ≥80% coverage (gate `source_matches_place`) | DONE | 68/68 matched, coverage 100% (local emulation with the kit library); `verify-rbxl.py` 0 failed |
| 6 | Place within caps, ≥1 non-empty script (gate `place_scripts`) | DONE | 76 instances, 68 non-empty scripts |
| 7 | `game.rbxl` is actually committed | DONE | R5 `.gitignore` ignored `*.rbxl`; added `!game.rbxl` exception (verified tracked in local check repo) |
| 8 | `screenshots/` 3–4 PNG/JPEG, ≤256 KiB each, long side ≤1280, short side ≥480, 16:9, real Studio captures; first by name = cover = Roblox thumbnail (gate `screenshots`) | **BLOCKED** | No Roblox client/Studio on the Linux box; **user** must capture in Studio (Windows). Not fabricated. |
| 9 | `PLAY.json` `{"url":"https://www.roblox.com/games/<placeId>","place_id":<placeId>,"universe_id":<universeId>}`, real Public start place (gates `entry_link_file`, `play_link`) | **BLOCKED** | Not published; no Roblox credentials on the box. **User** publishes in Studio and fills real IDs. File intentionally absent (no fake IDs). `check` → `play_link: FAIL` |
| 10 | Experience Public, description holds a make.fun play code | **BLOCKED** | **User** (Roblox account owner). Play code: `node cli/makefun.mjs check --repo <repo> --play-code 0` after `makefun login/register` |
| 11 | Icon + thumbnail uploaded on Creator Dashboard and past Roblox review; first thumbnail = one of screenshots/ | **BLOCKED** | **User**, Creator Dashboard |
| 12 | `dossier.json` byte-for-byte what buildDossier writes (gate `dossier_matches`) | DONE (pipeline) / BLOCKED (final) | main.ts produces identical dossier on two runs in a test copy (with kit stub images + kit zero PLAY.json, test only, not packaged). Final dossier needs real screenshots |
| 13 | `luau_compiles` (informational) | DONE | luau-compile 68/68 |
| 14 | Public GitHub repo owned by entrant, created after opening (2026-11-17 14:30 UTC) | DONE (repo) | `Hemant09sharma/glitch-tide-brainrot-heist` public, created 2026-11-18T23:06:45Z (04:36 IST 19 Nov) |
| 15 | Submitted commit pushed to a branch of the repo (`commit_in_repo`) | PENDING | Grok Build push (see HANDOFF) |
| 16 | `repo_owner` = account's GitHub login or `.makefun/owner.json` | PENDING | User's make.fun account must be signed in with GitHub `Hemant09sharma`, or commit owner.json with their wallet |
| 17 | **Sealed recordings** of the agent sessions that built the game, made by `makefun record` while the agent built it; every line timed after opening (transcript gate) | **BLOCKED — HARD ELIGIBILITY BLOCKER** | No recording exists: prior query on the user's PC returned `{"recordings":[]}`; no `~/.makefun` on the box; repo's QA report records no recording. Cannot be created after the fact. |
| 18 | ≤5 submissions/day, ≤10 total; last before deadline counts | N/A here | No submission made |
| 19 | No dot-named files under /output | DONE | main.ts filters dot names (`src/map/.gitkeep` skipped); verified in test output |
| 20 | `default.project.json`, `rojo.toml` | DONE | R5 versions; `rojo.toml` build output renamed to `game.rbxl` (comment/config only; Rojo itself builds from default.project.json) |
| 21 | README.md, THIRD_PARTY_NOTICES.md | DONE | README gains a make.fun section; notices add the kit vendor file (MIT, make.fun team) |
| 22 | `TOUR.json` (optional) | N/A | Optional; not created (would need real screenshots/keys) |
