-- SCRIPT CONTEXT
-- Expected type: ClientScript
-- Expected Creator path: world/ScriptService/OnDeadFace
-- This cosmetic script changes faces locally; gameplay damage remains server-owned.

local players = game["Players"]
local workspace = game["Environment"]

local deadFaceTemplate = game["Hidden"]["Remotes"]["DeadfaceSystem"]["Deadface"]
local deadFaceImage = deadFaceTemplate ~= nil and deadFaceTemplate.Image or nil

local function getCharacterFaceTarget(player)
    -- FaceImage is an ImageAsset. Reuse the scene deadface asset instead of assigning a number.
    local character = player.Character
    if character == nil then
        return nil
    end
    return character
end

local function applyFaceImage(player, faceImage)
    local character = getCharacterFaceTarget(player)
    if character ~= nil and faceImage ~= nil then
        character.FaceImage = faceImage
    end
end

local function onSpawn(player)
    if not player:IsA("NPC") and not player:IsA("Player") then
        return
    end

    local character = getCharacterFaceTarget(player)
    if character ~= nil and player.Shared.faceImage == nil then
        player.Shared.faceImage = character.FaceImage
    end

    player.Died:Connect(function()
        applyFaceImage(player, deadFaceImage)
    end)

    if not player:IsA("Player") then
        return
    end

    player.Respawned:Connect(function()
        applyFaceImage(player, player.Shared.faceImage)
    end)
end

for _, player in pairs(players:GetPlayers()) do
    onSpawn(player)
end

players.PlayerAdded:Connect(onSpawn)

workspace.ChildAdded:Connect(function(instance)
    if instance:IsA("NPC") then
        onSpawn(instance)
    end
end)

for _, instance in pairs(workspace:GetChildren()) do
    if instance:IsA("NPC") then
        onSpawn(instance)
    end
end