-- Scenario tests for Kill List Stats, run against tests/wow_mock.lua.

local passed, failed = 0, 0
local function check(cond, label)
    if cond then
        passed = passed + 1
        print("  ok   " .. label)
    else
        failed = failed + 1
        print("  FAIL " .. label)
    end
end
local function section(name) print("\n== " .. name) end
local function lastChat() return MOCK.messages[#MOCK.messages] or "" end
local function chatContains(text)
    for _, m in ipairs(MOCK.messages) do if m:find(text, 1, true) then return true end end
    return false
end

local ns = KillListStats
local ME = "Player-1-0001"

local function enemy(unit, guid, name, class, level, extra)
    local u = { guid = guid, name = name, class = class, level = level, race = "Orc", isPlayer = true, enemy = true }
    for k, v in pairs(extra or {}) do u[k] = v end
    MOCK.units[unit] = u
    MOCK.guidInfo[guid] = { name = name, class = class, className = class, race = "Orc", level = level, realm = u.realmInfo or "" }
    return u
end

---------------------------------------------------------------------------
section("load")
MOCK.units.player = { guid = ME, name = "Me", level = 20, isPlayer = true }
MOCK.Fire("ADDON_LOADED", "KillListStats")
MOCK.Fire("PLAYER_LOGIN")
MOCK.Fire("PLAYER_ENTERING_WORLD")
check(ns.db ~= nil and KillListStatsDB == ns.db, "saved variables initialised")
check(ns.myKey == "Me-MyRealm", "own key is Me-MyRealm")
check(ns.db.settings.assistWindow == 15, "default settings applied")

---------------------------------------------------------------------------
section("world kill")
MOCK.guidInfo["Player-1-AAA"] = { name = "Gankster", class = "ROGUE", className = "Rogue", race = "Orc", level = 22, realm = "" }
MOCK.Fire("PARTY_KILL", ME, "Player-1-AAA")
local g = ns.db.players["Gankster-MyRealm"]
check(g and g.kills.world == 1 and g.kills.bg == 0, "world kill counted")
check(g and g.class == "ROGUE" and g.level == 22, "class and level stored")
check(ns.db.guids["Player-1-AAA"] == "Gankster-MyRealm", "guid index stored")
check(chatContains("Killed Gankster (22 Rogue) - 1st kill"), "kill printed to chat")
MOCK.Fire("PARTY_KILL", ME, "Player-1-AAA")
check(g.kills.world == 1, "duplicate event within 3s ignored")
MOCK.Advance(5)
MOCK.Fire("PARTY_KILL", ME, "Player-1-AAA")
check(g.kills.world == 2, "second kill counted after 5s")

section("ignored kills")
MOCK.Advance(5)
MOCK.Fire("PARTY_KILL", "Player-1-0999", "Player-1-AAA")
check(g.kills.world == 2, "party member's kill not counted as yours")
MOCK.Fire("PARTY_KILL", ME, "Creature-0-1-2-3-4-5")
check(ns.CountKeys(ns.db.players) == 1, "NPC kill ignored")
local ok = pcall(MOCK.Fire, "PARTY_KILL", SECRET(ME), SECRET("Player-1-AAA"))
check(ok and g.kills.world == 2, "secret GUIDs ignored without errors")

section("pet kill")
MOCK.units.pet = { guid = "Pet-0-1-2-3-4-77" }
MOCK.Advance(5)
MOCK.Fire("PARTY_KILL", "Pet-0-1-2-3-4-77", "Player-1-AAA")
check(g.kills.world == 3, "pet killing blow counts as your kill")
check(ns.db.kills[#ns.db.kills].pet == true, "kill log marks pet kill")

section("battleground kill")
MOCK.instanceType, MOCK.zone = "pvp", "Warsong Gulch"
MOCK.guidInfo["Player-2-BBB"] = { name = "Flagrunner", class = "WARRIOR", className = "Warrior", race = "Tauren", level = 19, realm = "Other Realm" }
MOCK.Fire("PARTY_KILL", ME, "Player-2-BBB")
local fr = ns.db.players["Flagrunner-OtherRealm"]
check(fr and fr.kills.bg == 1 and fr.kills.world == 0, "BG kill counted under BG, realm normalised")
MOCK.instanceType, MOCK.zone = nil, nil

---------------------------------------------------------------------------
section("world death: fighting a mob at 50% HP when two players jump in")
-- You are fighting a Murloc; 8 seconds into the fight Bully and Helper lock onto you.
MOCK.units.target = { name = "Murloc Raider", isPlayer = false, enemy = true }
MOCK.Fire("PLAYER_REGEN_DISABLED")
MOCK.Advance(8)
enemy("nameplate1", "Player-1-CCC", "Bully", "WARRIOR", 30, { targetingMe = true, guild = "Gankers" })
enemy("nameplate2", "Player-1-DDD", "Helper", "MAGE", 25, { targetingMe = true })
enemy("nameplate3", "Player-1-EEE", "Bystander", "HUNTER", 20, { targetingMe = false })
MOCK.Fire("UNIT_TARGET", "nameplate1")
MOCK.Fire("UNIT_TARGET", "nameplate2")
MOCK.Fire("UNIT_TARGET", "nameplate3")
MOCK.Advance(3)
-- max health 1000; recap health is "after the hit" (0 on the killing blow)
MOCK.recap = {
    { event = "SWING_DAMAGE", sourceName = "Bully", amount = 100, currentHP = 0, timestamp = 10.0 },
    { event = "SPELL_DAMAGE", sourceName = "Helper", spellName = "Frostbolt", amount = 150, currentHP = 100, timestamp = 9.5 },
    { event = "SPELL_DAMAGE", sourceName = "Bully", spellName = "Mortal Strike", amount = 250, currentHP = 250, timestamp = 9.0 },
    { event = "SWING_DAMAGE", sourceName = "Murloc Raider", amount = 300, currentHP = 500, timestamp = 8.0 },
}
MOCK.Fire("PLAYER_DEAD")
MOCK.Fire("PLAYER_REGEN_ENABLED")
MOCK.Advance(1)
MOCK.units.target = nil
local bully, helper = ns.db.players["Bully-MyRealm"], ns.db.players["Helper-MyRealm"]
check(#ns.db.deaths == 1, "death recorded")
check(bully and bully.deaths.world == 1, "killer credited with the killing blow")
check(helper and helper.assists.world == 1, "other attacker gets an assist")
check(ns.db.players["Bystander-MyRealm"] == nil, "bystander not involved")
check(bully and bully.list ~= nil and helper.list == nil, "killer auto-added to Kill List, assister not (default)")
check(bully and bully.guild == "Gankers", "killer's guild remembered")
local d = ns.db.deaths[1]
local why = table.concat(d.reasons, " | ")
print("    why> " .. why)
check(d.killerLevel == 30 and d.myLevel == 20, "levels stored (30 vs 20)")
check(why:find("10 levels higher", 1, true) ~= nil, "explains level gap")
check(why:find("Outnumbered: 2 enemy players vs you alone", 1, true) ~= nil, "explains outnumbered")
check(why:find("Opportunist: attacked you at ~50% health while you were fighting Murloc Raider, 8s into the fight", 1, true) ~= nil,
    "explains: jumped in at 50% HP while you fought the mob, 8s in")
check(not why:find("You were also fighting NPCs", 1, true), "mob not mentioned twice")
check(d.killerHP == 50 and d.cheap == true and d.killerNPC == "Murloc Raider", "death stores your HP when the killer attacked")
check(bully.cheap == 1, "killer gets a cheap kill")
check(d.assists[1].hp == 25 and d.assists[1].npc == "Murloc Raider", "assister's join HP stored (25%)")
check(d.recap[3].hp == 50 and d.recap[4].hp == 80, "HP before each recap hit stored")
check(bully.list.reason:find("while you were fighting Murloc Raider", 1, true) ~= nil, "Kill List reason mentions the cheap shot")
check(d.kbSpell == "Melee", "killing blow spell stored")
check(chatContains("Killed by Bully (30 Warrior) with Melee"), "death printed to chat")

section("stale recap is not reused")
MOCK.units.nameplate1, MOCK.units.nameplate2, MOCK.units.nameplate3 = nil, nil, nil
MOCK.Advance(60)
MOCK.Fire("PLAYER_DEAD")
MOCK.Advance(5)
check(#ns.db.deaths == 1, "second death with old recap and no enemies not recorded")

section("Kill List alert")
local function alerted()
    local w = MOCK.lastRaidWarning
    MOCK.lastRaidWarning = nil
    return w ~= nil and w:find("Kill List", 1, true) ~= nil
end
enemy("nameplate1", "Player-1-CCC", "Bully", "WARRIOR", 30)
MOCK.lastRaidWarning = nil
MOCK.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check(alerted(), "raid warning when a Kill List player appears")
MOCK.Advance(30)
MOCK.units.mouseover = MOCK.units.nameplate1
MOCK.Fire("UPDATE_MOUSEOVER_UNIT")
MOCK.Fire("PLAYER_TARGET_CHANGED")
check(not alerted(), "no repeat while they stay nearby (nameplate still shown)")
MOCK.units.mouseover = nil
MOCK.Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
MOCK.Advance(3)
MOCK.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check(not alerted(), "no repeat when the nameplate only flickers")
MOCK.Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
MOCK.Advance(15)
MOCK.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check(alerted(), "warns again after walking away and coming back")
MOCK.Fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
MOCK.units.nameplate1 = nil
MOCK.Advance(20)
enemy("nameplate7", "Player-1-CCC", "Bully", "WARRIOR", 30)
MOCK.Fire("NAME_PLATE_UNIT_ADDED", "nameplate7")
check(alerted(), "warns again when they come back on a different nameplate")
MOCK.Fire("NAME_PLATE_UNIT_REMOVED", "nameplate7")
MOCK.units.nameplate7 = nil
-- nameplates turned off: target only
MOCK.Advance(20)
MOCK.units.target = { guid = "Player-1-CCC", name = "Bully", class = "WARRIOR", level = 30, isPlayer = true, enemy = true }
MOCK.Fire("PLAYER_TARGET_CHANGED")
check(alerted(), "warns when seen by target with no nameplate")
MOCK.Advance(30)
MOCK.Fire("PLAYER_TARGET_CHANGED")
check(not alerted(), "no repeat while still targeted within a minute")
MOCK.Advance(70)
MOCK.Fire("PLAYER_TARGET_CHANGED")
check(alerted(), "warns again after a minute unseen")
MOCK.units.target = nil
MOCK.units.nameplate1 = { guid = "Player-1-CCC", name = "Bully", class = "WARRIOR", level = 30, isPlayer = true, enemy = true }

section("revenge kill")
MOCK.Fire("PARTY_KILL", ME, "Player-1-CCC")
check(bully.kills.world == 1 and bully.revenge == 1, "revenge counted")
check(chatContains("REVENGE!"), "revenge announced")

section("pet killing blow with no player damage in recap")
MOCK.units.nameplate1 = nil
enemy("nameplate4", "Player-1-FFF", "Petmaster", "HUNTER", 21, { targetingMe = true })
MOCK.Fire("PLAYER_REGEN_DISABLED")
MOCK.Advance(12)
MOCK.recap = {
    { event = "SWING_DAMAGE", sourceName = "Wolf", sourceGUID = "Pet-0-1-2-3-4-99", amount = 120, currentHP = 0, timestamp = 20 },
}
MOCK.Fire("PLAYER_DEAD")
MOCK.Fire("PLAYER_REGEN_ENABLED")
MOCK.Advance(1)
local pm = ns.db.players["Petmaster-MyRealm"]
check(#ns.db.deaths == 2 and pm and pm.deaths.world == 1, "hunter credited when pet lands the killing blow")
check(table.concat(ns.db.deaths[2].reasons, "|"):find("Killing blow by Wolf", 1, true) ~= nil, "pet killing blow explained")

section("PvE death is not recorded")
MOCK.units.nameplate4 = nil
MOCK.Advance(60)
MOCK.recap = { { event = "SWING_DAMAGE", sourceName = "Defias Pillager", sourceGUID = "Creature-0-1-2-3-4-5", amount = 80, currentHP = 0 } }
MOCK.Fire("PLAYER_DEAD")
MOCK.Advance(1)
check(#ns.db.deaths == 2, "mob death ignored")

section("battleground death with hidden unit names")
MOCK.instanceType, MOCK.zone = "pvp", "Warsong Gulch"
MOCK.units.nameplate5 = { guid = SECRET("Player-2-BBB"), name = SECRET("Flagrunner"), class = "WARRIOR", level = 19, isPlayer = true, enemy = true, targetingMe = true }
MOCK.Fire("PLAYER_REGEN_DISABLED")
MOCK.Advance(2)
MOCK.recap = {
    { event = "SPELL_DAMAGE", sourceName = "Flagrunner-OtherRealm", spellName = "Execute", amount = 500, currentHP = 0 },
    { event = "SPELL_DAMAGE", sourceName = "Randomguy-OtherRealm", spellName = "Shadow Bolt", amount = 300, currentHP = 500 },
}
local okBG = pcall(MOCK.Fire, "PLAYER_DEAD")
MOCK.Fire("PLAYER_REGEN_ENABLED")
MOCK.Advance(1)
check(okBG, "no errors with secret unit values")
check(fr.deaths.bg == 1 and fr.list == nil, "BG killer credited (BG kills don't auto-list by default)")
local rg = ns.db.players["Randomguy-OtherRealm"]
check(rg and rg.assists.bg == 1, "BG assist from recap name")
local bgd = ns.db.deaths[#ns.db.deaths]
local bgwhy = table.concat(bgd.reasons, " | ")
print("    why> " .. bgwhy)
check(bgwhy:find("Dead 2s after combat started", 1, true) ~= nil, "explains quick death")
check(bgd.killerHP == 50 and not bgd.cheap, "HP noted; second attacker after another player is not a cheap shot")
MOCK.instanceType, MOCK.zone = nil, nil
MOCK.units.nameplate5 = nil

section("already hurt, no mob: player opens on you at 40% HP")
enemy("nameplate6", "Player-1-HHH", "Vulture", "ROGUE", 21, { targetingMe = true })
MOCK.Advance(60)
MOCK.Fire("PLAYER_REGEN_DISABLED")
MOCK.Advance(4)
MOCK.recap = {
    { event = "SPELL_DAMAGE", sourceName = "Vulture", spellName = "Eviscerate", amount = 200, currentHP = 0 },
    { event = "SPELL_DAMAGE", sourceName = "Vulture", spellName = "Ambush", amount = 200, currentHP = 200 },
}
MOCK.Fire("PLAYER_DEAD")
MOCK.Fire("PLAYER_REGEN_ENABLED")
MOCK.Advance(1)
local vd = ns.db.deaths[#ns.db.deaths]
print("    why> " .. table.concat(vd.reasons, " | "))
check(vd.killerHP == 40 and vd.cheap, "short recap covers the whole fight: 40% HP and a cheap shot")
check(table.concat(vd.reasons, "|"):find("Opportunist: attacked you when you were already hurt (~40% health)", 1, true) ~= nil,
    "explains: already hurt")
MOCK.units.nameplate6 = nil

section("recap cut short: HP unknown")
enemy("nameplate6", "Player-1-JJJ", "Longfight", "WARRIOR", 22, { targetingMe = true })
MOCK.Advance(60)
MOCK.Fire("PLAYER_REGEN_DISABLED")
MOCK.Advance(20)
MOCK.recap = {
    { event = "SWING_DAMAGE", sourceName = "Longfight", amount = 100, currentHP = 0 },
    { event = "SWING_DAMAGE", sourceName = "Longfight", amount = 100, currentHP = 100 },
    { event = "SWING_DAMAGE", sourceName = "Longfight", amount = 100, currentHP = 200 },
    { event = "SWING_DAMAGE", sourceName = "Longfight", amount = 100, currentHP = 300 },
}
MOCK.Fire("PLAYER_DEAD")
MOCK.Fire("PLAYER_REGEN_ENABLED")
MOCK.Advance(1)
local ld = ns.db.deaths[#ns.db.deaths]
check(ld.killer == "Longfight-MyRealm" and ld.killerHP == nil and not ld.cheap and not ld.engage, "full-length recap from one player: HP left unknown, not called cheap")
MOCK.units.nameplate6 = nil

---------------------------------------------------------------------------
section("tooltip")
GameTooltip._lines = {}
MOCK.tooltipPostCall(GameTooltip, { guid = "Player-1-CCC" })
local tt = table.concat(GameTooltip._lines, "\n")
print("    tooltip>\n      " .. tt:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("\n", "\n      "))
check(tt:find("They killed you", 1, true) and tt:find("KILL LIST", 1, true), "tooltip shows stats and Kill List")
GameTooltip._lines = {}
MOCK.tooltipPostCall(GameTooltip, { guid = SECRET("Player-1-CCC") })
check(#GameTooltip._lines == 0, "secret tooltip guid handled")
GameTooltip._lines = {}
MOCK.tooltipPostCall(GameTooltip, { guid = "Player-1-ZZZ" })
check(#GameTooltip._lines == 0, "unknown player gets no lines")

---------------------------------------------------------------------------
section("slash commands")
local function slash(msg) print("  /kls " .. msg); SlashCmdList.KILLLISTSTATS(msg) end
slash("stats")
check(lastChat():find("Kills 6 (world 4, BG 1)", 1, true) == nil and chatContains("Kills"), "stats printed")
slash("who bully")
check(chatContains("They killed you 1 time ("), "who lookup is case-insensitive")
slash("top")
slash("nemesis")
slash("add Somebody camps the flight path")
local sb = ns.db.players["Somebody-MyRealm"]
check(sb and sb.list and sb.list.note == "camps the flight path", "manual add with note")
slash("note Bully always at the crossroads")
check(bully.list.note == "always at the crossroads", "note command")
slash("remove Somebody")
check(sb.list == nil, "remove command")
slash("window 25")
check(ns.db.settings.assistWindow == 25, "assist window command")
slash("recap")
slash("help")
enemy("target", "Player-1-GGG", "Targetguy", "MAGE", 18)
slash("add")
check(ns.db.players["Targetguy-MyRealm"] and ns.db.players["Targetguy-MyRealm"].list, "add current target")

---------------------------------------------------------------------------
section("window")
local okUI, err = pcall(function()
    slash("")
    local UI = ns.UI
    check(UI.frame and UI.frame:IsShown(), "window opens")
    for tab = 1, 5 do
        UI:SelectTab(tab)
        local page = UI.pages[tab]
        if page.list then
            print(string.format("    tab %d rows: %d", tab, #page.list))
            -- exercise every column's text and sort function
            for _, col in ipairs(page.columns) do
                if col.sort then page:SetSort(col.key); page:SetSort(col.key) end
            end
            if page.onEnter and page.list[1] then page.onEnter(page.list[1]) end
            -- print the rendered table
            local header = {}
            for _, col in ipairs(page.columns) do header[#header + 1] = col.title end
            print("      | " .. table.concat(header, " | "))
            for i = 1, math.min(page.scrollBox._count or 0, 4) do
                local cells = {}
                for _, fs in ipairs(page.scrollBox._rows[i].cells) do
                    cells[#cells + 1] = (fs:GetText() or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "")
                end
                print("      | " .. table.concat(cells, " | "))
            end
        end
    end
    check(#UI.pages[1].list == 3, "Kills tab lists 3 victims")
    check(#UI.pages[2].list == 5, "Deaths tab lists 5 deaths")
    check(#UI.pages[3].list >= 2, "Kill List tab lists listed players")
    check(#UI.pages[4].list >= 3, "Classes tab lists classes")
    print("    summary> " .. UI.summary:GetText():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
    -- selection + buttons
    UI:SelectTab(1)
    local rows = UI.pages[1].scrollBox._rows
    rows[1]:Click()
    UI.buttons.add:Click()
    UI:SelectTab(3)
    UI.pages[3].scrollBox._rows[1]:Click()
    UI.buttons.note:Click()
    check(#MOCK.popups > 0 and MOCK.popups[#MOCK.popups].which == "KILLLISTSTATS_NOTE", "note popup opens")
    UI.buttons.remove:Click()
    UI.search:SetText("bully")
    UI.search._scripts.OnTextChanged(UI.search)
    MOCK.Advance(1)
    UI:SelectTab(1)
    check(#UI.pages[1].list == 1, "search filters rows")
    UI:SelectTab(5)
    UI.pages[5].checks[1]:SetChecked(false)
    UI.pages[5].checks[1]:Click()
    check(ns.db.settings.printKills == false, "option checkbox saves")
    KillListStats_OnAddonCompartmentClick()
    check(not UI.frame:IsShown(), "compartment click toggles window")
    KillListStats_OnAddonCompartmentClick()
    UI.frame.CloseButton:Click()
    check(not UI.frame:IsShown(), "close button hides window")
end)
check(okUI, "UI code ran without errors" .. (okUI and "" or (": " .. tostring(err))))

---------------------------------------------------------------------------
-- Kill detection: killing blows by others, honorable kills, damage meter
---------------------------------------------------------------------------
ns.db.settings.printKills = true
local function kills(key) local p = ns.db.players[key]; return p and ns.Total(p.kills) or 0 end
local function lastKill() return ns.db.kills[#ns.db.kills] end
local function clearUnits()
    for u in pairs(MOCK.units) do if u ~= "player" then MOCK.units[u] = nil end end
end
local function victim(guid, name, class, level, realm)
    MOCK.guidInfo[guid] = { name = name, class = class, className = class, race = "Orc", level = level, realm = realm or "" }
end
clearUnits()
MOCK.Advance(30)

section("migration: old kills become solo kills with your own killing blow")
local old = {
    version = 1,
    players = { ["Old-MyRealm"] = { name = "Old", realm = "MyRealm", kills = { world = 2, bg = 1 }, deaths = { world = 0, bg = 0 }, assists = { world = 0, bg = 0 } } },
    kills = { { t = 1, key = "Old-MyRealm", ctx = "world" }, { t = 2, key = "Old-MyRealm", ctx = "world", pet = true }, { t = 3, key = "Old-MyRealm", ctx = "bg" } },
    deaths = {},
}
ns:Migrate(old)
check(old.version == 2, "data upgraded to version 2")
check(old.kills[1].blow == "me" and old.kills[2].blow == "pet" and old.kills[3].group == "solo" and old.kills[3].gsize == 1,
    "old kills: your (or your pet's) killing blow, solo")
check(old.players["Old-MyRealm"].kb == 3 and old.players["Old-MyRealm"].solo == 3, "old player totals: all your killing blows, all solo")
check(ns.DeathGroup({ ctx = "world", group = 3 }) == "party" and ns.DeathGroup({ ctx = "bg", group = 15 }) == "solo",
    "old deaths: world group size kept, battleground raid counts as solo")

section("party member lands the killing blow (world, you in combat)")
MOCK.group = 3
MOCK.units.party1 = { guid = "Player-1-BUD", name = "Buddy", isPlayer = true }
MOCK.units.party2 = { guid = "Player-1-PAL", name = "Pal", isPlayer = true }
MOCK.units.partypet1 = { guid = "Pet-0-1-2-3-4-55", name = "Fluffy" }
victim("Player-1-KA1", "Partyvictim", "MAGE", 21)
MOCK.Fire("PLAYER_REGEN_DISABLED")
MOCK.Fire("PARTY_KILL", "Player-1-BUD", "Player-1-KA1")
check(kills("Partyvictim-MyRealm") == 0, "a group kill waits a moment for more signals")
MOCK.Advance(2)
local pv = ns.db.players["Partyvictim-MyRealm"]
local e = lastKill()
check(pv and pv.kills.world == 1, "party member's killing blow counted (you were in the fight)")
check(e.blow == "party" and e.blowBy == "Buddy", "kill log: Buddy landed the killing blow")
check(e.group == "party" and e.gsize == 3 and e.with and #e.with == 2, "kill log: party of 3, with Buddy and Pal")
check(pv.kb == 0 and pv.solo == 0, "not your killing blow, not solo")
check(chatContains("killing blow: Buddy (party) [party of 3]"), "chat says who landed the killing blow and your group")

section("party member's pet lands the killing blow")
victim("Player-1-KA2", "Petvictim", "MAGE", 21)
MOCK.Fire("PARTY_KILL", "Pet-0-1-2-3-4-55", "Player-1-KA2")
MOCK.Advance(2)
e = lastKill()
check(e.key == "Petvictim-MyRealm" and e.blow == "party" and e.blowBy == "Buddy" and e.blowPet, "party pet's killing blow credited to Buddy's pet")
check(ns.BlowText(e) == "Buddy's pet (party)", "shown as \"Buddy's pet (party)\"")

section("your own killing blow while grouped")
victim("Player-1-KA3", "Ownvictim", "ROGUE", 20)
MOCK.Fire("PARTY_KILL", ME, "Player-1-KA3")
e = lastKill()
local ov = ns.db.players["Ownvictim-MyRealm"]
check(e.key == "Ownvictim-MyRealm" and e.blow == "me" and e.group == "party", "own killing blow counted at once, with your party")
check(ov.kb == 1 and ov.solo == 0, "your killing blow, not solo")
MOCK.Fire("PLAYER_REGEN_ENABLED")
MOCK.group = nil
clearUnits()
MOCK.Advance(10)

section("solo: your totem lands the killing blow")
victim("Player-1-KA4", "Totemvictim", "WARRIOR", 22)
MOCK.Fire("PARTY_KILL", "Creature-0-1-2-3-2523-77", "Player-1-KA4")
MOCK.Advance(2)
e = lastKill()
check(e.key == "Totemvictim-MyRealm" and e.blow == "summon" and ns.IsOwnBlow(e), "solo totem/summon kill counts as your killing blow")
check(chatContains("[totem/summon]"), "chat marks the totem kill")

section("solo: they fought you, then a guard finished them")
enemy("nameplate1", "Player-1-KA5", "Guardbait", "ROGUE", 24, { targetingMe = true })
MOCK.Fire("PLAYER_REGEN_DISABLED")
MOCK.Fire("UNIT_TARGET", "nameplate1")
MOCK.Advance(5)
MOCK.units.nameplate1.dead = true
MOCK.Fire("UNIT_DIED", "Player-1-KA5")
MOCK.Advance(2)
e = lastKill()
check(e.key == "Guardbait-MyRealm" and e.blow == "other" and e.how:find("fought", 1, true) ~= nil,
    "enemy who fought you and died to an NPC counts (killing blow: NPC / other)")
check(ns.db.players["Guardbait-MyRealm"].kb == 0 and ns.db.players["Guardbait-MyRealm"].solo == 1, "solo, but not your killing blow")
check(chatContains("killing blow: an NPC or the environment"), "chat explains the NPC killing blow")
MOCK.Fire("PLAYER_REGEN_ENABLED")
MOCK.Advance(2)
clearUnits()

section("Feign Death is not a kill")
enemy("nameplate2", "Player-1-KA6", "Fakedeath", "HUNTER", 23, { targetingMe = true, feign = true })
MOCK.Fire("UNIT_TARGET", "nameplate2")
MOCK.Fire("UNIT_DIED", "Player-1-KA6")
MOCK.Advance(2)
check(kills("Fakedeath-MyRealm") == 0, "hunter feigning death not counted")
clearUnits()

section("solo: an enemy dies nearby, the damage meter shows your damage")
enemy("nameplate3", "Player-1-KA7", "Meterguy", "MAGE", 22)
MOCK.Fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
MOCK.Fire("PLAYER_REGEN_DISABLED")
MOCK.units.nameplate3.dead = true
MOCK.Fire("UNIT_DIED", "Player-1-KA7")
MOCK.Advance(2)
check(kills("Meterguy-MyRealm") == 0, "waits for combat to end to read the damage meter")
MOCK.meter = { combatSources = { { sourceGUID = "Player-1-KA7", name = "Meterguy", totalAmount = 900 } } }
MOCK.Fire("PLAYER_REGEN_ENABLED")
MOCK.Advance(2)
e = lastKill()
check(kills("Meterguy-MyRealm") == 1 and e.how:find("meter", 1, true) ~= nil, "counted once the damage meter shows your damage on them")

section("solo: an enemy dies nearby, no damage from you")
enemy("nameplate4", "Player-1-KA8", "Stranger", "MAGE", 22)
MOCK.Fire("NAME_PLATE_UNIT_ADDED", "nameplate4")
MOCK.meter = { combatSources = {} }
MOCK.Fire("PLAYER_REGEN_DISABLED")
MOCK.units.nameplate4.dead = true
MOCK.Fire("UNIT_DIED", "Player-1-KA8")
MOCK.Advance(2)
MOCK.Fire("PLAYER_REGEN_ENABLED")
MOCK.Advance(2)
check(kills("Stranger-MyRealm") == 0, "not counted when the damage meter shows no damage from you")
clearUnits()

section("honorable kill message")
COMBATLOG_HONORGAIN = "%s dies, honorable kill Rank: %s (Estimated Honor Points: %d)"
enemy("nameplate5", "Player-1-KA9", "Honorguy", "WARRIOR", 25)
MOCK.Fire("NAME_PLATE_UNIT_ADDED", "nameplate5")
MOCK.units.nameplate5 = nil
MOCK.Fire("CHAT_MSG_COMBAT_HONOR_GAIN", "Honorguy dies, honorable kill Rank: Private (Estimated Honor Points: 12)")
MOCK.Advance(2)
e = lastKill()
check(e.key == "Honorguy-MyRealm" and e.how:find("honor", 1, true) ~= nil and e.blow == "other",
    "honorable kill counted without a killing-blow event")
check(ns.ParseHonorMessage("Someone-Other Realm dies, honorable kill (Estimated Honor Points: 5)") == "Someone-Other Realm",
    "parses the honor line without a rank, with a realm")
check(ns.PatternFromFormat("%s dies, honorable kill Rank: %s (%d)") == "^(.-) dies, honorable kill Rank: ", "honor pattern built from the game's string")

section("honorable kill counter")
enemy("nameplate6", "Player-1-KB1", "Countme", "ROGUE", 21)
MOCK.Fire("NAME_PLATE_UNIT_ADDED", "nameplate6")
MOCK.units.nameplate6.dead = true
MOCK.Fire("UNIT_DIED", "Player-1-KB1")
MOCK.hk = MOCK.hk + 1
MOCK.Fire("PLAYER_PVP_KILLS_CHANGED", "player")
MOCK.Advance(2)
check(kills("Countme-MyRealm") == 1, "the honorable kill counter going up credits the death that just happened")

section("your own kill's honor tick is not given to another death")
victim("Player-1-KB2", "Minekill", "MAGE", 21)
enemy("nameplate7", "Player-1-KB3", "Bystander2", "MAGE", 21)
MOCK.Fire("NAME_PLATE_UNIT_ADDED", "nameplate7")
MOCK.Fire("PARTY_KILL", ME, "Player-1-KB2")
MOCK.hk = MOCK.hk + 1
MOCK.Fire("PLAYER_PVP_KILLS_CHANGED", "player")
MOCK.units.nameplate7.dead = true
MOCK.Fire("UNIT_DIED", "Player-1-KB3")
MOCK.Advance(2)
check(kills("Minekill-MyRealm") == 1 and kills("Bystander2-MyRealm") == 0, "honor tick goes to your own kill, not the bystander")
clearUnits()

section("battleground: name hidden until the match ends")
MOCK.instanceType, MOCK.zone, MOCK.bgRaid = "pvp", "Arathi Basin", 15
MOCK.Fire("PARTY_KILL", ME, "Player-3-BG1")
MOCK.Advance(5)
check(#ns.db.unresolved == 1, "kill kept until the name is known")
check(chatContains("whose name the game is hiding"), "chat says the kill is added later")
MOCK.score = { ["Player-3-BG1"] = { name = "Hiddenname-Far Realm", classToken = "MAGE", raceName = "Gnome" } }
MOCK.Fire("PVP_MATCH_COMPLETE")
MOCK.Advance(2)
local hn = ns.db.players["Hiddenname-FarRealm"]
check(hn and hn.kills.bg == 1 and hn.kb == 1 and hn.class == "MAGE" and #ns.db.unresolved == 0,
    "named from the scoreboard when the match ends, counted as a BG kill")
check(chatContains("(from earlier in the match)"), "chat marks the late kill")

section("battleground: a teammate's killing blow needs proof you fought")
MOCK.units.raid1 = { guid = "Player-1-TM1", name = "Teammate", isPlayer = true }
victim("Player-3-BG2", "Farfighter", "ROGUE", 24, "Far Realm")
MOCK.Fire("PLAYER_REGEN_DISABLED")
MOCK.Fire("PARTY_KILL", "Player-1-TM1", "Player-3-BG2")
MOCK.Advance(2)
check(kills("Farfighter-FarRealm") == 0, "teammate's kill on someone you never fought: not yours")
enemy("nameplate1", "Player-3-BG3", "Duelist", "WARRIOR", 25, { targetingMe = true, realmInfo = "Far Realm" })
MOCK.Fire("UNIT_TARGET", "nameplate1")
MOCK.Fire("PARTY_KILL", "Player-1-TM1", "Player-3-BG3")
MOCK.Advance(2)
e = lastKill()
check(e.key == "Duelist-FarRealm" and e.blow == "team" and e.blowBy == "Teammate" and e.group == "solo" and e.ctx == "bg",
    "teammate's kill on someone fighting you counts: killing blow Teammate (team), you solo")
MOCK.Fire("PLAYER_REGEN_ENABLED")
MOCK.Advance(2)
MOCK.instanceType, MOCK.zone, MOCK.bgRaid = nil, nil, nil
clearUnits()

section("shared kills can be turned off")
ns.db.settings.countSharedKills = false
enemy("nameplate2", "Player-1-KB4", "Offswitch", "ROGUE", 21, { targetingMe = true })
MOCK.Fire("UNIT_TARGET", "nameplate2")
MOCK.units.nameplate2.dead = true
MOCK.Fire("UNIT_DIED", "Player-1-KB4")
MOCK.Advance(2)
check(kills("Offswitch-MyRealm") == 0, "kill finished by an NPC not counted when the option is off")
ns.db.settings.countSharedKills = true
clearUnits()

section("an enemy who only clicked you while you were out of combat")
MOCK.Advance(10)
enemy("nameplate3", "Player-1-KB5", "Clicker", "MAGE", 21, { targetingMe = true })
MOCK.Fire("UNIT_TARGET", "nameplate3")
MOCK.units.nameplate3.dead = true
MOCK.Fire("UNIT_DIED", "Player-1-KB5")
MOCK.Advance(2)
check(kills("Clicker-MyRealm") == 0, "not counted: you were not in combat when they died")
clearUnits()

section("buddies command and tooltip")
SlashCmdList.KILLLISTSTATS("buddies")
check(chatContains("Kill buddies") and chatContains("Buddy - 3") and chatContains("1. Buddy - 2"),
    "buddies lists who you killed with, and who took the killing blows")
GameTooltip._lines = {}
MOCK.tooltipPostCall(GameTooltip, { guid = "Player-1-KA1" })
check(table.concat(GameTooltip._lines, "\n"):find("your killing blows / solo", 1, true) ~= nil, "tooltip shows killing blows / solo when someone else finished them")

---------------------------------------------------------------------------
section("filters and the every-kill view")
local okF, errF = pcall(function()
    local F, UI = ns.Filters, ns.UI
    UI.search:SetText("")
    UI.search._scripts.OnTextChanged(UI.search)
    MOCK.Advance(1)
    SlashCmdList.KILLLISTSTATS("kills")
    check(UI.frame:IsShown() and UI.tab == 1, "Kills tab open")
    local all = #UI.pages[1].list
    print("    players with kills: " .. all)
    F.Set("group", "solo")
    check(#UI.pages[1].list == all - 3, "Solo filter hides the 3 players killed while grouped")
    check(UI.status:GetText():find("Solo", 1, true) ~= nil, "status line names the active filter")
    check(UI.summary:GetText():find("Filtered", 1, true) ~= nil, "summary marks filtered totals")
    F.Set("group", "all")
    F.Set("blow", "party")
    check(#UI.pages[1].list == 2, "Killing blow = your party: Partyvictim and Petvictim")
    F.Reset()
    F.Set("where", "bg")
    check(#UI.pages[1].list == 3, "Battlegrounds: Flagrunner, Hiddenname, Duelist")
    F.Reset()
    check(#UI.pages[1].list == all, "clearing filters shows everyone again")

    -- the menu
    local menu = MOCK.NewMenu()
    UI.filterButton._menu(UI.filterButton, menu)
    check(menu:Find("Quick picks") and menu:Find("Killing blow") and menu:Find("Revenge kills only"), "filter menu built")
    menu:Find("Battlegrounds").b()
    check(F.State().where == "bg", "menu radio sets a filter")
    check(UI.filterButton._isDefault() == false, "filter button shows its reset X")
    UI.filterButton._default()
    check(F.IsDefault(), "reset X clears the filters")
    menu:Find("Solo killing blows").a()
    check(F.State().group == "solo" and F.State().blow == "mine", "quick pick sets several filters at once")
    menu = MOCK.NewMenu()
    UI.filterButton._menu(UI.filterButton, menu)
    check(menu:Find("Your group: Solo") ~= nil, "submenu title shows the current choice")
    menu:Find("Clear all filters").a()
    check(F.IsDefault(), "Clear all filters")

    -- every kill
    UI.viewButton:Click()
    check(UI:CurrentPage() == UI.killLog and UI.killLog:IsShown() and not UI.pages[1]:IsShown(), "view button switches to every kill")
    check(#UI.killLog.list == #ns.db.kills, "every kill view lists every kill")
    local log = UI.killLog
    for _, col in ipairs(log.columns) do
        if col.sort then log:SetSort(col.key); log:SetSort(col.key) end
    end
    log:SetSort("time")
    if log.sortAsc then log:SetSort("time") end
    log.onEnter(log.list[1])
    local header = {}
    for _, col in ipairs(log.columns) do header[#header + 1] = col.title end
    print("      | " .. table.concat(header, " | "))
    for i = 1, math.min(log.scrollBox._count or 0, 8) do
        local cells = {}
        for _, fs in ipairs(log.scrollBox._rows[i].cells) do
            cells[#cells + 1] = (fs:GetText() or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        end
        print("      | " .. table.concat(cells, " | "))
    end
    F.Set("blow", "notmine")
    local helped = #log.list
    check(helped == 7, "Anyone but you: 7 kills you only helped with (got " .. helped .. ")")
    F.Reset()
    log.scrollBox._rows[1]:Click()
    UI.buttons.add:Click()
    UI.viewButton:Click()
    check(UI:CurrentPage() == UI.pages[1], "view button switches back to by player")

    -- deaths and classes follow the filters
    UI:SelectTab(2)
    F.Set("where", "bg")
    check(#UI.pages[2].list == 1, "deaths filtered to battlegrounds")
    F.Set("blow", "mine")
    check(UI.status:GetText():find("only apply to kills", 1, true) ~= nil, "Deaths tab explains kill-only filters")
    F.Reset()
    UI:SelectTab(4)
    F.Set("blow", "mine")
    local mageMine
    for _, r in ipairs(UI.pages[4].list) do if r.class == "MAGE" then mageMine = r end end
    check(mageMine and mageMine.total == mageMine.kb, "classes count only your killing blows when filtered")
    F.Reset()
    UI:SelectTab(3)
    check(not UI.filterButton:IsShown(), "no filter button on the Kill List tab")

    -- predicates
    local s = F.State()
    s.time = "week"
    local since = select(2, F.Begin())
    check(F.Kill({ t = time() - 10 * 86400 }, s, since) == false and F.Kill({ t = time() }, s, since) == true, "Last 7 days")
    F.Reset()
    check(F.LevelBucket(25, nil, 20) == "higher" and F.LevelBucket(21, nil, 20) == "even" and F.LevelBucket(10, nil, 20) == "lower"
        and F.LevelBucket(nil, true, 20) == "higher", "level buckets")
    check(#F.Characters() >= 1, "characters listed")
    SlashCmdList.KILLLISTSTATS("filter")
    check(F.IsDefault(), "/kls filter clears filters")
    SlashCmdList.KILLLISTSTATS("log")
    check(UI:CurrentPage() == UI.killLog, "/kls log opens every kill")
    UI.frame:Hide()
end)
check(okF, "filter UI ran without errors" .. (okF and "" or (": " .. tostring(errF))))

section("reset")
StaticPopupDialogs.KILLLISTSTATS_RESET.OnAccept()
check(next(ns.db.players) == nil and #ns.db.deaths == 0, "reset wipes data")

print(string.format("\n%d passed, %d failed", passed, failed))
TEST_FAILED = failed
