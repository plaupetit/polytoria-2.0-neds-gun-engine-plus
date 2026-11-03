-- WeaponAim: client-side aim screen position, cursor-lock freeze, self-aim ghost and cursor-facing rotation.
-- Role: everything the Client facade used to do for "where am I aiming and which way does the body face".
-- Side: client only (reads Input, the local camera and the local Player/Character).
-- Dependencies (injected through WeaponAim.New(deps), nothing is required from siblings):
--   localPlayer, workspace (the Environment), input (the Input service), hooks (the Hooks service),
--   getEnums() (returns the Enums table or nil), weaponConfig (needs GetHeldTool(player)).
-- State: each WeaponAim.New call owns its own private state (cursor-lock memory, saved rotation mode,
-- hidden avatar colours). There is no module-global mutable state.
-- How to test: in Play equip a gun and move the cursor over the avatar (ghost fade), hold right mouse
-- (aim point must freeze), unequip (colours and RotationMode must be restored).
local WeaponAim = {}

-- CONFIGURATION VARIABLES
-- The fade follows the displayed cursor ray. It must not depend on the
-- camera zoom: a distant cursor over the local avatar still counts as self-aim.
local SELF_AIM_RAY_RANGE = 8192
local AIM_RAY_RANGE = 8192
local SELF_AIM_PLAYER_COLOR_PROPERTIES = {
    "HeadColor",
    "TorsoColor",
    "LeftArmColor",
    "RightArmColor",
    "LeftLegColor",
    "RightLegColor",
}

function WeaponAim.New(deps)
    local localPlayer = deps.localPlayer
    local workspace = deps.workspace
    local input = deps.input
    local hooks = deps.hooks

    -- Alpha 0 is invisible in Polytoria; preserve a clear ghost silhouette instead.
    local selfAimHiddenColor = Color.New(1, 1, 1, 0.35)

    local aim = {}

    -- CURSOR-LOCK STATE
    local lastFreeAimScreenPosition = nil
    local frozenAimScreenPosition = nil
    local cursorWasLocked = false

    -- SELF-AIM GHOST STATE
    -- In Creator 2.0, Player is the character controller and owns its visible body
    -- colours through its Character. Keeping the original Character and colours
    -- makes this client-only cosmetic effect reversible across a respawn without
    -- touching collision, damage, or weapon state.
    local selfAimHiddenColors = {}
    local selfAimHideActive = false
    local selfAimHiddenCharacter = nil

    -- CURSOR-AIM FACING STATE
    -- While a Ned weapon is equipped, cursor-facing owns yaw across Creator's movement pass.
    -- The original rotation mode is restored immediately after the player puts the weapon away.
    local savedRotationMode = nil
    local rotationModeOverridden = false
    local playerRotationMode = nil

    local function getAimScreenPosition()
        local width = input.ScreenWidth or 1920
        local height = input.ScreenHeight or 1080
        local camera = workspace.CurrentCamera
        if camera and camera.IsFirstPerson then
            -- First person must use the displayed centre reticle, not the cursor position saved before the camera lock.
            cursorWasLocked = false
            frozenAimScreenPosition = nil
            return Vector2.New(width * 0.5, height * 0.5)
        end
        if input.CursorLocked then
            if not cursorWasLocked or frozenAimScreenPosition == nil then
                -- Capture the free mouse coordinate before right-click camera lock centres the native pointer.
                frozenAimScreenPosition = lastFreeAimScreenPosition or Vector2.New(width * 0.5, height * 0.5)
            end
            cursorWasLocked = true
            return frozenAimScreenPosition
        end

        local mousePosition = input.MousePosition
        if mousePosition == nil then
            return frozenAimScreenPosition or Vector2.New(width * 0.5, height * 0.5)
        end
        cursorWasLocked = false
        frozenAimScreenPosition = nil
        -- Creator's camera ray uses the same bottom-origin Y space as the displayed UI cursor.
        -- Input.MousePosition remains top-origin, so convert only at this camera boundary.
        lastFreeAimScreenPosition = Vector2.New(mousePosition.X, height - mousePosition.Y)
        return lastFreeAimScreenPosition
    end

    local function getPlayerRotationMode()
        if playerRotationMode ~= nil then
            return playerRotationMode
        end

        -- ScriptService does not always inject Enums as a global, unlike Tool ClientScripts.
        local engineEnums = deps.getEnums()
        if engineEnums and engineEnums.PlayerRotationMode then
            playerRotationMode = engineEnums.PlayerRotationMode.MovementCtrlLockOnly
        end
        return playerRotationMode
    end

    local function getHeldWeapon()
        local ok, heldTool = pcall(function()
            return deps.weaponConfig.GetHeldTool(localPlayer)
        end)
        if not ok or heldTool == nil then
            return nil
        end

        local heldIsGun = false
        pcall(function()
            heldIsGun = heldTool.Shared.gun == true
        end)
        return heldIsGun and heldTool or nil
    end

    local function restoreMovementRotation()
        if not rotationModeOverridden or localPlayer == nil then
            return
        end
        pcall(function()
            localPlayer.RotationMode = savedRotationMode
        end)
        savedRotationMode = nil
        rotationModeOverridden = false
    end

    local function claimCursorRotation()
        if rotationModeOverridden or localPlayer == nil then
            return
        end
        local cursorRotationMode = getPlayerRotationMode()
        if cursorRotationMode == nil then
            return
        end
        pcall(function()
            savedRotationMode = localPlayer.RotationMode
            localPlayer.RotationMode = cursorRotationMode
            rotationModeOverridden = true
        end)
    end

    local function getSelfAimIgnore(heldTool)
        -- Player and Character can be separate raycast owners in Creator 2.0.
        -- Ignoring both keeps looking down from selecting the shooter's own body.
        local ignore = {heldTool}
        if localPlayer ~= nil then
            table.insert(ignore, localPlayer)
            if localPlayer.Character ~= nil then
                table.insert(ignore, localPlayer.Character)
            end
        end
        return ignore
    end

    local function restoreSelfAimVisibility()
        if not selfAimHideActive then
            return
        end
        for propertyName, originalColor in pairs(selfAimHiddenColors) do
            pcall(function()
                selfAimHiddenCharacter[propertyName] = originalColor
            end)
        end
        selfAimHiddenColors = {}
        selfAimHiddenCharacter = nil
        selfAimHideActive = false
    end

    local function setSelfAimVisibility(hidden)
        if hidden == selfAimHideActive then
            return
        end
        if not hidden then
            restoreSelfAimVisibility()
            return
        end

        local character = localPlayer and localPlayer.Character
        if character == nil then
            return
        end
        local changedAnyColor = false
        for _, propertyName in ipairs(SELF_AIM_PLAYER_COLOR_PROPERTIES) do
            local colorOk, originalColor = pcall(function()
                return character[propertyName]
            end)
            if colorOk and originalColor ~= nil then
                local hideOk = pcall(function()
                    -- Creator 2.0 renders the current avatar through Character, not Player.
                    character[propertyName] = selfAimHiddenColor
                end)
                if hideOk then
                    selfAimHiddenColors[propertyName] = originalColor
                    changedAnyColor = true
                end
            end
        end
        selfAimHiddenCharacter = changedAnyColor and character or nil
        selfAimHideActive = changedAnyColor
    end

    local function isLocalPlayerRayHit(hitInstance)
        local current = hitInstance
        while current ~= nil do
            if current == localPlayer then
                return true
            end
            local parentOk, parent = pcall(function()
                return current:GetParent()
            end)
            if not parentOk then
                return false
            end
            current = parent
        end
        return false
    end

    local function cursorTouchesLocalPlayer(heldTool)
        local camera = workspace.CurrentCamera
        local screenPosition = getAimScreenPosition()
        if camera == nil or screenPosition == nil or localPlayer == nil then
            return false
        end

        -- Do not ignore localPlayer here. This probe deliberately asks whether the
        -- displayed cursor ray intersects the local avatar, while the firing ray
        -- below continues to ignore it and reaches the world behind the player.
        local rayOk, ray = pcall(function()
            return camera:ScreenPointToRay(screenPosition, {heldTool}, SELF_AIM_RAY_RANGE)
        end)
        if not rayOk or ray == nil or ray.Origin == nil or ray.Direction == nil or ray.Direction.Magnitude <= 0.0001 then
            return false
        end
        local hit = workspace:Raycast(ray.Origin, ray.Direction.Normalized, SELF_AIM_RAY_RANGE, {heldTool})
        return hit ~= nil and isLocalPlayerRayHit(hit.Instance)
    end

    local function shouldHideLocalPlayer(heldTool)
        return cursorTouchesLocalPlayer(heldTool)
    end

    local function getWeaponAimPoint(heldTool)
        -- Resolve the cursor ray through the ignored local avatar. Only a real
        -- world impact becomes a cursor-facing target; an air endpoint can be
        -- behind the player when looking up or beyond the playable world.
        local screenPosition = getAimScreenPosition()
        local camera = workspace.CurrentCamera
        if screenPosition == nil or camera == nil then
            return nil
        end
        local rayOk, ray = pcall(function()
            return camera:ScreenPointToRay(screenPosition, getSelfAimIgnore(heldTool), AIM_RAY_RANGE)
        end)
        if not rayOk or ray == nil or ray.Origin == nil or ray.Direction == nil or ray.Direction.Magnitude <= 0.0001 then
            local worldPointOk, worldPoint = pcall(function()
                return input:GetMouseWorldPosition(getSelfAimIgnore(heldTool))
            end)
            return worldPointOk and worldPoint or nil
        end
        local direction = ray.Direction.Normalized
        local hit = workspace:Raycast(ray.Origin, direction, AIM_RAY_RANGE, getSelfAimIgnore(heldTool))
        -- This target is shared conceptually with WeaponFire: self collision is
        -- ignored, but a ground/wall behind the player remains the aim destination.
        return hit and hit.Position or nil
    end

    local function getForwardFacingPoint()
        local camera = workspace.CurrentCamera
        if camera == nil or localPlayer == nil then
            return nil
        end
        local forwardOk, forward = pcall(function()
            return camera.Forward
        end)
        if not forwardOk or forward == nil then
            forward = localPlayer.Forward
        end
        local flatForward = Vector3.New(forward.X, 0, forward.Z)
        if flatForward.Magnitude <= 0.0001 then
            return nil
        end
        -- A no-hit cursor uses camera forward, so looking into the sky cannot turn the body back.
        return localPlayer.Position + flatForward.Normalized * AIM_RAY_RANGE
    end

    local function updateWeaponFacing()
        local heldTool = getHeldWeapon()
        if localPlayer == nil or heldTool == nil then
            restoreSelfAimVisibility()
            restoreMovementRotation()
            return
        end
        if input.IsWindowFocused ~= true or input.IsGameFocused ~= true or input.IsInputFocused == true then
            restoreSelfAimVisibility()
            return
        end

        setSelfAimVisibility(shouldHideLocalPlayer(heldTool))
        claimCursorRotation()
        local aimPoint = getWeaponAimPoint(heldTool)
        if aimPoint == nil then
            aimPoint = getForwardFacingPoint()
        end
        if aimPoint == nil then
            return
        end
        local playerPosition = localPlayer.Position
        local flatTarget = Vector3.New(aimPoint.X, playerPosition.Y, aimPoint.Z)
        if math.abs(flatTarget.X - playerPosition.X) <= 0.0001 and math.abs(flatTarget.Z - playerPosition.Z) <= 0.0001 then
            return
        end

        -- Player and Character are distinct engine owners; write both on each render boundary.
        pcall(function()
            localPlayer:LookAt(flatTarget)
            local character = localPlayer.Character
            if character ~= nil then
                character:LookAt(flatTarget)
            end
        end)
    end

    -- Returns the cursor (or centre, in first person / locked) screen position in bottom-origin UI space.
    -- Must be called every frame by the owner so the free cursor is cached before a right-click lock.
    function aim:GetAimScreenPosition()
        return getAimScreenPosition()
    end

    function aim:UpdateFacing()
        updateWeaponFacing()
    end

    -- Binds updateWeaponFacing to the render hooks that exist in this Creator build.
    -- Returns (anyBound, preBound, postBound). When neither hook bound, the caller must run
    -- UpdateFacing from its own per-frame update; when one bound, it must NOT, so yaw is never written a third time.
    function aim:BindHooks()
        local facingPreHookBound = false
        local facingPostHookBound = false
        pcall(function()
            hooks.PreRendered:Connect(function()
                updateWeaponFacing()
            end)
            facingPreHookBound = true
        end)
        pcall(function()
            hooks.PostRendered:Connect(function()
                updateWeaponFacing()
            end)
            facingPostHookBound = true
        end)
        return facingPreHookBound or facingPostHookBound, facingPreHookBound, facingPostHookBound
    end

    return aim
end

return WeaponAim
