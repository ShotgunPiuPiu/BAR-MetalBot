--[[
    ShotgunMetal / military.lua
    Combat targeting: cluster/AoE target search, bomb-target memory,
    reclaim/resurrect/chase targets, defense recall coordination and
    spread/frontier movement helpers.
    Depends on: config, state, utils, intel (via D).
]]

local Spring = Spring
local Game   = Game
local math   = math
local string = string
local table  = table

local mFloor = math.floor
local mMax   = math.max
local mMin   = math.min
local mHuge  = math.huge
local mSqrt  = math.sqrt
local mAtan2 = math.atan2
local mCos   = math.cos
local mSin   = math.sin

local sLower = string.lower
local sFind  = string.find

local spGetUnitPosition   = Spring.GetUnitPosition
local spGetUnitDefID      = Spring.GetUnitDefID
local spGetUnitTeam       = Spring.GetUnitTeam
local spGetUnitAllyTeam   = Spring.GetUnitAllyTeam
local spGetUnitVelocity   = Spring.GetUnitVelocity
local spGetUnitHealth     = Spring.GetUnitHealth
local spGetUnitCommands   = Spring.GetUnitCommands
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spGetFeaturesInCylinder = Spring.GetFeaturesInCylinder
local spGetFeaturePosition = Spring.GetFeaturePosition
local spGetFeatureResources = Spring.GetFeatureResources
local spGetFeatureResurrect = Spring.GetFeatureResurrect
local spGetMyTeamID       = Spring.GetMyTeamID
local spGetMyAllyTeamID   = Spring.GetMyAllyTeamID
local spGetGaiaTeamID     = Spring.GetGaiaTeamID
local spAreTeamsAllied    = Spring.AreTeamsAllied
local spGiveOrderToUnit   = Spring.GiveOrderToUnit
local spGetGroundHeight   = Spring.GetGroundHeight

return function(cfg, st, U, D)

local tClear = table.clear

local W = {}

--------------------------------------------------------------------------------
-- Reclaim / resurrect / chase targets
--------------------------------------------------------------------------------

function W.FindReclaimTarget(ux, uz, isStalling, radiusOverride)
    local reclaimRange = cfg.RECLAIM_RANGE * (st.mapLinearScale or 1)
    local radius = radiusOverride or (isStalling and (reclaimRange * 2) or reclaimRange)
    local feats = spGetFeaturesInCylinder(ux, uz, radius)
    if not feats or #feats == 0 then return nil end

    local minMetal = (st.metalIncome or 0) * cfg.RECLAIM_MIN_METAL_SECONDS
    local bestID, bestScore = nil, -mHuge
    local bestX, bestZ

    for i = 1, #feats do
        local fID = feats[i]
        local metal = spGetFeatureResources(fID)
        if metal and metal >= minMetal then
            local fx, _, fz = spGetFeaturePosition(fID)
            if fx then
                local dx, dz = fx - ux, fz - uz
                local dist = math.sqrt(dx * dx + dz * dz) + 1
                local score = metal / (dist * dist * dist)
                if score > bestScore then
                    bestScore = score
                    bestID = fID
                    bestX, bestZ = fx, fz
                end
            end
        end
    end

    return bestID, bestX, bestZ
end

function W.FindResurrectTarget(ux, uz, radius)
    local feats = spGetFeaturesInCylinder(ux, uz, radius)
    if not feats then return nil end
    local bestID, bestScore = nil, -mHuge
    local bestX, bestZ, bestMetal
    for i = 1, #feats do
        local fID = feats[i]
        local rezName = spGetFeatureResurrect(fID)
        if rezName and rezName ~= "" then
            local fx, _, fz = spGetFeaturePosition(fID)
            if fx then
                local dx, dz = fx - ux, fz - uz
                local dist = math.sqrt(dx*dx + dz*dz) + 1
                -- prefer high-value wrecks, and only lightly weigh distance
                local metal = spGetFeatureResources(fID) or 0
                local score = metal / (1 + dist * 0.02)
                if score > bestScore then bestScore, bestID, bestX, bestZ, bestMetal = score, fID, fx, fz, metal end
            end
        end
    end
    return bestID, bestX, bestZ, bestMetal
end

function W.FindEnemyReclaimTarget(ux, uz, radius, myTeamID, myAllyTeamID, mobileChaser)
    local nearby = spGetUnitsInCylinder(ux, uz, radius)
    if not nearby or #nearby == 0 then return nil end

    myAllyTeamID = myAllyTeamID or spGetMyAllyTeamID()

    local isChaser = mobileChaser ~= nil
    local minCost = isChaser and ((st.metalIncome or 0) * cfg.ENEMY_RECLAIM_MIN_COST_SECONDS) or 0
    local bestID, bestScore = nil, -mHuge
    local bestX, bestZ

    for i = 1, #nearby do
        local nID = nearby[i]
        local nAllyTeam = spGetUnitAllyTeam(nID)

        if nAllyTeam and nAllyTeam ~= myAllyTeamID then
            local nDefID = spGetUnitDefID(nID)
            local nDef = nDefID and UnitDefs[nDefID]

            if nDef and not (isChaser and nDef.canFly) then
                local metalCost = nDef.metalCost or 0

                if metalCost >= minCost then
                    local nx, _, nz = spGetUnitPosition(nID)
                    if nx then
                        -- skip enemies fleeing toward their base
                        local movingAway = false
                        if isChaser then
                            local vx, _, vz = spGetUnitVelocity(nID)
                            if vx then
                                local refX = st.baseCenterX or ux
                                local refZ = st.baseCenterZ or uz
                                local towardX = refX - nx
                                local towardZ = refZ - nz
                                movingAway = (vx * towardX + vz * towardZ < 0)
                            end
                        end

                        if not movingAway then
                            local dx, dz = nx - ux, nz - uz
                            local distSq = dx * dx + dz * dz

                            local hp, maxHp = spGetUnitHealth(nID)
                            local damageBonus = 0.25
                            if hp and maxHp and maxHp > 0 then
                                damageBonus = damageBonus + (1.0 - (hp / maxHp))
                            end

                            local score = (metalCost * damageBonus) / (distSq + 1)

                            if score > bestScore then
                                bestScore = score
                                bestID = nID
                                bestX, bestZ = nx, nz
                            end
                        end
                    end
                end
            end
        end
    end

    return bestID, bestX, bestZ
end

--------------------------------------------------------------------------------
-- Cluster / AoE targeting
--------------------------------------------------------------------------------

local function GetEnemyUnitsInCylinder(x, z, radius)
    if Spring.ENEMY_UNITS then
        return spGetUnitsInCylinder(x, z, radius, Spring.ENEMY_UNITS)
    end
    return spGetUnitsInCylinder(x, z, radius)
end

W.GetEnemyUnitsInCylinder = GetEnemyUnitsInCylinder

function W.FindBestClusterTarget(fromX, fromZ, searchRadius, aoeRadius, shooterDefID)
    local nearby = GetEnemyUnitsInCylinder(fromX, fromZ, searchRadius)
    if not nearby or #nearby == 0 then return nil end

    -- Structure-of-arrays to avoid hundreds of small tables.
    local eID, eX, eZ, eCost = {}, {}, {}, {}
    local enCount = 0
    -- ground non-AA units and bombers should ignore air
    -- AA-only fighters can't hit ground.
    -- ignore cheap scouts, fire at will would attack them anyways
    local shooterDef = shooterDefID and UnitDefs[shooterDefID]
    local skipAir = shooterDef and (
        (not shooterDef.canFly and not U.IsAntiAirUnit(shooterDefID))
        or (shooterDef.canFly and not U.IsFighterDef(shooterDefID))
    )
    local skipGround = shooterDef and shooterDef.canFly and U.IsFighterDef(shooterDefID)
    local skipGroundScout = shooterDef and not shooterDef.canFly
    -- Never treat our own/allied/gaia units as targets.
    local myTeamID = spGetMyTeamID()
    local gaiaID = spGetGaiaTeamID()

    for i = 1, #nearby do
        local tID = nearby[i]
        local tTeam = spGetUnitTeam(tID)
        if tTeam and tTeam ~= myTeamID and tTeam ~= gaiaID and not spAreTeamsAllied(myTeamID, tTeam) then
            local tDefID = spGetUnitDefID(tID)
            local tDef = tDefID and UnitDefs[tDefID]
            if tDef and not (skipAir and tDef.canFly)
                and not (skipGround and not tDef.canFly)
                and not (skipGroundScout and not tDef.canFly and U.IsScoutDef(tDef)) then
                local ex, _, ez = spGetUnitPosition(tID)
                if ex and ez then
                    enCount = enCount + 1
                    eID[enCount] = tID
                    eX[enCount] = ex
                    eZ[enCount] = ez
                    eCost[enCount] = tDef.metalCost or 50
                end
            end
        end
    end

    if enCount == 0 then return nil end

    if enCount == 1 then
        local x, z = eX[1], eZ[1]
        return x, spGetGroundHeight(x, z), z, eID[1], 1, eCost[1], false
    end

    if not aoeRadius then aoeRadius = cfg.AOE_DAMAGE_RADIUS end
    local AoESq = aoeRadius * aoeRadius
    local invHalfAoESq = 2 / AoESq

    local bestIdx, bestMetal, bestClusterSize = 1, 0, 0
    local bestCentroidX, bestCentroidZ = eX[1], eZ[1]

    for i = 1, enCount do
        local cx, cz = eX[i], eZ[i]
        local totalMetal = eCost[i]
        local clusterCount = 1
        local sumX, sumZ = cx, cz

        for j = 1, enCount do
            if j ~= i then
                local dx = eX[j] - cx
                local dx2 = dx * dx
                if dx2 < AoESq then
                    local dz = eZ[j] - cz
                    local dz2 = dz * dz
                    if dz2 < AoESq then
                        local dSq = dx2 + dz2
                        if dSq < AoESq then
                            clusterCount = clusterCount + 1
                            totalMetal = totalMetal + eCost[j] / (1 + dSq * invHalfAoESq)
                            sumX = sumX + eX[j]
                            sumZ = sumZ + eZ[j]
                        end
                    end
                end
            end
        end

        -- weigh by cost, not density, give a mild density bonus for AOE value
        local score = totalMetal * (1 + 0.1 * (clusterCount - 1))

        if score > bestMetal then
            bestMetal = score
            bestIdx = i
            bestClusterSize = clusterCount
            bestCentroidX = sumX / clusterCount
            bestCentroidZ = sumZ / clusterCount
        end
    end

    local groundAttack = bestClusterSize >= cfg.CLUSTER_THRESHOLD
    local cx, cz = bestCentroidX, bestCentroidZ
    if not groundAttack then
        cx = eX[bestIdx]
        cz = eZ[bestIdx]
    end

    local cy = spGetGroundHeight(cx, cz)
    return cx, cy, cz, eID[bestIdx], bestClusterSize, bestMetal, groundAttack
end

-- remember enemy structure locations so we
-- can queue a bomb order without having LOS
-- this would be cleared once we do get LOS
-- so the worst is a wasted bombing
function W.FindBombTargetFromMemory(fromX, fromZ)
    local bases = st.enemyBases
    if not bases then return nil end

    local bestScore, bestX, bestY, bestZ = 0, nil, nil, nil

    for _, b in pairs(bases) do
        if b.lastSeen and b.lastSeen > 0 then
            local dx, dz = b.x - fromX, b.z - fromZ
            local dSq = dx * dx + dz * dz
            local score = (b.cost or 100) / (1 + mSqrt(dSq) * 0.01)
            if b.isFactory then score = score * 1.25 end
            if score > bestScore then
                bestScore = score
                bestX, bestY, bestZ = b.x, b.y or 0, b.z
            end
        end
    end

    return bestX, bestY, bestZ
end

--------------------------------------------------------------------------------
-- Defense recall & movement helpers
--------------------------------------------------------------------------------

local function SortDefenders(a, b)
    return a.eta < b.eta
end

function W.UpdateDefenseCoordination(frame)
    if tClear then
        tClear(st.currentDefenders)
    else
        for k in pairs(st.currentDefenders) do st.currentDefenders[k] = nil end
    end

    local udbg = st.uneaseDbg
    if not st.unease or st.unease <= 0 then return end
    udbg.detected = udbg.detected + 1
    if not st.uneaseX then return end
    udbg.fired = udbg.fired + 1
    udbg.lastUnease = mFloor(st.unease)

    local cands = {}
    for i = 1, st.myCombatUnitCount do
        local uID = st.myCombatUnits[i]
        local ux, _, uz = spGetUnitPosition(uID)
        if ux then
            local ddx, ddz = ux - st.uneaseX, uz - st.uneaseZ
            local uDef = UnitDefs[spGetUnitDefID(uID)]
            local speed = uDef and uDef.speed or 0
            cands[#cands + 1] = { id = uID, eta = (speed > 0) and (mSqrt(ddx * ddx + ddz * ddz) / speed) or mHuge }
        end
    end
    if #cands == 0 then
        udbg.noCands = udbg.noCands + 1
        return
    end
    table.sort(cands, SortDefenders)
    local budget = st.unease * cfg.UNEASE_OVERRUN_RATIO
    local spent, recalled = 0, 0
    for i = 1, #cands do
        if spent >= budget then break end
        local uID = cands[i].id
        -- performance thing, skip re-issuing if already heading to the threat.
        -- it's much cheaper to do this on our end, then send the network packet
        -- and wait for a response, there's also a concern that we'll be packet limited
        -- if we send too many packets
        local cs = spGetUnitCommands(uID, 1)
        local c1 = cs and cs[1]
        local already = (c1 and c1.id == cfg.CMD_MOVE and c1.params and c1.params[1] and c1.params[3]
            and ((st.uneaseX - c1.params[1]) * (st.uneaseX - c1.params[1]) + (st.uneaseZ - c1.params[3]) * (st.uneaseZ - c1.params[3]) < 160 * 160))
        if not already then
            spGiveOrderToUnit(uID, cfg.CMD_MOVE, { st.uneaseX, spGetGroundHeight(st.uneaseX, st.uneaseZ), st.uneaseZ }, {})
        end
        st.currentDefenders[uID] = true
        -- Already-heading units count toward the budget too
        local uDef = spGetUnitDefID(uID) and UnitDefs[spGetUnitDefID(uID)]
        spent = spent + ((uDef and uDef.metalCost) or 50)
        recalled = recalled + 1
        udbg.recalled = udbg.recalled + 1
    end
end

local SPREAD_HOLD_DIST = 160
function W.GiveSpreadMove(unitID, ux, uz, tx, tz, minR, maxR, targetID)
    local sx, sz = U.GetFlankSpreadPos(unitID, tx, tz, minR, maxR, targetID)
    sx, sz = U.NudgeOutOfLava(sx, sz, ux, uz)
    local dx, dz = sx - ux, sz - uz
    if dx * dx + dz * dz >= SPREAD_HOLD_DIST * SPREAD_HOLD_DIST then
        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { sx, spGetGroundHeight(sx, sz), sz }, {})
    end
end

-- no combat unit is ever left idle
function W.PushFrontier(unitID, ux, uz)
    local fX, fZ = D.intel.GetForwardTarget()
    if fX then
        local dir = mAtan2(fZ - uz, fX - ux)
        local lat = (U.UnitHash(unitID, 6) - 0.5) * 2.2
        local leg = 600 + U.UnitHash(unitID, 7) * 400
        local tx = ux + mCos(dir + lat) * leg
        local tz = uz + mSin(dir + lat) * leg
        local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
        tx = mMax(80, mMin(tx, mapX - 80))
        tz = mMax(80, mMin(tz, mapZ - 80))
        tx, tz = U.NudgeOutOfLava(tx, tz, ux, uz)
        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { tx, spGetGroundHeight(tx, tz), tz }, {})
    else
        -- no enemy known: push toward the far half of the map instead of roaming our side
        local homeX, homeZ = st.baseCenterX, st.baseCenterZ
        local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
        local dirX, dirZ = mapX * 0.5 - (homeX or ux), mapZ * 0.5 - (homeZ or uz)
        local dirLen = math.sqrt(dirX * dirX + dirZ * dirZ)
        local px, pz = ux, uz
        if dirLen > 1e-6 then
            dirX, dirZ = dirX / dirLen, dirZ / dirLen
            local lat = (U.UnitHash(unitID, 6) - 0.5) * 1.6
            local leg = 700 + U.UnitHash(unitID, 7) * 500
            local dir = mAtan2(dirZ, dirX)
            px = ux + mCos(dir + lat) * leg
            pz = uz + mSin(dir + lat) * leg
        else
            local sx, sz = U.GetSpreadPos(unitID, ux, uz, 400, 1200)
            px, pz = sx, sz
        end
        px = mMax(80, mMin(px, mapX - 80))
        pz = mMax(80, mMin(pz, mapZ - 80))
        px, pz = U.NudgeOutOfLava(px, pz, ux, uz)
        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { px, spGetGroundHeight(px, pz), pz }, {})
    end
end

return W

end
