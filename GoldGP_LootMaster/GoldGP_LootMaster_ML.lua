-- GoldGP_LootMaster_ML.lua
-- Отложенный бут — тело (до «end of boot») исполняется ВНУТРИ
-- boot(Addon, LM); если ядро/глобаль LM ещё не готовы (нарушенный порядок
-- загрузки), waiter ждёт их вместо молчаливого выхода. Намеренно без ре-индентации.
local boot = function(Addon, LM)

local UIKit = Addon.UIKit or {}
local COLORS = UIKit.COLORS or {
  bg_main = { r = 0.06, g = 0.06, b = 0.08, a = 0.88 },
  bg_panel = { r = 0.10, g = 0.10, b = 0.13, a = 0.92 },
  bg_row = { r = 0.08, g = 0.08, b = 0.10, a = 0.85 },
  bg_row_hover = { r = 0.20, g = 0.18, b = 0.10, a = 0.95 },
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

-- Классовые иконки
local CLASS_ICON_TEXTURE = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
local CLASS_ICON_TCOORDS = CLASS_ICON_TCOORDS or {
  ["WARRIOR"]     = { 0,    0.25, 0,    0.25 },
  ["MAGE"]        = { 0.25, 0.5,  0,    0.25 },
  ["ROGUE"]       = { 0.5,  0.75, 0,    0.25 },
  ["DRUID"]       = { 0.75, 1.0,  0,    0.25 },
  ["HUNTER"]      = { 0,    0.25, 0.25, 0.5  },
  ["SHAMAN"]      = { 0.25, 0.5,  0.25, 0.5  },
  ["PRIEST"]      = { 0.5,  0.75, 0.25, 0.5  },
  ["WARLOCK"]     = { 0.75, 1.0,  0.25, 0.5  },
  ["PALADIN"]     = { 0,    0.25, 0.5,  0.75 },
  ["DEATHKNIGHT"] = { 0.25, 0.5,  0.5,  0.75 },
}

-- ============================================================================
-- ФАЗА 4: ML — ПЕРЕХВАТ И РАССЫЛКА
-- ============================================================================

local mlFrame = nil           -- главное окно ML
local mlEventFrame = nil      -- фрейм для событий ML
local mlScrollFrame = nil     -- FauxScrollFrame
local mlRows = {}             -- строки таблицы
local ML_ROW_HEIGHT = 20
local ML_VISIBLE_ROWS = 15
local ML_WINDOW_WIDTH = 700
local ML_WINDOW_HEIGHT = 415

-- Дебаунс RefreshMLTable — объявлен ЗДЕСЬ (до использования в HandleWANT/HandleGEAR)
local mlRefreshPending = false
local mlRefreshFrame = nil
local function ScheduleMLRefresh()
  if mlRefreshPending then return end
  mlRefreshPending = true
  if not mlRefreshFrame then
    mlRefreshFrame = CreateFrame("Frame")
    mlRefreshFrame:Hide()
  end
  mlRefreshFrame:Show()
  mlRefreshFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    mlRefreshPending = false
    LM:RefreshMLTable()
  end)
end

-- Максимальная группа рейда для кандидатов (1-5)
local MAX_RAID_GROUP = 5

-- ============================================================================
-- ИНИЦИАЛИЗАЦИЯ ML
-- ============================================================================

-- IsMasterLooter() не существует в WoW 3.3.5a (появился в Cataclysm+).
-- Проверяем через GetLootMethod() — если lootmethod == "master" и player является ML.
-- В рейде: mlRaidID указывает на индекс рейда → GetRaidRosterInfo(mlRaidID) → имя.
-- В группе: mlPartyID == 0 → player, mlPartyID == N → partyN.
function LM:IsPlayerMasterLooter()
  local lootmethod, mlPartyID, mlRaidID = GetLootMethod()
  if lootmethod ~= "master" then return false end
  if mlRaidID then
    local name = GetRaidRosterInfo(mlRaidID)
    if name then
      name = strsplit("-", name) or name
      return name == UnitName("player")
    end
    return false
  end
  if mlPartyID == 0 then
    return true  -- player is ML в группе
  end
  return false
end

function LM:InitML()
  if mlEventFrame then return end

  -- BeginLootSession генерирует sessionId, lootSeq, mlName,
  -- закрывает старые клиентские popup (если были).
  LM:BeginLootSession(UnitName("player"))

  mlEventFrame = CreateFrame("Frame")
  mlEventFrame:RegisterEvent("OPEN_MASTER_LOOT_LIST")
  mlEventFrame:RegisterEvent("CHAT_MSG_LOOT")
  mlEventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
  mlEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
  mlEventFrame:RegisterEvent("LOOT_CLOSED")  -- авто-очистка зависшего лута
  -- LOOT_OPENED не регистрируется: перехват лута — только через OPEN_MASTER_LOOT_LIST
  -- (срабатывает при ПКМ по конкретному предмету).
  -- перехват назначения ML (как в EPGP Lootmaster)
  mlEventFrame:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
  mlEventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
  mlEventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")

  mlEventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "OPEN_MASTER_LOOT_LIST" then
      -- перехват ПКМ по предмету в луте → окно LootMaster.
      if LM.trackingEnabled == false then
        return  -- Tracking отключён — дефолтный UI
      end
      LM:OnOpenMasterLootList()
    elseif event == "CHAT_MSG_LOOT" then
      LM:OnChatMsgLoot(...)
    elseif event == "PLAYER_REGEN_DISABLED" then
      -- Скрываем окно ML в бою
      if mlFrame and mlFrame:IsShown() then
        mlFrame:Hide()
        mlFrame.hiddenByCombat = true
      end
    elseif event == "PLAYER_REGEN_ENABLED" then
      -- Показываем окно ML после боя
      if mlFrame and mlFrame.hiddenByCombat then
        mlFrame:Show()
        mlFrame.hiddenByCombat = false
      end
    elseif event == "LOOT_CLOSED" then
      -- авто-очистка зависшего лута
      LM:ScheduleLootCleanup()
    elseif event == "PARTY_LOOT_METHOD_CHANGED" or event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
      -- проверка назначения ML (как в EPGP lootmaster.lua:864 GROUP_UPDATE)
      LM:CheckLootMasterStatus()
    end
  end)

  -- Создаём окно ML (Фаза 5)
  self:CreateMLWindow()

  -- refresh ML table after GP award (candidate GP/PR changes)
  if Addon and Addon.RegisterCallback then
    Addon:RegisterCallback("GPAward", function()
      ScheduleMLRefresh()
    end)
    -- When Storage transitions to CURRENT, flush any pending GP retries.
    -- Addon:Fire(...) passes only the trailing varargs (NOT the
    -- event name) — see Core.lua Addon:Fire. So the callback receives exactly
    -- ONE arg: newState.
    -- Re-entry guard: a single CURRENT transition can't fire FlushPendingGP
    -- multiple times (e.g. REMOTE_FLUSHING -> STALE -> CURRENT -> FLUSHING -> CURRENT
    -- from recovery path may fire StorageStateChanged twice within 100ms).
    Addon:RegisterCallback("StorageStateChanged", function(newState)
      if newState ~= "CURRENT" then return end
      if LM._flush_in_progress then
        if Addon and Addon.Log and Addon.Log.Debug then
          Addon.Log:Debug("[LootMaster] FlushPendingGP already running, skipping StorageStateChanged")
        end
        return
      end
      LM._flush_in_progress = true
      local ok, err = pcall(function() LM:FlushPendingGP() end)
      LM._flush_in_progress = false
      if not ok and Addon and Addon.Log then
        Addon.Log:Warn("[LootMaster] FlushPendingGP failed: %s", tostring(err))
      end
    end)
  end

  -- начальная проверка ML при загрузке
  LM:CheckLootMasterStatus()

  -- restore lootTable from SavedVariables (crash recovery)
  -- Only restores records with pending GP retries.
  LM:RestoreLootTable()
end

-- ============================================================================
-- ПЕРЕХВАТ НАЗНАЧЕНИЯ ML (как в EPGP lootmaster.lua:864)
-- ============================================================================
-- Когда лидер рейда назначает ответственного за добычу (ML), проверяем:
--   - если ML = player и tracking ещё не определён → показать диалог
--   - если ML = player и trackingEnabled = true → перехватываем OPEN_MASTER_LOOT_LIST
--   - если ML = player и trackingEnabled = false → не перехватываем (дефолтный UI)
--   - если ML != player → trackingEnabled сбрасывается (на следующий раз спросит снова)

local current_ml_name = nil  -- кто сейчас ML (чтобы не триггерить диалог повторно)

function LM:CheckLootMasterStatus()
  local lootmethod, mlPartyID, mlRaidID = GetLootMethod()
  local newLootMaster = nil

  if lootmethod == "master" then
    if mlRaidID then
      -- в рейде
      newLootMaster = GetRaidRosterInfo(mlRaidID)
      if newLootMaster then
        newLootMaster = strsplit("-", newLootMaster) or newLootMaster
      end
    elseif mlPartyID == 0 then
      -- player is ML в группе
      newLootMaster = UnitName("player")
    elseif mlPartyID then
      -- кто-то другой в группе ML
      newLootMaster = UnitName("party" .. mlPartyID)
    end
  end

  -- Если newLootMaster = nil (GetLootMethod ещё не обновился),
  -- НЕ сбрасываем — подождём следующего события когда данные обновятся.
  if not newLootMaster and current_ml_name then
    if lootmethod ~= "master" then
      newLootMaster = nil
    else
      return
    end
  end

  -- Обрабатываем ВСЕ переходы ML (nil->A, A->B, A->player,
  -- player->A, A->nil). EndLootSession извлекает pending-GP записи в recoveryQueue
  -- до сброса lootTable, закрывает клиентские popup, сбрасывает sessionId/mlName/isML.
  -- BeginLootSession генерирует новый sessionId, закрывает popup.
  if current_ml_name ~= newLootMaster then
    local old_ml = current_ml_name
    local myName = UnitName("player")

    -- Сначала заканчиваем старую сессию (если была)
    if old_ml then
      if old_ml == myName then
        -- player -> A  или  player -> nil: мы теряли ML, сохраняем pending GP
        LM:EndLootSession("player_lost_ml")
      else
        -- A -> B  или  A -> nil (где A != player): мы не ML,
        -- но старые popup от прошлого ML больше не валидны.
        if LM.ResetClientLootState then
          LM:ResetClientLootState("ml_change_a_to_b_or_nil")
        end
        LM.state.mlName = nil
      end
    end

    -- Обновляем current_ml_name и LM.state.mlName
    current_ml_name = newLootMaster

    if newLootMaster == myName then
      -- nil -> player  или  A -> player: мы стали ML
      LM.state.isML = true
      LM:BeginLootSession(myName)
      -- всегда показываем диалог — без запоминания выбора.
      LM:ShowLootMasterDialog()
    else
      -- nil -> A, A -> B, player -> A, A -> nil — мы не ML
      LM.state.isML = false
      LM.trackingEnabled = nil
      LM.state.mlName = newLootMaster  -- nil если A->nil; имя нового ML если A->B
    end
  end
end

-- Диалог "Использовать LootMaster?" — только 2 кнопки (Да/Нет),
-- всегда спрашивать при каждом назначении ML.
function LM:ShowLootMasterDialog()
  -- гильд-лок — вне разрешённой гильдии диалог не показываем
  if Addon.IsEnabled and not Addon:IsEnabled() then
    LM.trackingEnabled = false
    LM.state.isML = false
    return
  end
  StaticPopupDialogs["GOLDGPLM_ASK_TRACKING"] = {
    text = "|cFFFFD700Вы назначены ответственным за добычу (Master Looter)!|r\n\nИспользовать LootMaster для распределения добычи?\n\n|cFF808080• Да — лут будет перехвачен, у кандидатов появятся окна с кнопками (Мейн/Офф/Откажусь)\n• Нет — лут распределяется через дефолтный UI WoW (ПКМ → выбрать игрока), без GP|r",
    button1 = "Да",
    button2 = "Нет",
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 0,
    showAlert = 1,
    OnAccept = function()
      LM.trackingEnabled = true
      LM.state.isML = true
      LM.state.mlName = UnitName("player")
      if Addon and Addon.Print then
        Addon.Print("[LootMaster] Включён — лут будет перехватываться")
      end
      if Addon and Addon.Log then
        Addon.Log:Info("[LootMaster] Tracking enabled by player")
      end
    end,
    OnCancel = function()
      LM.trackingEnabled = false
      if Addon and Addon.Print then
        Addon.Print("[LootMaster] Отключён — используется дефолтный UI раздачи")
      end
      if Addon and Addon.Log then
        Addon.Log:Info("[LootMaster] Tracking disabled by player")
      end
    end,
  }
  StaticPopup_Show("GOLDGPLM_ASK_TRACKING")
end

-- ============================================================================
-- ПЕРЕХВАТ OPEN_MASTER_LOOT_LIST
-- ============================================================================

-- Авто-очистка зависшего лута после LOOT_CLOSED
-- (C_Timer не существует в 3.3.5a — используем OnUpdate)
local cleanupFrame = nil
function LM:ScheduleLootCleanup()
  -- Очистка по персональному дедлайну каждого предмета:
  -- announcedAt + timeout + 10 сек (grace period).
  -- Предметы, чей таймаут ещё не истёк, переживают LOOT_CLOSED и продолжают голосоваться.
  if not cleanupFrame then
    cleanupFrame = CreateFrame("Frame")
    cleanupFrame:Hide()
  end
  cleanupFrame:Show()
  cleanupFrame:SetScript("OnUpdate", function(self, elapsed)
    if not LM.state.lootTable or not next(LM.state.lootTable) then
      -- lootTable пуст — останавливаем таймер
      self:Hide()
      return
    end
    local now = time()
    local any_expired = false
    -- safe iteration — собирать ключи для удаления, удалять после цикла
    local keys_to_remove = {}
    for key, loot in pairs(LM.state.lootTable) do
      local deadline = (loot.announcedAt or 0) + (loot.timeout or 60) + 10
      if now >= deadline then
        any_expired = true
  -- DISCARD по lootKey (не по itemID).
        -- Два одинаковых предмета: DISCARD первого НЕ закрывает второй popup.
        -- view_записи — ЛОКАЛЬНЫЕ копии окна просмотра у кандидата:
        -- их срок жизни никого, кроме этого клиента, не касается.
        -- для view_ключей — просто тихое удаление из lootTable.
        if loot.key and not string.match(loot.key, "^view_") then
          if GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0 then
            LM:SendToClient("DISCARD", loot.key, nil)
          else
            for _, name in ipairs(loot.candidateOrder or {}) do
              LM:SendToClient("DISCARD", loot.key, name)
            end
          end
          -- Self-delivery: if ML is also a candidate, close their window too
          local myName = UnitName("player")
          if loot.candidates and loot.candidates[myName] then
            LM:HandleDiscard(loot.key, myName)
          end
        end
        tinsert(keys_to_remove, key)
        -- лут удаляется из lootTable — удаляем его ключ и из
        -- очереди pendingAwards, иначе "призрак" навсегда блокирует очередь
        -- этого itemID+игрока (Peek всегда возвращает первый элемент).
        LM:PurgePendingAwardByLootKey(key)
        if Addon.Log and Addon.Log.Debug then
          Addon.Log:Debug("[LootMaster] Cleanup: item %s expired (deadline=%d, now=%d)",
            tostring(loot.itemID), deadline, now)
        end
      end
    end
    -- удаляем ключи после итерации (safe)
    for _, key in ipairs(keys_to_remove) do
      LM.state.lootTable[key] = nil
    end
    -- TTL-страховка — выкидываем зависшие записи очереди
    if any_expired or (now % 30 < 1) then
      LM:PurgeStalePendingAwards()
    end
    -- Скрываем окно ML если все предметы удалены
    if any_expired and mlFrame and mlFrame:IsShown() and not next(LM.state.lootTable) then
      mlFrame:Hide()
    end
  end)
end

-- Дебаунс для OnOpenMasterLootList — OPEN_MASTER_LOOT_LIST в WoW 3.3.5a
-- срабатывает 3 раза при одном ПКМ клике. Игнорируем повторные вызовы в течение 2 сек.
local last_open_master_loot_time = 0
local last_open_master_loot_link = nil

function LM:OnOpenMasterLootList()
  if not LM:IsPlayerMasterLooter() then return end
  if not IsInGuild() then return end
  -- гильд-лок — вне разрешённой гильдии LootMaster не перехватывает лут
  if Addon.IsEnabled and not Addon:IsEnabled() then return end

  local slot = LootFrame.selectedSlot or 1
  local lootIcon, lootName, lootQuantity, quality = GetLootSlotInfo(slot)
  local lootLink = GetLootSlotLink(slot)

  if not lootLink then return end
  if quality and quality < 2 then return end

  -- Дебаунс — если тот же link был добавлен < 2 сек назад, пропускаем.
  local now = GetTime()
  if lootLink == last_open_master_loot_link and (now - last_open_master_loot_time) < 2.0 then
    if Addon and Addon.Log and Addon.Log.Debug then
      Addon.Log:Debug("[LootMaster] OnOpenMasterLootList: debounced (same link within 2s)")
    end
    return
  end
  last_open_master_loot_time = now
  last_open_master_loot_link = lootLink

  StaticPopup_Hide("CONFIRM_LOOT_DISTRIBUTION")
  -- Закрываем дефолтное контекстное меню Blizzard (список кандидатов),
  -- как в оригинальном EPGP (lootmaster_ml.lua:1830). Иначе при ПКМ открывается И дефолтное
  -- меню И окно аддона. CloseDropDownMenus() закрывает все открытые dropdown-меню.
  CloseDropDownMenus()
  self:AddLoot(lootLink, lootName, lootIcon, lootQuantity, quality, slot)
end


-- ============================================================================
-- ADDLOOT — добавить предмет в lootTable и разослать кандидатам
-- ============================================================================

function LM:AddLoot(link, name, texture, quantity, quality, slotID)
  -- Получаем информацию о предмете
  -- через кэш (вместо прямого GetItemInfo)
  -- GetCachedItemInfo возвращает: name, link, rarity, level, equipLoc (5 значений)
  local _, _, rarity, level, equipLoc = LM:GetCachedItemInfo(link)
  if not rarity then
    -- Предмет ещё не в кэше — попробуем через itemID из ссылки
    local itemID = LM.GetItemIDFromLink(link)
    if itemID and LM.CUSTOM_ITEM_DATA[itemID] then
      local data = LM.CUSTOM_ITEM_DATA[itemID]
      rarity = data[1]
      level = data[2]
      equipLoc = data[3]
    end
  end

  -- Считаем GP
  local gpValue = LM:GetGPValue(link) or 0

  -- Извлекаем itemID
  local itemID = LM.GetItemIDFromLink(link) or tostring(GetTime())

  -- lootKey строится по схеме sessionId:itemID:slotID-or-seq.
  -- Два одинаковых предмета имеют один itemID, но разные slotID (или lootSeq),
  -- поэтому lootKey уникален: каждый экземпляр независим и может быть
  -- отдан разным кандидатам.
  -- Внимание: 3-х срабатывания OPEN_MASTER_LOOT_LIST обрабатываются дебаунсом
  -- в OnOpenMasterLootList (2с по link) — этого достаточно.
  if not LM.state.sessionId then
    -- На случай если AddLoot вызвали до InitML (например, через /gg loot add)
    LM.state.sessionId = string.format("s_%d_%d", time(), math.floor(GetTime() * 1000))
  end
  LM.state.lootSeq = (LM.state.lootSeq or 0) + 1
  local lootKey = LM.state.sessionId .. ":" .. tostring(itemID) .. ":" .. tostring(slotID or LM.state.lootSeq)

  -- Проверяем что этот lootKey ещё не добавлен (на случай если тот же link
  -- прошёл дебаунс через 2+ сек и не должен множить записи).
  -- Если lootKey уже есть — обновляем quantity.
  if LM.state.lootTable[lootKey] then
    LM.state.lootTable[lootKey].quantity = (LM.state.lootTable[lootKey].quantity or 1) + (quantity or 1)
    if Addon.Log and Addon.Log.Debug then
      Addon.Log:Debug("[LootMaster] AddLoot: duplicate lootKey=%s, updated quantity=%d",
        tostring(lootKey), LM.state.lootTable[lootKey].quantity)
    end
    return
  end

  -- Создаём запись в lootTable
  local loot = {
    key = lootKey,
    link = link,
    name = name or "Unknown",
    itemID = itemID,
    texture = texture or "",
    rarity = rarity or quality or 0,
    ilevel = level or 0,
    equipLoc = equipLoc or "",
    gpValue = gpValue,
    quantity = quantity or 1,
    slotID = slotID,
    mayDistribute = true,
    candidates = {},
    candidateOrder = {},
    announcedAt = time(),  -- для персонального дедлайна в ScheduleLootCleanup
    timeout = (LM.db and LM.db.global and LM.db.global.loot_timeout) or 60,  -- кэшируем
  }
  LM.state.lootTable[lootKey] = loot

  -- Мы ML
  LM.state.isML = true
  LM.state.mlName = UnitName("player")

  -- Строим список кандидатов
  self:BuildCandidateList(loot)

  -- Рассылаем DO_YOU_WANT всем кандидатам
  self:AnnounceLoot(loot)

  -- НЕ показываем окно ML сразу.
  -- Окно ML откроется автоматически после того как:
  --   - ML ответит сам (если он в списке кандидатов) → HandleWANT
  --   - либо таймер выйдет → SendItemWanted(TIMEOUT) → HandleWANT
  -- Если ML НЕ в списке кандидатов — окно откроется сразу (ML не нужно отвечать).
  local myName = UnitName("player")
  if not loot.candidates[myName] then
    -- ML не кандидат — показываем окно сразу
    self:ShowMLWindow(loot)
  else
    -- ML кандидат — ждём его ответа или таймаута
    if Addon.Log then
      Addon.Log:Debug("[LootMaster] ML is also candidate, waiting for response/timeout before showing ML window")
    end
  end

  if Addon.Log then
    Addon.Log:Info("[LootMaster] AddLoot: %s GP=%d candidates=%d",
      tostring(name), gpValue, #loot.candidateOrder)
  end

  -- persist lootTable after adding new loot (crash recovery)
  LM:PersistLootTable()
end

-- ============================================================================
-- ПОСТРОЕНИЕ СПИСКА КАНДИДАТОВ
-- ============================================================================

function LM:BuildCandidateList(loot)
  loot.candidates = {}
  loot.candidateOrder = {}

  -- В рейде: перебираем raid1..40, фильтруем группы 1-5
  if GetNumRaidMembers() > 0 then
    for i = 1, GetNumRaidMembers() do
      local name, _, subgroup = GetRaidRosterInfo(i)
      if name and subgroup and subgroup <= MAX_RAID_GROUP then
        name = strsplit("-", name) or name
        -- Проверяем может ли кандидат получить лут
        local canGet = false
        for cID = 1, 40 do
          local cName = GetMasterLootCandidate(cID)
          if cName and cName == name then
            canGet = true
            loot.candidates[name] = {
              response = LM.RESPONSE.WAIT,
              note = "",
              class = select(2, UnitClass("raid"..i)) or "WARRIOR",
              candidateID = cID,
              gold = 0, gp = 0, pr = 0,
              currentitem = 0, currentilvl = 0, currentgp = 0,
              lootType = nil, lootGP = 0,
            }
            tinsert(loot.candidateOrder, name)
            break
          end
        end
      end
    end
  elseif GetNumPartyMembers() > 0 then
    -- В группе: player + party1..4
    local pname = UnitName("player")
    if pname then
      -- Проверяем что player может получить лут
      for cID = 1, 40 do
        local cName = GetMasterLootCandidate(cID)
        if cName and cName == pname then
          loot.candidates[pname] = {
            response = LM.RESPONSE.WAIT, note = "",
            class = select(2, UnitClass("player")) or "WARRIOR",
            candidateID = cID,
            gold = 0, gp = 0, pr = 0,
            currentitem = 0, currentilvl = 0, currentgp = 0,
            lootType = nil, lootGP = 0,
          }
          tinsert(loot.candidateOrder, pname)
          break
        end
      end
    end
    for i = 1, GetNumPartyMembers() do
      local name = UnitName("party"..i)
      if name then
        for cID = 1, 40 do
          local cName = GetMasterLootCandidate(cID)
          if cName and cName == name then
            loot.candidates[name] = {
              response = LM.RESPONSE.WAIT, note = "",
              class = select(2, UnitClass("party"..i)) or "WARRIOR",
              candidateID = cID,
              gold = 0, gp = 0, pr = 0,
              currentitem = 0, currentilvl = 0, currentgp = 0,
              lootType = nil, lootGP = 0,
            }
            tinsert(loot.candidateOrder, name)
            break
          end
        end
      end
    end
  end

  -- Заполняем Gold/GP/PR из данных GoldGP
  for name, cand in pairs(loot.candidates) do
    local gold, gp, main = Addon:GetMemberData(name)
    if gold then
      cand.gold = gold
      cand.gp = gp or 0
      cand.pr = (gp and gp > 0) and (gold / gp) or 0
    end
  end
end

-- ============================================================================
-- РАССЫЛКА DO_YOU_WANT
-- ============================================================================

function LM:AnnounceLoot(loot)
  -- Таймаут берётся из LM.db (настраивается в Options, по умолчанию 60)
  local timeout = 60
  if LM.db and LM.db.global and LM.db.global.loot_timeout then
    timeout = LM.db.global.loot_timeout
  end
  -- payload с lootKey как первым field:
  --   DO_YOU_WANT:lootKey^itemID^gpValue^ilvl^quality^equipLoc^timeout^link^texture
  local payload = string.format("%s^%s^%d^%d^%d^%s^%d^%s^%s",
    loot.key,           -- lootKey
    loot.itemID,
    loot.gpValue,
    loot.ilevel,
    loot.rarity,
    loot.equipLoc or "",
    timeout,
    loot.link,
    loot.texture or ""
  )

  -- Явный self-delivery ТОЛЬКО ОДИН РАЗ.
  -- В Sirus 3.3.5a RAID/PARTY broadcast эхо НЕ возвращается отправителю надёжно
  -- (может не прийти или прийти дубликатом).
  -- Один broadcast кандидатам + один локальный вызов HandleDoYouWant
  -- для ML-as-candidate. Echo (если придёт) будет отброшен клиентским dedup'ом
  -- по lootKey в HandleDoYouWant (Client.lua:385-393).
  local myName = UnitName("player")
  local inRaid = GetNumRaidMembers() > 0
  local inParty = GetNumPartyMembers() > 0

  -- testMode — не отправляем реальные RAID/PARTY broadcast,
  -- но self-delivery оставляем (для тестов без рейда).
  if (inRaid or inParty) and not LM.testMode then
    -- Broadcast ОДИН РАЗ всему каналу
    LM:SendToClient("DO_YOU_WANT", payload, nil)  -- nil = broadcast всему каналу
    -- Явный self-delivery для ML-as-candidate ровно один раз.
    if loot.candidates and loot.candidates[myName] then
      local selfLoot = {
        lootKey  = loot.key,
        itemID   = loot.itemID,
        gpValue  = loot.gpValue,
        ilevel   = loot.ilevel,
        quality  = loot.rarity,  -- ML-side хранит .rarity, клиент ожидает .quality
        equipLoc = loot.equipLoc,
        timeout  = timeout,
        link     = loot.link,
        texture  = loot.texture,
        mlName   = myName,
      }
      LM:HandleDoYouWant(selfLoot)
    end
  else
    -- WHISPER (нет группы) или testMode: адресная рассылка + self-delivery.
    -- В цикле SendToClient сам сделает self-check если target==player.
    -- В testMode рассылаем только себе (myName) — не заходим в реальный RAID.
    if LM.testMode then
      if loot.candidates and loot.candidates[myName] then
        LM:SendToClient("DO_YOU_WANT", payload, myName)
      end
    else
      for _, name in ipairs(loot.candidateOrder) do
        LM:SendToClient("DO_YOU_WANT", payload, name)
      end
    end
  end

  -- master-side таймаут для кандидатов без аддона.
  -- Через (timeout + 10) сек проверяем — если кандидат всё ещё WAIT (response == 0),
  -- значит у него нет аддона (не ответил) — помечаем как TIMEOUT.
  -- Используем OnUpdate frame (C_Timer не существует в 3.3.5a).
  if not LM.mlTimeoutFrame then
    LM.mlTimeoutFrame = CreateFrame("Frame")
    LM.mlTimeoutFrame:Hide()
    LM.mlTimeoutFrame.checks = {}  -- список {lootKey=..., deadline=...}
    LM.mlTimeoutFrame:SetScript("OnUpdate", function(self, elapsed)
      local now = time()
      local remaining = {}
      for _, check in ipairs(self.checks) do
        if now >= check.deadline then
          -- Время вышло — проверить кандидатов
          local loot = LM.state.lootTable[check.lootKey]
          if loot and loot.candidates then
            local changed = false
            for name, cand in pairs(loot.candidates) do
              if (cand.response or 0) == 0 then  -- WAIT
                cand.response = 4  -- TIMEOUT (LM.RESPONSE.TIMEOUT = 4)
                changed = true
                if Addon and Addon.Log then
                  Addon.Log:Info("[LootMaster] Master-side timeout for %s on %s (no addon?)",
                    name, loot.link or "?")
                end
              end
            end
            if changed then
              ScheduleMLRefresh()
            end
          end
        else
          tinsert(remaining, check)
        end
      end
      self.checks = remaining
      if #self.checks == 0 then
        self:Hide()
      end
    end)
  end
  tinsert(LM.mlTimeoutFrame.checks, {
    lootKey = loot.key,
    deadline = time() + timeout + 10,  -- +10 сек запаса для ответа с аддоном
  })
  LM.mlTimeoutFrame:Show()
end

-- ============================================================================
-- ОБРАБОТКА WANT И GEAR
-- ============================================================================

function LM:HandleWANT(lootKey, sender, response, note)
  -- guard — только текущий ML должен обрабатывать WANT.
  if not LM.state.isML then return end
  -- Прямой O(1) lookup по lootKey вместо linear scan by itemID.
  local loot = LM:FindLootByKey(lootKey)
  if not loot then return end
  if not loot.candidates[sender] then return end

  -- Обновляем ответ
  loot.candidates[sender].response = response
  loot.candidates[sender].note = note

  -- Если ML сам ответил (sender == player) и окно ML ещё не показано — открыть сейчас.
  -- Это срабатывает когда ML является кандидатом на лут и нажал кнопку или таймер вышел.
  if LM.state.isML and sender == UnitName("player") then
    if not mlFrame or not mlFrame:IsShown() or mlFrame.currentLoot ~= loot then
      LM:ShowMLWindow(loot)
    end
  end

  -- Разослать ML_VIEW не-ML кандидатам (если ml_view_all_enabled)
  LM:SendMLView(loot)

  -- Обновляем UI (через дебаунс)
  ScheduleMLRefresh()

  if Addon.Log then
    Addon.Log:Debug("[LootMaster] WANT from %s: lootKey=%s response=%d",
      tostring(sender), tostring(lootKey), response)
  end
end

function LM:HandleGEAR(lootKey, sender, gear)
  -- guard — только текущий ML должен обрабатывать GEAR.
  if not LM.state.isML then return end
  -- Прямой lookup по lootKey
  local loot = LM:FindLootByKey(lootKey)
  if not loot or not loot.candidates[sender] then return end

  loot.candidates[sender].currentitem = gear.item1 or 0
  loot.candidates[sender].currentilvl = gear.ilvl1 or 0
  loot.candidates[sender].currentgp = gear.gp1 or 0

  ScheduleMLRefresh()  -- дебаунс
end

-- ============================================================================
-- ML_VIEW — рассылка состояния таблицы не-ML кандидатам
-- ============================================================================
-- ML вызывает эту функцию после каждого HandleWANT (если ml_view_all_enabled).
-- Не-ML кандидат с включённой настройкой ml_view_all_enabled получит обновление
-- и покажет read-only окно ML.

local function serialize_candidates(loot)
  -- Формат: name,class,response,gold,gp,pr^name,class,response,gold,gp,pr^...
  -- ^ разделяет кандидатов, , разделяет поля
  local parts = {}
  for _, name in ipairs(loot.candidateOrder or {}) do
    local c = loot.candidates[name]
    if c then
      -- name,class,response,gold,gp,pr (pr с 2 знаками после запятой)
      local pr_str = c.pr and string.format("%.2f", c.pr) or "0"
      tinsert(parts, name .. "," .. (c.class or "WARRIOR") .. "," ..
        tostring(c.response or 0) .. "," .. tostring(c.gold or 0) .. "," ..
        tostring(c.gp or 0) .. "," .. pr_str)
    end
  end
  return table.concat(parts, "^")
end

function LM:SendMLView(loot)
  if not loot then return end
  -- Проверяем включена ли настройка ml_view_all_enabled у ML
  -- (ML решает рассылать или нет — клиенты просто принимают)
  local enabled = LM.db and LM.db.global and LM.db.global.ml_view_all_enabled
  if not enabled then return end

  local candidatesStr = serialize_candidates(loot)
  local payload = string.format("%s^%s^%s^%d^%d^%d^%s",
    tostring(loot.itemID or ""),
    tostring(loot.name or ""),
    tostring(loot.texture or ""),
    loot.gpValue or 0,
    loot.ilevel or 0,
    loot.rarity or 0,
    candidatesStr
  )
  -- one broadcast instead of N individual sends
  if GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0 then
    LM:SendToClient("ML_VIEW", payload, nil)  -- broadcast to all
  else
    for _, name in ipairs(loot.candidateOrder or {}) do
      if name ~= UnitName("player") then
        LM:SendToClient("ML_VIEW", payload, name)
      end
    end
  end
end

-- Не-ML кандидат получил ML_VIEW — обновить локальную lootTable и показать окно ML (если включено)
function LM:HandleMLView(itemID, itemName, texture, gpValue, ilevel, rarity, candidatesStr, sender)
  -- Проверяем свою настройку
  local enabled = LM.db and LM.db.global and LM.db.global.ml_view_all_enabled
  if not enabled then return end
  -- Если мы ML — игнорируем (у нас есть актуальная таблица)
  if LM.state.isML then return end

  -- Создаём/обновляем локальную запись loot (read-only: mayDistribute = false)
  local lootKey = "view_" .. tostring(itemID)
  local loot = LM.state.lootTable[lootKey]
  if not loot then
    loot = {
      key = lootKey,
      link = "|cffff8080|Hitem:" .. tostring(itemID) .. ":0:0:0:0:0:0:0:80|h[" .. tostring(itemName) .. "]|h|r",
      name = itemName,
      itemID = itemID,
      texture = texture,
      rarity = rarity,
      ilevel = ilevel,
      equipLoc = "",
      gpValue = gpValue,
      quantity = 1,
      slotID = nil,
      mayDistribute = false,  -- read-only — ПКМ (ShowCandidateMenu) не сработает
      -- announcedAt/timeout обязательны: без них ScheduleLootCleanup считает
      -- view-запись просроченной с первого тика — окно просмотра мгновенно умрёт.
      announcedAt = time(),
      timeout = 60,
      candidates = {},
      candidateOrder = {},
    }
    LM.state.lootTable[lootKey] = loot
  else
    -- Обновляем существующие поля
    loot.name = itemName
    loot.texture = texture
    loot.gpValue = gpValue
    loot.ilevel = ilevel
    loot.rarity = rarity
  end

  -- Парсим candidatesStr: name,class,response,gold,gp,pr^...
  -- Очищаем старых кандидатов
  wipe(loot.candidates)
  wipe(loot.candidateOrder)
  for candBlock in string.gmatch(candidatesStr, "([^%^]+)") do
    local cname, cclass, cresp, cgold, cgp, cpr = strsplit(",", candBlock)
    if cname then
      loot.candidates[cname] = {
        response = tonumber(cresp) or 0,
        note = "",
        class = cclass or "WARRIOR",
        candidateID = nil,
        gold = tonumber(cgold) or 0,
        gp = tonumber(cgp) or 0,
        pr = tonumber(cpr) or 0,
        currentitem = 0, currentilvl = 0, currentgp = 0,
        lootType = nil, lootGP = 0,
      }
      tinsert(loot.candidateOrder, cname)
    end
  end

  -- Показываем окно ML (read-only)
  if not mlFrame or not mlFrame:IsShown() or mlFrame.currentLoot ~= loot then
    LM:ShowMLWindow(loot)
  else
    LM:RefreshMLTable()
  end

  if Addon.Log then
    Addon.Log:Debug("[LootMaster] ML_VIEW received: item=%s candidates=%d", tostring(itemID), #loot.candidateOrder)
  end
end

-- ============================================================================
-- ФАЗА 5: ML — ОКНО С ТАБЛИЦЕЙ
-- ============================================================================

-- Колонки таблицы
local ML_COLS = {
  { name = "Кл",    width = 24,  align = "CENTER" },  -- иконка класса
  { name = "Кандидат", width = 110, align = "LEFT"   },
  { name = "Ответ",   width = 110, align = "LEFT"   },
  { name = "Звание",  width = 90,  align = "LEFT"   },
  { name = "Gold",    width = 60,  align = "RIGHT"  },
  { name = "GP",      width = 60,  align = "RIGHT"  },
  { name = "PR",      width = 60,  align = "RIGHT"  },
  { name = "iLvl",    width = 60,  align = "CENTER" },
}

function LM:CreateMLWindow()
  if mlFrame then return end

  mlFrame = CreateFrame("Frame", "GoldGPLM_MLFrame", UIParent)
  mlFrame:SetSize(ML_WINDOW_WIDTH, ML_WINDOW_HEIGHT)
  mlFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  mlFrame:SetFrameStrata("DIALOG")
  mlFrame:SetMovable(true)
  mlFrame:EnableMouse(true)
  mlFrame:SetClampedToScreen(true)
  mlFrame:RegisterForDrag("LeftButton")
  mlFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  -- сохранение позиции окна при перетаскивании
  mlFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, xOfs, yOfs = self:GetPoint(1)
    if point and Addon.db and Addon.db.global then
      if not Addon.db.global.lm_window_pos then Addon.db.global.lm_window_pos = {} end
      Addon.db.global.lm_window_pos.ml = { point = point, relPoint = relPoint, x = xOfs, y = yOfs }
    end
  end)
  -- Восстановление позиции
  if Addon.db and Addon.db.global and Addon.db.global.lm_window_pos and Addon.db.global.lm_window_pos.ml then
    local pos = Addon.db.global.lm_window_pos.ml
    mlFrame:ClearAllPoints()
    mlFrame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
  end
  apply_backdrop(mlFrame, COLORS.bg_main, COLORS.border, 2)
  mlFrame:Hide()
  mlFrame.currentLoot = nil
  -- Присваиваем LM.mlFrame — иначе гварды «if LM.mlFrame ...:Hide()» в
  -- EndLootSession / finish_test / TestReset не работают: открытое ML-окно
  -- не скроется при завершении сессии/теста.
  LM.mlFrame = mlFrame

  -- Шапка окна: единый фабричный метод UIKit
  local chrome = UIKit.create_window_chrome(mlFrame, {
    title = "|cFFFFD700Mad|r|cFFAAAAAATeaParty|r |cFF808080LootMaster|r",
    icon  = "Interface\\Icons\\INV_Misc_Bag_10",
    on_close = function() mlFrame:Hide() end,
  })
  local titleBar = chrome.title_bar

  -- Информация о предмете
  local itemArea = CreateFrame("Frame", nil, mlFrame)
  itemArea:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -2)
  itemArea:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, -2)
  itemArea:SetHeight(60)
  apply_backdrop(itemArea, COLORS.bg_panel, COLORS.border, 1)

  mlFrame.itemIcon = CreateFrame("Button", nil, itemArea)
  mlFrame.itemIcon:SetSize(48, 48)
  mlFrame.itemIcon:SetPoint("LEFT", itemArea, "LEFT", 10, 0)
  mlFrame.itemIcon:SetNormalTexture("Interface\\Icons\\INV_Misc_QuestionMark")

  mlFrame.itemName = itemArea:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  mlFrame.itemName:SetPoint("LEFT", mlFrame.itemIcon, "RIGHT", 10, 8)

  mlFrame.itemInfo = itemArea:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  mlFrame.itemInfo:SetPoint("LEFT", mlFrame.itemIcon, "RIGHT", 10, -10)
  mlFrame.itemInfo:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  -- GP override поле
  local gpLabel = itemArea:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  gpLabel:SetPoint("RIGHT", itemArea, "RIGHT", -120, 0)
  gpLabel:SetText("GP:")
  gpLabel:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

  mlFrame.gpEdit = CreateFrame("EditBox", "GoldGPLMMlGpEdit", itemArea, "InputBoxTemplate")
  mlFrame.gpEdit:SetSize(60, 20)
  mlFrame.gpEdit:SetPoint("RIGHT", itemArea, "RIGHT", -50, 0)
  mlFrame.gpEdit:SetAutoFocus(false)
  mlFrame.gpEdit:SetNumeric(true)
  mlFrame.gpEdit:SetMaxLetters(5)
  mlFrame.gpEdit:SetText("")

  -- Золотая рамка у GP-поля
  -- Обёртка-Frame с apply_backdrop позади EditBox, чтобы не конфликтовать с InputBoxTemplate
  local gpEditBorder = CreateFrame("Frame", nil, itemArea)
  gpEditBorder:SetSize(70, 26)
  gpEditBorder:SetPoint("CENTER", mlFrame.gpEdit, "CENTER", 0, 0)
  gpEditBorder:SetFrameLevel(mlFrame.gpEdit:GetFrameLevel() - 1)
  apply_backdrop(gpEditBorder, {r=0.06, g=0.06, b=0.08, a=0.85}, COLORS.border_gold, 2)

  -- Header таблицы
  local header = CreateFrame("Frame", nil, mlFrame)
  header:SetPoint("TOPLEFT", itemArea, "BOTTOMLEFT", 0, -2)
  header:SetPoint("TOPRIGHT", itemArea, "BOTTOMRIGHT", 0, -2)
  header:SetHeight(22)
  apply_backdrop(header, COLORS.bg_panel, COLORS.border, 1)

  -- Колонки синхронизированы с CreateMLRow
  local x = 10
  for i, col in ipairs(ML_COLS) do
    local hText = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hText:SetPoint("LEFT", header, "LEFT", x, 0)
    hText:SetWidth(col.width)
    hText:SetJustifyH(col.align)
    hText:SetText(col.name)
    hText:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)
    x = x + col.width + 4
  end

  -- ScrollFrame для списка кандидатов
  mlScrollFrame = CreateFrame("ScrollFrame", "GoldGPLM_MLScroll", mlFrame, "FauxScrollFrameTemplate")
  mlScrollFrame:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
  mlScrollFrame:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -22, -2)
  mlScrollFrame:SetPoint("BOTTOM", mlFrame, "BOTTOM", 0, 10)
  mlScrollFrame:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ML_ROW_HEIGHT, function()
      LM:RefreshMLTable()
    end)
  end)

  -- Создаём строки таблицы
  for i = 1, ML_VISIBLE_ROWS do
    local row = self:CreateMLRow(mlFrame, i)
    mlRows[i] = row
  end

  -- Кнопка Discard
  -- Рассылать DISCARD ВСЕМ кандидатам (broadcast).
  local discardBtn = create_button(mlFrame, "Отменить", 100, 24, function()
    if mlFrame.currentLoot then
      local loot = mlFrame.currentLoot
      -- DISCARD по lootKey (не itemID)
      local myName = UnitName("player")
      if LM.testMode then
        -- testMode: только self-delivery
        LM:HandleDiscard(loot.key)
      elseif GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0 then
        LM:SendToClient("DISCARD", loot.key, nil)  -- broadcast
        -- Self-delivery (if ML is also a candidate)
        if loot.candidates and loot.candidates[myName] then
          LM:HandleDiscard(loot.key)
        end
      elseif loot.candidateOrder then
        for _, name in ipairs(loot.candidateOrder) do
          LM:SendToClient("DISCARD", loot.key, name)
        end
      end
      -- Удаляем из lootTable
      LM.state.lootTable[loot.key] = nil
      mlFrame.currentLoot = nil
      -- переключаемся на следующий лут или скрываем окно
      local nextKey = next(LM.state.lootTable)
      if nextKey then
        LM:ShowMLWindow(LM.state.lootTable[nextKey])
      else
        mlFrame:Hide()
        LM:UpdateMLItemButtons()
      end
    end
  end)
  discardBtn:SetPoint("BOTTOMRIGHT", mlFrame, "BOTTOMRIGHT", -10, 8)

  -- ItemButtons слева для переключения между лутами (как в EPGP LM)
  -- Каждая кнопка = 32x32px, до 8 штук вертикально слева от mlFrame
  -- Клик по кнопке → переключение currentLoot на этот loot
  mlFrame.itemButtons = {}
  local LOOTBUTTON_SIZE = 28
  local LOOTBUTTON_MAXNUM = 8
  local LOOTBUTTON_PADDING = 4

  for i = 1, LOOTBUTTON_MAXNUM do
    local btn = CreateFrame("Button", nil, mlFrame)
    btn:SetSize(LOOTBUTTON_SIZE + 4, LOOTBUTTON_SIZE + 4)
    -- Слева от mlFrame, вертикально вниз от titleBar
    if i == 1 then
      btn:SetPoint("TOPRIGHT", mlFrame, "TOPLEFT", -4, -32)
    else
      btn:SetPoint("TOP", mlFrame.itemButtons[i-1], "BOTTOM", 0, -LOOTBUTTON_PADDING)
    end

    apply_backdrop(btn, COLORS.bg_panel, COLORS.border, 1)

    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetSize(LOOTBUTTON_SIZE, LOOTBUTTON_SIZE)
    btn.icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

    -- Tooltip + click
    btn:SetScript("OnEnter", function(self)
      if self.loot then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.loot.link)
        GameTooltip:Show()
      end
    end)
    btn:SetScript("OnLeave", function(self)
      if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
    end)
    btn:SetScript("OnClick", function(self)
      if self.loot then
        LM:ShowMLWindow(self.loot)
      end
    end)

    btn:Hide()
    mlFrame.itemButtons[i] = btn
  end

  -- Регистрируем для Escape
  tinsert(UISpecialFrames, "GoldGPLM_MLFrame")
end

-- Обновить ItemButtons слева — показать все активные луты, выделить текущий
function LM:UpdateMLItemButtons()
  if not mlFrame or not mlFrame.itemButtons then return end

  local idx = 0
  for key, loot in pairs(LM.state.lootTable) do
    idx = idx + 1
    if idx > #mlFrame.itemButtons then break end
    local btn = mlFrame.itemButtons[idx]
    btn.loot = loot
    btn.icon:SetTexture(loot.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
    -- Подсветка текущего лута — золотая рамка
    if mlFrame.currentLoot == loot then
      apply_backdrop(btn, COLORS.bg_panel, COLORS.border_gold, 2)
    else
      apply_backdrop(btn, COLORS.bg_panel, COLORS.border, 1)
    end
    btn:Show()
  end

  -- Скрыть неиспользуемые
  for i = idx + 1, #mlFrame.itemButtons do
    mlFrame.itemButtons[i]:Hide()
    mlFrame.itemButtons[i].loot = nil
  end
end

-- Создать строку таблицы
function LM:CreateMLRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(ML_WINDOW_WIDTH - 40, ML_ROW_HEIGHT)
  row:SetPoint("TOPLEFT", mlScrollFrame, "TOPLEFT", 0, -((index - 1) * ML_ROW_HEIGHT))
  apply_backdrop(row, COLORS.bg_row, COLORS.border, 1)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  -- Иконка класса
  row.classIcon = row:CreateTexture(nil, "ARTWORK")
  row.classIcon:SetSize(16, 16)
  row.classIcon:SetPoint("LEFT", row, "LEFT", 10, 0)
  row.classIcon:SetTexture(CLASS_ICON_TEXTURE)

  -- Позиции синхронизированы с ML_COLS
  -- Колонки: Кл(24), Кандидат(110), Ответ(110), Звание(90), Gold(60), GP(60), PR(60), iLvl(60)
  -- Шаг: width + 4 (gap)
  local x = 10  -- отступ для иконки класса
  x = x + 24 + 4  -- после иконки класса

  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.name:SetPoint("LEFT", row, "LEFT", x, 0)
  row.name:SetWidth(110)
  row.name:SetJustifyH("LEFT")
  x = x + 110 + 4

  -- Иконка ответа слева от текста
  row.responseIcon = row:CreateTexture(nil, "ARTWORK")
  row.responseIcon:SetSize(14, 14)
  row.responseIcon:SetPoint("LEFT", row, "LEFT", x, 0)
  row.responseIcon:Hide()

  row.response = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.response:SetPoint("LEFT", row, "LEFT", x + 18, 0)
  row.response:SetWidth(110 - 18)
  row.response:SetJustifyH("LEFT")
  x = x + 110 + 4

  -- Колонка "Звание"
  row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.rank:SetPoint("LEFT", row, "LEFT", x, 0)
  row.rank:SetWidth(90)
  row.rank:SetJustifyH("LEFT")
  x = x + 90 + 4

  row.gold = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.gold:SetPoint("LEFT", row, "LEFT", x, 0)
  row.gold:SetWidth(60)
  row.gold:SetJustifyH("RIGHT")
  x = x + 60 + 4

  row.gp = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.gp:SetPoint("LEFT", row, "LEFT", x, 0)
  row.gp:SetWidth(60)
  row.gp:SetJustifyH("RIGHT")
  x = x + 60 + 4

  row.pr = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.pr:SetPoint("LEFT", row, "LEFT", x, 0)
  row.pr:SetWidth(60)
  row.pr:SetJustifyH("RIGHT")
  x = x + 60 + 4

  row.ilvl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.ilvl:SetPoint("LEFT", row, "LEFT", x, 0)
  row.ilvl:SetWidth(60)
  row.ilvl:SetJustifyH("CENTER")

  -- Hover эффект
  row:SetScript("OnEnter", function(self)
    apply_backdrop(self, COLORS.bg_row_hover, COLORS.border_gold, 1)
  end)
  row:SetScript("OnLeave", function(self)
    -- Восстанавливаем базовый фон строки (зебра), не фиксированный COLORS.bg_row
    apply_backdrop(self, self.baseBg or COLORS.bg_row, COLORS.border, 1)
  end)

  -- Правый клик → контекстное меню
  row:SetScript("OnClick", function(self, button)
    if button == "RightButton" and row.candidateName and mlFrame.currentLoot then
      LM:ShowCandidateMenu(row.candidateName, mlFrame.currentLoot)
    end
  end)

  return row
end

-- ============================================================================
-- ПОКАЗ И ОБНОВЛЕНИЕ ОКНА ML
-- ============================================================================

function LM:ShowMLWindow(loot)
  if not mlFrame then self:CreateMLWindow() end
  if not mlFrame then return end

  mlFrame.currentLoot = loot

  -- Иконка и название предмета
  mlFrame.itemIcon:SetNormalTexture(loot.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
  -- Один вызов через кэш (вместо двух GetItemInfo)
  -- GetCachedItemInfo возвращает: name, link, rarity, level, equipLoc
  local itemName, _, rarity = LM:GetCachedItemInfo(loot.link)
  mlFrame.itemName:SetText(itemName or loot.name or "Unknown")
  -- Цвет по редкости
  if rarity and rarity >= 2 then
    local r, g, b = GetItemQualityColor(rarity)
    mlFrame.itemName:SetTextColor(r, g, b)
  elseif loot.rarity and loot.rarity >= 2 then
    local r, g, b = GetItemQualityColor(loot.rarity)
    mlFrame.itemName:SetTextColor(r, g, b)
  else
    mlFrame.itemName:SetTextColor(1, 1, 1)
  end

  -- Инфо: iLvl, GP
  local infoParts = {}
  if loot.ilevel and loot.ilevel > 0 then
    tinsert(infoParts, "iLvl " .. loot.ilevel)
  end
  if loot.gpValue and loot.gpValue > 0 then
    tinsert(infoParts, "|cFFFFD700GP: " .. loot.gpValue .. "|r")
  end
  mlFrame.itemInfo:SetText(table.concat(infoParts, "  "))

  -- GP override
  mlFrame.gpEdit:SetText(tostring(loot.gpValue or 0))
  mlFrame.gpEdit:SetScript("OnEnterPressed", function(self)
    local val = tonumber(self:GetText()) or loot.gpValue or 0
    loot.gpValue = val
    self:SetText(tostring(val))
    self:ClearFocus()
  end)
  mlFrame.gpEdit:SetScript("OnEditFocusLost", function(self)
    local val = tonumber(self:GetText()) or loot.gpValue or 0
    loot.gpValue = val
    self:SetText(tostring(val))
  end)

  mlFrame:Show()
  self:RefreshMLTable()
  self:UpdateMLItemButtons()  -- обновить кнопки предметов слева
end

-- Обновить таблицу кандидатов
function LM:RefreshMLTable()
  if not mlFrame or not mlFrame:IsShown() then return end
  local loot = mlFrame.currentLoot
  if not loot then return end

  -- Сортируем кандидатов: по ответу (NEED > OFFSPEC > PASS), потом по PR
  -- tiebreaker по имени для стабильной сортировки
  table.sort(loot.candidateOrder, function(a, b)
    local ca = loot.candidates[a]
    local cb = loot.candidates[b]
    if not ca or not cb then return false end
    local sa = LM.RESPONSE_SORT[ca.response] or 999
    local sb = LM.RESPONSE_SORT[cb.response] or 999
    if sa ~= sb then return sa < sb end
    -- При равных ответах — по PR (по убыванию)
    local pra = ca.pr or 0
    local prb = cb.pr or 0
    if pra ~= prb then return pra > prb end
    -- при равном PR — по имени (стабильная сортировка)
    return a < b
  end)

  local total = #loot.candidateOrder
  local offset = FauxScrollFrame_GetOffset(mlScrollFrame)

  for i = 1, ML_VISIBLE_ROWS do
    local row = mlRows[i]
    local idx = i + offset
    if idx <= total then
      local name = loot.candidateOrder[idx]
      local cand = loot.candidates[name]
      if cand then
        -- Иконка класса
        local coords = CLASS_ICON_TCOORDS[cand.class]
        if coords then
          row.classIcon:SetTexCoord(unpack(coords))
          row.classIcon:Show()
        else
          row.classIcon:Hide()
        end

        -- Имя
        row.name:SetText(name)
        row.name:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

        -- Ответ
        row.response:SetText(LM.RESPONSE_TEXT[cand.response] or "|cFF808080ожидание...|r")

        -- Иконка ответа
        if row.responseIcon then
          local iconPath = nil
          if cand.response == LM.RESPONSE.NEED then
            iconPath = "Interface\\RaidFrame\\ReadyCheck-Ready"
          elseif cand.response == LM.RESPONSE.OFFSPEC then
            iconPath = "Interface\\RaidFrame\\ReadyCheck-Waiting"
          elseif cand.response == LM.RESPONSE.PASS or cand.response == LM.RESPONSE.TIMEOUT then
            iconPath = "Interface\\RaidFrame\\ReadyCheck-NotReady"
          end
          if iconPath then
            row.responseIcon:SetTexture(iconPath)
            row.responseIcon:Show()
          else
            row.responseIcon:Hide()
          end
        end

        -- Звание
        local rankName = Addon.data.rank_name_data and Addon.data.rank_name_data[name] or "-"
        row.rank:SetText(rankName)
        local rc = Addon.GetRankColor and Addon:GetRankColor(name) or {r=0.6,g=0.6,b=0.6}
        row.rank:SetTextColor(rc.r, rc.g, rc.b)

        -- Gold
        row.gold:SetText(tostring(cand.gold or 0))
        row.gold:SetTextColor(COLORS.text_gold.r, COLORS.text_gold.g, COLORS.text_gold.b)

        -- GP
        row.gp:SetText(tostring(cand.gp or 0))
        row.gp:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

        -- PR
        if cand.pr and cand.pr > 0 then
          row.pr:SetText(string.format("%.2f", cand.pr))
        else
          row.pr:SetText("-")
        end
        row.pr:SetTextColor(COLORS.text_main.r, COLORS.text_main.g, COLORS.text_main.b)

        -- iLvl текущего шмота
        if cand.currentilvl and cand.currentilvl > 0 then
          row.ilvl:SetText(tostring(cand.currentilvl))
        else
          row.ilvl:SetText("---")
        end
        row.ilvl:SetTextColor(COLORS.text_dim.r, COLORS.text_dim.g, COLORS.text_dim.b)

        -- Сохраняем имя для контекстного меню
        row.candidateName = name

        -- Зебра строк таблицы + сохранение базового фона
        row.baseBg = (idx % 2 == 0) and COLORS.bg_row or {r=0.06,g=0.06,b=0.08,a=0.85}
        apply_backdrop(row, row.baseBg, COLORS.border, 1)

        row:Show()
      else
        row:Hide()
      end
    else
      row:Hide()
    end
  end

  FauxScrollFrame_Update(mlScrollFrame, total, ML_VISIBLE_ROWS, ML_ROW_HEIGHT)
end

-- ============================================================================
-- ФАЗА 6: КОНТЕКСТНОЕ МЕНЮ + ВЫДАЧА ЛУТА
-- ============================================================================

local dropDown = nil

function LM:ShowCandidateMenu(candidateName, loot)
  if not loot or not loot.mayDistribute then return end
  if not loot.candidates[candidateName] then return end

  if not CanEditOfficerNote() then
    Addon.PrintError("[LootMaster] Нет прав на офицерские ноты — GP не будет начислен")
  end

  if not dropDown then
    dropDown = CreateFrame("Frame", "GoldGPLM_DropDown", UIParent, "UIDropDownMenuTemplate")
    dropDown:SetID(1)
  end

  dropDown.candidate = candidateName
  dropDown.loot = loot

  UIDropDownMenu_Initialize(dropDown, function(...)
    LM:CandidateMenuInitialize(...)
  end, "MENU")

  ToggleDropDownMenu(1, nil, dropDown, "cursor", 0, 0)
end

function LM:CandidateMenuInitialize(frame, level, menuList)
  if not frame or not frame.candidate or not frame.loot then return end

  local candidate = frame.candidate
  local loot = frame.loot
  -- gpValue берётся из текущего loot.gpValue (которое может быть
  -- изменено через GP override поле в окне ML). 50% пересчитывается от текущего.
  local gpValue = loot.gpValue or 0
  local gpValue50 = math.floor(gpValue * 0.5)

  local info = UIDropDownMenu_CreateInfo()
  info.text = candidate
  info.isTitle = true
  info.notCheckable = 1
  UIDropDownMenu_AddButton(info)

  -- Отдать лут + полный GP (Мейн спек)
  if gpValue and gpValue > 0 then
    info = UIDropDownMenu_CreateInfo()
    info.text = string.format("Отдать лут + %d GP", gpValue)
    info.notCheckable = 1
    info.disabled = not CanEditOfficerNote()
    info.tooltipTitle = "Выдать предмет и начислить GP"
    info.tooltipText = string.format("GP: %d (полная цена)", gpValue)
    info.func = function()
      LM:GiveLootToCandidate(loot, candidate, LM.LOOTTYPE.GP, gpValue)
    end
    UIDropDownMenu_AddButton(info)
  end

  -- Отдать лут на офф (50% от текущего GP)
  if gpValue50 and gpValue50 > 0 then
    info = UIDropDownMenu_CreateInfo()
    info.text = string.format("Отдать лут на офф + %d GP", gpValue50)
    info.notCheckable = 1
    info.disabled = not CanEditOfficerNote()
    info.tooltipTitle = "Выдать предмет на офф спек (50% GP)"
    info.tooltipText = string.format("GP: %d (50%% от %d)", gpValue50, gpValue)
    info.func = function()
      LM:GiveLootToCandidate(loot, candidate, LM.LOOTTYPE.GP, gpValue50)
    end
    UIDropDownMenu_AddButton(info)
  end

  -- Отдать лут бесплатно
  info = UIDropDownMenu_CreateInfo()
  info.text = "Отдать лут бесплатно"
  info.notCheckable = 1
  info.tooltipTitle = "Выдать предмет без начисления GP"
  info.func = function()
    LM:GiveLootToCandidate(loot, candidate, LM.LOOTTYPE.FREE, 0)
  end
  UIDropDownMenu_AddButton(info)

  -- Отдать для банка
  info = UIDropDownMenu_CreateInfo()
  info.text = "Отдать для банка"
  info.notCheckable = 1
  info.tooltipTitle = "Выдать предмет в банк гильдии"
  info.func = function()
    LM:GiveLootToCandidate(loot, candidate, LM.LOOTTYPE.BANK, 0)
  end
  UIDropDownMenu_AddButton(info)

  info = UIDropDownMenu_CreateInfo()
  info.text = " "
  info.notCheckable = 1
  info.disabled = true
  UIDropDownMenu_AddButton(info)

  info = UIDropDownMenu_CreateInfo()
  info.text = "Шепот"
  info.notCheckable = 1
  info.func = function()
    ChatFrame_SendTell(candidate)
  end
  UIDropDownMenu_AddButton(info)
end

-- ============================================================================
-- ВЫДАЧА ЛУТА КАНДИДАТУ
-- ============================================================================

-- Deferred GP retry frame. Declared UP HERE so RestoreLootTable can call it.
local gpPendingFrame = nil
local function ScheduleGPPendingRetry()
  if not gpPendingFrame then
    gpPendingFrame = CreateFrame("Frame")
    gpPendingFrame:Hide()
    gpPendingFrame.retryInterval = 0
    gpPendingFrame:SetScript("OnUpdate", function(self, elapsed)
      self.retryInterval = self.retryInterval - elapsed
      if self.retryInterval > 0 then return end
      self.retryInterval = 5.0
      LM:FlushPendingGP()
    end)
  end
  gpPendingFrame:Show()
end

-- Persist lootTable to SavedVariables for crash recovery.
-- Only persists data fields (no functions). Restored on ADDON_LOADED.
-- TestMode guard — не засоряем SavedVariables тестовыми записями.
-- Также снапшотим recoveryQueue (pending GP от прошлой сессии).
function LM:PersistLootTable()
  if LM.testMode then return end
  if not LM.db or not LM.db.global then return end
  -- Shallow snapshot: copy loot records but skip transient fields
  local snap = {}
  for key, loot in pairs(LM.state.lootTable or {}) do
    local copy = {}
    for k, v in pairs(loot) do
      if k ~= "candidates" and k ~= "candidateOrder" then
        copy[k] = v
      end
    end
    -- Deep copy candidates (only data fields)
    local candCopy = {}
    for name, cand in pairs(loot.candidates or {}) do
      local c = {}
      for ck, cv in pairs(cand) do
        c[ck] = cv
      end
      candCopy[name] = c
    end
    copy.candidates = candCopy
    copy.candidateOrder = {}
    for i, name in ipairs(loot.candidateOrder or {}) do
      copy.candidateOrder[i] = name
    end
    snap[key] = copy
  end
  LM.db.global.lootTableSnapshot = snap
  -- Снапшот recoveryQueue
  local rqSnap = {}
  for i, rec in ipairs(LM.state.recoveryQueue or {}) do
    rqSnap[i] = {
      lootKey = rec.lootKey,
      player = rec.player,
      link = rec.link,
      itemID = rec.itemID,
      lootType = rec.lootType,
      lootGP = rec.lootGP,
      gpPendingAmount = rec.gpPendingAmount,
      gpPendingReason = rec.gpPendingReason,
      sourceSessionId = rec.sourceSessionId,
    }
  end
  LM.db.global.recoveryQueueSnapshot = rqSnap
end

-- Restore lootTable from SavedVariables on load.
-- Only restores records that have gpPending = true (in-flight GP retries).
-- Также восстанавливаем recoveryQueue (pending GP от прошлой сессии).
function LM:RestoreLootTable()
  if not LM.db or not LM.db.global then return end
  local snap = LM.db.global.lootTableSnapshot
  local restored = 0
  if snap then
    for key, loot in pairs(snap) do
      local hasPending = false
      if loot.candidates then
        for _, cand in pairs(loot.candidates) do
          if cand.gpPending then hasPending = true; break end
        end
      end
      if hasPending then
        -- Mark as non-distributable (loot window is gone)
        loot.mayDistribute = false
        loot.slotID = nil
        -- Помечаем как recovery-eligible — OnChatMsgLoot fallback
        -- может сопоставить CHAT_MSG_LOOT с этой записью даже если sessionId старый
        -- (после reload). Это разрешает fallback matching для crash recovery записей.
        loot.recoveryEligible = true
        LM.state.lootTable[key] = loot
        restored = restored + 1
      end
    end
    if restored > 0 then
      if Addon and Addon.Log then
        Addon.Log:Warn("[LootMaster] Restored %d loot records with pending GP (will retry)", restored)
      end
      -- Необработанные gpPending из восстановленного lootTable
      -- переносим в recoveryQueue (как в EndLootSession) и помечаем оригинал
      -- gpProcessed. Иначе: если после рестарта мы снова стали ML, FlushPendingGP
      -- начислил бы GP из lootTable И из recoveryQueue — двойное списание
      -- (recoveryQueue заполняется через EndLootSession только при СМЕНЕ ML,
      -- а при выходе из игры без смены ML она пуста).
      LM.state.recoveryQueue = LM.state.recoveryQueue or {}
      for key, loot in pairs(LM.state.lootTable) do
        if loot.candidates then
          for name, cand in pairs(loot.candidates) do
            if cand.gpPending and not cand.gpProcessed then
              tinsert(LM.state.recoveryQueue, {
                lootKey = key,
                player = name,
                link = loot.link,
                itemID = loot.itemID,
                lootType = cand.lootType or LM.LOOTTYPE.UNKNOWN,
                lootGP = cand.gpPendingAmount or cand.lootGP or 0,
                gpPendingAmount = cand.gpPendingAmount or 0,
                gpPendingReason = cand.gpPendingReason,
                sourceSessionId = LM:GetLootSessionId(key),
              })
              cand.gpProcessed = true
            end
          end
        end
      end
      ScheduleGPPendingRetry()
    end
    -- Clear snapshot after restore (will be re-persisted on next mutation)
    LM.db.global.lootTableSnapshot = nil
  end
  -- Восстановление recoveryQueue
  local rqSnap = LM.db.global.recoveryQueueSnapshot
  if rqSnap then
    LM.state.recoveryQueue = LM.state.recoveryQueue or {}
    for i, rec in ipairs(rqSnap) do
      tinsert(LM.state.recoveryQueue, rec)
    end
    if #LM.state.recoveryQueue > 0 then
      if Addon and Addon.Log then
        Addon.Log:Warn("[LootMaster] Restored %d recoveryQueue records (will retry GP)",
          #LM.state.recoveryQueue)
      end
      ScheduleGPPendingRetry()
    end
    LM.db.global.recoveryQueueSnapshot = nil
  end
end

-- Try to apply pending GP for all candidates with gpPending flag.
-- Также итерируем recoveryQueue — pending GP от прошлых сессий,
-- сохранённые через EndLootSession. После успеха запись удаляется из recoveryQueue.
-- Re-entry guard (_flush_in_progress) предотвращает множественный
-- запуск на один CURRENT transition (см. StorageStateChanged callback в InitML).
-- RecoveryQueue обрабатывается даже если мы не ML —
-- это pending GP от прошлой сессии где мы были ML (наш долг).
function LM:FlushPendingGP()
  if not LM.state.lootTable then return end
  local anyPending = false
  -- Safe iteration — собирать ключи для TryRemoveLoot, вызывать после цикла
  local keys_to_remove = {}
  -- LootTable итерируем только если мы ML (иначе не наша сессия).
  if LM.state.isML then
    for lootKey, loot in pairs(LM.state.lootTable) do
      if loot.candidates then
        for name, cand in pairs(loot.candidates) do
          if cand.gpPending and not cand.gpProcessed then
            anyPending = true
            if CanEditOfficerNote() and Addon.Award and Addon.Award.IncGP then
              local reason = cand.gpPendingReason or ("Лут: " .. tostring(loot.link))
              local result = Addon.Award:IncGP(name, reason, cand.gpPendingAmount or 0, false)
              if result then
                cand.gpProcessed = true
                local applied = cand.gpPendingAmount or 0
                cand.gpPending = nil
                cand.gpPendingAmount = nil
                cand.gpPendingReason = nil
                cand.gpPendingRetryCount = nil
                cand.lootType = nil
                cand.lootGP = nil
                Addon.Print(string.format("[LootMaster] GP +%d -> %s (отложено, успешно)",
                  applied, tostring(name)))
                -- Отложенное удаление (не вызываем TryRemoveLoot внутри pairs)
                tinsert(keys_to_remove, lootKey)
              else
                cand.gpPendingRetryCount = (cand.gpPendingRetryCount or 0) + 1
                if cand.gpPendingRetryCount >= 12 then
                  Addon.PrintError(string.format(
                    "[LootMaster] GP pending для %s: 12 попыток провалены (60с). См. /gg log",
                    tostring(name)))
                  cand.gpPending = nil
                  cand.gpPendingRetryCount = nil
                end
              end
            end
          end
        end
      end
    end
    -- Удаляем после итерации (safe)
    for _, key in ipairs(keys_to_remove) do
      LM:TryRemoveLoot(key)
    end
    if #keys_to_remove > 0 then
      LM:PersistLootTable()
    end
  end

  -- Обрабатываем recoveryQueue — pending GP от прошлых сессий
  -- (сохранены через EndLootSession). Обрабатываем даже если мы не ML сейчас —
  -- это pending GP от сессии где мы были ML (наш долг).
  local rq_to_remove = {}
  for i, rec in ipairs(LM.state.recoveryQueue or {}) do
    anyPending = true
    if CanEditOfficerNote() and Addon.Award and Addon.Award.IncGP then
      local reason = rec.gpPendingReason or ("Лут: " .. tostring(rec.link))
      local result = Addon.Award:IncGP(rec.player, reason, rec.gpPendingAmount or 0, false)
      if result then
        Addon.Print(string.format("[LootMaster] GP +%d -> %s (recoveryQueue, успешно)",
          rec.gpPendingAmount or 0, tostring(rec.player)))
        tinsert(rq_to_remove, i)
      end
      -- Если IncGP не удался (Storage не готов), оставляем запись — следующий
      -- CURRENT transition (gpPendingFrame OnUpdate / StorageStateChanged) повторит.
    end
  end
  -- Удаляем обработанные записи (с конца чтобы индексы не поплыли)
  for i = #rq_to_remove, 1, -1 do
    tremove(LM.state.recoveryQueue, rq_to_remove[i])
  end
  if #rq_to_remove > 0 then
    LM:PersistLootTable()
  end

  if not anyPending then
    if gpPendingFrame then gpPendingFrame:Hide() end
  end
end

-- Try to remove loot from lootTable. Keeps record if quantity > 1 or pending GP.
function LM:TryRemoveLoot(lootKey)
  local loot = LM.state.lootTable[lootKey]
  if not loot then return end
  -- Don't remove if stacked items remain
  if (loot.quantity or 1) > 1 then
    loot.quantity = loot.quantity - 1
    LM:PersistLootTable()
    return
  end
  -- Don't remove if any candidate has pending GP
  if loot.candidates then
    for _, cand in pairs(loot.candidates) do
      if cand.gpPending then
        LM:PersistLootTable()
        return
      end
    end
  end
  LM.state.lootTable[lootKey] = nil
  LM:PersistLootTable()
end

function LM:GiveLootToCandidate(loot, candidate, lootType, gp)
  if not loot or not candidate then return end
  -- Нормализуем candidate ДО всех lookups.
  -- "Player-Realm" → "Player" — иначе loot.candidates["Player"] не найдётся
  -- и pendingAwards создаст ключ "Player-Realm" отдельно от "Player".
  candidate = LM:NormalizePlayerName(candidate)
  if not candidate then return end
  if not loot.candidates then return end
  if not loot.candidates[candidate] then return end

  -- Idempotency guard. Prevents double GiveMasterLoot from rapid right-clicks.
  if loot.candidates[candidate].lootGiven then
    if Addon.Log and Addon.Log.Debug then
      Addon.Log:Debug("[LootMaster] GiveLoot: %s already given to %s, skipping",
        tostring(loot.name), tostring(candidate))
    end
    return
  end

  -- testMode mock — вместо запрета, устанавливаем те же поля
  -- что и реальный путь (lootGiven/giveTime/lootType/lootGP), чтобы TestFull мог
  -- проверить OnChatMsgLoot FIFO matching. Реальный GiveMasterLoot не вызываем.
  -- Используем централизованную QueuePendingAward с защитой
  -- от дубликата и нормализацией itemID/candidate name.
  -- Если QueuePendingAward вернула false — откатываем ВСЕ
  -- выставленные поля (lootGiven/giveTime/lootType/lootGP), чтобы testMode не
  -- оставлял частично выданный предмет.
  if LM.testMode then
    loot.candidates[candidate].lootGiven = true
    loot.candidates[candidate].giveTime = time()
    loot.candidates[candidate].lootType = lootType
    loot.candidates[candidate].lootGP = tonumber(gp) or 0
    -- Централизованная очередь с защитой от дубликата
    local queued = LM:QueuePendingAward(loot.itemID, candidate, loot.key)
    if not queued then
      -- Откатываем ВСЕ выставленные поля
      loot.candidates[candidate].lootGiven = nil
      loot.candidates[candidate].giveTime = nil
      loot.candidates[candidate].lootType = nil
      loot.candidates[candidate].lootGP = nil
      Addon.PrintError("[LootMaster] testMode: Не удалось создать pending award для " ..
        tostring(loot.name) .. " — все поля откачены")
      -- В testMode всё равно возвращаемся — mock не должен вызывать GiveMasterLoot
      return
    end
    if Addon.Log and Addon.Log.Debug then
      Addon.Log:Debug("[LootMaster] testMode mock GiveLoot: %s -> %s lootKey=%s (pendingAwards queued)",
        tostring(loot.name), tostring(candidate), tostring(loot.key))
    end
    return
  end

  local candidateID = nil
  for cID = 1, 40 do
    local cName = GetMasterLootCandidate(cID)
    -- Сравниваем с нормализованным candidate
    -- (GetMasterLootCandidate может вернуть "Player-Realm" — нормализуем для сравнения)
    if cName then
      local cNorm = LM:NormalizePlayerName(cName)
      if cNorm == candidate then
        candidateID = cID
        break
      end
    end
  end
  if not candidateID then
    Addon.PrintError("[LootMaster] Не найден candidateID для " .. tostring(candidate))
    return
  end

  -- slotID-first resolution:
  --   1. Взять сохранённый loot.slotID.
  --   2. Проверить через GetLootSlotInfo + GetLootSlotLink (itemID match).
  --   3. Если слот валиден и совпадает — использовать именно его.
  --   4. Если нет — найти совпадающие слоты, исключить слоты других активных lootKey,
  --      выбрать только однозначный вариант.
  --   5. Если неоднозначно — НЕ вызывать GiveMasterLoot, показать ошибку ML.
  local slotID = nil
  local targetItemID = loot.itemID

  -- Шаг 1-3: сначала пробуем loot.slotID
  if loot.slotID and GetNumLootItems() > 0 then
    local slotInfo = GetLootSlotInfo(loot.slotID)
    if slotInfo then
      local sLink = GetLootSlotLink(loot.slotID)
      if sLink then
        local sItemID = LM.GetItemIDFromLink(sLink)
        if sItemID and tostring(sItemID) == tostring(targetItemID) then
          slotID = loot.slotID
        end
      end
    end
  end

  -- Шаг 4-5: если loot.slotID невалиден, ищем слоты по itemID, исключая слоты
  -- других активных lootKey. Выбираем однозначный вариант.
  if not slotID then
    -- Строим множество занятых slotID из других активных lootKey
    local taken_slots = {}
    for otherKey, otherLoot in pairs(LM.state.lootTable) do
      if otherKey ~= loot.key and otherLoot.slotID and otherLoot.candidates then
        -- Если у другого loot есть кандидат с lootGiven=true (ещё не выдан),
        -- считаем его slotID занятым
        for _, cand in pairs(otherLoot.candidates) do
          if cand.lootGiven then
            taken_slots[otherLoot.slotID] = true
            break
          end
        end
      end
    end

    local matching_slots = {}
    for sID = 1, GetNumLootItems() do
      if not taken_slots[sID] then
        local sLink = GetLootSlotLink(sID)
        if sLink then
          local sItemID = LM.GetItemIDFromLink(sLink)
          if sItemID and tostring(sItemID) == tostring(targetItemID) then
            tinsert(matching_slots, sID)
          end
        end
      end
    end

    if #matching_slots == 1 then
      slotID = matching_slots[1]
    elseif #matching_slots == 0 then
      Addon.PrintError(string.format(
        "[LootMaster] Не найден свободный slotID для %s (окно лута закрыто или слот занят другим активным lootKey)",
        tostring(loot.name)))
      return
    else
      -- #matching_slots > 1 — неоднозначно
      Addon.PrintError(string.format(
        "[LootMaster] Найдено %d свободных слотов с itemID=%s для %s. Неоднозначно — вызовите раздачу снова когда предыдущие предметы будут выданы.",
        #matching_slots, tostring(targetItemID), tostring(loot.name)))
      return
    end
  end

  -- Validate slot still exists
  local slotInfo = GetLootSlotInfo(slotID)
  if not slotInfo then
    Addon.PrintError("[LootMaster] Слот лута " .. tostring(slotID) .. " больше не существует")
    return
  end

  -- Set lootGiven flag BEFORE GiveMasterLoot to close the race window
  -- between the API call and CHAT_MSG_LOOT arrival.
  loot.candidates[candidate].lootGiven = true
  -- giveTime для FIFO-сопоставления в OnChatMsgLoot (fallback
  -- если pendingAwards очередь потеряна при reload).
  loot.candidates[candidate].giveTime = time()
  loot.candidates[candidate].lootType = lootType
  loot.candidates[candidate].lootGP = tonumber(gp) or 0

  -- Добавляем lootKey в pendingAwards через централизованную
  -- QueuePendingAward (с защитой от дубликата и нормализацией itemID/candidate).
  -- Порядок по spec: candidate проверен → slotID проверен → lootGiven/lootType/lootGP
  -- выставлены → pendingAwards создан → GiveMasterLoot → snapshot.
  -- Если QueuePendingAward вернула false — GiveMasterLoot НЕ вызываем.
  local queued = LM:QueuePendingAward(loot.itemID, candidate, loot.key)
  if not queued then
    -- Откатываем lootGiven, т.к. выдача не состоится
    loot.candidates[candidate].lootGiven = nil
    loot.candidates[candidate].giveTime = nil
    Addon.PrintError("[LootMaster] Не удалось создать pending award для " ..
      tostring(loot.name) .. " — itemID/candidate невалидны")
    return
  end

  if dropDown then CloseDropDownMenus() end

  if Addon.Log then
    Addon.Log:Info("[LootMaster] GiveLoot: %s -> %s type=%d gp=%d slot=%d lootKey=%s",
      tostring(loot.name), tostring(candidate), lootType, gp or 0, slotID, tostring(loot.key))
  end

  GiveMasterLoot(slotID, candidateID)
  LM:PersistLootTable()
end

-- ============================================================================
-- ОБРАБОТКА CHAT_MSG_LOOT -> НАЧИСЛЕНИЕ GP
-- ============================================================================

local function ParseLootMessage(message)
  if not message then return nil end
  local _, _, link = string.find(message, "(|c%x+|Hitem:.+|h%[.+%]|h|r)")
  if not link then return nil end
  local _, _, player = string.find(message, "^([^ ]+)")
  if not player then return nil end
  local _, _, count = string.find(message, "x(%d+)%s*$")
  count = tonumber(count) or 1
  -- Extract itemID from link for reliable comparison
  local itemID = LM.GetItemIDFromLink(link)
  return player, link, count, itemID
end

function LM:OnChatMsgLoot(message)
  if not LM.state.isML then return end
  if not message then return end

  local player, link, count, itemID = ParseLootMessage(message)
  if not player or not link then return end

  if player == "Вы" or player == "You" then
    player = UnitName("player")
  end
  -- Нормализуем имя кандидата для поиска в pendingAwards и loot.candidates
  player = LM:NormalizePlayerName(player)

  -- Matching через pendingAwards очередь с Peek-before-Remove.
  -- Сначала смотрим первый lootKey без удаления. Валидируем что loot существует
  -- и lootGiven=true. Только после успешной валидации вызываем RemovePendingAward.
  -- Это гарантирует: invalid lootKey не удаляется молча; повторный CHAT_MSG_LOOT
  -- не создаёт новые GP операции.
  local loot = nil
  local lootKey = nil

  local queuedLootKey = LM:PeekPendingAward(itemID, player)
  if queuedLootKey then
    local queuedLoot = LM.state.lootTable[queuedLootKey]
    local queuedCand = queuedLoot and queuedLoot.candidates and queuedLoot.candidates[player]
    if queuedLoot and queuedCand and queuedCand.lootGiven then
      -- Дополнительно проверяем что itemID совпадает (defense-in-depth)
      local queuedItemKey = LM:NormalizeItemID(queuedLoot.itemID)
      local eventItemKey = LM:NormalizeItemID(itemID)
      if queuedItemKey == eventItemKey then
        lootKey = queuedLootKey
        loot = queuedLoot
      else
        Addon.Log:Warn(
          "[LootMaster] Pending award itemID mismatch: event=%s queued=%s lootKey=%s",
          tostring(eventItemKey), tostring(queuedItemKey), tostring(queuedLootKey))
        return
      end
    else
      -- Запись в очереди невалидна (лут удалён из lootTable
      -- таймаутом/отменой, или выдача уже обработана) — это "призрак".
      Addon.Log:Warn(
        "[LootMaster] Pending award ghost removed: itemID=%s player=%s lootKey=%s",
        tostring(itemID), tostring(player), tostring(queuedLootKey))
      LM:RemovePendingAward(itemID, player, queuedLootKey)
      -- Не return — падаем в fallback-поиск ниже (реальная выдача может ждать дальше по очереди)
    end
  end

  -- Fallback через giveTime только если
  -- pendingAwards очередь полностью отсутствует (reload/crash recovery сценарий).
  -- Fallback рассматривает ТОЛЬКО:
  --   - loot текущей sessionId (LootTable записи с lootKey prefix = LM.state.sessionId)
  --   - или явно восстановленные записи с loot.recoveryEligible = true (из RestoreLootTable)
  -- Старые lootTable записи прошлой сессии (без recoveryEligible) НЕ рассматриваются.
  -- Если найдено несколько одинаковых записей с равным временем — НЕ выбираем
  -- через pairs() (non-deterministic), выводим ошибку и не начисляем GP.
  if not loot then
    local fallbackMatches = {}
    local currentItemKey = LM:NormalizeItemID(itemID)
    for key, l in pairs(LM.state.lootTable) do
      if LM:NormalizeItemID(l.itemID) == currentItemKey then
        local cand = l.candidates and l.candidates[player]
        if cand and cand.lootGiven and not cand.gpProcessed then
          -- Проверяем что loot текущей сессии или recovery-eligible
          local isCurrentSession = LM:GetLootSessionId(key) == LM.state.sessionId
          local isRecoveryEligible = l.recoveryEligible == true
          if isCurrentSession or isRecoveryEligible then
            tinsert(fallbackMatches, {key=key, loot=l, giveTime=cand.giveTime or l.announcedAt or 0})
          end
        end
      end
    end
    if #fallbackMatches == 1 then
      lootKey = fallbackMatches[1].key
      loot = fallbackMatches[1].loot
    elseif #fallbackMatches > 1 then
      -- Несколько кандидатов с равным временем — неоднозначно
      -- Сортируем по giveTime и проверяем, есть ли однозначный минимум
      table.sort(fallbackMatches, function(a, b) return a.giveTime < b.giveTime end)
      if fallbackMatches[1].giveTime == fallbackMatches[2].giveTime then
        -- Два или более записей с одинаковым минимальным giveTime — неоднозначно
        Addon.PrintError(
          "[LootMaster] Невозможно однозначно сопоставить выданный предмет. " ..
          "GP не начислен автоматически. Найдено " .. #fallbackMatches ..
          " кандидатов с одинаковым временем (itemID=" .. tostring(itemID) ..
          ", player=" .. tostring(player) .. ").")
        return
      end
      lootKey = fallbackMatches[1].key
      loot = fallbackMatches[1].loot
    end
    -- #fallbackMatches == 0: ничего не найдено, выходим
  end
  if not loot then return end
  if not loot.candidates[player] then return end

  -- Валидация свежести выдачи.
  -- CHAT_MSG_LOOT срабатывает на ЛЮБОЕ получение предмета этим игроком
  -- (сам лутнул с трупа, открыл сундук и т.п.), а не только на нашу выдачу
  -- через GiveMasterLoot. Если сообщение пришло через > 90 сек после фактической
  -- выдачи (giveTime) — это почти наверняка ДРУГОЕ получение того же itemID:
  -- НЕ начисляем GP и НЕ трогаем состояние выдачи.
  local loot_cand = loot.candidates[player]
  local loot_age = loot_cand.giveTime and (time() - loot_cand.giveTime) or 0
  if loot_cand.giveTime and loot_age > 90 then
    Addon.PrintError(string.format(
      "[LootMaster] Лут-сообщение для %s отстаёт от выдачи на %d сек — GP не начислен (не наша выдача).",
      tostring(player), loot_age))
    if Addon.Log then
      Addon.Log:Warn("[LootMaster] Stale loot message ignored: player=%s itemID=%s age=%ds lootKey=%s",
        tostring(player), tostring(itemID), loot_age, tostring(lootKey))
    end
    return
  end

  -- Удаляем lootKey из очереди ПОСЛЕ успешного matching,
  -- но ДО вызова IncGP. Если IncGP временно не удался, это уже не pending award,
  -- а gpPending — повторный CHAT_MSG_LOOT не должен повторно создавать GP операцию.
  if queuedLootKey then
    local removed = LM:RemovePendingAward(itemID, player, lootKey)
    if not removed then
      Addon.Log:Warn(
        "[LootMaster] Failed to remove pending award: itemID=%s player=%s lootKey=%s",
        tostring(itemID), tostring(player), tostring(lootKey))
    end
  end

  local lootType = loot.candidates[player].lootType or LM.LOOTTYPE.UNKNOWN
  local lootGP = loot.candidates[player].lootGP or 0

  -- Cap count at loot.quantity to prevent overcount (defensive against wrong chat messages)
  local effectiveCount = math.min(count, loot.quantity or 1)
  if effectiveCount > 1 then
    lootGP = lootGP * effectiveCount
  end

  -- TestMode guard — НЕ вызываем Addon.Award:IncGP.
  -- В тестах мы просто помечаем gpProcessed=true и не трогаем базу GoldGP.
  -- В testMode записываем в LM.testAwards вместо реального
  -- IncGP — это позволяет TestFull/TestDuplicates проверять фактические суммы GP
  -- (400/200) и порядок применения, а не только флаг gpProcessed.
  -- Check if already processed (prevent double GP from duplicate CHAT_MSG_LOOT)
  if loot.candidates[player].gpProcessed then
    if Addon.Log then
      Addon.Log:Debug("[LootMaster] OnChatMsgLoot: %s already processed, skipping", tostring(player))
    end
  elseif LM.testMode then
    -- testMode: помечаем как обработанное, но НЕ начисляем GP.
    -- Записываем в LM.testAwards для проверки сумм в тестах.
    loot.candidates[player].gpProcessed = true
    LM.testAwards = LM.testAwards or {}
    tinsert(LM.testAwards, {
      lootKey = lootKey,
      player = player,
      gp = lootGP,
      lootType = lootType,
    })
    if Addon.Log and Addon.Log.Debug then
      Addon.Log:Debug("[LootMaster] testMode: IncGP suppressed for %s (GP=%d, recorded in testAwards)",
        tostring(player), lootGP)
    end
  elseif lootType == LM.LOOTTYPE.GP and lootGP ~= 0 then
    if CanEditOfficerNote() and Addon.Award and Addon.Award.IncGP then
      local reason = "Лут: " .. link
      local result = Addon.Award:IncGP(player, reason, lootGP, false)
      if result then
        loot.candidates[player].gpProcessed = true
        Addon.Print(string.format("[LootMaster] GP +%d -> %s за %s",
          lootGP, tostring(player), tostring(link)))
      else
        -- GP lost — schedule retry, don't clean up.
        -- Keep lootType/lootGP until retry succeeds.
        loot.candidates[player].gpPending = true
        loot.candidates[player].gpPendingAmount = lootGP
        loot.candidates[player].gpPendingReason = "Лут: " .. tostring(link)
        loot.candidates[player].gpPendingRetryCount = 0
        Addon.PrintError(string.format(
          "[LootMaster] GP +%d для %s отложен (Storage не готов). Retry через 5 сек.",
          lootGP, tostring(player)))
        ScheduleGPPendingRetry()
      end
    else
      -- No officer rights — still schedule retry in case rights come back (rare)
      loot.candidates[player].gpPending = true
      loot.candidates[player].gpPendingAmount = lootGP
      loot.candidates[player].gpPendingReason = "Лут: " .. tostring(link)
      loot.candidates[player].gpPendingRetryCount = 0
      Addon.PrintError(string.format("[LootMaster] Нет прав для начисления GP: %s (отложено)", tostring(player)))
      ScheduleGPPendingRetry()
    end
  else
    -- Free / Bank — no GP, mark as processed
    loot.candidates[player].gpProcessed = true
  end

  -- Clear lootGiven flag (item successfully given to player)
  loot.candidates[player].lootGiven = nil
  -- Чистим giveTime чтобы не мешать следующим сопоставлениям
  loot.candidates[player].giveTime = nil

  -- LOOTED V2 payload — lootKey первым field.
  --   LOOTED:lootKey^player^link^lootType^lootGP
  local lootedPayload = string.format("%s^%s^%s^%d^%d", lootKey, player, link, lootType, lootGP)
  local myName = UnitName("player")
  -- testMode — не отправляем реальный RAID/PARTY broadcast LOOTED.
  -- Self-delivery нужен — чтобы закрыть popup у ML-as-candidate.
  if LM.testMode then
    if loot.candidates[myName] then
      LM:HandleLooted(lootKey, player, link, lootType, lootGP)
    end
  elseif GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0 then
    LM:SendToClient("LOOTED", lootedPayload, nil)
    if loot.candidates[myName] then
      LM:HandleLooted(lootKey, player, link, lootType, lootGP)
    end
  else
    for _, name in ipairs(loot.candidateOrder) do
      LM:SendToClient("LOOTED", lootedPayload, name)
    end
  end

  -- Defer cleanup. If GP pending, keep lootType/lootGP for retry.
  if not loot.candidates[player].gpPending then
    loot.candidates[player].lootType = nil
    loot.candidates[player].lootGP = nil
    -- gpProcessed stays so duplicate CHAT_MSG_LOOT is skipped
  end

  -- Don't remove loot from lootTable if quantity > 1 OR pending GP
  LM:TryRemoveLoot(lootKey)

  if mlFrame and mlFrame:IsShown() then
    if not next(LM.state.lootTable) then
      mlFrame:Hide()
      self:UpdateMLItemButtons()
    else
      local nextKey = next(LM.state.lootTable)
      if nextKey then
        self:ShowMLWindow(LM.state.lootTable[nextKey])
      else
        mlFrame:Hide()
        self:UpdateMLItemButtons()
      end
    end
  else
    self:UpdateMLItemButtons()
  end

  if Addon.Log then
    Addon.Log:Info("[LootMaster] LOOTED: lootKey=%s player=%s got %s type=%d gp=%d",
      tostring(lootKey), tostring(player), tostring(link), lootType, lootGP)
  end
end

-- ============================================================================
-- ФАЗА 7: ИНТЕГРАЦИЯ С GoldGP (встроена выше)
-- ============================================================================
-- IncGP вызывается в OnChatMsgLoot:
--   Addon.Award:IncGP(player, "Лут: " .. link, lootGP, false)
-- GetMemberData вызывается в BuildCandidateList (Фаза 4):
--   Addon:GetMemberData(name) -> gold, gp, main
-- Запись в журнал — автоматически через IncGP -> Addon:Fire("GPAward", ...)
-- Проверка CanEditOfficerNote() — в OnChatMsgLoot
-- Проверка Storage:IsCurrentState() — внутри IncGP (Award.lua)
-- ============================================================================

  -- Отложенный путь — если main уже прошёл PostLoadInit (LM.db готов),
  -- инициализируем ML сами. В нормальном пути LM.db ещё нет — InitML вызовет
  -- main на ADDON_LOADED (двойного запуска нет ни в одном из путей).
  if LM.db and LM.InitML then
    LM:InitML()
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
