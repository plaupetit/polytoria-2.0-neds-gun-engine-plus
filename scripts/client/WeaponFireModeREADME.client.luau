-- SCRIPT CONTEXT
-- Expected type: ClientScript
-- Expected Creator path: world/ScriptService/GunFramework/Scripts/WeaponFireModeREADME
-- This is a one-shot local configuration README and test. It never changes weapon data or gameplay.

-- CHANGE FIRE MODES
-- 1. Open the Tool's Config ModuleScript below PlayerDefaults/Inventory.
-- 2. Use false for SEMI and true for AUTO, for example: firemodes = { false, true }.
-- 3. Set startingFiremode = 1 (or another valid one-based index).
-- 4. Equip the tool and press V to cycle configured modes.
-- Burst is deliberately rejected until a dedicated WeaponBurst module defines its cadence and server contract.

local function WaitChild(parent, childName, duration)
    local found = parent:FindChild(childName)
    local startedAt = os.clock()
    while found == nil do
        if duration ~= nil and os.clock() - startedAt >= duration then
            return nil
        end
        wait()
        found = parent:FindChild(childName)
    end
    return found
end

local playerDefaults = WaitChild(game, "PlayerDefaults", 5)
local scriptService = WaitChild(game, "ScriptService", 5)
local gunFramework = scriptService and WaitChild(scriptService, "GunFramework", 5)
local modules = gunFramework and WaitChild(gunFramework, "Modules", 5)
local fireModeModule = modules and WaitChild(modules, "WeaponFireModes", 5)
local inventory = playerDefaults and WaitChild(playerDefaults, "Inventory", 5)
local fireModes = fireModeModule and require(fireModeModule)

local expected = {
    Shotgun = { "SEMI", "AUTO" },
    Pistol = { "SEMI", "AUTO" },
    Rifle = { "AUTO", "SEMI" },
}

local function labelsMatch(actual, wanted)
    if #actual ~= #wanted then
        return false
    end
    for index, label in ipairs(wanted) do
        if actual[index] ~= label then
            return false
        end
    end
    return true
end

local function runConfigTest(toolName, wantedLabels)
    local template = inventory and inventory:FindChild(toolName)
    local config = template and template:FindChild("Config")
    if config == nil then
        print(("[Ned Gun Firemode README] FAIL %s: PlayerDefaults/Inventory/%s/Config is missing."):format(toolName, toolName))
        return false
    end

    local configOk, data = pcall(function()
        return require(config)
    end)
    if not configOk or type(data) ~= "table" then
        print(("[Ned Gun Firemode README] FAIL %s: Config did not return a table."):format(toolName))
        return false
    end

    local report = fireModes.DescribeConfig(data)
    if not report.valid then
        print(("[Ned Gun Firemode README] FAIL %s: %s"):format(toolName, report.reason))
        return false
    end
    if not labelsMatch(report.labels, wantedLabels) then
        print(("[Ned Gun Firemode README] FAIL %s: expected %s, got %s."):format(
            toolName,
            table.concat(wantedLabels, ", "),
            table.concat(report.labels, ", ")
        ))
        return false
    end

    print(("[Ned Gun Firemode README] PASS %s: modes=%s; auto=%s; V-cycle=%s; start=%d."):format(
        toolName,
        table.concat(report.labels, ", "),
        tostring(report.hasAutomatic),
        tostring(report.supportsCycle),
        report.startingIndex
    ))
    return true
end

if fireModes == nil or inventory == nil then
    print("[Ned Gun Firemode README] FAIL: GunFramework fire-mode test dependencies are missing.")
else
    local passed = 0
    local total = 0
    for toolName, wantedLabels in pairs(expected) do
        total = total + 1
        if runConfigTest(toolName, wantedLabels) then
            passed = passed + 1
        end
    end
    print(("[Ned Gun Firemode README] SUMMARY %d/%d expected weapon fire-mode configs passed."):format(passed, total))
end