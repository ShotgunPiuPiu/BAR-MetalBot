# ShotgunPiuPiu Metal Bot

A [Beyond All Reason](https://www.beyondallreason.info) LuaUI widget that plays
metal maps as an AI teammate. Fork of
[MetalBot](https://github.com/PrivacyIsARight/MetalBot) by **vexalous**, renamed
and heavily modified by **ShotgunPiuPiu**.

## What it does

- Plays metal maps end to end: mexes, energy, factories, units, defenses.
- **Mex chaining** — workers grab the nearest unclaimed metal spot in a chain,
  clustering extractors tightly.
- **Eco strips** — long 2×N wind/solar rows radiating from the base (gated until
  3 mexes + 10 wind), keeping factory exit corridors clear and reclaiming
  anything that blocks them.
- **Unit rush doctrine** — first factory makes exactly 2 constructors before any
  combat units; mass cheap T1 units early, switch to the biggest guns after 60
  army value. Artillery only as a support slice.
- **Air doctrine** — fighters first, no bombers until T3, AA turrets scale with
  own air presence.
- **Defense** — minimum ground turret + AA ring around the base; when the enemy
  pressure is high, turrets are built even through metal stall.
- **Commander never idles** — falls back to a cheap mex or energy when there is
  nothing else to do.
- **AFUS latch** — once the first AFUS is ordered, all new energy goes into
  fusions only.
- **Emergency economy** — stalled resource? Any barely-started construction gets
  switched to producing the missing resource instead.
- **Perimeter behavior** — before the enemy base is scouted, combat units hold a
  stable ring of slots around your base instead of wandering.

## Install

1. Find your BAR data directory:
   `C:\Users\<you>\AppData\Local\Programs\Beyond-All-Reason\data\`
   (Menu → Settings → Open Data Directory in-game).
2. Copy `bot.lua` into `LuaUI\Widgets\` and the `ShotgunMetal\` folder next to it:

   ```
   data\LuaUI\Widgets\bot.lua
   data\LuaUI\Widgets\ShotgunMetal\*.lua
   ```

3. Start a match vs. AI or add the bot as an ally AI — the widget loads
   automatically (`/luaui reload` re-loads it in an already running game).
4. Toggle the overlay with **Ctrl+Shift+U**. Diagnostics are printed to chat/log
   every ~15 s.

## Tuning

All knobs live in `ShotgunMetal/config.lua`. The master one:

| Parameter    | Default | Effect                                                        |
| ------------ | ------- | ------------------------------------------------------------- |
| `AGGRESSION` | `1.5`   | Higher = earlier unit rush, fewer constructors/support builds |

Other notable groups: opening build order, eco strip sizing, mex cluster radius,
factory unit selection weights, defense targets, air bias, AFUS row count.

## License

GPL-3.0-or-later — same as the original MetalBot. See [LICENSE](LICENSE).

```
Copyright (C) 2024 vexalous (original MetalBot)
Copyright (C) 2026 ShotgunPiuPiu (modifications)

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
```
