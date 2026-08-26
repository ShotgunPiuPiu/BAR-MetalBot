--[[
    ShotgunMetal / orders.lua
    Per-unit order processing (ProcessUnitOrders): factories, builders,
    combat units, support units and scouts. Extracted verbatim from the
    original monolithic widget; cross-module helpers arrive via D.
    Depends on: config, state, utils, build/economy/intel/military (via D).
]]

local Spring = Spring
local Game   = Game
local math   = math
local string = string
local table  = table

local mFloor = math.floor
local mCeil  = math.ceil
local mMax   = math.max
local mMin   = math.min
local mHuge  = math.huge
local mAbs   = math.abs
local mSqrt  = math.sqrt
local mAtan2 = math.atan2
local mCos   = math.cos
local mSin   = math.sin

local sLower  = string.lower
local sFind   = string.find
local sFormat = string.format

local tInsert = table.insert

local spAreTeamsAllied = Spring.AreTeamsAllied
local spGetFactoryCommands = Spring.GetFactoryCommands
local spGetGaiaTeamID = Spring.GetGaiaTeamID
local spGetGroundHeight = Spring.GetGroundHeight
local spGetMyAllyTeamID = Spring.GetMyAllyTeamID
local spGetMyTeamID = Spring.GetMyTeamID
local spGetUnitCommands = Spring.GetUnitCommands
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitHealth = Spring.GetUnitHealth
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitTeam = Spring.GetUnitTeam
local spGetUnitVelocity = Spring.GetUnitVelocity
local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
local spGiveOrderToUnit = Spring.GiveOrderToUnit

return function(cfg, st, U, D)

local B = D.build
local E = D.economy
local W = D.military
local I = D.intel

local O = {}

-- Trapper mine targets live for the widget's lifetime; sharing the table
-- through st lets widget:UnitDestroyed clean entries up.
local trapperTargets = st.trapperTargets or {}
st.trapperTargets = trapperTargets

local function IsGuardingValidTarget(unitID, maxRange)
    local currentCmds = spGetUnitCommands(unitID, 1)
    if currentCmds and #currentCmds > 0 and currentCmds[1].id == cfg.CMD_GUARD then
        local target = currentCmds[1].params[1]
        if target and spGetUnitDefID(target) then
            -- A finished lab that's waited assists nothing, so guarding
            -- it is useless. One still under construction is worth helping.
            if st.factoryWaitState[target] then
                local thp, tmax = spGetUnitHealth(target)
                if thp and tmax and thp >= tmax then return false end
            end
            if maxRange then
                local ux, _, uz = spGetUnitPosition(unitID)
                local tx, _, tz = spGetUnitPosition(target)
                if ux and tx then
                    local dx, dz = tx - ux, tz - uz
                    if dx*dx + dz*dz > maxRange * maxRange then
                        return false
                    end
                end
            end
            return true
        end
    end
    return false
end

local function NeedsOrders(unitID, isFactory, isAttacker, isGraverobber)
    if isFactory then
        if spGetFactoryCommands then
            local factoryCmds = spGetFactoryCommands(unitID, 1)
            return not (factoryCmds and #factoryCmds > 0)
        end
        local currentCmds = spGetUnitCommands(unitID, 1)
        return not (currentCmds and #currentCmds > 0)
    end

    local cmds = spGetUnitCommands(unitID, 1)
    if not cmds or #cmds == 0 then return true end

    local cmd = cmds[1]
    local cmdId = cmd.id
    local params = cmd.params

    if cmdId == cfg.CMD_REPAIR then
        local target = params and params[1]
        if not target then return true end
        local hp, maxHp = spGetUnitHealth(target)
        if hp and maxHp and hp >= maxHp then return true end
    end

    if cmdId == cfg.CMD_RECLAIM or cmdId == cfg.CMD_PATROL or cmdId == cfg.CMD_RESURRECT then
        if not isAttacker then
            local mShort = mMax(0, (st.metalPull or 0) - (st.metalIncome or 0))
            local eShort = mMax(0, (st.energyPull or 0) - (st.energyIncome or 0))
            if mShort >= (st.metalIncome or 0) * cfg.STALL_PULL_METAL_RATIO or eShort >= (st.energyIncome or 0) * cfg.STALL_PULL_ENERGY_RATIO then return true end
        end
        
        -- GRAVEROBBERS ARE BROKEN TODO: This
        if isGraverobber then
            local cmdCount = st.myCommanderCount
            for i = 1, cmdCount do
                local cID = st.myCommanders[i]
                local chp, cmax = spGetUnitHealth(cID)
                if chp and cmax and chp < cmax then return true end
            end
            
            local armyState = st.army.state
            if (armyState == "attacking" or armyState == "searching") and st.myCombatUnitCount > 0 and st.army.targetX then
                local ux2, _, uz2 = spGetUnitPosition(unitID)
                if ux2 then
                    local dx, dz = st.army.targetX - ux2, st.army.targetZ - uz2
                    if dx*dx + dz*dz > 2250000 then return true end
                end
            end
        end
    end




    if cmdId == cfg.CMD_GUARD then
        local target = params and params[1]
        if not target or not spGetUnitDefID(target) then return true end

        if st.factoryWaitState[target] then
            local thp, tmax = spGetUnitHealth(target)
            if thp and tmax and thp >= tmax then return true end
        end

        if st.metalStalling or st.energyStalling then
            local mShort = mMax(0, (st.metalPull or 0) - (st.metalIncome or 0))
            local eShort = mMax(0, (st.energyPull or 0) - (st.energyIncome or 0))
            if (mShort >= (st.metalIncome or 0) * cfg.STALL_PULL_METAL_RATIO or eShort >= (st.energyIncome or 0) * cfg.STALL_PULL_ENERGY_RATIO) and math.random() < 0.25 then
                return true
            end
            return false
        end
        
        if st.incompleteFactoryCount > 0 and math.random() < 0.1 then return true end
        
        if isAttacker then
            if st.raiderCount > 0 then return true end
            if next(st.enemyBases) ~= nil then return true end 
            if math.random() < 0.05 then return true end
        else
            if math.random() < 0.01 then return true end
        end
        
        local armyState = st.army.state
        -- GRAVEROBBERS ARE BROKEN TODO: This
        if isGraverobber and (armyState == "attacking" or armyState == "searching") and st.myCombatUnitCount > 0 then return true end
        
        return false
    end

    if isAttacker then
        local CMD_ATTACK = cfg.CMD_ATTACK
        local CMD_MOVE = cfg.CMD_MOVE
        local CMD_GUARD = cfg.CMD_GUARD
        local CMD_PATROL = cfg.CMD_PATROL

        return (cmdId ~= CMD_ATTACK and cmdId ~= CMD_MOVE and cmdId ~= CMD_GUARD and cmdId ~= CMD_PATROL)
    end

    return false
end

local function ProcessUnitOrders(unitID, frame)
    -- Lua 5.1 caps us to 60 upvalues :(
    -- So we have to redeclare them here
    local spGetUnitDefID       = Spring.GetUnitDefID
    local spGetUnitCommands    = Spring.GetUnitCommands
    local spGiveOrderToUnit    = Spring.GiveOrderToUnit
    local spGetFactoryCommands = Spring.GetFactoryCommands
    local spGetUnitPosition    = Spring.GetUnitPosition
    local spGetGroundHeight    = Spring.GetGroundHeight
    local spGetMyTeamID        = Spring.GetMyTeamID
    local spGetUnitHealth      = Spring.GetUnitHealth
    local spGetUnitsInCylinder = Spring.GetUnitsInCylinder
    local spGetUnitTeam        = Spring.GetUnitTeam
    local spAreTeamsAllied     = Spring.AreTeamsAllied
    local spGetGaiaTeamID      = Spring.GetGaiaTeamID
    local spGetUnitVelocity    = Spring.GetUnitVelocity
    local mMax  = math.max
    local mMin  = math.min
    local mHuge = math.huge
    local mCos  = math.cos
    local mSin  = math.sin
    local mAbs  = math.abs
    local CMD_STOP       = cfg.CMD_STOP
    local CMD_WAIT       = cfg.CMD_WAIT
    local CMD_CLOAK      = cfg.CMD_CLOAK
    local CMD_DGUN       = cfg.CMD_DGUN
    local CMD_RESURRECT  = cfg.CMD_RESURRECT
    local CMD_FIRE_STATE = cfg.CMD_FIRE_STATE
    local CMD_MOVE_STATE = cfg.CMD_MOVE_STATE

    local uDefID = spGetUnitDefID(unitID)
    local uDef = uDefID and UnitDefs[uDefID]
    if not uDef then return end

    local name = uDef.name and sLower(uDef.name) or ""

    local puCmd = spGetUnitCommands(unitID, 1)
    local puC = puCmd and puCmd[1]
    if puC and puC.id == cfg.CMD_ATTACK and not uDef.canFly then
        spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
        if st.attackDbg then
            st.attackDbg.groundCleared = st.attackDbg.groundCleared + 1
            st.attackDbg.lastGroundDef = uDef.name
        end
    end
    
    local hasWind = (Game.windMax or 0) > 0 -- windless maps fall back to solar

    local isTrapperUnit = cfg.IsTrapper(uDef)

    if uDef.isFactory then
        -- Non-stop production: only pause labs on an ENERGY stall (nothing
        -- runs without power); brief metal stalls must NOT idle factories.
        local isStalling = st.energyStalling
        -- we need cons to get out of a stall
        -- let's not make any if we have a healthy amount and we're stalling
        local wantConRecovery = isStalling and (
            st.conUnitCount < 2
            or (st.metalStalling and st.unclaimedMexCount > 0 and st.conUnitCount < 8)
            or (st.energyStalling and st.conUnitCount < 4)
        )
        if isStalling and not wantConRecovery then
            if not st.factoryWaitState[unitID] then
                spGiveOrderToUnit(unitID, CMD_WAIT, {}, {})
                st.factoryWaitState[unitID] = true
            end
            return
        end
        if st.factoryWaitState[unitID] then
            spGiveOrderToUnit(unitID, CMD_WAIT, {}, {})
            st.factoryWaitState[unitID] = nil
        end

        if spGetFactoryCommands then
            local factoryCmds = spGetFactoryCommands(unitID, -1)
            if factoryCmds and #factoryCmds > 0 then return end
        else
            local currentCmds = spGetUnitCommands(unitID, -1)
            if currentCmds and #currentCmds > 0 then return end
        end

        if (frame - (st.lastFactoryOrderFrame[unitID] or -30)) < 30 then return end

        if NeedsOrders(unitID, true, false, false) then
            local cache = B.GetBuildCache(uDefID)
            local choice = nil
            local realConBots = mMax(0, st.conUnitCount)
            -- opening rule: the first factory works through constructors first;
            -- combat/scout units unlock once we have MIN_CONS_BEFORE_UNITS
            local unitsAllowed = realConBots >= cfg.MIN_CONS_BEFORE_UNITS
                or ((st.combatUnitCount or 0) + (st.scoutUnitCount or 0)) > 0
                or frame >= (cfg.UNIT_RUSH_FRAME / mMax(0.25, cfg.AGGRESSION or 1))
            local heavyUnlocked = (st.combatUnitCount or 0) >= cfg.HEAVY_UNLOCK_ARMY_SIZE
            -- master aggression knob: scales how hard factories flood units
            local agg = mMax(0.25, cfg.AGGRESSION or 1)

            -- while stalled the only unit worth queuing is a constructor
            if isStalling and #cache.cons > 0 then
                local conID = B.PickPreferAir(cache.cons, false)
                if conID then
                    spGiveOrderToUnit(unitID, -conID, {}, {})
                    st.conUnitCount = st.conUnitCount + 1
                    st.lastFactoryOrderFrame[unitID] = frame
                    return
                end
            end

            -- cap defenders so the factory doesn't only make fighters
            local targetDefenders = 4
            if st.raiderCount > 0 then targetDefenders = mMin(10, mMax(6, st.raiderCount * 2)) end

            -- get our scouts out fast, until we can find a better way to recognize enemy bases
            -- that doesn't force us to make a scout ASAP
            -- TODO: This
            if not choice and st.scoutUnitCount == 0 and #cache.scouts > 0 then
                local cheapestScout, cheapestCost = nil, mHuge
                for i = 1, #cache.scouts do
                    local sID = cache.scouts[i]
                    local sCost = UnitDefs[sID] and UnitDefs[sID].metalCost or 0
                    if B.CanAffordBuild(sID, true) and sCost < cheapestCost then
                        cheapestCost, cheapestScout = sCost, sID
                    end
                end
                if cheapestScout then
                    choice = cheapestScout
                    st.scoutUnitCount = st.scoutUnitCount + 1
                end
            end

            if not choice and st.combatUnitCount < targetDefenders then
                local cheapestDef = B.GetCheapestMobileDefense(cache)
                if cheapestDef and B.CanAffordBuild(cheapestDef, true) then
                    choice = cheapestDef
                    st.combatUnitCount = st.combatUnitCount + 1
                end
            end

            local dynamicLazLimit = math.floor(st.combatUnitCount / 80) + math.floor(st.metalIncome / 400)
            local dynamicRadarLimit = st.myFactoriesCount + math.floor(st.baseRadius / 600)

            local totalActiveProjects = st.incompleteFactoryCount + st.pendingFactoryBlueprints + st.unclaimedMexCount
            local maxCons = st.myFactoriesCount * cfg.CONS_PER_FACTORY + cfg.CONS_BASE
            local needMoreCons = false
            
            if realConBots < maxCons then
                if realConBots == 0 then needMoreCons = true
                elseif st.metalStalling and st.unclaimedMexCount > 0 and realConBots < (st.unclaimedMexCount + 1) then needMoreCons = true
                elseif st.energyStalling and realConBots < 3 then needMoreCons = true
                elseif totalActiveProjects > 0 and realConBots < (totalActiveProjects * 2) then needMoreCons = true
                elseif st.economySaturated then needMoreCons = true end
            end

            -- we need t2 cons, we don't care about if we have a bunch of t1 cons
            local advancedConID = nil
            for i = 1, #cache.cons do
                local cDef = UnitDefs[cache.cons[i]]
                if cDef and (cDef.metalCost or 0) >= 250 then advancedConID = cache.cons[i] break end
            end
            local needAdvancedCon = (advancedConID ~= nil)
                and (st.advConCount or 0) < cfg.ADV_CON_MAX
                and (st.metalIncome or 0) >= 15
                and not st.metalStalling

            -- Unit rush: opening forces a few constructors, then factories
            -- flood combat units. Cons only trickle in afterwards to reach
            -- the post-opening crew target (and during metal crises).
            local conTarget = mMax(cfg.MIN_CONS_BEFORE_UNITS, math.floor((st.myFactoriesCount * cfg.CONS_PER_FACTORY_POST + cfg.CONS_BASE_POST) / agg))
            local wantCons = false
            if realConBots < cfg.MIN_CONS_BEFORE_UNITS then wantCons = true
            elseif st.metalStalling and (st.unclaimedMexCount or 0) > 0 and realConBots < conTarget then wantCons = math.random() < mMin(1, 0.3 / agg)
            elseif realConBots < conTarget then wantCons = math.random() < mMin(1, cfg.CONS_ORDER_CHANCE / agg)
            else wantCons = math.random() < mMin(1, 0.05 / agg) end

            if not choice and (wantCons or needAdvancedCon) and #cache.cons > 0 then
                local useAdvanced = false
                if #cache.cons > 1 and st.metalIncome > 15 and realConBots >= 4 and not st.metalStalling and math.random() < 0.5 then
                    useAdvanced = true
                end
                
                if needAdvancedCon and advancedConID then
                    choice = advancedConID
                elseif useAdvanced then
                    choice = cache.cons[#cache.cons]
                else
                    choice = B.PickPreferAir(cache.cons, false)
                end
                if choice then
                    st.conUnitCount = st.conUnitCount + 1
                    local cDef = UnitDefs[choice]
                    if cDef and (cDef.metalCost or 0) >= 250 then st.advConCount = st.advConCount + 1 end
                end
            end

            if not choice and unitsAllowed and #cache.scouts > 0 then
                local targetScouts = mMin(4, mMax(2, cfg.SCOUTS_PER_FACTORY * st.myFactoriesCount))
                if st.scoutUnitCount < targetScouts then
                    local cheapestScout, cheapestCost = nil, mHuge
                    for i = 1, #cache.scouts do
                        local sID = cache.scouts[i]
                        local sCost = UnitDefs[sID] and UnitDefs[sID].metalCost or 0
                        if B.CanAffordBuild(sID, true) and sCost < cheapestCost then
                            cheapestCost, cheapestScout = sCost, sID
                        end
                    end
                    if cheapestScout then
                        choice = cheapestScout
                        st.scoutUnitCount = st.scoutUnitCount + 1
                    end
                end
            end

            if not choice and realConBots >= 3 then
                if heavyUnlocked and #cache.jammers > 0 and not st.metalStalling and not st.energyStalling and math.random() < mMin(1, 0.05 / agg) then
                    choice = cache.jammers[1] st.jammerCount = st.jammerCount + 1
                elseif st.radarCount < dynamicRadarLimit and #cache.radars > 0 and not st.metalStalling and not st.energyStalling then
                    choice = cache.radars[1] st.radarCount = st.radarCount + 1
                elseif heavyUnlocked and st.combatUnitCount >= 15 and st.lazCount < dynamicLazLimit and #cache.laz > 0 and math.random() < mMin(1, 0.08 / agg) then
                    choice = cache.laz[1] st.lazCount = st.lazCount + 1
                elseif heavyUnlocked and #cache.trappers > 0 and st.combatUnitCount > 20 and math.random() < mMin(1, 0.05 / agg) then
                    choice = cache.trappers[1]
                end
            end

            if not choice and unitsAllowed and (#cache.mobile > 0 or #cache.artillery > 0) then
                local affordable = {}
                if not heavyUnlocked then
                    -- mass-production mode: only cheap line units, no expensive
                    -- support units (Tremor class) until the army is big enough
                    for i = 1, #cache.mobile do
                        local mID = cache.mobile[i]
                        if cfg.CanAffordCombatUnit(mID) then
                            tInsert(affordable, mID)
                        end
                    end
                else
                    -- artillery bias
                    if st.combatUnitCount < 10 and #cache.artillery > 0 and math.random() < 0.3 then
                        for i = 1, #cache.artillery do
                            local mID = cache.artillery[i]
                            if cfg.CanAffordCombatUnit(mID) then
                                tInsert(affordable, mID)
                            end
                        end
                    end

                    if #affordable == 0 then
                        local pool = cache.mobile
                        if #cache.artillery > 0 then
                            pool = {}
                            for i = 1, #cache.mobile do pool[#pool + 1] = cache.mobile[i] end
                            for i = 1, #cache.artillery do pool[#pool + 1] = cache.artillery[i] end
                        end
                        for i = 1, #pool do
                            local mID = pool[i]
                            if cfg.CanAffordCombatUnit(mID) then
                                tInsert(affordable, mID)
                            end
                        end
                    end
                end

                if #affordable > 0 then
                    -- T3 gating: keep production on T2 until a large T2 army
                    -- is established. Even once T3 is allowed, bias heavily
                    -- against it to keep the T2 flood going.
                    local t3Min = cfg.T3_MIN_ARMY or 0
                    local t3Allowed = (st.combatUnitCount or 0) >= t3Min
                    local filtered = {}
                    for i = 1, #affordable do
                        local ad = UnitDefs[affordable[i]]
                        local isT3 = ad and (ad.techLevel or 0) >= 3
                        if not isT3 or t3Allowed then filtered[#filtered + 1] = affordable[i] end
                    end
                    if #filtered > 0 then affordable = filtered end
                    if t3Allowed and #affordable > 0 and math.random() < (cfg.T3_SKIP_CHANCE or 0) then
                        local without = {}
                        for i = 1, #affordable do
                            local ad = UnitDefs[affordable[i]]
                            if not (ad and (ad.techLevel or 0) >= 3) then without[#without + 1] = affordable[i] end
                        end
                        if #without > 0 then affordable = without end
                    end

                    -- air production rule: NO bombers at all until a T3 bomber
                    -- actually becomes available in our build options.
                    -- Fighters (AA-only weapons) and gunships stay allowed.
                    if U.IsAirFactory(uDefID) then
                        local t3BomberExists = false
                        for i = 1, #affordable do
                            local ad = UnitDefs[affordable[i]]
                            if ad and ad.canFly and (ad.weapons and #ad.weapons > 0)
                                and not U.IsFighterDef(affordable[i])
                                and not sFind(sLower(ad.name or ""), "gunship")
                                and (ad.techLevel or 0) >= cfg.T3_TECH_LEVEL then
                                t3BomberExists = true
                                break
                            end
                        end
                        if not t3BomberExists then
                            local filtered = {}
                            for i = 1, #affordable do
                                local ad = UnitDefs[affordable[i]]
                                local isBomber = ad and ad.canFly and (ad.weapons and #ad.weapons > 0)
                                    and not U.IsFighterDef(affordable[i])
                                    and not sFind(sLower(ad.name or ""), "gunship")
                                if not isBomber then filtered[#filtered + 1] = affordable[i] end
                            end
                            if #filtered > 0 then affordable = filtered end
                        end
                        -- keep a strong fighter screen up first
                        if math.random() < cfg.AIR_FIGHTER_BIAS then
                            local fighters = {}
                            for i = 1, #affordable do
                                if U.IsFighterDef(affordable[i]) then fighters[#fighters + 1] = affordable[i] end
                            end
                            if #fighters > 0 then choice = fighters[math.random(#fighters)] end
                        end
                    end
                    if not choice and math.random() < (heavyUnlocked and cfg.BIG_UNIT_BIAS or cfg.SMALL_UNIT_BIAS) then
                        -- spam mode: usually build the biggest gun we can afford,
                        -- so T2/heavy units roll out non-stop once unlocked.
                        -- Artillery is SUPPORT only: never picked as "the biggest".
                        local artySet = {}
                        for i = 1, #cache.artillery do artySet[cache.artillery[i]] = true end
                        local bestID, bestCost = nil, -1
                        for i = 1, #affordable do
                            if not artySet[affordable[i]] then
                                local ac = UnitDefs[affordable[i]] and UnitDefs[affordable[i]].metalCost or 0
                                if ac > bestCost then bestCost, bestID = ac, affordable[i] end
                            end
                        end
                        choice = bestID or affordable[#affordable]
                    else
                        -- cost-weighted random pick, capped at UNIT_PICK_COST_CAP_SECONDS
                        -- of income so the priciest unit doesn't dwarf all picks
                        local pickCostCap = (st.metalIncome or 0) * cfg.UNIT_PICK_COST_CAP_SECONDS
                        local totalWeight = 0
                        for i = 1, #affordable do
                            local ac = UnitDefs[affordable[i]] and UnitDefs[affordable[i]].metalCost or 0
                            totalWeight = totalWeight + math.sqrt(mMin(ac, pickCostCap) + 1)
                        end
                        local roll = math.random() * totalWeight
                        choice = affordable[#affordable]
                        for i = 1, #affordable do
                            local ac = UnitDefs[affordable[i]] and UnitDefs[affordable[i]].metalCost or 0
                            roll = roll - math.sqrt(mMin(ac, pickCostCap) + 1)
                            if roll <= 0 then choice = affordable[i] break end
                        end
                    end
                else
                    -- nothing affordable: queue the CHEAPEST option so the lab
                    -- resumes production as soon as any metal trickles in,
                    -- instead of sitting frozen on an expensive order
                    local pool = cache.mobile
                    if #cache.artillery > 0 then
                        pool = {}
                        for i = 1, #cache.mobile do pool[#pool + 1] = cache.mobile[i] end
                        for i = 1, #cache.artillery do pool[#pool + 1] = cache.artillery[i] end
                    end
                    local cheapestID, cheapestCost = nil, mHuge
                    for i = 1, #pool do
                        local pcost = UnitDefs[pool[i]] and UnitDefs[pool[i]].metalCost or mHuge
                        if pcost < cheapestCost then cheapestCost, cheapestID = pcost, pool[i] end
                    end
                    choice = cheapestID or pool[math.random(#pool)]
                end

                -- artillery as a small support slice of production
                if not choice and heavyUnlocked and #cache.artillery > 0 and math.random() < cfg.ARTILLERY_SUPPORT_CHANCE then
                    for i = #cache.artillery, 1, -1 do
                        local aID = cache.artillery[i]
                        if cfg.CanAffordCombatUnit(aID) then choice = aID break end
                    end
                end
            end

            -- last-resort cons ONLY while metal-stalled (keeps eco alive),
            -- otherwise the factory waits for metal instead of spamming cons
            if not choice and st.metalStalling and #cache.cons > 0 and realConBots < conTarget + 2 then
                choice = B.PickPreferAir(cache.cons, true)
                st.conUnitCount = st.conUnitCount + 1
            end

            if choice then
                spGiveOrderToUnit(unitID, -choice, {}, {})
                st.lastFactoryOrderFrame[unitID] = frame
            end
        end

    elseif uDef.isBuilder and not uDef.isFactory then
        local ux, uy, uz = spGetUnitPosition(unitID)
        if not ux then return end

        if isTrapperUnit then
            local currentCmds = spGetUnitCommands(unitID, 1)
            local curCmd = currentCmds and currentCmds[1]
            local curCmdId = curCmd and curCmd.id
            if curCmdId and curCmdId < 0 then return end

            local mineDefID = nil
            local bestMineCost = -1
            if uDef.buildOptions then
                for i = 1, #uDef.buildOptions do
                    local optID = uDef.buildOptions[i]
                    local optDef = UnitDefs[optID]
                    if optDef then
                        local optsName = sLower(optDef.name or "")
                        if sFind(optsName, "mine") then
                            local cost = optDef.metalCost or 0
                            if cost > bestMineCost then bestMineCost = cost mineDefID = optID end
                        end
                    end
                end
            end

            if mineDefID then
                -- face the enemy: nearest known base, else map centre (inline for the upvalue cap)
                local fX, fZ = st.frontierX, st.frontierZ
                if not fX then
                    local bestD, bX, bZ = 1e18, nil, nil
                    local refX, refZ = st.baseCenterX or ux, st.baseCenterZ or uz
                    for _, b in pairs(st.enemyBases) do
                        if b.lastSeen then
                            local dx, dz = b.x - refX, b.z - refZ
                            local d = dx*dx + dz*dz
                            if d < bestD then bestD, bX, bZ = d, b.x, b.z end
                        end
                    end
                    if bX then fX, fZ = bX, bZ
                    else fX, fZ = (Game.mapSizeX or 8192) * 0.5, (Game.mapSizeZ or 8192) * 0.5 end
                end

                -- roll a new mine spot only when this unit has no cached one as
                -- re-rolling every poll would re-aim before it ever arrived
                local tgt = trapperTargets[unitID]
                if not tgt then
                    local targetX, targetZ = ux, uz
                    if st.baseCenterX and st.baseRadius > 100 then
                        local baseAngle = math.atan2(fZ - st.baseCenterZ, fX - st.baseCenterX)
                        local angle = baseAngle + (math.random() - 0.5) * math.pi
                        local minDist = 800 -- at least 800 out, up to ~1.5x base radius
                        local maxDist = mMax(minDist + 400, st.baseRadius * 1.5)
                        local dist = math.random(minDist, maxDist)

                        targetX = mMax(100, mMin(st.baseCenterX + mCos(angle) * dist, (Game.mapSizeX or 8192) - 100))
                        targetZ = mMax(100, mMin(st.baseCenterZ + mSin(angle) * dist, (Game.mapSizeZ or 8192) - 100))
                    elseif st.myFactoriesCount > 0 then
                        local facID = st.myFactories[math.random(st.myFactoriesCount)]
                        local fx, _, fz = spGetUnitPosition(facID)
                        if fx then
                            local baseAngle = math.atan2(fZ - fz, fX - fx)
                            local angle = baseAngle + (math.random() - 0.5) * math.pi
                            local dist = math.random(200, 500)
                            targetX = mMax(100, mMin(fx + mCos(angle) * dist, (Game.mapSizeX or 8192) - 100))
                            targetZ = mMax(100, mMin(fz + mSin(angle) * dist, (Game.mapSizeZ or 8192) - 100))
                        end
                    elseif st.myCommanderCount > 0 then
                        local comID = st.myCommanders[1]
                        local cx, _, cz = spGetUnitPosition(comID)
                        if cx then
                            targetX = mMax(100, mMin(cx + math.random(-300, 300), (Game.mapSizeX or 8192) - 100))
                            targetZ = mMax(100, mMin(cz + math.random(-300, 300), (Game.mapSizeZ or 8192) - 100))
                        end
                    end
                    tgt = { x = targetX, z = targetZ }
                    trapperTargets[unitID] = tgt
                end
                local targetX, targetZ = tgt.x, tgt.z

                local dx, dz = targetX - ux, targetZ - uz
                local distSq = dx * dx + dz * dz
                if distSq > 150 * 150 then
                    if curCmdId ~= cfg.CMD_MOVE then
                        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { targetX, spGetGroundHeight(targetX, targetZ), targetZ }, {})
                    end
                else
                    if B.CanAffordBuild(mineDefID, true) then
                        local tx, ty, tz, facing, key = B.FindBuildSpot(targetX, targetZ, mineDefID, 64, unitID)
                        if tx then
                            st.claimedSpots[key] = { frame = frame, x = tx, z = tz, r2 = 32*32, isFactory = false, isAirFactory = false, facing = facing, defID = mineDefID, isMex = false }
                            st.pendingCommittedMetal = st.pendingCommittedMetal + (UnitDefs[mineDefID].metalCost or 0)
                            spGiveOrderToUnit(unitID, -mineDefID, { tx, ty, tz, facing }, {})
                            trapperTargets[unitID] = nil
                        else
                            -- no buildable tile near the committed spot: re-roll next poll
                            trapperTargets[unitID] = nil
                            if curCmdId ~= 0 and curCmdId ~= nil then spGiveOrderToUnit(unitID, CMD_STOP, {}, {}) end
                        end
                    end
                end
            else
                W.PushFrontier(unitID, ux, uz)
            end
            return 
        end

        local isCommander = uDef.customParams and (uDef.customParams.iscommander ~= nil or uDef.customParams.is_commander ~= nil) or (uDef.name and sFind(sLower(uDef.name), "commander"))
        if isCommander then
            local myTeamID = spGetMyTeamID()

            -- any damage means that our commander is too far up or exposed
            -- this would also catch hidden attackers
            local hp, maxHp = spGetUnitHealth(unitID)
            local wounded = (hp and maxHp and maxHp > 0) and (hp < maxHp - 0.5)

            local csts = Spring.GetUnitStates(unitID)
            local isCloaked = csts and csts.cloak

            local dgunRange = 0
            local dgunEnergyCost = 0
            if uDef.weapons then
                for i = 1, #uDef.weapons do
                    local wDef = uDef.weapons[i].weaponDef and WeaponDefs[uDef.weapons[i].weaponDef]
                    if wDef and (wDef.manualFire or wDef.commandFire) then
                        dgunRange = wDef.range or 250
                        dgunEnergyCost = wDef.energyCost or wDef.energyPerShot or 0
                        break
                    end
                end
            end
            if dgunRange == 0 then dgunRange = 256 end
            local dgunRangeSq = (dgunRange * 0.8) * (dgunRange * 0.8)

            -- track nearby mobile enemies so the commander can flee efficiently
            local nearby = spGetUnitsInCylinder(ux, uz, cfg.COMMANDER_SCAN_RADIUS)
            local dgunTarget = nil
            local threatX, threatZ, threatCount = 0, 0, 0
            if nearby then
                for i = 1, #nearby do
                    local nID = nearby[i]
                    local nTeam = spGetUnitTeam(nID)
                    if nTeam and nTeam ~= myTeamID and not spAreTeamsAllied(myTeamID, nTeam) then
                        local nDef = spGetUnitDefID(nID) and UnitDefs[spGetUnitDefID(nID)]
                        if nDef and not nDef.isBuilding then
                            local nx, _, nz = spGetUnitPosition(nID)
                            if nx then
                                local dist = (nx-ux)*(nx-ux) + (nz-uz)*(nz-uz)
                                threatX, threatZ, threatCount = threatX + nx, threatZ + nz, threatCount + 1
                                if dist < dgunRangeSq then dgunTarget = nID end
                            end
                        end
                    end
                end
            end

            -- The dgun only fires because an enemy is on top of us
            -- TODO: Work further on dgun logic
            local curEnergy = Spring.GetTeamResources(myTeamID, "energy")
            if dgunTarget and dgunEnergyCost > 0 and curEnergy and curEnergy >= dgunEnergyCost then
                if isCloaked then
                    Spring.GiveOrderToUnit(unitID, CMD_CLOAK, {0}, {})
                end
                spGiveOrderToUnit(unitID, CMD_DGUN, { dgunTarget }, {})
                return
            end

            -- retreat when wounded or enemies are close, and
            -- fall back towards base so that it stops once home
            if wounded or threatCount > 0 then
                if threatCount > 0 then
                    if not isCloaked then
                        Spring.GiveOrderToUnit(unitID, CMD_CLOAK, {1}, {})
                    end
                elseif isCloaked then
                    Spring.GiveOrderToUnit(unitID, CMD_CLOAK, {0}, {})
                end
                local fx, fz = nil, nil
                if threatCount > 0 then
                    local avgEX, avgEZ = threatX / threatCount, threatZ / threatCount
                    local dx, dz = ux - avgEX, uz - avgEZ
                    local len = math.sqrt(dx*dx + dz*dz)
                    if len > 0.1 then
                        fx, fz = ux + (dx / len) * cfg.COMMANDER_RETREAT_DIST, uz + (dz / len) * cfg.COMMANDER_RETREAT_DIST
                    end
                end
                if not fx and st.baseCenterX then
                    local dx, dz = st.baseCenterX - ux, st.baseCenterZ - uz
                    local len = math.sqrt(dx*dx + dz*dz)
                    if len > 0.1 then
                        fx, fz = ux + (dx / len) * cfg.COMMANDER_RETREAT_DIST, uz + (dz / len) * cfg.COMMANDER_RETREAT_DIST
                    end
                end
                if fx then
                    local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
                    fx = mMax(100, mMin(fx, mapX - 100))
                    fz = mMax(100, mMin(fz, mapZ - 100))
                    spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { fx, spGetGroundHeight(fx, fz), fz }, {})
                end
                return
            end

            if isCloaked then
                Spring.GiveOrderToUnit(unitID, CMD_CLOAK, {0}, {})
            end
        end
        local isGraverobber = uDef.canResurrect or (uDef.name and (sFind(sLower(uDef.name), "graverobber") or sFind(sLower(uDef.name), "lazarus") or sFind(sLower(uDef.name), "zagreus")))
        if isGraverobber then
            local gEnemyUnit = W.FindEnemyReclaimTarget(ux, uz, (cfg.ENEMY_RECLAIM_CHASE_RANGE * st.mapLinearScale) or 1000, nil, nil, true)
            if gEnemyUnit then
                local gcmds = spGetUnitCommands(unitID, 1)
                if not gcmds or #gcmds == 0 or gcmds[1].id ~= cfg.CMD_RECLAIM or gcmds[1].params[1] ~= gEnemyUnit then
                    spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
                    spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { gEnemyUnit }, {})
                end
                return
            end

            if NeedsOrders(unitID, false, false, true) then
                local buildDist = uDef.buildDistance or 200
                local buildDistSq = buildDist * buildDist
                local myTeamID2 = spGetMyTeamID()

                local cmdrToHeal, cmdrDist = nil, mHuge
                for k = 1, st.myCommanderCount do
                    local cID = st.myCommanders[k]
                    local chp, cmax = spGetUnitHealth(cID)
                    if chp and cmax and chp < cmax then
                        local cx, _, cz = spGetUnitPosition(cID)
                        if cx then
                            local dist = (cx-ux)*(cx-ux) + (cz-uz)*(cz-uz)
                            if dist < cmdrDist then cmdrDist, cmdrToHeal = dist, cID end
                        end
                    end
                end
                if cmdrToHeal then
                    if cmdrDist < buildDistSq then spGiveOrderToUnit(unitID, cfg.CMD_REPAIR, { cmdrToHeal }, {})
                    else spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { spGetUnitPosition(cmdrToHeal) }, {}) end
                    return
                end

                local nearby = spGetUnitsInCylinder(ux, uz, 800)
                local unitToHeal, uDist, bestHealScore = nil, mHuge, -mHuge
                if nearby then
                    for k = 1, #nearby do
                        local nID = nearby[k]
                        if nID ~= unitID and spGetUnitTeam(nID) == myTeamID2 then
                            local nDef = spGetUnitDefID(nID) and UnitDefs[spGetUnitDefID(nID)]
                            local hp, maxHp = spGetUnitHealth(nID)
                            -- don't chase units faster than us
                            if hp and maxHp and hp < maxHp * 0.95 and not (nDef and nDef.speed and nDef.speed > uDef.speed) then
                                local nx, _, nz = spGetUnitPosition(nID)
                                if nx then
                                    local dx, dz = nx - ux, nz - uz
                                    local dist = math.sqrt(dx*dx + dz*dz)
                                    local cost = (nDef and nDef.metalCost) or 50
                                    local score = cost - dist
                                    if score > bestHealScore then bestHealScore, unitToHeal, uDist = score, nID, dist end
                                end
                            end
                        end
                    end
                end
                if unitToHeal then
                    if uDist < buildDist then spGiveOrderToUnit(unitID, cfg.CMD_REPAIR, { unitToHeal }, {})
                    else spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { spGetUnitPosition(unitToHeal) }, {}) end
                    return
                end

                -- resurrect high value wrecks
                -- We don't care about reclaiming, it's a metal map
                local rezID, rezX, rezZ, rezMetal = W.FindResurrectTarget(ux, uz, 1600)
                if rezID then
                    local dx, dz = rezX - ux, rezZ - uz
                    local d2 = dx*dx + dz*dz
                    if d2 < buildDistSq then
                        spGiveOrderToUnit(unitID, CMD_RESURRECT, { rezID + (Game and Game.maxUnits or 32768) }, {})
                        return
                    elseif (rezMetal or 0) >= 100 then
                        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { rezX, spGetGroundHeight(rezX, rezZ), rezZ }, {})
                        return
                    end
                end

                if (st.army.state == "attacking" or st.army.state == "searching") and st.army.targetX then
                    local dx, dz = st.army.targetX - ux, st.army.targetZ - uz
                    if dx*dx + dz*dz > (400 * 400) then
                        W.GiveSpreadMove(unitID, ux, uz, st.army.targetX, st.army.targetZ, cfg.ANTI_CLUMP_MIN, cfg.ANTI_CLUMP_MAX)
                        return
                    end
                end

                if st.myCombatUnitCount > 0 then
                    local closestCombat, cDist = nil, mHuge
                    for i = 1, st.myCombatUnitCount do
                        local cID = st.myCombatUnits[i]
                        local cx, _, cz = spGetUnitPosition(cID)
                        if cx then
                            local dist = (cx-ux)*(cx-ux) + (cz-uz)*(cz-uz)
                            if dist < cDist then cDist, closestCombat = dist, cID end
                        end
                    end
                    if closestCombat then
                        if not IsGuardingValidTarget(unitID, 500) then spGiveOrderToUnit(unitID, cfg.CMD_GUARD, { closestCombat }, {}) end
                        return
                    end
                end
            end
            W.PushFrontier(unitID, ux, uz)
            return
        end

        local isStationary = (not uDef.speed or uDef.speed == 0)
        if isStationary then
            if not st.moveStateSet[unitID] then
                spGiveOrderToUnit(unitID, CMD_MOVE_STATE, { 0 }, {})
                st.moveStateSet[unitID] = true
            end
            local myTeamID = spGetMyTeamID()
            local buildDist = uDef.buildDistance or 200
            local currentCmds = spGetUnitCommands(unitID, 1)
            local cmd1 = currentCmds and currentCmds[1]
            local curId = cmd1 and cmd1.id
            local curParam = cmd1 and cmd1.params and cmd1.params[1]

            local enemyUnit = W.FindEnemyReclaimTarget(ux, uz, buildDist, myTeamID)
            if enemyUnit then
                if curId ~= cfg.CMD_RECLAIM or curParam ~= enemyUnit then
                    spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { enemyUnit }, {})
                end
                return
            end

            local mStall = st.metalStalling
            local eStall = st.energyStalling
            if mStall or eStall then
                if not eStall then
                    local reclaimTarget = W.FindReclaimTarget(ux, uz, true, buildDist)
                    if reclaimTarget then
                        local fcmd = reclaimTarget + (Game and Game.maxUnits or 32768)
                        if curId ~= cfg.CMD_RECLAIM or curParam ~= fcmd then
                            spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { fcmd }, {})
                        end
                        return
                    end
                end

                local function WantsStallType(def)
                    if not def then return false end
                    if mStall and def.extractsMetal and def.extractsMetal > 0 then return true end
                    if eStall then
                        local n = def.name and sLower(def.name) or ""
                        if (def.energyMake and def.energyMake > 0)
                            or sFind(n, "wind") or sFind(n, "solar")
                            or sFind(n, "fusion") or sFind(n, "geo") then return true end
                    end
                    return false
                end

                if curId == cfg.CMD_REPAIR and curParam then
                    local cDefID = spGetUnitDefID(curParam)
                    if WantsStallType(cDefID and UnitDefs[cDefID]) then
                        local chp, cmax = spGetUnitHealth(curParam)
                        if chp and cmax and chp < cmax then return end
                    end
                end

                local targetFrame, bestProgress = nil, 0
                local stallScan = spGetUnitsInCylinder(ux, uz, buildDist)
                if stallScan then
                    for k = 1, #stallScan do
                        local nID = stallScan[k]
                        if nID ~= unitID and spGetUnitTeam(nID) == myTeamID then
                            local nDefID = spGetUnitDefID(nID)
                            local nDef = nDefID and UnitDefs[nDefID]
                            if nDef and WantsStallType(nDef) then
                                local hp, maxHp = spGetUnitHealth(nID)
                                if hp and maxHp and maxHp > 0 and hp < maxHp then
                                    local progress = maxHp - hp
                                    if progress > bestProgress then bestProgress, targetFrame = progress, nID end
                                end
                            end
                        end
                    end
                end
                if targetFrame then
                    if curId ~= cfg.CMD_REPAIR or curParam ~= targetFrame then
                        spGiveOrderToUnit(unitID, cfg.CMD_REPAIR, { targetFrame }, {})
                    end
                    return
                end

                if currentCmds and #currentCmds > 0 then
                    spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
                end
                return
            end

            if curId == cfg.CMD_REPAIR then return end

            local nearby = spGetUnitsInCylinder(ux, uz, buildDist)
            if nearby then
                local targetToRepair, maxDamage = nil, 0
                for k = 1, #nearby do
                    local nID = nearby[k]
                    if nID ~= unitID and spGetUnitTeam(nID) == myTeamID then
                        local nDef = spGetUnitDefID(nID) and UnitDefs[spGetUnitDefID(nID)]
                        if nDef then
                            local hp, maxHp = spGetUnitHealth(nID)
                            if hp and maxHp and maxHp > 0 and hp < maxHp * cfg.CON_HEAL_THRESHOLD then
                                local nx, _, nz = spGetUnitPosition(nID)
                                if nx then
                                    local dx, dz = nx - ux, nz - uz
                                    if dx*dx + dz*dz <= buildDist * buildDist then
                                        local damage = maxHp - hp
                                        if damage > maxDamage then maxDamage, targetToRepair = damage, nID end
                                    end
                                end
                            end
                        end
                    end
                end
                if targetToRepair then
                    if curId ~= cfg.CMD_REPAIR or curParam ~= targetToRepair then
                        spGiveOrderToUnit(unitID, cfg.CMD_REPAIR, { targetToRepair }, {})
                    end
                    return
                end
            end

            local reclaimTarget = W.FindReclaimTarget(ux, uz, true, buildDist)
            if reclaimTarget then
                local fcmd = reclaimTarget + (Game and Game.maxUnits or 32768)
                if curId ~= cfg.CMD_RECLAIM or curParam ~= fcmd then
                    spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { fcmd }, {})
                end
                return
            end

            if currentCmds and #currentCmds > 0 then
                spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
            end
            return
        end

        -- Mobile con
        local myTeamID = spGetMyTeamID()
        local conBuildDist = uDef.buildDistance or 200
        -- t2 constructor threshold (matches advancedConID selection below)
        local isAdvCon = (uDef.metalCost or 0) >= 250
        local reclaimScanRadius = (cfg.ENEMY_RECLAIM_CHASE_RANGE * st.mapLinearScale) or 1000
        local enemyUnit = W.FindEnemyReclaimTarget(ux, uz, reclaimScanRadius, myTeamID, nil, true)
        if enemyUnit then
            local cmds = spGetUnitCommands(unitID, 1)
            if not cmds or #cmds == 0 or cmds[1].id ~= cfg.CMD_RECLAIM or cmds[1].params[1] ~= enemyUnit then
                spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
                spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { enemyUnit }, {})
            end
            return
        end

        local emergencyType = ((not E.IsUnitBuildingFactory(unitID))) and E.CheckEmergencyEconomy(unitID) or nil
        if emergencyType then
            local cache = B.GetBuildCache(uDefID)
            local emergencyDef, eSpacing = nil, cfg.MIN_SPACING

            if emergencyType == "energy" then
                if hasWind and #cache.energyWind > 0 then emergencyDef = cache.energyWind[1] eSpacing = 64
                elseif #cache.energySolar > 0 then emergencyDef = cache.energySolar[1] eSpacing = 64 end
            else
                if #cache.mex > 0 then
                    local cheapestMex, cheapestCost = nil, mHuge
                    for i = #cache.mex, 1, -1 do
                        local cost = UnitDefs[cache.mex[i]] and UnitDefs[cache.mex[i]].metalCost or mHuge
                        if cost < cheapestCost then cheapestCost, cheapestMex = cost, cache.mex[i] end
                    end
                    emergencyDef = cheapestMex
                    eSpacing = st.metalMapMexSpacing
                end
            end

            if emergencyDef and B.CanAffordBuild(emergencyDef, true) then
                local tx, ty, tz, facing, key
                tx, ty, tz, facing, key = B.FindBuildSpot(ux, uz, emergencyDef, eSpacing, unitID, conBuildDist, nil, nil, nil, true)

                if tx then
                    spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
                    local claimRadius = eSpacing * 0.5
                    if emergencyType == "metal" then claimRadius = st.metalMapMexSpacing * 0.5 end
                    local isMex = UnitDefs[emergencyDef] and UnitDefs[emergencyDef].extractsMetal and UnitDefs[emergencyDef].extractsMetal > 0
                    st.claimedSpots[key] = { frame = frame, x = tx, z = tz, r2 = claimRadius * claimRadius, isFactory = false, isAirFactory = false, facing = facing, defID = emergencyDef, isMex = isMex }
                    st.pendingCommittedMetal = st.pendingCommittedMetal + (UnitDefs[emergencyDef] and UnitDefs[emergencyDef].metalCost or 0)
                    spGiveOrderToUnit(unitID, -emergencyDef, { tx, ty, tz, facing }, {})
                    return
                end
            else
                local buildDist = uDef.buildDistance or 200
                local reclaimTarget = W.FindReclaimTarget(ux, uz, true, buildDist)
                if reclaimTarget then
                    local currentCmds = spGetUnitCommands(unitID, 1)
                    if not currentCmds or #currentCmds == 0 or currentCmds[1].id ~= cfg.CMD_RECLAIM then
                        spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
                        spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { reclaimTarget + (Game and Game.maxUnits or 32768) }, {})
                        return
                    end
                end
            end
        end

        if (not E.IsUnitBuildingFactory(unitID)) and NeedsOrders(unitID, false, false, false) then
            local cache = B.GetBuildCache(uDefID)
            local tx, ty, tz, facing, key, defID
            local claimRadius = cfg.MIN_SPACING
            local rowBuild = false
            local afusRow = false
            -- enemy direction (toward nearest seen enemy base); used for
            -- factory facing AND to keep eco rows out of launch corridors.
            -- Declared here so QueueEcoRow's closure captures it.
            local facDirX, facDirZ
            -- long eco strips unlock only after basic eco is established
            local ecoRowsReady = ((st.mexUnitCount or 0) >= cfg.ROWS_MIN_MEX)
                and ((st.ecoEnergyCount or 0) >= cfg.ROWS_MIN_WIND)
            local ecoRowLen = ecoRowsReady and cfg.ECO_ROW_COUNT or cfg.BUILD_BLOCK_SIZE
            local mexCluster = false
            local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
            local function clampAnchor(cx, cz) return mMax(300, mMin(cx, mapX - 300)), mMax(300, mMin(cz, mapZ - 300)) end

            -- Continuous eco rows: a strip 2 buildings wide and ECO_ROW_COUNT
            -- long, extending away from base center. Cells are validated with
            -- TestBuildOrder; if too few fit forward we flip the direction.
            local function QueueEcoRow(uid, dID, bx, by, bz, maxN)
                local bd = UnitDefs[dID]
                if not bd then return 0 end
                maxN = mMin(maxN or cfg.ECO_ROW_COUNT, cfg.ECO_ROW_COUNT)
                local fw = mMax(bd.xsize or 4, bd.zsize or 4) * 8 + cfg.BLOCK_GAP
                local bcx, bcz = st.baseCenterX or bx, st.baseCenterZ or bz
                local ddx, ddz = bx - bcx, bz - bcz
                local dirX, dirZ = 0, 1
                if mAbs(ddx) > mAbs(ddz) then
                    dirX, dirZ = (ddx >= 0) and 1 or -1, 0
                else
                    dirX, dirZ = 0, (ddz >= 0) and 1 or -1
                end
                local col2X, col2Z = 0, 0
                if dirX ~= 0 then col2Z = fw else col2X = fw end

                local function tryRow(sx, sz)
                    local q = {}
                    for r = 0, maxN - 1 do
                        for c = 1, 2 do
                            local offC = (c == 1) and 0 or 1
                            local px = sx + dirX * fw * r + col2X * offC
                            local pz = sz + dirZ * fw * r + col2Z * offC
                            if px > 100 and pz > 100 and px < mapX - 100 and pz < mapZ - 100 then
                                -- keep unit passages clear: never place eco cells
                                -- inside the launch corridor in front of a lab
                                local exitBlocked = false
                                for j = 1, st.myFactoriesCount do
                                    local fx, _, fz = spGetUnitPosition(st.myFactories[j])
                                    if fx then
                                        local cdx, cdz = px - fx, pz - fz
                                        if cdx * cdx + cdz * cdz < 22500 then
                                            local fdx, fdz = facDirX or 0, facDirZ or 0
                                            if fdx == 0 and fdz == 0 then exitBlocked = true
                                            elseif cdx * fdx + cdz * fdz > 0 then exitBlocked = true end
                                        end
                                    end
                                end
                                if not exitBlocked then
                                    local py = spGetGroundHeight(px, pz) or by
                                    if Spring.TestBuildOrder(dID, px, py, pz, 0) ~= 0 then
                                        q[#q + 1] = { px, py, pz }
                                    end
                                end
                            end
                        end
                    end
                    return q
                end

                local list = tryRow(bx, bz)
                if #list < mMin(cfg.ECO_ROW_MIN, maxN) then
                    local back = tryRow(bx - dirX * fw, bz - dirZ * fw)
                    if #back > #list then list = back end
                end
                for i = 1, #list do
                    spGiveOrderToUnit(uid, -dID, { list[i][1], list[i][2], list[i][3], 0 }, i == 1 and {} or { "shift" })
                end
                return #list
            end

            local buildAnchorX, buildAnchorZ = ux, uz
            if st.myFactoriesCount > 0 then buildAnchorX, buildAnchorZ = B.GetNearestFactoryPos(ux, uz) end

            if st.enemyBases and next(st.enemyBases) ~= nil then
                local bestD = mHuge
                for _, b in pairs(st.enemyBases) do
                    if b.lastSeen then
                        local bdx, bdz = b.x - ux, b.z - uz
                        local bd = bdx * bdx + bdz * bdz
                        if bd < bestD then bestD, facDirX, facDirZ = bd, bdx, bdz end
                    end
                end
            end
            if not facDirX then
                facDirX, facDirZ = mapX * 0.5 - ux, mapZ * 0.5 - uz
            end
            local facFacing
            if mAbs(facDirX) >= mAbs(facDirZ) then
                facFacing = facDirX >= 0 and 1 or 3
            else
                facFacing = facDirZ >= 0 and 0 or 2
            end

            local isNearBase = false
            if st.myFactoriesCount > 0 then
                local dx, dz = buildAnchorX - ux, buildAnchorZ - uz
                if dx*dx + dz*dz < (1200 * 1200) then isNearBase = true end
            else isNearBase = true end

            if isNearBase then
                local reclaimTarget = W.FindReclaimTarget(ux, uz, true, conBuildDist)
                if reclaimTarget and (st.metalStalling or math.random() < 0.25) then
                    spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { reclaimTarget + (Game and Game.maxUnits or 32768) }, {}) return
                end
            end

            if st.myFactoriesCount == 0 and (not E.IsUnitBuildingFactory(unitID)) and #cache.factories > 0 then
                local starterFactory = B.GetCheapestVehicleFactory(cache) or cache.factories[#cache.factories]
                if B.CanAffordBuild(starterFactory, true) then
                    defID = starterFactory
                    -- We want to place the first lab within
                    -- 80 elmos of the commanders range
                    -- So it doesn't have to walk to build it
                    local labDef = UnitDefs[defID]
                    local labKeepR = (mMax(labDef.xsize or 8, labDef.zsize or 8) * 8) / 2 + 48
                    tx, ty, tz, facing, key = B.FindBuildSpot(ux, uz, defID, 80, unitID, conBuildDist, labKeepR * labKeepR, facFacing)
                    if tx then
                        claimRadius = U.IsAirFactory(defID) and 90 or select(2, U.FactoryTurretInfo(defID))
                        st.claimedSpots[key] = { frame = frame, x = tx, z = tz, r2 = claimRadius * claimRadius, isFactory = true, isAirFactory = U.IsAirFactory(defID), facing = facing, defID = defID, isMex = false }
                        st.pendingCommittedMetal = st.pendingCommittedMetal + (UnitDefs[defID] and UnitDefs[defID].metalCost or 0)
                        st.pendingFactoryBlueprints = st.pendingFactoryBlueprints + 1
                        spGiveOrderToUnit(unitID, -defID, { tx, ty, tz, facing }, {})
                    end
                end
            end

            -- T2 economy focus: while advanced constructors exist, T1 workers
            -- stop claiming NEW eco and only assist/guard/reclaim instead
            if not tx and (not E.IsUnitBuildingFactory(unitID)) and (st.myFactoriesCount > 0 or st.pendingFactoryBlueprints > 0) and not st.economySaturated
                and (isAdvCon or uDef.isCommander or (st.advConCount or 0) == 0) then
                local overflowingEnergy = (st.currentEnergyStorage > 0) and (st.currentEnergy > st.currentEnergyStorage * 0.85)
                local targetEnergy = mMax(st.energyPull * 1.15, mMin(st.metalIncome * 20, mMax(st.energyPull * 2, 600)), 100)
                local overflowingMetal = (st.currentMetalStorage > 0) and (st.currentMetal > st.currentMetalStorage * 0.85)
                local metalDeficit = mMax(0, (st.metalPull or 0) - (st.metalIncome or 0))
                local energyDeficit = mMax(0, (st.energyPull or 0) - (st.energyIncome or 0))
                local mexBudget = mMax(1, mMin(math.ceil(metalDeficit / cfg.GetMexGain()), mMax(1, st.unclaimedMexCount or 0))) * cfg.ECO_BUILDER_AGGRESSION
                local energyBudget = mMax(1, math.ceil(energyDeficit / cfg.GetEnergyGain())) * cfg.ECO_BUILDER_AGGRESSION

                local needMetal = (st.metalStalling or st.unclaimedMexCount > 0) and not overflowingMetal
                local needEnergy = st.energyStalling or ((st.energyIncome < targetEnergy) and not overflowingEnergy)
                if not needMetal and not overflowingMetal and (st.metalIncome or 0) < (cfg.METAL_MAP_MEX_INCOME_TARGET * st.mapAreaScale) then
                    needMetal = true
                    mexBudget = mMax(mexBudget, math.ceil(cfg.MEX_GROWTH_FLOOR * st.mapAreaScale))
                end

                if not needMetal and not overflowingMetal and #cache.mex > 0 and (UnitDefs[cache.mex[#cache.mex]].metalCost or 0) > 300 then needMetal = true end

                -- enough builders on the job: leave this con to its current work
                if st.activeMexBuilders >= mexBudget then needMetal = false end
                if st.activeEnergyBuilders >= energyBudget then needEnergy = false end

                if not needEnergy and not needMetal then
                    -- keep a con on eco rather than idling
                    local energyStillNeeded = (st.energyIncome < targetEnergy) and not overflowingEnergy
                    if st.activeMexBuilders < mexBudget and st.activeEnergyBuilders < energyBudget then
                        if math.random() < 0.5 then needMetal = true elseif energyStillNeeded then needEnergy = true end
                    elseif st.activeMexBuilders < mexBudget then needMetal = true
                    elseif st.activeEnergyBuilders < energyBudget then
                        if energyStillNeeded then needEnergy = true end
                    end
                end
                if needEnergy and needMetal then
                    if st.energyStalling then needMetal = false elseif st.metalStalling then needEnergy = false else if math.random() < 0.65 then needMetal = false else needEnergy = false end end
                elseif needEnergy then needMetal = false
                elseif needMetal then needEnergy = false end

                if not tx and needMetal and #cache.mex > 0 then
                    local chosenMex = nil
                    local cheapestMexCost, cheapestMex = mHuge, nil
                    for i = #cache.mex, 1, -1 do
                        local cost = UnitDefs[cache.mex[i]] and UnitDefs[cache.mex[i]].metalCost or mHuge
                        if cost < cheapestMexCost then cheapestMexCost, cheapestMex = cost, cache.mex[i] end
                    end

                    if (st.metalStalling or st.unclaimedMexCount > 0) and cheapestMex and B.CanAffordBuild(cheapestMex, true) then chosenMex = cheapestMex end
                    if not chosenMex and st.economySaturated and not st.metalStalling then
                        for i = 1, #cache.mex do if B.CanAffordBuild(cache.mex[i], false) then chosenMex = cache.mex[i] break end end
                    end
                    if not chosenMex and cheapestMex and B.CanAffordBuild(cheapestMex, true) then chosenMex = cheapestMex end

                        if chosenMex then
                            defID = chosenMex
                            local nearestMex, mexDistSq = E.GetNearestUnclaimedMetalSpot(ux, uz)

                        local skipMetal = false
                        if nearestMex and mexDistSq > (cfg.MEX_SKIP_DIST * st.mapLinearScale) * (cfg.MEX_SKIP_DIST * st.mapLinearScale) and st.conUnitCount > 1 then
                            if not st.metalStalling or (st.metalStalling and st.activeMexBuilders >= 2) then skipMetal = true end
                        end

                        if skipMetal then
                            defID = nil
                        else
                            tx, ty, tz, facing, key = B.FindBuildSpot(ux, uz, defID, st.metalMapMexSpacing, unitID, conBuildDist, nil, nil, nil, true)
                        end

                        if not tx and defID then
                        -- Important, We NEVER want to upgrade existing
                        -- mexes. Theres no "tax credit" we're going to get
                        -- for making our mexes more efficient
                        -- it's wasted money
                            if #st.metalSpots == 0 then
                                local sx, sz = U.GetFlankSpreadPos(unitID, ux, uz, st.metalMapMexSpacing * 2, st.metalMapMexSpacing * 6, nil)
                                spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { sx, spGetGroundHeight(sx, sz), sz }, {})
                                return
                            end
                        end

                        if tx and defID then
                            claimRadius = st.metalMapMexSpacing * 0.5
                            st.activeMexBuilders = st.activeMexBuilders + 1
                            mexCluster = true
                        end
                    end
                end

                if not tx and needEnergy then
                    local eID = nil
                    local afusMode = false
                    -- AFUS endgame: once advanced fusion is affordable,
                    -- stop mixing in wind/solar entirely
                    for i = 1, #cache.energyAdv do
                        local aN = UnitDefs[cache.energyAdv[i]] and sLower(UnitDefs[cache.energyAdv[i]].name or "") or ""
                        if sFind(aN, "fusion") or sFind(aN, "afus") then
                            if st.afusLocked or B.CanAffordBuild(cache.energyAdv[i], false) then
                                eID = cache.energyAdv[i]
                                afusMode = true
                            end
                            break
                        end
                    end

                    if not eID and not st.afusLocked then
                        if hasWind and st.energyStalling and #cache.energyWind > 0 then eID = cache.energyWind[1] end
                        if not eID and #cache.energyAdv > 0 then
                            for i = 1, #cache.energyAdv do
                                local candidateID = cache.energyAdv[i]
                                local cost = UnitDefs[candidateID].metalCost or 0
                                if st.currentMetal > cost or (not st.energyStalling and st.currentMetal > (cost * 0.5)) then eID = candidateID break end
                            end
                        end
                        if not eID then
                            if hasWind and #cache.energyWind > 0 then eID = cache.energyWind[1]
                            elseif #cache.energySolar > 0 then eID = cache.energySolar[1] end
                        end
                    end

                    if eID and B.CanAffordBuild(eID, true) then
                        defID = eID
                        local eCost = UnitDefs[eID].metalCost or 0
                        local eSpacing = (eCost > 4000) and 192 or ((eCost > 800) and 128 or cfg.ENERGY_GRID_SPACING)
                        local eAx, eAz = clampAnchor(ux, uz)
                        tx, ty, tz, facing, key = B.FindBuildSpot(eAx, eAz, defID, eSpacing, unitID, conBuildDist, nil, nil, nil, true)
                        if tx then
                            claimRadius = eSpacing * 0.5
                            st.activeEnergyBuilders = st.activeEnergyBuilders + 1
                            rowBuild = true
                            if afusMode then
                                afusRow = true
                                st.afusLocked = true -- from now on: fusion only
                            end
                        end
                    end
                end
            end

            -- Storage overflow: immediately queue a storage building whenever
            -- a resource exceeds its current capacity buffer.  Cheap T1
            -- storage goes up right away; once adv constructors exist the
            -- same path picks T2 storage automatically.
            if not tx and #cache.storage > 0 and st.myFactoriesCount > 0 then
                local needStorage = false
                local pickEnergy = false
                if st.currentEnergyStorage > 0 and st.currentEnergy > st.currentEnergyStorage * cfg.STORAGE_OVERFLOW_RATIO then
                    needStorage = true; pickEnergy = true
                elseif st.currentMetalStorage > 0 and st.currentMetal > st.currentMetalStorage * cfg.STORAGE_OVERFLOW_RATIO then
                    needStorage = true; pickEnergy = false
                end
                if needStorage and B.CanAffordBuild(cache.storage[1], false) then
                    for i = 1, #cache.storage do
                        local sid = cache.storage[i]
                        local sd = UnitDefs[sid]
                        if sd then
                            local sdName = sLower(sd.name or "")
                            local isEnergySt = sFind(sdName, "energy") or (not sFind(sdName, "metal"))
                            if isEnergySt == pickEnergy then
                                defID = sid
                                local sAx, sAz = clampAnchor(ux, uz)
                                tx, ty, tz, facing, key = B.FindBuildSpot(sAx, sAz, sid, cfg.STORAGE_BUILD_SPACING, unitID, conBuildDist, nil, nil, nil, true)
                                if tx then claimRadius = cfg.STORAGE_BUILD_SPACING end
                                break
                            end
                        end
                    end
                end
            end

            if not tx and st.incompleteFactoryCount > 0 then
                -- send only a few cons to help build a lab
                for i = 1, st.incompleteFactoryCount do
                    local incFactID = st.incompleteFactories[i]
                    if incFactID and (st.factoryGuards[incFactID] or 0) < 3 then
                        spGiveOrderToUnit(unitID, cfg.CMD_GUARD, { incFactID }, {})
                        st.factoryGuards[incFactID] = (st.factoryGuards[incFactID] or 0) + 1
                        return
                    end
                end
            end

            if not tx and #cache.conTurrets > 0 then
                if st.factoriesNeedingTurretsCount > 0 then
                    st.turretDbg.fired = st.turretDbg.fired + 1
                    local targetFactory = st.factoriesNeedingTurrets[1]
                    local fewest = st.factoryTurrets[targetFactory] or 0
                    for tk = 2, st.factoriesNeedingTurretsCount do
                        local fid = st.factoriesNeedingTurrets[tk]
                        local have = st.factoryTurrets[fid] or 0
                        if have < fewest then fewest, targetFactory = have, fid end
                    end
                    local fx, _, fz = spGetUnitPosition(targetFactory)
                    if fx then
                        defID = cache.conTurrets[math.random(#cache.conTurrets)]
                        local spacing = cfg.TURRET_SPACING
                        if not B.CanAffordBuild(defID) then
                            st.turretDbg.noAfford = st.turretDbg.noAfford + 1
                            defID = nil
                        else
                            local tDef = UnitDefs[defID]
                            local turFoot = (mMax(tDef and tDef.xsize or 2, tDef and tDef.zsize or 2) * 8)
                            spacing = mMax(40, turFoot + 16)
                            local facDef = UnitDefs[spGetUnitDefID(targetFactory)]
                            local facHalf = (mMax(facDef and facDef.xsize or 8, facDef and facDef.zsize or 8) * 8) / 2
                            local ringOut = mMin(facHalf + spacing * 4, cfg.BUILD_RADIUS)
                            tx, ty, tz, facing, key = B.FindBuildSpot(fx, fz, defID, spacing, unitID, ringOut, nil, nil, true, nil, facHalf)
                        end
                        if tx then
                            st.turretDbg.placed = st.turretDbg.placed + 1
                            claimRadius = spacing
                            st.factoryTurrets[targetFactory] = (st.factoryTurrets[targetFactory] or 0) + 1
                            -- Remember WHICH lab this turret was ordered for, so the
                            -- scan counts it against that lab and never a
                            -- neighbouring one it sits next to.
                            st.conTurretHomes[key] = targetFactory
                            if st.factoryTurrets[targetFactory] >= (U.FactoryTurretInfo(spGetUnitDefID(targetFactory))) then
                                for k = 1, st.factoriesNeedingTurretsCount do
                                    if st.factoriesNeedingTurrets[k] == targetFactory then
                                        st.factoriesNeedingTurrets[k] = st.factoriesNeedingTurrets[st.factoriesNeedingTurretsCount]
                                        st.factoriesNeedingTurretsCount = st.factoriesNeedingTurretsCount - 1
                                        break
                                    end
                                end
                            end
                        else
                            st.turretDbg.noSpot = st.turretDbg.noSpot + 1
                            defID = nil
                        end
                    end
                else
                    st.turretDbg.noNeed = st.turretDbg.noNeed + 1
                end
            elseif not tx then
                st.turretDbg.noCon = st.turretDbg.noCon + 1
            end

            local activeFactoryBuilds = st.incompleteFactoryCount + st.pendingFactoryBlueprints
            if not tx and #cache.factories > 0 and activeFactoryBuilds < cfg.MAX_CONCURRENT_FACTORIES and st.myFactoriesCount > 0 then

                -- Somehow we do 1 factory per 5 income, and yet we're still overflowing
                local availableMetal = mMax(0, st.currentMetal - st.pendingCommittedMetal)
                local supportableFactories = math.floor(st.metalIncome / 5)
                local canExpand = st.economySaturated
                    or (st.myFactoriesCount < supportableFactories and not st.metalStalling)
                    or (st.metalIncome >= 20 and not st.metalStalling)

                -- We don't need to open a new lab if one still needs con turrets,
                -- unless income is already flowing (tech rush beats turret rings)
                if not st.economySaturated and (st.factoriesNeedingTurretsCount or 0) > 0
                    and (st.metalIncome or 0) < 30 then
                    canExpand = false
                end

                -- Tech rush: build the MOST EXPENSIVE lab we're allowed to tech
                -- into first (that's the T2/adv factory), then fill in cheaper types.
                local missingFacID = nil
                local missingFacCost = -1
                for i = 1, #cache.factories do
                    local fID = cache.factories[i]
                    local fCost = UnitDefs[fID] and UnitDefs[fID].metalCost or 0
                    local haveIt = false
                    for j = 1, st.myFactoriesCount do if spGetUnitDefID(st.myFactories[j]) == fID then haveIt = true break end end
                    for _, claim in pairs(st.claimedSpots) do if claim.isFactory and claim.defID == fID then haveIt = true break end end
                    if not haveIt and fCost > missingFacCost then
                        missingFacID = fID
                        missingFacCost = fCost
                    end
                end

                if missingFacID and not st.metalStalling and cfg.CanTechUpToFactory(missingFacID)
                    and (canExpand or availableMetal >= missingFacCost) then
                    defID = missingFacID
                    local fAx, fAz = clampAnchor(ux, uz)
                    tx, ty, tz, facing, key = B.FindBuildSpot(fAx, fAz, defID, cfg.BUILD_SPACING, unitID, conBuildDist, nil, facFacing)
                    if tx then claimRadius = U.IsAirFactory(defID) and 90 or select(2, U.FactoryTurretInfo(defID)) end
                end
                if not tx and canExpand and #cache.factories > 0 then
                    -- extra labs: prefer the priciest one we may tech into,
                    -- so growth trends toward T2/adv factories
                    local extraFacID = nil
                    local extraFacCost = -1
                    for i = 1, #cache.factories do
                        local fID = cache.factories[i]
                        local fCost = UnitDefs[fID] and UnitDefs[fID].metalCost or 0
                        if cfg.CanTechUpToFactory(fID) and fCost > extraFacCost then extraFacID, extraFacCost = fID, fCost end
                    end
                    if extraFacID then
                        defID = extraFacID
                        local fAx, fAz = clampAnchor(ux, uz)
                        tx, ty, tz, facing, key = B.FindBuildSpot(fAx, fAz, defID, cfg.BUILD_SPACING, unitID, conBuildDist, nil, facFacing)
                        if tx then claimRadius = U.IsAirFactory(defID) and 90 or select(2, U.FactoryTurretInfo(defID)) end
                    end
                end
            end

            if not tx and #cache.other > 0 and st.myFactoriesCount > 0 and st.metalIncome > 12 then
                if math.random() < 0.15 then
                    for i = 1, #cache.other do
                        local oID = cache.other[i]
                        if UnitDefs[oID] and B.CanAffordBuild(oID) then
                            defID = oID
                            local cAx, cAz = st.baseCenterX, st.baseCenterZ
                            if not cAx then cAx, cAz = buildAnchorX, buildAnchorZ end
                            tx, ty, tz, facing, key = B.FindBuildSpot(cAx, cAz, defID, cfg.TURRET_SPACING, unitID, conBuildDist)
                            if tx then claimRadius = cfg.TURRET_SPACING break end
                        end
                    end
                end
            end

            if not tx and #cache.shields > 0 and st.metalIncome > 20 and st.currentMetal > 300 and not st.metalStalling and not st.energyStalling then
                if math.random() < 0.1 and B.CanAffordBuild(cache.shields[1]) then
                    defID = cache.shields[1]
                    tx, ty, tz, facing, key = B.FindBuildSpot(buildAnchorX, buildAnchorZ, defID, cfg.SHIELD_GRID_SPACING, unitID, conBuildDist)
                    if tx then claimRadius = 150 end
                end
            end

            -- lol this doesn't do anything, the bot doesn't understand radar
            -- good for the future though, hopefully whenever that can be fixed
            if not tx and #cache.radarTowers > 0 and st.myFactoriesCount > 0 then
                local radarTowerBudget = mMin(4, 1 + math.floor((st.metalIncome or 0) / 100))
                if (st.radarTowerCount or 0) < radarTowerBudget and not st.metalStalling and not st.energyStalling then
                    local rID = cache.radarTowers[1]
                    if B.CanAffordBuild(rID) then
                        defID = rID
                        local rAx, rAz = st.baseCenterX, st.baseCenterZ
                        if not rAx then rAx, rAz = buildAnchorX, buildAnchorZ end
                        tx, ty, tz, facing, key = B.FindBuildSpot(rAx, rAz, defID, cfg.BUILD_SPACING, unitID, conBuildDist)
                        if tx then claimRadius = 160 end
                    end
                end
            end

            if not tx and st.myFactoriesCount > 0 then
                if #cache.defensesGround > 0 then
                    local dID = B.SelectBalancedDefense(cache.defensesGround, st.currentMetal)
                    local turretCost = (UnitDefs[dID] and UnitDefs[dID].metalCost) or 1
                    local targetGround = cfg.BASE_GROUND_DEF_TARGET + st.myFactoriesCount * cfg.DEFENSE_MIN_PER_FACTORY
                        + math.floor((st.unease or 0) / turretCost)
                        + math.floor((st.enemyArmyValue or 0) / (turretCost * cfg.DEFENSE_ARMY_TURRET_RATIO))
                    local underPressure = (st.enemyArmyValue or 0) > 500
                    local stallBypass = underPressure or (st.unease or 0) >= turretCost
                    if (st.defenseGroundCount or 0) < targetGround and (not st.metalStalling or stallBypass) and (not st.energyStalling or stallBypass) then
                        if B.CanAffordBuild(dID, false) then
                            defID = dID
                        end
                    end
                end

                if not defID and #cache.defensesAA > 0 then
                    local dID = B.SelectBalancedDefense(cache.defensesAA, st.currentMetal)
                    local turretCost = (UnitDefs[dID] and UnitDefs[dID].metalCost) or 1
                    local airFacs = 0
                    for j = 1, st.myFactoriesCount do
                        if U.IsAirFactory(spGetUnitDefID(st.myFactories[j])) then airFacs = airFacs + 1 end
                    end
                    local targetAA = cfg.BASE_AA_DEF_TARGET + st.myFactoriesCount * cfg.DEFENSE_MIN_PER_FACTORY + airFacs * cfg.AA_PER_AIR_FACTORY
                        + math.floor((st.enemyArmyValue or 0) / (turretCost * cfg.DEFENSE_ARMY_TURRET_RATIO * 2))
                    if (st.defenseAACount or 0) < targetAA and (not st.metalStalling or underPressure) and (not st.energyStalling or underPressure) then
                        if B.CanAffordBuild(dID, false) then
                            defID = dID
                        end
                    end
                end

                if defID then
                    local dAx, dAz = st.baseCenterX, st.baseCenterZ
                    if not dAx then dAx, dAz = buildAnchorX, buildAnchorZ end
                    local step = cfg.DEF_LINE_STEP * (st.mapLinearScale or 1)
                    local ringR = mMax(250, (st.baseRadius or 0) + 120)
                    local tAx, tAz
                    -- Face the nearest scouted enemy base: turrets form a
                    -- defensive line along the threat axis instead of a
                    -- random scatter.
                    local ebx, ebz, ebest = nil, nil, math.huge
                    for _, b in pairs(st.enemyBases or {}) do
                        if b.x and b.z then
                            local bdx, bdz = b.x - dAx, b.z - dAz
                            local bd = bdx * bdx + bdz * bdz
                            if bd < ebest then ebest, ebx, ebz = bd, b.x, b.z end
                        end
                    end
                    if ebx then
                        local fdx2, fdz2 = ebx - dAx, ebz - dAz
                        local fl2 = math.sqrt(fdx2 * fdx2 + fdz2 * fdz2)
                        if fl2 > 1 then fdx2, fdz2 = fdx2 / fl2, fdz2 / fl2 else fdx2, fdz2 = 1, 0 end
                        local k = (st.defLineIndex or 0) % mMax(1, cfg.DEF_LINE_TOWARDS_ENEMY)
                        st.defLineIndex = (st.defLineIndex or 0) + 1
                        local r = ringR + k * step
                        local ang = math.atan2(fdz2, fdx2) + (math.random() - 0.5) * 0.5
                        tAx = dAx + mCos(ang) * r
                        tAz = dAz + mSin(ang) * r
                    else
                        local fdx, fdz = facDirX, facDirZ
                        local fl = math.sqrt(fdx * fdx + fdz * fdz)
                        if fl < 1 then fdx, fdz = 1, 0 else fdx, fdz = fdx / fl, fdz / fl end
                        local ang = math.atan2(fdz, fdx) + (math.random() - 0.5) * math.pi * 1.2
                        tAx = dAx + mCos(ang) * ringR
                        tAz = dAz + mSin(ang) * ringR
                    end
                    tx, ty, tz, facing, key = B.FindBuildSpot(tAx, tAz, defID, cfg.TURRET_SPACING, unitID, conBuildDist)
                    if tx then claimRadius = cfg.TURRET_SPACING end
                end
            end

            -- Build antinuke when we can, and try to optimally cover the base
            if not tx and #cache.antinukes > 0 then
                local anDefID = cache.antinukes[#cache.antinukes]
                local covR = cfg.GetAntiNukeCoverage(anDefID) or 0
                local baseR = st.baseRadius or 0
                local target = 1
                if covR > 0 and baseR > covR then
                    target = math.ceil((baseR / covR) * (baseR / covR))
                end
                local current = (st.antinukeCount or 0) + (st.pendingAntinukeBlueprints or 0)
                if current < target and not st.metalStalling and not st.energyStalling then
                    if B.CanAffordBuild(anDefID, false) then
                        defID = anDefID
                        local nAx, nAz = st.baseCenterX, st.baseCenterZ
                        if not nAx then nAx, nAz = buildAnchorX, buildAnchorZ end
                        local ax, az = nAx, nAz
                        if current > 0 then
                            ax, az = cfg.GetSpreadPos(current + 1, nAx, nAz, covR * 0.5, mMax(covR, baseR))
                        end
                        tx, ty, tz, facing, key = B.FindBuildSpot(ax, az, defID, cfg.BUILD_SPACING, unitID, conBuildDist)
                        if tx then claimRadius = cfg.ANTI_NUKE_KEEPOUT end
                    end
                end
            end

            -- Commander must never idle: keep chaining mex/wind even when the
            -- macro budgets above are satisfied (start-of-game uptime matters).
            if not tx and uDef.isCommander and not E.IsUnitBuildingFactory(unitID) then
                local cmdMex, cmdMexCost = nil, mHuge
                for i = #cache.mex, 1, -1 do
                    local cost = UnitDefs[cache.mex[i]] and UnitDefs[cache.mex[i]].metalCost or mHuge
                    if cost < cmdMexCost then cmdMexCost, cmdMex = cost, cache.mex[i] end
                end
                if cmdMex and st.unclaimedMexCount > 0 and B.CanAffordBuild(cmdMex, true) then
                    defID = cmdMex
                    tx, ty, tz, facing, key = B.FindBuildSpot(ux, uz, defID, st.metalMapMexSpacing, unitID, conBuildDist, nil, nil, nil, true)
                    if tx then
                        claimRadius = st.metalMapMexSpacing * 0.5
                        st.activeMexBuilders = st.activeMexBuilders + 1
                        mexCluster = true
                    end
                end
                if not tx then
                    local cID = nil
                    for i = 1, #cache.energyAdv do
                        local aN = UnitDefs[cache.energyAdv[i]] and sLower(UnitDefs[cache.energyAdv[i]].name or "") or ""
                        if sFind(aN, "fusion") or sFind(aN, "afus") then
                            if st.afusLocked or B.CanAffordBuild(cache.energyAdv[i], false) then
                                cID = cache.energyAdv[i]
                                afusRow = true
                                st.afusLocked = true
                            end
                            break
                        end
                    end
                    if not cID and not st.afusLocked then cID = (hasWind and #cache.energyWind > 0) and cache.energyWind[1] or (#cache.energySolar > 0 and cache.energySolar[1] or nil) end
                    if cID and B.CanAffordBuild(cID, true) then
                        defID = cID
                        local cCost = UnitDefs[cID].metalCost or 0
                        local cSpacing = (cCost > 4000) and 192 or cfg.ENERGY_GRID_SPACING
                        local cAx, cAz = clampAnchor(ux, uz)
                        tx, ty, tz, facing, key = B.FindBuildSpot(cAx, cAz, defID, cSpacing, unitID, conBuildDist, nil, nil, nil, true)
                        if tx then
                            claimRadius = cSpacing * 0.5
                            st.activeEnergyBuilders = st.activeEnergyBuilders + 1
                            rowBuild = true
                        end
                    end
                end
            end

            if tx and defID then
                local isFac = UnitDefs[defID] and UnitDefs[defID].isFactory
                local isMex = UnitDefs[defID] and UnitDefs[defID].extractsMetal and UnitDefs[defID].extractsMetal > 0
                local isAntinuke = cfg.IsAntiNukeDef(defID)
                st.claimedSpots[key] = { frame = frame, x = tx, z = tz, r2 = claimRadius * claimRadius, isFactory = isFac, isAirFactory = isFac and U.IsAirFactory(defID), facing = facing, defID = defID, isMex = isMex, isAntinuke = isAntinuke }
                st.pendingCommittedMetal = st.pendingCommittedMetal + (UnitDefs[defID] and UnitDefs[defID].metalCost or 0)
                if isFac then st.pendingFactoryBlueprints = st.pendingFactoryBlueprints + 1 end
                if isAntinuke then st.pendingAntinukeBlueprints = st.pendingAntinukeBlueprints + 1 end
                if rowBuild then
                    local queuedN = QueueEcoRow(unitID, defID, tx, ty, tz, afusRow and cfg.AFUS_ROW_COUNT or ecoRowLen)
                    -- account for every queued cell, not just the anchor
                    st.pendingCommittedMetal = st.pendingCommittedMetal + mMax(0, queuedN - 1) * ((UnitDefs[defID] and UnitDefs[defID].metalCost) or 0)
                else
                    spGiveOrderToUnit(unitID, -defID, { tx, ty, tz, facing }, {})
                end
                -- Mex rows: queue more spots in one trip. Spots are fixed by
                -- the map, so we chain each new spot to the CLOSEST unclaimed
                -- neighbour of the last placed one -> contiguous tight lines.
                if mexCluster and isMex then
                    local clusterCap = ecoRowLen
                    if #st.metalSpots == 0 then
                        -- uniform-metal map: geometric tight row like winds
                        local queuedN = QueueEcoRow(unitID, defID, tx, ty, tz, clusterCap)
                        st.pendingCommittedMetal = st.pendingCommittedMetal + mMax(0, queuedN - 1) * ((UnitDefs[defID] and UnitDefs[defID].metalCost) or 0)
                    else
                        local grabbed = 1
                        local pool = {}
                        local spots = st.unclaimedMetalSpots or {}
                        for i = 1, #spots do
                            local spt = spots[i]
                            local dxs, dzs = spt.x - tx, spt.z - tz
                            local d2 = dxs * dxs + dzs * dzs
                            if d2 > 0 and d2 < cfg.MEX_CLUSTER_RADIUS_SQ then pool[#pool + 1] = { x = spt.x, z = spt.z } end
                        end
                        local lastX, lastZ = tx, tz
                        while grabbed < clusterCap and #pool > 0 do
                            local bi, bd2 = nil, mHuge
                            for i = 1, #pool do
                                local dxs, dzs = pool[i].x - lastX, pool[i].z - lastZ
                                local d2 = dxs * dxs + dzs * dzs
                                if d2 < bd2 then bd2, bi = d2, i end
                            end
                            if not bi or bd2 > cfg.MEX_CLUSTER_RADIUS_SQ then break end
                            local spt = table.remove(pool, bi)
                            local ax, ay, az, af, akey = B.FindBuildSpot(spt.x, spt.z, defID, st.metalMapMexSpacing, unitID, conBuildDist * 0.75, nil, nil, nil, true)
                            if ax then
                                st.claimedSpots[akey] = { frame = frame, x = ax, z = az, r2 = (st.metalMapMexSpacing * 0.5) * (st.metalMapMexSpacing * 0.5), isFactory = false, isAirFactory = false, facing = af, defID = defID, isMex = true }
                                st.pendingCommittedMetal = st.pendingCommittedMetal + ((UnitDefs[defID] and UnitDefs[defID].metalCost) or 0)
                                spGiveOrderToUnit(unitID, -defID, { ax, ay, az, af }, { "shift" })
                                grabbed = grabbed + 1
                                lastX, lastZ = ax, az
                            end
                        end
                    end
                end
            else
                if not tx and (st.unclaimedMexCount > 0 or #st.metalSpots == 0) then
                    local fDeficit = mMax(0, (st.metalPull or 0) - (st.metalIncome or 0))
                    local fBudget = mMax(1, math.ceil(fDeficit / cfg.GetMexGain()))
                    if (st.metalIncome or 0) < (cfg.METAL_MAP_MEX_INCOME_TARGET * st.mapAreaScale) then fBudget = mMax(fBudget, math.ceil(cfg.MEX_GROWTH_FLOOR * st.mapAreaScale)) end
                    if st.activeMexBuilders < fBudget and #cache.mex > 0 then
                        local mexID = cache.mex[#cache.mex]
                        if B.CanAffordBuild(mexID, true) then
                            local mx, my, mz, mf, mkey = B.FindBuildSpot(ux, uz, mexID, st.metalMapMexSpacing, unitID, conBuildDist, nil, nil, nil, true)
                            if mx then
                                local mDef = UnitDefs[mexID]
                                st.claimedSpots[mkey] = { frame = frame, x = mx, z = mz, r2 = (st.metalMapMexSpacing * 0.5) * (st.metalMapMexSpacing * 0.5), isFactory = false, isAirFactory = false, facing = mf, defID = mexID, isMex = true }
                                st.pendingCommittedMetal = st.pendingCommittedMetal + (mDef and mDef.metalCost or 0)
                                spGiveOrderToUnit(unitID, -mexID, { mx, my, mz, mf }, {})
                                return
                            end
                        end
                    end
                end

                if not tx and st.unclaimedMexCount > 0 then
                    local spot = E.GetNearestUnclaimedMetalSpot(ux, uz)
                    if spot then
                        local dx, dz = spot.x - ux, spot.z - uz
                        if dx*dx + dz*dz > 200*200 and (not E.IsUnitBuildingFactory(unitID)) then
                            local sx, sz = U.GetFlankSpreadPos(unitID, spot.x, spot.z, cfg.ANTI_CLUMP_MIN, cfg.ANTI_CLUMP_MAX, nil)
                            spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { sx, spGetGroundHeight(sx, sz), sz }, {}) return
                        end
                    end
                end

                -- clear blocked factory exits first: big units need a way out
                if st.myFactoriesCount > 0 then
                    for j = 1, st.myFactoriesCount do
                        local fx, _, fz = spGetUnitPosition(st.myFactories[j])
                        if fx then
                            local ex, ez = fx + (facDirX or 0) * 160, fz + (facDirZ or 0) * 160
                            local exitWreck = W.FindReclaimTarget(ex, ez, true, 220)
                            if exitWreck then
                                spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
                                spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { exitWreck + (Game.maxUnits or 32768) }, {})
                                return
                            end
                        end
                    end
                end

                local recT = W.FindReclaimTarget(ux, uz, true, uDef.buildDistance or 200)
                if recT then
                    spGiveOrderToUnit(unitID, cfg.CMD_RECLAIM, { recT + (Game and Game.maxUnits or 32768) }, {})
                    return
                end

                if uDef.buildOptions then
                    local repairSet = {}
                    for i = 1, #uDef.buildOptions do repairSet[uDef.buildOptions[i]] = true end
                    local repairT, repairD = nil, mHuge
                    local scanUnits = spGetUnitsInCylinder(ux, uz, (uDef.buildDistance or 200) + 500)
                    if scanUnits then
                        for i = 1, #scanUnits do
                            local nID = scanUnits[i]
                            local nTeam = spGetUnitTeam(nID)
                            if nTeam == myTeamID and nID ~= unitID then
                                local nDefID = spGetUnitDefID(nID)
                                if nDefID and repairSet[nDefID] then
                                    local nhp, nmax = spGetUnitHealth(nID)
                                    if nhp and nmax and nmax > 0 and nhp < nmax then
                                        local nx, _, nz = spGetUnitPosition(nID)
                                        if nx then
                                            local d = (nx-ux)*(nx-ux) + (nz-uz)*(nz-uz)
                                            if d < repairD then repairD, repairT = d, nID end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if repairT then
                        spGiveOrderToUnit(unitID, cfg.CMD_REPAIR, { repairT }, {})
                        return
                    end
                end

                -- nothing to reclaim or repair
                local bx, bz = st.baseCenterX or ux, st.baseCenterZ or uz
                local dx, dz = bx - ux, bz - uz
                if dx*dx + dz*dz > 400*400 and (not E.IsUnitBuildingFactory(unitID)) then
                    spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { bx, spGetGroundHeight(bx, bz), bz }, {})
                elseif (not E.IsUnitBuildingFactory(unitID)) then
                    local patAngle = ((unitID % 251) + 1) * 0.025
                    local patR = (st.baseRadius or 0) > 0 and st.baseRadius or 500
                    local pmx, pmz = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
                    local px = mMax(100, mMin(bx + mCos(patAngle) * patR, pmx - 100))
                    local pz = mMax(100, mMin(bz + mSin(patAngle) * patR, pmz - 100))
                    spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { px, spGetGroundHeight(px, pz), pz }, {})
                end
            end
        end

    elseif not uDef.isFactory and uDef.speed and uDef.speed > 0 then
        local ux, uy, uz = spGetUnitPosition(unitID)
        if not ux then return end

        if uDef.weapons and #uDef.weapons > 0 and not st.fireStateSet[unitID] then
            spGiveOrderToUnit(unitID, CMD_FIRE_STATE, {2}, {})
            st.fireStateSet[unitID] = true
        end

        if uDef.canFly and cfg.CMD_FLY and not st.flyStateSet[unitID] then
            spGiveOrderToUnit(unitID, cfg.CMD_FLY, { 0 }, 0)
            st.flyStateSet[unitID] = true
        end

        local isScout = false
        if not isTrapperUnit and not uDef.canResurrect and not uDef.isBuilder then
            isScout = U.IsScoutDef(uDef)
        end
        if isScout then
            local needs = NeedsOrders(unitID, false, true, false)
            if not needs then
                local cs = spGetUnitCommands(unitID, 1)
                local c1 = cs and cs[1]
                if c1 and c1.id == cfg.CMD_GUARD then needs = true end
            end
            -- new intel
            if not needs then
                if (st.scoutIntelVersion[unitID] or 0) ~= st.intelVersion then
                    needs = true
                end
            end
            if needs then
                local baseBX, baseBZ = st.baseCenterX, st.baseCenterZ
                -- Bring all the scouts back during a raid
                -- The proper solution is for the bot to just use radar,
                -- but that's easier said then done, which makes this a
                -- TODO: make the bot understand radar
                if baseBX and ((st.unease or 0) > 0 or (unitID % 3) == 0) then
                    local ringR = (st.baseRadius or 400) + (cfg.PERIMETER_PATROL_RING * st.mapLinearScale)
                    local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
                    local allyTeam = Spring.GetMyAllyTeamID()
                    local baseAng = math.atan2(uz - baseBZ, ux - baseBX)
                    local step = (2 * math.pi) / cfg.PERIMETER_PATROL_PROBES
                    local px, pz = nil, nil
                    for pi = 1, cfg.PERIMETER_PATROL_PROBES do
                        local a = baseAng + pi * step
                        local qx = mMax(50, mMin(baseBX + mCos(a) * ringR, mapX - 50))
                        local qz = mMax(50, mMin(baseBZ + mSin(a) * ringR, mapZ - 50))
                        if not Spring.IsPosInLos(qx, spGetGroundHeight(qx, qz), qz, allyTeam) then
                            px, pz = qx, qz
                            break
                        end
                    end
                    if not px then
                        px = mMax(50, mMin(baseBX + mCos(baseAng + step) * ringR, mapX - 50))
                        pz = mMax(50, mMin(baseBZ + mSin(baseAng + step) * ringR, mapZ - 50))
                    end
                    spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { px, spGetGroundHeight(px, pz), pz }, {})
                else
                    if not I.AssignScoutOrder(unitID, frame) then
                        -- push toward the enemy / unknown, don't be idle
                        W.PushFrontier(unitID, ux, uz)
                    end
                end
                st.scoutIntelVersion[unitID] = st.intelVersion
            end
            return
        end

        local curCmds = spGetUnitCommands(unitID, 1)
        local curCmd = curCmds and curCmds[1]
        local curCmdId = curCmd and curCmd.id
        
        if curCmdId == cfg.CMD_ATTACK then
            if uDef.canFly then
                local curParams = curCmd and curCmd.params
                local maxRange = cfg.GetGroundRange(uDefID)
                local shouldStop = false
                local myTeam = spGetMyTeamID()

                if curParams then
                    if #curParams == 1 and type(curParams[1]) == "number" then
                        -- is the unit still alive?
                        local tID = curParams[1]
                        local hp = spGetUnitHealth(tID)
                        if not hp or hp <= 0 then shouldStop = true end
                    elseif #curParams >= 3 then
                        local tX, tZ = curParams[1], curParams[3]
                        if not Spring.IsPosInLos(tX, 0, tZ, spGetMyAllyTeamID()) then return end
                        local targetRadius = mMax(maxRange * 0.6, cfg.AOE_DAMAGE_RADIUS * 1.5)
                        local enemiesAtPos = spGetUnitsInCylinder(tX, tZ, targetRadius)
                        local foundAlive = false
                        if enemiesAtPos then
                            for i = 1, #enemiesAtPos do
                                local tID = enemiesAtPos[i]
                                local tTeam = spGetUnitTeam(tID)
                                if tTeam and tTeam ~= myTeam and not spAreTeamsAllied(myTeam, tTeam) then
                                    local hp = spGetUnitHealth(tID)
                                    if hp and hp > 0 then foundAlive = true break end
                                end
                            end
                        end
                        if not foundAlive then shouldStop = true end
                    else
                        -- treat as stale
                        shouldStop = true
                    end
                else
                    shouldStop = true
                end

                if not shouldStop then return end

                -- target is gone, clear the stale order
                spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
            end

            -- I really would love to not have to have this here
            -- But I can't diagnose why they're getting attack commands
            spGiveOrderToUnit(unitID, CMD_STOP, {}, {})
        end
        if cfg.IsAntiNukeDef(uDefID) then
            local bx, bz = st.baseCenterX or ux, st.baseCenterZ or uz
            local baseR = st.baseRadius or 0
            local cov = cfg.GetAntiNukeCoverage(uDefID)
            if cov <= 0 then cov = 1600 end
            local ringR = mMax(250, mMin(baseR, cov * 0.6))
            local px, pz = U.GetFlankSpreadPos(unitID, bx, bz, ringR, ringR + 200, nil)
            local dx, dz = px - ux, pz - uz
            if dx * dx + dz * dz > 160 * 160 then
                local cs = spGetUnitCommands(unitID, 1)
                local c1 = cs and cs[1]
                local alreadyGoing = c1 and c1.id == cfg.CMD_MOVE and c1.params and c1.params[1] and c1.params[3]
                    and (c1.params[1] - px) * (c1.params[1] - px) + (c1.params[3] - pz) * (c1.params[3] - pz) < 160 * 160
                if not alreadyGoing then
                    spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { px, spGetGroundHeight(px, pz), pz }, {})
                end
            end
            return
        end

        local hasWeapons = uDef.weapons and #uDef.weapons > 0
        -- Artillery shouldn't try moving in, fire from the range limit
        -- because it's very fragile.
        local isArty = hasWeapons and cfg.GetGroundRange(uDefID) > 850
        local isRadar = (uDef.radarDistance and uDef.radarDistance > 500 and not hasWeapons) or (uDef.sonarDistance and uDef.sonarDistance > 500 and not hasWeapons) or sFind(name, "radar")
        local isJammer = (uDef.radarDistanceJam and uDef.radarDistanceJam > 0) or (uDef.sonarDistanceJam and uDef.sonarDistanceJam > 0) or sFind(name, "jammer") or sFind(name, "jam")
        local unitGroup = uDef.customParams and uDef.customParams.unitgroup
        -- I had some issues with units like the sol invictus getting classified as
        -- support units because they have an AA gun and they're a ground unit.
        -- Let's deal with that over here.
        local isDedicatedAA = (unitGroup == "aa")
        local isSupport = false
        if sFind(name, "antinuke") or sFind(name, "nuke") or unitGroup == "antinuke" or isRadar or isJammer or isDedicatedAA then isSupport = true end
        -- Fallback for a lack of the `unitgroup` customParam
        if not isDedicatedAA and unitGroup == nil and hasWeapons then
            for wi = 1, #uDef.weapons do
                local wDef = U.SafeGetWeaponDef(uDef.weapons[wi].weaponDef)
                if wDef and (sFind(sLower(wDef.name or ""), "flak") or sFind(sLower(wDef.type or ""), "aa")) then isSupport = true break end
            end
        end

        -- scouts have already returned above, so only non-scouts reach here
        local myTeamID = spGetMyTeamID()
        local supportType = nil
        if isRadar and isJammer then supportType = "both"
        elseif isRadar then supportType = "radar"
        elseif isJammer then supportType = "jammer"
        elseif isDedicatedAA then supportType = "aa" end

        if isSupport then
            if NeedsOrders(unitID, false, true, false) then
                local locks = st.supportGuardOwners

                local fdx, fdz = nil, nil
                local refX, refZ = st.baseCenterX or ux, st.baseCenterZ or uz
                local bestD = mHuge
                for _, b in pairs(st.enemyBases) do
                    if b.lastSeen then
                        local dx, dz = b.x - refX, b.z - refZ
                        local d = dx*dx + dz*dz
                        if d < bestD then bestD, fdx, fdz = d, dx, dz end
                    end
                end
                if not fdx then
                    if st.frontierX then fdx, fdz = st.frontierX - refX, st.frontierZ - refZ
                    else fdx, fdz = (Game.mapSizeX or 8192) * 0.5 - refX, (Game.mapSizeZ or 8192) * 0.5 - refZ end
                end
                local fl = math.sqrt(fdx*fdx + fdz*fdz)
                if fl < 1 then fl = 1 end
                fdx, fdz = fdx / fl, fdz / fl

                -- Move to a point behind the guarded unit (away from the enemy),
                -- I can see issues if the unit we're guarding is faster than us
                -- TODO: Look into this?
                local function MoveBehind(tx, tz)
                    local bx = tx - fdx * cfg.SUPPORT_BEHIND_DIST
                    local bz = tz - fdz * cfg.SUPPORT_BEHIND_DIST
                    local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
                    bx = mMax(50, mMin(bx, mapX - 50))
                    bz = mMax(50, mMin(bz, mapZ - 50))
                    local cs2 = spGetUnitCommands(unitID, 1)
                    local c2 = cs2 and cs2[1]
                    if c2 and c2.id == cfg.CMD_MOVE and c2.params and c2.params[1] and c2.params[3] then
                        local dx, dz = bx - c2.params[1], bz - c2.params[3]
                        if dx*dx + dz*dz < 80*80 then return end
                    end
                    spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { bx, spGetGroundHeight(bx, bz), bz }, {})
                end

                local function isTargetLocked(t)
                    if not supportType or not t then return false end
                    if (supportType == "radar" or supportType == "both") and locks.radar[t] then return true end
                    if (supportType == "jammer" or supportType == "both") and locks.jammer[t] then return true end
                    if supportType == "aa" and locks.aa[t] then return true end
                    return false
                end
                local function pickTarget(preferred)
                    if preferred and not isTargetLocked(preferred) then return preferred end
                    for i = 1, st.myCombatUnitCount do
                        local c = st.myCombatUnits[i]
                        if not isTargetLocked(c) then return c end
                    end
                    for i = 1, st.myFactoriesCount do
                        local f = st.myFactories[i]
                        if not isTargetLocked(f) then
                            -- skip a waited lab, there is nothing to
                            -- support there. we're fine with under construction labs
                            local fwaited = st.factoryWaitState[f]
                            if fwaited then
                                local fhp, fmax = spGetUnitHealth(f)
                                if fhp and fmax and fhp < fmax then fwaited = false end
                            end
                            if not fwaited then return f end
                        end
                    end
                    return nil
                end

                local curTarget = st.supportTarget[unitID]

                -- keep following the current target if we still own its lock
                if curTarget and spGetUnitDefID(curTarget) then
                    local keep = true
                    -- drop a support parked behind a waited lab: nothing to support
                    if st.factoryWaitState[curTarget] then
                        local thp, tmax = spGetUnitHealth(curTarget)
                        if thp and tmax and thp >= tmax then keep = false end
                    end
                    if keep then
                        if supportType then
                            keep = false
                            if (supportType == "radar" or supportType == "both") and locks.radar[curTarget] == unitID then keep = true end
                            if (supportType == "jammer" or supportType == "both") and locks.jammer[curTarget] == unitID then keep = true end
                            if supportType == "aa" and locks.aa[curTarget] == unitID then keep = true end
                        end
                        if keep then
                            local tx, _, tz = spGetUnitPosition(curTarget)
                            if tx then MoveBehind(tx, tz) end
                            return
                        end
                    end
                    st.supportTarget[unitID] = nil
                end

                -- pick any unlocked combat unit / factory.
                local target = pickTarget(nil)

                if target then
                    st.supportTarget[unitID] = target
                    -- claim the exclusive lock
                    if supportType == "radar" or supportType == "both" then locks.radar[target] = unitID end
                    if supportType == "jammer" or supportType == "both" then locks.jammer[target] = unitID end
                    if supportType == "aa" then locks.aa[target] = unitID end
                    local tx, _, tz = spGetUnitPosition(target)
                    if tx then MoveBehind(tx, tz) end
                    return
                end
                -- If there's nothing for our support unit to do, just move
                -- forward with the rest of the army
                W.PushFrontier(unitID, ux, uz)
            end
            return
        end

        -- we don't care about microing against enemy raiders
        -- we need to kill them fast, and hopefully possibly distract them
        local nearRaid = st.currentDefenders[unitID] == true

        local hp, maxHp = spGetUnitHealth(unitID)

        -- we don't want to get caught in the blast
        if st.selfDingCount > 0 then
            local blastX, blastZ, blastR = nil, nil, 0
            for i = 1, st.selfDingCount do
                local b = st.selfDingUnits[i]
                if b.id ~= unitID then
                    local br = b.blastRadius or 0
                    local dx, dz = b.x - ux, b.z - uz
                    if dx * dx + dz * dz < br * br then
                        blastX, blastZ, blastR = b.x, b.z, br
                        break
                    end
                end
            end
            if blastX then
                local awayX, awayZ = ux - blastX, uz - blastZ
                local awayLen = math.sqrt(awayX * awayX + awayZ * awayZ)
                if awayLen < 1 then awayX, awayZ, awayLen = 1, 0, 1 end
                local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
                local fx = mMax(50, mMin(ux + (awayX / awayLen) * blastR, mapX - 50))
                local fz = mMax(50, mMin(uz + (awayZ / awayLen) * blastR, mapZ - 50))
                spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { fx, spGetGroundHeight(fx, fz), fz }, {})
                return
            end
        end

        local selfDBlastRadius = cfg.GetSelfDBlastRadius(uDefID)
        if not nearRaid and not uDef.canFly and selfDBlastRadius >= cfg.SELFD_MIN_BLAST_RADIUS then
            local selfdActive = Spring.GetUnitSelfDTime(unitID) > 0
            local lowHP = hp and maxHp and maxHp > 0 and (hp / maxHp) < cfg.SELFD_HP_RATIO
            if selfdActive or lowHP then
                -- weight the threat
                local enemyX, enemyZ, enemyDistSq, enemyMetal = nil, nil, mHuge, 0
                local scan = spGetUnitsInCylinder(ux, uz, selfDBlastRadius * 2)
                if scan then
                    for i = 1, #scan do
                        local tID = scan[i]
                        local tTeam = spGetUnitTeam(tID)
                        if tTeam and tTeam ~= myTeamID and not spAreTeamsAllied(myTeamID, tTeam) then
                            local tDef = UnitDefs[spGetUnitDefID(tID)]
                            if tDef and tDef.speed and tDef.speed > 0 then
                                local ex, _, ez = spGetUnitPosition(tID)
                                if ex then
                                    enemyMetal = enemyMetal + (tDef.metalCost or 50)
                                    local d = (ex - ux) * (ex - ux) + (ez - uz) * (ez - uz)
                                    if d < enemyDistSq then enemyDistSq, enemyX, enemyZ = d, ex, ez end
                                end
                            end
                        end
                    end
                end

                if enemyX and enemyMetal >= (uDef.metalCost or 100) * cfg.SELFD_DOOM_RATIO then
                    -- start self d timer
                    if not selfdActive then
                        spGiveOrderToUnit(unitID, cfg.CMD_SELFD, {}, {})
                    end
                    -- let's go towards the enemies base, strong units like
                    -- the juggernaut have self d explosions similar to nukes
                    -- Niche, but to my knowledge, self d-ing a nuke silo has
                    -- a similar effect, lets add this as a TODO: look into this 
                    local marchX, marchZ, mDistSq = enemyX, enemyZ, mHuge
                    for _, b in pairs(st.enemyBases) do
                        if b.x and b.z then
                            local d = (b.x - ux) * (b.x - ux) + (b.z - uz) * (b.z - uz)
                            if d < mDistSq then mDistSq, marchX, marchZ = d, b.x, b.z end
                        end
                    end
                    local cs = spGetUnitCommands(unitID, 1)
                    local c1 = cs and cs[1]
                    local alreadyGoing = c1 and c1.id == cfg.CMD_MOVE and c1.params and c1.params[1] and c1.params[3]
                        and (c1.params[1] - marchX) * (c1.params[1] - marchX) + (c1.params[3] - marchZ) * (c1.params[3] - marchZ) < 160 * 160
                    if not alreadyGoing then
                        spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { marchX, spGetGroundHeight(marchX, marchZ), marchZ }, {})
                    end
                    return
                elseif selfdActive then
                    -- Don't self d if the attackers are gone
                    spGiveOrderToUnit(unitID, cfg.CMD_SELFD, {}, {})
                end
            end
        end

        if not nearRaid and hp and maxHp and maxHp > 0 and (hp / maxHp) < cfg.RETREAT_HEALTH_RATIO then
            local threatX, threatZ, threatDistSq = nil, nil, mHuge
            local enemyDPS, enemyHP = 0, 0
            local nearby = spGetUnitsInCylinder(ux, uz, cfg.TANGENTIAL_RETREAT_DIST)
            if nearby then
                for i = 1, #nearby do
                    local tID = nearby[i]
                    local tTeam = spGetUnitTeam(tID)
                    if tTeam and tTeam ~= myTeamID and not spAreTeamsAllied(myTeamID, tTeam) then
                        local tDefID = spGetUnitDefID(tID)
                        local tDPS = tDefID and cfg.GetUnitDPS(tDefID) or 0
                        if tDPS > 0 then
                            enemyDPS = enemyDPS + tDPS
                            local thp = spGetUnitHealth(tID)
                            if thp and thp > 0 then
                                enemyHP = enemyHP + thp
                            else
                                local tDef = UnitDefs[tDefID]
                                enemyHP = enemyHP + (tDef and tDef.maxHealth or 100)
                            end
                            local tx, _, tz = spGetUnitPosition(tID)
                            if tx then
                                local dx, dz = tx - ux, tz - uz
                                local d = dx*dx + dz*dz
                                if d < threatDistSq then threatDistSq, threatX, threatZ = d, tx, tz end
                            end
                        end
                    end
                end
            end

            local shouldRetreat = false
            if threatX and enemyDPS > 0 then
                local ourDPS = cfg.GetUnitDPS(uDefID)
                if ourDPS <= 0 then
                    shouldRetreat = true
                else
                    shouldRetreat = (hp / enemyDPS) < (enemyHP / ourDPS)
                end
            end
            if shouldRetreat
                and threatDistSq < (cfg.TANGENTIAL_RETREAT_DIST * cfg.TANGENTIAL_RETREAT_DIST) then
                local retreatDist = mMin(1200, mMax(450, (uDef.speed or 100) * 3.0))
                local tx, tz
                if U.CanStrafeByDefID(uDefID) then
                    local awayX, awayZ = ux - threatX, uz - threatZ
                    local awayLen = math.sqrt(threatDistSq)
                    if awayLen < 1 then awayX, awayZ, awayLen = 1, 0, 1 end
                    tx = ux + (awayX / awayLen) * retreatDist
                    tz = uz + (awayZ / awayLen) * retreatDist
                else
                    tx, tz = cfg.GetTangentialRetreat(unitID, ux, uz, threatX, threatZ, retreatDist)
                end
                local ty = spGetGroundHeight(tx, tz)
                spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { tx, ty, tz }, {})
                return
            end

        end

        if hasWeapons then
            local maxRange = cfg.GetGroundRange(uDefID)
            local airRange = mMax(maxRange, cfg.GetAAWeaponRange(uDefID))
            if maxRange > 200 then
                local cmds = spGetUnitCommands(unitID, -1)
                local cmd1 = cmds and cmds[1]
                
                local searchRadius = airRange + 400
                local cx, cy, cz, bestID, clusterSize, bestMetal, isGround =
                    W.FindBestClusterTarget(ux, uz, searchRadius, cfg.AOE_DAMAGE_RADIUS, uDefID)

                if cfg.IsJunoBomberDef(uDefID) then
                    local myTeam = spGetMyTeamID()
                    local gaia = spGetGaiaTeamID()
                    local jID, jDistSq, jX, jZ = nil, mHuge, nil, nil
                    local nearby = spGetUnitsInCylinder(ux, uz, 2500)
                    if nearby then
                        for i = 1, #nearby do
                            local tID = nearby[i]
                            local tTeam = spGetUnitTeam(tID)
                            if tTeam and tTeam ~= myTeam and tTeam ~= gaia and not spAreTeamsAllied(myTeam, tTeam) then
                                local tDef = UnitDefs[spGetUnitDefID(tID)]
                                if tDef and (not tDef.speed or tDef.speed == 0) and cfg.IsJunoVulnerableDef(tDef) then
                                    local tx, _, tz = spGetUnitPosition(tID)
                                    if tx then
                                        local d = (tx - ux) * (tx - ux) + (tz - uz) * (tz - uz)
                                        if d < jDistSq then
                                            jDistSq, jID, jX, jZ = d, tID, tx, tz
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if jID then
                        bestID = jID
                        cx, cy, cz = jX, spGetGroundHeight(jX, jZ), jZ
                        clusterSize, bestMetal, isGround = 1, 0, false
                    else
                        -- Linger near the frontline or enemy base so the bomber is ready to go
                        local bx = st.army.targetX or st.baseCenterX or ux
                        local bz = st.army.targetZ or st.baseCenterZ or uz
                        local alreadyGoing = cmd1 and cmd1.id == cfg.CMD_MOVE and cmd1.params and cmd1.params[1] and cmd1.params[3]
                            and (cmd1.params[1] - bx) * (cmd1.params[1] - bx) + (cmd1.params[3] - bz) * (cmd1.params[3] - bz) < 200 * 200
                        if not alreadyGoing then
                            spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { bx, spGetGroundHeight(bx, bz), bz }, {})
                        end
                        return
                    end
                end

                if not bestID and cfg.IsBomberDef(uDefID) then
                    local bX, bY, bZ = cfg.FindBombTargetFromMemory(ux, uz)
                    if bX then
                        local alreadyBombing = cmd1 and cmd1.id == cfg.CMD_ATTACK and cmd1.params
                            and cmd1.params[1] and cmd1.params[3]
                            and (cmd1.params[1] - bX) * (cmd1.params[1] - bX) + (cmd1.params[3] - bZ) * (cmd1.params[3] - bZ) < 200 * 200
                        if not alreadyBombing then
                            if st.attackDbg then
                                st.attackDbg.issued = st.attackDbg.issued + 1
                                st.attackDbg.airIssued = st.attackDbg.airIssued + 1
                                st.attackDbg.lastIssuedDef = uDef.name
                            end
                            spGiveOrderToUnit(unitID, cfg.CMD_ATTACK, { bX, bY or 0, bZ }, {})
                        end
                        return
                    end
                end

            if bestID then
                    if nearRaid and not uDef.canFly then
                        local raiderX, _, raiderZ = spGetUnitPosition(bestID)
                        if not raiderX then raiderX, raiderZ = cx, cz end
                        local alreadyCharging = false
                        if cmd1 and cmd1.id == cfg.CMD_MOVE and cmd1.params and cmd1.params[1] and cmd1.params[3] then
                            local ddx, ddz = raiderX - cmd1.params[1], raiderZ - cmd1.params[3]
                            if ddx*ddx + ddz*ddz < 160*160 then alreadyCharging = true end
                        end
                        if not alreadyCharging then
                            spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { raiderX, spGetGroundHeight(raiderX, raiderZ), raiderZ }, {})
                        end
                        return
                    end

                    if uDef.canFly then
                        local alreadyAttacking = false
                        if cmd1 and cmd1.id == cfg.CMD_ATTACK and cmd1.params and cmd1.params[1] == bestID then
                            alreadyAttacking = true
                        end
                        if not alreadyAttacking then
                            if st.attackDbg then
                                st.attackDbg.issued = st.attackDbg.issued + 1
                                if uDef.canFly then st.attackDbg.airIssued = st.attackDbg.airIssued + 1
                                else st.attackDbg.groundIssued = st.attackDbg.groundIssued + 1 end
                                st.attackDbg.lastIssuedDef = uDef.name
                            end
                            spGiveOrderToUnit(unitID, cfg.CMD_ATTACK, { bestID }, {})
                        end
                        return
                    end

                    if isArty then
                        local ddx, ddz = cx - ux, cz - uz
                        if ddx*ddx + ddz*ddz <= maxRange * maxRange then
                            local hasMove = false
                            if cmds then
                                for ci = 1, #cmds do
                                    local cid = cmds[ci].id
                                    if cid == cfg.CMD_MOVE or cid == cfg.CMD_ATTACK or cid == cfg.CMD_PATROL then hasMove = true break end
                                end
                            end
                            if hasMove then spGiveOrderToUnit(unitID, CMD_STOP, {}, {}) end
                            return
                        end
                        local sx, sz = U.GetFlankSpreadPos(unitID, cx, cz, maxRange * 0.85, maxRange * 0.95, nil)
                        local alreadyHeading = false
                        if cmd1 and cmd1.id == cfg.CMD_MOVE and cmd1.params and cmd1.params[1] and cmd1.params[3] then
                            local mdx, mdz = sx - cmd1.params[1], sz - cmd1.params[3]
                            if mdx*mdx + mdz*mdz < 160*160 then alreadyHeading = true end
                        end
                        if not alreadyHeading then
                            spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { sx, spGetGroundHeight(sx, sz), sz }, {})
                        end
                        return
                    end

                    local nEx, nEz, nDistSq, nVx, nVz = nil, nil, mHuge, 0, 0
                    local enemyDPS, enemyHP = 0, 0
                    local nAir = false
                    local kiteScan = spGetUnitsInCylinder(ux, uz, airRange)
                    if kiteScan then
                        for i = 1, #kiteScan do
                            local tID = kiteScan[i]
                            local tTeam = spGetUnitTeam(tID)
                            if tTeam and tTeam ~= myTeamID and not spAreTeamsAllied(myTeamID, tTeam) then
                                local tDefID = spGetUnitDefID(tID)
                                local tDPS = tDefID and cfg.GetUnitDPS(tDefID) or 0
                                -- A threat is anything that can hurt us
                                if tDPS > 0 then
                                    enemyDPS = enemyDPS + tDPS
                                    local thp = spGetUnitHealth(tID)
                                    if thp and thp > 0 then
                                        enemyHP = enemyHP + thp
                                    else
                                        local tDef = UnitDefs[tDefID]
                                        enemyHP = enemyHP + (tDef and tDef.maxHealth or 100)
                                    end
                                    local ex, _, ez = spGetUnitPosition(tID)
                                    if ex then
                                        local dx, dz = ex - ux, ez - uz
                                        local d = dx*dx + dz*dz
                                        if d < nDistSq then
                                            nDistSq, nEx, nEz = d, ex, ez
                                            nAir = (UnitDefs[tDefID] and UnitDefs[tDefID].canFly) or false
                                            local vx, _, vz = spGetUnitVelocity(tID)
                                            if vx then nVx, nVz = vx, vz else nVx, nVz = 0, 0 end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    local engageRange = nAir and airRange or maxRange
                    local shouldKite = false
                    if nEx and enemyDPS > 0 and hp and hp > 0 then
                        local ourDPS = cfg.GetUnitDPS(uDefID)
                        if ourDPS <= 0 then
                            shouldKite = true
                        else
                            shouldKite = (hp / enemyDPS) < (enemyHP / ourDPS)
                        end
                    end
                    if shouldKite
                        and nDistSq < (engageRange * cfg.KITE_TRIGGER_RATIO) * (engageRange * cfg.KITE_TRIGGER_RATIO) then
                        local kx, kz
                        if U.CanStrafeByDefID(uDefID) then
                            local awayX, awayZ = ux - nEx, uz - nEz
                            local awayLen = math.sqrt(nDistSq)
                            if awayLen < 1 then awayX, awayZ, awayLen = 1, 0, 1 end
                            local awayNX, awayNZ = awayX / awayLen, awayZ / awayLen
                            local closing = nVx * awayNX + nVz * awayNZ
                            local leadDist = mMax(0, closing) * cfg.KITE_LEAD_FRAMES
                            local standoff = engageRange * cfg.KITE_STANDOFF_RATIO + leadDist
                            kx = nEx + awayNX * standoff
                            kz = nEz + awayNZ * standoff
                        else
                            kx, kz = cfg.GetTangentialRetreat(unitID, ux, uz, nEx, nEz, engageRange * cfg.KITE_TANK_HOP)
                        end
                        local mapX, mapZ = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
                        kx = mMax(50, mMin(kx, mapX - 50))
                        kz = mMax(50, mMin(kz, mapZ - 50))
                        local kLvl = Spring.GetGameRulesParam("lavaLevel")
                        local kDanger = nil
                        if kLvl and kLvl > -9000 then
                            kDanger = kLvl
                        else
                            local geMin = Spring.GetGroundExtremes()
                            if geMin and geMin < -50 then kDanger = 0 end
                        end
                        if kDanger and spGetGroundHeight(kx, kz) < kDanger + cfg.LAVA_MARGIN then
                            local bdx, bdz = ux - kx, uz - kz
                            local bl = math.sqrt(bdx*bdx + bdz*bdz)
                            if bl < 1 then kx, kz = ux, uz
                            else
                                bdx, bdz = bdx / bl, bdz / bl
                                for si = 1, 16 do
                                    kx = kx + bdx * 32
                                    kz = kz + bdz * 32
                                    if spGetGroundHeight(kx, kz) >= kDanger + cfg.LAVA_MARGIN then break end
                                end
                            end
                        end
                        local alreadyKiting = false
                        if cmd1 and cmd1.id == cfg.CMD_MOVE and cmd1.params and cmd1.params[1] and cmd1.params[3] then
                            local mdx, mdz = kx - cmd1.params[1], kz - cmd1.params[3]
                            if mdx*mdx + mdz*mdz < cfg.KITE_DEADBAND * cfg.KITE_DEADBAND then alreadyKiting = true end
                        end
                        if not alreadyKiting then
                            spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { kx, spGetGroundHeight(kx, kz), kz }, {})
                        end
                        return
                    end
                    if st.enemyDefenses then
                        local dX, dZ, dR = nil, nil, 0
                        local dBest2 = 900 * 900
                        for dID, dEnt in pairs(st.enemyDefenses) do
                            local ddx, ddz = dEnt.x - cx, dEnt.z - cz
                            local dd2 = ddx*ddx + ddz*ddz
                            if dd2 < dBest2 then dBest2, dX, dZ, dR = dd2, dEnt.x, dEnt.z, dEnt.range or 0 end
                        end
                        if dX and dR > 0 and maxRange >= dR then
                            local holdR = mMin(maxRange, dR + 150)
                            local hx, hz = U.GetFlankSpreadPos(unitID, dX, dZ, mMax(60, holdR - 40), mMax(140, holdR + 40), nil)
                            local alreadyHeading = false
                            if cmd1 and cmd1.id == cfg.CMD_MOVE and cmd1.params and cmd1.params[1] and cmd1.params[3] then
                                local hdx, hdz = hx - cmd1.params[1], hz - cmd1.params[3]
                                if hdx*hdx + hdz*hdz < 160*160 then alreadyHeading = true end
                            end
                            if not alreadyHeading then
                                spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { hx, spGetGroundHeight(hx, hz), hz }, {})
                            end
                            return
                        end
                    end
                    local eMinR, eMaxR
                    if isGround and clusterSize >= cfg.CLUSTER_THRESHOLD then
                        eMinR = mMax(60, maxRange * 0.95)
                        eMaxR = mMax(140, maxRange * 0.98)
                    else
                        local tDefID = bestID and spGetUnitDefID(bestID)
                        local sRange = cfg.GetEngageRange(uDefID, tDefID and UnitDefs[tDefID])
                        eMinR = mMax(60, sRange * 0.95)
                        eMaxR = mMax(140, sRange * 0.98)
                    end
                    local sx, sz = nil, nil
                    if isGround and clusterSize >= cfg.CLUSTER_THRESHOLD then
                        sx, sz = U.GetFlankSpreadPos(unitID, cx, cz, eMinR, eMaxR, nil)
                    else
                        local ex, ey, ez = spGetUnitPosition(bestID)
                        if ex then
                            sx, sz = U.GetFlankSpreadPos(unitID, ex, ez, eMinR, eMaxR, bestID)
                        end
                    end
                    if sx then
                        local alreadyHeading = false
                        if cmd1 and cmd1.id == cfg.CMD_MOVE and cmd1.params and cmd1.params[1] and cmd1.params[3] then
                            local ddx, ddz = sx - cmd1.params[1], sz - cmd1.params[3]
                            if ddx*ddx + ddz*ddz < 160*160 then alreadyHeading = true end
                        end
                        if not alreadyHeading then
                            spGiveOrderToUnit(unitID, cfg.CMD_MOVE, { sx, spGetGroundHeight(sx, sz), sz }, {})
                        end
                    end
                    return
                end
            end
        end

        local reAim = true
        local cReaim = spGetUnitCommands(unitID, 1)
        local c0 = cReaim and cReaim[1]
        if c0 and (c0.id == cfg.CMD_MOVE or c0.id == cfg.CMD_ATTACK or c0.id == cfg.CMD_PATROL or c0.id == cfg.CMD_GUARD) then
            local planeArrived = false
            if uDef.canFly and c0.id == cfg.CMD_MOVE and c0.params and c0.params[1] and c0.params[3] then
                local adx, adz = c0.params[1] - ux, c0.params[3] - uz
                if adx * adx + adz * adz < 200 * 200 then planeArrived = true end
            end
            if not planeArrived then
                local lastAim = st.combatReaimFrame[unitID] or -999999
                if frame - lastAim < cfg.COMBAT_REAIM_INTERVAL then reAim = false end
            end
        end
        if reAim then
            st.combatReaimFrame[unitID] = frame
            st.frameNum = frame

            local tgtX, tgtY, tgtZ = st.army.targetX, st.army.targetY, st.army.targetZ
            local cx, cy, cz, bestID, clusterSize, bestMetal, isGround =
                W.FindBestClusterTarget(ux, uz, 1600, cfg.AOE_DAMAGE_RADIUS, uDefID)
            if not cx and tgtX then
                cx, cy, cz, bestID, clusterSize, bestMetal, isGround =
                    W.FindBestClusterTarget(tgtX, tgtZ, 1500, cfg.AOE_DAMAGE_RADIUS, uDefID)
            end

            if cx then
                local tDefID = bestID and spGetUnitDefID(bestID)
                local uRange = cfg.GetEngageRange(uDefID, tDefID and UnitDefs[tDefID])
                if isArty then
                    -- Hold at range limit once in range
                    local ddx, ddz = cx - ux, cz - uz
                    if ddx*ddx + ddz*ddz <= uRange * uRange then
                        local cs = spGetUnitCommands(unitID, -1)
                        local hasMove = false
                        if cs then
                            for ci = 1, #cs do
                                local cid = cs[ci].id
                                if cid == cfg.CMD_MOVE or cid == cfg.CMD_ATTACK or cid == cfg.CMD_PATROL then hasMove = true break end
                            end
                        end
                        if hasMove then spGiveOrderToUnit(unitID, CMD_STOP, {}, {}) end
                        return
                    end
                    W.GiveSpreadMove(unitID, ux, uz, cx, cz, uRange * 0.85, uRange * 0.95)
                    return
                end
                W.GiveSpreadMove(unitID, ux, uz, cx, cz, mMax(60, uRange * 0.95), mMax(140, uRange * 0.98), (clusterSize == 1 and bestID) or nil)
                return
            end

            if st.army.state == "attacking" and tgtX then
                local ddx, ddz = tgtX - ux, tgtZ - uz
                if ddx*ddx + ddz*ddz < 400 * 400 then
                    local myTeamID = spGetMyTeamID()
                    local gaiaTeam = spGetGaiaTeamID()
                    local nearbyEnemies = spGetUnitsInCylinder(tgtX, tgtZ, 500)
                    local targetEnemy = nil
                    if nearbyEnemies then
                        for ei = 1, #nearbyEnemies do
                            local eID = nearbyEnemies[ei]
                            if eID ~= unitID then
                                local eTeam = spGetUnitTeam(eID)
                                if eTeam and eTeam ~= gaiaTeam and not spAreTeamsAllied(eTeam, myTeamID) then
                                    targetEnemy = eID
                                    break
                                end
                            end
                        end
                    end
                    if targetEnemy then
                        spGiveOrderToUnit(unitID, cfg.CMD_ATTACK, { targetEnemy }, {})
                        return
                    else
                        W.PushFrontier(unitID, ux, uz)
                        return
                    end
                end
                W.GiveSpreadMove(unitID, ux, uz, tgtX, tgtZ, cfg.ANTI_CLUMP_MIN, 1100)
                return
            end

            if U.IsScoutDef(uDef) and not isTrapperUnit and I.CountActiveScouts(frame) < st.scoutMaxActive then
                if I.AssignScoutOrder(unitID, frame) then
                    return
                end
            end

            -- Enemy location unknown: man a defensive perimeter ring around
            -- the base instead of wandering into the fog blindly. Each unit
            -- gets a stable slot on the ring. Once the enemy is found, a
            -- fixed fraction (HOME_GUARD) stays behind as home guard.
            local bcx2, bcz2 = st.baseCenterX, st.baseCenterZ
            local enemyKnown = false
            for _ in pairs(st.enemyBases or {}) do enemyKnown = true break end
            local homeGuardUnit = ((unitID % cfg.HOME_GUARD_MOD) == (cfg.HOME_GUARD_KEEP % cfg.HOME_GUARD_MOD))
            if bcx2 and (not enemyKnown or homeGuardUnit) then
                local mapX2, mapZ2 = Game.mapSizeX or 8192, Game.mapSizeZ or 8192
                local ringR = mMax(800, ((st.baseRadius or 400) + 400) * (st.mapLinearScale or 1))
                local slots = cfg.PERIMETER_SLOTS
                local ang = (2 * math.pi) * (((unitID * 7) % slots) / slots) + (unitID % 13) * 0.04
                local px = mMax(100, mMin(bcx2 + mCos(ang) * ringR, mapX2 - 100))
                local pz = mMax(100, mMin(bcz2 + mSin(ang) * ringR, mapZ2 - 100))
                local ddx, ddz = px - ux, pz - uz
                if ddx * ddx + ddz * ddz > 220 * 220 then
                    W.GiveSpreadMove(unitID, ux, uz, px, pz, cfg.ANTI_CLUMP_MIN, cfg.ANTI_CLUMP_MAX)
                end
                return
            end

            W.PushFrontier(unitID, ux, uz)
        end
    end
end
O.ProcessUnitOrders = ProcessUnitOrders

return O

end
