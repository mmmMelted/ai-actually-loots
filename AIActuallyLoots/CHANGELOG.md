# Changelog

## 1.1.6
- Fixed a crash when travelling to another map (looting checks could touch AI and containers of the map being unloaded).

## 1.1.5
- Fixed AI still looting containers set against a wall (e.g. garbage piles) from the other side of it.

## 1.1.4
- AI no longer loot through walls: they stand on the container's side with a clear line to it, or skip it.

## 1.1.3
- AI searching a room walk straight to the next container instead of turning toward the exit first.

## 1.1.2
- Nomads never loot (no houses, bodies or kills).

## 1.1.1
- Guards and Military loot only rarely (about once per 5 / 10 minutes of calm time; was every ~25 s / ~1 min).

## 1.1.0
- AI open a container once and grab their items one after another (no longer re-opening it per item).
- AI check containers whether or not they hold anything, find nothing in empty ones and move on.
- After a container, AI keep searching the other unchecked containers in the same room/house.

## 1.0.0
- First release: calm AI loot nearby containers into their own inventory; hiders loot their house and return to
  ambush when something approaches; killers loot their kills, calm AI scavenge fresh bodies; vanilla Loot() no longer
  pulls AI out of a fight when its animation ends.
