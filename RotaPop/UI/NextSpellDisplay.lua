-- NextSpellDisplay.lua
Rotapop = Rotapop or {}
Rotapop.UI = Rotapop.UI or {}

-- ============================================================
-- Combat time tracking — exposed as Rotapop.getCombatTime()
-- Used by APL conditions that need time<N checks.
-- ============================================================
local combatStartTime = 0

Rotapop.EventBus:Subscribe("PLAYER_REGEN_DISABLED", function()
    combatStartTime = GetTime()
end)

Rotapop.EventBus:Subscribe("PLAYER_REGEN_ENABLED", function()
    combatStartTime = 0
end)

--- Returns seconds elapsed since entering combat (0 if out of combat).
function Rotapop.getCombatTime()
    if combatStartTime == 0 then return 0 end
    return GetTime() - combatStartTime
end

local Display = {}
Rotapop.UI.NextSpellDisplay = Display

local frame = CreateFrame("Frame", "RotapopNextSpellFrame", UIParent)
frame:SetSize(64, 64)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, -120)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

local icon = frame:CreateTexture(nil, "BACKGROUND")
icon:SetAllPoints()
icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

local cdOverlay = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
cdOverlay:SetAllPoints()

local border = frame:CreateTexture(nil, "OVERLAY")
border:SetAllPoints()
border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
border:SetBlendMode("ADD")

local function getUnitState()
    return {
        resources = {
            mana   = UnitPower("player", Enum.PowerType.Mana)   or 0,
            rage   = UnitPower("player", Enum.PowerType.Rage)   or 0,
            energy = UnitPower("player", Enum.PowerType.Energy) or 0,
        },
        buffs   = {},
        debuffs = {},
    }
end

-- Track last displayed spell to avoid redundant texture swaps
local lastSpellID = nil
local lastReady   = nil

function Display:Update()
    local ok, nextSpell, isReady = pcall(
        Rotapop.SimEngine.GetNextSpell,
        Rotapop.SimEngine,
        getUnitState()
    )

    -- pcall returns: ok, retval1, retval2
    -- If the engine doesn't return isReady (e.g. old DefaultPriority), default to true
    if ok and nextSpell then
        if isReady == nil then isReady = true end
    end

    -- C_AssistedCombat fallback: when SimEngine returns nothing, ask
    -- Blizzard's built-in rotation helper before giving up.
    if ok and not nextSpell then
        local acSpell = Rotapop.AssistedCombat:GetNextCastSpell()
        if acSpell then
            nextSpell = acSpell
            isReady   = true
        else
            -- Try first spell from the rotation list
            local acSpells = Rotapop.AssistedCombat:GetRotationSpells()
            if acSpells and #acSpells > 0 then
                nextSpell = acSpells[1]
                isReady   = false
            end
        end
    end

    if not ok or not nextSpell then
        if lastSpellID ~= nil then
            icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            icon:SetDesaturated(false)
            icon:SetVertexColor(1, 1, 1, 1)
            cdOverlay:Clear()
            lastSpellID = nil
            lastReady   = nil
        end
        return
    end

    -- Update icon texture only when spell changes
    if nextSpell ~= lastSpellID then
        local iconTexture
        local infoOk, spellInfo = pcall(C_Spell.GetSpellInfo, nextSpell)
        if infoOk and spellInfo and spellInfo.iconID then
            iconTexture = spellInfo.iconID
        end
        -- Fallback: C_Spell.GetSpellTexture (more resilient for overridden spells)
        if not iconTexture and C_Spell.GetSpellTexture then
            local texOk, tex = pcall(C_Spell.GetSpellTexture, nextSpell)
            if texOk and tex then
                iconTexture = tex
            end
        end
        icon:SetTexture(iconTexture or "Interface\\Icons\\INV_Misc_QuestionMark")
        lastSpellID = nextSpell
    end

    -- Visual distinction: ready = full color, waiting = desaturated
    if isReady ~= lastReady then
        if isReady then
            icon:SetDesaturated(false)
            icon:SetVertexColor(1, 1, 1, 1)
        else
            icon:SetDesaturated(true)
            icon:SetVertexColor(0.6, 0.6, 0.6, 1)
        end
        lastReady = isReady
    end

    -- Cooldown Overlay
    local state = Rotapop.StateCache:GetState(nextSpell)
    if state
        and state.cooldown.start
        and state.cooldown.duration
        and state.cooldown.duration > 1.5  -- kein GCD-Overlay
    then
        cdOverlay:SetCooldown(state.cooldown.start, state.cooldown.duration)
    else
        cdOverlay:Clear()
    end
end

-- Ticker alle 0.1s
C_Timer.NewTicker(0.1, function()
    Display:Update()
end)

-- Nach Cast sofort updaten
-- UNIT_SPELLCAST_SUCCEEDED → https://warcraft.wiki.gg/wiki/UNIT_SPELLCAST_SUCCEEDED
Rotapop.EventBus:Subscribe("UNIT_SPELLCAST_SUCCEEDED", function(_, unit)
    if unit == "player" then
        -- Kurze Verzögerung damit CD-APIs bereits den neuen State haben
        C_Timer.After(0.05, function()
            Display:Update()
        end)
    end
end)