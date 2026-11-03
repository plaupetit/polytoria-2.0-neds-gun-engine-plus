-- WeaponGrenadeServer: server authority for the Grenade (Config kind = "throwable").
-- Role: validates a ThrowGrenade request, owns the grenade count and cooldown, spawns the physical grenade as a
--   ballistic throw, settles it (bounce, friction, rest), detonates it after the fuse and applies linear-falloff
--   damage with a line-of-sight check. The engine Explosion is spawned for effects only (Damage = 0, Force = 0)
--   so it can never bypass the "Protect" shield.
-- Side: server only.
-- Dependencies: Connect(remote, getTool, environment, players, dependencies) with
--   remote        Hidden/Remotes/ThrowGrenade (NetworkEvent),
--   getTool       function(player) -> the Tool the player holds,
--   environment   game["Environment"] (grenades and explosions are parented here; Environment.Gravity is read),
--   players       game["Players"],
--   dependencies  { gunUtil = GunUtil (RaycastSkippingIgnored, ResolveDamageableTarget, CollectDamageableTargets,
--                   HasLineOfSight), enums = the Enums table (PartShape.Sphere) }.
--   Nothing is required from sibling modules.
-- Protocol:  client -> server  {origin: Vector3, dir: Vector3 (unit launch direction), charge: Number (0..1),
--                               rid: Int (optional, request counter)}
--            server -> thrower {count: Int, tool: Instance, ack: Int, seq: Int} right after the throw (or after a
--                               rejection, to reconcile the optimistic HUD count), then once more after the blast
--                               with {count, tool, ack, seq, hitConfirmed: Bool}.
--            count  = the AUTHORITATIVE grenade count at the moment of the reply (never a delta).
--            ack    = highest client request id the server has processed (accepted or rejected); the client can
--                     subtract its still-unacknowledged optimistic throws (sent rid - ack) from `count`.
--            seq    = per-state reply counter; the client ignores a reply whose seq is not newer than the last one.
-- Throw (hold-to-charge, derived on the server, never client-supplied): the client sends the charge (0..1, clamped
--   here; NaN or missing counts as 0). Launch speed = Config.minThrowSpeed + (Config.throwSpeed - minThrowSpeed) *
--   charge. Launch direction = the HORIZONTAL part of the received `dir` (the camera yaw) combined with the fixed
--   pitch Config.throwPitchDeg; the pitch the client sent is ignored. Velocity = direction * speed. The client
--   preview (WeaponThrowable) uses the same formula and the same gravity source (Environment.Gravity, fallback 85),
--   so the drawn arc is the real flight path. There is no aim-point solving any more.
-- Settling: the Part is unanchored and gets low Mass, high Friction/AngularDrag, small Bounciness. After the
--   first world contact the server also damps horizontal speed every motion step and anchors the grenade once it
--   has been slow for REST_SAMPLES samples in a row, so it never slides forever. On touching a Player/NPC it
--   zeroes its horizontal velocity (it drops at their feet) and never pushes them: contact with the thrower is
--   ignored for THROWER_GRACE seconds so the launch itself cannot trigger it.
-- State: per PLAYER (keyed by the player's Name, which is unique per server) and Tool Name: count, last throw time,
--   ack and reply counter. It is keyed by name and not by Tool/Player userdata because the Tool instance seen by
--   getTool changed identity between requests in local test (the old per-Tool weak table kept re-creating the state
--   and refilled the count: infinite grenades). The count is refilled in place (ack and reply counter stay
--   monotonic) only when that player fires Died or Respawned, and the entry is dropped when the player leaves
--   (PlayerRemoved). If those signals cannot be connected the
--   count simply lasts for the session (the failure is traced). Created inside Connect; no module-global state.
-- Invariants: the client never supplies count, cooldown, speed, radius or damage; they come from the Tool's
--   own Config module. A thrower's own "Protect" shield is consumed by throwing, exactly like firing a gun.
--   hitConfirmed is true only when somebody other than the thrower lost health. The thrower takes blast damage
--   like anybody else (same falloff, same line-of-sight rule); any "Protect" child still blocks all damage.
-- Origin reference: the client origin is validated like the firearm muzzle (WeaponServer.getValidatedRayOrigin):
--   it must lie within MAX_CLIENT_ORIGIN_DRIFT (160 studs, deliberately permissive) of a server reference. Local test
--   showed sender.Position can lag the live avatar by 50..95 studs, so three references are tried in order:
--   sender.Character position (+ chest), the held Tool Handle, sender.Position (+ chest). The first one within the
--   limit accepts the throw; every request traces all three positions and distances so Play shows which one is live.
-- Diagnostics: DEBUG_WEAPON_KINDS (TEMPORARY, lot L4/L6/L8) prints a "[Ned Gun:throwable]" line at every early
--   return, pcall failure, request (with server/client positions), accepted request, launch velocity, first contact,
--   character-contact stop, rest, blast, applied damage and self-damage. Set it to false once confirmed in Play.
-- How to test: in Play hold right mouse, release: the grenade flies along the previewed arc, lands near the marker,
--   bounces a little and stops; a tap throws a short toss; it stops at an NPC/player's feet instead of pushing them
--   against a wall; the count drops 3, 2, 1, 0 and stays 0 until you die/respawn (never refills while walking);
--   NPCs inside the radius lose 90 (centre) down to 20 (edge) health; a wall between blast and NPC blocks the
--   damage; a spawn-protected player in range is unharmed; standing inside the radius hurts the thrower too;
--   throwing a 4th grenade does nothing; walking far away still lets the throw through (no "origin is N studs" line).
local WeaponGrenadeServer = {}

-- TEMPORARY diagnostics switch (see header). Remove with the trace calls when the kind modules are stable.
local DEBUG_WEAPON_KINDS = true

-- Same permissive limit as the firearm server (WeaponServer MAX_CLIENT_ORIGIN_DRIFT): the server replica of the
-- thrower is not reliable in local test, so this only rejects absurd origins.
local MAX_CLIENT_ORIGIN_DRIFT = 160
local COOLDOWN_TOLERANCE = 0.9 -- network jitter allowance: the server accepts a throw at 90% of the cooldown
local MOTION_STEP = 0.05 -- seconds between motion/position samples while the grenade is alive
local MAX_FUSE = 10 -- hard cap so a bad Config can never leave a grenade alive for minutes
local GRENADE_SIZE = 0.45
local GRENADE_COLOR = Color.New(0.10, 0.25, 0.10, 1)
local CHEST_OFFSET = Vector3.New(0, 1.2, 0) -- Player/NPC Position is near the feet; aim LOS and distance at the chest
local LOS_LIFT = Vector3.New(0, 0.3, 0) -- start the LOS ray above the floor the grenade rests on
local BLAST_EFFECT_LIFETIME = 5
-- minThrowSpeed and throwPitchDeg are optional (older Config copies): readConfig fills these defaults.
local REQUIRED_NUMBERS = {"maxAmmo", "damage", "edgeDamage", "radius", "fuse", "cooldown", "throwSpeed"}
local DEFAULT_MIN_THROW_SPEED = 20
local DEFAULT_THROW_PITCH_DEG = 40
local MIN_PITCH_DEG = 5
local MAX_PITCH_DEG = 80

-- Throw shaping. These two constants are mirrored in WeaponThrowable (client preview); keep them equal.
local DEFAULT_GRAVITY = 85 -- studs/s^2, the Creator default Environment.Gravity (0, -85, 0); used if unreadable
local SPAWN_FORWARD = 1.0 -- studs in front of the origin so the Part does not start inside the thrower
local SPAWN_WALL_MARGIN = 0.6
local MIN_FLAT_LENGTH = 0.05

-- Settling. Property names follow RigidBody in the 2.0.26 API definitions.
local PHYSICS_PROPERTIES = {
    {"Mass", 0.25}, -- light, so a contact cannot shove a character
    {"Friction", 1.5},
    {"Bounciness", 0.25},
    {"Drag", 0}, -- no air drag: the preview maths assumes a vacuum
    {"AngularDrag", 2},
}
local GROUND_DAMP_PER_SECOND = 0.02 -- horizontal speed multiplier per second after the first world contact
local REST_SPEED = 1.2 -- studs/s below which (horizontal and vertical) a grenade counts as resting
local REST_SAMPLES = 3 -- consecutive resting samples before the grenade is anchored
local SUPPORT_PROBE = GRENADE_SIZE * 0.5 + 0.25 -- downward ray length that counts as "something under it"
local THROWER_GRACE = 0.5 -- seconds after launch during which touching the thrower is ignored

local function trace(message)
    if DEBUG_WEAPON_KINDS then
        print("[Ned Gun:throwable] " .. message)
    end
end

local function toolName(tool)
    local name = "?"
    pcall(function()
        name = tool.Name
    end)
    return name
end

local function instanceName(instance)
    local name = "?"
    pcall(function()
        name = tostring(instance.Name)
    end)
    return name
end

-- "(x, y, z)" or "unreadable" for traces; never throws.
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

-- Returns the Config table, or nil plus a human-readable reason. Optional throw fields get their defaults here.
local function readConfig(tool)
    local ok, config = pcall(function()
        return require(tool["Config"])
    end)
    if not ok then
        return nil, ("Config module cannot be required: %s"):format(tostring(config))
    end
    if type(config) ~= "table" then
        return nil, "Config module did not return a table"
    end
    if config.kind ~= "throwable" then
        return nil, ("Config.kind is '%s', expected 'throwable'"):format(tostring(config.kind))
    end
    for _, key in ipairs(REQUIRED_NUMBERS) do
        if type(config[key]) ~= "number" then
            return nil, ("Config.%s is missing or not a number"):format(key)
        end
    end
    if config.maxAmmo < 1 or config.radius <= 0 or config.fuse < 0 or config.throwSpeed <= 0 or config.cooldown < 0 then
        return nil, "Config numbers out of range (maxAmmo >= 1, radius > 0, fuse >= 0, throwSpeed > 0, cooldown >= 0)"
    end
    local minSpeed = config.minThrowSpeed
    if type(minSpeed) ~= "number" then
        minSpeed = DEFAULT_MIN_THROW_SPEED
    end
    local pitch = config.throwPitchDeg
    if type(pitch) ~= "number" then
        pitch = DEFAULT_THROW_PITCH_DEG
    end
    -- The Config table is shared module state: never write the defaults back, return the derived numbers instead.
    return config, nil, math.min(math.max(minSpeed, 0), config.throwSpeed), math.min(math.max(pitch, MIN_PITCH_DEG), MAX_PITCH_DEG)
end

local function readVector3(message, key)
    local ok, value = pcall(function()
        return message:GetVector3(key)
    end)
    if ok then
        return value
    end
    return nil
end

-- Optional Int field (older clients do not send "rid"); nil when absent.
local function readInt(message, key)
    local ok, value = pcall(function()
        return message:GetInt(key)
    end)
    if ok and type(value) == "number" then
        return value
    end
    return nil
end

-- Charge in [0, 1]. A missing, non-numeric or NaN value counts as 0 (the weakest throw), never as full power.
-- Returns the clamped charge plus the raw received value for the trace.
local function readCharge(message)
    local ok, value = pcall(function()
        return message:GetNumber("charge")
    end)
    if not ok or type(value) ~= "number" then
        return 0, nil
    end
    if not (value >= 0) then
        return 0, value -- negative or NaN
    end
    if value > 1 then
        return 1, value
    end
    return value, value
end

-- Rejects nil, zero-length and NaN/infinite vectors (NaN fails every comparison, so the range test catches it).
local function isUsableDirection(direction)
    if direction == nil then
        return false
    end
    local length = direction.Magnitude
    return length > 0.001 and length < 1000000
end

-- Linear falloff from `damage` at the centre to `edgeDamage` at the radius.
local function computeDamage(config, distance)
    local ratio = math.clamp(distance / config.radius, 0, 1)
    local value = config.damage + (config.edgeDamage - config.damage) * ratio
    return math.floor(value + 0.5)
end

-- True when both references name the same Player/NPC. Userdata identity is not guaranteed for engine objects,
-- so Players also compare by name (names are unique per server).
local function isSameActor(first, second)
    if first == second then
        return true
    end
    local ok, same = pcall(function()
        return first:IsA("Player") and second:IsA("Player") and first.Name == second.Name
    end)
    return ok and same == true
end

-- World gravity as a positive magnitude (studs/s^2). Same source and fallback as the client preview.
local function readGravity(environment)
    local ok, value = pcall(function()
        return -environment.Gravity.Y
    end)
    if ok and type(value) == "number" and value > 1 and value < 10000 then
        return value
    end
    return DEFAULT_GRAVITY
end

-- Launch velocity for a charge in [0, 1]: horizontal direction flatDir (unit), fixed pitch, interpolated speed.
-- MUST match WeaponThrowable.ComputeLaunch (client preview). Returns velocity, speed.
local function computeLaunch(config, minSpeed, pitchDeg, flatDir, charge)
    local speed = minSpeed + (config.throwSpeed - minSpeed) * charge
    local pitch = math.rad(pitchDeg)
    local horizontal = math.cos(pitch) * speed
    local velocity = Vector3.New(flatDir.X * horizontal, math.sin(pitch) * speed, flatDir.Z * horizontal)
    return velocity, speed
end

-- Server positions that could stand for the thrower. Every read is protected: a missing Character or Handle is
-- simply nil. Keys: character, handle, body (sender.Position).
local function readServerPositions(sender, tool)
    local positions = {}
    pcall(function()
        positions.character = sender.Character.Position
    end)
    pcall(function()
        positions.handle = tool:FindChild("Handle").Position
    end)
    pcall(function()
        positions.body = sender.Position
    end)
    return positions
end

-- Reference list in priority order. `offset` lifts feet-level positions to chest height (client origins are chest or
-- muzzle height); the Tool Handle already sits at hand height.
local REFERENCE_ORDER = {
    {key = "character", label = "Character", offset = CHEST_OFFSET},
    {key = "handle", label = "held Tool Handle", offset = nil},
    {key = "body", label = "sender.Position", offset = CHEST_OFFSET},
}

-- Checks `clientPosition` against every readable reference. Returns acceptedLabel (nil when none is within
-- MAX_CLIENT_ORIGIN_DRIFT), acceptedDistance, readableCount and a summary string with every distance.
-- NaN distances fail the `<=` test, so a poisoned origin is rejected.
local function checkClientPosition(clientPosition, positions)
    local acceptedLabel, acceptedDistance = nil, nil
    local readable = 0
    local parts = {}
    for _, reference in ipairs(REFERENCE_ORDER) do
        local raw = positions[reference.key]
        if raw ~= nil then
            readable = readable + 1
            local ok, distance = pcall(function()
                local target = raw
                if reference.offset ~= nil then
                    target = raw + reference.offset
                end
                return (clientPosition - target).Magnitude
            end)
            if ok and type(distance) == "number" then
                table.insert(parts, ("%s %.1f"):format(reference.label, distance))
                if acceptedLabel == nil and distance <= MAX_CLIENT_ORIGIN_DRIFT then
                    acceptedLabel = reference.label
                    acceptedDistance = distance
                end
            else
                table.insert(parts, ("%s unusable"):format(reference.label))
            end
        end
    end
    return acceptedLabel, acceptedDistance, readable, table.concat(parts, ", ")
end

function WeaponGrenadeServer.Connect(remote, getTool, environment, players, dependencies)
    local gunUtil = dependencies.gunUtil
    local enums = dependencies.enums
    -- [playerName] = { tools = { [toolName] = state }, listening = bool }. Names, not userdata (see header).
    local playerEntries = {}
    -- Only used to tell two states apart in the traces (a count that "resets" would show a new serial).
    local nextStateSerial = 0

    local function getPlayerName(player)
        local name = "?"
        pcall(function()
            name = player.Name
        end)
        return name
    end

    -- Death or respawn: the next life starts with a full grenade count. Connected once per player entry.
    local function listenForNewLife(player, playerName, entry)
        entry.listening = true
        for _, signalName in ipairs({"Died", "Respawned"}) do
            local connected, connectError = pcall(function()
                player[signalName]:Connect(function()
                    -- Refill in place and keep ack/replySeq monotonic: a Tool that survives the respawn on the
                    -- client would otherwise ignore every reply as stale (seq restarted) or mis-count the HUD.
                    for _, state in pairs(entry.tools) do
                        state.count = state.maxCount
                        state.lastThrowAt = -math.huge
                    end
                    trace(("%s: %s fired, grenade count refilled for the next life"):format(playerName, signalName))
                end)
            end)
            if not connected then
                trace(("%s: %s could not be connected, the grenade count lasts for the session: %s"):format(playerName, signalName, tostring(connectError)))
            end
        end
    end

    local function getState(player, tool, config)
        local playerName = getPlayerName(player)
        local entry = playerEntries[playerName]
        if entry == nil then
            entry = { tools = {}, listening = false }
            playerEntries[playerName] = entry
        end
        if not entry.listening then
            listenForNewLife(player, playerName, entry)
        end
        local name = toolName(tool)
        local state = entry.tools[name]
        if state == nil then
            nextStateSerial = nextStateSerial + 1
            state = { count = config.maxAmmo, maxCount = config.maxAmmo, lastThrowAt = -math.huge, ack = 0, replySeq = 0, serial = nextStateSerial }
            entry.tools[name] = state
            trace(("%s: new state #%d for player %s created with count %d"):format(name, state.serial, playerName, state.count))
        end
        return state
    end

    -- Players that leave must not keep an entry (names can be reused by a later join with a full count).
    pcall(function()
        players.PlayerRemoved:Connect(function(player)
            playerEntries[getPlayerName(player)] = nil
        end)
    end)

    -- Replies never throw: the thrower may have left or the Tool may already be destroyed. Every reply carries
    -- the authoritative count plus ack/seq so the client can reconcile its optimistic decrement (see header).
    local function reply(player, tool, state, hitConfirmed)
        state.replySeq = state.replySeq + 1
        local ok, err = pcall(function()
            local message = NetMessage.New()
            message:AddInt("count", state.count)
            message:AddInstance("tool", tool)
            message:AddInt("ack", state.ack)
            message:AddInt("seq", state.replySeq)
            if hitConfirmed ~= nil then
                message:AddBool("hitConfirmed", hitConfirmed)
            end
            remote:InvokeClient(message, player)
        end)
        if ok then
            trace(("%s: reply sent (state #%d, count %d, ack %d, seq %d%s)"):format(toolName(tool), state.serial, state.count, state.ack, state.replySeq, hitConfirmed ~= nil and (", hitConfirmed " .. tostring(hitConfirmed)) or ""))
        else
            trace(("%s: reply failed: %s"):format(toolName(tool), tostring(err)))
        end
    end

    -- True when something (world or a body) lies within SUPPORT_PROBE below the grenade.
    local function isSupported(grenade, position)
        local hit = gunUtil.RaycastSkippingIgnored(environment, position, Vector3.New(0, -1, 0), SUPPORT_PROBE, {grenade})
        return hit ~= nil and hit.Instance ~= nil
    end

    -- Touch handler. Characters: stop the horizontal motion so the grenade drops at their feet (never pushes).
    -- Anything else: remember the first world contact, which starts the settling damping.
    local function onTouched(grenade, motion, thrower, hit)
        if motion.settled or motion.detonated or hit == nil then
            return
        end
        local target = gunUtil.ResolveDamageableTarget(hit)
        if target ~= nil then
            if isSameActor(target, thrower) and os.clock() - motion.spawnedAt < THROWER_GRACE then
                return -- the launch itself overlaps the thrower's body
            end
            local velocity = grenade.Velocity
            grenade.Velocity = Vector3.New(0, math.min(velocity.Y, 0), 0)
            grenade.AngularVelocity = Vector3.New(0, 0, 0)
            motion.characterContacts = motion.characterContacts + 1
            if motion.characterContacts == 1 then
                trace(("character contact with %s: horizontal velocity zeroed (was %.1f, %.1f), grenade drops at their feet"):format(instanceName(target), velocity.X, velocity.Z))
            end
            return
        end
        if motion.contactAt == nil then
            motion.contactAt = os.clock()
            local velocity = grenade.Velocity
            trace(("first contact with %s after %.2f s at speed %.1f"):format(instanceName(hit), motion.contactAt - motion.spawnedAt, velocity.Magnitude))
        end
    end

    local function spawnGrenade(config, spawnPosition, velocity, thrower, motion)
        local grenade = Part.New()
        grenade.Name = "Grenade"
        if enums ~= nil and enums.PartShape ~= nil then
            grenade.Shape = enums.PartShape.Sphere
        end
        grenade.Size = Vector3.New(GRENADE_SIZE, GRENADE_SIZE, GRENADE_SIZE)
        grenade.Color = GRENADE_COLOR
        grenade.Anchored = false
        grenade.CanCollide = true
        -- Each property is set on its own: one rejected name must not leave the rest at their defaults.
        for _, entry in ipairs(PHYSICS_PROPERTIES) do
            local ok, err = pcall(function()
                grenade[entry[1]] = entry[2]
            end)
            if not ok then
                trace(("physics property %s could not be set: %s"):format(entry[1], tostring(err)))
            end
        end
        grenade.Position = spawnPosition
        grenade.Parent = environment
        -- A client has no authority over this part; the server simulates it.
        grenade.Velocity = velocity
        -- Bullet rays skip any Instance owning a child named "!Ignore", so guns never stop on a grenade in flight.
        Instance.New("Folder", grenade).Name = "!Ignore"
        local connected, connectError = pcall(function()
            grenade.Touched:Connect(function(hit)
                local ok, err = pcall(onTouched, grenade, motion, thrower, hit)
                if not ok then
                    trace(("touch handler failed: %s"):format(tostring(err)))
                end
            end)
        end)
        if not connected then
            trace(("Touched could not be connected (the support probe still settles the grenade): %s"):format(tostring(connectError)))
        end
        return grenade
    end

    -- One motion sample: after the first world contact damp horizontal speed, and anchor the grenade once it rests.
    local function stepMotion(grenade, motion, dt)
        if motion.settled then
            return
        end
        local position = grenade.Position
        if motion.contactAt == nil then
            -- Touched may not fire for every kind of surface; a short downward ray catches a grenade that is already
            -- rolling or resting.
            if isSupported(grenade, position) then
                motion.contactAt = os.clock()
                trace(("first contact (support probe) after %.2f s"):format(motion.contactAt - motion.spawnedAt))
            else
                return
            end
        end
        local velocity = grenade.Velocity
        local damp = GROUND_DAMP_PER_SECOND ^ math.clamp(dt, 0.01, 0.5)
        local damped = Vector3.New(velocity.X * damp, velocity.Y, velocity.Z * damp)
        grenade.Velocity = damped
        grenade.AngularVelocity = grenade.AngularVelocity * damp
        local horizontal = math.sqrt(damped.X * damped.X + damped.Z * damped.Z)
        if horizontal < REST_SPEED and math.abs(damped.Y) < REST_SPEED and isSupported(grenade, position) then
            motion.restSamples = motion.restSamples + 1
            if motion.restSamples >= REST_SAMPLES then
                grenade.Velocity = Vector3.New(0, 0, 0)
                grenade.AngularVelocity = Vector3.New(0, 0, 0)
                grenade.Anchored = true
                motion.settled = true
                trace(("came to rest at (%.1f, %.1f, %.1f) after %.2f s, anchored"):format(position.X, position.Y, position.Z, os.clock() - motion.spawnedAt))
            end
        else
            motion.restSamples = 0
        end
    end

    -- Applies the falloff damage; returns true when somebody other than `thrower` lost health.
    -- The thrower is an ordinary target (self-damage); every skip reason is traced for the thrower.
    local function applyBlast(config, blastPosition, grenade, thrower)
        local hitConfirmed = false
        local losOrigin = blastPosition + LOS_LIFT
        local candidates, damaged, blocked = 0, 0, 0
        for _, target in ipairs(gunUtil.CollectDamageableTargets(players, environment)) do
            -- A target destroyed mid-pass (disconnect, NPC cleanup) must not abort the rest of the blast;
            -- any error is traced, never swallowed.
            local ok, err = pcall(function()
                local isSelf = isSameActor(target, thrower)
                if target.Health <= 0 then
                    if isSelf then
                        trace("self-damage skipped: the thrower is already dead")
                    end
                    return
                end
                if target:FindChild("Protect") then
                    if isSelf then
                        trace("self-damage skipped: the thrower carries a Protect shield")
                    end
                    return
                end
                candidates = candidates + 1
                local chest = target.Position + CHEST_OFFSET
                local distance = (chest - blastPosition).Magnitude
                if distance > config.radius then
                    if isSelf then
                        trace(("self-damage skipped: thrower is %.1f studs from the blast (radius %.1f)"):format(distance, config.radius))
                    end
                    return
                end
                if not gunUtil.HasLineOfSight(environment, losOrigin, chest, {grenade}) then
                    blocked = blocked + 1
                    if isSelf then
                        trace(("self-damage skipped: wall between the blast and the thrower (%.1f studs)"):format(distance))
                    end
                    return
                end
                local damage = computeDamage(config, distance)
                target.Health = target.Health - damage
                damaged = damaged + 1
                trace(("damage %d applied to %s at %.1f studs%s"):format(damage, tostring(target.Name), distance, isSelf and " (SELF-DAMAGE)" or ""))
                if not isSelf then
                    hitConfirmed = true
                end
            end)
            if not ok then
                trace(("blast target check failed: %s"):format(tostring(err)))
            end
        end
        trace(("blast: %d unprotected candidates, %d damaged, %d blocked by walls"):format(candidates, damaged, blocked))
        return hitConfirmed
    end

    local function detonate(config, grenade, lastKnownPosition, thrower, tool, state, motion)
        motion.detonated = true
        local blastPosition = lastKnownPosition
        pcall(function()
            blastPosition = grenade.Position
        end)

        -- Effects only: Damage 0 and Force 0 keep the engine from hurting or shoving anyone, so the script-owned
        -- falloff below (with its Protect check) is the single source of damage.
        local explosionOk, explosion = pcall(function()
            local effect = Explosion.New()
            effect.Position = blastPosition
            effect.Radius = config.radius
            effect.Damage = 0
            effect.Force = 0
            effect.UseEffects = true
            effect.Parent = environment
            return effect
        end)

        if not explosionOk then
            trace(("explosion effect failed (damage still applies): %s"):format(tostring(explosion)))
        end
        trace(("detonating at (%.1f, %.1f, %.1f)"):format(blastPosition.X, blastPosition.Y, blastPosition.Z))
        local hitConfirmed = applyBlast(config, blastPosition, grenade, thrower)

        pcall(function()
            grenade:Destroy()
        end)
        if explosionOk and explosion ~= nil then
            -- The effect object is cosmetic; remove it after its animation so it cannot pile up.
            pcall(function()
                explosion:Destroy(BLAST_EFFECT_LIFETIME)
            end)
        end
        reply(thrower, tool, state, hitConfirmed)
    end

    -- Horizontal unit vector to use when the received direction has no horizontal part (aimed straight up or down).
    local function fallbackFlatDirection(sender)
        local flat = nil
        pcall(function()
            local forward = sender.Forward
            flat = Vector3.New(forward.X, 0, forward.Z)
        end)
        if flat ~= nil and flat.Magnitude > MIN_FLAT_LENGTH then
            return flat.Normalized
        end
        return Vector3.New(0, 0, 1)
    end

    -- Derives the launch from the validated origin, the received yaw and the clamped charge.
    -- Returns velocity, spawnPosition plus a description for the trace.
    local function planThrow(config, minSpeed, pitchDeg, sender, tool, origin, direction, charge)
        local flat = Vector3.New(direction.X, 0, direction.Z)
        local flatDir = nil
        if flat.Magnitude > MIN_FLAT_LENGTH then
            flatDir = flat.Normalized
        else
            flatDir = fallbackFlatDirection(sender)
        end

        local gravity = readGravity(environment)
        local velocity, speed = computeLaunch(config, minSpeed, pitchDeg, flatDir, charge)

        -- A wall right in front of the thrower: do not spawn the Part behind it.
        local forward = SPAWN_FORWARD
        local ignore = {sender, tool}
        pcall(function()
            local character = sender.Character
            if character ~= nil then
                table.insert(ignore, character)
            end
        end)
        local wallOk, wallHit = pcall(function()
            return gunUtil.RaycastSkippingIgnored(environment, origin, flatDir, SPAWN_FORWARD + SPAWN_WALL_MARGIN, ignore)
        end)
        if not wallOk then
            trace(("spawn wall probe failed (spawning in front anyway): %s"):format(tostring(wallHit)))
        elseif wallHit ~= nil and wallHit.Instance ~= nil then
            forward = 0
        end
        local spawnPosition = origin + flatDir * forward
        local flight = speed * math.sin(math.rad(pitchDeg))
        local peak = flight * flight / (2 * gravity)
        local description = ("charge %.2f, launch speed %.1f (min %.1f, max %.1f), pitch %.0f deg, g %.0f, velocity (%.1f, %.1f, %.1f), predicted peak %.1f, spawn %s"):format(
            charge, speed, minSpeed, config.throwSpeed, pitchDeg, gravity, velocity.X, velocity.Y, velocity.Z, peak, formatVector(spawnPosition)
        )
        return velocity, spawnPosition, description
    end

    remote.InvokedServer:Connect(function(sender, message)
        local senderName = getPlayerName(sender)
        trace(("request received from %s"):format(senderName))
        local tool = getTool(sender)
        if not tool then
            trace(("rejected: %s holds no Tool"):format(senderName))
            return
        end
        local name = toolName(tool)
        local config, reason, minSpeed, pitchDeg = readConfig(tool)
        if config == nil then
            trace(("%s: rejected: %s"):format(name, reason))
            return
        end

        local state = getState(sender, tool, config)
        -- Acknowledge the request id first, whatever the outcome, so every reply tells the client how many of
        -- its optimistic throws the server has already settled.
        local rid = readInt(message, "rid")
        if rid ~= nil and rid > state.ack then
            state.ack = rid
        end

        -- Read the whole request up front so the position trace below shows which server position is live.
        local origin = readVector3(message, "origin")
        local direction = readVector3(message, "dir")
        local charge, rawCharge = readCharge(message)
        local positions = readServerPositions(sender, tool)
        trace(("%s: positions: sender.Position %s, Character %s, held Tool Handle %s, client origin %s, charge %s (used %.2f)"):format(
            name, formatVector(positions.body), formatVector(positions.character), formatVector(positions.handle),
            formatVector(origin), rawCharge == nil and "missing" or tostring(rawCharge), charge))

        local now = os.clock()
        if state.count <= 0 or now - state.lastThrowAt < config.cooldown * COOLDOWN_TOLERANCE then
            -- Reconcile the client's optimistic count instead of leaving it out of sync.
            trace(("%s: rejected: %s (state #%d, count %d, rid %s)"):format(name, state.count <= 0 and "no grenade left" or "server cooldown still running", state.serial, state.count, tostring(rid)))
            reply(sender, tool, state)
            return
        end

        if origin == nil or not isUsableDirection(direction) then
            trace(("%s: rejected: missing 'origin' or unusable 'dir' in the message"):format(name))
            reply(sender, tool, state)
            return
        end
        local acceptedLabel, acceptedDistance, readable, summary = checkClientPosition(origin, positions)
        if readable == 0 then
            trace(("%s: rejected: no server position of the thrower could be read"):format(name))
            reply(sender, tool, state)
            return
        end
        if acceptedLabel == nil then
            trace(("%s: rejected: origin is farther than %d studs from every server reference (%s)"):format(name, MAX_CLIENT_ORIGIN_DRIFT, summary))
            reply(sender, tool, state)
            return
        end
        trace(("%s: origin accepted against %s at %.1f studs (limit %d; all: %s)"):format(name, acceptedLabel, acceptedDistance, MAX_CLIENT_ORIGIN_DRIFT, summary))

        local planOk, velocity, spawnPosition, description = pcall(planThrow, config, minSpeed, pitchDeg, sender, tool, origin, direction.Normalized, charge)
        if not planOk then
            trace(("%s: rejected: throw planning failed: %s"):format(name, tostring(velocity)))
            reply(sender, tool, state)
            return
        end

        state.count = state.count - 1
        state.lastThrowAt = now
        -- Attacking ends the spawn shield, exactly like firing a gun (WeaponServer).
        pcall(function()
            local shield = sender:FindChild("Protect")
            if shield then
                shield:Destroy()
            end
        end)

        local motion = { spawnedAt = os.clock(), contactAt = nil, characterContacts = 0, restSamples = 0, settled = false, detonated = false }
        local spawnOk, grenade = pcall(spawnGrenade, config, spawnPosition, velocity, sender, motion)
        if not spawnOk then
            -- The throw never happened: give the grenade back so the authoritative count stays honest.
            state.count = state.count + 1
            state.lastThrowAt = -math.huge
            trace(("%s: grenade spawn failed (count restored to %d): %s"):format(name, state.count, tostring(grenade)))
            reply(sender, tool, state)
            return
        end
        trace(("%s: accepted (state #%d, rid %s), grenade spawned, count now %d, fuse %.1f s"):format(name, state.serial, tostring(rid), state.count, config.fuse))
        trace(("launch: %s"):format(description))
        reply(sender, tool, state)

        spawn(function()
            local deadline = now + math.min(config.fuse, MAX_FUSE)
            local lastKnownPosition = spawnPosition
            local lastSampleAt = os.clock()
            repeat
                wait(MOTION_STEP)
                local sampleAt = os.clock()
                -- A grenade that fell out of the world is destroyed; keep its last sampled position.
                pcall(function()
                    lastKnownPosition = grenade.Position
                end)
                local stepOk, stepError = pcall(stepMotion, grenade, motion, sampleAt - lastSampleAt)
                if not stepOk then
                    trace(("motion step failed: %s"):format(tostring(stepError)))
                end
                lastSampleAt = sampleAt
            until os.clock() >= deadline
            local detonateOk, detonateError = pcall(detonate, config, grenade, lastKnownPosition, sender, tool, state, motion)
            if not detonateOk then
                trace(("%s: detonation failed: %s"):format(name, tostring(detonateError)))
            end
        end)
    end)
    trace("server connected (Hidden/Remotes/ThrowGrenade)")
end

return WeaponGrenadeServer
