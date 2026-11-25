-- Kill List Stats - Kill detection
--
-- WoW Forever hides the combat log from addons, so a kill is pieced together
-- from several signals about the same victim, gathered for a moment and then
-- combined into one decision:
--
--   PARTY_KILL (attacker, victim)  killing blows by you, your pet/totems or your group
--   UNIT_DIED (victim)             a nearby enemy player died. Catches kills that an NPC,
--                                  a guard or the environment finished.
--   honorable kill                 the "X dies, honorable kill" chat line, and the
--                                  honorable-kill counter going up
--   fought                         they targeted you, or you had them targeted in combat
--   damage meter                   after combat: the enemy took damage from you (solo only)
--
-- Your own killing blows always count. Other kills count when there is proof
-- you took part in them (see Decide).

local _, ns = ...
local Plain, PlainString, PlainNumber, Try = ns.Plain, ns.PlainString, ns.PlainNumber, ns.Try

local frame = CreateFrame("Frame")
ns.killFrame = frame

local WAIT = 1.5          -- seconds to gather signals about one death
local RECENT = 4          -- a victim recorded this recently is not counted again
local FOUGHT_WINDOW = 30  -- "you fought them" if they were on you this recently
local METER_WAIT = 120    -- longest a kill waits for combat to end to check the damage meter
local UNRESOLVED_KEEP = 6 * 3600 -- seconds to keep trying to learn a hidden victim's name

local pending = {}      -- id (victim GUID, or "name:Key") -> kill being gathered
local waitingMeter = {} -- id -> kill waiting for the damage meter
local fought = {}       -- victim GUID -> GetTime() they last fought you
local recorded = {}     -- victim GUID or key -> GetTime() it was counted
local ownRecent = {}    -- GetTime() of your own killing blows that may still get an honor tick
local hkCredit          -- honorable kills the counter reported before their death showed up
local lastHK
local inCombat, lastCombatEnd

ns.killPending = pending -- for /kls debug and tests

local function Recent(id)
    local t = id and recorded[id]
    return t ~= nil and GetTime() - t < RECENT
end

local function MyGUID() return PlainString(UnitGUID("player")) end

local function IsBusy(at)
    at = at or GetTime()
    return inCombat or Plain(Try(UnitAffectingCombat, "player")) == true
        or (lastCombatEnd ~= nil and at - lastCombatEnd < 5)
end

---------------------------------------------------------------------------
-- Your group
---------------------------------------------------------------------------

-- Names of the other players in your own party (not raids, not a battleground raid).
local function PartyNames()
    if ns.GroupState() ~= "party" then return nil end
    local names = {}
    local home = Plain(Try(GetHomePartyInfo))
    if Plain(Try(IsInGroup, ns.INSTANCE_GROUP)) and type(home) == "table" then
        for _, n in ipairs(home) do
            n = PlainString(n)
            if n then names[#names + 1] = n end
        end
    else
        for i = 1, 4 do
            local n = PlainString(Try(UnitName, "party" .. i))
            if n then names[#names + 1] = n end
        end
    end
    return #names > 0 and names or nil
end

-- Finds a group member (or their pet) by GUID. Returns the member's name and
-- whether it was their pet.
local function MemberByGUID(guid)
    local function Look(unit, owner)
        if PlainString(Try(UnitGUID, unit)) == guid then
            return PlainString(Try(UnitName, owner or unit)) or "?", owner ~= nil
        end
    end
    for i = 1, 4 do
        local name, pet = Look("party" .. i)
        if not name then name, pet = Look("partypet" .. i, "party" .. i) end
        if name then return name, pet end
    end
    if Plain(Try(IsInRaid)) then
        for i = 1, 40 do
            local name, pet = Look("raid" .. i)
            if not name then name, pet = Look("raidpet" .. i, "raid" .. i) end
            if name then return name, pet end
        end
    end
end

-- Is this group member in the party you formed yourself (not just your battleground raid)?
local function IsHomeMember(name)
    if ns.GroupState() == "solo" then return false end
    if not Plain(Try(IsInGroup, ns.INSTANCE_GROUP)) then return true end
    local home = Plain(Try(GetHomePartyInfo))
    if type(home) == "table" then
        for _, n in ipairs(home) do
            n = PlainString(n)
            if n and (n == name or ns.SplitName(n) == name) then return true end
        end
        return false
    end
    -- No home party list: count your own subgroup as your party.
    for i = 1, 4 do
        if PlainString(Try(UnitName, "party" .. i)) == name then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- "You fought them"
---------------------------------------------------------------------------

-- Called by Tracker.lua for every enemy unit it looks at.
function ns.NoteFight(unit, trackerCombat)
    if not Plain(UnitIsPlayer(unit)) then return end
    local guid = PlainString(Try(UnitGUID, unit))
    if not guid or not guid:find("^Player%-") then return end
    if not Plain(Try(UnitCanAttack, "player", unit)) then return end
    local targetingMe = Plain(Try(UnitIsUnit, unit .. "target", "player")) == true
    local mine = (unit == "target" or unit == "focus" or unit == "softenemy")
        and (trackerCombat or inCombat or Plain(Try(UnitAffectingCombat, "player")) == true)
    if targetingMe or mine then fought[guid] = GetTime() end
end

-- Is the unit with this GUID still standing (Feign Death, a fake death)?
local LOOK_UNITS = { "target", "focus", "mouseover", "softenemy" }
local function StillAlive(guid)
    if not guid then return false end
    local function Check(unit)
        if PlainString(Try(UnitGUID, unit)) ~= guid then return nil end
        if Plain(Try(UnitIsFeignDeath, unit)) == true then return true end
        local dead = Plain(Try(UnitIsDeadOrGhost, unit))
        if dead == false then return true end
        return false
    end
    for _, unit in ipairs(LOOK_UNITS) do
        local r = Check(unit)
        if r ~= nil then return r end
    end
    for i = 1, 40 do
        local r = Check("nameplate" .. i)
        if r ~= nil then return r end
    end
    return false
end

---------------------------------------------------------------------------
-- Gathering signals
---------------------------------------------------------------------------

local function NewKill(id, guid)
    local now = GetTime()
    local k = {
        id = id, guid = guid, gt = now, t = time(),
        ctx = ns.GetContext(),
        zone = PlainString(GetRealZoneText()), subzone = PlainString(GetSubZoneText()),
        myLevel = PlainNumber(UnitLevel("player")),
    }
    k.group, k.gsize = ns.GroupState()
    k.with = PartyNames()
    if hkCredit and hkCredit.n > 0 and now - hkCredit.t <= WAIT then
        k.honor = true
        hkCredit.n = hkCredit.n - 1
    end
    pending[id] = k
    C_Timer.After(WAIT, function() ns:FinishKill(id) end)
    return k
end

function frame:PARTY_KILL(attackerGUID, victimGUID)
    local attacker, victim = PlainString(attackerGUID), PlainString(victimGUID)
    ns.Debug("PARTY_KILL", attacker or "<hidden>", victim or "<hidden>")
    if not victim or not ns.IsPlayerGUID(victim) or Recent(victim) then return end
    local k = pending[victim] or NewKill(victim, victim)
    k.kb, k.attacker = true, attacker or false -- false: the game hid who it was
    local pet = PlainString(Try(UnitGUID, "pet"))
    if attacker and (attacker == MyGUID() or attacker == pet) then
        ns:FinishKill(victim) -- your own killing blow: no need to wait
    end
end

function frame:UNIT_DIED(guid)
    guid = PlainString(guid)
    if not guid or not ns.IsPlayerGUID(guid) or guid == MyGUID() or Recent(guid) then return end
    -- Only enemy players: ones you fought, saw as hostile, or have a record of.
    if not (pending[guid] or fought[guid] or ns.seen[guid] or ns.db.guids[guid]) then return end
    ns.Debug("UNIT_DIED", guid)
    local k = pending[guid] or NewKill(guid, guid)
    k.died = true
end

-- Honorable kill chat line. Built from the game's own (localized) strings,
-- e.g. "%s dies, honorable kill Rank: %s (Estimated Honor Points: %d)".
local HONOR_STRINGS = {
    "COMBATLOG_HONORGAIN", "COMBATLOG_HONORGAIN_NO_RANK",
    "COMBATLOG_HONORGAIN_EXHAUSTION1", "COMBATLOG_HONORGAIN_EXHAUSTION2",
    "COMBATLOG_HONORGAIN_EXHAUSTION3", "COMBATLOG_HONORGAIN_EXHAUSTION4",
}
local honorPatterns

local function EscapePattern(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- "%s dies, honorable kill Rank: %s" -> "^(.-) dies, honorable kill Rank: "
function ns.PatternFromFormat(fmt)
    if type(fmt) ~= "string" then return nil end
    local s, e = fmt:find("%%%d?%$?s")
    if not s then return nil end
    local rest = fmt:sub(e + 1)
    local nextSpec = rest:find("%%")
    local after = nextSpec and rest:sub(1, nextSpec - 1) or rest
    if after == "" then return nil end
    return "^" .. EscapePattern(fmt:sub(1, s - 1)) .. "(.-)" .. EscapePattern(after)
end

local function HonorPatterns()
    if honorPatterns then return honorPatterns end
    honorPatterns = {}
    for _, name in ipairs(HONOR_STRINGS) do
        local p = ns.PatternFromFormat(_G[name])
        if p then honorPatterns[#honorPatterns + 1] = p end
    end
    honorPatterns[#honorPatterns + 1] = "^(.-) dies, honorable kill"
    return honorPatterns
end

function ns.ParseHonorMessage(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1")
    for _, pattern in ipairs(HonorPatterns()) do
        local name = text:match(pattern)
        if name and name ~= "" then return strtrim(name) end
    end
end

local function FindPendingByName(name, realm)
    local lname = name:lower()
    for _, k in pairs(pending) do
        local kname, krealm = k.name, k.realm
        if not kname and k.guid then
            k.info = k.info or ns:InfoFromGUID(k.guid)
            if k.info then kname, krealm = k.info.name, k.info.realm end
        end
        if kname and kname:lower() == lname and (not realm or ns.NormRealm(realm) == krealm) then
            return k
        end
    end
end

local function GuidForKey(key)
    local seen = ns.seenByKey[key]
    if seen and seen.guid then return seen.guid end
    local p = ns.db.players[key]
    return p and p.guid
end

function frame:CHAT_MSG_COMBAT_HONOR_GAIN(text)
    text = PlainString(text)
    if not text then ns.Debug("honorable kill message hidden from addons") return end
    local full = ns.ParseHonorMessage(text)
    ns.Debug("honor:", text, "->", full or "?")
    if not full then return end
    local key, name, realm = ns.KeyFromFullName(full)
    if not key or Recent(key) then return end
    local k = FindPendingByName(name, select(2, ns.SplitName(full)))
    if not k then
        local guid = GuidForKey(key)
        if guid and Recent(guid) then return end
        if guid then
            k = pending[guid] or NewKill(guid, guid)
        else
            local id = "name:" .. key
            k = pending[id] or NewKill(id, nil)
            k.key, k.name, k.realm = key, name, realm
        end
    end
    k.honor = true
end

-- The honorable-kill counter went up: the newest deaths being gathered get the credit.
local function ReadHK() return PlainNumber((Try(GetPVPSessionStats))) end

function frame:PLAYER_PVP_KILLS_CHANGED(unit)
    unit = PlainString(unit)
    if unit and unit ~= "player" then return end
    local hk = ReadHK()
    if not hk then return end
    local gained = lastHK and (hk - lastHK) or 0
    lastHK = hk
    if gained <= 0 then return end
    ns.Debug("honorable kills +" .. gained)
    local now = GetTime()
    -- Your own killing blows that were counted at once take their ticks first.
    for i = #ownRecent, 1, -1 do
        if gained == 0 then break end
        if now - ownRecent[i] <= 3 then gained = gained - 1 end
        table.remove(ownRecent, i)
    end
    local list = {}
    for _, k in pairs(pending) do
        if not k.honor then list[#list + 1] = k end
    end
    table.sort(list, function(a, b) return a.gt > b.gt end)
    for _, k in ipairs(list) do
        if gained == 0 then break end
        k.honor = true
        gained = gained - 1
    end
    if gained > 0 then hkCredit = { t = now, n = gained } end
end

---------------------------------------------------------------------------
-- Deciding
---------------------------------------------------------------------------

-- Who landed the killing blow: blow kind, the group member's name, whether it was their pet.
local function WhoLandedIt(k)
    if not k.kb then return "other" end
    local a = k.attacker
    if a and a == MyGUID() then return "me" end
    local pet = PlainString(Try(UnitGUID, "pet"))
    if a and pet and a == pet then return "pet" end
    if a then
        local name, isPet = MemberByGUID(a)
        if name then return IsHomeMember(name) and "party" or "team", name, isPet or nil end
        if a:find("^Player%-") then return "other" end -- a player outside your group
    end
    -- A totem, guardian or other summon (or the game hid who it was).
    return "summon"
end

-- Returns "yes", "meter" (wait for the damage meter) or "no", plus a reason for debug.
local function Decide(k)
    local kind = ns.BlowKind(k)
    if kind == "mine" then return "yes" end
    if not ns.db.settings.countSharedKills then return "no", "shared kills are turned off" end
    -- A killing blow or an honorable kill proves the death; a bare "died" may be Feign Death.
    if not k.kb and not k.honor and StillAlive(k.guid) then return "no", "they are still alive (Feign Death?)" end
    if k.honor then return "yes" end -- the game itself credited you
    local busy = IsBusy(k.gt)
    -- They were on you (or you on them) recently, and you were still in combat when they died.
    local fightT = k.guid and fought[k.guid]
    if busy and fightT and k.gt - fightT <= FOUGHT_WINDOW then
        k.fought = true
        return "yes"
    end
    if busy and k.ctx == "world" and kind == "party" then
        return "yes" -- your party's kill while you were in combat, out in the world
    end
    if busy and k.group == "solo" and k.died then return "meter" end
    return "no", busy and "no sign you fought them" or "you were not in combat"
end

function ns:FinishKill(id)
    local k = pending[id]
    if not k then return end
    pending[id] = nil
    if Recent(id) or Recent(k.key) then return end
    k.blow, k.blowBy, k.blowPet = WhoLandedIt(k)
    local verdict, why = Decide(k)
    ns.Debug("kill", id, "blow:", k.blow, "->", verdict, why or "")
    if verdict == "yes" then
        recorded[id] = GetTime()
        if ns.IsOwnBlow(k) and not k.honor then ownRecent[#ownRecent + 1] = GetTime() end
        self:ResolveKill(k, 1)
    elseif verdict == "meter" then
        waitingMeter[id] = k
        if not inCombat then
            C_Timer.After(1, function() ns:CheckMeter(false) end)
        end
        C_Timer.After(METER_WAIT, function() ns:CheckMeter(true) end)
    end
end

-- Did the damage meter see this enemy take damage (from you, when solo)?
local function MeterDamaged(k)
    if not (C_DamageMeter and C_DamageMeter.GetCombatSessionFromType and Enum
        and Enum.DamageMeterType and Enum.DamageMeterSessionType) then return nil end
    local session = Plain(Try(C_DamageMeter.GetCombatSessionFromType,
        Enum.DamageMeterSessionType.Current, Enum.DamageMeterType.EnemyDamageTaken))
    if type(session) ~= "table" or (canaccesstable and not canaccesstable(session)) then return nil end
    local sources = Plain(session.combatSources)
    if type(sources) ~= "table" then return nil end
    local name = k.info and k.info.name or k.name
    for _, s in ipairs(sources) do
        if type(s) == "table" then
            local guid, sname = PlainString(s.sourceGUID), PlainString(s.name)
            local amount = PlainNumber(s.totalAmount)
            local match = (k.guid and guid == k.guid) or (name and sname and ns.SplitName(sname) == name)
            if match and amount and amount > 0 then return true end
        end
    end
    return false
end

function ns:CheckMeter(force)
    if inCombat and not force then return end
    for id, k in pairs(waitingMeter) do
        if force or GetTime() - k.gt < METER_WAIT + 5 then
            waitingMeter[id] = nil
            k.info = k.info or (k.guid and self:InfoFromGUID(k.guid))
            local ok, hit = pcall(MeterDamaged, k)
            ns.Debug("damage meter for", id, ok and tostring(hit) or "error")
            if ok and hit and not Recent(id) then
                k.meter = true
                recorded[id] = GetTime()
                self:ResolveKill(k, 1)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------

-- Name, class and race from the battleground scoreboard (readable once the match is over).
local function ScoreInfo(guid)
    if not (C_PvP and C_PvP.GetScoreInfoByPlayerGuid) then return nil end
    local s = Plain(Try(C_PvP.GetScoreInfoByPlayerGuid, guid))
    if type(s) ~= "table" or (canaccesstable and not canaccesstable(s)) then return nil end
    local full = PlainString(s.name)
    if not full then return nil end
    local name, realm = ns.SplitName(full)
    realm = ns.NormRealm(realm)
    return {
        guid = guid, name = name, realm = realm, key = name .. "-" .. realm,
        class = PlainString(s.classToken), race = PlainString(s.raceName),
    }
end

local function InfoFor(k)
    if k.guid then
        local info = ns:InfoFromGUID(k.guid) or ScoreInfo(k.guid)
        if info then return info end
    end
    if k.key then
        local seen = ns.seenByKey[k.key]
        if seen then return seen end
        return { name = k.name, realm = ns.NormRealm(k.realm), key = k.key }
    end
end

function ns:ResolveKill(k, attempt)
    local info = InfoFor(k)
    if info then
        self:RecordKill(k, info)
    elseif attempt < 4 then
        C_Timer.After(1, function() ns:ResolveKill(k, attempt + 1) end)
    else
        -- Battlegrounds hide enemy names until the match ends: try again later.
        local save = {}
        for key, v in pairs(k) do
            if type(v) ~= "table" or key == "with" then save[key] = v end
        end
        save.info = nil
        table.insert(self.db.unresolved, save)
        if self.db.settings.printKills then
            ns.Print("|cff40ff40Killed|r a player whose name the game is hiding for now. It is added as soon as the name shows (usually when the match ends).")
        end
    end
end

-- Kills whose victim could not be named yet (inside a battleground).
function ns:RetryUnresolved()
    local list = self.db and self.db.unresolved
    if not list or #list == 0 then return end
    local keep = {}
    for _, k in ipairs(list) do
        local info = InfoFor(k)
        if info then
            self:RecordKill(k, info, true)
        elseif time() - (k.t or 0) < UNRESOLVED_KEEP then
            keep[#keep + 1] = k
        else
            ns.Debug("Gave up identifying a killed player:", k.guid)
        end
    end
    self.db.unresolved = keep
end

function ns:RecordKill(k, info, late)
    local p = self:GetPlayer(info.key, true, info.name, info.realm)
    self:ApplyInfo(p, info)
    local ctx = k.ctx or "world"
    p.kills[ctx] = (p.kills[ctx] or 0) + 1
    local own = ns.IsOwnBlow(k)
    if own then p.kb = (p.kb or 0) + 1 end
    if (k.group or "solo") == "solo" then p.solo = (p.solo or 0) + 1 end
    p.lastKill = math.max(p.lastKill or 0, k.t)
    p.lastKillZone = k.zone
    p.lastSeen = math.max(p.lastSeen or 0, k.t)
    p.lastSeenZone = k.zone
    recorded[info.key] = GetTime()
    if k.guid then recorded[k.guid] = GetTime() end

    local revenge = p.list ~= nil
    if revenge then
        p.revenge = (p.revenge or 0) + 1
        p.list.lastRevenge = k.t
    end

    local how = {}
    if k.kb then how[#how + 1] = "kb" end
    if k.honor then how[#how + 1] = "honor" end
    if k.fought and not own then how[#how + 1] = "fought" end
    if k.meter then how[#how + 1] = "meter" end
    if #how == 0 then how[1] = "died" end

    local entry = {
        t = k.t, key = info.key, ctx = ctx, zone = k.zone, subzone = k.subzone,
        myLevel = k.myLevel, level = info.level, skull = info.skull,
        pet = (k.blow == "pet") or nil, revenge = revenge or nil, char = self.myKey,
        blow = k.blow or "me", blowBy = k.blowBy, blowPet = k.blowPet,
        group = k.group or "solo", gsize = k.gsize or 1, with = k.with,
        how = table.concat(how, ","),
    }
    self:AppendLog(self.db.kills, entry)

    if self.db.settings.printKills then
        local total = ns.Total(p.kills)
        local msg = string.format("|cff40ff40Killed|r %s (%s %s) - %s kill (%d world, %d BG)",
            ns.ColoredName(p), ns.FormatLevel(info.level, info.skull), ns.ClassName(p.class),
            ns.Ordinal(total), p.kills.world or 0, p.kills.bg or 0)
        if k.blow == "pet" then
            msg = msg .. " [pet]"
        elseif k.blow == "summon" and own then
            msg = msg .. " [totem/summon]"
        elseif not own then
            if k.blow == "other" then
                msg = msg .. " - killing blow: an NPC or the environment"
            else
                msg = msg .. " - killing blow: " .. ns.BlowText(entry)
            end
        end
        if entry.group ~= "solo" then msg = msg .. " [" .. ns.GroupText(entry.group, entry.gsize):lower() .. "]" end
        if late then msg = msg .. " (from earlier in the match)" end
        if revenge then
            local deaths = ns.Total(p.deaths)
            msg = msg .. string.format("  |cffff4040REVENGE!|r (%s, they killed you %s)",
                ns.Plural(p.revenge, "revenge kill"), ns.Plural(deaths, "time"))
        end
        ns.Print(msg)
    end
    self:NotifyChanged()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

function frame:PLAYER_REGEN_DISABLED()
    inCombat = true
end

function frame:PLAYER_REGEN_ENABLED()
    inCombat = false
    lastCombatEnd = GetTime()
    -- Give the damage meter a moment to finish the session.
    C_Timer.After(1, function() ns:CheckMeter(false) end)
    ns:RetryUnresolved()
    -- Forget old fights.
    local now = GetTime()
    for guid, t in pairs(fought) do
        if now - t > 300 then fought[guid] = nil end
    end
end

function frame:PLAYER_ENTERING_WORLD()
    lastHK = ReadHK()
    inCombat = Plain(Try(UnitAffectingCombat, "player")) == true
    C_Timer.After(3, function() ns:RetryUnresolved() end)
end

local scoreRetryAt = 0
function frame:UPDATE_BATTLEFIELD_SCORE()
    local now = GetTime()
    if now - scoreRetryAt < 5 then return end
    scoreRetryAt = now
    ns:RetryUnresolved()
end

function frame:PVP_MATCH_COMPLETE()
    C_Timer.After(1, function() ns:RetryUnresolved() end)
end

local reportedErrors = {}
frame:SetScript("OnEvent", function(self, event, ...)
    local handler = self[event]
    if not handler or not ns.db then return end
    local ok, err = pcall(handler, self, ...)
    if not ok and not reportedErrors[event] then
        reportedErrors[event] = true
        ns.Print("|cffff2020error in " .. event .. ":|r " .. tostring(err))
    end
end)

for _, event in ipairs({
    "PARTY_KILL", "UNIT_DIED", "CHAT_MSG_COMBAT_HONOR_GAIN", "PLAYER_PVP_KILLS_CHANGED",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD",
    "UPDATE_BATTLEFIELD_SCORE", "PVP_MATCH_COMPLETE",
}) do
    if not pcall(frame.RegisterEvent, frame, event) then
        ns.Debug("event not available:", event)
    end
end
