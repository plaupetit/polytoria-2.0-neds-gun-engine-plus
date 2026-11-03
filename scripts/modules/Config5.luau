local Enum = require(game['ScriptService']['GunFramework']['Enum'])

-- CONFIG: Sniper (kind = firearm). Side: read by client (WeaponConfig) and server (WeaponServer).
-- BALANCE ROLE: slow, precise one-shot-ish rifle; huge damage per round, tiny magazine, no spread.
-- RELOAD: R transfers rounds only from this Tool's own reserve to its magazine.
-- FIRE MODE: false = SEMI (one shot per press); true = AUTO (hold to repeat).
-- SCOPE: scopeFov enables the Z toggle (WeaponScope): Camera.FOV is set to this value while scoped
--   and the previous FOV is restored on toggle-off and on Unequipped. Tools without scopeFov have no Z key.
-- How to test: equip, press Z (view zooms in), press Z again or switch tool (FOV is restored).
return {
    kind = "firearm",

    limitedAmmo = true,

    maxAmmo = 5,
    storedAmmo = 30,

    minDamage = 70,
    maxDamage = 90,

    spread = 0,

    firerate = 40,

    -- Use one or more booleans: false = SEMI, true = AUTO.
    firemodes = {false},
    startingFiremode = 1,

    reloadTime = 3,

    bullets = 1,

    reloadType = Enum.ReloadType.Magazine,
    reloadAdd = 1,

    -- Field of view (degrees) while scoped; the default Creator camera FOV is restored when unscoped.
    scopeFov = 20
}
