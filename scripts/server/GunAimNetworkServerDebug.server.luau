-- GunAimNetworkServerDebug is a read-only ServerScript for tracing the exact
-- CreateBullet endpoint that reaches the multiplayer authority.
-- It never edits the message, weapon state, player state, raycasts, or damage.

-- Off by default so a published game does not spam the console or pay a per-shot cost; set true only while diagnosing.
local DEBUG_ENABLED = false

local function waitChild(parent, childName)
    local child = parent:FindChild(childName)
    while child == nil do
        wait()
        child = parent:FindChild(childName)
    end
    return child
end

local function formatVector3(value)
    if value == nil then
        return "nil"
    end
    return ("(%.2f, %.2f, %.2f)"):format(value.X, value.Y, value.Z)
end

local function getMuzzlePosition(player)
    local tool = player and player:FindChildByClass("Tool") or nil
    local handle = tool and tool:FindChild("Handle") or nil
    local shootPos = handle and handle:FindChild("ShootPos") or nil
    return tool, shootPos and shootPos.Position or nil
end

local hidden = game["Hidden"]
local remotes = waitChild(hidden, "Remotes")
local createBullet = waitChild(remotes, "CreateBullet")

-- EVENT / TRIGGER: any client invokes the existing weapon remote.
-- ACTION / TASK / DO: print immutable request data before it is lost to the network boundary.
createBullet.InvokedServer:Connect(function(sender, message)
    if not DEBUG_ENABLED or sender == nil or message == nil then
        return
    end

    local endpoint = nil
    local clientOrigin = nil
    local pelletCount = nil
    local endpointOk = pcall(function()
        endpoint = message:GetVector3("1")
        clientOrigin = message:GetVector3("origin")
        pelletCount = message:GetInt("m")
    end)
    if not endpointOk or endpoint == nil then
        -- Reload requests intentionally have no endpoint and are not gun shots.
        return
    end

    local tool, muzzlePosition = getMuzzlePosition(sender)
    local inboundDirection = nil
    local rayOrigin = clientOrigin or muzzlePosition
    if rayOrigin ~= nil and (endpoint - rayOrigin).Magnitude > 0.0001 then
        inboundDirection = (endpoint - rayOrigin).Normalized
    end

    print(("[GunAimServerDebug] INBOUND player=%s tool=%s pellets=%s serverMuzzle=%s clientOrigin=%s endpoint=%s direction=%s")
        :format(sender.Name, tool and tool.Name or "none", tostring(pelletCount),
            formatVector3(muzzlePosition), formatVector3(clientOrigin), formatVector3(endpoint), formatVector3(inboundDirection)))
end)

-- Announce only when enabled: a disabled diagnostic must stay silent in a published game.
if DEBUG_ENABLED then
    print("[GunAimServerDebug] Ready. Disable this ServerScript to stop inbound network diagnostics.")
end
