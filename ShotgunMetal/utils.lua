--[[
    ShotgunMetal / utils.lua
    Stateless helpers: unit-def classification (with per-def caches),
    geometry/spread math and terrain safety (lava/void).
    Factory: receives config.
]]

local Spring = Spring
local Game  = Game
local math  = math
local table = table
local string = string

local mFloor = math.floor
local mCeil  = math.ceil
local mCos   = math.cos
local mSin   = math.sin
local mMax   = math.max
local mMin   = math.min
local mHuge  = math.huge
local mAtan2 = math.atan2
local mRad   = math.rad

local sLower = string.lower
local sFind  = string.find

local spGetUnitFlanking = Spring.GetUnitFlanking
local spGetGroundHeight = Spring.GetGroundHeight

return function(cfg)

local M = {}

--------------------------------------------------------------------------------
-- Names/descriptions
--------------------------------------------------------------------------------

function M.GetHumanName(d)
    local n = d and (d.translatedHumanName or d.humanName)
    return n and sLower(n) or ""
end

function M.GetDescription(d)
    local t = d and (d.translatedTooltip or d.description)
    return t and sLower(t) or ""
end

function M.SafeGetWeaponDef(weaponDefIdx)
    if not weaponDefIdx then return nil end
    local ok, wd = pcall(function() return WeaponDefs[weaponDefIdx] end)
    return ok and wd or nil
end

--------------------------------------------------------------------------------
-- Deterministic pseudo-randomness for spread positions
--------------------------------------------------------------------------------

function M.UnitHash(unitID, salt)
    local h = (unitID * 2654435761 + salt * 40503) % 2147483647
    h = (h * 48271) % 2147483647
    return (h % 100000) / 100000
end

--------------------------------------------------------------------------------
-- Terrain: lava/void water/deep ground danger
--------------------------------------------------------------------------------

-- Cache lava level, for the most lava level is unimportant, but some metal maps *can*
-- have lava on them, and so we want to be accomadating
-- nil on non-lava maps; values < -9000 mean "not initialised yet".
local lavaLevelCache = nil
local lavaCheckFrame = -999999
local function GetLavaLevel()
    local gf = Spring.GetGameFrame()
    if gf - lavaCheckFrame < 30 then return lavaLevelCache end
    lavaCheckFrame = gf
    local lv = Spring.GetGameRulesParam("lavaLevel")
    if lv == nil or lv < -9000 then
        lavaLevelCache = nil
    else
        lavaLevelCache = lv
    end
    return lavaLevelCache
end

-- Unit's take damage below this level
local dangerLevelCache = nil
local dangerCheckFrame = -999999
local voidWaterMap = nil
local function IsVoidWaterMap()
    if voidWaterMap ~= nil then return voidWaterMap end
    voidWaterMap = false
    local ok, mapinfo = pcall(function()
        if VFS and VFS.Include then return VFS.Include("mapinfo.lua") end
    end)
    if ok and type(mapinfo) == "table" then
        local vw = mapinfo.voidwater
        if vw == nil then vw = mapinfo.voidWater end
        if vw and vw ~= false then voidWaterMap = true return true end
    end
    local ok2, vw2 = pcall(function() return gl and gl.GetMapRendering and gl.GetMapRendering("voidWater") end)
    if ok2 and vw2 then voidWaterMap = true return true end
    return false
end

local function GetDangerLevel()
    local gf = Spring.GetGameFrame()
    if gf - dangerCheckFrame < 60 then return dangerLevelCache end
    dangerCheckFrame = gf
    local lava = GetLavaLevel()
    if lava then dangerLevelCache = lava return dangerLevelCache end
    if IsVoidWaterMap() then dangerLevelCache = 0 return dangerLevelCache end
    local _, _, currMin = Spring.GetGroundExtremes()
    if currMin and currMin < -100 then
        dangerLevelCache = currMin + 50
        return dangerLevelCache
    end
    dangerLevelCache = nil
    return dangerLevelCache
end

local VOID_CELL = 128
local voidGrid = {}
local voidCols = 0
local voidRows = 0
local voidScanX = 0
local voidScanZ = 0
local voidScanInit = false

function M.StepVoidScan()
    if Spring.GetGameFrame() < 2 then return end
    if not voidScanInit then
        local mapX = Game.mapSizeX or 8192
        local mapZ = Game.mapSizeZ or 8192
        voidCols = mCeil(mapX / VOID_CELL)
        voidRows = mCeil(mapZ / VOID_CELL)
        voidScanInit = true
    end
    local danger = GetDangerLevel()
    if not danger then return end
    local minSafe = danger + cfg.LAVA_MARGIN
    for _ = 1, 24 do
        local col = voidGrid[voidScanX]
        if not col then col = {} voidGrid[voidScanX] = col end
        col[voidScanZ] = spGetGroundHeight((voidScanX + 0.5) * VOID_CELL, (voidScanZ + 0.5) * VOID_CELL) < minSafe
        voidScanZ = voidScanZ + 1
        if voidScanZ >= voidRows then
            voidScanZ = 0
            voidScanX = voidScanX + 1
            if voidScanX >= voidCols then voidScanX = 0 end
        end
    end
end

function M.IsInaccessible(x, z)
    local danger = GetDangerLevel()
    if not danger then return false end
    local cx = mFloor(x / VOID_CELL)
    local cz = mFloor(z / VOID_CELL)
    local col = voidGrid[cx]
    local v = col and col[cz]
    if v == nil then
        v = spGetGroundHeight(x, z) < danger + cfg.LAVA_MARGIN
        if not col then col = {} voidGrid[cx] = col end
        col[cz] = v
    end
    return v
end

function M.NudgeOutOfLava(x, z, towardX, towardZ)
    if not M.IsInaccessible(x, z) then return x, z end
    local dx, dz = towardX - x, towardZ - z
    local len = math.sqrt(dx*dx + dz*dz)
    if len < 1 then return x, z end
    dx, dz = dx / len, dz / len
    for i = 1, 16 do
        x = x + dx * 32
        z = z + dz * 32
        if not M.IsInaccessible(x, z) then return x, z end
    end
    return x, z
end

--------------------------------------------------------------------------------
-- Spread/retreat geometry
--------------------------------------------------------------------------------

--  do an offset as we don't want units to stack!
function M.GetSpreadPos(unitID, tx, tz, minR, maxR)
    local a = (unitID * 137.50776405 % 360) * (math.pi / 180)
    local rr = math.sqrt(M.UnitHash(unitID, 2)) * (maxR - minR) + minR
    local sx = tx + mCos(a) * rr
    local sz = tz + mSin(a) * rr
    local mapX = Game.mapSizeX or 8192
    local mapZ = Game.mapSizeZ or 8192
    local minX, maxX = 50, mapX - 50
    local minZ, maxZ = 50, mapZ - 50
    if sx < minX then sx = minX + (minX - sx) elseif sx > maxX then sx = maxX - (sx - maxX) end
    if sz < minZ then sz = minZ + (minZ - sz) elseif sz > maxZ then sz = maxZ - (sz - maxZ) end
    -- a target right on the border can still mirror outside, so clamp it as a fallback
    if sx < minX then sx = minX elseif sx > maxX then sx = maxX end
    if sz < minZ then sz = minZ elseif sz > maxZ then sz = maxZ end
    return sx, sz
end

-- Fairly niche mechanic
-- Flanking bonus: attacking from front and rear at once boosts damage, so
-- spread attackers to opposite sides
-- This probably also has the benefit of being harder to attack all of the units at the same time
function M.GetFlankSpreadPos(unitID, tx, tz, minR, maxR, targetID)
    local rr = math.sqrt(M.UnitHash(unitID, 2)) * (maxR - minR) + minR
    local a
    local rearX, rearZ = nil, nil
    if targetID and spGetUnitFlanking then
        local _, _, _, _, fx, _, fz = spGetUnitFlanking(targetID)
        if fx ~= nil and (fx ~= 0 or fz ~= 0) then rearX, rearZ = -fx, -fz end
    end
    if rearX ~= nil then
        local rearAngle = mAtan2(rearZ, rearX)
        a = rearAngle + (M.UnitHash(unitID, 5) - 0.5) * 2 * 1.2
    else
        a = (unitID * 137.50776405 % 360) * (math.pi / 180)
    end
    local sx = tx + mCos(a) * rr
    local sz = tz + mSin(a) * rr
    local mapX = Game.mapSizeX or 8192
    local mapZ = Game.mapSizeZ or 8192
    local minX, maxX = 50, mapX - 50
    local minZ, maxZ = 50, mapZ - 50
    if sx < minX then sx = minX + (minX - sx) elseif sx > maxX then sx = maxX - (sx - maxX) end
    if sz < minZ then sz = minZ + (minZ - sz) elseif sz > maxZ then sz = maxZ - (sz - maxZ) end
    if sx < minX then sx = minX elseif sx > maxX then sx = maxX end
    if sz < minZ then sz = minZ elseif sz > maxZ then sz = maxZ end
    return sx, sz
end

local function GetUnitForward(unitID)
    local heading = Spring.GetUnitHeading(unitID)
    if not heading then return 0, 1 end      -- fallback: facing +Z
    local theta = (heading / 65536) * 2 * math.pi
    return mSin(theta), mCos(theta)
end

-- Keep the last retreat direction per unit, so that retreats don't zigzag.
local retreatDirCache = {}

local TANGENTIAL_ANGLES = {
    { mCos(mRad( 45)), mSin(mRad( 45)) },
    { mCos(mRad( 60)), mSin(mRad( 60)) },
    { mCos(mRad( 75)), mSin(mRad( 75)) },
    { mCos(mRad( 90)), mSin(mRad( 90)) },
    { mCos(mRad(-45)), mSin(mRad(-45)) },
    { mCos(mRad(-60)), mSin(mRad(-60)) },
    { mCos(mRad(-75)), mSin(mRad(-75)) },
    { mCos(mRad(-90)), mSin(mRad(-90)) },
}
local TANGENTIAL_ANGLE_COUNT = #TANGENTIAL_ANGLES

function M.GetTangentialRetreat(unitID, ux, uz, threatX, threatZ, dist)
    local awayX, awayZ = ux - threatX, uz - threatZ
    local awayLenSq = awayX * awayX + awayZ * awayZ
    if awayLenSq < 0.01 then
        -- Threat on top of us: pick an arbitrary away direction.
        -- TODO: make this *not* arbitrary
        awayX, awayZ, awayLenSq = 1.0, 0.0, 1.0
    end
    local awayLen = math.sqrt(awayLenSq)
    local invLen = 1.0 / awayLen
    local awayNX, awayNZ = awayX * invLen, awayZ * invLen

    -- Map edge clamp bound
    local mapX  = Game.mapSizeX or 8192
    local mapZ  = Game.mapSizeZ or 8192
    local maxX  = mapX - 50
    local maxZ  = mapZ - 50
    local minX  = 50
    local minZ  = 50

    -- Forward current-unit vector from heading (fallback to facing +Z if null).
    local fwdX, fwdZ = GetUnitForward(unitID)
    local fwdLenSq = fwdX * fwdX + fwdZ * fwdZ
    if fwdLenSq < 0.01 then
        fwdX, fwdZ = 0.0, 1.0
    elseif fwdLenSq > 1.0001 then
        local fl = math.sqrt(fwdLenSq)
        fwdX = fwdX / fl
        fwdZ = fwdZ / fl
    end

    -- If we are already well-aligned with the away direction (~17 deg), just retreat directly.
    local dotAlign = fwdX * awayNX + fwdZ * awayNZ
    if dotAlign > 0.3 then
        retreatDirCache[unitID] = nil
        local tx = ux + awayNX * dist
        local tz = uz + awayNZ * dist
        if tx < minX then tx = minX elseif tx > maxX then tx = maxX end
        if tz < minZ then tz = minZ elseif tz > maxZ then tz = maxZ end
        tx, tz = M.NudgeOutOfLava(tx, tz, ux, uz)
        return tx, tz
    end

    -- Try each precomputed tangential angle, keep the one that best escapes
    -- the threat (plus a small bias toward the last retreat direction).
    local prevX, prevZ
    local cached = retreatDirCache[unitID]
    if cached then prevX, prevZ = cached[1], cached[2] end

    local bestScore = -2
    local bestAwayDot = -2
    local bestDirX = awayNX
    local bestDirZ = awayNZ

    for i = 1, TANGENTIAL_ANGLE_COUNT do
        local a = TANGENTIAL_ANGLES[i]
        local cosA = a[1]
        local sinA = a[2]
        local tangX = fwdX * cosA - fwdZ * sinA
        local tangZ = fwdX * sinA + fwdZ * cosA
        local awayDot = tangX * awayNX + tangZ * awayNZ
        local score = awayDot
        if prevX then score = score + 0.25 * (tangX * prevX + tangZ * prevZ) end
        if score > bestScore then
            bestScore = score
            bestAwayDot = awayDot
            bestDirX = tangX
            bestDirZ = tangZ
        end
    end

    -- Every tangent points back at the enemy, just retreat straight away
    if bestAwayDot < -0.55 then
        retreatDirCache[unitID] = nil
        bestDirX = awayNX
        bestDirZ = awayNZ
    else
        retreatDirCache[unitID] = { bestDirX, bestDirZ }
    end

    local tx = ux + bestDirX * dist
    local tz = uz + bestDirZ * dist
    if tx < minX then tx = minX elseif tx > maxX then tx = maxX end
    if tz < minZ then tz = minZ elseif tz > maxZ then tz = maxZ end
    tx, tz = M.NudgeOutOfLava(tx, tz, ux, uz)
    return tx, tz
end

--------------------------------------------------------------------------------
-- Unit-def classification (cached per defID)
--------------------------------------------------------------------------------

local canStrafeCache = {}
function M.CanStrafeByDefID(uDefID)
    if not uDefID then return false end
    if canStrafeCache[uDefID] ~= nil then return canStrafeCache[uDefID] end
    local uDef = UnitDefs[uDefID]
    local result = false
    if uDef and uDef.speed and uDef.speed > 0 and not uDef.isBuilding and not uDef.canFly then
        if not uDef.weapons or #uDef.weapons == 0 then
            result = true
        else
            local allTurreted = true
            for i = 1, #uDef.weapons do
                local wd = uDef.weapons[i].weaponDef
                local wDef = wd and M.SafeGetWeaponDef(wd)
                if wDef and wDef.turret == false then
                    allTurreted = false
                    break
                end
            end
            result = allTurreted
        end
    end
    canStrafeCache[uDefID] = result
    return result
end

-- I like to keep mine layers separate from everything else, one, because
-- I'm not too sure of their feasability in a real game
-- and two, because they're not meant to be combat units.
function M.IsTrapper(uDef)
    if not uDef then return false end
    local name = uDef.name and sLower(uDef.name) or ""
    if sFind(name, "trap") then return true end
    if uDef.customParams and (uDef.customParams.trap ~= nil or uDef.customParams.istrap ~= nil) then return true end
    if uDef.isBuilder and uDef.buildOptions then
        for i = 1, #uDef.buildOptions do
            local optDef = UnitDefs[uDef.buildOptions[i]]
            if optDef and sFind(sLower(optDef.name or ""), "mine") then return true end
        end
    end
    return false
end

local aaWeaponCache = {}
function M.IsAAWeapon(uDefID, weaponDefID)
    if not weaponDefID then return false end
    local perUnit
    if uDefID then
        perUnit = aaWeaponCache[uDefID]
        if not perUnit then
            perUnit = {}
            aaWeaponCache[uDefID] = perUnit
        end
    end
    local cached = perUnit and perUnit[weaponDefID]
    if cached ~= nil then return cached end

    local result = false

    local d = uDefID and UnitDefs[uDefID]
    if d and d.weapons then
        for i = 1, #d.weapons do
            local mount = d.weapons[i]
            if mount.weaponDef == weaponDefID then
                local ot = mount.onlyTargets
                if ot and ot.vtol then
                    result = true
                    for cat, on in pairs(ot) do
                        if on and cat ~= "vtol" then result = false break end
                    end
                end
                break
            end
        end
    end

    local wDef = WeaponDefs[weaponDefID]
    if not result and wDef then
        local ot = wDef.onlyTargets
        if ot and ot.vtol then
            result = true
            for cat, on in pairs(ot) do
                if on and cat ~= "vtol" then result = false break end
            end
        else
            local onlyCat = sLower(wDef.onlyTargetCategory or "")
            if onlyCat ~= "" and onlyCat ~= "notair" then
                result = onlyCat == "vtol"
                if not result then
                    for token in onlyCat:gmatch("%S+") do
                        if token == "vtol" then result = true break end
                    end
                    if result then
                        for token in onlyCat:gmatch("%S+") do
                            if token ~= "vtol" then result = false break end
                        end
                    end
                end
            end
        end
        if not result then
            local wName = sLower(wDef.name or "")
            local wType = sLower(wDef.type or "")
            result = (sFind(wName, "flak") or sFind(wType, "aa")) and true or false
        end
    end

    if perUnit then perUnit[weaponDefID] = result end
    return result
end

function M.GetAAWeaponRange(uDefID)
    local perUnit
    if uDefID then
        perUnit = aaWeaponCache[uDefID]
        if not perUnit then
            perUnit = {}
            aaWeaponCache[uDefID] = perUnit
        end
    end
    if perUnit and perUnit.range ~= nil then return perUnit.range end
    local d = uDefID and UnitDefs[uDefID]
    local best = 0
    if d and d.weapons then
        for i = 1, #d.weapons do
            local wDef = M.SafeGetWeaponDef(d.weapons[i].weaponDef)
            if wDef and M.IsAAWeapon(uDefID, d.weapons[i].weaponDef) then
                if (wDef.range or 0) > best then best = wDef.range or 0 end
            end
        end
    end
    if perUnit then perUnit.range = best end
    return best
end

function M.GetEngageRange(uDefID, targetDef)
    if targetDef and targetDef.canFly then
        local gr = M.GetGroundRange(uDefID)
        local ar = M.GetAAWeaponRange(uDefID)
        if ar > gr then return ar end
    end
    return M.GetGroundRange(uDefID)
end

local vehFacCache = {}
function M.IsVehicleFactory(uDefID)
    if not uDefID then return false end
    if vehFacCache[uDefID] ~= nil then return vehFacCache[uDefID] end
    local d = UnitDefs[uDefID]
    if not d or not d.isFactory then vehFacCache[uDefID] = false return false end

    local name = d.name and sLower(d.name) or ""
    local hName = M.GetHumanName(d)

    if d.minWaterDepth and d.minWaterDepth > 0 then vehFacCache[uDefID] = false return false end

    -- look at moveDef categories, if its not there, then name checks are the fallback
    local mc = d.modCategories
    if mc then
        if mc.bot and not mc.tank then vehFacCache[uDefID] = false return false end
        if mc.tank and not mc.bot then vehFacCache[uDefID] = true return true end
    end

    if sFind(name, "kbot") or sFind(name, "botlab") or sFind(name, "kbotlab") then vehFacCache[uDefID] = false return false end
    if sFind(hName, "kbot") or sFind(hName, "bot lab") or sFind(hName, "kbot lab") or sFind(hName, "k-bots") then vehFacCache[uDefID] = false return false end
    if (sFind(name, "bot") or sFind(hName, "bot")) and not sFind(name, "tank") and not sFind(hName, "tank") then vehFacCache[uDefID] = false return false end

    if sFind(name, "veh") or sFind(name, "vehicle") or sFind(name, "tank") or sFind(hName, "veh") or sFind(hName, "vehicle") or sFind(hName, "tank") then vehFacCache[uDefID] = true return true end
    if sFind(name, "vp") then vehFacCache[uDefID] = true return true end
    if sFind(hName, "vehicle plant") or sFind(hName, "vehicle lab") then vehFacCache[uDefID] = true return true end

    local groundVehCount, groundBotCount = 0, 0
    if d.buildOptions then
        for i = 1, #d.buildOptions do
            local bd = UnitDefs[d.buildOptions[i]]
            if bd and bd.speed and bd.speed > 0 and not bd.canFly and not bd.minWaterDepth then
                local isVeh, isBot = false, false
                local bmc = bd.modCategories
                if bmc then
                    if bmc.bot then isBot = true
                    elseif bmc.tank then isVeh = true end
                end
                if not isVeh and not isBot then
                    local bn = sLower(bd.name or "")
                    if sFind(bn, "veh") or sFind(bn, "tank") or sFind(bn, "lev") or sFind(bn, "rustler") or sFind(bn, "flash") or sFind(bn, "weasel") or sFind(bn, "gator") or sFind(bn, "logger") or sFind(bn, "heavyart") or sFind(bn, "mortartn") or sFind(bn, "pincer") or sFind(bn, "rodos") then
                        isVeh = true
                    elseif sFind(bn, "bot") or sFind(bn, "peew") or sFind(bn, "pew") or sFind(bn, "rocko") or sFind(bn, "rock") or sFind(bn, "zeus") or sFind(bn, "spider") or sFind(bn, "flea") or sFind(bn, "chicken") or sFind(bn, "klack") or sFind(bn, "switch") or sFind(bn, "kbot") then
                        isBot = true
                    end
                end
                if isVeh then groundVehCount = groundVehCount + 1
                elseif isBot then groundBotCount = groundBotCount + 1 end
            end
        end
    end

    if groundVehCount >= groundBotCount and groundVehCount > 0 then vehFacCache[uDefID] = true return true end
    vehFacCache[uDefID] = false
    return false
end

local hoverFacCache = {}
function M.IsHoverFactory(uDefID)
    if not uDefID then return false end
    if hoverFacCache[uDefID] ~= nil then return hoverFacCache[uDefID] end
    local d = UnitDefs[uDefID]
    if not d or not d.isFactory then hoverFacCache[uDefID] = false return false end
    local name = d.name and sLower(d.name) or ""
    local hName = M.GetHumanName(d)
    -- explicit name hits
    if sFind(name, "hov") or sFind(name, "hover") or sFind(name, "hplant") or sFind(hName, "hover") or sFind(hName, "hove") then
        hoverFacCache[uDefID] = true return true
    end
    -- hover units are amphibious-ish terrain walkers; check the factory's output
    if d.buildOptions then
        for i = 1, #d.buildOptions do
            local bd = UnitDefs[d.buildOptions[i]]
            if bd and bd.speed and bd.speed > 0 and not bd.canFly and not d.minWaterDepth then
                local bmc = bd.modCategories
                if bmc and bmc.hover then hoverFacCache[uDefID] = true return true end
            end
        end
    end
    hoverFacCache[uDefID] = false
    return false
end

local airFactoryCache = {}
function M.IsAirFactory(uDefID)
    if not uDefID then return false end
    if airFactoryCache[uDefID] ~= nil then return airFactoryCache[uDefID] end
    local d = UnitDefs[uDefID]
    local result = false
    if d and d.isFactory and d.buildOptions and #d.buildOptions > 0 then
        local total, airCount = 0, 0
        for i = 1, #d.buildOptions do
            local bd = UnitDefs[d.buildOptions[i]]
            if bd then
                total = total + 1
                if bd.canFly then airCount = airCount + 1 end
            end
        end
        result = total > 0 and (airCount == total)
    end
    airFactoryCache[uDefID] = result
    return result
end

function M.IsAmphibiousCon(name, d)
	-- I know I should be accomdatating to all metal maps, and *maybe*
	-- amphibious cons can be useful (somewhere?)
	-- but in all metal maps that we have so far, there's generally no area where
	-- making amphibious cons is better
	-- they're more expesnive with worse stats
    -- If it were a metal map with a sea,
    -- i'd much rather make an air con
    local hName = M.GetHumanName(d)
    local desc = M.GetDescription(d)
    if sFind(hName, "amphibious") or sFind(desc, "amphibious") then
        if d and d.isBuilder and d.speed and d.speed > 0 and not d.canFly then return true end
    end
    if d and d.modCategories and d.modCategories.phib then
        if d.isBuilder and d.speed and d.speed > 0 and not d.canFly then return true end
    end
    if sFind(name, "amph") then return true end
    if sFind(name, "acaorn") then return true end
    if sFind(name, "aconv") then return true end
    if sFind(name, "amcon") then return true end
    if sFind(name, "csub") then return true end
    if d and d.customParams and d.customParams.is_amphibious then return true end
    return false
end

function M.IsArtillery(d)
    if d.weapons and d.weapons[1] then
        local wd = d.weapons[1].weaponDef and M.SafeGetWeaponDef(d.weapons[1].weaponDef)
        if wd and wd.range and wd.range > 850 then return true end
    end
    return false
end

local antinukeDefCache = {}
function M.IsAntiNukeDef(uDefID)
    if not uDefID then return false end
    if antinukeDefCache[uDefID] ~= nil then return antinukeDefCache[uDefID] end
    local d = uDefID and UnitDefs[uDefID]
    local result = false
    if d then
        local name = d.name and sLower(d.name) or ""
        if sFind(name, "anti_nuke") or sFind(name, "antinuke") or sFind(name, "nukeguard") then
            result = true
        elseif d.weapons then
            for wi = 1, #d.weapons do
                local wDef = d.weapons[wi].weaponDef and WeaponDefs[d.weapons[wi].weaponDef]
                if wDef then
                    local wType = wDef.type and sLower(wDef.type) or ""
                    if sFind(wType, "antinuke") or ((wDef.interceptor or 0) ~= 0 and wDef.coverageRange) then result = true break end
                end
            end
        end
    end
    antinukeDefCache[uDefID] = result
    return result
end

local antinukeCoverageCache = {}
function M.GetAntiNukeCoverage(defID)
    if not defID then return 0 end
    local cached = antinukeCoverageCache[defID]
    if cached ~= nil then return cached end
    local d = UnitDefs[defID]
    local best = 0
    if d and d.weapons then
        for i = 1, #d.weapons do
            local wDef = M.SafeGetWeaponDef(d.weapons[i].weaponDef)
            if wDef and (wDef.interceptor or 0) ~= 0 and wDef.coverageRange then
                if wDef.coverageRange > best then best = wDef.coverageRange end
            end
        end
    end
    antinukeCoverageCache[defID] = best
    return best
end

local defenseDefCache = {}
function M.IsDefenseDef(defID)
    if not defID then return false end
    local cached = defenseDefCache[defID]
    if cached ~= nil then return cached end
    local d = UnitDefs[defID]
    local result = false
    if d then
        local isMobile = d.speed and d.speed > 0
        local hasWpn = d.weapons and #d.weapons > 0
        local isShield = false
        if hasWpn then
            for i = 1, #d.weapons do
                local wDef = M.SafeGetWeaponDef(d.weapons[i].weaponDef)
                if wDef and wDef.isShield then isShield = true break end
            end
        end
        local isAntinuke = M.IsAntiNukeDef(defID)
        local isMex = d.extractsMetal and d.extractsMetal > 0
        local isEnergy = (d.energyMake and d.energyMake > 0) or (d.windGenerator and d.windGenerator > 0)
        local isRadar = (d.radarDistance and d.radarDistance > 0) or (d.sonarDistance and d.sonarDistance > 0)
        if not isMobile and hasWpn and not d.isFactory and not d.isBuilder
            and not isShield and not isAntinuke and not isMex and not isEnergy and not isRadar then
            result = true
        end
    end
    defenseDefCache[defID] = result
    return result
end

local aaOnlyDefCache = {}
function M.IsAAOnlyDef(defID)
    if not defID then return false end
    local cached = aaOnlyDefCache[defID]
    if cached ~= nil then return cached end
    if not M.IsDefenseDef(defID) then aaOnlyDefCache[defID] = false return false end
    local d = UnitDefs[defID]
    local result = false
    if d and d.weapons and #d.weapons > 0 then
        result = true
        for i = 1, #d.weapons do
            if not M.IsAAWeapon(defID, d.weapons[i].weaponDef) then result = false break end
        end
    end
    aaOnlyDefCache[defID] = result
    return result
end

function M.IsScoutDef(d)
    if not d then return false end
    local mc = d.modCategories
    if mc then
        for k in pairs(mc) do
            if sFind(k, "scout") then return true end
        end
    end
    local cat = d.category
    if type(cat) == "string" and sFind(cat, "SCOUT") then return true end
    local name = d.name and sLower(d.name) or ""
    local hName = M.GetHumanName(d)
    if sFind(name, "scout") or sFind(hName, "scout") or sFind(name, "peep") or sFind(name, "flea") or sFind(name, "fink") or sFind(name, "phantom") or sFind(name, "weasel") or sFind(name, "wheelie") then
        return true
    end
    return (d.speed and d.speed > 150 and (not d.weapons or #d.weapons == 0))
end

function M.IsWallDef(d)
    if not d then return false end
    if d.speed and d.speed > 0 then return false end
    if (d.weapons and #d.weapons > 0) then return false end
    if (d.metalCost or 0) > 100 then return false end
    local name = d.name and sLower(d.name) or ""
    local hName = M.GetHumanName(d)
    if sFind(name, "drag") or sFind(name, "claw") or sFind(name, "maw") or sFind(name, "teeth") or sFind(name, "wall") then return true end
    if sFind(hName, "dragon") or sFind(hName, "teeth") then return true end
    return false
end

--------------------------------------------------------------------------------
-- Air unit classification
--------------------------------------------------------------------------------

local bomberCache = {}
-- remember enemy structure locations so we
-- can queue a bomb order without having LOS
-- this would be cleared once we do get LOS
-- so the worst is a wasted bombing
function M.IsBomberDef(uDefID)
    if not uDefID then return false end
    local cached = bomberCache[uDefID]
    if cached ~= nil then return cached end
    local d = uDefID and UnitDefs[uDefID]
    local result = false
    if d and d.canFly and d.weapons then
        for i = 1, #d.weapons do
            local wDef = M.SafeGetWeaponDef(d.weapons[i].weaponDef)
            if wDef and wDef.type and sLower(wDef.type) == "aircraftbomb" then result = true break end
        end
    end
    bomberCache[uDefID] = result
    return result
end

local fighterCache = {}
-- an aircraft whose only weapons are AA is a fighter
-- don't be distracted by it
function M.IsFighterDef(uDefID)
    if fighterCache[uDefID] ~= nil then return fighterCache[uDefID] end
    local d = uDefID and UnitDefs[uDefID]
    local result = false
    if d and d.canFly and d.weapons then
        local hasGround = false
        for i = 1, #d.weapons do
            if not M.IsAAWeapon(uDefID, d.weapons[i].weaponDef) then hasGround = true break end
        end
        result = not hasGround
    end
    fighterCache[uDefID] = result
    return result
end

local junoBomberCache = {}
function M.IsJunoBomberDef(uDefID)
    if not uDefID then return false end
    local cached = junoBomberCache[uDefID]
    if cached ~= nil then return cached end
    local d = uDefID and UnitDefs[uDefID]
    local result = false
    if d and d.canFly and d.weapons then
        for i = 1, #d.weapons do
            local wDef = M.SafeGetWeaponDef(d.weapons[i].weaponDef)
            if wDef and wDef.customParams and wDef.customParams.junotype then
                result = true
                break
            end
        end
    end
    junoBomberCache[uDefID] = result
    return result
end

-- what the Juno pulse can actually kill, ignore everything else
function M.IsJunoVulnerableDef(d)
    if not d then return false end
    if d.modCategories and d.modCategories.mine then return true end
    if M.IsScoutDef(d) then return true end
    if (d.radarDistance and d.radarDistance > 0) then return true end
    if (d.sonarDistance and d.sonarDistance > 0) then return true end
    if (d.radarDistanceJam and d.radarDistanceJam > 0) then return true end
    if d.stealth then return true end
    return false
end

local aaUnitCache = {}
function M.IsAntiAirUnit(uDefID)
    if not uDefID then return false end
    local cached = aaUnitCache[uDefID]
    if cached ~= nil then return cached end
    local d = uDefID and UnitDefs[uDefID]
    local result = false
    if d and d.weapons then
        for i = 1, #d.weapons do
            if M.IsAAWeapon(uDefID, d.weapons[i].weaponDef) then
                result = true
                break
            end
        end
    end
    aaUnitCache[uDefID] = result
    return result
end

--------------------------------------------------------------------------------
-- Ranges and damage estimates
--------------------------------------------------------------------------------

-- attack range, AA-aware: maxWeaponRange includes AA guns, which would make
-- ground units kite at the wrong distance. Fighters keep full range.
local groundRangeCache = {}
function M.GetGroundRange(uDefID)
    if not uDefID then return 0 end
    if groundRangeCache[uDefID] ~= nil then return groundRangeCache[uDefID] end
    local d = uDefID and UnitDefs[uDefID]
    local best = 0
    if d then
        if d.canFly then
            best = d.maxWeaponRange or 0
        elseif d.weapons then
            for i = 1, #d.weapons do
                local wDef = M.SafeGetWeaponDef(d.weapons[i].weaponDef)
                if not M.IsAAWeapon(uDefID, d.weapons[i].weaponDef) and wDef then
                    if (wDef.range or 0) > best then best = wDef.range or 0 end
                end
            end
        end
    end
    groundRangeCache[uDefID] = best
    return best
end

-- Rough single-weapon DPS: a relative lethality estimate only
local function GetWeaponDPS(wDef)
    if not wDef then return 0 end
    local dm = wDef.damages
    local dmg = dm and (dm[0] or dm.default or 0) or 0
    local reload = wDef.reload or 1
    if reload <= 0 then reload = 1 end
    return (dmg / reload) * (wDef.salvoSize or 1) * (wDef.projectiles or 1)
end

-- Total DPS of a unit's ground-capable weapons, AA skipped
local unitDPSCache = {}
function M.GetUnitDPS(defID)
    if not defID then return 0 end
    local cached = unitDPSCache[defID]
    if cached ~= nil then return cached end
    local d = UnitDefs[defID]
    local total = 0
    if d and d.weapons then
        for i = 1, #d.weapons do
            local wDef = M.SafeGetWeaponDef(d.weapons[i].weaponDef)
            if wDef then
                local wType = wDef.type and sLower(wDef.type) or ""
                local wName = wDef.name and sLower(wDef.name) or ""
                local onlyCat = wDef.onlyTargetCategory and sLower(wDef.onlyTargetCategory) or ""
                local isAA = sFind(wName, "flak") or sFind(wType, "aa") or sFind(onlyCat, "vtol")
                if not isAA then total = total + GetWeaponDPS(wDef) end
            end
        end
    end
    unitDPSCache[defID] = total
    return total
end

-- blast radius from the unit's selfDExplosion weapon TODO: work on this
local selfDBlastCache = {}
function M.GetSelfDBlastRadius(defID)
    if selfDBlastCache[defID] ~= nil then return selfDBlastCache[defID] end
    local d = defID and UnitDefs[defID]
    local result = 0
    if d then
        local sdn = d.selfDExplosion
        if sdn and sdn ~= "" then
            local wn = WeaponDefNames[sdn] or WeaponDefNames[sLower(sdn)]
            local wid = wn and wn.id
            local wd = wid and WeaponDefs[wid]
            if wd then result = wd.damageAreaOfEffect or wd.areaOfEffect or 0 end
        end
    end
    selfDBlastCache[defID] = result
    return result
end

--------------------------------------------------------------------------------
-- Misc small helpers
--------------------------------------------------------------------------------

function M.FactoryTurretInfo(facDefID)
    local d = UnitDefs[facDefID]
    local cost = d and (d.metalCost or 0) or 0
    if cost >= 4000 then return 12, 200 end
    if cost >= 1000 then return 8, 160 end
    return 6, 128
end

function M.GetFacingVector(facing)
    if facing == 0 then return 0, 1
    elseif facing == 1 then return 1, 0
    elseif facing == 2 then return 0, -1
    elseif facing == 3 then return -1, 0
    end
    return 0, 1
end

-- The speed a combat unit must have to double as a scout,
-- My thinking is factions scouts can have different speeds, so let's not hardcode anything
local scoutSpeedThreshold = nil
function M.GetScoutSpeedThreshold()
    if scoutSpeedThreshold then return scoutSpeedThreshold end
    local best = mHuge
    for i = 1, #UnitDefs do
        local d = UnitDefs[i]
        if d and M.IsScoutDef(d) and d.speed and d.speed > 0 then
            if d.speed < best then best = d.speed end
        end
    end
    scoutSpeedThreshold = (best ~= mHuge) and best or 45
    return scoutSpeedThreshold
end

function M.GetGameID()
    return Spring.GetGameRulesParam("GameID") or (Game and Game.gameID) or "0"
end

-- We have to do this because when spectating the game, it shows all units as ours
-- This confuses the bot and causes a lot of lag from failed commands
-- Also worth nothing, that the engine reports everyone as spectating during the
-- pre-game countdown, so only run this once the game is started.
function M.IsSpectating()
    if not Spring.GetSpectatingState then return false end
    local s = Spring.GetSpectatingState()
    if not (s and s ~= 0) then return false end
    return (Spring.GetGameFrame() or 0) > 0
end

--------------------------------------------------------------------------------
-- Per-unit cleanup hooks (called from widget:UnitDestroyed)
--------------------------------------------------------------------------------

function M.OnUnitDestroyed(unitID)
    retreatDirCache[unitID] = nil
end

return M

end
