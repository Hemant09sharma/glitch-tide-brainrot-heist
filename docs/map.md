# Glitch Tide — Brainrot Heist: The Memeverse — map folder
#
# The arena map is NOT stored as static parts in this folder.
# It is built at runtime by the server-side MapBuilder module, which
# constructs the lobby, arena floor, walls, spawn pads and decorations
# entirely from code (no external asset IDs). Keeping the map in code
# means Rojo syncs stay small and the map is identical on every server.
#
# This folder exists only so the Rojo project tree has a valid
# Workspace mapping (default.project.json maps Workspace -> src/map).
# Do not place .rbxl / .rbxm files here.
#
# PACKAGING NOTE (v1.0.2): this file lives in docs/, NOT in src/map/,
# so it is excluded from the Roblox instance tree — Rojo never sees
# it. src/map/ contains only an empty .gitkeep so the directory
# survives unzipping; the built Workspace is intentionally empty and
# MapBuilder constructs the whole arena at runtime.
