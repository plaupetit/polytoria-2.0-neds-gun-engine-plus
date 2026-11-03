-- WeaponThrowable: client-only input half of the Grenade (Config kind = "throwable").
-- Role: HOLD the right mouse button to charge, RELEASE to throw. While held it draws a local-only ballistic arc
--   preview (a pool of small dots plus a landing marker); on release it sends ThrowGrenade {origin, dir, charge,
--   rid} and optimistically decrements the HUD count. The server owns the real count, cooldown, velocity,
--   projectile and damage and reconciles the count in its reply (handled by Client). Each request also carries a
--   counter `rid` (tool.Shared.throwRid); the server echoes it as `ack`, see Client's reply handler.
-- Side: client only.
-- Input contract:
--   right mouse down   (Input.KeyDown, key text "Mouse1" or containing "MouseRight") starts the charge when the
--                      Grenade is the held Tool, ammo > 0 and the cooldown is over; nothing is sent yet,
--   right mouse up     (Input.KeyUp) ends the charge and throws. charge = hold seconds / Config.chargeTime clamped to
--                      0..1; a hold shorter than TAP_SECONDS (0.1 s) counts as charge 0 (minimum power),
--   left mouse (Mouse0, the BoolValue passed in) does nothing: it is only traced,
--   unequip, death, window focus loss or a hold longer than MAX_HOLD_SECONDS cancel the charge WITHOUT a throw.
--   ToolHandler is not involved: it only flips BoolValues that exist as children of the held Tool, so the right
--   mouse button never reaches the other Tools through it. This module listens to Input itself and acts only when
--   its own Tool is the held one, so a gun's right-click aim (WeaponAim cursor freeze) is untouched.
-- Dependencies (passed to Bind as `dependencies`; nothing is required from siblings):
--   remotes        the Hidden/Remotes folder; ThrowGrenade is looked up at release time so a missing remote
--                  cannot block start-up,
--   addAmmo(tool, amount)  HUD-aware ammo arithmetic,
--   findChildAndDoFunc, playSound   optional "Throw" Sound on the Handle,
--   getForward()   optional camera forward (default: Environment.CurrentCamera.Forward, then the avatar forward),
--   input, workspace   optional overrides of the Input service and the Environment (defaults: globals).
-- Throw maths (shared with WeaponGrenadeServer, keep both in sync): yaw = camera yaw (horizontal part of the camera
--   forward), pitch = fixed Config.throwPitchDeg (default 40, clamped 5..80), speed = minThrowSpeed + (throwSpeed -
--   minThrowSpeed) * charge, position(t) = start + v t + (0, -g t^2 / 2, 0) with g = -Environment.Gravity.Y
--   (fallback 85). The server ignores the pitch of the `dir` it receives and recomputes the velocity itself.
-- Preview: dots are repositioned each frame, never recreated; they sit in a Folder named "GrenadePreview" under
--   Environment/VFXs, created by this client only (never replicated, invisible to others). The arc is cut at the first
--   world hit (segment raycasts that ignore the local player, the held Tool and the preview itself) and the red
--   marker sits there. It is hidden on release, unequip, death and cancel.
-- State: tool.Shared.lastThrown and tool.Shared.throwRid (per Tool) plus tables created inside Bind; no
--   module-global mutable state. Bind connects Input.KeyDown/KeyUp once per Tool; a connection whose Tool was
--   destroyed disconnects itself on the next key event (and is inert before that, since it checks its Tool).
-- Invariants: the client never sends a count, speed, damage or hit; the server rejects/clamps everything.
-- Diagnostics: DEBUG_WEAPON_KINDS (TEMPORARY, lot L4/L8) prints a "[Ned Gun:throwable]" line at every early return,
--   pcall failure, key seen, charge start/cancel and request (with the client origin and the local player
--   position). Set it to false once the Grenade is confirmed working in Play.
-- How to test: equip the Grenade, hold right mouse: an arc + red marker appear and grow with the hold time (full
--   after 1.2 s); release: the grenade follows the arc and the count drops; a quick tap throws a short toss;
--   left click does nothing; unequip while holding: preview disappears, nothing is thrown.
local WeaponThrowable = {}

-- TEMPORARY diagnostics switch (see header). Remove with the trace calls when the kind modules are stable.
local DEBUG_WEAPON_KINDS = true

local DEFAULT_COOLDOWN = 1
local DEFAULT_CHARGE_TIME = 1.2
local DEFAULT_MIN_THROW_SPEED = 20
local DEFAULT_THROW_PITCH_DEG = 40
local MIN_PITCH_DEG = 5
local MAX_PITCH_DEG = 80
local TAP_SECONDS = 0.1 -- a hold shorter than this throws at charge 0
local MAX_HOLD_SECONDS = 20 -- safety net if a key-up is ever lost
local MIN_FLAT_LENGTH = 0.0001

-- Mirrored in WeaponGrenadeServer: keep equal.
local DEFAULT_GRAVITY = 85
local SPAWN_FORWARD = 1.0
local SPAWN_WALL_MARGIN = 0.6
-- Same muzzle fallback as WeaponFire.ComputeAim: the player's position lifted to chest height.
local CHEST_LIFT = Vector3.New(0, 1.5, 0)

-- Preview: PREVIEW_STEPS dots spaced PREVIEW_DT seconds apart (2.4 s of flight is far more than any throw needs).
local PREVIEW_STEPS = 30
local PREVIEW_DT = 0.08
local PREVIEW_FOLDER_NAME = "GrenadePreview"
local DOT_SIZE = 0.22
local DOT_COLOR = Color.New(1, 0.85, 0.2, 1)
local MARKER_SIZE = Vector3.New(1.2, 0.08, 1.2)
local HIDDEN_POSITION = Vector3.New(0, -10000, 0)

local function trace(tool, message)
    if DEBUG_WEAPON_KINDS then
        local name = "?"
        pcall(function()
            name = tool.Name
        end)
        print(("[Ned Gun:throwable] %s: %s"):format(name, message))
    end
end

local function formatVector(value)
    if value == nil then
        return "unreadable"
    end
    local ok, text = pcall(function()
        return ("(%.1f, %.1f, %.1f)"):format(value.X, value.Y, value.Z)
    end)
    if ok then
        return text
    end
    return "unreadable"
end

-- Pure helper: horizontal unit vector of `forward`, or nil when it is (almost) vertical or missing.
function WeaponThrowable.FlattenDirection(forward)
    if forward == nil then
        return nil
    end
    local flat = Vector3.New(forward.X, 0, forward.Z)
    if not (flat.Magnitude > MIN_FLAT_LENGTH) then
        return nil
    end
    return flat.Normalized
end

-- Pure helper: the throw numbers from a Tool.Shared-like table, with the same defaults and clamps as the server.
-- Returns { throwSpeed, minSpeed, pitchDeg, chargeTime, cooldown }.
function WeaponThrowable.ReadThrowNumbers(shared)
    local throwSpeed = shared.throwSpeed
    if type(throwSpeed) ~= "number" or not (throwSpeed > 0) then
        throwSpeed = 55
    end
    local minSpeed = shared.minThrowSpeed
    if type(minSpeed) ~= "number" then
        minSpeed = DEFAULT_MIN_THROW_SPEED
    end
    local pitch = shared.throwPitchDeg
    if type(pitch) ~= "number" then
        pitch = DEFAULT_THROW_PITCH_DEG
    end
    local chargeTime = shared.chargeTime
    if type(chargeTime) ~= "number" or not (chargeTime > 0.05) then
        chargeTime = DEFAULT_CHARGE_TIME
    end
    local cooldown = shared.cooldown
    if type(cooldown) ~= "number" then
        cooldown = DEFAULT_COOLDOWN
    end
    return {
        throwSpeed = throwSpeed,
        minSpeed = math.min(math.max(minSpeed, 0), throwSpeed),
        pitchDeg = math.min(math.max(pitch, MIN_PITCH_DEG), MAX_PITCH_DEG),
        chargeTime = chargeTime,
        cooldown = cooldown,
    }
end

-- Pure helper (MUST match WeaponGrenadeServer computeLaunch): launch velocity and speed for a charge in [0, 1].
function WeaponThrowable.ComputeLaunch(numbers, flatDir, charge)
    local speed = numbers.minSpeed + (numbers.throwSpeed - numbers.minSpeed) * charge
    local pitch = math.rad(numbers.pitchDeg)
    local horizontal = math.cos(pitch) * speed
    return Vector3.New(flatDir.X * horizontal, math.sin(pitch) * speed, flatDir.Z * horizontal), speed
end

-- Pure helper: ballistic position after `t` seconds from `start` with `velocity` under gravity magnitude `g`.
function WeaponThrowable.PositionAt(start, velocity, g, t)
    return Vector3.New(
        start.X + velocity.X * t,
        start.Y + velocity.Y * t - 0.5 * g * t * t,
        start.Z + velocity.Z * t
    )
end

-- True for the key names the engine may use for the right mouse button (the exact text is traced once in Play).
local function isRightMouseKey(key)
    local text = string.lower(tostring(key))
    return text == "mouse1" or string.find(text, "mouseright", 1, true) ~= nil
end

function WeaponThrowable.Bind(tool, handle, shootPos, mouse0, dependencies)
    local shared = tool.Shared
    -- Far in the past so the very first throw is never blocked by the cooldown.
    shared.lastThrown = -1000
    local warnedMissingRemote = false
    trace(tool, ("bound (shootPos %s, ammo %s)"):format(shootPos and "found" or "MISSING, the origin falls back to the chest", tostring(shared.ammo)))

    local input = dependencies.input
    if input == nil then
        input = Input
    end
    local environment = dependencies.workspace
    if environment == nil then
        environment = game["Environment"]
    end
    if input == nil then
        print(("[Ned Gun:throwable] %s: Input service not available, the right mouse charge cannot work."):format(tostring(tool.Name)))
        return
    end

    -- Charge state. `token` invalidates a running frame loop (cancel, release, a newer charge).
    local charge = { active = false, startedAt = 0, token = 0 }
    local preview = nil -- created lazily on the first charge: { folder, dots, marker }
    local seenMouseKeys = {}

    local function getLocalPlayer()
        local player = nil
        pcall(function()
            player = game["Players"].LocalPlayer
        end)
        return player
    end

    -- Destroyed Tools stay reachable in Creator 2.0 but lose their parent and Shared table (see WeaponRuntime.isGone).
    local function toolIsGone()
        local ok, parent = pcall(function()
            return tool:GetParent()
        end)
        if not ok or parent == nil then
            return true
        end
        local sharedOk, currentShared = pcall(function()
            return tool.Shared
        end)
        return not sharedOk or currentShared == nil
    end

    local function isHeld()
        local player = getLocalPlayer()
        if player == nil then
            return false
        end
        local ok, held = pcall(function()
            return player:FindChildByClass("Tool")
        end)
        if not ok or held == nil then
            return false
        end
        if held == tool then
            return true
        end
        -- Engine wrappers may not keep userdata identity: fall back to the Tool name.
        local same = false
        pcall(function()
            same = held.Name == tool.Name
        end)
        return same
    end

    local function isAlive()
        local player = getLocalPlayer()
        if player == nil then
            return false
        end
        local ok, health = pcall(function()
            return player.Health
        end)
        return not ok or type(health) ~= "number" or health > 0
    end

    -- ---- preview -------------------------------------------------------------------------------------------

    local function getPartShape(name)
        local shape = nil
        pcall(function()
            local partShape = PartShape
            if partShape == nil then
                partShape = game["Enums"].PartShape
            end
            shape = partShape[name]
        end)
        return shape
    end

    local function hidePart(part)
        pcall(function()
            part.Position = HIDDEN_POSITION
        end)
    end

    -- A client-created, anchored, non-colliding, non-shadow Part (the BulletTracer precedent): local to this client.
    local function createPart(parent, name, size, color, shape)
        local part = Instance.New("Part")
        part.Name = name
        part.Parent = parent
        part.Anchored = true
        part.CanCollide = false
        pcall(function()
            part.CastShadows = false
        end)
        if shape ~= nil then
            pcall(function()
                part.Shape = shape
            end)
        end
        part.Size = size
        part.Color = color
        pcall(function()
            part.Material = PartMaterial.Neon
        end)
        hidePart(part)
        return part
    end

    local function ensurePreview()
        if preview ~= nil then
            return preview
        end
        local parent = environment
        pcall(function()
            local effects = environment:FindChild("VFXs")
            if effects ~= nil then
                parent = effects
            end
        end)
        local created = { folder = nil, dots = {}, marker = nil }
        created.folder = Instance.New("Folder")
        created.folder.Name = PREVIEW_FOLDER_NAME
        created.folder.Parent = parent
        local sphere = getPartShape("Sphere")
        local dotSize = Vector3.New(DOT_SIZE, DOT_SIZE, DOT_SIZE)
        for index = 1, PREVIEW_STEPS do
            created.dots[index] = createPart(created.folder, PREVIEW_FOLDER_NAME .. "Dot", dotSize, DOT_COLOR, sphere)
        end
        created.marker = createPart(created.folder, PREVIEW_FOLDER_NAME .. "Marker", MARKER_SIZE, Color.New(1, 1, 1, 1), getPartShape("Brick"))
        preview = created
        local parentName = "?"
        pcall(function()
            parentName = tostring(parent.Name)
        end)
        trace(tool, ("preview created (%d dots + marker) under %s"):format(PREVIEW_STEPS, parentName))
        return preview
    end

    local function hidePreview()
        if preview == nil then
            return
        end
        for _, dot in ipairs(preview.dots) do
            hidePart(dot)
        end
        hidePart(preview.marker)
    end

    -- Raycast that re-casts through "!Ignore" objects and through the preview's own parts. `ignore` is mutated.
    local function castSegment(fromPosition, toPosition, ignore)
        local offset = toPosition - fromPosition
        local distance = offset.Magnitude
        if not (distance > 0.01) then
            return nil
        end
        local direction = offset.Normalized
        for _ = 1, 16 do
            local hit = environment:Raycast(fromPosition, direction, distance, ignore)
            local instance = hit and hit.Instance
            if instance == nil then
                return nil
            end
            local skip = false
            pcall(function()
                skip = instance:FindChild("!Ignore") ~= nil or string.sub(instance.Name, 1, #PREVIEW_FOLDER_NAME) == PREVIEW_FOLDER_NAME
            end)
            if not skip then
                return hit
            end
            table.insert(ignore, instance)
        end
        return nil
    end

    local function buildIgnoreList()
        local ignore = {tool}
        local player = getLocalPlayer()
        if player ~= nil then
            table.insert(ignore, player)
            pcall(function()
                if player.Character ~= nil then
                    table.insert(ignore, player.Character)
                end
            end)
        end
        if preview ~= nil then
            table.insert(ignore, preview.folder)
        end
        return ignore
    end

    local function readGravity()
        local ok, value = pcall(function()
            return -environment.Gravity.Y
        end)
        if ok and type(value) == "number" and value > 1 and value < 10000 then
            return value
        end
        return DEFAULT_GRAVITY
    end

    -- ---- aim inputs ----------------------------------------------------------------------------------------

    -- Camera yaw as a horizontal unit vector; falls back to the avatar forward when the camera looks straight
    -- up/down or is unavailable.
    local function getFlatDirection()
        local forward = nil
        if dependencies.getForward ~= nil then
            pcall(function()
                forward = dependencies.getForward()
            end)
        end
        if forward == nil then
            pcall(function()
                forward = environment.CurrentCamera.Forward
            end)
        end
        local flat = WeaponThrowable.FlattenDirection(forward)
        if flat == nil then
            local player = getLocalPlayer()
            pcall(function()
                flat = WeaponThrowable.FlattenDirection(player.Forward)
            end)
        end
        return flat
    end

    -- Throw origin: the muzzle if the template owns one, otherwise the chest (as WeaponFire.ComputeAim does).
    local function getOrigin()
        if shootPos ~= nil then
            local position = nil
            pcall(function()
                position = shootPos.Position
            end)
            if position ~= nil then
                return position
            end
        end
        local player = getLocalPlayer()
        local position = nil
        pcall(function()
            position = player.Position + CHEST_LIFT
        end)
        return position
    end

    -- Where the Part actually starts: SPAWN_FORWARD in front of the origin unless a wall is right there
    -- (the same probe the server runs).
    local function getSpawnPosition(origin, flatDir, ignore)
        local probeEnd = origin + flatDir * (SPAWN_FORWARD + SPAWN_WALL_MARGIN)
        local wall = nil
        pcall(function()
            wall = castSegment(origin, probeEnd, ignore)
        end)
        if wall ~= nil then
            return origin
        end
        return origin + flatDir * SPAWN_FORWARD
    end

    local function currentCharge(now)
        local numbers = WeaponThrowable.ReadThrowNumbers(shared)
        return math.clamp((now - charge.startedAt) / numbers.chargeTime, 0, 1), numbers
    end

    -- Repositions the preview for the current charge. Everything is protected by the caller's pcall.
    local function updatePreview(chargeValue, numbers)
        local flatDir = getFlatDirection()
        local origin = getOrigin()
        if flatDir == nil or origin == nil then
            hidePreview()
            return
        end
        ensurePreview()
        local ignore = buildIgnoreList()
        local start = getSpawnPosition(origin, flatDir, ignore)
        local velocity = WeaponThrowable.ComputeLaunch(numbers, flatDir, chargeValue)
        local gravity = readGravity()

        local previous = start
        local landing = nil
        local lastDot = 0
        for index = 1, PREVIEW_STEPS do
            local position = WeaponThrowable.PositionAt(start, velocity, gravity, index * PREVIEW_DT)
            local hit = castSegment(previous, position, ignore)
            if hit ~= nil and hit.Position ~= nil then
                landing = hit.Position
                break
            end
            preview.dots[index].Position = position
            lastDot = index
            previous = position
        end
        for index = lastDot + 1, PREVIEW_STEPS do
            hidePart(preview.dots[index])
        end
        if landing ~= nil then
            preview.marker.Position = landing + Vector3.New(0, 0.06, 0)
            preview.marker.Color = Color.New(1, 1 - chargeValue, 0, 1)
        else
            hidePart(preview.marker)
        end
    end

    -- ---- charge life cycle ---------------------------------------------------------------------------------

    local function cancelCharge(reason)
        if not charge.active then
            return
        end
        charge.active = false
        charge.token = charge.token + 1
        hidePreview()
        trace(tool, ("charge cancelled without a throw (%s)"):format(reason))
    end

    local function chargeLoop(token)
        while charge.active and charge.token == token do
            local now = os.clock()
            if toolIsGone() or not isHeld() then
                cancelCharge("the Grenade is no longer held")
                return
            end
            if not isAlive() then
                cancelCharge("the player died")
                return
            end
            local focusedOk, focused = pcall(function()
                return input.IsGameFocused
            end)
            if focusedOk and focused == false then
                cancelCharge("the game window lost focus")
                return
            end
            if now - charge.startedAt > MAX_HOLD_SECONDS then
                cancelCharge("held longer than the safety limit")
                return
            end
            local chargeValue, numbers = currentCharge(now)
            local ok, err = pcall(updatePreview, chargeValue, numbers)
            if not ok then
                -- A cosmetic failure must not repeat every frame: stop the charge and say why.
                cancelCharge("preview failed")
                print(("[Ned Gun:throwable] %s: preview failed: %s"):format(tostring(tool.Name), tostring(err)))
                return
            end
            wait()
        end
    end

    local function startCharge()
        if charge.active then
            return -- key auto-repeat while held
        end
        if toolIsGone() or not isHeld() then
            return -- another Tool is in hand: the right mouse button is none of our business
        end
        -- Owner trace 2026-11-03: Mouse1 was seen but no charge started and nothing was printed. The old
        -- IsInputFocused gate is the prime suspect (its meaning is undocumented and may be "game has focus",
        -- i.e. always true), so it is now trace-only and never blocks the charge.
        local inputFocusedOk, inputFocused = pcall(function()
            return input.IsInputFocused
        end)
        if inputFocusedOk and inputFocused == true then
            trace(tool, "note: Input.IsInputFocused is true (not blocking the charge)")
        end
        if not isAlive() then
            trace(tool, "charge not started: the local player is not alive")
            return
        end
        if type(shared.ammo) ~= "number" or shared.ammo <= 0 then
            trace(tool, ("charge not started: no grenade left (ammo = %s)"):format(tostring(shared.ammo)))
            return
        end
        local numbers = WeaponThrowable.ReadThrowNumbers(shared)
        local now = os.clock()
        if now - shared.lastThrown < numbers.cooldown then
            trace(tool, "charge not started: client cooldown still running")
            return
        end
        charge.active = true
        charge.startedAt = now
        charge.token = charge.token + 1
        trace(tool, ("charge started (time %.2f s, speed %.0f..%.0f, pitch %.0f deg)"):format(numbers.chargeTime, numbers.minSpeed, numbers.throwSpeed, numbers.pitchDeg))
        local token = charge.token
        coroutine.resume(coroutine.create(function()
            local ok, err = pcall(chargeLoop, token)
            if not ok then
                cancelCharge("charge loop failed")
                print(("[Ned Gun:throwable] %s: charge loop failed: %s"):format(tostring(tool.Name), tostring(err)))
            end
        end))
    end

    -- Sends the request for an already validated release. The count and cooldown start here, optimistically.
    local function throw(chargeValue, heldFor)
        if type(shared.ammo) ~= "number" or shared.ammo <= 0 then
            trace(tool, ("rejected: no grenade left (ammo = %s)"):format(tostring(shared.ammo)))
            return
        end
        local numbers = WeaponThrowable.ReadThrowNumbers(shared)
        local now = os.clock()
        if now - shared.lastThrown < numbers.cooldown then
            trace(tool, "rejected: client cooldown still running")
            return
        end

        local remote = dependencies.remotes:FindChild("ThrowGrenade")
        if remote == nil then
            if not warnedMissingRemote then
                warnedMissingRemote = true
                print("[Ned Gun] Hidden/Remotes/ThrowGrenade is missing; the grenade cannot be thrown.")
            end
            trace(tool, "rejected: Hidden/Remotes/ThrowGrenade not found")
            return
        end

        local flatDir = getFlatDirection()
        local origin = getOrigin()
        if flatDir == nil or origin == nil then
            -- No usable aim: the count and cooldown stay untouched.
            trace(tool, "rejected: no usable throw direction or origin (camera and avatar forward unavailable)")
            return
        end
        local launchPitch = math.rad(numbers.pitchDeg)
        local direction = Vector3.New(flatDir.X * math.cos(launchPitch), math.sin(launchPitch), flatDir.Z * math.cos(launchPitch))

        shared.lastThrown = now
        -- Request id: the server echoes the highest id it has processed ("ack" in every reply). Client's reply
        -- handler can then show `count - (throwRid - ack)` so an optimistic throw still in flight never makes the
        -- HUD jump back up or down when an older reply arrives.
        shared.throwRid = (shared.throwRid or 0) + 1
        dependencies.addAmmo(tool, -1)

        local message = NetMessage.New()
        message:AddVector3("origin", origin)
        message:AddVector3("dir", direction)
        message:AddNumber("charge", chargeValue)
        message:AddInt("rid", shared.throwRid)
        remote:InvokeServer(message)
        local playerPosition = nil
        pcall(function()
            playerPosition = getLocalPlayer().Position
        end)
        trace(tool, ("request sent (ThrowGrenade rid %d, held %.2f s, charge %.2f), client origin %s, local player position %s, optimistic ammo now %s"):format(
            shared.throwRid, heldFor, chargeValue, formatVector(origin), formatVector(playerPosition), tostring(shared.ammo)))

        dependencies.findChildAndDoFunc(handle, "Throw", dependencies.playSound)
    end

    local function releaseCharge()
        if not charge.active then
            return
        end
        local heldFor = os.clock() - charge.startedAt
        charge.active = false
        charge.token = charge.token + 1
        hidePreview()
        local chargeValue = 0
        if heldFor >= TAP_SECONDS then
            chargeValue = currentCharge(charge.startedAt + heldFor)
        end
        if toolIsGone() or not isHeld() or not isAlive() then
            trace(tool, "release ignored: the Grenade is no longer held or the player is dead")
            return
        end
        throw(chargeValue, heldFor)
    end

    -- ---- wiring --------------------------------------------------------------------------------------------

    -- Self-disconnecting listeners: after a respawn the old Tool's connections are inert (they check their own
    -- Tool) and remove themselves on their next event.
    local keyDownConnection = nil
    local keyUpConnection = nil
    local function disconnectOwn()
        pcall(function()
            keyDownConnection:Disconnect()
        end)
        pcall(function()
            keyUpConnection:Disconnect()
        end)
        -- The destroyed Tool's preview parts would otherwise stay hidden under VFXs for the whole session.
        if preview ~= nil then
            pcall(function()
                preview.folder:Destroy()
            end)
            preview = nil
        end
    end

    local function noteMouseKey(key)
        local text = tostring(key)
        local lowered = string.lower(text)
        if string.find(lowered, "mouse", 1, true) ~= nil and lowered ~= "mouse0" and not seenMouseKeys[text] then
            seenMouseKeys[text] = true
            trace(tool, ("mouse key seen: '%s' (treated as %s)"):format(text, isRightMouseKey(key) and "RIGHT mouse" or "not the right button"))
        end
    end

    keyDownConnection = input.KeyDown:Connect(function(key)
        local ok, err = pcall(function()
            if toolIsGone() then
                disconnectOwn()
                return
            end
            noteMouseKey(key)
            if isRightMouseKey(key) then
                startCharge()
            end
        end)
        if not ok then
            print(("[Ned Gun:throwable] %s: key-down handler failed: %s"):format(tostring(tool.Name), tostring(err)))
        end
    end)
    keyUpConnection = input.KeyUp:Connect(function(key)
        local ok, err = pcall(function()
            if toolIsGone() then
                disconnectOwn()
                return
            end
            if isRightMouseKey(key) then
                releaseCharge()
            end
        end)
        if not ok then
            print(("[Ned Gun:throwable] %s: key-up handler failed: %s"):format(tostring(tool.Name), tostring(err)))
            cancelCharge("key-up handler failed")
        end
    end)

    pcall(function()
        tool.Unequipped:Connect(function()
            cancelCharge("unequipped")
        end)
    end)
    pcall(function()
        getLocalPlayer().Died:Connect(function()
            cancelCharge("died")
        end)
    end)

    -- Left click does nothing; it is traced so the owner can see it was received and ignored.
    mouse0.Changed:Connect(function()
        if mouse0.Value == true then
            trace(tool, "left click ignored: hold the right mouse button to charge, release to throw")
        end
    end)
end

return WeaponThrowable
