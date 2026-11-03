-- WeaponServer is the multiplayer authority: clients submit aim directions, never trusted hits or ammo.
-- Dependencies: Connect(remotes, getTool, environment, gunUtil?). gunUtil is optional; when it provides
-- RaycastSkippingIgnored that shared bounded loop is used, otherwise the local fallback below runs.
local WeaponServer = {}
local MAX_RANGE = 8192
local MAX_IGNORED_RAYCASTS = 32
local MAX_CLIENT_ORIGIN_DRIFT = 160

-- CONFIGURATION VARIABLES
-- Global server-owned switch for every one-projectile weapon (pistol/rifle).
-- Set false to retain the cursor-to-endpoint aim exactly; multi-pellet guns
-- keep their configured cone so the shotgun can never become a damage laser.
local ENABLE_SINGLE_PROJECTILE_SPREAD = true

-- Per-Tool server state. Weak keys: every respawn clones new Tools, and a strong table would keep
-- the state of every destroyed Tool alive for the whole session (server memory leak).
local states = setmetatable({}, { __mode = "k" })

local function resolveDamageableTarget(hit)
    local candidate = hit
    while candidate do
        if candidate:IsA("NPC") or candidate:IsA("Player") then
            return candidate
        end
        candidate = candidate.Parent
    end
    return nil
end

local function getFireDelay(config)
    if config.useDelay == true then
        return config.firerate
    end
    return 60 / config.firerate
end

local function randomFloat(lower, upper)
    return lower + math.random() * (upper - lower)
end

local function getForward(pitch, yaw)
    return Vector3.New(math.cos(pitch) * math.sin(yaw), -math.sin(pitch), math.cos(pitch) * math.cos(yaw))
end

local function applyServerSpread(direction, spreadDegrees)
    local spreadRadians = math.rad(spreadDegrees or 0)
    if spreadRadians <= 0 then
        return direction
    end
    local pitch = math.asin(-direction.y)
    local yaw = math.atan2(direction.x, direction.z)
    -- Pellet spread is randomised here so a client cannot collapse a shotgun into one perfect ray.
    return getForward(
        pitch + randomFloat(-spreadRadians, spreadRadians),
        yaw + randomFloat(-spreadRadians, spreadRadians)
    )
end

local function getEffectiveSpreadDegrees(config)
    -- The toggle intentionally affects only one-ray weapons. Shotguns still
    -- need a cone while this first global setting has no fixed-pattern design.
    if config.bullets == 1 and not ENABLE_SINGLE_PROJECTILE_SPREAD then
        return 0
    end
    return config.spread or 0
end

local function loadRound(state, config)
    if state.ammo >= config.maxAmmo then
        return false
    end
    if config.limitedAmmo and state.reserve <= 0 then
        return false
    end

    local amount = math.min(config.reloadAdd or 1, config.maxAmmo - state.ammo)
    if config.limitedAmmo then
        amount = math.min(amount, state.reserve)
        state.reserve = state.reserve - amount
    end
    state.ammo = state.ammo + amount
    return amount > 0
end

local function updateReload(state, config, now)
    if not state.reloading then
        return
    end

    if config.reloadType == 1 then
        if now >= state.reloadEndsAt then
            local amount = config.maxAmmo - state.ammo
            if config.limitedAmmo then
                amount = math.min(amount, state.reserve)
                state.reserve = state.reserve - amount
            end
            state.ammo = state.ammo + amount
            state.reloading = false
        end
        return
    end

    while state.reloading and now >= state.nextShellAt do
        if not loadRound(state, config) then
            state.reloading = false
            break
        end
        state.nextShellAt = state.nextShellAt + config.reloadShellDelay
        if state.ammo >= config.maxAmmo or (config.limitedAmmo and state.reserve <= 0) then
            state.reloading = false
        end
    end
end

local function requestReload(state, config, now)
    updateReload(state, config, now)
    if state.reloading or state.ammo >= config.maxAmmo then
        return
    end
    if config.limitedAmmo and state.reserve <= 0 then
        return
    end

    state.reloading = true
    if config.reloadType == 1 then
        state.reloadEndsAt = now + config.reloadTime
        return
    end

    -- Shell reloads load one round immediately, then continue at the configured interval.
    if loadRound(state, config) then
        state.nextShellAt = now + config.reloadShellDelay
    else
        state.reloading = false
    end
end

local function getState(tool, config)
    local state = states[tool]
    if state == nil then
        state = {
            ammo = config.maxAmmo,
            reserve = config.storedAmmo or 0,
            lastShotAt = -math.huge,
            reloading = false,
            reloadEndsAt = 0,
            nextShellAt = 0,
        }
        states[tool] = state
    end
    return state
end

-- Local fallback with the same contract as GunUtil.RaycastSkippingIgnored (used only when it is not injected).
-- A RayResult can carry a nil Instance, so it is guarded; the loop is bounded by maxSkips.
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

local function getMessageBool(message, key)
    local ok, value = pcall(function()
        return message:GetBool(key)
    end)
    return ok and value == true
end

local function getValidatedRayOrigin(message, serverMuzzlePosition)
    local originOk, clientOrigin = pcall(function()
        return message:GetVector3("origin")
    end)
    -- Only accept the explicit client muzzle while it remains near the server's
    -- known tool replica. Older clients and malformed payloads retain server origin.
    if originOk and clientOrigin ~= nil
        and (clientOrigin - serverMuzzlePosition).Magnitude <= MAX_CLIENT_ORIGIN_DRIFT then
        return clientOrigin
    end
    return serverMuzzlePosition
end

function WeaponServer.Connect(remotes, getTool, environment, gunUtil)
    local raycastSkippingIgnored = gunUtil and gunUtil.RaycastSkippingIgnored or fallbackRaycastSkippingIgnored
    remotes["CreateBullet"].InvokedServer:Connect(function(sender, message)
        local tool = getTool(sender)
        if not tool then
            return
        end

        local configOk, config = pcall(function()
            return require(tool["Config"])
        end)
        if not configOk or type(config) ~= "table" or type(config.maxAmmo) ~= "number"
            or type(config.firerate) ~= "number" or config.firerate <= 0
            or type(config.bullets) ~= "number" or config.bullets < 1
            -- math.random(minDamage, maxDamage) below needs both bounds, in order.
            or type(config.minDamage) ~= "number" or type(config.maxDamage) ~= "number"
            or config.minDamage > config.maxDamage then
            return
        end

        local now = os.clock()
        local state = getState(tool, config)
        if getMessageBool(message, "reload") then
            requestReload(state, config, now)
            return
        end

        updateReload(state, config, now)
        if state.reloading and config.reloadType == 1 then
            return
        end
        if state.ammo <= 0 or now - state.lastShotAt < getFireDelay(config) then
            return
        end

        local countOk, shotCount = pcall(function()
            return message:GetInt("m")
        end)
        -- A gun's pellet count comes solely from its server-side Config module.
        if not countOk or shotCount ~= config.bullets then
            return
        end

        local handle = tool:FindChild("Handle")
        local shootPos = handle and handle:FindChild("ShootPos") or nil
        if shootPos == nil then
            return
        end

        local endpointOk, endpoint = pcall(function()
            return message:GetVector3("1")
        end)
        if not endpointOk or endpoint == nil then
            return
        end
        local rayOrigin = getValidatedRayOrigin(message, shootPos.Position)
        local aimOffset = endpoint - rayOrigin
        if aimOffset.Magnitude <= 0.001 then
            return
        end
        local aimDirection = aimOffset.Normalized
        local effectiveSpreadDegrees = getEffectiveSpreadDegrees(config)
        local directions = {}
        for index = 1, shotCount do
            directions[index] = applyServerSpread(aimDirection, effectiveSpreadDegrees)
        end

        -- An accepted shot interrupts a shell reload but never bypasses a magazine reload.
        state.reloading = false
        state.ammo = state.ammo - 1
        state.lastShotAt = now
        if sender:FindChild("Protect") then
            sender["Protect"]:Destroy()
        end

        local effectMessage = NetMessage.New()
        effectMessage:AddInstance("s", sender)
        effectMessage:AddInstance("o", shootPos)
        effectMessage:AddInt("m", shotCount)
        effectMessage:AddInt("serverAmmo", state.ammo)
        local hitConfirmed = false
        local damage = math.random(config.minDamage, config.maxDamage)

        for index = 1, shotCount do
            local hit = raycastSkippingIgnored(environment, rayOrigin, directions[index], MAX_RANGE, {sender, tool}, MAX_IGNORED_RAYCASTS)
            local endpoint = hit and hit.Position or rayOrigin + directions[index] * MAX_RANGE
            local normal = hit and hit.Normal or Vector3.New(0, 1, 0)
            local instance = hit and hit.Instance or nil
            effectMessage:AddVector3(tostring(index), endpoint)
            effectMessage:AddVector3("n" .. tostring(index), normal)
            if instance then
                effectMessage:AddInstance("h" .. tostring(index), instance)
                local target = resolveDamageableTarget(instance)
                if target and not target:FindChild("Protect") and target.Health > 0 then
                    target.Health = target.Health - damage
                    hitConfirmed = true
                end
            end
        end

        -- Broadcast only server-generated endpoints so every client sees the same valid tracer.
        effectMessage:AddBool("hitConfirmed", hitConfirmed)
        remotes["CreateBullet"]:InvokeClients(effectMessage)
    end)
end

return WeaponServer
