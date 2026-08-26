--[[
	ShotgunMetal / state.lua
	All mutable per-game state (st). Returned by reference: every module
	reads/writes the same table. Depends on: nothing.
]]

local st = {
    frameNum                     = 0,
    buildCache                   = {},
    lastFactoryOrderFrame        = {},
    claimedSpots                 = {},

    myFactories                  = {},
    myFactoriesCount             = 0,
    factoryGuards                = {},
    factoryTurrets               = {},
    conTurretHomes               = {},
    factoryWaitState             = {},
    incompleteFactories          = {},
    incompleteFactoryCount       = 0,
    combatReaimFrame             = {},
    pendingFactoryBlueprints     = 0,
    factoriesNeedingTurrets      = {},
    factoriesNeedingTurretsCount = 0,

    myCommanders                 = {},
    myCommanderCount             = 0,

    conUnitCount                 = 0,
    advConCount                  = 0,
    mexUnitCount                 = 0,
    combatUnitCount              = 0,
    myCombatUnits                = {},
    myCombatUnitCount            = 0,
    unclaimedMexCount            = 0,
    unclaimedMetalSpots          = {},

    lazCount                     = 0,
    jammerCount                  = 0,
    radarCount                   = 0,
    radarTowerCount              = 0,

    activeMexBuilders            = 0,
    activeEnergyBuilders         = 0,

    energyStalling               = false,
    metalStalling                = false,
    economySaturated             = false,
    metalIncome                  = 0,
    energyIncome                 = 0,
    metalPull                    = 0,
    energyPull                   = 0,
    currentMetal                 = 0,
    currentEnergy                = 0,
    currentEnergyStorage         = 0,
    currentMetalStorage          = 0,
    pendingCommittedMetal        = 0,

    cachedPrimeTargetPos         = nil,
    cachedPrimeTargetID          = nil,
    cachedPrimeTargetCost        = nil,

	-- Proof of concept, but generally,
    -- when a hidden enemy damages us, extrapolate the shell's trajectory back
    -- by its weapon range to guess where the shooter is; lets us retaliate
    -- into fog when nothing is visible.

    suspectedThreatX             = nil,
    suspectedThreatZ             = nil,
    suspectedThreatFrame         = -999999,
    metalSpots                   = {},
    claimedMexList               = {},

    baseCenterX                  = nil,
    baseCenterY                  = nil,
    baseCenterZ                  = nil,
    baseRadius                   = 0,
    baseStructureCount           = 0,

    enemyBases                   = {},
    enemyDefenses                = {},
    raiders                      = {},
    raiderCount                  = 0,
    unease                       = 0,    -- weighted strength of enemy units near base
    uneaseX                      = nil,  -- weighted centroid of the threatening group
    uneaseZ                      = nil,
    scoutSectors                 = {},
    scoutAssignments             = {},
    scoutIntelVersion            = {},
    scoutUnitCount               = 0,

    intelVersion                 = 0,   -- bumped whenever enemy-base intel changes

    myAntinukes                  = {},
    antinukeCount                = 0,
    pendingAntinukeBlueprints    = 0,
    defenseCount                 = 0,   -- total defensive *things*
    afusLocked                   = false, -- once true: eco energy = advanced fusion only
    defenseGroundCount           = 0,   -- ground attack towers (can also deal damage to air units, but aren't AA)
    defenseAACount               = 0,   -- AA-only towers

    selfDingUnits                = {},  -- our units should flee so they're not caught in the blast
    selfDingCount                = 0,

    currentDefenders             = {},  -- units recalled to intercept a threatening group

    frontierX                    = nil, -- forward expansion axis (toward enemy / map center)
    frontierZ                    = nil,

    plan = {
        mode          = "mex",   -- "mex" | "energy" | "army"
        frame         = 0,
        mexScore      = 0,
        energyScore   = 0,
        armyScore     = 0,       -- value of attacking now (depreciation + tempo)
        metalSurplus  = 0,       -- metalIncome - metalPull (per second)
        energyDeficit = 0,       -- energyPull - energyIncome (per second)
    },

    enemyTech                  = 0,   -- highest metal cost seen among enemy units (decays)
    ourTech                    = 0,   -- highest metal cost among our combat units
    armyValue                  = 0,   -- total metal of our fielded combat units
    enemyArmyValue             = 0,   -- total metal of enemy MOBILE combat units seen (decays)

    fireStateSet                 = {},
    moveStateSet                 = {},
    flyStateSet                  = {},

    -- let's get a exclusive lock here so we don't
	-- put two of the same support units on one unit
    supportGuardOwners = { radar = {}, jammer = {}, aa = {} },
    supportTarget               = {},

    aaThreats                    = {},

    army = {
        state           = "searching",
        targetX         = nil,
        targetY         = nil,
        targetZ         = nil,
        targetKey       = nil,
        stateFrame      = 0,
    },

    turretDbg = {
        consWithTurret = 0,   -- number of cons who can build a turret
        needTurrets    = 0,   -- labs waiting for their turret ring
        fired          = 0,
        noCon          = 0,   -- this con can't build turrets
        noNeed         = 0,   -- con *could* build turrets but no lab needs a ring
        noAfford       = 0,   -- target chosen but turrets are unaffordable
        noSpot         = 0,   -- FindBuildSpot found no tile
        placed         = 0,
        probeTiles     = 0,
        probeBlocked   = 0,
        probeInacc     = 0,   -- We can't get there (void, lava, etc) :(
        probeOverlap   = 0,   -- too close to the ordering con itself
        probeTest      = 0,
        probeExit      = 0,
        probeBounds    = 0,
        lastDef        = nil,
        lastSpacing    = 0,
        lastRingOut    = 0,
    },
    attackDbg = {
        issued          = 0, -- This is the total number of attack orders issued by the bot
        airIssued       = 0, -- This should be a number (if we have an air lab)
        groundIssued    = 0, -- This should be 0
        groundCleared   = 0, -- This should be 0
        lastIssuedDef   = nil,
        lastGroundDef   = nil,
    },
    uneaseDbg = {
        detected       = 0,
        fired          = 0,
        noCands        = 0,   -- fired but had no combat units to send
        recalled       = 0,
        lastUnease     = 0,   -- unease at the last fired recall
    },
}

return st
