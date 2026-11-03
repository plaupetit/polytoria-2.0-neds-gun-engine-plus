local Enum = require(game['ScriptService']['GunFramework']['Enum'])

-- BALANCE ROLE: close-range burst; eight pellets reward accuracy, but fall off through wide spread.
-- RELOAD: R transfers rounds only from this Tool's own reserve to its magazine.
-- FIRE MODE: false = SEMI (one shot per press); true = AUTO (hold to repeat).
-- MODE SWITCH: V cycles only when this list contains more than one supported entry.
-- Burst is intentionally not a config value yet; it needs a dedicated WeaponBurst module and server contract.
return {
    limitedAmmo = true,

    maxAmmo = 6,
    storedAmmo = 36,

    minDamage = 7,
    maxDamage = 9,

    spread = 6, -- degrees

    reloadTime = 3,

    firerate = 0.75,
    useDelay = true,

    -- Use one or more booleans: false = SEMI, true = AUTO.
    firemodes = {false, true},
    startingFiremode = 1,

    bullets = 8,

    pumpAction = true,
    beforePumpDelay = 0.3,
    pumpDelay = 0.35,

    reloadType = Enum.ReloadType.Shell,
    reloadAdd = 1,
    reloadShellDelay = 0.5
}