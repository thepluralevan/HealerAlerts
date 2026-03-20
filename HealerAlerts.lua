-- HealerAlerts.lua
-- Core engine: frame management, event routing, alert rendering, glow effects
--
-- API used (all TWW 11.0+ verified):
--   C_Spell.GetSpellInfo(spellID) -> SpellInfo{iconID, name, ...}
--   C_Spell.GetSpellCooldown(spellID) -> SpellCooldownInfo{startTime,duration,isEnabled,modRate}
--   C_UnitAuras.GetPlayerAuraBySpellID(spellID) -> AuraData?
--   UNIT_AURA event -> (unit, UnitAuraUpdateInfo?)
--   SPELL_UPDATE_COOLDOWN event -> ()
--   GetSpecialization() -> specIndex
--   GetSpecializationInfo(specIndex) -> specID, name, ...
--   UnitClassBase("player") -> classFilename  (e.g. "DRUID")
--   Settings.RegisterCanvasLayoutCategory / Settings.RegisterAddOnCategory
--   ActionButton_ShowOverlayGlow / ActionButton_HideOverlayGlow

local AddonName, HA = ...

-- ============================================================
-- DEFAULTS
-- ============================================================
local DEFAULTS = {
    iconSize      = 48,
    growDirection = "RIGHT",   -- RIGHT | LEFT | UP | DOWN
    iconLocked    = false,
    textLocked    = false,
    iconAnchorX   = 400,
    iconAnchorY   = 300,
    textAnchorX   = 400,
    textAnchorY   = 260,
    alerts        = {},
}

-- ============================================================
-- ADDON STATE
-- ============================================================
HA.alerts         = {}   -- alertKey -> { def, active, auraData }
HA.iconFrames     = {}   -- alertKey -> Button
HA.textFrames     = {}   -- alertKey -> FontString
HA.classDefs      = {}   -- "CLASSFILENAME_specID" -> spec table
HA._pendingAlerts = {}   -- defs registered before ADDON_LOADED
HA._settingsCategory = nil  -- stored so slash cmd can open it

-- ============================================================
-- DB ACCESSOR (only safe after ADDON_LOADED)
-- ============================================================
local function DB()
    return HealerAlertsDB
end

local function AlertCfg(key)
    return DB().alerts[key] or {}
end

-- ============================================================
-- ANCHOR FRAMES
-- ============================================================
local iconAnchor = CreateFrame("Frame", "HealerAlertsIconAnchor", UIParent)
iconAnchor:SetSize(1, 1)
iconAnchor:SetMovable(true)
iconAnchor:EnableMouse(false)

local textAnchor = CreateFrame("Frame", "HealerAlertsTextAnchor", UIParent)
textAnchor:SetSize(300, 120)
textAnchor:SetMovable(true)
textAnchor:EnableMouse(false)

local function UpdateAnchors()
    iconAnchor:ClearAllPoints()
    iconAnchor:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT",
        DB().iconAnchorX, DB().iconAnchorY)
    textAnchor:ClearAllPoints()
    textAnchor:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT",
        DB().textAnchorX, DB().textAnchorY)
end

-- ============================================================
-- DRAG HANDLES
-- ============================================================
local function MakeDragHandle(frame, xKey, yKey, displayName)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.1, 0.55, 0.1, 0.35)

    local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetAllPoints()
    lbl:SetText(displayName)
    lbl:SetTextColor(1, 1, 1)

    frame:SetScript("OnMouseDown", function(self, btn)
        if btn == "LeftButton" then self:StartMoving() end
    end)
    frame:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        -- GetPoint(1) is unreliable here: StartMoving() re-anchors the frame
        -- internally (often to TOPLEFT of UIParent rather than BOTTOMLEFT), so
        -- the x/y offsets it returns no longer correspond to our stored anchor
        -- convention.  GetLeft()/GetBottom() always give absolute screen-space
        -- coordinates which equal the BOTTOMLEFT-of-UIParent offsets we want
        -- (UIParent origin is always 0,0).
        local x = self:GetLeft()
        local y = self:GetBottom()
        if x and y then
            DB()[xKey] = math.floor(x + 0.5)
            DB()[yKey] = math.floor(y + 0.5)
        end
    end)

    bg:Hide(); lbl:Hide()
    return bg, lbl
end

local iconBG, iconLbl = MakeDragHandle(iconAnchor, "iconAnchorX", "iconAnchorY", "HealerAlerts: Icon Bar")
local textBG, textLbl = MakeDragHandle(textAnchor, "textAnchorX", "textAnchorY", "HealerAlerts: Text Alerts")

local function ApplyLockState()
    local il = DB().iconLocked
    local tl = DB().textLocked

    -- Resize iconAnchor to cover the full icon bar so the drag handle has a
    -- usable hit area.  (It was created 1×1 and never resized, making the
    -- green indicator invisible and the frame essentially un-clickable.)
    local iconCount = 0
    for _ in pairs(HA.iconFrames) do iconCount = iconCount + 1 end
    local sz   = DB().iconSize
    local step = sz + 4
    local ext  = iconCount > 0 and (iconCount * step - 4) or sz
    local dir  = DB().growDirection or "RIGHT"
    if dir == "RIGHT" or dir == "LEFT" then
        iconAnchor:SetSize(ext, sz)
    else
        iconAnchor:SetSize(sz, ext)
    end

    -- Icon anchor receives mouse when UNLOCKED; icon buttons receive mouse
    -- when LOCKED (for tooltips).  Buttons are children of iconAnchor and
    -- would otherwise intercept every click, preventing the anchor's
    -- OnMouseDown from ever firing while icons are visible.
    iconAnchor:EnableMouse(not il)
    for _, btn in pairs(HA.iconFrames) do
        btn:EnableMouse(il)
    end
    if il then iconBG:Hide();  iconLbl:Hide()
    else       iconBG:Show();  iconLbl:Show() end

    textAnchor:EnableMouse(not tl)
    if tl then textBG:Hide();  textLbl:Hide()
    else       textBG:Show();  textLbl:Show() end
end
HA.ApplyLockState = ApplyLockState  -- exposed for config UI

-- ============================================================
-- GLOW — ACTION BUTTON STYLE
-- Blizzard's own overlay glow used for proc indicators on action buttons.
-- Works on any frame that has a compatible structure. On regular Frames/Buttons
-- it creates the overlay as a child. Safe to call; guards against nil.
-- ============================================================
local function GlowAction_Show(btn)
    if ActionButton_ShowOverlayGlow then ActionButton_ShowOverlayGlow(btn) end
end
local function GlowAction_Hide(btn)
    if ActionButton_HideOverlayGlow then ActionButton_HideOverlayGlow(btn) end
end

-- ============================================================
-- GLOW — MARCHING ANTS
-- Square texture segments orbit the button perimeter clockwise.
-- Driven through OnUpdate on each icon button (no global ticker needed).
-- ============================================================
local ANTS_N     = 12     -- segment count
local ANTS_SZ    = 3      -- px side of each square
local ANTS_CYCLE = 3.75   -- seconds per full orbit (5× the original 0.75s)

local function Ants_Build(parent)
    local segs = {}
    for i = 1, ANTS_N do
        local t = parent:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(1, 0.92, 0.2, 1)
        t:SetSize(ANTS_SZ, ANTS_SZ)
        t:Hide()
        segs[i] = t
    end
    return { segs = segs, active = false, elapsed = 0, parent = parent }
end

local function Ants_Update(ants, dt)
    if not ants.active then return end
    ants.elapsed = (ants.elapsed + dt) % ANTS_CYCLE
    local p      = ants.parent
    local sz     = p:GetWidth()
    local half   = sz / 2
    local perim  = sz * 4
    local segGap = perim / ANTS_N
    local prog   = (ants.elapsed / ANTS_CYCLE) * perim

    for i, t in ipairs(ants.segs) do
        local d = ((i - 1) * segGap + prog) % perim
        local ox, oy
        if d < sz then
            ox = -half + d;          oy =  half
        elseif d < sz * 2 then
            ox =  half;              oy =  half - (d - sz)
        elseif d < sz * 3 then
            ox =  half - (d - sz*2); oy = -half
        else
            ox = -half;              oy = -half + (d - sz*3)
        end
        t:ClearAllPoints()
        t:SetPoint("CENTER", p, "CENTER", ox, oy)
    end
end

local function Ants_Show(ants) ants.active = true;  ants.elapsed = 0; for _, t in ipairs(ants.segs) do t:Show() end end
local function Ants_Hide(ants) ants.active = false; for _, t in ipairs(ants.segs) do t:Hide() end end

-- ============================================================
-- SOUND
-- ============================================================
local function TryPlaySound(key)
    local snd = AlertCfg(key).sound
    if snd and snd ~= "" then
        PlaySoundFile("Interface\\AddOns\\HealerAlerts\\Sounds\\" .. snd, "Master")
    end
end

-- ============================================================
-- ICON FRAME BUILDER  (called after DB is ready)
-- ============================================================
local function BuildIconFrame(def)
    local size = DB().iconSize
    local btn  = CreateFrame("Button", nil, iconAnchor)
    btn:SetSize(size, size)

    -- Dark background behind icon
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)

    -- Icon texture with trimmed border
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT",     btn, "TOPLEFT",      2,  -2)
    icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2,   2)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    btn._icon = icon

    -- Cooldown sweep overlay
    local cd = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
    cd:SetAllPoints()
    cd:SetDrawEdge(true)
    cd:SetHideCountdownNumbers(false)
    btn._cd = cd

    -- Stack count badge (lower-right, small — for incidental stack display)
    local badge = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    badge:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 2)
    badge:Hide()
    btn._badge = badge

    -- Color overlay — lets alerts tint the icon (e.g. red when a buff is missing).
    -- Sits in OVERLAY layer so it's above the ARTWORK icon but below child frames.
    -- Hidden by default; shown via HA:SetIconOverlay().
    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetPoint("TOPLEFT",     btn, "TOPLEFT",      2,  -2)
    overlay:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2,   2)
    overlay:SetColorTexture(1, 0, 0, 0)
    overlay:Hide()
    btn._overlay = overlay

    -- Large centered count — for stack-tracker alerts that want a prominent number.
    -- Shown/hidden and colored via HA:SetBigCount().
    local bigCount = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalLarge")
    bigCount:SetPoint("CENTER", btn, "CENTER", 0, 0)
    bigCount:Hide()
    btn._bigCount = bigCount

    -- Marching ants effect
    btn._ants = Ants_Build(btn)

    btn:SetScript("OnUpdate", function(self, dt)
        Ants_Update(self._ants, dt)
    end)

    -- Hover tooltip
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if def.spellID then
            GameTooltip:SetSpellByID(def.spellID)
        else
            GameTooltip:SetText(def.name or def.key)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Populate spell icon
    if def.spellID then
        local info = C_Spell.GetSpellInfo(def.spellID)
        if info and info.iconID then icon:SetTexture(info.iconID) end
    elseif def.icon then
        icon:SetTexture(def.icon)
    end

    btn:Hide()
    HA.iconFrames[def.key] = btn
    return btn
end

-- ============================================================
-- TEXT FRAME BUILDER
-- ============================================================
local function BuildTextFrame(def)
    local fs = textAnchor:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetTextColor(1, 0.85, 0.1, 1)
    fs:Hide()
    HA.textFrames[def.key] = fs
    return fs
end

-- ============================================================
-- LAYOUT HELPERS
-- ============================================================
local function LayoutIcons()
    local dir  = DB().growDirection or "RIGHT"
    local size = DB().iconSize
    local step = size + 4

    local ordered = {}
    for key, state in pairs(HA.alerts) do
        if HA.iconFrames[key] then
            ordered[#ordered + 1] = { key = key, order = state.def.order or 99 }
        end
    end
    table.sort(ordered, function(a, b) return a.order < b.order end)

    -- Keep iconAnchor sized to the full bar so the drag handle stays usable.
    local n   = #ordered
    local ext = n > 0 and (n * step - 4) or size
    if dir == "RIGHT" or dir == "LEFT" then
        iconAnchor:SetSize(ext, size)
    else
        iconAnchor:SetSize(size, ext)
    end

    for i, entry in ipairs(ordered) do
        local btn    = HA.iconFrames[entry.key]
        local offset = (i - 1) * step
        btn:ClearAllPoints()
        btn:SetSize(size, size)
        if     dir == "RIGHT" then btn:SetPoint("LEFT",   iconAnchor, "LEFT",    offset, 0)
        elseif dir == "LEFT"  then btn:SetPoint("RIGHT",  iconAnchor, "RIGHT",  -offset, 0)
        elseif dir == "UP"    then btn:SetPoint("BOTTOM", iconAnchor, "BOTTOM",  0,  offset)
        elseif dir == "DOWN"  then btn:SetPoint("TOP",    iconAnchor, "TOP",     0, -offset)
        end
    end
end

local TEXT_LINE_H = 22
local function LayoutTexts()
    -- Collect active alerts that have non-empty text
    local active = {}
    for key, state in pairs(HA.alerts) do
        if state.active then
            local cfg = AlertCfg(key)
            local txt = cfg.text ~= nil and cfg.text or state.def.defaultText
            if txt and txt ~= "" then
                active[#active + 1] = { key = key, order = state.def.order or 99, text = txt }
            end
        end
    end
    table.sort(active, function(a, b) return a.order < b.order end)

    -- Hide all, then re-anchor visible ones
    for _, fs in pairs(HA.textFrames) do
        fs:ClearAllPoints()
        fs:Hide()
    end
    for i, entry in ipairs(active) do
        local fs = HA.textFrames[entry.key]
        if fs then
            fs:SetText(entry.text)
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", textAnchor, "TOPLEFT", 0, -((i - 1) * TEXT_LINE_H))
            fs:Show()
        end
    end
    textAnchor:SetHeight(math.max(#active * TEXT_LINE_H, 22))
end

-- ============================================================
-- GLOW APPLICATION
-- ============================================================
local function ApplyGlow(btn, glowType)
    if glowType == "action" then
        GlowAction_Show(btn)
        Ants_Hide(btn._ants)
    elseif glowType == "ants" then
        GlowAction_Hide(btn)
        Ants_Show(btn._ants)
    else
        GlowAction_Hide(btn)
        Ants_Hide(btn._ants)
    end
end

local function ClearGlow(btn)
    GlowAction_Hide(btn)
    Ants_Hide(btn._ants)
end

-- ============================================================
-- ACTIVATE / DEACTIVATE
-- ============================================================
local function ActivateAlert(key, auraData)
    local state = HA.alerts[key]
    if not state or state.active then return end
    local cfg = AlertCfg(key)
    if cfg.enabled == false then return end

    state.active   = true
    state.auraData = auraData

    local btn = HA.iconFrames[key]
    if btn then
        btn:Show()
        ApplyGlow(btn, cfg.glowType or state.def.defaultGlow or "none")
    end

    TryPlaySound(key)
    LayoutIcons()
    LayoutTexts()
end

local function DeactivateAlert(key)
    local state = HA.alerts[key]
    if not state or not state.active then return end
    state.active   = false
    state.auraData = nil

    local btn = HA.iconFrames[key]
    if btn then btn:Hide(); ClearGlow(btn) end

    LayoutIcons()
    LayoutTexts()
end

-- ============================================================
-- PUBLIC API — for class modules
-- ============================================================

-- Show/update a cooldown sweep on an icon (pass 0,0 to clear)
function HA:SetCooldownSweep(key, startTime, duration, modRate)
    local btn = HA.iconFrames[key]
    if btn then btn._cd:SetCooldown(startTime or 0, duration or 0, modRate or 1) end
end

-- Set or hide the small BOTTOMRIGHT stack count badge on an icon
function HA:SetBadge(key, count)
    local btn = HA.iconFrames[key]
    if not btn then return end
    if count and count > 0 then
        btn._badge:SetText(tostring(count))
        btn._badge:Show()
    else
        btn._badge:Hide()
    end
end

-- Show or hide the full-icon color overlay.
-- Pass r,g,b,a to tint (e.g. 0.9,0.1,0.1,0.5 for a red warning tint).
-- Pass a=0 (or call with no color args) to hide the overlay.
function HA:SetIconOverlay(key, r, g, b, a)
    local btn = HA.iconFrames[key]
    if not btn then return end
    if not a or a <= 0 then
        btn._overlay:Hide()
    else
        btn._overlay:SetColorTexture(r or 1, g or 0, b or 0, a)
        btn._overlay:Show()
    end
end

-- Update the glow on an icon that is already active (ActivateAlert only applies
-- glow on first activation; use this to change it without a full re-activate).
function HA:UpdateGlow(key, glowType)
    local btn = HA.iconFrames[key]
    if not btn then return end
    ApplyGlow(btn, glowType)
end

-- Show a large centered stack count on an icon, colored by the given r,g,b.
-- Pass count=0 (or nil) to hide the label.
function HA:SetBigCount(key, count, r, g, b)
    local btn = HA.iconFrames[key]
    if not btn then return end
    if count and count > 0 then
        btn._bigCount:SetText(tostring(count))
        btn._bigCount:SetTextColor(r or 1, g or 1, b or 1)
        btn._bigCount:Show()
    else
        btn._bigCount:Hide()
    end
end

-- Aura-based alert: pass isActive=true to show, false to hide
function HA:HandleAuraChange(key, isActive, auraData)
    if isActive then ActivateAlert(key, auraData) else DeactivateAlert(key) end
end

-- Cooldown-based alert: isReady=true shows the icon (spell off CD)
function HA:HandleCooldownChange(key, isReady, startTime, duration, modRate)
    HA:SetCooldownSweep(key, startTime, duration, modRate)
    if isReady then ActivateAlert(key, nil) else DeactivateAlert(key) end
end

-- ============================================================
-- REGISTER ALERT DEF  (class files call this at load time)
-- Frame construction is deferred until ADDON_LOADED so DB is available.
-- ============================================================
function HA:RegisterAlert(def)
    HA.alerts[def.key] = { def = def, active = false }
    if HealerAlertsDB then
        -- DB already ready (e.g. second /reload): build now
        BuildIconFrame(def)
        BuildTextFrame(def)
    else
        HA._pendingAlerts[#HA._pendingAlerts + 1] = def
    end
end

-- Register a spec: { classFilename, specID, alertKeys }
-- classFilename = UnitClassBase result: "DRUID", "PRIEST", "SHAMAN", etc.
function HA:RegisterClassSpec(spec)
    local k = spec.classFilename .. "_" .. spec.specID
    HA.classDefs[k] = spec
end

-- ============================================================
-- SPEC DETECTION
-- UnitClassBase("player") is locale-independent. Returns "DRUID" etc.
-- GetSpecializationInfo returns: specID, name, desc, icon, role, ...
-- ============================================================
local function GetSpecKey()
    local idx = GetSpecialization and GetSpecialization()
    if not idx then return nil end
    local specID = select(1, GetSpecializationInfo(idx))
    if not specID then return nil end
    local cls = UnitClassBase("player")
    if not cls then return nil end
    return cls .. "_" .. specID
end

local function OnSpecActivated()
    for key in pairs(HA.alerts) do DeactivateAlert(key) end
    local spec = HA.classDefs[GetSpecKey() or ""]
    if not spec then return end
    for _, key in ipairs(spec.alertKeys) do
        local s = HA.alerts[key]
        if s and s.def.onSpecActivated then s.def.onSpecActivated() end
    end
end

-- ============================================================
-- LAYOUT REFRESH (config UI calls this after changing settings)
-- ============================================================
function HA:RefreshLayout()
    local size = DB().iconSize
    for _, btn in pairs(HA.iconFrames) do btn:SetSize(size, size) end
    UpdateAnchors()
    ApplyLockState()
    LayoutIcons()
    LayoutTexts()
end

-- ============================================================
-- MAIN EVENT FRAME
-- ============================================================
local ef = CreateFrame("Frame")
ef:RegisterEvent("ADDON_LOADED")
ef:RegisterEvent("PLAYER_ENTERING_WORLD")
ef:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ef:RegisterEvent("UNIT_AURA")
ef:RegisterEvent("SPELL_UPDATE_COOLDOWN")

ef:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= AddonName then return end

        HealerAlertsDB = HealerAlertsDB or {}
        for k, v in pairs(DEFAULTS) do
            if HealerAlertsDB[k] == nil then HealerAlertsDB[k] = v end
        end
        HealerAlertsDB.alerts = HealerAlertsDB.alerts or {}

        -- Build frames for all alerts registered before this point
        for _, def in ipairs(HA._pendingAlerts) do
            BuildIconFrame(def)
            BuildTextFrame(def)
        end
        HA._pendingAlerts = {}

        UpdateAnchors()
        ApplyLockState()
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_ENTERING_WORLD" then
        OnSpecActivated()

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        OnSpecActivated()

    elseif event == "UNIT_AURA" then
        local unit, updateInfo = ...
        if unit ~= "player" then return end
        local spec = HA.classDefs[GetSpecKey() or ""]
        if not spec then return end
        for _, key in ipairs(spec.alertKeys) do
            local s = HA.alerts[key]
            if s and s.def.onAuraUpdate then s.def.onAuraUpdate(updateInfo) end
        end

    elseif event == "SPELL_UPDATE_COOLDOWN" then
        local spec = HA.classDefs[GetSpecKey() or ""]
        if not spec then return end
        for _, key in ipairs(spec.alertKeys) do
            local s = HA.alerts[key]
            if s and s.def.onCooldownUpdate then s.def.onCooldownUpdate() end
        end
    end
end)

-- ============================================================
-- SLASH COMMANDS
--   /ha          → open settings panel
--   /ha lock     → toggle anchor lock
--   /ha reset    → reset anchor positions
-- ============================================================
SLASH_HEALERALERTS1 = "/ha"
SLASH_HEALERALERTS2 = "/healeralerts"
SlashCmdList["HEALERALERTS"] = function(msg)
    local cmd = strtrim(msg):lower()
    if cmd == "" or cmd == "config" or cmd == "options" then
        if HA._settingsCategory then
            Settings.OpenToCategory(HA._settingsCategory)
        else
            print("|cff00ff00HealerAlerts:|r Settings not yet loaded. Try after character login.")
        end
    elseif cmd == "lock" or cmd == "unlock" then
        local locked = not DB().iconLocked
        DB().iconLocked = locked
        DB().textLocked = locked
        ApplyLockState()
        local stateStr = locked and "|cffff4444locked|r" or "|cff44ff44unlocked|r"
        print("|cff00ff00HealerAlerts:|r Frames " .. stateStr ..
              (not locked and " — drag to reposition, /ha lock when done." or "."))
    elseif cmd == "reset" then
        DB().iconAnchorX = DEFAULTS.iconAnchorX
        DB().iconAnchorY = DEFAULTS.iconAnchorY
        DB().textAnchorX = DEFAULTS.textAnchorX
        DB().textAnchorY = DEFAULTS.textAnchorY
        UpdateAnchors()
        print("|cff00ff00HealerAlerts:|r Anchor positions reset.")
    else
        print("|cff00ff00HealerAlerts:|r /ha  |  /ha lock  |  /ha reset")
    end
end
