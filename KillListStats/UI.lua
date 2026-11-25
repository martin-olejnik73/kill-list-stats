-- Kill List Stats - Main window
-- Tabs: Kills (your kill database, by player or every single kill), Deaths
-- (who killed you and why), Kill List (players to get revenge on), Classes
-- (stats by class), Options. Kills, Deaths and Classes follow the filters.

local _, ns = ...
local UI = {}
ns.UI = UI
local F = ns.Filters

local ROW_HEIGHT = 18
local GREY, RED, GREEN, GOLD = "|cffaaaaaa", "|cffff4040", "|cff40ff40", "|cffffd100"

local function Total(c) return ns.Total(c) end

local function CtxTag(ctx)
    return ctx == "bg" and "|cff60a0ffBG|r" or "|cff80d080World|r"
end

---------------------------------------------------------------------------
-- Sortable table widget (header buttons + ScrollBox list)
---------------------------------------------------------------------------

local TableMixin = {}

function TableMixin:GetColumn(key)
    for _, col in ipairs(self.columns) do
        if col.key == key then return col end
    end
end

function TableMixin:UpdateHeader()
    for _, b in ipairs(self.headerButtons) do
        local active = b.col.key == self.sortKey
        b.arrow:SetShown(active)
        if active then b.arrow:SetRotation(self.sortAsc and (math.pi / 2) or (-math.pi / 2)) end
        if active then
            b.label:SetTextColor(1, 1, 1)
        else
            b.label:SetTextColor(1, 0.82, 0)
        end
    end
end

function TableMixin:SetSort(key)
    local col = self:GetColumn(key)
    if not col or not col.sort then return end
    if self.sortKey == key then
        self.sortAsc = not self.sortAsc
    else
        self.sortKey = key
        self.sortAsc = col.asc or false
    end
    if self.onSortChanged then self.onSortChanged(self.sortKey, self.sortAsc) end
    self:SortAndShow()
end

function TableMixin:SetData(list)
    self.list = list
    self:SortAndShow()
end

function TableMixin:SortAndShow()
    local list = self.list or {}
    local col = self:GetColumn(self.sortKey)
    if col and col.sort then
        local get, asc = col.sort, self.sortAsc
        table.sort(list, function(a, b)
            local va, vb = get(a), get(b)
            if va == vb then return (a.sortName or "") < (b.sortName or "") end
            if va == nil then return false end
            if vb == nil then return true end
            if type(va) ~= type(vb) then va, vb = tostring(va), tostring(vb) end
            if asc then return va < vb end
            return va > vb
        end)
    end
    for i, data in ipairs(list) do data._i = i end
    self.scrollBox:SetDataProvider(CreateDataProvider(list), ScrollBoxConstants.RetainScrollPosition)
    self.empty:SetShown(#list == 0)
    self:UpdateHeader()
end

function TableMixin:RefreshSelection()
    self.scrollBox:ForEachFrame(function(row)
        row.sel:SetShown(row.data ~= nil and row.data.id == self.selectedId)
    end)
end

function TableMixin:GetSelected()
    if not self.selectedId or not self.list then return nil end
    for _, data in ipairs(self.list) do
        if data.id == self.selectedId then return data end
    end
end

function TableMixin:InitRow(row, data)
    if not row.cells then
        row.cells = {}
        for i, col in ipairs(self.columns) do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", row, "LEFT", self.colX[i] + 4, 0)
            if col.width then
                fs:SetWidth(col.width - 8)
            else
                fs:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            end
            fs:SetJustifyH(col.align or "LEFT")
            fs:SetWordWrap(false)
            row.cells[i] = fs
        end
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.sel = row:CreateTexture(nil, "BORDER")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(1, 0.82, 0, 0.18)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function(r, button)
            self.selectedId = r.data and r.data.id
            self:RefreshSelection()
            if self.onSelect then self.onSelect(r.data, button) end
        end)
        row:SetScript("OnEnter", function(r)
            if self.onEnter and r.data then
                GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
                self.onEnter(r.data)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    row.data = data
    for i, col in ipairs(self.columns) do
        row.cells[i]:SetText(col.text(data) or "")
    end
    row.bg:SetColorTexture(1, 1, 1, (data._i or 0) % 2 == 0 and 0.04 or 0)
    row.sel:SetShown(data.id == self.selectedId)
end

local function CreateTable(parent, columns, sortKey, sortAsc)
    local t = CreateFrame("Frame", nil, parent)
    Mixin(t, TableMixin)
    t.columns = columns
    t.sortKey, t.sortAsc = sortKey, sortAsc
    t:SetPoint("TOPLEFT", parent, "TOPLEFT", 6, -6)
    t:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -6, 6)

    local header = CreateFrame("Frame", nil, t)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", -16, 0)
    header:SetHeight(22)
    local hbg = header:CreateTexture(nil, "BACKGROUND")
    hbg:SetAllPoints()
    hbg:SetColorTexture(0, 0, 0, 0.45)
    t.header = header
    t.headerButtons, t.colX = {}, {}

    local x = 0
    for i, col in ipairs(columns) do
        t.colX[i] = x
        local b = CreateFrame("Button", nil, header)
        b:SetPoint("TOPLEFT", header, "TOPLEFT", x, 0)
        if col.width then
            b:SetSize(col.width, 22)
            x = x + col.width
        else
            b:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
        end
        b.col = col
        b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.label:SetPoint("LEFT", 4, 0)
        b.label:SetPoint("RIGHT", -4, 0)
        b.label:SetJustifyH(col.align or "LEFT")
        b.label:SetText(col.title)
        b.label:SetWordWrap(false)
        b.arrow = b:CreateTexture(nil, "OVERLAY")
        b.arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
        b.arrow:SetSize(10, 10)
        if col.align == "RIGHT" then
            b.arrow:SetPoint("LEFT", b, "LEFT", 2, 0)
        else
            b.arrow:SetPoint("RIGHT", b, "RIGHT", -2, 0)
        end
        b.arrow:Hide()
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        if col.sort then
            b:SetScript("OnClick", function() t:SetSort(col.key) end)
        end
        if col.tip then
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(col.title, 1, 1, 1)
                GameTooltip:AddLine(col.tip, nil, nil, nil, true)
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        t.headerButtons[i] = b
    end

    local scrollBox = CreateFrame("Frame", nil, t, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
    scrollBox:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -16, 0)
    local scrollBar = CreateFrame("EventFrame", nil, t, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 5, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 5, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", function(row, data) t:InitRow(row, data) end)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
    t.scrollBox, t.scrollBar = scrollBox, scrollBar

    t.empty = t:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    t.empty:SetPoint("CENTER", scrollBox, "CENTER")
    t.empty:SetText("Nothing here yet.")
    t.empty:Hide()
    return t
end

---------------------------------------------------------------------------
-- Row builders
---------------------------------------------------------------------------

local function Matches(filter, ...)
    if not filter or filter == "" then return true end
    for i = 1, select("#", ...) do
        local s = select(i, ...)
        if s and tostring(s):lower():find(filter, 1, true) then return true end
    end
    return false
end

local function PlayerRow(key, p)
    return {
        id = key, key = key, p = p,
        sortName = (p.name or ""):lower(),
        kills = Total(p.kills), deaths = Total(p.deaths), assists = Total(p.assists),
    }
end

local function NumOrDash(n)
    if not n or n == 0 then return GREY .. "-|r" end
    return tostring(n)
end

-- Kills by player. r.st holds the (filtered) numbers: world, bg, kb, solo, deaths, assists, last.
local function BuildKills(filter)
    local rows = {}
    local players = ns.db.players
    for key, st in pairs(F.PlayerStats()) do
        local p = players[key]
        local kills = st.world + st.bg
        if p and kills > 0 and Matches(filter, p.name, p.realm, ns.ClassName(p.class), p.guild) then
            rows[#rows + 1] = {
                id = key, key = key, p = p, st = st,
                sortName = (p.name or ""):lower(),
                kills = kills, deaths = st.deaths, assists = st.assists,
            }
        end
    end
    return rows
end

-- Every single kill (the kill log).
local function BuildKillLog(filter)
    local rows = {}
    local players = ns.db.players
    local s, since = F.Begin()
    for i, e in ipairs(ns.db.kills) do
        if F.Kill(e, s, since) then
            local p = players[e.key]
            if Matches(filter, p and p.name, e.key, e.zone, e.subzone, p and ns.ClassName(p.class), p and p.guild,
                    ns.BlowText(e), e.with and table.concat(e.with, " ")) then
                rows[#rows + 1] = {
                    id = "kill" .. i .. ":" .. (e.t or 0), e = e, p = p, key = e.key,
                    sortName = p and (p.name or ""):lower() or (e.key or ""):lower(),
                }
            end
        end
    end
    return rows
end

local function BuildKillList(filter)
    local rows = {}
    for key, p in pairs(ns.db.players) do
        if p.list and Matches(filter, p.name, p.realm, ns.ClassName(p.class), p.guild, p.list.note, p.list.reason) then
            rows[#rows + 1] = PlayerRow(key, p)
        end
    end
    return rows
end

local function BuildDeaths(filter)
    local rows = {}
    local players = ns.db.players
    local s, since = F.Begin()
    for i, d in ipairs(ns.db.deaths) do
        local kp = d.killer and players[d.killer]
        if F.Death(d, s, since) and Matches(filter, kp and kp.name, d.zone, d.subzone, kp and ns.ClassName(kp.class), d.reasons and table.concat(d.reasons, " ")) then
            rows[#rows + 1] = { id = "death" .. i .. ":" .. (d.t or 0), d = d, kp = kp, key = d.killer, sortName = kp and kp.name:lower() or "" }
        end
    end
    return rows
end

local function BuildClasses()
    local byClass, allKills = {}, 0
    local players = ns.db.players
    for key, st in pairs(F.PlayerStats()) do
        local p = players[key]
        if p then
            local class = p.class or "UNKNOWN"
            local c = byClass[class]
            if not c then
                c = { id = class, class = class, sortName = ns.ClassName(p.class):lower(), world = 0, bg = 0, total = 0, kb = 0, unique = 0, deaths = 0, assists = 0 }
                byClass[class] = c
            end
            local k = st.world + st.bg
            c.world = c.world + st.world
            c.bg = c.bg + st.bg
            c.total = c.total + k
            c.kb = c.kb + st.kb
            if k > 0 then c.unique = c.unique + 1 end
            c.deaths = c.deaths + st.deaths
            c.assists = c.assists + st.assists
            allKills = allKills + k
        end
    end
    local rows = {}
    for _, c in pairs(byClass) do
        if c.total + c.deaths + c.assists > 0 then
            c.pct = allKills > 0 and (c.total / allKills * 100) or 0
            c.kd = c.deaths > 0 and (c.total / c.deaths) or (c.total > 0 and math.huge or 0)
            rows[#rows + 1] = c
        end
    end
    return rows
end

---------------------------------------------------------------------------
-- Column definitions
---------------------------------------------------------------------------

local function LevelOf(p) return p.level or 0 end

local killColumns = {
    { key = "name", title = "Player", width = 140, asc = true, sort = function(r) return r.sortName end, text = function(r) return ns.ColoredName(r.p) end },
    { key = "class", title = "Class", width = 80, asc = true, sort = function(r) return ns.ClassName(r.p.class) end, text = function(r) return "|c" .. ns.ClassColorHex(r.p.class) .. ns.ClassName(r.p.class) .. "|r" end },
    { key = "level", title = "Lvl", width = 36, align = "CENTER", sort = function(r) return LevelOf(r.p) end, text = function(r) return ns.FormatLevel(r.p.level) end },
    { key = "world", title = "World", width = 48, align = "RIGHT", sort = function(r) return r.st.world end, text = function(r) return NumOrDash(r.st.world) end, tip = "Your kills on this player outside battlegrounds." },
    { key = "bg", title = "BG", width = 40, align = "RIGHT", sort = function(r) return r.st.bg end, text = function(r) return NumOrDash(r.st.bg) end, tip = "Your kills on this player in battlegrounds." },
    { key = "total", title = "Total", width = 46, align = "RIGHT", sort = function(r) return r.kills end, text = function(r) return GREEN .. r.kills .. "|r" end },
    { key = "kb", title = "Your KB", width = 60, align = "RIGHT", sort = function(r) return r.st.kb end, text = function(r)
        if r.st.kb == 0 then return GREY .. "-|r" end
        return (r.st.kb == r.kills and GREEN or "") .. r.st.kb .. (r.st.kb == r.kills and "|r" or "")
    end, tip = "Kills where you (or your pet or totem) landed the killing blow. The rest were finished by your party, a battleground teammate, an NPC or the environment. Green = every kill was yours." },
    { key = "solo", title = "Solo", width = 44, align = "RIGHT", sort = function(r) return r.st.solo end, text = function(r) return NumOrDash(r.st.solo) end,
        tip = "Kills while you were not in a party or raid. A battleground raid you were put into doesn't count as a group." },
    { key = "deaths", title = "Killed you", width = 70, align = "RIGHT", sort = function(r) return r.deaths * 1000 + r.assists end, text = function(r)
        if r.deaths == 0 and r.assists == 0 then return GREY .. "-|r" end
        return RED .. r.deaths .. "|r" .. (r.assists > 0 and (GREY .. " +" .. r.assists .. "a|r") or "")
    end, tip = "Killing blows they landed on you (+ assists on your deaths)." },
    { key = "last", title = "Last kill", width = 78, align = "RIGHT", sort = function(r) return r.st.last or 0 end, text = function(r) return ns.FormatAgo(r.st.last) end },
    { key = "guild", title = "  Guild", asc = true, sort = function(r) return (r.p.guild or "~"):lower() end, text = function(r) return r.p.guild and ("  " .. GREY .. "<" .. r.p.guild .. ">|r") or "" end },
}

local BLOW_ORDER = { mine = 1, party = 2, team = 3, other = 4 }
local GROUP_ORDER = { solo = 1, party = 2, raid = 3 }

local function KillNotes(e)
    local parts = {}
    if e.revenge then parts[#parts + 1] = GOLD .. "Revenge!|r" end
    if e.with then parts[#parts + 1] = GREY .. "with " .. table.concat(e.with, ", ") .. "|r" end
    if not ns.IsOwnBlow(e) and e.how then
        local how = {}
        for code in e.how:gmatch("[^,]+") do
            if code ~= "kb" then how[#how + 1] = code end
        end
        if #how > 0 then parts[#parts + 1] = GREY .. "counted: " .. ns.HowText(table.concat(how, ",")) .. "|r" end
    end
    return "  " .. table.concat(parts, GREY .. " · |r")
end

local logColumns = {
    { key = "time", title = "When", width = 84, sort = function(r) return r.e.t or 0 end, text = function(r) return date("%m/%d %H:%M", r.e.t or 0) end },
    { key = "where", title = "Where", width = 126, asc = true, sort = function(r) return (r.e.zone or ""):lower() end, text = function(r)
        return (r.e.ctx == "bg" and "|cff60a0ff" or "") .. (r.e.zone or "?") .. (r.e.ctx == "bg" and "|r" or "")
    end, tip = "Zone of the kill. Blue = battleground." },
    { key = "name", title = "Player", width = 126, asc = true, sort = function(r) return r.sortName end, text = function(r)
        return r.p and ns.ColoredName(r.p) or (r.e.key or "?")
    end },
    { key = "class", title = "Class", width = 70, asc = true, sort = function(r) return ns.ClassName(r.p and r.p.class) end, text = function(r)
        local class = r.p and r.p.class
        return "|c" .. ns.ClassColorHex(class) .. ns.ClassName(class) .. "|r"
    end },
    { key = "level", title = "Lvl", width = 34, align = "CENTER", sort = function(r) return r.e.skull and 999 or (r.e.level or 0) end, text = function(r)
        return ns.ColoredLevel(r.e.level, r.e.skull, r.e.myLevel)
    end, tip = "Their level when you killed them, colored against yours (grey = much lower, red = much higher)." },
    { key = "mylevel", title = "You", width = 34, align = "CENTER", sort = function(r) return r.e.myLevel or 0 end, text = function(r) return tostring(r.e.myLevel or "?") end, tip = "Your level at the time." },
    { key = "blow", title = "Killing blow", width = 138, asc = true, sort = function(r)
        return (BLOW_ORDER[ns.BlowKind(r.e)] or 9) .. ns.BlowText(r.e):lower()
    end, text = function(r) return ns.ColoredBlow(r.e) end,
        tip = "Who landed the killing blow: you, your pet or totem (green), someone in your party or raid (gold), a battleground teammate (blue), or an NPC, a guard or the environment (grey)." },
    { key = "group", title = "Your group", width = 80, sort = function(r)
        return (GROUP_ORDER[r.e.group or "solo"] or 1) * 100 + (r.e.gsize or 1)
    end, text = function(r)
        local g = r.e.group or "solo"
        return (g == "solo" and "" or GOLD) .. ns.GroupText(g, r.e.gsize) .. (g == "solo" and "" or "|r")
    end, tip = "Whether you were solo or in a party or raid you formed. A battleground raid you were put into counts as solo." },
    { key = "notes", title = "  Notes", sort = nil, text = function(r) return KillNotes(r.e) end },
}

local deathColumns = {
    { key = "time", title = "When", width = 92, sort = function(r) return r.d.t or 0 end, text = function(r) return date("%m/%d %H:%M", r.d.t or 0) end },
    { key = "where", title = "Where", width = 130, asc = true, sort = function(r) return (r.d.zone or ""):lower() end, text = function(r)
        return (r.d.ctx == "bg" and "|cff60a0ff" or "") .. (r.d.zone or "?") .. (r.d.ctx == "bg" and "|r" or "")
    end },
    { key = "mylevel", title = "You", width = 34, align = "CENTER", sort = function(r) return r.d.myLevel or 0 end, text = function(r) return tostring(r.d.myLevel or "?") end, tip = "Your level when you died." },
    { key = "killer", title = "Killed by", width = 120, asc = true, sort = function(r) return r.sortName end, text = function(r)
        return r.kp and ns.ColoredName(r.kp) or "?"
    end },
    { key = "klevel", title = "Lvl", width = 34, align = "CENTER", sort = function(r) return r.d.killerSkull and 999 or (r.d.killerLevel or 0) end, text = function(r)
        return ns.ColoredLevel(r.d.killerLevel, r.d.killerSkull, r.d.myLevel)
    end, tip = "The killer's level (red = much higher than you, ?? = 10+ levels above you)." },
    { key = "hp", title = "HP", width = 40, align = "CENTER", sort = function(r) return r.d.killerHP or 999 end, text = function(r)
        return ns.ColoredPct(r.d.killerHP)
    end, tip = "Your health when the killer started attacking you (from the death recap). Red = you were already hurt. ? = unknown." },
    { key = "assists", title = "Help", width = 40, align = "CENTER", sort = function(r) return r.d.assists and #r.d.assists or 0 end, text = function(r)
        local n = r.d.assists and #r.d.assists or 0
        return n > 0 and (RED .. "+" .. n .. "|r") or (GREY .. "-|r")
    end, tip = "How many other enemy players helped the killer (they each get an assist)." },
    { key = "group", title = "Your group", width = 76, sort = function(r)
        local g, n = ns.DeathGroup(r.d)
        return (GROUP_ORDER[g] or 1) * 100 + n
    end, text = function(r)
        local g, n = ns.DeathGroup(r.d)
        return (g == "solo" and "" or GOLD) .. ns.GroupText(g, n) .. (g == "solo" and "" or "|r")
    end, tip = "Whether you were solo or in a party or raid you formed when you died." },
    { key = "why", title = "Why", sort = nil, text = function(r)
        return GREY .. (r.d.reasons and table.concat(r.d.reasons, "; ") or "") .. "|r"
    end },
}

local listColumns = {
    { key = "name", title = "Player", width = 135, asc = true, sort = function(r) return r.sortName end, text = function(r) return ns.ColoredName(r.p) end },
    { key = "class", title = "Class", width = 78, asc = true, sort = function(r) return ns.ClassName(r.p.class) end, text = function(r) return "|c" .. ns.ClassColorHex(r.p.class) .. ns.ClassName(r.p.class) .. "|r" end },
    { key = "level", title = "Lvl", width = 34, align = "CENTER", sort = function(r) return LevelOf(r.p) end, text = function(r) return ns.FormatLevel(r.p.level) end },
    { key = "deaths", title = "Killed you", width = 66, align = "RIGHT", sort = function(r) return r.deaths end, text = function(r) return r.deaths > 0 and (RED .. r.deaths .. "|r") or (GREY .. "-|r") end },
    { key = "assists", title = "Assists", width = 52, align = "RIGHT", sort = function(r) return r.assists end, text = function(r) return NumOrDash(r.assists) end },
    { key = "cheap", title = "Cheap", width = 44, align = "RIGHT", sort = function(r) return r.p.cheap or 0 end, text = function(r)
        return (r.p.cheap or 0) > 0 and (RED .. r.p.cheap .. "|r") or (GREY .. "-|r")
    end, tip = "Cheap kills: times they killed you after jumping in while you were fighting a mob or already hurt." },
    { key = "kills", title = "Your kills", width = 64, align = "RIGHT", sort = function(r) return r.kills end, text = function(r) return r.kills > 0 and (GREEN .. r.kills .. "|r") or (GREY .. "-|r") end },
    { key = "balance", title = "Score", width = 46, align = "RIGHT", sort = function(r) return r.kills - r.deaths end, text = function(r)
        local b = r.kills - r.deaths
        if b > 0 then return GREEN .. "+" .. b .. "|r" elseif b < 0 then return RED .. b .. "|r" end
        return GOLD .. "even|r"
    end, tip = "Your kills on them minus their killing blows on you." },
    { key = "seen", title = "Last seen", width = 72, align = "RIGHT", sort = function(r) return r.p.lastSeen or 0 end, text = function(r) return ns.FormatAgo(r.p.lastSeen) end },
    { key = "note", title = "  Reason / note", asc = true, sort = function(r) return (r.p.list.note or r.p.list.reason or "~"):lower() end, text = function(r)
        local l = r.p.list
        if l.note then return "  " .. GOLD .. l.note .. "|r" end
        return "  " .. GREY .. (l.reason or "") .. "|r"
    end },
}

local function FormatKD(kd)
    if kd == math.huge then return GREEN .. "perfect|r" end
    if kd == 0 then return GREY .. "-|r" end
    return string.format("%.2f", kd)
end

local classColumns = {
    { key = "class", title = "Class", width = 130, asc = true, sort = function(r) return r.sortName end, text = function(r)
        return ns.ClassIcon(r.class ~= "UNKNOWN" and r.class) .. " |c" .. ns.ClassColorHex(r.class) .. ns.ClassName(r.class ~= "UNKNOWN" and r.class or nil) .. "|r"
    end },
    { key = "world", title = "World kills", width = 72, align = "RIGHT", sort = function(r) return r.world end, text = function(r) return NumOrDash(r.world) end },
    { key = "bg", title = "BG kills", width = 64, align = "RIGHT", sort = function(r) return r.bg end, text = function(r) return NumOrDash(r.bg) end },
    { key = "total", title = "Total", width = 56, align = "RIGHT", sort = function(r) return r.total end, text = function(r) return GREEN .. r.total .. "|r" end },
    { key = "kb", title = "Your KB", width = 60, align = "RIGHT", sort = function(r) return r.kb end, text = function(r) return NumOrDash(r.kb) end, tip = "Kills on this class where you (or your pet or totem) landed the killing blow." },
    { key = "pct", title = "% of kills", width = 66, align = "RIGHT", sort = function(r) return r.pct end, text = function(r) return string.format("%.1f%%", r.pct) end },
    { key = "unique", title = "Players", width = 58, align = "RIGHT", sort = function(r) return r.unique end, text = function(r) return NumOrDash(r.unique) end, tip = "Different players of this class you have killed." },
    { key = "deaths", title = "Killed you", width = 70, align = "RIGHT", sort = function(r) return r.deaths end, text = function(r) return r.deaths > 0 and (RED .. r.deaths .. "|r") or (GREY .. "-|r") end },
    { key = "assists", title = "Assists", width = 56, align = "RIGHT", sort = function(r) return r.assists end, text = function(r) return NumOrDash(r.assists) end },
    { key = "kd", title = "  K/D", sort = function(r) return r.kd end, text = function(r) return "  " .. FormatKD(r.kd) end, tip = "Your kills on this class divided by their killing blows on you." },
}

---------------------------------------------------------------------------
-- Row tooltips
---------------------------------------------------------------------------

local function PlayerTooltip(r)
    local p = r.p
    GameTooltip:AddLine(ns.ColoredName(p))
    GameTooltip:AddLine(string.format("Level %s %s %s", ns.FormatLevel(p.level), p.race or "", ns.ClassName(p.class)), 1, 1, 1)
    ns.AddPlayerLines(GameTooltip, p, true)
end

local function KillTooltip(r)
    local e, p = r.e, r.p
    local function Line(left, right) GameTooltip:AddDoubleLine(left, right, 0.7, 0.7, 0.7, 1, 1, 1) end
    GameTooltip:AddLine("Killed " .. (p and ns.ColoredName(p) or (e.key or "?")) .. "  " .. GREY .. ns.FormatDate(e.t) .. "|r")
    Line("Where", (e.zone or "?") .. (e.subzone and e.subzone ~= "" and (" - " .. e.subzone) or "") .. "  " .. CtxTag(e.ctx))
    Line("Levels", string.format("you %s, them %s", tostring(e.myLevel or "?"), ns.ColoredLevel(e.level, e.skull, e.myLevel)))
    Line("Killing blow", ns.ColoredBlow(e))
    local group = ns.GroupText(e.group or "solo", e.gsize)
    if e.with then group = group .. GREY .. " (with " .. table.concat(e.with, ", ") .. ")|r" end
    Line("Your group", group)
    Line("Counted from", ns.HowText(e.how))
    if e.char then Line("Character", F.CharName(e.char)) end
    if e.revenge then GameTooltip:AddLine(GOLD .. "Revenge kill: they were on your Kill List.|r") end
    if p then
        GameTooltip:AddLine(" ")
        ns.AddPlayerLines(GameTooltip, p, false)
    end
end

local function DeathTooltip(r)
    local d, kp = r.d, r.kp
    GameTooltip:AddLine(string.format("Died %s", ns.FormatDate(d.t)))
    GameTooltip:AddDoubleLine("Where", (d.zone or "?") .. (d.subzone and d.subzone ~= "" and (" - " .. d.subzone) or "") .. "  " .. CtxTag(d.ctx), 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine("Your level", tostring(d.myLevel or "?"), 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine("Your group", ns.GroupText(ns.DeathGroup(d)), 0.7, 0.7, 0.7, 1, 1, 1)
    if kp then
        GameTooltip:AddDoubleLine("Killed by", string.format("%s (%s %s)", ns.ColoredName(kp),
            ns.ColoredLevel(d.killerLevel, d.killerSkull, d.myLevel), ns.ClassName(kp.class)), 0.7, 0.7, 0.7, 1, 1, 1)
    end
    if d.kbSpell then
        GameTooltip:AddDoubleLine("Killing blow", d.kbSpell .. (d.kbAmount and (" (" .. d.kbAmount .. ")") or ""), 0.7, 0.7, 0.7, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Your HP when they attacked", ns.ColoredPct(d.killerHP), 0.7, 0.7, 0.7, 1, 1, 1)
    if d.engage then
        GameTooltip:AddLine((d.cheap and (RED .. "Cheap shot:|r ") or "") .. "They " .. d.engage, 1, 1, 1, true)
    end
    if d.assists and #d.assists > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Assists:", 1, 0.82, 0)
        for _, a in ipairs(d.assists) do
            local ap = ns.db.players[a.key]
            local how = {}
            if a.hp then how[#how + 1] = "joined at " .. ns.ColoredPct(a.hp) .. " HP" end
            if a.npc then how[#how + 1] = "while you fought " .. a.npc end
            if a.dmg then how[#how + 1] = a.dmg .. " dmg" end
            if a.targeted and not a.dmg then how[#how + 1] = "was targeting you" end
            GameTooltip:AddDoubleLine(string.format("  %s (%s %s)", ap and ns.ColoredName(ap) or a.key,
                ns.ColoredLevel(a.level, a.skull, d.myLevel), ns.ClassName(a.class)), table.concat(how, ", "), 1, 1, 1, 0.7, 0.7, 0.7)
        end
    end
    if d.reasons and #d.reasons > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Why you died:", 1, 0.82, 0)
        for _, reason in ipairs(d.reasons) do GameTooltip:AddLine("  - " .. reason, 1, 1, 1, true) end
    end
    if d.recap and #d.recap > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Last hits taken (newest first):", 1, 0.82, 0)
        for _, h in ipairs(d.recap) do
            local right = (h.amount and tostring(h.amount) or "") .. (h.hp and ("  " .. GREY .. "at|r " .. ns.ColoredPct(h.hp)) or "")
            GameTooltip:AddDoubleLine("  " .. (h.src or "?") .. ": " .. (h.spell or "?"), right, 0.9, 0.9, 0.9, 1, 0.4, 0.4)
        end
    end
end

local function ClassTooltip(r)
    GameTooltip:AddLine(ns.ClassIcon(r.class ~= "UNKNOWN" and r.class, 16) .. " |c" .. ns.ClassColorHex(r.class) .. ns.ClassName(r.class ~= "UNKNOWN" and r.class or nil) .. "|r")
    GameTooltip:AddDoubleLine("Kills (world / BG)", string.format("%d / %d", r.world, r.bg), 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine("Your killing blows", tostring(r.kb), 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine("Different players killed", tostring(r.unique), 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine("Killed you / assists", string.format("%d / %d", r.deaths, r.assists), 0.7, 0.7, 0.7, 1, 1, 1)
    -- most killed player of this class
    local best, bestN
    for _, p in pairs(ns.db.players) do
        if (p.class or "UNKNOWN") == r.class then
            local n = Total(p.kills)
            if n > 0 and (not bestN or n > bestN) then best, bestN = p, n end
        end
    end
    if best then GameTooltip:AddDoubleLine("Most killed", ns.ColoredName(best) .. " x" .. bestN, 0.7, 0.7, 0.7, 1, 1, 1) end
end

---------------------------------------------------------------------------
-- Popups
---------------------------------------------------------------------------

local function PopupEditBox(dialog)
    return (dialog.GetEditBox and dialog:GetEditBox()) or dialog.editBox or dialog.EditBox
end

StaticPopupDialogs["KILLLISTSTATS_NOTE"] = {
    text = "Kill List note for %s:",
    button1 = ACCEPT or "Accept",
    button2 = CANCEL or "Cancel",
    hasEditBox = 1,
    maxLetters = 200,
    editBoxWidth = 280,
    OnShow = function(dialog, data)
        local eb = PopupEditBox(dialog)
        if eb then eb:SetText(data and data.note or ""); eb:SetFocus() end
    end,
    OnAccept = function(dialog, data)
        local eb = PopupEditBox(dialog)
        if eb and data then ns:SetNote(data.key, eb:GetText()) end
    end,
    EditBoxOnEnterPressed = function(editBox, data)
        if data then ns:SetNote(data.key, editBox:GetText()) end
        editBox:GetParent():Hide()
    end,
    EditBoxOnEscapePressed = function(editBox) editBox:GetParent():Hide() end,
    timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
}

StaticPopupDialogs["KILLLISTSTATS_RESET"] = {
    text = "Delete ALL Kill List Stats data (kills, deaths, Kill List)? This cannot be undone.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function()
        ns:ResetData()
        ns.Print("All data deleted.")
    end,
    timeout = 0, whileDead = 1, hideOnEscape = 1, showAlert = 1, preferredIndex = 3,
}

function UI:EditNote(key)
    local p = ns.db.players[key]
    if not p then return end
    StaticPopup_Show("KILLLISTSTATS_NOTE", ns.DisplayName(p), nil, { key = key, note = p.list and p.list.note })
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local TAB_NAMES = { "Kills", "Deaths", "Kill List", "Classes", "Options" }
local FILTER_TABS = { [1] = true, [2] = true, [4] = true } -- tabs the filters apply to

local function MakeButton(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 120, 22)
    b:SetText(text)
    return b
end

-- Blizzard's "Filter" dropdown (with its reset X), or a plain button that opens
-- the same menu if that template is missing.
local function CreateFilterButton(parent)
    local function Generator(_, root) F.BuildMenu(root) end
    local ok, dd = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1FilterDropdownTemplate")
    if ok and dd and dd.SetupMenu then
        dd:SetupMenu(Generator)
        if dd.SetIsDefaultCallback then dd:SetIsDefaultCallback(function() return F.IsDefault() end) end
        if dd.SetDefaultCallback then dd:SetDefaultCallback(function() F.Reset() end) end
        return dd
    end
    local b = MakeButton(parent, "Filter", 90)
    b:SetScript("OnClick", function(btn)
        if MenuUtil and MenuUtil.CreateContextMenu then MenuUtil.CreateContextMenu(btn, Generator) end
    end)
    return b
end

function UI:Create()
    if self.frame then return self.frame end
    local f = CreateFrame("Frame", "KillListStatsFrame", UIParent, "ButtonFrameTemplate")
    self.frame = f
    ButtonFrameTemplate_HidePortrait(f)
    f:SetSize(960, 540)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        local point, _, relPoint, x, y = frame:GetPoint(1)
        ns.db.ui.pos = { point, relPoint, x, y }
    end)
    local pos = ns.db.ui.pos
    if pos then
        f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        f:SetPoint("CENTER")
    end
    if f.SetTitle then
        f:SetTitle("Kill List Stats")
    elseif f.TitleText then
        f.TitleText:SetText("Kill List Stats")
    end
    tinsert(UISpecialFrames, "KillListStatsFrame")
    if f.CloseButton then
        f.CloseButton:SetScript("OnClick", function() f:Hide() end)
    end
    f:HookScript("OnShow", function() UI:Refresh() end)
    f:Hide()

    -- Top bar: search, filters, view switch (Kills tab) and the filter status.
    local search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
    search:SetSize(170, 20)
    search:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -32)
    search:HookScript("OnTextChanged", function(box)
        UI.filter = strtrim(box:GetText() or ""):lower()
        UI:RequestRefresh()
    end)
    self.search = search

    local filterBtn = CreateFilterButton(f)
    filterBtn:SetPoint("LEFT", search, "RIGHT", 12, 0)
    self.filterButton = filterBtn

    self.killView = ns.db.ui.killView == "log" and "log" or "players"
    local viewBtn = MakeButton(f, "Show every kill", 128)
    viewBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 345, -31)
    viewBtn:SetScript("OnClick", function()
        UI.killView = UI.killView == "log" and "players" or "log"
        ns.db.ui.killView = UI.killView
        UI:SelectTab(1)
    end)
    viewBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_TOP")
        GameTooltip:SetText("Kills view", 1, 1, 1)
        GameTooltip:AddLine("By player: one row per player with your totals.", nil, nil, nil, true)
        GameTooltip:AddLine("Every kill: one row per kill, with who landed the killing blow and whether you were solo or grouped.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    viewBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.viewButton = viewBtn

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("LEFT", f, "TOPLEFT", 484, -42)
    status:SetPoint("RIGHT", f, "TOPRIGHT", -16, -42)
    status:SetJustifyH("RIGHT")
    status:SetWordWrap(false)
    self.status = status

    -- Pages (one per tab) inside the inset.
    local inset = f.Inset
    local saved = ns.db.ui.sort or {}
    ns.db.ui.sort = saved
    local function SortSaver(name)
        return function(key, asc) saved[name] = { key, asc } end
    end
    local function Saved(name, defKey, defAsc)
        local s = saved[name]
        if s then return s[1], s[2] end
        return defKey, defAsc
    end

    self.pages = {}
    local k1, a1 = Saved("kills", "total", false)
    self.pages[1] = CreateTable(inset, killColumns, k1, a1)
    self.pages[1].onSortChanged = SortSaver("kills")
    self.pages[1].onEnter = PlayerTooltip
    self.pages[1].build = BuildKills

    local kl, al = Saved("killlog", "time", false)
    self.killLog = CreateTable(inset, logColumns, kl, al)
    self.killLog.onSortChanged = SortSaver("killlog")
    self.killLog.onEnter = KillTooltip
    self.killLog.build = BuildKillLog

    local k2, a2 = Saved("deaths", "time", false)
    self.pages[2] = CreateTable(inset, deathColumns, k2, a2)
    self.pages[2].onSortChanged = SortSaver("deaths")
    self.pages[2].onEnter = DeathTooltip
    self.pages[2].build = BuildDeaths

    local k3, a3 = Saved("list", "deaths", false)
    self.pages[3] = CreateTable(inset, listColumns, k3, a3)
    self.pages[3].onSortChanged = SortSaver("list")
    self.pages[3].onEnter = PlayerTooltip
    self.pages[3].build = BuildKillList
    self.pages[3].emptyText = "Your Kill List is empty. Players who kill you in the world are added automatically."

    local k4, a4 = Saved("classes", "total", false)
    self.pages[4] = CreateTable(inset, classColumns, k4, a4)
    self.pages[4].onSortChanged = SortSaver("classes")
    self.pages[4].onEnter = ClassTooltip
    self.pages[4].build = BuildClasses

    self.pages[5] = self:CreateOptions(inset)

    -- Bottom bar: summary on the left, buttons on the right.
    local summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 10)
    summary:SetPoint("RIGHT", f, "BOTTOMRIGHT", -350, 10)
    summary:SetJustifyH("LEFT")
    summary:SetWordWrap(false)
    self.summary = summary

    local addBtn = MakeButton(f, "Add to Kill List", 130)
    addBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 4)
    addBtn:SetScript("OnClick", function() UI:AddSelectedToList() end)
    local removeBtn = MakeButton(f, "Remove", 100)
    removeBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 4)
    removeBtn:SetScript("OnClick", function() UI:RemoveSelectedFromList() end)
    local noteBtn = MakeButton(f, "Edit note", 100)
    noteBtn:SetPoint("RIGHT", removeBtn, "LEFT", -4, 0)
    noteBtn:SetScript("OnClick", function()
        local sel = UI.pages[3]:GetSelected()
        if sel then UI:EditNote(sel.key) else ns.Print("Select a player first.") end
    end)
    local targetBtn = MakeButton(f, "Add my target", 120)
    targetBtn:SetPoint("RIGHT", noteBtn, "LEFT", -4, 0)
    targetBtn:SetScript("OnClick", function() ns:AddTargetToList() end)
    self.buttons = { add = addBtn, remove = removeBtn, note = noteBtn, target = targetBtn }

    -- Tabs
    for i, name in ipairs(TAB_NAMES) do
        local tab = CreateFrame("Button", "KillListStatsFrameTab" .. i, f, "PanelTabButtonTemplate")
        tab:SetID(i)
        tab:SetText(name)
        tab:SetScript("OnClick", function(btn)
            UI:SelectTab(btn:GetID())
            PlaySound(SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB or 841)
        end)
        if i == 1 then tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, 2) end
    end
    PanelTemplates_SetNumTabs(f, #TAB_NAMES)
    self:SelectTab(ns.db.ui.tab or 1)
    return f
end

-- The table shown right now (the Kills tab has two views).
function UI:CurrentPage()
    if self.tab == 1 and self.killView == "log" then return self.killLog end
    return self.pages[self.tab]
end

function UI:SelectTab(id)
    id = math.max(1, math.min(id or 1, #TAB_NAMES))
    self.tab = id
    ns.db.ui.tab = id
    PanelTemplates_SetTab(self.frame, id)
    local current = self:CurrentPage()
    for _, page in ipairs(self.pages) do page:SetShown(page == current) end
    self.killLog:SetShown(self.killLog == current)
    local b = self.buttons
    b.add:SetShown(id == 1 or id == 2)
    b.add:SetText(id == 2 and "List the killer" or "Add to Kill List")
    b.remove:SetShown(id == 3)
    b.note:SetShown(id == 3)
    b.target:SetShown(id == 3)
    self.viewButton:SetShown(id == 1)
    self.viewButton:SetText(self.killView == "log" and "Show by player" or "Show every kill")
    self.filterButton:SetShown(FILTER_TABS[id] == true)
    self.search:SetShown(id ~= 5)
    self.status:SetShown(id ~= 5)
    self:Refresh()
end

function UI:OnFiltersChanged()
    if self.filterButton and self.filterButton.ValidateResetState then
        pcall(self.filterButton.ValidateResetState, self.filterButton)
    end
    self:Refresh()
end

function UI:UpdateSummary()
    local kw, kbg, kb, solo, deaths, victims, revenge, listed = 0, 0, 0, 0, 0, 0, 0, 0
    local stats, filtered = F.PlayerStats()
    for _, st in pairs(stats) do
        kw = kw + st.world
        kbg = kbg + st.bg
        kb = kb + st.kb
        solo = solo + st.solo
        deaths = deaths + st.deaths
        revenge = revenge + st.revenge
        if st.world + st.bg > 0 then victims = victims + 1 end
    end
    for _, p in pairs(ns.db.players) do
        if p.list then listed = listed + 1 end
    end
    local kills = kw + kbg
    local kd = deaths > 0 and string.format("%.2f", kills / deaths) or (kills > 0 and "perfect" or "-")
    self.summary:SetText(string.format(
        "%sKills %s%d|r (World %d / BG %d)   Your KB %d   Solo %d   Players %d   Deaths %s%d|r   K/D %s   Revenge %d   Kill List %d",
        filtered and (GOLD .. "Filtered|r  ") or "", GREEN, kills, kw, kbg, kb, solo, victims, RED, deaths, kd, revenge, listed))
end

function UI:UpdateStatus()
    local labels = F.ActiveLabels()
    if #labels == 0 or not FILTER_TABS[self.tab] then
        self.status:SetText(GREY .. "Click a column header to sort. Hover a row for details.|r")
        return
    end
    local text = GOLD .. "Filters:|r " .. table.concat(labels, ", ")
    if self.tab == 2 and F.KillsOnlyActive() then
        text = text .. GREY .. "  (killing blow and revenge filters only apply to kills)|r"
    end
    self.status:SetText(text)
end

function UI:Refresh()
    local f = self.frame
    if not f or not f:IsShown() then return end
    self:UpdateSummary()
    self:UpdateStatus()
    local page = self:CurrentPage()
    if page and page.build then
        if FILTER_TABS[self.tab] and not F.IsDefault() then
            page.empty:SetText("Nothing matches your filters. Use the Filter menu (or its X) to clear them.")
        else
            page.empty:SetText(page.emptyText or "Nothing here yet.")
        end
        page:SetData(page.build(self.filter))
    elseif page and page.Refresh then
        page:Refresh()
    end
end

function UI:RequestRefresh()
    if not self.frame or not self.frame:IsShown() or self.pending then return end
    self.pending = true
    C_Timer.After(0.1, function()
        self.pending = nil
        self:Refresh()
    end)
end

function UI:Toggle(tab)
    local f = self:Create()
    if tab then
        f:Show()
        self:SelectTab(tab)
    elseif f:IsShown() then
        f:Hide()
    else
        f:Show()
    end
end

function UI:AddSelectedToList()
    local page = self:CurrentPage()
    local sel = page and page:GetSelected()
    local key = sel and sel.key
    if not key then ns.Print("Select a player first.") return end
    local p = ns.db.players[key]
    if not p then return end
    local reason
    if sel.d then
        reason = string.format("Killed you at level %s in %s", tostring(sel.d.myLevel or "?"), sel.d.zone or "?")
    end
    if ns:AddToKillList(p, reason, false) then
        ns.Print(ns.ColoredName(p) .. " added to your Kill List.")
    else
        ns.Print(ns.ColoredName(p) .. " is already on your Kill List.")
    end
    ns:NotifyChanged()
end

function UI:RemoveSelectedFromList()
    local sel = self.pages[3]:GetSelected()
    if not sel then ns.Print("Select a player first.") return end
    local p = ns.db.players[sel.key]
    if p then
        ns:RemoveFromKillList(p)
        ns.Print(ns.ColoredName(p) .. " removed from your Kill List.")
    end
    self.pages[3].selectedId = nil
    ns:NotifyChanged()
end

---------------------------------------------------------------------------
-- Options page
---------------------------------------------------------------------------

local OPTIONS = {
    { "printKills", "Print a chat message when you kill a player" },
    { "countSharedKills", "Also count kills you helped with (your party, a totem, an NPC or the environment landed the killing blow)" },
    { "printDeaths", "Print who killed you (and why) when a player kills you" },
    { "tooltip", "Show your kill history in player tooltips" },
    { "alertKillList", "Warn me when a Kill List player is nearby (target, mouseover, nameplate)" },
    { "alertSound", "Play a sound with that warning" },
    { "autoListWorldKillers", "Automatically add players who kill me in the world to the Kill List" },
    { "autoListWorldAssists", "Also add players who assisted in killing me in the world" },
    { "autoListBGKillers", "Also add players who kill me in battlegrounds" },
    { "debug", "Debug messages (prints what the addon detects)" },
}

function UI:CreateOptions(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints(parent)
    page.checks = {}
    local y = -14
    for _, opt in ipairs(OPTIONS) do
        local key, label = opt[1], opt[2]
        local cb = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", page, "TOPLEFT", 16, y)
        cb:SetSize(26, 26)
        if cb.Text then
            cb.Text:SetFontObject("GameFontHighlight")
            cb.Text:SetText(label)
        end
        cb:SetScript("OnClick", function(btn)
            ns.db.settings[key] = btn:GetChecked() and true or false
        end)
        cb.key = key
        page.checks[#page.checks + 1] = cb
        y = y - 30
    end

    local windowLabel = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    windowLabel:SetPoint("TOPLEFT", page, "TOPLEFT", 22, y - 10)
    windowLabel:SetText("Assist window (seconds) - enemies targeting you this recently before you die get an assist:")
    local box = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
    box:SetSize(40, 20)
    box:SetPoint("LEFT", windowLabel, "RIGHT", 10, 0)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(3)
    local function Save(b)
        local n = tonumber(b:GetText())
        if n and n >= 3 and n <= 120 then ns.db.settings.assistWindow = n end
        b:SetText(tostring(ns.db.settings.assistWindow))
        b:ClearFocus()
    end
    box:SetScript("OnEnterPressed", Save)
    box:SetScript("OnEditFocusLost", Save)
    page.windowBox = box

    local reset = MakeButton(page, "Delete all data...", 160)
    reset:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 16, 14)
    reset:SetScript("OnClick", function() StaticPopup_Show("KILLLISTSTATS_RESET") end)

    local info = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    info:SetPoint("BOTTOMLEFT", reset, "TOPLEFT", 0, 12)
    info:SetPoint("RIGHT", page, "RIGHT", -16, 0)
    info:SetJustifyH("LEFT")
    info:SetText("Your own killing blows (and your pet's or totem's) always count as kills. A kill someone else finished counts when " ..
        "the game gave you an honorable kill, the player was fighting you (targeting you, or your target in combat), your party " ..
        "finished them while you were in combat in the world, or (solo) the damage meter shows your damage on them. " ..
        "Deaths use the game's death recap plus enemies seen targeting you. Inside battlegrounds the game hides enemy names " ..
        "until the match ends, so those kills are added then. Type /kls help for chat commands.")

    function page:Refresh()
        for _, cb in ipairs(self.checks) do cb:SetChecked(ns.db.settings[cb.key] and true or false) end
        self.windowBox:SetText(tostring(ns.db.settings.assistWindow))
    end
    return page
end

---------------------------------------------------------------------------
-- Addon compartment (the addon button next to the minimap)
---------------------------------------------------------------------------

function KillListStats_OnAddonCompartmentClick()
    UI:Toggle()
end

function KillListStats_OnAddonCompartmentEnter(_, button)
    GameTooltip:SetOwner(button or UIParent, "ANCHOR_LEFT")
    GameTooltip:SetText("Kill List Stats")
    GameTooltip:AddLine("Click to open your kill database.", 1, 1, 1)
    GameTooltip:Show()
end

function KillListStats_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
