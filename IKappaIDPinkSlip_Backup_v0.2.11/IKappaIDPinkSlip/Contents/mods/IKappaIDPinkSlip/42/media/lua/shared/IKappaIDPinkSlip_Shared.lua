--[[
    IKappaIDPinkSlip_Shared.lua
    -------------------------------------------------------------------------
    Shared helpers + module constants. Loaded on both client and server.

    Design (v0.2.0):
      * The filled `PinkSlip` IS the vehicle's storage. There is no registry.
        Claim despawns the vehicle and writes a full state snapshot into the
        slip's modData. Deploy reads that snapshot and respawns the vehicle.
      * State capture is best-effort via public Java getters (Lua cannot
        reach BaseVehicle's native ByteBuffer save path). Optional Java calls
        go through safeCall so failures are labeled instead of swallowed.
      * MP identity uses server-issued UIDs stored in the slip's modData.
        The slip UID identifies the physical title item; the vehicle UID tags
        the vehicle lifecycle across claim/deploy cycles. Deploy is
        server-authoritative: the server resolves the slip from the requesting
        player's inventory by UID, never trusting client-supplied snapshot data.
]]

IKappaPinkSlip = IKappaPinkSlip or {}
local M = IKappaPinkSlip

-- =========================================================================
-- Constants
-- =========================================================================

M.MODULE_ID        = "IKappaIDPinkSlip"
M.SCHEMA_VERSION   = 1
M.BLANK_SLIP_TYPE  = "IKappaIDPinkSlip.BlankPinkSlip"
M.FILLED_SLIP_TYPE = "IKappaIDPinkSlip.PinkSlip"
M.SLIP_DATA_KEY    = "IKappaPinkSlip"   -- modData key on filled slip
M.OWNER_LOCK_KEY   = "IKappaPinkSlipOwner" -- modData key on respawned vehicle
M.VEHICLE_UID_KEY  = "IKappaPinkSlipVehicleUid" -- modData key on respawned vehicle

-- Server -> client commands
M.CMD_RESULT       = "PinkSlipResult"
M.CMD_DEPLOY_LIST  = "PinkSlipDeployList"

-- Client -> server commands
M.CMD_CLAIM        = "ClaimVehicle"
M.CMD_DEPLOY       = "DeployVehicle"
M.CMD_LIST_SLIPS   = "ListSlips"
M.CMD_REGISTER     = "RegisterSlip"

-- Optional addon IKappaIDPinkSlipLoot: second item type, same modData / UID keys.
M.LOOT_FILLED_SLIP_TYPE = "IKappaIDPinkSlipLoot.PinkSlipLoot"

function M.isFilledSlipFullType(fullType)
    if not fullType then return false end
    local s = tostring(fullType)
    if s == M.FILLED_SLIP_TYPE then return true end
    if M.LOOT_FILLED_SLIP_TYPE and s == M.LOOT_FILLED_SLIP_TYPE then return true end
    return false
end

function M.isFilledSlipItem(item)
    if not item or not item.getFullType then return false end
    local ok, ft = pcall(function() return item:getFullType() end)
    if not ok or ft == nil then return false end
    return M.isFilledSlipFullType(ft)
end

-- =========================================================================
-- Sandbox accessors (defaults so SP/standalone testing works without
-- the sandbox file being merged)
-- =========================================================================

function M.getSandbox()
    return SandboxVars and SandboxVars.IKappaIDPinkSlip or nil
end

function M.isEnabled()
    local sb = M.getSandbox()
    if sb and sb.Enable ~= nil then return sb.Enable end
    return true
end

function M.getMaxFilledSlips()
    local sb = M.getSandbox()
    if sb and tonumber(sb.MaxFilledSlipsPerPlayer) then
        return tonumber(sb.MaxFilledSlipsPerPlayer)
    end
    return 5
end

function M.getClaimDistance()
    local sb = M.getSandbox()
    if sb and tonumber(sb.ClaimDistance) then
        return tonumber(sb.ClaimDistance)
    end
    return 5.0
end

function M.requireEmptyVehicle()
    local sb = M.getSandbox()
    if sb and sb.RequireEmptyVehicle ~= nil then return sb.RequireEmptyVehicle end
    return true
end

function M.ownerLockOnDeploy()
    local sb = M.getSandbox()
    if sb and sb.OwnerLockOnDeploy ~= nil then return sb.OwnerLockOnDeploy end
    return false
end

function M.showQuickButton()
    local sb = M.getSandbox()
    if sb and sb.ShowQuickButton ~= nil then return sb.ShowQuickButton end
    return false
end

function M.movableQuickButton()
    local sb = M.getSandbox()
    if sb and sb.MovableQuickButton ~= nil then return sb.MovableQuickButton end
    return true
end

-- =========================================================================
-- Internal protected-call helpers
-- =========================================================================

local function fallbackCallLabel(fn)
    if debug and debug.getinfo then
        local info = debug.getinfo(fn, "Sl")
        if info and info.short_src and info.linedefined then
            return "protected call " .. tostring(info.short_src) .. ":" .. tostring(info.linedefined)
        end
    end
    return "protected call"
end

local function tryCall(fn, label)
    local ok, v = pcall(fn)
    if ok then return true, v end
    print("[IKappaIDPinkSlip] " .. tostring(label or fallbackCallLabel(fn)) .. " failed: " .. tostring(v))
    return false, v
end
M.tryCall = tryCall

local function safeCall(fn, default, label)
    local ok, v = tryCall(fn, label)
    if ok then return v end
    return default
end
M.safeCall = safeCall

function M.createItem(fullType)
    if not fullType or fullType == "" then return nil end
    if not instanceItem then
        print("[IKappaIDPinkSlip] instanceItem unavailable; cannot create " .. tostring(fullType))
        return nil
    end
    local ok, item = tryCall(function() return instanceItem(fullType) end, "create item " .. tostring(fullType))
    if ok and item then return item end
    return nil
end

-- =========================================================================
-- Item state capture / restore
-- =========================================================================

local function callGetter(obj, methodName, default, label)
    if not obj or not methodName or not obj[methodName] then return default end
    return safeCall(function() return obj[methodName](obj) end, default, label)
end

local function captureItem(item)
    if not item then return nil end
    local fullType = callGetter(item, "getFullType", nil, "capture item full type")
    if not fullType or fullType == "" then return nil end
    local data = {
        fullType  = tostring(fullType),
        condition = callGetter(item, "getCondition", nil, "capture item condition"),
        usedDelta = callGetter(item, "getUsedDelta", nil, "capture item used delta"),
    }
    return data
end

local function captureContainer(part)
    if not part then return nil end
    local container = callGetter(part, "getItemContainer", nil, "capture part container")
    if not container then return nil end
    local items = callGetter(container, "getItems", nil, "capture container items")
    if not items or not items.size or not items.get then return {} end
    local out = {}
    local n = callGetter(items, "size", 0, "capture container size") or 0
    for i = 0, n - 1 do
        local it = safeCall(function() return items:get(i) end, nil, "capture container item")
        local rec = captureItem(it)
        if rec then out[#out + 1] = rec end
    end
    return out
end

-- =========================================================================
-- Vehicle (de)serialization
-- =========================================================================

function M.serializeVehicle(vehicle)
    if not vehicle then return nil end
    local snap = {
        schemaVersion  = M.SCHEMA_VERSION,
        capturedAt     = (os and os.time and os.time()) or 0,
        scriptName     = "",
        skinIndex      = -1,
        rust           = nil,
        engineQuality  = nil,
        enginePower    = nil,
        engineLoudness = nil,
        hotwired       = nil,
        hasKey         = false,
        color          = nil,
        parts          = {},
        modData        = {},
    }

    snap.scriptName = safeCall(function()
        local sc = vehicle:getScript()
        if sc and sc.getName then return tostring(sc:getName() or "") end
        return ""
    end, "")
    if snap.scriptName == "" then
        -- Fallback: some builds expose getScriptName directly.
        snap.scriptName = safeCall(function()
            return tostring(vehicle:getScriptName() or "")
        end, "")
    end

    snap.skinIndex      = safeCall(function() return vehicle:getSkinIndex() end, -1) or -1
    snap.rust           = safeCall(function() return vehicle:getRust() end, nil)
    snap.engineQuality  = safeCall(function() return vehicle:getEngineQuality() end, nil)
    snap.enginePower    = safeCall(function() return vehicle:getEnginePower() end, nil)
    snap.engineLoudness = safeCall(function() return vehicle:getEngineLoudness() end, nil)
    snap.hotwired       = safeCall(function() return vehicle:isHotwired() end, nil)

    if not snap.enginePower then
        snap.enginePower = safeCall(function()
            local sc = vehicle:getScript()
            return sc and sc:getEngineForce() or nil
        end, nil)
    end
    if not snap.engineLoudness then
        snap.engineLoudness = safeCall(function()
            local sc = vehicle:getScript()
            return sc and sc:getEngineLoudness() or nil
        end, nil)
    end

    -- Color: HSV is the documented vanilla path on BaseVehicle.
    snap.color = safeCall(function()
        if vehicle.getColorHue then
            return {
                h = vehicle:getColorHue(),
                s = vehicle.getColorSaturation and vehicle:getColorSaturation() or nil,
                v = vehicle.getColorValue and vehicle:getColorValue() or nil,
            }
        end
        return nil
    end, nil)

    -- Parts
    local nparts = callGetter(vehicle, "getPartCount", 0, "capture vehicle part count") or 0
    for i = 0, nparts - 1 do
        local part = nil
        if vehicle.getPartByIndex then
            part = safeCall(function() return vehicle:getPartByIndex(i) end, nil, "capture vehicle part index " .. tostring(i))
        end
        if part then
            local pid = callGetter(part, "getId", nil, "capture part id")
            if pid and pid ~= "" then
                local rec = {
                    id        = tostring(pid),
                    condition = callGetter(part, "getCondition", nil, "capture part condition " .. tostring(pid)),
                    item      = captureItem(callGetter(part, "getInventoryItem", nil, "capture part item " .. tostring(pid))),
                    container = captureContainer(part),
                    content   = safeCall(function()
                        if part.isContainer and part:isContainer() and part.getContainerContentAmount then
                            return part:getContainerContentAmount()
                        end
                        return nil
                    end, nil),
                }
                snap.parts[#snap.parts + 1] = rec
            end
        end
    end

    -- Vehicle-level modData: shallow copy of primitives only (Java's
    -- modData serializer cannot preserve nested Lua tables reliably).
    safeCall(function()
        local md = vehicle:getModData()
        if type(md) == "table" then
            for k, v in pairs(md) do
                local t = type(v)
                if t == "string" or t == "number" or t == "boolean" then
                    snap.modData[k] = v
                end
            end
        end
    end, nil)

    return snap
end

local function transmitPart(vehicle, part, kind)
    if not vehicle or not part then return end
    local methodByKind = {
        item      = "transmitPartItem",
        condition = "transmitPartCondition",
        modData   = "transmitPartModData",
        usedDelta = "transmitPartUsedDelta",
    }
    local method = methodByKind[kind]
    if method and vehicle[method] then
        safeCall(function() vehicle[method](vehicle, part) end, nil, "transmit " .. method)
    end
end

local function callPartHook(vehicle, part, hookName)
    if not vehicle or not part or not hookName then return end
    local tbl = nil
    if part.getTable then
        tbl = safeCall(function() return part:getTable(hookName) end, nil, "resolve " .. tostring(hookName) .. " part hook")
    end
    if tbl and tbl.complete and VehicleUtils and VehicleUtils.callLua then
        safeCall(function() VehicleUtils.callLua(tbl.complete, vehicle, part) end, nil, hookName .. " part hook")
    end
end

-- Apply a captured snapshot to a freshly-spawned vehicle. Best-effort.
function M.applySnapshotToVehicle(vehicle, snap)
    if not vehicle or type(snap) ~= "table" then return false end

    if snap.skinIndex ~= nil and snap.skinIndex >= 0 then
        safeCall(function() vehicle:setSkinIndex(snap.skinIndex) end, nil, "restore skin")
    end
    if snap.rust ~= nil then
        safeCall(function() vehicle:setRust(snap.rust) end, nil, "restore rust")
    end
    if snap.engineQuality ~= nil and snap.enginePower ~= nil then
        safeCall(function()
            vehicle:setEngineFeature(snap.engineQuality or 0, snap.engineLoudness or 0, snap.enginePower or 0)
            if vehicle.transmitEngine then vehicle:transmitEngine() end
        end, nil, "restore engine")
    end
    if snap.color and snap.color.h ~= nil then
        safeCall(function()
            vehicle:setColorHSV(snap.color.h, snap.color.s or 0.5, snap.color.v or 0.5)
            if vehicle.transmitColorHSV then vehicle:transmitColorHSV() end
        end, nil, "restore color")
    end
    if snap.hotwired ~= nil then
        safeCall(function()
            if vehicle.setHotwired then vehicle:setHotwired(snap.hotwired and true or false) end
        end, nil, "restore hotwire")
    end

    if type(snap.parts) == "table" then
        for _, rec in ipairs(snap.parts) do
            local part = nil
            if vehicle.getPartById then
                part = safeCall(function() return vehicle:getPartById(rec.id) end, nil, "resolve part " .. tostring(rec.id))
            end
            if part then
                if rec.condition ~= nil and part.setCondition then
                    safeCall(function()
                        part:setCondition(rec.condition)
                        transmitPart(vehicle, part, "condition")
                    end, nil, "restore part condition " .. tostring(rec.id))
                end
                if rec.item and rec.item.fullType then
                    safeCall(function()
                        local newItem = M.createItem(rec.item.fullType)
                        if newItem and part.setInventoryItem then
                            if rec.item.condition ~= nil and newItem.setCondition then
                                safeCall(function() newItem:setCondition(rec.item.condition) end, nil, "restore item condition")
                            end
                            if rec.item.usedDelta ~= nil and newItem.setUsedDelta then
                                safeCall(function() newItem:setUsedDelta(rec.item.usedDelta) end, nil, "restore item delta")
                            end
                            if part.getInventoryItem and part:getInventoryItem() then
                                part:setInventoryItem(nil)
                                transmitPart(vehicle, part, "item")
                            end
                            part:setInventoryItem(newItem)
                            callPartHook(vehicle, part, "install")
                            transmitPart(vehicle, part, "item")
                            if rec.item.usedDelta ~= nil then transmitPart(vehicle, part, "usedDelta") end
                        end
                    end, nil, "restore part item " .. tostring(rec.id))
                else
                    safeCall(function()
                        if part.getInventoryItem and part.setInventoryItem and part:getInventoryItem() then
                            part:setInventoryItem(nil)
                            callPartHook(vehicle, part, "uninstall")
                            transmitPart(vehicle, part, "item")
                        end
                    end, nil, "remove missing part item " .. tostring(rec.id))
                end
                if rec.content ~= nil then
                    safeCall(function()
                        if part.setContainerContentAmount then
                            part:setContainerContentAmount(rec.content)
                            local wheelIndex = part.getWheelIndex and part:getWheelIndex() or -1
                            if wheelIndex ~= -1 and vehicle.setTireInflation
                                and part.getContainerCapacity and part.getContainerContentAmount
                                and part:getContainerCapacity() > 0 then
                                vehicle:setTireInflation(wheelIndex, part:getContainerContentAmount() / part:getContainerCapacity())
                            end
                        end
                    end, nil, "restore part content " .. tostring(rec.id))
                end
                if type(rec.container) == "table" then
                    local container = callGetter(part, "getItemContainer", nil, "resolve part container " .. tostring(rec.id))
                    if container then
                        safeCall(function()
                            if container.removeAllItems then container:removeAllItems() end
                        end, nil, "clear part container " .. tostring(rec.id))
                        for _, ir in ipairs(rec.container) do
                            safeCall(function()
                                local it = M.createItem(ir.fullType)
                                if it then
                                    if ir.condition ~= nil and it.setCondition then
                                        safeCall(function() it:setCondition(ir.condition) end, nil, "restore container item condition")
                                    end
                                    if ir.usedDelta ~= nil and it.setUsedDelta then
                                        safeCall(function() it:setUsedDelta(ir.usedDelta) end, nil, "restore container item delta")
                                    end
                                    if container.AddItem then
                                        container:AddItem(it)
                                        if sendAddItemToContainer then sendAddItemToContainer(container, it) end
                                    end
                                end
                            end, nil, "restore container item " .. tostring(ir and ir.fullType))
                        end
                    end
                end
                transmitPart(vehicle, part, "modData")
            end
        end
    end

    -- Restore vehicle modData primitives.
    safeCall(function()
        local md = vehicle:getModData()
        if type(md) == "table" and type(snap.modData) == "table" then
            for k, v in pairs(snap.modData) do md[k] = v end
        end
    end, nil, "restore vehicle modData")

    safeCall(function()
        if vehicle.transmitModData then vehicle:transmitModData() end
    end, nil, "transmit vehicle modData")

    return true
end

-- =========================================================================
-- Slip identity / labels
-- =========================================================================

-- Build a UID for a freshly-minted slip. Server-only path; uses os.time +
-- a per-player counter held on the player's modData so two slips minted in
-- the same second still have unique UIDs.
function M.mintSlipUid(player)
    local username = (player and player.getUsername and player:getUsername()) or "?"
    local md = player and player.getModData and player:getModData() or nil
    local n = 0
    if md then
        n = (tonumber(md.IKappaPinkSlip_Counter) or 0) + 1
        md.IKappaPinkSlip_Counter = n
    end
    local t = (os and os.time and os.time()) or 0
    return tostring(username) .. "_" .. tostring(t) .. "_" .. tostring(n)
end

function M.readSnapshotVehicleUid(snap)
    if type(snap) ~= "table" then return nil end
    if snap.vehicleUid and snap.vehicleUid ~= "" then return tostring(snap.vehicleUid) end
    if type(snap.modData) == "table" then
        local uid = snap.modData[M.VEHICLE_UID_KEY]
        if uid and uid ~= "" then return tostring(uid) end
    end
    return nil
end

function M.setSnapshotVehicleUid(snap, uid)
    if type(snap) ~= "table" or not uid or uid == "" then return nil end
    snap.vehicleUid = tostring(uid)
    snap.modData = snap.modData or {}
    snap.modData[M.VEHICLE_UID_KEY] = tostring(uid)
    return tostring(uid)
end

function M.ensureSnapshotVehicleUid(snap, fallbackUid)
    local uid = M.readSnapshotVehicleUid(snap)
    if uid then return M.setSnapshotVehicleUid(snap, uid) end
    return M.setSnapshotVehicleUid(snap, fallbackUid)
end

-- Friendly label for a slip's snapshot, used for radial/HUD text.
function M.describeSnapshot(snap)
    if type(snap) ~= "table" then return "Pink Slip (empty)" end
    local label = snap.scriptName or ""
    if label == "" then label = "Vehicle" end
    -- Strip leading "Base." for readability.
    label = label:gsub("^Base%.", "")
    if type(snap.modData) == "table" and snap.modData[M.OWNER_LOCK_KEY] then
        label = label .. " [" .. tostring(snap.modData[M.OWNER_LOCK_KEY]) .. "]"
    end
    return label
end

-- Read the snapshot stored on a slip InventoryItem. Returns nil if empty.
function M.readSlipSnapshot(item)
    if not item or not item.getModData then return nil end
    local md = safeCall(function() return item:getModData() end, nil)
    if type(md) ~= "table" then return nil end
    local snap = md[M.SLIP_DATA_KEY]
    if type(snap) == "table" and snap.scriptName then return snap end
    return nil
end

function M.readSlipUid(item)
    if not item or not item.getModData then return nil end
    local md = safeCall(function() return item:getModData() end, nil)
    if type(md) ~= "table" then return nil end
    local uid = md[M.SLIP_DATA_KEY .. "_uid"]
    if uid and uid ~= "" then return tostring(uid) end
    return nil
end

function M.readSlipVehicleUid(item)
    if not item or not item.getModData then return nil end
    local md = safeCall(function() return item:getModData() end, nil)
    if type(md) ~= "table" then return nil end
    local uid = md[M.SLIP_DATA_KEY .. "_vehicle_uid"]
    if uid and uid ~= "" then return tostring(uid) end
    return M.readSnapshotVehicleUid(md[M.SLIP_DATA_KEY])
end

function M.writeSlipPayload(item, snap, uid, ownerName)
    if not item or not item.getModData then return false end
    local md = safeCall(function() return item:getModData() end, nil)
    if type(md) ~= "table" then return false end

    local vehicleUid = M.ensureSnapshotVehicleUid(snap, md[M.SLIP_DATA_KEY .. "_vehicle_uid"] or uid)
    md[M.SLIP_DATA_KEY] = snap
    md[M.SLIP_DATA_KEY .. "_uid"] = uid
    md[M.SLIP_DATA_KEY .. "_vehicle_uid"] = vehicleUid
    md[M.SLIP_DATA_KEY .. "_owner"] = ownerName

    -- Name: vehicle only (no owner)
    -- Tooltip: includes owner + vehicle info
    safeCall(function()
        local rawScript = (type(snap) == "table" and snap.scriptName) or "Vehicle"
        local vehicleLabel = tostring(rawScript or "Vehicle"):gsub("^Base%.", "")
        if vehicleLabel == "" then vehicleLabel = "Vehicle" end

        local customName = "Pink Slip - " .. vehicleLabel
        if item.setName then item:setName(customName) end
        if item.setCustomName then item:setCustomName(true) end

        local ownerLabel = tostring(ownerName or "")
        local tooltip = "Stored vehicle: " .. vehicleLabel
        if ownerLabel ~= "" then
            tooltip = tooltip .. "\nRegistered owner: " .. ownerLabel
        end
        if item.setTooltip then item:setTooltip(tooltip) end
    end, nil, "set filled slip name/tooltip")

    safeCall(function() if item.transmitModData then item:transmitModData() end end, nil, "transmit slip modData")
    safeCall(function() if sendItemStats then sendItemStats(item) end end, nil, "sync slip item stats")
    return true
end

return M