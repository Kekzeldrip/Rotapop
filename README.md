# Rotapop

**SimC-based rotation assistant for World of Warcraft 12.x**

Rotapop is a Hekili-style rotation addon rebuilt from the ground up to work
with the Cooldown Manager APIs introduced in Patch 11.1.5 and the breaking
changes in Patch 12.0.

## Motivation

The original Hekili addon stopped working after Patch 12.0 because Blizzard:

- Removed or changed classic cooldown APIs
- Moved to a category-based internal cooldown system
- Introduced structured return values (`SpellCooldownInfo`)
- Added new restriction mechanics

Despite these changes the required information is still available in the client.
Rotapop uses the new APIs directly — no workarounds, no legacy wrappers.

## Design

| Layer | Description |
|---|---|
| **CooldownAdapter** | Normalizes spell state via `C_Spell.*` APIs (primary) with optional `C_CooldownViewer.*` enrichment. |
| **AssistedCombatAdapter** | Fallback data source using `C_AssistedCombat` (Blizzard's built-in rotation helper). Queried when the APL cannot determine a spell. |
| **StateCache** | Event-driven cache that refreshes tracked spells on `SPELL_UPDATE_COOLDOWN`, `SPELL_UPDATE_CHARGES`, cast events, and `UNIT_POWER_UPDATE`. |
| **SimEngine** | APL priority engine — evaluates registered actions in priority order and returns the next castable spell. |
| **UI** | Minimal next-spell icon with cooldown overlay; developer debug overlay (enable via `ROTAPOP_DEBUG = true`). |

### No-Legacy Policy

All cooldown and spell state queries go through documented `C_*` namespaced
APIs only. No dependency on removed global functions such as the old
`GetSpellCooldown`.

### Fallback Design

`CooldownAdapter:GetSpellState` uses the following priority:

1. `C_Spell.GetSpellCooldown` — primary cooldown source
   ([docs](https://warcraft.wiki.gg/wiki/API_C_Spell.GetSpellCooldown))
2. `C_Spell.GetSpellCharges` — charge info
   ([docs](https://warcraft.wiki.gg/wiki/API_C_Spell.GetSpellCharges))
3. `C_Spell.IsSpellUsable` — usability check
   ([docs](https://warcraft.wiki.gg/wiki/API_C_Spell.IsSpellUsable))
4. `C_CooldownViewer.GetCooldownViewerCooldownInfo` — **optional** enrichment
   for linked-spell data; only used when available and verified
   ([docs](https://warcraft.wiki.gg/wiki/API_C_CooldownViewer.GetCooldownViewerCooldownInfo))

When the SimEngine APL cannot determine a spell (all passes return nil), the
UI falls back to `C_AssistedCombat`:

5. `C_AssistedCombat.GetNextCastSpell` — Blizzard's built-in rotation
   recommendation; used as ultimate fallback so the icon never shows "?"
6. `C_AssistedCombat.GetRotationSpells` — full rotation spell list; used
   when `GetNextCastSpell` is unavailable

## Quick Reference

| Resource | Link |
|---|---|
| Patch 11.1.5 API Changes | <https://warcraft.wiki.gg/wiki/Patch_11.1.5/API_changes> |
| Patch 12.0.0 API Changes | <https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes> |
| `C_Spell.GetSpellCooldown` | <https://warcraft.wiki.gg/wiki/API_C_Spell.GetSpellCooldown> |
| `C_Spell.GetSpellCharges` | <https://warcraft.wiki.gg/wiki/API_C_Spell.GetSpellCharges> |
| `C_CooldownViewer.GetCooldownViewerCooldownInfo` | <https://warcraft.wiki.gg/wiki/API_C_CooldownViewer.GetCooldownViewerCooldownInfo> |
| `SpellCooldownInfo` Struct | <https://warcraft.wiki.gg/wiki/Struct_SpellCooldownInfo> |
| `SPELL_UPDATE_COOLDOWN` | <https://warcraft.wiki.gg/wiki/SPELL_UPDATE_COOLDOWN> |
| Original Hekili (reference only) | <https://github.com/Hekili/hekili> |

## SimC APL Import

Rotapop can import SimulationCraft action priority lists at runtime.

### Single-line import

```
/rotapop simc actions=stormstrike
/rotapop simc actions+=/lava_lash,if=buff.hot_hand.up
```

### Multi-line import

```
/rotapop simcstart
actions=stormstrike
actions+=/lava_lash,if=buff.hot_hand.up
actions+=/crash_lightning
actions+=/lightning_bolt,if=buff.maelstrom_weapon.stack>=5
/rotapop simcend
```

### Custom spell mappings

If your SimC profile uses spell names not in the default mapping:

```
/rotapop spell my_ability 123456
```

### Supported condition syntax

| SimC Syntax | Example |
|---|---|
| `buff.X.up` / `buff.X.down` | `buff.ascendance.up` |
| `buff.X.remains` | `buff.doom_winds.remains<5` |
| `buff.X.stack` | `buff.maelstrom_weapon.stack>=10` |
| `debuff.X.up` / `debuff.X.remains` | `debuff.flame_shock.remains=0` |
| `cooldown.X.ready` / `cooldown.X.remains` | `cooldown.doom_winds.ready` |
| `talent.X.enabled` | `talent.thorims_invocation.enabled` |
| `active_enemies>N` | `active_enemies>1` |
| `&` (and), `\|` (or), `!` (not) | `buff.ascendance.up&!debuff.flame_shock.up` |

## Installation

Copy the `RotaPop` folder into your WoW `Interface/AddOns` directory.

## Development

Set `ROTAPOP_DEBUG = true` in `Rotapop.lua` to enable the debug overlay that
shows real-time `CooldownAdapter` outputs for all tracked spells.

## License

See repository for license details.
