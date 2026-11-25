-- Kill List Stats - Tracker
-- Watches enemy players around you and detects your deaths to players
-- (PLAYER_DEAD + the death recap + enemies seen targeting you).
-- Kills are detected in Kills.lua.

local _, ns = ...
local Plain, PlainString, PlainNumber, Try = ns.Plain, ns.PlainString, ns.PlainNumber, ns.Try

local tracker = CreateFrame("Frame")
ns.tracker = tracker

-- Enemy players seen targeting you recently: key -> { info = info, t = GetTime() }
local attackers = {}
ns.attackers = attackers

local combatStart, lastCombatStart, lastCombatEnd
local lastRecapSig
local deathSerial = 0   -- each death gets a number; older pending lookups give up
-- Kill List presence: key -> { plates = { [nameplateToken] = true }, lastSeen = t, goneAt = t, alertedAt = t }
local presence = {}
local plateKey = {}     -- nameplate token -> key of the Kill List player shown on it
local FLICKER_GAP = 10  -- seconds a nameplate must be gone before a return counts as "came back"
local UNSEEN_GAP = 60   -- without a nameplate: unseen this long counts as gone
local MIN_ALERT_GAP = 5 -- never warn about the same player more often than this
local reportedErrors = {}

---------------------------------------------------------------------------
-- Watching enemy players
---------------------------------------------------------------------------

function ns:AlertKillList(p)
    if not p or not p.list or not self.db.settings.alertKillList then return end
    local deaths = ns.Total(p.deaths)
    local msg = string.format("Kill List: %s (%s %s) is nearby!", ns.ColoredName(p),
        ns.FormatLevel(p.level), ns.ClassName(p.class))
    if deaths > 0 then
        msg = msg .. string.format(" They killed you %d time%s.", deaths, deaths == 1 and "" or "s")
    end
    ns.Print(msg)
    if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo then
        pcall(RaidNotice_AddMessage, RaidWarningFrame, msg, ChatTypeInfo["RAID_WARNING"])
    end
    if self.db.settings.alertSound then
        pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959, "Master")
    end
end

-- Called whenever a Kill List player is seen on a unit. Warns when they
-- (re)appear: the first time, and again every time they come back after their
-- nameplate was gone for FLICKER_GAP seconds (or after UNSEEN_GAP without nameplates).
local function NotePresence(key, p, unit)
    local now = GetTime()
    local pr = presence[key]
    local wasPresent = false
    if pr then
        if next(pr.plates) then
            wasPresent = true
        elseif pr.goneAt then
            wasPresent = now - pr.goneAt < FLICKER_GAP
        else
            wasPresent = now - pr.lastSeen < UNSEEN_GAP
        end
    else
        pr = { plates = {} }
        presence[key] = pr
    end

    pr.lastSeen = now
    if unit:find("^nameplate%d+$") then
        if plateKey[unit] and plateKey[unit] ~= key and presence[plateKey[unit]] then
            presence[plateKey[unit]].plates[unit] = nil
        end
        plateKey[unit] = key
        pr.plates[unit] = true
    end
    if not wasPresent then
        pr.goneAt = nil
        if not pr.alertedAt or now - pr.alertedAt >= MIN_ALERT_GAP then
            pr.alertedAt = now
            ns:AlertKillList(p)
        end
    end
end

local function PlateGone(unit)
    local key = plateKey[unit]
    if not key then return end
    plateKey[unit] = nil
    local pr = presence[key]
    if pr then
        pr.plates[unit] = nil
        if not next(pr.plates) then pr.goneAt = GetTime() end
    end
end

-- The NPC you are fighting right now (your attackable non-player target), if any.
local function CurrentNPCTarget()
    if not combatStart or not UnitExists("target") or UnitIsPlayer("target") then return nil end
    if not Plain(UnitCanAttack("player", "target")) then return nil end
    if Plain(Try(UnitPlayerControlled, "target")) then return nil end -- someone's pet
    return PlainString(Try(UnitName, "target"))
end

local ENGAGE_RESET = 15 -- seconds without targeting you before it counts as a new engagement

-- Reads a unit; remembers enemy players, warns about Kill List players and
-- notes enemies that are targeting you (they get assists if you die soon).
-- When an enemy first locks onto you, remembers what you were doing: how long
-- you had been in combat and which mob you were fighting.
local function Observe(unit)
    -- Kills.lua: remembers enemies you are fighting (works even with hidden names).
    if ns.NoteFight then pcall(ns.NoteFight, unit, combatStart ~= nil) end
    local ok, info, p = pcall(ns.ObserveUnit, ns, unit)
    if not ok or not info then return end
    if p and p.list then NotePresence(info.key, p, unit) end

    local ok2, isMe = pcall(UnitIsUnit, unit .. "target", "player")
    if ok2 and Plain(isMe) == true then
        local now = GetTime()
        local a = attackers[info.key]
        -- Same engagement unless that entry is from an earlier, separate fight.
        local stale = a and ((combatStart and a.t < combatStart - 5)
            or (not combatStart and now - a.t > ENGAGE_RESET))
        if a and not stale then
            a.info, a.t = info, now
        else
            attackers[info.key] = {
                info = info, t = now, first = now,
                combatFor = combatStart and (now - combatStart) or nil,
                npc = ns.Try(CurrentNPCTarget),
            }
        end
    end
end

local SCAN_UNITS = { "target", "focus", "mouseover", "softenemy" }

local function Scan()
    for _, unit in ipairs(SCAN_UNITS) do Observe(unit) end
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) then Observe(unit) end
    end
    local now = GetTime()
    for key, a in pairs(attackers) do
        if now - a.t > 120 then attackers[key] = nil end
    end
end
ns.Scan = Scan

local scanTicker
local function StartScanning()
    if not scanTicker then scanTicker = C_Timer.NewTicker(0.5, Scan) end
end
local function StopScanning()
    if scanTicker then scanTicker:Cancel(); scanTicker = nil end
end

---------------------------------------------------------------------------
-- Deaths
---------------------------------------------------------------------------

local COMBATLOG_PLAYER = 0x00000400
local COMBATLOG_NPC = 0x00000800
local COMBATLOG_PET = 0x00001000
local COMBATLOG_GUARDIAN = 0x00002000

-- Returns the recap events of your latest death, or nil.
function ns:ReadRecap()
    if not C_DeathRecap or not C_DeathRecap.GetRecapEvents then return nil end
    local has = Plain(Try(C_DeathRecap.HasRecapEvents))
    if not has then return nil end
    local events = Try(C_DeathRecap.GetRecapEvents)
    if type(events) ~= "table" then return nil end
    if canaccesstable and not canaccesstable(events) then return nil end
    return events
end

local function RecapSignature(events)
    local parts = { #events }
    for i = 1, math.min(#events, 5) do
        local e = events[i]
        if type(e) == "table" then
            parts[#parts + 1] = tostring(PlainNumber(e.timestamp) or "")
            parts[#parts + 1] = tostring(PlainString(e.sourceName) or "")
            parts[#parts + 1] = tostring(PlainNumber(e.amount) or "")
            parts[#parts + 1] = tostring(PlainNumber(e.currentHP) or "")
        end
    end
    return table.concat(parts, "|")
end

local ENV_NAMES = {
    DROWNING = "Drowning", FALLING = "Falling", FATIGUE = "Fatigue",
    FIRE = "Fire", LAVA = "Lava", SLIME = "Slime",
}

local function ParseRecapEvent(e)
    if type(e) ~= "table" then return nil end
    local r = {
        event = PlainString(e.event),
        src = PlainString(e.sourceName),
        srcGUID = PlainString(e.sourceGUID),
        srcFlags = PlainNumber(e.sourceFlags),
        hidden = Plain(e.hideCaster) == true,
        spell = PlainString(e.spellName),
        amount = PlainNumber(e.amount),
        hp = PlainNumber(e.currentHP),
        ts = PlainNumber(e.timestamp),
    }
    if r.event == "SWING_DAMAGE" then
        r.spell = "Melee"
    elseif r.event == "ENVIRONMENTAL_DAMAGE" then
        local env = PlainString(e.environmentalType)
        r.isEnv = true
        r.src = ENV_NAMES[env and env:upper() or ""] or env or "Environment"
        r.spell = r.src
    end
    return r
end

-- Decides whether a recap damage source is an enemy player, a pet, or an NPC.
function ns:ClassifySource(r, ev)
    if r.isEnv then return "env" end
    if r.srcGUID then
        if r.srcGUID:find("^Player%-") then
            local info = self:InfoFromGUID(r.srcGUID)
            if not info and r.src then
                local key, name, realm = ns.KeyFromFullName(r.src)
                info = { key = key, name = name, realm = realm, guid = r.srcGUID }
            end
            return "player", info
        elseif r.srcGUID:find("^Pet%-") then
            return "pet"
        end
        return "npc"
    end
    if r.srcFlags then
        if bit.band(r.srcFlags, COMBATLOG_PLAYER) ~= 0 and bit.band(r.srcFlags, COMBATLOG_NPC) == 0 then
            if bit.band(r.srcFlags, COMBATLOG_PET + COMBATLOG_GUARDIAN) == 0 then
                -- player controlled "player" type: fall through to name lookup for details
            else
                return "pet"
            end
        elseif bit.band(r.srcFlags, COMBATLOG_PET + COMBATLOG_GUARDIAN) ~= 0 then
            return "pet"
        elseif bit.band(r.srcFlags, COMBATLOG_NPC) ~= 0 then
            return "npc"
        end
    end
    if not r.src then return "unknown" end

    local key, name, realm = ns.KeyFromFullName(r.src)
    local info = ev.targeters[key] or self.seenByKey[key]
    if info then return "player", info end
    local p = self.db.players[key]
    if p then
        return "player", { key = key, name = p.name, realm = p.realm, class = p.class, level = p.level, guid = p.guid }
    end
    if r.srcFlags and bit.band(r.srcFlags, COMBATLOG_PLAYER) ~= 0 then
        return "player", { key = key, name = name, realm = realm }
    end
    -- Inside battlegrounds almost every attacker is a player and names of
    -- enemy players cannot be read from units during the match.
    if ev.ctx == "bg" then
        return "player", { key = key, name = name, realm = realm }
    end
    return "npc"
end

local function SortedInvolved(involved)
    local list = {}
    for _, inv in pairs(involved) do list[#list + 1] = inv end
    table.sort(list, function(a, b)
        if a.dmg ~= b.dmg then return a.dmg > b.dmg end
        return (a.lastT or 0) > (b.lastT or 0)
    end)
    return list
end

local function Plural(n, word)
    return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

function tracker:PLAYER_DEAD()
    local now = GetTime()
    local ctx = ns.GetContext()
    local combatTime
    if combatStart then
        combatTime = now - combatStart
    elseif lastCombatStart and lastCombatEnd and now - lastCombatEnd < 2 then
        combatTime = lastCombatEnd - lastCombatStart
    end

    pcall(Scan)
    local window = ns.db.settings.assistWindow or 15
    local targeters, engage = {}, {}
    for key, a in pairs(attackers) do
        if now - a.t <= window then
            targeters[key] = a.info
            a.info.targetedAt = a.t
            engage[key] = { combatFor = a.combatFor, npc = a.npc }
        end
    end

    deathSerial = deathSerial + 1
    local party, psize = ns.GroupState()
    local ev = {
        party = party, psize = psize,
        serial = deathSerial,
        t = time(), gt = now, ctx = ctx,
        myLevel = UnitLevel("player"),
        zone = PlainString(GetRealZoneText()), subzone = PlainString(GetSubZoneText()),
        group = IsInGroup() and math.max(GetNumGroupMembers(), 1) or 1,
        combatTime = combatTime,
        targeters = targeters,
        engage = engage,
    }
    ns.Debug("PLAYER_DEAD", ctx, "targeting you:", ns.CountKeys(targeters))
    C_Timer.After(0.4, function() ns:ProcessDeath(ev, 1) end)
end

function ns.CountKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function ns:ProcessDeath(ev, attempt)
    if ev.serial ~= deathSerial then return end -- you died again meanwhile
    local events = self:ReadRecap()
    local sig = events and RecapSignature(events)
    if (not events or sig == lastRecapSig) and attempt < 7 then
        C_Timer.After(0.5, function() ns:ProcessDeath(ev, attempt + 1) end)
        return
    end
    if sig and sig == lastRecapSig then events = nil end -- stale recap from an earlier death
    if sig then lastRecapSig = sig end
    if events then self.lastRecapRaw = events end

    -- 1) Parse the recap (newest first: entry 1 is the killing blow).
    local recs = {}
    for _, e in ipairs(events or {}) do
        local r = ParseRecapEvent(e)
        if r then
            r.kind, r.info = self:ClassifySource(r, ev)
            recs[#recs + 1] = r
        end
    end

    -- 2) Collect every enemy player involved.
    local involved = {}
    local function Involve(info, fromRecap)
        if not info or not info.key then return nil end
        local inv = involved[info.key]
        if not inv then
            inv = { key = info.key, info = info, dmg = 0, hits = 0 }
            involved[info.key] = inv
        elseif info.guid and not inv.info.guid then
            inv.info = info
        end
        if fromRecap then inv.recap = true end
        return inv
    end
    for i, r in ipairs(recs) do
        if r.kind == "player" and r.info then
            local inv = Involve(r.info, true)
            inv.dmg = inv.dmg + (r.amount or 0)
            inv.hits = inv.hits + 1
            inv.spell = inv.spell or r.spell
            if i == 1 then inv.kb = true end
            inv.firstIdx = i -- the recap is newest first, so this ends on their oldest hit
        end
    end
    for key, info in pairs(ev.targeters) do
        local inv = Involve(info, false)
        inv.targeted = true
        inv.lastT = info.targetedAt
    end

    -- 2b) Your health when each of them started hitting you, and what you
    -- were doing at that moment (fighting a mob? how long into the fight?).
    local maxHP = PlainNumber(Try(C_DeathRecap and C_DeathRecap.GetRecapMaxHealth))
    -- The killing blow tells us how the recap stores health: 0 means "health
    -- after the hit", anything else means "health before the hit".
    local hpAfterHit = not (recs[1] and recs[1].hp and recs[1].hp > 0)
    -- The recap only keeps your last N hits. If this one is shorter than the
    -- longest seen so far, it holds the whole fight.
    local recapCap = self.db.recapMax or 0
    local recapComplete = recapCap >= 3 and #recs < recapCap
    self.db.recapMax = math.max(recapCap, #recs)
    local function HpBefore(r)
        if not r or not r.hp or not maxHP or maxHP <= 0 then return nil end
        local hp = r.hp
        if hpAfterHit then hp = hp + (r.amount or 0) end
        return math.max(0, math.min(100, math.floor(hp / maxHP * 100 + 0.5)))
    end
    for key, inv in pairs(involved) do
        local e = ev.engage[key]
        if e then
            inv.join = e.combatFor
            inv.npc = e.npc
        end
        if inv.firstIdx then
            local olderPlayer, olderNPC = false, nil
            for j = inv.firstIdx + 1, #recs do
                local o = recs[j]
                if o.kind == "player" then
                    olderPlayer = true
                elseif o.kind == "npc" and o.src and not olderNPC then
                    olderNPC = o.src
                end
            end
            inv.firstPlayer = not olderPlayer
            inv.npc = olderNPC or inv.npc
            -- Only trust it if older hits exist or the recap covers the whole
            -- fight; otherwise they may have hit you before the recap window.
            if inv.firstIdx < #recs or recapComplete then
                inv.hp = HpBefore(recs[inv.firstIdx])
            end
        end
    end

    -- Describes how a player engaged you. Returns text and whether it was a cheap shot.
    local function Engagement(inv)
        local text, cheap
        if inv.npc then
            text = "attacked you" .. (inv.hp and string.format(" at ~%d%% health", inv.hp) or "") ..
                " while you were fighting " .. inv.npc
            cheap = true
        elseif inv.hp and inv.hp <= 60 and inv.firstPlayer then
            text = string.format("attacked you when you were already hurt (~%d%% health)", inv.hp)
            cheap = true
        elseif inv.hp then
            text = string.format("attacked you at ~%d%% health", inv.hp)
        elseif inv.join and inv.join >= 5 then
            text = "joined a fight you were already in"
        end
        if text and inv.join and inv.join >= 3 then
            text = text .. string.format(", %ds into the fight", math.floor(inv.join + 0.5))
        end
        return text, cheap
    end

    -- 3) Pick the killer.
    local kbRec = recs[1]
    local killer, kbOther, guessed
    if kbRec and kbRec.kind == "player" and kbRec.info and involved[kbRec.info.key] then
        killer = involved[kbRec.info.key]
    else
        local ranked = SortedInvolved(involved)
        local topDamage = ranked[1] and ranked[1].dmg > 0 and ranked[1] or nil
        if topDamage then
            killer = topDamage
            kbOther = kbRec and (kbRec.src or kbRec.spell)
        elseif kbRec and kbRec.kind == "pet" and ranked[1] then
            killer, kbOther = ranked[1], kbRec.src
        elseif #recs == 0 and ranked[1] then
            killer, guessed = ranked[1], true
        end
    end
    ns.Debug(string.format("death: %d recap entries, killing blow by %s (%s), %d enemy players involved",
        #recs, kbRec and (kbRec.src or "?") or "-", kbRec and kbRec.kind or "-", ns.CountKeys(involved)))
    if not killer then
        ns.Debug("Death without enemy players involved - not recorded.")
        return
    end

    -- 4) Build the death record and the explanation.
    local db = self.db
    local myLevel = ev.myLevel
    local kInfo = killer.info
    local kp = self:GetPlayer(killer.key, true, kInfo.name, kInfo.realm)
    self:ApplyInfo(kp, kInfo)
    local kLevel = (kInfo.level and kInfo.level > 0) and kInfo.level or nil
    local kSkull = kInfo.skull and not kLevel or nil
    if not kLevel and not kSkull and kp.level then kLevel = kp.level end

    local reasons = {}
    if kSkull then
        reasons[#reasons + 1] = "Killer was ?? level (10+ levels above you)"
    elseif kLevel and myLevel then
        local d = kLevel - myLevel
        if d > 0 then
            reasons[#reasons + 1] = string.format("Killer was %s higher (%d vs your %d)", Plural(d, "level"), kLevel, myLevel)
        elseif d < 0 then
            reasons[#reasons + 1] = string.format("You were %s higher (%d vs their %d)", Plural(-d, "level"), myLevel, kLevel)
        end
    end

    local enemies = ns.CountKeys(involved)
    if enemies >= 2 then
        if ev.ctx == "world" then
            if ev.group > 1 then
                reasons[#reasons + 1] = string.format("Outnumbered: %d enemy players vs your group of %d", enemies, ev.group)
            else
                reasons[#reasons + 1] = string.format("Outnumbered: %d enemy players vs you alone", enemies)
            end
        else
            reasons[#reasons + 1] = string.format("%d enemy players on you", enemies)
        end
    end

    local engageText, cheap = Engagement(killer)
    if engageText then
        if cheap then
            reasons[#reasons + 1] = "Opportunist: " .. engageText
        else
            reasons[#reasons + 1] = (engageText:gsub("^%l", string.upper))
        end
    end

    if ev.combatTime and ev.combatTime <= 8 then
        reasons[#reasons + 1] = string.format("Dead %.0fs after combat started", math.max(ev.combatTime, 1))
    end

    local npcName
    for _, r in ipairs(recs) do
        if r.kind == "npc" and r.src then npcName = r.src break end
    end
    if npcName and not killer.npc then
        reasons[#reasons + 1] = "You were also fighting NPCs (" .. npcName .. ")"
    end

    if kbOther then reasons[#reasons + 1] = "Killing blow by " .. kbOther end
    if guessed then reasons[#reasons + 1] = "No death recap: killer guessed from who was targeting you" end

    local prevDeaths = ns.Total(kp.deaths)
    if prevDeaths > 0 then
        reasons[#reasons + 1] = string.format("Repeat offender: killed you %s before", Plural(prevDeaths, "time"))
    end

    local assists = {}
    for _, inv in ipairs(SortedInvolved(involved)) do
        if inv ~= killer then
            local ap = self:GetPlayer(inv.key, true, inv.info.name, inv.info.realm)
            self:ApplyInfo(ap, inv.info)
            ap.assists[ev.ctx] = (ap.assists[ev.ctx] or 0) + 1
            ap.lastAssist = ev.t
            ap.lastSeen = math.max(ap.lastSeen or 0, ev.t)
            ap.lastSeenZone = ev.zone
            local aText, aCheap = Engagement(inv)
            assists[#assists + 1] = {
                key = inv.key, class = ap.class, level = (inv.info.level and inv.info.level > 0) and inv.info.level or ap.level,
                skull = inv.info.skull, dmg = inv.dmg > 0 and inv.dmg or nil, targeted = inv.targeted or nil,
                hp = inv.hp, npc = inv.npc, join = inv.join, cheap = aCheap or nil, engage = aText,
            }
            if ev.ctx == "world" and db.settings.autoListWorldAssists then
                self:AddToKillList(ap, string.format("Helped kill you at level %s in %s", tostring(myLevel), ev.zone or "?"), true)
            end
        end
    end

    local recapSave = {}
    for i = 1, math.min(#recs, 10) do
        local r = recs[i]
        recapSave[i] = { src = r.src, spell = r.spell, amount = r.amount, kind = r.kind, hp = HpBefore(r) }
    end

    local death = {
        t = ev.t, char = self.myKey, ctx = ev.ctx, zone = ev.zone, subzone = ev.subzone,
        myLevel = myLevel, group = ev.group, party = ev.party, psize = ev.psize, combatTime = ev.combatTime,
        killer = killer.key, killerClass = kp.class, killerLevel = kLevel, killerSkull = kSkull,
        kbSpell = killer.kb and kbRec and kbRec.spell or killer.spell, kbAmount = killer.kb and kbRec and kbRec.amount or nil,
        kbOther = kbOther, guessed = guessed, enemies = enemies,
        killerHP = killer.hp, killerNPC = killer.npc, killerJoin = killer.join,
        cheap = cheap or nil, engage = engageText,
        assists = assists, reasons = reasons, recap = recapSave,
    }
    self:AppendLog(db.deaths, death)

    kp.deaths[ev.ctx] = (kp.deaths[ev.ctx] or 0) + 1
    if cheap then kp.cheap = (kp.cheap or 0) + 1 end
    kp.lastDeath = ev.t
    kp.lastDeathZone = ev.zone
    kp.lastSeen = math.max(kp.lastSeen or 0, ev.t)
    kp.lastSeenZone = ev.zone
    kp.lastDeathText = table.concat(reasons, "; ")

    local summary = string.format("Killed you at level %s in %s%s", tostring(myLevel), ev.zone or "?",
        kLevel and string.format(" (they were %d)", kLevel) or (kSkull and " (they were ??)" or ""))
    if cheap then summary = summary .. "; " .. engageText end
    local added
    if (ev.ctx == "world" and db.settings.autoListWorldKillers) or (ev.ctx == "bg" and db.settings.autoListBGKillers) then
        added = self:AddToKillList(kp, summary, true)
    elseif kp.list then
        kp.list.reason = summary
    end

    if db.settings.printDeaths then
        local msg = string.format("|cffff4040Killed by|r %s (%s %s)%s", ns.ColoredName(kp),
            ns.FormatLevel(kLevel, kSkull), ns.ClassName(kp.class),
            death.kbSpell and (" with " .. death.kbSpell) or "")
        if #assists > 0 then
            local names = {}
            for i, a in ipairs(assists) do
                if i > 5 then names[#names + 1] = "..." break end
                names[#names + 1] = ns.ColoredName(db.players[a.key])
            end
            msg = msg .. " | assists: " .. table.concat(names, ", ")
        end
        ns.Print(msg)
        if #reasons > 0 then ns.Print("  |cffbbbbbbWhy:|r " .. table.concat(reasons, "; ")) end
        if added then ns.Print("  " .. ns.ColoredName(kp) .. " was added to your Kill List.") end
    end
    self:NotifyChanged()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

function tracker:ADDON_LOADED(name)
    if name ~= ns.name then return end
    ns:InitDB()
    self:UnregisterEvent("ADDON_LOADED")
end

function tracker:PLAYER_LOGIN()
    ns.myRealm = nil
    ns.myKey = (UnitName("player") or "?") .. "-" .. ns.MyRealm()
end

function tracker:PLAYER_ENTERING_WORLD()
    -- Remember the current recap so an old one is never mistaken for a new death.
    local events = ns:ReadRecap()
    if events and not lastRecapSig then lastRecapSig = RecapSignature(events) end
    if UnitAffectingCombat("player") then
        combatStart = combatStart or GetTime()
        StartScanning()
    end
    wipe(attackers)
    -- Nameplates are rebuilt after a loading screen: forget the old ones.
    wipe(plateKey)
    for _, pr in pairs(presence) do
        if next(pr.plates) then
            wipe(pr.plates)
            pr.goneAt = GetTime()
        end
    end
    C_Timer.After(2, function() pcall(Scan) end)
end

function tracker:PLAYER_REGEN_DISABLED()
    combatStart = GetTime()
    lastCombatStart = combatStart
    StartScanning()
    Scan()
end

function tracker:PLAYER_REGEN_ENABLED()
    if combatStart then lastCombatStart = combatStart end
    lastCombatEnd = GetTime()
    combatStart = nil
    StopScanning()
end

function tracker:PLAYER_TARGET_CHANGED() Observe("target") end
function tracker:UPDATE_MOUSEOVER_UNIT() Observe("mouseover") end
function tracker:NAME_PLATE_UNIT_ADDED(unit) if type(unit) == "string" then Observe(unit) end end
function tracker:NAME_PLATE_UNIT_REMOVED(unit) if type(unit) == "string" then PlateGone(unit) end end

function tracker:UNIT_TARGET(unit)
    if type(unit) ~= "string" then return end
    if unit == "target" or unit == "focus" or unit == "mouseover" or unit:find("^nameplate%d+$") then
        Observe(unit)
    end
end

tracker:SetScript("OnEvent", function(self, event, ...)
    local handler = self[event]
    if not handler then return end
    local ok, err = pcall(handler, self, ...)
    if not ok and not reportedErrors[event] then
        reportedErrors[event] = true
        ns.Print("|cffff2020error in " .. event .. ":|r " .. tostring(err))
    end
end)

for _, event in ipairs({
    "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD",
    "PLAYER_DEAD",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "UNIT_TARGET",
}) do
    if not pcall(tracker.RegisterEvent, tracker, event) then
        ns.Debug("event not available:", event)
    end
end
