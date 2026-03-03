-- Rotapop.lua
-- Entry Point.

-- Dev-Flag: auf true setzen für DebugOverlay
ROTAPOP_DEBUG = false

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function()
    -- Lookup-Tabelle initial aufbauen
    Rotapop.CooldownAdapter:RebuildLookup()

    -- Debug: Zeige wie viele Spells gemappt wurden
    if ROTAPOP_DEBUG then
        local count = 0
        for _ in pairs(Rotapop.CooldownAdapter:GetLookupTable()) do
            count = count + 1
        end
        print("|cff00ff00Rotapop|r CooldownViewer gemappt: "
            .. count .. " Spells")
    end

    print("|cff00ff00Rotapop|r loaded. Debug=" .. tostring(ROTAPOP_DEBUG))
end)

-- ============================================================
-- Slash Commands
-- ============================================================
SLASH_ROTAPOP1 = "/rotapop"
SLASH_ROTAPOP2 = "/rp"

SlashCmdList["ROTAPOP"] = function(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^(%S+)%s*(.*)$")
    cmd = cmd and cmd:lower() or ""

    if cmd == "simc" then
        if rest == "" then
            print("|cff00ff00Rotapop|r Usage: /rotapop simc <paste SimC action list>")
            print("|cff00ff00Rotapop|r Example: /rotapop simc actions=stormstrike")
            print("|cff00ff00Rotapop|r Tip: For multi-line profiles, use /rotapop simcstart"
                .. " then /rotapop simc <line> per line, then /rotapop simcend")
            return
        end
        -- Multi-line buffer mode: append line instead of importing directly
        if Rotapop._simcBuffer then
            table.insert(Rotapop._simcBuffer, rest)
            print("|cff00ff00Rotapop|r buffered: " .. rest)
            return
        end
        local ok = Rotapop.SimCParser:ImportAndActivate(rest)
        if not ok then
            print("|cffff0000Rotapop|r SimC import failed. Check spell names.")
        end

    elseif cmd == "simcstart" then
        Rotapop._simcBuffer = {}
        print("|cff00ff00Rotapop|r SimC multi-line mode started."
            .. " Paste your APL lines, then type /rotapop simcend")

    elseif cmd == "simcend" then
        if not Rotapop._simcBuffer then
            print("|cffff0000Rotapop|r No SimC buffer active. Use /rotapop simcstart first.")
            return
        end
        local text = table.concat(Rotapop._simcBuffer, "\n")
        Rotapop._simcBuffer = nil
        local ok = Rotapop.SimCParser:ImportAndActivate(text)
        if not ok then
            print("|cffff0000Rotapop|r SimC import failed. Check spell names.")
        end

    elseif cmd == "debug" then
        ROTAPOP_DEBUG = not ROTAPOP_DEBUG
        print("|cff00ff00Rotapop|r Debug=" .. tostring(ROTAPOP_DEBUG))

    elseif cmd == "spell" then
        -- /rotapop spell name spellID — register a custom spell mapping
        local name, idStr = rest:match("^(%S+)%s+(%d+)$")
        if name and idStr then
            local spellID = tonumber(idStr)
            Rotapop.SimCParser:RegisterSpell(name, spellID)
            print(string.format(
                "|cff00ff00Rotapop|r Registered spell: %s = %d", name, spellID
            ))
        else
            print("|cff00ff00Rotapop|r Usage: /rotapop spell spell_name 12345")
        end

    else
        print("|cff00ff00Rotapop|r commands:")
        print("  /rotapop simc <text>     — import SimC action list (single line)")
        print("  /rotapop simcstart       — start multi-line SimC import")
        print("  /rotapop simcend         — finish multi-line SimC import")
        print("  /rotapop spell <n> <id>  — register spell name → ID mapping")
        print("  /rotapop debug           — toggle debug overlay")
    end
end