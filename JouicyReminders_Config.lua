-- JouicyReminders_Config.lua
-- Blizzard Settings panel (ESC → Options → AddOns → Jouicy Reminders)
-- and standalone access via /jr config
--
-- API used:
--   Settings.RegisterCanvasLayoutCategory(panel, name) → category
--   Settings.RegisterAddOnCategory(category)
--   Settings.OpenToCategory(category)
--   CreateFrame / UIPanelScrollFrameTemplate / UIPanelButtonTemplate
--   UICheckButtonTemplate / OptionsSliderTemplate / InputBoxTemplate

local AddonName, JR = ...

-- ============================================================
-- CONSTANTS
-- ============================================================
local PANEL_W   = 580
local COL_L     = 16    -- left margin inside scroll child
local COL_VAL   = 200   -- x-offset where value controls start
local ROW_H     = 26    -- standard row height
local SEC_GAP   = 14    -- extra gap before a new section

local ANCHOR_DEFAULTS_POS = {
    cooldown   = { x = 400, y = 300 },
    upkeep     = { x = 400, y = 240 },
    rotational = { x = 600, y = 300 },
    text       = { x = 400, y = 180 },
}

local CAT_LABELS = {
    cooldown   = "|cff4488ffCooldowns|r  (blue anchor)",
    upkeep     = "|cff44cc44Upkeep|r  (green anchor)",
    rotational = "|cffff8833Rotational|r  (orange anchor)",
    text       = "|cffaa44ffText Alerts|r  (purple anchor)",
}

local DIR_LIST   = { "RIGHT", "LEFT", "UP", "DOWN" }
local DIR_LABELS = { "Right →", "← Left", "↑ Up", "↓ Down" }

local GLOW_LIST   = { "action", "ants", "none" }
local GLOW_LABELS = { "Blizzard Glow", "Marching Ants", "None" }

-- ============================================================
-- DB HELPERS
-- ============================================================
local function DB()      return JouicyRemindersDB         end
local function ACfg(cat) return DB().anchors[cat]          end
local function ALCfg(key)
    DB().alerts[key] = DB().alerts[key] or {}
    return DB().alerts[key]
end

-- ============================================================
-- WIDGET FACTORY HELPERS
-- All return the new y cursor position after the widget.
-- ============================================================

-- Section header (gold, large)
local function Header(sc, y, text)
    local fs = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", sc, "TOPLEFT", COL_L, -y)
    fs:SetText(text)
    fs:SetTextColor(1, 0.82, 0)
    return y + 28
end

-- Thin horizontal rule
local function Divider(sc, y)
    local t = sc:CreateTexture(nil, "ARTWORK")
    t:SetPoint("TOPLEFT",  sc, "TOPLEFT",  COL_L,           -y)
    t:SetPoint("TOPRIGHT", sc, "TOPLEFT",  PANEL_W - COL_L, -y)
    t:SetHeight(1)
    t:SetColorTexture(0.4, 0.4, 0.4, 0.5)
    return y + 8
end

-- Plain label; returns the FontString (no y advance)
local function Label(sc, y, text, x, color)
    local fs = sc:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", sc, "TOPLEFT", x or COL_L, -y)
    fs:SetText(text)
    if color then fs:SetTextColor(unpack(color)) end
    return fs
end

-- Checkbox + inline label
local function Checkbox(sc, y, text, getV, setV)
    local cb = CreateFrame("CheckButton", nil, sc, "UICheckButtonTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint("TOPLEFT", sc, "TOPLEFT", COL_L, -(y + 2))
    cb:SetChecked(getV())
    cb:SetScript("OnClick", function(self)
        setV(self:GetChecked() == true or self:GetChecked() == 1)
        JR:RefreshLayout()
    end)
    local lbl = sc:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("LEFT", cb, "RIGHT", 3, 0)
    lbl:SetText(text)
    return y + ROW_H
end

-- Slider with label; uses a unique name so OptionsSliderTemplate children resolve
local _slN = 0
local function Slider(sc, y, text, minV, maxV, step, getV, setV)
    _slN = _slN + 1
    local nm = "JRSlider" .. _slN

    Label(sc, y + 6, text)

    local sl = CreateFrame("Slider", nm, sc, "OptionsSliderTemplate")
    sl:SetPoint("TOPLEFT", sc, "TOPLEFT", COL_VAL, -(y))
    sl:SetWidth(200)
    sl:SetMinMaxValues(minV, maxV)
    sl:SetValueStep(step)
    sl:SetObeyStepOnDrag(true)
    sl:SetValue(getV())
    _G[nm .. "Low"]:SetText(tostring(minV))
    _G[nm .. "High"]:SetText(tostring(maxV))
    _G[nm .. "Text"]:SetText(tostring(math.floor(getV())))

    sl:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val / step + 0.5) * step
        _G[nm .. "Text"]:SetText(tostring(val))
        setV(val)
        JR:RefreshLayout()
    end)
    return y + 36
end

-- Cycling button (stands in for a dropdown; avoids UIDropDownMenu taint)
local function Cycle(sc, y, text, list, labelList, getV, setV)
    Label(sc, y + 4, text)

    local btn = CreateFrame("Button", nil, sc, "UIPanelButtonTemplate")
    btn:SetSize(140, 22)
    btn:SetPoint("TOPLEFT", sc, "TOPLEFT", COL_VAL, -(y + 1))

    local function Refresh()
        local cur = getV()
        for i, v in ipairs(list) do
            if v == cur then btn:SetText(labelList[i]); return end
        end
        btn:SetText(cur or list[1])
    end
    Refresh()

    btn:SetScript("OnClick", function()
        local cur = getV()
        local nxt = list[1]
        for i, v in ipairs(list) do
            if v == cur then nxt = list[(i % #list) + 1]; break end
        end
        setV(nxt)
        Refresh()
        JR:RefreshLayout()
    end)
    return y + ROW_H
end

-- Single-line edit box
local function EditBox(sc, y, text, width, getV, setV)
    Label(sc, y + 4, text)

    local eb = CreateFrame("EditBox", nil, sc, "InputBoxTemplate")
    eb:SetSize(width or 200, 20)
    eb:SetPoint("TOPLEFT", sc, "TOPLEFT", COL_VAL, -(y + 2))
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(128)
    eb:SetText(getV() or "")
    eb:SetScript("OnEnterPressed", function(self)
        local v = strtrim(self:GetText())
        setV(v ~= "" and v or nil)
        self:ClearFocus()
    end)
    eb:SetScript("OnEscapePressed", function(self)
        self:SetText(getV() or "")
        self:ClearFocus()
    end)
    return y + ROW_H
end

-- Small push-button
local function Button(sc, y, text, onClick)
    local btn = CreateFrame("Button", nil, sc, "UIPanelButtonTemplate")
    btn:SetSize(130, 22)
    btn:SetPoint("TOPLEFT", sc, "TOPLEFT", COL_L, -(y))
    btn:SetText(text)
    btn:SetScript("OnClick", onClick)
    return y + 30
end

-- ============================================================
-- PANEL CONTENT BUILDER
-- Populates scrollChild and returns the final content height.
-- ============================================================
local function BuildContent(sc)
    local y = 10

    -- =========================================================
    -- SECTION: ANCHOR SETTINGS
    -- =========================================================
    y = Header(sc, y, "Anchor Settings")
    y = Divider(sc, y)

    for _, cat in ipairs({ "cooldown", "upkeep", "rotational", "text" }) do
        y = y + 4
        Label(sc, y, CAT_LABELS[cat], COL_L, { 1, 1, 1 })
        y = y + 22

        y = Checkbox(sc, y, "Hide this module",
            function() return ACfg(cat).hidden == true end,
            function(v) ACfg(cat).hidden = v end)

        if cat ~= "text" then
            y = Slider(sc, y, "Icon size",
                24, 72, 2,
                function() return ACfg(cat).iconSize or 48 end,
                function(v) ACfg(cat).iconSize = v end)

            y = Cycle(sc, y, "Grow direction",
                DIR_LIST, DIR_LABELS,
                function() return ACfg(cat).growDirection or "RIGHT" end,
                function(v) ACfg(cat).growDirection = v end)

            if cat == "cooldown" then
                y = Checkbox(sc, y, "Show keybind on icon",
                    function() return ACfg("cooldown").showKeybinds == true end,
                    function(v)
                        ACfg("cooldown").showKeybinds = v
                        JR.UpdateAllKeybinds()
                    end)

                y = Slider(sc, y, "Keybind font size",
                    8, 20, 1,
                    function() return ACfg("cooldown").keybindFontSize or 12 end,
                    function(v)
                        ACfg("cooldown").keybindFontSize = v
                        JR.UpdateAllKeybinds()
                    end)
            end
        end

        y = Button(sc, y, "Reset Position", function()
            local def = ANCHOR_DEFAULTS_POS[cat]
            ACfg(cat).x = def.x
            ACfg(cat).y = def.y
            JR:RefreshLayout()
            print("|cff88aaff[Jouicy Reminders]|r " .. cat .. " anchor position reset.")
        end)

        y = Divider(sc, y)
    end

    y = y + SEC_GAP

    -- =========================================================
    -- SECTION: ALERT SETTINGS
    -- =========================================================
    y = Header(sc, y, "Alert Settings")

    local hint = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", sc, "TOPLEFT", COL_L, -y)
    hint:SetText("Leave Text override and Sound fields empty to use defaults.")
    hint:SetTextColor(0.6, 0.6, 0.6)
    y = y + 18

    y = Divider(sc, y)

    -- Sort alerts by order, then name
    local alertList = {}
    for key, state in pairs(JR.alerts) do
        alertList[#alertList + 1] = {
            key   = key,
            order = state.def.order or 99,
            name  = state.def.name  or key,
            def   = state.def,
        }
    end
    table.sort(alertList, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.name < b.name
    end)

    for _, entry in ipairs(alertList) do
        local key = entry.key
        local def = entry.def

        y = y + 4

        -- Alert name + category badge
        local catColor = { cooldown={0.4,0.6,1}, upkeep={0.3,0.9,0.3},
                           rotational={1,0.6,0.2}, text={0.8,0.4,1} }
        local cc = catColor[def.category or "cooldown"] or { 1, 1, 1 }
        local badge = "[" .. (def.category or "?") .. "]"
        Label(sc, y, def.name or key, COL_L, { 1, 0.85, 0.3 })
        Label(sc, y, badge, COL_L + 220, cc)
        y = y + 20

        y = Checkbox(sc, y, "Enabled",
            function() return ALCfg(key).enabled ~= false end,
            function(v) ALCfg(key).enabled = v end)

        y = EditBox(sc, y, "Text override", 220,
            function() return ALCfg(key).text end,
            function(v) ALCfg(key).text = v end)

        y = EditBox(sc, y, "Sound file", 220,
            function() return ALCfg(key).sound end,
            function(v) ALCfg(key).sound = v end)

        y = Cycle(sc, y, "Glow",
            GLOW_LIST, GLOW_LABELS,
            function() return ALCfg(key).glowType or def.defaultGlow or "none" end,
            function(v) ALCfg(key).glowType = v end)

        y = y + 4
        y = Divider(sc, y)
    end

    return y + 20
end

-- ============================================================
-- PUBLIC: BUILD & REGISTER
-- Called by JouicyReminders.lua after ADDON_LOADED so that
-- JR.alerts is already populated by class module RegisterAlert calls.
-- ============================================================
function JR:BuildSettingsPanel()
    -- Canvas panel Blizzard will render in the Settings window
    local panel = CreateFrame("Frame")
    panel.name  = "Jouicy Reminders"

    -- Scroll frame fills the panel
    local sf = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     panel, "TOPLEFT",     4,   -4)
    sf:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28,  4)

    -- Scroll child — width is fixed, height is determined by content
    local sc = CreateFrame("Frame", nil, sf)
    sc:SetWidth(PANEL_W)
    sc:SetHeight(400)   -- will be updated below
    sf:SetScrollChild(sc)

    -- Populate content once alerts are registered; defer if called too early
    local function Populate()
        -- Clear any prior children (in case of re-open after /reload)
        for _, child in ipairs({ sc:GetChildren() }) do child:Hide() end
        for _, r in ipairs({ sc:GetRegions() }) do r:Hide() end

        local h = BuildContent(sc)
        sc:SetHeight(h)
    end
    Populate()

    -- Rebuild content on show so late-registered alerts are included
    panel:SetScript("OnShow", Populate)

    -- Register with Blizzard ESC → Options → AddOns
    local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)
    JR._settingsCategory = category
end
