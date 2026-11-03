-- TURRET CONTROLLER
-- Expected type: ServerScript, linked as a DIRECT CHILD of the turret Model (World/Environment/TestTurret).
-- Role: a stationary test turret that shoots Players standing inside its red range disc, so damage and the
--   spawn shield ("Protect") can be tested without a second human player.
-- Side: server only. Dependencies: none from the gun framework (self-contained on purpose, it only needs the
--   Hidden/Remotes/CreateBullet remote to make clients draw the normal tracer).
-- Expected children of the turret Model (the script waits for them):
--   Head              Part, turned with LookAt (forward = +Z, the barrel points along +Z)
--   Head/ShootPos     Part, the muzzle: the ray starts here and the tracer is drawn from here
--   RangeDisc         flat Cylinder Part on the ground; radius = Size.X / 2, READ AT RUNTIME so resizing the disc
--                     in Creator changes the turret range with no script edit
-- Targeting: only Players, alive, horizontal distance from the disc centre <= disc radius, clear line of sight
--   from ShootPos to the upper torso. Players with a "Protect" child are skipped; each protection is logged once
--   per player so the owner can see the shield working. NPCs are never targeted.
-- Aiming (rewritten 2026-11-03 after the owner's Play report "wakes up late, follows strangely"):
--   * The script owns the aim state as two angles (yaw around Y, pitch up/down) and NEVER reads the head's
--     orientation back (the Forward sign is an open question in the API audits). Each tick both angles move
--     toward the target angles by at most TURN_RATE_DEG * dt, so the motion is steady (no snapping, no
--     overshoot), then the head is turned with LookAt(headPosition + direction). One LookAt call therefore
--     yaws and pitches consistently; the pivot is the Head position for aiming and for the fire gate.
--   * The turret fires only when the current aim is within FIRE_CONE_DEG of the target direction.
--   * The current target is kept while it stays valid (no flip-flop between two players).
--   * Barrel calibration (2026-11-03, "tracer and barrel look like a miss"): after every LookAt the REAL barrel axis
--     is measured as (ShootPos - Head) normalised. If it points against the commanded direction (dot < 0) the
--     LookAt sign is flipped (lookSign) and the head re-turned. The fire gate compares the measured axis with the
--     muzzle-to-target line, and the shot ray starts at the muzzle ALONG the measured axis (plus spread), so the
--     tracer leaves the barrel and ends on the real hit point or the max-range end. Assumes ShootPos moves with
--     the Head when the Head is turned (child of Head); if it does not, no axis change is seen and the fallback is
--     the commanded direction (DEBUG_TURRET prints the measured axis to reveal this).
-- Broadcast contract (the exact keys Client.client.luau's CreateBullet reply handler reads):
--   "s" = this Model (not a Player: the client only compares it with LocalPlayer and looks for a held Tool,
--         both safe for a Model), "o" = ShootPos, "m" = 1, "1" = endpoint, "n1" = surface normal,
--         "h1" = struck Instance (only when something was hit), "hitConfirmed" = false (the hitmarker is for
--         the shooter of a real gun, never for the turret).
-- How to test: stand inside the red disc in line of sight: the head turns toward you within ~0.2 s at a
--   steady rate, then tracers fly every 0.5 s and health drops by 10 per hit. Stand outside the disc, behind
--   a wall, or right after spawning (shield): no damage. Set DEBUG_TURRET = true for acquire/lose/fire prints.

-- CONFIGURATION VARIABLES
local DEBUG_TURRET = false -- true: print acquire / lose / fire / LOS-blocked lines for diagnosis
local FIRE_INTERVAL = 0.5 -- seconds between shots (2 shots/s)
local DAMAGE = 10 -- health removed per hit
local SPREAD_DEGREES = 1.5 -- random yaw/pitch error added to every shot (like WeaponServer)
local MAX_RANGE = 120 -- studs the bullet ray travels
local TICK_INTERVAL = 0.05 -- seconds between target scans AND aim steps (acquisition latency <= one tick)
local TURN_RATE_DEG = 360 -- maximum yaw and pitch speed, degrees per second
local FIRE_CONE_DEG = 6 -- the turret fires only when its aim is within this angle of the target
local AIM_HEIGHT = 2.4 -- studs above Player.Position (near the feet) = upper torso; tune if shots go low/high

-- INTERNAL CONSTANTS
local AIM_OFFSET = Vector3.New(0, AIM_HEIGHT, 0)
local MAX_IGNORED_RAYCASTS = 32
local model = script.Parent

-- Bootstrap polling loop: the children are created by the Creator build step and may replicate late.
local function waitChild(parent, childName)
    local found = parent:FindChild(childName)
    local warned = false
    local startedAt = os.clock()
    while found == nil do
        wait()
        found = parent:FindChild(childName)
        if found == nil and not warned and os.clock() - startedAt > 5 then
            print(("[Turret] Waiting for %s/%s"):format(parent.Name, childName))
            warned = true
        end
    end
    return found
end

local head = waitChild(model, "Head")
local shootPos = waitChild(head, "ShootPos")
local rangeDisc = waitChild(model, "RangeDisc")
local createBullet = waitChild(waitChild(game["Hidden"], "Remotes"), "CreateBullet")
local players = game["Players"]
local environment = game["Environment"]

-- Per-player log memory: the Protect Instance already announced for that player (weak keys: players leave).
local announcedProtection = setmetatable({}, { __mode = "k" })

-- Everything that belongs to the turret is excluded from its own rays (the disc may be hit by a ray otherwise).
local ownInstances = { model, head, shootPos, rangeDisc }
for _, descendant in ipairs(model:GetDescendants()) do
    table.insert(ownInstances, descendant)
end

local function debugPrint(text)
    if DEBUG_TURRET then
        print("[Turret] " .. text)
    end
end

local function randomFloat(lower, upper)
    return lower + math.random() * (upper - lower)
end

local function clamp(value, lower, upper)
    return math.max(lower, math.min(upper, value))
end

-- Aim angles: yaw = rotation around +Y measured from +Z toward +X, pitch = elevation (positive = up).
-- anglesToDirection and directionToAngles are exact inverses, which keeps yaw and pitch consistent.
local function anglesToDirection(yaw, pitch)
    return Vector3.New(math.cos(pitch) * math.sin(yaw), math.sin(pitch), math.cos(pitch) * math.cos(yaw))
end

local function directionToAngles(direction)
    return math.atan2(direction.X, direction.Z), math.asin(clamp(direction.Y, -1, 1))
end

local function wrapAngle(angle)
    while angle > math.pi do
        angle = angle - 2 * math.pi
    end
    while angle < -math.pi do
        angle = angle + 2 * math.pi
    end
    return angle
end

-- Same spread model as WeaponServer: random pitch and yaw offsets inside +-SPREAD_DEGREES.
local function applySpread(direction)
    local spreadRadians = math.rad(SPREAD_DEGREES)
    if spreadRadians <= 0 then
        return direction
    end
    local yaw, pitch = directionToAngles(direction)
    return anglesToDirection(
        yaw + randomFloat(-spreadRadians, spreadRadians),
        pitch + randomFloat(-spreadRadians, spreadRadians)
    )
end

-- Raycast that re-casts through any struck Instance owning a child named "!Ignore" (bounded loop, copy of the
-- GunUtil contract). `ignore` is mutated, so callers pass a fresh list.
local function raycastSkippingIgnored(origin, direction, maxRange, ignore)
    for _ = 1, MAX_IGNORED_RAYCASTS do
        local hit = environment:Raycast(origin, direction, maxRange, ignore)
        local instance = hit and hit.Instance
        if instance == nil or instance:FindChild("!Ignore") == nil then
            return hit
        end
        table.insert(ignore, instance)
    end
    return nil
end

local function copyIgnoreList()
    local copy = {}
    for index, instance in ipairs(ownInstances) do
        copy[index] = instance
    end
    return copy
end

-- Walks up from a struck Instance to the Player or NPC that owns it; nil for world geometry.
local function resolveDamageable(hit)
    local candidate = hit
    while candidate do
        if candidate:IsA("NPC") or candidate:IsA("Player") then
            return candidate
        end
        candidate = candidate.Parent
    end
    return nil
end

-- True when `instance` is `ancestor` or lies below it.
local function isInside(instance, ancestor)
    local candidate = instance
    while candidate do
        if candidate == ancestor then
            return true
        end
        candidate = candidate.Parent
    end
    return false
end

-- True when only a Player/NPC (or nothing) lies between the muzzle and the aim point. The aim point is INSIDE
-- the target's body, so the ray normally strikes the target itself first: that must count as clear even when
-- the body part is not a descendant of the Player object (the Character may be a separate Instance).
local function hasLineOfSight(fromPosition, aimPosition, player)
    local offset = aimPosition - fromPosition
    local distance = offset.Magnitude
    if distance <= 0.05 then
        return true
    end
    local hit = raycastSkippingIgnored(fromPosition, offset.Normalized, distance, copyIgnoreList())
    local instance = hit and hit.Instance
    if instance == nil then
        return true
    end
    if isInside(instance, player) then
        return true
    end
    local okCharacter, character = pcall(function()
        return player.Character
    end)
    if okCharacter and character ~= nil and isInside(instance, character) then
        return true
    end
    if resolveDamageable(instance) ~= nil then
        return true
    end
    debugPrint(("line of sight to %s blocked by %s"):format(player.Name, instance.Name))
    return false
end

-- Logs a protection once per player and per Protect Instance (a new spawn creates a new shield, a new log).
local function noteProtection(player, shield)
    if announcedProtection[player] ~= shield then
        announcedProtection[player] = shield
        print(("[Turret] %s is spawn-protected: holding fire."):format(player.Name))
    end
end

-- Returns the aim point (upper torso) when `player` is an eligible target right now, else nil.
local function evaluatePlayer(player, muzzle, discPosition, radius)
    local aimPoint = nil
    -- A player who disconnects mid-scan must not stop the turret.
    local ok, errorMessage = pcall(function()
        if player.Health <= 0 then
            return
        end
        local position = player.Position
        local dx = position.X - discPosition.X
        local dz = position.Z - discPosition.Z
        if math.sqrt(dx * dx + dz * dz) > radius then
            return
        end
        local shield = player:FindChild("Protect")
        if shield ~= nil then
            noteProtection(player, shield)
            return
        end
        local candidate = position + AIM_OFFSET
        if hasLineOfSight(muzzle, candidate, player) then
            aimPoint = candidate
        end
    end)
    if not ok then
        debugPrint("evaluate failed: " .. tostring(errorMessage))
    end
    return aimPoint
end

local currentTarget = nil

-- Keeps the current target while it stays valid; otherwise picks the nearest eligible Player.
-- Returns the Player and the aim point, or nil.
local function findTarget()
    local discPosition = rangeDisc.Position
    -- Radius comes from the disc itself so the owner can resize the range in Creator.
    local radius = rangeDisc.Size.X * 0.5
    local muzzle = shootPos.Position

    if currentTarget ~= nil then
        local keptPoint = evaluatePlayer(currentTarget, muzzle, discPosition, radius)
        if keptPoint ~= nil then
            return currentTarget, keptPoint
        end
        -- A disconnected target may be destroyed: read its name defensively so the tick never sticks on it.
        local lostName = "?"
        pcall(function()
            lostName = tostring(currentTarget.Name)
        end)
        debugPrint(("lost target %s"):format(lostName))
        currentTarget = nil
    end

    local bestPlayer = nil
    local bestPoint = nil
    local bestDistance = math.huge
    for _, player in ipairs(players:GetPlayers()) do
        local point = evaluatePlayer(player, muzzle, discPosition, radius)
        if point ~= nil then
            local distance = (point - muzzle).Magnitude
            if distance < bestDistance then
                bestPlayer = player
                bestPoint = point
                bestDistance = distance
            end
        end
    end
    if bestPlayer ~= nil then
        currentTarget = bestPlayer
        debugPrint(("acquired %s at %.1f studs"):format(bestPlayer.Name, bestDistance))
    end
    return bestPlayer, bestPoint
end

-- One shot: server-side ray with spread, damage if a (non-shielded) Player is struck, then a client broadcast.
-- The ray leaves the MEASURED muzzle along the MEASURED barrel axis (`barrelAxis`, unit vector), so the damage ray
-- and the tracer both match what the owner sees of the barrel; the tracer ends on the real hit (or max range).
local function fireAt(barrelAxis)
    local muzzle = shootPos.Position
    local direction = applySpread(barrelAxis)
    local hit = raycastSkippingIgnored(muzzle, direction, MAX_RANGE, copyIgnoreList())
    local endpoint = hit and hit.Position or muzzle + direction * MAX_RANGE
    local normal = hit and hit.Normal or Vector3.New(0, 1, 0)
    local instance = hit and hit.Instance or nil

    if instance ~= nil then
        local victim = resolveDamageable(instance)
        -- The turret hurts Players only; NPCs in the line of fire and shielded players are left alone.
        if victim ~= nil and victim:IsA("Player") and not victim:FindChild("Protect") and victim.Health > 0 then
            victim.Health = victim.Health - DAMAGE
        end
    end
    debugPrint(("fire, hit %s"):format(instance and instance.Name or "nothing"))

    local message = NetMessage.New()
    message:AddInstance("s", model)
    message:AddInstance("o", shootPos)
    message:AddInt("m", 1)
    message:AddVector3("1", endpoint)
    message:AddVector3("n1", normal)
    if instance ~= nil then
        message:AddInstance("h1", instance)
    end
    message:AddBool("hitConfirmed", false)
    createBullet:InvokeClients(message)
end

-- Aim state, script-owned. Start from the head's own forward (+Z fallback); the first sweep is rate-capped.
local aimYaw = 0
local aimPitch = 0
do
    local okForward, forward = pcall(function()
        return head.Forward
    end)
    if okForward and forward ~= nil then
        aimYaw, aimPitch = directionToAngles(forward)
    end
end

-- Manual dot product: Vector3.Dot is documented with (lhs, rhs) and its static/instance form is unverified.
local function dot3(a, b)
    return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end

-- LookAt sign calibration: +1 = the barrel (Head -> ShootPos) follows LookAt's forward, -1 = it is reversed.
-- Learned at runtime from the measured barrel axis, never assumed (the model's real axis is not documented).
local lookSign = 1
-- Calibrate the sign once per run: a stale Position right after LookAt must not make the head flap 180 degrees.
local lookSignLocked = false
local MIN_AXIS_LENGTH = 0.05 -- studs; a shorter Head -> ShootPos offset cannot give a reliable axis

-- Measures the barrel's real world axis after a LookAt: (ShootPos - Head) normalised.
-- Returns nil when the muzzle sits (almost) on the head pivot, so no axis can be measured.
local function measureBarrelAxis()
    local offset = shootPos.Position - head.Position
    if offset.Magnitude < MIN_AXIS_LENGTH then
        return nil
    end
    return offset.Normalized
end

-- Moves yaw and pitch toward the direction of `aimPoint` seen from the Head by at most the turn budget, turns the
-- head, then MEASURES the barrel axis and corrects a reversed LookAt (dot < 0 against the commanded direction).
-- Returns (errorDegrees, barrelAxis): the angle between the measured barrel axis and the muzzle-to-target line,
-- measured after the step, and the unit axis the shot must use. errorDegrees is 180 when nothing can be fired.
local function stepAim(aimPoint, dt)
    local headPosition = head.Position
    local toTarget = aimPoint - headPosition
    if toTarget.Magnitude <= 0.001 then
        return 180, nil
    end
    local targetYaw, targetPitch = directionToAngles(toTarget.Normalized)
    local budget = math.rad(TURN_RATE_DEG) * dt
    aimYaw = aimYaw + clamp(wrapAngle(targetYaw - aimYaw), -budget, budget)
    aimPitch = aimPitch + clamp(targetPitch - aimPitch, -budget, budget)
    local commanded = anglesToDirection(aimYaw, aimPitch)
    head:LookAt(headPosition + commanded * lookSign)

    local axis = measureBarrelAxis()
    if not lookSignLocked and axis ~= nil and dot3(axis, commanded) < 0 then
        -- The barrel points away from where LookAt was told to look: the axis is reversed. Flip once, remeasure.
        lookSign = -lookSign
        lookSignLocked = true
        debugPrint(("barrel axis reversed vs LookAt, lookSign now %d"):format(lookSign))
        head:LookAt(headPosition + commanded * lookSign)
        axis = measureBarrelAxis()
    end
    if axis == nil then
        -- No measurable barrel (muzzle on the pivot): fall back to the commanded direction.
        axis = commanded
    end

    -- Fire gate: the real barrel axis against the line from the real muzzle to the target (handles a muzzle that
    -- is offset sideways from the pivot).
    local toTargetFromMuzzle = aimPoint - shootPos.Position
    if toTargetFromMuzzle.Magnitude <= 0.001 then
        return 180, nil
    end
    local errorDegrees = math.deg(math.acos(clamp(dot3(axis, toTargetFromMuzzle.Normalized), -1, 1)))
    debugPrint(("aim error %.1f deg (axis %.2f %.2f %.2f, lookSign %d)"):format(
        errorDegrees, axis.X, axis.Y, axis.Z, lookSign))
    return errorDegrees, axis
end

local lastShotAt = -math.huge
local lastTickAt = os.clock()

while true do
    wait(TICK_INTERVAL)
    local now = os.clock()
    -- Real elapsed time, capped so a long hitch cannot make the head teleport in one step.
    local dt = math.min(now - lastTickAt, 0.25)
    lastTickAt = now
    -- One failed scan (for example a Part destroyed during editing) must not kill the turret loop.
    local ok, errorMessage = pcall(function()
        local target, aimPoint = findTarget()
        if target == nil then
            return
        end
        local errorDegrees, barrelAxis = stepAim(aimPoint, dt)
        if barrelAxis ~= nil and errorDegrees <= FIRE_CONE_DEG and now - lastShotAt >= FIRE_INTERVAL then
            lastShotAt = now
            fireAt(barrelAxis)
        end
    end)
    if not ok then
        print("[Turret] scan failed: " .. tostring(errorMessage))
    end
end
