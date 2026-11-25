-- Kill List Stats - Core
-- Saved data, player records, secret-value safety and formatting helpers.
--
-- WoW Forever runs on the Midnight client, which means:
--   * COMBAT_LOG_EVENT_UNFILTERED cannot be used by addons (registering it errors).
--   * Many API values can be "secret" (opaque to addon code). Comparing,
--     indexing with, or doing arithmetic on a secret raises a Lua error, so every
--     value coming from the game API passes through ns.Plain() first.

local ADDON_NAME, ns = ...
KillListStats = ns

ns.name = ADDON_NAME
ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")) or "1.0.0"

ns.DEFAULT_SETTINGS = {
    printKills = true,            -- chat line when you kill a player
    printDeaths = true,           -- chat line when a player kills you
    tooltip = true,               -- add stats to player tooltips
    alertKillList = true,         -- warn when a Kill List player shows up
    alertSound = true,            -- play a sound with that warning
    autoListWorldKillers = true,  -- world killers go on the Kill List
    autoListWorldAssists = false, -- world assisters go on the Kill List too
    autoListBGKillers = false,    -- battleground killers go on the Kill List
    assistWindow = 15,            -- seconds: enemies targeting you this recently get an assist
    countSharedKills = true,      -- also count kills your group, a totem, an NPC or the environment finished
    logLimit = 3000,              -- max entries kept in each history log
    debug = false,
}

---------------------------------------------------------------------------
-- Secret-value helpers
---------------------------------------------------------------------------

local issecretvalue = issecretvalue

-- Returns v, or nil when v is a secret value addon code cannot use.
function ns.Plain(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end
local Plain = ns.Plain

function ns.PlainString(v)
    v = Plain(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

function ns.PlainNumber(v)
    v = Plain(v)
    if type(v) == "number" then return v end
    return nil
end

-- Calls fn safely and returns its results only if the call succeeded.
function ns.Try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local results = { pcall(fn, ...) }
    if not results[1] then return nil end
    return unpack(results, 2, table.maxn(results))
end

function ns.IsPlayerGUID(guid)
    guid = ns.PlainString(guid)
    return guid ~= nil and guid:find("^Player%-") ~= nil
end

---------------------------------------------------------------------------
-- Names / realms
---------------------------------------------------------------------------

function ns.MyRealm()
    if not ns.myRealm then
        local realm = ns.Try(GetNormalizedRealmName) or ns.Try(GetRealmName) or "Unknown"
        ns.myRealm = (realm:gsub("[%s%-]", ""))
    end
    return ns.myRealm
end

function ns.NormRealm(realm)
    realm = ns.PlainString(realm)
    if not realm then return ns.MyRealm() end
    return (realm:gsub("[%s%-]", ""))
end

function ns.MakeKey(name, realm)
    return name .. "-" .. ns.NormRealm(realm)
end

-- "Name-Realm" -> "Name", "Realm"   |   "Name" -> "Name", nil
function ns.SplitName(full)
    local name, realm = full:match("^([^%-]+)%-(.+)$")
    if name then return name, realm end
    return full, nil
end

function ns.KeyFromFullName(full)
    full = ns.PlainString(full)
    if not full then return nil end
    local name, realm = ns.SplitName(full)
    return ns.MakeKey(name, realm), name, ns.NormRealm(realm)
end

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------

local function CopyDefaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            if type(v) == "table" then
                dst[k] = CopyDefaults({}, v)
            else
                dst[k] = v
            end
        end
    end
    return dst
end

ns.DB_VERSION = 2

function ns:InitDB()
    KillListStatsDB = KillListStatsDB or {}
    local db = KillListStatsDB
    db.players = db.players or {}   -- "Name-Realm" -> player record
    db.guids = db.guids or {}       -- player GUID -> "Name-Realm"
    db.deaths = db.deaths or {}     -- PvP death log (oldest first)
    db.kills = db.kills or {}       -- kill log (oldest first)
    db.unresolved = db.unresolved or {} -- kills whose victim's name was hidden (battlegrounds)
    db.settings = CopyDefaults(db.settings or {}, ns.DEFAULT_SETTINGS)
    db.ui = db.ui or {}
    self:Migrate(db)
    self.db = db
end

-- Upgrades saved data from older versions.
function ns:Migrate(db)
    local version = db.version or (next(db.players) and 1 or ns.DB_VERSION)
    if version < 2 then
        -- Version 1 only counted your own killing blows and did not record your
        -- group, so every old kill is your killing blow (or your pet's), solo.
        for _, k in ipairs(db.kills or {}) do
            if not k.blow then k.blow = k.pet and "pet" or "me" end
            if not k.group then k.group, k.gsize = "solo", 1 end
            if not k.how then k.how = "kb" end
        end
        for _, p in pairs(db.players or {}) do
            local n = ns.Total(p.kills)
            if p.kb == nil then p.kb = n end
            if p.solo == nil then p.solo = n end
        end
    end
    db.version = ns.DB_VERSION
end

function ns:ResetData()
    local db = self.db
    wipe(db.players)
    wipe(db.guids)
    wipe(db.deaths)
    wipe(db.kills)
    wipe(db.unresolved)
    self:NotifyChanged()
end

local function TrimLog(log, limit)
    local extra = #log - (limit or 3000)
    if extra > 0 then
        for _ = 1, extra do table.remove(log, 1) end
    end
end

function ns:AppendLog(log, entry)
    log[#log + 1] = entry
    TrimLog(log, self.db.settings.logLimit)
end

---------------------------------------------------------------------------
-- Player records
---------------------------------------------------------------------------

local function Counter() return { world = 0, bg = 0 } end

function ns.Total(c)
    if not c then return 0 end
    return (c.world or 0) + (c.bg or 0)
end

function ns:GetPlayer(key, create, name, realm)
    local p = self.db.players[key]
    if not p and create then
        if not name then name, realm = ns.SplitName(key) end
        p = {
            name = name,
            realm = realm or ns.MyRealm(),
            kills = Counter(),    -- your kills on them (any killing blow, see p.kb)
            kb = 0,               -- of those: killing blows by you, your pet or your totem
            solo = 0,             -- of those: kills while you were not in a party or raid
            deaths = Counter(),   -- their killing blows on you
            assists = Counter(),  -- times they helped kill you
            revenge = 0,          -- kills on them while they were on your Kill List
            firstSeen = time(),
        }
        self.db.players[key] = p
    end
    return p
end

function ns:FindPlayerByGUID(guid)
    guid = ns.PlainString(guid)
    if not guid then return nil end
    local key = self.db.guids[guid]
    return key and self.db.players[key], key
end

-- Exact "Name-Realm" match first, then a unique match on the name alone.
function ns:FindPlayerByName(text)
    if not text or text == "" then return nil end
    local name, realm = ns.SplitName(text)
    local key = ns.MakeKey(name, realm)
    if self.db.players[key] then return self.db.players[key], key end
    local lname = name:lower()
    local foundKey
    for k, p in pairs(self.db.players) do
        if p.name and p.name:lower() == lname then
            if foundKey then return nil end -- ambiguous
            foundKey = k
        end
    end
    if foundKey then return self.db.players[foundKey], foundKey end
end

-- Copy what we know about a player (from a unit, GUID or death recap) into their record.
function ns:ApplyInfo(p, info)
    if not info then return end
    if info.guid then
        p.guid = info.guid
        if info.key then self.db.guids[info.guid] = info.key end
    end
    if info.class then p.class = info.class end
    if info.race then p.race = info.race end
    if info.level and info.level > 0 then
        p.level = info.level
        p.levelSeen = time()
    end
    if info.guild then p.guild = info.guild end
end

---------------------------------------------------------------------------
-- Session cache of enemy players we have seen (not saved)
---------------------------------------------------------------------------

ns.seen = {}       -- GUID -> info
ns.seenByKey = {}  -- "Name-Realm" -> info

function ns:Remember(info)
    if info.guid then self.seen[info.guid] = info end
    if info.key then self.seenByKey[info.key] = info end
end

local function CopyInfo(src)
    local t = {}
    for k, v in pairs(src) do t[k] = v end
    return t
end

-- Builds an info table for a player GUID: name, realm, key, class, race, level.
function ns:InfoFromGUID(guid)
    guid = ns.PlainString(guid)
    if not guid or not guid:find("^Player%-") then return nil end

    local info
    local _, class, race, _, _, name, realm, level = ns.Try(GetPlayerInfoByGUID, guid)
    name = ns.PlainString(name)
    if name then
        realm = ns.NormRealm(realm)
        info = {
            guid = guid,
            name = name,
            realm = realm,
            key = name .. "-" .. realm,
            class = ns.PlainString(class),
            race = ns.PlainString(race),
        }
        level = ns.PlainNumber(level)
        if level and level > 0 then info.level = level end
    end

    local cached = self.seen[guid]
    if cached then
        if not info then
            info = CopyInfo(cached)
        else
            info.class = info.class or cached.class
            info.guild = cached.guild
            info.skull = cached.skull
            if not info.level then info.level = cached.level end
        end
    end
    return info
end

-- Reads an enemy player unit. Returns info (and their saved record, if any).
function ns:ObserveUnit(unit)
    if not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
    local hostile = Plain(UnitIsEnemy("player", unit)) or Plain(UnitCanAttack("player", unit))
    if not hostile then return nil end

    local guid = ns.PlainString(ns.Try(UnitGUID, unit))
    local info = guid and self:InfoFromGUID(guid)
    if not info then
        local name, realm = ns.Try(UnitName, unit)
        name = ns.PlainString(name)
        if not name then return nil end -- name hidden (e.g. inside an active PvP match)
        realm = ns.NormRealm(realm)
        info = { guid = guid, name = name, realm = realm, key = name .. "-" .. realm }
    end

    local _, class = ns.Try(UnitClass, unit)
    info.class = ns.PlainString(class) or info.class
    local race = ns.Try(UnitRace, unit)
    info.race = ns.PlainString(race) or info.race
    local level = ns.PlainNumber(ns.Try(UnitLevel, unit))
    if level then
        if level > 0 then
            info.level, info.skull = level, nil
        else
            info.skull = true -- shown as "??": 10+ levels above you
        end
    end
    info.guild = ns.PlainString(ns.Try(GetGuildInfo, unit)) or info.guild
    info.seenAt = GetTime()
    self:Remember(info)

    local p = self.db.players[info.key]
    if p then
        self:ApplyInfo(p, info)
        p.lastSeen = time()
        p.lastSeenZone = ns.PlainString(GetRealZoneText())
    end
    return info, p
end

---------------------------------------------------------------------------
-- Kill List
---------------------------------------------------------------------------

function ns:AddToKillList(p, reason, auto)
    if not p.list then
        p.list = { added = time(), auto = auto or nil, reason = reason }
        return true
    end
    if reason then p.list.reason = reason end
    return false
end

function ns:RemoveFromKillList(p)
    p.list = nil
end

function ns:SetNote(key, note)
    local p = self.db.players[key]
    if not p then return end
    if not p.list then self:AddToKillList(p, nil, false) end
    note = note and strtrim(note) or ""
    p.list.note = (note ~= "") and note or nil
    self:NotifyChanged()
end

---------------------------------------------------------------------------
-- Context
---------------------------------------------------------------------------

-- "bg" inside battlegrounds/arenas, otherwise "world".
function ns.GetContext()
    local _, instanceType = IsInInstance()
    instanceType = ns.PlainString(instanceType)
    if instanceType == "pvp" or instanceType == "arena" then
        return "bg", instanceType
    end
    return "world", instanceType
end

ns.HOME_GROUP = LE_PARTY_CATEGORY_HOME or 1         -- the party/raid you formed yourself
ns.INSTANCE_GROUP = LE_PARTY_CATEGORY_INSTANCE or 2 -- the raid a battleground puts you in

-- Your own group: "solo", "party" or "raid", and its size. A battleground raid
-- you were put into does not count; only a party you formed (or queued with) does.
function ns.GroupState()
    if not ns.Plain(ns.Try(IsInGroup, ns.HOME_GROUP)) then return "solo", 1 end
    local n = ns.PlainNumber(ns.Try(GetNumGroupMembers, ns.HOME_GROUP)) or 2
    if ns.Plain(ns.Try(IsInRaid, ns.HOME_GROUP)) then return "raid", math.max(n, 2) end
    return "party", math.max(n, 2)
end

-- Your group when you died. Deaths saved before version 2 only stored a group
-- size, which inside battlegrounds is the battleground raid, so those count as solo.
function ns.DeathGroup(d)
    if d.party then return d.party, d.psize or 1 end
    local n = d.group or 1
    if d.ctx == "world" and n > 1 then return n > 5 and "raid" or "party", n end
    return "solo", 1
end

-- Kill log entries: who landed the killing blow.
--   "me", "pet"      you or your pet
--   "summon"         a totem/guardian (yours when solo, someone in your group's otherwise)
--   "party", "team"  someone in your own group / a battleground teammate (e.blowBy = name)
--   "other"          nobody in your group: an NPC, a guard, the environment
function ns.BlowKind(e)
    local b = e.blow or (e.pet and "pet") or "me"
    if b == "me" or b == "pet" or (b == "summon" and (e.group or "solo") == "solo") then return "mine" end
    if b == "summon" then return "party" end
    return b
end

function ns.IsOwnBlow(e) return ns.BlowKind(e) == "mine" end

function ns.BlowText(e)
    local b = e.blow or (e.pet and "pet") or "me"
    if b == "me" then return "You" end
    if b == "pet" then return "Your pet" end
    if b == "summon" then
        return (e.group or "solo") == "solo" and "Your totem/summon" or "A group summon"
    end
    if b == "party" or b == "team" then
        local who = e.blowBy or (b == "party" and "Group member" or "Teammate")
        if e.blowPet then who = who .. "'s pet" end
        local tag = b == "team" and "team" or (e.group == "raid" and "raid" or "party")
        return who .. " (" .. tag .. ")"
    end
    return "NPC / other"
end

local BLOW_COLORS = { mine = "|cff40ff40", party = "|cffffd100", team = "|cff60a0ff", other = "|cffaaaaaa" }
function ns.ColoredBlow(e)
    return (BLOW_COLORS[ns.BlowKind(e)] or "") .. ns.BlowText(e) .. "|r"
end

function ns.GroupText(state, size)
    if state == "party" then return "Party of " .. (size or 2) end
    if state == "raid" then return "Raid of " .. (size or 2) end
    return "Solo"
end

-- Why a kill counted, from a kill log entry's "how" field.
local HOW_TEXT = {
    kb = "killing-blow event",
    honor = "honorable kill",
    fought = "you were fighting them",
    meter = "your damage (damage meter)",
    died = "saw them die",
}
function ns.HowText(how)
    local parts = {}
    for code in tostring(how or "kb"):gmatch("[^,]+") do
        parts[#parts + 1] = HOW_TEXT[code] or code
    end
    return table.concat(parts, ", ")
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

local CHAT_PREFIX = "|cffff4040Kill List|r |cffffd100Stats|r: "

function ns.Print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    DEFAULT_CHAT_FRAME:AddMessage(CHAT_PREFIX .. table.concat(parts, " "))
end

function ns.Debug(...)
    if ns.db and ns.db.settings.debug then
        ns.Print("|cff888888[debug]|r", ...)
    end
end

function ns.ClassColorHex(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then
        if c.colorStr then return c.colorStr end
        return string.format("ff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
    return "ffbbbbbb"
end

function ns.ClassName(class)
    if not class then return "Unknown" end
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class])
        or (class:sub(1, 1) .. class:sub(2):lower())
end

function ns.ClassIcon(class, size)
    local coords = class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if not coords then return "" end
    size = size or 14
    return string.format("|TInterface\\WorldStateFrame\\Icons-Classes:%d:%d:0:0:256:256:%d:%d:%d:%d|t",
        size, size, coords[1] * 256, coords[2] * 256, coords[3] * 256, coords[4] * 256)
end

function ns.DisplayName(p)
    if not p then return "?" end
    local name = p.name or "?"
    if p.realm and p.realm ~= ns.MyRealm() then name = name .. "-" .. p.realm end
    return name
end

function ns.ColoredName(p)
    return "|c" .. ns.ClassColorHex(p and p.class) .. ns.DisplayName(p) .. "|r"
end

function ns.FormatLevel(level, skull)
    if level and level > 0 then return tostring(level) end
    if skull then return "??" end
    return "?"
end

-- Level text colored relative to your own level.
function ns.ColoredLevel(level, skull, myLevel)
    local text = ns.FormatLevel(level, skull)
    if skull and not (level and level > 0) then return "|cffff2020" .. text .. "|r" end
    if not (level and level > 0) or not myLevel then return text end
    local d = level - myLevel
    local color = (d >= 5 and "ff2020") or (d >= 3 and "ff8040") or (d >= -2 and "ffff00") or (d >= -8 and "40c040") or "909090"
    return "|cff" .. color .. text .. "|r"
end

-- Health percent text: red when low, orange when hurt.
function ns.ColoredPct(pct)
    if not pct then return "|cff808080?|r" end
    local color = (pct < 35 and "ff2020") or (pct < 70 and "ff9933") or "ffffff"
    return string.format("|cff%s%d%%|r", color, pct)
end

function ns.FormatAgo(t)
    if not t then return "never" end
    local d = time() - t
    if d < 60 then return "just now" end
    if d < 3600 then return string.format("%dm ago", d / 60) end
    if d < 86400 then return string.format("%dh ago", d / 3600) end
    if d < 86400 * 60 then return string.format("%dd ago", d / 86400) end
    return date("%Y-%m-%d", t)
end

function ns.FormatDate(t)
    return t and date("%Y-%m-%d %H:%M", t) or "?"
end

-- Plural(1, "time") -> "1 time", Plural(3, "time") -> "3 times"
function ns.Plural(n, word)
    return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

function ns.Ordinal(n)
    local s = "th"
    local m100 = n % 100
    if m100 < 11 or m100 > 13 then
        local m10 = n % 10
        s = (m10 == 1 and "st") or (m10 == 2 and "nd") or (m10 == 3 and "rd") or "th"
    end
    return n .. s
end

---------------------------------------------------------------------------
-- Change notification (refreshes the window when data changes)
---------------------------------------------------------------------------

function ns:NotifyChanged()
    if self.UI and self.UI.RequestRefresh then self.UI:RequestRefresh() end
end
