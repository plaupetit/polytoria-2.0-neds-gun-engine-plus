local Enum = require(game['ScriptService']['GunFramework']['Enum'])

-- BALANCE ROLE: reliable mid-range primary; sustained fire is offset by moderate per-round damage.
-- RELOAD: R transfers rounds only from this Tool's own reserve to its magazine.
-- FIRE MODE: false = SEMI (one shot per press); true = AUTO (hold to repeat).
-- MODE SWITCH: V cycles only when this list contains more than one supported entry.
-- Burst is intentionally not a config value yet; it needs a dedicated WeaponBurst module and server contract.
return {
    limitedAmmo = true,

    maxAmmo = 30,
    storedAmmo = 120,

    minDamage = 12,
    maxDamage = 16,

    spread = 0.75,

    firerate = 600,

    -- Use one or more booleans: false = SEMI, true = AUTO.
    firemodes = {true, false},
    startingFiremode = 1,

    reloadTime = 2.4,

    bullets = 1,

    --[[
    1 = mag
    2 = shell
    ]]
    reloadType = Enum.ReloadType.Magazine,
    reloadAdd = 1
}