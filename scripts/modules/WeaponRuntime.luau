-- WeaponRuntime creates one local controller and keeps the mutable registry private to that controller instance.
-- Role: per-Tool client bootstrap (ToolClient -> Client -> runtime:Initialize) and the per-frame update loop.
-- Side: client only. Nothing is required from sibling modules; Client injects every collaborator.
-- Routing: Initialize reads Config.kind (copied to tool.Shared.kind by WeaponConfig.Apply):
--   nil / "firearm"  fire modes, reload, spin-up and the per-frame Fire loop (this file),
--   "throwable"      dependencies.weaponThrowable.Bind(tool, handle, shootPos, mouse0, throwableDependencies),
--   "melee"          dependencies.weaponMelee.Bind(tool, handle, mouse0, meleeDependencies).
--   Throwables and melee Tools never touch fire modes, reload or WeaponFire, so the firearm validation
--   message can never be printed for them.
-- Optional dependencies: weaponThrowable / throwableDependencies / weaponMelee / meleeDependencies (a missing
--   module prints one line and skips that Tool; firearms are unaffected).
-- Muzzle: firearms and the Minigun wait for Handle/ShootPos; the Grenade waits at most SHOOTPOS_WAIT_SECONDS for
--   an optional one (a Grenade template owns no muzzle, and an unbounded wait used to stop Initialize before
--   Mouse0 existed, so clicking did nothing); the Knife never waits.
-- Diagnostics: DEBUG_WEAPON_KINDS (TEMPORARY, lot L4) prints "[Ned Gun:runtime]" lines for the Initialize flow of
--   every Tool (start, config, kind, muzzle, early returns). Set it to false once Grenade/Knife are confirmed.
-- State: weapons[tool] registry (private to the controller); per-Tool state lives on tool.Shared.
-- Invariants: the update closure never depends on tool.Shared.equipped (Equipped can fire before Initialize
--   connects it); Mouse0 is cleared on Unequipped, so wishfire alone gates spin-up and fire. Cosmetic barrel
--   spin failures are caught and can never abort initialisation or the update loop.
-- How to test: Play with every Tool: Rifle/Pistol/Shotgun/Sniper fire, Minigun spins ~0.6 s then fires,
--   Grenade throws, Knife stabs; the Output shows no "fire modes are invalid" line for Grenade/Knife.
local WeaponRuntime = {}

-- TEMPORARY diagnostics switch (see header). Remove with the trace calls when the kind modules are stable.
local DEBUG_WEAPON_KINDS = true

-- Longest wait for an optional muzzle (Grenade). Replication normally delivers it within a frame or two.
local SHOOTPOS_WAIT_SECONDS = 3

local function trace(tool, message)
    if DEBUG_WEAPON_KINDS then
        local name = "?"
        pcall(function()
            name = tool.Name
        end)
        print(("[Ned Gun:runtime] %s: %s"):format(name, message))
    end
end

-- Visual barrel spin for Tools whose Config sets spinUpTime (Minigun). Client-only cosmetics.
local SPIN_MAX_REVS = 6 -- revolutions per second at full speed; higher rates strobe at 60 fps
local SPIN_DOWN_TIME = 1.2 -- seconds from full speed to rest after Mouse0 is released

-- Collects Handle children named Barrel<n> and records each one's angle around the Spindle axis (+Z),
-- so the cluster can be re-placed by angle every frame without RotateAround direction ambiguity.
-- The Spindle is found by scanning GetChildren (no FindChild dependency); callers wrap this in pcall.
local function createBarrelSpin(handle)
    local spindle = nil
    local barrels = {}
    local sumX, sumY = 0, 0
    for _, child in ipairs(handle:GetChildren()) do
        if child.Name == "Spindle" then
            spindle = child
        elseif string.match(child.Name, "^Barrel%d+$") then
            table.insert(barrels, {part = child, base = child.LocalPosition})
            sumX = sumX + child.LocalPosition.X
            sumY = sumY + child.LocalPosition.Y
        end
    end
    if #barrels == 0 then
        return nil
    end
    local centerX = spindle and spindle.LocalPosition.X or sumX / #barrels
    local centerY = spindle and spindle.LocalPosition.Y or sumY / #barrels
    for _, barrel in ipairs(barrels) do
        local dx, dy = barrel.base.X - centerX, barrel.base.Y - centerY
        barrel.radius = math.sqrt(dx * dx + dy * dy)
        barrel.phase = math.atan2(dy, dx)
    end
    return {barrels = barrels, centerX = centerX, centerY = centerY, angle = 0, rate = 0}
end

local function stepBarrelSpin(spin, spinning, spinUpTime, dt)
    local maxRate = SPIN_MAX_REVS * 2 * math.pi
    if spinning then
        spin.rate = math.min(maxRate, spin.rate + maxRate / math.max(spinUpTime, 0.05) * dt)
    else
        spin.rate = math.max(0, spin.rate - maxRate / SPIN_DOWN_TIME * dt)
    end
    if spin.rate <= 0 then
        return
    end
    spin.angle = (spin.angle + spin.rate * dt) % (2 * math.pi)
    for _, barrel in ipairs(spin.barrels) do
        local a = barrel.phase + spin.angle
        barrel.part.LocalPosition = Vector3.New(
            spin.centerX + barrel.radius * math.cos(a),
            spin.centerY + barrel.radius * math.sin(a),
            barrel.base.Z
        )
    end
end

function WeaponRuntime.New(dependencies)
    local weapons = {}
    local runtime = {}

    function runtime:Initialize(tool)
        -- ToolClient can be invoked more than once by legacy replication; bind one controller per Tool.
        if weapons[tool] ~= nil then
            trace(tool, "Initialize skipped: already initialized")
            return
        end
        trace(tool, "Initialize called")

        local data = dependencies.weaponConfig.Resolve(tool, dependencies.defaultInventory)
        if data == nil then
            trace(tool, "Initialize stopped: no Config module could be required (template or Tool)")
            return
        end

        -- Configs written before `kind` existed (Config2..4) are firearms.
        local kind = data.kind or "firearm"
        trace(tool, ("Config resolved, kind = %s"):format(tostring(kind)))
        if kind ~= "firearm" and kind ~= "throwable" and kind ~= "melee" then
            print(("[Ned Gun] %s has unknown Config.kind '%s'; initialization skipped."):format(tool.Name, tostring(kind)))
            return
        end
        -- A missing optional module skips only this Tool; it must never fall through to the firearm path.
        if kind == "throwable" and (dependencies.weaponThrowable == nil or dependencies.throwableDependencies == nil) then
            print(("[Ned Gun] %s needs the WeaponThrowable module; initialization skipped."):format(tool.Name))
            return
        end
        if kind == "melee" and (dependencies.weaponMelee == nil or dependencies.meleeDependencies == nil) then
            print(("[Ned Gun] %s needs the WeaponMelee module; initialization skipped."):format(tool.Name))
            return
        end

        local handle = dependencies.waitChild(tool, "Handle")
        -- The Knife has no muzzle and the Grenade may not own one: never wait forever for a ShootPos.
        local shootPos = nil
        if kind == "melee" then
            shootPos = handle:FindChild("ShootPos")
        elseif kind == "throwable" then
            shootPos = dependencies.waitChild(handle, "ShootPos", SHOOTPOS_WAIT_SECONDS)
        else
            shootPos = dependencies.waitChild(handle, "ShootPos")
        end
        trace(tool, ("Handle found, ShootPos %s"):format(shootPos and "found" or "not present"))
        local mouse0 = dependencies.createBool("Mouse0", tool)
        local rKey = dependencies.createBool("R", tool)
        local vKey = dependencies.createBool("V", tool)

        dependencies.weaponConfig.Apply(tool, data)

        if kind ~= "firearm" then
            -- Throwable / melee: input half only. No fire modes, reload or WeaponFire (see header).
            dependencies.weaponAmmo.Update(tool, dependencies.enum, dependencies.ammoFormat)
            -- A Bind failure must be visible and must not leave the Tool half-registered.
            local bindOk, bindError = pcall(function()
                if kind == "throwable" then
                    dependencies.weaponThrowable.Bind(tool, handle, shootPos, mouse0, dependencies.throwableDependencies)
                else
                    dependencies.weaponMelee.Bind(tool, handle, mouse0, dependencies.meleeDependencies)
                end
            end)
            if not bindOk then
                print(("[Ned Gun:runtime] %s: %s Bind failed: %s"):format(tostring(tool.Name), kind, tostring(bindError)))
                return
            end
            trace(tool, ("%s input bound, Mouse0 BoolValue ready"):format(kind))
            tool.Unequipped:Connect(function()
                tool.Shared.equipped = false
                mouse0.Value = false
                rKey.Value = false
                vKey.Value = false
            end)
            -- No per-frame work, but the registry entry keeps Initialize idempotent and drops destroyed Tools.
            weapons[tool] = function() end
            return
        end

        local modesOk, modesOrReason = dependencies.fireModes.Initialize(tool)
        if not modesOk then
            print(("[Ned Gun] %s fire modes are invalid; initialization skipped: %s"):format(tool.Name, modesOrReason))
            return
        end

        local spinUpTime = tonumber(tool.Shared.spinUpTime)
        local barrelSpin = nil
        if spinUpTime ~= nil then
            -- Cosmetic only: any failure here must not abort initialisation (the gun still fires without spin).
            local spinOk, spinResult = pcall(createBarrelSpin, handle)
            if spinOk then
                barrelSpin = spinResult
            else
                print(("[Ned Gun] Minigun barrel spin disabled: %s"):format(tostring(spinResult)))
            end
        end
        local lastTick = os.clock()

        rKey.Changed:Connect(function()
            if not rKey.Value or tool.Shared.reloading or tool.Shared.ammo == tool.Shared.maxAmmo or (tool.Shared.limitedAmmo and tool.Shared.storedAmmo <= 0) then
                return
            end
            dependencies.weaponAmmo.Reload(tool, dependencies.reloadDependencies)
        end)

        vKey.Changed:Connect(function()
            if not vKey.Value then
                return
            end
            local changed, firemode, index, reason = dependencies.fireModes.Cycle(tool)
            if reason ~= nil then
                print(("[Ned Gun] %s fire-mode switch skipped: %s"):format(tool.Name, reason))
                return
            end
            tool.Shared.firemodeText = dependencies.fireModes.GetText(firemode)
            if changed then
                print(("[Ned Gun] %s fire mode %d/%d: %s"):format(
                    tool.Name,
                    index,
                    #tool.Shared.firemodes,
                    tool.Shared.firemodeText
                ))
            end
        end)

        mouse0.Changed:Connect(function()
            -- A loaded shell can be fired immediately; stop only the shell-by-shell reload loop.
            if mouse0.Value == true and tool.Shared.reloading == true
                and tool.Shared.reloadType == dependencies.enum.ReloadType.Shell
                and tool.Shared.ammo > 0 then
                tool.Shared.cancelShellReload = true
            end
            if dependencies.weaponFire.CanFire(tool) then
                tool.Shared.canfire = true
            end
            tool.Shared.wishfire = mouse0.Value
            if mouse0.Value == true then
                tool.Shared.spinStartedAt = os.clock()
                -- Spin-up weapons fire from the update tick once spinUpTime has elapsed (Config6 contract).
                if spinUpTime == nil then
                    dependencies.weaponFire.Fire(tool, handle, shootPos, dependencies.fireDependencies)
                end
            end
        end)

        tool.Equipped:Connect(function()
            tool.Shared.equipped = true
            dependencies.checkPump(tool, handle)
        end)

        tool.Unequipped:Connect(function()
            tool.Shared.equipped = false
            mouse0.Value = false
            rKey.Value = false
            vKey.Value = false
        end)

        dependencies.weaponAmmo.Update(tool, dependencies.enum, dependencies.ammoFormat)
        weapons[tool] = function()
            local now = os.clock()
            local dt = math.min(now - lastTick, 0.1)
            lastTick = now
            local firemode = dependencies.fireModes.GetCurrent(tool)
            local isAutomatic = dependencies.fireModes.IsAutomatic(firemode)
            tool.Shared.firemodeText = dependencies.fireModes.GetText(firemode)
            local spunUp = true
            if spinUpTime ~= nil then
                -- Not gated on tool.Shared.equipped: Equipped can fire before this runtime connects it, which
                -- left the flag nil and froze the Minigun. Unequipped clears Mouse0, so wishfire is enough.
                local spinning = tool.Shared.wishfire == true
                spunUp = spinning and now - (tool.Shared.spinStartedAt or now) >= spinUpTime
                if barrelSpin ~= nil then
                    -- A cosmetic error must not abort this closure before Fire is reached: disable the spin instead.
                    local stepOk, stepError = pcall(stepBarrelSpin, barrelSpin, spinning, spinUpTime, dt)
                    if not stepOk then
                        barrelSpin = nil
                        print(("[Ned Gun] Minigun barrel spin disabled: %s"):format(tostring(stepError)))
                    end
                end
            end
            if dependencies.weaponFire.CanFire(tool) and isAutomatic then
                tool.Shared.canfire = true
            end
            if isAutomatic and spunUp then
                dependencies.weaponFire.Fire(tool, handle, shootPos, dependencies.fireDependencies)
            end
        end
    end

    -- Creator 2.0 keeps a destroyed Tool reachable (GetParent does not throw) but clears its Shared table,
    -- so a respawned character left the old Tool in the registry and errored every frame.
    local function isGone(tool)
        if dependencies.isDestroyed(tool) then
            return true
        end
        local ok, shared = pcall(function()
            return tool.Shared
        end)
        return not ok or shared == nil
    end

    function runtime:Update()
        for tool, updateTool in pairs(weapons) do
            if isGone(tool) then
                weapons[tool] = nil
            else
                updateTool()
            end
        end
    end

    return runtime
end

return WeaponRuntime