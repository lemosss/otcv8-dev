-- =============================================================================
-- Buyer's view: shows another player's shop (items + prices) and lets us buy.
-- =============================================================================

viewWindow = nil
viewSellerId = 0
viewIsOwner = false      -- true quando o user esta olhando a propria loja
ownerRequested = false   -- seta no menu "Open Shop" do proprio char; gates
                         -- whether SHOP_DATA(isOwner=1) abre janela ou e ignorado

local function clearViewItems()
    if not viewWindow then return end
    viewWindow:recursiveGetChildById('viewItems'):destroyChildren()
end

local function buildItemRow(slotIndex, itemId, count, charges, price, name)
    local container = viewWindow:recursiveGetChildById('viewItems')
    local row = g_ui.createWidget('ShopBuyRow', container)

    local itemSlot = row:getChildById('itemSlot')
    itemSlot:setItemId(itemId)
    itemSlot:setItemCount(count)

    local itemName = row:getChildById('itemName')
    itemName:setText(('%dx %s'):format(count, name or 'item'))

    local total = price * count
    local itemPrice = row:getChildById('itemPrice')
    itemPrice:setText(('%d gold cada (total: %d)'):format(price, total))

    local qtyField = row:getChildById('qtyField')
    local buyBtn = row:getChildById('buyBtn')

    if viewIsOwner then
        -- Owner-mode: nao da pra comprar a propria loja. Esconde os
        -- controles de compra; deixa a linha so como visualizacao.
        qtyField:setVisible(false)
        buyBtn:setVisible(false)
        return
    end

    qtyField:setText(tostring(count))
    qtyField.onTextChange = function(self, text)
        local n = tonumber(text) or 0
        if n < 1 then
            self:setColor('red')
        elseif n > count then
            self:setColor('red')
            self:setText(tostring(count))
        else
            self:setColor('white')
        end
    end

    buyBtn.onClick = function()
        local n = tonumber(qtyField:getText()) or 0
        if n <= 0 then return end
        if n > count then n = count end
        local payload = modules.game_playershop.packU32(viewSellerId)
                     .. string.char(slotIndex)
                     .. modules.game_playershop.packU16(n)
        modules.game_playershop.sendOpcode(OPCODE_SHOP_BUY, payload)
    end
end

function shop_view_handle(buffer)
    local pos = 1
    local sellerId; sellerId, pos = modules.game_playershop.readPosU32(buffer, pos)
    local sellerName; sellerName, pos = modules.game_playershop.readPosStr(buffer, pos)
    local shopText; shopText, pos = modules.game_playershop.readPosStr(buffer, pos)
    local isOwner; isOwner, pos = modules.game_playershop.readPosU8(buffer, pos)
    local ownerMode = isOwner == 1

    -- Owner-mode: o server manda updates apos cada venda, mas so abrimos
    -- a janela se o user clicou "Open Shop" dele explicitamente. Senao,
    -- ignora o pacote (mensagem flutuante ja avisa a venda).
    if ownerMode and not viewWindow and not ownerRequested then
        return
    end
    -- Reseta a flag depois de consumir.
    if ownerMode then ownerRequested = false end

    viewIsOwner = ownerMode

    if not viewWindow then
        viewWindow = g_ui.displayUI('playershop.otui', rootWidget)
        viewWindow = g_ui.createWidget('ShopViewWindow', rootWidget)
    end
    viewWindow:show(); viewWindow:raise(); viewWindow:focus()
    viewSellerId = sellerId

    if ownerMode then
        viewWindow:setText('Minha Loja')
        viewWindow:recursiveGetChildById('sellerLine'):setText(
            ('Sua loja (%s)'):format(sellerName))
    else
        viewWindow:setText('Loja de ' .. sellerName)
        viewWindow:recursiveGetChildById('sellerLine'):setText(
            ('Vendedor: %s'):format(sellerName))
    end
    viewWindow:recursiveGetChildById('sellerText'):setText(shopText or '')

    -- Owner: botao Fechar vira "Cancelar Loja" + envia OPCODE_SHOP_CLOSE.
    local closeBtn = viewWindow:recursiveGetChildById('closeBtn')
    if ownerMode then
        closeBtn:setText('Cancelar Loja')
        closeBtn:setWidth(120)
        closeBtn.onClick = function()
            modules.game_playershop.sendOpcode(OPCODE_SHOP_CLOSE, '')
            if viewWindow then viewWindow:destroy(); viewWindow = nil end
        end
    else
        closeBtn:setText('Fechar')
        closeBtn:setWidth(80)
        closeBtn.onClick = function()
            if viewWindow then viewWindow:destroy(); viewWindow = nil end
        end
    end
    -- ESC fecha a janela (sem cancelar a loja).
    g_keyboard.bindKeyPress('Escape', function()
        if viewWindow then viewWindow:destroy(); viewWindow = nil end
    end, viewWindow)

    clearViewItems()

    local n = buffer:byte(pos); pos = pos + 1
    local emptyHint = viewWindow:recursiveGetChildById('viewEmptyHint')
    if emptyHint then emptyHint:setVisible(n == 0) end

    for i = 1, n do
        local slotIndex = buffer:byte(pos); pos = pos + 1
        local itemId; itemId, pos = modules.game_playershop.readPosU16(buffer, pos)
        local count;  count,  pos = modules.game_playershop.readPosU16(buffer, pos)
        local price;  price,  pos = modules.game_playershop.readPosU32(buffer, pos)
        local charges;charges,pos = modules.game_playershop.readPosU16(buffer, pos)
        local name;   name,   pos = modules.game_playershop.readPosStr(buffer, pos)
        buildItemRow(slotIndex, itemId, count, charges, price, name)
    end
end

function shop_view_close()
    if viewWindow then viewWindow:destroy(); viewWindow = nil end
end
