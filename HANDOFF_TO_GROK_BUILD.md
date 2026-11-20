# HANDOFF TO GROK BUILD — pushing the GLITCH TIDE make.fun package

Prepared 2026-11-20 ~17:30 IST by Grok Bot (cloud box). Folder: `/workspace/GLITCH_TIDE_MAKEFUN_FINAL_SUBMISSION`
(ZIP: `/workspace/GLITCH_TIDE_MAKEFUN_FINAL_SUBMISSION.zip`). **Nothing has been pushed or submitted.**
Deadline: **20:00 IST (14:30 UTC) today, 2026-11-20.**

## A. Verify before pushing
```
unzip -q GLITCH_TIDE_MAKEFUN_FINAL_SUBMISSION.zip -d push && cd push/GLITCH_TIDE_MAKEFUN_FINAL_SUBMISSION
sha256sum -c FILE_MANIFEST_SHA256.txt          # all OK (manifest excludes itself)
sha256sum game.rbxl vendor/makefun-roblox.ts   # 1bf97d32…369f66 / 0add4358…c6f550
```

## B. Push to GitHub — a NEW branch only (never main, never force)
Repo: `https://github.com/Hemant09sharma/glitch-tide-brainrot-heist` (public, created 2026-11-18T23:06:45Z).
Base the commit on the existing `r5-release` commit so history is preserved:
```
git clone --branch r5-release https://github.com/Hemant09sharma/glitch-tide-brainrot-heist gt && cd gt
test "$(git rev-parse HEAD)" = e0f30a5efb8c4d1dd928fd409847365068bbeca0
git switch -c makefun-submission
# replace the working tree with the package (keep .git)
rsync -a --delete --exclude .git ../push/GLITCH_TIDE_MAKEFUN_FINAL_SUBMISSION/ ./
git add -A
git status --short          # expect: A main.ts, vendor/, game.rbxl, the 4 handoff docs, docs/makefun-validation/;
                            #         M LICENSE, .gitignore, rojo.toml, README.md, THIRD_PARTY_NOTICES.md. NO src/ changes.
git ls-files game.rbxl      # must print game.rbxl (the .gitignore exception)
git commit -m "make.fun package: main.ts, kit vendor, game.rbxl (R5), SPDX LICENSE"
git push -u origin makefun-submission     # only with the user's explicit go-ahead
```
Then re-run the official check from the unpacked kit (`https://make.fun/c/roblox-brainrot-01/kit`), Node ≥ 22.18:
```
node cli/makefun.mjs check --kit . --repo <path to gt> --commit $(git -C <gt> rev-parse HEAD)
```
Expected today: license_osi, entrypoint pass; play_link FAIL until step C is done.

## C. User-only steps (Roblox account owner, Windows Studio) — cannot be done by an agent here
1. Open `game.rbxl` in Roblox Studio (signed in). File → Publish to Roblox → new experience
   "GLITCH TIDE — Brainrot Heist: The Memeverse".
2. Get a play code: `node cli/makefun.mjs login` (connect the make.fun account), then
   `node cli/makefun.mjs check --kit . --repo <repo> --play-code 0`; paste the printed `makefun-…` code into the
   experience description (Game Settings → Basic Info) and save.
3. Creator Dashboard → set the experience **Public** (answer Roblox's questionnaires).
4. Playtest in Studio and capture **3–4 real screenshots** (16:9, long side ≤ 1280, short side ≥ 480, each ≤ 256 KiB;
   JPEG re-encode if larger). Name them so the cover sorts first, e.g. `1-cover.jpg`, `2-…`. Keep HUD text off the
   top-left corner.
5. Creator Dashboard → Places → start place → upload an **icon** and the **cover screenshot as the first thumbnail**
   (same file as `screenshots/1-…`). Both must pass Roblox review.
6. Write `PLAY.json` with the real IDs (game.PlaceId / game.GameId in Studio):
   `{"url": "https://www.roblox.com/games/<placeId>", "place_id": <placeId>, "universe_id": <universeId>}`
7. Add `screenshots/` and `PLAY.json` to the branch, commit, push (Grok Build, with go-ahead), re-run `check` until
   `play_link` passes and `MAKEFUN_OUTPUT_DIR=out node main.ts` exits 0.
8. `repo_owner`: the make.fun account must be signed in with GitHub `Hemant09sharma`, or commit
   `.makefun/owner.json` `{"wallet": "<wallet on the account>"}`.

## D. HARD ELIGIBILITY BLOCKER — recordings
The bounty takes only **sealed recordings made by `makefun record` while the agent built the game**, every line
timed after 2026-11-17 14:30 UTC; no transcript upload is accepted. No such recording exists (user-PC query
returned `{"recordings":[]}`; none on the box). A recording of this packaging session or a later push does **not**
witness the game's authorship and must not be presented as if it does. Without a qualifying recording,
`submit --recording <id>` cannot be satisfied honestly. Decision belongs to the user.

## E. Do NOT
Push to main · force-push · rewrite history · submit to make.fun · fabricate IDs/screenshots/recordings ·
modify `vendor/makefun-roblox.ts` · rebuild game.rbxl from anything but this `src/` with Rojo 7.7.1.
If src/ ever changes: `rojo build default.project.json --output game.rbxl`, re-run verify-rbxl.py and check.
