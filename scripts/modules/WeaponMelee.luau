-- WeaponMelee: client-only input half of the Knife (Config kind = "melee").
-- Role: on Mouse0 press, checks the local cooldown, plays a cosmetic slash animation on the Handle and sends
--   Melee {dir, pos}, where dir is the camera forward flattened onto the horizontal plane and pos is the local
--   avatar's chest position (Players.LocalPlayer.Position + 1.2 up; optional, omitted when unreadable). The server
--   models the slash as a swept blade hitbox (see "Shared arc numbers" below) around `pos`, once `pos` passes the
--   server's drift check (the server replica of the attacker lags in local test), damages every Player/NPC body
--   the blade touches from ITS OWN target positions, rolls the damage and replies with hitConfirmed once per swing
--   (handled by Client, which shows the hitmarker).
-- Shared arc numbers (WeaponMeleeServer SLASH_YAW_KEYFRAMES must stay equal to the `ry` column of SLASH_KEYFRAMES
--   below; this file owns the look, the server owns the damage): yaw 0 -> -45 deg at 0.07 s (wind-up, not
--   damaging) -> +55 deg at 0.16 s (slash) -> 0 at 0.25 s (return), smoothstep eased; the blade reaches from 1.5
--   studs (hilt) to Config.bladeReach or Config.range (tip) from the chest. Positive yaw is assumed to swing to
--   the attacker's right; the server has a YAW_SIGN switch if Play shows the opposite. If you retime or widen the
--   animation here, change the server table in the same commit or the hitbox will no longer match the blade.
-- Side: client only.
-- Dependencies (passed to Bind as `dependencies`; nothing is required from siblings):
--   remotes            the Hidden/Remotes folder; Melee is looked up at press time,
--   getForward()       camera forward vector (Client wires workspace.CurrentCamera.Forward),
--   getFallbackForward()   optional; used when the camera looks straight up/down (Client wires the avatar forward),
--   getPosition()      optional chest position of the local avatar (default: Players.LocalPlayer.Position + 1.2 up),
--   isDestroyed(instance)  optional liveness probe (Client wires GunUtil.IsDestroyed); the animation also
--                      survives its absence through a protected GetParent read,
--   findChildAndDoFunc, playSound   optional "Swing" Sound on the Handle.
-- State: tool.Shared.lastSwing (per Tool) and one animation state table created inside Bind (per Tool);
--   no module-global mutable state.
-- Invariants: the client sends a direction and its own position only (never a target, range or damage); range,
--   cone, damage and cooldown are all re-checked by the server from its own Config, and `pos` is accepted only
--   within the server's drift limit of its own references.
-- Slash animation (client-only cosmetic): the Handle's LocalPosition/LocalRotation are driven through
--   SLASH_KEYFRAMES (wind-up, horizontal slash, return) by a short coroutine that yields with wait(), so it never
--   blocks input. The exact rest transform read at Bind is written back when the animation ends, is cancelled
--   (Unequipped) or fails; a destroyed Handle just stops the loop. Vector3 is read-only: every frame builds a
--   new value from the stored rest values.
-- Diagnostics: DEBUG_WEAPON_KINDS (TEMPORARY, lot L4) prints a "[Ned Gun:melee]" line at every early return,
--   pcall failure and request. Set it to false once the Knife is confirmed working in Play.
-- How to test: equip the Knife, click next to an NPC beside or in front of you: the blade sweeps across in about
--   0.25 s and the NPC is damaged when the blade passes through it (hitmarker once per swing); click twice within 0.45 s: only one swing is accepted; unequip mid-swing: the
--   blade is back at its rest pose.
local WeaponMelee = {}

-- TEMPORARY diagnostics switch (see header). Remove with the trace calls when the kind modules are stable.
local DEBUG_WEAPON_KINDS = true

local DEFAULT_COOLDOWN = 0.45
local MIN_FLAT_LENGTH = 0.0001
-- Mirrored in WeaponMeleeServer (CHEST_OFFSET): the server subtracts it to get back to feet level.
local CHEST_LIFT = Vector3.New(0, 1.2, 0)

-- "(x, y, z)" or "none" for traces; never throws.
local function formatVector(value)
    if value == nil then
        return "none"
    end
    local ok, text = pcall(function()
        return ("(%.1f, %.1f, %.1f)"):format(value.X, value.Y, value.Z)
    end)
    if ok then
        return text
    end
    return "unreadable"
end

-- Slash keyframes relative to the rest pose: {time (s), dx, dy, dz (studs), rx, ry, rz (degrees)}.
-- The blade points along +Z, so a yaw (ry) sweep moves its tip sideways: wind-up to one side, slash across to
-- the other with a short thrust, then return. Tune here; times must be strictly increasing from 0.
-- SHARED WITH THE SERVER HITBOX: the times and the `ry` column (0, -45, 55, 0) are mirrored in
-- WeaponMeleeServer SLASH_YAW_KEYFRAMES; the dx/dy/dz/rx/rz columns are cosmetic only.
local SLASH_KEYFRAMES = {
    {0.00, 0.00, 0.00, 0.00, 0, 0, 0},
    {0.07, -0.10, 0.05, -0.20, 10, -45, -20},
    {0.16, 0.12, -0.03, 0.30, -10, 55, 20},
    {0.25, 0.00, 0.00, 0.00, 0, 0, 0},
}
local SLASH_DURATION = SLASH_KEYFRAMES[#SLASH_KEYFRAMES][1]

local function trace(tool, message)
    if DEBUG_WEAPON_KINDS then
        local name = "?"
        pcall(function()
            name = tool.Name
        end)
        print(("[Ned Gun:melee] %s: %s"):format(name, message))
    end
end

-- Pure helper: horizontal unit vector of `forward`, or nil when it is (almost) vertical or missing.
function WeaponMelee.FlattenDirection(forward)
    if forward == nil then
        return nil
    end
    local flat = Vector3.New(forward.X, 0, forward.Z)
    if flat.Magnitude <= MIN_FLAT_LENGTH then
        return nil
    end
    return flat.Normalized
end

-- Pure helper: pose offsets {dx, dy, dz, rx, ry, rz} at `elapsed` seconds, eased between keyframes.
-- Clamps to the first/last keyframe outside the timeline.
function WeaponMelee.SampleSlash(elapsed)
    local frames = SLASH_KEYFRAMES
    if elapsed <= frames[1][1] then
        return {frames[1][2], frames[1][3], frames[1][4], frames[1][5], frames[1][6], frames[1][7]}
    end
    for index = 2, #frames do
        local nextFrame = frames[index]
        if elapsed <= nextFrame[1] then
            local previous = frames[index - 1]
            local span = nextFrame[1] - previous[1]
            local t = span > 0 and (elapsed - previous[1]) / span or 1
            -- Smoothstep so the blade accelerates out of the wind-up and settles into the return.
            t = t * t * (3 - 2 * t)
            local result = {}
            for slot = 2, 7 do
                result[slot - 1] = previous[slot] + (nextFrame[slot] - previous[slot]) * t
            end
            return result
        end
    end
    local last = frames[#frames]
    return {last[2], last[3], last[4], last[5], last[6], last[7]}
end

function WeaponMelee.Bind(tool, handle, mouse0, dependencies)
    local shared = tool.Shared
    shared.lastSwing = -1000
    local warnedMissingRemote = false

    -- Animation state for this Tool. `token` invalidates a running animation (Unequipped, a newer swing).
    local animation = { token = 0, running = false, disabled = false, restPosition = nil, restRotation = nil }
    if handle ~= nil then
        local restOk, restError = pcall(function()
            animation.restPosition = handle.LocalPosition
            animation.restRotation = handle.LocalRotation
        end)
        if not restOk or animation.restPosition == nil or animation.restRotation == nil then
            animation.disabled = true
            trace(tool, ("slash animation disabled: cannot read the Handle rest pose (%s)"):format(tostring(restError)))
        end
    else
        animation.disabled = true
        trace(tool, "slash animation disabled: the Tool has no Handle")
    end
    trace(tool, ("bound (animation %s)"):format(animation.disabled and "off" or "on"))

    -- Writes the exact rest transform back (the stored values are the engine's own, never recomputed).
    local function restoreRestPose()
        if animation.restPosition == nil or animation.restRotation == nil then
            return
        end
        local ok, err = pcall(function()
            handle.LocalPosition = animation.restPosition
            handle.LocalRotation = animation.restRotation
        end)
        if not ok then
            trace(tool, ("rest pose restore failed: %s"):format(tostring(err)))
        end
    end

    local function handleIsGone()
        if dependencies.isDestroyed ~= nil then
            return dependencies.isDestroyed(handle)
        end
        return not pcall(function()
            return handle:GetParent()
        end)
    end

    local function playSlash()
        if animation.disabled or animation.running then
            return
        end
        animation.running = true
        animation.token = animation.token + 1
        local token = animation.token
        coroutine.resume(coroutine.create(function()
            local ok, err = pcall(function()
                local startedAt = os.clock()
                while animation.token == token do
                    local elapsed = os.clock() - startedAt
                    if elapsed >= SLASH_DURATION or handleIsGone() then
                        break
                    end
                    local pose = WeaponMelee.SampleSlash(elapsed)
                    handle.LocalPosition = Vector3.New(
                        animation.restPosition.X + pose[1],
                        animation.restPosition.Y + pose[2],
                        animation.restPosition.Z + pose[3]
                    )
                    handle.LocalRotation = Vector3.New(
                        animation.restRotation.X + pose[4],
                        animation.restRotation.Y + pose[5],
                        animation.restRotation.Z + pose[6]
                    )
                    wait()
                end
            end)
            if not ok then
                -- A cosmetic failure must never repeat every swing: disable it and say why.
                animation.disabled = true
                print(("[Ned Gun:melee] %s: slash animation failed and is disabled: %s"):format(tostring(tool.Name), tostring(err)))
            end
            -- Only the animation that still owns the token restores here; Unequipped restores for a cancelled one.
            if animation.token == token then
                restoreRestPose()
                animation.running = false
            end
        end))
    end

    -- Unequipped mid-swing: cancel the animation and leave the Handle exactly at rest.
    tool.Unequipped:Connect(function()
        animation.token = animation.token + 1
        animation.running = false
        restoreRestPose()
    end)

    -- Chest position of the local avatar (feet position + CHEST_LIFT), or nil when it cannot be read.
    -- dependencies.getPosition() may override it; the default reads Players.LocalPlayer.
    local function getAttackerPosition()
        local position = nil
        local ok, err = pcall(function()
            if dependencies.getPosition ~= nil then
                position = dependencies.getPosition()
            else
                position = game["Players"].LocalPlayer.Position + CHEST_LIFT
            end
        end)
        if not ok then
            trace(tool, ("attacker position unreadable (the swing is sent without 'pos'): %s"):format(tostring(err)))
            return nil
        end
        return position
    end

    local onPress
    local swingQueued = false

    local function onPressBody()
        local now = os.clock()
        local remaining = (shared.cooldown or DEFAULT_COOLDOWN) - (now - shared.lastSwing)
        if remaining > 0 then
            -- Input buffer: a click during the cooldown is not lost, it swings as soon as the cooldown ends
            -- (one queued swing at most), so spamming feels responsive instead of silently dropping clicks.
            if not swingQueued then
                swingQueued = true
                trace(tool, ("cooldown running, swing queued in %.2f s"):format(remaining))
                coroutine.wrap(function()
                    wait(remaining)
                    swingQueued = false
                    if shared.equipped == false then
                        return
                    end
                    local ok, err = pcall(onPress)
                    if not ok then
                        print(("[Ned Gun:melee] %s: queued swing failed: %s"):format(tostring(tool.Name), tostring(err)))
                    end
                end)()
            end
            return
        end
        -- The swing is accepted locally from here: the cooldown starts and the blade moves, whatever the server says.
        shared.lastSwing = now
        playSlash()

        local remote = dependencies.remotes:FindChild("Melee")
        if remote == nil then
            if not warnedMissingRemote then
                warnedMissingRemote = true
                print("[Ned Gun] Hidden/Remotes/Melee is missing; the knife cannot swing.")
            end
            trace(tool, "rejected: Hidden/Remotes/Melee not found")
            return
        end

        local direction = WeaponMelee.FlattenDirection(dependencies.getForward())
        if direction == nil and dependencies.getFallbackForward then
            direction = WeaponMelee.FlattenDirection(dependencies.getFallbackForward())
        end
        if direction == nil then
            trace(tool, "rejected: no usable horizontal direction (camera and avatar forward are missing or vertical)")
            return
        end

        local message = NetMessage.New()
        message:AddVector3("dir", direction)
        -- The server's replica of this player lags the live avatar (50..95 studs in local test), so the swing
        -- carries the client's own chest position; the server range-checks it against its own references.
        local position = getAttackerPosition()
        if position ~= nil then
            message:AddVector3("pos", position)
        end
        remote:InvokeServer(message)
        trace(tool, ("request sent (Melee) dir=(%.2f, %.2f), pos %s"):format(direction.X, direction.Z, formatVector(position)))

        dependencies.findChildAndDoFunc(handle, "Swing", dependencies.playSound)
    end

    onPress = function()
        trace(tool, "Mouse0 press received")
        onPressBody()
    end

    mouse0.Changed:Connect(function()
        if mouse0.Value ~= true then
            return
        end
        -- A failure must be visible, never swallowed: print the error text and keep the connection alive.
        local ok, err = pcall(onPress)
        if not ok then
            print(("[Ned Gun:melee] %s: press handler failed: %s"):format(tostring(tool.Name), tostring(err)))
        end
    end)
end

return WeaponMelee
