--[[
    IKappaIDPinkSlip_VehicleOps.lua
    Shared vehicle spawn / key / despawn helpers (no pcall).
    Used by IKappaID Pink Slip and IKappaID-adjacent mods (e.g. car rental).
]]

require "IKappaIDPinkSlip_Shared"

IKappaPinkSlip = IKappaPinkSlip or {}
local M = IKappaPinkSlip

function M.findSpawnSquareNearPlayer(player)
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

local function findNearestVehicle(player)
    if not player or not getCell then return nil end
    local cell = getCell()
    if not cell or not cell.getVehicles then return nil end
    local vehicles = cell:getVehicles()
    if not vehicles or not vehicles.size then return nil end

    local px, py = player:getX(), player:getY()
    local best, bestDist = nil, 999
    for i = 0, vehicles:size() - 1 do
        local v = vehicles:get(i)
        if v then
            local dx = v:getX() - px
            local dy = v:getY() - py
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist < bestDist then
                bestDist = dist
                best = v
            end
        end
    end
    if bestDist <= 4 then return best end
    return nil
end

function M.applyConditionAndFuel(vehicle, conditionPercent, fuelPercent)
    if not vehicle then return end
    conditionPercent = math.max(1, math.min(100, tonumber(conditionPercent) or 70))
    fuelPercent = math.max(0, math.min(100, tonumber(fuelPercent) or 50))

    if vehicle.getPartCount then
        for i = 0, vehicle:getPartCount() - 1 do
            local part = vehicle:getPartByIndex(i)
            if part and part.setCondition and part.getConditionMax then
                local maxC = part:getConditionMax()
                if maxC and maxC > 0 then
                    part:setCondition(math.floor(maxC * conditionPercent / 100))
                    if part.transmitPartItem then part:transmitPartItem() end
                end
            end
        end
    end

    if vehicle.getPartById then
        local gas = vehicle:getPartById("GasTank")
        if gas and gas.setContainerContentAmount and gas.getContainerCapacity then
            local cap = gas:getContainerCapacity()
            if cap and cap > 0 then
                gas:setContainerContentAmount(cap * fuelPercent / 100)
                if gas.transmitPartItem then gas:transmitPartItem() end
            end
        end
    end

    if vehicle.setEngineFeature then
        vehicle:setEngineFeature(4, math.floor(conditionPercent * 10), math.floor(conditionPercent * 10))
        if vehicle.transmitEngine then vehicle:transmitEngine() end
    end
end

--- Spawn a vehicle by script name adjacent to the player. Returns vehicle, errorText.
function M.spawnVehicleByScript(player, scriptName, skinIndex, conditionPercent, fuelPercent)
    if not player then return nil, "No player" end
    scriptName = tostring(scriptName or "")
    if scriptName == "" then return nil, "Missing vehicle script" end
    if not addVehicleDebug then return nil, "addVehicleDebug not available" end

    local square = M.findSpawnSquareNearPlayer(player)
    if not square then return nil, "Could not find spawn square" end

    local dir = IsoDirections and IsoDirections.S or nil
    if player.getDir then
        local playerDir = player:getDir()
        if playerDir then dir = playerDir end
    end

    local vehicle = addVehicleDebug(scriptName, dir, skinIndex or -1, square)
    if not vehicle then
        vehicle = findNearestVehicle(player)
    end
    if vehicle and vehicle.getId and getVehicleById then
        local vehicleId = vehicle:getId()
        if vehicleId then
            local refreshed = getVehicleById(vehicleId)
            if refreshed then vehicle = refreshed end
        end
    end
    if not vehicle then
        return nil, "Could not resolve spawned vehicle"
    end

    if conditionPercent or fuelPercent then
        M.applyConditionAndFuel(vehicle, conditionPercent, fuelPercent)
    end
    return vehicle, nil
end

function M.giveVehicleKey(player, vehicle)
    if not player or not vehicle or not vehicle.createVehicleKey then
        return false, "Missing player or vehicle"
    end
    local key = vehicle:createVehicleKey()
    if not key then return false, "Could not create vehicle key" end
    local inv = player:getInventory()
    if not inv then return false, "No inventory" end
    local added = inv:AddItem(key)
    if not added then return false, "Could not add key to inventory" end
    if sendAddItemToContainer then sendAddItemToContainer(inv, added) end
    return true, nil
end

function M.removeRenterKey(player, vehicle)
    if not player or not vehicle or not vehicle.getKeyId then return end
    local keyId = vehicle:getKeyId()
    if not keyId then return end
    local inv = player:getInventory()
    if not inv or not inv.haveThisKeyId or not inv.getItemsFromType then return end
    if not inv:haveThisKeyId(keyId) then return end
    local items = inv:getItemsFromType("Base.CarKey", true)
    if not items or not items.size then return end
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and item.getKeyId and item:getKeyId() == keyId then
            inv:Remove(item)
            if sendRemoveItemFromContainer then sendRemoveItemFromContainer(inv, item) end
            break
        end
    end
end

function M.ejectVehicleOccupants(vehicle)
    if not vehicle or not vehicle.getMaxPassengers then return end
    local maxPassengers = vehicle:getMaxPassengers()
    if not maxPassengers or maxPassengers <= 0 then return end
    for seat = 0, maxPassengers - 1 do
        if vehicle.getCharacter then
            local occupant = vehicle:getCharacter(seat)
            if occupant and occupant.setVehicle then
                occupant:setVehicle(nil)
            end
        end
    end
end

function M.removeVehicleFromWorld(vehicle, ejectFirst)
    if not vehicle then return false end
    if ejectFirst then M.ejectVehicleOccupants(vehicle) end
    if vehicle.permanentlyRemove then
        vehicle:permanentlyRemove()
        return true
    end
    if vehicle.removeFromWorld then vehicle:removeFromWorld() end
    if vehicle.removeFromSquare then vehicle:removeFromSquare() end
    return true
end

function M.isRentalTaggedVehicle(vehicle)
    if not vehicle or not vehicle.getModData then return false end
    local modData = vehicle:getModData()
    if not modData then return false end
    return modData.IKappaIDRental_uid ~= nil or modData.CatRental_uid ~= nil
end

return M
