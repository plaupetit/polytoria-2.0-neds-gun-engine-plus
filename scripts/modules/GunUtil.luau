-- GunUtil: small stateless helpers shared by the gun scripts (single source instead of 6 diverging copies).
-- Role: WaitChild, FindChildAndDoFunc, IsDestroyed, CreateBool, the bounded "!Ignore" raycast loop and the
-- server-side damage-target helpers (ResolveDamageableTarget, CollectDamageableTargets, HasLineOfSight) shared
-- by WeaponGrenadeServer and WeaponMeleeServer. Damageable = a Player or an NPC (Player extends NPC), the same
-- rule WeaponServer applies to bullet hits; callers still check Health and the "Protect" shield themselves.
-- Side: both (client and server). Pure functions only; no module-global mutable state.
-- Dependencies: none. Callers pass every engine object explicitly, so this module never requires a sibling.
-- Bootstrap note: a script needs a plain polling loop to find this module, then uses GunUtil.WaitChild.
-- How to test: in Play, call GunUtil.RaycastSkippingIgnored over a Part holding a "!Ignore" Folder
-- and confirm the ray continues behind it; WaitChild with a missing child and a duration returns nil.
-- Damage helpers: throw a Grenade / stab with the Knife next to a practice NPC (see those server modules).
local GunUtil = {}

local DEFAULT_MAX_SKIPS = 32

-- Waits for parent[childName]. With a duration it returns nil after the timeout; without one it yields
-- until found and prints one warning after 5 s. `label` only prefixes that warning (e.g. "GunFramework/Client").
function GunUtil.WaitChild(parent, childName, duration, label)
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
            local prefix = label ~= nil and ("[" .. tostring(label) .. "]: ") or ""
            -- Format first, then prefix, so a label containing "%" cannot corrupt the format string.
            print(prefix .. ("Infinite yield on WaitChild(%s, %s)"):format(parent.Name, childName))
            warned = true
        end
    until found
    return found
end

function GunUtil.FindChildAndDoFunc(parent, childName, func)
    local child = parent:FindChild(childName)
    if not child then
        return
    end
    func(child)
end

-- A destroyed Instance throws when its parent is read; that throw is the only reliable liveness probe.
function GunUtil.IsDestroyed(instance)
    local ok = pcall(function()
        return instance:GetParent()
    end)
    return ok == false
end

function GunUtil.CreateBool(name, parent)
    local bool = Instance.New("BoolValue")
    bool.Name = name
    bool.Parent = parent
    return bool
end

-- Raycast that re-casts through any struck Instance owning a child named "!Ignore".
-- `ignore` is mutated (struck Instances are appended) so the next cast skips them.
-- The loop is bounded (maxSkips, default 32) to avoid unbounded retries on an ignored-object chain;
-- it returns nil when the bound is exhausted. A RayResult may carry a nil Instance, so it is guarded.
function GunUtil.RaycastSkippingIgnored(environment, origin, direction, maxRange, ignore, maxSkips)
    for _ = 1, maxSkips or DEFAULT_MAX_SKIPS do
        local hit = environment:Raycast(origin, direction, maxRange, ignore)
        local instance = hit and hit.Instance
        if instance == nil or instance:FindChild("!Ignore") == nil then
            return hit
        end
        table.insert(ignore, instance)
    end
    return nil
end

-- Walks up from a struck Instance to the Player or NPC that owns it; nil for world geometry.
-- Same rule as WeaponServer's bullet hit resolution (IsA("NPC") is also true for Players).
function GunUtil.ResolveDamageableTarget(hit)
    local candidate = hit
    while candidate do
        if candidate:IsA("NPC") or candidate:IsA("Player") then
            return candidate
        end
        candidate = candidate.Parent
    end
    return nil
end

-- Every Player plus every NPC under `environment`, without duplicates (a Player is also an NPC).
-- Returns a fresh array each call; it may be partial if the tree changes while it is walked. Callers must
-- tolerate a target vanishing mid-pass (pcall around per-target work). Cost is one GetDescendants walk of
-- `environment` per call, acceptable for a blast or a swing but not for a per-frame query.
function GunUtil.CollectDamageableTargets(players, environment)
    local targets = {}
    local seen = {}

    local function add(candidate)
        if candidate ~= nil and not seen[candidate] then
            seen[candidate] = true
            table.insert(targets, candidate)
        end
    end

    if players ~= nil then
        pcall(function()
            for _, player in ipairs(players:GetPlayers()) do
                add(player)
            end
        end)
    end
    if environment ~= nil then
        pcall(function()
            for _, instance in ipairs(environment:GetDescendants()) do
                if instance:IsA("NPC") then
                    add(instance)
                end
            end
        end)
    end
    return targets
end

-- True when nothing but a Player/NPC (or nothing at all) lies between the two points: world geometry blocks,
-- bodies do not (the target itself sits at the end of the segment). `ignore` is an optional array of Instances
-- that the ray skips; it is copied, never mutated. Instances owning an "!Ignore" child are skipped as well.
function GunUtil.HasLineOfSight(environment, fromPosition, toPosition, ignore)
    local offset = toPosition - fromPosition
    local distance = offset.Magnitude
    if not (distance > 0.05) then
        -- Touching points (or NaN) have nothing between them.
        return true
    end
    local skipList = {}
    if ignore ~= nil then
        for index, instance in ipairs(ignore) do
            skipList[index] = instance
        end
    end
    local hit = GunUtil.RaycastSkippingIgnored(environment, fromPosition, offset.Normalized, distance, skipList)
    local blocker = hit and hit.Instance
    if blocker == nil then
        return true
    end
    return GunUtil.ResolveDamageableTarget(blocker) ~= nil
end

return GunUtil
