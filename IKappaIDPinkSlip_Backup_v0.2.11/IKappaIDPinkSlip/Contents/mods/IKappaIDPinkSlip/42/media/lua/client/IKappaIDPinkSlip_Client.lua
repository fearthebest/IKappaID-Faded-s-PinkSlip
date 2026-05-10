--[[
    IKappaIDPinkSlip_Client.lua
    -------------------------------------------------------------------------
    Client side. Two radial verbs, no context menu:

      * CLAIM   - vanilla vehicle radial slice, shown when the player is in
                  or adjacent to a vehicle and is carrying a Blank Pink Slip.
                  Sends `ClaimVehicle` to the server. The server despawns
                  the vehicle and mints a filled Pink Slip.

      * DEPLOY  - a custom keybind (default: K) summons a custom radial
                  listing every filled Pink Slip in the player's inventory,
                  or right-click a filled Pink Slip and deploy it directly.
                  Selecting either path sends `DeployVehicle` to the server,
                  which respawns the vehicle and consumes that exact slip.

    Server `OnServerCommand` echoes a `PinkSlipResult { success, text }`
    payload that we render via halo text.
]]

if isServer() then return end

require "IKappaIDPinkSlip_Shared"
pcall(require, "ISUI/ISButton")
local M = IKappaPinkSlip
local safeCall = M.safeCall

print("[IKappaIDPinkSlip] Client module loaded")

local SLIP_TEXTURE_NAME = "Item_IKappaPinkSlip"

local function getSlipTexture()
    if not getTexture then return nil end
    return getTexture(SLIP_TEXTURE_NAME)
        or getTexture("media/textures/Item_IKappaPinkSlip.png")
        or getTexture("Item_Paper")
end

-- =========================================================================
-- Halo / notification helpers
-- =========================================================================

local function notify(playerObj, text, success)
    if not playerObj then return end
    if HaloTextHelper and HaloTextHelper.addTextWithArrow then
        local color = success and HaloTextHelper.getColorGreen() or HaloTextHelper.getColorRed()
        HaloTextHelper.addTextWithArrow(playerObj, tostring(text or ""), success and true or false, color)
    elseif playerObj.Say then
        playerObj:Say(tostring(text or ""))
    end
end

M.ClientResult = function(success, text)
    notify(getPlayer(), text, success)
end

local function sendPinkSlipCommand(playerObj, command, args)
    if isClient() then
        sendClientCommand(playerObj, M.MODULE_ID, command, args)
        return
    end
    if M.Server and M.Server.onClientCommand then
        M.Server.onClientCommand(M.MODULE_ID, command, playerObj, args)
        return
    end
    notify(playerObj, "Pink Slip server bridge unavailable", false)
end

-- =========================================================================
-- Inventory helpers
-- =========================================================================

local function findBlankSlip(playerObj)
    if not playerObj then return nil end
    local inv = safeCall(function()
        if playerObj.getInventory then return playerObj:getInventory() end
        return nil
    end, nil, "resolve blank slip inventory")
    if not inv then return nil end
    if inv.getItemFromType then
        local found = safeCall(function()
            return inv:getItemFromType(M.BLANK_SLIP_TYPE, true, true)
        end, nil, "find blank slip")
        if found then return found end
    end
    local items = safeCall(function()
        if inv.getAllEvalRecurse then
            return inv:getAllEvalRecurse(function(item)
                return item and item.getFullType and tostring(item:getFullType()) == M.BLANK_SLIP_TYPE
            end)
        end
        return nil
    end, nil, "scan blank slip")
    if items and items.size then
        local count = tonumber(safeCall(function() return items:size() end, 0, "count blank slips")) or 0
        if count > 0 then
            return safeCall(function() return items:get(0) end, nil, "resolve blank slip")
        end
    end
    return nil
end

-- Walk the player inventory recursively for filled slips.
local function collectFilledSlips(playerObj)
    local out = {}
    if not playerObj then return out end
    local inv = safeCall(function()
        if playerObj.getInventory then return playerObj:getInventory() end
        return nil
    end, nil, "resolve filled slip inventory")
    if not inv then return out end
    local items = safeCall(function()
        if inv.getAllEvalRecurse then
            return inv:getAllEvalRecurse(function(item)
                return item and M.isFilledSlipItem(item)
            end)
        end
        return nil
    end, nil, "collect filled slips")
    if items and items.size then
        local count = tonumber(safeCall(function() return items:size() end, 0, "count filled slips")) or 0
        for i = 0, count - 1 do
            local it = safeCall(function() return items:get(i) end, nil, "resolve filled slip")
            if it then out[#out + 1] = it end
        end
    end
    return out
end

-- Vehicle the player is in, sitting next to, or nearest within claim range.
local function resolveTargetVehicle(playerObj)
    if not playerObj then return nil end
    local v = safeCall(function()
        if playerObj.getVehicle then return playerObj:getVehicle() end
        return nil
    end, nil, "resolve player vehicle")
    if v then return v end

    v = safeCall(function()
        if playerObj.getUseableVehicle then return playerObj:getUseableVehicle() end
        return nil
    end, nil, "resolve usable vehicle")
    if v then return v end

    v = safeCall(function()
        if playerObj.getNearVehicle then return playerObj:getNearVehicle() end
        return nil
    end, nil, "resolve near vehicle")
    if v then return v end

    -- Adjacent grid scan (3x3) - cheap, only runs on V press.
    local cell = safeCall(function()
        if playerObj.getCell then return playerObj:getCell() end
        if getCell then return getCell() end
        return nil
    end, nil, "resolve player cell")
    if not cell then return nil end
    local px = math.floor(tonumber(safeCall(function() return playerObj:getX() end, nil, "resolve player x")) or 0)
    local py = math.floor(tonumber(safeCall(function() return playerObj:getY() end, nil, "resolve player y")) or 0)
    local pz = math.floor(tonumber(safeCall(function() return playerObj:getZ() end, nil, "resolve player z")) or 0)
    for dx = -1, 1 do
        for dy = -1, 1 do
            local sq = safeCall(function()
                if cell.getGridSquare then return cell:getGridSquare(px + dx, py + dy, pz) end
                return nil
            end, nil, "resolve nearby vehicle square")
            if sq then
                local moving = safeCall(function()
                    if sq.getMovingObjects then return sq:getMovingObjects() end
                    return nil
                end, nil, "resolve square moving objects")
                if moving then
                    local count = tonumber(safeCall(function()
                        if moving.size then return moving:size() end
                        return 0
                    end, 0, "count moving objects")) or 0
                    for i = 0, count - 1 do
                        local obj = safeCall(function() return moving:get(i) end, nil, "resolve moving object")
                        if obj and instanceof and instanceof(obj, "BaseVehicle") then return obj end
                    end
                end
            end
        end
    end

    return nil
end

-- =========================================================================
-- CLAIM: radial slice on the vanilla vehicle radial
-- =========================================================================

local function onClaimSliceClicked(playerObj)
    if not M.isEnabled() then
        notify(playerObj, "Pink Slip system is disabled", false)
        return
    end
    local vehicle = resolveTargetVehicle(playerObj)
    if not vehicle then
        notify(playerObj, "No vehicle nearby", false)
        return
    end
    if not findBlankSlip(playerObj) then
        notify(playerObj, "No Blank Pink Slip in inventory", false)
        return
    end
    local vehicleId = safeCall(function()
        if vehicle.getId then return vehicle:getId() end
        return nil
    end, nil, "resolve claim vehicle id")
    if not vehicleId then
        notify(playerObj, "Could not identify vehicle", false)
        return
    end
    sendPinkSlipCommand(playerObj, M.CMD_CLAIM, {
        vehicleId = vehicleId,
    })
end

local function addClaimSlice(playerObj)
    if not M.isEnabled() then return end
    if not findBlankSlip(playerObj) then return end
    local vehicle = resolveTargetVehicle(playerObj)
    if not vehicle then return end
    local playerNum = safeCall(function()
        if playerObj.getPlayerNum then return playerObj:getPlayerNum() end
        return 0
    end, 0, "resolve claim radial player num")
    local menu = getPlayerRadialMenu and safeCall(function()
        return getPlayerRadialMenu(playerNum)
    end, nil, "resolve claim radial menu") or nil
    if not menu then return end
    safeCall(function()
        if menu.addSlice then menu:addSlice("Claim Pink Slip", getSlipTexture(), onClaimSliceClicked, playerObj) end
    end, nil, "add claim pink slip slice")
end

local function hookVehicleRadial()
    if not ISVehicleMenu or not ISVehicleMenu.showRadialMenu then return end
    if ISVehicleMenu.__pinkSlipPatched then return end
    ISVehicleMenu.__pinkSlipPatched = true
    local original = ISVehicleMenu.showRadialMenu
    function ISVehicleMenu.showRadialMenu(playerObj)
        safeCall(function() original(playerObj) end, nil, "vanilla vehicle radial")
        if playerObj then
            safeCall(function() addClaimSlice(playerObj) end, nil, "add pink slip claim radial")
        end
    end
end

-- =========================================================================
-- DEPLOY: custom radial summoned by configurable hotkey
-- =========================================================================

-- Build a label from a slip's local snapshot. Falls back gracefully if
-- the client-side modData copy is incomplete (server-side modData is the
-- authoritative source, but the radial label is purely cosmetic).
local function labelForSlip(item, index)
    local snap = M.readSlipSnapshot(item)
    if snap then return M.describeSnapshot(snap) end
    return "Pink Slip #" .. tostring(index)
end

local function getInventorySelection(items)
    if ISInventoryPane and ISInventoryPane.getActualItems then
        local actual = safeCall(function() return ISInventoryPane.getActualItems(items) end, nil, "resolve inventory selection")
        if actual then return actual end
    end
    local out = {}
    if type(items) == "table" then
        for _, entry in ipairs(items) do
            local item = entry
            if type(entry) == "table" and entry.items and entry.items[1] then
                item = entry.items[1]
            end
            if item then out[#out + 1] = item end
        end
    elseif items then
        out[#out + 1] = items
    end
    return out
end

local function onDeploySliceClicked(playerObj, uid)
    if not M.isEnabled() then
        notify(playerObj, "Pink Slip system is disabled", false)
        return
    end
    if not uid or uid == "" then
        notify(playerObj, "Slip has no UID", false)
        return
    end
    local currentVehicle = safeCall(function()
        if playerObj.getVehicle then return playerObj:getVehicle() end
        return nil
    end, nil, "resolve deploy player vehicle")
    if currentVehicle then
        notify(playerObj, "Cannot deploy from inside a vehicle", false)
        return
    end
    sendPinkSlipCommand(playerObj, M.CMD_DEPLOY, { slipUid = uid })
end

local function onRegisterSlipClicked(playerObj, uid)
    if not M.isEnabled() then
        notify(playerObj, "Pink Slip system is disabled", false)
        return
    end
    if not uid or uid == "" then
        notify(playerObj, "Slip has no UID", false)
        return
    end
    sendPinkSlipCommand(playerObj, M.CMD_REGISTER, { slipUid = uid })
end

local function showDeployRadial(playerObj)
    if not M.isEnabled() then return end
    if not playerObj then return end
    local currentVehicle = safeCall(function()
        if playerObj.getVehicle then return playerObj:getVehicle() end
        return nil
    end, nil, "resolve deploy radial player vehicle")
    if currentVehicle then
        notify(playerObj, "Cannot deploy from inside a vehicle", false)
        return
    end
    local slips = collectFilledSlips(playerObj)
    if #slips == 0 then
        notify(playerObj, "No filled Pink Slip in inventory", false)
        return
    end

    local playerNum = safeCall(function()
        if playerObj.getPlayerNum then return playerObj:getPlayerNum() end
        return 0
    end, 0, "resolve deploy radial player num")
    local menu = getPlayerRadialMenu and safeCall(function()
        return getPlayerRadialMenu(playerNum)
    end, nil, "resolve deploy radial menu") or nil
    if not menu then
        notify(playerObj, "Radial menu unavailable", false)
        return
    end

    -- Vanilla vehicle radial reuses this same singleton; clear it so we
    -- don't render stale slices alongside our deploy options.
    safeCall(function()
        if menu.clear then menu:clear() end
    end, nil, "clear deploy radial")

    -- Cap to 8 to keep the radial readable.
    local maxSlices = math.min(#slips, 8)
    for i = 1, maxSlices do
        local slip = slips[i]
        local uid  = M.readSlipUid(slip)
        local lbl  = "Deploy: " .. labelForSlip(slip, i)
        if uid then
            safeCall(function()
                if menu.addSlice then menu:addSlice(lbl, getSlipTexture(), onDeploySliceClicked, playerObj, uid) end
            end, nil, "add deploy pink slip slice")
        else
            -- Slip with no UID is unsupported (pre-mint or corrupted).
            local sliceObj = safeCall(function()
                if menu.addSlice then return menu:addSlice(lbl .. " (no UID)", getSlipTexture(), nil) end
                return nil
            end, nil, "add corrupt pink slip slice")
            if sliceObj then sliceObj.notAvailable = true end
        end
    end

    safeCall(function()
        if menu.setX and getMouseX then menu:setX(getMouseX() - 100) end
        if menu.setY and getMouseY then menu:setY(getMouseY() - 100) end
        if menu.display then menu:display() end
    end, nil, "display deploy radial")
end

-- =========================================================================
-- Filled slip inventory context menu
-- =========================================================================

local function addInventoryContext(playerNum, context, items)
    if not M.isEnabled() then return end
    local playerObj = getSpecificPlayer and getSpecificPlayer(playerNum) or getPlayer()
    if not playerObj then return end

    local selection = getInventorySelection(items)
    for _, item in ipairs(selection) do
        if item and M.isFilledSlipItem(item) then
            local uid = M.readSlipUid(item)
            if uid then
                local label = labelForSlip(item, 1)
                local deployOption = context:addOption("Deploy: " .. tostring(label), playerObj, onDeploySliceClicked, uid)
                if deployOption then deployOption.iconTexture = getSlipTexture() end

                local snap = M.readSlipSnapshot(item)
                local owner = snap and snap.modData and snap.modData[M.OWNER_LOCK_KEY] or nil
                local username = playerObj.getUsername and playerObj:getUsername() or nil
                if owner ~= username then
                    local registerOption = context:addOption("Register Title to Me", playerObj, onRegisterSlipClicked, uid)
                    if registerOption then registerOption.iconTexture = getSlipTexture() end
                end
            else
                local badOption = context:addOption("Pink Slip Missing UID", nil, nil)
                if badOption then badOption.notAvailable = true end
            end
            return
        end
    end
end

-- =========================================================================
-- Left-side quick deploy button
-- =========================================================================

local quickButton = nil
local quickButtonTarget = {}
local QUICK_BUTTON_SIZE = 42
local QUICK_MD_X_KEY = "IKappaPinkSlip_QB_X"
local QUICK_MD_Y_KEY = "IKappaPinkSlip_QB_Y"

-- Local fallbacks only if shared getters are unavailable.
local QUICK_BUTTON_DEFAULT_VISIBLE = false
local QUICK_BUTTON_DEFAULT_MOVABLE = true

local function getQuickButtonVisible()
    if M.showQuickButton then return M.showQuickButton() end
    return QUICK_BUTTON_DEFAULT_VISIBLE
end

local function getQuickButtonMovable()
    if M.movableQuickButton then return M.movableQuickButton() end
    return QUICK_BUTTON_DEFAULT_MOVABLE
end

local function clampToScreen(x, y, w, h)
    if not getCore then return x, y end
    local core = getCore()
    local screenW = core and core:getScreenWidth() or 1280
    local screenH = core and core:getScreenHeight() or 720
    local nx = math.max(0, math.min(math.floor(x or 0), math.max(0, screenW - (w or 0))))
    local ny = math.max(0, math.min(math.floor(y or 0), math.max(0, screenH - (h or 0))))
    return nx, ny
end

local function loadQuickButtonPos()
    local core = getCore and getCore() or nil
    local screenH = core and core:getScreenHeight() or 720
    local defaultX = 4
    local defaultY = math.floor((screenH - QUICK_BUTTON_SIZE) * 0.42)

    local playerObj = getPlayer and getPlayer() or nil
    if not playerObj or not playerObj.getModData then
        return defaultX, defaultY
    end

    local md = playerObj:getModData()
    local x = tonumber(md[QUICK_MD_X_KEY])
    local y = tonumber(md[QUICK_MD_Y_KEY])

    if x == nil or y == nil then
        return defaultX, defaultY
    end

    return clampToScreen(x, y, QUICK_BUTTON_SIZE, QUICK_BUTTON_SIZE)
end

local function saveQuickButtonPos(x, y)
    local playerObj = getPlayer and getPlayer() or nil
    if not playerObj or not playerObj.getModData then return end
    local md = playerObj:getModData()
    md[QUICK_MD_X_KEY] = math.floor(x or 0)
    md[QUICK_MD_Y_KEY] = math.floor(y or 0)
end

local function removeQuickButton()
    if quickButton and quickButton.removeFromUIManager then
        quickButton:removeFromUIManager()
    end
    quickButton = nil
end

function quickButtonTarget:onClick()
    local playerObj = getPlayer and getPlayer() or nil
    if not playerObj then return end
    showDeployRadial(playerObj)
end

local function attachDragHandlers(btn)
    if not btn then return end
    btn._ikappaDragEnabled = getQuickButtonMovable()
    btn._ikappaDragging = false
    btn._ikappaDragged = false
    btn._ikappaDragOffsetX = 0
    btn._ikappaDragOffsetY = 0

    function btn:onMouseDown(x, y)
        if self._ikappaDragEnabled then
            self._ikappaDragging = true
            self._ikappaDragged = false
            self._ikappaDragOffsetX = tonumber(x) or 0
            self._ikappaDragOffsetY = tonumber(y) or 0
        end
        if ISButton.onMouseDown then
            return ISButton.onMouseDown(self, x, y)
        end
        return true
    end

    function btn:onMouseMove(dx, dy)
        if self._ikappaDragging and self._ikappaDragEnabled and getMouseX and getMouseY then
            local mx = getMouseX()
            local my = getMouseY()
            local nx = mx - (self._ikappaDragOffsetX or 0)
            local ny = my - (self._ikappaDragOffsetY or 0)
            nx, ny = clampToScreen(nx, ny, self.width or QUICK_BUTTON_SIZE, self.height or QUICK_BUTTON_SIZE)
            self:setX(nx)
            self:setY(ny)
            self._ikappaDragged = true
            return
        end
        if ISButton.onMouseMove then
            ISButton.onMouseMove(self, dx, dy)
        end
    end

    function btn:onMouseUp(x, y)
        local wasDragging = self._ikappaDragging
        self._ikappaDragging = false

        if wasDragging and self._ikappaDragged then
            saveQuickButtonPos(self:getX(), self:getY())
            self._ikappaDragged = false
            return true
        end

        if ISButton.onMouseUp then
            return ISButton.onMouseUp(self, x, y)
        end
        return true
    end
end

local function createQuickButton()
    if not M.isEnabled() or not getQuickButtonVisible() then
        removeQuickButton()
        return
    end
    if not ISButton then return end
    local playerObj = getPlayer and getPlayer() or nil
    if not playerObj then return end

    removeQuickButton()

    local x, y = loadQuickButtonPos()

    quickButton = ISButton:new(x, y, QUICK_BUTTON_SIZE, QUICK_BUTTON_SIZE, "", quickButtonTarget, quickButtonTarget.onClick)
    quickButton:initialise()
    quickButton.tooltip = "Deploy Pink Slip"
    quickButton.backgroundColor = { r = 0.06, g = 0.04, b = 0.05, a = 0.72 }
    quickButton.backgroundColorMouseOver = { r = 0.22, g = 0.10, b = 0.13, a = 0.86 }
    quickButton.borderColor = { r = 0.92, g = 0.56, b = 0.62, a = 0.85 }
    local icon = getSlipTexture()
    if icon and quickButton.setImage then quickButton:setImage(icon) end

    attachDragHandlers(quickButton)

    quickButton:addToUIManager()
    quickButton:setVisible(true)
end

local function delayedCreateQuickButton()
    if not Events or not Events.OnTick then
        createQuickButton()
        return
    end
    local ticks = 0
    local function onTick()
        ticks = ticks + 1
        if ticks < 60 then return end
        Events.OnTick.Remove(onTick)
        createQuickButton()
    end
    Events.OnTick.Add(onTick)
end

-- =========================================================================
-- Keybind handler
-- =========================================================================

local DEPLOY_KEYBIND_NAME = "IKappaIDPinkSlip.Deploy"
local DEPLOY_DEFAULT_KEY  = Keyboard and Keyboard.KEY_K or 37

-- Register the keybind so it appears in vanilla Mod Options -> Keybinds.
if keyBinding then
    table.insert(keyBinding, { value = DEPLOY_KEYBIND_NAME, key = DEPLOY_DEFAULT_KEY })
end

local function getBoundDeployKey()
    if getCore and getCore().getKey then
        local k = safeCall(function() return getCore():getKey(DEPLOY_KEYBIND_NAME) end, nil, "read deploy keybind")
        if tonumber(k) then return tonumber(k) end
    end
    return DEPLOY_DEFAULT_KEY
end

local function onKeyPressed(key)
    if not M.isEnabled() then return end
    if key ~= getBoundDeployKey() then return end
    local playerObj = getPlayer()
    if not playerObj then return end
    showDeployRadial(playerObj)
end

-- =========================================================================
-- Server result handler
-- =========================================================================

local function onServerCommand(module, command, args)
    if module ~= M.MODULE_ID then return end
    local playerObj = getPlayer()
    if not playerObj then return end
    if command == M.CMD_RESULT then
        local text = (args and args.text) or ""
        local success = args and args.success or false
        notify(playerObj, text, success)
    end
end

-- =========================================================================
-- Init
-- =========================================================================

local function init()
    hookVehicleRadial()
    delayedCreateQuickButton()
end

if Events then
    if Events.OnGameStart     then Events.OnGameStart.Add(init) end
    if Events.OnCreatePlayer  then Events.OnCreatePlayer.Add(function(playerIndex) if playerIndex == 0 then delayedCreateQuickButton() end end) end
    if Events.OnResolutionChange then Events.OnResolutionChange.Add(createQuickButton) end
    if Events.OnKeyPressed    then Events.OnKeyPressed.Add(onKeyPressed) end
    if Events.OnServerCommand then Events.OnServerCommand.Add(onServerCommand) end
    if Events.OnFillInventoryObjectContextMenu then Events.OnFillInventoryObjectContextMenu.Add(addInventoryContext) end
end