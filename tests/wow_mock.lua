-- Minimal mock of the WoW Forever (Midnight-based) client API, enough to load
-- Kill List Stats and drive it with fake events. Not a full emulator.

MOCK = { now = 1000, timers = {}, messages = {}, popups = {}, events = {}, frames = {} }

-- Lua 5.1 has no bit ops; WoW provides the "bit" library.
bit = {
    band = function(a, b)
        local r, p = 0, 1
        while a > 0 and b > 0 do
            if a % 2 == 1 and b % 2 == 1 then r = r + p end
            a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
        end
        return r
    end,
}

-- Secret values: any table with __secret = true counts as secret.
function SECRET(v) return { __secret = true, v = v } end
function issecretvalue(v) return type(v) == "table" and rawget(v, "__secret") == true end
function canaccesstable(t) return true end

wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
tinsert = table.insert
unpack = unpack or table.unpack
date = os.date
time = function() return 1700000000 + math.floor(MOCK.now) end
GetTime = function() return MOCK.now end

-- Moves the clock forward, running timers in order at their due time.
function MOCK.Advance(sec)
    local target = MOCK.now + sec
    while true do
        table.sort(MOCK.timers, function(a, b) return a.at < b.at end)
        local t = MOCK.timers[1]
        if not t or t.at > target then break end
        table.remove(MOCK.timers, 1)
        MOCK.now = math.max(MOCK.now, t.at)
        t.fn()
    end
    MOCK.now = target
end

C_Timer = {
    After = function(sec, fn) table.insert(MOCK.timers, { at = MOCK.now + sec, fn = fn }) end,
    NewTicker = function(sec, fn) return { Cancel = function() end } end,
}

C_AddOns = { GetAddOnMetadata = function() return "1.0.0-test" end }

-- Chat output
DEFAULT_CHAT_FRAME = {
    AddMessage = function(_, msg)
        local plain = msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "")
        table.insert(MOCK.messages, plain)
        print("    chat> " .. plain)
    end,
}

---------------------------------------------------------------------------
-- Units
---------------------------------------------------------------------------
MOCK.units = {}
MOCK.guidInfo = {}

local function U(unit) return MOCK.units[unit] end
function UnitExists(unit) return U(unit) ~= nil end
function UnitIsPlayer(unit) local u = U(unit); return u ~= nil and u.isPlayer == true end
function UnitIsEnemy(_, unit) local u = U(unit); return u ~= nil and u.enemy == true end
function UnitCanAttack(_, unit) local u = U(unit); return u ~= nil and u.enemy == true end
function UnitGUID(unit) local u = U(unit); return u and u.guid end
function UnitName(unit) local u = U(unit); if u then return u.name, u.realm end end
function UnitLevel(unit) local u = U(unit); return u and u.level or 0 end
function UnitClass(unit) local u = U(unit); if u then return u.class, u.class, 1 end end
function UnitRace(unit) local u = U(unit); if u then return u.race, u.race, 1 end end
function GetGuildInfo(unit) local u = U(unit); return u and u.guild end
function UnitIsUnit(a, b)
    if b == "player" and a:sub(-6) == "target" then
        local base = a:sub(1, -7)
        local u = U(base)
        return u ~= nil and u.targetingMe == true
    end
    return a == b
end
function UnitAffectingCombat() return false end
function IsInGroup() return MOCK.group ~= nil end
function GetNumGroupMembers() return MOCK.group or 0 end

function GetPlayerInfoByGUID(guid)
    local i = MOCK.guidInfo[guid]
    if not i then return nil end
    return i.className, i.class, i.race, i.race, 2, i.name, i.realm or "", i.level
end

function GetNormalizedRealmName() return "MyRealm" end
function GetRealmName() return "My Realm" end
function IsInInstance()
    if MOCK.instanceType then return true, MOCK.instanceType end
    return false, "none"
end
function GetRealZoneText() return MOCK.zone or "Stranglethorn Vale" end
function GetSubZoneText() return MOCK.subzone or "" end

C_DeathRecap = {
    HasRecapEvents = function() return MOCK.recap ~= nil end,
    GetRecapEvents = function() return MOCK.recap end,
    GetRecapMaxHealth = function() return MOCK.maxHP or 1000 end,
}

RAID_CLASS_COLORS = {
    ROGUE = { r = 1, g = 0.96, b = 0.41, colorStr = "fffff569" },
    WARRIOR = { r = 0.78, g = 0.61, b = 0.43, colorStr = "ffc79c6e" },
    MAGE = { r = 0.41, g = 0.8, b = 0.94, colorStr = "ff69ccf0" },
    HUNTER = { r = 0.67, g = 0.83, b = 0.45, colorStr = "ffabd473" },
}
LOCALIZED_CLASS_NAMES_MALE = { ROGUE = "Rogue", WARRIOR = "Warrior", MAGE = "Mage", HUNTER = "Hunter" }
CLASS_ICON_TCOORDS = { ROGUE = { 0.49, 0.73, 0, 0.25 }, WARRIOR = { 0, 0.25, 0, 0.25 }, MAGE = { 0.25, 0.49, 0, 0.25 }, HUNTER = { 0, 0.25, 0.25, 0.5 } }
SOUNDKIT = { RAID_WARNING = 8959, IG_CHARACTER_INFO_TAB = 841 }
ChatTypeInfo = { RAID_WARNING = { r = 1, g = 0.3, b = 0 } }
ACCEPT, CANCEL, YES, NO = "Accept", "Cancel", "Yes", "No"
function PlaySound() end
function RaidNotice_AddMessage(_, msg) MOCK.lastRaidWarning = msg end
RaidWarningFrame = {}

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------
local Methods = {}
local Meta = {
    __index = function(t, k)
        local m = Methods[k]
        if m then return m end
        -- Unknown widget methods (they start with a capital letter) are no-ops.
        if type(k) == "string" and k:find("^%u") then return function() return nil end end
        return nil
    end,
}

local function NewObject(kind, parent)
    local o = setmetatable({ _kind = kind, _scripts = {}, _shown = true, _text = "", _parent = parent, _events = {} }, Meta)
    table.insert(MOCK.frames, o)
    return o
end
MOCK.NewObject = NewObject

function Methods:SetScript(name, fn) self._scripts[name] = fn end
function Methods:GetScript(name) return self._scripts[name] end
function Methods:HookScript(name, fn)
    local old = self._scripts[name]
    self._scripts[name] = function(...) if old then old(...) end fn(...) end
end
function Methods:RegisterEvent(ev) self._events[ev] = true; MOCK.events[ev] = MOCK.events[ev] or {}; table.insert(MOCK.events[ev], self) end
function Methods:UnregisterEvent(ev) self._events[ev] = nil end
function Methods:Show()
    local was = self._shown
    self._shown = true
    if not was and self._scripts.OnShow then self._scripts.OnShow(self) end
end
function Methods:Hide() self._shown = false end
function Methods:IsShown() return self._shown end
function Methods:IsVisible() return self._shown end
function Methods:SetShown(v) if v then self:Show() else self:Hide() end end
function Methods:SetText(t) self._text = t end
function Methods:GetText() return self._text end
function Methods:SetID(id) self._id = id end
function Methods:GetID() return self._id end
function Methods:SetChecked(v) self._checked = v end
function Methods:GetChecked() return self._checked end
function Methods:GetParent() return self._parent end
function Methods:GetPoint() return "CENTER", nil, "CENTER", 10, 20 end
function Methods:CreateFontString() return NewObject("FontString", self) end
function Methods:CreateTexture() return NewObject("Texture", self) end
function Methods:Click() if self._scripts.OnClick then self._scripts.OnClick(self, "LeftButton") end end

-- ScrollBox behaviour: initialize one row per element.
function Methods:SetDataProvider(dp)
    self._rows = self._rows or {}
    local list = dp.list
    for i, data in ipairs(list) do
        local row = self._rows[i] or NewObject("Button", self)
        self._rows[i] = row
        self._view.init(row, data)
    end
    self._count = #list
end
function Methods:ForEachFrame(fn)
    for i = 1, (self._count or 0) do fn(self._rows[i]) end
end

function CreateFrame(kind, name, parent, template)
    local o = NewObject(kind, parent)
    if name then _G[name] = o end
    template = template or ""
    if template:find("ButtonFrameTemplate") then
        o.Inset = NewObject("Frame", o)
        o.CloseButton = NewObject("Button", o)
    end
    if template:find("UICheckButtonTemplate") then o.Text = NewObject("FontString", o) end
    if template:find("PanelTabButtonTemplate") then
        local tabs = rawget(parent, "Tabs") or {}
        rawset(parent, "Tabs", tabs)
        table.insert(tabs, o)
    end
    return o
end

function Mixin(obj, ...)
    for i = 1, select("#", ...) do
        for k, v in pairs((select(i, ...))) do obj[k] = v end
    end
    return obj
end
function CreateDataProvider(list) return { list = list } end
function CreateScrollBoxListLinearView()
    return {
        SetElementExtent = function() end,
        SetElementInitializer = function(self, _, fn) self.init = fn end,
    }
end
ScrollUtil = { InitScrollBoxListWithScrollBar = function(sb, _, view) sb._view = view end }
ScrollBoxConstants = { RetainScrollPosition = true }
function ButtonFrameTemplate_HidePortrait() end
function PanelTemplates_SetNumTabs(f, n) f.numTabs = n end
function PanelTemplates_SetTab(f, id) f.selectedTab = id end
UISpecialFrames = {}
UIParent = NewObject("Frame")
StaticPopupDialogs = {}
function StaticPopup_Show(which, a1, a2, data) table.insert(MOCK.popups, { which = which, a1 = a1, data = data }) end

-- Tooltip
GameTooltip = NewObject("GameTooltip")
GameTooltip._lines = {}
function GameTooltip:AddLine(t) table.insert(self._lines, t) end
function GameTooltip:AddDoubleLine(l, r) table.insert(self._lines, l .. " || " .. r) end
function GameTooltip:SetOwner() self._lines = {} end
function GameTooltip:SetText(t) self._lines = { t } end
function GameTooltip:GetUnit() return nil, MOCK.tooltipUnit end

Enum = { TooltipDataType = { Unit = 2 } }
TooltipDataProcessor = {
    AddTooltipPostCall = function(kind, fn) MOCK.tooltipPostCall = fn end,
}

SlashCmdList = {}

function MOCK.Fire(event, ...)
    for _, f in ipairs(MOCK.events[event] or {}) do
        if f._events[event] and f._scripts.OnEvent then f._scripts.OnEvent(f, event, ...) end
    end
end
