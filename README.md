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

## License

- My changes and additions are under the MIT license (see `LICENSE`). That covers the 2.0
  port, the Sniper, Minigun, Grenade, Knife and turret, and the later fixes.
- The parts that come from Ned's original are not mine to relicense. They stay Ned's, are included
  here with credit because the site copy is broken, and will be removed if Ned asks.

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

The test turret fires at players who enter the red disc, except during the spawn shield.

## Status

Work in progress. Debug traces (`DEBUG_WEAPON_KINDS`) are still on in the grenade and knife scripts.

---

**FR** : monde Polytoria 2.0 publié ici parce que la copie de monde 2.0 est cassée sur le site.
Système d'origine : Ned's Gun Engine par Ned, crédité ci-dessus. Mes ajouts sont sous licence MIT.
