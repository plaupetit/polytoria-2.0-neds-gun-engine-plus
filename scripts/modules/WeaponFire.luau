-- WeaponFire sends aim directions only; WeaponServer validates rays, ammunition and damage.
-- ComputeAim(tool, shootPos, dependencies) is the shared aim resolver: Fire uses it, and Client also hands it to
-- WeaponThrowable (the Grenade throws along the same cursor aim). Side: client only.
local WeaponFire = {}

local MAX_IGNORED_RAYCASTS = 32

-- Local fallback, used only when the caller did not inject GunUtil.RaycastSkippingIgnored.
-- A RayResult can be valid while Instance is nil, so do not dereference it until it is guarded.
-- The bounded loop replaces recursive retries and prevents an ignored-object chain from overflowing.
local function fallbackRaycastSkippingIgnored(environment, origin, direction, maxRange, ignore, maxSkips)
    for _ = 1, maxSkips do
        local hit = environment:Raycast(origin, direction, maxRange, ignore)
        local instance = hit and hit.Instance
        if instance == nil or instance:FindChild("!Ignore") == nil then
            return hit
        end
        table.insert(ignore, instance)
    end
    return nil
end

local function raycastThroughIgnoredInstances(dependencies, origin, direction, maxRange, ignore)
    local raycast = dependencies.raycastSkippingIgnored or fallbackRaycastSkippingIgnored
    return raycast(dependencies.workspace, origin, direction, maxRange, ignore, MAX_IGNORED_RAYCASTS)
end

local function getAimWorldPosition(dependencies, ignore, maxRange)
    local screenPosition = nil
    if dependencies.getAimScreenPosition then
        pcall(function()
            screenPosition = dependencies.getAimScreenPosition()
        end)
    end
    local camera = dependencies.workspace.CurrentCamera
    if screenPosition and camera then
        local rayOk, ray = pcall(function()
            return camera:ScreenPointToRay(screenPosition, ignore, maxRange)
        end)
        if rayOk and ray and ray.Origin and ray.Direction and ray.Direction.Magnitude > 0.0001 then
            local direction = ray.Direction.Normalized
            -- Resolve the screen ray ourselves so it continues beyond an ignored
            -- local avatar and reaches the ground or world object behind it.
            local cameraHit = raycastThroughIgnoredInstances(
                dependencies,
                ray.Origin,
                direction,
                maxRange,
                ignore
            )
            if cameraHit and cameraHit.Position then
                return cameraHit.Position, true
            end
            -- An air endpoint can be behind the player in a steep third-person
            -- view. Fire therefore uses its safe forward fallback for no-hit rays.
            return nil, false
        end
    end

    -- Native input is only a fallback when Creator cannot build a screen ray.
    local mouseWorldPosition = nil
    local mouseWorldOk = pcall(function()
        mouseWorldPosition = dependencies.input:GetMouseWorldPosition(ignore)
    end)
    if mouseWorldOk and mouseWorldPosition ~= nil then
        return mouseWorldPosition, true
    end
    return nil, false
end

local function getForwardFallbackDirection(dependencies)
    local camera = dependencies.workspace.CurrentCamera
    local forward = camera and camera.Forward or dependencies.localPlayer.Forward
    if forward == nil or forward.Magnitude <= 0.0001 then
        return nil
    end
    -- Camera.Forward retains the viewed forward direction for sky/no-hit shots.
    return forward.Normalized
end

function WeaponFire.GetFireDelay(tool)
    if tool.Shared.useDelay == true then
        return tool.Shared.firerate
    end
    return 60 / tool.Shared.firerate
end

function WeaponFire.CanFire(tool)
    return os.clock() - tool.Shared.lastFired >= WeaponFire.GetFireDelay(tool)
end


function WeaponFire.CheckPump(tool, handle, dependencies)
    if tool.Shared.pumped == true then
        return
    end
    dependencies.findChildAndDoFunc(handle, "Pump", dependencies.playSound)
    wait(tool.Shared.pumpDelay)
    tool.Shared.pumped = true
end

function WeaponFire.PlayShootSound(tool, handle, shootPos, dependencies)
    if tool and tool.Shared.pumpAction then
        tool.Shared.pumped = false
    end
    dependencies.findChildAndDoFunc(shootPos, "Fire", dependencies.playSound)

    if tool.Shared.pumpAction == true and tool.Shared.ammo > 0 then
        wait(tool.Shared.beforePumpDelay)
        dependencies.checkPump(tool, handle)
    end
end

-- Resolves where a shot (or a throw) starts and which way it points, from the same cursor/camera aim the guns use.
-- Returns barrelPos, aimDirection; aimDirection is nil when no usable direction exists (callers skip silently).
-- `dependencies` is the same table as for Fire (localPlayer, workspace, vfxsModel, input, getAimScreenPosition,
-- raycastSkippingIgnored). Extracted from Fire without behaviour change so WeaponThrowable shares one aim path.
function WeaponFire.ComputeAim(tool, shootPos, dependencies)
    local localPos = dependencies.localPlayer.Position + Vector3.New(0, 1.5, 0)
    local owner = tool.Parent
    -- Cursor world queries must not stop on the local avatar when the camera
    -- looks down. Include both Player and Character because Creator exposes
    -- them as distinct collision owners during replication.
    local ignore = {dependencies.vfxsModel, owner, dependencies.localPlayer, tool}
    local character = dependencies.localPlayer and dependencies.localPlayer.Character or nil
    if character ~= nil then
        table.insert(ignore, character)
    end

    -- Native mouse-world aiming is preferred; a frozen camera coordinate is fallback-only.
    local worldMousePos, hasWorldImpact = getAimWorldPosition(dependencies, ignore, 8192)
    -- Both the collision ray and the visible tracer must start at the same muzzle point.
    -- The player-height fallback preserves firing if a weapon attachment is temporarily absent.
    local barrelPos = shootPos and shootPos.Position or localPos

    local aimDirection = nil
    if hasWorldImpact and worldMousePos ~= nil and (worldMousePos - barrelPos).Magnitude > 0.0001 then
        aimDirection = (worldMousePos - barrelPos).Normalized
    else
        aimDirection = getForwardFallbackDirection(dependencies)
    end
    return barrelPos, aimDirection
end

function WeaponFire.Fire(tool, handle, shootPos, dependencies)
    local toolShared = tool.Shared
    if toolShared.pumpAction and not toolShared.pumped then
        return
    end
    if toolShared.ammo <= 0 or toolShared.reloading or not toolShared.canfire or not toolShared.wishfire then
        return
    end

    local barrelPos, aimDirection = WeaponFire.ComputeAim(tool, shootPos, dependencies)
    local shots = {}
    if aimDirection == nil then
        -- No usable direction: skip the shot silently. Ammo, lastFired and canfire are untouched,
        -- so a failed aim can never burn a round without a shot.
        return
    end

    -- The shot is now certain: consume the round and the fire gate.
    toolShared.lastFired = os.clock()
    toolShared.canfire = false
    dependencies.addAmmo(tool, -1)

    for _ = 1, toolShared.bullets do
        -- Do not send client raycast hits or client spread: the first endpoint is aim only.
        table.insert(shots, {barrelPos + aimDirection * 8192, Vector3.New(0, 1, 0)})
    end

    local message = NetMessage.New()
    message:AddInt("m", toolShared.bullets)
    -- The server's player/tool replica can lag behind Creator 2.0 client movement.
    -- Send the local muzzle separately so the server can bound and validate its ray origin.
    message:AddVector3("origin", barrelPos)
    for index, shotData in pairs(shots) do
        message:AddVector3(tostring(index), shotData[1])
        message:AddVector3("n" .. tostring(index), shotData[2])
    end
    dependencies.remotes["CreateBullet"]:InvokeServer(message)

    dependencies.doShootSound(tool, handle, shootPos)
end

return WeaponFire
