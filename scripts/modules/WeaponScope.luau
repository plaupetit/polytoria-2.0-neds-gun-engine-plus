-- WeaponScope: client-only sniper scope, a Camera.FOV toggle bound to the Z key.
-- Role: Toggle/Enable/Disable narrow the camera field of view to the Tool's Config `scopeFov`, remember the
--   previous FOV on the Tool and restore it on toggle-off and on Unequipped.
-- Side: client only.
-- Dependencies (passed per call as `dependencies`, nothing is required from siblings):
--   workspace (the Environment; its CurrentCamera.FOV is read and written).
-- State: pure functions. Per-Tool state lives in tool.Shared (scopeActive, savedFov, copied scopeFov); there is
--   no module-global mutable state, so two scoped Tools can never share a saved FOV.
-- Invariants: Enable never overwrites savedFov while already active (a second Enable would otherwise save the
--   scoped value and lock the player in the zoomed view); Disable is idempotent and safe to call from
--   Unequipped, the runtime safety check and the Z handler.
-- How to test: equip the Sniper, press Z (view narrows to scopeFov), press Z (original FOV returns), press Z
--   then switch Tool or die (original FOV returns without pressing Z again).
local WeaponScope = {}

local function getCamera(dependencies)
    local workspace = dependencies and dependencies.workspace
    return workspace and workspace.CurrentCamera or nil
end

function WeaponScope.HasScope(tool)
    local scopeFov = tool.Shared.scopeFov
    return type(scopeFov) == "number" and scopeFov > 0
end

function WeaponScope.IsActive(tool)
    return tool.Shared.scopeActive == true
end

function WeaponScope.Enable(tool, dependencies)
    if not WeaponScope.HasScope(tool) or WeaponScope.IsActive(tool) then
        return
    end
    local camera = getCamera(dependencies)
    if camera == nil then
        return
    end
    tool.Shared.savedFov = camera.FOV
    tool.Shared.scopeActive = true
    camera.FOV = tool.Shared.scopeFov
end

function WeaponScope.Disable(tool, dependencies)
    if not WeaponScope.IsActive(tool) then
        return
    end
    tool.Shared.scopeActive = false
    local camera = getCamera(dependencies)
    local savedFov = tool.Shared.savedFov
    if camera ~= nil and type(savedFov) == "number" then
        camera.FOV = savedFov
    end
end

function WeaponScope.Toggle(tool, dependencies)
    if WeaponScope.IsActive(tool) then
        WeaponScope.Disable(tool, dependencies)
    else
        WeaponScope.Enable(tool, dependencies)
    end
end

return WeaponScope
