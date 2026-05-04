-- private variables
local SHOP_EXTENTED_OPCODE = 201

shop = nil
transferWindow = nil
local otcv8shop = false
local shopButton = nil
local msgWindow = nil
local browsingHistory = false
local transferValue = 0

-- for classic store
local storeUrl = ""
local coinsPacketSize = 0

local CATEGORIES = {}
local HISTORY = {}
local STATUS = {}
local AD = {}

local selectedOffer = {}

local function sendAction(action, data)
  if not g_game.getFeature(GameExtendedOpcode) then
    return
  end
  
  local protocolGame = g_game.getProtocolGame()
  if data == nil then
    data = {}
  end
  if protocolGame then
    protocolGame:sendExtendedJSONOpcode(SHOP_EXTENTED_OPCODE, {action = action, data = data})
  end  
end

-- public functions
function init()
  connect(g_game, {
    onGameStart = onShopGameStart,
    onGameEnd = hide,
    onStoreInit = onStoreInit,
    onStoreCategories = onStoreCategories,
    onStoreOffers = onStoreOffers,
    onStoreTransactionHistory = onStoreTransactionHistory,
    onStorePurchase = onStorePurchase,
    onStoreError = onStoreError,
    onCoinBalance = onCoinBalance
  })

  ProtocolGame.registerExtendedJSONOpcode(SHOP_EXTENTED_OPCODE, onExtendedJSONOpcode)
  
  if g_game.isOnline() then
    check()
  end
  createShop()
  createTransferWindow()
end

function terminate()
  disconnect(g_game, {
    onGameStart = onShopGameStart,
    onGameEnd = hide,
    onStoreInit = onStoreInit,
    onStoreCategories = onStoreCategories,
    onStoreOffers = onStoreOffers,
    onStoreTransactionHistory = onStoreTransactionHistory,    
    onStorePurchase = onStorePurchase,
    onStoreError = onStoreError,
    onCoinBalance = onCoinBalance    
  })

  ProtocolGame.unregisterExtendedJSONOpcode(SHOP_EXTENTED_OPCODE, onExtendedJSONOpcode)
  
  if shopButton then
    shopButton:destroy()
    shopButton = nil
  end
  if shop then
    disconnect(shop.categories, { onChildFocusChange = changeCategory })
    shop:destroy()
    shop = nil
  end
  if msgWindow then
    msgWindow:destroy()
  end
end

function check()
  otcv8shop = false
  sendAction("init")
end

-- Tibia.dat sprites are not always ready when this module's init() runs,
-- which made the ShopCategoryItem icons render blank even after addCategory
-- assigned them. Refresh the local categories on game start so the
-- UIItem.setItemId calls hit a fully-loaded dat.
function onShopGameStart()
  check()
  if shop and shop.categories then
    while shop.categories:getChildCount() > 0 do
      shop.categories:destroyChildren(shop.categories:getLastChild())
    end
  end
  CATEGORIES = {}
  addLocalCategories()
end

function hide()
  if not shop then
    return
  end
  shop:hide()
end

function show()
  if not shop or not shopButton then
    return
  end
  if g_game.getFeature(GameIngameStore) then
    g_game.openStore(0)
  end

  shop:show()
  shop:raise()
  shop:focus()
  -- Trigger the focus chain on each open so the right detail panel always
  -- reflects what's selected — programmatic focus during createShop runs
  -- while the window is hidden, and OTC sometimes drops the focus event
  -- in that state.
  local cat = shop.categories:getFocusedChild() or shop.categories:getChildByIndex(1)
  if cat then
    cat:focus()
    changeCategory(cat, cat)
  end
end

function softHide()
  if not transferWindow then return end

  transferWindow:hide()
  shop:show()
end

function showTransfer()
  if not shop or not transferWindow then return end

  hide()
  transferWindow:show()
  transferWindow:raise()
  transferWindow:focus()
end

function hideTransfer()
  if not shop or not transferWindow then return end

  transferWindow:hide()
  show()
end

function toggle()
  if not shop then
    return
  end
  if shop:isVisible() then
    return hide()
  end
  show()
  check()
end

function createShop()
  if shop then return end
  shop = g_ui.displayUI('shop')
  shop:hide()
  shopButton = modules.client_topmenu.addRightGameToggleButton('shopButton', tr('Shop'), '/images/topbuttons/shop', toggle, false, 99)
  connect(shop.categories, { onChildFocusChange = changeCategory })
  -- Wire offer-card selection: when the user clicks a card the TextList
  -- re-focuses, and we mirror that into the right detail panel.
  connect(shop.offers, { onChildFocusChange = function(self, focusedChild) selectOffer(focusedChild) end })
  addLocalCategories()
end

-- Local categories are injected client-side so the Shop window has
-- something to show even when the server does not push a category list
-- (TFS-1.5-Downgrades does not implement the OTCv8 extended-shop
-- protocol). They are also re-appended after processCategories() in
-- case a server later sends its own list.
-- Default outfit colors used as a neutral preview palette so the category
-- and card creatures don't render as the bald-mannequin default.
local DEFAULT_OUTFIT_COLORS = {head = 78, body = 88, legs = 113, feet = 95, addons = 0}

local function outfitOffer(id, lookType, name)
  local outfit = {type = lookType}
  for k, v in pairs(DEFAULT_OUTFIT_COLORS) do outfit[k] = v end
  return {
    id = id, type = "outfit", outfit = outfit, cost = 450,
    title = name, description = name .. " outfit. Unlocks the look on your character."
  }
end

local LOCAL_CATEGORIES = {
  {
    type = "item",
    item = 2819,
    count = 1,
    name = "Premium Time",
    offers = {
      {id = "premium_15",  type = "item", item = 2819, count = 1, cost = 200, title = "Premium Account 15 days",  description = "15 days of Premium Account"},
      {id = "premium_30",  type = "item", item = 2819, count = 1, cost = 300, title = "Premium Account 30 days",  description = "30 days of Premium Account"},
      {id = "premium_60",  type = "item", item = 2819, count = 1, cost = 500, title = "Premium Account 60 days",  description = "60 days of Premium Account"},
      {id = "premium_120", type = "item", item = 2819, count = 1, cost = 950, title = "Premium Account 120 days", description = "120 days of Premium Account"},
    },
  },
  {
    -- Knight as the category icon (most iconic 8.0 outfit). Card-side
    -- creatures pick up their own look type from each offer.
    type = "outfit",
    outfit = (function()
      local o = {type = 131}
      for k, v in pairs(DEFAULT_OUTFIT_COLORS) do o[k] = v end
      return o
    end)(),
    name = "Outfits",
    offers = {
      outfitOffer("outfit_citizen",  128, "Citizen"),
      outfitOffer("outfit_hunter",   129, "Hunter"),
      outfitOffer("outfit_mage",     130, "Mage"),
      outfitOffer("outfit_knight",   131, "Knight"),
      outfitOffer("outfit_nobleman", 132, "Nobleman"),
      outfitOffer("outfit_summoner", 133, "Summoner"),
      outfitOffer("outfit_warrior",  134, "Warrior"),
      outfitOffer("outfit_druid",    143, "Druid"),
      outfitOffer("outfit_wizard",   145, "Wizard"),
      outfitOffer("outfit_oriental", 146, "Oriental"),
    },
  },
}

function addLocalCategories()
  for _, category in ipairs(LOCAL_CATEGORIES) do
    table.insert(CATEGORIES, category)
    addCategory(category)
  end
  -- Focus the first category so the offers list (and the detail panel via
  -- changeCategory's auto-select) populate immediately on first open.
  if shop and shop.categories then
    local firstCategory = shop.categories:getChildByIndex(1)
    if firstCategory then
      firstCategory:focus()
    end
  end
end

GET_COINS_URL = "https://www.google.com"

function openGetCoins()
  g_platform.openUrl(GET_COINS_URL)
end

function createTransferWindow()
  if transferWindow then return end
  transferWindow = g_ui.displayUI('transfer')
  transferWindow:hide()
end

function onStoreInit(url, coins)
  if otcv8shop then return end
  storeUrl = url
  if storeUrl:len() > 0 then
    if storeUrl:sub(storeUrl:len(), storeUrl:len()) ~= "/" then
      storeUrl = storeUrl .. "/"
    end
    storeUrl = storeUrl .. "64/"
    if storeUrl:sub(1, 4):lower() ~= "http" then
      storeUrl = "http://" .. storeUrl
    end
  end
  coinsPacketSize = coins
  createShop()
  createTransferWindow()
end

function onStoreCategories(categories)
  if not shop or otcv8shop then return end
  local correctCategories = {}
  for i, category in ipairs(categories) do
    local image = ""
    if category.icon:len() > 0 then
      image = storeUrl .. category.icon
    end
    table.insert(correctCategories, {
      type = "image",
      image = image,
      name = category.name,
      offers = {}
    })
  end
  processCategories(correctCategories)
end

function onStoreOffers(categoryName, offers)
  if not shop or otcv8shop then return end
  local updated = false
    
  for i, category in ipairs(CATEGORIES) do
    if category.name == categoryName then
      if #category.offers ~= #offers then
        updated = true
      end
      for i=1,#category.offers do
        if category.offers[i].title ~= offers[i].name or category.offers[i].id ~= offers[i].id or category.offers[i].cost ~= offers[i].price then
          updated = true
        end
      end
      if updated then    
        for offer in pairs(category.offers) do
          category.offers[offer] = nil
        end
        for i, offer in ipairs(offers) do
          local image = ""
          if offer.icon:len() > 0 then
            image = storeUrl .. offer.icon
          end
          table.insert(category.offers, {
            id=offer.id,
            type="image",
            image=image,
            cost=offer.price,
            title=offer.name,
            description=offer.description        
          })
        end
      end
    end
  end
  if not updated then
    return
  end
  
  local activeCategory = shop.categories:getFocusedChild()
  changeCategory(activeCategory, activeCategory)
end

function onStoreTransactionHistory(currentPage, hasNextPage, offers)
  if not shop or otcv8shop then return end
  HISTORY = {}
  for i, offer in ipairs(offers) do
    table.insert(HISTORY, {
      id=offer.id,
      type="image",
      image=storeUrl .. offer.icon,
      cost=offer.price,
      title=offer.name,
      description=offer.description        
    })
  end
  
  if not browsingHistory then return end
  -- Re-render the history panel with the freshly-arrived transactions
  -- (force=true since we're already in browsingHistory mode).
  showHistory(true)
end

function onStorePurchase(message)
  if not shop or otcv8shop then return end
  if not transferWindow:isVisible() then
    processMessage({title="Successful shop purchase", msg=message})
  else
    processMessage({title="Successfuly gifted coins", msg=message})
    softHide()
  end
end

function onStoreError(errorType, message)
  if not shop or otcv8shop then return end
  if not transferWindow:isVisible() then
    processMessage({title="Shop Error", msg=message})
  else
    processMessage({title="Gift coins error", msg=message})
  end
end

function onCoinBalance(coins, transferableCoins)
  if not shop or otcv8shop then return end
  -- OTCv8 runs on Lua 5.1 where every number is a double, so concatenating
  -- the coin value via ".." gives "1000.0". Format as integer instead.
  local coinsStr = string.format("%d", coins)
  -- New bottom-bar label (visible). The legacy infoPanel.points is kept
  -- but invisible; setting both keeps any other code path that watches
  -- the legacy node working (e.g. tooltips, future modules).
  if shop.pointsText then
    shop.pointsText:setText(tr("Points:") .. " " .. coinsStr)
  end
  if shop.infoPanel and shop.infoPanel.points then
    shop.infoPanel.points:setText(tr("Points:") .. " " .. coinsStr)
  end
  transferWindow.coinsBalance:setText(tr('Transferable Tibia Coins: ') .. coinsStr)
  transferWindow.coinsAmount:setMaximum(coins)
end

function transferCoins()
  if not transferWindow then return end
  local amount = 0
  amount = transferWindow.coinsAmount:getValue()
  local recipient = transferWindow.recipient:getText()

  g_game.transferCoins(recipient, amount)
  transferWindow.recipient:setText('')
  transferWindow.coinsAmount:setValue(0)
end

function onExtendedJSONOpcode(protocol, code, json_data)
  createShop()
  createTransferWindow()

  local action = json_data['action']
  local data = json_data['data']
  local status = json_data['status']
  if not action or not data then
    return false
  end
  
  otcv8shop = true
  if action == 'categories' then
    processCategories(data)
  elseif action == 'history' then
    processHistory(data)
  elseif action == 'message' then
    processMessage(data)
  end

  if status then
    processStatus(status)
  end
end

function clearOffers()
  while shop.offers:getChildCount() > 0 do
    local child = shop.offers:getLastChild()
    shop.offers:destroyChildren(child)
  end
end

function clearCategories()
  CATEGORIES = {}
  clearOffers()
  while shop.categories:getChildCount() > 0 do
    local child = shop.categories:getLastChild()
    shop.categories:destroyChildren(child)
  end
end

function clearHistory()
  HISTORY = {}
  if browsingHistory then
    clearOffers()
  end
end

function processCategories(data)
  if table.equal(CATEGORIES,data) then
    return
  end
  clearCategories()
  CATEGORIES = data
  for i, category in ipairs(data) do
    addCategory(category)
  end
  -- keep the local Premium Time tab even after a server pushes its
  -- own category list
  addLocalCategories()
  if not browsingHistory then
    local firstCategory = shop.categories:getChildByIndex(1)
    if firstCategory then
      firstCategory:focus()
    end
  end
end

function processHistory(data)
  if table.equal(HISTORY,data) then
    return
  end
  HISTORY = data
  if browsingHistory then
    showHistory(true)
  end
end

function processMessage(data)
  if msgWindow then
    msgWindow:destroy()
  end
    
  local title = tr(data["title"])
  local msg = data["msg"]
  msgWindow = displayInfoBox(title, msg)
  msgWindow.onDestroy = function(widget)
    if widget == msgWindow then
      msgWindow = nil
    end
  end
  msgWindow:show()
  msgWindow:raise()
  msgWindow:focus()
end

function processStatus(data)
  if table.equal(STATUS,data) then
    return
  end
  STATUS = data

  if data['ad'] then
    processAd(data['ad'])
  end
  if data['points'] then
    if shop.pointsText then
      shop.pointsText:setText(tr("Points:") .. " " .. data['points'])
    end
    if shop.infoPanel and shop.infoPanel.points then
      shop.infoPanel.points:setText(tr("Points:") .. " " .. data['points'])
    end
  end
  if data['buyUrl'] and data['buyUrl']:sub(1, 4):lower() == "http" then
    shop.infoPanel.buy:show()
    shop.infoPanel.buy.onMouseRelease = function() 
      scheduleEvent(function() g_platform.openUrl(data['buyUrl']) end, 50)
    end
  else
    shop.infoPanel.buy:hide()
    shop.infoPanel:setHeight(20)
  end
end

function processAd(data)
  if table.equal(AD,data) then
    return
  end
  AD = data
  
  if data['image'] and data['image']:sub(1, 4):lower() == "http" then
    HTTP.downloadImage(data['image'], function(path, err) 
      if err then g_logger.warning("HTTP error: " .. err .. " - " .. data['image']) return end
      shop.adPanel:setHeight(shop.infoPanel:getHeight())
      shop.adPanel.ad:setText("")
      shop.adPanel.ad:setImageSource(path)
      shop.adPanel.ad:setImageFixedRatio(true)
      shop.adPanel.ad:setImageAutoResize(true)
      shop.adPanel.ad:setHeight(shop.infoPanel:getHeight())
    end)
  elseif data['text'] and data['text']:len() > 0 then
      shop.adPanel:setHeight(shop.infoPanel:getHeight())
      shop.adPanel.ad:setText(data['text'])
      shop.adPanel.ad:setHeight(shop.infoPanel:getHeight())
  else
      shop.adPanel:setHeight(0)
  end
  if data['url'] and data['url']:sub(1, 4):lower() == "http" then
    shop.adPanel.ad.onMouseRelease = function() 
      scheduleEvent(function() g_platform.openUrl(data['url']) end, 50)
    end
  else
    shop.adPanel.ad.onMouseRelease = nil
  end
end

function addCategory(data)
  local category
  if data["type"] == "item" then
    category = g_ui.createWidget('ShopCategoryItem', shop.categories)
    category.item:setItemId(data["item"])
    category.item:setItemCount(data["count"])
    category.item:setShowCount(false)
  elseif data["type"] == "outfit" then
    category = g_ui.createWidget('ShopCategoryCreature', shop.categories)
    category.creature:setOutfit(data["outfit"])
    if data["outfit"]["rotating"] then
      category.creature:setAutoRotating(true)
    end
  elseif data["type"] == "image" then
    category = g_ui.createWidget('ShopCategoryImage', shop.categories)
    if data["image"] and data["image"]:sub(1, 4):lower() == "http" then
       HTTP.downloadImage(data['image'], function(path, err) 
        if err then g_logger.warning("HTTP error: " .. err .. " - " .. data["image"]) return end
        category.image:setImageSource(path)
      end)
    else
      category.image:setImageSource(data["image"])
    end
  else
    g_logger.error("Invalid shop category type: " .. tostring(data["type"]))
    return
  end
  category:setId("category_" .. shop.categories:getChildCount())
  category.name:setText(data["name"])
end

-- Mock history rows for visual testing while the server-side transaction
-- log isn't wired yet. Replaced by server data once HISTORY is populated.
local MOCK_HISTORY = {
  {date = "2026-05-01 14:50:40", delta = -10,  description = "Purchased Private Store Document"},
  {date = "2026-04-29 09:32:11", delta = -200, description = "Purchased Premium Account 15 days"},
  {date = "2026-04-27 18:14:02", delta = -450, description = "Purchased Knight outfit"},
  {date = "2026-04-23 15:20:50", delta = -5,   description = "Purchased Ring of Light"},
  {date = "2026-04-20 21:03:45", delta = -10,  description = "Purchased 1x Miracle Coin"},
  {date = "2026-04-20 21:03:42", delta = -13,  description = "Purchased 1x Miracle Coin"},
  {date = "2026-04-20 21:03:39", delta = -10,  description = "Purchased 1x Miracle Coin"},
  {date = "2026-04-20 10:55:37", delta = -15,  description = "Lemos transferred to Ikamuni"},
  {date = "2026-04-19 22:10:01", delta = -5,   description = "Purchased Ring of Light"},
  {date = "2026-04-18 08:42:19", delta = -300, description = "Purchased Premium Account 30 days"},
}

function showHistory(force)
  if browsingHistory and not force then
    return
  end

  if g_game.getFeature(GameIngameStore) and not otcv8shop then
    g_game.openTransactionHistory(100)
  end
  sendAction("history")

  browsingHistory = true
  shop.categories:focusChild(nil)

  -- Swap the right side from offers+detail to the dedicated history panel.
  -- Keeping the categories sidebar visible matches the playershop and lets
  -- the user click a category to exit history mode.
  if shop.offers then shop.offers:setVisible(false) end
  if shop.offersScrollBar then shop.offersScrollBar:setVisible(false) end
  if shop.detailPanel then shop.detailPanel:setVisible(false) end
  if shop.historyPanel then shop.historyPanel:setVisible(true) end

  -- Wipe any previous rows in the history list panel.
  local histList = shop.historyPanel and shop.historyPanel.histListPanel
  if histList then
    while histList:getChildCount() > 0 do
      histList:destroyChildren(histList:getLastChild())
    end
  end

  -- Rows: prefer the server-populated HISTORY; fall back to mock data so
  -- the layout is visible while the backend isn't wired. Alternating row
  -- tint (zebra striping) makes individual transactions easier to scan.
  local rows = (HISTORY and #HISTORY > 0) and HISTORY or MOCK_HISTORY
  if histList then
    for i, tx in ipairs(rows) do
      local row = g_ui.createWidget('ShopHistoryRow', histList)

      -- Defensive child lookups: if any one column widget fails to
      -- materialize for a given row, the others still render.
      -- getChildById matches the access pattern used by the playershop's
      -- HistoryRow code which we know works in production.
      local dateLbl = row:getChildById('rowDate')
      local balanceLbl = row:getChildById('rowBalance')
      local descLbl = row:getChildById('rowDesc')
      local delta = tx.delta or tx.cost or 0

      if dateLbl then dateLbl:setText(tx.date or "") end
      if balanceLbl then balanceLbl:setText(string.format("%d", -math.abs(delta))) end
      if descLbl then descLbl:setText(tx.description or tx.title or "") end

      if i % 2 == 0 then
        row:setBackgroundColor("#0000001a")
      else
        row:setBackgroundColor("#00000033")
      end
    end
  end

  -- Toggle the bottom-right button into "Offers" mode while in history.
  local btn = shop.bottomBar and shop.bottomBar.transactionHistory
  if btn then
    btn:setText(tr('Offers'))
  end
end

-- The bottom-right button serves both showHistory and showOffers (toggle).
-- Click cycles between the two modes based on browsingHistory.
function toggleHistory()
  if browsingHistory then
    showOffers()
  else
    showHistory()
  end
end

function showOffers()
  browsingHistory = false
  local btn = shop.bottomBar and shop.bottomBar.transactionHistory
  if btn then
    btn:setText(tr('History'))
  end
  -- Hide history panel, restore offers + detail panel for the standard
  -- 3-column shop layout.
  if shop.historyPanel then shop.historyPanel:setVisible(false) end
  if shop.offers then shop.offers:setVisible(true) end
  if shop.offersScrollBar then shop.offersScrollBar:setVisible(true) end
  if shop.detailPanel then shop.detailPanel:setVisible(true) end
  -- Re-focus the active category so changeCategory re-populates the
  -- offers list and the detail panel auto-selects.
  local cat = shop.categories:getFocusedChild() or shop.categories:getChildByIndex(1)
  if cat then
    cat:focus()
    changeCategory(cat, cat)
  end
end

function addOffer(category, data)
  local offer
  if data["type"] == "item" then
    offer = g_ui.createWidget('ShopOfferItem', shop.offers)
    offer.item:setItemId(data["item"])
    offer.item:setItemCount(data["count"])
    offer.item:setShowCount(false)
  elseif data["type"] == "outfit" then
    offer = g_ui.createWidget('ShopOfferCreature', shop.offers)
    offer.creature:setOutfit(data["outfit"])
    if data["outfit"]["rotating"] then
      offer.creature:setAutoRotating(true)
    end
  elseif data["type"] == "image" then
    offer = g_ui.createWidget('ShopOfferImage', shop.offers)
    if data["image"] and data["image"]:sub(1, 4):lower() == "http" then
      HTTP.downloadImage(data['image'], function(path, err)
        if err then g_logger.warning("HTTP error: " .. err .. " - " .. data['image']) return end
        if not offer.image then return end
        offer.image:setImageSource(path)
      end)
    elseif data["image"] and data["image"]:len() > 1 then
      offer.image:setImageSource(data["image"])
    end
  else
    g_logger.error("Invalid shop offer type: " .. tostring(data["type"]))
    return
  end
  offer:setId("offer_" .. category .. "_" .. shop.offers:getChildCount())
  offer.title:setText(data["title"])
  offer.description:setText(data["description"])
  -- Card-side price label: thousand-separated for readability (200 / 950 / 1.000…)
  offer.priceFrame.price:setText(string.format("%d", data["cost"]))
  offer.offerId = data["id"]
  -- Same zebra striping as the history table — even cards get the lighter
  -- darken, odd cards the deeper one. Applied via background-color so the
  -- button image-color (which the focus/hover states drive) stays free.
  if shop.offers:getChildCount() % 2 == 0 then
    offer:setBackgroundColor("#0000001a")
  else
    offer:setBackgroundColor("#00000033")
  end
  -- Stash the source data on the widget so selectOffer / buySelected can
  -- read everything without a back-lookup into CATEGORIES.
  offer.offerData = data
  offer.offerCategory = category

  -- Card click → populate the right detail panel. The shop.offers
  -- TextList connects onChildFocusChange in createShop() so we don't
  -- need a per-widget handler here. Double-click still buys directly.
  if category ~= 0 then
    offer.onDoubleClick = buyOffer
  end
end


-- Render the selected offer in the right detail panel. Called from the
-- offer-card focus handler. `widget` is the offer Panel (ShopOfferItem etc.)
--
-- All detail widgets live INSIDE shop.detailPanel — they're not direct
-- children of the shop window. Have to traverse through detailPanel,
-- otherwise the lookups silently return nil and the right column never
-- updates (visible bug: clicking a card does nothing in the detail area).
function selectOffer(widget)
  if not shop or not widget then return end
  local panel = shop.detailPanel
  if not panel then return end
  local data = widget.offerData
  if not data then return end

  panel.detailName:setText(data["title"] or "")

  local frame = panel.detailIconFrame
  local iconItem = frame.detailIcon
  local iconCreature = frame.detailCreature
  local iconImage = frame.detailImage
  iconItem:hide(); iconCreature:hide(); iconImage:hide()

  if data["type"] == "item" then
    iconItem:setItemId(data["item"] or 0)
    iconItem:setItemCount(data["count"] or 1)
    iconItem:setShowCount(false)
    iconItem:show()
  elseif data["type"] == "outfit" then
    iconCreature:setOutfit(data["outfit"])
    if data["outfit"] and data["outfit"]["rotating"] then
      iconCreature:setAutoRotating(true)
    end
    iconCreature:show()
  elseif data["type"] == "image" then
    if data["image"] and data["image"]:sub(1, 4):lower() == "http" then
      HTTP.downloadImage(data['image'], function(path, err)
        if err then return end
        iconImage:setImageSource(path)
      end)
    elseif data["image"] then
      iconImage:setImageSource(data["image"])
    end
    iconImage:show()
  end

  panel.detailPriceFrame.detailPrice:setText(string.format("%d", data["cost"] or 0))
  panel.detailDescriptionFrame.detailDescription:setText(data["description"] or "")

  if widget.offerCategory and widget.offerCategory ~= 0 then
    selectedOffer = {
      category = widget.offerCategory,
      offer = tonumber(widget:getId():split("_")[3]),
      title = data["title"], cost = data["cost"], id = widget.offerId
    }
    panel.detailBuyButton:setEnabled(true)
  else
    selectedOffer = {}
    panel.detailBuyButton:setEnabled(false)
  end
end


-- Wired to the right-panel "Buy Now!" button. Reuses the existing buyOffer
-- confirmation flow by faking a widget id that buyOffer's split("_") parser
-- expects. Keeps the legacy double-click-to-buy ergonomics unchanged.
function buySelected()
  if not selectedOffer or not selectedOffer.category or not selectedOffer.offer then
    return
  end
  local fakeId = "offer_" .. selectedOffer.category .. "_" .. selectedOffer.offer
  local widget = shop.offers:getChildById(fakeId)
  if widget then
    buyOffer(widget)
  end
end


function changeCategory(widget, newCategory)
  if not newCategory then
    return
  end

  if g_game.getFeature(GameIngameStore) and widget ~= newCategory and not otcv8shop then
    local serviceType = 0
    if g_game.getFeature(GameTibia12Protocol) then
      serviceType = 2
    end
    g_game.requestStoreOffers(newCategory.name:getText(), serviceType)
  end

  -- If we were in history mode (historyPanel visible, button labelled
  -- "Offers"), restore the offers layout before populating the new
  -- category. Without this, picking a sidebar category from history view
  -- left the right column showing the history table and the History
  -- button stuck on "Offers".
  if browsingHistory then
    if shop.historyPanel then shop.historyPanel:setVisible(false) end
    if shop.offers then shop.offers:setVisible(true) end
    if shop.offersScrollBar then shop.offersScrollBar:setVisible(true) end
    if shop.detailPanel then shop.detailPanel:setVisible(true) end
    local btn = shop.bottomBar and shop.bottomBar.transactionHistory
    if btn then
      btn:setText(tr('History'))
    end
  end
  browsingHistory = false
  local id = tonumber(newCategory:getId():split("_")[2])
  clearOffers()
  for i, offer in ipairs(CATEGORIES[id]["offers"]) do
    addOffer(id, offer)
  end
  -- Auto-select the first offer of the freshly-loaded category so the
  -- detail panel never sits empty (matches the spec screenshot which
  -- shows the first Premium tier pre-selected). We call selectOffer
  -- explicitly in addition to :focus() because a TextList doesn't always
  -- fire onChildFocusChange for a programmatic focus while the parent
  -- window is hidden (createShop runs before the user opens the shop).
  local firstOffer = shop.offers:getChildByIndex(1)
  if firstOffer then
    firstOffer:focus()
    selectOffer(firstOffer)
  else
    -- No offers in this category — clear the right side so it doesn't
    -- still show whatever was selected from the previous category.
    selectedOffer = {}
    local panel = shop.detailPanel
    if panel then
      panel.detailName:setText("")
      panel.detailPriceFrame.detailPrice:setText("")
      panel.detailDescription:setText("")
      panel.detailBuyButton:setEnabled(false)
      panel.detailIconFrame.detailIcon:hide()
      panel.detailIconFrame.detailCreature:hide()
      panel.detailIconFrame.detailImage:hide()
    end
  end
end

function buyOffer(widget)
  if not widget then
    return
  end
  local split = widget:getId():split("_")
  if #split ~= 3 then
    return
  end
  local category = tonumber(split[2])  
  local offer = tonumber(split[3])  
  local item = CATEGORIES[category]["offers"][offer]
  if not item then
    return
  end
  
  selectedOffer = {category=category, offer=offer, title=item.title, cost=item.cost, id=widget.offerId}
  
  scheduleEvent(function()
      if msgWindow then
        msgWindow:destroy()
      end
      
      local title = tr("Buying from shop")
      local msg = "Do you want to buy " ..  item.title .. " for " .. item.cost .. " premium points?"
      msgWindow = displayGeneralBox(title, msg, {
          { text=tr('Yes'), callback=buyConfirmed },
          { text=tr('No'), callback=buyCanceled },
          anchor=AnchorHorizontalCenter}, buyConfirmed, buyCanceled)
      msgWindow:show()
      msgWindow:raise()
      msgWindow:focus()
      msgWindow:raise()
    end, 50)
end

function buyConfirmed()
  msgWindow:destroy()
  msgWindow = nil
  sendAction("buy", selectedOffer)
  if g_game.getFeature(GameIngameStore) and selectedOffer.id and not otcv8shop then
    local offerName = selectedOffer.title:lower()
    if string.find(offerName, "name") and string.find(offerName, "change") and modules.client_textedit then
      modules.client_textedit.singlelineEditor("", function(newName)
        if newName:len() == 0 then
          return
        end
        g_game.buyStoreOffer(selectedOffer.id, 1, newName)        
      end)
    else
      g_game.buyStoreOffer(selectedOffer.id, 0, "")
    end
  end
end

function buyCanceled()
  msgWindow:destroy()
  msgWindow = nil
  selectedOffer = {}
end