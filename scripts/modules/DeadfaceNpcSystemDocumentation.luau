-- DEADFACE + NPC RESPAWN SYSTEM DOCUMENTATION
-- Expected type: ModuleScript
-- Expected Creator path: world/ScriptService/DeadfaceNpcSystemDocumentation
-- Documentation-only module: it is not required by gameplay code.

-- REQUIRED SCENE REFERENCES
-- 1. world.Hidden.Remotes.DeadfaceSystem.Deadface : Image3D holding the deadface ImageAsset.
-- 2. world.ScriptService.OnDeadFace : ClientScript linked to scripts/client/OnDeadFace.client.luau.
-- 3. world.Environment : contains the top-level NPC instances watched by NpcRespawnController.
-- 4. world.ScriptService.NpcRespawnController : ServerScript linked to scripts/server/NpcRespawnController.server.luau.
--
-- REQUIRED API CONTRACTS
-- - PolytorianModel.FaceImage receives an ImageAsset, not a numeric ImageID.
-- - NPC.Died triggers the five-second delay; NPC:Respawn() rebuilds its character.
-- - NPC.Position and NPC.Rotation restore the original map transform after respawn.
-- - OnDeadFace stores a player's original FaceImage only when one exists, then restores it on Respawned.
--
-- NO WEAPON-SYSTEM DEPENDENCY
-- This system does not call GunFramework, ToolHandler, BulletTracer, or weapon remotes.

return {
    deadfaceAssetPath = "World/Hidden/Remotes/DeadfaceSystem/Deadface",
    deadfaceClientScriptPath = "World/ScriptService/OnDeadFace",
    npcContainerPath = "World/Environment",
    npcRespawnScriptPath = "World/ScriptService/NpcRespawnController",
    respawnDelaySeconds = 5,
}
