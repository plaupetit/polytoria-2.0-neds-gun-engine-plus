-- WeaponFireModes owns the supported fire-mode contract and the selected mode for each Tool.
-- Burst is deliberately excluded: it needs a dedicated cadence module plus a server-side validation contract.
local WeaponFireModes = {}

local function getModeText(mode)
    return mode == true and "AUTO" or "SEMI"
end

local function validateModes(config)
    local modes = config and config.firemodes
    if type(modes) ~= "table" or #modes == 0 then
        return nil, "firemodes must contain at least one supported mode."
    end

    local normalized = {}
    local labels = {}
    local hasAutomatic = false
    for index, mode in ipairs(modes) do
        if type(mode) ~= "boolean" then
            return nil, ("firemodes[%d] must be true (AUTO) or false (SEMI); burst needs its own module."):format(index)
        end
        normalized[index] = mode
        labels[index] = getModeText(mode)
        hasAutomatic = hasAutomatic or mode
    end

    local startingIndex = tonumber(config.startingFiremode) or 1
    if startingIndex % 1 ~= 0 or startingIndex < 1 or startingIndex > #normalized then
        return nil, ("startingFiremode must select 1..%d."):format(#normalized)
    end

    return {
        modes = normalized,
        labels = labels,
        hasAutomatic = hasAutomatic,
        startingIndex = startingIndex,
    }
end

function WeaponFireModes.DescribeConfig(config)
    local description, reason = validateModes(config)
    if description == nil then
        return {
            valid = false,
            reason = reason,
            labels = {},
            hasAutomatic = false,
            supportsCycle = false,
        }
    end
    description.valid = true
    description.reason = nil
    description.supportsCycle = #description.modes > 1
    return description
end

function WeaponFireModes.Initialize(tool)
    local description, reason = validateModes(tool.Shared)
    if description == nil then
        return false, reason
    end

    tool.Shared.firemodes = description.modes
    tool.Shared.firemode = description.startingIndex
    tool.Shared.firemodeText = description.labels[description.startingIndex]
    return true, description
end

function WeaponFireModes.GetCurrent(tool)
    -- A Tool torn down mid-frame has no Shared table; report "no mode" instead of throwing.
    local shared = tool.Shared
    if shared == nil then
        return nil, nil
    end
    local modes = shared.firemodes
    local index = shared.firemode
    return modes and modes[index] or nil, index
end

function WeaponFireModes.GetText(mode)
    return getModeText(mode)
end

function WeaponFireModes.IsAutomatic(mode)
    return mode == true
end

function WeaponFireModes.Cycle(tool)
    local modes = tool.Shared.firemodes
    if type(modes) ~= "table" or #modes == 0 then
        return false, nil, nil, "mode list unavailable"
    end

    local index = tonumber(tool.Shared.firemode) or 1
    if index < 1 or index > #modes then
        index = 1
    end
    if #modes == 1 then
        tool.Shared.firemode = index
        tool.Shared.firemodeText = getModeText(modes[index])
        return false, modes[index], index, nil
    end

    local nextIndex = index % #modes + 1
    tool.Shared.firemode = nextIndex
    tool.Shared.firemodeText = getModeText(modes[nextIndex])
    return true, modes[nextIndex], nextIndex, nil
end

return WeaponFireModes