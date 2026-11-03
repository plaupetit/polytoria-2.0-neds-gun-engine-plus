local function WaitChild(parent, childName, duration)
    local warned = false
    local found = parent:FindChild(childName)
    local startedAt = os.clock()
    if found then
        return found
    end
    repeat
        local timer = os.clock() - startedAt
        wait()
        found = parent:FindChild(childName)
        if duration ~= nil and timer >= duration then
            break
        elseif duration == nil and not warned and timer > 5 then
            print(("Infinite yield on WaitChild(%s, %s)"):format(parent.Name, childName))
            warned = true
        end
    until found
    return found
end

local workspace = game["Environment"]
local effects = WaitChild(workspace, "VFXs")
-- Template emitters may exist as script children for authoring, but must not
-- emit at runtime. The weapon only creates its visual parts inside start().
for _, template in ipairs({ script:FindChild("BulletHole"), script:FindChild("Particles") }) do
    if template ~= nil and template:IsA("Particles") then
        template:Stop()
        template:Clear()
    end
end

local bulletDur = 0.1
local bulletThickness = 0.12
local impactPoolSize = 5
local impactLifetime = 2
local impactStartSize = 0.75
local impactThickness = 0.04
local impactDispersion = 1
local impactGravity = 1
local impactSpinDegreesPerSecond = 360

-- Each final offset has magnitude one. The pool interpolates from zero spread to this endpoint over its lifetime.
local impactDispersionOffsets = {
    Vector3.New(-1, 0, 0),
    Vector3.New(1, 0, 0),
    Vector3.New(0, 0, -1),
    Vector3.New(0, 0, 1),
    Vector3.New(0.70710678, 0, 0.70710678),
}

local renderWaits = {}
local impactPool = {}
local nextImpactIndex = 1

function renderWait()
    local newIndex = #renderWaits + 1
    renderWaits[newIndex] = true
    repeat wait() until not renderWaits[newIndex]
end

local function hideImpactFragment(part)
    part.Position = Vector3.New(0, -10000, 0)
    part.Size = Vector3.New(0.01, 0.01, 0.01)
    part.Color = Color.New(1, 1, 1, 0)
end

local function createImpactFragment(index)
    local part = Instance.New("Part")
    part.Name = "GunImpactFragment_" .. tostring(index)
    part.Parent = effects
    part.Anchored = true
    part.CanCollide = false
    if PartShape ~= nil and PartShape.Brick ~= nil then
        part.Shape = PartShape.Brick
    end
    hideImpactFragment(part)
    return {
        part = part,
        generation = 0,
        active = false,
    }
end

local function ensureImpactPool()
    while #impactPool < impactPoolSize do
        table.insert(impactPool, createImpactFragment(#impactPool + 1))
    end
end

local function acquireImpactFragment()
    ensureImpactPool()
    local item = impactPool[nextImpactIndex]
    nextImpactIndex = (nextImpactIndex % impactPoolSize) + 1
    item.generation = item.generation + 1
    return item
end

local function getImpactColor(surface)
    local colour = Color.New(0.85, 0.85, 0.85, 1)
    pcall(function()
        if surface and surface.Color then
            colour = surface.Color
        end
    end)
    return colour
end

-- Impact fragments are client-local cosmetics, so the active local camera is the correct viewer to face.
local function orientImpactFragment(part, position, spinAngle)
    part.Position = position
    local camera = workspace.CurrentCamera
    if camera == nil or camera.Position == nil then
        return
    end

    local viewerOffset = camera.Position - position
    if viewerOffset.Magnitude <= 0.0001 then
        return
    end

    part:LookAt(camera.Position)
    -- Keep the requested one-turn-per-second spin around the local viewer axis.
    part:RotateAround(position, viewerOffset.Normalized, spinAngle)
end

local function emitImpactFragments(position, normal, surface)
    local colour = getImpactColor(surface)
    for index = 1, impactPoolSize do
        local item = acquireImpactFragment()
        local part = item.part
        item.active = true
        item.startedAt = os.clock()
        -- The normal only avoids embedding in the struck surface. The anchored, non-colliding pool has no bounce path.
        item.startPosition = position + normal * 0.03
        item.finalSpread = impactDispersionOffsets[index] * impactDispersion
        item.velocity = Vector3.New(0, 0.25 + (index % 2) * 0.04, 0)
        item.startRotation = (index - 1) * (360 / impactPoolSize)
        pcall(function()
            orientImpactFragment(part, item.startPosition, item.startRotation)
            part.Size = Vector3.New(impactStartSize, impactStartSize, impactThickness)
            part.Color = colour
        end)
    end
end

local function updateImpactPool()
    local now = os.clock()
    for _, item in ipairs(impactPool) do
        if item.active then
            local age = now - item.startedAt
            local progress = age / impactLifetime
            if progress >= 1 then
                item.active = false
                hideImpactFragment(item.part)
            else
                local size = math.max(0.01, impactStartSize * (1 - progress))
                local fallDistance = 0.5 * impactGravity * age * age
                -- Visual dispersion begins at zero and reaches exactly the configured one-unit endpoint at expiry.
                local progressiveSpread = item.finalSpread * progress
                local position = item.startPosition + progressiveSpread + item.velocity * age - Vector3.New(0, fallDistance, 0)
                pcall(function()
                    orientImpactFragment(item.part, position, item.startRotation + impactSpinDegreesPerSecond * age)
                    item.part.Size = Vector3.New(size, size, math.max(0.01, impactThickness * (1 - progress)))
                end)
            end
        end
    end
end

-- Hooks.Updated is the Creator 2.0 frame signal for the cosmetic-only pool.
Hooks.Updated:Connect(function()
    for index = #renderWaits, 1, -1 do
        table.remove(renderWaits, index)
    end
    updateImpactPool()
end)

function start(a, b, normal, hitInstance)
    if normal and hitInstance then
        emitImpactFragments(b, normal, hitInstance)
    end

    local tracer = Instance.New("Part")
    tracer.Parent = effects
    -- A static brick keeps the beam rectangular and immune to world physics during its 0.1 second tween.
    tracer.Anchored = true
    tracer.CanCollide = false
    if PartShape ~= nil and PartShape.Brick ~= nil then
        tracer.Shape = PartShape.Brick
    end
    tracer.Position = Vector3.Lerp(a, b, 0.5)
    tracer.Size = Vector3.New(bulletThickness, bulletThickness, Vector3.Distance(a, b))
    tracer.Color = Color.FromHex("#FFFF00FF")
    tracer.Material = PartMaterial.Neon
    tracer.LookAt(b)
    renderWait()
    Tween:TweenSize(tracer, Vector3.New(bulletThickness, bulletThickness, 0), bulletDur, TweenType.linear, function() end) -- explicit no-op: the legacy `pass` helper no longer exists
    Tween:TweenPosition(tracer, b, bulletDur, TweenType.linear, function()
        -- The tracer is not in any ignore list anymore (ToolHandler no longer keeps one); just destroy it.
        tracer:Destroy()
    end)
end