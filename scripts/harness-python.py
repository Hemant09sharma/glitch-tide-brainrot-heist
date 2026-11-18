#!/usr/bin/env python3
"""GLITCH TIDE static harness — 70 checks over the v1.1 src/ tree.

v1.1 update (2026-11-19, integration): the 50 v1.0.2 checks with
expectations moved to v1.1 (roster 27, GameVersion 1.1.0, 10 tide
variants, 19 fusion recipes, 54 quests, 17 playable powers, no
disabled tide table), the two make.fun-package-only checks (vendor
file, PLAY.json.template — they belong to the competition package,
not the game tree) replaced by GameManager registration + EquipTitle
wiring, plus 20 new v1.1 checks (51-70: new characters, companions
and their wiring, new services, dimensions, lighting, achievements,
expeditions, territories, remotes, dead-path fixes, sound hygiene).

Read-only regex/JSON checks only — no Roblox, no Studio, no network.

Read-only regex/JSON checks only — no Roblox, no Studio, no network.
Run from the package root:  python3 scripts/harness-python.py
Exit 0 iff all 70 checks pass. A failing check names the files/lines
involved; fix the GAME (or, only when the check itself is provably
wrong about the source, the check) and re-run.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
KIT_VENDOR_SHA = "0add43584f2037edee560834c3d04c05c092071eb0007856e8ff199eb5c6f550"

passed, failed = [], []


def check(n, name, ok, detail=""):
    (passed if ok else failed).append(n)
    print(f"{'PASS' if ok else 'FAIL'} {n:02d}  {name}" + (f" -- {detail}" if detail else ""))


def _walk_keys(node):
    """Yield every dict key in a nested JSON value (so a '$class' key
    is found as a KEY, not as a substring of '$className')."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield k
            yield from _walk_keys(v)
    elif isinstance(node, list):
        for v in node:
            yield from _walk_keys(v)


def read(rel):
    return (SRC / rel).read_text(errors="replace")


def strip_comments(text):
    """Remove Luau -- line comments and --[[ ]]-- blocks (best effort;
    string literals containing '--' are rare in this tree and none of
    the code-only checks below depend on one)."""
    text = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
    return "\n".join(line.split("--", 1)[0] for line in text.splitlines())


def table_block(text, assign):
    """Return the {...} body of `assign = { ... }` (first close brace at
    column 0 / matching `\\n}`), or '' when absent. A Luau type
    annotation between the name and `=` (e.g. `X: { T } = {`) is allowed."""
    m = re.search(re.escape(assign) + r"(?:\s*:\s*\{[^}]*\})?\s*=\s*\{(.*?)\n\}", text, re.S)
    return m.group(1) if m else ""


def num_table(body):
    return dict(re.findall(r"(\w+)\s*=\s*([0-9.]+)", body))


all_luau = sorted(SRC.rglob("*.luau"))
all_text = {str(p.relative_to(SRC)): p.read_text(errors="replace") for p in all_luau}
code_text = {k: strip_comments(v) for k, v in all_text.items()}
joined = "\n".join(all_text.values())
joined_code = "\n".join(code_text.values())

# --- 1-8. Rojo project -------------------------------------------------
try:
    proj = json.loads((ROOT / "default.project.json").read_text())
    check(1, "project.json valid JSON, name GlitchTide",
          proj.get("name") == "GlitchTide", f"name={proj.get('name')}")
    check(2, "project.json uses $className, no $class",
          "$className" in proj["tree"]
          and not any(k == "$class" for k in _walk_keys(proj["tree"])))
    tree = proj["tree"]
    check(3, "ReplicatedStorage -> src/shared",
          tree.get("ReplicatedStorage", {}).get("$path") == "src/shared")
    check(4, "ServerScriptService -> src/server",
          tree.get("ServerScriptService", {}).get("$path") == "src/server")
    check(5, "StarterGui direct DataModel child -> src/client/ui",
          tree.get("StarterGui", {}).get("$path") == "src/client/ui")
    sps = tree.get("StarterPlayer", {}).get("StarterPlayerScripts", {})
    check(6, "StarterPlayerScripts exactly Main + Controllers",
          set(sps) == {"Main", "Controllers"}
          and sps["Main"].get("$path") == "src/client/Main.client.luau"
          and sps["Controllers"].get("$path") == "src/client/Controllers",
          f"keys={sorted(sps)}")
    check(7, "Workspace -> src/map",
          tree.get("Workspace", {}).get("$path") == "src/map")
except Exception as e:  # noqa: BLE001 - report as check failures
    for n in range(1, 8):
        check(n, "project.json checks", False, str(e))

check(8, "src/map exists in the package (Workspace target)",
      (SRC / "map").is_dir(), "src/map/.gitkeep keeps the empty dir tracked")

# --- 9-11. Tree hygiene -------------------------------------------------
check(9, "68 Luau files under src/ (48 v1.0.2 + 20 v1.1)", len(all_luau) == 68, f"found {len(all_luau)}")
check(10, "no .md files under src/", not list(SRC.rglob("*.md")))
dot_src = [str(p.relative_to(SRC)) for p in SRC.rglob("*")
           if p.name.startswith(".") and str(p.relative_to(SRC)) != "map/.gitkeep"]
dot_shots = [p.name for p in (ROOT / "screenshots").rglob("*") if p.name.startswith(".")] if (ROOT / "screenshots").is_dir() else []
check(11, "no unexpected dot-names under src/ or screenshots/",
      not dot_src and not dot_shots,
      f"src: {dot_src} screenshots: {dot_shots} (map/.gitkeep is the one allowed dot-name: main.ts excludes dot-names from /output)")

# --- 12-19. Config / roster / weights ----------------------------------
cfg = read("shared/Config.luau")
check(12, "Config.GameVersion is 1.1.0", '"1.1.0"' in cfg)
chars = read("shared/Characters.luau")
roster = re.findall(r"(?m)^\t\tId = \"([a-z0-9_]+)\"", chars)
check(13, "roster has 27 characters", len(roster) == 27, f"found {len(roster)}")
powers_src = read("shared/Powers.luau")
power_ids = set(re.findall(r"Id = \"([a-z_]+)\"", powers_src))
ability_ids = re.findall(r"AbilityId = \"([a-z_]+)\"", chars)
check(14, "every roster AbilityId resolves to a Power",
      len(ability_ids) == 27 and all(a in power_ids for a in ability_ids),
      f"{len(ability_ids)} AbilityIds, unresolved={[a for a in ability_ids if a not in power_ids]}")
rarities = re.findall(r"Rarity = \"(\w+)\"", chars)
ladder = ["Common", "Uncommon", "Rare", "Epic", "Legendary",
          "Mythic", "Divine", "Celestial", "Secret", "Impossible"]
check(15, "every roster Rarity is on the 10-tier ladder",
      len(rarities) == 27 and all(r in ladder for r in rarities),
      f"tiers used={sorted(set(rarities))}")
incomes = [int(v) for v in re.findall(r"IncomePerSec = (\d+)", chars)]
costs = [int(v) for v in re.findall(r"Cost = (\d+)", chars)]
check(16, "roster IncomePerSec > 0 and Cost >= 0",
      len(incomes) == 27 and all(i > 0 for i in incomes)
      and len(costs) == 27 and all(c >= 0 for c in costs))
weights = num_table(table_block(cfg, "Config.RarityWeights"))
check(17, "RarityWeights sum to 1.0 over 10 tiers",
      len(weights) == 10 and abs(sum(map(float, weights.values())) - 1.0) < 1e-9,
      f"sum={sum(map(float, weights.values()))} over {len(weights)} tiers")
conv = num_table(table_block(cfg, "Config.ConveyorRarityWeights"))
conv_total = sum(map(float, conv.values()))
aligned = (set(conv) == set(weights)
           and all(abs(float(conv[k]) / conv_total - float(weights[k])) < 1e-9
                   for k in weights))
check(18, "ConveyorRarityWeights: 10 tiers, aligned with RarityWeights",
      len(conv) == 10 and aligned, f"total={conv_total}")
check(19, "MaxBasePlots == MaxPlayers == 12",
      "Config.MaxBasePlots = 12" in cfg and "Config.MaxPlayers = 12" in cfg)

# --- 20-23. Keybinds ------------------------------------------------------
kb = table_block(cfg, "Config.Keybinds")
check(20, "keybinds Q/F/R/E/G + loadout 1/2/3 in Config.Keybinds",
      all(f'{k} = "{v}"' in kb for k, v in
          [("Primary", "Q"), ("Slam", "F"), ("Heal", "R"), ("Interact", "E"),
           ("Drop", "G"), ("Loadout1", "1"), ("Loadout2", "2"), ("Loadout3", "3")]))
slots = table_block(cfg, "Config.AbilitySlots")
check(21, "AbilitySlots matches Keybinds (Q/F/R)",
      all(f'{k} = "{v}"' in slots for k, v in
          [("Primary", "Q"), ("Slam", "F"), ("Heal", "R")]))
gen = table_block(cfg, "Config.GenericAbilities")
check(22, "GenericAbilities F=slam, R=heal (no Q/E collision)",
      'F = "slam"' in gen and 'R = "heal"' in gen and '"Q"' not in gen)
utils = read("shared/Utils.luau")
check(23, "Utils.GetKeybinds: Interact E, Drop G",
      'Interact = "E"' in utils and 'Drop = "G"' in utils)

# --- 24-25. Remotes -------------------------------------------------------
rem = read("shared/Remotes.luau")
# Names table keys are the source of truth.
names = set(re.findall(r"(?m)^\t(\w+) = \"[A-Za-z]+\"", table_block(rem, "Remotes.Names")))
referenced = set(re.findall(r"(?:getRemote|GetRemote|GetFunction)\(\"([A-Za-z]+)\"\)", joined))
event_names = set(re.findall(r'"([A-Za-z]+)"', table_block(rem, "EVENT_NAMES")))
func_names = set(re.findall(r'"([A-Za-z]+)"', table_block(rem, "FUNCTION_NAMES")))
check(24, "referenced remote names exist in Remotes.Names; EVENT/FUNCTION tables ⊆ Names",
      referenced <= names and event_names <= names and func_names <= names,
      f"referenced={sorted(referenced)}, unknown={[r for r in referenced if r not in names]}, "
      f"event/function outside Names={sorted((event_names | func_names) - names)}")
unwired = ["SynergyUpdate", "SettingsUpdate", "UsePower"]
fired = set(re.findall(r"fireAll\(\"([A-Za-z]+)\"", joined))
fired |= set(re.findall(r"fireClient\(_names\.([A-Za-z]+)", joined))
fired |= set(re.findall(r"FireAllClients\(\"([A-Za-z]+)\"", joined))
boss_svc = read("server/Services/BossService.luau")
check(25, "BossUpdate now fired by BossService; SynergyUpdate/SettingsUpdate/UsePower declared but unwired by documented decision",
      'fireAll("BossUpdate"' in boss_svc
      and all(u in names for u in unwired) and not (set(unwired) & fired)
      and "UsePower" in rem and "SettingsUpdate" in rem,
      f"fired-unwired={[u for u in unwired if u in fired]}")

# --- 26-30. RemoteFunction handlers ---------------------------------------
check(26, "RequestQuests has a server OnServerInvoke",
      "OnServerInvoke" in all_text["server/Services/QuestService.luau"]
      and "RequestQuests" in all_text["server/Services/QuestService.luau"])
check(27, "RequestCollection has a server OnServerInvoke",
      "OnServerInvoke" in all_text["server/Services/ProgressionService.luau"]
      and "RequestCollection" in all_text["server/Services/ProgressionService.luau"])
check(28, "RequestEvents has a server OnServerInvoke",
      "OnServerInvoke" in all_text["server/Services/EventService.luau"]
      and "RequestEvents" in all_text["server/Services/EventService.luau"])
check(29, "RequestShop has a server OnServerInvoke (EconomyService)",
      "OnServerInvoke" in all_text["server/Services/EconomyService.luau"]
      and "RequestShop" in all_text["server/Services/EconomyService.luau"])
check(30, "RequestBase has a server OnServerInvoke (BaseService)",
      "OnServerInvoke" in all_text["server/Services/BaseService.luau"]
      and "RequestBase" in all_text["server/Services/BaseService.luau"])

# --- 31. WaitForChild / require targets -----------------------------------
shared_mods = {p.stem for p in (SRC / "shared").glob("*.luau")}
services = {p.stem for p in (SRC / "server" / "Services").glob("*.luau")}
controllers = {p.stem for p in (SRC / "client" / "Controllers").glob("*.luau")}
known_instances = {"PlayerGui", "Remotes", "Services", "Controllers",
                   "StarterGui", "StarterPlayerScripts"}
wfc_targets = set(re.findall(r"WaitForChild\(\"([A-Za-z]+)\"\)", joined))
resolvable = shared_mods | services | controllers | known_instances | names | {"Main", "GameManager"}
unresolved = sorted(t for t in wfc_targets if t not in resolvable)
# require(script.Parent.X) resolves against the REQUIRING file's own
# directory: shared modules resolve against shared/, services against
# Services/, controllers against Controllers/. (The first version of
# this check wrongly resolved every require against shared/ only.)
dir_mods = {
    "shared": shared_mods,
    "server/Services": services,
    "client/Controllers": controllers,
    "client": {"Main"},
    "server": {"Main"},
}
unresolved_req = []
for rel, text in all_text.items():
    parent_dir = str(Path(rel).parent)
    siblings = dir_mods.get(parent_dir, shared_mods)
    for r in re.findall(r"require\(script\.Parent\.([A-Za-z]+)\)", text):
        if r not in siblings and r not in shared_mods:
            unresolved_req.append(f"{rel}:{r}")
    for r in re.findall(r"require\(script\.Parent\.Parent\.([A-Za-z]+)\)", text):
        if r not in shared_mods:
            unresolved_req.append(f"{rel}:{r}")
unresolved_req = sorted(set(unresolved_req))
check(31, "WaitForChild / require targets resolve",
      not unresolved and not unresolved_req,
      f"unresolved WaitForChild={unresolved}, unresolved require={unresolved_req}")

# --- 32-34. Hygiene --------------------------------------------------------
check(32, "no TODO/FIXME/STUB markers in src/",
      not re.search(r"TODO|FIXME|STUB", joined))
italian = ["Tung Tung", "Tralalero", "Bombardiro", "Chimpanzini", "Lirili", "Ballerina"]
found_it = [n for n in italian if n.lower() in joined.lower()]
check(33, "no copyrighted Italian Brainrot names in src/",
      not found_it, f"found: {found_it}" if found_it else "clean")
check(34, "no 'Brainrot Battle Arena' branding in src/",
      "Brainrot Battle Arena" not in joined)

# --- 35-38. Tide / mutations / camera --------------------------------------
tide_vars = re.findall(r"(\w+) = \{", table_block(cfg, "Config.TideVariations"))
tide_svc = read("server/Services/TideService.luau")
check(35, "10 playable tide variations, each with behaviour in TideService",
      sorted(tide_vars) == ["Corrupted", "Cosmic", "Dark", "Double", "Fast",
                            "Frozen", "GiantBoss", "Meteor", "Standard", "Toxic"]
      and all(v in tide_svc for v in tide_vars),
      f"variations={sorted(tide_vars)}")
check(36, "TideVariationsDisabled table deleted (only a comment may mention it)",
      "Config.TideVariationsDisabled = {" not in cfg
      and "TideVariationsDisabled" not in table_block(cfg, "Config.TideVariations"))
check(37, "Magma/Spectral appear only in comments, never in code",
      ("Magma" in joined or "Spectral" in joined)
      and "Magma" not in joined_code and "Spectral" not in joined_code)
cam_refs = [(f, i + 1) for f, t in all_text.items()
            for i, line in enumerate(t.splitlines())
            if re.search(r"CurrentCamera|CameraType|CameraSubject", line)]
cam_files = sorted({f for f, _ in cam_refs})
check(38, "camera touched only by CameraController/EffectsController (13 refs)",
      cam_files == ["client/Controllers/CameraController.luau",
                    "client/Controllers/EffectsController.luau"]
      and len(cam_refs) == 13,
      f"files={cam_files}, refs={len(cam_refs)}")

# --- 39-44. Fusion / rebirth / mutations -----------------------------------
mut = read("shared/Mutations.luau")
recipes = re.findall(r"ResultId = \"([a-z0-9_]+)\"", mut)
check(39, "19 fusion recipes, every ResultId a real character",
      len(recipes) == 19 and all(r in roster for r in recipes),
      f"recipes={len(recipes)}, bad={[r for r in recipes if r not in roster]}")
check(40, "GetFusionRecipe is order-independent (both orders tested)",
      ("first == characterIdA and second == characterIdB" in mut
       and "first == characterIdB and second == characterIdA" in mut))
fusion_costs = table_block(cfg, "Config.FusionCosts")
check(41, "FusionCosts 1000 coins + 25 crystals",
      "Coins = 1000" in fusion_costs and "MutationCrystals = 25" in fusion_costs)
reb = table_block(cfg, "Config.RebirthRequirements")
check(42, "rebirth requirements canonical (L25, 100000 coins, 10 distinct, +10%, +2 slots, 25 gems, max 10)",
      all(s in reb for s in ["Coins = 100000", "Level = 25", "Brainrots = 10",
                             "RewardGems = 25", "IncomeBonusPerRebirth = 0.10",
                             "SlotsPerRebirth = 2", "MaxRebirths = 10"]))
mut_ids = re.findall(r"(?m)^\t\tId = \"([A-Za-z]+)\"", mut)
check(43, "12 mutations, no Magma/Spectral mutation Ids",
      len(mut_ids) == 12 and "Magma" not in mut_ids and "Spectral" not in mut_ids,
      f"mutations={mut_ids}")
mut_svc = read("server/Services/MutationService.luau")
check(44, "mutation compatibility enforced (CanMutate used by MutationService)",
      "CanMutate" in mut and "CanMutate" in mut_svc)

# --- 45-47. Quests / events / powers ---------------------------------------
quest_svc = read("server/Services/QuestService.luau")
quest_ids = re.findall(r"Id = \"(q_[a-z0-9_]+)\"", quest_svc)
check(45, "54 quests; Epic Discovery requires Epic+ (rank >= 4)",
      len(quest_ids) == 54 and "q_discover_epic" in quest_ids
      and "rank >= 4" in quest_svc,
      f"quests={len(quest_ids)}")
event_svc = read("server/Services/EventService.luau")
event_ids = re.findall(r"Id = \"([a-z_]+)\"", event_svc)
check(46, "6 world events", len(event_ids) == 6, f"events={event_ids}")
playable = re.findall(r"Id = \"([a-z_]+)\"", table_block(powers_src, "PLAYABLE_LIST"))
check(47, "17 playable powers",
      len(playable) == 17, f"playable={len(playable)}")

# --- 48. The 7 v1.0.1 integration fixes -------------------------------------
shop = read("client/Controllers/ShopController.luau")
hud = read("client/Controllers/HUDController.luau")
gm = read("server/Services/GameManager.luau")
base_svc = read("server/Services/BaseService.luau")
char_svc = read("server/Services/CharacterService.luau")
econ_svc = read("server/Services/EconomyService.luau")
fixes = {
    "I1 getRemote per-name (no GetRemotes)": "GetRemotes()" not in strip_comments(char_svc)
        and "getRemote(\"SelectCharacter\")" in char_svc,
    "I2 RequestQuests handler + push": "OnServerInvoke" in quest_svc,
    "I2b RequestCollection/RequestEvents handlers": "OnServerInvoke" in all_text["server/Services/ProgressionService.luau"]
        and "OnServerInvoke" in event_svc,
    "I3 Fusion tab (rebuildFusion)": "rebuildFusion" in shop and "FuseBrainrot" in shop,
    "I4 EventUpdate/TideSurvivor listeners": "EventUpdate" in hud and "TideSurvivor" in hud,
    "I5 Golden Hour via SetEventService": "SetEventService" in base_svc and "SetEventService" in gm,
    "I6 BurstLimit on Buy/SelectCharacter": "BurstLimit" in econ_svc and "BurstLimit" in char_svc,
    "I7 inert findNearest stub (no attribute scan)": "findNearest" in read("client/Controllers/InteractionController.luau"),
}
missing_fixes = [k for k, v in fixes.items() if not v]
check(48, "all 7 v1.0.1 integration fixes present (+ I7 stub)",
      not missing_fixes, f"missing={missing_fixes}")

# --- 49-50. v1.1 integration ----------------------------------------------
gm = read("server/Services/GameManager.luau")
new_services = ["LightingService", "EnvironmentService", "DimensionsService",
                "CompanionService", "LaboratoryService", "ExpeditionService",
                "TerritoryService", "SecretService", "AchievementService"]
check(49, "GameManager OPTIONAL_SERVICES lists all 9 new services + explicit Init branches for Lab/Territory/Secret/Achievement",
      all(f'"{s}"' in gm for s in new_services)
      and all(f'name == "{s}"' in gm for s in
              ["LaboratoryService", "TerritoryService", "SecretService", "AchievementService"]),
      f"missing={[s for s in new_services if f'\"{s}\"' not in gm]}")
ach_svc = read("server/Services/AchievementService.luau")
check(50, "EquipTitle server handler wired in AchievementService (integration fix)",
      "EquipTitle" in ach_svc and "OnServerEvent" in ach_svc
      and "SetEquippedTitle" in ach_svc)

# --- 51-70. v1.1 expansion ----------------------------------------------
new_ids = ["phantom_pancake", "prism_penguin", "neon_narwhal", "reactor_raccoon",
           "gravity_goblin", "thunder_tortoise", "quantum_quokka", "solar_sloth", "void_vulture"]
check(51, "9 new v1.1 characters present (one per tier Common..Secret)",
      all(n in roster for n in new_ids) and len(roster) == 27,
      f"missing={[n for n in new_ids if n not in roster]}")
shapes = set(re.findall(r'BodyShape = "([A-Za-z]+)"', chars))
models = read("shared/CharacterModels.luau")
check(52, "every BodyShape has a builder in CharacterModels",
      all(s in models for s in shapes),
      f"shapes={sorted(shapes)}, missing={[s for s in shapes if s not in models]}")
comp_svc = read("server/Services/CompanionService.luau")
companion_getters = ["GetBonuses", "GetIncomeMultiplier", "IsTideProtected",
                     "GetRareWeightMultiplier", "GetCarrySpeedMultiplier",
                     "GetRaidWarningSeconds", "GetMutationIncomeBonus"]
check(53, "15 CompanionAbility entries; all 7 companion getters exist",
      chars.count("CompanionAbility = {") == 15
      and all(g in comp_svc for g in companion_getters),
      f"entries={chars.count('CompanionAbility = {')}")
carry_svc = read("server/Services/CarryService.luau")
conv_svc = read("server/Services/ConveyorService.luau")
raid_svc = read("server/Services/RaidService.luau")
check(54, "all 6 companion bonuses wired (income/tide/carry/mutation/rare/raid)",
      "GetCompanionIncomeMultiplier" in base_svc
      and "CompanionService" in gm and "IsTideProtected" in gm
      and "SetCompanionService" in carry_svc and "GetCarrySpeedMultiplier" in carry_svc
      and "GetMutationIncomeBonus" in base_svc
      and "GetRareWeightMultiplier" in conv_svc
      and "GetRaidWarningSeconds" in raid_svc)
check(55, "all 9 new v1.1 services exist as files",
      all((SRC / "server" / "Services" / f"{s}.luau").exists() for s in new_services),
      f"missing={[s for s in new_services if not (SRC / 'server' / 'Services' / f'{s}.luau').exists()]}")
dims = read("shared/Dimensions.luau")
dim_svc = read("server/Services/DimensionsService.luau")
check(56, "dimensions Abyssal + Skyfall defined; TeleportToDimension + save/load exist",
      "Abyssal" in dims and "Skyfall" in dims
      and "TeleportToDimension" in dim_svc
      and "GetStateForSave" in dim_svc and "LoadState" in dim_svc)
light_svc = read("server/Services/LightingService.luau")
moods = ["Hub", "Market", "Abyssal", "Skyfall", "TideWarning", "TideActive",
         "Toxic", "Frozen", "Meteor", "Dark", "Cosmic", "Boss"]
check(57, "LightingService: 12 moods + SetMood/GetMood",
      all(m in light_svc for m in moods) and "SetMood" in light_svc and "GetMood" in light_svc,
      f"missing={[m for m in moods if m not in light_svc]}")
ach_defs = read("shared/AchievementDefs.luau")
exp_defs = read("shared/ExpeditionDefs.luau")
lab_svc = read("server/Services/LaboratoryService.luau")
terr_svc = read("server/Services/TerritoryService.luau")
terr_ids = ["plaza", "market", "lab", "arena", "rift", "abyssal", "skyfall"]
check(58, "24 achievements + 13 titles; 6 expeditions; 7 territories; Lab Evolve exists",
      len(re.findall(r'Id = "ach_', ach_defs)) == 24
      and len(re.findall(r'Id = "title_', ach_defs)) == 13
      and len(re.findall(r'Id = "', exp_defs)) == 6
      and all(f'Id = "{t}"' in terr_svc for t in terr_ids)
      and "EvolveBrainrot" in lab_svc)
check(59, "QuestService ReportProgress + story-chain Requires field",
      "ReportProgress" in quest_svc and "Requires" in quest_svc)
new_remotes = ["TeleportDimension", "RequestDimensions", "DimensionUpdate",
               "RequestLab", "LabUpdate", "EvolveBrainrot", "RequestExpeditions",
               "ExpeditionUpdate", "StartExpedition", "ClaimExpedition",
               "RequestTerritories", "TerritoryUpdate", "CaptureTerritory",
               "SecretDiscovered", "RequestAchievements", "AchievementUnlocked", "EquipTitle"]
check(60, "all 17 v1.1 remote names in Remotes.Names",
      all(r in names for r in new_remotes),
      f"missing={[r for r in new_remotes if r not in names]}")
ability_ctrl = read("client/Controllers/AbilityController.luau")
inter_ctrl = read("client/Controllers/InteractionController.luau")
check(61, "Attack firer (AbilityController) + StealBrainrot firer (InteractionController)",
      '"Attack"' in ability_ctrl and "FireServer" in ability_ctrl
      and 'fireRemote("StealBrainrot"' in inter_ctrl)
coll_ctrl = read("client/Controllers/CollectionController.luau")
check(62, "RequestCollection + RequestEvents invoked by clients",
      "RequestCollection" in coll_ctrl and "InvokeServer" in coll_ctrl
      and "RequestEvents" in hud and "InvokeServer" in hud)
check(63, "BossUpdate listener in HUD; UsePower/SettingsUpdate decisions documented in Remotes.luau",
      "BossUpdate" in hud and "UsePower" in rem and "SettingsUpdate" in rem)
eff_ctrl = read("client/Controllers/EffectsController.luau")
check(64, "EffectsController accepts both SpawnEffect forms (table + positional)",
      "onSpawnEffectTable" in eff_ctrl and "TWO forms" in eff_ctrl)
code_only = "\n".join(line.split("--", 1)[0] for line in joined.splitlines())
check(65, "no rbxassetid:// uses in src/ code (2 comment mentions only, explaining no invented IDs)",
      "rbxassetid://" not in code_only)
check(66, "stale Utils slam-on-E comment removed",
      'binds slam to "E"' not in utils and 'stale "E" for slam' not in utils)
data_svc = read("server/Services/DataService.luau")
new_fields = ["Expeditions", "Achievements", "Titles", "Prestige",
              "LabDiscoveries", "SecretDiscoveries", "DimensionUnlocks", "Mastery"]
check(67, "DataService has v1.1 persistence fields with nil-safe defaults",
      all(f in data_svc for f in new_fields))
check(68, "docs/SHOT_LIST.md + docs/AUDIT_V1_1.md exist",
      (ROOT / "docs" / "SHOT_LIST.md").exists() and (ROOT / "docs" / "AUDIT_V1_1.md").exists())
check(69, "docs/QA_V11_A/B/C/D/E.md all exist",
      all((ROOT / "docs" / f"QA_V11_{s}.md").exists() for s in "ABCDE"))
check(70, "docs/REMOTES_NEEDED_A/B/C/D.md + REMOTES_WIRED_E.md exist",
      all((ROOT / "docs" / f"REMOTES_NEEDED_{s}.md").exists() for s in "ABCD")
      and (ROOT / "docs" / "REMOTES_WIRED_E.md").exists())

print(f"\n{len(passed)} passed, {len(failed)} failed (of {len(passed) + len(failed)})")
if failed:
    print(f"FAILED checks: {failed}")
sys.exit(1 if failed else 0)
