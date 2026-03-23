-- Classes/RestoDruid.lua
-- Restoration Druid (specID 105) alert definitions
--
-- ┌──────────────────────┬──────────┬────────────────────────────────────────────────┐
-- │ Alert                │ SpellID  │ Trigger                                        │
-- ├──────────────────────┼──────────┼────────────────────────────────────────────────┤
-- │ Lifebloom            │ 33763    │ Alert when MISSING or < 4.5s remaining         │
-- │ Swiftmend            │ 18562    │ Alert when OFF cooldown (ready to cast)         │
-- │ Wild Growth          │ 48438    │ Alert when OFF cooldown (ready to cast)         │
-- │ Abundance            │ 207383   │ Always shown; badge shows current stack count   │
-- │                      │(buff 207640)│ talent ID ≠ buff ID — icon uses 207383,    │
-- │                      │          │ aura query uses 207640                          │
-- │ Convoke the Spirits  │ 391528   │ Ready when OFF CD. TALENT-GATED (IsPlayerSpell)│
-- │                      │          │ Mutually exclusive with Incarnation             │
-- │ Tranquility          │ 740      │ Ready when OFF CD. TALENT-GATED (IsPlayerSpell)│
-- │ Incarnation: ToL     │ 33891    │ Ready when OFF CD. TALENT-GATED (IsPlayerSpell)│
-- │                      │          │ Mutually exclusive with Convoke                 │
-- └──────────────────────┴──────────┴────────────────────────────────────────────────┘
--
-- API used:
--   C_UnitAuras.GetPlayerAuraBySpellID(spellID) → AuraData?
--     AuraData.expirationTime  number   GetTime() when aura expires (0 = no expiry)
--     AuraData.duration        number   total duration in seconds
--     AuraData.applications    number   current stack count
--   C_Spell.GetSpellCooldown(spellID) → SpellCooldownInfo?
--     SpellCooldownInfo.startTime   number   GetTime() when CD started (0 = not on CD)
--     SpellCooldownInfo.duration    number   CD length in seconds
--     SpellCooldownInfo.isEnabled   bool     false when spell is "active" (e.g. form)
--     SpellCooldownInfo.modRate     number   haste modifier on the CD timer

local AddonName, HA = ...

local CLASS_FILENAME = "DRUID"   -- UnitClassBase("player") return value
local SPEC_ID        = 105       -- Restoration

local SPELL_LIFEBLOOM  = 33763
local SPELL_SWIFTMEND  = 18562
local SPELL_WILDGROWTH = 48438
local SPELL_ABUNDANCE       = 207383  -- talent node (used for icon texture + tooltip)
local SPELL_ABUNDANCE_BUFF  = 207640  -- actual player buff applied by the talent
                                       -- (talent ID ≠ buff ID — verified in-game)

-- Major cooldowns — all talent-gated (verified via IsPlayerSpell at runtime).
-- Convoke and Incarnation are mutually exclusive talent choices.
-- NOTE: spell IDs verified in-game by the user — do NOT trust wowhead/wowwiki
-- for these; the retail IDs changed between expansions.
local SPELL_CONVOKE      = 391528   -- Convoke the Spirits (verified in-game March 2026)
local SPELL_TRANQUILITY  = 740      -- Tranquility (verified in-game March 2026)
local SPELL_INCARNATION  = 33891    -- Incarnation: Tree of Life (verified in-game March 2026)

-- How many seconds before Lifebloom expiry we start showing the alert
local LB_WARN_THRESHOLD = 4.5

-- Maximum GCD duration in seconds (base 1.5s; with haste minimum is 0.75s).
-- Any cooldown with duration <= this threshold is treated as "GCD only" and
-- does NOT count as a real cooldown — the spell is still considered ready.
-- Using 1.6 gives a small float buffer above the 1.5s max.
local GCD_THRESHOLD = 1.6

-- ============================================================
-- HELPERS
-- ============================================================
local function GetAura(spellID)
    return C_UnitAuras.GetPlayerAuraBySpellID(spellID)
end

-- Returns SpellCooldownInfo or nil
local function GetCD(spellID)
    return C_Spell.GetSpellCooldown(spellID)
end

-- Returns true if the spell is ready (no real cooldown active).
-- A startTime > 0 with duration <= GCD_THRESHOLD means the spell is only
-- sitting on the Global Cooldown, not an actual spell cooldown — treat it
-- as ready so GCD-triggered SPELL_UPDATE_COOLDOWN events don't flash icons.
local function CDIsReady(cdInfo)
    if not cdInfo then return false end
    if not cdInfo.isEnabled then return false end
    if cdInfo.startTime == 0 or cdInfo.startTime == nil then return true end
    -- GCD-only: real cooldown has not started
    return (cdInfo.duration or 0) <= GCD_THRESHOLD
end

-- Returns true if the player has learned the spell (from spec, talent, etc.).
-- Used to gate talent-dependent alerts — if the spell is not known the alert
-- is immediately deactivated so it never occupies a slot in the icon bar.
-- IsPlayerSpell is a long-standing Blizzard global (pre-docs era); verify
-- in-game if behaviour seems wrong on a new patch.
local function IsKnown(spellID)
    return IsPlayerSpell(spellID) == true
end

-- ============================================================
-- LIFEBLOOM
-- Logic: show alert when Lifebloom is absent OR within LB_WARN_THRESHOLD seconds
-- of expiring. Show the cooldown sweep counting down remaining duration.
-- ============================================================
local function LB_Check()
    local aura    = GetAura(SPELL_LIFEBLOOM)
    local alert   = false
    local start   = 0
    local dur     = 0

    if not aura then
        alert = true
    elseif aura.expirationTime and aura.expirationTime > 0 then
        local remain = aura.expirationTime - GetTime()
        alert = (remain < LB_WARN_THRESHOLD)
        -- Show countdown sweep representing remaining duration
        start = aura.expirationTime - aura.duration
        dur   = aura.duration
    end

    HA:HandleAuraChange("lifebloom", alert, aura)
    -- Always update the sweep so the timer is visible even when alert is inactive
    HA:SetCooldownSweep("lifebloom", start, dur, 1)
end

local lifeblosomDef = {
    key          = "lifebloom",
    name         = "Lifebloom",
    spellID      = SPELL_LIFEBLOOM,
    type         = "aura",
    order        = 1,
    defaultGlow  = "ants",
    defaultText  = "Lifebloom expiring!",
    defaultSound = "lifebloom_expiring.ogg",

    onSpecActivated = LB_Check,

    onAuraUpdate = function(updateInfo)
        -- On full update always re-query
        if not updateInfo or updateInfo.isFullUpdate then
            LB_Check(); return
        end
        -- On incremental, only re-check if Lifebloom was involved
        -- addedAuras contains full AuraData; removed/updated are instance IDs only
        local relevant = false
        if updateInfo.addedAuras then
            for _, a in ipairs(updateInfo.addedAuras) do
                if a.spellId == SPELL_LIFEBLOOM then relevant = true; break end
            end
        end
        -- For removed/updated we don't have spellIDs, so just re-check always —
        -- LB_Check() is cheap (single GetPlayerAuraBySpellID call).
        if not relevant and (updateInfo.removedAuraInstanceIDs or updateInfo.updatedAuraInstanceIDs) then
            relevant = true
        end
        if relevant then LB_Check() end
    end,

    onCooldownUpdate = nil,
}

-- ============================================================
-- SWIFTMEND
-- ============================================================
local function SM_Check()
    local cd    = GetCD(SPELL_SWIFTMEND)
    local ready = CDIsReady(cd)
    -- Clear the sweep when the spell is ready (includes GCD-only state) so a
    -- brief GCD duration never flickers as a cooldown animation on a ready icon.
    local start = (not ready and cd) and cd.startTime or 0
    local dur   = (not ready and cd) and cd.duration  or 0
    local mod   = cd and cd.modRate or 1
    HA:HandleCooldownChange("swiftmend", ready, start, dur, mod)
end

local swiftmendDef = {
    key          = "swiftmend",
    name         = "Swiftmend",
    spellID      = SPELL_SWIFTMEND,
    type         = "cooldown",
    order        = 2,
    defaultGlow  = "action",
    defaultText  = "Swiftmend ready!",
    defaultSound = "swiftmend_ready.ogg",

    onSpecActivated  = SM_Check,
    onCooldownUpdate = SM_Check,
    onAuraUpdate     = nil,
}

-- ============================================================
-- WILD GROWTH
-- ============================================================
local function WG_Check()
    local cd    = GetCD(SPELL_WILDGROWTH)
    local ready = CDIsReady(cd)
    local start = (not ready and cd) and cd.startTime or 0
    local dur   = (not ready and cd) and cd.duration  or 0
    local mod   = cd and cd.modRate or 1
    HA:HandleCooldownChange("wildgrowth", ready, start, dur, mod)
end

local wildGrowthDef = {
    key          = "wildgrowth",
    name         = "Wild Growth",
    spellID      = SPELL_WILDGROWTH,
    type         = "cooldown",
    order        = 3,
    defaultGlow  = "action",
    defaultText  = "Wild Growth ready!",
    defaultSound = "wildgrowth_ready.ogg",

    onSpecActivated  = WG_Check,
    onCooldownUpdate = WG_Check,
    onAuraUpdate     = nil,
}

-- ============================================================
-- ABUNDANCE  (permanent stack tracker)
-- Icon is ALWAYS visible — it acts as a persistent tracker, not a conditional
-- alert.  Two visual states:
--   Missing : red overlay + marching-ants border → "you have no Abundance"
--   Present : clear icon + large centered stack count, color-coded:
--               < 5  stacks → orange
--               5-10 stacks → yellow
--               > 10 stacks → green
-- ============================================================
-- Tracks the previous aura presence so we can detect the present→absent
-- transition and fire the "missing" sound at the right moment.
local abundanceWasPresent = nil

local function AB_Check()
    local aura  = GetAura(SPELL_ABUNDANCE_BUFF)   -- query the buff, not the talent
    local count = aura and (aura.applications or 0) or 0

    -- Always keep the icon visible regardless of buff state.
    -- HandleAuraChange with isActive=true activates on first call;
    -- subsequent calls return early from ActivateAlert but we still
    -- update glow / overlay / count below.
    HA:HandleAuraChange("abundance", true, aura)

    if not aura then
        -- Play the "missing" sound only on the present→absent transition, not
        -- every UNIT_AURA tick while the buff remains absent.
        if abundanceWasPresent then
            HA:PlayAlertSound("abundance")
        end
        abundanceWasPresent = false

        -- Buff missing: red tint + marching ants warning
        HA:SetIconOverlay("abundance", 0.9, 0.1, 0.1, 0.5)
        HA:UpdateGlow("abundance", "ants")
        HA:SetBigCount("abundance", 0)
    else
        abundanceWasPresent = true
        -- Buff present: clear overlay + color-coded stack count
        HA:SetIconOverlay("abundance", 0, 0, 0, 0)
        HA:UpdateGlow("abundance", "none")
        local r, g, b
        if count > 10 then
            r, g, b = 0.1, 1.0, 0.1   -- green
        elseif count >= 5 then
            r, g, b = 1.0, 1.0, 0.1   -- yellow
        else
            r, g, b = 1.0, 0.55, 0.1  -- orange
        end
        HA:SetBigCount("abundance", count, r, g, b)
    end
end

local abundanceDef = {
    key          = "abundance",
    name         = "Abundance",
    spellID      = SPELL_ABUNDANCE,
    type         = "aura_count",
    order        = 4,
    defaultGlow  = "none",   -- AB_Check drives glow via UpdateGlow immediately after
    defaultText  = "",
    defaultSound = "abundance_missing.ogg",

    onSpecActivated = AB_Check,

    onAuraUpdate = function(updateInfo)
        if not updateInfo or updateInfo.isFullUpdate then AB_Check(); return end
        local relevant = false
        if updateInfo.addedAuras then
            for _, a in ipairs(updateInfo.addedAuras) do
                if a.spellId == SPELL_ABUNDANCE_BUFF then relevant = true; break end
            end
        end
        if not relevant and (updateInfo.removedAuraInstanceIDs or updateInfo.updatedAuraInstanceIDs) then
            relevant = true
        end
        if relevant then AB_Check() end
    end,

    onCooldownUpdate = nil,
}

-- ============================================================
-- CONVOKE THE SPIRITS  (talent-gated, mutually exclusive with Incarnation)
-- Shows when the talent is taken AND the spell is off cooldown.
-- ============================================================
local function CV_Check()
    if not IsKnown(SPELL_CONVOKE) then
        -- Talent not taken: ensure the icon stays hidden and return.
        HA:HandleCooldownChange("convoke", false, 0, 0, 1)
        return
    end
    local cd    = GetCD(SPELL_CONVOKE)
    local ready = CDIsReady(cd)
    local start = (not ready and cd) and cd.startTime or 0
    local dur   = (not ready and cd) and cd.duration  or 0
    local mod   = cd and cd.modRate or 1
    HA:HandleCooldownChange("convoke", ready, start, dur, mod)
end

local convokeDef = {
    key          = "convoke",
    name         = "Convoke the Spirits",
    spellID      = SPELL_CONVOKE,
    type         = "cooldown",
    order        = 5,
    defaultGlow  = "action",
    defaultText  = "Convoke ready!",
    defaultSound = "convoke_ready.ogg",

    onSpecActivated  = CV_Check,
    onCooldownUpdate = CV_Check,
    onAuraUpdate     = nil,
}

-- ============================================================
-- TRANQUILITY  (talent-gated)
-- Shows when the talent is taken AND the spell is off cooldown.
-- ============================================================
local function TQ_Check()
    if not IsKnown(SPELL_TRANQUILITY) then
        HA:HandleCooldownChange("tranquility", false, 0, 0, 1)
        return
    end
    local cd    = GetCD(SPELL_TRANQUILITY)
    local ready = CDIsReady(cd)
    local start = (not ready and cd) and cd.startTime or 0
    local dur   = (not ready and cd) and cd.duration  or 0
    local mod   = cd and cd.modRate or 1
    HA:HandleCooldownChange("tranquility", ready, start, dur, mod)
end

local tranquilityDef = {
    key          = "tranquility",
    name         = "Tranquility",
    spellID      = SPELL_TRANQUILITY,
    type         = "cooldown",
    order        = 6,
    defaultGlow  = "action",
    defaultText  = "Tranquility ready!",
    defaultSound = "tranquility_ready.ogg",

    onSpecActivated  = TQ_Check,
    onCooldownUpdate = TQ_Check,
    onAuraUpdate     = nil,
}

-- ============================================================
-- INCARNATION: TREE OF LIFE  (talent-gated, mutually exclusive with Convoke)
-- Shows when the talent is taken AND the spell is off cooldown.
-- Shares order=5 with Convoke — only one will ever be active.
-- ============================================================
local function IT_Check()
    if not IsKnown(SPELL_INCARNATION) then
        HA:HandleCooldownChange("incarnation", false, 0, 0, 1)
        return
    end
    local cd    = GetCD(SPELL_INCARNATION)
    local ready = CDIsReady(cd)
    local start = (not ready and cd) and cd.startTime or 0
    local dur   = (not ready and cd) and cd.duration  or 0
    local mod   = cd and cd.modRate or 1
    HA:HandleCooldownChange("incarnation", ready, start, dur, mod)
end

local incarnationDef = {
    key          = "incarnation",
    name         = "Incarnation: Tree of Life",
    spellID      = SPELL_INCARNATION,
    type         = "cooldown",
    order        = 5,   -- same slot as Convoke; they are mutually exclusive talents
    defaultGlow  = "action",
    defaultText  = "Incarnation ready!",
    defaultSound = "incarnation_ready.ogg",

    onSpecActivated  = IT_Check,
    onCooldownUpdate = IT_Check,
    onAuraUpdate     = nil,
}

-- ============================================================
-- REGISTER
-- ============================================================
HA:RegisterAlert(lifeblosomDef)
HA:RegisterAlert(swiftmendDef)
HA:RegisterAlert(wildGrowthDef)
HA:RegisterAlert(abundanceDef)
HA:RegisterAlert(convokeDef)
HA:RegisterAlert(tranquilityDef)
HA:RegisterAlert(incarnationDef)

HA:RegisterClassSpec({
    classFilename = CLASS_FILENAME,
    specID        = SPEC_ID,
    alertKeys     = {
        "lifebloom", "swiftmend", "wildgrowth", "abundance",
        "convoke", "tranquility", "incarnation",
    },
})
