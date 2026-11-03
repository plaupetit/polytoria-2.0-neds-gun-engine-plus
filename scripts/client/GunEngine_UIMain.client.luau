-- GunEngine_UIMain is a presentation facade; WeaponHud derives values from the equipped Tool.
-- WeaponHud geometry and visible text are authored in Creator; this script only refreshes live values and handles the mode button.
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

local players = WaitChild(game, "Players")
local playerGui = WaitChild(game, "PlayerGUI")
local environment = WaitChild(game, "Environment")
local localPlayer = players.LocalPlayer
local mainUi = WaitChild(playerGui, "MainUI")
local cursor = WaitChild(mainUi, "Cursor")
local hud = WaitChild(mainUi, "WeaponHud")
local mag = WaitChild(hud, "Mag")
local ammo = WaitChild(hud, "Ammo")
local firemode = WaitChild(hud, "Firemode")
local firemodeCycleButton = WaitChild(hud, "FiremodeCycleButton")
local scriptService = WaitChild(game, "ScriptService")
local gunFramework = WaitChild(scriptService, "GunFramework")
local modules = WaitChild(gunFramework, "Modules")
local WeaponHud = require(WaitChild(modules, "WeaponHud"))
local WeaponFireModes = require(WaitChild(modules, "WeaponFireModes"))

-- The HUD button delegates to WeaponFireModes, so V and mouse clicks always use one state owner.
local function cycleFiremodeFromHud()
    local tool = WeaponHud.GetHeldTool(localPlayer)
    if WeaponHud.IsGunTool(tool) then
        WeaponFireModes.Cycle(tool)
    end
end

if firemodeCycleButton then
    firemodeCycleButton.Clicked:Connect(cycleFiremodeFromHud)
end

local function updateHud()
    local tool = WeaponHud.GetHeldTool(localPlayer)
    local visible = WeaponHud.IsGunTool(tool)

    -- Keep the HUD and its interactive button hidden between equips.
    hud.Visible = visible
    cursor.Visible = visible
    firemodeCycleButton.Visible = visible
    firemodeCycleButton.IgnoreMouse = not visible
    Input.CursorVisible = not visible
    if visible then
        mag.Text = WeaponHud.GetMagazineText(tool)
        ammo.Text = WeaponHud.GetReserveText(tool)
        firemode.Text = tool.Shared.firemodeText or ""
        local screenWidth = Input.ScreenWidth or 1920
        local screenHeight = Input.ScreenHeight or 1080
        local camera = environment.CurrentCamera
        if camera and camera.IsFirstPerson then
            -- First person and its camera ray share one explicit screen centre, independent of the locked native pointer.
            cursor.PositionOffset = Vector2.New(screenWidth * 0.5, screenHeight * 0.5)
        else
            -- Input uses a top-origin Y coordinate while this UI's positive Y axis points upward.
            -- Camera aiming keeps the converted free-cursor point in Client; only this presentation boundary follows the mouse.
            local mousePosition = Input.MousePosition
            if not Input.CursorLocked and mousePosition ~= nil then
                cursor.PositionOffset = Vector2.New(mousePosition.X, screenHeight - mousePosition.Y)
            end
        end
    end
end

-- Apply the initial hidden/equipped state, then refresh every Creator 2.0 frame.
updateHud()
Hooks.Updated:Connect(updateHud)