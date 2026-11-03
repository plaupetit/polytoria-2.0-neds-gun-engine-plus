-- GunAimNetworkDebug is a read-only ClientScript for diagnosing cursor-to-server shot drift.
-- Creator placement: World/ScriptService/GunFramework/Scripts/GunAimNetworkDebug.
-- It observes existing weapon-fire state and the CreateBullet reply; it never sends a message,
-- changes aim, modifies damage/ammo, or changes any gameplay object.

-- Off by default so a published game does not spam the console or pay a per-shot cost; set true only while diagnosing.
local DEBUG_ENABLED = false
local MAX_RANGE = 8192
local RESPONSE_TIMEOUT_SECONDS = 0.75
local MAX_PENDING_SHOTS = 16

local function waitChild(parent, childName)
    local child = parent:FindChild(childName)
    while child == nil do
        wait()
        child = parent:FindChild(childName)
    end
    return child
end

local function formatVector3(value)
    if value == nil then
        return "nil"
    end
    return ("(%.2f, %.2f, %.2f)"):format(value.X, value.Y, value.Z)
end

local function formatVector2(value)
    if value == nil then
        return "nil"
    end
    return ("(%.2f, %.2f)"):format(value.X, value.Y)
end

local function angleDegrees(left, right)
    if left == nil or right == nil or left.Magnitude <= 0.0001 or right.Magnitude <= 0.0001 then
        return nil
    end
    local dot = math.max(-1, math.min(1, left.Normalized:Dot(right.Normalized)))
    return math.deg(math.acos(dot))
end

local environment = game["Environment"]
local hidden = game["Hidden"]
local input = game["Input"]
local players = game["Players"]
local hooks = game["Hooks"]
local localPlayer = players.LocalPlayer
local remotes = waitChild(hidden, "Remotes")
local createBullet = waitChild(remotes, "CreateBullet")

-- SCRIPT CONTEXT VARIABLES
-- The FIFO only pairs local click samples with the next server-approved response.
-- It is diagnostic metadata, not weapon state and is intentionally bounded.
local pendingShots = {}
local observedTools = {}
local observedLastFired = {}

local function getClientAimSample(tool)
    local camera = environment.CurrentCamera
    local handle = tool:FindChild("Handle")
    local shootPos = handle and handle:FindChild("ShootPos") or nil
    local rawMouse = input.MousePosition
    local screenHeight = input.ScreenHeight or 1080
    local rayScreenPosition = nil
    local cameraRay = nil
    local cameraHit = nil
    local mouseWorldPosition = nil

    if rawMouse ~= nil then
        -- Creator's ScreenPointToRay uses the same bottom-origin Y basis as the gun's live aim code.
        rayScreenPosition = Vector2.New(rawMouse.X, screenHeight - rawMouse.Y)
    end

    if camera ~= nil and rayScreenPosition ~= nil then
        pcall(function()
            cameraRay = camera:ScreenPointToRay(rayScreenPosition, { tool, localPlayer }, MAX_RANGE)
        end)
        if cameraRay ~= nil and cameraRay.Origin ~= nil and cameraRay.Direction ~= nil
            and cameraRay.Direction.Magnitude > 0.0001 then
            pcall(function()
                cameraHit = environment:Raycast(
                    cameraRay.Origin,
                    cameraRay.Direction.Normalized,
                    MAX_RANGE,
                    { tool, localPlayer }
                )
            end)
        end
    end

    pcall(function()
        mouseWorldPosition = input:GetMouseWorldPosition({ tool, localPlayer })
    end)

    local requestedAimPoint = cameraHit and cameraHit.Position or nil
    if requestedAimPoint == nil and cameraRay ~= nil and cameraRay.Origin ~= nil and cameraRay.Direction ~= nil
        and cameraRay.Direction.Magnitude > 0.0001 then
        requestedAimPoint = cameraRay.Origin + cameraRay.Direction.Normalized * MAX_RANGE
    end

    local muzzlePosition = shootPos and shootPos.Position or nil
    local muzzleDirection = nil
    if requestedAimPoint ~= nil and muzzlePosition ~= nil and (requestedAimPoint - muzzlePosition).Magnitude > 0.0001 then
        muzzleDirection = (requestedAimPoint - muzzlePosition).Normalized
    end

    return {
        firedAt = os.clock(),
        toolName = tool.Name,
        rawMouse = rawMouse,
        rayScreenPosition = rayScreenPosition,
        cursorLocked = input.CursorLocked == true,
        firstPerson = camera and camera.IsFirstPerson == true,
        cameraPosition = camera and camera.Position or nil,
        cameraForward = camera and camera.Forward or nil,
        localMouseWorldPosition = mouseWorldPosition,
        cameraAimPoint = requestedAimPoint,
        clientMuzzlePosition = muzzlePosition,
        clientMuzzleDirection = muzzleDirection,
        cameraHitName = cameraHit and cameraHit.Instance and cameraHit.Instance.Name or "none",
        -- WeaponRuntime copies the active Config into Shared. These values explain why a click can be a valid no-shot.
        ammo = tool.Shared.ammo,
        maxAmmo = tool.Shared.maxAmmo,
        reloading = tool.Shared.reloading == true,
        reloadType = tool.Shared.reloadType,
        pumpAction = tool.Shared.pumpAction == true,
        pumped = tool.Shared.pumped == true,
        canFire = tool.Shared.canfire == true,
        wishFire = tool.Shared.wishfire == true,
        firemode = tool.Shared.firemodeText,
        pelletCount = tool.Shared.bullets,
        configuredSpreadDegrees = tool.Shared.spread,
    }
end

local function printClientSample(sample)
    print(("[GunAimDebug] CLICK tool=%s locked=%s firstPerson=%s rawMouse=%s rayScreen=%s")
        :format(sample.toolName, tostring(sample.cursorLocked), tostring(sample.firstPerson),
            formatVector2(sample.rawMouse), formatVector2(sample.rayScreenPosition)))
    print(("[GunAimDebug] CLIENT camera=%s forward=%s mouseWorld=%s cameraHit=%s (%s) muzzle=%s direction=%s")
        :format(formatVector3(sample.cameraPosition), formatVector3(sample.cameraForward),
            formatVector3(sample.localMouseWorldPosition), formatVector3(sample.cameraAimPoint), sample.cameraHitName,
            formatVector3(sample.clientMuzzlePosition), formatVector3(sample.clientMuzzleDirection)))
    print(("[GunAimDebug] WEAPON ammo=%s/%s reload=%s(type=%s) pump=%s/armed=%s canFire=%s wishFire=%s mode=%s pellets=%s spread=%s degrees")
        :format(tostring(sample.ammo), tostring(sample.maxAmmo), tostring(sample.reloading), tostring(sample.reloadType),
            tostring(sample.pumpAction), tostring(sample.pumped), tostring(sample.canFire), tostring(sample.wishFire),
            tostring(sample.firemode), tostring(sample.pelletCount), tostring(sample.configuredSpreadDegrees)))
end

local function recordFiredShot(tool, firedAt)
    if not DEBUG_ENABLED then
        return
    end
    local sample = getClientAimSample(tool)
    sample.firedAt = firedAt
    if #pendingShots >= MAX_PENDING_SHOTS then
        table.remove(pendingShots, 1)
    end
    table.insert(pendingShots, sample)
    printClientSample(sample)
end

local function observeTool(tool)
    -- No Tool is equipped during spawn and after unequip; this diagnostic must stay silent then.
    if tool == nil then
        return
    end
    if observedTools[tool] then
        return
    end
    local mouse0 = tool:FindChild("Mouse0")
    if mouse0 == nil then
        return
    end
    observedTools[tool] = true
    -- lastFired changes only when WeaponFire accepts a local shot, including every AUTO round.
    observedLastFired[tool] = tool.Shared.lastFired
end

local function getHeldTool()
    if localPlayer == nil then
        return nil
    end
    return localPlayer:FindChildByClass("Tool")
end

createBullet.InvokedClient:Connect(function(firstArgument, secondArgument)
    if not DEBUG_ENABLED then
        return
    end

    -- Creator callbacks have appeared with either (sender, message) or (message) shapes.
    -- Probe both safely so the observer cannot hide the very server reply it is meant to report.
    local message = secondArgument
    local sender = nil
    local senderOk = pcall(function()
        sender = message:GetInstance("s")
    end)
    if not senderOk or sender == nil then
        message = firstArgument
        senderOk = pcall(function()
            sender = message:GetInstance("s")
        end)
    end
    if not senderOk or sender == nil then
        print("[GunAimDebug] NET_REPLY_UNREADABLE: CreateBullet callback did not contain a readable NetMessage.")
        return
    end
    if sender ~= localPlayer then
        return
    end

    local sample = table.remove(pendingShots, 1)
    local serverMuzzle = nil
    pcall(function()
        serverMuzzle = message:GetInstance("o")
    end)
    local serverMuzzlePosition = serverMuzzle and serverMuzzle.Position or nil
    local pellets = {}
    local expectedPelletCount = sample and sample.pelletCount or MAX_PENDING_SHOTS
    for index = 1, expectedPelletCount do
        local endpoint = nil
        local normal = nil
        local hit = nil
        local endpointOk = pcall(function()
            endpoint = message:GetVector3(tostring(index))
            normal = message:GetVector3("n" .. tostring(index))
            hit = message:GetInstance("h" .. tostring(index))
        end)
        if not endpointOk or endpoint == nil then
            break
        end
        table.insert(pellets, { endpoint = endpoint, normal = normal, hit = hit })
    end

    local clientToServerMuzzle = sample and sample.clientMuzzlePosition and serverMuzzlePosition
        and (serverMuzzlePosition - sample.clientMuzzlePosition).Magnitude or nil
    local responseDelay = sample and (os.clock() - sample.firedAt) or nil

    print(("[GunAimDebug] SERVER muzzle=%s acceptedPellets=%d")
        :format(formatVector3(serverMuzzlePosition), #pellets))
    print(("[GunAimDebug] COMPARE response=%.3fs muzzleDrift=%s")
        :format(responseDelay or -1, clientToServerMuzzle and string.format("%.3f", clientToServerMuzzle) or "n/a"))

    local firstDirection = nil
    for index, pellet in ipairs(pellets) do
        local serverDirection = serverMuzzlePosition and (pellet.endpoint - serverMuzzlePosition) or nil
        if firstDirection == nil then
            firstDirection = serverDirection
        end
        local deviationFromAim = sample and angleDegrees(sample.clientMuzzleDirection, serverDirection) or nil
        local coneFromFirst = angleDegrees(firstDirection, serverDirection)
        print(("[GunAimDebug] PELLET %d endpoint=%s hit=%s normal=%s aimDeviation=%s degrees coneFromFirst=%s degrees")
            :format(index, formatVector3(pellet.endpoint), pellet.hit and pellet.hit.Name or "none", formatVector3(pellet.normal),
                deviationFromAim and string.format("%.3f", deviationFromAim) or "n/a",
                coneFromFirst and string.format("%.3f", coneFromFirst) or "n/a"))
    end
end)

-- EVENT / TRIGGER: discover the local equipped Tool after the normal runtime creates Mouse0.
-- ACTION / TASK / DO: log a stale request when the server does not approve a shot in time.
hooks.Updated:Connect(function()
    local tool = getHeldTool()
    observeTool(tool)
    if tool ~= nil and observedTools[tool] then
        local currentLastFired = tool.Shared.lastFired
        if currentLastFired ~= nil and currentLastFired ~= observedLastFired[tool] then
            observedLastFired[tool] = currentLastFired
            recordFiredShot(tool, currentLastFired)
        end
    end
    local now = os.clock()
    while #pendingShots > 0 and now - pendingShots[1].firedAt > RESPONSE_TIMEOUT_SECONDS do
        local timedOut = table.remove(pendingShots, 1)
        print(("[GunAimDebug] NO_SERVER_REPLY tool=%s after %.3fs; the shot may have been rejected or rate-limited.")
            :format(timedOut.toolName, now - timedOut.firedAt))
    end
end)

-- Announce only when enabled: a disabled diagnostic must stay silent in a published game.
if DEBUG_ENABLED then
    print("[GunAimDebug] Ready. Set DEBUG_ENABLED = false or disable this ClientScript to stop diagnostics.")
end
