local Enum = require(game['ScriptService']['GunFramework']['Enum'])

-- CONFIG: Minigun (kind = firearm). Side: read by client (WeaponConfig) and server (WeaponServer).
-- BALANCE ROLE: sustained suppression; very large magazine, low damage per round, wide spread.
-- RELOAD: R transfers rounds only from this Tool's own reserve to its magazine.
-- FIRE MODE: AUTO only (firemodes = {true}); hold Mouse0.
-- SPIN-UP: spinUpTime seconds must elapse after Mouse0 goes down before the first round leaves the barrel;
--   releasing Mouse0 resets the timer (WeaponRuntime update tick, which also spins Barrel<n>). Enforced on the client only, the
--   server still validates ammo and cadence (60 / firerate seconds between rounds).
-- How to test: hold Mouse0, nothing fires for about 0.6 s, then a continuous stream; release and press again
--   and the delay repeats.
return {
    kind = "firearm",

    limitedAmmo = true,

    maxAmmo = 200,
    storedAmmo = 600,

    minDamage = 6,
    maxDamage = 9,

    spread = 3, -- degrees

    firerate = 900,

    -- Use one or more booleans: false = SEMI, true = AUTO.
    firemodes = {true},
    startingFiremode = 1,

    reloadTime = 4,

    bullets = 1,

    reloadType = Enum.ReloadType.Magazine,
    reloadAdd = 1,

    -- Seconds between Mouse0 down and the first round.
    spinUpTime = 0.6
}
