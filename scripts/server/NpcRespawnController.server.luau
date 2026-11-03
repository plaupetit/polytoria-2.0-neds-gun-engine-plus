-- NPC RESPAWN CONTROLLER
-- Expected type: ServerScript
-- Expected Creator path: world/ScriptService/NpcRespawnController
-- Rebinds all top-level Environment NPCs and restores their initial transform.

local environment = game["Environment"]
local respawnDelaySeconds = 5
local pendingRespawns = {}
local initialPositions = {}
local initialRotations = {}
local boundNpcs = {}

local function bindNpc(npc)
    if not npc:IsA("NPC") or boundNpcs[npc] then
        return
    end

    boundNpcs[npc] = true
    initialPositions[npc] = npc.Position
    initialRotations[npc] = npc.Rotation

    npc.Died:Connect(function()
        if pendingRespawns[npc] then
            return
        end

        pendingRespawns[npc] = true
        wait(respawnDelaySeconds)

        -- Respawn first so Creator rebuilds the character, then restore its map spawn.
        if npc.Parent ~= nil then
            npc:Respawn()
            npc.Position = initialPositions[npc]
            npc.Rotation = initialRotations[npc]
        end

        pendingRespawns[npc] = nil
    end)
end

for _, instance in pairs(environment:GetChildren()) do
    bindNpc(instance)
end

environment.ChildAdded:Connect(bindNpc)
