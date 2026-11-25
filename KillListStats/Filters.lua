-- Kill List Stats - Filters
-- What the window shows: where (world / battlegrounds), your group, who landed
-- the killing blow, their level compared to yours, when, which character, and
-- revenge kills. Holds the filter state, the checks for kill and death log
-- entries, per-player totals rebuilt from the logs, and the filter menu.

local _, ns = ...
local F = {}
ns.Filters = F

F.DEFAULTS = {
    where = "all", group = "all", blow = "all", level = "all", time = "all",
    char = "all", revenge = false,
}

-- { value, menu label, short label for the status line }
F.MENU = {
    { key = "where", title = "Where", choices = {
        { "all", "Anywhere" },
        { "world", "World", "World" },
        { "bg", "Battlegrounds", "Battlegrounds" },
    } },
    { key = "group", title = "Your group", choices = {
        { "all", "Solo or grouped" },
        { "solo", "Solo", "Solo" },
        { "grouped", "In a party or raid", "Grouped" },
        { "party", "In a party", "In a party" },
        { "raid", "In a raid", "In a raid" },
    } },
    { key = "blow", title = "Killing blow", killsOnly = true, choices = {
        { "all", "Anyone" },
        { "mine", "You (or your pet / totem)", "Your killing blows" },
        { "notmine", "Anyone but you (you helped)", "Kills you helped with" },
        { "party", "Your party or raid", "Group killing blows" },
        { "team", "A battleground teammate", "Teammate killing blows" },
        { "other", "An NPC, a guard or the environment", "Finished by NPC/other" },
    } },
    { key = "level", title = "Their level", choices = {
        { "all", "Any level" },
        { "higher", "Higher than you (3+ levels)", "Higher level" },
        { "even", "Even fight (within 2 levels)", "Even fights" },
        { "lower", "Lower than you (3+ levels)", "Lower level" },
    } },
    { key = "time", title = "When", choices = {
        { "all", "All time" },
        { "today", "Today", "Today" },
        { "week", "Last 7 days", "Last 7 days" },
        { "month", "Last 30 days", "Last 30 days" },
    } },
}

F.PRESETS = {
    { label = "Solo killing blows", set = { group = "solo", blow = "mine" } },
    { label = "Kills with your group", set = { group = "grouped" } },
    { label = "Kills you only helped with", set = { blow = "notmine" } },
    { label = "Revenge kills", set = { revenge = true } },
    { label = "Even fights (within 2 levels)", set = { level = "even" } },
    { label = "Ganks (3+ levels below you)", set = { level = "lower" } },
    { label = "This week in the world", set = { where = "world", time = "week" } },
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

function F.State()
    local ui = ns.db.ui
    if type(ui.filters) ~= "table" then ui.filters = {} end
    local s = ui.filters
    for k, v in pairs(F.DEFAULTS) do
        if s[k] == nil then s[k] = v end
    end
    return s
end

function F.IsDefault()
    local s = F.State()
    for k, v in pairs(F.DEFAULTS) do
        if s[k] ~= v then return false end
    end
    return true
end

local function Changed()
    if ns.UI and ns.UI.OnFiltersChanged then ns.UI:OnFiltersChanged() end
end

function F.Set(key, value)
    F.State()[key] = value
    Changed()
end

function F.Reset()
    local s = F.State()
    for k, v in pairs(F.DEFAULTS) do s[k] = v end
    Changed()
end

function F.ApplyPreset(preset)
    local s = F.State()
    for k, v in pairs(F.DEFAULTS) do s[k] = v end
    for k, v in pairs(preset.set) do s[k] = v end
    Changed()
end

---------------------------------------------------------------------------
-- Checks
---------------------------------------------------------------------------

-- Earliest time() a "When" choice lets through.
local function TimeStart(mode)
    if mode == "today" then
        local d = date("*t", time())
        d.hour, d.min, d.sec = 0, 0, 0
        return time(d)
    end
    if mode == "week" then return time() - 7 * 86400 end
    if mode == "month" then return time() - 30 * 86400 end
end

-- "higher", "even" or "lower": their level compared to yours (nil when unknown).
function F.LevelBucket(level, skull, myLevel)
    if skull and not (level and level > 0) then return "higher" end
    if not (level and level > 0) or not myLevel then return nil end
    local d = level - myLevel
    if d >= 3 then return "higher" end
    if d <= -3 then return "lower" end
    return "even"
end

local function GroupOK(want, state)
    if want == "all" then return true end
    if want == "grouped" then return state ~= "solo" end
    return state == want
end

local function CommonOK(s, since, ctx, t, char)
    if s.where ~= "all" and (ctx or "world") ~= s.where then return false end
    if since and (t or 0) < since then return false end
    if s.char ~= "all" and char ~= s.char then return false end
    return true
end

-- Returns the filter state plus the start time, for the checks below.
function F.Begin()
    local s = F.State()
    return s, TimeStart(s.time)
end

-- Does a kill log entry pass the filters?
function F.Kill(e, s, since)
    if not s then s, since = F.Begin() end
    if not CommonOK(s, since, e.ctx, e.t, e.char) then return false end
    if not GroupOK(s.group, e.group or "solo") then return false end
    if s.blow ~= "all" then
        local kind = ns.BlowKind(e)
        if s.blow == "notmine" then
            if kind == "mine" then return false end
        elseif kind ~= s.blow then
            return false
        end
    end
    if s.level ~= "all" and F.LevelBucket(e.level, e.skull, e.myLevel) ~= s.level then return false end
    if s.revenge and not e.revenge then return false end
    return true
end

-- Does a death log entry pass the filters? (Killing blow and revenge only apply to kills.)
function F.Death(d, s, since)
    if not s then s, since = F.Begin() end
    if not CommonOK(s, since, d.ctx, d.t, d.char) then return false end
    if not GroupOK(s.group, (ns.DeathGroup(d))) then return false end
    if s.level ~= "all" and F.LevelBucket(d.killerLevel, d.killerSkull, d.myLevel) ~= s.level then return false end
    return true
end

-- Per-player numbers: key -> { world, bg, kb, solo, deaths, assists, revenge, last }.
-- Without filters they come from the player records (never trimmed); with
-- filters they are counted again from the kill and death logs.
function F.PlayerStats()
    local out = {}
    if F.IsDefault() then
        for key, p in pairs(ns.db.players) do
            local n = ns.Total(p.kills)
            out[key] = {
                world = p.kills.world or 0, bg = p.kills.bg or 0,
                kb = p.kb or n, solo = p.solo or n,
                deaths = ns.Total(p.deaths), assists = ns.Total(p.assists),
                revenge = p.revenge or 0, last = p.lastKill,
            }
        end
        return out, false
    end
    local function Get(key)
        local r = out[key]
        if not r then
            r = { world = 0, bg = 0, kb = 0, solo = 0, deaths = 0, assists = 0, revenge = 0 }
            out[key] = r
        end
        return r
    end
    local s, since = F.Begin()
    for _, e in ipairs(ns.db.kills) do
        if e.key and F.Kill(e, s, since) then
            local r = Get(e.key)
            if e.ctx == "bg" then r.bg = r.bg + 1 else r.world = r.world + 1 end
            if ns.IsOwnBlow(e) then r.kb = r.kb + 1 end
            if (e.group or "solo") == "solo" then r.solo = r.solo + 1 end
            if e.revenge then r.revenge = r.revenge + 1 end
            if not r.last or (e.t or 0) > r.last then r.last = e.t end
        end
    end
    for _, d in ipairs(ns.db.deaths) do
        if F.Death(d, s, since) then
            if d.killer then
                local r = Get(d.killer)
                r.deaths = r.deaths + 1
            end
            for _, a in ipairs(d.assists or {}) do
                if a.key then
                    local r = Get(a.key)
                    r.assists = r.assists + 1
                end
            end
        end
    end
    return out, true
end

---------------------------------------------------------------------------
-- Labels
---------------------------------------------------------------------------

function F.CharName(key)
    if not key then return "?" end
    local name, realm = ns.SplitName(key)
    if realm and realm ~= ns.MyRealm() then return name .. "-" .. realm end
    return name
end

-- Your characters that appear in the logs.
function F.Characters()
    local seen, list = {}, {}
    local function Add(c)
        if c and not seen[c] then seen[c] = true; list[#list + 1] = c end
    end
    for _, e in ipairs(ns.db.kills) do Add(e.char) end
    for _, d in ipairs(ns.db.deaths) do Add(d.char) end
    Add(ns.myKey)
    table.sort(list)
    return list
end

local function ChoiceLabel(opt, value, short)
    for _, ch in ipairs(opt.choices) do
        if ch[1] == value then return short and ch[3] or ch[2] end
    end
    return tostring(value)
end

-- Short names of the active filters, for the status line.
function F.ActiveLabels()
    local s, out = F.State(), {}
    for _, opt in ipairs(F.MENU) do
        if s[opt.key] ~= "all" then out[#out + 1] = ChoiceLabel(opt, s[opt.key], true) end
    end
    if s.char ~= "all" then out[#out + 1] = F.CharName(s.char) .. " only" end
    if s.revenge then out[#out + 1] = "Revenge kills" end
    return out
end

-- Are any filters active that only apply to kills (not deaths)?
function F.KillsOnlyActive()
    local s = F.State()
    return s.blow ~= "all" or s.revenge
end

---------------------------------------------------------------------------
-- Menu (Blizzard's dropdown menu system)
---------------------------------------------------------------------------

local function KeepOpen() return MenuResponse and MenuResponse.Refresh end

function F.BuildMenu(root)
    local s = F.State()
    root:CreateTitle("Quick picks")
    for _, preset in ipairs(F.PRESETS) do
        root:CreateButton(preset.label, function() F.ApplyPreset(preset) end)
    end
    root:CreateDivider()
    root:CreateTitle("Filters")
    for _, opt in ipairs(F.MENU) do
        local title = opt.title
        if s[opt.key] ~= "all" then
            title = title .. ": |cffffd100" .. ChoiceLabel(opt, s[opt.key], true) .. "|r"
        end
        local sub = root:CreateButton(title)
        if opt.killsOnly then sub:CreateTitle("Applies to kills only") end
        for _, ch in ipairs(opt.choices) do
            local value = ch[1]
            sub:CreateRadio(ch[2],
                function() return F.State()[opt.key] == value end,
                function() F.Set(opt.key, value); return KeepOpen() end,
                value)
        end
    end
    local chars = F.Characters()
    if #chars > 1 or s.char ~= "all" then
        local title = "Character"
        if s.char ~= "all" then title = title .. ": |cffffd100" .. F.CharName(s.char) .. "|r" end
        local sub = root:CreateButton(title)
        sub:CreateRadio("All characters", function() return F.State().char == "all" end,
            function() F.Set("char", "all"); return KeepOpen() end, "all")
        for _, c in ipairs(chars) do
            sub:CreateRadio(F.CharName(c), function() return F.State().char == c end,
                function() F.Set("char", c); return KeepOpen() end, c)
        end
    end
    root:CreateCheckbox("Revenge kills only", function() return F.State().revenge end,
        function() F.Set("revenge", not F.State().revenge) end)
    root:CreateDivider()
    root:CreateButton("Clear all filters", function() F.Reset() end)
end
