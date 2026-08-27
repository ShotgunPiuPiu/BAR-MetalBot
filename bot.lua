-- ShotgunPiuPiu Metal Bot -- a widget that plays metal maps on BAR.
--
-- Fork of MetalBot by vexalous:
--   https://github.com/PrivacyIsARight/MetalBot
-- Renamed and heavily modified by ShotgunPiuPiu, 2026.
--
-- This is the entry point only: configuration, state, and all logic live in
-- the ShotgunMetal/ modules next to this file. Each module is a factory so that
-- VFS.Include never re-executes shared state, and cross-module helpers are
-- passed explicitly instead of relying on Lua 5.1's 60-upvalue limit:
--
--   config.lua   plain table of tunables
--   state.lua    per-game mutable state (factory)
--   utils.lua    pure helpers over UnitDefs/map (factory)
--   intel.lua    enemy scouting/threat tracking            (cfg, st, U, D)
--   economy.lua  macro state + strategic planning          (cfg, st, U, D)
--   military.lua reclaim/clustering/defense coordination   (cfg, st, U, D)
--   build.lua    build-spot search + affordability         (cfg, st, U, D)
--   orders.lua   per-unit ProcessUnitOrders                (cfg, st, U, D)
--
-- GPLv3 or later licensed. Have fun!

local widget = widget
local Spring = Spring
local math   = math
local string = string

local mFloor = math.floor
local mCeil  = math.ceil
local mMax   = math.max
local mMin   = math.min

local spGetUnitPosition       = Spring.GetUnitPosition
local spGetUnitDefID          = Spring.GetUnitDefID
local spGetTeamUnits          = Spring.GetTeamUnits
local spGetMyTeamID           = Spring.GetMyTeamID
local spGiveOrderToUnit       = Spring.GiveOrderToUnit
local spGetProjectilePosition = Spring.GetProjectilePosition
local spGetProjectileVelocity = Spring.GetProjectileVelocity

--------------------------------------------------------------------------------
-- Modules
--------------------------------------------------------------------------------

-- Spring's VFS does not resolve paths relative to this file, so anchor them
-- at the LuaUI root (with a fallback for alternative mount layouts).
local function MBInclude(fname)
    local lastErr
    for _, p in ipairs({ "LuaUI/Widgets/ShotgunMetal/" .. fname, "ShotgunMetal/" .. fname }) do
        local ok, res = pcall(VFS.Include, p)
        if ok then return res end
        lastErr = res
    end
    error("[ShotgunMetal] cannot load " .. fname .. ": " .. tostring(lastErr), 2)
end

local cfg = MBInclude("config.lua")
-- state.lua returns the shared mutable table itself (no factory)
local st  = MBInclude("state.lua")

local U = MBInclude("utils.lua")(cfg)

local D = {}
D.intel    = MBInclude("intel.lua")(cfg, st, U, D)
D.economy  = MBInclude("economy.lua")(cfg, st, U, D)
D.military = MBInclude("military.lua")(cfg, st, U, D)
D.build    = MBInclude("build.lua")(cfg, st, U, D)

local O = MBInclude("orders.lua")(cfg, st, U, D)

-- The order processor was extracted verbatim from the original monolith and
-- reaches some helpers through cfg; keep those bridges intact.
cfg.IsTrapper               = U.IsTrapper
cfg.IsAAWeapon              = U.IsAAWeapon
cfg.IsAntiNukeDef           = U.IsAntiNukeDef
cfg.IsDefenseDef            = U.IsDefenseDef
cfg.GetSpreadPos            = U.GetSpreadPos
cfg.GetFlankSpreadPos       = U.GetFlankSpreadPos
cfg.GetTangentialRetreat    = U.GetTangentialRetreat
cfg.GetScoutSpeedThreshold  = U.GetScoutSpeedThreshold
cfg.GetSelfDBlastRadius     = U.GetSelfDBlastRadius
cfg.GetGroundRange          = U.GetGroundRange
cfg.GetUnitDPS              = U.GetUnitDPS
cfg.GetAAWeaponRange        = U.GetAAWeaponRange
cfg.GetEngageRange          = U.GetEngageRange
cfg.IsBomberDef             = U.IsBomberDef
cfg.IsFighterDef            = U.IsFighterDef
cfg.IsJunoBomberDef         = U.IsJunoBomberDef
cfg.IsJunoVulnerableDef     = U.IsJunoVulnerableDef
cfg.GetAntiNukeCoverage     = U.GetAntiNukeCoverage
cfg.GetMexGain              = D.economy.GetMexGain
cfg.GetEnergyGain           = D.economy.GetEnergyGain
cfg.CanAffordCombatUnit     = D.build.CanAffordCombatUnit
cfg.CanTechUpToFactory      = D.build.CanTechUpToFactory
cfg.FindBombTargetFromMemory = D.military.FindBombTargetFromMemory

--------------------------------------------------------------------------------
-- Widget metadata / UI toggle
--------------------------------------------------------------------------------

function widget:GetInfo()
    return {
        name      = "ShotgunPiuPiu Metal Bot",
        desc      = "Bot plays metal maps",
        author    = "ShotgunPiuPiu, vexalous",
        date      = "2024, 2026",
        license   = "GNU GPL, v3 or later",
        layer     = 0,
        enabled   = true
    }
end

local ui = {
    showGUI = false,
    active  = true,
    vsx     = 0,
    vsy     = 0,
    btnW    = 160,
    btnH    = 40,
    btnX    = 0,
    btnY    = 0
}

-- Adaptive load governor: stretch check/threat intervals when we're slow.
local loadGov = {
    cpuMs = 0,
    scale = 1,
    lastAdaptFrame = -cfg.LOAD_ADAPT_EVERY,
    effCheckInterval = cfg.CHECK_INTERVAL,
    effThreatInterval = cfg.THREAT_INTERVAL,
}

local function UpdateLoadGovernor(frame)
    if frame - loadGov.lastAdaptFrame < cfg.LOAD_ADAPT_EVERY then return end
    loadGov.lastAdaptFrame = frame

    local fps = (Spring.GetFPS and Spring.GetFPS()) or 0
    local cpuOver  = loadGov.cpuMs > cfg.LOAD_CEILING_MS
    local cpuUnder = loadGov.cpuMs < cfg.LOAD_TARGET_MS
    local fpsLow   = (fps > 0) and (fps < cfg.LOAD_MIN_FPS)
    local fpsOk    = (fps == 0) or (fps > cfg.LOAD_MIN_FPS_RECOVER)

    if cpuOver or fpsLow then
        loadGov.scale = mMin(loadGov.scale + 0.5, cfg.LOAD_MAX_SCALE)
    elseif cpuUnder and fpsOk then
        loadGov.scale = mMax(loadGov.scale - 0.5, 1)
    end

    loadGov.effCheckInterval  = mMax(cfg.CHECK_INTERVAL, mCeil(cfg.CHECK_INTERVAL * loadGov.scale))
    loadGov.effThreatInterval = mMax(cfg.THREAT_INTERVAL, mCeil(cfg.THREAT_INTERVAL * loadGov.scale))
end

--------------------------------------------------------------------------------
-- Callin handlers
--------------------------------------------------------------------------------

function widget:Initialize()
    ui.active = true
    ui.vsx, ui.vsy = Spring.GetViewGeometry()
    ui.btnX = mFloor((ui.vsx - ui.btnW) / 2)
    ui.btnY = mFloor((ui.vsy - ui.btnH) / 2)
    Spring.Echo("[ShotgunMetal] Loaded (active=" .. tostring(ui.active) .. ")")

    if U.IsSpectating() then
        Spring.Echo("[ShotgunMetal] spectator mode - bot idle")
        return
    end

    local myTeam = spGetMyTeamID()
    if myTeam then
        local units = spGetTeamUnits(myTeam)
        if units then
            for i = 1, #units do
                local uID = units[i]
                local dID = spGetUnitDefID(uID)
                local d = dID and UnitDefs[dID]
                if d and not d.isFactory and not d.isBuilder and d.speed and d.speed > 0 and d.weapons and #d.weapons > 0 then
                    spGiveOrderToUnit(uID, cfg.CMD_FIRE_STATE, {2}, {})
                    st.fireStateSet[uID] = true
                end
                if d and d.canFly and cfg.CMD_FLY then
                    spGiveOrderToUnit(uID, cfg.CMD_FLY, { 0 }, 0)
                    st.flyStateSet[uID] = true
                end
            end
        end
    end

    st.scoutSectors = {}
    local mapX = Game.mapSizeX or 8192
    local mapZ = Game.mapSizeZ or 8192
    local sectorSize = 1024
    local sectorCount = 0
    for x = 0, mapX - 1, sectorSize do
        for z = 0, mapZ - 1, sectorSize do
            local key = x .. "_" .. z
            st.scoutSectors[key] = {
                x = x + sectorSize / 2,
                z = z + sectorSize / 2,
                lastScouted = 0
            }
            sectorCount = sectorCount + 1
        end
    end

    st.scoutSectorCount = sectorCount
    st.mapAreaScale = (mapX * mapZ) / (8192 * 8192)
    st.mapLinearScale = math.sqrt(st.mapAreaScale)
    st.scoutMaxActive = mMax(1, mCeil(sectorCount * cfg.SCOUT_COVERAGE_RATIO))
    st.metalMapMexSpacing = (Game.extractorRadius or 24) * 4

    -- Remember where the enemy base is so we can reload the widget without
    -- forgetting! :)
    local gid = U.GetGameID()
    local bc = WG and WG.ShotgunMetalBaseCache
    if bc and bc.gameID == gid then
        if bc.bases and next(bc.bases) ~= nil then
            st.enemyBases = bc.bases
            local n = 0
            for _ in pairs(bc.bases) do n = n + 1 end
            Spring.Echo("[ShotgunMetal] restored " .. n .. " enemy base(s) from match cache")
        end
        if bc.enemyDefenses then
            st.enemyDefenses = bc.enemyDefenses
        end
        if bc.army and bc.army.state then
            st.army.state = bc.army.state
            st.army.targetX = bc.army.targetX
            st.army.targetY = bc.army.targetY
            st.army.targetZ = bc.army.targetZ
            st.army.targetKey = bc.army.targetKey
            st.army.stateFrame = bc.army.stateFrame or 0
        end
        if bc.scoutSectors then
            st.scoutSectors = bc.scoutSectors
        end
        if bc.factoryWaitState then
            st.factoryWaitState = bc.factoryWaitState
        end
    end
end

function widget:KeyPress(key, mods, isRepeat)
    if mods.ctrl and mods.shift and (key == 117 or key == 85) then
        ui.showGUI = not ui.showGUI
        return true
    end
    return false
end

function widget:ViewResize(viewSizeX, viewSizeY)
    ui.vsx = viewSizeX
    ui.vsy = viewSizeY
    ui.btnX = mFloor((ui.vsx - ui.btnW) / 2)
    ui.btnY = mFloor((ui.vsy - ui.btnH) / 2)
end

function widget:DrawScreen()
    if not ui.showGUI then return end
    if ui.active then gl.Color(0.2, 0.7, 0.2, 0.8) else gl.Color(0.7, 0.2, 0.2, 0.8) end
    gl.Rect(ui.btnX, ui.btnY, ui.btnX + ui.btnW, ui.btnY + ui.btnH)
    gl.Color(1, 1, 1, 1)
    gl.Text(ui.active and "METALAI: ON" or "METALAI: OFF", ui.btnX + (ui.btnW / 2), ui.btnY + (ui.btnH / 2) - 4, 16, "cv")
end

function widget:IsAbove(x, y)
    return x >= ui.btnX and x <= (ui.btnX + ui.btnW) and y >= ui.btnY and y <= (ui.btnY + ui.btnH)
end

function widget:MousePress(x, y, button)
    if ui.showGUI and button == 1 and widget:IsAbove(x, y) then
        ui.active = not ui.active
        Spring.Echo("[ShotgunMetal] " .. (ui.active and "ENABLED" or "DISABLED"))
        return true
    end
    return false
end

function widget:UnitCreated(unitID, unitDefID, teamID)
    D.build.OnWorldChange()
    if U.IsSpectating() then return end
    if not teamID or teamID ~= spGetMyTeamID() then return end
    local d = unitDefID and UnitDefs[unitDefID]
    if d and not d.isFactory and not d.isBuilder and d.speed and d.speed > 0 and d.weapons and #d.weapons > 0 then
        spGiveOrderToUnit(unitID, cfg.CMD_FIRE_STATE, {2}, {})
        st.fireStateSet[unitID] = true
    end
    if d and d.canFly and cfg.CMD_FLY then
        spGiveOrderToUnit(unitID, cfg.CMD_FLY, { 0 }, 0)
        st.flyStateSet[unitID] = true
    end
end

function widget:UnitDestroyed(unitID, unitDefID, teamID)
    D.build.OnWorldChange()
    U.OnUnitDestroyed(unitID)
    st.trapperTargets[unitID] = nil
    st.factoryGuards[unitID] = nil
    st.factoryWaitState[unitID] = nil
    st.lastFactoryOrderFrame[unitID] = nil
    st.fireStateSet[unitID] = nil
    st.moveStateSet[unitID] = nil
    st.flyStateSet[unitID] = nil
    st.combatReaimFrame[unitID] = nil
    st.supportTarget[unitID] = nil

    for key, assign in pairs(st.scoutAssignments) do
        if assign.unitID == unitID then st.scoutAssignments[key] = nil end
    end
    st.scoutIntelVersion[unitID] = nil

    for key, base in pairs(st.enemyBases) do
        if base.id == unitID then st.enemyBases[key] = nil end
    end
end

function widget:FeatureCreated()
    D.build.OnWorldChange()
end

function widget:FeatureDestroyed()
    D.build.OnWorldChange()
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID, attackerID, attackerDefID, attackerTeam)
    if not attackerID then return end

    local ax, _, az = spGetUnitPosition(attackerID)

    if attackerDefID and U.IsAAWeapon(attackerDefID, weaponDefID) and ax then
        st.aaThreats[attackerID] = { x = ax, z = az, frame = st.frameNum }
    end

    -- POC Nonsense
    if not ax and projectileID then
        local px, _, pz = spGetProjectilePosition(projectileID)
        if px then
            local fx, fz = px, pz
            local vx, _, vz = spGetProjectileVelocity(projectileID)
            if vx and (vx ~= 0 or vz ~= 0) then
                local wDef = weaponDefID and WeaponDefs[weaponDefID]
                local wRange = (wDef and wDef.range) or 600
                local vlen = math.sqrt(vx * vx + vz * vz)
                if vlen > 0.001 then
                    fx = px - (vx / vlen) * wRange
                    fz = pz - (vz / vlen) * wRange
                end
            end
            st.suspectedThreatX = fx
            st.suspectedThreatZ = fz
            st.suspectedThreatFrame = st.frameNum
            -- Retarget the army now, not on the next threat scan.
            st.army.targetX = fx
            st.army.targetZ = fz
            st.army.targetKey = "fire_origin"
            if st.army.state ~= "attacking" then st.army.state = "attacking" end
        end
    end
end

function widget:GameFrame(frame)
    if not ui.active then return end

    -- spectators can't command units
    if U.IsSpectating() then return end

    local myTeam = spGetMyTeamID()
    if not myTeam then return end

    local units = spGetTeamUnits(myTeam)
    if not units then return end

    st.frameNum = frame

    U.StepVoidScan()

    UpdateLoadGovernor(frame)

    local t0 = Spring.GetTimer()

    local checkInterval  = loadGov.effCheckInterval
    local threatInterval = loadGov.effThreatInterval
    local isCheckFrame   = (frame % checkInterval == 0)
    local isThreatFrame  = (frame % threatInterval == 0)

    if isCheckFrame then
        D.economy.UpdateMacroState(myTeam, units)
        D.economy.ComputeStrategicPlan(frame)
    end

    if isThreatFrame then
        D.intel.UpdateThreat(myTeam, units, frame)
        D.intel.UpdateArmyCoordination(frame)
        D.military.UpdateDefenseCoordination(frame)
        D.intel.CleanupAAThreats(frame)

        -- we don't want to lose data on a widget reload
        -- so then let's do this
        if WG then
            WG.ShotgunMetalBaseCache = {
                gameID = U.GetGameID(),
                bases = st.enemyBases,
                enemyDefenses = st.enemyDefenses,
                army = {
                    state = st.army.state,
                    targetX = st.army.targetX,
                    targetY = st.army.targetY,
                    targetZ = st.army.targetZ,
                    targetKey = st.army.targetKey,
                    stateFrame = st.army.stateFrame,
                },
                scoutSectors = st.scoutSectors,
                factoryWaitState = st.factoryWaitState,
            }
        end

        local cutoffFrame = frame - 900
        for key, claim in pairs(st.claimedSpots) do
            if claim.frame < cutoffFrame and not claim.isFactory then
                st.claimedSpots[key] = nil
            end
        end
    end

    local maxUnitsPerFrame = cfg.LOAD_MAX_UNITS_PER_FRAME
    local processed = 0
    for i = 1, #units do
        local unitID = units[i]
        if (frame + unitID) % checkInterval == 0 then
            O.ProcessUnitOrders(unitID, frame)
            processed = processed + 1
            if processed >= maxUnitsPerFrame then break end
        end
    end

    -- print for diagnostics
    if frame % 900 == 0 then
        local fmt = "[ShotgunMetal] state=%s target=(%s,%s) base=(%s,%s) combat=%d scouts=%d cons=%d facs=%d enemyRaiders=%d enemyBases=%d pendingMex=%d pF=%d metal=%d/s energy=%d/s(pull=%d stor=%d) stall=%s%s unease=%d load=%.2fms/%.1fx agg=%.1f"
        local tx, tz = st.army.targetX or -1, st.army.targetZ or -1
        local bx, bz = st.baseCenterX or -1, st.baseCenterZ or -1
        Spring.Echo(string.format(fmt,
            tostring(st.army.state), tostring(tx), tostring(tz), tostring(bx), tostring(bz),
            st.combatUnitCount or 0, st.scoutUnitCount or 0, st.conUnitCount or 0,
            st.myFactoriesCount or 0, st.raiderCount or 0,
            st.enemyBases and next(st.enemyBases) ~= nil and 1 or 0,
            st.unclaimedMexCount or 0,
            st.pendingFactoryBlueprints or 0,
            mFloor(st.metalIncome or 0),
            mFloor(st.energyIncome or 0), mFloor(st.energyPull or 0), mFloor(st.currentEnergyStorage or 0),
            (st.metalStalling and "M" or ""), (st.energyStalling and "E" or ""),
            st.unease or 0, loadGov.cpuMs, loadGov.scale, cfg.AGGRESSION or 1))

        local td = st.turretDbg
        local probe = ""
        if td.probeTiles and td.probeTiles > 0 then
            probe = string.format(" tiles=%d(blk=%d inacc=%d ovl=%d test=%d exit=%d bnd=%d) ringOut=%d step=%d def=%s",
                td.probeTiles, td.probeBlocked, td.probeInacc, td.probeOverlap, td.probeTest, td.probeExit, td.probeBounds,
                td.lastRingOut or 0, td.lastSpacing or 0, td.lastDef or "?")
        end
        Spring.Echo(string.format(
            "[ShotgunMetal] turret: consCanBuild=%d needRing=%d fired=%d placed=%d (noCon=%d noNeed=%d noAfford=%d noSpot=%d)%s",
            td.consWithTurret or 0, td.needTurrets or 0,
            td.fired or 0, td.placed or 0,
            td.noCon or 0, td.noNeed or 0, td.noAfford or 0, td.noSpot or 0, probe))
        td.fired, td.placed = 0, 0
        td.noCon, td.noNeed, td.noAfford, td.noSpot = 0, 0, 0, 0

        local ad = st.attackDbg
        if ad and (ad.issued > 0 or ad.groundCleared > 0) then
            Spring.Echo(string.format(
                "[ShotgunMetal] attack: issued=%d air=%d ground=%d groundCleared=%d lastIssued=%s lastCleared=%s",
                ad.issued, ad.airIssued, ad.groundIssued, ad.groundCleared,
                ad.lastIssuedDef or "?", ad.lastGroundDef or "?"))
            ad.issued, ad.airIssued, ad.groundIssued = 0, 0, 0
            ad.groundCleared = 0
            ad.lastIssuedDef, ad.lastGroundDef = nil, nil
        end

        local ub = st.uneaseDbg
        if ub and ub.detected > 0 then
            Spring.Echo(string.format(
                "[ShotgunMetal] unease: detected=%d fired=%d noCands=%d recalled=%d lastU=%d",
                ub.detected, ub.fired, ub.noCands, ub.recalled,
                ub.lastUnease))
            ub.detected, ub.fired = 0, 0
            ub.noCands, ub.recalled = 0, 0
            ub.lastUnease = 0
        end
    end

    local elapsedMs = Spring.DiffTimers(Spring.GetTimer(), t0) * 1000
    loadGov.cpuMs = loadGov.cpuMs + cfg.LOAD_EMA * (elapsedMs - loadGov.cpuMs)
end

function widget:SetConfigData(data)
    if data and type(data.active) == "boolean" then
        ui.active = data.active
    end
end

function widget:GetConfigData()
    return { active = ui.active }
end
