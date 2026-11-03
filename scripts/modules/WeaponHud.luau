-- WeaponHud derives display data from the equipped Tool so the HUD has no duplicate ammunition state.
local WeaponHud = {}

function WeaponHud.GetHeldTool(player)
    return player and player:FindChildByClass("Tool") or nil
end

function WeaponHud.IsGunTool(tool)
    return tool ~= nil and tool.Shared ~= nil and tool.Shared.gun == true
end

local function readAmmoState(tool)
    if not WeaponHud.IsGunTool(tool) then
        return 0, 0
    end

    local shared = tool.Shared
    local magazine = type(shared.ammo) == "number" and shared.ammo or 0
    local reserve = shared.limitedAmmo == true and shared.storedAmmo or shared.maxAmmo
    if type(reserve) ~= "number" then
        reserve = 0
    end
    return magazine, reserve
end

function WeaponHud.GetMagazineText(tool)
    local magazine = readAmmoState(tool)
    return tostring(magazine)
end

function WeaponHud.GetReserveText(tool)
    local _, reserve = readAmmoState(tool)
    return tostring(reserve)
end

-- Keep the legacy combined representation for callers that have not yet moved to the modular labels.
function WeaponHud.GetAmmoText(tool)
    return ("%s / %s"):format(WeaponHud.GetMagazineText(tool), WeaponHud.GetReserveText(tool))
end

return WeaponHud