-- WeaponMeleeServer: server authority for the Knife (Config kind = "melee").
-- Role: validates a Melee request, enforces the cooldown, then plays the slash as a SWEPT HITBOX over time: the
--   blade (a horizontal segment from the hilt to the tip at attacker chest height) rotates through the yaw arc of
--   the client animation, and every Player or NPC whose body capsule the blade touches is damaged, once per swing.
--   Several targets can be hit by the same swing. This replaces the old "nearest target in a range + cone" scan.
-- Side: server only.
-- Dependencies: Connect(remote, getTool, environment, players, dependencies) with
--   remote        Hidden/Remotes/Melee (NetworkEvent),
--   getTool       function(player) -> the Tool the player holds,
--   environment   game["Environment"] (NPC list and line-of-sight raycasts),
--   players       game["Players"],
--   dependencies  { gunUtil = GunUtil (CollectDamageableTargets, HasLineOfSight, RaycastSkippingIgnored, IsDestroyed) }.
--   Nothing is required from sibling modules.
-- Protocol:  client -> server  {dir: Vector3 (camera forward; only its horizontal part is used),
--                               pos: Vector3 (optional; the client avatar's CHEST position, feet + 1.2)}
--            server -> attacker {hitConfirmed: Bool, tool: Instance} once per swing, at the first damaging hit.
-- State: last swing time per player Name + Tool Name in a plain table created inside Connect (bounded by
--   players x tools; Tool/Player userdata identity is not stable across requests in local test, so it is not a key);
--   each swing owns a private record list (one record per candidate) that lives only for the 0.25 s sweep;
--   no module-global mutable state.
-- Hitbox model (SHARED NUMBERS with WeaponMelee SLASH_KEYFRAMES, keep both files in sync):
--   * Blade: horizontal segment at chest height (the validated `pos` Y), from BLADE_START (1.5 studs, the hilt) to
--     the tip at Config.bladeReach (optional) or, when absent, Config.range.
--   * Arc: yaw relative to `dir` follows SLASH_YAW_KEYFRAMES = 0 -> -45 (0.07 s wind-up) -> +55 (0.16 s slash) ->
--     0 (0.25 s return), smoothstep eased exactly like the client animation. The wind-up segment is NOT damaging
--     (the blade is cocked back and the slash covers the same ground); the slash and the return are.
--     YAW_SIGN = 1 means a positive yaw swings towards the attacker's RIGHT (Unity-style clockwise from above, the
--     assumed Polytoria convention); flip YAW_SIGN to -1 if Play shows the blade sweeping the other way.
--   * Target body: vertical capsule, Position = feet, CAPSULE_HEIGHT 5 and CAPSULE_RADIUS 1.2 (NPC/Player expose no
--     body size in the API; Dynamic.Size is only traced, never used). The blade may be up to BLADE_VERTICAL_SLACK
--     studs outside the capsule's vertical axis range and still counts as touching (stairs, slopes, jumps).
--   * Test: the exact distance between the capsule and the annular sector swept by the blade between two animation
--     times (no sampling, so no gaps at any arc speed); overlap (distance <= radius) = hit. The swept sector is
--     re-tested over time (steps no longer than MAX_STEP_SECONDS, aligned to the keyframes), so a target that walks
--     into the arc mid-swing is hit. Target POSITIONS are re-read every step; the attacker chest stays fixed at the
--     validated `pos` of the request (the swing is a short, animation-locked action).
--   * Line of sight: chest -> point on the target capsule surface nearest to the target axis (world geometry
--     blocks, other bodies do not). Blocked contacts are retried on later steps.
-- Attacker position: in local test the server's sender.Position lagged the live avatar by 50..95 studs, which made
--   every swing report "0 in range". The swing carries the client's own chest position `pos`. It is used as the
--   hitbox origin only when it lies within MAX_CLIENT_POSITION_DRIFT (160 studs, as permissive as the firearm
--   origin check) of one of the server's references, tried in order: sender.Character position, the held Tool
--   Handle, sender.Position. Beyond that the swing is rejected with a trace (cooldown not consumed). Without `pos`
--   (older client) the server falls back to Character, then sender.Position (+ chest lift). Target positions are
--   ALWAYS the server's own; only the attacker side is client-reported, so a forged `pos` can move the knife up
--   to 160 studs (documented as permissive, see ARCHITECTURE "Known follow-ups"). A Player target's server
--   replica may lag its live avatar the same way, so another player can be hit slightly behind where they look.
-- Invariants: blade reach, cooldown and damage come from the Tool's Config, never from the client. The swing
--   direction only orients the arc, and the blade can never reach beyond its tip distance from the validated
--   chest position. Config.coneAngle is no longer used (legacy field, ignored).
--   A target carrying "Protect" is touched like any other (the shield stops the blade) but takes no damage and
--   does not confirm a hit. Swinging, hit or miss, consumes the attacker's own "Protect" and the cooldown.
--   Per-target work runs inside pcall (a target can vanish mid-sweep), but a failure is TRACED, never swallowed:
--   an earlier version hid a bad Vector3:Dot call there and silently skipped every target.
-- Diagnostics: DEBUG_WEAPON_KINDS (TEMPORARY, lot L4/L9) prints a "[Ned Gun:melee]" line at every early return,
--   pcall failure and accepted request, plus per swing the candidates and, for every target within
--   TRACE_GAP_LIMIT studs of the blade, the closest gap between the blade sweep and its capsule surface
--   (negative = overlap) with the hit / miss reason. Set it to false once the Knife is confirmed in Play.
-- How to test: in Play slash an NPC standing at the side of the arc, in front, and one you walk into: each loses
--   35-45 health and the hitmarker shows once per swing; two NPCs side by side are both hit by one swing; an NPC
--   behind you, 8+ studs away, behind a wall or a spawn-protected player is not damaged (the trace says why).
local WeaponMeleeServer = {}

-- TEMPORARY diagnostics switch (see header). Remove with the trace calls when the kind modules are stable.
local DEBUG_WEAPON_KINDS = true

local COOLDOWN_TOLERANCE = 0.9 -- network jitter allowance: accept a swing at 90% of the cooldown
local CHEST_OFFSET = Vector3.New(0, 1.2, 0) -- Player/NPC Position is near the feet; the client `pos` is chest height
local MIN_FLAT_LENGTH = 0.0001
local MAX_CLIENT_POSITION_DRIFT = 160 -- studs between the client `pos` and the nearest server reference
local REQUIRED_NUMBERS = {"cooldown", "range", "minDamage", "maxDamage"}

-- Hitbox tunables (see the header). Shared animation numbers: keep SLASH_YAW_KEYFRAMES equal to the `ry` column
-- of WeaponMelee SLASH_KEYFRAMES.
local BLADE_START = 1.5 -- studs from the chest to the hilt end of the swept segment
local MIN_BLADE_LENGTH = 0.5 -- the tip is never closer than BLADE_START + this
local CAPSULE_HEIGHT = 5 -- target body height, feet to head top
local CAPSULE_RADIUS = 1.2 -- target body radius
local BLADE_VERTICAL_SLACK = 0.75 -- studs the blade may miss the capsule axis range vertically and still touch
local CONTACT_PULLBACK = 0.9 -- LOS ends this fraction of the radius short of the axis (on the body surface)
local YAW_SIGN = 1 -- +1: positive yaw sweeps towards the attacker's right (assumed convention)
local MAX_STEP_SECONDS = 0.04 -- longest animation time between two hit tests
local ACTIVE_FROM_TIME = 0.07 -- animation time at which the blade starts being damaging (end of the wind-up)
local TRACE_GAP_LIMIT = 12 -- per-target trace lines only for targets this close (studs) to the blade surface
-- {time (s), yaw (degrees relative to the swing direction)}. Times strictly increasing from 0; arc width < 180.
local SLASH_YAW_KEYFRAMES = {
    {0.00, 0},
    {0.07, -45},
    {0.16, 55},
    {0.25, 0},
}

-- Hit-test steps derived once from the keyframes: each step covers the yaw interval the blade passes between the
-- previous and this animation time. Yaw is monotonic inside a keyframe segment (smoothstep), so the interval ends
-- are its extremes and nothing between two tests can be missed. Built at load; the table is never mutated after.
local function buildSweepSteps()
    local steps = {}
    for index = 2, #SLASH_YAW_KEYFRAMES do
        local from = SLASH_YAW_KEYFRAMES[index - 1]
        local to = SLASH_YAW_KEYFRAMES[index]
        local span = to[1] - from[1]
        local count = math.max(1, math.ceil(span / MAX_STEP_SECONDS))
        local previousYaw = from[2]
        for part = 1, count do
            local t = part / count
            local eased = t * t * (3 - 2 * t)
            local yaw = from[2] + (to[2] - from[2]) * eased
            table.insert(steps, {
                time = from[1] + span * t,
                yawFrom = previousYaw,
                yawTo = yaw,
                damaging = from[1] >= ACTIVE_FROM_TIME - 0.000001,
            })
            previousYaw = yaw
        end
    end
    return steps
end

local SWEEP_STEPS = buildSweepSteps()

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

-- Server positions that could stand for the attacker. Every read is protected: a missing Character or Handle is
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

-- Reference list in priority order. `offset` lifts feet-level positions to chest height (the client `pos` is a
-- chest position); the Tool Handle already sits at hand height.
local REFERENCE_ORDER = {
    {key = "character", label = "Character", offset = CHEST_OFFSET},
    {key = "handle", label = "held Tool Handle", offset = nil},
    {key = "body", label = "sender.Position", offset = CHEST_OFFSET},
}

-- Checks the client chest position against every readable reference. Returns acceptedLabel (nil when none is
-- within MAX_CLIENT_POSITION_DRIFT), acceptedDistance, readableCount and a summary with every distance.
-- NaN distances fail the `<=` test, so a poisoned position is rejected.
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
                if acceptedLabel == nil and distance <= MAX_CLIENT_POSITION_DRIFT then
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

-- True when both references name the same Player/NPC (Players also compare by name: userdata identity of engine
-- objects is not guaranteed).
local function isSameActor(first, second)
    if first == second then
        return true
    end
    local ok, same = pcall(function()
        return first:IsA("Player") and second:IsA("Player") and first.Name == second.Name
    end)
    return ok and same == true
end

local function trace(message)
    if DEBUG_WEAPON_KINDS then
        print("[Ned Gun:melee] " .. message)
    end
end

local function toolName(tool)
    local name = "?"
    pcall(function()
        name = tool.Name
    end)
    return name
end

-- Returns the Config table, or nil plus a human-readable reason.
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
    if config.kind ~= "melee" then
        return nil, ("Config.kind is '%s', expected 'melee'"):format(tostring(config.kind))
    end
    for _, key in ipairs(REQUIRED_NUMBERS) do
        if type(config[key]) ~= "number" then
            return nil, ("Config.%s is missing or not a number"):format(key)
        end
    end
    -- math.random(min, max) needs ordered integer bounds.
    if config.range <= 0 or config.cooldown < 0 or config.minDamage > config.maxDamage then
        return nil, "Config numbers out of range (range > 0, cooldown >= 0, minDamage <= maxDamage)"
    end
    return config
end

-- Horizontal unit vector, or nil for a missing, vertical, zero-length or NaN input.
local function flatten(vector)
    if vector == nil then
        return nil
    end
    local flat = Vector3.New(vector.X, 0, vector.Z)
    if not (flat.Magnitude > MIN_FLAT_LENGTH and flat.Magnitude < 1000000) then
        return nil
    end
    return flat.Normalized
end

-- Tip distance of the blade: Config.bladeReach when present, else Config.range, never shorter than the hilt plus
-- MIN_BLADE_LENGTH so the swept sector keeps a positive width.
local function bladeTipDistance(config)
    local tip = config.range
    if type(config.bladeReach) == "number" and config.bladeReach > 0 then
        tip = config.bladeReach
    end
    return math.max(tip, BLADE_START + MIN_BLADE_LENGTH)
end

-- 2D distance from point (u, v) to the radial segment that starts at radius `rIn` and ends at radius `rOut` along
-- the unit direction (bu, bv). Frame: u = along the swing direction, v = towards the attacker's right.
local function distanceToRadialSegment(u, v, bu, bv, rIn, rOut)
    local along = u * bu + v * bv
    if along < rIn then
        along = rIn
    elseif along > rOut then
        along = rOut
    end
    local du = u - along * bu
    local dv = v - along * bv
    return math.sqrt(du * du + dv * dv)
end

-- 2D distance (0 inside) from point (u, v) to the annular sector between radii rIn..rOut and yaw angles
-- loDeg..hiDeg (hiDeg - loDeg < 180). Angles grow from the swing direction (+u) towards +v. The wedge membership
-- uses cross products, so no atan is needed. NaN input yields NaN, which never passes a `<=` test.
local function distanceToSector(u, v, loDeg, hiDeg, rIn, rOut)
    local loRad = math.rad(loDeg)
    local hiRad = math.rad(hiDeg)
    local loU, loV = math.cos(loRad), math.sin(loRad)
    local hiU, hiV = math.cos(hiRad), math.sin(hiRad)
    local insideWedge = (loU * v - loV * u) >= 0 and (u * hiV - v * hiU) >= 0
    if insideWedge then
        local radius = math.sqrt(u * u + v * v)
        return math.max(0, rIn - radius, radius - rOut)
    end
    return math.min(
        distanceToRadialSegment(u, v, loU, loV, rIn, rOut),
        distanceToRadialSegment(u, v, hiU, hiV, rIn, rOut)
    )
end

-- Distance between the target capsule SURFACE and the blade sweep (negative = overlap). `frame` holds the swing
-- origin (chest), the unit swing direction (dx, dz) and its right-hand perpendicular (rx, rz).
-- Returns gap, horizontalDistance, verticalGap, u, v and the capsule axis point nearest the blade height.
local function measureGap(feet, frame, loDeg, hiDeg, rIn, rOut)
    local relativeX = feet.X - frame.origin.X
    local relativeZ = feet.Z - frame.origin.Z
    local u = relativeX * frame.dx + relativeZ * frame.dz
    local v = relativeX * frame.rx + relativeZ * frame.rz
    local horizontal = distanceToSector(u, v, loDeg, hiDeg, rIn, rOut)
    -- The capsule's vertical axis runs from one radius above the feet to one radius below the head top.
    local axisLow = feet.Y + CAPSULE_RADIUS
    local axisHigh = feet.Y + CAPSULE_HEIGHT - CAPSULE_RADIUS
    local bladeHeight = frame.origin.Y
    local axisY = bladeHeight
    local vertical = 0
    if bladeHeight < axisLow then
        axisY = axisLow
        vertical = axisLow - bladeHeight
    elseif bladeHeight > axisHigh then
        axisY = axisHigh
        vertical = bladeHeight - axisHigh
    end
    vertical = math.max(0, vertical - BLADE_VERTICAL_SLACK)
    local gap = math.sqrt(horizontal * horizontal + vertical * vertical) - CAPSULE_RADIUS
    return gap, horizontal, vertical, u, v, Vector3.New(feet.X, axisY, feet.Z)
end

-- Degrees of the target direction relative to the swing direction (positive = right), trace only. "?" on failure.
local function describeBearing(u, v)
    local ok, text = pcall(function()
        return ("%.0f"):format(math.deg(math.atan2(v, u)))
    end)
    if ok then
        return text
    end
    return "?"
end

function WeaponMeleeServer.Connect(remote, getTool, environment, players, dependencies)
    local gunUtil = dependencies.gunUtil
    -- [playerName .. "|" .. toolName] = last accepted swing time. String keys: see the State note in the header.
    local lastSwingAt = {}

    local function reply(player, tool)
        local ok, err = pcall(function()
            local message = NetMessage.New()
            message:AddBool("hitConfirmed", true)
            message:AddInstance("tool", tool)
            remote:InvokeClient(message, player)
        end)
        if ok then
            trace(("%s: reply sent (hitConfirmed)"):format(toolName(tool)))
        else
            trace(("%s: reply failed: %s"):format(toolName(tool), tostring(err)))
        end
    end

    -- Snapshot of every damageable Player/NPC (not the attacker, still alive) taking part in this swing. One record
    -- each: the engine object, a display name, the best (smallest) surface gap seen, and the final outcome.
    local function collectCandidates(attacker)
        local records = {}
        for _, target in ipairs(gunUtil.CollectDamageableTargets(players, environment)) do
            local ok, err = pcall(function()
                if isSameActor(target, attacker) or target.Health <= 0 then
                    return
                end
                table.insert(records, {
                    target = target,
                    name = tostring(target.Name),
                    minGap = math.huge,
                    closest = "never tested",
                    done = false,
                    outcome = nil,
                    blockedAt = nil,
                })
            end)
            if not ok then
                trace(("candidate check failed: %s"):format(tostring(err)))
            end
        end
        return records
    end

    -- Damages one touched target. Returns "hit", "protected" or "dead".
    local function applyDamage(record, tool, config)
        local target = record.target
        if target.Health <= 0 then
            return "dead"
        end
        if target:FindChild("Protect") then
            return "protected"
        end
        local damage = math.random(config.minDamage, config.maxDamage)
        target.Health = target.Health - damage
        trace(("%s: damage %d applied to %s"):format(toolName(tool), damage, record.name))
        return "hit"
    end

    -- One hit test of one candidate against the blade sector of `step`. Throws on engine errors (caller pcalls).
    local function testCandidate(record, step, frame, loDeg, hiDeg, rIn, rOut, ignore, tool, config, swing)
        local target = record.target
        if target.Health <= 0 then
            record.done = true
            record.outcome = "already dead"
            return
        end
        local feet = target.Position
        local gap, horizontal, vertical, u, v, axisPoint = measureGap(feet, frame, loDeg, hiDeg, rIn, rOut)
        if gap < record.minGap then
            record.minGap = gap
            record.closest = ("t=%.2f s, bearing %s deg, %.1f studs from the chest, horizontal %.1f, vertical %.1f"):format(
                step.time, describeBearing(u, v), math.sqrt(u * u + v * v), horizontal, vertical)
        end
        if not (gap <= 0) then
            return
        end
        -- Touching. World geometry between the chest and the body surface blocks the blade.
        local toAxis = axisPoint - frame.origin
        local distance = toAxis.Magnitude
        local pullback = CAPSULE_RADIUS * CONTACT_PULLBACK
        local visible = true
        if distance > pullback then
            local contact = frame.origin + toAxis.Normalized * (distance - pullback)
            visible = gunUtil.HasLineOfSight(environment, frame.origin, contact, ignore)
        end
        if not visible then
            record.blockedAt = step.time
            return
        end
        local result = applyDamage(record, tool, config)
        record.done = true
        if result == "hit" then
            record.outcome = ("HIT at t=%.2f s (gap %.1f)"):format(step.time, gap)
            swing.damaged = swing.damaged + 1
            if not swing.confirmed then
                swing.confirmed = true
                reply(swing.attacker, tool)
            end
        elseif result == "protected" then
            record.outcome = ("touched at t=%.2f s but protected (no damage)"):format(step.time)
            swing.protected = swing.protected + 1
        else
            record.outcome = "died before the damage landed"
        end
    end

    local function describeOutcome(record)
        if record.outcome ~= nil then
            return record.outcome
        end
        if record.blockedAt ~= nil then
            return ("touched at t=%.2f s but the line of sight was blocked by world geometry"):format(record.blockedAt)
        end
        if record.minGap == math.huge then
            return "never tested"
        end
        return ("MISS, closest gap %.1f studs outside the blade arc"):format(record.minGap)
    end

    -- Runs the whole slash for one accepted request. Never throws; yields between hit tests (own coroutine).
    local function runSweep(attacker, tool, config, direction, chest, ignore)
        local name = toolName(tool)
        local rIn = BLADE_START
        local rOut = bladeTipDistance(config)
        local frame = {
            origin = chest,
            dx = direction.X, dz = direction.Z,
            rx = direction.Z, rz = -direction.X, -- right-hand perpendicular (Unity-style: forward +Z has right +X)
        }
        local records = collectCandidates(attacker)
        local swing = {attacker = attacker, confirmed = false, damaged = 0, protected = 0}
        trace(("%s: sweep start: %d candidates, chest %s, dir (%.2f, %.2f), blade %.1f..%.1f studs, capsule %.1f x r%.1f, yaw sign %d"):format(
            name, #records, formatVector(chest), direction.X, direction.Z, rIn, rOut, CAPSULE_HEIGHT, CAPSULE_RADIUS, YAW_SIGN))

        local startedAt = os.clock()
        local testedSteps = 0
        for _, step in ipairs(SWEEP_STEPS) do
            local delay = step.time - (os.clock() - startedAt)
            if delay > 0.001 then
                wait(delay)
            end
            if step.damaging then
                -- A dead or departed attacker stops swinging. Only a successful read of Health <= 0 or a
                -- destroyed Player counts, so an unreadable property cannot cancel every swing.
                local gone = gunUtil.IsDestroyed(attacker)
                if not gone then
                    local readOk, health = pcall(function()
                        return attacker.Health
                    end)
                    gone = readOk and type(health) == "number" and health <= 0
                end
                if gone then
                    trace(("%s: sweep stopped at t=%.2f s: the attacker is gone or dead"):format(name, step.time))
                    break
                end
                local first = YAW_SIGN * step.yawFrom
                local second = YAW_SIGN * step.yawTo
                local loDeg, hiDeg = math.min(first, second), math.max(first, second)
                testedSteps = testedSteps + 1
                for _, record in ipairs(records) do
                    if not record.done then
                        local ok, err = pcall(testCandidate, record, step, frame, loDeg, hiDeg, rIn, rOut, ignore, tool, config, swing)
                        if not ok then
                            trace(("%s: test of %s failed: %s"):format(name, record.name, tostring(err)))
                        end
                    end
                end
            end
        end

        -- Per-target report. Far targets are only counted, so a busy map does not flood the output.
        local reported, skipped = 0, 0
        for _, record in ipairs(records) do
            if record.done or record.blockedAt ~= nil or record.minGap <= TRACE_GAP_LIMIT then
                reported = reported + 1
                local bodySize = "n/a"
                pcall(function()
                    bodySize = formatVector(record.target.Size)
                end)
                trace(("%s:   %s: %s | closest: %s | Dynamic.Size %s (traced only)"):format(
                    name, record.name, describeOutcome(record), record.closest, bodySize))
            else
                skipped = skipped + 1
            end
        end
        trace(("%s: sweep end: %d hit-tests, %d damaged, %d protected, %d candidates (%d reported, %d farther than %d studs)"):format(
            name, testedSteps, swing.damaged, swing.protected, #records, reported, skipped, TRACE_GAP_LIMIT))
    end

    remote.InvokedServer:Connect(function(sender, message)
        local senderName = "?"
        pcall(function()
            senderName = sender.Name
        end)
        trace(("request received from %s"):format(senderName))
        local tool = getTool(sender)
        if not tool then
            trace(("rejected: %s holds no Tool"):format(senderName))
            return
        end
        local name = toolName(tool)
        local config, reason = readConfig(tool)
        if config == nil then
            trace(("%s: rejected: %s"):format(name, reason))
            return
        end

        -- Read the whole request up front so the position trace shows which server position is live.
        local positions = readServerPositions(sender, tool)
        local posOk, clientPosition = pcall(function()
            return message:GetVector3("pos")
        end)
        if not posOk then
            clientPosition = nil
        end
        trace(("%s: positions: sender.Position %s, Character %s, held Tool Handle %s, client pos %s"):format(
            name, formatVector(positions.body), formatVector(positions.character), formatVector(positions.handle),
            clientPosition == nil and "missing" or formatVector(clientPosition)))

        local now = os.clock()
        local swingKey = senderName .. "|" .. name
        local previous = lastSwingAt[swingKey] or -math.huge
        if now - previous < config.cooldown * COOLDOWN_TOLERANCE then
            trace(("%s: rejected: server cooldown still running"):format(name))
            return
        end

        local dirOk, rawDirection = pcall(function()
            return message:GetVector3("dir")
        end)
        local direction = dirOk and flatten(rawDirection) or nil
        if direction == nil then
            trace(("%s: rejected: no usable 'dir' in the message (%s)"):format(name, dirOk and "vertical or zero" or tostring(rawDirection)))
            return
        end

        -- Attacker CHEST position: origin of the swept blade (height = blade height).
        local chest = nil
        if clientPosition ~= nil then
            local acceptedLabel, acceptedDistance, readable, summary = checkClientPosition(clientPosition, positions)
            if readable == 0 then
                trace(("%s: rejected: no server position of the attacker could be read"):format(name))
                return
            end
            if acceptedLabel == nil then
                trace(("%s: rejected: client pos is farther than %d studs from every server reference (%s)"):format(name, MAX_CLIENT_POSITION_DRIFT, summary))
                return
            end
            chest = clientPosition
            trace(("%s: client pos accepted against %s at %.1f studs (limit %d; all: %s)"):format(name, acceptedLabel, acceptedDistance, MAX_CLIENT_POSITION_DRIFT, summary))
        else
            local feet = positions.character or positions.body
            if feet == nil then
                trace(("%s: rejected: no 'pos' in the message and no server position could be read"):format(name))
                return
            end
            chest = feet + CHEST_OFFSET
            trace(("%s: no client pos, using the server %s %s"):format(name, positions.character and "Character position" or "sender.Position", formatVector(feet)))
        end

        lastSwingAt[swingKey] = now
        -- Attacking ends the spawn shield, exactly like firing a gun (WeaponServer).
        pcall(function()
            local shield = sender:FindChild("Protect")
            if shield then
                shield:Destroy()
            end
        end)
        trace(("%s: accepted swing, dir=(%.2f, %.2f)"):format(name, direction.X, direction.Z))

        -- Own body parts and the held Tool must not block the chest-to-body line of sight.
        local ignore = {sender, tool}
        pcall(function()
            local character = sender.Character
            if character ~= nil then
                table.insert(ignore, character)
            end
        end)

        -- The sweep yields (wait) between hit tests, so it runs in its own coroutine and never blocks the remote.
        coroutine.wrap(function()
            local ok, err = pcall(runSweep, sender, tool, config, direction, chest, ignore)
            if not ok then
                trace(("%s: sweep failed: %s"):format(name, tostring(err)))
            end
        end)()
    end)
    trace("server connected (Hidden/Remotes/Melee)")
end

return WeaponMeleeServer
