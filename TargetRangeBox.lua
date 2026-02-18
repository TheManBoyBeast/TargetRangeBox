-- TargetRangeBox - MOP Classic + TBC Anniversary 2.5.5
-- Per-character: TargetRangeBoxDB | Global profiles: TargetRangeBoxProfilesDB
-- /trb opens Options > AddOns > TargetRangeBox
-- /trb lock | /trb unlock | /trb show | /trb hide | /trb show nt | /trb hide nt
--
-- FIX 4: Handle ADDON_ACTION_BLOCKED reports that show protected function as "UNKNOWN()"
-- Some Classic/TBC clients report CheckInteractDistance blocks as UNKNOWN() when wrapped.
-- This build:
--   - still prefers securecallfunction(CheckInteractDistance,...)
--   - if a block event fires while we are attempting an interact check, we disable ONLY the interact fallback
--     until leaving combat (prevents repeated spam) even if func name is UNKNOWN()
--
-- NEW: Options toggle to disable all Close-Range Proxies (AoE/Cone proxy system + rogue remote 10y + interact fallback).
-- Adds: "Enable Close-Range Proxies" checkbox with helper note:
--   "(Recommended OFF for classes without close-range)"
-- Default stays ON unless user turns it OFF.

local ADDON_NAME = ...

-- ============================================================
-- Defaults (applied on fresh install / first run only)
-- ============================================================

local GOLD_YELLOW = {1, 0.7843137255, 0.1960784314, 1} -- #ffc832
local WHITE = {1, 1, 1, 1}                             -- #ffffff

local defaults = {
    show = true,
    showNoTarget = true,
    lock = false,

    size = 40,
    updateFrequency = 0.05,
    alpha = 1.0,

    background = "Interface/Buttons/WHITE8X8",

    noTargetColor = {0, 0, 0, 0},
    outOfRangeColor = {1, 0, 0, 1},

    rangeProxies = { [10] = "", [12] = "" },

    proxyColors = {
        [10] = {WHITE[1], WHITE[2], WHITE[3], WHITE[4]},
        [12] = {GOLD_YELLOW[1], GOLD_YELLOW[2], GOLD_YELLOW[3], GOLD_YELLOW[4]},
    },

    remoteProxy = { enabled = true, maxAge = 0.75 },

    -- NEW: master toggle for close-range proxy system (AoE/Cone proxy + remote 10y + interact fallback)
    closeRangeProxy = { enabled = true },

    spells = {
        { name = "", color = {0, 1, 0, 1} },
        { name = "", color = {1, 0.5, 0, 1} },
        { name = "", color = {1, 1, 0, 1} },
        { name = "", color = {0, 1, 1, 1} },
        { name = "", color = {1, 0, 1, 1} },
        { name = "", color = {0.6, 0.6, 1, 1} },
        { name = "", color = {1, 0.2, 0.2, 1} },
        { name = "", color = {0.2, 1, 0.2, 1} },
        { name = "", color = {GOLD_YELLOW[1], GOLD_YELLOW[2], GOLD_YELLOW[3], GOLD_YELLOW[4]} },
        { name = "", color = {WHITE[1], WHITE[2], WHITE[3], WHITE[4]} },
    },

    point = {"CENTER", "UIParent", "CENTER", 0, 0},
}

-- ============================================================
-- Fast locals
-- ============================================================

local UnitExists, UnitIsDead, UnitIsVisible = UnitExists, UnitIsDead, UnitIsVisible
local UnitGUID, UnitClass = UnitGUID, UnitClass
local IsSpellInRange, IsItemInRange = IsSpellInRange, IsItemInRange
local CheckInteractDistance, GetTime = CheckInteractDistance, GetTime
local IsInGroup, IsInRaid = IsInGroup, IsInRaid
local wipe, type, tostring, pairs, unpack = wipe, type, tostring, pairs, unpack
local math_floor = math.floor
local DEFAULT_CHAT_FRAME = DEFAULT_CHAT_FRAME
local securecallfunction = securecallfunction

local C_ChatInfo = C_ChatInfo
local RegisterAddonMessagePrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
local SendAddonMessageFunc = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage

-- ============================================================
-- Small utilities
-- ============================================================

local function CopyDefaults(src, dst)
    if type(dst) ~= "table" then dst = {} end
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = DeepCopy(val) end
    return out
end

local function SortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys+1] = k end
    table.sort(keys, function(a,b) return tostring(a):lower() < tostring(b):lower() end)
    return keys
end

local function EnsureProfilesDB()
    if type(TargetRangeBoxProfilesDB) ~= "table" then TargetRangeBoxProfilesDB = {} end
    if type(TargetRangeBoxProfilesDB.profiles) ~= "table" then TargetRangeBoxProfilesDB.profiles = {} end
end

local function CleanName(name)
    return tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function PrintMsg(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00TargetRangeBox:|r " .. tostring(msg))
    end
end

local function PrintRaw(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(tostring(msg))
    end
end

-- NEW: master toggle helper
local function CloseRangeProxyEnabled()
    return TargetRangeBoxDB
        and TargetRangeBoxDB.closeRangeProxy
        and TargetRangeBoxDB.closeRangeProxy.enabled == true
end

-- ============================================================
-- Main Frame (Box)
-- ============================================================

local Box = CreateFrame("Frame", "TargetRangeBoxFrame", UIParent, "BackdropTemplate")
Box:SetFrameStrata("BACKGROUND")
Box:SetMovable(true)
Box:RegisterForDrag("LeftButton")
Box:Hide()

local function ApplyBackdrop()
    Box:SetBackdrop({
        bgFile = TargetRangeBoxDB.background,
        edgeFile = nil,
        tile = true,
        tileSize = 8,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
end

local function Redraw()
    Box:SetSize(TargetRangeBoxDB.size, TargetRangeBoxDB.size)
    ApplyBackdrop()
end

local function UpdateClickThrough()
    Box:EnableMouse(not TargetRangeBoxDB.lock)
end

local lastR, lastG, lastB, lastA
local function SetColorRGBA(r, g, b, a)
    local alphaMult = (TargetRangeBoxDB.alpha or 1)
    local finalA = (a or 1) * alphaMult
    if lastR == r and lastG == g and lastB == b and lastA == finalA then return end
    lastR, lastG, lastB, lastA = r, g, b, finalA
    Box:SetBackdropColor(r, g, b, finalA)
end

local function SetColorTable(c)
    SetColorRGBA(c[1], c[2], c[3], c[4])
end

Box:SetScript("OnDragStart", function(self)
    if TargetRangeBoxDB and not TargetRangeBoxDB.lock then
        self:StartMoving()
    end
end)

Box:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if not TargetRangeBoxDB then return end
    local p, _, rp, x, y = self:GetPoint()
    TargetRangeBoxDB.point = {p, "UIParent", rp, x, y}
end)

-- ============================================================
-- Remote proxy (Rogue Sap 10y broadcast + cache)
-- ============================================================

local TRB_PREFIX = "TRB1"
local remote10Cache = {}

local function Remote10Enabled()
    return CloseRangeProxyEnabled()
        and TargetRangeBoxDB
        and TargetRangeBoxDB.remoteProxy
        and TargetRangeBoxDB.remoteProxy.enabled == true
end

local function Remote10MaxAge()
    local rp = TargetRangeBoxDB and TargetRangeBoxDB.remoteProxy
    if rp and type(rp.maxAge) == "number" then return rp.maxAge end
    return 0.75
end

local function GetRemote10ForGUID(guid)
    if not Remote10Enabled() or not guid or guid == "" then return nil end
    local entry = remote10Cache[guid]
    if not entry then return nil end
    if (GetTime() - (entry.t or 0)) > Remote10MaxAge() then return nil end
    return entry.inRange
end

local function InGroupChannel()
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    return nil
end

local isRogue do
    local _, class = UnitClass("player")
    isRogue = (class == "ROGUE")
end

local lastSapGUID, lastSapVal, lastSapSendT = nil, nil, 0
local function BroadcastSapIfNeeded()
    if not isRogue or not Remote10Enabled() then return end

    local chan = InGroupChannel()
    if not chan or not SendAddonMessageFunc then return end

    if not UnitExists("target") or UnitIsDead("target") or not UnitIsVisible("target") then
        lastSapGUID, lastSapVal = nil, nil
        return
    end

    local guid = UnitGUID("target")
    if not guid then return end

    local r = IsSpellInRange("Sap", "target")
    if r ~= 1 and r ~= 0 then return end
    local val = (r == 1) and 1 or 0

    local now = GetTime()
    if guid == lastSapGUID and val == lastSapVal and (now - lastSapSendT) < 0.5 then return end
    lastSapGUID, lastSapVal, lastSapSendT = guid, val, now

    SendAddonMessageFunc(TRB_PREFIX, "S10|" .. guid .. "|" .. tostring(val), chan)
end

local commFrame = CreateFrame("Frame")
commFrame:RegisterEvent("CHAT_MSG_ADDON")
commFrame:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
    if prefix ~= TRB_PREFIX or type(message) ~= "string" then return end
    local tag, guid, v = message:match("^(S10)|([^|]+)|([01])$")
    if tag ~= "S10" or not guid then return end

    remote10Cache[guid] = {
        inRange = (v == "1"),
        t = GetTime(),
        sender = sender,
    }
end)

-- ============================================================
-- AoE/Cone support (Proxy + Remote + Interact fallback)
-- ============================================================

local CUSTOM_SPELLS = {
    ["Arcane Explosion"] = { yards = 10 },
    ["Dragon's Breath"]  = { yards = 12 },
}

local function IsItemInRangeBool(itemName)
    local r = IsItemInRange(itemName, "target")
    if r == 1 or r == true then return true end
    if r == 0 or r == false then return false end
    return nil
end

local function ProxyInRange(yards)
    local rp = TargetRangeBoxDB and TargetRangeBoxDB.rangeProxies
    if not rp then return nil end

    local proxyName = CleanName(rp[yards])
    if proxyName == "" then return nil end

    local sr = IsSpellInRange(proxyName, "target")
    if sr == 1 then return true end
    if sr == 0 then return false end

    return IsItemInRangeBool(proxyName)
end

-- ============================================================
-- Interact fallback with robust block detection
-- ============================================================

local interactTemporarilyDisabled = false
local warnedInteractDisabled = false
local interactCallInProgress = false
local interactBlockCooldownUntil = 0

local function DisableInteractUntilRegen()
    interactTemporarilyDisabled = true
    if not warnedInteractDisabled then
        warnedInteractDisabled = true
        PrintMsg("Interact-range fallback was blocked by the client; disabling it until you leave combat.")
    end
end

local function SafeCheckInteractDistance(unit, distIndex)
    if interactTemporarilyDisabled then return nil end
    if not CheckInteractDistance then return nil end

    -- small cooldown after a block to avoid immediate re-trigger spam
    local now = GetTime()
    if now < interactBlockCooldownUntil then return nil end

    interactCallInProgress = true

    -- Prefer securecallfunction when available
    if type(securecallfunction) == "function" then
        local ok, res = pcall(securecallfunction, CheckInteractDistance, unit, distIndex)
        interactCallInProgress = false
        if ok then
            return res and true or false
        else
            -- If securecallfunction path failed, back off briefly
            interactBlockCooldownUntil = now + 0.25
            return nil
        end
    end

    -- Fallback: raw pcall
    local ok, res = pcall(CheckInteractDistance, unit, distIndex)
    interactCallInProgress = false
    if not ok then
        interactBlockCooldownUntil = now + 0.25
        return nil
    end
    return res and true or false
end

local function InteractInRangeApprox(yards)
    if yards <= 10 then
        return SafeCheckInteractDistance("target", 3)
    else
        return SafeCheckInteractDistance("target", 2)
    end
end

-- Watch for blocks; handle UNKNOWN() by checking interactCallInProgress
local blockWatch = CreateFrame("Frame")
blockWatch:RegisterEvent("ADDON_ACTION_BLOCKED")
blockWatch:RegisterEvent("ADDON_ACTION_FORBIDDEN")
blockWatch:RegisterEvent("PLAYER_REGEN_ENABLED")
blockWatch:SetScript("OnEvent", function(_, event, addonName, funcName)
    if event == "PLAYER_REGEN_ENABLED" then
        interactTemporarilyDisabled = false
        warnedInteractDisabled = false
        interactCallInProgress = false
        interactBlockCooldownUntil = 0
        return
    end

    if addonName ~= "TargetRangeBox" and addonName ~= ADDON_NAME then return end

    -- Some clients report funcName as UNKNOWN() when wrapped; treat that as interact if we were calling it
    funcName = tostring(funcName or "")
    if funcName:find("CheckInteractDistance", 1, true) or funcName:find("UNKNOWN", 1, true) then
        if interactCallInProgress or funcName:find("CheckInteractDistance", 1, true) then
            DisableInteractUntilRegen()
        end
    end
end)

local function CustomSpellInRange(spellName)
    -- NEW: master toggle - when OFF, we skip all proxy/remote/interact logic entirely
    if not CloseRangeProxyEnabled() then return nil, nil end

    local spec = CUSTOM_SPELLS[spellName]
    if not spec then return nil, nil end

    local prox = ProxyInRange(spec.yards)
    if prox ~= nil then return prox, spec.yards end

    if spec.yards == 10 and Remote10Enabled() then
        local guid = UnitGUID("target")
        local remoteVal = guid and GetRemote10ForGUID(guid)
        if remoteVal ~= nil then return remoteVal, spec.yards end
    end

    return InteractInRangeApprox(spec.yards), spec.yards
end

-- ============================================================
-- Range Logic
-- ============================================================

local activeSlots = {}
local function RebuildActiveSlots()
    wipe(activeSlots)
    local sp = TargetRangeBoxDB and TargetRangeBoxDB.spells
    if not sp then return end
    for i = #sp, 1, -1 do
        local n = sp[i] and sp[i].name
        if n and n ~= "" then activeSlots[#activeSlots + 1] = i end
    end
end

local function UpdateRange()
    BroadcastSapIfNeeded()

    if not UnitExists("target") or UnitIsDead("target") or not UnitIsVisible("target") then
        local c = TargetRangeBoxDB.noTargetColor
        if TargetRangeBoxDB.showNoTarget then
            SetColorRGBA(c[1], c[2], c[3], 1)
        else
            SetColorTable(c)
        end
        return
    end

    for j = 1, #activeSlots do
        local i = activeSlots[j]
        local s = TargetRangeBoxDB.spells[i]
        local name = s and s.name
        if name and name ~= "" then
            local sr = IsSpellInRange(name, "target")
            if sr == 1 then
                SetColorTable(s.color)
                return
            end

            if sr == nil then
                local ok, yards = CustomSpellInRange(name)
                if ok == true then
                    local pc = yards and TargetRangeBoxDB.proxyColors and TargetRangeBoxDB.proxyColors[yards]
                    if type(pc) == "table" and pc[1] then
                        SetColorTable(pc)
                    else
                        SetColorTable(s.color)
                    end
                    return
                end
            end

            if IsItemInRangeBool(name) == true then
                SetColorTable(s.color)
                return
            end
        end
    end

    SetColorTable(TargetRangeBoxDB.outOfRangeColor)
end

-- ============================================================
-- Throttled OnUpdate + Apply
-- ============================================================

local elapsedSince = 0
local function OnUpdate(_, elapsed)
    elapsedSince = elapsedSince + elapsed
    if elapsedSince < TargetRangeBoxDB.updateFrequency then return end
    elapsedSince = 0
    UpdateRange()
end

local function ApplyShowState()
    if TargetRangeBoxDB.show then
        Box:Show()
        Box:SetScript("OnUpdate", OnUpdate)
        elapsedSince = TargetRangeBoxDB.updateFrequency
        UpdateRange()
    else
        Box:SetScript("OnUpdate", nil)
        Box:Hide()
    end
end

local function ApplyAll()
    Box:ClearAllPoints()
    Box:SetPoint(unpack(TargetRangeBoxDB.point))
    Redraw()
    UpdateClickThrough()
    RebuildActiveSlots()
    lastR, lastG, lastB, lastA = nil, nil, nil, nil
    ApplyShowState()
end

-- ============================================================
-- Color Picker Helper
-- ============================================================

local function ShowColorPicker(initial, onChange)
    local r, g, b, a = initial[1], initial[2], initial[3], initial[4]

    ColorPickerFrame.hasOpacity = true
    ColorPickerFrame.opacity = 1 - (a or 1)
    ColorPickerFrame.previousValues = {r, g, b, a}

    ColorPickerFrame.func = function()
        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
        local na = 1 - OpacitySliderFrame:GetValue()
        onChange(nr, ng, nb, na)
    end

    ColorPickerFrame.opacityFunc = ColorPickerFrame.func

    ColorPickerFrame.cancelFunc = function(prev)
        if type(prev) == "table" and prev[1] then
            onChange(prev[1], prev[2], prev[3], prev[4])
        else
            onChange(r, g, b, a)
        end
    end

    ColorPickerFrame:SetColorRGB(r, g, b)
    ColorPickerFrame:Show()
end

-- ============================================================
-- Delete Confirmation Popup
-- ============================================================

local DELETE_DIALOG_KEY = "TARGETRANGEBOX_CONFIRM_DELETE_PROFILE"
StaticPopupDialogs[DELETE_DIALOG_KEY] = StaticPopupDialogs[DELETE_DIALOG_KEY] or {
    text = "Delete profile \"%s\"?\nThis cannot be undone.",
    button1 = "Delete",
    button2 = CANCEL,
    OnAccept = function() end,
    OnCancel = function() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- ============================================================
-- Options Panel UI
-- ============================================================

local Options = CreateFrame("Frame", "TargetRangeBoxOptions", UIParent)
Options.name = "TargetRangeBox"

Options:SetScript("OnShow", function(self)
    if not TargetRangeBoxDB then return end

    if self._init then
        local ui = self._ui
        local nameBox = ui and ui.profilesNameBox
        if nameBox then
            local cur = CleanName(nameBox:GetText())
            if cur == "" and not nameBox._trbUserCleared then
                local pn = CleanName((UnitName and UnitName("player")) or "")
                if pn ~= "" then
                    nameBox:SetText(pn)
                    nameBox:SetCursorPosition(0)
                end
            end
        end
        return
    end

    self._init = true

    EnsureProfilesDB()

    TargetRangeBoxDB.rangeProxies = TargetRangeBoxDB.rangeProxies or {}
    TargetRangeBoxDB.proxyColors = TargetRangeBoxDB.proxyColors or {}
    TargetRangeBoxDB.remoteProxy = TargetRangeBoxDB.remoteProxy or {}
    if TargetRangeBoxDB.remoteProxy.enabled == nil then TargetRangeBoxDB.remoteProxy.enabled = true end
    if type(TargetRangeBoxDB.remoteProxy.maxAge) ~= "number" then TargetRangeBoxDB.remoteProxy.maxAge = 0.75 end

    -- NEW: ensure toggle table exists (default ON unless user turns OFF)
    TargetRangeBoxDB.closeRangeProxy = TargetRangeBoxDB.closeRangeProxy or {}
    if TargetRangeBoxDB.closeRangeProxy.enabled == nil then TargetRangeBoxDB.closeRangeProxy.enabled = true end

    if type(TargetRangeBoxDB.proxyColors[10]) ~= "table" then TargetRangeBoxDB.proxyColors[10] = {1, 1, 1, 1} end
    if type(TargetRangeBoxDB.proxyColors[12]) ~= "table" then TargetRangeBoxDB.proxyColors[12] = {1, 0.7843137255, 0.1960784314, 1} end

    self._ui = {
        checkShow = nil,
        checkShowNoTarget = nil,
        checkLock = nil,
        spellEdit = {},
        spellSwatch = {},
        profilesDropdown = nil,
        profilesSelected = nil,
        profilesRefreshDropdown = nil,
        profilesNameBox = nil,
    }

    local leftX, rightX = 16, 360
    local GAP_ROW, GAP_CHECK, GAP_SECTION = 42, 24, 16

    local function Title(text, x, y)
        local t = self:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        t:SetPoint("TOPLEFT", x, y)
        t:SetText(text)
        return y - 28
    end

    local function Header(text, x, y)
        local t = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        t:SetPoint("TOPLEFT", x, y)
        t:SetText(text)
        return y - 18
    end

    local function Note(text, x, y)
        local t = self:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        t:SetPoint("TOPLEFT", x, y)
        t:SetText(text)
        t:SetJustifyH("LEFT")
        t:SetWidth(320)
        return y - 16
    end

    local function CheckboxAt(label, x, y, storeKey, getter, setter)
        local cb = CreateFrame("CheckButton", nil, self, "InterfaceOptionsCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", x, y)
        cb.Text:SetText(label)
        cb:SetChecked(getter())
        cb:SetScript("OnClick", function(btn) setter(btn:GetChecked()) end)
        if storeKey then self._ui[storeKey] = cb end
        return y - GAP_CHECK
    end

    local function SliderAt(x, y, label, minv, maxv, step, getter, setter, width)
        width = width or 240

        local text = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        text:SetPoint("TOPLEFT", x, y)

        local function SetTextForValue(v)
            if step >= 1 then
                text:SetText(label .. ": " .. tostring(v))
            else
                text:SetText(label .. ": " .. string.format("%.2f", v))
            end
        end

        SetTextForValue(getter())

        local s = CreateFrame("Slider", nil, self, "OptionsSliderTemplate")
        s:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -6)
        s:SetWidth(width)
        s:SetMinMaxValues(minv, maxv)
        s:SetValueStep(step)
        s:SetObeyStepOnDrag(true)
        s:SetValue(getter())

        s:SetScript("OnValueChanged", function(_, v)
            if step >= 1 then
                v = math_floor(v + 0.5)
            else
                v = math_floor((v / step) + 0.5) * step
            end
            SetTextForValue(v)
            setter(v)
        end)

        return y - 52
    end

    local function ColorRowAt(x, y, label, getter, setter)
        local btn = CreateFrame("Button", nil, self)
        btn:SetSize(20, 20)
        btn:SetPoint("TOPLEFT", x, y)

        local swatch = btn:CreateTexture(nil, "BACKGROUND")
        swatch:SetAllPoints()

        local function Refresh()
            local c = getter()
            swatch:SetColorTexture(c[1], c[2], c[3], c[4])
        end
        Refresh()

        local t = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        t:SetPoint("LEFT", btn, "RIGHT", 8, 0)
        t:SetText(label)

        btn:SetScript("OnClick", function()
            ShowColorPicker(getter(), function(r, g, b, a)
                setter({r, g, b, a})
                Refresh()
                UpdateRange()
            end)
        end)

        return y - 28
    end

    local function AddDelOkButtons(editBox, okCallback, delCallback)
        local okW, delW, pad = 30, 34, 2
        editBox:SetTextInsets(6, okW + delW + pad * 3 + 2, 0, 0)

        local ok = CreateFrame("Button", nil, editBox, "UIPanelButtonTemplate")
        ok:SetSize(okW, 18)
        ok:SetPoint("RIGHT", editBox, "RIGHT", -pad, 0)
        ok:SetText("OK")
        ok:SetScript("OnClick", function() if okCallback then okCallback() end end)

        local del = CreateFrame("Button", nil, editBox, "UIPanelButtonTemplate")
        del:SetSize(delW, 18)
        del:SetPoint("RIGHT", ok, "LEFT", -pad, 0)
        del:SetText("DEL")
        del:SetScript("OnClick", function() if delCallback then delCallback() end end)

        editBox:SetScript("OnEnterPressed", function() if okCallback then okCallback() end end)
    end

    local function SlotRowAt(x, y, i)
        local editW, swatchSize, gap = 220, 18, 6

        local label = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        label:SetPoint("TOPLEFT", x, y)
        label:SetText("Spell / Item " .. i)

        local eb = CreateFrame("EditBox", nil, self, "InputBoxTemplate")
        eb:SetPoint("TOPLEFT", x, y - 16)
        eb:SetSize(editW, 20)
        eb:SetAutoFocus(false)
        eb:SetText(TargetRangeBoxDB.spells[i].name or "")
        eb:SetCursorPosition(0)

        local function Save()
            TargetRangeBoxDB.spells[i].name = eb:GetText() or ""
            eb:ClearFocus()
            RebuildActiveSlots()
            UpdateRange()
        end

        local function Del()
            eb:SetText("")
            TargetRangeBoxDB.spells[i].name = ""
            eb:ClearFocus()
            RebuildActiveSlots()
            UpdateRange()
        end

        AddDelOkButtons(eb, Save, Del)

        local tNum = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        tNum:SetPoint("LEFT", eb, "RIGHT", gap, 0)
        tNum:SetText(tostring(i))

        local btn = CreateFrame("Button", nil, self)
        btn:SetSize(swatchSize, swatchSize)
        btn:SetPoint("LEFT", tNum, "RIGHT", gap, 0)

        local swatch = btn:CreateTexture(nil, "BACKGROUND")
        swatch:SetAllPoints()

        local function Refresh()
            local c = TargetRangeBoxDB.spells[i].color
            swatch:SetColorTexture(c[1], c[2], c[3], c[4])
        end
        Refresh()

        btn:SetScript("OnClick", function()
            ShowColorPicker(TargetRangeBoxDB.spells[i].color, function(r, g, b, a)
                TargetRangeBoxDB.spells[i].color = {r, g, b, a}
                Refresh()
                UpdateRange()
            end)
        end)

        self._ui.spellEdit[i] = eb
        self._ui.spellSwatch[i] = swatch

        return y - GAP_ROW
    end

    local function ProxyRowAt(x, y, label, yards)
        local editW, swatchSize, gap = 220, 18, 6

        local t = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        t:SetPoint("TOPLEFT", x, y)
        t:SetText(label)

        local eb = CreateFrame("EditBox", nil, self, "InputBoxTemplate")
        eb:SetPoint("TOPLEFT", x, y - 16)
        eb:SetSize(editW, 20)
        eb:SetAutoFocus(false)
        eb:SetText(TargetRangeBoxDB.rangeProxies[yards] or "")
        eb:SetCursorPosition(0)

        local function Save()
            TargetRangeBoxDB.rangeProxies[yards] = CleanName(eb:GetText())
            eb:ClearFocus()
            UpdateRange()
        end

        local function Del()
            eb:SetText("")
            TargetRangeBoxDB.rangeProxies[yards] = ""
            eb:ClearFocus()
            UpdateRange()
        end

        AddDelOkButtons(eb, Save, Del)

        local btn = CreateFrame("Button", nil, self)
        btn:SetSize(swatchSize, swatchSize)
        btn:SetPoint("LEFT", eb, "RIGHT", gap + 30, 0)

        local ydLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        ydLabel:SetPoint("RIGHT", btn, "LEFT", -gap, 0)
        ydLabel:SetText(tostring(yards) .. "yd")

        local sw = btn:CreateTexture(nil, "BACKGROUND")
        sw:SetAllPoints()

        local function RefreshSwatch()
            local c = TargetRangeBoxDB.proxyColors[yards]
            sw:SetColorTexture(c[1], c[2], c[3], c[4])
        end
        RefreshSwatch()

        btn:SetScript("OnClick", function()
            ShowColorPicker(TargetRangeBoxDB.proxyColors[yards], function(r, g, b, a)
                TargetRangeBoxDB.proxyColors[yards] = {r, g, b, a}
                RefreshSwatch()
            end)
        end)

        return y - GAP_ROW
    end

    local function SaveProfile(name)
        EnsureProfilesDB()
        name = CleanName(name)
        if name == "" then return false, "Enter a profile name." end
        TargetRangeBoxProfilesDB.profiles[name] = DeepCopy(TargetRangeBoxDB)
        return true, "Saved profile: " .. name
    end

    local function LoadProfile(name)
        EnsureProfilesDB()
        name = CleanName(name)
        local p = TargetRangeBoxProfilesDB.profiles[name]
        if type(p) ~= "table" then return false, "Profile not found." end
        TargetRangeBoxDB = CopyDefaults(defaults, DeepCopy(p))
        ApplyAll()
        return true, "Loaded profile: " .. name
    end

    local function DeleteProfile(name)
        EnsureProfilesDB()
        name = CleanName(name)
        if TargetRangeBoxProfilesDB.profiles[name] == nil then return false, "Profile not found." end
        TargetRangeBoxProfilesDB.profiles[name] = nil
        return true, "Deleted profile: " .. name
    end

    local function ResetCharacter()
        TargetRangeBoxDB = CopyDefaults(defaults, {})
        ApplyAll()
        return true, "Reset this character to defaults."
    end

    local yL, yR = -16, -16
    yL = Title("TargetRangeBox", leftX, yL)

    yL = CheckboxAt("Show Box", leftX, yL, "checkShow",
        function() return TargetRangeBoxDB.show end,
        function(v) TargetRangeBoxDB.show = v; ApplyShowState() end
    )

    yL = CheckboxAt("Show Box/No Target", leftX, yL, "checkShowNoTarget",
        function() return TargetRangeBoxDB.showNoTarget end,
        function(v) TargetRangeBoxDB.showNoTarget = v; UpdateRange() end
    )

    yL = CheckboxAt("Lock (click-through)", leftX, yL, "checkLock",
        function() return TargetRangeBoxDB.lock end,
        function(v) TargetRangeBoxDB.lock = v; UpdateClickThrough() end
    )

    yL = yL - 2
    yL = ColorRowAt(leftX, yL, "Out of Range Color",
        function() return TargetRangeBoxDB.outOfRangeColor end,
        function(c) TargetRangeBoxDB.outOfRangeColor = c end
    )

    yL = yL - 6
    yR = Title("Display", rightX, yR)

    yR = SliderAt(rightX, yR, "Box Size", 5, 100, 1,
        function() return TargetRangeBoxDB.size end,
        function(v) TargetRangeBoxDB.size = v; Redraw() end
    )

    yR = SliderAt(rightX, yR, "Transparency", 0, 1, 0.05,
        function() return TargetRangeBoxDB.alpha end,
        function(v) TargetRangeBoxDB.alpha = v; UpdateRange() end
    )

    local yTop = yL
    if yR < yTop then yTop = yR end
    yTop = yTop - GAP_SECTION

    local yLeftSpells  = Header("Spells / Items 1-5 (Farthest / Mid)", leftX,  yTop)
    local yRightSpells = Header("Spells / Items 6-10 (Mid / Nearest)", rightX, yTop)

    for i = 1, 5 do yLeftSpells = SlotRowAt(leftX, yLeftSpells, i) end
    for i = 6, 10 do yRightSpells = SlotRowAt(rightX, yRightSpells, i) end

    yLeftSpells = yLeftSpells - 6
    yLeftSpells = Header("Close-Range AoE/Cone Proxies", leftX, yLeftSpells)

    yLeftSpells = Note(" ", leftX + 28, yLeftSpells + 6)

    local yProxyFirstRow = yLeftSpells
    yLeftSpells = ProxyRowAt(leftX, yLeftSpells, "10 Yard Range:", 10)
    yLeftSpells = ProxyRowAt(leftX, yLeftSpells, "12 Yard Range:", 12)

    -- NEW: toggle + helper note
    yLeftSpells = CheckboxAt("Close-Range AoE/Cone Proxies (ON/OFF)", leftX, yLeftSpells, nil,
        function() return TargetRangeBoxDB.closeRangeProxy and TargetRangeBoxDB.closeRangeProxy.enabled end,
        function(v)
            TargetRangeBoxDB.closeRangeProxy.enabled = (v and true or false)
            UpdateRange()
        end
    )
    yLeftSpells = Note("(Uncheck box = OFF for no close-range check)", leftX + 28, yLeftSpells + 6)

    yLeftSpells = yLeftSpells - 5
    local profLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    profLabel:SetPoint("TOPLEFT", leftX, yLeftSpells)
    profLabel:SetText("Profiles")
    yLeftSpells = yLeftSpells - 20

    local selectedProfile = nil
    self._ui.profilesSelected = nil

    local dropdown = CreateFrame("Frame", "TargetRangeBoxEmbeddedProfilesDropdown", self, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", leftX - 16, yLeftSpells + 6)
    UIDropDownMenu_SetWidth(dropdown, 260)
    UIDropDownMenu_SetText(dropdown, "Select a profile")
    self._ui.profilesDropdown = dropdown

    local function RefreshDropdown()
        EnsureProfilesDB()
        local keys = SortedKeys(TargetRangeBoxProfilesDB.profiles)

        UIDropDownMenu_Initialize(dropdown, function(_, level)
            local info = UIDropDownMenu_CreateInfo()
            info.func = function(btn)
                selectedProfile = btn.value
                self._ui.profilesSelected = selectedProfile
                UIDropDownMenu_SetText(dropdown, selectedProfile)
            end

            if #keys == 0 then
                info.text, info.notCheckable, info.disabled = "(No saved profiles)", true, true
                UIDropDownMenu_AddButton(info, level)
                return
            end

            for _, name in ipairs(keys) do
                info.text = name
                info.value = name
                info.checked = (name == selectedProfile)
                info.notCheckable = false
                info.disabled = false
                UIDropDownMenu_AddButton(info, level)
            end
        end)
    end

    self._ui.profilesRefreshDropdown = RefreshDropdown
    RefreshDropdown()

    local btnW, btnH, btnGap = 260, 22, 6
    local yButtons = yProxyFirstRow + 2

    local btnSave = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    btnSave:SetSize(btnW, btnH)
    btnSave:SetPoint("TOPLEFT", rightX, yButtons)
    btnSave:SetText("Save Current As...")
    yButtons = yButtons - (btnH + btnGap)

    local btnLoad = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    btnLoad:SetSize(btnW, btnH)
    btnLoad:SetPoint("TOPLEFT", rightX, yButtons)
    btnLoad:SetText("Load To This Character")
    yButtons = yButtons - (btnH + btnGap)

    local btnDelete = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    btnDelete:SetSize(btnW, btnH)
    btnDelete:SetPoint("TOPLEFT", rightX, yButtons)
    btnDelete:SetText("Delete Profile")
    yButtons = yButtons - (btnH + btnGap)

    local btnReset = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    btnReset:SetSize(btnW, btnH)
    btnReset:SetPoint("TOPLEFT", rightX, yButtons)
    btnReset:SetText("Reset This Character")

    local yName = yButtons - (btnH + 10)

    local nameLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    nameLabel:SetPoint("TOPLEFT", rightX, yName)
    nameLabel:SetText("Profile Name")

    local nameBox = CreateFrame("EditBox", nil, self, "InputBoxTemplate")
    nameBox:SetPoint("TOPLEFT", rightX, yName - 20)
    nameBox:SetSize(260, 20)
    nameBox:SetAutoFocus(false)

    local initialCharName = CleanName((UnitName and UnitName("player")) or "")
    nameBox._trbUserCleared = false
    nameBox:SetText(initialCharName ~= "" and initialCharName or "")
    nameBox:SetCursorPosition(0)

    self._ui.profilesNameBox = nameBox

    AddDelOkButtons(nameBox,
        function()
            local cleaned = CleanName(nameBox:GetText())
            nameBox:SetText(cleaned)
            nameBox._trbUserCleared = (cleaned == "")
            nameBox:ClearFocus()
        end,
        function()
            nameBox:SetText("")
            nameBox._trbUserCleared = true
            nameBox:ClearFocus()
        end
    )

    btnSave:SetScript("OnClick", function()
        local name = CleanName(nameBox:GetText())
        local ok, msg = SaveProfile(name)
        PrintMsg(msg)
        if ok then
            selectedProfile = name
            self._ui.profilesSelected = name
            UIDropDownMenu_SetText(dropdown, selectedProfile)
            RefreshDropdown()
        end
    end)

    btnLoad:SetScript("OnClick", function()
        local name = self._ui.profilesSelected or CleanName(nameBox:GetText())
        if not name or name == "" then
            PrintMsg("Select a profile (dropdown) or type a profile name first.")
            return
        end
        local _, msg = LoadProfile(name)
        PrintMsg(msg)
        RefreshDropdown()
        UpdateRange()
    end)

    btnDelete:SetScript("OnClick", function()
        local name = self._ui.profilesSelected or CleanName(nameBox:GetText())
        if not name or name == "" then
            PrintMsg("Select a profile (dropdown) or type a profile name first.")
            return
        end

        StaticPopupDialogs[DELETE_DIALOG_KEY].OnAccept = function()
            local ok, msg = DeleteProfile(name)
            PrintMsg(msg)
            if ok then
                selectedProfile = nil
                self._ui.profilesSelected = nil
                UIDropDownMenu_SetText(dropdown, "Select a profile")
                RefreshDropdown()
            end
        end

        StaticPopup_Show(DELETE_DIALOG_KEY, name)
    end)

    btnReset:SetScript("OnClick", function()
        local _, msg = ResetCharacter()
        PrintMsg(msg)
        RefreshDropdown()
        UpdateRange()
    end)
end)

-- ============================================================
-- Options registration + /trb commands
-- ============================================================

local optionsRegistered = false
local function RegisterOptionsPanel()
    if optionsRegistered then return end

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(Options, Options.name)
        if category then
            Settings.RegisterAddOnCategory(category)
            Options._settingsCategory = category
        end
    end

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(Options)
    end

    optionsRegistered = true
end

local function OpenOptionsPanel()
    RegisterOptionsPanel()

    if Settings and Settings.OpenToCategory and Options._settingsCategory then
        Settings.OpenToCategory(Options._settingsCategory:GetID())
        return
    end

    if InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(Options)
        InterfaceOptionsFrame_OpenToCategory(Options)
        return
    end

    PrintMsg("Open Options and select TargetRangeBox in the AddOns list.")
end

local function SyncOptionsCheckboxes()
    if not Options or not Options._init then return end
    local ui = Options._ui
    if not ui then return end
    if ui.checkShow then ui.checkShow:SetChecked(TargetRangeBoxDB.show and true or false) end
    if ui.checkShowNoTarget then ui.checkShowNoTarget:SetChecked(TargetRangeBoxDB.showNoTarget and true or false) end
    if ui.checkLock then ui.checkLock:SetChecked(TargetRangeBoxDB.lock and true or false) end
end

local function HandleSlash(msg)
    msg = tostring(msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local lower = msg:lower()

    if not TargetRangeBoxDB then
        OpenOptionsPanel()
        return
    end

    if lower == "lock" then
        TargetRangeBoxDB.lock = true
        UpdateClickThrough()
        SyncOptionsCheckboxes()
        PrintMsg("Locked (click-through enabled).")
        return
    end

    if lower == "unlock" then
        TargetRangeBoxDB.lock = false
        UpdateClickThrough()
        SyncOptionsCheckboxes()
        PrintMsg("Unlocked (movable/clickable).")
        return
    end

    if lower == "show" then
        TargetRangeBoxDB.show = true
        ApplyShowState()
        SyncOptionsCheckboxes()
        PrintMsg("Show Box: ON")
        return
    end

    if lower == "hide" then
        TargetRangeBoxDB.show = false
        ApplyShowState()
        SyncOptionsCheckboxes()
        PrintMsg("Show Box: OFF")
        return
    end

    if lower == "show nt" or lower == "show no target" then
        TargetRangeBoxDB.showNoTarget = true
        UpdateRange()
        SyncOptionsCheckboxes()
        PrintMsg("Show Box/No Target: ON")
        return
    end

    if lower == "hide nt" or lower == "hide no target" then
        TargetRangeBoxDB.showNoTarget = false
        UpdateRange()
        SyncOptionsCheckboxes()
        PrintMsg("Show Box/No Target: OFF")
        return
    end

    OpenOptionsPanel()
end

SLASH_TARGETRANGEBOX1 = "/trb"
SlashCmdList.TARGETRANGEBOX = function(msg) HandleSlash(msg) end

-- ============================================================
-- Init
-- ============================================================

local Loader = CreateFrame("Frame")
Loader:RegisterEvent("ADDON_LOADED")
Loader:SetScript("OnEvent", function(_, _, name)
    if name ~= ADDON_NAME then return end

    EnsureProfilesDB()

    local isFirstRun = (type(TargetRangeBoxDB) ~= "table") or (TargetRangeBoxDB._firstRunComplete ~= true)
    TargetRangeBoxDB = CopyDefaults(defaults, TargetRangeBoxDB or {})

    if type(RegisterAddonMessagePrefix) == "function" then
        pcall(RegisterAddonMessagePrefix, TRB_PREFIX)
    end

    RegisterOptionsPanel()
    ApplyAll()

    if isFirstRun then
        TargetRangeBoxDB._firstRunComplete = true
        PrintRaw("TargetRangeBox Loaded: Type (/trb) to open the options menu.")
    end
end)
