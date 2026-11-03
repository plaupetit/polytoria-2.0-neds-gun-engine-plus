-- WeaponConfig keeps per-Tool configuration copies isolated from module cache state.
local WeaponConfig = {}

local function copyTable(value)
    local copy = {}
    for key, entry in pairs(value) do
        copy[key] = type(entry) == "table" and copyTable(entry) or entry
    end
    return copy
end

local function tryRequire(config)
    if config == nil then
        return nil
    end

    local ok, data = pcall(function()
        return require(config)
    end)
    if ok and type(data) == "table" then
        return data
    end

    return nil
end

function WeaponConfig.Resolve(tool, defaultInventory)
    local toolName = tool and tool.Name or "unknown"
    local templateTool = defaultInventory and defaultInventory:FindChild(toolName)
    local data = tryRequire(templateTool and templateTool:FindChild("Config"))
    if data ~= nil then
        return data
    end

    -- Runtime clones can expose a generic Config, so this remains a fallback.
    data = tryRequire(tool and tool:FindChild("Config"))
    if data ~= nil then
        return data
    end

    print(("[Ned Gun] Config unavailable for %s; initialization skipped."):format(toolName))
    return nil
end

function WeaponConfig.Apply(tool, data)
    tool.Shared.gun = true
    for key, value in pairs(data) do
        tool.Shared[key] = type(value) == "table" and copyTable(value) or value
    end
    tool.Shared.ammo = data.maxAmmo
    tool.Shared.lastFired = 0
    -- WeaponFireModes validates this copied config and owns the selected mode index.
    if tool.Shared.pumpAction then
        tool.Shared.pumped = true
    end
end

function WeaponConfig.GetHeldTool(player)
    return player and player:FindChildByClass("Tool") or nil
end

return WeaponConfig