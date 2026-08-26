--[[
    ShotgunMetal / intel.lua
    Enemy intel: threat/base scanning (LOS + radar), prime target selection,
    army attack coordination and scout sector assignment.
    Depends on: config, state, utils.
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
local mAtan2 = math.atan2
local mCos   = math.cos
local mSin   = math.sin
local mSqrt  = math.sqrt

local sLower = string.lower
local sFind  = string.find

local spGetUnitPosition    = Spring.GetUnitPosition
local spGetUnitDefID       = Spring.GetUnitDefID
local spGetUnitTeam        = Spring.GetUnitTeam
local spGetUnitHealth      = Spring.GetUnitHealth
local spGetUnitCommands    = Spring.GetUnitCommands
local spGetUnits           = Spring.GetTeamUnits
local spGetTeamList        = Spring.GetTeamList
local spGetMyAllyTeamID    = Spring.GetMyAllyTeamID
local spGetGaiaTeamID      = Spring.GetGaiaTeamID
local spGetMyTeamID        = Spring.GetMyTeamID
local spAreTeamsAllied     = Spring.AreTeamsAllied
local spGiveOrderToUnit    = Spring.GiveOrderToUnit
local spGetGroundHeight    = Spring.GetGroundHeight
local spIsPosInLos         = Spring.IsPosInLos

return function(cfg, st, U, D)

local I = {}

--------------------------------------------------------------------------------
-- AA threat bookkeeping
--------------------------------------------------------------------------------

function I.CleanupAAThreats(frame)
    local expiryFrame = frame - 1800
    for id, threat in pairs(st.aaThreats) do
        if threat.frame < expiryFrame or not spGetUnitDefID(id) then
            st.aaThreats[id] = nil
        end
    end
end

--------------------------------------------------------------------------------
-- Threat scan: enemy bases, defenses, raiders, unease
--------------------------------------------------------------------------------

function I.UpdateThreat(myTeam, myUnits, frame)
    -- Cleanup old enemy bases
    local enemyBases = st.enemyBases
    local myAllyTeamID = spGetMyAllyTeamID()

    if enemyBases then
        for key, base in pairs(enemyBases) do
            -- If we have LOS on the structure, check if it's still there
            if spIsPosInLos(base.x, 0, base.z, myAllyTeamID) then
                local hp = base.id and spGetUnitHealth(base.id)
                if hp and hp > 0 then
                    base.lastSeen = frame
                    base.lastRadarSeen = frame
                else
                    enemyBases[key] = nil
                    st.intelVersion = st.intelVersion + 1
                end
            end
        end
    else
        enemyBases = {}
        st.enemyBases = enemyBases
    end

    -- enemy defenses keep coords + weapon range after LOS fades
    local enemyDefenses = st.enemyDefenses
    if not enemyDefenses then enemyDefenses = {} st.enemyDefenses = enemyDefenses end
    for dID, dEnt in pairs(enemyDefenses) do
        if spIsPosInLos(dEnt.x, 0, dEnt.z, myAllyTeamID) then
            local hp = spGetUnitHealth(dID)
            if hp and hp > 0 then
                dEnt.lastSeen = frame
            else
                enemyDefenses[dID] = nil
            end
        end
    end

    -- Init raiders and find enemy teams
    local raiders = {}
    local raiderCount = 0

    local gaiaTeam = spGetGaiaTeamID()
    local enemyTeams, eTeamCount = {}, 0
    local tList = spGetTeamList()

    for i = 1, #tList do
        local team = tList[i]
        if team ~= gaiaTeam and not spAreTeamsAllied(myTeam, team) then
            eTeamCount = eTeamCount + 1
            enemyTeams[eTeamCount] = team
        end
    end

    -- Update scout sectors
    local refX, refZ = st.baseCenterX, st.baseCenterZ
    if not refX and st.myCommanders[1] then refX, _, refZ = spGetUnitPosition(st.myCommanders[1]) end
    refX, refZ = refX or 0, refZ or 0
    local scoutSectors = st.scoutSectors
    local floor = mFloor

    -- center in LOS counts as scouted, no need to walk in
    if scoutSectors then
        for key, sector in pairs(scoutSectors) do
            if spIsPosInLos(sector.x, 0, sector.z, myAllyTeamID) then
                sector.lastScouted = frame
            end
        end
    end

    -- Anything physically inside the sector guarantees that it is scouted
    for i = 1, #myUnits do
        local x, _, z = spGetUnitPosition(myUnits[i])
        if x then
            local key = (floor(x / 1024) * 1024) .. "_" .. (floor(z / 1024) * 1024)
            if scoutSectors and scoutSectors[key] then
                scoutSectors[key].lastScouted = frame
            end
        end
    end

    -- Scan enemy units
    local highestThreat, bestX, bestY, bestZ, bestDist, bestID = -1, nil, nil, nil, mHuge, nil
    local bestCost = 0
    -- scan from past the base perimeter outward: a raider chewing mexes at the
    -- edge triggers the same response as one at the core
    local scanR = (cfg.UNEASE_SCAN_BUFFER * st.mapLinearScale) + (cfg.UNEASE_WATCH_RING * st.mapLinearScale) + (st.baseRadius or 0)
    local SCAN_SQ = scanR * scanR
    local unitDefs = UnitDefs
    local maxVisibleCost = 0 -- enemy tech ceiling, this feeds aggression
    -- metal-weighted: a juggernaut alarms more than scoutspam
    -- TODO: make this dps not metal based
    local unease = 0
    local uneaseSumX, uneaseSumZ, uneaseWeight = 0, 0, 0
    local enemyArmyValue = 0 -- total visible enemy mobile metal

    for eIdx = 1, eTeamCount do
        local eUnits = spGetUnits(enemyTeams[eIdx])
        if eUnits then
            for i = 1, #eUnits do
                local uID = eUnits[i]
                local eDefID = spGetUnitDefID(uID)
                local eDef = eDefID and unitDefs[eDefID]
                if eDef then
                    local threat = 10
                    local customParams = eDef.customParams
                    local isCmd = customParams and (customParams.iscommander ~= nil or customParams.is_commander ~= nil)

                    if not isCmd and eDef.name then
                        isCmd = sFind(sLower(eDef.name), "commander", 1, true) ~= nil
                    end

                    -- any structure counts as their base
                    local isBaseWorthy = false
                    if isCmd then threat = 10000 isBaseWorthy = true
                    elseif eDef.isFactory then threat = 5000 isBaseWorthy = true
                    elseif eDef.isBuilding then
                        threat = 1000
                        isBaseWorthy = true
                    end

                    local ex, ey, ez = spGetUnitPosition(uID)
                    if ex then
                        local inLos = spIsPosInLos(ex, ey, ez, myAllyTeamID)
                        if inLos and not isCmd and eDef.metalCost and eDef.metalCost > maxVisibleCost then
                            maxVisibleCost = eDef.metalCost
                        end

                        if inLos and eDef.speed and eDef.speed > 0 and eDef.weapons and #eDef.weapons > 0 then
                            enemyArmyValue = enemyArmyValue + (eDef.metalCost or 50)
                        end

                        -- lastRadarSeen = radar blip, lastSeen = verified in LOS.
                        if isBaseWorthy then
                            local gx, gz = floor(ex / 500), floor(ez / 500)
                            local key = gx .. "_" .. gz
                            local base = enemyBases[key]

                            if base then
                                base.x, base.y, base.z = ex, ey, ez
                                base.id = uID
                                base.defID = eDefID
                                base.cost = eDef.metalCost or 100
                                base.isFactory = eDef.isFactory or nil
                                if inLos then
                                    base.lastSeen = frame
                                    base.lastRadarSeen = frame
                                else
                                    base.lastRadarSeen = frame
                                end
                            else
                                enemyBases[key] = {
                                    id = uID, x = ex, y = ey, z = ez,
                                    defID = eDefID,
                                    cost = eDef.metalCost or 100,
                                    isFactory = eDef.isFactory or nil,
                                    lastSeen = inLos and frame or 0,
                                    lastRadarSeen = frame
                                }
                                -- New enemy base discovered, so let scouts re-aim.
                                st.intelVersion = st.intelVersion + 1
                            end

                            -- remember armed buildings with exact coords + range (LOS-only)
                            if inLos and eDef.maxWeaponRange and eDef.maxWeaponRange > 0 then
                                local gRange = U.GetGroundRange(eDefID)
                                local cur = enemyDefenses[uID]
                                if cur then
                                    cur.x, cur.z, cur.range = ex, ez, gRange
                                    cur.lastSeen = frame
                                else
                                    enemyDefenses[uID] = {
                                        defID = eDefID, x = ex, z = ez,
                                        range = gRange,
                                        cost = eDef.metalCost or 50,
                                        lastSeen = frame
                                    }
                                end
                            end
                        end

                        local dx = ex - refX
                        local dx2 = dx * dx

                        if dx2 < SCAN_SQ then
                            local dz = ez - refZ
                            local dz2 = dz * dz

                            if dz2 < SCAN_SQ then
                                local dist = dx2 + dz2
                                local eSpeed = eDef.speed

                                if dist < SCAN_SQ and eSpeed and eSpeed > 0 and inLos then
                                    raiderCount = raiderCount + 1
                                    raiders[raiderCount] = uID
                                    local uw = eDef.metalCost or 50
                                    unease = unease + uw
                                    uneaseSumX = uneaseSumX + ex * uw
                                    uneaseSumZ = uneaseSumZ + ez * uw
                                    uneaseWeight = uneaseWeight + uw
                                end

                                -- prime target needs true LOS too
                                if inLos and (threat > highestThreat or (threat == highestThreat and dist < bestDist)) then
                                    highestThreat = threat
                                    bestDist = dist
                                    bestX, bestY, bestZ = ex, ey, ez
                                    bestID = uID
                                    bestCost = eDef.metalCost or 50
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    st.raiders = raiders
    st.raiderCount = raiderCount
    st.unease = unease
    if uneaseWeight > 0 then
        st.uneaseX = uneaseSumX / uneaseWeight
        st.uneaseZ = uneaseSumZ / uneaseWeight
    else
        st.uneaseX, st.uneaseZ = nil, nil
    end

    -- this doesn't inhibit scaling to higher tiers,
    -- if our enemey is weak, but it does give
    -- us a fairly rough idea of how advanced the enemy is
    st.enemyTech = mMax(maxVisibleCost, (st.enemyTech or 0) * 0.995)

    -- same idea for total visible mobile combat metal
    st.enemyArmyValue = mMax(enemyArmyValue, (st.enemyArmyValue or 0) * 0.99)

    if bestID then
        st.cachedPrimeTargetPos = { bestX, bestY, bestZ }
        st.cachedPrimeTargetID = bestID
        st.cachedPrimeTargetCost = bestCost
    else
        st.cachedPrimeTargetPos = nil
        st.cachedPrimeTargetID = nil
        st.cachedPrimeTargetCost = nil
    end
end

--------------------------------------------------------------------------------
-- Army target selection & coordination
--------------------------------------------------------------------------------

function I.GetForwardTarget()
    if st.frontierX and st.frontierZ then return st.frontierX, st.frontierZ end
    if st.baseCenterX then
        local bestD, bX, bZ = mHuge, nil, nil
        for _, b in pairs(st.enemyBases) do
            if b.lastSeen then
                local dx, dz = b.x - st.baseCenterX, b.z - st.baseCenterZ
                local d = dx*dx + dz*dz
                if d < bestD then bestD, bX, bZ = d, b.x, b.z end
            end
        end
        if bX then return bX, bZ end
    end
    return nil, nil
end

function I.PickArmyTarget(frame)
    local primeTargetID = st.cachedPrimeTargetID
    local primeTargetPos = st.cachedPrimeTargetPos

    if primeTargetID and primeTargetPos then
        local hp = spGetUnitHealth(primeTargetID)
        if hp and hp > 0 then
            local primeCost = st.cachedPrimeTargetCost or 0
            local commitThreshold = mMax((st.metalIncome or 0) * cfg.UNEASE_FLOOR_INCOME_SECONDS, (st.armyValue or 0) * cfg.UNEASE_ARMY_RATIO)
            if primeCost >= commitThreshold then
                return primeTargetPos[1], primeTargetPos[2], primeTargetPos[3], "prime"
            end
        end
    end

    local enemyBases = st.enemyBases
    if not enemyBases then return nil end

    local bestKey, bestBase, bestDist = nil, nil, mHuge
    local rx, rz = st.army.targetX or 0, st.army.targetZ or 0

    for key, base in pairs(enemyBases) do
        if base.lastSeen then
            local dx, dz = base.x - rx, base.z - rz
            local distSq = dx * dx + dz * dz

            if distSq < bestDist then
                bestDist = distSq
                bestBase = base
                bestKey = key
            end
        end
    end

    if bestBase then
        -- hit the known defense at this base first
        local dBest = nil
        if st.enemyDefenses then
            local bestD2 = (cfg.DEFENSE_TARGET_RADIUS * st.mapLinearScale) * (cfg.DEFENSE_TARGET_RADIUS * st.mapLinearScale)
            for dID, dEnt in pairs(st.enemyDefenses) do
                local dx, dz = dEnt.x - bestBase.x, dEnt.z - bestBase.z
                local d2 = dx*dx + dz*dz
                if d2 < bestD2 then bestD2, dBest = d2, dEnt end
            end
        end
        if dBest then
            return dBest.x, spGetGroundHeight(dBest.x, dBest.z), dBest.z,
                "defense_" .. mFloor(dBest.x) .. "_" .. mFloor(dBest.z)
        end
        return bestBase.x, bestBase.y, bestBase.z, bestKey
    end

    -- retaliate toward where a hidden shooter's shells come from
    if st.suspectedThreatX and (frame - st.suspectedThreatFrame) < 600 then
        return st.suspectedThreatX, spGetGroundHeight(st.suspectedThreatX, st.suspectedThreatZ), st.suspectedThreatZ, "fire_origin"
    end

    return nil
end

function I.UpdateArmyCoordination(frame)
    local function GetAnyKnownTarget()
        return I.PickArmyTarget(frame)
    end

    if st.army.state == "attacking" then
        local tx, ty, tz, tkey = GetAnyKnownTarget()
        if tx then
            if tkey ~= st.army.targetKey then
                st.army.targetX, st.army.targetY, st.army.targetZ, st.army.targetKey = tx, ty, tz, tkey
            end
            if tkey == "prime" and st.cachedPrimeTargetID then
                local px, py, pz = spGetUnitPosition(st.cachedPrimeTargetID)
                if px then
                    st.army.targetX, st.army.targetY, st.army.targetZ = px, py, pz
                end
            end
        else
            st.army.state, st.army.stateFrame = "searching", frame
            st.army.targetX, st.army.targetY, st.army.targetZ, st.army.targetKey = nil, nil, nil, nil
        end
    elseif st.army.state == "searching" then
        local tx, ty, tz, tkey = GetAnyKnownTarget()
        if tx then
            st.army.state, st.army.targetX, st.army.targetY, st.army.targetZ, st.army.targetKey, st.army.stateFrame = "attacking", tx, ty, tz, tkey, frame
        elseif frame - st.army.stateFrame > cfg.ATTACK_SCOUT_DURATION then
            -- Cycle the state to force re-evaluation
            st.army.stateFrame = frame
            st.army.targetKey = "map_scout_" .. frame
        end
    end
end

--------------------------------------------------------------------------------
-- Scouts
--------------------------------------------------------------------------------

function I.CountActiveScouts(frame)
    local count = 0
    for key, assign in pairs(st.scoutAssignments) do
        if frame - assign.frame < cfg.SCOUT_LOCK_TTL then count = count + 1 else st.scoutAssignments[key] = nil end
    end
    return count
end

function I.AssignScoutOrder(unitID, frame)
    local ux, _, uz = spGetUnitPosition(unitID)
    if not ux then return false end
    for key, assign in pairs(st.scoutAssignments) do
        if assign.unitID == unitID or (frame - assign.frame) >= cfg.SCOUT_LOCK_TTL then st.scoutAssignments[key] = nil end
    end
    local activeScouts = I.CountActiveScouts(frame)
    if activeScouts >= st.scoutMaxActive then
        -- Scouts never fall back to guarding
        return false
    end

    local targetBase, bestScore = nil, -1

    -- prioritize bases further away that have been seen recently
    for key, base in pairs(st.enemyBases) do
        local dx = base.x - (st.baseCenterX or 0)
        local dz = base.z - (st.baseCenterZ or 0)
        local distSq = dx * dx + dz * dz
        local score = base.lastSeen * (distSq > 0 and math.sqrt(distSq) or 1)

        if score > bestScore then
            bestScore = score
            targetBase = base
        end
    end
    if not targetBase and st.cachedPrimeTargetPos then targetBase = {x = st.cachedPrimeTargetPos[1], z = st.cachedPrimeTargetPos[3]} end

    if targetBase then
        -- get close enough to spot it, with an angle offset so scouts spread around it
        local angle = mAtan2(targetBase.z - (st.baseCenterZ or 0), targetBase.x - (st.baseCenterX or 0))
        local flankAngle = angle + (math.random() > 0.5 and 0.4 or -0.4)
        local dist = math.random(400, 1000)

        local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
        local flankX = mMax(0, mMin(targetBase.x + mCos(flankAngle) * dist, mapX))
        local flankZ = mMax(0, mMin(targetBase.z + mSin(flankAngle) * dist, mapZ))
        flankX, flankZ = U.NudgeOutOfLava(flankX, flankZ, ux, uz)

        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { flankX, spGetGroundHeight(flankX, flankZ), flankZ }, {})
        st.scoutAssignments[tostring(unitID)] = { unitID = unitID, frame = frame }
        return true
    end

    -- Our enemy is probably most likely sitting in a corner
    -- if not we'll find out eventually
    local bestScore, bestKey, bestSector = -mHuge, nil, nil
    local frontierX, frontierZ = st.frontierX, st.frontierZ
    local mapCX, mapCZ = (Game.mapSizeX or 8192) * 0.5, (Game.mapSizeZ or 8192) * 0.5
    local maxCornerDist = math.sqrt(mapCX * mapCX + mapCZ * mapCZ)
    -- hard-penalise our half of the map, but we don't want to set this to 0,
    -- because someone could cheese that, but we do want to penalize our side
    -- a turtelling enemy on our side *could* end up never being found
    local homeX, homeZ = st.baseCenterX, st.baseCenterZ
    if not homeX and st.myCommanders[1] then homeX, _, homeZ = spGetUnitPosition(st.myCommanders[1]) end
    local axisX, axisZ
    if frontierX and frontierZ and homeX then
        axisX, axisZ = frontierX - homeX, frontierZ - homeZ
    elseif homeX then
        axisX, axisZ = mapCX - homeX, mapCZ - homeZ
    else
        axisX, axisZ = 0, 0
    end
    local axisLen = math.sqrt(axisX * axisX + axisZ * axisZ)
    if axisLen > 1e-6 then
        axisX, axisZ = axisX / axisLen, axisZ / axisLen
    else
        axisX, axisZ = 0, 0
    end
    for key, sector in pairs(st.scoutSectors) do
            if not st.scoutAssignments[key] then
                -- skip void/inaccessible sectors
                if not U.IsInaccessible(sector.x, sector.z) then
                    local dx, dz = sector.x - ux, sector.z - uz
                    local dist = math.sqrt(dx*dx + dz*dz) + 1
                    local staleness = frame - sector.lastScouted
                    local sdx, sdz = sector.x - mapCX, sector.z - mapCZ
                    local distFromCenter = math.sqrt(sdx*sdx + sdz*sdz)
                    -- up to 5x at the corners, linear to 1x at the center
                    local cornerBoost = 1 + mMax(0, 1 - distFromCenter / mMax(1, maxCornerDist)) * 4
                    local score = staleness * staleness * staleness * cornerBoost / (dist + 250)
                    if sdx * axisX + sdz * axisZ < 0 then
                        score = score * 0.02
                    end
                    if frontierX and frontierZ then
                        local fdx, fdz = sector.x - frontierX, sector.z - frontierZ
                        local fdist = math.sqrt(fdx*fdx + fdz*fdz)
                        score = score * (1 + mMax(0, 1 - fdist / 4000)) -- up to ~2x near the frontier
                    end
                if score > bestScore then bestScore, bestKey, bestSector = score, key, sector end
            end
        end
    end
    if bestSector then
        local tx, tz = mFloor(bestSector.x + math.random(-200, 200)), mFloor(bestSector.z + math.random(-200, 200))
        tx, tz = U.NudgeOutOfLava(tx, tz, ux, uz)
        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { tx, spGetGroundHeight(tx, tz), tz }, {})
        st.scoutAssignments[bestKey] = { unitID = unitID, frame = frame }
        return true
    end
    return false
end

return I

end
