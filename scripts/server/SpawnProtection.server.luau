local protect = game['Hidden']['Protect']
local SHIELD_SECONDS = 3

game['Players'].PlayerAdded:Connect(function(player)
    local shield
    -- Generation token: each respawn bumps it, so an older delayed cleanup can tell it was superseded
    -- and must not destroy the newer shield (respawn faster than SHIELD_SECONDS).
    local generation = 0
    local function respawn()
        generation = generation + 1
        local myGeneration = generation
        pcall(function()
            if shield then
                shield:Destroy()
            end
        end)
        local myShield = protect:Clone()
        shield = myShield
        myShield.Parent = player
        myShield.LocalPosition = Vector3.New()
        myShield.LocalRotation = Vector3.New()
        wait(SHIELD_SECONDS)
        if generation ~= myGeneration then
            return
        end
        -- WeaponServer may already have destroyed "Protect" on the first shot, so the Destroy can throw.
        pcall(function()
            myShield:Destroy()
        end)
    end
    spawn(respawn)
    player.Respawned:Connect(respawn)
end)
