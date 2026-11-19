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
section("world death: killer, assists, explanation")
enemy("nameplate1", "Player-1-CCC", "Bully", "WARRIOR", 30, { targetingMe = true, guild = "Gankers" })
enemy("nameplate2", "Player-1-DDD", "Helper", "MAGE", 25, { targetingMe = true })
enemy("nameplate3", "Player-1-EEE", "Bystander", "HUNTER", 20, { targetingMe = false })
MOCK.Fire("PLAYER_REGEN_DISABLED")
MOCK.Advance(3)
MOCK.recap = {
    { event = "SWING_DAMAGE", sourceName = "Bully", amount = 300, currentHP = 0, timestamp = 10.0 },
    { event = "SPELL_DAMAGE", sourceName = "Helper", spellName = "Frostbolt", amount = 200, currentHP = 300, timestamp = 9.5 },
    { event = "SPELL_DAMAGE", sourceName = "Bully", spellName = "Mortal Strike", amount = 400, currentHP = 500, timestamp = 9.0 },
    { event = "SWING_DAMAGE", sourceName = "Murloc Raider", amount = 50, currentHP = 450, timestamp = 8.0 },
}
MOCK.Fire("PLAYER_DEAD")
MOCK.Fire("PLAYER_REGEN_ENABLED")
MOCK.Advance(1)
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
check(why:find("Murloc Raider", 1, true) ~= nil, "explains NPCs involved")
check(why:find("Dead 3s after combat started", 1, true) ~= nil, "explains quick death")
check(why:find("~50% health", 1, true) ~= nil, "explains low starting health")
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
MOCK.instanceType, MOCK.zone = nil, nil
MOCK.units.nameplate5 = nil

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
    check(#UI.pages[2].list == 3, "Deaths tab lists 3 deaths")
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

section("reset")
StaticPopupDialogs.KILLLISTSTATS_RESET.OnAccept()
check(next(ns.db.players) == nil and #ns.db.deaths == 0, "reset wipes data")

print(string.format("\n%d passed, %d failed", passed, failed))
TEST_FAILED = failed
