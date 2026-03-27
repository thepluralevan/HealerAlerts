-- JouicyReminders.lua
-- Core engine: four independent alert categories, each with its own anchor.
--
--   cooldown   — spell cooldown icons  (blue drag handle)
--   upkeep     — persistent tracker icons (green drag handle)
--   rotational — rotational priority icons (orange drag handle)
--   text       — scrolling text alerts (purple drag handle)
--
-- API used (all TWW / Midnight 12.0.x verified):
--   C_Spell.GetSpellInfo(spellID) -> SpellInfo{iconID, name, ...}
--   C_Spell.GetSpellCooldown(spellID) -> SpellCooldownInfo{...}
--   C_UnitAuras.GetPlayerAuraBySpellID(spellID) -> AuraData?
--   UNIT_AURA, SPELL_UPDATE_COOLDOWN, PLAYER_TALENT_UPDATE, etc.
--   ActionButton_ShowOverlayGlow / ActionButton_HideOverlayGlow

local AddonName, JR = ...

-- ============================================================
-- CONSTANTS
-- ============================================================
local CATEGORIES      = { "cooldown", "upkeep", "rotational", "text" }
local ICON_CATEGORIES = { "cooldown", "upkeep", "rotational" }

-- Default config for each anchor (x/y = BOTTOMLEFT offset from UIParent origin)
local ANCHOR_DEFAULTS = {
    cooldown   = { x = 400, y = 300, locked = false, hidden = false, iconSize = 48,
                   growDirection = "RIGHT", showKeybinds = false, keybindFontSize = 12 },
    upkeep     = { x = 400, y = 240, locked = false, hidden = false, iconSize = 48,
                   growDirection = "RIGHT" },
    rotational = { x = 600, y = 300, locked = false, hidden = false, iconSize = 48,
                   growDirection = "RIGHT" },
    text       = { x = 400, y = 180, locked = false, hidden = false },
}

-- Drag handle colors (r, g, b, a)
local ANCHOR_COLORS = {
    cooldown   = { 0.1,  0.4,  0.9,  0.45 },   -- blue
    upkeep     = { 0.1,  0.8,  0.1,  0.45 },   -- green
    rotational = { 0.9,  0.5,  0.1,  0.45 },   -- orange
    text       = { 0.6,  0.1,  0.9,  0.45 },   -- purple
}

local ANCHOR_NAMES = {
    cooldown   = "JR: Cooldowns",
    upkeep     = "JR: Upkeep",
    rotational = "JR: Rotational",
    text       = "JR: Text Alerts",
}

-- Text shown for active alerts that have no explicit defaultText.
-- Resolution order: user cfg.text > def.defaultText > this template
local CATEGORY_TEXT_TEMPLATE = {
    cooldown   = "%s is ready!",
    upkeep     = "%s is missing!",
    rotational = "Use %s!",
}

-- ============================================================
-- STATE
-- ============================================================
JR.alerts         = {}   -- alertKey -> { def, active, auraData }
JR.iconFrames     = {}   -- alertKey -> Button
JR.textFrames     = {}   -- alertKey -> FontString
JR.classDefs      = {}   -- "CLASSFILENAME_specID" -> spec table
JR._pendingAlerts = {}   -- defs registered before ADDON_LOADED
JR._settingsCategory = nil

-- ============================================================
-- ANCHOR FRAMES  (created at file load; positioned after ADDON_LOADED)
-- ============================================================
local anchorFrames = {}   -- cat -> Frame
local anchorBGs    = {}   -- cat -> Texture  (drag handle background)
local anchorLbls   = {}   -- cat -> FontString (drag handle label)

for _, cat in ipairs(CATEGORIES) do
    local f = CreateFrame("Frame", "JouicyReminders_Anchor_" .. cat, UIParent)
    f:SetSize(1, 1)
    f:SetMovable(true)
    f:EnableMouse(false)
    anchorFrames[cat] = f
end

-- ============================================================
-- DB ACCESSORS  (only safe after ADDON_LOADED)
-- ============================================================
local function DB()
    return JouicyRemindersDB
end

local function AnchorCfg(cat)
    return DB().anchors[cat]
end

local function AlertCfg(key)
    return DB().alerts[key] or {}
end

-- ============================================================
-- DRAG HANDLES
-- ============================================================
local function MakeDragHandle(cat)
    local frame = anchorFrames[cat]
    local col   = ANCHOR_COLORS[cat]

    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(col[1], col[2], col[3], col[4])

    local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetAllPoints()
    lbl:SetText(ANCHOR_NAMES[cat])
    lbl:SetTextColor(1, 1, 1)

    frame:SetScript("OnMouseDown", function(self, btn)
        if btn == "LeftButton" then self:StartMoving() end
    end)
    frame:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        -- GetLeft()/GetBottom() give absolute screen coords == BOTTOMLEFT-of-UIParent
        -- offsets we store (UIParent origin is always 0,0).
        local x = self:GetLeft()
        local y = self:GetBottom()
        if x and y then
            AnchorCfg(cat).x = math.floor(x + 0.5)
            AnchorCfg(cat).y = math.floor(y + 0.5)
        end
    end)

    bg:Hide(); lbl:Hide()
    anchorBGs[cat]  = bg
    anchorLbls[cat] = lbl
end

for _, cat in ipairs(CATEGORIES) do
    MakeDragHandle(cat)
end

local function UpdateAnchors()
    for _, cat in ipairs(CATEGORIES) do
        local cfg = AnchorCfg(cat)
        local f   = anchorFrames[cat]
        f:ClearAllPoints()
        f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", cfg.x, cfg.y)
    end
end

-- ============================================================
-- GLOW — ACTION BUTTON STYLE
-- Blizzard's overlay glow used for proc indicators on action buttons.
-- ============================================================
local function GlowAction_Show(btn)
    if ActionButton_ShowOverlayGlow then ActionButton_ShowOverlayGlow(btn) end
end
local function GlowAction_Hide(btn)
    if ActionButton_HideOverlayGlow then ActionButton_HideOverlayGlow(btn) end
end

-- ============================================================
-- GLOW — MARCHING ANTS
-- Square texture segments orbit the button perimeter clockwise,
-- driven by OnUpdate on each icon button.
-- ============================================================
local ANTS_N     = 12
local ANTS_SZ    = 3
local ANTS_CYCLE = 3.75   -- seconds per full orbit

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
            ox = -half + d;           oy =  half
        elseif d < sz * 2 then
            ox =  half;               oy =  half - (d - sz)
        elseif d < sz * 3 then
            ox =  half - (d - sz*2);  oy = -half
        else
            ox = -half;               oy = -half + (d - sz*3)
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
    local cfg   = AlertCfg(key)
    local state = JR.alerts[key]
    local snd   = (cfg.sound and cfg.sound ~= "" and cfg.sound)
               or (state and state.def.defaultSound)
    if snd and snd ~= "" then
        PlaySoundFile("Interface\\AddOns\\JouicyReminders\\Sounds\\" .. snd, "Master")
    end
end

-- ============================================================
-- KEYBIND HELPERS
-- Maps an action slot number → the WoW binding command string so we can call
-- GetBindingKey(cmd) to find the player's actual key assignment.
--
-- Slot layout (all live in the game's flat 1-180 slot namespace):
--   1-12   Main action bar   (ActionButton1-12)
--   13-24  Multi-bar 1 BL    (MultiActionBar1Button1-12)
--   25-36  Multi-bar 2 BR    (MultiActionBar2Button1-12)
--   37-48  Multi-bar 3 Right (MultiActionBar3Button1-12)
--   49-60  Multi-bar 4 Left  (MultiActionBar4Button1-12)
--   61-72  Multi-bar 5       (MultiActionBar5Button1-12)
--   73-84  Multi-bar 6       (MultiActionBar6Button1-12)
--   85-96  Multi-bar 7       (MultiActionBar7Button1-12)
--   97-108 Multi-bar 8       (MultiActionBar8Button1-12)
-- ============================================================
local SLOT_RANGES = {
    { 1,   12,  "ACTIONBUTTON",           0   },
    { 13,  24,  "MULTIACTIONBAR1BUTTON",  12  },
    { 25,  36,  "MULTIACTIONBAR2BUTTON",  24  },
    { 37,  48,  "MULTIACTIONBAR3BUTTON",  36  },
    { 49,  60,  "MULTIACTIONBAR4BUTTON",  48  },
    { 61,  72,  "MULTIACTIONBAR5BUTTON",  60  },
    { 73,  84,  "MULTIACTIONBAR6BUTTON",  72  },
    { 85,  96,  "MULTIACTIONBAR7BUTTON",  84  },
    { 97,  108, "MULTIACTIONBAR8BUTTON",  96  },
    -- Extra ranges for TWW expanded bar layout.  Binding command names
    -- beyond MULTIACTIONBAR8BUTTON may not exist in all builds; if
    -- GetBindingKey returns nil for them that is fine — the slot is still
    -- visited so the texture / spellID match can succeed, and the binding
    -- is reported as unbound rather than silently skipped.
    { 109, 120, "MULTIACTIONBAR9BUTTON",  108 },
    { 121, 132, "MULTIACTIONBAR10BUTTON", 120 },
    { 133, 144, "MULTIACTIONBAR11BUTTON", 132 },
    { 145, 156, "MULTIACTIONBAR12BUTTON", 144 },
}

local function SlotToBindingCmd(slot)
    for _, r in ipairs(SLOT_RANGES) do
        if slot >= r[1] and slot <= r[2] then
            return r[3] .. (slot - r[4])
        end
    end
    return nil
end

-- Ordered list of Blizzard default action bar button frame name prefixes.
-- Derived from a working production addon (CooldownManagerCentered).
-- Reading .action (slot number) and .commandName (binding target) directly
-- from the frame is authoritative — the frame knows its own slot and binding
-- regardless of what our static SLOT_RANGES table says.
local BLIZZARD_BAR_PREFIXES = {
    "ActionButton",               -- Bar 1: main action bar
    "MultiBarBottomLeftButton",   -- Bar 2
    "MultiBarBottomRightButton",  -- Bar 3
    "MultiBarRightButton",        -- Bar 4
    "MultiBarLeftButton",         -- Bar 5
    "MultiBar5Button",            -- Bar 6 (TWW)
    "MultiBar6Button",            -- Bar 7 (TWW)
    "MultiBar7Button",            -- Bar 8 (TWW)
}

-- Safe wrappers for legacy macro C functions that may not exist in all
-- WoW versions.  We capture them once at load time so callers never need
-- nil-guard boilerplate.
local _GetMacroSpell = type(GetMacroSpell) == "function" and GetMacroSpell or nil
local _GetMacroBody  = type(GetMacroBody)  == "function" and GetMacroBody  or nil
local _GetMacroInfo  = type(GetMacroInfo)  == "function" and GetMacroInfo  or nil
-- GetMacroInfo(index) → name, iconTexture, body   (pre-docs legacy global)

-- Returns true if the macro at macroIndex casts/shows the spell with spellID.
--
-- Three-path approach (each path is guarded in case the API was removed):
--   1. GetMacroSpell(index)        – instant; may be nil/removed in TWW
--   2. GetMacroBody(index)         – reads raw text; may be nil/removed in TWW
--   3. GetMacroInfo(index) body    – fallback body source if GetMacroBody gone
-- Body parsing strips [@condition] blocks and compares spell name
-- case-insensitively against C_Spell.GetSpellInfo(spellID).name.
local function MacroCastsSpell(macroIndex, spellID)
    -- Path 1: GetMacroSpell (fast; only works when WoW can resolve the spell
    -- without a live target — bare #showtooltip macros return nil here).
    if _GetMacroSpell then
        local ok, macroSID = pcall(_GetMacroSpell, macroIndex)
        if ok and macroSID == spellID then return true end
    end

    -- Path 2 & 3: get the raw macro body text.
    local body
    if _GetMacroBody then
        local ok, b = pcall(_GetMacroBody, macroIndex)
        if ok then body = b end
    end
    if not body and _GetMacroInfo then
        -- GetMacroInfo returns: name, iconTexture, body
        local ok, _, _, b = pcall(_GetMacroInfo, macroIndex)
        if ok then body = b end
    end
    if not body then return false end

    local info = C_Spell.GetSpellInfo(spellID)
    local wantName = info and info.name
    if not wantName then return false end
    wantName = wantName:lower()

    for line in body:gmatch("[^\n]+") do
        -- Match /cast and /use lines.
        local castArgs = line:match("^%s*/cast%s+(.+)")
                      or line:match("^%s*/use%s+(.+)")
        if castArgs then
            -- Strip all conditional blocks: [@mouseover], [mod:shift], etc.
            -- %b[] matches a balanced [...] pair.
            local noConditions = castArgs:gsub("%b[]%s*", "")
            -- Handle semicolon-separated fallback chains: "Spell1; Spell2"
            for part in noConditions:gmatch("[^;]+") do
                local trimmed = part:match("^%s*(.-)%s*$")
                if trimmed then
                    -- Strip WoW's "no-cancel" ! prefix (e.g. /cast !Tranquility)
                    if trimmed:sub(1, 1) == "!" then trimmed = trimmed:sub(2) end
                    if trimmed:lower() == wantName then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- Returns a short display string for the first keybind found for spellID,
-- or nil if the spell is not on any action bar or has no binding.
--
-- TWW 10.2+ note: GetActionInfo returns THREE values for macro slots:
--   actionType, id, subType
--   subType = "spell"  →  id is the resolved spellID (reliable, direct match)
--   subType = "item"   →  id is GARBAGE (== slot-1, WoWUIBugs #495).
--                          For these we use GetActionText(slot) to get the
--                          macro's title, then GetMacroSpell(title) — passing
--                          a string name, not an index — which correctly
--                          resolves the spell even for /cast !Tranquility etc.
--   (no subType)       →  pre-10.2 / unknown; id treated as macro index.
--
-- Primary scan: Blizzard action bar button frames (bar 1 first).
--   button.action      → actual slot number (authoritative)
--   button.commandName → exact binding target string for GetBindingKey
-- Fallback: SLOT_RANGES table scan for slots not in standard frames.
-- Key modifiers are shortened: CTRL- → ^  SHIFT- → +  ALT- → A-
local function GetSpellKeybind(spellID)
    if not spellID then return nil end

    -- Pre-fetch icon ID as last-resort texture fallback.
    local spellInfoForIcon = C_Spell.GetSpellInfo(spellID)
    local spellIconID      = spellInfoForIcon and spellInfoForIcon.iconID

    -- Formats a raw binding key string into the short display form.
    local function FormatKey(key)
        if not key or key == "" then return nil end
        return key:gsub("CTRL%-", "^"):gsub("SHIFT%-", "+"):gsub("ALT%-", "A-")
    end

    -- Returns a formatted key if slot/cmd resolve to spellID, else nil.
    -- Implements the full TWW subType-aware matching strategy.
    local function CheckSlot(slot, cmd)
        if not slot or not cmd then return nil end
        local actionType, id, subType = GetActionInfo(slot)
        local matches = false

        if actionType == "spell" and id == spellID then
            matches = true

        elseif actionType == "macro" then
            if subType == "spell" then
                -- TWW direct: id is the resolved spellID.
                matches = (id == spellID)

            else
                -- subType="item" (id is garbage) or no subType.
                -- Strategy 1: GetMacroSpell(macroName) — pass the macro's
                -- title as a string, which WoW resolves from the macro body.
                -- This is how CooldownManagerCentered handles item macros and
                -- avoids the garbage-id problem entirely.
                local macroName = GetActionText and GetActionText(slot)
                if macroName and macroName ~= "" and _GetMacroSpell then
                    local ok, macroSID = pcall(_GetMacroSpell, macroName)
                    if ok and macroSID == spellID then
                        matches = true
                    end
                end

                -- Strategy 2 (pre-TWW / no subType, numeric id available):
                -- MacroCastsSpell body parse via the numeric macro index.
                if not matches and (not subType) and id and id ~= 0 then
                    matches = MacroCastsSpell(id, spellID)
                end

                -- Strategy 3: icon texture comparison (last resort).
                if not matches and spellIconID then
                    local tex = GetActionTexture and GetActionTexture(slot)
                    if tex and tex == spellIconID then matches = true end
                end
            end
        end

        if matches then
            return FormatKey(GetBindingKey(cmd))
        end
        return nil
    end

    -- ── Primary scan: Blizzard action bar button frames ──────────────────
    -- button.action gives the real slot; button.commandName gives the exact
    -- binding target.  Both come from the frame itself, so they are always
    -- correct regardless of page state or TWW UI changes.
    for _, prefix in ipairs(BLIZZARD_BAR_PREFIXES) do
        for btn = 1, 12 do
            local button = _G[prefix .. btn]
            if button then
                local key = CheckSlot(button.action, button.commandName)
                if key then return key end
            end
        end
    end

    -- ── Fallback: SLOT_RANGES scan ───────────────────────────────────────
    -- Catches any slots not covered by the eight standard Blizzard bar
    -- frames above (e.g. extra TWW bars, or addons that reuse slot numbers
    -- outside the standard prefix naming).
    for slot = 1, 156 do
        local cmd = SlotToBindingCmd(slot)
        if cmd then
            local key = CheckSlot(slot, cmd)
            if key then return key end
        end
    end

    return nil
end

-- Refresh the keybind label on a single icon.
local function UpdateKeybindLabel(key)
    local state = JR.alerts[key]
    local btn   = JR.iconFrames[key]
    if not state or not btn or not btn._keybind then return end

    local cfg  = AnchorCfg("cooldown")
    local show = cfg.showKeybinds
    if not show then
        btn._keybind:Hide()
        return
    end

    local fontSize = cfg.keybindFontSize or 12
    btn._keybind:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")

    local kb = GetSpellKeybind(state.def.spellID)
    if kb then
        btn._keybind:SetText(kb)
        btn._keybind:Show()
    else
        btn._keybind:Hide()
    end
end

-- Refresh all cooldown icon keybind labels.
local function UpdateAllKeybinds()
    for key, state in pairs(JR.alerts) do
        if state.def.category == "cooldown" then
            UpdateKeybindLabel(key)
        end
    end
end
JR.UpdateAllKeybinds = UpdateAllKeybinds   -- expose for config UI

-- ============================================================
-- ICON FRAME BUILDER  (called after DB is ready)
-- Parented to the anchor frame for the alert's category.
-- ============================================================
local function BuildIconFrame(def)
    local cat    = def.category or "cooldown"
    local anchor = anchorFrames[cat]
    local size   = AnchorCfg(cat).iconSize or 48
    local btn    = CreateFrame("Button", nil, anchor)
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

    -- Stack count badge (lower-right, small)
    local badge = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    badge:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 2)
    badge:Hide()
    btn._badge = badge

    -- Color overlay — tints the icon (e.g. red when a buff is missing).
    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetPoint("TOPLEFT",     btn, "TOPLEFT",      2,  -2)
    overlay:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2,   2)
    overlay:SetColorTexture(1, 0, 0, 0)
    overlay:Hide()
    btn._overlay = overlay

    -- Large centered count — for stack-tracker alerts.
    local bigCount = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalLarge")
    bigCount:SetPoint("CENTER", btn, "CENTER", 0, 0)
    bigCount:Hide()
    btn._bigCount = bigCount

    -- Keybind label — upper-right corner, cooldown category only.
    -- Shown/hidden and sized by UpdateKeybindLabel(); nil on non-cooldown icons.
    if cat == "cooldown" then
        local kb = btn:CreateFontString(nil, "OVERLAY")
        kb:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
        kb:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -2, -3)
        kb:SetTextColor(1, 1, 1)
        kb:Hide()
        btn._keybind = kb
    end

    -- Marching ants effect
    btn._ants = Ants_Build(btn)
    btn:SetScript("OnUpdate", function(self, dt) Ants_Update(self._ants, dt) end)

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
    JR.iconFrames[def.key] = btn
    return btn
end

-- ============================================================
-- TEXT FRAME BUILDER
-- All text frames are parented to the text anchor.
-- ============================================================
local function BuildTextFrame(def)
    local fs = anchorFrames["text"]:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetTextColor(1, 0.85, 0.1, 1)
    fs:Hide()
    JR.textFrames[def.key] = fs
    return fs
end

-- ============================================================
-- LAYOUT HELPERS
-- ============================================================

-- Layout icons for a single category's anchor.
-- Only active alerts occupy slots — no phantom gaps for hidden/ungated icons.
local function LayoutIconsForCategory(cat)
    local cfg    = AnchorCfg(cat)
    local dir    = cfg.growDirection or "RIGHT"
    local size   = cfg.iconSize or 48
    local step   = size + 4
    local anchor = anchorFrames[cat]

    -- ── Hidden module: collapse everything and bail out ──────────────────
    if cfg.hidden then
        anchor:Hide()
        for key, state in pairs(JR.alerts) do
            if state.def.category == cat and JR.iconFrames[key] then
                JR.iconFrames[key]:Hide()
            end
        end
        return
    end

    -- ── Module is visible: ensure anchor and all active icons are shown ──
    -- This handles the case where the module was just un-hidden; active
    -- alerts need to be re-shown because they were hidden by the block above.
    anchor:Show()
    for key, state in pairs(JR.alerts) do
        if state.def.category == cat and JR.iconFrames[key] then
            if state.active and AlertCfg(key).enabled ~= false then
                JR.iconFrames[key]:Show()
            end
        end
    end

    local ordered = {}
    for key, state in pairs(JR.alerts) do
        if state.def.category == cat and JR.iconFrames[key] and state.active then
            ordered[#ordered + 1] = { key = key, order = state.def.order or 99 }
        end
    end
    table.sort(ordered, function(a, b) return a.order < b.order end)

    local n   = #ordered
    local ext = n > 0 and (n * step - 4) or size
    if dir == "RIGHT" or dir == "LEFT" then
        anchor:SetSize(ext, size)
    else
        anchor:SetSize(size, ext)
    end

    for i, entry in ipairs(ordered) do
        local btn    = JR.iconFrames[entry.key]
        local offset = (i - 1) * step
        btn:ClearAllPoints()
        btn:SetSize(size, size)
        if     dir == "RIGHT" then btn:SetPoint("LEFT",   anchor, "LEFT",    offset, 0)
        elseif dir == "LEFT"  then btn:SetPoint("RIGHT",  anchor, "RIGHT",  -offset, 0)
        elseif dir == "UP"    then btn:SetPoint("BOTTOM", anchor, "BOTTOM",  0,  offset)
        elseif dir == "DOWN"  then btn:SetPoint("TOP",    anchor, "TOP",     0, -offset)
        end
    end
end

local function LayoutIcons()
    for _, cat in ipairs(ICON_CATEGORIES) do
        LayoutIconsForCategory(cat)
    end
end

local TEXT_LINE_H = 22
local function LayoutTexts()
    -- When the text module is hidden, hide everything and bail out.
    if AnchorCfg("text").hidden then
        anchorFrames["text"]:Hide()
        for _, fs in pairs(JR.textFrames) do fs:Hide() end
        return
    end
    anchorFrames["text"]:Show()

    -- Collect active alerts from all categories that have displayable text.
    -- Text resolution: user cfg.text > def.defaultText > category template.
    local active = {}
    for key, state in pairs(JR.alerts) do
        if state.active then
            local def = state.def
            local cfg = AlertCfg(key)
            local txt
            if cfg.text ~= nil then
                txt = cfg.text
            elseif def.defaultText ~= nil then
                txt = def.defaultText
            else
                local tmpl = CATEGORY_TEXT_TEMPLATE[def.category or "cooldown"]
                txt = tmpl and string.format(tmpl, def.name or def.key) or nil
            end
            if txt and txt ~= "" then
                active[#active + 1] = { key = key, order = def.order or 99, text = txt }
            end
        end
    end
    table.sort(active, function(a, b) return a.order < b.order end)

    for _, fs in pairs(JR.textFrames) do
        fs:ClearAllPoints()
        fs:Hide()
    end
    for i, entry in ipairs(active) do
        local fs = JR.textFrames[entry.key]
        if fs then
            fs:SetText(entry.text)
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", anchorFrames["text"], "TOPLEFT", 0, -((i - 1) * TEXT_LINE_H))
            fs:Show()
        end
    end
    anchorFrames["text"]:SetHeight(math.max(#active * TEXT_LINE_H, 22))
end

-- ============================================================
-- LOCK STATE  (independent per anchor)
-- ============================================================
local function ApplyLockStateForCategory(cat)
    local cfg    = AnchorCfg(cat)
    local locked = cfg.locked
    local anchor = anchorFrames[cat]

    -- Hidden modules have no visible anchor — nothing to lock/unlock.
    if cfg.hidden then return end

    if cat ~= "text" then
        -- Resize anchor to cover the actual current icon bar
        local size  = cfg.iconSize or 48
        local step  = size + 4
        local dir   = cfg.growDirection or "RIGHT"
        local count = 0
        for key, state in pairs(JR.alerts) do
            if state.def.category == cat and JR.iconFrames[key] and state.active then
                count = count + 1
            end
        end
        local ext = count > 0 and (count * step - 4) or size
        if dir == "RIGHT" or dir == "LEFT" then
            anchor:SetSize(ext, size)
        else
            anchor:SetSize(size, ext)
        end

        -- When unlocked: anchor receives mouse (for dragging).
        -- When locked: individual icon buttons receive mouse (for tooltips).
        -- Icon buttons are children of the anchor and would intercept clicks
        -- during dragging, so we swap mouse ownership here.
        anchor:EnableMouse(not locked)
        for key, state in pairs(JR.alerts) do
            if state.def.category == cat and JR.iconFrames[key] then
                JR.iconFrames[key]:EnableMouse(locked)
            end
        end
    else
        anchor:SetSize(300, 120)
        anchor:EnableMouse(not locked)
    end

    if locked then
        anchorBGs[cat]:Hide()
        anchorLbls[cat]:Hide()
    else
        anchorBGs[cat]:Show()
        anchorLbls[cat]:Show()
    end
end

local function ApplyLockState()
    for _, cat in ipairs(CATEGORIES) do
        ApplyLockStateForCategory(cat)
    end
end
JR.ApplyLockState = ApplyLockState

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
    local state = JR.alerts[key]
    if not state or state.active then return end
    local cfg = AlertCfg(key)
    if cfg.enabled == false then return end

    state.active   = true
    state.auraData = auraData

    local btn = JR.iconFrames[key]
    if btn then
        -- Don't surface the icon if its module is currently hidden.
        if not AnchorCfg(state.def.category or "cooldown").hidden then
            btn:Show()
            ApplyGlow(btn, cfg.glowType or state.def.defaultGlow or "none")
        end
    end

    TryPlaySound(key)
    LayoutIcons()
    LayoutTexts()
end

local function DeactivateAlert(key)
    local state = JR.alerts[key]
    if not state or not state.active then return end
    state.active   = false
    state.auraData = nil

    local btn = JR.iconFrames[key]
    if btn then btn:Hide(); ClearGlow(btn) end

    LayoutIcons()
    LayoutTexts()
end

-- ============================================================
-- PUBLIC API — for class modules
-- ============================================================

-- Show/update a cooldown sweep on an icon (pass 0, 0 to clear)
function JR:SetCooldownSweep(key, startTime, duration, modRate)
    local btn = JR.iconFrames[key]
    if btn then btn._cd:SetCooldown(startTime or 0, duration or 0, modRate or 1) end
end

-- Set or hide the small BOTTOMRIGHT stack count badge on an icon
function JR:SetBadge(key, count)
    local btn = JR.iconFrames[key]
    if not btn then return end
    if count and count > 0 then
        btn._badge:SetText(tostring(count))
        btn._badge:Show()
    else
        btn._badge:Hide()
    end
end

-- Show or hide the full-icon color overlay.
-- Pass r,g,b,a to tint; pass a=0 to hide.
function JR:SetIconOverlay(key, r, g, b, a)
    local btn = JR.iconFrames[key]
    if not btn then return end
    if not a or a <= 0 then
        btn._overlay:Hide()
    else
        btn._overlay:SetColorTexture(r or 1, g or 0, b or 0, a)
        btn._overlay:Show()
    end
end

-- Update glow on an already-active icon without a full re-activate
function JR:UpdateGlow(key, glowType)
    local btn = JR.iconFrames[key]
    if not btn then return end
    ApplyGlow(btn, glowType)
end

-- Show a large centered stack count on an icon, colored r,g,b.
-- Pass count=0 or nil to hide.
function JR:SetBigCount(key, count, r, g, b)
    local btn = JR.iconFrames[key]
    if not btn then return end
    if count and count > 0 then
        btn._bigCount:SetText(tostring(count))
        btn._bigCount:SetTextColor(r or 1, g or 1, b or 1)
        btn._bigCount:Show()
    else
        btn._bigCount:Hide()
    end
end

-- Expose TryPlaySound for alerts that manage their own sound timing
-- (e.g. always-visible trackers that fire on a state transition)
function JR:PlayAlertSound(key)
    TryPlaySound(key)
end

-- Aura-based alert: isActive=true shows, false hides
function JR:HandleAuraChange(key, isActive, auraData)
    if isActive then ActivateAlert(key, auraData) else DeactivateAlert(key) end
end

-- Cooldown-based alert: isReady=true shows the icon (spell off CD)
function JR:HandleCooldownChange(key, isReady, startTime, duration, modRate)
    JR:SetCooldownSweep(key, startTime, duration, modRate)
    if isReady then ActivateAlert(key, nil) else DeactivateAlert(key) end
end

-- ============================================================
-- REGISTER ALERT DEF  (class files call this at load time)
-- Frame construction is deferred until ADDON_LOADED so DB is available.
-- ============================================================
function JR:RegisterAlert(def)
    JR.alerts[def.key] = { def = def, active = false }
    if JouicyRemindersDB then
        -- DB already ready (e.g. after /reload): build now
        BuildIconFrame(def)
        BuildTextFrame(def)
    else
        JR._pendingAlerts[#JR._pendingAlerts + 1] = def
    end
end

-- Register a spec: { classFilename, specID, alertKeys }
-- classFilename = UnitClassBase result: "DRUID", "PRIEST", "SHAMAN", etc.
function JR:RegisterClassSpec(spec)
    local k = spec.classFilename .. "_" .. spec.specID
    JR.classDefs[k] = spec
end

-- ============================================================
-- SPEC DETECTION
-- UnitClassBase("player") is locale-independent. Returns "DRUID" etc.
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
    for key in pairs(JR.alerts) do DeactivateAlert(key) end
    local spec = JR.classDefs[GetSpecKey() or ""]
    if not spec then return end
    for _, key in ipairs(spec.alertKeys) do
        local s = JR.alerts[key]
        if s and s.def.onSpecActivated then s.def.onSpecActivated() end
    end
    UpdateAllKeybinds()
end

-- ============================================================
-- LAYOUT REFRESH  (called after config changes)
-- ============================================================
function JR:RefreshLayout()
    for _, cat in ipairs(ICON_CATEGORIES) do
        local size = AnchorCfg(cat).iconSize or 48
        for key, state in pairs(JR.alerts) do
            if state.def.category == cat and JR.iconFrames[key] then
                JR.iconFrames[key]:SetSize(size, size)
            end
        end
    end
    UpdateAnchors()
    ApplyLockState()
    LayoutIcons()
    LayoutTexts()
    UpdateAllKeybinds()
end

-- ============================================================
-- DB INIT  (deep-copy defaults on first load / new keys)
-- ============================================================
local function InitDB()
    JouicyRemindersDB = JouicyRemindersDB or {}
    local db = JouicyRemindersDB
    db.anchors = db.anchors or {}
    db.alerts  = db.alerts  or {}

    for cat, defaults in pairs(ANCHOR_DEFAULTS) do
        db.anchors[cat] = db.anchors[cat] or {}
        for k, v in pairs(defaults) do
            if db.anchors[cat][k] == nil then
                db.anchors[cat][k] = v
            end
        end
    end
end

-- ============================================================
-- MAIN EVENT FRAME
-- ============================================================
local ef = CreateFrame("Frame")
ef:RegisterEvent("ADDON_LOADED")
ef:RegisterEvent("PLAYER_ENTERING_WORLD")
ef:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ef:RegisterEvent("PLAYER_TALENT_UPDATE")   -- fires when talents are committed
ef:RegisterEvent("UNIT_AURA")
ef:RegisterEvent("SPELL_UPDATE_COOLDOWN")
ef:RegisterEvent("UPDATE_BINDINGS")          -- player changed keybindings
ef:RegisterEvent("ACTIONBAR_PAGE_CHANGED")   -- active bar page changed

ef:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= AddonName then return end

        InitDB()

        -- Build frames for all alerts registered before ADDON_LOADED
        for _, def in ipairs(JR._pendingAlerts) do
            BuildIconFrame(def)
            BuildTextFrame(def)
        end
        JR._pendingAlerts = {}

        UpdateAnchors()
        ApplyLockState()
        JR:BuildSettingsPanel()
        -- Keybinds are read after PLAYER_ENTERING_WORLD when action bars are live,
        -- so UpdateAllKeybinds() is called there via OnSpecActivated → RefreshLayout.
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_ENTERING_WORLD" then
        OnSpecActivated()

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        OnSpecActivated()

    elseif event == "PLAYER_TALENT_UPDATE" then
        -- Re-evaluate talent gates whenever the player commits a talent change.
        OnSpecActivated()

    elseif event == "UNIT_AURA" then
        local unit, updateInfo = ...
        if unit ~= "player" then return end
        local spec = JR.classDefs[GetSpecKey() or ""]
        if not spec then return end
        for _, key in ipairs(spec.alertKeys) do
            local s = JR.alerts[key]
            if s and s.def.onAuraUpdate then s.def.onAuraUpdate(updateInfo) end
        end

    elseif event == "SPELL_UPDATE_COOLDOWN" then
        local spec = JR.classDefs[GetSpecKey() or ""]
        if not spec then return end
        for _, key in ipairs(spec.alertKeys) do
            local s = JR.alerts[key]
            if s and s.def.onCooldownUpdate then s.def.onCooldownUpdate() end
        end

    elseif event == "UPDATE_BINDINGS" or event == "ACTIONBAR_PAGE_CHANGED" then
        UpdateAllKeybinds()
    end
end)

-- ============================================================
-- SLASH COMMANDS
--   /jr                → print usage
--   /jr lock           → toggle lock all anchors
--   /jr lock <cat>     → toggle lock for one anchor
--   /jr reset          → reset all anchor positions to defaults
--
-- Valid <cat> values: cooldown, upkeep, rotational, text
-- ============================================================
local VALID_CATS = { cooldown = true, upkeep = true, rotational = true, text = true }

SLASH_JOUICYREMINDERS1 = "/jr"
SLASH_JOUICYREMINDERS2 = "/jouicy"
SlashCmdList["JOUICYREMINDERS"] = function(msg)
    local cmd, arg = strtrim(msg):lower():match("^(%S*)%s*(.-)$")

    if cmd == "" or cmd == "config" or cmd == "options" then
        if JR._settingsCategory then
            Settings.OpenToCategory(JR._settingsCategory)
        else
            print("|cff88aaff[Jouicy Reminders]|r Settings not yet loaded. Try after logging in.")
        end

    elseif cmd == "help" then
        print("|cff88aaff[Jouicy Reminders]|r Commands:")
        print("  /jr (or /jr config)    — open settings panel")
        print("  /jr lock [cat]         — toggle lock (cooldown/upkeep/rotational/text)")
        print("  /jr reset              — reset all anchor positions")
        print("  /jr debug keybinds     — diagnose keybind detection per spell")
        print("  /jr debug slot         — dump all non-empty action bar slots")

    elseif cmd == "lock" or cmd == "unlock" then
        if arg ~= "" then
            -- Lock/unlock a single category
            if not VALID_CATS[arg] then
                print("|cff88aaff[Jouicy Reminders]|r Unknown category: " .. arg)
                print("  Valid: cooldown, upkeep, rotational, text")
                return
            end
            local cfg  = AnchorCfg(arg)
            cfg.locked = not cfg.locked
            ApplyLockStateForCategory(arg)
            local stateStr = cfg.locked and "|cffff4444locked|r" or "|cff44ff44unlocked|r"
            print("|cff88aaff[Jouicy Reminders]|r " .. arg .. " anchor " .. stateStr)
        else
            -- Toggle all anchors together (majority vote: lock if any is unlocked)
            local anyUnlocked = false
            for _, cat in ipairs(CATEGORIES) do
                if not AnchorCfg(cat).locked then anyUnlocked = true; break end
            end
            local newLocked = anyUnlocked
            for _, cat in ipairs(CATEGORIES) do
                AnchorCfg(cat).locked = newLocked
            end
            ApplyLockState()
            local stateStr = newLocked and "|cffff4444locked|r" or "|cff44ff44unlocked|r"
            print("|cff88aaff[Jouicy Reminders]|r All anchors " .. stateStr ..
                  (not newLocked and " — drag to reposition, /jr lock when done." or "."))
        end

    elseif cmd == "reset" then
        for cat, defaults in pairs(ANCHOR_DEFAULTS) do
            local cfg = AnchorCfg(cat)
            cfg.x = defaults.x
            cfg.y = defaults.y
        end
        UpdateAnchors()
        print("|cff88aaff[Jouicy Reminders]|r All anchor positions reset.")

    elseif cmd == "debug" then
        local sub = (arg ~= "" and arg or "keybinds")

        if sub == "keybinds" then
            -- ── /jr debug keybinds ──────────────────────────────────────────
            -- For every registered cooldown alert, show: spellID, the first
            -- matching bar slot found, how it matched (spell/macro), and
            -- the resolved keybind (or why it's missing).
            local P = "|cff88aaff[JR debug]|r "
            print(P .. "=== Keybind scan for registered cooldown alerts ===")
            local cfg = AnchorCfg("cooldown")
            print(P .. "showKeybinds = " .. tostring(cfg.showKeybinds))

            -- Helper: safe body fetch using whichever API exists.
            local function SafeGetBody(macroIdx)
                if _GetMacroBody then
                    local ok, b = pcall(_GetMacroBody, macroIdx)
                    if ok and b then return b end
                end
                if _GetMacroInfo then
                    local ok, _, _, b = pcall(_GetMacroInfo, macroIdx)
                    if ok and b then return b end
                end
                return nil
            end

            -- Inner helper: test a slot+cmd pair, return how-string or nil.
            local function DebugCheckSlot(slot, cmd, sid, scanIcon, spellName)
                if not slot or not cmd then return nil end
                local aType, aID, aSub = GetActionInfo(slot)
                if aType == "spell" and aID == sid then
                    return "direct spell"
                elseif aType == "macro" then
                    if aSub == "spell" and aID == sid then
                        return "macro subType=spell (id==spellID)"
                    end
                    -- For item-macros and any other subType: try name-based lookup.
                    local macroName = GetActionText and GetActionText(slot)
                    print(P .. "  [slot " .. slot .. " sub=" .. tostring(aSub) ..
                          " id=" .. tostring(aID) ..
                          " macroName=\"" .. tostring(macroName) .. "\"]")
                    if macroName and macroName ~= "" and _GetMacroSpell then
                        local ok, macroSID = pcall(_GetMacroSpell, macroName)
                        print(P .. "    GetMacroSpell(\"" .. macroName ..
                              "\") = " .. tostring(macroSID))
                        if ok and macroSID == sid then
                            return "macro via GetMacroSpell(name)"
                        end
                    end
                    -- Pre-TWW numeric-index body parse (no subType, numeric id).
                    if (not aSub) and aID and aID ~= 0 then
                        local body = SafeGetBody(aID)
                        if body and spellName then
                            local wl = spellName:lower()
                            for line in body:gmatch("[^\n]+") do
                                local ca = line:match("^%s*/cast%s+(.+)") or
                                           line:match("^%s*/use%s+(.+)")
                                if ca then
                                    local noC = ca:gsub("%b[]%s*", "")
                                    for part in noC:gmatch("[^;]+") do
                                        local t = part:match("^%s*(.-)%s*$")
                                        if t then
                                            if t:sub(1,1) == "!" then t = t:sub(2) end
                                            if t:lower() == wl then
                                                return "macro via body parse"
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    -- Last resort: icon texture.
                    if scanIcon then
                        local tex = GetActionTexture and GetActionTexture(slot)
                        print(P .. "    tex=" .. tostring(tex) ..
                              " wantIcon=" .. tostring(scanIcon))
                        if tex and tex == scanIcon then
                            return "macro via icon-texture fallback"
                        end
                    end
                end
                return nil
            end

            for key, state in pairs(JR.alerts or {}) do
                local def = state.def
                if def and def.category == "cooldown" and def.spellID then
                    local sid = def.spellID
                    local info = C_Spell.GetSpellInfo(sid)
                    local spellName = info and info.name
                    local scanIcon  = info and info.iconID
                    print(P .. "---- " .. tostring(spellName) ..
                          " (spellID " .. sid .. ") ----")

                    local foundSlot, foundHow, foundKey = nil, nil, nil

                    -- Mirror GetSpellKeybind: button frames first, then SLOT_RANGES.
                    local function TrySlot(slot, cmd)
                        if foundSlot then return end  -- already found
                        local how = DebugCheckSlot(slot, cmd, sid, scanIcon, spellName)
                        if how then
                            local rawKey = GetBindingKey(cmd)
                            local barNum = math.ceil(slot / 12)
                            local btnNum = (slot - 1) % 12 + 1
                            print(P .. "  Slot " .. slot ..
                                  " (Bar" .. barNum .. " btn " .. btnNum ..
                                  "): " .. how)
                            print(P .. "    bindCmd=" .. tostring(cmd) ..
                                  "  rawKey=" .. tostring(rawKey))
                            foundSlot = slot
                            foundHow  = how
                            foundKey  = rawKey
                        end
                    end

                    for _, prefix in ipairs(BLIZZARD_BAR_PREFIXES) do
                        for btn = 1, 12 do
                            local button = _G[prefix .. btn]
                            if button then
                                TrySlot(button.action, button.commandName)
                            end
                        end
                    end
                    if not foundSlot then
                        for slot = 1, 156 do
                            TrySlot(slot, SlotToBindingCmd(slot))
                        end
                    end

                    if not foundSlot then
                        print(P .. "  >> NOT FOUND on any action bar slot")
                    else
                        print(P .. "  >> Using slot " .. foundSlot ..
                              " key=" .. tostring(foundKey))
                    end
                end
            end
            print(P .. "=== End of scan ===")

        elseif sub == "slot" then
            -- ── /jr debug slot ──────────────────────────────────────────────
            -- Dump every non-empty slot in bars 1-156 with its action type,
            -- ID, texture, binding command, current keybind, and macro details.
            -- Slots where GetActionInfo returns nil but HasAction is true are
            -- also printed (TWW edge-case macros that can't be resolved).
            local P = "|cff88aaff[JR debug]|r "
            print(P .. "=== Action bar slot dump (non-empty slots 1-156) ===")
            for slot = 1, 156 do
                -- Capture subType (3rd return, added in TWW 10.2).
                local aType, aID, aSub = GetActionInfo(slot)
                local hasAct = HasAction and HasAction(slot)
                if aType or hasAct then
                    local cmd = SlotToBindingCmd(slot)
                    local key = cmd and GetBindingKey(cmd)
                    local tex = GetActionTexture and GetActionTexture(slot)
                    print(P .. "slot " .. slot ..
                          ": type=" .. tostring(aType) ..
                          " sub=" .. tostring(aSub) ..
                          " id=" .. tostring(aID) ..
                          " has=" .. tostring(hasAct) ..
                          " tex=" .. tostring(tex) ..
                          " bind=" .. tostring(cmd) ..
                          " key=" .. tostring(key))
                end
            end
            print(P .. "=== End slot dump ===")

        elseif sub == "funcs" then
            -- ── /jr debug funcs ─────────────────────────────────────────────
            -- Report which legacy macro/action API globals exist in this build.
            local P = "|cff88aaff[JR debug]|r "
            print(P .. "=== Legacy API availability ===")
            local funcs = {
                "GetActionInfo", "GetBindingKey",
                "GetMacroSpell", "GetMacroBody", "GetMacroInfo",
            }
            for _, fn in ipairs(funcs) do
                print(P .. fn .. " = " .. type(_G[fn]))
            end
            print(P .. "C_Macro.GetMacroName = " ..
                  type(C_Macro and C_Macro.GetMacroName))
            print(P .. "_GetMacroSpell (cached) = " .. type(_GetMacroSpell))
            print(P .. "_GetMacroBody  (cached) = " .. type(_GetMacroBody))
            print(P .. "_GetMacroInfo  (cached) = " .. type(_GetMacroInfo))
            print(P .. "=== End ===")

        elseif sub == "probe" then
            -- ── /jr debug probe ──────────────────────────────────────────────
            -- Two-part diagnostic to locate a missing macro slot:
            --   Part 1: Explicit dump of EVERY slot 1-40 (including empty ones)
            --           — shows what GetActionInfo + HasAction + GetActionTexture
            --             return for the range where bar 1-3 should live.
            --   Part 2: Full scan 1-156, printing only slots with HasAction=true
            --           but GetActionInfo returning nil (hidden macros).
            local P = "|cff88aaff[JR debug]|r "
            print(P .. "=== PROBE: explicit slots 1-40 ===")
            for slot = 1, 40 do
                local aType, aID, aSub = GetActionInfo(slot)
                local has  = HasAction and HasAction(slot)
                local tex  = GetActionTexture and GetActionTexture(slot)
                print(P .. " [" .. slot .. "] type=" .. tostring(aType) ..
                      " sub=" .. tostring(aSub) ..
                      " id=" .. tostring(aID) ..
                      " has=" .. tostring(has) ..
                      " tex=" .. tostring(tex))
            end
            print(P .. "=== PROBE: HasAction=true but GetActionInfo=nil (slots 1-156) ===")
            for slot = 1, 156 do
                local aType = GetActionInfo(slot)
                local has   = HasAction and HasAction(slot)
                if has and not aType then
                    local tex = GetActionTexture and GetActionTexture(slot)
                    local cmd = SlotToBindingCmd(slot)
                    local key = cmd and GetBindingKey(cmd)
                    print(P .. " [" .. slot .. "] has=true type=nil " ..
                          " tex=" .. tostring(tex) ..
                          " bind=" .. tostring(cmd) ..
                          " key=" .. tostring(key))
                end
            end
            print(P .. "=== End probe ===")

        else
            local P = "|cff88aaff[JR debug]|r "
            print(P .. "Debug sub-commands:")
            print("  /jr debug keybinds  — scan registered alerts for keybinds")
            print("  /jr debug slot      — dump all non-empty action bar slots")
            print("  /jr debug funcs     — check which legacy API functions exist")
            print("  /jr debug probe     — explicit slot-by-slot diagnosis (slots 1-40 + hidden macros)")
        end

    else
        print("|cff88aaff[Jouicy Reminders]|r Unknown command. Usage: /jr lock [cat] | /jr reset | /jr debug")
    end
end
