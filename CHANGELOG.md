# Tally - release history

Tally is a statistics addon for WoW Forever 1.60.1 (`## Interface: 16001`).
This file lists every tagged release and what changed. New releases go at the top.

---

## 20261107.1 - 7 November 2026

**Fixed**

- Loot: fishing no longer counts `You receive item:` lines - vendor purchases,
  mail and the auction house - as catches, and loot chat is ignored while a
  vendor window is open. A fishing supply bought at a vendor no longer appears
  under Gathered -> Fishing.
- Loot: gathering (Mining, Herbalism, Skinning) has the same vendor guard, so a
  purchase cannot be credited to a profession either.
- Merchant's Favor: this client's Lua has no `os` table, so `os.date` raised an
  error on every gain. That one failure is why earned, today and recent stayed
  empty and why the page could go blank. Dates now come from the game's own
  `date()`.
- Merchant's Favor: a record whose numbers do not add up is repaired once (a
  balance with nothing behind it is credited to earned), and an earned total
  with no history gets one by-level, daily and recent row.
- Merchant's Favor: the live balance is shown even before a character record
  exists, and a drawing error can no longer blank the Economy page.
- Login: after a `/reload` this client raises only `ADDON_LOADED`, not
  `PLAYER_LOGIN` or `PLAYER_ENTERING_WORLD`. A retry now selects the character,
  so the addon keeps recording instead of leaving every tab empty.
- Blocked actions: a refused `SetRaidTarget` from a macro's `/run` no longer
  reads as if Tally called it. The message explains the insecure-Lua cause and
  points at `/tm`.

**Added**

- `/tally favor` prints the live currency read and the stored Favor record;
  `/tally favor sync` forces a read and repaints the page.

---

## 20261105.4 - 5 November 2026

**Fixed**

- A level-up message is no longer printed long after the level.
- Professions by level shows the cap in effect at each level instead of setting
  the cap on lower levels.
- Find Minerals and other permanent buffs no longer count brief aura-scan gaps
  as new gains.

---

## 20261105.3 - 5 November 2026

**Fixed**

- The Level-ups card lists levels in order again, newest first.
- A new character no longer gets a fake "Level 0 to 1 - no reading" row.
- Level points are sorted by level before the card and the levelling graph read
  them.

---

## 20261105.2 - 5 November 2026

**Playtime**

- The current-level figure ticks by itself between `/played` reads; the
  client's own figure stays authoritative and snaps the counter on every reply.
- A level whose `/played` reply was missed falls back to Tally's sampled
  seconds, marked as tracked rather than confirmed, so fast level-ups no longer
  leave holes in the graph.
- The "Leave AFK time out of played time" setting was removed: AFK time always
  counts, matching the client's `/played`, in sessions, tracked time, XP per
  hour and zone time.

**Loot and professions**

- Disenchanting counts its materials as crafted Enchanting items and adds a
  Disenchants total; Professions by level gained a `skill gains` /
  `materials` toggle.
- Destroyed items are tracked separately from loot and listed under
  Loot -> Looted.

**Graphs and chat**

- A second character of the same class gets a graph colour kept clear of the
  class colours.
- Guild and officer chat keep counting after login, with per-guild totals
  under the current guild and the guild history; own whispers are counted
  again.

---

## 20261105.1 - 5 November 2026

**Fixed**

- Guild and officer chat keep counting after login: send hooks are rechecked
  and own messages match by GUID or normalised name.
- Guild message counts appear under "Current guild" and each guild in the
  history; the Chat section shows the lifetime Guild total again.
- The "Not split by guild" row is gone.
- Merchant's Favor no longer says "No character selected" when there is simply
  no Favor.
- Debuffs count each new application or refresh, including enemy debuffs whose
  names the client seals.
- "+0" cells in Professions by level are grey.

---

## 20261105 - 5 November 2026

**Added**

- Guild chat sent is tracked per guild, including officer chat; Social -> Guild
  has a per-guild breakdown.

**Fixed**

- Sending a guild invite no longer triggers an addon-blocked warning.
- Level-ups no longer print the previous level after a newer one.
- A level-up asks for `/played` once instead of retrying every 2 seconds.

---

## 20261103.2 - 3 November 2026

- Profession notifications: skill-cap and trainer messages, cooldown summaries,
  a separate notification character list and a chime test.
- Login cooldown catch-up and the loaded line.
- TOC limited to Forever (`## Interface: 16001`).

---

## 20261103 - 3 November 2026

- Loot -> Gathered: Fishing, Herbalism, Mining and Skinning pages, with item
  lists, zones and levels.
- Loot -> Crafted and Character -> Professions: every profession, by level.
- Economy -> Merchant's Favor: Forever currency 3402, with balance, earned,
  spent, daily and per-level records (first read treated as the starting
  balance).
- Total -> Records and the combined views; level-times graph fixes.
- CurseForge packaging metadata and release checklist.

---

## 20261101 - 1 November 2026

- Initial public build: Character, Playtime, Economy, Combat, Loot and Explore
  tabs, plus the Social tab.
- Classic profession fixes, overview rows, graph view and money labels.

---

## Earlier

`v20261101` was the first tagged release. Older commit history is in the
repository log.
