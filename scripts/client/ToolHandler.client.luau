-- ToolHandler is keyboard/mouse input routing only: it flips the BoolValues (Mouse0, R, V, ...) that
-- WeaponRuntime listens to on the equipped Tool. It no longer owns an ignore list or draws tracers
-- (BulletTracer does); every helper is local so nothing leaks into the script environment.

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
        if found ~= nil then
            return found
        elseif duration ~= nil and timer >= duration then
            break
        elseif duration == nil and not warned and timer > 5 then
            print(("Infinite yield on WaitChild(%s, %s)"):format(parent.Name, childName))
            warned = true
        end
    until found
    return found
end

local function FindChildAndDoFunc(parent, childName, func)
    local child = parent:FindChild(childName)
    if not child then
        return
    end
    func(child)
end

local players = WaitChild(game, "Players")
local localPlayer = players.LocalPlayer

local function setBoolToTrue(bool)
    bool.Value = true
end

local function setBoolToFalse(bool)
    bool.Value = false
end

local function getTool()
    return localPlayer:FindChildByClass("Tool")
end

-- UI input is not weapon input: Mouse0 over the HUD mode button must not reach the equipped Tool.
local function isPointerOverFiremodeButton()
    local playerGui = game:FindChild("PlayerGUI")
    local mainUi = playerGui and playerGui:FindChild("MainUI")
    local weaponHud = mainUi and mainUi:FindChild("WeaponHud")
    local button = weaponHud and weaponHud:FindChild("FiremodeCycleButton")
    if button == nil or button.IgnoreMouse or not button.IsVisibleInTree then
        return false
    end

    local pointer = Input.MousePosition
    local position = button.AbsolutePosition
    local size = button.AbsoluteSize
    local screenHeight = Input.ScreenHeight
    if pointer == nil or position == nil or size == nil or screenHeight == nil then
        return false
    end

    -- Input is top-origin, while HUD coordinates use a bottom-origin Y axis.
    local pointerY = screenHeight - pointer.Y
    return pointer.X >= position.X and pointer.X <= position.X + size.X
        and pointerY >= position.Y and pointerY <= position.Y + size.Y
end

Input.KeyDown:Connect(function(key)
    local tool = getTool()
    if tool then
        if key == "Mouse0" and isPointerOverFiremodeButton() then
            return
        end
        FindChildAndDoFunc(tool, key, setBoolToTrue)
    end
end)
Input.KeyUp:Connect(function(key)
    local tool = getTool()
    if tool then
        FindChildAndDoFunc(tool, key, setBoolToFalse)
    end
end)
