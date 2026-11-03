-- Server is a thin authority facade. WeaponServer keeps damage validation and replication server-side.
-- Tool kinds: firearms use WeaponServer (CreateBullet); the Grenade (kind "throwable") is served by
-- WeaponGrenadeServer on Hidden/Remotes/ThrowGrenade and the Knife (kind "melee") by WeaponMeleeServer on
-- Hidden/Remotes/Melee. Each optional module is loaded and connected in its own protected coroutine, so a
-- missing remote or a broken module can never take the firearm path down.
-- Diagnostics: DEBUG_WEAPON_KINDS (TEMPORARY, lot L4) prints "[Ned Gun:throwable]" / "[Ned Gun:melee]" lines for
-- every step of connectKindServer (waiting, module/remote lookup, require, connected). Set it to false once the
-- Grenade and the Knife are confirmed in Play.

-- TEMPORARY diagnostics switch (see above).
local DEBUG_WEAPON_KINDS = true
local function traceKind(kind, message)
    if DEBUG_WEAPON_KINDS then
        print(("[Ned Gun:%s] %s"):format(kind, message))
    end
end

-- Bootstrap only: GunUtil.WaitChild lives in a module, so a plain polling loop is needed to reach it.
local function bootstrapWaitChild(parent, childName)
    local found = parent:FindChild(childName)
    while found == nil do
        wait()
        found = parent:FindChild(childName)
    end
    return found
end

local gunFrameworkFolder = script.Parent
local modules = bootstrapWaitChild(gunFrameworkFolder, "Modules")
local GunUtil = require(bootstrapWaitChild(modules, "GunUtil"))

local hidden = game["Hidden"]
local remotes = GunUtil.WaitChild(hidden, "Remotes")
local WeaponServer = require(GunUtil.WaitChild(modules, "WeaponServer"))
local environment = game["Environment"]

-- GunUtil is passed as the optional 4th argument so WeaponServer shares the bounded "!Ignore" raycast.
WeaponServer.Connect(remotes, function(player)
    return player:FindChildByClass("Tool")
end, environment, GunUtil)

-- Optional kind modules. Dependencies are injected (modules never require each other); GunUtil carries the
-- shared damage-target helpers. Enums may be absent as a global in ScriptService scripts, so fall back to
-- game["Enums"] (WeaponGrenadeServer uses PartShape.Sphere only and tolerates nil).
local players = game["Players"]
local engineEnums = Enums
if engineEnums == nil then
    pcall(function()
        engineEnums = game["Enums"]
    end)
end

local function getHeldTool(player)
    return player:FindChildByClass("Tool")
end

local function connectKindServer(kind, moduleName, remoteName, dependencies)
    spawn(function()
        traceKind(kind, ("connecting %s to Hidden/Remotes/%s"):format(moduleName, remoteName))
        local moduleScript = GunUtil.WaitChild(modules, moduleName, 10)
        local remote = GunUtil.WaitChild(remotes, remoteName, 10)
        if moduleScript == nil or remote == nil then
            print(("[Ned Gun] %s not started: module %s, remote %s."):format(
                moduleName,
                moduleScript and "found" or "MISSING",
                remote and "found" or "MISSING"
            ))
            traceKind(kind, ("%s NOT started: module %s, remote %s"):format(
                moduleName,
                moduleScript and "found" or "MISSING",
                remote and "found" or "MISSING"
            ))
            return
        end
        local ok, err = pcall(function()
            require(moduleScript).Connect(remote, getHeldTool, environment, players, dependencies)
        end)
        if not ok then
            print(("[Ned Gun] %s failed to start: %s"):format(moduleName, tostring(err)))
            traceKind(kind, ("%s failed to start: %s"):format(moduleName, tostring(err)))
        end
    end)
end

connectKindServer("throwable", "WeaponGrenadeServer", "ThrowGrenade", { gunUtil = GunUtil, enums = engineEnums })
connectKindServer("melee", "WeaponMeleeServer", "Melee", { gunUtil = GunUtil })
