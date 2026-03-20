-- HealerAlerts_Config.lua
-- Settings UI registered via Settings.RegisterCanvasLayoutCategory (TWW/11.0+)
--
-- We avoid UIDropDownMenuTemplate which is deprecated in 11.0+ in favour of
-- simple radio-button groups for small fixed option sets.
--
-- The category object is stored in HA._settingsCategory so the slash command
-- can call Settings.OpenToCategory(HA._settingsCategory) correctly.

local AddonName, HA = ...

local PANEL_W = 580
local PANEL_H = 900   -- canvas must be this tall; scroll child can exceed it

-- ============================================================
-- WIDGET FACTORIES
-- ============================================================
local function Label(parent, text, x, y, template)
    local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontNormal")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    fs:SetText(text)
    return fs
end

local function HSep(parent, y)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetHeight(1)
    t:SetPoint("TOPLEFT",  parent, "TOPLEFT",   10, -y)
    t:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -10, -y)
    t:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    return t
end

-- Checkbox: returns the CheckButton, bottom y consumed = y+26
local function Checkbox(parent, text, x, y, getVal, setVal)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    cb.text:SetText(text)
    cb.text:SetFontObject("GameFontNormal")
    cb:SetChecked(getVal())
    cb:SetScript("OnClick", function(self) setVal(self:GetChecked() and true or false) end)
    return cb
end

-- Slider: returns frame, consumes ~60px height
local function Slider(parent, labelText, x, y, w, minV, maxV, step, getVal, setVal)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(w, 56)
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)

    local lbl = container:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    lbl:SetPoint("TOPLEFT")
    lbl:SetText(labelText)

    local sl = CreateFrame("Slider", nil, container, "OptionsSliderTemplate")
    sl:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -2)
    sl:SetWidth(w)
    sl:SetMinMaxValues(minV, maxV)
    sl:SetValueStep(step)
    sl:SetObeyStepOnDrag(true)
    sl:SetValue(getVal())
    sl.Low:SetText(tostring(minV))
    sl.High:SetText(tostring(maxV))

    local valDisp = container:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    valDisp:SetPoint("TOP", sl, "BOTTOM", 0, 2)
    valDisp:SetText(tostring(getVal()))

    sl:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v / step + 0.5) * step
        valDisp:SetText(tostring(v))
        setVal(v)
    end)
    return container
end

-- Radio group: a set of labelled buttons where exactly one is selected.
-- options = { {label, value}, ... }
-- Returns the container frame; consumes (18 * #options + 4) px height.
local function RadioGroup(parent, labelText, x, y, w, options, getVal, setVal)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(w, 18 * #options + 20)
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)

    local hdr = container:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    hdr:SetPoint("TOPLEFT")
    hdr:SetText(labelText)

    local btns = {}
    local function Refresh()
        local cur = getVal()
        for _, b in ipairs(btns) do
            b:SetChecked(b._val == cur)
        end
    end

    for i, opt in ipairs(options) do
        local btn = CreateFrame("CheckButton", nil, container, "UICheckButtonTemplate")
        btn:SetSize(18, 18)
        btn:SetPoint("TOPLEFT", container, "TOPLEFT", 4, -(16 + (i - 1) * 20))
        btn.text:SetText(opt.label)
        btn.text:SetFontObject("GameFontNormalSmall")
        btn._val = opt.value
        btn:SetScript("OnClick", function(self)
            setVal(self._val)
            Refresh()
        end)
        btns[i] = btn
    end

    Refresh()
    return container
end

-- EditBox with a label above it; consumes ~54px height.
local function EditBox(parent, labelText, x, y, w, getVal, setVal)
    local lbl = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    lbl:SetText(labelText)

    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -4)
    eb:SetSize(w, 22)
    eb:SetAutoFocus(false)
    eb:SetText(getVal() or "")

    local function Commit() setVal(eb:GetText()); eb:ClearFocus() end
    eb:SetScript("OnEnterPressed", Commit)
    eb:SetScript("OnEscapePressed", function(self)
        self:SetText(getVal() or "")
        self:ClearFocus()
    end)
    -- Also commit on losing focus so changes aren't lost
    eb:SetScript("OnEditFocusLost", Commit)

    return lbl, eb
end

-- ============================================================
-- PER-ALERT SECTION
-- Returns the new y offset after all widgets are placed.
-- ============================================================
local function BuildAlertSection(content, key, def, y)
    HSep(content, y); y = y + 10

    Label(content, def.name, 12, y, "GameFontNormalLarge"); y = y + 26

    -- Enabled toggle
    Checkbox(content, "Enable", 14, y,
        function()
            local c = HealerAlertsDB.alerts[key]
            return (not c) or (c.enabled ~= false)
        end,
        function(v)
            HealerAlertsDB.alerts[key] = HealerAlertsDB.alerts[key] or {}
            HealerAlertsDB.alerts[key].enabled = v
        end)
    y = y + 26

    -- Glow type radio group
    local glowOpts = {
        { label = "Action bar glow (Blizzard proc style)", value = "action" },
        { label = "Marching ants (animated border)",       value = "ants"   },
        { label = "None",                                  value = "none"   },
    }
    RadioGroup(content, "Glow effect:", 14, y, 340, glowOpts,
        function()
            local c = HealerAlertsDB.alerts[key]
            return (c and c.glowType) or def.defaultGlow or "none"
        end,
        function(v)
            HealerAlertsDB.alerts[key] = HealerAlertsDB.alerts[key] or {}
            HealerAlertsDB.alerts[key].glowType = v
        end)
    y = y + (#glowOpts * 20) + 24

    -- Alert text
    EditBox(content, "Alert text  (empty = no text):", 14, y, 320,
        function()
            local c = HealerAlertsDB.alerts[key]
            if c and c.text ~= nil then return c.text end
            return def.defaultText or ""
        end,
        function(v)
            HealerAlertsDB.alerts[key] = HealerAlertsDB.alerts[key] or {}
            HealerAlertsDB.alerts[key].text = v
        end)
    y = y + 50

    -- Sound file
    EditBox(content, "Sound file  (relative to HealerAlerts/Sounds/, e.g. ready.ogg):", 14, y, 340,
        function()
            local c = HealerAlertsDB.alerts[key]
            return (c and c.sound) or ""
        end,
        function(v)
            HealerAlertsDB.alerts[key] = HealerAlertsDB.alerts[key] or {}
            HealerAlertsDB.alerts[key].sound = v
        end)
    y = y + 54

    return y
end

-- ============================================================
-- BUILD THE CANVAS FRAME
-- ============================================================
local function BuildCanvas()
    -- Outer frame handed to Blizzard Settings system
    local outer = CreateFrame("Frame")
    outer:SetSize(PANEL_W, PANEL_H)

    -- Scrollable inner content
    local scroll = CreateFrame("ScrollFrame", nil, outer, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     outer, "TOPLEFT",      4,   -4)
    scroll:SetPoint("BOTTOMRIGHT", outer, "BOTTOMRIGHT", -26,   4)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(PANEL_W - 36)
    content:SetHeight(1)   -- will be expanded below
    scroll:SetScrollChild(content)

    local y = 10

    -- Title
    Label(content, "HealerAlerts  —  Settings", 12, y, "GameFontNormalLarge")
    y = y + 8

    local sub = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    sub:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -(y + 18))
    sub:SetText("/ha lock  to toggle draggable anchors  |  /ha reset  to restore positions")
    sub:SetTextColor(0.7, 0.7, 0.7)
    y = y + 42

    -- ── ICON BAR ─────────────────────────────────────────────
    HSep(content, y); y = y + 10
    Label(content, "Icon Bar", 12, y, "GameFontNormalLarge"); y = y + 28

    Slider(content, "Icon size (px):", 14, y, 220,
        24, 96, 4,
        function() return HealerAlertsDB.iconSize end,
        function(v) HealerAlertsDB.iconSize = v; HA:RefreshLayout() end)
    y = y + 62

    local dirOpts = {
        { label = "Grow right  →",  value = "RIGHT" },
        { label = "Grow left   ←",  value = "LEFT"  },
        { label = "Grow up     ↑",  value = "UP"    },
        { label = "Grow down   ↓",  value = "DOWN"  },
    }
    RadioGroup(content, "Icon bar direction:", 14, y, 240, dirOpts,
        function() return HealerAlertsDB.growDirection or "RIGHT" end,
        function(v) HealerAlertsDB.growDirection = v; HA:RefreshLayout() end)
    y = y + (#dirOpts * 20) + 30

    -- ── FRAME LOCK ───────────────────────────────────────────
    HSep(content, y); y = y + 10
    Label(content, "Frame Positions", 12, y, "GameFontNormalLarge"); y = y + 28

    local noteFs = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    noteFs:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -y)
    noteFs:SetText("Unlock to drag the icon bar and text area. Lock again to save position.")
    noteFs:SetTextColor(0.75, 0.75, 0.75)
    y = y + 20

    Checkbox(content, "Lock icon bar",   14, y,
        function() return HealerAlertsDB.iconLocked end,
        function(v) HealerAlertsDB.iconLocked = v; HA.ApplyLockState() end)
    y = y + 26

    Checkbox(content, "Lock text alerts", 14, y,
        function() return HealerAlertsDB.textLocked end,
        function(v) HealerAlertsDB.textLocked = v; HA.ApplyLockState() end)
    y = y + 34

    -- Reset button
    local resetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    resetBtn:SetSize(160, 24)
    resetBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -y)
    resetBtn:SetText("Reset Positions")
    resetBtn:SetScript("OnClick", function()
        HealerAlertsDB.iconAnchorX = 400
        HealerAlertsDB.iconAnchorY = 300
        HealerAlertsDB.textAnchorX = 400
        HealerAlertsDB.textAnchorY = 260
        HA:RefreshLayout()
    end)
    y = y + 36

    -- ── PER-ALERT SECTIONS ───────────────────────────────────
    HSep(content, y); y = y + 10
    Label(content, "Per-Alert Settings", 12, y, "GameFontNormalLarge"); y = y + 28

    local hintFs = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    hintFs:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -y)
    hintFs:SetText("Place sound files (.ogg or .mp3) in  HealerAlerts/Sounds/  and enter the filename below.")
    hintFs:SetTextColor(0.7, 0.7, 0.7)
    y = y + 24

    -- Sort alerts by their order field for consistent display
    local sorted = {}
    for key, state in pairs(HA.alerts) do
        sorted[#sorted + 1] = { key = key, def = state.def }
    end
    table.sort(sorted, function(a, b)
        return (a.def.order or 99) < (b.def.order or 99)
    end)

    for _, entry in ipairs(sorted) do
        y = BuildAlertSection(content, entry.key, entry.def, y)
        y = y + 6
    end

    -- Expand content to fit everything
    content:SetHeight(y + 30)

    return outer
end

-- ============================================================
-- REGISTER WITH BLIZZARD SETTINGS
-- Must happen after PLAYER_LOGIN so HA.alerts is fully populated
-- by all class files.
-- ============================================================
local regFrame = CreateFrame("Frame")
regFrame:RegisterEvent("PLAYER_LOGIN")
regFrame:SetScript("OnEvent", function(self, event)
    if event ~= "PLAYER_LOGIN" then return end

    local canvas   = BuildCanvas()
    local category = Settings.RegisterCanvasLayoutCategory(canvas, "HealerAlerts")
    Settings.RegisterAddOnCategory(category)

    -- Store reference for slash command
    HA._settingsCategory = category

    self:UnregisterEvent("PLAYER_LOGIN")
end)
