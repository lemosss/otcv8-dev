-- =============================================================================
-- Create-Shop window: lets the seller pick items + prices from a grid layout
-- (mirrors the buyer view structure), then dispatches OPCODE_SHOP_OPEN to the
-- server.
-- =============================================================================

createWindow = nil
inventoryList = {}      -- snapshot received from server
slots = {}              -- [slotIndex] = { entryUid, entryId, serverId, count, charges, price, stackable, widget }

local MAX_SLOTS = 20
local selectedSlotIndex = nil
-- Set true by openCreateShop when there's a cached `lastSavedSlots` from a
-- previous attempt (e.g. server rejected the OPEN with "Invalid price ..."):
-- once the inventory list arrives we walk the cache and re-fill the grid so
-- the seller doesn't have to redo all picks/prices from scratch.
local pendingRestoreDraft = false

-- ----------------------------------------------------------------------------
-- Slot grid (replaces the old vertical list of ShopSlot rows).
-- ----------------------------------------------------------------------------

local function isFilled(s)
    return s and s.entryId ~= nil
end

local function refreshSummary()
    if not createWindow then return end
    local lbl = createWindow:recursiveGetChildById('summaryLbl')
    if not lbl then return end
    local total, count = 0, 0
    for _, s in pairs(slots) do
        if isFilled(s) then
            count = count + 1
            total = total + (s.price or 0) * (s.count or 1)
        end
    end
    lbl:setText(('%d items, total: %d gold'):format(count, total))
end

local function refreshInfoPanel()
    if not createWindow then return end
    local nameLbl    = createWindow:recursiveGetChildById('slotName')
    local priceEdit  = createWindow:recursiveGetChildById('slotPriceEdit')
    local amountLbl  = createWindow:recursiveGetChildById('slotAmountLbl')
    local removeBtn  = createWindow:recursiveGetChildById('slotRemoveBtn')
    local previewItem= createWindow:recursiveGetChildById('previewItem')
    local descText   = createWindow:recursiveGetChildById('descText')

    local s = selectedSlotIndex and slots[selectedSlotIndex] or nil
    if not isFilled(s) then
        nameLbl:setText('None selected')
        priceEdit:setText('')
        priceEdit:setEnabled(false)
        amountLbl:setText('Amount: -')
        removeBtn:setEnabled(false)
        previewItem:setItemId(0)
        descText:setText('-')
        return
    end

    nameLbl:setText(s.name or 'item')
    priceEdit:setEnabled(true)
    priceEdit:setText(tostring(s.price or 0))
    amountLbl:setText(('Amount: %dx'):format(s.count or 1))
    removeBtn:setEnabled(true)
    previewItem:setItemId(s.entryId)
    previewItem:setItemCount(s.count or 1)
    descText:setText(('You see %s.\nQty in shop: %d.'):format(
        s.name or 'this item', s.count or 1))
end

-- Walk every cell and reset border to 0; paint the chosen one with white.
local function highlightSlotCell(cell)
    if not createWindow then return end
    local panel = createWindow:recursiveGetChildById('slotsPanel')
    if not panel then return end
    for _, sib in ipairs(panel:getChildren()) do sib:setBorderWidth(0) end
    if cell then
        cell:setBorderColor('#ffffff')
        cell:setBorderWidth(2)
    end
end

local function selectSlot(index)
    selectedSlotIndex = index
    local s = slots[index]
    highlightSlotCell(s and s.widget or nil)
    refreshInfoPanel()
end

local function setCellEmpty(cell)
    cell.cellItem:setItemId(0)
    cell.cellPlus:setVisible(true)
end

local function setCellFilled(cell, entryId, count)
    cell.cellItem:setItemId(entryId)
    cell.cellItem:setItemCount(count)
    cell.cellPlus:setVisible(false)
end

local function buildSlotCell(index)
    local panel = createWindow:recursiveGetChildById('slotsPanel')
    local cell = g_ui.createWidget('ShopSellerCell', panel)
    cell.cellItem = cell:getChildById('cellItem')
    cell.cellPlus = cell:getChildById('cellPlus')
    cell.slotIndex = index
    setCellEmpty(cell)

    cell.onClick = function(self)
        local s = slots[index]
        if isFilled(s) then
            selectSlot(index)
        else
            -- Empty: open the picker which will eventually call assignItemDirect.
            selectedSlotIndex = index
            highlightSlotCell(self)
            openItemPicker(index)
        end
    end
    cell.onDoubleClick = cell.onClick

    slots[index] = { widget = cell }
    return cell
end

local function clearAllSlots()
    if not createWindow then return end
    local panel = createWindow:recursiveGetChildById('slotsPanel')
    if panel then panel:destroyChildren() end
    slots = {}
    selectedSlotIndex = nil
end

-- Counts cells currently in the grid (filled + empty placeholders).
local function totalSlots()
    local n = 0
    for _ in pairs(slots) do n = n + 1 end
    return n
end

-- Returns the highest slot index in use.
local function maxIndex()
    local hi = 0
    for i in pairs(slots) do if i > hi then hi = i end end
    return hi
end

-- Ensure exactly one trailing empty `+` cell exists at the end (unless we're
-- at MAX_SLOTS already). Called after every fill / remove so the user always
-- has a `+` cell to click to add a new item, and never sees more empty slots
-- than they need.
local function ensureTrailingPlus()
    if not createWindow then return end
    -- Find an existing empty slot
    local empties = {}
    for i, s in pairs(slots) do
        if not isFilled(s) then empties[#empties + 1] = i end
    end
    if #empties == 0 then
        -- No empty cell -> add one at the end (if room)
        if totalSlots() < MAX_SLOTS then
            buildSlotCell(maxIndex() + 1)
        end
    elseif #empties > 1 then
        -- More than one empty -> keep the highest, remove the rest
        table.sort(empties)
        for i = 1, #empties - 1 do
            local s = slots[empties[i]]
            if s and s.widget then s.widget:destroy() end
            slots[empties[i]] = nil
        end
    end
end

function buildEmptySlots()
    clearAllSlots()
    buildSlotCell(1)  -- start with one `+` cell
    refreshSummary()
    refreshInfoPanel()
end

-- ----------------------------------------------------------------------------
-- Restore the previously-attempted shop draft after the inventory list
-- arrives. Triggered when the server rejected the OPEN payload (invalid
-- price, etc.) or simply when the player reopens Create Shop and we still
-- have `lastSavedSlots` cached from the last commit.
--
-- Matching strategy:
--   - non-stackable items: by entryUid (each depot instance is unique)
--   - stackable items: by serverId, clamped to whatever's actually still in
--     the depot now (counts may have shrunk if part of the stack was sold
--     before the previous shop closed).
--
-- Slots that no longer match anything are silently skipped instead of
-- producing phantom cells.
-- ----------------------------------------------------------------------------
local function restoreDraftSlots()
    if not pendingRestoreDraft then return end
    pendingRestoreDraft = false  -- one-shot: don't re-fire on later inv lists
    if not lastSavedSlots then return end
    if not createWindow then return end
    if not inventoryList or #inventoryList == 0 then return end

    -- Index the depot inventory for fast lookup.
    local byUid, byServerId = {}, {}
    for _, e in ipairs(inventoryList) do
        if e.stackable then
            byServerId[e.serverId] = e
        else
            byUid[e.uid] = e
        end
    end

    -- Walk the saved cache in stable slot order so the restored grid keeps
    -- the same visual layout the user had before.
    local indices = {}
    for i in pairs(lastSavedSlots) do indices[#indices + 1] = i end
    table.sort(indices)

    local consumedStack = {}   -- serverId -> already-allocated stackable count
    local consumedUid   = {}   -- uid -> true (non-stackable already taken)

    for _, savedIdx in ipairs(indices) do
        local saved = lastSavedSlots[savedIdx]
        if saved then
            local match
            local count = saved.count or 1
            if saved.uid and saved.uid ~= 0 and byUid[saved.uid] and not consumedUid[saved.uid] then
                match = byUid[saved.uid]
                consumedUid[saved.uid] = true
                count = 1  -- non-stackable instances are always 1
            elseif saved.serverId and saved.serverId ~= 0 then
                local invEntry = byServerId[saved.serverId]
                if invEntry then
                    local already = consumedStack[saved.serverId] or 0
                    local available = (invEntry.count or 1) - already
                    if available > 0 then
                        match = invEntry
                        if count > available then count = available end
                        consumedStack[saved.serverId] = already + count
                    end
                end
            end
            if match and count > 0 then
                -- Find the lowest empty slot index in the current grid.
                local targetIdx
                for i, s in pairs(slots) do
                    if not isFilled(s) then
                        if not targetIdx or i < targetIdx then targetIdx = i end
                    end
                end
                if targetIdx then
                    assignItemDirect(targetIdx, {
                        uid = match.uid,
                        id = match.id,
                        serverId = match.serverId,
                        charges = match.charges,
                        name = match.name,
                        stackable = match.stackable,
                    }, count)
                    -- assignItemDirect set price to 0 (placeholder default);
                    -- write the cached price back so the seller doesn't have
                    -- to re-type it.
                    local s = slots[targetIdx]
                    if s then s.price = saved.price or 0 end
                end
            end
        end
    end

    refreshSummary()
    refreshInfoPanel()
end

-- ----------------------------------------------------------------------------
-- Item assignment (called by the picker after the user picks an item).
-- ----------------------------------------------------------------------------

function assignItemDirect(index, entry, count)
    local s = slots[index]
    if not s or not s.widget then return end
    s.entryUid = entry.uid or 0
    s.stackable = entry.stackable and true or false
    s.entryId  = entry.id            -- clientId (display)
    s.serverId = entry.serverId or 0 -- echoed back to server on OPEN
    s.count    = count
    s.charges  = entry.charges or 0
    s.name     = entry.name
    s.price    = s.price or 0
    setCellFilled(s.widget, entry.id, count)
    selectSlot(index)
    -- That cell just stopped being empty -> add a fresh `+` cell at the end.
    ensureTrailingPlus()
    refreshSummary()
end

function removeSlot(index)
    local s = slots[index]
    if not s or not s.widget then return end
    -- Destroy the widget entirely instead of toggling it to empty -- we
    -- keep exactly ONE trailing `+` placeholder via ensureTrailingPlus().
    s.widget:destroy()
    slots[index] = nil
    if selectedSlotIndex == index then selectedSlotIndex = nil end
    highlightSlotCell(nil)
    -- Make sure there's still a `+` cell to click for new items.
    if totalSlots() == 0 then buildSlotCell(1) end
    ensureTrailingPlus()
    refreshSummary()
    refreshInfoPanel()
end

-- ----------------------------------------------------------------------------
-- Item picker: popup with a grid of items the player has in their DEPOT,
-- aggregated by itemId. User clicks an item, optionally enters quantity for
-- stackables, then it's assigned to the requested slot.
-- ----------------------------------------------------------------------------
local pickerWindow = nil
local pendingSlotIndex = nil
local pickerSelected = nil   -- currently-highlighted PickerCell widget
local pickerSearchText = ''

local function destroyPickerWindow()
    if pickerWindow then pickerWindow:destroy(); pickerWindow = nil end
    pickerSelected = nil
    pickerSearchText = ''
end

local function truncate(text, maxLen)
    if not text then return '' end
    if #text <= maxLen then return text end
    return text:sub(1, maxLen - 1) .. '.'
end

function openItemPicker(slotIndex)
    destroyPickerWindow()
    pendingSlotIndex = slotIndex

    if not inventoryList or #inventoryList == 0 then
        if modules.game_playershop and modules.game_playershop.sendOpcode then
            modules.game_playershop.sendOpcode(OPCODE_INVENTORY_LIST, '')
        end
    end

    pickerWindow = g_ui.createWidget('PickerWindow', rootWidget)
    pickerWindow:setText('Pick item from depot (slot ' .. slotIndex .. ')')

    local cancelBtn = pickerWindow:recursiveGetChildById('pickCancelBtn')
    cancelBtn.onClick = destroyPickerWindow

    local okBtn = pickerWindow:recursiveGetChildById('pickOkBtn')
    okBtn.onClick = function()
        if pickerSelected and pickerSelected.entry then
            promptCountAndAssign(pendingSlotIndex, pickerSelected.entry)
        end
    end

    local searchEdit = pickerWindow:recursiveGetChildById('searchEdit')
    searchEdit.onTextChange = function(self, text)
        pickerSearchText = (text or ''):lower()
        populatePickerList()
    end

    pcall(function()
        g_keyboard.bindKeyPress('Escape', destroyPickerWindow, pickerWindow)
    end)

    pcall(function()
        local panel = pickerWindow:recursiveGetChildById('gridPanel')
        if not panel then return end
        local function tryPopulate()
            if pickerWindow and populatePickerList
                and inventoryList and #inventoryList > 0 then
                populatePickerList()
            end
        end
        tryPopulate()
        connect(panel, { onGeometryChange = function(self, oldRect, newRect)
            tryPopulate()
        end })
    end)
end

local function highlightCell(cell)
    if pickerWindow then
        local panel = pickerWindow:recursiveGetChildById('gridPanel')
        if panel then
            for _, sibling in ipairs(panel:getChildren()) do
                sibling:setBorderWidth(0)
            end
        end
    end
    pickerSelected = cell
    if cell then
        cell:setBorderColor('#ffffff')
        cell:setBorderWidth(2)
    end
    if pickerWindow then
        local okBtn = pickerWindow:recursiveGetChildById('pickOkBtn')
        if okBtn then okBtn:setEnabled(cell ~= nil) end
    end
end

function populatePickerList()
    if not pickerWindow then return end
    local panel = pickerWindow:recursiveGetChildById('gridPanel')
    local emptyHint = pickerWindow:recursiveGetChildById('emptyHintLbl')
    if not panel then return end
    panel:destroyChildren()
    pickerSelected = nil

    do
        local okBtn = pickerWindow:recursiveGetChildById('pickOkBtn')
        if okBtn then okBtn:setEnabled(false) end
    end

    -- For STACKABLES: subtract total already allocated across other slots
    -- (they share the same aggregate stock). For NON-STACKABLES: each
    -- inventory entry is a unique instance; hide it once allocated.
    local allocatedStackById = {}
    local allocatedNonStackUid = {}
    for idx, s in pairs(slots) do
        if idx ~= pendingSlotIndex and isFilled(s) and s.count and s.count > 0 then
            if s.stackable then
                allocatedStackById[s.entryId] = (allocatedStackById[s.entryId] or 0) + s.count
            elseif s.entryUid and s.entryUid ~= 0 then
                allocatedNonStackUid[s.entryUid] = true
            end
        end
    end

    local matches = {}
    for _, e in ipairs(inventoryList or {}) do
        local visible
        local effectiveCount = e.count or 1
        if e.stackable then
            local available = effectiveCount - (allocatedStackById[e.id] or 0)
            visible = available > 0
            if visible then effectiveCount = available end
        else
            visible = not allocatedNonStackUid[e.uid]
        end

        local matchSearch = true
        local q = pickerSearchText or ''
        if q ~= '' then
            local nm = (e.name or ''):lower()
            matchSearch = nm:find(q, 1, true) ~= nil
        end

        if visible and matchSearch then
            matches[#matches + 1] = {
                id = e.id, serverId = e.serverId,
                uid = e.uid, charges = e.charges,
                name = e.name, count = effectiveCount,
                stackable = e.stackable,
            }
        end
    end
    table.sort(matches, function(a, b) return (a.name or '') < (b.name or '') end)

    if #matches == 0 then
        if emptyHint then
            emptyHint:setText(pickerSearchText ~= ''
                and '(no items match the search)'
                or '(your depot is empty)')
            emptyHint:setVisible(true)
        end
        return
    end
    if emptyHint then emptyHint:setVisible(false) end

    for _, e in ipairs(matches) do
        local ok, err = pcall(function()
            local cell = g_ui.createWidget('PickerCell', panel)
            local cellItem = cell:getChildById('cellItem')
            local cellName = cell:getChildById('cellName')

            cellItem:setItemId(e.id)
            cellItem:setItemCount(e.count)
            cellName:setText(truncate(e.name or '', 8))
            cell:setTooltip(('%dx %s\n(id %d)'):format(e.count, e.name or '', e.id))
            cell.entry = e

            cell.onClick = function(self) highlightCell(self) end
            cell.onDoubleClick = function(self)
                highlightCell(self)
                promptCountAndAssign(pendingSlotIndex, e)
            end
        end)
        if not ok then
            print(('[playershop] cell create error id=%s: %s'):format(
                tostring(e.id), tostring(err)))
        end
    end

    if panel.updateLayout then panel:updateLayout() end
end

-- For stackable items, prompt for the quantity (default = full stack). For
-- non-stackable items, count is always 1 (each entry is one instance).
function promptCountAndAssign(slotIndex, entry)
    if not slotIndex or not entry then return end
    local available = entry.count or 1
    if not entry.stackable or available <= 1 then
        assignItemDirect(slotIndex, entry, 1)
        destroyPickerWindow()
        return
    end

    -- Destroy the picker BEFORE creating the qty window so a stale OK click
    -- queued by OTC can't reach an already-gone widget.
    destroyPickerWindow()

    local qtyWindow = g_ui.createWidget('QtyWindow', rootWidget)
    qtyWindow:setText(('How many? (max %d)'):format(available))

    local edit = qtyWindow:recursiveGetChildById('qtyEdit')
    edit:setText(tostring(available))
    edit:focus()
    if edit.selectAll then edit:selectAll() end

    -- ------------------------------------------------------------------
    -- Make the qty dialog effectively modal: while it's alive, the user
    -- cannot click the createWindow (or anything else) to bring it to
    -- front. They MUST click OK / Cancel (or press Enter/Escape).
    --
    -- Implementation: a full-screen transparent overlay sits BELOW
    -- qtyWindow but ABOVE every other window. Clicks outside qtyWindow's
    -- bounds hit the overlay first; the overlay eats them via an
    -- onMousePress that always returns true (consumed). Clicks INSIDE
    -- qtyWindow's bounds hit qtyWindow normally because qtyWindow was
    -- raised above the overlay.
    -- ------------------------------------------------------------------
    local overlay = g_ui.createWidget('UIWidget', rootWidget)
    overlay:fill('parent')
    overlay:setBackgroundColor('#00000000')  -- fully transparent
    overlay:setFocusable(false)
    overlay.onMousePress = function() return true end  -- swallow all clicks
    qtyWindow:raise()
    qtyWindow:focus()

    local destroyed = false
    local function closeQty()
        if destroyed then return end
        destroyed = true
        if overlay then pcall(function() overlay:destroy() end); overlay = nil end
        pcall(function() qtyWindow:destroy() end)
    end

    local function commit()
        if destroyed then return end
        local n = tonumber(edit:getText()) or available
        if n < 1 then n = 1 end
        if n > available then n = available end
        assignItemDirect(slotIndex, entry, n)
        closeQty()
        destroyPickerWindow()
    end

    qtyWindow:recursiveGetChildById('qtyOkBtn').onClick = commit
    qtyWindow:recursiveGetChildById('qtyCancelBtn').onClick = closeQty
    pcall(g_keyboard.bindKeyPress, 'Return', commit, qtyWindow)
    pcall(g_keyboard.bindKeyPress, 'Enter',  commit, qtyWindow)
    pcall(g_keyboard.bindKeyPress, 'Escape', closeQty, qtyWindow)
end

-- ----------------------------------------------------------------------------
-- Open / close the create window
-- ----------------------------------------------------------------------------
function openCreateShop()
    if createWindow then createWindow:show(); createWindow:raise(); return end
    inventoryList = {}
    createWindow = g_ui.displayUI('playershop.otui', rootWidget)
    createWindow = g_ui.createWidget('CreateShopWindow', rootWidget)
    createWindow:show()
    createWindow:raise()
    createWindow:focus()

    buildEmptySlots()

    if lastSavedText then
        createWindow:recursiveGetChildById('shopText'):setText(lastSavedText)
    end

    -- If we still have slots cached from a previous attempt (e.g. the server
    -- rejected it for "Invalid price item slot N" or the shop was closed
    -- normally), mark the draft for restore. The actual re-fill happens
    -- inside create_shop_inventory() once the inventory arrives.
    pendingRestoreDraft = (lastSavedSlots ~= nil) and (next(lastSavedSlots) ~= nil) or false

    -- Cancel / Start buttons.
    createWindow:recursiveGetChildById('cancelBtn').onClick = closeCreateShop
    createWindow:recursiveGetChildById('startBtn').onClick = commitCreateShop

    -- Description clear (X next to the description input).
    local descClearBtn = createWindow:recursiveGetChildById('descClearBtn')
    if descClearBtn then
        descClearBtn.onClick = function()
            createWindow:recursiveGetChildById('shopText'):setText('')
        end
    end

    -- Live-update price from the info panel into the selected slot.
    local priceEdit = createWindow:recursiveGetChildById('slotPriceEdit')
    if priceEdit then
        priceEdit.onTextChange = function(self, text)
            local s = selectedSlotIndex and slots[selectedSlotIndex] or nil
            if not isFilled(s) then return end
            local v = tonumber(text) or 0
            if v < 1 or v > 1000000000 then
                self:setColor('red')
            else
                self:setColor('white')
            end
            s.price = v
            refreshSummary()
        end
    end

    -- Remove button in the info panel.
    local removeBtn = createWindow:recursiveGetChildById('slotRemoveBtn')
    if removeBtn then
        removeBtn.onClick = function()
            if selectedSlotIndex then removeSlot(selectedSlotIndex) end
        end
    end

    g_keyboard.bindKeyPress('Escape', closeCreateShop, createWindow)

    if modules.game_playershop and modules.game_playershop.sendOpcode then
        modules.game_playershop.sendOpcode(OPCODE_INVENTORY_LIST, '')
    end
end

function closeCreateShop()
    if createWindow then createWindow:destroy(); createWindow = nil end
    if pickerWindow then pickerWindow:destroy(); pickerWindow = nil end
    inventoryList = {}
    selectedSlotIndex = nil
end

function commitCreateShop()
    local text = createWindow:recursiveGetChildById('shopText'):getText() or ''
    if text:gsub("%s+", "") == "" then
        if modules.game_textmessage then
            modules.game_textmessage.displayStatusMessage('You need to set a title for the shop.')
        end
        createWindow:recursiveGetChildById('shopText'):focus()
        return
    end
    local payload = ''
    payload = payload .. modules.game_playershop.packStr(text)
    local filled = {}
    for i = 1, MAX_SLOTS do
        local s = slots[i]
        if isFilled(s) then filled[#filled + 1] = { idx = i, e = s } end
    end
    if #filled == 0 then
        if modules.game_textmessage then
            modules.game_textmessage.displayStatusMessage('Empty shop. Add at least one item.')
        end
        return
    end
    payload = payload .. string.char(#filled)
    for _, f in ipairs(filled) do
        local s = f.e
        payload = payload .. modules.game_playershop.packU32(s.entryUid or 0)
        payload = payload .. modules.game_playershop.packU16(s.serverId or 0)
        payload = payload .. modules.game_playershop.packU16(s.count or 1)
        payload = payload .. modules.game_playershop.packU32(s.price or 0)
    end
    modules.game_playershop.sendOpcode(OPCODE_SHOP_OPEN, payload)
    iAmSelling = true

    -- Cache for reopening the same draft later.
    lastSavedText = text
    lastSavedSlots = {}
    for _, f in ipairs(filled) do
        lastSavedSlots[f.idx] = {
            uid = f.e.entryUid, id = f.e.entryId, serverId = f.e.serverId,
            count = f.e.count, charges = f.e.charges,
            name = '', price = f.e.price,
        }
    end
    closeCreateShop()
end

-- ----------------------------------------------------------------------------
-- Server -> client: inventory list payload
-- ----------------------------------------------------------------------------
function create_shop_inventory(buffer)
    local pos = 1
    local n; n, pos = modules.game_playershop.readPosU16(buffer, pos)
    inventoryList = {}
    for i = 1, n do
        local uid, serverId, clientId, count, charges, stack, name
        uid,      pos = modules.game_playershop.readPosU32(buffer, pos)
        serverId, pos = modules.game_playershop.readPosU16(buffer, pos)
        clientId, pos = modules.game_playershop.readPosU16(buffer, pos)
        count,    pos = modules.game_playershop.readPosU16(buffer, pos)
        charges,  pos = modules.game_playershop.readPosU16(buffer, pos)
        stack,    pos = modules.game_playershop.readPosU8(buffer, pos)
        name,     pos = modules.game_playershop.readPosStr(buffer, pos)
        inventoryList[#inventoryList + 1] = {
            uid = uid, id = clientId, serverId = serverId,
            count = count, charges = charges,
            stackable = stack == 1, name = name
        }
    end
    -- Restore draft slots if we just opened Create Shop and have a cached
    -- previous attempt. Runs before populatePickerList so the picker (if
    -- already open) reflects the items already consumed by the restored
    -- slots when calculating what's still pickable.
    restoreDraftSlots()
    if populatePickerList then populatePickerList() end
end
