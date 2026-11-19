-- Kill List Stats - Slash commands

local _, ns = ...

local GREEN, RED, GREY = "|cff40ff40", "|cffff4040", "|cffaaaaaa"

function ns:AddTargetToList(note)
    local info = ns.Try(ns.ObserveUnit, ns, "target")
    if not info then
        ns.Print("Target an enemy player first (their name must be visible to addons).")
        return
    end
    local p = self:GetPlayer(info.key, true, info.name, info.realm)
    self:ApplyInfo(p, info)
    p.lastSeen = time()
    p.lastSeenZone = ns.PlainString(GetRealZoneText())
    local added = self:AddToKillList(p, "Added manually", false)
    if note and note ~= "" then p.list.note = note end
    ns.Print(ns.ColoredName(p) .. (added and " added to your Kill List." or " is already on your Kill List."))
    self:NotifyChanged()
end

local function PrintPlayer(p)
    ns.Print(string.format("%s - level %s %s%s", ns.ColoredName(p), ns.FormatLevel(p.level), ns.ClassName(p.class),
        p.guild and (" <" .. p.guild .. ">") or ""))
    ns.Print(string.format("  You killed them %s%s|r (%d world, %d BG), last %s",
        GREEN, ns.Plural(ns.Total(p.kills), "time"), p.kills.world or 0, p.kills.bg or 0, ns.FormatAgo(p.lastKill)))
    ns.Print(string.format("  They killed you %s%s|r (%d world, %d BG), assisted %s",
        RED, ns.Plural(ns.Total(p.deaths), "time"), p.deaths.world or 0, p.deaths.bg or 0, ns.Plural(ns.Total(p.assists), "time")))
    if p.lastDeathText then ns.Print("  Last time: " .. GREY .. p.lastDeathText .. "|r") end
    if p.list then
        ns.Print("  On your Kill List: " .. (p.list.note or p.list.reason or "yes") ..
            ((p.revenge or 0) > 0 and (" (" .. ns.Plural(p.revenge, "revenge kill") .. ")") or ""))
    end
end

local function PrintSummary()
    local kw, kb, deaths, victims, listed = 0, 0, 0, 0, 0
    for _, p in pairs(ns.db.players) do
        kw = kw + (p.kills.world or 0)
        kb = kb + (p.kills.bg or 0)
        deaths = deaths + ns.Total(p.deaths)
        if ns.Total(p.kills) > 0 then victims = victims + 1 end
        if p.list then listed = listed + 1 end
    end
    ns.Print(string.format("Kills %s%d|r (world %d, BG %d) on %d different players. Killed by players %s%d|r times. Kill List: %d.",
        GREEN, kw + kb, kw, kb, victims, RED, deaths, listed))
end

local function PrintTop(field, label, n)
    local rows = {}
    for _, p in pairs(ns.db.players) do
        local v = ns.Total(p[field])
        if v > 0 then rows[#rows + 1] = { p = p, v = v } end
    end
    table.sort(rows, function(a, b) return a.v > b.v end)
    if #rows == 0 then ns.Print("No data yet.") return end
    ns.Print(label)
    for i = 1, math.min(n, #rows) do
        local r = rows[i]
        ns.Print(string.format("  %d. %s (%s %s) - %d", i, ns.ColoredName(r.p), ns.FormatLevel(r.p.level), ns.ClassName(r.p.class), r.v))
    end
end

local function SafeString(v)
    if issecretvalue and issecretvalue(v) then return "<secret>" end
    if type(v) == "table" then return "<table>" end
    return tostring(v)
end

local function DumpRecap()
    local events = ns:ReadRecap() or ns.lastRecapRaw
    if not events then ns.Print("No death recap available.") return end
    ns.Print(string.format("Death recap: %d entries (entry 1 = killing blow)", #events))
    for i = 1, math.min(#events, 3) do
        local e = events[i]
        local parts = {}
        if type(e) == "table" then
            for k, v in pairs(e) do parts[#parts + 1] = tostring(k) .. "=" .. SafeString(v) end
            table.sort(parts)
        end
        ns.Print(string.format("  [%d] %s", i, table.concat(parts, ", ")))
    end
end

local function Help()
    ns.Print("commands (/kls or /killlist):")
    local lines = {
        "/kls - open or close the window",
        "/kls kills | deaths | list | classes | options - open a tab",
        "/kls stats - short summary in chat",
        "/kls who <name> - your history with a player",
        "/kls top - players you killed most     /kls nemesis - players who killed you most",
        "/kls add [name] [note] - add a player (or your target) to the Kill List",
        "/kls remove <name> - remove a player from the Kill List",
        "/kls note <name> <text> - set a Kill List note",
        "/kls window <seconds> - assist window (default 15)",
        "/kls debug - toggle debug messages     /kls recap - show raw death recap data",
        "/kls reset - delete all data",
    }
    for _, l in ipairs(lines) do ns.Print("  " .. l) end
end

local TABS = { kills = 1, deaths = 2, list = 3, killlist = 3, kos = 3, classes = 4, class = 4, options = 5, config = 5, settings = 5 }

SLASH_KILLLISTSTATS1 = "/kls"
SLASH_KILLLISTSTATS2 = "/killlist"
SlashCmdList.KILLLISTSTATS = function(msg)
    if not ns.db then return end
    msg = strtrim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" or cmd == "show" then
        ns.UI:Toggle()
    elseif TABS[cmd] then
        ns.UI:Toggle(TABS[cmd])
    elseif cmd == "help" or cmd == "?" then
        Help()
    elseif cmd == "stats" then
        PrintSummary()
    elseif cmd == "who" or cmd == "lookup" then
        local p = ns:FindPlayerByName(rest)
        if p then PrintPlayer(p) else ns.Print("No record for '" .. rest .. "'.") end
    elseif cmd == "top" then
        PrintTop("kills", "Players you killed most:", tonumber(rest) or 10)
    elseif cmd == "nemesis" then
        PrintTop("deaths", "Players who killed you most:", tonumber(rest) or 10)
    elseif cmd == "add" then
        local name, note = rest:match("^(%S*)%s*(.-)$")
        if not name or name == "" then
            ns:AddTargetToList()
            return
        end
        local p, key = ns:FindPlayerByName(name)
        if not p then
            local n, realm = ns.SplitName(name)
            n = n:sub(1, 1):upper() .. n:sub(2):lower()
            key = ns.MakeKey(n, realm)
            p = ns:GetPlayer(key, true, n, ns.NormRealm(realm))
        end
        local added = ns:AddToKillList(p, "Added manually", false)
        if note ~= "" then p.list.note = note end
        ns.Print(ns.ColoredName(p) .. (added and " added to your Kill List." or " is already on your Kill List."))
        ns:NotifyChanged()
    elseif cmd == "remove" or cmd == "del" then
        local p = ns:FindPlayerByName(rest)
        if p and p.list then
            ns:RemoveFromKillList(p)
            ns.Print(ns.ColoredName(p) .. " removed from your Kill List.")
            ns:NotifyChanged()
        else
            ns.Print("'" .. rest .. "' is not on your Kill List.")
        end
    elseif cmd == "note" then
        local name, note = rest:match("^(%S+)%s*(.-)$")
        local p, key = ns:FindPlayerByName(name or "")
        if not p then ns.Print("No record for '" .. (name or "") .. "'.") return end
        ns:SetNote(key, note)
        ns.Print("Note saved for " .. ns.ColoredName(p) .. ".")
    elseif cmd == "window" then
        local n = tonumber(rest)
        if n and n >= 3 and n <= 120 then
            ns.db.settings.assistWindow = n
            ns.Print("Assist window set to " .. n .. " seconds.")
        else
            ns.Print("Usage: /kls window <3-120>  (currently " .. ns.db.settings.assistWindow .. ")")
        end
    elseif cmd == "debug" then
        ns.db.settings.debug = not ns.db.settings.debug
        ns.Print("Debug " .. (ns.db.settings.debug and "on" or "off") .. ".")
    elseif cmd == "recap" then
        DumpRecap()
    elseif cmd == "reset" then
        StaticPopup_Show("KILLLISTSTATS_RESET")
    else
        Help()
    end
end
