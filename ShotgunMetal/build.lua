--[[
    ShotgunMetal / build.lua
    Build-option classification (per-builder cache), affordability checks and
    FindBuildSpot: obstacle grid, exit-corridor/flood-fill checks, tile search.
    Owns all build-probe caches.
    Depends on: config, state, utils.
]]

local VFS    = VFS
local Spring = Spring
local Game   = Game
local math   = math
local string = string
local table  = table

local mFloor = math.floor
local mMax   = math.max
local mMin   = math.min
local mHuge  = math.huge
local mAbs   = math.abs

local sLower = string.lower
local sFind  = string.find

local tInsert = table.insert
local tSort   = table.sort

local spGetUnitPosition       = Spring.GetUnitPosition
local spGetUnitDefID          = Spring.GetUnitDefID
local spGetUnitBuildFacing    = Spring.GetUnitBuildFacing
local spGetUnitsInCylinder    = Spring.GetUnitsInCylinder
local spGetFeaturesInCylinder = Spring.GetFeaturesInCylinder
local spGetFeaturePosition    = Spring.GetFeaturePosition
local spTestBuildOrder        = Spring.TestBuildOrder
local spGetGroundHeight       = Spring.GetGroundHeight
local spGetMyTeamID           = Spring.GetMyTeamID

return function(cfg, st, U, D)

local B = {}

--------------------------------------------------------------------------------
-- Build-probe caches
--------------------------------------------------------------------------------

-- Build spot checks are expensive
-- Cache them so computer doesn't explode
local buildCacheTTL      = 600
local buildTestCache     = {}
local buildExitCache     = {}
local buildTestCount     = {}
local buildExitCount     = 0
local buildCacheLastClear = -9999
local BUILD_CACHE_COALESCE = 15

local OBSTACLE_SCAN_CELL = 512
local OBSTACLE_SCAN_PAD  = 400
local obstacleScanCache  = {}

function B.ClearCaches()
    buildTestCache = {}
    buildExitCache = {}
    buildTestCount = {}
    buildExitCount = 0
    obstacleScanCache = {}
end

function B.OnWorldChange()
    local fr = st.frameNum or 0
    if fr - buildCacheLastClear >= BUILD_CACHE_COALESCE then
        B.ClearCaches()
        buildCacheLastClear = fr
    end
end

--------------------------------------------------------------------------------
-- Build-option sorting/picking helpers
--------------------------------------------------------------------------------

local function SortByMetalCostDesc(a, b)
    local cA = UnitDefs[a] and UnitDefs[a].metalCost or 0
    local cB = UnitDefs[b] and UnitDefs[b].metalCost or 0
    return cA > cB
end

local function SortFactoriesVehicleFirst(a, b)
    local aVeh = U.IsVehicleFactory(a) and 1 or 0
    local bVeh = U.IsVehicleFactory(b) and 1 or 0
    if aVeh ~= bVeh then return aVeh > bVeh end
    return SortByMetalCostDesc(a, b)
end

local function SortByMetalCostAsc(a, b)
    local cA = UnitDefs[a] and UnitDefs[a].metalCost or 0
    local cB = UnitDefs[b] and UnitDefs[b].metalCost or 0
    return cA < cB
end

-- pick a random affordable defense; list is sorted cheapest-first
function B.SelectBalancedDefense(list, currentMetal)
    if not list or #list == 0 then return nil end
    currentMetal = currentMetal or 0

    local affordable = {}
    for i = 1, #list do
        local defID = list[i]
        if UnitDefs[defID] and (UnitDefs[defID].metalCost or 0) <= currentMetal then
            affordable[#affordable + 1] = defID
        end
    end

    -- Nothing affordable: return the cheapest anyway.
    if #affordable == 0 then return list[1] end

    return affordable[math.random(#affordable)]
end

function B.PickPreferAir(list, isRandom)
    if not list or #list == 0 then return nil end
    local airOptions = {}
    for i = 1, #list do
        local d = UnitDefs[list[i]]
        if d and d.canFly and not (d.transportCapacity and d.transportCapacity > 0) then
            airOptions[#airOptions + 1] = list[i]
        end
    end
    if #airOptions > 0 then return isRandom and airOptions[math.random(#airOptions)] or airOptions[1] end

    local nonAirOptions = {}
    for i = 1, #list do
        local d = UnitDefs[list[i]]
        if d and not d.canFly then
            nonAirOptions[#nonAirOptions + 1] = list[i]
        end
    end
    if #nonAirOptions > 0 then return isRandom and nonAirOptions[math.random(#nonAirOptions)] or nonAirOptions[1] end

    return isRandom and list[math.random(#list)] or list[1]
end

--------------------------------------------------------------------------------
-- Per-builder build-options classification
--------------------------------------------------------------------------------

function B.GetBuildCache(uDefID)
    local cached = st.buildCache[uDefID]
    if cached then return cached end

    local c = { factories = {}, mex = {}, energyAdv = {}, energyWind = {}, energySolar = {}, cons = {}, mobile = {}, artillery = {}, defenses = {}, defensesGround = {}, defensesAA = {}, other = {}, conTurrets = {}, shields = {}, antinukes = {}, jammers = {}, radars = {}, radarTowers = {}, laz = {}, trappers = {}, scouts = {} }
    local opts = UnitDefs[uDefID] and UnitDefs[uDefID].buildOptions

    if opts then
        for i = 1, #opts do
            local bID = opts[i]
            local d = UnitDefs[bID]
            if d then
                local name = d.name and sLower(d.name) or ""
                local hName = U.GetHumanName(d)
                local isWaterUnit = (d.minWaterDepth and d.minWaterDepth > 0) or (d.needWater)

                if isWaterUnit or sFind(name, "torpedo") or sFind(name, "tidal") or sFind(name, "sonar") or sFind(name, "shipyard") or sFind(name, "subpen") then isWaterUnit = true end
                if not isWaterUnit and d.weapons then
                    for wi = 1, #d.weapons do
                        local wDef = d.weapons[wi].weaponDef and WeaponDefs[d.weapons[wi].weaponDef]
                        if wDef then
                            local wType = wDef.type and sLower(wDef.type) or ""
                            local wName = wDef.name and sLower(wDef.name) or ""
                            if sFind(wType, "torpedo") or sFind(wName, "torpedo") or sFind(wName, "depthcharge") then isWaterUnit = true break end
                        end
                    end
                end

                local isCloaked = d.canCloak or sFind(name, "cloak")
                local isTransport = (d.transportCapacity and d.transportCapacity > 0) or d.isTransport
                if not (isWaterUnit or isCloaked or isTransport) and not sFind(name, "juno") then
                    local isMobile = d.speed and d.speed > 0
                    local isMex = d.extractsMetal and d.extractsMetal > 0
                    local isWindGenDef = false
                    if d.windGenerator then
                        if type(d.windGenerator) == "number" and d.windGenerator > 0 then isWindGenDef = true
                        elseif type(d.windGenerator) == "boolean" and d.windGenerator == true then isWindGenDef = true end
                    end

                    local isEnergy = (not isMobile) and ((d.energyMake and d.energyMake > 0) or isWindGenDef or sFind(name, "win") or sFind(hName, "wind") or sFind(hName, "turbine") or sFind(name, "solar") or sFind(hName, "solar") or sFind(name, "fusion") or sFind(hName, "fusion") or sFind(name, "geo") or sFind(hName, "geo"))
                    local isConTurret = d.isBuilder and not isMobile and not (d.canResurrect)
                    -- DON'T MAKE CONVERTORS!!
                    local isConverter = (not isMobile) and (
                        (d.makesMetal and d.makesMetal > 0) or (d.metalMake and d.metalMake > 0)
                        or ((d.energyMake and d.energyMake > 0) and ((d.metalUse and d.metalUse > 0) or (d.metalUpkeep and d.metalUpkeep > 0)))
                    )
                    local isShield = false
                    if d.weapons then
                        for wi = 1, #d.weapons do
                            local wDef = U.SafeGetWeaponDef(d.weapons[wi].weaponDef)
                            if wDef and wDef.isShield then isShield = true break end
                        end
                    end
                    if not isShield then
                        isShield = sFind(name, "shield") or sFind(name, "aegis") or sFind(name, "aspis") or sFind(name, "corash") or sFind(name, "deflector") or sFind(name, "gate")
                    end
                    local isRadarTower = (d.radarDistance and d.radarDistance > 0) or (d.sonarDistance and d.sonarDistance > 0)

                    if U.IsAntiNukeDef(bID) and not (d.speed and d.speed > 0) then tInsert(c.antinukes, bID)
                    elseif isShield and not isMobile then tInsert(c.shields, bID)
                    elseif d.isFactory then tInsert(c.factories, bID)
                    elseif isMobile then
                        local isLaz = d.canResurrect or sFind(name, "lazarus") or sFind(name, "graverobber") or sFind(name, "zagreus")
                        local isTrapper = U.IsTrapper(d)

                        if isLaz then
                            tInsert(c.laz, bID)
                        elseif isTrapper then
                            tInsert(c.trappers, bID)
                        elseif d.isBuilder and d.buildOptions and #d.buildOptions > 0 then
                            if not U.IsAmphibiousCon(name, d) then
                                tInsert(c.cons, bID)
                            end
                        elseif U.IsArtillery(d) then
                            tInsert(c.artillery, bID)
                        else
                            local isJammer = (d.radarDistanceJam and d.radarDistanceJam > 0) or sFind(name, "jammer") or sFind(name, "jam")
                            local isRadar = (d.radarDistance and d.radarDistance > 0 and not d.weapons) or sFind(name, "radar")
                            local isScoutDef = U.IsScoutDef(d)
                            if isJammer then tInsert(c.jammers, bID)
                            elseif isRadar then tInsert(c.radars, bID)
                            elseif isScoutDef then tInsert(c.scouts, bID)
                            else tInsert(c.mobile, bID) end
                        end
                    elseif isMex then tInsert(c.mex, bID)
                    elseif isConverter then -- DON'T MAKE CONVERTORS!!
                    elseif isConTurret then tInsert(c.conTurrets, bID)
                    elseif isEnergy then
                        local isAdvEnergy = (d.metalCost and d.metalCost >= 1000) or sFind(name, "fusion") or sFind(hName, "fusion") or sFind(name, "afus")
                        local isWind = isWindGenDef or sFind(name, "win") or sFind(hName, "wind") or sFind(hName, "turbine")
                        local isSolar = sFind(name, "solar") or sFind(hName, "solar")
                        local isGeo = sFind(name, "geo") or sFind(hName, "geo")
                        if isAdvEnergy or isGeo then tInsert(c.energyAdv, bID)
                        elseif isWind then tInsert(c.energyWind, bID)
                        elseif isSolar then tInsert(c.energySolar, bID)
                        else tInsert(c.other, bID) end
                    elseif isRadarTower then tInsert(c.radarTowers, bID)
                    elseif U.IsDefenseDef(bID) then
                        tInsert(c.defenses, bID)
                        if U.IsAAOnlyDef(bID) then tInsert(c.defensesAA, bID)
                        else tInsert(c.defensesGround, bID) end
                    else tInsert(c.other, bID) end
                end
            end
        end
    end

    tSort(c.factories, SortFactoriesVehicleFirst)
    tSort(c.mex, SortByMetalCostDesc)
    tSort(c.energyAdv, SortByMetalCostDesc)
    tSort(c.energyWind, SortByMetalCostDesc)
    tSort(c.energySolar, SortByMetalCostDesc)
    tSort(c.shields, SortByMetalCostDesc)
    tSort(c.antinukes, SortByMetalCostDesc)
    tSort(c.defenses, SortByMetalCostAsc)
    tSort(c.defensesGround, SortByMetalCostAsc)
    tSort(c.defensesAA, SortByMetalCostAsc)
    tSort(c.cons, SortByMetalCostAsc)

    st.buildCache[uDefID] = c
    return c
end

--------------------------------------------------------------------------------
-- Factory/mobile-defense pickers over a build cache
--------------------------------------------------------------------------------

function B.GetCheapestVehicleFactory(cache)
    if not cache or not cache.factories then return nil end
    local cheapest, cheapestCost = nil, mHuge
    for i = #cache.factories, 1, -1 do
        local fID = cache.factories[i]
        if U.IsVehicleFactory(fID) then
            local cost = UnitDefs[fID] and UnitDefs[fID].metalCost or mHuge
            if cost < cheapestCost then cheapestCost = cost cheapest = fID end
        end
    end
    return cheapest
end

function B.GetCheapestMobileDefense(cache)
    if not cache or not cache.mobile then return nil end
    local cheapest, cheapestCost = nil, mHuge
    for i = 1, #cache.mobile do
        local d = UnitDefs[cache.mobile[i]]
        if d and d.weapons and #d.weapons > 0 then
            local cost = d.metalCost or mHuge
            if cost < cheapestCost then cheapestCost = cost cheapest = cache.mobile[i] end
        end
    end
    return cheapest
end

local function GetAdvancedVehicleFactory(cache)
    local factories = cache and cache.factories
    if not factories or #factories == 0 then
        return nil
    end

    local unitDefs = UnitDefs
    local isVehicleFactory = U.IsVehicleFactory

    local best, bestCost = nil, -1
    local count = #factories

    for i = 1, count do
        local fID = factories[i]
        if isVehicleFactory(fID) then
            local def = unitDefs[fID]
            local cost = def and def.metalCost or 0
            if cost > bestCost then
                bestCost = cost
                best = fID
            end
        end
    end

    return best
end

--------------------------------------------------------------------------------
-- Affordability checks / factory anchors
--------------------------------------------------------------------------------

function B.GetNearestFactoryPos(ux, uz)
    if st.myFactoriesCount == 0 then return ux, uz end
    local bestFx, bestFz, bestDist = ux, uz, mHuge
    for j = 1, st.myFactoriesCount do
        local fID = st.myFactories[j]
        local fx, _, fz = spGetUnitPosition(fID)
        if fx then
            local dx, dz = fx - ux, fz - uz
            local dist = dx * dx + dz * dz
            if dist < bestDist then bestDist, bestFx, bestFz = dist, fx, fz end
        end
    end
    return bestFx, bestFz
end

function B.CanAffordBuild(defID, isEssential)
    local d = UnitDefs[defID]
    if not d then return true end
    local cost = d.metalCost or 0
    if cost <= 0 then return true end
    local available = mMax(0, st.currentMetal - st.pendingCommittedMetal)
    if isEssential then
        if cost <= 160 then return true end
        return available >= cost * 0.5 or not st.metalStalling
    end
    -- judge non-essential builds against a short income window
    local incomeWindow = 12
    if st.metalStalling then
        return cost <= mMax(st.metalIncome * 2, 40) -- let small builds go in a brief stall
    end
    if cost <= available then return true end
    return cost <= mMax(st.metalIncome * incomeWindow, 60)
end

-- without this the bot won't build t3
function B.CanAffordCombatUnit(defID)
    local d = UnitDefs[defID]
    if not d then return true end
    local cost = d.metalCost or 0
    if cost <= 0 then return true end
    local available = mMax(0, st.currentMetal - st.pendingCommittedMetal)
    if st.metalStalling then
        -- keep heavy units flowing through brief stalls instead of idling labs
        return cost <= mMax(st.metalIncome * 8, 150)
    end
    if cost <= available then return true end
    local incomeWindow = cfg.INCOME_WINDOW_BASE + cost * cfg.INCOME_WINDOW_COST_RATIO
    return cost <= mMax(st.metalIncome * incomeWindow, 60)
end

-- Tech-up gate for expensive labs; tuned so T2 comes as early as the
-- economy can possibly feed it.
function B.CanTechUpToFactory(fID)
    local def = UnitDefs[fID]
    local cost = (def and def.metalCost) or 0

    local cheapestFactoryCost = D.economy.GetCheapestFactoryInfo().cost or 0
    if cost <= cheapestFactoryCost * cfg.ADV_FACTORY_TIER_RATIO then
        return true
    end

    local paybackSecs = cfg.ADV_FACTORY_PAYBACK_SECS or 1
    local requiredIncome = cost / paybackSecs

    if (st.metalIncome or 0) >= requiredIncome then
        return true
    end

    local currentMetal = st.currentMetal or 0
    local pendingMetal = st.pendingCommittedMetal or 0
    local availableMetal = mMax(0, currentMetal - pendingMetal)

    return availableMetal >= cost
end

--------------------------------------------------------------------------------
-- FindBuildSpot
--------------------------------------------------------------------------------

local STANDARD_FACINGS = { 0, 1, 2, 3 }

function B.FindBuildSpot(ux, uz, defID, spacingOverride, excludeUnitID, preferRadius, blockAnchorR2, preferFacing, radial, tight, radialAnchorHalf)
    local d = UnitDefs[defID]
    local isBuildingFactory = d and d.isFactory and not U.IsAirFactory(defID)
    -- con turrets are not a rez bot and not a factory.
    local isConTurret = d and d.isBuilder and (not d.speed or d.speed == 0) and not d.canResurrect and not d.isFactory

    local frame = st.frameNum or 0

    -- With a preferred facing (initial factory), try it first on every tile
    local facingOrder = STANDARD_FACINGS
    if preferFacing then
        facingOrder = { preferFacing, (preferFacing + 1) % 4, (preferFacing + 2) % 4, (preferFacing + 3) % 4 }
    end

    local xsize = d and d.xsize or 4
    local zsize = d and d.zsize or 4
    local actualSpacing = mMax(xsize, zsize) * 8 + 16
    if spacingOverride then actualSpacing = spacingOverride end

    local stepSize = mMax(16, mFloor(actualSpacing / 16) * 16)
    if stepSize < 32 then stepSize = 32 end

    local gridStartX = mFloor(ux / stepSize) * stepSize
    local gridStartZ = mFloor(uz / stepSize) * stepSize

    local mapMaxX = Game.mapSizeX or 8192
    local mapMaxZ = Game.mapSizeZ or 8192

    -- spatial hash grid
    local obsGrid = {}
    local cellSize = 256

    local function AddObstacle(x, z, r2)
        local cellX = mFloor(x / cellSize)
        local cellZ = mFloor(z / cellSize)
        local col = obsGrid[cellX]
        if not col then
            col = {}
            obsGrid[cellX] = col
        end
        local cell = col[cellZ]
        if not cell then
            cell = {}
            col[cellZ] = cell
        end
        -- Flat layout: x, z, r2
        local n = #cell
        cell[n + 1] = x
        cell[n + 2] = z
        cell[n + 3] = r2
    end

    -- no matter how big I make this exit corridor
    -- some con bots going to block it
    local function AddExitCorridor(cx, cz, dirX, dirZ, halfWidth)
        local px, pz = -dirZ, dirX
        local start = mMax(32, halfWidth or 32)
        for dist = start, 960, 60 do
            for lat = -40, 40, 40 do
                AddObstacle(cx + dirX * dist + px * lat, cz + dirZ * dist + pz * lat, 40 * 40)
            end
        end
    end

    local function IsBlocked(x, z)
        local cellX = mFloor(x / cellSize)
        local cellZ = mFloor(z / cellSize)
        for cx = -1, 1 do
            local col = obsGrid[cellX + cx]
            if col then
                for cz = -1, 1 do
                    local cell = col[cellZ + cz]
                    if cell then
                        local n = #cell
                        local i = 1
                        while i <= n do
                            local ox = cell[i]
                            local oz = cell[i + 1]
                            local or2 = cell[i + 2]
                            local ddx = x - ox
                            local ddz = z - oz
                            if (ddx * ddx + ddz * ddz) < or2 then
                                return true
                            end
                            i = i + 3
                        end
                    end
                end
            end
        end
        return false
    end

    local function BlockedForUnit(x, z, halfW)
        local cellX = mFloor(x / cellSize)
        local cellZ = mFloor(z / cellSize)
        local hw = halfW or 0
        for cx = -1, 1 do
            local col = obsGrid[cellX + cx]
            if col then
                for cz = -1, 1 do
                    local cell = col[cellZ + cz]
                    if cell then
                        local n = #cell
                        local i = 1
                        while i <= n do
                            local ox = cell[i]
                            local oz = cell[i + 1]
                            local r = math.sqrt(cell[i + 2]) + hw
                            local ddx = x - ox
                            local ddz = z - oz
                            if (ddx * ddx + ddz * ddz) < r * r then return true end
                            i = i + 3
                        end
                    end
                end
            end
        end
        return false
    end

    -- detect open ground
    local function ObstacleNear(x, z, radius)
        local cellX = mFloor(x / cellSize)
        local cellZ = mFloor(z / cellSize)
        local span = math.ceil(radius / cellSize)
        local r2 = radius * radius
        for cx = cellX - span, cellX + span do
            local col = obsGrid[cx]
            if col then
                for cz = cellZ - span, cellZ + span do
                    local cell = col[cz]
                    if cell then
                        local n = #cell
                        local i = 1
                        while i <= n do
                            local ox = cell[i]
                            local oz = cell[i + 1]
                            local ddx = x - ox
                            local ddz = z - oz
                            if (ddx * ddx + ddz * ddz) < r2 then return true end
                            i = i + 3
                        end
                    end
                end
            end
        end
        return false
    end

    -- straight-line exit check for factories
    local function IsExitCorridorClear(cx, cz, dirX, dirZ, halfWidth)
        local px, pz = -dirZ, dirX
        local halfW = mMax(48, halfWidth or 32)
        local start = mMax(32, halfWidth or 32)
        for dist = start, 480, 40 do
            local bx = cx + dirX * dist
            local bz = cz + dirZ * dist
            if IsBlocked(bx, bz) then return false end
            for lat = 32, halfW, 32 do
                if IsBlocked(bx + px * lat, bz + pz * lat) then return false end
                if IsBlocked(bx - px * lat, bz - pz * lat) then return false end
            end
        end
        return true
    end

    -- Flood fill from a start point till we reach somewhere open.
    -- TODO: optimizations here are always nice, especially with more cons
    -- Also TODO: This algorithm still needs improvements, it's not perfect, like t3 units getting trapped.
    local function HasExitPath(ex, ez, opts)
        local step = opts.step or 96
        local maxRadius = cfg.BUILD_RADIUS
        local clearR = 360
        local maxDist2 = maxRadius * maxRadius
        local escDist2 = opts.escapeDist and (opts.escapeDist * opts.escapeDist) or nil
        local wallX, wallZ = opts.wallX, opts.wallZ
        local halfW = opts.halfW or 16
        local wallEffR2 = nil
        if opts.wallR2 then
            local wr = math.sqrt(opts.wallR2) + halfW
            wallEffR2 = wr * wr
        end
        -- stay on the map, this caused issues when a factory faced one of the map walls
        -- and the flood fill thought that it was open ground
        local mapMaxX = (Game.mapSizeX or 8192) - 80
        local mapMaxZ = (Game.mapSizeZ or 8192) - 80
        -- offset so the lattice never aligns with build grids (reads dense fields as sealed)
        local lx, lz = ex, ez
        if opts.originOffset then lx, lz = ex + opts.originOffset, ez + opts.originOffset end

        -- Cache floods by start + params
        local frame = st.frameNum or 0
        local bk = step .. "_" .. (opts.escapeDist or 0) .. "_" .. (opts.originOffset or 0) .. "_" .. halfW .. "_" .. (opts.wallR2 or 0) .. "_" .. (opts.anchorR2 or 0) .. "_" .. (opts.excl or 0)
        local exitMap = buildExitCache[bk]
        if not exitMap then exitMap = {} buildExitCache[bk] = exitMap end
        local lx0 = mFloor(lx / step)
        local lz0 = mFloor(lz / step)
        local wlx0 = (wallX and mFloor(wallX / step)) or 0
        local wlz0 = (wallZ and mFloor(wallZ / step)) or 0
        local ckey = (lx0 * 8192 + lz0) * 8388608 + wlx0 * 8192 + wlz0
        local ce = exitMap[ckey]
        if ce and frame - ce.f <= buildCacheTTL then return ce.r, ce.d end

        -- Start off-map: nothing to march out to.
        if lx < 80 or lz < 80 or lx > mapMaxX or lz > mapMaxZ then return false, 0 end

        local openX = { lx }
        local openZ = { lz }
        local openD = { 0 }
        local seen = {}
        seen[lx0 * 4096 + lz0] = true
        local k = 1
        local len = 1
        local res = false
        local resDepth = 0
        while k <= len do
            local cx, cz, cd = openX[k], openZ[k], openD[k]
            k = k + 1
            local clear = false
            if cx >= 80 and cz >= 80 and cx <= mapMaxX and cz <= mapMaxZ then
                clear = not ObstacleNear(cx, cz, clearR)
                if clear and wallX then
                    local wx = cx - wallX
                    local wz = cz - wallZ
                    if wx * wx + wz * wz < clearR * clearR then clear = false end
                end
            end
            if clear then res = true resDepth = cd break end
            local dx0, dz0 = cx - lx, cz - lz
            if escDist2 and dx0 * dx0 + dz0 * dz0 > escDist2 then res = true resDepth = cd break end
            if dx0 * dx0 + dz0 * dz0 <= maxDist2 then
                for dxi = -1, 1 do
                    for dzi = -1, 1 do
                        if dxi ~= 0 or dzi ~= 0 then
                            local nx = cx + dxi * step
                            local nz = cz + dzi * step
                            if nx >= 80 and nz >= 80 and nx <= mapMaxX and nz <= mapMaxZ then
                                local nkey = mFloor(nx / step) * 4096 + mFloor(nz / step)
                                if not seen[nkey] then
                                    seen[nkey] = true
                                    local blocked = false
                                    -- No corner-cutting: a diagonal step needs both
                                    -- adjacent cardinal cells free.
                                    if dxi ~= 0 and dzi ~= 0 then
                                        blocked = BlockedForUnit(cx + dxi * step, cz, halfW) or BlockedForUnit(cx, cz + dzi * step, halfW)
                                    end
                                    if not blocked then
                                        blocked = BlockedForUnit(nx, nz, halfW)
                                    end
                                    if not blocked and wallEffR2 then
                                        local wx = nx - wallX
                                        local wz = nz - wallZ
                                        if wx * wx + wz * wz < wallEffR2 then blocked = true end
                                    end
                                    if not blocked then
                                        len = len + 1
                                        openX[len] = nx
                                        openZ[len] = nz
                                        openD[len] = cd + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        exitMap[ckey] = { r = res, d = resDepth, f = frame }
        buildExitCount = buildExitCount + 1
        if buildExitCount > 80000 then
            buildExitCache = {}
            buildExitCount = 0
        end
        return res, resDepth
    end

    -- the obstacle scan is filtered to our team (enemies are caught by spTestBuildOrder)
    local myTeamID = spGetMyTeamID()
    local oCellX = mFloor(ux / OBSTACLE_SCAN_CELL)
    local oCellZ = mFloor(uz / OBSTACLE_SCAN_CELL)
    local oKey = oCellX * 8192 + oCellZ
    local oce = obstacleScanCache[oKey]
    if not oce or (frame - oce.f) > buildCacheTTL then
        local scX = (oCellX + 0.5) * OBSTACLE_SCAN_CELL
        local scZ = (oCellZ + 0.5) * OBSTACLE_SCAN_CELL
        local scanR = cfg.BUILD_RADIUS + OBSTACLE_SCAN_PAD
        oce = { f = frame, units = spGetUnitsInCylinder(scX, scZ, scanR, myTeamID), feats = spGetFeaturesInCylinder(scX, scZ, scanR) }
        obstacleScanCache[oKey] = oce
    end
    local nearbyUnits = oce.units
    if nearbyUnits then
        for i = 1, #nearbyUnits do
            local nID = nearbyUnits[i]
            local nx, _, nz = spGetUnitPosition(nID)
            local ndID = spGetUnitDefID(nID)
            local nd = ndID and UnitDefs[ndID]
            if nx and nz and nd then
                local obsRadius = 0
                if nd.isFactory then
                    if U.IsAirFactory(ndID) then obsRadius = 120
                    else
                        -- con turrets hug the lab, eco has to stay away
                        if isConTurret then
                            obsRadius = (mMax(nd.xsize or 8, nd.zsize or 8) * 8) / 2 + 8
                        else
                            obsRadius = select(2, U.FactoryTurretInfo(ndID))
                        end
                        local unitFacing = spGetUnitBuildFacing(nID) or 0
                        local dirX, dirZ = U.GetFacingVector(unitFacing)
                        AddExitCorridor(nx, nz, dirX, dirZ, (mMax(nd.xsize or 8, nd.zsize or 8) * 8) / 2)
                    end
                elseif nd.isBuilding then
                    obsRadius = (nd.xsize and nd.xsize * 8 or 16) + 8
                end
                if excludeUnitID and nID == excludeUnitID then obsRadius = 0 end
                if obsRadius > 0 then AddObstacle(nx, nz, obsRadius * obsRadius) end
            end
        end
    end

    local nearbyFeatures = oce.feats
    if nearbyFeatures then
        for i = 1, #nearbyFeatures do
            local fID = nearbyFeatures[i]
            local fx, _, fz = spGetFeaturePosition(fID)
            if fx and fz then AddObstacle(fx, fz, 32 * 32) end
        end
    end

    for _, claim in pairs(st.claimedSpots) do
        local cr2 = claim.r2
        -- con turrets can (and should) sit inside a lab's keep-out
        -- eco needs to stay away
        if claim.isFactory and not claim.isAirFactory and isConTurret then
            local cDef = claim.defID and UnitDefs[claim.defID]
            local cR = (mMax(cDef and cDef.xsize or 8, cDef and cDef.zsize or 8) * 8) / 2 + 8
            cr2 = cR * cR
        end
        AddObstacle(claim.x, claim.z, cr2)
        if claim.isFactory and not claim.isAirFactory then
            local dirX, dirZ = U.GetFacingVector(claim.facing or 0)
            local cDef = claim.defID and UnitDefs[claim.defID]
            AddExitCorridor(claim.x, claim.z, dirX, dirZ, (mMax(cDef and cDef.xsize or 8, cDef and cDef.zsize or 8) * 8) / 2)
        end
    end

    -- Re-add the anchor (commander/con) as a real obstacle: TestBuildOrder never
    -- checks unit collisions, so without this the new build could land on the
    -- builder itself.
    if blockAnchorR2 and blockAnchorR2 > 0 then
        AddObstacle(ux, uz, blockAnchorR2)
    end

    -- half-footprint of the excluded builder
    local exclR = nil
    if excludeUnitID then
        local eID = spGetUnitDefID(excludeUnitID)
        local eDef = eID and UnitDefs[eID]
        if eDef then exclR = (mMax(eDef.xsize or 1, eDef.zsize or 1) * 8) / 2 end
    end

    local maxRing = mFloor(cfg.BUILD_RADIUS / stepSize)

    -- We should prefer spots within the builder's own build distance; and only fall back
    -- to the full search radius only if nothing is buildable nearby.
    local preferRing = preferRadius and mFloor(preferRadius / stepSize) or maxRing
    if preferRing < 0 then preferRing = 0 elseif preferRing > maxRing then preferRing = maxRing end

    -- Once we know where an enemy base is, grow the base
    -- away from the enemy
    local fdx, fdz = nil, nil
    local isMex = d.extractsMetal and d.extractsMetal > 0
    local isMine = sFind(sLower(d.name or ""), "mine") ~= nil
    if not isMex and not isMine and st.enemyBases and next(st.enemyBases) ~= nil then
        local refX, refZ = st.baseCenterX or ux, st.baseCenterZ or uz
        local bestD = mHuge
        for _, b in pairs(st.enemyBases) do
            if b.lastSeen then
                local bdx, bdz = b.x - refX, b.z - refZ
                local bd = bdx * bdx + bdz * bdz
                if bd < bestD then bestD, fdx, fdz = bd, bdx, bdz end
            end
        end
        if fdx then
            local fl = math.sqrt(fdx * fdx + fdz * fdz)
            if fl > 1 then fdx, fdz = fdx / fl, fdz / fl end
        end
    end

    -- radial placement diagnostics: TryTile records why it rejects each tile
    local diagReject = nil
    local diagActive = false

    local function TryTile(gx, gz)
        if diagActive then diagReject = nil end
        if gx < 0 or gz < 0 or gx >= mapMaxX or gz >= mapMaxZ then if diagActive then diagReject = "bounds" end return nil end
        local tx = mFloor(gx / 16 + 0.5) * 16
        local tz = mFloor(gz / 16 + 0.5) * 16
        if IsBlocked(tx, tz) then if diagActive then diagReject = "blocked" end return nil end
        -- Never build into void/lava
        if U.IsInaccessible(tx, tz) then if diagActive then diagReject = "inacc" end return nil end
        -- Never overlap the builder itself (it's excluded from the obstacle
        -- grid above, so this is the only guard).
        if exclR then
            local ex, _, ez = spGetUnitPosition(excludeUnitID)
            if ex then
                local req = (mMax(xsize, zsize) * 8) / 2 + exclR + 12
                local adx, adz = tx - ex, tz - ez
                if adx * adx + adz * adz < req * req then if diagActive then diagReject = "overlap" end return nil end
            end
        end
        -- cached spTestBuildOrder + ground height
        local tkey = (tx * 1048576 + tz) * 4
        local tbc = buildTestCache[defID]
        local ty = nil
        if diagActive then diagReject = "test" end
        for fi = 1, 4 do
            local f = facingOrder[fi]
            local te
            if tbc then te = tbc[tkey + f] end
            local ok
            if te and (frame - te.f) <= buildCacheTTL then
                ok = te.r
                if not ty then ty = te.y end
            else
                if not ty then ty = spGetGroundHeight(tx, tz) end
                ok = spTestBuildOrder(defID, tx, ty, tz, f) ~= 0
                if not tbc then tbc = {} buildTestCache[defID] = tbc end
                local cnt = (buildTestCount[defID] or 0) + 1
                if cnt > 32768 then
                    tbc = {} buildTestCache[defID] = tbc
                    buildTestCount[defID] = 0
                else
                    buildTestCount[defID] = cnt
                end
                tbc[tkey + f] = { r = ok, y = ty, f = frame }
            end
            if ok then
                local facClear = true
                if isBuildingFactory then
                    local dirX, dirZ = U.GetFacingVector(f)
                    local facHalf = (mMax(xsize, zsize) * 8) / 2
                    -- Is the exit corridor directly clear and theres a real walking path out?
                    if not IsExitCorridorClear(tx, tz, dirX, dirZ, facHalf) then
                        facClear = false
                        if diagActive then diagReject = "exit" end
                    end
                    if facClear and not HasExitPath(tx + dirX * (facHalf + 40), tz + dirZ * (facHalf + 40), { step = 64, halfW = 24, anchorR2 = blockAnchorR2, excl = excludeUnitID }) then
                        facClear = false
                        if diagActive then diagReject = "exit" end
                    end
                else
                    -- the builder shouldn't wall itself in
                    if not isConTurret and ObstacleNear(ux, uz, 400) then
                        local wallR = (mMax(xsize, zsize) * 8) / 2 + 8
                        if not HasExitPath(ux, uz, { step = 64, originOffset = 32, escapeDist = 800, wallX = tx, wallZ = tz, wallR2 = wallR * wallR, anchorR2 = blockAnchorR2, excl = excludeUnitID }) then
                            facClear = false
                            if diagActive then diagReject = "exit" end
                        end
                    end
                end

                if facClear then
                    return tx, ty, tz, f, mFloor(tx) .. "_" .. mFloor(tz)
                end
            end
        end
        return nil
    end

    if radial then
        local rOut = preferRadius or cfg.BUILD_RADIUS
        local rMin = mMax(stepSize, mFloor(((radialAnchorHalf or 0) + (mMax(xsize, zsize) * 8) / 2 + 8) / stepSize + 1) * stepSize)
        if st.turretDbg then
            diagActive = true
            local tDef = UnitDefs[defID]
            st.turretDbg.lastDef = (tDef and tDef.name) or defID
            st.turretDbg.lastSpacing = stepSize
            st.turretDbg.lastRingOut = rOut
        end
        for r = rMin, rOut, stepSize do
            local n = mMax(6, mFloor((2 * math.pi * r) / stepSize))
            for s = 0, n - 1 do
                local ang = (s / n) * (2 * math.pi)
                local rx, ry, rz, rf, rk = TryTile(ux + math.cos(ang) * r, uz + math.sin(ang) * r)
                if rx then
                    diagActive = false
                    return rx, ry, rz, rf, rk
                end
                if diagActive then
                    st.turretDbg.probeTiles = st.turretDbg.probeTiles + 1
                    if diagReject == "blocked" then st.turretDbg.probeBlocked = st.turretDbg.probeBlocked + 1
                    elseif diagReject == "inacc" then st.turretDbg.probeInacc = st.turretDbg.probeInacc + 1
                    elseif diagReject == "overlap" then st.turretDbg.probeOverlap = st.turretDbg.probeOverlap + 1
                    elseif diagReject == "exit" then st.turretDbg.probeExit = st.turretDbg.probeExit + 1
                    elseif diagReject == "bounds" then st.turretDbg.probeBounds = st.turretDbg.probeBounds + 1
                    else st.turretDbg.probeTest = st.turretDbg.probeTest + 1 end
                end
            end
        end
        diagActive = false
        return nil
    end

    if preferFacing then
        local dirX, dirZ = U.GetFacingVector(preferFacing)
        local tx, ty, tz, f, key = TryTile(ux + dirX * stepSize, uz + dirZ * stepSize)
        if tx then return tx, ty, tz, f, key end
    end

    local ax, az = 1, 0
    if fdx then
        if mAbs(fdx) >= mAbs(fdz) then ax, az = (fdx >= 0 and 1 or -1), 0
        else ax, az = 0, (fdz >= 0 and 1 or -1) end
    end
    local px, pz = -az, ax

    local bestTX, bestTY, bestTZ, bestF, bestKey = nil, nil, nil, nil, nil
    local bestScore = -mHuge

    local function consider(gx, gz, withinPrefer)
        local tx, ty, tz, f, key = TryTile(gx, gz)
        if tx then
            if not fdx or not withinPrefer then return tx, ty, tz, f, key end
            -- cover depth minus how far toward the enemy it sits, with a mild
            -- distance penalty so the builder still prefers close
            local ok, cover = HasExitPath(tx, tz, {})
            if not ok then cover = maxRing end
            local proj = (tx - ux) * fdx + (tz - uz) * fdz
            local dist = math.sqrt((tx - ux) * (tx - ux) + (tz - uz) * (tz - uz))
            local score = cover * 96 - proj - dist * 0.5
            if score > bestScore then
                bestScore = score
                bestTX, bestTY, bestTZ, bestF, bestKey = tx, ty, tz, f, key
            end
        end
        return nil
    end

    for lat = 0, preferRing do
        local latOff = lat
        for s = 1, (lat == 0 and 1 or 2) do
            if s == 2 then latOff = -lat end
            for along = 0, preferRing do
                local gx = gridStartX + (ax * along + px * latOff) * stepSize
                local gz = gridStartZ + (az * along + pz * latOff) * stepSize
                local r1, r2, r3, r4, r5 = consider(gx, gz, true)
                if r1 then return r1, r2, r3, r4, r5 end
            end
        end
    end
    if bestTX then return bestTX, bestTY, bestTZ, bestF, bestKey end

    -- Tight mode (eco/mex): only build close in; never send the builder
    -- sprinting to the far edge of the search ring.
    if tight then return nil end

    -- Phase 2: nothing buildable within the prefer square - extend outward.
    for lat = 0, maxRing do
        local latOff = lat
        for s = 1, (lat == 0 and 1 or 2) do
            if s == 2 then latOff = -lat end
            local alongStart = (lat <= preferRing) and (preferRing + 1) or 0
            for along = alongStart, maxRing do
                local gx = gridStartX + (ax * along + px * latOff) * stepSize
                local gz = gridStartZ + (az * along + pz * latOff) * stepSize
                local r1, r2, r3, r4, r5 = consider(gx, gz, false)
                if r1 then return r1, r2, r3, r4, r5 end
            end
        end
    end
    return nil
end

return B

end