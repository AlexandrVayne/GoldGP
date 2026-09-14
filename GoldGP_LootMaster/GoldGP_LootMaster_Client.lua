-- GoldGP_LootMaster_Client.lua
-- Отложенный бут: тело (до «end of boot») исполняется ВНУТРИ boot(Addon, LM);
-- если ядро/глобаль LM ещё не готовы (нарушенный порядок загрузки), waiter
-- ждёт их вместо молчаливого выхода. Намеренно без ре-индентации.
local boot = function(Addon, LM)

local UIKit = Addon.UIKit or {}
local COLORS = UIKit.COLORS or {
  bg_main = { r = 0.06, g = 0.06, b = 0.08, a = 0.88 },
  bg_panel = { r = 0.10, g = 0.10, b = 0.13, a = 0.92 },
  border = { r = 0.00, g = 0.00, b = 0.00, a = 1.0 },
  border_gold = { r = 0.79, g = 0.64, b = 0.15, a = 1.0 },
  text_main = { r = 0.95, g = 0.95, b = 0.95, a = 1.0 },
  text_dim = { r = 0.55, g = 0.55, b = 0.55, a = 1.0 },
  text_gold = { r = 1.00, g = 0.84, b = 0.00, a = 1.0 },
}
local apply_backdrop = UIKit.apply_backdrop or function(frame, bg, edge, sz)
  frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    tile = false, tileSize = 0, edgeSize = sz or 1,
    insets = { left = 0, right = 0, top = 0, bottom = 0 }
  })
  frame:SetBackdropColor(bg.r, bg.g, bg.b, bg.a or 1.0)
  frame:SetBackdropBorderColor(edge.r, edge.g, edge.b, edge.a or 1.0)
end

-- Флаг звука — играет 1 раз за пачку входящих предметов.
-- Сбрасывается когда все окна лута закрыты (как в оригинальном EPGP_LootMaster).
local audioPlayed = false
local create_button = UIKit.create_button or function(parent, text, w, h, cb)
  local btn = CreateFrame("Button", nil, parent)
  btn:SetSize(w or 100, h or 24)
  apply_backdrop(btn, {r=0.14,g=0.14,b=0.18,a=0.95}, {r=0.40,g=0.32,b=0.15,a=1}, 2)
  btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  btn.text:SetPoint("CENTER", btn, "CENTER", 0, 1)
  btn.text:SetText(text)
  btn.text:SetTextColor(0.92, 0.90, 0.80)
  btn:SetScript("OnClick", function() if cb then cb() end PlaySound("igMainMenuOptionCheckBoxOn") end)
  return btn
end

-- ============================================================================
-- СОСТОЯНИЕ КЛИЕНТА
-- ============================================================================
local clientFrame = nil       -- главный фрейм окна
local lootFrames = {}         -- массив подокон (по одному на предмет)
local timerFrame = nil        -- OnUpdate таймер

-- Запас высоты под полноценный тайтлбар шапки (прежде сверху был голый текст)
local CHROME_H = 8

-- Экспортируем lootFrames для Options (применение текстов кнопок)
LM._lootFrames = lootFrames

-- Хелпер — получить текст кнопки из LM.db (или дефолт)
local function get_btn_text(key, default)
  if LM.db and LM.db.global and LM.db.global[key] then
    return LM.db.global[key]
  end
  return default
end

-- ============================================================================
-- СОЗДАНИЕ ОКНА КАНДИДАТА
-- ============================================================================

function LM:InitClient()
  if clientFrame then return end

  -- Главный контейнер
  clientFrame = CreateFrame("Frame", "GoldGPLM_ClientFrame", UIParent)
  clientFrame:SetSize(530, 138)
  clientFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
  clientFrame:SetFrameStrata("DIALOG")
  clientFrame:SetMovable(true)
  clientFrame:EnableMouse(true)
  clientFrame:SetClampedToScreen(true)
  clientFrame:RegisterForDrag("LeftButton")
  clientFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  -- Сохранение позиции при перетаскивании
  clientFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, xOfs, yOfs = self:GetPoint(1)
    if point and Addon.db and Addon.db.global then
      if not Addon.db.global.lm_window_pos then Addon.db.global.lm_window_pos = {} end
      Addon.db.global.lm_window_pos.client = { point = point, relPoint = relPoint, x = xOfs, y = yOfs }
    end
  end)
  -- Восстановление позиции
  if Addon.db and Addon.db.global and Addon.db.global.lm_window_pos and Addon.db.global.lm_window_pos.client then
    local pos = Addon.db.global.lm_window_pos.client
    clientFrame:ClearAllPoints()
    clientFrame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
  end
  apply_backdrop(clientFrame, COLORS.bg_main, COLORS.border, 2)
  clientFrame:Hide()

  -- Скрытие Client окна в бою (как ML окно).
  local combatFrame = CreateFrame("Frame")
  combatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
  combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
  combatFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
      if clientFrame and clientFrame:IsShown() then
        clientFrame:Hide()
        clientFrame.hiddenByCombat = true
      end
    elseif event == "PLAYER_REGEN_ENABLED" then
      if clientFrame and clientFrame.hiddenByCombat then
        -- Показываем только если есть активные loot frames
        local has_visible = false
        for _, lf in ipairs(lootFrames or {}) do
          if lf:IsShown() then has_visible = true; break end
        end
        if has_visible then
          clientFrame:Show()
        end
        clientFrame.hiddenByCombat = false
      end
    end
  end)

  -- Шапка окна: единый фабричный метод UIKit (прежде — отдельный FontString
  -- сверху и разрозненные кнопки масштаба)
  local chrome = UIKit.create_window_chrome(clientFrame, {
    title = "|cFFFFD700LootMaster|r |cFFCCCCCC— выбери лут на свой спек|r",
    icon  = "Interface\\Icons\\INV_Misc_Bag_10",
    on_close = function() clientFrame:Hide() end,
  })

  -- Контейнер для предметов (до 4 штук вертикально)
  local container = CreateFrame("Frame", nil, clientFrame)
  -- Верх контейнера — под шапкой (полоса 34px + зазор)
  container:SetPoint("TOPLEFT", clientFrame, "TOPLEFT", 10, -38)
  container:SetPoint("TOPRIGHT", clientFrame, "TOPRIGHT", -10, -38)
  container:SetPoint("BOTTOM", clientFrame, "BOTTOM", 0, 10)
  clientFrame.container = container

  -- Создаём 4 слота под предметы
  for i = 1, 4 do
    local lf = self:CreateLootFrame(container, i)
    lootFrames[i] = lf
  end

  -- Таймер для обратного отсчёта
  timerFrame = CreateFrame("Frame")
  timerFrame:Hide()
  timerFrame:SetScript("OnUpdate", function(self, elapsed)
    if not clientFrame or not clientFrame:IsShown() then
      self:Hide()
      return
    end
    local anyActive = false
    for _, lf in ipairs(lootFrames) do
      if lf:IsShown() and lf.data and lf.data.timeoutLeft then
        lf.data.timeoutLeft = lf.data.timeoutLeft - elapsed
        if lf.data.timeoutLeft <= 0 then
          -- Таймаут — авто-PASS + скрытие строки + обновление layout
          lf.data.timeoutLeft = 0
          -- self здесь = timerFrame (не LM), поэтому вызов явно через LM:
          LM:SendItemWanted(lf.data, LM.RESPONSE.TIMEOUT)
          lf:Hide()
          LM:UpdateClientLayout()
        else
          anyActive = true
          -- Обновить текст таймера
          if lf.timerText then
            lf.timerText:SetText(string.format("%d", math.ceil(lf.data.timeoutLeft)))
          end
          -- Обновить StatusBar
          if lf.timerBar then
            local pct = lf.data.timeoutLeft / (lf.data.timeout or 60)
            lf.timerBar:SetValue(math.max(0, pct * 100))
            -- Градиент таймера по оставшемуся времени
            local tr, tg, tb
            if pct > 0.5 then tr, tg, tb = 0.4, 0.8, 0.4
            elseif pct > 0.2 then tr, tg, tb = 0.9, 0.8, 0.2
            else tr, tg, tb = 0.9, 0.3, 0.2 end
            lf.timerBar:SetStatusBarColor(tr, tg, tb)
          end
        end
      end
    end
    if not anyActive then
      self:Hide()
      clientFrame:Hide()
    end
  end)

  -- Регистрируем окно для Escape
  tinsert(UISpecialFrames, "GoldGPLM_ClientFrame")
end

-- Создать подокно для одного предмета
function LM:CreateLootFrame(parent, index)
  local ROW_HEIGHT = 100  -- +10 для кнопок внизу
  local lf = CreateFrame("Frame", nil, parent)
  lf:SetSize(parent:GetWidth(), ROW_HEIGHT)
  lf:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * (ROW_HEIGHT + 5)))
  apply_backdrop(lf, COLORS.bg_panel, COLORS.border, 1)
  lf:Hide()

  -- Иконка предмета (48×48)
  -- Прижата к верхнему краю (TOPLEFT)
  lf.icon = CreateFrame("Button", nil, lf)
  lf.icon:SetSize(48, 48)
  lf.icon:SetPoint("TOPLEFT", lf, "TOPLEFT", 8, -8)
  lf.icon:SetNormalTexture("Interface\\Icons\\INV_Misc_QuestionMark")
  lf.icon:SetScript("OnEnter", function(self)
    if lf.data and lf.data.link then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(lf.data.link)
      GameTooltip:Show()
    end
  end)
  lf.icon:SetScript("OnLeave", function(self)
    if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
  end)

  -- Рамка иконки по цвету редкости
  lf.iconBorder = lf:CreateTexture(nil, "BORDER")
  lf.iconBorder:SetPoint("TOPLEFT", lf.icon, "TOPLEFT", -2, 2)
  lf.iconBorder:SetPoint("BOTTOMRIGHT", lf.icon, "BOTTOMRIGHT", 2, -2)
  lf.iconBorder:SetTexture("Interface\\Buttons\\WHITE8x8")
  lf.iconBorder:SetVertexColor(1, 1, 1, 1)

  -- Контейнер для текста (текст по центру по вертикали)
  local textGroup = CreateFrame("Frame", nil, lf)
  textGroup:SetAllPoints(lf)
  lf.textGroup = textGroup

  -- Название предмета (выровнено по центру)
  lf.nameText = textGroup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  lf.nameText:SetPoint("CENTER", textGroup, "CENTER", 0, 25)
  lf.nameText:SetText("")
  lf.nameText:SetWidth(lf:GetWidth() - 20)
  lf.nameText:SetJustifyH("CENTER")

  -- Тип предмета (GameFontNormal)
  lf.typeText = textGroup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  lf.typeText:SetPoint("CENTER", textGroup, "CENTER", 0, 8)
  lf.typeText:SetText("")
  lf.typeText:SetWidth(lf:GetWidth() - 20)
  lf.typeText:SetJustifyH("CENTER")
  lf.typeText:SetTextColor(0.8, 0.8, 0.8)

  -- Информация: iLvl, GP (по центру, под типом)
  lf.infoText = textGroup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  lf.infoText:SetPoint("CENTER", textGroup, "CENTER", 0, -8)
  lf.infoText:SetText("")
  lf.infoText:SetWidth(lf:GetWidth() - 20)
  lf.infoText:SetJustifyH("CENTER")
  lf.infoText:SetTextColor(1, 0.84, 0)

  -- Кнопки привязаны к нижней части lf, не к icon
  -- Тексты кнопок берутся из LM.db (настраиваются в Options)
  lf.btnNeed = create_button(lf, get_btn_text("btn_need_text", "Мейн спек"), 90, 24, function()
    LM:SendItemWanted(lf.data, LM.RESPONSE.NEED)
    lf:Hide()
    LM:UpdateClientLayout()
  end)
  lf.btnNeed:SetPoint("BOTTOMLEFT", lf, "BOTTOMLEFT", 8, 8)
  -- Цветной фон кнопки Need
  apply_backdrop(lf.btnNeed, {r=0.10,g=0.22,b=0.10,a=0.95}, {r=0.30,g=0.65,b=0.30,a=1}, 2)

  lf.btnOffspec = create_button(lf, get_btn_text("btn_offspec_text", "Офф спек"), 80, 24, function()
    LM:SendItemWanted(lf.data, LM.RESPONSE.OFFSPEC)
    lf:Hide()
    LM:UpdateClientLayout()
  end)
  lf.btnOffspec:SetPoint("LEFT", lf.btnNeed, "RIGHT", 6, 0)
  -- Цветной фон кнопки Offspec
  apply_backdrop(lf.btnOffspec, {r=0.22,g=0.17,b=0.05,a=0.95}, {r=0.65,g=0.50,b=0.15,a=1}, 2)

  lf.btnPass = create_button(lf, get_btn_text("btn_pass_text", "Откажусь"), 75, 24, function()
    LM:SendItemWanted(lf.data, LM.RESPONSE.PASS)
    lf:Hide()
    LM:UpdateClientLayout()
  end)
  lf.btnPass:SetPoint("LEFT", lf.btnOffspec, "RIGHT", 6, 0)

  -- Таймер (текст + StatusBar) — справа от кнопки Откажусь
  lf.timerText = lf:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  lf.timerText:SetPoint("LEFT", lf.btnPass, "RIGHT", 12, 0)
  lf.timerText:SetText("60")
  lf.timerText:SetTextColor(1, 0.5, 0)

  lf.timerBar = CreateFrame("StatusBar", nil, lf)
  lf.timerBar:SetSize(80, 8)
  lf.timerBar:SetPoint("LEFT", lf.timerText, "RIGHT", 4, 0)
  lf.timerBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  lf.timerBar:SetMinMaxValues(0, 100)
  lf.timerBar:SetValue(100)
  lf.timerBar:SetStatusBarColor(0.4, 0.8, 0.4)

  return lf
end

-- ============================================================================
-- ОТОБРАЖЕНИЕ ПРЕДМЕТОВ В ОКНЕ
-- ============================================================================

function LM:UpdateClientLayout()
  if not clientFrame then return end

  -- Считаем видимые предметы
  local visibleCount = 0
  for _, lf in ipairs(lootFrames) do
    if lf:IsShown() then
      visibleCount = visibleCount + 1
    end
  end

  if visibleCount == 0 then
    -- Сброс флага звука — следующая пачка предметов снова сыграет звук
    audioPlayed = false
    clientFrame:Hide()
    return
  end

  -- Пересчитываем позиции видимых фреймов
  local y = 0
  for _, lf in ipairs(lootFrames) do
    if lf:IsShown() then
      lf:SetPoint("TOPLEFT", clientFrame.container, "TOPLEFT", 0, -y)
      -- ROW_HEIGHT (100) + gap (5) = 105
      y = y + 105
    end
  end

  -- Подгоняем высоту окна
  clientFrame:SetHeight(30 + CHROME_H + y + 10)  -- шапка + строки лута + нижний отступ
  clientFrame:Show()
end

-- ============================================================================
-- ОБРАБОТЧИКИ
-- ============================================================================

-- Кандидат получил DO_YOU_WANT — показать предмет в окне
function LM:HandleDoYouWant(loot)
  if not clientFrame then self:InitClient() end
  if not clientFrame then return end

  -- Дедуп по lootKey (в V2 lootKey ≠ itemID).
  -- Проверяем И clientLootList И отображённые lootFrames (окна).
  -- Если loot с таким lootKey уже есть — игнорируем, не открываем второе окно.
  -- Это отбрасывает (а) echo от RAID broadcast, (б) повторные DO_YOU_WANT,
  -- (в) дубли от 3-х срабатываний OPEN_MASTER_LOOT_LIST.
  -- Внимание: dedup по lootKey (не itemID), поэтому два одинаковых предмета
  -- с разными lootKey дают два независимых окна.
  for _, existing in ipairs(LM.state.clientLootList) do
    if existing.lootKey == loot.lootKey then
      if Addon.Log and Addon.Log.Debug then
        Addon.Log:Debug("[LootMaster] HandleDoYouWant: duplicate lootKey=%s in clientLootList, ignoring",
          tostring(loot.lootKey))
      end
      return
    end
  end
  -- Дополнительная проверка по отображённым окнам (lootFrames).
  -- На случай если loot удалили из clientLootList (HandleLooted/Discard) но окно ещё видно.
  for _, lf in ipairs(lootFrames) do
    if lf:IsShown() and lf.data and lf.data.lootKey == loot.lootKey then
      if Addon.Log and Addon.Log.Debug then
        Addon.Log:Debug("[LootMaster] HandleDoYouWant: duplicate lootKey=%s in lootFrames (window shown), ignoring",
          tostring(loot.lootKey))
      end
      return
    end
  end

  -- Сохраняем ML имя
  LM.state.mlName = loot.mlName

  -- Слот ищется ДО добавления в clientLootList — иначе при отсутствии
  -- свободного frame в clientLootList остаётся stale-запись, блокирующая
  -- все последующие DO_YOU_WANT для того же lootKey.
  local freeSlot = nil
  for i, lf in ipairs(lootFrames) do
    if not lf:IsShown() then
      freeSlot = lf
      break
    end
  end

  if not freeSlot then
    -- Нет места (максимум 4 предмета) — игнорируем, НЕ добавляя в clientLootList
    if Addon.Log then
      Addon.Log:Warn("[LootMaster] Too many loot items, ignoring %s", tostring(loot.link))
    end
    return
  end

  -- Добавляем ТОЛЬКО после успешного поиска freeSlot (см. инвариант выше).
  tinsert(LM.state.clientLootList, loot)

  -- Заполняем слот данными
  freeSlot.data = loot
  freeSlot.data.timeoutLeft = loot.timeout or 60

  -- Иконка
  if loot.texture and loot.texture ~= "" then
    freeSlot.icon:SetNormalTexture(loot.texture)
  else
    freeSlot.icon:SetNormalTexture("Interface\\Icons\\INV_Misc_QuestionMark")
  end

  -- Название (с цветом по редкости) + рамка иконки
  -- Один вызов через кэш (вместо двух GetItemInfo)
  local itemName, _, rarity = LM:GetCachedItemInfo(loot.link)
  local r, g, b = 1, 1, 1
  if rarity and rarity >= 2 then
    r, g, b = GetItemQualityColor(rarity)
  end
  if itemName then
    freeSlot.nameText:SetText(itemName)
    freeSlot.nameText:SetTextColor(r, g, b)
  else
    freeSlot.nameText:SetText(loot.link or "Unknown item")
    freeSlot.nameText:SetTextColor(r, g, b)
  end
  -- Применить цвет редкости к рамке иконки
  if freeSlot.iconBorder then
    freeSlot.iconBorder:SetVertexColor(r, g, b, 1)
  end

  -- Информация: тип предмета, iLvl, GP
  -- Тип предмета на русском
  local INVTYPE_RU = {
    ["INVTYPE_HEAD"] = "Голова",
    ["INVTYPE_NECK"] = "Триня",
    ["INVTYPE_SHOULDER"] = "Плечи",
    ["INVTYPE_CHEST"] = "Грудь",
    ["INVTYPE_ROBE"] = "Грудь",
    ["INVTYPE_WAIST"] = "Пояс",
    ["INVTYPE_LEGS"] = "Ноги",
    ["INVTYPE_FEET"] = "Ступни",
    ["INVTYPE_WRIST"] = "Запястья",
    ["INVTYPE_HAND"] = "Перчатки",
    ["INVTYPE_FINGER"] = "Кольцо",
    ["INVTYPE_TRINKET"] = "Триня",
    ["INVTYPE_CLOAK"] = "Плащ",
    ["INVTYPE_WEAPON"] = "Оружие",
    ["INVTYPE_2HWEAPON"] = "Посох",
    ["INVTYPE_WEAPONMAINHAND"] = "Правая рука",
    ["INVTYPE_WEAPONOFFHAND"] = "Левая рука",
    ["INVTYPE_HOLDABLE"] = "Левая рука",
    ["INVTYPE_SHIELD"] = "Щит",
    ["INVTYPE_RANGED"] = "Дальний бой",
    ["INVTYPE_RANGEDRIGHT"] = "Дальний бой",
    ["INVTYPE_THROWN"] = "Метательное",
    ["INVTYPE_RELIC"] = "Реликвия",
  }
  local itemType = ""
  if loot.equipLoc and INVTYPE_RU[loot.equipLoc] then
    itemType = INVTYPE_RU[loot.equipLoc]
  end
  freeSlot.typeText:SetText(itemType)

  local infoParts = {}
  if loot.ilevel and loot.ilevel > 0 then
    tinsert(infoParts, "iLvl " .. loot.ilevel)
  end
  if loot.gpValue and loot.gpValue > 0 then
    tinsert(infoParts, "|cFFFFD700GP: " .. loot.gpValue .. "|r")
  end
  freeSlot.infoText:SetText(table.concat(infoParts, "  "))

  -- Показываем с fade-in
  freeSlot:SetAlpha(0)
  freeSlot:Show()
  UIFrameFadeIn(freeSlot, 0.25, 0, 1)
  -- Звуковое оповещение при открытии окна лута (как в оригинальном EPGP_LootMaster)
  if not audioPlayed then
    PlaySoundFile("Sound\\interface\\AuctionWindowClose.wav")
    audioPlayed = true
  end
  self:UpdateClientLayout()

  -- Запускаем таймер
  timerFrame:Show()

  -- Отправляем GEAR (текущий шмот в слоте) обратно ML
  self:SendGearInfo(loot)

  if Addon.Log then
    Addon.Log:Debug("[LootMaster] DO_YOU_WANT shown: %s", tostring(loot.link))
  end
end

-- Кандидат получил LOOTED — убрать предмет из окна.
-- Поиск по lootKey (не itemID): LOOTED-протокол V2 содержит lootKey первым
-- полем, поэтому клиент ищет конкретный экземпляр.
-- Два одинаковых предмета: LOOTED первого закрывает только первый popup.
function LM:HandleLooted(lootKey, player, link, lootType, lootGP)
  -- Удаляем по lootKey из clientLootList
  for i = #LM.state.clientLootList, 1, -1 do
    local loot = LM.state.clientLootList[i]
    if loot.lootKey == lootKey then
      tremove(LM.state.clientLootList, i)
    end
  end

  -- Скрываем соответствующий lootFrame по lootKey
  for _, lf in ipairs(lootFrames) do
    if lf:IsShown() and lf.data and lf.data.lootKey == lootKey then
      lf:Hide()
      lf.data = nil
    end
  end
  self:UpdateClientLayout()

  if Addon.Log then
    Addon.Log:Debug("[LootMaster] LOOTED: lootKey=%s player=%s link=%s",
      tostring(lootKey), tostring(player), tostring(link))
  end
end

-- Кандидат получил DISCARD — убрать предмет.
-- Поиск по lootKey (не itemID): DISCARD V2 содержит lootKey.
-- Два одинаковых предмета: DISCARD первого НЕ закрывает второй popup.
-- ML также вызывает эту функцию (т.к. ML может быть кандидатом).
-- Второй аргумент (sender) игнорируется — совместимость с ML:HandleDiscard(lootKey, sender).
function LM:HandleDiscard(lootKey, sender)
  -- Поиск по lootKey в clientLootList
  for i = #LM.state.clientLootList, 1, -1 do
    local loot = LM.state.clientLootList[i]
    if loot.lootKey == lootKey then
      tremove(LM.state.clientLootList, i)
    end
  end
  -- Скрытие lootFrame по lootKey
  for _, lf in ipairs(lootFrames) do
    if lf:IsShown() and lf.data and lf.data.lootKey == lootKey then
      lf:Hide()
      lf.data = nil
    end
  end
  self:UpdateClientLayout()
end

-- ============================================================================
-- БЕЗОПАСНАЯ ОЧИСТКА КЛИЕНТСКОГО UI
-- ============================================================================
-- Сбрасывает все активные loot frames, clientLootList, останавливает таймер.
-- ВНИМАНИЕ: вызывает только в безопасных местах (НЕ при обычном ответе на
-- один предмет — иначе можно закрыть другие активные предметы):
--   - отключение LootMaster;
--   - смена Master Looter — старые окна от прошлого ML больше не валидны;
--   - выход из группы/рейда;
--   - явная очистка тестового режима (/gg loot testreset);
--   - ADDON_UNLOAD (если аддон выгружается).
-- Для удаления ОДНОГО предмета используйте HandleLooted / HandleDiscard.
-- ============================================================================

function LM:ResetClientLootState(reason)
  if Addon.Log and Addon.Log.Debug then
    Addon.Log:Debug("[LootMaster] ResetClientLootState: reason=%s", tostring(reason))
  end
  -- Скрываем все lootFrames и обнуляем их данные
  for _, lf in ipairs(lootFrames) do
    if lf.data then lf.data = nil end
    if lf:IsShown() then lf:Hide() end
  end
  -- Полная очистка clientLootList (создаём новый массив чтобы не портить ссылки)
  LM.state.clientLootList = {}
  -- Останавливаем timer (он сам себя останавливает если clientFrame не показан,
  -- но мы явно прячем чтобы не тратить CPU на OnUpdate)
  if timerFrame then timerFrame:Hide() end
  -- Скрываем clientFrame
  if clientFrame then clientFrame:Hide() end
  -- Сбрасываем звуковой флаг (для следующей пачки предметов)
  audioPlayed = false
  -- Сбрасываем mlName: при смене ML следующий DO_YOU_WANT от нового ML
  -- будет принят (проверка sender-vs-mlName проходит при LM.state.mlName == nil).
  LM.state.mlName = nil
end

-- ============================================================================
-- ОТПРАВКА ОТВЕТОВ ML
-- ============================================================================

-- Отправить WANT (выбор кандидата)
function LM:SendItemWanted(loot, response)
  if not loot then return end
  -- Заметки убраны: отправляем пустой note
  local note = ""

  -- Отправляем lootKey как первое поле (вместо itemID).
  -- WANT:lootKey^response^note
  local payload = string.format("%s^%d^%s", loot.lootKey or "", response, note)
  LM:SendToML("WANT", payload)

  -- Скрываем клиентский popup после ответа.
  -- Поиск по lootKey (не itemID) — два одинаковых предмета: ответ
  -- на первый НЕ скрывает popup второго.
  for _, lf in ipairs(lootFrames) do
    if lf:IsShown() and lf.data and lf.data.lootKey == loot.lootKey then
      lf:Hide()
      lf.data = nil
    end
  end
  self:UpdateClientLayout()

  if Addon.Log then
    Addon.Log:Debug("[LootMaster] WANT sent: lootKey=%s response=%d note=%s",
      tostring(loot.lootKey), response, note)
  end
end

-- Отправить GEAR (текущий шмот в слоте)
function LM:SendGearInfo(loot)
  if not loot or not loot.equipLoc then return end

  local INVTYPE_SLOTS = {
    ["INVTYPE_HEAD"] = {"HeadSlot"},
    ["INVTYPE_NECK"] = {"NeckSlot"},
    ["INVTYPE_SHOULDER"] = {"ShoulderSlot"},
    ["INVTYPE_CHEST"] = {"ChestSlot"},
    ["INVTYPE_ROBE"] = {"ChestSlot"},
    ["INVTYPE_WAIST"] = {"WaistSlot"},
    ["INVTYPE_LEGS"] = {"LegsSlot"},
    ["INVTYPE_FEET"] = {"FeetSlot"},
    ["INVTYPE_WRIST"] = {"WristSlot"},
    ["INVTYPE_HAND"] = {"HandsSlot"},
    ["INVTYPE_FINGER"] = {"Finger0Slot", "Finger1Slot"},
    ["INVTYPE_TRINKET"] = {"Trinket0Slot", "Trinket1Slot"},
    ["INVTYPE_CLOAK"] = {"BackSlot"},
    ["INVTYPE_WEAPON"] = {"MainHandSlot", "SecondaryHandSlot"},
    ["INVTYPE_2HWEAPON"] = {"MainHandSlot"},
    ["INVTYPE_WEAPONMAINHAND"] = {"MainHandSlot"},
    ["INVTYPE_WEAPONOFFHAND"] = {"SecondaryHandSlot"},
    ["INVTYPE_HOLDABLE"] = {"SecondaryHandSlot"},
    ["INVTYPE_SHIELD"] = {"SecondaryHandSlot"},
    ["INVTYPE_RANGED"] = {"RangedSlot"},
    ["INVTYPE_RANGEDRIGHT"] = {"RangedSlot"},
    ["INVTYPE_THROWN"] = {"RangedSlot"},
    ["INVTYPE_RELIC"] = {"RangedSlot"},
  }

  local slots = INVTYPE_SLOTS[loot.equipLoc]
  if not slots then return end

  -- Send only numeric fields (itemID, gp, ilvl) — no item links (254 byte limit)
  local itemID1, itemID2 = 0, 0
  local gp1, gp2 = 0, 0
  local ilvl1, ilvl2 = 0, 0

  for i, slotName in ipairs(slots) do
    local slotID = GetInventorySlotInfo(slotName)
    if slotID then
      local link = GetInventoryItemLink("player", slotID)
      if link then
        local id = LM.GetItemIDFromLink(link) or 0
        local _, _, _, ilvl = LM:GetCachedItemInfo(link)
        local gp = LM:GetGPValue(link) or 0
        if i == 1 then
          itemID1 = id
          gp1 = gp
          ilvl1 = ilvl or 0
        else
          itemID2 = id
          gp2 = gp
          ilvl2 = ilvl or 0
        end
      end
    end
  end

  -- GEAR:lootKey^itemID1^gp1^ilvl1^itemID2^gp2^ilvl2
  -- lootKey как первое поле (вместо itemID)
  local payload = string.format("%s^%d^%d^%d^%d^%d^%d",
    loot.lootKey or "", itemID1, gp1, ilvl1, itemID2, gp2, ilvl2)
  LM:SendToML("GEAR", payload)

  if Addon.Log then
    Addon.Log:Debug("[LootMaster] GEAR sent: lootKey=%s id1=%d ilvl1=%d",
      tostring(loot.lootKey), itemID1, ilvl1)
  end
end

  -- Отложенный путь — main уже мог пройти PostLoadInit (LM.db готов):
  -- инициализируем клиент сами. В нормальном пути LM.db ещё нет — InitClient
  -- вызовет main на ADDON_LOADED (двойного запуска нет ни в одном из путей).
  if LM.db and LM.InitClient then
    LM:InitClient()
  end
end  -- end of boot(Addon, LM)

-- ============================================================================
-- ЗАПУСК — сразу, либо отложенно (waiter до 30с)
-- ============================================================================
if GoldGP and _G.GoldGPLootMaster then
  boot(GoldGP, _G.GoldGPLootMaster)
else
  local waiter = CreateFrame("Frame")
  local waited = 0
  waiter:RegisterEvent("ADDON_LOADED")
  waiter:RegisterEvent("PLAYER_LOGIN")
  waiter:SetScript("OnEvent", function() waited = 999 end)
  waiter:SetScript("OnUpdate", function(self, elapsed)
    waited = waited + elapsed
    if GoldGP and _G.GoldGPLootMaster then
      self:UnregisterAllEvents()
      self:Hide()
      boot(GoldGP, _G.GoldGPLootMaster)
    elseif waited > 30 then
      self:UnregisterAllEvents()
      self:Hide()
      -- Диагностику уже вывел GoldGP_LootMaster.lua (ядро не загрузилось)
    end
  end)
end
