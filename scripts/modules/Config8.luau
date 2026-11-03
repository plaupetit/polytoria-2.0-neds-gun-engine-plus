-- CONFIG: Knife (kind = melee). Side: read by the client (WeaponConfig -> WeaponMelee) and by the server
-- (WeaponMeleeServer, which re-requires this module and never trusts client numbers).
-- No Enum is needed: there is no reload, no fire mode and no ammunition.
-- AMMO FIELDS: maxAmmo = 0 / limitedAmmo = false exist only so the shared ammo plumbing works;
--   WeaponHud shows "-" for melee Tools.
-- RANGE / CONE: `range` studs measured from the attacker, `coneAngle` is the FULL cone angle in degrees
--   (70 means 35 degrees either side of the swing direction). The nearest valid Player or NPC is hit.
-- DAMAGE: random integer in [minDamage, maxDamage], skipped for targets carrying a "Protect" child.
-- How to test: stand 3 studs from an NPC and click: the hitmarker shows and the NPC loses 35-45 health;
--   click with the NPC behind you or 10 studs away: nothing happens.
return {
    kind = "melee",

    limitedAmmo = false,
    maxAmmo = 0,
    storedAmmo = 0,

    minDamage = 35,
    maxDamage = 45,

    cooldown = 0.45,
    range = 5,
    coneAngle = 70
}
