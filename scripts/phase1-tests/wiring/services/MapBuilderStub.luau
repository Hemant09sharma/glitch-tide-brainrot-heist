-- MapBuilderStub.luau — Lune-only stand-in for the server MapBuilder
-- module (src/server/Services/MapBuilder.luau), which BaseService
-- requires via `script.Parent`. The real MapBuilder builds plots from
-- the Roblox map; the stub builds the same SHAPE BaseService reads:
-- GetBasePlot(i) -> { Center: Vector3, Pedestals: { [slot]: CFrame },
-- Sign: nil }.
--
-- Geometry (mirrored by H.pedestalPosition in harness.luau — keep the
-- two in sync): plot i is centred at (i*100, 0, 0); pedestal slot s
-- sits at centre + (s*4, 0, 0). 10 pedestals per plot, so
-- effectiveSlots caps at 10 and the 12-stud PLACE_DISTANCE check has
-- a real near/far distinction: a thief standing at the victim's plot
-- is ~100 studs from their own pedestal.
-- NOT a copy of a src file: there is no src MapBuilder to diverge
-- from under Lune (the real one needs Workspace parts), so no
-- divergence check applies to this file.
--
-- Wiring-area addition: GetConveyorPath, the straight 60-stud belt
-- ConveyorService.Init reads (the store copy never needs it because
-- the store tests never Init ConveyorService; the wiring test drives
-- the real GameManager.Init, which does).
local MapBuilderStub = {}

local plots: { [number]: any } = {}

function MapBuilderStub.GetBasePlot(plotIndex: number): any
	local plot = plots[plotIndex]
	if plot ~= nil then
		return plot
	end
	local center = Vector3.new(plotIndex * 100, 0, 0)
	local pedestals: { [number]: any } = {}
	for slot = 1, 10 do
		pedestals[slot] = CFrame.new(center.X + slot * 4, 0, 0)
	end
	plot = {
		Center = center,
		Pedestals = pedestals,
		Sign = nil,
	}
	plots[plotIndex] = plot
	return plot
end

-- Straight 60-stud belt for ConveyorService.Init (GetConveyorPath is
-- the only MapBuilder call that runs at Init time; the belt-parts
-- movement loop lives in a task.spawn the harness discards).
function MapBuilderStub.GetConveyorPath(): { any }
	return { Vector3.new(0, 0, 0), Vector3.new(60, 0, 0) }
end

return MapBuilderStub
