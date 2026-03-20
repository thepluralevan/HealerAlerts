-- Classes/RestoDruid.lua
-- Restoration Druid (specID 105) alert definitions
--
-- ┌─────────────┬──────────┬────────────────────────────────────────────────┐
-- │ Alert        │ SpellID  │ Trigger                                        │
-- ├─────────────┼──────────┼────────────────────────────────────────────────┤
-- │ Lifebloom    │ 33763    │ Alert when MISSING or < 4.5s remaining         │
-- │ Swiftmend    │ 18562    │ Alert when OFF cooldown (ready to cast)         │
-- │ Wild Growth  │ 48438    │ Alert when OFF cooldown (ready to cast)         │
-- │ Abundance    │ 207383   │ Always shown; badge shows current stack count   │
-- └─────────────┴──────────┴────────────────────────────────────────────────┘
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
local SPELL_ABUNDANCE  = 207383

-- How many seconds before Lifebloom expiry we start showing the alert
local LB_WARN_THRESHOLD = 4.5

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

-- Returns true if the spell is ready (no active cooldown)
local function CDIsReady(cdInfo)
    if not cdInfo then return false end
    -- startTime == 0 means not on cooldown; also must be enabled
    return cdInfo.isEnabled and (cdInfo.startTime == 0 or cdInfo.startTime == nil)
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
    key         = "lifebloom",
    name        = "Lifebloom",
    spellID     = SPELL_LIFEBLOOM,
    type        = "aura",
    order       = 1,
    defaultGlow = "ants",
    defaultText = "Lifebloom expiring!",

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
    local start = cd and cd.startTime  or 0
    local dur   = cd and cd.duration   or 0
    local mod   = cd and cd.modRate    or 1
    HA:HandleCooldownChange("swiftmend", ready, start, dur, mod)
end

local swiftmendDef = {
    key         = "swiftmend",
    name        = "Swiftmend",
    spellID     = SPELL_SWIFTMEND,
    type        = "cooldown",
    order       = 2,
    defaultGlow = "action",
    defaultText = "Swiftmend ready!",

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
    local start = cd and cd.startTime or 0
    local dur   = cd and cd.duration  or 0
    local mod   = cd and cd.modRate   or 1
    HA:HandleCooldownChange("wildgrowth", ready, start, dur, mod)
end

local wildGrowthDef = {
    key         = "wildgrowth",
    name        = "Wild Growth",
    spellID     = SPELL_WILDGROWTH,
    type        = "cooldown",
    order       = 3,
    defaultGlow = "action",
    defaultText = "Wild Growth ready!",

    onSpecActivated  = WG_Check,
    onCooldownUpdate = WG_Check,
    onAuraUpdate     = nil,
}

-- ============================================================
-- ABUNDANCE  (stack tracker)
-- Always shows when any stacks are present; badge = current count.
-- defaultText intentionally empty — badge is the primary indicator.
-- ============================================================
local function AB_Check()
    local aura = GetAura(SPELL_ABUNDANCE)
    HA:HandleAuraChange("abundance", aura ~= nil, aura)
    HA:SetBadge("abundance", aura and (aura.applications or 0) or 0)
end

local abundanceDef = {
    key         = "abundance",
    name        = "Abundance",
    spellID     = SPELL_ABUNDANCE,
    type        = "aura_count",
    order       = 4,
    defaultGlow = "none",
    defaultText = "",

    onSpecActivated = AB_Check,

    onAuraUpdate = function(updateInfo)
        if not updateInfo or updateInfo.isFullUpdate then AB_Check(); return end
        local relevant = false
        if updateInfo.addedAuras then
            for _, a in ipairs(updateInfo.addedAuras) do
                if a.spellId == SPELL_ABUNDANCE then relevant = true; break end
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
-- REGISTER
-- ============================================================
HA:RegisterAlert(lifeblosomDef)
HA:RegisterAlert(swiftmendDef)
HA:RegisterAlert(wildGrowthDef)
HA:RegisterAlert(abundanceDef)

HA:RegisterClassSpec({
    classFilename = CLASS_FILENAME,
    specID        = SPEC_ID,
    alertKeys     = { "lifebloom", "swiftmend", "wildgrowth", "abundance" },
})
