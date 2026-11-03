-- NED GUN ENGINE UPDATE WELCOME
-- Expected type: ClientScript
-- Expected Creator path: World/ScriptService/NedGunEngineUpdateWelcome
-- Presentation only: this script never changes weapon, NPC, or player gameplay state.
-- Remove PlayerGUI/NedGunEngineUpdateWelcomeGui and this ClientScript to remove it.

local playerGui = game["PlayerGUI"]
local welcomeGui = playerGui and playerGui:FindChild("NedGunEngineUpdateWelcomeGui")
if welcomeGui == nil then
    warn("NedGunEngineUpdateWelcomeGui is missing; welcome window was not shown.")
    return
end

local expandedPanel = welcomeGui:FindChild("ExpandedPanel")
local compactTab = welcomeGui:FindChild("CompactTab")
if expandedPanel == nil or compactTab == nil then
    warn("NedGunEngineUpdateWelcomeGui is incomplete; welcome window was not shown.")
    welcomeGui.Visible = false
    return
end

local function findPanelChild(name)
    local child = expandedPanel:FindChild(name)
    if child == nil then
        warn("NedGunEngineUpdateWelcomeGui is missing " .. name .. ".")
    end
    return child
end

local creditViewport = nil
local title = findPanelChild("Title")
local minimizeButton = findPanelChild("MinimizeButton")
local closeButton = findPanelChild("CloseButton")
local scrollUpButton = findPanelChild("ScrollUpButton")
local scrollThumb = findPanelChild("ScrollThumb")
local scrollDownButton = findPanelChild("ScrollDownButton")
local oldCreditsScroll = findPanelChild("CreditsScroll")
creditViewport = oldCreditsScroll and oldCreditsScroll:FindChild("CreditViewport")
if creditViewport == nil then
    warn("NedGunEngineUpdateWelcomeGui is missing CreditViewport in CreditsScroll.")
end

local function findCreditChild(name)
    local child = creditViewport and creditViewport:FindChild(name)
    if child == nil then
        warn("NedGunEngineUpdateWelcomeGui is missing " .. name .. " in CreditViewport.")
    end
    return child
end

local originalCredit = findCreditChild("OriginalCredit")
local updateCredit = findCreditChild("UpdateCredit")
local supportContact = findCreditChild("SupportContact")
local removalInstructions = findCreditChild("RemovalInstructions")

-- CreditsScroll owns the native wheel and vertical scrollbar at runtime.
-- Its taller CreditViewport makes Auto mode expose native vertical scrolling.
expandedPanel.ClipDescendants = true
if creditViewport then
    creditViewport.ClipDescendants = false
end
if oldCreditsScroll then
    oldCreditsScroll.Visible = true
    oldCreditsScroll.ClipDescendants = true
end
-- Creator's UIScrollView already supplies the real scrollbar. Hide the old
-- script-owned arrows so two independent scroll positions can never fight.
if scrollUpButton then scrollUpButton.Visible = false end
if scrollThumb then scrollThumb.Visible = false end
if scrollDownButton then scrollDownButton.Visible = false end

local function showExpanded()
    expandedPanel.Visible = true
    compactTab.Visible = false
end

local function showCompact()
    expandedPanel.Visible = false
    compactTab.Visible = true
end

-- Window drag state is local to this client session.
local dragging = false
local dragStartMouse = nil
local dragStartPanelOffset = nil

local function stopDragging()
    dragging = false
    dragStartMouse = nil
    dragStartPanelOffset = nil
end

local function startDragging()
    if Input.CursorLocked or title == nil or Input.MousePosition == nil then
        return
    end
    dragging = true
    dragStartMouse = Input.MousePosition
    dragStartPanelOffset = expandedPanel.PositionOffset
end

local function updateDragging()
    if not dragging or dragStartMouse == nil or dragStartPanelOffset == nil or Input.MousePosition == nil then
        return
    end
    local mouse = Input.MousePosition
    local x = dragStartPanelOffset.X + (mouse.X - dragStartMouse.X)
    local y = dragStartPanelOffset.Y + (mouse.Y - dragStartMouse.Y)
    expandedPanel.PositionRelative = Vector2.New(0, 0)
    expandedPanel.PositionOffset = Vector2.New(x, y)
    compactTab.PositionRelative = Vector2.New(0, 0)
    compactTab.PositionOffset = Vector2.New(x, y)
end

-- Each credit section has a fixed, non-overlapping rectangle. The text is
-- deliberately kept in separate blocks so wrapped sentences cannot merge
-- visually into the following paragraph.
local creditWidth = 596
local creditContentHeight = 754
local originalCreditY, originalCreditHeight = 0, 76
local updateCreditY, updateCreditHeight = 88, 450
local supportContactY, supportContactHeight = 550, 68
local removalInstructionsY, removalInstructionsHeight = 630, 112

local function configureCreditBlock(block, y, height)
    if block == nil then
        return
    end
    block.PositionRelative = Vector2.New(0, 0)
    block.PositionOffset = Vector2.New(0, y)
    block.SizeRelative = Vector2.New(0, 0)
    block.SizeOffset = Vector2.New(creditWidth, height)
end

configureCreditBlock(originalCredit, originalCreditY, originalCreditHeight)
configureCreditBlock(updateCredit, updateCreditY, updateCreditHeight)
configureCreditBlock(supportContact, supportContactY, supportContactHeight)
configureCreditBlock(removalInstructions, removalInstructionsY, removalInstructionsHeight)
if creditViewport then
    creditViewport.SizeRelative = Vector2.New(0, 0)
    creditViewport.SizeOffset = Vector2.New(creditWidth, creditContentHeight)
end

-- The document stays at its authored positions. Native UIScrollView scrolling
-- moves the single CreditViewport, preventing clipped or overlapping labels.
local function renderCreditScroll()
end

-- Only the title is draggable; scrolling belongs exclusively to UIScrollView.
if title then
    title.MouseDown:Connect(startDragging)
    title.MouseUp:Connect(stopDragging)
end
expandedPanel.MouseUp:Connect(function()
    stopDragging()
end)
Input.MouseMoved:Connect(function()
    updateDragging()
end)

-- The red X hides the complete GUI only for this client session; it does not save a preference.
if closeButton then
    closeButton.Clicked:Connect(function()
        stopDragging()
        welcomeGui.Visible = false
    end)
end
if minimizeButton then
    minimizeButton.Clicked:Connect(function()
        stopDragging()
        showCompact()
    end)
end
compactTab.Clicked:Connect(showExpanded)

renderCreditScroll()
showExpanded()
