# Kill List Stats (WoW Forever addon)

Keeps a database of every player you kill and every player who kills you, with a
revenge **Kill List** of the players who killed you while you were leveling.

## What it tracks

**Your kills**
- Every enemy player you kill, split into **world** and **battleground** kills per player.
- **Who landed the killing blow**: you, your pet or totem, someone in your party or raid (by name),
  a battleground teammate, or an NPC / guard / the environment.
- **Solo or grouped**: whether you were alone or in a party or raid you formed (and with whom).
  A battleground raid you were put into counts as solo.
- Your own killing blows always count. A kill someone else finished counts when:
  - the game gave you an **honorable kill** for it, or
  - the player was fighting you (targeting you, or your target) and you were in combat when they died, or
  - your party finished them while you were in combat, out in the world, or
  - you were solo and the built-in **damage meter** shows your damage on them.
  
  You can turn these "helped" kills off on the Options tab. They are kept apart from your own
  killing blows, so the **Your KB** column always shows only the kills you finished yourself.
- Player name, realm, class, race, level and guild.

**Your deaths to players**
- **Killer** is the player who landed the killing blow. If a pet or NPC landed it, the enemy
  player who did the most damage gets the credit.
- **Assists** go to every other enemy player who damaged you (from the death recap) or was
  targeting you in the last 15 seconds before you died.
- **Your level and theirs** at the time of death. `??` means the killer was 10+ levels above you.
- **Your HP when they attacked you**, for the killer and for each assister. It also notes whether
  you were fighting a mob and how many seconds into the fight they jumped in. If someone opens on
  you while you're fighting a mob, or while you're already hurt, it counts as a **cheap kill**.
  Cheap kills show in the Kill List's "Cheap" column and in their tooltip.
- **Why you died**, built automatically from what happened. For example:
  - `Killer was 8 levels higher (32 vs your 24)`
  - `Outnumbered: 3 enemy players vs you alone`
  - `Dead 3s after combat started` (a gank)
  - `Opportunist: attacked you at ~50% health while you were fighting Murloc Raider, 8s into the fight`
  - `Opportunist: attacked you when you were already hurt (~40% health)`
  - `You were also fighting NPCs (Murloc Raider)`
  - `Killing blow by Wolf` (a hunter's pet)
  - `Repeat offender: killed you 2 times before`

**Kill List (revenge list)**
- Anyone who kills you in the world is added automatically. You can turn this off, or also add
  assisters and battleground killers, on the Options tab.
- Each entry shows how many times they killed you, their assists, your kills on them and a score.
  It also shows the auto-generated reason, or your own note.
- Killing someone on your Kill List counts as a **revenge kill** and is announced.
- Every time a Kill List player shows up nearby, you get a raid-warning style alert and a sound.
  - **With enemy nameplates on:** it warns when their nameplate appears. It warns again when they
    come back after their nameplate was gone for 10+ seconds.
  - **Without nameplates:** it warns when you target or mouse over them, or when they target you,
    after not seeing them for a minute.

**Class stats**
- Per class: world kills, BG kills, share of all your kills, how many different players you
  killed, how often that class killed you or assisted, and your K/D against the class.

## Where you see it

- **Tooltips**: mouse over any player you have history with to see your kills on them (world / BG),
  their kills on you and assists, and their Kill List status.
- **Window**: open it with `/kls` or the addon button next to the minimap. It has five tabs:
  - **Kills**: your kill database, in two views (switch with the button at the top):
    - **By player**: one row per player with world, BG and total kills, **Your KB** (kills you
      finished yourself) and **Solo** (kills while not grouped). Click a column header to sort.
    - **Every kill**: one row per kill with when, where, both levels, **Killing blow** (you in
      green, your party in gold, a BG teammate in blue, an NPC or other in grey) and **Your group**
      (Solo / Party of 3 / Raid of 10). Hover a row for the full story, such as who you were with
      and why it counted.
  - **Deaths**: every PvP death, with killer, levels, your HP when they attacked, helpers, your
    group and the reason. Hover a row to see the last hits you took, with your HP before each one.
  - **Kill List**: your revenge list. Select a row to remove it or edit its note, or use
    "Add my target".
  - **Classes**: class statistics.
  - **Options**: settings.
  
  The search box filters by name, class, guild, zone, reason or party member.
- **Filters** (the Filter button on the Kills, Deaths and Classes tabs). Every number in the window
  follows them, including the totals along the bottom:
  - **Where**: world or battlegrounds.
  - **Your group**: solo, in a party, in a raid, or any group.
  - **Killing blow**: yours, anyone but you (kills you helped with), your party, a BG teammate, or
    an NPC / other.
  - **Their level**: higher than you, an even fight (within 2 levels), or lower than you (ganks).
  - **When**: today, last 7 days, last 30 days.
  - **Character**: one of your characters (when you play more than one).
  - **Revenge kills only**.
  - **Quick picks** set several at once: "Solo killing blows", "Kills with your group",
    "Kills you only helped with", "Revenge kills", "Even fights", "Ganks", "This week in the world".
  
  The X on the Filter button (or `/kls filter`) clears them.
- **Chat**: a short line for each kill and death, plus the reason you died.

## Commands

```
/kls                      open or close the window
/kls kills|deaths|list|classes|options   open a tab
/kls log                  every single kill (the "Every kill" view)
/kls stats                summary in chat
/kls who <name>           your history with a player
/kls top                  players you killed most
/kls nemesis              players who killed you most
/kls buddies              who you kill with, and who takes your killing blows
/kls filter               clear the window's filters
/kls add [name] [note]    add a player (or your current target) to the Kill List
/kls remove <name>        remove from the Kill List
/kls note <name> <text>   set a Kill List note
/kls window <seconds>     assist window (default 15)
/kls debug                print what the addon detects
/kls recap                show the raw death recap data
/kls reset                delete all data
```

## Install

1. Download this repository: clone it, or use **Code → Download ZIP** on GitHub and unzip it.
2. Copy only the `KillListStats` folder (not the whole repository) into your WoW Forever
   AddOns folder:

   ```
   <your World of Warcraft folder>\_forever_\Interface\AddOns\KillListStats
   ```

   The folder must be named exactly `KillListStats` and contain `KillListStats.toc` directly.
   For example: `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\KillListStats\KillListStats.toc`.
3. Restart the game or type `/reload`. Then check that "Kill List Stats" is enabled in the AddOns
   list on the character select screen.

Each player keeps their own data. Nothing is shared between friends.

## How it works, and what WoW Forever limits

WoW Forever runs on the Midnight client, and that client stops addons from reading the combat log.
The addon gets its data from other sources instead:

| Need | Source |
| --- | --- |
| Killing blows | `PARTY_KILL` event: who landed it and who died. Fires for you, your pet and totems, and your party or raid. |
| Kills someone else finished | `UNIT_DIED` (a nearby enemy player died), the honorable-kill chat line and counter (`CHAT_MSG_COMBAT_HONOR_GAIN`, `GetPVPSessionStats`), and the damage meter (`C_DamageMeter`, read after combat) |
| Did you fight them | Enemies seen targeting you, or your target while you were in combat |
| Your group | `IsInGroup` / `GetNumGroupMembers` for the party you formed, and your party members' names |
| Victim's name, class and level | `GetPlayerInfoByGUID`, plus what was seen on their unit. In battlegrounds, the scoreboard once the match ends. |
| Who killed you, who hit you | `C_DeathRecap.GetRecapEvents()`: your last hits taken, read after you die |
| Who else was on you | Every 0.5s in combat, enemy nameplates, target, focus and mouseover are checked for who is targeting you |

All the signals about one death are collected for about 1.5 seconds and then combined into one
decision, so a kill is never counted twice.

Known limits:
- **Kills someone else finished need proof you took part** (see "Your kills" above). Without it,
  a player who dies near you is not counted. A hunter's Feign Death is not counted.
- **Battleground kills may show up late.** During a match the game hides enemy names from addons,
  so a kill is held back until the name can be read (usually when the match ends) and then added.
- **Old data**: kills recorded before version 1.1 are treated as solo kills with your own killing
  blow, because that is all older versions counted.
- **HP comes from the death recap.** WoW Forever never lets addons read your live health
  (`UnitHealth` is always hidden from them). Your HP when someone attacked is worked out after you
  die, from the recap's health on each hit.
  - When the recap is cut short and that player was already hitting you before it starts, HP shows
    as `?`. The addon leaves it unknown rather than guess.
  - "Fighting a mob" also comes from what you were targeting when they locked onto you.
- **Assist detection works best with enemy nameplates turned on.** The death recap only covers
  your last few hits, so enemies who hit you earlier are found because they were targeting you.
- **Battlegrounds**: during an active match the game hides enemy names on units from addons. BG
  deaths therefore rely on the death recap. Recap attackers that can't be identified are assumed
  to be players, so in Alterac Valley an NPC guard can show up as a "player".
- Data is saved account-wide in `WTF\Account\<account>\SavedVariables\KillListStats.lua`. Each kill
  and death in the logs records which of your characters it happened to. The logs keep the last
  3000 entries each. Per-player totals are never trimmed.

If something looks wrong in game, `/kls debug` prints what the addon detects, and `/kls recap`
shows the raw death recap fields. Those two outputs make a bug easy to fix.

## Development

The `tests` folder runs the addon under Lua 5.1 with a mocked WoW API. It simulates kills, deaths,
pets, party and teammate killing blows, honorable kills, the damage meter, Feign Death, secret
values, battlegrounds, saved-data upgrades, filters, tooltips, slash commands and the window:

```
pip install lupa
python tests/run_tests.py
```
