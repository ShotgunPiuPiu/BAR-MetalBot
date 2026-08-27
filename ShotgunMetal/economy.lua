--[[
    ShotgunMetal / economy.lua
    Macro economy: resource snapshot (UpdateMacroState), strategic plan scoring,
    cheapest-def lookups, unclaimed metal spots and emergency-economy checks.
    Depends on: config, state, utils.
]]

local Spring = Spring
local Game   = Game
local math   = math
local string = string

local mFloor = math.floor
local mMax   = math.max
local mMin   = math.min
local mHuge  = math.huge

local sLower = string.lower
local sFind  = string.find

local spGetUnitPosition   = Spring.GetUnitPosition
local spGetUnitDefID      = Spring.GetUnitDefID
local spGetUnitHealth     = Spring.GetUnitHealth
local spGetUnitCommands   = Spring.GetUnitCommands
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spGetGroundHeight   = Spring.GetGroundHeight
local spGetTeamResources  = Spring.GetTeamResources
local spGetUnitSelfDTime  = Spring.GetUnitSelfDTime

return function(cfg, st, U, D)

local E = {}

--------------------------------------------------------------------------------
-- Cheapest unit-def lookups (memoized)
--------------------------------------------------------------------------------

local cheapestMexInfo = nil
function E.GetCheapestMexInfo()
    if cheapestMexInfo then return cheapestMexInfo end
    local best, bestCost = nil, mHuge
    for i = 1, #UnitDefs do
        local d = UnitDefs[i]
        if d and d.extractsMetal and d.extractsMetal > 0 and not d.isFactory then
            local cost = d.metalCost or mHuge
            if cost < bestCost then bestCost, best = cost, d end
        end
    end
    cheapestMexInfo = { def = best, cost = bestCost }
    return cheapestMexInfo
end

-- metal/s a new mex adds
function E.GetMexGain()
    local count = st.mexUnitCount or 0
    local income = st.metalIncome or 0
    if count > 0 and income > 0 then
        return income / count
    end
    local info = E.GetCheapestMexInfo()
    local em = (info.def and info.def.extractsMetal) or 0.0008
    return em * 30 * (Game.mapHardness or 100)
end

-- cheapest energy producer; BAR expresses production three ways
-- (energyMake, negative energyUpkeep, windGenerator)
local cheapestEnergyInfo = nil
function E.GetCheapestEnergyInfo()
    if cheapestEnergyInfo then return cheapestEnergyInfo end
    local best, bestCost = nil, mHuge
    for i = 1, #UnitDefs do
        local d = UnitDefs[i]
        if d and not d.isFactory then
            local makesEnergy = (d.energyMake and d.energyMake > 0)
                or (d.energyUpkeep and d.energyUpkeep < 0)
                or (d.windGenerator and d.windGenerator > 0)
            if makesEnergy then
                local cost = d.metalCost or mHuge
                if cost < bestCost then bestCost, best = cost, d end
            end
        end
    end
    local output = 0
    if best then
        if best.energyMake and best.energyMake > 0 then output = best.energyMake
        elseif best.energyUpkeep and best.energyUpkeep < 0 then output = -best.energyUpkeep
        elseif best.windGenerator and best.windGenerator > 0 then output = best.windGenerator end
    end
    cheapestEnergyInfo = { def = best, cost = bestCost, output = output }
    return cheapestEnergyInfo
end

function E.GetEnergyGain()
    local info = E.GetCheapestEnergyInfo()
    return (info.output and info.output > 0 and info.output) or 15
end

local cheapestFactoryInfo = nil
function E.GetCheapestFactoryInfo()
    if cheapestFactoryInfo then return cheapestFactoryInfo end
    local best, bestCost = nil, mHuge
    for i = 1, #UnitDefs do
        local d = UnitDefs[i]
        if d and d.isFactory then
            local cost = d.metalCost or mHuge
            if cost < bestCost then bestCost, best = cost, d end
        end
    end
    cheapestFactoryInfo = { def = best, cost = bestCost }
    return cheapestFactoryInfo
end

--------------------------------------------------------------------------------
-- Metal spots / emergency checks
--------------------------------------------------------------------------------

function E.GetNearestUnclaimedMetalSpot(ux, uz)
    local spots = st.unclaimedMetalSpots
    if not spots or #spots == 0 then
        return nil, mHuge
    end

    local claims = st.claimedMexList
    if not claims then claims = {} end

    local bestSpot, bestDistSq = nil, mHuge
    local CLAIM_RADIUS_SQ = 4096

    for i = 1, #spots do
        local spot = spots[i]
        local sx, sz = spot.x, spot.z
        local isClaimed = false

        for k = 1, #claims do
            local claim = claims[k]
            local dx = claim.x - sx
            local dx2 = dx * dx
            if dx2 < CLAIM_RADIUS_SQ then
                local dz = claim.z - sz
                local dz2 = dz * dz
                if dz2 < CLAIM_RADIUS_SQ and (dx2 + dz2) < CLAIM_RADIUS_SQ then
                    isClaimed = true
                    break
                end
            end
        end

        if not isClaimed then
            local dx = sx - ux
            local dx2 = dx * dx
            if dx2 < bestDistSq then
                local dz = sz - uz
                local dz2 = dz * dz
                if dz2 < bestDistSq then
                    local distSq = dx2 + dz2
                    if distSq < bestDistSq then
                        bestDistSq = distSq
                        bestSpot = spot
                    end
                end
            end
        end
    end

    return bestSpot, bestDistSq
end

function E.CheckEmergencyEconomy(unitID)
    local cmds = spGetUnitCommands(unitID, 1)
    if not cmds or #cmds == 0 then return false end

    local cmd = cmds[1]
    local cmdId = cmd.id

    if cmdId < 0 then
        local buildDefID = -cmdId
        local buildDef = UnitDefs[buildDefID]
        if not buildDef then return false end

        local params = cmd.params
        if not params or not params[1] or not params[3] then return false end
        local tx, tz = params[1], params[3]

        local nearbyUnits = spGetUnitsInCylinder(tx, tz, 50)
        local incUnitID = nil

        if nearbyUnits then
            for i = 1, #nearbyUnits do
                local nID = nearbyUnits[i]
                if spGetUnitDefID(nID) == buildDefID then
                    incUnitID = nID
                    break
                end
            end
        end

        if incUnitID then -- skip if already >5% built
            local hp, maxHp = spGetUnitHealth(incUnitID)
            if hp and maxHp and maxHp > 0 and (hp / maxHp) > 0.05 then
                return false
            end
        end

        local isMex = buildDef.extractsMetal and buildDef.extractsMetal > 0
        local isEnergy = false

        if buildDef.energyMake and buildDef.energyMake > 0 then
            isEnergy = true
        else
            local windGen = buildDef.windGenerator
            if windGen == true or (type(windGen) == "number" and windGen > 0) then
                isEnergy = true
            else
                local name = sLower(buildDef.name or "")
                -- plain-text search (4th arg) is much faster
                if sFind(name, "solar", 1, true) or sFind(name, "wind", 1, true)
                   or sFind(name, "fusion", 1, true) or sFind(name, "geo", 1, true) then
                    isEnergy = true
                end
            end
        end

        -- Never freeze workers over missing resources: switch ANY not-yet-
        -- started build into producing the stalled resource. Exception: the
        -- pending build itself IS the cure for the current stall (mex during
        -- a metal stall, generator during an energy stall).
        if isMex and st.metalStalling and not st.energyStalling then return false end
        if isEnergy and st.energyStalling and not st.metalStalling then return false end

        if st.energyStalling then return "energy" end
        if st.metalStalling then return "metal" end
    else
        if cmdId == cfg.CMD_RECLAIM then return false end

        if st.energyStalling then return "energy" end
        if st.metalStalling then return "metal" end
    end

    return false
end

function E.IsUnitBuildingFactory(unitID)
    local cmds = spGetUnitCommands(unitID, 1)
    if not cmds or #cmds == 0 then return false end
    local cmd = cmds[1]
    if cmd.id < 0 then
        local defID = -cmd.id
        local d = UnitDefs[defID]
        if d and d.isFactory then return true end
    end
    return false
end

function E.IsUnitBuildingUnit(unitID)
    local cmds = spGetUnitCommands(unitID, 1)
    if not cmds or #cmds == 0 then return false end
    if cmds[1].id < 0 then return true end
    return false
end

-- Count queued BUILD commands (id < 0) in a unit's whole command queue,
-- filtered by kind: "energy" (wind/solar), "mex", "factory".
function E.CountQueuedBuilds(unitID, kind)
    local cmds = spGetUnitCommands(unitID, -1)
    if not cmds then return 0 end
    local n = 0
    for i = 1, #cmds do
        local c = cmds[i]
        if c.id < 0 then
            local d = UnitDefs[-c.id]
            if d then
                local name = d.name or ""
                local isFac = d.isFactory
                if kind == "factory" and isFac then n = n + 1
                elseif kind == "mex" and (d.extractsMetal and d.extractsMetal > 0) and not isFac then n = n + 1
                elseif kind == "energy" and not isFac and not (d.extractsMetal and d.extractsMetal > 0)
                    and (sFind(name, "wind") or sFind(name, "turbine") or sFind(name, "solar") or sFind(name, "fusion") or sFind(name, "geo")) then n = n + 1
                end
            end
        end
    end
    return n
end

--------------------------------------------------------------------------------
-- Strategic plan scoring
--------------------------------------------------------------------------------

function E.ComputeStrategicPlan(frame)
    local mexInfo = E.GetCheapestMexInfo()
    local mexDef = mexInfo.def
    local mexExtract   = mexDef and mexDef.extractsMetal or 1.0
    local mexEnergyUpkeep = mexDef and mexDef.energyCost or 0

    local metalSurplus = (st.metalIncome or 0) - (st.metalPull or 0)      -- >0: earning > spending
    local energyDeficit = (st.energyPull or 0) - (st.energyIncome or 0)   -- >0: energy short

    -- How much of a new mex's metal can we actually put to use right now?
    local metalUseFactor
    if st.metalStalling then metalUseFactor = 1.5
    elseif metalSurplus < 0 then metalUseFactor = 1.0
    elseif metalSurplus > (st.metalIncome or 0) * 0.25 then metalUseFactor = 0.2
    else metalUseFactor = 0.6 end

    local n = mMax(1, st.mexUnitCount)
    local mexScore = mexExtract * (1.0 / (1.0 + 0.08 * n)) * metalUseFactor
    -- Penalize if we cannot even feed the mexes we already have
    if mexEnergyUpkeep > 0 and energyDeficit > 0 then
        mexScore = mexScore * ((st.energyIncome or 0) / mMax(1, energyDeficit + (st.energyIncome or 0)))
    end

    -- energy value
    local energyScore = 0.1
    if energyDeficit > 0 then
        energyScore = 1.0 + energyDeficit / mMax(1, st.energyIncome or 1)
    elseif st.currentEnergyStorage and st.currentEnergyStorage > 0 and st.currentEnergy < st.currentEnergyStorage * 0.35 then
        energyScore = 0.6
    end

    -- opportunity cost of inaction, a held army becomes more useless
    -- as the enemy techs up
    local ourTech = mMax(1, st.ourTech or 1)
    local enemyTech = mMax(ourTech, st.enemyTech or ourTech)
    local techPressure = mMin(6, enemyTech / ourTech)

    local armyValue = st.armyValue or 0
    local depreciation = armyValue * techPressure * cfg.ARMY_DEPRECIATION_RATE

    local tempo = 0
    for _, b in pairs(st.enemyBases) do
        if b.lastSeen then
            local bDefID = b.id and spGetUnitDefID(b.id)
            local bDef = bDefID and UnitDefs[bDefID]
            if bDef then
                tempo = tempo + (bDef.buildTime or 0)
            end
        end
    end

    local raiderThreat = (st.raiderCount or 0) * 5
    local myArmy = st.myCombatUnitCount or 0
    local armyReadiness = myArmy / mMax(cfg.ARMY_MIN_SIZE * 3, myArmy + cfg.ARMY_MIN_SIZE)
    local armyScore = (depreciation + tempo + raiderThreat) * armyReadiness
    if st.army.state == "attacking" then armyScore = armyScore * 1.5 end

    -- a real energy deficit must be fixed before any other spend (an army is
    -- worthless if its factories are stalled)
    local mode = "mex"
    if energyDeficit > (st.energyIncome or 0) * 0.5 then
        mode = "energy"
    elseif armyScore >= mexScore and armyScore >= energyScore and armyScore >= 1.0 then
        mode = "army"
    elseif energyScore >= mexScore and energyScore >= 0.6 then
        mode = "energy"
    end

    st.plan.frame = frame
    st.plan.mode = mode
    st.plan.mexScore = mexScore
    st.plan.energyScore = energyScore
    st.plan.armyScore = armyScore
    st.plan.metalSurplus = metalSurplus
    st.plan.energyDeficit = energyDeficit
end

-- stalling = demand exceeds production and the bank is nearly empty
function E.IsResourceStalling(cur, pull, income)
    if (pull or 0) <= (income or 0) then return false end
    return (cur or 0) < mMax(50, (income or 0) * 2)
end

--------------------------------------------------------------------------------
-- Macro state snapshot
--------------------------------------------------------------------------------

function E.UpdateMacroState(myTeam, units)
    st.pendingCommittedMetal = 0

    if WG and WG['resource_spot_finder'] then
        st.metalSpots = WG['resource_spot_finder'].metalSpotsList or {}
    else
        st.metalSpots = {}
    end

    st.unclaimedMetalSpots = {}
    st.unclaimedMexCount = 0
    -- The occupancy scan is the most expensive part so only refresh it every other pass
    if st.frameNum % (cfg.CHECK_INTERVAL * 2) == 0 then
        if st.metalSpots and #st.metalSpots > 0 then
            for i = 1, #st.metalSpots do
                local spot = st.metalSpots[i]
                local isOccupied = false
                if spot.x and spot.z then
                    local nearby = spGetUnitsInCylinder(spot.x, spot.z, 80, myTeam)
                    if nearby then
                        for j = 1, #nearby do
                            local nDefID = spGetUnitDefID(nearby[j])
                            local nDef = nDefID and UnitDefs[nDefID]
                            if nDef and nDef.extractsMetal and nDef.extractsMetal > 0 then
                                isOccupied = true break
                            end
                        end
                    end
                end
                if not isOccupied then
                    st.unclaimedMexCount = st.unclaimedMexCount + 1
                    st.unclaimedMetalSpots[#st.unclaimedMetalSpots + 1] = {x = spot.x, z = spot.z}
                end
            end
        end
    end

    local okM, mCur, mStorage, mPull, mIncome = pcall(spGetTeamResources, myTeam, "metal")
    if okM then
        st.metalStalling = E.IsResourceStalling(mCur, mPull, mIncome)
    else mCur, mStorage, mPull, mIncome = 0, 0, 0, 0 st.metalStalling = true end
    st.metalIncome, st.metalPull, st.currentMetal, st.currentMetalStorage = mIncome or 0, mPull or 0, mCur or 0, mStorage or 0

    local okE, eCur, eStorage, ePull, eIncome = pcall(spGetTeamResources, myTeam, "energy")
    if okE then
        st.energyStalling = E.IsResourceStalling(eCur, ePull, eIncome)
    else eCur, eStorage, ePull, eIncome = 0, 0, 0, 0 st.energyStalling = true end
    st.energyIncome, st.energyPull, st.currentEnergy, st.currentEnergyStorage = eIncome or 0, ePull or 0, eCur or 0, eStorage or 0

    local growthFactor = st.metalPull > 0 and (st.metalIncome / st.metalPull) or 2.0
    st.economySaturated = (not st.metalStalling) and (not st.energyStalling) and st.currentMetalStorage > 0
        and (st.currentMetal / st.currentMetalStorage) > cfg.ECONOMY_SATURATION_RATIO and growthFactor > cfg.ECONOMY_INCOME_SLACK

    st.myFactories, st.factoryGuards, st.factoryTurrets = {}, {}, {}
    st.incompleteFactories, st.factoriesNeedingTurrets = {}, {}
    st.myCommanders = {}
    st.myCommanderCount = 0
    st.baseCenterX, st.baseCenterY, st.baseCenterZ, st.baseRadius, st.baseStructureCount = nil, nil, nil, 0, 0
    st.conUnitCount, st.mexUnitCount, st.combatUnitCount = 0, 0, 0
    st.advConCount = 0
    st.scoutUnitCount = 0
    st.supportGuardOwners.radar = {}
    st.supportGuardOwners.jammer = {}
    st.supportGuardOwners.aa = {}
    st.myCombatUnits, st.myCombatUnitCount = {}, 0
    st.activeMexBuilders, st.activeEnergyBuilders = 0, 0
    st.ourTech, st.armyValue = 0, 0
    st.myFactoriesCount, st.incompleteFactoryCount, st.factoriesNeedingTurretsCount = 0, 0, 0
    st.myAntinukes, st.antinukeCount = {}, 0
    st.defenseCount = 0
    st.defenseGroundCount = 0
    st.defenseAACount = 0
    st.selfDingUnits, st.selfDingCount = {}, 0
    st.turretDbg.consWithTurret = 0

    st.pendingFactoryBlueprints = 0
    st.pendingAntinukeBlueprints = 0
    st.claimedMexList = {}
    for _, claim in pairs(st.claimedSpots) do
        if claim.isFactory and (st.frameNum - claim.frame) < 900 then
            st.pendingFactoryBlueprints = st.pendingFactoryBlueprints + 1
        elseif claim.isAntinuke and (st.frameNum - claim.frame) < 900 then
            st.pendingAntinukeBlueprints = st.pendingAntinukeBlueprints + 1
        elseif claim.isMex then
            st.claimedMexList[#st.claimedMexList + 1] = claim
        end
    end

    st.lazCount, st.jammerCount, st.radarCount = 0, 0, 0
    st.radarTowerCount = 0
    st.ecoEnergyCount = 0
    st.scoutMaxActive = mMax(2, mMin(5, st.myFactoriesCount * cfg.SCOUTS_PER_FACTORY))

    local structPos, structCnt, sumSX, sumSZ = {}, 0, 0, 0

    -- prune conTurretHomes entries whose turret/build order no longer exists
    local seenHomeKeys = {}

    for i = 1, #units do
        local uID = units[i]
        local d = UnitDefs[spGetUnitDefID(uID)]
        if d then
            local isCmd = d.customParams and (d.customParams.iscommander ~= nil or d.customParams.is_commander ~= nil)
            if isCmd or (d.name and sFind(sLower(d.name), "commander")) then
                st.myCommanderCount = st.myCommanderCount + 1
                st.myCommanders[st.myCommanderCount] = uID
            end

            if d.isFactory then
                st.myFactoriesCount = st.myFactoriesCount + 1
                st.myFactories[st.myFactoriesCount] = uID
                st.factoryGuards[uID] = 0
                st.factoryTurrets[uID] = 0

                local hp, maxHp = spGetUnitHealth(uID)
                if hp and maxHp and hp < maxHp then
                    st.incompleteFactoryCount = st.incompleteFactoryCount + 1
                    st.incompleteFactories[st.incompleteFactoryCount] = uID
                end
            end

            if U.IsAntiNukeDef(spGetUnitDefID(uID)) then
                st.antinukeCount = st.antinukeCount + 1
                st.myAntinukes[st.antinukeCount] = uID
            end

            if U.IsDefenseDef(spGetUnitDefID(uID)) then
                st.defenseCount = st.defenseCount + 1
                if U.IsAAOnlyDef(spGetUnitDefID(uID)) then st.defenseAACount = st.defenseAACount + 1
                else st.defenseGroundCount = st.defenseGroundCount + 1 end
            end

            -- Track units mid self-destruct so allies can flee the blast.
            if d.speed and d.speed > 0 and spGetUnitSelfDTime(uID) > 0 then
                local sx, _, sz = spGetUnitPosition(uID)
                if sx then
                    st.selfDingCount = st.selfDingCount + 1
                    st.selfDingUnits[st.selfDingCount] = { id = uID, x = sx, z = sz, blastRadius = U.GetSelfDBlastRadius(spGetUnitDefID(uID)) }
                end
            end

            if not d.speed or d.speed == 0 then
                local sx, _, sz = spGetUnitPosition(uID)
                if sx then
                    structCnt = structCnt + 1
                    structPos[structCnt] = { sx, sz }
                    sumSX, sumSZ = sumSX + sx, sumSZ + sz
                end
            end
        end
    end

    if structCnt > 0 then
        local cx, cz = sumSX / structCnt, sumSZ / structCnt
        local maxDistSq = 0
        for i = 1, structCnt do
            local dx, dz = structPos[i][1] - cx, structPos[i][2] - cz
            if dx*dx + dz*dz > maxDistSq then maxDistSq = dx*dx + dz*dz end
        end
        st.baseCenterX, st.baseCenterY, st.baseCenterZ, st.baseRadius, st.baseStructureCount = cx, spGetGroundHeight(cx, cz), cz, math.sqrt(maxDistSq), structCnt
    end

    for i = 1, #units do
        local uID = units[i]
        local d = UnitDefs[spGetUnitDefID(uID)]
        if d and not d.isFactory then
            if d.isBuilder and d.speed and d.speed > 0 then
                local cN = d.name and sLower(d.name) or ""
                local isCmdDef = (d.customParams and (d.customParams.iscommander ~= nil or d.customParams.is_commander ~= nil)) or (sFind(cN, "commander") and true or false)
                local isLazDef = d.canResurrect or sFind(cN, "lazarus") or sFind(cN, "graverobber") or sFind(cN, "zagreus")
                local isTrapperDef = U.IsTrapper(d)
                if not isCmdDef and not isLazDef and not isTrapperDef then
                    st.conUnitCount = st.conUnitCount + 1
                    if (d.metalCost or 0) >= 250 then st.advConCount = st.advConCount + 1 end
                    -- Diagnostics: how many fielded cons can build a con turret.
                    local bc = st.buildCache[spGetUnitDefID(uID)]
                    if bc and bc.conTurrets and #bc.conTurrets > 0 then
                        st.turretDbg.consWithTurret = st.turretDbg.consWithTurret + 1
                    end
                end
                local cmds = spGetUnitCommands(uID, 10)
                local countedEco = false
                if cmds then
                    for c = 1, #cmds do
                        local cmdId = cmds[c].id
                        if cmdId == cfg.CMD_GUARD then
                            local target = cmds[c].params[1]
                            if target and st.factoryGuards[target] ~= nil then st.factoryGuards[target] = st.factoryGuards[target] + 1 end
                        elseif cmdId < 0 then
                            local bDef = UnitDefs[-cmdId]
                            if bDef then
                                if not countedEco then
                                    if bDef.extractsMetal and bDef.extractsMetal > 0 then st.activeMexBuilders = st.activeMexBuilders + 1 countedEco = true
                                    elseif (bDef.energyMake and bDef.energyMake > 0) or sFind(sLower(bDef.name or ""), "wind") or sFind(sLower(bDef.name or ""), "solar") or sFind(sLower(bDef.name or ""), "fusion") or sFind(sLower(bDef.name or ""), "geo") then
                                        st.activeEnergyBuilders = st.activeEnergyBuilders + 1 countedEco = true
                                    end
                                end
                                if bDef.isBuilder and (not bDef.speed or bDef.speed == 0) then
                                    local tx, tz = cmds[c].params[1], cmds[c].params[3]
                                    if tx and tz then
                                        local hk = mFloor(tx) .. "_" .. mFloor(tz)
                                        local homeF = st.conTurretHomes[hk]
                                        if homeF then
                                            seenHomeKeys[hk] = true
                                            st.factoryTurrets[homeF] = (st.factoryTurrets[homeF] or 0) + 1
                                        else
                                            local bestF, bestDist = nil, cfg.TURRET_SEARCH_RADIUS * cfg.TURRET_SEARCH_RADIUS
                                            for j = 1, st.myFactoriesCount do
                                                local fID = st.myFactories[j]
                                                local fx, _, fz = spGetUnitPosition(fID)
                                                if fx then
                                                    local dx, dz = fx - tx, fz - tz
                                                    if dx*dx + dz*dz < bestDist then bestDist, bestF = dx*dx + dz*dz, fID end
                                                end
                                            end
                                            if bestF then st.factoryTurrets[bestF] = (st.factoryTurrets[bestF] or 0) + 1 end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            elseif d.isBuilder and (not d.speed or d.speed == 0) then
                local tx, _, tz = spGetUnitPosition(uID)
                if tx then
                    local hk = mFloor(tx) .. "_" .. mFloor(tz)                    local homeF = st.conTurretHomes[hk]
                    if homeF then
                        seenHomeKeys[hk] = true
                        st.factoryTurrets[homeF] = (st.factoryTurrets[homeF] or 0) + 1
                    else
                        local bestF, bestDist = nil, cfg.TURRET_SEARCH_RADIUS * cfg.TURRET_SEARCH_RADIUS
                        for j = 1, st.myFactoriesCount do
                            local fID = st.myFactories[j]
                            local fx, _, fz = spGetUnitPosition(fID)
                            if fx then
                                local dx, dz = fx - tx, fz - tz
                                if dx*dx + dz*dz < bestDist then bestDist, bestF = dx*dx + dz*dz, fID end
                            end
                        end
                        if bestF then st.factoryTurrets[bestF] = (st.factoryTurrets[bestF] or 0) + 1 end
                    end
                end
            else
                local name = sLower(d.name or "")
                if sFind(name, "win") then Spring.Echo(string.format("[ELSE-WIN] f=%d name=%s isB=%s speed=%s em=%s", st.frameNum, name, tostring(d.isBuilder), tostring(d.speed), tostring(d.energyMake))) end
                local isLaz = d.canResurrect or sFind(name, "lazarus") or sFind(name, "graverobber") or sFind(name, "zagreus")
                local isJammer = (d.radarDistanceJam and d.radarDistanceJam > 0) or sFind(name, "jammer") or sFind(name, "jam")
                local isRadar = (d.radarDistance and d.radarDistance > 500 and not (d.weapons and #d.weapons > 0)) or sFind(name, "radar")

                if d.extractsMetal and d.extractsMetal > 0 then st.mexUnitCount = st.mexUnitCount + 1
                elseif (d.energyMake and d.energyMake > 0) and not (d.energyUse and d.energyUse > d.energyMake) then
                    st.ecoEnergyCount = st.ecoEnergyCount + 1
                    Spring.Echo(string.format("[ECO+1] f=%d name=%s em=%s eco=%d", st.frameNum, name, tostring(d.energyMake), st.ecoEnergyCount))
                elseif isLaz then st.lazCount = st.lazCount + 1
                elseif isJammer then
                    st.jammerCount = st.jammerCount + 1
                    if d.speed and d.speed > 0 and not d.isBuilder then
                        local tg = st.supportTarget[uID]
                        if tg and spGetUnitDefID(tg) then st.supportGuardOwners.jammer[tg] = uID end
                    end
                elseif isRadar and d.speed and d.speed > 0 then
                    st.radarCount = st.radarCount + 1
                    if not d.isBuilder then
                        local tg = st.supportTarget[uID]
                        if tg and spGetUnitDefID(tg) then st.supportGuardOwners.radar[tg] = uID end
                    end
                elseif isRadar then
                    st.radarTowerCount = st.radarTowerCount + 1
                elseif (d.customParams and d.customParams.unitgroup == "aa") and d.speed and d.speed > 0 and not d.isBuilder then
                    -- mobile AA is support, not combat, so keep it out of
                    -- myCombatUnits so that it can't end up guarding another AA
                    local tg = st.supportTarget[uID]
                    if tg and spGetUnitDefID(tg) then st.supportGuardOwners.aa[tg] = uID end
                elseif U.IsScoutDef(d) then st.scoutUnitCount = st.scoutUnitCount + 1
                elseif not d.isBuilder and (d.speed and d.speed > 0) and (d.weapons and #d.weapons > 0) and not U.IsAntiNukeDef(spGetUnitDefID(uID)) then
                    st.combatUnitCount = st.combatUnitCount + 1
                    st.myCombatUnitCount = st.myCombatUnitCount + 1
                    st.myCombatUnits[st.myCombatUnitCount] = uID
                    local uCost = d.metalCost or 0
                    st.armyValue = st.armyValue + uCost
                    if uCost > st.ourTech then st.ourTech = uCost end
                end
            end
        end
    end

    if st.frameNum % 30 == 0 then
        Spring.Echo(string.format("[SCAN] f=%d units=%d cons=%d mex=%d eco=%d fac=%d", st.frameNum, #(units or {}), st.conUnitCount or 0, st.mexUnitCount or 0, st.ecoEnergyCount or 0, st.myFactoriesCount or 0))
        local names = {}
        for i = 1, #(units or {}) do
            local du = UnitDefs[spGetUnitDefID(units[i])]
            if du then names[#names + 1] = (du.name or "?") .. (du.isBuilder and "[]" or "") end
        end
        Spring.Echo("    [SCAN-UNIT] " .. table.concat(names, " "))
    end

    for hk in pairs(st.conTurretHomes) do
        if not seenHomeKeys[hk] then st.conTurretHomes[hk] = nil end
    end

    for j = 1, st.myFactoriesCount do
        local fID = st.myFactories[j]
        local hp, maxHp = spGetUnitHealth(fID)
        -- ring the lab from 50% construction up
        if hp and maxHp and hp >= maxHp * 0.5 and (st.factoryTurrets[fID] or 0) < (U.FactoryTurretInfo(spGetUnitDefID(fID))) then
            st.factoriesNeedingTurretsCount = st.factoriesNeedingTurretsCount + 1
            st.factoriesNeedingTurrets[st.factoriesNeedingTurretsCount] = fID
        end
    end
    st.turretDbg.needTurrets = st.factoriesNeedingTurretsCount
end

return E

end
