--[[
	ShotgunMetal / config.lua
	All tunable parameters (cfg) and engine command-id constants.
	Depends on: nothing.
]]

local CMD = CMD

local CMD_DGUN        = (CMD and (CMD.MANUALFIRE or CMD.DGUN)) or 37899
local CMD_STOP        = (CMD and CMD.STOP) or 0
local CMD_WAIT        = (CMD and CMD.WAIT) or 5
local CMD_CLOAK       = 37382 -- BAR's cloak command
local CMD_RESURRECT   = (CMD and CMD.RESURRECT) or 125
local CMD_FIRE_STATE  = (CMD and CMD.FIRE_STATE) or 25200
local CMD_MOVE_STATE  = (CMD and CMD.MOVE_STATE) or 25201

local cfg = {
    BUILD_RADIUS          = 1000,   -- max radius the flood-fill build-spot search explores
    CHECK_INTERVAL        = 10,
    THREAT_INTERVAL       = 30,     -- frames between enemy/threat scans (~1s)
    COMBAT_REAIM_INTERVAL = 60,     -- frames between mid-move re-aims

    -- Cap units/frame when we're slow. It's probably best to optimize the code, but if
    -- we can't do that, atleast we can do this.

    LOAD_TARGET_MS        = 1.0,
    LOAD_CEILING_MS       = 2.5,
    LOAD_MAX_SCALE        = 8,
    LOAD_MAX_UNITS_PER_FRAME = 40,
    LOAD_ADAPT_EVERY      = 15,     -- (~0.5s)
    LOAD_EMA              = 0.1,
    LOAD_MIN_FPS          = 20,
    LOAD_MIN_FPS_RECOVER  = 26,

    BUILD_SPACING         = 384,    -- grid spacing for factory/eco placement
    ENERGY_GRID_SPACING   = 64,
    OPENING_WIND_SPACING  = 32,     -- opening winds placed right next to each other
    ECO_BUILD_RADIUS      = 120,    -- compact eco block: 2 rows x 4 (8 buildings)
    SHIELD_GRID_SPACING   = 256,
    TURRET_SPACING        = 80,
    MIN_SPACING           = 32,     -- I don't think you can build stuff this close, but it (might?) help out performance wise adding this
    BUILD_BLOCK_SIZE      = 4,      -- legacy small-block size (still used as safety floor)
    BLOCK_GAP             = 12,     -- elmo gap between buildings inside eco rows/blocks
    ECO_ROW_COUNT         = 4,      -- continuous eco strips: 2 wide x 4 long (8 buildings)
    ECO_BLOCK_BUILDINGS   = 8,      -- hard cap of eco buildings per compact block; stop growing a block past this
    ECO_ROW_MIN           = 6,      -- fewer valid cells than this -> flip row direction
    MEX_CLUSTER_RADIUS_SQ = 102400, -- grab extra mex spots within this radius (squared elmos) in one trip (=320^2)
    MIN_CONS_BEFORE_UNITS = 2,      -- first factory MUST make this many constructors before any units
    UNIT_RUSH_FRAME       = 4500,   -- (~2.5 min) from here factories prioritize combat units hard
    CONS_PER_FACTORY_POST = 5,      -- post-opening constructor trickle target per lab
    CONS_BASE_POST        = 10,     -- ...plus this flat amount (keep a solid eco workforce)
    CONS_ORDER_CHANCE     = 0.85,   -- chance a factory picks a con while below the trickle target
    ROWS_MIN_MEX          = 3,      -- long eco strips need at least this many built mexes...
    ROWS_MIN_WIND         = 10,     -- ...and this many wind/solar buildings before they unlock
    ARTILLERY_SUPPORT_CHANCE = 0.12, -- post-throttle chance a factory queues artillery as support
    AIR_FIGHTER_BIAS      = 0.6,    -- chance an air factory queues a fighter instead of a bomber
    T3_TECH_LEVEL         = 3,      -- bombers stay banned until a bomber of this tech level exists
    AA_PER_AIR_FACTORY    = 2,      -- extra AA towers per own air factory
    AFUS_ROW_COUNT        = 6,      -- once AFUS is affordable, place them 2 wide x N long
    BASE_GROUND_DEF_TARGET = 4,     -- ground defenses wanted even with zero factories/pressure
    BASE_AA_DEF_TARGET     = 2,     -- AA defenses wanted even with zero factories/pressure
    LAVA_MARGIN           = 12,     -- build/move this far above the lava level

    ANTI_NUKE_KEEPOUT      = 160,

	-- Hardcoded variables are fragile, but it's whatever.
	-- The important thing to note is that this not a hard ban,
	-- it simply allows us to build other things once we have enough m/s.

    METAL_MAP_MEX_INCOME_TARGET = 300,

    -- When our metal income is this many times below the pull (spend rate) we
    -- are critically starved: FORCE constructors onto mexes over anything else.
    METAL_CRITICAL_INCOME_RATIO = 2.5,
    METAL_CRITICAL_MIN_MEX     = 2,  -- keep building mexes until we have this many

    MEX_GROWTH_FLOOR     = 2,       -- we should have this many mex builders while income < target (x mapAreaScale)
    STALL_PULL_METAL_RATIO  = 0.25, -- stall-pull thresholds are a fraction of our income, not fixed m/s
    STALL_PULL_ENERGY_RATIO = 0.25,

    RECLAIM_RANGE         = 650,    -- This scales with map size
    RECLAIM_MIN_METAL_SECONDS = 4,  -- a wreck is reclaimed only if worth this many seconds of income
    RETREAT_HEALTH_RATIO  = 0.15,   -- below this HP a unit retreats
    TANGENTIAL_RETREAT_DIST = 700,

    SELFD_HP_RATIO       = 0.20,    -- nearly-dead big units self-D as a weapon when enemies worth DOOM_RATIO x cost are on top TODO: fix this, it doesn't work
    SELFD_MIN_BLAST_RADIUS = 300,   -- min selfDExplosion AoE to be a "bomb" (generic pops are <= ~96)
    SELFD_DOOM_RATIO     = 0.20,

    KITE_TRIGGER_RATIO   = 0.95,    -- back off when an enemy closes inside this x our range
    KITE_STANDOFF_RATIO  = 1.0,
    KITE_LEAD_FRAMES     = 15,
    KITE_TANK_HOP        = 0.3,
    KITE_DEADBAND        = 16,

	-- normally you would use guard here, but when a unit reverses
 	-- guarding can lead to the guarding unit ending up infront of the unit its guarding
 	-- I actuallly am not sure this is even working properly TODO: look into this

    SUPPORT_BEHIND_DIST  = 140,

    COMMANDER_SCAN_RADIUS   = 1200,
    -- This ones up for debate, but I'm not sure whether retreating a specific amount is best (what if the enemy leaves?)
    -- But also, (what if they leave our LOS, but they can still see us?)
    COMMANDER_RETREAT_DIST  = 800,
    CON_HEAL_THRESHOLD     = 0.9,

    TURRET_SEARCH_RADIUS  = 400,    -- keep 'em close to the lab!

    CMD_MOVE              = 10,
    CMD_PATROL            = 15,
    CMD_ATTACK            = 20,
    CMD_GUARD             = 25,
    CMD_REPAIR            = 40,
    CMD_RECLAIM           = 90,
    CMD_SELFD             = 65,
    CMD_STOP              = CMD_STOP,
    CMD_WAIT              = CMD_WAIT,
    CMD_CLOAK             = CMD_CLOAK,
    CMD_DGUN              = CMD_DGUN,
    CMD_RESURRECT         = CMD_RESURRECT,
    CMD_FIRE_STATE        = CMD_FIRE_STATE,
    CMD_MOVE_STATE        = CMD_MOVE_STATE,
    CMD_FLY               = (CMD and CMD.IDLEMODE) or nil,

    ENEMY_RECLAIM_MIN_COST_SECONDS = 2,  -- don't reclaim enemies worth < this many seconds of income
    ENEMY_RECLAIM_CHASE_RANGE  = 500,    -- how far mobile cons chase enemies to reclaim them

    ARMY_MIN_SIZE          = 2,          -- send atleast *something*

    UNEASE_FLOOR_INCOME_SECONDS = 30,
    UNEASE_ARMY_RATIO      = 0.5,
    UNEASE_OVERRUN_RATIO   = 1.25,  -- recall defenders worth a minimum of threat + ~25%

    PERIMETER_PATROL_RING  = 700,
    UNEASE_WATCH_RING      = 800,
    UNEASE_SCAN_BUFFER     = 1500,
    PERIMETER_PATROL_PROBES = 8,

    DEFENSE_TARGET_RADIUS  = 1300,  -- army attacks nearest static defense within this range

    DEFENSE_MIN_PER_FACTORY   = 2,
    DEFENSE_ARMY_TURRET_RATIO = 5,
    DEF_LINE_TOWARDS_ENEMY = 6,     -- once an enemy base is scouted: extra turrets form a defensive line along the threat axis
    DEF_LINE_STEP          = 340,   -- elmo spacing between line turrets (scaled by mapLinearScale)

    UNIT_PICK_COST_CAP_SECONDS = 90,
    INCOME_WINDOW_BASE         = 30,
    INCOME_WINDOW_COST_RATIO   = 0.001,

    -- Tech rush / heavy-unit spam
    MAX_CONCURRENT_FACTORIES = 10,  -- labs under construction or claimed at once
    BIG_UNIT_BIAS            = 0.7, -- chance a factory builds its most expensive affordable unit
SMALL_UNIT_BIAS          = 0.05, -- before the army threshold: almost only cheap line units
HEAVY_UNLOCK_ARMY_SIZE   = 60,   -- combat units needed before heavy/support units are allowed
ADV_CON_MAX              = 5,   -- keep this many T2 constructors alive

    ATTACK_SCOUT_DURATION  = 1200,

    SCOUT_COVERAGE_RATIO   = 0.5,
    SCOUT_LOCK_TTL         = 2400,
    SCOUTS_PER_FACTORY     = 1,

    ECONOMY_SATURATION_RATIO = 0.85,
    ECONOMY_INCOME_SLACK     = 1.5,

    ADV_FACTORY_TIER_RATIO  = 2,

    -- Moderate storage production: immediately queue one storage building
    -- whenever a resource overflows its current capacity buffer.
    STORAGE_OVERFLOW_RATIO = 0.85,  -- trigger when resource > capacity × ratio
    STORAGE_BUILD_SPACING  = 192,   -- spacing around storage units

    ADV_FACTORY_PAYBACK_SECS = 90,

    -- Never tech into an advanced (T2+) lab until BOTH thresholds are met:
    -- early adv labs eat all the metal and lose to plain T1 spam.
    T2_MIN_ARMY              = 20,  -- combat units alive before the first adv lab
    T2_MIN_FACTORIES         = 3,   -- completed labs before the first adv lab
    AIR_FACTORY_MIN_ARMY     = 15,  -- don't open air factories until this many ground/combat units exist (keeps ground focus)

    -- Phase progression: T1 spam → T2 spam → T3 (rare). T3 only enters
    -- the queue after a massive T2 army is established, and even then only
    -- a small fraction of production goes to T3 to keep the T2 flow heavy.
    T3_MIN_ARMY              = 80,  -- combat units required before ANY T3 unit ordered or T3 lab built
    T3_SKIP_CHANCE           = 0.85,-- when unlocked, chance a T3 unit is skipped in the build queue

    AOE_DAMAGE_RADIUS     = 256,
    CLUSTER_THRESHOLD     = 2,

CONS_PER_FACTORY      = 9,	   -- constructors wanted per lab (fast eco expansion)
CONS_BASE             = 12,
    ECO_BUILDER_AGGRESSION = 3,     -- multiplier on mex/energy builder budgets (build wider while space lasts)
    PERIMETER_SLOTS       = 24,     -- defensive ring slots around base when enemy is unknown
    HOME_GUARD_MOD        = 2,      -- even after the enemy is found, every N-th combat unit...
    HOME_GUARD_KEEP       = 1,      -- ...(unitID % MOD == KEEP) stays on the perimeter ring as home guard
    HOME_GUARD_RANGE      = 9,      -- x baseRadius: defenders never chase targets farther than this from base
    AGGRESSION            = 7,    -- MASTER unit-spam knob: 1 = balanced, higher = flood units hard
                                    -- (fewer constructors, earlier unit rush, cheaper mixes, less support).
                                    -- Lower (<1) = greedy eco. Try 2.0-3.0 for maximum unit spam.

    MEX_SKIP_DIST         = 1000,  -- skip walking to a mex spot further than this

    ARMY_DEPRECIATION_RATE = 0.02, -- get the army moving, t1s are more useful early on

    ANTI_CLUMP_MIN         = 220,
    ANTI_CLUMP_MAX         = 650,  -- anti-clump ring kept wide on purpose; a tight disc clumped the whole army
}

return cfg
