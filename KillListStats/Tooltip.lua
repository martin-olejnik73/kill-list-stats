-- Kill List Stats - Tooltips
-- Adds your history with a player to their unit tooltip.

local _, ns = ...

local GREEN, RED, GOLD, GREY = "|cff40ff40", "|cffff4040", "|cffffd100", "|cffaaaaaa"

-- Adds stat lines for player record p to tooltip tt.
-- detailed = true adds extra lines (used by the main window).
function ns.AddPlayerLines(tt, p, detailed)
    local kills, deaths, assists = ns.Total(p.kills), ns.Total(p.deaths), ns.Total(p.assists)

    if kills > 0 then
        tt:AddDoubleLine(GREEN .. "You killed them|r",
            string.format("%d  " .. GREY .. "(%d world / %d BG)|r", kills, p.kills.world or 0, p.kills.bg or 0),
            1, 1, 1, 1, 1, 1)
    end
    if deaths > 0 or assists > 0 then
        local right = string.format("%d", deaths)
        if deaths > 0 then
            right = right .. string.format("  " .. GREY .. "(%d world / %d BG)|r", p.deaths.world or 0, p.deaths.bg or 0)
        end
        tt:AddDoubleLine(RED .. "They killed you|r", right, 1, 1, 1, 1, 1, 1)
        if assists > 0 then
            tt:AddDoubleLine(RED .. "Assisted on your deaths|r", tostring(assists), 1, 1, 1, 1, 1, 1)
        end
    end
    if p.list then
        local text = p.list.note or p.list.reason or "on your Kill List"
        tt:AddLine(RED .. "KILL LIST|r " .. GREY .. "- " .. text .. "|r", 1, 1, 1, true)
        if (p.revenge or 0) > 0 then
            tt:AddDoubleLine(GOLD .. "Revenge kills|r", tostring(p.revenge), 1, 1, 1, 1, 1, 1)
        end
    end
    if detailed then
        if p.guild then tt:AddDoubleLine("Guild", "<" .. p.guild .. ">", 0.7, 0.7, 0.7, 1, 1, 1) end
        if p.lastKill then tt:AddDoubleLine("Last killed", ns.FormatAgo(p.lastKill) .. (p.lastKillZone and (" in " .. p.lastKillZone) or ""), 0.7, 0.7, 0.7, 1, 1, 1) end
        if p.lastDeath then tt:AddDoubleLine("Last killed you", ns.FormatAgo(p.lastDeath) .. (p.lastDeathZone and (" in " .. p.lastDeathZone) or ""), 0.7, 0.7, 0.7, 1, 1, 1) end
        if p.lastDeathText and p.lastDeathText ~= "" then
            tt:AddLine(GREY .. "Why: " .. p.lastDeathText .. "|r", 1, 1, 1, true)
        end
        if p.lastSeen then tt:AddDoubleLine("Last seen", ns.FormatAgo(p.lastSeen) .. (p.lastSeenZone and (" in " .. p.lastSeenZone) or ""), 0.7, 0.7, 0.7, 1, 1, 1) end
    end
end

local function OnTooltipSetUnit(tooltip, data)
    if tooltip ~= GameTooltip or not ns.db or not ns.db.settings.tooltip then return end

    local p
    local guid = data and ns.PlainString(data.guid)
    if guid then
        if not ns.IsPlayerGUID(guid) then return end
        p = ns:FindPlayerByGUID(guid)
    end
    if not p then
        local _, unit = ns.Try(tooltip.GetUnit, tooltip)
        unit = ns.PlainString(unit)
        if not unit or not UnitIsPlayer(unit) then return end
        local name, realm = ns.Try(UnitName, unit)
        name = ns.PlainString(name)
        if not name then return end
        p = ns.db.players[ns.MakeKey(name, realm)]
    end
    if not p then return end

    if ns.Total(p.kills) + ns.Total(p.deaths) + ns.Total(p.assists) == 0 and not p.list then return end
    ns.AddPlayerLines(tooltip, p, false)
    tooltip:Show()
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
        pcall(OnTooltipSetUnit, tooltip, data)
    end)
elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetUnit", function(tooltip)
        pcall(OnTooltipSetUnit, tooltip, nil)
    end)
end
