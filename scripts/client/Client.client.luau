-- Client is the thin client facade (GunFramework/Client): it finds the modules, wires them together and
-- owns the network reply handler. Mutable weapon state lives on each Tool or its WeaponRuntime instance;
-- aim/cursor state lives in WeaponAim and hit feedback in WeaponHitmarker (both private to their instance).
-- Tool kinds (Config.kind): firearms run through WeaponRuntime + WeaponFire; "throwable" (Grenade) and "melee"
-- (Knife) are bound by WeaponRuntime to the optional WeaponThrowable / WeaponMelee modules injected below.
-- Their server replies (ThrowGrenade: HUD count + hitmarker, Melee: hitmarker) are handled at the bottom.
local SCRIPT_LABEL = script.Parent.Name .. "/" .. script.Name

-- TEMPORARY diagnostics switch (lot L4): prints "[Ned Gun:throwable]" / "[Ned Gun:melee]" lines for the kind
-- wiring (optional modules, reply handlers). Set to false once the Grenade and the Knife are confirmed in Play.
local DEBUG_WEAPON_KINDS = true
local function traceKind(kind, message)
    if DEBUG_WEAPON_KINDS then
        print(("[Ned Gun:%s] %s"):format(kind, message))
    end
end
local gunFrameworkFolder = script.Parent

-- Bootstrap only: GunUtil.WaitChild lives in a module, so a plain polling loop is needed to reach it.
local function bootstrapWaitChild(parent, childName)
    local found = parent:FindChild(childName)
    while found == nil do
        wait()
        found = parent:FindChild(childName)
    end
    return found
end

local modules = bootstrapWaitChild(gunFrameworkFolder, "Modules")
local GunUtil = require(bootstrapWaitChild(modules, "GunUtil"))

-- Keep the labelled infinite-yield warning that previously named this script.
local function WaitChild(parent, childName, duration)
    return GunUtil.WaitChild(parent, childName, duration, SCRIPT_LABEL)
end

local FindChildAndDoFunc = GunUtil.FindChildAndDoFunc

local workspace = game["Environment"]
local hidden = game["Hidden"]
local players = game["Players"]
local playerDefaults = game["PlayerDefaults"]
local playerGUI = game["PlayerGUI"]

local mainUI = WaitChild(playerGUI, "MainUI")
local cursor = WaitChild(mainUI, "Cursor")
local hitmarker = WaitChild(mainUI, "Hitmarker")

cursor.PositionOffset = Vector2.New()
cursor.PositionRelative = Vector2.New()

local localPlayer = players.LocalPlayer

local hitmarkerSound = WaitChild(gunFrameworkFolder, "Hitmarker")
local remotes = WaitChild(hidden, "Remotes")
local vfxs = WaitChild(gunFrameworkFolder, "VFXs")
local enum = require(WaitChild(gunFrameworkFolder, "Enum"))
local vfxsModel = WaitChild(workspace, "VFXs")

local WeaponConfig = require(WaitChild(modules, "WeaponConfig"))
local WeaponAmmo = require(WaitChild(modules, "WeaponAmmo"))
local WeaponFire = require(WaitChild(modules, "WeaponFire"))
local WeaponFireModes = require(WaitChild(modules, "WeaponFireModes"))
local WeaponRuntime = require(WaitChild(modules, "WeaponRuntime"))
local WeaponAim = require(WaitChild(modules, "WeaponAim"))
local WeaponHitmarker = require(WaitChild(modules, "WeaponHitmarker"))

-- Optional kind modules: bounded wait + pcall so a missing or broken module disables only the Grenade/Knife
-- (WeaponRuntime prints one line for the skipped Tool) and can never stop the firearms from loading.
local function requireOptional(moduleName)
    local moduleScript = WaitChild(modules, moduleName, 10)
    if moduleScript == nil then
        print(("[Ned Gun] Optional module %s is missing; its Tools will not work."):format(moduleName))
        return nil
    end
    local ok, result = pcall(function()
        return require(moduleScript)
    end)
    if not ok or type(result) ~= "table" then
        print(("[Ned Gun] Optional module %s failed to load: %s"):format(moduleName, tostring(result)))
        return nil
    end
    return result
end

local WeaponThrowable = requireOptional("WeaponThrowable")
local WeaponMelee = requireOptional("WeaponMelee")
traceKind("throwable", ("client module WeaponThrowable %s"):format(WeaponThrowable and "loaded" or "NOT loaded"))
traceKind("melee", ("client module WeaponMelee %s"):format(WeaponMelee and "loaded" or "NOT loaded"))

local ammoFormat = "%s / %s"
local defaultInventory = playerDefaults and playerDefaults:FindChild("Inventory")

-- AIM + CURSOR-FACING (see WeaponAim). Dependencies are injected; the module requires no siblings.
local aim = WeaponAim.New({
    localPlayer = localPlayer,
    workspace = workspace,
    input = Input,
    hooks = Hooks,
    weaponConfig = WeaponConfig,
    getEnums = function()
        -- ScriptService does not always inject Enums as a global, unlike Tool ClientScripts.
        local engineEnums = Enums
        if engineEnums == nil then
            pcall(function()
                engineEnums = game["Enums"]
            end)
        end
        return engineEnums
    end,
})

local function getAimScreenPosition()
    return aim:GetAimScreenPosition()
end

-- Returns (anyBound, preBound, postBound); the per-frame fallback below needs only the two flags.
local _, facingPreHookBound, facingPostHookBound = aim:BindHooks()

-- HITMARKER (see WeaponHitmarker)
local hitmarkerFeedback = WeaponHitmarker.New({
    mainUI = mainUI,
    cursor = cursor,
    hitmarker = hitmarker,
    hitmarkerSound = hitmarkerSound,
    workspace = workspace,
    tween = Tween,
    tweenType = TweenType,
    label = SCRIPT_LABEL,
})

local function playSound(sound)
    sound:Play()
end

local pumpDependencies = {
    findChildAndDoFunc = FindChildAndDoFunc,
    playSound = playSound,
}

local function checkPump(tool, handle)
    WeaponFire.CheckPump(tool, handle, pumpDependencies)
end

local shootSoundDependencies = {
    findChildAndDoFunc = FindChildAndDoFunc,
    playSound = playSound,
    checkPump = checkPump,
}

local function doShootSound(tool, handle, shootPos)
    WeaponFire.PlayShootSound(tool, handle, shootPos, shootSoundDependencies)
end

local function addAmmo(tool, amount)
    WeaponAmmo.Add(tool, amount, enum, ammoFormat)
end

local reloadDependencies = {
    enum = enum,
    ammoFormat = ammoFormat,
    findChildAndDoFunc = FindChildAndDoFunc,
    playSound = playSound,
    checkPump = checkPump,
    requestServerReload = function()
        -- Reload intent contains no client ammo value; WeaponServer owns the authoritative state.
        local message = NetMessage.New()
        message:AddBool("reload", true)
        remotes["CreateBullet"]:InvokeServer(message)
    end,
}

local fireDependencies = {
    localPlayer = localPlayer,
    workspace = workspace,
    vfxsModel = vfxsModel,
    input = Input,
    vfxs = vfxs,
    remotes = remotes,
    getAimScreenPosition = getAimScreenPosition,
    -- Shared bounded "!Ignore" raycast; WeaponFire keeps a local fallback if this is absent.
    raycastSkippingIgnored = GunUtil.RaycastSkippingIgnored,

    addAmmo = addAmmo,
    doShootSound = doShootSound,
}

-- Grenade input half (WeaponThrowable). getAim reuses the firearm cursor aim through WeaponFire.ComputeAim.
local throwableDependencies = {
    -- Injected because the Input global is not guaranteed inside a required ModuleScript.
    input = Input,
    workspace = workspace,
    remotes = remotes,
    getAim = function(tool, shootPos)
        return WeaponFire.ComputeAim(tool, shootPos, fireDependencies)
    end,
    addAmmo = addAmmo,
    findChildAndDoFunc = FindChildAndDoFunc,
    playSound = playSound,
}

-- Knife input half (WeaponMelee). The camera forward is the swing axis; the avatar forward covers a camera
-- that looks straight up or down.
local meleeDependencies = {
    remotes = remotes,
    getForward = function()
        local camera = workspace.CurrentCamera
        return camera and camera.Forward or nil
    end,
    getFallbackForward = function()
        return localPlayer.Forward
    end,
    isDestroyed = GunUtil.IsDestroyed,
    findChildAndDoFunc = FindChildAndDoFunc,
    playSound = playSound,
}

local runtime = WeaponRuntime.New({
    weaponConfig = WeaponConfig,
    weaponAmmo = WeaponAmmo,
    weaponFire = WeaponFire,
    fireModes = WeaponFireModes,
    defaultInventory = defaultInventory,
    waitChild = WaitChild,
    createBool = GunUtil.CreateBool,
    isDestroyed = GunUtil.IsDestroyed,
    enum = enum,
    ammoFormat = ammoFormat,
    reloadDependencies = reloadDependencies,
    fireDependencies = fireDependencies,
    checkPump = checkPump,
    weaponThrowable = WeaponThrowable,
    throwableDependencies = throwableDependencies,
    weaponMelee = WeaponMelee,
    meleeDependencies = meleeDependencies,
})

-- ToolClient calls this legacy spelling through Client:Call, so it remains the public compatibility entry point.
function initalize(tool)
    runtime:Initialize(tool)
end

script.Parent.Shared.initalized = true

-- Hooks.Updated is the Creator 2.0 update signal; legacy _Update does not advance the runtime.
Hooks.Updated:Connect(function()
    -- Cache the cursor every frame before a possible right-click lock.
    getAimScreenPosition()
    runtime:Update()
    -- Fallback for Creator sessions without PreRendered/PostRendered; never write a third yaw in normal sessions.
    if not (facingPreHookBound or facingPostHookBound) then
        aim:UpdateFacing()
    end
end)

WaitChild(remotes, "CreateBullet").InvokedClient:Connect(function(_, message)
    local sender = message:GetInstance("s")
    if sender == localPlayer then
        local heldTool = WeaponConfig.GetHeldTool(sender)
        local ammoOk, serverAmmo = pcall(function()
            return message:GetInt("serverAmmo")
        end)
        if heldTool and ammoOk and serverAmmo ~= nil then
            -- Reconcile the HUD with the server after every accepted shot.
            heldTool.Shared.ammo = serverAmmo
            WeaponAmmo.Update(heldTool, enum, ammoFormat)
        end
        -- Only display a hitmarker after the server accepted and applied character damage.
        local confirmedOk, hitConfirmed = pcall(function()
            return message:GetBool("hitConfirmed")
        end)
        if confirmedOk and hitConfirmed then
            hitmarkerFeedback:Show()
        end
    end

    local shootPos = message:GetInstance("o")
    local tool = WeaponConfig.GetHeldTool(sender)
    local handle = tool and tool:FindChild("Handle") or nil
    if sender ~= localPlayer and tool and handle and shootPos then
        coroutine.resume(coroutine.create(doShootSound), tool, handle, shootPos)
    end

    local shotCount = 0
    while true do
        shotCount = shotCount + 1
        local hitPosSuccess, hitPos = pcall(function()
            return message:GetVector3(tostring(shotCount))
        end)
        local normalSuccess, normal = pcall(function()
            return message:GetVector3("n" .. tostring(shotCount))
        end)
        local hitSuccess, hit = pcall(function()
            return message:GetInstance("h" .. tostring(shotCount))
        end)
        if not hitPosSuccess or not hitPos then
            break
        end
        if shootPos then
            -- Every client renders the server-approved endpoint, including the shooter.
            vfxs["BulletTracer"]:Call("start", shootPos.Position, hitPos, normal, hit)
        end
    end
end)

-- Server replies for the Grenade and the Knife. Looked up in their own coroutine with a bounded wait so a
-- missing remote can never delay the firearm handlers above. Accept both InvokedClient signatures
-- (sender, message) and (message), as the CreateBullet handler does.
local function connectKindReply(kind, remoteName, handler)
    coroutine.resume(coroutine.create(function()
        local remote = WaitChild(remotes, remoteName, 15)
        if remote == nil then
            print(("[Ned Gun] Hidden/Remotes/%s is missing; its server replies are ignored."):format(remoteName))
            traceKind(kind, ("reply handler NOT connected: Hidden/Remotes/%s not found after 15 s"):format(remoteName))
            return
        end
        remote.InvokedClient:Connect(function(first, second)
            local message = second or first
            if message == nil then
                traceKind(kind, ("%s reply ignored: empty message"):format(remoteName))
                return
            end
            traceKind(kind, ("%s reply received"):format(remoteName))
            local ok, err = pcall(handler, message)
            if not ok then
                print(("[Ned Gun] %s reply failed: %s"):format(remoteName, tostring(err)))
                traceKind(kind, ("%s reply handler failed: %s"):format(remoteName, tostring(err)))
            end
        end)
        traceKind(kind, ("reply handler connected (Hidden/Remotes/%s)"):format(remoteName))
    end))
end

local function showHitmarkerIfConfirmed(message)
    local confirmedOk, hitConfirmed = pcall(function()
        return message:GetBool("hitConfirmed")
    end)
    if confirmedOk and hitConfirmed == true then
        traceKind("hit", "hitConfirmed received: showing the hitmarker")
        hitmarkerFeedback:Show()
    end
end

-- ThrowGrenade reply {count, tool, hitConfirmed?}: sent right after the throw (or a rejection) and again after
-- the blast. The server count replaces the optimistic one; hitConfirmed (blast only) shows the hitmarker.
connectKindReply("throwable", "ThrowGrenade", function(message)
    local countOk, count = pcall(function()
        return message:GetInt("count")
    end)
    local toolOk, tool = pcall(function()
        return message:GetInstance("tool")
    end)
    if not toolOk or tool == nil then
        tool = WeaponConfig.GetHeldTool(localPlayer)
    end
    -- Skip a Tool destroyed since the reply was queued (its Shared table is cleared).
    local ackOk, ack = pcall(function() return message:GetInt("ack") end)
    local seqOk, seq = pcall(function() return message:GetInt("seq") end)
    if countOk and type(count) == "number" and tool ~= nil and not GunUtil.IsDestroyed(tool) and tool.Shared ~= nil then
        local shared = tool.Shared
        -- Ignore a reply that is not newer than the last applied one (out-of-order replies).
        local stale = seqOk and type(seq) == "number" and type(shared.grenadeReplySeq) == "number" and seq <= shared.grenadeReplySeq
        if not stale then
            if seqOk and type(seq) == "number" then
                shared.grenadeReplySeq = seq
            end
            -- Throws sent but not yet acknowledged are still optimistic: subtract them from the server count.
            local pending = 0
            if ackOk and type(ack) == "number" and type(shared.throwRid) == "number" then
                pending = math.max(0, shared.throwRid - ack)
            end
            shared.ammo = math.max(0, count - pending)
            WeaponAmmo.Update(tool, enum, ammoFormat)
        end
    end
    showHitmarkerIfConfirmed(message)
end)

-- Melee reply {hitConfirmed, tool}: sent only when the server damaged a target.
connectKindReply("melee", "Melee", showHitmarkerIfConfirmed)
