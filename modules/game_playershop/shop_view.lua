-- =============================================================================
-- Buyer's view: shows another player's shop (items + prices) and lets us buy.
-- Layout: search bar -> grid of cells -> bottom panel with selected info,
-- preview + buy button, and description.
-- =============================================================================

viewWindow = nil
viewSellerId = 0
viewIsOwner = false      -- true quando o user esta olhando a propria loja
ownerRequested = false   -- seta no menu "Open Shop" do proprio char; gates
                         -- whether SHOP_DATA(isOwner=1) abre janela ou e ignorado

-- Local state for the new layout (selection + items snapshot).
local viewEntries = {}     -- [i] = { slot, itemId, count, charges, price, weight, name }
local searchText = ''
local selectedCell = nil   -- currently-highlighted ShopBuyCell widget
local selectedEntry = nil  -- viewEntries[i] of the selected cell
viewBalance = 0            -- buyer's bank+cash, populated by shop_view_handle

local function clearViewItems()
    if not viewWindow then return end
    viewWindow:recursiveGetChildById('viewItems'):destroyChildren()
    selectedCell = nil
    selectedEntry = nil
end

-- Insert "." every 3 digits from the right: 379584769 -> 379.584.769.
local function fmtThousands(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub('(%d%d%d)', '%1.'):reverse()
    -- gsub puts a leading '.' if the length is a multiple of 3; trim it.
    if out:sub(1, 1) == '.' then out = out:sub(2) end
    return out
end

local function refreshSelectionPanel()
    if not viewWindow then return end
    local selName    = viewWindow:recursiveGetChildById('selName')
    local priceLbl   = viewWindow:recursiveGetChildById('priceLbl')
    local amountLbl  = viewWindow:recursiveGetChildById('amountLbl')
    local amount     = viewWindow:recursiveGetChildById('amountScroll')
    local previewItem= viewWindow:recursiveGetChildById('previewItem')
    local descText   = viewWindow:recursiveGetChildById('descText')
    local buyBtn     = viewWindow:recursiveGetChildById('buyBtn')

    if not selectedEntry then
        selName:setText('None selected')
        priceLbl:setText('Price (un): -')
        amountLbl:setText('Amount: 1x')
        amount:setMinimum(1); amount:setMaximum(1); amount:setValue(1)
        previewItem:setItemId(0)
        descText:setText('-')
        buyBtn:setEnabled(false)
        return
    end

    local e = selectedEntry
    selName:setText(e.name or 'item')
    priceLbl:setText(('Price (un): %s g'):format(fmtThousands(e.price or 0)))
    amount:setMinimum(1)
    amount:setMaximum(math.max(1, e.count or 1))
    amount:setValue(amount:getValue() or 1)
    amountLbl:setText(('Amount: %dx'):format(amount:getValue()))
    previewItem:setItemId(e.itemId)
    previewItem:setItemCount(amount:getValue())
    -- e.weight is in 1/100 oz (= ItemType:getWeight()).
    if e.weight and e.weight > 0 then
        descText:setText(('You see %s.\nIt weighs %.2f oz.'):format(
            e.name or 'this item', e.weight / 100))
    else
        descText:setText(('You see %s.'):format(e.name or 'this item'))
    end
    buyBtn:setEnabled(not viewIsOwner)
end

local function selectCell(cell)
    -- Hard-reset every cell border via direct widget API (the $on style
    -- proved sticky in this OTC build), then paint the chosen cell only.
    if viewWindow then
        local container = viewWindow:recursiveGetChildById('viewItems')
        if container then
            for _, sibling in ipairs(container:getChildren()) do
                sibling:setBorderWidth(0)
            end
        end
    end
    selectedCell = cell
    if cell then
        cell:setBorderColor('#ffffff')
        cell:setBorderWidth(2)
        selectedEntry = cell.entry
    else
        selectedEntry = nil
    end
    refreshSelectionPanel()
end

local function applySearchFilter()
    if not viewWindow then return end
    local needle = (searchText or ''):lower()
    local container = viewWindow:recursiveGetChildById('viewItems')
    local emptyHint = viewWindow:recursiveGetChildById('viewEmptyHint')
    local visible = 0
    for _, cell in ipairs(container:getChildren()) do
        local match = needle == '' or
            (cell.entry and cell.entry.name and
             cell.entry.name:lower():find(needle, 1, true))
        cell:setVisible(match and true or false)
        if match then visible = visible + 1 end
    end
    if emptyHint then
        emptyHint:setVisible(visible == 0)
        emptyHint:setText(needle ~= ''
            and '(no items match the search)'
            or '(this shop has no items)')
    end
end

local function buildBuyerCell(entry)
    local container = viewWindow:recursiveGetChildById('viewItems')
    local cell = g_ui.createWidget('ShopBuyCell', container)
    local cellItem = cell:getChildById('cellItem')
    cellItem:setItemId(entry.itemId)
    cellItem:setItemCount(entry.count)
    cell:setTooltip(('%dx %s\n%s g each'):format(
        entry.count, entry.name or '', fmtThousands(entry.price or 0)))
    cell.entry = entry

    cell.onClick = function(self) selectCell(self) end
    cell.onDoubleClick = function(self)
        selectCell(self)
        if not viewIsOwner then
            local amount = viewWindow:recursiveGetChildById('amountScroll')
            local n = amount and amount:getValue() or 1
            local payload = modules.game_playershop.packU32(viewSellerId)
                         .. string.char(entry.slot)
                         .. modules.game_playershop.packU16(n)
            modules.game_playershop.sendOpcode(OPCODE_SHOP_BUY, payload)
        end
    end
end

local function refreshGoldLabel()
    if not viewWindow then return end
    -- Gold coin: server id 2148, but UIItem:setItemId expects the
    -- client.dat id (3031 in Cipsoft 7.72). Passing the server id renders
    -- whatever happens to be at dat-id 2148 -- a dark random sprite.
    local icon = viewWindow:recursiveGetChildById('goldIcon')
    if icon then icon:setItemId(3031) end
    local lbl = viewWindow:recursiveGetChildById('goldLbl')
    if not lbl then return end
    -- viewBalance is computed server-side (bank + cash) and shipped in the
    -- SHOP_DATA payload because 7.72 doesn't push wallet info to the client.
    lbl:setText(fmtThousands(viewBalance or 0))
end

function shop_view_handle(buffer)
    local pos = 1
    local sellerId; sellerId, pos = modules.game_playershop.readPosU32(buffer, pos)
    local sellerName; sellerName, pos = modules.game_playershop.readPosStr(buffer, pos)
    local shopText; shopText, pos = modules.game_playershop.readPosStr(buffer, pos)
    local isOwner; isOwner, pos = modules.game_playershop.readPosU8(buffer, pos)
    local ownerMode = isOwner == 1
    -- Buyer balance (bank + cash, computed server-side and shipped here so the
    -- 7.72 client doesn't have to walk the open backpack).
    local balance; balance, pos = modules.game_playershop.readPosU32(buffer, pos)
    viewBalance = balance

    -- Owner-mode: o server manda updates apos cada venda, mas so abrimos
    -- a janela se o user clicou "Open Shop" dele explicitamente. Senao,
    -- ignora o pacote (mensagem flutuante ja avisa a venda).
    if ownerMode and not viewWindow and not ownerRequested then
        return
    end
    if ownerMode then ownerRequested = false end

    viewIsOwner = ownerMode

    if not viewWindow then
        viewWindow = g_ui.displayUI('playershop.otui', rootWidget)
        viewWindow = g_ui.createWidget('ShopViewWindow', rootWidget)
    end
    viewWindow:show(); viewWindow:raise(); viewWindow:focus()
    viewSellerId = sellerId

    if ownerMode then
        viewWindow:setText(("%s's Shop"):format(sellerName))
        viewWindow:recursiveGetChildById('sellerLine'):setText(
            ('Your shop: ' .. (shopText or '')))
    else
        viewWindow:setText(("%s's Shop"):format(sellerName))
        viewWindow:recursiveGetChildById('sellerLine'):setText(shopText or '')
    end

    -- Owner: botao Close vira "Cancelar Loja" + envia OPCODE_SHOP_CLOSE.
    local closeBtn = viewWindow:recursiveGetChildById('closeBtn')
    if ownerMode then
        closeBtn:setText('Cancel Shop')
        closeBtn:setWidth(110)
        closeBtn.onClick = function()
            modules.game_playershop.sendOpcode(OPCODE_SHOP_CLOSE, '')
            if viewWindow then viewWindow:destroy(); viewWindow = nil end
        end
    else
        closeBtn:setText('Close')
        closeBtn:setWidth(80)
        closeBtn.onClick = function()
            if viewWindow then viewWindow:destroy(); viewWindow = nil end
        end
    end

    -- Search input.
    local searchEdit = viewWindow:recursiveGetChildById('searchEdit')
    local searchClearBtn = viewWindow:recursiveGetChildById('searchClearBtn')
    if searchEdit then
        searchEdit:setText('')
        searchText = ''
        searchEdit.onTextChange = function(self, text)
            searchText = text or ''
            applySearchFilter()
        end
    end
    if searchClearBtn then
        searchClearBtn.onClick = function()
            if searchEdit then searchEdit:setText('') end
            searchText = ''
            applySearchFilter()
        end
    end

    -- Amount slider: live-update the preview and amount label.
    local amount = viewWindow:recursiveGetChildById('amountScroll')
    if amount then
        amount.onValueChange = function(self, value)
            local lbl = viewWindow:recursiveGetChildById('amountLbl')
            if lbl then lbl:setText(('Amount: %dx'):format(value)) end
            local preview = viewWindow:recursiveGetChildById('previewItem')
            if preview and selectedEntry then
                preview:setItemCount(value)
            end
        end
    end

    -- Buy button: uses the currently-selected entry + amount slider.
    local buyBtn = viewWindow:recursiveGetChildById('buyBtn')
    if buyBtn then
        buyBtn.onClick = function()
            if viewIsOwner or not selectedEntry then return end
            local n = amount and amount:getValue() or 1
            if n < 1 then return end
            if n > (selectedEntry.count or 1) then n = selectedEntry.count end
            local payload = modules.game_playershop.packU32(viewSellerId)
                         .. string.char(selectedEntry.slot)
                         .. modules.game_playershop.packU16(n)
            modules.game_playershop.sendOpcode(OPCODE_SHOP_BUY, payload)
        end
    end

    -- ESC fecha a janela (sem cancelar a loja).
    pcall(function()
        g_keyboard.bindKeyPress('Escape', function()
            if viewWindow then viewWindow:destroy(); viewWindow = nil end
        end, viewWindow)
    end)

    clearViewItems()
    viewEntries = {}

    local n = buffer:byte(pos); pos = pos + 1
    local emptyHint = viewWindow:recursiveGetChildById('viewEmptyHint')
    if emptyHint then emptyHint:setVisible(n == 0) end

    for i = 1, n do
        local slotIndex = buffer:byte(pos); pos = pos + 1
        local itemId; itemId, pos = modules.game_playershop.readPosU16(buffer, pos)
        local count;  count,  pos = modules.game_playershop.readPosU16(buffer, pos)
        local price;  price,  pos = modules.game_playershop.readPosU32(buffer, pos)
        local charges;charges,pos = modules.game_playershop.readPosU16(buffer, pos)
        local weight; weight, pos = modules.game_playershop.readPosU32(buffer, pos)
        local name;   name,   pos = modules.game_playershop.readPosStr(buffer, pos)
        local entry = {
            slot = slotIndex, itemId = itemId, count = count,
            charges = charges, price = price, weight = weight, name = name,
        }
        viewEntries[#viewEntries + 1] = entry
        buildBuyerCell(entry)
    end

    refreshSelectionPanel()
    applySearchFilter()
    refreshGoldLabel()
end

function shop_view_close()
    if viewWindow then viewWindow:destroy(); viewWindow = nil end
end
