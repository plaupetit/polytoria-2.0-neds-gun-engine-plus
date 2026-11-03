local Enum = require(game['ScriptService']['GunFramework']['Enum'])

-- BALANCE ROLE: accurate sidearm; stronger single rounds but a smaller magazine and slower fire cadence.
-- RELOAD: R transfers rounds only from this Tool's own reserve to its magazine.
-- FIRE MODE: false = SEMI (one shot per press); true = AUTO (hold to repeat).
-- MODE SWITCH: V cycles only when this list contains more than one supported entry.
-- Burst is intentionally not a config value yet; it needs a dedicated WeaponBurst module and server contract.
return {
    limitedAmmo = true,

    maxAmmo = 12,
    storedAmmo = 72,

    minDamage = 18,
    maxDamage = 22,

    spread = 1,

    firerate = 300,

    -- Use one or more booleans: false = SEMI, true = AUTO.
    firemodes = {false, true},
    startingFiremode = 1,

    reloadTime = 1.6,

    bullets = 1,

    --[[
    1 = mag
    2 = shell
    ]]
    reloadType = Enum.ReloadType.Magazine,
    reloadAdd = 1
}