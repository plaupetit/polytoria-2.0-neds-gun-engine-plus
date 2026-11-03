-- WeaponAmmo owns only per-Tool ammunition arithmetic; no state is stored in this cached module.
local WeaponAmmo = {}

function WeaponAmmo.Update(tool, enum, ammoFormat)
    if tool.Shared.reloading == true and tool.Shared.reloadType ~= enum.ReloadType.Shell then
        tool.Shared.ammoText = "Reloading"
        return
    end

    local reserve = tool.Shared.limitedAmmo and tool.Shared.storedAmmo or tool.Shared.maxAmmo
    tool.Shared.ammoText = ammoFormat:format(tool.Shared.ammo, reserve)
end

function WeaponAmmo.Add(tool, amount, enum, ammoFormat)
    tool.Shared.ammo = tool.Shared.ammo + amount
    WeaponAmmo.Update(tool, enum, ammoFormat)
end

function WeaponAmmo.LoadShellFromReserve(tool, enum, ammoFormat)
    local magazineSpace = math.max(tool.Shared.maxAmmo - tool.Shared.ammo, 0)
    if magazineSpace <= 0 then
        return false
    end

    local reloadAmount = math.min(tool.Shared.reloadAdd or 1, magazineSpace)
    if tool.Shared.limitedAmmo then
        reloadAmount = math.min(reloadAmount, math.max(tool.Shared.storedAmmo, 0))
        if reloadAmount <= 0 then
            return false
        end
        tool.Shared.storedAmmo = tool.Shared.storedAmmo - reloadAmount
    end

    WeaponAmmo.Add(tool, reloadAmount, enum, ammoFormat)
    return true
end

function WeaponAmmo.Reload(tool, dependencies)
    local enum = dependencies.enum
    -- A new reload clears the previous interruption request before loading the next shell.
    tool.Shared.cancelShellReload = false
    tool.Shared.reloading = true
    -- The client requests a reload, but the server decides its real ammo and reload timing.
    dependencies.requestServerReload()

    if tool.Shared.reloadType == enum.ReloadType.Magazine then
        dependencies.findChildAndDoFunc(tool, "Handle", function(handle)
            dependencies.findChildAndDoFunc(handle, "Reload", dependencies.playSound)
        end)
        wait(tool.Shared.reloadTime or 3)

        if not tool.Shared.limitedAmmo then
            tool.Shared.ammo = tool.Shared.maxAmmo
        else
            -- Magazine reloads transfer existing reserve rounds only.
            local reloadAmount = math.min(
                math.max(tool.Shared.maxAmmo - tool.Shared.ammo, 0),
                math.max(tool.Shared.storedAmmo, 0)
            )
            tool.Shared.storedAmmo = tool.Shared.storedAmmo - reloadAmount
            WeaponAmmo.Add(tool, reloadAmount, enum, dependencies.ammoFormat)
        end

        tool.Shared.reloading = false
        WeaponAmmo.Update(tool, enum, dependencies.ammoFormat)
    end

    if tool.Shared.reloadType == enum.ReloadType.Shell then
        tool.Shared.loadTime = tool.Shared.loadTime or 0
        while true do
            if tool.Shared.cancelShellReload == true or tool.Shared.equipped == false or tool.Shared.ammo >= tool.Shared.maxAmmo then
                break
            end
            if os.clock() - tool.Shared.loadTime >= tool.Shared.reloadShellDelay then
                tool.Shared.loadTime = os.clock()
                if not WeaponAmmo.LoadShellFromReserve(tool, enum, dependencies.ammoFormat) then
                    break
                end
                dependencies.findChildAndDoFunc(tool, "Handle", function(handle)
                    dependencies.findChildAndDoFunc(handle, "Reload", dependencies.playSound)
                end)
                wait(tool.Shared.reloadShellDelay)
            end
            wait()
        end
        tool.Shared.reloading = false
        tool.Shared.cancelShellReload = false
        WeaponAmmo.Update(tool, enum, dependencies.ammoFormat)
    end

    dependencies.checkPump(tool, tool:FindChild("Handle"))
end

return WeaponAmmo
