-- =============================================================================
-- Player Shop client module entry point.
-- - Registers ExtendedOpcodes.
-- - Maintains state of nearby selling creatures (bubbles + name icon).
-- - Maintains VIP icon/color for sellers in our VIP list.
-- - Intercepts left-click on a selling creature to open the buyer view.
-- =============================================================================

OPCODE_SHOP_OPEN              = 130
OPCODE_SHOP_CLOSE             = 131
OPCODE_SHOP_REQUEST           = 132
OPCODE_SHOP_BUY               = 133
OPCODE_SHOP_DATA              = 134
OPCODE_SHOP_STATE_BROADCAST   = 135
OPCODE_VIP_SHOP_STATUS        = 136
OPCODE_INVENTORY_LIST         = 137
OPCODE_REJECT                 = 138

VIP_GOLD_COLOR = '#FFD700'
SHOP_ICON_PATH = '/modules/game_playershop/icons/shop_icon'

-- Per-creature bubble widgets.
sellingCreatures = {}      -- [creatureId] = { text, bubbleWidget }
vipSellers       = {}      -- [vipGuid]    = sellerName
lastShopRequest  = 0
iAmSelling       = false   -- true while local player has own shop open (server-confirmed)

local function nowMs()
    return g_clock.millis()
end

-- ----------------------------------------------------------------------------
-- Bubble (text widget over creature) + name icon
-- ----------------------------------------------------------------------------
local function createBubbleFor(creatureId, text)
    local creature = g_map.getCreatureById(creatureId)
    if not creature then
        -- Creature not in view yet; just remember the text. updateBubblePositions
        -- will create the widget once the creature appears.
        sellingCreatures[creatureId] = sellingCreatures[creatureId] or { text = text }
        sellingCreatures[creatureId].text = text
        return
    end
    local entry = sellingCreatures[creatureId]
    if entry and entry.bubbleWidget then
        entry.bubbleWidget:setText(text or '')
        entry.text = text
        return
    end
    local mapPanel = modules.game_interface and modules.game_interface.getMapPanel and modules.game_interface.getMapPanel()
    if not mapPanel then return end
    local bubble = g_ui.createWidget('ShopBubble', mapPanel)
    bubble:setText(text or '')
    sellingCreatures[creatureId] = { text = text, bubbleWidget = bubble, creature = creature }
end

function updateBubblePositions()
    -- Bubble widget temporarily disabled (positioning math gets out-of-sync
    -- when the local player walks). Indicator is now the engine's creature
    -- icon (setIconTexture) which the engine positions automatically.
    -- Re-enable later if/when we figure out the camera offset reliably.
end

local function destroyBubble(creatureId)
    local entry = sellingCreatures[creatureId]
    if entry and entry.bubbleWidget then entry.bubbleWidget:destroy() end
    sellingCreatures[creatureId] = nil
end

-- ----------------------------------------------------------------------------
-- Hook drawInformation: paint the shop icon next to the seller's name.
-- ----------------------------------------------------------------------------
local origDrawInformation = nil

local function patchDrawInformation()
    if origDrawInformation then return end
    if not Creature or not Creature.drawInformation then return end
    origDrawInformation = Creature.drawInformation
    Creature.drawInformation = function(self, ...)
        origDrawInformation(self, ...)
        local cid = self:getId()
        if sellingCreatures[cid] then
            -- Draw a small icon to the left of the name (16x16).
            local pos = self.getInformationPosition and self:getInformationPosition() or nil
            if pos then
                g_drawQueue:addTexturedRect(
                    { x = pos.x - 18, y = pos.y - 8, width = 16, height = 16 },
                    g_textures.getTexture(SHOP_ICON_PATH))
            end
        end
    end
end

local function unpatchDrawInformation()
    if origDrawInformation and Creature then
        Creature.drawInformation = origDrawInformation
        origDrawInformation = nil
    end
end

-- ----------------------------------------------------------------------------
-- Block chat send while own shop is open.
-- ----------------------------------------------------------------------------
local origSendMessage  = nil
local origTalkChannel  = nil
local origTalkPrivate  = nil
local origTalk         = nil

local function notifyBlocked()
    if modules.game_textmessage then
        modules.game_textmessage.displayFailureMessage('Voce nao pode digitar enquanto a loja esta aberta.')
    end
end

-- Always keep the chat TextEdit enabled so the seller can still type commands
-- like !fecharloja. Filtering happens inside game_console (sendMessage
-- patched to allow only messages starting with ! or / while selling).
function setChatEnabled(enabled)
    local cte = modules.game_console and modules.game_console.consoleTextEdit
    if cte then
        cte:setEnabled(true)
    end
end

function patchChatSend()
    -- All chat blocking happens in console.lua's sendCurrentMessage (commands
    -- starting with ! or / are allowed through). No g_game.talk* hooks here so
    -- legitimate command messages reach the server.
end

local function unpatchChatSend()
    -- Nothing to unpatch (chat block lives in console.lua directly).
end

-- ----------------------------------------------------------------------------
-- VIP list color/icon hook (cor dourada + ícone)
-- ----------------------------------------------------------------------------
local function refreshVipWidgetFor(guid, sellerName, isOpen)
    local vip = modules.game_vip
    if not vip or not vip.vipWindow then return end
    local widgetList = vip.vipWindow:recursiveGetChildById('contentsPanel')
    if not widgetList then return end
    for _, w in ipairs(widgetList:getChildren()) do
        if w.guid and tostring(w.guid) == tostring(guid) then
            if isOpen then
                w:setColor(VIP_GOLD_COLOR)
                if not w:getChildById('shopIcon') then
                    local ic = g_ui.createWidget('UIWidget', w)
                    ic:setId('shopIcon')
                    ic:setImageSource(SHOP_ICON_PATH)
                    ic:setSize({ width = 12, height = 12 })
                    ic:addAnchor(AnchorRight, 'parent', AnchorRight)
                    ic:addAnchor(AnchorVerticalCenter, 'parent', AnchorVerticalCenter)
                end
            else
                w:setColor('white')
                local ic = w:getChildById('shopIcon')
                if ic then ic:destroy() end
            end
            return
        end
    end
end

-- ----------------------------------------------------------------------------
-- Click intercept: if user left-clicks a selling creature, open shop view.
-- ----------------------------------------------------------------------------
local origOnGameMapMouseRelease = nil

local function patchClickIntercept()
    if origOnGameMapMouseRelease then return end
    if not modules.game_interface or not modules.game_interface.onMouseRelease then return end
    origOnGameMapMouseRelease = modules.game_interface.onMouseRelease
    modules.game_interface.onMouseRelease = function(self, mousePos, mouseButton)
        if mouseButton == MouseLeftButton then
            local mapPanel = modules.game_interface.getMapPanel()
            local creature = mapPanel and mapPanel:getCreatureByPos(mousePos)
            if creature and sellingCreatures[creature:getId()] then
                requestShopFromCreature(creature)
                return true
            end
        end
        return origOnGameMapMouseRelease(self, mousePos, mouseButton)
    end
end

-- Distancia maxima (Chebyshev / SQM) pra abrir uma loja: o vendedor
-- precisa estar a no maximo 1 tile (adjacente, em qualquer direcao)
-- e no mesmo floor. Aplicado tanto no left-click quick-open quanto
-- no menu hook, e tambem como gate pra manter a janela aberta
-- (server fecha automatico se o comprador se afastar).
SHOP_OPEN_MAX_DISTANCE = 1

function withinShopRange(creature)
    local lp = g_game.getLocalPlayer()
    if not lp or not creature then return false end
    local a, b = lp:getPosition(), creature:getPosition()
    if not a or not b or a.z ~= b.z then return false end
    return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y)) <= SHOP_OPEN_MAX_DISTANCE
end

function requestShopFromCreature(creature)
    if not creature then return end
    if not withinShopRange(creature) then
        if modules.game_textmessage then
            modules.game_textmessage.displayBroadcastMessage(
                "Voce esta longe demais. Aproxime-se do vendedor.")
        end
        return
    end
    local now = nowMs()
    if now - lastShopRequest < 1000 then return end  -- client-side rate limit
    lastShopRequest = now
    local proto = g_game.getProtocolGame()
    if not proto then return end
    local buf = string.char(0, 0, 0, 0)  -- placeholder; we need 4 bytes LE of cid
    local cid = creature:getId()
    buf = string.char(cid % 256, math.floor(cid / 256) % 256,
                      math.floor(cid / 65536) % 256, math.floor(cid / 16777216) % 256)
    proto:sendExtendedOpcode(OPCODE_SHOP_REQUEST, buf)
end

-- ----------------------------------------------------------------------------
-- Opcode handlers (server -> client)
-- ----------------------------------------------------------------------------
local function readU8(buf, pos)  return (buf:byte(pos) or 0), pos + 1 end
local function readU16(buf, pos) return (buf:byte(pos+1) or 0) * 256 + (buf:byte(pos) or 0), pos + 2 end
local function readU32(buf, pos)
    local b1, b2, b3, b4 = buf:byte(pos), buf:byte(pos+1), buf:byte(pos+2), buf:byte(pos+3)
    return ((b4 or 0)*16777216) + ((b3 or 0)*65536) + ((b2 or 0)*256) + (b1 or 0), pos + 4
end
local function readStr(buf, pos)
    local len; len, pos = readU16(buf, pos)
    return buf:sub(pos, pos + len - 1), pos + len
end

local function onStateBroadcast(proto, opcode, buffer)
    local pos = 1
    local cid; cid, pos = readU32(buffer, pos)
    local isOpen = buffer:byte(pos)
    local creature = g_map.getCreatureById(cid)
    if isOpen == 1 then
        local text; text, pos = readStr(buffer, pos + 1)
        sellingCreatures[cid] = { text = text }
        -- O icone agora vem via protocolo nativo (skull id 7 = SHOP_ICON,
        -- mapeado pro shop_icon.png em gamelib/creature.lua). O server
        -- envia no AddCreature, instantaneo igual PK skull.
        --
        -- Texto da loja FIXO acima da cabeca do char: usa o sistema de
        -- "title" nativo do OTC v8 (Creature:setTitle), que renderiza um
        -- texto extra colado no nome via drawInformation no engine. Por
        -- ser nativo, segue a creature quando ela anda, nao decai e nao
        -- polui o chat. Cor dourada pra destacar de outros titles.
        if creature and creature.setTitle then
            pcall(function()
                creature:setTitle(text or '', 'verdana-11px-rounded', '#FFD700')
            end)
        end
    else
        sellingCreatures[cid] = nil
        -- Mesmo: o skull volta ao real automaticamente no proximo packet
        -- de update do server (quando storage 88810 voltar a 0).
        -- Limpa o title fixo da loja.
        if creature and creature.clearTitle then
            pcall(function() creature:clearTitle() end)
        end
        -- Se eu (comprador) estou vendo justamente a loja desse seller que
        -- acabou de fechar (ultimo item vendido, logout, expiracao, etc),
        -- fecha automaticamente minha view-window pra nao ficar pendurada.
        pcall(function()
            if shop_view and shop_view.viewSellerId == cid then
                if shop_view_close then shop_view_close() end
            end
            -- Fallback: tambem checar a global viewWindow / viewSellerId
            -- caso shop_view module table nao esteja exposto.
            if viewSellerId == cid and viewWindow then
                if shop_view_close then shop_view_close()
                else viewWindow:destroy(); viewWindow = nil end
            end
        end)
    end
    local lp = g_game.getLocalPlayer()
    if lp and cid == lp:getId() then
        local prev = iAmSelling
        iAmSelling = (isOpen == 1)
        if prev ~= iAmSelling then
            print(('[playershop] state changed: iAmSelling %s -> %s'):format(
                tostring(prev), tostring(iAmSelling)))
        end
    end
end

local function onVipStatus(proto, opcode, buffer)
    local pos = 1
    local guid; guid, pos = readU32(buffer, pos)
    local name; name, pos = readStr(buffer, pos)
    local isOpen = buffer:byte(pos)
    if isOpen == 1 then vipSellers[guid] = name else vipSellers[guid] = nil end
    refreshVipWidgetFor(guid, name, isOpen == 1)
end

local function onShopData(proto, opcode, buffer)
    -- Hand off to shop_view module.
    if shop_view_handle then shop_view_handle(buffer) end
end

local function onInventoryList(proto, opcode, buffer)
    if create_shop_inventory then create_shop_inventory(buffer) end
end

local function onReject(proto, opcode, buffer)
    local reason = buffer or ""
    -- Don't toggle iAmSelling here -- server sends STATE_BROADCAST right after
    -- every REJECT with the player's actual selling state, which then sets the
    -- flag correctly via onStateBroadcast.

    -- Close the buy view via every path that might exist (sandboxed env has
    -- module-shared globals BUT cross-script lookups can be inconsistent).
    pcall(function() if shop_view_close then shop_view_close() end end)
    pcall(function() if viewWindow then viewWindow:destroy(); viewWindow = nil end end)
    pcall(function()
        local mod = modules.game_playershop
        if mod and mod.viewWindow then mod.viewWindow:destroy(); mod.viewWindow = nil end
        if mod and mod.shop_view_close then mod.shop_view_close() end
    end)

    -- Render as RED warning (centerRed via MessageModes.Warning inside displayBroadcastMessage).
    if modules.game_textmessage and modules.game_textmessage.displayBroadcastMessage then
        modules.game_textmessage.displayBroadcastMessage(reason)
        return
    end
    print('[PlayerShop] ' .. reason)
end

-- ----------------------------------------------------------------------------
-- Init / Terminate
-- ----------------------------------------------------------------------------
function init()
    print('[playershop] init() entered')
    print('[playershop] type(modules)=' .. type(modules))
    print('[playershop] modules.game_interface=' .. tostring(modules and modules.game_interface))
    local gi = modules and modules.game_interface
    if gi then
        print('[playershop] gi.addMenuHook=' .. tostring(gi.addMenuHook))
    end

    -- Schedule menu hooks AFTER all modules definitely loaded.
    scheduleEvent(function()
        local gi2 = modules and modules.game_interface
        if not gi2 or not gi2.addMenuHook then return end

        -- Two categories. Each category that's "non-empty" adds a separator.
        -- Result: when right-clicking own char OR a selling other, the menu
        -- shows TWO separator lines (one per category) plus the Open Shop entry.
        gi2.addMenuHook(
            'playershop_a_create',
            'Open Shop',
            function(menuPos, look, use, creature)
                local lp = g_game.getLocalPlayer()
                print(('[playershop] Open Shop click: iAmSelling=%s'):format(
                    tostring(iAmSelling)))
                if iAmSelling and lp then
                    -- Ja tem loja ativa: pede SHOP_DATA da propria loja
                    -- pra abrir em modo owner-view (estoque atualizado).
                    ownerRequested = true
                    local proto = g_game.getProtocolGame()
                    if proto then
                        proto:sendExtendedOpcode(OPCODE_SHOP_REQUEST,
                            packU32(lp:getId()))
                    end
                else
                    -- Sem loja ativa: abre a janela de criar loja.
                    if openCreateShop then openCreateShop() end
                end
            end,
            function(menuPos, look, use, creature)
                local lp = g_game.getLocalPlayer()
                return creature ~= nil and lp ~= nil and creature:getId() == lp:getId()
            end
        )
        gi2.addMenuHook(
            'playershop_b_view',
            'Open Shop',
            function(menuPos, look, use, creature)
                if creature and requestShopFromCreature then requestShopFromCreature(creature) end
            end,
            function(menuPos, look, use, creature)
                if not creature or not creature:isPlayer() then return false end
                local lp = g_game.getLocalPlayer()
                if lp and creature:getId() == lp:getId() then return false end
                -- Source of truth primaria: o skull. Se eh 7 (ShopIcon), o
                -- server marcou o player como vendedor via getSkullClient.
                -- Esse caminho eh instantaneo (vem no AddCreature packet).
                if creature.getSkull and creature:getSkull() == 7 then
                    return true
                end
                -- Fallback: cache populado via STATE_BROADCAST.
                return sellingCreatures[creature:getId()] ~= nil
            end
        )
        print('[playershop] menu hooks registered')
    end, 1500)

    -- All optional setup wrapped in pcalls so nothing breaks the hook.
    pcall(function() g_ui.importStyle('playershop.otui') end)
    -- Quando uma creature aparece no campo de visao do client (subiu/desceu
    -- escada, andou pra perto, etc.), re-aplica o TITLE da loja se ela esta
    -- no nosso cache `sellingCreatures`. O icone (skull) ja vem via protocol
    -- nativo. O title eh client-side state e some quando a creature eh
    -- destruida/recriada, entao precisa ser re-aplicado nesse hook.
    pcall(function()
        connect(Creature, {
            onAppear = function(creature)
                if not creature then return end
                local cid = creature:getId()
                local entry = sellingCreatures and sellingCreatures[cid]
                if entry and creature.setTitle then
                    pcall(function()
                        creature:setTitle(entry.text or '',
                            'verdana-11px-rounded', '#FFD700')
                    end)
                end
            end
        })
    end)
    pcall(function()
        ProtocolGame.registerExtendedOpcode(OPCODE_SHOP_STATE_BROADCAST, onStateBroadcast)
        ProtocolGame.registerExtendedOpcode(OPCODE_VIP_SHOP_STATUS,      onVipStatus)
        ProtocolGame.registerExtendedOpcode(OPCODE_SHOP_DATA,            onShopData)
        ProtocolGame.registerExtendedOpcode(OPCODE_INVENTORY_LIST,       onInventoryList)
        ProtocolGame.registerExtendedOpcode(OPCODE_REJECT,               onReject)
    end)
    -- Client-side instant auto-close: assim que o local player muda de
    -- posicao e a viewWindow esta aberta, recalcula a distancia pro
    -- vendedor. Se passou de 1 SQM, fecha imediato (sem esperar o
    -- tick do server). O server tambem fecha via reject no proximo
    -- tick (500ms) -- isso aqui eh so pra UX responsiva.
    pcall(function()
        connect(LocalPlayer, {
            onPositionChange = function(player, newPos, oldPos)
                if not viewWindow then return end
                if not viewSellerId or viewSellerId == 0 then return end
                local seller = g_map.getCreatureById(viewSellerId)
                if not seller then return end
                local sp = seller:getPosition()
                if not sp or not newPos then return end
                if sp.z ~= newPos.z then
                    if shop_view_close then shop_view_close() end
                    return
                end
                local dist = math.max(math.abs(sp.x - newPos.x),
                                      math.abs(sp.y - newPos.y))
                if dist > SHOP_OPEN_MAX_DISTANCE then
                    if shop_view_close then shop_view_close() end
                    if modules.game_textmessage then
                        modules.game_textmessage.displayBroadcastMessage(
                            "Voce se afastou do vendedor. Loja fechada.")
                    end
                end
            end
        })
    end)
    pcall(patchDrawInformation)
    pcall(patchClickIntercept)
    pcall(patchChatSend)

    -- (No top-bar button: shop creation is now via right-click on own char.)

    -- Bubble position refresher: every ~50ms re-position all shop bubbles
    -- on top of their creature's information offset.
    local function tickBubbles()
        updateBubblePositions()
        bubbleTickEvent = scheduleEvent(tickBubbles, 50)
    end
    bubbleTickEvent = scheduleEvent(tickBubbles, 50)

    -- (No top-menu button: shop creation is via right-click "Open Shop" on own char.)

    connect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
end

function terminate()
    ProtocolGame.unregisterExtendedOpcode(OPCODE_SHOP_STATE_BROADCAST)
    ProtocolGame.unregisterExtendedOpcode(OPCODE_VIP_SHOP_STATUS)
    ProtocolGame.unregisterExtendedOpcode(OPCODE_SHOP_DATA)
    ProtocolGame.unregisterExtendedOpcode(OPCODE_INVENTORY_LIST)
    ProtocolGame.unregisterExtendedOpcode(OPCODE_REJECT)

    if modules.game_interface and modules.game_interface.removeMenuHook then
        modules.game_interface.removeMenuHook('playershop')
    end

    unpatchDrawInformation()
    unpatchChatSend()
    if bubbleTickEvent then removeEvent(bubbleTickEvent); bubbleTickEvent = nil end

    for cid, _ in pairs(sellingCreatures) do destroyBubble(cid) end
    sellingCreatures = {}
    vipSellers = {}

    disconnect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
end

function onGameStart()
    iAmSelling = false
end

function onGameEnd()
    for cid, _ in pairs(sellingCreatures) do destroyBubble(cid) end
    sellingCreatures = {}
    vipSellers = {}
    iAmSelling = false  -- crucial: reset so re-login is unlocked
    -- Clear cached create-shop window state (items + text) so the next
    -- character on this client doesn't see the previous one's draft.
    lastSavedText = nil
    lastSavedSlots = nil
    inventoryList = {}
    if createWindow then createWindow:destroy(); createWindow = nil end
end

-- Re-export so create_shop.lua / shop_view.lua can use them.
function sendOpcode(opcode, buffer)
    local proto = g_game.getProtocolGame()
    if proto then proto:sendExtendedOpcode(opcode, buffer) end
end

-- helpers exported for the other two scripts
function packU16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
function packU32(n)
    return string.char(n % 256,
                       math.floor(n / 256) % 256,
                       math.floor(n / 65536) % 256,
                       math.floor(n / 16777216) % 256)
end
function packStr(s)
    s = s or ''
    return packU16(#s) .. s
end
function readPosU8(buf, pos)   return readU8(buf, pos)   end
function readPosU16(buf, pos)  return readU16(buf, pos)  end
function readPosU32(buf, pos)  return readU32(buf, pos)  end
function readPosStr(buf, pos)  return readStr(buf, pos)  end
