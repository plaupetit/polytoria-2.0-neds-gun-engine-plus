# Ned's Gun Engine+ for Polytoria 2.0

A Polytoria 2.0 world: a gun framework with a Rifle, Pistol, Shotgun, Sniper, Minigun, Grenade,
Knife and a test turret.

## Why it is on GitHub

Copying a 2.0 world from the Polytoria site is broken at the moment, so an uncopylocked place
cannot be taken from there. This repository is the copy. It is linked from my official Polytoria
profile.

## Credit

The original system is **Ned's Gun Engine by Ned**: https://polytoria.com/u/Ned. Please thank Ned
first. Ned shared the original as an uncopylocked place, without a license.

This repository is an independent continuation for Polytoria 2.0. I directed and tested it; the code
was written with AI and MCP tools. I defined the goals, tested the behaviour and validated the
results.

## Why I share it here

Ned published the original as an **uncopylocked** place on Polytoria: anyone was meant to be able
to copy it, open it and use it. Someone asked me for access to this 2.0 version, and I could not
give it to them through the official Polytoria site, because copying a 2.0 world is broken there
at the moment. This repository does the job the site's copy button is supposed to do. Nothing more.

## About the license

I am not using the MIT license to claim Ned's work as mine. Ned made the original system, and the
credit above stays his.

The reason for a license is practical. On GitHub, a repository with no license counts as "all
rights reserved" by default, which would make this world less open here than it is on Polytoria,
where it was uncopylocked. MIT keeps it the way it was meant to be: copyable and usable by everyone.

To be precise about what is what:

- My changes and additions are under the MIT license (see `LICENSE`): the 2.0 port, the Sniper,
  Minigun, Grenade, Knife and turret, and the fixes after that.
- Ned's original parts are shared here in the same open spirit as his uncopylocked place. I cannot
  change their author: they remain Ned's work.
- If Ned wants it credited differently, licensed differently or taken down, I will do it.

## Open it

1. Clone or download this repository.
2. Open the folder in Polytoria Creator 2.0 (`project.ptproj`; the world is `main.poly`).
3. Scripts are linked files under `scripts/` (`client/`, `server/`, `modules/`). Keep the `.meta`
   files next to them: they tie each file to its script in the world.

## Controls

| Weapon | Input |
|---|---|
| Firearms | Left click fire, R reload, V fire mode |
| Sniper | Z scope |
| Minigun | Hold left click: barrels spin up, then fire |
| Grenade | Hold right click to charge (arc preview), release to throw |
| Knife | Left click slash |

## Test turret

The world also has a test turret, there to test damage and the spawn shield without a second
player. It stands on a red disc (radius 25 studs) with a "TEST TURRET" label. When a player enters
the disc and is in line of sight, the turret turns toward them, aims at the torso and fires
2 shots per second for 10 damage each. It never fires at a player who still has the spawn shield.

## Status

Work in progress. Debug traces (`DEBUG_WEAPON_KINDS`) are still on in the grenade and knife scripts.

| Weapon | State |
|---|---|
| Rifle, Pistol, Shotgun | Working |
| Minigun | Working: spin-up, then continuous fire |
| Knife | Works, but you have to aim exactly at the player or NPC; it is not easy or obvious to use yet |
| Sniper | Fires; no scope zoom or sniper tunnel vision yet |
| Grenade | Tested and working: hold-to-charge throw with arc preview; still needs polish |
| Test turret | Tracks and hits; still being tuned |

## Planned

- Sniper: scope zoom with a tunnel-vision overlay.
- A custom cursor for each firearm type.
- An easier knife: wider, clearer hit area and visible feedback.

---

**FR** : monde Polytoria 2.0 publié ici parce que la copie de monde 2.0 est cassée sur le site.
Système d'origine : Ned's Gun Engine par Ned, crédité ci-dessus. Mes ajouts sont sous licence MIT.
