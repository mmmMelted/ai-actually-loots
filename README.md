# AI Actually Loots

**Road to Vostok's AI is supposed to loot. It never does. This fixes it.**

The game ships with AI looting code (wandering AI pick a nearby container, play a loot animation and take an item),
but the part that finds containers was never wired up: the AI's loot detection area has no collision layers and
containers have nothing for it to detect, so it always comes back empty and no AI ever loots. This mod finds the
targets itself and hands them to the game's own looting, animation and inventory code.

## What it does

- **AI loot houses.** Calm AI (not alerted or fighting) walk to nearby containers, open them once and grab 1-3
  items into their own inventory. Kill them and you'll find the loot on the body.
- **They actually search.** AI don't know what's inside until they look: they check containers, find nothing in the
  empty ones and move on, and sweep the other containers in the same room or house before leaving. They remember
  what they've already searched.
- **Hiders loot instead of standing still.** AI waiting in ambush inside houses loot the house and return to their
  hide spot. The moment you (or a Nomad) approach, they drop it and get back into ambush.
- **Bodies get stripped.** After a kill, the killer loots the body once things calm down. Other calm AI scavenge
  fresh bodies too: bandits loot anyone, everyone else only loots enemies.
- **Personality by faction.** Bandits loot often. Guards and Military are on duty: you'll only rarely catch one
  rifling through a cabinet (about once per 5 / 10 minutes of calm). Nomads never loot.
- **Fixes a vanilla side bug:** an AI that got into a fight in the middle of looting was sent back to wandering when
  its loot animation finished. Now it stays in the fight.

Bosses are left alone.

## Requirements

- Road to Vostok Build 2 ("Nomads", v0.2.0.0), Godot 4.6.3.
- [Metro Mod Loader](https://github.com/ametrocavich/vostok-mod-loader) v3.4.1 or newer (uses its RTVModLib hooks).

## Download

Get `AIActuallyLoots.vmz` from the [Releases](https://github.com/mmmMelted/ai-actually-loots/releases) page (or build it
yourself with `python build.py`).

## Install

1. Install Metro Mod Loader (follow its instructions: `override.cfg` + `modloader.gd` in the game folder, plus a
   `mods` folder).
2. Drop `AIActuallyLoots.vmz` into `Road to Vostok/mods/`.
3. Start the game and make sure **AI Actually Loots** is checked in the loader window, then click **Launch modded**.

**Uninstall:** delete `AIActuallyLoots.vmz` (or uncheck it in the loader window).

## Compatibility

- Single player. Safe to add to or remove from an existing save (it stores nothing in your save).
- Works with other AI mods, as long as they don't also replace the AI's `Loot` function (the loader will warn in the
  log if one does).

## Troubleshooting

The log is at `%APPDATA%\Road to Vostok\logs\godot.log` (written when the game closes). Look for
`[AIActuallyLoots] v1.1.5 loaded`. Every item an AI takes is logged as `[AIActuallyLoots] <AI> looted <item>`.

## Credits

- Mod by **mmmMelted** ([github.com/mmmMelted](https://github.com/mmmMelted)).
- Built on [Metro Mod Loader](https://github.com/ametrocavich/vostok-mod-loader) by ametrocavich (RTVModLib hooks).
- Made with AI assistance: designed, written and tested with Claude Code (Anthropic, Claude Opus 5.5), reviewed and
  playtested by mmmMelted.
- No game files or assets are included; the mod only calls the game's own functions.

## License

MIT, see `LICENSE` (in the mod folder).
