-- SimEngine.lua
-- APL-Prioritäts-Engine (SimC-Port).
-- Konsumiert ausschließlich StateCache/CooldownAdapter-Outputs
-- und Ressource-State.
--
-- Interface:
--   SimEngine:GetNextSpell(unitState) → spellID, isReady
--     isReady = true  → spell is castable right now
--     isReady = false → spell is on CD but is the next priority spell (fallback)
--     spellID = nil   → no known spell found at all
--
-- unitState = {
--   resources = { mana, rage, energy, ... },
--   buffs     = { [spellID] = { stacks, expires }, ... },
--   debuffs   = { [spellID] = { stacks, expires }, ... },
-- }

Rotapop = Rotapop or {}
Rotapop.SimEngine = {}

local SE = Rotapop.SimEngine
local SC = Rotapop.StateCache

-- APL-Liste: geordnete Prioritätsliste von Einträgen.
-- Jeder Eintrag: { spellID, condition }
-- condition(unitState, spellState) → bool
-- Wird von APL-Modulen befüllt (z. B. DefaultPriority.lua).
SE.apl = {}

--- Registriere einen APL-Eintrag.
-- @param spellID  number
-- @param condition function(unitState, spellState) → bool
-- @param priority number  Niedrigere Zahl = höhere Priorität
function SE:RegisterAction(spellID, condition, priority)
    -- SpellID im StateCache tracken
    SC:Track(spellID)

    table.insert(self.apl, {
        spellID   = spellID,
        condition = condition,
        priority  = priority or 999,
    })

    -- Sortiere nach Priorität
    table.sort(self.apl, function(a, b)
        return a.priority < b.priority
    end)
end

--- Evaluiert die APL und gibt die nächste castbare SpellID zurück.
-- Two-pass evaluation:
--   Pass 1: IsReady + APL condition → ready spell
--   Pass 2: condition only (ignore CD) → next priority spell as fallback
-- This ensures the UI always shows a meaningful spell instead of "?".
-- @param unitState table  Ressourcen, Buffs, Debuffs
-- @return number|nil  spellID des nächsten Spells oder nil
-- @return bool        true = castable now, false = on cooldown (fallback)
function SE:GetNextSpell(unitState)
    for _, entry in ipairs(self.apl) do
        local spellState = SC:GetState(entry.spellID)

        -- Spell bekannt und grundsätzlich castbar?
        if spellState and spellState.isKnown then
            -- IsReady-Check (Cooldown / Charges)
            local ready = Rotapop.CooldownAdapter:IsReady(entry.spellID)

            if ready then
                -- APL-Condition evaluieren
                local conditionMet = true
                if entry.condition then
                    local ok, result = pcall(entry.condition, unitState, spellState)
                    if ok then
                        conditionMet = result
                    else
                        -- Condition-Fehler → überspringen, nicht crashen
                        conditionMet = false
                    end
                end

                if conditionMet then
                    return entry.spellID, true
                end
            end
        end
    end

    -- Pass 2: Fallback — find the highest priority known spell whose
    -- condition passes but is on cooldown. Shows "what's coming next".
    for _, entry in ipairs(self.apl) do
        if not entry.sublist then
            local spellState = SC:GetState(entry.spellID)
            if spellState and spellState.isKnown then
                local conditionMet = true
                if entry.condition then
                    local ok, result = pcall(entry.condition, unitState, spellState)
                    conditionMet = ok and (result == true)
                end
                if conditionMet then
                    return entry.spellID, false
                end
            end
        end
    end

    -- Pass 3: last resort — return any known spell from the APL
    for _, entry in ipairs(self.apl) do
        if not entry.sublist then
            local spellState = SC:GetState(entry.spellID)
            if spellState and spellState.isKnown then
                return entry.spellID, false
            end
        end
    end

    return nil, false
end