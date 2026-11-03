-- WeaponHitmarker: client-only server-confirmed hit feedback (cloned HUD marker, arm pulse, hit sound).
-- Role: owns the authored MainUI/Hitmarker template set-up and the per-hit visual + audio effect.
-- Side: client only.
-- Dependencies (injected through WeaponHitmarker.New(deps), nothing is required from siblings):
--   mainUI, cursor, hitmarker (the authored template inside MainUI), hitmarkerSound (template Sound),
--   workspace (the Environment, parent of the temporary sound clone), tween (the Tween service),
--   tweenType (the TweenType enum table), label (text used in the missing-arm warning).
-- State: the generation token and the live clone are private to each New() instance. There is no
-- module-global mutable state.
-- How to test: in Play hit an NPC; four white arms must pulse outwards at the cursor and vanish within
-- about 0.22 s; two rapid hits must never leave a stale clone on screen.
local WeaponHitmarker = {}

local HITMARKER_Z_INDEX = 1000
local ARM_NAMES = {
    "HitmarkerArmTopRight",
    "HitmarkerArmBottomRight",
    "HitmarkerArmBottomLeft",
    "HitmarkerArmTopLeft",
}
local PULSE_OUT_DURATION = 0.06
local PULSE_BACK_DURATION = 0.10
local LIFETIME = 0.22
local SOUND_LIFETIME = 2
local ARM_SPREAD_RATIO = 0.20

local function captureTransform(view)
    return {
        positionOffset = view.PositionOffset,
        positionRelative = view.PositionRelative,
        pivotPoint = view.PivotPoint,
        sizeOffset = view.SizeOffset,
        sizeRelative = view.SizeRelative,
        rotation = view.Rotation,
    }
end

local function restoreTransform(view, state)
    view.PositionOffset = state.positionOffset
    view.PositionRelative = state.positionRelative
    view.PivotPoint = state.pivotPoint
    view.SizeOffset = state.sizeOffset
    view.SizeRelative = state.sizeRelative
    view.Rotation = state.rotation
end

local function setArmPosition(line, position)
    pcall(function()
        line.PositionOffset = position
    end)
end

function WeaponHitmarker.New(deps)
    local mainUI = deps.mainUI
    local cursor = deps.cursor
    local hitmarker = deps.hitmarker
    local hitmarkerSound = deps.hitmarkerSound
    local workspace = deps.workspace
    local tween = deps.tween
    local tweenType = deps.tweenType

    local instance = {}
    local hitmarkClone = nil
    local hitmarkGeneration = 0

    local function forEachArm(root, callback)
        -- The authored MainUI template owns arm geometry; code only controls visibility, layering and the brief pulse.
        for _, armName in ipairs(ARM_NAMES) do
            local arm = root:FindChild(armName)
            if arm and arm:IsA("UIView") then
                callback(arm)
            else
                print(("[%s]: Hitmarker arm '%s' is missing or is not a UIView."):format(tostring(deps.label), armName))
            end
        end
    end

    -- Keep server-confirmed hit feedback above local world cosmetics without changing the artist-authored transform.
    hitmarker.ZIndex = HITMARKER_Z_INDEX
    hitmarker.Visible = false
    forEachArm(hitmarker, function(arm)
        arm.ZIndex = HITMARKER_Z_INDEX + 1
        arm.Visible = false
        arm.Color = Color.New(1, 1, 1, 0)
        arm.BorderColor = Color.New(1, 1, 1, 0)
    end)

    local function placeAtCursor(currentHitmark)
        -- Cursor and Hitmarker share MainUI coordinates, so snapshot the visual aim point once at confirmed impact.
        -- Do not parent the marker to Cursor: its template pivot and arm pulse must stay independent of cursor transforms.
        currentHitmark.PositionOffset = cursor.PositionOffset
        currentHitmark.PositionRelative = cursor.PositionRelative
    end

    local function animateArm(line, state, generation, currentHitmark)
        local offset = state.positionOffset
        local distance = math.sqrt(offset.X * offset.X + offset.Y * offset.Y)
        if distance <= 0 then
            return
        end

        -- Direct arms no longer inherit a rotated group, so expand along their authored centre-to-arm vector.
        local direction = Vector2.New(offset.X / distance, offset.Y / distance)
        local spread = math.max(2, math.max(math.abs(offset.X), math.abs(offset.Y)) * ARM_SPREAD_RATIO)
        local expandedPosition = Vector2.New(offset.X + direction.X * spread, offset.Y + direction.Y * spread)

        tween:TweenVector2(offset, expandedPosition, PULSE_OUT_DURATION, function(value)
            setArmPosition(line, value)
        end, tweenType.linear, function()
            -- A newer hit (or its cleanup) supersedes this pulse; do not animate a stale clone back.
            if hitmarkGeneration ~= generation or hitmarkClone ~= currentHitmark then
                return
            end
            tween:TweenVector2(expandedPosition, offset, PULSE_BACK_DURATION, function(value)
                setArmPosition(line, value)
            end, tweenType.linear, function()
                setArmPosition(line, offset)
            end)
        end)
    end

    -- Shows one hitmarker pulse at the current cursor position. Call only after the server confirmed damage.
    function instance:Show()
        if hitmarkClone then
            hitmarkClone:Destroy()
        end

        hitmarkGeneration = hitmarkGeneration + 1
        local generation = hitmarkGeneration
        local hitmarkerSoundC = hitmarkerSound:Clone()
        hitmarkerSoundC.Parent = workspace
        hitmarkerSoundC:Play()
        hitmarkClone = hitmarker:Clone()
        local currentHitmark = hitmarkClone
        local rootState = captureTransform(currentHitmark)
        restoreTransform(currentHitmark, rootState)
        currentHitmark.ZIndex = HITMARKER_Z_INDEX
        currentHitmark.Visible = true
        -- The clone stays in MainUI, so it follows the visual aim point without inheriting Cursor transforms.
        currentHitmark.Parent = mainUI
        placeAtCursor(currentHitmark)

        forEachArm(currentHitmark, function(arm)
            local armState = captureTransform(arm)
            -- Do not hard-code arm size or rotation: preserve the artist-authored template across resolutions.
            restoreTransform(arm, armState)
            arm.ZIndex = HITMARKER_Z_INDEX + 1
            arm.Visible = true
            arm.BorderColor = Color.New(0, 0, 0, 0.2)
            arm.Color = Color.New(1, 1, 1, 1)
            animateArm(arm, armState, generation, currentHitmark)
        end)

        spawn(function()
            wait(LIFETIME)
            pcall(function()
                currentHitmark:Destroy()
            end)
            if hitmarkGeneration == generation then
                hitmarkClone = nil
            end
        end)
        spawn(function()
            -- Audio has its own lifetime and must not keep the visual clone alive for two seconds.
            wait(SOUND_LIFETIME)
            hitmarkerSoundC:Destroy()
        end)
    end

    return instance
end

return WeaponHitmarker
