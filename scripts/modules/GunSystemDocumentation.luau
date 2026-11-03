-- NED GUN SYSTEM - PUBLIC UNCOPYLOCKED DOCUMENTATION
-- Expected type: ModuleScript
-- Expected Creator path: world/ScriptService/GunSystemDocumentation
-- This module is documentation only. Nothing needs to require it for weapons to work.

-- START HERE
-- This project has three weapon templates: Pistol, Rifle, and Shotgun.
-- The templates are copied from PlayerDefaults/Inventory to players at spawn.
-- Do not move a referenced child without updating every script that reads it.

-- CORE HIERARCHY
-- world.ScriptService.GunFramework
--   Scripts : client scripts. ToolHandler = keyboard/mouse input routing only (flips the Tool's BoolValues).
--   Client / Server : the client and server facades that wire the modules together.
--   Modules : reusable weapon data/runtime code (10 modules, listed below).
--   VFXs    : cosmetic client scripts, including BulletTracer.
-- world.PlayerDefaults.Inventory
--   Pistol, Rifle, Shotgun : Tool templates.
--   Each Tool needs Handle, ToolClient, ToolServer, and Config.
--   Handle/ShootPos marks the firing origin; ShootPos/Fire is the fire sound.
-- world.Environment
--   VFXs is the client cosmetic parent used by BulletTracer.
--   NPC, NPC3, NPC5, and NPC7 are top-level practice NPC examples.
-- world.PlayerGUI.MainUI
--   WeaponHud and Hitmarker are the cosmetic HUD references.

-- REQUIRED LINKS
-- Client gun entrypoint: ScriptService/GunFramework/Client (facade). ToolClient calls Client:Call("initalize", tool).
--   ToolHandler (Scripts/ToolHandler) is NOT the entrypoint: it only routes keyboard/mouse input.
-- Server gun entrypoint: ScriptService/GunFramework/Server (facade) -> Modules/WeaponServer.Connect.
-- Weapon Config: PlayerDefaults/Inventory/<Tool>/Config.
-- Tool scripts: PlayerDefaults/Inventory/<Tool>/ToolClient and ToolServer.
-- Bullet VFX: ScriptService/GunFramework/VFXs/BulletTracer.
-- Projectile origin: PlayerDefaults/Inventory/<Tool>/Handle/ShootPos.
-- Ignore rules: a world Part can contain a Folder named !Ignore.
--
-- DEADFACE + NPC ADDITIONS
-- Deadface image asset: Hidden/Remotes/DeadfaceSystem/Deadface.
-- Death-face client script: ScriptService/OnDeadFace.
-- NPC respawn server script: ScriptService/NpcRespawnController.
-- NPC respawn waits five seconds, calls NPC:Respawn(), then restores initial Position and Rotation.

-- MODULES (ScriptService/GunFramework/Modules)
-- 1. GunUtil          : WaitChild, FindChildAndDoFunc, IsDestroyed, CreateBool, bounded "!Ignore" raycast (client + server).
-- 2. WeaponAim        : factory; cursor aim position, self-aim ghost, cursor-facing rotation (client).
-- 3. WeaponHitmarker  : factory; server-confirmed hitmarker pulse and sound (client).
-- 4. WeaponAmmo       : ammo/HUD text and reload helpers.
-- 5. WeaponConfig     : per-Tool Config resolution and held-Tool lookup.
-- 6. WeaponFire       : fire gate, aim direction, CreateBullet request, shoot sound.
-- 7. WeaponFireModes  : SEMI/AUTO fire-mode state and cycling.
-- 8. WeaponRuntime    : per-Tool controller (input BoolValues, update loop).
-- 9. WeaponServer     : server authority (ammo, reload, ray validation, damage). Hits are never trusted from clients.
-- 10. WeaponHud       : HUD ammo/fire-mode text and visibility, used by Scripts/GunEngine_UIMain.
-- Modules receive their dependencies through factory/function arguments; they do not require each other.
-- Data modules live elsewhere: GunFramework/Enum, GunFramework/Config, and one Config per Tool template.
--
-- DEBUG SCRIPTS
-- GunAimNetworkDebug (client) and GunAimNetworkServerDebug (server) ship with DEBUG_ENABLED = false.
-- Set it to true only while diagnosing cursor-to-server shot drift, then switch it off again.

-- SAFE EDITING RULES
-- 1. Keep scripts client, server, and module scoped to their existing side.
-- 2. Change one Config at a time; firemode arrays use false=SEMI and true=AUTO.
-- 3. Do not leave template Particles emitting: BulletTracer manages VFX at runtime.
-- 4. Keep Deadface as an Image3D asset source; FaceImage needs an ImageAsset, never a number.
-- 5. Play-test after moving hierarchy references or changing Config/Tool links.

return {
    title = "Ned Gun System Documentation",
    tools = { "Pistol", "Rifle", "Shotgun" },
    rootPaths = {
        gunFramework = "World/ScriptService/GunFramework",
        inventory = "World/PlayerDefaults/Inventory",
        environment = "World/Environment",
        hud = "World/PlayerGUI/MainUI",
    },
    supportSystems = {
        deadface = "World/Hidden/Remotes/DeadfaceSystem/Deadface",
        npcRespawn = "World/ScriptService/NpcRespawnController",
    },
}
