--[[
    IKappaIDPinkSlip_Server.lua
    -------------------------------------------------------------------------
    Server side. Authoritative claim/deploy:

      ClaimVehicle  - validate proximity + blank slip in inventory, capture
                      vehicle state via shared serializer, despawn the
                      vehicle, consume the blank, mint a filled Pink Slip
                      with the snapshot + UID written into its modData.

      DeployVehicle - validate slip ownership in player's inventory by UID,
                      spawn a vehicle of the captured script type adjacent
                      to the player, apply the snapshot, consume the slip.

    GLOBAL_RULES Rule 14: server NEVER trusts client-supplied identity or
    payload data. Player identity comes from the OnClientCommand `player`
    argument; snapshot data is read from the player's authoritative
    inventory item, never from `args`.
]]

if isClient() then return end

require "IKappaIDPinkSlip_Shared"
require "IKappaIDPinkSlip_VehicleOps"
local M = IKappaPinkSlip
local tryCall = M.tryCall
local safeCall = M.safeCall

print("[IKappaIDPinkSlip] Server module loaded")

-- =========================================================================
-- Result echo
-- =========================================================================

local function echo(player, success, text)
    if not player then return end
    if isClient() == false and isServer() == false and M.ClientResult and getPlayer then
        local _, localPlayer = tryCall(function() return getPlayer() end, "resolve local player for echo")
        if localPlayer and localPlayer == player then
            M.ClientResult(success and true or false, tostring(text or ""))
            return
        end
    end
    if sendServerCommand then
        sendServerCommand(player, M.MODULE_ID, M.CMD_RESULT, {
            success = success and true or false,
            text    = tostring(text or ""),
        })
    end
end

-- =========================================================================
-- Inventory helpers
-- =========================================================================

local function findFilledSlipByUid(player, uid)
    if not player or not uid or uid == "" then return nil end
    local inv = player:getInventory()
    if not inv then return nil end
    local ok, items = tryCall(function()
        return inv:getAllEvalRecurse(function(item)
            return item and M.isFilledSlipItem(item)
        end)
    end, "find filled slip")
    if not ok then return nil end
    if not items or not items.size then return nil end
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and M.readSlipUid(it) == uid then return it end
    end
    return nil
end

local function countFilledSlips(player)
    if not player then return 0 end
    local inv = player:getInventory()
    if not inv then return 0 end
    local ok, items = tryCall(function()
        return inv:getAllEvalRecurse(function(item)
            return item and M.isFilledSlipItem(item)
        end)
    end, "count filled slips")
    if not ok then return 0 end
    if items and items.size then return items:size() end
    return 0
end

local function findFirstItemByType(player, fullType)
    if not player or not fullType then return nil end
    local inv = player:getInventory()
    if not inv then return nil end
    if inv.getItemFromType then
        local ok, item = tryCall(function() return inv:getItemFromType(fullType, true, true) end, "find item " .. tostring(fullType))
        if ok and item then return item end
    end
    local ok, items = tryCall(function()
        return inv:getAllEvalRecurse(function(item)
            return item and item.getFullType and tostring(item:getFullType()) == fullType
        end)
    end, "scan item " .. tostring(fullType))
    if ok and items and items.size and items:size() > 0 then return items:get(0) end
    return nil
end

-- Find the InventoryItem container holding `item` so we can remove it cleanly.
-- Falls back to the player's primary inventory if the parent container can't
-- be resolved.
local function removeItemFromAnywhere(player, item)
    if not player or not item then return false end
    local container = nil
    if item.getContainer then
        local ok, result = tryCall(function() return item:getContainer() end, "resolve item container")
        if ok then container = result end
    end
    if not container then container = player:getInventory() end
    local ok = false
    if container and container.DoRemoveItem then
        ok = tryCall(function()
            container:DoRemoveItem(item)
            if sendRemoveItemFromContainer then sendRemoveItemFromContainer(container, item) end
        end, "do-remove item from container")
    end
    if not ok then
        ok = tryCall(function()
            if container and container.Remove then
                container:Remove(item)
                if sendRemoveItemFromContainer then sendRemoveItemFromContainer(container, item) end
                return
            end
            player:getInventory():Remove(item)
        end, "remove item from container")
    end
    return ok
end

local function addItemBack(player, item)
    if not player or not item then return false end
    local inv = player:getInventory()
    if not inv then return false end
    local ok = tryCall(function()
        inv:AddItem(item)
        if sendAddItemToContainer then sendAddItemToContainer(inv, item) end
    end, "restore item to inventory")
    return ok
end

local function mintItemForInventory(inv, fullType)
    if not inv or not fullType then return nil, false end
    local item = M.createItem(fullType)
    if item then return item, false end
    if inv.AddItem then
        local ok, added = tryCall(function() return inv:AddItem(fullType) end, "add item by type " .. tostring(fullType))
        if ok and added then
            if sendAddItemToContainer then
                tryCall(function() sendAddItemToContainer(inv, added) end, "sync added item " .. tostring(fullType))
            end
            return added, true
        end
    end
    return nil, false
end

-- =========================================================================
-- Vehicle spawn helper
-- =========================================================================

local function findNearestVehicle(player)
    if not player then return nil end

    local near = safeCall(function()
        if player.getUseableVehicle then return player:getUseableVehicle() end
        return nil
    end, nil, "find usable spawned vehicle")
    if near then return near end

    near = safeCall(function()
        if player.getNearVehicle then return player:getNearVehicle() end
        return nil
    end, nil, "find near spawned vehicle")
    if near then return near end

    local cell = safeCall(function()
        if player.getCell then return player:getCell() end
        if getCell then return getCell() end
        return nil
    end, nil, "resolve spawned vehicle scan cell")
    if not cell then return nil end

    local px = math.floor(tonumber(safeCall(function() return player:getX() end, nil, "resolve spawned vehicle scan x")) or 0)
    local py = math.floor(tonumber(safeCall(function() return player:getY() end, nil, "resolve spawned vehicle scan y")) or 0)
    local pz = math.floor(tonumber(safeCall(function() return player:getZ() end, nil, "resolve spawned vehicle scan z")) or 0)
    for dx = -2, 2 do
        for dy = -2, 2 do
            local sq = safeCall(function()
                if cell.getGridSquare then return cell:getGridSquare(px + dx, py + dy, pz) end
                return nil
            end, nil, "resolve spawned vehicle scan square")
            local moving = sq and safeCall(function()
                if sq.getMovingObjects then return sq:getMovingObjects() end
                return nil
            end, nil, "resolve spawned vehicle scan objects") or nil
            local count = moving and tonumber(safeCall(function()
                if moving.size then return moving:size() end
                return 0
            end, 0, "count spawned vehicle scan objects")) or 0
            for i = 0, count - 1 do
                local obj = safeCall(function() return moving:get(i) end, nil, "resolve spawned vehicle scan object")
                if obj and instanceof and instanceof(obj, "BaseVehicle") then return obj end
            end
        end
    end
    return nil
end

local function findSpawnSquareNearPlayer(player)
    if not player or not getCell then return nil end
    local cell = getCell()
    if not cell then return nil end

    local px = math.floor(tonumber(player:getX()) or 0)
    local py = math.floor(tonumber(player:getY()) or 0)
    local pz = math.floor(tonumber(player:getZ()) or 0)

    local candidates = {
        { 0,  1}, { 1,  0}, { 0, -1}, {-1,  0},
        { 1,  1}, { 1, -1}, {-1,  1}, {-1, -1},
        { 0,  2}, { 2,  0}, { 0, -2}, {-2,  0},
    }

    for _, d in ipairs(candidates) do
        local sq = cell:getGridSquare(px + d[1], py + d[2], pz)
        if sq and sq.getMovingObjects then
            local blocked = false
            local objs = sq:getMovingObjects()
            if objs and objs.size then
                for i = 0, objs:size() - 1 do
                    local obj = objs:get(i)
                    if obj and instanceof and instanceof(obj, "BaseVehicle") then
                        blocked = true
                        break
                    end
                end
            end
            if not blocked then return sq end
        end
    end

    return cell:getGridSquare(px, py, pz)
end

local function spawnVehicleForPlayer(player, snap)
    if not player or not snap or not snap.scriptName or snap.scriptName == "" then
        return nil, "Snapshot is missing a vehicle script"
    end
    local okSquare, square = tryCall(function()
        return findSpawnSquareNearPlayer(player)
    end, "resolve spawn square")
    if not okSquare or not square then
        return nil, "Could not resolve a spawn square"
    end
    local dir = IsoDirections and IsoDirections.S or nil
    local okDir, playerDir = tryCall(function() return player:getDir() end, "resolve player direction")
    if okDir and playerDir then dir = playerDir end

    local vehicle = nil
    -- CarWanna's B42 source path calls addVehicleDebug(type, dir, skin, square).
    if not addVehicleDebug then return nil, "addVehicleDebug not available" end
    local okSpawn, spawnedOrErr = tryCall(function()
        return addVehicleDebug(snap.scriptName, dir, snap.skinIndex or -1, square)
    end, "spawn vehicle")
    if not okSpawn then return nil, "addVehicleDebug failed: " .. tostring(spawnedOrErr) end
    vehicle = spawnedOrErr
    if not vehicle then
        vehicle = findNearestVehicle(player)
    end
    if vehicle and vehicle.getId and getVehicleById then
        local okId, vehicleId = tryCall(function() return vehicle:getId() end, "resolve spawned vehicle id")
        if okId and vehicleId then
            local okRefresh, refreshed = tryCall(function() return getVehicleById(vehicleId) end, "refresh spawned vehicle")
            if okRefresh and refreshed then vehicle = refreshed end
        end
    end
    if not vehicle then
        return nil, "Could not resolve spawned vehicle"
    end
    return vehicle, nil
end

local function removeVehicle(vehicle)
    if not vehicle then return false end
    if vehicle.permanentlyRemove then
        local ok = tryCall(function() vehicle:permanentlyRemove() end, "permanently remove vehicle")
        if ok then return true end
    end

    local didRemove = false
    if vehicle.removeFromWorld then
        local ok = tryCall(function() vehicle:removeFromWorld() end, "remove vehicle from world")
        didRemove = ok or didRemove
    end
    if vehicle.removeFromSquare then
        local ok = tryCall(function() vehicle:removeFromSquare() end, "remove vehicle from square")
        didRemove = ok or didRemove
    end
    return didRemove
end

local function findVehicleKey(player, vehicle)
    if not player or not vehicle then return nil end
    local inv = player:getInventory()
    if not inv then return nil end
    if not inv.haveThisKeyId or not vehicle.getKeyId then return nil end
    local ok, key = tryCall(function() return inv:haveThisKeyId(vehicle:getKeyId()) end, "find vehicle key")
    if ok then return key end
    return nil
end

local function measureVehicleDistance(player, vehicle)
    local ok, dist = tryCall(function()
        if not player or not vehicle then return nil end

        local px = tonumber(player:getX())
        local py = tonumber(player:getY())
        local pz = tonumber(player:getZ()) or 0
        local vx = vehicle.getX and tonumber(vehicle:getX()) or nil
        local vy = vehicle.getY and tonumber(vehicle:getY()) or nil
        local vz = vehicle.getZ and tonumber(vehicle:getZ()) or pz

        if (not vx or not vy) and vehicle.getSquare then
            local square = vehicle:getSquare()
            if square then
                vx = square.getX and tonumber(square:getX()) or vx
                vy = square.getY and tonumber(square:getY()) or vy
                vz = square.getZ and tonumber(square:getZ()) or vz
            end
        end

        if not px or not py or not vx or not vy then return nil end
        if math.abs((vz or pz) - pz) > 1 then return 999999 end

        local dx = px - vx
        local dy = py - vy
        return math.sqrt((dx * dx) + (dy * dy))
    end, "measure vehicle coordinate distance")

    if ok then return tonumber(dist) end
    return nil
end

-- =========================================================================
-- CLAIM
-- =========================================================================

local function handleClaim(player, args)
    if not M.isEnabled() then
        echo(player, false, "Pink Slip system is disabled")
        return
    end
    if not player then return end

    local vehicle = nil
    if getVehicleById then
        local okVehicle, foundVehicle = tryCall(function()
            return getVehicleById(args and args.vehicleId)
        end, "resolve vehicle by id")
        if okVehicle then vehicle = foundVehicle end
    end
    if not vehicle then
        echo(player, false, "Vehicle not found")
        return
    end

    if M.isRentalTaggedVehicle(vehicle) then
        echo(player, false, "Rental vehicles cannot be claimed as Pink Slips")
        return
    end

    -- Proximity gate (or driver gate when sitting in the vehicle).
    local okVehicle, currentVehicle = tryCall(function() return player:getVehicle() end, "resolve player vehicle")
    local sittingIn = okVehicle and currentVehicle == vehicle
    if not sittingIn then
        local dist = measureVehicleDistance(player, vehicle)
        if not dist then
            echo(player, false, "Could not verify vehicle distance")
            return
        end
        if dist > M.getClaimDistance() then
            echo(player, false, "Vehicle is too far away")
            return
        end
    end

    -- Reject if other players are inside (configurable).
    if M.requireEmptyVehicle() then
        local occupants = 0
        local okSeats = tryCall(function()
            local maxSeats = vehicle.getMaxPassengers and vehicle:getMaxPassengers() or 0
            for i = 0, (maxSeats or 0) - 1 do
                local occ = vehicle:getCharacter(i)
                if occ and occ ~= player then occupants = occupants + 1 end
            end
        end, "verify vehicle occupants")
        if not okSeats then
            echo(player, false, "Could not verify vehicle occupants")
            return
        end
        if occupants > 0 then
            echo(player, false, "Vehicle is not empty")
            return
        end
    end

    -- Cap on filled slips per player.
    local filledCount = countFilledSlips(player)
    if filledCount >= M.getMaxFilledSlips() then
        echo(player, false, "Pink Slip cap reached (" .. tostring(M.getMaxFilledSlips()) .. ")")
        return
    end

    -- Authoritative inventory check for the blank slip.
    local inv = player:getInventory()
    local blankSlip = findFirstItemByType(player, M.BLANK_SLIP_TYPE)
    if not inv or not blankSlip then
        echo(player, false, "No Blank Pink Slip in inventory")
        return
    end

    -- Capture state.
    local snap = M.serializeVehicle(vehicle)
    if not snap or not snap.scriptName or snap.scriptName == "" then
        echo(player, false, "Could not capture vehicle state")
        return
    end

    -- Stamp stable title metadata. The client-provided vehicleId was only a
    -- short-lived lookup hint; this UID is the persistent lifecycle tag.
    local ownerName = player:getUsername() or ""
    local uid = M.mintSlipUid(player)
    snap.modData = snap.modData or {}
    snap.modData[M.OWNER_LOCK_KEY] = ownerName
    local vehicleUid = M.ensureSnapshotVehicleUid(snap, uid)
    local vehicleKey = findVehicleKey(player, vehicle)
    snap.hasKey = vehicleKey ~= nil

    local newSlip, slipAlreadyAdded = mintItemForInventory(inv, M.FILLED_SLIP_TYPE)
    if not newSlip then
        echo(player, false, "Failed to mint Pink Slip")
        return
    end
    if not M.writeSlipPayload(newSlip, snap, uid, ownerName) then
        if slipAlreadyAdded then removeItemFromAnywhere(player, newSlip) end
        echo(player, false, "Failed to write Pink Slip payload")
        return
    end

    if not slipAlreadyAdded then
        local okAddSlip = tryCall(function()
            inv:AddItem(newSlip)
            if sendAddItemToContainer then sendAddItemToContainer(inv, newSlip) end
        end, "add filled slip")
        if not okAddSlip then
            echo(player, false, "Failed to add Pink Slip to inventory")
            return
        end
        slipAlreadyAdded = true
    end

    if not removeItemFromAnywhere(player, blankSlip) then
        if slipAlreadyAdded then removeItemFromAnywhere(player, newSlip) end
        echo(player, false, "Could not consume Blank Pink Slip")
        return
    end

    -- Despawn the original vehicle after the title is ready. If removal fails,
    -- roll the title back so a vehicle and its filled slip cannot both remain.
    if not removeVehicle(vehicle) then
        addItemBack(player, blankSlip)
        if slipAlreadyAdded then removeItemFromAnywhere(player, newSlip) end
        echo(player, false, "Could not remove original vehicle")
        return
    end

    -- Consume the captured key after the vehicle successfully becomes a slip.
    if vehicleKey then removeItemFromAnywhere(player, vehicleKey) end
    if inv.setDrawDirty then inv:setDrawDirty(true) end

    print("[IKappaIDPinkSlip] " .. tostring(ownerName) .. " claimed " .. tostring(snap.scriptName)
        .. " uid=" .. tostring(uid) .. " vehicleUid=" .. tostring(vehicleUid))
    echo(player, true, "Pink Slip issued: " .. M.describeSnapshot(snap))
end

-- =========================================================================
-- DEPLOY
-- =========================================================================

local function handleRegisterSlip(player, args)
    if not M.isEnabled() then
        echo(player, false, "Pink Slip system is disabled")
        return
    end
    if not player then return end

    local uid = args and args.slipUid or nil
    if not uid or uid == "" then
        echo(player, false, "Slip UID missing")
        return
    end

    local slip = findFilledSlipByUid(player, uid)
    if not slip then
        echo(player, false, "Pink Slip not found in your inventory")
        return
    end

    local snap = M.readSlipSnapshot(slip)
    if not snap or not snap.scriptName or snap.scriptName == "" then
        echo(player, false, "Pink Slip is empty or corrupt")
        return
    end
    M.ensureSnapshotVehicleUid(snap, M.readSlipVehicleUid(slip) or uid)

    local ownerName = player:getUsername() or ""
    snap.modData = snap.modData or {}
    snap.modData[M.OWNER_LOCK_KEY] = ownerName
    if M.writeSlipPayload(slip, snap, uid, ownerName) then
        echo(player, true, "Pink Slip registered to " .. tostring(ownerName))
        return
    end
    echo(player, false, "Could not register Pink Slip")
end

local function handleDeploy(player, args)
    if not M.isEnabled() then
        echo(player, false, "Pink Slip system is disabled")
        return
    end
    if not player then return end

    local uid = args and args.slipUid or nil
    if not uid or uid == "" then
        echo(player, false, "Slip UID missing")
        return
    end

    local okCurrentVehicle, currentVehicle = tryCall(function() return player:getVehicle() end, "resolve deploy player vehicle")
    if not okCurrentVehicle then
        echo(player, false, "Could not verify player vehicle state")
        return
    end
    if currentVehicle then
        echo(player, false, "Cannot deploy from inside a vehicle")
        return
    end

    local slip = findFilledSlipByUid(player, uid)
    if not slip then
        echo(player, false, "Pink Slip not found in your inventory")
        return
    end

    local snap = M.readSlipSnapshot(slip)
    if not snap or not snap.scriptName or snap.scriptName == "" then
        echo(player, false, "Pink Slip is empty or corrupt")
        return
    end
    local vehicleUid = M.ensureSnapshotVehicleUid(snap, M.readSlipVehicleUid(slip) or uid)

    -- Optional owner lock: only the registered owner can deploy.
    if M.ownerLockOnDeploy() then
        local stamped = snap.modData and snap.modData[M.OWNER_LOCK_KEY] or nil
        if stamped and stamped ~= "" and stamped ~= player:getUsername() then
            echo(player, false, "Pink Slip is owned by " .. tostring(stamped))
            return
        end
    end

    if not removeItemFromAnywhere(player, slip) then
        echo(player, false, "Could not consume Pink Slip")
        return
    end

    -- Spawn.
    local vehicle, err = spawnVehicleForPlayer(player, snap)
    if not vehicle then
        addItemBack(player, slip)
        echo(player, false, "Spawn failed: " .. tostring(err or "unknown"))
        return
    end

    -- Apply captured state.
    M.applySnapshotToVehicle(vehicle, snap)
    safeCall(function()
        local md = vehicle.getModData and vehicle:getModData() or nil
        if type(md) == "table" and vehicleUid then md[M.VEHICLE_UID_KEY] = vehicleUid end
        if vehicle.transmitModData then vehicle:transmitModData() end
    end, nil, "stamp deployed vehicle uid")

    if snap.hasKey then
        local okKey = tryCall(function()
            if vehicle.createVehicleKey then
                local newKey = vehicle:createVehicleKey()
                if newKey then
                    if player.sendObjectChange then
                        player:sendObjectChange("addItem", { item = newKey })
                    elseif player:getInventory() then
                        player:getInventory():AddItem(newKey)
                    end
                end
            end
        end, "create deployed vehicle key")
        if not okKey then
            echo(player, false, "Vehicle deployed, but key restore failed")
        end
    end

    local deployInv = player:getInventory()
    if deployInv and deployInv.setDrawDirty then deployInv:setDrawDirty(true) end

    print("[IKappaIDPinkSlip] " .. tostring(player:getUsername())
        .. " deployed " .. tostring(snap.scriptName)
        .. " uid=" .. tostring(uid) .. " vehicleUid=" .. tostring(vehicleUid))
    echo(player, true, "Vehicle deployed: " .. M.describeSnapshot(snap))
end

-- =========================================================================
-- Dispatch
-- =========================================================================

local function onClientCommand(module, command, player, args)
    if module ~= M.MODULE_ID then return end
    if not player then return end
    if command == M.CMD_CLAIM then
        handleClaim(player, args)
    elseif command == M.CMD_DEPLOY then
        handleDeploy(player, args)
    elseif command == M.CMD_REGISTER then
        handleRegisterSlip(player, args)
    end
end

M.Server = M.Server or {}
M.Server.onClientCommand = onClientCommand

if Events and Events.OnClientCommand then
    Events.OnClientCommand.Add(onClientCommand)
end

-- =========================================================================
-- Init logging on both bootstrap paths so dedicated servers and hosted-host
-- both produce the tagged init line.
-- =========================================================================

local function onServerStarted()
    print("[IKappaIDPinkSlip] OnServerStarted - vehicle claim/deploy ready")
end

if Events then
    if Events.OnServerStarted then Events.OnServerStarted.Add(onServerStarted) end
    if Events.OnGameStart     then Events.OnGameStart.Add(onServerStarted) end
end